// SPDX-License-Identifier: Apache-2.0

// UIKitEmitter.swift — lowers a recognized UIKit cell construction METHOD BODY
// to guest `UI.`-builder Swift source that builds a `UIKitNode` tree.
// =============================================================================
// This is the code-generation half of the UIKit cell lowering — the analogue of
// `SwiftUIEmitter`. The SwiftUI emitter turns an expression tree of view VALUES
// into `N.` builder calls; this one turns the IMPERATIVE statement list of a cell
// construction into `UI.` builder calls.
//
// The model is a small intra-method ABSTRACT MACHINE:
//   * `views`  — symbol table: local name (`title`) → a `ViewBuild` (its node kind
//                + accumulated `UIKitViewProps` + constraints + child order).
//   * statements mutate that table: a property set folds into the build's props/
//     leaf payload; an `addSubview`/`addArrangedSubview` records a parent→child
//     edge; an `NSLayoutConstraint.activate([...])` (or `.isActive = true`)
//     resolves each constraint onto the owning view's build.
//   * the CONTENT ROOT is the single view added to `contentView` — the tree we
//     emit, walking the parent→child graph from it.
//
// EVERY statement must be recognized. The first unrecognized one sets `bailed` and
// `emit()` returns nil → the cell stays 100% native (the cardinal demote rule). A
// recognized subview whose constructor we can't lower (a custom `UIView` subclass)
// is NOT a bail: it becomes a `UI.customSlot` leaf (native, slotable from the
// thunk), exactly like the SwiftUI mixed-view `.opaque`.

import SwiftSyntax
import ViewNodeIR

extension UIKitCellLowering {

    /// Lower one recognized cell. Returns nil if the construction isn't the
    /// recognized declarative grammar (whole-method demote). `namespaceConstants` are the
    /// file-level caseless-namespace static-let literals in scope (Lever B), collected
    /// once per source in `lowerAllCells`.
    func lower(cell: FoundCell, structCatalog: [String: [BodyLowering.StructField]],
               namespaceConstants: [String: UIKitEmitter.ConstantValue] = [:],
               extensions: [ExtensionDeclSyntax] = []) -> LoweredCell? {
        guard let body = cell.method.body else { return nil }
        var emitter = UIKitEmitter()
        emitter.containerKind = cell.containerKind
        emitter.inputs = Self.modelInputs(of: cell, structCatalog: structCatalog)
        emitter.inaccessibleNames = Self.inaccessibleMemberNames(of: cell.decl, extensions: extensions)
        emitter.reachableMemberNames = Self.reachableMemberNames(of: cell.decl)
        emitter.selectorArities = Self.instanceMethodArities(of: cell.decl, extensions: extensions)
        emitter.selfMethodNames = Self.instanceMethodNames(of: cell.decl, extensions: extensions)
        // No-arg same-class helpers (`setupViews()`/`addSubviews()`) whose bodies are
        // themselves the recognized grammar, so a cell that splits its build across
        // `configure()` + a helper still lowers (the helper body is inlined).
        emitter.inlineHelpers = Self.noArgHelpers(of: cell.decl, excluding: cell.method.selector)
        // Design-system static-let constants in scope (file-level + the cell's own nested
        // namespaces): `UX.spacing`, `Config.width` resolve to their literal at build time.
        emitter.namespaceConstants = namespaceConstants.merging(
            Self.namespaceConstants(in: cell.decl)) { _, nested in nested }
        // Seed the symbol table with the cell's STORED view properties (the common cell
        // shape declares `let titleLabel = UILabel()` at class scope and configures it
        // in `configure(with:)`). A stored prop initialized with a known widget
        // constructor (or a lazy/typed-only one) pre-registers as that widget; a
        // stored prop of a CUSTOM view type pre-registers as a slotted custom leaf.
        emitter.seedStoredViews(Self.storedViewProperties(of: cell.decl))
        guard let rootExpr = emitter.emit(methodBody: body.statements) else { return nil }

        let inputs = emitter.inputs
        // A construction that READS a non-reconstructable input (a nested struct/enum/
        // dictionary model field) is EXCLUDED — like the SwiftUI BuildPipeline gate.
        let referencesUnmarshalled = emitter.referencedInputs.contains { name in
            inputs.contains { $0.name == name && !$0.kind.guestReconstructable }
        }
        // thunkSafe iff every custom slot is slotable (the thunk can render it from a
        // self-only closure) AND it reads no unmarshalled input. A 100%-lowered body
        // has no slots, so this subsumes it.
        let thunkSafe = emitter.customSlots.allSatisfy { $0.slotable } && !referencesUnmarshalled

        return LoweredCell(
            typeName: cell.name,
            methodName: cell.method.selector,
            replacedSelector: cell.method.selector,
            methodParameterClause: Self.parameterClauseSource(of: cell.method),
            modelParamName: Self.modelParameter(of: cell.method)?.name,
            guestBody: rootExpr,
            inputs: inputs,
            customSlots: emitter.customSlots,
            actionIDs: emitter.actionIDs,
            actionWirings: emitter.actionWirings.map {
                .init(id: $0.id, selector: $0.selector)
            },
            gestureWirings: emitter.gestureWirings.map {
                .init(viewNodeID: $0.viewNodeID, source: $0.source)
            },
            observerEffects: emitter.observerEffects.map {
                .init(id: $0.id, source: $0.source)
            },
            nativeEffects: emitter.nativeEffects
                .sorted { $0.ordinal < $1.ordinal }
                .map { .init(source: $0.source, ordinal: $0.ordinal) },
            hostTokens: emitter.hostTokens,
            thunkSafe: thunkSafe,
            referencesUnmarshalledInput: referencesUnmarshalled,
            containerKind: cell.containerKind)
    }

