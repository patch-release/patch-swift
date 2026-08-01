// SPDX-License-Identifier: Apache-2.0

import Foundation

/// FUSION (breakthrough #2) — rewrite a **bridgeable native leaf** in the
/// developer's REAL source to a `patch_host`/`patch` host-bridge import, so a
/// function that is pure value-type logic but touches ONE bridgeable native API
/// (`UserDefaults`/`Locale`/logging/…) COMPILES under the WASM SDK instead of
/// demoting.
///
/// ## Why this is the missing join
/// The real-source closure path (`PATCH_REAL_SOURCE=1`) compiles a demoted
/// function's verbatim source under the full WASM SDK. That works for pure value
/// logic — but the instant the body references a native symbol the real compile
/// fails (`no such module` / unresolved `UserDefaults`) and the function demotes.
/// The host-ABI bridge (`CHeaderBridge`/`patch_host`) lets WASM call back into the
/// native shell. The fusion is the JOIN: rewrite the ONE bridgeable native call
/// site in the real source to a host-bridge import, and the 95 %-pure function
/// compiles.
///
/// This is exactly what `research/wave3/fusion-prototype/` proved end-to-end:
/// real value types + a `UserDefaults` leaf rewritten to `patch_host.defaults_get_str`,
/// compiled under the FULL WASM SDK, executed in WasmKit through real `UserDefaults`
/// (6/6 checks pass, including re-reading live native state per call).
///
/// ## ABI discipline (the proven facts this encodes)
/// 1. The imports MUST be declared through a **C header** with Clang's
///    `import_module`/`import_name` attributes — `@_extern(wasm)` emits a mangled,
///    non-flat ABI WasmKit rejects (confirmed under the full SDK: `@_extern` yields
///    `defaults_get : [i32,i32,i32,i32]->[i64]`, two hidden trailing args; the C
///    header yields the flat `[i32,i32]->[i64]` the SDK host registers). So the
///    fusion contributes a `Sources/FusionCHost` C target, exactly like the prototype.
/// 2. The host module namespaces in the SDK are NOT uniform: `UserDefaults` /
///    `Keychain` / `Date`-`Locale` / logging register under module **`patch`**;
///    the Foundation value surface registers under **`patch_host`**. This file is
///    the SINGLE source of truth that pins each leaf to its real registered
///    `(module, name, signature)` — closing the "patch vs patch_host drift" the
///    research report (P1) flagged. Every entry here matches a live
///    `imports.host(module, name, …)` registration in `sdk/Sources/PatchSDK/Bridges.swift`.
public struct FusionRewriter {
    public init() {}

    /// One bridgeable leaf: the host import it binds to plus the C declaration and
    /// the Swift call the rewrite emits. `cImportModule`/`cImportName` MUST match a
    /// live SDK `imports.host(module, name, …)` registration.
    public struct Bridge: Sendable, Hashable {
        /// Stable id for reporting which leaves were bridged.
        public let id: String
        /// WASM import module — `"patch"` or `"patch_host"` (matches the SDK).
        public let cImportModule: String
        /// WASM import name (matches the SDK registration).
        public let cImportName: String
        /// The flat C declaration written into `fusion_chost.h` (Clang import attrs).
        public let cDecl: String
        /// The Swift shim (a top-level `func`) the rewritten call resolves to. Added
        /// once to the bridge support file when this leaf is used.
        public let swiftShim: String
        /// True for an ASYNC bridge (breakthrough #6 networking): the host import
        /// returns `()` (suspends the guest) and the result is delivered later via a
        /// `patch_resolve_*` export the host calls, instead of being returned inline.
        /// An async bridge's shim is an `async` func and depends on the executor
        /// continuation registry (`_patchFusionHTTP*`). Sync bridges leave this false.
        public let isAsync: Bool

        public init(id: String, cImportModule: String, cImportName: String,
                    cDecl: String, swiftShim: String, isAsync: Bool = false) {
            self.id = id
            self.cImportModule = cImportModule
            self.cImportName = cImportName
            self.cDecl = cDecl
            self.swiftShim = swiftShim
            self.isAsync = isAsync
        }
    }

    // MARK: - Source-of-truth bridge table

    /// `UserDefaults.standard.string(forKey:)` → `patch.defaults_get` (packed
    /// string; 0 = absent). Matches `UserDefaultsBridge` (module `patch`).
    static let defaultsGet = Bridge(
        id: "UserDefaults.string(forKey:)",
        cImportModule: "patch", cImportName: "defaults_get",
        cDecl: """
        WASM_IMPORT("patch","defaults_get")
        int64_t patch_defaults_get(const uint8_t* key, int32_t keyLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionDefaultsGetString(_ key: String) -> String? {
            let k = Array(key.utf8)
            let packed = k.withUnsafeBufferPointer { kp in
                patch_defaults_get(kp.baseAddress, Int32(kp.count))
            }
            let (ptr, len) = _patchFusionUnpack(packed)
            if ptr == 0 || len == 0 { return nil }
            return _patchFusionReadString(ptr: ptr, len: len)
        }
        """)

    /// `UserDefaults.standard.set(_:forKey:)` (String value) → `patch.defaults_set`.
    static let defaultsSet = Bridge(
        id: "UserDefaults.set(_:forKey:)",
        cImportModule: "patch", cImportName: "defaults_set",
        cDecl: """
        WASM_IMPORT("patch","defaults_set")
        void patch_defaults_set(const uint8_t* key, int32_t keyLen,
                                const uint8_t* val, int32_t valLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionDefaultsSetString(_ value: String, _ key: String) {
            let k = Array(key.utf8), v = Array(value.utf8)
            k.withUnsafeBufferPointer { kp in
                v.withUnsafeBufferPointer { vp in
                    patch_defaults_set(kp.baseAddress, Int32(kp.count), vp.baseAddress, Int32(vp.count))
                }
            }
        }
        """)

    /// `Locale.current.identifier` → `patch.locale_identifier` (packed string).
    /// Matches `DateLocaleBridge` (module `patch`).
    static let localeIdentifier = Bridge(
        id: "Locale.current.identifier",
        cImportModule: "patch", cImportName: "locale_identifier",
        cDecl: """
        WASM_IMPORT("patch","locale_identifier")
        int64_t patch_locale_identifier(void);
        """,
        swiftShim: """
        @inlinable func _patchFusionLocaleIdentifier() -> String {
            let packed = patch_locale_identifier()
            let (ptr, len) = _patchFusionUnpack(packed)
            if ptr == 0 || len == 0 { return "" }
            return _patchFusionReadString(ptr: ptr, len: len)
        }
        """)

    /// `TimeZone.current.identifier` → `patch.timezone_identifier` (packed string).
    static let timezoneIdentifier = Bridge(
        id: "TimeZone.current.identifier",
        cImportModule: "patch", cImportName: "timezone_identifier",
        cDecl: """
        WASM_IMPORT("patch","timezone_identifier")
        int64_t patch_timezone_identifier(void);
        """,
        swiftShim: """
        @inlinable func _patchFusionTimeZoneIdentifier() -> String {
            let packed = patch_timezone_identifier()
            let (ptr, len) = _patchFusionUnpack(packed)
            if ptr == 0 || len == 0 { return "" }
            return _patchFusionReadString(ptr: ptr, len: len)
        }
        """)

    /// `UIApplication.shared.open(<url>)` → `patch.open_url` (i32 result: 1 opened /
    /// 0 rejected). Matches `OpenURLBridge` (module `patch`). The host validates the
    /// URL (scheme required), hops to the main actor, and calls the real
    /// `UIApplication.shared.open(_:)`. The shim accepts a `URL` or a `String`
    /// (`_PatchURLLike`, shared with the networking shim) and discards the Bool
    /// result so the rewrite slots cleanly into a fire-and-forget statement
    /// (`@discardableResult`); a caller that READS the result still compiles
    /// (the func returns `Bool`). Only the single-URL form is rewritten — the
    /// `open(_:options:completionHandler:)` overload (extra args) is left native.
    ///
    /// NB: `OpenURLBridge` is registered under `#if canImport(UIKit)`, so a guest
    /// importing `patch.open_url` requires a UIKit host (iOS) — exactly the platform
    /// a `UIApplication.shared.open` call already targets, so this never widens the
    /// host contract beyond what the developer's own code implies.
    static let openURL = Bridge(
        id: "UIApplication.shared.open(_:)",
        cImportModule: "patch", cImportName: "open_url",
        cDecl: """
        WASM_IMPORT("patch","open_url")
        int32_t patch_open_url(const uint8_t* url, int32_t urlLen);
        """,
        swiftShim: """
        @discardableResult
        @inlinable func _patchFusionOpenURL(_ url: _PatchURLLike) -> Bool {
            let u = Array(url._patchURLString.utf8)
            let r = u.withUnsafeBufferPointer { up in
                patch_open_url(up.baseAddress, Int32(up.count))
            }
            return r != 0
        }
        """)

    /// `NotificationCenter.default.post(name: <name>, object: nil)` → `patch.notify_post`
    /// (fire-and-forget, name only). Matches `NotificationCenterBridge` (module `patch`),
    /// which posts `Notification(name:object:nil)`. The shim takes a
    /// `Notification.Name` (a wasm-safe Foundation value type under the full SDK) and
    /// forwards its `rawValue`. ONLY the `object: nil` form is rewritten — a non-nil
    /// `object:` / a `userInfo:` payload has no value-marshalling path and is left
    /// native (demotes). Posting a name is the dominant real-app shape (decouple a
    /// settings toggle from its observers); the observer side stays NATIVE (see
    /// `addObserver` note in the bridge table — registering a guest closure as an
    /// observer would outlive the WASM instance, so it must not be bridged).
    static let notifyPost = Bridge(
        id: "NotificationCenter.default.post(name:object:nil)",
        cImportModule: "patch", cImportName: "notify_post",
        cDecl: """
        WASM_IMPORT("patch","notify_post")
        void patch_notify_post(const uint8_t* name, int32_t nameLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionNotifyPost(_ name: Notification.Name) {
            let n = Array(name.rawValue.utf8)
            n.withUnsafeBufferPointer { np in
                patch_notify_post(np.baseAddress, Int32(np.count))
            }
        }
        """)

    /// `NSLog(_:)` (single literal/string argument) → `patch.log` at level 1 (info).
    /// Matches `LoggingBridge` (module `patch`). Only the single-string form is
    /// rewritten; format-string `NSLog("%@", x)` is left native (demotes).
    static let logInfo = Bridge(
        id: "NSLog(_:)",
        cImportModule: "patch", cImportName: "log",
        cDecl: """
        WASM_IMPORT("patch","log")
        void patch_log(int32_t level, const uint8_t* msg, int32_t msgLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionLog(_ level: Int32, _ message: String) {
            let m = Array(message.utf8)
            m.withUnsafeBufferPointer { mp in
                patch_log(level, mp.baseAddress, Int32(mp.count))
            }
        }
        """)

    // MARK: - Breakthrough #8 host-ABI bridge FAMILY (module "patch_host")
    //
    // Read-only synchronous native leaves proven end-to-end in executing WASM
    // (the host-bridge design, the host-bridge prototypes,
    // 16/16 checks). Each entry's `(cImportModule, cImportName, signature)` matches
    // a live `imports.host("patch_host", name, …)` registration in
    // `sdk/Sources/PatchSDK/Bridges.swift` (FileManagerBridge / BundleBridge /
    // ProcessInfoBridge.envOSVersion / UserDefaultsBridge typed). The flat C-header
    // ABI (Clang import_module/import_name) is the one WasmKit accepts — verbatim
    // the discipline the existing 5 bridges already encode.

    /// `FileManager.default.fileExists(atPath:)` → `patch_host.file_exists`
    /// (`(ptr,len)->i32`, 1 exists / 0 no). READ-ONLY.
    static let fileExists = Bridge(
        id: "FileManager.default.fileExists(atPath:)",
        cImportModule: "patch_host", cImportName: "file_exists",
        cDecl: """
        WASM_IMPORT("patch_host","file_exists")
        int32_t patch_file_exists(const uint8_t* path, int32_t pathLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionFileExists(_ path: String) -> Bool {
            let p = Array(path.utf8)
            return p.withUnsafeBufferPointer { pp in
                patch_file_exists(pp.baseAddress, Int32(pp.count)) != 0
            }
        }
        """)

