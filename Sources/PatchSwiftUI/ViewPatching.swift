// ViewPatching.swift — the OUT-OF-THE-BOX SwiftUI body patching runtime.
// ======================================================================
// This is the SDK half of automatic view patching. The CLI (`patchcli prepare`,
// run by `init` and as a build phase) makes every eligible `View.body` getter
// `dynamic` and generates one replacement thunk per view:
//
//   extension SettingsScreen {
//       @_dynamicReplacement(for: body)
//       @ViewBuilder @MainActor var __patch_body: some View {
//           if let __p = Patch.shared.thunkBody(typeName: "SettingsScreen", instance: self) {
//               __p
//           } else {
//               body   // ← inside a replacement this calls the ORIGINAL body
//           }
//       }
//   }
//
// At every body evaluation the thunk asks `thunkBody(typeName:instance:)` for a
// patched replacement. The decision pipeline:
//
//   1. The active module's view MANIFEST (`patch_view_manifest` export, emitted
//      by the engine) says which view types have a fully-lowered, auto-routable
//      body export (`thunkSafe`). No manifest ⇒ no auto-routing (old modules).
//   2. The registry caches the manifest per MODULE EPOCH (`Patch.moduleEpoch`),
//      so the steady-state cost of an UNPATCHED view's body is one generation
//      read + one epoch compare + one dictionary miss — nanoseconds.
//   3. If the view is patched: the live instance's stored properties and scalar
//      `@State`/`@Binding`/`@AppStorage` values are marshalled (via Mirror) into
//      the flat inputs JSON the lowered guest body scans, and a `PatchedBodyHost`
//      renders the guest's ViewNode tree with the full interactive dispatch loop.
//      Guest state mutations are WRITTEN BACK to the native wrappers, so native
//      persistence (`@AppStorage`) and unpatched siblings stay coherent.
//   4. Any failure (decode, schema, trap) DEMOTES that view type for the current
//      module epoch: the next body evaluation takes the native branch. A broken
//      patch degrades to the compiled-in UI, never a broken screen.
//
// Live invalidation: on iOS 17+/macOS 14+ the registry exposes an `@Observable`
// generation counter read during every thunked body evaluation — SwiftUI then
// re-evaluates ALL thunked views when a patch (de)activates mid-session, so a
// hot-applied patch appears without navigation. On iOS 16 the new module is
// picked up on each view's next natural re-evaluation (or next launch).

#if canImport(SwiftUI)
import Foundation
import os
import SwiftUI
import PatchSDK
import PatchViewIR
import PatchRender
#if canImport(Observation)
import Observation
#endif

// MARK: - The module's view manifest

/// The engine-emitted manifest describing which lowered view-body exports the
/// active module ships, keyed by the view's (sanitized) type name. Decoded from
/// the module's `patch_view_manifest` export (a compile-time JSON literal in the
/// guest, so it costs one call + one small decode per module activation).
public struct PatchViewManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// The sanitized view type name — matches the literal baked into the
        /// generated thunk (`SwiftUIGuestEmitter.sanitizedViewName`).
        public let type: String
        /// The `view_body__<View>` export building this view's tree.
        public let export: String
        /// The `dispatch__<View>` export when the view is interactive, else nil
        /// (the view renders read-only and re-renders on native prop changes).
        public let dispatch: String?
        /// True when the body lowered with ZERO opaque fallback nodes — the only
        /// case the SDK auto-routes. A partially-lowered body would render
        /// visible stubs where native content belongs, so it stays native until
        /// the engine can lower all of it.
        public let thunkSafe: Bool
        /// The MINIMUM PatchViewIR schema version a host must support to render THIS view
        /// (per-view version gate). Optional for backward-decode of an older manifest that
        /// predates the field — `nil` falls back to the module `schemaVersion` (the prior
        /// whole-module behavior). A newer module stamps it per view (9 for a reactive-collection
        /// marshalling view, 8 otherwise) so an older host demotes only the views it can't render.
        public let minVersion: Int?
        /// NATIVE-FAST-PATH: the per-view body content hash the engine stamped at build
        /// time (`BodyLowering.viewBodyContentHash` over the view's lowered `guestBody` +
        /// parameterized-slot literals). The SDK compares it against the thunk's baked
        /// `baselineHash`: when EQUAL, the active module's body for this view is byte-
        /// identical to the build's shipped baseline (no OTA patch changed it), so the
        /// thunk renders the NATIVE body with ZERO WASM. ADDITIVE + backward-decode safe —
        /// `nil` for a manifest from a cli that predates the field (the SDK then fail-safes
        /// that view to WASM, the prior always-route behavior). A newer host still decodes
        /// an older manifest (this key absent → nil); an older host decodes a newer manifest
        /// (ignores this key). `minSupportedVersion` is unchanged (this is not a wire-format
        /// node case — it's an optional scalar that rides the existing manifest JSON).
        public let bodyHash: String?
        /// STRUCTURALLY-STATIC CACHE: when `true`, the engine proved the WASM-emitted
        /// ViewNode tree for this view is identical across ALL inputs — no bound input
        /// name appears in a live tree position, no input-riding host token, no
        /// GeometryReader, no interactive state model. The SDK caches the decoded tree
        /// after the FIRST WASM call and skips WASM on ALL subsequent renders.
        /// ADDITIVE + backward-decode safe: `nil` (absent in an older manifest) or `false`
        /// = always-WASM (the safe prior behavior). A newer host still decodes an older
        /// manifest (absent → nil → treated as false); an older host decodes a newer
        /// manifest (ignores this key). No `minSupportedVersion` bump — this is a purely
        /// optional optimization field, not a wire-format node case.
        public let isStructurallyStatic: Bool?
        public init(type: String, export: String, dispatch: String?, thunkSafe: Bool,
                    minVersion: Int? = nil, bodyHash: String? = nil,
                    isStructurallyStatic: Bool? = nil) {
            self.type = type
            self.export = export
            self.dispatch = dispatch
            self.thunkSafe = thunkSafe
            self.minVersion = minVersion
            self.bodyHash = bodyHash
            self.isStructurallyStatic = isStructurallyStatic
        }
    }
    /// PatchViewIR schema version the module's emissions target.
    public let schemaVersion: Int
    public let views: [Entry]
    public init(schemaVersion: Int, views: [Entry]) {
        self.schemaVersion = schemaVersion
        self.views = views
    }

    /// The guest export name (packed `(ptr,len) -> i64` ABI; input ignored).
    public static let exportName = "patch_view_manifest"
}

/// Minimal ONE-TIME runtime warning sink (R2-#100): logs each unique message at most once via
/// os.Logger so a version-skew diagnostic surfaces (a dev on a too-old pinned PatchSDK sees their
/// patch is partially inert) without spamming on every module-epoch reload.
enum PatchRuntimeLog {
    // Lock-guarded global de-dup state; `nonisolated(unsafe)` on `seen` is sound because every
    // access is serialized through `lock` below (Swift-6 strict-concurrency can't see that invariant).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen = Set<String>()
    private static let logger = Logger(subsystem: "com.patch.sdk", category: "patch-version")
    static func warnOnce(_ message: String) {
        lock.lock(); let isNew = seen.insert(message).inserted; lock.unlock()
        guard isNew else { return }
        logger.warning("\(message, privacy: .public)")
    }
}

// MARK: - Invalidation signal (iOS 17+/macOS 14+)

#if canImport(Observation)
/// An `@Observable` generation counter. Every thunked body evaluation READS
/// `generation`, which registers an Observation dependency with SwiftUI; bumping
/// it after a module (de)activation re-evaluates every on-screen thunked view.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@Observable
@MainActor
final class PatchViewInvalidationSignal {
    var generation: UInt64 = 0
}
#endif

// MARK: - Registry

/// Per-process registry mapping view type names to the active module's lowered
/// body exports. MainActor-confined: it is only ever touched from SwiftUI body
/// evaluations and the (main-queue) module-change notification.
@MainActor
public final class PatchViewPatchRegistry {
    public static let shared = PatchViewPatchRegistry()

    /// Manifest entries of the CURRENT module epoch, keyed by sanitized type name.
    private var entries: [String: PatchViewManifest.Entry] = [:]
    /// The `Patch.moduleEpoch` the entries were loaded against (nil = never).
    private var loadedEpoch: UInt64?
    /// View types DEMOTED for the current epoch after a render/decode failure —
    /// their thunks fall back to the native body until the next module change.
    private var failedTypes: Set<String> = []
    /// One-shot setup guards.
    private var didInstallChangeHandler = false
    private var didEnsureActivation = false
    /// Test seam: when set, `reload()` uses this JSON instead of calling the
    /// module's manifest export.
    var manifestJSONOverrideForTesting: (() -> String?)?

    /// Test seam (NATIVE-FAST-PATH): install a manifest's worth of entries directly and
    /// PIN the loaded epoch so `syncWithModuleEpoch` won't reload over them. Lets a unit
    /// test exercise `entryIfPatchable` / the `thunkBody` fast-path gate against a precise
    /// `bodyHash` set without standing up a real WASM module + epoch dance. Clears the
    /// failed-type demote set so the entries route cleanly.
    func installEntriesForTesting(_ entries: [PatchViewManifest.Entry]) {
        // Burn the one-shot setup guards FIRST: `entryIfPatchable` would otherwise call
        // `ensureActivationOnce()` (which can activate a cached module from a prior test and
        // bump `Patch.moduleEpoch` AFTER we pin it → `syncWithModuleEpoch` reloads + clobbers
        // our installed entries). Disabling them keeps the next lookup a pure read.
        self.didEnsureActivation = true
        self.didInstallChangeHandler = true
        self.entries = Dictionary(entries.map { ($0.type, $0) }, uniquingKeysWith: { _, b in b })
        self.failedTypes.removeAll()
        // Pin to the live epoch so the next `entryIfPatchable` doesn't re-sync + clobber.
        self.loadedEpoch = Patch.shared.moduleEpoch
    }

    /// Test seam: clear all installed entries + demote state (call at the END of a test
    /// that used `installEntriesForTesting`, to keep the singleton clean for the next).
    func resetForTesting() {
        self.entries.removeAll()
        self.failedTypes.removeAll()
        self.loadedEpoch = nil
    }

    #if canImport(Observation)
    private var _signalStorage: AnyObject?
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    private var invalidationSignal: PatchViewInvalidationSignal {
        if let s = _signalStorage as? PatchViewInvalidationSignal { return s }
        let s = PatchViewInvalidationSignal()
        _signalStorage = s
        return s
    }
    #endif

    init() {}

    /// The thunk fast path: the manifest entry for `typeName` iff the active
    /// module ships a fully-lowered body for it and it has not been demoted.
    public func entryIfPatchable(typeName: String) -> PatchViewManifest.Entry? {
        touchInvalidationSignal()
        installChangeHandlerOnce()
        ensureActivationOnce()
        syncWithModuleEpoch()
        guard let entry = entries[typeName], entry.thunkSafe,
              !failedTypes.contains(typeName) else { return nil }
        return entry
    }

    /// Whether the active module's manifest marks the view shipping `export` as
    /// `thunkSafe` (fully lowered, no undispatchable effect). Used to gate the explicit
    /// `Patch.patchView(viewBodyExport:)` path so a hand-wired export cannot bypass the
    /// thunkSafe gate the auto-route path enforces (bug #71 — a non-thunkSafe `.onDelete`
    /// ForEach reaching the destructive `editableForEach` array-revert). Returns:
    ///   * `true`  — a manifest entry for this export exists AND is thunkSafe.
    ///   * `false` — a manifest entry exists but is NOT thunkSafe (refuse).
    ///   * `nil`   — no manifest, or no entry for this export (a legacy/manifest-less
    ///               module, or a non-view-body export): the caller renders as before
    ///               (we can't gate what the manifest doesn't describe).
    public func isExportThunkSafe(export: String) -> Bool? {
        syncWithModuleEpoch()
        guard !entries.isEmpty else { return nil }
        guard let entry = entries.values.first(where: { $0.export == export }) else { return nil }
        return entry.thunkSafe
    }

    /// Demote `typeName` for the current module epoch (a render/decode failure).
    /// The bump re-evaluates on-screen views so the demoted view's NEXT body
    /// evaluation takes the native branch.
    public func markFailed(typeName: String) {
        markFailed(typeName: typeName, forEpoch: nil)
    }

    /// Demote `typeName`, but ONLY if it still belongs to `forEpoch` (the module epoch
    /// observed when the failure occurred). A failure is reported via a deferred
    /// `Task { @MainActor … }`; between scheduling and running, a module hot-swap can
    /// advance the epoch and clear `failedTypes` for the NEW module — running the stale
    /// `markFailed` would then false-demote a freshly-loaded view that never failed
    /// (bug #72). Re-syncing first + checking the epoch makes the demote no-op across a
    /// swap. `forEpoch == nil` keeps the legacy unconditional behavior.
    public func markFailed(typeName: String, forEpoch: UInt64?) {
        // Re-sync so `loadedEpoch`/`failedTypes` reflect any swap that landed meanwhile.
        syncWithModuleEpoch()
        if let forEpoch, forEpoch != loadedEpoch {
            // The failure belonged to a now-superseded module; ignore it for the new one.
            return
        }
        guard !failedTypes.contains(typeName) else { return }
        failedTypes.insert(typeName)
        bumpSignal()
    }

    /// Number of patchable view types in the active module (diagnostics).
    public var patchableViewCount: Int {
        syncWithModuleEpoch()
        return entries.values.filter(\.thunkSafe).count
    }

    // MARK: internals

    private func touchInvalidationSignal() {
        #if canImport(Observation)
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            // The read is the point: it registers the Observation dependency.
            _ = invalidationSignal.generation
        }
        #endif
    }

    private func bumpSignal() {
        #if canImport(Observation)
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            invalidationSignal.generation &+= 1
        }
        #endif
    }

    private func installChangeHandlerOnce() {
        guard !didInstallChangeHandler else { return }
        didInstallChangeHandler = true
        Patch.shared.onModuleSetChange { _ in
            // Handlers fire on the main queue; hop into the actor without waiting.
            Task { @MainActor in
                PatchViewPatchRegistry.shared.bumpSignal()
            }
        }
    }

    private func ensureActivationOnce() {
        guard !didEnsureActivation else { return }
        didEnsureActivation = true
        // First thunked body evaluation of the process: if `start()`'s async Task
        // hasn't activated the cached module yet, do it now (bounded by size) so
        // the FIRST frame already shows the patch.
        Patch.shared.ensureLocalActivationOnce()
    }

    private func syncWithModuleEpoch() {
        let epoch = Patch.shared.moduleEpoch
        guard epoch != loadedEpoch else { return }
        loadedEpoch = epoch
        failedTypes.removeAll()
        entries = Self.loadManifestEntries(overrideJSON: manifestJSONOverrideForTesting?())
    }

    private static func loadManifestEntries(overrideJSON: String?) -> [String: PatchViewManifest.Entry] {
        let jsonBytes: [UInt8]
        if let overrideJSON {
            jsonBytes = Array(overrideJSON.utf8)
        } else {
            guard Patch.shared.hasFunction(PatchViewManifest.exportName),
                  let bytes = try? Patch.shared.callPacked(PatchViewManifest.exportName, []) else {
                return [:]
            }
            jsonBytes = bytes
        }
        guard let manifest = try? JSONDecoder().decode(PatchViewManifest.self,
                                                       from: Data(jsonBytes)) else {
            return [:]
        }
        // PER-VIEW version gate (R2-#40/#41/#26/#88, replaces the prior whole-module refusal):
        // keep each view whose required schema version this host supports, DEMOTE only the rest.
        // A view's requirement is its `minVersion` (a newer manifest stamps it per view) else the
        // module `schemaVersion` (backward-compat with an older manifest that lacks the field). So
        // one v9 reactive-marshalling view never poisons its v8 siblings, an older host renders
        // everything it can instead of refusing the whole module, and a reactive view on a pre-v9
        // SDK demotes to native (the dev's real ForEach) instead of empty-rendering (R2-#24/#48).
        var out: [String: PatchViewManifest.Entry] = [:]
        var refusedTypes: [String] = []
        for entry in manifest.views {
            let req = entry.minVersion ?? manifest.schemaVersion
            // Route through the schema's own renderability predicate so BOTH bounds —
            // floor (`minSupportedVersion`) and ceiling (`version`) — stay in lockstep
            // with any future floor bump. A sub-floor entry demotes instead of being
            // admitted and then mis-rendering (the hand-rolled `<= version` checked only
            // the ceiling).
            if PatchViewIRSchema.isSupported(req) {
                out[entry.type] = entry
            } else {
                refusedTypes.append(entry.type)
            }
        }
        if !refusedTypes.isEmpty {
            // R2-#100 diagnostic: NAME the refused views so a dev on a too-old pinned PatchSDK
            // learns exactly which patch is inert (the console otherwise just shows "rolled
            // out"). Naming the views also makes distinct skews produce distinct strings, so
            // warnOnce (which dedups on the full message) can't swallow a later, different skew.
            PatchRuntimeLog.warnOnce(
                "PatchSDK v\(PatchViewIRSchema.version): \(refusedTypes.count) patched view(s) need a newer "
                + "PatchViewIR schema — rendered natively. Update PatchSDK to render them OTA. "
                + "Views: [\(refusedTypes.sorted().joined(separator: ", "))].")
        }
        return out
    }
}