    // MARK: - Model-input extraction

    /// The inputs the construction marshals: the `configure(with model:)` parameter's
    /// FLAT fields (each `model.<field>` reads one), flattened to top-level keys
    /// (`name`, `subtitle`) — OR, when the method takes no model param, the cell's own
    /// stored properties. Reuses the SwiftUI flat-struct catalog + `ViewInput`.
    static func modelInputs(of cell: FoundCell,
                            structCatalog: [String: [BodyLowering.StructField]]) -> [BodyLowering.ViewInput] {
        // (A) A model parameter (`with model: Model` / `_ model: Model`): expand its
        // flat fields to top-level inputs, recording the param name so the emitter can
        // strip the `model.` prefix when reading `model.title`.
        if let (paramName, typeName) = Self.modelParameter(of: cell.method) {
            // The shared SwiftUI struct catalog now resolves RECURSIVE field shapes
            // (nested structs / arrays / dicts). UIKit cell marshalling stays SCALAR-only
            // (its established contract — a cell reads `model.<scalarField>`), so a model
            // struct that has ANY non-scalar field is treated exactly as before: not a
            // flat struct → one `.unsupported` input that demotes any read (never a wrong
            // string default for a nested field).
            if let fields = structCatalog[typeName],
               fields.allSatisfy({ if case .scalar = $0.shape { return true } else { return false } }) {
                return fields.map {
                    BodyLowering.ViewInput(name: "\(paramName).\($0.name)", kind: $0.kind,
                                           defaultLiteral: Self.zeroLiteral($0.kind))
                }
            }
            // A model whose type isn't a known flat struct → one unsupported input so
            // any read of it demotes the cell (never a wrong default).
            return [BodyLowering.ViewInput(name: paramName, kind: .unsupported, defaultLiteral: "\"\"")]
        }
        // (B) No model param: the cell's own stored properties are the inputs.
        return Self.storedPropertyInputs(of: cell.decl)
    }

    /// The construction method's parameter-clause SOURCE (`(with model: CellModel)`,
    /// `()`), used to re-declare a signature-matching `@_dynamicReplacement`.
    static func parameterClauseSource(of method: FunctionOrInit) -> String {
        switch method {
        case .function(let f): return f.signature.parameterClause.trimmedDescription
        case .initializer(let i): return i.signature.parameterClause.trimmedDescription
        }
    }

    /// The construction method's MODEL parameter (name, type) — the first non-trivial
    /// value parameter of a `configure`/`setup`/`init`. We treat the first parameter as
    /// the model (`configure(with model: Model)`, `configure(_ model: Model)`).
    static func modelParameter(of method: FunctionOrInit) -> (name: String, type: String)? {
        let params: FunctionParameterListSyntax
        switch method {
        case .function(let f): params = f.signature.parameterClause.parameters
        case .initializer(let i): params = i.signature.parameterClause.parameters
        }
        guard let first = params.first else { return nil }
        // The internal name (`model` in `with model: Model`) is what the body reads.
        let internalName = first.secondName?.text ?? first.firstName.text
        guard internalName != "_" else { return nil }
        let type = first.type.trimmedDescription
        // Skip UIKit-shell init params (`style:`, `reuseIdentifier:`, `frame:`,
        // `coder:`) — those aren't the model.
        let shellParams: Set<String> = ["style", "reuseIdentifier", "frame", "coder"]
        if shellParams.contains(first.firstName.text) { return nil }
        return (internalName, type)
    }

