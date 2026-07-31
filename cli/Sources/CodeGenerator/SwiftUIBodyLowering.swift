// SPDX-License-Identifier: Apache-2.0

// BodyLowering.swift — the SwiftSyntax body→ViewNode lowering + analyzer.
// =======================================================================
// Given a SwiftUI `View` type's source, this:
//   1. Finds the `body` computed property (or a `@ViewBuilder` function).
//   2. Walks the result-builder expression tree.
//   3. Classifies every primitive/container/modifier as LOWERABLE (→ ViewNode
//      IR, which runs in WASM) or a NATIVE FALLBACK (`.opaque`), producing a
//      `LoweringReport` (the headline % measurement).
//   4. Emits the guest-side `N.`-builder Swift code for the lowered tree (what
//      the engine compiles to WASM in place of the native body).
//
// This is a STATIC lowering: it understands the declarative grammar of a body
// (constructor calls + modifier chains + result-builder composition: if/else,
// ForEach, statement lists). Dynamic values that are pure structure (a `@State`
// string in a `Text`, a count in a `ForEach`) are marshalled in as inputs; a
// reference it cannot prove is pure structure becomes `.opaque` so the whole
// view never fails to lower.

import SwiftSyntax
import SwiftParser
import ViewNodeIR
import Foundation
import CryptoKit

public struct BodyLowering {
    public init() {}

    // MARK: - Per-view body content hash (NATIVE-FAST-PATH)

    /// THE ONE deterministic per-view body hash, computed identically at BOTH emit
    /// sites (the manifest emitter in `BuildPipeline`/`SwiftUIGuestEmitter` and the
    /// `ThunkGenerator` thunk call-site). It is the linchpin of the native-fast-path:
    /// the SDK compares the thunk's baked `baselineHash` against the active module's
    /// manifest `bodyHash`; when they MATCH the view is byte-identical to the build's
    /// shipped baseline (no OTA patch touched it) and the thunk renders the NATIVE
    /// body with ZERO WASM. A mismatch (an OTA patch changed this view) routes WASM.
    ///
    /// CANONICAL REPRESENTATION = every channel an OTA patch can change about a view's
    /// rendering, in a deterministic string:
    ///   1. `guestBody` — the `N.`-builder expression that BUILDS the ViewNode tree in
    ///      WASM. Any SEMANTIC body change re-lowers to a different `guestBody`. This is
    ///      the dominant term (identical at both sites: both pass `lowered.guestBody`).
    ///   2. The PARAMETERIZED-SLOT string-literal values (`OpaqueLeaf.stringArgs` keyed
    ///      by the content-stable `OpaqueLeaf.id`). A lifted slot literal rides the
    ///      guest's `BodyEmission.slotArgs` (NOT `guestBody`), so editing one ships OTA
    ///      WITHOUT changing `guestBody`. It MUST be in the hash, or such a patch would
    ///      false-native (silently not apply — the exact dangerous failure). Sorted by
    ///      id so the serialization is order-independent across runs.
    ///
    /// SHA256 ⇒ identical hash ⟺ identical canonical representation (no collisions), so a
    /// MATCH proves the native render equals what the WASM baseline would render, and ANY
    /// change differs. (Tokens are NOT included: a design-system token value is resolved
    /// NATIVELY by the thunk's `__patchTokens()` in BOTH the native body and the WASM
    /// path, and editing the token's source is a compiled-in native change handled by the
    /// native-shell fingerprint — never an OTA channel.)
    public static func viewBodyContentHash(_ lowered: LoweredView) -> String {
        viewBodyContentHash(guestBody: lowered.guestBody, opaqueLeaves: lowered.opaqueLeaves)
    }

    /// The same hash over the primitive inputs (used where only the lowered fields are in
    /// hand). Keep this the SINGLE place the canonical string is built so the two emit
    /// sites can NEVER drift.
    public static func viewBodyContentHash(guestBody: String, opaqueLeaves: [OpaqueLeaf]) -> String {
        var canonical = "v1\n" + guestBody
        // Parameterized-slot literals, deterministically ordered by content-stable id.
        let parameterized = opaqueLeaves
            .filter { !$0.stringArgs.isEmpty }
            .sorted { $0.id < $1.id }
        if !parameterized.isEmpty {
            canonical += "\n\u{1F}slotArgs\u{1F}"
            for leaf in parameterized {
                // `\u{1E}`/`\u{1F}` are control separators that can't appear in a Swift
                // identifier/expression, so the join is unambiguous.
                canonical += "\u{1E}" + leaf.id + "\u{1F}" + leaf.stringArgs.joined(separator: "\u{1F}")
            }
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        // 16 hex chars (64 bits) of the digest — ample collision resistance for the
        // per-build per-view set, and a compact literal to bake into every thunk.
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Public API

    /// Analyze the first `View` struct in `source`, returning its lowering report.
    public func analyze(source: String) -> LoweringReport? {
        let tree = Parser.parse(source: source)
        guard let view = firstView(in: tree) else { return nil }
        let bodyExpr = bodyExpression(of: view.decl)
        guard let bodyExpr else {
            return LoweringReport(viewName: view.name, elements: [])
        }
        var collector = Classifier()
        collector.classify(expr: bodyExpr)
        return LoweringReport(viewName: view.name, elements: collector.elements)
    }

    /// Analyze every `View` struct in `source`.
    public func analyzeAll(source: String) -> [LoweringReport] {
        let tree = Parser.parse(source: source)
        var out: [LoweringReport] = []
        for view in allViews(in: tree) {
            if let bodyExpr = bodyExpression(of: view.decl) {
                var collector = Classifier()
                collector.classify(expr: bodyExpr)
                out.append(LoweringReport(viewName: view.name, elements: collector.elements))
            } else {
                out.append(LoweringReport(viewName: view.name, elements: []))
            }
        }
        return out
    }

    /// Lower the first view's body to a guest `ViewNode`-builder expression
    /// string (the Swift the engine would compile to WASM). Configures the emitter
    /// the SAME way `lowerAllViews` does (inaccessible-member names + marshalled
    /// scalar-array input names) so this convenience API lowers a `ForEach` /
    /// dynamic `List` over a marshalled array to a real bound guest loop, identical
    /// to the production path.
    public func emitGuestBody(source: String) -> String? {
        let tree = Parser.parse(source: source)
        guard let view = firstView(in: tree),
              let bodyExpr = bodyExpression(of: view.decl) else { return nil }
        let structCatalog = Self.flatStructCatalog(in: tree)
        let enumCatalog = Self.rawEnumCatalog(in: tree)
        let helpers = Self.inlinableHelpers(of: view.decl)
        let inputs = Self.gateRichInputs(
            viewInputs(of: view.decl, structCatalog: structCatalog, enumCatalog: enumCatalog),
            bodyExpr: bodyExpr, helperBodies: Array(helpers.values))
        var emitter = Emitter()
        emitter.inaccessibleNames = Self.inaccessibleMemberNames(of: view.decl)
        emitter.selfMemberNames = Self.allMemberNames(of: view.decl)
        emitter.scalarArrayInputNames = Self.scalarArrayInputNames(inputs)
        // The marshalled SCALAR input names (string/bool/int/double) the guest binds as
        // `let`s — MUST be set here to match the production `lowerAllViews` path, or the
        // scope check would flag a perfectly-resolvable `Text(title)` and (mis)slot it.
        emitter.marshalledInputNames = Set(inputs.filter {
            switch $0.kind {
            case .string, .bool, .int, .double: return true
            default: return false
            }
        }.map(\.name))
        emitter.structArrayInputElements = Self.structArrayInputElements(inputs)
        emitter.flatStructInputElements = Self.flatStructInputElements(inputs)
        emitter.enumInputElements = Self.enumInputElements(inputs)
        emitter.helperBodies = helpers
        return emitter.emit(expr: bodyExpr)
    }

    // MARK: - Production engine API (BuildPipeline integration)

    /// One fully-lowered View body: the view's name, its lowering report (the
    /// measured % of nodes/modifiers that ride WASM), and the emitted guest
    /// `N.`-builder expression (the Swift the engine compiles to WASM in place of
    /// the native body). The lowerable elements ride WASM; the rest become
    /// `.opaque` native-fallback slots, so a body never fails to lower.
    public struct LoweredView: Sendable {
        public let viewName: String
        public let report: LoweringReport
        /// The `N.`-builder expression that BUILDS the ViewNode tree in WASM.
        public let guestBody: String
        /// The view's stored-property INPUTS the body references (the `@State`/`let`
        /// values marshalled in across the boundary). The guest binds each from the
        /// input JSON (falling back to its default), so a body that reads `name` /
        /// `notificationsOn` compiles + runs in WASM. Scalars AND arrays-of-scalars
        /// marshal faithfully; a struct/enum/dictionary input binds to its literal
        /// default in the guest (the SDK still marshals its real value, but the
        /// Foundation-free guest can't reconstruct it) — see `referencesUnmarshalledInput`.
        public let inputs: [ViewInput]
        /// True when the lowered body READS at least one input the GUEST cannot
        /// reconstruct (a struct/enum/dictionary/custom value type). Binding such an
        /// input to a literal default would render WRONG, so the engine refuses to
        /// auto-route the view (`thunkSafe = false`) and it stays NATIVE — faithful
        /// over broken. A body that only reads scalars/arrays-of-scalars is false.
        public let referencesUnmarshalledInput: Bool
        /// True when the emitted guest body references a FREE identifier the guest
        /// scope can't resolve — a computed property (`var height: CGFloat { … }`,
        /// skipped by `viewInputs`), a body-local `let` the emitter dropped
        /// (`let owners = schedule.…`), a design-system static in a NUMERIC position
        /// (`Theme.Radius.md` — the token path only lowers color/font modifier
        /// VALUES), or a Foundation type left in an input default (`Locale.current.…`).
        /// Such a body compiles to `cannot find 'X' in scope`, which (since all view
        /// exports share ONE wrapper file) demotes the WHOLE module to zero views.
        /// The engine EXCLUDES such a view from guest emission (it renders natively) so
        /// the other views still ship — the #1 real-app fix. The unresolved names are
        /// in `unresolvedSymbols` (for the demote diagnostic).
        public let referencesUnresolvedSymbol: Bool
        /// The free identifiers the guest scope can't resolve (empty unless
        /// `referencesUnresolvedSymbol`). Surfaced in the verbose demote log.
        public let unresolvedSymbols: [String]
        /// The view's own `private`/`fileprivate` member names that the lowered body
        /// READS in a position that would have to be host-resolved (a slot closure or a
        /// design-system token) — but CAN'T be, because the generated thunk's
        /// `__patchSlots()`/`__patchTokens()` live in a SEPARATE file and Swift's
        /// file-scoped `private`/`fileprivate` makes those members invisible there. This
        /// is the "inaccessible-member wall": such a member read forces the view native
        /// even though its value is otherwise marshallable. Empty for a view blocked for
        /// any OTHER reason (a genuinely non-reconstructable struct/enum, a body-local
        /// `let`, a computed property). Used ONLY to make the EXCLUDE diagnostic precise
        /// (name the real architectural limit); it never changes what ships.
        public let inaccessibleReadNames: [String]
        /// DIAGNOSTIC (never changes what ships): the precise stored-property names whose
        /// non-reconstructable value the lowered body READS and which therefore force the
        /// view native — the actionable "why didn't my view lower" answer. A superset of
        /// `inaccessibleReadNames` semantically (those are the private subset). Empty when
        /// the block is purely a free out-of-scope symbol (see `unresolvedSymbols`).
        public let blockingReadNames: [String]
        /// DIAGNOSTIC: the subset of `blockingReadNames` that are SwiftData-backed —
        /// a `@Query` property, an `@Environment(\.modelContext)`, a `@Bindable`/stored
        /// property typed as a `@Model` class. These are the modern-SwiftUI-app blocker:
        /// the engine can't marshal SwiftData's reference-type, macro-backed model objects,
        /// so a view reading them demotes. Surfaced so the dev sees the real cause.
        public let swiftDataBlockers: [String]
        /// DIAGNOSTIC: the subset of `blockingReadNames` whose declared type annotation is
        /// a Swift TUPLE (`(type1, type2)` / `(label: Type, …)`). Tuples aren't Codable so
        /// the engine can't marshal them into the guest; replacing the tuple with a named
        /// Codable struct would make the view OTA-patchable. Purely diagnostic — never
        /// changes what ships. Empty when no blocking read is a tuple-typed property.
        public let tupleBlockingNames: [String]
        /// The view's interactive STATE MODEL (Breakthrough #5 productization): the
        /// `@State` fields the body's controls/taps bind to, plus the mutation rules
        /// (event id → state change) the engine derived from those controls. When
        /// non-empty, the engine ALSO emits a `dispatch(state,event)->{newState,newTree}`
        /// guest export so the UPDATE logic runs IN WASM (not native). `nil`/empty ⇒
        /// no dispatch is emitted (the view stays a `view_body`-only re-render).
        public let stateModel: StateModel?
        /// The non-lowerable LEAVES the body emitted as `.opaque` nodes (with a
        /// content-stable id + slotability). For mixed-view rendering the build-time
        /// thunk supplies a native slot closure for each SLOTABLE leaf; a view all of
        /// whose opaque leaves are slotable is still ROUTABLE (the lowered parts ride
        /// WASM, the native leaves render from the compiled-in closures).
        public let opaqueLeaves: [OpaqueLeaf]
        /// The DESIGN-SYSTEM TOKENS (color/font) the lowered body references in a
        /// modifier value position. The build-time thunk supplies each token's resolved
        /// `Color`/`Font` by id (`__patchTokens()`); the tree carries `.hostToken(id)` /
        /// `.fontToken(id)`. Every recorded token is resolvable by construction (the
        /// emitter only records one whose closure compiles), so they never block
        /// `thunkSafe` — but the thunk MUST supply all of them (the SDK demotes a view
        /// whose tree carries a token id the thunk didn't cover, like an opaque leaf).
        public let hostTokens: [HostToken]
        /// The PER-ROW INDEXED NATIVE-ACTION SLOTS the body emitted (`indexedForEachSlot`
        /// nodes). For each, the build-time thunk supplies a per-row factory `(Int) ->
        /// AnyView` (keyed by id) AND the row count (under `__rowcount_<id>`). Every
        /// recorded slot is provably thunk-compilable by construction (the emitter only
        /// records one whose collection + row sources reference no body-local besides the
        /// loop var / no inaccessible member), so — like `hostTokens` — they never block
        /// `thunkSafe`; but the thunk MUST cover all of them (the SDK demotes a view whose
        /// tree carries an indexed-slot id the thunk didn't supply, like an opaque leaf).
        public let indexedRowSlots: [IndexedRowSlot]
        /// The NATIVE-ACTION SLOTS the body emitted (`actionSlotButton` nodes — an actions-list
        /// Button whose action is a native method call). For each, the build-time thunk supplies a
        /// `() -> Void` action closure (keyed by id) via `__patchActionSlots()`. Every recorded
        /// slot is provably thunk-compilable by construction (the emitter only records one whose
        /// action closure references no body-local / no inaccessible member), so — like
        /// `hostTokens`/`indexedRowSlots` — they never block `thunkSafe`; but the thunk MUST cover
        /// all of them (the SDK demotes a view whose tree carries an action-slot id the thunk
        /// didn't supply, never shipping a dead button). An UN-slotable actions-list Button instead
        /// sets `hasUndispatchableAction` (the whole view demotes — the dev's native view renders).
        public let actionSlots: [ActionSlot]
        /// The NATIVE EFFECT-MODIFIER SLOTS the body emitted (`nativeEffectSlot` modifiers — an
        /// undispatchable EFFECT modifier `.task`/`.onAppear`/`.refreshable`/`.onSubmit`/gesture
        /// whose closure runs a native side-effect). For each, the build-time thunk supplies a
        /// `(AnyView) -> AnyView` effect-application closure (keyed by id) via `__patchEffectSlots()`.
        /// Every recorded slot is provably thunk-compilable + fidelity-safe by construction (the
        /// emitter only records one whose re-application references no body-local / no inaccessible
        /// member and isn't an animation/value-watcher), so — like `hostTokens`/`actionSlots` — they
        /// never block `thunkSafe`; but the thunk MUST cover all of them (the SDK demotes a view
        /// whose tree carries an effect-slot id the thunk didn't supply, never silently re-showing
        /// the old native view). An UN-slotable / unsafe effect instead keeps `hasUndispatchableEffect`.
        public let effectSlots: [EffectSlot]
        /// True when the lowered body contains ≥1 `GeometryReader` (C): its child
        /// reads the reserved `__geo_*` inputs, so the guest emitter must bind them
        /// from the input JSON (the SDK host wrapper supplies the live proxy's
        /// size/frame there). Drives `SwiftUIGuestEmitter`'s geo-input bindings.
        public let usesGeometry: Bool
        /// True when the body emitted a `Button` (in a MODIFIER-ACTION LIST context —
        /// `.alert`/`.confirmationDialog`/`.toolbar`/`Menu`/`.contextMenu`) whose action is
        /// REAL but NOT a recordable dispatch rule. Such a button would RENDER from WASM yet
        /// dispatch NOTHING on device (a dead control), and the renderer can't attach a native
        /// slot to an actions-list entry — so the WHOLE view must DEMOTE to native (fully
        /// functional). The BuildPipeline `thunkSafe` gate ANDs in `!hasUndispatchableAction`.
        /// (In a plain BODY/container context the same button is SLOTTED instead — a working
        /// native control — and this flag stays false; see `SwiftUIEmitter.emitButton`.)
        public let hasUndispatchableAction: Bool
        /// True when the body emitted a BEHAVIORAL/LIFECYCLE modifier whose effect is NOT
        /// faithfully produced on device (`.task`/`.onChange` with a real closure;
        /// `.onDelete`/`.onMove`; `.onAppear`/`.onDisappear`/`.onSubmit`/`.onTapGesture`/
        /// `.onLongPressGesture` with a non-trivial closure the guest couldn't record as a
        /// dispatch rule). A modifier closure has no native-slot fallback, so the WHOLE view
        /// must DEMOTE to native (its real modifier then runs natively = production behavior).
        /// The BuildPipeline `thunkSafe` gate ANDs in `!hasUndispatchableEffect` (mirrored in
        /// `ProjectFingerprint.isAutoRouted`). See `SwiftUIEmitter.hasUndispatchableEffect`.
        public let hasUndispatchableEffect: Bool
        /// True when this view marshals a REACTIVE view-model collection (reactiveCollectionInputs
        /// registered a `.flatStruct` input). The on-device SDK can only reconstruct that input
        /// with its reactive-`extract` capability (IR schema v9); an OLDER SDK supplies no
        /// `{"vm":…}` so a `ForEach(vm.items)` would render EMPTY. Drives the view's manifest
        /// `minVersion` (9) so an older host DEMOTES this view to native instead of empty-rendering.
        public let usesReactiveMarshalling: Bool
        /// True when the body emitted a `.animation(_:value:)` modifier. The SDK renderer reconstructs
        /// the real `Animation` + watches the value scalar (IR schema v11); an OLDER SDK NO-OPs it (the
        /// value change applies instantly — a silently degraded effect). Drives the view's manifest
        /// `minVersion` (11) so an older host DEMOTES this view to native instead of degrading it.
        /// See `SwiftUIEmitter.usesAnimationValue`.
        public let usesAnimationValue: Bool
        /// STRUCTURALLY-STATIC CACHE: true when the WASM-emitted ViewNode tree is provably
        /// IDENTICAL across ALL inputs — no bound input name appears in the guestBody in a
        /// live (non-opaque-label) position, no input-riding host token (`__numtok_`/
        /// `__strtok_`) is present, the view doesn't use GeometryReader (which injects
        /// `__geo_*` inputs that vary per-layout), and the view has no interactive state
        /// model (dispatch re-emits the tree with new state → different state = different
        /// tree). Conservative by construction: false ⟹ always-WASM (the safe prior
        /// behavior). The SDK can cache the decoded tree after the first WASM call and skip
        /// WASM on ALL subsequent renders — the tree is a pure constant.
        public let isStructurallyStatic: Bool
        /// The CHILD-VIEW CALLBACK SLOTS the body emitted (`callbackSlot` nodes — a custom
        /// child-view call with a `() -> Void` closure arg whose body is dispatchable). For each,
        /// the build-time thunk's `__patchCallbackSlots()` supplies an `AnyView` opaque closure
        /// (the full child-view call, with the closure arg replaced by a stable forwarding closure
        /// `{ self.__patchDispatchCallback("<id>") }`). The closure body itself lives in the WASM
        /// dispatch table (OTA-patchable). Every recorded slot is provably thunk-compilable by
        /// construction (same `isSlotable` gate as opaque leaves); they don't block `thunkSafe`,
        /// but the thunk MUST cover all of them (the SDK demotes a view whose tree carries a
        /// callback-slot id the thunk didn't supply). Fingerprinted under `CB:` (the slot source,
        /// NOT the callback body, so a callback-body edit is fingerprint-stable = OTA).
        public let callbackSlots: [CallbackSlot]
        public init(viewName: String, report: LoweringReport, guestBody: String,
                    inputs: [ViewInput] = [], stateModel: StateModel? = nil,
                    opaqueLeaves: [OpaqueLeaf] = [],
                    hostTokens: [HostToken] = [],
                    indexedRowSlots: [IndexedRowSlot] = [],
                    actionSlots: [ActionSlot] = [],
                    effectSlots: [EffectSlot] = [],
                    callbackSlots: [CallbackSlot] = [],
                    referencesUnmarshalledInput: Bool = false,
                    referencesUnresolvedSymbol: Bool = false,
                    unresolvedSymbols: [String] = [],
                    inaccessibleReadNames: [String] = [],
                    blockingReadNames: [String] = [],
                    swiftDataBlockers: [String] = [],
                    tupleBlockingNames: [String] = [],
                    usesGeometry: Bool = false,
                    hasUndispatchableAction: Bool = false,
                    hasUndispatchableEffect: Bool = false,
                    usesReactiveMarshalling: Bool = false,
                    usesAnimationValue: Bool = false,
                    isStructurallyStatic: Bool = false) {
            self.viewName = viewName
            self.report = report
            self.guestBody = guestBody
            self.inputs = inputs
            self.stateModel = stateModel
            self.opaqueLeaves = opaqueLeaves
            self.hostTokens = hostTokens
            self.indexedRowSlots = indexedRowSlots
            self.actionSlots = actionSlots
            self.effectSlots = effectSlots
            self.callbackSlots = callbackSlots
            self.referencesUnmarshalledInput = referencesUnmarshalledInput
            self.referencesUnresolvedSymbol = referencesUnresolvedSymbol
            self.unresolvedSymbols = unresolvedSymbols
            self.inaccessibleReadNames = inaccessibleReadNames
            self.blockingReadNames = blockingReadNames
            self.swiftDataBlockers = swiftDataBlockers
            self.tupleBlockingNames = tupleBlockingNames
            self.usesGeometry = usesGeometry
            self.hasUndispatchableAction = hasUndispatchableAction
            self.hasUndispatchableEffect = hasUndispatchableEffect
            self.usesReactiveMarshalling = usesReactiveMarshalling
            self.usesAnimationValue = usesAnimationValue
            self.isStructurallyStatic = isStructurallyStatic
        }
    }

    /// The interactive state model the engine derives for a view: the `@State`
    /// fields its controls bind to + the UPDATE rules (event id → mutation). This is
    /// the data the guest emitter turns into a `dispatch` export running in WASM.
    ///
    /// COVERED grammar (the proven subset — matches the standalone interactive
    /// proof): scalar `@State` (Bool/Int/Double/String) mutated by a control's
    /// two-way binding (Toggle/Slider/Stepper/TextField) or a discrete event
    /// (`.onTapGesture`/`Button(action:)`) whose action is a single recognizable
    /// `@State` mutation (assign / toggle / increment / decrement / clamp). Anything
    /// outside this stays NATIVE (no rule emitted) — demote-safe, like the rest of
    /// the lowering.
    public struct StateModel: Sendable, Equatable {
        /// The scalar `@State` fields that participate (name + kind + default literal).
        public var fields: [ViewInput]
        /// The mutation rules: each maps an event id (the same id the emitted tree
        /// carries) to a state mutation. Driven in WASM by the `dispatch` export.
        public var rules: [MutationRule]
        public init(fields: [ViewInput], rules: [MutationRule]) {
            self.fields = fields
            self.rules = rules
        }
        /// A model is interactive (emits dispatch) iff it has ≥1 field AND ≥1 rule.
        public var isInteractive: Bool { !fields.isEmpty && !rules.isEmpty }
    }

    /// One UPDATE rule: on `eventID`, apply `op` to the field `field`. The event id
    /// is exactly what the lowered tree carries for the control/tap, so the guest's
    /// `update` matches by the SAME id the host echoes back.
    public struct MutationRule: Sendable, Equatable {
        public enum Op: Sendable, Equatable {
            /// `field = <incoming bool value>` (else flip on a bare tap).
            case setBool
            /// `field = clamp(<incoming int>, lo, hi)` (lo/hi from the Stepper range, or nil).
            case setIntClamped(lo: Int?, hi: Int?)
            /// `field = clamp(<incoming double>, lo, hi)` (Slider range).
            case setDoubleClamped(lo: Double, hi: Double)
            /// `field = <incoming string>`.
            case setString
            /// `field.toggle()` (a discrete tap flips a Bool).
            case toggleBool
            /// `field += step` (clamped to hi if present, else wraparound to lo).
            case incInt(step: Int, lo: Int?, hi: Int?, wrap: Bool)
            /// `field -= step` (clamped to lo if present).
            case decInt(step: Int, lo: Int?, hi: Int?)
            /// `field = <int literal>` (a tap that assigns a constant).
            case assignIntLiteral(Int)
            /// `field = true` / `field = false` (a tap that sets a constant Bool — the
            /// overwhelmingly common `showing = true`/`isOpen = false` sheet/flag toggle).
            case assignBoolLiteral(Bool)
        }
        public var eventID: String
        public var field: String
        public var op: Op
        public init(eventID: String, field: String, op: Op) {
            self.eventID = eventID; self.field = field; self.op = op
        }
    }

    /// A non-lowerable LEAF the body emitted as a `.opaque` node. For mixed-view
    /// rendering the build-time thunk supplies a native slot closure for each
    /// SLOTABLE leaf (`{ AnyView(<source>) }`, captured over self), keyed by the
    /// content-stable `id` the emitted tree carries — so the engine (push) and the
    /// thunk generator (build) agree on the id without sharing state.
    public struct OpaqueLeaf: Sendable, Equatable {
        public let id: String
        /// The leaf's Swift source — rendered natively in the slot closure. When the
        /// leaf is PARAMETERIZED (`stringArgs` non-empty) this is the TEMPLATE: the
        /// original source with each simple string-literal argument replaced by a
        /// placeholder `\u{1}N\u{1}` (N = the arg index). The thunk's slot factory
        /// substitutes `\u{1}N\u{1}` → the runtime-supplied `args[N]`.
        public let source: String
        /// True iff the slot closure is guaranteed to compile (references no
        /// body-local name — only self members / types / globals).
        public let slotable: Bool
        public let label: String
        /// PARAMETERIZED SLOT — the simple string-literal argument VALUES, in source
        /// order, that were lifted out of `source` into the placeholders. Empty for a
        /// plain (non-parameterized) slot. The values ride WASM via
        /// `BodyEmission.slotArgs[id]`, so editing a string literal inside a slotted
        /// custom view (`DisplayText(text: "Settings")`) is OTA-patchable AND the
        /// native-shell fingerprint stays stable (the slot id is structural — derived
        /// from the template, not the literal values).
        public let stringArgs: [String]
        /// PARAMETERIZED SLOT — the UTF-8 byte ranges (into the source the body was
        /// lowered from) of each lifted string literal's FULL `StringLiteralExpr`
        /// (quotes included), in source order (parallel to `stringArgs`). The
        /// fingerprint walker uses these to normalize ONLY the lifted literals to a
        /// placeholder, so editing a slotted custom view's string keeps the
        /// native-shell fingerprint stable WHILE a non-string (number/arg/structure)
        /// edit still trips the gate. Empty for a plain (non-parameterized) slot.
        public let stringArgRanges: [Range<Int>]
        public init(id: String, source: String, slotable: Bool, label: String,
                    stringArgs: [String] = [], stringArgRanges: [Range<Int>] = []) {
            self.id = id; self.source = source; self.slotable = slotable
            self.label = label; self.stringArgs = stringArgs
            self.stringArgRanges = stringArgRanges
        }
    }

    /// A DESIGN-SYSTEM TOKEN a lowered body references in a color/font modifier
    /// position (`.foregroundStyle(Theme.Colors.ink)`, `.font(Theme.Font.body(13))`).
    /// The lowered tree carries only the content-stable `id` (`ColorRef.hostToken(id)`
    /// / `Modifier.fontToken(id)`); the build-time thunk's `__patchTokens()` evaluates
    /// `source` NATIVELY (over `self`) → a resolved `Color`/`Font` keyed by that id. So
    /// the modifier rides WASM (patchable) while its VALUE is host-supplied — the same
    /// slot mechanism as a mixed-view leaf, but for a modifier value. The engine only
    /// records a token whose `source` is RESOLVABLE (references no body-local /
    /// inaccessible member, so the thunk closure compiles); an unresolvable one makes
    /// the whole node slot instead (faithful over wrong). The id is a content-stable
    /// FNV hash, so the engine (push) and thunk generator (build) agree with no shared
    /// state — exactly like `OpaqueLeaf`.
    public struct HostToken: Sendable, Equatable {
        /// A token's value tier. `color`/`font` are applied by the SDK RENDERER from
        /// the thunk's `__patchTokens()` (the tree carries `.hostToken(id)`/
        /// `.fontToken(id)`). A `number` (a design-system `CGFloat`/`Double` constant
        /// like `Theme.Radius.lg` used in a NUMERIC position — `.cornerRadius(…)`,
        /// `.padding(…)`, `frame`) is consumed INSIDE the guest body, so it doesn't ride
        /// the tree at all: the thunk resolves it natively → a Double the SDK MERGES into
        /// the guest's input JSON under a reserved `__numtok_<id>` key (exactly like a
        /// `__geo_*` input), and the guest binds + reads it. This is what lets a numeric
        /// design token LOWER instead of leaking `Theme` as a free identifier.
        ///
        /// A `string` is the STRING analogue of a `number`: a host-resolved String used as
        /// `Text(…)` CONTENT whose expression isn't guest-reconstructable (an enum's
        /// computed-String member like `confidence.label`, a `.uppercased()` of one, a
        /// ternary thereof). The thunk evaluates it NATIVELY → a String the SDK merges into
        /// the guest's input JSON under the reserved `__strtok_<id>` key; the guest reads it
        /// as the Text content. The view STRUCTURE/modifiers stay OTA-patchable — only the
        /// enum-derived string is host-resolved (exactly like a slot, but for text content).
        public enum Kind: String, Sendable, Equatable { case color, font, number, string }

        /// True when this token rides the guest's INPUT JSON (`.number`/`.string` — bound
        /// from a reserved `__numtok_`/`__strtok_` key the SDK merges in) rather than the
        /// rendered tree (`.color`/`.font` — applied by the renderer). Used by the guest
        /// emitter (which binds these as inputs) and the scope-check (which treats their
        /// reserved keys as in-scope).
        public var ridesInputJSON: Bool { kind == .number || kind == .string }

        /// The reserved guest input KEY this token binds from (`__numtok_<id>` for a number,
        /// `__strtok_<id>` for a string). Only meaningful for `ridesInputJSON` tokens.
        public var inputKey: String {
            kind == .string ? BodyLowering.stringTokenInputKey(id)
                            : BodyLowering.numericTokenInputKey(id)
        }
        public let id: String
        /// The token's native Swift source (`Theme.Colors.ink`, `Theme.Radius.lg`) —
        /// evaluated in the thunk's `__patchTokens()` over `self`.
        public let source: String
        public let kind: Kind
        public init(id: String, source: String, kind: Kind) {
            self.id = id; self.source = source; self.kind = kind
        }
    }

    /// The reserved guest input KEY a numeric design-system token binds from (the SDK
    /// merges the thunk-resolved value here, like a `__geo_*` input). Shared by the
    /// emitter (which emits the reference), the guest emitter (which binds it), and the
    /// scope-check (which treats it as in-scope) so they agree with no shared state.
    public static func numericTokenInputKey(_ id: String) -> String { "__numtok_" + id }

    /// The reserved guest input KEY a STRING design/host token binds from (the SDK merges
    /// the thunk-resolved String here, like `__numtok_<id>` for numbers). Shared by the
    /// emitter (which emits the reference), the guest emitter (which binds it), and the
    /// scope-check (which treats it as in-scope) so they agree with no shared state.
    public static func stringTokenInputKey(_ id: String) -> String { "__strtok_" + id }

    /// The reserved guest input KEY a PER-ROW INDEXED SLOT's row COUNT rides on. The
    /// build-time thunk natively evaluates the body-local collection and supplies its
    /// `.count` here; the SDK merges it into the guest's input JSON (like `__numtok_`),
    /// so the guest's `indexedForEachSlot` node can carry it and the host knows how many
    /// rows to reconstitute. Shared by the emitter, the guest emitter (which never needs
    /// to bind it — the count rides the NODE's `countKey`, read host-side), the thunk
    /// generator, and the SDK so they agree with no shared state.
    public static func rowCountInputKey(_ id: String) -> String { "__rowcount_" + id }

    /// A PER-ROW INDEXED NATIVE-ACTION SLOT — the lowering of a `ForEach` over a
    /// BODY-LOCAL collection the guest can't reconstruct, whose rows are a custom child
    /// view carrying a PER-ROW native action closure (`AccountChip(...) { schedule.
    /// selectedOwnerId = owner.id }`). The `self`-keyed `OpaqueLeaf` can't express "a
    /// different native subtree per row", so this carries the data the build-time thunk
    /// needs to natively rebuild each row:
    ///   * `collectionSource` — the ACCESSIBLE Swift expression for the collection
    ///     (`schedule.availableOwners`), evaluated natively in the thunk (over `self`).
    ///     A body-local alias (`let owners = schedule.availableOwners`) is resolved back
    ///     to its accessible initializer here.
    ///   * `loopVar` — the row closure's element name (`owner`), bound inside the per-row
    ///     factory to `<collection>[i]`.
    ///   * `rowSource` — the row VIEW expression verbatim (`AccountChip(...) { … }`), with
    ///     `loopVar` in scope; rendered natively per row.
    /// The thunk generates a factory `(Int) -> AnyView` keyed by `id`, plus supplies the
    /// row COUNT (`collectionSource.count`) under `rowCountInputKey(id)`. Both ids are
    /// content-stable (FNV of the structural seed), so the engine (push) and thunk
    /// generator (build) agree with no shared state — exactly like `OpaqueLeaf`. A slot is
    /// recorded ONLY when `collectionSource` + `rowSource` are guaranteed to compile in
    /// the cross-file thunk (no body-local besides `loopVar`, no inaccessible member); an
    /// unprovable shape stays a plain native slot instead (demote-safe).
    public struct IndexedRowSlot: Sendable, Equatable {
        public let id: String
        public let collectionSource: String
        public let loopVar: String
        public let rowSource: String
        /// The FULL original row-closure source (`{ AccountChip(id: $0.id) { … } }`),
        /// present ONLY for a `$0`-SHORTHAND row. When set, the thunk factory INVOKES
        /// the closure with the element (`AnyView((closure)(element))`) so Swift's own
        /// scoping resolves `$0` — and any genuinely-nested closure keeps its own `$0`
        /// untouched (no string/syntax rewrite of `$0` anywhere). nil for the named
        /// loop-var form (`{ owner in … }`), which keeps the `let owner = coll[i]` bind.
        public let rowClosureText: String?
        /// The reserved input key the row count rides (`__rowcount_<id>`).
        public var countKey: String { BodyLowering.rowCountInputKey(id) }
        public let label: String
        public init(id: String, collectionSource: String, loopVar: String,
                    rowSource: String, label: String, rowClosureText: String? = nil) {
            self.id = id; self.collectionSource = collectionSource
            self.loopVar = loopVar; self.rowSource = rowSource; self.label = label
            self.rowClosureText = rowClosureText
        }
    }

    /// A NATIVE-ACTION SLOT — the lowering of a `Button` inside an ACTIONS-LIST builder
    /// (`.swipeActions`/`.toolbar`/`.alert`/`Menu`/`.contextMenu`) whose action is a NATIVE
    /// method call (`deleteSubscription(subscription)`, `resetAllData()`) the guest can't
    /// dispatch. The Button's LABEL + `role` lower to a `actionSlotButton` node (OTA-patchable);
    /// the ACTION is supplied as a `() -> Void` slot closure the build-time thunk's
    /// `__patchActionSlots()` provides by `id` (closing over `self`, so the real native call runs
    /// faithfully). A slot is recorded ONLY when `source` (the action closure body, verbatim) is
    /// guaranteed to compile in the cross-file thunk — it references no body-local / no
    /// inaccessible (`private`) member (the SAME `isSlotable` check the opaque-leaf slot path
    /// uses). An un-slotable action keeps the view's `hasUndispatchableAction` demote (the dev's
    /// real native view renders) — never strips a body it can't fill. The id is content-stable
    /// (the same `act<hash>` id the dispatch path derives from the call slice), so the engine
    /// (push) and thunk generator (build) agree with no shared state — exactly like `OpaqueLeaf`.
    public struct ActionSlot: Sendable, Equatable {
        public let id: String
        /// The action closure BODY source (`{ deleteSubscription(subscription) }`'s inner
        /// statements) — emitted RAW in the thunk's `__patchActionSlots()` as `{ <source> }`,
        /// run over `self`. Folded into the native-shell fingerprint so editing this native
        /// action churns the hash (a native-shell change → MISMATCH) while a Button LABEL edit
        /// (which rides WASM) does not.
        public let source: String
        public let label: String
        public init(id: String, source: String, label: String) {
            self.id = id; self.source = source; self.label = label
        }
    }

    /// A NATIVE EFFECT-MODIFIER SLOT — the lowering of an undispatchable EFFECT modifier
    /// (`.task { await load() }`/`.onAppear`/`.refreshable`/`.onSubmit`/`.onTapGesture`/`.gesture`/
    /// `.onLongPressGesture`/`.onDisappear`) whose closure runs a NATIVE side-effect the guest
    /// can't re-run in WASM. Rather than DEMOTE the whole view (the old `hasUndispatchableEffect`
    /// behavior), the modified SUBTREE lowers to WASM normally and this slot keeps the EFFECT
    /// native: the modifier lowers to a `Modifier.nativeEffectSlot(id)`, and the build-time thunk's
    /// `__patchEffectSlots()` supplies a `(AnyView) -> AnyView` closure that applies the REAL
    /// modifier expression over `self` to its content. A slot is recorded ONLY when (a) the effect
    /// is FIDELITY-SAFE (fires on lifecycle/user-input, doesn't WATCH guest state — `.onChange`/
    /// `.onReceive` stay demoted — and contains no `withAnimation`/`.animation` through the
    /// guest-render boundary) and (b) `applySource` (the `content.<mod>(...)` re-application,
    /// verbatim) is guaranteed to compile in the cross-file thunk: it references no body-local /
    /// no inaccessible (`private`) member (the SAME `isSlotable` check the opaque-leaf / action-slot
    /// path uses). An un-slotable / unsafe effect keeps the view's `hasUndispatchableEffect` demote
    /// (the dev's real native view renders) — never strips a body whose effect it can't supply. The
    /// id is content-stable (the same `<prefix><hash>` id the effect's IR node derives from the call
    /// slice), so the engine (push) and thunk generator (build) agree with no shared state — exactly
    /// like `OpaqueLeaf`/`ActionSlot`.
    public struct EffectSlot: Sendable, Equatable {
        public let id: String
        /// The MODIFIER-APPLICATION source over a `content` placeholder — e.g.
        /// `content.task { await self.load() }`. The thunk's `__patchEffectSlots()` emits a
        /// closure `{ (content: AnyView) -> AnyView in AnyView(<applySource>) }`, run over `self`.
        /// Folded into the native-shell fingerprint so editing this native effect closure churns
        /// the hash (a native-shell change → MISMATCH) while editing the lowered body text does not.
        public let applySource: String
        public let label: String
        public init(id: String, applySource: String, label: String) {
            self.id = id; self.applySource = applySource; self.label = label
        }
    }

    /// A CHILD-VIEW CALLBACK SLOT: a custom child-view call with a `() -> Void` closure arg
    /// whose body is DISPATCHABLE (pure state mutations over guest-marshalled inputs, e.g.
    /// `showPaywall = true`). The SLOT holds:
    ///   • `id` — POSITION-KEYED (view-type + arg-label + occurrence-index via
    ///     `stableEventHash`), stable across closure-body edits (so it never MISMATCHes
    ///     on an OTA-delivered callback edit).
    ///   • `slotSource` — the COMPLETE child-view call expression, used as the native OPAQUE
    ///     SLOT closure the thunk's `__patchCallbackSlots()` emits as `{ AnyView(<slotSource>) }`.
    ///     Folded into the native-shell fingerprint under `CB:` so changing the NON-callback
    ///     args or the child-view type churns the hash (→ MISMATCH, correct: a native-shell change).
    ///     NOTE: the closure arg ITSELF is excluded from `slotSource` (replaced with a stable
    ///     forwarding closure `{ self.__patchDispatchCallback("<id>") }`) so editing the callback
    ///     body does NOT churn the fingerprint — it's OTA-patchable.
    ///   • `callbackBody` — the closure body statements (NOT the containing call) the WASM dispatch
    ///     sequence runs. Folded into `nativeSurface` as the DISPATCH BODY not the slot source,
    ///     so an edit to the callback body registers as a WASM change (fingerprint-stable; OTA).
    ///   • `label` — human-readable diagnostic string.
    public struct CallbackSlot: Sendable, Equatable {
        public let id: String
        /// The full child-view call with the closure arg replaced by the stable forwarding closure.
        /// This is emitted verbatim as the body of `__patchCallbackSlots()[id]`.
        public let slotSource: String
        /// The original closure body statements (the OTA-editable part). Folded into the guest
        /// dispatch table, NOT into `nativeSurface`. Editing this body = WASM-only change = OTA.
        public let callbackBody: String
        public let label: String
        public init(id: String, slotSource: String, callbackBody: String, label: String) {
            self.id = id; self.slotSource = slotSource
            self.callbackBody = callbackBody; self.label = label
        }
    }

    /// A field of a Codable struct element marshalled in as JSON. The guest
    /// reconstructs a mirroring `struct` of these fields, so a `ForEach` row /
    /// single-struct body reading `item.<name>`[`.<nested>`…] resolves.
    ///
    /// HISTORICAL NOTE: this was scalar-ONLY (`.string`/`.bool`/`.int`/`.double`);
    /// the RICH-INPUT widening (this pass) lets a field ALSO be a nested struct, a
    /// raw-value enum, a scalar array, an array of nested structs, or a `[String:…]`
    /// dictionary — every shape the guest can faithfully reconstruct from the SDK's
    /// recursive Mirror marshalling (`PatchValueEncoder`). The `shape` carries the
    /// full recursive descriptor; `kind` stays the SCALAR kind for a scalar field
    /// (every pre-existing consumer reads `kind` and only ever saw scalar fields, so
    /// for non-scalar fields `kind` is a harmless placeholder — those consumers are
    /// updated to switch on `shape`). A field whose type is NOT recursively
    /// reconstructable disqualifies the whole owning struct (it stays `.unsupported`
    /// → the view demotes natively, never a wrong/partial render).
    public struct StructField: Sendable, Equatable {
        public let name: String
        /// One of `.string`/`.bool`/`.int`/`.double` — a placeholder for non-scalar
        /// fields (read only by scalar-field consumers, which never see those).
        public let kind: ViewInput.Kind
        /// The recursive shape of this field (scalar / nested struct / enum / array /
        /// dictionary). For a scalar field this is `.scalar(kind)`.
        public let shape: FieldShape
        public init(name: String, kind: ViewInput.Kind) {
            self.name = name; self.kind = kind; self.shape = .scalar(kind)
        }
        public init(name: String, shape: FieldShape) {
            self.name = name; self.shape = shape
            // `kind` mirrors the scalar kind for a scalar field; for a non-scalar
            // shape it's a placeholder (`.string`) only legacy scalar-field code reads.
            if case let .scalar(k) = shape { self.kind = k } else { self.kind = .string }
        }
    }

    /// The recursive SHAPE of a struct field (or a top-level rich input). Every case
    /// is a value the GUEST can faithfully reconstruct from the SDK's Mirror JSON
    /// (`PatchValueEncoder`). `indirect` because a struct field can be another struct.
    public indirect enum FieldShape: Sendable, Equatable {
        /// A plain scalar field (`String`/`Bool`/`Int`/`Double`/`CGFloat`).
        case scalar(ViewInput.Kind)
        /// A NESTED struct field — its own (recursive) element descriptor. The guest
        /// generates a mirroring nested `_PatchRow_<Type>` + cuts the field's `{…}`
        /// object bytes and recurses. (`StructElement` carries the recursive fields.)
        case structValue(ViewInput.StructElement)
        /// A RAW-VALUE enum field — the guest generates a mirroring enum + decodes the
        /// `{"case":"…"}` marshalling.
        case enumValue(ViewInput.EnumElement)
        /// An array of a single SCALAR element (`[Int]`/`[String]`/`[Double]`/`[Bool]`).
        case scalarArray(ViewInput.Kind)
        /// An array of NESTED structs (`[SubStruct]`). The guest cuts the `[…]` body,
        /// splits it into element objects, and recurses per element.
        case structArray(ViewInput.StructElement)
        /// A `[String:Scalar]` dictionary — marshalled as a JSON object of scalar values.
        /// The guest decodes it into a `[String: T]` (a key list + per-key scalar scan).
        case scalarDictionary(ViewInput.Kind)
        /// A `[String:SubStruct]` dictionary — marshalled as a JSON object whose VALUES
        /// are nested struct objects (`PatchValueEncoder.encodeDictionary` emits a JSON
        /// object for String keys). The guest decodes it into a `[String: _PatchRow_<T>]`
        /// (the object's keys + per-key struct-builder over the cut value bytes). The
        /// element struct itself must qualify (recursively) — same gate as `.structArray`.
        case structDictionary(ViewInput.StructElement)
        /// An OPTIONAL SCALAR field (`String?`/`Int?`/`Bool?`/`Double?`/`CGFloat?`). The
        /// SDK marshals `.some(x)` as the bare scalar and `.none` as JSON `null` (or omits
        /// the key). The guest reconstructs a `T?`: missing key OR a `null` token → `nil`,
        /// else the scanned scalar. A body reading it must use it ONLY optionally
        /// (`field ?? default`, `field == nil`/`!= nil`) — gated demote-safe; a force-unwrap
        /// or a `.member` on the optional disqualifies (the guest can't prove unwrap-safety).
        case optionalScalar(ViewInput.Kind)
    }

    /// The classification of a `base.f1.f2…fn` member-access chain against a struct's
    /// recursive field shapes. Drives the demote-safe usage gates: a chain is guest-safe
    /// iff it resolves to a SCALAR leaf, OR to a whole collection (scalar/struct array,
    /// scalar dictionary) used only in a whole-value position (a `ForEach` / `.count` /
    /// `.isEmpty`) — anything else (an unknown field, a method call, a deeper access on a
    /// scalar) is `.unsafe` → the owning input demotes natively.
    public enum ChainResolution: Equatable {
        /// The chain resolves to a scalar leaf (`item.address.city`) — always safe.
        case scalarLeaf
        /// The chain resolves to a NON-scalar value (a nested struct, an array, a dict).
        /// Only the WHOLE-value positions the gate permits (a ForEach collection arg, a
        /// `.count`/`.isEmpty`) are safe; the chain itself is otherwise `.unsafe`.
        case collection(FieldShape)
        /// The chain references a nested STRUCT value whole (`item.address` passed
        /// somewhere) — not directly renderable; the gate rejects a bare use.
        case structWhole(ViewInput.StructElement)
        /// The chain resolves to an OPTIONAL SCALAR leaf (`item.subtitle`, type `String?`).
        /// Safe ONLY in an optional-use position (`?? default`, `== nil`/`!= nil`) — a bare
        /// read / force-unwrap / `.member` on it disqualifies (the gate checks `outer`).
        case optionalScalarLeaf
        /// The chain does NOT resolve through the field shapes → demote.
        case unsafe
    }

    /// Walk a member-access chain (`[f1, f2, …, fn]`, OUTERMOST-first as the source reads
    /// `base.f1.f2`) against a struct's recursive `fields`, returning what it resolves to.
    /// Each step looks the next field up in the current struct's fields; a step into a
    /// scalar that has MORE chain left is `.unsafe` (`item.score.foo`), a chain ending on
    /// a scalar is `.scalarLeaf`, ending on a nested struct is `.structWhole`, ending on an
    /// array/dictionary is `.collection`. An unknown field is `.unsafe`.
    public static func resolveFieldChain(_ chain: [String], fields: [StructField]) -> ChainResolution {
        guard let first = chain.first else { return .unsafe }
        guard let field = fields.first(where: { $0.name == first }) else { return .unsafe }
        let rest = Array(chain.dropFirst())
        switch field.shape {
        case .scalar:
            return rest.isEmpty ? .scalarLeaf : .unsafe   // a further `.x` on a scalar
        case .optionalScalar:
            // An optional scalar leaf: a trailing access on it (`.subtitle.count`) can't be
            // proven unwrap-safe → unsafe; a bare terminal read is `.optionalScalarLeaf`
            // (the gate then requires it sit in an optional-use position).
            return rest.isEmpty ? .optionalScalarLeaf : .unsafe
        case .structValue(let el):
            if rest.isEmpty { return .structWhole(el) }
            return resolveFieldChain(rest, fields: el.fields)   // recurse into nested struct
        case .enumValue:
            // A nested enum value: reading it whole isn't directly renderable here, and a
            // `.rawValue`/`== .case` use on a NESTED enum is not yet wired through the gate.
            return .unsafe
        case .scalarArray, .structArray, .scalarDictionary, .structDictionary:
            if rest.isEmpty { return .collection(field.shape) }
            // A trailing collection ACCESSOR that yields a scalar the body can render
            // (`tags.count`, `tags.isEmpty`) — only those, and only as the FINAL step.
            if rest.count == 1, Self.scalarCollectionAccessors.contains(rest[0]) {
                return .scalarLeaf
            }
            return .unsafe
        }
    }

    /// Collection accessors that yield a SCALAR the lowered body can render directly
    /// (so `coll.count` / `coll.isEmpty` are guest-safe terminal chain steps).
    static let scalarCollectionAccessors: Set<String> = ["count", "isEmpty"]

    /// A view's stored-property input crossing the WASM boundary. `name` is the
    /// property identifier the lowered body references; `kind` is the marshalled
    /// shape; `defaultLiteral` is the property's `= …` initializer (or a
    /// type-appropriate zero) used when the host sends no value for it.
    public struct ViewInput: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case string, bool, int, double
            /// Arrays of a single scalar element type — the guest CAN reconstruct
            /// these (it scans the JSON array into a `[T]`), so a body reading them
            /// renders the real value. The SDK marshals the real array IN.
            case stringArray, boolArray, intArray, doubleArray
            /// An array of a FLAT Codable struct (`[SomeStruct]`, all stored fields
            /// scalar/string). The guest CAN reconstruct these: the emitter generates a
            /// mirroring guest `struct` + a JSON array-of-objects scanner, so a
            /// `ForEach` row reading `item.<field>` resolves. The element's flat fields
            /// + the element type name ride in `structElement` (set on the input). The
            /// SDK marshals the real `[SomeStruct]` IN (recursive Mirror → array-of-objects).
            case structArray
            /// A SINGLE FLAT struct input (`let item: Product`, every stored field
            /// scalar/string — TASK 1). The guest reconstructs a mirroring `struct` (the
            /// SAME one the struct-ARRAY path generates) + a single JSON-OBJECT scanner,
            /// and binds `let item = _patchScan<Type>Row(blob, "item") ?? _PatchRow_<Type>()`,
            /// so a body reading `item.<flatField>` resolves in WASM. The element fields +
            /// type name ride in `structElement`. The SDK marshals the real struct IN
            /// (recursive Mirror → a nested JSON object under the input's key). This kind
            /// is only ASSIGNED after a whole-body usage check proves the body uses the
            /// input ONLY as `item.<flatField>` (a bare `item`, a method call, or a
            /// non-flat-field access keeps it `.unsupported` → the view demotes natively).
            case flatStruct
            /// A RAW-VALUE enum input (`let s: Status` where `enum Status: String/Int { … }`
            /// — TASK 2). The guest reconstructs a mirroring guest `enum` (raw-value
            /// initializable) + a scanner reading the SDK's `{"case":"…"}` marshalling, so a
            /// body reading `s == .case` / `s.rawValue` resolves in WASM. The cases + raw
            /// kind ride in `enumElement`. Only ASSIGNED after a whole-body usage check
            /// proves the body uses the input in a guest-reconstructable way (`== .case`,
            /// `switch`, `.rawValue`); any other use keeps it `.unsupported` (the view
            /// demotes natively).
            case enumValue
            /// A struct / enum / dictionary / custom value type. The SDK marshals
            /// the real value IN (recursive Mirror encode), but the Foundation-free
            /// guest can't reconstruct an arbitrary one without Codable — so a body
            /// that READS such an input DEMOTES to native (never a wrong default).
            case unsupported

            /// Whether the GUEST can faithfully reconstruct a value of this kind from
            /// the marshalled JSON (scalars + arrays-of-scalars + arrays-of-flat-struct).
            /// When false AND the body references the input, the view must stay native.
            public var guestReconstructable: Bool {
                switch self {
                case .string, .bool, .int, .double,
                     .stringArray, .boolArray, .intArray, .doubleArray, .structArray,
                     .flatStruct, .enumValue:
                    return true
                case .unsupported:
                    return false
                }
            }
        }
        public let name: String
        public let kind: Kind
        public let defaultLiteral: String
        /// For a `.structArray` or `.flatStruct` input: the element struct's type name +
        /// flat fields (so the guest emitter can generate the mirroring struct + scanner).
        /// `nil` for every other kind.
        public let structElement: StructElement?
        /// For an `.enumValue` input: the enum's type name, raw-value kind, and cases (so
        /// the guest emitter can generate a mirroring raw-value enum + a case scanner).
        /// `nil` for every other kind.
        public let enumElement: EnumElement?
        public init(name: String, kind: Kind, defaultLiteral: String,
                    structElement: StructElement? = nil,
                    enumElement: EnumElement? = nil) {
            self.name = name; self.kind = kind; self.defaultLiteral = defaultLiteral
            self.structElement = structElement
            self.enumElement = enumElement
        }

        /// The element descriptor for a `.structArray` / `.flatStruct` input.
        public struct StructElement: Sendable, Equatable {
            /// The element struct's source type name (`Player`) — used to derive a
            /// UNIQUE guest struct name (`_PatchRow_Player`) shared by every input of
            /// the same element type.
            public let typeName: String
            /// The element's flat scalar/string stored fields.
            public let fields: [StructField]
            public init(typeName: String, fields: [StructField]) {
                self.typeName = typeName; self.fields = fields
            }
        }

        /// The descriptor for an `.enumValue` input (TASK 2). A guest-reconstructable
        /// RAW-VALUE enum: every case name + its (declared or implicit) raw value, plus
        /// the raw-value kind. The guest emits a mirroring `enum _PatchEnum_<Type>:
        /// <Raw>` and decodes the SDK's `{"case":"<name>"}` marshalling by case NAME.
        public struct EnumElement: Sendable, Equatable {
            public enum RawKind: String, Sendable { case string, int }
            /// One case: its name + its EXPLICIT raw-value literal (the `= "x"` / `= 3`),
            /// or nil when implicit (the guest then uses Swift's implicit raw — for a
            /// String enum the case name, for an Int enum the running index).
            public struct Case: Sendable, Equatable {
                public let name: String
                public let rawLiteral: String?
                public init(name: String, rawLiteral: String?) {
                    self.name = name; self.rawLiteral = rawLiteral
                }
            }
            /// The enum's source type name (`Status`) → a unique guest enum name.
            public let typeName: String
            /// The raw-value kind (String or Int backing).
            public let rawKind: RawKind
            /// The cases in declaration order, with explicit raw values where present.
            public let cases: [Case]
            /// Convenience: the case names in declaration order.
            public var caseNames: [String] { cases.map(\.name) }
            public init(typeName: String, rawKind: RawKind, cases: [Case]) {
                self.typeName = typeName; self.rawKind = rawKind; self.cases = cases
            }
        }
    }