    /// `FileManager.default.contents(atPath:)` → `patch_host.file_read`
    /// (packed `(ptr<<32)|len`; 0 = missing/unreadable). READ-ONLY.
    static let fileRead = Bridge(
        id: "FileManager.default.contents(atPath:)",
        cImportModule: "patch_host", cImportName: "file_read",
        cDecl: """
        WASM_IMPORT("patch_host","file_read")
        int64_t patch_file_read(const uint8_t* path, int32_t pathLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionFileContents(_ path: String) -> [UInt8]? {
            let p = Array(path.utf8)
            let packed = p.withUnsafeBufferPointer { pp in
                patch_file_read(pp.baseAddress, Int32(pp.count))
            }
            let (ptr, len) = _patchFusionUnpack(packed)
            if ptr == 0 || len == 0 { return nil }
            return _patchFusionReadBytes(ptr: ptr, len: len)
        }
        """)

    /// `FileManager.default.attributesOfItem(atPath:)[.size]` → `patch_host.file_size`
    /// (`(ptr,len)->i64`; -1 if missing). READ-ONLY (attributes size only).
    static let fileSize = Bridge(
        id: "FileManager.default.attributesOfItem(.size)",
        cImportModule: "patch_host", cImportName: "file_size",
        cDecl: """
        WASM_IMPORT("patch_host","file_size")
        int64_t patch_file_size(const uint8_t* path, int32_t pathLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionFileSize(_ path: String) -> Int64 {
            let p = Array(path.utf8)
            return p.withUnsafeBufferPointer { pp in
                patch_file_size(pp.baseAddress, Int32(pp.count))
            }
        }
        """)

    /// `Bundle.main.object(forInfoDictionaryKey:)` → `patch_host.bundle_info_string`
    /// (packed string; 0 = absent). Host-served value (Info.plist on device).
    static let bundleInfoString = Bridge(
        id: "Bundle.main.object(forInfoDictionaryKey:)",
        cImportModule: "patch_host", cImportName: "bundle_info_string",
        cDecl: """
        WASM_IMPORT("patch_host","bundle_info_string")
        int64_t patch_bundle_info_string(const uint8_t* key, int32_t keyLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionBundleInfoString(_ key: String) -> String? {
            let k = Array(key.utf8)
            let packed = k.withUnsafeBufferPointer { kp in
                patch_bundle_info_string(kp.baseAddress, Int32(kp.count))
            }
            let (ptr, len) = _patchFusionUnpack(packed)
            if ptr == 0 || len == 0 { return nil }
            return _patchFusionReadString(ptr: ptr, len: len)
        }
        """)

    /// `Bundle.main.path(forResource:ofType:)` → `patch_host.bundle_resource_path`
    /// (packed string; 0 = absent). Two `(ptr,len)` pairs (name, ext).
    static let bundleResourcePath = Bridge(
        id: "Bundle.main.path(forResource:ofType:)",
        cImportModule: "patch_host", cImportName: "bundle_resource_path",
        cDecl: """
        WASM_IMPORT("patch_host","bundle_resource_path")
        int64_t patch_bundle_resource_path(const uint8_t* name, int32_t nameLen,
                                           const uint8_t* ext, int32_t extLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionBundleResourcePath(_ name: String, _ ext: String?) -> String? {
            let n = Array(name.utf8), e = Array((ext ?? "").utf8)
            let packed = n.withUnsafeBufferPointer { np in
                e.withUnsafeBufferPointer { ep in
                    patch_bundle_resource_path(np.baseAddress, Int32(np.count),
                                               ep.baseAddress, Int32(ep.count))
                }
            }
            let (ptr, len) = _patchFusionUnpack(packed)
            if ptr == 0 || len == 0 { return nil }
            return _patchFusionReadString(ptr: ptr, len: len)
        }
        """)

    /// `ProcessInfo.processInfo.environment[<name>]` → `patch_host.process_env`
    /// (packed string; 0 = unset). READ-ONLY.
    static let processEnv = Bridge(
        id: "ProcessInfo.processInfo.environment[]",
        cImportModule: "patch_host", cImportName: "process_env",
        cDecl: """
        WASM_IMPORT("patch_host","process_env")
        int64_t patch_process_env(const uint8_t* name, int32_t nameLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionProcessEnv(_ name: String) -> String? {
            let n = Array(name.utf8)
            let packed = n.withUnsafeBufferPointer { np in
                patch_process_env(np.baseAddress, Int32(np.count))
            }
            let (ptr, len) = _patchFusionUnpack(packed)
            if ptr == 0 || len == 0 { return nil }
            return _patchFusionReadString(ptr: ptr, len: len)
        }
        """)

    /// `ProcessInfo.processInfo.operatingSystemVersion` → `patch_host.os_version`
    /// (packed "major.minor.patch" string). The shim parses it back into the same
    /// `(major,minor,patch)` tuple `operatingSystemVersion` yields.
    static let osVersion = Bridge(
        id: "ProcessInfo.processInfo.operatingSystemVersion",
        cImportModule: "patch_host", cImportName: "os_version",
        cDecl: """
        WASM_IMPORT("patch_host","os_version")
        int64_t patch_os_version(void);
        """,
        swiftShim: """
        @inlinable func _patchFusionOSVersion() -> (majorVersion: Int, minorVersion: Int, patchVersion: Int) {
            let packed = patch_os_version()
            let (ptr, len) = _patchFusionUnpack(packed)
            if ptr == 0 || len == 0 { return (0, 0, 0) }
            let s = _patchFusionReadString(ptr: ptr, len: len)
            // Hand-rolled split on "." (no Foundation in the embedded guest).
            var parts: [Int] = [], cur = 0, any = false
            for b in s.utf8 {
                if b == 0x2E { parts.append(cur); cur = 0; any = false }
                else if b >= 0x30 && b <= 0x39 { cur = cur * 10 + Int(b - 0x30); any = true }
            }
            if any { parts.append(cur) }
            while parts.count < 3 { parts.append(0) }
            return (parts[0], parts[1], parts[2])
        }
        """)

    /// `UserDefaults.standard.bool(forKey:)` → `patch_host.defaults_get_bool`
    /// (`(ptr,len)->i32` tri-state 1/0/-1; absent → `false` like UserDefaults).
    static let defaultsGetBool = Bridge(
        id: "UserDefaults.bool(forKey:)",
        cImportModule: "patch_host", cImportName: "defaults_get_bool",
        cDecl: """
        WASM_IMPORT("patch_host","defaults_get_bool")
        int32_t patch_defaults_get_bool(const uint8_t* key, int32_t keyLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionDefaultsGetBool(_ key: String) -> Bool {
            let k = Array(key.utf8)
            let r = k.withUnsafeBufferPointer { kp in
                patch_defaults_get_bool(kp.baseAddress, Int32(kp.count))
            }
            // tri-state: 1 true, 0 false, -1 absent. UserDefaults.bool(forKey:)
            // returns false for an absent key, so -1 collapses to false.
            return r == 1
        }
        """)

    /// `UserDefaults.standard.integer(forKey:)` → `patch_host.defaults_get_int`
    /// (`(ptr,len)->i64`; 0 if absent, matching `integer(forKey:)`).
    static let defaultsGetInt = Bridge(
        id: "UserDefaults.integer(forKey:)",
        cImportModule: "patch_host", cImportName: "defaults_get_int",
        cDecl: """
        WASM_IMPORT("patch_host","defaults_get_int")
        int64_t patch_defaults_get_int(const uint8_t* key, int32_t keyLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionDefaultsGetInt(_ key: String) -> Int {
            let k = Array(key.utf8)
            let r = k.withUnsafeBufferPointer { kp in
                patch_defaults_get_int(kp.baseAddress, Int32(kp.count))
            }
            return Int(r)
        }
        """)

    /// `UserDefaults.standard.double(forKey:)` → `patch_host.defaults_get_double`
    /// (`(ptr,len)->i64` carrying the Double's bit-pattern; 0.0 if absent, matching
    /// `double(forKey:)`). The shim reinterprets the i64 bits as a `Double`.
    static let defaultsGetDouble = Bridge(
        id: "UserDefaults.double(forKey:)",
        cImportModule: "patch_host", cImportName: "defaults_get_double",
        cDecl: """
        WASM_IMPORT("patch_host","defaults_get_double")
        int64_t patch_defaults_get_double(const uint8_t* key, int32_t keyLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionDefaultsGetDouble(_ key: String) -> Double {
            let k = Array(key.utf8)
            let bits = k.withUnsafeBufferPointer { kp in
                patch_defaults_get_double(kp.baseAddress, Int32(kp.count))
            }
            return Double(bitPattern: UInt64(bitPattern: bits))
        }
        """)

    /// `UserDefaults.standard.set(<Bool>, forKey:)` → `patch_host.defaults_set_bool`
    /// (`(key,len, i32)`; 1/0). A TYPED set is a distinct host fn from the String
    /// `defaults_set` because a Bool stored as the string "true" would re-read wrong
    /// via `bool(forKey:)`. Only a literal `true`/`false` value is matched (a
    /// non-literal value is ambiguous → left to the String shim, which compiles only
    /// if it really is a String, else demotes — demote-safe).
    static let defaultsSetBool = Bridge(
        id: "UserDefaults.set(Bool:forKey:)",
        cImportModule: "patch_host", cImportName: "defaults_set_bool",
        cDecl: """
        WASM_IMPORT("patch_host","defaults_set_bool")
        void patch_defaults_set_bool(const uint8_t* key, int32_t keyLen, int32_t value);
        """,
        swiftShim: """
        @inlinable func _patchFusionDefaultsSetBool(_ value: Bool, _ key: String) {
            let k = Array(key.utf8)
            k.withUnsafeBufferPointer { kp in
                patch_defaults_set_bool(kp.baseAddress, Int32(kp.count), value ? 1 : 0)
            }
        }
        """)

    /// `UserDefaults.standard.set(<Int>, forKey:)` → `patch_host.defaults_set_int`
    /// (`(key,len, i64)`). Only a plain integer literal value is matched.
    static let defaultsSetInt = Bridge(
        id: "UserDefaults.set(Int:forKey:)",
        cImportModule: "patch_host", cImportName: "defaults_set_int",
        cDecl: """
        WASM_IMPORT("patch_host","defaults_set_int")
        void patch_defaults_set_int(const uint8_t* key, int32_t keyLen, int64_t value);
        """,
        swiftShim: """
        @inlinable func _patchFusionDefaultsSetInt(_ value: Int, _ key: String) {
            let k = Array(key.utf8)
            k.withUnsafeBufferPointer { kp in
                patch_defaults_set_int(kp.baseAddress, Int32(kp.count), Int64(value))
            }
        }
        """)

    /// `UserDefaults.standard.set(<Double>, forKey:)` → `patch_host.defaults_set_double`
    /// (`(key,len, i64-bits)`). Only a floating-point literal value is matched.
    static let defaultsSetDouble = Bridge(
        id: "UserDefaults.set(Double:forKey:)",
        cImportModule: "patch_host", cImportName: "defaults_set_double",
        cDecl: """
        WASM_IMPORT("patch_host","defaults_set_double")
        void patch_defaults_set_double(const uint8_t* key, int32_t keyLen, int64_t valueBits);
        """,
        swiftShim: """
        @inlinable func _patchFusionDefaultsSetDouble(_ value: Double, _ key: String) {
            let k = Array(key.utf8)
            k.withUnsafeBufferPointer { kp in
                patch_defaults_set_double(kp.baseAddress, Int32(kp.count), Int64(bitPattern: value.bitPattern))
            }
        }
        """)

    // MARK: - Foundation VALUE bridges (Date clock / ISO8601 / NumberFormatter)
    //
    // The "common Foundation value API" leaves — date math, ISO8601 string<->date,
    // localized number formatting — that constantly appear in bug-fix code. Each is
    // a SINGLE deterministic developer call form rewritten to a `patch_host` host
    // import the SDK's FoundationBridge serves with the shell's REAL Foundation/ICU,
    // so the function compiles at T0 (no in-module Foundation) instead of escalating
    // to the ~11.7 MB T2 Foundation tier (or, for the device clock, returning a wrong
    // value the WASM guest's clock-less Foundation would).
    //
    // ALL-OR-NOTHING per call + DEMOTE-SAFE: only the exact bridged form is rewritten;
    // any other shape (a multi-statement `DateFormatter` builder, a non-default
    // `ISO8601DateFormatter` option set, an implicit-locale `NumberFormatter`) is left
    // VERBATIM, so it stays native / T2 and demotes alone — never mis-formatted.

