// SPDX-License-Identifier: Apache-2.0

// UIKitClassifier.swift — recognizes a UIKit cell's DECLARATIVE construction and
// drives its lowering to the `UIKitNode` IR (the `UI.*` builder).
// =============================================================================
// This is the UIKit analogue of `SwiftUIClassifier`/`BodyLowering`. Where the
// SwiftUI classifier walks a `body` EXPRESSION tree (a result-builder of view
// values), a UIKit cell's construction is IMPERATIVE-but-flat: inside a method
// (`configure(with:)`/`setup()`/`init`) the code makes views, sets properties,
// adds subviews, and activates constraints. So this classifier walks a METHOD
// BODY (a statement list) and recognizes exactly that grammar:
//
//   * local view creation:   `let title = UILabel()`  (and the cheap controls)
//   * property configuration: `title.text = model.name`, `title.font = .boldSystemFont(ofSize: 17)`
//   * subview wiring:         `contentView.addSubview(stack)`,
//                             `stack.addArrangedSubview(title)`,
//                             `let stack = UIStackView(arrangedSubviews: [a, b])`
//   * Auto Layout:            `title.translatesAutoresizingMaskIntoConstraints = false`,
//                             `NSLayoutConstraint.activate([ a.topAnchor.constraint(equalTo: …), … ])`,
//                             `a.topAnchor.constraint(equalTo: b.topAnchor, constant: 8).isActive = true`
//
// The result is a `UIKitNode` tree rooted at the cell's CONTENT ROOT — the single
// subview added to `contentView` (the conventional cell shape). Each created view
// is a node; its set properties fold into `UIKitViewProps` (+ the leaf payload);
// its constraints attach to the node. A subview that isn't a recognized
// constructor (a custom `UIView` subclass, an imperative sub-build) becomes a
// `UI.customSlot(id:)` — rendered natively from the thunk's build-time closure,
// exactly like the SwiftUI mixed-view `.opaque` mechanism.
//
// ALL-OR-NOTHING-PER-METHOD demote (the cardinal rule): if ANY statement in the
// method isn't in the recognized grammar (a `for` loop building rows, a call into
// an unknown helper, an `if` whose branches aren't pure config, a property set we
// can't model), the WHOLE method stays native — `lower()` returns nil and no
// patch is emitted for the cell. A recognized-but-un-lowerable LEAF (a custom
// subview) is NOT a whole-method demote: it slots. This keeps a patched cell
// always faithful: either the construction rides WASM (with native slots for the
// odd leaf) or the cell is 100% the compiled-in code.

import SwiftSyntax
import SwiftParser
import ViewNodeIR

/// Lowers a UIKit cell's declarative construction method to a guest body that
/// builds a `UIKitNode` tree. The entry point mirrors `BodyLowering`:
/// `lowerAllCells(source:)` returns one `LoweredCell` per recognized cell type.
public struct UIKitCellLowering {
    public init() {}

    /// The kind of UIKit container whose declarative construction we lowered. The
    /// IR + guest emission are identical for both — the difference is purely the
    /// CONTENT-ROOT host view the construction adds subviews to (and, downstream,
    /// the thunk's install target):
    ///   * `.cell` — a `UITableViewCell`/`UICollectionViewCell`/header-footer subclass,
    ///     rooted at `contentView`, replaced at its re-runnable `configure(with:)`/
    ///     `setup()` hook (tier C is free — UIKit re-runs it on reuse).
    ///   * `.viewController` — a programmatic `UIViewController`/`UIView` subclass,
    ///     rooted at `view` (the VC's root view) / `self`, replaced at its one-time
    ///     `setupViews()`/`viewDidLoad` construction. `viewDidLoad` runs once + is
    ///     Void, so the SDK MANUFACTURES the tier-C teardown-prior+rebuild seat (the
    ///     install clears any prior patched root before adding the new one — the same
    ///     `clearPatchedRoot` the cell path already uses).
    public enum ContainerKind: String, Sendable, Equatable {
        case cell
        case viewController
    }