    /// Lower EVERY `View`-conforming struct in `source` to a guest body + report.
    /// This is the engine entry point: the BuildPipeline calls it for each source
    /// file, gets back one `LoweredView` per view, and emits a guest `view_body`
    /// module that builds the tree (the lowerable elements ride WASM; the rest are
    /// `.opaque` native-fallback slots, so a body never fails to lower).
    ///
    /// `sameFileThunk` controls the ACCESS-CONTROL contract with the generated thunk.
    /// `patchcli prepare` now emits each view's `@_dynamicReplacement(for: body)` thunk
    /// (and its `__patchSlots()`/`__patchTokens()` helpers) as an extension in the
    /// SAME FILE as the view (see `ThunkGenerator`), so the thunk can reach the view's
    /// own `private`/`fileprivate` members. With same-file thunks (the default), the
    /// emitter is therefore allowed to host-resolve (slot / token) a read of a private
    /// member — exactly what unblocks a view like SettingsScreen whose sole blocker is a
    /// `private @Environment` read in an alert-message interpolation. When `false`
    /// (the legacy SEPARATE-file thunk), private members stay inaccessible: a leaf/token
    /// that reads one is NOT lowerable, and the view stays native. Passing `false`
    /// reproduces the historical behavior exactly (demote-safe fallback).
    /// `crossFile*Catalog` carry PROJECT-WIDE type info the BuildPipeline collects from ALL
    /// source files (the lowering otherwise runs PER-FILE and can't see a param's type defined
    /// in another file — e.g. `AccentBadge(accent:)` in one file, `enum SpeechAccent` in
    /// Look up a SwiftUI view struct by name in `source`. Returns the `StructDeclSyntax`
    /// for the named view, or nil if not found. Used by tests to call per-struct static
    /// helpers (e.g. `closurePropNames`, `tuplePropertyNames`) without running the full
    /// lowering pipeline.
    static func findViewDecl(named name: String, in source: String) -> StructDeclSyntax? {
        let tree = Parser.parse(source: source)
        for stmt in tree.statements {
            guard let s = stmt.item.as(StructDeclSyntax.self),
                  s.name.text == name else { continue }
            return s
        }
        return nil
    }

