import Foundation
import WasmKit
#if canImport(os)
import os
#endif

// MARK: - Bridge ABI helpers
//
// Bridges are the wasm->native escape hatch: a guest function imports a host
// function, calls it with the Patch v0 `(ptr: i32, len: i32)` ABI, and the host
// runs real Swift/iOS code. The 9 pre-built bridges below register host
// functions into the runtime's `Imports` under the module namespace
// `"patch"` (so the guest imports e.g. `(import "patch" "log" ...)`).
//
// ## Variable-length results: the packed-i64 convention
// A host function that returns bytes (e.g. JSON, a UserDefaults string) writes
// them into guest linear memory via the guest's exported `patch_malloc`, then
// returns a single `i64` packing `(ptr << 32) | len`. The guest unpacks it,
// reads `[ptr, ptr+len)`, and frees with `patch_free`. A return of `0` means
// "no value" (nil / not found). This keeps every bridge a single `i64`-returning
// import, which is trivial to declare on the guest side.

/// Wraps a WasmKit `Caller` to give bridge host functions read/write/alloc
/// access to the calling instance's linear memory, honoring the Patch v0 ABI.
public struct BridgeContext {
    public let caller: Caller
    private let memoryName: String
    private let allocatorName: String

    public init(caller: Caller, memoryName: String = "memory", allocatorName: String = "patch_malloc") {
        self.caller = caller
        self.memoryName = memoryName
        self.allocatorName = allocatorName
    }

    public enum BridgeError: Error, CustomStringConvertible {
        case noMemory
        case noAllocator
        case oob(ptr: UInt32, len: UInt32)
        case allocFailed(Int)
        public var description: String {
            switch self {
            case .noMemory: return "bridge: instance exports no `memory`"
            case .noAllocator: return "bridge: instance exports no `patch_malloc`"
            case .oob(let p, let l): return "bridge: guest memory OOB (ptr=\(p), len=\(l))"
            case .allocFailed(let n): return "bridge: guest allocator returned null for \(n) bytes"
            }
        }
    }

    private func memory() throws -> Memory {
        guard let mem = caller.instance?.exports[memory: memoryName] else { throw BridgeError.noMemory }
        return mem
    }

    /// Best-effort release of a guest buffer via the exported `patch_free`. A no-op
    /// when the guest exports no allocator-free or `ptr == 0`. Used to reclaim a
    /// buffer that was allocated but could not be written (error path), so a broken
    /// allocator can't leak a buffer per bridge call.
    private func freeGuest(_ ptr: UInt32) {
        guard ptr != 0, let free = caller.instance?.exports[function: "patch_free"] else { return }
        _ = try? free.invoke([.i32(ptr)])
    }

    /// Read `len` bytes from guest memory at `ptr`.
    public func readBytes(ptr: UInt32, len: UInt32) throws -> [UInt8] {
        let mem = try memory()
        let all = mem.data
        let start = Int(ptr), end = Int(ptr) + Int(len)
        guard start >= 0, end <= all.count else { throw BridgeError.oob(ptr: ptr, len: len) }
        if len == 0 { return [] }
        return [UInt8](all[start..<end])
    }

    /// Read a UTF-8 string from guest memory.
    public func readString(ptr: UInt32, len: UInt32) throws -> String {
        String(decoding: try readBytes(ptr: ptr, len: len), as: UTF8.self)
    }

    /// Allocate guest memory via `patch_malloc`, copy `bytes` in, return `(ptr,len)`.
    public func writeBytes(_ bytes: [UInt8]) throws -> (ptr: UInt32, len: UInt32) {
        if bytes.isEmpty { return (0, 0) }
        guard let alloc = caller.instance?.exports[function: allocatorName] else {
            throw BridgeError.noAllocator
        }
        let res = try alloc.invoke([.i32(UInt32(bytes.count))])
        guard res.count == 1, case .i32(let ptr) = res[0], ptr != 0 else {
            throw BridgeError.allocFailed(bytes.count)
        }
        let mem = try memory()
        // Bounds-check the allocator's returned pointer BEFORE writing. The guest
        // allocator is guest-controlled; a buggy/hostile `patch_malloc` can return
        // a pointer near (or past) the end of linear memory, in which case
        // `withUnsafeMutableBufferPointer(offset:count:)` would write out of bounds
        // and corrupt guest memory / trap. `readBytes` already checks; this makes
        // the write path symmetric (fail closed with an OOB error instead).
        guard Int(ptr) >= 0, Int(ptr) + bytes.count <= mem.data.count else {
            // The buffer was already allocated in guest memory; free it before
            // throwing so a broken allocator can't leak one buffer per bridge call.
            // (Best-effort: a no-op if the guest exports no `patch_free`.)
            freeGuest(ptr)
            throw BridgeError.oob(ptr: ptr, len: UInt32(bytes.count))
        }
        mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: bytes.count) { raw in
            raw.copyBytes(from: bytes)
        }
        return (ptr, UInt32(bytes.count))
    }

    /// Pack `(ptr, len)` into the i64 result convention. `(0,0)` packs to 0.
    public static func pack(ptr: UInt32, len: UInt32) -> Value {
        .i64((UInt64(ptr) << 32) | UInt64(len))
    }

    /// Allocate + write `bytes` and return the packed i64 result (0 if empty/nil).
    public func packedResult(_ bytes: [UInt8]?) throws -> Value {
        guard let bytes, !bytes.isEmpty else { return .i64(0) }
        let (ptr, len) = try writeBytes(bytes)
        return Self.pack(ptr: ptr, len: len)
    }

    public func packedResult(_ string: String?) throws -> Value {
        try packedResult(string.map { [UInt8]($0.utf8) })
    }
}

// MARK: - Synchronous main-actor read helper

/// Run a `@MainActor` read synchronously and return its value, hopping to the
/// main thread.
///
/// Some device bridges (badge/brightness/VoiceOver/device-info/etc.) expose a
/// *synchronous* host getter whose guest call must return a real value, but the
/// underlying UIKit state is `@MainActor`-isolated. Such a getter cannot use a
/// fire-and-forget `Task { @MainActor in … }` (it needs the value back), and the
/// SDK's iOS-16 floor rules out `MainActor.assumeIsolated` (treat it as 17+).
///
/// Every host->wasm invocation — and therefore every bridge getter closure — runs
/// on `Patch.callQueue`, a private serial queue (see `Patch.swift`), NOT the main
/// queue. So `DispatchQueue.main.sync` here can never re-enter the main queue and
/// never deadlocks, and the `@MainActor` body makes the UIKit access well-isolated
/// (no "main actor-isolated state from a nonisolated/Sendable closure" diagnostic).
@inline(__always)
func patchMainActorSyncRead<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
    DispatchQueue.main.sync { body() }
}

