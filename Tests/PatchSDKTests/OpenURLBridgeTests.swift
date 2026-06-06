import XCTest
import WasmKit
@testable import PatchSDK

/// OpenURLBridge — external links / deep links.
///
/// Two layers under test:
///   1. `OpenURLBridge.isValidURL` — the pure validation gate (rejects empty /
///      garbage, requires a scheme). Tested directly with deterministic inputs.
///   2. The registered host functions `patch.open_url` / `patch.can_open_url`,
///      driven guest -> host through a tiny SELF-CONTAINED wasm module embedded
///      below (no shared fixture / no rebuild). Spies record the requested URLs
///      and return canned bools; we assert decode + dispatch + the i32 result.
final class OpenURLBridgeTests: XCTestCase {

    // MARK: - Embedded fixture
    //
    // A 212-byte hand-written module (see the WAT in this file's header comment)
    // that imports `patch.open_url` / `patch.can_open_url` and exports
    // `call_open_url` / `call_can_open_url` plus `memory` + `patch_malloc`, so a
    // test can write a URL into guest memory and round-trip through the bridge.
    //
    // WAT source:
    //   (module
    //     (import "patch" "open_url"     (func $open (param i32 i32) (result i32)))
    //     (import "patch" "can_open_url" (func $can  (param i32 i32) (result i32)))
    //     (memory (export "memory") 1)
    //     (global $bump (mut i32) (i32.const 1024))
    //     (func $patch_malloc (export "patch_malloc") (param $n i32) (result i32)
    //       (local $p i32)
    //       (local.set $p (global.get $bump))
    //       (global.set $bump
    //         (i32.and (i32.add (i32.add (global.get $bump) (local.get $n)) (i32.const 7))
    //                  (i32.const -8)))
    //       (local.get $p))
    //     (func $patch_free (export "patch_free") (param i32))
    //     (func (export "call_open_url") (param i32 i32) (result i32)
    //       (call $open (local.get 0) (local.get 1)))
    //     (func (export "call_can_open_url") (param i32 i32) (result i32)
    //       (call $can (local.get 0) (local.get 1))))
    private static let fixtureBytes: [UInt8] = [
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03, 0x60,
        0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x01,
        0x7f, 0x00, 0x02, 0x27, 0x02, 0x05, 0x70, 0x61, 0x74, 0x63, 0x68, 0x08,
        0x6f, 0x70, 0x65, 0x6e, 0x5f, 0x75, 0x72, 0x6c, 0x00, 0x00, 0x05, 0x70,
        0x61, 0x74, 0x63, 0x68, 0x0c, 0x63, 0x61, 0x6e, 0x5f, 0x6f, 0x70, 0x65,
        0x6e, 0x5f, 0x75, 0x72, 0x6c, 0x00, 0x00, 0x03, 0x05, 0x04, 0x01, 0x02,
        0x00, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x06, 0x07, 0x01, 0x7f, 0x01,
        0x41, 0x80, 0x08, 0x0b, 0x07, 0x4a, 0x05, 0x06, 0x6d, 0x65, 0x6d, 0x6f,
        0x72, 0x79, 0x02, 0x00, 0x0c, 0x70, 0x61, 0x74, 0x63, 0x68, 0x5f, 0x6d,
        0x61, 0x6c, 0x6c, 0x6f, 0x63, 0x00, 0x02, 0x0a, 0x70, 0x61, 0x74, 0x63,
        0x68, 0x5f, 0x66, 0x72, 0x65, 0x65, 0x00, 0x03, 0x0d, 0x63, 0x61, 0x6c,
        0x6c, 0x5f, 0x6f, 0x70, 0x65, 0x6e, 0x5f, 0x75, 0x72, 0x6c, 0x00, 0x04,
        0x11, 0x63, 0x61, 0x6c, 0x6c, 0x5f, 0x63, 0x61, 0x6e, 0x5f, 0x6f, 0x70,
        0x65, 0x6e, 0x5f, 0x75, 0x72, 0x6c, 0x00, 0x05, 0x0a, 0x2e, 0x04, 0x17,
        0x01, 0x01, 0x7f, 0x23, 0x00, 0x21, 0x01, 0x23, 0x00, 0x20, 0x00, 0x6a,
        0x41, 0x07, 0x6a, 0x41, 0x78, 0x71, 0x24, 0x00, 0x20, 0x01, 0x0b, 0x02,
        0x00, 0x0b, 0x08, 0x00, 0x20, 0x00, 0x20, 0x01, 0x10, 0x00, 0x0b, 0x08,
        0x00, 0x20, 0x00, 0x20, 0x01, 0x10, 0x01, 0x0b,
    ]

    /// Build a runtime over the embedded fixture with the given bridge.
    private func makeRuntime(_ bridge: OpenURLBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(bridge)
        return try WASMRuntime(bytes: Self.fixtureBytes, hostImports: registry.hostImports())
    }

    private func writeString(_ s: String, into rt: WASMRuntime) throws -> (UInt32, UInt32) {
        let (p, l) = try rt.writeBuffer([UInt8](s.utf8))
        return (p, l)
    }

    // MARK: - isValidURL (pure validation gate)