    /// another). They are MERGED with the per-file catalogs (the per-file definition WINS on a
    /// name collision, so a same-file type is never shadowed). Empty by default → exact legacy
    /// per-file behavior (so existing single-file tests are unaffected).
    public func lowerAllViews(source: String, sameFileThunk: Bool = true,
                              crossFileStructCatalog: [String: [StructField]] = [:],
                              crossFileEnumCatalog: [String: ViewInput.EnumElement] = [:],
                              crossFileStringFieldCatalog: [String: [StructField]] = [:],
                              crossFileScalarFieldCatalog: [String: [String: ViewInput.Kind]] = [:],
                              crossFileCollectionFieldCatalog: [String: Set<String>] = [:],
                              crossFileReactiveCollectionShapeCatalog: [String: [StructField]] = [:],
                              crossFileComputedMemberCatalog: [String: [String: HostToken.Kind]] = [:],
                              crossFileObservableClassNames: Set<String> = [],
                              crossFileModelClassNames: Set<String> = []) -> [LoweredView] {
        let tree = Parser.parse(source: source)
        // Source-wide FLAT-struct catalog (type name → flat scalar/string fields). A
        // `[SomeStruct]` view input is `.structArray`-reconstructable only when its
        // element struct is in here (every stored field scalar — see `flatStructFields`).
        let structCatalog = Self.flatStructCatalog(in: tree)
            .merging(crossFileStructCatalog) { perFile, _ in perFile }
        // Source-wide RAW-VALUE-ENUM catalog (type name → element descriptor). A `let s:
        // Status` enum input is `.enumValue`-reconstructable only when `Status` is in here
        // (a `String`/`Int`-raw enum, every case a bare no-payload case — see `rawEnumCatalog`).
        let enumCatalog = Self.rawEnumCatalog(in: tree)
            .merging(crossFileEnumCatalog) { perFile, _ in perFile }
        // ALL-TYPES String-field catalog — for HOST-PROJECTION ONLY (never marshalling). Lets a
        // view host-project `param.stringField` (`page.title`) even when `param`'s type isn't
        // fully marshallable (it has a `Color`/`Image`/etc. field) — the #1 remaining lever (the
        // "custom view displaying a model's fields" pattern). Merged into the struct catalog ONLY
        // for `stringTypedMemberPaths`; the marshalling paths keep the strict `structCatalog`.
        let hostProjectStringCatalog = structCatalog.merging(
            Self.hostProjectableStringFieldCatalog(in: tree)
                .merging(crossFileStringFieldCatalog) { perFile, _ in perFile }) { existing, _ in existing }
        // REACTIVE-MEMBER host-projection catalogs: a view's reactive ref-type model's SCALAR
        // (Bool/Int/Double) and COLLECTION fields. Built per-file then merged with the project-
        // wide cross-file catalogs (per-file wins on a name collision, so a same-file type is
        // never shadowed) — the model class is usually in ANOTHER file. These let a free
        // `viewModel.isOn` / `viewModel.items.isEmpty` host-project (the thunk reads
        // `self.viewModel.<field>` natively → a numeric token) instead of leaking the base.
        let scalarFieldCatalog = Self.scalarFieldCatalog(in: tree)
            .merging(crossFileScalarFieldCatalog) { perFile, _ in perFile }
        let collectionFieldCatalog = Self.collectionFieldCatalog(in: tree)
            .merging(crossFileCollectionFieldCatalog) { perFile, _ in perFile }
        // COMPUTED-MEMBER-ON-INPUT host-projection catalog (the design-system `Size`-enum
        // idiom): a TYPE's computed scalar/Font members. A view's `<structEnumInput>.<member>`
        // read off one host-projects (the thunk re-evaluates `self.<input>.<member>` natively).
        // Merged with the CROSS-FILE catalog so a type defined in another file (e.g. an app-wide
        // `enum BadgeSize` in `Theme.swift`) is visible when the view is in `BadgeView.swift`.
        // Per-file wins on a name collision (a nested `enum Size` shadows a cross-file `Size`).
        let computedMemberCatalog = Self.computedScalarFontMemberCatalog(in: tree)
            .merging(crossFileComputedMemberCatalog) { perFile, _ in perFile }
        // REACTIVE-COLLECTION MARSHALLING catalogs. The shape catalog (type → marshallable array
        // fields) uses the merged `structCatalog` so a `[Player]` element defined cross-file
        // resolves. The String-ONLY catalog (per-file + cross-file, NOT the struct-merged
        // `hostProjectStringCatalog`) is the gate's set of host-projectable String reads — keeping
        // it String-only avoids over-permitting the gate with arbitrary struct fields.
        let reactiveCollectionShapeCat = Self.reactiveCollectionShapeCatalog(in: tree, structCatalog: structCatalog)
            .merging(crossFileReactiveCollectionShapeCatalog) { perFile, _ in perFile }
        let stringOnlyCatalog = Self.hostProjectableStringFieldCatalog(in: tree)
            .merging(crossFileStringFieldCatalog) { perFile, _ in perFile }
        // OBSERVABLE-STORED-PROP host-projection: `@Observable`-non-@Model class names visible
        // in this file. Per-file names (same-file decl) win; cross-file names fill in the rest.
        // A per-file name always supersedes a same-named cross-file entry (conservative: a
        // same-name class in another file could be a different @Observable — keep the one we
        // can see syntactically). The union is safe: the host-projection gate only produces
        // scalar/String tokens — it never marshals the object.
        let mergedObservableClassNames = Self.observableClassNames(in: tree)
            .union(crossFileObservableClassNames)
        // MODEL-PLAIN host-projection: `@Model`-annotated SwiftData class names visible in this
        // file or provided cross-file. Per-file names win. The gate (arm C in
        // `reactiveMemberTypesWithKind`) only projects SCALAR (Int/Bool/Double) fields of
        // NON-OPTIONAL @Model members — the @Model object never crosses to WASM.
        let mergedModelClassNames = Self.modelClassNames(in: tree)
            .union(crossFileModelClassNames)
        var out: [LoweredView] = []
        for view in allViews(in: tree) {
            guard let bodyExpr = bodyExpression(of: view.decl) else { continue }
            // Same-struct `some View`/`@ViewBuilder` helper members, inline-lowerable
            // into the parent body (TASK 2). A helper that takes args / is in another
            // type / isn't body-lowerable is NOT collected → its use-site still slots.
            let helpers = Self.inlinableHelpers(of: view.decl)
            // Detect single-struct (`.flatStruct`) and raw-enum (`.enumValue`) inputs, then
            // DEMOTE-SAFE GATE them: a `.flatStruct` input keeps its kind only if every
            // use (in the body AND in any inlinable helper the body can pull in) is
            // `input.<flatField>`; an `.enumValue` input only if every use is `== .case` /
            // `switch` / `.rawValue`. A failing input is downgraded to `.unsupported` so the
            // view demotes natively exactly as before (never a wrong/partial reconstruction).
            // The helper bodies MUST be scanned too: a collected helper is substituted INLINE
            // into the guest body (TASK 2), so a `s.title()` inside an inlined helper would
            // otherwise leak into the lowered tree and break the single guest compile unit.
            var inputs = Self.gateRichInputs(
                viewInputs(of: view.decl, structCatalog: structCatalog, enumCatalog: enumCatalog),
                bodyExpr: bodyExpr, helperBodies: Array(helpers.values))
            // REACTIVE-COLLECTION MARSHALLING: register a reactive member carrying a marshallable
            // collection (`@Observable`/`@ObservedObject`/… `vm` with `items: [Player]`) as a
            // `.flatStruct` input (its collection fields), so a `ForEach(vm.items)` lowers. The
            // gate already proved every `vm.*` use is a collection access or a host-projected
            // scalar/String. These REPLACE the `.unsupported` input the reactive member otherwise
            // became (so there's no duplicate name); appended AFTER `gateRichInputs` so they aren't
            // re-gated/downgraded (their scalar reads host-project, which `gateRichInputs` can't see).
            let reactiveInputs = Self.reactiveCollectionInputs(
                of: view.decl, collectionShapeCatalog: reactiveCollectionShapeCat,
                scalarFieldCatalog: scalarFieldCatalog, stringFieldCatalog: stringOnlyCatalog,
                bodyExpr: bodyExpr, helperBodies: Array(helpers.values))
            if !reactiveInputs.isEmpty {
                let names = Set(reactiveInputs.map(\.name))
                inputs = inputs.filter { !names.contains($0.name) } + reactiveInputs
            }
            var collector = Classifier()
            collector.helperBodies = helpers
            collector.classify(expr: bodyExpr)
            let report = LoweringReport(viewName: view.name, elements: collector.elements)
            var emitter = Emitter()
            // ACCESS CONTROL × THUNK PLACEMENT. With a SAME-FILE thunk (the default —
            // `patchcli prepare` appends the `@_dynamicReplacement(for: body)` extension
            // and its `__patchSlots()`/`__patchTokens()` to the view's own file), the
            // thunk CAN reference the view's `private`/`fileprivate` members, so NONE are
            // inaccessible — a leaf/token reading a private member is fully lowerable. With
            // the legacy SEPARATE-file thunk, Swift's file-scoped private hides those
            // members from the extension, so a leaf/token reading one is NOT slotable
            // (it would not compile: `'$x' is inaccessible due to 'private'`) → the read
            // forces the view native.
            emitter.inaccessibleNames = sameFileThunk
                ? [] : Self.inaccessibleMemberNames(of: view.decl)
            // The view's own members — so an `if let <selfProp>` shadow doesn't make a
            // self-member reference in another leaf look like a blocking body-local.
            emitter.selfMemberNames = Self.allMemberNames(of: view.decl)
            // The scalar-array inputs the guest CAN reconstruct (B's `_patchScan*Array`
            // bindings expose them as bound `[T]`s). A `ForEach` over one of these
            // emits a REAL guest loop binding the loop var; a `ForEach` over anything
            // else demotes to a native slot (never an unbound loop var that fails the
            // whole-module compile).
            emitter.scalarArrayInputNames = Self.scalarArrayInputNames(inputs)
            // The marshalled SCALAR input names (string/bool/int/double) — the guest
            // binds each as a `let`, so a numeric expression over them resolves WITHOUT
            // a design-system token. (Drives `numericOrToken`'s "resolvable as written"
            // decision so only genuinely-out-of-scope numeric constants become tokens.)
            emitter.marshalledInputNames = Set(inputs.filter {
                switch $0.kind {
                case .string, .bool, .int, .double: return true
                default: return false
                }
            }.map(\.name))
            // The struct-array inputs (`[SomeStruct]`) the guest reconstructs via a
            // mirroring struct + array-of-objects scanner. A `ForEach`/`List(items)`
            // over one emits a real guest loop binding `item` (its fields resolve
            // against the guest struct); over anything else it demotes (TASK 1).
            emitter.structArrayInputElements = Self.structArrayInputElements(inputs)
            // The SINGLE flat-struct inputs (`let item: Product`, TASK 1) — bound as a
            // `let item = _patchScan<Type>Row(blob,"item") ?? _PatchRow_<Type>()`, so a
            // body reading `item.<flatField>` resolves. The whole-body usage gate
            // (`gateRichInputs`) already proved every use is `item.<flatField>`.
            emitter.flatStructInputElements = Self.flatStructInputElements(inputs)
            // The RAW-VALUE enum inputs (`let s: Status`, TASK 2) — bound to a mirroring
            // guest enum via a case scanner over the SDK's `{"case":"…"}` marshalling, so
            // `s == .case` / `switch s` / `s.rawValue` resolve. The usage gate already
            // proved the body uses the input only in a guest-reconstructable way.
            emitter.enumInputElements = Self.enumInputElements(inputs)
            // Computed SCALAR properties of the view (G42): a get-only
            // `var x: Bool/String/Int/Double/CGFloat { … }`. A bare reference to one in a
            // host-resolvable position is host-projected via the thunk's `__patchTokens()`
            // (it evaluates `self.x` natively → a String/Double the SDK merges into the
            // input JSON) instead of leaking a free identifier. With a SAME-FILE thunk a
            // PRIVATE computed property is reachable too (the thunk calls `self.<name>`);
            // with the legacy separate-file thunk only accessible ones qualify.
            emitter.computedScalarProps =
                Self.computedScalarProperties(of: view.decl, includingPrivate: sameFileThunk)
            // PROVABLY-TYPED color/font property names (the type-safety gate for a BARE
            // IDENTIFIER token): a stored/computed `let/var name: Color` / `: Font` of the
            // view. Without this proof, a bare identifier in a color/font modifier slot
            // (`.background(backgroundView)` where `backgroundView` is `some View`) would be
            // mis-recorded as a `.color` token, and the thunk's `.color(backgroundView)`
            // would NOT compile. With it, only a provably-`Color`/`Font` bare name admits a
            // token; an unknown bare name native-slots instead (build-safe = demote-safe).
            let (colorNames, fontNames) = Self.colorFontTypedMemberNames(of: view.decl)
            emitter.colorTypedNames = colorNames
            emitter.fontTypedNames = fontNames
            // PROVABLY-NUMERIC member names (the numeric-token analogue): a stored/computed
            // `let/var name: Int/Double/CGFloat/Float`. A bare identifier admits a `.number`
            // token only if it's here; an unknown bare name slots (so `.number(Double(<name>))`
            // can never be `Double(<non-numeric>)`).
            emitter.numericTypedNames = Self.numericTypedMemberNames(of: view.decl)
            emitter.collectionTypedNames = Self.collectionTypedMemberNames(of: view.decl)
            // PROVABLY-STRING member-access PATHS (`profile.name`): a stored/`@State` struct
            // property whose catalog type has a `String` scalar field. The type-PROOF for
            // admitting a BARE MEMBER-ACCESS string token — without it the engine can't tell
            // `Text(profile.name)` (String) from `Text(feature.description)` (AttributedString),
            // and a `.string(self.feature.description)` thunk wouldn't compile. Only String
            // scalar leaves are emitted; an unknown/non-String/optional member stays rejected
            // (the caller slots the Text node / demotes the view). Build-safe = demote-safe.
            emitter.stringTypedMemberPaths = Self.stringTypedMemberPaths(of: view.decl, catalog: hostProjectStringCatalog)
            // REACTIVE-MEMBER host-projection: a SCALAR/Bool read off a reactive ref-type member
            // (`viewModel.isOn`) → a numeric (Bool-as-Double) token; a collection field's
            // `.isEmpty`/`.count` (`viewModel.items.isEmpty`) → a numeric count token. The thunk
            // reads `self.<base>.<field>` natively (the base is a self property → it compiles).
            // Build-safe = demote-safe: only a PROVABLY-scalar single-hop read / a provably-
            // collection guard projects; everything else keeps the native demote.
            // PRIVATE-COMPUTED-MEMBER numeric host-projection (same-file-thunk only): a read of
            // `foo.count` (Int) or `foo.isReady` (Bool) where `foo` is a COMPUTED property
            // (`private var foo: Foo { … }`, type-annotated) whose return type is cataloged.
            // The thunk evaluates `self.foo.count` natively → a __numtok_ the SDK merges into
            // the guest input JSON (the same mechanism as reactive-member scalar projection).
            // Gated on `sameFileThunk`: a separate-file thunk can't call `private` members.
            // Only scalar (Int/Double/CGFloat/Bool) fields cross — never the whole object.
            var reactivePaths =
                Self.reactiveMemberScalarPaths(of: view.decl, scalarFieldCatalog: scalarFieldCatalog,
                                               observableClassNames: mergedObservableClassNames,
                                               modelClassNames: mergedModelClassNames)
            if sameFileThunk {
                let computedPaths = Self.privateComputedMemberScalarPaths(
                    of: view.decl, scalarFieldCatalog: scalarFieldCatalog)
                reactivePaths.merge(computedPaths) { existing, _ in existing }
            }
            emitter.reactiveMemberScalarPaths = reactivePaths
            emitter.reactiveMemberCollectionPaths =
                Self.reactiveMemberCollectionPaths(of: view.decl, collectionFieldCatalog: collectionFieldCatalog,
                                                   observableClassNames: mergedObservableClassNames)
            // COMPUTED-MEMBER-ON-INPUT host-projection: `<structEnumInput>.<computedScalar/Font>`
            // (`size.iconSize` where `size: Size` is an enum param and `Size.iconSize` is a
            // computed `CGFloat`) → a number/string/font token. The thunk re-evaluates
            // `self.<input>.<member>` natively (the input is a self stored property, the member
            // a public computed property of its type → it compiles). Build-safe = demote-safe:
            // only a PROVABLY-scalar/Font computed single-hop read projects.
            emitter.inputComputedMemberPaths =
                Self.inputComputedMemberPaths(of: view.decl, memberCatalog: computedMemberCatalog)
            // The NON-SCALAR struct/enum INPUT param names — the demote-safety gate so the
            // design-system numeric-token path never mis-projects a NON-`.number` member off a
            // struct/enum input (`.padding(size.insets)` where `size.insets: EdgeInsets`).
            // CRITICAL: only genuine struct/enum inputs belong here. A SCALAR input
            // (`grid: Bool`, `label: String`, `count: Int`) is guest-resolvable/marshalled —
            // referencing it in a numeric token (`grid ? Theme.Radius.md : Theme.Radius.pill`)
            // resolves natively over `self` and MUST be allowed. Including scalars here wrongly
            // gated those legitimate tokens (the ternary-radius regression).
            emitter.structEnumInputBases = Set(
                Self.inputDeclaredTypeNames(of: view.decl)
                    .filter { !Self.scalarInputTypeNames.contains($0.value) }
                    .keys)
            // Same-struct inline-lowerable helpers (TASK 2).
            emitter.helperBodies = helpers
            // Encode any PLAIN non-ASCII string literal in the emitted body as an explicit
            // UTF-8 byte form (`String(decoding:[..],as:UTF8.self)`) so a Japanese/emoji/
            // accented `Text("…")` rides WASM byte-exact regardless of the guest toolchain's
            // non-ASCII string-literal codegen (some toolchains small-string-inline a
            // multi-byte literal wrong → silent native demote). ASCII bodies are returned
            // verbatim (fast path → byte-identical, zero fingerprint churn). Done BEFORE the
            // scope check / content hash below so every consumer sees the shipped form.
            let guestBody = GuestNonASCIIEncoder.encode(emitter.emit(expr: bodyExpr))
            // The emitter collected a mutation rule for every interactive control /
            // recognizable tap it lowered (event id = the control's event id, so the
            // rules match the tree exactly). Pair them with the scalar fields they
            // mutate to form the state model — when non-empty, the guest emitter ALSO
            // ships a `dispatch` export running the UPDATE logic in WASM.
            let (stateModel, droppedDeadActionRule) = Self.buildStateModel(rules: emitter.mutationRules, inputs: inputs)
            // Does the LOWERED body read an input the guest can't reconstruct (a
            // struct/enum/dictionary/custom value)? Scan the EMITTED guest body — a
            // reference inside an `.opaque` leaf is just the label string (rendered
            // natively from `self`, so it's safe), only a live identifier reference
            // in the lowered tree binds a wrong default. If so, the view must stay
            // native (BuildPipeline gates `thunkSafe` on this).
            // CLOSURE-PROP SLOT: subtract stored closure-typed props (`let onTap: () -> Void`)
            // from the unmarshalled-names set BEFORE checking whether the body references them.
            // A closure prop CAN'T be marshalled to WASM (no JSON representation for a function),
            // but each CALL SITE in the body (`Button("X") { onTap() }`) is handled natively by
            // the emitter's existing opaqueExprLifted / actionSlot path — so the closure never
            // leaks as a live WASM identifier. Subtracting here ONLY promotes views that were
            // previously demoting because of a closure prop; views without closure props are
            // unaffected (the subtraction is a no-op on an empty set). DEMOTE-SAFE: if the
            // emitter CAN'T slot a closure-prop call site (e.g. a body-local alias) it falls
            // back to opaqueExprLifted (whole-view scope-check remains unchanged).
            let closureProps = Self.closurePropNames(of: view.decl)
            var unmarshalledNames = Set(inputs.filter { !$0.kind.guestReconstructable }.map(\.name))
            unmarshalledNames.subtract(closureProps)
            let referencesUnmarshalled = !unmarshalledNames.isEmpty
                && Self.guestBodyReferencesAny(guestBody, names: unmarshalledNames)
            // DEMOTE-SAFETY GUARD: scope-check the emitted guest body for FREE
            // identifiers the guest can't resolve (a computed property, a dropped
            // body-local `let`, a design-system static in a numeric position, a
            // Foundation type in an input default). Such a reference compiles to
            // `cannot find 'X' in scope` and — because every view export shares ONE
            // wrapper file — demotes the WHOLE module to zero views. We exclude just
            // this view so the others still ship (the #1 real-app blocker). The
            // marshalled INPUT names are exactly those the guest emitter binds (every
            // reconstructable kind; an `.unsupported` input is never bound, but a body
            // that reads one is already caught by `referencesUnmarshalled` above and
            // excluded — so treating it as out-of-scope here is consistent).
            let boundInputs = inputs.filter { $0.kind.guestReconstructable }
            var boundInputNames = Set(boundInputs.map(\.name))
            // DESIGN-SYSTEM NUMERIC / STRING TOKENS the emitter recorded bind as reserved
            // `__numtok_<id>` / `__strtok_<id>` inputs in the guest (the SDK injects the
            // resolved value), so they are IN SCOPE — add them before the scope-check or it
            // would flag the `Double(__numtok_<id>)` / `__strtok_<id>` reference the token
            // lowering emits.
            boundInputNames.formUnion(
                emitter.hostTokens.filter { $0.ridesInputJSON }.map { $0.inputKey })
            // Scope-check the bound inputs' DEFAULT LITERALS too: the guest emitter
            // bakes them in verbatim (`?? <default>`), so a Foundation type / free
            // symbol in a default (`Locale.current.region?…`) is the same scope error
            // as one in the body. (An `.unsupported` input read is already excluded via
            // `referencesUnmarshalledInput`, so we only check the ones actually bound.)
            let scopeResult = SwiftUIGuestScopeCheck.check(
                guestBody: guestBody, inputNames: boundInputNames,
                usesGeometry: emitter.usesGeometry,
                inputDefaultLiterals: boundInputs.map(\.defaultLiteral))
            // PRECISE-DIAGNOSTIC (the "inaccessible-member wall"): of the symbols that
            // BLOCK this view (an unmarshalled input the lowered tree reads, or a free
            // symbol the scope check couldn't resolve), which are the view's OWN
            // `private`/`fileprivate` members? With a SEPARATE-file thunk those reads can
            // only be host-resolved (a slot/token closure) but CAN'T be — Swift's
            // file-scoped private hides the member from the extension — so naming them
            // lets the EXCLUDE diagnostic report the real architectural limit
            // (cross-file thunk × private member) instead of the generic
            // "non-reconstructable input". With a SAME-FILE thunk that wall does NOT
            // exist (the thunk reaches private members), so a private read no longer
            // blocks; the field stays empty (any residual block has a DIFFERENT cause —
            // a body-local `let`, a genuinely non-reconstructable value). Diagnostic-only:
            // it never changes what ships.
            let inaccessible = sameFileThunk ? [] : Self.inaccessibleMemberNames(of: view.decl)
            let blockingSymbols = unmarshalledNames.union(Set(scopeResult.unresolved))
            let inaccessibleReads = inaccessible.intersection(blockingSymbols)
                .filter { Self.guestBodyReferencesAny(guestBody, names: [$0]) }
                .sorted()
            // DIAGNOSTIC (never changes what ships): the precise non-reconstructable
            // inputs the body actually reads — the actionable "why didn't this lower"
            // answer — and the SwiftData subset (the modern-app blocker).
            let blockingReads = unmarshalledNames
                .filter { Self.guestBodyReferencesAny(guestBody, names: [$0]) }
                .sorted()
            let swiftDataNames = Self.swiftDataPropertyNames(of: view.decl)
            let swiftDataBlockers = blockingReads.filter { swiftDataNames.contains($0) }
            // DIAGNOSTIC (never changes what ships): blocking reads that are TUPLE-typed
            // stored properties. Tuples aren't Codable, so a named Codable struct would
            // unblock them — surfaced as an actionable fix-hint in the demote diagnostic.
            let tupleNames = Self.tuplePropertyNames(of: view.decl)
            let tupleBlockingNames = blockingReads.filter { tupleNames.contains($0) }
            // STRUCTURALLY-STATIC DETECTION: a view's WASM-emitted tree is provably
            // identical across ALL inputs iff:
            //   1. No input-riding host token (numeric/string __numtok_/__strtok_) is
            //      present — those values are merged into the input JSON and vary per
            //      instance, so the WASM body would read different values per call.
            //   2. No bound (guest-reconstructable) input name appears in the guest body
            //      in a LIVE position (a reference inside an `.opaque` label is safe —
            //      the classifier skips those strings). When there are NO reconstructable
            //      inputs, the tree trivially doesn't reference any of them.
            //   3. No GeometryReader (usesGeometry): the reserved `__geo_*` inputs are
            //      injected per-layout and change the tree structure (child sizes differ).
            //   4. No interactive state model (stateModel?.isInteractive == true): the
            //      dispatch export re-emits the tree with new state → the tree changes
            //      per interaction even if the INITIAL tree is input-independent.
            // Conservative: false ⟹ always-WASM (the safe prior behavior).
            let hasInputRidingTokens = emitter.hostTokens.contains { $0.ridesInputJSON }
            let reconstructableNames = Set(inputs.filter { $0.kind.guestReconstructable }.map(\.name))
            let treeReferencesInputs = !reconstructableNames.isEmpty
                && Self.guestBodyReferencesAny(guestBody, names: reconstructableNames)
            let isStructurallyStatic = !hasInputRidingTokens
                && !treeReferencesInputs
                && !emitter.usesGeometry
                && stateModel?.isInteractive != true
            out.append(LoweredView(viewName: view.name, report: report,
                                   guestBody: guestBody, inputs: inputs,
                                   stateModel: stateModel,
                                   opaqueLeaves: emitter.opaqueLeaves,
                                   hostTokens: emitter.hostTokens,
                                   indexedRowSlots: emitter.indexedRowSlots,
                                   actionSlots: emitter.actionSlots,
                                   effectSlots: emitter.effectSlots,
                                   callbackSlots: emitter.callbackSlots,
                                   referencesUnmarshalledInput: referencesUnmarshalled,
                                   referencesUnresolvedSymbol: !scopeResult.isCompilable,
                                   unresolvedSymbols: scopeResult.unresolved,
                                   inaccessibleReadNames: inaccessibleReads,
                                   blockingReadNames: blockingReads,
                                   swiftDataBlockers: swiftDataBlockers,
                                   tupleBlockingNames: tupleBlockingNames,
                                   usesGeometry: emitter.usesGeometry,
                                   hasUndispatchableAction: emitter.hasUndispatchableAction || droppedDeadActionRule,
                                   hasUndispatchableEffect: emitter.hasUndispatchableEffect,
                                   usesReactiveMarshalling: !reactiveInputs.isEmpty,
                                   usesAnimationValue: emitter.usesAnimationValue,
                                   isStructurallyStatic: isStructurallyStatic))
        }
        return out
    }

    /// Whether the emitted guest-body expression contains a live identifier
    /// reference to ANY of `names`. Parses `guestBody` as a Swift expression and
    /// looks for a `DeclReferenceExpr` (or the base of a member access like
    /// `user.name`) whose identifier is in the set. Input names that appear only
    /// inside an `N.opaque(…, label: "…")` STRING LITERAL don't match (those render
    /// natively from `self`), so this fires only when a wrong default would ship.
    static func guestBodyReferencesAny(_ guestBody: String, names: Set<String>) -> Bool {
        guard !names.isEmpty else { return false }
        // Wrap in a trivial decl so the builder expression parses as an expression.
        let wrapped = "let __patch_probe = \(guestBody)"
        let tree = Parser.parse(source: wrapped)
        let scanner = GuestBodyNameRefScanner(names)
        scanner.walk(tree)
        return scanner.found
    }

    /// The identifier names a Swift EXPRESSION source references in a way that could resolve
    /// to a `self`-member: every FREE identifier (`profile` in `profile.name`), every
    /// `self.X` member name (`X`), and every `$x` property-wrapper projection. Used by the
    /// HYBRID thunk-placement decision to detect whether a slot/token/row-slot source reads
    /// one of the view's own `private`/`fileprivate` members — in which case that view's
    /// helper methods must stay same-file (Swift access control is file-scoped). A safe
    /// OVER-approximation: it never MISSES a real `self`-member read (so it can't wrongly
    /// route a private-reading view to a separate file), at the cost of occasionally naming
    /// an identifier that happens to match — which only keeps a view same-file needlessly
    /// (build-safe). Returns the bare names AND the `$`-prefixed projections it saw.
    static func identifierReferences(in source: String) -> Set<String> {
        // Parse as an expression by binding it (the row-closure/token sources are
        // expressions). A parse failure yields the empty set (we then fall back to the
        // engine diagnostic in the caller).
        let tree = Parser.parse(source: "let __patch_probe = {\n\(source)\n}")
        let scanner = SelfMemberRefScanner()
        scanner.walk(tree)
        return scanner.names
    }

