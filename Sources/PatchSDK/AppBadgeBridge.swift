import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - AppBadge (app icon badge number)
//
// set_badge(count: i32) -> []   — set the app icon badge count (0 clears it).
// get_badge() -> i32            — read the current app icon badge count.
//
// The badge count is a plain scalar, so this bridge uses the flat-scalar ABI
// directly (an `.i32` arg / `.i32` result) rather than the (ptr,len)+packed-i64
// string convention — there is nothing to marshal through guest memory.
//
// The native capability (`UIApplication.shared.applicationIconBadgeNumber`) is
// UIKit-only and main-thread bound, so it is injected as two `@Sendable`
// closures (a setter and a getter). The bridge struct + its `register(...)`
// marshalling therefore compile on macOS (no direct UIKit at the top level):
// tests inject spies backed by an in-memory Int and assert the set/get
// round-trip. The convenience `init()` wires the real UIApplication reads/writes
// under `#if canImport(UIKit)`. Mirrors how `NavigationBridge` injects a handler.
//
// Negative counts are meaningless for a badge, so they clamp to 0 (a clear) in a
// pure `static func clamp(_:)` that is unit-tested directly.
public struct AppBadgeBridge: Bridge {
    /// Set the app icon badge count (already clamped to >= 0 by the host fn).
    public typealias Setter = @Sendable (_ count: Int) -> Void
    /// Read the current app icon badge count.
    public typealias Getter = @Sendable () -> Int32

    public let module = "patch"
    private let setter: Setter
    private let getter: Getter

    /// Cross-platform designated init (used by tests): inject the native badge
    /// setter/getter as closures so the bridge is exercisable on macOS.
    public init(set: @escaping Setter, get: @escaping Getter) {
        self.setter = set
        self.getter = get
    }

    #if canImport(UIKit)
    /// Convenience default init wiring the real iOS implementation. Guarded by
    /// `canImport(UIKit)` so the host build on macOS never references UIKit.
    ///
    /// `applicationIconBadgeNumber` is UI state and must be touched on the main
    /// thread: the setter hops to main (sync if already there); the getter reads
    /// the value on the main thread so the guest's synchronous call sees the
    /// real, current count.
    public init() {
        self.init(
            set: { count in
                let apply: @Sendable () -> Void = {
                    UIApplication.shared.applicationIconBadgeNumber = count
                }
                if Thread.isMainThread {
                    apply()
                } else {
                    DispatchQueue.main.sync { apply() }
                }
            },
            get: {
                let read: @Sendable () -> Int = {
                    UIApplication.shared.applicationIconBadgeNumber
                }
                let value = Thread.isMainThread ? read() : DispatchQueue.main.sync { read() }
                return Int32(clamping: value)
            })
    }
    #endif

    /// Clamp a requested badge count to the valid range. Negative counts are
    /// meaningless for an app icon badge, so they collapse to 0 (clear). Pure +
    /// directly unit-tested.
    public static func clamp(_ count: Int) -> Int {
        max(0, count)
    }

    public func register(into imports: inout Imports, store: Store) {
        let setter = self.setter
        let getter = self.getter
        // set_badge(count) -> [] : clamp negatives to 0, then set.
        imports.host(module, "set_badge", [.i32], [], store: store) { _, args in
            let requested = Int(Int32(bitPattern: args[0].i32))
            setter(Self.clamp(requested))
            return []
        }
        // get_badge() -> i32 : read the current badge count.
        imports.host(module, "get_badge", [], [.i32], store: store) { _, _ in
            [.i32(UInt32(bitPattern: getter()))]
        }
    }
}
