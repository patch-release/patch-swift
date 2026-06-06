import XCTest
import WasmKit
@testable import PatchSDK

/// HapticsBridge — host bridge for tactile feedback. Two layers under test:
///
///  1. The pure `normalize*` logic (single source of truth for valid style/type
///     strings; invalid → default), tested directly with deterministic inputs.
///  2. The full guest -> host decode + dispatch path: a tiny hand-written wasm
///     module (`hapticsFixtureBytes`, byte-for-byte from `wat2wasm`) imports the
///     three `patch.haptic_*` host functions and exports `call_*` trampolines.
///     We register the bridge with a recording spy, write the style/type string
///     into guest memory, invoke the export, and assert the spy saw the decoded
///     + normalized (event, variant) pair.
///
/// No real UIKit is required — the iOS `UIFeedbackGenerator` wiring lives behind
/// the `#if canImport(UIKit)` default init; tests inject a cross-platform spy.
final class HapticsBridgeTests: XCTestCase {

    // MARK: - Fixture (hand-written wasm; verified via wat2wasm)
    //
    // (module
    //   (import "patch" "haptic_impact"       (func (param i32 i32)))
    //   (import "patch" "haptic_notification" (func (param i32 i32)))
    //   (import "patch" "haptic_selection"    (func))
    //   (memory (export "memory") 2)
    //   (func (export "patch_malloc") (param i32) (result i32) ...bump...)
    //   (func (export "patch_free")  (param i32))
    //   (func (export "call_impact")       (param i32 i32) (call $imp ...))
    //   (func (export "call_notification") (param i32 i32) (call $notif ...))
    //   (func (export "call_selection")    (call $sel)))
    private static let hapticsFixtureBytes: [UInt8] = [
        0, 97, 115, 109, 1, 0, 0, 0, 1, 18, 4, 96, 2, 127, 127, 0,
        96, 0, 0, 96, 1, 127, 1, 127, 96, 1, 127, 0, 2, 76, 3, 5,
        112, 97, 116, 99, 104, 13, 104, 97, 112, 116, 105, 99, 95, 105, 109, 112,
        97, 99, 116, 0, 0, 5, 112, 97, 116, 99, 104, 19, 104, 97, 112, 116,
        105, 99, 95, 110, 111, 116, 105, 102, 105, 99, 97, 116, 105, 111, 110, 0,
        0, 5, 112, 97, 116, 99, 104, 16, 104, 97, 112, 116, 105, 99, 95, 115,
        101, 108, 101, 99, 116, 105, 111, 110, 0, 1, 3, 6, 5, 2, 3, 0,
        0, 1, 5, 3, 1, 0, 2, 6, 7, 1, 127, 1, 65, 128, 8, 11,
        7, 89, 6, 6, 109, 101, 109, 111, 114, 121, 2, 0, 12, 112, 97, 116,
        99, 104, 95, 109, 97, 108, 108, 111, 99, 0, 3, 10, 112, 97, 116, 99,
        104, 95, 102, 114, 101, 101, 0, 4, 11, 99, 97, 108, 108, 95, 105, 109,
        112, 97, 99, 116, 0, 5, 17, 99, 97, 108, 108, 95, 110, 111, 116, 105,
        102, 105, 99, 97, 116, 105, 111, 110, 0, 6, 14, 99, 97, 108, 108, 95,
        115, 101, 108, 101, 99, 116, 105, 111, 110, 0, 7, 10, 51, 5, 23, 1,
        1, 127, 35, 0, 33, 1, 35, 0, 32, 0, 106, 65, 7, 106, 65, 120,
        113, 36, 0, 32, 1, 11, 2, 0, 11, 8, 0, 32, 0, 32, 1, 16,
        0, 11, 8, 0, 32, 0, 32, 1, 16, 1, 11, 4, 0, 16, 2, 11,
    ]

    /// Build a runtime over the haptics fixture with the bridge spy installed.
    private func makeRuntime(_ bridge: HapticsBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry()
        registry.register(bridge)
        return try WASMRuntime(bytes: Self.hapticsFixtureBytes, hostImports: registry.hostImports())
    }

    /// Write `s` into guest memory and call `export` with its (ptr,len).
    private func fire(_ export: String, _ s: String, on rt: WASMRuntime) throws {
        let (p, l) = try rt.writeBuffer([UInt8](s.utf8))
        _ = try rt.invoke(export, [.i32(p), .i32(l)])
    }

    // MARK: - Pure normalization

    func testNormalizeImpactKeepsValidStyles() {
        for style in ["light", "medium", "heavy", "soft", "rigid"] {
            XCTAssertEqual(HapticsBridge.normalizeImpact(style), style)
        }
    }