    /// One recognized `addGestureRecognizer` wiring (Lever 1) — the public mirror of the
    /// emitter's internal record, carried on `LoweredCell` so the thunk generator can emit
    /// the native replay closure. `viewNodeID` is the local view name the gesture attaches
    /// to (the rendered node's id); `source` is the verbatim gesture construction.
    public struct GestureWiring: Sendable, Equatable {
        public let viewNodeID: String
        public let source: String
        public init(viewNodeID: String, source: String) {
            self.viewNodeID = viewNodeID; self.source = source
        }
    }

    /// One recognized `NotificationCenter.default.addObserver(self, selector:…)` (Lever 2)
    /// — a method-level effect replayed natively. `id` is a content-stable hash; `source`
    /// is the verbatim `addObserver(...)` call.
    public struct ObserverEffect: Sendable, Equatable {
        public let id: String
        public let source: String
        public init(id: String, source: String) { self.id = id; self.source = source }
    }

    /// One QUARANTINED native effect (Goal 1 — GRANULAR PER-STATEMENT PARTITIONING): an
    /// unrecognized-but-isolatable imperative statement the build-time thunk replays
    /// VERBATIM against `self` in SOURCE ORDER, so the surrounding declarative construction
    /// still lowers instead of the whole method demoting. `ordinal` is the replay order.
    /// The public mirror of the emitter's internal `NativeEffect`, carried on `LoweredCell`
    /// so the thunk generator can emit the native replay closures.
    public struct NativeEffect: Sendable, Equatable {
        public let source: String
        public let ordinal: Int
        public init(source: String, ordinal: Int) {
            self.source = source; self.ordinal = ordinal
        }
    }

    /// One control ACTION WIRING (BUG #17/#18 fix) — the public mirror of the emitter's
    /// internal `ActionWiring`, carried on `LoweredCell` so the thunk generator can emit
    /// the native action handler (`__actions[id] = { [self] in self.<selector>() }`).
    /// `id` is the lowered control's action id (the dispatcher's `EventID.id`); `selector`
    /// is the cell's native `#selector` handler base name.
    public struct ActionWiring: Sendable, Equatable {
        public let id: String
        public let selector: String
        public init(id: String, selector: String) { self.id = id; self.selector = selector }
    }

