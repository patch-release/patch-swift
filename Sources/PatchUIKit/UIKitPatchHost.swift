// SPDX-License-Identifier: MIT

// UIKitPatchHost.swift — the OUT-OF-THE-BOX UIKit cell-patching runtime.
// =============================================================================
// This is the SDK half of automatic UIKit cell patching — the analogue of
// `PatchSwiftUI/ViewPatching.swift`. The CLI (`patchcli prepare`) makes a cell's
// recognized construction method (`configure(with:)`) route through a generated
// thunk (a `@_dynamicReplacement(for:)`); at runtime each thunk asks this host
// whether the active OTA module ships a patched construction for the cell type and,
// if so, RENDERS the guest's `UIKitNode` tree into the cell's `contentView`.
//
// Why a cell is the friendly wedge: a `UITableViewCell`/`UICollectionViewCell` is
// RE-RUN on reuse (the table view calls `configure(with:)` for every dequeue), so
// idempotency is free — the host tears down any prior patched subtree and rebuilds
// each call (tier C). No new idempotency machinery, no first-frame bookkeeping like
// the SwiftUI thunk needs.
//
// The decision pipeline mirrors the SwiftUI registry:
//   1. The active module's UIKit MANIFEST (`patch_uikit_manifest`, emitted by the
//      engine) says which cell types have a fully-lowered, auto-routable
//      construction export (`thunkSafe`). No manifest ⇒ no routing (old modules).
//   2. The registry caches the manifest per MODULE EPOCH (`Patch.moduleEpoch`), so an
//      unpatched cell's steady-state cost is one config check + one epoch compare +
//      one dictionary miss.
//   3. If patched: the host marshals the cell's MODEL into the flat inputs JSON the
//      lowered guest scans, invokes `uikit_configure__<Type>`, decodes the
//      `UIKitEmission`, renders it via `renderUIKit`, fills the renderer's slot table
//      from the thunk's native slot closures, wires control actions to the cell's
//      native handlers, and installs the rendered view into `contentView`.
//   4. Any failure (decode, schema, trap, an uncovered slot) DEMOTES that cell type
//      for the current module epoch — the next `configure` runs the native code.

#if canImport(UIKit)
import Foundation
import UIKit
import PatchSDK
import PatchViewIR
import PatchRenderUIKit

// (`PatchUIKitManifest` lives in PatchUIKitManifest.swift — UIKit-free so it compiles
// + tests on macOS too.)

// MARK: - Registry

/// Per-process registry mapping cell type names to the active module's lowered
/// construction exports. MainActor-confined (cells are configured on the main thread).
@MainActor
public final class PatchUIKitCellRegistry {
    public static let shared = PatchUIKitCellRegistry()

    private var entries: [String: PatchUIKitManifest.Entry] = [:]
    private var loadedEpoch: UInt64?
    /// Cell types DEMOTED for the current epoch after a failure — their thunks run
    /// the native construction until the next module change.
    private var failedTypes: Set<String> = []
    /// Test seam: when set, `reload()` uses this JSON instead of the module export.
    var manifestJSONOverrideForTesting: (() -> String?)?

    init() {}

    /// The thunk fast path: the manifest entry for `typeName` iff the active module
    /// ships a fully-lowered construction for it and it has not been demoted.
    public func entryIfPatchable(typeName: String) -> PatchUIKitManifest.Entry? {
        syncWithModuleEpoch()
        guard let entry = entries[typeName], entry.thunkSafe,
              !failedTypes.contains(typeName) else { return nil }
        return entry
    }

    /// Demote `typeName` for the current module epoch (a render/decode failure).
    public func markFailed(typeName: String) { failedTypes.insert(typeName) }

    /// Number of patchable cell types in the active module (diagnostics).
    public var patchableCellCount: Int {
        syncWithModuleEpoch()
        return entries.values.filter(\.thunkSafe).count
    }

    private func syncWithModuleEpoch() {
        let epoch = Patch.shared.moduleEpoch
        guard epoch != loadedEpoch else { return }
        loadedEpoch = epoch
        failedTypes.removeAll()
        entries = Self.loadManifestEntries(overrideJSON: manifestJSONOverrideForTesting?())
    }

