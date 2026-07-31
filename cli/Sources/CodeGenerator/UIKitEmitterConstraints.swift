// SPDX-License-Identifier: Apache-2.0

// UIKitEmitterConstraints.swift — parse the Auto Layout anchor grammar into the
// shared `IRConstraint` and attach it to the owning view's build.
// =============================================================================
// Recognizes the common `NSLayoutConstraint` anchor DSL, the form inside an
// `NSLayoutConstraint.activate([ … ])` array or a `… .isActive = true`:
//
//   first.<anchor>Anchor.constraint(equalTo: second.<anchor>Anchor,
//                                   multiplier: m, constant: c)
//   first.<dim>Anchor.constraint(equalToConstant: c)
//   first.<dim>Anchor.constraint(greaterThanOrEqualTo: …)         (and lessThanOrEqual)
//   …optionally chained `.constraint(…)` with a trailing `.priority`-mutation we
//    DON'T parse (a `let c = …; c.priority = .defaultHigh; c.isActive = true` split
//    isn't the flat grammar — demote). A single `.constraint(...)` with an optional
//    leading-dot priority via the rarely-used initializer isn't modeled either.
//
// The constraint's FIRST side names the owning view (the one we attach it to). The
// SECOND side resolves to an `IRAnchorTarget`:
//   * the owning view's parent stack/container → `.superview`,
//   * `contentView` / `self.contentView` / `<parent>.safeAreaLayoutGuide` → the
//     content root's frame; we map `contentView` to `.superview` (the cell's
//     content root IS pinned within contentView, which is the renderer's superview),
//     and an explicit `…safeAreaLayoutGuide` to `.safeArea`,
//   * another sibling view → `.sibling(id:)` (its local name is its node id),
//   * the SAME view → `.selfView`.
// A second side we can't resolve to a known view → demote (faithful: don't drop a
// constraint silently).

import SwiftSyntax
import ViewNodeIR

extension UIKitEmitter {

