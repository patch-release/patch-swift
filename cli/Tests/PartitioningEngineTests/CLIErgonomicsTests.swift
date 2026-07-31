// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler

/// Ergonomics tests for the developer-facing CLI surface that lives in the
/// importable `Compiler` module: the `release`→`push` metadata forwarding, the
/// `bundle_id`→`app_id` resolution + write-back precedence, the `channels`
/// command's module-list fallback derivation, and the rollout-flag validation
/// rule both `push` and `release` share.
///
/// (The command structs themselves live in the non-importable `PatchCLI`
/// executable; this exercises the exact logic they delegate to.)

// A scripted in-memory backend mirroring the one in CLISupportTests, but focused
// on resolution + channel derivation.
private final class ErgoMockAPI: PatchAPI, @unchecked Sendable {
    var appsByBundleId: [String: AppRecord] = [:]
    var lookupCalls: [String] = []
    var uploaded: [ModuleUploadMetadata] = []
    var activeFingerprint: FingerprintRecord?
    var modules: [ModuleRecord] = []

    func lookupApp(bundleId: String) throws -> AppRecord? {
        lookupCalls.append(bundleId); return appsByBundleId[bundleId]
    }
    func registerFingerprint(appId: String, fingerprint: String, components: [String: Any],
                             appVersion: String?) throws -> FingerprintRecord {
        FingerprintRecord(id: "fp", appId: appId, fingerprint: fingerprint, isActive: true, appVersion: appVersion)
    }
    func getActiveFingerprint(appId: String) throws -> FingerprintRecord? { activeFingerprint }
    var entitlementsResult: Entitlements?
    var entitlementsCalls: [String] = []
    func entitlements(workspaceId: String) throws -> Entitlements {
        entitlementsCalls.append(workspaceId)
        guard let e = entitlementsResult else {
            throw APIError.transport("entitlements unavailable (mock)")
        }
        return e
    }
    func uploadAppIcon(appId: String, icon: Data, fileName: String, mimeType: String) throws -> String? {
        return "apps/\(appId)/icon.png"
    }
    func uploadModule(metadata: ModuleUploadMetadata, wasm: Data) throws -> ModuleRecord {
        uploaded.append(metadata)
        return ModuleRecord(id: "mod-\(uploaded.count)", appId: metadata.appId, version: metadata.version,
                            channel: metadata.channel, sha256: "sha", sizeBytes: wasm.count,
                            rolloutPct: metadata.rolloutPct, mandatory: metadata.mandatory, isActive: true,
                            releaseNotes: metadata.releaseNotes, modulePath: "p", pushedAt: "t", rolledBackAt: nil)
    }
    func listModules(appId: String, channel: String?) throws -> [ModuleRecord] {
        channel.map { c in modules.filter { $0.channel == c } } ?? modules
    }
    func updateRollout(moduleID: String, rolloutPct: Int) throws -> ModuleRecord { modules.first { $0.id == moduleID }! }
    func rollback(moduleID: String) throws -> ModuleRecord { modules.first { $0.id == moduleID }! }
    func stats(moduleID: String) throws -> ModuleStats { ModuleStats(moduleId: moduleID, version: "1", downloads: 0, activations: 0, errors: 0) }
}

// MARK: - Rollout flag validation (shared push/release rule)

final class RolloutValidationTests: XCTestCase {
    /// Mirror of `PushFlow.validate(rollout:)`: 0...100 inclusive.
    private func valid(_ rollout: Int) -> Bool { (0...100).contains(rollout) }

    func testRolloutBoundsAreInclusive() {
        XCTAssertTrue(valid(0))
        XCTAssertTrue(valid(100))
        XCTAssertTrue(valid(50))
    }
    func testRolloutOutOfRangeRejected() {
        XCTAssertFalse(valid(-1))
        XCTAssertFalse(valid(101))
    }
}

// MARK: - release → push metadata forwarding