// MARK: - Instance marshalling (Mirror → flat inputs JSON + write-backs)

/// Extracts/sets the scalar value of a SwiftUI property wrapper without knowing
/// its generic parameter. Conformances below cover the wrappers whose CURRENT
/// value must cross into the guest (`@State`, `@Binding`, `@AppStorage`). Their
/// `wrappedValue` setters are `nonmutating` (they write through to the live
/// SwiftUI storage box), so a Mirror-extracted COPY still reads/writes the
/// authoritative value.
@MainActor
public protocol _PatchScalarWrapper {
    func _patchRead() -> Any?
    func _patchWrite(_ newValue: Any)
    /// Reconstruct the wrapper's CONCRETE value from a JSON fragment and write it
    /// back, returning whether it wrote. Used for NON-scalar state (struct/array/
    /// enum/Date/…) whose value the guest mutated: when the wrapper's `Value`
    /// conforms to `Decodable`, the fragment decodes into it faithfully. A
    /// `Value` that isn't `Decodable` returns false (no write — never wrong).
    func _patchWriteJSON(_ jsonFragment: String) -> Bool
}

extension _PatchScalarWrapper {
    /// Default: no JSON reconstruction (scalar-only wrappers / external conformers
    /// keep working unchanged). The built-in wrappers override this.
    public func _patchWriteJSON(_ jsonFragment: String) -> Bool { false }
}

/// Coerce a writeback candidate to the wrapper's concrete `Value` BEFORE the
/// `as? Value` cast, fixing the numeric-type mismatch that silently dropped writes:
/// the guest serializes an integral `Double` (`1.0`, `0.0`) without a fractional part,
/// `unbox` then collapses any integral JSON number to `Int`, and `Int as? Double` is nil
/// → `@State<Double>`/`@AppStorage<Double>`/`Binding<Double>` (a `Slider` at an integral
/// stop, a persisted opacity/volume) NEVER updated → on reopen it snapped back / never
/// persisted (a value-dependent data-loss bug). We bridge Int↔Double↔CGFloat both ways so
/// the cast lands. A non-numeric `Value` falls through unchanged (the plain `as?`).
@MainActor
func _patchCoerceScalar<Value>(_ newValue: Any, to _: Value.Type) -> Value? {
    if let v = newValue as? Value { return v }
    // Pull a lossless integer out of whatever integral arrived FIRST (so a large
    // `Int64`/`UInt` snowflake/epoch-ms id never funnels through a lossy Double —
    // bug #51/#74). `unbox` collapses an integral JSON number to `Int`, but the
    // wrapper's concrete `Value` may be any width — bridge to every fixed-width
    // integer target so the `as? Value` cast lands instead of silently dropping
    // the write (which reverted the @State on the next native re-render).
    let intVal: Int?
    switch newValue {
    case let i as Int: intVal = i
    case let i as Int64: intVal = Int(exactly: i)
    case let i as Int32: intVal = Int(i)
    case let i as Int16: intVal = Int(i)
    case let i as Int8: intVal = Int(i)
    case let u as UInt: intVal = Int(exactly: u)
    case let u as UInt64: intVal = Int(exactly: u)
    case let u as UInt32: intVal = Int(u)
    case let u as UInt16: intVal = Int(u)
    case let u as UInt8: intVal = Int(u)
    default: intVal = nil
    }
    if let intVal {
        if Value.self == Int.self { return intVal as? Value }
        if Value.self == Int64.self { return Int64(intVal) as? Value }
        if Value.self == Int32.self { return Int32(exactly: intVal) as? Value }
        if Value.self == Int16.self { return Int16(exactly: intVal) as? Value }
        if Value.self == Int8.self { return Int8(exactly: intVal) as? Value }
        if Value.self == UInt.self { return UInt(exactly: intVal) as? Value }
        if Value.self == UInt64.self { return UInt64(exactly: intVal) as? Value }
        if Value.self == UInt32.self { return UInt32(exactly: intVal) as? Value }
        if Value.self == UInt16.self { return UInt16(exactly: intVal) as? Value }
        if Value.self == UInt8.self { return UInt8(exactly: intVal) as? Value }
        // A floating target from an integral source.
        if Value.self == Double.self { return Double(intVal) as? Value }
        if Value.self == CGFloat.self { return CGFloat(intVal) as? Value }
        if Value.self == Float.self { return Float(intVal) as? Value }
        return nil
    }
    // Numeric widening/narrowing: pull a Double out of whatever floating arrived.
    let d: Double?
    switch newValue {
    case let x as Double: d = x
    case let f as CGFloat: d = Double(f)
    case let f as Float: d = Double(f)
    default: d = nil
    }
    guard let d else { return nil }
    if Value.self == Double.self { return d as? Value }
    if Value.self == CGFloat.self { return CGFloat(d) as? Value }
    if Value.self == Float.self { return Float(d) as? Value }
    // An integral target written from an integral-valued Double (`Int` from `Int(d)`).
    if d == d.rounded() {
        if Value.self == Int.self { return Int(d) as? Value }
        if Value.self == Int64.self { return Int64(d) as? Value }
        if Value.self == Int32.self { return Int32(exactly: d) as? Value }
        if Value.self == UInt.self, d >= 0 { return UInt(d) as? Value }
        if Value.self == UInt64.self, d >= 0 { return UInt64(d) as? Value }
        if Value.self == UInt32.self, d >= 0 { return UInt32(exactly: d) as? Value }
    }
    return nil
}

extension State: _PatchScalarWrapper {
    public func _patchRead() -> Any? { wrappedValue }
    public func _patchWrite(_ newValue: Any) {
        if let v = _patchCoerceScalar(newValue, to: Value.self) { wrappedValue = v }
    }
    public func _patchWriteJSON(_ jsonFragment: String) -> Bool {
        guard let v = _patchDecodeJSON(Value.self, from: jsonFragment) else { return false }
        wrappedValue = v; return true
    }
}

extension Binding: _PatchScalarWrapper {
    public func _patchRead() -> Any? { wrappedValue }
    public func _patchWrite(_ newValue: Any) {
        if let v = _patchCoerceScalar(newValue, to: Value.self) { wrappedValue = v }
    }
    public func _patchWriteJSON(_ jsonFragment: String) -> Bool {
        guard let v = _patchDecodeJSON(Value.self, from: jsonFragment) else { return false }
        wrappedValue = v; return true
    }
}

extension AppStorage: _PatchScalarWrapper {
    public func _patchRead() -> Any? { wrappedValue }
    public func _patchWrite(_ newValue: Any) {
        if let v = _patchCoerceScalar(newValue, to: Value.self) { wrappedValue = v }
    }
    // @AppStorage only stores property-list scalars (String/Int/Double/Bool/Data/
    // URL/RawRepresentable), never a free struct/array, so the default no-op JSON
    // write-back (from the protocol extension) is exactly right here.
}

/// Unwraps a SwiftUI REACTIVE property wrapper to the OBJECT it holds, so the
/// object's fields can be marshalled into the guest inputs as a nested object
/// (`{"vm":{"items":[…]}}`) — letting a `ForEach(vm.items)` over a reactive
/// collection lower to a bound WASM loop instead of native-slotting the rows.
///
/// SAFE-SURFACE INVARIANT (bug #8): conformed ONLY by the wrappers that HOLD their
/// object directly and whose `wrappedValue` therefore NEVER traps —
/// `@ObservedObject` and `@StateObject`. It is DELIBERATELY *not* conformed by
/// `@EnvironmentObject` or `@Environment(SomeType.self)`: those read their object
/// out of the environment, and `wrappedValue` TRAPS (an uncatchable Swift fatalError)
/// when the object isn't installed. `extract` marshals EVERY reactive wrapper it
/// finds on the instance EAGERLY — even one the current body-render path wouldn't
/// touch — so conforming the environment wrappers would crash the app MORE than
/// native rendering ever would (native only traps if the body actually reads the
/// missing object). A trap can't be caught, so there is no try/catch fix: the only
/// safe answer is to never call `wrappedValue` on a possibly-absent wrapper. The
/// engine MIRRORS this restriction — it refuses to register an `@EnvironmentObject`/
/// `@Environment`-backed reactive collection as a marshalled input (the `ForEach`
/// then native-demotes, demote-safe), so the two sides agree on the safe surface.
///
/// (A `@State var vm = SomeObservable()` / a plain `let vm` is NOT here — those
/// already marshal via `_PatchScalarWrapper`/the stored-property path.)
///
/// Returns the wrapped value ONLY when it is a CLASS instance (a value-type held
/// object isn't a marshallable view-model and shouldn't be treated as one).
/// `wrappedValue` is read during the view's body evaluation (when the thunk runs),
/// where `@ObservedObject`/`@StateObject` are always populated.
@MainActor
public protocol _PatchReactiveWrapper {
    func _patchReactiveObject() -> AnyObject?
}

extension ObservedObject: _PatchReactiveWrapper {
    public func _patchReactiveObject() -> AnyObject? { wrappedValue as AnyObject }
}
extension StateObject: _PatchReactiveWrapper {
    public func _patchReactiveObject() -> AnyObject? { wrappedValue as AnyObject }
}
// NOTE: `EnvironmentObject` and `Environment` are INTENTIONALLY NOT conformed —
// reading their `wrappedValue` when the object is absent traps uncatchably. See the
// SAFE-SURFACE INVARIANT above. Do not add them back without a per-member opt-in
// that the engine can prove the body actually reads (and even then, the env object
// can still be legitimately absent at the time `extract` runs).

/// Decode a JSON fragment into `V` IFF `V: Decodable` (a runtime check — `State`'s
/// `Value` carries no Decodable bound). Returns nil for a non-Decodable `V` or a
/// fragment that doesn't parse, so the write-back is skipped rather than wrong.
///
/// The decoder MUST mirror `PatchValueEncoder`'s conventions or the write-back
/// corrupts the value (bug #23): the encoder marshals a `Date` as
/// `timeIntervalSince1970` (epoch-1970 seconds), but a vanilla `JSONDecoder`
/// defaults to `.deferredToDate` (a 2001 reference-date Double) and would read the
/// same number ~31 years off. Pin `dateDecodingStrategy` to `.secondsSince1970` so
/// a `Date` inside a Decodable `@State`/`@Binding` struct round-trips faithfully.
@MainActor
func _patchDecodeJSON<V>(_ type: V.Type, from jsonFragment: String) -> V? {
    guard let decodableType = V.self as? any Decodable.Type,
          let data = jsonFragment.data(using: .utf8) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    // BUG R4-MED: `PatchValueEncoder` emits `Data` as a JSON int array `[1,2,3]`, but a
    // vanilla `JSONDecoder` defaults `dataDecodingStrategy` to `.base64` (it expects a
    // base64 STRING) — so a top-level `Data` @State, or any Decodable struct holding a
    // `Data` field, fails to decode and the write-back is silently dropped. Pin
    // `.deferredToData` so the int-array form round-trips, exactly as the `Date` pin above.
    decoder.dataDecodingStrategy = .deferredToData
    if let decoded = try? decoder.decode(decodableType, from: data) {
        return decoded as? V
    }
    // BUG R4-HIGH: `PatchValueEncoder.encodeEnum` emits an enum as `{"case":"<label>"[,…]}`,
    // a shape the vanilla decoder above cannot round-trip (Swift's synthesized `Codable`
    // encodes a no-payload/raw-`String` case as a BARE STRING and an associated-value case
    // as `{caseName:{payload}}`, never `{"case":…}`). Without this, a `Picker`/segmented
    // enum @State/@Binding write-back is DEAD. Detect the `{"case":…}` envelope and retry
    // against the shape the synthesized decoder expects, so the mutation reaches the guest.
    if let reshaped = _patchReshapeEnumFragment(jsonFragment),
       let decoded = try? decoder.decode(decodableType, from: reshaped) {
        return decoded as? V
    }
    return nil
}

/// Reshape a `PatchValueEncoder`-emitted enum envelope `{"case":"<label>"[, "_0":…,…]}`
/// into the form Swift's synthesized `Codable` decodes:
///   * no associated values → a BARE JSON string `"<label>"` (handles a raw-`String` /
///     no-payload case — the dominant Picker/segmented-control shape);
///   * associated values     → `{"<label>":{<payload-without-the-"case"-key>}}`.
/// Returns nil for anything that isn't a recognizable `{"case":…}` object (so the caller
/// falls through and the write-back is skipped rather than corrupted — demote-safe).
@MainActor
func _patchReshapeEnumFragment(_ jsonFragment: String) -> Data? {
    guard let data = jsonFragment.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let caseName = obj["case"] as? String else { return nil }
    var payload = obj
    payload.removeValue(forKey: "case")
    if payload.isEmpty {
        // No associated values: the synthesized decoder reads a bare string (a raw-String
        // or no-payload case). Emit a JSON string literal with the same escaping the encoder
        // uses, so the quoting matches.
        return PatchInstanceInputs.quotedJSONString(caseName).data(using: .utf8)
    }
    // Associated-value case: `{"<label>":{ <payload> }}`.
    return try? JSONSerialization.data(withJSONObject: [caseName: payload], options: [])
}

/// One native storage location a guest state field writes back to: the wrapper
/// (an existing live wrapper value extracted from the instance) plus the flat-
/// JSON key the guest state-model uses for it.
@MainActor
public struct PatchScalarWriteback {
    public let key: String
    let wrapper: any _PatchScalarWrapper
}

/// Marshals a live view instance's stored properties into the flat inputs JSON
/// the lowered guest body scans (`{"name":"…","flag":true,…}`), plus write-backs
/// for the wrapper-backed scalars.
// MARK: - Marshalling memoization (P0 perf)