    /// One lowered cell ready to ship as an OTA UIKit patch.
    public struct LoweredCell: Sendable, Equatable {
        /// The cell's type name (`ProfileCell`).
        public let typeName: String
        /// The recognized construction method's selector base (`configure(with:)`,
        /// `setup()`, `init(style:reuseIdentifier:)`). The thunk replaces THIS method.
        public let methodName: String
        /// The Swift label-list form for `@_dynamicReplacement(for:)` (`configure(with:)`,
        /// `setup`, `init(style:reuseIdentifier:)`). Mirrors how the dynamic-replacement
        /// attribute names the original.
        public let replacedSelector: String
        /// The construction method's full parameter clause source (`(with model: CellModel)`,
        /// `()`), so the generated thunk re-declares a SIGNATURE-MATCHING replacement
        /// (`@_dynamicReplacement` type-checks only against the exact signature). Empty
        /// `()` for a no-arg `setup()`.
        public let methodParameterClause: String
        /// The model parameter's INTERNAL name (the value the body reads + the thunk
        /// forwards to the host as the model), or nil when the method takes no model.
        public let modelParamName: String?
        /// The `UI.<…>` builder expression that builds the cell's content-root tree.
        public let guestBody: String
        /// The model fields the construction reads, marshalled in from JSON (the cell's
        /// `with model:` parameter's flat fields — or the cell's own stored props when
        /// it has no model param). Reuses the SwiftUI `ViewInput` marshalling.
        public let inputs: [BodyLowering.ViewInput]
        /// Non-lowerable LEAVES emitted as `UI.customSlot` — the thunk supplies a native
        /// slot closure for each SLOTABLE one, keyed by the SAME content-stable id.
        public let customSlots: [BodyLowering.OpaqueLeaf]
        /// Action ids wired by the construction (`button.addTarget(...)` / a
        /// `UI.button(action:)`) — the thunk maps each to the cell's native handler.
        public let actionIDs: [String]
        /// CONTROL ACTION WIRINGS (BUG #17/#18 fix): each pairs a lowered control's action
        /// id with the cell's native `#selector` handler name. The generated thunk replays
        /// these into `PatchCellWiring.actions` (`__actions[id] = { [self] in
        /// self.<selector>() }`) so a patched button/switch/slider/textField's action
        /// actually fires on device. Empty for an action-free construction.
        public let actionWirings: [ActionWiring]
        /// GESTURE WIRINGS (Lever 1 — `addGestureRecognizer`): each carries the LOCAL view
        /// name the gesture attaches to (the rendered node's id) + the VERBATIM gesture
        /// construction source. The thunk supplies a per-view native closure `{ v in
        /// v.addGestureRecognizer(<source>) }` and the SDK applies it to the matching
        /// rendered view after building the tree. Empty for a gesture-free construction.
        public let gestureWirings: [GestureWiring]
        /// OBSERVER EFFECTS (Lever 2 — `NotificationCenter.default.addObserver`): each
        /// carries a content-stable id + the VERBATIM `addObserver(...)` call source. The
        /// thunk supplies a native closure that re-runs it against `self`, and the SDK runs
        /// each ONCE at install. Empty for a construction with no observer registration.
        public let observerEffects: [ObserverEffect]
        /// QUARANTINED NATIVE EFFECTS (Goal 1): the isolatable imperative statements the
        /// thunk replays verbatim in source order (a delegate set, a live-object call), so
        /// a single weird line is no longer contagious. Empty for a 100%-declarative method.
        public let nativeEffects: [NativeEffect]
        /// DESIGN-SYSTEM COLOR TOKENS (Lever D): custom color expressions the guest can't
        /// reconstruct, lowered as `ColorRef.hostToken(id)`. The thunk emits a resolver
        /// (`{ <source> } as () -> UIColor`) per id; the SDK fills the renderer's token
        /// table. Only the `.color` kind is used for UIKit (applied by the renderer).
        public let hostTokens: [BodyLowering.HostToken]
        /// True iff the body lowered with ZERO custom slots that aren't slotable AND
        /// reads no unmarshalled input — the gate the host uses to AUTO-ROUTE.
        public let thunkSafe: Bool
        /// True when the construction reads a model/stored input the guest can't
        /// reconstruct (a nested struct/enum/dictionary) — such a cell is EXCLUDED
        /// from guest emission (renders native), never shipped with a wrong default.
        public let referencesUnmarshalledInput: Bool
        /// Whether this lowered construction is a reuse-driven cell or a programmatic
        /// view-controller. Drives the thunk's install target (`contentView` vs `view`)
        /// and the replaced selector's idempotency story; the IR + guest are identical.
        public let containerKind: ContainerKind

        public init(typeName: String, methodName: String, replacedSelector: String,
                    methodParameterClause: String, modelParamName: String?,
                    guestBody: String, inputs: [BodyLowering.ViewInput],
                    customSlots: [BodyLowering.OpaqueLeaf], actionIDs: [String],
                    actionWirings: [ActionWiring] = [],
                    gestureWirings: [GestureWiring] = [],
                    observerEffects: [ObserverEffect] = [],
                    nativeEffects: [NativeEffect] = [],
                    hostTokens: [BodyLowering.HostToken] = [],
                    thunkSafe: Bool, referencesUnmarshalledInput: Bool,
                    containerKind: ContainerKind = .cell) {
            self.typeName = typeName
            self.methodName = methodName
            self.replacedSelector = replacedSelector
            self.methodParameterClause = methodParameterClause
            self.modelParamName = modelParamName
            self.guestBody = guestBody
            self.inputs = inputs
            self.customSlots = customSlots
            self.actionIDs = actionIDs
            self.actionWirings = actionWirings
            self.gestureWirings = gestureWirings
            self.observerEffects = observerEffects
            self.nativeEffects = nativeEffects
            self.hostTokens = hostTokens
            self.thunkSafe = thunkSafe
            self.referencesUnmarshalledInput = referencesUnmarshalledInput
            self.containerKind = containerKind
        }
    }

