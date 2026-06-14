import Foundation
import WasmKit

// MARK: - Breakthrough #8 — host-ABI bridge FAMILY (module "patch_host")
//
// Read-only synchronous native leaves the FusionRewriter rewrites a developer's
// real source onto, so a 95%-pure function whose ONLY native touch is one of
// these compiles + ships OTA instead of demoting. Proven end-to-end in executing
// WASM (docs/ENGINEERING.md §2 breakthrough #8, experiments/host-bridges/,
// 16/16 checks). Every function here is registered under the flat-ABI namespace
// **"patch_host"** (the namespace the CLI's generated C header imports), with the
// exact `(ptr,len)` + packed-i64 marshalling the existing `BridgeContext` uses.
//
// These complement — they do not replace — the existing `patch`-namespace bridges
// (UserDefaultsBridge / ProcessInfoBridge / DateLocaleBridge), which stay intact.

// MARK: - FileManagerBridge (read-only file ops)
//
// `file_exists(path,len) -> i32` · `file_read(path,len) -> packed (ptr,len)` ·
// `file_size(path,len) -> i64`. READ-ONLY by design: no write/delete/enumerate.
// A write bridge would change the native-shell fingerprint and risk data loss on
// a bad OTA, so writes stay native (registry mustStayNative member guard).
//
// `FileManager` is plain Foundation — it compiles AND runs on macOS, so the real
// path needs no platform guard. The accessor is injectable for deterministic
// tests (a function `(String) -> ...` over an in-memory file table).
public struct FileManagerBridge: Bridge {
    public typealias Exists = @Sendable (_ path: String) -> Bool
    public typealias Contents = @Sendable (_ path: String) -> [UInt8]?
    public typealias Size = @Sendable (_ path: String) -> Int64

    public let module = "patch_host"
    private let existsFn: Exists
    private let contentsFn: Contents
    private let sizeFn: Size

    /// Designated init: inject the three read-only accessors (testable).
    public init(exists: @escaping Exists, contents: @escaping Contents, size: @escaping Size) {
        self.existsFn = exists
        self.contentsFn = contents
        self.sizeFn = size
    }

    /// Convenience default init: the real `FileManager.default` read-only surface.
    public init(fileManager: @Sendable @escaping () -> FileManager = { .default }) {
        self.init(
            exists: { fileManager().fileExists(atPath: $0) },
            contents: { fileManager().contents(atPath: $0).map { [UInt8]($0) } },
            size: { path in
                guard let attrs = try? fileManager().attributesOfItem(atPath: path),
                      let n = attrs[.size] as? NSNumber else { return -1 }
                return n.int64Value
            })
    }

    public func register(into imports: inout Imports, store: Store) {
        let existsFn = self.existsFn, contentsFn = self.contentsFn, sizeFn = self.sizeFn
        imports.host(module, "file_exists", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let path = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [.i32(existsFn(path) ? 1 : 0)]
        }
        imports.host(module, "file_read", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let path = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [try ctx.packedResult(contentsFn(path))]
        }
        imports.host(module, "file_size", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let path = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [.i64(UInt64(bitPattern: sizeFn(path)))]
        }
    }
}

// MARK: - BundleBridge (Info.plist / resource lookups)
//
// `bundle_info_string(key,len) -> packed string` backed by
// `Bundle.main.object(forInfoDictionaryKey:)`; `bundle_resource_path(name,len,
// ext,len) -> packed string` backed by `Bundle.main.path(forResource:ofType:)`.
// Returns VALUES (not a `Bundle` instance); code needing a `Bundle` object still
// demotes. On the macOS CLI harness there is no app bundle, so the host serves
// the value from its real source (identical ABI + contract); on iOS this is
// literally `Bundle.main`.
public struct BundleBridge: Bridge {
    public typealias InfoString = @Sendable (_ key: String) -> String?
    public typealias ResourcePath = @Sendable (_ name: String, _ ext: String?) -> String?

    public let module = "patch_host"
    private let infoFn: InfoString
    private let resourceFn: ResourcePath

    /// Designated init: inject the two read-only lookups (testable).
    public init(info: @escaping InfoString, resource: @escaping ResourcePath) {
        self.infoFn = info
        self.resourceFn = resource
    }

    /// Convenience default init: the real `Bundle.main` read-only surface.
    public init(bundle: @Sendable @escaping () -> Bundle = { .main }) {
        self.init(
            info: { bundle().object(forInfoDictionaryKey: $0) as? String },
            resource: { name, ext in
                bundle().path(forResource: name, ofType: (ext?.isEmpty == true) ? nil : ext)
            })
    }

    public func register(into imports: inout Imports, store: Store) {
        let infoFn = self.infoFn, resourceFn = self.resourceFn
        imports.host(module, "bundle_info_string", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [try ctx.packedResult(infoFn(key))]
        }
        imports.host(module, "bundle_resource_path", [.i32, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let name = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let ext = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            return [try ctx.packedResult(resourceFn(name, ext.isEmpty ? nil : ext))]
        }
    }
}

// MARK: - ProcessInfoEnvBridge (env + OS version, flat patch_host shapes)
//
// Distinct from `ProcessInfoBridge` (which serves a JSON blob under module
// `patch`): these are the FLAT scalar shapes the FusionRewriter targets.
// `process_env(name,len) -> packed string` (0 = unset) ·
// `os_version() -> packed "major.minor.patch"`. Plain Foundation → cross-platform,
// fully testable. Accessors injectable for determinism.
public struct ProcessInfoEnvBridge: Bridge {
    public typealias EnvLookup = @Sendable (_ name: String) -> String?
    public typealias OSVersion = @Sendable () -> String

