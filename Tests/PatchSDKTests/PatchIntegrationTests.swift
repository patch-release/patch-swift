import XCTest
import WasmKit
@testable import PatchSDK

/// End-to-end: Patch.start()/checkForUpdate() wiring the D2 loader + fallback +
/// telemetry over a mock transport (no real network). Proves the orchestration,
/// not just the units.
final class PatchIntegrationTests: XCTestCase {

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-integ-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func marshalBytes() throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm"))
        return [UInt8](try Data(contentsOf: url))
    }

    /// Transport that serves a canned check response and a module file by URL.
    private struct RoutingTransport: HTTPTransport {
        let route: @Sendable (URLRequest) -> (Data, Int)
        func send(_ request: URLRequest) async throws -> (Data, Int) { route(request) }
    }

    func testStartActivatesBundledThenAppliesRemoteUpdate() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = try marshalBytes()
        let sha = SHA256Hash.hexString(of: Data(bytes))

        // Serve the new module from a local file URL.
        let moduleFile = dir.appendingPathComponent("v2.wasm")
        try Data(bytes).write(to: moduleFile)

        let appID = "11111111-1111-1111-1111-111111111111"
        let checkResponse = UpdateCheckResponse(
            has_update: true, version: "2.0.0",
            module_url: moduleFile.absoluteString, sha256: sha, size: bytes.count)
        let checkJSON = try JSONEncoder().encode(checkResponse)

        let events = EventCollector()
        let transport = RoutingTransport { req in
            let path = req.url?.absoluteString ?? ""
            if path.hasSuffix("/modules/check") { return (checkJSON, 200) }
            if path.hasSuffix("/events") {
                if let body = req.httpBody { events.record(body) }
                return (Data(), 201)
            }
            return (Data(), 404)
        }

        let storage = try ModuleStorage(appKey: "integ", baseDirectory: dir)
        // Bundled fallback = the real module, so phase-1 activates something.
        storage.registerBundled(version: "bundled-1.0", bytes: bytes)

        let checker = UpdateChecker(
            baseURL: URL(string: "https://api.test/api/v1")!, transport: transport)

        let patch = Patch()
        patch.bridges.registerDefaults()
        patch.injectForTesting(
            configuration: PatchConfiguration(
                appKey: "integ", appID: appID, apiBaseURL: URL(string: "https://api.test/api/v1")!,
                fingerprint: "fp", deviceID: "dev-1"),
            storage: storage, checker: checker)

        // Phase 1: local fallback chain activates the bundled module.
        let outcome = await patch.start()
        if case .activated = outcome {} else { XCTFail("expected local activation, got \(outcome)") }

        // Phase 2 (run inside start): the remote update was applied → current=2.0.0.
        XCTAssertEqual(storage.currentVersion, "2.0.0")
        XCTAssertTrue(patch.hasActiveModule)
        XCTAssertEqual(Int64(bitPattern: try patch.call("add_i64", [.i64(40), .i64(2)])[0].i64), 42)

        // Telemetry: download + activation events fired with the right schema.
        let types = events.eventTypes()
        XCTAssertTrue(types.contains("download"), "expected a download event, got \(types)")
        XCTAssertTrue(types.contains("activation"), "expected an activation event, got \(types)")
    }

    func testCheckForUpdateRecoversWhenNewModuleCorrupt() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let good = try marshalBytes()

        // Seed a healthy current so there's something to fall back to.
        let storage = try ModuleStorage(appKey: "integ2", baseDirectory: dir)
        try storage.installCurrent(version: "1.0.0", sha256: SHA256Hash.hexString(of: Data(good)), bytes: good)
        // And a previous (install again so 1.0.0 becomes previous, 1.1.0 current).
        try storage.installCurrent(version: "1.1.0", sha256: "x", bytes: good)

        // Remote offers a "2.0.0" whose bytes are garbage but whose advertised
        // sha matches the garbage (so verify passes, but ACTIVATION traps).
        let garbage: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0xFF, 0xFF, 0xFF, 0xFF]
        let garbageSHA = SHA256Hash.hexString(of: Data(garbage))
        let moduleFile = dir.appendingPathComponent("bad.wasm")
        try Data(garbage).write(to: moduleFile)

        let appID = "22222222-2222-2222-2222-222222222222"
        let resp = UpdateCheckResponse(
            has_update: true, version: "2.0.0",
            module_url: moduleFile.absoluteString, sha256: garbageSHA, size: garbage.count)
        let respJSON = try JSONEncoder().encode(resp)

        let events = EventCollector()
        let transport = RoutingTransport { req in
            let p = req.url?.absoluteString ?? ""
            if p.hasSuffix("/modules/check") { return (respJSON, 200) }
            if p.hasSuffix("/events") { if let b = req.httpBody { events.record(b) }; return (Data(), 201) }
            return (Data(), 404)
        }

        let patch = Patch()
        patch.injectForTesting(
            configuration: PatchConfiguration(
                appKey: "integ2", appID: appID, apiBaseURL: URL(string: "https://api.test/api/v1")!,
                deviceID: "dev-2"),
            storage: storage,
            checker: UpdateChecker(baseURL: URL(string: "https://api.test/api/v1")!, transport: transport))

        let outcome = await patch.checkAndApply()
        // The corrupt 2.0.0 fails to activate → recover to previous (1.0.0).
        if case .fallback(let state) = outcome {
            XCTAssertEqual(state, .previous(version: "1.0.0"))
        } else {
            XCTFail("expected fallback outcome, got \(outcome)")
        }
        XCTAssertEqual(storage.currentVersion, "1.0.0")
        // The recovered module still runs.
        XCTAssertEqual(Int64(bitPattern: try patch.call("add_i64", [.i64(3), .i64(4)])[0].i64), 7)
        // Error + fallback telemetry fired.
        let types = events.eventTypes()
        XCTAssertTrue(types.contains("error"))
        XCTAssertTrue(types.contains("fallback"))
    }
}

/// Collects event POST bodies for assertions.
private final class EventCollector: @unchecked Sendable {
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
