import Foundation
import WasmKit
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

// Patch — the public entry point of the on-device OTA SDK.
//
// Provides configuration, the runtime/marshalling core, the thread-safety
// foundation (a serial call queue plus a read/write lock guarding the active
// module so hot-swap is safe while calls are in flight), `Patch.call` against
// the active module, and the high-level orchestration that wires the loader
// (download/verify/cache), native fallback chain, hot-swap activation, and the
// host bridges together.

// MARK: - Configuration

/// Which update stream this app pulls patches from.
///
/// The three presets (`production` / `staging` / `development`) are conveniences;
/// `custom("…")` carries an arbitrary backend channel string (channels are
/// free-form on the backend). `name` is what goes on the wire.
public enum PatchChannel: Sendable, Equatable {
    case production
    case staging
    case development
    /// Any backend-defined channel string (e.g. `"beta"`, `"qa-eu"`).
    case custom(String)

    /// The wire string sent in the update-check `channel` field.
    public var name: String {
        switch self {
        case .production: return "production"
        case .staging: return "staging"
        case .development: return "development"
        case .custom(let s): return s
        }
    }

    /// Build a channel from an arbitrary string, mapping the three known names
    /// back to their presets and anything else to `.custom`.
    public init(_ name: String) {
        switch name {
        case "production": self = .production
        case "staging": self = .staging
        case "development": self = .development
        default: self = .custom(name)
        }
    }
}

/// SDK configuration supplied once at launch via `Patch.configure(...)`.
public struct PatchConfiguration: Sendable {
    /// Per-app identifier issued by the Patch service.
    public var appKey: String
    /// Backend app UUID (used as `app_id` in the update-check wire payload).
    public var appID: String?
    /// API root. Defaults to the production Patch API
    /// (`https://api.patchrelease.com/api/v1`) when omitted, so the SDK works out of
    /// the box; set explicitly to point at a self-hosted/staging backend, or pass
    /// `nil` to disable remote update checks entirely (e.g. in tests).
    public var apiBaseURL: URL?

    /// The production Patch API the SDK targets by default (see `apiBaseURL`).
    public static let defaultAPIBaseURL = URL(string: "https://api.patchrelease.com/api/v1")
    /// Native-shell fingerprint sent in the update check.
    public var fingerprint: String?
    /// Stable anonymous device id sent in the update check + telemetry.
    public var deviceID: String?
    /// Update channel to subscribe to.
    public var channel: PatchChannel
    /// Optional app-assigned cohort label (e.g. "beta", "internal") reported on
    /// every update check. A release with `--target-cohort beta` is only served
    /// to devices whose `cohort` equals "beta"; nil → no explicit cohort (the
    /// backend derives a stable hash-bucket cohort from `deviceID`). Compose with
    /// the channel + rollout % to slice the fleet for staged releases.
    public var cohort: String?
    /// Whether the SDK may automatically apply downloaded patches.
    public var autoApply: Bool
    /// Whether to fall back to baked-in native code if no/invalid patch.
    public var nativeFallbackEnabled: Bool
    /// WASI capabilities granted to loaded modules.
    public var wasiConfig: WASIConfig

    public init(
        appKey: String,
        appID: String? = nil,
        apiBaseURL: URL? = PatchConfiguration.defaultAPIBaseURL,
        fingerprint: String? = nil,
        deviceID: String? = nil,
        channel: PatchChannel = .production,
        cohort: String? = nil,
        autoApply: Bool = true,
        nativeFallbackEnabled: Bool = true,
        wasiConfig: WASIConfig = .default
    ) {
        self.appKey = appKey
        self.appID = appID
        self.apiBaseURL = apiBaseURL
        self.fingerprint = fingerprint
        self.deviceID = deviceID
        self.channel = channel
        self.cohort = cohort
        self.autoApply = autoApply
        self.nativeFallbackEnabled = nativeFallbackEnabled
        self.wasiConfig = wasiConfig
    }

    /// Convenience initializer accepting an arbitrary **channel string** (spec
    /// §3 — channels are free-form on the backend). Equivalent to passing
    /// `channel: PatchChannel(channelName)`; the three known names map back to
    /// their presets, anything else becomes `.custom`.
    public init(
        appKey: String,
        appID: String? = nil,
        apiBaseURL: URL? = PatchConfiguration.defaultAPIBaseURL,
        fingerprint: String? = nil,
        deviceID: String? = nil,
        channelName: String,
        cohort: String? = nil,
        autoApply: Bool = true,
        nativeFallbackEnabled: Bool = true,
        wasiConfig: WASIConfig = .default
    ) {
        self.init(
            appKey: appKey, appID: appID, apiBaseURL: apiBaseURL,
            fingerprint: fingerprint, deviceID: deviceID,
            channel: PatchChannel(channelName), cohort: cohort,
            autoApply: autoApply, nativeFallbackEnabled: nativeFallbackEnabled,
            wasiConfig: wasiConfig)
    }

    /// The channel string sent on the wire (the resolved `channel.name`).
    public var channelName: String { channel.name }
}

/// Errors surfaced by the `Patch` façade.
public enum PatchError: Error, CustomStringConvertible {
    case notConfigured
    case noActiveModule
    case runtime(PatchRuntimeError)
    case marshalling(Error)

    public var description: String {
        switch self {
        case .notConfigured: return "Patch.configure(_:) must be called before use"
        case .noActiveModule: return "no active WASM module is loaded"
        case .runtime(let e): return "runtime error: \(e)"
        case .marshalling(let e): return "marshalling error: \(e)"
        }
    }
}

// MARK: - Read/Write lock
//
// Guards the active module so a hot-swap can replace it exclusively
// while concurrent reads (calls obtaining the current runtime) proceed in
// parallel. Built on `pthread_rwlock` — portable to iOS, no Foundation-only API.

final class ReadWriteLock: @unchecked Sendable {
    private var lock = pthread_rwlock_t()
    init() { pthread_rwlock_init(&lock, nil) }
    deinit { pthread_rwlock_destroy(&lock) }

    func read<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return try body()
    }
    func write<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return try body()
    }
}

// MARK: - Patch façade

public final class Patch: @unchecked Sendable {
    /// Process-wide shared instance, set by `configure`.
    public static let shared = Patch()