/// A MainActor-isolated, bounded memoization cache for the MARSHALLED INPUT JSON.
///
/// `PatchInstanceInputs.extract` Mirror-reflects + recursively JSON-encodes the instance
/// EVERY render to build the WASM input. Profiling shows the Mirror enumeration is cheap
/// (~3.8µs) but the recursive string build is ~159µs for a rich instance — and SwiftUI
/// re-evaluates `body` constantly with UNCHANGED state, so it's rebuilt byte-identically
/// over and over. This cache keys the produced JSON by a CHANGE-DETECTOR FINGERPRINT of the
/// instance's marshalled state (a hash over exactly the key/value content `extract` encodes)
/// so an unchanged render reuses the string instead of rebuilding it.
///
/// Correctness (this is the #1 false-render-risk area — a stale JSON = WRONG UI on device):
///  * The fingerprint (`PatchInstanceInputs.fingerprint`) covers EVERY selected field's key,
///    representability, and recursive content+structure, so equal fingerprint ⇒ (overwhelmingly)
///    equal marshalled JSON. An un-fingerprintable instance never caches (always re-encodes).
///  * The cached value is ONLY the WASM-INPUT JSON, which is a pure function of instance state
///    and INDEPENDENT of the module epoch (it's the input to WASM, not WASM output) — so unlike
///    the render cache this needs no epoch scoping. The live wrappers' writebacks are NEVER
///    cached (re-collected every render from the live instance).
///  * Bounded per typeName via a tiny LRU (steady state has ~1 distinct fingerprint).
///  * MainActor-isolated — all access is serialized with no lock.
@MainActor
final class PatchMarshalCache {
    static let shared = PatchMarshalCache()

    /// Per-typeName LRU capacity. Steady state holds ~1 distinct fingerprint; 4 absorbs a
    /// small amount of state churn (a value oscillating between a few states) without growing.
    static let capacityPerType = 4

    private struct Bucket {
        var entries: [UInt64: String] = [:]   // fingerprint → marshalled JSON
        var order: [UInt64] = []              // LRU recency (front = MRU)
    }
    private var byType: [String: Bucket] = [:]

    /// The cached JSON for (typeName, fingerprint), or nil on a miss. A hit refreshes recency.
    func lookup(typeName: String, fingerprint: UInt64) -> String? {
        guard var bucket = byType[typeName], let json = bucket.entries[fingerprint] else { return nil }
        if let idx = bucket.order.firstIndex(of: fingerprint) { bucket.order.remove(at: idx) }
        bucket.order.insert(fingerprint, at: 0)
        byType[typeName] = bucket
        return json
    }

    /// Store the JSON for (typeName, fingerprint), enforcing the per-type LRU bound.
    func store(typeName: String, fingerprint: UInt64, json: String) {
        var bucket = byType[typeName] ?? Bucket()
        bucket.entries[fingerprint] = json
        if let idx = bucket.order.firstIndex(of: fingerprint) { bucket.order.remove(at: idx) }
        bucket.order.insert(fingerprint, at: 0)
        while bucket.order.count > Self.capacityPerType {
            let victim = bucket.order.removeLast()
            bucket.entries[victim] = nil
        }
        byType[typeName] = bucket
    }

    /// Test-only: number of distinct cached fingerprints for a type.
    func entryCount(typeName: String) -> Int { byType[typeName]?.order.count ?? 0 }

    /// Test-only: drop everything.
    func reset() { byType.removeAll() }
}

public enum PatchInstanceInputs {
    public struct Extraction {
        public let json: String
        public let writebacks: [PatchScalarWriteback]
    }

    /// One marshallable field selected from the instance's top-level Mirror: the JSON key it
    /// emits under and the VALUE that gets recursively encoded for it. (`writeback` is set
    /// for a scalar-wrapper field.) This is the single field-collection pass shared by the
    /// JSON build AND the change-detector fingerprint, so the two can never disagree on which
    /// fields/values flow into the guest input.
    struct SelectedField {
        let key: String
        let value: Any
        let writeback: PatchScalarWriteback?
    }

    /// Walk the instance's TOP-LEVEL Mirror once and select the marshallable fields (applying
    /// the wrapper/reactive/plain-prop rules), WITHOUT yet encoding any value. Cheap (~Mirror
    /// enumeration); the expensive recursive JSON string-build happens later, only on a miss.
    @MainActor
    static func selectFields(from instance: Any) -> [SelectedField] {
        var fields: [SelectedField] = []
        for child in Mirror(reflecting: instance).children {
            guard let rawLabel = child.label else { continue }
            if rawLabel.hasPrefix("_") {
                if let wrapper = child.value as? _PatchScalarWrapper {
                    let key = String(rawLabel.dropFirst())
                    guard !key.isEmpty, !isReservedInputKey(key),
                          let value = wrapper._patchRead() else { continue }
                    // Write-back is wired for any wrapper-backed field whose value round-trips
                    // through the guest. (Representability of the value is decided later by the
                    // encoder/fingerprint, identically on both sides.)
                    fields.append(SelectedField(key: key, value: value,
                                                writeback: PatchScalarWriteback(key: key, wrapper: wrapper)))
                } else if let reactive = child.value as? _PatchReactiveWrapper,
                          let object = reactive._patchReactiveObject() {
                    // A REACTIVE view-model/service object marshalled as a nested object so the
                    // guest can read `member.collection`. READ-ONLY (no write-back).
                    let key = String(rawLabel.dropFirst())
                    guard !key.isEmpty, !isReservedInputKey(key) else { continue }
                    fields.append(SelectedField(key: key, value: object, writeback: nil))
                }
            } else {
                // A plain stored property (`let`/`var`).
                guard rawLabel != "body", !isReservedInputKey(rawLabel) else { continue }
                fields.append(SelectedField(key: rawLabel, value: child.value, writeback: nil))
            }
        }
        return fields
    }

    /// Build the flat inputs JSON from already-selected fields, encoding each value and
    /// OMITTING a field whose value the encoder can't represent (the input then falls back
    /// to its guest-side default). Deterministic key order.
    @MainActor
    private static func buildJSON(from fields: [SelectedField]) -> String {
        var fragments: [(key: String, json: String)] = []
        fragments.reserveCapacity(fields.count)
        for f in fields {
            guard let fragment = PatchValueEncoder.encode(f.value) else { continue }
            fragments.append((f.key, fragment))
        }
        fragments.sort { $0.key < $1.key }
        return "{" + fragments.map { "\"\(escapeJSONKey($0.key))\":\($0.json)" }
            .joined(separator: ",") + "}"
    }