// MARK: - Bridge protocol + registry

/// A native bridge: a set of host functions exposed to the guest under a module
/// namespace. `register` adds them to the WasmKit `Imports`.
public protocol Bridge {
    /// WASM import module namespace (e.g. "patch").
    var module: String { get }
    /// Add this bridge's host functions to `imports`.
    func register(into imports: inout Imports, store: Store)
}

/// Collects bridges and produces the `hostImports` closure `WASMRuntime` accepts.
/// This is also the **custom bridge registration API**: app devs add their own
/// `Bridge` (or raw host functions) before building the runtime.
public final class BridgeRegistry: @unchecked Sendable {
    private var bridges: [Bridge] = []
    /// Raw host-function registrations (the lowest-level custom API).
    private var raw: [(module: String, name: String, params: [ValueType], results: [ValueType], body: (Caller, [Value]) throws -> [Value])] = []
    private var defaultsInstalled = false
    private let lock = NSLock()

    public init() {}

    /// Register a packaged `Bridge`.
    @discardableResult
    public func register(_ bridge: Bridge) -> BridgeRegistry {
        lock.lock(); defer { lock.unlock() }
        bridges.append(bridge)
        return self
    }

    /// Custom bridge registration: expose an arbitrary host function to the guest
    /// under `module`.`name` with the given signature. The body receives the
    /// `Caller` (use `BridgeContext(caller:)` for memory access) and raw args.
    @discardableResult
    public func registerFunction(
        module: String = "patch",
        name: String,
        parameters: [ValueType],
        results: [ValueType],
        body: @escaping (Caller, [Value]) throws -> [Value]
    ) -> BridgeRegistry {
        lock.lock(); defer { lock.unlock() }
        raw.append((module, name, parameters, results, body))
        return self
    }

    /// Install all the default 9 bridges (idempotent — installs at most once per
    /// registry). Returns self for chaining.
    @discardableResult
    public func registerDefaults(
        userDefaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        navigation: NavigationBridge.Handler? = nil
    ) -> BridgeRegistry {
        lock.lock()
        if defaultsInstalled { lock.unlock(); return self }
        defaultsInstalled = true
        lock.unlock()
        register(URLSessionBridge())
        register(UserDefaultsBridge(defaults: userDefaults))
        register(NotificationCenterBridge(center: notificationCenter))
        register(NavigationBridge(handler: navigation))
        register(KeychainBridge())
        register(DateLocaleBridge())
        register(JSONBridge())
        // The Embedded-Swift "borrow the shell's Foundation" surface
        // (patch_host.decimal_op / json_get_i64 / now_unix_millis). This is what
        // lets a tiny Embedded OTA patch compute exact Decimal money math, read
        // JSON, and read Date() using the NATIVE shell's real Foundation/ICU.
        register(FoundationBridge())
        register(LoggingBridge())
        // Breakthrough #8 — host-ABI bridge FAMILY (module "patch_host"). The
        // read-only synchronous leaves the CLI's FusionRewriter rewrites a real
        // function's call sites onto, so a 95%-pure function whose only native
        // touch is one of these ships OTA instead of demoting. All plain
        // Foundation → cross-platform, registered unconditionally.
        register(FileManagerBridge())
        register(BundleBridge())
        register(ProcessInfoEnvBridge())
        register(UserDefaultsTypedBridge(defaults: userDefaults))
        // Breakthrough #6 — NETWORKING (async). Serves patch_host.http_get /
        // http_request (the async-suspend shape the FusionRewriter rewrites
        // `URLSession.shared.data(from:)`/`.data(for:)` onto). Backed by a real
        // URLSession broker out of the box (device path); cookies/TLS/auth stay
        // host-side. Distinct from the sync `patch.http_get` (URLSessionBridge) —
        // different module namespace, no collision. To DRIVE a guest that awaits a
        // fetch, resolve through this bridge's broker in the pump's stall handler
        // (see `Patch.callAsyncResult` / `PatchHTTPBroker.resolveCallback`).
        register(PatchHTTPBridge())
        // Wave-5 bridges. Each convenience default init is platform-guarded, so the
        // registration is gated by the same condition (tests inject their own impls
        // via overrides, so this only governs the out-of-the-box wiring).
        register(AnalyticsBridge())
        register(FileStorageBridge())
        #if canImport(Network)
        register(ConnectivityBridge())
        #endif
        #if canImport(LocalAuthentication)
        register(BiometricsBridge())
        #endif
        #if os(iOS) || os(tvOS) || os(visionOS)
        register(AppReviewBridge())        // StoreKit default init (iOS family only)
        register(InAppPurchaseBridge())    // StoreKit 2 (iOS family only)
        #endif
        #if canImport(UIKit)
        register(PasteboardBridge())
        register(HapticsBridge())
        register(DeviceInfoBridge())
        register(ShareSheetBridge())
        register(OpenURLBridge())
        register(AppBadgeBridge())
        register(DocumentPickerBridge())
        #endif
        #if canImport(CoreLocation)
        register(LocationBridge())
        #endif
        #if canImport(EventKit)
        register(CalendarBridge())
        #endif
        #if canImport(Contacts)
        register(ContactsBridge())
        #endif
        #if canImport(MessageUI)
        register(MailComposeBridge())
        #endif
        #if canImport(AVFoundation)
        register(SpeechSynthesisBridge())
        #endif
        #if canImport(AudioToolbox)
        register(SystemSoundBridge())
        #endif
        #if canImport(PhotosUI) && canImport(UIKit)
        register(PhotoPickerBridge())
        #endif
        // Wave-6 bridges (cross-platform defaults first, then platform-gated).
        register(ProcessInfoBridge())
        register(FileDownloadBridge())
        register(HandoffBridge())
        register(NetworkImageBridge())
        // (AppGroupStorageBridge needs an app-group suite name — register it explicitly.)
        #if canImport(Security)
        register(SecureRandomBridge())
        #endif
        #if canImport(AVFoundation)
        register(AudioPlaybackBridge())
        register(AudioRecordingBridge())
        register(VideoPlaybackBridge())
        #endif
        #if canImport(Speech)
        register(SpeechRecognitionBridge())
        #endif
        #if canImport(CoreImage)
        register(ImageFilterBridge())
        register(QRGenerateBridge())
        #endif
        #if canImport(CoreGraphics) && canImport(CoreText)
        register(PDFGenerateBridge())
        #endif
        #if canImport(CoreSpotlight)
        register(SpotlightIndexBridge())
        #endif
        #if canImport(WatchConnectivity)
        register(WatchConnectivityBridge())
        #endif
        #if canImport(CoreNFC)
        register(NfcReadBridge())
        #endif
        #if canImport(UIKit)
        register(ScreenControlBridge())
        register(MapsDirectionsBridge())
        register(BackgroundTaskBridge())
        register(AccessibilityBridge())
        register(AppShortcutsBridge())
        #endif
        #if os(iOS) || os(watchOS) || os(visionOS)
        register(MotionBridge())
        #endif
        #if os(iOS) || os(tvOS) || os(visionOS)
        register(MediaInfoBridge())
        register(CameraBridge())
        #endif
        return self
    }

