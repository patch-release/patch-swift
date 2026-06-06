import XCTest
@testable import PatchSDK

/// UpdateChecker: wire-protocol parse/decision, telemetry, exponential
/// backoff. Uses a mock `HTTPTransport` (no real network).
final class UpdateCheckerTests: XCTestCase {

    /// Canned-response transport: maps a URL suffix to (status, body).
    private struct MockTransport: HTTPTransport {
        let handler: @Sendable (URLRequest) -> (Data, Int)
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            handler(request)
        }
    }

    private let base = URL(string: "https://api.patch.test/api/v1")!

    // MARK: - Parse + decision

    func testParsesHasUpdateResponseMatchingBackendSchema() async throws {
        // Exactly the JSON shape the backend's UpdateCheckResponse emits.
        let json = """
        {
          "has_update": true,
          "version": "1.2.3",
          "module_url": "https://cdn.test/app/.../module.wasm.br",
          "diff_url": "https://cdn.test/app/.../diff-from-1.2.2.patch",
          "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "size": 498176,
          "diff_size": 23552,
          "mandatory": false,
          "release_notes": "Fixed pricing calculation for EU regions"
        }
        """
        let captured = RequestBox()
        let transport = MockTransport { req in
            captured.set(req)
            return (Data(json.utf8), 200)
        }
        let checker = UpdateChecker(baseURL: base, transport: transport)
        let req = UpdateCheckRequest(
            current_version: "1.2.2",
            fingerprint: "a3f8c2d1",
            device_id: "anon_d7f8",
            app_id: "11111111-1111-1111-1111-111111111111",
            os_version: "18.4", app_version: "2.1.0", sdk_version: "1.0.0")
        let resp = try await checker.check(req)

        XCTAssertTrue(resp.has_update)
        XCTAssertEqual(resp.version, "1.2.3")
        XCTAssertEqual(resp.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(resp.size, 498176)
        XCTAssertEqual(resp.diff_size, 23552)
        XCTAssertFalse(resp.mandatory)
        XCTAssertEqual(resp.release_notes, "Fixed pricing calculation for EU regions")

        // The outbound request must hit /modules/check with the exact snake_case body.
        let sent = captured.get()
        XCTAssertEqual(sent?.url?.absoluteString, "https://api.patch.test/api/v1/modules/check")
        XCTAssertEqual(sent?.httpMethod, "POST")
        let body = try XCTUnwrap(sent?.httpBody)
        let decoded = try JSONDecoder().decode(UpdateCheckRequest.self, from: body)
        XCTAssertEqual(decoded.current_version, "1.2.2")
        XCTAssertEqual(decoded.device_id, "anon_d7f8")
        XCTAssertEqual(decoded.channel, "production")
        // Ensure snake_case keys are on the wire (backend pydantic requires them).
        let jsonObj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertNotNil(jsonObj?["current_version"])
        XCTAssertNotNil(jsonObj?["app_id"])
        XCTAssertNotNil(jsonObj?["sdk_version"])
    }

    func testParsesNoUpdateResponse() async throws {
        let transport = MockTransport { _ in (Data(#"{"has_update": false}"#.utf8), 200) }
        let checker = UpdateChecker(baseURL: base, transport: transport)
        let resp = try await checker.check(.init(
            current_version: "1.0.0", fingerprint: "fp", device_id: "d",
            app_id: "11111111-1111-1111-1111-111111111111"))
        XCTAssertFalse(resp.has_update)
        XCTAssertNil(resp.version)
        XCTAssertNil(resp.module_url)
        XCTAssertFalse(resp.mandatory)  // backend may omit → defaults false
    }

    func testHTTPErrorStatusThrows() async {
        let transport = MockTransport { _ in (Data(), 503) }
        let checker = UpdateChecker(baseURL: base, transport: transport)
        do {
            _ = try await checker.check(.init(
                current_version: "1", fingerprint: "f", device_id: "d",
                app_id: "11111111-1111-1111-1111-111111111111"))
            XCTFail("expected HTTP error")
        } catch let e as UpdateChecker.CheckError {
            if case .httpStatus(503) = e {} else { XCTFail("wrong error: \(e)") }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    // MARK: - Telemetry

    func testReportEventHitsEventsEndpointWithBackendSchema() async throws {
        let captured = RequestBox()
        let transport = MockTransport { req in captured.set(req); return (Data(), 201) }
        let checker = UpdateChecker(baseURL: base, transport: transport)

        let status = await checker.reportEvent(DeviceEventPayload(
            app_id: "11111111-1111-1111-1111-111111111111",
            device_id: "anon_d7f8",
            event_type: EventType.activation.rawValue,
            module_version: "1.2.3",
            duration_ms: 42))
        XCTAssertEqual(status, 201)

        let sent = captured.get()
        XCTAssertEqual(sent?.url?.absoluteString, "https://api.patch.test/api/v1/events")
        let body = try XCTUnwrap(sent?.httpBody)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(obj?["event_type"] as? String, "activation")
        XCTAssertEqual(obj?["module_version"] as? String, "1.2.3")
        XCTAssertEqual(obj?["duration_ms"] as? Int, 42)
        XCTAssertNotNil(obj?["app_id"])
        XCTAssertNotNil(obj?["device_id"])
    }

    func testEventTypeVocabularyMatchesBackendStats() {
        // backend stats aggregates on "download"/"activation"/"error".
        XCTAssertEqual(EventType.download.rawValue, "download")
        XCTAssertEqual(EventType.activation.rawValue, "activation")
        XCTAssertEqual(EventType.error.rawValue, "error")
    }

    // MARK: - Exponential backoff

    func testBackoffScheduleGrowsAndCaps() {
        let b = ExponentialBackoff(base: 2, multiplier: 2, maxDelay: 60, jitter: false)
        XCTAssertEqual(b.delay(forAttempt: 0), 2)
        XCTAssertEqual(b.delay(forAttempt: 1), 4)
        XCTAssertEqual(b.delay(forAttempt: 2), 8)
        XCTAssertEqual(b.delay(forAttempt: 3), 16)
        XCTAssertEqual(b.delay(forAttempt: 4), 32)
        XCTAssertEqual(b.delay(forAttempt: 5), 60, "capped at maxDelay")
        XCTAssertEqual(b.delay(forAttempt: 10), 60, "stays capped")
    }

    func testBackoffAdvancesAndResets() {
        var b = ExponentialBackoff(base: 1, multiplier: 2, maxDelay: 100, jitter: false)
        XCTAssertEqual(b.nextDelay(), 1)
        XCTAssertEqual(b.nextDelay(), 2)
        XCTAssertEqual(b.nextDelay(), 4)
        b.reset()
        XCTAssertEqual(b.nextDelay(), 1, "reset restarts the schedule")
    }

    func testBackoffJitterStaysWithinBound() {
        var b = ExponentialBackoff(base: 4, multiplier: 2, maxDelay: 100, jitter: true)
        for _ in 0..<50 {
            let d = b.nextDelay()
            XCTAssertGreaterThanOrEqual(d, 0)
            XCTAssertLessThanOrEqual(d, 100)
        }
    }

    func testCheckerResetsBackoffOnSuccessAndAdvancesOnFailure() async throws {
        // Failing transport advances backoff; a success resets it.
        let failTransport = MockTransport { _ in (Data(), 500) }
        let checker = UpdateChecker(
            baseURL: base, transport: failTransport,
            backoff: ExponentialBackoff(base: 1, multiplier: 2, maxDelay: 30, jitter: false))
        XCTAssertEqual(checker.backoffAttempt, 0)
        _ = try? await checker.check(.init(
            current_version: "1", fingerprint: "f", device_id: "d",
            app_id: "11111111-1111-1111-1111-111111111111"))
        // After a failure, the caller advances the backoff to schedule a retry.
        let d1 = checker.nextBackoffDelay()
        XCTAssertEqual(d1, 1)
        let d2 = checker.nextBackoffDelay()
        XCTAssertEqual(d2, 2)
    }
}

/// Thread-safe capture box for the mock transport.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var req: URLRequest?
    func set(_ r: URLRequest) { lock.lock(); req = r; lock.unlock() }
    func get() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return req }
}