    /// A CHANGE-DETECTOR fingerprint of the selected fields, parallel to (and covering EXACTLY
    /// the same key/value content as) `buildJSON`. Returns nil iff ANY selected value is not
    /// completely+cheaply fingerprintable — in which case the caller treats the marshalled
    /// state as CHANGED and re-encodes (the safe default; never a false "unchanged"). Folds
    /// in each field's key, a per-field representability flag, and the field count, so a field
    /// set / value / order change always changes the fingerprint.
    @MainActor
    static func fingerprint(of fields: [SelectedField]) -> UInt64? {
        // Sort by key so the fingerprint is order-independent of Mirror's child order (matches
        // `buildJSON`, which sorts the emitted fragments by key).
        let sorted = fields.sorted { $0.key < $1.key }
        var hasher = Hasher()
        hasher.combine(0x70 as UInt8)            // top-level instance tag
        hasher.combine(sorted.count)
        for f in sorted {
            hasher.combine(f.key)
            // Mirror `buildJSON`'s omit-on-unencodable: a value the encoder can't represent is
            // OMITTED from the JSON. The fingerprint must reflect that EXACT representability
            // decision, so a field flipping representable↔unrepresentable changes the
            // fingerprint. `PatchValueFingerprint.feed` returns false on EXACTLY the values
            // `PatchValueEncoder.encode` returns nil for (parallel construction).
            var sub = Hasher()
            let representable = PatchValueFingerprint.feed(f.value, into: &sub)
            hasher.combine(representable)
            if representable { hasher.combine(sub.finalize()) }
            // If NOT representable the field is omitted from the JSON — its content can't
            // change the JSON, so we DON'T fold sub's (partial) content. The representable
            // flag alone records the omission, which is all the JSON depends on.
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// The full marshal: select fields, build JSON, collect writebacks. Always does the
    /// recursive encode — used by tests/benchmarks as the always-fresh reference and by the
    /// memoizing `extract(from:typeName:)` on a cache miss.
    @MainActor
    public static func extract(from instance: Any) -> Extraction {
        let fields = selectFields(from: instance)
        let json = buildJSON(from: fields)
        let writebacks = fields.compactMap { $0.writeback }
        return Extraction(json: json, writebacks: writebacks)
    }

    /// MEMOIZED marshal (P0 perf). Performs the CHEAP field-selection + fingerprint pass every
    /// render; on a steady-state render whose fingerprint matches a recent one for this view
    /// type, it REUSES the cached `propsJSON` and SKIPS the ~159µs recursive JSON string build.
    /// On a miss (or an un-fingerprintable instance) it does the full encode and caches it.
    ///
    /// SAFETY (the #1 false-render-risk area): the writebacks are ALWAYS freshly collected
    /// from the LIVE wrappers (never cached — they hold live `@State` references). Only the
    /// WASM-input JSON string is memoized, and only when the fingerprint — which covers every
    /// selected key/value's content + structure — matches. An un-fingerprintable instance
    /// (fingerprint == nil) ALWAYS re-encodes. So a cache hit implies (overwhelmingly) an
    /// identical marshalled state; the residual risk is a 64-bit hash collision between two
    /// distinct states of the same view, which is the standard memoization tradeoff.
    @MainActor
    public static func extract(from instance: Any, typeName: String) -> Extraction {
        let fields = selectFields(from: instance)
        // Writebacks are LIVE — always re-collected, never cached.
        let writebacks = fields.compactMap { $0.writeback }
        let fp = fingerprint(of: fields)
        if let fp, let cachedJSON = PatchMarshalCache.shared.lookup(typeName: typeName, fingerprint: fp) {
            return Extraction(json: cachedJSON, writebacks: writebacks)
        }
        // Miss (or un-fingerprintable): do the full encode.
        let json = buildJSON(from: fields)
        if let fp { PatchMarshalCache.shared.store(typeName: typeName, fingerprint: fp, json: json) }
        return Extraction(json: json, writebacks: writebacks)
    }

    /// BUG R4-LOW: true iff `key` collides with an ENGINE-RESERVED input namespace the
    /// host merges OVER the guest state at render time — the GeometryReader proxy inputs
    /// (`__geo_*`) and the input-riding host tokens (`__numtok_*`/`__strtok_*`). A user
    /// stored property literally named like one of these would be silently clobbered by
    /// the reserved input on every layout/token pass (override wins in `PatchFlatJSON.merge`).
    /// `extract` SKIPS such a key so the reserved input can never be overwritten and the
    /// user field falls back to its guest-side default (build-safe = demote-safe). A normal
    /// Swift property never starts with `__geo_`/`__numtok_`/`__strtok_`.
    static func isReservedInputKey(_ key: String) -> Bool {
        for prefix in ["__geo_", "__numtok_", "__strtok_"] {
            if key.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// A flat-JSON value fragment for a supported scalar, else nil. Integral
    /// doubles print as integers — the guest's Foundation-free `_patchScanInt`
    /// rejects a trailing `.0`, and `_patchScanDouble` accepts either shape.
    static func scalarJSONFragment(_ value: Any) -> String? {
        switch value {
        case let s as String: return quotedJSONString(s)
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let i as Int32: return String(i)
        case let i as Int64: return String(i)
        case let u as UInt: return String(u)
        // BUG R4-MED: the remaining fixed-width integer widths. Without these a
        // `@State var id: UInt64` (or Int8/Int16/UInt8/UInt16/UInt32) fell past every
        // scalar/leaf case into Mirror, which has no displayStyle/children for a
        // fixed-width int → the encoder returned nil → the key was omitted → the guest
        // rendered its compiled-in default. The write-side `_patchCoerceScalar` already
        // bridges all these widths, so the read side was the only asymmetric gap.
        case let i as Int8: return String(i)
        case let i as Int16: return String(i)
        case let u as UInt8: return String(u)
        case let u as UInt16: return String(u)
        case let u as UInt32: return String(u)
        case let u as UInt64: return String(u)
        case let d as Double: return doubleFragment(d)
        case let f as Float: return doubleFragment(Double(f))
        case let c as CGFloat: return doubleFragment(Double(c))
        default: return nil
        }
    }

    private static func doubleFragment(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
        return String(d)
    }

    static func quotedJSONString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func escapeJSONKey(_ key: String) -> String {
        // Property names are Swift identifiers; quotes/backslashes can't occur,
        // but escape defensively anyway.
        key.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Flat-JSON merge (latest native props ∪ guest-owned state)

enum PatchFlatJSON {
    /// Merge two flat JSON objects: `override`'s keys win. Either may be empty.
    /// The guest's `dispatch` re-emits ONLY its state-model fields, so merging
    /// keeps freshly-marshalled native props for everything else.
    static func merge(base: String, override: String) -> String {
        if override.isEmpty { return base.isEmpty ? "{}" : base }
        if base.isEmpty { return override }
        // PARSE-FREE FAST PATH (PERF batch): when BOTH inputs are flat top-level JSON
        // objects of cheaply-canonicalizable scalars (the common case — props / guest
        // scalar state / token merges), splice them WITHOUT a full JSONSerialization
        // parse + NSNumber-boxing reserialize. The result is BYTE-IDENTICAL to the
        // JSONSerialization path (it canonicalizes each scalar through the SAME rules
        // `fragment(for:)`/`serialize` use, and sorts keys the same way), so it feeds
        // the render-cache key identically. ANY non-flat / escaped / edge input on
        // EITHER side falls through to the proven JSONSerialization path below.
        if let spliced = flatScalarMerge(base: base, override: override) {
            return spliced
        }
        return mergeViaJSONSerialization(base: base, override: override)
    }

    /// The ORIGINAL JSONSerialization merge (parse both → dict-union → reserialize). This
    /// is the proven reference path `merge` falls back to, and the byte-identical oracle the
    /// transparency tests diff the fast path against. NOT the hot path — kept callable so a
    /// test can assert the parse-free splice matches it exactly for every input shape.
    static func mergeViaJSONSerialization(base: String, override: String) -> String {
        if override.isEmpty { return base.isEmpty ? "{}" : base }
        if base.isEmpty { return override }
        guard var baseObj = parse(base) else { return override }
        guard let overObj = parse(override) else { return base }
        for (k, v) in overObj { baseObj[k] = v }
        return serialize(baseObj)
    }

    // MARK: - Parse-free flat-scalar merge (the fast path)

    /// One scanned `key: rawValueSlice` of a flat JSON object, already canonicalized to
    /// the exact bytes `serialize`/`fragment(for:)` would emit. `nil` value means the
    /// field is dropped (matches `serialize`'s `guard let frag … else { continue }`).
    private struct FlatField { var key: String; var canonical: String? }

    /// Attempt the parse-free splice. Returns the merged canonical string, or `nil` to
    /// signal "fall back to the JSONSerialization path" (any input shape this can't
    /// PROVE byte-identical). Conservative by construction: it only emits when every
    /// scanned value is a scalar it can canonicalize to the same bytes the slow path
    /// would, with no nesting/escapes it can't reproduce.
    private static func flatScalarMerge(base: String, override: String) -> String? {
        guard let baseFields = scanFlatScalarObject(base) else { return nil }
        guard let overFields = scanFlatScalarObject(override) else { return nil }
        // Merge by key, override wins. Preserve the SAME drop semantics as `serialize`:
        // a field whose canonical is nil is omitted. Duplicate keys WITHIN one object are
        // disallowed by the scanner (returns nil → fall back) so last-wins ambiguity can't
        // diverge from JSONSerialization.
        var byKey: [String: String?] = [:]
        byKey.reserveCapacity(baseFields.count + overFields.count)
        for f in baseFields { byKey[f.key] = f.canonical }
        for f in overFields { byKey[f.key] = f.canonical }   // override wins
        var pairs: [(key: String, json: String)] = []
        pairs.reserveCapacity(byKey.count)
        for (k, v) in byKey { if let v { pairs.append((k, v)) } }
        pairs.sort { $0.key < $1.key }
        var out = "{"
        var first = true
        for p in pairs {
            if !first { out += "," }
            first = false
            out += PatchInstanceInputs.quotedJSONString(p.key)
            out += ":"
            out += p.json
        }
        out += "}"
        return out
    }

    /// Scan a FLAT top-level JSON object whose values are all scalars (string/number/
    /// bool/null) into `(key, canonicalValueBytes)` fields, WITHOUT JSONSerialization.
    /// Returns `nil` (→ caller falls back) on the FIRST sign the splice can't be proven
    /// byte-identical: a nested object/array value, an escaped string the canonical
    /// form would rewrite, a number that doesn't canonicalize trivially, a duplicate
    /// key, or any malformed/edge byte. NEVER guesses — a `nil` is always safe.
    private static func scanFlatScalarObject(_ s: String) -> [FlatField]? {
        // CHEAP PRE-REJECT (keeps the fallback path from paying the full structured scan):
        // walk the UTF8 view ONCE — no allocation — and bail the instant a structural byte
        // proves this isn't a flat-scalar object: a nested `{`/`[` outside a string. (A `{`
        // or `[` INSIDE a string value is skipped correctly, respecting `\"` escapes.) This
        // makes an array/object-bearing input — which MUST fall back — skip straight to the
        // JSONSerialization path without allocating `Array(s.utf8)` or scanning twice.
        if !flatScalarPreScan(s.utf8) { return nil }

        let bytes = Array(s.utf8)
        var i = 0
        let n = bytes.count
        @inline(__always) func skipWS() { while i < n, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D { i += 1 } }
        skipWS()
        guard i < n, bytes[i] == UInt8(ascii: "{") else { return nil }
        i += 1
        skipWS()
        var fields: [FlatField] = []
        var seenKeys = Set<String>()
        if i < n, bytes[i] == UInt8(ascii: "}") {
            i += 1; skipWS()
            return i == n ? fields : nil   // trailing garbage ⇒ fall back
        }
        while true {
            skipWS()
            // ---- key (a JSON string) ----
            guard i < n, bytes[i] == UInt8(ascii: "\"") else { return nil }
            guard let (rawKey, decodedKey, kEnd) = scanString(bytes, from: i) else { return nil }
            i = kEnd
            // The canonical KEY emission is `quotedJSONString(decodedKey)`. If the raw
            // key slice (incl. quotes) is NOT already that exact form, the splice would
            // differ — only accept when raw == canonical (no escapes ⇒ they match). The
            // map below keys on the DECODED key (so two keys that decode equal can't both
            // survive); a duplicate decoded key ⇒ fall back (JSONSerialization last-wins
            // is order-dependent and we don't want to replicate it heuristically).
            if PatchInstanceInputs.quotedJSONString(decodedKey) != rawKey { return nil }
            if !seenKeys.insert(decodedKey).inserted { return nil }
            skipWS()
            guard i < n, bytes[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            skipWS()
            // ---- value (scalar only) ----
            guard i < n else { return nil }
            let c = bytes[i]
            let canonical: String?
            if c == UInt8(ascii: "\"") {
                guard let (rawStr, decodedStr, vEnd) = scanString(bytes, from: i) else { return nil }
                // Canonical string emission = quotedJSONString(decoded). Accept only when
                // the raw slice already equals that (no escape the canonical form rewrites).
                if PatchInstanceInputs.quotedJSONString(decodedStr) != rawStr { return nil }
                canonical = rawStr
                i = vEnd
            } else if c == UInt8(ascii: "t") || c == UInt8(ascii: "f") || c == UInt8(ascii: "n") {
                guard let (lit, vEnd) = scanLiteral(bytes, from: i) else { return nil }
                canonical = lit         // "true"/"false"/"null" are already canonical
                i = vEnd
            } else if c == UInt8(ascii: "-") || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) {
                guard let (canon, vEnd) = scanNumberCanonical(bytes, from: i) else { return nil }
                canonical = canon
                i = vEnd
            } else {
                // '{' or '[' (nested) or anything else ⇒ not a flat scalar ⇒ fall back.
                return nil
            }
            fields.append(FlatField(key: decodedKey, canonical: canonical))
            skipWS()
            guard i < n else { return nil }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") {
                i += 1; skipWS()
                return i == n ? fields : nil
            }
            return nil
        }
    }

    /// A fast structural pre-check: is `utf8` plausibly a FLAT object of scalars? Returns
    /// `false` (→ the caller falls back to JSONSerialization WITHOUT the full structured
    /// scan) the moment it sees a nested `{`/`[` outside a string. Strings are skipped
    /// correctly (a `{`/`[`/`}`/`]` inside a string value can't false-trigger), honoring
    /// `\"`/`\\` escapes. A `true` is NOT a promise the input is valid flat-scalar JSON —
    /// just that the structured scan is worth attempting; the scan still validates fully.
    private static func flatScalarPreScan(_ utf8: String.UTF8View) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        var sawTopObject = false
        for b in utf8 {
            if inString {
                if escaped { escaped = false; continue }
                if b == UInt8(ascii: "\\") { escaped = true; continue }
                if b == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch b {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"):
                depth += 1
                if depth == 1 { sawTopObject = true }
                else { return false }          // a nested object ⇒ not flat
            case UInt8(ascii: "["):
                return false                    // any array ⇒ not flat (top-level or nested)
            case UInt8(ascii: "}"):
                depth -= 1
            default:
                continue
            }
        }
        // Only worth attempting if we saw exactly the top-level object and it closed cleanly.
        return sawTopObject && depth == 0 && !inString
    }

    /// Scan a JSON string starting at `from` (must point at the opening `"`). Returns the
    /// RAW slice (incl. both quotes), the DECODED string, and the index PAST the closing
    /// quote. Returns `nil` on an unterminated/invalid string. Decodes the standard escape
    /// set; an escape it doesn't model (`\u…`, `\/`, etc.) is decoded conservatively so the
    /// `raw == quotedJSONString(decoded)` equality check the caller runs will simply FAIL
    /// for those (→ fall back), never producing a wrong splice.
    private static func scanString(_ bytes: [UInt8], from start: Int) -> (raw: String, decoded: String, end: Int)? {
        let n = bytes.count
        var i = start + 1            // past opening quote
        var decoded: [UInt8] = []
        while i < n {
            let b = bytes[i]
            if b == UInt8(ascii: "\"") {
                let raw = String(decoding: bytes[start...i], as: UTF8.self)
                let dec = String(decoding: decoded, as: UTF8.self)
                return (raw, dec, i + 1)
            }
            if b == UInt8(ascii: "\\") {
                guard i + 1 < n else { return nil }
                let e = bytes[i + 1]
                switch e {
                case UInt8(ascii: "\""): decoded.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): decoded.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "n"): decoded.append(0x0A)
                case UInt8(ascii: "t"): decoded.append(0x09)
                case UInt8(ascii: "r"): decoded.append(0x0D)
                default:
                    // An escape we don't canonicalize 1:1 (\/ , \b, \f, \uXXXX). Decode the
                    // escaped byte verbatim so `raw == quotedJSONString(decoded)` FAILS and
                    // the caller falls back — correct (never a wrong splice), just not fast.
                    decoded.append(e)
                }
                i += 2
                continue
            }
            decoded.append(b)
            i += 1
        }
        return nil   // unterminated
    }

    /// Scan one of the bare literals `true` / `false` / `null` at `from`. Returns the
    /// literal text + the index past it, or `nil` if the bytes don't match exactly.
    private static func scanLiteral(_ bytes: [UInt8], from start: Int) -> (String, Int)? {
        func match(_ lit: String) -> Int? {
            let l = Array(lit.utf8)
            guard start + l.count <= bytes.count else { return nil }
            for k in 0..<l.count where bytes[start + k] != l[k] { return nil }
            return start + l.count
        }
        if let e = match("true") { return ("true", e) }
        if let e = match("false") { return ("false", e) }
        if let e = match("null") { return ("null", e) }
        return nil
    }

    /// Scan a JSON number at `from` and return its CANONICAL emission — byte-identical to
    /// what `fragment(for:)` produces (an INTEGER literal → `String(int64Value)`; a literal
    /// with `.`/`e`/`E` → `doubleFragment(Double(...))`) — plus the index past the number.
    /// Returns `nil` (→ fall back) for anything that can't be canonicalized exactly: an
    /// integer that overflows `Int64`, a non-finite/over-precision double, or a malformed
    /// token. This MIRRORS JSONSerialization's int-vs-float decision (presence of `.`/`e`/`E`).
    private static func scanNumberCanonical(_ bytes: [UInt8], from start: Int) -> (String, Int)? {
        let n = bytes.count
        var i = start
        var isFloat = false
        if i < n, bytes[i] == UInt8(ascii: "-") { i += 1 }
        let digitsStart = i
        while i < n, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { i += 1 }
        if i == digitsStart { return nil }   // need ≥1 integer digit
        // JSON's integer grammar forbids a LEADING ZERO (`00`/`01` are invalid — and
        // JSONSerialization REJECTS the whole object, so `merge` would return the OTHER
        // side). Reject a multi-digit run that starts with `0` so the splice falls back
        // and reproduces that rejection, never canonicalizing an invalid number.
        if bytes[digitsStart] == UInt8(ascii: "0"), i - digitsStart > 1 { return nil }
        if i < n, bytes[i] == UInt8(ascii: ".") {
            isFloat = true
            i += 1
            let fracStart = i
            while i < n, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { i += 1 }
            if i == fracStart { return nil }   // a `.` with no fraction digit is malformed
        }
        if i < n, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            isFloat = true
            i += 1
            if i < n, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            let expStart = i
            while i < n, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { i += 1 }
            if i == expStart { return nil }
        }
        let literal = String(decoding: bytes[start..<i], as: UTF8.self)
        if isFloat {
            guard let d = Double(literal), d.isFinite else { return nil }
            // Replicate fragment(for:)'s float branch EXACTLY: scalarJSONFragment(doubleValue)
            // → doubleFragment. (Cross-check below guards the rare String(Double) rounding.)
            let canon = PatchInstanceInputs.scalarJSONFragment(d) ?? ""
            // SAFETY NET: only accept if re-parsing the canonical form yields the SAME Double
            // JSONSerialization would have produced (both go through Double(String)), so the
            // splice can't diverge from the slow path's number formatting. Equal-or-fall-back.
            guard let back = Double(canon), back == d || (back.isNaN && d.isNaN) else { return nil }
            return (canon, i)
        } else {
            // INTEGER literal: fragment(for:) emits String(n.int64Value). JSON forbids leading
            // zeros / leading `+`, but `-0` is legal and canonicalizes to `0` — Int64("-0")==0
            // → String → "0", matching. Overflow ⇒ fall back (JSONSerialization would make it a
            // Double, a different branch).
            guard let v = Int64(literal) else { return nil }
            return (String(v), i)
        }
    }

    static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func serialize(_ obj: [String: Any]) -> String {
        var fragments: [(key: String, json: String)] = []
        for (k, v) in obj {
            guard let frag = fragment(for: v) else { continue }
            fragments.append((k, frag))
        }
        fragments.sort { $0.key < $1.key }
        return "{" + fragments.map {
            "\(PatchInstanceInputs.quotedJSONString($0.key)):\($0.json)"
        }.joined(separator: ",") + "}"
    }

    /// A JSON fragment for any `JSONSerialization`-decoded value — scalars AND
    /// nested objects/arrays/null. The merge can now carry a non-scalar input
    /// (a struct/array `@State`) through unchanged instead of dropping it.
    private static func fragment(for value: Any) -> String? {
        // JSONSerialization yields NSNumber/NSString; disambiguate Bool first
        // (a Bool NSNumber would otherwise match the numeric casts).
        if value is NSNull { return "null" }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            // BUG #73: a large integral @State (> 2^53) merged through here must keep its
            // exact value — emitting `scalarJSONFragment(n.doubleValue)` would round it to
            // a 53-bit Double (and `doubleFragment`'s 1e15 cap then prints a `.0` the guest's
            // `_patchScanInt` rejects → the @State reverts). When JSONSerialization parsed an
            // INTEGER, emit its exact `int64Value` verbatim; only floats go through Double.
            if !CFNumberIsFloatType(n) {
                return String(n.int64Value)
            }
            return PatchInstanceInputs.scalarJSONFragment(n.doubleValue)
        }
        if let s = value as? String { return PatchInstanceInputs.quotedJSONString(s) }
        if let obj = value as? [String: Any] { return serialize(obj) }
        if let arr = value as? [Any] {
            let parts = arr.compactMap { fragment(for: $0) }
            // Preserve element count: if any element couldn't serialize, bail rather
            // than silently shorten the array.
            guard parts.count == arr.count else { return nil }
            return "[" + parts.joined(separator: ",") + "]"
        }
        return nil
    }

    /// A JSON fragment string for a non-scalar `JSONSerialization` value (object /
    /// array / null) — the input to a wrapper's Codable write-back. Returns nil for
    /// a scalar (those take the cheap scalar write-back path instead).
    static func fragmentForWriteback(_ value: Any) -> String? {
        if value is [String: Any] || value is [Any] || value is NSNull {
            return fragment(for: value)
        }
        return nil
    }

    /// Whether a freshly-dispatched guest value equals the current native value
    /// (used to suppress no-op write-backs).
    static func scalarEqual(_ a: Any?, _ b: Any) -> Bool {
        guard let a else { return false }
        switch (a, b) {
        case let (x as String, y as String): return x == y
        case let (x as Bool, y as Bool): return x == y
        default:
            // BUG R2-#98/#99: a large integral value (> 2^53, e.g. a snowflake id /
            // epoch-ms) must NOT compare through `numeric()`'s `Double` cast — that
            // collapses 9007199254740993 to …992.0, so a real write-back to such a
            // value is wrongly suppressed as a no-op (the @State never updates / snaps
            // back). When BOTH sides are genuine fixed-width integers, compare them
            // exactly first; only fall back to the Double compare when at least one
            // side is genuinely floating. Mirrors the int-first ordering in `unbox`.
            if let xi = integerValue(a), let yi = integerValue(b) { return xi == yi }
            // Numeric cross-family compare (Int vs NSNumber-double etc.).
            if let xa = numeric(a), let xb = numeric(b) { return xa == xb }
            return false
        }
    }

    /// The exact integer value of `v` IF it bridges to a fixed-width integer (Int /
    /// Int32 / Int64 / UInt / a non-float `NSNumber`), else nil (a genuine float,
    /// String, etc.). Used by `scalarEqual` to compare large integral values without
    /// the lossy `Double` round-trip (bug R2-#98/#99). `UInt64` above `Int64.max`
    /// returns nil (rare; falls back to the Double compare).
    private static func integerValue(_ v: Any) -> Int64? {
        switch v {
        case is Bool: return nil
        case let i as Int: return Int64(i)
        case let i as Int32: return Int64(i)
        case let i as Int64: return i
        case let u as UInt: return u <= UInt(Int64.max) ? Int64(u) : nil
        case let u as UInt64: return u <= UInt64(Int64.max) ? Int64(u) : nil
        case let n as NSNumber:
            // Boolean NSNumbers are not integers here; a FLOAT NSNumber must go through
            // the Double path (it may carry a fractional value).
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            if CFNumberIsFloatType(n) { return nil }
            return n.int64Value
        default: return nil
        }
    }

    private static func numeric(_ v: Any) -> Double? {
        switch v {
        case let b as Bool: _ = b; return nil
        case let i as Int: return Double(i)
        case let i as Int32: return Double(i)
        case let i as Int64: return Double(i)
        case let u as UInt: return Double(u)
        case let d as Double: return d
        case let f as Float: return Double(f)
        case let c as CGFloat: return Double(c)
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.doubleValue
        default: return nil
        }
    }
}

// MARK: - Render-input memoization (P0 perf)

/// The six pre-collected id-sets a render needs from the (WASM-derived) tree. Caching
/// these alongside the tree lets a cache HIT skip the 6 `collect*IDs` full-tree walks as
/// well as the WASM invoke+decode. They are a pure deterministic function of the tree
/// (value types, `Sendable`), so reusing them on an identical-input hit is sound.
struct PatchedBodyIDSets: Sendable {
    let opaque: [String]
    let token: [String]
    let row: [String]
    let action: [String]
    let effect: [String]
    let button: [String]
    /// The watched `@State` names of every `.animation(_:value:)` modifier in the tree
    /// (the `valueKey`s). The host resolves each key's CURRENT scalar from the input JSON
    /// and hands the renderer an `AnyHashable` trigger so the value-keyed animation fires
    /// on change. Unlike the slot/token id-sets this is NOT a demote gate: a key whose
    /// scalar can't be resolved degrades to a constant trigger in the renderer (the curve
    /// still attaches; the view stays patched), so an `.animation`-using view never demotes
    /// for an unresolved value.
    let animationValueKeys: [String]
}

/// The WASM-DERIVED payload memoized per render input. Holds ONLY data the guest body
/// produced as a deterministic function of its input string — the decoded `ViewNode`
/// tree, the parameterized-slot `slotArgs`, and the pre-collected id-sets. It NEVER holds
/// the per-instance native closures (slots/tokens/rowSlots/actionSlots/effectSlots), which
/// come from the LIVE instance each render and must not be cached (correctness invariant #2).
struct PatchedBodyCacheEntry: Sendable {
    let tree: ViewNode
    let slotArgs: [String: [String]]
    let idSets: PatchedBodyIDSets
}

/// A MainActor-isolated, bounded, epoch-scoped memoization cache for the render hot path.
///
/// SwiftUI re-evaluates `body` constantly with byte-identical state, paying the full
/// WASM-invoke + JSON-decode + 6 tree-walk cost each time even though the guest body is a
/// DETERMINISTIC function of its input. This cache keys WASM-derived output by the EXACT
/// final input string (plus typeName/export/moduleEpoch) so a steady-state render reuses
/// the decoded tree instead of recomputing it.
///
/// Correctness:
///  * Keyed by the FULL input string (not a lossy hash) — looked up via a strong hash
///    bucket, then a byte-exact `inputString` compare on the candidate, so a hash collision
///    can NEVER return the wrong tree (invariant #1).
///  * `moduleEpoch` is part of the key; entries from any other epoch are dropped on access
///    (a hot-swap changes the WASM, so a stale-epoch tree must never be reused — invariant #1/#3).
///  * Stores ONLY WASM-derived data (invariant #2).
///  * Bounded per (typeName, export) via a tiny LRU (steady state has ~1 distinct input),
///    so memory can't grow unbounded (invariant #3).
///  * MainActor-isolated — `PatchedBodyHost.body` runs on the MainActor, so all access is
///    serialized with no lock (invariant #4).
@MainActor
final class PatchedBodyRenderCache {
    static let shared = PatchedBodyRenderCache()