    /// The cell's stored-property inputs (when there's no model param) — reuses the
    /// SwiftUI `viewInputs` logic via a thin re-implementation over the class members.
    static func storedPropertyInputs(of c: ClassDeclSyntax) -> [BodyLowering.ViewInput] {
        var out: [BodyLowering.ViewInput] = []
        for member in c.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            // Skip the view outlets themselves (UILabel/UIButton/… stored props) +
            // computed properties — only data-ish stored props are inputs.
            for binding in v.bindings {
                guard binding.accessorBlock == nil else { continue }
                let name = binding.pattern.trimmedDescription
                let typeText = binding.typeAnnotation?.type.trimmedDescription
                // A view-typed stored prop isn't a marshalled input.
                if let t = typeText, t.hasPrefix("UI") { continue }
                let defaultExpr = binding.initializer?.value.trimmedDescription
                let kind = Self.uikitInputKind(typeAnnotation: typeText, defaultExpr: defaultExpr)
                guard kind != .unsupported || typeText != nil else { continue }
                out.append(BodyLowering.ViewInput(name: name, kind: kind,
                                                  defaultLiteral: Self.zeroLiteral(kind, declared: defaultExpr)))
            }
        }
        return out
    }

    /// A stored-property's marshalled `ViewInput.Kind` (scalar / array-of-scalar /
    /// unsupported) inferred from the declared type or its default literal. The UIKit
    /// analogue of the SwiftUI `inputKind` — kept here so we don't touch the SwiftUI
    /// lowering, but identical in spirit (scalars + arrays-of-scalar reconstruct).
    static func uikitInputKind(typeAnnotation: String?, defaultExpr: String?) -> BodyLowering.ViewInput.Kind {
        if let t = typeAnnotation {
            switch t {
            case "String": return .string
            case "Bool": return .bool
            case "Int": return .int
            case "Double", "CGFloat": return .double
            case "[String]", "Array<String>": return .stringArray
            case "[Bool]", "Array<Bool>": return .boolArray
            case "[Int]", "Array<Int>": return .intArray
            case "[Double]", "Array<Double>", "[CGFloat]", "Array<CGFloat>": return .doubleArray
            default: return .unsupported
            }
        }
        if let d = defaultExpr {
            if d == "true" || d == "false" { return .bool }
            if d.hasPrefix("\"") { return .string }
            if d.contains("."), Double(d) != nil { return .double }
            if Int(d) != nil { return .int }
        }
        return .unsupported
    }

    static func zeroLiteral(_ k: BodyLowering.ViewInput.Kind, declared: String? = nil) -> String {
        if let declared { return declared }
        switch k {
        case .string: return "\"\""
        case .bool: return "false"
        case .int: return "0"
        case .double: return "0"
        case .stringArray, .boolArray, .intArray, .doubleArray, .structArray, .flatStruct, .enumValue: return "[]"
        case .unsupported: return "\"\""
        }
    }

    /// A cell's STORED view properties: name → its creation expression. Captures the
    /// `let titleLabel = UILabel()` / `let chart = SparklineView()` / lazy-var /
    /// type-only (`let v: UILabel`) declarations at class scope. The emitter seeds the
    /// symbol table with these so a `configure(with:)` that configures a class-scope
    /// view (the common cell shape) lowers. Each value is the initializer expression
    /// (or, for a type-only decl, a synthetic `Type()`), used to classify the widget.
    static func storedViewProperties(of c: ClassDeclSyntax) -> [(name: String, initExpr: ExprSyntax?, typeName: String?)] {
        var out: [(String, ExprSyntax?, String?)] = []
        for member in c.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in v.bindings {
                // A computed property (getter) isn't a stored view.
                if let acc = binding.accessorBlock {
                    // A `lazy var x: UILabel = { … }()` has no accessor block; a
                    // get-only computed `var x: some` does — skip the latter.
                    _ = acc; continue
                }
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                let typeName = binding.typeAnnotation?.type.trimmedDescription
                let initExpr = binding.initializer?.value
                // Only consider properties that are plausibly views: a UI… type
                // annotation, OR an initializer that is a constructor call. (A data
                // stored prop like `var count = 0` is NOT a view — skip; it's an input.)
                let looksView = (typeName?.hasPrefix("UI") ?? false)
                    || (initExpr?.as(FunctionCallExprSyntax.self) != nil)
                    || (typeName.map { !($0.hasPrefix("[") || ["String","Int","Bool","Double","CGFloat"].contains($0)) } ?? false)
                guard looksView else { continue }
                out.append((name, initExpr, typeName))
            }
        }
        return out
    }

    /// The cell's NO-ARG instance methods (name → body statements), excluding the
    /// construction method itself — candidates for inline-lowering when the
    /// construction calls them (`setupViews()`). Only no-arg funcs are collected; an
    /// arg-taking helper references params not in scope, so its call-site demotes.
    static func noArgHelpers(of c: ClassDeclSyntax, excluding selector: String) -> [String: CodeBlockItemListSyntax] {
        var out: [String: CodeBlockItemListSyntax] = [:]
        for member in c.memberBlock.members {
            guard let f = member.decl.as(FunctionDeclSyntax.self),
                  f.signature.parameterClause.parameters.isEmpty,
                  let body = f.body else { continue }
            // Don't collect the construction method as its own helper.
            if f.name.text == selector || "\(f.name.text)()" == selector { continue }
            out[f.name.text] = body.statements
        }
        return out
    }

    /// The cell's `private`/`fileprivate` member names (+ their addressable forms) —
    /// a slot closure in the cross-file thunk can't reference these. (Mirrors the
    /// SwiftUI `inaccessibleMemberNames`.) `extensions` are the cell's SAME-FILE
    /// extensions (R2-#29): a `private extension FooCell { var themeColor … }` member is
    /// equally unreachable from the cross-file thunk — union it in so a color/number token
    /// (or slot) over it correctly demotes instead of compile-failing the thunk.
    static func inaccessibleMemberNames(of c: ClassDeclSyntax,
                                        extensions: [ExtensionDeclSyntax] = []) -> Set<String> {
        var out = Set<String>()
        func isInaccessible(_ mods: DeclModifierListSyntax) -> Bool {
            mods.contains { $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate) }
        }
        // A `private extension FooCell { … }` makes EVERY member private (the extension-level
        // modifier applies to each member), so within such an extension a member with no own
        // access modifier is still inaccessible.
        func collect(_ members: MemberBlockItemListSyntax, extPrivate: Bool) {
            for member in members {
                if let v = member.decl.as(VariableDeclSyntax.self), extPrivate || isInaccessible(v.modifiers) {
                    for b in v.bindings {
                        let name = b.pattern.trimmedDescription
                        guard !name.isEmpty else { continue }
                        out.insert(name)
                    }
                } else if let f = member.decl.as(FunctionDeclSyntax.self), extPrivate || isInaccessible(f.modifiers) {
                    out.insert(f.name.text)
                }
            }
        }
        collect(c.memberBlock.members, extPrivate: false)
        for ext in extensions {
            let extPrivate = ext.modifiers.contains {
                $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)
            }
            collect(ext.memberBlock.members, extPrivate: extPrivate)
        }
        return out
    }

    /// Every same-file extension of a cell type, keyed by the EXTENDED type name (R2-#29).
    /// A `extension FooCell { … }` / `private extension FooCell { … }` contributes members
    /// (and private members) the engine must see when deciding token/slot/quarantine
    /// reachability — `lower`/`diagnose` pass the matching list to `inaccessibleMemberNames`
    /// + the selector-arity / self-method collectors.
    static func extensionsByType(in tree: SourceFileSyntax) -> [String: [ExtensionDeclSyntax]] {
        var out: [String: [ExtensionDeclSyntax]] = [:]
        func walk(_ members: MemberBlockItemListSyntax) {
            for m in members {
                if let ext = m.decl.as(ExtensionDeclSyntax.self) {
                    out[ext.extendedType.trimmedDescription, default: []].append(ext)
                }
            }
        }
        for stmt in tree.statements {
            if let ext = stmt.item.as(ExtensionDeclSyntax.self) {
                out[ext.extendedType.trimmedDescription, default: []].append(ext)
            }
            // Nested (an extension inside another type) — uncommon for a cell, but cheap.
            if let c = stmt.item.as(ClassDeclSyntax.self) { walk(c.memberBlock.members) }
            if let e = stmt.item.as(EnumDeclSyntax.self) { walk(e.memberBlock.members) }
            if let s = stmt.item.as(StructDeclSyntax.self) { walk(s.memberBlock.members) }
        }
        return out
    }

    /// Map each `@objc`-callable instance method (name → its parameter COUNT) declared on the
    /// cell decl AND its same-file extensions (R2-#2/#31). The action-wiring arity gate uses
    /// this to confirm a `#selector(handler)` target takes ZERO args before lowering the
    /// control's action (the thunk replays `self.<handler>()` with no args). A method that
    /// appears in several overloads keeps the SMALLEST arity (the no-arg form, if present).
    static func instanceMethodArities(of c: ClassDeclSyntax,
                                      extensions: [ExtensionDeclSyntax] = []) -> [String: Int] {
        var out: [String: Int] = [:]
        func collect(_ members: MemberBlockItemListSyntax) {
            for member in members {
                guard let f = member.decl.as(FunctionDeclSyntax.self),
                      !f.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) })
                else { continue }
                let arity = f.signature.parameterClause.parameters.count
                if let existing = out[f.name.text] { out[f.name.text] = min(existing, arity) }
                else { out[f.name.text] = arity }
            }
        }
        collect(c.memberBlock.members)
        for ext in extensions { collect(ext.memberBlock.members) }
        return out
    }

    /// The names of every instance method declared on the cell decl + its same-file
    /// extensions (R2-#8) — used to refuse quarantining a `self.<method>(...)` call (an
    /// arbitrary same-class helper may build view structure the patched root then occludes).
    static func instanceMethodNames(of c: ClassDeclSyntax,
                                    extensions: [ExtensionDeclSyntax] = []) -> Set<String> {
        var out = Set<String>()
        func collect(_ members: MemberBlockItemListSyntax) {
            for member in members {
                if let f = member.decl.as(FunctionDeclSyntax.self),
                   !f.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }) {
                    out.insert(f.name.text)
                }
            }
        }
        collect(c.memberBlock.members)
        for ext in extensions { collect(ext.memberBlock.members) }
        return out
    }

    /// The cell's ACCESSIBLE (non-`private`/`fileprivate`) instance member names — every
    /// stored property + method the cross-file thunk extension CAN reference. Used by the
    /// quarantine receiver gate (Goal 1): a native-effect receiver must be a name the engine
    /// can VOUCH for as thunk-reachable — `self`, a known stored member here, or a curated
    /// inherited/global name — else demote (an unknown free identifier would not compile in
    /// the thunk). The inverse companion of `inaccessibleMemberNames` (which lists the ones
    /// that are walled off); a member is reachable iff accessible AND declared on the cell.
    static func reachableMemberNames(of c: ClassDeclSyntax) -> Set<String> {
        var out = Set<String>()
        func isInaccessible(_ mods: DeclModifierListSyntax) -> Bool {
            mods.contains { $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate) }
        }
        for member in c.memberBlock.members {
            if let v = member.decl.as(VariableDeclSyntax.self), !isInaccessible(v.modifiers) {
                for b in v.bindings {
                    if let name = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                        out.insert(name)
                    }
                }
            } else if let f = member.decl.as(FunctionDeclSyntax.self), !isInaccessible(f.modifiers) {
                out.insert(f.name.text)
            }
        }
        return out
    }

    // MARK: - Namespace static-constant collection (Lever B)

    /// Collect FILE-LEVEL caseless-namespace static-let/var SIMPLE-LITERAL constants — the
    /// design-system tables real UIKit apps use for spacing/sizes/durations
    /// (`enum UX { static let spacing: CGFloat = 8 }`, used as `UX.spacing`). Walks every
    /// top-level `enum`/`struct`/extension, recording each simple-literal static under the
    /// dotted access path (`UX.spacing`) AND a nested form (`Outer.UX.spacing`) so the
    /// emitter resolves either reference. Demote-safe: ONLY a string-no-interpolation /
    /// numeric / bool literal is recorded — a computed/derived static stays absent → a
    /// reference to it still demotes (never a wrong value). Mirrors the SwiftUI/real-source
    /// namespace-enum reconstruction in spirit (here: resolve to the literal at build time).
    static func namespaceConstants(in tree: SourceFileSyntax) -> [String: UIKitEmitter.ConstantValue] {
        var out: [String: UIKitEmitter.ConstantValue] = [:]
        for stmt in tree.statements {
            collectNamespaceConstants(stmt.item, prefix: "", into: &out)
        }
        return out
    }

    /// Collect the constants declared INSIDE a cell/VC class (its own nested `enum UX {}`
    /// tables), merged on top of the file-level ones (a closer scope wins).
    static func namespaceConstants(in c: ClassDeclSyntax) -> [String: UIKitEmitter.ConstantValue] {
        var out: [String: UIKitEmitter.ConstantValue] = [:]
        for member in c.memberBlock.members {
            collectNamespaceConstants(member.decl, prefix: "", into: &out)
        }
        return out
    }

    private static func collectNamespaceConstants(_ decl: some SyntaxProtocol, prefix: String,
                                                  into out: inout [String: UIKitEmitter.ConstantValue]) {
        // A namespace container: enum / struct / caseless-enum / extension. Recurse with a
        // path prefix so `enum Layout { enum UX { static let p = 8 } }` records `UX.p`,
        // `Layout.UX.p`, and bare `p`.
        let (typeName, members): (String?, MemberBlockItemListSyntax?)
        if let e = decl.as(EnumDeclSyntax.self) { typeName = e.name.text; members = e.memberBlock.members }
        else if let s = decl.as(StructDeclSyntax.self) { typeName = s.name.text; members = s.memberBlock.members }
        else { typeName = nil; members = nil }
        guard let typeName, let members else { return }
        let path = prefix.isEmpty ? typeName : "\(prefix).\(typeName)"
        for member in members {
            if let v = member.decl.as(VariableDeclSyntax.self),
               v.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) {
                for b in v.bindings {
                    guard let name = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                          let value = b.initializer?.value,
                          let lit = simpleConstantLiteral(value) else { continue }
                    // Record under the FULL path (`Layout.UX.spacing`), the immediate
                    // path (`UX.spacing`), and the bare tail (`spacing`). A bare-tail
                    // collision across two namespaces keeps the LAST seen — the dotted
                    // forms (the way real code references them) stay unambiguous.
                    out["\(path).\(name)"] = lit
                    if let dot = path.lastIndex(of: ".") {
                        out["\(path[path.index(after: dot)...]).\(name)"] = lit
                    }
                    out[name] = lit
                }
            }
            collectNamespaceConstants(member.decl, prefix: path, into: &out)
        }
    }

    /// A SIMPLE literal constant value (number / bool / string-no-interpolation), or nil
    /// for anything derived (a fn call, a member ref, an interpolated string, arithmetic).
    /// A leading `-` numeric and a `CGFloat(8)`/`Double(8)` wrapper are simple.
    static func simpleConstantLiteral(_ expr: ExprSyntax) -> UIKitEmitter.ConstantValue? {
        if let b = UIKitEmitter.boolLiteral(expr) { return .bool(b) }
        if let d = UIKitEmitter.doubleLiteral(expr) { return .number(d) }
        if let s = UIKitEmitter.plainStringLiteral(expr) { return .string(s) }
        return nil
    }
}