    /// Serial queue: all host->wasm invocations are funneled here so a single
    /// WASM instance (single-threaded by nature) is never
    /// re-entered concurrently. `call` dispatches synchronously onto it.
    private let callQueue = DispatchQueue(label: "com.patch.sdk.runtime", qos: .userInitiated)

    /// Guards `active` so hot-swap is safe while calls are in flight.
    private let lock = ReadWriteLock()

    private var configuration: PatchConfiguration?
    /// The currently-active loaded module (the DEFAULT-engine module), or nil if none
    /// loaded. For a multi-module `PMOD` container this is the FIRST sub-module; it
    /// owns the host-import surface and is the value-lift / SwiftUI-render source.
    private var active: WASMRuntime?
    /// ADDITIONAL sub-module instances from a `PMOD` container (real-source / SwiftUI
    /// additive modules). Each is an INDEPENDENT WasmKit instance with its OWN memory /
    /// allocator / `_initialize` — sound by construction (a single fused module would be
    /// multi-memory, which WasmKit can't instantiate, or would corrupt the second
    /// module's heap). A call to a function the default module doesn't export is routed
    /// to the first additional instance that does. Empty for a legacy single `.wasm`.
    private var additional: [WASMRuntime] = []

    /// Host bridges exposed to loaded modules. Apps add custom bridges here before
    /// `configure`/`start`; the defaults are installed by `configure`.
    public let bridges = BridgeRegistry()

    /// Host side of the guest↔host async round-trip. Records the tokens a guest
    /// suspends on (via the `patch_host.async_request` import) so the async pump
    /// can resolve them. Apps swap `broker.valueProvider` to plug in real host
    /// async results.
    public let asyncBroker = PatchAsyncBroker()

    /// Host side of the guest↔host networking round-trip. Records
    /// the fetches a guest suspends on (via `patch_host.http_get`/`http_request`) and
    /// resolves them through `patch_resolve_http`. Defaults to a real-`URLSession`
    /// fetch; apps/tests can replace `httpBroker` (e.g. with a mock fetch) before
    /// `configure`. Driven alongside `asyncBroker` by the async-call paths, so an
    /// async guest export that `await`s a fetch is pumped to completion.
    public var httpBroker = PatchHTTPBroker()

    /// The async pump contract (export/import names + budget) used by the
    /// async-call path. Defaults to the standard `patch_*` names; settable so the
    /// guest contract can evolve.
    public var asyncPumpContract: AsyncPumpContract {
        get { lock.read { _asyncPumpContract } }
        set { lock.write { _asyncPumpContract = newValue } }
    }
    private var _asyncPumpContract = AsyncPumpContract.default

    /// On-disk cache (current/previous/bundled). Created by `configure`.
    private var _storage: ModuleStorage?
    /// Update poller. Created by `configure` when an API base URL is set.
    private var _updateChecker: UpdateChecker?

    /// SwiftUI-observable state machine for the imperative update
    /// flow. `@MainActor` so SwiftUI views can `@ObservedObject` it directly.
    @MainActor public let updateState = PatchUpdateStateObservable()

    /// Holds the last `checkForUpdate()` response (the imperative API), so a
    /// subsequent `fetchUpdate()` knows what to download without re-checking.
    /// Guarded by `lock`.
    private var _pendingResponse: UpdateCheckResponse?
    /// Bytes fetched + verified by `fetchUpdate()`, awaiting `reloadAsync()`.
    /// Guarded by `lock`.
    private var _staged: ModuleLoader.AcquiredModule?

    init() {}

    // MARK: Configuration

    /// Configure the SDK. Call once, early in app launch.
    ///
    /// Sets up the on-disk cache, installs the 9 default bridges (custom bridges
    /// added to `Patch.shared.bridges` beforehand are preserved), and prepares
    /// the update checker when `apiBaseURL` is provided. It does NOT perform
    /// network I/O — call `start()` (async) to load the cached/bundled module via
    /// the fallback chain and optionally poll for an update.
    public static func configure(_ configuration: PatchConfiguration) {
        shared.lock.write {
            shared.configuration = configuration
            shared._storage = try? ModuleStorage(appKey: configuration.appKey)
            if let base = configuration.apiBaseURL {
                shared._updateChecker = UpdateChecker(baseURL: base)
            }
        }
        // Install the default bridges (idempotent registration is fine — apps
        // that pre-registered customs keep them; later defines win at link time).
        shared.bridges.registerDefaults()
        // Wire the async round-trip import (`patch_host.async_request`) so any
        // module that awaits HOST async work can hand the host a token; the async
        // pump resolves it via the broker. Registered as a custom host function so
        // it rides the same `activate` import-composition path as every bridge.
        shared.registerAsyncBrokerImport()
        // Wire the NETWORKING round-trip imports (`patch_host.http_get` /
        // `http_request`) so they enqueue into the FACADE's `httpBroker` — the same
        // broker the async-call paths drain in the pump's stall handler. Registered
        // AFTER `registerDefaults()` so this define (bound to the facade broker) wins
        // over the default `PatchHTTPBridge()`'s internal broker at link time.
        shared.registerHTTPBrokerImport()
    }

    /// Register the broker's `patch_host.async_request(token)` host function so
    /// every activated module exposes the guest↔host async round-trip. Idempotent
    /// at the call site (re-registering re-defines the same import; last wins).
    func registerAsyncBrokerImport() {
        let broker = self.asyncBroker
        bridges.registerFunction(
            module: PatchAsyncBroker.importModule,
            name: PatchAsyncBroker.importName,
            parameters: [.i32],
            results: []
        ) { _, args in
            broker.enqueue(token: Int32(bitPattern: args[0].i32))
            return []
        }
    }