    /// Build the interactive state model from the emitter's collected mutation rules.
    /// Keeps only rules whose mutated field is a known SCALAR input of a kind the
    /// mutation expects (so the generated `update` always type-checks); the model's
    /// fields are exactly those participating scalar `@State` properties. A rule that
    /// references a non-scalar/unknown field is dropped (that interaction stays native).
    /// Returns the state model AND `droppedDeadRule` — true iff a recorded mutation rule was
    /// dropped here for a KIND MISMATCH or a MISSING field (NOT a benign de-dup). The emitter
    /// already emitted a LIVE `N.button(actionID:)`/effect node for every recorded rule, so a
    /// rule dropped here = a control that renders + is tappable but does NOTHING on device
    /// (the #7/#9 dead-control class: e.g. `@State var x: Double = 0; Button{ x += 1 }` records
    /// `.incInt` from the int-literal RHS, then this kind-check drops it because `x` is `.double`).
    /// The caller ORs this into `hasUndispatchableAction` so the view DEMOTES to native (where the
    /// control works) instead of shipping the dead control — restoring build-safe = demote-safe.
    static func buildStateModel(rules: [MutationRule], inputs: [ViewInput]) -> (model: StateModel?, droppedDeadRule: Bool) {
        guard !rules.isEmpty else { return (nil, false) }
        // A view may LEGALLY shadow a name (e.g. a `static let foo` and a `@State var foo`),
        // so `inputs` can carry duplicate names. `Dictionary(uniqueKeysWithValues:)` TRAPS on
        // a duplicate key — a runtime crash inside lowering that, unlike a demote, has NO
        // backstop and aborts the whole app's module build (seen on real apps: exyte-Chat
        // `maxSelectionRowWidth`, NetNewsWire `model`). De-dupe keeping the FIRST occurrence;
        // a mutation rule that then resolves to the wrong shadowed field just fails its
        // kind-check below and is dropped (that interaction stays native — demote-safe).
        let byName = Dictionary(inputs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var keptRules: [MutationRule] = []
        var fieldNames = Set<String>()
        var droppedDeadRule = false
        for rule in rules {
            // MISSING field (non-scalar/unknown) — the emitter emitted a live node for this
            // recorded rule, so dropping it leaves a DEAD control → flag for demote.
            guard let input = byName[rule.field] else { droppedDeadRule = true; continue }
            // The field kind must match the op (a setBool needs a Bool field, etc.).
            let ok: Bool
            switch rule.op {
            case .setBool, .toggleBool, .assignBoolLiteral: ok = (input.kind == .bool)
            case .setIntClamped, .incInt, .decInt, .assignIntLiteral: ok = (input.kind == .int)
            case .setDoubleClamped: ok = (input.kind == .double)
            case .setString: ok = (input.kind == .string)
            }
            // KIND MISMATCH (e.g. `.incInt`/`.assignIntLiteral` from an int-literal RHS on a
            // Double/CGFloat/Optional field) — same dead-control hazard → flag for demote.
            guard ok else { droppedDeadRule = true; continue }
            // De-dup identical (event,field) pairs (a control + its own onChange). This is a
            // BENIGN drop (the event is still handled by the kept rule) — NOT a dead control.
            if keptRules.contains(where: { $0.eventID == rule.eventID }) { continue }
            keptRules.append(rule)
            fieldNames.insert(rule.field)
        }
        guard !keptRules.isEmpty else { return (nil, droppedDeadRule) }
        let fields = inputs.filter { fieldNames.contains($0.name) }
        let model = StateModel(fields: fields, rules: keptRules)
        return (model.isInteractive ? model : nil, droppedDeadRule)
    }

    /// Extract the view's stored-property INPUTS (the `let`/`var` values the body
    /// marshals in). Computed properties (`body`, any `{ get }`) are skipped — they
    /// are structure, not inputs. A SwiftUI property-wrapper attribute (`@State`,
    /// `@Binding`, …) is stripped; the underlying value name + type is what the body
    /// references. Only scalar/string-typed inputs marshal; others bind to their
    /// literal default so the guest still compiles.
    func viewInputs(of s: StructDeclSyntax,
                    structCatalog: [String: [StructField]] = [:],
                    enumCatalog: [String: ViewInput.EnumElement] = [:]) -> [ViewInput] {
        var out: [ViewInput] = []
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in v.bindings {
                let name = binding.pattern.trimmedDescription
                if name == "body" { continue }
                // Skip computed properties (an accessor block that is a getter).
                if binding.accessorBlock != nil { continue }
                let typeText = binding.typeAnnotation?.type.trimmedDescription
                let defaultExpr = binding.initializer?.value.trimmedDescription
                // An array-of-FLAT-struct (`[SomeStruct]`) the guest can reconstruct
                // (TASK 1): classify it as `.structArray` with the element descriptor,
                // so a `ForEach(items)` over it lowers to a real loop. A `[SomeStruct]`
                // whose element ISN'T a known flat struct stays `.unsupported`.
                if let typeText, let element = Self.structArrayElement(typeText, catalog: structCatalog) {
                    out.append(ViewInput(name: name, kind: .structArray, defaultLiteral: "[]",
                                         structElement: element))
                    continue
                }
                // A SINGLE FLAT-struct input (`let item: Product`, TASK 1): the element
                // type is a FLAT struct in the catalog. Marked `.flatStruct` PROVISIONALLY
                // — `gateRichInputs` downgrades it to `.unsupported` unless the body uses
                // it only as `item.<flatField>` (so the guest reconstruction can compile).
                if let typeText, let element = Self.flatStructInput(typeText, catalog: structCatalog) {
                    out.append(ViewInput(name: name, kind: .flatStruct, defaultLiteral: "",
                                         structElement: element))
                    continue
                }
                // A RAW-VALUE enum input (`let s: Status`, TASK 2): the type is a String/Int
                // raw-value enum in the enum catalog. Marked `.enumValue` PROVISIONALLY —
                // `gateRichInputs` downgrades it unless the body uses it only in a guest-
                // reconstructable way (`== .case` / `switch` / `.rawValue`).
                if let typeText, let element = Self.enumInput(typeText, catalog: enumCatalog) {
                    out.append(ViewInput(name: name, kind: .enumValue, defaultLiteral: "",
                                         enumElement: element))
                    continue
                }
                let kind = Self.inputKind(typeAnnotation: typeText, defaultExpr: defaultExpr)
                let defLiteral = Self.defaultLiteral(kind: kind, declared: defaultExpr)
                out.append(ViewInput(name: name, kind: kind, defaultLiteral: defLiteral))
            }
        }
        return out
    }

    /// If `type` is a SIMPLE type name (`Product`, NOT `[Product]`/`Product?`/a generic)
    /// that is a FLAT struct in `catalog`, the element descriptor for a `.flatStruct`
    /// input (TASK 1); else nil. (An Optional `Product?` keeps `.unsupported` — the guest
    /// would need to handle `null`/unwrap, which `gateRichInputs` can't prove safe.)
    static func flatStructInput(_ type: String,
                                catalog: [String: [StructField]]) -> ViewInput.StructElement? {
        let t = type.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              let fields = catalog[t], !fields.isEmpty else { return nil }
        return ViewInput.StructElement(typeName: t, fields: fields)
    }

    /// If `type` is a SIMPLE type name that is a RAW-VALUE enum in `catalog`, the element
    /// descriptor for an `.enumValue` input (TASK 2); else nil. (Optional/generic keeps
    /// `.unsupported`.)
    static func enumInput(_ type: String,
                          catalog: [String: ViewInput.EnumElement]) -> ViewInput.EnumElement? {
        let t = type.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return catalog[t]
    }

    /// If `type` is `[SomeStruct]`/`Array<SomeStruct>` and `SomeStruct` is a FLAT
    /// struct in `catalog` (every stored field scalar/string), the element descriptor
    /// (type name + fields) for a `.structArray` input; else nil. (A scalar element
    /// type like `[Int]` is handled by `arrayElementKind`, not here.)
    static func structArrayElement(_ type: String,
                                   catalog: [String: [StructField]]) -> ViewInput.StructElement? {
        let t = type.trimmingCharacters(in: .whitespaces)
        let element: String?
        if t.hasPrefix("["), t.hasSuffix("]") {
            element = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        } else if t.hasPrefix("Array<"), t.hasSuffix(">") {
            element = String(t.dropFirst("Array<".count).dropLast()).trimmingCharacters(in: .whitespaces)
        } else {
            element = nil
        }
        // The element must be a simple type name (not a nested generic / dictionary).
        guard let e = element, !e.isEmpty,
              e.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              let fields = catalog[e], !fields.isEmpty else { return nil }
        return ViewInput.StructElement(typeName: e, fields: fields)
    }

    /// The view's `private`/`fileprivate` member names (vars/lets/funcs), each plus
    /// its `$`-projected form (`x` → `x`, `$x`). A mixed-view slot closure — emitted
    /// into a SEPARATE file — can't reference these, so a leaf that does is not
    /// slotable. (Access-control on extensions is per-file: `private`/`fileprivate`
    /// members are invisible to an extension in another file.)
    /// ALL of a view's OWN member names (stored + computed properties, methods, and their
    /// `$`-projected forms), regardless of access level. Used to keep a self-member
    /// reference in a slot closure from being misclassified as a blocking body-local when
    /// an `if let <selfProp>` shadow elsewhere in the body pollutes `bodyLocals`.
    static func allMemberNames(of s: StructDeclSyntax) -> Set<String> {
        var out = Set<String>()
        for member in s.memberBlock.members {
            if let v = member.decl.as(VariableDeclSyntax.self) {
                for b in v.bindings {
                    let name = b.pattern.trimmedDescription
                    guard !name.isEmpty, !name.contains("(") else { continue }
                    out.insert(name); out.insert("$" + name)
                }
            } else if let f = member.decl.as(FunctionDeclSyntax.self) {
                out.insert(f.name.text)
            }
        }
        return out
    }