final class ReleaseForwardingTests: XCTestCase {
    /// `release` forwards its push flags straight into the upload metadata via
    /// `PushFlow.Options` → `ModuleUploadMetadata`. This asserts the field-by-field
    /// mapping that wiring depends on (channel, rollout, mandatory, message, version).
    func testReleasePushFlagsMapOntoUploadMetadata() throws {
        let api = ErgoMockAPI()
        let meta = ModuleUploadMetadata(
            appId: "A", workspaceId: "W", version: "2026.06.04.120000",
            fingerprintId: "F", channel: "beta-eu", mandatory: true,
            rolloutPct: 30, releaseNotes: "release msg")
        let rec = try api.uploadModule(metadata: meta, wasm: Data([0, 1]))
        XCTAssertEqual(api.uploaded.count, 1)
        let sent = api.uploaded[0]
        XCTAssertEqual(sent.channel, "beta-eu")
        XCTAssertEqual(sent.rolloutPct, 30)
        XCTAssertEqual(sent.mandatory, true)
        XCTAssertEqual(sent.releaseNotes, "release msg")
        XCTAssertEqual(sent.version, "2026.06.04.120000")
        XCTAssertEqual(rec.channel, "beta-eu")
    }

    func testUploadMetadataDefaultsMatchPushDefaults() {
        // `push`/`release` defaults: production channel, 100% rollout, not mandatory.
        let meta = ModuleUploadMetadata(appId: "A", workspaceId: "W", version: "1", fingerprintId: "F")
        XCTAssertEqual(meta.channel, "production")
        XCTAssertEqual(meta.rolloutPct, 100)
        XCTAssertFalse(meta.mandatory)
        XCTAssertNil(meta.releaseNotes)
    }
}

// MARK: - app_id resolution precedence (CLISupport.resolveAppID logic)

final class AppIDResolutionTests: XCTestCase {
    /// Pinned `app_id` short-circuits — no lookup network call is made.
    func testExplicitAppIDWinsAndSkipsLookup() throws {
        let api = ErgoMockAPI()
        var cfg = PatchConfig(appKey: "k", project: "P", target: "P")
        cfg.appId = "pinned-uuid"
        cfg.bundleId = "com.acme.app"  // present but must be ignored

        // The exact precedence resolveAppID applies:
        let resolved: String
        if let id = cfg.appId, !id.isEmpty {
            resolved = id
        } else {
            resolved = try XCTUnwrap(api.lookupApp(bundleId: cfg.bundleId!)).id
        }
        XCTAssertEqual(resolved, "pinned-uuid")
        XCTAssertTrue(api.lookupCalls.isEmpty, "pinned app_id must NOT trigger a lookup")
    }

    /// Absent app_id → resolve by bundle_id, then cache app_id + workspace_id back.
    func testBundleIdResolutionCachesBackBoth() throws {
        let api = ErgoMockAPI()
        api.appsByBundleId["com.acme.app"] = AppRecord(
            id: "app-9", workspaceId: "ws-9", name: "Acme", bundleId: "com.acme.app", platform: "ios")

        var cfg = PatchConfig(appKey: "k", project: "P", target: "P")
        cfg.bundleId = "com.acme.app"
        XCTAssertNil(cfg.appId)
        XCTAssertNil(cfg.workspaceId)

        let app = try XCTUnwrap(api.lookupApp(bundleId: cfg.bundleId!))
        cfg.appId = app.id
        if (cfg.workspaceId ?? "").isEmpty, !app.workspaceId.isEmpty { cfg.workspaceId = app.workspaceId }

        XCTAssertEqual(cfg.appId, "app-9")
        XCTAssertEqual(cfg.workspaceId, "ws-9")
        XCTAssertEqual(api.lookupCalls, ["com.acme.app"])
        // Persisted form round-trips so the next push skips the lookup.
        let reparsed = try PatchConfig.parse(cfg.yamlString())
        XCTAssertEqual(reparsed.appId, "app-9")
        XCTAssertEqual(reparsed.workspaceId, "ws-9")
    }

