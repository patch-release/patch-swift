// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler

/// Tests for the B3 paid-only rollout pre-check.
///
/// The CLI used to run the FULL WASM build and only learn the plan can't do a
/// phased rollout / non-prod channel when the upload 402'd — wasting a compile
/// on the free tier. These tests cover the pure decision logic
/// (`PaidRolloutPrecheck`) AND an orchestration mirror of what `push`/`release` do,
/// proving a hobby `--rollout 25` fails fast (mocked entitlements call) WITHOUT
/// ever invoking the build/upload.

// A `PatchAPI` mock that records the entitlements pre-check and the upload, so we
// can assert the upload (the proxy for "the build ran") is never reached when the
// pre-check refuses.
private final class PrecheckMockAPI: PatchAPI, @unchecked Sendable {
    var entitlementsResult: Entitlements?
    var entitlementsCalls: [String] = []
    var uploadCalls = 0

    func lookupApp(bundleId: String) throws -> AppRecord? { nil }
    func registerFingerprint(appId: String, fingerprint: String, components: [String: Any],
                             appVersion: String?) throws -> FingerprintRecord {
        FingerprintRecord(id: "fp", appId: appId, fingerprint: fingerprint, isActive: true, appVersion: nil)
    }
    func getActiveFingerprint(appId: String) throws -> FingerprintRecord? { nil }
    func entitlements(workspaceId: String) throws -> Entitlements {
        entitlementsCalls.append(workspaceId)
        guard let e = entitlementsResult else { throw APIError.transport("offline (mock)") }
        return e
    }
    func uploadAppIcon(appId: String, icon: Data, fileName: String, mimeType: String) throws -> String? { nil }
    func uploadModule(metadata: ModuleUploadMetadata, wasm: Data) throws -> ModuleRecord {
        uploadCalls += 1
        return ModuleRecord(id: "m", appId: metadata.appId, version: metadata.version,
                            channel: metadata.channel, sha256: "s", sizeBytes: wasm.count,
                            rolloutPct: metadata.rolloutPct, mandatory: metadata.mandatory,
                            isActive: true, releaseNotes: nil, modulePath: "p", pushedAt: "t",
                            rolledBackAt: nil)
    }
    func listModules(appId: String, channel: String?) throws -> [ModuleRecord] { [] }
    func updateRollout(moduleID: String, rolloutPct: Int) throws -> ModuleRecord { fatalError() }
    func rollback(moduleID: String) throws -> ModuleRecord { fatalError() }
    func stats(moduleID: String) throws -> ModuleStats {
        ModuleStats(moduleId: moduleID, version: "1", downloads: 0, activations: 0, errors: 0)
    }
}

private func hobby() -> Entitlements {
    Entitlements(plan: "hobby", isPaid: false, canAbTest: false, canUseChannels: false,
                 upgradeURL: "https://patch.dev/pricing",
                 upgradeAbMsg: "Phased rollouts and A/B testing are a paid feature.",
                 upgradeChannelMsg: "Release channels are a paid feature.")
}

private func pro() -> Entitlements {
    Entitlements(plan: "pro", isPaid: true, canAbTest: true, canUseChannels: true,
                 upgradeURL: "https://patch.dev/pricing", upgradeAbMsg: "", upgradeChannelMsg: "")
}

// MARK: - requiresPaidPlan: which requests even need a round-trip

final class RequiresPaidPlanTests: XCTestCase {
    func testFullProductionReleaseNeedsNoCheck() {
        // The COMMON path: rollout 100 on production → no round-trip, no latency.
        XCTAssertFalse(PaidRolloutPrecheck.requiresPaidPlan(channel: "production", rollout: 100))
    }
    func testNonFullRolloutRequiresPaidPlan() {
        XCTAssertTrue(PaidRolloutPrecheck.requiresPaidPlan(channel: "production", rollout: 25))
        XCTAssertTrue(PaidRolloutPrecheck.requiresPaidPlan(channel: "production", rollout: 0))
    }
    func testNonProductionChannelRequiresPaidPlan() {
        XCTAssertTrue(PaidRolloutPrecheck.requiresPaidPlan(channel: "beta", rollout: 100))
        XCTAssertTrue(PaidRolloutPrecheck.requiresPaidPlan(channel: "canary", rollout: 100))
    }
}

// MARK: - upgradeMessage: which message to fail with