    /// Register the networking round-trip imports (`patch_host.http_get` /
    /// `http_request`) bound to the facade's `httpBroker`, so the async-call paths'
    /// resolve drains the same requests the guest enqueued. Last define wins.
    func registerHTTPBrokerImport() {
        let broker = self.httpBroker
        bridges.registerFunction(
            module: PatchHTTPBroker.importModule, name: PatchHTTPBroker.getImportName,
            parameters: [.i32, .i32, .i32], results: []
        ) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let url = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            broker.enqueueGet(token: Int32(bitPattern: args[2].i32), url: url)
            return []
        }
        bridges.registerFunction(
            module: PatchHTTPBroker.importModule, name: PatchHTTPBroker.requestImportName,
            parameters: [.i32, .i32, .i32, .i32, .i32, .i32, .i32], results: []
        ) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let method = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let url = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            let body = try ctx.readBytes(ptr: args[4].i32, len: args[5].i32)
            broker.enqueueRequest(token: Int32(bitPattern: args[6].i32),
                                  method: method, url: url, body: body)
            return []
        }
    }

    /// The on-disk module cache, available after `configure`.
    public var storage: ModuleStorage? { lock.read { _storage } }
    /// The update checker, available after `configure` with an `apiBaseURL`.
    public var updateChecker: UpdateChecker? { lock.read { _updateChecker } }

    /// Register a module shipped inside the app bundle as the bundled fallback
    /// (the last OTA rung before "disabled"). Call after `configure`.
    public func registerBundledModule(version: String, bytes: [UInt8]) {
        lock.read { _storage }?.registerBundled(version: version, bytes: bytes)
    }

    /// Test/advanced hook: inject a pre-built storage + update checker (e.g. with
    /// a mock `HTTPTransport`) instead of the ones `configure` derives. Lets the
    /// end-to-end loader/fallback/telemetry path run with no real network.
    public func injectForTesting(configuration: PatchConfiguration, storage: ModuleStorage, checker: UpdateChecker?) {
        lock.write {
            self.configuration = configuration
            self._storage = storage
            self._updateChecker = checker
        }
    }

    /// The current configuration, if configured.
    public var currentConfiguration: PatchConfiguration? {
        lock.read { configuration }
    }

    /// Whether a module is currently loaded and active.
    public var hasActiveModule: Bool {
        lock.read { active != nil }
    }

    // MARK: Module activation

    /// Load a module from raw bytes and make it the active module. The loader
    /// calls this internally after download+verify; it is also public so apps
    /// can activate a module directly and bridges can drive it.
    public func activate(bytes: [UInt8]) throws {
        // Build the new runtime(s) OUTSIDE the write lock (instantiation is slow);
        // swap in under the exclusive lock so in-flight reads see a consistent module.
        // Calls already dispatched to callQueue serialize against each other; the lock
        // protects the active-pointer swap itself.
        let built = try instantiateModuleSet(bytes: bytes)
        lock.write {
            self.active?.teardown()
            self.additional.forEach { $0.teardown() }
            self.active = built.primary
            self.additional = built.additional
            // Drop the per-pass value cache INSIDE the swap critical section (BUG-9):
            // clearing it after releasing the lock races a concurrent value reader that
            // observed the freshly-swapped `active` but still hits a STALE cache entry
            // keyed against the OLD module, returning the wrong value.
            valueCache.clear()
        }
    }

    /// Instantiate the module-set from raw `bytes`: a single `WASMRuntime` for a legacy
    /// `.wasm`, or one PER sub-module for a `PMOD` container (the first is the primary
    /// default-engine module, the rest are additive real-source/SwiftUI instances). Each
    /// gets the SAME WASI config + host-import surface. Any sub-module failing to
    /// instantiate fails the whole activation (atomic — the caller keeps the prior set).
    private func instantiateModuleSet(bytes: [UInt8]) throws
        -> (primary: WASMRuntime, additional: [WASMRuntime]) {
        let cfg = lock.read { configuration }
        let wasi = cfg?.wasiConfig ?? .default
        let hostImports = bridges.hostImports()

        let modules: [[UInt8]] = PatchModuleContainer.decode(bytes) ?? [bytes]
        var runtimes: [WASMRuntime] = []
        runtimes.reserveCapacity(modules.count)
        do {
            for m in modules {
                runtimes.append(try WASMRuntime(bytes: m, wasiConfig: wasi, hostImports: hostImports))
            }
        } catch let e as PatchRuntimeError {
            runtimes.forEach { $0.teardown() }
            throw PatchError.runtime(e)
        } catch {
            runtimes.forEach { $0.teardown() }
            throw error
        }
        guard let primary = runtimes.first else {
            throw PatchError.runtime(.instantiationFailed("empty module set"))
        }
        return (primary, Array(runtimes.dropFirst()))
    }

    /// Atomically replace the active module with `bytes`, draining in-flight
    /// guest calls first and rolling back to the previously-active module if the
    /// new module fails to come up. Unlike `activate(bytes:)`, this guarantees:
    ///
    ///   1. **Drain / quiesce.** The swap is funneled through `callQueue`, the
    ///      same serial queue every guest call goes through. Any call already
    ///      dispatched runs to completion before the swap item executes, so the
    ///      runtime is never replaced out from under an in-flight invocation.
    ///   2. **Build-then-swap.** The new `WASMRuntime` is instantiated *before*
    ///      the live module is touched. If instantiation throws, the prior module
    ///      is still active and the call fails cleanly (nothing was swapped).
    ///   3. **Rollback on failure.** Once swapped in, the new module is probed
    ///      for usability (its memory/exports must instantiate). If the probe
    ///      throws, the previous runtime is restored under the write lock and the
    ///      error is rethrown — the app keeps running the known-good module. The
    ///      prior runtime is only torn down once the new one is proven good.
    ///
    /// On success the previous runtime is torn down and the per-pass value cache
    /// is dropped (the new module may carry different lifted values).
    public func hotSwap(bytes: [UInt8]) throws {
        // Drain in-flight calls: by running the whole swap as a `callQueue` item,
        // any guest call already on the queue completes first, and no new call
        // can interleave until the swap returns.
        try callQueue.sync {
            // (1) Build the replacement set OUTSIDE the module-state mutation. A
            // failure here leaves the active set untouched (the prior modules stay).
            let built = try instantiateModuleSet(bytes: bytes)

            // (2) Swap under the write lock, retaining the prior set so we can roll
            // back if the new primary turns out to be unusable. Do NOT tear the prior
            // ones down yet — they are our rollback target.
            let prior = lock.write { () -> (WASMRuntime?, [WASMRuntime]) in
                let p = (self.active, self.additional)
                self.active = built.primary
                self.additional = built.additional
                return p
            }

            // (3) Probe the freshly-swapped PRIMARY module. If it cannot stand up,
            // restore the prior set and rethrow so the app keeps the good module.
            func rollback(_ throwing: () -> Void) {
                built.primary.teardown()
                built.additional.forEach { $0.teardown() }
                lock.write { self.active = prior.0; self.additional = prior.1 }
                throwing()
            }
            do {
                try built.primary.assertUsable()
            } catch let e as PatchRuntimeError {
                rollback {}
                throw PatchError.runtime(e)
            } catch {
                rollback {}
                throw error
            }

            // New module set is good — retire the prior one and refresh caches.
            prior.0?.teardown()
            prior.1.forEach { $0.teardown() }
            valueCache.clear()
        }
    }

    /// Drop the active module set (e.g. on rollback).
    public func deactivate() {
        lock.write {
            self.active?.teardown()
            self.additional.forEach { $0.teardown() }
            self.active = nil
            self.additional = []
        }
    }

    // MARK: Calling into the active module

    /// Run `body` with exclusive serial access to the active runtime. Funnels
    /// onto `callQueue` (so the single-threaded WASM instance is never
    /// re-entered) and holds the read lock for the whole closure (so a
    /// concurrent hot-swap, which takes the write lock, can't free the runtime
    /// mid-call). This is the one primitive every call path goes through.
    public func withRuntime<R>(_ body: (WASMRuntime) throws -> R) throws -> R {
        try callQueue.sync {
            try lock.read {
                guard let runtime = active else { throw PatchError.noActiveModule }
                return try body(runtime)
            }
        }
    }

    /// Like `withRuntime`, but ROUTES to the sub-module instance that exports
    /// `function`: the default (primary) module if it has the export, otherwise the
    /// first additional `PMOD` instance that does. This is how a real-source/SwiftUI
    /// export — which lives in its OWN WasmKit instance (separate memory/allocator) —
    /// is actually invoked on-device. For a legacy single module this always resolves
    /// to the one active runtime (unchanged behavior). Throws `exportNotFound` if NO
    /// loaded instance exports it.
    public func withRuntime<R>(forFunction function: String,
                               _ body: (WASMRuntime) throws -> R) throws -> R {
        try callQueue.sync {
            try lock.read {
                guard let primary = active else { throw PatchError.noActiveModule }
                if primary.hasFunction(function) { return try body(primary) }
                if let alt = additional.first(where: { $0.hasFunction(function) }) {
                    return try body(alt)
                }
                throw PatchError.runtime(.exportNotFound(function))
            }
        }
    }

    /// Whether ANY loaded instance (default or an additive `PMOD` sub-module) exports
    /// `function`. Used by routing/feature checks.
    public func hasFunction(_ function: String) -> Bool {
        callQueue.sync {
            lock.read {
                guard let primary = active else { return false }
                return primary.hasFunction(function)
                    || additional.contains { $0.hasFunction(function) }
            }
        }
    }

    /// The host-side entry the generated bridge code uses to call a patched
    /// function. Invokes `function` with pre-lowered `Value` args, then hands
    /// the live runtime + results to `body` to raise a typed result on the same
    /// queue/instance.
    public func call<R>(
        _ function: String,
        _ args: [Value] = [],
        _ body: (WASMRuntime, [Value]) throws -> R
    ) throws -> R {
        try withRuntime(forFunction: function) { runtime in
            do {
                let results = try runtime.invoke(function, args)
                return try body(runtime, results)
            } catch let e as PatchRuntimeError {
                throw PatchError.runtime(e)
            }
        }
    }

    /// Convenience overload: invoke and return the raw result `Value`s.
    @discardableResult
    public func call(_ function: String, _ args: [Value] = []) throws -> [Value] {
        try call(function, args) { _, results in results }
    }

    /// The canonical **structured-blob** call shape used by the engine's
    /// auto-generated `@_cdecl` exports and by app code that talks to a module
    /// directly. The guest export has the signature
    /// `(_ ptr: i32, _ len: i32) -> i64`, where:
    ///   * the host writes `inputBytes` into guest memory and passes `(ptr, len)`,
    ///   * the guest decodes its argument blob, runs, encodes its result blob into
    ///     freshly `patch_malloc`'d guest memory, and returns the packed
    ///     `(outPtr << 32) | outLen` as an i64.
    /// The host unpacks that, reads the output bytes, frees both buffers, and
    /// returns the raw output blob. The codec of the blob (JSON / MessagePack) is
    /// the caller's concern — this primitive only moves opaque bytes across the
    /// boundary using the proven (ptr,len)+packed-i64 ABI.
    ///
    /// This is the one host primitive every generated structured call goes
    /// through; it runs under the same serial queue + read lock as `withRuntime`,
    /// so it is hot-swap-safe.
    public func callPacked(_ function: String, _ inputBytes: [UInt8]) throws -> [UInt8] {
        try withRuntime(forFunction: function) { runtime in
            do {
                let (inPtr, inLen) = try runtime.writeBuffer(inputBytes)
                // Free the INPUT buffer no matter how we leave this scope. The old
                // code freed it only on the happy path, so a guest trap during
                // `invoke`, an unexpected result shape, or an out-of-bounds packed
                // (ptr,len) from a buggy guest leaked the input buffer in guest
                // linear memory — repeated failing calls exhausted guest memory.
                defer { runtime.free(inPtr) }
                let results = try runtime.invoke(function, [.i32(inPtr), .i32(inLen)])
                guard let first = results.first, case .i64(let packed) = first else {
                    throw PatchRuntimeError.unexpectedResults(
                        function: function, got: results.count, expected: "1 i64 (packed ptr,len)")
                }
                let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
                let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
                let outBytes = try runtime.read(ptr: outPtr, len: outLen)
                runtime.free(outPtr)
                return outBytes
            } catch let e as PatchRuntimeError {
                throw PatchError.runtime(e)
            }
        }
    }

    // MARK: - Async exports (the on-device executor pump)
    //
    // A guest export that kicks off a `Task {...}` (an `async`/await body, an
    // `async let`, a `TaskGroup`, an actor hop, or a host-awaiting body) does NOT
    // run on its own under WasmKit — there is no event loop. These methods DRIVE
    // the guest's cooperative executor to completion: they install the executor
    // hook, invoke the kickoff export, then PUMP the guest's queued jobs
    // (`patch_pump` → `swift_job_run`) until the top-level Task signals done,
    // resolving any host-async continuations through `asyncBroker` in between.
    // All of this runs under the same serial call queue + read lock as every other
    // call, so it is hot-swap-safe and never re-enters the single-threaded module.

    /// Whether the active module exposes the async pump contract.
    public func activeModuleSupportsAsync() -> Bool {
        (try? withRuntime { $0.supportsAsyncPump(self.asyncPumpContract) }) ?? false
    }

    /// Invoke a kickoff export that starts an async `Task` in the guest, then pump
    /// the guest executor to completion (resolving host-async continuations via
    /// `asyncBroker`). The kickoff export is the generated
    /// `patch_start_<fn>(args…)`-style entry that enqueues — but does not run — a
    /// top-level Task. Returns the number of pump rounds it took.
    ///
    /// The executor pump runs through `withRuntime` (the serial queue + read
    /// lock) so it is hot-swap-safe. After it returns, read
    /// the guest result via the module's result export (e.g. `patch_result`) using
    /// `call(...)`, or use `callAsyncResult` which does both.
    @discardableResult
    public func runAsync(start function: String, _ args: [Value] = []) throws -> Int {
        let contract = self.asyncPumpContract
        let broker = self.asyncBroker
        let httpBroker = self.httpBroker
        // Route to the instance that EXPORTS the kickoff (mirrors the sync
        // `callPacked` path). In a PMOD multi-module container the async export can
        // live in an additive instance; pumping the PRIMARY (the old `withRuntime`)
        // would throw `exportNotFound` AND the broker would resolve the fetch into
        // the WRONG instance's memory. `withRuntime(forFunction:)` makes `runtime`
        // the correct instance for kickoff + pump + host-resolve alike.
        return try withRuntime(forFunction: function) { runtime in
            do {
                _ = broker.drain()                       // clear any stale owed work
                _ = httpBroker.drain()
                try runtime.installAsyncExecutor(contract)
                _ = try runtime.invoke(function, args)   // enqueue the top-level Task
                return try runtime.pumpToCompletion(
                    contract: contract,
                    hostResolve: combinedResolve(async: broker, http: httpBroker, contract: contract))
            } catch let e as PatchRuntimeError {
                throw PatchError.runtime(e)
            } catch let e as AsyncPumpError {
                throw PatchError.runtime(.trap("async pump: \(e)"))
            }
        }
    }

    /// `runAsync` + read a single scalar result export. The common shape:
    /// kick off `patch_start_<fn>`, pump to completion, then read `resultExport`
    /// (default `patch_result`) as an `i32`.
    @discardableResult
    public func callAsyncResult(
        start function: String,
        _ args: [Value] = [],
        resultExport: String = "patch_result"
    ) throws -> Int32 {
        let contract = self.asyncPumpContract
        let broker = self.asyncBroker
        let httpBroker = self.httpBroker
        // Route to the kickoff export's instance (see `runAsync`): the pump and
        // the host-resolve must target the SAME instance the Task runs in.
        return try withRuntime(forFunction: function) { runtime in
            do {
                _ = broker.drain()
                _ = httpBroker.drain()
                try runtime.installAsyncExecutor(contract)
                _ = try runtime.invoke(function, args)
                _ = try runtime.pumpToCompletion(
                    contract: contract,
                    hostResolve: combinedResolve(async: broker, http: httpBroker, contract: contract))
                let r = try runtime.invoke(resultExport)
                guard let first = r.first else { return 0 }
                return Int32(bitPattern: first.i32)
            } catch let e as PatchRuntimeError {
                throw PatchError.runtime(e)
            } catch let e as AsyncPumpError {
                throw PatchError.runtime(.trap("async pump: \(e)"))
            }
        }
    }

    /// The structured-blob async call: kick off an async export that takes an
    /// input blob via the proven `(ptr,len)` ABI, pump it to completion, then read
    /// the packed `(outPtr<<32)|outLen` result the export returns. For an async
    /// `view_body`/`dispatch`-shaped export whose body awaits host work before
    /// emitting its JSON result.
    ///
    /// The kickoff export must accept `(ptr: i32, len: i32)` and itself enqueue
    /// the Task; the RESULT is read from `resultExport` which returns the packed
    /// i64 once the Task is done. (If the module instead returns the packed result
    /// directly and is synchronous, use `callPacked`.)
    public func callPackedAsync(
        _ function: String,
        _ inputBytes: [UInt8],
        resultExport: String
    ) throws -> [UInt8] {
        let contract = self.asyncPumpContract
        let broker = self.asyncBroker
        let httpBroker = self.httpBroker
        // Route to the kickoff export's instance (see `runAsync`): the pump and
        // the host-resolve must target the SAME instance the Task runs in.
        return try withRuntime(forFunction: function) { runtime in
            do {
                _ = broker.drain()
                _ = httpBroker.drain()
                try runtime.installAsyncExecutor(contract)
                let (inPtr, inLen) = try runtime.writeBuffer(inputBytes)
                defer { runtime.free(inPtr) }
                _ = try runtime.invoke(function, [.i32(inPtr), .i32(inLen)])
                _ = try runtime.pumpToCompletion(
                    contract: contract,
                    hostResolve: combinedResolve(async: broker, http: httpBroker, contract: contract))
                let results = try runtime.invoke(resultExport)
                guard let first = results.first, case .i64(let packed) = first else {
                    throw PatchRuntimeError.unexpectedResults(
                        function: resultExport, got: results.count, expected: "1 i64 (packed ptr,len)")
                }
                let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
                let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
                let outBytes = try runtime.read(ptr: outPtr, len: outLen)
                runtime.free(outPtr)
                return outBytes
            } catch let e as PatchRuntimeError {
                throw PatchError.runtime(e)
            } catch let e as AsyncPumpError {
                throw PatchError.runtime(.trap("async pump: \(e)"))
            }
        }
    }

    /// Typed convenience over `callPacked` using **JSON** as the structured codec
    /// (the canonical codec the engine emits on the guest side — Foundation's
    /// `JSONEncoder`/`JSONDecoder` compile to WASM, so the guest needs no extra
    /// codec source). Encodes `argument` to JSON, runs the export, decodes the
    /// JSON result blob into `R`. This is exactly what the generated `Patch.call`
    /// shim in `_bridge.swift` calls.
    public func callJSON<A: Encodable, R: Decodable>(
        _ function: String,
        _ argument: A,
        returning: R.Type
    ) throws -> R {
        let inBytes: [UInt8]
        do { inBytes = [UInt8](try JSONEncoder().encode(argument)) }
        catch { throw PatchError.marshalling(error) }
        let outBytes = try callPacked(function, inBytes)
        do { return try JSONDecoder().decode(R.self, from: Data(outBytes)) }
        catch { throw PatchError.marshalling(error) }
    }

    /// High-level typed call: lowers `argument`, invokes `function`, raises `R`.
    /// This is the single-argument convenience; multi-argument calls go through
    /// the lower-level `call(_:_:)` / marshalling APIs.
    public func call<A: WASMBridgeable, R: WASMBridgeable>(
        _ function: String,
        _ argument: A,
        returning: R.Type
    ) throws -> R {
        try withRuntime { runtime in
            let ctx = MarshalContext(runtime: runtime)
            defer { ctx.release() }
            do {
                let loweredArgs = try argument.lower(into: ctx)
                let results = try runtime.invoke(function, loweredArgs)
                var idx = 0
                return try R.raise(from: results, index: &idx, ctx: ctx)
            } catch let e as PatchRuntimeError {
                throw PatchError.runtime(e)
            } catch let e as MarshalError {
                throw PatchError.marshalling(e)
            }
        }
    }

    // MARK: - High-level orchestration (loader + fallback + telemetry)

    /// Outcome of `start()` / `checkForUpdate()`.
    public enum StartOutcome: Sendable, Equatable {
        case activated(version: String)
        case fallback(FallbackManager.State)
        case noModule
    }

    /// Bring the SDK online:
    /// 1. Activate the best already-available module via the fallback chain
    ///    (cached current → previous → bundled → disabled) so the app runs OTA
    ///    code immediately, offline, without waiting on the network.
    /// 2. If an `apiBaseURL` is configured, poll for an update and, if one is
    ///    available, download + verify + activate it (replacing current), with
    ///    telemetry. Any failure leaves the already-active module untouched.
    @discardableResult
    public func start() async -> StartOutcome {
        // Phase 1 — local fallback chain (synchronous, offline-safe).
        let local = activateBestLocal()

        // Phase 2 — remote update check + auto-apply (best-effort). Startup
        // behavior is unchanged: this is the same auto-apply path that used to
        // live in the public `checkForUpdate()`; it now lives in the internal
        // `checkAndApply()` so the NEW public `checkForUpdate()` can report
        // availability without applying.
        if updateChecker != nil { await checkAndApply() }
        return local
    }

    /// Activate the best locally-available module using the fallback chain. Safe
    /// to call offline. Returns the outcome.
    @discardableResult
    public func activateBestLocal() -> StartOutcome {
        guard let storage = storage else { return .noModule }
        let fb = FallbackManager(
            storage: storage,
            activate: { [weak self] bytes in try self?.activate(bytes: bytes) },
            deactivate: { [weak self] in self?.deactivate() })
        let state = fb.activateBest()
        switch state {
        case .current(let v), .previous(let v), .bundled(let v):
            return .activated(version: v)
        case .disabled:
            return .fallback(.disabled)
        }
    }

    /// Poll the backend once and **auto-apply** an update if available. Emits
    /// download/activation/error telemetry. Returns the outcome. On a bad new
    /// module it runs the fallback chain so the app keeps working.
    ///
    /// This is the auto-apply behavior that `start()` drives. The public
    /// `checkForUpdate()` is the imperative, report-only API (see below). This
    /// stays internal so startup behavior is unchanged and the imperative API is
    /// purely additive.
    @discardableResult
    func checkAndApply() async -> StartOutcome {
        guard let cfg = currentConfiguration,
              let checker = updateChecker,
              let storage = storage,
              let appID = cfg.appID else { return .noModule }

        let device = cfg.deviceID ?? "anon"
        let req = UpdateCheckRequest(
            current_version: storage.currentVersion ?? "0.0.0",
            fingerprint: cfg.fingerprint ?? "",
            device_id: device,
            app_id: appID,
            os_version: Patch.osVersion,
            app_version: Patch.appVersion,
            sdk_version: Patch.sdkVersion,
            cohort: cfg.cohort,
            channel: cfg.channel.name)

        let response: UpdateCheckResponse
        do { response = try await checker.check(req) }
        catch {
            await checker.reportEvent(.init(app_id: appID, device_id: device,
                event_type: EventType.error.rawValue, error_message: "\(error)"))
            return .noModule
        }
        guard response.has_update, cfg.autoApply else {
            return storage.currentVersion.map { .activated(version: $0) } ?? .noModule
        }

        let loader = ModuleLoader(storage: storage)
        do {
            let result = try await loader.acquireAndActivate(response) { [weak self] bytes in
                try self?.activate(bytes: bytes)
            }
            await checker.reportEvent(.init(app_id: appID, device_id: device,
                event_type: EventType.download.rawValue, module_version: result.version))
            await checker.reportEvent(.init(app_id: appID, device_id: device,
                event_type: EventType.activation.rawValue, module_version: result.version))
            return .activated(version: result.version)
        } catch {
            // New module failed (verify/activate). Recover down the chain and
            // report the fallback so the dashboard sees the failure.
            await checker.reportEvent(.init(app_id: appID, device_id: device,
                event_type: EventType.error.rawValue,
                module_version: response.version, error_message: "\(error)"))
            let fb = FallbackManager(
                storage: storage,
                activate: { [weak self] bytes in try self?.activate(bytes: bytes) },
                deactivate: { [weak self] in self?.deactivate() })
            let state = fb.recoverFromBadCurrent()
            await checker.reportEvent(.init(app_id: appID, device_id: device,
                event_type: EventType.fallback.rawValue, module_version: storage.currentVersion))
            return .fallback(state)
        }
    }

    // MARK: - Imperative update API
    //
    // These methods give the host app explicit control over the update
    // lifecycle — check (no apply) → fetch (stage) → reload (activate) — so a
    // developer can drive an "Update available → Download now → Reload" UI. They
    // are additive: `start()` / `checkAndApply()` (auto-apply) are unchanged.
    // Each step also drives `updateState` (the `@MainActor` observable) so
    // SwiftUI can react without the developer tracking flags by hand.

    /// Errors surfaced by the imperative update API.
    public enum UpdateError: Error, CustomStringConvertible {
        case notConfigured
        case noUpdateAvailable
        case nothingStaged
        case check(Error)
        case fetch(Error)
        case activation(Error)
        public var description: String {
            switch self {
            case .notConfigured: return "Patch is not configured for remote updates (missing apiBaseURL/appID)"
            case .noUpdateAvailable: return "no update is available to fetch"
            case .nothingStaged: return "no fetched update is staged; call fetchUpdate() first"
            case .check(let e): return "update check failed: \(e)"
            case .fetch(let e): return "update fetch failed: \(e)"
            case .activation(let e): return "update activation failed: \(e)"
            }
        }
    }

    /// Build the `/modules/check` request from the current configuration + cache.
    private func makeCheckRequest() -> (UpdateCheckRequest, cfg: PatchConfiguration, checker: UpdateChecker, appID: String, device: String)? {
        guard let cfg = currentConfiguration,
              let checker = updateChecker,
              let storage = storage,
              let appID = cfg.appID else { return nil }
        let device = cfg.deviceID ?? "anon"
        let req = UpdateCheckRequest(
            current_version: storage.currentVersion ?? "0.0.0",
            fingerprint: cfg.fingerprint ?? "",
            device_id: device,
            app_id: appID,
            os_version: Patch.osVersion,
            app_version: Patch.appVersion,
            sdk_version: Patch.sdkVersion,
            cohort: cfg.cohort,
            channel: cfg.channel.name)
        return (req, cfg, checker, appID, device)
    }

    private func setState(_ s: PatchUpdateState) async {
        await MainActor.run { self.updateState.set(s) }
    }

    /// Check the backend for an available update **without applying it**.
    /// Returns an `UpdateInfo`
    /// describing the available update (including `isMandatory`), or `nil` when
    /// already up to date. The response is remembered so a subsequent
    /// `fetchUpdate()` can download it. Drives `updateState`.
    @discardableResult
    public func checkForUpdate() async throws -> UpdateInfo? {
        guard let (req, _, checker, appID, device) = makeCheckRequest() else {
            throw UpdateError.notConfigured
        }
        await setState(.checking)
        let response: UpdateCheckResponse
        do { response = try await checker.check(req) }
        catch {
            await checker.reportEvent(.init(app_id: appID, device_id: device,
                event_type: EventType.error.rawValue, error_message: "\(error)"))
            await setState(.failed("\(error)"))
            throw UpdateError.check(error)
        }

        guard let info = UpdateInfo(response: response) else {
            lock.write { self._pendingResponse = nil; self._staged = nil }
            await setState(.upToDate)
            return nil
        }
        lock.write { self._pendingResponse = response; self._staged = nil }
        await setState(.available(info))
        return info
    }

    /// Download + verify + **stage** the available update (the one reported by
    /// the most recent `checkForUpdate()`), without activating it. Returns `true`
    /// when an update was staged, `false` when there was nothing to fetch. After
    /// success the bytes are held in memory until `reloadAsync()`. Fires the
    /// `download` telemetry event. Drives `updateState`.
    @discardableResult
    public func fetchUpdate() async throws -> Bool {
        guard let cfg = currentConfiguration,
              let checker = updateChecker,
              let storage = storage,
              let appID = cfg.appID else { throw UpdateError.notConfigured }
        let device = cfg.deviceID ?? "anon"

        // Use the remembered response, or check now if none.
        var response = lock.read { _pendingResponse }
        if response == nil {
            _ = try await checkForUpdate()
            response = lock.read { _pendingResponse }
        }
        guard let response, response.has_update else { return false }

        await setState(.downloading(0))
        let loader = ModuleLoader(storage: storage)
        let acquired: ModuleLoader.AcquiredModule
        do { acquired = try await loader.acquire(response) }
        catch {
            await checker.reportEvent(.init(app_id: appID, device_id: device,
                event_type: EventType.error.rawValue,
                module_version: response.version, error_message: "\(error)"))
            await setState(.failed("\(error)"))
            throw UpdateError.fetch(error)
        }
        lock.write { self._staged = acquired }
        await checker.reportEvent(.init(app_id: appID, device_id: device,
            event_type: EventType.download.rawValue, module_version: acquired.version))
        await setState(.downloading(1))
        await setState(.readyToReload)
        return true
    }

    /// Activate the staged update **now** (hot-swap).
    /// Activates the bytes fetched by `fetchUpdate()`,
    /// caches them as the new current on success, and fires the `activation`
    /// telemetry event. Throws `nothingStaged` if no update was fetched. On an
    /// activation failure it reports `error`, runs the fallback chain so the app
    /// keeps working, and rethrows. Drives `updateState`.
    public func reloadAsync() async throws {
        guard let storage = storage else { throw UpdateError.notConfigured }
        guard let staged = lock.read({ _staged }) else { throw UpdateError.nothingStaged }
        let cfg = currentConfiguration
        let appID = cfg?.appID
        let device = cfg?.deviceID ?? "anon"
        let checker = updateChecker

        do {
            try activate(bytes: staged.bytes)
        } catch {
            if let appID, let checker {
                await checker.reportEvent(.init(app_id: appID, device_id: device,
                    event_type: EventType.error.rawValue,
                    module_version: staged.version, error_message: "\(error)"))
            }
            // The STAGED bytes failed to activate, but they were never installed
            // as `current` — the on-disk current slot is still the good module
            // that was running before this reload. Re-activate the best available
            // local module (current → previous → bundled → disabled) so the app
            // keeps running the GOOD current. Using `recoverFromBadCurrent()` here
            // would be wrong: it demotes/discards the still-good current and
            // needlessly downgrades to `previous` (or bundled/disabled) even
            // though nothing bad was ever installed.
            let fb = FallbackManager(
                storage: storage,
                activate: { [weak self] bytes in try self?.activate(bytes: bytes) },
                deactivate: { [weak self] in self?.deactivate() })
            _ = fb.activateBest()
            if let appID, let checker {
                await checker.reportEvent(.init(app_id: appID, device_id: device,
                    event_type: EventType.fallback.rawValue, module_version: storage.currentVersion))
            }
            lock.write { self._staged = nil }
            await setState(.failed("\(error)"))
            throw UpdateError.activation(error)
        }
        // Activation succeeded — persist as the new current and clear staging.
        try? storage.installCurrent(version: staged.version, sha256: staged.sha256, bytes: staged.bytes)
        lock.write { self._staged = nil; self._pendingResponse = nil }
        if let appID, let checker {
            await checker.reportEvent(.init(app_id: appID, device_id: device,
                event_type: EventType.activation.rawValue, module_version: staged.version))
        }
        await setState(.idle)
    }

    /// If the available update is **mandatory** (per `response.mandatory`), fetch
    /// and reload it automatically. The decision to block UI stays with the
    /// developer; this convenience just performs the forced upgrade. No-op when
    /// there is no update or it is optional. Best-effort: any failure is left in
    /// `updateState` (`.failed`) — it never throws, so it is safe to fire on
    /// launch without a do/catch.
    public func enforceMandatoryUpdates() async {
        do {
            guard let info = try await checkForUpdate(), info.isMandatory else { return }
            guard try await fetchUpdate() else { return }
            try await reloadAsync()
        } catch {
            // Already surfaced on `updateState` by the failing step.
        }
    }

    /// The SDK version reported in the update-check payload (`sdk_version`).
    public static let sdkVersion = "1.0.0"

    // MARK: - Release-targeting client facts (os_version / app_version)
    //
    // The backend's `update_check` filters a candidate release by its
    // `min_app_version` / `max_app_version` / `min_os_version` (numeric semver).
    // For that targeting to take effect the SDK must send the device OS version
    // and the host app's marketing version on every check; when these are nil the
    // backend fails open (no version filtering). These are stable for the process
    // lifetime, so we compute them once and reuse them at both check sites.

    /// The device OS version (e.g. "17.4"), sent as `os_version`. On Apple UI
    /// platforms this is `UIDevice.current.systemVersion`; elsewhere (macOS /
    /// Linux, including the SDK's own test build) it falls back to
    /// `ProcessInfo.operatingSystemVersion` formatted "major.minor.patch". Never
    /// crashes; the value is non-empty on every supported host.
    static let osVersion: String = {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }()

    /// The host app's marketing version (`CFBundleShortVersionString`), sent as
    /// `app_version`. Nil-safe: `nil` when there is no main-bundle Info.plist
    /// entry (e.g. a unit-test or CLI host), which leaves app-version targeting
    /// fail-open exactly as before.
    static let appVersion: String? =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    // MARK: - SwiftUI value-lift resolution (P1)
    //
    // A lifted SwiftUI value member (a design token / label / value helper) is
    // compiled into the WASM module as `_pv_<Type>_<member>` and read by the
    // native shell's generated getter shim through `Patch.value(key)` /
    // `Patch.call(key, args)`. The shim passes a dotted key (`ProfileCard.greeting`)
    // which this layer maps to the export symbol and dispatches over the same
    // JSON (ptr,len) ABI the rest of the engine uses. CGFloat tokens cross as
    // Double and are wrapped back to CGFloat at the (native) shim use site, so no
    // CGFloat-specific marshalling lives here — the value rides as a Double.
    //
    // A per-pass cache memoizes results so SwiftUI re-renders (which re-read each
    // token on every diff) don't re-enter WASM on every pass. `beginValuePass()`
    // clears it; the SDK clears it automatically when a hot-swap activates a new
    // module so a freshly pushed value takes effect.

    /// Memoizes `Patch.value`/`Patch.call` results within one body pass. Keyed by
    /// the value key plus a digest of the encoded args (no-arg values key on the
    /// key alone). Guarded by its own lock; cleared on `beginValuePass` / activate.
    private let valueCache = ValueCache()

    /// Map a dotted value key (`ProfileCard.primaryFontSize`) to its WASM export
    /// symbol (`_pv_ProfileCard_primaryFontSize`).
    static func valueExportSymbol(for key: String) -> String {
        "_pv_" + key.replacingOccurrences(of: ".", with: "_")
    }

    /// Begin a new SwiftUI body pass: drop the per-pass value cache so the next
    /// reads re-enter the module. Call once per render pass if you want each pass
    /// to observe a value change mid-flight; otherwise the cache is cleared on
    /// module activation, which is the common OTA case.
    public func beginValuePass() { valueCache.clear() }

    /// Resolve a **no-input** lifted SwiftUI value (`Patch.value`). Encodes an
    /// empty args envelope, invokes `_pv_<key>`, decodes the JSON `{ "value": … }`
    /// result into `R`, and caches it for the pass. `R` is the generated `_Out`
    /// envelope; the shim reads `.value`.
    public func valueJSON<R: Decodable>(_ key: String, returning: R.Type) throws -> R {
        if let cached: R = valueCache.get(key: key, argsDigest: nil) { return cached }
        let symbol = Patch.valueExportSymbol(for: key)
        // No-input export still reads a (possibly empty) buffer; send "{}".
        let outBytes = try callPacked(symbol, [UInt8]("{}".utf8))
        let value: R
        do { value = try JSONDecoder().decode(R.self, from: Data(outBytes)) }
        catch { throw PatchError.marshalling(error) }
        valueCache.set(key: key, argsDigest: nil, value: value)
        return value
    }

    /// Resolve a lifted SwiftUI value **helper with inputs** (`Patch.call`).
    /// Encodes `argument` to JSON, invokes `_pv_<key>`, decodes the JSON result.
    /// Cached per pass keyed by the key + the encoded-args bytes.
    public func callValueJSON<A: Encodable, R: Decodable>(
        _ key: String, _ argument: A, returning: R.Type
    ) throws -> R {
        let inBytes: [UInt8]
        do { inBytes = [UInt8](try JSONEncoder().encode(argument)) }
        catch { throw PatchError.marshalling(error) }
        let digest = ValueCache.digest(inBytes)
        if let cached: R = valueCache.get(key: key, argsDigest: digest) { return cached }
        let symbol = Patch.valueExportSymbol(for: key)
        let outBytes = try callPacked(symbol, inBytes)
        let value: R
        do { value = try JSONDecoder().decode(R.self, from: Data(outBytes)) }
        catch { throw PatchError.marshalling(error) }
        valueCache.set(key: key, argsDigest: digest, value: value)
        return value
    }
}

/// A small, thread-safe per-pass cache for lifted SwiftUI values. Stores the
/// raw decoded `Decodable` boxed as `Any`; the caller re-checks the type via the
/// generic `get`. Cleared per body pass and on module activation.
final class ValueCache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Any] = [:]

    /// A stable, cheap digest of encoded args (FNV-1a over the bytes).
    static func digest(_ bytes: [UInt8]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    private func compositeKey(_ key: String, _ argsDigest: String?) -> String {
        argsDigest.map { "\(key)#\($0)" } ?? key
    }

    func get<R>(key: String, argsDigest: String?) -> R? {
        lock.lock(); defer { lock.unlock() }
        return store[compositeKey(key, argsDigest)] as? R
    }

    func set<R>(key: String, argsDigest: String?, value: R) {
        lock.lock(); defer { lock.unlock() }
        store[compositeKey(key, argsDigest)] = value
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll(keepingCapacity: true)
    }
}