    /// The closure `WASMRuntime(hostImports:)` expects. Applies every bridge +
    /// raw function. Capture this once and pass it to the runtime.
    public func hostImports() -> (inout Imports, Store) -> Void {
        let bridgesSnapshot: [Bridge]
        let rawSnapshot: [(module: String, name: String, params: [ValueType], results: [ValueType], body: (Caller, [Value]) throws -> [Value])]
        lock.lock()
        bridgesSnapshot = bridges
        rawSnapshot = raw
        lock.unlock()
        return { imports, store in
            for b in bridgesSnapshot { b.register(into: &imports, store: store) }
            for r in rawSnapshot {
                imports.define(
                    module: r.module, name: r.name,
                    Function(store: store, parameters: r.params, results: r.results, body: r.body))
            }
        }
    }
}

// Small helper to cut boilerplate when a bridge defines a host function.
// NOTE: `Imports` has a nested `Imports.Value` type, so inside this extension
// the bare names `Value`/`ValueType` would resolve into the `Imports` namespace.
// Qualify everything with `WasmKit.` to bind to the WASM ABI types.
extension Imports {
    mutating func host(
        _ module: String, _ name: String,
        _ params: [WasmKit.ValueType], _ results: [WasmKit.ValueType],
        store: Store,
        _ body: @escaping (WasmKit.Caller, [WasmKit.Value]) throws -> [WasmKit.Value]
    ) {
        define(module: module, name: name,
               Function(store: store, parameters: params, results: results, body: body))
    }
}

// MARK: - 1. URLSession (networking)
//
// Synchronous-from-the-guest HTTP GET. The guest passes a URL `(ptr,len)`; the
// host performs a blocking request and returns the body as a packed-i64
// `(ptr,len)` blob (0 on error). Real networking on device; in tests inject a
// mock session. Marked device-exercised — uses real URLSession (works on macOS
// too, but tests avoid real network).
public struct URLSessionBridge: Bridge {
    public let module = "patch"
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func register(into imports: inout Imports, store: Store) {
        let session = self.session
        imports.host(module, "http_get", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let url = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let body = Self.syncGet(url, session: session)
            return [try ctx.packedResult(body)]
        }
    }

    /// Blocking GET (the guest call is synchronous). Returns body bytes or nil.
    static func syncGet(_ urlString: String, session: URLSession) -> [UInt8]? {
        guard let url = URL(string: urlString) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        let box = ByteBox()
        let task = session.dataTask(with: url) { data, _, _ in
            if let data { box.set([UInt8](data)) }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 30)
        return box.get()
    }
}