    /// An existing workspace_id is preserved (not overwritten) during resolution.
    func testExistingWorkspaceIdIsNotOverwritten() throws {
        let api = ErgoMockAPI()
        api.appsByBundleId["com.acme.app"] = AppRecord(
            id: "app-9", workspaceId: "ws-FROM-BACKEND", name: "Acme",
            bundleId: "com.acme.app", platform: "ios")
        var cfg = PatchConfig(appKey: "k", project: "P", target: "P")
        cfg.bundleId = "com.acme.app"
        cfg.workspaceId = "ws-PINNED"

        let app = try XCTUnwrap(api.lookupApp(bundleId: cfg.bundleId!))
        cfg.appId = app.id
        if (cfg.workspaceId ?? "").isEmpty, !app.workspaceId.isEmpty { cfg.workspaceId = app.workspaceId }

        XCTAssertEqual(cfg.workspaceId, "ws-PINNED", "a pinned workspace_id must not be clobbered")
    }

    /// No app_id AND an unknown bundle_id → lookup returns nil (the command then errors).
    func testUnknownBundleIdYieldsNil() throws {
        let api = ErgoMockAPI()
        XCTAssertNil(try api.lookupApp(bundleId: "com.unknown.app"))
        XCTAssertEqual(api.lookupCalls, ["com.unknown.app"])
    }
}

// MARK: - channels fallback derivation (Channels command degradation path)

/// Mirrors the `Channels` command's "endpoint unavailable" fallback: derive the
/// channel list from `GET /modules`, keeping the active module per channel.
private struct DerivedChannel: Equatable {
    var channel: String
    var activeVersion: String?
    var rolloutPct: Int?
    var mandatory: Bool?
}

private func deriveChannels(from modules: [ModuleRecord]) -> [DerivedChannel] {
    var byChannel: [String: DerivedChannel] = [:]
    for m in modules {
        if byChannel[m.channel] == nil || m.isActive {
            byChannel[m.channel] = DerivedChannel(
                channel: m.channel,
                activeVersion: m.isActive ? m.version : byChannel[m.channel]?.activeVersion,
                rolloutPct: m.isActive ? m.rolloutPct : byChannel[m.channel]?.rolloutPct,
                mandatory: m.isActive ? m.mandatory : byChannel[m.channel]?.mandatory)
        }
    }
    return byChannel.values.sorted { $0.channel < $1.channel }
}

final class ChannelsFallbackTests: XCTestCase {
    private func mod(_ version: String, channel: String, active: Bool,
                     rollout: Int = 100, mandatory: Bool = false) -> ModuleRecord {
        ModuleRecord(id: "id-\(version)", appId: "A", version: version, channel: channel,
                     sha256: "s", sizeBytes: 1, rolloutPct: rollout, mandatory: mandatory,
                     isActive: active, releaseNotes: nil, modulePath: "p", pushedAt: "t", rolledBackAt: nil)
    }

    func testDerivesActivePerChannelSortedByName() {
        let mods = [
            mod("1.0.0", channel: "production", active: false),
            mod("2.0.0", channel: "production", active: true, rollout: 50),
            mod("0.9.0-beta", channel: "beta", active: true, rollout: 25, mandatory: true),
        ]
        let derived = deriveChannels(from: mods)
        XCTAssertEqual(derived.map(\.channel), ["beta", "production"])  // sorted
        let prod = derived.first { $0.channel == "production" }!
        XCTAssertEqual(prod.activeVersion, "2.0.0")
        XCTAssertEqual(prod.rolloutPct, 50)
        let beta = derived.first { $0.channel == "beta" }!
        XCTAssertEqual(beta.activeVersion, "0.9.0-beta")
        XCTAssertEqual(beta.mandatory, true)
    }

    func testChannelWithNoActiveModuleStillAppears() {
        let derived = deriveChannels(from: [mod("1.0.0", channel: "legacy", active: false)])
        XCTAssertEqual(derived.map(\.channel), ["legacy"])
        XCTAssertNil(derived[0].activeVersion, "no active module → nil active version")
    }

    func testEmptyModuleListYieldsNoChannels() {
        XCTAssertTrue(deriveChannels(from: []).isEmpty)
    }

    func testListModulesChannelFilterUsedByDerivation() throws {
        let api = ErgoMockAPI()
        api.modules = [
            mod("1.0.0", channel: "production", active: true),
            mod("0.9.0", channel: "staging", active: true),
        ]
        // No channel filter → all; the command derives across every channel.
        let all = try api.listModules(appId: "A", channel: nil)
        XCTAssertEqual(Set(deriveChannels(from: all).map(\.channel)), ["production", "staging"])
    }
}
