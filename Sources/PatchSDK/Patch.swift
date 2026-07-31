// SPDX-License-Identifier: MIT

import Foundation
import WasmKit
import PatchHostBridge
// (No UIKit import: the only former UIKit use here — `UIDevice.current.systemVersion`
// for `os_version` — was replaced by the nonisolated `ProcessInfo` equivalent to
// satisfy Swift 6 strict concurrency. See `osVersion` below.)

// Patch — the public entry point of the on-device OTA SDK.
//
// Day-2 (Agent D1) implements: configuration, the runtime/marshalling core, the
// thread-safety foundation (serial call queue + a read/write lock guarding the
// active module so hot-swap is safe while calls are in flight), and `Patch.call`
// against an already-loaded module. The loader (download/verify/cache), native
// fallback, hot-swap activation, and generated bridges are Days 3–6 and are
// marked `// TODO(Day N)` below.

// MARK: - Configuration

/// Which update stream this app pulls patches from.
///
/// The three presets (`production` / `staging` / `development`) are conveniences;
/// `custom("…")` carries an arbitrary backend channel string (channels are
/// free-form on the backend — see spec §3). `name` is what goes on the wire.
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
    /// Optional — when nil the SDK mints and persists one (`PatchDeviceIDStore`).
    public var deviceID: String?
    /// App-group identifier (e.g. `"group.com.example.app"`) used to SHARE the
    /// auto-generated `deviceID` between the host app and its extensions.
    ///
    /// An extension has its own `UserDefaults` domain, so without this each
    /// widget/share/notification extension mints a separate id — counting one
    /// user as several devices against the plan cap and against billing, and
    /// splitting the rollout bucket so an extension can run a different patch
    /// version than its host. Set the same value in every target that calls
    /// `Patch.configure`. Ignored when `deviceID` is set explicitly.
    public var appGroupIdentifier: String?
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
        appGroupIdentifier: String? = nil,
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
        self.appGroupIdentifier = appGroupIdentifier
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
        appGroupIdentifier: String? = nil,
        channelName: String,
        cohort: String? = nil,
        autoApply: Bool = true,
        nativeFallbackEnabled: Bool = true,
        wasiConfig: WASIConfig = .default
    ) {
        self.init(
            appKey: appKey, appID: appID, apiBaseURL: apiBaseURL,
            fingerprint: fingerprint, deviceID: deviceID,
            appGroupIdentifier: appGroupIdentifier,
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
// Guards the active module so a hot-swap (Day 3+) can replace it exclusively
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
    /// WASM instance (single-threaded by nature — see COMPATIBILITY.md) is never
    /// re-entered concurrently. `call` dispatches synchronously onto it.
    private let callQueue = DispatchQueue(label: "com.patch.sdk.runtime", qos: .userInitiated)

    /// Serial queue that makes a whole `activate()` (instantiate + swap + host-bridge
    /// refresh + notify) ATOMIC against another concurrent `activate()` (bug R2-#135).
    /// Two unguarded activations — e.g. `start()` Phase 2's `checkAndApply` and a user
    /// 'reload' button's `activateOffMain` — each swap `active` atomically under `lock`,
    /// but then call `refreshHostBridgeForActiveModuleSet()` OFF the lock; without this
    /// serialization their handle-removeAll / manifest-load / registrar steps interleave,
    /// leaving the host-bridge manifest bound to a DIFFERENT module than `active`. It is
    /// deliberately NOT `callQueue`: the refresh re-enters `callQueue` (via
    /// `hasFunction`/`callPacked`), so running it on `callQueue` would deadlock.
    private let activationQueue = DispatchQueue(label: "com.patch.sdk.activation", qos: .userInitiated)

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

    /// The active resource overlay (Phase 1b) — named color/string/image overrides
    /// extracted from the patch artifact's outer `POVR` wrapper, mirroring the active
    /// module set. Set on `activate`/`hotSwap`, restored on rollback, cleared on
    /// `deactivate`. The on-device redirection (`ResourceOverlayRedirect.shared`) reads
    /// the same value through its own copy; this field is the SDK's source of truth so
    /// a hot-swap rollback can restore the PRIOR overlay in lock-step with the module
    /// set. Guarded by `lock`. Nil when the active artifact carries no overlay.
    private var _activeOverlay: PatchResourceOverlay.Table?

    /// Monotonic counter, incremented under `lock` every time the ACTIVE MODULE SET
    /// changes (activate / hot-swap commit / hot-swap rollback / deactivate). Cheap to
    /// read; the SwiftUI view-patching registry compares it per body evaluation to
    /// know when its cached per-module state (the view manifest) is stale, instead of
    /// re-querying the module. Guarded by `lock`.
    private var _moduleEpoch: UInt64 = 0
    /// Handlers fired ON THE MAIN QUEUE after the active module set changes. Used by
    /// the SwiftUI view-patching layer to invalidate on-screen views when a patch
    /// activates mid-session. Handlers MUST NOT assume any particular module is still
    /// active (read state through the normal accessors). Guarded by `lock`.
    private var _moduleChangeHandlers: [@Sendable (UInt64) -> Void] = []
    /// One-shot guard for `ensureLocalActivationOnce()` (also set by
    /// `activateBestLocal()` so the lazy path never re-runs the chain after `start()`).
    /// Guarded by `lock`.
    private var _localActivationAttempted = false

    /// TEST-ONLY: fired at the start of `instantiateModuleSet` (the CPU-heavy module
    /// decode/instantiate) so a test can assert on which thread the activation runs —
    /// the regression guard that `start()`'s Phase-1 activation does NOT block the
    /// calling (main) thread for a large module (adversarial review #17). Never set in
    /// production.
    var _onInstantiateForTesting: (@Sendable () -> Void)?

    // MARK: - Cold-start pre-warm (W5a/W5b)
    //
    // The SDK pre-warms two things immediately after a module activates on the
    // `activationQueue` background queue (before the main-queue notification fires):
    //
    //   W5b — manifest cache: the `patch_view_manifest` WASM export is called ONCE
    //         here and its JSON bytes are cached under `_cachedManifestBytes`.
    //         `PatchViewPatchRegistry.syncWithModuleEpoch` reads the cache instead of
    //         calling `callPacked` from inside a SwiftUI body eval (main thread), so
    //         the first-body-eval WASM call for the manifest disappears.
    //
    //   W5a — view-body handle warmup: every `view_body__*` export in the manifest
    //         is invoked once with a minimal `{}` input (result discarded). WasmKit
    //         memoizes export-handle lookups after the first resolve, so the first
    //         real per-view SwiftUI body eval (which used to pay 10-30ms the first
    //         time it asked for the export handle) sees a warm cache. Both W5a and
    //         W5b run on the already-background `activationQueue` before `notify`
    //         fires, so the SwiftUI tree never experiences them on the main thread.
    //
    // Safety: the pre-warm invocation uses `{}` as input; the WASM body may return
    // an error-shaped emission or a trivial tree — that's fine, the result is
    // discarded. The real body is always called again with live inputs. A pre-warm
    // failure (trap / missing export) is silently ignored so an unrecognized module
    // shape never crashes launch. The cached manifest bytes are cleared alongside the
    // epoch on every module-set change (activate / hotSwap / deactivate).

    /// W5b — the cached `patch_view_manifest` bytes from the most recently activated
    /// module. Nil when no module is active or the manifest export is absent.
    /// Populated on the activationQueue in `activate()`/`hotSwap()` BEFORE
    /// `notifyModuleSetChanged` fires on main, so the first SwiftUI body eval's
    /// `syncWithModuleEpoch` → `loadManifestEntries` reads the pre-loaded bytes
    /// instead of making a blocking `callPacked` from the main thread. Guarded by
    /// `lock`.
    private var _cachedManifestBytes: [UInt8]?

    /// Read the cached manifest bytes (W5b). Returns nil when not yet loaded or
    /// no module is active. Call from any thread (guarded by `lock`).
    /// Used by `PatchSwiftUI.PatchViewPatchRegistry.loadManifestEntries` to avoid
    /// a synchronous WASM call on the first SwiftUI body eval (main thread).
    public func cachedManifestBytes() -> [UInt8]? {
        lock.read { _cachedManifestBytes }
    }

    /// Minimal Decodable mirror of `PatchViewManifest` (defined in `PatchSwiftUI`)
    /// used ONLY by the pre-warm path in `PatchSDK`. We need just enough to
    /// enumerate the `thunkSafe` view body export names without importing `PatchSwiftUI`
    /// (which would create a circular dependency or require a separate target split).
    private struct _ManifestForPrewarm: Decodable {
        struct Entry: Decodable {
            let export: String
            let thunkSafe: Bool
        }
        let views: [Entry]
    }

    /// The well-known WASM export name for the view manifest (mirrors
    /// `PatchViewManifest.exportName` in `PatchSwiftUI` — kept in sync by
    /// the split-repo resync step).
    private static let _viewManifestExportName = "patch_view_manifest"

    /// W5a + W5b implementation: load the view manifest and pre-warm each
    /// `view_body__*` export. Called on the `activationQueue` (background) in both
    /// `activate()` and the hotSwap commit path, BEFORE `notifyModuleSetChanged`
    /// fires on main. Errors/traps from pre-warm invocations are silently discarded
    /// (the real body call will surface any real failure via the demote path).
    private func prewarmViewBodyExports() {
        // W5b: load and cache the manifest bytes.
        let manifestBytes: [UInt8]?
        if hasFunction(Self._viewManifestExportName),
           let bytes = try? callPacked(Self._viewManifestExportName, []) {
            manifestBytes = bytes
        } else {
            manifestBytes = nil
        }
        lock.write { _cachedManifestBytes = manifestBytes }

        // W5a: decode the manifest to get export names, then warm each export.
        guard let mb = manifestBytes,
              let manifest = try? JSONDecoder().decode(_ManifestForPrewarm.self,
                                                       from: Data(mb)) else { return }
        let emptyInput = [UInt8]("{}".utf8)
        for entry in manifest.views where entry.thunkSafe {
            // Invoke once and discard. WasmKit caches the export handle after this
            // first resolution so the real body eval won't pay the lookup cost.
            _ = try? callPacked(entry.export, emptyInput)
        }
    }

    /// The current module-set epoch (see `_moduleEpoch`). 0 ⇒ nothing was ever
    /// activated or deactivated in this process.
    public var moduleEpoch: UInt64 { lock.read { _moduleEpoch } }

    /// Register a handler fired on the MAIN queue whenever the active module set
    /// changes (activation, hot-swap, rollback, deactivation), with the new epoch.
    /// Handlers are held for the process lifetime — register once per subsystem.
    public func onModuleSetChange(_ handler: @escaping @Sendable (UInt64) -> Void) {
        lock.write { _moduleChangeHandlers.append(handler) }
    }

    /// Bump the epoch (must be called INSIDE a `lock.write` that mutates the module
    /// set) — returns the new value for the post-release notification.
    private func bumpModuleEpochLocked() -> UInt64 {
        _moduleEpoch &+= 1
        return _moduleEpoch
    }

    /// Fire the module-set-change handlers on the main queue (call AFTER releasing
    /// `lock`/`callQueue` so a handler can safely read SDK state).
    private func notifyModuleSetChanged(_ epoch: UInt64) {
        let handlers = lock.read { _moduleChangeHandlers }
        guard !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for h in handlers { h(epoch) }
        }
    }

    /// D3 bridges exposed to loaded modules. Apps add custom bridges here before
    /// `configure`/`start`; the defaults are installed by `configure`.
    public let bridges = BridgeRegistry()

    /// LEVER #2 — the SHARED generalized-host-bridge controller. The registry of
    /// build-time resolver thunks (the app's compiled-in `__patchRegisterHostBridges`
    /// dispatch table) + the handle table + the routed-symbol manifest for the active
    /// module set. Process-lifetime owned; its PER-EPOCH state (handles + manifest) is
    /// reset on every module-set change by `refreshHostBridgeForActiveModuleSet()`,
    /// torn down fully on `deactivate`. The three generic `patch_host.*` imports
    /// (call/release/have) are wired onto every instantiated module via
    /// `composedHostImports()` (see `HostBridgeActivation.swift`). A module that ships
    /// no generic-bridge sub-module just leaves these imports defined-but-unused —
    /// additive, demote-safe.
    public let hostBridge = PatchHostBridge()
    /// The app's generated host-bridge registration closure, installed once via
    /// `onRegisterHostBridges(_:)` and re-run after each module-set change. Guarded
    /// by `lock`. Nil when the app registered no routed symbols (the common case for
    /// apps that don't use Lever #2 — the registry stays empty, every routed `have()`
    /// is 0, every routed call demotes).
    private var _hostBridgeRegistrar: (@Sendable (PatchHostBridge) -> Void)?

    /// Set the app's host-bridge registrar under the lock (called by
    /// `onRegisterHostBridges`).
    func setHostBridgeRegistrar(_ register: @escaping @Sendable (PatchHostBridge) -> Void) {
        lock.write { _hostBridgeRegistrar = register }
    }
    /// Read the installed app registrar under the lock (called per-epoch refresh).
    func currentHostBridgeRegistrar() -> (@Sendable (PatchHostBridge) -> Void)? {
        lock.read { _hostBridgeRegistrar }
    }

    /// Host side of the guest↔host async round-trip. Records the tokens a guest
    /// suspends on (via the `patch_host.async_request` import) so the async pump
    /// can resolve them. Apps swap `broker.valueProvider` to plug in real host
    /// async results; the default mirrors the proven `experiments/async-exec`.
    public let asyncBroker = PatchAsyncBroker()

    /// Host side of the guest↔host NETWORKING round-trip (breakthrough #6). Records
    /// the fetches a guest suspends on (via `patch_host.http_get`/`http_request`) and
    /// resolves them through `patch_resolve_http`. Defaults to a real-`URLSession`
    /// fetch; apps/tests can replace `httpBroker` (e.g. with a mock fetch) before
    /// `configure`. Driven alongside `asyncBroker` by the async-call paths, so an
    /// async guest export that `await`s a fetch is pumped to completion.
    public var httpBroker = PatchHTTPBroker()

    /// The async pump contract (export/import names + budget) used by the
    /// async-call path. Defaults to the proven `patch_*` names; settable so the
    /// engine can evolve the guest contract.
    public var asyncPumpContract: AsyncPumpContract {
        get { lock.read { _asyncPumpContract } }
        set { lock.write { _asyncPumpContract = newValue } }
    }
    private var _asyncPumpContract = AsyncPumpContract.default

    /// D2 on-disk cache (current/previous/bundled). Created by `configure`.
    private var _storage: ModuleStorage?
    /// D2 update poller. Created by `configure` when an API base URL is set.
    private var _updateChecker: UpdateChecker?

    /// SwiftUI-observable state machine for the imperative (EAS-style) update
    /// flow. `@MainActor` so SwiftUI views can `@ObservedObject` it directly.
    @MainActor public let updateState = PatchUpdateStateObservable()

    /// Holds the last `checkForUpdate()` response (W4 §5 imperative API), so a
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

    // MARK: Module activation (Day-2: direct load; Day-3: from the loader)

    /// Load a module from raw bytes and make it the active module. On Day 3 the
    /// loader will call this internally after download+verify; exposed now so the
    /// runtime/marshalling core is testable and bridges can drive it.
    public func activate(bytes: [UInt8]) throws {
        // BUG R2-#135: serialize the WHOLE activation (instantiate → swap → host-bridge
        // refresh → notify) so two concurrent `activate()` calls can't interleave their
        // off-lock `refreshHostBridgeForActiveModuleSet()` steps and leave the host-bridge
        // manifest bound to a different module than `active`. The refresh re-enters
        // `callQueue`, so this MUST be a separate serial queue (`activationQueue`).
        try activationQueue.sync {
            // Build the new runtime(s) OUTSIDE the write lock (instantiation is slow);
            // swap in under the exclusive lock so in-flight reads see a consistent module.
            // Calls already dispatched to callQueue serialize against each other; the lock
            // protects the active-pointer swap itself.
            let built = try instantiateModuleSet(bytes: bytes)
            let epoch = lock.write {
                self.active?.teardown()
                self.additional.forEach { $0.teardown() }
                self.active = built.primary
                self.additional = built.additional
                // PHASE 1b: swap the active resource overlay in lock-step with the module
                // set, so the named-lookup redirection (colors/strings/images) reflects the
                // newly-active artifact (nil overlay ⇒ no overrides, falls through to bundle).
                self._activeOverlay = built.overlay
                // Drop the per-pass value cache INSIDE the swap critical section (BUG-9):
                // clearing it after releasing the lock races a concurrent value reader that
                // observed the freshly-swapped `active` but still hits a STALE cache entry
                // keyed against the OLD module, returning the wrong value.
                valueCache.clear()
                return bumpModuleEpochLocked()
            }
            // Push the overlay to the process-wide redirection AFTER releasing the lock
            // (installing the swizzles touches the ObjC runtime; keep it off the lock).
            ResourceOverlayRedirect.shared.setActiveOverlay(built.overlay)
            // LEVER #2: reset the shared host bridge for the new module set — drop the
            // prior epoch's handles, reload this module's `patch_host_symbols` manifest,
            // and re-run the app's resolver-thunk registrar. Off the lock (it reads the
            // live runtime). No-op-cheap for a module with no routed symbols. Serialized
            // with the swap above so it always reflects THIS activation's module set.
            refreshHostBridgeForActiveModuleSet()
            // W5a/W5b: load the view manifest + pre-warm every view_body__* export
            // handle HERE on the activationQueue (background) so the first SwiftUI body
            // eval on main never makes a synchronous WASM call for either the manifest
            // or the per-view export handle.
            prewarmViewBodyExports()
            notifyModuleSetChanged(epoch)
        }
    }

    /// Instantiate the module-set from raw `bytes`: a single `WASMRuntime` for a legacy
    /// `.wasm`, or one PER sub-module for a `PMOD` container (the first is the primary
    /// default-engine module, the rest are additive real-source/SwiftUI instances). Each
    /// gets the SAME WASI config + host-import surface. Any sub-module failing to
    /// instantiate fails the whole activation (atomic — the caller keeps the prior set).
    ///
    /// PHASE 1b: the artifact may be wrapped in an outer `POVR` envelope carrying a
    /// resource overlay (named color/string/image overrides). This strips that wrapper
    /// FIRST — it returns the decoded overlay table (nil when absent / malformed) and
    /// instantiates the modules from the INNER bytes, so the WASM path is unchanged. A
    /// raw `.wasm`/`PMOD` blob (no `POVR` magic) is handled exactly as before.
    private func instantiateModuleSet(bytes: [UInt8]) throws
        -> (primary: WASMRuntime, additional: [WASMRuntime], overlay: PatchResourceOverlay.Table?) {
        lock.read { _onInstantiateForTesting }?()
        let cfg = lock.read { configuration }
        let wasi = cfg?.wasiConfig ?? .default
        // LEVER #2: layer the three generic `patch_host.*` imports (call/release/have),
        // backed by the shared `hostBridge`, on top of the curated bridges so a module
        // that routes native calls through the generalized bridge resolves them. A
        // module that doesn't just leaves them defined-but-unused (demote-safe).
        let hostImports = composedHostImports()

        // Strip the resource-overlay wrapper (if present) before any WASM decoding.
        // (The overlay CHUNK is persisted separately by `ModuleStorage.installCurrent`,
        // which extracts it from the same wrapped bytes; here we only need the decoded
        // table to drive the live redirection.)
        var overlay: PatchResourceOverlay.Table?
        let wasmBytes: [UInt8]
        if let decoded = PatchOverlayArtifact.decode(bytes) {
            wasmBytes = decoded.inner
            overlay = PatchResourceOverlay.decode(decoded.overlay)
        } else {
            wasmBytes = bytes
        }

        let modules: [[UInt8]] = PatchModuleContainer.decode(wasmBytes) ?? [wasmBytes]
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
        // Probe EVERY module's usability (it must export the linear `memory` the
        // marshalling ABI crosses through) before returning the set, so neither
        // `activate` nor `hotSwap` ever swaps in a set containing a module that
        // instantiated but can't actually participate in a call. Done here (before
        // the swap) so a bad set fails the build, leaving the prior set untouched.
        do {
            for rt in runtimes { try rt.assertUsable() }
        } catch let e as PatchRuntimeError {
            runtimes.forEach { $0.teardown() }
            throw PatchError.runtime(e)
        } catch {
            runtimes.forEach { $0.teardown() }
            throw error
        }
        return (primary, Array(runtimes.dropFirst()), overlay)
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
        // BUG R3: run the WHOLE swap + its off-callQueue bridge tail on `activationQueue`
        // so a concurrent `activate()`/`deactivate()` can't interleave their off-lock
        // `refreshHostBridgeForActiveModuleSet()`/teardown steps with this one (same
        // R2-#135 invariant). `activationQueue.sync` is NOT re-entrant here: `hotSwap()`
        // is a public API never invoked from inside `activate()`/`activationQueue`. The
        // inner `refreshHostBridgeForActiveModuleSet()` must stay OUTSIDE `callQueue`
        // (it re-enters via `callPacked`) but INSIDE `activationQueue`.
        try activationQueue.sync {
            try hotSwapBody(bytes: bytes)
        }
    }

    private func hotSwapBody(bytes: [UInt8]) throws {
        // Drain in-flight calls: by running the whole swap as a `callQueue` item,
        // any guest call already on the queue completes first, and no new call
        // can interleave until the swap returns.
        let epoch = try callQueue.sync { () -> UInt64 in
            // (1) Build the replacement set OUTSIDE the module-state mutation. A
            // failure here leaves the active set untouched (the prior modules stay).
            let built = try instantiateModuleSet(bytes: bytes)

            // (2) Swap under the write lock, retaining the prior set so we can roll
            // back if the new primary turns out to be unusable. Do NOT tear the prior
            // ones down yet — they are our rollback target. The PRIOR overlay is part
            // of the rollback snapshot too (Phase 1b), so a rollback restores the
            // named-lookup redirection to exactly what it was before the swap.
            let prior = lock.write { () -> (WASMRuntime?, [WASMRuntime], PatchResourceOverlay.Table?) in
                let p = (self.active, self.additional, self._activeOverlay)
                self.active = built.primary
                self.additional = built.additional
                self._activeOverlay = built.overlay
                return p
            }
            // Reflect the new overlay in the redirection (outside the lock).
            ResourceOverlayRedirect.shared.setActiveOverlay(built.overlay)

            // (3) Probe the freshly-swapped module set. If ANY module cannot stand up
            // (e.g. an additive PMOD sub-module that instantiated but exports no
            // `memory`, so the marshalling ABI can't cross into it), restore the prior
            // set and rethrow so the app keeps the known-good module. Probing only the
            // primary would let a broken additive sub-module swap in and fail later at
            // call time instead of rolling back here.
            func rollback(_ throwing: () -> Void) {
                built.primary.teardown()
                built.additional.forEach { $0.teardown() }
                // The restore is a module-set change too: a concurrent reader may have
                // observed the (not-yet-probed) new set, so bump + notify so any
                // per-module caches resynchronize against the restored set.
                let epoch = lock.write { () -> UInt64 in
                    self.active = prior.0
                    self.additional = prior.1
                    self._activeOverlay = prior.2
                    return bumpModuleEpochLocked()
                }
                // Restore the PRIOR overlay in the redirection (clean rollback).
                ResourceOverlayRedirect.shared.setActiveOverlay(prior.2)
                notifyModuleSetChanged(epoch)
                throwing()
            }
            do {
                try built.primary.assertUsable()
                for sub in built.additional { try sub.assertUsable() }
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
            return lock.write {
                valueCache.clear()
                return bumpModuleEpochLocked()
            }
        }
        // LEVER #2: reset the shared host bridge against the now-active NEW set —
        // OUTSIDE the `callQueue.sync` block above, because the refresh reads the live
        // module's `patch_host_symbols` export via `callPacked`, which itself funnels
        // onto `callQueue` (re-entering it from inside would deadlock). This runs only
        // on the COMMIT path: a probe-failure rollback throws out of `callQueue.sync`
        // above and never reaches here — which is correct, since a rollback restores
        // the PRIOR module whose bridge state (registry/manifest) is already loaded and
        // the failed new set never ran a call (no handles to drop).
        refreshHostBridgeForActiveModuleSet()
        // W5a/W5b: pre-warm view-body export handles + cache the manifest here (on
        // activationQueue, background) so the next SwiftUI body eval on main pays
        // neither the manifest WASM call nor the first per-export handle resolution.
        prewarmViewBodyExports()
        notifyModuleSetChanged(epoch)
    }

    /// Drop the active module set (e.g. on rollback).
    public func deactivate() {
        // CODE-REVIEW H1: serialize the ENTIRE deactivation (active-set teardown →
        // swap-to-nil → overlay clear → host-bridge teardown → notify) on
        // `activationQueue`, EXACTLY as `activate()`/`hotSwap()` do. Previously only the
        // post-lock bridge tail was on the queue while the `lock.write` teardown ran
        // OUTSIDE it — so deactivate()'s active-set mutation was NOT serialized against a
        // concurrent activate()/hotSwap() swap. Bad interleave: activate() commits
        // `active = newModule` then releases the rwlock; deactivate() (not yet on the
        // queue) immediately tears down + nils that freshly-activated module, leaving
        // `active == nil` while activate()'s off-lock refresh/notify runs against the
        // torn-down runtime (and `_activeOverlay`/the live redirection diverge → wrong
        // overlay colors/strings). Wrapping the whole body closes it. Reachable now from
        // BOTH FallbackManager's `.disabled` path AND the rollback revert directive
        // (`checkAndApply()` deactivates a recalled module) running concurrently with a
        // Phase-2 activate/hotSwap. `activationQueue.sync` stays NON-re-entrant: every
        // deactivate() caller (FallbackManager closure, checkAndApply revert) invokes it
        // from OUTSIDE the queue, never from inside `activate()`/`activationQueue`.
        activationQueue.sync {
            let epoch = lock.write { () -> UInt64 in
                self.active?.teardown()
                self.additional.forEach { $0.teardown() }
                self.active = nil
                self.additional = []
                // PHASE 1b: clear the resource overlay too, so the named-lookup
                // redirection falls all the way through to the bundle (native behavior).
                self._activeOverlay = nil
                // W5b: clear the manifest cache so a subsequent activation's registry
                // sync never reads stale bytes from the previous epoch.
                self._cachedManifestBytes = nil
                return bumpModuleEpochLocked()
            }
            ResourceOverlayRedirect.shared.setActiveOverlay(nil)
            // LEVER #2: no module is active anymore — fully tear down the shared host
            // bridge (drop every live handle + the manifest + the registry). The app's
            // registrar is preserved, so a subsequent activation re-primes the registry
            // from the same compiled-in thunks via `refreshHostBridgeForActiveModuleSet()`.
            teardownHostBridge()
            notifyModuleSetChanged(epoch)
        }
    }

    // MARK: - Resource overlay (Phase 1b) — public lookup + manual activation
    //
    // The named-lookup REDIRECTION (UIColor(named:)/UIImage(named:)/NSLocalizedString)
    // is installed automatically by swizzling when an overlay activates, so colors +
    // strings are overridden with ZERO dev work. These APIs are the documented FALLBACK
    // for the cases swizzling can't reach — chiefly SwiftUI's pure-Swift `Color(_:bundle:)`
    // initializer, which is NOT an `@objc` accessor (on UIKit platforms `Color("name")`
    // resolves through the swizzled `UIColor(named:)`, but a host can call this directly
    // to be explicit / platform-independent).

    /// The active resource overlay table, or nil when none is active.
    public var activeResourceOverlay: PatchResourceOverlay.Table? {
        lock.read { _activeOverlay }
    }

    /// Whether a resource overlay is currently active.
    public var hasResourceOverlay: Bool { lock.read { _activeOverlay != nil } }

    /// Look up an overridden color by name (the overlay's RGBA components, dark variant
    /// selected by `dark`). Returns nil when there is no override — the caller then uses
    /// the bundle color. This is the documented fallback for SwiftUI `Color("name")`.
    public func overlayColor(named name: String, dark: Bool = false) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard let c = lock.read({ _activeOverlay })?.color(named: name) else { return nil }
        let v = (dark ? c.dark : nil) ?? c.light
        return (v.r, v.g, v.b, v.a)
    }

    /// Look up an overridden localized string, resolved with locale fallback (the
    /// device's preferred locale → its language prefix → base). Returns nil when there
    /// is no override (the caller then uses the bundle string). `table` scopes to a
    /// `.strings` table name (nil/"" = the default table).
    public func overlayLocalizedString(forKey key: String, table: String? = nil, locale: String? = nil) -> String? {
        let loc = locale ?? Locale.preferredLanguages.first
        return lock.read { _activeOverlay }?.string(forKey: key, table: table, locale: loc)
    }

    /// Look up overridden image bytes by name (inline-kind overrides only). Returns nil
    /// when there is no inline override. The documented fallback for SwiftUI `Image("name")`.
    public func overlayImageBytes(named name: String) -> [UInt8]? {
        guard let img = lock.read({ _activeOverlay })?.image(named: name), img.kind == .inline else { return nil }
        return img.payload
    }

    /// Manually activate a resource overlay table (bypassing the patch artifact) —
    /// installs the named-lookup redirection from `table`, or clears it when nil. The
    /// normal path is automatic (an overlay rides the patch's `POVR` wrapper and
    /// activates with the module); this is for tests + advanced hosts that want to set
    /// an overlay directly. NOTE: this does NOT touch the module set / epoch.
    public func activateResourceOverlay(_ table: PatchResourceOverlay.Table?) {
        lock.write { _activeOverlay = (table?.isEmpty == true) ? nil : table }
        ResourceOverlayRedirect.shared.setActiveOverlay(table)
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
                // Free the OUTPUT buffer no matter how we leave this scope. A buggy
                // or hostile guest can pack an out-of-bounds (ptr,len), making the
                // `read` below throw `memoryOutOfBounds` — in which case the old
                // code never reached `free(outPtr)` and leaked the guest buffer.
                // Repeated failing calls would exhaust guest linear memory. (free
                // no-ops on outPtr==0, the "no value" encoding.)
                defer { runtime.free(outPtr) }
                let outBytes = try runtime.read(ptr: outPtr, len: outLen)
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
    /// `asyncBroker`). The kickoff export is the engine-emitted
    /// `patch_start_<fn>(args…)`-style entry that enqueues — but does not run — a
    /// top-level Task. Returns the number of pump rounds it took.
    ///
    /// This is the productized executor pump: it is exactly the
    /// `experiments/async-exec` host driver, moved into the SDK and funneled
    /// through `withRuntime` (the serial queue + read lock). After it returns, read
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
                // Free the OUTPUT buffer on every exit path (see `callPacked`): an
                // out-of-bounds packed (ptr,len) makes `read` throw, and the old
                // code leaked `outPtr` on that path.
                defer { runtime.free(outPtr) }
                let outBytes = try runtime.read(ptr: outPtr, len: outLen)
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
    /// This is the shape generated single-argument bridges will use. Multi-arg
    /// variants are generated per-signature (Day 5+).
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

    // MARK: - High-level orchestration (D2: loader + fallback + telemetry)

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
        // Phase 1 — local fallback chain (offline-safe). Instantiating the cached
        // module (`activate(bytes:)` → `instantiateModuleSet`) is CPU-heavy and
        // SYNCHRONOUS: a large full-Foundation module (the real-app case — tens of
        // MB, tens of thousands of functions + WASM data segments) takes SECONDS to
        // decode + instantiate in WasmKit. `start()` is typically awaited from a
        // `@MainActor` SwiftUI `.task {}`, so running Phase 1 INLINE would block the
        // main thread for that whole time → a multi-second launch freeze (adversarial
        // review #17). Hop the heavy work onto a background queue and suspend the
        // awaiting Task until it finishes. The main thread stays free; the first frame
        // paints native and the patched render swaps in once the module is live (the
        // small-module first-frame path is unaffected — that stays the synchronous,
        // size-gated `ensureLocalActivationOnce`, whose `8 MiB` cap is unchanged; this
        // only moves the LARGE-module activation off the caller's main thread).
        //
        // It MUST be a DIFFERENT queue from `callQueue`: `activate()` →
        // `refreshHostBridgeForActiveModuleSet()` → `hasFunction()` does `callQueue.sync`,
        // so running this on `callQueue` would dispatch_sync onto the queue we're already
        // on → deadlock (SIGTRAP). A user-initiated GLOBAL queue runs the activation
        // off-main while leaving those inner `callQueue.sync` calls free to proceed.
        let local = await withCheckedContinuation { (cont: CheckedContinuation<StartOutcome, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self.activateBestLocal())
            }
        }

        // Phase 2 — remote update check + auto-apply (best-effort). Startup
        // behavior is unchanged: this is the same auto-apply path that used to
        // live in the public `checkForUpdate()`; it now lives in the internal
        // `checkAndApply()` so the NEW public `checkForUpdate()` can report
        // availability without applying.
        if updateChecker != nil { await checkAndApply() }
        return local
    }

    /// Synchronously run the local fallback chain ONCE per process if nothing has
    /// run it yet — the first-frame path for auto-patched SwiftUI views. `start()`
    /// is async (the injected snippet wraps it in a `Task`), so the first body
    /// evaluations can land BEFORE Phase 1 activates the cached module; a patched
    /// view would then paint native for a frame (or until the next re-render on
    /// OSes without the Observation-based invalidation). Calling this from the
    /// first body evaluation closes that gap: if a cached/bundled module exists
    /// it activates before the first paint.
    ///
    /// Bounded: modules larger than `maxSyncBytes` (default 8 MiB) are left to the
    /// async `start()` so a huge full-Foundation module can't stall the first
    /// frame; SwiftUI patch modules are typically tens of KiB.
    public func ensureLocalActivationOnce(maxSyncBytes: Int = 8 << 20) {
        guard lock.read({ configuration != nil }), let storage = storage else { return }
        // BUG R2-#38: the size gate MUST be checked BEFORE claiming the one-shot
        // `_localActivationAttempted` flag. The old order test-and-SET the flag first,
        // then hit the size gate and RETURNED WITHOUT activating for a large (>8 MiB)
        // module — but `start()`'s background `activateBestLocal(markAttempted: true)`
        // then saw the flag already claimed and DEFERRED, so the large module NEVER
        // activated. By gating first, a size-gated early-return leaves the flag UNCLAIMED,
        // so `start()`'s background path still performs the (slow, off-main) activation.
        if let current = storage.manifest().current, current.size > maxSyncBytes { return }
        // Now atomically claim the one-shot attempt — only when we WILL activate.
        let shouldRun: Bool = lock.write {
            guard !_localActivationAttempted else { return false }
            _localActivationAttempted = true
            return true
        }
        guard shouldRun else { return }
        _ = activateBestLocal(markAttempted: false)
    }

    /// Activate the best locally-available module using the fallback chain. Safe
    /// to call offline. Returns the outcome.
    ///
    /// BUG #45 — concurrent double-activation race. `start()` hops Phase 1 onto a
    /// background queue calling this with `markAttempted: true`, while the first
    /// patched-view body evaluation calls `ensureLocalActivationOnce` (main thread)
    /// which test-and-sets the SAME `_localActivationAttempted` flag and calls this
    /// with `markAttempted: false`. Previously `markAttempted: true` only SET the flag
    /// (never read it) and ran `activate()` unconditionally — so both paths could run
    /// `activate()` nearly simultaneously on two threads. Now the `markAttempted: true`
    /// path ALSO does an atomic test-and-set: if the attempt was ALREADY claimed (by
    /// `ensureLocalActivationOnce` or a prior call), it does NOT re-activate — it just
    /// reports the current activation state. So exactly one path performs the activation.
    @discardableResult
    public func activateBestLocal(markAttempted: Bool = true) -> StartOutcome {
        if markAttempted {
            // Atomically claim the one-shot attempt. If someone else already claimed it
            // (the lazy first-frame path), skip activation — they are (or already did)
            // bring the module up; just report the current state. Avoids two concurrent
            // `activate()` calls racing on two threads.
            let claimed: Bool = lock.write {
                if _localActivationAttempted { return false }
                _localActivationAttempted = true
                return true
            }
            if !claimed { return currentLocalOutcome() }
        }
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

    /// The current local outcome WITHOUT (re-)activating — used when the one-shot
    /// activation attempt was already claimed by another path (bug #45). Reports the
    /// active module's version if one is up, else `.noModule`.
    private func currentLocalOutcome() -> StartOutcome {
        if let v = storage?.currentVersion { return .activated(version: v) }
        return .noModule
    }

    /// Run the synchronous, CPU-heavy `activate(bytes:)` on a background queue and
    /// suspend the awaiting Task until it finishes — so a large-module instantiate
    /// never freezes the resuming executor (the main actor for an imperative reload
    /// button). Rethrows any activation error to the caller (bug #69). It MUST be a
    /// queue OTHER than `callQueue` (whose inner `callQueue.sync`s in `activate()` →
    /// `refreshHostBridgeForActiveModuleSet()` would deadlock if re-entered).
    private func activateOffMain(bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try self.activate(bytes: bytes); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Poll the backend once and **auto-apply** an update if available. Emits
    /// download/activation/error telemetry. Returns the outcome. On a bad new
    /// module it runs the fallback chain so the app keeps working.
    ///
    /// This is the original auto-apply behavior that `start()` drives; it used to
    /// be the public `checkForUpdate()`. The public `checkForUpdate()` is now the
    /// EAS-style report-only API (see below). Kept internal so startup is
    /// identical and the imperative API is purely additive.
    @discardableResult
    func checkAndApply() async -> StartOutcome {
        // `appID` (the backend UUID) is OPTIONAL: the backend resolves `appKey`
        // server-side, so the snippet-only integration
        // (`Patch.configure(.init(appKey: …))`) polls like any other. (Guarding
        // on `appID` here used to silently disable ALL remote checks for
        // exactly that integration — the quickstart-killing bug.)
        guard let cfg = currentConfiguration,
              let checker = updateChecker,
              let storage = storage else { return .noModule }

        let device = cfg.resolvedDeviceID
        let req = UpdateCheckRequest(
            current_version: storage.currentVersion ?? "0.0.0",
            fingerprint: cfg.fingerprint ?? "",
            device_id: device,
            app_id: cfg.appID,
            app_key: cfg.appKey,
            os_version: Patch.osVersion,
            app_version: Patch.appVersion,
            sdk_version: Patch.sdkVersion,
            cohort: cfg.cohort,
            channel: cfg.channel.name)

        let response: UpdateCheckResponse
        do { response = try await checker.check(req) }
        catch {
            await checker.reportEvent(Self.event(cfg, device: device,
                type: .error, errorMessage: "\(error)"))
            return .noModule
        }

        // ROLLBACK DIRECTIVE (P0). The backend sets `revert: true` when this
        // device's cached `current_version` was ROLLED BACK and there is no
        // active replacement to move to. Without acting on it, the device would
        // keep serving the now-bad cached module forever (it only ever sees
        // `has_update: false`). DEACTIVATE the live module set (which also bumps
        // `moduleEpoch` so auto-patched SwiftUI views re-render native) AND drop
        // the cached current slot so the revert is DURABLE across relaunch — on
        // the next `start()` the local fallback chain would otherwise re-promote
        // the rolled-back `current` module. Honored regardless of `autoApply`:
        // unwinding a known-bad patch is a safety action, not an "apply".
        if response.revert {
            deactivate()
            storage.clearCurrent()
            return storage.currentVersion.map { .activated(version: $0) } ?? .noModule
        }

        guard response.has_update, cfg.autoApply else {
            return storage.currentVersion.map { .activated(version: $0) } ?? .noModule
        }

        let loader = ModuleLoader(storage: storage)
        do {
            let result = try await loader.acquireAndActivate(response) { [weak self] bytes in
                try self?.activate(bytes: bytes)
            }
            await checker.reportEvent(Self.event(cfg, device: device,
                type: .download, moduleVersion: result.version))
            await checker.reportEvent(Self.event(cfg, device: device,
                type: .activation, moduleVersion: result.version))
            return .activated(version: result.version)
        } catch {
            // New module failed (verify/activate). Recover down the chain and
            // report the fallback so the dashboard sees the failure.
            await checker.reportEvent(Self.event(cfg, device: device,
                type: .error, moduleVersion: response.version,
                errorMessage: "\(error)"))
            // The STAGED module threw inside `loader.acquireAndActivate` BEFORE
            // `installCurrent` ran (ModuleLoader.swift activates, then caches), so the
            // on-disk `current` slot still holds the GOOD prior module. Re-activate the
            // best available local module (current → previous → bundled → disabled) IN
            // PLACE — exactly as the reloadAsync path does. Using `recoverFromBadCurrent()`
            // here would be wrong: it promotes previous→current (deleting the good
            // current's bytes) and needlessly downgrades the device one version even
            // though the current was never bad. Reserve `recoverFromBadCurrent()` for a
            // module that was actually installed-as-current and later proved bad.
            let fb = FallbackManager(
                storage: storage,
                activate: { [weak self] bytes in try self?.activate(bytes: bytes) },
                deactivate: { [weak self] in self?.deactivate() })
            let state = fb.activateBest()
            await checker.reportEvent(Self.event(cfg, device: device,
                type: .fallback, moduleVersion: storage.currentVersion))
            return .fallback(state)
        }
    }

    /// Build a telemetry payload carrying BOTH app identifiers (`app_id` when
    /// configured, always `app_key`) so events resolve server-side however the
    /// SDK was configured.
    static func event(
        _ cfg: PatchConfiguration, device: String, type: EventType,
        moduleVersion: String? = nil, errorMessage: String? = nil
    ) -> DeviceEventPayload {
        DeviceEventPayload(
            app_id: cfg.appID, app_key: cfg.appKey, device_id: device,
            event_type: type.rawValue, module_version: moduleVersion,
            error_message: errorMessage)
    }

    // MARK: - Imperative EAS-Expo-Updates-style API (W4 §5)
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
            case .notConfigured: return "Patch is not configured for remote updates (missing apiBaseURL)"
            case .noUpdateAvailable: return "no update is available to fetch"
            case .nothingStaged: return "no fetched update is staged; call fetchUpdate() first"
            case .check(let e): return "update check failed: \(e)"
            case .fetch(let e): return "update fetch failed: \(e)"
            case .activation(let e): return "update activation failed: \(e)"
            }
        }
    }

    /// Build the `/modules/check` request from the current configuration + cache.
    /// `appID` is optional — `appKey` rides along and resolves server-side.
    private func makeCheckRequest() -> (UpdateCheckRequest, cfg: PatchConfiguration, checker: UpdateChecker, device: String)? {
        guard let cfg = currentConfiguration,
              let checker = updateChecker,
              let storage = storage else { return nil }
        let device = cfg.resolvedDeviceID
        let req = UpdateCheckRequest(
            current_version: storage.currentVersion ?? "0.0.0",
            fingerprint: cfg.fingerprint ?? "",
            device_id: device,
            app_id: cfg.appID,
            app_key: cfg.appKey,
            os_version: Patch.osVersion,
            app_version: Patch.appVersion,
            sdk_version: Patch.sdkVersion,
            cohort: cfg.cohort,
            channel: cfg.channel.name)
        return (req, cfg, checker, device)
    }

    private func setState(_ s: PatchUpdateState) async {
        await MainActor.run { self.updateState.set(s) }
    }

    /// Check the backend for an available update **without applying it** (the
    /// EAS-Expo-Updates `checkForUpdateAsync` shape). Returns an `UpdateInfo`
    /// describing the available update (including `isMandatory`), or `nil` when
    /// already up to date. The response is remembered so a subsequent
    /// `fetchUpdate()` can download it. Drives `updateState`.
    @discardableResult
    public func checkForUpdate() async throws -> UpdateInfo? {
        guard let (req, cfg, checker, device) = makeCheckRequest() else {
            throw UpdateError.notConfigured
        }
        await setState(.checking)
        let response: UpdateCheckResponse
        do { response = try await checker.check(req) }
        catch {
            await checker.reportEvent(Self.event(cfg, device: device,
                type: .error, errorMessage: "\(error)"))
            await setState(.failed("\(error)"))
            throw UpdateError.check(error)
        }

        // ROLLBACK DIRECTIVE: mirror the checkAndApply() revert path exactly.
        // A device on the imperative/EAS-style flow must also honor a server
        // rollback-recall — this is a safety action regardless of autoApply.
        if response.revert {
            if let s = lock.read({ _storage }) { deactivate(); s.clearCurrent() }
            lock.write { self._pendingResponse = nil; self._staged = nil }
            await setState(.upToDate)
            return nil
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
              let storage = storage else { throw UpdateError.notConfigured }
        let device = cfg.resolvedDeviceID

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
            await checker.reportEvent(Self.event(cfg, device: device,
                type: .error, moduleVersion: response.version,
                errorMessage: "\(error)"))
            await setState(.failed("\(error)"))
            throw UpdateError.fetch(error)
        }
        lock.write { self._staged = acquired }
        await checker.reportEvent(Self.event(cfg, device: device,
            type: .download, moduleVersion: acquired.version))
        await setState(.downloading(1))
        await setState(.readyToReload)
        return true
    }

    /// Activate the staged update **now** (hot-swap) — the EAS-Expo-Updates
    /// `reloadAsync` shape. Activates the bytes fetched by `fetchUpdate()`,
    /// caches them as the new current on success, and fires the `activation`
    /// telemetry event. Throws `nothingStaged` if no update was fetched. On an
    /// activation failure it reports `error`, runs the fallback chain so the app
    /// keeps working, and rethrows. Drives `updateState`.
    public func reloadAsync() async throws {
        guard let storage = storage else { throw UpdateError.notConfigured }
        // BUG R2-#136: ATOMICALLY CLAIM `_staged` (read-and-nil under one lock.write) so
        // two concurrent `reloadAsync()` calls (e.g. a 'Reload now' button +
        // `enforceMandatoryUpdates`) can't both read the same staged bytes and activate
        // them TWICE — which double-instantiated the module, double-bumped the epoch,
        // double-notified module-set change, and emitted duplicate 'activation' telemetry
        // (the second activation needlessly tearing down + re-instantiating the just-
        // activated module). The loser now sees nil and throws `.nothingStaged`. `_staged`
        // is left nil on every path (success AND failure), matching the prior semantics
        // (the original cleared it in both branches).
        guard let staged = (lock.write { () -> ModuleLoader.AcquiredModule? in
            let s = _staged; _staged = nil; return s
        }) else { throw UpdateError.nothingStaged }
        let cfg = currentConfiguration
        let device = cfg?.resolvedDeviceID ?? PatchDeviceIDStore.resolve(appGroupIdentifier: nil)
        let checker = updateChecker

        do {
            // BUG #69: a large full-Foundation module takes SECONDS to decode +
            // instantiate in WasmKit, and the synchronous `activate(bytes:)` would run
            // it on whatever executor resumes this async call (the main actor for a
            // SwiftUI button tap) → a multi-second UI freeze, exactly the freeze the
            // review-#17 fix removed from `start()`. Offload the heavy instantiate onto a
            // background queue and suspend until it finishes, mirroring `start()`. (Must
            // be a queue OTHER than `callQueue`, whose inner `callQueue.sync`s must stay
            // free — a global user-initiated queue runs off-main without re-entering it.)
            try await activateOffMain(bytes: staged.bytes)
        } catch {
            if let cfg, let checker {
                await checker.reportEvent(Self.event(cfg, device: device,
                    type: .error, moduleVersion: staged.version,
                    errorMessage: "\(error)"))
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
            if let cfg, let checker {
                await checker.reportEvent(Self.event(cfg, device: device,
                    type: .fallback, moduleVersion: storage.currentVersion))
            }
            lock.write { self._staged = nil }
            await setState(.failed("\(error)"))
            throw UpdateError.activation(error)
        }
        // Activation succeeded — persist as the new current and clear staging.
        // Do NOT swallow an installCurrent failure: the new module is LIVE in memory,
        // but if persistence throws (disk full / replaceItemAt failure) the on-disk
        // `current` still names the OLD module, so the next-launch activateBestLocal
        // would silently regress one version. Surface a warning event and KEEP
        // `_pendingResponse` so a subsequent reload re-persists; only clear the staged
        // bytes (they are already activated and we will not re-activate them).
        var persistError: Error?
        do {
            try storage.installCurrent(version: staged.version, sha256: staged.sha256, bytes: staged.bytes)
        } catch {
            persistError = error
        }
        if let persistError {
            // Keep _pendingResponse so the next reload re-persists; drop only _staged.
            lock.write { self._staged = nil }
            if let cfg, let checker {
                await checker.reportEvent(Self.event(cfg, device: device,
                    type: .error, moduleVersion: staged.version,
                    errorMessage: "activation persisted-in-memory but installCurrent failed: \(persistError)"))
            }
        } else {
            lock.write { self._staged = nil; self._pendingResponse = nil }
        }
        if let cfg, let checker {
            await checker.reportEvent(Self.event(cfg, device: device,
                type: .activation, moduleVersion: staged.version))
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
    public static let sdkVersion = "1.5.18"

    // MARK: - Release-targeting client facts (os_version / app_version)
    //
    // The backend's `update_check` filters a candidate release by its
    // `min_app_version` / `max_app_version` / `min_os_version` (numeric semver).
    // For that targeting to take effect the SDK must send the device OS version
    // and the host app's marketing version on every check; when these are nil the
    // backend fails open (no version filtering). These are stable for the process
    // lifetime, so we compute them once and reuse them at both check sites.

    /// The device OS version (e.g. "17.4"), sent as `os_version`. Computed from
    /// `ProcessInfo.operatingSystemVersion` formatted "major.minor.patch" on every
    /// platform — on iOS/tvOS this returns the same OS version numbers as
    /// `UIDevice.current.systemVersion` would, but `ProcessInfo` is `nonisolated`
    /// (and `Sendable`), so reading it in this nonisolated `static let` default
    /// value does NOT trip Swift 6 strict-concurrency's "main actor-isolated
    /// default value in a nonisolated context" error that `UIDevice.current`
    /// (main-actor-isolated) does. Never crashes; the value is non-empty on every
    /// supported host.
    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
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
    /// symbol (`_pv_ProfileCard_primaryFontSize`). Mirrors `CodeEmitter.ValueExport`.
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