// MARK: - The intra-method abstract machine

/// Lowers one cell construction method body. Self-contained; produces the root
/// `UI.` builder expression or nil (demote).
struct UIKitEmitter {
    /// Cell vs programmatic VC/View — selects the CONTENT-ROOT host view the
    /// construction adds subviews to (`contentView` for a cell, `view`/`self` for a VC)
    /// and tolerates a leading `super.viewDidLoad()` for a `viewDidLoad` construction.
    var containerKind: UIKitCellLowering.ContainerKind = .cell
    /// The marshalled inputs (flattened model fields, or the cell's stored props).
    var inputs: [BodyLowering.ViewInput] = []
    /// Inaccessible (private/fileprivate) cell member names — a leaf referencing one
    /// can't be slotted from the cross-file thunk.
    var inaccessibleNames: Set<String> = []
    /// ACCESSIBLE (non-private) cell instance-member names (stored props + methods) — the
    /// names the cross-file thunk extension can reference. The quarantine receiver gate
    /// (Goal 1) requires a native-effect receiver to be VOUCHED-FOR reachable: `self`, one
    /// of these, or a curated inherited/global name — else demote (an unknown free
    /// identifier would not compile in the thunk). Empty ⇒ no member-based receiver vouched
    /// (only `self`/curated-global effects can quarantine).
    var reachableMemberNames: Set<String> = []
    /// The parameter COUNT of each `@objc`-callable instance method on the cell (name →
    /// arity), used by the action-wiring arity gate (R2-#2/#31): the generated thunk replays
    /// an action handler as `self.<selector>()` with ZERO args, so a `#selector` whose target
    /// method takes a SENDER arg (`@objc func tap(_ sender:)`) would NOT compile. We only
    /// record an action wiring (and lower the control's action) when the handler's arity is
    /// KNOWN-ZERO; an unknown or non-zero arity demotes (drop the wiring → demote the cell).
    var selectorArities: [String: Int] = [:]
    /// The NAME of every `self`-method the cross-file thunk's `extension <Cell>` CANNOT
    /// reach safely — a method that BUILDS view structure (an arbitrary same-class helper).
    /// Used by the quarantine `self.<method>(...)` gate (R2-#8): a `self.<method>(...)` call
    /// that fell through every recognized case is NOT a vetted side-effect; replaying it
    /// natively on every cell reuse would re-build native subviews atop the patched root.
    /// So a member call whose receiver head is `self`/nil and whose method is a same-class
    /// instance method is never quarantined (demote instead). This set lists those methods.
    var selfMethodNames: Set<String> = []

