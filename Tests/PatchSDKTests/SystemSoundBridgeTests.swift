import XCTest
import WasmKit
@testable import PatchSDK

/// SystemSoundBridge — host bridge for playing system sounds / vibrating.
///
/// The two host functions are fire-and-forget and take scalar args (no string
/// marshalling): `play_system_sound(i32)` (a SystemSoundID) and `vibrate()`.
/// We test the full guest -> host decode + dispatch path with a tiny hand-written
/// wasm module (`systemSoundFixtureBytes`, byte-for-byte from `wat2wasm`) that
/// imports the two `patch.*` host functions and exports `call_play(i32)` /
/// `call_vibrate()` trampolines. We register the bridge with recording spies,
/// invoke the exports, and assert the spies saw the decoded sound ID and the
/// vibrate count.
///
/// No real AudioToolbox is required — the `AudioServicesPlaySystemSound` wiring
/// lives behind the `#if canImport(AudioToolbox)` default init; tests inject
/// cross-platform spies.
final class SystemSoundBridgeTests: XCTestCase {

    // MARK: - Fixture (hand-written wasm; verified via wat2wasm)
    //
    // (module
    //   (import "patch" "play_system_sound" (func $play (param i32)))
    //   (import "patch" "vibrate"           (func $vibrate))
    //   (memory (export "memory") 1)
    //   (global $next (mut i32) (i32.const 1024))
    //   (func (export "patch_malloc") (param i32) (result i32) ...bump...)
    //   (func (export "patch_free")  (param i32))
    //   (func (export "call_play")    (param i32) (call $play (local.get 0)))
    //   (func (export "call_vibrate") (call $vibrate)))
    private static let systemSoundFixtureBytes: [UInt8] = [
        0, 97, 115, 109, 1, 0, 0, 0, 1, 13, 3, 96, 1, 127, 0, 96, 0, 0, 96, 1, 127, 1,
        127, 2, 43, 2, 5, 112, 97, 116, 99, 104, 17, 112, 108, 97, 121, 95, 115, 121,
        115, 116, 101, 109, 95, 115, 111, 117, 110, 100, 0, 0, 5, 112, 97, 116, 99,
        104, 7, 118, 105, 98, 114, 97, 116, 101, 0, 1, 3, 5, 4, 2, 0, 0, 1, 5, 3, 1, 0,
        1, 6, 7, 1, 127, 1, 65, 128, 8, 11, 7, 65, 5, 6, 109, 101, 109, 111, 114, 121,
        2, 0, 12, 112, 97, 116, 99, 104, 95, 109, 97, 108, 108, 111, 99, 0, 2, 10, 112,
        97, 116, 99, 104, 95, 102, 114, 101, 101, 0, 3, 9, 99, 97, 108, 108, 95, 112,
        108, 97, 121, 0, 4, 12, 99, 97, 108, 108, 95, 118, 105, 98, 114, 97, 116, 101,
        0, 5, 10, 40, 4, 23, 1, 1, 127, 35, 0, 33, 1, 35, 0, 32, 0, 106, 65, 7, 106,
        65, 120, 113, 36, 0, 32, 1, 11, 2, 0, 11, 6, 0, 32, 0, 16, 0, 11, 4, 0, 16, 1,
        11,
    ]

    /// Build a runtime over the system-sound fixture with the bridge spy installed.
    private func makeRuntime(_ bridge: SystemSoundBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry()
        registry.register(bridge)
        return try WASMRuntime(bytes: Self.systemSoundFixtureBytes, hostImports: registry.hostImports())
    }

    // MARK: - play_system_sound decode + dispatch

    func testPlayDispatchDecodesSoundID() throws {
        let spy = SystemSoundSpy()
        let rt = try makeRuntime(SystemSoundBridge(play: spy.play, vibrate: spy.vibrate))

        _ = try rt.invoke("call_play", [.i32(1007)])
        _ = try rt.invoke("call_play", [.i32(1304)])
        _ = try rt.invoke("call_play", [.i32(0)])

        XCTAssertEqual(spy.soundIDs, [1007, 1304, 0])
        XCTAssertEqual(spy.vibrateCount, 0)
    }

    /// A full-range SystemSoundID (top bit set) round-trips as an unsigned i32.
    func testPlayDispatchPreservesHighBitSoundID() throws {
        let spy = SystemSoundSpy()
        let rt = try makeRuntime(SystemSoundBridge(play: spy.play, vibrate: spy.vibrate))

        _ = try rt.invoke("call_play", [.i32(0xFFFF_FFFF)])

        XCTAssertEqual(spy.soundIDs, [0xFFFF_FFFF])
    }

    // MARK: - vibrate dispatch

    func testVibrateDispatchIncrementsCount() throws {
        let spy = SystemSoundSpy()
        let rt = try makeRuntime(SystemSoundBridge(play: spy.play, vibrate: spy.vibrate))

        _ = try rt.invoke("call_vibrate")
        _ = try rt.invoke("call_vibrate")
        _ = try rt.invoke("call_vibrate")

        XCTAssertEqual(spy.vibrateCount, 3)
        XCTAssertEqual(spy.soundIDs, [])
    }

    /// Both host functions interleave correctly through one runtime, preserving order.
    func testMixedDispatchOrderingPreserved() throws {
        let spy = SystemSoundSpy()
        let rt = try makeRuntime(SystemSoundBridge(play: spy.play, vibrate: spy.vibrate))

        _ = try rt.invoke("call_play", [.i32(1007)])
        _ = try rt.invoke("call_vibrate")
        _ = try rt.invoke("call_play", [.i32(1106)])

        XCTAssertEqual(spy.soundIDs, [1007, 1106])
        XCTAssertEqual(spy.vibrateCount, 1)
    }

    #if canImport(AudioToolbox)
    /// On AudioToolbox platforms the default init must construct without spies (it
    /// wires the real `AudioServicesPlaySystemSound`). Just prove it registers cleanly.
    func testDefaultInitRegistersOnAudioToolbox() throws {
        let registry = BridgeRegistry()
        registry.register(SystemSoundBridge())
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.systemSoundFixtureBytes,
                                         hostImports: registry.hostImports()))
    }
    #endif
}

/// Thread-safe spy recording requested sound IDs (in call order) and a vibrate count.
private final class SystemSoundSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _soundIDs: [UInt32] = []
    private var _vibrateCount = 0

    var play: SystemSoundBridge.Play {
        { [self] soundID in
            lock.lock(); _soundIDs.append(soundID); lock.unlock()
        }
    }
    var vibrate: SystemSoundBridge.Vibrate {
        { [self] in
            lock.lock(); _vibrateCount += 1; lock.unlock()
        }
    }

    var soundIDs: [UInt32] { lock.lock(); defer { lock.unlock() }; return _soundIDs }
    var vibrateCount: Int { lock.lock(); defer { lock.unlock() }; return _vibrateCount }
}
