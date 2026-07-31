// SPDX-License-Identifier: Apache-2.0

// Emitter.swift — lowers a body AST to guest `N.`-builder Swift source.
// =====================================================================
// This is the code-generation half of the lowering: it turns the parsed
// SwiftUI body into the Swift the engine compiles to WASM, where it builds a
// `ViewNode` tree via the `N` builder (Sources/ViewNodeIR/Builder.swift).
//
// It handles the common declarative grammar: constructor calls, modifier
// chains (preserving order), result-builder statement lists, and ForEach/Button
// with trailing-closure content. A construct it can't lower is emitted as
// `N.opaque(id:..., label:...)` so the emitted body always compiles.
//
// The emitter is intentionally conservative: it round-trips literals exactly,
// and for dynamic-but-pure-structure values (a `name` string, a `count`) it
// emits the expression verbatim — at WASM-compile time those resolve to the
// marshalled-in inputs. References it can't prove pure become opaque.

import SwiftSyntax
import SwiftOperators
import SwiftParser
import ViewNodeIR

struct Emitter {

    /// Mutation rules collected as the body is lowered (Breakthrough #5
    /// productization). Each interactive control / recognizable tap contributes a
    /// rule keyed by the SAME event id the emitted tree carries, so the guest's
    /// `update` matches the host-echoed id exactly. `BodyLowering` pairs these with
    /// the view's scalar `@State` fields to build the dispatch state model.
    private(set) var mutationRules: [BodyLowering.MutationRule] = []

    /// Non-lowerable LEAVES emitted as `N.opaque` (see `BodyLowering.OpaqueLeaf`).
    /// The build-time thunk supplies a native slot closure for each SLOTABLE leaf,
    /// keyed by the SAME content-stable `id` the emitted tree carries — so a body
    /// that's only PARTLY lowerable still renders (lowered parts ride WASM, native
    /// leaves render from the compiled-in closures).
    private(set) var opaqueLeaves: [BodyLowering.OpaqueLeaf] = []
    /// DESIGN-SYSTEM TOKENS the body references in a color/font modifier position
    /// (`Theme.Colors.ink`, `Theme.Font.body(13, weight: .semibold)`). The lowered
    /// tree carries only a content-stable id (`.hostToken(id)` / `.fontToken(id)`);
    /// the build-time thunk's `__patchTokens()` evaluates the real expression natively
    /// (over `self`) → a resolved `Color`/`Font` keyed by that id. This lets a
    /// token-using modifier LOWER (the modifier rides WASM; its VALUE is host-supplied
    /// — the same slot mechanism as a mixed-view leaf, but for a modifier value). Keyed
    /// like `opaqueLeaves`: the engine (push) and the thunk generator (build) derive the
    /// SAME id from the source, so they agree with no shared state.
    private(set) var hostTokens: [BodyLowering.HostToken] = []
    /// PER-ROW INDEXED NATIVE-ACTION SLOTS the body emitted (`indexedForEachSlot`):
    /// a `ForEach` over a BODY-LOCAL collection the guest can't reconstruct whose rows
    /// are a custom child view with a PER-ROW native action closure. The build-time
    /// thunk natively evaluates the collection + supplies a per-row factory + the row
    /// count. Keyed (like `opaqueLeaves`/`hostTokens`) by a content-stable id, so the
    /// engine (push) and thunk generator (build) agree with no shared state.
    private(set) var indexedRowSlots: [BodyLowering.IndexedRowSlot] = []
    /// NATIVE-ACTION SLOTS the body emitted (`actionSlotButton`): a `Button` inside an
    /// ACTIONS-LIST builder (`.swipeActions`/`.toolbar`/`.alert`/`Menu`/`.contextMenu`) whose
    /// action is a NATIVE method call the guest can't dispatch but the cross-file thunk CAN run
    /// (the action references no body-local / no inaccessible member). The build-time thunk's
    /// `__patchActionSlots()` supplies the `() -> Void` action closure by id; the Button's
    /// label + role lower (OTA-patchable). Keyed (like `opaqueLeaves`/`indexedRowSlots`) by a
    /// content-stable id, so the engine (push) and thunk generator (build) agree with no shared
    /// state. An UN-slotable actions-list action instead sets `hasUndispatchableAction` (demote).
    private(set) var actionSlots: [BodyLowering.ActionSlot] = []
    /// NATIVE EFFECT-MODIFIER SLOTS the body emitted (`nativeEffectSlot`): an undispatchable
    /// EFFECT modifier (`.task`/`.onAppear`/`.refreshable`/`.onSubmit`/`.onTapGesture`/`.gesture`/
    /// `.onLongPressGesture`/`.onDisappear`) whose closure runs a native side-effect the guest can't
    /// re-run in WASM, but that the cross-file thunk CAN re-apply over `self`. The modified SUBTREE
    /// lowers normally (OTA-patchable); the effect rides as a `(AnyView) -> AnyView` slot the thunk's
    /// `__patchEffectSlots()` supplies by id. Keyed (like `actionSlots`) by a content-stable id, so
    /// engine (push) and thunk generator (build) agree with no shared state. An UN-slotable / unsafe
    /// effect instead sets `hasUndispatchableEffect` (the whole view demotes — the dev's native view
    /// renders, never a stripped body whose effect can't be supplied).
    private(set) var effectSlots: [BodyLowering.EffectSlot] = []
    /// CHILD-VIEW CALLBACK SLOTS the body emitted (`callbackSlot` nodes — a custom child-view call
    /// with a `() -> Void` closure arg whose body is dispatchable). The thunk's
    /// `__patchCallbackSlots()` supplies an opaque `AnyView` closure per slot (the full call with
    /// the closure arg replaced by a stable forwarding closure); the callback body runs in WASM
    /// (OTA-patchable). Keyed by a POSITION-STABLE id so the engine (push) and thunk generator
    /// (build) agree without shared state. Editing the callback body = WASM-only change = OTA.
    private(set) var callbackSlots: [BodyLowering.CallbackSlot] = []
    /// Body-local `let`/`var` initializer SOURCES (name → RHS source), collected up
    /// front in `emit(expr:)`. Used ONLY to resolve a `ForEach` collection that is a
    /// body-local alias (`let owners = schedule.availableOwners`) back to its ACCESSIBLE
    /// initializer for a per-row indexed slot's `collectionSource` — so the cross-file
    /// thunk can re-evaluate the real collection over `self`.
    private var bodyLocalLetInits: [String: String] = [:]
    /// True once the body lowered ≥1 `GeometryReader` (C): its child reads the
    /// reserved `__geo_*` inputs, so the guest emitter must bind them from the input
    /// JSON (the SDK host wrapper supplies the live proxy's size/frame there).
    private(set) var usesGeometry = false
    /// True once the body emitted a `Button` (or other tap-bearing control whose action
    /// must live in a host-actions LIST) whose action is REAL (non-empty) but NOT a
    /// recordable dispatch rule — AND that button lives in a MODIFIER-ACTION list context
    /// (`.alert`/`.confirmationDialog`/`.toolbar`/`Menu`/`.contextMenu`) where the SDK
    /// renderer can't attach a native slot (SwiftUI's actions ViewBuilder won't reach a
    /// Button wrapped behind the renderer's `ForEach`/`AnyView`). Slotting there would put
    /// an opaque node in an actions list → a DEAD control on device. So instead the WHOLE
    /// view is forced to DEMOTE (stays native, fully functional). In a plain BODY/container
    /// context the same undispatchable button is SLOTTED (a working native control), not
    /// flagged — see `emitButton`.
    private(set) var hasUndispatchableAction = false
    /// True once the body emitted a BEHAVIORAL/LIFECYCLE modifier whose closure is REAL
    /// (non-empty) but whose effect is NOT faithfully produced on device — so the view
    /// would auto-route with a DEAD (or, for `.onDelete`/`.onMove`, DESTRUCTIVE) modifier.
    /// Unlike a body-context Button, a modifier closure has NO native-slot fallback (the
    /// renderer applies the modifier itself; there's no opaque slot for a `.task`/`.onChange`
    /// closure), so the only correct outcome is to DEMOTE the WHOLE view to native (its real
    /// `.task`/`.onChange`/`.onDelete`/… then runs natively = production behavior). The
    /// BuildPipeline `thunkSafe` gate ANDs in `!hasUndispatchableEffect` (mirrored in
    /// `ProjectFingerprint.isAutoRouted`). Confirmed dead/destructive on device:
    ///   * `.task { … }`            — the renderer fires the event but NO guest rule is ever
    ///                                 recorded (the engine never calls `recordActionMutation`
    ///                                 for `task`) → the async data-load never runs → EMPTY screen.
    ///   * `.onChange(of:) { … }`   — the renderer attaches NO hook (`_ = e; return v`) and no
    ///                                 host value-watcher emits the `chg…` event → never fires.
    ///   * `.onDelete`/`.onMove`    — the renderer dispatches an `.array([.int])` payload, but
    ///                                 the guest's MutationRule system is scalar-only → no rule
    ///                                 matches → the delete/move is silently dropped (the row
    ///                                 animates out then REAPPEARS) — a data-integrity bug.
    ///   * `.onAppear`/`.onDisappear`/`.onSubmit`/`.onTapGesture`/`.onLongPressGesture` with a
    ///     NON-TRIVIAL closure the engine couldn't record as a dispatch rule — the renderer
    ///     fires the event but no rule matches → dead. (A SIMPLE recordable mutation — e.g.
    ///     `.onTapGesture { count += 1 }` — DOES dispatch in WASM and is kept routing; an
    ///     EMPTY closure is a harmless no-op and is kept too.)
    private(set) var hasUndispatchableEffect = false
    /// True when the body emitted a `.animation(_:value:)` modifier. The SDK renderer (v11+)
    /// reconstitutes the real `Animation` AND watches the watched-`@State` scalar as the trigger,
    /// so such a view auto-routes — but it requires the v11 renderer (an older host NO-OPs the
    /// animation → renders the value change instantly, a silently degraded effect). Drives the
    /// view's manifest `minVersion` (11) so an older host DEMOTES this view to native (where the
    /// real implicit animation runs) instead. See BuildPipeline's `minSchemaVersion`.
    private(set) var usesAnimationValue = false
    /// True while lowering the ACTIONS LIST of a modifier-action context (alert /
    /// confirmationDialog / toolbar / Menu / contextMenu). In this context a `Button`
    /// whose action isn't a recordable rule can't be slotted (the renderer can't put a
    /// native control inside an actions builder), so `emitButton` flags
    /// `hasUndispatchableAction` (the view demotes) instead of slotting. Saved/restored
    /// around each actions-list `emitItems` call so nested non-action content lowers
    /// normally.
    private var inActionListContext = false
    /// Names bound LOCALLY in the body (let/var, closure params, ForEach element) —
    /// a leaf referencing any can't render from a self-only slot closure.
    private var bodyLocals: Set<String> = []
    /// Body-local `let`/`var` bindings (G33) whose RHS is guest-resolvable and which
    /// the emitter EMITTED as real guest bindings (inside an immediately-invoked
    /// closure wrapping the body). Their names ARE in scope for sibling nodes + later
    /// `let`s + numeric/string-token resolution, so they're added to
    /// `guestResolvableNames`. A `let` whose RHS isn't guest-resolvable is NOT emitted
    /// (and stays out of this set) — a sibling reading it then correctly demotes via
    /// the body-level scope check (faithful over a broken guest compile).
    private var emittedLetNames: Set<String> = []
    /// `private`/`fileprivate` member names of the view (and their `$`-projected
    /// forms). The generated thunk lives in a SEPARATE file, so its slot closures
    /// CANNOT reference these (`'$x' is inaccessible due to 'private'`). A leaf that
    /// references one is therefore not slotable. Set by `BodyLowering`.
    var inaccessibleNames: Set<String> = []
    /// ALL of the view's OWN member names (stored + computed properties, methods, and
    /// `$`-projected forms) — regardless of access. A reference to a self member in a
    /// slot closure RESOLVES (it's `self.<name>`), so such a name must NOT be treated as
    /// a blocking body-local even when an `if let <selfProp> { … }` optional-binding
    /// elsewhere in the body SHADOWS it (which would otherwise pollute `bodyLocals` with
    /// the member name and wrongly block every OTHER leaf that reads the property). A
    /// PRIVATE self member stays blocked in separate-file mode via `inaccessibleNames`
    /// (a distinct set), so subtracting these from `bodyLocals` never unblocks a private
    /// member. Set by `BodyLowering`.
    var selfMemberNames: Set<String> = []
    /// PARAMETERIZED NATIVE SLOTS: per-body count of how many times each structural
    /// template (literals normalized to placeholders) has already been seen. Two
    /// sibling custom-view calls that are STRUCTURALLY identical but carry DIFFERENT
    /// string-literal values (`Foo(text:"A")` + `Foo(text:"B")`) would otherwise
    /// collapse to the same template id and the second would render the first's
    /// value. Appending the occurrence index to the 2nd+ id keeps each distinct
    /// WHILE staying literal-value-independent (so editing a literal keeps its id —
    /// the OTA-patchability invariant). Source-order visitation makes the index
    /// stable across literal edits; adding/removing a sibling is a structural edit
    /// that legitimately re-slots, same as any other structural change.
    private var parameterizedTemplateCounts: [String: Int] = [:]
    /// The view's stored-property names whose `kind` is an ARRAY-OF-SCALAR
    /// (`[Int]`/`[String]`/`[Double]`/`[Bool]`) — the inputs the guest CAN
    /// reconstruct from JSON (B's `_patchScan*Array` bindings make them available
    /// as bound `let`s in the guest). A `ForEach` whose collection is one of these
    /// can emit a REAL guest loop (the loop var binds over the bound array); a
    /// `ForEach` over anything else (a computed expression, a struct/object array)
    /// is DEMOTED to a native `.opaque` slot — never emitted with an unbound loop
    /// var (which would fail the whole-module compile). Set by `BodyLowering`.
    var scalarArrayInputNames: Set<String> = []
    /// The view's MARSHALLED scalar/string input names (`String`/`Bool`/`Int`/
    /// `Double`/`CGFloat` stored props the guest binds as `let`s). Used by
    /// `numericOrToken` to decide whether a numeric expression resolves in the guest
    /// as written (no token) or references an out-of-scope design-system constant (a
    /// token). Set by `BodyLowering`. (Array/struct-array names are tracked separately.)
    var marshalledInputNames: Set<String> = []
    /// The view's stored-property names whose `kind` is an ARRAY-OF-FLAT-STRUCT
    /// (`[SomeStruct]`) → the element descriptor (TASK 1). The guest reconstructs
    /// these via a generated mirroring `struct` + array-of-objects scanner (emitted by
    /// `SwiftUIGuestEmitter` from the input's `structElement`), bound as a `let` of
    /// `[_PatchRow_<Type>]`. A `ForEach(items){ item in … item.field … }` over one of
    /// these emits a REAL guest loop binding `item` (its fields resolve against the
    /// guest struct); a `ForEach` over anything else demotes to a native slot. Set by
    /// `BodyLowering`.
    var structArrayInputElements: [String: BodyLowering.ViewInput.StructElement] = [:]
    /// The view's SINGLE flat-struct input names → element descriptor (TASK 1). The guest
    /// binds each as `let item = _patchScan<Type>Row(blob,"item") ?? _PatchRow_<Type>()`, so
    /// a `Text(item.name)` / `if item.flag` resolves in scope (`guestResolvableNames` adds
    /// these). `BodyLowering.gateRichInputs` already proved every use is `item.<flatField>`.
    var flatStructInputElements: [String: BodyLowering.ViewInput.StructElement] = [:]
    /// The view's RAW-VALUE enum input names → element descriptor (TASK 2). The guest binds
    /// each to a mirroring `enum _PatchEnum_<Type>` decoded from the SDK's `{"case":"…"}`
    /// marshalling, so `s == .case` / `switch s` / `s.rawValue` resolve. The usage gate
    /// already proved the body uses the input only in a guest-reconstructable way.
    var enumInputElements: [String: BodyLowering.ViewInput.EnumElement] = [:]
    /// The view's COMPUTED SCALAR properties (G42): a get-only `var name: Bool/String/
    /// Int/Double/CGFloat { … }` whose body reads `@Environment`/state/Foundation the
    /// guest can't reconstruct (`var locked: Bool { !state.isPlus }`). A bare reference
    /// to one in a host-resolvable position (a `Text(status)`, a numeric modifier value
    /// `.padding(inset)`) is HOST-PROJECTED: the thunk's `__patchTokens()` evaluates
    /// `self.<name>` natively → a String/Double the SDK merges into the guest input JSON
    /// (reusing the `.string`/`.number` token path — no IR change). Only NON-private
    /// properties are here (the cross-file thunk can call `self.<name>` only if it's
    /// accessible). Set by `BodyLowering`. Maps name → its scalar kind.
    var computedScalarProps: [String: BodyLowering.ViewInput.Kind] = [:]
    /// Property/local names whose declared type is PROVABLY `Color` (a stored or computed
    /// `let/var name: Color`). Used to admit a BARE-IDENTIFIER color token (`.background(c)`
    /// where `let c: Color`) — without a proof of type, a bare identifier is NOT a color
    /// token (it could be a `some View`/function/custom type), so the modifier native-slots
    /// instead. Set by `BodyLowering` from the view decl. This is THE type-safety gate that
    /// makes "build-safe = demote-safe" hold for the bare-identifier color hazard.
    var colorTypedNames: Set<String> = []
    /// Property/local names whose declared type is PROVABLY `Font` (a stored or computed
    /// `let/var name: Font`). The `.font(<bare identifier>)` analogue of `colorTypedNames`.
    var fontTypedNames: Set<String> = []
    /// Property/local names whose declared type is PROVABLY a NUMERIC scalar (a stored or
    /// computed `let/var name: Int/Double/CGFloat/Float`). Used to admit a BARE-IDENTIFIER
    /// numeric token (`.cornerRadius(r)` where `let r: CGFloat`) — without a type proof, a
    /// bare identifier that reaches the numeric-token recorder (it failed the scope check
    /// AND isn't a known numeric computed property) carries an unknown type, so the thunk's
    /// `.number(Double(r))` could fail to compile (`r` not numeric-convertible). Set by
    /// `BodyLowering`. (Stored numeric inputs are already resolved verbatim by the scope
    /// check; this set guards the residual stored/computed accessible numeric props that
    /// weren't marshalled.)
    var numericTypedNames: Set<String> = []
    /// View member names whose declared type is PROVABLY a collection (`[T]`/`Set<T>`/`[K:V]`/
    /// `String`). The PROOF for host-projecting a `.count`/`.isEmpty` collection guard (BUG #13):
    /// a domain type with a custom `var isEmpty: Bool` is NOT a collection, so `(self.<that>).count`
    /// would fail to compile / pick the wrong branch. Only a base in this set admits the guard.
    var collectionTypedNames: Set<String> = []
    /// Member-access PATHS (`profile.name`, `profile.address.city`) whose declared/inferred
    /// leaf type is PROVABLY a non-optional `String`, resolved from the local struct catalog.
    /// The type-PROOF for admitting a BARE MEMBER-ACCESS string token (`Text(profile.name)`
    /// where `profile` is a `@State`/stored struct value with a `String` field): the thunk
    /// emits `.string(self.<path>)`, which compiles only when `<path>` is a `String`. A
    /// member access is structurally plausible but UNTYPED (`feature.description` is an
    /// `AttributedString`, `item.count` an `Int`), so the static `stringTokenTypeProvable`
    /// gate rejects bare member accesses; this set RE-ADMITS exactly the ones the catalog
    /// proves are `String`. Optional-scalar / non-String / collection fields are excluded
    /// (a `.string(String?)`/`.string(Int)` would not compile). Set by `BodyLowering`.
    /// Accessibility isn't filtered here — the recorder's `inaccessibleNames` scan demotes
    /// a private member read in the separate-file thunk; a same-file thunk reads it natively.
    var stringTypedMemberPaths: Set<String> = []
    /// HOST-PROJECTABLE single-hop SCALAR/Bool reads off the view's REACTIVE reference-type
    /// members: the member-access PATH `reactiveBase.scalarField` → its scalar kind
    /// (`.bool`/`.int`/`.double`). A reactive `@ObservedObject`/`@StateObject`/`@EnvironmentObject`/
    /// `@Environment(T.self)` model is non-reconstructable, but the build-time thunk CAN read
    /// `self.<base>.<field>` natively → a numeric token (Bool carried as 1.0/0.0). So a free
    /// `if viewModel.isOn { … }` / `.opacity(viewModel.isVisible ? 1 : 0)` host-projects instead
    /// of leaking the base identifier and demoting the whole view. Set by `BodyLowering`. Only a
    /// PROVABLY-scalar single-hop read is here; a deeper chain / Optional / object field is not
    /// (it demotes — faithful). (String reads go through `stringTypedMemberPaths` already.)
    var reactiveMemberScalarPaths: [String: BodyLowering.ViewInput.Kind] = [:]
    /// HOST-PROJECTABLE collection-guard PATHS off the view's REACTIVE members:
    /// `reactiveBase.collectionField` whose field is a collection. Its `.isEmpty`/`.count`
    /// host-projects (the thunk evaluates `(self.<base>.<field>).count` natively → a numeric
    /// token) — the v1.6.5 collection-guard, extended through a reactive member. The WHOLE
    /// collection is NOT marshalled (a `ForEach(vm.items)` still demotes); only the count/empty
    /// guard projects. Set by `BodyLowering`.
    var reactiveMemberCollectionPaths: Set<String> = []
    /// HOST-PROJECTABLE single-hop reads off the view's struct/enum INPUT params:
    /// `<structEnumInput>.<computedScalar/Font>` → its host-token kind (`.number`/`.string`/
    /// `.font`). The design-system `Size`-enum idiom (`size.iconSize` where `let size: Size`
    /// is an enum param and `Size.iconSize` is a computed `CGFloat`). The input is a
    /// non-reconstructable struct/enum value, but the build-time thunk CAN read
    /// `self.<input>.<member>` natively — so the read host-projects to a token instead of
    /// leaking the base identifier and demoting the whole view. A `.number`/`.string` rides
    /// the input JSON (`__numtok_`/`__strtok_`); a `.font` rides the tree (`.fontToken`). Set
    /// by `BodyLowering`. Only a PROVABLY-scalar/Font COMPUTED single-hop read is here; a
    /// method call / deeper chain / stored / non-scalar member is excluded (it demotes).
    var inputComputedMemberPaths: [String: BodyLowering.HostToken.Kind] = [:]
    /// The view's struct/enum INPUT param names (`size`, `meta`) — every stored `let`/`var`
    /// whose declared type is a plain-identifier (non-collection, non-scalar) type. A NUMERIC
    /// token must NEVER be recorded over a member access whose ROOT base is one of these unless
    /// that exact path is a `.number` entry in `inputComputedMemberPaths` (already projected in
    /// `numericOrToken` step b3) — otherwise `.number(Double(self.size.insets))` over an
    /// `EdgeInsets`/non-scalar member would mis-compile. THE demote-safety gate for the
    /// computed-member feature's interaction with the design-system numeric-token path. Set by
    /// `BodyLowering`.
    var structEnumInputBases: Set<String> = []
    /// Same-struct `some View`/`@ViewBuilder` helper members (name → body statements),
    /// inline-lowerable into the parent body (TASK 2). When the body references a
    /// helper (a bare `header`, or a no-arg `makeRow()`), the emitter substitutes the
    /// helper's body inline and lowers it in the SAME scope (its references resolve
    /// against the view's members/inputs) instead of emitting an `.opaque` slot. Set by
    /// `BodyLowering` (only no-arg, same-struct, body-lowerable helpers are collected).
    var helperBodies: [String: CodeBlockItemListSyntax] = [:]
    /// Helper names currently being inlined — a recursion guard so a helper that
    /// (directly or transitively) references itself can't expand forever. A re-entrant
    /// reference falls back to an `.opaque` slot (faithful: it renders natively).
    private var inliningHelpers: Set<String> = []

    private mutating func record(event: String, field: String,
                                 op: BodyLowering.MutationRule.Op) {
        mutationRules.append(.init(eventID: event, field: field, op: op))
    }

    mutating func emit(expr items: CodeBlockItemListSyntax) -> String {
        // Collect body-local names up front so opaque leaves can be classified as
        // slotable (renderable natively) vs not.
        // Subtract the view's OWN member names: an `if let <selfProp>` shadow elsewhere in
        // the body would otherwise add a self-member name to `bodyLocals` and wrongly block
        // every other leaf that reads that property (a slot reading `self.<prop>` compiles).
        // Private members stay blocked via `inaccessibleNames` (separate set).
        bodyLocals = LocalNameCollector.collect(in: items).subtracting(selfMemberNames)
        // Collect body-local `let`/`var` initializer sources (name → RHS) so a per-row
        // indexed slot can resolve a `ForEach(<alias>)` back to its accessible source.
        bodyLocalLetInits = Self.collectLetInitSources(in: items)
        return emitBuilderBlock(items)
    }

    /// Walk a body's statement list (recursing into `if`/`else`/`switch`/closure
    /// blocks) and record every SINGLE-binding `let`/`var` with a plain-identifier
    /// pattern → its initializer SOURCE. Used to resolve a body-local collection alias
    /// (`let owners = schedule.availableOwners`) back to its accessible initializer when
    /// lowering a per-row indexed slot. Multi-binding / destructured / accessor-block
    /// decls are skipped (they don't alias a single collection).
    static func collectLetInitSources(in items: CodeBlockItemListSyntax) -> [String: String] {
        var out: [String: String] = [:]
        let collector = LetInitSourceCollector()
        collector.walk(items)
        for (name, src) in collector.inits where out[name] == nil { out[name] = src }
        return out
    }

    /// Lower a ViewBuilder statement LIST (the body, an `if`/`else` branch block, a
    /// helper body) to ONE guest expression. Handles a body-local `let`/`var` binding
    /// (G33: `var body { let r = size*0.235; ZStack{…} }`) whose RHS is guest-resolvable
    /// by EMITTING it as a real guest binding inside an immediately-invoked closure that
    /// wraps the produced view nodes — so a sibling node reading `r` resolves in WASM.
    /// A `let` whose RHS isn't guest-resolvable is DROPPED (as before): the sibling that
    /// reads it then demotes via the body-level scope check (faithful over a broken
    /// guest compile). When no resolvable `let` was emitted this is exactly the prior
    /// behavior (single node verbatim, or a `Group` of multiple).
    private mutating func emitBuilderBlock(_ items: CodeBlockItemListSyntax) -> String {
        // Snapshot the emitted-let set so bindings introduced HERE don't leak into a
        // sibling block's scope (each builder block has its own closure scope).
        let savedLets = emittedLetNames
        defer { emittedLetNames = savedLets }
        var letBindings: [String] = []
        for item in items {
            guard case .decl(let d) = item.item,
                  let varDecl = d.as(VariableDeclSyntax.self) else { continue }
            if let binding = Self.emittableLetBinding(varDecl, resolvable: guestResolvableNames,
                                                      usesGeometry: usesGeometry) {
                letBindings.append(binding.source)
                emittedLetNames.insert(binding.name)
            }
        }
        let nodes = emitItems(items)
        // A body is a single view; if the builder produced multiple top-level nodes,
        // wrap them in a Group (matching @ViewBuilder semantics).
        let viewExpr: String = nodes.count == 1 ? nodes[0]
            : "N.group([\n" + nodes.map { indent($0) }.joined(separator: ",\n") + "\n])"
        guard !letBindings.isEmpty else { return viewExpr }
        // Wrap the bindings + node expression in an immediately-invoked closure so the
        // `let`s are real in-scope guest bindings (`GuestBoundNameCollector` picks them
        // up; the guest function compiles them). `[ViewNode]`/`ViewNode` return type is
        // inferred from the closure body's single `return`.
        var out = "{ () -> ViewNode in\n"
        for b in letBindings { out += indent(b) + "\n" }
        out += indent("return " + viewExpr) + "\n}()"
        return out
    }

    /// Emit a ForEach/loop ROW from its closure statements, treating them as a builder
    /// block so a ROW-LOCAL `let` (`let isPeak = idx == peakIdx`) rides into the guest
    /// (G33) instead of being dropped (a dropped row-local leaves a free reference that
    /// excludes the whole view). `loopVars` are the loop binding name(s) — already in
    /// `bodyLocals` from the top-level collect, but merged here defensively so a row-local
    /// `let`'s RHS over the loop var is judged resolvable. Restores `bodyLocals` after.
    private mutating func emitRowBuilder(_ stmts: CodeBlockItemListSyntax,
                                         loopVars: [String]) -> String {
        let saved = bodyLocals
        bodyLocals.formUnion(loopVars)
        defer { bodyLocals = saved }
        return emitBuilderBlock(stmts)
    }

    /// If `varDecl` is a SINGLE `let`/`var` binding with an initializer whose RHS is
    /// GUEST-RESOLVABLE (references only names currently in scope + safe globals) and a
    /// plain identifier pattern (no tuple/destructuring), return its name + the verbatim
    /// guest binding source (`let name = <rhs>`). Returns nil otherwise — the decl is
    /// dropped and any sibling reading the name demotes via the scope check. A
    /// type-annotated binding keeps the annotation (it's valid guest Swift). A binding
    /// with NO initializer (a forward `let x: T`) is never emittable.
    static func emittableLetBinding(_ varDecl: VariableDeclSyntax,
                                    resolvable: Set<String>,
                                    usesGeometry: Bool) -> (name: String, source: String)? {
        // Only a single binding (`let a = …`, not `let a = …, b = …`) is handled — a
        // multi-binding decl is rare in a body and conservatively dropped.
        guard varDecl.bindings.count == 1, let binding = varDecl.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let initializer = binding.initializer else { return nil }
        // A computed/observed binding (`{ get }`/`willSet`) isn't a value binding.
        guard binding.accessorBlock == nil else { return nil }
        let rhs = initializer.value.trimmedDescription
        // The RHS must resolve in the guest scope as written (only in-scope names +
        // safe globals). A `let r = size * 0.235` over a marshalled `size` resolves; a
        // `let owners = schedule.filteredOwners` (an out-of-scope service) does not → drop.
        let check = SwiftUIGuestScopeCheck.check(
            guestBody: rhs, inputNames: resolvable, usesGeometry: usesGeometry)
        guard check.isCompilable else { return nil }
        let kw = varDecl.bindingSpecifier.text   // "let" or "var"
        let typeAnno = binding.typeAnnotation?.trimmedDescription ?? ""
        let anno = typeAnno.isEmpty ? "" : " " + typeAnno
        return (name, "\(kw) \(name)\(anno) = \(rhs)")
    }

    /// Lower an ACTIONS-LIST closure (alert/confirmationDialog/toolbar/Menu/contextMenu
    /// actions) with `inActionListContext` set, so a `Button` whose action isn't a
    /// recordable rule flags `hasUndispatchableAction` (→ the view demotes) instead of
    /// silently lowering to a dead `N.button` — the renderer can't attach a native slot to
    /// an actions-list entry. The flag is restored after (nested non-action content lowers
    /// normally on the next call).
    private mutating func emitActionItems(_ items: CodeBlockItemListSyntax) -> [String] {
        let saved = inActionListContext
        inActionListContext = true
        defer { inActionListContext = saved }
        return emitItems(items)
    }

    private mutating func emitItems(_ items: CodeBlockItemListSyntax) -> [String] {
        var out: [String] = []
        for item in items {
            if case .expr(let e) = item.item {
                // A `#if os(iOS) … #else … #endif` compilation conditional in the body
                // (G24): an `#if` parses as a postfix `IfConfigExpr` here. Pick the
                // iOS-applicable clause and emit its elements inline (the engine targets
                // iOS — the other platforms' branches never ship).
                if let ifConfig = e.as(IfConfigDeclSyntax.self) {
                    out.append(contentsOf: emitIfConfig(ifConfig)); continue
                }
                out.append(emitExpr(e))
            } else if case .stmt(let s) = item.item,
                      let exprStmt = s.as(ExpressionStmtSyntax.self) {
                out.append(emitExpr(exprStmt.expression))
            } else if case .decl(let d) = item.item,
                      let ifConfig = d.as(IfConfigDeclSyntax.self) {
                // A `#if` in statement/decl position (G24) — same iOS-branch pick.
                out.append(contentsOf: emitIfConfig(ifConfig))
            }
            // other decls (plain `let`s) are handled by `emitBuilderBlock` (G33);
            // an unhandled decl here is setup, not a node.
        }
        return out
    }

    /// Pick the iOS-applicable branch of an `#if`/`#elseif`/`#else` compilation
    /// conditional in a view body (G24) and emit its elements inline. The engine
    /// compiles for iOS, so a `#if os(iOS)` / `#if !os(macOS)` / `#if canImport(UIKit)`
    /// clause is taken, a `#if os(macOS)` clause is dropped, and an `#else` is taken only
    /// when no preceding clause matched. A condition we can't classify (a `compiler(…)` /
    /// custom flag) conservatively picks the FIRST clause (the source's primary build) —
    /// faithful to the developer's default config. The chosen elements lower like any
    /// builder statement list (so a `let` inside survives via the normal path).
    private mutating func emitIfConfig(_ ifConfig: IfConfigDeclSyntax) -> [String] {
        var chosen: IfConfigClauseSyntax?
        for clause in ifConfig.clauses {
            if clause.poundKeyword.tokenKind == .poundElse {
                if chosen == nil { chosen = clause }   // `#else` taken iff nothing matched
                break
            }
            // `#if`/`#elseif` — evaluate its platform condition for an iOS target.
            if let cond = clause.condition, Self.ifConfigConditionHoldsForIOS(cond) {
                chosen = clause
                break
            }
        }
        // No clause matched and no `#else` → emit nothing (the construct is compiled out).
        guard let elements = chosen?.elements?.as(CodeBlockItemListSyntax.self) else { return [] }
        return emitItems(elements)
    }

    /// Whether a `#if` condition holds when compiling for iOS. Recognizes the common
    /// platform predicates: `os(iOS)` (true), `os(macOS)`/`os(watchOS)`/`os(tvOS)`/
    /// `os(visionOS)`/`os(Linux)`/`os(Windows)` (false for iOS), `canImport(UIKit)`
    /// (true — UIKit imports on iOS), `canImport(AppKit)` (false), `targetEnvironment(...)`
    /// (`macCatalyst` false, `simulator` we treat as build-dependent → true so a
    /// simulator-only branch isn't dropped), and the boolean combinators `!`/`&&`/`||`.
    /// An UNRECOGNIZED condition (a custom build flag, `compiler(>=…)`, `swift(>=…)`)
    /// conservatively returns TRUE so we don't drop a clause we can't reason about — the
    /// caller takes the FIRST matching clause (the developer's primary configuration).
    static func ifConfigConditionHoldsForIOS(_ cond: ExprSyntax) -> Bool {
        let trimmed = cond.trimmedDescription
        // Boolean negation.
        if let prefix = cond.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
            return !ifConfigConditionHoldsForIOS(prefix.expression)
        }
        // `a && b` / `a || b` combinators (folded or unfolded — match on the operator).
        if let seq = cond.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            // Find a top-level `&&`/`||` operator.
            for (i, el) in elems.enumerated() {
                if let op = el.as(BinaryOperatorExprSyntax.self) {
                    let lhs = ExprSyntax(elems[0..<i].first ?? el)
                    let rhsElems = Array(elems[(i + 1)...])
                    if let rhsFirst = rhsElems.first {
                        let lOK = ifConfigConditionHoldsForIOS(lhs)
                        let rOK = ifConfigConditionHoldsForIOS(ExprSyntax(rhsFirst))
                        if op.operator.text == "&&" { return lOK && rOK }
                        if op.operator.text == "||" { return lOK || rOK }
                    }
                }
            }
        }
        if let infix = cond.as(InfixOperatorExprSyntax.self),
           let op = infix.operator.as(BinaryOperatorExprSyntax.self) {
            let lOK = ifConfigConditionHoldsForIOS(infix.leftOperand)
            let rOK = ifConfigConditionHoldsForIOS(infix.rightOperand)
            if op.operator.text == "&&" { return lOK && rOK }
            if op.operator.text == "||" { return lOK || rOK }
        }
        // Parenthesized.
        if let tup = cond.as(TupleExprSyntax.self), tup.elements.count == 1,
           let only = tup.elements.first, only.label == nil {
            return ifConfigConditionHoldsForIOS(only.expression)
        }
        // `os(X)` / `canImport(X)` / `targetEnvironment(X)` predicate calls.
        if let call = cond.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let arg = call.arguments.first?.expression.trimmedDescription ?? ""
            switch callee.baseName.text {
            case "os":
                return arg == "iOS"
            case "canImport":
                // UIKit imports on iOS; AppKit does not. Anything else: assume importable
                // (don't drop a clause guarding a module we can't reason about).
                if arg == "AppKit" { return false }
                return true
            case "targetEnvironment":
                // macCatalyst is a distinct target (false); `simulator` is iOS-buildable.
                return arg != "macCatalyst"
            default:
                return true   // unknown predicate → don't drop the clause
            }
        }
        // A bare custom flag (`DEBUG`, `MYFLAG`) or anything else unrecognized: assume
        // active so the clause isn't dropped (the developer's primary configuration).
        _ = trimmed
        return true
    }

    private mutating func emitExpr(_ expr: ExprSyntax) -> String {
        if let ifExpr = expr.as(IfExprSyntax.self) {
            return emitIf(ifExpr)
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return emitCall(call)
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            // `self.header` referencing a same-struct `some View` helper — inline-lower
            // it (TASK 2). Checked BEFORE `emitBareMember` (which would slot it).
            if member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self",
               let inlined = emitInlineHelper(name: member.declName.baseName.text) {
                return inlined
            }
            return emitBareMember(member)
        }
        // A bare reference to a same-struct `some View` helper property (`header`) —
        // inline-lower its body in place (TASK 2).
        if let ref = expr.as(DeclReferenceExprSyntax.self),
           let inlined = emitInlineHelper(name: ref.baseName.text) {
            return inlined
        }
        // A `switch <subject> { case … }` view-builder body. As a bare leaf its source
        // (`switch x { … }`) can't be wrapped `AnyView(switch …)` (a `switch` is illegal in
        // argument position). Route it through `opaqueViewBuilder` so the slot source is
        // `Group { switch … }` — VALID Swift when the arms are view EXPRESSIONS. The
        // `recordOpaque` AnyView-wrappability gate then ships it iff that `Group`-wrapped form
        // compiles (bare view-expression arms) and demotes it iff not (statement/`return`
        // arms, heterogeneous arms) — never an emitted broken wrap.
        //
        // PARAMETERIZED-SWITCH FAST PATH (A1 fix): when the switch SUBJECT is a marshalled
        // guest input AND every arm's body is a single opaqueCall-able function call, lower
        // each arm as its own parameterized `opaqueCall` slot (string literals ride WASM via
        // slotArgs → stringArgRanges → fingerprint-stable) and emit a guest-side `if/else`
        // chain that dispatches on the subject's value. This is the fix for OnboardingFlow's
        // `switch page { case 0: onboardingContent(title:"Find…") default: onboardingContent(title:"Plan…") }`
        // — the title strings no longer bake into nativeSurface, so editing them ships OTA.
        // DEMOTE-SAFE: only taken when (a) subject is a plain identifier/member that the guest
        // resolves, (b) EVERY arm has exactly one statement that is a single call expression
        // with no non-slotable references, (c) the arm's call is free of body-local/private
        // names beyond any lifted string args. Any deviation falls through to `opaqueViewBuilder`.
        if let sw = expr.as(SwitchExprSyntax.self),
           let switchNode = emitSwitchAsParameterizedSlots(sw) {
            return switchNode
        }
        if expr.is(SwitchExprSyntax.self) {
            return opaqueViewBuilderLifted(expr, labelHint: "switch")
        }
        return opaqueExprLifted(expr)
    }

    /// Inline-lower a same-struct helper member's body (TASK 2): substitute the
    /// helper's body statements into the parent IR and lower them in the SAME scope
    /// (the helper's references — self members, inputs — resolve identically). Returns
    /// nil when `name` isn't a collected inlinable helper, or it's already being
    /// inlined (recursion guard) → the caller slots the reference as before. A helper
    /// whose body is multiple top-level views wraps them in a `group` (@ViewBuilder
    /// semantics), matching `emit(expr:)`.
    private mutating func emitInlineHelper(name: String) -> String? {
        guard let stmts = helperBodies[name] else { return nil }
        // Re-entrant reference (a helper that references itself, directly or via a
        // chain) → don't expand forever; fall back to a native slot for this use.
        guard inliningHelpers.insert(name).inserted else { return nil }
        defer { inliningHelpers.remove(name) }
        // The helper's OWN body-locals (its `let`/`var`, closure/ForEach params) aren't
        // in the parent's `bodyLocals` set, so a NON-lowerable leaf inside the helper
        // that references one would be wrongly judged slotable — and its slot closure
        // `{ AnyView(<leaf>) }` (emitted in the cross-file thunk) would not compile.
        // Merge them in for the duration of this inline emit so such a leaf is correctly
        // non-slotable (the view stays native — demote-safe), then restore.
        let savedLocals = bodyLocals
        bodyLocals.formUnion(LocalNameCollector.collect(in: stmts))
        defer { bodyLocals = savedLocals }
        let nodes = emitItems(stmts)
        guard !nodes.isEmpty else { return nil }
        if nodes.count == 1 { return nodes[0] }
        return "N.group([\n" + nodes.map { indent($0) }.joined(separator: ",\n") + "\n])"
    }

    private mutating func emitIf(_ ifExpr: IfExprSyntax) -> String {
        // `if #available(iOS NN, *) { … } else { … }` (G25): the device running an OTA
        // patch always meets the SDK deployment floor, so the AVAILABLE branch is taken.
        // Emit the `then` branch's lowered nodes inline (drop the `else`). A condition
        // that ALSO has a non-availability term (`#available(…) && flag`) is NOT this
        // simple form — it falls through to the normal handling (which slots it).
        if Self.isSoleAvailabilityCondition(ifExpr.conditions) {
            let thenNodes = emitItems(ifExpr.body.statements)
            if thenNodes.count == 1 { return thenNodes[0] }
            return "N.group([\n" + thenNodes.map { indent($0) }.joined(separator: ",\n") + "\n])"
        }
        // Emit a Swift ternary that picks between the lowered branches. The guest
        // evaluates the condition from marshalled inputs. ONLY a plain BOOLEAN condition
        // lowers — an optional binding (`if let x = opt`) or pattern match (`if case …`)
        // can't be a ternary condition (and the unwrapped binding `x` wouldn't exist in
        // the guest), so such an `if` DEMOTES the whole expression to a native slot
        // rather than emit invalid guest code (`((let x = opt) ? …)`) that would fail the
        // WHOLE module compile and ship NO views. Faithful: the branch renders natively.
        guard Self.isPlainBooleanCondition(ifExpr.conditions) else {
            // Wrap in `Group { … }` so the thunk's `{ AnyView(<source>) }` is valid
            // Swift — a bare `if let`/ViewBuilder block can't be wrapped in `AnyView(…)`.
            return opaqueViewBuilderLifted(ExprSyntax(ifExpr), labelHint: "if")
        }
        // HOST-PROJECT BODY-LOCAL-COLLECTION GUARDS: a guard `if owners.count > 1 { … }`
        // over a body-local collection alias (`let owners = schedule.availableOwners`)
        // leaks `owners` as a free guest identifier (the count is host-side). Rewrite each
        // `<alias>.count`/`.isEmpty` against a host NUMERIC token (the thunk resolves the
        // real collection's `.count` over `self`) so the condition compiles in the guest.
        // Used for the per-row indexed-slot guard (`AccountSwitcher`). If a body-local
        // reference in the condition CAN'T be projected, the rewrite returns nil and the
        // whole `if` demotes to a native slot (faithful over a free-identifier leak).
        let rawCond = ifExpr.conditions.trimmedDescription
        // A body-local the GUEST can't resolve (a DROPPED `let owners = schedule.…`, not a
        // G33-emitted binding, not a loop/closure var in scope) would leak as a free guest
        // identifier in the verbatim ternary. The guest-resolvable body-locals (emitted
        // `let`s + loop/closure vars) are fine. So treat ONLY the NON-resolvable body-locals
        // as "needs projection".
        let unresolvableLocals = bodyLocals.subtracting(guestResolvableLocalNames)
        // ALSO project self-accessible PROPERTY collection guards (`plantsForSelectedDate.isEmpty`,
        // `plants.isEmpty`) — a computed/`@Query`/stored collection's `.count`/`.isEmpty` that
        // would otherwise leak the property as a free guest symbol and demote the view. The
        // thunk evaluates `(self.<prop>).count` natively → a numeric token (the SAME mechanism
        // as a body-local alias). The #1 SwiftData/data-view condition blocker.
        let projectionTargets = unresolvableLocals.union(
            collectionGuardPropertyNames(ifExpr.conditions))
        // REACTIVE-MEMBER projection (the reactive view-model lever): a condition that reads a
        // reactive ref-type member (`if viewModel.isOn`, `if vm.items.isEmpty`) leaks the base
        // as a free guest symbol. Host-project each such read to a numeric token (the thunk
        // reads `self.vm.<field>` natively). Tried BEFORE the verbatim path — a reactive base is
        // never guest-resolvable. If projection can't fully cover the condition (an unprojectable
        // reactive use remains), fall through to the existing body-local / demote handling.
        let reactiveBases = Self.reactiveBases(scalarPaths: reactiveMemberScalarPaths,
                                               collectionPaths: reactiveMemberCollectionPaths)
        let condReadsReactive = !reactiveBases.isEmpty
            && BodyLowering.guestBodyReferencesAny(rawCond, names: reactiveBases)
        let cond: String
        if condReadsReactive {
            // Snapshot tokens so a partial/failed projection doesn't orphan the ones
            // `hostProjectReactiveReads` appended (we demote below if it can't fully cover).
            let tokenSnapshot = hostTokens.count
            // MIXED-CONDITION SAFETY: a `vm.isOn && owners.count > 0` projects `vm.isOn` but a
            // residual NON-resolvable body-local (`owners`) would still leak. Accept the
            // reactive projection ONLY when no body-local projection target survives.
            if let projected = hostProjectReactiveReads(in: rawCond),
               !BodyLowering.guestBodyReferencesAny(projected, names: projectionTargets) {
                cond = projected
            } else {
                // Couldn't fully project the reactive condition — demote (never leak the base).
                if hostTokens.count > tokenSnapshot { hostTokens.removeLast(hostTokens.count - tokenSnapshot) }
                return opaqueViewBuilderLifted(ExprSyntax(ifExpr), labelHint: "if")
            }
        } else if !Self.conditionReferencesBodyLocal(ifExpr.conditions, bodyLocals: projectionTargets) {
            cond = rawCond
        } else if let projected = hostProjectCollectionGuard(ifExpr.conditions,
                                                             unresolvable: projectionTargets) {
            cond = projected
        } else {
            return opaqueViewBuilderLifted(ExprSyntax(ifExpr), labelHint: "if")
        }
        let thenNodes = emitItems(ifExpr.body.statements)
        let thenExpr = thenNodes.count == 1 ? thenNodes[0]
            : "N.group([" + thenNodes.joined(separator: ", ") + "])"
        var elseExpr = "N.group([])"
        if let elseBody = ifExpr.elseBody {
            switch elseBody {
            case .codeBlock(let cb):
                let n = emitItems(cb.statements)
                elseExpr = n.count == 1 ? n[0] : "N.group([" + n.joined(separator: ", ") + "])"
            case .ifExpr(let nested):
                elseExpr = emitIf(nested)
            }
        }
        return "((\(cond)) ? \(thenExpr) : \(elseExpr))"
    }

    /// Try to lower a `switch <subject> { case V: call(…) … default: call(…) }` whose
    /// subject is a MARSHALLED GUEST INPUT into a guest-side `if/else` chain where each
    /// arm is an individually PARAMETERIZED `opaqueCall` slot.
    ///
    /// This is the A1 fix for the OnboardingFlow fingerprint-mismatch bug: string literals
    /// passed to per-arm helper calls (e.g. `onboardingContent(title:"Plan the YEAR…")`)
    /// are lifted into `slotArgs`/`stringArgRanges` and no longer bake into `nativeSurface`,
    /// so editing a title ships OTA without changing the native-shell fingerprint.
    ///
    /// PRECONDITIONS (all must hold; returns nil on any failure → caller falls back to opaqueViewBuilder):
    ///   (a) Subject is a single `DeclReferenceExprSyntax` (bare name, no member chain) that
    ///       resolves as a marshalled guest input (`guestResolvableNames` contains it).
    ///   (b) Every case is a non-`@unknown` case with exactly ONE statement that is a single
    ///       `ExpressionStmtSyntax` wrapping a `FunctionCallExprSyntax`.
    ///   (c) Each arm call passes `isSlotable` (no reference to body-locals/inaccessible names).
    ///   (d) There is at most ONE `default` arm.
    ///   (e) Non-default arms use a single integer or string literal pattern (so the condition
    ///       can be expressed as `subjectName == V`).
    ///
    /// The emitted guest code is a RIGHT-ASSOCIATIVE chain of ternaries:
    ///   `((page == 0) ? slot0 : ((page == 1) ? slot1 : slotDefault))`
    ///
    /// DEMOTE-SAFE: returning nil means the caller uses `opaqueViewBuilder` (today's path) —
    /// no regression. We never emit partial or broken guest code.
    private mutating func emitSwitchAsParameterizedSlots(_ sw: SwitchExprSyntax) -> String? {
        // (a) Subject must be a bare name that IS a MARSHALLED SCALAR GUEST INPUT (not
        // merely any body-resolvable name). We check `marshalledInputNames` directly because:
        //   - `guestResolvableNames` also includes body-locals (including DROPPED `let idx = …`
        //     whose RHS references out-of-scope symbols), which must NOT trigger this path —
        //     the guest has no real binding for them.
        //   - Only scalar `@State`/`let`/`var` inputs (string/bool/int/double) are guaranteed
        //     to be in the guest's `let` bindings from the input JSON.
        guard let subjectRef = sw.subject.as(DeclReferenceExprSyntax.self) else { return nil }
        let subjectName = subjectRef.baseName.text
        guard marshalledInputNames.contains(subjectName) else { return nil }

        // Collect the arms: (condition string or nil for default, call expr).
        struct Arm {
            var condition: String?   // nil → default
            var call: FunctionCallExprSyntax
        }
        var arms: [Arm] = []
        var defaultCount = 0

        for caseItem in sw.cases {
            // `sw.cases` is `SwitchCaseListSyntax` whose elements are an `Element` enum:
            // `.switchCase(SwitchCaseSyntax)` or `.ifConfigDecl(IfConfigDeclSyntax)`.
            // Any `#if` conditional in the case list means we can't statically enumerate
            // the arms → fall back to the safe `opaqueViewBuilder` path.
            guard case .switchCase(let swCase) = caseItem else { return nil }
            // Label: either a `case` list or `default`.
            let isDefault: Bool
            var conditionStr: String? = nil
            switch swCase.label {
            case .case(let caseLabel):
                // Support exactly ONE item per arm with a single literal pattern (integer or string).
                let items = Array(caseLabel.caseItems)
                guard items.count == 1 else { return nil }
                let pat = items[0].pattern
                if let expr = pat.as(ExpressionPatternSyntax.self) {
                    let raw = expr.expression.trimmedDescription
                    // Accept integer literal or string literal patterns.
                    if let intExpr = expr.expression.as(IntegerLiteralExprSyntax.self) {
                        conditionStr = "\(subjectName) == \(intExpr.literal.text)"
                    } else if expr.expression.as(StringLiteralExprSyntax.self) != nil {
                        conditionStr = "\(subjectName) == \(raw)"
                    } else {
                        return nil  // Not a simple literal pattern — fall back.
                    }
                } else {
                    return nil  // Non-expression pattern (tuple, `is`, etc.) — fall back.
                }
                isDefault = false
            case .default:
                defaultCount += 1
                if defaultCount > 1 { return nil }
                isDefault = true
            }

            // Body must be exactly ONE expression statement wrapping a function call.
            // In a switch-case body, a bare function call is parsed as `.expr(ExprSyntax)`
            // (not `.stmt(ExpressionStmtSyntax)`), so we must handle both item kinds.
            let stmts = Array(swCase.statements)
            guard stmts.count == 1 else { return nil }
            let callExpr: FunctionCallExprSyntax
            switch stmts[0].item {
            case .expr(let e):
                guard let c = e.as(FunctionCallExprSyntax.self) else { return nil }
                callExpr = c
            case .stmt(let s):
                guard let exprStmt = s.as(ExpressionStmtSyntax.self),
                      let c = exprStmt.expression.as(FunctionCallExprSyntax.self) else { return nil }
                callExpr = c
            case .decl:
                return nil
            }
            // (c) Slotability check: the call must not reference body-locals / inaccessible names.
            guard Self.isSlotable(ExprSyntax(callExpr), blocked: bodyLocals.union(inaccessibleNames)) else {
                return nil
            }

            arms.append(Arm(condition: isDefault ? nil : conditionStr, call: callExpr))
        }

        // Need at least 2 arms (a trivial single-arm switch is handled fine by opaqueViewBuilder).
        guard arms.count >= 2 else { return nil }
        // Exactly one default (or none — a switch without a default is fine too).
        guard defaultCount <= 1 else { return nil }

        // All checks passed. Emit each arm as a parameterized opaqueCall slot.
        // Snapshot leaf count so we can roll back if opaqueCall fails to produce any
        // parameterized leaf (shouldn't happen given the checks, but be safe).
        let leafSnapshot = opaqueLeaves.count
        let tokenSnapshot = hostTokens.count
        var armNodes: [String] = []
        for arm in arms {
            // Get the label hint from the callee name (for descriptive slot label).
            let label: String
            if let callee = arm.call.calledExpression.as(DeclReferenceExprSyntax.self) {
                label = callee.baseName.text
            } else {
                label = "switch_arm"
            }
            // opaqueCall will parameterize string literals and record the leaf.
            let node = opaqueCall(arm.call, labelHint: label)
            armNodes.append(node)
        }

        // Build the guest-side if/else chain from right to left.
        // Arms: zip with conditions. The default arm (condition == nil) must be LAST.
        // Sort: non-default arms first, default arm last.
        let nonDefaultArms = zip(arms, armNodes).filter { $0.0.condition != nil }
        let defaultArm = zip(arms, armNodes).first { $0.0.condition == nil }

        // Must have at least one non-default arm with a condition to form a ternary.
        guard !nonDefaultArms.isEmpty else {
            // All arms are default — roll back and fall through.
            opaqueLeaves.removeLast(opaqueLeaves.count - leafSnapshot)
            hostTokens.removeLast(hostTokens.count - tokenSnapshot)
            return nil
        }

        // The fallback (else) node: use the default arm's slot, or an empty group.
        let fallbackNode = defaultArm?.1 ?? "N.group([])"

        // Build the chain right-to-left: last non-default arm wraps the default fallback,
        // then each preceding arm wraps the result.
        var result = fallbackNode
        for (arm, node) in nonDefaultArms.reversed() {
            result = "((\(arm.condition!)) ? \(node) : \(result))"
        }
        return result
    }

    /// The body-local names the GUEST can resolve as written: the G33-emitted `let`
    /// bindings (their RHS was guest-resolvable, so they're real guest `let`s) — plus any
    /// loop/closure params currently merged into `bodyLocals` (those are bound in the
    /// guest loop/closure). A DROPPED `let` (whose RHS wasn't guest-resolvable, like
    /// `let owners = schedule.…`) is NOT here, so a condition reading it needs projection.
    private var guestResolvableLocalNames: Set<String> {
        // emittedLetNames covers G33 bindings. A loop/closure param added to bodyLocals
        // during row/closure emission is resolvable in that scope; at the top body level
        // there are none, so emittedLetNames is the operative set there. We approximate
        // "resolvable local" as the emitted lets plus the loop/closure-bound names the
        // marshalled-input scope already tracks — but to stay conservative (and correct
        // for the AccountSwitcher case), only emittedLetNames is treated as resolvable.
        emittedLetNames
    }

    /// True iff the `if` condition references ANY of `bodyLocals` (so it can't be emitted
    /// verbatim into the guest ternary). Parses the condition + scans for a live
    /// `DeclReferenceExpr` (or member-access base) whose identifier is in the set.
    static func conditionReferencesBodyLocal(_ conditions: ConditionElementListSyntax,
                                             bodyLocals: Set<String>) -> Bool {
        guard !bodyLocals.isEmpty else { return false }
        // Subtract names bound WITHIN the condition's own closures/bindings before scanning —
        // exactly as `isSlotable` subtracts internal bindings. A `$0` inside a condition closure
        // (`if list.filter { !$0.isEmpty }.count == 0`) is collected scope-unaware into
        // `bodyLocals` by `LocalNameCollector`, but it is NOT a free guest identifier (it's bound
        // within the `filter` closure). Pre-fix this falsely demoted the whole `if` block (a very
        // common SwiftUI pattern — kiwix-apple `SearchResults`, ACHNBrowserUI `TurnipsFormView`).
        // A genuinely-dropped `let` body-local READ by the condition (e.g. `let owners =
        // schedule.owners; if owners.isEmpty`) is NOT internally bound → still flagged → demotes.
        // The rare shadowing edge (`if let x = x` over a body-local `x`) is caught downstream by
        // the guest scope check (a free guest identifier demotes the view), so this is demote-safe.
        let internalBindings = LocalNameCollector.collect(in: Syntax(conditions))
        let effective = bodyLocals.subtracting(internalBindings)
        guard !effective.isEmpty else { return false }
        return BodyLowering.guestBodyReferencesAny(conditions.trimmedDescription, names: effective)
    }

    /// HOST-PROJECT a body-local-COLLECTION guard condition: rewrite each
    /// `<bodyLocalAlias>.count` / `<bodyLocalAlias>.isEmpty` — where `<bodyLocalAlias>`
    /// resolves (through `bodyLocalLetInits`) to an ACCESSIBLE collection source — into a
    /// reference against a host NUMERIC token (the thunk evaluates `(<resolved>).count`
    /// natively over `self`). `.count` → `Int(__numtok_<id>)`, `.isEmpty` →
    /// `(__numtok_<id> == 0)`. Returns the rewritten condition source iff EVERY body-local
    /// reference in the condition was projected away (no free guest identifier remains);
    /// nil otherwise (→ caller demotes the whole `if` to a native slot). Demote-safe: a
    /// guard we can't fully project never ships a broken guest condition.
    private mutating func hostProjectCollectionGuard(_ conditions: ConditionElementListSyntax,
                                                     unresolvable: Set<String>) -> String? {
        // Parse the condition list as an expression list so we can locate member accesses.
        let condSource = conditions.trimmedDescription
        let probe = Parser.parse(source: "let __patch_cond = (\(condSource))")
        guard let valueExpr = Self.tokenProbeValueExpr(probe) else { return nil }
        // Find every `<base>.count` / `<base>.isEmpty` whose base is a bare NON-resolvable
        // body-local collection alias (a dropped `let owners = schedule.…`). A resolvable
        // local stays verbatim (the guest has it). Collect the hits, then substitute.
        let finder = CollectionGuardMemberFinder(bodyLocals: unresolvable)
        finder.walk(valueExpr)
        guard !finder.hits.isEmpty else { return nil }
        // Build the replacement for each hit; bail if any base can't be resolved to an
        // accessible source (a body-local that isn't an alias of a self-reachable value).
        var replacements: [(node: ExprSyntax, text: String)] = []
        for hit in finder.hits {
            guard let resolved = resolveAccessibleCollectionSource(hit.base) else { return nil }
            let id = "nt_" + Self.stableHash64("count|\(resolved)")
            if !hostTokens.contains(where: { $0.id == id }) {
                hostTokens.append(.init(id: id, source: "(\(resolved)).count", kind: .number))
            }
            let key = BodyLowering.numericTokenInputKey(id)
            let replacement: String
            switch hit.member {
            case "count":   replacement = "Int(\(key))"
            case "isEmpty": replacement = "(\(key) == 0)"
            default: return nil
            }
            replacements.append((hit.fullExpr, replacement))
        }
        // Apply the substitutions by trimmed-description string replacement (each hit's
        // full member-access source is unique enough in a small guard; we replace the
        // longest first to avoid `a.count` clobbering inside `a.countX` — member names are
        // exact so this is safe). Operate on the ORIGINAL condition source.
        var out = condSource
        for (node, text) in replacements.sorted(by: { $0.node.trimmedDescription.count > $1.node.trimmedDescription.count }) {
            out = out.replacingOccurrences(of: node.trimmedDescription, with: text)
        }
        // VERIFY: the rewritten condition references no NON-resolvable body-local (full
        // projection). A resolvable local (an emitted G33 `let`) may legitimately remain.
        if BodyLowering.guestBodyReferencesAny(out, names: unresolvable) { return nil }
        return out
    }

    /// HOST-PROJECT every read off a REACTIVE reference-type member in `source` (a condition
    /// or a numeric-modifier value). Rewrites:
    ///   • a SCALAR/Bool read `vm.field` → a numeric (Bool→1.0/0.0) token reference. A Bool
    ///     becomes `(__numtok_<id> != 0)`; an Int/Double becomes `Int(__numtok_<id>)` /
    ///     `__numtok_<id>` (the caller's position determines the cast). The thunk evaluates
    ///     `self.vm.field` natively → a Double.
    ///   • a collection guard `vm.coll.isEmpty`/`.count` → `(__numtok_<id> == 0)` / `Int(__numtok_<id>)`
    ///     (the thunk evaluates `(self.vm.coll).count`).
    /// Returns the rewritten source, or nil if ANY reactive base is used unprojectably (a bare
    /// pass / method / deep chain / unknown field) — then the caller demotes (a residual base
    /// would leak as a free guest symbol). `numericContext` controls a scalar Bool's spelling:
    /// in a Bool position (an `if` condition) a Bool projects to `(... != 0)`; in a NUMERIC
    /// position the Bool isn't expected (it would be inside a ternary CONDITION, still Bool).
    /// All scalar reads project as a numeric token regardless; the Bool spelling `(x != 0)` is
    /// valid in a condition and as a ternary test in a numeric value.
    mutating func hostProjectReactiveReads(in source: String) -> String? {
        guard !reactiveMemberScalarPaths.isEmpty || !reactiveMemberCollectionPaths.isEmpty else { return nil }
        let bases = Self.reactiveBases(scalarPaths: reactiveMemberScalarPaths,
                                       collectionPaths: reactiveMemberCollectionPaths)
        guard !bases.isEmpty else { return nil }
        let probe = Parser.parse(source: "let __patch_rx = (\(source))")
        guard let valueExpr = Self.tokenProbeValueExpr(probe) else { return nil }
        let finder = ReactiveMemberReadFinder(bases: bases,
                                              scalarPaths: reactiveMemberScalarPaths,
                                              collectionPaths: reactiveMemberCollectionPaths)
        finder.walk(valueExpr)
        // Need at least one projectable hit, and NO unprojectable reactive use (else a base leaks).
        guard !finder.scalarHits.isEmpty || !finder.collectionHits.isEmpty else { return nil }
        guard !finder.hasUnprojectableUse else { return nil }

        // Build the replacement for each hit (longest-source first so a shorter path doesn't
        // clobber inside a longer one). A scalar Bool → `(__numtok != 0)`; an Int/Double →
        // `Double(__numtok)` (a numeric-position value) — but in a Bool/comparison context the
        // numeric value participates as written. We substitute the SCALAR with the raw Double
        // key for Int/Double and the `(key != 0)` form for Bool; the collection guard with
        // `Int(key)` (count) / `(key == 0)` (isEmpty).
        var replacements: [(text: String, with: String)] = []
        for hit in finder.scalarHits {
            let id = "nt_" + Self.stableHash64("rx|" + hit.path)
            if !hostTokens.contains(where: { $0.id == id }) {
                let src: String
                switch hit.kind {
                case .bool:  src = "((self.\(hit.path)) ? 1.0 : 0.0)"
                default:     src = "Double(self.\(hit.path))"
                }
                hostTokens.append(.init(id: id, source: src, kind: .number))
            }
            let key = BodyLowering.numericTokenInputKey(id)
            let with: String
            switch hit.kind {
            case .bool:  with = "(\(key) != 0)"
            case .int:   with = "Int(\(key))"
            default:     with = "\(key)"   // Double — the token already carries the value
            }
            replacements.append((text: hit.path, with: with))
        }
        for hit in finder.collectionHits {
            let id = "nt_" + Self.stableHash64("rxcount|" + hit.collectionPath)
            if !hostTokens.contains(where: { $0.id == id }) {
                hostTokens.append(.init(id: id, source: "(self.\(hit.collectionPath)).count", kind: .number))
            }
            let key = BodyLowering.numericTokenInputKey(id)
            let with = hit.member == "count" ? "Int(\(key))" : "(\(key) == 0)"
            replacements.append((text: hit.fullExpr.trimmedDescription, with: with))
        }
        var out = source
        for r in replacements.sorted(by: { $0.text.count > $1.text.count }) {
            // BOUNDARY-SAFE substitution: replace `r.text` only when it is NOT followed by an
            // identifier character (so `vm.isOn` never clobbers inside `vm.isOnce`). The text is
            // a member-access path (no regex metachars except `.`, which we escape).
            out = Self.replaceTokenPath(in: out, path: r.text, with: r.with)
        }
        // VERIFY no reactive base survives the rewrite (full projection).
        if BodyLowering.guestBodyReferencesAny(out, names: bases) { return nil }
        return out
    }

    /// Replace every occurrence of the member-access `path` in `source` with `replacement`,
    /// but ONLY where `path` is NOT immediately followed by an identifier char (so `vm.isOn`
    /// can't clobber inside `vm.isOnce`) and NOT immediately followed by `.`/`(`/`[` (so a
    /// `vm.field` scalar replacement never fires when the source actually had `vm.field.sub` /
    /// `vm.field(...)` / `vm.field[...]` — those are unprojectable and the finder already bailed,
    /// but this is belt-and-suspenders). The preceding char is checked too (avoid matching a
    /// `.vm.isOn` suffix of a longer chain — though the finder roots the path at a bare base).
    static func replaceTokenPath(in source: String, path: String, with replacement: String) -> String {
        guard !path.isEmpty else { return source }
        var result = ""
        var idx = source.startIndex
        func isIdentChar(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }
        while idx < source.endIndex {
            if let r = source.range(of: path, range: idx..<source.endIndex) {
                // The char immediately before the match (boundary on the left).
                let leftOK: Bool
                if r.lowerBound == source.startIndex { leftOK = true }
                else {
                    let before = source[source.index(before: r.lowerBound)]
                    leftOK = !isIdentChar(before) && before != "."   // not mid-identifier / mid-chain
                }
                // The char immediately after the match (boundary on the right).
                let rightOK: Bool
                if r.upperBound == source.endIndex { rightOK = true }
                else {
                    let after = source[r.upperBound]
                    rightOK = !isIdentChar(after) && after != "." && after != "(" && after != "["
                }
                result += source[idx..<r.lowerBound]
                if leftOK && rightOK {
                    result += replacement
                } else {
                    result += source[r.lowerBound..<r.upperBound]   // not a clean boundary — keep verbatim
                }
                idx = r.upperBound
            } else {
                result += source[idx...]
                break
            }
        }
        return result
    }

    /// The set of reactive base identifiers from the scalar + collection path catalogs
    /// (`viewModel.isOn` / `viewModel.items` → `viewModel`).
    static func reactiveBases(scalarPaths: [String: BodyLowering.ViewInput.Kind],
                              collectionPaths: Set<String>) -> Set<String> {
        var out = Set<String>()
        for p in scalarPaths.keys { if let dot = p.firstIndex(of: ".") { out.insert(String(p[..<dot])) } }
        for p in collectionPaths { if let dot = p.firstIndex(of: ".") { out.insert(String(p[..<dot])) } }
        return out
    }

    /// Discover SELF-ACCESSIBLE PROPERTY collection-guard names in an `if` condition: a
    /// `<prop>.count` / `<prop>.isEmpty` where `<prop>` is a BARE identifier that is (a) NOT
    /// guest-resolvable (not a marshalled input / emitted `let` / loop var — so it would leak
    /// as a free guest symbol and demote the whole module), (b) NOT already a body-local (those
    /// the caller projects via `unresolvableLocals`), and (c) self-accessible (resolves through
    /// `resolveAccessibleCollectionSource`, so the thunk can evaluate `(self.<prop>).count`).
    /// These are computed/`@Query`/stored COLLECTION properties (`plantsForSelectedDate`,
    /// `plants`) — the #1 SwiftData/data-view condition blocker. Adding them to the projection
    /// set lets `hostProjectCollectionGuard` rewrite their `.count`/`.isEmpty` to a numeric
    /// token (the SAME mechanism as a body-local alias), so the guard compiles in the guest.
    /// A free name used in ANY other way (a bare `if flag`, a `prop.first`) is NOT returned →
    /// the condition demotes to a native slot as before (build-safe = demote-safe).
    private mutating func collectionGuardPropertyNames(
        _ conditions: ConditionElementListSyntax) -> Set<String> {
        let probe = Parser.parse(source: "let __patch_cond = (\(conditions.trimmedDescription))")
        guard let valueExpr = Self.tokenProbeValueExpr(probe) else { return [] }
        let finder = CollectionGuardMemberFinder(bodyLocals: [], collectAll: true)
        finder.walk(valueExpr)
        let resolvable = guestResolvableNames
        var out = Set<String>()
        for hit in finder.hits {
            if resolvable.contains(hit.base) { continue }      // guest has it — no token needed
            if bodyLocals.contains(hit.base) { continue }       // a body-local — already handled
            if resolveAccessibleCollectionSource(hit.base) == nil { continue }  // not self-reachable
            // BUG #13: the base must be PROVABLY a collection (its declared type is `[T]`/`Set`/
            // `[K:V]`/`String`). A domain type with a custom `var isEmpty: Bool`/`var count: Int`
            // is self-accessible but NOT a collection — host-projecting `(self.<base>).count` over
            // it fails the thunk compile or evaluates the wrong branch. Require the collection proof.
            if !collectionTypedNames.contains(hit.base) { continue }
            out.insert(hit.base)
        }
        return out
    }

    /// True iff every condition in the clause is a plain BOOLEAN expression (the only
    /// form expressible as a guest ternary). An `if let`/`if var` optional binding, an
    /// `if case` pattern, or an availability `#available` is NOT — those make the whole
    /// `if` demote to a native slot (never a broken ternary). Multiple comma-separated
    /// boolean conditions are fine (they join as `&&` inside the ternary).
    static func isPlainBooleanCondition(_ conditions: ConditionElementListSyntax) -> Bool {
        for c in conditions {
            switch c.condition {
            case .expression: continue            // a boolean expression — OK
            default: return false                  // optionalBinding / matchingPattern / availability
            }
        }
        return !conditions.isEmpty
    }

    /// True iff the `if`'s condition is EXACTLY one `#available(…)` / `#unavailable(…)`
    /// availability check (no additional boolean/binding terms). This is the G25 form
    /// `if #available(iOS NN, *) { … }` we resolve by taking the AVAILABLE branch (the
    /// device running an OTA patch meets the SDK floor). An `#unavailable` is its inverse
    /// — but we treat a sole `#unavailable` conservatively as NOT this form (it would mean
    /// taking the `else`, which we don't special-case; it falls through to slotting), since
    /// `#unavailable` in a view body is rare. Only `#available` returns true here.
    static func isSoleAvailabilityCondition(_ conditions: ConditionElementListSyntax) -> Bool {
        guard conditions.count == 1, let only = conditions.first else { return false }
        if case .availability(let avail) = only.condition {
            return avail.availabilityKeyword.tokenKind == .poundAvailable
        }
        return false
    }

    private mutating func emitCall(_ call: FunctionCallExprSyntax) -> String {
        // Modifier chain: `<base>.<mod>(args)`
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           let base = member.base {
            // Snapshot opaque leaves AND host tokens so that if we end up slotting the
            // WHOLE expression (below), we discard any sub-leaves/sub-tokens recorded
            // while emitting the now-subsumed base — keeping both consistent with the
            // emitted tree (an orphaned token would make the thunk emit an unused — and
            // possibly non-compiling — `__patchTokens()` entry).
            let leafSnapshot = opaqueLeaves.count
            let tokenSnapshot = hostTokens.count
            let effectSnapshot = effectSlots.count
            let baseCode = emitExpr(base)
            let mod = member.declName.baseName.text
            if let chained = emitModifier(mod, call: call, base: baseCode) {
                return chained
            }
            // A modifier we can't FAITHFULLY lower (an unknown modifier, or a form we
            // don't model). Rather than DROP it (silent layout drift) we render the
            // WHOLE expression natively via a mixed-view slot. The rest of the body
            // still lowers around it. Discard any effect slot recorded while emitting the
            // now-subsumed base (an orphaned effect slot would make the thunk emit an
            // unused — possibly non-compiling — `__patchEffectSlots()` entry).
            opaqueLeaves.removeLast(opaqueLeaves.count - leafSnapshot)
            hostTokens.removeLast(hostTokens.count - tokenSnapshot)
            effectSlots.removeLast(effectSlots.count - effectSnapshot)
            // The whole modifier-chained expression is slotted as a unit, but we STILL lift
            // plain string LITERALS from inside it (`opaqueExprLifted`) so editing a constant
            // in a slotted custom-modifier view — e.g. a title/`Text("…")` inside
            // `VStack { … }.screenBackground()` — rides WASM (OTA-editable) instead of baking
            // into native slot source. A custom modifier on a CONTAINER otherwise collapses the
            // WHOLE container to one baked native leaf, so editing ANY literal in it = a
            // FINGERPRINT MISMATCH (the #1 real-app edit-breaks-OTA cause; design-system
            // container modifiers are ubiquitous). Lifting is position-typed + identity-safe
            // (see `StringLiteralLifter.liftSpecs`): only display/icon literals lift; `.tag`,
            // ForEach `id:`, Chart `.value`, asset `Color("…")` and unlabeled args stay baked
            // (they have a base / no display label, so the lifter never matches them).
            // Pass the modifier name as a CLEAN labelHint so the debug `.label` is e.g.
            // "screenBackground" — not the rewritten source (which carries placeholder
            // control chars + structural punctuation).
            return opaqueExprLifted(ExprSyntax(call), labelHint: mod)
        }
        // Constructor
        if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return emitConstructor(callee.baseName.text, call: call)
        }
        return opaqueExpr(ExprSyntax(call))
    }

    private mutating func emitBareMember(_ member: MemberAccessExprSyntax) -> String {
        if let base = member.base?.as(DeclReferenceExprSyntax.self),
           base.baseName.text == "Color" {
            // BUG R2-#68: a standalone `Color.<custom>` leaf VIEW (e.g. a design-system
            // `Color.brandPrimary` = `Color("BrandPrimary")` asset). Emitting `.named(x)`
            // unconditionally renders an unknown color as `.primary` (wrong color) on
            // device. Route through `colorRefOrToken`: a KNOWN palette name lowers to
            // `.named`, a resolvable design-system token lowers to `.hostToken(id)`, and an
            // unresolvable color slots the whole leaf natively (faithful) — never an
            // unvalidated `.named`.
            let src = member.trimmedDescription
            if let lc = colorRefOrToken(src) {
                return "N.color(\(lc))"
            }
            return opaqueExpr(ExprSyntax(member), labelHint: "Color")
        }
        return opaqueExpr(ExprSyntax(member))
    }

    // MARK: Constructors

    private mutating func emitConstructor(_ name: String, call: FunctionCallExprSyntax) -> String {
        let args = call.arguments
        // A NO-ARG call to a same-struct `@ViewBuilder func makeRow() -> some View`
        // helper — inline-lower its body in place (TASK 2). Only a parameterless,
        // trailing-closure-free call inlines (an arg-taking helper isn't collected, so
        // `emitInlineHelper` returns nil and we fall through to the normal handling).
        if args.isEmpty, call.trailingClosure == nil, helperBodies[name] != nil,
           let inlined = emitInlineHelper(name: name) {
            return inlined
        }
        switch name {
        case "Text":
            // `Text(verbatim: "x")` → a styledText with the verbatim flag (skip the
            // localization lookup). The `Text(date, style:)`, markdown, and
            // LocalizedStringKey forms are NOT lowered here (the guest can't compute a
            // Date epoch under Embedded Swift, and a bare `Text("literal")` is already
            // the verbatim render — changing it to a `localized`/`markdown` flag would
            // be unfaithful), so they stay as plain `N.text` or slot.
            if let verbatim = args.first(where: { $0.label?.text == "verbatim" }),
               args.count == 1 {
                // A plain STRING LITERAL is always safe to emit verbatim.
                if verbatim.expression.is(StringLiteralExprSyntax.self) {
                    return "N.styledText(\(verbatim.expression.trimmedDescription), verbatim: true)"
                }
                // BUG R2-#117/#120: a NON-literal verbatim arg (`Text(verbatim: vm.title)`)
                // bypassed the leak/slotability guards — it could leak a non-marshalled
                // reactive flat-struct member into the guest (a compile failure). Route it
                // through the SAME host-projection the plain Text content uses: resolvable /
                // host-token → emit; otherwise slot (self-accessible) or emit verbatim so the
                // build-time scope check demotes (inaccessible) — never an unchecked raw emit.
                let content = verbatim.expression.trimmedDescription
                if let resolved = stringContentOrToken(content) {
                    return "N.styledText(\(resolved), verbatim: true)"
                }
                let callExpr = ExprSyntax(call)
                if Self.isSlotable(callExpr, blocked: bodyLocals.union(inaccessibleNames)) {
                    return opaqueExpr(callExpr, labelHint: "Text")
                }
                return "N.styledText(\(content), verbatim: true)"
            }
            // `Text("…[link](url)…")` / `Text("**bold**")` — a STRING-LITERAL
            // `LocalizedStringKey` carrying MARKDOWN (G31). SwiftUI auto-renders markdown
            // in a string-literal Text; we lower it as `styledText(markdown: true)` so the
            // SDK renderer reconstitutes the same `AttributedString(markdown:)` styling.
            // Only a plain (non-interpolated) string literal qualifies — an interpolation
            // (`"\(x)"`) is computed in the guest and stays a plain text node.
            if let first = args.first, first.label == nil, args.count == 1,
               let lit = first.expression.as(StringLiteralExprSyntax.self),
               Self.stringLiteralIsPlain(lit), Self.literalLooksMarkdown(lit) {
                return "N.styledText(\(first.expression.trimmedDescription), markdown: true)"
            }
            // `Text(x, style:)` / `Text(x, format:)` / `Text(image)` aren't a plain
            // string — slot them (the leading arg is non-string). Only a single
            // unlabeled (or no) arg is the plain string form.
            if let first = args.first {
                if first.label == nil && args.count == 1 {
                    // A SwiftUI-ONLY interpolation overload (`Text("\(v, specifier:)")` /
                    // `Text("\(n, format:)")` / `Text("\(date, style:)")`) is NOT a plain
                    // `String` — emitting it verbatim or as a `.string(<source>)` token both
                    // fail the guest/thunk compile (plain `String.StringInterpolation` has no
                    // such overload). Slot the whole Text so the NATIVE `Text` renders the
                    // formatted output faithfully; `isSlotable` then either fills it (a
                    // `self`-accessible value) or, for a body-local/inaccessible read, the
                    // body-level scope check demotes the view cleanly at BUILD time — no
                    // wasted guest compile + isolation pass (the 22× compile-demote class).
                    if let lit = first.expression.as(StringLiteralExprSyntax.self),
                       Self.literalHasSwiftUIInterpolationOverload(lit) {
                        // SwiftUI-only interpolation overload: can't lift the literal (the
                        // `\(v, specifier:)` segment isn't a plain string). Plain slot.
                        return opaqueExpr(ExprSyntax(call), labelHint: "Text")
                    }
                    // The plain `Text(<string>)` form. If the content is guest-resolvable
                    // as written it's emitted verbatim; if it's a host STRING token (an
                    // enum's computed-String member like `confidence.label`, a
                    // `.uppercased()` thereof) it lowers as a `__strtok_<id>` input
                    // reference (the thunk resolves it natively).
                    let content = first.expression.trimmedDescription
                    if let resolved = stringContentOrToken(content) {
                        return "N.text(\(resolved))"
                    }
                    // Neither resolvable nor a host token. If the content is SLOTABLE —
                    // it references only `self`-accessible members the cross-file thunk can
                    // render natively — slot the whole Text node (the rest of the view
                    // still ships). If it's NOT slotable (it reads a body-local or a
                    // `private`/`fileprivate` member the thunk can't reach), a native slot
                    // would be unfillable → the view would silently runtime-demote while we
                    // reported it shipped. Emit VERBATIM instead so the body-level guest
                    // scope check demotes the view at BUILD time — honest over optimistic.
                    let callExpr = ExprSyntax(call)
                    if Self.isSlotable(callExpr, blocked: bodyLocals.union(inaccessibleNames)) {
                        // Apply position-typed string lifting so the text literal rides WASM.
                        return opaqueExprLifted(callExpr, labelHint: "Text")
                    }
                    return "N.text(\(content))"
                }
                return opaqueExprLifted(ExprSyntax(call), labelHint: "Text")
            }
            return "N.text(\"\")"
        case "Image":
            if let sys = args.first(where: { $0.label?.text == "systemName" }) {
                // `Image(systemName:, variableValue:)` → symbolImage when a
                // variableValue is present; else the plain image node.
                if let vv = args.first(where: { $0.label?.text == "variableValue" }) {
                    return "N.symbolImage(systemName: \(sys.expression.trimmedDescription), "
                        + "variableValue: Double(\(vv.expression.trimmedDescription)))"
                }
                // Any OTHER extra arg we don't model → slot the whole image.
                if args.allSatisfy({ $0.label?.text == "systemName" }) {
                    // MULTI-SITE HOST-PROJECTION: route the systemName through the SAME
                    // string host-projection `Text` content uses. A string LITERAL /
                    // guest-resolvable expr emits verbatim (unchanged); a member read the
                    // guest can't reconstruct but the host can (`accent.icon` where `icon`
                    // is a provably-`String` member — the thunk evals `self.accent.icon`)
                    // lowers as a `__strtok_<id>` input reference instead of LEAKING the
                    // free identifier and demoting the whole view. (Before this, an
                    // `Image(systemName: model.field)` emitted the field verbatim → demote.)
                    let raw = sys.expression.trimmedDescription
                    if let resolved = stringContentOrToken(raw) {
                        return "N.image(systemName: \(resolved))"
                    }
                    // Not host-resolvable: slot the whole Image if slotable (renders
                    // natively from `self`); else emit verbatim so the build-time scope
                    // check demotes honestly (mirrors the `Text` path — never an unfillable slot).
                    let callExpr = ExprSyntax(call)
                    if Self.isSlotable(callExpr, blocked: bodyLocals.union(inaccessibleNames)) {
                        // systemName is a String position — lift it so editing the icon
                        // name is fingerprint-stable and rides WASM.
                        return opaqueExprLifted(callExpr, labelHint: "Image")
                    }
                    return "N.image(systemName: \(raw))"
                }
                return opaqueExprLifted(ExprSyntax(call), labelHint: "Image")
            }
            // `Image("assetName")` — a single STRING-LITERAL unlabeled arg resolves
            // the shipped Asset Catalog by name. (A computed name, `Image(uiImage:)`,
            // `Image(decorative:)`, etc. stay native via a slot.)
            if args.count == 1, let only = args.first, only.label == nil,
               only.expression.as(StringLiteralExprSyntax.self) != nil {
                return "N.bundleImage(name: \(only.expression.trimmedDescription))"
            }
            return opaqueExprLifted(ExprSyntax(call), labelHint: "Image")
        case "AsyncImage":
            return emitAsyncImage(call: call)
        case "Spacer":
            return "N.spacer()"
        case "Divider":
            return "N.divider"
        case "Color":
            // `Color(red:green:blue:[opacity:])` lowers to `.color(.rgba(...))`
            // (the renderer already renders `.rgba`). A NON-literal Color initializer
            // (asset `Color("Brand")`, `Color(uiColor:)`, `Color(.systemBackground)`,
            // `Color(hex:)`) routes through the host-token color path (G15b): the
            // build thunk evaluates the real `Color(...)` natively → a resolved Color
            // keyed by id, and the node carries `.color(.hostToken(id))`. A token that
            // references a body-local / inaccessible member slots (faithful over wrong).
            if let rgba = Self.loweredRGBAColorOrNil(call.trimmedDescription) {
                return "N.color(\(rgba))"
            }
            if let lc = colorRefOrToken(call.trimmedDescription) {
                return "N.color(\(lc))"
            }
            return opaqueExpr(ExprSyntax(call), labelHint: "Color")
        case "ProgressView":
            return emitProgressView(call: call)
        case "Rectangle":
            return "N.shape(.rectangle)"
        case "RoundedRectangle":
            let r = args.first { $0.label?.text == "cornerRadius" }?.expression.trimmedDescription ?? "0"
            guard let rn = numericOrToken(r) else {
                return opaqueExpr(ExprSyntax(call), labelHint: "RoundedRectangle")
            }
            return "N.shape(.roundedRectangle(cornerRadius: Double(\(rn))))"
        case "Circle":
            return "N.shape(.circle)"
        case "Ellipse":
            return "N.shape(.ellipse)"
        case "Capsule":
            return "N.shape(.capsule)"
        case "VStack":
            return emitStack("vstack", call: call, horizontal: true)
        case "HStack":
            return emitStack("hstack", call: call, horizontal: false)
        case "LazyVStack":
            // Modeled DISTINCTLY from VStack (the IR now has a lazyVStack node that
            // renders a real `LazyVStack`); layout-identical, but the tree preserves
            // that it was lazy.
            return emitStack("lazyVStack", call: call, horizontal: true)
        case "LazyHStack":
            return emitStack("lazyHStack", call: call, horizontal: false)
        case "LazyVGrid":
            return emitGrid("lazyVGrid", tracksLabel: "columns", call: call)
        case "LazyHGrid":
            return emitGrid("lazyHGrid", tracksLabel: "rows", call: call)
        case "Grid":
            return emitGridContainer(call: call)
        case "GridRow":
            return emitGridRow(call: call)
        case "GroupBox":
            return emitGroupBox(call: call)
        case "DisclosureGroup":
            return emitDisclosureGroup(call: call)
        case "ViewThatFits":
            return emitViewThatFits(call: call)
        case "ControlGroup":
            let children = childrenCode(call)
            return "N.controlGroup([\n\(children)\n])"
        case "TabView":
            return emitTabView(call: call)
        case "EmptyView":
            // `EmptyView()` is patchable — an empty group (NOT a slot).
            return "N.group([])"
        case "AnyView":
            // `AnyView(x)` — erasure is host-only; unwrap to the lowered inner node.
            if let inner = args.first, inner.label == nil {
                return emitExpr(inner.expression)
            }
            return opaqueExpr(ExprSyntax(call), labelHint: "AnyView")
        case "ZStack":
            return emitZStack(call: call)
        case "Group":
            let children = childrenCode(call)
            return "N.group([\n\(children)\n])"
        case "ForEach":
            return emitForEach(call: call)
        case "ScrollView":
            return emitScrollView(call: call)
        case "List":
            // Static `List { rows }` or dynamic `List(items) { item in … }`. The
            // dynamic form pre-unrolls like ForEach, so it routes through the shared
            // loop-or-demote logic (a real guest loop over a marshalled array, else
            // the whole List slots natively — never an unbound loop var).
            switch containerChildren(call) {
            case .nodes(let children): return "N.list([\n\(children)\n])"
            case .demote: return opaqueExpr(ExprSyntax(call), labelHint: "List")
            }
        case "Section":
            return emitSection(call: call)
        case "Form":
            switch containerChildren(call) {
            case .nodes(let children): return "N.form([\n\(children)\n])"
            case .demote: return opaqueExpr(ExprSyntax(call), labelHint: "Form")
            }
        case "NavigationStack", "NavigationView":
            // NavigationView (legacy) maps to the same navigationStack shell.
            // BUG R2-#4: a `path:` binding (`NavigationStack(path: $path)`) drives
            // programmatic / value-based navigation. The plain `navigationStack` node
            // carries NO path, so lowering it would ship a path-LESS shell — programmatic
            // navigation (`path.append`/`.removeLast`, `NavigationLink(value:)`) would be
            // dead. Slot the whole stack natively so the real path binding is preserved.
            if call.arguments.contains(where: { $0.label?.text == "path" }) {
                return opaqueExpr(ExprSyntax(call), labelHint: "NavigationStack")
            }
            let children = childrenCode(call)
            return "N.navigationStack([\n\(children)\n])"
        case "Label":
            return emitLabel(call: call)
        case "Button":
            return emitButton(call: call)
        case "Toggle":
            return emitToggle(call: call)
        case "Slider":
            return emitSlider(call: call)
        case "Stepper":
            return emitStepper(call: call)
        case "TextField":
            return emitTextField(call: call)
        case "SecureField":
            return emitSecureField(call: call)
        case "TextEditor":
            return emitTextEditor(call: call)
        case "Gauge":
            return emitGauge(call: call)
        case "Link":
            return emitLink(call: call)
        case "ShareLink":
            return emitShareLink(call: call)
        case "LabeledContent":
            return emitLabeledContent(call: call)
        case "Menu":
            return emitMenu(call: call)
        case "Picker":
            return emitPicker(call: call)
        case "NavigationLink":
            return emitNavigationLink(call: call)
        case "EditButton":
            return "N.editButton"
        case "GeometryReader":
            return emitGeometryReader(call: call)
        case "Path":
            return emitPath(call: call)
        default:
            // Custom view type (`ChildView(...)`, a UIViewRepresentable, an
            // unsupported SwiftUI type): a native leaf rendered via a mixed-view
            // slot closure when self-contained (the common case, since custom views
            // live in the app module and need no import). String-literal arguments are
            // lifted into a PARAMETERIZED slot so editing them is OTA-patchable +
            // fingerprint-stable (see `opaqueCall`).
            //
            // CALLBACK-SLOT LEVER: if the call has exactly one dispatchable `() -> Void`
            // closure arg (labeled or trailing), lower the closure body as a WASM dispatch
            // sequence and emit a `callbackSlot(id:label:)` node. The id is position-keyed
            // (callee + arg label) so it is stable across closure body edits → editing the
            // callback is fingerprint-stable (OTA). The full child-view call (with the
            // closure replaced by a stable forwarder) lives in `slotSource` → fingerprinted
            // under `CB:` prefix. A non-dispatchable closure (body-local / inaccessible
            // read) falls through to `opaqueCall` as before. Only the FIRST closure arg
            // is checked; a multi-closure custom view is too complex and stays opaque.
            if let cbId = findAndRecordCallbackSlot(call: call, name: name) {
                return "N.callbackSlot(id: \(cbId.debugDescription), label: \(name.debugDescription))"
            }
            return opaqueCall(call, labelHint: name)
        }
    }

    /// Finds the first dispatchable `() -> Void` closure arg in a custom child-view call
    /// and records a callbackSlot for it. Returns the slot id string if successful, nil otherwise.
    /// Only considers closures with NO parameters (the `() -> Void` signature); closures with
    /// parameters (e.g. Canvas `{ context, size in }`, ForEach `{ item in }`) are excluded —
    /// they can't be the OTA-dispatchable callback-slot pattern.
    private mutating func findAndRecordCallbackSlot(call: FunctionCallExprSyntax, name: String) -> String? {
        // Check LABELED arguments only. Trailing closures are intentionally excluded:
        // in SwiftUI a trailing closure on a custom child-view call is overwhelmingly a
        // `@ViewBuilder () -> Content` provider (NOT a `() -> Void` callback), and we
        // have no type-level proof to distinguish them at this point. A labeled arg like
        // `onContinue: { ... }` or `onPurchase: { ... }` is unambiguously a callback.
        // Inertness invariant: a view whose custom child-view calls ONLY have trailing
        // closures lowers byte-identically to before the callbackSlot lever.
        for arg in call.arguments {
            guard let closureExpr = arg.expression.as(ClosureExprSyntax.self) else { continue }
            // Only labeled closure args qualify. An unlabeled inline closure in the arg list
            // (rare, but syntactically distinct from a trailing closure) is skipped for safety.
            guard let argLabel = arg.label?.text, !argLabel.isEmpty else { return nil }
            // Only `() -> Void` closures (no parameters) qualify as callback slots.
            guard closureExpr.signature == nil || (closureExpr.signature?.parameterClause == nil) else {
                return nil
            }
            if let id = tryRecordCallbackSlot(call, closureArg: closureExpr, closureArgLabel: argLabel) {
                return id
            }
            // Found a labeled closure arg but it's not dispatchable — fall through to opaqueCall.
            return nil
        }
        // Trailing closures: skip entirely (cannot prove `() -> Void` vs. `@ViewBuilder`).
        return nil
    }

    // MARK: ForEach (real guest loop or demote — never an unbound loop var)

    /// `ForEach(<collection>[, id: …]) { <loopVar> in <row> }`.
    ///
    /// A ForEach contributes ROWS to the tree. To build them in the guest we must
    /// either (a) bind the loop variable over a collection the guest actually has,
    /// or (b) render the whole ForEach natively. The previous emitter emitted the
    /// row template ONCE referencing the loop var as a FREE identifier
    /// (`N.forEach([ N.text("\(s)") ])` with no `for s in …`) — that fails the guest
    /// compile (`cannot find 's' in scope`), and because the SwiftUI guest is ONE
    /// compile unit, the WHOLE module fails and NO view ships.
    ///
    /// FIX: when the collection is a MARSHALLED scalar-array input (a bare
    /// identifier B's marshalling binds as a `[Int]`/`[String]`/`[Double]`/`[Bool]`
    /// in the guest), emit a real guest loop inside an immediately-invoked closure
    /// that appends one row per element. Otherwise (a computed expression, a
    /// range, a struct/object array the guest can't reconstruct) DEMOTE the whole
    /// ForEach to a native `.opaque` slot — never emit an unbound loop var.
    private mutating func emitForEach(call: FunctionCallExprSyntax) -> String {
        // The collection is the FIRST unlabeled argument. The row builder is the
        // trailing closure (or a closure passed as an argument). When we can build a
        // real guest loop over a marshalled array, do so; otherwise demote the WHOLE
        // ForEach to a native slot (never an unbound loop var that fails the module).
        if let collectionArg = call.arguments.first(where: { $0.label == nil }),
           let rowClosure = forEachRowClosure(call) {
            // COARSEN-ON-NON-SLOTABLE-LEAF: a granular loop lowering is only thunk-safe if
            // every opaque leaf it produces is slotable. A ROW that lowers its loop but
            // contains an inner element referencing a ROW-LOCAL the inner slot can't reach
            // (`let isPeak = idx == peakIdx` used in a conditional `.fill(isPeak ? …)`)
            // yields a NON-slotable leaf → the WHOLE view would render native. Instead,
            // REVERT the granular emission and slot the WHOLE `ForEach` as one leaf: it
            // binds its loop vars + row-locals INTERNALLY (→ slotable via the leaf-internal
            // subtraction), so the surrounding structure still rides WASM while the loop is
            // one native slot. Coarsening only ever turns a would-be-NATIVE view routed.
            let mark = (leaves: opaqueLeaves.count, tokens: hostTokens.count,
                        rows: indexedRowSlots.count, muts: mutationRules.count)
            func revertToMark() {
                if opaqueLeaves.count > mark.leaves { opaqueLeaves.removeLast(opaqueLeaves.count - mark.leaves) }
                if hostTokens.count > mark.tokens { hostTokens.removeLast(hostTokens.count - mark.tokens) }
                if indexedRowSlots.count > mark.rows { indexedRowSlots.removeLast(indexedRowSlots.count - mark.rows) }
                if mutationRules.count > mark.muts { mutationRules.removeLast(mutationRules.count - mark.muts) }
            }
            func rowLeavesAllSlotable() -> Bool { opaqueLeaves[mark.leaves...].allSatisfy { $0.slotable } }
            // G30: `ForEach(scalarArr.enumerated()[, id: \.offset]) { (i, v) in … }` /
            // `{ pair in … pair.offset … pair.element … }` over a MARSHALLED scalar array.
            // The `id:` (`\.0`/`\.offset`/`\.element`) is identity-only and doesn't affect
            // the loop; we iterate `<arr>.enumerated()` in the guest with the same binding.
            if let enumLoop = loweredEnumeratedLoop(collectionArg: collectionArg, rowClosure: rowClosure) {
                if rowLeavesAllSlotable() { return "N.forEach(\(enumLoop))" }
                revertToMark()
                return opaqueExpr(ExprSyntax(call), labelHint: "ForEach")
            }
            if let rows = loweredRowLoop(collectionArg: collectionArg, rowClosure: rowClosure) {
                if rowLeavesAllSlotable() { return "N.forEach(\(rows))" }
                revertToMark()
                return opaqueExpr(ExprSyntax(call), labelHint: "ForEach")
            }
            // PER-ROW INDEXED NATIVE-ACTION SLOT: the guest can't reconstruct the
            // collection (it's a body-local read off an `@Environment` service, a computed
            // property — not a marshalled input), but the build-time thunk CAN evaluate it
            // natively over `self` and rebuild each row (incl. its per-row native action
            // closure). Try that before demoting to a plain whole-ForEach slot.
            if let node = indexedForEachSlotIfProvable(collectionArg: collectionArg,
                                                       rowClosure: rowClosure) {
                return node
            }
        }
        return opaqueExpr(ExprSyntax(call), labelHint: "ForEach")
    }

    /// Lower a `ForEach(<body-local collection>[, id:]) { <loopVar> in <CustomRow>(...) }`
    /// to a PER-ROW INDEXED NATIVE-ACTION SLOT (`N.indexedForEachSlot`) when the shape is
    /// PROVABLY thunk-renderable. Returns nil (→ caller slots the whole ForEach) otherwise.
    ///
    /// Requirements (all must hold; any failure → nil → demote-safe plain slot):
    ///   * The row closure has a SINGLE explicit element parameter (`{ owner in … }`); a
    ///     `$0`-shorthand or multi-param closure isn't a per-row builder we can bind.
    ///   * The row body is a SINGLE view EXPRESSION (`AccountChip(...) { … }`) — not a
    ///     multi-statement builder (a row-local `let` + view; that's a later wave).
    ///   * The COLLECTION, resolved through body-local `let` aliases to its accessible
    ///     source (`owners` → `schedule.availableOwners`), references NO body-local (other
    ///     than via the alias it resolves) and NO inaccessible (`private`) member — so the
    ///     thunk's `self.<collection>` compiles.
    ///   * The ROW source, with `loopVar` in scope, references no body-local BESIDES
    ///     `loopVar` and no inaccessible member — so the thunk's per-row factory compiles.
    /// The collection + row are NOT emitted into the guest tree at all (no free guest
    /// identifier leaks): the node carries only the slot id + the reserved count key.
    private mutating func indexedForEachSlotIfProvable(
        collectionArg: LabeledExprSyntax, rowClosure: ClosureExprSyntax) -> String? {
        // (1) The row binding shape. TWO accepted forms (anything else → nil → demote):
        //   * a SINGLE explicit element parameter (`{ owner in … }`) → `loopVar`, OR
        //   * a SINGLE-element `$0`-SHORTHAND (`{ AccountChip(id: $0.id) { … } }`).
        // A `$1`/multi-param shorthand (more than one element param) DECLINES — the indexed
        // slot is single-element. The two forms differ ONLY in the thunk factory: a named
        // var binds `let owner = coll[i]`; a `$0` row INVOKES the original closure with the
        // element (`(closure)(coll[i])`) so Swift's own scoping resolves `$0` — and any
        // genuinely-nested closure keeps its OWN `$0`/params (NO `$0` rewrite anywhere).
        let loopVar = forEachLoopVarName(rowClosure)
        let isShorthand: Bool
        if loopVar == nil {
            // Not a named single-param closure. Accept ONLY a single-element `$0` shorthand.
            guard Self.rowClosureIsSingleElementShorthand(rowClosure) else { return nil }
            isShorthand = true
        } else {
            isShorthand = false
        }
        // (2) The row body is a single view expression.
        guard let rowExpr = Self.singleRowViewExpr(rowClosure) else { return nil }
        // The row MUST be rooted in a CUSTOM view constructor (`AccountChip(...) { … }`) —
        // a non-lowerable child view whose per-row native action the guest can't express.
        // A row rooted in a STANDARD lowerable view (`Text(r)`, `HStack { … }`) is NOT this
        // path: it would lower the normal way if the collection were marshallable, and over
        // an unmarshalled collection it should DEMOTE (faithful native) rather than wrap a
        // perfectly-lowerable leaf in a native row slot. Requiring a custom root keeps the
        // indexed slot to genuinely-unlowerable rows (and keeps the native-vs-OTA boundary
        // — and thus the fingerprint — honest: a standard-view row stays native, not OTA).
        guard Self.rowRootedInCustomView(rowExpr) else { return nil }

        // (3) Resolve the collection to a source the thunk can evaluate over `self`.
        //
        // TWO accepted forms (anything else → nil → demote-safe plain slot):
        //
        //   A. A MARSHALLED STRUCT-ARRAY input name (`items: [Plant]`). The input name is a
        //      stored property → `self.items` compiles in the cross-file thunk. The thunk
        //      factory does `let __coll = items; let item = __coll[i]; return AnyView(RowView(…))`
        //      exactly like a body-local collection. This is the "opaque-struct-row demote" fix:
        //      a `ForEach(items){ item in PlantRowView(plant: item) }` was previously slotted as
        //      ONE whole-ForEach opaque leaf (the ElementUsageScanner blocked the guest loop since
        //      `item` was used bare), wasting the per-row indexing ability and preventing OTA
        //      structural changes to the ForEach itself. Now it lowers to `indexedForEachSlot`,
        //      the thunk supplies a per-row `(Int)->AnyView` factory over `items`, and the SDK
        //      reconstitutes the count rows natively — identical render, but the ForEach structure
        //      (count guard, id: parameter, surrounding modifiers) is now OTA-editable.
        //      SCALAR arrays are NOT admitted here (a `[Int]`/`[String]` element used bare is not
        //      a custom-view pattern and the guest can already loop scalars — keep that path).
        //   B. A BODY-LOCAL / member-access collection (the original path): an @Environment service
        //      or computed property the guest can't reconstruct. Alias-resolve through body-local
        //      `let` initializers to the accessible self-member source.
        //
        // A scalar-array input falls through to the established guest-loop path (not here).
        let rawCollection = collectionArg.expression.trimmedDescription
        let isMarshalledStructArray = isSimpleIdentifier(rawCollection)
            && structArrayInputElements[rawCollection] != nil
        guard let collectionSource: String = {
            if isMarshalledStructArray {
                // Form A: the marshalled struct-array name IS the thunk-accessible source.
                return rawCollection
            }
            // Form B: body-local / member access. Reject scalar-array inputs (those loop
            // in the guest, not here). Resolve aliases; reject if it resolves to any
            // marshalled input (a body-local alias pointing at a marshalled array = wrong path).
            guard !scalarArrayInputNames.contains(rawCollection) else { return nil }
            guard let src = resolveAccessibleCollectionSource(rawCollection) else { return nil }
            guard !collectionNamesMarshalledArrayInput(src) else { return nil }
            return src
        }() else { return nil }

        // (5) The row source must compile in the thunk factory: it may reference the ELEMENT
        // (a named `loopVar` bound to `collection[i]`, OR `$0` bound by invoking the closure)
        // but no OTHER body-local, and no inaccessible member. For the named form we judge
        // slotability with `loopVar` REMOVED from the blocked set (it's bound in the factory);
        // every other body-local stays blocked. For the `$0` form, `$0` is NEVER a body-local
        // (it has no declaration node), so the full blocked set applies as-is — a genuine
        // body-local read (other than the element) still fails (demote-safe). A nested
        // closure's OWN `$0` likewise has no declaration node, so it never trips.
        let rowSource = rowExpr.trimmedDescription
        var blockedForRow = bodyLocals.union(inaccessibleNames)
        if let loopVar { blockedForRow.remove(loopVar) }
        guard Self.isSlotable(rowExpr, blocked: blockedForRow) else { return nil }

        // For the `$0` form, store the FULL original closure source so the thunk factory can
        // INVOKE it with the element. The factory text is the whole closure (incl. its
        // `@ViewBuilder` body), so this ALSO handles a multi-statement row body for free.
        let rowClosureText: String? = isShorthand ? rowClosure.trimmedDescription : nil
        // A synthetic loop-var name only used in the structural seed for the `$0` form
        // (the factory never binds it). Keeps the id stable + distinct from a named row.
        let seedLoopVar = loopVar ?? "$0"

        // Content-stable id: FNV of the structural seed (collection + loopVar + row). Editing
        // the row's strings re-slots (the row source is part of the seed) — acceptable: a
        // per-row slot is wholly native, so any row edit is a native-shell change anyway
        // (the fingerprint covers it; there are no lifted literals here).
        let seed = "rowfor|\(collectionSource)|\(seedLoopVar)|\(rowSource)"
        let id = "rf_" + Self.stableHash64(seed)
        if !indexedRowSlots.contains(where: { $0.id == id }) {
            indexedRowSlots.append(.init(id: id, collectionSource: collectionSource,
                                         loopVar: seedLoopVar, rowSource: rowSource,
                                         label: "ForEach", rowClosureText: rowClosureText))
        }
        let countKey = BodyLowering.rowCountInputKey(id)
        return "N.indexedForEachSlot(id: \"\(id)\", countKey: \"\(countKey)\", "
            + "label: \"\(Self.safeLabel("ForEach"))\")"
    }

    /// True iff `closure` is a `$0`-SHORTHAND row builder with EXACTLY ONE element
    /// parameter — it has NO explicit parameter clause (no `{ x in … }`), its body
    /// references `$0`, and it references NO higher anonymous parameter (`$1`/`$2`/…).
    /// A `ForEach` row binds a single element, so a `$1`+ usage means the closure is a
    /// multi-element form the single-element indexed slot can't express → DECLINE.
    /// Implicit `$0` of a GENUINELY-NESTED closure (an inner action closure) belongs to
    /// that closure, not this one; counting `$0`/`$1` over the WHOLE row body would be
    /// unsound — so the scan stops at any nested `ClosureExpr` boundary (only this
    /// closure's OWN anonymous parameters are considered).
    static func rowClosureIsSingleElementShorthand(_ closure: ClosureExprSyntax) -> Bool {
        // An explicit parameter clause means it's not a `$N` shorthand at all.
        if closure.signature?.parameterClause != nil { return false }
        let scan = AnonymousParamScanner.scan(closure)
        // Must use `$0` (else there is no element binding to invoke with) and must NOT use
        // any `$1`+ (a multi-element form the single-element indexed slot can't express).
        return scan.usesDollarZero && !scan.usesHigherDollar
    }

    /// True iff the row view expression is ROOTED in a CUSTOM view constructor — a
    /// `FunctionCallExpr` whose callee is a capitalized type name NOT in the standard
    /// lowerable-view set (`AccountChip(...)`, possibly with trailing modifiers). A row
    /// rooted in a standard lowerable view (`Text(r)`, `HStack { … }`, `Button(...)`) is
    /// NOT custom — it returns false so the indexed-slot path declines (such a row stays
    /// native/demotes, keeping the native-vs-OTA boundary honest).
    static func rowRootedInCustomView(_ expr: ExprSyntax) -> Bool {
        // Unwrap a trailing modifier chain to the base constructor: `Foo(...).bar()` → `Foo(...)`.
        var cur: ExprSyntax = expr
        while true {
            if let call = cur.as(FunctionCallExprSyntax.self) {
                // A modifier call `<base>.bar(...)` → recurse into the base.
                if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                   let base = member.base {
                    cur = base
                    continue
                }
                // A constructor `Foo(...)` — the callee is the type name.
                if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                    let name = callee.baseName.text
                    guard let first = name.first, first.isUppercase else { return false }
                    return !Classifier.lowerableNodes.contains(name)
                }
                return false
            }
            // `Foo(...).bar` (a member access whose base is the constructor).
            if let member = cur.as(MemberAccessExprSyntax.self), let base = member.base {
                cur = base
                continue
            }
            return false
        }
    }

    /// The SINGLE view expression of a row closure body (`{ owner in AccountChip(...) }`),
    /// or nil when the body isn't exactly one expression statement (a multi-statement
    /// builder, a row-local `let`, an `if`/`switch` — those aren't handled here). An
    /// `ExpressionStmt` and a bare `.expr` item both count.
    static func singleRowViewExpr(_ closure: ClosureExprSyntax) -> ExprSyntax? {
        let items = Array(closure.statements)
        guard items.count == 1, let only = items.first else { return nil }
        if case .expr(let e) = only.item { return e }
        if case .stmt(let s) = only.item, let es = s.as(ExpressionStmtSyntax.self) {
            return es.expression
        }
        return nil
    }

    /// True iff `collection` names a GUEST-RECONSTRUCTABLE array input — a bare scalar-array
    /// (`[Int]`/`[String]`/…) or struct-array (`[SomeStruct]`) input, OR a member-access
    /// chain resolving (through the recursive field shapes) to such an array field. These
    /// the guest CAN loop, so they must NOT become a per-row native slot (the demote-safe
    /// established path — a guest loop, with a non-lowerable custom row demoting to native —
    /// already handles them faithfully).
    private func collectionNamesMarshalledArrayInput(_ collection: String) -> Bool {
        let s = collection.trimmingCharacters(in: .whitespaces)
        if isSimpleIdentifier(s) {
            return scalarArrayInputNames.contains(s) || structArrayInputElements[s] != nil
        }
        // A member-access chain (`cart.items`) resolving to a struct/scalar array field.
        if let shape = resolveFlatStructCollection(s) {
            switch shape {
            case .structArray, .scalarArray: return true
            default: return false
            }
        }
        return false
    }

    /// Resolve a `ForEach` collection expression to a source the cross-file thunk can
    /// evaluate over `self`. A body-local `let` alias (`let owners = schedule.
    /// availableOwners`) resolves to its initializer; a chain of aliases follows
    /// transitively (bounded). Returns the accessible source iff, after resolution, it
    /// references NO body-local and NO inaccessible (`private`) member — so the thunk's
    /// `self.<source>` compiles. Returns nil otherwise (→ caller slots the whole ForEach).
    private func resolveAccessibleCollectionSource(_ raw: String) -> String? {
        var current = raw.trimmingCharacters(in: .whitespaces)
        var resolved = current
        // Follow a chain of bare-identifier aliases to its accessible root (bounded to
        // avoid a pathological self-referential chain).
        var hops = 0
        while hops < 8 {
            // A bare identifier that names a body-local with a known initializer: replace it
            // with the initializer source and re-check.
            let bare = current
            guard bare.first != nil,
                  bare.allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }),
                  bodyLocals.contains(bare), let initSrc = bodyLocalLetInits[bare] else {
                break
            }
            resolved = initSrc.trimmingCharacters(in: .whitespaces)
            current = resolved
            hops += 1
        }
        // The resolved source must parse + reference no body-local / inaccessible member,
        // so the thunk closure `{ self.<resolved> }` compiles. (A residual body-local means
        // the alias didn't resolve to an accessible root — demote.)
        let probe = Parser.parse(source: "let __patch_coll = (\(resolved))")
        let blocked = bodyLocals.union(inaccessibleNames)
        if !blocked.isEmpty,
           ReferencedNameScanner.referencesAnyInSource(probe, of: blocked) {
            return nil
        }
        // Reject a degenerate / empty source.
        guard !resolved.isEmpty else { return nil }
        return resolved
    }

    /// G30 — build a guest loop for `ForEach(<scalarArr>.enumerated())` /
    /// `ForEach(Array(<scalarArr>.enumerated()))` over a MARSHALLED scalar-array input.
    /// Supports BOTH closure binding shapes:
    ///   * destructured `{ (index, value) in … }` → `for (index, value) in arr.enumerated()`
    ///   * single tuple `{ pair in … pair.offset … pair.element … }` → `for pair in …`
    /// Returns nil unless the base is a bare scalar-array input AND the row references a
    /// bound name (so the loop is meaningful) — otherwise the caller falls through to the
    /// regular loop path / a native slot (never an unbound loop var). Enumerating ONLY a
    /// scalar array: a struct/custom-type `.enumerated()` needs full struct marshalling
    /// (a later wave) and stays a slot here (faithful over broken).
    private mutating func loweredEnumeratedLoop(collectionArg: LabeledExprSyntax,
                                                rowClosure: ClosureExprSyntax) -> String? {
        let collection = collectionArg.expression.trimmedDescription
        guard let base = Self.enumeratedScalarBase(collection),
              scalarArrayInputNames.contains(base) else { return nil }
        // Determine the loop binding + the bound names that must be referenced.
        let binding: String
        let boundNames: [String]
        if let names = Self.destructuredTuplePair(rowClosure) {
            binding = "(\(names.0), \(names.1))"
            boundNames = [names.0, names.1]
        } else if let single = forEachLoopVarName(rowClosure) {
            binding = single
            boundNames = [single]
        } else {
            return nil
        }
        // Emit the row body with the binding(s) in scope (LocalNameCollector already
        // walked the closure params into `bodyLocals`, so a leaf reading them is correctly
        // non-slotable). Use `.enumerated()` directly so `(offset, element)` /
        // `pair.offset`/`pair.element` resolve against the Swift stdlib tuple. Via
        // `emitRowBuilder` a ROW-LOCAL `let` (G33) rides into the guest, not dropped.
        let row = emitRowBuilder(rowClosure.statements, loopVars: boundNames)
        guard !row.isEmpty else { return nil }
        // The row must reference a bound name as a LIVE identifier (else looping is
        // meaningless — a fully-opaque row would emit N indistinguishable nodes + leave
        // the binding unused). Demote to a native slot when it doesn't.
        guard boundNames.contains(where: { Self.guestExprReferences(row, name: $0) }) else { return nil }
        let indentedRow = row.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "        " + $0 }.joined(separator: "\n")
        return """
        { () -> [ViewNode] in
            var __rows: [ViewNode] = []
            for \(binding) in \(base).enumerated() {
                __rows.append(
        \(indentedRow)
                )
            }
            return __rows
        }()
        """
    }

    /// If `src` is `<base>.enumerated()` or `Array(<base>.enumerated())` where `<base>`
    /// is a bare identifier, return `<base>`; else nil. (Only a bare base names a
    /// marshalled array input the guest can iterate.)
    static func enumeratedScalarBase(_ src: String) -> String? {
        var s = src.trimmingCharacters(in: .whitespaces)
        // Unwrap `Array( … )`.
        if s.hasPrefix("Array("), s.hasSuffix(")") {
            s = String(s.dropFirst("Array(".count).dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard s.hasSuffix(".enumerated()") else { return nil }
        let base = String(s.dropLast(".enumerated()".count)).trimmingCharacters(in: .whitespaces)
        guard let first = base.first, first == "_" || first.isLetter,
              base.allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }) else { return nil }
        return base
    }

    /// The two destructured tuple parameter names of a `{ (a, b) in … }` row closure,
    /// or nil if it isn't a 2-param closure (a single-param / shorthand `$0` form). Each
    /// name must be a plain identifier (not `_` / `$0`).
    static func destructuredTuplePair(_ closure: ClosureExprSyntax) -> (String, String)? {
        guard let clause = closure.signature?.parameterClause else { return nil }
        if let typed = clause.as(ClosureParameterClauseSyntax.self) {
            let params = Array(typed.parameters)
            guard params.count == 2 else { return nil }
            let a = (params[0].secondName ?? params[0].firstName).text
            let b = (params[1].secondName ?? params[1].firstName).text
            guard !a.hasPrefix("$"), a != "_", !b.hasPrefix("$"), b != "_" else { return nil }
            return (a, b)
        }
        if let shorthand = clause.as(ClosureShorthandParameterListSyntax.self) {
            let params = Array(shorthand)
            guard params.count == 2 else { return nil }
            let a = params[0].name.text, b = params[1].name.text
            guard !a.hasPrefix("$"), a != "_", !b.hasPrefix("$"), b != "_" else { return nil }
            return (a, b)
        }
        return nil
    }

    /// Build a `[ViewNode]`-producing immediately-invoked closure that iterates a
    /// MARSHALLED array input and appends one lowered row per element, binding the loop
    /// variable — the ONLY form that compiles + runs in the guest. Handles BOTH a
    /// scalar-array input (`[Int]`/`[String]`/…, loop var is a scalar) AND a
    /// flat-struct-array input (`[SomeStruct]`, loop var is the generated guest struct,
    /// so `item.field` resolves — TASK 1). Returns nil when the collection isn't a
    /// guest-reconstructable bound array, the row closure isn't a single-explicit-
    /// parameter builder, or (for a struct array) the row uses the element in a way the
    /// guest can't compile (a bare `item` / a method call / a non-flat-field access);
    /// the caller then demotes the whole construct to a native slot rather than emit
    /// broken guest code (which would fail the whole SwiftUI guest compile and ship NO
    /// views).
    private mutating func loweredRowLoop(collectionArg: LabeledExprSyntax,
                                         rowClosure: ClosureExprSyntax) -> String? {
        guard let loopVar = forEachLoopVarName(rowClosure) else { return nil }
        let collection = collectionArg.expression.trimmedDescription
        // The collection is either:
        //  (a) a BARE identifier naming a marshalled array input (the guest has a real
        //      `[T]` for it — a scalar array or `[SomeStruct]` top-level input), OR
        //  (b) a member-access chain `input.field…` resolving (through the recursive
        //      field shapes) to a STRUCT-ARRAY / SCALAR-ARRAY field of a bound flat-struct
        //      input — the guest reconstructs `input.field` as a real array too.
        // Anything else (a call, a range, a non-reconstructable type) falls to a native slot.
        var structElement: BodyLowering.ViewInput.StructElement?   // the row element type, if a struct array
        var isScalarArray = false
        if isSimpleIdentifier(collection) {
            structElement = structArrayInputElements[collection]
            isScalarArray = scalarArrayInputNames.contains(collection)
            guard isScalarArray || structElement != nil else { return nil }
        } else if let resolved = resolveFlatStructCollection(collection) {
            // (b) `input.field` resolving to a struct-array / scalar-array field.
            switch resolved {
            case .structArray(let el): structElement = el
            case .scalarArray: isScalarArray = true
            default: return nil
            }
        } else {
            return nil
        }

        // STRUCT-ARRAY: the loop var is the generated guest struct, so the row may ONLY
        // use the element as `item.<field>`[`.<nested>`…] resolving through the RECURSIVE
        // field shapes to a scalar leaf (or a whole collection in a ForEach/`.count`).
        // Every other use (a bare `item`, a method call, an unknown member) would not
        // compile against the guest struct → demote the whole ForEach (faithful over broken).
        if let element = structElement {
            guard ElementUsageScanner.usesOnlyReconstructableFields(
                rowClosure.statements, element: loopVar, fields: element.fields) else {
                return nil
            }
        }

        // Emit the row body with the loop var in scope. `bodyLocals` already includes
        // the closure's parameter (LocalNameCollector walks closure params), so a row
        // leaf referencing the loop var is correctly classified non-slotable. Use
        // `emitBuilderBlock` (not `emitItems`) so a ROW-LOCAL `let` (`let isPeak = idx ==
        // peakIdx`) is emitted as a real guest binding (G33) rather than dropped — a
        // dropped row-local would leave a free reference that excludes the whole view.
        let row = emitRowBuilder(rowClosure.statements, loopVars: [loopVar])
        guard !row.isEmpty else { return nil }

        // The emitted row must reference the loop var as a LIVE identifier for the loop
        // to be meaningful. If it doesn't — because the WHOLE row lowered to a single
        // `.opaque` leaf (the row body was non-lowerable: e.g. an HStack with an
        // unsupported modifier), or the row genuinely ignores the element — looping
        // would (a) emit `N` identical opaque nodes the SDK can't distinguish, and
        // (b) leave the bound `\(loopVar)` UNUSED (a guest-compile warning). DEMOTE the
        // whole ForEach to ONE native slot instead (more faithful: the row renders
        // natively per element, and the loop var leak is gone). A row that lowers even
        // PARTLY (any lowered child reads the element, e.g. `Text(tag)`) keeps the loop;
        // its non-lowerable leaf is non-slotable, so the view stays native via the thunk
        // — but the module still compiles cleanly, which is the invariant that matters.
        guard Self.guestExprReferences(row, name: loopVar) else { return nil }

        let indentedRow = row.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "        " + $0 }.joined(separator: "\n")
        return """
        { () -> [ViewNode] in
            var __rows: [ViewNode] = []
            for \(loopVar) in \(collection) {
                __rows.append(
        \(indentedRow)
                )
            }
            return __rows
        }()
        """
    }

    /// Resolve a member-access collection string (`cart.items`, `a.b.items`) to the FIELD
    /// SHAPE it names, when the leading identifier is a bound flat-struct input and the
    /// chain walks (through nested structs) to a struct-array / scalar-array field. Returns
    /// nil for anything else (an unknown input, a non-array field, a deeper-than-bound
    /// chain) → the caller demotes the ForEach to a native slot. The guest reconstructs the
    /// nested array field, so `for x in input.field` compiles and iterates the real values.
    private func resolveFlatStructCollection(_ collection: String) -> BodyLowering.FieldShape? {
        // Split `a.b.c` → ["a","b","c"]. Reject anything that isn't a plain dotted chain
        // of identifiers (a call, a subscript, `self.x`, an operator all bail).
        let parts = collection.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }),
              let element = flatStructInputElements[parts[0]] else { return nil }
        // Walk the remaining chain through the recursive field shapes.
        switch BodyLowering.resolveFieldChain(Array(parts.dropFirst()), fields: element.fields) {
        case .collection(let shape): return shape
        default: return nil
        }
    }

    /// True iff `raw` is a member access (`base.f…`) whose LEADING identifier is a bound
    /// flat-struct INPUT but whose field chain does NOT resolve to one of that input's
    /// marshalled fields (`.unsafe`) — i.e. the guest's mirroring struct for `base` doesn't
    /// carry that field, so emitting the read VERBATIM would reference a name the guest can't
    /// resolve. Reactive-collection marshalling registers `vm` carrying ONLY its collection
    /// fields, so a `vm.title` String read lands here and must HOST-PROJECT (a `__strtok_`
    /// token) instead of going verbatim. A normal flat-struct input's reads always resolve
    /// (the whole-body usage gate proved it), so this never fires for them — it's surgical to
    /// the un-gated reactive case. Build-safe = demote-safe: a member that can't host-project
    /// then slots/demotes via the caller.
    private func flatStructInputMemberLeaks(_ raw: String) -> Bool {
        let trimmed = Self.strippingLeadingSelf(raw.trimmingCharacters(in: .whitespaces))
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }),
              let element = flatStructInputElements[parts[0]] else { return false }
        if case .unsafe = BodyLowering.resolveFieldChain(Array(parts.dropFirst()), fields: element.fields) {
            return true
        }
        return false
    }

    /// Whether the emitted guest builder expression `expr` references `name` as a LIVE
    /// identifier (a `DeclReferenceExpr`), parsed as a Swift expression. Names that
    /// appear only inside an `N.opaque(…, label: "…")` string literal don't count (a
    /// fully-opaque row carries the loop var only in its label, never live).
    static func guestExprReferences(_ expr: String, name: String) -> Bool {
        BodyLowering.guestBodyReferencesAny(expr, names: [name])
    }

    /// The ForEach row-builder closure: the trailing closure, or a `content:`/last
    /// closure argument. Returns nil when there is no closure (an unhandled form).
    private func forEachRowClosure(_ call: FunctionCallExprSyntax) -> ClosureExprSyntax? {
        if let trailing = call.trailingClosure { return trailing }
        for arg in call.arguments.reversed() {
            if let c = arg.expression.as(ClosureExprSyntax.self) { return c }
        }
        return nil
    }

    /// The row closure's SINGLE explicit element parameter name (`{ item in … }`
    /// → "item"). Returns nil for the implicit-`$0` form (`{ Text($0) }`) — we can't
    /// bind `$0` with a `for` loop, so such a row DEMOTES rather than emit broken
    /// code — and nil for a multi-param closure (a `ForEach` row never has >1 param;
    /// such a shape is not a row builder we can loop). The explicit-single-param form
    /// is the overwhelmingly common one.
    private func forEachLoopVarName(_ closure: ClosureExprSyntax) -> String? {
        guard let clause = closure.signature?.parameterClause else { return nil }
        // `{ x in … }` / `{ (x: T) in … }` — the typed parameter clause.
        if let typed = clause.as(ClosureParameterClauseSyntax.self) {
            guard typed.parameters.count == 1, let p = typed.parameters.first else { return nil }
            let name = (p.secondName ?? p.firstName).text
            return name.hasPrefix("$") ? nil : name
        }
        // `{ x in … }` shorthand list (no parens). A single explicit name only.
        if let shorthand = clause.as(ClosureShorthandParameterListSyntax.self) {
            guard shorthand.count == 1, let p = shorthand.first else { return nil }
            let name = p.name.text
            return name.hasPrefix("$") ? nil : name
        }
        return nil
    }

    /// True iff `s` is a single bare identifier (`items`) — not a member access
    /// (`m.items`), call (`f()`), subscript, or any compound expression.
    private func isSimpleIdentifier(_ s: String) -> Bool {
        guard let first = s.first, first == "_" || first.isLetter else { return false }
        return s.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private mutating func emitStack(_ fn: String, call: FunctionCallExprSyntax,
                                    horizontal: Bool) -> String {
        var pieces: [String] = []
        if let align = call.arguments.first(where: { $0.label?.text == "alignment" }) {
            let raw = align.expression.trimmedDescription
                .replacingOccurrences(of: ".", with: "")
            // BUG #63: validate against the IR alignment allowlist before emitting. NOTE the
            // `horizontal` param means "uses a HorizontalAlignment" — it is TRUE for V-stacks
            // (a VStack aligns along the horizontal axis → HorizontalAlignment {leading,center,
            // trailing}) and FALSE for H-stacks (VerticalAlignment {top,center,bottom,
            // firstTextBaseline,lastTextBaseline}). A custom/non-standard guide is NOT a valid IR
            // case, so the guest wrapper wouldn't compile (→ wasteful isolation). Slot the WHOLE
            // stack natively (renders the real alignment) instead — build-safe = demote-safe.
            let valid: Set<String> = horizontal
                ? ["leading", "center", "trailing"]
                : ["top", "center", "bottom", "firstTextBaseline", "lastTextBaseline"]
            guard valid.contains(raw) else { return opaqueExpr(ExprSyntax(call), labelHint: fn) }
            pieces.append("alignment: .\(raw)")
        }
        if let spacing = call.arguments.first(where: { $0.label?.text == "spacing" }),
           spacing.expression.trimmedDescription != "nil" {
            // BUG #64: `spacing: nil` (an explicit default) must NOT become `Double(nil)`
            // (uncompilable). `nil` == default spacing, so OMITTING the piece is semantically
            // identical — only a non-nil spacing is lowered below.
            // MULTI-SITE HOST-PROJECTION: route the container `spacing:` through the SAME
            // numeric host-projection the modifier positions (`.padding`/`.cornerRadius`) use.
            // A design-system constant (`VStack(spacing: Theme.Radius.sm)`) thus lowers as a
            // `__numtok_<id>` (the thunk evals `Theme.Radius.sm` natively) instead of LEAKING
            // `Theme` and demoting the whole stack. A literal / marshalled-input spacing
            // resolves verbatim (unchanged); an unresolvable expr falls back to verbatim so the
            // build-time scope check demotes honestly (never a silently-wrong layout).
            let raw = spacing.expression.trimmedDescription
            let resolved = numericOrToken(raw) ?? raw
            pieces.append("spacing: Double(\(resolved))")
        }
        let header = pieces.isEmpty ? "" : pieces.joined(separator: ", ") + ", "
        let children = childrenCode(call)
        return "N.\(fn)(\(header)[\n\(children)\n])"
    }

    private mutating func emitZStack(call: FunctionCallExprSyntax) -> String {
        var header = ""
        if let align = call.arguments.first(where: { $0.label?.text == "alignment" }) {
            // BUG R2-#121: validate against the IRAlignment allowlist (the BUG #63 class,
            // previously only patched for V/HStack). A non-IR `Alignment` guide
            // (`.leadingFirstTextBaseline`, a custom `extension Alignment` guide) would
            // emit an invalid enum case → guest WASM compile failure. Slot the whole
            // ZStack natively on a miss (build-safe = demote-safe).
            guard let c = Self.loweredAlignmentOrNil(align.expression.trimmedDescription) else {
                return opaqueExpr(ExprSyntax(call), labelHint: "ZStack")
            }
            header = "alignment: .\(c), "
        }
        let children = childrenCode(call)
        return "N.zstack(\(header)[\n\(children)\n])"
    }

    // MARK: IR v2 containers

    private mutating func emitScrollView(call: FunctionCallExprSyntax) -> String {
        // The axis is the leading unlabeled arg (`.horizontal`/`.vertical`); the
        // SwiftUI default is `.vertical`. `showsIndicators:` and a multi-axis set
        // (`[.horizontal, .vertical]`) are not modeled → default to vertical.
        var axis = "vertical"
        if let first = call.arguments.first(where: { $0.label == nil }) {
            let raw = first.expression.trimmedDescription
            if raw.contains("horizontal") && !raw.contains("vertical") { axis = "horizontal" }
        }
        let children = childrenCode(call)
        return "N.scrollView(axis: .\(axis), [\n\(children)\n])"
    }

    private mutating func emitLabel(call: FunctionCallExprSyntax) -> String {
        // Convenience: `Label("Title", systemImage: "house")` → the string/SF-symbol
        // form (kept as the dedicated builder which expands to title:[.text]/icon:[.image]).
        if let sys = call.arguments.first(where: { $0.label?.text == "systemImage" }),
           let titleArg = call.arguments.first(where: { $0.label == nil }),
           titleArg.expression.as(StringLiteralExprSyntax.self) != nil {
            return "N.label(title: \(titleArg.expression.trimmedDescription), "
                + "systemImage: \(sys.expression.trimmedDescription))"
        }
        // General builder: `Label { title } icon: { icon }` → recurse both subtrees.
        var title: [String] = []
        var icon: [String] = []
        if let trailing = call.trailingClosure {
            title = emitItems(trailing.statements)
        }
        for add in call.additionalTrailingClosures {
            if add.label.text == "icon" { icon = emitItems(add.closure.statements) }
            else if add.label.text == "title" { title = emitItems(add.closure.statements) }
        }
        // `title:`/`icon:` as normal closure arguments.
        for arg in call.arguments {
            guard let lbl = arg.label?.text, let c = arg.expression.as(ClosureExprSyntax.self) else { continue }
            if lbl == "title" { title = emitItems(c.statements) }
            else if lbl == "icon" { icon = emitItems(c.statements) }
        }
        // Need BOTH a title and an icon to faithfully rebuild; otherwise slot.
        if title.isEmpty || icon.isEmpty {
            return opaqueExpr(ExprSyntax(call), labelHint: "Label")
        }
        return "N.label(title: \(nodeList(title)), icon: \(nodeList(icon)))"
    }

    private mutating func emitAsyncImage(call: FunctionCallExprSyntax) -> String {
        // `AsyncImage(url: URL(string: "literal")[, scale: x])` — the DEFAULT form
        // (no content/placeholder closure) renders the real AsyncImage. A
        // content/placeholder-closure form, or a non-literal URL, slots.
        guard call.trailingClosure == nil,
              !call.arguments.contains(where: { $0.expression.is(ClosureExprSyntax.self) }),
              let urlArg = call.arguments.first(where: { $0.label?.text == "url" }),
              let urlString = Self.literalURLString(urlArg.expression.trimmedDescription) else {
            return opaqueExpr(ExprSyntax(call), labelHint: "AsyncImage")
        }
        var scale = ""
        if let s = call.arguments.first(where: { $0.label?.text == "scale" }) {
            scale = ", scale: Double(\(s.expression.trimmedDescription))"
        }
        return "N.asyncImage(url: \(urlString)\(scale))"
    }

    private mutating func emitProgressView(call: FunctionCallExprSyntax) -> String {
        let args = call.arguments
        // A bare `ProgressView()` (indeterminate spinner).
        if args.isEmpty && call.trailingClosure == nil {
            return "N.progressView"
        }
        // Determinate `ProgressView(value: x[, total: y])` [ { label } | "title" ].
        if let value = args.first(where: { $0.label?.text == "value" }) {
            var total = "1"
            if let t = args.first(where: { $0.label?.text == "total" }) {
                total = "Double(\(t.expression.trimmedDescription))"
            }
            // Label: a leading string title → a Text; else a trailing/`label:` closure.
            var label: [String] = []
            if let titled = args.first(where: { $0.label == nil }),
               titled.expression.as(StringLiteralExprSyntax.self) != nil {
                // BUG R2-#65/#66/#67/#119: markdown → styledText; overload → slot.
                guard let node = Self.emitTitleTextLiteral(titled.expression) else {
                    return opaqueExpr(ExprSyntax(call), labelHint: "ProgressView")
                }
                label = [node]
            } else if let trailing = call.trailingClosure {
                label = emitItems(trailing.statements)
            } else {
                for arg in args where arg.label?.text == "label" {
                    if let c = arg.expression.as(ClosureExprSyntax.self) { label = emitItems(c.statements) }
                }
            }
            return "N.progressView(value: Double(\(value.expression.trimmedDescription)), "
                + "total: \(total), label: \(nodeList(label)))"
        }
        // `ProgressView("title")` (indeterminate w/ a label) and other forms slot.
        // Lift any plain string-literal title so editing "Loading…" is OTA-stable.
        return opaqueExprLifted(ExprSyntax(call), labelHint: "ProgressView")
    }

    private mutating func emitGauge(call: FunctionCallExprSyntax) -> String {
        let args = call.arguments
        guard let value = args.first(where: { $0.label?.text == "value" }) else {
            return opaqueExpr(ExprSyntax(call), labelHint: "Gauge")
        }
        // `in: lo...hi` → min/max; default 0...1.
        var minMax = "min: 0, max: 1"
        if let r = args.first(where: { $0.label?.text == "in" }),
           let bounds = Self.doubleRangeBounds(r.expression.trimmedDescription) {
            minMax = "min: \(bounds.0), max: \(bounds.1)"
        } else if args.contains(where: { $0.label?.text == "in" }) {
            // A non-literal range we can't reduce → slot (can't faithfully rebuild).
            return opaqueExpr(ExprSyntax(call), labelHint: "Gauge")
        }
        // Label: a leading string title → Text; else a trailing/`label:` closure.
        var label: [String] = []
        if let titled = args.first(where: { $0.label == nil }),
           titled.expression.as(StringLiteralExprSyntax.self) != nil {
            // BUG R2-#65/#66/#67/#119: markdown → styledText; overload → slot.
            guard let node = Self.emitTitleTextLiteral(titled.expression) else {
                return opaqueExpr(ExprSyntax(call), labelHint: "Gauge")
            }
            label = [node]
        } else if let trailing = call.trailingClosure {
            label = emitItems(trailing.statements)
        } else {
            for arg in args where arg.label?.text == "label" {
                if let c = arg.expression.as(ClosureExprSyntax.self) { label = emitItems(c.statements) }
            }
        }
        return "N.gauge(value: Double(\(value.expression.trimmedDescription)), \(minMax), label: \(nodeList(label)))"
    }

    private mutating func emitLink(call: FunctionCallExprSyntax) -> String {
        // `Link("Title", destination: URL(...))` OR `Link(destination:) { label }`.
        guard let destArg = call.arguments.first(where: { $0.label?.text == "destination" }),
              let dest = Self.literalURLString(destArg.expression.trimmedDescription) else {
            // FIX: title-literal fingerprint stability — if the leading unlabeled arg is a
            // plain string literal (the link title), lift it via `opaqueCall` so the id
            // is STRUCTURAL (literal-independent) and editing only the title is fingerprint-stable.
            // A non-literal title (variable / interpolation) has no liftable arg → falls back
            // to plain `opaqueExpr` unchanged (demote-safe: slotability is unaffected).
            return opaqueCall(call, labelHint: "Link")
        }
        // String-titled form: the leading literal is the label.
        if let titled = call.arguments.first(where: { $0.label == nil }),
           titled.expression.as(StringLiteralExprSyntax.self) != nil {
            // BUG R2-#65/#66/#67/#119: markdown → styledText; overload → slot.
            guard let node = Self.emitTitleTextLiteral(titled.expression) else {
                return opaqueExpr(ExprSyntax(call), labelHint: "Link")
            }
            return "N.link(destination: \(dest), label: [\(node)])"
        }
        // Trailing-closure label.
        var label: [String] = []
        if let trailing = call.trailingClosure {
            label = emitItems(trailing.statements)
        } else {
            for arg in call.arguments where arg.label?.text == "label" {
                if let c = arg.expression.as(ClosureExprSyntax.self) { label = emitItems(c.statements) }
            }
        }
        if label.isEmpty { return opaqueExpr(ExprSyntax(call), labelHint: "Link") }
        return "N.link(destination: \(dest), label: \(nodeList(label)))"
    }

    private mutating func emitShareLink(call: FunctionCallExprSyntax) -> String {
        // `ShareLink(item: "x")` / `ShareLink(items: [...])` of STRING items. A
        // custom `Transferable` item (non-string) slots. An optional label closure
        // recurses; the default form emits an empty label.
        var items: [String] = []
        if let item = call.arguments.first(where: { $0.label?.text == "item" }) {
            guard let s = Self.stringLiteralOrIdent(item.expression) else {
                return opaqueExpr(ExprSyntax(call), labelHint: "ShareLink")
            }
            items = [s]
        } else if let itemsArg = call.arguments.first(where: { $0.label?.text == "items" }),
                  let arr = itemsArg.expression.as(ArrayExprSyntax.self) {
            for el in arr.elements {
                guard let s = Self.stringLiteralOrIdent(el.expression) else {
                    return opaqueExpr(ExprSyntax(call), labelHint: "ShareLink")
                }
                items.append(s)
            }
        } else {
            return opaqueExpr(ExprSyntax(call), labelHint: "ShareLink")
        }
        var label: [String] = []
        if let trailing = call.trailingClosure {
            label = emitItems(trailing.statements)
        } else {
            for arg in call.arguments where arg.label?.text == "label" {
                if let c = arg.expression.as(ClosureExprSyntax.self) { label = emitItems(c.statements) }
            }
        }
        let itemsLiteral = "[" + items.joined(separator: ", ") + "]"
        return "N.shareLink(items: \(itemsLiteral), label: \(nodeList(label)))"
    }

    private mutating func emitSecureField(call: FunctionCallExprSyntax) -> String {
        guard let b = eventArg(call, "text") else { return opaqueExpr(ExprSyntax(call), labelHint: "SecureField") }
        // BUG R2-#66/#67: placeholder LocalizedStringKey interpolation overload → slot.
        if let ph = call.arguments.first(where: { $0.label == nil })?.expression
            .as(StringLiteralExprSyntax.self), Self.literalHasSwiftUIInterpolationOverload(ph) {
            return opaqueExpr(ExprSyntax(call), labelHint: "SecureField")
        }
        let placeholder = call.arguments.first { $0.label == nil }?
            .expression.trimmedDescription ?? "\"\""
        record(event: b.event, field: b.value, op: .setString)
        return "N.secureField(\(placeholder), text: \(b.value), event: \"\(b.event)\")"
    }

    private mutating func emitTextEditor(call: FunctionCallExprSyntax) -> String {
        guard let b = eventArg(call, "text") else { return opaqueExpr(ExprSyntax(call), labelHint: "TextEditor") }
        record(event: b.event, field: b.value, op: .setString)
        return "N.textEditor(text: \(b.value), event: \"\(b.event)\")"
    }

    private mutating func emitLabeledContent(call: FunctionCallExprSyntax) -> String {
        // `LabeledContent("Title") { content }` OR `LabeledContent { content } label: { label }`.
        var label: [String] = []
        var content: [String] = []
        if let titled = call.arguments.first(where: { $0.label == nil }),
           titled.expression.as(StringLiteralExprSyntax.self) != nil {
            // BUG R2-#65/#66/#67/#119: markdown → styledText; overload → slot.
            guard let node = Self.emitTitleTextLiteral(titled.expression) else {
                return opaqueExprLifted(ExprSyntax(call), labelHint: "LabeledContent")
            }
            label = [node]
        }
        if let trailing = call.trailingClosure {
            content = emitItems(trailing.statements)
        }
        for add in call.additionalTrailingClosures where add.label.text == "label" {
            label = emitItems(add.closure.statements)
        }
        for arg in call.arguments {
            guard let lbl = arg.label?.text, let c = arg.expression.as(ClosureExprSyntax.self) else { continue }
            if lbl == "content" { content = emitItems(c.statements) }
            else if lbl == "label" { label = emitItems(c.statements) }
        }
        if content.isEmpty && label.isEmpty {
            return opaqueExprLifted(ExprSyntax(call), labelHint: "LabeledContent")
        }
        return "N.labeledContent(label: \(nodeList(label)), content: \(nodeList(content)))"
    }

    private mutating func emitMenu(call: FunctionCallExprSyntax) -> String {
        // `Menu("Title") { items }` OR `Menu { items } label: { label }`.
        var label: [String] = []
        var items: [String] = []
        if let titled = call.arguments.first(where: { $0.label == nil }),
           titled.expression.as(StringLiteralExprSyntax.self) != nil {
            // BUG R2-#65/#66/#67/#119: markdown → styledText; overload → slot.
            guard let node = Self.emitTitleTextLiteral(titled.expression) else {
                // Lift any plain string-literal title (e.g. markdown "**Bold**") so
                // editing the title is OTA-stable even when the whole Menu slots.
                return opaqueExprLifted(ExprSyntax(call), labelHint: "Menu")
            }
            label = [node]
        }
        // The menu's CONTENT is an ACTIONS-LIST context (its Buttons live in the menu's
        // item list, where the renderer can't attach a native slot) — an undispatchable
        // Button there demotes the view. The `label:` is plain content (lowers normally).
        if let trailing = call.trailingClosure {
            items = emitActionItems(trailing.statements)
        }
        for add in call.additionalTrailingClosures where add.label.text == "label" {
            label = emitItems(add.closure.statements)
        }
        for arg in call.arguments {
            guard let lbl = arg.label?.text, let c = arg.expression.as(ClosureExprSyntax.self) else { continue }
            if lbl == "content" { items = emitActionItems(c.statements) }
            else if lbl == "label" { label = emitItems(c.statements) }
        }
        if label.isEmpty || items.isEmpty {
            // Lift any plain string-literal title so editing "Sort" in a Menu("Sort"){…}
            // that can't lower (undispatchable buttons) is OTA-patchable + fingerprint-stable.
            return opaqueExprLifted(ExprSyntax(call), labelHint: "Menu")
        }
        return "N.menu(label: \(nodeList(label)), items: \(nodeList(items)))"
    }

    // MARK: Host-state controls (B — selection / navigation)

    private mutating func emitPicker(call: FunctionCallExprSyntax) -> String {
        // `Picker("Title", selection: $sel) { rows }` (or `Picker(selection:){…} label:{…}`).
        // The bound `$sel` becomes the event/field; each row must be a view carrying a
        // LITERAL `.tag(Int/String)`. A custom Hashable tag, a ForEach-generated row
        // set (the tag binds a body-local), or a missing tag → slot (faithful).
        guard let b = eventArg(call, "selection") else {
            // Lift any plain string-literal title so editing it is OTA-stable.
            return opaqueExprLifted(ExprSyntax(call), labelHint: "Picker")
        }
        // The content closure (the rows).
        var rowStatements: [CodeBlockItemSyntax] = []
        if let trailing = call.trailingClosure {
            rowStatements = Array(trailing.statements)
        } else {
            for arg in call.arguments where arg.label?.text == "content" {
                if let c = arg.expression.as(ClosureExprSyntax.self) { rowStatements = Array(c.statements) }
            }
        }
        guard !rowStatements.isEmpty else {
            // Lift any plain string-literal title so editing "Appearance" in a
            // Picker("Appearance", selection: …) { /* no rows */ } is OTA-stable.
            return opaqueExprLifted(ExprSyntax(call), labelHint: "Picker")
        }
        // Parse each row into (tag, labelNode). A row that isn't `<view>.tag(literal)`
        // (e.g. a ForEach, an interpolated tag) makes the whole Picker slot.
        var intOptions: [(String, String)] = []   // (tagLiteral, loweredLabelNode)
        var stringOptions: [(String, String)] = []
        for item in rowStatements {
            guard case .expr(let e) = item.item,
                  let (tagExpr, viewExpr) = Self.splitTagModifier(e) else {
                // Row isn't .tag(literal) — whole Picker slots. Lift the title so
                // editing e.g. "Appearance" in a ForEach-row Picker is OTA-stable.
                return opaqueExprLifted(ExprSyntax(call), labelHint: "Picker")
            }
            let labelNode = emitExpr(viewExpr)
            if let i = Self.intLiteral(tagExpr) {
                intOptions.append((String(i), labelNode))
            } else if tagExpr.as(StringLiteralExprSyntax.self) != nil {
                stringOptions.append((tagExpr.trimmedDescription, labelNode))
            } else {
                return opaqueExprLifted(ExprSyntax(call), labelHint: "Picker")
            }
        }
        // The label: a leading string title, else a `label:` closure.
        var label: [String] = []
        if let titled = call.arguments.first(where: { $0.label == nil }),
           titled.expression.as(StringLiteralExprSyntax.self) != nil {
            // BUG R2-#65/#66/#67/#119: markdown → styledText; overload → slot.
            guard let node = Self.emitTitleTextLiteral(titled.expression) else {
                return opaqueExprLifted(ExprSyntax(call), labelHint: "Picker")
            }
            label = [node]
        } else {
            for add in call.additionalTrailingClosures where add.label.text == "label" {
                label = emitItems(add.closure.statements)
            }
            for arg in call.arguments where arg.label?.text == "label" {
                if let c = arg.expression.as(ClosureExprSyntax.self) { label = emitItems(c.statements) }
            }
        }
        // All rows must agree on a single tag type (mixing int+string can't lower).
        if !intOptions.isEmpty && stringOptions.isEmpty {
            // The Picker's selection is an Int field; assign the picked tag.
            record(event: b.event, field: b.value, op: .setIntClamped(lo: nil, hi: nil))
            let opts = intOptions.map { "IRPickerOption(tag: .int(\($0.0)), label: [\($0.1)])" }
                .joined(separator: ", ")
            return "N.picker(label: \(nodeList(label)), selection: \(b.value), options: [\(opts)], event: \"\(b.event)\")"
        }
        if !stringOptions.isEmpty && intOptions.isEmpty {
            record(event: b.event, field: b.value, op: .setString)
            let opts = stringOptions.map { "IRPickerOption(tag: .string(\($0.0)), label: [\($0.1)])" }
                .joined(separator: ", ")
            return "N.picker(label: \(nodeList(label)), selection: \(b.value), options: [\(opts)], event: \"\(b.event)\")"
        }
        // Mixed int+string tags — whole Picker slots. Lift the title.
        return opaqueExprLifted(ExprSyntax(call), labelHint: "Picker")
    }

    /// Split a `<view>.tag(<value>)` expression into (`<value>` tag arg, `<view>` base).
    /// Returns nil if the OUTERMOST modifier isn't a single-arg `.tag(...)`.
    static func splitTagModifier(_ expr: ExprSyntax) -> (tag: ExprSyntax, view: ExprSyntax)? {
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "tag",
              let base = member.base,
              call.arguments.count == 1, let only = call.arguments.first, only.label == nil,
              call.trailingClosure == nil else { return nil }
        return (only.expression, base)
    }

    private mutating func emitNavigationLink(call: FunctionCallExprSyntax) -> String {
        // The EAGER `NavigationLink(destination:) { label }` / `NavigationLink { label }
        // destination: { dest }` form: SwiftUI owns push/pop; both subtrees recurse.
        // A value-based `NavigationLink(value:)` (needs NavigationStack(path:) + a
        // destination registry) slots here — that path form is hand-written/round-trip.
        if call.arguments.contains(where: { $0.label?.text == "value" }) {
            return opaqueExpr(ExprSyntax(call), labelHint: "NavigationLink")
        }
        // BUG R2-#48: the PROGRAMMATIC forms — `NavigationLink(destination:isActive:)`
        // and `(destination:tag:selection:)` — carry a binding the eager IR node can't
        // represent (it owns push/pop natively). Lowering would drop the binding and the
        // link would never activate programmatically. Slot the whole link natively.
        if call.arguments.contains(where: {
            $0.label?.text == "isActive" || $0.label?.text == "tag" || $0.label?.text == "selection" }) {
            return opaqueExpr(ExprSyntax(call), labelHint: "NavigationLink")
        }
        var destination: [String] = []
        var label: [String] = []
        // `destination:` as a normal closure/view arg.
        for arg in call.arguments {
            guard let lbl = arg.label?.text else { continue }
            if lbl == "destination" {
                if let c = arg.expression.as(ClosureExprSyntax.self) { destination = emitItems(c.statements) }
                else { destination = [emitExpr(arg.expression)] }
            }
        }
        // A leading string-literal title → a Text label (the `NavigationLink("Title", destination:)` form).
        if let titled = call.arguments.first(where: { $0.label == nil }),
           titled.expression.as(StringLiteralExprSyntax.self) != nil {
            // BUG R2-#65/#66/#67/#119: markdown → styledText; overload → slot.
            guard let node = Self.emitTitleTextLiteral(titled.expression) else {
                return opaqueExpr(ExprSyntax(call), labelHint: "NavigationLink")
            }
            label = [node]
        }
        // Trailing-closure forms (SwiftUI's `NavigationLink(destination:label:)`):
        //   * `NavigationLink { destination } label: { label }` — the LEADING trailing
        //     closure is the DESTINATION; the `label:` additional-trailing is the label.
        //   * `NavigationLink("Title") { destination }` — string label + the sole
        //     trailing closure is the destination.
        //   * `NavigationLink(destination:) { label }` (destination already from the
        //     `destination:` arg) — the sole trailing closure is the label.
        if !destination.isEmpty {
            // `destination:` was an explicit arg → a trailing closure is the label.
            if label.isEmpty, let trailing = call.trailingClosure {
                label = emitItems(trailing.statements)
            }
        } else if !label.isEmpty {
            // A string title gave us the label → the sole trailing closure is the dest.
            if let trailing = call.trailingClosure { destination = emitItems(trailing.statements) }
        } else {
            // No explicit destination/label yet → leading trailing closure is the
            // DESTINATION, and a `label:` additional-trailing-closure is the label.
            if let trailing = call.trailingClosure { destination = emitItems(trailing.statements) }
            for add in call.additionalTrailingClosures where add.label.text == "label" {
                label = emitItems(add.closure.statements)
            }
        }
        if destination.isEmpty || label.isEmpty {
            return opaqueExpr(ExprSyntax(call), labelHint: "NavigationLink")
        }
        return "N.navigationLink(destination: \(nodeList(destination)), label: \(nodeList(label)))"
    }

    // MARK: GeometryReader (C — promoted to host-state)

    /// Lower `GeometryReader { proxy in <body> }` to `N.geometryReader(id:, [<body>])`.
    /// The closure body is lowered with the proxy's geometry member accesses REWRITTEN
    /// to reserved input identifiers the guest binds from the input JSON (the SDK host
    /// wrapper injects the live proxy's size/frame there):
    ///   `proxy.size.width`  → `__geo_width`    `proxy.size.height` → `__geo_height`
    ///   `proxy.frame(in:).minX/.minY` → `__geo_minX`/`__geo_minY`
    ///   `proxy.frame(in:).width/.height` → `__geo_width`/`__geo_height`
    /// A proxy use we can't map (`proxy.size` whole, `proxy.safeAreaInsets`,
    /// `proxy[anchor]`, `.maxX`/`.midX`/…) DEMOTES the whole GeometryReader to a native
    /// slot — never a guest that references the unbound `proxy`. The `id` is a
    /// content-stable hash of the closure source so the SDK can re-locate THIS reader
    /// in the re-emitted tree (multiple readers don't collide).
    private mutating func emitGeometryReader(call: FunctionCallExprSyntax) -> String {
        // The body is the trailing closure (or a sole closure arg) with a single
        // explicit `proxy` parameter. Any other shape (no closure, multi-param,
        // implicit `$0`) → slot (we can't bind the proxy name to rewrite it).
        guard let closure = call.trailingClosure
                ?? call.arguments.first(where: { $0.expression.is(ClosureExprSyntax.self) })?
                    .expression.as(ClosureExprSyntax.self),
              let proxyName = singleClosureParamName(closure) else {
            return opaqueExpr(ExprSyntax(call), labelHint: "GeometryReader")
        }
        // Rewrite the proxy geometry accesses to the reserved identifiers. If ANY
        // `proxy` use is unmappable, the rewriter flags it → demote the whole reader.
        let rewriter = GeometryProxyRewriter(proxyName: proxyName)
        let rewrittenStmts = rewriter.rewrite(closure.statements)
        if rewriter.unmappable {
            return opaqueExpr(ExprSyntax(call), labelHint: "GeometryReader")
        }
        // The reserved geo names are body-locals from the emitter's POV only in that
        // they're now bare identifiers; they are NOT in `bodyLocals` (so a leaf reading
        // one is correctly NOT slot-blocked — it's a real guest input), and they will
        // be bound by the guest emitter. Mark geometry in use BEFORE lowering the child
        // so any numeric position inside it (a rewritten `.frame(width: __geo_width…)`)
        // sees `__geo_*` as in-scope — otherwise `numericOrToken` would mistake the
        // reserved geo input for an out-of-scope constant and tokenize it. (Set even on
        // the rare post-lowering demote below; the only cost is the guest binding unused
        // `__geo_*` vars, which are discarded — demote-safe.)
        usesGeometry = true
        let rowNodes = emitItems(rewrittenStmts)
        guard !rowNodes.isEmpty else { return opaqueExpr(ExprSyntax(call), labelHint: "GeometryReader") }
        // After lowering, the proxy name MUST be fully gone (every use rewritten). If a
        // live `proxy` reference survived (an unmapped form the rewriter passed through),
        // demote — a guest referencing the unbound `proxy` would fail the whole module.
        let childList = rowNodes.count == 1 ? rowNodes[0]
            : "N.group([\n" + rowNodes.map { indent($0) }.joined(separator: ",\n") + "\n])"
        if Self.guestExprReferences(childList, name: proxyName) {
            return opaqueExpr(ExprSyntax(call), labelHint: "GeometryReader")
        }
        let id = "geo_" + Self.stableHash64(call.trimmedDescription)
        return "N.geometryReader(id: \"\(id)\", [\n\(indent(childList))\n])"
    }

    // MARK: Path (declarative shape — literal scalar commands or slot)

    /// `Path { p in p.move(to: CGPoint(x:0,y:0)); p.addLine(to: …); … }` — a
    /// DECLARATIVE path of LITERAL scalar commands. Each statement must be a
    /// `<param>.<method>(...)` whose coordinates are numeric literals; any computed/
    /// non-literal coordinate, an unknown method, an `addArc`/ellipse, or any other
    /// statement shape → SLOT the whole Path (faithful — never a partial path). The
    /// render side replays `[IRPathCommand]` into a real `Path` (a Shape); fill/stroke
    /// ride as separate modifiers. The `Path(...)` convenience initializers
    /// (`Path(ellipseIn:)`, `Path(roundedRect:…)`, `Path(CGRect)`) are NOT the closure
    /// form, so they slot here too (no closure param).
    private mutating func emitPath(call: FunctionCallExprSyntax) -> String {
        guard let closure = call.trailingClosure
                ?? call.arguments.first(where: { $0.expression.is(ClosureExprSyntax.self) })?
                    .expression.as(ClosureExprSyntax.self),
              let pathName = singleClosureParamName(closure) else {
            return opaqueExpr(ExprSyntax(call), labelHint: "Path")
        }
        var commands: [String] = []
        for item in closure.statements {
            // Each statement must be a bare expression: `<pathName>.<method>(...)`.
            guard case .expr(let e) = item.item,
                  let cmd = Self.loweredPathCommand(e, pathName: pathName) else {
                return opaqueExpr(ExprSyntax(call), labelHint: "Path")
            }
            commands.append(cmd)
        }
        // An EMPTY path closure (`Path { _ in }`) is valid but renders nothing —
        // still lower it (an empty command list is a faithful empty shape).
        let list = "[" + commands.joined(separator: ", ") + "]"
        return "N.path(\(list))"
    }

    /// Lower one `<pathName>.<method>(<literal coords>)` statement to an
    /// `IRPathCommand(...)` builder literal, or nil if the statement isn't a
    /// recognized declarative command with numeric-literal coordinates.
    static func loweredPathCommand(_ expr: ExprSyntax, pathName: String) -> String? {
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              let base = member.base?.as(DeclReferenceExprSyntax.self),
              base.baseName.text == pathName,
              call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty else {
            return nil
        }
        let method = member.declName.baseName.text
        // A literal CGPoint(x:N, y:N) (or `.init(x:y:)`) → (x, y) literal pair.
        func point(_ e: ExprSyntax?) -> (String, String)? {
            guard let e, let pc = e.as(FunctionCallExprSyntax.self) else { return nil }
            let callee = pc.calledExpression.trimmedDescription
            guard callee == "CGPoint" || callee.hasSuffix(".init") || callee == "CGPoint.init" else { return nil }
            guard let x = pc.arguments.first(where: { $0.label?.text == "x" })?.expression.trimmedDescription,
                  let y = pc.arguments.first(where: { $0.label?.text == "y" })?.expression.trimmedDescription,
                  isNumericLiteral(x), isNumericLiteral(y) else { return nil }
            return (x, y)
        }
        func argExpr(_ label: String) -> ExprSyntax? {
            call.arguments.first(where: { $0.label?.text == label })?.expression
        }
        func numLit(_ label: String) -> String? {
            guard let v = argExpr(label)?.trimmedDescription, isNumericLiteral(v) else { return nil }
            return v
        }
        func firstUnlabeledExpr() -> ExprSyntax? {
            call.arguments.first(where: { $0.label == nil })?.expression
        }
        switch method {
        case "move":
            guard let p = point(argExpr("to")) else { return nil }
            return "IRPathCommand.move(x: Double(\(p.0)), y: Double(\(p.1)))"
        case "addLine":
            guard let p = point(argExpr("to")) else { return nil }
            return "IRPathCommand.line(x: Double(\(p.0)), y: Double(\(p.1)))"
        case "addQuadCurve":
            guard let to = point(argExpr("to")), let cp = point(argExpr("control")) else { return nil }
            return "IRPathCommand.quad(cpx: Double(\(cp.0)), cpy: Double(\(cp.1)), x: Double(\(to.0)), y: Double(\(to.1)))"
        case "addCurve":
            guard let to = point(argExpr("to")),
                  let c1 = point(argExpr("control1")), let c2 = point(argExpr("control2")) else { return nil }
            return "IRPathCommand.curve(cp1x: Double(\(c1.0)), cp1y: Double(\(c1.1)), cp2x: Double(\(c2.0)), cp2y: Double(\(c2.1)), x: Double(\(to.0)), y: Double(\(to.1)))"
        case "closeSubpath":
            guard call.arguments.isEmpty else { return nil }
            return "IRPathCommand.closeSubpath"
        case "addRect":
            // `addRect(CGRect(x:y:width:height:))` — a single unlabeled CGRect literal.
            guard let r = firstUnlabeledExpr(), let rect = cgRectLiteral(r) else { return nil }
            return "IRPathCommand.addRect(x: Double(\(rect.0)), y: Double(\(rect.1)), width: Double(\(rect.2)), height: Double(\(rect.3)))"
        case "addRoundedRect":
            // `addRoundedRect(in: CGRect(...), cornerSize: CGSize(width:N, height:N))` /
            // `(in:, cornerRadius: N)`.
            guard let rectE = argExpr("in"), let rect = cgRectLiteral(rectE) else { return nil }
            var radius: String? = numLit("cornerRadius")
            if radius == nil, let cs = argExpr("cornerSize")?.as(FunctionCallExprSyntax.self),
               cs.calledExpression.trimmedDescription == "CGSize",
               let w = cs.arguments.first(where: { $0.label?.text == "width" })?.expression.trimmedDescription,
               isNumericLiteral(w) {
                radius = w
            }
            guard let rad = radius else { return nil }
            return "IRPathCommand.addRoundedRect(x: Double(\(rect.0)), y: Double(\(rect.1)), width: Double(\(rect.2)), height: Double(\(rect.3)), cornerRadius: Double(\(rad)))"
        default:
            return nil   // addArc / addEllipse / addPath / etc. → slot the whole Path
        }
    }

    /// A literal `CGRect(x:N, y:N, width:N, height:N)` → its 4 numeric-literal
    /// components, or nil for any non-literal/other-initializer form.
    static func cgRectLiteral(_ expr: ExprSyntax) -> (String, String, String, String)? {
        guard let pc = expr.as(FunctionCallExprSyntax.self),
              pc.calledExpression.trimmedDescription == "CGRect" else { return nil }
        func a(_ l: String) -> String? {
            guard let v = pc.arguments.first(where: { $0.label?.text == l })?.expression.trimmedDescription,
                  isNumericLiteral(v) else { return nil }
            return v
        }
        guard let x = a("x"), let y = a("y"), let w = a("width"), let h = a("height") else { return nil }
        return (x, y, w, h)
    }

    /// The closure's SINGLE explicit parameter name (`{ proxy in … }` → "proxy"),
    /// or nil for the implicit-`$0` form / a multi-param / no-param closure.
    private func singleClosureParamName(_ closure: ClosureExprSyntax) -> String? {
        guard let clause = closure.signature?.parameterClause else { return nil }
        if let typed = clause.as(ClosureParameterClauseSyntax.self) {
            guard typed.parameters.count == 1, let p = typed.parameters.first else { return nil }
            let name = (p.secondName ?? p.firstName).text
            return name.hasPrefix("$") || name == "_" ? nil : name
        }
        if let shorthand = clause.as(ClosureShorthandParameterListSyntax.self) {
            guard shorthand.count == 1, let p = shorthand.first else { return nil }
            let name = p.name.text
            return name.hasPrefix("$") || name == "_" ? nil : name
        }
        return nil
    }

    // MARK: New containers (lazy grids, grid, groupBox, disclosureGroup, viewThatFits, tabView)

    private mutating func emitGrid(_ fn: String, tracksLabel: String,
                                   call: FunctionCallExprSyntax) -> String {
        // `LazyVGrid(columns: [GridItem(...)], spacing: x) { cells }`. The tracks
        // (`columns:`/`rows:`) must be an array literal of `GridItem(...)` we can
        // reduce to `IRGridItem`; a computed tracks expression slots the whole grid.
        guard let tracksArg = call.arguments.first(where: { $0.label?.text == tracksLabel }),
              let arr = tracksArg.expression.as(ArrayExprSyntax.self) else {
            return opaqueExpr(ExprSyntax(call), labelHint: fn == "lazyVGrid" ? "LazyVGrid" : "LazyHGrid")
        }
        var tracks: [String] = []
        for el in arr.elements {
            guard let ir = Self.loweredGridItemOrNil(el.expression.trimmedDescription) else {
                return opaqueExpr(ExprSyntax(call), labelHint: fn == "lazyVGrid" ? "LazyVGrid" : "LazyHGrid")
            }
            tracks.append(ir)
        }
        var spacing = ""
        if let s = call.arguments.first(where: { $0.label?.text == "spacing" }),
           s.expression.trimmedDescription != "nil" {
            // BUG R2-#21: `spacing: nil` (the explicit default) must NOT become
            // `Double(nil)` (uncompilable Swift → the whole guest module fails → NO
            // views ship). `nil` == default spacing, so OMITTING the piece is
            // semantically identical. A non-nil spacing routes through the same numeric
            // host-projection emitStack uses (a design-system constant lowers as a
            // `__numtok_<id>` instead of leaking; literal/input resolves verbatim).
            let raw = s.expression.trimmedDescription
            let resolved = numericOrToken(raw) ?? raw
            spacing = ", spacing: Double(\(resolved))"
        }
        let children = childrenCode(call)
        let tracksLiteral = "[" + tracks.joined(separator: ", ") + "]"
        return "N.\(fn)(\(tracksLabel): \(tracksLiteral)\(spacing), [\n\(children)\n])"
    }

    private mutating func emitGridContainer(call: FunctionCallExprSyntax) -> String {
        var pieces: [String] = []
        if let a = call.arguments.first(where: { $0.label?.text == "alignment" }) {
            // BUG R2-#121: validate Grid's alignment against the IRAlignment allowlist.
            guard let c = Self.loweredAlignmentOrNil(a.expression.trimmedDescription) else {
                return opaqueExpr(ExprSyntax(call), labelHint: "Grid")
            }
            pieces.append("alignment: .\(c)")
        }
        if let hs = call.arguments.first(where: { $0.label?.text == "horizontalSpacing" }) {
            // `nil` is the legitimate default → omit. A non-literal (design-system token)
            // would leak an identifier / `Double(nil)` into the guest → slot the whole grid.
            let raw = hs.expression.trimmedDescription
            if raw != "nil" {
                guard Self.isNumericLiteral(raw) else { return opaqueExpr(ExprSyntax(call), labelHint: "Grid") }
                pieces.append("horizontalSpacing: Double(\(raw))")
            }
        }
        if let vs = call.arguments.first(where: { $0.label?.text == "verticalSpacing" }) {
            let raw = vs.expression.trimmedDescription
            if raw != "nil" {
                guard Self.isNumericLiteral(raw) else { return opaqueExpr(ExprSyntax(call), labelHint: "Grid") }
                pieces.append("verticalSpacing: Double(\(raw))")
            }
        }
        let header = pieces.isEmpty ? "" : pieces.joined(separator: ", ") + ", "
        let children = childrenCode(call)
        return "N.grid(\(header)[\n\(children)\n])"
    }

    private mutating func emitGridRow(call: FunctionCallExprSyntax) -> String {
        var header = ""
        if let a = call.arguments.first(where: { $0.label?.text == "alignment" }) {
            // BUG R2-#122: GridRow takes a VerticalAlignment — validate against the 5
            // IRVerticalAlignment cases (NOT IRAlignment). A custom vertical guide would
            // emit an invalid case → guest compile fail. Slot the GridRow on a miss.
            guard let c = Self.loweredVerticalAlignmentOrNil(a.expression.trimmedDescription) else {
                return opaqueExpr(ExprSyntax(call), labelHint: "GridRow")
            }
            header = "alignment: .\(c), "
        }
        let children = childrenCode(call)
        return "N.gridRow(\(header)[\n\(children)\n])"
    }

    private mutating func emitGroupBox(call: FunctionCallExprSyntax) -> String {
        // `GroupBox { content }`, `GroupBox("Title") { content }`, or
        // `GroupBox { content } label: { label }`.
        var label: [String] = []
        var content: [String] = []
        if let titled = call.arguments.first(where: { $0.label == nil }),
           titled.expression.as(StringLiteralExprSyntax.self) != nil {
            // BUG R2-#65/#66/#67/#119: markdown → styledText; overload → slot.
            guard let node = Self.emitTitleTextLiteral(titled.expression) else {
                return opaqueExpr(ExprSyntax(call), labelHint: "GroupBox")
            }
            label = [node]
        }
        if let trailing = call.trailingClosure {
            content = emitItems(trailing.statements)
        }
        for add in call.additionalTrailingClosures where add.label.text == "label" {
            label = emitItems(add.closure.statements)
        }
        for arg in call.arguments {
            guard let lbl = arg.label?.text, let c = arg.expression.as(ClosureExprSyntax.self) else { continue }
            if lbl == "content" { content = emitItems(c.statements) }
            else if lbl == "label" { label = emitItems(c.statements) }
        }
        let labelPiece = label.isEmpty ? "" : "label: \(nodeList(label)), "
        return "N.groupBox(\(labelPiece)[\n\(content.map { indent($0) }.joined(separator: ",\n"))\n])"
    }

    private mutating func emitDisclosureGroup(call: FunctionCallExprSyntax) -> String {
        // `DisclosureGroup("Title") { content }` / `DisclosureGroup { content } label:
        // { label }` (UNBOUND) OR `DisclosureGroup(isExpanded: $flag) { content }
        // label: { label }` (BOUND — the SDK owns the expand/collapse via the existing
        // Bool-binding bridge: GET = the guest flag, SET dispatches `setBool`). The
        // bound `$flag` must be a marshallable Bool state field (`eventArg`).
        let boundExpand = eventArg(call, "isExpanded")
        // The bound form requires a resolvable Bool binding; a non-`$`-binding (a
        // computed/derived expression) slots safely.
        if call.arguments.contains(where: { $0.label?.text == "isExpanded" }), boundExpand == nil {
            return opaqueExpr(ExprSyntax(call), labelHint: "DisclosureGroup")
        }
        var label: [String] = []
        var content: [String] = []
        if let titled = call.arguments.first(where: { $0.label == nil }),
           titled.expression.as(StringLiteralExprSyntax.self) != nil {
            // BUG R2-#65/#66/#67/#119: markdown → styledText; overload → slot.
            guard let node = Self.emitTitleTextLiteral(titled.expression) else {
                return opaqueExpr(ExprSyntax(call), labelHint: "DisclosureGroup")
            }
            label = [node]
        }
        if let trailing = call.trailingClosure {
            content = emitItems(trailing.statements)
        }
        for add in call.additionalTrailingClosures where add.label.text == "label" {
            label = emitItems(add.closure.statements)
        }
        for arg in call.arguments {
            guard let lbl = arg.label?.text, let c = arg.expression.as(ClosureExprSyntax.self) else { continue }
            if lbl == "content" { content = emitItems(c.statements) }
            else if lbl == "label" { label = emitItems(c.statements) }
        }
        if label.isEmpty {
            return opaqueExpr(ExprSyntax(call), labelHint: "DisclosureGroup")
        }
        let contentList = "[\n\(content.map { indent($0) }.joined(separator: ",\n"))\n]"
        // BOUND form → the host-state `disclosureGroup(label:isExpanded:_:event:)`
        // builder (renders a real bound `DisclosureGroup`; SET dispatches setBool).
        if let b = boundExpand {
            record(event: b.event, field: b.value, op: .setBool)
            return "N.disclosureGroup(label: \(nodeList(label)), isExpanded: \(b.value), \(contentList), event: \"\(b.event)\")"
        }
        return "N.disclosureGroup(label: \(nodeList(label)), \(contentList))"
    }

    private mutating func emitViewThatFits(call: FunctionCallExprSyntax) -> String {
        var axes = "both"
        if let a = call.arguments.first(where: { $0.label?.text == "in" }) {
            let raw = a.expression.trimmedDescription
            if raw.contains("horizontal") && !raw.contains("vertical") { axes = "horizontal" }
            else if raw.contains("vertical") && !raw.contains("horizontal") { axes = "vertical" }
        }
        let children = childrenCode(call)
        return "N.viewThatFits(axes: .\(axes), [\n\(children)\n])"
    }

    private mutating func emitTabView(call: FunctionCallExprSyntax) -> String {
        // UNBOUND TabView only — a `TabView(selection:)` binding is a later
        // host-state task, so it slots.
        if call.arguments.contains(where: { $0.label?.text == "selection" }) {
            return opaqueExpr(ExprSyntax(call), labelHint: "TabView")
        }
        // The PAGED-CAROUSEL form (G4): `TabView { View1(); View2() }` whose children
        // are plain views with NO `.tabItem` (a paged onboarding carousel, almost
        // always followed by `.tabViewStyle(.page)`). Lower each top-level child view
        // to its own tab (empty tabItem, index tag) so the carousel + its page dots
        // ride WASM. A child carrying `.tabItem` is the tab-BAR form — re-modeling each
        // tag/tabItem from arbitrary modifier chains is fragile, so that slots (honest
        // limit; the bound-selection tab-bar form is a later host-state task).
        guard let closure = call.trailingClosure
                ?? call.arguments.first?.expression.as(ClosureExprSyntax.self) else {
            return opaqueExpr(ExprSyntax(call), labelHint: "TabView")
        }
        // Collect the top-level child expressions (skip decls). If ANY child mentions
        // `.tabItem`, this is the tab-bar form → slot the whole TabView.
        var childExprs: [ExprSyntax] = []
        for item in closure.statements {
            if case .expr(let e) = item.item { childExprs.append(e) }
            else if case .stmt(let s) = item.item, let es = s.as(ExpressionStmtSyntax.self) {
                childExprs.append(es.expression)
            } else if case .decl = item.item {
                continue
            } else {
                // a control-flow stmt we don't model at the tab level → slot.
                return opaqueExpr(ExprSyntax(call), labelHint: "TabView")
            }
        }
        guard !childExprs.isEmpty,
              !childExprs.contains(where: { $0.trimmedDescription.contains(".tabItem") }) else {
            return opaqueExpr(ExprSyntax(call), labelHint: "TabView")
        }
        var tabs: [String] = []
        for (i, e) in childExprs.enumerated() {
            let node = emitExpr(e)   // a non-lowerable page becomes an opaque leaf — never a demote
            tabs.append("IRTab(tag: \"\(i)\", tabItem: [], content: [\(node)])")
        }
        return "N.tabView(tabs: [\n\(tabs.map { indent($0) }.joined(separator: ",\n"))\n])"
    }

    /// Render a list of already-lowered node strings as a bracketed `[ ... ]` literal
    /// (a shared helper for the new multi-subtree nodes).
    private func nodeList(_ nodes: [String]) -> String {
        if nodes.isEmpty { return "[]" }
        return "[\n" + nodes.map { indent($0) }.joined(separator: ",\n") + "\n]"
    }

    private mutating func emitSection(call: FunctionCallExprSyntax) -> String {
        // Resolve header / footer / content from the three Section shapes:
        //   Section("Title") { rows }            → header = [N.text("Title")]
        //   Section(header: X) { rows }           → header = lowered X
        //   Section(footer: Y) { rows }           → footer = lowered Y
        //   Section { rows } header: { } footer: {} → multi-trailing-closure
        var header: [String] = []
        var footer: [String] = []

        // A leading string-literal title → a Text header.
        if let titled = call.arguments.first(where: { $0.label == nil }),
           titled.expression.as(StringLiteralExprSyntax.self) != nil {
            // BUG R2-#65/#66/#67/#119: markdown → styledText; interpolation-overload → slot.
            guard let node = Self.emitTitleTextLiteral(titled.expression) else {
                // Lift the title literal so editing it is OTA-stable.
                return opaqueExprLifted(ExprSyntax(call), labelHint: "Section")
            }
            header = [node]
        }
        // `header:` / `footer:` as normal arguments (a single view OR a closure).
        for arg in call.arguments {
            guard let label = arg.label?.text else { continue }
            if label == "header" { header = sectionSlot(arg.expression) }
            else if label == "footer" { footer = sectionSlot(arg.expression) }
        }
        // `header:` / `footer:` as additional trailing closures.
        for add in call.additionalTrailingClosures {
            if add.label.text == "header" { header = emitItems(add.closure.statements) }
            else if add.label.text == "footer" { footer = emitItems(add.closure.statements) }
        }

        // DYNAMIC-DATA `Section(items) { item in row }`: a leading non-string
        // collection arg + a row closure with a parameter. Same unbound-loop-var
        // hazard as ForEach — route through the shared loop-or-demote logic (a real
        // guest loop over a marshalled array becomes one `N.forEach(<loop>)` child,
        // else the whole Section slots natively).
        if let collectionArg = call.arguments.first(where: {
                $0.label == nil && $0.expression.as(StringLiteralExprSyntax.self) == nil }),
           let rowClosure = forEachRowClosure(call) {
            // BUG R2-#1: a `$0`-shorthand data-driven row (no parameterClause) would
            // otherwise fall through and leak a free `$0` into a native slot closure → an
            // app-target compile failure. Treat it (like the named-param form) as the
            // data-driven path: a loopable marshalled array lowers, else the Section slots.
            if rowClosure.signature?.parameterClause == nil
                && !AnonymousParamScanner.scan(rowClosure).usesDollarZero {
                // Not a data-driven row (a static `Section(<view>) { A; B }` shape) — fall
                // through to the static content handling below.
            } else {
            guard let rows = loweredRowLoop(collectionArg: collectionArg, rowClosure: rowClosure) else {
                // Lift any plain string-literal title in e.g. Section("Recent"){ForEach…}
                // so editing "Recent" is OTA-stable even when the data row can't lower.
                return opaqueExprLifted(ExprSyntax(call), labelHint: "Section")
            }
            let headerCode = sectionList(header)
            let footerCode = sectionList(footer)
            var pieces: [String] = []
            if !header.isEmpty { pieces.append("header: \(headerCode)") }
            if !footer.isEmpty { pieces.append("footer: \(footerCode)") }
            let prefix = pieces.isEmpty ? "" : pieces.joined(separator: ", ") + ", "
            return "N.section(\(prefix)[\n\(indent("N.forEach(\(rows))"))\n])"
            }
        }

        // Content = the main (leading) trailing closure when header/footer are
        // multi-trailing-closures; otherwise the sole trailing/closure arg.
        var content: [String] = []
        if let trailing = call.trailingClosure {
            content = emitItems(trailing.statements)
        } else {
            for arg in call.arguments where arg.label == nil {
                if let closure = arg.expression.as(ClosureExprSyntax.self) {
                    content = emitItems(closure.statements)
                }
            }
        }

        let headerCode = sectionList(header)
        let footerCode = sectionList(footer)
        let contentCode = content.map { indent($0) }.joined(separator: ",\n")
        var pieces: [String] = []
        if !header.isEmpty { pieces.append("header: \(headerCode)") }
        if !footer.isEmpty { pieces.append("footer: \(footerCode)") }
        let prefix = pieces.isEmpty ? "" : pieces.joined(separator: ", ") + ", "
        return "N.section(\(prefix)[\n\(contentCode)\n])"
    }

    /// A Section `header:`/`footer:` argument: a `{ … }` view-builder closure OR
    /// a single inline view expression. Returns the lowered child node strings.
    private mutating func sectionSlot(_ expr: ExprSyntax) -> [String] {
        if let closure = expr.as(ClosureExprSyntax.self) {
            return emitItems(closure.statements)
        }
        return [emitExpr(expr)]
    }

    /// Render a list of already-lowered node strings as an `[ ... ]` literal.
    private func sectionList(_ nodes: [String]) -> String {
        if nodes.isEmpty { return "[]" }
        return "[\n" + nodes.map { indent($0) }.joined(separator: ",\n") + "\n]"
    }

    private mutating func emitButton(call: FunctionCallExprSyntax) -> String {
        // Derive a stable action id from the source slice (DETERMINISTIC — see
        // `stableEventHash`; `String.hashValue` is per-process-seeded and would churn
        // the emitted ids every build).
        let actionID = "act\(Self.stableEventHash(call.trimmedDescription))"
        // The action closure is the UPDATE half: parse it for a single recognizable
        // `@State` mutation and record a rule keyed by this button's action id.
        let actionClosure = buttonActionClosure(call)
        let recorded = recordActionMutation(actionClosure, event: actionID)
        // CRITICAL CORRECTNESS GATE (the dead-button fix): an `N.button(actionID:)` renders
        // from WASM, but tapping dispatches the recorded RULE. If the action is REAL
        // (non-empty) but NOT a recordable rule — a COMPLEX action (`Task { await … }`, an
        // `@Observable`/method call, a multi-statement body) — the button would RENDER but do
        // NOTHING on device (a dead control), because there's no native button left to tap once
        // the view auto-routes. So when the action is undispatchable we DON'T emit a bare
        // `N.button`:
        //   * In a MODIFIER-ACTION LIST context (alert/confirmationDialog/toolbar/Menu/
        //     contextMenu) the renderer can't attach a native slot to an actions-list entry —
        //     SwiftUI's actions ViewBuilder won't reach a Button behind the renderer's
        //     ForEach/AnyView — so we flag `hasUndispatchableAction`; the WHOLE view DEMOTES to
        //     native (fully functional) via the BuildPipeline thunkSafe gate.
        //   * In a plain BODY/container context we SLOT the whole Button natively
        //     (`opaqueExpr`): the real button + real action render via the thunk's
        //     `__patchSlots()` self-context, the rest of the view still lowers. A non-slotable
        //     button (action/label reads a body-local) makes the view demote via the existing
        //     `opaqueLeaves.allSatisfy { $0.slotable }` gate.
        // An EMPTY action (`Button("X") {}`) is a valid no-op — it lowers as a plain wired
        // button with no rule (unchanged). A RECORDED action is unchanged (it dispatches).
        // A FUNCTION-REFERENCE action (`Button(_, action: submit)`) is ALSO undispatchable (no
        // closure body to record a rule from) → treat it like a non-empty undispatchable action.
        let undispatchable = !recorded
            && (!Self.actionClosureIsEmpty(actionClosure) || buttonHasFunctionRefAction(call))
        // ACTIONS-LIST NATIVE-ACTION SLOT: a Button in an actions-list builder
        // (`.swipeActions`/`.toolbar`/`.alert`/`Menu`/`.contextMenu`) whose action is a native
        // method call (`deleteSubscription(s)`, `resetAllData()`). Previously this UNCONDITIONALLY
        // demoted the whole view (`hasUndispatchableAction`). Now, when the action closure is
        // SLOTABLE (references no body-local / no inaccessible member — the SAME `isSlotable`
        // check the opaque-leaf path uses), we lower the LABEL + role and supply the ACTION as a
        // NATIVE SLOT closure (`__patchActionSlots()[id] = { <body> }`, closing over `self`), so
        // the view auto-routes AND the real native call runs faithfully on tap. If the action is
        // NOT slotable (a private/body-local read the cross-file thunk can't reach), we KEEP the
        // `hasUndispatchableAction` demote — never strip a body we can't fill (which would ship a
        // patch that silently renders the OLD native view with the dev's edit missing — FORBIDDEN).
        var emitAsActionSlot = false
        if undispatchable {
            if inActionListContext {
                if let slotID = tryRecordActionSlot(call, actionClosure: actionClosure, id: actionID) {
                    // Slotted — the label/role lower below; the node is an `actionSlotButton`.
                    emitAsActionSlot = true
                    _ = slotID
                } else {
                    hasUndispatchableAction = true
                    // The view will demote, so what we emit here is moot — keep the node for shape.
                }
            } else {
                // SLOT the whole Button natively (real button + real action via the self-only
                // slot closure). The whole `Button(…) { … }` call is the slot source.
                // Lift any plain string-literal title from the slot so editing the title
                // is OTA-patchable + fingerprint-stable.
                return opaqueExprLifted(ExprSyntax(call), labelHint: "Button")
            }
        }
        // `Button(role: .destructive/.cancel)` → carry the role (needed by alert /
        // confirmationDialog / context-menu actions). An unrecognized role slots-safe
        // to nil (a non-destructive/-cancel role is just a default button).
        let rolePiece = buttonRolePiece(call)
        // The node constructor: a SLOTTED actions-list Button emits `N.actionSlotButton(id:…)`
        // (its action comes from the thunk's native `__patchActionSlots()` closure); everything
        // else emits the ordinary `N.button(actionID:…)` (guest-dispatched / inert).
        func emitButtonNode(label: String) -> String {
            if emitAsActionSlot {
                return "N.actionSlotButton(id: \"\(actionID)\"\(rolePiece), label: [\n\(label)\n])"
            }
            return "N.button(actionID: \"\(actionID)\"\(rolePiece), label: [\n\(label)\n])"
        }
        // Button("title"[, role:]) { action }  OR  Button(role:?, action:){ label }
        if let titleArg = call.arguments.first(where: { $0.label == nil }),
           titleArg.expression.as(StringLiteralExprSyntax.self) != nil {
            // BUG R2-#65/#66/#67/#119: route the title through the shared LocalizedStringKey
            // handling — markdown → styledText, a SwiftUI-only interpolation overload → slot.
            guard let titleNode = Self.emitTitleTextLiteral(titleArg.expression) else {
                // Markdown title on a lowerable button — lift the literal so editing
                // "**Sign In**" is OTA-stable.
                return opaqueExprLifted(ExprSyntax(call), labelHint: "Button")
            }
            return emitButtonNode(label: indent(titleNode))
        }
        // label builder is the trailing closure (or `label:`). Lower ONLY the LABEL
        // content — NOT the `action:` closure. `childrenCode` would otherwise lower the
        // action closure's statements as child nodes too, turning a Void action body
        // (`{ if … { action() } }`) into an `AnyView(action())` leaf — `'()' cannot conform
        // to 'View'`. The action is the behavior half (handled by `recordActionMutation`);
        // only the visible label is content.
        let label = buttonLabelCode(call)
        return emitButtonNode(label: label)
    }

    /// Try to record a NATIVE-ACTION SLOT for an undispatchable actions-list Button. Returns the
    /// slot id (== the Button's `actionID`) when the action closure is SLOTABLE — it references no
    /// body-local and no inaccessible (`private`/`fileprivate`) member, so the cross-file thunk's
    /// `{ <body> }` closure (over `self`) is guaranteed to compile and run the real native call.
    /// Returns nil when the action ISN'T slotable (a function-ref with no closure body, an empty
    /// closure, or a body reading a body-local / inaccessible member) — the caller then keeps the
    /// `hasUndispatchableAction` demote, NEVER stripping a body it can't fill. The slot SOURCE (the
    /// closure's inner statements, verbatim) is folded into the native-shell fingerprint, so editing
    /// the native action churns the hash while editing the Button label (which rides WASM) does not.
    private mutating func tryRecordActionSlot(_ call: FunctionCallExprSyntax,
                                              actionClosure: ClosureExprSyntax?,
                                              id: String) -> String? {
        // A function/method REFERENCE action (`Button("Connect", action: submit)`) has no closure
        // body to re-emit, but a BARE 0-arg method ref naming a thunk-REACHABLE method CAN be
        // slotted: the thunk supplies the native closure `{ self.<name>() }`, which compiles iff
        // `<name>` is one of the view's OWN methods (in `selfMemberNames`), is NOT inaccessible in
        // separate-file mode (`inaccessibleNames` — same-file thunk clears that set), and isn't
        // shadowed by a blocking body-local. A non-resolvable / member-chain / private (separate-
        // file) method ref stays a demote (conservative = faithful — never an unfillable slot).
        if actionClosure == nil {
            guard let methodName = buttonMethodRefName(call) else { return nil }
            // REACHABILITY (the demote-safety invariant): `self.<name>()` compiles in the thunk
            // ONLY when `<name>` is a real method of THIS view AND reachable from the thunk's file.
            guard selfMemberNames.contains(methodName),          // it's one of the view's members
                  !inaccessibleNames.contains(methodName),       // separate-file thunk can reach it
                  !bodyLocals.contains(methodName)                // no body-local shadow
            else { return nil }
            let methodCall = "self.\(methodName)()"
            if !actionSlots.contains(where: { $0.id == id }) {
                actionSlots.append(.init(id: id, source: methodCall, label: "Button"))
            }
            return id
        }
        // Only a real closure BODY can be slotted faithfully otherwise — fall through below.
        guard let closure = actionClosure else { return nil }
        // An empty action (`{}`) is a no-op — nothing to slot; the dispatch path handles it.
        guard !Self.actionClosureIsEmpty(closure) else { return nil }
        // The action closure's BODY statements, verbatim — what the thunk runs over `self`.
        let bodySource = closure.statements.trimmedDescription
        guard !bodySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // SLOTABILITY (the demote-safety invariant): the slot closure `{ <body> }` runs in the
        // cross-file thunk over `self`. It compiles ONLY if the body references no body-local
        // (out of scope there) and no inaccessible `private`/`fileprivate` member (Swift access
        // control is file-scoped). This is the SAME `isSlotable` gate the opaque-leaf slot path
        // uses. The closure's OWN parameters/bindings are subtracted inside `isSlotable`.
        let blocked = bodyLocals.union(inaccessibleNames)
        guard Self.isSlotable(ExprSyntax(closure), blocked: blocked) else { return nil }
        // Record it (idempotent by id — a structurally-identical sibling reuses the slot).
        if !actionSlots.contains(where: { $0.id == id }) {
            actionSlots.append(.init(id: id, source: bodySource, label: "Button"))
        }
        return id
    }

    /// Try to record a CALLBACK SLOT from a child-view call expression with a `() -> Void`
    /// closure argument. Returns the position-keyed `id` on success, nil on failure (caller
    /// falls back to opaqueCall for the whole expression — demote-safe).
    ///
    /// GATES (all must pass):
    ///   1. The closure body must be NON-EMPTY and slotable (no body-local capture, no
    ///      inaccessible private member — same `isSlotable` gate as opaque-leaf slots).
    ///   2. The REST of the call expression (callee + all non-closure args) must be slotable
    ///      so the thunk can supply the full child-view rendering natively.
    ///
    /// SOUND for OTA callback-body edits (NOT for removing native calls from the closure):
    ///   • Editing a dispatchable op (`showPaywall = true` → `showPaywall = true; tracker()`)
    ///     where `tracker()` is ALSO dispatchable → OTA (WASM dispatch body changes, slot source
    ///     unchanged, fingerprint stable).
    ///   • Removing an op that's ALREADY in the thunk's guest WASM body → OTA (the WASM body
    ///     shrinks; the slot source is unchanged; the thunk's forwarding closure is unaffected).
    ///   • Editing to add a non-bridgeable call (e.g. `SuperwallPresenter.present(...)`) →
    ///     the engine at NEXT prepare/build demotes the closure (no longer dispatchable) →
    ///     MISMATCH on the WASM body hash → clean error, never silent.
    ///
    /// VERDICT on "remove native call from closure" (the user's Superwall case):
    ///   The `slotSource` (child-view call with stable forwarding closure) is UNCHANGED whether
    ///   or not the callback body contains the Superwall call — so the nativeSurface's `CB:` hash
    ///   entry for this slot is STABLE across that edit. The WASM dispatch body DOES change (the
    ///   Superwall line is removed from the guest body), which means the `bodyHash` in the guest
    ///   manifest changes → the SDK routes WASM (correct: the patch IS different). The resulting
    ///   WASM simply doesn't dispatch the Superwall event (the signed thunk's forwarding closure
    ///   still exists, but the WASM body doesn't call `dispatch_callback` for that path). This
    ///   is SOUND: the device's thunk has the Superwall slot available but the WASM body doesn't
    ///   invoke it → the Superwall call is cleanly suppressed OTA. No uncovered slot (the coverage
    ///   check only fires when the THUNK is MISSING a slot the WASM NEEDS — here the WASM doesn't
    ///   need it). This IS the OTA-now verdict for the remove-native-call case.
    ///
    ///   IMPORTANT CAVEAT: this only applies when the removed call is IN the closure arg itself.
    ///   If the removed call is in a DIFFERENT part of the native slot (the child-view call's own
    ///   non-closure args), that changes `slotSource` → changes `CB:` → MISMATCH (correct).
    private mutating func tryRecordCallbackSlot(
        _ call: FunctionCallExprSyntax,
        closureArg: ClosureExprSyntax,
        closureArgLabel: String
    ) -> String? {
        // Closure body must be non-empty and slotable (no body-local/inaccessible capture).
        let bodySource = closureArg.statements.trimmedDescription
        guard !bodySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let blocked = bodyLocals.union(inaccessibleNames)
        guard Self.isSlotable(ExprSyntax(closureArg), blocked: blocked) else { return nil }

        // Build a MODIFIED call expression with the closure arg replaced by a stable forwarding
        // closure so the slot source is stable across callback-body edits.
        // The id is derived from the CALL DESCRIPTION (callee + arg label, minus closure body)
        // which is position-keyed — stable across body edits.
        let callDescription = call.calledExpression.trimmedDescription + "/" + closureArgLabel
        let baseId = "cb_" + Self.stableEventHash(callDescription)
        // COLLISION FIX (P1): `callDescription` excludes the closure body (so a body edit is
        // OTA-stable) AND the non-closure args, so the SAME child view + same callback label at
        // two positions (e.g. `Card(onContinue: { showA = true })` in an `if` arm and
        // `Card(onContinue: { showB = true })` in the `else` arm) collide on one `baseId`. The
        // old idempotency guard then SILENTLY DROPPED the 2nd occurrence's mutation rule and made
        // both render via the 1st's factory → tapping the 2nd dispatched the WRONG @State (P1
        // wrong-dispatch). Disambiguate each occurrence with a per-baseId index. INERTNESS: the
        // FIRST occurrence keeps the bare `baseId`, so any view with a single such callback (the
        // overwhelming common case) is byte-identical to before this fix — no fingerprint churn;
        // only an actual collision gets a `#N` suffix. The index is body-edit-stable (a body edit
        // changes neither the count nor the order of recorded callbacks).
        let collisionCount = callbackSlots.filter {
            $0.id == baseId || $0.id.hasPrefix(baseId + "#")
        }.count
        let id = collisionCount == 0 ? baseId : "\(baseId)#\(collisionCount)"

        // The slot source is the entire call with the closure replaced by the forwarder.
        // We use the SOURCE of the call up to the closure arg, then inject the stable forwarder.
        // For simplicity, reconstruct from the call's non-closure args + the forwarder.
        var argParts: [String] = []
        for arg in call.arguments {
            // Replace the matching labeled closure arg with the stable forwarding closure; keep all others.
            // `closureArgLabel` is always a non-empty label text (e.g. "onContinue") — trailing closures
            // are excluded by `findAndRecordCallbackSlot` and never reach here.
            let argLabel = arg.label?.text ?? ""
            if arg.expression.as(ClosureExprSyntax.self) != nil && argLabel == closureArgLabel {
                let labelPrefix = arg.label.map { "\($0.text): " } ?? ""
                argParts.append("\(labelPrefix){ self.__patchDispatchCallback(\"\(id)\") }")
            } else {
                argParts.append(arg.trimmedDescription)
            }
        }
        let callee = call.calledExpression.trimmedDescription
        let slotSource = "\(callee)(\(argParts.joined(separator: ", ")))"

        // SOUNDNESS GATE + EMIT WIRING (the fix that closes the dead-callback hole the
        // soundness review found): the callback body must be fully DISPATCHABLE — expressible
        // as a guest mutation rule — not merely `isSlotable`. `recordActionMutation` records the
        // body's mutation rule keyed by THIS callback `id` (so the guest's `dispatch(event: id)`
        // applies it at runtime) and returns true; if the body is NOT dispatchable (e.g. a native
        // `Superwall.shared.register(...)` call), it records NOTHING and returns false → we fall
        // back (return nil) so the whole call stays a native `opaqueCall` (editing it → MISMATCH,
        // which is CORRECT: a native call cannot be OTA-dispatched in WASM). Without this gate a
        // slotable-but-undispatchable body would create a callback slot whose guest `dispatch` has
        // no rule for `id` → a DEAD callback on-device (the forwarder fires, nothing happens). The
        // gate runs inside the idempotency guard so the rule is recorded exactly once, with the slot.
        if !callbackSlots.contains(where: { $0.id == id }) {
            guard recordActionMutation(closureArg, event: id) else { return nil }
            callbackSlots.append(.init(id: id, slotSource: slotSource,
                                       callbackBody: bodySource, label: callee))
        }
        return id
    }

    /// The FIDELITY-SAFE effect modifiers we can keep NATIVE (a `nativeEffectSlot`) while lowering
    /// the rest of the view: they fire on lifecycle / user input and do NOT watch GUEST-OWNED state.
    ///
    /// `.onChange(of:)` and `.onReceive(_:)` are HERE NOW (added in the onChange-coverage pass), but
    /// with a STRICTER caller-side gate than the lifecycle effects:
    ///   * `.onReceive(publisher)` fires on a NATIVE publisher event (the publisher is a member the
    ///     thunk reads off `self`); its closure runs natively over `self`, exactly like `.task`. No
    ///     watched VALUE, so no extra gate beyond `tryRecordEffectSlot`'s reachability check.
    ///   * `.onChange(of: X)` is slotted ONLY when the watched value `X` is NATIVE SOURCE-OF-TRUTH —
    ///     i.e. the GUEST BODY does not mutate it (no recorded dispatch rule writes that field). Then
    ///     the real `.onChange(of: self.X) { … }` applied over the rendered subtree fires on the real
    ///     change of the live `self.X`, identical to native. A GUEST-OWNED watched value (the guest
    ///     body mutates `X` via dispatch) is NOT slotted here — it keeps the `hasUndispatchableEffect`
    ///     demote (faithful firing would need a renderer value-watcher; conservative = correct). That
    ///     watched-field check lives in the `case "onChange"` site (where the mutation info exists),
    ///     NOT in `tryRecordEffectSlot`.
    static let nativeEffectSlotModifiers: Set<String> = [
        "task", "onAppear", "onDisappear", "refreshable", "onSubmit",
        "onTapGesture", "gesture", "onLongPressGesture",
        "onReceive", "onChange",
    ]

    /// Try to record a NATIVE EFFECT-MODIFIER SLOT for an undispatchable effect modifier. Returns the
    /// `content.<mod>(...)` re-application source (verbatim, with the modifier's receiver replaced by
    /// a `content` placeholder) when the effect is SLOTTABLE — it is in the fidelity-safe allowlist,
    /// drives no `withAnimation`/`.animation` through the guest-render boundary, and references no
    /// body-local / no inaccessible (`private`/`fileprivate`) member, so the cross-file thunk's
    /// `{ content in AnyView(content.<mod>(...)) }` closure (over `self`) is guaranteed to compile and
    /// run the real native effect. Returns nil when the effect ISN'T slottable — the caller then keeps
    /// the `hasUndispatchableEffect` demote, NEVER stripping a body whose effect it can't supply (which
    /// would silently re-show the OLD native view). The slot SOURCE is folded into the native-shell
    /// fingerprint, so editing the native effect churns the hash while editing the lowered body text
    /// (which rides WASM) does not.
    /// Try to record a NATIVE EFFECT-MODIFIER SLOT. The id is derived INTERNALLY from the
    /// RECEIVER-INDEPENDENT `applySource` (`content.<mod>(...)`), NOT from the caller's
    /// `call.trimmedDescription` (which includes the whole modified subtree) — otherwise editing
    /// any text inside the modified subtree would churn the id → churn `nativeSurface` → a benign
    /// OTA body edit would falsely trip the fingerprint MISMATCH. The id is stable across body-
    /// content edits and changes only when the EFFECT EXPRESSION changes (the correct churn).
    private mutating func tryRecordEffectSlot(_ call: FunctionCallExprSyntax,
                                              name: String) -> String? {
        // FIDELITY GATE 1: only the lifecycle/user-input effects (not state-watchers) are safe.
        guard Self.nativeEffectSlotModifiers.contains(name) else { return nil }
        // The receiver `<base>.<mod>(...)` — we need to re-root the application on `content`.
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.base != nil else { return nil }
        // FIDELITY GATE 2: an effect closure that drives animation THROUGH the guest-render
        // boundary is unproven — `withAnimation { … }` in the effect's closure, or a `.animation(...)`
        // chained INSIDE the effect's own arguments/closure. Demote conservatively (a wrong-rendering
        // view is never worth shipping). Scan ONLY the effect modifier's OWN arguments + trailing
        // closures — NOT the receiver `base` (`member.base`): the base is the WASM-lowered subtree
        // re-rooted on `content`, so an INNER sibling modifier in the chain (e.g. a
        // `Group{…}.animation(value: flow).onChange(of:)` where `.animation` is on the base) is
        // handled by its OWN modifier case and must not falsely reject this effect's slot. (Scanning
        // `call.trimmedDescription` would include the whole receiver chain and over-reject — the
        // ContentView/HomeScreen miss this fixes.)
        func drivesAnimation(_ syntax: Syntax) -> Bool {
            let t = syntax.trimmedDescription
            return t.contains("withAnimation") || t.contains(".animation(")
        }
        for arg in call.arguments where drivesAnimation(Syntax(arg.expression)) { return nil }
        if let trailing = call.trailingClosure, drivesAnimation(Syntax(trailing)) { return nil }
        for extra in call.additionalTrailingClosures where drivesAnimation(Syntax(extra.closure)) {
            return nil
        }
        // SLOTTABILITY (the demote-safety invariant): the re-application `content.<mod>(...)` runs in
        // the cross-file thunk over `self`. It compiles ONLY if every symbol it reads is reachable
        // there — no body-local (out of scope there) and no inaccessible `private`/`fileprivate`
        // member (Swift access control is file-scoped). This is the SAME `isSlotable` gate the
        // opaque-leaf / action-slot paths use; the modifier's OWN closure params/bindings are
        // subtracted inside `isSlotable`. We check the modifier's ARGUMENTS + trailing closures
        // (the receiver `content` is synthetic and always reachable).
        let blocked = bodyLocals.union(inaccessibleNames)
        for arg in call.arguments {
            if !Self.isSlotable(arg.expression, blocked: blocked) { return nil }
        }
        if let trailing = call.trailingClosure,
           !Self.isSlotable(ExprSyntax(trailing), blocked: blocked) { return nil }
        for extra in call.additionalTrailingClosures {
            if !Self.isSlotable(ExprSyntax(extra.closure), blocked: blocked) { return nil }
        }
        // Reconstruct the application source over a `content` placeholder by replacing ONLY the
        // modifier's OWN receiver (`member.base`) with a `content` reference — never a nested member
        // access inside the args/closure (those keep their real receivers). We rebuild the call with
        // the `calledExpression`'s base swapped, keeping the args + trailing closures verbatim (no
        // string surgery on `$0`/closure bodies — SwiftSyntax preserves them exactly).
        let contentRef = ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier("content")))
        // Replace the receiver with `content` AND strip the leading trivia on the `.` period so a
        // modifier written on a NEW LINE (`VStack { … }\n.task { … }`) doesn't re-root to
        // `content\n.task` (which would fail the `content.` prefix check). The whole application is
        // emitted inline in `AnyView(<applySource>)`, so any interior newline is cosmetic anyway.
        let newMember = member
            .with(\.base, contentRef)
            .with(\.period, member.period.with(\.leadingTrivia, []))
        let newCall = call.with(\.calledExpression, ExprSyntax(newMember))
        let applySource = newCall.trimmedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // Defensive: the re-rooted source must actually mention `content` (the rewrite hit the
        // receiver) — else fall back to a demote rather than emit an unrooted application.
        guard applySource.hasPrefix("content.") else { return nil }
        // CONTENT-STABLE id from the RECEIVER-INDEPENDENT applySource (NOT the call slice, which
        // includes the modified subtree). The `e<name-prefix>` keeps ids readable + distinct per
        // modifier kind; the hash is over `applySource` so it churns ONLY when the effect
        // expression changes (a body-content edit inside the modified subtree leaves it stable).
        let id = "eff\(Self.stableEventHash(applySource))"
        // Record it (idempotent by id — a structurally-identical sibling reuses the slot).
        if !effectSlots.contains(where: { $0.id == id }) {
            effectSlots.append(.init(id: id, applySource: applySource, label: name))
        }
        return id
    }

    /// Lower ONLY a Button's LABEL content to child nodes — never its `action:` closure
    /// (the behavior half). For `Button(action: { … }) { label }` the label is the trailing
    /// closure; for `Button { action } label: { label }` it's the `label:` trailing closure.
    /// A plain `Button("Title") { action }` was already handled by the string-title path, so
    /// here the trailing closure is the LABEL unless an explicit `label:` closure exists.
    private mutating func buttonLabelCode(_ call: FunctionCallExprSyntax) -> String {
        var nodes: [String] = []
        // `Button { action } label: { label }` — the label is the `label:` trailing closure.
        if let labelClosure = call.additionalTrailingClosures.first(where: { $0.label.text == "label" }) {
            nodes.append(contentsOf: emitItems(labelClosure.closure.statements))
            return nodes.map { indent($0) }.joined(separator: ",\n")
        }
        // Otherwise the trailing closure is the LABEL (`Button(action:) { label }`), and the
        // `action:` ARGUMENT closure is the behavior — emit only the trailing label closure.
        if let trailing = call.trailingClosure {
            nodes.append(contentsOf: emitItems(trailing.statements))
        }
        // A `label:` passed as a labeled ARGUMENT closure (not trailing) is also content.
        for arg in call.arguments where arg.label?.text == "label" {
            if let closure = arg.expression.as(ClosureExprSyntax.self) {
                nodes.append(contentsOf: emitItems(closure.statements))
            }
        }
        return nodes.map { indent($0) }.joined(separator: ",\n")
    }

    /// `, role: .destructive` / `, role: .cancel` for a `Button(role:)`, else "".
    private func buttonRolePiece(_ call: FunctionCallExprSyntax) -> String {
        guard let roleArg = call.arguments.first(where: { $0.label?.text == "role" }),
              let c = Self.bareEnumCase(roleArg.expression.trimmedDescription),
              c == "destructive" || c == "cancel" else { return "" }
        return ", role: .\(c)"
    }

    /// True iff a Button carries a REAL action that is NOT a (parsed) closure — a
    /// FUNCTION/METHOD REFERENCE passed as `action:` (`Button("Connect", action: submit)`).
    /// Such an action can NEVER be a recordable dispatch rule (there's no closure body to
    /// parse), so it would render but do nothing on device — a dead button. The caller treats
    /// it exactly like a non-empty-but-undispatchable closure (slot in body context / demote in
    /// an actions list). An `action: { }` (a closure) is handled by `buttonActionClosure` +
    /// `actionClosureIsEmpty` instead; a `Button` with NO `action:` arg and no action closure
    /// (e.g. a `Button(role:){ label }` inside an alert, action implied) returns false.
    private func buttonHasFunctionRefAction(_ call: FunctionCallExprSyntax) -> Bool {
        for arg in call.arguments where arg.label?.text == "action" {
            // A closure action is handled elsewhere; a NON-closure expression here is a
            // function/method reference (or a key-path/`self.foo` selector) → undispatchable.
            if arg.expression.as(ClosureExprSyntax.self) == nil { return true }
        }
        return false
    }

    /// Extract a Button's BARE METHOD-REFERENCE action — the `action:` arg (or a string-titled
    /// Button's trailing positional non-closure) when it is a bare identifier (`submit`) or a
    /// `self.`-qualified member (`self.submit`) naming a 0-arg method we can invoke over `self`.
    /// Returns the method NAME (`submit`) so the caller can synthesize the slot source
    /// `self.<name>()`. Returns nil for a closure (handled elsewhere), a member CHAIN
    /// (`vm.load` — the receiver may be private/body-local, harder to prove reachable), a
    /// key-path, or anything that isn't a single bare/`self.`-qualified identifier. Conservative:
    /// only the provable bare-method-ref shape returns a name; everything else stays a demote.
    private func buttonMethodRefName(_ call: FunctionCallExprSyntax) -> String? {
        // The action-bearing expression: an explicit `action:` arg, else (for a string-titled
        // Button with no closure) a trailing UNLABELED non-closure positional argument.
        var actionExpr: ExprSyntax?
        for arg in call.arguments where arg.label?.text == "action" {
            actionExpr = arg.expression
        }
        if actionExpr == nil {
            // `Button("Title", submit)` — the title is the FIRST unlabeled arg; a SECOND
            // unlabeled non-closure trailing arg is the positional action ref.
            let unlabeled = call.arguments.filter { $0.label == nil }
            if unlabeled.count >= 2,
               unlabeled.first?.expression.as(StringLiteralExprSyntax.self) != nil,
               let last = unlabeled.last {
                actionExpr = last.expression
            }
        }
        guard let expr = actionExpr else { return nil }
        // A closure action is dispatched/slotted via the closure path — not here.
        if expr.is(ClosureExprSyntax.self) { return nil }
        // A bare identifier: `submit`.
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text
        }
        // A `self.`-qualified member: `self.submit` (base is `self`, single hop).
        if let member = expr.as(MemberAccessExprSyntax.self),
           let base = member.base?.as(DeclReferenceExprSyntax.self),
           base.baseName.tokenKind == .keyword(.self) {
            return member.declName.baseName.text
        }
        return nil
    }

    /// True iff a BEHAVIORAL/LIFECYCLE modifier carries its action as a FUNCTION/METHOD
    /// REFERENCE rather than a closure — `.onSubmit(connect)`, `.onAppear(perform: load)`,
    /// `.onTapGesture(perform: handler)`, `.onChange(of:_, fn)`. There's no closure body to
    /// record a dispatch rule from, so the renderer would fire the event but match NO guest
    /// rule → a DEAD effect. The caller flags `hasUndispatchableEffect` (the view demotes so
    /// the real native modifier runs). We look at the action-bearing argument(s): the
    /// `perform:` label, OR a trailing-position UNLABELED argument that is NOT a closure and
    /// NOT a value literal (so it's a function reference / member selector). A `value:`/`of:`/
    /// `id:`/`minimumDuration:` etc. data argument is excluded (only the action arg counts).
    private func modifierHasFunctionRefAction(_ call: FunctionCallExprSyntax) -> Bool {
        // An explicit `perform:` function-ref (no closure body).
        for arg in call.arguments where arg.label?.text == "perform" {
            if arg.expression.as(ClosureExprSyntax.self) == nil { return true }
        }
        // A trailing UNLABELED non-closure expression is the action passed positionally
        // (`.onSubmit(connect)` / `.onChange(of: x, fn)`). A unlabeled DATA argument (an
        // `.onTapGesture(count: 2)` has a LABEL; `.onLongPressGesture(minimumDuration:)` is
        // labeled too), so an unlabeled non-closure trailing arg is the action ref.
        if let last = call.arguments.last(where: { $0.label == nil }) {
            let e = last.expression
            if e.as(ClosureExprSyntax.self) == nil
                && e.as(IntegerLiteralExprSyntax.self) == nil
                && e.as(FloatLiteralExprSyntax.self) == nil
                && e.as(BooleanLiteralExprSyntax.self) == nil
                && e.as(StringLiteralExprSyntax.self) == nil {
                // A bare identifier / member access (`connect` / `vm.load`) = a function ref.
                if e.is(DeclReferenceExprSyntax.self) || e.is(MemberAccessExprSyntax.self) {
                    return true
                }
            }
        }
        return false
    }

    /// Find a Button's ACTION closure (the behavior half), not its label content:
    ///   * `Button("Title") { action }`           → the sole trailing closure
    ///   * `Button(action: { … }) { label }`       → the `action:` argument closure
    ///   * `Button { action } label: { … }`        → the leading trailing closure
    private func buttonActionClosure(_ call: FunctionCallExprSyntax) -> ClosureExprSyntax? {
        // Explicit `action:` argument closure.
        for arg in call.arguments where arg.label?.text == "action" {
            if let c = arg.expression.as(ClosureExprSyntax.self) { return c }
        }
        let firstUnlabeled = call.arguments.first { $0.label == nil }
        let titled = firstUnlabeled?.expression.as(StringLiteralExprSyntax.self) != nil
        // `Button("Title") { action }`: the sole trailing closure is the action.
        if titled { return call.trailingClosure }
        // `Button { action } label: { label }`: leading trailing closure is action.
        if call.additionalTrailingClosures.contains(where: { $0.label.text == "label" }) {
            return call.trailingClosure
        }
        // CLOSURE-PROP SLOT fix: `Button(anyExpr) { action }` where the first arg is an
        // IDENTIFIER or other non-literal expression (e.g. `Button(title) { onTap() }` where
        // `title` is a String input). This is the `Button(_ title:, action:)` form — the
        // first unlabeled arg is the title expression and the sole trailing closure is the
        // action. Without this, `buttonActionClosure` returns nil (only string literals were
        // recognized), causing `undispatchable = false` → the closure body is wrongly emitted
        // as label content (a Void call in view position → `AnyView(onTap())` = type error).
        // CONSERVATIVE: requires exactly one unlabeled arg + one trailing closure + NO
        // additional trailing closures (the unambiguous title+action form).
        if let firstUnlabeled, call.trailingClosure != nil,
           call.additionalTrailingClosures.isEmpty,
           // The first unlabeled arg must be an IDENTIFIER or interpolated string — NOT itself
           // a closure (which would indicate the action-label form `Button { action }{ label }`).
           !firstUnlabeled.expression.is(ClosureExprSyntax.self) {
            return call.trailingClosure
        }
        return nil
    }

    /// Extract the action closure from a `.gesture(TapGesture().onEnded { … })` /
    /// `.gesture(TapGesture(count: 2).onEnded { … })` (also `.onChanged`) expression — the
    /// FIRST unlabeled argument of the `.gesture(...)` call. Walks the gesture's modifier
    /// chain for an `.onEnded`/`.onChanged` whose argument is a closure. Returns nil if no
    /// such closure is found (then the caller treats it as empty = a no-op tap). A function-ref
    /// `.onEnded(handler)` returns nil → the emptiness check keeps it from a false-record; the
    /// caller still flags it undispatchable only if the closure is non-empty (so a function-ref
    /// here stays conservative — it won't falsely record a rule).
    private static func gestureActionClosure(_ call: FunctionCallExprSyntax) -> ClosureExprSyntax? {
        guard let gestureExpr = call.arguments.first(where: { $0.label == nil })?.expression else {
            return nil
        }
        // Walk the `.onEnded`/`.onChanged` member-call chain.
        var cur: ExprSyntax? = gestureExpr
        while let e = cur {
            if let fc = e.as(FunctionCallExprSyntax.self),
               let member = fc.calledExpression.as(MemberAccessExprSyntax.self) {
                let name = member.declName.baseName.text
                if name == "onEnded" || name == "onChanged" {
                    if let c = fc.trailingClosure { return c }
                    if let c = fc.arguments.first(where: { $0.expression.is(ClosureExprSyntax.self) })?
                        .expression.as(ClosureExprSyntax.self) { return c }
                }
                cur = member.base
                continue
            }
            break
        }
        return nil
    }

    // MARK: Interactive controls (Breakthrough #5)
    //
    // A control's binding (`$isOn` / `$value` / `$text`) is lowered to an EVENT
    // ID derived from the bound state's name. The emitted node reads the current
    // value from the marshalled-in state (the binding's base name), and the host
    // wires the SwiftUI control's Binding to dispatch that event back to WASM.

    /// `$flag` → `"flag"` (the state field name = the event id).
    private func bindingName(_ expr: ExprSyntax) -> String {
        var s = expr.trimmedDescription
        if s.hasPrefix("$") { s.removeFirst() }
        return s
    }

    private func eventArg(_ call: FunctionCallExprSyntax, _ label: String) -> (event: String, value: String)? {
        guard let arg = call.arguments.first(where: { $0.label?.text == label }) else { return nil }
        // BUG R2-#46/#63/#111: the binding MUST be a `$`-projection over a single
        // identifier (`$flag`) or a `$a.b` member chain rooted at one `$identifier`.
        // Anything else — `.constant(x)`, `obj.binding(\.flag)`, an inline computed
        // `Binding(...)` — is a `Binding<T>` we'd emit VERBATIM into a scalar guest
        // param (a guest type error: the whole-module compile would then rely on the
        // bisect backstop). Reject those so the control falls back to a native slot.
        guard Self.isDollarBindingProjection(arg.expression) else { return nil }
        let name = bindingName(arg.expression)
        // A MEMBER-PATH binding (`$vm.isOn`/`$config.enabled`) whose chain doesn't
        // resolve to a marshalled field of a reconstructed flat-struct input would LEAK
        // a non-existent member into the guest tree (a guest-WASM compile failure). The
        // SAME `flatStructInputMemberLeaks` guard the leaf emitters use demotes it.
        if name.contains("."), flatStructInputMemberLeaks(name) { return nil }
        return (event: name, value: name)
    }

    /// True iff `expr` is a `$identifier` (or `$a.b.c` member chain rooted at a single
    /// `$identifier`) binding projection — the ONLY form the scalar control lowering can
    /// faithfully consume. Rejects `.constant(...)`, a method-call-returning-Binding, an
    /// inline `Binding(...)`, and any non-`$`-rooted expression.
    static func isDollarBindingProjection(_ expr: ExprSyntax) -> Bool {
        // Walk a trailing `.member` chain down to the root.
        var cur: ExprSyntax = expr
        while let member = cur.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return false }
            cur = base
        }
        // The root must be `$identifier` — a PrefixOperatorExpr with the `$` operator
        // over a bare DeclReference, which SwiftSyntax models as a DeclReferenceExpr
        // whose baseName begins with `$`.
        if let decl = cur.as(DeclReferenceExprSyntax.self) {
            return decl.baseName.text.hasPrefix("$")
        }
        return false
    }

    private mutating func emitToggle(call: FunctionCallExprSyntax) -> String {
        guard let b = eventArg(call, "isOn") else {
            // FIX: title-literal fingerprint stability — if the leading unlabeled arg is a plain
            // string literal (the toggle title), lift it via `opaqueCall` so the id is STRUCTURAL
            // and editing only the title is fingerprint-stable. A non-literal title (variable /
            // interpolation) has no liftable arg → plain `opaqueExpr` unchanged (demote-safe).
            return opaqueCall(call, labelHint: "Toggle")
        }
        // Resolve the LABEL. Three forms:
        //   * a leading string-literal title (markdown/overload-aware), OR
        //   * BUG R2-#64: a TRAILING-CLOSURE label (`Toggle(isOn:){ Label(…) }` /
        //     `{ Text(…) }`) — previously DROPPED, shipping an empty-labeled toggle, OR
        //   * no label (the binding-only init) → empty.
        var labelNodes: [String] = []
        if let titled = call.arguments.first(where: { $0.label == nil }),
           titled.expression.as(StringLiteralExprSyntax.self) != nil {
            // BUG R2-#65/#66/#67/#119: markdown → styledText; overload → slot.
            guard let node = Self.emitTitleTextLiteral(titled.expression) else {
                return opaqueExpr(ExprSyntax(call), labelHint: "Toggle")
            }
            labelNodes = [node]
        } else if let trailing = call.trailingClosure {
            labelNodes = emitItems(trailing.statements)
            // BUG R2-#64: an unlowerable label → slot the whole control rather than ship
            // an empty-labeled toggle.
            if labelNodes.isEmpty { return opaqueExpr(ExprSyntax(call), labelHint: "Toggle") }
        } else {
            for arg in call.arguments where arg.label?.text == "label" {
                if let c = arg.expression.as(ClosureExprSyntax.self) { labelNodes = emitItems(c.statements) }
            }
            if call.arguments.contains(where: { $0.label?.text == "label" }) && labelNodes.isEmpty {
                return opaqueExpr(ExprSyntax(call), labelHint: "Toggle")
            }
        }
        // UPDATE rule: the toggle's binding sets the Bool field (or flips it on a
        // payload-free tap). Event id = the bound field name.
        record(event: b.event, field: b.value, op: .setBool)
        return "N.toggle(isOn: \(b.value), event: \"\(b.event)\", label: \(nodeList(labelNodes)))"
    }

    private mutating func emitSlider(call: FunctionCallExprSyntax) -> String {
        guard let b = eventArg(call, "value") else { return opaqueExpr(ExprSyntax(call), labelHint: "Slider") }
        // `in: lo...hi` → range; default 0...1.
        var range = "0...1"
        if let r = call.arguments.first(where: { $0.label?.text == "in" }) {
            range = r.expression.trimmedDescription
        }
        var step = ""
        if let s = call.arguments.first(where: { $0.label?.text == "step" }) {
            step = ", step: Double(\(s.expression.trimmedDescription))"
        }
        // BUG #8: a NON-LITERAL range bound (`0...maxScore`, a marshalled/var upper bound) can't
        // be evaluated in the guest, so the guest clamp falls back to 0...1 while the native
        // renderer uses the REAL range — the thumb snaps to ~bottom and sticks. SLOT the whole
        // slider natively (correct range + value mapping) when the bounds aren't plain literals.
        // build-safe = demote-safe. A literal-bounded slider lowers as before.
        // FIX: use opaqueCall (instead of opaqueExpr) so that any leading string-literal title
        // arg (e.g. a future Slider variant) is lifted for fingerprint stability. Slider's
        // standard API uses closure labels so there is typically no liftable string literal;
        // opaqueCall falls back to opaqueExpr unchanged when no string literal is present.
        guard let bounds = Self.doubleRangeBounds(range) else {
            return opaqueCall(call, labelHint: "Slider")
        }
        record(event: b.event, field: b.value,
               op: .setDoubleClamped(lo: bounds.0, hi: bounds.1))
        return "N.slider(value: \(b.value), in: \(rangeAsDouble(range))\(step), event: \"\(b.event)\")"
    }

    private mutating func emitStepper(call: FunctionCallExprSyntax) -> String {
        guard let b = eventArg(call, "value") else { return opaqueExpr(ExprSyntax(call), labelHint: "Stepper") }
        var rangeArg = ""
        var lo: Int? = nil, hi: Int? = nil
        if let r = call.arguments.first(where: { $0.label?.text == "in" }) {
            let raw = r.expression.trimmedDescription
            // BUG R2-#47: a FRACTIONAL range bound (`60.0...80.0`) means a Double/Float
            // stepper — the IR `N.stepper` value is Int, so emitting it would be an Int
            // type error caught only by the bisect backstop. Slot the whole stepper.
            if Self.rangeHasFractionalBound(raw) {
                return opaqueExpr(ExprSyntax(call), labelHint: "Stepper")
            }
            rangeArg = ", in: \(raw)"
            if let bounds = Self.intRangeBounds(raw) { lo = bounds.0; hi = bounds.1 }
        }
        var step = ""
        if let s = call.arguments.first(where: { $0.label?.text == "step" }) {
            let raw = s.expression.trimmedDescription
            // BUG R2-#47: a fractional `step:` (`step: 0.5`) means a Double-valued stepper
            // (SwiftUI Stepper is generic over Strideable). The IR step is Int → slot.
            if Self.isNumericLiteral(raw) && raw.contains(".") {
                return opaqueExpr(ExprSyntax(call), labelHint: "Stepper")
            }
            step = ", step: \(raw)"
        }
        // Resolve the title/label.
        let title: String
        if let titled = call.arguments.first(where: { $0.label == nil }),
           let lit = titled.expression.as(StringLiteralExprSyntax.self) {
            // BUG R2-#65/#66/#67/#119: a markdown or SwiftUI-interpolation-overload title
            // can't ride the plain-String `_ title:` builder faithfully → slot.
            if Self.literalHasSwiftUIInterpolationOverload(lit)
                || (Self.stringLiteralIsPlain(lit) && Self.literalLooksMarkdown(lit)) {
                return opaqueExpr(ExprSyntax(call), labelHint: "Stepper")
            }
            title = titled.expression.trimmedDescription
        } else if call.trailingClosure != nil
                    || call.arguments.contains(where: { $0.label?.text == "label" }) {
            // BUG R2-#64: a trailing-closure / `label:` label can't be carried by the
            // plain-String stepper builder → slot rather than ship an empty label.
            return opaqueExpr(ExprSyntax(call), labelHint: "Stepper")
        } else {
            title = "\"\""
        }
        // UPDATE rule: the stepper sets the Int field, clamped to its range (the host
        // sends the already-stepped value; the guest re-clamps as source of truth).
        record(event: b.event, field: b.value, op: .setIntClamped(lo: lo, hi: hi))
        return "N.stepper(\(title), value: \(b.value)\(rangeArg)\(step), event: \"\(b.event)\")"
    }

    /// True iff a `lo...hi` / `lo..<hi` range literal has a FRACTIONAL (non-integer)
    /// numeric bound — the signal of a Double/Float-valued control.
    static func rangeHasFractionalBound(_ raw: String) -> Bool {
        for sep in ["...", "..<"] {
            if let r = raw.range(of: sep) {
                let loS = raw[raw.startIndex..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let hiS = raw[r.upperBound...].trimmingCharacters(in: .whitespaces)
                for bound in [loS, hiS] where isNumericLiteral(bound) && bound.contains(".") {
                    return true
                }
                return false
            }
        }
        return false
    }

    private mutating func emitTextField(call: FunctionCallExprSyntax) -> String {
        guard let b = eventArg(call, "text") else { return opaqueExpr(ExprSyntax(call), labelHint: "TextField") }
        // BUG R2-#66/#67: the placeholder is a LocalizedStringKey — a SwiftUI-only
        // interpolation overload can't ride the plain-String param → slot the control.
        if let ph = call.arguments.first(where: { $0.label == nil })?.expression
            .as(StringLiteralExprSyntax.self), Self.literalHasSwiftUIInterpolationOverload(ph) {
            return opaqueExpr(ExprSyntax(call), labelHint: "TextField")
        }
        let placeholder = call.arguments.first { $0.label == nil }?
            .expression.trimmedDescription ?? "\"\""
        // UPDATE rule: the text field assigns the String field.
        record(event: b.event, field: b.value, op: .setString)
        return "N.textField(\(placeholder), text: \(b.value), event: \"\(b.event)\")"
    }

    // `0...1` → `0.0...1.0` best-effort (the IR slider range is Double).
    private func rangeAsDouble(_ r: String) -> String {
        // The N.slider builder takes a ClosedRange<Double>; emit the literal as-is
        // and let Swift coerce — if it's integer literals, wrap each bound.
        if r.contains("...") {
            let parts = r.components(separatedBy: "...")
            if parts.count == 2 {
                return "Double(\(parts[0]))...Double(\(parts[1]))"
            }
        }
        return r
    }

    // Emit the child nodes from trailing/closure content as a comma list (the
    // STATIC `{ A; B }` content form). The DYNAMIC-DATA form (a leading collection
    // arg + a row closure with a parameter — `List(items){ item in … }`) is NOT
    // handled here: a container that accepts it must call `containerChildren` so the
    // row is built as a real guest loop (or the whole container demotes), never an
    // unbound loop var.
    private mutating func childrenCode(_ call: FunctionCallExprSyntax) -> String {
        var nodes: [String] = []
        if let trailing = call.trailingClosure {
            nodes.append(contentsOf: emitItems(trailing.statements))
        }
        for arg in call.arguments {
            if let closure = arg.expression.as(ClosureExprSyntax.self) {
                nodes.append(contentsOf: emitItems(closure.statements))
            }
        }
        return nodes.map { indent($0) }.joined(separator: ",\n")
    }

    /// Lower a single unlabeled NON-closure VIEW argument to a child node — for the
    /// `.background(<shapeView>)` / `.overlay(<shapeView>)` forms where the backing is
    /// a shape view (`Capsule().fill(Theme.Colors.accent)`, `RoundedRectangle(…).stroke(…)`,
    /// a bare `Circle()`, `Theme.Colors.surface.overlay(…)`). Emitting it as a CONTENT
    /// child lets a design-system shape-fill backing LOWER (the shape + its token fill
    /// ride WASM) instead of slotting the whole modified view — the dominant real-world
    /// demotion pattern. Returns nil when there isn't exactly one unlabeled, non-closure
    /// argument (every other `.background`/`.overlay` shape has been handled by an
    /// earlier color/style/content-closure form, so this is the residual view form).
    /// NOTE: if the child itself can't lower, it becomes an `.opaque` leaf INSIDE the
    /// background content — still strictly better than demoting the whole outer view,
    /// and the leaf's slotability is enforced like any other opaque leaf.
    private mutating func loweredViewArgNode(_ call: FunctionCallExprSyntax) -> String? {
        let unlabeled = call.arguments.filter {
            $0.label == nil && !$0.expression.is(ClosureExprSyntax.self)
        }
        guard unlabeled.count == 1, call.trailingClosure == nil,
              let only = unlabeled.first else { return nil }
        return emitExpr(only.expression)
    }

    /// Outcome of resolving a data-capable container's children (`List`/`Form`/
    /// `Section`): either a comma-joined list of lowered child node strings (the
    /// static `{ A; B }` form, OR a single `N.forEach(<loop>)` for a loopable
    /// dynamic-data form), or a signal to DEMOTE the whole container natively (a
    /// dynamic-data form whose collection can't be safely looped — never an unbound
    /// loop var that breaks the module).
    private enum ContainerChildren { case nodes(String); case demote }

    /// Resolve a data-capable container's children, handling the dynamic-data form
    /// (`List(items){ item in row }`) the same way `ForEach` does: build a real
    /// guest loop when the collection is a marshalled array, else demote the whole
    /// container. A static `{ A; B }` content closure (no leading collection / no
    /// row parameter) falls through to the normal `childrenCode`.
    private mutating func containerChildren(_ call: FunctionCallExprSyntax) -> ContainerChildren {
        if let collectionArg = call.arguments.first(where: { $0.label == nil }),
           let rowClosure = forEachRowClosure(call) {
            // The data-driven form has a leading collection arg AND a row closure with a
            // parameter. A static `List { A; B }` has no leading collection arg.
            if rowClosure.signature?.parameterClause != nil {
                if let rows = loweredRowLoop(collectionArg: collectionArg, rowClosure: rowClosure) {
                    return .nodes(indent("N.forEach(\(rows))"))
                }
                return .demote
            }
            // BUG R2-#1: a `$0`-shorthand data-driven row (`List(items) { Text($0.name) }`)
            // has NO parameterClause, so it WOULD fall through to the static `childrenCode`
            // path — which emits `$0` into a native slot closure (`AnyView(Text($0.name))`)
            // and FAILS the app-target compile (`anonymous closure argument not contained
            // in a closure`). Treat it as the data-driven form: DEMOTE the whole container
            // (the `$0` stays inside its own closure in the native slot). build-safe.
            if AnonymousParamScanner.scan(rowClosure).usesDollarZero {
                return .demote
            }
        }
        return .nodes(childrenCode(call))
    }

    // MARK: Modifiers

    private mutating func emitModifier(_ name: String, call: FunctionCallExprSyntax,
                                       base: String) -> String? {
        let args = call.arguments
        // BUG R2-#74/#121: set when an alignment arg is PRESENT but not a valid IR case
        // (`alignmentPiece` flips it). The .background/.overlay/.mask sites that read an
        // alignment must SLOT the whole modifier when this is true, rather than silently
        // dropping the requested guide (a wrong render) or emitting an invalid enum case.
        var alignmentNeedsSlot = false
        func arg(_ label: String) -> String? {
            args.first { $0.label?.text == label }?.expression.trimmedDescription
        }
        func firstUnlabeled() -> String? {
            args.first { $0.label == nil }?.expression.trimmedDescription
        }
        // True iff the first unlabeled argument is a PLAIN STRING-LITERAL expression (a
        // single string segment, no `\(…)` interpolation) — so it rides the wire verbatim
        // as static data. A computed string OR an interpolated literal (which could be a
        // SwiftUI-only `specifier:`/`format:` overload, or read an unmarshalled name) slots.
        func firstUnlabeledExprIsStringLiteral() -> Bool {
            guard let lit = args.first(where: { $0.label == nil })?.expression
                    .as(StringLiteralExprSyntax.self) else { return false }
            return Self.stringLiteralIsPlain(lit)
        }
        // A numeric-LITERAL argument (else nil → the whole modifier slots).
        func numArg(_ label: String) -> String? {
            guard let v = arg(label), Self.isNumericLiteral(v) else { return nil }
            return v
        }
        // A bool-LITERAL argument as "true"/"false".
        func boolArg(_ label: String) -> String? {
            guard let v = arg(label), v == "true" || v == "false" else { return nil }
            return v
        }
        // A leading-dot enum case (`.bottom`, `Edge.bottom`) → "bottom". Rejects a
        // case WITH a payload/call (`.fraction(0.5)`) or further member access.
        func enumArg(_ label: String?) -> String? {
            guard let raw = (label.flatMap { arg($0) }) ?? (label == nil ? firstUnlabeled() : nil) else { return nil }
            return Self.bareEnumCase(raw)
        }
        // An OptionSet / Edge.Set / Axis.Set literal (`.all`, `.top`, `[.top,.bottom]`,
        // `.horizontal`) → a stable dotless joined string ("top" / "top+bottom").
        func setArg(_ label: String?) -> String? {
            guard let raw = (label.flatMap { arg($0) }) ?? (label == nil ? firstUnlabeled() : nil) else { return nil }
            return Self.parseSetLiteral(raw)
        }
        // A ShapeKind literal for an `in:`-style shape arg, or "nil".
        func shapeArg(_ label: String) -> String {
            guard let raw = arg(label), let s = Self.loweredShapeKindOrNil(raw) else { return "nil" }
            return s
        }
        // `alignment: .x, ` piece (empty when absent / unrecognized).
        func alignmentPiece(_ label: String) -> String {
            guard let a = arg(label) else { return "" }
            // BUG R2-#74/#121: validate against IRAlignment; a non-IR guide must slot.
            guard let c = Self.loweredAlignmentOrNil(a) else {
                alignmentNeedsSlot = true
                return ""
            }
            return "alignment: .\(c), "
        }
        // `, anchor: .center` piece for a UnitPoint arg (named cases only; an
        // arbitrary `UnitPoint(x:y:)` is dropped to nil-anchor — faithful default).
        func unitPointArg(_ label: String) -> String {
            guard let a = arg(label), let u = Self.bareEnumCase(a),
                  Self.knownUnitPoints.contains(u) else { return ", anchor: nil" }
            return ", anchor: .\(u)"
        }
        // Parse `.degrees(N)` / `Angle(degrees: N)` from the first unlabeled or
        // `angle:` arg → the literal degree value, else nil.
        func degreesArg() -> String? {
            let raw = arg("angle") ?? firstUnlabeled()
            guard let r = raw else { return nil }
            return Self.parseDegrees(r)
        }
        // Build an IRStrokeStyle literal from a `style:`/second-positional
        // `StrokeStyle(lineWidth:…)` arg; default lineWidth 1. Best-effort: only
        // the lineWidth literal is parsed (cap/join/dash keep defaults).
        func strokeStyleLit() -> String {
            let raw = arg("style") ?? args.dropFirst().first(where: { $0.label == nil })?.expression.trimmedDescription
            if let r = raw, let lw = Self.captureArg(r, "lineWidth"), Self.isNumericLiteral(lw) {
                return "IRStrokeStyle(lineWidth: Double(\(lw)))"
            }
            return "IRStrokeStyle(lineWidth: 1)"
        }
        switch name {
        case "font":
            // `.font(.title)` / `.font(.system(size: 18, weight: .bold))` lower to a
            // structured `IRFont`. A DESIGN-SYSTEM font token (`Theme.Font.body(13,
            // weight: .semibold)`, any non-`.system` font expr) can't be reduced to an
            // IRFont descriptor, so it rides as a host-supplied `Font` TOKEN: the build
            // thunk evaluates it natively → a `Font` keyed by id, and the tree carries
            // `.fontToken(id)`. (Previously a non-`.system` font emitted invalid guest
            // code — `IRFont(style: .ThemeFontbody(…))` — which failed the WHOLE module
            // compile and shipped NO views; now it lowers as a token, or slots if the
            // token isn't resolvable.)
            guard let f = firstUnlabeled() else { return base }
            // `.font(size.fontSize)` where `Size.fontSize: Font { … }` is a computed Font
            // member of a struct/enum INPUT → a host Font token (source `self.size.fontSize`),
            // resolved through the type-proven catalog (build-safe = demote-safe).
            if let id = inputComputedMemberFontKey(f) {
                return "\(base).fontToken(\"\(id)\")"
            }
            // `.system(size: size.iconSize, …)` whose numeric args reference an out-of-scope
            // computed-member-on-input read → route the args through `numericOrToken` so the
            // `size.iconSize` projects to a `__numtok_<id>` the guest binds. Falls back to the
            // static lowering when the args are all guest-resolvable as written.
            if let irFont = loweredSystemFontOrNil(f) {
                return "\(base).font(\(irFont))"
            }
            if let irFont = Self.loweredFontOrNil(f) {
                return "\(base).font(\(irFont))"
            }
            if let id = recordFontTokenIfResolvable(f) {
                return "\(base).fontToken(\"\(id)\")"
            }
            return nil
        case "foregroundColor":
            // `.foregroundColor(_)` is color-only; keep the legacy `foregroundColor`
            // node so old modules still decode. A literal/system color lowers directly;
            // a design-system token (`Theme.Colors.ink`) lowers as `.hostToken(id)`;
            // an unresolvable token slots.
            if let c = firstUnlabeled(), let lc = colorRefOrToken(c) {
                return "\(base).foregroundColor(\(lc))"
            }
            return nil
        case "foregroundStyle":
            // `.foregroundStyle(_)` with 1–3 style layers. A single color (literal,
            // system, or design-system TOKEN) keeps using the legacy `foregroundColor`
            // node (broadest decode); other forms (gradient/material/hierarchical/
            // semantic, or 2–3 layers) use the `foregroundStyle([IRShapeStyle])` case.
            // A layer we can't resolve (or a non-resolvable token) slots.
            let layers = args.filter { $0.label == nil }.map { $0.expression.trimmedDescription }
            guard !layers.isEmpty, layers.count <= 3 else { return nil }
            if layers.count == 1, let lc = colorRefOrToken(layers[0]) {
                return "\(base).foregroundColor(\(lc))"
            }
            var styleLits: [String] = []
            for l in layers {
                guard let s = shapeStyleOrToken(l) else { return nil }
                styleLits.append(s)
            }
            return "\(base).foregroundStyle([\(styleLits.joined(separator: ", "))])"
        case "bold":
            return "\(base).bold()"
        case "italic":
            return "\(base).italic()"
        case "padding":
            // Forms that lower (all via the existing `IREdgeInsets` modifier — no new
            // IR, the renderer already applies edge insets):
            //   `.padding()`                       → 16 on all edges
            //   `.padding(<number>)`               → that number on all edges
            //   `.padding(.horizontal, 14)`        → leading+trailing = 14
            //   `.padding(.vertical)` / `(.top, 8)`/ `([.top,.bottom], 8)` / `(.all, 6)`
            //   (an omitted length defaults to 16, matching SwiftUI). The edge set is a
            //   built-in `Edge.Set` literal; a numeric length must be a literal. An
            //   `EdgeInsets(…)` value, a computed length, or a non-edge first arg slots.
            if args.isEmpty { return "\(base).padding()" }
            // All-edges numeric: a single unlabeled arg that is a numeric LITERAL, OR a
            // design-system numeric TOKEN (`Theme.Spacing.m`) — `numericOrToken` resolves
            // either (a literal stays verbatim; a token reads a host-injected value, so
            // `.padding(Theme.…)` lowers instead of leaking `Theme`). An `Edge.Set` first
            // arg (`.horizontal`, `.all`, `[.top,.bottom]`) is NOT all-edges — it starts
            // with `.`/`[` and is handled by the edge-specific form below; we exclude
            // those shapes here so a leading-dot case isn't mistaken for a number.
            // A LEADING-DOT case (`.horizontal`) or a `[…]` literal is an Edge.Set, NOT
            // an all-edges length → excluded here (handled by the edge-specific form).
            // A member-access arg is admitted ONLY when it's a qualified numeric-token
            // PATH (`Theme.Spacing.m`); a bare literal/identifier is always admitted.
            if args.count == 1, let only = args.first, only.label == nil,
               !only.expression.is(FunctionCallExprSyntax.self),
               !only.expression.is(ArrayExprSyntax.self),
               !(only.expression.is(MemberAccessExprSyntax.self)
                   && !Self.looksLikeNumericTokenPath(only.expression.trimmedDescription)) {
                guard let n = numericOrToken(only.expression.trimmedDescription) else { return nil }
                return "\(base).padding(Double(\(n)))"
            }
            // Edge-specific: a leading `Edge.Set` literal (`.horizontal` / `[.top,.bottom]`),
            // optionally followed by a numeric length (default 16). This is the dominant
            // real-world padding form and was previously the #1 modifier that slotted a
            // whole design-system component.
            if let edges = setArg(nil) {
                let unlabeledAfter = args.filter { $0.label == nil }.dropFirst()
                var length = "16"
                if let lenArg = unlabeledAfter.first {
                    let raw = lenArg.expression.trimmedDescription
                    guard Self.isNumericLiteral(raw) else { return nil }
                    length = raw
                } else if let lenArg = arg("_") ?? arg("length"), Self.isNumericLiteral(lenArg) {
                    length = lenArg
                }
                guard let insets = Self.edgeSetInsets(edges, length: length) else { return nil }
                return "\(base).padding(\(insets))"
            }
            return nil
        case "frame":
            // Two faithful forms lower (IR v2):
            //   * the FIXED `.frame(width:height:alignment:)` → `.frame(...)`, and
            //   * the FLEXIBLE `.frame(minWidth:idealWidth:maxWidth:minHeight:
            //     idealHeight:maxHeight:alignment:)` (any subset, incl. `.infinity`)
            //     → `.flexFrame(...)`.
            // Each bound is an `IRLength` (`.infinity` → `.infinity`, a number →
            // `.points(Double(x))`). Any other arg label, or a bound expression we
            // can't reduce to a literal/`.infinity`, slots the whole modifier (nil).
            let fixedFrameArgs: Set<String> = ["width", "height", "alignment"]
            let flexFrameArgs: Set<String> = ["minWidth", "idealWidth", "maxWidth",
                                              "minHeight", "idealHeight", "maxHeight"]
            let hasFlex = args.contains { $0.label.map { flexFrameArgs.contains($0.text) } ?? false }
            if hasFlex {
                // The flexible overload has NO width/height; if a fixed bound also
                // appears it isn't a valid flexible frame — slot it.
                let allowed = flexFrameArgs.union(["alignment"])
                for a in args where !(a.label.map { allowed.contains($0.text) } ?? false) {
                    return nil
                }
                func bound(_ label: String) -> String? {
                    guard let raw = arg(label) else { return "nil" }
                    guard let ir = Self.loweredIRLengthOrNil(raw) else { return nil }
                    return ir
                }
                guard let minW = bound("minWidth"), let idealW = bound("idealWidth"),
                      let maxW = bound("maxWidth"), let minH = bound("minHeight"),
                      let idealH = bound("idealHeight"), let maxH = bound("maxHeight")
                else { return nil }
                var alignPiece = "nil"
                if let a = arg("alignment") {
                    // BUG R2-#121: validate frame alignment against IRAlignment.
                    guard let c = Self.loweredAlignmentOrNil(a) else { return nil }
                    alignPiece = ".\(c)"
                }
                return "\(base).flexFrame(minWidth: \(minW), idealWidth: \(idealW), "
                    + "maxWidth: \(maxW), minHeight: \(minH), idealHeight: \(idealH), "
                    + "maxHeight: \(maxH), alignment: \(alignPiece))"
            }
            for a in args where !(a.label.map { fixedFrameArgs.contains($0.text) } ?? false) {
                return nil
            }
            var pieces: [String] = []
            if let w = arg("width") {
                guard let n = numericOrToken(w) else { return nil }
                pieces.append("width: Double(\(n))")
            }
            if let h = arg("height") {
                guard let n = numericOrToken(h) else { return nil }
                pieces.append("height: Double(\(n))")
            }
            if let a = arg("alignment") {
                // BUG R2-#121: validate frame alignment against IRAlignment.
                guard let c = Self.loweredAlignmentOrNil(a) else { return nil }
                pieces.append("alignment: .\(c)")
            }
            return pieces.isEmpty ? nil : "\(base).frame(\(pieces.joined(separator: ", ")))"
        case "background":
            // Forms (checked in order):
            //   .background(<palette/token color>)  → legacy `.background(color)` node
            //   .background([alignment:]){ views }  → `.background(alignment, content)`
            //   .background(<style>[, in: shape])   → `.background(IRShapeStyle, in:)`
            //   .background(<shape VIEW>)           → `.background(alignment, [shapeNode])`
            //     (`Capsule().fill(Theme.Colors.accent)`, `RoundedRectangle(…).stroke(…)`,
            //     a bare `Circle()`) — emitted as a CONTENT child so a design-system
            //     shape-fill background lowers instead of slotting the whole node. This
            //     is the #1 pattern in real design systems and was previously the
            //     dominant cause of whole-view demotion.
            if let c = firstUnlabeled(), let lc = colorRefOrToken(c) {
                return "\(base).background(\(lc))"   // legacy color case (decode-stable)
            }
            if call.trailingClosure != nil || args.contains(where: { $0.expression.is(ClosureExprSyntax.self) }) {
                let align = alignmentPiece("alignment")
                if alignmentNeedsSlot { return nil }   // BUG R2-#74: invalid alignment → slot
                let kids = childrenCode(call)
                return "\(base).background(\(align)[\n\(kids)\n])"
            }
            if let s = firstUnlabeled(), let style = shapeStyleOrToken(s) {
                let inShape = shapeArg("in")
                return "\(base).background(\(style), in: \(inShape))"
            }
            if let child = loweredViewArgNode(call) {
                let align = alignmentPiece("alignment")
                if alignmentNeedsSlot { return nil }   // BUG R2-#74: invalid alignment → slot
                return "\(base).background(\(align)[\n\(indent(child))\n])"
            }
            return nil
        case "cornerRadius":
            if let r = firstUnlabeled() {
                guard let n = numericOrToken(r) else { return nil }
                return "\(base).cornerRadius(Double(\(n)))"
            }
            return base
        case "opacity":
            // Route the opacity value through `numericOrToken` so a design-system / reactive-
            // member numeric read (`vm.loading ? 0.5 : 1`) host-projects instead of leaking; a
            // plain literal/marshalled expr resolves verbatim (the `Double(...)` cast widens it).
            if let o = firstUnlabeled() {
                if let n = numericOrToken(o) { return "\(base).opacity(Double(\(n)))" }
                return "\(base).opacity(Double(\(o)))"
            }
            return base
        case "lineLimit":
            // `.lineLimit(N, reservesSpace: B)` (iOS 16+) → the dedicated IR case; a
            // non-literal count or reserve flag slots.
            if let r = boolArg("reservesSpace") {
                guard let n = firstUnlabeled(), Self.isNumericLiteral(n) else { return nil }
                return "\(base).lineLimitReservesSpace(limit: \(n), reservesSpace: \(r))"
            }
            if arg("reservesSpace") != nil { return nil }
            if let n = firstUnlabeled() {
                // Builder is `lineLimit(_ n: Int?)`; a range overload (`2...4`) or a
                // non-literal identifier (`maxLines`) passed verbatim breaks guest
                // compile → slot. Only `nil` or a plain Int literal is representable.
                guard n == "nil" || (Self.isNumericLiteral(n) && !n.contains(".")) else { return nil }
                return "\(base).lineLimit(\(n))"
            }
            return base
        case "multilineTextAlignment":
            if let a = firstUnlabeled() {
                // IRTextAlignment is the closed enum {leading,center,trailing}; a qualified
                // (`TextAlignment.center`) or custom alignment would break guest compile → slot.
                guard let c = Self.bareEnumCase(a), ["leading", "center", "trailing"].contains(c) else { return nil }
                return "\(base).multilineTextAlignment(.\(c))"
            }
            return base
        case "onTapGesture":
            // Lower a discrete tap to an event id derived from the call site. The
            // action closure body is NOT view content, but it IS the UPDATE half:
            // parse it for a single recognizable `@State` mutation and record a rule
            // keyed by this tap's event id (so the guest's `update` runs the tap
            // logic IN WASM). A body the guest can't lower yields no rule → native.
            let eid = "tap\(Self.stableEventHash(call.trimmedDescription))"
            let tapClosure = call.trailingClosure
                ?? args.first { $0.expression.is(ClosureExprSyntax.self) }?
                    .expression.as(ClosureExprSyntax.self)
            let tapRecorded = recordActionMutation(tapClosure, event: eid)
            // The renderer DOES fire `d?.send(eid, .none)` on tap, so a SIMPLE recorded
            // mutation dispatches in WASM (kept routing — better than a native slot). A
            // non-empty closure the guest couldn't record (a Task/method call/multi-statement
            // body), OR a function-ref action (`.onTapGesture(perform: handler)`), would fire
            // the event but match NO rule → a DEAD tap that also SWALLOWS the gesture from the
            // native view underneath. A `count:` > 1 (`.onTapGesture(count: 2)`) is a multi-tap
            // the IR can't represent. In EITHER undispatchable case, keep the `.onTapGesture`
            // NATIVE via a `nativeEffectSlot` (the thunk re-applies `content.onTapGesture { … }`
            // verbatim over `self`, preserving the closure AND the count faithfully) when the
            // closure is thunk-reachable — so the REST of the view still OTA-patches. Only if it
            // can't be slotted do we demote.
            let tapUndispatchable = !tapRecorded
                && (!Self.actionClosureIsEmpty(tapClosure) || modifierHasFunctionRefAction(call))
            let tapMultiTap = (arg("count").map { $0 != "1" } ?? false)
            if tapUndispatchable || tapMultiTap {
                if let slotID = tryRecordEffectSlot(call, name: "onTapGesture") {
                    return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
                }
                hasUndispatchableEffect = true
            }
            return "\(base).onTapGesture(event: \"\(eid)\")"
        case "navigationTitle":
            // `.navigationTitle("X")` — lower only the string form (a literal or a
            // marshalled-in String input). A `Text`/`LocalizedStringKey`/binding
            // title we can't model as a plain String degrades to native (nil).
            guard let t = firstUnlabeled() else { return nil }
            let trimmed = t.trimmingCharacters(in: .whitespaces)
            // Reject a `Text(...)` title or any non-string-looking expression: keep
            // a string literal or a bare identifier (a String input/property).
            if trimmed.hasPrefix("Text(") || trimmed.hasPrefix(".") { return nil }
            // Route through stringContentOrToken (BUG #12): a reactive/flat-struct member the
            // guest can't reconstruct (`vm.pageTitle`, whose mirroring struct carries only its
            // collection field) HOST-PROJECTS to a `__strtok_` token instead of leaking verbatim
            // (which fails the whole guest compile). A literal / marshalled-String input stays
            // verbatim; an un-resolvable, un-projectable title degrades to native (nil).
            guard let resolved = stringContentOrToken(trimmed) else { return nil }
            return "\(base).navigationTitle(\(resolved))"
        case "tint":
            // `.tint(color)` — a palette name / `Color(red:…)` RGBA / design-system
            // TOKEN keeps the legacy `tint(ColorRef)` node; a `ShapeStyle`
            // (`.blue.gradient`, a gradient) uses the widened `tintStyle(IRShapeStyle)`
            // case. Else slots.
            if let c = firstUnlabeled(), let lc = colorRefOrToken(c) {
                return "\(base).tint(\(lc))"
            }
            if let s = firstUnlabeled(), let style = shapeStyleOrToken(s) {
                return "\(base).tint(\(style))"
            }
            return nil
        case "clipShape":
            // `.clipShape(Circle())` / `Capsule()` / `RoundedRectangle(cornerRadius:)`
            // / `Rectangle()` / `Ellipse()` → `.clipShape(.circle)` etc. A custom
            // Shape, or a `style:` arg we don't model, slots (nil).
            if let s = firstUnlabeled(), args.allSatisfy({ $0.label == nil }),
               let shape = shapeKindOrTokenized(s) {
                return "\(base).clipShape(\(shape))"
            }
            return nil
        case "trim":
            // `Shape.trim(from: 0, to: progress)` — from/to are guest-resolvable
            // numerics (a literal, a marshalled input like `progress`, or a numeric
            // token). `from` defaults to 0, `to` to 1 (SwiftUI's defaults). A value
            // the guest can't resolve slots the whole modified shape.
            let trimFromRaw = arg("from") ?? "0"
            let trimToRaw = arg("to") ?? "1"
            guard let from = numericOrToken(trimFromRaw), let to = numericOrToken(trimToRaw) else { return nil }
            return "\(base).trim(from: Double(\(from)), to: Double(\(to)))"
        case "disabled":
            // Only a BOOL LITERAL lowers (`.disabled(true)` / `.disabled(false)`);
            // a dynamic `.disabled(expr)` stays native via a slot (nil).
            if let b = firstUnlabeled(), b == "true" || b == "false" {
                return "\(base).disabled(\(b))"
            }
            return nil
        case "fixedSize":
            // The no-arg `.fixedSize()` lowers; the axis form
            // `.fixedSize(horizontal:vertical:)` lowers when both are bool literals.
            if args.isEmpty { return "\(base).fixedSize()" }
            if let h = boolArg("horizontal"), let v = boolArg("vertical") {
                return "\(base).fixedSize(horizontal: \(h), vertical: \(v))"
            }
            return nil

        // MARK: Styling (IRShapeStyle vocabulary)
        // (foregroundStyle/background/tint are handled in their merged cases above,
        // which dispatch the color vs ShapeStyle vs content-builder forms.)
        case "fill":
            // `.fill(<style/token>[, style: FillStyle])`. We model the eoFill flag only.
            guard let s = firstUnlabeled(), let style = shapeStyleOrToken(s) else { return nil }
            let eo = (arg("style").map { $0.contains("eoFill: true") } ?? false) ? "true" : "false"
            return "\(base).fill(\(style), eoFill: \(eo))"
        case "stroke":
            guard let s = firstUnlabeled(), let style = shapeStyleOrToken(s) else { return nil }
            return "\(base).stroke(\(style), \(strokeStyleLit()))"
        case "strokeBorder":
            guard let s = firstUnlabeled(), let style = shapeStyleOrToken(s) else { return nil }
            return "\(base).strokeBorder(\(style), \(strokeStyleLit()))"
        case "border":
            guard let s = firstUnlabeled(), let style = shapeStyleOrToken(s) else { return nil }
            let w = arg("width").flatMap { Self.isNumericLiteral($0) ? $0 : nil } ?? "1"
            return "\(base).border(\(style), width: Double(\(w)))"
        case "overlay":
            // `.overlay(<style/token>, in: shape)` OR `.overlay(alignment:){ views }`
            // OR `.overlay(<shape VIEW>)` (`Capsule().stroke(Theme.Colors.line)`) —
            // emitted as a content child so a design-system shape overlay lowers.
            if let s = firstUnlabeled(), let style = shapeStyleOrToken(s),
               let shapeRaw = arg("in"), let shape = Self.loweredShapeKindOrNil(shapeRaw) {
                return "\(base).overlay(\(style), in: \(shape))"
            }
            if call.trailingClosure != nil || args.contains(where: { $0.expression.is(ClosureExprSyntax.self) }) {
                let align = alignmentPiece("alignment")
                if alignmentNeedsSlot { return nil }   // BUG R2-#74: invalid alignment → slot
                let kids = childrenCode(call)
                return "\(base).overlay(\(align)[\n\(kids)\n])"
            }
            if let child = loweredViewArgNode(call) {
                let align = alignmentPiece("alignment")
                if alignmentNeedsSlot { return nil }   // BUG R2-#74: invalid alignment → slot
                return "\(base).overlay(\(align)[\n\(indent(child))\n])"
            }
            return nil
        case "mask":
            // `.mask(alignment:){ maskContent }`.
            if call.trailingClosure != nil || args.contains(where: { $0.expression.is(ClosureExprSyntax.self) }) {
                let align = alignmentPiece("alignment")
                if alignmentNeedsSlot { return nil }   // BUG R2-#74: invalid alignment → slot
                let kids = childrenCode(call)
                return "\(base).mask(\(align)[\n\(kids)\n])"
            }
            return nil
        case "shadow":
            // `.shadow(color:?, radius:, x:?, y:?)`. radius must be a literal.
            guard let r = arg("radius"), Self.isNumericLiteral(r) else { return nil }
            var colorPiece = "nil"
            if let c = arg("color"), let lc = colorRefOrToken(c) { colorPiece = lc }
            else if arg("color") != nil { return nil }   // a color we can't lower → slot whole
            let x = arg("x").flatMap { Self.isNumericLiteral($0) ? $0 : nil } ?? "0"
            let y = arg("y").flatMap { Self.isNumericLiteral($0) ? $0 : nil } ?? "0"
            return "\(base).shadow(color: \(colorPiece), radius: Double(\(r)), x: Double(\(x)), y: Double(\(y)))"

        // MARK: Layout
        case "offset":
            // `.offset(x:y:)` or `.offset(CGSize(width:height:))` — literals only.
            if let x = numArg("x"), let y = numArg("y") {
                return "\(base).offset(x: Double(\(x)), y: Double(\(y)))"
            }
            return nil
        case "position":
            if let x = numArg("x"), let y = numArg("y") {
                return "\(base).position(x: Double(\(x)), y: Double(\(y)))"
            }
            return nil
        case "aspectRatio":
            // `.aspectRatio([ratio,] contentMode:)`. The contentMode is `contentMode:`
            // OR a leading `.fit`/`.fill`; the ratio (if present) is a leading
            // numeric literal. A `CGSize` ratio or computed ratio slots (nil).
            var modeRaw: String? = nil
            var ratioPiece = "nil"
            if let cm = arg("contentMode"), let c = Self.bareEnumCase(cm), c == "fit" || c == "fill" {
                modeRaw = ".\(c)"
            }
            for a in args where a.label == nil {
                let raw = a.expression.trimmedDescription
                if let c = Self.bareEnumCase(raw), c == "fit" || c == "fill" { modeRaw = ".\(c)" }
                else if Self.isNumericLiteral(raw) { ratioPiece = "Double(\(raw))" }
                else { return nil }   // an unrecognized positional (CGSize/computed) → slot
            }
            guard let m = modeRaw else { return nil }
            return "\(base).aspectRatio(\(ratioPiece), contentMode: \(m))"
        case "scaledToFit":
            return args.isEmpty ? "\(base).scaledToFit()" : nil
        case "scaledToFill":
            return args.isEmpty ? "\(base).scaledToFill()" : nil
        case "clipped":
            let aa = boolArg("antialiased") ?? "false"
            return "\(base).clipped(antialiased: \(aa))"
        case "layoutPriority":
            guard let p = firstUnlabeled(), Self.isNumericLiteral(p) else { return nil }
            return "\(base).layoutPriority(Double(\(p)))"
        case "safeAreaInset":
            // `.safeAreaInset(edge: .bottom, alignment:?, spacing:?){ content }`.
            guard let edge = enumArg("edge") else { return nil }
            guard call.trailingClosure != nil || args.contains(where: { $0.expression.is(ClosureExprSyntax.self) }) else { return nil }
            // BUG R2-#74: the IR carries an IRAlignment — a guide it can't represent (a
            // VerticalAlignment like `.firstTextBaseline` for a leading/trailing edge, or
            // a custom guide) must SLOT, not silently drop / emit an invalid case.
            var align = ""
            if let a = arg("alignment") {
                guard let c = Self.loweredAlignmentOrNil(a) else { return nil }
                align = ", alignment: .\(c)"
            }
            let spacing = numArg("spacing").map { ", spacing: Double(\($0))" } ?? ""
            let kids = childrenCode(call)
            return "\(base).safeAreaInset(edge: \"\(edge)\"\(align)\(spacing), [\n\(kids)\n])"
        case "ignoresSafeArea":
            // `.ignoresSafeArea([regions][, edges:])` — enum/option literals → names.
            let regions = enumArg(nil) ?? "all"
            let edges = setArg("edges") ?? "all"
            return "\(base).ignoresSafeArea(regions: \"\(regions)\", edges: \"\(edges)\")"
        case "edgesIgnoringSafeArea":
            let edges = setArg(nil) ?? "all"
            return "\(base).ignoresSafeArea(regions: \"all\", edges: \"\(edges)\")"
        case "zIndex":
            guard let z = firstUnlabeled(), Self.isNumericLiteral(z) else { return nil }
            return "\(base).zIndex(Double(\(z)))"
        case "containerRelativeFrame":
            let axes = setArg(nil) ?? enumArg(nil)
            guard let a = axes else { return nil }
            // BUG R2-#74/#121: validate the alignment against IRAlignment; slot on a miss.
            var align = ""
            if let al = arg("alignment") {
                guard let c = Self.loweredAlignmentOrNil(al) else { return nil }
                align = ", alignment: .\(c)"
            }
            return "\(base).containerRelativeFrame(axes: \"\(a)\"\(align))"
        case "allowsHitTesting":
            // `.allowsHitTesting(<bool literal>)` — a non-literal slots.
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).allowsHitTesting(\(b))"
        case "scrollClipDisabled":
            // No-arg defaults to true; an explicit bool literal lowers; anything else slots.
            if args.isEmpty { return "\(base).scrollClipDisabled(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).scrollClipDisabled(\(b))"
        case "scrollContentBackground":
            // `.scrollContentBackground(.hidden)` — a Visibility enum case.
            guard let vis = enumArg(nil), ["automatic", "hidden", "visible"].contains(vis) else { return nil }
            return "\(base).scrollContentBackground(\"\(vis)\")"

        // MARK: Scroll & layout (sweep — added at END)
        case "scrollDisabled":
            // `.scrollDisabled(<bool literal>)` — a non-literal slots.
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).scrollDisabled(\(b))"
        case "scrollIndicators":
            // `.scrollIndicators(.hidden[, axes: .vertical])` — a
            // ScrollIndicatorVisibility enum + optional Axis.Set. A non-enum form slots.
            guard let vis = enumArg(nil),
                  ["automatic", "visible", "hidden", "never"].contains(vis) else { return nil }
            let axes = setArg("axes") ?? "all"
            return "\(base).scrollIndicators(\"\(vis)\", axes: \"\(axes)\")"
        case "scrollTargetBehavior":
            // `.scrollTargetBehavior(.viewAligned)` / `(.paging)` — the two built-in
            // behaviors. A custom `ScrollTargetBehavior` struct slots.
            guard let beh = enumArg(nil), ["viewAligned", "paging"].contains(beh) else { return nil }
            return "\(base).scrollTargetBehavior(\"\(beh)\")"
        case "scrollTargetLayout":
            // `.scrollTargetLayout()` (defaults to enabled) or `(isEnabled: <bool>)`.
            if args.isEmpty { return "\(base).scrollTargetLayout(isEnabled: true)" }
            guard let b = boolArg("isEnabled") else { return nil }
            return "\(base).scrollTargetLayout(isEnabled: \(b))"
        case "scrollBounceBehavior":
            // `.scrollBounceBehavior(.basedOnSize[, axes: .vertical])` — a
            // ScrollBounceBehavior enum + optional Axis.Set.
            guard let beh = enumArg(nil),
                  ["automatic", "always", "basedOnSize"].contains(beh) else { return nil }
            let axes = setArg("axes") ?? "vertical"
            return "\(base).scrollBounceBehavior(\"\(beh)\", axes: \"\(axes)\")"
        case "contentMargins":
            // `.contentMargins([edges,] <length>[, for: <placement>])`. Length must be
            // a numeric literal; edges (an Edge.Set) and placement default. The
            // `EdgeInsets`/computed forms slot.
            let unlabeled = Array(args.filter { $0.label == nil })
            var edges = "all"
            var lengthRaw: String? = nil
            if unlabeled.count == 2 {
                // `.contentMargins(<edges>, <length>)`
                guard let e = Self.parseSetLiteral(unlabeled[0].expression.trimmedDescription)
                else { return nil }
                edges = e
                lengthRaw = unlabeled[1].expression.trimmedDescription
            } else if unlabeled.count == 1 {
                // `.contentMargins(<length>)` (all edges)
                lengthRaw = unlabeled[0].expression.trimmedDescription
            } else {
                return nil
            }
            guard let len = lengthRaw, Self.isNumericLiteral(len) else { return nil }
            var placement = "automatic"
            if let p = enumArg("for"),
               ["automatic", "scrollContent", "scrollIndicators"].contains(p) {
                placement = p
            } else if arg("for") != nil {
                // a `for:` was given but isn't a recognized placement → slot
                return nil
            }
            return "\(base).contentMargins(edges: \"\(edges)\", Double(\(len)), placement: \"\(placement)\")"
        case "safeAreaPadding":
            // `.safeAreaPadding(<length>)` (all edges) / `.safeAreaPadding(<edges>[, <length>])`
            // / `.safeAreaPadding(EdgeInsets(...))`. A computed length slots.
            if args.isEmpty { return nil }
            if let only = firstUnlabeled(), args.count == 1,
               let insets = Self.parseEdgeInsetsLiteral(only) {
                // `.safeAreaPadding(EdgeInsets(...))`
                return "\(base).safeAreaPadding(edges: \"all\", nil, insets: \(insets))"
            }
            let unlabeled = Array(args.filter { $0.label == nil })
            if unlabeled.count == 1, let raw = unlabeled.first?.expression.trimmedDescription {
                if Self.isNumericLiteral(raw) {
                    // `.safeAreaPadding(<length>)` — all edges, that length.
                    return "\(base).safeAreaPadding(edges: \"all\", Double(\(raw)), insets: nil)"
                }
                if let e = Self.parseSetLiteral(raw) {
                    // `.safeAreaPadding(<edges>)` — system default length on those edges.
                    return "\(base).safeAreaPadding(edges: \"\(e)\", nil, insets: nil)"
                }
                return nil
            }
            if unlabeled.count == 2,
               let e = Self.parseSetLiteral(unlabeled[0].expression.trimmedDescription) {
                let lenRaw = unlabeled[1].expression.trimmedDescription
                guard Self.isNumericLiteral(lenRaw) else { return nil }
                return "\(base).safeAreaPadding(edges: \"\(e)\", Double(\(lenRaw)), insets: nil)"
            }
            return nil
        case "listRowSeparator", "listSectionSeparator":
            // `.listRowSeparator(.hidden[, edges: .all])` — Visibility + optional edges.
            guard let vis = enumArg(nil), ["automatic", "hidden", "visible"].contains(vis) else { return nil }
            let edges = setArg("edges") ?? "all"
            return "\(base).\(name)(\"\(vis)\", edges: \"\(edges)\")"
        case "listRowInsets":
            // `.listRowInsets(EdgeInsets(top:leading:bottom:trailing:))` — all literal,
            // OR `.listRowInsets(nil)` (reset → zero). A computed value slots.
            guard let raw = firstUnlabeled() else { return nil }
            if raw == "nil" { return "\(base).listRowInsets(IREdgeInsets())" }
            guard let insets = Self.parseEdgeInsetsLiteral(raw) else { return nil }
            return "\(base).listRowInsets(\(insets))"
        case "listRowBackground":
            // `.listRowBackground(<view>)` — the backing view rides as a child subtree
            // (a non-lowerable backing becomes an opaque leaf inside it, never a demote).
            guard let only = args.first(where: { $0.label == nil }),
                  args.count == 1, call.trailingClosure == nil else { return nil }
            if only.expression.trimmedDescription == "nil" {
                return "\(base).listRowBackground([])"
            }
            let child = emitExpr(only.expression)
            return "\(base).listRowBackground([\(child)])"

        // MARK: Transforms & visual effects
        case "rotationEffect":
            guard let deg = degreesArg() else { return nil }
            let anchor = unitPointArg("anchor")
            return "\(base).rotationEffect(degrees: Double(\(deg))\(anchor))"
        case "rotation3DEffect":
            guard let deg = degreesArg(), let axis = arg("axis") else { return nil }
            guard let (x, y, z) = Self.parseAxis3(axis) else { return nil }
            let anchor = unitPointArg("anchor")
            let anchorZ = numArg("anchorZ") ?? "0"
            let persp = numArg("perspective") ?? "1"
            return "\(base).rotation3DEffect(degrees: Double(\(deg)), x: \(x), y: \(y), z: \(z)\(anchor), anchorZ: Double(\(anchorZ)), perspective: Double(\(persp)))"
        case "scaleEffect":
            // `.scaleEffect(s)` uniform, `.scaleEffect(x:y:)`, or `CGSize`.
            let anchor = unitPointArg("anchor")
            if let x = numArg("x"), let y = numArg("y") {
                return "\(base).scaleEffect(x: Double(\(x)), y: Double(\(y))\(anchor))"
            }
            if let s = firstUnlabeled(), Self.isNumericLiteral(s) {
                return "\(base).scaleEffect(x: Double(\(s)), y: Double(\(s))\(anchor))"
            }
            return nil
        case "blur":
            guard let r = numArg("radius") else { return nil }
            let o = boolArg("opaque") ?? "false"
            return "\(base).blur(radius: Double(\(r)), opaque: \(o))"
        case "brightness", "contrast", "saturation", "grayscale":
            guard let v = firstUnlabeled(), Self.isNumericLiteral(v) else { return nil }
            return "\(base).\(name)(Double(\(v)))"
        case "hueRotation":
            guard let deg = degreesArg() else { return nil }
            return "\(base).hueRotation(degrees: Double(\(deg)))"
        case "colorInvert":
            return args.isEmpty ? "\(base).colorInvert()" : nil
        case "blendMode":
            guard let m = enumArg(nil) else { return nil }
            return Self.knownBlendModes.contains(m) ? "\(base).blendMode(.\(m))" : nil

        // MARK: Text styling
        case "fontWeight":
            guard let w = enumArg(nil), Self.irFontWeightCases.contains(w) else { return nil }
            return "\(base).fontWeight(.\(w))"
        case "fontDesign":
            guard let d = enumArg(nil), Self.irFontDesignCases.contains(d) else { return nil }
            return "\(base).fontDesign(.\(d))"
        case "underline", "strikethrough":
            // `.underline()` / `.underline(_ active:Bool, color:?)`.
            var active = "true"
            if let a = firstUnlabeled() {
                guard a == "true" || a == "false" else { return nil }
                active = a
            }
            var colorPiece = "nil"
            if let c = arg("color"), let lc = Self.loweredColorOrNil(c) { colorPiece = lc }
            else if arg("color") != nil { return nil }
            return "\(base).\(name)(\(active), color: \(colorPiece))"
        case "kerning", "tracking", "baselineOffset", "lineSpacing", "minimumScaleFactor":
            guard let v = firstUnlabeled(), Self.isNumericLiteral(v) else { return nil }
            return "\(base).\(name)(Double(\(v)))"
        case "textCase":
            // `.textCase(.uppercase)` / `.textCase(.lowercase)` / `.textCase(nil)`.
            guard let raw = firstUnlabeled() else { return nil }
            if raw == "nil" { return "\(base).textCase(nil)" }
            let c = raw.replacingOccurrences(of: ".", with: "")
            return (c == "uppercase" || c == "lowercase") ? "\(base).textCase(\"\(c)\")" : nil
        case "truncationMode":
            guard let m = enumArg(nil) else { return nil }
            return ["head", "middle", "tail"].contains(m) ? "\(base).truncationMode(\"\(m)\")" : nil
        case "monospaced":
            return args.isEmpty ? "\(base).monospaced()" : nil
        case "monospacedDigit":
            return args.isEmpty ? "\(base).monospacedDigit()" : nil
        case "redacted":
            guard let r = enumArg("reason") else { return nil }
            return "\(base).redacted(reason: \"\(r)\")"
        case "unredacted":
            return args.isEmpty ? "\(base).unredacted()" : nil
        case "symbolRenderingMode":
            guard let m = enumArg(nil) else { return nil }
            return ["monochrome", "hierarchical", "palette", "multicolor"].contains(m)
                ? "\(base).symbolRenderingMode(\"\(m)\")" : nil
        case "symbolVariant":
            guard let v = enumArg(nil) else { return nil }
            return "\(base).symbolVariant(\"\(v)\")"
        case "imageScale":
            guard let s = enumArg(nil) else { return nil }
            return ["small", "medium", "large"].contains(s) ? "\(base).imageScale(\"\(s)\")" : nil
        case "dynamicTypeSize":
            // Only the single-size form (`.dynamicTypeSize(.large)`); a range slots.
            guard let s = enumArg(nil) else { return nil }
            return "\(base).dynamicTypeSize(\"\(s)\")"

        // MARK: Control config (built-in named styles only; a custom style slots)
        case "buttonStyle":
            guard let s = enumArg(nil), Self.knownButtonStyles.contains(s) else { return nil }
            return "\(base).buttonStyle(.\(s))"
        case "listStyle":
            guard let s = enumArg(nil), Self.knownListStyles.contains(s) else { return nil }
            return "\(base).listStyle(.\(s))"
        case "tabViewStyle":
            // `.tabViewStyle(.page)` / `.tabViewStyle(.page(indexDisplayMode: .never))`
            // / `.tabViewStyle(.automatic)`. A custom style STRUCT slots.
            guard let raw = firstUnlabeled() else { return nil }
            guard let s = Self.parsePageStyle(raw, modeLabel: "indexDisplayMode") else { return nil }
            return "\(base).tabViewStyle(\"\(s)\")"
        case "indexViewStyle":
            // `.indexViewStyle(.page)` / `.indexViewStyle(.page(backgroundDisplayMode: .always))`.
            guard let raw = firstUnlabeled() else { return nil }
            guard let s = Self.parsePageStyle(raw, modeLabel: "backgroundDisplayMode") else { return nil }
            return "\(base).indexViewStyle(\"\(s)\")"
        case "pickerStyle", "toggleStyle", "labelStyle", "gaugeStyle",
             "progressViewStyle", "menuStyle", "buttonBorderShape", "controlSize",
             "keyboardType", "textContentType", "textInputAutocapitalization", "submitLabel":
            // Built-in named style/config enums → carry the case name as a String.
            // A custom style STRUCT (`MyStyle()`) is a call, not a `.case`, so it
            // fails `enumArg` and slots — exactly the honest boundary.
            guard let s = enumArg(nil) else { return nil }
            return "\(base).\(name)(\"\(s)\")"

        // MARK: Control config — additional built-in styles (styles-views wave)
        // Each carries the built-in case name as a String; a name not in the
        // known set (or a custom style STRUCT, which `enumArg` rejects) slots.
        case "textFieldStyle":
            guard let s = enumArg(nil), Self.knownTextFieldStyles.contains(s) else { return nil }
            return "\(base).textFieldStyle(\"\(s)\")"
        case "datePickerStyle":
            guard let s = enumArg(nil), Self.knownDatePickerStyles.contains(s) else { return nil }
            return "\(base).datePickerStyle(\"\(s)\")"
        case "groupBoxStyle":
            guard let s = enumArg(nil), Self.knownGroupBoxStyles.contains(s) else { return nil }
            return "\(base).groupBoxStyle(\"\(s)\")"
        case "controlGroupStyle":
            guard let s = enumArg(nil), Self.knownControlGroupStyles.contains(s) else { return nil }
            return "\(base).controlGroupStyle(\"\(s)\")"
        case "disclosureGroupStyle":
            guard let s = enumArg(nil), Self.knownDisclosureGroupStyles.contains(s) else { return nil }
            return "\(base).disclosureGroupStyle(\"\(s)\")"
        case "tableStyle":
            guard let s = enumArg(nil), Self.knownTableStyles.contains(s) else { return nil }
            return "\(base).tableStyle(\"\(s)\")"
        case "autocorrectionDisabled":
            // No-arg defaults to true; an explicit bool literal lowers; anything else slots.
            if args.isEmpty { return "\(base).autocorrectionDisabled(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).autocorrectionDisabled(\(b))"
        case "preferredColorScheme":
            guard let raw = firstUnlabeled() else { return nil }
            if raw == "nil" { return "\(base).preferredColorScheme(nil)" }
            let c = raw.replacingOccurrences(of: ".", with: "")
            return (c == "light" || c == "dark") ? "\(base).preferredColorScheme(\"\(c)\")" : nil
        case "accentColor":
            guard let c = firstUnlabeled() else { return nil }
            if c == "nil" { return "\(base).accentColor(nil)" }
            guard let lc = colorRefOrToken(c) else { return nil }
            return "\(base).accentColor(\(lc))"

        // MARK: Gestures
        case "onLongPressGesture":
            let eid = "lp\(Self.stableEventHash(call.trimmedDescription))"
            let lpClosure = call.trailingClosure
                ?? args.first { $0.label?.text == "perform" }?.expression.as(ClosureExprSyntax.self)
            let lpRecorded = recordActionMutation(lpClosure, event: eid)
            // Same as onTapGesture: a recorded simple mutation dispatches in WASM (kept routing).
            // A non-empty unrecordable closure / function-ref action, OR an unmodeled
            // `maximumDistance`/`pressing`/`onPressingChanged`/non-literal `minimumDuration`,
            // would otherwise be a dead or wrong-threshold control. In any of those cases keep the
            // `.onLongPressGesture` NATIVE via a `nativeEffectSlot` (the thunk re-applies it
            // verbatim over `self`, preserving every param + callback faithfully) when the closure
            // is thunk-reachable — the REST of the view still OTA-patches. Only if not slottable
            // do we demote.
            let lpUndispatchable = !lpRecorded
                && (!Self.actionClosureIsEmpty(lpClosure) || modifierHasFunctionRefAction(call))
            let lpUnmodeled = arg("maximumDistance") != nil
                || arg("pressing") != nil || arg("onPressingChanged") != nil
                || (arg("minimumDuration").map { !Self.isNumericLiteral($0) } ?? false)
            if lpUndispatchable || lpUnmodeled {
                if let slotID = tryRecordEffectSlot(call, name: "onLongPressGesture") {
                    return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
                }
                hasUndispatchableEffect = true
            }
            let dur = numArg("minimumDuration") ?? "0.5"
            return "\(base).onLongPressGesture(minimumDuration: Double(\(dur)), event: \"\(eid)\")"
        case "gesture", "highPriorityGesture", "simultaneousGesture":
            // `.gesture(DragGesture()…)` / `MagnifyGesture()` / `RotateGesture()`.
            // The continuous value (translation / magnification / rotation) ships to
            // the guest over the event loop (drag → `.point`, magnify/rotate →
            // `.double`). A composed/custom gesture we can't recognize slots (nil).
            // BUG R2-#76/#80: `highPriorityGesture`/`simultaneousGesture` carry GESTURE
            // ARBITRATION priority the IR/renderer can only express as an EXCLUSIVE
            // `.gesture`/`.onTapGesture`. Lowering them to a plain exclusive gesture
            // changes arbitration on device (a simultaneousGesture would no longer fire
            // alongside the parent's scroll/tap; a highPriorityGesture would no longer
            // pre-empt a child). Only `gesture` keeps routing; the priority forms demote.
            if name == "highPriorityGesture" || name == "simultaneousGesture" {
                // The priority/arbitration is unmodeled by the IR — but a NATIVE re-application
                // preserves it faithfully. Keep it native via a `nativeEffectSlot` when the
                // gesture's handlers are thunk-reachable; the rest of the view still OTA-patches.
                // BUG FIX: pass GATE-1 key "gesture" (the allowlisted user-input key) — the slot's
                // emitted `applySource` is rebuilt from the REAL `call` (`content.highPriorityGesture(…)`
                // via `member.declName`), so the `name` arg ONLY selects GATE 1. Pre-fix it passed
                // "highPriorityGesture"/"simultaneousGesture", which aren't in `nativeEffectSlotModifiers`,
                // so GATE 1 always failed and these views demoted despite the slot path being written.
                if let slotID = tryRecordEffectSlot(call, name: "gesture") {
                    return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
                }
                hasUndispatchableEffect = true
                return base
            }
            guard let g = firstUnlabeled() else { return nil }
            let h = Self.stableEventHash(call.trimmedDescription)
            if g.hasPrefix("DragGesture") {
                let minDist = Self.captureArg(g, "minimumDistance").flatMap { Self.isNumericLiteral($0) ? $0 : nil } ?? "10"
                // Only attach the event ids whose closures the gesture actually has.
                let onChanged = g.contains(".onChanged") ? "\"dc\(h)\"" : "nil"
                let onEnded = g.contains(".onEnded") ? "\"de\(h)\"" : "nil"
                // CRITICAL (same dead-effect class as `.onTapGesture`): the renderer
                // dispatches the drag's `.point` translation, but the scalar-only guest
                // MutationRule grammar has NO point/value op to consume it → the drag does
                // NOTHING on device AND swallows the gesture from native content underneath.
                // No native-slot fallback for a `.gesture` modifier → demote the whole view.
                // BUG R2-#81: `.updating($state)` (the `@GestureState` form) carries a
                // handler the scalar guest grammar can't consume; without this it would
                // ship a dead drag that still SWALLOWS the gesture from native content.
                // Treat `.updating` like `.onChanged`/`.onEnded` → demote.
                if g.contains(".onChanged") || g.contains(".onEnded") || g.contains(".updating") {
                    // The drag's continuous `.point`/value the scalar-only guest can't consume —
                    // keep the WHOLE `.gesture(DragGesture()…)` NATIVE via a `nativeEffectSlot` (the
                    // thunk re-applies it verbatim over `self`, so the real drag runs) when the
                    // handlers are thunk-reachable. The rest of the view still OTA-patches. Only if
                    // not slottable do we demote.
                    if let slotID = tryRecordEffectSlot(call, name: "gesture") {
                        return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
                    }
                    hasUndispatchableEffect = true
                }
                return "\(base).dragGesture(minDistance: Double(\(minDist)), onChanged: \(onChanged), onEnded: \(onEnded))"
            }
            if g.hasPrefix("MagnifyGesture") || g.hasPrefix("MagnificationGesture") {
                // Magnify/rotate dispatch a `.double` the guest can't consume (no value op).
                // Keep the gesture NATIVE via a `nativeEffectSlot` when thunk-reachable; else demote.
                if let slotID = tryRecordEffectSlot(call, name: "gesture") {
                    return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
                }
                hasUndispatchableEffect = true
                return "\(base).magnifyGesture(event: \"mg\(h)\")"
            }
            if g.hasPrefix("RotateGesture") || g.hasPrefix("RotationGesture") {
                if let slotID = tryRecordEffectSlot(call, name: "gesture") {
                    return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
                }
                hasUndispatchableEffect = true
                return "\(base).rotateGesture(event: \"rg\(h)\")"
            }
            if g.hasPrefix("TapGesture") {
                // A `.gesture(TapGesture().onEnded { … })` is a discrete tap — route its
                // action through the SAME rule-recording path as the dedicated
                // `.onTapGesture` so a SIMPLE mutation dispatches in WASM (kept routing) and
                // a complex/undispatchable body demotes (rather than silently shipping a dead
                // tap, which the bare `onTapGesture(event:)` emission did before).
                let eid = "tap\(h)"
                // Extract the `.onEnded { … }` (or `.onChanged { … }`) action closure from the
                // gesture expression so its body can be parsed for a recordable mutation.
                let tapAction = Self.gestureActionClosure(call)
                let tapRecorded = recordActionMutation(tapAction, event: eid)
                // A non-empty unrecordable closure OR a function-ref action
                // (`.onEnded(handler)` — `gestureActionClosure` finds no closure, but the
                // gesture string carries `.onEnded`/`.onChanged`) is a dead tap → demote.
                let tapHasFunctionRef = tapAction == nil
                    && (g.contains(".onEnded") || g.contains(".onChanged"))
                let gtUndispatchable = !tapRecorded
                    && (!Self.actionClosureIsEmpty(tapAction) || tapHasFunctionRef)
                // BUG R2-#75 (gesture route): `TapGesture(count: 2)` is a multi-tap the IR
                // can't represent (lowers to a count-1 onTapGesture).
                let gtMultiTap = (Self.captureArg(g, "count").map { $0 != "1" } ?? false)
                if gtUndispatchable || gtMultiTap {
                    // Keep the `.gesture(TapGesture()…)` NATIVE via a `nativeEffectSlot` (the thunk
                    // re-applies it verbatim over `self`) when thunk-reachable — else demote.
                    if let slotID = tryRecordEffectSlot(call, name: "gesture") {
                        return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
                    }
                    hasUndispatchableEffect = true
                }
                return "\(base).onTapGesture(event: \"\(eid)\")"
            }
            return nil   // a composed / custom gesture stays native

        // MARK: Lifecycle
        case "onAppear":
            let eid = "appear\(Self.stableEventHash(call.trimmedDescription))"
            let apClosure = call.trailingClosure
                ?? args.first { $0.label?.text == "perform" }?.expression.as(ClosureExprSyntax.self)
            let apRecorded = recordActionMutation(apClosure, event: eid)
            // The renderer fires `d?.send(eid, .none)` on appear → a recorded simple
            // mutation runs in WASM (kept routing). A non-empty closure the guest can't
            // record (the typical `.onAppear { viewModel.load() }` / `Task { … }`), OR a
            // function-ref action (`.onAppear(perform: load)`), would fire the event but
            // match NO rule. INSTEAD of demoting the whole view, keep the effect NATIVE
            // via a `nativeEffectSlot` (the thunk re-applies `content.onAppear { … }` over
            // `self`) when the closure is thunk-reachable — so the REST of the view still
            // OTA-patches. Only if it can't be slotted do we demote.
            if !apRecorded
                && (!Self.actionClosureIsEmpty(apClosure) || modifierHasFunctionRefAction(call)) {
                if let slotID = tryRecordEffectSlot(call, name: "onAppear") {
                    return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
                }
                hasUndispatchableEffect = true
            }
            return "\(base).onAppear(event: \"\(eid)\")"
        case "onDisappear":
            let eid = "disappear\(Self.stableEventHash(call.trimmedDescription))"
            let dpClosure = call.trailingClosure
                ?? args.first { $0.label?.text == "perform" }?.expression.as(ClosureExprSyntax.self)
            let dpRecorded = recordActionMutation(dpClosure, event: eid)
            if !dpRecorded
                && (!Self.actionClosureIsEmpty(dpClosure) || modifierHasFunctionRefAction(call)) {
                if let slotID = tryRecordEffectSlot(call, name: "onDisappear") {
                    return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
                }
                hasUndispatchableEffect = true
            }
            return "\(base).onDisappear(event: \"\(eid)\")"
        case "onChange":
            // `.onChange(of: value) { ... }` — a state-watcher. The SDK renderer attaches NO
            // hook for the `onChange` IR node (it does `_ = e; return v`) and no host value-
            // watcher emits the `chg…` event, so the recorded-mutation guest path NEVER fires on
            // device. So a non-empty `.onChange` can't route via the GUEST. Instead we keep it
            // NATIVE via a `nativeEffectSlot` (the thunk re-applies the real `.onChange(of:
            // self.X) { … }` over the rendered subtree, where SwiftUI's own machinery fires it)
            // — but ONLY when the watched value `X` is NATIVE SOURCE-OF-TRUTH.
            guard let ofArg = arg("of") else { return nil }
            let key = Self.bareName(ofArg)
            let eid = "chg\(Self.stableEventHash(call.trimmedDescription))"
            let chgClosure = call.trailingClosure
            // An empty `.onChange { }` is a harmless no-op → keep the lowered passthrough node.
            if !Self.actionClosureIsEmpty(chgClosure) || modifierHasFunctionRefAction(call) {
                // FALSE-RENDER GATE (the #1 risk area). The watched value must be NATIVE
                // source-of-truth: the GUEST BODY must not mutate it. If it does (a recorded
                // dispatch rule writes that field), the guest owns the value and the writeback
                // round-trip into `self.X` would make a slotted native `.onChange(of: self.X)`
                // fire at an unproven time relative to the guest's own re-render — KEEP DEMOTED
                // (faithful firing needs a renderer value-watcher, a separate follow-on). When
                // the guest never mutates the watched field, native `self.X` is the sole source-
                // of-truth, so the real `.onChange(of: self.X) { … }` fires exactly on its real
                // change — identical to native. Capture the guest-mutated fields recorded by the
                // INNER body (already emitted, base-first) before deciding.
                let guestMutatedFields = Set(mutationRules.map(\.field))
                if !guestMutatedFields.contains(key),
                   let slotID = tryRecordEffectSlot(call, name: "onChange") {
                    // The whole `.onChange(of: self.X) { … }` runs natively over `self` — no
                    // guest dispatch rule (recording one would be a DEAD rule). The REST of the
                    // view lowers around it (vs. the old whole-view demote).
                    return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
                }
                // Guest-owned watched value, an un-reachable closure, or an animation-driving
                // effect → keep the conservative whole-view demote (the dev's native view runs).
                hasUndispatchableEffect = true
            }
            return "\(base).onChange(valueKey: \"\(key)\", event: \"\(eid)\")"
        case "onReceive":
            // `.onReceive(publisher) { value in … }` — fires when a NATIVE Combine publisher
            // (a member the thunk reads off `self`, e.g. a `Timer.publish(…)`) emits. There's no
            // guest analogue (the publisher + its subscription live natively), so the engine never
            // modeled an `onReceive` IR node — historically the WHOLE modified subtree slotted as
            // ONE opaque native leaf (faithful, but the inner content then didn't OTA-patch).
            // INSTEAD keep ONLY the `.onReceive` native via a `nativeEffectSlot` (the thunk re-
            // applies `content.onReceive(self.<pub>) { … }` over `self`, so the real publisher
            // event + its native closure run) — the REST of the view lowers around it. This is the
            // SAME fidelity contract as `.task`/`.onAppear` (a native effect closure over `self`):
            // no WATCHED-value gate (a publisher is an event source, not a guest-owned value), only
            // `tryRecordEffectSlot`'s thunk-reachability + animation-free gate. An EMPTY
            // `.onReceive { }` is a no-op (kept as a passthrough — no node, the base renders). When
            // it ISN'T slottable (a body-local publisher, an animation-driving closure) fall through
            // to nil → the whole expression slots as an opaque native leaf (the pre-change behavior,
            // still demote-safe — never a dropped/dead effect).
            let recvClosure = call.trailingClosure
                ?? args.first { $0.label?.text == "perform" }?.expression.as(ClosureExprSyntax.self)
            if Self.actionClosureIsEmpty(recvClosure) && !modifierHasFunctionRefAction(call) {
                return base
            }
            if let slotID = tryRecordEffectSlot(call, name: "onReceive") {
                return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
            }
            return nil
        case "task":
            // `.task { ... }` / `.task(id:) { ... }`.
            guard let taskClosure = call.trailingClosure else { return nil }
            let eid = "task\(Self.stableEventHash(call.trimmedDescription))"
            let idPiece = arg("id").map { ", id: \"\(Self.bareName($0))\"" } ?? ""
            // CRITICAL: `task` is the primary async data-load hook, but the engine NEVER
            // records a dispatch rule for it (and a Task body is never a scalar mutation
            // rule), so the renderer's `d?.send(eid,.none)` matches NO guest rule → the
            // body never runs → a data screen renders EMPTY. INSTEAD of demoting the whole
            // view, keep the `.task` NATIVE via a `nativeEffectSlot` (the thunk re-applies
            // `content.task { await self.load() }` over `self`, so the real async load runs)
            // when the closure is thunk-reachable — the REST of the view still OTA-patches.
            // Only if it can't be slotted do we demote. (An empty `.task { }` is kept.)
            if !Self.actionClosureIsEmpty(taskClosure) {
                if let slotID = tryRecordEffectSlot(call, name: "task") {
                    return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
                }
                hasUndispatchableEffect = true
            }
            return "\(base).task(event: \"\(eid)\"\(idPiece))"
        case "onSubmit":
            let eid = "submit\(Self.stableEventHash(call.trimmedDescription))"
            let smClosure = call.trailingClosure
            let smRecorded = recordActionMutation(smClosure, event: eid)
            // The renderer fires `d?.send(eid,.none)` on submit; a recorded simple mutation
            // dispatches. A non-empty unrecordable closure (`.onSubmit { search() }`) OR a
            // function-ref action (`.onSubmit(connect)` — the common form) fires the event but
            // matches no rule → dead. INSTEAD of demoting, keep the `.onSubmit` NATIVE via a
            // `nativeEffectSlot` (the thunk re-applies `content.onSubmit { … }` verbatim over
            // `self` — which ALSO preserves any `of:` trigger faithfully) when the closure is
            // thunk-reachable. Only if it can't be slotted do we demote. (`.onSubmit(connect)`
            // is a function ref — no closure body to slot — so it stays a demote.)
            if !smRecorded
                && (!Self.actionClosureIsEmpty(smClosure) || modifierHasFunctionRefAction(call)) {
                if let slotID = tryRecordEffectSlot(call, name: "onSubmit") {
                    return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
                }
                hasUndispatchableEffect = true
            }
            // BUG R2-#78: the `of:` submit-trigger is dropped — the IR `onSubmit(EventID)`
            // carries none and the renderer applies the default `.text` trigger. An
            // `.onSubmit(of: .search)` handler would fire on a TEXT-field submit instead of
            // the SEARCH field (wrong trigger). If `of:` is present and not `.text`, demote.
            // (A slottable `of:` was already kept native verbatim above — this only bites a
            // non-slottable onSubmit, e.g. an empty closure that fell through.)
            if let of = arg("of"), Self.bareEnumCase(of) != "text" {
                hasUndispatchableEffect = true
            }
            return "\(base).onSubmit(event: \"\(eid)\")"
        case "refreshable":
            // `.refreshable { await reload() }` — a pull-to-refresh async action the guest can't
            // re-run in WASM (and the IR/renderer models no refresh hook). Keep it NATIVE via a
            // `nativeEffectSlot` (the thunk re-applies `content.refreshable { … }` over `self`, so
            // the real refresh runs) when the closure is thunk-reachable — the REST of the view
            // still OTA-patches. An EMPTY `.refreshable { }` is a no-op (kept as a passthrough,
            // no slot). Not slottable → fall through to nil (the whole expression slots as a
            // native opaque leaf, the pre-change behavior — still demote-safe).
            let rfClosure = call.trailingClosure
                ?? args.first { $0.label == nil }?.expression.as(ClosureExprSyntax.self)
            if Self.actionClosureIsEmpty(rfClosure) { return base }
            if let slotID = tryRecordEffectSlot(call, name: "refreshable") {
                return "\(base).nativeEffectSlot(id: \"\(slotID)\")"
            }
            return nil
        case "onHover":
            let eid = "hover\(Self.stableEventHash(call.trimmedDescription))"
            // Same dead-effect class as `.onChange`: the renderer dispatches `.bool(hovering)`
            // but no guest rule consumes it (the hover closure's `(Bool)->Void` body isn't a
            // recordable scalar mutation) → the hover handler never fires. A non-empty closure
            // (or function-ref) demotes the view; an empty `.onHover { _ in }` is a no-op (kept).
            let hvClosure = call.trailingClosure
                ?? args.first { $0.label?.text == "perform" }?.expression.as(ClosureExprSyntax.self)
            if !Self.actionClosureIsEmpty(hvClosure) || modifierHasFunctionRefAction(call) {
                hasUndispatchableEffect = true
            }
            return "\(base).onHover(event: \"\(eid)\")"
        case "sensoryFeedback":
            // `.sensoryFeedback(.impact, trigger: value)` — kind enum + trigger key.
            guard let kind = enumArg(nil), let trig = arg("trigger") else { return nil }
            let key = Self.bareName(trig)
            // BUG #33/#61: the SDK renderer currently NO-OPs the haptic (`_ = kind; return v`),
            // so a lowered+auto-routed `.sensoryFeedback` is a DEAD effect (the haptic never
            // fires on device, though it does natively). Mark the view undispatchable so it
            // DEMOTES to native — where the real haptic fires — instead of shipping a dead effect.
            hasUndispatchableEffect = true
            return "\(base).sensoryFeedback(kind: \"\(kind)\", triggerKey: \"\(key)\")"

        // MARK: Animation
        case "animation":
            // `.animation(<anim>?, value: x)` — modern two-arg form only (the
            // deprecated single-arg `.animation(_)` is ambiguous and slots).
            guard let valueArg = arg("value") else { return nil }
            let key = Self.bareName(valueArg)
            let animRaw = firstUnlabeled() ?? "nil"
            let animLit = (animRaw == "nil") ? "nil" : Self.loweredAnimationOrNil(animRaw)
            guard let lit = animLit else { return nil }
            // BUG #62 (FIXED, IR v11): the SDK renderer now reconstitutes the real `Animation`
            // AND watches the watched-`@State`'s CURRENT scalar (resolved from the marshalled input
            // JSON into an `AnyHashable`, plumbed via `RenderContext.animationValues`) as the
            // `Equatable` trigger — a change to that value across renders fires the implicit
            // animation, matching native. So the view AUTO-ROUTES (no longer undispatchable). It
            // requires the v11 renderer (an older host NO-OPs the animation), so flag the view to
            // stamp its manifest `minVersion` 11 — an older host then DEMOTES it to native (where the
            // real animation runs) rather than rendering the value change instantly.
            usesAnimationValue = true
            return "\(base).animation(\(lit), valueKey: \"\(key)\")"
        case "transition":
            guard let t = firstUnlabeled(), let lit = Self.loweredTransitionOrNil(t) else { return nil }
            return "\(base).transition(\(lit))"

        case "contextMenu":
            // `.contextMenu { items }` — the long-press menu. Lower ONLY the
            // menu-items-builder form (Buttons auto-wire via the actionID path); the
            // `menuItems:preview:` overload (a preview subtree) or a bound
            // `forSelectionType:` form slots (nil). The whole node wraps the lowered
            // base content so the menu travels with it.
            guard call.additionalTrailingClosures.isEmpty,
                  args.allSatisfy({ $0.expression.is(ClosureExprSyntax.self) }) else { return nil }
            var items: [String] = []
            if let trailing = call.trailingClosure {
                items = emitActionItems(trailing.statements)
            } else {
                for arg in args {
                    if let c = arg.expression.as(ClosureExprSyntax.self) { items = emitActionItems(c.statements) }
                }
            }
            if items.isEmpty { return nil }
            return "N.contextMenu(content: [\(base)], items: \(nodeList(items)))"

        // MARK: Host-state — presentation (B.2)
        // Each owns a Bool flag the SDK binds; the binding's SET (incl. a system
        // swipe-dismiss) dispatches the event → the guest's UPDATE rule sets the
        // flag → re-emits. We record a `.setBool` rule keyed by the flag name so a
        // dismiss flips the guest's flag. ONLY the `isPresented:`-Bool form lowers;
        // an `item:` form whose body reads a body-local, or a binding we can't name,
        // slots. The content closure recurses (its action Buttons auto-wire).
        case "sheet":
            return emitPresentation(base, call: call, builder: "sheet")
        case "fullScreenCover":
            return emitPresentation(base, call: call, builder: "fullScreenCover")
        case "popover":
            return emitPresentation(base, call: call, builder: "popover")
        case "navigationDestination":
            // ONLY the `isPresented:`-Bool form (a `for:`-typed destination needs the
            // path registry → slot). Same Bool bridge as `.sheet`.
            guard arg("isPresented") != nil else { return nil }
            return emitPresentation(base, call: call, builder: "navigationDestination")
        case "alert":
            return emitAlert(base, call: call, builder: "alert")
        case "confirmationDialog":
            return emitAlert(base, call: call, builder: "confirmationDialog")

        // MARK: Host-state — navigation chrome / toolbar (B.2)
        case "toolbar":
            return emitToolbar(base, call: call)
        case "navigationBarTitleDisplayMode":
            guard let m = enumArg(nil) else { return nil }
            return ["automatic", "inline", "large"].contains(m)
                ? "\(base).navigationBarTitleDisplayMode(\"\(m)\")" : nil
        case "navigationBarBackButtonHidden":
            if args.isEmpty { return "\(base).navigationBarBackButtonHidden(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).navigationBarBackButtonHidden(\(b))"
        // NOTE: `.presentationDetents` / `.presentationDragIndicator` are DELIBERATELY NOT
        // lowered (they fall through to the unknown-modifier slot path). Lowering them as
        // IR modifiers regressed a real view (a real app's RemindersQuickSheet 44→43): keeping
        // the modified `ScrollView`'s base content lowered re-exposed a non-reconstructable
        // `@State` read (`pending: [UNNotificationRequest]`) that the previous whole-expression
        // slot subsumed — flipping the view from shipping to a build-time demote. These are
        // sheet-presentation modifiers with little OTA value; slotting them is demote-safe and
        // ships the view. Re-enable only with a root-caused fix that keeps the view lowering.
        case "navigationBarTitle":
            // Legacy `.navigationBarTitle("X"[, displayMode: .inline])`. Only a string
            // literal title lowers (a LocalizedStringKey computed title slots).
            guard let titleArg = firstUnlabeled(), titleArg.hasPrefix("\""), titleArg.hasSuffix("\"") else { return nil }
            let title = String(titleArg.dropFirst().dropLast())
            var mode = "automatic"
            if let m = enumArg("displayMode"), ["automatic", "inline", "large"].contains(m) { mode = m }
            return "\(base).navigationBarTitle(\"\(title)\", displayMode: \"\(mode)\")"
        case "navigationViewStyle":
            guard let s = enumArg(nil) else { return nil }
            // `.stack` / `.columns` / `.automatic` (the StackNavigationViewStyle() /
            // ColumnNavigationViewStyle() struct forms aren't `.case`s, so they slot).
            let known = ["stack", "columns", "automatic"]
            return known.contains(s) ? "\(base).navigationViewStyle(\"\(s)\")" : nil
        case "environment":
            // `.environment(\.<key>, <value>)` for a reconstructable key. The first
            // arg is a key-path (`\.layoutDirection`); the second is the value. An
            // `.environment(object)` form (one arg, no keypath) or an unrecognized
            // key/value slots (stays native).
            let unlabeled = args.filter { $0.label == nil }
            guard unlabeled.count == 2,
                  let kp = unlabeled.first?.expression.trimmedDescription,
                  kp.hasPrefix("\\."),
                  let valRaw = unlabeled.last?.expression.trimmedDescription else { return nil }
            let key = String(kp.dropFirst(2))   // "\.layoutDirection" → "layoutDirection"
            guard let value = Self.parseEnvironmentValue(key: key, raw: valRaw) else { return nil }
            return "\(base).environmentValue(key: \"\(key)\", value: \"\(value)\")"

        // MARK: Accessibility (G8)
        case "accessibilityLabel", "accessibilityHint", "accessibilityValue":
            // A simple string-LITERAL arg lowers (`Text(...)`-arg, interpolation, or a
            // computed/localized form slots — faithful over wrong). The original
            // literal is passed VERBATIM (it's already a valid Swift string literal),
            // so embedded escapes survive. Reject interpolation (`\(`).
            guard let arg0 = args.first(where: { $0.label == nil }),
                  let lit = arg0.expression.as(StringLiteralExprSyntax.self),
                  !lit.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) else { return nil }
            return "\(base).\(name)(\(lit.trimmedDescription))"
        case "accessibilityHidden":
            if args.isEmpty { return "\(base).accessibilityHidden(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).accessibilityHidden(\(b))"
        case "accessibilityAddTraits", "accessibilityRemoveTraits":
            // `.accessibilityAddTraits(.isButton)` / `([.isButton, .isHeader])`.
            guard let raw = firstUnlabeled(), let traits = Self.parseAccessibilityTraits(raw) else { return nil }
            return "\(base).\(name)(\"\(traits)\")"

        // MARK: Host-state — search / focus / list-editing (B.2 / B.1)
        case "searchable":
            // `.searchable(text: $query[, prompt: "…"])` — a system search bar bound
            // to the guest String field; filtering is guest body logic. On edit the
            // host dispatches `.string`; record a `.setString` rule.
            guard let b = eventArg(call, "text") else { return nil }
            record(event: b.event, field: b.value, op: .setString)
            var prompt = "nil"
            if let p = arg("prompt") {
                let t = p.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("\"") && t.hasSuffix("\"") { prompt = t } else { return nil }
            }
            let promptPiece = prompt == "nil" ? "" : ", prompt: \(prompt)"
            return "\(base).searchable(searchKey: \"\(b.value)\", query: \(b.value)\(promptPiece), event: \"\(b.event)\")"
        case "focused":
            // `.focused($field, equals: .token)` — binds the SDK-owned @FocusState to
            // the guest focus field. The first arg MUST be a `$`-projected binding
            // (`$field`); `equals:` must be an enum-raw/string-literal token the guest
            // reduces to a String. A non-binding first arg or non-literal token slots.
            guard let fb = call.arguments.first(where: { $0.label == nil }),
                  fb.expression.trimmedDescription.hasPrefix("$") else { return nil }
            let focusKey = bindingName(fb.expression)
            guard !focusKey.isEmpty else { return nil }
            let token: String
            if let eq = arg("equals"), let c = Self.bareEnumCase(eq) {
                token = c
            } else if let eq = arg("equals"), eq.hasPrefix("\""), eq.hasSuffix("\"") {
                token = String(eq.dropFirst().dropLast())
            } else {
                // BUG #32: the bare `.focused($bool)` form (no `equals:`) binds a Bool @FocusState.
                // The token path below would emit `isFocused: (focusKey == "true")` — a `Bool ==
                // String` guest TYPE ERROR that fails the whole module compile (recovered only by
                // the per-view bisect). Until Bool-focus is modeled end-to-end, DEMOTE the bare
                // form (slot → native, where `.focused($bool)` works) — build-safe = demote-safe.
                return nil
            }
            let eid = "focus\(Self.stableEventHash(call.trimmedDescription))"
            // The focus field is host-owned; the guest just stores the token string.
            record(event: eid, field: focusKey, op: .setString)
            return "\(base).focused(focusKey: \"\(focusKey)\", equals: \"\(token)\", isFocused: (\(focusKey) == \"\(token)\"), event: \"\(eid)\")"
        case "onDelete":
            // `.onDelete { offsets in … }` — the SDK ships the deleted offsets as
            // `.array([.int])`. But the guest's MutationRule system is SCALAR-ONLY (no
            // array-mutation rule exists), so the `del…` event matches NO rule → the
            // deletion is SILENTLY DROPPED on device: the row animates out then REAPPEARS
            // (the guest re-renders from unchanged state) — a data-integrity bug. There's no
            // native slot for a `.onDelete` modifier closure either, so the only correct
            // outcome is to DEMOTE the WHOLE view to native (the dev's real `.onDelete` then
            // applies the deletion). We still emit the node for shape; the view demotes.
            hasUndispatchableEffect = true
            let did = "del\(Self.stableEventHash(call.trimmedDescription))"
            return "\(base).onDelete(event: \"\(did)\")"
        case "onMove":
            // Same as `.onDelete`: the move ships as `.array([.int])` the scalar-only guest
            // can't apply → the reorder silently reverts. Demote to native.
            hasUndispatchableEffect = true
            let mid = "mov\(Self.stableEventHash(call.trimmedDescription))"
            return "\(base).onMove(event: \"\(mid)\")"

        // MARK: Visibility / chrome / declarative effects (modifier-coverage sweep v6)
        // Each lowers a declarative enum/bool/scalar/ColorRef/ShapeKind config — no
        // native closure or symbol — so it rides WASM and the renderer reapplies the
        // real modifier (OS-floor-guarded). An unrecognized form returns nil → slots.
        case "backgroundStyle":
            // `.backgroundStyle(<style>)` — a shape style (color / system color /
            // gradient / material / design-system TOKEN). Reuses the existing
            // `backgroundStyle(IRShapeStyle, in:)` IR/renderer. An unresolvable style slots.
            guard let s = firstUnlabeled(), let style = shapeStyleOrToken(s) else { return nil }
            return "\(base).background(\(style), in: nil)"
        case "hidden":
            return args.isEmpty ? "\(base).hidden()" : nil
        case "labelsHidden":
            return args.isEmpty ? "\(base).labelsHidden()" : nil
        case "labelsVisibility":
            guard let vis = enumArg(nil), ["automatic", "visible", "hidden"].contains(vis) else { return nil }
            return "\(base).labelsVisibility(\"\(vis)\")"
        case "menuIndicator":
            guard let vis = enumArg(nil), ["automatic", "visible", "hidden"].contains(vis) else { return nil }
            return "\(base).menuIndicator(\"\(vis)\")"
        case "menuOrder":
            guard let o = enumArg(nil), ["automatic", "fixed", "priority"].contains(o) else { return nil }
            return "\(base).menuOrder(\"\(o)\")"
        case "persistentSystemOverlays":
            guard let vis = enumArg(nil), ["automatic", "visible", "hidden"].contains(vis) else { return nil }
            return "\(base).persistentSystemOverlays(\"\(vis)\")"
        case "headerProminence":
            guard let p = enumArg(nil), ["standard", "increased"].contains(p) else { return nil }
            return "\(base).headerProminence(\"\(p)\")"
        case "badgeProminence":
            guard let p = enumArg(nil), ["standard", "increased", "decreased"].contains(p) else { return nil }
            return "\(base).badgeProminence(\"\(p)\")"
        case "listItemTint":
            // `.listItemTint(<color>)` — only the plain color form (a `.fixed`/
            // `.monochrome`/`.preferred` ListItemTint case isn't a ColorRef → slots).
            guard let c = firstUnlabeled() else { return nil }
            if c == "nil" { return "\(base).listItemTint(nil)" }
            guard let lc = Self.loweredColorOrNil(c) else { return nil }
            return "\(base).listItemTint(\(lc))"
        case "listRowSeparatorTint", "listSectionSeparatorTint":
            // `.listRowSeparatorTint(<color>[, edges: .all])` — a tint color + optional
            // VerticalEdge.Set. A nil color resets; a non-literal color slots.
            guard let c = firstUnlabeled() else { return nil }
            let edges = setArg("edges") ?? "all"
            if c == "nil" { return "\(base).\(name)(nil, edges: \"\(edges)\")" }
            guard let lc = Self.loweredColorOrNil(c) else { return nil }
            return "\(base).\(name)(\(lc), edges: \"\(edges)\")"
        case "containerShape":
            // `.containerShape(<shape>)` — a shape CONSTRUCTOR (`Capsule()`) OR a
            // leading-dot `Shape` static accessor (`.capsule`/`.rect`/`.circle`/
            // `.containerRelative`). A `RoundedRectangle(cornerRadius:)` rides too.
            guard let s = firstUnlabeled() else { return nil }
            if let shape = Self.loweredShapeKindOrNil(s) {
                return "\(base).containerShape(\(shape))"
            }
            if let shape = Self.dotShapeKindOrNil(s) {
                return "\(base).containerShape(\(shape))"
            }
            return nil
        case "compositingGroup":
            return args.isEmpty ? "\(base).compositingGroup()" : nil
        case "geometryGroup":
            return args.isEmpty ? "\(base).geometryGroup()" : nil
        case "drawingGroup":
            // `.drawingGroup([opaque:])` — colorMode/colorSpace default. Only `opaque`
            // (a bool literal) rides; a non-literal opaque slots.
            var opaque = "false"
            if let o = boolArg("opaque") { opaque = o }
            else if arg("opaque") != nil { return nil }
            return "\(base).drawingGroup(opaque: \(opaque))"
        case "colorMultiply":
            guard let c = firstUnlabeled(), let lc = Self.loweredColorOrNil(c) else { return nil }
            return "\(base).colorMultiply(\(lc))"
        case "luminanceToAlpha":
            return args.isEmpty ? "\(base).luminanceToAlpha()" : nil
        case "contentTransition":
            guard let t = enumArg(nil),
                  ["identity", "opacity", "interpolate", "numericText"].contains(t) else { return nil }
            return "\(base).contentTransition(\"\(t)\")"
        case "textSelection":
            // `.textSelection(.enabled)` / `.textSelection(.disabled)`.
            guard let s = enumArg(nil), ["enabled", "disabled"].contains(s) else { return nil }
            return "\(base).textSelection(\(s == "enabled"))"
        case "allowsTightening", "flipsForRightToLeftLayoutDirection":
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).\(name)(\(b))"
        case "invalidatableContent":
            if args.isEmpty { return "\(base).invalidatableContent(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).invalidatableContent(\(b))"
        case "defaultScrollAnchor":
            // `.defaultScrollAnchor(.top)` / `(.center)` / `(.bottom)` — a named UnitPoint.
            // A custom `UnitPoint(x:y:)` slots (we only lower the named cases).
            guard let raw = firstUnlabeled(), let u = Self.bareEnumCase(raw),
                  Self.knownUnitPoints.contains(u) else { return nil }
            return "\(base).defaultScrollAnchor(.\(u))"
        case "selectionDisabled":
            if args.isEmpty { return "\(base).selectionDisabled(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).selectionDisabled(\(b))"
        case "moveDisabled", "deleteDisabled":
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).\(name)(\(b))"

        // MARK: Accessibility / help / a11y-config (modifier-coverage sweep v7)
        // Each lowers a declarative string/bool/scalar config — no native closure or
        // symbol — so it rides WASM and the renderer reapplies the real modifier
        // (OS-floor-guarded). An unrecognized form returns nil → slots.
        case "help":
            // `.help("Tooltip")` — only a STRING-LITERAL (a LocalizedStringKey literal)
            // lowers; a computed string slots (it can't ride as data).
            guard let s = firstUnlabeled(),
                  firstUnlabeledExprIsStringLiteral() else { return nil }
            return "\(base).help(\(s))"
        case "accessibilityIdentifier":
            guard let s = firstUnlabeled(), firstUnlabeledExprIsStringLiteral() else { return nil }
            return "\(base).accessibilityIdentifier(\(s))"
        case "accessibilitySortPriority":
            guard let d = firstUnlabeled(), Self.isNumericLiteral(d) else { return nil }
            return "\(base).accessibilitySortPriority(\(d))"
        case "accessibilityRespondsToUserInteraction":
            if args.isEmpty { return "\(base).accessibilityRespondsToUserInteraction(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).accessibilityRespondsToUserInteraction(\(b))"
        case "accessibilityIgnoresInvertColors":
            if args.isEmpty { return "\(base).accessibilityIgnoresInvertColors(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).accessibilityIgnoresInvertColors(\(b))"
        case "privacySensitive":
            if args.isEmpty { return "\(base).privacySensitive(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).privacySensitive(\(b))"
        case "speechAlwaysIncludesPunctuation", "speechSpellsOutCharacters",
             "speechAnnouncementsQueued":
            if args.isEmpty { return "\(base).\(name)(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).\(name)(\(b))"
        case "speechAdjustedPitch":
            guard let d = firstUnlabeled(), Self.isNumericLiteral(d) else { return nil }
            return "\(base).speechAdjustedPitch(\(d))"

        // MARK: Text / symbol / input config (sweep v7)
        case "scrollDismissesKeyboard":
            guard let m = enumArg(nil),
                  ["automatic", "immediately", "interactively", "never"].contains(m) else { return nil }
            return "\(base).scrollDismissesKeyboard(\"\(m)\")"
        case "fontWidth":
            guard let w = enumArg(nil),
                  ["compressed", "condensed", "expanded", "standard"].contains(w) else { return nil }
            return "\(base).fontWidth(\"\(w)\")"
        case "textScale":
            guard let s = enumArg(nil), ["default", "secondary"].contains(s) else { return nil }
            return "\(base).textScale(\"\(s)\")"
        case "symbolEffectsRemoved":
            if args.isEmpty { return "\(base).symbolEffectsRemoved(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).symbolEffectsRemoved(\(b))"
        case "findDisabled", "replaceDisabled":
            if args.isEmpty { return "\(base).\(name)(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).\(name)(\(b))"
        case "statusBarHidden":
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).statusBarHidden(\(b))"
        case "contentShape":
            // `.contentShape(<shape>[, eoFill: <bool>])` — a standard `ShapeKind`. The
            // `.contentShape(.interaction, <shape>)`/`kind:` overload (a leading enum kind)
            // slots (we only lower the single-shape form). A non-literal eoFill slots.
            guard let s = firstUnlabeled() else { return nil }
            var shapeExpr: String? = nil
            if let shape = Self.loweredShapeKindOrNil(s) { shapeExpr = shape }
            else if let shape = Self.dotShapeKindOrNil(s) { shapeExpr = shape }
            guard let shape = shapeExpr else { return nil }
            var eoFill = "false"
            if let e = boolArg("eoFill") { eoFill = e }
            else if arg("eoFill") != nil { return nil }
            return "\(base).contentShape(\(shape), eoFill: \(eoFill))"
        case "coordinateSpace":
            // `.coordinateSpace(.named("grid"))` — only the NAMED form lowers (a string).
            // The deprecated `.coordinateSpace(name:)` form + `.local`/`.global` slot.
            guard let raw = firstUnlabeled(),
                  let nm = Self.namedCoordinateSpaceString(raw) else { return nil }
            return "\(base).coordinateSpaceNamed(\(nm))"

        // MARK: Presentation config (sweep v7)
        case "interactiveDismissDisabled":
            if args.isEmpty { return "\(base).interactiveDismissDisabled(true)" }
            guard let b = firstUnlabeled(), b == "true" || b == "false" else { return nil }
            return "\(base).interactiveDismissDisabled(\(b))"
        case "presentationCornerRadius":
            guard let d = firstUnlabeled(), Self.isNumericLiteral(d) else { return nil }
            return "\(base).presentationCornerRadius(\(d))"
        case "presentationContentInteraction":
            guard let m = enumArg(nil),
                  ["automatic", "resizes", "scrolls"].contains(m) else { return nil }
            return "\(base).presentationContentInteraction(\"\(m)\")"
        case "presentationCompactAdaptation":
            // `.presentationCompactAdaptation(.popover)` (single-arg form). The
            // `(horizontal:vertical:)` two-arg form slots.
            guard args.count == 1, let m = enumArg(nil),
                  ["automatic", "none", "popover", "sheet", "fullScreenCover"].contains(m) else { return nil }
            return "\(base).presentationCompactAdaptation(\"\(m)\")"

        default:
            return nil
        }
    }

    /// Lower a Bool-presentation modifier (`.sheet`/`.fullScreenCover`/`.popover`/
    /// `.navigationDestination(isPresented:)`). Extracts the `isPresented: $flag`
    /// binding → the flag field/event, records a `.setBool` rule (so a dismiss flips
    /// the guest flag), and lowers the content closure. Returns nil (→ slot) for an
    /// `item:` form or a binding we can't name.
    private mutating func emitPresentation(_ base: String, call: FunctionCallExprSyntax,
                                           builder: String) -> String? {
        let args = call.arguments
        // The `item:` form (an Optional-token binding) needs the item value marshalled
        // into the content; if the content reads a body-local item it can't slot-render
        // either — keep it native for now (honest limit). Only `isPresented:` lowers.
        guard let presented = args.first(where: { $0.label?.text == "isPresented" }) else {
            return nil
        }
        let flag = bindingName(presented.expression)
        guard !flag.isEmpty, presented.expression.trimmedDescription.hasPrefix("$") else { return nil }
        // The content closure (the presented body).
        var content: [String] = []
        if let trailing = call.trailingClosure {
            content = emitItems(trailing.statements)
        } else {
            for arg in args where arg.label?.text == "content" {
                if let c = arg.expression.as(ClosureExprSyntax.self) { content = emitItems(c.statements) }
            }
        }
        guard !content.isEmpty else { return nil }
        let eid = "pres\(Self.stableEventHash(call.trimmedDescription))"
        // A dismiss (system or button) sets the flag from the dispatched Bool.
        record(event: eid, field: flag, op: .setBool)
        switch builder {
        case "sheet":
            return "\(base).sheet(presentedKey: \"\(flag)\", isPresented: \(flag), event: \"\(eid)\", \(nodeList(content)))"
        case "fullScreenCover":
            return "\(base).fullScreenCover(presentedKey: \"\(flag)\", isPresented: \(flag), event: \"\(eid)\", \(nodeList(content)))"
        case "popover":
            return "\(base).popover(presentedKey: \"\(flag)\", isPresented: \(flag), event: \"\(eid)\", \(nodeList(content)))"
        case "navigationDestination":
            return "\(base).navigationDestination(presentedKey: \"\(flag)\", isPresented: \(flag), event: \"\(eid)\", \(nodeList(content)))"
        default:
            return nil
        }
    }

    /// Lower `.alert(title, isPresented: $flag) { actions } message: { message }` and
    /// `.confirmationDialog(...)`. The title must be a string literal; the actions/
    /// message closures recurse (action Buttons auto-wire, incl. `Button(role:)`).
    private mutating func emitAlert(_ base: String, call: FunctionCallExprSyntax,
                                    builder: String) -> String? {
        let args = call.arguments
        guard let titled = args.first(where: { $0.label == nil }),
              titled.expression.as(StringLiteralExprSyntax.self) != nil else { return nil }
        let title = titled.expression.trimmedDescription
        guard let presented = args.first(where: { $0.label?.text == "isPresented" }) else { return nil }
        let flag = bindingName(presented.expression)
        guard !flag.isEmpty, presented.expression.trimmedDescription.hasPrefix("$") else { return nil }
        // Actions: the leading trailing closure (or `actions:`); message: the
        // `message:` additional-trailing-closure / arg.
        var actions: [String] = []
        var message: [String] = []
        // Actions lower in the ACTIONS-LIST context (an undispatchable Button there demotes
        // the view — the renderer can't slot a native control into the alert's button list).
        if let trailing = call.trailingClosure {
            actions = emitActionItems(trailing.statements)
        }
        for add in call.additionalTrailingClosures {
            if add.label.text == "message" { message = emitItems(add.closure.statements) }
            else if add.label.text == "actions" { actions = emitActionItems(add.closure.statements) }
        }
        for arg in args {
            guard let lbl = arg.label?.text, let c = arg.expression.as(ClosureExprSyntax.self) else { continue }
            if lbl == "actions" { actions = emitActionItems(c.statements) }
            else if lbl == "message" { message = emitItems(c.statements) }
        }
        guard !actions.isEmpty else { return nil }
        let eid = "alert\(Self.stableEventHash(call.trimmedDescription))"
        record(event: eid, field: flag, op: .setBool)
        if builder == "confirmationDialog" {
            var tv = "automatic"
            if let raw = arg2(call, "titleVisibility"), let c = Self.bareEnumCase(raw) { tv = c }
            return "\(base).confirmationDialog(\(title), titleVisibility: \"\(tv)\", presentedKey: \"\(flag)\", isPresented: \(flag), event: \"\(eid)\", actions: \(nodeList(actions)), message: \(nodeList(message)))"
        }
        return "\(base).alert(\(title), presentedKey: \"\(flag)\", isPresented: \(flag), event: \"\(eid)\", actions: \(nodeList(actions)), message: \(nodeList(message)))"
    }

    /// Lower `.toolbar { ToolbarItem(placement:) { content } … }` (the items-builder
    /// form). Each `ToolbarItem`/`ToolbarItemGroup` statement → an `IRToolbarItem`.
    /// A bare-content toolbar (`.toolbar { Button(...) }`) defaults to `.automatic`.
    /// A `for:`/visibility toolbar form, or a non-Item statement, slots (nil).
    private mutating func emitToolbar(_ base: String, call: FunctionCallExprSyntax) -> String? {
        guard call.additionalTrailingClosures.isEmpty,
              call.arguments.allSatisfy({ $0.expression.is(ClosureExprSyntax.self) }) else { return nil }
        var closure: ClosureExprSyntax?
        if let trailing = call.trailingClosure { closure = trailing }
        else { closure = call.arguments.first?.expression.as(ClosureExprSyntax.self) }
        guard let body = closure else { return nil }
        // Toolbar content is an ACTIONS-LIST context: a bare `.toolbar { Button { … } }` puts
        // its Buttons in the toolbar's item list, where the renderer can't attach a native
        // slot — an undispatchable Button there must demote the view, not ship dead.
        let savedActionCtx = inActionListContext
        inActionListContext = true
        defer { inActionListContext = savedActionCtx }
        var items: [String] = []
        for item in body.statements {
            guard case .expr(let e) = item.item else { return nil }
            if let toolItem = emitToolbarItem(e) {
                items.append(toolItem)
            } else if Self.isToolbarItemCall(e) {
                // BUG R2-#116: it IS a ToolbarItem(Group) but `emitToolbarItem` declined
                // (an unrecognized/computed placement, or unlowerable content). SLOT the
                // whole toolbar so the real placement is preserved natively — never
                // silently collapse the control into the system-default `.automatic` slot.
                return nil
            } else {
                // A bare content view (not a ToolbarItem) → an automatic-placement item.
                let node = emitExpr(e)
                items.append("IRToolbarItem(placement: \"automatic\", content: [\(node)])")
            }
        }
        guard !items.isEmpty else { return nil }
        return "\(base).toolbar(items: [\(items.joined(separator: ", "))])"
    }

    /// Parse a `ToolbarItem(placement: .x) { content }` / `ToolbarItemGroup(...)`
    /// statement into an `IRToolbarItem(...)` literal, else nil.
    private mutating func emitToolbarItem(_ expr: ExprSyntax) -> String? {
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
              callee.baseName.text == "ToolbarItem" || callee.baseName.text == "ToolbarItemGroup" else {
            return nil
        }
        var placement = "automatic"
        if let p = call.arguments.first(where: { $0.label?.text == "placement" }) {
            // BUG R2-#116: a PRESENT placement that isn't a bare case (a computed var, a
            // payload expression) must NOT silently default to `.automatic` (wrong bar
            // position) — decline so the caller slots the whole toolbar natively.
            guard let c = Self.bareEnumCase(p.expression.trimmedDescription) else { return nil }
            placement = c
        }
        var content: [String] = []
        if let trailing = call.trailingClosure { content = emitItems(trailing.statements) }
        guard !content.isEmpty else { return nil }
        return "IRToolbarItem(placement: \"\(placement)\", content: \(nodeList(content)))"
    }

    /// True iff `expr` is a `ToolbarItem(...)` / `ToolbarItemGroup(...)` call.
    static func isToolbarItemCall(_ expr: ExprSyntax) -> Bool {
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) else { return false }
        return callee.baseName.text == "ToolbarItem" || callee.baseName.text == "ToolbarItemGroup"
    }

    /// Capture a labeled argument's value as a trimmed source string (a small helper
    /// for the host-state emitters; mirrors the `arg(_:)` local closure shape).
    private func arg2(_ call: FunctionCallExprSyntax, _ label: String) -> String? {
        call.arguments.first { $0.label?.text == label }?.expression.trimmedDescription
    }

    /// The built-in `Font.TextStyle` cases (the ONLY named styles that map to a real
    /// adaptive `IRFont(style:)`). A `.font(.title)` lowers; a `.font(Theme.Font.x)`
    /// does NOT (it's a design-system token — the caller routes it to a font token).
    static let knownFontStyles: Set<String> = [
        "largeTitle", "title", "title2", "title3", "headline", "subheadline",
        "body", "callout", "footnote", "caption", "caption2"
    ]

    /// `.title` -> `IRFont(style: .title)`; `.system(size:18,weight:.bold)` parsed.
    /// Returns nil for ANYTHING ELSE (a design-system token like `Theme.Font.body(…)`,
    /// a custom font, a `Font.custom("…")`) so the caller can route it to a host font
    /// TOKEN or slot — NEVER emits an invalid `IRFont(style: .<garbage>)` (which used to
    /// fail the whole guest module compile).
    /// The closed `IRFont.Weight` case set — a weight outside it (e.g. a custom
    /// `extension Font.Weight` case) is not a member and would break guest compile,
    /// so a non-member weight must slot instead of lowering.
    static let irFontWeightCases: Set<String> = [
        "ultraLight", "thin", "light", "regular", "medium",
        "semibold", "bold", "heavy", "black",
    ]
    /// The closed `IRFont.Design` case set.
    static let irFontDesignCases: Set<String> = ["default", "serif", "rounded", "monospaced"]

    static func loweredFontOrNil(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix(".system") || s.hasPrefix("Font.system") || s.hasPrefix("SwiftUI.Font.system") {
            guard let argsStr = systemFontArgs(s) else { return nil }
            return "IRFont(\(argsStr))"
        }
        // A bare named text style (`.title`, `Font.title`) → the adaptive style. Reject
        // any further nesting (`.title.bold()`) or a non-built-in name (a token).
        if let style = Self.bareEnumCase(s), Self.knownFontStyles.contains(style) {
            return "IRFont(style: .\(style))"
        }
        return nil
    }

    /// Like the static `loweredFontOrNil`'s `.system` branch, but routes the `size:` arg
    /// through the instance `numericOrToken` so an OUT-OF-SCOPE numeric size — a computed-
    /// member-on-input read (`.system(size: size.iconSize)`), a design-system numeric token —
    /// host-projects to a `__numtok_<id>` the guest binds, instead of leaking the free
    /// identifier. Returns nil when it isn't a `.system(...)` font OR the size arg is neither
    /// guest-resolvable nor a resolvable token (then the caller falls back to the static
    /// lowering / a font token / a slot). `weight`/`design` are kept as-is (enum literals).
    private mutating func loweredSystemFontOrNil(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix(".system") || s.hasPrefix("Font.system")
                || s.hasPrefix("SwiftUI.Font.system") else { return nil }
        guard let rawSize = Self.capture(s, after: "size:") else { return nil }
        // Only do the work when the size ISN'T already guest-resolvable as written (the static
        // path handles that). A resolvable literal/marshalled-input size goes the static way.
        let asWritten = SwiftUIGuestScopeCheck.check(
            guestBody: rawSize, inputNames: guestResolvableNames, usesGeometry: usesGeometry)
        if asWritten.isCompilable { return nil }
        guard let sizeExpr = numericOrToken(rawSize) else { return nil }
        var parts = ["size: Double(\(sizeExpr))"]
        if let weight = Self.capture(s, after: "weight:") {
            guard let w = Self.bareEnumCase(weight), Self.irFontWeightCases.contains(w) else { return nil }
            parts.append("weight: .\(w)")
        }
        if let design = Self.capture(s, after: "design:") {
            guard let d = Self.bareEnumCase(design), Self.irFontDesignCases.contains(d) else { return nil }
            parts.append("design: .\(d)")
        }
        return "IRFont(\(parts.joined(separator: ", ")))"
    }

    static func systemFontArgs(_ s: String) -> String? {
        var parts: [String] = []
        if let size = capture(s, after: "size:") { parts.append("size: Double(\(size))") }
        if let weight = capture(s, after: "weight:") {
            // weight/design must be closed-enum members; a custom Font.Weight/Design
            // would break guest compile, so a non-member fails the whole `.system` lowering.
            guard let w = bareEnumCase(weight), irFontWeightCases.contains(w) else { return nil }
            parts.append("weight: .\(w)")
        }
        if let design = capture(s, after: "design:") {
            guard let d = bareEnumCase(design), irFontDesignCases.contains(d) else { return nil }
            parts.append("design: .\(d)")
        }
        return parts.joined(separator: ", ")
    }

    static func capture(_ s: String, after key: String) -> String? {
        guard let r = s.range(of: key) else { return nil }
        let rest = s[r.upperBound...]
        let token = rest.prefix { $0 != "," && $0 != ")" }
        let t = token.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    static func loweredColor(_ src: String) -> String {
        Self.loweredColorOrNil(src) ?? ".named(\"primary\")"
    }

    /// Map a color expression to an IR `ColorRef` when it's either a recognized
    /// system-palette name (`.red`, `Color.blue`, `.primary`, …) → `.named(...)`,
    /// OR a literal `Color(red:green:blue:[opacity:])` → `.rgba(...)` (IR v2; the
    /// renderer already renders `.rgba`). Returns nil for anything else — an asset
    /// color, a gradient, a view — so the caller renders it NATIVELY (faithful) via
    /// a mixed-view slot instead of silently substituting the wrong color.
    static func loweredColorOrNil(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        // `Color(red:green:blue:[opacity:])` → an explicit RGBA `ColorRef`.
        if s.hasPrefix("Color("), let rgba = Self.loweredRGBAColorOrNil(s) {
            return rgba
        }
        let name: String
        if s.hasPrefix("Color.") { name = String(s.dropFirst("Color.".count)) }
        else if s.hasPrefix(".") { name = String(s.dropFirst()) }
        else { return nil }
        // Reject anything with further member access / call (e.g. `.red.opacity(0.5)`).
        guard Self.knownColorNames.contains(name) else { return nil }
        return ".named(\"\(name)\")"
    }

    /// Parse a `Color(red:green:blue:[opacity:])` source string into an IR
    /// `.rgba(IRColor(...))` literal. Each component must be a plain numeric literal
    /// (the common case); a computed/non-literal component returns nil so the color
    /// slots natively (faithful). `opacity` defaults to 1.
    static func loweredRGBAColorOrNil(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("Color("), s.hasSuffix(")") else { return nil }
        // A `Color(.sRGB, red:…)`/`Color("asset")`/`Color(uiColor:)` form isn't the
        // plain RGBA initializer — require all three of red/green/blue to be present.
        guard let r = captureArg(s, "red"), let g = captureArg(s, "green"),
              let b = captureArg(s, "blue") else { return nil }
        guard isNumericLiteral(r), isNumericLiteral(g), isNumericLiteral(b) else { return nil }
        let a = captureArg(s, "opacity")
        if let a, !isNumericLiteral(a) { return nil }
        let alpha = a ?? "1"
        return ".rgba(IRColor(r: Double(\(r)), g: Double(\(g)), b: Double(\(b)), a: Double(\(alpha))))"
    }

    /// Build an `IREdgeInsets(...)` literal from a dotless `Edge.Set` string (as
    /// produced by `parseSetLiteral` — "horizontal" / "vertical" / "top" / "all" /
    /// "top+bottom") applying `length` (a numeric literal string) to the named edges.
    /// Returns nil if any token isn't a recognized edge/`horizontal`/`vertical`/`all`.
    static func edgeSetInsets(_ edges: String, length: String) -> String? {
        var top = "0", leading = "0", bottom = "0", trailing = "0"
        for token in edges.split(separator: "+").map(String.init) {
            switch token {
            case "all": top = length; leading = length; bottom = length; trailing = length
            case "horizontal": leading = length; trailing = length
            case "vertical": top = length; bottom = length
            case "top": top = length
            case "bottom": bottom = length
            case "leading": leading = length
            case "trailing": trailing = length
            default: return nil
            }
        }
        return "IREdgeInsets(top: Double(\(top)), leading: Double(\(leading)), "
            + "bottom: Double(\(bottom)), trailing: Double(\(trailing)))"
    }

    /// Parse the value of a reconstructable `.environment(\.<key>, <value>)`. Returns
    /// the wire value string, or nil (the whole modifier slots) for an unknown key or
    /// a non-literal value:
    ///   layoutDirection: `.rightToLeft`/`.leftToRight`
    ///   colorScheme:     `.dark`/`.light`
    ///   locale:          `Locale(identifier: "he")` → "he" (a string-literal id only)
    static func parseEnvironmentValue(key: String, raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        switch key {
        case "layoutDirection":
            guard let c = bareEnumCase(s), c == "rightToLeft" || c == "leftToRight" else { return nil }
            return c
        case "colorScheme":
            guard let c = bareEnumCase(s), c == "dark" || c == "light" else { return nil }
            return c
        case "locale":
            // `Locale(identifier: "he")` — extract the string-literal identifier.
            guard s.hasPrefix("Locale("), let id = captureArg(s, "identifier"),
                  id.hasPrefix("\""), id.hasSuffix("\"") else { return nil }
            return String(id.dropFirst().dropLast())
        default:
            return nil
        }
    }

    /// The accessibility trait names we can reconstitute on-device.
    static let knownAccessibilityTraits: Set<String> = [
        "isButton", "isHeader", "isSelected", "isImage", "isLink", "isSearchField",
        "isStaticText", "isToggle", "isModal", "isSummaryElement", "updatesFrequently",
        "playsSound", "startsMediaSession", "allowsDirectInteraction", "causesPageTurn"
    ]

    /// Parse `.isButton` or `[.isButton, .isHeader]` → "isButton" / "isButton+isHeader".
    /// Returns nil (slots) if any trait isn't in the known set.
    static func parseAccessibilityTraits(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        var names: [String] = []
        if s.hasPrefix("["), s.hasSuffix("]") {
            let inner = String(s.dropFirst().dropLast())
            for part in inner.split(separator: ",") {
                guard let c = bareEnumCase(String(part)) else { return nil }
                names.append(c)
            }
        } else if let c = bareEnumCase(s) {
            names.append(c)
        } else {
            return nil
        }
        guard !names.isEmpty, names.allSatisfy({ knownAccessibilityTraits.contains($0) }) else { return nil }
        return names.joined(separator: "+")
    }

    /// Parse a `.page` / `.page(<modeLabel>: .never|.always)` / `.automatic`
    /// tab/index view-page style. Returns "automatic" | "page" | "page.always" |
    /// "page.never". A custom style (`MyStyle()`) or unrecognized form returns nil.
    static func parsePageStyle(_ raw: String, modeLabel: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s == ".automatic" { return "automatic" }
        if s == ".page" || s == ".page()" { return "page" }
        if s.hasPrefix(".page(") {
            if let mode = captureArg(s, modeLabel), let c = bareEnumCase(mode) {
                if c == "always" { return "page.always" }
                if c == "never" { return "page.never" }
                if c == "automatic" { return "page" }
            }
            // `.page(...)` with an arg we don't recognize → treat as the default page.
            return "page"
        }
        return nil
    }

    /// Parse an `EdgeInsets(top:leading:bottom:trailing:)` literal expression to an
    /// `IREdgeInsets(...)` literal. Each component must be a numeric literal (a
    /// missing component defaults to 0; SwiftUI requires all four, but we tolerate
    /// fewer). A non-literal component or a non-`EdgeInsets` expression returns nil.
    static func parseEdgeInsetsLiteral(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("EdgeInsets(") else { return nil }
        func comp(_ label: String) -> String {
            guard let raw = captureArg(s, label), isNumericLiteral(raw) else { return "0" }
            return raw
        }
        // Reject if any present labeled value is non-numeric (would silently drop it).
        for label in ["top", "leading", "bottom", "trailing"] {
            if let raw = captureArg(s, label), !isNumericLiteral(raw) { return nil }
        }
        return "IREdgeInsets(top: Double(\(comp("top"))), leading: Double(\(comp("leading"))), "
            + "bottom: Double(\(comp("bottom"))), trailing: Double(\(comp("trailing"))))"
    }

    /// Map a `.frame` flexible bound expression to an `IRLength` literal:
    /// `.infinity`/`CGFloat.infinity` → `.infinity`; a numeric literal → `.points(...)`.
    /// A non-literal/unsupported bound returns nil (the whole frame slots).
    static func loweredIRLengthOrNil(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        if s == ".infinity" || s.hasSuffix(".infinity") { return ".infinity" }
        if isNumericLiteral(s) { return ".points(Double(\(s)))" }
        return nil
    }

    /// Map a shape constructor expression (for `.clipShape`) to a `ShapeKind`
    /// literal. Mirrors the shape constructors `emitConstructor` recognizes.
    static func loweredShapeKindOrNil(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("Circle(") { return ".circle" }
        if s.hasPrefix("Capsule(") { return ".capsule" }
        if s.hasPrefix("Rectangle(") { return ".rectangle" }
        if s.hasPrefix("Ellipse(") { return ".ellipse" }
        if s.hasPrefix("RoundedRectangle(") {
            let r = captureArg(s, "cornerRadius") ?? "0"
            return ".roundedRectangle(cornerRadius: Double(\(r)))"
        }
        return nil
    }

    /// A leading-dot `Shape` static accessor (used by `.containerShape(.capsule)` —
    /// the `Shape`/`ContainerShape` protocol exposes `.rect`/`.capsule`/`.circle`/
    /// `.ellipse`/`.containerRelative` statics). A `.rect(cornerRadius:)` payload form
    /// lowers when the radius is a numeric literal; everything else → nil (slots).
    static func dotShapeKindOrNil(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        switch s {
        case ".circle": return ".circle"
        case ".capsule": return ".capsule"
        case ".rect", ".rectangle": return ".rectangle"
        case ".ellipse": return ".ellipse"
        case ".containerRelative": return ".containerRelative"
        default: break
        }
        if s.hasPrefix(".rect(") || s.hasPrefix(".rect (") {
            if let r = captureArg(s, "cornerRadius"), isNumericLiteral(r) {
                return ".roundedRectangle(cornerRadius: Double(\(r)))"
            }
            return nil
        }
        return nil
    }

    /// `.named("grid")` / `CoordinateSpace.named("grid")` → the STRING-LITERAL source
    /// (`"grid"`) for a `.coordinateSpace(.named(_:))`. Only a string-literal name lowers
    /// (it rides the wire as data); `.local`/`.global` (SwiftUI defaults, no modifier) and
    /// a computed/non-literal name return nil → the modifier slots.
    static func namedCoordinateSpaceString(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        let parsed = Parser.parse(source: "let __cs = (\(s))")
        guard let value = parsed.statements.first?.item.as(VariableDeclSyntax.self)?
                .bindings.first?.initializer?.value,
              let inner = (value.as(TupleExprSyntax.self)?.elements.first?.expression) ?? value.as(FunctionCallExprSyntax.self).map({ ExprSyntax($0) }),
              let call = inner.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
              callee.declName.baseName.text == "named",
              call.arguments.count == 1, let only = call.arguments.first, only.label == nil,
              let lit = only.expression.as(StringLiteralExprSyntax.self),
              stringLiteralIsPlain(lit) else { return nil }
        return only.expression.trimmedDescription
    }

    // MARK: Modifier-surface parsers (IRShapeStyle / unit-point / animation / etc.)

    /// `$x`/`store.count` → a stable, escaped bare key for a `valueKey:`/`id:`
    /// string. Strips a leading `$`; keeps the rest verbatim (member paths are a
    /// fine stable key). Quotes/newlines are escaped so it's literal-safe.
    static func bareName(_ src: String) -> String {
        var s = src.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("$") { s.removeFirst() }
        return safeLabel(s)
    }

    /// A leading-dot enum case (`.bottom`, `Edge.bottom`, `.impact`) → "bottom".
    /// Returns nil for a case WITH a payload/call (`.fraction(0.5)`), a STRUCT
    /// instance (`MyStyle()`), or any expression with further nesting — exactly the
    /// honest "only built-in named cases lower" boundary.
    // The closed IR alignment enums (must stay in sync with IRAlignment /
    // IRHorizontalAlignment / IRVerticalAlignment in ViewNode.swift). Used by the
    // allowlist guards below (BUG #63 class) so a non-IR alignment guide
    // (`.firstTextBaseline` in an `Alignment` slot, a custom `extension Alignment`
    // guide) SLOTS the node natively instead of emitting an invalid enum case that
    // fails the guest WASM compile.
    static let irAlignmentCases: Set<String> = [
        "leading", "center", "trailing", "top", "bottom",
        "topLeading", "topTrailing", "bottomLeading", "bottomTrailing",
    ]
    static let irVerticalAlignmentCases: Set<String> = [
        "top", "center", "bottom", "firstTextBaseline", "lastTextBaseline",
    ]
    static let irHorizontalAlignmentCases: Set<String> = ["leading", "center", "trailing"]

    /// Validate an `Alignment` expression against the 9 IRAlignment cases; returns the
    /// bare case (e.g. "topLeading") or nil (the caller must slot/omit) — never an
    /// unvalidated case that would fail the guest compile.
    static func loweredAlignmentOrNil(_ raw: String) -> String? {
        guard let c = bareEnumCase(raw), irAlignmentCases.contains(c) else { return nil }
        return c
    }
    /// Validate a `VerticalAlignment` (GridRow / H-stack) against its 5 IR cases.
    static func loweredVerticalAlignmentOrNil(_ raw: String) -> String? {
        guard let c = bareEnumCase(raw), irVerticalAlignmentCases.contains(c) else { return nil }
        return c
    }

    static func bareEnumCase(_ src: String) -> String? {
        var s = src.trimmingCharacters(in: .whitespaces)
        // Reject a call/payload form.
        if s.contains("(") || s.contains(")") || s.contains("[") { return nil }
        // `Type.case` → drop a single qualifier; `.case` → drop the dot.
        if let dot = s.lastIndex(of: ".") {
            s = String(s[s.index(after: dot)...])
        }
        guard !s.isEmpty else { return nil }
        // Must be a plain identifier (letters/digits/_).
        for ch in s where !(ch.isLetter || ch.isNumber || ch == "_") { return nil }
        guard let first = s.first, first.isLetter || first == "_" else { return nil }
        return s
    }

    /// An OptionSet/`Edge.Set`/`Axis.Set` literal → a stable dotless string:
    ///   `.all` → "all"; `.top` → "top"; `[.top, .bottom]` → "top+bottom";
    ///   `.horizontal` → "horizontal". Returns nil if any element isn't a plain case.
    static func parseSetLiteral(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") && s.hasSuffix("]") {
            let inner = s.dropFirst().dropLast()
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var cases: [String] = []
            for p in parts {
                guard let c = bareEnumCase(p) else { return nil }
                cases.append(c)
            }
            return cases.isEmpty ? nil : cases.joined(separator: "+")
        }
        return bareEnumCase(s)
    }

    /// Parse `.degrees(N)` / `Angle(degrees: N)` / `Angle.degrees(N)` → the literal
    /// degree value as a string, else nil (radians/computed forms slot).
    static func parseDegrees(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix(".degrees(") || s.hasPrefix("Angle.degrees(") {
            let inner = String(s[s.firstIndex(of: "(")!...].dropFirst().dropLast())
            return isNumericLiteral(inner) ? inner : nil
        }
        if s.hasPrefix("Angle("), let d = captureArg(s, "degrees"), isNumericLiteral(d) {
            return d
        }
        return nil
    }

    /// Extract the URL STRING from a `destination:`/`url:` argument that is either a
    /// bare string literal (`"https://x"`) or `URL(string: "https://x")[!]`. Returns
    /// the quoted string-literal source (ready to embed) or nil for a computed URL.
    static func literalURLString(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        // A bare string literal.
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 { return s }
        // `URL(string: "…")` (optionally force-unwrapped / with extra args we ignore).
        if s.hasPrefix("URL("), let inner = captureArg(s, "string") {
            let t = inner.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 { return t }
        }
        return nil
    }

    /// Parse an `axis: (x:1, y:0, z:0)` 3-tuple → ("1","0","0") string components.
    static func parseAxis3(_ src: String) -> (String, String, String)? {
        let x = captureArg(src, "x") ?? captureTuple(src, 0)
        let y = captureArg(src, "y") ?? captureTuple(src, 1)
        let z = captureArg(src, "z") ?? captureTuple(src, 2)
        guard let x, let y, let z, isNumericLiteral(x), isNumericLiteral(y), isNumericLiteral(z) else { return nil }
        return ("Double(\(x))", "Double(\(y))", "Double(\(z))")
    }
    private static func captureTuple(_ s: String, _ index: Int) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("("), trimmed.hasSuffix(")") else { return nil }
        let inner = trimmed.dropFirst().dropLast()
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard index < parts.count else { return nil }
        var p = parts[index]
        if let colon = p.firstIndex(of: ":") { p = String(p[p.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        return p.isEmpty ? nil : p
    }

    /// Map a ShapeStyle expression to an `IRShapeStyle` literal. Handles:
    ///   * a palette/RGBA color (`.red`, `Color(red:…)`) → `.color(...)`
    ///   * a Material (`.ultraThinMaterial`/`.thinMaterial`/`.regularMaterial`/
    ///     `.thickMaterial`/`.bar`) → `.material(...)`
    ///   * the hierarchical statics (`.secondary`/`.tertiary`/… as a STYLE — but
    ///     those collide with palette names, so we treat `.primary…quaternary` as
    ///     hierarchical levels here since this resolver is style-context)
    ///   * `.tint` semantic
    ///   * a linear/radial/angular Gradient constructor with literal stops.
    /// Returns nil for anything else (a custom style, a gradient with non-literal
    /// stops) → the modified node slots natively (faithful).
    static func loweredShapeStyleOrNil(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        // Materials.
        if let m = materialName(s) { return ".material(.\(m))" }
        // `.blue.gradient` / `Color.blue.gradient` → a vertical linear gradient of
        // the base color (the common `.gradient` sugar). We approximate it as a
        // top→bottom linear gradient between the color and itself-ish; faithful
        // enough for the styling intent, and it round-trips.
        if s.hasSuffix(".gradient") {
            let baseColor = String(s.dropLast(".gradient".count))
            if let c = Self.loweredColorOrNil(baseColor) {
                return ".linearGradient(IRGradient(stops: [IRGradientStop(color: \(c), location: 0), "
                    + "IRGradientStop(color: \(c), location: 1)]), startPoint: .top, endPoint: .bottom)"
            }
            return nil
        }
        // Gradient constructors.
        if let g = loweredGradientStyleOrNil(s) { return g }
        // Semantic foreground style names.
        if s == ".tint" { return ".semantic(\"tint\")" }
        if s == ".separator" || s == "Color.separator" { return ".semantic(\"separator\")" }
        if s == ".placeholder" { return ".semantic(\"placeholder\")" }
        // A plain palette / RGBA color.
        if let c = Self.loweredColorOrNil(s) { return ".color(\(c))" }
        return nil
    }

    /// `.ultraThinMaterial` → "ultraThin" etc.; nil if not a material.
    private static func materialName(_ s: String) -> String? {
        switch s {
        case ".ultraThinMaterial", "Material.ultraThin": return "ultraThin"
        case ".thinMaterial", "Material.thin": return "thin"
        case ".regularMaterial", "Material.regular": return "regular"
        case ".thickMaterial", "Material.thick": return "thick"
        case ".bar", "Material.bar": return "bar"
        default: return nil
        }
    }

    /// Parse `LinearGradient(...)`/`RadialGradient(...)`/`AngularGradient(...)` into
    /// an `IRShapeStyle` gradient literal. Only the `colors:`/`stops:` + geometry
    /// forms with LITERAL palette colors + named UnitPoints lower; else nil.
    static func loweredGradientStyleOrNil(_ s: String) -> String? {
        let kind: String
        if s.hasPrefix("LinearGradient(") { kind = "linear" }
        else if s.hasPrefix("RadialGradient(") { kind = "radial" }
        else if s.hasPrefix("AngularGradient(") { kind = "angular" }
        else { return nil }
        guard let stops = parseGradientStops(s) else { return nil }
        // Resolve an optional UnitPoint arg: ABSENT → the supplied SwiftUI default;
        // PRESENT-AND-NAMED → that case; PRESENT-BUT-UNMODELED (a `UnitPoint(x:y:)`
        // literal / computed) → nil (signal: SLOT the whole gradient). The contract is
        // 'lower faithfully or slot', never 'lower with a wrong default'.
        func resolveUnitPoint(_ label: String, default def: String) -> String? {
            guard let raw = captureArg(s, label) else { return def }   // absent → default
            return unitPointLit(raw)   // present: named case, or nil → slot
        }
        // Resolve an optional numeric radius arg: ABSENT → default; PRESENT-LITERAL → it;
        // PRESENT-NON-LITERAL → nil (slot).
        func resolveRadius(_ label: String, default def: String) -> String? {
            guard let raw = captureArg(s, label) else { return def }
            return isNumericLiteral(raw) ? raw : nil
        }
        // Resolve an optional angle arg: ABSENT → default; PRESENT-PARSEABLE → degrees;
        // PRESENT-NON-PARSEABLE → nil (slot).
        func resolveAngle(_ label: String, default def: String) -> String? {
            guard let raw = captureArg(s, label) else { return def }
            return parseDegrees(raw)
        }
        switch kind {
        case "linear":
            // BUG R2-#69: a custom start/end UnitPoint (`UnitPoint(x:y:)`) must SLOT, not
            // silently fall back to .top/.bottom (a diagonal would render as vertical).
            guard let sp = resolveUnitPoint("startPoint", default: ".top"),
                  let ep = resolveUnitPoint("endPoint", default: ".bottom") else { return nil }
            return ".linearGradient(IRGradient(stops: [\(stops)]), startPoint: \(sp), endPoint: \(ep))"
        case "radial":
            // BUG R2-#70/#73: a non-named center or a non-literal start/end radius must
            // SLOT, not silently become .center / 0 / 100 (wrong gradient extent).
            guard let c = resolveUnitPoint("center", default: ".center"),
                  let sr = resolveRadius("startRadius", default: "0"),
                  let er = resolveRadius("endRadius", default: "100") else { return nil }
            return ".radialGradient(IRGradient(stops: [\(stops)]), center: \(c), startRadius: Double(\(sr)), endRadius: Double(\(er)))"
        default: // angular
            // BUG R2-#71/#72: parse the provided startAngle/endAngle (`.degrees(N)`)
            // instead of HARDCODING 0...360 (a partial sweep rendered as a full sweep);
            // a present-but-non-literal angle SLOTS the whole gradient.
            guard let c = resolveUnitPoint("center", default: ".center"),
                  let sa = resolveAngle("startAngle", default: "0"),
                  let ea = resolveAngle("endAngle", default: "360") else { return nil }
            return ".angularGradient(IRGradient(stops: [\(stops)]), center: \(c), startAngle: \(sa), endAngle: \(ea))"
        }
    }

    /// Parse a gradient's `colors: [.red, .blue]` (evenly spaced) or
    /// `stops: [.init(color:.red, location:0), …]` into `IRGradientStop(...)` lits.
    private static func parseGradientStops(_ s: String) -> String? {
        if let colors = captureArg(s, "colors"), colors.hasPrefix("[") {
            let inner = String(colors.dropFirst().dropLast())
            // BUG R2-#123: split DEPTH-AWARE so a nested `Color(red:green:blue:)` /
            // `Gradient.Stop(...)` literal's inner commas don't fragment the element list
            // (a naive `,` split demoted the whole gradient for any RGBA color element).
            let parts = splitTopLevel(inner, on: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            var lits: [String] = []
            for (i, p) in parts.enumerated() {
                guard let c = Self.loweredColorOrNil(p) else { return nil }
                let loc = parts.count == 1 ? 0 : Double(i) / Double(parts.count - 1)
                lits.append("IRGradientStop(color: \(c), location: \(loc))")
            }
            return lits.joined(separator: ", ")
        }
        // A `stops:` array of `Gradient.Stop`/`.init(color:location:)` — best-effort.
        if let stops = captureArg(s, "stops"), stops.hasPrefix("[") {
            // Too varied to parse robustly; require the simpler `colors:` form.
            return nil
        }
        return nil
    }

    /// A named-UnitPoint literal from a `.top`/`.center`/… expr, else nil.
    static func unitPointLit(_ raw: String?) -> String? {
        guard let r = raw, let c = bareEnumCase(r), knownUnitPoints.contains(c) else { return nil }
        return ".\(c)"
    }

    /// Map an `Animation` expression to an `IRAnimation` literal. Handles the
    /// common static curves with literal params; a custom/`timingCurve` form slots.
    static func loweredAnimationOrNil(_ src: String) -> String? {
        var s = src.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("Animation.") { s = String(s.dropFirst("Animation.".count)); s = "." + s }
        // Bare curve, no params: `.default`/`.easeInOut`/`.spring`/`.bouncy`/…
        if let c = bareEnumCase(s), knownAnimCurves.contains(c) {
            return "IRAnimation(curve: \"\(c)\")"
        }
        // `.curve(params)` forms.
        guard s.hasPrefix(".") else { return nil }
        let curve = String(s.dropFirst().prefix { $0 != "(" })
        guard knownAnimCurves.contains(curve) else { return nil }
        var parts: [String] = ["curve: \"\(curve)\""]
        func add(_ label: String, _ irLabel: String, isBool: Bool = false) {
            if let v = captureArg(s, label) {
                if isBool, v == "true" || v == "false" { parts.append("\(irLabel): \(v)") }
                else if isNumericLiteral(v) { parts.append("\(irLabel): \(v)") }
            }
        }
        // `.easeInOut(duration:)`; `.linear(duration:)`.
        add("duration", "duration")
        // `.spring(response:dampingFraction:)` etc.
        add("response", "response")
        add("dampingFraction", "dampingFraction")
        // common `.delay`/`.speed` are chained methods, not init args — skip.
        return "IRAnimation(\(parts.joined(separator: ", ")))"
    }

    /// Map a `.transition(...)` argument to an `IRTransition` literal. Handles the
    /// named built-ins + `.move(edge:)`/`.scale`/`.offset`; composed forms slot.
    static func loweredTransitionOrNil(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        switch s {
        case ".identity": return ".identity"
        case ".opacity": return ".opacity"
        case ".slide": return ".slide"
        case ".scale": return ".scale(scale: 0, anchor: .center)"
        case ".blurReplace": return ".blurReplace"
        default: break
        }
        // The edge must be a closed Edge case; an unrecognized identifier would render
        // as the SDK renderer's `.top` default (wrong direction) — slot instead.
        let edgeCases: Set<String> = ["top", "bottom", "leading", "trailing"]
        if s.hasPrefix(".move("), let e = captureArg(s, "edge"), let ec = bareEnumCase(e), edgeCases.contains(ec) {
            return ".move(edge: \"\(ec)\")"
        }
        if s.hasPrefix(".push("), let e = captureArg(s, "edge"), let ec = bareEnumCase(e), edgeCases.contains(ec) {
            return ".push(edge: \"\(ec)\")"
        }
        if s.hasPrefix(".offset(") {
            let x = captureArg(s, "x") ?? "0"; let y = captureArg(s, "y") ?? "0"
            if isNumericLiteral(x), isNumericLiteral(y) { return ".offset(x: Double(\(x)), y: Double(\(y)))" }
        }
        if s.hasPrefix(".scale(") {
            let sc = captureArg(s, "scale") ?? "0"
            if isNumericLiteral(sc) { return ".scale(scale: Double(\(sc)), anchor: .center)" }
        }
        return nil
    }

    static let knownUnitPoints: Set<String> = [
        "center", "top", "bottom", "leading", "trailing",
        "topLeading", "topTrailing", "bottomLeading", "bottomTrailing",
    ]
    static let knownBlendModes: Set<String> = [
        "normal", "multiply", "screen", "overlay", "darken", "lighten",
        "colorDodge", "colorBurn", "softLight", "hardLight", "difference", "exclusion",
        "hue", "saturation", "color", "luminosity",
        "sourceAtop", "destinationOver", "destinationOut", "plusDarker", "plusLighter",
    ]
    static let knownButtonStyles: Set<String> = [
        "automatic", "bordered", "borderedProminent", "borderless", "plain",
    ]
    static let knownListStyles: Set<String> = [
        "automatic", "plain", "grouped", "insetGrouped", "inset", "sidebar", "bordered",
    ]
    // Additional built-in control styles (styles-views wave). Each set names the
    // STATIC accessors of the corresponding `*Style` protocol; a name outside the
    // set (or a custom style struct) slots.
    static let knownTextFieldStyles: Set<String> = [
        "automatic", "plain", "roundedBorder", "squareBorder",
    ]
    static let knownDatePickerStyles: Set<String> = [
        "automatic", "compact", "graphical", "wheel", "field", "stepperField",
    ]
    static let knownGroupBoxStyles: Set<String> = [
        "automatic",
    ]
    static let knownControlGroupStyles: Set<String> = [
        "automatic", "navigation", "compactMenu", "menu", "palette",
    ]
    static let knownDisclosureGroupStyles: Set<String> = [
        "automatic",
    ]
    static let knownTableStyles: Set<String> = [
        "automatic", "inset", "bordered",
    ]
    static let knownAnimCurves: Set<String> = [
        "default", "linear", "easeIn", "easeOut", "easeInOut",
        "spring", "interpolatingSpring", "bouncy", "smooth", "snappy",
    ]

    /// A `ShareLink` item that is a plain string literal (the lowerable case). A
    /// non-string `Transferable` slots. Returns the quoted source or nil.
    static func stringLiteralOrIdent(_ expr: ExprSyntax) -> String? {
        if expr.as(StringLiteralExprSyntax.self) != nil { return expr.trimmedDescription }
        return nil
    }

    /// Parse a `GridItem(.fixed(80))` / `GridItem(.flexible(minimum:maximum:))` /
    /// `GridItem(.adaptive(minimum:maximum:))` source into an `IRGridItem(...)`
    /// literal. `spacing:`/`alignment:` are carried when present. A computed sizing
    /// (a non-literal min/max/fixed) returns nil so the whole grid slots.
    static func loweredGridItemOrNil(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("GridItem(") else { return nil }
        // The leading sizing arg: `.fixed(x)` / `.flexible(...)` / `.adaptive(...)`.
        let sizeIR: String
        if let fx = sizingArg(s, ".fixed") {
            guard isNumericLiteral(fx) else { return nil }
            sizeIR = ".fixed(Double(\(fx)))"
        } else if s.contains(".flexible") {
            let minV = captureArg(s, "minimum") ?? "10"
            let maxV = captureArg(s, "maximum")
            guard let ir = gridFlexAdaptive(".flexible", minV: minV, maxV: maxV) else { return nil }
            sizeIR = ir
        } else if s.contains(".adaptive") {
            let minV = captureArg(s, "minimum") ?? "10"
            let maxV = captureArg(s, "maximum")
            guard let ir = gridFlexAdaptive(".adaptive", minV: minV, maxV: maxV) else { return nil }
            sizeIR = ir
        } else {
            return nil
        }
        var pieces = ["size: \(sizeIR)"]
        if let sp = captureArg(s, "spacing"), isNumericLiteral(sp) {
            pieces.append("spacing: Double(\(sp))")
        }
        if let al = captureArg(s, "alignment") {
            // BUG R2-#121: validate against IRAlignment; a non-IR guide returns nil so the
            // whole grid slots (emitGrid demotes on a nil GridItem) — never an invalid case.
            guard let c = loweredAlignmentOrNil(al) else { return nil }
            pieces.append("alignment: .\(c)")
        }
        return "IRGridItem(\(pieces.joined(separator: ", ")))"
    }

    /// `.flexible`/`.adaptive` min/max → an `IRGridItemSize` literal. `min` must be a
    /// numeric literal (default 10); `max` is `.infinity` when absent/`.infinity`,
    /// else a numeric `.points(x)`. A non-literal min/max → nil.
    private static func gridFlexAdaptive(_ kind: String, minV: String, maxV: String?) -> String? {
        let minTrim = minV.trimmingCharacters(in: .whitespaces)
        guard isNumericLiteral(minTrim) else { return nil }
        let maxIR: String
        if let mv = maxV?.trimmingCharacters(in: .whitespaces) {
            if mv == ".infinity" || mv.hasSuffix(".infinity") { maxIR = ".infinity" }
            else if isNumericLiteral(mv) { maxIR = ".points(Double(\(mv)))" }
            else { return nil }
        } else {
            maxIR = ".infinity"   // SwiftUI's default maximum
        }
        let caseName = kind == ".fixed" ? ".fixed" : kind
        return "\(caseName)(min: Double(\(minTrim)), max: \(maxIR))"
    }

    /// Capture the numeric arg of a `.fixed(<n>)` sizing call from a flat source.
    private static func sizingArg(_ s: String, _ kind: String) -> String? {
        guard let r = s.range(of: "\(kind)(") else { return nil }
        var depth = 0
        var value = ""
        for ch in s[r.upperBound...] {
            if ch == "(" || ch == "[" { depth += 1; value.append(ch) }
            else if ch == ")" || ch == "]" {
                if depth == 0 { break }
                depth -= 1; value.append(ch)
            } else { value.append(ch) }
        }
        let t = value.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Capture a labeled argument's value from a flat call-source string
    /// (`Foo(label: <value>, …)`). Returns the trimmed value up to the next
    /// top-level comma or the closing paren. Best-effort (the args we parse are
    /// simple literals); a nested call in the value would confuse it, but those
    /// aren't numeric literals so they're rejected downstream.
    /// Split `s` on a single-character separator at PAREN/BRACKET depth 0 only, so a
    /// nested call/array literal's inner separators don't fragment the list. (Used by
    /// gradient `colors:` parsing — a `Color(red:green:blue:)` element carries commas.)
    static func splitTopLevel(_ s: String, on sep: Character) -> [String] {
        var depth = 0
        var cur = ""
        var out: [String] = []
        for ch in s {
            if ch == "(" || ch == "[" { depth += 1 }
            else if ch == ")" || ch == "]" { if depth > 0 { depth -= 1 } }
            if ch == sep && depth == 0 {
                out.append(cur)
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        out.append(cur)
        return out
    }

    static func captureArg(_ s: String, _ label: String) -> String? {
        guard let r = s.range(of: "\(label):") else { return nil }
        var depth = 0
        var value = ""
        for ch in s[r.upperBound...] {
            if ch == "(" || ch == "[" { depth += 1 }
            else if ch == ")" || ch == "]" {
                if depth == 0 { break }
                depth -= 1
            } else if ch == "," && depth == 0 { break }
            value.append(ch)
        }
        let t = value.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// A plain numeric literal (int or decimal, optional leading minus, `_` digit
    /// separators allowed). Used to gate RGBA components / frame bounds to literals.
    static func isNumericLiteral(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        var body = Substring(t)
        if body.hasPrefix("-") { body = body.dropFirst() }
        guard !body.isEmpty else { return false }
        var seenDot = false
        for ch in body {
            if ch == "." {
                if seenDot { return false }
                seenDot = true
            } else if ch == "_" {
                continue
            } else if !ch.isNumber {
                return false
            }
        }
        return true
    }

    /// The system palette the SDK renderer maps by name (Render.systemColor). Keep
    /// in sync with that switch.
    static let knownColorNames: Set<String> = [
        "primary", "secondary", "accent", "accentColor",
        "red", "orange", "yellow", "green", "mint", "teal", "cyan",
        "blue", "indigo", "purple", "pink", "brown",
        "white", "gray", "grey", "black", "clear",
    ]

    // MARK: Action-closure mutation parsing (the UPDATE half of a tap/button)
    //
    // A discrete event's action closure is the interaction LOGIC. We parse it for a
    // SINGLE recognizable `@State` mutation and record a rule (event id → mutation)
    // so the guest runs it in WASM. We are deliberately conservative: only the
    // proven mutation grammar (toggle / inc / dec / clamp / assign-literal) on a
    // simple `lhs <op> rhs` statement is recognized. Anything else — multiple
    // statements we can't fold, Foundation calls, method bodies — yields NO rule, so
    // that interaction simply stays native (the tree still re-renders). Honest +
    // demote-safe, matching the rest of the lowering.

    /// Parse a Button's action closure for a recordable `@State` mutation and, if found,
    /// append the dispatch rule. Returns true iff a rule was recorded (the tap dispatches
    /// in WASM); false means the action is NOT guest-dispatchable (the caller must slot the
    /// whole Button natively, or — in an actions-list context — demote the view) — so a
    /// COMPLEX action (`Task { … }`, an `@Observable`/method call, a multi-statement body)
    /// never silently produces a dead button.
    @discardableResult
    private mutating func recordActionMutation(_ closure: ClosureExprSyntax?, event: String) -> Bool {
        guard let closure else { return false }
        // SwiftParser leaves operator sequences UNFOLDED (a flat `SequenceExprSyntax`),
        // so `x = x >= 9 ? 0 : x + 1` isn't an `InfixOperatorExprSyntax` yet. Fold the
        // whole closure with the standard operator table first, so the mutation parser
        // sees structured infix/ternary/assignment trees.
        let folded = (OperatorTable.standardOperators.foldAll(closure) { _ in }
            .as(ClosureExprSyntax.self)) ?? closure
        // Collect the closure's expression statements (ignore pure no-ops). A single
        // recognizable mutation is the covered case; a two-statement wraparound
        // `x += 1; if x > hi { x = lo }` is folded by `parseTwoStatementWraparound`.
        let exprs: [ExprSyntax] = folded.statements.compactMap { item in
            if case .expr(let e) = item.item { return e }
            if case .stmt(let s) = item.item,
               let es = s.as(ExpressionStmtSyntax.self) { return es.expression }
            return nil
        }
        // Single-statement mutations cover toggle/assign/clamp and the ternary
        // wraparound `x = x >= hi ? lo : x + step`.
        if exprs.count == 1, let rule = Self.parseMutation(exprs[0], event: event) {
            mutationRules.append(rule)
            return true
        }
        // Two-statement wraparound: `x += step` then `if x > hi { x = lo }`.
        if let rule = Self.parseTwoStatementWraparound(folded.statements, event: event) {
            mutationRules.append(rule)
            return true
        }
        return false
    }

    /// True iff a Button's action closure has NO effective statements — `Button("X") {}`
    /// or `{ }`/`{ /* comment */ }`. Such a deliberately-empty action is a valid no-op (the
    /// button renders, tapping does nothing by design): it lowers to a plain `N.button` with
    /// no rule and is NEVER slotted/demoted. (A `nil` closure — no action closure parsed —
    /// is also treated as empty.)
    private static func actionClosureIsEmpty(_ closure: ClosureExprSyntax?) -> Bool {
        guard let closure else { return true }
        return closure.statements.allSatisfy { item in
            // A pure no-op or whitespace/comment-only statement list.
            item.item.trimmedDescription.isEmpty
        }
    }

    /// Parse a single `lhs <op> rhs` (or `x.toggle()`) into a mutation rule.
    static func parseMutation(_ expr: ExprSyntax, event: String) -> BodyLowering.MutationRule? {
        // `x.toggle()` — a Bool flip.
        if let call = expr.as(FunctionCallExprSyntax.self),
           call.arguments.isEmpty,
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "toggle",
           let base = member.base?.as(DeclReferenceExprSyntax.self) {
            return .init(eventID: event, field: identName(base), op: .toggleBool)
        }
        // An infix expression: `lhs = rhs`, `lhs += n`, `lhs -= n`.
        guard let seq = expr.as(InfixOperatorExprSyntax.self) else { return nil }
        guard let lhs = seq.leftOperand.as(DeclReferenceExprSyntax.self) else { return nil }
        let field = identName(lhs)
        let opText = seq.operator.as(BinaryOperatorExprSyntax.self)?.operator.text
            ?? seq.operator.as(AssignmentExprSyntax.self).map { _ in "=" }
        let rhs = seq.rightOperand

        switch opText {
        case "+=":
            if let n = intLiteral(rhs) { return .init(eventID: event, field: field,
                                                      op: .incInt(step: n, lo: nil, hi: nil, wrap: false)) }
        case "-=":
            if let n = intLiteral(rhs) { return .init(eventID: event, field: field,
                                                      op: .decInt(step: n, lo: nil, hi: nil)) }
        case "=":
            // `x = !x` → toggle.
            if let pre = rhs.as(PrefixOperatorExprSyntax.self),
               pre.operator.text == "!",
               let inner = pre.expression.as(DeclReferenceExprSyntax.self),
               identName(inner) == field {
                return .init(eventID: event, field: field, op: .toggleBool)
            }
            // `x = x >= hi ? lo : x + step` (ternary wraparound).
            if let tern = rhs.as(TernaryExprSyntax.self),
               let rule = parseTernaryWraparound(tern, field: field, event: event) {
                return rule
            }
            // `x = x + n` / `x = x - n`.
            if let inner = rhs.as(InfixOperatorExprSyntax.self),
               let l = inner.leftOperand.as(DeclReferenceExprSyntax.self),
               identName(l) == field,
               let n = intLiteral(inner.rightOperand) {
                let op = inner.operator.as(BinaryOperatorExprSyntax.self)?.operator.text
                if op == "+" { return .init(eventID: event, field: field,
                                            op: .incInt(step: n, lo: nil, hi: nil, wrap: false)) }
                if op == "-" { return .init(eventID: event, field: field,
                                            op: .decInt(step: n, lo: nil, hi: nil)) }
            }
            // `x = <int literal>` → assign a constant.
            if let n = intLiteral(rhs) {
                return .init(eventID: event, field: field, op: .assignIntLiteral(n))
            }
            // `x = true` / `x = false` → assign a constant Bool (the common `showing = true`
            // sheet/flag tap). Without this the tap recorded NO rule → a dead button.
            if let b = rhs.as(BooleanLiteralExprSyntax.self) {
                return .init(eventID: event, field: field,
                             op: .assignBoolLiteral(b.literal.text == "true"))
            }
        default:
            return nil
        }
        return nil
    }

    /// `x = x >= hi ? lo : x + step` (or `x < hi ? x + step : lo`) → wraparound inc.
    private static func parseTernaryWraparound(_ tern: TernaryExprSyntax, field: String,
                                               event: String) -> BodyLowering.MutationRule? {
        // Condition `x >= hi` (or `x == hi`): then-branch resets to lo, else +step.
        guard let cond = tern.condition.as(InfixOperatorExprSyntax.self),
              let l = cond.leftOperand.as(DeclReferenceExprSyntax.self),
              identName(l) == field,
              let hi = intLiteral(cond.rightOperand) else { return nil }
        let cmp = cond.operator.as(BinaryOperatorExprSyntax.self)?.operator.text
        let thenE = tern.thenExpression, elseE = tern.elseExpression
        // Resolve which branch is the reset-to-lo and which is the +step.
        func incStep(_ e: ExprSyntax) -> Int? {
            guard let i = e.as(InfixOperatorExprSyntax.self),
                  let il = i.leftOperand.as(DeclReferenceExprSyntax.self),
                  identName(il) == field,
                  i.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "+" else { return nil }
            return intLiteral(i.rightOperand)
        }
        if (cmp == ">=" || cmp == "==" || cmp == ">"),
           let lo = intLiteral(thenE), let step = incStep(elseE) {
            // hi when `>=`/`==`; treat `>` the same (UI ranges are inclusive enough).
            return .init(eventID: event, field: field, op: .incInt(step: step, lo: lo, hi: hi, wrap: true))
        }
        if (cmp == "<" || cmp == "<="),
           let step = incStep(thenE), let lo = intLiteral(elseE) {
            return .init(eventID: event, field: field, op: .incInt(step: step, lo: lo, hi: hi, wrap: true))
        }
        return nil
    }

    /// `x += step` followed by `if x > hi { x = lo }` → wraparound inc.
    private static func parseTwoStatementWraparound(_ stmts: CodeBlockItemListSyntax,
                                                    event: String) -> BodyLowering.MutationRule? {
        let items = Array(stmts)
        guard items.count == 2 else { return nil }
        // Statement 1: `x += step` (or `x = x + step`).
        guard case .expr(let e0) = items[0].item,
              let r0 = parseMutation(e0, event: event),
              case .incInt(let step, _, _, _) = r0.op else { return nil }
        let field = r0.field
        // Statement 2: an `if x > hi { x = lo }` resetting field to lo.
        var ifExpr: IfExprSyntax?
        if case .expr(let e1) = items[1].item { ifExpr = e1.as(IfExprSyntax.self) }
        if case .stmt(let s1) = items[1].item {
            ifExpr = s1.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self)
        }
        guard let ife = ifExpr,
              let cond = ife.conditions.first?.condition.as(InfixOperatorExprSyntax.self),
              let cl = cond.leftOperand.as(DeclReferenceExprSyntax.self),
              identName(cl) == field,
              let hi = intLiteral(cond.rightOperand) else { return nil }
        let cmp = cond.operator.as(BinaryOperatorExprSyntax.self)?.operator.text
        guard cmp == ">" || cmp == ">=" else { return nil }
        // The body assigns `field = lo`.
        let body = Array(ife.body.statements)
        guard body.count == 1, case .expr(let be) = body[0].item,
              let assign = be.as(InfixOperatorExprSyntax.self),
              let al = assign.leftOperand.as(DeclReferenceExprSyntax.self),
              identName(al) == field,
              assign.operator.is(AssignmentExprSyntax.self),
              let lo = intLiteral(assign.rightOperand) else { return nil }
        // BUG R2-#77/#79: the guest renders `.incInt(wrap)` as
        // `x = x >= hi ? lo : x+step` (compare-then-increment). The SOURCE here
        // increments THEN compares the NEW value. For a `>` native condition the
        // inclusive max IS `hi`. For a `>=` native condition the source resets one step
        // EARLIER — at `hi` — so the guest's max must be `hi - step` to match (else the
        // guest displays one extra value before wrapping). Correct the bound per cmp.
        let effectiveHi = (cmp == ">=") ? (hi - step) : hi
        return .init(eventID: event, field: field,
                     op: .incInt(step: step, lo: lo, hi: effectiveHi, wrap: true))
    }

    static func identName(_ d: DeclReferenceExprSyntax) -> String { d.baseName.text }

    /// An integer literal (allowing a unary minus) → its Int value.
    static func intLiteral(_ expr: ExprSyntax) -> Int? {
        // Every caller bakes the result into the 32-bit wasm guest (mutation-rule constants,
        // picker tags, UIKit literals). A value outside Int32 range overflows the guest Int
        // at COMPILE time and fails the whole module, so reject it here → the caller demotes
        // that feature to native instead of shipping an uncompilable guest.
        func inRange(_ n: Int?) -> Int? {
            guard let n, n >= Int(Int32.min), n <= Int(Int32.max) else { return nil }
            return n
        }
        if let lit = expr.as(IntegerLiteralExprSyntax.self) {
            return inRange(Int(lit.literal.text.replacingOccurrences(of: "_", with: "")))
        }
        if let pre = expr.as(PrefixOperatorExprSyntax.self), pre.operator.text == "-",
           let lit = pre.expression.as(IntegerLiteralExprSyntax.self) {
            return inRange(Int("-" + lit.literal.text.replacingOccurrences(of: "_", with: "")))
        }
        return nil
    }

    // Parse a `lo...hi` (or `lo..<hi`) range literal's integer bounds.
    static func intRangeBounds(_ raw: String) -> (Int, Int)? {
        for sep in ["...", "..<"] {
            if let r = raw.range(of: sep) {
                let loS = raw[raw.startIndex..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let hiS = raw[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if let lo = Int(loS), let hi = Int(hiS) {
                    return sep == "..<" ? (lo, hi - 1) : (lo, hi)
                }
                _ = hiS  // silence unused in the non-int path
            }
        }
        return nil
    }

    // Parse a `lo...hi` range literal's double bounds.
    static func doubleRangeBounds(_ raw: String) -> (Double, Double)? {
        if let r = raw.range(of: "...") {
            let loS = raw[raw.startIndex..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let hiS = raw[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if let lo = Double(loS), let hi = Double(hiS) { return (lo, hi) }
        }
        return nil
    }

    // MARK: helpers

    /// Emit an opaque node for a non-lowerable leaf EXPRESSION, recording it (with
    /// a CONTENT-STABLE id + slotability) so the build-time thunk can render it
    /// natively. The id is derived from the leaf's source, so the SAME leaf gets the
    /// SAME id in the engine (push) and the thunk generator (build) — they agree
    /// without sharing state, and a rearranged-but-unchanged leaf keeps its id.
    private mutating func opaqueExpr(_ expr: ExprSyntax, labelHint: String? = nil) -> String {
        // cli 1.6.32: LIFT BY DEFAULT. Every non-lowerable leaf now routes through the
        // string-literal lifter so a plain DISPLAY literal anywhere inside it (a Text/title
        // in a slotted `NavigationStack { … }` / `Group { … }` / custom view) rides WASM
        // (OTA-editable) instead of baking into native slot source — generalizing the 1.6.31
        // custom-modifier fix to ALL slotted constructs (the #1 real-app edit-breaks-OTA
        // cause: a container whose whole subtree slots natively, e.g. SettingsScreen's
        // NavigationStack). `opaqueExprLifted` falls back to `opaqueExprRaw` (the old behavior)
        // when nothing is liftable, so a literal-free leaf (Color/shape/custom-view-no-text) is
        // BYTE-IDENTICAL to before. Lifting is identity-safe (the lifter only matches display/
        // icon positions; `.tag`/ForEach `id:`/Chart `.value`/asset names stay baked/stable).
        return opaqueExprLifted(expr, labelHint: labelHint ?? Self.derivedLeafLabel(expr))
    }

    /// The RAW (no-lift) opaque-leaf primitive — records the leaf verbatim. `opaqueExpr` now
    /// lifts by default and falls back HERE when nothing is liftable (so the non-text path is
    /// unchanged). Call this directly only when lifting must be bypassed.
    private mutating func opaqueExprRaw(_ expr: ExprSyntax, labelHint: String? = nil) -> String {
        let source = expr.trimmedDescription
        let id = "op_" + Self.stableHash64(source)
        let slotable = Self.isSlotable(expr, blocked: bodyLocals.union(inaccessibleNames))
        recordOpaque(id: id, source: source, slotable: slotable, label: labelHint ?? source)
        return "N.opaque(id: \"\(id)\", label: \"\(Self.safeLabel(labelHint ?? source))\")"
    }

    /// A clean debug `.label` for a leaf with no explicit labelHint: the leading call/member
    /// identifier (e.g. "NavigationStack", "AddConnectionSheet"), so a lifted leaf's label is
    /// the construct name — never the rewritten source (placeholder control chars / structural
    /// punctuation). Cosmetic only (the slot id is a content hash; the label is debug metadata).
    static func derivedLeafLabel(_ expr: ExprSyntax) -> String {
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) { return ref.baseName.text }
            if let mem = call.calledExpression.as(MemberAccessExprSyntax.self) { return mem.declName.baseName.text }
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) { return ref.baseName.text }
        if let mem = expr.as(MemberAccessExprSyntax.self) { return mem.declName.baseName.text }
        return "view"
    }

    /// Like `opaqueExpr`, but for a VIEWBUILDER expression that can't be wrapped in
    /// `AnyView(<source>)` directly (a bare `if`/`if let`/`switch` block, a multi-
    /// statement ViewBuilder): the slot source is the expression wrapped in
    /// `Group { … }`, which IS `AnyView`-wrappable and renders identically. Slotability
    /// is judged on the ORIGINAL expression's references (the `Group` wrapper adds none).
    /// The id keys off the wrapped source so it's stable + distinct from a plain leaf.
    private mutating func opaqueViewBuilder(_ expr: ExprSyntax, labelHint: String? = nil) -> String {
        // cli 1.6.32: LIFT BY DEFAULT (same generalization as opaqueExpr) — a display literal
        // inside a slotted `if`/`switch`/multi-statement ViewBuilder rides WASM (OTA-editable).
        // Falls back to `opaqueViewBuilderRaw` when nothing is liftable (byte-identical to before).
        return opaqueViewBuilderLifted(expr, labelHint: labelHint)
    }

    /// The RAW (no-lift) ViewBuilder opaque primitive — `opaqueViewBuilder` now lifts by default
    /// and falls back HERE when nothing is liftable.
    private mutating func opaqueViewBuilderRaw(_ expr: ExprSyntax, labelHint: String? = nil) -> String {
        let inner = expr.trimmedDescription
        let source = "Group {\n\(inner)\n}"
        let id = "op_" + Self.stableHash64(source)
        let slotable = Self.isSlotable(expr, blocked: bodyLocals.union(inaccessibleNames))
        recordOpaque(id: id, source: source, slotable: slotable, label: labelHint ?? "if")
        return "N.opaque(id: \"\(id)\", label: \"\(Self.safeLabel(labelHint ?? "if"))\")"
    }

    /// A label-only opaque (no renderable expression available) — never slotable.
    private mutating func opaque(label: String) -> String {
        let id = "opx_" + Self.stableHash64(label)
        recordOpaque(id: id, source: "", slotable: false, label: label)
        return "N.opaque(id: \"\(id)\", label: \"\(Self.safeLabel(label))\")"
    }

    private mutating func recordOpaque(id: String, source: String, slotable: Bool, label: String,
                                       stringArgs: [String] = [],
                                       stringArgRanges: [Range<Int>] = []) {
        guard !opaqueLeaves.contains(where: { $0.id == id }) else { return }
        // BUILD-SAFETY GATE (prove-the-slot-expression-or-demote): the thunk wraps a
        // slotable leaf as `AnyView(<source>)`. A non-empty PARAMETERIZED template
        // (`stringArgs`) is rewritten before wrapping, so it's vetted by `opaqueCall`'s own
        // slotability check; for a PLAIN leaf, additionally require the source to be a single
        // `AnyView(…)`-wrappable view EXPRESSION — a bare `switch`/`for`/`guard` statement, a
        // `#if`-containing fragment, or a Void-returning action would emit uncompilable Swift.
        // If not wrappable, force NON-slotable so the view demotes to native (faithful) rather
        // than ship a broken wrap.
        let slotable = (slotable && stringArgs.isEmpty && !source.isEmpty)
            ? Self.isAnyViewWrappableSource(source)
            : slotable
        opaqueLeaves.append(.init(id: id, source: source, slotable: slotable, label: label,
                                  stringArgs: stringArgs, stringArgRanges: stringArgRanges))
    }

    /// Slot a CUSTOM-VIEW call, lifting its simple string-literal arguments into a
    /// PARAMETERIZED slot so editing those literals is OTA-patchable + fingerprint-
    /// stable. `Foo(text: "Settings", size: 28)` becomes a slot whose id is derived
    /// from the STRUCTURAL template `Foo(text: \u{1}0\u{1}, size: 28)` (literal value
    /// normalized out) and whose values `["Settings"]` ride WASM via
    /// `BodyEmission.slotArgs[id]`; the thunk renders `{ a in Foo(text: a[0], size: 28) }`.
    /// A string with interpolation (`"Hi \(name)"`) is NOT lifted when its dynamic part
    /// references a body-local; falls back to the plain (baked) slot.
    ///
    /// cli 1.6.33 — NESTED lifting: this no longer walks only the TOP-LEVEL call args.
    /// It routes the WHOLE call through `StringLiteralLifter` in `liftAllPlainStrings`
    /// mode, so plain-string args of NESTED custom-view calls (a `SettingsRow(label:…)`
    /// inside a `SettingsSection(title:…) { … }` trailing/@ViewBuilder closure) ALSO lift
    /// → editing a nested settings-row label rides WASM (was a FINGERPRINT MISMATCH).
    /// RANGE CORRECTNESS is preserved because the lifter records byte ranges from the
    /// ORIGINAL un-rewritten node (its FIX 2 / `pendingLifts`), never the offset=0
    /// rewritten tree — the cli 1.6.28 silent-drop hazard does not regress. SAFE because
    /// `opaqueCall` produces a fully-NATIVE parameterized reconstruction (no guest-tree
    /// identity correlation, unlike `opaqueExpr`/the renderer tree), so lifting ANY
    /// plain-string arg in any nested position is render-safe (same property as the
    /// top-level lift this path always did).
    private mutating func opaqueCall(_ call: FunctionCallExprSyntax, labelHint: String) -> String {
        let lifter = StringLiteralLifter(blocked: bodyLocals.union(inaccessibleNames),
                                         liftAllPlainStrings: true)
        let rewritten = lifter.rewrite(Syntax(ExprSyntax(call)))
        let values = lifter.values
        let ranges = lifter.ranges
        guard !values.isEmpty else {
            // No liftable string literal → plain slot (unchanged behavior).
            return opaqueExpr(ExprSyntax(call), labelHint: labelHint)
        }
        // The rewritten tree's `trimmedDescription` is the parameterized template (every
        // lifted literal — top-level AND nested — replaced by its `\u{1}k\u{1}` placeholder).
        let template = (rewritten.as(ExprSyntax.self) ?? ExprSyntax(call)).trimmedDescription
        // Disambiguate STRUCTURALLY-identical-but-differently-valued siblings (see
        // `parameterizedTemplateCounts`): the first occurrence keeps the bare
        // template id; the Nth (N≥1) appends `#N`. The id stays independent of the
        // literal VALUES, so editing a string keeps the id stable (OTA-patchable).
        let occurrence = parameterizedTemplateCounts[template, default: 0]
        parameterizedTemplateCounts[template] = occurrence + 1
        let idSeed = occurrence == 0 ? template : "\(template)#\(occurrence)"
        let id = "op_" + Self.stableHash64(idSeed)
        // Slotability is judged on the ORIGINAL call (the native render): it must
        // reference no body-local beyond the strings we lifted.
        let slotable = Self.isSlotable(ExprSyntax(call), blocked: bodyLocals.union(inaccessibleNames))
        recordOpaque(id: id, source: template, slotable: slotable, label: labelHint,
                     stringArgs: values, stringArgRanges: ranges)
        return "N.opaque(id: \"\(id)\", label: \"\(Self.safeLabel(labelHint))\")"
    }

    // MARK: - Position-typed string lifting (opaqueExpr generalization)
    //
    // When an expression that can't be lowered (e.g. `Text("OR")` inside a non-lowerable
    // `if let`/`switch` context, a Button with an undispatchable action, an Image whose
    // systemName resolves but whose call is non-lowerable) ends up in `opaqueExpr` or
    // `opaqueViewBuilder`, its string literals bake into the slot source — and into the
    // `nativeSurface` hash. Editing `"OR"` → `"AND"` then gives a FINGERPRINT MISMATCH
    // even though the change is genuinely OTA-deliverable.
    //
    // FIX: for recognized SwiftUI call positions, lift PLAIN string literals into the
    // parameterized-slot mechanism (stringArgs / stringArgRanges) wherever they appear in
    // the opaque expression tree. The StringLiteralLifter rewriter walks the AST, finds
    // recognized positions, replaces each liftable literal with a `\u{1}k\u{1}` placeholder
    // (for String positions) or `LocalizedStringKey(\u{1}k\u{1})` (for LocalizedStringKey
    // positions), and records the value + byte-range. The resulting template + args route
    // through the existing recordOpaque / ThunkGenerator / fingerprint machinery unchanged.
    //
    // POSITION RULES (conservative — unknown positions stay baked):
    //   LocalizedStringKey: Text(firstUnlabeled), Button(firstUnlabeled), Toggle(firstUnlabeled),
    //     TextField/SecureField(firstUnlabeled), Label(firstUnlabeled), Section(firstUnlabeled),
    //     Picker(firstUnlabeled), Stepper(firstUnlabeled), GroupBox(firstUnlabeled),
    //     DisclosureGroup(firstUnlabeled), NavigationLink(firstUnlabeled), Menu(firstUnlabeled),
    //     LabeledContent(firstUnlabeled), ProgressView(firstUnlabeled), Gauge(firstUnlabeled),
    //     ShareLink(firstUnlabeled), Link(firstUnlabeled).
    //   String: Image(systemName:), Image(firstUnlabeled), Image(decorative:),
    //     Text(verbatim:), accessibilityLabel/Hint/Value(firstUnlabeled).
    //
    // DEMOTE-SAFETY: isSlotable decisions UNCHANGED; we only change the TEMPLATE after a
    // leaf's slotability is already determined. A non-slotable leaf stays non-slotable; its
    // stringArgs still make the literal ride WASM (the fingerprint gate normalizes them
    // regardless of slotability — see `hasOTAParameterizedSlotLiterals`). An unrecognized
    // position leaves the literal baked. No IR/wire/SDK change.

    /// Like `opaqueExpr` but first tries to lift plain string literals from RECOGNIZED
    /// SwiftUI call positions anywhere in `expr` into parameterized-slot args. Falls back
    /// to plain `opaqueExpr` when no liftable literals are found. The slot id is derived
    /// from the TEMPLATE (literal-independent), so editing a lifted literal never changes
    /// the id → OTA-patchable + fingerprint-stable.
    private mutating func opaqueExprLifted(_ expr: ExprSyntax, labelHint: String? = nil) -> String {
        let lifter = StringLiteralLifter(blocked: bodyLocals.union(inaccessibleNames))
        let rewritten = lifter.rewrite(Syntax(expr))
        let values = lifter.values
        let ranges = lifter.ranges
        guard !values.isEmpty else {
            return opaqueExprRaw(expr, labelHint: labelHint)
        }
        // Use trimmedDescription on the cast-back ExprSyntax to strip leading/trailing trivia
        // (same as opaqueCall which uses rewritten.trimmedDescription on FunctionCallExprSyntax).
        let source = (rewritten.as(ExprSyntax.self) ?? expr).trimmedDescription
        // Dedup structurally-identical-but-differently-valued siblings (same logic as opaqueCall).
        let occurrence = parameterizedTemplateCounts[source, default: 0]
        parameterizedTemplateCounts[source] = occurrence + 1
        let idSeed = occurrence == 0 ? source : "\(source)#\(occurrence)"
        let id = "op_" + Self.stableHash64(idSeed)
        let slotable = Self.isSlotable(expr, blocked: bodyLocals.union(inaccessibleNames))
        recordOpaque(id: id, source: source, slotable: slotable, label: labelHint ?? source,
                     stringArgs: values, stringArgRanges: ranges)
        return "N.opaque(id: \"\(id)\", label: \"\(Self.safeLabel(labelHint ?? source))\")"
    }

    /// Like `opaqueViewBuilder` but applies the same position-typed string lifting
    /// inside the `Group { … }` wrapper. Falls back to plain `opaqueViewBuilder` when
    /// no liftable literals are found.
    private mutating func opaqueViewBuilderLifted(_ expr: ExprSyntax, labelHint: String? = nil) -> String {
        let lifter = StringLiteralLifter(blocked: bodyLocals.union(inaccessibleNames))
        let rewritten = lifter.rewrite(Syntax(expr))
        let values = lifter.values
        let ranges = lifter.ranges
        guard !values.isEmpty else {
            return opaqueViewBuilderRaw(expr, labelHint: labelHint)
        }
        let inner = (rewritten.as(ExprSyntax.self) ?? expr).trimmedDescription
        let source = "Group {\n\(inner)\n}"
        let occurrence = parameterizedTemplateCounts[source, default: 0]
        parameterizedTemplateCounts[source] = occurrence + 1
        let idSeed = occurrence == 0 ? source : "\(source)#\(occurrence)"
        let id = "op_" + Self.stableHash64(idSeed)
        let slotable = Self.isSlotable(expr, blocked: bodyLocals.union(inaccessibleNames))
        recordOpaque(id: id, source: source, slotable: slotable, label: labelHint ?? "if",
                     stringArgs: values, stringArgRanges: ranges)
        return "N.opaque(id: \"\(id)\", label: \"\(Self.safeLabel(labelHint ?? "if"))\")"
    }

    // MARK: - Design-system token resolution (color + font tokens)

    /// Resolve a COLOR expression to an IR `ColorRef` literal string for a modifier
    /// that takes a color (`.foregroundColor`/`.foregroundStyle`/`.tint`/`.shadow`/
    /// `.background`). Tries the static literal/system path first (`.blue`,
    /// `Color(red:…)`); on miss, treats the WHOLE expression as a DESIGN-SYSTEM color
    /// TOKEN — the build-time thunk evaluates it natively (over `self`) → a resolved
    /// `Color` keyed by a content-stable id, and the tree carries `.hostToken(id)`.
    /// This is what lets `Theme.Colors.ink`, `confidence.text`, even a ternary
    /// `selected ? .white : Theme.Colors.accent` LOWER (the modifier rides WASM; the
    /// color VALUE is host-supplied). Returns nil ONLY when the token isn't resolvable
    /// — its slot closure would reference a body-local / inaccessible member, so it
    /// can't be evaluated in the cross-file thunk — in which case the caller slots the
    /// whole node as before (faithful over wrong). Empty / trivially-degenerate exprs
    /// also return nil.
    mutating func colorRefOrToken(_ src: String) -> String? {
        if let lit = Self.loweredColorOrNil(src) { return lit }
        guard let id = recordColorTokenIfResolvable(src) else { return nil }
        return ".hostToken(\"\(id)\")"
    }

    /// Resolve a ShapeStyle expression to an `IRShapeStyle` literal for a style-taking
    /// modifier (`.fill`/`.stroke`/`.strokeBorder`/`.border`/the style forms of
    /// `.background`/`.overlay`/`.foregroundStyle`/`.tint`). Tries the static path
    /// (palette/gradient/material/semantic); on miss, treats the whole expression as a
    /// color TOKEN wrapped in `.color(.hostToken(id))` (a design-system color used as a
    /// fill/stroke style — the overwhelmingly common case). Returns nil when neither
    /// the static path nor a resolvable token applies (e.g. a custom non-color
    /// ShapeStyle, or a token referencing a body-local) → the caller slots.
    mutating func shapeStyleOrToken(_ src: String) -> String? {
        if let lit = Self.loweredShapeStyleOrNil(src) { return lit }
        guard let id = recordColorTokenIfResolvable(src) else { return nil }
        return ".color(.hostToken(\"\(id)\"))"
    }

    /// Resolve a NUMERIC expression for a numeric modifier/builder position
    /// (`.cornerRadius(N)`, `.padding(N)`, `.frame(width:height:)`, a shape's
    /// `cornerRadius:`). When `raw` is guest-resolvable as written — a literal, or an
    /// expression over the body's in-scope inputs/locals/safe globals — it's returned
    /// VERBATIM (the current behavior; the guest computes it in WASM). Otherwise, when
    /// it's a resolvable DESIGN-SYSTEM NUMERIC TOKEN (a `Theme.Radius.lg`-style member
    /// access, or a ternary/min/max thereof, referencing no body-local / inaccessible
    /// member), a `HostToken(kind:.number)` is recorded and the guest-readable token
    /// VARIABLE name is returned (`__numtok_<id>`) — the SDK injects the natively
    /// resolved value under that key, so the leaked `Theme` free identifier disappears.
    /// Returns nil ONLY when it's neither (an un-resolvable expression) → the caller
    /// keeps its existing fallback (slot the whole node, faithful over wrong).
    ///
    /// A numeric expression that references ONLY names the guest body resolves (the
    /// marshalled scalar/array inputs, geo inputs, loop/closure vars in scope, safe
    /// globals) needs NO token — it computes in WASM as written. Anything else (a
    /// `Theme.Radius.lg`) leaks a free identifier and must become a token.
    mutating func numericOrToken(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // (a) Already guest-resolvable as written? Emit verbatim (a literal `20`,
        // `width * 0.66` over a marshalled `width`, a `grid ? 14 : 16`). We reuse the
        // SAME free-identifier scope-check the build pipeline runs over the whole body,
        // so "resolvable here" exactly tracks "the guest compiles". The in-scope set is
        // the marshalled input names + the loop/closure/body-local names bound so far.
        let asWritten = SwiftUIGuestScopeCheck.check(
            guestBody: trimmed, inputNames: guestResolvableNames, usesGeometry: usesGeometry)
        // EXCEPTION (BUG #1/#11): a member access whose base is a flat-struct INPUT but whose
        // field chain doesn't resolve to a marshalled field passes the name-only scope check yet
        // would NOT compile in the guest (the mirroring struct lacks the field). Reactive-collection
        // marshalling registers `vm` carrying ONLY its collection fields, so `.padding(vm.spacing)` /
        // `VStack(spacing: vm.gap)` lands here — it must fall through to the reactive host-projection
        // (b2), never leak `vm.spacing` verbatim (which fails the whole guest compile → ships 0 views).
        if asWritten.isCompilable, !flatStructInputMemberLeaks(trimmed) { return trimmed }
        // (b) A bare reference to a NUMERIC computed scalar property (G42:
        // `.padding(inset)` where `var inset: CGFloat { … }` reads state) → host-project
        // it. The thunk's `__patchTokens()` evaluates `self.inset` natively → a Double the
        // SDK merges into the input JSON under `__numtok_<id>`.
        if let key = computedScalarNumberKey(trimmed) { return key }
        // (b2) A numeric expression that reads a REACTIVE ref-type member — e.g.
        // `.opacity(viewModel.sessions.isEmpty ? 0 : 1)` / `.frame(height: vm.isVisible ? nil : 0)`.
        // Host-project each reactive read (the collection guard / the Bool flag) to a numeric
        // token so the residual expression is guest-resolvable. Tried before the design-system
        // token path (which would reject the whole expr as out-of-scope).
        let reactiveBases = Self.reactiveBases(scalarPaths: reactiveMemberScalarPaths,
                                               collectionPaths: reactiveMemberCollectionPaths)
        if !reactiveBases.isEmpty,
           BodyLowering.guestBodyReferencesAny(trimmed, names: reactiveBases) {
            // Snapshot the recorded tokens so a FAILED recheck doesn't orphan the ones
            // `hostProjectReactiveReads` appended (the design-system path / slot fallback runs
            // instead; an orphaned `__patchTokens()` entry the tree never reads is untidy).
            let tokenSnapshot = hostTokens.count
            if let projected = hostProjectReactiveReads(in: trimmed) {
                // The projected expression must now be guest-resolvable (no free base remains).
                let recheck = SwiftUIGuestScopeCheck.check(
                    guestBody: projected, inputNames: guestResolvableNames.union(
                        hostTokens.filter { $0.ridesInputJSON }.map { $0.inputKey }),
                    usesGeometry: usesGeometry)
                if recheck.isCompilable { return projected }
            }
            if hostTokens.count > tokenSnapshot { hostTokens.removeLast(hostTokens.count - tokenSnapshot) }
        }
        // (b3) A numeric expression that reads a COMPUTED scalar member off a struct/enum
        // INPUT (`size.iconSize` where `size: Size`, `Size.iconSize: CGFloat { … }`) — the
        // design-system `Size`-enum idiom. Host-project each such read to a numeric token (the
        // thunk evaluates `self.size.iconSize` natively → a Double). Tried before the design-
        // system token path (which would admit the bare member access wrongly). When the
        // projection covers every input-member read AND the residual is guest-resolvable, use it.
        if !inputComputedMemberPaths.isEmpty {
            let tokenSnapshot = hostTokens.count
            if let projected = hostProjectInputComputedMemberReads(in: trimmed) {
                let recheck = SwiftUIGuestScopeCheck.check(
                    guestBody: projected, inputNames: guestResolvableNames.union(
                        hostTokens.filter { $0.ridesInputJSON }.map { $0.inputKey }),
                    usesGeometry: usesGeometry)
                if recheck.isCompilable { return projected }
            }
            if hostTokens.count > tokenSnapshot { hostTokens.removeLast(hostTokens.count - tokenSnapshot) }
        }
        // (c) Not resolvable as written — try it as a design-system NUMERIC token.
        guard let id = recordNumericTokenIfResolvable(trimmed) else { return nil }
        return BodyLowering.numericTokenInputKey(id)
    }

    /// The input-computed-member base names (`size`) — the struct/enum INPUT params that
    /// carry a host-projectable computed scalar/Font member. Derived from the path keys.
    private var inputComputedMemberBases: Set<String> {
        Set(inputComputedMemberPaths.keys.compactMap { $0.split(separator: ".").first.map(String.init) })
    }

    /// HOST-PROJECT every `<input>.<computedScalarMember>` read in a NUMERIC `source` (a
    /// modifier value / a `.system(size:)` arg). Rewrites each `.number`-kind path
    /// `input.member` → `__numtok_<id>` (the thunk evaluates `self.input.member`). Returns the
    /// rewritten source, or nil if ANY input-member base is used in a way we can't project (a
    /// bare pass / a non-`.number` member in a numeric position / an unknown member) — then the
    /// caller demotes (a residual base would leak as a free guest symbol). Demote-safe.
    private mutating func hostProjectInputComputedMemberReads(in source: String) -> String? {
        guard !inputComputedMemberPaths.isEmpty else { return nil }
        let bases = inputComputedMemberBases
        guard !bases.isEmpty,
              BodyLowering.guestBodyReferencesAny(source, names: bases) else { return nil }
        let probe = Parser.parse(source: "let __patch_icm = (\(source))")
        guard let valueExpr = Self.tokenProbeValueExpr(probe) else { return nil }
        let finder = InputMemberReadFinder(bases: bases)
        finder.walk(valueExpr)
        guard !finder.hits.isEmpty else { return nil }
        var replacements: [(text: String, with: String)] = []
        for hit in finder.hits {
            // EVERY use of the base must be a `.number`-kind computed-member access — a
            // non-`.number` member or a bare/other use in a numeric position leaks.
            guard hit.member != nil else { return nil }      // bare base use → can't project
            let path = "\(hit.base).\(hit.member!)"
            guard inputComputedMemberPaths[path] == .number else { return nil }
            let id = "nt_" + Self.stableHash64("icm|\(path)")
            if !hostTokens.contains(where: { $0.id == id }) {
                hostTokens.append(.init(id: id, source: "self.\(path)", kind: .number))
            }
            replacements.append((hit.fullText, "Double(\(BodyLowering.numericTokenInputKey(id)))"))
        }
        var out = source
        // Replace longest first so `a.bc` isn't clobbered by `a.b`.
        for (text, with) in replacements.sorted(by: { $0.text.count > $1.text.count }) {
            out = out.replacingOccurrences(of: text, with: with)
        }
        // No residual base may remain (full projection).
        if BodyLowering.guestBodyReferencesAny(out, names: bases) { return nil }
        return out
    }

    /// If `src` is a `<input>.<member>` read off a struct/enum INPUT whose member is a
    /// COMPUTED `.string` member, record a `.string` host token (source `self.<path>`, matching
    /// the reactive-member projection convention) and return the `__strtok_<id>` input key.
    /// Returns nil otherwise.
    private mutating func inputComputedMemberStringKey(_ src: String) -> String? {
        let path = Self.strippingLeadingSelf(src.trimmingCharacters(in: .whitespaces))
        guard inputComputedMemberPaths[path] == .string else { return nil }
        let id = "st_" + Self.stableHash64("icm|\(path)")
        if !hostTokens.contains(where: { $0.id == id }) {
            hostTokens.append(.init(id: id, source: "self.\(path)", kind: .string))
        }
        return BodyLowering.stringTokenInputKey(id)
    }

    /// If `src` is a `<input>.<member>` read off a struct/enum INPUT whose member is a
    /// COMPUTED `.font` member (`size.fontSize` where `Size.fontSize: Font { … }`), record a
    /// `.font` host token (source `self.<path>`) and return its id (the caller emits
    /// `.fontToken("<id>")`). Returns nil otherwise.
    private mutating func inputComputedMemberFontKey(_ src: String) -> String? {
        let path = Self.strippingLeadingSelf(src.trimmingCharacters(in: .whitespaces))
        guard inputComputedMemberPaths[path] == .font else { return nil }
        let id = "ft_" + Self.stableHash64("icm|\(path)")
        if !hostTokens.contains(where: { $0.id == id }) {
            hostTokens.append(.init(id: id, source: "self.\(path)", kind: .font))
        }
        return id
    }

    /// If `src` is a BARE reference to a known NUMERIC computed scalar property (G42) —
    /// an accessible (non-private) `var x: Int/Double/CGFloat { … }` of the view — record
    /// a `.number` host token (its native value resolved by the thunk over `self`) and
    /// return the reserved `__numtok_<id>` input key the guest reads. Returns nil when
    /// `src` isn't such a bare property reference (the caller falls through to the
    /// design-system-token path / its slot fallback). A `private`/`fileprivate` computed
    /// property is NOT eligible (the cross-file thunk can't call `self.<name>`).
    private mutating func computedScalarNumberKey(_ src: String) -> String? {
        // Accept a bare `x` OR an explicit `self.x` (the same self-accessible computed
        // property; `self.` is a common, harmless prefix). The token SOURCE keeps the
        // `self.`-stripped name so the thunk resolves `self.<name>` identically either way.
        guard let bare = Self.selfStrippedBareIdentifier(src),
              let kind = computedScalarProps[bare],
              kind == .int || kind == .double,
              !inaccessibleNames.contains(bare) else { return nil }
        let id = "nt_" + Self.stableHash64(bare)
        if !hostTokens.contains(where: { $0.id == id }) {
            hostTokens.append(.init(id: id, source: bare, kind: .number))
        }
        return BodyLowering.numericTokenInputKey(id)
    }

    /// If `src` is a BARE reference to a known STRING computed scalar property (G42) —
    /// an accessible `var s: String { … }` of the view — record a `.string` host token
    /// and return the reserved `__strtok_<id>` input key. Returns nil otherwise.
    private mutating func computedScalarStringKey(_ src: String) -> String? {
        guard let bare = Self.selfStrippedBareIdentifier(src),
              computedScalarProps[bare] == .string,
              !inaccessibleNames.contains(bare) else { return nil }
        let id = "st_" + Self.stableHash64(bare)
        if !hostTokens.contains(where: { $0.id == id }) {
            hostTokens.append(.init(id: id, source: bare, kind: .string))
        }
        return BodyLowering.stringTokenInputKey(id)
    }

    /// True iff `src` is exactly a bare Swift identifier (`status`, `_inset`) — no dots,
    /// calls, operators, or whitespace. A bare property reference is the only G42 shape
    /// we host-project (a transformed expression like `status.uppercased()` already
    /// routes through the regular string/number token path).
    static func isBareIdentifier(_ src: String) -> Bool {
        let s = src.trimmingCharacters(in: .whitespaces)
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The bare property name for a G42 computed-scalar host-projection: a bare
    /// identifier (`status`) as-is, OR an explicit `self.<name>` access stripped to
    /// `<name>` (`self.status` → `status`). Returns nil for any other shape (a dotted
    /// member chain `a.b.c`, a call, an operator expression) — those route through the
    /// regular string/number token path or slot. Stripping only the single `self.`
    /// prefix is safe: `self.<name>` and `<name>` denote the SAME member, and the thunk
    /// resolves the token source as `self.<name>` regardless.
    static func selfStrippedBareIdentifier(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        if isBareIdentifier(s) { return s }
        if s.hasPrefix("self.") {
            let rest = String(s.dropFirst("self.".count)).trimmingCharacters(in: .whitespaces)
            if isBareIdentifier(rest) { return rest }
        }
        return nil
    }

    /// The names a guest numeric expression can resolve WITHOUT a token: every
    /// marshalled input (scalar + scalar-array + struct-array element) the guest binds,
    /// plus the body-local names bound so far (loop vars / closure params / surviving
    /// `let`s — these are exactly the `bodyLocals` the slotability scan tracks). Safe
    /// globals (`Double`, `max`, …) and `__geo_*` are added by the scope-check itself.
    private var guestResolvableNames: Set<String> {
        var s = marshalledInputNames
        s.formUnion(scalarArrayInputNames)
        s.formUnion(structArrayInputElements.keys)
        s.formUnion(flatStructInputElements.keys)   // single flat-struct inputs (TASK 1)
        s.formUnion(enumInputElements.keys)          // raw-value enum inputs (TASK 2)
        s.formUnion(bodyLocals)
        s.formUnion(emittedLetNames)
        return s
    }

    /// Map a shape constructor expression (for `.clipShape`/`.background(_, in:)`/
    /// `.overlay(_, in:)`) to a `ShapeKind` literal — like `loweredShapeKindOrNil`, but
    /// a `RoundedRectangle(cornerRadius:)` whose radius is a design-system NUMERIC token
    /// (`Theme.Radius.lg`) routes the radius through `numericOrToken` (so it lowers as a
    /// `__numtok_<id>` reference) instead of leaking `Theme`. Returns nil when the shape
    /// isn't recognized OR its radius is neither guest-resolvable nor a resolvable token.
    mutating func shapeKindOrTokenized(_ src: String) -> String? {
        let s = src.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("Circle(") { return ".circle" }
        if s.hasPrefix("Capsule(") { return ".capsule" }
        if s.hasPrefix("Rectangle(") { return ".rectangle" }
        if s.hasPrefix("Ellipse(") { return ".ellipse" }
        if s.hasPrefix("RoundedRectangle(") {
            let r = Self.captureArg(s, "cornerRadius") ?? "0"
            guard let n = numericOrToken(r) else { return nil }
            return ".roundedRectangle(cornerRadius: Double(\(n)))"
        }
        return nil
    }

    /// Record a NUMERIC design-system token for `src` IF (1) it's STRUCTURALLY a
    /// plausible numeric token — a member access (`Theme.Radius.lg`), a min/max/abs
    /// call, or a ternary/optional thereof (NOT a view/shape constructor) — and (2) its
    /// native slot closure compiles in the cross-file thunk (references no body-local /
    /// inaccessible member). Returns the content-stable id, or nil (the caller falls
    /// back to slotting). The id derivation matches `recordTokenIfResolvable`.
    private mutating func recordNumericTokenIfResolvable(_ src: String) -> String? {
        let trimmed = src.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parsedProbe = Parser.parse(source: "let __patch_numtok = (\(trimmed))")
        let probe = OperatorTable.standardOperators.foldAll(parsedProbe) { _ in }
            .as(SourceFileSyntax.self) ?? parsedProbe
        guard let valueExpr = Self.tokenProbeValueExpr(probe),
              Self.isPlausibleNumericTokenExpr(valueExpr) else { return nil }
        // TYPE-PROVABILITY GATE (build-safe = demote-safe), the numeric analogue of the
        // color/font gate: a BARE IDENTIFIER reaching here failed the scope check (so it's
        // not a marshalled numeric input/local) and isn't a known numeric computed property,
        // so its type is unknown — `.number(Double(<name>))` could be `Double(<non-numeric>)`.
        // Admit a bare numeric identifier ONLY when its declared type is provably a numeric
        // scalar; otherwise reject (the caller slots/demotes). A member access / arithmetic /
        // numeric-call shape keeps the existing admission (a design-system constant resolves).
        if !tokenExprNumericProvable(valueExpr) { return nil }
        let blocked = bodyLocals.union(inaccessibleNames)
        if !blocked.isEmpty,
           ReferencedNameScanner.referencesAnyInSource(probe, of: blocked) {
            return nil
        }
        // DEMOTE-SAFETY (the computed-member feature's interaction with this design-system
        // numeric path): a member access whose ROOT base is a struct/enum INPUT param
        // (`size.insets`) must NEVER become a `.number` token here — `Double(self.size.insets)`
        // over a non-scalar/`EdgeInsets`/unknown member won't compile. Any `.number`-projectable
        // input read was already host-projected upstream (`numericOrToken` step b3); a residual
        // input-base reference here is non-numeric → reject (the caller slots/demotes the node).
        if !structEnumInputBases.isEmpty,
           ReferencedNameScanner.referencesAnyInSource(probe, of: structEnumInputBases) {
            return nil
        }
        let id = "nt_" + Self.stableHash64(trimmed)
        if !hostTokens.contains(where: { $0.id == id }) {
            hostTokens.append(.init(id: id, source: trimmed, kind: .number))
        }
        return id
    }

    /// Resolve a `Text(…)` CONTENT expression for the text leaf. When `raw` is
    /// guest-resolvable as written — a string literal, an interpolation over the body's
    /// in-scope inputs/locals, etc. — it's returned VERBATIM (the guest computes it in
    /// WASM, the current behavior). Otherwise, when it's a resolvable HOST STRING TOKEN
    /// (a `confidence.label`-style enum-derived String, a `.uppercased()` of one, a
    /// ternary thereof — referencing no body-local / inaccessible member), a
    /// `HostToken(kind:.string)` is recorded and the guest-readable token VARIABLE name is
    /// returned (`__strtok_<id>`) — the SDK injects the natively-resolved String there, so
    /// the leaked `confidence` (a non-reconstructable enum input) disappears. Returns nil
    /// ONLY when it's neither (the caller keeps its fallback: slot the whole Text node).
    mutating func stringContentOrToken(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // (a) Already guest-resolvable as written? Emit verbatim (a `"literal"`, a
        // `"\(name)"` interpolation over a marshalled input). Same scope-check the build
        // pipeline runs over the whole body, so "resolvable here" tracks "the guest
        // compiles". EXCEPTION: a member access whose base is a flat-struct INPUT but whose
        // field chain doesn't resolve to one of that input's marshalled fields would pass the
        // name-only scope check yet NOT compile in the guest (the mirroring struct lacks the
        // field). The reactive-collection marshalling registers `vm` carrying ONLY its
        // collection fields, so `Text(vm.title)` lands here — it must HOST-PROJECT (a string
        // token the thunk resolves natively), never leak `vm.title` verbatim. Skip the
        // verbatim path for such a read so it falls through to host-projection (b/c).
        let asWritten = SwiftUIGuestScopeCheck.check(
            guestBody: trimmed, inputNames: guestResolvableNames, usesGeometry: usesGeometry)
        if asWritten.isCompilable, !flatStructInputMemberLeaks(trimmed) {
            // EXCEPTION: an expression that passes the name-scope check may still fail to
            // compile in the Foundation-FREE WASM guest if it applies a Foundation-only String
            // property (`s.capitalized`, `s.localizedUppercase`) or method
            // (`s.trimmingCharacters(in:)`, `s.replacingOccurrences(of:with:)`) — these
            // require the Foundation module, which is absent in the embedded guest. Emitting
            // them verbatim would produce `N.text(s.capitalized)` which the WASM compiler
            // rejects, silently demoting the view via the convergence loop.
            //
            // Instead, fall through to host-projection: the thunk evaluates the whole
            // expression natively (Foundation is available in the full app) and injects the
            // resolved String via the `__strtok_<id>` mechanism — EXACT same mechanism
            // `confidence.label.uppercased()` already uses.
            //
            // INERTNESS GUARD: if the path is in `stringTypedMemberPaths` it is a STORED
            // String field of a mirrored struct input — the guest struct carries the field
            // directly, Foundation is NOT needed, verbatim is correct. Don't intercept.
            let stripped = Self.strippingLeadingSelf(trimmed)
            let guardedByKnownField = stringTypedMemberPaths.contains(stripped)
            if guardedByKnownField
                || !Self.expressionAppliesFoundationOnlyStringMember(trimmed) {
                return trimmed
            }
            // Foundation-only member detected: fall through to (b)/(c) for host-projection.
        }
        // (b) A bare reference to a STRING computed scalar property (G42:
        // `Text(status)` where `var status: String { … }` reads state) → host-project it.
        if let key = computedScalarStringKey(trimmed) { return key }
        // (b2) A `<input>.<member>` read off a struct/enum INPUT whose member is a COMPUTED
        // `String` (`Text(size.label)` where `Size.label: String { … }`) → host-project it.
        if let key = inputComputedMemberStringKey(trimmed) { return key }
        // (c) Not resolvable as written — try it as a HOST STRING TOKEN.
        guard let id = recordStringTokenIfResolvable(trimmed) else { return nil }
        return BodyLowering.stringTokenInputKey(id)
    }

    /// Record a HOST STRING token for `src` IF (1) it's STRUCTURALLY a plausible string
    /// token — a member access (`confidence.label`), a `.uppercased()`/`.lowercased()`-
    /// style String method call, a ternary/optional thereof, or a string-interpolation /
    /// concatenation thereof (NOT a view/number/color constructor) — and (2) its native
    /// slot closure compiles in the cross-file thunk (references no body-local /
    /// inaccessible member). Returns the content-stable id, or nil (the caller slots).
    private mutating func recordStringTokenIfResolvable(_ src: String) -> String? {
        let trimmed = src.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parsedProbe = Parser.parse(source: "let __patch_strtok = (\(trimmed))")
        let probe = OperatorTable.standardOperators.foldAll(parsedProbe) { _ in }
            .as(SourceFileSyntax.self) ?? parsedProbe
        guard let valueExpr = Self.tokenProbeValueExpr(probe),
              Self.isPlausibleStringTokenExpr(valueExpr),
              // THE type-safety gate (build-safe = demote-safe): the thunk emits
              // `.string(<src>)`, whose arg MUST be a `String`. A member access is
              // structurally plausible (`confidence.label`) but UNTYPED — `feature.description`
              // is an `AttributedString`, `item.count` an `Int` — so `.string(<that>)` fails
              // to compile. Tokenize ONLY when the expr is PROVABLY a `String` (a literal/
              // interpolation, a `String(...)` cast, a String-returning method tail like
              // `.uppercased()`, a `+` concat with a provable operand, a `?? "literal"`, or a
              // ternary thereof); an unproven shape (a bare member access / property chain)
              // returns nil → the caller slots the whole `Text` node natively (faithful).
              // EXCEPTION (still build-safe): a bare member-access PATH the local struct
              // catalog proves is a non-optional `String` (`profile.name`) is admitted —
              // `.string(self.profile.name)` compiles. `stringTypedMemberPaths` carries
              // exactly those paths; `feature.description` (AttributedString) is NOT in it.
              (Self.stringTokenTypeProvable(valueExpr)
               || stringTypedMemberPaths.contains(Self.strippingLeadingSelf(trimmed)))
              else { return nil }
        let blocked = bodyLocals.union(inaccessibleNames)
        if !blocked.isEmpty,
           ReferencedNameScanner.referencesAnyInSource(probe, of: blocked) {
            return nil
        }
        let id = "st_" + Self.stableHash64(trimmed)
        if !hostTokens.contains(where: { $0.id == id }) {
            hostTokens.append(.init(id: id, source: trimmed, kind: .string))
        }
        return id
    }

    /// Drop a leading `self.` qualifier so a member-access source matches the unqualified
    /// paths in `stringTypedMemberPaths` (`self.profile.name` → `profile.name`). The path
    /// set is keyed by the property's bare name; the thunk re-qualifies with `self.` anyway.
    static func strippingLeadingSelf(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("self.") ? String(t.dropFirst("self.".count)) : t
    }

    /// True iff `expr` is structurally a plausible HOST STRING token value — a member
    /// access (`confidence.label`, `.label`), a method/func call whose callee is a MEMBER
    /// ACCESS (`x.uppercased()`, `confidence.label.uppercased()`), a string-literal (incl.
    /// interpolation), a `String(...)` cast, a `+` concatenation of plausibles, or a
    /// ternary/optional/parenthesized thereof. It is FALSE for a bare type-CONSTRUCTOR call
    /// (`SomeView()`) and for an obviously-numeric expression — those must never be mistaken
    /// for a string.
    ///
    /// DELIBERATELY EXCLUDES a BARE IDENTIFIER (`Text(someProp)`): a bare reference is
    /// either a marshalled scalar input (already guest-resolvable → emitted verbatim, never
    /// reaches here) or a non-reconstructable/`@State` stored property — host-tokenizing the
    /// latter would (a) bypass the marshalling/dispatch path a plain mutable scalar should
    /// take, and (b) ship a view the existing unmarshalled-input guard intentionally
    /// excludes. Requiring a TRANSFORMATION (member access / method call / interpolation /
    /// ternary / concat) targets exactly the enum/host-derived content (`confidence.label`)
    /// the host must resolve, leaving plain property reads to their established path.
    static func isPlausibleStringTokenExpr(_ expr: ExprSyntax) -> Bool {
        if expr.is(MemberAccessExprSyntax.self) { return true }
        if let lit = expr.as(StringLiteralExprSyntax.self) {
            // A SwiftUI-only interpolation overload (`"\(v, specifier:)"`) is NOT a plain
            // `String` — the thunk emits the token as `.string(<source>)`, which would fail
            // to compile (plain `String.StringInterpolation` lacks the overload). Reject it
            // as a string token so the caller slots the whole node instead (faithful native).
            return !Self.literalHasSwiftUIInterpolationOverload(lit)
        }
        if let t = expr.as(TernaryExprSyntax.self) {
            return isPlausibleStringTokenExpr(t.thenExpression) && isPlausibleStringTokenExpr(t.elseExpression)
        }
        if let f = expr.as(ForceUnwrapExprSyntax.self) { return isPlausibleStringTokenExpr(f.expression) }
        if let o = expr.as(OptionalChainingExprSyntax.self) { return isPlausibleStringTokenExpr(o.expression) }
        if let tup = expr.as(TupleExprSyntax.self), tup.elements.count == 1,
           let only = tup.elements.first, only.label == nil {
            return isPlausibleStringTokenExpr(only.expression)
        }
        // A folded `+` concatenation (`prefix + name`, `a.label + b.label`).
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            if let op = infix.operator.as(BinaryOperatorExprSyntax.self), op.operator.text == "+" {
                return isPlausibleStringTokenExpr(infix.leftOperand)
                    && isPlausibleStringTokenExpr(infix.rightOperand)
            }
            return false
        }
        // A call: plausible when the callee is a MEMBER ACCESS (`x.uppercased()`,
        // `Theme.label(x)`) — a String method/factory — or a bare `String(...)` cast.
        // A call whose callee is a bare type name (`SomeView()`) is a constructor, NOT a
        // string, so it's rejected (it's handled as a view/leaf elsewhere).
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if call.calledExpression.is(MemberAccessExprSyntax.self) { return true }
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
               callee.baseName.text == "String" {
                return call.arguments.allSatisfy { isPlausibleStringTokenExpr($0.expression) }
            }
            return false
        }
        return false
    }

    /// THE string-token type-safety gate (build-safe = demote-safe). True iff a `.string(…)`
    /// token over `expr` is GUARANTEED to be a `String`, so the thunk's `.string(<src>)`
    /// compiles. The hazard this closes: a BARE MEMBER ACCESS (`feature.description`,
    /// `item.count`) is structurally a plausible string token but carries NO static type —
    /// `description` can be an `AttributedString`, a member can be any type — so
    /// `.string(feature.description)` is `cannot convert 'AttributedString' to 'String'`.
    ///
    /// Provable shapes (each GUARANTEES a `String`):
    ///   * a STRING LITERAL / interpolation (non-SwiftUI-overload — already vetted);
    ///   * a `String(...)` CAST;
    ///   * a CALL whose final member is a known String-returning method
    ///     (`.uppercased()`/`.lowercased()`/`.capitalized`/`.trimmingCharacters(…)`/
    ///     `.replacingOccurrences(…)`/`.joined(…)`/`.formatted()`) — a String transformation;
    ///   * a `+` CONCATENATION with at least one PROVABLE operand (`"x" + name` is String);
    ///   * a `?? "literal"` whose default is a string literal (the whole expr is String);
    ///   * a TERNARY / FORCE-UNWRAP / OPTIONAL-CHAIN / PAREN whose sub-branches are provable.
    ///
    /// The UNPROVABLE shapes — a bare member access (`x.label`), a bare property chain — are
    /// REJECTED → the caller slots the whole `Text` node natively (it renders faithfully from
    /// `self`) or, for a body-local/inaccessible read, demotes the view at build time. This is
    /// the STRING analogue of `tokenExprTypeProvable` (color/font) and `tokenExprNumericProvable`.
    static func stringTokenTypeProvable(_ expr: ExprSyntax) -> Bool {
        // A string literal / interpolation (the SwiftUI-overload form was already rejected
        // by `isPlausibleStringTokenExpr`, so any literal reaching here is a plain `String`).
        if expr.is(StringLiteralExprSyntax.self) { return true }
        // Recurse through value-preserving wrappers.
        if let t = expr.as(TernaryExprSyntax.self) {
            return stringTokenTypeProvable(t.thenExpression) && stringTokenTypeProvable(t.elseExpression)
        }
        if let f = expr.as(ForceUnwrapExprSyntax.self) { return stringTokenTypeProvable(f.expression) }
        if let o = expr.as(OptionalChainingExprSyntax.self) { return stringTokenTypeProvable(o.expression) }
        if let tup = expr.as(TupleExprSyntax.self), tup.elements.count == 1,
           let only = tup.elements.first, only.label == nil {
            return stringTokenTypeProvable(only.expression)
        }
        // A binary operator: `+` concat (String iff ≥1 provable operand — a `String + T`
        // overload only exists for `String`), or `??` with a string-literal default.
        if let infix = expr.as(InfixOperatorExprSyntax.self),
           let op = infix.operator.as(BinaryOperatorExprSyntax.self) {
            switch op.operator.text {
            case "+":
                return stringTokenTypeProvable(infix.leftOperand)
                    || stringTokenTypeProvable(infix.rightOperand)
            case "??":
                // `a ?? "default"` — the whole expr is String iff the default is a String
                // literal (the `a` side is then a `String?`, so the result is `String`).
                return stringTokenTypeProvable(infix.rightOperand)
            default:
                return false
            }
        }
        // A call: provable iff it's a `String(...)` cast or a String-returning method tail.
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
               callee.baseName.text == "String" {
                return true
            }
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                return stringReturningMethods.contains(member.declName.baseName.text)
            }
            return false
        }
        // A member access whose PROPERTY NAME is a Foundation-only String property
        // (`.capitalized`, `.localizedCapitalized` etc.) is provably a `String` in the
        // THUNK context — the thunk always has Foundation. This handles `s.capitalized`
        // (property access, no parentheses) so the thunk can emit `.string(s.capitalized)`
        // safely. The function-call form `.capitalized()` (invalid Swift) is already
        // handled by `stringReturningMethods` above.
        if let member = expr.as(MemberAccessExprSyntax.self),
           foundationOnlyStringProperties.contains(member.declName.baseName.text) {
            return true
        }
        // A bare member access (`confidence.label`, `feature.description`) or anything else
        // is NOT provably a String.
        return false
    }

    /// Method names that return a `String` (a String transformation tail). A member-access
    /// call ending in one of these is a provable string token; any other member call
    /// (`.formatted(.percent)` returns various, `.description` may be non-String) stays
    /// conservative outside this set. `.formatted()` (no-arg) returns String for the common
    /// `FormatStyle` defaults; only the no-arg form is admitted (an arg form is excluded —
    /// it's ambiguous), checked by the caller via the bare method name plus the structural
    /// gate (`isPlausibleStringTokenExpr` already required a member-access callee).
    static let stringReturningMethods: Set<String> = [
        "uppercased", "lowercased", "capitalized", "trimmingCharacters",
        "replacingOccurrences", "joined", "appending", "appendingFormat",
        // NOTE (BUG #28/#34): `trimmingPrefix` returns a `Substring`, NOT a `String`, so a
        // `.string(x.trimmingPrefix("…"))` token fails to compile in the dev's thunk. It is
        // DELIBERATELY excluded — such a read slots/demotes (faithful) instead of shipping an
        // uncompilable thunk. Only genuinely String-returning tails belong here.
    ]

    /// Foundation-only String PROPERTIES (accessed without parentheses, e.g. `s.capitalized`)
    /// that are absent from the Foundation-free WASM guest stdlib. An expression applying one
    /// of these to a String base will fail to compile in the guest even when the base
    /// identifier is in scope. Stdlib methods (`uppercased()`, `lowercased()`) are NOT here.
    ///
    /// Each entry is the bare member name (the `.member` in a MemberAccessExprSyntax):
    ///   `capitalized`        — `String.capitalized` (Foundation)
    ///   `localizedCapitalized` — Foundation
    ///   `localizedLowercase`   — Foundation
    ///   `localizedUppercase`   — Foundation
    static let foundationOnlyStringProperties: Set<String> = [
        "capitalized", "localizedCapitalized", "localizedLowercase", "localizedUppercase",
    ]

    /// Foundation-only String METHOD names (called WITH parentheses) that are absent from
    /// the Foundation-free WASM guest. A call ending in one of these would compile from the
    /// scope-check perspective (the base is in scope) but fail WASM compilation because the
    /// method requires Foundation. Stdlib methods (`uppercased`, `lowercased`, `joined`) are
    /// NOT included here.
    static let foundationOnlyStringMethodNames: Set<String> = [
        "trimmingCharacters", "replacingOccurrences", "appending", "appendingFormat",
    ]

    /// True iff `src` applies a Foundation-only String property (`.capitalized`) or method
    /// (`.trimmingCharacters(in:)`, `.replacingOccurrences(of:with:)`) at any level of the
    /// member-access chain, such that the expression would FAIL to compile in the Foundation-
    /// free WASM guest even though the base identifier passes the scope check.
    ///
    /// Examples that return TRUE (need host-projection):
    ///   `s.capitalized`                       — Foundation property on scalar String
    ///   `s.trimmingCharacters(in: .whitespaces)` — Foundation method on scalar String
    ///   `s.capitalized.lowercased()`           — Foundation property in the chain base
    ///   `title.localizedUppercase`             — Foundation property
    ///
    /// Examples that return FALSE (verbatim is safe):
    ///   `s.uppercased()`   — stdlib method, works in WASM
    ///   `s.lowercased()`   — stdlib
    ///   `"\(name)"`        — string literal / interpolation, no Foundation
    private static func expressionAppliesFoundationOnlyStringMember(_ src: String) -> Bool {
        let parsed = Parser.parse(source: "let __probe = (\(src))")
        guard let varDecl = parsed.statements.first?.item.as(VariableDeclSyntax.self),
              let initExpr = varDecl.bindings.first?.initializer?.value else { return false }
        return exprAppliesFoundationOnlyMember(initExpr)
    }

    /// Recursive helper for `expressionAppliesFoundationOnlyStringMember`.
    private static func exprAppliesFoundationOnlyMember(_ expr: ExprSyntax) -> Bool {
        // Unwrap a single-element parenthesized tuple `(expr)`.
        if let tup = expr.as(TupleExprSyntax.self), tup.elements.count == 1,
           let only = tup.elements.first, only.label == nil {
            return exprAppliesFoundationOnlyMember(only.expression)
        }
        // PROPERTY ACCESS `base.property`: check the property name.
        if let member = expr.as(MemberAccessExprSyntax.self) {
            if foundationOnlyStringProperties.contains(member.declName.baseName.text) { return true }
            // Recurse into the base: catches chains like `s.capitalized.lowercased()` where
            // the Foundation property is in the inner member access of the base.
            if let base = member.base { return exprAppliesFoundationOnlyMember(base) }
        }
        // METHOD CALL `base.method(…)`: check the method name or recurse into the base.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            if foundationOnlyStringMethodNames.contains(member.declName.baseName.text) { return true }
            // Recurse into the callee's base (e.g. `s.capitalized.lowercased()` — the
            // callee of `.lowercased()` is `s.capitalized` which has the Foundation member).
            if let base = member.base { return exprAppliesFoundationOnlyMember(base) }
        }
        // TERNARY: Foundation-only iff EITHER branch uses it (if one side would fail,
        // the whole verbatim expression fails; must host-project the whole ternary).
        if let t = expr.as(TernaryExprSyntax.self) {
            return exprAppliesFoundationOnlyMember(t.thenExpression)
                || exprAppliesFoundationOnlyMember(t.elseExpression)
        }
        return false
    }

    /// True iff `expr` is structurally a plausible NUMERIC design-token value — a
    /// member access (`Theme.Radius.lg`, `.lg`), a bare identifier (a CGFloat constant
    /// — accessibility checked separately), a `min`/`max`/`abs`/`CGFloat`/`Double` call
    /// over plausible args, a binary arithmetic expression of plausibles, or a ternary /
    /// optional / parenthesized thereof. FALSE for a view/shape constructor (`Capsule()`)
    /// or any string/color-looking expression — those must never be mistaken for a number.
    static func isPlausibleNumericTokenExpr(_ expr: ExprSyntax) -> Bool {
        if expr.is(MemberAccessExprSyntax.self) { return true }
        if expr.is(DeclReferenceExprSyntax.self) { return true }
        if expr.is(IntegerLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self) { return true }
        if let t = expr.as(TernaryExprSyntax.self) {
            return isPlausibleNumericTokenExpr(t.thenExpression) && isPlausibleNumericTokenExpr(t.elseExpression)
        }
        if let f = expr.as(ForceUnwrapExprSyntax.self) { return isPlausibleNumericTokenExpr(f.expression) }
        if let o = expr.as(OptionalChainingExprSyntax.self) { return isPlausibleNumericTokenExpr(o.expression) }
        if let tup = expr.as(TupleExprSyntax.self), tup.elements.count == 1,
           let only = tup.elements.first, only.label == nil {
            return isPlausibleNumericTokenExpr(only.expression)
        }
        // A folded binary arithmetic expression (`Theme.Radius.lg * 0.5`, `a + b`).
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return isPlausibleNumericTokenExpr(infix.leftOperand)
                && isPlausibleNumericTokenExpr(infix.rightOperand)
        }
        // A numeric free-function / cast call (`min(a,b)`, `CGFloat(x)`, `Double(x)`),
        // whose callee is a bare numeric name and whose args are all plausible.
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
               numericTokenCallees.contains(callee.baseName.text) {
                return call.arguments.allSatisfy { isPlausibleNumericTokenExpr($0.expression) }
            }
            // `Theme.Font.body(13).x` style is NOT numeric — a member-call callee is
            // rejected (it's the color/font token shape, handled elsewhere).
            return false
        }
        return false
    }

    /// Free-function/cast callees a numeric token may legitimately be built from.
    static let numericTokenCallees: Set<String> =
        ["min", "max", "abs", "CGFloat", "Double", "Float", "Int"]

    /// True iff `src` is a QUALIFIED member path rooted in a named type (`Theme.Spacing.m`,
    /// `Brand.radius`) — a plausible design-system NUMERIC token — as opposed to a
    /// LEADING-DOT enum case (`.horizontal`, `.all`) which is an `Edge.Set`, NOT a number.
    /// Used to disambiguate an all-edges `.padding(token)` from `.padding(.horizontal)`.
    static func looksLikeNumericTokenPath(_ src: String) -> Bool {
        let s = src.trimmingCharacters(in: .whitespaces)
        // A leading dot is an enum/option case, never a numeric path.
        guard let first = s.first, first != "." else { return false }
        // Must be a dotted path rooted in an identifier (`Theme.…`): at least one dot,
        // and the first character is a letter/underscore (an identifier start).
        guard s.contains("."), first.isLetter || first == "_" else { return false }
        return true
    }

    /// Record a color token for `src` IF its native slot closure is guaranteed to
    /// compile in the cross-file thunk (references no body-local / inaccessible
    /// member), returning the content-stable id. Returns nil otherwise (not
    /// resolvable → the caller demotes the whole node, never emits a token the thunk
    /// can't supply). A whitespace-only / non-expression `src` returns nil.
    private mutating func recordColorTokenIfResolvable(_ src: String) -> String? {
        recordTokenIfResolvable(src, kind: .color, idPrefix: "ct_")
    }

    /// As `recordColorTokenIfResolvable`, for a FONT token (`.font(Theme.Font.body(…))`).
    private mutating func recordFontTokenIfResolvable(_ src: String) -> String? {
        recordTokenIfResolvable(src, kind: .font, idPrefix: "ft_")
    }

    /// Shared token recorder: parse `src` as a Swift expression, require it to be a
    /// genuine value expression (not empty / not a bare type ref) whose slot closure
    /// is slotable (no body-local / inaccessible reference), and record a `HostToken`.
    /// The id is a content-stable FNV hash of the source (matching the thunk
    /// generator's derivation), so push + build agree with no shared state.
    private mutating func recordTokenIfResolvable(_ src: String,
                                                  kind: BodyLowering.HostToken.Kind,
                                                  idPrefix: String) -> String? {
        let trimmed = src.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Parse the expression so we can both (a) check slotability and (b) verify it's
        // STRUCTURALLY a plausible color/font token — NOT a view/struct constructor.
        // Without (b), `.background(SomeCustomView())` (checked in the color slot before
        // the shape-view-child form) would be mis-recorded as a color token, and the
        // thunk would emit `.color(SomeCustomView())` — wrong (a View isn't a Color).
        // A recognized NON-color ShapeStyle (a material/gradient/semantic/hierarchical
        // — `.ultraThinMaterial`, `.blue.gradient`, `.separator`) is NOT a design-system
        // token: the static resolver already lowers it. Reject it here so a style isn't
        // mis-recorded as a host-token color (the caller's style path handles it).
        if let style = Self.loweredShapeStyleOrNil(trimmed), !style.hasPrefix(".color(") {
            return nil
        }
        let parsedProbe = Parser.parse(source: "let __patch_tok = (\(trimmed))")
        // Operator-fold so a ternary `a ? b : c` is a real `TernaryExpr` (the raw parse
        // leaves it an unfolded `SequenceExpr`), letting `isPlausibleTokenExpr` see it.
        let probe = OperatorTable.standardOperators.foldAll(parsedProbe) { _ in }
            .as(SourceFileSyntax.self) ?? parsedProbe
        guard let valueExpr = Self.tokenProbeValueExpr(probe),
              Self.isPlausibleTokenExpr(valueExpr) else { return nil }
        // TYPE-PROVABILITY GATE (build-safe = demote-safe). `isPlausibleTokenExpr` is a
        // STRUCTURAL check — it admits a bare identifier on the (false) assumption that a
        // bare name in a color/font modifier slot is a color/font value. But a bare
        // identifier's TYPE is unknown: `.background(backgroundView)` where `backgroundView`
        // is `some View` is syntactically identical to `.background(myColor)` where
        // `myColor: Color`. Recording the former as a `.color` token makes the thunk emit
        // `.color(backgroundView)` → `Cannot convert value of type 'some View' to expected
        // argument type 'Color'`. So a bare identifier (or a ternary/optional thereof) is
        // admitted ONLY when its declared type is PROVABLY the token's kind (`Color` for a
        // color token, `Font` for a font token). Otherwise the token is rejected (nil) and
        // the caller native-slots the whole modifier (a `.background`/`.overlay` view child)
        // or demotes — faithful over a wrong-type guess. Member accesses / calls / `Color(…)`
        // constructors keep the existing (correct) admission; only the UNPROVABLE bare-name
        // shape is tightened.
        if (kind == .color || kind == .font),
           !tokenExprTypeProvable(valueExpr, kind: kind) {
            return nil
        }
        // Reuse the same slotability rule as opaque leaves: no reference to a body-local
        // or an inaccessible (private/fileprivate) member (the cross-file thunk closure
        // `{ <src> }` would not compile otherwise).
        let blocked = bodyLocals.union(inaccessibleNames)
        if !blocked.isEmpty,
           ReferencedNameScanner.referencesAnyInSource(probe, of: blocked) {
            return nil
        }
        let id = idPrefix + Self.stableHash64(trimmed)
        if !hostTokens.contains(where: { $0.id == id }) {
            hostTokens.append(.init(id: id, source: trimmed, kind: kind))
        }
        return id
    }

    /// The value expression of the `let __patch_tok = (<expr>)` probe (unwrapping the
    /// added parentheses), or nil if the probe didn't parse to a binding initializer.
    static func tokenProbeValueExpr(_ tree: SourceFileSyntax) -> ExprSyntax? {
        for stmt in tree.statements {
            guard let decl = stmt.item.as(VariableDeclSyntax.self),
                  let binding = decl.bindings.first,
                  var expr = binding.initializer?.value else { continue }
            // Unwrap the wrapping `( … )`.
            while let tuple = expr.as(TupleExprSyntax.self),
                  tuple.elements.count == 1, let only = tuple.elements.first, only.label == nil {
                expr = only.expression
            }
            return expr
        }
        return nil
    }

    /// THE type-safety gate (build-safe = demote-safe). True iff a color/font token over
    /// `expr` is TYPE-PROVABLE — i.e. the build-time thunk's `.color(<src>)` / `.font(<src>)`
    /// is GUARANTEED to be a `Color` / `Font`, so it compiles. The hazard this closes: a
    /// BARE IDENTIFIER (`backgroundView`, `makeBackground`) carries no static type info, so
    /// `.color(backgroundView)` over a `some View` property is `Cannot convert value of type
    /// 'some View' to expected argument type 'Color'`.
    ///
    /// Provable shapes (all GUARANTEE the thunk's `.color`/`.font` arg is the right type):
    ///   * a MEMBER ACCESS (`Theme.Colors.ink`, `.red`, `confidence.dot`, `Color.white`) —
    ///     a `Type.member`/`.member`/`value.member` namespace access is a strong, idiomatic
    ///     design-system color/font signal; the thunk evaluates it natively, and the engine
    ///     has long treated these as the canonical token (the real-world `Theme` case).
    ///   * a CALL whose callee is a member access or `Color(…)`/`UIColor(…)` constructor
    ///     (`Theme.Font.body(13)`, `Color.white.opacity(0.5)`, `Color(.systemBackground)`) —
    ///     a color/font-producing call; `isPlausibleTokenExpr` already rejected view/shape
    ///     calls, so a member-rooted call here resolves to the token type.
    ///   * a TERNARY / FORCE-UNWRAP / OPTIONAL-CHAIN / PAREN whose every sub-branch is
    ///     itself provable.
    ///
    /// The UNPROVABLE shape — a BARE IDENTIFIER — is admitted ONLY when its declared type is
    /// known to be the token's kind (`colorTypedNames` for a color, `fontTypedNames` for a
    /// font). Everything else (an unknown bare name) is rejected → the caller native-slots
    /// the modifier or demotes (faithful over a wrong-type guess).
    private func tokenExprTypeProvable(_ expr: ExprSyntax,
                                       kind: BodyLowering.HostToken.Kind) -> Bool {
        // A bare identifier: provable ONLY when its declared type matches the token kind.
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            switch kind {
            case .color: return colorTypedNames.contains(name)
            case .font: return fontTypedNames.contains(name)
            default: return false
            }
        }
        // A member access — the canonical, type-trusted design-system token shape.
        if expr.is(MemberAccessExprSyntax.self) { return true }
        // Recurse through value-preserving wrappers.
        if let t = expr.as(TernaryExprSyntax.self) {
            return tokenExprTypeProvable(t.thenExpression, kind: kind)
                && tokenExprTypeProvable(t.elseExpression, kind: kind)
        }
        if let f = expr.as(ForceUnwrapExprSyntax.self) {
            return tokenExprTypeProvable(f.expression, kind: kind)
        }
        if let o = expr.as(OptionalChainingExprSyntax.self) {
            return tokenExprTypeProvable(o.expression, kind: kind)
        }
        if let tup = expr.as(TupleExprSyntax.self), tup.elements.count == 1,
           let only = tup.elements.first, only.label == nil {
            return tokenExprTypeProvable(only.expression, kind: kind)
        }
        // A call: provable when it's a member-rooted or `Color`/`UIColor` constructor call
        // (the same admission `isPlausibleTokenExpr` already vetted as non-view/non-shape).
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                return callee.baseName.text == "Color" || callee.baseName.text == "UIColor"
            }
            // A member-rooted call (`X.y(…)`, `.red.opacity(…)`) is admitted; a
            // view/shape-producing call was already rejected by `isPlausibleTokenExpr`.
            return call.calledExpression.is(MemberAccessExprSyntax.self)
        }
        // Anything else (a literal, an operator expr, etc.) isn't a provable color/font token.
        return false
    }

    /// The NUMERIC analogue of `tokenExprTypeProvable` (build-safe = demote-safe). True iff
    /// a numeric token over `expr` is GUARANTEED `Double(<src>)`-convertible, so the thunk's
    /// `.number(Double(<src>))` compiles. A BARE IDENTIFIER is admitted ONLY when its
    /// declared type is provably a numeric scalar (`numericTypedNames`); a member access,
    /// arithmetic, numeric-call, or literal keeps the existing (correct) admission — a
    /// design-system numeric constant (`Theme.Radius.lg`) resolves natively. An unknown bare
    /// name is rejected → the caller slots/demotes.
    /// The leftmost (root) identifier of a member-access chain (`Theme.Radius.lg` → "Theme",
    /// `theme.insets` → "theme"). nil for an implicit member (`.lg`) or a non-identifier base
    /// (a call/subscript). Distinguishes a STATIC design-token path (uppercase Type root,
    /// provably a constant) from an INSTANCE member of unknown type (lowercase root).
    static func memberAccessRootIdentifier(_ expr: ExprSyntax) -> String? {
        var cur: ExprSyntax = expr
        while let m = cur.as(MemberAccessExprSyntax.self) {
            guard let base = m.base else { return nil }   // implicit member `.lg`
            cur = base
        }
        return cur.as(DeclReferenceExprSyntax.self)?.baseName.text
    }

    private func tokenExprNumericProvable(_ expr: ExprSyntax) -> Bool {
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return numericTypedNames.contains(ref.baseName.text)
        }
        // A member access is a numeric token ONLY when it's a STATIC design-token path whose
        // ROOT is an uppercase Type (`Theme.Radius.lg`) — provably a compile-time constant.
        // An INSTANCE member of unknown type (`theme.insets` → EdgeInsets, `layout.metrics` →
        // CGSize) is NOT trusted: `.number(Double(theme.insets))` fails the dev's thunk compile
        // (BUG #10). Catalog-resolvable instance reads (`size.iconSize`, `vm.spacing`) are
        // host-projected UPSTREAM and never reach here. build-safe = demote-safe (untrusted →
        // the caller slots/demotes).
        if expr.is(MemberAccessExprSyntax.self) {
            if let root = Self.memberAccessRootIdentifier(expr), let f = root.first, f.isUppercase {
                return true
            }
            return false
        }
        if expr.is(IntegerLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self) { return true }
        if let t = expr.as(TernaryExprSyntax.self) {
            return tokenExprNumericProvable(t.thenExpression) && tokenExprNumericProvable(t.elseExpression)
        }
        if let f = expr.as(ForceUnwrapExprSyntax.self) { return tokenExprNumericProvable(f.expression) }
        if let o = expr.as(OptionalChainingExprSyntax.self) { return tokenExprNumericProvable(o.expression) }
        if let tup = expr.as(TupleExprSyntax.self), tup.elements.count == 1,
           let only = tup.elements.first, only.label == nil {
            return tokenExprNumericProvable(only.expression)
        }
        // Arithmetic of provables (`Theme.Radius.lg * 0.5`).
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return tokenExprNumericProvable(infix.leftOperand) && tokenExprNumericProvable(infix.rightOperand)
        }
        // A numeric free-function/cast call (`min(a,b)`, `CGFloat(x)`) — args all provable.
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
               Self.numericTokenCallees.contains(callee.baseName.text) {
                return call.arguments.allSatisfy { tokenExprNumericProvable($0.expression) }
            }
            return false
        }
        return false
    }

    /// True iff `expr` is structurally a plausible COLOR/FONT token value — a member
    /// access (`Theme.Colors.ink`, `confidence.dot`), a bare identifier (a local/prop
    /// holding a color/font), a method/func call whose callee is a MEMBER ACCESS
    /// (`Theme.Font.body(13)`, `Color.white.opacity(0.5)`, `.red.opacity(0.3)`), a
    /// ternary whose branches are plausible, or a force-unwrap/optional thereof. It is
    /// FALSE for a bare type-CONSTRUCTOR call (`SomeView()`, `Capsule()`) — those are
    /// views/structs, not color/font members, and must NOT be mistaken for a token.
    static func isPlausibleTokenExpr(_ expr: ExprSyntax) -> Bool {
        // A member access (`A.b`, `.b`, `a.b.c`) — the canonical token shape.
        if expr.is(MemberAccessExprSyntax.self) { return true }
        // A bare identifier (a local/prop of color/font type — its accessibility is
        // checked separately by the slotability scan).
        if expr.is(DeclReferenceExprSyntax.self) { return true }
        // A ternary: both branches must be plausible token values.
        if let t = expr.as(TernaryExprSyntax.self) {
            return isPlausibleTokenExpr(t.thenExpression) && isPlausibleTokenExpr(t.elseExpression)
        }
        // A force-unwrap / optional-chained / parenthesized inner.
        if let f = expr.as(ForceUnwrapExprSyntax.self) { return isPlausibleTokenExpr(f.expression) }
        if let o = expr.as(OptionalChainingExprSyntax.self) { return isPlausibleTokenExpr(o.expression) }
        if let tup = expr.as(TupleExprSyntax.self), tup.elements.count == 1,
           let only = tup.elements.first, only.label == nil {
            return isPlausibleTokenExpr(only.expression)
        }
        // A call: plausible ONLY when the callee is a MEMBER ACCESS (`X.y(…)`,
        // `Color.white.opacity(…)`, `Theme.Font.body(13)`) AND the member is NOT a
        // VIEW-PRODUCING modifier. A call whose callee is a bare type name (`Capsule()`,
        // `SomeView()`) is a constructor — NOT a token; and `Capsule().fill(c)` /
        // `shape.stroke(c)` produce a VIEW, not a color/font, so they must be rejected
        // here (they're handled as a background/overlay shape-view child instead).
        if let call = expr.as(FunctionCallExprSyntax.self) {
            // G15b: a `Color(...)` / `UIColor(...)` CONSTRUCTOR is a genuine Color value
            // the thunk can evaluate natively (`Color(uiColor:)`, `Color(.systemBackground)`,
            // `Color(hex:)`, `Color("AssetName")`). The callee is a bare type name, so the
            // generic "callee must be a member access" rule below would reject it — allow
            // these two color-producing type constructors explicitly.
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
               callee.baseName.text == "Color" || callee.baseName.text == "UIColor" {
                return true
            }
            guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return false }
            if Self.viewProducingMembers.contains(member.declName.baseName.text) { return false }
            // Also reject if the call's base chain is rooted in a SHAPE constructor
            // (`Capsule().fill(...)` → base `Capsule()` is a shape view).
            if Self.isShapeRooted(ExprSyntax(member)) { return false }
            return true
        }
        return false
    }

    /// Members that turn a Shape/View into a VIEW (so an expression ending in one is
    /// NOT a color/font value, even though its callee is a member access).
    static let viewProducingMembers: Set<String> = [
        "fill", "stroke", "strokeBorder", "frame", "background", "overlay",
        "clipShape", "padding", "fixedSize", "cornerRadius", "offset", "scaleEffect",
        "rotationEffect", "shadow", "mask", "border", "blur", "brightness", "contrast",
        // `.ignoresSafeArea()` / `.edgesIgnoringSafeArea(_:)` turn a `Color` into a VIEW
        // (`some View`), so `.background(color.ignoresSafeArea())` is NOT a color token —
        // `.color(<that>)` would be `cannot convert 'some View' to expected 'Color'`. They
        // must be rejected here so the whole `.background` node native-slots (faithful).
        "ignoresSafeArea", "edgesIgnoringSafeArea"
    ]

    /// True iff the innermost base of a member/call chain is a SHAPE constructor
    /// (`Capsule()`, `Circle()`, `RoundedRectangle(...)`, `Rectangle()`, `Ellipse()`).
    static func isShapeRooted(_ expr: ExprSyntax) -> Bool {
        var cur: ExprSyntax? = expr
        while let e = cur {
            if let call = e.as(FunctionCallExprSyntax.self) {
                if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
                   knownShapeConstructors.contains(callee.baseName.text) {
                    return true
                }
                cur = call.calledExpression
            } else if let member = e.as(MemberAccessExprSyntax.self) {
                cur = member.base
            } else {
                return false
            }
        }
        return false
    }

    static let knownShapeConstructors: Set<String> =
        ["Capsule", "Circle", "RoundedRectangle", "Rectangle", "Ellipse", "UnevenRoundedRectangle"]

    static func safeLabel(_ s: String) -> String {
        // The label is a COSMETIC identifier baked into an `N.opaque(…, label: "…")`
        // Swift string literal in the guest body (the slot renders NATIVELY via `id`;
        // labels are fingerprint-EXCLUDED). It must therefore contain only characters
        // LEGAL inside a double-quoted Swift literal, or the guest fails to compile and
        // production's convergence loop silently drops the whole view. The hazards:
        //   • `"`  closes the literal                              → `'`
        //   • `\`  starts an escape; a lone source backslash (a regex/path literal
        //          baked into the slot source) → "invalid escape sequence in literal" → `/`
        //   • control chars — newline/CR/TAB AND the `\u{1}k\u{1}` lifted-arg sentinels
        //          the StringLiteralLifter injects → "unprintable ASCII character found
        //          in source" → space. (Swift rejects a RAW tab/newline inside a literal;
        //          they must be `\t`/`\n` escapes. Since the label is purely cosmetic and
        //          truncated, mapping every control char to a space is simplest + safe —
        //          and a raw-tab label only ever occurs in a view that ALREADY fails to
        //          compile, so this has zero blast radius on already-compiling views.)
        var out = ""
        out.unicodeScalars.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("'")
            case "\\": out.append("/")
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { out.append(" ") }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return String(out.prefix(60))
    }

    /// A leaf is slotable iff its slot closure `{ AnyView(<source>) }` (captured
    /// over `self` in the generated extension) is guaranteed to compile — i.e. it
    /// references NO `blocked` name. `blocked` = body-locals (not in scope in the
    /// extension) ∪ the view's private/fileprivate members (the cross-file thunk
    /// can't access them). Self's accessible members, types, and globals resolve
    /// fine, so they're not blocked.
    static func isSlotable(_ expr: ExprSyntax, blocked: Set<String>) -> Bool {
        if blocked.isEmpty { return true }
        // A name BOUND WITHIN the leaf — a `ForEach`/`for` loop var, a closure parameter,
        // an `if let`/`guard let` binding, a leaf-local `let` — is NOT a free reference: the
        // slot closure `AnyView(<expr>)` carries that binding and compiles. `bodyLocals` is
        // collected over the WHOLE body, so it over-includes such names; a leaf that binds
        // its own loop var (`ForEach(xs) { x in Row(x) }`) was wrongly judged non-slotable.
        // Subtract the leaf's OWN internal bindings; only an OUTER body-local left genuinely
        // free still blocks. SOUND for compiling input: a reference inside the leaf is either
        // bound-within (subtracted, compiles) or free-from-outside (kept, blocks). A name
        // bound in one inner scope but used outside it WITHIN the leaf can't occur in code
        // that already compiles (it would be "out of scope" in the developer's own source).
        let internalBindings = LocalNameCollector.collect(in: Syntax(expr))
        let effectiveBlocked = blocked.subtracting(internalBindings)
        if effectiveBlocked.isEmpty { return true }
        return !ReferencedNameScanner.referencesAny(expr, of: effectiveBlocked)
    }

    /// THE slot build-safety gate (build-safe = demote-safe): true iff `source` is a
    /// SINGLE view-typed EXPRESSION that compiles when spliced into `AnyView(<source>)`.
    /// The thunk's slot closure emits exactly `AnyView(<source>)` (`ThunkGenerator`), so a
    /// `source` that ISN'T such an expression produces uncompilable Swift. The classes this
    /// rejects (each a real corpus build-break):
    ///   * a bare STATEMENT body — `switch`/`for`/`while`/`guard`/bare `if`/`do` — that the
    ///     `@ViewBuilder` accepts but is illegal in argument position
    ///     (`AnyView(switch x {…})` → "'switch' may only be used as expression…");
    ///   * a fragment containing a compilation conditional (`#if … #endif`) — `#endif`
    ///     must be on its own line, so `AnyView(… #endif) }` → "extra tokens following
    ///     conditional compilation directive";
    ///   * a Void-returning ACTION expression — `withAnimation { state.toggle() }`,
    ///     `state.toggle()`, an assignment — whose result is `()`, not a `View`
    ///     (`AnyView(withAnimation {…})` → "'()' cannot conform to 'View'").
    /// A `source` that fails this gate is recorded NON-slotable, so the view demotes to
    /// native (the thunk falls through to the original `body`) — never an emitted broken
    /// wrap. A `Group { … }`-wrapped ViewBuilder source (`opaqueViewBuilder`) IS wrappable
    /// (it's a single `Group(…)` expression), so it passes.
    static func isAnyViewWrappableSource(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // A compilation conditional anywhere in the source can't be wrapped in
        // `AnyView( … )` — `#endif` must terminate a line, and the wrapper appends `) }`
        // on the `#endif` line. Reject before parsing (a mid-expression `#if` parses as a
        // postfix `IfConfigExpr` and would otherwise look like a plausible expression).
        if trimmed.contains("#if") || trimmed.contains("#endif") || trimmed.contains("#elseif") {
            return false
        }
        // Parse the source as the value of `AnyView( … )` and require it to be EXACTLY one
        // expression. A statement body (`switch`/`for`/`guard`/`do`/bare `if`/`while`) does
        // NOT parse as a single function-call argument expression, so the wrapped form has
        // a parse error — detect that directly by parsing the real wrap.
        let probe = "let __patch_wrap = AnyView(\(trimmed))"
        let tree = Parser.parse(source: probe)
        if tree.hasError { return false }
        // Locate the wrapped argument expression and reject the View-INCOMPATIBLE shapes a
        // clean parse still admits: a statement-expression (`SwitchExprSyntax` whose arms
        // `return`, captured raw), and a Void-returning action (`withAnimation { … }`, a
        // bare mutating call, an assignment).
        guard let argExpr = anyViewWrappedArgument(tree) else { return false }
        // A `return` anywhere in the wrapped source is a SEMANTIC error the parser doesn't
        // flag (`return` parses fine) but the compiler rejects in an expression/ViewBuilder
        // position ("cannot use 'return' to transfer control out of 'switch' expression").
        // This is exactly the `switch rating { case 1: return Text(…) }` corpus break — the
        // arms `return` rather than being bare expressions. Reject so the view demotes.
        if ReturnStmtFinder.contains(in: Syntax(argExpr)) { return false }
        return !isVoidReturningActionExpr(argExpr)
    }

    /// The single argument expression of the `let __patch_wrap = AnyView( <arg> )` probe,
    /// or nil if it isn't exactly one unlabeled argument.
    private static func anyViewWrappedArgument(_ tree: SourceFileSyntax) -> ExprSyntax? {
        for stmt in tree.statements {
            guard let decl = stmt.item.as(VariableDeclSyntax.self),
                  let binding = decl.bindings.first,
                  let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
                  call.arguments.count == 1,
                  let only = call.arguments.first, only.label == nil else { continue }
            return only.expression
        }
        return nil
    }

    /// True iff `expr` is a VOID-returning action expression — its value is `()`, not a
    /// `View`, so `AnyView(expr)` is "'()' cannot conform to 'View'". Recognizes the corpus
    /// shapes: a trailing-closure call to a known animation/transaction wrapper
    /// (`withAnimation { … }`, `withTransaction { … }`, `withAnimation(_:) { … }`) — whose
    /// result type is the closure's `Void` body — an assignment, and a bare
    /// `state.toggle()`/`obj.method()` mutating call (a member call with no further view
    /// modifier). A genuine view expression (`Text(…)`, `Foo().padding()`,
    /// `Group { … }`) is NOT flagged.
    private static func isVoidReturningActionExpr(_ expr: ExprSyntax) -> Bool {
        // An assignment / sequence with `=` is a statement-expr returning Void.
        if let seq = expr.as(SequenceExprSyntax.self) {
            for el in seq.elements where el.as(AssignmentExprSyntax.self) != nil { return true }
        }
        if expr.is(AssignmentExprSyntax.self) { return true }
        // A trailing-closure call whose callee is a known VOID animation/transaction
        // wrapper: `withAnimation { … }` returns the closure's result, and a mutating-
        // action closure body (`state.toggle()`) makes that `Void`.
        if let call = expr.as(FunctionCallExprSyntax.self) {
            let calleeName = (call.calledExpression.as(DeclReferenceExprSyntax.self))?.baseName.text
            if let calleeName, voidActionWrappers.contains(calleeName) { return true }
        }
        return false
    }

    /// Known free functions whose trailing-closure form returns the closure's result — so a
    /// `{ state.toggle() }` body makes the whole expression `Void`. Captured as an action
    /// (not a view) when slotted, so a leaf of this shape must demote, never `AnyView(…)`.
    static let voidActionWrappers: Set<String> = ["withAnimation", "withTransaction"]

    /// True iff `lit` is a PLAIN string literal — a single string segment, no
    /// `\(…)` interpolation. Only a plain literal's content is statically known (so
    /// markdown detection is sound); an interpolated literal is computed in the guest.
    static func stringLiteralIsPlain(_ lit: StringLiteralExprSyntax) -> Bool {
        lit.segments.allSatisfy { $0.is(StringSegmentSyntax.self) }
    }

    /// BUG R2-#65/#66/#67/#119: the shared lowering for a control's STRING-LITERAL title
    /// (`Button("…")`, `Section("…")`, `Toggle("…")`, `Link("…")`, `Menu("…")`,
    /// `Label`/`Gauge`/`ProgressView`/`LabeledContent`/`NavigationLink`/`GroupBox`/
    /// `DisclosureGroup`). Each title is a `LocalizedStringKey`, so it gets the SAME
    /// markdown + interpolation-overload handling the `Text` case already applies — a
    /// bare `N.text(<literal>)` was WRONG (markdown markers render literally) and
    /// UNSAFE (a SwiftUI-only `specifier:`/`format:` interpolation fails the guest
    /// compile). Returns:
    ///   * an `N.text(...)` / `N.styledText(..., markdown: true)` node string, OR
    ///   * `nil` — the literal carries a SwiftUI-only interpolation overload; the CALLER
    ///     must SLOT the whole control natively (the native control renders it faithfully).
    /// A non-string-literal title is not this function's concern (callers gate on
    /// `StringLiteralExprSyntax` before calling).
    static func emitTitleTextLiteral(_ expr: ExprSyntax) -> String? {
        guard let lit = expr.as(StringLiteralExprSyntax.self) else {
            return "N.text(\(expr.trimmedDescription))"
        }
        // A SwiftUI-only interpolation overload can't ride the wire as a plain String → slot.
        if literalHasSwiftUIInterpolationOverload(lit) { return nil }
        // A plain literal carrying markdown lowers as styledText so the SDK reconstitutes
        // the SAME `AttributedString(markdown:)` styling (instead of literal `**`/`[](…)`).
        if stringLiteralIsPlain(lit), literalLooksMarkdown(lit) {
            return "N.styledText(\(expr.trimmedDescription), markdown: true)"
        }
        return "N.text(\(expr.trimmedDescription))"
    }

    /// True iff `lit` carries a SwiftUI-ONLY string-interpolation overload — an
    /// `\(value, specifier: "%.1f")` / `\(n, format: .number)` / `\(date, style: .time)`
    /// / `\(image)` segment, i.e. an interpolation with a LABELED argument or MORE THAN
    /// ONE argument. These overloads exist on `LocalizedStringKey.StringInterpolation`
    /// (SwiftUI's `Text("…")` argument) but NOT on plain `String.StringInterpolation`,
    /// so emitting such a literal VERBATIM into the guest (whose `N.text(_:)` takes a
    /// plain `String`) is a guaranteed T2 type error — `incorrect argument label` /
    /// `extra argument 'format'` — which previously slipped the name-only static guard
    /// (the value identifier resolves) and only got caught by the expensive bisecting
    /// isolation backstop. Detecting it here lets the `Text` case SLOT the whole node
    /// up-front (the native `Text` renders the formatted string faithfully) — or, when
    /// the content isn't `self`-slotable, demote the view cleanly at build time — instead
    /// of shipping a body that fails the guest compile. A PLAIN interpolation
    /// (`"\(name)"`, `"\(count) items"`) is unaffected (it compiles as a plain String).
    static func literalHasSwiftUIInterpolationOverload(_ lit: StringLiteralExprSyntax) -> Bool {
        for seg in lit.segments {
            guard let expr = seg.as(ExpressionSegmentSyntax.self) else { continue }
            let elems = expr.expressions
            // A bare `\(x)` is a single, unlabeled element — a plain interpolation.
            // Anything else (a label like `specifier:`/`format:`/`style:`, or >1 element)
            // is a SwiftUI-only overload the plain `String` interpolation can't express.
            if elems.count != 1 { return true }
            if elems.first?.label != nil { return true }
        }
        return false
    }

    /// The decoded text of a PLAIN string literal (concatenated string segments). Only
    /// meaningful when `stringLiteralIsPlain` is true.
    static func plainStringLiteralText(_ lit: StringLiteralExprSyntax) -> String {
        var s = ""
        for seg in lit.segments {
            if let str = seg.as(StringSegmentSyntax.self) { s += str.content.text }
        }
        return s
    }

    /// Heuristic: does a plain string-literal Text content carry MARKDOWN inline syntax
    /// SwiftUI would auto-render — a `[label](url)` link, `**bold**`/`__bold__`,
    /// `*italic*`/`_italic_`, or `` `code` ``? Deliberately CONSERVATIVE: a string with
    /// no such marker stays a plain text node (no behavior change). Matching SwiftUI's
    /// own LocalizedStringKey markdown so a literal lowers to the SAME styled render.
    static func literalLooksMarkdown(_ lit: StringLiteralExprSyntax) -> Bool {
        let s = plainStringLiteralText(lit)
        guard !s.isEmpty else { return false }
        // A `[text](url)` link: a `](` sequence following a `[`.
        if let lb = s.firstIndex(of: "["), s[lb...].contains("](") { return true }
        // BUG R2-#118: require CommonMark FLANKING for `**`/`__`/`` ` `` emphasis — an
        // OPENING run must be immediately FOLLOWED by a non-space and a CLOSING run
        // immediately PRECEDED by a non-space. Previously a bare `s.components(…).count
        // >= 3` match flagged plain text with spaced markers (`"a ** b ** c"`) or
        // backticks used literally, stripping markers / reformatting plain copy. The
        // flanking rule keeps real emphasis (`**bold**`, `` `code` ``) while rejecting
        // the false positives.
        for marker in ["**", "__", "`"] where hasFlankedMarkdownEmphasis(s, marker: marker) {
            return true
        }
        return false
    }

    /// True iff `s` contains a CommonMark-style emphasis run with `marker` — an OPENING
    /// occurrence immediately followed by a non-space, and a later CLOSING occurrence
    /// immediately preceded by a non-space (the basic flanking rule). Conservative: it
    /// rejects spaced markers (`a ** b **`) and a single dangling marker.
    static func hasFlankedMarkdownEmphasis(_ s: String, marker: String) -> Bool {
        let chars = Array(s)
        let m = Array(marker)
        var i = 0
        var openIdx: Int? = nil
        while i + m.count <= chars.count {
            if Array(chars[i..<(i + m.count)]) == m {
                let afterIdx = i + m.count
                let before = i > 0 ? chars[i - 1] : " "
                let after = afterIdx < chars.count ? chars[afterIdx] : " "
                if let oi = openIdx {
                    // This run can CLOSE if the char just before it is a non-space (and it
                    // isn't immediately adjacent to the opener — i.e. there's content between).
                    if !before.isWhitespace && i > oi + m.count {
                        return true
                    }
                    // Otherwise it might re-open: treat it as a new opener if it can flank.
                    if !after.isWhitespace { openIdx = i }
                } else if !after.isWhitespace {
                    openIdx = i
                }
                i = afterIdx
                continue
            }
            i += 1
        }
        return false
    }

    private func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  " + $0 }.joined(separator: "\n")
    }

    /// A DETERMINISTIC, process-stable hash of a source slice, used to derive a
    /// control's event id (Button action / `.onTapGesture`). Swift's
    /// `String.hashValue` is SEEDED PER PROCESS (random per launch), so using it
    /// here made the emitted guest source — and therefore the WASM module — differ
    /// on every CLI run for the SAME input (non-reproducible builds, broken artifact
    /// diffing/caching, and a tree whose ids the dispatch rules key off of churning
    /// build-to-build). FNV-1a over the UTF-8 bytes is stable across processes +
    /// platforms.
    ///
    /// IMPORTANT: Returns the FULL 64-bit hash as a hex string (not truncated to
    /// 5 decimal digits). The old truncation to `% 100000` made collisions trivially
    /// achievable (~100K bucket space), causing two views with the SAME label but
    /// DIFFERENT actions to emit byte-identical `guestBody` strings → identical
    /// `viewBodyContentHash` → the native-fast-path gate incorrectly treated a real
    /// patch as "unchanged" (FALSE-NATIVE). The full 64-bit space makes collision
    /// probability astronomically small (~1.8×10⁻¹⁹ for any pair).
    static func stableEventHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325          // FNV offset basis
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3                // FNV prime
        }
        return String(hash, radix: 16)
    }

    /// Full-width (16-hex-digit) content hash for opaque-leaf ids — wide enough
    /// that distinct leaves don't collide onto one slot. Stable across processes
    /// and platforms (FNV-1a over UTF-8), like `stableEventHash`.
    static func stableHash64(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Body-local name collection + reference scanning (mixed-view slotability)

/// Collects names bound LOCALLY within a body: `let`/`var` declarations, closure
/// parameters (incl. ForEach/Button trailing-closure element names), and
/// function-parameter shorthand. A leaf referencing any of these can't be rendered
/// from a `self`-only slot closure, so it is not slotable.
final class LocalNameCollector: SyntaxVisitor {
    private(set) var names: Set<String> = []

    static func collect(in items: CodeBlockItemListSyntax) -> Set<String> {
        let c = LocalNameCollector(viewMode: .sourceAccurate)
        for item in items { c.walk(item) }
        return c.names
    }

    /// Collect every name BOUND WITHIN an arbitrary syntax node (a leaf expression):
    /// `ForEach`/closure params, `if let`/`guard let` bindings, leaf-local `let`/`var`.
    /// Used to exclude a leaf's own internal bindings from the slotability `blocked` set.
    static func collect(in node: Syntax) -> Set<String> {
        let c = LocalNameCollector(viewMode: .sourceAccurate)
        c.walk(node)
        return c.names
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.text); return .visitChildren
    }
    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text); return .visitChildren
    }
    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.firstName.text)
        if let second = node.secondName { names.insert(second.text) }
        return .visitChildren
    }
}

/// Detects which anonymous closure parameters (`$0`, `$1`, …) a closure uses IN ITS OWN
/// BODY — stopping at any nested `ClosureExpr` boundary (a nested closure's `$0` belongs
/// to it, not the outer one). Used to classify a `ForEach` row closure: a single-element
/// `$0`-shorthand row (uses `$0`, never `$1`+) lowers via the indexed-slot factory by
/// INVOKING the closure with the element; a `$1`+ form is a multi-element shape the
/// single-element slot can't express (→ decline).
final class AnonymousParamScanner: SyntaxVisitor {
    private(set) var usesDollarZero = false
    private(set) var usesHigherDollar = false
    /// Nesting depth INSIDE a child closure. We only count anonymous params at depth 0
    /// (this closure's own body); inside a nested closure the `$N` are that closure's.
    private var nestedClosureDepth = 0

    static func scan(_ closure: ClosureExprSyntax) -> AnonymousParamScanner {
        let s = AnonymousParamScanner(viewMode: .sourceAccurate)
        // Walk the STATEMENTS (the body), not the whole `ClosureExprSyntax` (whose root is
        // the closure itself — visiting it would immediately bump `nestedClosureDepth`).
        for item in closure.statements { s.walk(item) }
        return s
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        nestedClosureDepth += 1
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) {
        nestedClosureDepth -= 1
    }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard nestedClosureDepth == 0 else { return .visitChildren }
        let name = node.baseName.text
        guard name.hasPrefix("$"), name.count >= 2 else { return .visitChildren }
        let digits = name.dropFirst()
        guard digits.allSatisfy(\.isNumber) else { return .visitChildren }
        if digits == "0" { usesDollarZero = true } else { usesHigherDollar = true }
        return .visitChildren
    }
}

/// Finds `<base>.count` / `<base>.isEmpty` member accesses where `<base>` is a BARE
/// body-local identifier — used to host-project a body-local-collection guard condition
/// (`if owners.count > 1`). Each hit records the base identifier, the member name, and
/// the full `<base>.<member>` expression (for substitution). Only a single-component
/// bare base is collected (a deeper chain `a.b.count` isn't an alias we resolve here).
final class CollectionGuardMemberFinder: SyntaxVisitor {
    struct Hit { let base: String; let member: String; let fullExpr: ExprSyntax }
    private(set) var hits: [Hit] = []
    private let bodyLocals: Set<String>
    /// When true, collect EVERY bare-identifier `.count`/`.isEmpty` base regardless of the
    /// `bodyLocals` filter — used to DISCOVER candidate self-accessible property guards
    /// (`plantsForSelectedDate.isEmpty`) the caller then vets for projection.
    private let collectAll: Bool
    init(bodyLocals: Set<String>, collectAll: Bool = false) {
        self.bodyLocals = bodyLocals
        self.collectAll = collectAll
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let member = node.declName.baseName.text
        if member == "count" || member == "isEmpty",
           let baseRef = node.base?.as(DeclReferenceExprSyntax.self) {
            let base = baseRef.baseName.text
            if collectAll || bodyLocals.contains(base) {
                hits.append(Hit(base: base, member: member, fullExpr: ExprSyntax(node)))
            }
        }
        return .visitChildren
    }
}

/// Finds reads off a view's struct/enum INPUT params (`size.iconSize`) in an expression,
/// for the computed-member host-projection. A `<base>.<member>` single-hop access (base in
/// `bases`) is a candidate hit (`member` set); a BARE `base` reference NOT serving as the
/// base of a member access — a whole-value pass / a deeper chain root we can't single-hop —
/// is recorded with `member == nil` so the caller demotes (a residual base would leak). A
/// DEEP chain (`size.a.b`) records the OUTER access's base as nil too (the inner `size.a`
/// node is visited first with member "a", but the outer member access has base = a
/// MemberAccessExpr, not a DeclReferenceExpr, so it isn't a single-hop hit — and the inner
/// `size.a`'s value is consumed by `.b`, so admitting it would be wrong; we conservatively
/// flag the bare-base path by requiring the hit's full node to be the WHOLE expression a
/// caller substitutes — handled by recording member==nil for any non-single-hop base use).
final class InputMemberReadFinder: SyntaxVisitor {
    struct Hit { let base: String; let member: String?; let fullText: String }
    private(set) var hits: [Hit] = []
    private let bases: Set<String>
    init(bases: Set<String>) { self.bases = bases; super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        // A single-hop `base.member` where base is a bare INPUT identifier.
        if let baseRef = node.base?.as(DeclReferenceExprSyntax.self), bases.contains(baseRef.baseName.text) {
            hits.append(Hit(base: baseRef.baseName.text, member: node.declName.baseName.text,
                            fullText: node.trimmedDescription))
            return .skipChildren   // don't re-visit the base DeclRef as a bare use
        }
        return .visitChildren
    }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        // A bare INPUT identifier reached here = used NOT as a single-hop member-access base
        // (a whole-value pass, a comparison `size != .small`, a function arg). Can't project.
        if bases.contains(node.baseName.text) {
            hits.append(Hit(base: node.baseName.text, member: nil, fullText: node.trimmedDescription))
        }
        return .visitChildren
    }
}

/// Finds HOST-PROJECTABLE reads off a view's REACTIVE reference-type members in an
/// expression: a SCALAR/Bool single-hop read (`viewModel.isOn`, path in `scalarPaths`) and a
/// collection-guard read (`viewModel.items.isEmpty`/`.count`, the `vm.field` part in
/// `collectionPaths`). It ALSO detects a NON-projectable use of a reactive base (a bare
/// `viewModel` passed whole, a method call `viewModel.f()`, a deep/Optional chain, a subscript,
/// a single-hop read whose field ISN'T a known scalar) — if any such use exists, the caller
/// must NOT project (a residual `viewModel` would leak → demote-safe). Records each projectable
/// hit's full source (for substitution) + whether any reactive base is used unprojectably.
final class ReactiveMemberReadFinder: SyntaxVisitor {
    /// A projectable scalar read: the `vm.field` source, its scalar kind.
    struct ScalarHit { let path: String; let kind: BodyLowering.ViewInput.Kind; let node: ExprSyntax }
    /// A projectable collection guard: the FULL `vm.field.isEmpty`/`.count` source + the
    /// collection path `vm.field` + the member (`isEmpty`/`count`).
    struct CollectionHit { let fullExpr: ExprSyntax; let collectionPath: String; let member: String }
    private(set) var scalarHits: [ScalarHit] = []
    private(set) var collectionHits: [CollectionHit] = []
    /// A reactive base used in a way we can't project (forces the caller to demote).
    private(set) var hasUnprojectableUse = false

    private let bases: Set<String>
    private let scalarPaths: [String: BodyLowering.ViewInput.Kind]
    private let collectionPaths: Set<String>
    init(bases: Set<String>, scalarPaths: [String: BodyLowering.ViewInput.Kind],
         collectionPaths: Set<String>) {
        self.bases = bases; self.scalarPaths = scalarPaths; self.collectionPaths = collectionPaths
        super.init(viewMode: .sourceAccurate)
    }

    // The root identifier of `a.b.c` / `a.b()` / `a[i]` → `a` (nil if not a plain ident root).
    private func rootIdentifier(of expr: ExprSyntax) -> String? {
        if let d = expr.as(DeclReferenceExprSyntax.self) { return d.baseName.text }
        if let m = expr.as(MemberAccessExprSyntax.self), let b = m.base { return rootIdentifier(of: b) }
        if let c = expr.as(FunctionCallExprSyntax.self) { return rootIdentifier(of: c.calledExpression) }
        if let s = expr.as(SubscriptCallExprSyntax.self) { return rootIdentifier(of: s.calledExpression) }
        if let o = expr.as(OptionalChainingExprSyntax.self) { return rootIdentifier(of: o.expression) }
        if let f = expr.as(ForceUnwrapExprSyntax.self) { return rootIdentifier(of: f.expression) }
        return nil
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        // A bare reference to a reactive base whose parent is NOT a member access we classify
        // (passed whole as an argument / into a closure) is unprojectable.
        if bases.contains(node.baseName.text),
           !(node.parent?.is(MemberAccessExprSyntax.self) ?? false) {
            hasUnprojectableUse = true
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard let root = rootIdentifier(of: ExprSyntax(node)), bases.contains(root) else {
            return .visitChildren
        }
        // Only classify the OUTERMOST member access of the chain (so `a.b.c` is seen once at
        // `a.b.c`, not also at `a.b`). A parent that continues the chain / calls / subscripts
        // it means this node is an inner step — skip it (the outer node classifies the whole).
        if let parent = node.parent {
            if let pm = parent.as(MemberAccessExprSyntax.self), pm.base?.id == Syntax(node).id { return .visitChildren }
            if let pc = parent.as(FunctionCallExprSyntax.self), pc.calledExpression.id == ExprSyntax(node).id { return .visitChildren }
            if let ps = parent.as(SubscriptCallExprSyntax.self), ps.calledExpression.id == ExprSyntax(node).id { return .visitChildren }
            if parent.is(OptionalChainingExprSyntax.self) || parent.is(ForceUnwrapExprSyntax.self) { return .visitChildren }
        }
        // (1) Single-hop scalar `vm.field` (base is the bare reactive root).
        if let base = node.base, base.is(DeclReferenceExprSyntax.self), base.trimmedDescription == root {
            let path = node.trimmedDescription
            if let kind = scalarPaths[path] {
                scalarHits.append(ScalarHit(path: path, kind: kind, node: ExprSyntax(node)))
            } else {
                hasUnprojectableUse = true   // an unknown / non-scalar single-hop field
            }
            return .visitChildren
        }
        // (2) Two-hop collection guard `vm.field.isEmpty`/`.count` (inner `vm.field` is a
        // known collection path; inner base is the bare reactive root).
        let member = node.declName.baseName.text
        if (member == "isEmpty" || member == "count"),
           let inner = node.base?.as(MemberAccessExprSyntax.self),
           let innerBase = inner.base, innerBase.is(DeclReferenceExprSyntax.self),
           innerBase.trimmedDescription == root {
            let collPath = inner.trimmedDescription
            if collectionPaths.contains(collPath) {
                collectionHits.append(CollectionHit(fullExpr: ExprSyntax(node),
                                                    collectionPath: collPath, member: member))
                return .visitChildren
            }
        }
        // Any other shape rooted at a reactive base (a deep chain, a non-collection two-hop,
        // an object field) is unprojectable.
        hasUnprojectableUse = true
        return .visitChildren
    }
}

/// Collects every body-local SINGLE-binding `let`/`var` declaration's
/// initializer SOURCE (name → RHS trimmed source) — used to resolve a per-row
/// indexed slot's `ForEach(<alias>)` collection back to its ACCESSIBLE source
/// (`let owners = schedule.availableOwners`). Recurses into nested blocks (the
/// ForEach is usually inside an `if owners.count > 1 { ScrollView { … } }`).
/// Multi-binding / destructured / accessor-block decls are skipped.
final class LetInitSourceCollector: SyntaxVisitor {
    private(set) var inits: [(String, String)] = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.bindings.count == 1, let b = node.bindings.first,
              let name = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              b.accessorBlock == nil, let initializer = b.initializer else {
            return .visitChildren
        }
        inits.append((name, initializer.value.trimmedDescription))
        return .visitChildren
    }
}

/// Verifies that, within a `ForEach` row over a flat-struct array, the loop element
/// is used ONLY as `element.<flatField>` (TASK 1) — the only shape the generated
/// guest struct can compile. A bare `element` (e.g. `Text("\(item)")`), a method call
/// (`item.f()`), or an access to a member NOT in the flat field set
/// (`item.computed`/`item.nested.x`) makes the whole `ForEach` demote to native
/// (faithful over broken guest code).
///
/// Mechanism: walk every `DeclReferenceExpr` named `element`. Each MUST be the BASE of
/// a `MemberAccessExpr` whose member name is a flat field (`item.score`). The inner
/// `element.field` of a chain like `element.field.uppercased()` would pass this base
/// check, so we ALSO reject any `element.field` that is itself the base of a further
/// member access (the chained `.uppercased()` would not be guest-safe).
final class ElementUsageScanner: SyntaxVisitor {
    private let element: String
    private let fields: [BodyLowering.StructField]
    private(set) var ok = true

    private init(element: String, fields: [BodyLowering.StructField]) {
        self.element = element; self.fields = fields
        super.init(viewMode: .sourceAccurate)
    }

    /// A row uses the loop element guest-safely iff every `element.f1…fn` chain resolves
    /// (through the RECURSIVE field shapes) to a scalar leaf, or to a scalar-array/
    /// dictionary used only as a whole collection (`ForEach`/`.count`). A bare `element`,
    /// a method call, an unknown field, or a nested struct/value used whole → demote.
    static func usesOnlyReconstructableFields(_ stmts: CodeBlockItemListSyntax,
                                              element: String,
                                              fields: [BodyLowering.StructField]) -> Bool {
        let s = ElementUsageScanner(element: element, fields: fields)
        for item in stmts { s.walk(item) }
        return s.ok
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.baseName.text == element else { return .visitChildren }
        // Skip a `.member` selector that merely SHARES the name.
        if let parent = node.parent?.as(MemberAccessExprSyntax.self), parent.declName.id == node.id {
            return .visitChildren
        }
        let (chain, outer) = RichStructChain.climb(base: node)
        guard !chain.isEmpty, let outer else {
            ok = false; return .skipChildren   // bare `element` use — not provable
        }
        switch BodyLowering.resolveFieldChain(chain, fields: fields) {
        case .scalarLeaf:
            return .visitChildren
        case .collection:
            if RichStructChain.usedAsWholeCollection(outer) { return .visitChildren }
            ok = false; return .skipChildren
        case .optionalScalarLeaf:
            if RichStructChain.usedAsOptionalScalar(outer) { return .visitChildren }
            ok = false; return .skipChildren
        case .structWhole, .unsafe:
            ok = false; return .skipChildren
        }
    }
}

/// Rewrites a `GeometryReader` closure body, replacing the proxy's geometry member
/// accesses with reserved guest-input identifiers (`__geo_width`/`__geo_height`/
/// `__geo_minX`/`__geo_minY`) the guest binds from the input JSON. Any OTHER use of
/// the proxy (`proxy.size` whole, `proxy.safeAreaInsets`, `proxy[anchor]`,
/// `.maxX`/`.midX`/… which need arithmetic) sets `unmappable` → the caller demotes
/// the whole GeometryReader to a native slot (faithful over a wrong/unbound guest).
final class GeometryProxyRewriter: SyntaxRewriter {
    private let proxyName: String
    private(set) var unmappable = false
    init(proxyName: String) { self.proxyName = proxyName; super.init() }

    func rewrite(_ stmts: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
        // Wrap → rewrite → unwrap so we operate on the statement list as a unit.
        let block = CodeBlockSyntax(statements: stmts)
        let out = rewrite(Syntax(block)).as(CodeBlockSyntax.self)
        return out?.statements ?? stmts
    }

    /// The reserved identifier a proxy member chain maps to, or nil if it's not a
    /// proxy geometry access we model. `base` is the chain UNDER the final `.member`.
    private func reservedName(forMember member: String, base: ExprSyntax) -> String? {
        // `proxy.size.<member>` — base is `proxy.size`.
        if let bm = base.as(MemberAccessExprSyntax.self),
           bm.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == proxyName,
           bm.declName.baseName.text == "size" {
            switch member {
            case "width": return "__geo_width"
            case "height": return "__geo_height"
            default: return nil   // `.size.<other>` — unmodeled
            }
        }
        // `proxy.frame(in: …).<member>` — base is a call of `proxy.frame`.
        if let call = base.as(FunctionCallExprSyntax.self),
           let cm = call.calledExpression.as(MemberAccessExprSyntax.self),
           cm.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == proxyName,
           cm.declName.baseName.text == "frame" {
            switch member {
            case "minX": return "__geo_minX"
            case "minY": return "__geo_minY"
            case "width": return "__geo_width"
            case "height": return "__geo_height"
            default: return nil   // `.maxX`/`.midX`/`.size`/… need arithmetic — unmodeled
            }
        }
        return nil
    }

    /// Whether an expression's chain is rooted at the proxy (so an UNMAPPED member on
    /// it, or the bare proxy, is an unmappable use we must flag).
    private func rootsAtProxy(_ expr: ExprSyntax) -> Bool {
        if let d = expr.as(DeclReferenceExprSyntax.self) { return d.baseName.text == proxyName }
        if let m = expr.as(MemberAccessExprSyntax.self), let b = m.base { return rootsAtProxy(b) }
        if let c = expr.as(FunctionCallExprSyntax.self) { return rootsAtProxy(c.calledExpression) }
        if let s = expr.as(SubscriptCallExprSyntax.self) { return rootsAtProxy(s.calledExpression) }
        return false
    }

    override func visit(_ node: MemberAccessExprSyntax) -> ExprSyntax {
        if let base = node.base {
            // A mapped proxy geometry chain → the reserved identifier. PRESERVE the
            // original chain's leading/trailing trivia: dropping it produced
            // `__geo_height/ 2` (space only after `/`), which Swift parses as a
            // POSTFIX `/` — a compile error. Carrying the trivia keeps `height / 2`'s
            // spacing as `__geo_height / 2`.
            if let reserved = reservedName(forMember: node.declName.baseName.text, base: base) {
                let token = TokenSyntax.identifier(reserved,
                                                   leadingTrivia: node.leadingTrivia,
                                                   trailingTrivia: node.trailingTrivia)
                return ExprSyntax(DeclReferenceExprSyntax(baseName: token))
            }
            // An UNMAPPED member whose base roots at the proxy (`proxy.size` whole,
            // `proxy.safeAreaInsets`, `proxy.frame(in:).maxX`, …) → unmappable.
            if rootsAtProxy(base) { unmappable = true }
        }
        return super.visit(node)
    }

    override func visit(_ node: SubscriptCallExprSyntax) -> ExprSyntax {
        // `proxy[anchor]` (the GeometryProxy subscript) → unmappable.
        if rootsAtProxy(node.calledExpression) { unmappable = true }
        return super.visit(node)
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> ExprSyntax {
        // A bare `proxy` that survived (not consumed by a mapped chain) → unmappable.
        if node.baseName.text == proxyName { unmappable = true }
        return ExprSyntax(node)
    }
}

/// Scans an expression for references to any of a set of names (a
/// `DeclReferenceExpr` whose base identifier is in the set — this also catches the
/// base of a member access like `item.foo`).
final class ReferencedNameScanner: SyntaxVisitor {
    private let target: Set<String>
    private(set) var found = false
    private init(_ target: Set<String>) { self.target = target; super.init(viewMode: .sourceAccurate) }

    static func referencesAny(_ expr: ExprSyntax, of names: Set<String>) -> Bool {
        let s = ReferencedNameScanner(names)
        s.walk(expr)
        return s.found
    }

    /// Whether ANY `DeclReferenceExpr` in a parsed source tree names one of `names`.
    /// Used to decide a design-system token's slotability (its thunk closure can't
    /// reference a body-local / inaccessible member). The token expr is parsed wrapped
    /// in a `let __patch_tok = (...)`; the binding name is a declaration, not a
    /// reference, so it never matches.
    static func referencesAnyInSource(_ tree: SourceFileSyntax, of names: Set<String>) -> Bool {
        let s = ReferencedNameScanner(names)
        s.walk(tree)
        return s.found
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        // A member NAME in a member access (`Color.recording`, `vm.title`) is a field
        // SELECTOR — never a free-variable reference — so it must NOT match a body-local
        // name. BUG (pre-fix): `Color.recording` falsely matched a body-local `recording`
        // (e.g. from `.onChange(of:) { _, recording in … }`), demoting the view
        // (a real app's `RecordButton`). Skip the `.declName` selector position —
        // a body-local variable can never be accessed as `Base.var`, so skipping a selector
        // off a TYPE/value base is sound, and the base itself is still visited normally.
        //
        // EXCEPTION (the private wall): a `self.<member>` / `Self.<member>` selector IS a real
        // reference to the instance's member, which may be a BLOCKED private member the
        // cross-file thunk can't read (`self.accent`, `self.privateRadius`). Those must STAY
        // matched so a token over a private member still demotes — UIKitGrammarLevers'
        // private-wall tests pin this. So: skip the selector ONLY when its base is NOT self/Self
        // (a foreign type/value base, or a leading-dot `.red` contextual lookup → base nil).
        if let parent = node.parent?.as(MemberAccessExprSyntax.self),
           parent.declName.id == node.id,
           !Self.baseIsSelf(parent.base) {
            return .skipChildren
        }
        if target.contains(node.baseName.text) { found = true }
        return found ? .skipChildren : .visitChildren
    }

    /// True when a member-access base is the literal `self` or `Self` — so the selector is a
    /// real instance/type member reference (subject to the private wall), not a foreign type's
    /// member. A nil base (leading-dot `.red` contextual lookup) is NOT self → returns false.
    private static func baseIsSelf(_ base: ExprSyntax?) -> Bool {
        guard let ref = base?.as(DeclReferenceExprSyntax.self) else { return false }
        let t = ref.baseName.text
        return t == "self" || t == "Self"
    }
}

// MARK: - StringLiteralLifter

/// Lifts PLAIN string literals from RECOGNIZED SwiftUI call positions into
/// parameterized-slot placeholder form. Used by `opaqueExprLifted` /
/// `opaqueViewBuilderLifted` to make string-literal edits inside opaque slot
/// bodies OTA-patchable and fingerprint-stable without touching `isSlotable`
/// or the IR wire format.
///
/// POSITION TYPES (conservative; unknown positions are left baked):
///   - LocalizedStringKey: Text(first), Button(first), Toggle(first),
///     TextField/SecureField(first placeholder), Label(first title),
///     Section/Picker/Stepper/GroupBox/DisclosureGroup/NavigationLink/Menu/
///     LabeledContent/ProgressView/Gauge/ShareLink/Link(first unlabeled title).
///   - String: Image(systemName:), Image(first unlabeled), Image(decorative:),
///     Text(verbatim:), accessibilityLabel/Hint/Value(first unlabeled).
///
/// SAFETY RULE: PLAIN single-segment strings are always lifted. INTERPOLATED strings
/// are lifted ONLY when every interpolated expression is slotable (no body-local/private
/// read): static string segments ride WASM (editable); interpolated expressions stay
/// native in the template, resolved live over self. If ANY interpolated expression is
/// non-slotable, the whole string is left baked (conservative). For String-position
/// calls (Image etc.), the same split applies but without LocalizedStringKey wrapping.
///
/// The SyntaxRewriter subclass form avoids the "cannot use visitPost in extension" compile
/// failure: this is a standalone class, not an extension override on a SwiftSyntax type.
final class StringLiteralLifter: SyntaxRewriter {

    /// Lifted literal VALUES in source order (parallel to `ranges`).
    private(set) var values: [String] = []
    /// Byte ranges (into the ORIGINAL body source) of each lifted `StringLiteralExprSyntax`
    /// (quotes included), in source order. Passed as `stringArgRanges` to `recordOpaque`
    /// so the fingerprint walker normalizes only those bytes.
    private(set) var ranges: [Range<Int>] = []

    /// Names blocked from use inside slot closures (body-locals + inaccessible names).
    /// Used conservatively: if we're uncertain about a call position, we don't lift.
    private let blocked: Set<String>

    /// LIFT-ALL mode (cli 1.6.33): when an UNRECOGNIZED (custom view / helper) call is
    /// reached, lift EVERY plain non-interpolated string-literal arg — ANY label or no
    /// label — as a bare `String` placeholder, matching `opaqueCall`'s top-level
    /// aggressiveness. This is what lets `opaqueCall` route its WHOLE recursion through
    /// this lifter and pick up NESTED custom-view string args (a `SettingsRow(label:…)`
    /// inside a `SettingsSection(title:…) { … }` trailing closure), not just the
    /// top-level section title.
    ///
    /// SAFETY: `opaqueCall` produces a PARAMETERIZED NATIVE RECONSTRUCTION
    /// (`{ a in Foo(text: a[0]) }`) with NO guest-tree identity correlation, so lifting
    /// ANY plain-string arg in any position is render-safe (identical safety property to
    /// the top-level lift `opaqueCall` already does). RECOGNIZED SwiftUI calls
    /// (Text/Image/Button/…) keep their POSITION-TYPED specs even in this mode — their
    /// localization correctness (LocalizedStringKey vs String) must be preserved; only
    /// the `default` (custom/unknown) case widens from the display-label subset to
    /// all-plain-string-args.
    private let liftAllPlainStrings: Bool

    init(blocked: Set<String>, liftAllPlainStrings: Bool = false) {
        self.blocked = blocked
        self.liftAllPlainStrings = liftAllPlainStrings
        super.init(viewMode: .sourceAccurate)
    }

    /// Position type for a recognized string-literal argument.
    private enum ArgKind {
        /// Argument takes a `LocalizedStringKey`: the placeholder is wrapped as
        /// `LocalizedStringKey(\u{1}k\u{1})` so the thunk renders `LocalizedStringKey(a[k])`.
        case localizedStringKey
        /// Argument takes a plain `String`: the placeholder is bare `\u{1}k\u{1}`
        /// → the thunk renders `a[k]` (e.g. `Image(systemName: a[0])`).
        case string
    }

    // MARK: - FIX 2: Nested-call range correctness
    //
    // `super.visit(node)` is a bottom-up rewriter: inner recognized calls are rewritten
    // FIRST (inner Image inside an outer Button), returning a NEW syntax tree rooted at
    // offset=0.  Reading `lit.positionAfterSkippingLeadingTrivia.utf8Offset` from THAT
    // rewritten tree records garbage offsets for the OUTER literal (used for fingerprint
    // normalization via `stringArgRanges`).  The VALUES (what rides WASM) are still
    // correct — only the RANGES are wrong — but a wrong range means a structural change
    // can get normalized out → real native change ships with a stale fingerprint
    // (silent-drop on device).
    //
    // FIX: record every liftable argument's byte range from the ORIGINAL, UN-REWRITTEN
    // node (positions are valid there).  We do a first read-only pass over `node` to
    // collect (originalArg, absoluteRange, spec) triples, THEN call `super.visit(node)`
    // for the recursive rewrite, THEN build the new argument list using the rewritten
    // args but the ORIGINAL ranges.

    /// One liftable argument collected from the ORIGINAL (un-rewritten) node.
    private struct PendingLift {
        let argIndex: Int          // position in `call.arguments`
        let spec: LiftSpec
        // Absolute UTF-8 byte ranges from the ORIGINAL source tree.
        // For plain literals: one range (the whole literal span, quotes included).
        // For interpolated literals: one range PER STATIC STRING SEGMENT (may be empty
        // when the segment is empty, included for index-consistency).
        let staticRanges: [Range<Int>]
        // Parallel to staticRanges: the VALUE of each static string segment (without quotes).
        let staticValues: [String]
        // For interpolated strings: the TEMPLATE (with \u{1}k\u{1} placeholders for statics
        // AND the original \(expr) interpolations for dynamics).  Nil for plain literals.
        let interpolatedTemplate: String?
        // cli 1.6.34 — TERNARY-ARM lift: for a `cond ? "A" : "B"` argument whose BOTH arms
        // are plain string literals, the TEMPLATE is the ternary with each arm replaced by a
        // local placeholder `\u{1}L<k>\u{1}` (the condition source preserved VERBATIM — it
        // reads live native state and is never lifted). staticRanges/staticValues carry the
        // two arm ranges/values in source order (then, else). The per-arm placeholder is
        // POSITION-TYPED at insertion time (LocalizedStringKey wrap vs bare) from `spec.kind`.
        // Nil for non-ternary arguments.
        let ternaryArmTemplate: String?
    }

    /// cli 1.6.34 — the two PLAIN-string arms + condition of a ternary argument, with the
    /// arm byte ranges read from the ORIGINAL (un-rewritten) node (so FIX-2 range correctness
    /// holds). Returns nil unless the argument is a ternary whose BOTH arms are single-segment
    /// (non-interpolated) string literals — the conservative "lift neither if either is
    /// non-liftable" rule. Handles BOTH the folded (`TernaryExprSyntax`) and the unfolded
    /// (`SequenceExprSyntax` with an `UnresolvedTernaryExprSyntax` middle) forms DIRECTLY,
    /// since a body subtree reaches the lifter UN-folded (SwiftParser does not fold operators).
    private struct TernaryArms {
        let condition: Syntax
        let thenValue: String
        let elseValue: String
        let thenRange: Range<Int>
        let elseRange: Range<Int>
    }

    private static func ternaryStringArms(_ expr: ExprSyntax) -> TernaryArms? {
        // Reduce a single-element TupleExpr `(cond ? "a" : "b")` to its inner expression.
        if let tup = expr.as(TupleExprSyntax.self), tup.elements.count == 1,
           let only = tup.elements.first, only.label == nil {
            return ternaryStringArms(only.expression)
        }
        // ── FOLDED form: a proper TernaryExprSyntax ──────────────────────────────────────
        if let tern = expr.as(TernaryExprSyntax.self) {
            guard let then = plainStringArm(tern.thenExpression),
                  let els = plainStringArm(tern.elseExpression) else { return nil }
            return TernaryArms(condition: Syntax(tern.condition),
                               thenValue: then.value, elseValue: els.value,
                               thenRange: then.range, elseRange: els.range)
        }
        // ── UNFOLDED form: SequenceExpr [cond..., UnresolvedTernary(? then :), else] ──────
        guard let seq = expr.as(SequenceExprSyntax.self) else { return nil }
        let elements = Array(seq.elements)
        // Find the SINGLE UnresolvedTernaryExprSyntax (the `? then :` middle). Exactly one,
        // and it must NOT be the last element (the else arm follows it). More than one
        // (nested/chained ternary) → bail (conservative).
        let unresolvedIdxs = elements.indices.filter { elements[$0].is(UnresolvedTernaryExprSyntax.self) }
        guard unresolvedIdxs.count == 1 else { return nil }
        let tIdx = unresolvedIdxs[0]
        guard tIdx > 0, tIdx + 1 == elements.count - 1 else {
            // The else arm must be the LAST element, immediately after the `? then :`.
            return nil
        }
        guard let unresolved = elements[tIdx].as(UnresolvedTernaryExprSyntax.self) else { return nil }
        let thenExpr = ExprSyntax(unresolved.thenExpression)
        let elseExpr = elements[tIdx + 1]
        guard let then = plainStringArm(thenExpr),
              let els = plainStringArm(elseExpr) else { return nil }
        // Condition = the sub-sequence of elements BEFORE the `? then :`. Reconstruct it as a
        // SequenceExpr so its trimmedDescription is the verbatim condition source (`a < 2`).
        let condElements = Array(elements[0..<tIdx])
        let condition: Syntax
        if condElements.count == 1 {
            condition = Syntax(condElements[0])
        } else {
            condition = Syntax(SequenceExprSyntax(elements: ExprListSyntax(condElements)))
        }
        return TernaryArms(condition: condition,
                           thenValue: then.value, elseValue: els.value,
                           thenRange: then.range, elseRange: els.range)
    }

    /// A single PLAIN (non-interpolated) string-literal arm → its unquoted value + the
    /// ORIGINAL byte range of the full literal (quotes included). Nil for an interpolated
    /// or non-string-literal arm.
    private static func plainStringArm(_ expr: ExprSyntax) -> (value: String, range: Range<Int>)? {
        guard let lit = expr.as(StringLiteralExprSyntax.self),
              lit.segments.count == 1,
              let seg = lit.segments.first?.as(StringSegmentSyntax.self) else { return nil }
        let lo = lit.positionAfterSkippingLeadingTrivia.utf8Offset
        let hi = lit.endPositionBeforeTrailingTrivia.utf8Offset
        return (seg.content.text, lo..<hi)
    }

    /// Scan the ORIGINAL (un-rewritten) call for liftable arguments.
    /// Returns nil if the call name is unrecognized.
    /// Returns an empty array if the call is recognized but nothing is liftable.
    private func pendingLifts(from node: FunctionCallExprSyntax) -> [PendingLift]? {
        // Resolve call name from the ORIGINAL node.
        let callName: String
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            callName = ref.baseName.text
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                  member.base == nil {
            callName = member.declName.baseName.text
        } else {
            return nil
        }
        // LIFT-ALL mode (cli 1.6.33): for an UNRECOGNIZED (custom view / helper) call,
        // lift EVERY plain-string arg (ANY label / no label) as a bare `String` — matching
        // `opaqueCall`'s top-level aggressiveness, now reaching NESTED custom-view calls in
        // trailing/@ViewBuilder closures. Recognized standard-library calls keep their
        // POSITION-TYPED specs (localization correctness). This is render-safe because
        // `opaqueCall` produces a fully-native parameterized reconstruction (no guest-tree
        // identity correlation — see the type doc).
        let liftAllThisCall = liftAllPlainStrings && !Self.isRecognizedCallName(callName)
        let specs = Self.liftSpecs(for: callName)
        // In lift-all mode a custom call always lifts (specs is the all-label spec built
        // per-arg below), so an empty `customCallDisplayLiftSpecs` would never gate it.
        guard liftAllThisCall || !specs.isEmpty else { return nil }

        var result: [PendingLift] = []
        for (idx, arg) in node.arguments.enumerated() {
            let label = arg.label?.text
            let spec: LiftSpec
            if liftAllThisCall {
                // Lift EVERY plain-string arg regardless of label, as a bare String.
                spec = LiftSpec(label: label, kind: .string)
            } else {
                guard let matched = specs.first(where: { $0.label == label })
                    ?? (label == nil ? specs.first(where: { $0.label == nil }) : nil) else {
                    continue
                }
                spec = matched
            }
            // cli 1.6.34 — TERNARY-ARM lift: `cond ? "A" : "B"`. When the argument is a
            // ternary whose BOTH arms are PLAIN (non-interpolated) string literals, lift both
            // arm literals (the condition source is preserved VERBATIM — it reads live native
            // state and must never ride WASM). If EITHER arm is non-liftable (an interpolated
            // literal, or any non-string-literal expression), lift NEITHER — the whole ternary
            // stays baked (conservative; the `else` below leaves a non-literal argument
            // untouched). This is render-safe for the same reason the plain/interpolated lifts
            // are: the lifted values ride WASM in `stringArgs` and the native slot factory
            // substitutes them; the condition evaluates natively over `self`.
            //
            // NOTE: SwiftParser produces an UNFOLDED `SequenceExprSyntax` for a raw ternary
            // (`[cond..., UnresolvedTernary(? then :), else]`), not a `TernaryExprSyntax` — the
            // latter only appears after operator folding. `Self.ternaryStringArms` handles BOTH
            // forms DIRECTLY (it does not re-fold), reading the arm byte ranges straight from
            // the ORIGINAL nodes — so FIX-2 range correctness holds (the recorded ranges point
            // at the original literal bytes the fingerprint walker normalizes).
            if let arms = Self.ternaryStringArms(arg.expression) {
                // Both arm literals are plain (non-interpolated) String literals.
                let condSource = arms.condition.trimmedDescription
                let template = "\(condSource) ? \u{1}L0\u{1} : \u{1}L1\u{1}"
                result.append(PendingLift(
                    argIndex: idx, spec: spec,
                    staticRanges: [arms.thenRange, arms.elseRange],
                    staticValues: [arms.thenValue, arms.elseValue],
                    interpolatedTemplate: nil,
                    ternaryArmTemplate: template))
                continue
            }
            // If the arg is a ternary that is NOT liftable (an interpolated arm, a non-literal
            // arm), `ternaryStringArms` returns nil AND the arg is not a plain StringLiteral →
            // the guard below `continue`s, leaving the whole ternary baked (conservative).
            guard let lit = arg.expression.as(StringLiteralExprSyntax.self) else { continue }

            // Determine if the literal has any true interpolation (`\(expr)` segments).
            let hasExprInterpolation = lit.segments.contains { $0.is(ExpressionSegmentSyntax.self) }

            if !hasExprInterpolation {
                // PLAIN literal (possibly with escape sequences like `\n`, `\t`, or `\"` that
                // SwiftSyntax may parse as multiple StringSegmentSyntax rather than one):
                // treat the WHOLE literal as a single atomic value. Join all StringSegmentSyntax
                // tokens to get the display text; use the whole quoted literal's byte range.
                // This lifts `"Find MY best\ntime to post."` correctly — a `\n` in a non-raw
                // string literal is just an escape, not a runtime interpolation, so the string
                // is fully static and OTA-editable (no wrong-render risk).
                let lo = lit.positionAfterSkippingLeadingTrivia.utf8Offset
                let hi = lit.endPositionBeforeTrailingTrivia.utf8Offset
                // Concatenate segment text to reconstruct the escaped content (e.g. "Hello\nWorld"
                // → content text "Hello\nWorld" — the source-form escape characters, not a real
                // newline). The SDK and WASM receive this string as a slotArg; the thunk substitutes
                // it verbatim via `a[k]` so it appears correctly in the native call.
                let value = lit.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
                guard !value.isEmpty else { continue }
                result.append(PendingLift(
                    argIndex: idx, spec: spec,
                    staticRanges: [lo..<hi],
                    staticValues: [value],
                    interpolatedTemplate: nil,
                    ternaryArmTemplate: nil))
            } else {
                // TRUE INTERPOLATION (`\(expr)` present): do NOT lift. The original
                // `makeInterpolatedReplacement` path embeds the template as a
                // DeclReferenceExprSyntax identifier whose text is `"<template>"` (double
                // quotes included). After `renderParameterizedTemplate` replaces
                // `\u{1}k\u{1}` → `a[k]`, the slot closure emits Swift source like
                // `AnyView(Text(LocalizedStringKey("a[0]\(expr)a[1]")))` — where `a[0]` and
                // `a[1]` are the LITERAL CHARACTERS "a[0]"/"a[1]", not array subscripts.
                // The rendered SwiftUI view displays "a[0]" + expr_value + "a[1]" instead
                // of the intended static segments — a WRONG RENDER (visible garbage on screen).
                // P0-B FIX: the safe path is to leave true interpolations baked. A static-
                // segment edit triggers a MISMATCH (the safe failure), not a wrong render.
                // Only PLAIN (non-interpolated) string literals — including escape-sequence
                // strings like `"Hello\nWorld"` (all StringSegmentSyntax, no ExpressionSegmentSyntax)
                // — are lifted.
                continue
            }
        }
        return result
    }

    /// Rewrite a function-call node by lifting recognized string-literal args.
    /// Each lifted literal is replaced by a `\u{1}k\u{1}` bare identifier (String position)
    /// or a `LocalizedStringKey(\u{1}k\u{1})` call expression (LocalizedStringKey position).
    ///
    /// FIX 2: byte ranges are collected from the ORIGINAL node BEFORE `super.visit`.
    /// This prevents nested-call rewriting from corrupting the absolute byte offsets
    /// recorded in `ranges` (used by the fingerprint walker to normalize only lifted literals).
    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        // STEP 1: Collect liftable arguments from the ORIGINAL (un-rewritten) node.
        // Their byte ranges are valid here; after super.visit they would be offset=0-based.
        guard let pending = pendingLifts(from: node), !pending.isEmpty else {
            // No liftable arguments in this call (or unrecognized call name) → recurse only.
            return super.visit(node)
        }

        // STEP 2: Recurse into children (bottom-up: inner calls are rewritten first).
        // We do this AFTER collecting the original ranges above.
        let visited = super.visit(node)
        guard let call = visited.as(FunctionCallExprSyntax.self) else { return visited }

        // STEP 3: Build the new argument list using the REWRITTEN call's args (for correct
        // sub-tree rewrites) but using the ORIGINAL ranges (from `pending`) for fingerprint
        // normalization.
        var newArgs: [LabeledExprSyntax] = Array(call.arguments)
        var didLift = false

        for lift in pending {
            let argIdx = lift.argIndex
            guard argIdx < newArgs.count else { continue }
            let arg = newArgs[argIdx]

            if let ternaryTemplate = lift.ternaryArmTemplate {
                // ── Ternary arms (cli 1.6.34) ─────────────────────────────────────────
                // `cond ? "A" : "B"` → both arm literals ride WASM; the condition stays
                // native (verbatim in the template). Assign global indices for each arm,
                // rebase the local placeholders, and POSITION-TYPE-wrap each arm.
                let baseIdx = values.count
                for (val, range) in zip(lift.staticValues, lift.staticRanges) {
                    values.append(val)
                    ranges.append(range)
                }
                // Replace each local arm placeholder \u{1}Lk\u{1} with the position-typed
                // expression for global index (baseIdx+k): bare `\u{1}g\u{1}` for a String
                // position, `LocalizedStringKey(\u{1}g\u{1})` for an LSK position. The
                // ThunkGenerator's text pass then rewrites each `\u{1}g\u{1}` → `a[g]`.
                var template = ternaryTemplate
                for i in 0..<lift.staticValues.count {
                    let globalIdx = baseIdx + i
                    let armExpr = Self.ternaryArmPlaceholder(globalIndex: globalIdx, kind: lift.spec.kind)
                    template = template.replacingOccurrences(of: "\u{1}L\(i)\u{1}", with: armExpr)
                }
                // Embed the whole ternary template as a bare token expression — same scheme
                // as `makeInterpolatedReplacement` (the substitution pass handles the
                // \u{1}g\u{1} placeholders; the rest is verbatim Swift). NO outer
                // LocalizedStringKey wrap here: each arm is already individually wrapped, so
                // the ternary itself is `cond ? LocalizedStringKey(a[0]) : LocalizedStringKey(a[1])`
                // (an expression of type LocalizedStringKey) at the call site.
                let replacementExpr = ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(template)))
                var newArg = arg
                newArg.expression = replacementExpr
                newArgs[argIdx] = newArg
                didLift = true
            } else if lift.interpolatedTemplate == nil {
                // ── Plain (non-interpolated) literal ──────────────────────────────────
                // One static value → one global placeholder index.
                let globalIdx = values.count
                values.append(lift.staticValues[0])
                ranges.append(lift.staticRanges[0])
                let placeholder = "\u{1}\(globalIdx)\u{1}"
                let replacementExpr = Self.makeReplacement(placeholder: placeholder, kind: lift.spec.kind)
                var newArg = arg
                newArg.expression = replacementExpr
                newArgs[argIdx] = newArg
                didLift = true
            } else {
                // ── Interpolated literal (FIX 3) ──────────────────────────────────────
                // The template uses local placeholders \u{1}L<k>\u{1} for static segments.
                // We assign global indices for each static segment and rebase the template.
                let baseIdx = values.count
                for (i, (val, range)) in zip(lift.staticValues, lift.staticRanges).enumerated() {
                    values.append(val)
                    ranges.append(range)
                    _ = i  // used in template below
                }
                // Replace local \u{1}Lk\u{1} placeholders with global \u{1}(baseIdx+k)\u{1}.
                var template = lift.interpolatedTemplate!
                for i in 0..<lift.staticValues.count {
                    template = template.replacingOccurrences(of: "\u{1}L\(i)\u{1}",
                                                             with: "\u{1}\(baseIdx + i)\u{1}")
                }
                // Build the replacement expression for the full interpolated string.
                let replacementExpr = Self.makeInterpolatedReplacement(template: template, kind: lift.spec.kind)
                var newArg = arg
                newArg.expression = replacementExpr
                newArgs[argIdx] = newArg
                didLift = true
            }
        }

        guard didLift else { return ExprSyntax(call) }
        var result = call
        result.arguments = LabeledExprListSyntax(newArgs)
        return ExprSyntax(result)
    }

    /// Build a replacement ExprSyntax for a PLAIN placeholder at a given kind.
    private static func makeReplacement(placeholder: String, kind: ArgKind) -> ExprSyntax {
        switch kind {
        case .string:
            // Bare placeholder → thunk renders `a[k]`
            return ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(placeholder)))
        case .localizedStringKey:
            // `LocalizedStringKey(\u{1}k\u{1})` → thunk renders `LocalizedStringKey(a[k])`
            let innerArg = LabeledExprSyntax(
                expression: ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(placeholder))))
            return ExprSyntax(FunctionCallExprSyntax(
                calledExpression: ExprSyntax(DeclReferenceExprSyntax(
                    baseName: .identifier("LocalizedStringKey"))),
                leftParen: .leftParenToken(),
                arguments: LabeledExprListSyntax([innerArg]),
                rightParen: .rightParenToken()))
        }
    }

    /// cli 1.6.34 — the per-arm placeholder SOURCE for a lifted ternary arm at a global
    /// index, position-typed. Returns the Swift source FRAGMENT (not a SwiftSyntax node)
    /// that goes into the ternary template; the ThunkGenerator's text pass rewrites the
    /// embedded `\u{1}g\u{1}` → `a[g]`.
    ///   - .string:             `\u{1}g\u{1}`                       → `a[g]`
    ///   - .localizedStringKey: `LocalizedStringKey(\u{1}g\u{1})`  → `LocalizedStringKey(a[g])`
    private static func ternaryArmPlaceholder(globalIndex: Int, kind: ArgKind) -> String {
        let ph = "\u{1}\(globalIndex)\u{1}"
        switch kind {
        case .string:
            return ph
        case .localizedStringKey:
            return "LocalizedStringKey(\(ph))"
        }
    }

    /// Build a replacement ExprSyntax for an INTERPOLATED string.
    ///
    /// The `template` string already has \u{1}k\u{1} global placeholders for static
    /// segments and \(expr) for dynamic segments.  We produce a string-interpolation
    /// expression from it (rather than trying to build SwiftSyntax nodes for the
    /// interpolation segments — that's complex and fragile).  Since the template is
    /// ITSELF used as the slot source text (not compiled directly), we just embed it
    /// as a description token that the ThunkGenerator's text-replace pass will process.
    ///
    /// For .localizedStringKey positions: `LocalizedStringKey("\(template)")` (a string-
    /// interpolation constructor).
    /// For .string positions: use the template as a bare interpolated-string identifier
    /// (the placeholder sequence the ThunkGenerator already handles).
    private static func makeInterpolatedReplacement(template: String, kind: ArgKind) -> ExprSyntax {
        // We can't easily build a SwiftSyntax StringLiteralExprSyntax with both static
        // and interpolation segments from scratch.  Instead we emit the template as an
        // identifier token that ThunkGenerator's substitution pass replaces verbatim.
        // This matches the existing behavior for plain-literal placeholders.
        let embeddedToken = "\"\(template)\""
        switch kind {
        case .string:
            // Bare string expression: `"<template>"`
            return ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(embeddedToken)))
        case .localizedStringKey:
            // `LocalizedStringKey("<template>")` → thunk renders LocalizedStringKey(a[0]+...+expr+...)
            let innerArg = LabeledExprSyntax(
                expression: ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(embeddedToken))))
            return ExprSyntax(FunctionCallExprSyntax(
                calledExpression: ExprSyntax(DeclReferenceExprSyntax(
                    baseName: .identifier("LocalizedStringKey"))),
                leftParen: .leftParenToken(),
                arguments: LabeledExprListSyntax([innerArg]),
                rightParen: .rightParenToken()))
        }
    }

    // MARK: - Position classification table

    private struct LiftSpec {
        /// Argument label to match; nil means "first unlabeled argument".
        var label: String?
        var kind: ArgKind
    }

    /// Whether `name` is a RECOGNIZED standard-library SwiftUI call (has an explicit
    /// `case` in `liftSpecs`, i.e. NOT the custom-view `default`). Recognized calls keep
    /// their POSITION-TYPED specs even in lift-all mode — their localization correctness
    /// (LocalizedStringKey vs String) must be preserved. Only the custom/unknown case
    /// widens to all-plain-string-args.
    private static func isRecognizedCallName(_ name: String) -> Bool {
        switch name {
        case "Text", "Button", "Toggle", "Menu", "Link", "ShareLink",
             "TextField", "SecureField", "Label",
             "Section", "Picker", "Stepper", "GroupBox", "DisclosureGroup",
             "NavigationLink", "LabeledContent", "ProgressView", "Gauge",
             "Image",
             "accessibilityLabel", "accessibilityHint", "accessibilityValue",
             "accessibilityIdentifier", "help":
            return true
        default:
            return false
        }
    }

    /// Returns the lift specs for a recognized SwiftUI call name.
    /// An empty array means the call is not recognized → nothing is lifted.
    private static func liftSpecs(for name: String) -> [LiftSpec] {
        switch name {
        // ── LocalizedStringKey positions ──────────────────────────────────────────────
        // Text("lit") — first unlabeled arg is LocalizedStringKey.
        // Text(verbatim:"lit") is handled separately below (String position).
        // We don't lift Text here at all because Text with a plain literal LOWERS to
        // N.text(...) and never reaches opaqueExpr; only complex Text forms (SwiftUI
        // interpolation overloads, non-resolvable content) reach opaqueExpr. Lifting
        // those is safe: `Text(LocalizedStringKey(a[0]))` compiles and preserves
        // localization. BUT: we must NOT lift the verbatim: label (String position).
        case "Text":
            // First unlabeled arg → LocalizedStringKey. `verbatim:` is a plain String
            // position (cli 1.6.34): lifting it as a bare placeholder renders
            // `Text(verbatim: a[k])`, which is correct (a[k] is a String); wrapping it as
            // LocalizedStringKey would be a COMPILE error. This also covers the ternary form
            // `Text(verbatim: cond ? "a" : "b")` → bare-string arms.
            return [LiftSpec(label: nil, kind: .localizedStringKey),
                    LiftSpec(label: "verbatim", kind: .string)]
        case "Button", "Toggle", "Menu", "Link", "ShareLink":
            return [LiftSpec(label: nil, kind: .localizedStringKey)]
        case "TextField", "SecureField":
            // First unlabeled arg is the placeholder: LocalizedStringKey.
            return [LiftSpec(label: nil, kind: .localizedStringKey)]
        case "Label":
            // First unlabeled is the title: LocalizedStringKey. systemImage: is String.
            return [LiftSpec(label: nil, kind: .localizedStringKey),
                    LiftSpec(label: "systemImage", kind: .string)]
        case "Section", "Picker", "Stepper", "GroupBox", "DisclosureGroup",
             "NavigationLink", "LabeledContent", "ProgressView", "Gauge":
            return [LiftSpec(label: nil, kind: .localizedStringKey)]
        // ── String positions ──────────────────────────────────────────────────────────
        case "Image":
            // Image(systemName: "lit") → String position
            // Image("lit") → String position (asset name, verbatim)
            // Image(decorative: "lit") → String position
            return [LiftSpec(label: "systemName", kind: .string),
                    LiftSpec(label: nil, kind: .string),
                    LiftSpec(label: "decorative", kind: .string)]
        case "accessibilityLabel", "accessibilityHint", "accessibilityValue":
            // These modifiers take LocalizedStringKey — preserves localization semantics.
            return [LiftSpec(label: nil, kind: .localizedStringKey)]
        case "accessibilityIdentifier":
            // FIX 1: View.accessibilityIdentifier(_:) takes a plain String (NOT
            // LocalizedStringKey). The thunk must render `accessibilityIdentifier(a[k])`
            // with a bare String argument — wrapping it as LocalizedStringKey is a
            // COMPILE ERROR.  Split into its own case with kind: .string.
            return [LiftSpec(label: nil, kind: .string)]
        case "help":
            return [LiftSpec(label: nil, kind: .localizedStringKey)]
        default:
            // CUSTOM VIEW / HELPER CALL (`OnboardingPage(title: "…")`, `DisplayText(text: "…")`,
            // `PillButton(title: "Continue", icon: "arrow.right")`): lift a plain string LITERAL
            // passed under a DISPLAY-CONTENT or ICON label as a plain `String` (bare `a[k]`), so
            // editing that constant in a slotted custom view rides WASM (OTA-editable) instead of
            // baking into native slot source (a FINGERPRINT MISMATCH on edit — the real-app bug).
            // ONLY these explicit display/icon labels match — identity/data positions are NOT
            // lifted: `.tag(…)`/ForEach `id:`/Chart `.value(…)` have a base or non-display label,
            // an asset `Color("…")` / unlabeled first arg has no matching label here, so all stay
            // baked/stable. A custom view whose param is `LocalizedStringKey` (not `String`) makes
            // the generated thunk fail to compile → that view DEMOTES (prove-or-demote), never a
            // wrong render.
            return Self.customCallDisplayLiftSpecs
        }
    }

    /// Display-content / icon argument labels lifted for an UNRECOGNIZED (custom view/helper)
    /// call — the `default` case of `liftSpecs`. Plain `String` positions (rendered bare `a[k]`).
    /// Identity/data labels (`id`, `tag`, `value`, `key`, `format`, `specifier`) are deliberately
    /// ABSENT so a literal in those positions never rides WASM (it must stay byte-stable).
    private static let customCallDisplayLiftSpecs: [LiftSpec] = [
        "title", "text", "label", "message", "subtitle", "caption",
        "headline", "subheadline", "description", "prompt", "placeholder",
        "header", "footer", "body", "icon", "systemImage", "systemName",
    ].map { LiftSpec(label: $0, kind: .string) }
}

// MARK: - Text(verbatim:) override

extension StringLiteralLifter {
    // Text(verbatim: "lit") is a String position — handled by the general visit(_:)
    // via a special label: "verbatim" maps to .string. We override the liftSpecs
    // by noting that "Text" with label "verbatim" should use .string, not .localizedStringKey.
    // The liftSpecs() above returns [LiftSpec(nil, .localizedStringKey)] for Text,
    // but for the verbatim: label there is no matching spec (nil != "verbatim"), so the
    // verbatim arg won't be accidentally lifted by the nil-label spec. We add it explicitly:
}
// (Text verbatim: is handled below by an additional liftSpec in the table above.
// Actually: the liftSpecs for "Text" only has label:nil → the labeled "verbatim:" arg
// won't match the nil-label spec because `arg.label?.text == "verbatim"` != nil.
// So Text(verbatim:"lit") will NOT be lifted by the LocalizedStringKey spec — correct!
// To lift Text(verbatim:"lit") as a String position we need an explicit spec.
// However: Text(verbatim:) falling to opaqueExpr is rare (only for non-literal verbatim
// args, per line 1241-1243 — these aren't string literals). We defer this case.

/// Detects a `return` STATEMENT anywhere in a syntax subtree. Used by the slot
/// AnyView-wrappability gate: a `switch` body whose arms `return` (`switch r { case 1:
/// return Text(…) }`) parses cleanly but is a SEMANTIC error when wrapped in an
/// expression/ViewBuilder position, so a slot source carrying one must demote. The scan
/// crosses arm/closure boundaries deliberately — ANY `return` in the captured fragment
/// makes the `AnyView(…)` wrap unsafe.
final class ReturnStmtFinder: SyntaxVisitor {
    private(set) var found = false
    private init() { super.init(viewMode: .sourceAccurate) }
    static func contains(in node: Syntax) -> Bool {
        let f = ReturnStmtFinder(); f.walk(node); return f.found
    }
    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        found = true; return .skipChildren
    }
}

// MARK: - Non-ASCII guest string-literal encoding (multi-byte UTF-8 robustness)

/// Rewrites every PLAIN (non-interpolated) string literal in an emitted guest body
/// that contains a NON-ASCII scalar into an explicit byte form:
///
///   "録画品質"  →  String(decoding: [233,140,178,231,148,187,229,147,129,232,179,170] as [UInt8], as: UTF8.self)
///
/// ## Why
/// The guest is compiled with **Embedded Swift**. How a non-ASCII string LITERAL is
/// codegen'd (small-string packed inline vs a data-section blob, and the exact
/// small-string layout) is toolchain-version-dependent, and some toolchains (observed
/// on an Xcode-27 beta) miscompile / mislay a multi-byte literal so the guest emits a
/// garbled/empty string at runtime — the view then silently demotes to native and a
/// Japanese/emoji/accented `Text("…")` OTA patch "doesn't take" even though the pipeline
/// reported it shipped. A `[UInt8]` array literal (pure ASCII source: integers) plus
/// `String(decoding:as:)` — an API the guest already links heavily (`_patchReadString`,
/// `JSONOut`) — reconstructs the SAME string at runtime with NO dependence on the
/// toolchain's non-ASCII string-literal codegen. Byte-for-byte identical rendered output;
/// toolchain-robust construction.
///
/// ## Safety / scope
/// - **ASCII is untouched** (a body with no byte ≥ 0x80 is returned verbatim — the fast
///   path, so every existing ASCII app is byte-identical: zero fingerprint churn).
/// - Only PLAIN literals are rewritten (`representedLiteralValue` is non-nil): an
///   INTERPOLATION (`"オーナー: \(owner)"`) is left as-is (its dynamic part already forces a
///   non-small-string; proven to round-trip). Escapes + raw strings decode correctly via
///   `representedLiteralValue`; an undecodable literal is left as-is (conservative).
/// - The replacement references only `String` / `UInt8` / `UTF8` — all guest-in-scope
///   (see `SwiftUIGuestScopeCheck.safeGlobals`).
enum GuestNonASCIIEncoder {
    /// Fast non-ASCII presence check (a body with none is returned unchanged).
    static func containsNonASCII(_ s: String) -> Bool {
        for b in s.utf8 where b > 0x7F { return true }
        return false
    }

    /// The guest expression that reconstructs `value` at runtime, byte-exact and
    /// toolchain-independent. Used for both in-body literals and slot-arg values.
    static func byteDecodeExpr(_ value: String) -> String {
        let bytes = Array(value.utf8).map { String($0) }.joined(separator: ", ")
        return "String(decoding: [\(bytes)] as [UInt8], as: UTF8.self)"
    }

    /// Rewrite plain non-ASCII string literals in `guestBody` to the byte-decode form.
    /// Returns `guestBody` unchanged when it has no non-ASCII byte (the fast path).
    static func encode(_ guestBody: String) -> String {
        guard containsNonASCII(guestBody) else { return guestBody }
        // Parse as an expression by binding it to a throwaway `let`. The prefix's UTF-8
        // length is subtracted so the collected ranges are relative to `guestBody`.
        let prefix = "let __patch_nonascii_probe = "
        let prefixLen = prefix.utf8.count
        let tree = Parser.parse(source: prefix + guestBody)
        let collector = NonASCIILiteralCollector(prefixByteOffset: prefixLen)
        collector.walk(tree)
        guard !collector.replacements.isEmpty else { return guestBody }
        // Apply in DESCENDING start order so earlier byte offsets stay valid.
        var bytes = Array(guestBody.utf8)
        for r in collector.replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard r.range.lowerBound >= 0, r.range.upperBound <= bytes.count,
                  r.range.lowerBound < r.range.upperBound else { continue }
            bytes.replaceSubrange(r.range, with: Array(r.replacement.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Collects the byte range + byte-decode replacement of every PLAIN non-ASCII string
/// literal in a parsed guest body. Byte ranges are made relative to the original body
/// by subtracting the parse prefix length.
private final class NonASCIILiteralCollector: SwiftSyntax.SyntaxVisitor {
    struct Replacement { let range: Range<Int>; let replacement: String }
    private(set) var replacements: [Replacement] = []
    private let prefixByteOffset: Int
    init(prefixByteOffset: Int) {
        self.prefixByteOffset = prefixByteOffset
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        // `representedLiteralValue` is nil for an INTERPOLATED literal (leave it as-is —
        // its dynamic part already forces a non-small string) and decodes escapes / raw
        // strings correctly for a plain one.
        guard let value = node.representedLiteralValue,
              GuestNonASCIIEncoder.containsNonASCII(value) else { return .visitChildren }
        let lo = node.positionAfterSkippingLeadingTrivia.utf8Offset - prefixByteOffset
        let hi = node.endPositionBeforeTrailingTrivia.utf8Offset - prefixByteOffset
        guard lo >= 0, hi > lo else { return .visitChildren }
        replacements.append(.init(range: lo..<hi,
                                  replacement: GuestNonASCIIEncoder.byteDecodeExpr(value)))
        return .visitChildren
    }
}
