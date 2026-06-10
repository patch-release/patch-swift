// PatchViewGlue.swift — wires a LIVE Patch WASM module to the SwiftUI renderer.
// =============================================================================
// `PatchView` (in PatchRender) is closure-driven so it has no WasmKit dependency.
// This file supplies those closures from a live `Patch` module: it calls the
// guest's `view_body` / `dispatch` exports over the proven packed-(ptr,len)+JSON
// ABI, decodes the emitted `ViewNode` tree, validates the IR schema version, and
// hands the tree to the renderer. A control change forwards the event into the
// guest's `dispatch`, which re-emits the tree — the host re-renders.
//
// This is the productization of the SwiftUI BREAKTHROUGH #3/#5 loop: a shipped
// WASM module's view renders as REAL SwiftUI, and its interaction LOGIC runs
// on-device in the sandbox.

#if canImport(SwiftUI)
import SwiftUI
import PatchSDK
import PatchViewIR
import PatchRender

/// Errors specific to driving a SwiftUI view from a WASM module.
public enum PatchViewError: Error, CustomStringConvertible {
    case schema(PatchViewIRSchema.Mismatch)
    case decode(Error)
    case runtime(PatchError)
    public var description: String {
        switch self {
        case .schema(let m): return m.description
        case .decode(let e): return "ViewNode decode failed: \(e)"
        case .runtime(let e): return "module call failed: \(e)"
        }
    }
}

extension Patch {
    /// Decode + schema-check a `BodyEmission` returned by an export.
    private func decodeEmission(_ bytes: [UInt8]) throws -> BodyEmission {
        let emission: BodyEmission
        do { emission = try ViewNodeWire.decode(bytes) }
        catch { throw PatchViewError.decode(error) }
        do { try PatchViewIRSchema.check(emission.schemaVersion) }
        catch let m as PatchViewIRSchema.Mismatch { throw PatchViewError.schema(m) }
        return emission
    }

    /// Decode + schema-check a `DispatchResult` returned by `dispatch`.
    private func decodeDispatch(_ bytes: [UInt8]) throws -> DispatchResult {
        let r: DispatchResult
        do { r = try ViewNodeWire.decodeDispatch(bytes) }
        catch { throw PatchViewError.decode(error) }
        do { try PatchViewIRSchema.check(r.schemaVersion) }
        catch let m as PatchViewIRSchema.Mismatch { throw PatchViewError.schema(m) }
        return r
    }

    /// Call the guest's `view_body(state)` and return the decoded ViewNode tree.
    /// `state` is the guest's opaque state JSON (empty ⇒ guest defaults).
    public func viewBody(state: String = "", export: String = "view_body") throws -> ViewNode {
        let inBytes: [UInt8] = state.isEmpty ? [] : [UInt8](state.utf8)
        let outBytes: [UInt8]
        do { outBytes = try callPacked(export, inBytes) }
        catch let e as PatchError { throw PatchViewError.runtime(e) }
        return try decodeEmission(outBytes).root
    }

    /// Call the guest's `dispatch(state, event)` and return the new opaque state +
    /// re-emitted tree. The guest applies the UPDATE logic in WASM; the host stores
    /// `state` verbatim and renders `tree`.
    public func dispatch(state: String, event: EventID, value: IRValue,
                         export: String = "dispatch") throws -> DispatchResult {
        let envelope: [UInt8]
        do {
            envelope = try ViewNodeWire.encodeDispatch(
                state: state, event: DispatchEvent(event: event, value: value))
        } catch { throw PatchViewError.decode(error) }
        let outBytes: [UInt8]
        do { outBytes = try callPacked(export, envelope) }
        catch let e as PatchError { throw PatchViewError.runtime(e) }
        return try decodeDispatch(outBytes)
    }

    /// Build a `PatchView` (real SwiftUI) driven by THIS module's `view_body` /
    /// `dispatch` exports. A control change forwards into the guest's `dispatch`;
    /// the guest re-emits the tree; SwiftUI re-renders. The view is read-only if
    /// the module has no `dispatch` export.
    ///
    /// On a per-pass decode failure (a bad tree, a schema mismatch) the view falls
    /// back to an `errorView` (default: a labeled native stub) rather than
    /// crashing, so a broken OTA tree degrades gracefully.
    @MainActor
    public func patchView(
        initialState: String = "",
        context: RenderContext = RenderContext(),
        viewBodyExport: String = "view_body",
        dispatchExport: String = "dispatch",
        errorView: @escaping (Error) -> ViewNode = { e in
            ViewNode(.opaque(id: "patchview-error", label: "PatchView error: \(e)"))
        }
    ) -> PatchView {
        // Use the FACADE's `hasFunction` (which checks the primary AND every
        // additive PMOD sub-module), NOT `withRuntime { $0.hasFunction(...) }`
        // (which only inspects the primary). The actual `dispatch` call routes via
        // `callPacked` → `withRuntime(forFunction:)`, which DOES reach an additive
        // sub-module; checking only the primary here would wrongly mark a PMOD
        // module whose `dispatch` lives in a sub-module as read-only.
        let hasDispatch = hasFunction(dispatchExport)
        return PatchView(
            initialState: initialState,
            context: context,
            treeProvider: { state in
                do { return try self.viewBody(state: state, export: viewBodyExport) }
                catch { return errorView(error) }
            },
            reduce: hasDispatch ? { state, event, value in
                // Run the UPDATE in WASM; return the new opaque state. On failure
                // keep the old state (the view re-renders the last good tree).
                (try? self.dispatch(state: state, event: event, value: value,
                                    export: dispatchExport).state) ?? state
            } : nil
        )
    }
}
#endif
