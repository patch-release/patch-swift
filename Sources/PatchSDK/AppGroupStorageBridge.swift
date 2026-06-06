import Foundation
import WasmKit

// MARK: - AppGroupStorage bridge (shared UserDefaults via an app group)
//
// Reads/writes the SHARED `UserDefaults(suiteName:)` container an app group owns
// — the channel an app uses to share small values with its widgets / extensions
// / a paired Watch app. Mirrors `UserDefaultsBridge` but every value is stored in
// the app-group suite the bridge was constructed with, not `.standard`.
//
// Host functions (module "patch"):
//   * app_group_get(keyPtr,keyLen) -> packed string blob (0 if absent)
//   * app_group_set(keyPtr,keyLen, valPtr,valLen) -> [] (store a string value)
//   * app_group_remove(keyPtr,keyLen) -> [] (delete a key)
//
// ## Cross-platform core + injected dependency (guide Rule 2)
// `UserDefaults(suiteName:)` is plain Foundation and compiles on macOS, so the
// native dependency is injected simply as the `UserDefaults` instance. Tests
// inject a private, isolated suite (a random suiteName cleared in setUp) so the
// get/set/remove round-trip is exercised on macOS with no real app group /
// entitlement. The convenience `init(suiteName:)` resolves the real shared
// container; if the suite can't be opened (bad/absent entitlement) it falls back
// to `.standard` so the bridge never traps.
public struct AppGroupStorageBridge: Bridge {
    public let module = "patch"
    private let defaults: UserDefaults

    /// Cross-platform designated init — tests inject an isolated `UserDefaults`
    /// suite; apps can inject any pre-resolved shared container.
    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// Convenience init: resolve the shared `UserDefaults` for the given app-group
    /// suite name (e.g. "group.com.acme.app"). Falls back to `.standard` if the
    /// suite cannot be opened (missing App Groups entitlement / typo) so the
    /// bridge degrades gracefully instead of trapping. Fully cross-platform.
    public init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public func register(into imports: inout Imports, store: Store) {
        let defaults = self.defaults
        imports.host(module, "app_group_get", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [try ctx.packedResult(defaults.string(forKey: key))]
        }
        imports.host(module, "app_group_set", [.i32, .i32, .i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let val = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            defaults.set(val, forKey: key)
            return []
        }
        imports.host(module, "app_group_remove", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            defaults.removeObject(forKey: key)
            return []
        }
    }
}