    static func loadManifestEntries(overrideJSON: String?) -> [String: PatchUIKitManifest.Entry] {
        let jsonBytes: [UInt8]
        if let overrideJSON {
            jsonBytes = Array(overrideJSON.utf8)
        } else {
            guard Patch.shared.hasFunction(PatchUIKitManifest.exportName),
                  let bytes = try? Patch.shared.callPacked(PatchUIKitManifest.exportName, []) else {
                return [:]
            }
            jsonBytes = bytes
        }
        return PatchUIKitManifest.decodeEntries(jsonBytes)
    }
}

// MARK: - The host call + install

/// Errors specific to driving a UIKit cell from a WASM module.
public enum PatchUIKitError: Error, CustomStringConvertible {
    case decode(Error)
    case runtime(Error)
    case uncoveredSlot(String)
    public var description: String {
        switch self {
        case .decode(let e): return "UIKitEmission decode failed: \(e)"
        case .runtime(let e): return "uikit_configure call failed: \(e)"
        case .uncoveredSlot(let id): return "patch introduced an uncovered slot: \(id)"
        }
    }
}

extension Patch {
    /// Call the guest's `uikit_configure(modelJSON)` and return the decoded UIKitNode
    /// tree. `modelJSON` is the cell model's flat inputs JSON (empty ⇒ guest defaults).
    public func uikitConfigure(modelJSON: String = "",
                               export: String = "uikit_configure") throws -> UIKitEmission {
        let inBytes: [UInt8] = modelJSON.isEmpty ? [] : [UInt8](modelJSON.utf8)
        let outBytes: [UInt8]
        do { outBytes = try callPacked(export, inBytes) }
        catch { throw PatchUIKitError.runtime(error) }
        do { return try JSONDecoder().decode(UIKitEmission.self, from: Data(outBytes)) }
        catch { throw PatchUIKitError.decode(error) }
    }
}

