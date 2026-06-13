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
        public init(type: String, export: String, dispatch: String?, thunkSafe: Bool) {
            self.type = type
            self.export = export
            self.dispatch = dispatch
            self.thunkSafe = thunkSafe
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

    /// Demote `typeName` for the current module epoch (a render/decode failure).
    /// The bump re-evaluates on-screen views so the demoted view's NEXT body
    /// evaluation takes the native branch.
    public func markFailed(typeName: String) {
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
        // A manifest stamped with a NEWER schema than this SDK renders is not
        // auto-routable — the per-call emission check would reject every tree
        // anyway; refusing here keeps views native instead of demote-thrashing.
        guard manifest.schemaVersion <= PatchViewIRSchema.version else { return [:] }
        var out: [String: PatchViewManifest.Entry] = [:]
        for entry in manifest.views { out[entry.type] = entry }
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
}

extension State: _PatchScalarWrapper {
    public func _patchRead() -> Any? { wrappedValue }
    public func _patchWrite(_ newValue: Any) { if let v = newValue as? Value { wrappedValue = v } }
}

extension Binding: _PatchScalarWrapper {
    public func _patchRead() -> Any? { wrappedValue }
    public func _patchWrite(_ newValue: Any) { if let v = newValue as? Value { wrappedValue = v } }
}

extension AppStorage: _PatchScalarWrapper {
    public func _patchRead() -> Any? { wrappedValue }
    public func _patchWrite(_ newValue: Any) { if let v = newValue as? Value { wrappedValue = v } }
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
public enum PatchInstanceInputs {
    public struct Extraction {
        public let json: String
        public let writebacks: [PatchScalarWriteback]
    }

    @MainActor
    public static func extract(from instance: Any) -> Extraction {
        var fragments: [(key: String, json: String)] = []
        var writebacks: [PatchScalarWriteback] = []

        for child in Mirror(reflecting: instance).children {
            guard let rawLabel = child.label else { continue }
            if rawLabel.hasPrefix("_") {
                // A property wrapper's backing storage (`_name`). Extract the
                // CURRENT scalar value from the wrappers we understand.
                guard let wrapper = child.value as? _PatchScalarWrapper else { continue }
                let key = String(rawLabel.dropFirst())
                guard !key.isEmpty, let value = wrapper._patchRead(),
                      let fragment = scalarJSONFragment(value) else { continue }
                fragments.append((key, fragment))
                writebacks.append(PatchScalarWriteback(key: key, wrapper: wrapper))
            } else {
                // A plain stored property (`let`/`var`). Marshal scalars; anything
                // else stays guest-side-defaulted (the lowering bound a literal).
                guard rawLabel != "body", let fragment = scalarJSONFragment(child.value) else { continue }
                fragments.append((rawLabel, fragment))
            }
        }

        // Deterministic key order (stable for tests + cacheable upstream).
        fragments.sort { $0.key < $1.key }
        let json = "{" + fragments.map { "\"\(escapeJSONKey($0.key))\":\($0.json)" }
            .joined(separator: ",") + "}"
        return Extraction(json: json, writebacks: writebacks)
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
        guard var baseObj = parse(base) else { return override }
        guard let overObj = parse(override) else { return base }
        for (k, v) in overObj { baseObj[k] = v }
        return serialize(baseObj)
    }

    static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func serialize(_ obj: [String: Any]) -> String {
        var fragments: [(String, String)] = []
        for (k, v) in obj {
            guard let frag = fragment(for: v) else { continue }
            fragments.append((k, frag))
        }
        fragments.sort { $0.0 < $1.0 }
        return "{" + fragments.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }

    private static func fragment(for value: Any) -> String? {
        // JSONSerialization yields NSNumber/NSString; disambiguate Bool first
        // (a Bool NSNumber would otherwise match the numeric casts).
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return PatchInstanceInputs.scalarJSONFragment(n.doubleValue)
        }
        if let s = value as? String { return PatchInstanceInputs.quotedJSONString(s) }
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
            // Numeric cross-family compare (Int vs NSNumber-double etc.).
            if let xa = numeric(a), let xb = numeric(b) { return xa == xb }
            return false
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

// MARK: - The patched-body host view

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
    /// by the shipped tree's opaque-slot id. Empty for a fully-lowered view.
    let slots: [String: () -> AnyView]

    @State private var guestState: String = ""

    init(typeName: String, entry: PatchViewManifest.Entry, propsJSON: String,
         writebacks: [PatchScalarWriteback], slots: [String: () -> AnyView] = [:]) {
        self.typeName = typeName
        self.entry = entry
        self.propsJSON = propsJSON
        self.writebacks = writebacks
        self.slots = slots
    }

    public var body: some View {
        let merged = PatchFlatJSON.merge(base: propsJSON, override: guestState)
        let tree: ViewNode
        do {
            tree = try Patch.shared.viewBody(state: merged, export: entry.export)
        } catch {
            // Demote OUTSIDE this view-update pass; this pass renders nothing and
            // the next evaluation takes the thunk's native branch.
            let name = typeName
            Task { @MainActor in
                PatchViewPatchRegistry.shared.markFailed(typeName: name)
            }
            return AnyView(EmptyView())
        }

        // MIXED-VIEW SAFETY NET: every opaque leaf in the tree must have a native
        // slot closure. If a patch introduced a leaf with no matching slot (i.e. it
        // changed native code that isn't in the installed build), we cannot render
        // it — DEMOTE the whole view to native rather than show a hole. (A patch
        // that only changes the lowered structure keeps the same leaf ids, so this
        // never trips for text/modifier/layout/rearrange edits.)
        let neededIDs = Self.collectOpaqueIDs(tree)
        let uncovered = neededIDs.filter { slots[$0] == nil }
        if !uncovered.isEmpty {
            let name = typeName
            Task { @MainActor in PatchViewPatchRegistry.shared.markFailed(typeName: name) }
            return AnyView(EmptyView())
        }

        var context = RenderContext(showOpaqueStubs: false)
        // Fill the renderer's opaque table with the native leaf renderers.
        for id in neededIDs { if let make = slots[id] { context.opaques.set(id, make()) } }
        if let dispatchExport = entry.dispatch {
            let stateBinding = $guestState
            let props = propsJSON
            let wbs = writebacks
            let name = typeName
            let dispatcher = Dispatcher { event, value in
                let current = PatchFlatJSON.merge(base: props, override: stateBinding.wrappedValue)
                do {
                    let result = try Patch.shared.dispatch(
                        state: current, event: event, value: value, export: dispatchExport)
                    stateBinding.wrappedValue = result.state
                    Self.applyWritebacks(wbs, newStateJSON: result.state)
                } catch {
                    Task { @MainActor in
                        PatchViewPatchRegistry.shared.markFailed(typeName: name)
                    }
                }
            }
            context.dispatcher = dispatcher
            // Lowered Buttons carry actionIDs with engine-emitted UPDATE rules
            // keyed by the SAME id — wire each to a guest dispatch event.
            for actionID in Self.collectButtonActionIDs(tree) {
                context.actions.set(actionID) {
                    dispatcher.send(EventID(actionID), .none)
                }
            }
        }
        return render(tree, context: context)
    }

    static func applyWritebacks(_ writebacks: [PatchScalarWriteback], newStateJSON: String) {
        guard !writebacks.isEmpty,
              let state = PatchFlatJSON.parse(newStateJSON) else { return }
        for wb in writebacks {
            guard let newValue = unbox(state[wb.key]) else { continue }
            if PatchFlatJSON.scalarEqual(wb.wrapper._patchRead(), newValue) { continue }
            wb.wrapper._patchWrite(newValue)
        }
    }

    /// JSONSerialization value → the Swift scalar the wrapper write expects.
    private static func unbox(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
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
            if case .button(let actionID, _) = n.kind { out.append(actionID) }
            for child in n.childNodes { walk(child) }
        }
        walk(node)
        return out
    }

    /// Every `.opaque` node id in the tree — the leaves the thunk must supply a
    /// native slot for (mixed views).
    nonisolated static func collectOpaqueIDs(_ node: ViewNode) -> [String] {
        var out: [String] = []
        func walk(_ n: ViewNode) {
            if case .opaque(let id, _) = n.kind { out.append(id) }
            for child in n.childNodes { walk(child) }
        }
        walk(node)
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
    /// for it. Each closure renders one leaf (a custom child view, an unsupported
    /// construct) keyed by the content-stable id the shipped tree carries.
    ///
    /// Steady-state cost when NOT patched: a configuration check, an Observation
    /// read, an epoch compare and a dictionary lookup.
    @MainActor
    public func thunkBody(typeName: String, instance: Any,
                          slots: () -> [String: () -> AnyView] = { [:] }) -> PatchedBodyHost? {
        guard currentConfiguration != nil else { return nil }
        guard let entry = PatchViewPatchRegistry.shared.entryIfPatchable(typeName: typeName) else {
            return nil
        }
        let extraction = PatchInstanceInputs.extract(from: instance)
        return PatchedBodyHost(typeName: typeName, entry: entry,
                               propsJSON: extraction.json,
                               writebacks: extraction.writebacks,
                               slots: slots())
    }
}
#endif