/// Tiny thread-safe box so the completion handler can hand bytes back to the
/// blocking caller without a data-race warning.
private final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [UInt8]?
    func set(_ v: [UInt8]) { lock.lock(); value = v; lock.unlock() }
    func get() -> [UInt8]? { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - 2. UserDefaults
//
// get(key) -> packed string blob (0 if absent); set(key, value); remove(key).
public struct UserDefaultsBridge: Bridge {
    public let module = "patch"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func register(into imports: inout Imports, store: Store) {
        let defaults = self.defaults
        imports.host(module, "defaults_get", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [try ctx.packedResult(defaults.string(forKey: key))]
        }
        imports.host(module, "defaults_set", [.i32, .i32, .i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let val = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            defaults.set(val, forKey: key)
            return []
        }
        imports.host(module, "defaults_remove", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            defaults.removeObject(forKey: key)
            return []
        }
    }
}

// MARK: - 3. NotificationCenter
//
// post(name) — posts a Notification with the given name. (UserInfo marshalling
// is left to a custom bridge; the core post path is what patches need.)
public struct NotificationCenterBridge: Bridge {
    public let module = "patch"
    private let center: NotificationCenter
    public init(center: NotificationCenter = .default) { self.center = center }

    public func register(into imports: inout Imports, store: Store) {
        let center = self.center
        imports.host(module, "notify_post", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let name = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            center.post(name: Notification.Name(name), object: nil)
            return []
        }
    }
}

// MARK: - 4. Navigation (iOS-device-oriented)
//
// navigate(route) — hands a route string to a host-supplied handler (which on
// iOS drives the real navigation stack / UINavigationController / SwiftUI
// router). Compiles everywhere; the handler is app-supplied. Without a handler
// it is a no-op (so it is unit-testable on macOS by injecting a handler).
public struct NavigationBridge: Bridge {
    public typealias Handler = @Sendable (_ route: String) -> Void
    public let module = "patch"
    private let handler: Handler?
    public init(handler: Handler? = nil) { self.handler = handler }

    public func register(into imports: inout Imports, store: Store) {
        let handler = self.handler
        imports.host(module, "navigate", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let route = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            handler?(route)
            return []
        }
    }
}

// MARK: - 5. Keychain (iOS-device-only secure storage)
//
// keychain_get(key) -> packed blob; keychain_set(key, value); keychain_delete(key).
// Backed by the Security framework (`SecItem*`). The Security calls compile on
// macOS too but behave differently (login keychain / entitlements), so the
// bridge is structured + compiles cross-platform and is treated as
// **device-only** for behavioral testing. The marshalling layer around it IS
// unit-tested via a custom-bridge stub.
public struct KeychainBridge: Bridge {
    public let module = "patch"
    private let service: String
    public init(service: String = "com.patch.sdk.keychain") { self.service = service }

    public func register(into imports: inout Imports, store: Store) {
        let service = self.service
        imports.host(module, "keychain_get", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [try ctx.packedResult(Keychain.get(service: service, account: key))]
        }
        imports.host(module, "keychain_set", [.i32, .i32, .i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let val = try ctx.readBytes(ptr: args[2].i32, len: args[3].i32)
            return [.i32(Keychain.set(service: service, account: key, data: Data(val)) ? 1 : 0)]
        }
        imports.host(module, "keychain_delete", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let key = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [.i32(Keychain.delete(service: service, account: key) ? 1 : 0)]
        }
    }
}

/// Thin wrapper over the Security framework. Device-only behavior; compiles on
/// all Apple platforms.
public enum Keychain {
    public static func set(service: String, account: String, data: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func get(service: String, account: String) -> [UInt8]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return [UInt8](data)
    }

    @discardableResult
    public static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let s = SecItemDelete(query as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}

// MARK: - 6. Date / Locale
//
// now_unix_millis() -> i64; locale_identifier() -> packed string;
// timezone_identifier() -> packed string. Gives patches host time/locale
// without bundling ICU (per DECISIONS: OTA code is pure/embedded; time+locale
// come from the native shell). Fully cross-platform → fully tested.
public struct DateLocaleBridge: Bridge {
    public let module = "patch"
    private let clock: @Sendable () -> Date
    private let localeProvider: @Sendable () -> Locale
    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        locale: @escaping @Sendable () -> Locale = { Locale.current }
    ) {
        self.clock = clock
        self.localeProvider = locale
    }

    public func register(into imports: inout Imports, store: Store) {
        let clock = self.clock
        let localeProvider = self.localeProvider
        imports.host(module, "now_unix_millis", [], [.i64], store: store) { _, _ in
            [.i64(UInt64(bitPattern: Int64(clock().timeIntervalSince1970 * 1000)))]
        }
        imports.host(module, "locale_identifier", [], [.i64], store: store) { caller, _ in
            let ctx = BridgeContext(caller: caller)
            return [try ctx.packedResult(localeProvider().identifier)]
        }
        imports.host(module, "timezone_identifier", [], [.i64], store: store) { caller, _ in
            let ctx = BridgeContext(caller: caller)
            return [try ctx.packedResult(TimeZone.current.identifier)]
        }
    }
}

// MARK: - 7. JSON
//
// json_canonicalize(blob) -> packed blob: parse arbitrary JSON in the guest's
// memory and return a re-serialized (sorted-keys) canonical form. This lets
// embedded-Swift guests (which have no Foundation JSON) offload JSON to the
// native shell's Foundation. Fully cross-platform → fully tested.
public struct JSONBridge: Bridge {
    public let module = "patch"
    public init() {}

    public func register(into imports: inout Imports, store: Store) {
        imports.host(module, "json_canonicalize", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]),
                  let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .fragmentsAllowed])
            else { return [.i64(0)] }
            return [try ctx.packedResult([UInt8](out))]
        }
    }
}

// MARK: - 8. Foundation value bridge (Embedded Swift "borrow the shell's Foundation")
//
// This is the bridge that makes the Embedded-Swift + host-bridge module model
// work: an OTA patch compiled with the EMBEDDED WASM SDK has NO Foundation in it
// (no Decimal, no JSONSerialization, no Date — those would statically link
// ICU/Foundation and balloon to ~57 MB). Instead the patch imports these flat
// host functions and the NATIVE shell satisfies them with its REAL Foundation.
// Result: tens-of-KB patches with full Decimal/JSON/Date semantics.
//
// CRITICAL ABI NOTE (research finding, shell-foundation/FINDINGS.md): the patch
// MUST declare these imports through a generated **C header** with
// `__attribute__((import_module("patch_host"), import_name("...")))` — NOT Swift
// `@_extern(wasm)`, whose mangled, non-flat ABI WasmKit rejects. The CLI codegen
// emits exactly that header (`CodeGenerator.CHeaderBridge`). The module namespace
// is therefore **"patch_host"** (not "patch"), and every function here uses the
// flat scalar ABI Clang's attributes produce.
//
// Surface (the complete "Foundation value" set proven to run on WasmKit 0.2.2):
//   * `decimal_op(op:i32, a:i64, b:i64, scale:i32) -> i64`
//        Exact base-10 Decimal arithmetic. op: 0=mul 1=div 2=add 3=sub.
//        Operands are integers the guest tracks at its own fixed-point `scale`;
//        the host does real `Decimal` math and rounds the result to an integer
//        (half-up). This gives precise money math with no ICU in the patch.
//   * `json_get_i64(ptr:i32, len:i32, keyPtr:i32, keyLen:i32) -> i64`
//        Parse a JSON object in guest memory (real `JSONSerialization`) and
//        return the integer value of a top-level numeric field (0 if absent).
//   * `now_unix_millis() -> i64`
//        Real native `Date()` as Unix epoch milliseconds.
//
// Cross-platform → fully unit-tested. The clock is injectable for determinism.
public struct FoundationBridge: Bridge {
    /// op codes accepted by `decimal_op`.
    ///
    /// 0-3 are the base arithmetic ops, all rounding the integer result half-up.
    /// `divFloor` (4) is division that **truncates toward zero** — the standard
    /// money policy for taxes/fees (matches integer-cents `(a*rate)/denom`), so a
    /// patch can reproduce exact ledger arithmetic via real base-10 Decimal.
    public enum Op: Int32, Sendable { case mul = 0, div = 1, add = 2, sub = 3, divFloor = 4 }