    // MARK: - Public entry points

    /// Lower EVERY cell-like class in `source` (a `UITableViewCell`/
    /// `UICollectionViewCell` subclass with a recognized declarative construction
    /// method). Returns one `LoweredCell` per cell whose construction lowered;
    /// a cell whose construction isn't the recognized grammar is skipped entirely
    /// (it stays 100% native — the cardinal demote rule).
    public func lowerAllCells(source: String) -> [LoweredCell] {
        let tree = Parser.parse(source: source)
        let structCatalog = BodyLowering.flatStructCatalog(in: tree)
        let constants = Self.namespaceConstants(in: tree)
        let extensions = Self.extensionsByType(in: tree)
        var out: [LoweredCell] = []
        for cell in cellClasses(in: tree) {
            if let lowered = lower(cell: cell, structCatalog: structCatalog,
                                   namespaceConstants: constants,
                                   extensions: extensions[cell.name] ?? []) {
                out.append(lowered)
            }
        }
        return out
    }

    /// Convenience for tests: the guest body of the FIRST recognized cell, or nil.
    public func emitGuestBody(source: String) -> String? {
        lowerAllCells(source: source).first?.guestBody
    }

    /// DIAGNOSTIC: lower the first cell, returning its guest body OR the bail reason
    /// (why the construction wasn't recognized). For tests + `PATCH_UIKIT_VERBOSE`.
    public func diagnoseFirstCell(source: String) -> (body: String?, reason: String, cellFound: Bool) {
        let tree = Parser.parse(source: source)
        let catalog = BodyLowering.flatStructCatalog(in: tree)
        let extensions = Self.extensionsByType(in: tree)
        guard let cell = cellClasses(in: tree).first else {
            return (nil, "no cell class with a recognized construction method found", false)
        }
        let d = diagnose(cell: cell, catalog: catalog, extensions: extensions[cell.name] ?? [])
        return (d.body, d.reason, true)
    }

    /// DIAGNOSTIC: a per-method outcome — the construction method's identity plus the
    /// lowered guest body (when it lowered) or the bail reason (when it demoted). Used by
    /// the corpus measure to bucket EVERY candidate method, not just the first per file.
    public struct CellDiagnosis: Sendable {
        public let typeName: String
        public let methodName: String
        public let containerKind: ContainerKind
        public let body: String?
        public let reason: String
        /// True when the method lowered to a guest body (`body != nil`).
        public var lowered: Bool { body != nil }
    }

    /// DIAGNOSTIC: diagnose EVERY recognized cell/VC candidate in the source (the real
    /// per-method coverage granularity — a file can hold several cells, each lowering or
    /// demoting independently). One entry per candidate.
    public func diagnoseAllCells(source: String) -> [CellDiagnosis] {
        let tree = Parser.parse(source: source)
        let catalog = BodyLowering.flatStructCatalog(in: tree)
        let constants = Self.namespaceConstants(in: tree)
        let extensions = Self.extensionsByType(in: tree)
        return cellClasses(in: tree).map {
            diagnose(cell: $0, catalog: catalog, constants: constants,
                     extensions: extensions[$0.name] ?? [])
        }
    }