    static func inaccessibleMemberNames(of s: StructDeclSyntax) -> Set<String> {
        var out = Set<String>()
        func isInaccessible(_ modifiers: DeclModifierListSyntax) -> Bool {
            modifiers.contains { $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate) }
        }
        for member in s.memberBlock.members {
            if let v = member.decl.as(VariableDeclSyntax.self), isInaccessible(v.modifiers) {
                for b in v.bindings {
                    let name = b.pattern.trimmedDescription
                    guard !name.isEmpty else { continue }
                    out.insert(name); out.insert("$" + name)
                }
            } else if let f = member.decl.as(FunctionDeclSyntax.self), isInaccessible(f.modifiers) {
                out.insert(f.name.text)
            }
        }
        return out
    }

    /// Collect the view's COMPUTED SCALAR properties (G42): an ACCESSIBLE (not
    /// `private`/`fileprivate`) get-only `var name: Bool/String/Int/Double/CGFloat { … }`
    /// → its scalar kind. These are NOT view inputs (computed, so skipped by `viewInputs`)
    /// but a bare reference to one can be HOST-PROJECTED — the cross-file thunk's
    /// `__patchTokens()` evaluates `self.<name>` natively (it can, since the property is
    /// accessible) → a String/Double the SDK merges into the guest input JSON. `body` is
    /// excluded (it's `some View`, not a scalar). A property returning `some View` (a
    /// helper) or a non-scalar type is excluded. A `private`/`fileprivate` one is excluded
    /// (the cross-file thunk extension can't call it).
    static func computedScalarProperties(of s: StructDeclSyntax,
                                         includingPrivate: Bool = false) -> [String: ViewInput.Kind] {
        var out: [String: ViewInput.Kind] = [:]
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            // Skip static members always. Skip `private`/`fileprivate` members only when
            // the thunk is SEPARATE-file (it can't call `self.<name>`); with a same-file
            // thunk (`includingPrivate`) a private computed property IS reachable.
            if v.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) { continue }
            if !includingPrivate, v.modifiers.contains(where: {
                $0.name.tokenKind == .keyword(.private)
                    || $0.name.tokenKind == .keyword(.fileprivate)
            }) { continue }
            for binding in v.bindings {
                let name = binding.pattern.trimmedDescription
                guard name != "body", !name.isEmpty else { continue }
                // Must be a COMPUTED property (a getter accessor block), not stored.
                guard binding.accessorBlock != nil else { continue }
                guard let typeText = binding.typeAnnotation?.type.trimmedDescription else { continue }
                let kind: ViewInput.Kind?
                switch typeText {
                case "String": kind = .string
                case "Bool": kind = .bool
                case "Int": kind = .int
                case "Double", "CGFloat": kind = .double
                default: kind = nil
                }
                if let k = kind { out[name] = k }
            }
        }
        return out
    }

    /// Collect the view's member names whose declared type is PROVABLY `Color` or `Font`
    /// (a stored or computed `let/var name: Color` / `: Font`). Returns (colorNames,
    /// fontNames). This is the type-PROOF for admitting a BARE-IDENTIFIER color/font token:
    /// without it, the engine can't tell `.background(c)` where `let c: Color` from
    /// `.background(v)` where `var v: some View` — both are a bare identifier — and would
    /// wrongly emit `.color(v)` (a View isn't a Color). A bare identifier admits a token
    /// ONLY when it's in the kind-appropriate set; an unknown bare name native-slots.
    ///
    /// Both stored (`let c: Color`) and computed (`var c: Color { … }`) members count — the
    /// thunk evaluates `self.<name>`, which is a `Color`/`Font` either way. Accessibility
    /// (private/fileprivate) is NOT filtered here: a same-file thunk can reach a private
    /// member, and the separate-file inaccessibility is already enforced by the recorder's
    /// `inaccessibleNames` slotability scan. Static members are excluded (a bare reference
    /// to a static needs a type qualifier — it'd be a member access, not a bare identifier).
    /// An optional `Color?`/`Font?` annotation also counts (a force-unwrap/`??` of it is
    /// still color/font-typed). `Optional<Color>`-style spelled types are matched too.
    static func colorFontTypedMemberNames(of s: StructDeclSyntax) -> (color: Set<String>, font: Set<String>) {
        var colorNames = Set<String>()
        var fontNames = Set<String>()
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            if v.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) { continue }
            for binding in v.bindings {
                let name = binding.pattern.trimmedDescription
                guard !name.isEmpty, name != "body" else { continue }
                guard let typeText = binding.typeAnnotation?.type.trimmedDescription else { continue }
                // BUG #5: an OPTIONAL `Color?`/`Font?` must NOT be admitted as a bare-identifier
                // token — the thunk emits `.color(<name>)` / `.font(<name>)` whose argument is a
                // non-optional `Color`/`Font`, so `.color(Color?)` fails to compile. A bare
                // optional read slots/demotes (faithful); a `?? default` use is non-bare.
                if Self.isOptionalTypeSpelling(typeText) { continue }
                switch Self.normalizedColorFontType(typeText) {
                case .color: colorNames.insert(name)
                case .font: fontNames.insert(name)
                case .none: break
                }
            }
        }
        return (colorNames, fontNames)
    }

    /// Collect the view's member names whose declared type is PROVABLY a NUMERIC scalar
    /// (`Int`/`Double`/`CGFloat`/`Float`, optionally `Optional`-wrapped/module-qualified) —
    /// stored OR computed. The type-PROOF for admitting a BARE-IDENTIFIER `.number` token:
    /// the thunk emits `.number(Double(<name>))`, which compiles only if `<name>` is numeric.
    /// Static members are excluded (a bare reference to one needs a type qualifier).
    static func numericTypedMemberNames(of s: StructDeclSyntax) -> Set<String> {
        var out = Set<String>()
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            if v.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) { continue }
            for binding in v.bindings {
                let name = binding.pattern.trimmedDescription
                guard !name.isEmpty, name != "body" else { continue }
                guard let typeText = binding.typeAnnotation?.type.trimmedDescription else { continue }
                // BUG #31: an OPTIONAL numeric (`Int?`/`CGFloat?`) must NOT be admitted as a
                // bare-identifier token — the thunk emits `.number(Double(<name>))`, and
                // `Double(Int?)` doesn't compile. A `?? default`/force-unwrap use is a non-bare
                // expression handled elsewhere; a BARE optional read slots/demotes (safe).
                if Self.isOptionalTypeSpelling(typeText) { continue }
                if Self.isNumericScalarType(typeText) { out.insert(name) }
            }
        }
        return out
    }

    // MARK: - @Observable class name catalog

    /// The set of class names (simple identifiers) in `tree` that are annotated with `@Observable`
    /// but NOT with `@Model`. This is the allowlist for the `observableStoredProp` host-projection
    /// lever (arm A and arm B of `reactiveMemberTypesWithKind`).
    ///
    /// SAFETY: `@Model` classes are explicitly excluded — SwiftData's reference-type, ObjC-backed
    /// model objects can't be host-projected through the value boundary (no thunk can safely read
    /// `self.item.field` when `item: @Model` may be un-inserted or faulted). A class with BOTH
    /// `@Observable` and `@Model` stays excluded (a corner case, but safe).
    static func observableClassNames(in tree: SourceFileSyntax) -> Set<String> {
        let collector = ObservableClassCollector(viewMode: .sourceAccurate)
        collector.walk(tree)
        return collector.names
    }

    /// PROJECT-WIDE observable class names across all `sources` (a type declared in 2+ files is
    /// dropped — ambiguous, conservative). Fed into `CrossFileBundle.observableClassNames` so the
    /// `observableStoredProp` host-projection resolves cross-file `@Observable` view-models.
    static func crossFileObservableClassNames(sources: [String]) -> Set<String> {
        let ambiguous = Self.crossFileAmbiguousTypeNames(sources: sources)
        var seen = Set<String>()
        var multi = Set<String>()
        var result = Set<String>()
        for src in sources {
            let tree = Parser.parse(source: src)
            for name in observableClassNames(in: tree) {
                if ambiguous.contains(name) { continue }
                if !seen.insert(name).inserted { multi.insert(name) }
                else { result.insert(name) }
            }
        }
        // Drop names seen in 2+ files.
        result.subtract(multi)
        return result
    }

    /// The set of class names (simple identifiers) in `tree` that are annotated with `@Model`
    /// (SwiftData). These are the @Model classes whose SCALAR (Int/Bool/Double) fields can be
    /// host-projected via the `modelPlain` arm of `reactiveMemberTypesWithKind` — the @Model
    /// host-projection lever (ARM C). A name collision (two `@Model` classes with the same name
    /// in one file) drops the entry — ambiguous, conservative.
    ///
    /// Note: the `@Observable` annotation on a @Model class does NOT disqualify it here (it's
    /// legitimate for a @Model to also be @Observable). The lever's SAFETY is enforced elsewhere:
    /// the member must be NON-OPTIONAL and single-hop scalar (the `scalarFieldCatalog` gate).
    static func modelClassNames(in tree: SourceFileSyntax) -> Set<String> {
        let collector = ModelClassCollector(viewMode: .sourceAccurate)
        collector.walk(tree)
        return collector.names
    }

    /// PROJECT-WIDE @Model class names across all `sources` (a type declared in 2+ files is
    /// dropped — ambiguous, conservative). Fed into `CrossFileBundle.modelClassNames` so the
    /// `modelPlain` host-projection resolves cross-file `@Model` types (the SwiftData model is
    /// almost always in a separate file from the view that displays it).
    static func crossFileModelClassNames(sources: [String]) -> Set<String> {
        let ambiguous = Self.crossFileAmbiguousTypeNames(sources: sources)
        var seen = Set<String>()
        var multi = Set<String>()
        var result = Set<String>()
        for src in sources {
            let tree = Parser.parse(source: src)
            for name in modelClassNames(in: tree) {
                if ambiguous.contains(name) { continue }
                if !seen.insert(name).inserted { multi.insert(name) }
                else { result.insert(name) }
            }
        }
        result.subtract(multi)
        return result
    }

    /// REACTIVE REFERENCE-TYPE member names of a view — `@ObservedObject` / `@StateObject` /
    /// `@EnvironmentObject` / `@Environment(SomeType.self)` (the iOS-17 Observation injection
    /// form) → the property's declared/injected TYPE name (nil if not a plain identifier).
    /// These are the view-model / service properties the guest can't reconstruct, but the
    /// build-time thunk CAN read natively (`self.viewModel.<field>`) — so a SCALAR/Bool field
    /// read off one host-projects (see `reactiveMemberScalarPaths` / `reactiveMemberCollectionPaths`)
    /// instead of leaking the base identifier and demoting the whole view.
    static func reactiveMemberTypes(of s: StructDeclSyntax,
                                    observableClassNames: Set<String> = [],
                                    modelClassNames: Set<String> = []) -> [String: String] {
        Self.reactiveMemberTypesWithKind(of: s, observableClassNames: observableClassNames,
                                         modelClassNames: modelClassNames).mapValues { $0.typeName }
    }

    /// Which property-wrapper holds a reactive member. Drives the bug-#8 safe-surface gate:
    /// only `.held` wrappers (`@ObservedObject`/`@StateObject`) hold their object directly, so the
    /// SDK can EAGERLY marshal them without risking an uncatchable `wrappedValue` trap; `.environment`
    /// wrappers (`@EnvironmentObject`/`@Environment(T.self)`) read the object out of the environment
    /// and trap when it's absent, so the engine must NOT register them as a marshalled collection
    /// input (the `ForEach` native-demotes). HOST-PROJECTION off either kind stays fine — the thunk
    /// reads `self.<base>.<field>` natively during body eval, where the environment is installed.
    /// `.observablePlain` is a plain stored `let/var` or `@Bindable var` whose declared type is an
    /// `@Observable` (non-`@Model`) class — it is HOST-PROJECTION ONLY, like `.environment`, and
    /// is explicitly excluded from the `.held` marshalling gate in `reactiveCollectionInputs`.
    /// `.modelPlain` is a plain stored `let item: Item` or `@Bindable var item: Item` whose
    /// declared type is a `@Model` class — HOST-PROJECTION ONLY for scalar (Int/Bool/Double)
    /// fields. The `@Model` object itself NEVER crosses to WASM (not marshalled). The thunk
    /// reads `self.item.<scalarField>` natively during `__patchTokens()` — identical to what
    /// the view's body does — so it is render-correct iff (a) the member is NON-OPTIONAL (we
    /// check the top-level type annotation, not the field), (b) the field is a SINGLE-HOP
    /// scalar (no relationship traversal), and (c) it is a STORED attribute (no modelContext
    /// access). Optional `@Model` members are left `.unsupported` (a nil dereference in
    /// `__patchTokens()` would crash the thunk). String fields route through the EXISTING
    /// `stringTypedMemberPaths` channel (AnyClassDeclCollector already covers `@Model` classes)
    /// so they need no special treatment here.
    enum ReactiveWrapperKind: Equatable { case held, environment, observablePlain, modelPlain }

    /// REACTIVE REFERENCE-TYPE members of a view → (type name, wrapper kind). See
    /// `reactiveMemberTypes` for the type-resolution rules; `kind` records whether the wrapper
    /// HOLDS its object (`@ObservedObject`/`@StateObject`) or reads it from the ENVIRONMENT
    /// (`@EnvironmentObject`/`@Environment(T.self)`), or is a PLAIN stored `@Observable` /
    /// `@Bindable`-non-@Model property (`.observablePlain`).
    ///
    /// The `observableClassNames` set (from `observableClassNames(in:)` + cross-file) names
    /// the `@Observable`-annotated (non-`@Model`) classes visible to this view's file. Used to
    /// recognise TWO arms:
    ///   (A) A plain STORED property (`let vm: MyVM` / `var vm: MyVM`) with no reactive wrapper
    ///       whose declared type is in `observableClassNames` — this is the idiomatic iOS-17
    ///       `@Observable` pattern where the view is a SIMPLE STRUCT that doesn't embed an
    ///       `@ObservedObject`/`@StateObject` wrapper (it relies on the `@Observable` macro's
    ///       own observation infrastructure). These properties CAN'T be marshalled (they are
    ///       reference types), but their SCALAR/String fields CAN be host-projected exactly like
    ///       `@ObservedObject` members (the thunk reads `self.vm.field` natively).
    ///   (B) A `@Bindable var x: SomeVM` whose declared type is in `observableClassNames` —
    ///       a non-@Model bindable observable. `@Bindable` wrapping an `@Observable` non-@Model
    ///       class makes its properties bindable; the object itself still can't be marshalled,
    ///       but scalar/String fields host-project exactly as in (A).
    ///
    /// The `modelClassNames` set (from `modelClassNames(in:)` + cross-file) names the
    /// `@Model`-annotated SwiftData classes. Used for ARM (C):
    ///   (C) A NON-OPTIONAL plain stored property (`let item: Item`) or `@Bindable var item:
    ///       Item` whose declared TYPE is in `modelClassNames` — host-projection only for
    ///       SCALAR fields (Int/Bool/Double/CGFloat). The @Model object NEVER enters WASM.
    ///       The thunk's `__patchTokens()` reads `self.item.<scalarField>` natively during
    ///       the view's body evaluation — exactly as the body itself does — so the read is
    ///       render-correct when: (a) the member is non-Optional (checked here: the top-level
    ///       type annotation must NOT end in `?` or `!`), (b) the field is a single-hop stored
    ///       scalar in `scalarFieldCatalog` (NOT a relationship traversal, NOT a computed
    ///       modelContext access — those disqualify because `scalarFieldCatalog` only records
    ///       stored scalar/getter non-private fields), and (c) the model context is live (it
    ///       always is during SwiftUI body evaluation). String fields on @Model classes are NOT
    ///       added here: they already host-project via `stringTypedMemberPaths`
    ///       (AnyClassDeclCollector already covers all class types including @Model).
    ///
    /// IRON SAFETY (retained): `@Model` members with an Optional top-level annotation
    /// (`var item: Item?`) are EXCLUDED from ARM (C) — cleanedTypeName strips `?`/`!` but we
    /// add an explicit Optional guard before invoking it (a nil dereference in `__patchTokens()`
    /// would crash the thunk; demoting is correct over crashing). The `.modelPlain` kind is
    /// excluded from the `.held` marshalling gate in `reactiveCollectionInputs` so no @Model
    /// object ever enters the SDK's eager `extract` path.
    static func reactiveMemberTypesWithKind(
        of s: StructDeclSyntax,
        observableClassNames: Set<String> = [],
        modelClassNames: Set<String> = []
    ) -> [String: (typeName: String, kind: ReactiveWrapperKind)] {
        var out: [String: (typeName: String, kind: ReactiveWrapperKind)] = [:]
        func cleanedTypeName(_ raw: String) -> String? {
            var t = raw.trimmingCharacters(in: .whitespaces)
            while t.hasSuffix("?") || t.hasSuffix("!") { t = String(t.dropLast()) }
            if let dot = t.lastIndex(of: ".") { t = String(t[t.index(after: dot)...]) }
            return (!t.isEmpty && t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }) ? t : nil
        }
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            var injectedType: String? = nil   // `@Environment(T.self)` → T
            var isReactive = false
            var kind: ReactiveWrapperKind = .held
            var isBindable = false
            for attr in v.attributes {
                guard let a = attr.as(AttributeSyntax.self) else { continue }
                let n = a.attributeName.trimmedDescription
                if n == "ObservedObject" || n == "StateObject" {
                    isReactive = true; kind = .held
                }
                if n == "EnvironmentObject" {
                    isReactive = true; kind = .environment
                }
                if n == "Environment", let args = a.arguments?.trimmedDescription, args.hasSuffix(".self") {
                    // `@Environment(MyService.self)` — a reactive (`@Observable`) injection;
                    // a `\.keyPath` value-environment is NOT (no `.self`), so it's excluded.
                    isReactive = true; kind = .environment
                    injectedType = cleanedTypeName(String(args.dropLast(".self".count)))
                }
                if n == "Bindable" { isBindable = true }
            }
            if isReactive {
                for binding in v.bindings {
                    let name = binding.pattern.trimmedDescription
                    guard !name.isEmpty else { continue }
                    if let t = injectedType { out[name] = (t, kind); continue }
                    if let typeText = binding.typeAnnotation?.type.trimmedDescription,
                       let t = cleanedTypeName(typeText) {
                        out[name] = (t, kind)
                    } else if let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
                              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                        // `@StateObject var vm = SomeVM()` — type inferred from the initializer.
                        out[name] = (callee.baseName.text, kind)
                    }
                }
                continue
            }
            // ARM (A): plain stored `let/var` with no reactive wrapper, whose declared type
            // is a known `@Observable` (non-@Model) class — host-projection only.
            // ARM (B): `@Bindable var` whose declared type is a known `@Observable` non-@Model
            // class — also host-projection only. `@Bindable` on an @Model stays blocked because
            // `observableClassNames` excludes `@Model`-annotated classes.
            // ARM (C): plain stored `let item: Item` or `@Bindable var item: Item` whose type is
            // a known `@Model` class — host-projection of SCALAR fields only (see docstring).
            // Check ARM (C) first (before the observableClassNames guard which would `continue`
            // past @Model members with an empty observableClassNames set).
            // Skip computed properties — they aren't stored inputs.
            let hasAccessor = v.bindings.contains { $0.accessorBlock != nil }
            guard !hasAccessor else { continue }
            // Only STORED properties (no accessor) with an explicit type annotation.
            for binding in v.bindings {
                guard binding.accessorBlock == nil else { continue }
                let name = binding.pattern.trimmedDescription
                guard !name.isEmpty, name != "body" else { continue }
                guard let rawTypeText = binding.typeAnnotation?.type.trimmedDescription else { continue }
                // RENDER-CORRECTNESS SAFETY: reject Optional top-level type annotation for @Model.
                // `cleanedTypeName` strips `?`/`!` but would still return a name — an Optional
                // @Model property (`var item: Item?`) could be nil when `__patchTokens()` runs,
                // crashing the thunk. Explicitly exclude before attempting @Model arm (C).
                let isTopLevelOptional = rawTypeText.hasSuffix("?") || rawTypeText.hasSuffix("!")
                guard let typeName = cleanedTypeName(rawTypeText) else { continue }
                // If this name is already mapped (e.g. by a reactive-wrapper arm above), skip.
                guard out[name] == nil else { continue }
                // ARM (C): @Model stored/bindable member — host-project scalar fields only.
                if !isTopLevelOptional && !modelClassNames.isEmpty && modelClassNames.contains(typeName) {
                    out[name] = (typeName, .modelPlain)
                    continue
                }
                // ARM (A)/(B): @Observable non-@Model member.
                if observableClassNames.contains(typeName) {
                    out[name] = (typeName, .observablePlain)
                }
            }
        }
        return out
    }

    /// HOST-PROJECTABLE single-hop SCALAR/Bool reads off a view's REACTIVE reference-type
    /// members: `reactiveBase.scalarField` (Bool/Int/Double/CGFloat/Float) → its scalar kind.
    /// The reactive base's type is resolved via `reactiveMemberTypes`, its field's type via the
    /// project-wide `scalarFieldCatalog` (struct/class/enum stored + literal-inferred fields).
    /// String fields are NOT here (`stringTypedMemberPaths` already host-projects `Text(vm.title)`
    /// via the string-token channel — this is the numeric/Bool complement). The thunk evaluates
    /// `self.<base>.<field>` natively → a numeric token (Bool carried as 1.0/0.0). Only a
    /// PROVABLY-scalar single-hop read qualifies — a nested chain / Optional / object field is
    /// excluded (it stays a native demote). Returns `path → kind`.
    ///
    /// (Reactive-member host-projection INCLUDES `@EnvironmentObject`/`@Environment(T.self)`:
    /// unlike the eager `extract` marshalling path — which the #8 gate restricts to held wrappers
    /// because it reads `wrappedValue` outside body-eval — these tokens are evaluated by the
    /// thunk's `__patchTokens()` DURING body rendering, where SwiftUI has installed the
    /// environment object, so `self.<envMember>.<field>` is as safe as the native body's own read.
    /// A reverted over-cautious exclusion would have demoted every env-driven guard.)

    static func reactiveMemberScalarPaths(of s: StructDeclSyntax,
                                          scalarFieldCatalog: [String: [String: ViewInput.Kind]],
                                          observableClassNames: Set<String> = [],
                                          modelClassNames: Set<String> = []) -> [String: ViewInput.Kind] {
        var out: [String: ViewInput.Kind] = [:]
        for (base, typeName) in Self.reactiveMemberTypes(of: s, observableClassNames: observableClassNames,
                                                         modelClassNames: modelClassNames) {
            guard let fields = scalarFieldCatalog[typeName] else { continue }
            for (field, kind) in fields {
                switch kind {
                case .bool, .int, .double:
                    out["\(base).\(field)"] = kind
                default:
                    break   // String routes through stringTypedMemberPaths; others demote
                }
            }
        }
        return out
    }

    /// HOST-PROJECTABLE scalar-field reads off a view's PRIVATE COMPUTED PROPERTIES
    /// (same-file-thunk only). A computed property `private var foo: Foo { … }` with an
    /// explicit type annotation naming a type `Foo` in `scalarFieldCatalog` contributes
    /// paths `foo.<field>` for every Bool/Int/Double scalar field of `Foo`. The thunk
    /// evaluates `self.foo.<field>` natively → a __numtok_ the SDK merges into the guest
    /// input JSON. String fields are NOT included here — `stringTypedMemberPaths` already
    /// covers them via the string-token channel (it doesn't filter `private` or computed).
    ///
    /// IRON SAFETY: ONLY the resolved scalar (Int/Double/CGFloat/Bool) value crosses to
    /// WASM as a `__numtok_` token. The receiver object is NEVER marshalled. A non-scalar
    /// field, a whole-object read, or a non-annotated/Optional computed property → demotes
    /// (unchanged). Cross-file behaviour is UNCHANGED — callers gate on `sameFileThunk`.
    static func privateComputedMemberScalarPaths(of s: StructDeclSyntax,
                                                 scalarFieldCatalog: [String: [String: ViewInput.Kind]]) -> [String: ViewInput.Kind] {
        var out: [String: ViewInput.Kind] = [:]
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            // Skip static members — a bare `foo.field` needs foo to be a self property.
            if v.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) { continue }
            for binding in v.bindings {
                let baseName = binding.pattern.trimmedDescription
                guard !baseName.isEmpty, baseName != "body" else { continue }
                // Must be COMPUTED (accessor block present), not stored.
                guard binding.accessorBlock != nil else { continue }
                // Must have an EXPLICIT type annotation naming a simple (non-generic,
                // non-optional, non-collection) type that appears in the scalar catalog.
                guard let typeText = binding.typeAnnotation?.type.trimmedDescription else { continue }
                var t = typeText.trimmingCharacters(in: .whitespaces)
                // Reject Optional/IUO and collection spellings — an Optional receiver
                // makes `self.foo.field` potentially crash at thunk-eval time.
                if t.hasSuffix("?") || t.hasSuffix("!") { continue }
                if t.hasPrefix("[") || t.hasPrefix("Array<") || t.hasPrefix("Set<")
                    || t.hasPrefix("Dictionary<") { continue }
                // Strip module qualifier (e.g. `MyModule.Foo` → `Foo`).
                if let dot = t.lastIndex(of: ".") { t = String(t[t.index(after: dot)...]) }
                guard !t.isEmpty, t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
                guard let fields = scalarFieldCatalog[t] else { continue }
                for (field, kind) in fields {
                    switch kind {
                    case .bool, .int, .double:
                        out["\(baseName).\(field)"] = kind
                    default:
                        break   // String routes through stringTypedMemberPaths
                    }
                }
            }
        }
        return out
    }

    /// HOST-PROJECTABLE collection-guard reads off a view's REACTIVE reference-type members:
    /// the member-access PATH `reactiveBase.collectionField` whose field is a collection
    /// (`[…]`/`Array`/`Set`/`Dictionary`). Its `.isEmpty`/`.count` host-projects (the v1.6.5
    /// collection-guard mechanism, extended through a reactive member): the thunk evaluates
    /// `(self.<base>.<field>).count` natively → a numeric token. The WHOLE collection is NOT
    /// marshalled (a `ForEach(vm.items)` still demotes — only the count/empty guard projects).
    static func reactiveMemberCollectionPaths(of s: StructDeclSyntax,
                                              collectionFieldCatalog: [String: Set<String>],
                                              observableClassNames: Set<String> = []) -> Set<String> {
        var out = Set<String>()
        for (base, typeName) in Self.reactiveMemberTypes(of: s, observableClassNames: observableClassNames) {
            guard let fields = collectionFieldCatalog[typeName] else { continue }
            for field in fields { out.insert("\(base).\(field)") }
        }
        return out
    }

    /// Project-wide SCALAR-field catalog for HOST-PROJECTION off reactive members (never
    /// marshalling): type name → (field name → scalar kind), over ALL struct/class/enum decls.
    /// A field's kind comes from its explicit annotation (`var n: Int`), else a literal
    /// initializer inference (`= false` → bool, `= 0` → int, `= 0.0` → double — the common
    /// `@Published var showActivityIndicator = false` shape). An Optional / non-scalar / un-
    /// annotated-non-literal field is OMITTED (a read of it demotes, faithful). Computed
    /// scalar getters (`var isReady: Bool { … }`) are INCLUDED (the thunk reads `self.x.isReady`
    /// → the getter runs natively). A `private`/`fileprivate`/`static` field is excluded (the
    /// cross-file thunk can't reach it).
    static func scalarFieldCatalog(in tree: SourceFileSyntax) -> [String: [String: ViewInput.Kind]] {
        var out: [String: [String: ViewInput.Kind]] = [:]
        func scalarKind(of typeText: String) -> ViewInput.Kind? {
            var t = typeText.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("?") || t.hasSuffix("!") { return nil }   // optional disqualifies
            if let dot = t.lastIndex(of: ".") { t = String(t[t.index(after: dot)...]) }
            switch t {
            case "Bool": return .bool
            case "Int": return .int
            case "Double", "CGFloat", "Float": return .double
            default: return nil
            }
        }
        func litKind(of expr: ExprSyntax) -> ViewInput.Kind? {
            if expr.is(BooleanLiteralExprSyntax.self) { return .bool }
            if expr.is(IntegerLiteralExprSyntax.self) { return .int }
            if expr.is(FloatLiteralExprSyntax.self) { return .double }
            return nil
        }
        func collect(_ name: String, _ members: MemberBlockItemListSyntax) {
            var fields = out[name] ?? [:]
            for member in members {
                guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
                if v.modifiers.contains(where: {
                    $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
                    // `private(set)`/`fileprivate(set)` carry the scope in `.detail` and leave the
                    // GETTER at default access, so the cross-file thunk + SDK Mirror CAN read them.
                    // Exclude `private`/`fileprivate` only when there's no `(set)` detail.
                    || ($0.detail == nil
                        && ($0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)))
                }) { continue }
                for b in v.bindings {
                    let fname = b.pattern.trimmedDescription
                    guard !fname.isEmpty, fname != "body", fields[fname] == nil else { continue }
                    if let t = b.typeAnnotation?.type.trimmedDescription, let k = scalarKind(of: t) {
                        fields[fname] = k
                    } else if b.accessorBlock == nil, b.typeAnnotation == nil,
                              let initVal = b.initializer?.value, let k = litKind(of: initVal) {
                        fields[fname] = k   // inferred from the literal initializer
                    }
                }
            }
            if !fields.isEmpty { out[name] = fields }
        }
        let structDecls = StructEnumDeclCollector(viewMode: .sourceAccurate); structDecls.walk(tree)
        let classDecls = AnyClassDeclCollector(viewMode: .sourceAccurate); classDecls.walk(tree)
        let enumDecls = AnyEnumDeclCollector(viewMode: .sourceAccurate); enumDecls.walk(tree)
        // A simple name produced by 2+ of {struct, class, enum} collectors is a WITHIN-FILE
        // same-name collision. The per-collector dedup only catches a duplicate WITHIN its own
        // kind, and `collect`'s `out[name] ?? [:]` would UNION a struct's fields with a same-name
        // class's (or enum's) — host-projecting a `.number(Double(self.x.count))` for a `count`
        // that exists only on the OTHER same-name type → an uncompilable app build. Poison
        // (drop) any name declared by 2+ kinds before merging, so a read of it demotes (faithful).
        let crossKindCollision = Self.crossKindCollidingNames(structNames: structDecls.structDecls.keys,
                                                              classNames: classDecls.classes.keys,
                                                              enumNames: enumDecls.enums.keys)
        for (n, d) in structDecls.structDecls where !crossKindCollision.contains(n) { collect(n, d.memberBlock.members) }
        for (n, d) in classDecls.classes where !crossKindCollision.contains(n) { collect(n, d.memberBlock.members) }
        for (n, d) in enumDecls.enums where !crossKindCollision.contains(n) { collect(n, d.memberBlock.members) }
        return out
    }

    /// The set of simple type names declared by 2+ of the three decl-kind collectors
    /// (struct / class / enum) WITHIN one file. Each collector already drops a duplicate
    /// WITHIN its own kind, so a name that survives in two collectors is a genuine
    /// cross-KIND same-name collision (a `struct X` + `class X`, etc.). Such a name's field
    /// shape is ambiguous, so it must be poisoned from any host-projection catalog that
    /// unions across the three kinds (build-safe = demote-safe).
    static func crossKindCollidingNames<S: Sequence, C: Sequence, E: Sequence>(
        structNames: S, classNames: C, enumNames: E
    ) -> Set<String> where S.Element == String, C.Element == String, E.Element == String {
        var seen = Set<String>(), collide = Set<String>()
        for n in structNames { if !seen.insert(n).inserted { collide.insert(n) } }
        for n in classNames { if !seen.insert(n).inserted { collide.insert(n) } }
        for n in enumNames { if !seen.insert(n).inserted { collide.insert(n) } }
        return collide
    }

    /// Project-wide COLLECTION-field catalog for the reactive-member collection-guard
    /// host-projection: type name → field names whose declared type is a collection
    /// (`[…]`/`Array<…>`/`Set<…>`/`Dictionary<…>`/`[…:…]`), or an empty-collection literal
    /// initializer (`= []`/`= [:]`). A `private`/`fileprivate`/`static` field is excluded.
    static func collectionFieldCatalog(in tree: SourceFileSyntax) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        func isCollectionType(_ typeText: String) -> Bool {
            let t = typeText.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("?") || t.hasSuffix("!") { return false }   // optional collection: demote-safe
            if t.hasPrefix("[") && t.hasSuffix("]") { return true }
            if t.hasPrefix("Array<") || t.hasPrefix("Set<") || t.hasPrefix("Dictionary<") { return true }
            return false
        }
        func isEmptyCollectionLiteral(_ expr: ExprSyntax) -> Bool {
            expr.is(ArrayExprSyntax.self) || expr.is(DictionaryExprSyntax.self)
        }
        func collect(_ name: String, _ members: MemberBlockItemListSyntax) {
            var fields = out[name] ?? Set<String>()
            for member in members {
                guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
                if v.modifiers.contains(where: {
                    $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
                    // `private(set)`/`fileprivate(set)` carry the scope in `.detail` and leave the
                    // GETTER at default access, so the cross-file thunk + SDK Mirror CAN read them.
                    // Exclude `private`/`fileprivate` only when there's no `(set)` detail.
                    || ($0.detail == nil
                        && ($0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)))
                }) { continue }
                for b in v.bindings {
                    let fname = b.pattern.trimmedDescription
                    guard !fname.isEmpty, fname != "body" else { continue }
                    if let t = b.typeAnnotation?.type.trimmedDescription, isCollectionType(t) {
                        fields.insert(fname)
                    } else if b.accessorBlock == nil, b.typeAnnotation == nil,
                              let initVal = b.initializer?.value, isEmptyCollectionLiteral(initVal) {
                        fields.insert(fname)
                    }
                }
            }
            if !fields.isEmpty { out[name] = fields }
        }
        let structDecls = StructEnumDeclCollector(viewMode: .sourceAccurate); structDecls.walk(tree)
        let classDecls = AnyClassDeclCollector(viewMode: .sourceAccurate); classDecls.walk(tree)
        // Poison any name declared as BOTH a struct and a class within the file — `collect`'s
        // `out[name] ?? Set()` would otherwise UNION a struct's collection fields with a same-name
        // class's, host-projecting a `.count`/`.isEmpty` guard against a field that exists only on
        // the OTHER same-name type → an uncompilable thunk (build-safe = demote-safe to drop).
        let crossKindCollision = Self.crossKindCollidingNames(structNames: structDecls.structDecls.keys,
                                                              classNames: classDecls.classes.keys,
                                                              enumNames: [String]())
        for (n, d) in structDecls.structDecls where !crossKindCollision.contains(n) { collect(n, d.memberBlock.members) }
        for (n, d) in classDecls.classes where !crossKindCollision.contains(n) { collect(n, d.memberBlock.members) }
        return out
    }

    /// Project-wide catalog of a TYPE's COMPUTED scalar/Font members, for the
    /// computed-member-on-input host-projection (the design-system-`Size`-enum idiom:
    /// `struct StreakBadge { let size: Size; enum Size { var iconSize: CGFloat {…} } }`).
    /// type name → (member name → host-token kind). A member qualifies only if it is a
    /// COMPUTED property (a `{ get }` accessor block — a switch/expression over `self`, the
    /// shape the thunk re-runs natively) whose declared return type is provably a scalar
    /// (`CGFloat`/`Double`/`Int`/`Float` → `.number`, `String` → `.string`) or `Font`
    /// (`.font`). A STORED field is excluded (it routes through marshalling / the string-field
    /// catalogs). A `private`/`fileprivate`/`static` member is excluded (the cross-file thunk
    /// can't reach a private member; a same-file thunk could, but to stay conservative — and
    /// because the demote-safety gate the emitter applies already filters on accessibility —
    /// we keep the catalog public-only). An optional / non-scalar / generic / parameterized
    /// member is OMITTED (`var label: String?` / `var view: some View` / `func f()` →
    /// `.number(Double(self.size.label))`-style mis-compile would fail; demote-safe to skip).
    /// Recurses into nested type decls (`enum Size` nested in the view struct is captured).
    static func computedScalarFontMemberCatalog(in tree: SourceFileSyntax) -> [String: [String: HostToken.Kind]] {
        var out: [String: [String: HostToken.Kind]] = [:]
        func tokenKind(of typeText: String) -> HostToken.Kind? {
            var t = typeText.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("?") || t.hasSuffix("!") { return nil }   // optional disqualifies
            if let dot = t.lastIndex(of: ".") { t = String(t[t.index(after: dot)...]) }
            switch t {
            case "CGFloat", "Double", "Int", "Float": return .number
            case "String": return .string
            case "Font": return .font
            default: return nil
            }
        }
        func collect(_ name: String, _ members: MemberBlockItemListSyntax) {
            var fields = out[name] ?? [:]
            for member in members {
                guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
                if v.modifiers.contains(where: {
                    $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
                    // `private(set)`/`fileprivate(set)` carry the scope in `.detail` and leave the
                    // GETTER at default access, so the cross-file thunk + SDK Mirror CAN read them.
                    // Exclude `private`/`fileprivate` only when there's no `(set)` detail.
                    || ($0.detail == nil
                        && ($0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)))
                }) { continue }
                for b in v.bindings {
                    let fname = b.pattern.trimmedDescription
                    guard !fname.isEmpty, fname != "body", fields[fname] == nil else { continue }
                    // Must be a COMPUTED property (a getter accessor block) — the shape the
                    // thunk re-runs natively. A stored field is not host-projected here.
                    guard b.accessorBlock != nil else { continue }
                    guard let t = b.typeAnnotation?.type.trimmedDescription,
                          let k = tokenKind(of: t) else { continue }
                    fields[fname] = k
                }
            }
            if !fields.isEmpty { out[name] = fields }
        }
        let structDecls = StructEnumDeclCollector(viewMode: .sourceAccurate); structDecls.walk(tree)
        for (n, d) in structDecls.structDecls { collect(n, d.memberBlock.members) }
        let classDecls = AnyClassDeclCollector(viewMode: .sourceAccurate); classDecls.walk(tree)
        for (n, d) in classDecls.classes { collect(n, d.memberBlock.members) }
        let enumDecls = AnyEnumDeclCollector(viewMode: .sourceAccurate); enumDecls.walk(tree)
        for (n, d) in enumDecls.enums { collect(n, d.memberBlock.members) }
        return out
    }

    /// The view's struct/enum INPUT params → their (unqualified) type name. An INPUT is a
    /// STORED `let`/`var` (no accessor block — a computed property is structure, not an input)
    /// whose declared type is a plain identifier (optionally module-qualified / optional-
    /// wrapped). Used to resolve a `<input>.<member>` read against
    /// `computedScalarFontMemberCatalog`. Property-wrapper attributes don't matter here (a
    /// `@State`-wrapped struct still names a struct type); the value the body reads is the
    /// member off that type, which the thunk re-evaluates over `self.<input>`.
    /// Scalar/marshalled input types that must NEVER count as a struct/enum INPUT base for the
    /// numeric-token demote-safety gate. A view input of one of these is guest-resolvable
    /// (marshalled into the body / resolvable over `self` in the thunk), so a numeric token may
    /// freely reference it. Anything NOT in this set is treated as a genuine struct/enum input
    /// (gated). `Bool` is the regression's culprit (`grid ? Theme.Radius.md : Theme.Radius.pill`).
    static let scalarInputTypeNames: Set<String> = [
        "Bool", "String", "Int", "Double", "CGFloat", "Float",
        "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    ]

    static func inputDeclaredTypeNames(of s: StructDeclSyntax) -> [String: String] {
        var out: [String: String] = [:]
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            if v.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) { continue }
            for b in v.bindings {
                guard b.accessorBlock == nil else { continue }   // computed → not an input
                let name = b.pattern.trimmedDescription
                guard !name.isEmpty, name != "body" else { continue }
                guard var t = b.typeAnnotation?.type.trimmedDescription else { continue }
                t = t.trimmingCharacters(in: .whitespaces)
                while t.hasSuffix("?") || t.hasSuffix("!") { t = String(t.dropLast()) }
                if let dot = t.lastIndex(of: ".") { t = String(t[t.index(after: dot)...]) }
                guard !t.isEmpty, t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
                out[name] = t
            }
        }
        return out
    }

    /// HOST-PROJECTABLE single-hop reads off a view's struct/enum INPUT params:
    /// `<input>.<computedScalarFontMember>` → its token kind (`.number`/`.string`/`.font`).
    /// The input's declared type is resolved via `inputDeclaredTypeNames`, its computed
    /// member's kind via the project-wide `computedScalarFontMemberCatalog`. The thunk
    /// evaluates `self.<input>.<member>` natively → a number/string the SDK merges into the
    /// guest input JSON (a `.font` rides the tree as a `.fontToken`). This is the
    /// reactive-member host-projection mechanism, generalized to a NEW receiver — a struct/
    /// enum view param — and a NEW member shape — a COMPUTED scalar/Font (the design-system
    /// `Size`-enum idiom). Only a PROVABLY-scalar/Font computed single-hop read qualifies;
    /// a method call / deeper chain / non-scalar / optional member is excluded (it demotes —
    /// faithful). Returns `path → kind`.
    static func inputComputedMemberPaths(of s: StructDeclSyntax,
                                         memberCatalog: [String: [String: HostToken.Kind]]) -> [String: HostToken.Kind] {
        var out: [String: HostToken.Kind] = [:]
        for (base, typeName) in Self.inputDeclaredTypeNames(of: s) {
            guard let members = memberCatalog[typeName] else { continue }
            for (member, kind) in members {
                out["\(base).\(member)"] = kind
            }
        }
        return out
    }

    /// Collect member-access PATHS (`profile.name`, `profile.address.city`) of the view whose
    /// declared/inferred leaf type is PROVABLY a non-optional `String`, resolved from the local
    /// struct `catalog`. The type-PROOF for admitting a BARE MEMBER-ACCESS string token: the
    /// thunk emits `.string(self.<path>)`, which compiles only when the path is a `String`.
    ///
    /// A stored/`@State` property whose type — an explicit annotation, else the callee of a
    /// `Type(...)` initializer (`= Profile(...)`) — is a catalog struct contributes one path
    /// per `String` SCALAR field, recursing into nested-struct fields. OPTIONAL-scalar and
    /// non-String fields are EXCLUDED (`.string(String?)` / `.string(Int)` won't compile).
    /// Accessibility is NOT filtered here — the recorder's `inaccessibleNames` slotability scan
    /// demotes a private read in the separate-file thunk; a same-file thunk reads it natively.
    /// Static members are skipped (a bare reference needs a type qualifier — a member access).
    static func stringTypedMemberPaths(of s: StructDeclSyntax,
                                       catalog: [String: [StructField]]) -> Set<String> {
        var out = Set<String>()
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            if v.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) { continue }
            for binding in v.bindings {
                let name = binding.pattern.trimmedDescription
                guard !name.isEmpty, name != "body" else { continue }
                guard let structName = Self.structTypeNameOfBinding(binding),
                      let fields = catalog[structName] else { continue }
                Self.collectStringScalarPaths(prefix: name, fields: fields, into: &out, depth: 0)
            }
        }
        return out
    }

    /// The STRUCT type name of a stored-property binding: an explicit annotation (stripped of
    /// `?`/`!`/module qualifier), else the callee of a bare `Type(...)` initializer
    /// (`@State var profile = Profile(...)` → `Profile`). Returns nil for a generic/array/
    /// closure/non-identifier spelling (those aren't catalog structs).
    private static func structTypeNameOfBinding(_ binding: PatternBindingSyntax) -> String? {
        if let typeText = binding.typeAnnotation?.type.trimmedDescription {
            var t = typeText.trimmingCharacters(in: .whitespaces)
            while t.hasSuffix("?") || t.hasSuffix("!") { t = String(t.dropLast()) }
            if let dot = t.lastIndex(of: ".") { t = String(t[t.index(after: dot)...]) }
            return t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !t.isEmpty ? t : nil
        }
        if let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return callee.baseName.text
        }
        return nil
    }

    /// Append `prefix.field` for every `String` SCALAR field, recursing into nested structs
    /// (`prefix.sub.field`). Bounded recursion (depth < 4) guards a cyclic/deep shape.
    private static func collectStringScalarPaths(prefix: String, fields: [StructField],
                                                 into out: inout Set<String>, depth: Int) {
        guard depth < 4 else { return }
        for f in fields {
            switch f.shape {
            case .scalar(.string):
                out.insert("\(prefix).\(f.name)")
            case .structValue(let el):
                Self.collectStringScalarPaths(prefix: "\(prefix).\(f.name)",
                                              fields: el.fields, into: &out, depth: depth + 1)
            default:
                break   // optional/non-String/collection/enum — not a provable bare String
            }
        }
    }

    /// DIAGNOSTIC helper: the view's stored-property names that are SwiftData-backed —
    /// detected by property-wrapper ATTRIBUTE: `@Query` (a fetch result `[Model]`),
    /// `@Bindable` (a bound `@Model` instance), or `@Environment(\.modelContext)` (the
    /// model context). These are reference-type, macro/ObjC-backed values the engine can't
    /// marshal into the Foundation-free guest, so a view reading one demotes. Naming them
    /// turns the invisible #1 modern-SwiftUI-app coverage wall into actionable feedback.
    /// Attribute-based (syntax-only) — conservative: a bare `let m: SomeModel` without a
    /// wrapper isn't flagged here (it surfaces as a generic non-reconstructable read).
    static func swiftDataPropertyNames(of s: StructDeclSyntax) -> Set<String> {
        var out = Set<String>()
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            var isSwiftData = false
            for attr in v.attributes {
                guard let a = attr.as(AttributeSyntax.self) else { continue }
                let name = a.attributeName.trimmedDescription
                if name == "Query" || name == "Bindable" { isSwiftData = true; break }
                if name == "Environment",
                   let args = a.arguments?.trimmedDescription,
                   args.contains("modelContext") { isSwiftData = true; break }
            }
            guard isSwiftData else { continue }
            for binding in v.bindings {
                let n = binding.pattern.trimmedDescription
                if !n.isEmpty { out.insert(n) }
            }
        }
        return out
    }

    /// DIAGNOSTIC: stored-property names of `s` whose declared type annotation is a
    /// Swift TUPLE — spelled `(…)` with at least one `,` or `:` inside (the canonical
    /// `(type1, type2)` / `(label: Type, …)` forms). Tuples aren't Codable, so the engine
    /// can't marshal them; naming them lets the demote diagnostic suggest the fix
    /// (replace with a named Codable struct). Computed properties are excluded (they
    /// don't produce a stored input). Pure diagnostic — never changes what ships.
    static func tuplePropertyNames(of s: StructDeclSyntax) -> Set<String> {
        var out = Set<String>()
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in v.bindings {
                // Only stored properties (no accessor block = no computed getter).
                guard binding.accessorBlock == nil else { continue }
                guard let typeText = binding.typeAnnotation?.type.trimmedDescription else { continue }
                // A tuple type: the top-level annotation is parenthesised AND contains at
                // least one element separator (`,`) or element label (`:`).
                let t = typeText.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("("), t.hasSuffix(")"),
                      t.contains(",") || t.contains(":") else { continue }
                let n = binding.pattern.trimmedDescription
                if !n.isEmpty { out.insert(n) }
            }
        }
        return out
    }

    /// CLOSURE-PROP SLOT: stored-property names of `s` whose declared type annotation is a
    /// Swift FUNCTION TYPE (contains ` -> ` in the annotation text). These are callback
    /// closures — `let onTap: () -> Void`, `let onSelect: (String) -> Void` — that the guest
    /// WASM can't reconstruct (there's no JSON-marshallable representation for a closure), so
    /// they appear in `unmarshalledNames` and cause the whole view to demote. The fix: subtract
    /// them from `unmarshalledNames` before the `referencesUnmarshalled` check, then let the
    /// emitter's existing actionSlot / opaqueExprLifted path handle each call site natively.
    ///
    /// Only STORED properties (no accessor block). Only properties whose TYPE ANNOTATION
    /// contains ` -> ` (the function-arrow — provably a function/closure type). Computed
    /// properties are excluded (they're not inputs and use a different mechanism). A plain
    /// variable without a type annotation stays `.unsupported` (conservative).
    ///
    /// INERTNESS: subtracting a closure prop from `unmarshalledNames` ONLY promotes views that
    /// were previously DEMOTING because of that prop. A view with no closure props, or one that
    /// already lowered, is completely unaffected (the set subtraction is a no-op there).
    static func closurePropNames(of s: StructDeclSyntax) -> Set<String> {
        var out = Set<String>()
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in v.bindings {
                // Only stored properties (no accessor block = no computed getter).
                guard binding.accessorBlock == nil else { continue }
                guard let typeText = binding.typeAnnotation?.type.trimmedDescription else { continue }
                // A function/closure type contains a function arrow in its annotation.
                // Examples: `() -> Void`, `(String) -> Bool`, `(Int, Int) -> Int`.
                // Conservative: the arrow MUST appear as ` -> ` (with spaces) to avoid
                // matching a subscript-result annotation or an accidental substring.
                guard typeText.contains(" -> ") else { continue }
                let n = binding.pattern.trimmedDescription
                if !n.isEmpty { out.insert(n) }
            }
        }
        return out
    }

    /// True iff a declared type spelling is provably a COLLECTION with `.count`/`.isEmpty`
    /// (an Array `[T]`/`Array<T>`/`ContiguousArray<T>`, a Set `Set<T>`, a Dictionary
    /// `[K:V]`/`Dictionary<K,V>`, or a `String`/`Substring`), allowing an Optional/`!` wrapper
    /// + module qualifier. The PROOF for host-projecting a `.count`/`.isEmpty` collection guard
    /// (BUG #13): a domain type with a custom `var isEmpty: Bool`/`var count: Int` is NOT a
    /// collection, so `(self.<that>).count` would fail the thunk compile / evaluate the wrong
    /// branch — only a provable collection admits the guard.
    static func isCollectionTypeSpelling(_ raw: String) -> Bool {
        var t = raw.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("?") || t.hasSuffix("!") { t = String(t.dropLast()).trimmingCharacters(in: .whitespaces) }
        if t.hasPrefix("[") && t.hasSuffix("]") { return true }   // [T] array OR [K:V] dictionary
        // Strip a leading module qualifier (`Swift.Set` → `Set`).
        if let dot = t.lastIndex(of: "."), !t.contains("<") || t.firstIndex(of: "<")! > dot {
            t = String(t[t.index(after: dot)...])
        }
        if t == "String" || t == "Substring" { return true }
        for head in ["Array<", "Set<", "Dictionary<", "ContiguousArray<"] where t.hasPrefix(head) && t.hasSuffix(">") {
            return true
        }
        return false
    }

    /// View member names whose declared/return type is PROVABLY a collection (see
    /// `isCollectionTypeSpelling`) — the allowlist that gates `.count`/`.isEmpty` collection-guard
    /// host-projection (BUG #13). Covers a `@Query var plants: [Plant]`, a stored `var items: [X]`,
    /// and a computed `var filtered: [X] { … }`. A member with no collection-spelling annotation
    /// (incl. a domain type carrying a custom `isEmpty`/`count`) is NOT admitted → its guard demotes.
    static func collectionTypedMemberNames(of s: StructDeclSyntax) -> Set<String> {
        var out = Set<String>()
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            if v.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) { continue }
            for binding in v.bindings {
                let name = binding.pattern.trimmedDescription
                guard !name.isEmpty, name != "body" else { continue }
                if let t = binding.typeAnnotation?.type.trimmedDescription, Self.isCollectionTypeSpelling(t) {
                    out.insert(name)
                }
            }
        }
        return out
    }

    /// True iff a declared type spelling is OPTIONAL (`T?`, `T!`, `Optional<T>`, `Swift.Optional<T>`).
    /// Bare-identifier color/font/numeric TOKENS reject optionals (BUG #5/#31): the thunk's
    /// `.color(<name>)`/`.number(Double(<name>))` need a non-optional value, so a bare optional read
    /// slots/demotes instead of shipping an uncompilable thunk.
    static func isOptionalTypeSpelling(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("?") || t.hasSuffix("!") { return true }
        if let lt = t.firstIndex(of: "<"), t.hasSuffix(">") {
            let head = String(t[..<lt]).trimmingCharacters(in: .whitespaces)
            if head == "Optional" || head.hasSuffix(".Optional") { return true }
        }
        return false
    }

    /// True iff a declared type spelling is a numeric scalar (`Int`/`Double`/`CGFloat`/`Float`),
    /// allowing an `Optional`/`!` wrapper and a module qualifier.
    private static func isNumericScalarType(_ raw: String) -> Bool {
        var t = raw.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("?") || t.hasSuffix("!") { t = String(t.dropLast()) }
        if let lt = t.firstIndex(of: "<"), t.hasSuffix(">") {
            let head = String(t[..<lt])
            if head == "Optional" || head.hasSuffix(".Optional") {
                t = String(t[t.index(after: lt)..<t.index(before: t.endIndex)])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        if let dot = t.lastIndex(of: ".") { t = String(t[t.index(after: dot)...]) }
        switch t {
        case "Int", "Double", "CGFloat", "Float": return true
        default: return false
        }
    }

    private enum ColorFontType { case color, font }

    /// Map a declared type spelling to `.color`/`.font` when it's provably one (allowing an
    /// `Optional` wrapper: `Color?`, `Optional<Font>`, `SwiftUI.Color`). Returns nil
    /// otherwise. Conservative on purpose — a typealias or a custom wrapper isn't matched
    /// (it'd native-slot, which is safe).
    private static func normalizedColorFontType(_ raw: String) -> ColorFontType? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        // Strip a trailing `?` (Optional sugar) and `!` (IUO).
        while t.hasSuffix("?") || t.hasSuffix("!") { t = String(t.dropLast()) }
        // `Optional<Color>` / `Swift.Optional<Font>`.
        if let lt = t.firstIndex(of: "<"), t.hasSuffix(">") {
            let head = String(t[..<lt])
            if head == "Optional" || head.hasSuffix(".Optional") {
                t = String(t[t.index(after: lt)..<t.index(before: t.endIndex)])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        // Strip a module qualifier (`SwiftUI.Color` → `Color`).
        if let dot = t.lastIndex(of: ".") { t = String(t[t.index(after: dot)...]) }
        switch t {
        case "Color": return .color
        case "Font": return .font
        default: return nil
        }
    }

    /// Collect the view's SAME-STRUCT helper view-members that can be INLINE-LOWERED
    /// into the parent body (TASK 2), keyed by name → the helper's body statements:
    ///   * a `var header: some View { … }` computed property (a getter returning
    ///     `some View`/`View`), and
    ///   * a `@ViewBuilder func makeRow() -> some View { … }` (or a plain
    ///     `func … -> some View`) with NO parameters.
    /// A helper that TAKES ARGUMENTS, is `private`/`fileprivate` (still fine to inline —
    /// it's substituted into the same type's lowered body, which can see private
    /// members; the cross-file thunk constraint only blocks SLOT closures, not the
    /// in-WASM guest body), or whose body isn't a single view expression list is simply
    /// NOT collected → its use-site stays `.opaque`. `body` itself is excluded (it's the
    /// entry point, not a helper). The emitter substitutes a collected helper's body
    /// inline and lowers it; an uncollected reference slots as before.
    static func inlinableHelpers(of s: StructDeclSyntax) -> [String: CodeBlockItemListSyntax] {
        var out: [String: CodeBlockItemListSyntax] = [:]
        for member in s.memberBlock.members {
            // `var header: some View { … }` — a computed view property.
            if let v = member.decl.as(VariableDeclSyntax.self) {
                for binding in v.bindings {
                    let name = binding.pattern.trimmedDescription
                    guard name != "body", !name.isEmpty else { continue }
                    guard Self.isSomeViewType(binding.typeAnnotation?.type) else { continue }
                    guard let stmts = Self.getterStatements(binding.accessorBlock) else { continue }
                    guard Self.helperBodyIsInlineSafe(stmts) else { continue }
                    out[name] = stmts
                }
                continue
            }
            // `func makeRow() -> some View { … }` (NO params) — a helper builder.
            if let f = member.decl.as(FunctionDeclSyntax.self) {
                let sig = f.signature
                // Only a NO-ARG helper inlines cleanly (an arg-taking helper's body
                // references params not in the parent scope → keep slotting).
                guard sig.parameterClause.parameters.isEmpty else { continue }
                guard Self.isSomeViewType(sig.returnClause?.type) else { continue }
                guard let body = f.body, Self.helperBodyIsInlineSafe(body.statements) else { continue }
                out[f.name.text] = body.statements
            }
        }
        return out
    }

    /// Whether a helper's body is SAFE to inline-lower into the parent guest body. The
    /// hazard: a `let`/`var` declaration in a BUILDER-statement position of the helper
    /// (`var header: some View { let x = …; Text(x) }`) is SKIPPED by the emitter
    /// (decls aren't nodes), but a sibling node referencing `x` would emit a LIVE `x`
    /// the guest can't bind → the single-unit guest module fails to compile (taking
    /// sibling views down with it). Such a helper is NOT inlined (its use-site keeps
    /// slotting — faithful + demote-safe). We check the SAME positions the emitter
    /// treats as builder statement lists: the top-level statements and `if`/`else`
    /// branch blocks (which `emitIf` recurses into). A `let` inside an ACTION/label
    /// CLOSURE (a `Button { let x = …; save(x) }`) is NOT a builder statement (the
    /// closure body is behavior, never emitted as a node), so it doesn't disqualify —
    /// we deliberately don't recurse into closures, keeping the common interactive
    /// helper inlinable.
    private static func helperBodyIsInlineSafe(_ stmts: CodeBlockItemListSyntax) -> Bool {
        for item in stmts {
            switch item.item {
            case .decl(let d) where d.is(VariableDeclSyntax.self):
                return false
            case .expr(let e):
                if let ifExpr = e.as(IfExprSyntax.self), !ifBranchesInlineSafe(ifExpr) { return false }
            case .stmt(let s):
                if let ifExpr = s.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self),
                   !ifBranchesInlineSafe(ifExpr) { return false }
            default:
                break
            }
        }
        return true
    }

    /// Recurse the inline-safety check into an `if`/`else` builder's branch blocks.
    private static func ifBranchesInlineSafe(_ ifExpr: IfExprSyntax) -> Bool {
        guard helperBodyIsInlineSafe(ifExpr.body.statements) else { return false }
        if let elseBody = ifExpr.elseBody {
            switch elseBody {
            case .codeBlock(let cb): return helperBodyIsInlineSafe(cb.statements)
            case .ifExpr(let nested): return ifBranchesInlineSafe(nested)
            }
        }
        return true
    }

    /// Whether `type` is `some View` / `View` (the helper-view return shape). An
    /// `opaque` `some View`, a bare `View`, or `AnyView` all qualify; any other type
    /// (a concrete `Text`, a non-View) does not.
    private static func isSomeViewType(_ type: TypeSyntax?) -> Bool {
        guard let type else { return false }
        if let some = type.as(SomeOrAnyTypeSyntax.self) {
            return some.constraint.trimmedDescription == "View"
        }
        let t = type.trimmedDescription
        return t == "View" || t == "AnyView"
    }

    /// The statement list of a computed property's GETTER (`{ … }` or `{ get { … } }`),
    /// or nil if the accessor block isn't a readable getter.
    private static func getterStatements(_ accessor: AccessorBlockSyntax?) -> CodeBlockItemListSyntax? {
        guard let accessor else { return nil }
        switch accessor.accessors {
        case .getter(let items): return items
        case .accessors(let list):
            for acc in list where acc.accessorSpecifier.text == "get" {
                if let b = acc.body { return b.statements }
            }
            return nil
        }
    }

    private static func inputKind(typeAnnotation: String?, defaultExpr: String?) -> ViewInput.Kind {
        // Prefer the declared type; fall back to inferring from the default literal.
        if let t = typeAnnotation {
            switch t {
            case "String": return .string
            case "Bool": return .bool
            case "Int": return .int
            case "Double", "CGFloat": return .double
            default:
                if let arr = arrayElementKind(t) { return arr }
                return .unsupported
            }
        }
        if let d = defaultExpr {
            if d == "true" || d == "false" { return .bool }
            if d.hasPrefix("\"") { return .string }
            if d.contains(".") , Double(d) != nil { return .double }
            if Int(d) != nil { return .int }
            // An ARRAY-LITERAL default with no type annotation (`days = ["M","T","W"]`):
            // infer the array kind for the UNAMBIGUOUS element shapes (all string literals
            // → .stringArray; all bool literals → .boolArray). A numeric literal array is
            // ambiguous ([Int] vs [Double]) and stays `.unsupported` (slots, as before),
            // and a mixed/empty literal isn't reconstructable. This makes a guest-readable
            // array reachable WITHOUT a type annotation — so a `ForEach`/subscript over it
            // lowers instead of slotting the surrounding construct.
            if let arr = Self.arrayLiteralKind(d) { return arr }
        }
        return .unsupported
    }

    /// Infer a guest-reconstructable ARRAY kind from an array-LITERAL default expression
    /// with no type annotation, for the UNAMBIGUOUS element shapes only: a non-empty
    /// literal whose every element is a string literal → `.stringArray`; every element a
    /// `true`/`false` → `.boolArray`. Returns nil for a numeric literal array (ambiguous
    /// `[Int]`/`[Double]`), an empty literal, a mixed/non-literal element, or a
    /// non-array-literal expression (the caller keeps `.unsupported`, which slots safely).
    static func arrayLiteralKind(_ src: String) -> ViewInput.Kind? {
        let s = src.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("["), s.hasSuffix("]") else { return nil }
        let arrTree = Parser.parse(source: "let __patch_arr = \(s)")
        guard let arrayExpr = ArrayLiteralFinder.firstArray(in: arrTree),
              !arrayExpr.elements.isEmpty else { return nil }
        var allString = true, allBool = true
        for el in arrayExpr.elements {
            let e = el.expression
            if e.is(StringLiteralExprSyntax.self) { allBool = false }
            else if let b = e.as(BooleanLiteralExprSyntax.self),
                    b.literal.tokenKind == .keyword(.true) || b.literal.tokenKind == .keyword(.false) {
                allString = false
            } else {
                return nil   // a numeric/other/non-literal element → not unambiguous
            }
        }
        if allString { return .stringArray }
        if allBool { return .boolArray }
        return nil
    }

    /// The names of the inputs whose kind is an ARRAY-OF-SCALAR — the inputs B's
    /// marshalling exposes to the guest as a bound `[Int]`/`[String]`/`[Double]`/
    /// `[Bool]`. A `ForEach`/dynamic-`List` over one of these can emit a real guest
    /// loop binding the element var; anything else demotes (the emitter's
    /// `scalarArrayInputNames` gate).
    static func scalarArrayInputNames(_ inputs: [ViewInput]) -> Set<String> {
        Set(inputs.filter {
            switch $0.kind {
            case .stringArray, .boolArray, .intArray, .doubleArray: return true
            default: return false
            }
        }.map(\.name))
    }

    /// The struct-array inputs keyed by name → element descriptor (TASK 1). A
    /// `ForEach`/dynamic-`List` over one of these emits a real guest loop binding
    /// `item` over the marshalled array-of-objects (its fields resolve against the
    /// generated guest struct); anything else demotes. The Emitter's gate.
    static func structArrayInputElements(_ inputs: [ViewInput]) -> [String: ViewInput.StructElement] {
        var out: [String: ViewInput.StructElement] = [:]
        for inp in inputs where inp.kind == .structArray {
            if let el = inp.structElement { out[inp.name] = el }
        }
        return out
    }

    /// The SINGLE flat-struct inputs keyed by name → element descriptor (TASK 1). The
    /// guest binds each as `let item = _patchScan<Type>Row(blob,"item") ?? _PatchRow_<Type>()`,
    /// so `item.<flatField>` resolves. The Emitter's gate (a use that isn't `item.<field>`
    /// already downgraded the input to `.unsupported` in `gateRichInputs`).
    static func flatStructInputElements(_ inputs: [ViewInput]) -> [String: ViewInput.StructElement] {
        var out: [String: ViewInput.StructElement] = [:]
        for inp in inputs where inp.kind == .flatStruct {
            if let el = inp.structElement { out[inp.name] = el }
        }
        return out
    }

    /// The RAW-VALUE enum inputs keyed by name → element descriptor (TASK 2). The guest
    /// binds each to a mirroring `enum _PatchEnum_<Type>` via a case scanner, so
    /// `s == .case` / `switch s` / `s.rawValue` resolve.
    static func enumInputElements(_ inputs: [ViewInput]) -> [String: ViewInput.EnumElement] {
        var out: [String: ViewInput.EnumElement] = [:]
        for inp in inputs where inp.kind == .enumValue {
            if let el = inp.enumElement { out[inp.name] = el }
        }
        return out
    }

    /// DEMOTE-SAFE gate for the rich (`.flatStruct` / `.enumValue`) inputs (TASKS 1+2).
    /// An input is marked rich PROVISIONALLY by `viewInputs`; this walks the WHOLE body
    /// and downgrades it to `.unsupported` (so `referencesUnmarshalledInput` keeps the
    /// view native, exactly as before) UNLESS the body uses it ONLY in a way the guest
    /// reconstruction can faithfully compile:
    ///   * `.flatStruct`: every use is `input.<flatField>` (a bare `input`, a method call,
    ///     a non-flat-field / chained access disqualifies — `FlatStructInputUsageScanner`).
    ///   * `.enumValue`: every use is `input == .case` / `switch input { case .x }` /
    ///     `input.rawValue` (a bare `input` passed somewhere, a `.method()`, an unknown
    ///     member disqualifies — `EnumInputUsageScanner`).
    /// A non-rich input passes through unchanged. (The whole module shares ONE guest
    /// compile unit, so a single broken reconstruction would ship NO views — this gate is
    /// the safety the design rests on: faithful native demote over a wrong/partial render.)
    static func gateRichInputs(_ inputs: [ViewInput],
                               bodyExpr: CodeBlockItemListSyntax,
                               helperBodies: [CodeBlockItemListSyntax] = []) -> [ViewInput] {
        // Scan the body AND every inlinable helper body (each may be substituted INLINE
        // into the guest body), so a non-reconstructable use anywhere disqualifies.
        let scopes = [bodyExpr] + helperBodies
        return inputs.map { inp in
            switch inp.kind {
            case .flatStruct:
                guard let el = inp.structElement else {
                    return ViewInput(name: inp.name, kind: .unsupported, defaultLiteral: "\"\"")
                }
                // Shape-aware gate: every use of `item` must be a member-access chain that
                // resolves through the recursive field shapes to a guest-safe LEAF (a
                // scalar, or a scalar-array/dictionary used only as a whole collection).
                let ok = scopes.allSatisfy {
                    FlatStructInputUsageScanner.usesOnlyReconstructableFields(
                        $0, name: inp.name, fields: el.fields)
                }
                return ok ? inp : ViewInput(name: inp.name, kind: .unsupported, defaultLiteral: "\"\"")
            case .enumValue:
                guard let el = inp.enumElement else {
                    return ViewInput(name: inp.name, kind: .unsupported, defaultLiteral: "\"\"")
                }
                let cases = Set(el.caseNames)
                let ok = scopes.allSatisfy {
                    EnumInputUsageScanner.usesGuestReconstructably($0, name: inp.name, cases: cases)
                }
                return ok ? inp : ViewInput(name: inp.name, kind: .unsupported, defaultLiteral: "\"\"")
            default:
                return inp
            }
        }
    }

    /// Build a source-wide catalog of RAW-VALUE enums (type name → element descriptor)
    /// for `.enumValue` reconstruction (TASK 2). An enum qualifies iff it (1) declares a
    /// `String` or `Int` raw-value conformance in its inheritance clause, and (2) every
    /// case is a BARE no-associated-value case (an associated-value case disqualifies the
    /// whole enum — the guest can't reconstruct a payload from `{"case":"…"}`). The case
    /// names ride in declaration order. Walks top-level AND nested enum decls. On a name
    /// collision the enum is DROPPED (ambiguous shape; the input stays `.unsupported`).
    static func rawEnumCatalog(in tree: SourceFileSyntax) -> [String: ViewInput.EnumElement] {
        let collector = RawEnumCollector(viewMode: .sourceAccurate)
        collector.walk(tree)
        return collector.rawEnums
    }

    /// The RAW-VALUE-enum element descriptor for an enum decl, or nil if it isn't a
    /// String/Int raw enum of all-bare cases. (Shared by the collector.)
    static func rawEnumElement(_ e: EnumDeclSyntax) -> ViewInput.EnumElement? {
        // 1) A `String`/`Int` raw-value conformance in the inheritance clause.
        guard let inh = e.inheritanceClause else { return nil }
        var rawKind: ViewInput.EnumElement.RawKind?
        for t in inh.inheritedTypes {
            switch t.type.trimmedDescription {
            case "String": rawKind = .string
            case "Int": rawKind = .int
            default: break
            }
        }
        guard let rawKind else { return nil }
        // 2) Every case must be a BARE no-associated-value case.
        var cases: [ViewInput.EnumElement.Case] = []
        for member in e.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else {
                // A nested type / func / computed var is fine (it isn't a stored case),
                // BUT a stored property would be illegal in an enum — so skip non-cases.
                continue
            }
            for element in caseDecl.elements {
                // An associated value (parameter clause) disqualifies the whole enum.
                if element.parameterClause != nil { return nil }
                // Capture an EXPLICIT raw value (`= "x"` / `= 3`) so `.rawValue` is faithful;
                // nil means Swift's implicit raw (case name for String, running index for Int).
                let rawLiteral = element.rawValue?.value.trimmedDescription
                cases.append(.init(name: element.name.text, rawLiteral: rawLiteral))
            }
        }
        guard !cases.isEmpty else { return nil }
        return ViewInput.EnumElement(typeName: e.name.text, rawKind: rawKind, cases: cases)
    }

    /// Build a source-wide catalog of guest-reconstructable structs (type name →
    /// recursive field shapes). A struct qualifies iff EVERY stored property is a shape
    /// the guest can reconstruct: a scalar (`String`/`Bool`/`Int`/`Double`/`CGFloat`),
    /// a NESTED struct that itself qualifies, a raw-value enum, a scalar array, an
    /// ARRAY of a qualifying struct, or a `[String:Scalar]` dictionary — recursively.
    /// A field of any OTHER shape (an optional, a non-string-keyed dictionary, a custom
    /// non-catalog type, a deeper-than-bound nesting) disqualifies the whole struct (it
    /// stays out of the catalog, so a `[ThatStruct]`/`let x: ThatStruct` input stays
    /// `.unsupported` and the view demotes natively — never a wrong/partial render).
    /// Walks top-level AND nested struct decls (a `Player` nested in the view counts).
    ///
    /// RECURSION: resolution is two-phase — collect every struct/enum DECL first, then
    /// resolve each struct's fields against the decl set with cycle detection + a depth
    /// bound (so a struct that (transitively) references itself, or nests deeper than the
    /// guest's bounded marshalling, drops out rather than spin / over-promise).
    static func flatStructCatalog(in tree: SourceFileSyntax) -> [String: [StructField]] {
        let decls = StructEnumDeclCollector(viewMode: .sourceAccurate)
        decls.walk(tree)
        let enumCat = rawEnumCatalog(in: tree)
        var resolved: [String: [StructField]] = [:]
        for name in decls.structDecls.keys {
            if let fields = resolveStructFields(name, structDecls: decls.structDecls,
                                                enumCatalog: enumCat, visiting: []) {
                resolved[name] = fields
            }
        }
        return resolved
    }

    /// Build a catalog of EVERY struct/class type → its non-optional `String` stored fields,
    /// for HOST-PROJECTION ONLY (never marshalling). Unlike `flatStructCatalog` this does NOT
    /// require the WHOLE type to be reconstructable — a struct with a `Color`/`Image`/closure
    /// field still contributes its `String` fields here. The win: the ubiquitous "custom view
    /// displaying a model's fields" pattern — `OnboardingPageView(page:)` reading `page.title`
    /// where `OnboardingPage { title: String; color: Color }` — can host-project `page.title`
    /// (the thunk evals `self.page.title` → a `.string` token) even though the struct can't be
    /// marshalled (its `color` field disqualifies the marshalling catalog). Walks struct decls
    /// AND `@Model`/`@Observable`/plain class decls (a view's model is often a class). Only the
    /// `String` fields are recorded; a non-String field is simply omitted (a read of it isn't
    /// projected here → demotes/slots as before). Consumed ONLY by `stringTypedMemberPaths`.
    /// True iff `typeText` denotes Swift's `String` — i.e. the BARE token `String` or the
    /// explicitly-qualified `Swift.String`. Any OTHER `X.String` (a nested type that happens to
    /// be named `String`, e.g. `Theme.String`) is rejected (bug R2-#108): host-projecting it as
    /// a `.string` token would emit an uncompilable thunk.
    static func isBareSwiftString(_ typeText: String) -> Bool {
        let t = typeText.trimmingCharacters(in: .whitespaces)
        return t == "String" || t == "Swift.String"
    }

    static func hostProjectableStringFieldCatalog(in tree: SourceFileSyntax) -> [String: [StructField]] {
        let structDecls = StructEnumDeclCollector(viewMode: .sourceAccurate)
        structDecls.walk(tree)
        let classDecls = AnyClassDeclCollector(viewMode: .sourceAccurate)
        classDecls.walk(tree)
        let enumDecls = AnyEnumDeclCollector(viewMode: .sourceAccurate)
        enumDecls.walk(tree)
        let rawEnums = rawEnumCatalog(in: tree)   // String-raw enums → `.rawValue` is a String
        var out: [String: [StructField]] = [:]
        // Collect a type's HOST-PROJECTABLE String members: a STORED `var/let f: String`, AND a
        // COMPUTED `var f: String { get }` (non-private — the thunk reads `self.<param>.<f>`
        // natively, which calls the getter; a private getter on another type is unreachable
        // cross-file, so it's excluded). A computed String getter is the `accent.icon` /
        // `item.label` shape ubiquitous in "display a model" views.
        func collect(_ name: String, _ members: MemberBlockItemListSyntax) {
            var fields: [StructField] = []
            for member in members {
                guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
                if v.modifiers.contains(where: {
                    $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
                    // `private(set)`/`fileprivate(set)` carry the scope in `.detail` and leave the
                    // GETTER at default access, so the cross-file thunk + SDK Mirror CAN read them.
                    // Exclude `private`/`fileprivate` only when there's no `(set)` detail.
                    || ($0.detail == nil
                        && ($0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)))
                }) { continue }
                for binding in v.bindings {
                    let fname = binding.pattern.trimmedDescription
                    guard !fname.isEmpty, fname != "body",
                          let t = binding.typeAnnotation?.type.trimmedDescription else { continue }
                    // Accept ONLY the bare `String` or `Swift.String` — a member type spelled
                    // `Theme.String` (a nested type that is NOT Swift.String) must NOT be
                    // host-projected as a `.string` token (bug R2-#108: stripping the qualifier
                    // before the equality test mis-typed it → uncompilable `.string(...)` thunk).
                    if Self.isBareSwiftString(t) { fields.append(StructField(name: fname, kind: .string)) }
                }
            }
            if !fields.isEmpty, out[name] == nil { out[name] = fields }
        }
        // A simple name declared by 2+ of {struct, class, enum} is a within-file cross-KIND
        // collision: the three passes below would otherwise union/overwrite members across the
        // distinct same-name types (e.g. a String-raw enum X's `rawValue` appended onto a struct
        // X that has no `rawValue`, fabricating a member neither real type has → an uncompilable
        // `.string(self.x.rawValue)` thunk). The cross-FILE ambiguity drop is cross-file only and
        // the per-collector dedup is per-kind, so neither catches this. Poison such names from ALL
        // three passes so a read of the ambiguous type demotes (build-safe = demote-safe).
        let crossKindCollision = Self.crossKindCollidingNames(structNames: structDecls.structDecls.keys,
                                                              classNames: classDecls.classes.keys,
                                                              enumNames: enumDecls.enums.keys)
        for (name, decl) in structDecls.structDecls where !crossKindCollision.contains(name) {
            collect(name, decl.memberBlock.members)
        }
        for (name, decl) in classDecls.classes where out[name] == nil && !crossKindCollision.contains(name) {
            collect(name, decl.memberBlock.members)
        }
        // Enums: a String-raw enum's `.rawValue` is a `String` (the thunk reads
        // `self.<param>.rawValue`); plus any computed `var x: String`. Merge both. SKIP a name
        // already present from the struct/class pass (a same-name struct/class + enum must not
        // fabricate a unioned member set neither real type has) AND any cross-kind-collision name.
        for (name, decl) in enumDecls.enums where out[name] == nil && !crossKindCollision.contains(name) {
            var fields = out[name] ?? []
            if rawEnums[name]?.rawKind == .string, !fields.contains(where: { $0.name == "rawValue" }) {
                fields.append(StructField(name: "rawValue", kind: .string))
            }
            for member in decl.memberBlock.members {
                guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
                if v.modifiers.contains(where: {
                    $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.private)
                    || $0.name.tokenKind == .keyword(.fileprivate)
                }) { continue }
                for binding in v.bindings {
                    let fname = binding.pattern.trimmedDescription
                    guard !fname.isEmpty, fname != "body",
                          let t = binding.typeAnnotation?.type.trimmedDescription else { continue }
                    // Bare `String`/`Swift.String` only — a `Theme.String` nested type is NOT
                    // Swift.String (bug R2-#108).
                    if Self.isBareSwiftString(t), !fields.contains(where: { $0.name == fname }) {
                        fields.append(StructField(name: fname, kind: .string))
                    }
                }
            }
            if !fields.isEmpty { out[name] = fields }
        }
        return out
    }

    /// Per-TYPE catalog of MARSHALLABLE COLLECTION fields, for REACTIVE-COLLECTION MARSHALLING
    /// (the lever that lets a `ForEach(vm.items)` over a reactive view-model's collection lower to a
    /// bound guest loop instead of native-slotting the rows). type name → [StructField] for each
    /// stored `var/let f: [E]`/`Array<E>` whose element `E` is a SCALAR (→ `.scalarArray`) or a
    /// struct in `structCatalog` (→ `.structArray`). Unlike `flatStructCatalog` this does NOT require
    /// the WHOLE type to be reconstructable — a view-model CLASS with services/closures still
    /// contributes its array fields (the SDK marshals the reactive object as a nested JSON object;
    /// the guest only scans the collection field). A non-array field, a non-marshallable element, a
    /// `private`/`static`/computed field is OMITTED (a read of it isn't marshalled here → it
    /// host-projects/demotes as before — build-safe = demote-safe). Walks struct AND class decls
    /// (a reactive model is usually a class). Element resolution uses the (cross-file-merged)
    /// `structCatalog`, so a `[Player]` whose `Player` lives in another file still resolves.
    static func reactiveCollectionShapeCatalog(in tree: SourceFileSyntax,
                                               structCatalog: [String: [StructField]]) -> [String: [StructField]] {
        func scalarKind(_ t: String) -> ViewInput.Kind? {
            switch t {
            case "String": return .string
            case "Bool": return .bool
            case "Int": return .int
            case "Double", "CGFloat", "Float": return .double
            default: return nil
            }
        }
        func elementShape(_ arrayType: String) -> FieldShape? {
            let t = arrayType.trimmingCharacters(in: .whitespaces)
            let element: String
            if t.hasPrefix("["), t.hasSuffix("]") {
                element = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("Array<"), t.hasSuffix(">") {
                element = String(t.dropFirst("Array<".count).dropLast()).trimmingCharacters(in: .whitespaces)
            } else { return nil }
            guard !element.isEmpty, element.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
            if let k = scalarKind(element) { return .scalarArray(k) }
            if let fields = structCatalog[element], !fields.isEmpty {
                return .structArray(ViewInput.StructElement(typeName: element, fields: fields))
            }
            return nil   // non-marshallable element → not a reactive-marshallable collection
        }
        func collect(_ members: MemberBlockItemListSyntax) -> [StructField] {
            var fields: [StructField] = []
            for member in members {
                guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
                if v.modifiers.contains(where: {
                    $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
                    // `private(set)`/`fileprivate(set)` carry the scope in `.detail` and leave the
                    // GETTER at default access, so the cross-file thunk + SDK Mirror CAN read them.
                    // Exclude `private`/`fileprivate` only when there's no `(set)` detail.
                    || ($0.detail == nil
                        && ($0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)))
                }) { continue }
                for b in v.bindings {
                    if b.accessorBlock != nil { continue }   // computed → not a stored collection
                    let name = b.pattern.trimmedDescription
                    guard !name.isEmpty, name != "body",
                          let t = b.typeAnnotation?.type.trimmedDescription,
                          let shape = elementShape(t) else { continue }
                    if !fields.contains(where: { $0.name == name }) {
                        fields.append(StructField(name: name, shape: shape))
                    }
                }
            }
            return fields
        }
        var out: [String: [StructField]] = [:]
        let structDecls = StructEnumDeclCollector(viewMode: .sourceAccurate); structDecls.walk(tree)
        for (n, d) in structDecls.structDecls {
            let f = collect(d.memberBlock.members); if !f.isEmpty { out[n] = f }
        }
        let classDecls = AnyClassDeclCollector(viewMode: .sourceAccurate); classDecls.walk(tree)
        for (n, d) in classDecls.classes where out[n] == nil {
            let f = collect(d.memberBlock.members); if !f.isEmpty { out[n] = f }
        }
        return out
    }

    /// SYNTHETIC `.flatStruct` inputs for a view's REACTIVE members that carry a MARSHALLABLE
    /// COLLECTION (`@ObservedObject`/`@StateObject`/`@EnvironmentObject`/`@Environment(T.self) var vm`
    /// whose type has e.g. `items: [Player]`). Registering `vm` as a flat-struct input whose fields
    /// are its marshallable collections lets a `ForEach(vm.items)` lower to a bound guest loop (the
    /// SDK marshals `vm` as a nested object `{"vm":{"items":[…]}}`). The reactive member's SCALAR/
    /// String reads (`vm.isOn`/`vm.title`) keep HOST-PROJECTING (1.6.9, untouched) — they're NOT in
    /// the registered element (the guest never scans them); they must only not DISQUALIFY the input.
    ///
    /// DEMOTE-SAFE GATE: register the input ONLY IF every use of `vm` in the body+helpers is either a
    /// marshalled collection access (ForEach / `.count` / `.isEmpty`) OR a host-projectable scalar/
    /// String read. ANY other use (a bare `vm`, a method call, an unknown/non-collection member) skips
    /// it — the ForEach stays a native slot / the view demotes exactly as before, never a guest-leaking
    /// free identifier. Returns the inputs to MERGE over `viewInputs` (replacing the `.unsupported`
    /// input the reactive member otherwise becomes).
    static func reactiveCollectionInputs(of s: StructDeclSyntax,
                                         collectionShapeCatalog: [String: [StructField]],
                                         scalarFieldCatalog: [String: [String: ViewInput.Kind]],
                                         stringFieldCatalog: [String: [StructField]],
                                         bodyExpr: CodeBlockItemListSyntax,
                                         helperBodies: [CodeBlockItemListSyntax]) -> [ViewInput] {
        var out: [ViewInput] = []
        let scopes = [bodyExpr] + helperBodies
        for (base, info) in Self.reactiveMemberTypesWithKind(of: s) {
            let typeName = info.typeName
            // BUG #8 SAFE-SURFACE GATE: only `@ObservedObject`/`@StateObject` hold their object
            // directly, so the SDK can eagerly marshal them without an uncatchable `wrappedValue`
            // trap. An `@EnvironmentObject`/`@Environment(T.self)`-backed collection is NOT
            // registered as a marshalled input — the SDK refuses to unwrap those (a missing
            // environment object traps), so a registered `{"vm":…}` input would never be supplied
            // and the `ForEach(vm.items)` would render an EMPTY list. Skipping it native-demotes
            // the ForEach instead (demote-safe). The member's scalar/String/collection-guard
            // host-projection is UNAFFECTED — that runs in the thunk natively, not via SDK extract.
            guard info.kind == .held else { continue }
            guard let collectionFields = collectionShapeCatalog[typeName], !collectionFields.isEmpty else { continue }
            // Gate-permitted fields = the marshalled collections + the host-projectable scalar
            // (Bool/Int/Double) + String fields. A `vm.<scalarOrString>` read is fine (host-projected);
            // anything NOT here disqualifies (→ skip, demote-safe).
            var gateFields = collectionFields
            for (f, k) in scalarFieldCatalog[typeName] ?? [:] where !gateFields.contains(where: { $0.name == f }) {
                gateFields.append(StructField(name: f, kind: k))
            }
            for sf in stringFieldCatalog[typeName] ?? [] where !gateFields.contains(where: { $0.name == sf.name }) {
                gateFields.append(StructField(name: sf.name, kind: .string))
            }
            let ok = scopes.allSatisfy {
                FlatStructInputUsageScanner.usesOnlyReconstructableFields($0, name: base, fields: gateFields)
            }
            guard ok else { continue }
            // Register ONLY the collection fields — the guest scans those; scalars/Strings host-project.
            out.append(ViewInput(name: base, kind: .flatStruct, defaultLiteral: "",
                                 structElement: ViewInput.StructElement(typeName: typeName, fields: collectionFields)))
        }
        return out
    }

    /// EVERY type NAME (struct/class/enum) DECLARED in a single source file (top-level +
    /// nested), regardless of whether it yields any catalog entry. Used to compute the
    /// "declared in 2+ files" ambiguity set: a same-name type whose definition in file B
    /// yields NO catalog entry (e.g. its field is a non-String for the String catalog, or a
    /// non-collection for the collection catalog, or a non-scalar for the scalar catalog)
    /// would otherwise EVADE the per-catalog ambiguity drop (which only fires when BOTH files
    /// contribute an entry), leaving file A's entry trusted and a token/marshalling emitted
    /// that won't compile (or wrong-renders) in the file-B view. Tracking declared names
    /// independently of catalog membership closes that no-entry evasion.
    static func declaredTypeNames(in tree: SourceFileSyntax) -> Set<String> {
        var names = Set<String>()
        let structDecls = StructEnumDeclCollectorAll(viewMode: .sourceAccurate)
        structDecls.walk(tree)
        names.formUnion(structDecls.names)
        return names
    }

    /// The set of type names DECLARED (as a struct/class/enum) in 2+ of the given sources.
    /// These names are AMBIGUOUS across files and MUST be dropped from every cross-file
    /// catalog — even a file whose definition produced no catalog entry poisons the name
    /// (the shared root of bugs R2-#17..#20, #59, #60, #61).
    static func crossFileAmbiguousTypeNames(sources: [String]) -> Set<String> {
        var seenInSomeFile = Set<String>()
        var multi = Set<String>()
        for src in sources {
            let tree = Parser.parse(source: src)
            for name in declaredTypeNames(in: tree) {
                if !seenInSomeFile.insert(name).inserted { multi.insert(name) }
            }
        }
        return multi
    }

    /// Generic cross-file catalog merge: first-writer-wins, a genuine SHAPE disagreement
    /// across files drops the name. `dropped` is pre-seeded with the declared-in-2+-files set
    /// so an evasive no-entry file is already excluded.
    static func mergeCatalog<V: Equatable>(_ src: [String: V], into dst: inout [String: V],
                                           _ dropped: inout Set<String>) {
        for (k, v) in src {
            if dropped.contains(k) { dst[k] = nil; continue }
            if let existing = dst[k] {
                if existing != v { dst[k] = nil; dropped.insert(k) }   // ambiguous across files → drop
            } else { dst[k] = v }
        }
    }

    /// Cross-file merge for a `[StructField]` catalog — like `mergeCatalog` but the
    /// ambiguity test is ORDER-INSENSITIVE (a member reorder of a structurally-identical type
    /// is NOT a conflict: bugs R2-#109/#110). The stored value keeps the first file's order
    /// (deterministic); only a genuine field-SET disagreement drops the name.
    static func mergeStructFieldCatalog(_ src: [String: [StructField]],
                                        into dst: inout [String: [StructField]],
                                        _ dropped: inout Set<String>) {
        func canon(_ fs: [StructField]) -> [StructField] { fs.sorted { $0.name < $1.name } }
        for (k, v) in src {
            if dropped.contains(k) { dst[k] = nil; continue }
            if let existing = dst[k] {
                if canon(existing) != canon(v) { dst[k] = nil; dropped.insert(k) }
            } else { dst[k] = v }
        }
    }

    /// Build PROJECT-WIDE type catalogs from ALL of a project's `.swift` SOURCES, for
    /// cross-file type resolution in the per-file SwiftUI lowering (a view in one file
    /// reading a param typed by a struct/enum/`@Model` defined in ANOTHER file). Returns the
    /// merged flat-struct catalog, raw-enum catalog, and host-projectable String-field catalog.
    /// A type NAME that appears in 2+ files (potentially-different shapes) is DROPPED from the
    /// cross-file set — ambiguous, so it stays per-file-only (conservative; a view using it
    /// then demotes as today rather than risk a wrong cross-file shape). The drop fires on the
    /// "declared in 2+ files" set (`crossFileAmbiguousTypeNames`), NOT merely on a catalog-entry
    /// shape conflict — a file whose definition yields no entry for THIS catalog still poisons
    /// the name (closes the no-entry evasion: bugs R2-#17..#20, #59, #60, #61).
    public static func crossFileCatalogs(sources: [String])
        -> (structs: [String: [StructField]], enums: [String: ViewInput.EnumElement],
            stringFields: [String: [StructField]]) {
        // Seed every per-catalog dropped set with the names declared in 2+ files, so a
        // same-name type whose file-B definition yields no entry for THIS catalog can never be
        // inserted from file A (the no-entry evasion). The shape-conflict drop below still
        // covers a same-name type that DOES contribute to both files with divergent shapes.
        let ambiguous = Self.crossFileAmbiguousTypeNames(sources: sources)
        var structs: [String: [StructField]] = [:], droppedS = ambiguous
        var enums: [String: ViewInput.EnumElement] = [:], droppedE = ambiguous
        var strs: [String: [StructField]] = [:], droppedStr = ambiguous
        for src in sources {
            let tree = Parser.parse(source: src)
            Self.mergeStructFieldCatalog(Self.flatStructCatalog(in: tree), into: &structs, &droppedS)
            Self.mergeCatalog(Self.rawEnumCatalog(in: tree), into: &enums, &droppedE)
            Self.mergeStructFieldCatalog(Self.hostProjectableStringFieldCatalog(in: tree), into: &strs, &droppedStr)
        }
        return (structs, enums, strs)
    }

    /// PROJECT-WIDE reactive-member host-projection catalogs (a view's reactive ref-type model
    /// is usually defined in ANOTHER file): the SCALAR-field catalog (type → field → scalar kind,
    /// for `reactiveMemberScalarPaths`) and the COLLECTION-field catalog (type → collection field
    /// names, for `reactiveMemberCollectionPaths`). Same ambiguity rule as `crossFileCatalogs` (a
    /// type defined in 2+ files with DIFFERENT shapes is dropped — conservative). Kept SEPARATE
    /// from `crossFileCatalogs` so existing call sites (and the wire-stable fingerprint path) are
    /// unaffected; the lowering merges these with the per-file catalogs.
    public static func crossFileReactiveCatalogs(sources: [String])
        -> (scalarFields: [String: [String: ViewInput.Kind]], collectionFields: [String: Set<String>]) {
        // Pre-seed both dropped sets with names declared in 2+ files, so a same-name reactive
        // model whose file-B field is non-scalar / non-collection (yielding no entry for the
        // respective catalog) can't be host-projected against file A's shape (bugs R2-#18/#20/#59).
        let ambiguous = Self.crossFileAmbiguousTypeNames(sources: sources)
        var scalars: [String: [String: ViewInput.Kind]] = [:], droppedSc = ambiguous
        var colls: [String: Set<String>] = [:], droppedCo = ambiguous
        for src in sources {
            let tree = Parser.parse(source: src)
            Self.mergeCatalog(Self.scalarFieldCatalog(in: tree), into: &scalars, &droppedSc)
            Self.mergeCatalog(Self.collectionFieldCatalog(in: tree), into: &colls, &droppedCo)
        }
        return (scalars, colls)
    }

    /// PROJECT-WIDE reactive-collection SHAPE catalog (type → marshallable collection fields with
    /// FULLY-RESOLVED element shapes) for cross-file REACTIVE-COLLECTION MARSHALLING — a view's
    /// reactive model class (`@Observable PhraseDatabase` with `sounds: [PhraseSound]`) is
    /// usually in ANOTHER file than the view. Two-phase: (1) build the merged flat-struct catalog
    /// across ALL sources (so an element `PhraseSound` defined anywhere resolves), then (2) build
    /// `reactiveCollectionShapeCatalog` over each source tree USING that merged struct catalog, so the
    /// `.structArray` element fields are baked in. The result is self-contained (no dependency on the
    /// dormant `crossFileStructCatalog` at the lowering site). Same ambiguity rule as the other
    /// cross-file catalogs (a type defined in 2+ files with DIFFERENT collection shapes is DROPPED).
    public static func crossFileReactiveCollectionShapeCatalog(sources: [String]) -> [String: [StructField]] {
        // The drop set fires on "declared (struct/class/enum) in 2+ files" — so a same-name
        // ELEMENT struct whose file-B definition fails reconstruction (yielding no flatStruct
        // entry) still poisons the element shape (bug R2-#17/#61), and a same-name reactive
        // MODEL type whose file-B collection field disqualifies still drops the model entry.
        let ambiguous = Self.crossFileAmbiguousTypeNames(sources: sources)
        // Phase 1: merged flat-struct catalog (element types) across all files.
        var structs: [String: [StructField]] = [:], droppedS = ambiguous
        var trees: [SourceFileSyntax] = []
        for src in sources {
            let tree = Parser.parse(source: src); trees.append(tree)
            Self.mergeStructFieldCatalog(Self.flatStructCatalog(in: tree), into: &structs, &droppedS)
        }
        // Phase 2: shape catalog over all trees, element shapes resolved against the merged structs.
        var out: [String: [StructField]] = [:], droppedC = ambiguous
        for tree in trees {
            Self.mergeStructFieldCatalog(Self.reactiveCollectionShapeCatalog(in: tree, structCatalog: structs),
                                         into: &out, &droppedC)
        }
        return out
    }

    /// The demote-safe CROSS-FILE catalog bundle fed to every per-file lowering so a view's
    /// reactive model + its element structs (usually in OTHER files) resolve. Carries the
    /// host-projection catalogs (scalar/collection/string), the reactive-collection SHAPE catalog
    /// (element shapes pre-resolved), the computed-member catalog, AND the cross-file STRUCT +
    /// ENUM marshalling catalogs (used ONLY in pass 2 of the two-pass lowering — never applied
    /// to a view that already lowers in pass 1, guaranteeing byte-identical output for every
    /// 1.6.35-lowering view). Build BOTH the build and the fingerprint from the SAME bundle
    /// (`crossFileBundle(sources:)` over the same source set) so the auto-routed set the
    /// fingerprint strips matches what the build ships — else a patchable body edit churns.
    public struct CrossFileBundle: Sendable {
        public let stringFields: [String: [StructField]]
        public let scalarFields: [String: [String: ViewInput.Kind]]
        public let collectionFields: [String: Set<String>]
        public let reactiveShapes: [String: [StructField]]
        /// PROJECT-WIDE computed scalar/Font member catalog (type name → member name → token kind).
        /// Enables cross-file resolution of the `<input>.<computedScalar>` host-projection pattern
        /// (e.g. `let size: BadgeSize` in the view file + `enum BadgeSize { var iconSize: CGFloat }`
        /// in a shared `Theme.swift` → `size.iconSize` host-projects as a numeric token).
        public let computedMembers: [String: [String: HostToken.Kind]]
        /// PROJECT-WIDE flat-struct marshalling catalog (type name → flat scalar/string fields).
        /// Enables a view in one file to marshal an input whose type is declared in another file
        /// (e.g. `let plant: Plant` in `PlantRow.swift`, `struct Plant` in `Models/Plant.swift`).
        /// ONLY applied in PASS 2 of the two-pass lowering — never used for a view that already
        /// lowers in pass 1 (exact inertness guarantee). Ambiguity rule: a type declared in 2+
        /// files is dropped. Per-file definitions WIN on a collision.
        public let structs: [String: [StructField]]
        /// PROJECT-WIDE raw-value-enum marshalling catalog (type name → element descriptor).
        /// Same two-pass inertness guarantee + ambiguity rule as `structs`.
        public let enums: [String: ViewInput.EnumElement]
        /// PROJECT-WIDE `@Observable`-non-`@Model` class names, for the `observableStoredProp`
        /// host-projection lever (arm A: plain stored `let/var vm: VM`; arm B: `@Bindable var
        /// vm: VM`). A type declared in 2+ files is dropped (ambiguous, conservative). Enables
        /// cross-file resolution when the `@Observable` class is in another file from the view.
        public let observableClassNames: Set<String>
        /// PROJECT-WIDE `@Model` (SwiftData) class names, for the `modelPlain` host-projection
        /// lever (arm C: plain stored `let item: Item` or `@Bindable var item: Item` where `Item`
        /// is `@Model`). A type declared in 2+ files is dropped (ambiguous, conservative). Enables
        /// cross-file resolution — the @Model class is almost always in a separate file.
        public let modelClassNames: Set<String>
        /// Explicit memberwise init with a default for `modelClassNames` so existing call sites
        /// that don't supply it (e.g. older tests) continue to compile unchanged — they implicitly
        /// get an empty set, which means no @Model scalar projection. This is the safe default:
        /// views that used to demote on @Model members continue to demote (backward-compatible).
        public init(stringFields: [String: [StructField]],
                    scalarFields: [String: [String: ViewInput.Kind]],
                    collectionFields: [String: Set<String>],
                    reactiveShapes: [String: [StructField]],
                    computedMembers: [String: [String: HostToken.Kind]],
                    structs: [String: [StructField]],
                    enums: [String: ViewInput.EnumElement],
                    observableClassNames: Set<String>,
                    modelClassNames: Set<String> = []) {
            self.stringFields = stringFields
            self.scalarFields = scalarFields
            self.collectionFields = collectionFields
            self.reactiveShapes = reactiveShapes
            self.computedMembers = computedMembers
            self.structs = structs
            self.enums = enums
            self.observableClassNames = observableClassNames
            self.modelClassNames = modelClassNames
        }
        public static let empty = CrossFileBundle(stringFields: [:], scalarFields: [:],
                                                  collectionFields: [:], reactiveShapes: [:],
                                                  computedMembers: [:], structs: [:], enums: [:],
                                                  observableClassNames: [], modelClassNames: [])
    }

    /// PROJECT-WIDE computed scalar/Font member catalog across ALL sources, for cross-file
    /// resolution of the `<input>.<computedScalar>` host-projection pattern (a view's struct/enum
    /// input type — e.g. `enum BadgeSize` — defined in ANOTHER file but whose computed members
    /// the thunk evaluates natively via `self.<input>.<member>`). Same ambiguity rule as the
    /// other cross-file catalogs: a type NAME declared in 2+ files is DROPPED from the catalog.
    /// `private`/`fileprivate`/`static` members are excluded in `computedScalarFontMemberCatalog`
    /// itself (the cross-file thunk can't reach private members), so the merge is safe.
    public static func crossFileComputedMemberCatalog(sources: [String]) -> [String: [String: HostToken.Kind]] {
        let ambiguous = Self.crossFileAmbiguousTypeNames(sources: sources)
        var out: [String: [String: HostToken.Kind]] = [:], dropped = ambiguous
        for src in sources {
            let tree = Parser.parse(source: src)
            Self.mergeCatalog(Self.computedScalarFontMemberCatalog(in: tree), into: &out, &dropped)
        }
        return out
    }

    /// Build the cross-file bundle from a project's full source set (model-class files INCLUDED —
    /// they carry the reactive collections). One call, so the build + the fingerprint construct
    /// IDENTICAL catalogs from the same sources.
    public static func crossFileBundle(sources: [String]) -> CrossFileBundle {
        let catalogs = Self.crossFileCatalogs(sources: sources)   // struct + enum + stringFields
        let reactive = Self.crossFileReactiveCatalogs(sources: sources)
        return CrossFileBundle(
            stringFields: catalogs.stringFields,
            scalarFields: reactive.scalarFields,
            collectionFields: reactive.collectionFields,
            reactiveShapes: Self.crossFileReactiveCollectionShapeCatalog(sources: sources),
            computedMembers: Self.crossFileComputedMemberCatalog(sources: sources),
            structs: catalogs.structs,
            enums: catalogs.enums,
            observableClassNames: Self.crossFileObservableClassNames(sources: sources),
            modelClassNames: Self.crossFileModelClassNames(sources: sources))
    }

    /// Lower all views in `source` with a cross-file `bundle` — the convenience the build + the
    /// fingerprint both use so they pass IDENTICAL cross-file catalogs.
    ///
    /// TWO-PASS INERTNESS DESIGN:
    /// - Pass 1 lowers WITHOUT the cross-file struct/enum marshalling catalogs (i.e. exactly
    ///   the 1.6.35 behavior — the host-projection string/scalar/computed + reactive-shape
    ///   catalogs stay AS-IS; only the new struct+enum marshalling catalogs are withheld).
    ///   If a view lowers in pass 1 (not `referencesUnmarshalledInput`), its result is used
    ///   verbatim and pass 2 is NEVER run for it. This guarantees byte-identical output for
    ///   every view that already lowered in 1.6.35 — the provable inertness guarantee.
    /// - Pass 2 runs only for views that DEMOTED in pass 1 (i.e. `referencesUnmarshalledInput
    ///   == true`). It retries WITH the cross-file struct/enum catalogs. If the view lowers
    ///   in pass 2, that result replaces the demote. If pass 2 also demotes, the pass-1 result
    ///   is kept (consistent demote behavior). The cross-file struct/enum catalogs thus ONLY
    ///   ever change a previously-demoting view → they can never alter a previously-lowering view.
    public func lowerAllViews(source: String, sameFileThunk: Bool = true,
                              crossFile bundle: CrossFileBundle) -> [LoweredView] {
        // PASS 1 — exact 1.6.35 behavior (no cross-file struct/enum marshalling catalogs).
        let pass1 = lowerAllViews(source: source, sameFileThunk: sameFileThunk,
                                  crossFileStringFieldCatalog: bundle.stringFields,
                                  crossFileScalarFieldCatalog: bundle.scalarFields,
                                  crossFileCollectionFieldCatalog: bundle.collectionFields,
                                  crossFileReactiveCollectionShapeCatalog: bundle.reactiveShapes,
                                  crossFileComputedMemberCatalog: bundle.computedMembers,
                                  crossFileObservableClassNames: bundle.observableClassNames,
                                  crossFileModelClassNames: bundle.modelClassNames)
        // Early-exit: if the bundle has no cross-file struct/enum catalogs, or no view demoted,
        // skip pass 2 entirely (the common path — no allocation overhead).
        let demoterNames = pass1.filter { $0.referencesUnmarshalledInput }.map(\.viewName)
        guard !demoterNames.isEmpty,
              (!bundle.structs.isEmpty || !bundle.enums.isEmpty) else { return pass1 }
        // PASS 2 — retry only needed when at least one view demoted AND the bundle carries
        // cross-file struct/enum catalogs. Run the whole-file lowering again WITH those catalogs
        // (the non-demoting views produce byte-identical results since their inputs already
        // resolved in pass 1; we discard their pass-2 output to preserve the inertness invariant).
        let pass2 = lowerAllViews(source: source, sameFileThunk: sameFileThunk,
                                  crossFileStructCatalog: bundle.structs,
                                  crossFileEnumCatalog: bundle.enums,
                                  crossFileStringFieldCatalog: bundle.stringFields,
                                  crossFileScalarFieldCatalog: bundle.scalarFields,
                                  crossFileCollectionFieldCatalog: bundle.collectionFields,
                                  crossFileReactiveCollectionShapeCatalog: bundle.reactiveShapes,
                                  crossFileComputedMemberCatalog: bundle.computedMembers,
                                  crossFileObservableClassNames: bundle.observableClassNames,
                                  crossFileModelClassNames: bundle.modelClassNames)
        // MERGE: for each view, use pass-1 result UNLESS it demoted AND pass 2 produced a
        // non-demoting result. This is the inertness invariant in code — a view that ALREADY
        // lowers in pass 1 is NEVER replaced with a pass-2 result (even if pass 2 also lowers).
        let demoterNameSet = Set(demoterNames)
        let pass2ByName = Dictionary(pass2.map { ($0.viewName, $0) }, uniquingKeysWith: { f, _ in f })
        return pass1.map { p1 in
            guard demoterNameSet.contains(p1.viewName),
                  let p2 = pass2ByName[p1.viewName],
                  !p2.referencesUnmarshalledInput else { return p1 }
            return p2
        }
    }

    /// The maximum struct-nesting depth the guest reconstructs (matches the SDK
    /// encoder's bounded recursion — a deeper graph drops out and the view demotes).
    static let maxStructNestingDepth = 6

    /// Resolve a struct type's recursive field shapes, or nil if any field is not
    /// guest-reconstructable (which disqualifies the whole struct). `visiting` is the
    /// in-flight type chain for cycle detection (a recursive/mutually-recursive struct
    /// disqualifies — the guest can't bound it). De-dups by name first-seen.
    static func resolveStructFields(_ typeName: String,
                                    structDecls: [String: StructDeclSyntax],
                                    enumCatalog: [String: ViewInput.EnumElement],
                                    visiting: [String]) -> [StructField]? {
        guard visiting.count < maxStructNestingDepth else { return nil }
        guard !visiting.contains(typeName) else { return nil }   // cycle → disqualify
        guard let s = structDecls[typeName] else { return nil }
        let nextVisiting = visiting + [typeName]
        var fields: [StructField] = []
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            if v.modifiers.contains(where: {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }) { continue }
            for binding in v.bindings {
                if binding.accessorBlock != nil { continue }   // computed → not stored
                let name = binding.pattern.trimmedDescription
                guard !name.isEmpty else { continue }
                let typeText = binding.typeAnnotation?.type.trimmedDescription
                let defaultExpr = binding.initializer?.value.trimmedDescription
                guard let shape = resolveFieldShape(typeAnnotation: typeText, defaultExpr: defaultExpr,
                                                    structDecls: structDecls, enumCatalog: enumCatalog,
                                                    visiting: nextVisiting) else {
                    return nil   // a non-reconstructable field disqualifies the struct
                }
                fields.append(StructField(name: name, shape: shape))
            }
        }
        return fields.isEmpty ? nil : fields
    }

    /// The recursive guest-reconstructable SHAPE of a stored field, or nil if it isn't
    /// one (which disqualifies the owning struct). Handles scalars, nested structs,
    /// raw-value enums, scalar arrays, arrays-of-qualifying-struct, and
    /// `[String:Scalar]` dictionaries — recursively, bounded by `visiting`.
    static func resolveFieldShape(typeAnnotation: String?, defaultExpr: String?,
                                  structDecls: [String: StructDeclSyntax],
                                  enumCatalog: [String: ViewInput.EnumElement],
                                  visiting: [String]) -> FieldShape? {
        // Without a declared type we can only infer SCALAR shapes from a literal default.
        guard let raw = typeAnnotation?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            if let k = scalarFieldKind(typeAnnotation: nil, defaultExpr: defaultExpr) {
                return .scalar(k)
            }
            return nil
        }
        // An OPTIONAL field. An optional SCALAR (`String?`/`Int?`/`Bool?`/`Double?`) IS
        // reconstructable: the SDK marshals `.some(x)` as the bare scalar / `.none` as
        // `null` (or omits the key), and the guest decodes a `T?` (missing/null → nil).
        // A demote-safe body gate then requires it be used only optionally (`?? d`/`==nil`).
        // An optional STRUCT / array / dict / enum still disqualifies — the guest can't
        // prove a safe unwrap of a richer shape (those are rarer; demote-safe over wrong).
        if let optInner = Self.optionalInnerType(raw) {
            if let sk = scalarFieldKind(typeAnnotation: optInner, defaultExpr: nil) {
                return .optionalScalar(sk)
            }
            return nil
        }
        // 1) Scalar.
        if let k = scalarFieldKind(typeAnnotation: raw, defaultExpr: defaultExpr) {
            return .scalar(k)
        }
        // 2) Array — `[Elem]` / `Array<Elem>`.
        if let elem = arrayElementTypeText(raw) {
            // 2a) Array of a scalar element (`[Int]`).
            if let sk = scalarFieldKind(typeAnnotation: elem, defaultExpr: nil) {
                return .scalarArray(sk)
            }
            // 2b) Array of a qualifying nested struct (`[SubStruct]`).
            if let nested = resolveStructFields(elem, structDecls: structDecls,
                                                enumCatalog: enumCatalog, visiting: visiting) {
                return .structArray(ViewInput.StructElement(typeName: elem, fields: nested))
            }
            return nil
        }
        // 3) Dictionary — `[String:Scalar]` (a JSON object of scalar values).
        if let valScalar = stringKeyedScalarDictValue(raw) {
            return .scalarDictionary(valScalar)
        }
        // 3b) Dictionary — `[String:SubStruct]` where SubStruct qualifies recursively
        // (the SDK marshals a String-keyed dict as a JSON object; here every VALUE is a
        // nested struct object). A non-qualifying value type / non-String key → not here.
        if let valStructType = stringKeyedDictValueType(raw),
           let nested = resolveStructFields(valStructType, structDecls: structDecls,
                                            enumCatalog: enumCatalog, visiting: visiting) {
            return .structDictionary(ViewInput.StructElement(typeName: valStructType, fields: nested))
        }
        // 4) A raw-value enum in the catalog.
        if let el = enumCatalog[raw] { return .enumValue(el) }
        // 5) A NESTED struct that itself qualifies.
        if let nested = resolveStructFields(raw, structDecls: structDecls,
                                            enumCatalog: enumCatalog, visiting: visiting) {
            return .structValue(ViewInput.StructElement(typeName: raw, fields: nested))
        }
        return nil   // not guest-reconstructable
    }

    /// If `type` is an array type (`[Elem]` / `Array<Elem>`), the element TYPE TEXT;
    /// else nil. (Element may itself be a struct — the caller resolves it.)
    static func arrayElementTypeText(_ type: String) -> String? {
        let t = type.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("["), t.hasSuffix("]"), !t.contains(":") {
            let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            return simpleTypeName(inner) ? inner : nil
        }
        if t.hasPrefix("Array<"), t.hasSuffix(">") {
            let inner = String(t.dropFirst("Array<".count).dropLast()).trimmingCharacters(in: .whitespaces)
            return simpleTypeName(inner) ? inner : nil
        }
        return nil
    }

    /// If `type` is a `[String:Scalar]` / `Dictionary<String,Scalar>`, the VALUE scalar
    /// kind; else nil. (Only String-keyed scalar-valued dictionaries — the SDK marshals
    /// these as a JSON object the guest can decode by key.)
    static func stringKeyedScalarDictValue(_ type: String) -> ViewInput.Kind? {
        let t = type.trimmingCharacters(in: .whitespaces)
        var keyVal: (String, String)?
        if t.hasPrefix("["), t.hasSuffix("]"), let colon = t.dropFirst().dropLast().firstIndex(of: ":") {
            let body = t.dropFirst().dropLast()
            let key = String(body[body.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            keyVal = (key, val)
        } else if t.hasPrefix("Dictionary<"), t.hasSuffix(">") {
            let body = String(t.dropFirst("Dictionary<".count).dropLast())
            if let comma = body.firstIndex(of: ",") {
                let key = String(body[body.startIndex..<comma]).trimmingCharacters(in: .whitespaces)
                let val = String(body[body.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                keyVal = (key, val)
            }
        }
        guard let (key, val) = keyVal, key == "String" else { return nil }
        return scalarFieldKind(typeAnnotation: val, defaultExpr: nil)
    }

    /// If `type` is a `[String:SimpleType]` / `Dictionary<String,SimpleType>` whose VALUE
    /// is a bare simple type name (NOT a scalar, NOT a nested generic), the value type
    /// name; else nil. The caller checks that the value type qualifies as a struct. (A
    /// scalar-valued dict is handled by `stringKeyedScalarDictValue` first.)
    static func stringKeyedDictValueType(_ type: String) -> String? {
        let t = type.trimmingCharacters(in: .whitespaces)
        var keyVal: (String, String)?
        if t.hasPrefix("["), t.hasSuffix("]"), let colon = t.dropFirst().dropLast().firstIndex(of: ":") {
            let body = t.dropFirst().dropLast()
            let key = String(body[body.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            keyVal = (key, val)
        } else if t.hasPrefix("Dictionary<"), t.hasSuffix(">") {
            let body = String(t.dropFirst("Dictionary<".count).dropLast())
            if let comma = body.firstIndex(of: ",") {
                let key = String(body[body.startIndex..<comma]).trimmingCharacters(in: .whitespaces)
                let val = String(body[body.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                keyVal = (key, val)
            }
        }
        guard let (key, val) = keyVal, key == "String", simpleTypeName(val) else { return nil }
        // A scalar value is NOT a struct dict — those are handled earlier.
        if scalarFieldKind(typeAnnotation: val, defaultExpr: nil) != nil { return nil }
        return val
    }

    /// True iff `t` is a bare simple type name (`Player`, not `[X]`/`X?`/a generic).
    static func simpleTypeName(_ t: String) -> Bool {
        !t.isEmpty && t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// If `type` is an OPTIONAL (`T?` or `Optional<T>`), the inner type text `T`; else nil.
    /// (A nested optional `T??` returns `T?` — the caller then sees a non-scalar inner and
    /// disqualifies, since the guest can't prove a double-unwrap shape.)
    static func optionalInnerType(_ type: String) -> String? {
        let t = type.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("?") {
            return String(t.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if t.hasPrefix("Optional<"), t.hasSuffix(">") {
            return String(t.dropFirst("Optional<".count).dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// A field's SCALAR kind (`.string`/`.bool`/`.int`/`.double`), or nil if it isn't
    /// a plain scalar/string (so the owning struct is not guest-reconstructable). Only
    /// the declared type is trusted for a struct field; an inferred-from-default kind
    /// is allowed when there's no annotation (a `var name = "x"` flat field).
    private static func scalarFieldKind(typeAnnotation: String?, defaultExpr: String?) -> ViewInput.Kind? {
        if let t = typeAnnotation {
            switch t {
            case "String": return .string
            case "Bool": return .bool
            case "Int": return .int
            case "Double", "CGFloat": return .double
            default: return nil   // an array/optional/nested/custom field disqualifies
            }
        }
        if let d = defaultExpr {
            if d == "true" || d == "false" { return .bool }
            if d.hasPrefix("\"") { return .string }
            if d.contains("."), Double(d) != nil { return .double }
            if Int(d) != nil { return .int }
        }
        return nil
    }

    /// If `type` is an array of a single scalar element (`[Int]`, `[String]`,
    /// `Array<Double>`, `[Bool]`, `[CGFloat]`), the matching array kind; else nil.
    /// The guest can reconstruct these, so the body reads the REAL array.
    static func arrayElementKind(_ type: String) -> ViewInput.Kind? {
        let t = type.trimmingCharacters(in: .whitespaces)
        let element: String?
        if t.hasPrefix("["), t.hasSuffix("]") {
            element = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        } else if t.hasPrefix("Array<"), t.hasSuffix(">") {
            element = String(t.dropFirst("Array<".count).dropLast()).trimmingCharacters(in: .whitespaces)
        } else {
            element = nil
        }
        switch element {
        case "String": return .stringArray
        case "Bool": return .boolArray
        case "Int": return .intArray
        case "Double", "CGFloat": return .doubleArray
        default: return nil
        }
    }

    private static func defaultLiteral(kind: ViewInput.Kind, declared: String?) -> String {
        // The guest emitter bakes this in VERBATIM as the `?? <default>` fallback. The
        // SDK always marshals the live value in, so the fallback only matters at compile
        // time — but it MUST compile. A declared default that references a FREE
        // identifier the guest can't resolve (`Locale.current.region?…`, a computed
        // property, an app global) would be `cannot find 'X' in scope` and demote the
        // WHOLE module. When the declared default isn't guest-safe, fall back to the
        // type-appropriate ZERO (the host supplies the real value at runtime regardless),
        // so a view with such an input still ships instead of excluding on its default.
        if let d = declared, Self.defaultLiteralIsGuestSafe(d) {
            if kind == .int {
                // An Int default outside Int32 range overflows the 32-bit wasm guest at
                // COMPILE time → the whole module fails. Keep the literal only when it
                // provably fits Int32 (a decimal literal in range); otherwise fall through to
                // the zero default. The SDK marshals the real value in at runtime, so the
                // compile-time fallback is correctness-neutral.
                let cleaned = d.replacingOccurrences(of: "_", with: "")
                if let n = Int64(cleaned), n >= Int64(Int32.min), n <= Int64(Int32.max) { return d }
            } else {
                return d
            }
        }
        switch kind {
        case .string: return "\"\""
        case .bool: return "false"
        case .int: return "0"
        case .double: return "0"
        case .stringArray, .boolArray, .intArray, .doubleArray, .structArray: return "[]"
        // `.flatStruct`/`.enumValue` build their ViewInput directly (defaultLiteral "");
        // the guest binding uses a `?? _PatchRow_<Type>()` / `?? .<firstCase>` fallback,
        // so this branch is unused for them — return "" defensively.
        case .flatStruct, .enumValue: return ""
        case .unsupported: return "\"\""   // best-effort; unused for unsupported binds
        }
    }

    /// Whether a declared input default literal is safe to bake into the guest binding
    /// verbatim — i.e. it references NO free identifier the guest scope can't resolve
    /// (only literals + Swift/IR safe globals). A default referencing a Foundation type
    /// (`Locale`/`TimeZone`/`Date`/`UUID`/…), an app global, or a computed property is
    /// NOT safe (it would fail the guest compile) → the caller substitutes the zero
    /// default (the host marshals the live value in at runtime, so nothing is lost).
    static func defaultLiteralIsGuestSafe(_ declared: String) -> Bool {
        let t = declared.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        // Reuse the guest scope-check's free-identifier scan with NO in-scope inputs:
        // only safe globals + literals are allowed (a default referencing another input
        // is unusual and conservatively treated as unsafe → zero default, still correct).
        let r = SwiftUIGuestScopeCheck.check(
            guestBody: t, inputNames: [], usesGeometry: false)
        guard r.isCompilable else { return false }
        // The scope-check only catches a FREE IDENTIFIER. A method/function CALL whose
        // BASE is a literal passes it (no free identifier) yet can still reference a method
        // the Foundation-FREE guest LACKS — e.g. a custom `String.image()` extension
        // (`?? "🥇".image()`), a `Date()`/`UUID()` initializer, a `.formatted(…)` call.
        // Baked verbatim, it fails the guest compile and convergence-drops the WHOLE view.
        // The default is DEAD CODE (the SDK always marshals the live value in — the `??`
        // fallback only matters at compile time), so a CALL anywhere in it makes it unsafe
        // → the caller substitutes the type-appropriate ZERO (correctness-neutral). A
        // guest-safe scalar default is a literal / member-access / operator expression with
        // NO call, so this leaves the common case untouched.
        return !Self.defaultExprContainsCall(t)
    }

    /// True iff the (already free-identifier-clean) default expression contains a
    /// function/method CALL anywhere — the residual guest-compile hazard for a default
    /// whose base is a literal (see `defaultLiteralIsGuestSafe`). Conservative: any call
    /// (even a guest-safe `Int(x)`) marks the default unsafe, which only substitutes the
    /// dead-code zero — never a regression.
    private static func defaultExprContainsCall(_ src: String) -> Bool {
        let tree = Parser.parse(source: "let __patch_default_call_probe = (\(src))")
        let finder = _DefaultCallFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        return finder.found
    }

    // MARK: - Locating the view + its body

    struct FoundView { var name: String; var decl: StructDeclSyntax }

    private func allViews(in tree: SourceFileSyntax) -> [FoundView] {
        var found: [FoundView] = []
        for stmt in tree.statements {
            guard let s = stmt.item.as(StructDeclSyntax.self) else { continue }
            // A generic view carrying a `where` clause (`struct Row<T>: View where T: …`) is
            // EXCLUDED from lowering — `ThunkGenerator.discover` likewise excludes it from thunk
            // generation (no `dynamic` body, no `@_dynamicReplacement`). Were the engine to lower +
            // ship it thunkSafe while no thunk exists, the fingerprint would strip its body yet it
            // would render NATIVE (false-stable + coverage-loss: bug R2-#62). Match the predicate.
            if s.genericParameterClause != nil, s.genericWhereClause != nil { continue }
            if conformsToView(s) {
                found.append(FoundView(name: s.name.text, decl: s))
            }
        }
        return found
    }

    private func firstView(in tree: SourceFileSyntax) -> FoundView? {
        allViews(in: tree).first
    }

    private func conformsToView(_ s: StructDeclSyntax) -> Bool {
        guard let inh = s.inheritanceClause else { return false }
        return inh.inheritedTypes.contains { t in
            t.type.trimmedDescription == "View"
        }
    }

    /// The body's CodeBlock — the var body computed getter, or func body() body.
    private func bodyExpression(of s: StructDeclSyntax) -> CodeBlockItemListSyntax? {
        for member in s.memberBlock.members {
            // var body: some View { … }
            if let v = member.decl.as(VariableDeclSyntax.self) {
                for binding in v.bindings {
                    guard binding.pattern.trimmedDescription == "body" else { continue }
                    if let accessors = binding.accessorBlock {
                        switch accessors.accessors {
                        case .getter(let items): return items
                        case .accessors(let list):
                            for acc in list where acc.accessorSpecifier.text == "get" {
                                if let b = acc.body { return b.statements }
                            }
                        }
                    }
                }
            }
        }
        return nil
    }
}

/// Finds the first `ArrayExprSyntax` (`[…]` literal) in a parsed snippet — used to
/// inspect an array-literal default's elements for unambiguous kind inference.
final class ArrayLiteralFinder: SwiftSyntax.SyntaxVisitor {
    private(set) var found: ArrayExprSyntax?
    static func firstArray(in tree: SourceFileSyntax) -> ArrayExprSyntax? {
        let f = ArrayLiteralFinder(viewMode: .sourceAccurate)
        f.walk(tree)
        return f.found
    }
    override func visit(_ node: ArrayExprSyntax) -> SyntaxVisitorContinueKind {
        if found == nil { found = node }
        return .skipChildren
    }
}

/// Walks a source file collecting every STRUCT decl by name (top-level + nested), so
/// the recursive field resolver (`resolveStructFields`) can look a nested field's type
/// up. On a name COLLISION (two structs named the same) the name is DROPPED — the field
/// shapes might differ, and emitting one guest struct for an ambiguous name is unsafe,
/// so any input of that type stays `.unsupported` (faithful native demote). This
/// replaces the old `FlatStructCollector` (which resolved scalar-only fields inline);
/// resolution is now a separate two-phase step that can recurse into nested types.
final class StructEnumDeclCollector: SwiftSyntax.SyntaxVisitor {
    private(set) var structDecls: [String: StructDeclSyntax] = [:]
    private var droppedNames = Set<String>()
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        if droppedNames.contains(name) {
            // already known-ambiguous
        } else if structDecls[name] != nil {
            structDecls[name] = nil; droppedNames.insert(name)   // ambiguous duplicate
        } else {
            structDecls[name] = node
        }
        return .visitChildren   // recurse into nested struct decls
    }
}

/// Walks a source file collecting EVERY type NAME declared (struct/class/enum, top-level +
/// nested), regardless of shape or duplicate-within-file. Used to compute the cross-file
/// "declared in 2+ files" ambiguity set independently of any catalog's membership — so a
/// same-name type whose definition yields NO catalog entry still poisons the name (closes
/// the no-entry evasion behind the cross-file same-name catalog bugs).
final class StructEnumDeclCollectorAll: SwiftSyntax.SyntaxVisitor {
    private(set) var names = Set<String>()
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text); return .visitChildren
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text); return .visitChildren
    }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text); return .visitChildren
    }
    // A `typealias Player = Account` (or a same-name `actor`) SHADOWS a same-name struct in
    // another file: it makes `Player` resolve to a DIFFERENT type than file B's struct shape.
    // Recording its declared name here poisons the cross-file ambiguity set so the wrong
    // file's shape can never be host-projected against an alias'd/actor'd same name (a
    // mis-typed `.string`/`.number` token thunk that the parse-only gate would otherwise ship).
    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text); return .visitChildren
    }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text); return .visitChildren
    }
}

/// Walks a source file collecting ALL class decls (name → decl), for host-projecting a
/// reference-type model's `String` fields (`page.title` where `page: SomeModelClass`). A
/// name collision drops the entry (ambiguous → no projection, safe). Visits nested classes.
final class AnyClassDeclCollector: SwiftSyntax.SyntaxVisitor {
    private(set) var classes: [String: ClassDeclSyntax] = [:]
    private var dropped = Set<String>()
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        if dropped.contains(name) {
            // already known-ambiguous
        } else if classes[name] != nil {
            classes[name] = nil; dropped.insert(name)
        } else {
            classes[name] = node
        }
        return .visitChildren
    }
}

/// Walks a source file collecting the names of `@Observable`-annotated CLASS declarations
/// that are NOT also annotated with `@Model`. These are the "plain observable view-model"
/// classes whose scalar/String fields can be host-projected via the `observableStoredProp`
/// lever (arm A and arm B of `reactiveMemberTypesWithKind`).
///
/// A name collision (two `@Observable` classes with the same name in one file) drops the
/// entry — ambiguous, conservative. `@Model` classes are excluded even if they also carry
/// `@Observable` (SwiftData's ObjC-backed store can't be host-projected through WASM).
final class ObservableClassCollector: SwiftSyntax.SyntaxVisitor {
    private(set) var names = Set<String>()
    private var dropped = Set<String>()
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        guard !dropped.contains(name) else { return .visitChildren }
        var hasObservable = false
        var hasModel = false
        for attr in node.attributes {
            guard let a = attr.as(AttributeSyntax.self) else { continue }
            let n = a.attributeName.trimmedDescription
            if n == "Observable" { hasObservable = true }
            if n == "Model" { hasModel = true }
        }
        guard hasObservable && !hasModel else { return .visitChildren }
        if names.contains(name) {
            // Second class with the same name in this file — drop both (ambiguous).
            names.remove(name); dropped.insert(name)
        } else {
            names.insert(name)
        }
        return .visitChildren
    }
}

/// Walks a source file collecting the names of `@Model`-annotated CLASS declarations (SwiftData).
/// These are the SwiftData model objects whose SCALAR (Int/Bool/Double) fields can be
/// host-projected via ARM (C) of `reactiveMemberTypesWithKind` (the `modelPlain` kind).
///
/// A name collision (two `@Model` classes with the same name in one file) drops the entry
/// — ambiguous, conservative. A class annotated with BOTH `@Model` and `@Observable` IS
/// included (it qualifies for the @Model host-projection arm, not the @Observable arm).
final class ModelClassCollector: SwiftSyntax.SyntaxVisitor {
    private(set) var names = Set<String>()
    private var dropped = Set<String>()
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        guard !dropped.contains(name) else { return .visitChildren }
        var hasModel = false
        for attr in node.attributes {
            guard let a = attr.as(AttributeSyntax.self) else { continue }
            if a.attributeName.trimmedDescription == "Model" { hasModel = true; break }
        }
        guard hasModel else { return .visitChildren }
        if names.contains(name) {
            // Second @Model class with the same name in this file — drop both (ambiguous).
            names.remove(name); dropped.insert(name)
        } else {
            names.insert(name)
        }
        return .visitChildren
    }
}

