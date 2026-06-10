import XCTest
import WasmKit
@testable import PatchSDK

/// W4 §5 — the EAS-Expo-Updates-style imperative API:
/// `checkForUpdate()` (no apply) → `fetchUpdate()` (stage) → `reloadAsync()`
/// (activate), plus `enforceMandatoryUpdates()`, the `isMandatory` surface, the
/// observable `updateState`, and arbitrary channel strings. All over a mock
/// transport + local file URLs — no real network.
final class ImperativeUpdateTests: XCTestCase {

    // MARK: Helpers

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-imp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func marshalBytes() throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm"))
        return [UInt8](try Data(contentsOf: url))
    }

    /// Transport that serves a canned check response, captures the check request,
    /// and serves module files by URL. Records event POSTs.
    private struct RoutingTransport: HTTPTransport {
        let route: @Sendable (URLRequest) -> (Data, Int)
        func send(_ request: URLRequest) async throws -> (Data, Int) { route(request) }
    }

    private let apiBase = URL(string: "https://api.test/api/v1")!

    /// Build a configured `Patch` + storage whose check endpoint returns
    /// `response`, serving the module bytes from a local file URL.
    private func makePatch(
        dir: URL,
        appID: String,
        channel: PatchChannel = .production,
        mandatory: Bool = false,
        releaseNotes: String? = nil,
        size: Int? = nil,
        events: EventSink,
        capturedCheck: RequestSink? = nil
    ) throws -> (Patch, ModuleStorage, UpdateCheckResponse) {
        let bytes = try marshalBytes()
        let sha = SHA256Hash.hexString(of: Data(bytes))
        let moduleFile = dir.appendingPathComponent("v2.wasm")
        try Data(bytes).write(to: moduleFile)

        let response = UpdateCheckResponse(
            has_update: true, version: "2.0.0",
            module_url: moduleFile.absoluteString, sha256: sha,
            size: size ?? bytes.count, mandatory: mandatory, release_notes: releaseNotes)
        let checkJSON = try JSONEncoder().encode(response)

        let transport = RoutingTransport { req in
            let path = req.url?.absoluteString ?? ""
            if path.hasSuffix("/modules/check") { capturedCheck?.set(req); return (checkJSON, 200) }
            if path.hasSuffix("/events") { if let b = req.httpBody { events.record(b) }; return (Data(), 201) }
            return (Data(), 404)
        }

        let storage = try ModuleStorage(appKey: "imp-\(appID)", baseDirectory: dir)
        let checker = UpdateChecker(baseURL: apiBase, transport: transport)
        let patch = Patch()
        patch.bridges.registerDefaults()
        patch.injectForTesting(
            configuration: PatchConfiguration(
                appKey: "imp", appID: appID, apiBaseURL: apiBase,
                fingerprint: "fp", deviceID: "dev", channel: channel),
            storage: storage, checker: checker)
        return (patch, storage, response)
    }


    // MARK: - checkForUpdate (report only, no apply)

    func testCheckForUpdateReportsAvailabilityWithoutApplying() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink()
        let (patch, storage, _) = try makePatch(
            dir: dir, appID: "11111111-1111-1111-1111-111111111111",
            mandatory: true, releaseNotes: "EU pricing fix", size: 4242, events: events)

        let info = try await patch.checkForUpdate()
        let unwrapped = try XCTUnwrap(info)
        XCTAssertEqual(unwrapped.version, "2.0.0")
        XCTAssertEqual(unwrapped.releaseNotes, "EU pricing fix")
        XCTAssertTrue(unwrapped.isMandatory, "response.mandatory must surface as isMandatory")
        XCTAssertEqual(unwrapped.sizeBytes, 4242)

        // Crucially: nothing was applied or cached.
        XCTAssertFalse(patch.hasActiveModule, "checkForUpdate must NOT activate")
        XCTAssertNil(storage.currentVersion, "checkForUpdate must NOT cache")

        // No download/activation telemetry fired (only a check happened).
        let types = events.eventTypes()
        XCTAssertFalse(types.contains("download"))
        XCTAssertFalse(types.contains("activation"))

        // Observable reached `.available`.
        let s = await currentState(patch)
        XCTAssertEqual(s, .available(unwrapped))
    }

    func testCheckForUpdateReturnsNilWhenUpToDate() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let transport = RoutingTransport { req in
            let p = req.url?.absoluteString ?? ""
            if p.hasSuffix("/modules/check") { return (Data(#"{"has_update": false}"#.utf8), 200) }
            return (Data(), 201)
        }
        let storage = try ModuleStorage(appKey: "uptodate", baseDirectory: dir)
        let patch = Patch()
        patch.injectForTesting(
            configuration: PatchConfiguration(
                appKey: "uptodate", appID: "22222222-2222-2222-2222-222222222222",
                apiBaseURL: apiBase, deviceID: "d"),
            storage: storage, checker: UpdateChecker(baseURL: apiBase, transport: transport))

        let info = try await patch.checkForUpdate()
        XCTAssertNil(info)
        let s = await currentState(patch)
        XCTAssertEqual(s, .upToDate)
    }

    func testCheckForUpdateThrowsWhenNotConfiguredForRemote() async {
        let patch = Patch()  // no apiBaseURL / appID
        do {
            _ = try await patch.checkForUpdate()
            XCTFail("expected notConfigured")
        } catch let e as Patch.UpdateError {
            if case .notConfigured = e {} else { XCTFail("wrong error: \(e)") }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    // MARK: - fetchUpdate (stage, no activate)

    func testFetchUpdateStagesWithoutActivating() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink()
        let (patch, storage, _) = try makePatch(
            dir: dir, appID: "33333333-3333-3333-3333-333333333333", events: events)

        _ = try await patch.checkForUpdate()
        let staged = try await patch.fetchUpdate()
        XCTAssertTrue(staged)

        // Downloaded + verified, but NOT activated and NOT yet cached.
        XCTAssertFalse(patch.hasActiveModule, "fetchUpdate must not activate")
        XCTAssertNil(storage.currentVersion, "fetchUpdate must not install as current")

        // Download telemetry fired; activation did NOT.
        let types = events.eventTypes()
        XCTAssertTrue(types.contains("download"))
        XCTAssertFalse(types.contains("activation"))

        let s = await currentState(patch)
        XCTAssertEqual(s, .readyToReload)
    }

    func testFetchUpdateChecksImplicitlyWhenNoPriorCheck() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink()
        let (patch, _, _) = try makePatch(
            dir: dir, appID: "44444444-4444-4444-4444-444444444444", events: events)
        // No explicit checkForUpdate() first — fetchUpdate should check itself.
        let staged = try await patch.fetchUpdate()
        XCTAssertTrue(staged)
        let s = await currentState(patch)
        XCTAssertEqual(s, .readyToReload)
    }

    // MARK: - reloadAsync (activate the staged update)

    func testReloadAsyncActivatesStagedUpdate() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink()
        let (patch, storage, _) = try makePatch(
            dir: dir, appID: "55555555-5555-5555-5555-555555555555", events: events)

        _ = try await patch.checkForUpdate()
        _ = try await patch.fetchUpdate()
        XCTAssertFalse(patch.hasActiveModule)

        try await patch.reloadAsync()

        // Now active + cached as the new current; the module actually runs.
        XCTAssertTrue(patch.hasActiveModule)
        XCTAssertEqual(storage.currentVersion, "2.0.0")
        XCTAssertEqual(Int64(bitPattern: try patch.call("add_i64", [.i64(40), .i64(2)])[0].i64), 42)

        // Activation telemetry fired (download fired during fetch).
        let types = events.eventTypes()
        XCTAssertTrue(types.contains("download"))
        XCTAssertTrue(types.contains("activation"))

        let s = await currentState(patch)
        XCTAssertEqual(s, .idle)
    }

    func testReloadAsyncThrowsWithNothingStaged() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink()
        let (patch, _, _) = try makePatch(
            dir: dir, appID: "66666666-6666-6666-6666-666666666666", events: events)
        do {
            try await patch.reloadAsync()
            XCTFail("expected nothingStaged")
        } catch let e as Patch.UpdateError {
            if case .nothingStaged = e {} else { XCTFail("wrong error: \(e)") }
        }
    }

    // MARK: - enforceMandatoryUpdates

    func testEnforceMandatoryUpdatesAppliesMandatory() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink()
        let (patch, storage, _) = try makePatch(
            dir: dir, appID: "77777777-7777-7777-7777-777777777777",
            mandatory: true, events: events)

        await patch.enforceMandatoryUpdates()

        // Mandatory → fetched + reloaded automatically.
        XCTAssertTrue(patch.hasActiveModule)
        XCTAssertEqual(storage.currentVersion, "2.0.0")
        let types = events.eventTypes()
        XCTAssertTrue(types.contains("download"))
        XCTAssertTrue(types.contains("activation"))
    }

    func testEnforceMandatoryUpdatesSkipsOptional() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink()
        let (patch, storage, _) = try makePatch(
            dir: dir, appID: "88888888-8888-8888-8888-888888888888",
            mandatory: false, events: events)

        await patch.enforceMandatoryUpdates()

        // Optional update is surfaced but NOT auto-applied.
        XCTAssertFalse(patch.hasActiveModule, "optional update must not be forced")
        XCTAssertNil(storage.currentVersion)
        // Left in `.available` for the developer to act on.
        let s = await currentState(patch)
        if case .available(let info) = s {
            XCTAssertFalse(info.isMandatory)
        } else {
            XCTFail("expected .available state")
        }
    }

    // MARK: - Channels (§3): arbitrary channel string on the wire

    func testArbitraryChannelStringSentOnWire() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventSink()
        let captured = RequestSink()
        let (patch, _, _) = try makePatch(
            dir: dir, appID: "99999999-9999-9999-9999-999999999999",
            channel: .custom("beta-eu"), events: events, capturedCheck: captured)

        _ = try await patch.checkForUpdate()

        let sent = try XCTUnwrap(captured.get())
        let body = try XCTUnwrap(sent.httpBody)
        let decoded = try JSONDecoder().decode(UpdateCheckRequest.self, from: body)
        XCTAssertEqual(decoded.channel, "beta-eu", "custom channel string must ride on the wire")
    }

    func testChannelNameConvenienceInitMapsPresetsAndCustom() {
        XCTAssertEqual(PatchConfiguration(appKey: "a", channelName: "production").channel, .production)
        XCTAssertEqual(PatchConfiguration(appKey: "a", channelName: "staging").channel, .staging)
        XCTAssertEqual(PatchConfiguration(appKey: "a", channelName: "qa").channel, .custom("qa"))
        XCTAssertEqual(PatchConfiguration(appKey: "a", channelName: "qa").channelName, "qa")
        XCTAssertEqual(PatchChannel.custom("beta").name, "beta")
    }
}

/// Thread-safe sink for captured event POST bodies.
private final class EventSink: @unchecked Sendable {
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

/// Thread-safe capture box for a single request.
private final class RequestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var req: URLRequest?
    func set(_ r: URLRequest) { lock.lock(); req = r; lock.unlock() }
    func get() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return req }
}

/// Read `Patch.updateState.state` on the main actor. A free function (not a
/// method) so awaiting it from a test never captures the non-Sendable
/// XCTestCase `self`.
@Sendable private func currentState(_ patch: Patch) async -> PatchUpdateState {
    await MainActor.run { patch.updateState.state }
}
