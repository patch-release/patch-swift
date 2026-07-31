// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax

/// Walks a parsed syntax tree and produces a `FunctionRecord` for every
/// function-like declaration (func, method, init, computed property, accessor)
/// and every closure literal.
///
/// Each record's `bodyReferences` is gathered by a nested `ReferenceCollector`
/// that records type names, calls, member accesses, attributes and selectors.
///
/// Conservative-by-design: when the extractor sees a construct it cannot reason
/// about precisely (`@objc`, `#selector`, `dynamic`, `performSelector`), it sets
/// `forcesNative` on the enclosing record. The classifier honors this flag so
/// such functions can never be classified `wasmEligible`.
final class FunctionExtractor: SyntaxVisitor {
    let moduleName: String
    let file: URL
    let converter: SourceLocationConverter

    private(set) var records: [FunctionRecord] = []

    /// Type/extension nesting stack used to build qualified ids.
    private var typeStack: [String] = []
    /// Function-name nesting stack used to qualify closures.
    private var functionStack: [String] = []
    /// How many `functionStack` entries each currently-open `VariableDeclSyntax`
    /// pushed, so `visitPost(VariableDeclSyntax)` pops exactly that many. A
    /// computed property / accessor `emitRecord` pushes onto `functionStack`
    /// (to qualify closures inside its body) but — unlike func/init — has no
    /// per-decl `visitPost` of its own kind to pop in, so without this counter the
    /// pushes LEAKED, permanently polluting the qualified id of every closure
    /// parsed later in the file (a single computed property before any closure was
    /// enough to corrupt that closure's function id, the call-graph key).
    private var varDeclPushCounts: [Int] = []
    /// Parallel to `typeStack`: a reason string if the enclosing type forces
    /// EVERY member native (genuine UI/system type: conforms to `View`/`App`,
    /// inherits `UIViewController`/`NSObject`, system delegate, etc.). nil = not blanket-forced.
    private var typeNativeReason: [String?] = []
    /// Parallel to `typeStack`: names of stored properties declared with a native
    /// property wrapper (`@Published`, `@State`, `@ObservedObject`, …). A method
    /// that REFERENCES one of these names is forced native (the wrapper's storage
    /// is Combine/SwiftUI runtime → not WASM-safe), but the type as a whole is
    /// NOT blanket-forced. This frees pure helper methods on view-models/stores
    /// (the single biggest Day-2 coverage lever) while staying safe: any method
    /// actually touching reactive state is still caught.
    private var typeNativePropertyNames: [Set<String>] = []
    /// Parallel to `typeStack`: names → declared types of stored properties that
    /// are REACTIVE via a SwiftUI/Combine property wrapper (`@State`/`@Published`/
    /// `@AppStorage`/…) AND whose declared type is a VALUE-MARSHALLABLE type
    /// (scalar/String/Bool, or a homogeneous array of those). These are the props
    /// the native shell can HOST-PROJECT into a lifted WASM fragment (the same
    /// trick the SwiftUI view-body path uses for `@State` scalars). A member that
    /// is forced native ONLY because it reads such props — and writes nothing,
    /// touches no other native interop, and returns a marshallable type — is
    /// recorded with `hostProjectableReads` instead of being forced native (→
    /// `mixed`, not `native`). SUBSET ⊆ `typeNativePropertyNames` by construction:
    /// every entry here is also a forced-native reactive name, so this NEVER frees
    /// a member the old rule would have caught — it only UPGRADES a would-be
    /// `native` member to `mixed`. A prop appears here only when its type is
    /// provably value-marshallable; anything uncertain is omitted, so the member
    /// stays native (lost coverage, never a false negative).
    private var typeValueReactivePropertyTypes: [[String: String]] = []
    /// Parallel to `typeStack`: when a type is a SwiftUI **view-DSL** conformance
    /// (View/App/Scene/ViewModifier/Shape/…), the reason is recorded HERE rather
    /// than as a blanket `typeNativeReason`. Members of such a type are then forced
    /// native PER-MEMBER — only `body`, members returning `some View`/a view type,
    /// `@ViewBuilder`/result-builder members, reactive-state touches and native
    /// symbols stay native. Pure value members (design tokens, labels, layout-math)
    /// are freed to classify on their merits. This mirrors the engine's existing
    /// `@Published`/`ObservableObject` per-member carve-out, extended to view
    /// structs. Hard-native conformances (system delegates, NSObject, *Representable…)
    /// keep the blanket reason in `typeNativeReason`. nil = not a per-member view-DSL
    /// type.
    private var typeViewDSLReason: [String?] = []

    /// Parallel to `typeStack`: when a type is a **UIKit/AppKit view or
    /// view-controller** base class (`UIViewController`/`UIView`/`UIResponder`/
    /// `UITableViewCell`/`NSViewController`/…), the reason is recorded HERE rather
    /// than as a blanket `typeNativeReason` (UIKit "Phase 1a"). Members of such a
    /// type are forced native PER-MEMBER — a member stays native ONLY if it
    ///   (e) is a UIKit lifecycle override (`viewDidLoad`/`loadView`/`viewWillAppear`/
    ///       `layoutSubviews`/`draw(_:)`/…),
    ///   (b) references a UIKit/native registry symbol (caught downstream by the
    ///       registry scan in the Classifier),
    ///   (d) is `@objc`/`@IBAction`/`#selector`/`dynamic` (caught by `nativeAttributes`/
    ///       the `dynamic` modifier / `#selector` scans below), or
    ///   (a/c) references a stored property that is native-typed or backed by a
    ///       native property wrapper (`@IBOutlet`/…) — caught by `nativePropertyNames`.
    /// A pure value-returning/computation method touching none of those is FREED to
    /// classify on its merits (may become `wasmEligible`). Mirrors the view-DSL
    /// carve-out exactly; the blanket flag is only ever REMOVED, then the unchanged
    /// downstream native-detection re-runs, so it can never create a false negative
    /// (only, at worst, lose coverage). nil = not a per-member UIKit view/VC type.
    private var typeUIKitReason: [String?] = []

    /// True when ANY enclosing type blanket-forces native.
    private var inForcedNativeType: Bool { typeNativeReason.contains { $0 != nil } }
    /// The most-specific blanket-forced reason in scope.
    private var currentTypeNativeReason: String? {
        typeNativeReason.last(where: { $0 != nil }) ?? nil
    }
    /// Union of native-property names across all enclosing types.
    private var nativePropertyNamesInScope: Set<String> {
        typeNativePropertyNames.reduce(into: Set<String>()) { $0.formUnion($1) }
    }
    /// Union of value-marshallable reactive props (name → type) across all
    /// enclosing types — the host-projection candidate set.
    private var valueReactivePropertyTypesInScope: [String: String] {
        typeValueReactivePropertyTypes.reduce(into: [String: String]()) { acc, m in
            for (k, v) in m { acc[k] = v }
        }
    }
    /// The most-specific per-member view-DSL reason in scope.
    private var currentViewDSLReason: String? {
        typeViewDSLReason.last(where: { $0 != nil }) ?? nil
    }
    /// The most-specific per-member UIKit-view/VC reason in scope.
    private var currentUIKitReason: String? {
        typeUIKitReason.last(where: { $0 != nil }) ?? nil
    }

    init(moduleName: String, file: URL, converter: SourceLocationConverter) {
        self.moduleName = moduleName
        self.file = file
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Type context tracking

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text,
                 inheritance: node.inheritanceClause,
                 members: node.memberBlock,
                 attributes: node.attributes)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { popType() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text,
                 inheritance: node.inheritanceClause,
                 members: node.memberBlock,
                 attributes: node.attributes)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { popType() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock,
                 attributes: node.attributes)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { popType() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock,
                 attributes: node.attributes)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { popType() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.extendedType.trimmedDescription,
                 inheritance: node.inheritanceClause,
                 members: node.memberBlock,
                 attributes: node.attributes)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { popType() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, inheritance: node.inheritanceClause, members: nil,
                 attributes: node.attributes)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { popType() }

    // MARK: - Type context push/pop with native-inheritance detection

    private func pushType(
        _ name: String,
        inheritance: InheritanceClauseSyntax?,
        members: MemberBlockSyntax?,
        attributes: AttributeListSyntax? = nil
    ) {
        typeStack.append(name)
        let (blanket, viewDSL, uiKit) = nativeReasons(inheritance: inheritance)
        typeNativeReason.append(blanket)
        typeViewDSLReason.append(viewDSL)
        typeUIKitReason.append(uiKit)
        // OBSERVATION MACRO (`@Observable` / SwiftData `@Model`): the macro makes
        // EVERY plain stored property reactive (it synthesizes the observation
        // accessors), so a reader/writer of such a prop touches Observation runtime
        // state exactly like a `@Published` prop. Treat each plain stored property as
        // reactive (force readers native, host-project the value-marshallable subset)
        // — UNLESS it carries `@ObservationIgnored` (opt-out of observation). This is
        // the modern analogue of the `@Published` per-member rule.
        let isObservationMacroType = Self.hasObservationMacro(attributes)
        let nativeProps = nativePropertyNames(in: members,
                                              observationMacroType: isObservationMacroType)
        typeNativePropertyNames.append(nativeProps)
        // Value-marshallable reactive props (host-projection candidates) — kept as
        // a strict subset of the forced-native reactive names so it can only ever
        // upgrade a would-be `native` member to `mixed`, never free one.
        typeValueReactivePropertyTypes.append(
            valueReactivePropertyTypes(in: members, nativeNames: nativeProps,
                                       observationMacroType: isObservationMacroType))
    }

