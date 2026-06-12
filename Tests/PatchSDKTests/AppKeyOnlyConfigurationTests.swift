import XCTest
@testable import PatchSDK

/// The snippet-only integration — `Patch.configure(.init(appKey: "pak_…"))`,
/// no `appID` — MUST still poll the backend: the wire request carries
/// `app_key` and the backend resolves it server-side. (Guarding remote checks
/// on `appID` used to silently no-op exactly this integration, leaving the
/// console quickstart stuck on "Waiting for your app to check in…" forever.)
final class AppKeyOnlyConfigurationTests: XCTestCase {

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-appkey-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Captures every request body sent to a path suffix.
    private final class BodyCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []
        func record(_ d: Data?) { guard let d else { return }; lock.lock(); bodies.append(d); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return bodies.count }
        func json(at i: Int) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            guard i < bodies.count else { return nil }
            return (try? JSONSerialization.jsonObject(with: bodies[i])) as? [String: Any]
        }
    }

    private struct RoutingTransport: HTTPTransport {
        let route: @Sendable (URLRequest) -> (Data, Int)
        func send(_ request: URLRequest) async throws -> (Data, Int) { route(request) }
    }

    private func makePatch(
        appID: String?, checks: BodyCollector, events: BodyCollector,
        checkStatus: Int = 200, dir: URL
    ) throws -> Patch {
        let noUpdate = try JSONEncoder().encode(UpdateCheckResponse(has_update: false))
        let transport = RoutingTransport { req in
            let p = req.url?.absoluteString ?? ""
            if p.hasSuffix("/modules/check") {
                checks.record(req.httpBody)
                return (noUpdate, checkStatus)
            }
            if p.hasSuffix("/events") {
                events.record(req.httpBody)
                return (Data(), 201)
            }
            return (Data(), 404)
        }
        let storage = try ModuleStorage(appKey: "pak_test_key", baseDirectory: dir)
        let checker = UpdateChecker(
            baseURL: URL(string: "https://api.test/api/v1")!, transport: transport)
        let patch = Patch()
        patch.injectForTesting(
            configuration: PatchConfiguration(
                appKey: "pak_test_key", appID: appID,
                apiBaseURL: URL(string: "https://api.test/api/v1")!,
                deviceID: "dev-key-only"),
            storage: storage, checker: checker)
        return patch
    }

    func testStartPollsWithAppKeyOnly() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let checks = BodyCollector(); let events = BodyCollector()
        let patch = try makePatch(appID: nil, checks: checks, events: events, dir: dir)

        _ = await patch.start()

        XCTAssertEqual(checks.count, 1, "appKey-only configure must still hit /modules/check")
        let body = try XCTUnwrap(checks.json(at: 0))
        XCTAssertEqual(body["app_key"] as? String, "pak_test_key")
        XCTAssertNil(body["app_id"], "no appID configured → field omitted from the wire")
        XCTAssertEqual(body["device_id"] as? String, "dev-key-only")
    }

    func testCheckCarriesBothIdentifiersWhenConfigured() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let checks = BodyCollector(); let events = BodyCollector()
        let appID = "33333333-3333-3333-3333-333333333333"
        let patch = try makePatch(appID: appID, checks: checks, events: events, dir: dir)

        _ = await patch.start()

        let body = try XCTUnwrap(checks.json(at: 0))
        XCTAssertEqual(body["app_id"] as? String, appID)
        XCTAssertEqual(body["app_key"] as? String, "pak_test_key")
    }

    func testImperativeCheckForUpdateWorksWithAppKeyOnly() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let checks = BodyCollector(); let events = BodyCollector()
        let patch = try makePatch(appID: nil, checks: checks, events: events, dir: dir)

        // Used to throw UpdateError.notConfigured purely because appID was nil.
        let info = try await patch.checkForUpdate()
        XCTAssertNil(info) // backend said no update
        XCTAssertEqual(checks.count, 1)
    }

    func testErrorTelemetryCarriesAppKeyOnly() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let checks = BodyCollector(); let events = BodyCollector()
        // 500 on check → the error event must still identify the app by key.
        let patch = try makePatch(
            appID: nil, checks: checks, events: events, checkStatus: 500, dir: dir)

        _ = await patch.start()

        XCTAssertEqual(events.count, 1, "check failure must report an error event")
        let body = try XCTUnwrap(events.json(at: 0))
        XCTAssertEqual(body["event_type"] as? String, "error")
        XCTAssertEqual(body["app_key"] as? String, "pak_test_key")
        XCTAssertNil(body["app_id"])
    }
}
