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
    public init(slots: [String: () -> UIView] = [:],
                actions: [String: () -> Void] = [:]) {
        self.slots = slots
        self.actions = actions
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
        guard currentConfiguration != nil else { return false }
        guard let entry = PatchUIKitCellRegistry.shared.entryIfPatchable(typeName: typeName) else {
            return false
        }
        // Marshal the model's flat fields to the inputs JSON the guest scans.
        let modelJSON = model.map { PatchUIKitModelMarshal.flatJSON(from: $0) } ?? "{}"

        let emission: UIKitEmission
        do { emission = try uikitConfigure(modelJSON: modelJSON, export: entry.export) }
        catch {
            PatchUIKitCellRegistry.shared.markFailed(typeName: typeName)
            return false
        }

        // Every customSlot in the tree must have a native renderer. If a patch
        // introduced a slot id that the installed thunk doesn't cover (it changed
        // native code not in this build), we can't render it — demote to native.
        let w = wiring()
        let neededIDs = Self.collectSlotIDs(emission.root)
        if neededIDs.contains(where: { w.slots[$0] == nil }) {
            PatchUIKitCellRegistry.shared.markFailed(typeName: typeName)
            return false
        }

        // Build the render context: the slot table + the action dispatcher.
        let slotTable = UIKitSlotTable()
        for id in neededIDs { if let make = w.slots[id] { slotTable.set(id, make()) } }
        let dispatcher = UIKitDispatcher { event, _ in
            // A lowered control's action id maps to the cell's native handler.
            w.actions[event.id]?()
        }
        let context = UIKitRenderContext(slots: slotTable, dispatcher: dispatcher,
                                         showSlotStubs: false)
        let rendered = renderUIKit(emission.root, context: context)

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
}
#endif
