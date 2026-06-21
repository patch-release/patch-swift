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
    /// The manifest marks the requested view-body export NON-thunkSafe (it has an
    /// undispatchable effect, e.g. an `.onDelete`/`.onMove` the guest can't apply).
    /// `patchView` refuses to render it rather than reach the destructive array-revert
    /// path (bug #71).
    case notThunkSafe(String)
    public var description: String {
        switch self {
        case .schema(let m): return m.description
        case .decode(let e): return "ViewNode decode failed: \(e)"
        case .runtime(let e): return "module call failed: \(e)"
        case .notThunkSafe(let export): return "view export \(export) is not thunk-safe (refused)"
        }
    }
}

extension Patch {
    // PERF R2: bypass the intermediate `[UInt8](state.utf8)` allocation in the
    // view-body hot path by writing String.UTF8View directly into guest memory.
    // This mirrors `callPacked(_:_:)` exactly but uses `writeBuffer(utf8:)`
    // instead of `writeBuffer(_:)` for the input — byte-identical output.
    private func callPackedUTF8(_ function: String, utf8 state: String) throws -> [UInt8] {
        let utf8View = state.utf8
        return try withRuntime(forFunction: function) { runtime in
            do {
                let (inPtr, inLen) = try runtime.writeBuffer(utf8: utf8View)
                defer { if inPtr != 0 { runtime.free(inPtr) } }
                let results = try runtime.invoke(function, [.i32(inPtr), .i32(inLen)])
                guard let first = results.first, case .i64(let packed) = first else {
                    throw PatchRuntimeError.unexpectedResults(
                        function: function, got: results.count, expected: "1 i64 (packed ptr,len)")
                }
                let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
                let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
                defer { runtime.free(outPtr) }
                return try runtime.read(ptr: outPtr, len: outLen)
            } catch let e as PatchRuntimeError {
                throw PatchError.runtime(e)
            }
        }
    }

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
        try viewBodyEmission(state: state, export: export).root
    }

    /// Call the guest's `view_body(state)` and return the FULL decoded emission —
    /// the ViewNode tree PLUS the parameterized-slot `slotArgs` (slot id → the
    /// lifted string-literal values that ride WASM). `PatchedBodyHost` uses this so
    /// it can render a parameterized native slot via the thunk's factory applied to
    /// the CURRENT (possibly OTA-edited) literal values. `state` is the guest's
    /// opaque state JSON (empty ⇒ guest defaults).
    public func viewBodyEmission(state: String = "", export: String = "view_body") throws -> BodyEmission {
        // PERF R2: use callPackedUTF8 to write String.UTF8View directly into guest
        // memory, skipping the [UInt8](state.utf8) intermediate allocation.
        // Empty state → zero-length input (writeBuffer(utf8:) returns (0,0) for empty).
        let outBytes: [UInt8]
        do { outBytes = try callPackedUTF8(export, utf8: state) }
        catch let e as PatchError { throw PatchViewError.runtime(e) }
        return try decodeEmission(outBytes)
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
        // THUNK-SAFE GATE (bug #71): the auto-route path refuses a NON-thunkSafe view
        // (e.g. a `List` ForEach with `.onDelete`, which the emitter flags because the
        // renderer's destructive `editableForEach` dispatches an array op a scalar-only
        // guest can't apply → a row that animates out then REAPPEARS, a data-integrity
        // loss). A hand-wired `Patch.patchView(viewBodyExport:)` bypassed that gate and
        // reached the destructive path. Mirror the gate here: if the manifest says this
        // export's view is NOT thunkSafe, refuse to render it (show the errorView) rather
        // than reach the array-revert. `nil` (no manifest / unknown export) renders as
        // before — we only refuse what the manifest explicitly marks non-thunkSafe.
        if PatchViewPatchRegistry.shared.isExportThunkSafe(export: viewBodyExport) == false {
            let stub = errorView(PatchViewError.notThunkSafe(viewBodyExport))
            return PatchView(initialState: initialState, context: context,
                             treeProvider: { _ in stub }, reduce: nil)
        }
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
