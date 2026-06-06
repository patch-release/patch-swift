import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `CameraBridge` — capture a still photo (fire-and-forget).
///
/// Two layers (per the bridge guide):
///   1. `CapturePhotoRequest.parse(_:)` — the pure JSON decode + field
///      normalization, tested directly.
///   2. Dispatch — the registered `patch.capture_photo` host fn decodes the arg
///      and invokes the injected handler spy, driven through WasmKit via a
///      hand-built module (imports the host fn, exports `call_capture_photo`).
final class CameraBridgeTests: XCTestCase {

    // MARK: - CapturePhotoRequest.parse(_:)

    func testParseAllFields() {
        let req = CapturePhotoRequest.parse(Array(
            #"{"camera":"FRONT","flash":"on","quality":"high"}"#.utf8))
        XCTAssertEqual(req, CapturePhotoRequest(camera: "front", flash: "on", quality: "high"))
    }

    func testParseEmptyUsesDefaults() {
        let req = CapturePhotoRequest.parse(Array("{}".utf8))
        XCTAssertEqual(req, CapturePhotoRequest(camera: "back", flash: "auto", quality: "balanced"))
    }

    func testParseUnknownValuesFallBackToDefaults() {
        let req = CapturePhotoRequest.parse(Array(
            #"{"camera":"sideways","flash":"strobe","quality":"ultra"}"#.utf8))
        XCTAssertEqual(req, CapturePhotoRequest())   // all defaults
    }

    func testParseInvalidJSONIsAllDefaults() {
        XCTAssertEqual(CapturePhotoRequest.parse(Array("not json".utf8)), CapturePhotoRequest())
        XCTAssertEqual(CapturePhotoRequest.parse([]), CapturePhotoRequest())
    }

    func testNormalizeHelper() {
        XCTAssertEqual(CapturePhotoRequest.normalize(" Front ", allowed: ["front", "back"], default: "back"), "front")
        XCTAssertEqual(CapturePhotoRequest.normalize("nope", allowed: ["front", "back"], default: "back"), "back")
        XCTAssertEqual(CapturePhotoRequest.normalize(nil, allowed: ["front", "back"], default: "back"), "back")
    }

    // MARK: - Fixture (imports patch.capture_photo; exports call_capture_photo)

    private static let fixtureBase64 =
        "AGFzbQEAAAABDwNgAn9/AGABfwF/YAF/AAIXAQVwYXRjaA1jYXB0dXJlX3Bob3RvAAADBAMBAgAFAwEAAQYHAX8BQYAICwc7BAZtZW1vcnkCAAxwYXRjaF9tYWxsb2MAAQpwYXRjaF9mcmVlAAISY2FsbF9jYXB0dXJlX3Bob3RvAAMKJQMXAQF/IwAhASMAIABqQQdqQXhxJAAgAQsCAAsIACAAIAEQAAs="

    private func fixtureBytes() throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64)))
    }

    private func makeRuntime(_ spy: CameraSpy) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(CameraBridge(capture: { req in spy.record(req) }))
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    // MARK: - Dispatch

    func testCaptureDecodesAndForwards() throws {
        let spy = CameraSpy()
        let rt = try makeRuntime(spy)
        let (p, l) = try rt.writeBuffer([UInt8](#"{"camera":"front","flash":"off"}"#.utf8))
        let res = try rt.invoke("call_capture_photo", [.i32(p), .i32(l)])
        XCTAssertTrue(res.isEmpty, "capture returns no value")
        XCTAssertEqual(spy.captured.count, 1)
        XCTAssertEqual(spy.captured.first,
                       CapturePhotoRequest(camera: "front", flash: "off", quality: "balanced"))
    }

    func testCaptureBadPayloadStillFiresWithDefaults() throws {
        let spy = CameraSpy()
        let rt = try makeRuntime(spy)
        let (p, l) = try rt.writeBuffer([UInt8]("garbage".utf8))
        _ = try rt.invoke("call_capture_photo", [.i32(p), .i32(l)])
        XCTAssertEqual(spy.captured.count, 1, "bad payload still attempts a default capture")
        XCTAssertEqual(spy.captured.first, CapturePhotoRequest())
    }

    func testModuleNamespace() {
        XCTAssertEqual(CameraBridge(capture: { _ in }).module, "patch")
    }
}

/// Thread-safe spy recording the capture requests the bridge forwards.
private final class CameraSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _captured: [CapturePhotoRequest] = []
    func record(_ req: CapturePhotoRequest) { lock.lock(); _captured.append(req); lock.unlock() }
    var captured: [CapturePhotoRequest] { lock.lock(); defer { lock.unlock() }; return _captured }
}