    /// `Date().timeIntervalSince1970` → `patch_host.now_unix_millis` (the shell's real
    /// clock), returned as `Double` SECONDS. PURE scalar result → T0, no Foundation.
    /// The device clock is the one true host fact (a WASM-SDK `Date()` has no real
    /// clock), so this is strictly MORE correct than the native form.
    static let nowUnixSeconds = Bridge(
        id: "Date().timeIntervalSince1970",
        cImportModule: "patch_host", cImportName: "now_unix_millis",
        cDecl: """
        WASM_IMPORT("patch_host","now_unix_millis")
        int64_t patch_now_unix_millis(void);
        """,
        swiftShim: """
        @inlinable func _patchFusionNowUnixSeconds() -> Double {
            Double(patch_now_unix_millis()) / 1000.0
        }
        """)

    /// `Date().timeIntervalSinceNow` → 0 via the host clock (the interval from "now"
    /// to "now" is 0 by definition). Bridged to a pure literal so a `Date()`-relative
    /// computation compiles at T0 with the exact native semantics (Foundation returns
    /// a value within float epsilon of 0; we return exactly 0.0). Demote-safe: only
    /// the bare `Date().timeIntervalSinceNow` form is matched.
    static let nowIntervalSinceNow = Bridge(
        id: "Date().timeIntervalSinceNow",
        cImportModule: "patch_host", cImportName: "now_unix_millis",
        cDecl: """
        WASM_IMPORT("patch_host","now_unix_millis")
        int64_t patch_now_unix_millis(void);
        """,
        swiftShim: """
        @inlinable func _patchFusionNowIntervalSinceNow() -> Double {
            // `Date().timeIntervalSinceNow` ≡ 0 (now relative to now). Touch the host
            // clock so the call is a genuine host read (and shares the import decl).
            _ = patch_now_unix_millis()
            return 0.0
        }
        """)

    /// `ISO8601DateFormatter().string(from: <date>)` → `patch_host.iso8601_format`.
    /// The arg is a `Date` (a WASM-SDK Foundation value type) → the shim needs
    /// Foundation (the result is a plain `String`). ISO8601 default options are a
    /// FIXED, locale-independent, UTC wire format — zero fidelity risk.
    static let iso8601String = Bridge(
        id: "ISO8601DateFormatter().string(from:)",
        cImportModule: "patch_host", cImportName: "iso8601_format",
        cDecl: """
        WASM_IMPORT("patch_host","iso8601_format")
        int64_t patch_iso8601_format(int64_t unixMillis);
        """,
        swiftShim: """
        @inlinable func _patchFusionISO8601String(_ date: Date) -> String {
            let ms = Int64((date.timeIntervalSince1970 * 1000.0).rounded())
            let packed = patch_iso8601_format(ms)
            let (ptr, len) = _patchFusionUnpack(packed)
            if ptr == 0 || len == 0 { return "" }
            return _patchFusionReadString(ptr: ptr, len: len)
        }
        """)

    /// `ISO8601DateFormatter().date(from: <string>)` → `patch_host.iso8601_parse`.
    /// Returns `Date?` (nil when the string does not parse — the host returns the
    /// `INT64_MIN` sentinel). The shim reconstructs a `Date` from the host millis →
    /// needs Foundation. Fixed format, no fidelity risk.
    static let iso8601Date = Bridge(
        id: "ISO8601DateFormatter().date(from:)",
        cImportModule: "patch_host", cImportName: "iso8601_parse",
        cDecl: """
        WASM_IMPORT("patch_host","iso8601_parse")
        int64_t patch_iso8601_parse(const uint8_t* str, int32_t strLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionISO8601Date(_ string: String) -> Date? {
            let s = Array(string.utf8)
            let ms = s.withUnsafeBufferPointer { sp in
                patch_iso8601_parse(sp.baseAddress, Int32(sp.count))
            }
            if ms == Int64.min { return nil }
            return Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        """)

    // MARK: - LEVER #2: Date/Calendar/Formatter host bridges (locale/ICU on the shell)
    //
    // The most common bug-fix shapes — relative-date phrasing, localized number/
    // currency formatting, styled date formatting, Calendar date math — need ICU +
    // locale data the Embedded guest has none of (~11.7 MB if linked → T2). Each leaf
    // rewrites the canonical developer form to a `patch_host` import the SDK's
    // FoundationBridge serves with the shell's REAL Foundation/ICU, so the function
    // ships at T0. DEMOTE-SAFE: only the exact canonical builder shape is matched; any
    // configured-formatter / unusual form is left verbatim → stays native/T2.
    //
    // FIDELITY DISCIPLINE: the developer's EXPLICIT style + locale pass through to the
    // shell (never silently defaulted to a wrong locale). The result is a plain String
    // (or a Date the shim rebuilds from host millis), so the leaf is value-clean.

    /// `RelativeDateTimeFormatter().localizedString(for:relativeTo:)` (a 3-statement
    /// builder: init + `.unitsStyle =` + the call) → `patch_host.relative_date_format`.
    /// The FUSION rewrite collapses the WHOLE builder to a single shim call carrying
    /// the two `Date`s + the resolved unitsStyle code. This is the
    /// `SettingsScreen.relativeString` real-app bug-fix target. The shim needs
    /// Foundation (the `Date` args), returns a plain `String`.
    static let relativeDateString = Bridge(
        id: "RelativeDateTimeFormatter.localizedString(for:relativeTo:)",
        cImportModule: "patch_host", cImportName: "relative_date_format",
        cDecl: """
        WASM_IMPORT("patch_host","relative_date_format")
        int64_t patch_relative_date_format(int64_t forMillis, int64_t relativeToMillis,
                                           int32_t unitsStyle, const uint8_t* loc, int32_t locLen);
        WASM_IMPORT("patch_host","now_unix_millis")
        int64_t patch_now_unix_millis(void);
        """,
        swiftShim: """
        // unitsStyle codes (the host enum order). Named so the rewrite can emit the
        // captured style NAME (`.abbreviated`) as a stable identifier the shim resolves.
        @usableFromInline let _patchFusionRelStyle_full: Int32 = 0
        @usableFromInline let _patchFusionRelStyle_spellOut: Int32 = 1
        @usableFromInline let _patchFusionRelStyle_short: Int32 = 2
        @usableFromInline let _patchFusionRelStyle_abbreviated: Int32 = 3
        @inlinable func _patchFusionRelativeDateString(_ date: Date, _ relativeTo: Date, _ unitsStyle: Int32) -> String {
            let forMs = Int64((date.timeIntervalSince1970 * 1000.0).rounded())
            let refMs = Int64((relativeTo.timeIntervalSince1970 * 1000.0).rounded())
            let loc = Array("".utf8)
            let packed = loc.withUnsafeBufferPointer { lp in
                patch_relative_date_format(forMs, refMs, unitsStyle, lp.baseAddress, Int32(lp.count))
            }
            let (ptr, len) = _patchFusionUnpack(packed)
            if ptr == 0 || len == 0 { return "" }
            return _patchFusionReadString(ptr: ptr, len: len)
        }
        // A `relativeTo: .now` form: the WASM-SDK guest `Date.now` has no real clock, so
        // resolve "now" from the host clock (the one true fact) instead of a clock-less
        // guest Date — strictly MORE correct, matching the `Date().timeInterval*` bridges.
        @inlinable func _patchFusionRelativeDateStringToNow(_ date: Date, _ unitsStyle: Int32) -> String {
            let nowSeconds = Double(patch_now_unix_millis()) / 1000.0
            return _patchFusionRelativeDateString(date, Date(timeIntervalSince1970: nowSeconds), unitsStyle)
        }
        """)

    /// `NumberFormatter` localized number/currency/percent string (a builder:
    /// init + `.numberStyle =` + an EXPLICIT, EQUAL `.minimumFractionDigits =
    /// .maximumFractionDigits = N` + a `.string(from: NSNumber(value:))` call) →
    /// `patch_host.number_format`. The rewrite collapses the canonical 4-statement
    /// builder to one shim call. The FoundationBridge.numberFormat already exists;
    /// this widens its callers from a pre-built shim to the in-source builder form.
    /// Locale-aware (en_US default if unspecified). Pure Double → String → the shim
    /// needs no Foundation.
    ///
    /// FIDELITY DISCIPLINE (why the fraction digits must be EXPLICIT + EQUAL): the
    /// SDK shim (`FoundationBridge.numberFormat`) applies the single `fractionDigits`
    /// arg to BOTH `minimumFractionDigits` AND `maximumFractionDigits`. So only a
    /// builder that ALSO sets BOTH to the SAME value is faithfully representable —
    /// the rewrite matches exactly that shape. A builder that omits the fraction
    /// digits (relying on the style's native defaults — `.currency`→2, `.decimal`→
    /// max 3, etc.) is NOT matched (passing 0 would force integer-only output, a
    /// silent wrong render); it stays native and demotes alone. The `value` is
    /// wrapped in `Double(...)` so an `Int`/`Decimal`-valued `NSNumber(value:)`
    /// round-trips through the Double-typed shim.
    static let numberFormatStyled = Bridge(
        id: "NumberFormatter.string(from:)",
        cImportModule: "patch_host", cImportName: "number_format",
        cDecl: """
        WASM_IMPORT("patch_host","number_format")
        int64_t patch_number_format(int64_t valueBits, int32_t style, int32_t fractionDigits,
                                    const uint8_t* loc, int32_t locLen);
        """,
        swiftShim: """
        // numberStyle codes (the host enum order: 0=decimal 1=currency 2=percent).
        // Named so the rewrite can emit the captured style NAME as a stable id.
        @usableFromInline let _patchFusionNumStyle_decimal: Int32 = 0
        @usableFromInline let _patchFusionNumStyle_currency: Int32 = 1
        @usableFromInline let _patchFusionNumStyle_percent: Int32 = 2
        @inlinable func _patchFusionNumberFormat(_ value: Double, _ style: Int32, _ fractionDigits: Int32, _ locale: String) -> String {
            let loc = Array(locale.utf8)
            let packed = loc.withUnsafeBufferPointer { lp in
                patch_number_format(Int64(bitPattern: value.bitPattern), style, fractionDigits, lp.baseAddress, Int32(lp.count))
            }
            let (ptr, len) = _patchFusionUnpack(packed)
            if ptr == 0 || len == 0 { return "" }
            return _patchFusionReadString(ptr: ptr, len: len)
        }
        """)

    /// `Calendar.current.startOfDay(for: <date>)` → `patch_host.calendar_date_op`
    /// (op 0). Returns a `Date` (the shim rebuilds it from host millis) → needs
    /// Foundation. The "midnight of the day" math the user's real region computes.
    static let calendarStartOfDay = Bridge(
        id: "Calendar.current.startOfDay(for:)",
        cImportModule: "patch_host", cImportName: "calendar_date_op",
        cDecl: """
        WASM_IMPORT("patch_host","calendar_date_op")
        int64_t patch_calendar_date_op(int32_t op, int64_t a, int64_t b, int32_t component,
                                       const uint8_t* tz, int32_t tzLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionCalendarStartOfDay(_ date: Date) -> Date {
            let a = Int64((date.timeIntervalSince1970 * 1000.0).rounded())
            let tz = Array("".utf8)
            let ms = tz.withUnsafeBufferPointer { tp in
                patch_calendar_date_op(0, a, 0, 0, tp.baseAddress, Int32(tp.count))
            }
            return Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        """)

    /// `Calendar.current.isDate(<a>, inSameDayAs: <b>)` → `patch_host.calendar_date_op`
    /// (op 2, returns 1/0). Pure `Bool` → no Foundation needed beyond the `Date` args.
    static let calendarSameDay = Bridge(
        id: "Calendar.current.isDate(_:inSameDayAs:)",
        cImportModule: "patch_host", cImportName: "calendar_date_op",
        cDecl: """
        WASM_IMPORT("patch_host","calendar_date_op")
        int64_t patch_calendar_date_op(int32_t op, int64_t a, int64_t b, int32_t component,
                                       const uint8_t* tz, int32_t tzLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionCalendarSameDay(_ a: Date, _ b: Date) -> Bool {
            let am = Int64((a.timeIntervalSince1970 * 1000.0).rounded())
            let bm = Int64((b.timeIntervalSince1970 * 1000.0).rounded())
            let tz = Array("".utf8)
            let r = tz.withUnsafeBufferPointer { tp in
                patch_calendar_date_op(2, am, bm, 0, tp.baseAddress, Int32(tp.count))
            }
            return r == 1
        }
        """)