    // Collected during lowering. (All stored state is INTERNAL — not private — so the
    // machine extensions in the sibling UIKitEmitter*.swift files can mutate it
    // directly; `private` would wall it off from same-module extensions.)
    var customSlots: [BodyLowering.OpaqueLeaf] = []
    var actionIDs: [String] = []
    /// CONTROL ACTION WIRINGS (BUG #17/#18 fix): one per recognized `addTarget(self,
    /// action: #selector(handler), …)` — the lowered control's action id PLUS the native
    /// `#selector` handler name. The generated thunk uses these to populate
    /// `PatchCellWiring.actions` (`__actions[id] = { [self] in self.<selector>() }`) so a
    /// patched button/switch/slider/textField's action actually fires on device (without
    /// this the control rendered but the user's tap did nothing — a silent dead control).
    /// DEMOTE-SAFE: only a `self` target + thunk-reachable (non-private) `#selector` is
    /// recorded; anything else demotes the whole method (see `handleAddTarget`).
    var actionWirings: [UIKitEmitter.ActionWiring] = []
    /// GESTURE WIRINGS (Lever 1 — `addGestureRecognizer`): a `someView.addGestureRecognizer(
    /// UITapGestureRecognizer(target: self, action: #selector(handleTap)))` recognized when
    /// `someView` is a KNOWN constructed view, the gesture's `target` is `self`, and its
    /// `action` is a `#selector(...)`. The gesture itself NEVER rides the guest tree — it's a
    /// native effect replayed against `self` + the RENDERED view. The engine records the
    /// VERBATIM gesture construction `source` (`UITapGestureRecognizer(target: self, action:
    /// #selector(self.handleTap))`) keyed to the view's node id (`viewNodeID` = the view's
    /// local name, which the emitted node carries as `.id(name)`). The thunk supplies a
    /// per-view native closure `{ v in v.addGestureRecognizer(<source>) }` (selector resolved
    /// NATIVELY in the thunk — no guest-side selector reconstruction), and the SDK applies it
    /// to the matching rendered view after building the tree. DEMOTE-SAFE: only a `self`
    /// target + `#selector` action on a known view records; anything else bails. No IR change
    /// (the wiring rides the thunk + the view's node id, not the tree).
    var gestureWirings: [UIKitEmitter.GestureWiring] = []
    /// OBSERVER EFFECTS (Lever 2 — `NotificationCenter.default.addObserver`): the canonical
    /// `NotificationCenter.default.addObserver(self, selector: #selector(onKeyboard(_:)),
    /// name: …, object: …)` shape with a `self` target + `#selector` action. NOT view-attached
    /// — a METHOD-LEVEL side effect: the engine records the VERBATIM `addObserver(...)` call so
    /// the thunk supplies a native closure that re-runs it against `self` (selector resolved
    /// natively), and the SDK runs each observer-effect closure ONCE at install. DEMOTE-SAFE:
    /// only the selector-based shape lowers; the block-based `addObserver(forName:object:queue:
    /// using:)` (a closure = guest-unreconstructable logic) DEMOTES. No IR change.
    var observerEffects: [UIKitEmitter.ObserverEffect] = []
    /// DESIGN-SYSTEM COLOR TOKENS (Lever D): a custom color expression the guest can't
    /// reconstruct (`SemanticColors.View.backgroundDefault`, `Asset.Colors.brand.color`)
    /// that is build-time-resolvable from the cross-file thunk (references no body-local
    /// view / `private` member) lowers as `ColorRef.hostToken(id)`. The tree carries only
    /// the id; the thunk's token resolver evaluates the REAL `UIColor` natively and the SDK
    /// fills the renderer's token table. Reuses the SwiftUI `HostToken` type (`.color`
    /// kind). Demote-safe: a token referencing a body-local/`private` member is NOT
    /// recorded → the color stays unresolvable → the whole method demotes (never wrong).
    var hostTokens: [BodyLowering.HostToken] = []
    /// Which declared inputs the construction actually READ (used by the unmarshalled
    /// gate). Names are the flat input names (`model.title`, or a stored-prop name).
    var referencedInputs: Set<String> = []

