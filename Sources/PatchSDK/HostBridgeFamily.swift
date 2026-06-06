import Foundation
import WasmKit

// MARK: - Host-ABI bridge family (module "patch_host")
//
// Read-only synchronous native leaves that a developer's real source can be
// rewritten onto, so a near-pure function whose only native touch is one of
// these compiles and ships OTA instead of falling back. Every function here is
// registered under the flat-ABI namespace
// **"patch_host"** (the namespace the generated C header imports), with the
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

// MARK: - UserDefaultsTypedBridge (bool/int, flat patch_host shapes)
//
// The String `defaults_get` lives on `UserDefaultsBridge` (module `patch`). The
// FusionRewriter additionally rewrites `bool(forKey:)` / `integer(forKey:)`, which
// need typed shapes under the flat `patch_host` namespace:
//   `defaults_get_bool(key,len) -> i32` tri-state (1 true, 0 false, -1 absent) ·
//   `defaults_get_int(key,len)  -> i64` (0 if absent, matching integer(forKey:)).
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
    }
}
