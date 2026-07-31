// SPDX-License-Identifier: Apache-2.0

// UIKitEmitterMachine.swift — the statement-walking core of the UIKit cell lowering.
// =============================================================================
// The `UIKitEmitter` abstract machine (declared in UIKitEmitter.swift) executed
// over a cell construction method body: it classifies each statement into the
// recognized grammar, mutates the per-view build state, and finally walks the
// parent→child graph from the content root to emit a `UI.` builder expression.
//
// Recognized statements (anything else → whole-method demote):
//   1. `let v = UIWidget()` / `let v = UIWidget(arrangedSubviews: [a,b])` /
//      `let v = CustomView()`  — create a view (or a slotted custom subview).
//   2. `v.prop = <value>`      — fold a property into the build (or demote).
//   3. `parent.addSubview(child)` / `parent.addArrangedSubview(child)` — wire an edge.
//   4. `NSLayoutConstraint.activate([ <constraint>, … ])` — resolve constraints.
//   5. `<constraint>.isActive = true`                      — resolve one constraint.
//   6. `v.translatesAutoresizingMaskIntoConstraints = false` — ignored (the
//      renderer sets it uniformly).
//   7. `v.addTarget(self, action: #selector(...), for: .touchUpInside)` — wire an
//      action id (the thunk maps it to the native handler).
//   8. a bare `setupViews()` style call to a SAME-class no-arg helper whose body is
//      itself the recognized grammar — inlined (so a cell that splits its build
//      across `configure`+`setupViews` still lowers).  [conservative: only no-arg]

import SwiftSyntax
import ViewNodeIR

extension UIKitEmitter {

    /// Lower the method body to the root `UI.` builder expression, or nil (demote).
    mutating func emit(methodBody statements: CodeBlockItemListSyntax) -> String? {
        walk(statements)
        guard !bailed else { return nil }

        // R2-#30/#92 (build-safe = demote-safe): a property set under a model-driven `if`
        // branch is faithful ONLY when its target view is GATED on the SAME condition (so the
        // view is present iff its conditional property applies). A view configured inside a
        // branch but ADDED unconditionally (`if isError { titleLabel.textColor = .red }` with
        // `titleLabel` added outside the branch — or configured-in-branch then added by a later
        // unconditional `addSubviews(stack, badge)`) would apply the property to an always-
        // present view → a silent wrong-render across all rows. Demote any such view.
        for (viewName, propContexts) in propSetContexts {
            let gates = gateContexts[viewName] ?? []
            if !propContexts.isSubset(of: gates) {
                bail("conditional property set on a view not gated by the same condition (R2-#30/#92) — demote")
                return nil
            }
        }

        // The content root: the single view added to `contentView` (the conventional
        // cell shape). If the cell adds exactly one subview to contentView, that's the
        // root. If it adds several, we wrap them in a synthetic container. If it adds
        // NONE (e.g. the build targets `self` directly, or uses a content
        // configuration we don't model), demote — there's no tree to patch.
        let roots = contentRootNames()
        // A build that configures ONLY the root view (`view.backgroundColor = …`) with no
        // content children still has a tree (the styled root) — materialize it.
        guard !roots.isEmpty || rootPropsSet else { return nil }
        let rootName: String
        if roots.count == 1 && !rootPropsSet {
            // The established single-content-child-is-root path (byte-identical when the
            // root host view itself was never configured — Lever A is purely additive).
            rootName = roots[0]
        } else {
            // Wrap the content-root subviews in a synthetic container node. When the root
            // host view was configured (Lever A), the synthetic node CARRIES those props
            // (`rootProps`) — the renderer pins it to fill the host, so a root
            // `.background(…)` / `.cornerRadius(…)` paints exactly as the native set.
            rootName = "__patch_root"
            var build = ViewBuild(widget: .view)
            if rootPropsSet { build.props = rootProps }
            views[rootName] = build
            childrenStore[rootName] = roots
            creationOrder.insert(rootName, at: 0)
        }
        return emitNode(name: rootName, indent: 0)
    }