    private func diagnose(cell: FoundCell,
                          catalog: [String: [BodyLowering.StructField]],
                          constants: [String: UIKitEmitter.ConstantValue] = [:],
                          extensions: [ExtensionDeclSyntax] = []) -> CellDiagnosis {
        guard let body = cell.method.body else {
            return CellDiagnosis(typeName: cell.name, methodName: cell.method.selector,
                                 containerKind: cell.containerKind, body: nil,
                                 reason: "method has no body")
        }
        var emitter = UIKitEmitter()
        emitter.containerKind = cell.containerKind
        emitter.inputs = Self.modelInputs(of: cell, structCatalog: catalog)
        emitter.inaccessibleNames = Self.inaccessibleMemberNames(of: cell.decl, extensions: extensions)
        emitter.reachableMemberNames = Self.reachableMemberNames(of: cell.decl)
        emitter.selectorArities = Self.instanceMethodArities(of: cell.decl, extensions: extensions)
        emitter.selfMethodNames = Self.instanceMethodNames(of: cell.decl, extensions: extensions)
        emitter.inlineHelpers = Self.noArgHelpers(of: cell.decl, excluding: cell.method.selector)
        emitter.namespaceConstants = constants.merging(
            Self.namespaceConstants(in: cell.decl)) { _, nested in nested }
        emitter.seedStoredViews(Self.storedViewProperties(of: cell.decl))
        let root = emitter.emit(methodBody: body.statements)
        // An empty-tree demote (no contentView children) surfaces with no bail reason —
        // label it so the corpus measure buckets it instead of attributing a blank.
        let reason = emitter.bailReasonStore.isEmpty
            ? (root == nil ? "no content-root subview (build targets self / nothing added)" : "")
            : emitter.bailReasonStore
        return CellDiagnosis(typeName: cell.name, methodName: cell.method.selector,
                             containerKind: cell.containerKind, body: root, reason: reason)
    }

    // MARK: - Cell discovery

    struct FoundCell {
        let name: String
        let decl: ClassDeclSyntax
        /// The recognized construction method (the one the thunk replaces).
        let method: FunctionOrInit
        /// Cell vs programmatic view-controller — drives the content-root host view
        /// (`contentView` vs `view`) and the thunk's install target.
        let containerKind: ContainerKind
    }

    /// A function decl OR an initializer decl — both can be the recognized
    /// construction method (`configure(with:)`/`setup()` are funcs; some cells do
    /// their build in `init`).
    enum FunctionOrInit {
        case function(FunctionDeclSyntax)
        case initializer(InitializerDeclSyntax)

        var body: CodeBlockSyntax? {
            switch self {
            case .function(let f): return f.body
            case .initializer(let i): return i.body
            }
        }
        /// The selector base used as the method name + replacement label list.
        /// `configure(with:)`, `setup`, `init(style:reuseIdentifier:)`.
        var selector: String {
            switch self {
            case .function(let f):
                let labels = f.signature.parameterClause.parameters.map {
                    ($0.firstName.text == "_" ? "_" : $0.firstName.text) + ":"
                }.joined()
                return labels.isEmpty ? f.name.text : "\(f.name.text)(\(labels))"
            case .initializer(let i):
                let labels = i.signature.parameterClause.parameters.map {
                    ($0.firstName.text == "_" ? "_" : $0.firstName.text) + ":"
                }.joined()
                return "init(\(labels))"
            }
        }
    }

    /// The UIKit containers worth lowering, in declaration order. A class qualifies if
    /// it inherits a known CELL base (UITableViewCell/…) — re-run on reuse, tier C is
    /// free — OR a known VIEW-CONTROLLER base (UIViewController/UIView) — built once, so
    /// the SDK manufactures the teardown-prior+rebuild seat (Goal 2). For each, pick the
    /// BEST recognized construction method (a cell's `configure`/`setup`; a VC's
    /// `setupViews`/`viewDidLoad`).
    func cellClasses(in tree: SourceFileSyntax) -> [FoundCell] {
        var found: [FoundCell] = []
        for stmt in tree.statements {
            guard let c = stmt.item.as(ClassDeclSyntax.self) else { continue }
            if Self.isCellClass(c) {
                guard let method = Self.constructionMethod(of: c) else { continue }
                found.append(FoundCell(name: c.name.text, decl: c, method: method,
                                       containerKind: .cell))
            } else if Self.isViewControllerClass(c) {
                guard let method = Self.vcConstructionMethod(of: c) else { continue }
                found.append(FoundCell(name: c.name.text, decl: c, method: method,
                                       containerKind: .viewController))
            }
        }
        return found
    }

    /// The known reusable-cell base classes. (We match by the inheritance clause's
    /// FIRST type name — the superclass — since a cell `: UITableViewCell` lists the
    /// base first. A protocol-only conformance doesn't make a cell.)
    static let cellBaseClasses: Set<String> = [
        "UITableViewCell", "UICollectionViewCell",
        "UITableViewHeaderFooterView", "UICollectionReusableView"
    ]