/// Walks a source file collecting ALL enum decls (name → decl), for host-projecting an
/// enum param's `String`-returning members (`accent.rawValue` on a `String`-raw enum, or a
/// computed `var icon: String`). A name collision drops the entry (ambiguous, safe).
final class AnyEnumDeclCollector: SwiftSyntax.SyntaxVisitor {
    private(set) var enums: [String: EnumDeclSyntax] = [:]
    private var dropped = Set<String>()
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        if dropped.contains(name) {
            // already known-ambiguous
        } else if enums[name] != nil {
            enums[name] = nil; dropped.insert(name)
        } else {
            enums[name] = node
        }
        return .visitChildren
    }
}

/// Walks a source file collecting RAW-VALUE enum decls (String/Int raw, all-bare cases)
/// → their element descriptor, for `.enumValue` reconstruction (TASK 2). Visits nested
/// enums too. A name collision DROPS the entry (ambiguous shape → the input stays
/// `.unsupported`, faithful native demote).
final class RawEnumCollector: SwiftSyntax.SyntaxVisitor {
    private(set) var rawEnums: [String: BodyLowering.ViewInput.EnumElement] = [:]
    private var seenNames = Set<String>()
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        if seenNames.insert(name).inserted {
            if let el = BodyLowering.rawEnumElement(node) { rawEnums[name] = el }
        } else {
            rawEnums[name] = nil   // ambiguous duplicate → drop
        }
        return .visitChildren   // recurse into nested enum decls
    }
}