    /// NATIVE EFFECT SLOTS (Goal 1 — GRANULAR PER-STATEMENT PARTITIONING). The generalized
    /// quarantine path: an unrecognized-but-ISOLATABLE imperative statement (a delegate set
    /// `tableView.delegate = self`, a live-object call `view.bringSubviewToFront(x)` /
    /// `navigationController?.setNavigationBarHidden(true)`, a `self`-method effect) is NOT
    /// contagious — instead of demoting the WHOLE method (the old all-or-nothing-per-method
    /// rule), the surrounding DECLARATIVE construction still lowers and the odd imperative
    /// line is recorded here as a native effect the build-time thunk replays VERBATIM
    /// against `self` (+ the rendered view, for a view-targeted effect), in SOURCE ORDER,
    /// after the tree is built. DEMOTE-SAFE + BUILD-SAFE by construction (see
    /// `UIKitEmitterQuarantine.swift`): a statement is only quarantined when its verbatim
    /// text compiles in the cross-file thunk scope (references no body-local / `private`
    /// member) AND it touches no state the lowered tree also expresses (no double-set
    /// conflict) AND it isn't an order/data-dependency the engine can't track — otherwise
    /// the whole method still demotes. The `ordinal` preserves the inter-effect source
    /// order the SDK replays them in. No IR change (the effects ride the thunk wiring +
    /// node ids, exactly like the gesture/observer levers this generalizes).
    var nativeEffects: [NativeEffect] = []
    /// Monotonic source-order counter assigned to each quarantined native effect so the
    /// SDK replays them in the order they appeared in the construction method.
    var effectOrdinal = 0
    /// The cell's STORED view-property names (seeded from class scope) — the subset of
    /// `localNames` the cross-file thunk CAN reference (a `self.<name>` member is reachable
    /// there; a method-LOCAL view var is not). A view-targeted native effect is only
    /// quarantinable when its receiver is a stored view (reachable) or `self`/global.
    var storedViewNames: Set<String> = []

    /// Set when an unrecognized statement is hit — `emit` returns nil. (Named `…Flag`/
    /// `…Store` so the `bailed`/`bail(_:)` accessors in the extension read cleanly.)
    var bailedFlag = false
    var bailReasonStore = ""