    /// The known programmatic view/VC base classes whose declarative construction we
    /// lower (Goal 2). A class inheriting one of these — and NOT a cell base — roots its
    /// content at `view` (the VC's root view). `UITableViewController`/
    /// `UICollectionViewController` are EXCLUDED: their root view IS the table/collection
    /// (you don't `view.addSubview` into it the declarative way), so they have no
    /// `setupViews`-style tree to lower.
    static let viewControllerBaseClasses: Set<String> = [
        "UIViewController", "UIView",
    ]

    static func isCellClass(_ c: ClassDeclSyntax) -> Bool {
        guard let inh = c.inheritanceClause else { return false }
        return inh.inheritedTypes.contains { Self.cellBaseClasses.contains(Self.baseName($0.type)) }
    }

    static func isViewControllerClass(_ c: ClassDeclSyntax) -> Bool {
        guard let inh = c.inheritanceClause else { return false }
        // A cell base wins (handled by the cell path); a VC/View base otherwise.
        if inh.inheritedTypes.contains(where: { Self.cellBaseClasses.contains(Self.baseName($0.type)) }) {
            return false
        }
        return inh.inheritedTypes.contains { Self.viewControllerBaseClasses.contains(Self.baseName($0.type)) }
    }

    static func baseName(_ type: TypeSyntax) -> String {
        let desc = type.trimmedDescription
        return desc.split(separator: "<", maxSplits: 1).first.map(String.init) ?? desc
    }

    /// Choose the construction method to lower + replace. Preference order (the
    /// friendliest re-runnable hooks first):
    ///   1. `configure(with:)` / `configure(...)` — the canonical reuse hook,
    ///   2. `setup()` / `setupViews()` / `setUp()` — a one-time build helper.
    /// We only RETURN a method whose body is the recognized declarative grammar
    /// (validated later in `lower`). Here we pick the candidate by name. We do NOT
    /// target a bare `init` for the cell wedge: a cell's `init` is dominated by the
    /// boilerplate `init?(coder:)` / `init(style:reuseIdentifier:)` shells (not the
    /// build), and an init-based build isn't re-run on reuse (it would need the
    /// synthesized re-runnable hook listed as deferred). `configure`/`setup` cover the
    /// overwhelming majority of real cells and are genuinely re-run.
    static func constructionMethod(of c: ClassDeclSyntax) -> FunctionOrInit? {
        var configure: FunctionDeclSyntax?
        var setup: FunctionDeclSyntax?
        let setupNames: Set<String> = ["setup", "setupviews", "setupui", "setupcell",
                                       "setupsubviews", "configureviews", "commoninit"]
        for member in c.memberBlock.members {
            if let f = member.decl.as(FunctionDeclSyntax.self) {
                // R2-#90/#32/#94: only a SIGNATURE the thunk can faithfully replace +
                // re-declare + forward — Void, no async/throws, ≤1 (named, non-`_:`) model
                // param. A non-Void / effectful / multi-param / anonymous-param construction
                // stays native (the thunk would mismatch / mis-forward).
                guard Self.isLowerableConstructionSignature(f) else { continue }
                let lower = f.name.text.lowercased()
                if f.name.text == "configure" { configure = configure ?? f }
                else if setupNames.contains(lower) { setup = setup ?? f }
            }
        }
        if let configure { return .function(configure) }
        if let setup { return .function(setup) }
        return nil
    }

