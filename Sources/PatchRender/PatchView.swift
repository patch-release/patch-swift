// PatchView.swift — the production SwiftUI entry point for rendering a WASM-
// emitted ViewNode tree as REAL SwiftUI, with the interactive dispatch loop.
// =============================================================================
// `PatchView` is the public, app-facing wrapper an app drops into its SwiftUI
// hierarchy. It owns the TEA (The Elm Architecture) loop driven by a WASM guest:
//
//   1. `treeProvider(state)` asks the guest for the current `ViewNode` tree for
//      the current opaque state (in production this calls `Patch.callPacked
//      ("view_body"/"dispatch", …)` — see the `Patch` glue in PatchSDK).
//   2. The tree renders to real SwiftUI via `render(_:)`.
//   3. A control change fires the `Dispatcher`, which calls `dispatch(state,
//      event)` in the guest; the guest mutates state + re-emits a new tree; the
//      host stores the new state and SwiftUI re-renders.
//
// `PatchView` is closure-driven so this target needs no dependency on the WasmKit
// runtime (PatchSDK). The `Patch.patchView(...)` convenience in PatchSDK supplies
// the closures that call into a live module.

#if canImport(SwiftUI)
import SwiftUI
import PatchViewIR

/// Drives the interactive WASM view loop and renders it as real SwiftUI.
///
/// `initialState` is the guest's opaque state JSON (or empty for defaults).
/// `treeProvider(state)` returns the `ViewNode` tree for a state (calls
/// `view_body`). `reduce(state, event, value)` applies a user interaction in the
/// guest and returns the NEW opaque state (the guest is the source of truth; the
/// host stores the string verbatim and re-feeds it).
@MainActor
public struct PatchView: View {
    /// Returns the ViewNode tree for the given opaque state (calls `view_body`).
    public let treeProvider: (String) -> ViewNode
    /// Applies an event in the guest and returns the new opaque state (calls
    /// `dispatch`). When nil, the view renders but is read-only.
    public let reduce: ((String, EventID, IRValue) -> String)?
    /// Host wiring (action/opaque tables, opaque-stub policy).
    public let context: RenderContext

    @State private var state: String

    public init(initialState: String = "",
                context: RenderContext = RenderContext(),
                treeProvider: @escaping (String) -> ViewNode,
                reduce: ((String, EventID, IRValue) -> String)? = nil) {
        self.treeProvider = treeProvider
        self.reduce = reduce
        self.context = context
        self._state = State(initialValue: initialState)
    }

    public var body: some View {
        // Capture the current state binding so the dispatcher can advance it.
        let stateBinding = $state
        let reduce = self.reduce
        let dispatcher = Dispatcher { event, value in
            guard let reduce else { return }
            // Drive the guest reduce + advance @State, which re-invokes
            // `treeProvider(state)` on the next SwiftUI pass (the re-render loop).
            stateBinding.wrappedValue = reduce(stateBinding.wrappedValue, event, value)
        }
        var ctx = context
        ctx.dispatcher = dispatcher
        return render(treeProvider(state), context: ctx)
    }
}
#endif