    /// The symbol table: local view name → its build state.
    var views: [String: ViewBuild] = [:]
    /// View creation order (for deterministic id assignment + child ordering).
    var creationOrder: [String] = []
    /// Parent → ordered children (by local name). A child is added via
    /// `addSubview`/`addArrangedSubview`.
    var childrenStore: [String: [String]] = [:]
    /// Whether a child was added as ARRANGED (stack) vs plain subview — disambiguates
    /// how the parent renders (stack arranged vs container subview).
    var arrangedParentsStore: Set<String> = []
    /// The local names added directly to `contentView` (the content root candidates).
    var contentViewChildrenStore: [String] = []
    /// Names bound LOCALLY in the method (the view vars + any other let/var) — a slot
    /// leaf referencing one isn't slotable.
    var localNames: Set<String> = []
    /// Same-class no-arg helpers whose bodies are inline-lowerable (name → statements).
    var inlineHelpers: [String: CodeBlockItemListSyntax] = [:]
    /// Helpers currently being inlined (recursion guard).
    var inliningSet: Set<String> = []
    /// The active guest VISIBILITY condition while walking inside a model-driven `if`
    /// branch (Lever 1). A view ADDED to its parent while this is set is gated with
    /// `.hidden(!cond)` so it only paints when the marshalled condition holds. nil at
    /// top level (the common case — no conditional construction).
    var pendingVisibility: String? = nil
    /// R2-#30/#92 (build-safe = demote-safe): the set of distinct VISIBILITY CONTEXTS under
    /// which any PROPERTY was set on a view (`if isError { label.textColor = .red }` records
    /// `propSetContexts["label"] = {isError-guest}`). A static tree sets a property ONCE
    /// (unconditionally), so a conditional property set is faithful ONLY when its target view
    /// is GATED on the SAME condition (so it's present iff the prop applies). At emit we
    /// require every prop-set context of a view to appear in its GATE contexts; otherwise the
    /// property would apply unconditionally to an unconditionally-present view → demote.
    var propSetContexts: [String: Set<String>] = [:]
    /// The set of visibility CONTEXTS each view is GATED on (recorded when a view is added
    /// under a visibility context via `applyPendingVisibility`). Compared against
    /// `propSetContexts` at emit to catch the conditional-property-on-ungated-view bug.
    var gateContexts: [String: Set<String>] = [:]
    /// Local NAMED constraint bindings (`let c = title.topAnchor.constraint(...)`): the
    /// constraint EXPRESSION captured by name, so a later `NSLayoutConstraint.activate([c])`
    /// / `c.isActive = true` / `c.priority = .defaultHigh; c.isActive = true` resolves the
    /// real anchor form (Lever 3 — the named-constraint pattern). Maps the var name to its
    /// `.constraint(...)` expression + any priority set on it before activation.
    var constraintVars: [String: (expr: ExprSyntax, priority: Double?)] = [:]
    /// ROOT-view property configuration (Lever A): a property set on the CONTENT ROOT
    /// itself — `view.backgroundColor` / `view.layer.cornerRadius` for a VC, bare
    /// `backgroundColor` / `layer.cornerRadius` / `self.backgroundColor` for a `UIView`
    /// subclass building into `self`. These fold here (not onto a local view); at emit
    /// time, when `rootPropsSet` is true, the content children are wrapped in a synthetic
    /// root `.view` node carrying these props (the renderer pins it to fill the host, so
    /// `.superview` constraints stay correct). nil/false when the root is never configured
    /// — the established single-content-child-is-root path is then byte-identical.
    var rootProps = MutableProps()
    var rootPropsSet = false
    /// Caseless-namespace static-let constants (`enum UX { static let pad: CGFloat = 8 }`)
    /// in scope, resolved to their SIMPLE-LITERAL value (Lever B). A reference
    /// `UX.pad` / `Layout.UX.pad` in a numeric/string position resolves to this literal at
    /// build time; a non-literal static (a fn call / member ref / interpolation) is absent
    /// here and stays a demote (faithful). Keyed by the FULL dotted access path (`UX.pad`)
    /// AND the bare tail (`pad`) so either reference form resolves.
    var namespaceConstants: [String: ConstantValue] = [:]

    /// A resolved namespace constant's literal value + kind (number / string / bool).
    enum ConstantValue: Equatable {
        case number(Double)
        case string(String)
        case bool(Bool)
    }

    /// One recognized `addGestureRecognizer` wiring (Lever 1). The gesture rides NOTHING
    /// across the WASM boundary — `source` is the VERBATIM native gesture construction
    /// (`UITapGestureRecognizer(target: self, action: #selector(self.handleTap))`) the
    /// thunk replays against `self`, and `viewNodeID` is the LOCAL view name the gesture
    /// attaches to (the emitted node carries it as `.id(viewNodeID)`), so the SDK applies
    /// the closure to the matching rendered view. Demote-safe by construction: the emitter
    /// only records one whose target is `self` + action is a `#selector` on a known view.
    struct GestureWiring: Equatable {
        /// The local name of the KNOWN view the gesture attaches to (the rendered node's id).
        let viewNodeID: String
        /// The verbatim gesture-recognizer construction source (selector intact), replayed
        /// natively in the thunk: `v.addGestureRecognizer(<source>)`.
        let source: String
    }

    /// One recognized `NotificationCenter.default.addObserver(self, selector:…, name:…,
    /// object:…)` (Lever 2) — a METHOD-LEVEL effect, not view-attached. `source` is the
    /// VERBATIM `NotificationCenter.default.addObserver(...)` call the thunk re-runs against
    /// `self` once at install (selector resolved natively); `id` is a content-stable hash of
    /// the source so engine (push) + thunk (build) agree with no shared state.
    struct ObserverEffect: Equatable {
        let id: String
        /// The verbatim `NotificationCenter.default.addObserver(...)` call source, replayed
        /// natively in the thunk.
        let source: String
    }