final class UpgradeMessageTests: XCTestCase {
    func testHobbyNonFullRolloutReturnsAbMessage() {
        let msg = PaidRolloutPrecheck.upgradeMessage(channel: "production", rollout: 25,
                                                     entitlements: hobby())
        XCTAssertEqual(msg, hobby().upgradeAbMsg)
    }
    func testHobbyNonProdChannelReturnsChannelMessage() {
        let msg = PaidRolloutPrecheck.upgradeMessage(channel: "beta", rollout: 100,
                                                     entitlements: hobby())
        XCTAssertEqual(msg, hobby().upgradeChannelMsg)
    }
    func testHobbyRolloutGateWinsOverChannelGate() {
        // Mirrors the server: the A-B (rollout) gate is evaluated before channel.
        let msg = PaidRolloutPrecheck.upgradeMessage(channel: "beta", rollout: 25,
                                                     entitlements: hobby())
        XCTAssertEqual(msg, hobby().upgradeAbMsg)
    }
    func testProPlanProceedsForPaidRollout() {
        XCTAssertNil(PaidRolloutPrecheck.upgradeMessage(channel: "beta", rollout: 25,
                                                        entitlements: pro()))
    }
    func testFullProductionAlwaysProceeds() {
        XCTAssertNil(PaidRolloutPrecheck.upgradeMessage(channel: "production", rollout: 100,
                                                        entitlements: hobby()))
    }
}

// MARK: - Orchestration: the push/release pre-check sequence (the B3 short-circuit)

/// Mirrors exactly what `PushFlow.precheckPaidRollout` does (it lives in the
/// non-importable `PatchCLI` executable, so we re-run its sequence here against
/// the same `PatchAPI` mock). Proves the upload — and therefore the build that
/// precedes it in `release` — is NEVER reached when the plan can't do the rollout.
private enum PrecheckError: Error, Equatable { case refused(String) }

private func runPrecheckThenUpload(api: PrecheckMockAPI, workspaceId: String,
                                   channel: String, rollout: Int) throws {
    // 1. Common path → no entitlements call at all.
    if PaidRolloutPrecheck.requiresPaidPlan(channel: channel, rollout: rollout) {
        // 2. Resolve entitlements; a failed call (offline/old backend) falls back.
        if let ent = try? api.entitlements(workspaceId: workspaceId),
           let msg = PaidRolloutPrecheck.upgradeMessage(
               channel: channel, rollout: rollout, entitlements: ent) {
            throw PrecheckError.refused(msg)  // FAIL FAST — before build/upload.
        }
    }
    // 3. Only reached when the pre-check passed (or fell back): build + upload.
    _ = try api.uploadModule(
        metadata: ModuleUploadMetadata(appId: "A", workspaceId: workspaceId,
                                       version: "1", fingerprintId: "F",
                                       channel: channel, rolloutPct: rollout),
        wasm: Data([0]))
}

final class PrecheckOrchestrationTests: XCTestCase {
    /// THE B3 TEST: a hobby `--rollout 25` fails fast WITHOUT invoking the build.
    func testHobbyRollout25FailsFastWithoutBuildingOrUploading() {
        let api = PrecheckMockAPI()
        api.entitlementsResult = hobby()
        XCTAssertThrowsError(
            try runPrecheckThenUpload(api: api, workspaceId: "W", channel: "production", rollout: 25)
        ) { err in
            guard case PrecheckError.refused(let msg) = err else {
                return XCTFail("expected a paid-plan refusal, got \(err)")
            }
            XCTAssertEqual(msg, hobby().upgradeAbMsg)
        }
        // The pre-check ran exactly one entitlements round-trip…
        XCTAssertEqual(api.entitlementsCalls, ["W"])
        // …and the build/upload was NEVER reached (the whole point of B3).
        XCTAssertEqual(api.uploadCalls, 0, "the build/upload must be skipped on a fast-fail")
    }

    /// The COMMON path (rollout 100 / production) adds NO round-trip and uploads.
    func testFullProductionReleaseSkipsEntitlementsRoundTrip() throws {
        let api = PrecheckMockAPI()
        api.entitlementsResult = hobby()  // even a hobby plan is fine at 100% / prod
        try runPrecheckThenUpload(api: api, workspaceId: "W", channel: "production", rollout: 100)
        XCTAssertTrue(api.entitlementsCalls.isEmpty, "common path must NOT call entitlements")
        XCTAssertEqual(api.uploadCalls, 1)
    }

    /// A paid plan requesting a phased rollout proceeds to build/upload.
    func testProPlanProceedsToUpload() throws {
        let api = PrecheckMockAPI()
        api.entitlementsResult = pro()
        try runPrecheckThenUpload(api: api, workspaceId: "W", channel: "beta", rollout: 25)
        XCTAssertEqual(api.entitlementsCalls, ["W"])
        XCTAssertEqual(api.uploadCalls, 1)
    }

    /// Offline / old backend (entitlements call throws) → DON'T block: fall back
    /// to the build + server gate. The legitimate push must still go through.
    func testEntitlementsFailureFallsBackToBuildAndUpload() throws {
        let api = PrecheckMockAPI()
        api.entitlementsResult = nil  // entitlements() throws
        try runPrecheckThenUpload(api: api, workspaceId: "W", channel: "beta", rollout: 25)
        XCTAssertEqual(api.entitlementsCalls, ["W"], "we tried the pre-check…")
        XCTAssertEqual(api.uploadCalls, 1, "…but a failed pre-check never blocks the push")
    }
}
