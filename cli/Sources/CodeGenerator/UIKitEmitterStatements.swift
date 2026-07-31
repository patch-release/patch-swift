// SPDX-License-Identifier: Apache-2.0

// UIKitEmitterStatements.swift — expression-statement classification for the cell
// lowering machine: property sets, subview wiring, constraint activation, addTarget.
// =============================================================================
// Each top-level expression statement in the construction is one of:
//   * an ASSIGNMENT `lhs = rhs` — a property set (`title.text = …`,
//     `v.translatesAutoresizingMaskIntoConstraints = false`) or a
//     `<constraint>.isActive = true`,
//   * a CALL `recv.method(args)` — `addSubview`/`addArrangedSubview`/`addTarget`/
//     `NSLayoutConstraint.activate`/`setTitle`/… ,
//   * a bare reference to a same-class no-arg helper (inlined).
// Anything else demotes the whole method (`bail`).

import SwiftSyntax
import ViewNodeIR

extension UIKitEmitter {

    mutating func bail(_ reason: String) {
        guard !bailedFlag else { return }
        bailedFlag = true
        bailReasonStore = reason
    }
    var bailed: Bool { bailedFlag }

    // MARK: - Expression statement dispatch

    mutating func handleExpr(_ expr: ExprSyntax) {
        // An assignment: `lhs = rhs`. SwiftParser models this as a SequenceExpr
        // (lhs, AssignmentExpr, rhs) unless folded; handle both shapes.
        if let assign = Self.asAssignment(expr) {
            recognizeOrQuarantine(expr) { $0.handleAssignment(lhs: assign.lhs, rhs: assign.rhs) }
            return
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            recognizeOrQuarantine(expr) { $0.handleCall(call) }
            return
        }
        // A bare reference `setupViews` (no parens) is unusual; a call `setupViews()`
        // is a FunctionCallExpr handled above. Anything else → demote.
        bail("unsupported expression: \(expr.trimmedDescription)")
    }

    /// Run a recognized-grammar handler; if it DEMOTES (sets `bailed`), try to QUARANTINE
    /// the statement as a native effect (Goal 1 — granular per-statement partitioning)
    /// instead of letting the whole method demote. A successful quarantine CLEARS the bail
    /// (the surrounding declarative construction keeps lowering); a failed one leaves the
    /// bail in place (conservative whole-method demote — demote-safe + build-safe). Only
    /// the FIRST bail per statement is considered (a statement either lowers, quarantines,
    /// or demotes — never partway).
    private mutating func recognizeOrQuarantine(_ expr: ExprSyntax,
                                                _ recognize: (inout UIKitEmitter) -> Void) {
        // Was the machine ALREADY demoted before this statement? (It shouldn't be — `walk`
        // returns on `bailed` — but be defensive: if so, leave it alone.)
        let hadBailed = bailedFlag
        recognize(&self)
        // Recognized cleanly (or was already bailed before we ran) — nothing to do.
        guard bailedFlag, !hadBailed else { return }
        // The handler demoted this statement. Capture the recognized-path bail REASON (set
        // by `recognize`, so AFTER the call) so we can restore it verbatim if the quarantine
        // declines. The recognized handlers bail BEFORE mutating view state on the demoting
        // path (every `applyProperty` case is `if let x = resolve { set } else { bail }`), so
        // rolling back the bail flag + reason is the only load-bearing rollback.
        let recognizedReason = bailReasonStore
        // Clear the demote so the quarantine path runs on a clean machine; restore it if the
        // quarantine declines (the statement genuinely isn't isolatable → whole-method demote).
        bailedFlag = false
        bailReasonStore = ""
        if !tryQuarantine(expr) {
            bailedFlag = true
            bailReasonStore = recognizedReason
        }
    }

    /// Peel a trailing `?` optional-chaining wrapper (`v.titleLabel?` → `v.titleLabel`).
    /// Returns the inner expression (or the same expression when not optional-chained).
    static func unwrapOptionalChain(_ expr: ExprSyntax) -> ExprSyntax? {
        if let chain = expr.as(OptionalChainingExprSyntax.self) { return chain.expression }
        return expr
    }