    public let module = "patch_host"
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Pure host-side Decimal computation, exposed (and unit-tested) directly so
    /// the round-trip can be asserted without a wasm instance. Mirrors EXACTLY
    /// what the registered `decimal_op` host function does.
    ///
    /// - Parameters:
    ///   - op: 0=mul 1=div 2=add 3=sub.
    ///   - a, b: integer operands (guest tracks fixed-point scale itself).
    ///   - scale: advisory fixed-point scale the guest uses (not applied here —
    ///       the host returns an integer rounded result, matching the proven
    ///       bridge; kept in the ABI so a future policy can use it).
    /// - Returns: the result rounded to an integer (half-up). div-by-0 → 0.
    public static func decimalOp(op: Int32, a: Int64, b: Int64, scale: Int32) -> Int64 {
        let da = Decimal(a)
        let db = Decimal(b)
        var out: Decimal
        let mode: NSDecimalNumber.RoundingMode = .plain   // half-up by default
        // `divFloor` must TRUNCATE TOWARD ZERO (the integer-division semantics
        // ledger math relies on — C/Python `(a*rate)/denom` truncates toward 0).
        // `NSDecimalNumber.RoundingMode.down` is FLOOR (toward −∞), which is WRONG
        // for a negative result: e.g. divFloor(-5,2) must be -2, not -3 (.down).
        // So round the MAGNITUDE with `.down` and re-apply the sign — correct for
        // both signs, and identical to `.down` for the positive case (unchanged).
        var truncateTowardZero = false
        switch op {
        case Op.mul.rawValue: out = da * db
        case Op.div.rawValue: out = b == 0 ? 0 : da / db
        case Op.add.rawValue: out = da + db
        case Op.divFloor.rawValue:
            out = b == 0 ? 0 : da / db
            truncateTowardZero = true
        default:              out = da - db   // sub / unknown → sub
        }
        var rounded = Decimal()
        if truncateTowardZero {
            // Round |out| down, then restore the sign → truncation toward zero.
            let negative = out < 0
            var src = negative ? -out : out
            NSDecimalRound(&rounded, &src, 0, .down)
            if negative { rounded = -rounded }
        } else {
            var src = out
            NSDecimalRound(&rounded, &src, 0, mode)       // → integer
        }
        return (rounded as NSDecimalNumber).int64Value
    }

