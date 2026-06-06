import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ScreenControl bridge (brightness + idle-timer / keep-awake)
//
// Lets an OTA patch read/set the screen brightness and toggle the idle timer
// (the "keep the screen awake" switch) — common for readers, players, scanners,
// and turn-by-turn screens.
//
// Host functions (module "patch"):
//   * get_brightness() -> i32        — current brightness as 0...100 (percent).
//   * set_brightness(level: i32) -> [] — set brightness; level clamped to 0...100.
//   * set_idle_timer_disabled(disabled: i32) -> [] — 1 keeps the screen awake, 0
//       restores normal auto-lock.
//
// Brightness crosses the ABI as an integer PERCENT (0...100) rather than the
// UIKit `0.0...1.0` CGFloat, so the guest never deals with floats: the host
// converts. The two pure conversions (`clampPercent` / `percentToUnit` /
// `unitToPercent`) are the single source of truth and are unit-tested directly.
//
// ## Cross-platform core + injected dependency (guide Rule 2)
// `UIScreen.brightness` / `UIApplication.isIdleTimerDisabled` are UIKit-only and
// main-thread bound, so they are injected as `@Sendable` closures backed (in the
// default init) by the real UIKit state. Tests inject spies over an in-memory
// store and assert the get/set round-trip + the keep-awake flag, with no real
// UIKit. The convenience `init()` wires UIKit under `#if canImport(UIKit)`.
public struct ScreenControlBridge: Bridge {
    /// Read the current brightness as a unit value (0.0...1.0).
    public typealias BrightnessGetter = @Sendable () -> Double
    /// Set the brightness from a unit value (0.0...1.0).
    public typealias BrightnessSetter = @Sendable (_ unit: Double) -> Void
    /// Set whether the idle timer is disabled (true = keep screen awake).
    public typealias IdleTimerSetter = @Sendable (_ disabled: Bool) -> Void

    public let module = "patch"
    private let getBrightness: BrightnessGetter
    private let setBrightness: BrightnessSetter
    private let setIdleTimerDisabled: IdleTimerSetter

    /// Cross-platform designated init — tests inject spies. Brightness is exchanged
    /// with the injected closures as a UNIT value (0.0...1.0), matching UIKit.
    public init(
        getBrightness: @escaping BrightnessGetter,
        setBrightness: @escaping BrightnessSetter,
        setIdleTimerDisabled: @escaping IdleTimerSetter
    ) {
        self.getBrightness = getBrightness
        self.setBrightness = setBrightness
        self.setIdleTimerDisabled = setIdleTimerDisabled
    }

    #if canImport(UIKit)
    /// Convenience default init: wires `UIScreen.main.brightness` and
    /// `UIApplication.shared.isIdleTimerDisabled`. Both are UI state and must be
    /// touched on the main thread, so each closure hops to main when needed.
    /// Guarded by `canImport(UIKit)` so the cross-platform core compiles on macOS.
    public init() {
        self.init(
            getBrightness: {
                let read: @Sendable () -> Double = { Double(UIScreen.main.brightness) }
                return Thread.isMainThread ? read() : DispatchQueue.main.sync { read() }
            },
            setBrightness: { unit in
                let apply: @Sendable () -> Void = { UIScreen.main.brightness = CGFloat(unit) }
                if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
            },
            setIdleTimerDisabled: { disabled in
                let apply: @Sendable () -> Void = { UIApplication.shared.isIdleTimerDisabled = disabled }
                if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
            }
        )
    }
    #endif

    // MARK: - Pure conversions (single source of truth, unit-tested directly)

    /// Clamp a requested brightness percent into the valid 0...100 range.
    public static func clampPercent(_ percent: Int) -> Int {
        min(100, max(0, percent))
    }

    /// Convert a 0...100 integer percent to a 0.0...1.0 unit value (UIKit's scale).
    /// The percent is clamped first so out-of-range guest input is well-defined.
    public static func percentToUnit(_ percent: Int) -> Double {
        Double(clampPercent(percent)) / 100.0
    }

    /// Convert a 0.0...1.0 unit value to a rounded 0...100 integer percent. Values
    /// outside the unit range are clamped, so a freak >1.0 reading never escapes.
    public static func unitToPercent(_ unit: Double) -> Int {
        let clamped = min(1.0, max(0.0, unit))
        return Int((clamped * 100.0).rounded())
    }

    // MARK: - Dispatch seams (what the host closures run; unit-tested directly)

    /// Read brightness via the injected getter and convert to a 0...100 percent —
    /// exactly what `get_brightness` returns. Factored out so the dispatch path is
    /// unit-testable with a spy getter (no wasm fixture).
    func readBrightnessPercent() -> Int {
        Self.unitToPercent(getBrightness())
    }

    /// Clamp + convert a guest percent and push it to the injected setter — exactly
    /// what `set_brightness` does.
    func applyBrightness(percent: Int) {
        setBrightness(Self.percentToUnit(percent))
    }

    /// Push a keep-awake flag to the injected idle-timer setter — exactly what
    /// `set_idle_timer_disabled` does (non-zero = keep awake).
    func applyIdleTimerDisabled(_ disabled: Bool) {
        setIdleTimerDisabled(disabled)
    }

    public func register(into imports: inout Imports, store: Store) {
        let bridge = self

        // get_brightness() -> i32 : current brightness as 0...100 percent.
        imports.host(module, "get_brightness", [], [.i32], store: store) { _, _ in
            [.i32(UInt32(bridge.readBrightnessPercent()))]
        }
        // set_brightness(level) -> [] : clamp to 0...100, convert to unit, apply.
        imports.host(module, "set_brightness", [.i32], [], store: store) { _, args in
            bridge.applyBrightness(percent: Int(Int32(bitPattern: args[0].i32)))
            return []
        }
        // set_idle_timer_disabled(disabled) -> [] : non-zero = keep awake.
        imports.host(module, "set_idle_timer_disabled", [.i32], [], store: store) { _, args in
            bridge.applyIdleTimerDisabled(args[0].i32 != 0)
            return []
        }
    }
}