    /// One recognized control ACTION WIRING (BUG #17/#18 fix). `id` is the content-stable
    /// action id the lowered control node carries (the `EventID` the renderer's dispatcher
    /// keys on); `selector` is the cell's native `#selector` method base name. The generated
    /// thunk replays it as `__actions[id] = { [self] in self.<selector>() }` so the patched
    /// control's action fires on device. Demote-safe by construction: recorded only for a
    /// `self`-target + thunk-reachable (non-private) selector.
    struct ActionWiring: Equatable {
        /// The lowered control's action id (the renderer dispatcher's `EventID.id`).
        let id: String
        /// The cell's native `#selector` handler base name (`didToggle`), called directly
        /// from the thunk as `self.<selector>()`.
        let selector: String
    }

    /// One QUARANTINED native effect (Goal 1). Replayed VERBATIM against `self` by the
    /// thunk — the original statement text compiles unchanged in the cross-file
    /// `extension <Cell>` scope (a bare `tableView.delegate = self` resolves to
    /// `self.tableView` there; a `navigationItem.x = …` is an inherited member). `ordinal`
    /// is the statement's source position, used by the SDK to replay effects in order.
    /// `source` is the verbatim statement text the thunk emits unchanged — the whole
    /// build-safety point (the engine never paraphrases it).
    struct NativeEffect: Equatable {
        /// The verbatim statement source.
        let source: String
        /// The statement's source-order position (replay order).
        let ordinal: Int
    }

    /// One created view's accumulating state.
    struct ViewBuild {
        /// The widget constructor (`UILabel`, `UIStackView`, `UIButton`, …) or, for a
        /// non-lowerable subview, `customType` (the actual type, slotted).
        var widget: Widget
        var props = MutableProps()
        var constraints: [ConstraintBuild] = []
        /// For a stack created via `UIStackView(arrangedSubviews: [a,b])`: the initial
        /// arranged child names (added before the symbol table is walked further).
        var initialArranged: [String] = []
    }

    /// A folded constraint plus optional guest-EXPRESSION overrides for its numeric
    /// `constant`/`multiplier` (a design-system NUMERIC token: `__numtok_<id>`). The base
    /// `IRConstraint` carries the literal-folded values (the established path, byte-
    /// identical when no override is set); when an `*Expr` override is present the emitter
    /// prints THAT expression as the builder arg instead of the folded literal, so the
    /// constant is host-resolved in-guest. The IRConstraint that comes out the other side
    /// of the guest builder still carries a plain `Double` constant — ZERO wire change.
    struct ConstraintBuild {
        var base: IRConstraint
        var constantExpr: String?
        var multiplierExpr: String?
    }

    enum Widget: Equatable {
        case label, button, imageView, stackView, view, switchControl, slider, textField
        /// A subview whose type isn't a lowerable widget — slotted natively. `slotable`
        /// (computed at registration, where the AST is in hand) says whether the thunk
        /// can render it from a self-only closure.
        case custom(typeName: String, sourceExpr: String, slotable: Bool)
    }

    /// Mutable mirror of `UIKitViewProps` + the per-leaf payload, folded as set.
    ///
    /// Numeric/bool props are stored TWO ways: a folded scalar (`cornerRadius: Double?`,
    /// the common literal path) AND an optional guest-EXPRESSION override
    /// (`cornerRadiusExpr: String?`) carrying a ternary like `(big ? 12 : 4)`. When the
    /// expr override is set it wins at emit time (the guest evaluates it); otherwise the
    /// folded literal is printed. This keeps the literal path byte-identical (no
    /// regression) while adding model-driven conditional values additively.
    struct MutableProps {
        // common UIView props
        var backgroundColor: ColorRefLit?
        var cornerRadius: Double?
        var cornerRadiusExpr: String?
        var clipsToBounds: Bool?
        var clipsToBoundsExpr: String?
        var alpha: Double?
        var alphaExpr: String?
        var isHidden: Bool?
        var isHiddenExpr: String?
        var tintColor: ColorRefLit?
        var accessibilityIdentifier: String?
        // label payload
        var text: ExprLit?
        var font: FontLit?
        var textColor: ColorRefLit?
        var numberOfLines: Int?
        var numberOfLinesExpr: String?
        var textAlignment: String?
        // button payload
        var buttonTitle: ExprLit?
        var buttonTitleColor: ColorRefLit?
        var buttonFont: FontLit?
        var buttonAction: String?
        // imageView payload
        var image: ImageLit?
        var contentMode: String?
        // stack payload
        var axis: String?
        var spacing: Double?
        var spacingExpr: String?
        var stackAlignment: String?
        var distribution: String?
        // control payloads
        var isOn: Bool?
        var isOnExpr: String?
        var sliderValue: Double?
        var sliderValueExpr: String?
        var sliderMin: Double?
        var sliderMinExpr: String?
        var sliderMax: Double?
        var sliderMaxExpr: String?
        var switchEvent: String?
        var sliderEvent: String?
        var fieldText: ExprLit?
        var placeholder: ExprLit?
        var fieldEvent: String?
    }

    // A literal carried verbatim into the emitted guest (a string literal, or a
    // marshalled-input expression like `model.title` rewritten to `title`).
    struct ExprLit { var guest: String }       // emitted guest expression (String)
    struct ColorRefLit { var guest: String }   // a `ColorRef` builder expr
    struct FontLit { var guest: String }        // an `IRFont?` builder expr (or "nil")
    struct ImageLit { var guest: String }       // an `IRImageRef` builder expr
}