    /// Per (typeName,export) LRU capacity. Steady state holds ~1 distinct input; 4 absorbs
    /// a small amount of input churn (e.g. a value oscillating between a few states) without
    /// letting any one view's cache grow unbounded.
    static let capacityPerScope = 4

    /// A bucket of cached entries for one (typeName, export) scope. `order` is the LRU
    /// recency list (front = most recent). Each entry remembers the EXACT input string +
    /// the epoch it was produced under for a collision-proof, epoch-exact match on lookup.
    private struct Stored {
        var inputString: String
        var epoch: UInt64
        var payload: PatchedBodyCacheEntry
    }
    private struct Bucket {
        var entries: [Int: [Stored]] = [:]   // strong-hash bucket → candidates (collision-safe)
        var order: [String] = []             // LRU recency by inputString (front = MRU)
    }

    private var scopes: [String: Bucket] = [:]

    private func scopeKey(typeName: String, export: String) -> String { typeName + "\u{1}" + export }

    /// Look up a cached payload for (typeName, export, input, epoch). Returns nil on a miss.
    /// A hit also refreshes LRU recency. Entries from a DIFFERENT epoch are never returned
    /// (and are dropped lazily on the next store for that scope).
    func lookup(typeName: String, export: String, input: String, epoch: UInt64) -> PatchedBodyCacheEntry? {
        let sk = scopeKey(typeName: typeName, export: export)
        guard var bucket = scopes[sk] else { return nil }
        let h = input.hashValue
        guard let candidates = bucket.entries[h] else { return nil }
        // Byte-exact + epoch-exact match (collision-proof; cross-epoch never reused).
        for cand in candidates where cand.epoch == epoch && cand.inputString == input {
            // Refresh LRU recency.
            if let idx = bucket.order.firstIndex(of: input) { bucket.order.remove(at: idx) }
            bucket.order.insert(input, at: 0)
            scopes[sk] = bucket
            return cand.payload
        }
        return nil
    }

    /// Store a WASM-derived payload for (typeName, export, input, epoch). Drops any entries
    /// from a stale epoch in this scope, then enforces the per-scope LRU bound.
    func store(typeName: String, export: String, input: String, epoch: UInt64,
               payload: PatchedBodyCacheEntry) {
        let sk = scopeKey(typeName: typeName, export: export)
        var bucket = scopes[sk] ?? Bucket()

        // Epoch invalidation: a hot-swap bumps the epoch, so any entry from a different
        // epoch is stale WASM output — drop the whole scope's contents before storing.
        if let firstEpoch = bucket.entries.values.first?.first?.epoch, firstEpoch != epoch {
            bucket = Bucket()
        }

        let h = input.hashValue
        var candidates = bucket.entries[h] ?? []
        // Replace an existing same-input candidate (same epoch by construction here).
        candidates.removeAll { $0.inputString == input }
        candidates.append(Stored(inputString: input, epoch: epoch, payload: payload))
        bucket.entries[h] = candidates

        // Recency: move this input to the front.
        if let idx = bucket.order.firstIndex(of: input) { bucket.order.remove(at: idx) }
        bucket.order.insert(input, at: 0)

        // Enforce the LRU bound: evict least-recently-used inputs beyond capacity.
        while bucket.order.count > Self.capacityPerScope {
            let victim = bucket.order.removeLast()
            let vh = victim.hashValue
            if var c = bucket.entries[vh] {
                c.removeAll { $0.inputString == victim }
                if c.isEmpty { bucket.entries[vh] = nil } else { bucket.entries[vh] = c }
            }
        }
        scopes[sk] = bucket
    }

    /// Test-only: current number of distinct cached inputs for a scope (== `order.count`).
    func entryCount(typeName: String, export: String) -> Int {
        scopes[scopeKey(typeName: typeName, export: export)]?.order.count ?? 0
    }

    /// Test-only: drop everything (so a test starts from a clean cache).
    func reset() { scopes.removeAll() }
}

// MARK: - Structurally-static template cache

/// A decoded ViewNode tree cached for a view the engine proved STRUCTURALLY STATIC
/// (identical tree regardless of inputs). Keyed by (typeName, export, moduleEpoch):
/// a hot-swap bumps the epoch and invalidates all entries (the new module may have
/// a different tree). Per-(typeName,export) so a static view's template is stored ONCE
/// and reused across all instances and all input values — the tree is a pure constant.
///
/// Correctness:
///  * Only populated when `entry.isStructurallyStatic == true` (engine opt-in, engine
///    proved the invariant — conservative, demote-safe).
///  * `moduleEpoch` is part of the key; a hot-swap bumps the epoch → the entry is a
///    MISS on the next call → WASM runs once to re-prime the cache (invariant #1).
///  * Stores ONLY WASM-derived data (tree/slotArgs/idSets) — the live native slot
///    closures/tokens/rowSlots are filled from `self` on every render, exactly as
///    with the input-hash cache (invariant #2).
///  * MainActor-isolated: `PatchedBodyHost.body` runs on the MainActor, so all
///    access is serialized with no lock (invariant #3).
@MainActor
final class PatchedBodyStaticTemplateCache {
    static let shared = PatchedBodyStaticTemplateCache()

    private struct Key: Hashable {
        let typeName: String
        let export: String
        let epoch: UInt64
    }

    private var cache: [Key: PatchedBodyCacheEntry] = [:]

    /// Look up the cached template for (typeName, export, epoch). Returns nil on a miss.
    func lookup(typeName: String, export: String, epoch: UInt64) -> PatchedBodyCacheEntry? {
        cache[Key(typeName: typeName, export: export, epoch: epoch)]
    }

    /// Store the template for (typeName, export, epoch). An existing entry for the
    /// same key is replaced (idempotent — the static tree is the same on every call).
    func store(typeName: String, export: String, epoch: UInt64, payload: PatchedBodyCacheEntry) {
        cache[Key(typeName: typeName, export: export, epoch: epoch)] = payload
    }

    /// Test-only: drop everything (so a test starts from a clean cache).
    func reset() { cache.removeAll() }

    /// Test-only: count of cached entries.
    var count: Int { cache.count }
}

// MARK: - The patched-body host view

/// A mutable holder for the last successfully-rendered tree (bug #50). A class (not
/// `@State`) so `PatchedBodyHost.body` can record into it without mutating observed
/// SwiftUI state mid-evaluation. MainActor-confined: only touched from `body`.
@MainActor
final class LastGoodTreeBox {
    var tree: ViewNode?
    var context: RenderContext?
    init() {}
}

/// The view a generated thunk returns when its type is patched: renders the
/// guest's lowered body and runs the full interactive loop against the LIVE
/// native instance's inputs.
///
///   * `propsJSON` is re-marshalled on every thunk evaluation, so native prop
///     changes flow into the guest tree like any SwiftUI data flow.
///   * `guestState` (SwiftUI-owned, identity-stable) carries the guest's
///     authoritative state-model fields after interactions; it OVERRIDES the
///     marshalled snapshot of those fields.
///   * Guest state changes write back into the native `@State`/`@AppStorage`/
///     `@Binding` storage, keeping persistence and unpatched UI coherent.
///   * Buttons auto-wire: a lowered `Button`'s actionID dispatches into the
///     guest as an event (the engine emits the matching UPDATE rule).
///   * Failure demotes the view type for this module epoch and renders the
///     native body from the next evaluation on.
@MainActor
public struct PatchedBodyHost: View {
    let typeName: String
    let entry: PatchViewManifest.Entry
    let propsJSON: String
    let writebacks: [PatchScalarWriteback]
    /// Native renderers for this view's non-lowerable leaves (mixed views), keyed
    /// by the shipped tree's opaque-slot id. Each is a FACTORY `([String]) -> AnyView`:
    /// a PARAMETERIZED leaf (a slotted custom view whose string-literal args were
    /// lifted) substitutes the runtime values from the emission's `slotArgs` into its
    /// template; a plain leaf ignores its args. Empty for a fully-lowered view.
    let slots: [String: ([String]) -> AnyView]
    /// Resolved DESIGN-SYSTEM TOKEN values (`Color`/`Font`) for this view's
    /// `.hostToken(id)`/`.fontToken(id)` modifier values, keyed by the shipped tree's
    /// token id. Empty for a view that uses no design-system tokens.
    let tokens: [String: PatchHostToken]
    /// PER-ROW INDEXED NATIVE-ACTION SLOTS for this view's `.indexedForEachSlot` nodes,
    /// keyed by the shipped tree's slot id. Each carries the host-evaluated row count
    /// (`collection.count`) + a per-row factory `(Int) -> AnyView` (the thunk's, closing
    /// over `self`). Empty for a view with no body-local-collection per-row slots.
    let rowSlots: [String: PatchRowSlot]
    /// NATIVE-ACTION SLOTS for this view's `.actionSlotButton` nodes, keyed by the shipped
    /// tree's slot id. Each is the action closure `() -> Void` (the thunk's, closing over
    /// `self`) for an actions-list Button whose action is a native method call. Empty for a
    /// view with no action slots.
    let actionSlots: [String: () -> Void]
    /// NATIVE EFFECT-MODIFIER SLOTS for this view's `.nativeEffectSlot` modifiers, keyed by the
    /// shipped tree's slot id. Each is the effect-application closure `(AnyView) -> AnyView` (the
    /// thunk's, closing over `self`) that applies the real `.task`/`.onAppear`/gesture/etc.
    /// modifier expression to its rendered subtree. Empty for a view with no native effect slots.
    let effectSlots: [String: (AnyView) -> AnyView]

    @State private var guestState: String = ""
    /// The freshly-marshalled native props snapshot captured at the moment the guest
    /// last emitted `guestState`. Used to RECONCILE a dual-owned field (bug #49/#52):
    /// a `@Binding`/`@AppStorage`/`@State` the guest control mutates AND native code
    /// (a parent "Reset", a `Timer`, `.onReceive`) also changes. If the current
    /// `propsJSON` value for a guest-owned key has moved AWAY from this baseline, native
    /// changed it after the guest's last write → the guest override for that key is
    /// STALE and must yield to the live native value (else the view shows the old guest
    /// value forever). Empty until the first dispatch.
    @State private var guestBaseline: String = ""
    /// The LAST tree this host rendered successfully (decoded + all safety nets passed),
    /// retained so a later FAILURE pass shows the last-known-good patched content instead
    /// of a blank `EmptyView` (bug #50). On iOS 17+ a demote also bumps the Observation
    /// signal, re-evaluating the thunk → the native branch; but on iOS 16 (no Observation)
    /// nothing forces that re-evaluation, so without this the screen would go BLANK until
    /// an unrelated state change re-rendered the parent. Showing the last good tree keeps
    /// the view populated on every OS while the demote propagates — never wrong NEW content
    /// (it's exactly what last rendered correctly). A reference box (not `@State`) so
    /// recording it inside `body` doesn't mutate observed state mid-evaluation.
    private let lastGood = LastGoodTreeBox()

    init(typeName: String, entry: PatchViewManifest.Entry, propsJSON: String,
         writebacks: [PatchScalarWriteback], slots: [String: ([String]) -> AnyView] = [:],
         tokens: [String: PatchHostToken] = [:],
         rowSlots: [String: PatchRowSlot] = [:],
         actionSlots: [String: () -> Void] = [:],
         effectSlots: [String: (AnyView) -> AnyView] = [:]) {
        self.typeName = typeName
        self.entry = entry
        self.propsJSON = propsJSON
        self.writebacks = writebacks
        self.slots = slots
        self.tokens = tokens
        self.rowSlots = rowSlots
        self.actionSlots = actionSlots
        self.effectSlots = effectSlots
    }