/// The native slot renderers + action handlers a generated cell thunk supplies. The
/// thunk captures these over the LIVE cell instance, so a custom subview leaf renders
/// the cell's existing property (`self.chart`) and a control action calls the cell's
/// native handler. The host invokes them only when routing (an unpatched cell pays
/// nothing).
@MainActor
public struct PatchCellWiring {
    /// Native renderers for the cell's non-lowerable leaves, keyed by the shipped
    /// tree's customSlot id. Empty for a fully-lowered cell.
    public var slots: [String: () -> UIView]
    /// Native action handlers, keyed by the action id the lowered control carries.
    public var actions: [String: () -> Void]
    /// DESIGN-SYSTEM COLOR TOKEN resolvers, keyed by the shipped tree's `.hostToken(id)`.
    /// Each evaluates the cell's real design-system color expression NATIVELY (over the
    /// live instance), so a custom color (`SemanticColors.View.backgroundDefault`) the
    /// guest can't reconstruct rides WASM as an id and resolves to the real `UIColor` at
    /// render time — the UIKit analogue of the SwiftUI `__patchTokens()` color channel.
    public var colorTokens: [String: () -> UIColor]
    /// DESIGN-SYSTEM NUMERIC TOKEN resolvers, keyed by the content-stable id the engine
    /// derived for a cross-file/computed numeric constant in a numeric position (a
    /// constraint constant, `cornerRadius`, `spacing`, …). Each evaluates the cell's real
    /// design-system number expression (`TPMenuUX.UX.viewCornerRadius`, `Theme.Radius.card`)
    /// NATIVELY over the live instance → a `Double`. Unlike color tokens (which fill the
    /// renderer's token table), a number token rides the INPUT JSON: its value is MERGED
    /// into the model JSON under `__numtok_<id>` before the guest runs, so the lowered body
    /// reads it as a `.double` input in the numeric position. The UIKit analogue of the
    /// SwiftUI `.number` host token — no renderer-table application, no wire-format change.
    public var numberTokens: [String: () -> Double]
    /// VIEW-ATTACHED GESTURE WIRINGS (Lever 1 — `addGestureRecognizer`): keyed by the
    /// rendered node's id (the source view's local name), each closure does the REAL native
    /// wiring against `self` + the rendered view — `{ v in v.addGestureRecognizer(
    /// UITapGestureRecognizer(target: self, action: #selector(self.handleTap))) }`. The
    /// `#selector` is a compile-time `#selector` in the generated thunk, so a patch can't
    /// change the selector (it's baked into the native shell) — only the layout/styling the
    /// gesture's view rides over WASM is OTA-patchable. The host applies each to the matching
    /// rendered view after building the tree (a view that didn't end up in the tree is
    /// silently skipped). A view may carry several gestures.
    public var gestureWirings: [String: [(UIView) -> Void]]
    /// METHOD-LEVEL OBSERVER EFFECTS (Lever 2 — `NotificationCenter.default.addObserver`):
    /// each closure re-runs the VERBATIM `NotificationCenter.default.addObserver(self,
    /// selector: #selector(self.onKeyboard(_:)), name: …, object: …)` against `self`
    /// (selector resolved natively). The host runs each ONCE at install, after rendering.
    /// Not view-attached — a side effect of the construction method.
    public var observerEffects: [() -> Void]
    /// QUARANTINED NATIVE EFFECTS (Goal 1 — GRANULAR PER-STATEMENT PARTITIONING): the
    /// isolatable imperative statements the engine couldn't lower but the thunk replays
    /// VERBATIM against `self` in SOURCE ORDER after building the tree, so a single weird
    /// line no longer demotes the whole method. Already ordered by the engine. Each closure
    /// captures the live cell/VC instance; the dominant real case is a delegate/dataSource/
    /// config set on a stored `UITableView`/`UIScrollView`/`MKMapView` that renders as a
    /// slotted custom leaf (`self.<name>`) — so configuring `self.<name>` configures exactly
    /// the shown view. The generalization of the gesture/observer levers.
    public var nativeEffects: [() -> Void]
    public init(slots: [String: () -> UIView] = [:],
                actions: [String: () -> Void] = [:],
                colorTokens: [String: () -> UIColor] = [:],
                numberTokens: [String: () -> Double] = [:],
                gestureWirings: [String: [(UIView) -> Void]] = [:],
                observerEffects: [() -> Void] = [],
                nativeEffects: [() -> Void] = []) {
        self.slots = slots
        self.actions = actions
        self.colorTokens = colorTokens
        self.numberTokens = numberTokens
        self.gestureWirings = gestureWirings
        self.observerEffects = observerEffects
        self.nativeEffects = nativeEffects
    }
}

