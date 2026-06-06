import Foundation
import WasmKit
#if canImport(AudioToolbox)
import AudioToolbox
#endif

// MARK: - System sound bridge (play system sounds / vibrate)
//
// Plays short system sounds and triggers device vibration, routed through two
// host-supplied closures. On macOS / iOS the default init wires Apple's
// `AudioServicesPlaySystemSound` (AudioToolbox); cross-platform (tests) it stays
// a pure no-op that records the requested sound ID / vibrate count via the
// injected closures.
//
// Both host functions are fire-and-forget (no return value): the guest asks for
// a sound/vibration and does not wait for or read anything back — exactly like
// the `NavigationBridge.navigate` template.
//
// Host functions (module "patch"):
//   * `play_system_sound(i32) -> []`  — arg = a SystemSoundID (e.g. 1007).
//   * `vibrate() -> []`               — no argument; buzzes the device.
//
// The injected dependencies are:
//   * `play`    : @Sendable (UInt32) -> Void  — receives the SystemSoundID.
//   * `vibrate` : @Sendable () -> Void         — triggers a vibration.
//
// On Apple platforms AudioToolbox's `AudioServicesPlaySystemSound` plays the
// given system sound by ID; passing `kSystemSoundID_Vibrate` vibrates the device
// (a no-op on hardware without a Taptic Engine, e.g. iPad / Mac). AudioToolbox is
// available on macOS + iOS, so the convenience default init is guarded by
// `#if canImport(AudioToolbox)`.
public struct SystemSoundBridge: Bridge {
    /// Plays the system sound with the given `SystemSoundID`.
    public typealias Play = @Sendable (_ soundID: UInt32) -> Void
    /// Triggers a device vibration.
    public typealias Vibrate = @Sendable () -> Void

    public let module = "patch"
    private let play: Play
    private let vibrate: Vibrate

    /// Cross-platform designated init — tests inject spies that record calls.
    public init(play: @escaping Play, vibrate: @escaping Vibrate) {
        self.play = play
        self.vibrate = vibrate
    }

    #if canImport(AudioToolbox)
    /// Convenience default init: wires the real AudioToolbox system-sound API.
    /// `play_system_sound` plays the requested `SystemSoundID`; `vibrate` plays
    /// `kSystemSoundID_Vibrate`. Guarded by `canImport(AudioToolbox)` so the
    /// cross-platform core still compiles where AudioToolbox is absent.
    public init() {
        self.init(
            play: { soundID in
                AudioServicesPlaySystemSound(SystemSoundID(soundID))
            },
            vibrate: {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        )
    }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let play = self.play
        let vibrate = self.vibrate
        // play_system_sound(i32) -> [] — arg is a raw SystemSoundID.
        imports.host(module, "play_system_sound", [.i32], [], store: store) { _, args in
            play(args[0].i32)
            return []
        }
        // vibrate() -> [] — no argument.
        imports.host(module, "vibrate", [], [], store: store) { _, _ in
            vibrate()
            return []
        }
    }
}