    public var body: some View {
        // The module epoch THIS render runs under — tag every deferred `markFailed` with
        // it so a demote scheduled here can't false-demote a view freshly loaded by a
        // later hot-swap (bug #72).
        let renderEpoch = Patch.shared.moduleEpoch
        // RECONCILE dual-owned state (bug #49/#52): drop any guest-owned key whose live
        // native value has moved away from the baseline captured at the guest's last
        // write — native code (a parent "Reset", a Timer, `.onReceive`) changed it and
        // must win, rather than the stale guest value masking it forever.
        let effectiveGuestState = Self.reconcileGuestOverride(
            guestState: guestState, baseline: guestBaseline, currentProps: propsJSON)
        var merged = PatchFlatJSON.merge(base: propsJSON, override: effectiveGuestState)
        // INPUT-RIDING HOST TOKENS: a `Theme.Radius.lg`-style NUMERIC constant the guest
        // consumes inside a `.cornerRadius(…)`/`.padding(…)`/`frame` position, and a
        // host STRING (an enum's computed-String `Text(…)` content like `confidence.label`)
        // the guest reads as text. The thunk resolved each natively; merge them into the
        // guest's input JSON under their reserved `__numtok_<id>`/`__strtok_<id>` keys
        // BEFORE building the tree, exactly like a `__geo_*` input. (Color/font tokens are
        // applied by the renderer over the tree instead — handled below.)
        let inputTokenJSON = Self.inputTokenJSON(from: tokens)
        if let inputTokenJSON {
            merged = PatchFlatJSON.merge(base: merged, override: inputTokenJSON)
        }
        let tree: ViewNode
        // PARAMETERIZED NATIVE SLOTS: the guest's emission carries `slotArgs` (slot id
        // → lifted string-literal values that ride WASM). A parameterized native slot
        // is rendered via the thunk's factory applied to THESE values, so an OTA patch
        // that only edited a string in a slotted custom view shows the new string.
        let slotArgs: [String: [String]]
        // The six pre-collected id-sets (opaque/token/row/action/effect/button). Computed
        // once per distinct input and reused on a cache hit, skipping the 6 full-tree walks.
        let idSets: PatchedBodyIDSets
        // STRUCTURALLY-STATIC TEMPLATE CACHE (perf — zero WASM after first render):
        // when the engine proved this view's WASM tree is identical for ALL inputs, we
        // run WASM ONCE and cache the tree keyed by (typeName, export, epoch) — no input
        // string needed. Subsequent renders skip WASM entirely. A hot-swap bumps the epoch
        // → a MISS → WASM runs once to re-prime, then the template is cached again.
        // SAFETY: only applied when `entry.isStructurallyStatic == true` (engine opt-in;
        // conservative detection). The input-hash cache below is still checked + populated
        // for the general case — the static path is strictly a faster route for the views
        // the engine provably identified as constant-tree.
        if entry.isStructurallyStatic == true,
           let staticEntry = PatchedBodyStaticTemplateCache.shared.lookup(
               typeName: typeName, export: entry.export, epoch: renderEpoch) {
            // Static cache HIT: tree is a constant — reuse it with zero WASM.
            tree = staticEntry.tree
            slotArgs = staticEntry.slotArgs
            idSets = staticEntry.idSets
        } else {
        // INPUT-HASH MEMOIZATION (P0 perf): the guest body is a DETERMINISTIC function of
        // its input string, so a byte-identical `merged` (the common steady-state case in
        // SwiftUI — body re-evaluates constantly with unchanged state) yields a byte-
        // identical tree. Reuse the cached WASM-derived {tree, slotArgs, idSets} instead of
        // re-running the WASM invoke + JSON decode + 6 tree walks. Keyed by the EXACT final
        // input string (+ typeName/export/moduleEpoch); a hot-swap bumps the epoch and
        // invalidates. ONLY WASM-derived data is cached — the live native slot closures are
        // filled below from `self`, exactly as on a miss.
        if let cached = PatchedBodyRenderCache.shared.lookup(
            typeName: typeName, export: entry.export, input: merged, epoch: renderEpoch) {
            tree = cached.tree
            slotArgs = cached.slotArgs
            idSets = cached.idSets
        } else {
            do {
                let emission = try Patch.shared.viewBodyEmission(state: merged, export: entry.export)
                tree = emission.root
                slotArgs = emission.slotArgs ?? [:]
            } catch {
                // Demote OUTSIDE this view-update pass; the next thunk evaluation takes the
                // native branch (iOS 17+ via the Observation bump). This pass shows the last
                // good tree if any (so the view doesn't go BLANK on iOS 16 — bug #50).
                let name = typeName
                let ep = renderEpoch
                Task { @MainActor in
                    PatchViewPatchRegistry.shared.markFailed(typeName: name, forEpoch: ep)
                }
                return demoteFallback()
            }
            // Collect the six id-sets (+ animation keys) ONCE for this fresh tree in a SINGLE
            // traversal (T2), then cache them with the tree so an identical-input render skips
            // both the WASM stage AND these walks. `collectAllIDs` is the multiset-identical,
            // false-render-safe equivalent of the six separate collectors (proven by
            // RenderHotPathPerfRoundTests) — pure speed, no behavior change — and matters at
            // real-screen node counts where 6 passes cost ~6× one pass.
            idSets = Self.collectAllIDs(tree)
            let cachePayload = PatchedBodyCacheEntry(tree: tree, slotArgs: slotArgs, idSets: idSets)
            PatchedBodyRenderCache.shared.store(
                typeName: typeName, export: entry.export, input: merged, epoch: renderEpoch,
                payload: cachePayload)
            // STRUCTURALLY-STATIC TEMPLATE CACHE PRIME: if this view is static and we just
            // ran WASM (a static-cache miss, i.e. the first render or post-hot-swap), store
            // the result as the template for (typeName, export, epoch). Future renders skip
            // WASM entirely — the tree is identical regardless of input.
            if entry.isStructurallyStatic == true {
                PatchedBodyStaticTemplateCache.shared.store(
                    typeName: typeName, export: entry.export, epoch: renderEpoch,
                    payload: cachePayload)
            }
        }
        } // end static-template cache else-branch

        // MIXED-VIEW SAFETY NET: every opaque leaf in the tree must have a native
        // slot closure. If a patch introduced a leaf with no matching slot (i.e. it
        // changed native code that isn't in the installed build), we cannot render
        // it — DEMOTE the whole view to native rather than show a hole. (A patch
        // that only changes the lowered structure keeps the same leaf ids, so this
        // never trips for text/modifier/layout/rearrange edits.)
        let neededIDs = idSets.opaque
        let uncovered = neededIDs.filter { slots[$0] == nil }
        if !uncovered.isEmpty {
            let name = typeName
            let ep = renderEpoch
            Task { @MainActor in PatchViewPatchRegistry.shared.markFailed(typeName: name, forEpoch: ep) }
            return demoteFallback()
        }

        // DESIGN-SYSTEM TOKEN SAFETY NET: every `.hostToken(id)` color / `.fontToken(id)`
        // font in the tree must have a resolved value from the thunk's `__patchTokens()`.
        // If a patch introduced a token id the installed build doesn't supply (it changed
        // native token code that isn't compiled in), we can't resolve it — DEMOTE the whole
        // view rather than render a wrong/placeholder color. A patch that only re-arranges
        // the lowered structure keeps the same token ids, so this never trips for ordinary
        // text/layout/color-reselect edits among the build's enumerated tokens.
        let neededTokenIDs = idSets.token
        let uncoveredTokens = neededTokenIDs.filter { tokens[$0] == nil }
        if !uncoveredTokens.isEmpty {
            let name = typeName
            let ep = renderEpoch
            Task { @MainActor in PatchViewPatchRegistry.shared.markFailed(typeName: name, forEpoch: ep) }
            return demoteFallback()
        }

        // PER-ROW INDEXED SLOT SAFETY NET: every `.indexedForEachSlot(id:…)` node in the
        // tree must have a per-row factory + count from the thunk's `__patchRowSlots()`.
        // If a patch introduced an indexed-slot id the installed build doesn't supply (it
        // changed native row code that isn't compiled in), we can't render the rows —
        // DEMOTE the whole view rather than show a hole. A patch that only re-arranges the
        // lowered structure keeps the same slot ids, so this never trips for ordinary edits.
        let neededRowIDs = idSets.row
        let uncoveredRows = neededRowIDs.filter { rowSlots[$0] == nil }
        if !uncoveredRows.isEmpty {
            let name = typeName
            let ep = renderEpoch
            Task { @MainActor in PatchViewPatchRegistry.shared.markFailed(typeName: name, forEpoch: ep) }
            return demoteFallback()
        }

        // NATIVE-ACTION SLOT SAFETY NET: every `.actionSlotButton(id:…)` node in the tree must
        // have an action closure from the thunk's `__patchActionSlots()`. If a patch introduced an
        // action-slot id the installed build doesn't supply (it changed native action code that
        // isn't compiled in), we can't supply the closure — DEMOTE the whole view rather than ship
        // a Button that does NOTHING on tap (the worst outcome: the OLD native view silently runs).
        // A patch that only re-arranges the lowered structure / edits a button LABEL keeps the same
        // slot ids, so this never trips for ordinary text/layout edits.
        let neededActionIDs = idSets.action
        let uncoveredActions = neededActionIDs.filter { actionSlots[$0] == nil }
        if !uncoveredActions.isEmpty {
            let name = typeName
            let ep = renderEpoch
            Task { @MainActor in PatchViewPatchRegistry.shared.markFailed(typeName: name, forEpoch: ep) }
            return demoteFallback()
        }

        // NATIVE EFFECT-MODIFIER SLOT SAFETY NET: every `.nativeEffectSlot(id)` modifier in the
        // tree must have an effect-application closure from the thunk's `__patchEffectSlots()`. If a
        // patch introduced an effect-slot id the installed build doesn't supply (it changed native
        // effect code that isn't compiled in), we can't apply the modifier — DEMOTE the whole view
        // rather than strip a body whose `.task`/`.onAppear`/gesture/etc. we can't supply (which
        // would silently re-show the OLD native view, the dev's edit lost — the WORST outcome). A
        // patch that only re-arranges the lowered structure / edits text keeps the same slot ids,
        // so this never trips for ordinary edits.
        let neededEffectIDs = idSets.effect
        let uncoveredEffects = neededEffectIDs.filter { effectSlots[$0] == nil }
        if !uncoveredEffects.isEmpty {
            let name = typeName
            let ep = renderEpoch
            Task { @MainActor in PatchViewPatchRegistry.shared.markFailed(typeName: name, forEpoch: ep) }
            return demoteFallback()
        }

        var context = RenderContext(showOpaqueStubs: false)
        // Fill the renderer's opaque table with the native leaf renderers. A
        // PARAMETERIZED slot's factory is applied to the emission's `slotArgs[id]`
        // (the CURRENT, possibly OTA-edited, string-literal values); a plain slot's
        // factory ignores its (empty) args. Missing args default to `[]` → a
        // parameterized factory's arg-count guard returns EmptyView (demote-safe,
        // never a crash); but a parameterized slot always ships its args in the
        // same emission, so this only bites a genuinely malformed tree.
        for id in neededIDs {
            if let make = slots[id] { context.opaques.set(id, make(slotArgs[id] ?? [])) }
        }
        // Fill the renderer's token table with the resolved design-system token values.
        for id in neededTokenIDs { if let tok = tokens[id] { context.tokens.set(id, tok) } }
        // Fill the renderer's per-row indexed-slot table: each carries the host-evaluated
        // row count + the thunk's per-row factory (closing over `self`, so each row's real
        // per-row native action works). The renderer reconstitutes `count` rows.
        for id in neededRowIDs {
            if let slot = rowSlots[id] {
                context.rowSlots.set(id, count: slot.count, factory: slot.factory)
            }
        }
        // Fill the renderer's native-action-slot table: each is the thunk's `() -> Void` (closing
        // over `self`, so the real native method call runs faithfully) for an actions-list Button.
        for id in neededActionIDs {
            if let action = actionSlots[id] { context.actionSlots.set(id, action) }
        }
        // Fill the renderer's native effect-slot table: each is the thunk's `(AnyView) -> AnyView`
        // (closing over `self`, so the real native `.task`/`.onAppear`/gesture/etc. runs faithfully)
        // applied to the modified subtree.
        for id in neededEffectIDs {
            if let applyEffect = effectSlots[id] { context.effectSlots.set(id, applyEffect) }
        }
        // Fill the renderer's `.animation(_:value:)` trigger map: for every animation
        // valueKey in the tree, resolve its CURRENT scalar from the marshalled input JSON
        // (the SAME `merged` blob the @State was marshalled into) as an `AnyHashable`, so a
        // change to that value across renders fires the implicit animation (native behavior).
        // NOT a demote gate — an unresolvable key is simply absent (the renderer degrades to
        // a constant trigger, keeping the view patched). Parse `merged` once only if needed.
        let animKeys = idSets.animationValueKeys
        if !animKeys.isEmpty, let mergedObj = PatchFlatJSON.parse(merged) {
            for key in animKeys {
                if let v = Self.animationTriggerValue(mergedObj[key]) {
                    context.animationValues[key] = v
                }
            }
        }
        // GeometryReader (C): wire a rebuild closure so a `geometryReader` node re-
        // evaluates its lowered child body against the LIVE proxy. On each layout the
        // host merges the proxy's size/frame as reserved `__geo_*` inputs into the
        // current state, re-invokes `view_body`, and returns THIS reader's children
        // (matched by id) from the re-emitted tree. A rebuild failure returns nil and
        // the renderer falls back to the statically-lowered children (demote-safe).
        let geoExport = entry.export
        let geoState = merged
        // The coverage the host's tables actually provide — the GeometryReader rebuild
        // must NOT return re-emitted children carrying an id outside these sets (bug #22).
        let coveredSlotIDs = Set(slots.keys)
        let coveredTokenIDs = Set(tokens.keys)
        let coveredRowIDs = Set(rowSlots.keys)
        let coveredActionIDs = Set(actionSlots.keys)
        let coveredEffectIDs = Set(effectSlots.keys)
        let geoName = typeName
        let geoEpoch = renderEpoch
        context.geometryRebuild = GeometryRebuild { gid, w, h, minX, minY in
            let geoJSON = "{\"__geo_width\":\(Self.numJSON(w)),\"__geo_height\":\(Self.numJSON(h)),"
                + "\"__geo_minX\":\(Self.numJSON(minX)),\"__geo_minY\":\(Self.numJSON(minY))}"
            let withGeo = PatchFlatJSON.merge(base: geoState, override: geoJSON)
            guard let reTree = try? Patch.shared.viewBody(state: withGeo, export: geoExport),
                  let children = Self.geometryChildren(in: reTree, id: gid) else { return nil }
            // BUG #22: the geometry-dependent re-emit can surface an opaque/token/row-slot
            // leaf the STATIC tree never had (e.g. `if proxy.size.width > 300 { CustomNativeView() }`),
            // for which the host's tables were never filled. Rendering those children here would
            // hit `context.opaques.view(for:)` → nil → EmptyView (a SILENT native hole) instead of
            // demoting. Re-run the safety nets on the re-emitted children: if any id is uncovered,
            // DEMOTE the whole view and fall back to the static children (which we DID cover).
            for child in children {
                let opaqueOK = Self.collectOpaqueIDs(child).allSatisfy { coveredSlotIDs.contains($0) }
                let tokenOK = Self.collectTokenIDs(child).allSatisfy { coveredTokenIDs.contains($0) }
                let rowOK = Self.collectRowSlotIDs(child).allSatisfy { coveredRowIDs.contains($0) }
                let actionOK = Self.collectActionSlotIDs(child).allSatisfy { coveredActionIDs.contains($0) }
                let effectOK = Self.collectEffectSlotIDs(child).allSatisfy { coveredEffectIDs.contains($0) }
                if !(opaqueOK && tokenOK && rowOK && actionOK && effectOK) {
                    Task { @MainActor in
                        PatchViewPatchRegistry.shared.markFailed(typeName: geoName, forEpoch: geoEpoch)
                    }
                    return nil
                }
            }
            return children
        }
        if let dispatchExport = entry.dispatch {
            let stateBinding = $guestState
            let baselineBinding = $guestBaseline
            let props = propsJSON
            let effectiveOverride = effectiveGuestState
            let wbs = writebacks
            let name = typeName
            let dispEpoch = renderEpoch
            // The dispatch rebuilds the tree IN WASM, so its `_patchBuildTree` needs the
            // input-riding token inputs too (a `Double(__numtok_<id>)` numeric token, a
            // `__strtok_<id>` string token) in the rebuilt body.
            let tokJSON = inputTokenJSON
            let dispatcher = Dispatcher { event, value in
                // BUG R2-#39: an alert/confirmationDialog Button action and the auto-
                // dismiss `isPresented = false` both fire SYNCHRONOUSLY through this same
                // closure. If both merge over the render-time `effectiveOverride` snapshot,
                // the second dispatch composes on a STALE base and CLOBBERS the first's
                // write (e.g. `confirmed = true` is reverted by the auto-dismiss). Use the
                // LIVE guest state (`stateBinding.wrappedValue`, just written by the prior
                // synchronous dispatch) as the override base when present, so sequential
                // dispatches accumulate; fall back to the reconciled snapshot on the first
                // dispatch (when no guest write has happened yet).
                let liveOverride = stateBinding.wrappedValue
                let overrideBase = liveOverride.isEmpty ? effectiveOverride : liveOverride
                // Dispatch over the RECONCILED override (so a native-changed dual-owned
                // field feeds the guest its live value, not the stale one — bug #49/#52).
                var current = PatchFlatJSON.merge(base: props, override: overrideBase)
                if let tokJSON { current = PatchFlatJSON.merge(base: current, override: tokJSON) }
                do {
                    let result = try Patch.shared.dispatch(
                        state: current, event: event, value: value, export: dispatchExport)
                    stateBinding.wrappedValue = result.state
                    // Snapshot the native props AS OF this write, so a later native change
                    // to a dual-owned field is detected on the next body eval and the guest
                    // override yields to it (bug #49/#52).
                    baselineBinding.wrappedValue = props
                    Self.applyWritebacks(wbs, newStateJSON: result.state)
                } catch {
                    Task { @MainActor in
                        PatchViewPatchRegistry.shared.markFailed(typeName: name, forEpoch: dispEpoch)
                    }
                }
            }
            context.dispatcher = dispatcher
            // Lowered Buttons carry actionIDs with engine-emitted UPDATE rules
            // keyed by the SAME id — wire each to a guest dispatch event.
            for actionID in idSets.button {
                context.actions.set(actionID) {
                    dispatcher.send(EventID(actionID), .none)
                }
            }
        }
        // Record this fully-validated tree+context as the last-known-good render, so a
        // later failure pass shows it instead of a blank EmptyView (bug #50).
        lastGood.tree = tree
        lastGood.context = context
        return render(tree, context: context)
    }

