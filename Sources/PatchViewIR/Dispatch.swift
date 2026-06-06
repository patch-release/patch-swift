// Dispatch.swift — the interactive event-loop envelopes.
// =========================================================================
// The static path lowers a body to `view_body(state) -> tree`. The interactive
// path adds the update half of an Elm/TEA loop, run in WASM:
//
//     dispatch(state, event) -> (newState, newTree)
//
// * STATE lives in the guest's value world (marshalled across the boundary as an
//   opaque JSON blob the host never interprets — it only stores + re-feeds it).
// * On a user interaction the host sends `{ state, event }` to the guest's
//   `dispatch` export. The guest decodes the state, applies the event via the
//   view's UPDATE function (the interaction LOGIC — this is what now runs in
//   WASM, not native), then RE-EMITS both the new state and the new ViewNode
//   tree. The host stores the new state and re-renders the new tree.
//
// `dispatch` is therefore a PURE function `(State, Event) -> (State, Tree)`
// compiled to WASM. The host is just the renderer + the event source.
//
// Foundation-free so it compiles into the embedded (T0) guest as well.

/// One user interaction, marshalled into the guest. `event` selects the UPDATE
/// branch; `value` carries the new control value (`.bool`/`.double`/`.int`/
/// `.string`) or `.none` for a bare tap.
public struct DispatchEvent: Equatable, Sendable {
    public var event: EventID
    public var value: IRValue
    public init(event: EventID, value: IRValue) {
        self.event = event
        self.value = value
    }
}

/// What the guest returns from `dispatch`: the new (opaque-to-host) state JSON
/// and the freshly re-emitted tree. The host stores `state` verbatim for the
/// next dispatch and renders `tree`.
public struct DispatchResult: Equatable, Sendable {
    /// The new state, as the guest's own JSON encoding (host stores it opaquely).
    public var state: String
    /// The re-emitted ViewNode tree for the new state.
    public var tree: ViewNode
    /// Optional self-reported coverage (same as `BodyEmission`).
    public var coverage: BodyEmission.Coverage?
    /// The IR schema version the guest emitted with (see `PatchViewIRSchema`).
    /// Optional for backward-compat exactly as `BodyEmission.schemaVersion`.
    public var schemaVersion: Int?
    public init(state: String, tree: ViewNode,
                coverage: BodyEmission.Coverage? = nil,
                schemaVersion: Int? = nil) {
        self.state = state
        self.tree = tree
        self.coverage = coverage
        self.schemaVersion = schemaVersion
    }
}

#if !FRONTIER_EMBEDDED
extension DispatchEvent: Codable {}
extension DispatchResult: Codable {}
#endif