    func testNormalizeImpactIsCaseInsensitive() {
        XCTAssertEqual(HapticsBridge.normalizeImpact("HEAVY"), "heavy")
        XCTAssertEqual(HapticsBridge.normalizeImpact("Soft"), "soft")
    }

    func testNormalizeImpactInvalidMapsToMedium() {
        // The required behavior: any invalid style → "medium".
        XCTAssertEqual(HapticsBridge.normalizeImpact("bogus"), "medium")
        XCTAssertEqual(HapticsBridge.normalizeImpact(""), "medium")
        XCTAssertEqual(HapticsBridge.normalizeImpact("ultra-heavy"), "medium")
        XCTAssertEqual(HapticsBridge.normalizeImpact("success"), "medium")
    }

    func testNormalizeNotificationKeepsValidTypes() {
        for type in ["success", "warning", "error"] {
            XCTAssertEqual(HapticsBridge.normalizeNotification(type), type)
        }
        XCTAssertEqual(HapticsBridge.normalizeNotification("ERROR"), "error")
    }

    func testNormalizeNotificationInvalidMapsToSuccess() {
        XCTAssertEqual(HapticsBridge.normalizeNotification("nope"), "success")
        XCTAssertEqual(HapticsBridge.normalizeNotification(""), "success")
        XCTAssertEqual(HapticsBridge.normalizeNotification("heavy"), "success")
    }

    // MARK: - Full decode + dispatch through a wasm instance

    func testImpactDispatchDecodesAndNormalizes() throws {
        let spy = HapticSpy()
        let rt = try makeRuntime(HapticsBridge(fire: spy.record))

        try fire("call_impact", "heavy", on: rt)
        try fire("call_impact", "light", on: rt)
        // Invalid style decoded off the guest, normalized to "medium".
        try fire("call_impact", "explosive", on: rt)

        XCTAssertEqual(spy.events, [
            .init(event: "impact", variant: "heavy"),
            .init(event: "impact", variant: "light"),
            .init(event: "impact", variant: "medium"),
        ])
    }

    func testNotificationDispatchDecodesAndNormalizes() throws {
        let spy = HapticSpy()
        let rt = try makeRuntime(HapticsBridge(fire: spy.record))

        try fire("call_notification", "warning", on: rt)
        try fire("call_notification", "error", on: rt)
        // Unknown type → "success".
        try fire("call_notification", "rigid", on: rt)

        XCTAssertEqual(spy.events, [
            .init(event: "notification", variant: "warning"),
            .init(event: "notification", variant: "error"),
            .init(event: "notification", variant: "success"),
        ])
    }

    func testSelectionDispatchHasNoVariant() throws {
        let spy = HapticSpy()
        let rt = try makeRuntime(HapticsBridge(fire: spy.record))

        _ = try rt.invoke("call_selection")
        _ = try rt.invoke("call_selection")

        XCTAssertEqual(spy.events, [
            .init(event: "selection", variant: ""),
            .init(event: "selection", variant: ""),
        ])
    }

    /// All three host functions interleave correctly through one runtime.
    func testMixedDispatchOrderingPreserved() throws {
        let spy = HapticSpy()
        let rt = try makeRuntime(HapticsBridge(fire: spy.record))

        try fire("call_impact", "soft", on: rt)
        _ = try rt.invoke("call_selection")
        try fire("call_notification", "success", on: rt)

        XCTAssertEqual(spy.events, [
            .init(event: "impact", variant: "soft"),
            .init(event: "selection", variant: ""),
            .init(event: "notification", variant: "success"),
        ])
    }

    #if canImport(UIKit)
    /// On UIKit platforms the default init must construct without a spy (it wires
    /// the real feedback generators). Just prove it registers cleanly.
    func testDefaultInitRegistersOnUIKit() throws {
        let registry = BridgeRegistry()
        registry.register(HapticsBridge())
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.hapticsFixtureBytes,
                                         hostImports: registry.hostImports()))
    }
    #endif
}

/// Thread-safe spy recording (event, variant) pairs in call order.
private final class HapticSpy: @unchecked Sendable {
    struct Event: Equatable, Sendable { let event: String; let variant: String }
    private let lock = NSLock()
    private var _events: [Event] = []
    var record: HapticsBridge.Fire {
        { [self] event, variant in
            lock.lock(); _events.append(.init(event: event, variant: variant)); lock.unlock()
        }
    }
    var events: [Event] { lock.lock(); defer { lock.unlock() }; return _events }
}
