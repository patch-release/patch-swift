import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - OpenURL (external links / deep links)
//
// open_url(ptr,len) -> i32   — open an external URL / deep link; 1 if opened, 0 if rejected.
// can_open_url(ptr,len) -> i32 — can the system open this URL? 1/0.
//
// The guest passes a URL string `(ptr,len)`; the host validates that it parses
// as a URL (rejecting empty / garbage strings up front) and then hands it to an
// injected closure. On iOS the convenience init wires the real
// `UIApplication.shared.open(_:)` / `canOpenURL(_:)`. The struct + its
// `register(...)` marshalling compile on macOS (no direct UIKit at the top
// level): tests inject spies that record requested URLs and return canned
// bools. Mirrors how `NavigationBridge` injects a handler.
public struct OpenURLBridge: Bridge {
    /// Open an external URL / deep link. Returns whether the URL was opened.
    public typealias Opener = @Sendable (_ url: String) -> Bool
    /// Whether the system can open the given URL. Returns 1/0 to the guest.
    public typealias CanOpener = @Sendable (_ url: String) -> Bool

    public let module = "patch"
    private let opener: Opener
    private let canOpener: CanOpener

    /// Cross-platform designated init (used by tests): inject the native
    /// capability as closures so the bridge is exercisable on macOS.
    public init(open: @escaping Opener, canOpen: @escaping CanOpener) {
        self.opener = open
        self.canOpener = canOpen
    }

    #if canImport(UIKit)
    /// Convenience default init wiring the real iOS implementation. Guarded by
    /// `canImport(UIKit)` so the host build on macOS never references UIKit.
    public init() {
        self.init(
            open: { url in
                guard let u = URL(string: url) else { return false }
                let box = OpenResultBox()
                let sem = DispatchSemaphore(value: 0)
                // `UIApplication.shared` / `canOpenURL` / `open(_:)` are all
                // main-actor-isolated and main-thread-affine. Do the WHOLE check +
                // open inside a single main-actor hop (`DispatchQueue.main.async { @MainActor in … }`)
                // so no main-actor state is touched from this nonisolated `@Sendable`
                // closure, then block on the semaphore so the guest's synchronous call
                // still gets a real result. (A blocking getter can't use a
                // fire-and-forget `Task`; we keep the existing semaphore bridge.)
                DispatchQueue.main.async { @MainActor in
                    let app = UIApplication.shared
                    guard app.canOpenURL(u) else { box.set(false); sem.signal(); return }
                    app.open(u, options: [:]) { ok in box.set(ok); sem.signal() }
                }
                _ = sem.wait(timeout: .now() + 5)
                return box.get()
            },
            canOpen: { url in
                guard let u = URL(string: url) else { return false }
                // Synchronous read of a main-actor-isolated API via a synchronous main
                // hop (see `patchMainActorSyncRead`; bridge calls run off-main on
                // `callQueue`, so this never deadlocks). Cannot use a fire-and-forget
                // `Task` — the guest needs the Bool back.
                return patchMainActorSyncRead { UIApplication.shared.canOpenURL(u) }
            })
    }
    #endif

    /// Validate that `s` parses as a URL we are willing to dispatch. Rejects
    /// empty / whitespace-only strings and anything that does not form a URL
    /// with a scheme (so bare garbage like "not a url" is rejected). Pure +
    /// directly unit-tested.
    public static func isValidURL(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let url = URL(string: trimmed) else { return false }
        // Require a scheme — a deep link / external link is always scheme-led
        // (https:, mailto:, myapp:). This rejects bare paths and free-text.
        guard let scheme = url.scheme, !scheme.isEmpty else { return false }
        return true
    }

    public func register(into imports: inout Imports, store: Store) {
        let opener = self.opener
        let canOpener = self.canOpener
        imports.host(module, "open_url", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let url = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            guard Self.isValidURL(url) else { return [.i32(0)] }
            return [.i32(opener(url) ? 1 : 0)]
        }
        imports.host(module, "can_open_url", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let url = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            guard Self.isValidURL(url) else { return [.i32(0)] }
            return [.i32(canOpener(url) ? 1 : 0)]
        }
    }
}

/// Tiny thread-safe box so the iOS `open(_:completionHandler:)` callback can
/// hand its result back to the blocking guest call without a data-race warning.
private final class OpenResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
