import XCTest
import WasmKit
@testable import PatchSDK

/// AccessibilityBridge — host bridge for VoiceOver announcements + status.
///
/// Two layers under test:
///   1. Dispatch of `a11y_announce(ptr,len)`: the registered host function decodes
///      the guest string and invokes the injected announcer with it.
///   2. Dispatch of `a11y_voiceover_running() -> i32`: returns 1/0 from the
///      injected status reader.
///
/// Driven end-to-end through WasmKit with a tiny hand-built module (imports the
/// two `patch.a11y_*` functions, exports `call_announce(i32,i32)` / `call_vo()`
/// plus `memory`/`patch_malloc`/`patch_free`), so no shared fixture is touched and
/// the test runs on macOS without UIKit (spies stand in for UIAccessibility).
final class AccessibilityBridgeTests: XCTestCase {

    // Hand-written wasm (wat2wasm). See AccessibilityBridge for the host ABI.
    //   (import "patch" "a11y_announce" (func (param i32 i32)))
    //   (import "patch" "a11y_voiceover_running" (func (result i32)))
    //   exports: memory, patch_malloc (bump), patch_free,
    //            call_announce(i32 i32), call_vo() -> i32
    private static let fixture: [UInt8] = [
        0, 97, 115, 109, 1, 0, 0, 0, 1, 19, 4, 96, 2, 127, 127, 0, 96, 0, 1, 127, 96,
        1, 127, 1, 127, 96, 1, 127, 0, 2, 54, 2, 5, 112, 97, 116, 99, 104, 13,
        97, 49, 49, 121, 95, 97, 110, 110, 111, 117, 110, 99, 101, 0, 0, 5,
        112, 97, 116, 99, 104, 22, 97, 49, 49, 121, 95, 118, 111, 105, 99,
        101, 111, 118, 101, 114, 95, 114, 117, 110, 110, 105, 110, 103, 0, 1,
        3, 5, 4, 2, 3, 0, 1, 5, 3, 1, 0, 1, 6, 7, 1, 127, 1, 65, 128, 8, 11,
        7, 64, 5, 6, 109, 101, 109, 111, 114, 121, 2, 0, 12, 112, 97, 116, 99,
        104, 95, 109, 97, 108, 108, 111, 99, 0, 2, 10, 112, 97, 116, 99, 104,
        95, 102, 114, 101, 101, 0, 3, 13, 99, 97, 108, 108, 95, 97, 110, 110,
        111, 117, 110, 99, 101, 0, 4, 7, 99, 97, 108, 108, 95, 118, 111, 0, 5,
        10, 42, 4, 23, 1, 1, 127, 35, 0, 33, 1, 35, 0, 32, 0, 106, 65, 7, 106,
        65, 120, 113, 36, 0, 32, 1, 11, 2, 0, 11, 8, 0, 32, 0, 32, 1, 16, 0,
        11, 4, 0, 16, 1, 11,
    ]

    private func makeRuntime(_ bridge: AccessibilityBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(bridge)
        return try WASMRuntime(bytes: Self.fixture, hostImports: registry.hostImports())
    }

    // MARK: - announce dispatch

    func testAnnounceDecodesAndInvokes() throws {
        let spy = A11ySpy(voiceOver: false)
        let rt = try makeRuntime(AccessibilityBridge(
            announce: spy.announce, isVoiceOverRunning: spy.status))

        let (ptr, len) = try rt.writeBuffer([UInt8]("Loaded 5 new items".utf8))
        _ = try rt.invoke("call_announce", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.messages, ["Loaded 5 new items"])
    }

    func testAnnouncePreservesUnicode() throws {
        let spy = A11ySpy(voiceOver: false)
        let rt = try makeRuntime(AccessibilityBridge(
            announce: spy.announce, isVoiceOverRunning: spy.status))

        let (ptr, len) = try rt.writeBuffer([UInt8]("café 🎉 níce".utf8))
        _ = try rt.invoke("call_announce", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.messages, ["café 🎉 níce"])
    }

    func testAnnounceEmptyStringStillFires() throws {
        let spy = A11ySpy(voiceOver: false)
        let rt = try makeRuntime(AccessibilityBridge(
            announce: spy.announce, isVoiceOverRunning: spy.status))

        let (ptr, len) = try rt.writeBuffer([])
        _ = try rt.invoke("call_announce", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.messages, [""])
    }

    // MARK: - voiceover_running dispatch

    func testVoiceOverRunningReturnsOne() throws {
        let spy = A11ySpy(voiceOver: true)
        let rt = try makeRuntime(AccessibilityBridge(
            announce: spy.announce, isVoiceOverRunning: spy.status))

        let result = try rt.invoke("call_vo")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].i32, 1)
    }

    func testVoiceOverRunningReturnsZero() throws {
        let spy = A11ySpy(voiceOver: false)
        let rt = try makeRuntime(AccessibilityBridge(
            announce: spy.announce, isVoiceOverRunning: spy.status))

        let result = try rt.invoke("call_vo")
        XCTAssertEqual(result[0].i32, 0)
    }

    /// The internal accessor mirrors the registered host closure's status read.
    func testVoiceOverRunningAccessor() {
        let bridge = AccessibilityBridge(announce: { _ in }, isVoiceOverRunning: { true })
        XCTAssertTrue(bridge.voiceOverRunning())
    }

    #if canImport(UIKit)
    /// On UIKit platforms the default init wires real UIAccessibility; just prove
    /// it registers cleanly.
    func testDefaultInitRegistersOnUIKit() throws {
        let registry = BridgeRegistry().register(AccessibilityBridge())
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.fixture, hostImports: registry.hostImports()))
    }
    #endif
}

/// Thread-safe spy recording announced messages + a fixed VoiceOver status.
private final class A11ySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []
    private let voiceOver: Bool

    init(voiceOver: Bool) { self.voiceOver = voiceOver }

    var announce: AccessibilityBridge.Announce {
        { [self] msg in lock.lock(); _messages.append(msg); lock.unlock() }
    }
    var status: AccessibilityBridge.IsVoiceOverRunning {
        { [self] in voiceOver }
    }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return _messages }
}
