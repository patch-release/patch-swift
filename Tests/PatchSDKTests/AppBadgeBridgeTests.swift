import XCTest
import WasmKit
@testable import PatchSDK

/// AppBadgeBridge — host bridge for the app icon badge number. Two layers under
/// test:
///
///  1. The pure `clamp(_:)` logic (negative counts collapse to 0 / clear),
///     tested directly with deterministic inputs.
///  2. The full guest -> host decode + dispatch path: a tiny hand-written wasm
///     module (`fixtureWasm`, byte-for-byte from `wat2wasm`) imports the two
///     `patch.set_badge` / `patch.get_badge` host functions and exports
///     `call_set_badge(i32)` / `call_get_badge() -> i32` trampolines. We register
///     the bridge with spies backed by a single in-memory Int and assert the
///     set/get round-trip — including that negative inputs clamp to 0.
///
/// No real UIKit is required — the iOS `UIApplication.applicationIconBadgeNumber`
/// wiring lives behind the `#if canImport(UIKit)` default init; tests inject a
/// cross-platform spy.
final class AppBadgeBridgeTests: XCTestCase {

    // MARK: - Fixture (hand-written wasm; verified via wat2wasm)
    //
    // (module
    //   (import "patch" "set_badge" (func $set (param i32)))
    //   (import "patch" "get_badge" (func $get (result i32)))
    //   (func (export "call_set_badge") (param i32) local.get 0 call $set)
    //   (func (export "call_get_badge") (result i32) call $get))
    private static let fixtureWasm: [UInt8] = [
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x09, 0x02, 0x60,
        0x01, 0x7f, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x02, 0x25, 0x02, 0x05, 0x70,
        0x61, 0x74, 0x63, 0x68, 0x09, 0x73, 0x65, 0x74, 0x5f, 0x62, 0x61, 0x64,
        0x67, 0x65, 0x00, 0x00, 0x05, 0x70, 0x61, 0x74, 0x63, 0x68, 0x09, 0x67,
        0x65, 0x74, 0x5f, 0x62, 0x61, 0x64, 0x67, 0x65, 0x00, 0x01, 0x03, 0x03,
        0x02, 0x00, 0x01, 0x07, 0x23, 0x02, 0x0e, 0x63, 0x61, 0x6c, 0x6c, 0x5f,
        0x73, 0x65, 0x74, 0x5f, 0x62, 0x61, 0x64, 0x67, 0x65, 0x00, 0x02, 0x0e,
        0x63, 0x61, 0x6c, 0x6c, 0x5f, 0x67, 0x65, 0x74, 0x5f, 0x62, 0x61, 0x64,
        0x67, 0x65, 0x00, 0x03, 0x0a, 0x0d, 0x02, 0x06, 0x00, 0x20, 0x00, 0x10,
        0x00, 0x0b, 0x04, 0x00, 0x10, 0x01, 0x0b,
    ]