    public let module = "patch_host"
    private let envFn: EnvLookup
    private let osVersionFn: OSVersion

    /// Designated init: inject env lookup + OS-version string (testable).
    public init(env: @escaping EnvLookup, osVersion: @escaping OSVersion) {
        self.envFn = env
        self.osVersionFn = osVersion
    }

    /// Convenience default init: the real `ProcessInfo.processInfo` surface.
    public init(processInfo: @Sendable @escaping () -> ProcessInfo = { .processInfo }) {
        self.init(
            env: { processInfo().environment[$0] },
            osVersion: {
                let v = processInfo().operatingSystemVersion
                return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            })
    }

    public func register(into imports: inout Imports, store: Store) {
        let envFn = self.envFn, osVersionFn = self.osVersionFn
        imports.host(module, "process_env", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let name = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [try ctx.packedResult(envFn(name))]
        }
        imports.host(module, "os_version", [], [.i64], store: store) { caller, _ in
            let ctx = BridgeContext(caller: caller)
            return [try ctx.packedResult(osVersionFn())]
        }
    }
}

// MARK: - UserDefaultsTypedBridge (typed get/set, flat patch_host shapes)
//
// The String `defaults_get`/`defaults_set` live on `UserDefaultsBridge` (module
// `patch`). The FusionRewriter additionally rewrites the TYPED accessors —
// `bool/integer/double(forKey:)` and `set(<bool|int|double>, forKey:)` — which
// need flat scalar shapes under the `patch_host` namespace (the String forms
// can't carry a typed value losslessly: a Bool stored as the literal "true" would
// re-read wrong, so each scalar type gets its own host fn).
//
// ## Bridge boundary (what these serve / deliberately omit)
//   GET: `defaults_get_bool(key,len) -> i32` tri-state (1 true, 0 false, -1 absent;
//        absent collapses to `false` in the shim, matching `bool(forKey:)`) ·
//        `defaults_get_int(key,len) -> i64` (0 if absent, like `integer(forKey:)`) ·
//        `defaults_get_double(key,len) -> i64` (the Double's BIT PATTERN in an i64;
//        0.0 if absent, like `double(forKey:)` — the guest reinterprets the bits).
//   SET: `defaults_set_bool(key,len, i32)` · `defaults_set_int(key,len, i64)` ·
//        `defaults_set_double(key,len, i64-bits)` — fire-and-forget, no result.
//
// NOT served (stay native / demote — no SAFE single-type value bridge):
//   * `object(forKey:)` / `set(_:forKey:)` of an arbitrary `Any?` (array/dict/Data/
//     custom plist) — the value has no fixed scalar shape to marshal, so a function
//     using it is left native (the registry's `UserDefaults` .bridgeable tier still
//     lets the WHOLE function run as a `bridged` native call; only the in-WASM
//     lowering of THIS call is declined). `Data`/`[String]` round-trips would need a
//     bespoke serializer — out of scope, kept honest.
//   * `register(defaults:)`, `removePersistentDomain`, KVO observation — native.
public struct UserDefaultsTypedBridge: Bridge {
    public let module = "patch_host"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func register(into imports: inout Imports, store: Store) {
        let defaults = self.defaults
        imports.host(module, "defaults_get_bool", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            // Tri-state: -1 when the key is absent (so the guest can distinguish a
            // stored `false` from "never set"). UserDefaults.bool(forKey:) itself
            // returns false for an absent key — the guest's shim collapses -1 → false.
            if defaults.object(forKey: key) == nil { return [.i32(UInt32(bitPattern: -1))] }
            return [.i32(defaults.bool(forKey: key) ? 1 : 0)]
        }
        imports.host(module, "defaults_get_int", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [.i64(UInt64(bitPattern: Int64(defaults.integer(forKey: key))))]
        }
        // double(forKey:) — return the Double's bit-pattern in an i64 (the same
        // bits-in-an-i64 convention `FoundationBridge`/`json_get_f64` use; WASM
        // host fns have no f64-result shape in this ABI). Absent → 0.0 (bits 0),
        // matching `UserDefaults.double(forKey:)`.
        imports.host(module, "defaults_get_double", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [.i64(defaults.double(forKey: key).bitPattern)]
        }
        // Typed setters (fire-and-forget). A Bool is the i32 arg (1/0); an Int is the
        // i64 arg; a Double is its bit-pattern in the i64 arg.
        imports.host(module, "defaults_set_bool", [.i32, .i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            defaults.set(args[2].i32 != 0, forKey: key)
            return []
        }
        imports.host(module, "defaults_set_int", [.i32, .i32, .i64], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            defaults.set(Int(Int64(bitPattern: args[2].i64)), forKey: key)
            return []
        }
        imports.host(module, "defaults_set_double", [.i32, .i32, .i64], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            defaults.set(Double(bitPattern: args[2].i64), forKey: key)
            return []
        }
    }
}