    /// Names BOUND LOCALLY by a member node — its own function parameters plus every
    /// `let`/`var`/`case let`/closure-param binding in its body. A reference to such a
    /// name denotes the local, not a same-named reactive `self.<prop>`, so the
    /// host-projection scan must NOT treat it as a reactive read (it would over-force
    /// AND project the wrong value). Conservative: an over-inclusive local set can only
    /// SUPPRESS a host-projection (keep a member native / pure), never create one.
    static func locallyBoundNames(in node: Syntax) -> Set<String> {
        let v = LocalBindingCollector(viewMode: .sourceAccurate)
        v.walk(node)
        return v.names
    }

    /// Does a type carry the Observation `@Observable` macro (or SwiftData `@Model`,
    /// which also synthesizes observation)? Such a type's plain stored properties are
    /// all reactive. Matched on the leading attribute identifier (qualified forms like
    /// `@Observation.Observable` are folded to the leading name).
    static func hasObservationMacro(_ attributes: AttributeListSyntax?) -> Bool {
        guard let attributes else { return false }
        for attr in attributes {
            guard let a = attr.as(AttributeSyntax.self) else { continue }
            let name = a.attributeName.trimmedDescription
            let leading = name.split(separator: ".").last.map(String.init) ?? name
            if leading == "Observable" || leading == "Model" { return true }
        }
        return false
    }

    private func popType() {
        typeStack.removeLast()
        typeNativeReason.removeLast()
        typeViewDSLReason.removeLast()
        typeUIKitReason.removeLast()
        typeNativePropertyNames.removeLast()
        typeValueReactivePropertyTypes.removeLast()
    }

    /// Determine whether a type forces native, splitting the reason into:
    ///   - `blanket`: a HARD-native conformance (system delegate, NSObject,
    ///     *Representable…) that forces EVERY member native, always.
    ///   - `viewDSL`: a SwiftUI view-DSL conformance (View/App/Scene/ViewModifier/
    ///     Shape/…). Downgraded to a PER-MEMBER force — only `body` / members
    ///     returning `some View` / `@ViewBuilder` members / reactive-state touches /
    ///     native symbols stay native; pure value members are freed.
    ///   - `uiKit`: a UIKit/AppKit view or view-controller base class
    ///     (`UIViewController`/`UIView`/`UIResponder`/cell/`NSViewController`/…).
    ///     Downgraded to a PER-MEMBER force (UIKit "Phase 1a") — only lifecycle
    ///     overrides / UIKit-symbol touches / `@objc`-family / native-typed-or-
    ///     wrapped-property touches stay native; pure value/logic methods are freed.
    /// Property wrappers never blanket-force (handled per-member via
    /// `nativePropertyNames`). At most one of the three is non-nil (first match wins,
    /// in inheritance order).
    private func nativeReasons(inheritance: InheritanceClauseSyntax?)
        -> (blanket: String?, viewDSL: String?, uiKit: String?)
    {
        guard let inheritance else { return (nil, nil, nil) }
        for inherited in inheritance.inheritedTypes {
            let base = inherited.type.trimmedDescription
            // Take the leading identifier of a possibly-qualified name.
            let leading = base.split(separator: ".").first.map(String.init) ?? base
            guard Self.nativeConformances.contains(leading) else { continue }
            let reason = "type conforms to / inherits \(leading)"
            if Self.viewDSLConformances.contains(leading) {
                return (nil, reason, nil)   // per-member SwiftUI view-DSL treatment
            }
            if Self.uiKitViewConformances.contains(leading) {
                return (nil, nil, reason)   // per-member UIKit view/VC treatment
            }
            return (reason, nil, nil)       // hard blanket force
        }
        return (nil, nil, nil)
    }

    /// Collect the names of properties that touch native state, so a method
    /// REFERENCING any of them is forced native. Sources:
    ///   1. A native **property wrapper** (`@Published`/`@State`/`@IBOutlet`/…) — the
    ///      wrapper's storage is Combine/SwiftUI/IB runtime, never WASM-safe.
    ///   2. A STORED property of native **declared/constructed type**
    ///      (`let tableView: UITableView`, `let label = UILabel()`,
    ///      `let t = UITableView.init()`) — touching such a property hands the method
    ///      a native object even though the property name itself is not a registry
    ///      symbol. This is the (a)/(c) leg of the UIKit per-member rule: without it,
    ///      `self.tableView.reloadData()` (where `reloadData` is unregistered and
    ///      `tableView` is a bare identifier) would slip past every native scan and
    ///      be falsely freed.
    ///   3. A COMPUTED property whose getter is native — either its declared return
    ///      type is native (`var spinner: UIActivityIndicatorView { … }`), or its
    ///      getter body itself references a native symbol (`var derived: String {
    ///      label.text ?? "" }`). A reader of `self.derived` only sees the bare name,
    ///      so the property name must be recorded or the reader would be falsely freed.
    ///
    /// SAFETY: this set only ever ADDS forced-native property names, so it is
    /// strictly more conservative — it can only LOSE coverage, never create a false
    /// negative. A method touching no such property is unaffected. The getter-body
    /// native scan reuses the same `ReferenceCollector` + registry the Classifier
    /// runs with, so it recognises exactly the symbols the Classifier would.
    private func nativePropertyNames(in members: MemberBlockSyntax?,
                                     observationMacroType: Bool = false) -> Set<String> {
        guard let members else { return [] }
        var names: Set<String> = []
        func record(_ ident: String) {
            names.insert(ident)
            // Combine/SwiftUI projected value `$name` and backing storage `_name` too.
            names.insert("$" + ident)
            names.insert("_" + ident)
        }
        func bindingIdent(_ binding: PatternBindingSyntax) -> String? {
            binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        }

        // PASS 1 — wrapper-backed props + native-typed STORED props + computed props
        // whose declared return type is native. These are decidable from the decl
        // alone (no dependence on other property names), so they seed the set first.
        // Deferred computed properties (getter body, no native annotation) are held
        // for pass 2 once the seed set of native names is known.
        var deferredComputed: [(name: String, accessor: AccessorBlockSyntax)] = []
        for member in members.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isNativeWrapped = varDecl.attributes.contains { attr in
                guard let a = attr.as(AttributeSyntax.self) else { return false }
                return Self.nativePropertyWrappers.contains(a.attributeName.trimmedDescription)
            }
            // `@Observable`/`@Model` make every PLAIN STORED `var` reactive, UNLESS the
            // property opts out with `@ObservationIgnored`. A `let` constant is not
            // observed (it never changes), and a computed property is handled below.
            let isObservationIgnored = varDecl.attributes.contains { attr in
                guard let a = attr.as(AttributeSyntax.self) else { return false }
                let n = a.attributeName.trimmedDescription
                return (n.split(separator: ".").last.map(String.init) ?? n) == "ObservationIgnored"
            }
            let isVar = varDecl.bindingSpecifier.text == "var"
            for binding in varDecl.bindings {
                guard let ident = bindingIdent(binding) else { continue }
                if isNativeWrapped { record(ident); continue }
                if let accessor = binding.accessorBlock {
                    if let annotated = binding.typeAnnotation?.type.trimmedDescription,
                       Self.leadingTypeIsNative(annotated) {
                        record(ident)
                    } else {
                        deferredComputed.append((ident, accessor))
                    }
                    continue
                }
                // Observation-macro stored `var` (not ignored) → reactive, like @Published.
                if observationMacroType && isVar && !isObservationIgnored {
                    record(ident); continue
                }
                if Self.isNativeStoredPropertyType(binding) { record(ident) }
            }
        }