    // MARK: - LEVER: Regex host bridges (the signed app's real ICU NSRegularExpression)
    //
    // `NSRegularExpression` / `String.range(of:options:.regularExpression)` ship at T2
    // today (the patch statically links ICU, ~11.7 MB). Regex validation/parsing/extract
    // is a common bug-fix shape. Each leaf rewrites a canonical developer form to a
    // `patch_host.regex_*` import the SDK's FoundationBridge serves with the shell's REAL
    // ICU `NSRegularExpression`, so the function ships at T0 (no in-module ICU) AND uses
    // the device's exact, version-stable regex engine.
    //
    // FIDELITY DISCIPLINE: only the EXACT bridged forms are rewritten. `firstMatch`/
    // `numberOfMatches`/`stringByReplacingMatches` on a BARE `NSRegularExpression(pattern:)`
    // (the single-use form), and the `.regularExpression`-option String shapes. Any
    // configured/reused regex (a stored `let re = …`, `.caseInsensitive` options, a
    // closure-style `enumerateMatches`, an iOS-16 `Regex` literal) is left verbatim →
    // stays native/T2 and demotes alone (never wrong results). The pure-Bool/Int shims
    // are scalar (T0, no Foundation); the String-returning shims return a plain `String`
    // (still T0 — no Foundation value type crosses the boundary).

    /// `str.range(of: <pat>, options: .regularExpression) != nil` (a Bool TEST — the
    /// dominant validation form) → `patch_host.regex_test`. The shim returns `Bool`. The
    /// pattern is the developer's expression (a string literal or a ref). Only the
    /// `.regularExpression`-option form is matched (a plain `range(of:)` substring search
    /// is a different operation and is NOT touched).
    static let regexTest = Bridge(
        id: "String.range(of:options:.regularExpression)",
        cImportModule: "patch_host", cImportName: "regex_test",
        cDecl: """
        WASM_IMPORT("patch_host","regex_test")
        int32_t patch_regex_test(const uint8_t* str, int32_t strLen,
                                 const uint8_t* pat, int32_t patLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionRegexTest(_ str: String, _ pattern: String) -> Bool {
            let s = Array(str.utf8), p = Array(pattern.utf8)
            let r = s.withUnsafeBufferPointer { sp in
                p.withUnsafeBufferPointer { pp in
                    patch_regex_test(sp.baseAddress, Int32(sp.count), pp.baseAddress, Int32(pp.count))
                }
            }
            return r != 0
        }
        """)

    /// `NSRegularExpression(pattern: <pat>).firstMatch(...)` whole-match extraction →
    /// `patch_host.regex_capture` group 0 (returns `String?`, nil on no match / invalid
    /// pattern). The capture-group form (`group: n`) routes to the same import with the
    /// caller's group index; the whole-match form uses group 0.
    static let regexCapture = Bridge(
        id: "NSRegularExpression.firstMatch.capture",
        cImportModule: "patch_host", cImportName: "regex_capture",
        cDecl: """
        WASM_IMPORT("patch_host","regex_capture")
        int64_t patch_regex_capture(const uint8_t* str, int32_t strLen,
                                    const uint8_t* pat, int32_t patLen, int32_t group);
        """,
        swiftShim: """
        @inlinable func _patchFusionRegexCapture(_ str: String, _ pattern: String, _ group: Int32) -> String? {
            let s = Array(str.utf8), p = Array(pattern.utf8)
            let packed = s.withUnsafeBufferPointer { sp in
                p.withUnsafeBufferPointer { pp in
                    patch_regex_capture(sp.baseAddress, Int32(sp.count), pp.baseAddress, Int32(pp.count), group)
                }
            }
            let (ptr, len) = _patchFusionUnpack(packed)
            if ptr == 0 || len == 0 { return nil }
            return _patchFusionReadString(ptr: ptr, len: len)
        }
        """)

    /// `NSRegularExpression(pattern: <pat>).numberOfMatches(...)` → `patch_host.regex_count`
    /// (the match-count form, distinct from the `regexCount` static used by other tests).
    /// Returns `Int`. Invalid pattern → 0.
    static let regexCount = Bridge(
        id: "NSRegularExpression.numberOfMatches",
        cImportModule: "patch_host", cImportName: "regex_count",
        cDecl: """
        WASM_IMPORT("patch_host","regex_count")
        int32_t patch_regex_count(const uint8_t* str, int32_t strLen,
                                  const uint8_t* pat, int32_t patLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionRegexCount(_ str: String, _ pattern: String) -> Int {
            let s = Array(str.utf8), p = Array(pattern.utf8)
            let r = s.withUnsafeBufferPointer { sp in
                p.withUnsafeBufferPointer { pp in
                    patch_regex_count(sp.baseAddress, Int32(sp.count), pp.baseAddress, Int32(pp.count))
                }
            }
            return Int(r)
        }
        """)

    /// `str.replacingOccurrences(of: <pat>, with: <tmpl>, options: .regularExpression)` AND
    /// `NSRegularExpression(pattern: <pat>).stringByReplacingMatches(...withTemplate: <tmpl>)`
    /// → `patch_host.regex_replace` (ICU template replace over ALL matches). Returns the
    /// replaced `String`; an invalid pattern returns the input unchanged (matching the
    /// native no-op). Only the `.regularExpression`-option replace is matched (a literal
    /// `replacingOccurrences` is a different operation and is left untouched).
    static let regexReplace = Bridge(
        id: "String.replacingOccurrences(of:with:.regularExpression)",
        cImportModule: "patch_host", cImportName: "regex_replace",
        cDecl: """
        WASM_IMPORT("patch_host","regex_replace")
        int64_t patch_regex_replace(const uint8_t* str, int32_t strLen,
                                    const uint8_t* pat, int32_t patLen,
                                    const uint8_t* tmpl, int32_t tmplLen);
        """,
        swiftShim: """
        @inlinable func _patchFusionRegexReplace(_ str: String, _ pattern: String, _ template: String) -> String {
            let s = Array(str.utf8), p = Array(pattern.utf8), t = Array(template.utf8)
            let packed = s.withUnsafeBufferPointer { sp in
                p.withUnsafeBufferPointer { pp in
                    t.withUnsafeBufferPointer { tp in
                        patch_regex_replace(sp.baseAddress, Int32(sp.count),
                                            pp.baseAddress, Int32(pp.count),
                                            tp.baseAddress, Int32(tp.count))
                    }
                }
            }
            let (ptr, len) = _patchFusionUnpack(packed)
            // A 0-packed result is an EMPTY result string (the whole input matched and
            // was replaced away). The invalid-pattern case is handled host-side: the host
            // returns the INPUT unchanged (so it round-trips through here as the input,
            // not as 0). Either way the value is faithful.
            if ptr == 0 || len == 0 { return "" }
            return _patchFusionReadString(ptr: ptr, len: len)
        }
        """)

    // MARK: - Breakthrough #6 — NETWORKING (URLSession) async host bridge
    //
    // The dominant real-app async shape: a function that is `async` ONLY because it
    // `await`s `URLSession`, then decodes JSON + runs value-type logic. Proven
    // end-to-end in executing WASM (the host-bridge design, 6/6
    // incl a live HTTPS fetch). This is the async sibling of the #8 family: the host
    // import returns `()` (the guest SUSPENDS via a continuation), the host performs
    // the REAL `URLSession` fetch on its own run loop, and resumes the guest by
    // calling `patch_resolve_http(token, dataPtr, dataLen, status)` — writing the
    // response bytes into guest linear memory via the guest's exported `patch_malloc`
    // (same ownership model as the packed-string returns). v1 scope: GET + simple
    // POST request/response + decode; streaming/websockets/upload/delegates stay
    // native (registry mustStayNative). cookies/TLS/auth stay HOST-side (the security
    // win — credentials never enter WASM).

    /// `await URLSession.shared.data(from: url)` → `patch_host.http_get` (async
    /// suspend). The shim is `async`, returns `(Data, _PatchHTTPURLResponse)` (a plain
    /// value struct carrying the status). The host writes the body into guest memory +
    /// resolves with the HTTP status.
    ///
    /// NB on the response type: the shim deliberately returns a `_PatchHTTPURLResponse`
    /// VALUE struct, not Foundation's `URLResponse`/`HTTPURLResponse`. Under the WASM
    /// SDK `URLRequest` is NOT in the guest's Foundation (verified by compiling the
    /// emitted bridge under swift-6.3.2-RELEASE_wasm), and the NS-bridged response
    /// types are fragile to extend; a value struct is portable and is all the
    /// request/response value logic actually reads (`statusCode`). `URL` IS available,
    /// so the URL arg accepts a real `URL` or a `String` via `_PatchURLLike`.
    static let httpGet = Bridge(
        id: "URLSession.data(from:)",
        cImportModule: "patch_host", cImportName: "http_get",
        cDecl: """
        WASM_IMPORT("patch_host","http_get")
        void patch_http_get(const uint8_t* url, int32_t urlLen, int32_t token);
        """,
        swiftShim: """
        @inlinable func _patchFusionURLSessionDataFrom(_ url: _PatchURLLike) async throws -> (Data, _PatchHTTPURLResponse) {
            let bytes = try await _patchFusionHTTPGet(url._patchURLString)
            return (Data(bytes.body), _PatchHTTPURLResponse(statusCode: bytes.status, url: url._patchURLString))
        }
        """,
        isAsync: true)

    // NOTE — `data(for: URLRequest)` is DEFERRED from v1 (not a bridge entry). The
    // guest's Foundation under the WASM SDK does NOT provide `URLRequest` (verified:
    // `import Foundation` cannot find `URLRequest` under swift-6.3.2-RELEASE_wasm),
    // so a function that builds a `URLRequest` will not compile in WASM regardless of
    // fusion — there is nothing to unlock. `URLRequest` therefore correctly stays in
    // the mustStayNative-adjacent set and `data(for:)` is left native (demotes alone).
    // The host import `patch_host.http_request` is still SERVED by the SDK (for a
    // future value-type request shim), but no engine rewrite targets it in v1.

    /// All bridges, by id. The first 5 are breakthrough #2; the #8 host-ABI bridge
    /// family (module "patch_host") follows; the last is the breakthrough #6
    /// NETWORKING async bridge (module "patch_host", `isAsync`). `data(for:)` is
    /// deferred (URLRequest absent in the WASM-SDK guest Foundation).
    public static let allBridges: [Bridge] = [
        defaultsGet, defaultsSet, localeIdentifier, timezoneIdentifier, logInfo,
        // Business-logic action/onChange leaves (settings + links + events):
        openURL, notifyPost,
        // Breakthrough #8 family:
        fileExists, fileRead, fileSize,
        bundleInfoString, bundleResourcePath,
        processEnv, osVersion,
        defaultsGetBool, defaultsGetInt,
        // Typed UserDefaults get/set (the settings-toggle workhorse):
        defaultsGetDouble, defaultsSetBool, defaultsSetInt, defaultsSetDouble,
        // Foundation VALUE bridges (date math / ISO8601):
        nowUnixSeconds, nowIntervalSinceNow, iso8601String, iso8601Date,
        // LEVER #2: Date/Calendar/Formatter (locale/ICU on the shell):
        relativeDateString, numberFormatStyled, calendarStartOfDay, calendarSameDay,
        // LEVER: Regex (the shell's real ICU NSRegularExpression):
        regexTest, regexCapture, regexCount, regexReplace,
        // Breakthrough #6 networking (async):
        httpGet,
    ]

    // MARK: - LEVER #2 hook — the GENERALIZED "call what's already linked" path
    //
    // The curated rewrite above handles a CLOSED set of leaves. The generalized
    // path (`GeneralBridgeRewriter`) routes ARBITRARY already-linked symbols
    // through the single `patch_host.call` import. This hook is deliberately
    // TINY: it hands a classified call-site candidate to the general rewriter and
    // returns the emitted guest sequence (or nil → keep native). The call-site
    // EXTRACTION (turning parsed source into `Candidate`s) and the ABI-core wiring
    // are owned by parallel work; this method is the seam that joins the curated
    // FusionRewriter to the generalized classifier so both live behind one entry.
    //
    // DEMOTE-ON-DOUBT: a `.demote` verdict returns nil and the caller leaves the
    // call verbatim (native). Only a `.route` verdict produces a rewrite.
    public func generalBridgeSequence(
        for candidate: GeneralBridgeRewriter.Candidate,
        abi: HostBridgeABIProvider = StubHostBridgeABI()
    ) -> String? {
        let rw = GeneralBridgeRewriter(abi: abi)
        guard case .route(let site) = rw.classify(candidate) else { return nil }
        return rw.emitGuestSequence(site)
    }

    // MARK: - Rewrite