    /// Pre-register the cell's STORED view properties so a construction that
    /// configures a class-scope view lowers. Each becomes a widget (or a slotted
    /// custom leaf) in the symbol table; the stored name is a local name (a slot leaf
    /// referencing it isn't slotable). A stored view we can't classify as a known
    /// widget AND has no constructor to slot is registered as a bare `.view` (an empty
    /// container) so a later `addSubview` to it still resolves.
    mutating func seedStoredViews(_ props: [(name: String, initExpr: ExprSyntax?, typeName: String?)]) {
        for (name, initExpr, typeName) in props {
            localNames.insert(name)
            // A stored view property is reachable from the cross-file thunk as `self.<name>`
            // (a method-local view var is not) — track it so a quarantined view-targeted
            // native effect knows its receiver is thunk-reachable (Goal 1).
            storedViewNames.insert(name)
            // A known UIKit widget type by ANNOTATION → that widget, but ONLY when the
            // initializer is absent or a no-arg `Type()`. A `var x: UILabel = { …config… }()`
            // closure-call, or any constructor carrying args, must NOT register as a bare
            // widget (that drops the construction) — let the initializer-driven paths below
            // (bug-1/bug-3) classify it. (BUILD-SAFE = DEMOTE-SAFE.)
            if let t = typeName, let w = Self.widget(forType: t),
               Self.isNoArgWidgetInit(initExpr) {
                register(name: name, widget: w); continue
            }
            // A closure-call initializer (`lazy var x: UILabel = { … }()`): the closure body
            // configures the live property in ways we don't model here — render it as a
            // slotted custom leaf (`self.<name>`, the live lazy var) so its config is NOT
            // dropped. (Detect `{ … }()` — calledExpression is a ClosureExpr, possibly
            // parenthesized.)
            if let call = initExpr?.as(FunctionCallExprSyntax.self),
               Self.isClosureCall(call) {
                registerCustomStored(name: name, expr: ExprSyntax(call)); continue
            }
            if let call = initExpr?.as(FunctionCallExprSyntax.self),
               let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                if let w = Self.widget(forType: callee.baseName.text) {
                    // `UIStackView(arrangedSubviews: [a,b])` at class scope: seed arranged.
                    var build = ViewBuild(widget: w)
                    if w == .stackView,
                       let arg = call.arguments.first(where: { $0.label?.text == "arrangedSubviews" }),
                       let arr = arg.expression.as(ArrayExprSyntax.self) {
                        for el in arr.elements {
                            // BUILD-SAFE = DEMOTE-SAFE: an arranged element that is not a bare
                            // identifier naming a seedable view (an inline `UILabel()`, a call,
                            // etc.) can't be wired by name — silently dropping it would lose a
                            // child, so demote the whole method (mirror the local-var path).
                            guard let n = el.expression.as(DeclReferenceExprSyntax.self)?.baseName.text else {
                                bail("non-name in arrangedSubviews (stored stack)"); return
                            }
                            build.initialArranged.append(n)
                        }
                        arrangedParentsStore.insert(name)
                    } else if w == .imageView,
                              let arg = call.arguments.first(where: { $0.label?.text == "image" }),
                              let img = Self.imageLiteral(arg.expression) {
                        build.props.image = img
                    } else if w != .imageView, w != .stackView,
                              !Self.isBenignWidgetConstruction(call) {
                        // A widget constructor carrying a NON-BENIGN arg (one that materially
                        // changes the rendered widget, not a cosmetic/layout UIKit-shell arg
                        // like `type:`/`frame:`/`coder:`) — be conservative and slot the whole
                        // thing as a custom stored leaf (render `self.<name>`) instead of
                        // registering a bare widget that drops the construction. `UIButton(
                        // type:)`/`UIView(frame:)`/`UILabel(frame:)` stay benign → lower as the
                        // widget (the arg is cosmetic or auto-layout-overridden).
                        registerCustomStored(name: name, expr: ExprSyntax(call)); continue
                    }
                    views[name] = build
                    creationOrder.append(name)
                    if !build.initialArranged.isEmpty { childrenStore[name] = build.initialArranged }
                    continue
                }
                // A custom view type at class scope → a slotted custom leaf.
                registerCustomStored(name: name, expr: ExprSyntax(call)); continue
            }
            // A type-only stored prop of a custom type (`let chart: SparklineView`) →
            // a slotted custom leaf built from `Type()`.
            if let t = typeName, !t.hasPrefix("UI") {
                registerCustomStored(name: name, source: "\(t)()"); continue
            }
            // Fallback: an empty container (an `addSubview` target we couldn't classify).
            register(name: name, widget: .view)
        }
    }

    /// Register a stored CUSTOM view leaf. A stored custom view's slot closure renders
    /// `self.<name>` (the live cell property) — always slotable (it's a self member),
    /// UNLESS the property is private/fileprivate (the cross-file thunk can't see it).
    private mutating func registerCustomStored(name: String, expr: ExprSyntax) {
        registerCustomStored(name: name, source: "self.\(name)")
        _ = expr
    }
    private mutating func registerCustomStored(name: String, source: String) {
        let slotable = !inaccessibleNames.contains(name)
        views[name] = ViewBuild(widget: .custom(typeName: source, sourceExpr: source,
                                                slotable: slotable))
        creationOrder.append(name)
    }

    /// Whether a stored-view initializer is ABSENT or a no-arg widget constructor `Type()`
    /// — the only forms for which a type-annotation can safely register a bare widget. A
    /// closure-call (`{ … }()`) or an arg-carrying constructor (`UIButton(type:)`) is NOT
    /// no-arg → it must route to an initializer-driven path that preserves the construction.
    private static func isNoArgWidgetInit(_ initExpr: ExprSyntax?) -> Bool {
        guard let initExpr else { return true }       // `let v: UILabel` (configured later).
        guard let call = initExpr.as(FunctionCallExprSyntax.self) else { return false }
        // A direct `Type()` widget constructor with no arguments.
        return call.calledExpression.as(DeclReferenceExprSyntax.self) != nil
            && call.arguments.isEmpty
            && call.trailingClosure == nil
    }

    /// Cosmetic / auto-layout-overridden UIKit-shell widget-constructor args. A widget
    /// built with ONLY these lowers faithfully as the bare widget (the arg doesn't change
    /// the rendered structure) — `UIButton(type:)`, `UIView(frame:)`, `UILabel(frame:)`.
    private static let benignWidgetCtorArgs: Set<String> = ["type", "frame", "coder"]

    /// Whether a widget constructor carries ONLY benign cosmetic/shell args (so it can
    /// lower as the bare widget) vs a non-benign arg that materially changes the rendered
    /// widget (→ slot the whole construction). An UNLABELED arg is treated as non-benign
    /// (we can't classify it) → conservative slot.
    private static func isBenignWidgetConstruction(_ call: FunctionCallExprSyntax) -> Bool {
        guard call.trailingClosure == nil else { return false }
        for arg in call.arguments {
            guard let label = arg.label?.text,
                  benignWidgetCtorArgs.contains(label) else { return false }
        }
        return true
    }

    /// Whether `call` is an immediately-invoked closure `{ … }()` (or its parenthesized
    /// form `({ … })()`) — a config-closure initializer rather than a widget constructor.
    private static func isClosureCall(_ call: FunctionCallExprSyntax) -> Bool {
        var callee = call.calledExpression
        if let tuple = callee.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression {
            callee = inner
        }
        return callee.is(ClosureExprSyntax.self)
    }

    // MARK: - Statement walk

    private mutating func walk(_ statements: CodeBlockItemListSyntax) {
        for item in statements {
            if bailed { return }
            switch item.item {
            case .decl(let d):
                if let v = d.as(VariableDeclSyntax.self) { handleVarDecl(v) }
                else { bail("unsupported declaration: \(d.trimmedDescription)") }
            case .expr(let e):
                // A standalone `if cond { … }` parses as an `IfExprSyntax` expression
                // (model-driven conditional construction — Lever 1).
                if let ifExpr = e.as(IfExprSyntax.self) { handleConditional(ifExpr); continue }
                handleExpr(e)
            case .stmt(let s):
                // An `if`/`switch` may arrive wrapped in an `ExpressionStmtSyntax`.
                if let exprStmt = s.as(ExpressionStmtSyntax.self),
                   let ifExpr = exprStmt.expression.as(IfExprSyntax.self) {
                    handleConditional(ifExpr); continue
                }
                // A bare `return` (in an init) is fine; ignore it. Any other statement
                // (for/guard/while/…) isn't the recognized flat grammar — demote.
                if s.as(ReturnStmtSyntax.self) != nil { continue }
                bail("unsupported statement: \(s.trimmedDescription)")
            }
        }
    }

    /// Walk a code block's statements WITHOUT the content-root machinery (shared by the
    /// top-level walk, helper inlining, and conditional branches). Public-to-module so
    /// the conditional handler can recurse into a branch body.
    mutating func walkBlock(_ statements: CodeBlockItemListSyntax) { walk(statements) }

    // MARK: 1. `let v = UIWidget()` / custom view / arrangedSubviews

    mutating func handleVarDecl(_ v: VariableDeclSyntax) {
        for binding in v.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                bail("non-identifier binding"); return
            }
            localNames.insert(name)
            // A view var with NO initializer + a UI… type annotation is a stored-style
            // local declared then configured (`let v: UILabel`). Treat as a creation.
            guard let initExpr = binding.initializer?.value else {
                if let t = binding.typeAnnotation?.type.trimmedDescription, let w = Self.widget(forType: t) {
                    register(name: name, widget: w); continue
                }
                bail("local `\(name)` has no initializer"); return
            }
            // A NAMED CONSTRAINT binding: `let c = title.topAnchor.constraint(...)`
            // (Lever 3). Capture the constraint expression by name so a later
            // `NSLayoutConstraint.activate([c])` / `c.isActive = true` resolves the real
            // anchor form — instead of slotting the constraint as a (broken) custom view.
            if Self.isConstraintExpr(initExpr) {
                constraintVars[name] = (initExpr, nil)
                continue
            }
            // A `UIWidget(arrangedSubviews: [a, b])` initializer (stack with initial
            // arranged children).
            if let call = initExpr.as(FunctionCallExprSyntax.self),
               let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                let typeName = callee.baseName.text
                if let widget = Self.widget(forType: typeName) {
                    var build = ViewBuild(widget: widget)
                    // `UIStackView(arrangedSubviews: [a, b])` → seed arranged children.
                    if widget == .stackView,
                       let arg = call.arguments.first(where: { $0.label?.text == "arrangedSubviews" }),
                       let arr = arg.expression.as(ArrayExprSyntax.self) {
                        for el in arr.elements {
                            guard let n = el.expression.as(DeclReferenceExprSyntax.self)?.baseName.text else {
                                bail("non-name in arrangedSubviews"); return
                            }
                            build.initialArranged.append(n)
                        }
                        arrangedParentsStore.insert(name)
                    } else if !call.arguments.isEmpty, widget != .imageView {
                        // A widget constructor with UNEXPECTED args (other than the few we
                        // model) — be conservative and slot the whole thing as custom.
                        registerCustom(name: name, call: call); continue
                    }
                    views[name] = build
                    creationOrder.append(name)
                    if !build.initialArranged.isEmpty { childrenStore[name] = build.initialArranged }
                    continue
                }
                // `UIImageView(image: UIImage(systemName:))` etc. — model image init.
                if typeName == "UIImageView" {
                    var build = ViewBuild(widget: .imageView)
                    if let arg = call.arguments.first(where: { $0.label?.text == "image" }),
                       let img = Self.imageLiteral(arg.expression) {
                        build.props.image = img
                    }
                    views[name] = build; creationOrder.append(name); continue
                }
                // An unknown constructor → a slotted custom subview.
                registerCustom(name: name, call: call); continue
            }
            // A non-call initializer (`let v = someFactory`) — slot it as custom (it's a
            // view value we can't introspect).
            registerCustom(name: name, expr: initExpr); continue
        }
    }

    private mutating func register(name: String, widget: Widget) {
        views[name] = ViewBuild(widget: widget)
        creationOrder.append(name)
    }

    private mutating func registerCustom(name: String, call: FunctionCallExprSyntax) {
        registerCustom(name: name, expr: ExprSyntax(call))
    }
    private mutating func registerCustom(name: String, expr: ExprSyntax) {
        let source = expr.trimmedDescription
        // Compute slotability NOW (we have the real AST node): the leaf renders from a
        // self-only closure `{ <source> }` in the cross-file thunk, so it must NOT
        // reference a body-local OR an inaccessible (private/fileprivate) member. The
        // local view names referenced inside an initializer are exactly the wiring we
        // already lowered, so a typical `CustomView()` / `CustomView(model: model)` is
        // slotable (it reads `model`, a self-equivalent input, fine).
        let blocked = localNames.union(inaccessibleNames)
        let slotable = blocked.isEmpty || !ReferencedNameScanner.referencesAny(expr, of: blocked)
        views[name] = ViewBuild(widget: .custom(typeName: source, sourceExpr: source,
                                                slotable: slotable))
        creationOrder.append(name)
    }

    // MARK: - Content root resolution

    /// The content-root view names: those added to `contentView` (or, for a header/
    /// footer view, directly — but we standardize on contentView). De-duplicated,
    /// preserving order.
    private func contentRootNames() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for n in contentViewChildrenStore where views[n] != nil && seen.insert(n).inserted {
            out.append(n)
        }
        return out
    }
}
