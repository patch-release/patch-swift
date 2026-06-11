import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - AccessibilityBridge (VoiceOver announcement + status)
//
// Two host functions exposed to the guest:
//
//   * `a11y_announce(ptr,len) -> []` — post a VoiceOver announcement. The guest
//     passes a UTF-8 string `(ptr,len)`; VoiceOver speaks it (when running).
//     Fire-and-forget — no result is returned (like NavigationBridge.navigate).
//   * `a11y_voiceover_running() -> i32` — read whether VoiceOver is active
//     (1 = running, 0 = not). A plain scalar return (the flat-scalar ABI, like
//     AppBadgeBridge.get_badge), so there is nothing to marshal through memory.
//
// ## Cross-platform core + injected dependencies (Rule 2)
// The native capability (`UIAccessibility.post(notification:argument:)` and
// `UIAccessibility.isVoiceOverRunning`) is UIKit-only, so it is injected as two
// `@Sendable` closures: an announcer and a status reader. The bridge struct + its
// `register(...)` marshalling therefore compile on macOS (no direct UIKit at the
// top level); tests inject spies and assert the announce string / status
// round-trip. The convenience `init()` wires the real UIAccessibility calls under
// `#if canImport(UIKit)`. Mirrors AppBadgeBridge (injected setter/getter).
public struct AccessibilityBridge: Bridge {
    /// Post a VoiceOver announcement for the given string.
    public typealias Announce = @Sendable (_ message: String) -> Void
    /// Read whether VoiceOver is currently running.
    public typealias IsVoiceOverRunning = @Sendable () -> Bool

    public let module = "patch"
    private let announce: Announce
    private let isVoiceOverRunning: IsVoiceOverRunning

    /// Cross-platform designated init — tests inject spies here.
    public init(announce: @escaping Announce, isVoiceOverRunning: @escaping IsVoiceOverRunning) {
        self.announce = announce
        self.isVoiceOverRunning = isVoiceOverRunning
    }

    #if canImport(UIKit)
    /// Convenience default init wiring the real UIAccessibility implementation.
    /// Guarded by `canImport(UIKit)` so the host build on macOS never references
    /// UIKit. The announcement is posted on the main thread (UIKit accessibility
    /// notifications are main-thread bound); the status read also hops to main so
    /// the guest's synchronous call sees the real, current value.
    public init() {
        self.init(
            announce: { message in
                // Concurrency hop: `UIAccessibility.post` is main-actor-isolated; this
                // is a synchronous nonisolated `@Sendable` closure. Posting is
                // fire-and-forget, so hop onto the main actor with `Task { @MainActor in
                // … }` (capturing only the Sendable `String`). A Task is used rather
                // than `MainActor.assumeIsolated` (iOS 17+) to keep the iOS 16 floor.
                Task { @MainActor in
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
            },
            isVoiceOverRunning: {
                // Synchronous getter: reads `UIAccessibility.isVoiceOverRunning`
                // (main-actor) via a synchronous main hop (see
                // `patchMainActorSyncRead`; bridge calls run off-main on `callQueue`,
                // so this never deadlocks).
                patchMainActorSyncRead { UIAccessibility.isVoiceOverRunning }
            })
    }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let announce = self.announce
        let isVoiceOverRunning = self.isVoiceOverRunning
        // a11y_announce(ptr,len) -> [] : decode the string, post it; fire-and-forget.
        imports.host(module, "a11y_announce", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let message = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            announce(message)
            return []
        }
        // a11y_voiceover_running() -> i32 : 1 if VoiceOver running, else 0.
        imports.host(module, "a11y_voiceover_running", [], [.i32], store: store) { _, _ in
            [.i32(isVoiceOverRunning() ? 1 : 0)]
        }
    }

    /// Internal accessor exercising the injected status reader exactly as the
    /// registered `a11y_voiceover_running` host closure does. Used by tests.
    func voiceOverRunning() -> Bool { isVoiceOverRunning() }
}
