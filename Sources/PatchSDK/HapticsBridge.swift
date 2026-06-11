import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Haptics bridge (iOS-device-oriented)
//
// Tactile feedback routed through a host-supplied handler. On iOS the default
// init wires Apple's three feedback generators
// (`UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` /
// `UISelectionFeedbackGenerator`); cross-platform (macOS / tests) it stays a
// pure no-op that records (event, variant) pairs via the injected closure.
//
// All three host functions are fire-and-forget (no return value): the guest
// triggers a buzz and does not wait for or read anything back. They follow the
// Patch v0 `(ptr: i32, len: i32)` ABI for the string argument, exactly like the
// `NavigationBridge.navigate` template.
//
// Host functions (module "patch"):
//   * `haptic_impact(ptr,len)`       — arg = style: light|medium|heavy|soft|rigid
//   * `haptic_notification(ptr,len)` — arg = type:  success|warning|error
//   * `haptic_selection()`           — no argument
//
// The injected dependency is a single `@Sendable (event, variant) -> Void`:
//   * impact       → event "impact",       variant = the (normalized) style
//   * notification → event "notification", variant = the (normalized) type
//   * selection    → event "selection",    variant = "" (no variant)
//
// Invalid / unknown impact styles normalize to "medium" (the system default
// feel) before dispatch — `Self.normalizeImpact` is the single source of truth
// and is unit-tested directly. The convenience iOS init maps the normalized
// variant onto the matching `UIImpactFeedbackGenerator.FeedbackStyle` /
// `UINotificationFeedbackGenerator.FeedbackType`.
public struct HapticsBridge: Bridge {
    /// Records one haptic event. `event` is "impact" | "notification" |
    /// "selection"; `variant` is the normalized style/type ("" for selection).
    public typealias Fire = @Sendable (_ event: String, _ variant: String) -> Void

    public let module = "patch"
    private let fire: Fire

    /// Cross-platform designated init — tests inject a spy that records calls.
    public init(fire: @escaping Fire) { self.fire = fire }

    #if canImport(UIKit)
    /// Convenience default init: wires the real UIKit feedback generators. Each
    /// call lazily constructs a generator, `prepare()`s it, and fires. Guarded by
    /// `canImport(UIKit)` so the cross-platform core still compiles on macOS.
    public init() {
        self.init(fire: { event, variant in
            // Feedback generators are main-actor-isolated (they must be created/used on
            // the main thread), but this is a synchronous nonisolated `@Sendable`
            // closure. Firing haptics is fire-and-forget, so hop the whole body onto
            // the main actor with `Task { @MainActor in … }` (capturing only the
            // Sendable `String` event/variant). A Task is used rather than
            // `MainActor.assumeIsolated` (iOS 17+) to keep the iOS 16 floor.
            Task { @MainActor in
                switch event {
                case "impact":
                    let gen = UIImpactFeedbackGenerator(style: Self.uiImpactStyle(variant))
                    gen.prepare()
                    gen.impactOccurred()
                case "notification":
                    let gen = UINotificationFeedbackGenerator()
                    gen.prepare()
                    gen.notificationOccurred(Self.uiNotificationType(variant))
                case "selection":
                    let gen = UISelectionFeedbackGenerator()
                    gen.prepare()
                    gen.selectionChanged()
                default:
                    break
                }
            }
        })
    }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let fire = self.fire
        // haptic_impact(ptr,len) -> [] — style string normalized to a known feel.
        imports.host(module, "haptic_impact", [.i32, .i32], [], store: store) { caller, args in
            let raw = try BridgeContext(caller: caller).readString(ptr: args[0].i32, len: args[1].i32)
            fire("impact", Self.normalizeImpact(raw))
            return []
        }
        // haptic_notification(ptr,len) -> [] — type string normalized to success/warning/error.
        imports.host(module, "haptic_notification", [.i32, .i32], [], store: store) { caller, args in
            let raw = try BridgeContext(caller: caller).readString(ptr: args[0].i32, len: args[1].i32)
            fire("notification", Self.normalizeNotification(raw))
            return []
        }
        // haptic_selection() -> [] — no argument, no variant.
        imports.host(module, "haptic_selection", [], [], store: store) { _, _ in
            fire("selection", "")
            return []
        }
    }

    // MARK: - Pure normalization (single source of truth, unit-tested directly)

    /// Valid impact styles. Anything else (typo, empty, casing) → "medium".
    public static func normalizeImpact(_ style: String) -> String {
        switch style.lowercased() {
        case "light", "medium", "heavy", "soft", "rigid": return style.lowercased()
        default: return "medium"
        }
    }

    /// Valid notification types. Anything else → "success" (the benign default).
    public static func normalizeNotification(_ type: String) -> String {
        switch type.lowercased() {
        case "success", "warning", "error": return type.lowercased()
        default: return "success"
        }
    }

    #if canImport(UIKit)
    /// Map a normalized impact-style string to UIKit's `FeedbackStyle`.
    static func uiImpactStyle(_ variant: String) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch variant {
        case "light": return .light
        case "heavy": return .heavy
        case "soft": return .soft
        case "rigid": return .rigid
        default: return .medium
        }
    }

    /// Map a normalized notification-type string to UIKit's `FeedbackType`.
    static func uiNotificationType(_ variant: String) -> UINotificationFeedbackGenerator.FeedbackType {
        switch variant {
        case "warning": return .warning
        case "error": return .error
        default: return .success
        }
    }
    #endif
}
