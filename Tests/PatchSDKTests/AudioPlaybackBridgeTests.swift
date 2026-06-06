import XCTest
import WasmKit
@testable import PatchSDK

/// AudioPlaybackBridge — `AVAudioPlayer` play/stop/volume routed through injected
/// closures. Volume crosses the ABI as a 0...100 percent. Two layers:
///   1. Pure helpers (`normalizePath` / `clampPercent` / `percentToUnit`), the
///      single source of truth, tested directly.
///   2. The dispatch seams (`playPayload` / `stopPayload` / `setVolumePayload`)
///      the host fns run, exercised with spies recording path / stop / volume.
/// No real AVFoundation / wasm fixture required.
final class AudioPlaybackBridgeTests: XCTestCase {

    // MARK: - Pure helpers

    func testNormalizePathTrimsAndRejectsEmpty() {
        XCTAssertEqual(AudioPlaybackBridge.normalizePath("/tmp/a.caf"), "/tmp/a.caf")
        XCTAssertEqual(AudioPlaybackBridge.normalizePath("  /tmp/a.caf  "), "/tmp/a.caf")
        XCTAssertNil(AudioPlaybackBridge.normalizePath(""))
        XCTAssertNil(AudioPlaybackBridge.normalizePath("   "))
        XCTAssertNil(AudioPlaybackBridge.normalizePath("\n\t"))
    }

    func testClampPercent() {
        XCTAssertEqual(AudioPlaybackBridge.clampPercent(0), 0)
        XCTAssertEqual(AudioPlaybackBridge.clampPercent(100), 100)
        XCTAssertEqual(AudioPlaybackBridge.clampPercent(-1), 0)
        XCTAssertEqual(AudioPlaybackBridge.clampPercent(140), 100)
    }

    func testPercentToUnit() {
        XCTAssertEqual(AudioPlaybackBridge.percentToUnit(0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(AudioPlaybackBridge.percentToUnit(75), 0.75, accuracy: 1e-9)
        XCTAssertEqual(AudioPlaybackBridge.percentToUnit(100), 1.0, accuracy: 1e-9)
        XCTAssertEqual(AudioPlaybackBridge.percentToUnit(-50), 0.0, accuracy: 1e-9, "clamps first")
        XCTAssertEqual(AudioPlaybackBridge.percentToUnit(200), 1.0, accuracy: 1e-9, "clamps first")
    }

    // MARK: - Spy-backed dispatch

    /// Records play paths, stop calls, and volume unit values; lets `play` return
    /// a canned success/failure.
    private final class AudioSpy: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var played: [String] = []
        private(set) var stops = 0
        private(set) var volumes: [Double] = []
        private let playResult: Bool
        init(playResult: Bool = true) { self.playResult = playResult }
        var play: AudioPlaybackBridge.Player {
            { [self] path in lock.lock(); played.append(path); lock.unlock(); return playResult }
        }
        var stop: AudioPlaybackBridge.Stopper {
            { [self] in lock.lock(); stops += 1; lock.unlock() }
        }
        var setVolume: AudioPlaybackBridge.VolumeSetter {
            { [self] u in lock.lock(); volumes.append(u); lock.unlock() }
        }
    }

    private func makeBridge(_ spy: AudioSpy) -> AudioPlaybackBridge {
        AudioPlaybackBridge(play: spy.play, stop: spy.stop, setVolume: spy.setVolume)
    }

    /// A valid path is trimmed and forwarded; the player's success returns 1.
    func testPlayForwardsTrimmedPathAndReturnsStarted() {
        let spy = AudioSpy(playResult: true)
        let bridge = makeBridge(spy)
        XCTAssertEqual(bridge.playPayload(rawPath: "  /sfx/ping.caf "), 1)
        XCTAssertEqual(spy.played, ["/sfx/ping.caf"])
    }

    /// A player failure returns 0 (but the player WAS consulted).
    func testPlayFailureReturnsZero() {
        let spy = AudioSpy(playResult: false)
        let bridge = makeBridge(spy)
        XCTAssertEqual(bridge.playPayload(rawPath: "/sfx/ping.caf"), 0)
        XCTAssertEqual(spy.played, ["/sfx/ping.caf"], "player still consulted")
    }

    /// An empty/whitespace path returns 0 WITHOUT consulting the player.
    func testPlayInvalidPathSkipsPlayer() {
        let spy = AudioSpy()
        let bridge = makeBridge(spy)
        XCTAssertEqual(bridge.playPayload(rawPath: "   "), 0)
        XCTAssertTrue(spy.played.isEmpty, "invalid path must not reach the player")
    }

    func testStopForwards() {
        let spy = AudioSpy()
        let bridge = makeBridge(spy)
        bridge.stopPayload()
        bridge.stopPayload()
        XCTAssertEqual(spy.stops, 2)
    }

    /// Volume percents are clamped + converted to unit values for the setter.
    func testSetVolumeConvertsAndClamps() {
        let spy = AudioSpy()
        let bridge = makeBridge(spy)
        bridge.setVolumePayload(percent: 50)
        bridge.setVolumePayload(percent: 300)   // clamps to 100 → 1.0
        bridge.setVolumePayload(percent: -20)    // clamps to 0 → 0.0
        XCTAssertEqual(spy.volumes.count, 3)
        XCTAssertEqual(spy.volumes[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(spy.volumes[1], 1.0, accuracy: 1e-9)
        XCTAssertEqual(spy.volumes[2], 0.0, accuracy: 1e-9)
    }

    // MARK: - Bridge shape / registration

    func testModuleNamespaceAndRegistration() {
        let bridge = makeBridge(AudioSpy())
        XCTAssertEqual(bridge.module, "patch")
        XCTAssertNotNil(BridgeRegistry().register(bridge).hostImports())
    }

    #if canImport(AVFoundation)
    func testDefaultInitRegisters() {
        XCTAssertNotNil(BridgeRegistry().register(AudioPlaybackBridge()).hostImports())
    }
    #endif
}