    public struct RewriteResult {
        /// The rewritten source (verbatim where nothing matched).
        public let source: String
        /// The leaf ids bridged in this file (for reporting + which shims to emit).
        public let bridgedLeaves: Set<String>
        public var didRewrite: Bool { !bridgedLeaves.isEmpty }
    }

    /// Rewrite every recognized bridgeable native call site in `source` to its host
    /// bridge shim. CONSERVATIVE: only exact, syntactically-unambiguous textual
    /// patterns are rewritten; anything else is left verbatim (so a genuinely-native
    /// or unrecognized reference still fails the real compile and demotes alone —
    /// the demote-safety guarantee is preserved). Returns the rewritten text and the
    /// set of leaf ids that fired.
    public func rewrite(_ source: String) -> RewriteResult {
        var out = source
        var fired = Set<String>()

        for (pattern, replacement, leafID) in Self.patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
                continue
            }
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            // Only rewrite matches that are genuine CODE — never a call form that
            // happens to appear inside a string literal or a `//` comment. A plain
            // `stringByReplacingMatches` corrupted a string whose VALUE contained
            // `Locale.current.identifier` (turning the literal into a call), silently
            // shipping wrong runtime behavior. Apply replacements right-to-left so
            // earlier ranges stay valid as we splice.
            let masked = Self.codeMask(ns as String)
            var anyFired = false
            for m in matches.reversed() {
                let r = m.range
                guard r.location != NSNotFound,
                      Self.matchHeadIsCode(r, mask: masked) else { continue }
                // BUG R4-#1367/#1410: a formatter-builder rewrite (RelativeDateTimeFormatter
                // / NumberFormatter) collapses the WHOLE builder — INCLUDING its
                // `let <f> = …Formatter()` declaration — into a single shim call, DROPPING
                // the declaration. The "reused formatter doesn't match" reasoning only
                // holds WITHIN the matched window: a use of `<f>` ELSEWHERE in the source
                // (not part of this builder) would be left referencing an undeclared
                // variable (non-compiling guest). If the matched window declares a
                // formatter whose name is referenced OUTSIDE this match, skip the rewrite
                // (leave native → demote-safe).
                if let declared = Self.declaredFormatterName(inMatch: r, of: ns),
                   Self.identifierUsedOutside(declared, range: r, in: ns) {
                    continue
                }
                let replaced = re.replacementString(for: m, in: out, offset: 0, template: replacement)
                out = (out as NSString).replacingCharacters(in: r, with: replaced)
                anyFired = true
            }
            if anyFired { fired.insert(leafID) }
        }

        return RewriteResult(source: out, bridgedLeaves: fired)
    }

    /// If the matched window declares a formatter local — `let <name> = <X>Formatter()`
    /// (a `RelativeDateTimeFormatter`/`NumberFormatter`/`DateFormatter`/… builder whose
    /// `let` the rewrite DROPS) — return that `<name>`; otherwise nil. Used by the
    /// usage-count guard so only a declare-and-drop builder rewrite is protected (a
    /// regex/calendar one-liner match has no such decl → guard is inert).
    static func declaredFormatterName(inMatch r: NSRange, of ns: NSString) -> String? {
        guard r.location != NSNotFound, r.length > 0 else { return nil }
        let window = ns.substring(with: r)
        guard let re = try? NSRegularExpression(
            pattern: #"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*[A-Za-z_][A-Za-z0-9_]*Formatter\(\)"#) else {
            return nil
        }
        let wns = window as NSString
        guard let m = re.firstMatch(in: window, range: NSRange(location: 0, length: wns.length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return wns.substring(with: m.range(at: 1))
    }

    /// True iff `name` (a whole-identifier, code-position reference) appears in `ns`
    /// OUTSIDE the matched window `r`. A reference inside a string literal/comment is
    /// ignored (it isn't a real use). Conservative: any out-of-window code reference
    /// means the formatter is used beyond the builder window → the rewrite (which
    /// drops the declaration) would leave that reference dangling.
    static func identifierUsedOutside(_ name: String, range r: NSRange, in ns: NSString) -> Bool {
        let pattern = #"(?<![A-Za-z0-9_.])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![A-Za-z0-9_])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let full = ns as String
        let mask = codeMask(full)
        let matches = re.matches(in: full, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let mr = m.range
            // Inside the rewritten window — that occurrence is consumed by the rewrite.
            if mr.location >= r.location && (mr.location + mr.length) <= (r.location + r.length) {
                continue
            }
            // A reference in a string/comment is not a real code use.
            if mr.location < mask.count, mask[mr.location] == false { continue }
            return true
        }
        return false
    }

    /// A per-UTF-16-offset mask: `true` where the character is ordinary CODE,
    /// `false` where it is inside a string literal (`"…"`, honoring `\"` escapes —
    /// AND a raw string `#"…"#` / `##"…"##`, where backslash is NOT an escape and
    /// the literal closes only at `"` followed by the SAME number of `#`s), a
    /// `//` line comment, OR a `/* … */` block comment (Swift block comments NEST,
    /// so a `blockCommentDepth` counter tracks `/*`/`*/` pairs). Deliberately
    /// conservative — it does not model `'` (Swift has no char literal). Modelling
    /// raw strings stops a regex/UserDefaults/date call FORM appearing as DATA
    /// inside `#"…"#` from being mis-masked as CODE and wrongly rewritten (BUG #55).
    /// Modelling BLOCK comments stops a stray `"` inside `/* it's a " */` from
    /// opening a PHANTOM string region that swallows (mis-masks) the real code that
    /// follows — silently losing a legitimate rewrite (BUG R2-#101). A bridge call
    /// FORM that appears inside a block comment is correctly left un-rewritten
    /// (its head is masked).
    static func codeMask(_ s: String) -> [Bool] {
        let u = Array(s.utf16)
        var mask = [Bool](repeating: true, count: u.count)
        var inString = false
        var rawHashCount = 0           // >0 ⇒ inside a raw string with this many delimiter `#`s
        var inMultilineString = false  // inside a `""" … """` multi-line string literal
        var inLineComment = false
        var blockCommentDepth = 0      // >0 ⇒ inside a (possibly nested) `/* … */` block comment
        var i = 0
        let quote: UInt16 = 0x22       // "
        let hash: UInt16 = 0x23        // #
        let backslash: UInt16 = 0x5C   // \
        let slash: UInt16 = 0x2F       // /
        let star: UInt16 = 0x2A        // *
        let newline: UInt16 = 0x0A     // \n
        while i < u.count {
            let c = u[i]
            // Block comments take precedence over string/line-comment opening: a `"`
            // or `//` inside a block comment is just comment text (NOT a string/line
            // comment), and Swift block comments NEST (`/* /* */ */`).
            if blockCommentDepth > 0 {
                mask[i] = false
                if c == slash, i + 1 < u.count, u[i + 1] == star {
                    mask[i + 1] = false
                    blockCommentDepth += 1
                    i += 2
                    continue
                }
                if c == star, i + 1 < u.count, u[i + 1] == slash {
                    mask[i + 1] = false
                    blockCommentDepth -= 1
                    i += 2
                    continue
                }
                i += 1
                continue
            }
            if inLineComment {
                mask[i] = false
                if c == newline { inLineComment = false }
                i += 1
                continue
            }
            if inMultilineString {
                // BUG R4-#1124: a `""" … """` multi-line string is masked WHOLE (its
                // content, including `\(...)` interpolation and any unbalanced `"`, is
                // non-code). It closes only on the next `"""`. A `\` escapes the next
                // char (so `\"""` does not close), mirroring the single-line handling.
                mask[i] = false
                if c == backslash, i + 1 < u.count {
                    mask[i + 1] = false
                    i += 2
                    continue
                }
                if c == quote, i + 2 < u.count, u[i + 1] == quote, u[i + 2] == quote {
                    mask[i + 1] = false
                    mask[i + 2] = false
                    i += 3
                    inMultilineString = false
                    continue
                }
                i += 1
                continue
            }
            if inString {
                mask[i] = false
                if rawHashCount > 0 {
                    // RAW string: backslash is literal (not an escape). The literal
                    // closes only at `"` immediately followed by exactly `rawHashCount`
                    // `#`s. A bare `"` (or one with the wrong number of `#`s) stays
                    // inside the string — so embedded code FORMS are kept masked.
                    if c == quote, i + rawHashCount < u.count,
                       (1...rawHashCount).allSatisfy({ u[i + $0] == hash }) {
                        for k in 0...rawHashCount { mask[i + k] = false }
                        i += rawHashCount + 1
                        inString = false
                        rawHashCount = 0
                        continue
                    }
                    i += 1
                    continue
                }
                if c == backslash, i + 1 < u.count {
                    // Escaped char (e.g. \") stays inside the string.
                    mask[i + 1] = false
                    i += 2
                    continue
                }
                if c == quote { inString = false }
                i += 1
                continue
            }
            // Ordinary code.
            if c == hash {
                // A run of `#`s immediately followed by `"` opens a raw string literal.
                var h = 0
                while i + h < u.count, u[i + h] == hash { h += 1 }
                if i + h < u.count, u[i + h] == quote {
                    inString = true
                    rawHashCount = h
                    for k in 0...h { mask[i + k] = false }   // the `#`s and the opening `"`
                    i += h + 1
                    continue
                }
                // A lone `#` (e.g. `#available`, `#selector`) is ordinary code.
            } else if c == quote, i + 2 < u.count, u[i + 1] == quote, u[i + 2] == quote {
                // A `"""` run opens a multi-line string literal (handled above). Without
                // this, `"""` was processed as three single-`"` toggles, so multiline
                // content with an unbalanced `"` mis-masked the following real code.
                inMultilineString = true
                mask[i] = false
                mask[i + 1] = false
                mask[i + 2] = false
                i += 3
                continue
            } else if c == quote {
                inString = true
                rawHashCount = 0
                mask[i] = false
            } else if c == slash, i + 1 < u.count, u[i + 1] == slash {
                inLineComment = true
                mask[i] = false
            } else if c == slash, i + 1 < u.count, u[i + 1] == star {
                // Open a `/* … */` block comment (nestable).
                blockCommentDepth = 1
                mask[i] = false
                mask[i + 1] = false
                i += 2
                continue
            }
            i += 1
        }
        return mask
    }

    /// True iff the match's HEAD (its first character — the call's leading token,
    /// e.g. the `U` of `UserDefaults` or the `L` of `Locale`) is ordinary CODE.
    ///
    /// We anchor on the head, NOT the whole span: a genuine code call legitimately
    /// CONTAINS a string-literal argument (`UserDefaults.standard.string(forKey: "k")`),
    /// whose `"k"` is correctly masked — so an all-span check would wrongly reject
    /// the real call. A call form that is itself embedded in a string literal or a
    /// `//` comment, however, has its HEAD inside the masked region, so it is skipped.
    static func matchHeadIsCode(_ range: NSRange, mask: [Bool]) -> Bool {
        guard range.location >= 0, range.location < mask.count else { return false }
        return mask[range.location]
    }

    /// The (regex, replacement, leafID) table. Each pattern is anchored on a
    /// distinctive native call form. Capture groups carry the developer's own
    /// argument expressions through verbatim. Kept deliberately narrow: a false
    /// rewrite would change behavior, while a missed rewrite merely demotes (safe).
    ///
    /// `$1`/`$2` in the replacement are captures. Raw string literals (`#"…"#`) keep
    /// regex backslashes single.
    static let patterns: [(pattern: String, replacement: String, leafID: String)] = [
        // UserDefaults.standard.string(forKey: <expr>)  →  _patchFusionDefaultsGetString(<expr>)
        // The key argument is a literal or simple ref (no nested parens in practice).
        (#"UserDefaults\.standard\.string\(forKey:\s*([^()]+?)\)"#,
         "_patchFusionDefaultsGetString($1)",
         defaultsGet.id),

        // ---- TYPED UserDefaults set (literal value) — MUST precede the String set ----
        // A typed `set` is routed to its own host fn so the value round-trips
        // losslessly (a Bool stored as the string "true" would re-read wrong). Only a
        // LITERAL value is matched — its type is then textually unambiguous. These run
        // BEFORE the String-set pattern so a typed literal is consumed here; a
        // non-literal value (`set(x, forKey:)`) falls through to the String pattern,
        // which compiles only if `x` really is a String (else the function demotes —
        // demote-safe). Double is matched before Int (a Double literal contains digits).
        //
        // set(true|false, forKey: <key>)  →  _patchFusionDefaultsSetBool(<bool>, <key>)
        (#"UserDefaults\.standard\.set\((true|false),\s*forKey:\s*([^()]+?)\)"#,
         "_patchFusionDefaultsSetBool($1, $2)",
         defaultsSetBool.id),
        // set(<float literal>, forKey: <key>)  →  _patchFusionDefaultsSetDouble(<double>, <key>)
        // A decimal point disambiguates a Double from an Int literal.
        (#"UserDefaults\.standard\.set\((-?[0-9]+\.[0-9]+),\s*forKey:\s*([^()]+?)\)"#,
         "_patchFusionDefaultsSetDouble($1, $2)",
         defaultsSetDouble.id),
        // set(<integer literal>, forKey: <key>)  →  _patchFusionDefaultsSetInt(<int>, <key>)
        (#"UserDefaults\.standard\.set\((-?[0-9]+),\s*forKey:\s*([^()]+?)\)"#,
         "_patchFusionDefaultsSetInt($1, $2)",
         defaultsSetInt.id),

        // UserDefaults.standard.set(<value>, forKey: <key>)  →  _patchFusionDefaultsSetString(<value>, <key>)
        // value and key are simple expressions (no nested parens / commas). A bool/int/
        // double literal value is EXCLUDED (the typed patterns above already consumed
        // those, and the negative-lookahead keeps this pattern from re-claiming one if
        // ordering ever changes): a literal value here must NOT route through the String
        // shim (it would either mis-store or fail to compile). A bare `String` value or
        // a non-literal expression still matches and lowers (or demotes if not a String).
        //
        // The numeric exclusion is `-?[0-9][^,]*` — ANY value that BEGINS with a digit
        // (optionally negative), so it also excludes the NON-DECIMAL numeric literals
        // the decimal-only typed patterns miss: `0xFF`, `1e5`, `0b1010`, `0o17`. Those
        // would otherwise be captured as a String value and passed to a `String`-typed
        // shim (a guest WASM compile failure). A real `String` value never begins with
        // a digit (a Swift identifier can't, and a `"…"` literal starts with `"`), so
        // this over-exclusion never drops a genuine String set (it stays native →
        // demote-safe). See BUG #54.
        (#"UserDefaults\.standard\.set\((?!(?:true|false|-?[0-9][^,]*)\s*,)([^(),]+?),\s*forKey:\s*([^()]+?)\)"#,
         "_patchFusionDefaultsSetString($1, $2)",
         defaultsSet.id),

        // Locale.current.identifier  →  _patchFusionLocaleIdentifier()
        (#"Locale\.current\.identifier"#,
         "_patchFusionLocaleIdentifier()",
         localeIdentifier.id),

        // TimeZone.current.identifier  →  _patchFusionTimeZoneIdentifier()
        (#"TimeZone\.current\.identifier"#,
         "_patchFusionTimeZoneIdentifier()",
         timezoneIdentifier.id),

        // NSLog(<single string expr>)  →  _patchFusionLog(1, <expr>)
        // Only the single-argument form (no comma → no printf args).
        (#"NSLog\(([^(),]+?)\)"#,
         "_patchFusionLog(1, $1)",
         logInfo.id),

        // ---- Business-logic action leaves (links + events, module patch) ----

        // UIApplication.shared.open(<url>)  →  _patchFusionOpenURL(<url>)
        // ONLY the single-argument form. The `open(_:options:completionHandler:)`
        // overload has a comma (extra args) → not matched by the no-comma `[^(),]+?`
        // capture, so it is left native and demotes (the completion handler can't be
        // bridged). The leading `@discardableResult` on the shim lets a bare
        // `UIApplication.shared.open(url)` statement (result unused) compile.
        (#"UIApplication\.shared\.open\(([^(),]+?)\)"#,
         "_patchFusionOpenURL($1)",
         openURL.id),

        // NotificationCenter.default.post(name: <name>, object: nil)  →  _patchFusionNotifyPost(<name>)
        // ONLY the `object: nil` form (the dominant shape). A non-nil object: or an
        // extra `userInfo:` arg has no value-marshalling path → left native (demotes).
        // The name expr carries through verbatim; the shim reads its `.rawValue`.
        (#"NotificationCenter\.default\.post\(name:\s*([^(),]+?),\s*object:\s*nil\)"#,
         "_patchFusionNotifyPost($1)",
         notifyPost.id),

        // ---- Breakthrough #8 family (read-only leaves, module patch_host) ----
        // NB: order matters — the more specific FileManager attribute/size form is
        // listed before the bare-existence form so the size read is not partially
        // captured. Each capture carries the developer's own argument expression
        // verbatim. All forms are narrow (no nested parens/commas in practice); an
        // unrecognized shape is left native and demotes alone (safety preserved).

        // FileManager.default.attributesOfItem(atPath: <p>)[.size] as? Int  → size
        // The whole `attributesOfItem(...)[.size] as? Int` expression (optionally
        // `(... )?.intValue`-free) collapses to an Int64 size accessor returning -1
        // when absent. Conservative: only the canonical `[.size] as? Int` tail.
        (#"FileManager\.default\.attributesOfItem\(atPath:\s*([^()\[\]]+?)\)\[\.size\]\s+as\?\s+Int"#,
         "Int(_patchFusionFileSize($1))",
         fileSize.id),

        // FileManager.default.fileExists(atPath: <p>)  →  _patchFusionFileExists(<p>)
        (#"FileManager\.default\.fileExists\(atPath:\s*([^()]+?)\)"#,
         "_patchFusionFileExists($1)",
         fileExists.id),

        // FileManager.default.contents(atPath: <p>)  →  _patchFusionFileContents(<p>)
        (#"FileManager\.default\.contents\(atPath:\s*([^()]+?)\)"#,
         "_patchFusionFileContents($1)",
         fileRead.id),

        // Bundle.main.object(forInfoDictionaryKey: <k>)  →  _patchFusionBundleInfoString(<k>)
        // (returns String?; code that needs a non-String value type still demotes.)
        (#"Bundle\.main\.object\(forInfoDictionaryKey:\s*([^()]+?)\)\s+as\?\s+String"#,
         "_patchFusionBundleInfoString($1)",
         bundleInfoString.id),

        // Bundle.main.path(forResource: <n>, ofType: <e>)  →  _patchFusionBundleResourcePath(<n>, <e>)
        (#"Bundle\.main\.path\(forResource:\s*([^(),]+?),\s*ofType:\s*([^()]+?)\)"#,
         "_patchFusionBundleResourcePath($1, $2)",
         bundleResourcePath.id),

        // ProcessInfo.processInfo.environment[<name>]  →  _patchFusionProcessEnv(<name>)
        (#"ProcessInfo\.processInfo\.environment\[([^\[\]]+?)\]"#,
         "_patchFusionProcessEnv($1)",
         processEnv.id),

        // ProcessInfo.processInfo.operatingSystemVersion  →  _patchFusionOSVersion()
        (#"ProcessInfo\.processInfo\.operatingSystemVersion"#,
         "_patchFusionOSVersion()",
         osVersion.id),

        // UserDefaults.standard.bool(forKey: <k>)  →  _patchFusionDefaultsGetBool(<k>)
        (#"UserDefaults\.standard\.bool\(forKey:\s*([^()]+?)\)"#,
         "_patchFusionDefaultsGetBool($1)",
         defaultsGetBool.id),

        // UserDefaults.standard.integer(forKey: <k>)  →  _patchFusionDefaultsGetInt(<k>)
        (#"UserDefaults\.standard\.integer\(forKey:\s*([^()]+?)\)"#,
         "_patchFusionDefaultsGetInt($1)",
         defaultsGetInt.id),

        // UserDefaults.standard.double(forKey: <k>)  →  _patchFusionDefaultsGetDouble(<k>)
        (#"UserDefaults\.standard\.double\(forKey:\s*([^()]+?)\)"#,
         "_patchFusionDefaultsGetDouble($1)",
         defaultsGetDouble.id),

        // ---- Foundation VALUE bridges (date math / ISO8601, module patch_host) ----
        // Each is a SINGLE deterministic call form; an unmatched shape is left native
        // and demotes alone. Order: the `since1970`/`sinceNow` forms are distinct
        // tails on `Date()`, matched explicitly so neither is partially captured.
        //
        // NB on the `(?<![A-Za-z0-9_.])` lead-guard: the `Date()`/`ISO8601DateFormatter()`
        // type names must NOT match as the SUFFIX of another identifier or a member
        // access — `effectiveDate().timeIntervalSince1970`, `dueDate()…`, or
        // `obj.Date()` would otherwise be wrongly rewritten (a correctness bug: the
        // leading `effective`/`obj.` is left dangling). The negative lookbehind anchors
        // the match to a genuine bare `Date()` / `ISO8601DateFormatter()` token.

        // Date().timeIntervalSince1970  →  _patchFusionNowUnixSeconds()
        (#"(?<![A-Za-z0-9_.])Date\(\)\.timeIntervalSince1970"#,
         "_patchFusionNowUnixSeconds()",
         nowUnixSeconds.id),

        // Date().timeIntervalSinceNow  →  _patchFusionNowIntervalSinceNow()  (≡ 0)
        (#"(?<![A-Za-z0-9_.])Date\(\)\.timeIntervalSinceNow"#,
         "_patchFusionNowIntervalSinceNow()",
         nowIntervalSinceNow.id),

        // ISO8601DateFormatter().string(from: <date>)  →  _patchFusionISO8601String(<date>)
        // ONLY the default-options init `ISO8601DateFormatter()` — a configured
        // formatter (`let f = ISO8601DateFormatter(); f.formatOptions = …`) is a
        // different format and is NOT matched (stays native → demotes).
        (#"(?<![A-Za-z0-9_.])ISO8601DateFormatter\(\)\.string\(from:\s*([^()]+?)\)"#,
         "_patchFusionISO8601String($1)",
         iso8601String.id),

        // ISO8601DateFormatter().date(from: <string>)  →  _patchFusionISO8601Date(<string>)
        (#"(?<![A-Za-z0-9_.])ISO8601DateFormatter\(\)\.date\(from:\s*([^()]+?)\)"#,
         "_patchFusionISO8601Date($1)",
         iso8601Date.id),

        // ---- LEVER #2: Date/Calendar/Formatter BUILDER rewrites (module patch_host) ----
        // These match a canonical MULTI-STATEMENT formatter builder (the real-app shape,
        // not a one-liner) and collapse the WHOLE builder to a single shim call. The
        // regex threads the local formatter variable name (`\1`) so a builder for `f`
        // only matches the SAME `f`, never a different formatter; `\s+` between
        // statements absorbs the newline/indent. The statement CONNECTOR between the
        // style line and the call (`return `, `x = `, `let y = `, or nothing) is captured
        // as group 2 and RE-EMITTED verbatim so the rewrite preserves the developer's
        // `return`/assignment exactly. ANY deviation (a third property set, a reused
        // formatter, an unusual ref) fails to match → left verbatim (demote-safe). Run
        // BEFORE the one-liner Calendar forms so the builder is consumed whole.
        //
        // <connector> captures: an optional `return ` / `<lhs> = ` / `let|var <lhs> = `
        // immediately before the `\1.localizedString(...)` call. `(?:…)?` keeps it
        // optional (a bare expression-statement call). The `.now` variants route through
        // the host clock (`…ToNow`); an EXPLICIT relativeTo ref uses the 2-Date shim.
        // unitsStyle code: full=0, spellOut=1, short=2, abbreviated=3 (host enum order).
        //
        // The connector sub-pattern, reused below: `((?:return\s+|(?:let|var\s+)?[A-Za-z_][\w.]*\s*=\s*)?)`
        //
        // --- .now forms (route through the host clock) ---
        (#"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*RelativeDateTimeFormatter\(\)\s+\1\.unitsStyle\s*=\s*\.(full|spellOut|short|abbreviated)\b\s+((?:return\s+|(?:let\s+|var\s+)?[A-Za-z_][\w.]*\s*=\s*)?)\1\.localizedString\(for:\s*([^(),]+?),\s*relativeTo:\s*(?:\.now|Date\.now|Date\(\))\)"#,
         "$3_patchFusionRelativeDateStringToNow($4, _patchFusionRelStyle_$2)",
         relativeDateString.id),
        // bare init (no unitsStyle; defaults to .full), .now ref.
        (#"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*RelativeDateTimeFormatter\(\)\s+((?:return\s+|(?:let\s+|var\s+)?[A-Za-z_][\w.]*\s*=\s*)?)\1\.localizedString\(for:\s*([^(),]+?),\s*relativeTo:\s*(?:\.now|Date\.now|Date\(\))\)"#,
         "$2_patchFusionRelativeDateStringToNow($3, 0)",
         relativeDateString.id),
        // --- explicit relativeTo ref (2-Date shim) ---
        (#"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*RelativeDateTimeFormatter\(\)\s+\1\.unitsStyle\s*=\s*\.(full|spellOut|short|abbreviated)\b\s+((?:return\s+|(?:let\s+|var\s+)?[A-Za-z_][\w.]*\s*=\s*)?)\1\.localizedString\(for:\s*([^(),]+?),\s*relativeTo:\s*([^()]+?)\)"#,
         "$3_patchFusionRelativeDateString($4, $5, _patchFusionRelStyle_$2)",
         relativeDateString.id),
        // bare init (no unitsStyle; defaults to .full), explicit ref.
        (#"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*RelativeDateTimeFormatter\(\)\s+((?:return\s+|(?:let\s+|var\s+)?[A-Za-z_][\w.]*\s*=\s*)?)\1\.localizedString\(for:\s*([^(),]+?),\s*relativeTo:\s*([^()]+?)\)"#,
         "$2_patchFusionRelativeDateString($3, $4, 0)",
         relativeDateString.id),

        // ---- NumberFormatter builder (the documented coverage, BUG R2-#107) ----
        // The canonical 4-statement builder:
        //   let f = NumberFormatter()
        //   f.numberStyle = .currency
        //   f.minimumFractionDigits = 2
        //   f.maximumFractionDigits = 2
        //   <connector> f.string(from: NSNumber(value: <val>))   // a `String?`
        // collapses to one `Optional(_patchFusionNumberFormat(Double(<val>),
        // <styleCode>, <N>, ""))`. The shim is wrapped in `Optional(...)` so the result
        // stays a `String?` EXACTLY as the original `NumberFormatter.string(from:)`
        // returns — the developer's surrounding `?? ""` / `if let` / direct `String?`
        // use all keep type-checking, and the shim's "" (on failure) flows through.
        //
        // FIDELITY: the min/max fraction digits MUST be EXPLICIT and EQUAL — the SDK
        // shim (`FoundationBridge.numberFormat`) applies the single `fractionDigits`
        // arg to BOTH `minimumFractionDigits` AND `maximumFractionDigits`, so only a
        // builder that sets them to the SAME value is faithfully representable. The
        // EQUAL constraint is enforced by a BACKREFERENCE: group `\3` captures the
        // first digits literal and `\3` (reused) requires the second to be textually
        // identical. A builder that OMITS the fraction digits (relying on the style's
        // native defaults) is NOT matched (passing 0 would force integer-only output) →
        // stays native and demotes alone. The `value:` arg is wrapped `Double(...)` so
        // an Int/Decimal NSNumber value round-trips. `\s+` absorbs newlines/indent; ANY
        // deviation (omitted/unequal fraction digits, a third property set, a reused
        // formatter) fails the match → left verbatim (demote-safe).
        //
        // min THEN max (the common ordering):
        (##"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*NumberFormatter\(\)\s+\1\.numberStyle\s*=\s*\.(decimal|currency|percent)\b\s+\1\.minimumFractionDigits\s*=\s*([0-9]+)\s+\1\.maximumFractionDigits\s*=\s*\3\b\s+((?:return\s+|(?:let\s+|var\s+)?[A-Za-z_][\w.]*\s*=\s*)?)\1\.string\(from:\s*NSNumber\(value:\s*([^()]+?)\)\)"##,
         ##"$4Optional(_patchFusionNumberFormat(Double($5), _patchFusionNumStyle_$2, Int32($3), ""))"##,
         numberFormatStyled.id),
        // max THEN min (the other ordering):
        (##"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*NumberFormatter\(\)\s+\1\.numberStyle\s*=\s*\.(decimal|currency|percent)\b\s+\1\.maximumFractionDigits\s*=\s*([0-9]+)\s+\1\.minimumFractionDigits\s*=\s*\3\b\s+((?:return\s+|(?:let\s+|var\s+)?[A-Za-z_][\w.]*\s*=\s*)?)\1\.string\(from:\s*NSNumber\(value:\s*([^()]+?)\)\)"##,
         ##"$4Optional(_patchFusionNumberFormat(Double($5), _patchFusionNumStyle_$2, Int32($3), ""))"##,
         numberFormatStyled.id),

        // Calendar.current.startOfDay(for: <date>)  →  _patchFusionCalendarStartOfDay(<date>)
        // A one-liner — no builder. The lead-guard prevents matching a custom
        // `myCalendar.current` member chain.
        (#"(?<![A-Za-z0-9_.])Calendar\.current\.startOfDay\(for:\s*([^()]+?)\)"#,
         "_patchFusionCalendarStartOfDay($1)",
         calendarStartOfDay.id),

        // Calendar.current.isDate(<a>, inSameDayAs: <b>)  →  _patchFusionCalendarSameDay(<a>, <b>)
        (#"(?<![A-Za-z0-9_.])Calendar\.current\.isDate\(([^(),]+?),\s*inSameDayAs:\s*([^()]+?)\)"#,
         "_patchFusionCalendarSameDay($1, $2)",
         calendarSameDay.id),

        // ---- LEVER: Regex (the shell's real ICU NSRegularExpression, module patch_host) ----
        // Each matches a CANONICAL single-use regex form. A configured/reused regex, a
        // closure enumerate, an iOS-16 `Regex` literal, or a plain (non-.regularExpression)
        // String op is NOT matched → left verbatim (stays native/T2, demotes alone). The
        // capture/count forms are anchored on a BARE `NSRegularExpression(pattern:)` so a
        // stored `let re = NSRegularExpression(...)` (reused, possibly with options) is not
        // claimed. The pattern arg uses `[^,()]+?` so a string literal / simple ref carries
        // through but a nested call/comma (extra args like `options:`) breaks the match.
        //
        // NB on ordering: the `range(of:options:.regularExpression) != nil` / `== nil` TEST
        // forms are matched BEFORE any bare `range(of:)` so the whole comparison collapses
        // to a Bool. The `!= nil` form maps to the shim directly; `== nil` maps to `!shim`.

        // <recv>.range(of: <pat>, options: .regularExpression) != nil  →  _patchFusionRegexTest(<recv>, <pat>)
        (#"([A-Za-z_][\w.]*)\.range\(of:\s*([^,()]+?),\s*options:\s*\.regularExpression\)\s*!=\s*nil"#,
         "_patchFusionRegexTest($1, $2)",
         regexTest.id),
        // <recv>.range(of: <pat>, options: .regularExpression) == nil  →  !_patchFusionRegexTest(<recv>, <pat>)
        (#"([A-Za-z_][\w.]*)\.range\(of:\s*([^,()]+?),\s*options:\s*\.regularExpression\)\s*==\s*nil"#,
         "!_patchFusionRegexTest($1, $2)",
         regexTest.id),

        // <recv>.replacingOccurrences(of: <pat>, with: <tmpl>, options: .regularExpression)
        //   →  _patchFusionRegexReplace(<recv>, <pat>, <tmpl>)
        // The `.regularExpression` option distinguishes a regex replace from a literal one
        // (a literal `replacingOccurrences(of:with:)` is a different operation, left native).
        (#"([A-Za-z_][\w.]*)\.replacingOccurrences\(of:\s*([^,()]+?),\s*with:\s*([^,()]+?),\s*options:\s*\.regularExpression\)"#,
         "_patchFusionRegexReplace($1, $2, $3)",
         regexReplace.id),

        // The bare `NSRegularExpression(pattern: <pat>).<member>(in: <str>, range: <r>, …)`
        // forms. The `range:` arg is an `NSRange` whose canonical full-string value contains
        // ONE level of nested parens (`NSRange(location: 0, length: …)` /
        // `NSRange(str.startIndex..., in: str)`), so it is matched with the bounded
        // single-nesting sub-pattern `(?:[^()]|\([^()]*\))+?` (NOT `[^,()]` — that can't span
        // the range's commas/parens) and then DROPPED: the host operates over the WHOLE
        // input. A deeper-nested / partial range fails the bounded match → stays native
        // (demote-safe). The `pattern:` and `withTemplate:`/result args use the simple
        // `[^,()]+?` (a literal / ref). The init must be a BARE single-use `NSRegularExpression(pattern:)`
        // — a stored/reused/options-configured regex is not matched.

        // NSRegularExpression(pattern: <pat>).stringByReplacingMatches(in: <str>, range: <r>, withTemplate: <tmpl>)
        //   →  _patchFusionRegexReplace(<str>, <pat>, <tmpl>)   (replace over the whole string)
        // `\(\s*` after each call name tolerates a newline/indent after the opening paren
        // (the multi-line call style real apps write the long NSRegularExpression forms in).
        // A leading `try!`/`try?`/`try ` is CONSUMED (matched + dropped): the bare
        // `NSRegularExpression(pattern:)` init is `throws`, so real code always prefixes it,
        // but the host shim does NOT throw — leaving the `try` dangling would not compile. An
        // invalid pattern is handled host-side (count/replace return the safe no-value), so
        // dropping `try` is faithful: the shim never throws and there is nothing to catch.
        (#"(?:try[!?]?\s+)?NSRegularExpression\(\s*pattern:\s*([^,()]+?)\)\.stringByReplacingMatches\(\s*in:\s*([^,()]+?),\s*range:\s*(?:[^()]|\([^()]*\))+?,\s*withTemplate:\s*([^,()]+?)\)"#,
         "_patchFusionRegexReplace($2, $1, $3)",
         regexReplace.id),

        // NSRegularExpression(pattern: <pat>).numberOfMatches(in: <str>, range: <r>)
        //   →  _patchFusionRegexCount(<str>, <pat>)
        (#"(?:try[!?]?\s+)?NSRegularExpression\(\s*pattern:\s*([^,()]+?)\)\.numberOfMatches\(\s*in:\s*([^,()]+?),\s*range:\s*(?:[^()]|\([^()]*\))+?\)"#,
         "_patchFusionRegexCount($2, $1)",
         regexCount.id),

        // NSRegularExpression(pattern: <pat>).firstMatch(in: <str>, range: <r>) != nil
        //   →  _patchFusionRegexTest(<str>, <pat>)   (a Bool match TEST)
        (#"(?:try[!?]?\s+)?NSRegularExpression\(\s*pattern:\s*([^,()]+?)\)\.firstMatch\(\s*in:\s*([^,()]+?),\s*range:\s*(?:[^()]|\([^()]*\))+?\)\s*!=\s*nil"#,
         "_patchFusionRegexTest($2, $1)",
         regexTest.id),
        // NSRegularExpression(pattern: <pat>).firstMatch(in: <str>, range: <r>) == nil
        //   →  !_patchFusionRegexTest(<str>, <pat>)
        (#"(?:try[!?]?\s+)?NSRegularExpression\(\s*pattern:\s*([^,()]+?)\)\.firstMatch\(\s*in:\s*([^,()]+?),\s*range:\s*(?:[^()]|\([^()]*\))+?\)\s*==\s*nil"#,
         "!_patchFusionRegexTest($2, $1)",
         regexTest.id),

        // ---- Breakthrough #6 NETWORKING (async, module patch_host) ----
        // The `await` is INSIDE the matched span on purpose: the leaf is itself an
        // `await URLSession…` and the shim is `async throws`, so the rewritten call
        // keeps the developer's `await`/`try` exactly where it was. Conservative: only
        // the canonical `URLSession.shared.data(from:)` / `.data(for:)` forms (the two
        // the breakthrough proved). A `URLSession(configuration:)` instance, a delegate
        // task, websocket/upload/download, or a `.bytes(...)` stream is NOT matched and
        // stays native (registry mustStayNative member-call guard) → demotes alone.

        // URLSession.shared.data(from: <url>)  →  _patchFusionURLSessionDataFrom(<url>)
        // (the developer's leading `try await` is left in place before the call).
        // `data(for: URLRequest)` is deliberately NOT rewritten — URLRequest is absent
        // in the WASM-SDK guest Foundation, so it stays native and demotes alone.
        (#"URLSession\.shared\.data\(from:\s*([^()]+?)\)"#,
         "_patchFusionURLSessionDataFrom($1)",
         httpGet.id),
    ]

    // MARK: - Bridge package artifacts

    /// The shared marshalling helpers every shim depends on (unpack a packed
    /// `(ptr<<32)|len` and read a host-allocated UTF-8 buffer out of guest memory,
    /// freeing it). Emitted once into the bridge support file.
    static let sharedHelpers = """
    // Shared (ptr,len) marshalling for the fusion host bridges. The host allocates
    // the result buffer in OUR linear memory (via the exported patch_malloc) and
    // writes UTF-8 bytes; we read with String(decoding:as:) and free the buffer.
    @inlinable func _patchFusionUnpack(_ packed: Int64) -> (ptr: Int, len: Int) {
        (Int((packed >> 32) & 0xffff_ffff), Int(packed & 0xffff_ffff))
    }
    @inlinable func _patchFusionReadString(ptr: Int, len: Int) -> String {
        guard let base = UnsafePointer<UInt8>(bitPattern: ptr) else { return "" }
        let s = String(decoding: UnsafeBufferPointer(start: base, count: len), as: UTF8.self)
        UnsafeMutableRawPointer(bitPattern: ptr)?.deallocate()
        return s
    }
    @inlinable func _patchFusionReadBytes(ptr: Int, len: Int) -> [UInt8] {
        guard let base = UnsafePointer<UInt8>(bitPattern: ptr) else { return [] }
        let bytes = Array(UnsafeBufferPointer(start: base, count: len))
        UnsafeMutableRawPointer(bitPattern: ptr)?.deallocate()
        return bytes
    }
    """

    /// ASYNC bridge support (breakthrough #6 networking). Emitted ONLY when an async
    /// bridge fired. Provides:
    ///   - the host-await continuation registry (token → continuation), keyed the same
    ///     way the executor pump expects, resumed by the host calling the guest export
    ///     `patch_resolve_http(token, dataPtr, dataLen, status)`;
    ///   - `_patchFusionHTTPGet` / `_patchFusionHTTPRequest`: the `async throws`
    ///     primitives the shims call — stash a continuation under a fresh token, hand
    ///     the URL/request to the host via the flat import, and SUSPEND;
    ///   - a tiny `_PatchHTTPURLResponse` value struct so the rewritten
    ///     `(Data, HTTPURLResponse)`-shaped destructuring keeps compiling under the
    ///     WASM SDK. The `URL`-or-`String` arg is handled by the shared `_PatchURLLike`
    ///     helper (emitted separately — see `urlLikeHelper`/`urlLikeLeafIDs` — since the
    ///     `open_url` leaf also needs it; the two must not redeclare the protocol).
    static let asyncHelpers = """
    // ---- Breakthrough #6 networking: async host-await support ----
    // The host owns concurrency: the guest suspends here and the host performs the
    // real URLSession fetch, then resumes via patch_resolve_http (written below).
    public struct _PatchHTTPResult { public var body: [UInt8]; public var status: Int }
    public enum _PatchHTTPError: Error { case badStatus(Int); case transport }

    // token → continuation. Single-threaded WASI: no lock needed.
    @usableFromInline var _patchFusionHTTPConts: [Int32: CheckedContinuation<_PatchHTTPResult, Never>] = [:]
    @usableFromInline var _patchFusionHTTPToken: Int32 = 1

    @inlinable func _patchFusionHTTPGet(_ url: String) async throws -> _PatchHTTPResult {
        let token = _patchFusionHTTPToken; _patchFusionHTTPToken &+= 1
        let r: _PatchHTTPResult = await withCheckedContinuation { cont in
            _patchFusionHTTPConts[token] = cont
            let u = Array(url.utf8)
            u.withUnsafeBufferPointer { up in
                patch_http_get(up.baseAddress, Int32(up.count), token)
            }
        }
        return r
    }

    // The host resumes a suspended fetch: it has already written `len` response bytes
    // at `dataPtr` in OUR linear memory (via patch_malloc). We read+free them and
    // resume the continuation with (body, status). Exported flat for the host to call.
    @_cdecl("patch_resolve_http")
    public func _patchFusionResolveHTTP(_ token: Int32, _ dataPtr: Int32, _ dataLen: Int32, _ status: Int32) {
        guard let cont = _patchFusionHTTPConts.removeValue(forKey: token) else { return }
        let body = _patchFusionReadBytes(ptr: Int(UInt32(bitPattern: dataPtr)), len: Int(UInt32(bitPattern: dataLen)))
        cont.resume(returning: _PatchHTTPResult(body: body, status: Int(status)))
    }

    // Minimal HTTPURLResponse stand-in so `(data, response)` destructuring + a
    // `response.statusCode` / `as? HTTPURLResponse` check keeps compiling in WASM.
    public struct _PatchHTTPURLResponse {
        public let statusCode: Int
        public let url: String
        @inlinable public init(statusCode: Int, url: String) { self.statusCode = statusCode; self.url = url }
    }
    """

    /// `_PatchURLLike` — accept either a real Foundation `URL` or a `String` for any
    /// URL-typed shim arg (the networking `data(from:)` and the `open_url` leaf). `URL`
    /// IS in the WASM-SDK guest Foundation (a pure value type); `URLRequest` is NOT,
    /// which is why `data(for:)` is deferred and no `_PatchURLRequestLike` exists.
    /// Emitted whenever a URL-consuming bridge fired (networking OR openURL) — both
    /// would otherwise redeclare it, so it lives here once.
    static let urlLikeHelper = """
    // Accept either a real Foundation `URL` or a `String` for a URL-typed shim arg.
    public protocol _PatchURLLike { var _patchURLString: String { get } }
    extension String: _PatchURLLike { @inlinable public var _patchURLString: String { self } }
    extension URL: _PatchURLLike { @inlinable public var _patchURLString: String { self.absoluteString } }
    """

    /// The C header (`fusion_chost.h`) declaring the flat host imports for the
    /// bridges that fired. Same mechanism as `CHeaderBridge` (Clang
    /// `import_module`/`import_name`) — proven to yield the flat ABI WasmKit accepts
    /// under the full SDK.
    public func headerSource(for bridges: [Bridge]) -> String {
        var s = """
        // Auto-generated by Patch FUSION — bridgeable-leaf host-import ABI (C header).
        // DO NOT EDIT. Clang import_module/import_name attributes → flat WASM ABI.
        // Each import matches a live PatchSDK bridge registration (module + name).
        #ifndef PATCH_FUSION_CHOST_H
        #define PATCH_FUSION_CHOST_H
        #include <stdint.h>

        #define WASM_IMPORT(mod,nm) __attribute__((import_module(mod), import_name(nm)))

        """
        // Dedup at the per-DECLARATION level (one `WASM_IMPORT(...)` + its function
        // prototype), NOT per-bridge: two bridges may share one host import (`…Since1970`
        // and `…SinceNow` both bind `patch_host.now_unix_millis`), AND a single bridge's
        // cDecl may declare MORE than one import (the relative-date leaf also declares
        // `now_unix_millis` so its `…ToNow` shim is self-contained). Splitting on the
        // `WASM_IMPORT` boundary and keying on `(module,name)` emits each unique flat
        // import exactly once — robust against a frontend that rejects a repeated
        // `import_*`-attributed prototype, regardless of which bridges happened to fire.
        var seen = Set<String>()
        for b in bridges {
            for (key, decl) in Self.splitImportDecls(b.cDecl) where seen.insert(key).inserted {
                s += decl + "\n\n"
            }
        }
        s += "#endif\n"
        return s
    }

    /// Split a bridge's `cDecl` block into its individual `WASM_IMPORT(mod,nm) …;`
    /// declarations, each keyed by its `module.name`. A cDecl is one-or-more
    /// `WASM_IMPORT("mod","nm")` lines each followed by a (possibly multi-line) C
    /// prototype ending in `;`. Returns `[(key, declarationText)]` preserving order.
    static func splitImportDecls(_ cDecl: String) -> [(key: String, decl: String)] {
        let lines = cDecl.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [(key: String, decl: String)] = []
        var i = 0
        // Matches WASM_IMPORT("module","name") capturing the two strings.
        let re = try? NSRegularExpression(pattern: #"WASM_IMPORT\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)"#)
        while i < lines.count {
            let line = lines[i]
            let ns = line as NSString
            guard let re,
                  let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges == 3 else { i += 1; continue }
            let module = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2))
            // Accumulate the prototype lines until one ends with `;`.
            var block = line
            i += 1
            while i < lines.count {
                block += "\n" + lines[i]
                let ended = lines[i].trimmingCharacters(in: .whitespaces).hasSuffix(";")
                i += 1
                if ended { break }
            }
            out.append((key: "\(module).\(name)", decl: block))
        }
        return out
    }

    /// The C shim translation unit (forces SwiftPM to emit the C target object so
    /// the import declarations land in the module).
    public func shimSource() -> String {
        """
        // Auto-generated by Patch FUSION — C shim for the bridgeable-leaf header.
        #include "include/fusion_chost.h"
        """
    }

    /// Leaf ids whose shim uses the `_PatchURLLike` URL helper (a `URL`-or-`String`
    /// arg): the networking GET and the `open_url` leaf. Emitted once when either
    /// fired so the two don't redeclare the protocol.
    static let urlLikeLeafIDs: Set<String> = [httpGet.id, openURL.id]

    /// Leaf ids whose shim references a Foundation value type and therefore needs
    /// `import Foundation` in the emitted bridge file: the networking GET (`URL`/
    /// `Data`), the `open_url` leaf (`URL` via `_PatchURLLike`), the `notify_post`
    /// leaf (`Notification.Name`), and the ISO8601 string<->date leaves (`Date`).
    /// The pure scalar/string leaves (UserDefaults / FileManager / Bundle /
    /// ProcessInfo / Locale / `Date().timeIntervalSince*`) never need it.
    static let foundationLeafIDs: Set<String> = [
        httpGet.id, openURL.id, notifyPost.id, iso8601String.id, iso8601Date.id,
        // LEVER #2: the relative-date + Calendar leaves take/return `Date` value types.
        // (numberFormatStyled is pure Double->String → no Foundation needed.)
        relativeDateString.id, calendarStartOfDay.id, calendarSameDay.id,
    ]

    /// The Swift bridge support file: `import` of the C target, the shared
    /// marshalling helpers, and the per-leaf Swift shims the rewrite calls. Compiled
    /// into the real-source module alongside the developer's (rewritten) source.
    public func swiftBridgeSource(for bridges: [Bridge], cTargetName: String) -> String {
        let anyAsync = bridges.contains { $0.isAsync }
        let needsFoundation = bridges.contains { Self.foundationLeafIDs.contains($0.id) }
        let needsURLLike = bridges.contains { Self.urlLikeLeafIDs.contains($0.id) }
        var s = """
        // Auto-generated by Patch FUSION — Swift shims over the bridgeable-leaf host
        // imports. DO NOT EDIT. The native shell satisfies these via PatchSDK's
        // UserDefaults/DateLocale/Logging/OpenURL/NotificationCenter bridges
        // (modules "patch"/"patch_host").
        import \(cTargetName)

        """
        // Foundation value types (URL / Data / Notification.Name) — all proven to
        // compile under the full WASM SDK. Imported only when a leaf that uses one
        // fired (the pure scalar/string leaves never need it).
        if needsFoundation { s += "import Foundation\n\n" }
        s += Self.sharedHelpers + "\n\n"
        // The URL-or-String helper, shared by the networking + open_url shims (emitted
        // once when either fired so they don't redeclare the protocol).
        if needsURLLike { s += Self.urlLikeHelper + "\n\n" }
        // The async host-await continuation registry + networking primitives + the
        // `patch_resolve_http` export, emitted once when any async (networking) leaf
        // fired. Depends on the executor pump being linked (CExec) — the same
        // mechanism the #4 async executor uses, and the precondition for any async fn.
        if anyAsync { s += Self.asyncHelpers + "\n\n" }
        for b in bridges { s += b.swiftShim + "\n\n" }
        return s
    }

    /// Files for the fusion CHost target + Swift bridge, ready to write into the
    /// real-source compile package. `swiftTargetName` is the real module's target
    /// (the package is named after the developer's module).
    public func files(bridges: [Bridge], swiftTargetName: String,
                      cTargetName: String = "FusionCHost") -> [(relativePath: String, contents: String)] {
        [
            (relativePath: "Sources/\(cTargetName)/include/fusion_chost.h",
             contents: headerSource(for: bridges)),
            (relativePath: "Sources/\(cTargetName)/shim.c",
             contents: shimSource()),
            (relativePath: "Sources/\(swiftTargetName)/_patch_fusion_bridge.swift",
             contents: swiftBridgeSource(for: bridges, cTargetName: cTargetName)),
        ]
    }

    /// The fusion C-target name (the real module depends on this).
    public static let cTargetName = "FusionCHost"

    /// Resolve a set of fired leaf ids to their `Bridge` entries (stable order).
    public func bridges(forLeaves leaves: Set<String>) -> [Bridge] {
        Self.allBridges.filter { leaves.contains($0.id) }
    }
}