    /// The view to show on a FAILURE pass (decode error / uncovered slot, token, or row
    /// slot). On iOS 17+ the demote also bumps the Observation signal so the thunk re-
    /// evaluates to native; this rendered fallback covers the gap until then — and is the
    /// ONLY thing keeping an iOS-16 device (no Observation invalidation) from showing a
    /// blank screen (bug #50). Renders the last-known-good tree if one exists, else an
    /// EmptyView (the first-ever eval failed, with nothing good to fall back to).
    private func demoteFallback() -> AnyView {
        if let tree = lastGood.tree, let context = lastGood.context {
            return render(tree, context: context)
        }
        return AnyView(EmptyView())
    }

    /// Reconcile a dual-owned field (bug #49/#52). `guestState` carries the guest's
    /// authoritative state-model after interactions and normally OVERRIDES the
    /// freshly-marshalled native `propsJSON`. But a field that native code ALSO owns
    /// (a `@Binding` the parent resets, a `@State` a Timer/`.onReceive` mutates) would
    /// be masked forever by the stale guest value. So: for each guest-owned key, if the
    /// CURRENT native value differs from the `baseline` captured at the guest's last
    /// write, native changed it AFTER that write → drop the guest override for that key
    /// (the live native value wins). A key whose native value still equals the baseline
    /// keeps its guest override (only the guest touched it). With no baseline yet (no
    /// dispatch has happened) the guest override is empty anyway, so nothing is masked.
    static func reconcileGuestOverride(guestState: String, baseline: String,
                                       currentProps: String) -> String {
        guard !guestState.isEmpty else { return guestState }
        guard let guestObj = PatchFlatJSON.parse(guestState) else { return guestState }
        // No baseline → nothing native could have changed relative to a guest write.
        guard !baseline.isEmpty, let baseObj = PatchFlatJSON.parse(baseline),
              let curObj = PatchFlatJSON.parse(currentProps) else { return guestState }
        var kept: [String: Any] = [:]
        var dropped = false
        for (key, gval) in guestObj {
            let baselineVal = baseObj[key]
            let currentVal = curObj[key]
            // Native moved this key away from the baseline → it's stale; drop the override.
            if !jsonValueEqual(baselineVal, currentVal) {
                dropped = true
                continue
            }
            kept[key] = gval
        }
        guard dropped else { return guestState }
        // Re-serialize the surviving guest overrides via the merge path so the wire
        // shape matches (sorted keys, scalar/object fragments).
        return PatchFlatJSON.merge(base: "{}", override: serializeFlat(kept))
    }

    /// Serialize a parsed flat-JSON dict back to a JSON object string (deterministic
    /// key order), reusing `PatchFlatJSON`'s fragment encoder for scalars/objects.
    private static func serializeFlat(_ obj: [String: Any]) -> String {
        // Round-trip through merge, which re-uses the same fragment encoder.
        // Build via JSONSerialization for nested fidelity, then normalize.
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        // Normalize through parse→merge so number/string fragments match the wire form.
        return PatchFlatJSON.merge(base: "{}", override: s)
    }