        // PASS 2 — a computed property (no native annotation) is native if its
        // getter references a native registry symbol, forces native (selector/objc/
        // unsafe), OR reads one of the native property names seeded in pass 1
        // (`var derived: String { label.text ?? "" }` where `label: UILabel`). A
        // reader of such a property sees only its bare name, so we must record it.
        // Iterated to a fixpoint so a computed prop reading ANOTHER native computed
        // prop is also caught (rare, but free and strictly more conservative).
        var changed = true
        while changed {
            changed = false
            for entry in deferredComputed where !names.contains(entry.name) {
                if accessorTouchesNative(entry.accessor, knownNativeNames: names) {
                    record(entry.name)
                    changed = true
                }
            }
        }
        return names
    }

    /// Does a computed property's accessor block reference any native symbol, force
    /// native (selector/objc/unsafe), or read one of `knownNativeNames`? Reuses the
    /// `ReferenceCollector` + `NativeRegistry.standard` the Classifier uses, so it
    /// recognises the same symbols. Used only to decide whether READERS of the
    /// property must be forced native — strictly additive (never frees anything).
    private func accessorTouchesNative(_ accessor: AccessorBlockSyntax,
                                       knownNativeNames: Set<String>) -> Bool {
        var collector = ReferenceCollector(converter: converter)
        collector.walk(Syntax(accessor))
        if !collector.forcedNativeReasons.isEmpty { return true }
        let registry = NativeRegistry.standard
        for ref in collector.references {
            if knownNativeNames.contains(ref.name) { return true }
            if let hit = registry.match(ref), hit.tier != .wasmSafeFoundation { return true }
        }
        return false
    }

    /// Collect (name → type) of stored properties that are REACTIVE via a SwiftUI/
    /// Combine property wrapper AND whose declared type is VALUE-MARSHALLABLE — the
    /// host-projection candidate set. A reader of such a prop would be forced
    /// native by `nativePropertyNames` (the wrapper makes the name reactive); this
    /// set lets the host-projection gate upgrade that member from `native` to
    /// `mixed` and project the prop's value into the WASM fragment.
    ///
    /// STRICT SUBSET of `nativeNames`: a prop is included ONLY when (a) it is in
    /// `nativeNames` (so it was already a forced-native reactive read) AND (b) its
    /// declared type is value-marshallable. So this can only ever turn a would-be
    /// `native` member into `mixed`; it can never free a member the old rule caught.
    /// Conservative: a wrapped prop with NO explicit type annotation, or a
    /// non-value-marshallable type, is omitted (the reader stays native).
    private func valueReactivePropertyTypes(in members: MemberBlockSyntax?,
                                            nativeNames: Set<String>,
                                            observationMacroType: Bool = false) -> [String: String] {
        guard let members else { return [:] }
        var out: [String: String] = [:]
        for member in members.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            // The reactivity source is EITHER a reactive property wrapper
            // (`@Published`/`@State`/…) OR — for an `@Observable`/`@Model` type — the
            // Observation macro over a plain stored `var`.
            let wrapper = varDecl.attributes.compactMap { attr -> String? in
                guard let a = attr.as(AttributeSyntax.self) else { return nil }
                let name = a.attributeName.trimmedDescription
                return Self.nativePropertyWrappers.contains(name) ? name : nil
            }.first
            // `@IBOutlet`/`@NSManaged` are genuine native-object outlets, never a
            // marshallable value — exclude them outright (defensive; their types
            // also won't be value-marshallable).
            if wrapper == "IBOutlet" || wrapper == "NSManaged" { continue }
            let isObservationIgnored = varDecl.attributes.contains { attr in
                guard let a = attr.as(AttributeSyntax.self) else { return false }
                let n = a.attributeName.trimmedDescription
                return (n.split(separator: ".").last.map(String.init) ?? n) == "ObservationIgnored"
            }
            // Stored `var` under an observation-macro type counts as reactive even with
            // no explicit wrapper. A computed prop / `let` constant is NOT a reactive
            // storage candidate (a computed value is recomputed; a `let` never changes).
            let isVar = varDecl.bindingSpecifier.text == "var"
            let observationStored = observationMacroType && isVar && !isObservationIgnored
                && varDecl.bindings.allSatisfy { $0.accessorBlock == nil }
            guard wrapper != nil || observationStored else { continue }
            for binding in varDecl.bindings {
                guard let ident = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                else { continue }
                // Only a prop already treated as a forced-native reactive name
                // qualifies (keeps this a strict subset — never frees anything).
                guard nativeNames.contains(ident) else { continue }
                // (1) An explicit annotation is the most reliable type source.
                if let annotated = binding.typeAnnotation?.type.trimmedDescription,
                   let marshallable = Self.valueMarshallableType(annotated) {
                    out[ident] = marshallable
                    continue
                }
                // (2) No annotation — infer a value-marshallable type from a LITERAL
                // initializer. Real `@Published` props very often use inference
                // (`@Published var isEnabled = true`, `var searchText = ""`, `var
                // count = 0`); without this they were skipped and their readers stayed
                // native. ONLY a literal whose type is unambiguous and marshallable is
                // accepted (a bare `true`/`""`/`0`/`0.0` + a homogeneous scalar array
                // literal); a constructor / member / function-call initializer is
                // ambiguous and is left out (conservative → the reader stays native,
                // never mistyped). This can only turn a would-be `native` reactive
                // read into a host-projectable `mixed` — strictly additive.
                if let initVal = binding.initializer?.value,
                   let inferred = Self.marshallableLiteralType(initVal) {
                    out[ident] = inferred
                }
            }
        }
        return out
    }

    /// The value-marshallable type of a LITERAL initializer expression, or nil. Only
    /// unambiguous literals: `Bool`/`Int`/`Double`/`String`, and a homogeneous array
    /// literal of those (`[Int]`/`[String]`/…). Everything else (a constructor, a
    /// member access like `.normal`, a function call, an enum case, a heterogeneous
    /// or empty array) is ambiguous → nil (the reader stays native; never mistyped).
    static func marshallableLiteralType(_ expr: ExprSyntax) -> String? {
        if expr.is(BooleanLiteralExprSyntax.self) { return "Bool" }
        if expr.is(IntegerLiteralExprSyntax.self) { return "Int" }
        if expr.is(FloatLiteralExprSyntax.self) { return "Double" }
        if expr.is(StringLiteralExprSyntax.self) { return "String" }
        if let arr = expr.as(ArrayExprSyntax.self), !arr.elements.isEmpty {
            var elem: String?
            for el in arr.elements {
                guard let t = marshallableLiteralType(el.expression),
                      marshallableScalars.contains(t) else { return nil }
                if let e = elem { if e != t { return nil } } else { elem = t }
            }
            if let elem { return "[\(elem)]" }
        }
        return nil
    }

    /// The canonical value-marshallable type string for a declared type, or nil if
    /// the type is NOT safely marshallable across the WASM JSON ABI. Accepts:
    ///   - scalars / String / Bool (the JSON-codable primitives the splitter +
    ///     emitter already round-trip),
    ///   - a single optional of those (`Int?`),
    ///   - a homogeneous array of those (`[String]`, `[Int]`) and `[T]?`.
    /// Everything else — a project value-struct, an enum, a tuple, a dictionary, a
    /// nested array, any native/reference type — returns nil (conservative: the
    /// reader stays native). Enums/value-structs are deferred (subset (c)); only
    /// the proven-safe scalar/String/Bool + scalar-array subset is accepted here.
    static func valueMarshallableType(_ type: String) -> String? {
        var t = type.trimmingCharacters(in: .whitespaces)
        // Single trailing optional is fine (`Int?` → `Int?`).
        let optional = t.hasSuffix("?")
        if optional { t = String(t.dropLast()).trimmingCharacters(in: .whitespaces) }
        // IUO (`String!`) is not a value we want to marshal implicitly — reject.
        if t.hasSuffix("!") { return nil }
        // Array of scalars: `[Scalar]`.
        if t.hasPrefix("[") && t.hasSuffix("]") {
            let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            // Reject dictionaries (`[K: V]`) and nested arrays — only flat scalar
            // arrays are accepted in this increment.
            guard !inner.contains(":"), !inner.contains("["), marshallableScalars.contains(inner)
            else { return nil }
            return optional ? "[\(inner)]?" : "[\(inner)]"
        }
        guard marshallableScalars.contains(t) else { return nil }
        return optional ? "\(t)?" : t
    }

    /// The exact scalar/string primitive type names accepted as directly
    /// JSON-ABI-marshallable (matches the splitter/emitter's proven set).
    static let marshallableScalars: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "Bool", "String",
    ]

    /// Does a member body WRITE (assign / mutate-in-place / pass `inout`) any of
    /// `reactiveNames`? A getter never can, but a `method` could (`func reset() {
    /// count = 0 }`), and a write cannot be host-projected (the WASM fragment can't
    /// write back reactive state). Conservative: if ANY assignment LHS, compound
    /// assignment, or `&`-inout argument names a reactive prop (bare or via `self.`),
    /// the member is NOT host-projectable. Also rejects a bare assignment whose LHS
    /// we cannot resolve to a simple identifier/`self.x` (over-rejects → safe).
    static func bodyWritesReactiveProperty(_ body: Syntax, reactiveNames: Set<String>) -> Bool {
        let scanner = ReactiveWriteScanner(reactiveNames: reactiveNames)
        scanner.walk(body)
        return scanner.writes
    }

    /// Does a member body WRITE a NON-reactive instance property via `self.<x> = …`
    /// (or `self.<x>` compound-assignment)? This is the discriminator for the
    /// PARTIAL host-projection gate (subset (b)): a method that reads a reactive
    /// prop AND writes back a non-reactive stored property is the genuine partial
    /// shape (`func refresh(){ let v = counter*2; self.cache = v }`). A member with
    /// NO such write is either a clean value member (handled / soundly rejected by
    /// the whole-body gate) or has no native shell statement to keep — so the
    /// partial gate must NOT fire for it (re-admitting it would route an
    /// unmarshallable-return computed property to `mixed`). Reactive writes are NOT
    /// counted here (they are rejected separately by `bodyWritesReactiveProperty`).
    /// Conservative: only a `self.`-qualified write counts (a bare `x = …` is
    /// ambiguous between a local and an implicit-self member; ignoring it can only
    /// cost coverage, never soundness — the splitter is still the ground truth).
    static func bodyWritesNonReactiveSelfProperty(_ body: Syntax, reactiveNames: Set<String>) -> Bool {
        let scanner = SelfPropertyWriteScanner(reactiveNames: reactiveNames)
        scanner.walk(body)
        return scanner.writesNonReactive
    }

    /// Do any of a member's body references resolve to a registry NON-WASM symbol
    /// (`mustStayNative` like `CLLocation`/`URLSession`/`ModelContext`, OR
    /// `bridgeable` like `UserDefaults`)? The FunctionExtractor's own `nativeFlags`
    /// capture forced interop (ObjC/selector/unsafe/native types) but NOT plain
    /// registry symbols — the Classifier adds those later. The host-projection gate
    /// scans them here so a member that ALSO touches a native/bridged API is never
    /// recorded host-projectable. This keeps the gate self-consistent: a
    /// host-projectable record is genuinely pure-over-wasm-safe + the reactive
    /// reads, so the Classifier always routes it to `mixed` (never `bridged`/native)
    /// and the splitter's host-projection fragment is sound (pure + wasm-safe only).
    /// Uses the same `NativeRegistry.standard` the Classifier scans with;
    /// `wasmSafeFoundation` symbols (`Date`/`Decimal`/`Locale`/…) do NOT count.
    static func referencesMustStayNative(_ references: [Reference]) -> Bool {
        let registry = NativeRegistry.standard
        for ref in references {
            if let hit = registry.match(ref),
               hit.tier == .mustStayNative || hit.tier == .bridgeable { return true }
        }
        return false
    }

    /// Does a stored-property binding have a native (UIKit/AppKit/registry-native)
    /// type — from its explicit annotation or its constructor initializer?
    /// Conservative: only a confidently-native leading type counts; anything we
    /// cannot resolve is treated as NOT native here (the property name is then left
    /// to the other native scans, and the method's own body refs still gate it).
    private static func isNativeStoredPropertyType(_ binding: PatternBindingSyntax) -> Bool {
        // (a) explicit type annotation: `let x: UITableView` / `[UIView]` / `UILabel?`.
        if let annotated = binding.typeAnnotation?.type.trimmedDescription,
           leadingTypeIsNative(annotated) {
            return true
        }
        // (b) initializer is a constructor call whose called type is native:
        //     `let x = UILabel()`, `UIButton(type: .system)`, `UITableView.init()`,
        //     `UIKit.UILabel()`. Resolve the called expression to its leading nominal.
        if let initExpr = binding.initializer?.value.as(FunctionCallExprSyntax.self),
           let typeName = constructedTypeName(initExpr.calledExpression) {
            return isNativeTypeName(typeName)
        }
        return false
    }

    /// The nominal type name a constructor-call's called-expression denotes, if it
    /// is a plain type reference or a `Type.init` / `Module.Type` member access.
    /// Returns nil for non-constructor expressions (a value method call, a closure,
    /// etc.) — kept conservative so only confident constructors add the property.
    private static func constructedTypeName(_ callee: ExprSyntax) -> String? {
        // `UILabel(...)` — a bare type reference.
        if let ref = callee.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            return name.first?.isUppercase == true ? name : nil
        }
        // `UITableView.init(...)` or `UIKit.UILabel(...)` — a member access. The
        // native type is the `.init` base, or the trailing nominal of a qualified
        // type. Either way, scan base→member for the first uppercase nominal that
        // the registry knows.
        if let member = callee.as(MemberAccessExprSyntax.self) {
            let memberName = member.declName.baseName.text
            if memberName == "init", let base = member.base {
                return constructedTypeName(base)
            }
            // `UIKit.UILabel` → the member name is the type.
            if memberName.first?.isUppercase == true { return memberName }
            // Fall back to the base (`Foundation.Type.init` chains).
            if let base = member.base { return constructedTypeName(base) }
        }
        return nil
    }

    /// The leading nominal of a (possibly optional/array/qualified) type string is a
    /// registry-native type. Handles `UITableView`, `UILabel?`, `[UIView]`,
    /// `UIKit.UIView`, `UITableView!`.
    private static func leadingTypeIsNative(_ type: String) -> Bool {
        var t = type.trimmingCharacters(in: .whitespaces)
        // Strip array brackets and optional/IUO suffixes.
        while t.hasPrefix("[") && t.hasSuffix("]") {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        while t.hasSuffix("?") || t.hasSuffix("!") { t = String(t.dropLast()) }
        // Take the leading identifier of a possibly-qualified / generic name.
        let leading = t.split(whereSeparator: { $0 == "." || $0 == "<" || $0 == " " || $0 == "(" })
            .first.map(String.init) ?? t
        return isNativeTypeName(leading)
    }

    /// Is `name` a UIKit/AppKit/registry-native TYPE name (the (a)/(c) gate). Uses
    /// the same `NativeRegistry.standard` the Classifier scans with, so a property
    /// typed with any `mustStayNative`/`bridgeable` framework type (UIKit views,
    /// AVFoundation, CoreLocation, …) is recognised. WASM-safe Foundation value
    /// types (`Date`/`Decimal`/`Codable`) are NOT native, so a `let d: Date` prop is
    /// correctly NOT forced — keeping pure value-type fields free.
    private static func isNativeTypeName(_ name: String) -> Bool {
        guard let entry = NativeRegistry.standard.entry(for: name) else { return false }
        return entry.tier != .wasmSafeFoundation
    }

    // MARK: - Function declarations

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let signature = signatureString(name: node.name.text, params: node.signature.parameterClause.parameters)
        let kind: FunctionKind = typeStack.isEmpty ? .function : .method
        emitRecord(
            simpleName: node.name.text,
            signature: signature,
            kind: kind,
            node: Syntax(node),
            body: node.body.map { Syntax($0) },
            attributes: node.attributes,
            modifiers: node.modifiers,
            signatureTypes: Syntax(node.signature),
            declaredReturnType: node.signature.returnClause?.type.trimmedDescription,
            hasViewBuilderAttr: Self.hasResultBuilderAttr(node.attributes)
        )
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let signature = signatureString(name: "init", params: node.signature.parameterClause.parameters)
        emitRecord(
            simpleName: "init",
            signature: signature,
            kind: .initializer,
            node: Syntax(node),
            body: node.body.map { Syntax($0) },
            attributes: node.attributes,
            modifiers: node.modifiers,
            signatureTypes: Syntax(node.signature)
        )
        return .visitChildren
    }

    // MARK: - Computed properties & accessors

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Record the function-stack depth on entry; the matching `visitPost` below
        // truncates back to it, popping however many entries the computed-property /
        // accessor `emitRecord`s pushed (each pushes one, to qualify closures in its
        // body). Without this, those pushes never got popped — see `varDeclPushCounts`.
        varDeclPushCounts.append(functionStack.count)
        // Only computed properties (those with an accessor block / getter body) qualify.
        for binding in node.bindings {
            guard let accessor = binding.accessorBlock else { continue }
            let propName = binding.pattern.trimmedDescription
            let declType = binding.typeAnnotation?.type.trimmedDescription
            let isVB = Self.hasResultBuilderAttr(node.attributes)
            switch accessor.accessors {
            case .getter(let codeBlock):
                emitRecord(
                    simpleName: propName,
                    signature: propName,
                    kind: .computedProperty,
                    node: Syntax(binding),
                    body: Syntax(codeBlock),
                    attributes: node.attributes,
                    modifiers: node.modifiers,
                    declaredReturnType: declType,
                    hasViewBuilderAttr: isVB
                )
            case .accessors(let list):
                for acc in list {
                    guard let block = acc.body else { continue }
                    let kindName = acc.accessorSpecifier.text
                    emitRecord(
                        simpleName: "\(propName).\(kindName)",
                        signature: "\(propName).\(kindName)",
                        kind: .accessor,
                        node: Syntax(acc),
                        body: Syntax(block),
                        attributes: node.attributes,
                        modifiers: node.modifiers,
                        declaredReturnType: declType,
                        hasViewBuilderAttr: isVB
                    )
                }
            }
        }
        return .visitChildren
    }

    // Pop whatever the computed-property / accessor records pushed onto the
    // function-name stack while this `VariableDeclSyntax` (and its descendants)
    // were in scope, restoring the depth captured on entry. Truncating (rather
    // than a fixed number of `removeLast`s) is robust to a var decl that emits
    // multiple records (a get/set pair) or none (a stored property).
    override func visitPost(_ node: VariableDeclSyntax) {
        if let depth = varDeclPushCounts.popLast(), functionStack.count > depth {
            functionStack.removeLast(functionStack.count - depth)
        }
    }

    // MARK: - Closures

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        let loc = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let simple = "closure@L\(loc.line)"
        emitRecord(
            simpleName: simple,
            signature: simple,
            kind: .closure,
            node: Syntax(node),
            body: Syntax(node.statements),
            attributes: nil,
            modifiers: nil
        )
        return .visitChildren
    }

    // MARK: - Record emission

    private func emitRecord(
        simpleName: String,
        signature: String,
        kind: FunctionKind,
        node: Syntax,
        body: Syntax?,
        attributes: AttributeListSyntax?,
        modifiers: DeclModifierListSyntax?,
        signatureTypes: Syntax? = nil,
        declaredReturnType: String? = nil,
        hasViewBuilderAttr: Bool = false
    ) {
        let start = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let end = converter.location(for: node.endPositionBeforeTrailingTrivia)

        // Build qualified id from module + type stack + (enclosing functions for closures) + signature.
        var components = [moduleName] + typeStack
        if kind == .closure { components += functionStack }
        let id = (components + [signature]).joined(separator: ".")

        // Collect references and native flags from attributes/modifiers + body.
        var collector = ReferenceCollector(converter: converter)
        var nativeFlags: [String] = []

        // Type-level forced native (hard-native conformance: UIViewController,
        // NSObject, system delegate, *Representable…) applies to EVERY member.
        if let reason = currentTypeNativeReason {
            nativeFlags.append(reason)
        }

        // PER-MEMBER view-DSL rule. A member of a View/App/Scene/ViewModifier/
        // Shape-conforming type stays native ONLY if it is the view DSL itself;
        // otherwise it is freed and classified on its merits (the body references +
        // reactive-property + signature checks below still apply, so safety is
        // unchanged — any native touch still forces native). This mirrors the
        // engine's existing per-member `@Published`/`ObservableObject` carve-out,
        // extended to view structs, and is the SwiftUI value-lift coverage lever.
        //
        // SAFETY (zero false negatives): we KEEP native any member that
        //   (a) is `body` (or a `body`-like view-builder property), or
        //   (b) returns `some View` / a SwiftUI view type, or
        //   (c) is annotated with a result-builder (`@ViewBuilder`/`@SceneBuilder`/
        //       …) — its statements are view DSL, not a single liftable value.
        // Everything we are unsure about defaults to native via these checks; the
        // existing reactive-property + native-symbol passes catch the rest. The
        // rule only ever REMOVES the blanket flag, then re-runs the unchanged
        // downstream checks — it cannot bypass a native check, so it cannot create
        // a false negative (only, at worst, a false positive = lost coverage).
        if let viewReason = currentViewDSLReason {
            let isViewBody = (simpleName == "body")
            let returnsView = (declaredReturnType.map(Self.isViewReturnType) ?? false)
            let isViewBuilder = hasViewBuilderAttr
            if isViewBody || returnsView || isViewBuilder {
                nativeFlags.append("\(viewReason) — view-DSL member (\(simpleName))")
            }
            // else: freed for per-merit classification (no flag added here).
        }

        // PER-MEMBER UIKit-view/VC rule (UIKit "Phase 1a"). A member of a
        // UIViewController/UIView/UIResponder/cell (or AppKit equivalent) stays
        // native ONLY if it is a UIKit LIFECYCLE OVERRIDE (e) — `viewDidLoad`,
        // `loadView`, `viewWillAppear`, `layoutSubviews`, `draw(_:)`, … — whose body
        // imperatively mutates `self`/the view tree and is not a re-runnable pure
        // value. The OTHER legs of the keep-native rule are enforced by the
        // unchanged downstream scans, so they need no flag here:
        //   (b) references a UIKit/native type or API → the registry `mustStayNative`
        //       scan in the Classifier fires (UIView/UILabel/UIColor/CGContext/… are
        //       all `mustStayNative`),
        //   (c)/(a) touches an @IBOutlet / native-property-wrapper / native-typed
        //       stored property → the `nativePropertyNames` pass below fires,
        //   (d) is @objc/@IBAction/#selector/dynamic → the `nativeAttributes` /
        //       `dynamic` / `#selector` scans below fire.
        // A pure value-returning/computation method touching NONE of those is FREED
        // to classify on its merits (may become `wasmEligible`). Mirrors the view-DSL
        // carve-out: the rule only ever REMOVES the blanket flag and re-runs the
        // unchanged native-detection — it cannot bypass a native check, so it cannot
        // create a false negative (only, at worst, lose coverage). When in doubt
        // (a lifecycle name we cannot prove pure), we KEEP native.
        if let uiKitReason = currentUIKitReason {
            if kind == .method, Self.uiKitLifecycleMethodNames.contains(simpleName) {
                nativeFlags.append("\(uiKitReason) — UIKit lifecycle override (\(simpleName))")
            }
            // else: freed for per-merit classification (no flag added here); the
            // body-reference / native-property / signature / @objc scans still apply.
        }

        // Attributes like @objc / @IBAction / @State force native handling.
        if let attributes {
            for attr in attributes {
                if let a = attr.as(AttributeSyntax.self) {
                    let attrName = a.attributeName.trimmedDescription
                    collector.references.append(
                        Reference(name: attrName, kind: .attribute,
                                  line: converter.location(for: a.positionAfterSkippingLeadingTrivia).line)
                    )
                    if Self.nativeAttributes.contains(attrName) {
                        nativeFlags.append("@\(attrName)")
                    }
                }
            }
        }
        // `dynamic` modifier => ObjC dispatch => native.
        if let modifiers {
            for mod in modifiers where mod.name.text == "dynamic" {
                nativeFlags.append("dynamic")
            }
        }

        if let body {
            collector.walk(body)
            nativeFlags.append(contentsOf: collector.forcedNativeReasons)
        }

        // PER-MEMBER UIKit-view/VC rule, part 2 (body-reference leg). Inside a
        // UIViewController/UIView/cell subclass, the INHERITED UIKit surface is huge
        // and almost never declared in the subclass body: `view`, `navigationController`,
        // `tableView`, `dismiss(…)`, `present(…)`, `addSubview(…)`, `setNeedsLayout()`,
        // and any `super.<uikitMethod>()`. None of these is a registry symbol or a
        // locally-declared native property, so without this guard a method like
        // `func tag() -> Int { view.tag }` or `func close() { dismiss(animated:true) }`
        // would be FALSELY freed to WASM (the old blanket force masked this entirely).
        // Keep native any UIKit-type member that:
        //   - references `super` (a `super.` access resolves to a UIKit superclass
        //     member — always native), or
        //   - references a known inherited UIKit VC/View member name (as an identifier,
        //     a member-access member, or a function call).
        // SAFETY: this is purely ADDITIVE forced-native (the cardinal invariant). It
        // is conservative — over-matching a same-named pure local just costs coverage.
        // Scoped to the UIKit per-member rule (`currentUIKitReason`), so it never
        // affects non-UIKit types.
        if currentUIKitReason != nil {
            if let touched = collector.references.first(where: { ref in
                ref.name == "super" || ref.base == "super"
                    || Self.uiKitInheritedMemberNames.contains(ref.name)
            }) {
                nativeFlags.append("UIKit inherited member / super access ('\(touched.name)')")
            }
        }

        // Also scan the function signature (parameter & return types). A
        // parameter typed `NSManagedObjectContext`/`CLLocation`/etc. exposes a
        // native dependency even when the body only calls `.save()` on it.
        // Critical for zero false negatives: without this a native-typed param
        // operated on by a bare member call would slip through as wasmEligible.
        if let signatureTypes {
            var sigCollector = ReferenceCollector(converter: converter)
            sigCollector.walk(signatureTypes)
            collector.references.append(contentsOf: sigCollector.references)
            nativeFlags.append(contentsOf: sigCollector.forcedNativeReasons)
        }

        // Snapshot the native flags accumulated from EVERYTHING except the reactive
        // read below. The host-projection upgrade fires ONLY when this is empty —
        // i.e. the reactive read is the *sole* reason the member would be native.
        // (Any genuine native interop — ObjC/selector/unsafe, a `mustStayNative`
        // symbol, a native-typed signature, a blanket/UIKit/view-DSL force — has
        // already pushed a flag here, so it disqualifies host-projection.)
        let nativeFlagsBeforeReactive = nativeFlags.count

        // Per-member native property-wrapper rule: if this member references a
        // property declared with a native wrapper (@Published/@State/…), it
        // touches Combine/SwiftUI runtime state → force native. Pure siblings on
        // the same type are untouched. (Skip for closures whose enclosing member
        // already carries this.)
        let nativeProps = nativePropertyNamesInScope
        // A reactive prop name SHADOWED by this member's own parameter or a local
        // binding is NOT a reactive read — the body's reference denotes the local,
        // not `self.<prop>`. Treating it as reactive would (a) over-force a pure
        // function native, and worse (b) host-project the WRONG value (project
        // `self.count` while the body uses the param `count`) — a render/compute bug.
        // Exclude such shadowed names. EXCEPTION: a `self.`-qualified reference is
        // never shadowed, so a body that ALSO does an explicit `self.<prop>` read keeps
        // the prop reactive (conservative — caught by the explicit-base check below).
        let locallyShadowed = nativeProps.isEmpty ? [] : Self.locallyBoundNames(in: node)
        let touchedReactive: [String] = nativeProps.isEmpty ? [] : {
            var seen: Set<String> = []
            var out: [String] = []
            for ref in collector.references where nativeProps.contains(ref.name) {
                // A bare/implicit reference to a SHADOWED name is the local, not the
                // reactive prop — skip it. An EXPLICIT `self.<name>` member access
                // (base == "self") always denotes the prop, never the local → count it.
                let isExplicitSelfMember = ref.kind == .memberAccess && ref.base == "self"
                if locallyShadowed.contains(ref.name) && !isExplicitSelfMember { continue }
                if seen.insert(ref.name).inserted { out.append(ref.name) }
            }
            return out
        }()
        if let firstTouched = touchedReactive.first {
            nativeFlags.append("references reactive property '\(firstTouched)' (@Published/@State storage)")
        }

        // HOST-PROJECTION UPGRADE (the "pure-logic-over-reactive-reads" lift).
        //
        // A member that would be native ONLY because it READS reactive properties
        // — and writes none of them, touches no other native interop, and returns
        // a marshallable value type — can instead be HOST-PROJECTED: the native
        // shell reads the reactive props, marshals their values into a lifted WASM
        // fragment, and the fragment runs the pure logic over those values (it
        // never touches reactive state). This mirrors what the SwiftUI view-body
        // path already does for `@State` scalars, extended to the general engine.
        //
        // The member is recorded with `hostProjectableReads` instead of
        // `forcesNative`, which routes it to `mixed` (not `native`, not pure
        // `wasmEligible`). The FunctionSplitter is the ground truth: if it cannot
        // realize a compilable projection, nothing ships and the member is native
        // in the realized pass — so this upgrade is demote-safe by construction.
        //
        // GATE (ALL must hold — when in doubt, stay native):
        //   1. it is a getter-shaped value member (computed property / `get`
        //      accessor / method) — never an `init`, `set`/`willSet`/`didSet`, or
        //      closure (those have no clean single-value projection),
        //   2. the reactive read is the SOLE native reason (`nativeFlagsBeforeReactive == 0`),
        //   3. it touches NO registry NON-WASM symbol in its body — `mustStayNative`
        //      (`CLLocation`/`URLSession`/`ModelContext`) OR `bridgeable`
        //      (`UserDefaults`). Those are symbols the FunctionExtractor's own flags
        //      don't capture (the Classifier adds them later); scanning here keeps the
        //      gate self-consistent so a host-projectable member is pure-over-wasm-safe
        //      + the reactive reads (Classifier always routes it `mixed`, never
        //      `bridged`/native; the splitter's fragment is sound — wasm-safe only),
        //   4. it reads ≥1 reactive prop and EVERY reactive prop it reads is a
        //      value-marshallable host-projection candidate (a native-typed
        //      reactive prop like `connections: [SomeModel]` disqualifies — that is
        //      the AuthService `user: User?` safety boundary),
        //   5. it declares a marshallable value return type,
        //   6. it WRITES no reactive property (a getter cannot, but a method could;
        //      a write can't be projected, so it stays native).
        var hostProjectableReads: [HostProjectableRead] = []
        var hostProjectablePartial = false
        let valueReactive = valueReactivePropertyTypesInScope
        let isGetterShaped = (kind == .computedProperty || kind == .method)
            || (kind == .accessor && simpleName.hasSuffix(".get"))
        if isGetterShaped,
           nativeFlagsBeforeReactive == 0,
           !touchedReactive.isEmpty,
           !Self.referencesMustStayNative(collector.references),
           let returnType = declaredReturnType,
           Self.valueMarshallableType(returnType) != nil,
           touchedReactive.allSatisfy({ valueReactive[$0] != nil }),
           let body, !Self.bodyWritesReactiveProperty(body, reactiveNames: nativeProps),
           // A value-returning method that ALSO writes a non-reactive prop
           // (`func step(_ d:Int)->Int { let n = base+d; self.last = n; return n }`)
           // has a native shell statement the whole-body single-value fragment can't
           // absorb — route it to the PARTIAL gate below instead (which keeps the
           // write in the shell). Without this exclusion the whole-body gate claims
           // it, then `strategyHostProjection` can't realize it (the `self` write),
           // and it ships nothing. The partial gate splits it for real.
           !Self.bodyWritesNonReactiveSelfProperty(body, reactiveNames: nativeProps) {
            // Project EXACTLY the reactive props this member reads, with their
            // proven value-marshallable types. Sorted for deterministic codegen.
            hostProjectableReads = touchedReactive.sorted().map {
                HostProjectableRead(name: $0, type: valueReactive[$0]!)
            }
            // This member is no longer forced native — its reactive read is
            // host-projected. Drop the reactive flag so the classifier sees a clean
            // host-projectable member (routed to `mixed`).
            if let idx = nativeFlags.firstIndex(where: { $0.hasPrefix("references reactive property") }) {
                nativeFlags.remove(at: idx)
            }
        }

        // HOST-PROJECTION (subset (b) — MULTI-STATEMENT PARTIAL PROJECTION).
        //
        // The whole-body gate above lifts ONLY a clean single-value member (one
        // that returns a marshallable value and writes nothing). But the dominant
        // real-world shape is a METHOD that reads a reactive prop among otherwise-
        // pure statements AND writes back a NON-reactive stored property / returns
        // Void: e.g. `func update() { let x = published; let y = compute(x); cache
        // = transform(y) }`. The whole body can't be a single value fragment (the
        // `cache = …` write keeps `self`), so the whole-body gate (which requires a
        // marshallable return + zero writes) skips it and it stays native.
        //
        // Such a method can still be PARTIALLY split: the native shell projects the
        // reactive reads into locals, the pure middle statements (`let x = …; let y
        // = compute(x)`) ride WASM, and the native write (`cache = transform(y)`)
        // stays verbatim in the shell. We mark the reactive reads host-projectable
        // and set `hostProjectablePartial`; the FunctionSplitter's
        // `strategyHostProjectionPartial` is the GROUND TRUTH — if it cannot realize
        // a sound statement-level partition (e.g. a reactive write, ordering/
        // aliasing hazard, no liftable pure run) it returns nil and the member is
        // native in the realized pass. So this is demote-safe by construction.
        //
        // GATE (additive — fires ONLY when the whole-body gate did NOT, so subset
        // (a) is untouched; ALL must hold):
        //   1. getter-shaped value member (method / computed prop / `.get`) — same
        //      shapes the whole-body gate considers (never init/set/closure),
        //   2. the reactive read is the SOLE native-symbol reason
        //      (`nativeFlagsBeforeReactive == 0`) — identical to subset (a); a
        //      genuine native interop touch disqualifies,
        //   3. it touches NO registry NON-WASM symbol (`mustStayNative`/`bridgeable`)
        //      — same self-consistency requirement as subset (a),
        //   4. it reads ≥1 reactive prop and EVERY reactive prop it reads is a
        //      value-marshallable host-projection candidate (the native-typed
        //      reactive read safety boundary),
        //   5. it WRITES no reactive property (a reactive write can never be
        //      projected back across the ABI — the `recompute(){ sum += … }`
        //      safety boundary). Plain non-reactive `self.<x> = …` writes are fine:
        //      they stay verbatim in the native shell.
        //   6. it WRITES ≥1 non-reactive instance property via `self.<x> = …` — the
        //      genuine partial shape. This DISCRIMINATES (b) from a clean value
        //      member: a computed property that merely returns an unmarshallable
        //      value (`var pair: Pair { Pair(a: x, b: x) }`) has no native shell
        //      statement, so it must stay native (the whole-body gate's domain), not
        //      be re-admitted here as `mixed`.
        // No return-type requirement (Void is welcome) — that, plus the allowed
        // non-reactive write, is exactly what distinguishes (b) from (a).
        if hostProjectableReads.isEmpty,
           isGetterShaped,
           nativeFlagsBeforeReactive == 0,
           !touchedReactive.isEmpty,
           !Self.referencesMustStayNative(collector.references),
           touchedReactive.allSatisfy({ valueReactive[$0] != nil }),
           let body, !Self.bodyWritesReactiveProperty(body, reactiveNames: nativeProps),
           Self.bodyWritesNonReactiveSelfProperty(body, reactiveNames: nativeProps) {
            hostProjectableReads = touchedReactive.sorted().map {
                HostProjectableRead(name: $0, type: valueReactive[$0]!)
            }
            hostProjectablePartial = true
            if let idx = nativeFlags.firstIndex(where: { $0.hasPrefix("references reactive property") }) {
                nativeFlags.remove(at: idx)
            }
        }

        records.append(
            FunctionRecord(
                id: id,
                kind: kind,
                sourceFile: file,
                startLine: start.line,
                endLine: end.line,
                bodyReferences: collector.references,
                forcesNative: !nativeFlags.isEmpty,
                nativeFlags: nativeFlags,
                hostProjectableReads: hostProjectableReads,
                hostProjectablePartial: hostProjectablePartial
            )
        )

        // Track function name for closure qualification while we descend.
        if kind != .closure {
            functionStack.append(signature)
        }
    }

    // Pop the function-name stack on the way out so closure qualification stays correct.
    override func visitPost(_ node: FunctionDeclSyntax) {
        if !functionStack.isEmpty { functionStack.removeLast() }
    }
    override func visitPost(_ node: InitializerDeclSyntax) {
        if !functionStack.isEmpty { functionStack.removeLast() }
    }

    // MARK: - Helpers

    /// Does an attribute list carry a SwiftUI result-builder attribute? Such a
    /// member's body is view DSL (a chain of view literals), not a single liftable
    /// value, so it stays native under the per-member view-DSL rule.
    static func hasResultBuilderAttr(_ attributes: AttributeListSyntax?) -> Bool {
        guard let attributes else { return false }
        for attr in attributes {
            guard let a = attr.as(AttributeSyntax.self) else { continue }
            if resultBuilderAttrs.contains(a.attributeName.trimmedDescription) { return true }
        }
        return false
    }
    /// Result-builder attributes whose presence marks a member as view DSL.
    static let resultBuilderAttrs: Set<String> = [
        "ViewBuilder", "SceneBuilder", "ToolbarContentBuilder", "CommandsBuilder",
        "WidgetBundleBuilder", "AccessibilityRotorContentBuilder",
    ]

    /// Is a declared return type a SwiftUI view (so the member is view DSL, kept
    /// native under the per-member view-DSL rule)? Conservative: any `some View`,
    /// `AnyView`, or a type whose leading identifier is a known SwiftUI view type
    /// counts. When in doubt about a type we DON'T free it — only a confidently
    /// value-typed member is freed — so this only needs to catch the obvious
    /// view-returning shapes to keep the DSL native.
    static func isViewReturnType(_ type: String) -> Bool {
        let t = type.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("some ") { return true }   // `some View`, `some Shape`, …
        if t.hasPrefix("any ") { return true }     // `any View`
        if t.contains("View") { return true }      // AnyView, EmptyView, …View
        let leading = t.split(whereSeparator: { $0 == "<" || $0 == "." || $0 == " " })
            .first.map(String.init) ?? t
        return viewReturnTypeNames.contains(leading)
    }
    /// Concrete SwiftUI view/result-builder return types that mark a member as DSL.
    static let viewReturnTypeNames: Set<String> = [
        "Text", "Image", "Button", "VStack", "HStack", "ZStack", "List", "Group",
        "Section", "Form", "Color", "Label", "Spacer", "Divider", "Toggle",
        "Picker", "Shape", "Path", "Rectangle", "RoundedRectangle", "Circle",
        "ProgressView", "ScrollView", "TabView", "ModifiedContent", "TupleView",
        "Body", "Content", "Scene", "Commands", "WidgetConfiguration", "AnyView",
        "EmptyView", "GeometryReader", "NavigationStack", "NavigationView",
        "NavigationLink", "Menu", "Stepper", "Slider", "TextField", "SecureField",
        "DatePicker", "Gradient", "LinearGradient", "Capsule", "Ellipse",
    ]

    /// Build a Swift-style argument-label signature, e.g. `submitOrder(_:)`,
    /// `calculateOrderTotal(items:promoCode:)`.
    private func signatureString(name: String, params: FunctionParameterListSyntax) -> String {
        let labels = params.map { param -> String in
            // External label is `firstName` unless it is `_`; if absent, use the internal name.
            let first = param.firstName.text
            return "\(first):"
        }
        return "\(name)(\(labels.joined()))"
    }

    /// Attributes that immediately force native classification.
    static let nativeAttributes: Set<String> = [
        "objc", "IBAction", "IBOutlet", "IBInspectable", "IBDesignable",
        "NSManaged", "NSCopying", "GKInspectable", "main", "UIApplicationMain",
        "NSApplicationMain",
    ]

    /// Protocols / base classes whose conformers/subclasses are native. Two subsets
    /// are forced PER-MEMBER rather than blanket:
    ///   - `viewDSLConformances` (SwiftUI View/App/Scene/…) — only `body` /
    ///     `some View`-returning / `@ViewBuilder` / reactive / native members native.
    ///   - `uiKitViewConformances` (UIViewController/UIView/UIResponder/cell/AppKit
    ///     equivalents) — only lifecycle overrides / native-symbol / @objc-family /
    ///     native-or-wrapped-property touches stay native (UIKit "Phase 1a").
    /// Every OTHER entry here is a HARD blanket force (every member native, always:
    /// system delegates whose callbacks fire on native objects, NSObject, the
    /// *Representable bridges). Conservative by design.
    static let nativeConformances: Set<String> = [
        // SwiftUI
        "View", "App", "Scene", "ViewModifier", "Commands", "ToolbarContent",
        "Shape", "PreviewProvider", "DynamicProperty", "WidgetBundle", "Widget",
        // UIKit / AppKit view & view-controller base classes — PER-MEMBER
        // (`uiKitViewConformances`, UIKit Phase 1a): only lifecycle overrides /
        // native-symbol / @objc-family / native-or-wrapped-property members native.
        "UIView", "UIViewController", "UIResponder", "UITableViewCell",
        "UICollectionViewCell", "UITableViewHeaderFooterView",
        "NSView", "NSViewController",
        // App / scene / data-source / gesture DELEGATE protocols + the *Representable
        // bridges + NSObject — HARD blanket force (callbacks fire on native objects;
        // a Representable's whole surface bridges into UIKit; NSObject is ObjC root).
        "UIApplicationDelegate", "UIWindowSceneDelegate",
        "UISceneDelegate", "UITableViewDataSource", "UITableViewDelegate",
        "UICollectionViewDataSource", "UICollectionViewDelegate", "UIGestureRecognizerDelegate",
        "NSObject", "NSApplicationDelegate",
        "UIViewRepresentable", "UIViewControllerRepresentable", "NSViewRepresentable",
        // System delegate protocols (callbacks fire on native objects)
        "CLLocationManagerDelegate", "CBCentralManagerDelegate", "CBPeripheralDelegate",
        "AVCaptureMetadataOutputObjectsDelegate", "URLSessionDelegate",
        "UNUserNotificationCenterDelegate", "WCSessionDelegate",
        "NSFetchedResultsControllerDelegate",
        // NB: `ObservableObject` is intentionally NOT here (Day-2). It is reactive
        // plumbing (Combine), not a UI/system base type. Its `@Published` members
        // are caught per-method via `nativePropertyNames`; pure helpers on the
        // same class are now free to classify as wasmEligible/bridged.
    ]

    /// The SUBSET of `nativeConformances` that are SwiftUI view/value-DSL types,
    /// for which forcing is PER-MEMBER (not blanket). Everything ELSE in
    /// `nativeConformances` (UIViewController, system delegates, NSObject, the
    /// *Representable bridges…) keeps the hard blanket force.
    static let viewDSLConformances: Set<String> = [
        "View", "App", "Scene", "ViewModifier", "Commands", "ToolbarContent",
        "Shape", "PreviewProvider", "DynamicProperty", "WidgetBundle", "Widget",
    ]

    /// The SUBSET of `nativeConformances` that are UIKit/AppKit **view or
    /// view-controller** base classes, for which forcing is PER-MEMBER (UIKit
    /// "Phase 1a") rather than blanket. A member of such a type stays native only if
    /// it is a UIKit lifecycle override (`uiKitLifecycleMethodNames`) or is caught by
    /// the unchanged downstream native scans (a UIKit/native symbol, `@objc`-family,
    /// or a native-typed/wrapped-property touch). Pure value/logic methods are freed.
    /// NB: the app/scene/data-source DELEGATE protocols, the *Representable bridges,
    /// and `NSObject` are deliberately NOT here — their callbacks fire on, or their
    /// whole surface bridges into, native objects, so they keep the hard blanket
    /// force in `nativeConformances`.
    static let uiKitViewConformances: Set<String> = [
        "UIView", "UIViewController", "UIResponder", "UITableViewCell",
        "UICollectionViewCell", "UITableViewHeaderFooterView",
        "NSView", "NSViewController",
    ]

    /// UIKit/AppKit lifecycle / view-machinery override method NAMES that stay native
    /// under the per-member UIKit rule (leg (e)). These are imperative `self`/view-
    /// tree mutators (or custom drawing / sizing the OS calls) — never a re-runnable
    /// pure value — so even when their body happens to touch no registry symbol they
    /// are kept native (conservative: a `layoutSubviews` reading only `bounds.width`
    /// math must not be freed). Matched by simple method name on a `.method` decl.
    /// Plain helper methods (not in this set, no native touch) are freed. This is the
    /// only EXTRA keep-native flag the UIKit rule adds beyond the shared scans, so it
    /// can only ever ADD native (lose coverage), never create a false negative.
    static let uiKitLifecycleMethodNames: Set<String> = [
        // UIViewController lifecycle
        "viewDidLoad", "loadView", "viewWillAppear", "viewDidAppear",
        "viewWillDisappear", "viewDidDisappear", "viewWillLayoutSubviews",
        "viewDidLayoutSubviews", "viewWillTransition", "willMove", "didMove",
        "updateViewConstraints", "viewLayoutMarginsDidChange",
        "viewSafeAreaInsetsDidChange", "didReceiveMemoryWarning",
        "setEditing", "encodeRestorableState", "decodeRestorableState",
        // UIView / CALayer drawing, layout & sizing
        "draw", "drawRect", "layoutSubviews", "updateConstraints",
        "sizeThatFits", "sizeToFit", "intrinsicContentSize", "layoutMarginsDidChange",
        "safeAreaInsetsDidChange", "tintColorDidChange", "didMoveToSuperview",
        "didMoveToWindow", "willMoveToSuperview", "willMoveToWindow",
        "traitCollectionDidChange", "hitTest", "point",
        // UITableViewCell / UICollectionViewCell reuse machinery
        "prepareForReuse", "awakeFromNib", "setSelected", "setHighlighted",
        "applyLayoutAttributes", "preferredLayoutAttributesFitting",
        // UIResponder event handling
        "touchesBegan", "touchesMoved", "touchesEnded", "touchesCancelled",
        "pressesBegan", "pressesEnded", "motionBegan", "motionEnded",
        "becomeFirstResponder", "resignFirstResponder",
    ]

    /// INHERITED UIKit/AppKit VC/View/cell/responder member names that expose or
    /// mutate native state but are almost never declared in the subclass body (so the
    /// `nativePropertyNames` scan can't see them and they aren't registry symbols).
    /// A method in a UIKit view/VC type that references any of these — or `super` —
    /// is forced native (leg (a)/(b) of the per-member rule, extended to the inherited
    /// surface). Curated to high-frequency members that return native objects, mutate
    /// the view tree, or drive navigation/presentation; deliberately EXCLUDES names
    /// that collide with common pure-helper names (e.g. `frame`, `bounds`, `text`,
    /// `value`, `count`, `title`) to avoid over-forcing — those, when they DO denote a
    /// native member, are reached through a native-typed receiver the registry / typed
    /// scans already catch. Matched against a body reference's `name`.
    static let uiKitInheritedMemberNames: Set<String> = [
        // The root view + view-hierarchy mutators (UIViewController / UIView)
        "view", "addSubview", "insertSubview", "bringSubviewToFront",
        "sendSubviewToBack", "removeFromSuperview", "addArrangedSubview",
        "insertArrangedSubview", "removeArrangedSubview", "superview", "subviews",
        "addConstraint", "addConstraints", "removeConstraint", "removeConstraints",
        "addLayoutGuide", "addGestureRecognizer", "removeGestureRecognizer",
        "setNeedsLayout", "setNeedsDisplay", "layoutIfNeeded", "setNeedsUpdateConstraints",
        "setNeedsFocusUpdate", "invalidateIntrinsicContentSize",
        // Anchors / layout guides (constraint construction returns native objects)
        "safeAreaLayoutGuide", "layoutMarginsGuide", "readableContentGuide",
        "keyboardLayoutGuide", "topAnchor", "bottomAnchor", "leadingAnchor",
        "trailingAnchor", "leftAnchor", "rightAnchor", "widthAnchor", "heightAnchor",
        "centerXAnchor", "centerYAnchor", "firstBaselineAnchor", "lastBaselineAnchor",
        "safeAreaInsets", "layoutMargins", "directionalLayoutMargins",
        // Navigation / presentation / containment (UIViewController)
        "navigationController", "tabBarController", "splitViewController",
        "navigationItem", "tabBarItem", "presentingViewController",
        "presentedViewController", "parent", "children", "presentationController",
        "present", "dismiss", "show", "showDetailViewController", "performSegue",
        "addChild", "removeFromParent", "setViewControllers", "pushViewController",
        "popViewController", "popToRootViewController", "setToolbarItems",
        "setNeedsStatusBarAppearanceUpdate", "setNeedsUpdateOfHomeIndicatorAutoHidden",
        // Window / screen / responder chain (mostly inherited, native)
        "window", "windowScene", "nextResponder", "becomeFirstResponder",
        "resignFirstResponder", "inputAccessoryView", "inputView",
        // Cell / table / collection inherited surface
        "contentView", "backgroundView", "selectedBackgroundView", "accessoryView",
        "dequeueReusableCell", "dequeueReusableSupplementaryView",
        "dequeueReusableHeaderFooterView", "register", "reloadData", "reloadRows",
        "reloadSections", "insertRows", "deleteRows", "insertSections",
        "deleteSections", "performBatchUpdates", "indexPathForSelectedRow",
        "selectRow", "deselectRow", "scrollToRow", "scrollToItem",
    ]

    /// Property-wrapper attributes whose presence on a type's stored properties
    /// marks the whole type native (SwiftUI state plumbing, Core Data, etc.).
    static let nativePropertyWrappers: Set<String> = [
        "State", "Binding", "StateObject", "ObservedObject", "EnvironmentObject",
        "Environment", "FetchRequest", "SectionedFetchRequest", "AppStorage",
        "SceneStorage", "FocusState", "GestureState", "Namespace", "ScaledMetric",
        "Bindable", "Published", "Query", "NSManaged", "IBOutlet", "IBInspectable",
    ]
}