/// Shared chain-extraction + whole-collection-position helpers for the rich-struct usage
/// gates (`FlatStructInputUsageScanner` here + `ElementUsageScanner` in the emitter).
/// Given a base `DeclReferenceExpr` named `input`, climb the OUTERMOST chain of plain
/// `.member` accesses (`input.a.b.c`) and classify whether the terminal value is used
/// guest-safely against the struct's recursive field shapes.
enum RichStructChain {
    /// Climb `input.f1.f2…` collecting the member names (outermost-first). Returns the
    /// chain plus the OUTERMOST member-access node (the whole `input.f1.f2` expression)
    /// so the caller can inspect how the terminal value is used. A NON-`.member` parent
    /// (a bare `input` passed somewhere) yields an empty chain.
    static func climb(base node: DeclReferenceExprSyntax) -> (chain: [String], outer: MemberAccessExprSyntax?) {
        var chain: [String] = []
        var cur: MemberAccessExprSyntax? = node.parent?.as(MemberAccessExprSyntax.self)
        var outer: MemberAccessExprSyntax? = nil
        // The first member access must have `node` as its base (`input.f1`).
        guard let first = cur, first.base?.id == node.id else { return ([], nil) }
        chain.append(first.declName.baseName.text)
        outer = first
        // Keep climbing while the parent is a member access whose base is the current node.
        while let o = outer,
              let parent = o.parent?.as(MemberAccessExprSyntax.self),
              parent.base?.id == o.id {
            chain.append(parent.declName.baseName.text)
            outer = parent
        }
        return (chain, outer)
    }

