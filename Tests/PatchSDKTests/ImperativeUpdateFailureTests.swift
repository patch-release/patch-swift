import XCTest
import WasmKit
@testable import PatchSDK

/// W4 §5 — failure-path + observable-state coverage that complements
/// `ImperativeUpdateTests` (which covers the happy paths). Here we drive the
/// `.failed` transition for each imperative step, assert the error telemetry
/// fires, and verify the `PatchUpdateStateObservable.available` mirror is kept
/// in sync (set on `.available`, cleared on `.failed` / `.upToDate` / `.idle`).
/// All over mock transports + local file URLs — no real network.
final class ImperativeUpdateFailureTests: XCTestCase {

    // MARK: Helpers

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-impfail-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func marshalBytes() throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm"))
        return [UInt8](try Data(contentsOf: url))
    }

    private struct RoutingTransport: HTTPTransport {
        let route: @Sendable (URLRequest) -> (Data, Int)
        func send(_ request: URLRequest) async throws -> (Data, Int) { route(request) }
    }

    private let apiBase = URL(string: "https://api.test/api/v1")!

    /// Build a configured `Patch` whose `/modules/check` returns `checkStatus` +
    /// `checkBody`, and serves a module of `moduleBytes` at `moduleURLOverride`
    /// (defaults to a real on-disk file with a correct sha256).
    private func makePatch(
        dir: URL,
        appID: String,
        checkBody: Data,
        checkStatus: Int = 200,
        events: EventSink2
    ) throws -> (Patch, ModuleStorage) {
        let transport = RoutingTransport { req in
            let path = req.url?.absoluteString ?? ""
            if path.hasSuffix("/modules/check") { return (checkBody, checkStatus) }
            if path.hasSuffix("/events") { if let b = req.httpBody { events.record(b) }; return (Data(), 201) }
            return (Data(), 404)
        }
        let storage = try ModuleStorage(appKey: "impfail-\(appID)", baseDirectory: dir)
        let checker = UpdateChecker(baseURL: apiBase, transport: transport)
        let patch = Patch()
        patch.bridges.registerDefaults()
        patch.injectForTesting(
            configuration: PatchConfiguration(
                appKey: "impfail", appID: appID, apiBaseURL: apiBase,
                fingerprint: "fp", deviceID: "dev", channel: .production),
            storage: storage, checker: checker)
        return (patch, storage)
    }

    /// A valid `has_update` response whose module is served from a local file URL.
    private func validResponse(dir: URL, bytes: [UInt8], tamperSha: Bool = false) throws -> Data {
        let sha = SHA256Hash.hexString(of: Data(bytes))
        let file = dir.appendingPathComponent("v2.wasm")
        try Data(bytes).write(to: file)
        let response = UpdateCheckResponse(
            has_update: true, version: "2.0.0",
            module_url: file.absoluteString,
            sha256: tamperSha ? String(repeating: "0", count: 64) : sha,
            size: bytes.count, mandatory: false, release_notes: nil)
        return try JSONEncoder().encode(response)
    }

    // MARK: - checkForUpdate failure → .failed + error telemetry

    func testCheckForUpdateFailureSetsFailedStateAndReportsError() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink2()
        // 500 from the check endpoint → UpdateChecker throws → .failed.
        let (patch, _) = try makePatch(
            dir: dir, appID: "a1111111-1111-1111-1111-111111111111",
            checkBody: Data("boom".utf8), checkStatus: 500, events: events)

        do {
            _ = try await patch.checkForUpdate()
            XCTFail("expected check to throw on HTTP 500")
        } catch let e as Patch.UpdateError {
            if case .check = e {} else { XCTFail("wrong error: \(e)") }
        }

        let s = await currentState2(patch)
        guard case .failed = s else { return XCTFail("expected .failed, got \(s)") }
        // An `error` telemetry event was reported.
        XCTAssertTrue(events.eventTypes().contains("error"))
        // The available mirror is nil after a failure.
        let mirror = await MainActor.run { patch.updateState.available }
        XCTAssertNil(mirror)
    }

    // MARK: - fetchUpdate failure (sha256 mismatch) → .failed

    func testFetchUpdateShaMismatchSetsFailedStateAndReportsError() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink2()
        let body = try validResponse(dir: dir, bytes: try marshalBytes(), tamperSha: true)
        let (patch, storage) = try makePatch(
            dir: dir, appID: "a2222222-2222-2222-2222-222222222222",
            checkBody: body, events: events)

        _ = try await patch.checkForUpdate()  // succeeds; .available
        do {
            _ = try await patch.fetchUpdate()
            XCTFail("expected fetch to throw on sha256 mismatch")
        } catch let e as Patch.UpdateError {
            if case .fetch = e {} else { XCTFail("wrong error: \(e)") }
        }

        // Failed, nothing staged or cached, error reported.
        let s = await currentState2(patch)
        guard case .failed = s else { return XCTFail("expected .failed, got \(s)") }
        XCTAssertFalse(patch.hasActiveModule)
        XCTAssertNil(storage.currentVersion)
        XCTAssertTrue(events.eventTypes().contains("error"))
        // download/activation never fired.
        XCTAssertFalse(events.eventTypes().contains("download"))
    }

    // MARK: - reloadAsync with nothing staged → throws, no state corruption

    func testReloadWithNothingStagedThrowsNothingStaged() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink2()
        let body = try validResponse(dir: dir, bytes: try marshalBytes())
        let (patch, _) = try makePatch(
            dir: dir, appID: "a3333333-3333-3333-3333-333333333333",
            checkBody: body, events: events)
        _ = try await patch.checkForUpdate()  // available but not fetched

        do {
            try await patch.reloadAsync()
            XCTFail("expected nothingStaged")
        } catch let e as Patch.UpdateError {
            if case .nothingStaged = e {} else { XCTFail("wrong error: \(e)") }
        }
    }

    // MARK: - Observable `available` mirror lifecycle

    func testAvailableMirrorSetOnAvailableClearedOnUpToDate() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink2()
        let body = try validResponse(dir: dir, bytes: try marshalBytes())
        let appID = "a4444444-4444-4444-4444-444444444444"
        let (patch, storage) = try makePatch(
            dir: dir, appID: appID, checkBody: body, events: events)

        _ = try await patch.checkForUpdate()
        let afterAvailable = await MainActor.run { patch.updateState.available }
        XCTAssertEqual(afterAvailable?.version, "2.0.0", "available mirror set on .available")

        // Re-inject a checker that now reports up-to-date → mirror must clear.
        let upToDateChecker = UpdateChecker(
            baseURL: apiBase,
            transport: RoutingTransport { req in
                let p = req.url?.absoluteString ?? ""
                if p.hasSuffix("/modules/check") { return (Data(#"{"has_update": false}"#.utf8), 200) }
                return (Data(), 201)
            })
        patch.injectForTesting(
            configuration: PatchConfiguration(
                appKey: "impfail", appID: appID, apiBaseURL: apiBase,
                fingerprint: "fp", deviceID: "dev", channel: .production),
            storage: storage, checker: upToDateChecker)
        let info = try await patch.checkForUpdate()
        XCTAssertNil(info)
        let s = await currentState2(patch)
        XCTAssertEqual(s, .upToDate)
        let afterUpToDate = await MainActor.run { patch.updateState.available }
        XCTAssertNil(afterUpToDate, "available mirror cleared on .upToDate")
    }

    func testAvailableMirrorRetainedDuringFetchThenClearedOnActivate() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink2()
        let body = try validResponse(dir: dir, bytes: try marshalBytes())
        let (patch, storage) = try makePatch(
            dir: dir, appID: "a5555555-5555-5555-5555-555555555555",
            checkBody: body, events: events)

        _ = try await patch.checkForUpdate()
        _ = try await patch.fetchUpdate()
        // During fetch/readyToReload the mirror is retained (not cleared).
        let duringStage = await MainActor.run { patch.updateState.available }
        XCTAssertEqual(duringStage?.version, "2.0.0")

        try await patch.reloadAsync()
        XCTAssertTrue(patch.hasActiveModule)
        XCTAssertEqual(storage.currentVersion, "2.0.0")
        // Activation → .idle → mirror cleared.
        let afterIdle = await MainActor.run { patch.updateState.available }
        XCTAssertNil(afterIdle, "available mirror cleared once back to .idle")
    }
}

/// Thread-safe sink for captured event POST bodies (local to this file).
private final class EventSink2: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    func record(_ d: Data) { lock.lock(); bodies.append(d); lock.unlock() }
    func eventTypes() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var s = Set<String>()
        for b in bodies {
            if let o = try? JSONSerialization.jsonObject(with: b) as? [String: Any],
               let t = o["event_type"] as? String { s.insert(t) }
        }
        return s
    }
}

@Sendable private func currentState2(_ patch: Patch) async -> PatchUpdateState {
    await MainActor.run { patch.updateState.state }
}