/// Detects whether a member body WRITES (mutates) any of a set of reactive
/// property names — used by the host-projection gate to keep a member native if
/// it mutates reactive state (a mutation can't be projected into a by-value WASM
/// fragment; the original reactive state wouldn't update). Flags a write on:
///   * an assignment / compound-assignment whose LHS is `name` or `self.name`
///     (incl. `name.member = …` / `name[i] = …` member/subscript assignment),
///   * an `&name` inout argument,
///   * a call to a known STDLIB MUTATING method whose receiver is the reactive
///     prop (`flag.toggle()`, `arr.append(1)`, `s.removeLast()`, `xs.sort()`, …).
/// The host-projection gate only ever projects scalar / String / Bool / scalar-
/// array props, whose mutating-method surface is the FINITE, KNOWN stdlib set
/// below — so this denylist is complete for the projectable universe (no custom
/// value types are projectable). Conservative throughout: an LHS/receiver shape
/// it cannot resolve to a reactive prop is ignored (the surrounding gates still
/// apply); it never frees a member, only ever keeps one native.
/// Collects names bound LOCALLY inside a member node: function parameters, `let`/
/// `var` binding identifiers, closure parameters, and `case let`/`for`-pattern
/// bindings. Used by the host-projection scan to drop a reactive-prop name that is
/// SHADOWED by a local (the body's reference is the local, not `self.<prop>`).
private final class LocalBindingCollector: SyntaxVisitor {
    private(set) var names: Set<String> = []

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert((node.secondName ?? node.firstName).text); return .visitChildren
    }
    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert((node.secondName ?? node.firstName).text); return .visitChildren
    }
    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text); return .visitChildren
    }
    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.text); return .visitChildren
    }
}