    /// In-memory badge store backing the injected setter/getter (mirrors what the
    /// real UIApplication badge property does). Thread-safe.
    private final class BadgeStore: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int32 = 0
        var set: AppBadgeBridge.Setter {
            { [self] count in lock.lock(); _value = Int32(clamping: count); lock.unlock() }
        }
        var get: AppBadgeBridge.Getter {
            { [self] in lock.lock(); defer { lock.unlock() }; return _value }
        }
        /// Direct read of the backing value (what the bridge stored).
        var value: Int32 { lock.lock(); defer { lock.unlock() }; return _value }
    }

    private func makeRuntime(_ store: BadgeStore) throws -> WASMRuntime {
        let bridge = AppBadgeBridge(set: store.set, get: store.get)
        let registry = BridgeRegistry().register(bridge)
        return try WASMRuntime(bytes: Self.fixtureWasm, hostImports: registry.hostImports())
    }

    /// Drive the guest `call_set_badge(count)` export.
    private func setBadge(_ count: Int32, on rt: WASMRuntime) throws {
        _ = try rt.invoke("call_set_badge", [.i32(UInt32(bitPattern: count))])
    }

    /// Drive the guest `call_get_badge() -> i32` export.
    private func getBadge(on rt: WASMRuntime) throws -> Int32 {
        let results = try rt.invoke("call_get_badge")
        guard results.count == 1 else { return -999 }
        return Int32(bitPattern: results[0].i32)
    }

    // MARK: - Pure clamp logic

    func testClampKeepsZeroAndPositive() {
        XCTAssertEqual(AppBadgeBridge.clamp(0), 0)
        XCTAssertEqual(AppBadgeBridge.clamp(1), 1)
        XCTAssertEqual(AppBadgeBridge.clamp(7), 7)
        XCTAssertEqual(AppBadgeBridge.clamp(9999), 9999)
        XCTAssertEqual(AppBadgeBridge.clamp(Int(Int32.max)), Int(Int32.max))
    }

    func testClampCollapsesNegativeToZero() {
        XCTAssertEqual(AppBadgeBridge.clamp(-1), 0)
        XCTAssertEqual(AppBadgeBridge.clamp(-5), 0)
        XCTAssertEqual(AppBadgeBridge.clamp(Int(Int32.min)), 0)
    }

    // MARK: - Full decode + dispatch through a wasm instance

    /// set then get must round-trip the same value through the guest -> host ABI.
    func testSetGetRoundTrip() throws {
        let store = BadgeStore()
        let rt = try makeRuntime(store)

        XCTAssertEqual(try getBadge(on: rt), 0, "starts cleared")

        try setBadge(5, on: rt)
        XCTAssertEqual(store.value, 5, "host setter stored the value")
        XCTAssertEqual(try getBadge(on: rt), 5, "guest reads back what it set")

        try setBadge(42, on: rt)
        XCTAssertEqual(try getBadge(on: rt), 42)
    }

    /// Setting 0 clears the badge.
    func testZeroClearsBadge() throws {
        let store = BadgeStore()
        let rt = try makeRuntime(store)

        try setBadge(9, on: rt)
        XCTAssertEqual(try getBadge(on: rt), 9)

        try setBadge(0, on: rt)
        XCTAssertEqual(store.value, 0)
        XCTAssertEqual(try getBadge(on: rt), 0, "0 clears the badge")
    }

    /// Negative inputs from the guest clamp to 0 at the host boundary, so a
    /// subsequent get returns 0 (never a negative badge).
    func testNegativeInputClampsToZero() throws {
        let store = BadgeStore()
        let rt = try makeRuntime(store)

        try setBadge(8, on: rt)
        XCTAssertEqual(try getBadge(on: rt), 8)

        try setBadge(-1, on: rt)
        XCTAssertEqual(store.value, 0, "negative clamps to 0 before reaching the setter")
        XCTAssertEqual(try getBadge(on: rt), 0)

        try setBadge(-9999, on: rt)
        XCTAssertEqual(try getBadge(on: rt), 0, "large negative also clamps to 0")
    }

    // MARK: - Bridge shape

    /// The bridge's module namespace + ABI shape (set takes an i32, get returns one).
    func testModuleNamespaceAndDispatch() throws {
        let store = BadgeStore()
        let bridge = AppBadgeBridge(set: store.set, get: store.get)
        XCTAssertEqual(bridge.module, "patch")

        let rt = try WASMRuntime(bytes: Self.fixtureWasm,
                                 hostImports: BridgeRegistry().register(bridge).hostImports())
        // set returns no value to the guest; get returns exactly one i32.
        let setResults = try rt.invoke("call_set_badge", [.i32(3)])
        XCTAssertTrue(setResults.isEmpty, "set_badge returns no value")
        let getResults = try rt.invoke("call_get_badge")
        XCTAssertEqual(getResults.count, 1, "get_badge returns one i32")
        XCTAssertEqual(Int32(bitPattern: getResults[0].i32), 3)
    }

    #if canImport(UIKit)
    /// On UIKit platforms the default init must construct without spies (it wires
    /// the real UIApplication badge property). Just prove it registers cleanly.
    func testDefaultInitRegistersOnUIKit() throws {
        let registry = BridgeRegistry().register(AppBadgeBridge())
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.fixtureWasm,
                                         hostImports: registry.hostImports()))
    }
    #endif
}