    /// Is `expr` an anchor-DSL constraint expression `<x>.<anchor>Anchor.constraint(...)`
    /// (possibly chained with a trailing `.<call>(...)`)? Used by the var-decl handler to
    /// capture a NAMED constraint binding instead of slotting it as a (broken) view.
    static func isConstraintExpr(_ expr: ExprSyntax) -> Bool {
        var cur = expr
        while let call = cur.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            if member.declName.baseName.text == "constraint" { return true }
            guard let base = member.base else { return false }
            cur = base
        }
        return false
    }

    /// Resolve one constraint expression (an element of `activate([…])` or the base of
    /// a `.isActive = true`) and attach the resulting `IRConstraint` to its owning
    /// view's build. Demotes on any unrecognized shape.
    mutating func resolveConstraintExpr(_ expr: ExprSyntax) {
        // A BARE reference to a NAMED constraint binding (`c` from
        // `let c = title.topAnchor.constraint(...)`) → resolve its captured expression,
        // carrying any priority set on it before activation.
        if let ref = expr.as(DeclReferenceExprSyntax.self),
           let captured = constraintVars[ref.baseName.text] {
            resolveConstraint(captured.expr, priorityOverride: captured.priority)
            return
        }
        resolveConstraint(expr, priorityOverride: nil)
    }

    /// The core constraint resolver (shared by the inline + named-binding paths). An
    /// optional `priorityOverride` (from a named constraint's `.priority = …`) is applied.
    mutating func resolveConstraint(_ expr: ExprSyntax, priorityOverride: Double?) {
        // The expression is `<first.anchor>.constraint(...)` — peel the trailing
        // `.constraint(...)` call.
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let constraintMember = call.calledExpression.as(MemberAccessExprSyntax.self),
              constraintMember.declName.baseName.text == "constraint",
              let firstAnchorExpr = constraintMember.base else {
            bail("unrecognized constraint expression: \(expr.trimmedDescription)"); return
        }
        // FIRST side: `<view>.<anchor>Anchor`.
        guard let (firstView, firstAnchor) = Self.anchorParts(firstAnchorExpr),
              views[firstView] != nil else {
            bail("constraint first side not a known view anchor: \(firstAnchorExpr.trimmedDescription)"); return
        }

        var relation: IRConstraintRelation = .eq
        var second: IRAnchorRef? = nil
        var multiplier = 1.0
        var multiplierExpr: String? = nil
        var constant = 0.0
        var constantExpr: String? = nil
        var priority: Double? = priorityOverride
        var sawSecond = false

        for arg in call.arguments {
            switch arg.label?.text {
            case "equalTo", "equalToConstant":
                relation = .eq
                if arg.label?.text == "equalToConstant" {
                    // A constant dimension. A foldable literal/namespace constant stays
                    // the established path; a cross-file/computed design constant
                    // (`TPMenuUX.UX.viewCornerRadius`) host-tokenizes (the guest reads it
                    // from the merged model JSON). Neither → demote.
                    if let c = resolveDouble(arg.expression) { constant = c }
                    else if let g = numericValueOrToken(arg.expression) { constantExpr = g }
                    else { bail("non-literal equalToConstant"); return }
                    sawSecond = true                 // a constant dimension: second stays nil
                } else if let ref = secondRef(arg.expression, firstView: firstView) {
                    second = ref; sawSecond = true
                } else { bail("equalTo target not a known anchor: \(arg.expression.trimmedDescription)"); return }
            case "greaterThanOrEqualTo", "greaterThanOrEqualToConstant":
                relation = .ge
                if arg.label?.text == "greaterThanOrEqualToConstant" {
                    if let c = resolveDouble(arg.expression) { constant = c }
                    else if let g = numericValueOrToken(arg.expression) { constantExpr = g }
                    else { bail("non-literal ge constant"); return }
                    sawSecond = true
                } else if let ref = secondRef(arg.expression, firstView: firstView) {
                    second = ref; sawSecond = true
                } else { bail("ge target not a known anchor"); return }
            case "lessThanOrEqualTo", "lessThanOrEqualToConstant":
                relation = .le
                if arg.label?.text == "lessThanOrEqualToConstant" {
                    if let c = resolveDouble(arg.expression) { constant = c }
                    else if let g = numericValueOrToken(arg.expression) { constantExpr = g }
                    else { bail("non-literal le constant"); return }
                    sawSecond = true
                } else if let ref = secondRef(arg.expression, firstView: firstView) {
                    second = ref; sawSecond = true
                } else { bail("le target not a known anchor"); return }
            case "multiplier":
                if let m = resolveDouble(arg.expression) { multiplier = m }
                else if let g = numericValueOrToken(arg.expression) { multiplierExpr = g }
                else { bail("non-literal multiplier"); return }
            case "constant":
                if let c = resolveDouble(arg.expression) { constant = c }
                else if let g = numericValueOrToken(arg.expression) { constantExpr = g }
                else { bail("non-literal constant"); return }
            default:
                bail("unrecognized constraint arg `\(arg.label?.text ?? "?")`"); return
            }
        }
        guard sawSecond else { bail("constraint missing a relation arg"); return }

        // An OUTER `.constraint(...).priority(...)`-style wrap or trailing
        // `.withPriority`/`.priority` chained call isn't this `call` (it would wrap it);
        // the outer chain is handled by `resolveConstraintExprWithChain`. Here `call` is
        // the bare `.constraint(...)`. Attach. A NUMERIC token (`constantExpr`/
        // `multiplierExpr`) rides as a guest expression; the folded `constant`/`multiplier`
        // stays the IRConstraint default (the guest builder takes the expr arg).
        let c = IRConstraint(first: firstAnchor, relation: relation, second: second,
                             multiplier: multiplier, constant: constant, priority: priority)
        views[firstView]?.constraints.append(
            UIKitEmitter.ConstraintBuild(base: c, constantExpr: constantExpr,
                                         multiplierExpr: multiplierExpr))
    }

    /// Decompose `<view>.<anchor>Anchor` → (viewName, IRAnchor). The anchor token is
    /// the member name with the `Anchor` suffix dropped (`leadingAnchor` → `.leading`).
    /// Returns nil if it isn't a `<DeclRef>.<…>Anchor` shape we map.
    static func anchorParts(_ expr: ExprSyntax) -> (view: String, anchor: IRAnchor)? {
        guard let m = expr.as(MemberAccessExprSyntax.self),
              let view = m.base?.as(DeclReferenceExprSyntax.self)?.baseName.text else { return nil }
        let token = m.declName.baseName.text
        guard token.hasSuffix("Anchor") else { return nil }
        let anchorName = String(token.dropLast("Anchor".count))
        guard let anchor = mapAnchor(anchorName) else { return nil }
        return (view, anchor)
    }

    static func mapAnchor(_ name: String) -> IRAnchor? {
        switch name {
        case "leading": return .leading
        case "trailing": return .trailing
        case "top": return .top
        case "bottom": return .bottom
        case "left": return .left
        case "right": return .right
        case "width": return .width
        case "height": return .height
        case "centerX": return .centerX
        case "centerY": return .centerY
        case "firstBaseline": return .firstBaseline
        case "lastBaseline": return .lastBaseline
        default: return nil
        }
    }

    /// The container's CONTENT-ROOT host-view name(s): `contentView` for a cell, `view`
    /// for a VC. A constraint pinned to it resolves to `.superview`.
    static func isContentRootHostName(_ name: String, kind: UIKitCellLowering.ContainerKind) -> Bool {
        switch kind {
        case .cell: return name == "contentView"
        case .viewController: return name == "view"
        }
    }

    /// Resolve the SECOND side of a constraint (`avatar.trailingAnchor`,
    /// `contentView.topAnchor`, `view.topAnchor`, `topAnchor` (a UIView-subclass's own
    /// anchor), `contentView.safeAreaLayoutGuide.topAnchor`) to an `IRAnchorRef`.
    /// Returns nil if the target view isn't known.
    mutating func secondRef(_ expr: ExprSyntax, firstView: String) -> IRAnchorRef? {
        // A BARE anchor (`topAnchor`, no receiver) in a `UIView` subclass building into
        // ITSELF denotes the view's own (superview) anchor → `.superview`.
        if containerKind == .viewController,
           let ref = expr.as(DeclReferenceExprSyntax.self) {
            let token = ref.baseName.text
            if token.hasSuffix("Anchor"),
               let anchor = Self.mapAnchor(String(token.dropLast("Anchor".count))) {
                return IRAnchorRef(target: .superview, anchor: anchor)
            }
        }
        guard let m = expr.as(MemberAccessExprSyntax.self) else { return nil }
        let token = m.declName.baseName.text
        guard token.hasSuffix("Anchor") else { return nil }
        guard let anchor = Self.mapAnchor(String(token.dropLast("Anchor".count))) else { return nil }

        // The base is the target: a bare view name, `contentView`, `self.contentView`,
        // `view`/`self.view`, `self`, a `safeAreaLayoutGuide`/`layoutMarginsGuide` (bare
        // or `<x>.`-qualified).
        guard let base = m.base else { return nil }

        // `<x>.safeAreaLayoutGuide` → .safeArea (the content root's superview's safe area).
        // `<x>.layoutMarginsGuide` we treat as .superview (close enough; an explicit margin
        // offset rides in `constant`).
        if let guideMember = base.as(MemberAccessExprSyntax.self) {
            let guideName = guideMember.declName.baseName.text
            if guideName == "safeAreaLayoutGuide" { return IRAnchorRef(target: .safeArea, anchor: anchor) }
            if guideName == "layoutMarginsGuide" { return IRAnchorRef(target: .superview, anchor: anchor) }
            // `self.contentView` (cell) / `self.view` (VC) → the content root's superview.
            if Self.isContentRootHostName(guideName, kind: containerKind) {
                return IRAnchorRef(target: .superview, anchor: anchor)
            }
            return nil
        }

        let baseName = base.as(DeclReferenceExprSyntax.self)?.baseName.text
        guard let baseName else { return nil }
        // A BARE `safeAreaLayoutGuide` / `layoutMarginsGuide` (implicit self) in a UIView/VC
        // subclass building into `self` (Lever C — `safeAreaLayoutGuide.topAnchor`).
        if containerKind == .viewController {
            if baseName == "safeAreaLayoutGuide" { return IRAnchorRef(target: .safeArea, anchor: anchor) }
            if baseName == "layoutMarginsGuide" { return IRAnchorRef(target: .superview, anchor: anchor) }
            // `self.topAnchor` — the root's own (superview) anchor.
            if baseName == "self" { return IRAnchorRef(target: .superview, anchor: anchor) }
        }
        // The container's CONTENT-ROOT host view (`contentView` for a cell, `view` for a
        // VC) → the content root's superview (the renderer pins our root within it).
        if Self.isContentRootHostName(baseName, kind: containerKind) {
            return IRAnchorRef(target: .superview, anchor: anchor)
        }
        // The SAME view → .selfView (e.g. `v.widthAnchor == 2 * v.heightAnchor`).
        if baseName == firstView { return IRAnchorRef(target: .selfView, anchor: anchor) }
        // Another known view → a sibling reference by its node id (its local name).
        if views[baseName] != nil { return IRAnchorRef(target: .sibling(id: baseName), anchor: anchor) }
        // The first view's PARENT (an enclosing stack/container) → .superview. We don't
        // track upward parent pointers by name here; the common pin-to-parent uses
        // `contentView`. A pin to a named parent that ISN'T contentView is unknown.
        return nil
    }

    // MARK: - Emit one constraint as a `UI.` chain call

    /// The chainable builder call for a `ConstraintBuild`: `pin(...)` for a related
    /// constraint, `size(...)` for a constant dimension. Mirrors the `UI.*` sugar. A
    /// numeric design-system TOKEN rides as a guest EXPRESSION (`constantExpr`/
    /// `multiplierExpr` = `__numtok_<id>`) in the `constant:`/`multiplier:` position
    /// instead of the folded literal; the guest builder evaluates it at WASM run time, so
    /// the resulting `IRConstraint` still carries a plain `Double` — zero wire change.
    static func constraintCall(_ cb: ConstraintBuild) -> String {
        let c = cb.base
        // The emitted constant/multiplier text: a host-token EXPRESSION wins; else the
        // folded literal.
        let constantText = cb.constantExpr ?? numLit(c.constant)
        let multiplierText = cb.multiplierExpr ?? numLit(c.multiplier)
        guard let second = c.second else {
            // Constant dimension: `size(.width, 40, relation:)`.
            var s = "size(.\(c.first.rawValue), \(constantText)"
            if c.relation != .eq { s += ", relation: .\(c.relation.rawValue)" }
            if let p = c.priority { s += ", priority: \(numLit(p))" }
            return s + ")"
        }
        // Related: `pin(.leading, to: .trailing, of: <target>, …)`.
        var s = "pin(.\(c.first.rawValue), to: .\(second.anchor.rawValue), of: \(targetExpr(second.target))"
        if c.relation != .eq { s += ", relation: .\(c.relation.rawValue)" }
        // Emit a non-default multiplier/constant. A TOKEN expression is always emitted
        // (it isn't foldable to compare against the default); a folded literal is emitted
        // only when non-default (the established byte-identical path).
        if cb.multiplierExpr != nil || c.multiplier != 1 { s += ", multiplier: \(multiplierText)" }
        if cb.constantExpr != nil || c.constant != 0 { s += ", constant: \(constantText)" }
        if let p = c.priority { s += ", priority: \(numLit(p))" }
        return s + ")"
    }

    static func targetExpr(_ t: IRAnchorTarget) -> String {
        switch t {
        case .superview: return ".superview"
        case .safeArea: return ".safeArea"
        case .selfView: return ".selfView"
        case .sibling(let id): return ".sibling(id: \"\(id)\")"
        }
    }
}