    /// Equality of two optional `JSONSerialization` values (both nil → equal; one nil →
    /// not equal). Scalars compare by value (numeric cross-family); objects/arrays by
    /// their normalized JSON string.
    private static func jsonValueEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (x?, y?):
            if PatchFlatJSON.scalarEqual(x, y) { return true }
            // Fall back to normalized-string comparison for nested/object values.
            let fa = PatchFlatJSON.fragmentForWriteback(x) ?? scalarFrag(x)
            let fb = PatchFlatJSON.fragmentForWriteback(y) ?? scalarFrag(y)
            return fa != nil && fa == fb
        }
    }

    private static func scalarFrag(_ v: Any) -> String? {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            if !CFNumberIsFloatType(n) { return String(n.int64Value) }
            return PatchInstanceInputs.scalarJSONFragment(n.doubleValue)
        }
        if let s = v as? String { return PatchInstanceInputs.quotedJSONString(s) }
        return PatchInstanceInputs.scalarJSONFragment(v)
    }

    /// Whether two JSON fragment strings represent the same value, comparing through a
    /// canonical (sorted-key) re-serialization so two encoders' key orderings don't
    /// cause a false inequality. Returns false (NOT equal) if either side can't be
    /// canonicalized — the caller then performs the write rather than wrongly
    /// suppressing it (bug R2-#137 is demote-safe: suppress only on a proven match).
    static func jsonFragmentsEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let ca = canonicalJSON(a), let cb = canonicalJSON(b) else { return false }
        return ca == cb
    }

    /// Re-serialize a JSON fragment with sorted object keys for a stable, comparable
    /// form. Wraps the (possibly top-level scalar) fragment in an array so
    /// `JSONSerialization` — which rejects a bare top-level scalar — accepts it, then
    /// unwraps. Returns nil for an unparseable fragment.
    private static func canonicalJSON(_ s: String) -> String? {
        let wrapped = "[" + s + "]"
        guard let data = wrapped.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: out, encoding: .utf8) else { return nil }
        return str
    }

    static func applyWritebacks(_ writebacks: [PatchScalarWriteback], newStateJSON: String) {
        guard !writebacks.isEmpty,
              let state = PatchFlatJSON.parse(newStateJSON) else { return }
        for wb in writebacks {
            guard let raw = state[wb.key] else { continue }
            if let newValue = unbox(raw) {
                // Scalar field: cheap equality-suppressed scalar write.
                if PatchFlatJSON.scalarEqual(wb.wrapper._patchRead(), newValue) { continue }
                wb.wrapper._patchWrite(newValue)
            } else if let fragment = PatchFlatJSON.fragmentForWriteback(raw) {
                // Non-scalar field (object/array/null): reconstruct the concrete
                // type from its JSON fragment when the wrapper's Value is Decodable.
                // (`_patchWriteJSON` is a no-op for a non-Decodable Value — safe.)
                //
                // BUG R2-#137: suppress a NO-OP non-scalar write so an unchanged
                // struct/array doesn't re-fire `.onChange`/`didSet` on every dispatch.
                // Encode the wrapper's CURRENT value through the SAME encoder used at
                // marshal time and compare it (canonicalized) to the incoming fragment;
                // skip the write when they're equal. If the current value can't be
                // encoded or either side fails to canonicalize, fall through to the
                // unconditional write (never suppress on uncertainty — demote-safe).
                if let current = wb.wrapper._patchRead(),
                   let currentFrag = PatchValueEncoder.encode(current),
                   Self.jsonFragmentsEqual(currentFrag, fragment) {
                    continue
                }
                _ = wb.wrapper._patchWriteJSON(fragment)
            }
        }
    }

    /// JSONSerialization value → the Swift scalar the wrapper write expects.
    private static func unbox(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            // BUG #74: a large integral @State (> 2^53, e.g. a snowflake id / epoch-ms)
            // must NOT funnel through `doubleValue` — that collapses 9007199254740993 to
            // …992, silently corrupting the write-back. When JSONSerialization parsed the
            // value as an INTEGER (not a float), read its exact `int64Value` and unbox an
            // `Int` directly. Only fall back to Double for a genuinely fractional number.
            if !CFNumberIsFloatType(n) {
                return Int(n.int64Value)
            }
            // Integral numbers unbox as Int (covers Int-typed @State); the write
            // closure's `as? Value` cast no-ops on a type mismatch, so also try
            // Double via a second write candidate at the call site if needed.
            let d = n.doubleValue
            if d == d.rounded() && abs(d) < 1e15 { return Int(d) }
            return d
        }
        if let s = value as? String { return s }
        return nil
    }

    nonisolated static func collectButtonActionIDs(_ node: ViewNode) -> [String] {
        var out: [String] = []
        func walk(_ n: ViewNode) {
            if case .button(let actionID, _, _) = n.kind { out.append(actionID) }
            for child in n.childNodes { walk(child) }
            // ALSO recurse into modifier content (sheet/alert/toolbar actions live in
            // a MODIFIER subtree, not `childNodes`) so their Buttons auto-wire too.
            for m in n.modifiers { for child in m.contentNodes { walk(child) } }
        }
        walk(node)
        return out
    }

    // MARK: - Combined single-pass id collection (P0 perf — T2)

    /// The seven id-sets a render needs from the tree, collected in ONE traversal instead
    /// of the six (+ animation) separate full-tree walks. At real-screen node counts
    /// (hundreds of nodes) the six independent walks cost ~6× a single pass; this folds them
    /// into one DFS that fills every set, then packs the result into `PatchedBodyIDSets`.
    ///
    /// CORRECTNESS INVARIANT (proven by `RenderHotPathPerfRoundTests`): the combined result is
    /// EXACTLY the same set of ids — same elements, same multiplicities, NONE added/dropped — as
    /// the six originals + `collectAnimationValueKeys`. Concretely:
    ///   * `opaque`/`row`/`action`/`button` are BYTE-IDENTICAL arrays to their originals (same
    ///     order): the originals are node-first / children-before-modifier-content, which this
    ///     traversal matches exactly.
    ///   * `token`/`effect`/`animation` are MULTISET-IDENTICAL (same ids, possibly a different
    ///     order): their originals recurse modifier-content-before-childNodes, the opposite
    ///     subtree order, which a single DFS cannot also satisfy for the node-first families.
    ///     The differential gate asserts SORTED equality for these three.
    /// ORDER IS PROVABLY IRRELEVANT downstream: every consumer of all seven arrays uses them for
    /// set-membership (`filter { table[$0] == nil }`) or idempotent dict population
    /// (`for id in … { table.set(id, …) }`) — never order-dependent. So multiset-identity is the
    /// real safety-net invariant, and this is a pure speed change with zero behavioral effect.
    ///
    /// (The originals stay defined above — they are the proven reference the differential gate
    /// diffs against, and the geometry-rebuild path still calls the single-type variants on a
    /// per-child basis where a one-shot all-types collection isn't wanted.)
    nonisolated static func collectAllIDs(_ node: ViewNode) -> PatchedBodyIDSets {
        var opaque: [String] = []
        var token: [String] = []
        var row: [String] = []
        var action: [String] = []
        var effect: [String] = []
        var button: [String] = []
        var animation: [String] = []

        func tokenIDs(in m: Modifier, into out: inout [String]) {
            func add(_ c: ColorRef) { if case .hostToken(let id) = c { out.append(id) } }
            func add(_ s: IRShapeStyle) { if case .color(let c) = s { add(c) } }
            switch m {
            case .fontToken(let id): out.append(id)
            case .foregroundColor(let c), .background(let c), .tint(let c): add(c)
            case .accentColor(let c?): add(c)
            case .shadow(let c?, _, _, _): add(c)
            case .foregroundStyle(let layers): for s in layers { add(s) }
            case .backgroundStyle(let s, _), .tintStyle(let s),
                 .fill(let s, _), .stroke(let s, _), .strokeBorder(let s, _),
                 .border(let s, _), .overlayStyle(let s, _): add(s)
            default: break
            }
        }

        func walk(_ n: ViewNode) {
            // Kind-derived ids (mutually-exclusive node kinds) emit PRE-ORDER — matches the
            // node-first originals (opaque/row/action/button), which append before recursing.
            switch n.kind {
            case .opaque(let id, _): opaque.append(id)
            case .indexedForEachSlot(let id, _, _): row.append(id)
            case .actionSlotButton(let id, _, _): action.append(id)
            case .button(let actionID, _, _): button.append(actionID)
            default: break
            }
            // This node's OWN modifier-derived ids (token/effect/animation) emit while scanning
            // `n.modifiers` — matches the modifier-first originals (which scan modifiers before
            // recursing childNodes).
            for m in n.modifiers {
                tokenIDs(in: m, into: &token)
                if case .nativeEffectSlot(let id) = m { effect.append(id) }
                if case .animation(_, let valueKey) = m, !valueKey.isEmpty { animation.append(valueKey) }
            }
            // Recurse childNodes BEFORE modifier content — matches opaque/row/action/button
            // (children-first), and is order-equivalent for token/effect/animation because their
            // originals emit this node's own modifier ids (above) before any subtree, and the
            // remaining subtree ids are membership-only downstream.
            for child in n.childNodes { walk(child) }
            for m in n.modifiers { for child in m.contentNodes { walk(child) } }
        }
        walk(node)
        return PatchedBodyIDSets(opaque: opaque, token: token, row: row, action: action,
                                 effect: effect, button: button, animationValueKeys: animation)
    }

    /// Every `.opaque` node id in the tree — the leaves the thunk must supply a
    /// native slot for (mixed views). Walks both `childNodes` AND modifier content
    /// (a sheet/alert/overlay body's opaque leaf must still be covered).
    nonisolated static func collectOpaqueIDs(_ node: ViewNode) -> [String] {
        var out: [String] = []
        func walk(_ n: ViewNode) {
            if case .opaque(let id, _) = n.kind { out.append(id) }
            for child in n.childNodes { walk(child) }
            for m in n.modifiers { for child in m.contentNodes { walk(child) } }
        }
        walk(node)
        return out
    }

    /// Every `.indexedForeachSlot` node id in the tree — the per-row native-action slots
    /// the thunk must supply a factory + count for. Walks `childNodes` AND modifier
    /// content (an indexed-row slot nested in a sheet/overlay body must still be covered).
    nonisolated static func collectRowSlotIDs(_ node: ViewNode) -> [String] {
        var out: [String] = []
        func walk(_ n: ViewNode) {
            if case .indexedForEachSlot(let id, _, _) = n.kind { out.append(id) }
            for child in n.childNodes { walk(child) }
            for m in n.modifiers { for child in m.contentNodes { walk(child) } }
        }
        walk(node)
        return out
    }

    /// Every `.actionSlotButton` node id in the tree — the NATIVE-ACTION slots the thunk must
    /// supply a `() -> Void` closure for. Walks `childNodes` AND modifier content (an
    /// actions-list Button lives in a `.swipeActions`/`.toolbar`/`.alert`/`Menu`/`.contextMenu`
    /// MODIFIER subtree, NOT `childNodes`), so a slot nested in an actions-list is still covered.
    nonisolated static func collectActionSlotIDs(_ node: ViewNode) -> [String] {
        var out: [String] = []
        func walk(_ n: ViewNode) {
            if case .actionSlotButton(let id, _, _) = n.kind { out.append(id) }
            for child in n.childNodes { walk(child) }
            for m in n.modifiers { for child in m.contentNodes { walk(child) } }
        }
        walk(node)
        return out
    }

    /// Every `.nativeEffectSlot(id)` MODIFIER id in the tree — the native effect-application
    /// closures the thunk must supply a `(AnyView) -> AnyView` for. Unlike the node-based slots,
    /// this walks the MODIFIER list (an effect slot is a modifier, not a node); it also recurses
    /// into `childNodes` AND modifier content (an effect slot on a sheet/overlay body must still
    /// be covered). An uncovered id demotes the whole view (like an opaque leaf / action slot).
    nonisolated static func collectEffectSlotIDs(_ node: ViewNode) -> [String] {
        var out: [String] = []
        func walk(_ n: ViewNode) {
            for m in n.modifiers {
                if case .nativeEffectSlot(let id) = m { out.append(id) }
                for child in m.contentNodes { walk(child) }
            }
            for child in n.childNodes { walk(child) }
        }
        walk(node)
        return out
    }

    /// Every `.animation(_:value:)` `valueKey` in the tree — the watched `@State` names
    /// the renderer needs a CURRENT scalar for (to drive the value-keyed implicit
    /// animation). Walks node modifiers + modifier content + child nodes. NOT a demote
    /// gate: an unresolved key degrades to a constant trigger in the renderer.
    nonisolated static func collectAnimationValueKeys(_ node: ViewNode) -> [String] {
        var out: [String] = []
        func walk(_ n: ViewNode) {
            for m in n.modifiers {
                if case .animation(_, let valueKey) = m, !valueKey.isEmpty { out.append(valueKey) }
                for child in m.contentNodes { walk(child) }
            }
            for child in n.childNodes { walk(child) }
        }
        walk(node)
        return out
    }

    /// Every DESIGN-SYSTEM TOKEN id in the tree (`ColorRef.hostToken(id)` colors and
    /// `Modifier.fontToken(id)` fonts, including a token nested in an `IRShapeStyle.color`
    /// of a `.fill`/`.background(style)`/`.foregroundStyle`/`.stroke`/etc.). The thunk's
    /// `__patchTokens()` must supply each — an uncovered id demotes the whole view (like
    /// an opaque leaf). Walks node modifiers + modifier content + child nodes.
    nonisolated static func collectTokenIDs(_ node: ViewNode) -> [String] {
        var out: [String] = []
        func add(_ c: ColorRef) { if case .hostToken(let id) = c { out.append(id) } }
        func add(_ s: IRShapeStyle) { if case .color(let c) = s { add(c) } }
        func add(_ m: Modifier) {
            switch m {
            case .fontToken(let id): out.append(id)
            case .foregroundColor(let c), .background(let c), .tint(let c): add(c)
            case .accentColor(let c?): add(c)
            case .shadow(let c?, _, _, _): add(c)
            case .foregroundStyle(let layers): for s in layers { add(s) }
            case .backgroundStyle(let s, _), .tintStyle(let s),
                 .fill(let s, _), .stroke(let s, _), .strokeBorder(let s, _),
                 .border(let s, _), .overlayStyle(let s, _): add(s)
            default: break
            }
        }
        func walk(_ n: ViewNode) {
            for m in n.modifiers { add(m); for child in m.contentNodes { walk(child) } }
            for child in n.childNodes { walk(child) }
        }
        walk(node)
        return out
    }

    /// Find the `geometryReader` node with `id` in a re-emitted tree and return its
    /// children (used by the GeometryReader rebuild closure). Walks `childNodes` AND
    /// modifier content so a reader nested in a sheet/overlay body is still found.
    nonisolated static func geometryChildren(in node: ViewNode, id: String) -> [ViewNode]? {
        if case .geometryReader(let nid, let children) = node.kind, nid == id { return children }
        for child in node.childNodes {
            if let found = geometryChildren(in: child, id: id) { return found }
        }
        for m in node.modifiers {
            for child in m.contentNodes {
                if let found = geometryChildren(in: child, id: id) { return found }
            }
        }
        return nil
    }

    /// Convert a `JSONSerialization`-decoded scalar (from the marshalled input JSON) into a
    /// stable `AnyHashable` the renderer uses as a `.animation(_:value:)` `Equatable` trigger.
    /// Handles String/Bool/Int/Double (the marshalled @State scalar shapes) + null; a
    /// non-scalar (object/array @State, which can't be an `.animation` value trigger) or a
    /// missing key returns nil → the renderer degrades to a constant trigger (demote-safe).
    /// Bool is disambiguated BEFORE the numeric casts (an NSNumber Bool would otherwise match),
    /// and an INTEGER value is carried as `Int64` (not a lossy Double) so a counter-style
    /// trigger compares exactly across renders.
    nonisolated static func animationTriggerValue(_ value: Any?) -> AnyHashable? {
        guard let value, !(value is NSNull) else { return nil }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return AnyHashable(n.boolValue) }
            if !CFNumberIsFloatType(n) { return AnyHashable(n.int64Value) }
            return AnyHashable(n.doubleValue)
        }
        if let s = value as? String { return AnyHashable(s) }
        if let b = value as? Bool { return AnyHashable(b) }
        if let i = value as? Int { return AnyHashable(Int64(i)) }
        if let d = value as? Double { return AnyHashable(d) }
        return nil
    }

    /// A flat-JSON number fragment (integral doubles print as ints — matching the
    /// guest's `_patchScanInt`/`_patchScanDouble` tolerance).
    nonisolated static func numJSON(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
        return String(d)
    }

    /// Build the flat JSON object that injects every INPUT-RIDING HOST TOKEN into the
    /// guest's input blob: a `.number` token keyed by its reserved `__numtok_<id>` key
    /// (the guest reads `Double(__numtok_<id>)` in a numeric position) and a `.string`
    /// token keyed by `__strtok_<id>` (the guest reads it as `Text(…)` content). Only
    /// `.number`/`.string` tokens are emitted; color/font tokens ride the rendered tree
    /// instead. Returns nil when there are none (the common case → no extra merge). The
    /// id derivation must match the engine's `numericTokenInputKey`/`stringTokenInputKey`
    /// (`__numtok_`/`__strtok_` + the content-stable hash the thunk keyed the token by).
    nonisolated static func inputTokenJSON(from tokens: [String: PatchHostToken]) -> String? {
        var pieces: [String] = []
        for (id, tok) in tokens {
            switch tok {
            case .number(let value):
                pieces.append("\"__numtok_\(id)\":\(numJSON(value))")
            case .string(let value):
                pieces.append("\"__strtok_\(id)\":\(jsonString(value))")
            case .color, .font:
                continue
            }
        }
        guard !pieces.isEmpty else { return nil }
        return "{" + pieces.joined(separator: ",") + "}"
    }

    /// Minimal JSON string encoder for a host-token String value (the guest's flat-JSON
    /// scanner reads a standard double-quoted JSON string). Escapes the control set the
    /// scanner can choke on: `"`, `\`, and the C0 controls (newline/tab/etc.). This is
    /// the same shape `EmbeddedJSON` emits guest-side, so the scanner round-trips it.
    nonisolated static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

// MARK: - The thunk entry point

extension Patch {
    /// The single call every generated body thunk makes. Returns the patched-body
    /// host when the active module ships a routable body for `typeName`, else nil
    /// (the thunk falls through to the original `body`).
    ///
    /// `slots` is a provider of native renderers for the view's non-lowerable LEAVES
    /// (mixed views) — invoked ONLY when routing, so an unpatched view pays nothing
    /// for it. Each closure is a FACTORY `([String]) -> AnyView` keyed by the
    /// content-stable id the shipped tree carries: a PARAMETERIZED leaf (a slotted
    /// custom view whose simple string-literal args were lifted so editing them is
    /// OTA-patchable) substitutes the runtime values from `BodyEmission.slotArgs`
    /// into its template; a plain leaf ignores its args. This is the ABI that lets
    /// an OTA patch which only edited a string in a slotted custom view ship.
    ///
    /// `tokens` is a provider of resolved DESIGN-SYSTEM TOKEN values (`Color`/`Font`
    /// for `Theme.Colors.ink` / `Theme.Font.body(…)`), keyed by the content-stable id
    /// the tree carries in `.hostToken(id)`/`.fontToken(id)`. Like `slots`, it's invoked
    /// only when routing. Defaulted so pre-existing generated thunks (which don't pass
    /// it) keep compiling and behave exactly as before (no tokens → a token-using view
    /// simply isn't routable, same as today).
    ///
    /// `rowSlots` is a provider of PER-ROW INDEXED NATIVE-ACTION SLOTS (`PatchRowSlot`:
    /// host-evaluated row count + per-row factory `(Int) -> AnyView`), keyed by the
    /// content-stable id the tree carries in `.indexedForEachSlot(id:…)`. This is what
    /// lets a `ForEach` over a body-local collection whose rows are a custom child view
    /// with a per-row native action LOWER — the structure rides WASM (patchable) while
    /// each row's native subtree + action comes from this compiled-in `self`-closing
    /// factory. Like the others, invoked only when routing; defaulted so existing thunks
    /// keep compiling (no row slots → an indexed-row-using view simply isn't routable).
    ///
    /// Steady-state cost when NOT patched: a configuration check, an Observation
    /// read, an epoch compare and a dictionary lookup.
    /// `actionSlots` is a provider of NATIVE-ACTION SLOTS (`() -> Void` closures, closing over
    /// the view's `self`), keyed by the content-stable id the tree carries in
    /// `.actionSlotButton(id:…)`. This is what lets a `Button` inside an actions-list builder
    /// (`.swipeActions`/`.toolbar`/`.alert`/`Menu`/`.contextMenu`) whose action is a native method
    /// call LOWER — the label + role ride WASM (patchable) while the native action comes from this
    /// compiled-in `self`-closing closure. Like the others, invoked only when routing; defaulted so
    /// existing thunks keep compiling (no action slots → an action-slot-using view simply isn't
    /// routable, identical to the pre-change demote behavior).
    /// `effectSlots` is a provider of NATIVE EFFECT-MODIFIER SLOTS (`(AnyView) -> AnyView` closures,
    /// closing over the view's `self`), keyed by the content-stable id the tree carries in a
    /// `.nativeEffectSlot(id)` modifier. This is what lets a view with an undispatchable EFFECT
    /// modifier (`.task { await load() }`/`.onAppear`/`.refreshable`/`.onSubmit`/gesture) OTA-patch
    /// its OTHER content — the modified subtree rides WASM (patchable) while the real native effect
    /// (which can't be re-run in WASM) comes from this compiled-in `self`-closing closure applied to
    /// the rendered subtree. Like the others, invoked only when routing; defaulted so existing thunks
    /// keep compiling (no effect slots → an effect-using view stays demoted, identical to before).
    @MainActor
    public func thunkBody(typeName: String, baselineHash: String? = nil, instance: Any,
                          slots: () -> [String: ([String]) -> AnyView] = { [:] },
                          tokens: () -> [String: PatchHostToken] = { [:] },
                          rowSlots: () -> [String: PatchRowSlot] = { [:] },
                          actionSlots: () -> [String: () -> Void] = { [:] },
                          effectSlots: () -> [String: (AnyView) -> AnyView] = { [:] }) -> PatchedBodyHost? {
        guard currentConfiguration != nil else { return nil }
        guard let entry = PatchViewPatchRegistry.shared.entryIfPatchable(typeName: typeName) else {
            return nil
        }
        // NATIVE-FAST-PATH (the single highest-value perf win): when this build's baked
        // `baselineHash` EQUALS the active module's manifest `bodyHash` for this view, the
        // active body is BYTE-IDENTICAL to what the app shipped (no OTA patch touched this
        // view — typically the bundled baseline module, lowered FROM the native code). The
        // WASM render would reproduce exactly the native body, so we return nil and the
        // thunk renders the ORIGINAL native body with ZERO WASM round-trip. This skips even
        // the `PatchInstanceInputs.extract` marshal below — an unpatched view costs only the
        // registry's epoch/Observation read + this string compare.
        //
        // FAIL-SAFE: any case where the hashes can't be PROVEN equal routes WASM (the prior
        // always-route behavior) — a missing baselineHash (a thunk from an OLD cli), a
        // missing manifest bodyHash (an OLD module), or any inequality. A false "native"
        // (silently not applying a real patch) is the only dangerous outcome, and SHA256
        // equality makes it impossible: equal hash ⟺ identical body.
        if let bh = baselineHash, let eh = entry.bodyHash, bh == eh {
            return nil
        }
        // MEMOIZED marshal (P0 perf): a cheap fingerprint pass skips the ~159µs recursive
        // JSON string-build when the instance's marshalled state is unchanged since a recent
        // render of THIS view type (the SwiftUI steady state). Writebacks stay live.
        let extraction = PatchInstanceInputs.extract(from: instance, typeName: typeName)
        return PatchedBodyHost(typeName: typeName, entry: entry,
                               propsJSON: extraction.json,
                               writebacks: extraction.writebacks,
                               slots: slots(),
                               tokens: tokens(),
                               rowSlots: rowSlots(),
                               actionSlots: actionSlots(),
                               effectSlots: effectSlots())
    }
}
#endif