private final class ReactiveWriteScanner: SyntaxVisitor {
    let reactiveNames: Set<String>
    private(set) var writes = false

    init(reactiveNames: Set<String>) {
        self.reactiveNames = reactiveNames
        super.init(viewMode: .sourceAccurate)
    }

    /// Known mutating methods on the projectable stdlib value types (Bool /
    /// numeric / String / Array<Scalar> / Set<Scalar>). A call to one of these on
    /// a reactive prop receiver mutates it → keep the member native.
    static let mutatingMethods: Set<String> = [
        // Bool
        "toggle",
        // Numeric in-place
        "negate", "round", "formRemainder", "formTruncatingRemainder",
        "formSquareRoot", "addProduct",
        // String / Array / Set / RangeReplaceableCollection / MutableCollection
        "append", "insert", "remove", "removeAll", "removeFirst", "removeLast",
        "removeSubrange", "removeRandomElement", "popLast", "popFirst",
        "replaceSubrange", "reserveCapacity", "sort", "reverse", "shuffle",
        "swapAt", "partition", "update", "subtract", "formUnion", "formIntersection",
        "formSymmetricDifference", "write",
    ]

    /// The reactive name an expression denotes as a mutation target — a bare
    /// `name`, a `self.name`, or a `name.member` / `name[i]` rooted at a reactive
    /// prop. nil otherwise.
    private func reactiveTarget(_ expr: ExprSyntax) -> String? {
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let n = ref.baseName.text
            return reactiveNames.contains(n) ? n : nil
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            let n = member.declName.baseName.text
            let base = member.base?.trimmedDescription
            // `self.name` (or `.name`) targeting a reactive prop.
            if (base == nil || base == "self"), reactiveNames.contains(n) { return n }
            // `name.member` (member-assignment LHS) rooted at a reactive prop.
            if let b = member.base, let root = reactiveTarget(b) { return root }
            return nil
        }
        // `name[i]` subscript-assignment LHS.
        if let sub = expr.as(SubscriptCallExprSyntax.self), let root = reactiveTarget(sub.calledExpression) {
            return root
        }
        // `name?` / `name!` optional-chained LHS.
        if let opt = expr.as(OptionalChainingExprSyntax.self) { return reactiveTarget(opt.expression) }
        if let force = expr.as(ForceUnwrapExprSyntax.self) { return reactiveTarget(force.expression) }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression { return reactiveTarget(inner) }
        return nil
    }

    // `a = b` / `a += b` parse as a SequenceExpr: [LHS, <assign-op>, RHS]. When the
    // operator is `=` (AssignmentExprSyntax) or a compound assignment
    // (BinaryOperatorExpr whose text ends in `=`, e.g. `+=`), the element before it
    // is the assignment target.
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (i, el) in elements.enumerated() where i > 0 {
            let isAssign = el.is(AssignmentExprSyntax.self)
                || (el.as(BinaryOperatorExprSyntax.self).map { op in
                        let t = op.operator.text
                        return t.hasSuffix("=") && !["==", "!=", "<=", ">="].contains(t)
                    } ?? false)
            if isAssign, reactiveTarget(elements[i - 1]) != nil { writes = true }
        }
        return .visitChildren
    }

    // `name = b` can also appear as a standalone InfixOperatorExpr in some trees.
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if node.operator.is(AssignmentExprSyntax.self), reactiveTarget(node.leftOperand) != nil {
            writes = true
        }
        return .visitChildren
    }

    // `foo(&name)` hands a reactive prop out by reference — a potential write.
    override func visit(_ node: InOutExprSyntax) -> SyntaxVisitorContinueKind {
        if reactiveTarget(node.expression) != nil { writes = true }
        return .visitChildren
    }

    // `name.mutatingMethod(...)` — a known stdlib mutation on a reactive prop.
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           let base = member.base,
           reactiveTarget(base) != nil,
           Self.mutatingMethods.contains(member.declName.baseName.text) {
            writes = true
        }
        return .visitChildren
    }
}