    /// Host-side JSON top-level integer field read (mirrors the `json_get_i64`
    /// host function), exposed for direct unit testing.
    public static func jsonGetI64(_ jsonBytes: [UInt8], key: String) -> Int64 {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(jsonBytes)) as? [String: Any],
              let n = obj[key] as? NSNumber else { return 0 }
        return n.int64Value
    }

    // MARK: - Expanded Foundation bridge surface (research/foundation-bridges)
    //
    // Typed JSON readers + string-return formatter/regex/date bridges. These widen
    // the set of fragments CodeEmitter can ship at the tiny Embedded (T0) tier: a
    // fragment whose boundary is a String/Double or that formats a number / runs a
    // regex no longer needs to statically link Foundation (~60 MB, demoted on size)
    // — it calls the native shell's real Foundation through these flat host
    // functions. All mirror the existing FoundationBridge/BridgeContext patterns.
    // Each is exposed as a `static func` for direct unit testing (like decimalOp /
    // jsonGetI64), with the registered host function delegating to it.

    /// `json_get_string` — top-level String field of a JSON object (nil if absent
    /// or non-String).
    public static func jsonGetString(_ jsonBytes: [UInt8], key: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(jsonBytes)) as? [String: Any],
              let s = obj[key] as? String else { return nil }
        return s
    }

    /// `json_get_f64` — top-level numeric field as a Double (nil if absent/non-number).
    public static func jsonGetF64(_ jsonBytes: [UInt8], key: String) -> Double? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(jsonBytes)) as? [String: Any],
              let n = obj[key] as? NSNumber else { return nil }
        return n.doubleValue
    }

    /// `json_get_bool` — tri-state top-level Bool field. nil = absent/non-bool.
    /// CRITICAL: a JSON `true`/`false` bridges to an `NSNumber` whose
    /// `objCType` is `c` (a bool), shared with `0`/`1` integers. Match on the
    /// concrete `Bool` cast so `1` (an Int) is NOT mistaken for `true`.
    public static func jsonGetBool(_ jsonBytes: [UInt8], key: String) -> Bool? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(jsonBytes)) as? [String: Any],
              let raw = obj[key] else { return nil }
        guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// `json_get_subobject` — extract the nested JSON value at a top-level `key` and
    /// re-serialize it as its OWN JSON blob (nil if absent). Used to marshal a
    /// VALUE-TYPE receiver/arg at T0: the guest reads the sub-blob, then re-reads each
    /// scalar stored field from it with the existing top-level json_get_* readers — no
    /// in-guest Foundation/Codable. Keys are sorted so the blob is deterministic.
    public static func jsonGetSubobject(_ jsonBytes: [UInt8], key: String) -> [UInt8]? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(jsonBytes)) as? [String: Any],
              let sub = obj[key] else { return nil }
        // The sub-value must itself be a JSON object/array (a value type's encoded
        // form). A scalar at `key` is not a sub-object — return nil (the guest then
        // treats the field as absent and uses scalar readers directly, never reached
        // for a value-type field).
        guard JSONSerialization.isValidJSONObject(sub) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: sub, options: [.sortedKeys]) else {
            return nil
        }
        return [UInt8](data)
    }

    /// `number_format` — real `NumberFormatter` (decimal/currency/percent), locale-
    /// aware via the shell's ICU. style: 0=decimal 1=currency 2=percent.
    public static func numberFormat(valueBits: Int64, style: Int32, fractionDigits: Int32,
                                    locale: String) -> String {
        let value = Double(bitPattern: UInt64(bitPattern: valueBits))
        let f = NumberFormatter()
        f.locale = Locale(identifier: locale.isEmpty ? "en_US" : locale)
        switch style {
        case 1: f.numberStyle = .currency
        case 2: f.numberStyle = .percent
        default: f.numberStyle = .decimal
        }
        let frac = Int(fractionDigits)
        f.minimumFractionDigits = frac
        f.maximumFractionDigits = frac
        return f.string(from: NSNumber(value: value)) ?? ""
    }

    /// `regex_find` — first match substring via `NSRegularExpression` (nil on no
    /// match / invalid pattern).
    public static func regexFind(_ str: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = str as NSString
        guard let m = re.firstMatch(in: str, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: m.range)
    }

    /// `regex_count` — number of matches (0 on invalid pattern).
    public static func regexCount(_ str: String, pattern: String) -> Int32 {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let ns = str as NSString
        return Int32(re.numberOfMatches(in: str, range: NSRange(location: 0, length: ns.length)))
    }

    /// `date_format` — format a Unix-millis instant with a `DateFormatter` pattern.
    /// tz defaults to UTC; locale fixed to en_US_POSIX so the pattern is stable.
    public static func dateFormat(unixMillis: Int64, format: String, timeZone: String) -> String {
        let f = DateFormatter()
        f.dateFormat = format
        f.timeZone = TimeZone(identifier: timeZone.isEmpty ? "UTC" : timeZone)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date(timeIntervalSince1970: Double(unixMillis) / 1000.0))
    }

    // MARK: - Foundation VALUE bridges (Date / ISO8601 / NumberFormatter localized)
    //
    // These are the "common Foundation value API" bridges the FusionRewriter routes
    // a real-source call site onto so a function that does date math / ISO8601
    // string<->date / localized number formatting runs IN WASM at T0 (no in-module
    // Foundation/ICU) by calling the native shell's real Foundation. Each maps a
    // SINGLE, unambiguous developer call form to a deterministic host computation.
    //
    // FIDELITY DISCIPLINE (the safety bar): a bridge ships ONLY the forms whose
    // semantics the host reproduces EXACTLY:
    //   * ISO8601 string<->date is a FIXED, locale-INDEPENDENT, UTC wire format —
    //     `ISO8601DateFormatter()` default options (`.withInternetDateTime`) — so
    //     there is no locale/timezone to get wrong. This is the safest date bridge.
    //   * the device CLOCK (`now_unix_millis`) is the one true host fact; a guest
    //     `Date()` under the WASM SDK has no real clock, so reading the shell's is
    //     STRICTLY more correct.
    //   * localized number formatting passes the developer's EXPLICIT locale through
    //     to the shell's real ICU (it is never silently defaulted to a wrong locale).

    /// `iso8601_format` — a Unix-millis instant → an ISO 8601 internet-date-time
    /// string (e.g. `2021-01-01T00:00:00Z`), using `ISO8601DateFormatter()` with its
    /// DEFAULT options. Locale-independent + UTC — deterministic, no fidelity risk.
    public static func iso8601Format(unixMillis: Int64) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date(timeIntervalSince1970: Double(unixMillis) / 1000.0))
    }

    /// `iso8601_parse` — an ISO 8601 internet-date-time string → Unix MILLIS, or the
    /// sentinel `INT64_MIN` when the string does not parse (the guest treats it as
    /// `nil`, matching `ISO8601DateFormatter().date(from:)` returning `nil`).
    /// `INT64_MIN` is unreachable as a real instant, so it can never collide with a
    /// genuine parsed value.
    public static let iso8601ParseNil: Int64 = .min
    public static func iso8601Parse(_ string: String) -> Int64 {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: string) else { return Self.iso8601ParseNil }
        return Int64((d.timeIntervalSince1970 * 1000.0).rounded())
    }

    // MARK: - LEVER #2: Date/Calendar/Formatter host bridges (locale/ICU on the shell)
    //
    // The most common bug-fix shapes — relative-date phrasing, localized number /
    // currency formatting, styled date formatting, and Calendar date math — all need
    // ICU + locale data the Embedded WASM guest does NOT carry (~11.7 MB if linked).
    // These flat `patch_host` host fns let the guest offload each to the native
    // shell's REAL Foundation. Every one maps a SINGLE, deterministic developer call
    // form to a host computation; the developer's EXPLICIT inputs (style/locale)
    // pass through so nothing is silently mis-localized. Each is a `static func`
    // exposed for direct unit testing (mirroring numberFormat/dateFormat above), with
    // the registered host fn delegating to it.

    /// `relative_date_format` — `RelativeDateTimeFormatter().localizedString(for:relativeTo:)`.
    /// `unitsStyle`: 0=full 1=spellOut 2=short 3=abbreviated (the enum's raw order).
    /// `dateContext`/`relativeContext` are Unix MILLIS. Locale-aware via the shell's
    /// real ICU (empty locale → current). This is the `SettingsScreen.relativeString`
    /// bug-fix shape — "2 hr ago", "yesterday", "in 3 days".
    public static func relativeDateFormat(forMillis: Int64, relativeToMillis: Int64,
                                          unitsStyle: Int32, locale: String) -> String {
        let f = RelativeDateTimeFormatter()
        switch unitsStyle {
        case 1: f.unitsStyle = .spellOut
        case 2: f.unitsStyle = .short
        case 3: f.unitsStyle = .abbreviated
        default: f.unitsStyle = .full
        }
        if !locale.isEmpty { f.locale = Locale(identifier: locale) }
        let d = Date(timeIntervalSince1970: Double(forMillis) / 1000.0)
        let ref = Date(timeIntervalSince1970: Double(relativeToMillis) / 1000.0)
        return f.localizedString(for: d, relativeTo: ref)
    }

    /// `date_format_styled` — `DateFormatter` with `dateStyle`/`timeStyle` (the
    /// localized-style builder, distinct from the pattern-based `date_format`).
    /// style: 0=none 1=short 2=medium 3=long 4=full (matches `DateFormatter.Style`).
    /// Locale-aware (empty → current); tz empty → current. This is the dominant
    /// "show a date the way the user's region expects" shape.
    public static func dateFormatStyled(unixMillis: Int64, dateStyle: Int32, timeStyle: Int32,
                                        locale: String, timeZone: String) -> String {
        let f = DateFormatter()
        func style(_ raw: Int32) -> DateFormatter.Style {
            switch raw { case 1: return .short; case 2: return .medium
            case 3: return .long; case 4: return .full; default: return .none }
        }
        f.dateStyle = style(dateStyle)
        f.timeStyle = style(timeStyle)
        if !locale.isEmpty { f.locale = Locale(identifier: locale) }
        if !timeZone.isEmpty { f.timeZone = TimeZone(identifier: timeZone) }
        return f.string(from: Date(timeIntervalSince1970: Double(unixMillis) / 1000.0))
    }

    /// `calendar_date_op` — common `Calendar.current` date math, all returning a Unix
    /// MILLIS instant (or `INT64_MIN` for the failure/nil shapes). `op`:
    ///   0 = `startOfDay(for:)`            — `a` only.
    ///   1 = `date(byAdding: <component>, value:, to:)` — `a` = base millis, `b` =
    ///       signed amount, `component` selects the unit.
    ///   2 = `isDate(a, inSameDayAs: b)`   — returns 1 (same day) / 0 (different), NOT
    ///       a millis value (the guest reads it as a Bool i64).
    /// `component`: 0=second 1=minute 2=hour 3=day 4=weekOfYear 5=month 6=year.
    /// Locale/timezone come from `Calendar.current` (the shell's real region) so the
    /// "off-by-one across midnight / DST" class of bug is computed with real rules.
    public static let calendarOpNil: Int64 = .min
    public static func calendarDateOp(op: Int32, a: Int64, b: Int64, component: Int32,
                                      timeZone: String) -> Int64 {
        var cal = Calendar.current
        if !timeZone.isEmpty, let tz = TimeZone(identifier: timeZone) { cal.timeZone = tz }
        let base = Date(timeIntervalSince1970: Double(a) / 1000.0)
        func comp(_ raw: Int32) -> Calendar.Component {
            switch raw { case 0: return .second; case 1: return .minute; case 2: return .hour
            case 4: return .weekOfYear; case 5: return .month; case 6: return .year
            default: return .day }
        }
        switch op {
        case 0:
            return Int64((cal.startOfDay(for: base).timeIntervalSince1970 * 1000.0).rounded())
        case 1:
            guard let out = cal.date(byAdding: comp(component), value: Int(b), to: base) else {
                return Self.calendarOpNil
            }
            return Int64((out.timeIntervalSince1970 * 1000.0).rounded())
        case 2:
            let other = Date(timeIntervalSince1970: Double(b) / 1000.0)
            return cal.isDate(base, inSameDayAs: other) ? 1 : 0
        default:
            return Self.calendarOpNil
        }
    }

    /// `calendar_component` — read a single `Calendar.current.component(_:from:)`
    /// integer (year/month/day/hour/minute/second/weekday/etc.). `component` matches
    /// `calendarDateOp` plus 7=weekday 8=dayOfYear. tz empty → current. The
    /// "extract the day/month from a Date with the user's real calendar" shape.
    public static func calendarComponent(unixMillis: Int64, component: Int32, timeZone: String) -> Int64 {
        var cal = Calendar.current
        if !timeZone.isEmpty, let tz = TimeZone(identifier: timeZone) { cal.timeZone = tz }
        let d = Date(timeIntervalSince1970: Double(unixMillis) / 1000.0)
        let c: Calendar.Component
        switch component {
        case 0: c = .second; case 1: c = .minute; case 2: c = .hour
        case 4: c = .weekOfYear; case 5: c = .month; case 6: c = .year
        case 7: c = .weekday
        case 8:
            // dayOfYear: `Calendar.Component.dayOfYear` is macOS 15+/iOS 18+, but the
            // SDK targets lower. `ordinality(of:.day, in:.year, for:)` yields the same
            // 1-based day-within-year and is available since iOS 8 / macOS 10.4.
            return Int64(cal.ordinality(of: .day, in: .year, for: d) ?? 1)
        default: c = .day
        }
        return Int64(cal.component(c, from: d))
    }

    public func register(into imports: inout Imports, store: Store) {
        // decimal_op(op, a, b, scale) -> i64 — exact base-10 Decimal in the host.
        imports.host(module, "decimal_op", [.i32, .i64, .i64, .i32], [.i64], store: store) { _, args in
            let op = Int32(bitPattern: args[0].i32)
            let a = Int64(bitPattern: args[1].i64)
            let b = Int64(bitPattern: args[2].i64)
            let scale = Int32(bitPattern: args[3].i32)
            let v = Self.decimalOp(op: op, a: a, b: b, scale: scale)
            return [.i64(UInt64(bitPattern: v))]
        }
        // json_get_i64(ptr, len, keyPtr, keyLen) -> i64 — real JSONSerialization.
        imports.host(module, "json_get_i64", [.i32, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let jsonBytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            let key = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            let v = Self.jsonGetI64(jsonBytes, key: key)
            return [.i64(UInt64(bitPattern: v))]
        }
        // now_unix_millis() -> i64 — real native Date(). (Distinct namespace from
        // DateLocaleBridge's `patch.now_unix_millis`; both can coexist.)
        let clock = self.clock
        imports.host(module, "now_unix_millis", [], [.i64], store: store) { _, _ in
            [.i64(UInt64(bitPattern: Int64(clock().timeIntervalSince1970 * 1000)))]
        }

        // ---- Expanded surface (research/foundation-bridges) ------------------
        // Typed JSON readers (complete the json_get_* family).
        // json_get_string(ptr,len,key,keyLen) -> i64 packed string (0 = absent).
        imports.host(module, "json_get_string", [.i32, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            let key = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            return [try ctx.packedResult(Self.jsonGetString(bytes, key: key))]
        }
        // json_get_f64(ptr,len,key,keyLen) -> i64 holding the Double's bit-pattern
        // (0 = absent — the guest reads the bits and treats 0 as nil).
        imports.host(module, "json_get_f64", [.i32, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            let key = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            guard let d = Self.jsonGetF64(bytes, key: key) else { return [.i64(0)] }
            return [.i64(d.bitPattern)]
        }
        // json_get_bool(ptr,len,key,keyLen) -> i32 tri-state (1 true, 0 false, -1 absent).
        imports.host(module, "json_get_bool", [.i32, .i32, .i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            let key = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            guard let b = Self.jsonGetBool(bytes, key: key) else { return [.i32(UInt32(bitPattern: -1))] }
            return [.i32(b ? 1 : 0)]
        }
        // json_get_subobject(ptr,len,key,keyLen) -> i64 packed sub-blob (0 = absent).
        // Extract a nested value-type field as its own JSON blob (value-type T0 marshalling).
        imports.host(module, "json_get_subobject", [.i32, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            let key = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            guard let sub = Self.jsonGetSubobject(bytes, key: key) else { return [.i64(0)] }
            return [try ctx.packedResult(String(decoding: sub, as: UTF8.self))]
        }

        // String-return formatter / regex / date bridges. The host allocates a
        // guest buffer (via the guest's exported patch_malloc — exactly what
        // BridgeContext.packedResult does), writes the UTF-8 bytes, returns packed
        // (ptr,len); the guest reads with String(decoding:as:) and frees.
        // number_format(valueBits, style, fractionDigits, locale ptr,len) -> packed string.
        imports.host(module, "number_format", [.i64, .i32, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let loc = try ctx.readString(ptr: args[3].i32, len: args[4].i32)
            let s = Self.numberFormat(valueBits: Int64(bitPattern: args[0].i64),
                                      style: Int32(bitPattern: args[1].i32),
                                      fractionDigits: Int32(bitPattern: args[2].i32),
                                      locale: loc)
            return [try ctx.packedResult(s)]
        }
        // regex_find(str ptr,len, pat ptr,len) -> packed first-match substring (0 none).
        imports.host(module, "regex_find", [.i32, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let s = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let pat = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            return [try ctx.packedResult(Self.regexFind(s, pattern: pat))]
        }
        // regex_count(str ptr,len, pat ptr,len) -> i32 match count.
        imports.host(module, "regex_count", [.i32, .i32, .i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let s = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let pat = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            return [.i32(UInt32(bitPattern: Self.regexCount(s, pattern: pat)))]
        }
        // date_format(unixMillis, fmt ptr,len, tz ptr,len) -> packed string.
        imports.host(module, "date_format", [.i64, .i32, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let fmt = try ctx.readString(ptr: args[1].i32, len: args[2].i32)
            let tz = try ctx.readString(ptr: args[3].i32, len: args[4].i32)
            let s = Self.dateFormat(unixMillis: Int64(bitPattern: args[0].i64), format: fmt, timeZone: tz)
            return [try ctx.packedResult(s)]
        }
        // iso8601_format(unixMillis) -> packed string (ISO 8601 internet-date-time, UTC).
        imports.host(module, "iso8601_format", [.i64], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            return [try ctx.packedResult(Self.iso8601Format(unixMillis: Int64(bitPattern: args[0].i64)))]
        }
        // iso8601_parse(str ptr,len) -> i64 Unix MILLIS (INT64_MIN = unparseable/nil).
        imports.host(module, "iso8601_parse", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let s = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [.i64(UInt64(bitPattern: Self.iso8601Parse(s)))]
        }

        // ---- LEVER #2: Date/Calendar/Formatter host bridges --------------------
        // relative_date_format(forMillis, relativeToMillis, unitsStyle, loc ptr,len) -> packed string.
        imports.host(module, "relative_date_format", [.i64, .i64, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let loc = try ctx.readString(ptr: args[3].i32, len: args[4].i32)
            let s = Self.relativeDateFormat(forMillis: Int64(bitPattern: args[0].i64),
                                            relativeToMillis: Int64(bitPattern: args[1].i64),
                                            unitsStyle: Int32(bitPattern: args[2].i32),
                                            locale: loc)
            return [try ctx.packedResult(s)]
        }
        // date_format_styled(unixMillis, dateStyle, timeStyle, loc ptr,len, tz ptr,len) -> packed string.
        imports.host(module, "date_format_styled", [.i64, .i32, .i32, .i32, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let loc = try ctx.readString(ptr: args[3].i32, len: args[4].i32)
            let tz = try ctx.readString(ptr: args[5].i32, len: args[6].i32)
            let s = Self.dateFormatStyled(unixMillis: Int64(bitPattern: args[0].i64),
                                          dateStyle: Int32(bitPattern: args[1].i32),
                                          timeStyle: Int32(bitPattern: args[2].i32),
                                          locale: loc, timeZone: tz)
            return [try ctx.packedResult(s)]
        }
        // calendar_date_op(op, a, b, component, tz ptr,len) -> i64 Unix MILLIS (or 1/0 for op 2, INT64_MIN nil).
        imports.host(module, "calendar_date_op", [.i32, .i64, .i64, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let tz = try ctx.readString(ptr: args[4].i32, len: args[5].i32)
            let v = Self.calendarDateOp(op: Int32(bitPattern: args[0].i32),
                                        a: Int64(bitPattern: args[1].i64),
                                        b: Int64(bitPattern: args[2].i64),
                                        component: Int32(bitPattern: args[3].i32),
                                        timeZone: tz)
            return [.i64(UInt64(bitPattern: v))]
        }
        // calendar_component(unixMillis, component, tz ptr,len) -> i64 component value.
        imports.host(module, "calendar_component", [.i64, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let tz = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            let v = Self.calendarComponent(unixMillis: Int64(bitPattern: args[0].i64),
                                           component: Int32(bitPattern: args[1].i32),
                                           timeZone: tz)
            return [.i64(UInt64(bitPattern: v))]
        }
    }
}

// MARK: - 9. Logging / Analytics
//
// log(level, message): record a log line. Routes to a host sink (default: `os`
// unified logging where available, else print). Captures lines for testing via
// an injectable sink. Fully cross-platform → fully tested.
public struct LoggingBridge: Bridge {
    public typealias Sink = @Sendable (_ level: Int32, _ message: String) -> Void
    public let module = "patch"
    private let sink: Sink

    public init(sink: Sink? = nil) {
        if let sink { self.sink = sink; return }
        #if canImport(os)
        let logger = Logger(subsystem: "com.patch.sdk", category: "patch-module")
        self.sink = { level, msg in
            switch level {
            case 0: logger.debug("\(msg, privacy: .public)")
            case 1: logger.info("\(msg, privacy: .public)")
            case 2: logger.warning("\(msg, privacy: .public)")
            default: logger.error("\(msg, privacy: .public)")
            }
        }
        #else
        self.sink = { level, msg in print("[patch][\(level)] \(msg)") }
        #endif
    }

    public func register(into imports: inout Imports, store: Store) {
        let sink = self.sink
        imports.host(module, "log", [.i32, .i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let level = Int32(bitPattern: args[0].i32)
            let msg = try ctx.readString(ptr: args[1].i32, len: args[2].i32)
            sink(level, msg)
            return []
        }
    }
}
