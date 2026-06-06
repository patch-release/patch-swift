import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `PhotoPickerBridge` — the iOS photo-picker host bridge.
///
/// Two layers, per the bridge implementation guide:
///   1. `parse(_:)` — the pure JSON→`PhotoPickerRequest` decode, tested directly
///      with deterministic inputs (defaults when missing, `limit` clamped to
///      `>= 1`, `filter` normalized to images/videos/any).
///   2. Dispatch — the registered `patch.present_photo_picker` host function
///      decodes the guest `(ptr,len)` arg and invokes the injected handler with
///      the right `PhotoPickerRequest`. Driven end-to-end through WasmKit via a
///      tiny hand-built module (imports `patch.present_photo_picker`, exports
///      `call_present_photo_picker`) so no shared fixture is touched and the test
///      runs on macOS without PhotosUI/UIKit.
final class PhotoPickerBridgeTests: XCTestCase {

    // MARK: - parse(_:) pure decode

    func testParseDefaultsWhenEmptyObject() {
        let req = PhotoPickerBridge.parse(Array("{}".utf8))
        XCTAssertEqual(req.limit, 1, "missing limit → default 1")
        XCTAssertEqual(req.filter, "images", "missing filter → default images")
    }

    func testParseBothPresent() {
        let req = PhotoPickerBridge.parse(Array(#"{"limit":3,"filter":"videos"}"#.utf8))
        XCTAssertEqual(req.limit, 3)
        XCTAssertEqual(req.filter, "videos")
    }

    func testParseLimitClampedAtLeastOne() {
        XCTAssertEqual(PhotoPickerBridge.parse(Array(#"{"limit":0}"#.utf8)).limit, 1,
                       "limit 0 clamps to 1")
        XCTAssertEqual(PhotoPickerBridge.parse(Array(#"{"limit":-5}"#.utf8)).limit, 1,
                       "negative limit clamps to 1")
    }

    func testParseLimitLargeValuePreserved() {
        XCTAssertEqual(PhotoPickerBridge.parse(Array(#"{"limit":50}"#.utf8)).limit, 50)
    }

    func testParseNonNumberLimitFallsBackToDefault() {
        // Non-number limit → default 1 (not a crash).
        XCTAssertEqual(PhotoPickerBridge.parse(Array(#"{"limit":"lots"}"#.utf8)).limit, 1)
        XCTAssertEqual(PhotoPickerBridge.parse(Array(#"{"limit":null}"#.utf8)).limit, 1)
    }

    func testParseFilterNormalizedCaseAndWhitespace() {
        XCTAssertEqual(PhotoPickerBridge.parse(Array(#"{"filter":"VIDEOS"}"#.utf8)).filter, "videos")
        XCTAssertEqual(PhotoPickerBridge.parse(Array(#"{"filter":"  Images  "}"#.utf8)).filter, "images")
        XCTAssertEqual(PhotoPickerBridge.parse(Array(#"{"filter":"Any"}"#.utf8)).filter, "any")
    }

    func testParseUnknownFilterFallsBackToImages() {
        XCTAssertEqual(PhotoPickerBridge.parse(Array(#"{"filter":"gifs"}"#.utf8)).filter, "images",
                       "unknown filter → default images")
    }

    func testParseNonStringFilterFallsBackToImages() {
        XCTAssertEqual(PhotoPickerBridge.parse(Array(#"{"filter":42}"#.utf8)).filter, "images")
    }

    func testParseInvalidJSONReturnsDefaults() {
        let req = PhotoPickerBridge.parse(Array("not json at all {".utf8))
        XCTAssertEqual(req.limit, 1)
        XCTAssertEqual(req.filter, "images")
    }

    func testParseNonObjectJSONReturnsDefaults() {
        // A top-level array (valid JSON, wrong shape) → all-defaults request.
        let req = PhotoPickerBridge.parse(Array(#"[1,2,3]"#.utf8))
        XCTAssertEqual(req.limit, 1)
        XCTAssertEqual(req.filter, "images")
    }

    func testParseEmptyBytesReturnsDefaults() {
        let req = PhotoPickerBridge.parse([])
        XCTAssertEqual(req, PhotoPickerRequest(limit: 1, filter: "images"))
    }

    // MARK: - normalizeFilter(_:) units

    func testNormalizeFilterNilDefaultsImages() {
        XCTAssertEqual(PhotoPickerBridge.normalizeFilter(nil), "images")
    }

    func testNormalizeFilterAcceptsAllThree() {
        XCTAssertEqual(PhotoPickerBridge.normalizeFilter("images"), "images")
        XCTAssertEqual(PhotoPickerBridge.normalizeFilter("videos"), "videos")
        XCTAssertEqual(PhotoPickerBridge.normalizeFilter("any"), "any")
    }

    // MARK: - Dispatch (guest -> host) through a hand-built module

    /// A minimal wasm module compiled from:
    ///   (module
    ///     (import "patch" "present_photo_picker" (func $present (param i32 i32)))
    ///     (memory (export "memory") 1)
    ///     (global $bump (mut i32) (i32.const 1024))
    ///     (func $patch_malloc (export "patch_malloc") (param $n i32) (result i32) … bump …)
    ///     (func $patch_free (export "patch_free") (param i32))
    ///     (func (export "call_present_photo_picker") (param i32 i32)
    ///       (call $present (local.get 0) (local.get 1))))
    /// It forwards (ptr,len) straight to the host `patch.present_photo_picker`
    /// import, exactly like the guest would. Embedded as base64 so the test is
    /// self-contained.
    private static let pickerFixtureBase64 =
        "AGFzbQEAAAABDwNgAn9/AGABfwF/YAF/AAIeAQVwYXRjaBRwcmVzZW50X3Bob3RvX3BpY2tlcgAAAwQDAQIABQMBAAEGBwF/AUGACAsHQgQGbWVtb3J5AgAMcGF0Y2hfbWFsbG9jAAEKcGF0Y2hfZnJlZQACGWNhbGxfcHJlc2VudF9waG90b19waWNrZXIAAwolAxcBAX8jACEBIwAgAGpBB2pBeHEkACABCwIACwgAIAAgARAACw=="

    private func pickerFixtureBytes() throws -> [UInt8] {
        let data = try XCTUnwrap(Data(base64Encoded: Self.pickerFixtureBase64))
        return [UInt8](data)
    }

    /// Build a runtime over the picker fixture with the given bridge installed.
    private func makeRuntime(_ bridge: PhotoPickerBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(bridge)
        return try WASMRuntime(bytes: try pickerFixtureBytes(), hostImports: registry.hostImports())
    }

    func testDispatchDecodesArgsAndInvokesHandler() throws {
        let spy = PickerSpy()
        let rt = try makeRuntime(PhotoPickerBridge(present: { spy.record($0) }))

        let json = #"{"limit":4,"filter":"any"}"#
        let (ptr, len) = try rt.writeBuffer([UInt8](json.utf8))
        _ = try rt.invoke("call_present_photo_picker", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first, PhotoPickerRequest(limit: 4, filter: "any"))
    }

    func testDispatchEmptyObjectFiresDefaults() throws {
        let spy = PickerSpy()
        let rt = try makeRuntime(PhotoPickerBridge(present: { spy.record($0) }))

        let (ptr, len) = try rt.writeBuffer([UInt8]("{}".utf8))
        _ = try rt.invoke("call_present_photo_picker", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first, PhotoPickerRequest(limit: 1, filter: "images"))
    }

    func testDispatchInvalidJSONStillFiresWithDefaults() throws {
        // Fire-and-forget: even garbage input invokes the handler (with defaults),
        // never throwing back into the guest.
        let spy = PickerSpy()
        let rt = try makeRuntime(PhotoPickerBridge(present: { spy.record($0) }))

        let (ptr, len) = try rt.writeBuffer([UInt8]("garbage".utf8))
        _ = try rt.invoke("call_present_photo_picker", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first, PhotoPickerRequest(limit: 1, filter: "images"))
    }
}

/// Thread-safe spy recording the `PhotoPickerRequest` the bridge handler is
/// invoked with.
private final class PickerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [PhotoPickerRequest] = []
    func record(_ request: PhotoPickerRequest) {
        lock.lock(); _calls.append(request); lock.unlock()
    }
    var calls: [PhotoPickerRequest] { lock.lock(); defer { lock.unlock() }; return _calls }
}