/// Detects a `self.<x> = …` (or `self.<x> <compound>= …`) write to a NON-reactive
/// instance property — the PARTIAL host-projection discriminator (subset (b)). A
/// write to a NAME in `reactiveNames` does NOT count (it is a reactive write, the
/// `bodyWritesReactiveProperty` boundary, which keeps the member native). Only a
/// `self.`-qualified LHS counts, so a bare-local assignment is never mistaken for
/// a member write — conservative (can only cost coverage, never soundness).
private final class SelfPropertyWriteScanner: SyntaxVisitor {
    let reactiveNames: Set<String>
    private(set) var writesNonReactive = false

    init(reactiveNames: Set<String>) {
        self.reactiveNames = reactiveNames
        super.init(viewMode: .sourceAccurate)
    }

    /// The non-reactive instance-property name an LHS denotes as a `self.<x>` write
    /// target (`self.cache`, `self.cache.field`, `self.cache[i]`); nil for a bare
    /// local, a reactive prop, or anything we can't resolve to a `self.`-rooted
    /// property.
    private func selfPropertyTarget(_ expr: ExprSyntax) -> String? {
        if let member = expr.as(MemberAccessExprSyntax.self) {
            let n = member.declName.baseName.text
            if let base = member.base?.as(DeclReferenceExprSyntax.self), base.baseName.text == "self" {
                return reactiveNames.contains(n) ? nil : n   // self.<x>: count iff non-reactive
            }
            // `self.cache.field` / chained — root it at the `self.<x>` prefix.
            if let b = member.base { return selfPropertyTarget(b) }
            return nil
        }
        if let sub = expr.as(SubscriptCallExprSyntax.self) { return selfPropertyTarget(sub.calledExpression) }
        if let opt = expr.as(OptionalChainingExprSyntax.self) { return selfPropertyTarget(opt.expression) }
        if let force = expr.as(ForceUnwrapExprSyntax.self) { return selfPropertyTarget(force.expression) }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression { return selfPropertyTarget(inner) }
        return nil
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (i, el) in elements.enumerated() where i > 0 {
            let isAssign = el.is(AssignmentExprSyntax.self)
                || (el.as(BinaryOperatorExprSyntax.self).map { op in
                        let t = op.operator.text
                        return t.hasSuffix("=") && !["==", "!=", "<=", ">="].contains(t)
                    } ?? false)
            if isAssign, selfPropertyTarget(elements[i - 1]) != nil { writesNonReactive = true }
        }
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if node.operator.is(AssignmentExprSyntax.self), selfPropertyTarget(node.leftOperand) != nil {
            writesNonReactive = true
        }
        return .visitChildren
    }
}