    /// True iff the member-access expression `outer` (the terminal `input.f1…fn`) is used
    /// only in a WHOLE-COLLECTION position the guest supports: as the collection argument
    /// of a `ForEach(...)` / `List(...)`, or as the base of `.count`/`.isEmpty`/`.first`/
    /// `.last`. (A scalar array / dictionary value can ride those; anything else can't.)
    static func usedAsWholeCollection(_ outer: MemberAccessExprSyntax) -> Bool {
        // `.count` / `.isEmpty` / `.first` / `.last` on the collection.
        if let m = outer.parent?.as(MemberAccessExprSyntax.self), m.base?.id == outer.id {
            switch m.declName.baseName.text {
            case "count", "isEmpty", "first", "last": return true
            default: return false
            }
        }
        // A direct argument of a `ForEach(...)` / `List(...)` call.
        if let arg = outer.parent?.as(LabeledExprSyntax.self),
           let call = arg.parent?.as(LabeledExprListSyntax.self)?.parent?.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
           callee == "ForEach" || callee == "List" {
            return true
        }
        return false
    }

    /// True iff the terminal optional-scalar read `outer` (`input.subtitle`, type `T?`) is
    /// used in a position the guest can faithfully reconstruct WITHOUT proving a non-nil
    /// unwrap: the LHS of a `??` coalesce (`input.subtitle ?? "x"`), or an `== nil` /
    /// `!= nil` comparison. A bare read, a force-unwrap (`input.subtitle!`), optional-chain
    /// (`input.subtitle?.count`), or `if let` binding all return false → the input demotes
    /// (faithful over a wrong default). `if let` is excluded because the lowered body would
    /// need to bind+conditionally-render the unwrapped value, which the gate doesn't model.
    static func usedAsOptionalScalar(_ outer: MemberAccessExprSyntax) -> Bool {
        // Reject an OPTIONAL-CHAIN (`input.subtitle?.count`) or FORCE-UNWRAP
        // (`input.subtitle!`) on the optional — the immediate parent is an
        // `OptionalChainingExpr` / `ForcedValueExpr`. Those access THROUGH the optional,
        // which the guest can't reconstruct (`String?.count` isn't the marshalled shape).
        if outer.parent?.is(OptionalChainingExprSyntax.self) == true
            || outer.parent?.is(ForcedValueExprSyntax.self) == true {
            return false
        }
        // `input.subtitle ?? <default>` — the optional is the LHS of a `??` in a folded
        // or unfolded sequence. The parser doesn't fold operators, so `a ?? b` is a
        // SequenceExpr [a, ??, b]. Walk up to a SequenceExpr containing a `??` operator.
        var node: Syntax = Syntax(outer)
        while let parent = node.parent {
            if let seq = parent.as(SequenceExprSyntax.self) {
                let hasCoalesce = seq.elements.contains {
                    $0.as(BinaryOperatorExprSyntax.self)?.operator.text == "??"
                }
                let hasNilEq = seq.elements.contains {
                    let op = $0.as(BinaryOperatorExprSyntax.self)?.operator.text
                    return op == "==" || op == "!="
                } && seq.elements.contains { $0.as(NilLiteralExprSyntax.self) != nil }
                if hasCoalesce || hasNilEq { return true }
                return false
            }
            // Stop climbing once we leave simple expression nesting (a tuple/paren is fine
            // to pass through; anything statement-level is not an optional-use position).
            if parent.as(TupleExprElementListSyntax.self) != nil
                || parent.as(LabeledExprListSyntax.self) != nil {
                return false   // passed as an argument bare → not provably safe
            }
            node = parent
        }
        return false
    }
}

/// Verifies that, across a WHOLE view body, a SINGLE struct input is used ONLY in a
/// guest-reconstructable way against its RECURSIVE field shapes (the rich-input gate). A
/// member chain `input.f1…fn` is allowed iff it resolves (through nested structs) to a
/// SCALAR leaf, or to a scalar-array/dictionary used only as a whole collection (a
/// `ForEach`/`.count`). A bare `input`, a method call, an unknown field, or a nested
/// struct/value used whole sets `ok = false` → the input is downgraded to `.unsupported`
/// (the view stays native — faithful over a wrong/partial reconstruction).
final class FlatStructInputUsageScanner: SwiftSyntax.SyntaxVisitor {
    private let name: String
    private let fields: [BodyLowering.StructField]
    private(set) var ok = true
    private init(name: String, fields: [BodyLowering.StructField]) {
        self.name = name; self.fields = fields
        super.init(viewMode: .sourceAccurate)
    }
    static func usesOnlyReconstructableFields(_ stmts: CodeBlockItemListSyntax,
                                              name: String,
                                              fields: [BodyLowering.StructField]) -> Bool {
        let s = FlatStructInputUsageScanner(name: name, fields: fields)
        for item in stmts { s.walk(item) }
        return s.ok
    }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.baseName.text == name else { return .visitChildren }
        // Skip a `.member` selector that merely SHARES the name (`.item` in `Foo.item`).
        if let parent = node.parent?.as(MemberAccessExprSyntax.self), parent.declName.id == node.id {
            return .visitChildren
        }
        let (chain, outer) = RichStructChain.climb(base: node)
        guard !chain.isEmpty, let outer else {
            ok = false; return .skipChildren   // a bare `input` use — not provable
        }
        switch BodyLowering.resolveFieldChain(chain, fields: fields) {
        case .scalarLeaf:
            return .visitChildren   // `input.address.city` — fine
        case .collection:
            // A scalar array / dictionary value — safe only as a whole collection.
            if RichStructChain.usedAsWholeCollection(outer) { return .visitChildren }
            ok = false; return .skipChildren
        case .optionalScalarLeaf:
            // An optional scalar (`input.subtitle`, type `T?`) — safe only in an optional
            // position (`?? default`, `== nil`/`!= nil`); a bare read / unwrap demotes.
            if RichStructChain.usedAsOptionalScalar(outer) { return .visitChildren }
            ok = false; return .skipChildren
        case .structWhole, .unsafe:
            ok = false; return .skipChildren
        }
    }
}

/// Verifies that, across a WHOLE view body, a RAW-VALUE enum input is used ONLY in a
/// guest-reconstructable way (TASK 2 demote-safe gate): a comparison/switch against a
/// known case (`input == .active`, `switch input { case .active }`) or `input.rawValue`.
/// Any OTHER use — a bare `input` passed somewhere, a method call (`input.f()`), an
/// unknown member (`input.title`), or a comparison against a case NOT in the declared set
/// — sets `ok = false` → the input is downgraded to `.unsupported` (the view stays native).
/// Note: a `.case` LITERAL (`== .active`) is a `MemberAccessExpr` with NO base, so it never
/// references `input`; we only need to constrain how `input` ITSELF is used.
final class EnumInputUsageScanner: SwiftSyntax.SyntaxVisitor {
    private let name: String
    private let cases: Set<String>
    private(set) var ok = true
    private init(name: String, cases: Set<String>) {
        self.name = name; self.cases = cases
        super.init(viewMode: .sourceAccurate)
    }
    static func usesGuestReconstructably(_ stmts: CodeBlockItemListSyntax,
                                         name: String, cases: Set<String>) -> Bool {
        let s = EnumInputUsageScanner(name: name, cases: cases)
        for item in stmts { s.walk(item) }
        return s.ok
    }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.baseName.text == name else { return .visitChildren }
        // A `.member` selector sharing the name is unrelated (a member of another base).
        if let parent = node.parent?.as(MemberAccessExprSyntax.self), parent.declName.id == node.id {
            return .visitChildren
        }
        // The reference is OUR input. Allowed shapes:
        if let member = node.parent?.as(MemberAccessExprSyntax.self), member.base?.id == node.id {
            // `input.rawValue` is OK; `input.<other>` (a method/property) is not.
            // Reject a FURTHER access on `input.rawValue` (`.rawValue.x`) defensively.
            if member.declName.baseName.text == "rawValue",
               !(member.parent?.as(MemberAccessExprSyntax.self)?.base?.id == member.id) {
                return .visitChildren
            }
            ok = false; return .skipChildren
        }
        // A bare `input` is OK ONLY as the SUBJECT of an `==`/`!=` comparison or a
        // `switch`. Both shapes leave `input` as a plain DeclReference operand/subject —
        // the guest's mirroring enum is `Equatable`/switchable, so they compile. Any
        // other bare use (an argument, an interpolation, a return) can't be proven safe.
        if isComparisonOperand(node) || isSwitchSubject(node) { return .visitChildren }
        ok = false; return .skipChildren
    }

    /// True when `node` is an operand of an `==`/`!=` infix comparison.
    private func isComparisonOperand(_ node: DeclReferenceExprSyntax) -> Bool {
        // SwiftSyntax models `a == b` (after operator folding NOT applied here) as a
        // SequenceExpr of [a, ==, b] before folding; the parser used by lowering does
        // not fold, so the comparison appears as a sibling `BinaryOperatorExpr` in a
        // `SequenceExprSyntax`. Walk up to a SequenceExpr and confirm it contains `==`/`!=`.
        var cur: Syntax? = Syntax(node)
        while let c = cur {
            if let seq = c.as(SequenceExprSyntax.self) {
                return seq.elements.contains { el in
                    if let op = el.as(BinaryOperatorExprSyntax.self) {
                        let t = op.operator.text
                        return t == "==" || t == "!="
                    }
                    return false
                }
            }
            // Stop ascending at a statement / closure / call boundary.
            if c.is(CodeBlockItemSyntax.self) || c.is(ClosureExprSyntax.self)
                || c.is(FunctionCallExprSyntax.self) { return false }
            cur = c.parent
        }
        return false
    }

    /// True when `node` is the SUBJECT expression of a `switch input { … }`.
    private func isSwitchSubject(_ node: DeclReferenceExprSyntax) -> Bool {
        node.parent?.as(SwitchExprSyntax.self)?.subject.id == node.id
    }
}

/// Scans a parsed guest-body expression for a live identifier reference to any of
/// a set of names. A `DeclReferenceExpr` whose base identifier is in the set
/// matches (this catches the base of a member access like `user.name`). Contents
/// of string literals (e.g. an `N.opaque(…, label: "…")` label) are NOT
/// `DeclReferenceExpr`s, so a name appearing only inside an opaque label — which
/// renders natively from `self` — does not match.
final class GuestBodyNameRefScanner: SwiftSyntax.SyntaxVisitor {
    private let target: Set<String>
    private(set) var found = false
    init(_ target: Set<String>) {
        self.target = target
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        // Skip the `.member` of a member access (`.color` in `IRShapeStyle.color(…)`,
        // `.text` in `confidence.text`): it's a property/case of the BASE, not a free
        // reference to an INPUT of the same name. Without this, a view with an input
        // named `color`/`text`/`font`/etc. was WRONGLY flagged as reading an
        // unmarshalled input the instant its lowered tree used the IR member `.color`/
        // `.text`/… (the emitted `.color(.hostToken(id))` for a color TOKEN, say) —
        // excluding a view whose input is actually fully host-resolved into a token.
        if let parent = node.parent?.as(MemberAccessExprSyntax.self),
           parent.declName.id == node.id {
            return .visitChildren
        }
        if target.contains(node.baseName.text) { found = true }
        return found ? .skipChildren : .visitChildren
    }
}

/// Collects identifier names an expression references that could resolve to a `self`-member:
/// FREE identifiers (the base of a member access or a bare reference), `self.X` member
/// names, and `$x` projections. Backs `BodyLowering.identifierReferences(in:)` (the HYBRID
/// thunk-placement private-read check). Deliberately collects the base of `a.b` (so a bare
/// `profile` in `profile.name` is seen) AND the member of `self.b` (so `self.foo` is seen),
/// but NOT the member of a NON-self base (`x.foo` contributes `x`, not `foo`) — that keeps
/// it from over-naming unrelated `.member` accesses while never missing a real self-member.
final class SelfMemberRefScanner: SwiftSyntax.SyntaxVisitor {
    private(set) var names = Set<String>()
    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let text = node.baseName.text
        // `$x` property-wrapper projection (a Binding to a private @State, say).
        if text.hasPrefix("$") { names.insert(text) }
        // The member name of a member access: include it ONLY when the base is `self`
        // (`self.foo` → foo); otherwise it's `someOther.foo` — not a self-member.
        if let parent = node.parent?.as(MemberAccessExprSyntax.self), parent.declName.id == node.id {
            if let base = parent.base?.as(DeclReferenceExprSyntax.self)?.baseName.text, base == "self" {
                names.insert(text)
            }
            return .visitChildren
        }
        // A free identifier / the BASE of a member access (`profile` in `profile.name`).
        names.insert(text)
        return .visitChildren
    }
}

/// Detects whether an input-default expression contains a guest-compile HAZARD that the
/// free-identifier scope-check misses (the default's base is a literal / implicit, so no
/// free identifier). Two forms:
///   • a function/method CALL — may reference a method absent from the Foundation-free
///     guest (`"🥇".image()`, `Date()`, `.formatted()`);
///   • an IMPLICIT-MEMBER access (`.zero`, `.pi`, `.infinity`) — context-dependent, so when
///     the guest binding wraps the default in `Double(.zero)` it is "ambiguous use of
///     'init(_:)'" (exyte-Chat).
/// Either makes the default unsafe → the caller substitutes the type-appropriate zero
/// (the `?? default` is dead code, so this is correctness-neutral). Used by
/// `SwiftUIBodyLowering.defaultLiteralIsGuestSafe`.
fileprivate final class _DefaultCallFinder: SyntaxVisitor {
    var found = false
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        found = true
        return .skipChildren
    }
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        // An IMPLICIT member (`.zero`) has no base — it needs surrounding type context the
        // guest binding's `Double(…)` wrapper makes ambiguous. An EXPLICIT member
        // (`Foo.bar`) has a base and is already covered by the free-identifier scope-check.
        if node.base == nil { found = true; return .skipChildren }
        return .visitChildren
    }
}