    /// Whether a recognized construction method's SIGNATURE is one the generated thunk can
    /// faithfully replace, re-declare, and forward (R2-#90/#32/#94):
    ///   * Void return — `@_dynamicReplacement(for:)` matches the original's signature, and
    ///     the original-call fall-through is a statement; a `-> Bool` build would mismatch +
    ///     drop the return value.
    ///   * no `async`/`throws` effect specifiers — the thunk neither `try`s nor `await`s the
    ///     original, and the replacement's signature would mismatch.
    ///   * at most ONE value parameter, and if present it must be NAMED (an internal name the
    ///     replacement can forward) and non-shell — a multi-param construction
    ///     (`configure(with:animated:)`) or an anonymous `configure(_:)` can't be forwarded
    ///     (`originalCall` only knows the single model param), so it stays native.
    static func isLowerableConstructionSignature(_ f: FunctionDeclSyntax) -> Bool {
        // No async/throws.
        if let effects = f.signature.effectSpecifiers,
           effects.asyncSpecifier != nil || effects.throwsClause != nil {
            return false
        }
        // Void return only (no returnClause, or `-> Void`/`-> ()`).
        if let ret = f.signature.returnClause {
            let t = ret.type.trimmedDescription
            if t != "Void" && t != "()" { return false }
        }
        // Parameter clause: zero or one NAMED, non-`_:`, non-shell value param.
        let params = f.signature.parameterClause.parameters
        if params.count > 1 { return false }
        if let first = params.first {
            let internalName = first.secondName?.text ?? first.firstName.text
            // An anonymous `_:` value param has no internal name the replacement can forward
            // (`originalCall` would fabricate `configure(nil)` — a compile-fail/wrong arg for a
            // non-Optional model). Demote. A `_ model:` (named internal) forwards fine.
            if internalName == "_" { return false }
        }
        return true
    }

    /// The chained-super lifecycle calls a VC `viewDidLoad` construction may open with
    /// (`super.viewDidLoad()` and the other no-arg lifecycle supers). Tolerated +
    /// ignored by the emitter so a `viewDidLoad`-rooted declarative build still lowers;
    /// they mutate no view tree we model.
    static let uiKitLifecycleSuperCalls: Set<String> = [
        "viewDidLoad", "viewWillAppear", "viewDidAppear", "viewWillDisappear",
        "viewDidDisappear", "viewWillLayoutSubviews", "viewDidLayoutSubviews",
        "layoutSubviews", "awakeFromNib", "updateViewConstraints", "updateConstraints",
    ]

    /// VC setup-helper method names (the dedicated declarative-construction hooks a
    /// programmatic VC factors its view build into). Preferred over `viewDidLoad`
    /// because they tend to be PURE construction (no `super.viewDidLoad()` /
    /// delegate-wiring / observer-setup mixed in), so they lower more often.
    static let vcSetupNames: Set<String> = [
        "setupviews", "setupui", "setupsubviews", "configureviews", "setuplayout",
        "buildviews", "buildui", "configuresubviews", "configureui", "addsubviews",
        "installviews", "setuphierarchy", "setupconstraints",
    ]

    /// Choose the construction method to lower + replace for a programmatic VC/View.
    /// Preference order (the friendliest re-runnable hooks first):
    ///   1. a dedicated `setupViews()`/`buildUI()`-style helper (pure construction),
    ///   2. `viewDidLoad()` itself (the canonical one-time build site).
    /// Only a NO-ARG (or `viewDidLoad()`) method is returned — an arg-taking helper
    /// reads params not in scope. We do NOT target `init`/`loadView` for the VC wedge:
    /// an init-based build isn't a clean re-runnable hook, and `loadView` replaces the
    /// root view entirely (no `view.addSubview` declarative tree).
    static func vcConstructionMethod(of c: ClassDeclSyntax) -> FunctionOrInit? {
        var setup: FunctionDeclSyntax?
        var viewDidLoad: FunctionDeclSyntax?
        for member in c.memberBlock.members {
            guard let f = member.decl.as(FunctionDeclSyntax.self) else { continue }
            // R2-#90: reject async/throws/non-Void construction methods — the
            // @_dynamicReplacement signature would mismatch + the original-call fall-through
            // would miss the required try/await. `setupViews() throws` / `-> Bool` stays native.
            guard Self.isLowerableConstructionSignature(f) else { continue }
            let lower = f.name.text.lowercased()
            if f.signature.parameterClause.parameters.isEmpty, Self.vcSetupNames.contains(lower) {
                setup = setup ?? f
            } else if f.name.text == "viewDidLoad",
                      f.signature.parameterClause.parameters.isEmpty {
                viewDidLoad = viewDidLoad ?? f
            }
        }
        if let setup { return .function(setup) }
        if let viewDidLoad { return .function(viewDidLoad) }
        return nil
    }
}