    func testIsValidURLAcceptsRealURLs() {
        XCTAssertTrue(OpenURLBridge.isValidURL("https://example.com"))
        XCTAssertTrue(OpenURLBridge.isValidURL("http://example.com/path?q=1#frag"))
        XCTAssertTrue(OpenURLBridge.isValidURL("mailto:hi@example.com"))
        XCTAssertTrue(OpenURLBridge.isValidURL("tel:+15551234567"))
        XCTAssertTrue(OpenURLBridge.isValidURL("myapp://profile/42"))      // deep link
        XCTAssertTrue(OpenURLBridge.isValidURL("  https://example.com  ")) // trimmed
    }

    func testIsValidURLRejectsEmptyAndGarbage() {
        XCTAssertFalse(OpenURLBridge.isValidURL(""))
        XCTAssertFalse(OpenURLBridge.isValidURL("   "))
        XCTAssertFalse(OpenURLBridge.isValidURL("\n\t"))
        XCTAssertFalse(OpenURLBridge.isValidURL("not a url"))   // space → not parseable
        XCTAssertFalse(OpenURLBridge.isValidURL("just-some-text"))  // no scheme
        XCTAssertFalse(OpenURLBridge.isValidURL("/relative/path"))  // no scheme
        XCTAssertFalse(OpenURLBridge.isValidURL("example.com"))     // bare host, no scheme
    }

    // MARK: - open_url dispatch (decode + dispatch + i32 result)

    func testOpenURLDispatchesAndReturnsResult() throws {
        let spy = URLSpy()
        let rt = try makeRuntime(OpenURLBridge(
            open: { url in spy.recordOpen(url); return true },
            canOpen: { url in spy.recordCan(url); return true }))

        let (p, l) = try writeString("https://example.com/welcome", into: rt)
        let res = try rt.invoke("call_open_url", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i32, 1, "opener returned true -> 1")
        XCTAssertEqual(spy.opened, ["https://example.com/welcome"],
                       "the exact decoded URL must be handed to the opener")
        XCTAssertTrue(spy.canChecked.isEmpty, "open_url must not invoke the canOpen closure")
    }

    func testOpenURLReturnsZeroWhenOpenerRejects() throws {
        let spy = URLSpy()
        let rt = try makeRuntime(OpenURLBridge(
            open: { url in spy.recordOpen(url); return false },
            canOpen: { _ in true }))

        let (p, l) = try writeString("myapp://deep/link", into: rt)
        let res = try rt.invoke("call_open_url", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i32, 0, "opener returned false -> 0")
        XCTAssertEqual(spy.opened, ["myapp://deep/link"])
    }

    func testOpenURLRejectsInvalidWithoutDispatch() throws {
        let spy = URLSpy()
        let rt = try makeRuntime(OpenURLBridge(
            open: { url in spy.recordOpen(url); return true },
            canOpen: { url in spy.recordCan(url); return true }))

        let (p, l) = try writeString("not a url", into: rt)
        let res = try rt.invoke("call_open_url", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i32, 0, "invalid URL -> 0 (rejected by isValidURL gate)")
        XCTAssertTrue(spy.opened.isEmpty, "invalid URL must NOT reach the opener closure")
    }

    // MARK: - can_open_url dispatch

    func testCanOpenURLDispatchesAndReturnsResult() throws {
        let spy = URLSpy()
        let rt = try makeRuntime(OpenURLBridge(
            open: { _ in true },
            canOpen: { url in spy.recordCan(url); return true }))

        let (p, l) = try writeString("tel:+15551234567", into: rt)
        let res = try rt.invoke("call_can_open_url", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i32, 1, "canOpen returned true -> 1")
        XCTAssertEqual(spy.canChecked, ["tel:+15551234567"])
        XCTAssertTrue(spy.opened.isEmpty, "can_open_url must not invoke the open closure")
    }

    func testCanOpenURLReturnsZeroWhenUnsupported() throws {
        let spy = URLSpy()
        let rt = try makeRuntime(OpenURLBridge(
            open: { _ in true },
            canOpen: { url in spy.recordCan(url); return false }))

        let (p, l) = try writeString("weirdscheme://x", into: rt)
        let res = try rt.invoke("call_can_open_url", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i32, 0, "canOpen returned false -> 0")
        XCTAssertEqual(spy.canChecked, ["weirdscheme://x"])
    }

    func testCanOpenURLRejectsInvalidWithoutDispatch() throws {
        let spy = URLSpy()
        let rt = try makeRuntime(OpenURLBridge(
            open: { _ in true },
            canOpen: { url in spy.recordCan(url); return true }))

        let (p, l) = try writeString("", into: rt)
        let res = try rt.invoke("call_can_open_url", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i32, 0, "empty URL -> 0 (rejected by gate)")
        XCTAssertTrue(spy.canChecked.isEmpty, "empty URL must NOT reach the canOpen closure")
    }
}

/// Thread-safe spy recording every URL the bridge requested through each closure.
private final class URLSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [String] = []
    private var _canChecked: [String] = []
    func recordOpen(_ url: String) { lock.lock(); _opened.append(url); lock.unlock() }
    func recordCan(_ url: String) { lock.lock(); _canChecked.append(url); lock.unlock() }
    var opened: [String] { lock.lock(); defer { lock.unlock() }; return _opened }
    var canChecked: [String] { lock.lock(); defer { lock.unlock() }; return _canChecked }
}
