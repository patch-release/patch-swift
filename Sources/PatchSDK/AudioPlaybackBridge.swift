import Foundation
import WasmKit
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - AudioPlayback bridge (AVAudioPlayer play / stop / volume)
//
// Plays a short local audio clip and controls its volume, routed through host
// closures backed by a single `AVAudioPlayer`. Suited to UI feedback sounds,
// short cues, and looping ambience an OTA patch wants to drive.
//
// Host functions (module "patch"):
//   * audio_play(pathPtr,pathLen) -> i32 — start playing the file at the given
//       local path; returns 1 if playback started, 0 on failure (missing file /
//       undecodable). A new play replaces any current one.
//   * audio_stop() -> []                 — stop playback and release the player.
//   * audio_set_volume(level: i32) -> [] — set volume from a 0...100 percent
//       (clamped); converted to AVAudioPlayer's 0.0...1.0 internally.
//
// Volume crosses the ABI as an integer PERCENT (0...100) so the guest never
// touches floats; the pure conversions (`clampPercent` / `percentToUnit`) are
// the single source of truth and unit-tested directly. Paths are validated by a
// pure `static func normalizePath(_:)` (rejects empty/whitespace) before reaching
// the native player.
//
// ## Cross-platform core + injected dependency (guide Rule 2)
// `AVAudioPlayer` is injected behind three `@Sendable` closures so the struct +
// its `register(...)` marshalling compile + unit-test on macOS without binding a
// real player at the top level. Tests inject spies (recording path / volume /
// stop) and assert the validate-then-dispatch path. The convenience `init()`
// wires a real `AVAudioPlayer` under `#if canImport(AVFoundation)` (AVFoundation
// is available on macOS too, but the bridge stays injectable for deterministic
// tests). AVFoundation does NOT re-export SwiftUI, so a plain import is safe.
public struct AudioPlaybackBridge: Bridge {
    /// Start playing the file at `path`. Returns true if playback started.
    public typealias Player = @Sendable (_ path: String) -> Bool
    /// Stop playback.
    public typealias Stopper = @Sendable () -> Void
    /// Set the volume from a unit value (0.0...1.0).
    public typealias VolumeSetter = @Sendable (_ unit: Double) -> Void

    public let module = "patch"
    private let play: Player
    private let stop: Stopper
    private let setVolume: VolumeSetter

    /// Cross-platform designated init — tests inject spies.
    public init(play: @escaping Player, stop: @escaping Stopper, setVolume: @escaping VolumeSetter) {
        self.play = play
        self.stop = stop
        self.setVolume = setVolume
    }

    #if canImport(AVFoundation)
    /// Convenience default init: wires a real `AVAudioPlayer`. A single player is
    /// held in a thread-safe box so `audio_play` replaces the current clip,
    /// `audio_stop` tears it down, and `audio_set_volume` adjusts the live player.
    /// Guarded by `canImport(AVFoundation)` so the cross-platform core compiles
    /// where AVFoundation is absent.
    public init() {
        let box = PlayerBox()
        self.init(
            play: { path in
                let url = URL(fileURLWithPath: path)
                guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
                box.set(player)
                player.prepareToPlay()
                return player.play()
            },
            stop: {
                box.get()?.stop()
                box.set(nil)
            },
            setVolume: { unit in
                box.get()?.volume = Float(unit)
            }
        )
    }
    #endif

    // MARK: - Pure helpers (single source of truth, unit-tested directly)

    /// Validate + normalize a requested path. Returns the trimmed path, or nil if
    /// empty/whitespace-only (nothing to play). Pure + directly unit-tested.
    public static func normalizePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Clamp a requested volume percent into 0...100.
    public static func clampPercent(_ percent: Int) -> Int {
        min(100, max(0, percent))
    }

    /// Convert a 0...100 integer percent to a 0.0...1.0 unit volume (clamped).
    public static func percentToUnit(_ percent: Int) -> Double {
        Double(clampPercent(percent)) / 100.0
    }

    // MARK: - Dispatch seams (what the host closures run; unit-tested directly)

    /// Validate the path and start playback via the injected player — exactly what
    /// `audio_play` does. Returns 0 for an invalid path (never consulting the
    /// player), else the player's started/failed result as 1/0. Factored out so
    /// the validate-then-dispatch path is unit-testable with a spy (no fixture).
    func playPayload(rawPath: String) -> Int32 {
        guard let path = Self.normalizePath(rawPath) else { return 0 }
        return play(path) ? 1 : 0
    }

    /// Stop playback via the injected stopper — exactly what `audio_stop` does.
    func stopPayload() { stop() }

    /// Clamp + convert a guest percent and push it to the injected volume setter —
    /// exactly what `audio_set_volume` does.
    func setVolumePayload(percent: Int) { setVolume(Self.percentToUnit(percent)) }

    public func register(into imports: inout Imports, store: Store) {
        let bridge = self

        // audio_play(path) -> i32 : 1 if playback started, 0 on invalid/failure.
        imports.host(module, "audio_play", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let raw = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [.i32(UInt32(bitPattern: bridge.playPayload(rawPath: raw)))]
        }
        // audio_stop() -> [] : stop + release.
        imports.host(module, "audio_stop", [], [], store: store) { _, _ in
            bridge.stopPayload()
            return []
        }
        // audio_set_volume(level) -> [] : clamp 0...100, convert to unit, apply.
        imports.host(module, "audio_set_volume", [.i32], [], store: store) { _, args in
            bridge.setVolumePayload(percent: Int(Int32(bitPattern: args[0].i32)))
            return []
        }
    }
}

#if canImport(AVFoundation)
/// Thread-safe holder for the single live `AVAudioPlayer` so the three host
/// closures (play / stop / set-volume) share one instance without a data race.
private final class PlayerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var player: AVAudioPlayer?
    func set(_ p: AVAudioPlayer?) { lock.lock(); player = p; lock.unlock() }
    func get() -> AVAudioPlayer? { lock.lock(); defer { lock.unlock() }; return player }
}
#endif