    /// Decompose `lhs = rhs` from either a folded `AssignmentExprSyntax`-bearing
    /// `InfixOperatorExprSyntax`, or an unfolded `SequenceExprSyntax`. The RHS may itself
    /// be a multi-element subsequence (an UNFOLDED ternary `cond ? a : b` parses as 3
    /// trailing elements) — rebuild it as a `SequenceExpr` so a conditional value RHS is
    /// recognized (`asTernary` re-decodes it).
    static func asAssignment(_ expr: ExprSyntax) -> (lhs: ExprSyntax, rhs: ExprSyntax)? {
        if let infix = expr.as(InfixOperatorExprSyntax.self),
           infix.operator.is(AssignmentExprSyntax.self) {
            return (infix.leftOperand, infix.rightOperand)
        }
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            guard elems.count >= 3, elems[1].is(AssignmentExprSyntax.self) else { return nil }
            let lhs = elems[0]
            let rhsElems = Array(elems[2...])
            if rhsElems.count == 1 {
                return (lhs, rhsElems[0])
            }
            // Rebuild the trailing elements as a SequenceExpr (an unfolded ternary/infix
            // RHS); the value resolvers fold/decode it.
            let rhsSeq = SequenceExprSyntax(elements: ExprListSyntax(rhsElems))
            return (lhs, ExprSyntax(rhsSeq))
        }
        return nil
    }

    // MARK: - Assignments: property sets + constraint.isActive

    private mutating func handleAssignment(lhs: ExprSyntax, rhs: ExprSyntax) {
        // A BARE-identifier lhs (`backgroundColor = …`, `layer = …` is nonsense): for a
        // `UIView`/VC subclass building into `self`, an unqualified property set targets
        // the CONTENT ROOT itself (Lever A — `backgroundColor`, `clipsToBounds`, `alpha`).
        // The renderer pins the lowered root to fill the host, so a root `.background(…)`
        // paints exactly as the native `self.backgroundColor`. A bare ident that ISN'T a
        // root-modelable prop demotes (honest — e.g. `title = …` we can't model).
        if let ref = lhs.as(DeclReferenceExprSyntax.self) {
            if containerKind == .viewController, views[ref.baseName.text] == nil {
                applyRootProperty(prop: ref.baseName.text, value: rhs); return
            }
            bail("unsupported assignment lhs: \(lhs.trimmedDescription)"); return
        }
        guard let member = lhs.as(MemberAccessExprSyntax.self),
              let baseExpr = member.base else {
            bail("unsupported assignment lhs: \(lhs.trimmedDescription)"); return
        }
        let prop = member.declName.baseName.text

        // ROOT-view property config (Lever A): `view.<prop>` (VC), `self.<prop>` /
        // `self.view.<prop>` — a property set on the CONTENT ROOT host view. Folds onto the
        // synthetic root node (materialized at emit when `rootPropsSet`). A bare `layer.x`
        // / `view.layer.x` / `self.layer.x` (root layer config) routes to the root layer.
        if Self.isRootReceiver(baseExpr, kind: containerKind), views[Self.receiverName(baseExpr) ?? ""] == nil {
            applyRootProperty(prop: prop, value: rhs); return
        }
        // `view.layer.cornerRadius` / `layer.cornerRadius` (bare) / `self.layer.cornerRadius`
        // — root layer property. The lhs base is `<root>.layer` or bare `layer`.
        if let layerBase = Self.unwrapOptionalChain(baseExpr),
           Self.isRootLayerReceiver(layerBase, kind: containerKind) {
            applyRootLayerProperty(prop: prop, value: rhs); return
        }

        // `<constraintExpr>.isActive = true` — resolve a single constraint.
        if prop == "isActive" {
            guard rhs.trimmedDescription == "true" else {
                bail(".isActive set to non-true"); return
            }
            resolveConstraintExpr(baseExpr)
            return
        }
        // `c.priority = .defaultHigh` on a NAMED constraint binding — capture the priority
        // so the later `c.isActive = true` / `activate([c])` carries it. (A priority set on
        // anything that ISN'T a known constraint var falls through to demote.)
        if prop == "priority",
           let ref = baseExpr.as(DeclReferenceExprSyntax.self),
           constraintVars[ref.baseName.text] != nil {
            let p = Self.layoutPriorityValue(rhs)
            constraintVars[ref.baseName.text]?.priority = p
            return
        }
        // `v.translatesAutoresizingMaskIntoConstraints = false` — the renderer sets
        // this uniformly; accept + ignore (any value).
        if prop == "translatesAutoresizingMaskIntoConstraints" { return }

        // A nested `v.layer.cornerRadius = r` (or `.masksToBounds`): the lhs base is
        // itself `v.layer`. Resolve the view + delegate to the layer-property folder.
        // The base may be optional-chained (`v.layer?.cornerRadius`).
        if let layerBase = Self.unwrapOptionalChain(baseExpr),
           let layerMember = layerBase.as(MemberAccessExprSyntax.self),
           layerMember.declName.baseName.text == "layer",
           let viewName = Self.unwrapOptionalChain(layerMember.base ?? ExprSyntax(layerMember))
               .flatMap({ $0.as(DeclReferenceExprSyntax.self)?.baseName.text }),
           views[viewName] != nil {
            recordPropContext(viewName)
            applyLayerProperty(viewName: viewName, prop: prop, value: rhs)
            return
        }

        // A `button.titleLabel?.font = …` / `.textColor` / `.numberOfLines` — the common
        // way to style a UIButton's text. Route onto the button's leaf payload (font →
        // the button font, textColor → the title color). The base is `button.titleLabel`
        // (possibly optional-chained: `button.titleLabel?`).
        if let tlBase = Self.unwrapOptionalChain(baseExpr),
           let tlMember = tlBase.as(MemberAccessExprSyntax.self),
           tlMember.declName.baseName.text == "titleLabel",
           let viewName = tlMember.base?.as(DeclReferenceExprSyntax.self)?.baseName.text,
           views[viewName]?.widget == .button {
            recordPropContext(viewName)
            applyButtonTitleLabelProperty(viewName: viewName, prop: prop, value: rhs)
            return
        }

        // A property set on a known view: `title.text = …`.
        guard let viewName = baseExpr.as(DeclReferenceExprSyntax.self)?.baseName.text,
              views[viewName] != nil else {
            bail("property set on unknown view: \(lhs.trimmedDescription)"); return
        }
        recordPropContext(viewName)
        applyProperty(viewName: viewName, prop: prop, value: rhs)
    }

    /// R2-#30/#92: record that a property was set on `viewName` under the active visibility
    /// context (if any). A static tree applies a property unconditionally, so a conditional
    /// property set is faithful only when the target view is gated on the same condition —
    /// `emit()` verifies that (else demotes). A top-level (nil-context) set records nothing.
    mutating func recordPropContext(_ viewName: String) {
        guard let cond = pendingVisibility else { return }
        propSetContexts[viewName, default: []].insert(cond)
    }

    // MARK: - Calls: subview wiring / constraint.activate / addTarget / setters

    private mutating func handleCall(_ call: FunctionCallExprSyntax) {
        // A VC `viewDidLoad` construction conventionally opens with `super.viewDidLoad()`
        // (the mandatory chained call) before building the view tree. It mutates no view
        // tree we model — tolerate + ignore it so a `viewDidLoad`-rooted build still
        // lowers. Scoped to a `super.<lifecycle>()` no-arg call (never a `super.<other>`).
        if containerKind == .viewController,
           let m = call.calledExpression.as(MemberAccessExprSyntax.self),
           m.base?.as(SuperExprSyntax.self) != nil,
           call.arguments.isEmpty, call.trailingClosure == nil,
           UIKitCellLowering.uiKitLifecycleSuperCalls.contains(m.declName.baseName.text) {
            return
        }
        // `[a, b, c].forEach { … }` / `[a, b].forEach(parent.addArrangedSubview)` —
        // the canonical "wire several views at once" idiom (Lever F). Recognized only
        // when the receiver is an ARRAY LITERAL of known views and the closure/method-ref
        // does ONLY provable subview-wiring + TAMIC no-ops (anything else demotes).
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "forEach",
           let arrayBase = member.base?.as(ArrayExprSyntax.self) {
            handleForEachOverViews(arrayBase: arrayBase, call: call)
            return
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              let baseExpr = member.base else {
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                // A bare `setupViews()` (no args) → inline a same-class no-arg helper.
                if call.arguments.isEmpty, call.trailingClosure == nil {
                    inlineHelperCall(callee.baseName.text)
                    return
                }
                // A bare `addSubview(child)` / `addArrangedSubview(child)` (implicit
                // `self` receiver) — for a `UIView` subclass that builds into ITSELF.
                // The child roots at `self` (the content root). Only valid for a VC/View
                // container; a cell's content root is always `contentView`.
                if containerKind == .viewController,
                   callee.baseName.text == "addSubview" || callee.baseName.text == "addArrangedSubview" {
                    handleAddChild(parentExpr: ExprSyntax(DeclReferenceExprSyntax(baseName: .keyword(.self))),
                                   parentName: nil, call: call,
                                   arranged: callee.baseName.text == "addArrangedSubview")
                    return
                }
                // A bare VARIADIC `addSubviews(a, b, c)` (implicit self) — the Firefox-style
                // `func addSubviews(_ views: UIView...)` convention (Lever C). Each arg is a
                // child added to the content root. Only valid for a VC/View container.
                if containerKind == .viewController,
                   callee.baseName.text == "addSubviews" || callee.baseName.text == "addArrangedSubviews" {
                    handleAddSubviewsVariadic(parentExpr: ExprSyntax(DeclReferenceExprSyntax(baseName: .keyword(.self))),
                                              parentName: nil, call: call,
                                              arranged: callee.baseName.text == "addArrangedSubviews")
                    return
                }
            }
            bail("unsupported call: \(call.trimmedDescription)"); return
        }
        let method = member.declName.baseName.text
        let baseName = baseExpr.as(DeclReferenceExprSyntax.self)?.baseName.text

        switch method {
        case "addSubview", "addArrangedSubview":
            handleAddChild(parentExpr: baseExpr, parentName: baseName, call: call,
                           arranged: method == "addArrangedSubview")
        case "addSubviews", "addArrangedSubviews":
            // A VARIADIC `view.addSubviews(a, b, c)` / `stack.addArrangedSubviews(a, b)`
            // (Lever C — the common helper-extension convention). Add each arg as a child.
            handleAddSubviewsVariadic(parentExpr: baseExpr, parentName: baseName, call: call,
                                      arranged: method == "addArrangedSubviews")
        case "activate" where baseName == "NSLayoutConstraint":
            handleActivate(call)
        case "addTarget":
            handleAddTarget(viewName: baseName, call: call)
        case "addGestureRecognizer":
            // Lever 1: `someView.addGestureRecognizer(UITapGestureRecognizer(target: self,
            // action: #selector(handleTap)))` — replay the native wiring against `self` +
            // the rendered view from the thunk. Recognized only when `someView` is a known
            // view, the gesture's target is `self`, and its action is a `#selector`.
            handleAddGestureRecognizer(viewName: baseName, call: call)
        case "addObserver" where Self.isNotificationCenterReceiver(baseExpr):
            // Lever 2: `NotificationCenter.default.addObserver(self, selector: #selector(…),
            // name: …, object: …)` — a method-level effect re-run natively from the thunk.
            // The block-based `addObserver(forName:object:queue:using:)` (a closure) is NOT
            // this canonical shape and DEMOTES via the guards below.
            handleAddObserver(call: call)
        case "setTitle", "setTitleColor", "setImage", "setBackgroundImage":
            handleButtonSetter(viewName: baseName, method: method, call: call)
        case "setCustomSpacing":
            // `stack.setCustomSpacing(_:after:)` — not modeled per-gap; demote to keep
            // faithful (a uniform `spacing` is modeled; per-gap isn't in the IR).
            bail("setCustomSpacing not modeled")
        case _ where Self.toleratedConfigCalls.contains(method) && (baseName != nil && views[baseName!] != nil):
            // A harmless layout-hint / no-render-effect config call ON A KNOWN VIEW
            // (`label.setContentHuggingPriority(...)`, `v.setContentCompressionResistancePriority(...)`,
            // `v.sizeToFit()`). These tune Auto Layout behavior but DON'T change the
            // lowered subview tree — accept (tolerate) rather than demote. Scoped to a
            // known local view so we never blanket-ignore an unknown receiver's call.
            return
        default:
            bail("unsupported call `\(method)` on \(baseExpr.trimmedDescription)")
        }
    }

    /// Calls on a known view that tune layout behavior / are no-ops for the lowered tree.
    /// Tolerated (accepted) so a construction that includes them still lowers; never a
    /// blanket ignore — they must target a KNOWN view (checked at the call site).
    static let toleratedConfigCalls: Set<String> = [
        "setContentHuggingPriority", "setContentCompressionResistancePriority",
        "sizeToFit", "setNeedsLayout", "layoutIfNeeded", "setNeedsUpdateConstraints",
    ]

    private mutating func handleAddChild(parentExpr: ExprSyntax, parentName: String?,
                                         call: FunctionCallExprSyntax, arranged: Bool) {
        guard let childExpr = call.arguments.first?.expression else {
            bail("addSubview of non-view: \(call.trimmedDescription)"); return
        }
        addChild(childExpr: childExpr, parentExpr: parentExpr, parentName: parentName,
                 arranged: arranged, callDesc: call.trimmedDescription)
    }

    /// A VARIADIC `addSubviews(a, b, c)` / `addArrangedSubviews(a, b)` (Lever C): add EACH
    /// argument as a child of the parent. Each arg must be a known view name (a literal
    /// `UIView()` arg demotes via `addChild`, faithful). The order is the argument order.
    private mutating func handleAddSubviewsVariadic(parentExpr: ExprSyntax, parentName: String?,
                                                    call: FunctionCallExprSyntax, arranged: Bool) {
        guard !call.arguments.isEmpty else { return }
        for arg in call.arguments {
            if bailed { return }
            addChild(childExpr: arg.expression, parentExpr: parentExpr, parentName: parentName,
                     arranged: arranged, callDesc: call.trimmedDescription)
        }
    }

    // MARK: - Lever F: `[viewList].forEach { … }` / `.forEach(parent.addSubview)`

    /// `[a, b, c].forEach { … }` over an ARRAY LITERAL of known views (Lever F — the #1
    /// remaining UIKit construction demote). Every array element must be a KNOWN view name
    /// (a literal `UILabel()` element demotes — never silently add a non-view). The forEach
    /// "body" must be ONE of these PROVABLE forms — anything else demotes (build-safe +
    /// demote-safe), because a richer body (per-element constraints referencing `$0`, a
    /// property set we can't model, a nested call) carries structure the flat tree can't
    /// reflect:
    ///   1. a METHOD REFERENCE `parent.addArrangedSubview` / `parent.addSubview` (or bare
    ///      `addSubview`/`addArrangedSubview` — implicit self/content-root): add each
    ///      element to that parent, in array order.
    ///   2. a CLOSURE `{ … }` (single param `$0` or a named param) whose body contains ONLY
    ///      (a) `$0.translatesAutoresizingMaskIntoConstraints = false` (a no-op the renderer
    ///      sets uniformly) and/or (b) an `addSubview($0)`/`parent.addArrangedSubview($0)`
    ///      wiring of the loop element. (A closure with a `NSLayoutConstraint.activate`, a
    ///      property set, or any other statement demotes — that's per-element structure the
    ///      flat tree can't capture.)
    private mutating func handleForEachOverViews(arrayBase: ArrayExprSyntax,
                                                 call: FunctionCallExprSyntax) {
        // The array elements must all be known view names (else demote — faithful).
        var elementNames: [String] = []
        for el in arrayBase.elements {
            guard let n = el.expression.as(DeclReferenceExprSyntax.self)?.baseName.text,
                  views[n] != nil else {
                bail("forEach over a non-view-array element: \(el.expression.trimmedDescription)")
                return
            }
            elementNames.append(n)
        }
        guard !elementNames.isEmpty else { return }

        // Form 1: a METHOD REFERENCE argument — `parent.addArrangedSubview` (no parens).
        // (A trailing closure takes precedence; check the explicit arg first.)
        if call.trailingClosure == nil, call.arguments.count == 1,
           let methodRef = call.arguments.first?.expression {
            handleForEachMethodRef(elements: elementNames, methodRef: methodRef, callDesc: call.trimmedDescription)
            return
        }

        // Form 2: a CLOSURE body (trailing or explicit single closure arg).
        let closure = call.trailingClosure
            ?? call.arguments.first?.expression.as(ClosureExprSyntax.self)
        if let closure {
            handleForEachClosure(elements: elementNames, closure: closure, callDesc: call.trimmedDescription)
            return
        }
        bail("forEach with an unrecognized argument: \(call.trimmedDescription)")
    }

    /// Form 1: `[a, b].forEach(parent.addArrangedSubview)` — a bare method reference. The
    /// reference must name `addSubview`/`addArrangedSubview` on the content root, a known
    /// view, or be the implicit-self bare form. Add each element to that parent in order.
    private mutating func handleForEachMethodRef(elements: [String], methodRef: ExprSyntax,
                                                 callDesc: String) {
        // `parent.addArrangedSubview` — a member access with no call parens.
        if let m = methodRef.as(MemberAccessExprSyntax.self), let parentExpr = m.base {
            let method = m.declName.baseName.text
            guard method == "addSubview" || method == "addArrangedSubview" else {
                bail("forEach method-ref isn't addSubview/addArrangedSubview: \(callDesc)"); return
            }
            let parentName = parentExpr.as(DeclReferenceExprSyntax.self)?.baseName.text
            for el in elements {
                if bailed { return }
                addChild(childExpr: ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(el))),
                         parentExpr: parentExpr, parentName: parentName,
                         arranged: method == "addArrangedSubview", callDesc: callDesc)
            }
            return
        }
        // A bare `addSubview` / `addArrangedSubview` reference (implicit self / content root)
        // — only meaningful for a VC/View building into itself.
        if let ref = methodRef.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "addSubview" || ref.baseName.text == "addArrangedSubview",
           containerKind == .viewController {
            let arranged = ref.baseName.text == "addArrangedSubview"
            let selfExpr = ExprSyntax(DeclReferenceExprSyntax(baseName: .keyword(.self)))
            for el in elements {
                if bailed { return }
                addChild(childExpr: ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(el))),
                         parentExpr: selfExpr, parentName: nil, arranged: arranged, callDesc: callDesc)
            }
            return
        }
        bail("forEach method-ref isn't a recognized add wiring: \(callDesc)")
    }

    /// Form 2: a CLOSURE body. The closure has ONE parameter (the loop element — `$0` or a
    /// named param). Its body may contain ONLY TAMIC no-ops and/or one add-wiring of that
    /// element; any other statement demotes (per-element structure the flat tree can't hold).
    private mutating func handleForEachClosure(elements: [String], closure: ClosureExprSyntax,
                                               callDesc: String) {
        // Resolve the loop-parameter name: `$0` (shorthand, no signature) or a named param.
        let paramName: String
        if let sig = closure.signature {
            // A `{ view in … }` named param. Reject a multi-param / capture-list signature.
            if let params = sig.parameterClause?.as(ClosureShorthandParameterListSyntax.self) {
                guard params.count == 1, let only = params.first else {
                    bail("forEach closure isn't single-parameter: \(callDesc)"); return
                }
                paramName = only.name.text
            } else if let params = sig.parameterClause?.as(ClosureParameterClauseSyntax.self) {
                guard params.parameters.count == 1, let only = params.parameters.first else {
                    bail("forEach closure isn't single-parameter: \(callDesc)"); return
                }
                paramName = only.firstName.text
            } else {
                bail("forEach closure signature unrecognized: \(callDesc)"); return
            }
        } else {
            paramName = "$0"
        }

        // Each statement in the closure body must be one of the two provable forms over the
        // loop param. We collect the wiring intent (a single add-target parent) — a closure
        // adding the element to AT MOST one parent (the common shape).
        var addParentExpr: ExprSyntax? = nil
        var addParentName: String? = nil
        var addArranged = false
        var sawAdd = false
        for item in closure.statements {
            guard case .expr(let e) = item.item else {
                bail("forEach closure has a non-expression statement: \(item.trimmedDescription)"); return
            }
            // (a) `$0.translatesAutoresizingMaskIntoConstraints = false` — a no-op.
            if let assign = Self.asAssignment(e),
               let m = assign.lhs.as(MemberAccessExprSyntax.self),
               m.declName.baseName.text == "translatesAutoresizingMaskIntoConstraints",
               m.base?.trimmedDescription == paramName {
                continue
            }
            // (b) an add-wiring of the loop element: `addSubview($0)` (implicit) or
            //     `parent.addSubview($0)` / `parent.addArrangedSubview($0)`.
            if let inner = e.as(FunctionCallExprSyntax.self),
               let (pExpr, pName, arranged, isAddOfParam) =
                   forEachAddWiring(inner, loopParam: paramName) {
                guard isAddOfParam else {
                    bail("forEach closure call isn't an add of the loop element: \(inner.trimmedDescription)"); return
                }
                // Only ONE add target per closure (a second, different parent isn't the flat shape).
                if sawAdd, pExpr?.trimmedDescription != addParentExpr?.trimmedDescription || arranged != addArranged {
                    bail("forEach closure adds to multiple parents: \(callDesc)"); return
                }
                addParentExpr = pExpr; addParentName = pName; addArranged = arranged; sawAdd = true
                continue
            }
            bail("forEach closure has an unsupported statement: \(item.trimmedDescription)"); return
        }
        // A TAMIC-only closure (no add) is a pure no-op — accept (the views are wired
        // elsewhere; we just tolerate the uniform TAMIC set).
        guard sawAdd, let pExpr = addParentExpr else { return }
        for el in elements {
            if bailed { return }
            addChild(childExpr: ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(el))),
                     parentExpr: pExpr, parentName: addParentName, arranged: addArranged, callDesc: callDesc)
        }
    }

    /// Decode an add-wiring call inside a forEach closure: `addSubview($0)` (implicit
    /// self / content root) or `parent.addSubview($0)` / `parent.addArrangedSubview($0)`.
    /// Returns (parentExpr, parentName, arranged, isAddOfLoopParam) when the call is a
    /// recognized add of the SINGLE loop parameter; nil when it isn't an add wiring.
    private func forEachAddWiring(_ call: FunctionCallExprSyntax, loopParam: String)
        -> (parentExpr: ExprSyntax?, parentName: String?, arranged: Bool, isAddOfParam: Bool)? {
        let isAddOfParam: Bool = {
            guard call.arguments.count == 1, call.trailingClosure == nil,
                  let a = call.arguments.first?.expression else { return false }
            return a.trimmedDescription == loopParam
        }()
        // `parent.addSubview($0)` — member access.
        if let m = call.calledExpression.as(MemberAccessExprSyntax.self), let parentExpr = m.base {
            let method = m.declName.baseName.text
            guard method == "addSubview" || method == "addArrangedSubview" else { return nil }
            return (parentExpr, parentExpr.as(DeclReferenceExprSyntax.self)?.baseName.text,
                    method == "addArrangedSubview", isAddOfParam)
        }
        // bare `addSubview($0)` (implicit self / content root) — VC only.
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "addSubview" || ref.baseName.text == "addArrangedSubview",
           containerKind == .viewController {
            let selfExpr = ExprSyntax(DeclReferenceExprSyntax(baseName: .keyword(.self)))
            return (selfExpr, nil, ref.baseName.text == "addArrangedSubview", isAddOfParam)
        }
        return nil
    }

    /// Add one child (named by `childExpr`) to `parent`. Shared by the single-`addSubview`
    /// and variadic-`addSubviews` paths.
    private mutating func addChild(childExpr: ExprSyntax, parentExpr: ExprSyntax,
                                   parentName: String?, arranged: Bool, callDesc: String) {
        guard let childName = childExpr.as(DeclReferenceExprSyntax.self)?.baseName.text,
              views[childName] != nil else {
            bail("addSubview of non-view: \(callDesc)"); return
        }
        // Model-driven conditional construction (Lever 1): when this `addSubview` is
        // inside an `if cond { … }` branch, the child is GATED — it paints only when the
        // marshalled condition holds. We model that as a guest `.hidden(!cond)`.
        //
        // BUG #39 (build-safe = demote-safe): `.hidden` is faithful ONLY for an ARRANGED
        // (UIStackView) child — a hidden arranged-subview COLLAPSES, so siblings reflow
        // exactly as they would have had the view never been added. A hidden PLAIN
        // (non-arranged) child, however, still owns its Auto Layout constraints: a
        // constraint-driven badge gated by `if isPremium` would keep its 24pt height +
        // its sibling-relative constraints ACTIVE even when hidden, leaving a phantom gap
        // the native code (which simply never `addSubview`s the badge) does NOT have. We
        // can't faithfully reconstruct "view not added" via visibility when constraints
        // are involved, so a conditionally-gated NON-ARRANGED child demotes the whole
        // method to native (honest, never a wrong layout). Every faithful real-world
        // conditional ("show this badge only when premium") routes the child through a
        // stack, which keeps lowering.
        if let cond = pendingVisibility {
            guard arranged else {
                bail("conditional non-arranged child (constraint-driven gap risk) — demote")
                return
            }
            applyPendingVisibility(to: childName, condition: cond)
        }
        // The parent is the CONTENT-ROOT host view, a known local view, or demote. The
        // content root differs by container kind: a cell adds into `contentView`; a
        // programmatic VC adds into its root `view` (`view`/`self.view`). Either way the
        // child becomes a content-root candidate — the lowered tree is rooted there and
        // the SDK installs it into the corresponding host view.
        if Self.isContentRootParent(name: parentName, expr: parentExpr, kind: containerKind) {
            contentViewChildrenStore.append(childName)
            return
        }
        guard let parent = parentName, views[parent] != nil else {
            bail("addSubview to unknown parent: \(parentExpr.trimmedDescription)"); return
        }
        childrenStore[parent, default: []].append(childName)
        if arranged { arrangedParentsStore.insert(parent) }
    }

    private mutating func handleActivate(_ call: FunctionCallExprSyntax) {
        guard let arr = call.arguments.first?.expression.as(ArrayExprSyntax.self) else {
            bail("NSLayoutConstraint.activate without an array literal"); return
        }
        for el in arr.elements {
            if bailed { return }
            resolveConstraintExpr(el.expression)
        }
    }

    private mutating func handleAddTarget(viewName: String?, call: FunctionCallExprSyntax) {
        guard let viewName, views[viewName] != nil else {
            bail("addTarget on unknown view"); return
        }
        // `v.addTarget(self, action: #selector(handleTap), for: .touchUpInside)` — derive
        // a stable action id from the selector name; record it as the view's event.
        var selectorName = ""
        for arg in call.arguments where arg.label?.text == "action" {
            // `#selector(foo)` → "foo"; `#selector(self.foo(_:))` → "foo".
            let raw = arg.expression.trimmedDescription
            selectorName = Self.selectorBaseName(raw)
        }
        guard !selectorName.isEmpty else { bail("addTarget without a #selector"); return }
        // DEMOTE-SAFE (BUG #17/#18 — the dead-button fix): the action handler is REPLAYED
        // by the generated cross-file `@_dynamicReplacement` thunk as `self.<selector>()`,
        // so it must be a `self` target with a thunk-REACHABLE (non-private/fileprivate)
        // selector. Without this the control rendered but the user's tap did nothing — a
        // silent dead control. The first (unlabeled) `addTarget` argument is the target;
        // require it to be `self` (the dominant cell shape — a different target object isn't
        // reachable from the thunk). Mirrors the gesture/observer selector levers.
        let targetIsSelf = call.arguments.first.map {
            $0.label == nil && $0.expression.trimmedDescription == "self"
        } ?? false
        guard targetIsSelf else {
            bail("addTarget target isn't self (thunk-unreachable handler)"); return
        }
        guard !inaccessibleNames.contains(selectorName) else {
            bail("addTarget selector is private/fileprivate (thunk-unreachable)"); return
        }
        // ARITY GATE (R2-#2/#31 — the dev-build-break fix): the generated thunk replays the
        // handler as `self.<selector>()` with ZERO args. The canonical UIKit handler takes a
        // SENDER (`@objc func didToggle(_ sender: UISwitch)`), so calling it with no args
        // would NOT compile (breaking the whole app build). Only lower the wiring when the
        // handler's arity is KNOWN-ZERO; a sender-taking handler (or one whose arity we can't
        // resolve — e.g. inherited / cross-file) DEMOTES (drop the wiring → the control stays
        // native via the slot path, never a non-compiling thunk). `selectorBaseName` already
        // stripped any `(_:)`, so we look the base name up in the collected method arities.
        guard let arity = selectorArities[selectorName] else {
            bail("addTarget selector arity unknown (inherited/cross-file) — demote"); return
        }
        guard arity == 0 else {
            bail("addTarget selector takes a sender arg (thunk replays self.\(selectorName)() with 0 args) — demote"); return
        }
        let actionID = "act_" + Self.stableHash64(viewName + "." + selectorName)
        recordAction(actionID)
        // Record the id→selector wiring so the generated thunk can supply the LIVE native
        // handler (`__actions[id] = { [self] in self.<selector>() }`). Without this the
        // lowered control's action id never reaches a handler and the control is dead on
        // device. De-dup identical wirings (a method walked twice via helper inlining).
        if !actionWirings.contains(where: { $0.id == actionID }) {
            actionWirings.append(.init(id: actionID, selector: selectorName))
        }
        // Attach the action to the view's leaf payload (button → action; switch/slider/
        // field → their event), so the emitted node carries the wire-up id.
        attachEvent(viewName: viewName, actionID: actionID)
    }

    // MARK: - Lever 1: addGestureRecognizer (view-attached effect replay)

    /// The gesture-recognizer constructors whose `target:`/`action:` wiring we replay
    /// natively. A gesture of a TYPE outside this set demotes (faithful — we only replay a
    /// known tap/pan/long-press/swipe/pinch/rotation/screen-edge form).
    static let gestureRecognizerTypes: Set<String> = [
        "UITapGestureRecognizer", "UIPanGestureRecognizer", "UILongPressGestureRecognizer",
        "UISwipeGestureRecognizer", "UIPinchGestureRecognizer", "UIRotationGestureRecognizer",
        "UIScreenEdgePanGestureRecognizer",
    ]

    /// `someView.addGestureRecognizer(UITapGestureRecognizer(target: self, action:
    /// #selector(handleTap)))`. Recognized only when ALL hold (else bail / demote):
    ///   * `someView` is a KNOWN constructed view (so it appears in the rendered tree as
    ///     `.id(viewName)` — the SDK applies the gesture to that node's view),
    ///   * the argument is a recognized gesture-recognizer CONSTRUCTOR call,
    ///   * its `target:` is `self`, and its `action:` is a `#selector(...)`.
    /// The gesture's TYPE + selector are carried VERBATIM in `source`, so the thunk emits
    /// the exact original wiring (selector resolved natively — no guest-side selector
    /// string). The gesture rides nothing across the boundary; only the wiring id (the
    /// view's node id) + the native replay closure do.
    private mutating func handleAddGestureRecognizer(viewName: String?, call: FunctionCallExprSyntax) {
        guard let viewName, views[viewName] != nil else {
            bail("addGestureRecognizer on unknown view"); return
        }
        guard let arg = call.arguments.first?.expression,
              let gestureCall = Self.unwrapGestureConstruction(arg),
              let callee = gestureCall.calledExpression.as(DeclReferenceExprSyntax.self),
              Self.gestureRecognizerTypes.contains(callee.baseName.text) else {
            bail("addGestureRecognizer of a non-recognized gesture form"); return
        }
        // The gesture's target MUST be `self` and its action MUST be a `#selector(...)`.
        // Anything else (a stored recognizer, a non-self target, a non-selector action,
        // an `addAction`/closure-based form) demotes — we only replay the canonical wiring.
        var targetIsSelf = false
        var hasSelector = false
        for a in gestureCall.arguments {
            switch a.label?.text {
            case "target":
                targetIsSelf = a.expression.trimmedDescription == "self"
            case "action":
                hasSelector = a.expression.trimmedDescription.hasPrefix("#selector(")
            default:
                break
            }
        }
        guard targetIsSelf, hasSelector else {
            bail("addGestureRecognizer target isn't self / action isn't a #selector"); return
        }
        // DEMOTE-SAFE: the `#selector` is replayed from the CROSS-FILE thunk extension, so a
        // `private`/`fileprivate` selector method is unreachable there — demote rather than
        // emit a thunk that won't compile. (Mirrors the slot/token inaccessible-member wall.)
        let selectorName = Self.selectorBaseName(
            gestureCall.arguments.first(where: { $0.label?.text == "action" })?
                .expression.trimmedDescription ?? "")
        guard !inaccessibleNames.contains(selectorName) else {
            bail("addGestureRecognizer selector is private/fileprivate (thunk-unreachable)"); return
        }
        // DEMOTE-SAFE (R2-#93): the WHOLE gesture construction is replayed VERBATIM in the
        // cross-file thunk, so EVERY identifier it names (not just the selector) must be
        // thunk-reachable — no method-local `let` (`threshold: localThreshold`), no
        // `private`/`fileprivate` member, no marshalled model field. The selector check above
        // is necessary-but-not-sufficient; scan the full construction expr (the same
        // reachability gate slot closures / quarantine use).
        guard isGestureSourceThunkReachable(ExprSyntax(gestureCall), attachedView: viewName) else {
            bail("addGestureRecognizer construction references a thunk-unreachable name — demote"); return
        }
        // Record the VERBATIM gesture construction keyed to the view's node id. The thunk
        // replays `v.addGestureRecognizer(<source>)` natively.
        gestureWirings.append(.init(viewNodeID: viewName,
                                    source: gestureCall.trimmedDescription))
    }

    /// Peel a gesture-recognizer construction out of the `addGestureRecognizer` argument.
    /// The common form is a bare constructor (`UITapGestureRecognizer(target:action:)`); a
    /// trailing optional-chain or `as`-cast isn't the canonical shape we replay (demote).
    static func unwrapGestureConstruction(_ expr: ExprSyntax) -> FunctionCallExprSyntax? {
        expr.as(FunctionCallExprSyntax.self)
    }

    /// Whether a gesture/observer construction expr (replayed VERBATIM in the cross-file
    /// thunk) references ONLY thunk-reachable identifiers (R2-#93): no method-LOCAL binding
    /// (minus the stored-view names, which ARE `self` members), no `private`/`fileprivate`
    /// member, no marshalled model field. `attachedView` (the gesture's host view) is the one
    /// local name that legitimately appears at the call site but NOT inside the construction
    /// expr — it isn't part of `expr`, so it needs no special exclusion here. The `#selector`
    /// method name is checked separately (and a `#selector` rides natively), so a non-private
    /// selector name in the blocked set can't arise.
    func isGestureSourceThunkReachable(_ expr: ExprSyntax, attachedView: String?) -> Bool {
        let methodLocals = localNames.subtracting(storedViewNames)
        var blocked = methodLocals.union(inaccessibleNames).union(marshalledInputNames())
        if let attachedView { blocked.remove(attachedView) }
        guard !blocked.isEmpty else { return true }
        return !ReferencedNameScanner.referencesAny(expr, of: blocked)
    }

    // MARK: - Lever 2: NotificationCenter.addObserver (method-level effect replay)

    /// Is `expr` a `NotificationCenter` receiver — `NotificationCenter.default` or the bare
    /// `.default` (when the type is inferred)? We replay the observer wiring only for the
    /// canonical `NotificationCenter.default` receiver. A custom/stored center reference
    /// also resolves here when written as `NotificationCenter.default`; anything else
    /// (`myCenter.addObserver`) is not recognized and demotes via the call switch's default.
    static func isNotificationCenterReceiver(_ expr: ExprSyntax) -> Bool {
        let desc = expr.trimmedDescription
        return desc == "NotificationCenter.default" || desc == "NotificationCenter.`default`"
    }

    /// `NotificationCenter.default.addObserver(self, selector: #selector(onKeyboard(_:)),
    /// name: …, object: …)`. Recognized ONLY for this canonical selector-based shape:
    ///   * the FIRST (unlabeled) argument is `self` (the observer target), AND
    ///   * a `selector:` argument is a `#selector(...)`.
    /// The block-based `addObserver(forName:object:queue:using:)` has NO unlabeled-`self`
    /// first arg + NO `selector:` (it takes `forName:`/`using:` a closure) → it fails these
    /// guards and DEMOTES (its closure body is guest-unreconstructable logic). The whole
    /// call is carried VERBATIM in `source` so the thunk re-runs the exact original wiring
    /// (selector + name + object resolved natively).
    private mutating func handleAddObserver(call: FunctionCallExprSyntax) {
        let args = Array(call.arguments)
        // First arg unlabeled `self` (the observer). A block-based addObserver opens with
        // `forName:` (labeled) — so a missing/non-self first unlabeled arg demotes.
        guard let first = args.first, first.label == nil,
              first.expression.trimmedDescription == "self" else {
            bail("addObserver isn't the canonical self+selector shape"); return
        }
        // A `selector:` argument that is a `#selector(...)`.
        guard let sel = args.first(where: { $0.label?.text == "selector" }),
              sel.expression.trimmedDescription.hasPrefix("#selector(") else {
            bail("addObserver without a #selector (block-based form demotes)"); return
        }
        // DEMOTE-SAFE: the `#selector` is replayed from the CROSS-FILE thunk extension, so a
        // `private`/`fileprivate` selector method is unreachable there — demote (faithful)
        // rather than emit a non-compiling thunk.
        let selectorName = Self.selectorBaseName(sel.expression.trimmedDescription)
        guard !inaccessibleNames.contains(selectorName) else {
            bail("addObserver selector is private/fileprivate (thunk-unreachable)"); return
        }
        // DEMOTE-SAFE (R2-#93): the WHOLE addObserver call is replayed VERBATIM in the
        // cross-file thunk, so every identifier it names (`name:`/`object:` args beyond the
        // selector) must be thunk-reachable — no method-local binding, no `private` member,
        // no marshalled model field. (`name: .myNotification` is a global static — fine; a
        // `object: localOwner` referencing a method-local demotes.)
        guard isGestureSourceThunkReachable(ExprSyntax(call), attachedView: nil) else {
            bail("addObserver call references a thunk-unreachable name — demote"); return
        }
        let source = call.trimmedDescription
        let id = "uiobs_" + Self.stableHash64(source)
        // De-dup identical observer registrations (a method walked twice via inlining).
        if !observerEffects.contains(where: { $0.id == id }) {
            observerEffects.append(.init(id: id, source: source))
        }
    }

    private mutating func handleButtonSetter(viewName: String?, method: String,
                                             call: FunctionCallExprSyntax) {
        guard let viewName, views[viewName] != nil else {
            bail("\(method) on unknown view"); return
        }
        // R2-#30/#92: a `setTitle`/`setTitleColor` folds into the button's prop block, which
        // applies UNCONDITIONALLY in the static tree. Record the active visibility context so
        // the subset gate (`emit()`) can demote a conditional setter on a button NOT gated on
        // the same condition — mirror the assignment paths' `recordPropContext`.
        recordPropContext(viewName)
        switch method {
        case "setTitle":
            // `btn.setTitle("X", for: .normal)` — only the `.normal` state lowers.
            guard Self.isNormalState(call) else { bail("setTitle for non-.normal state"); return }
            if let v = call.arguments.first?.expression, let lit = stringValue(v) {
                views[viewName]?.props.buttonTitle = lit
            } else { bail("setTitle with non-literal/non-input title") }
        case "setTitleColor":
            guard Self.isNormalState(call) else { bail("setTitleColor non-.normal"); return }
            if let v = call.arguments.first?.expression, let c = colorValueOrToken(v) {
                views[viewName]?.props.buttonTitleColor = c
            } else { bail("setTitleColor with unmodelable color") }
        default:
            // setImage/setBackgroundImage — not modeled on a button leaf; demote.
            bail("\(method) not modeled")
        }
    }

    /// Is `addSubview`'s receiver the container's CONTENT ROOT? A cell roots at
    /// `contentView`; a programmatic VC roots at its own root `view`. (`self.view` /
    /// `self.contentView` are the qualified forms.)
    static func isContentRootParent(name: String?, expr: ExprSyntax,
                                    kind: UIKitCellLowering.ContainerKind) -> Bool {
        switch kind {
        case .cell:
            return name == "contentView" || expr.trimmedDescription == "self.contentView"
        case .viewController:
            // The VC's root view (`view` / `self.view`). A `UIView` subclass building
            // into `self` is handled by the bare-`self` add below.
            return name == "view" || expr.trimmedDescription == "self.view"
                || expr.trimmedDescription == "self"
        }
    }

    // MARK: - Root-view receiver recognition (Lever A)

    /// The bare DeclReference name of a property-set RECEIVER (`view`, `self`,
    /// `contentView`, a local view name), or nil for a deeper member chain.
    static func receiverName(_ expr: ExprSyntax) -> String? {
        expr.as(DeclReferenceExprSyntax.self)?.baseName.text
    }

    /// Is `expr` the CONTENT-ROOT host VIEW itself — `view`/`self.view`/`self` (VC),
    /// `contentView`/`self.contentView` (cell) — the target of a root property set
    /// (`view.backgroundColor = …`)? Distinct from `isContentRootParent`, which also
    /// accepts `self` as an add target; here `self` is a root receiver too.
    static func isRootReceiver(_ expr: ExprSyntax, kind: UIKitCellLowering.ContainerKind) -> Bool {
        let desc = expr.trimmedDescription
        switch kind {
        case .cell:
            return desc == "contentView" || desc == "self.contentView"
        case .viewController:
            return desc == "view" || desc == "self.view" || desc == "self"
        }
    }

    /// Is `expr` the ROOT's `.layer` — bare `layer`, `self.layer`, `view.layer`,
    /// `self.view.layer`, `contentView.layer` — so a `<that>.cornerRadius = …` is a ROOT
    /// layer property? (`v.layer` for a LOCAL view `v` is handled by the local-view layer
    /// path, which runs first via the known-view guard.)
    static func isRootLayerReceiver(_ expr: ExprSyntax, kind: UIKitCellLowering.ContainerKind) -> Bool {
        // Bare `layer` (implicit self).
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text == "layer" && kind == .viewController
        }
        guard let m = expr.as(MemberAccessExprSyntax.self), m.declName.baseName.text == "layer",
              let base = m.base else { return false }
        return isRootReceiver(base, kind: kind)
    }

    // MARK: - Helper inlining (a same-class no-arg `setupViews()` whose body is
    // itself the recognized grammar). Conservative: only no-arg, body recognized.

    private mutating func inlineHelperCall(_ name: String) {
        guard let stmts = inlineHelpers[name] else {
            bail("call to non-inlinable helper `\(name)()`"); return
        }
        guard inliningSet.insert(name).inserted else { bail("recursive helper `\(name)`"); return }
        defer { inliningSet.remove(name) }
        walkInline(stmts)
    }

    // MARK: - Backing storage shims (the machine's mutable state lives in the
    // base struct; these computed accessors let the extension mutate it cleanly).

    // (Defined in UIKitEmitterState.swift to keep the stored properties in one place.)
}