extension Patch {
    /// The single call every generated cell thunk makes. If the active module ships a
    /// routable construction for `typeName`, this marshals `model` → renders the guest
    /// tree → installs it into `contentView` (clearing any prior patched subtree) and
    /// returns `true` (the thunk then SKIPS the native construction). Returns `false`
    /// when the cell isn't patched or rendering failed — the thunk runs the native
    /// construction (faithful fallback).
    ///
    /// Idempotent on reuse: the install clears the previously-installed patched root
    /// before adding the new one, so the table view calling `configure` on every
    /// dequeue rebuilds cleanly (tier C — cells are re-run, no extra bookkeeping).
    @MainActor
    @discardableResult
    public func installPatchedCell(typeName: String,
                                   contentView: UIView,
                                   model: Any?,
                                   wiring: () -> PatchCellWiring = { PatchCellWiring() }) -> Bool {
        // BUG #53 (stale-patched-root on a reused cell): EVERY decline path must first
        // remove any PATCH-installed root left in `contentView` by a PRIOR successful
        // install of this reused cell instance. Otherwise, when a later `configure` on the
        // same dequeued cell declines a gate (a patch adds an unsupplied slot/color-token
        // id, decode traps, or the type was demoted via `markFailed`), this returns `false`
        // → the thunk falls through to the native `configure(with:)`, which builds native
        // subviews into a `contentView` that STILL holds the stale patched root R1 → a
        // double/overlapping render. Clearing the tagged root on decline (and on success,
        // just before re-adding the new one) makes the native fallback render cleanly. The
        // clear is a cheap tag-filtered pass over `contentView.subviews` — a no-op for a
        // never-patched cell (no tagged subviews).
        func decline() -> Bool {
            Self.clearPatchedRoot(in: contentView)
            return false
        }

        guard currentConfiguration != nil else { return decline() }
        guard let entry = PatchUIKitCellRegistry.shared.entryIfPatchable(typeName: typeName) else {
            return decline()
        }
        // Marshal the model's flat fields to the inputs JSON the guest scans. The wiring
        // is materialized up-front so its DESIGN-SYSTEM NUMERIC TOKENS (resolved natively
        // over the live cell) can be MERGED into the model JSON before the guest runs —
        // the body reads each as a `.double` input under `__numtok_<id>` (rides the input
        // JSON, like the SwiftUI numeric token; no wire change).
        let w = wiring()
        let baseModelJSON = model.map { PatchUIKitModelMarshal.flatJSON(from: $0) } ?? "{}"
        let resolvedNumberTokens = w.numberTokens.mapValues { $0() }
        let modelJSON = PatchUIKitModelMarshal.merging(modelJSON: baseModelJSON,
                                                       numberTokens: resolvedNumberTokens)

        let emission: UIKitEmission
        do { emission = try uikitConfigure(modelJSON: modelJSON, export: entry.export) }
        catch {
            PatchUIKitCellRegistry.shared.markFailed(typeName: typeName)
            return decline()
        }

        // Every customSlot in the tree must have a native renderer. If a patch
        // introduced a slot id that the installed thunk doesn't cover (it changed
        // native code not in this build), we can't render it — demote to native.
        let neededIDs = Self.collectSlotIDs(emission.root)
        if neededIDs.contains(where: { w.slots[$0] == nil }) {
            PatchUIKitCellRegistry.shared.markFailed(typeName: typeName)
            return decline()
        }
        // Every design-system color TOKEN in the tree must have a native resolver. A patch
        // that adds an unsupplied token id (changed native code not in this build) can't
        // resolve to the real color — demote to native (faithful over a wrong default).
        let neededTokenIDs = Self.collectColorTokenIDs(emission.root)
        if neededTokenIDs.contains(where: { w.colorTokens[$0] == nil }) {
            PatchUIKitCellRegistry.shared.markFailed(typeName: typeName)
            return decline()
        }

        // Build the render context: the slot table + the token table + the dispatcher.
        let slotTable = UIKitSlotTable()
        for id in neededIDs { if let make = w.slots[id] { slotTable.set(id, make()) } }
        let tokenTable = UIKitTokenTable()
        for id in neededTokenIDs { if let resolve = w.colorTokens[id] { tokenTable.setColor(id, resolve()) } }
        let dispatcher = UIKitDispatcher { event, _ in
            // A lowered control's action id maps to the cell's native handler.
            w.actions[event.id]?()
        }
        let context = UIKitRenderContext(slots: slotTable, dispatcher: dispatcher,
                                         showSlotStubs: false, tokens: tokenTable)
        let (rendered, viewsByID) = renderUIKitIndexed(emission.root, context: context)

        // Detect REUSE: a prior patch-installed root in contentView means this cell
        // instance was already configured (from a previous dequeue). Observer effects
        // (`NotificationCenter.addObserver`) MUST NOT run again on reuse — they are not
        // idempotent and `NotificationCenter` never deduplicates by selector, so calling
        // `addObserver` a second time on the same object/selector registers a DUPLICATE
        // observer that causes notification handlers to fire twice, tripling on the third
        // reuse, etc. (a P0 false-behavior bug). We detect reuse before clearPatchedRoot
        // so the check is based on the state entering this configure call.
        let isReuse = contentView.subviews.contains { $0.tag == Self.patchedRootTag }

        // Lever 1: apply the view-attached GESTURE WIRINGS. Each is keyed by the source
        // view's local name (the rendered node's id); the thunk's closure does the real
        // native `addGestureRecognizer(<gesture>(target: self, action: #selector(...)))`
        // against the matching rendered view. A wiring whose view didn't end up in the tree
        // is silently skipped (the gesture's view isn't visible anyway) — never a demote.
        // Gesture wirings MUST re-run on every configure call because the rendered view tree
        // is freshly rebuilt each time (the gestures attach to the NEW rendered views).
        for (nodeID, applies) in w.gestureWirings {
            guard let view = viewsByID[nodeID] else { continue }
            for apply in applies { apply(view) }
        }
        // Lever 2: run the method-level OBSERVER EFFECTS, but ONLY on first install (not
        // on cell reuse). `NotificationCenter.addObserver` is NOT idempotent — calling it
        // again without a prior `removeObserver` accumulates duplicate registrations whose
        // handlers fire N times after N reuses. Observer effects are cell-instance-scoped
        // (they observe `self`), so they survive cell reuse as-is without re-registration.
        if !isReuse {
            for effect in w.observerEffects { effect() }
        }

        // Goal 1: replay the QUARANTINED NATIVE EFFECTS in SOURCE ORDER (the engine already
        // sorted by ordinal). Each runs once against `self` (the closure captures the live
        // instance) — a delegate/dataSource/config set or a live-object call the engine
        // couldn't lower but vetted as a faithful native side effect. The surrounding
        // declarative construction still rode WASM (the whole win over the old whole-method
        // demote); these effects ride the compiled-in thunk, exactly like the observers.
        // Native effects run on EVERY configure (including reuse) because they commonly
        // re-configure live stored subviews (`self.tableView.delegate = self`) that are
        // part of the freshly re-rendered slot tree.
        for effect in w.nativeEffects { effect() }

        // Install into contentView: clear any prior PATCH-installed root, then add the
        // new one pinned to the content view's edges. The prior root is tagged so a
        // reuse-driven re-`configure` removes exactly our subtree (never the cell's
        // own chrome).
        Self.clearPatchedRoot(in: contentView)
        rendered.tag = Self.patchedRootTag
        rendered.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rendered)
        NSLayoutConstraint.activate([
            rendered.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rendered.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rendered.topAnchor.constraint(equalTo: contentView.topAnchor),
            rendered.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        return true
    }

    /// The view tag the patched root carries so a reuse re-install removes exactly it.
    static let patchedRootTag = 0x50_4154_4348   // "PATCH" — distinctive, app-unlikely

    static func clearPatchedRoot(in contentView: UIView) {
        for sub in contentView.subviews where sub.tag == patchedRootTag {
            sub.removeFromSuperview()
        }
    }

    /// Every `.customSlot` id in the tree — the leaves the thunk must supply.
    nonisolated static func collectSlotIDs(_ node: UIKitNode) -> [String] {
        var out: [String] = []
        func walk(_ n: UIKitNode) {
            if case .customSlot(let id, _) = n.kind { out.append(id) }
            for child in n.childNodes { walk(child) }
        }
        walk(node)
        return out
    }

    /// Every `ColorRef.hostToken(id)` in the tree — the design-system color tokens the
    /// thunk must resolve (Lever D). Inspects every color-bearing position: the common
    /// view props (`backgroundColor`/`tintColor`) on EVERY node + the per-leaf color
    /// payloads (`label.textColor`, `button.titleColor`/`tintColor`, `imageView.tintColor`).
    nonisolated static func collectColorTokenIDs(_ node: UIKitNode) -> [String] {
        var out: [String] = []
        func tokenID(_ c: ColorRef?) { if case .hostToken(let id)? = c { out.append(id) } }
        func walk(_ n: UIKitNode) {
            tokenID(n.props.backgroundColor)
            tokenID(n.props.tintColor)
            switch n.kind {
            case .label(_, _, let textColor, _, _): tokenID(textColor)
            case .button(_, let titleColor, _, _): tokenID(titleColor)
            case .imageView(_, let tintColor, _): tokenID(tintColor)
            default: break
            }
            for child in n.childNodes { walk(child) }
        }
        walk(node)
        return out
    }
}
#endif
