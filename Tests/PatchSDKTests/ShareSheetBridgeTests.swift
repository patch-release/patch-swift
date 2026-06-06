import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `ShareSheetBridge` — the iOS share-sheet host bridge.
///
/// Two layers, per the bridge implementation guide:
///   1. `parse(_:)` — the pure JSON→(text,url) decode, tested directly with
///      deterministic inputs (missing keys → nil, both present, etc.).
///   2. Dispatch — the registered `patch.share` host function decodes the
///      guest `(ptr,len)` arg and invokes the injected handler with the right
///      (text,url). Driven end-to-end through WasmKit via a tiny hand-built
///      module (imports `patch.share`, exports `call_share`) so no shared
///      fixture is touched and the test runs on macOS without UIKit.
final class ShareSheetBridgeTests: XCTestCase {

    // MARK: - parse(_:) pure decode

    func testParseBothPresent() {
        let (text, url) = ShareSheetBridge.parse(
            Array(#"{"text":"hello","url":"https://example.com"}"#.utf8))
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(url, "https://example.com")
    }

    func testParseTextOnly() {
        let (text, url) = ShareSheetBridge.parse(Array(#"{"text":"just text"}"#.utf8))
        XCTAssertEqual(text, "just text")
        XCTAssertNil(url, "missing url key → nil")
    }

    func testParseURLOnly() {
        let (text, url) = ShareSheetBridge.parse(Array(#"{"url":"https://patch.dev"}"#.utf8))
        XCTAssertNil(text, "missing text key → nil")
        XCTAssertEqual(url, "https://patch.dev")
    }

    func testParseEmptyObjectBothNil() {
        let (text, url) = ShareSheetBridge.parse(Array("{}".utf8))
        XCTAssertNil(text)
        XCTAssertNil(url)
    }

    func testParseNonStringValuesTreatedAsAbsent() {
        // Numeric / object / null values for the keys must decode as nil, not crash.
        let (text, url) = ShareSheetBridge.parse(
            Array(#"{"text":42,"url":{"nested":true}}"#.utf8))
        XCTAssertNil(text, "non-string text → nil")
        XCTAssertNil(url, "non-string url → nil")
    }

    func testParseInvalidJSONBothNil() {
        let (text, url) = ShareSheetBridge.parse(Array("not json at all {".utf8))
        XCTAssertNil(text)
        XCTAssertNil(url)
    }

    func testParseNonObjectJSONBothNil() {
        // A top-level array (valid JSON, wrong shape) → (nil, nil).
        let (text, url) = ShareSheetBridge.parse(Array(#"["text","url"]"#.utf8))
        XCTAssertNil(text)
        XCTAssertNil(url)
    }

    func testParseEmptyBytesBothNil() {
        let (text, url) = ShareSheetBridge.parse([])
        XCTAssertNil(text)
        XCTAssertNil(url)
    }

    func testParsePreservesUnicodeAndEmpties() {
        let (text, url) = ShareSheetBridge.parse(
            Array(#"{"text":"café 🎉","url":""}"#.utf8))
        XCTAssertEqual(text, "café 🎉")
        XCTAssertEqual(url, "", "explicit empty string is preserved (not nil)")
    }

    // MARK: - Dispatch (guest -> host) through a hand-built module

    /// A minimal wasm module compiled from:
    ///   (module
    ///     (import "patch" "share" (func $share (param i32 i32)))
    ///     (memory (export "memory") 1)
    ///     (global $bump (mut i32) (i32.const 1024))
    ///     (func $patch_malloc (export "patch_malloc") (param $n i32) (result i32) … bump …)
    ///     (func $patch_free (export "patch_free") (param i32))
    ///     (func (export "call_share") (param i32 i32)
    ///       (call $share (local.get 0) (local.get 1))))
    /// It forwards (ptr,len) straight to the host `patch.share` import, exactly
    /// like the guest would. Embedded as base64 so the test is self-contained.
    private static let shareFixtureBase64 =
        "AGFzbQEAAAABDwNgAn9/AGABfwF/YAF/AAIPAQVwYXRjaAVzaGFyZQAAAwQDAQIABQMBAAEGBwF/AUGACAsHMwQGbWVtb3J5AgAMcGF0Y2hfbWFsbG9jAAEKcGF0Y2hfZnJlZQACCmNhbGxfc2hhcmUAAwolAxcBAX8jACEBIwAgAGpBB2pBeHEkACABCwIACwgAIAAgARAACw=="

    private func shareFixtureBytes() throws -> [UInt8] {
        let data = try XCTUnwrap(Data(base64Encoded: Self.shareFixtureBase64))
        return [UInt8](data)
    }

    /// Build a runtime over the share fixture with the given bridge installed.
    private func makeRuntime(_ bridge: ShareSheetBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(bridge)
        return try WASMRuntime(bytes: try shareFixtureBytes(), hostImports: registry.hostImports())
    }

    func testDispatchDecodesArgsAndInvokesHandler() throws {
        let spy = ShareSpy()
        let rt = try makeRuntime(ShareSheetBridge(present: { text, url in spy.record(text: text, url: url) }))

        let json = #"{"text":"share me","url":"https://example.com/x"}"#
        let (ptr, len) = try rt.writeBuffer([UInt8](json.utf8))
        _ = try rt.invoke("call_share", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.text, "share me")
        XCTAssertEqual(spy.calls.first?.url, "https://example.com/x")
    }

    func testDispatchTextOnlyPassesNilURL() throws {
        let spy = ShareSpy()
        let rt = try makeRuntime(ShareSheetBridge(present: { text, url in spy.record(text: text, url: url) }))

        let (ptr, len) = try rt.writeBuffer([UInt8](#"{"text":"only text"}"#.utf8))
        _ = try rt.invoke("call_share", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.text, "only text")
        XCTAssertNil(spy.calls.first?.url)
    }

    func testDispatchInvalidJSONStillFiresWithBothNil() throws {
        // Fire-and-forget: even garbage input invokes the handler (with nils),
        // never throwing back into the guest.
        let spy = ShareSpy()
        let rt = try makeRuntime(ShareSheetBridge(present: { text, url in spy.record(text: text, url: url) }))

        let (ptr, len) = try rt.writeBuffer([UInt8]("garbage".utf8))
        _ = try rt.invoke("call_share", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertNil(spy.calls.first?.text)
        XCTAssertNil(spy.calls.first?.url)
    }
}

/// Thread-safe spy recording the (text,url) the bridge handler is invoked with.
private final class ShareSpy: @unchecked Sendable {
    struct Call: Sendable { let text: String?; let url: String? }
    private let lock = NSLock()
    private var _calls: [Call] = []
    func record(text: String?, url: String?) {
        lock.lock(); _calls.append(.init(text: text, url: url)); lock.unlock()
    }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
}
