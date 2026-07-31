// SPDX-License-Identifier: Apache-2.0

// UIKitEmitterConditions.swift — guest-evaluable BOOLEAN conditions + CONDITIONAL
// (ternary / `if`-driven) values for the UIKit construction lowering.
// =============================================================================
// Model-driven conditional construction is the single biggest UIKit "milk-more"
// bucket (see docs/UIKIT-COVERAGE.md §C / Lever 1). UIKit is imperative, so an
// arbitrary `if` mutating shared view state is NOT faithfully capturable as a
// static tree. But the COMMON, clean subset IS, and it maps onto the existing
// static `UIKitNode` tree with ZERO new IR — by evaluating the condition IN-GUEST
// from the marshalled model:
//
//   1. CONDITIONAL VALUES — a ternary RHS in a property set:
//        `label.textColor = isError ? .systemRed : .label`
//        `label.text       = isVIP ? "VIP" : name`
//        `view.alpha       = enabled ? 1.0 : 0.5`
//      lowers to a guest ternary over the bound input var. The guest is REAL Swift
//      running in WASM, so `(isError ? ColorRef.named("red") : ColorRef.named("label"))`
//      evaluates correctly per-row. Both arms must themselves lower; the condition
//      must be a guest-evaluable boolean over marshalled inputs.
//
//   2. CONDITIONAL VISIBILITY — `if cond { parent.addArrangedSubview(child) }`:
//      the child lowers normally but is gated with a guest-evaluated `.hidden(!cond)`
//      (a hidden arranged-subview collapses in a UIStackView; a hidden child in a
//      plain container just doesn't paint). This is faithful for the dominant
//      "show this badge only when premium" pattern and needs no new IR.
//
// A condition leaf that ISN'T a marshalled input (a `self.private` read, a trait/
// geometry query like `traitCollection.userInterfaceStyle`, an arbitrary call) makes
// the condition non-guest-evaluable → the form demotes (honest: never a wrong
// branch). This mirrors SwiftUI's model-driven-`if` vs trait-driven-`if` split.

import SwiftSyntax
import ViewNodeIR

extension UIKitEmitter {

    // MARK: - Guest-evaluable boolean conditions

    /// Translate a Swift boolean condition expression to a guest boolean expression
    /// over the marshalled input vars (the same flat names the guest binds), or nil if
    /// ANY leaf isn't a marshalled input (→ the caller demotes the conditional form).
    ///
    /// Recognized:
    ///   * a bool input read          — `isPremium`, `model.isPremium`,
    ///   * its negation               — `!isPremium`,
    ///   * a scalar comparison        — `count > 0`, `model.count == 3`, `pct <= 1`,
    ///   * boolean composition        — `a && b`, `a || b`, `(a)`, and nested forms,
    ///   * a string equality          — `tier == "vip"` (a String input vs a literal).
    /// The produced text references the bound input vars verbatim (`count > 0`), so it
    /// evaluates natively in the WASM guest against the decoded model.
    mutating func guestBoolCondition(_ expr: ExprSyntax) -> String? {
        // Parenthesized: `(cond)`.
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression {
            guard let g = guestBoolCondition(inner) else { return nil }
            return "(\(g))"
        }
        // Negation: `!cond`.
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
            guard let g = guestBoolCondition(prefix.expression) else { return nil }
            return "!(\(g))"
        }
        // A bare bool input read (`isPremium` / `model.isPremium`).
        if let g = boolInputRead(expr) { return g }
        // A folded infix (`count > 0`, `a && b`) — SwiftParser hands a folded tree when
        // operators are already resolved.
        if let folded = Self.foldedInfix(expr) {
            return guestInfix(lhs: folded.lhs, op: folded.op, rhs: folded.rhs)
        }
        // An UNFOLDED multi-element sequence (`a == b && c`): split on the lowest-
        // precedence boolean operator (`||` then `&&`) and recurse; the remaining
        // comparison sub-sequence is itself re-decoded.
        if let seq = expr.as(SequenceExprSyntax.self) {
            return guestSequence(Array(seq.elements))
        }
        return nil
    }

    /// Translate an unfolded operator sequence (e.g. `model.tier == "vip" && model.active`,
    /// flattened to `[tier, ==, "vip", &&, active]`) into a guest boolean. Splits on the
    /// LOWEST-precedence boolean operator first (`||`, then `&&`), recursing on each side;
    /// a side with no boolean operator is a single comparison/leaf decoded directly.
    private mutating func guestSequence(_ elems: [ExprSyntax]) -> String? {
        // Find the LAST top-level `||` (lowest precedence, left-assoc → split at last).
        for op in ["||", "&&"] {
            for i in stride(from: elems.count - 1, through: 1, by: -1) {
                if let b = elems[i].as(BinaryOperatorExprSyntax.self), b.operator.text == op {
                    let lhs = Array(elems[0..<i])
                    let rhs = Array(elems[(i + 1)...])
                    guard !lhs.isEmpty, !rhs.isEmpty,
                          let l = guestSubsequence(lhs), let r = guestSubsequence(rhs) else { return nil }
                    return "\(l) \(op) \(r)"
                }
            }
        }
        // No boolean operator at this level → a single comparison/leaf.
        return guestSubsequence(elems)
    }

    /// Decode a sub-sequence (no top-level `||`/`&&`) as a guest boolean: a 3-element
    /// comparison (`a == b`), or a single leaf (a bool input / parenthesized condition).
    private mutating func guestSubsequence(_ elems: [ExprSyntax]) -> String? {
        if elems.count == 1 { return guestBoolCondition(elems[0]) }
        if elems.count == 3, let b = elems[1].as(BinaryOperatorExprSyntax.self) {
            return guestInfix(lhs: elems[0], op: b.operator.text, rhs: elems[2])
        }
        // A longer non-boolean sub-sequence (arithmetic in a comparand, etc.) isn't a
        // guest boolean we model — demote (no recursion: don't re-wrap the same elems).
        return nil
    }

    /// A bound BOOL input read → its guest var name (the flat name). nil otherwise.
    private mutating func boolInputRead(_ expr: ExprSyntax) -> String? {
        let raw = expr.trimmedDescription
        if let inp = inputs.first(where: { ($0.name == raw || Self.flatInputName($0.name) == raw) && $0.kind == .bool }) {
            referencedInputs.insert(inp.name)
            return Self.flatInputName(inp.name)
        }
        return nil
    }

    /// A guest expression for one infix condition node. The operator text is preserved
    /// verbatim (Swift's `>`/`>=`/`==`/`&&`/… are all valid in the guest); the operands
    /// must each be guest-evaluable (a scalar input read / literal, or a sub-condition).
    private mutating func guestInfix(lhs: ExprSyntax, op: String, rhs: ExprSyntax) -> String? {
        switch op {
        case "&&", "||":
            guard let l = guestBoolCondition(lhs), let r = guestBoolCondition(rhs) else { return nil }
            return "\(l) \(op) \(r)"
        case "==", "!=", "<", "<=", ">", ">=":
            guard let l = guestScalarOperand(lhs), let r = guestScalarOperand(rhs) else { return nil }
            return "\(l) \(op) \(r)"
        default:
            return nil
        }
    }

    /// A guest scalar operand for a comparison: a numeric/string input read, a numeric
    /// literal, or a string literal. nil if it isn't guest-evaluable.
    private mutating func guestScalarOperand(_ expr: ExprSyntax) -> String? {
        // A marshalled scalar input (Int/Double/String/Bool).
        let raw = expr.trimmedDescription
        if let inp = inputs.first(where: { $0.name == raw || Self.flatInputName($0.name) == raw }) {
            switch inp.kind {
            case .int, .double, .string, .bool:
                referencedInputs.insert(inp.name)
                return Self.flatInputName(inp.name)
            default: return nil
            }
        }
        // A numeric literal (`0`, `3`, `1.0`, `-2`).
        if let d = Self.doubleLiteral(expr) { return Self.numLit(d) }
        // A string literal (`"vip"`).
        if let s = Self.plainStringLiteral(expr) { return "\"\(Self.escape(s))\"" }
        return nil
    }

    /// Decompose an infix expression (`a > b`, `x && y`) from either a folded
    /// `InfixOperatorExprSyntax` or an unfolded `SequenceExprSyntax` of 3 elements.
    static func foldedInfix(_ expr: ExprSyntax) -> (lhs: ExprSyntax, op: String, rhs: ExprSyntax)? {
        if let infix = expr.as(InfixOperatorExprSyntax.self),
           let opExpr = infix.operator.as(BinaryOperatorExprSyntax.self) {
            return (infix.leftOperand, opExpr.operator.text, infix.rightOperand)
        }
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            if elems.count == 3, let opExpr = elems[1].as(BinaryOperatorExprSyntax.self) {
                return (elems[0], opExpr.operator.text, elems[2])
            }
        }
        return nil
    }

    // MARK: - Conditional (ternary) value RHS

    /// Decompose a ternary `cond ? a : b` from either a folded `TernaryExprSyntax` or an
    /// unfolded `SequenceExprSyntax` (`cond ? a : b` parses as a sequence with an
    /// `UnresolvedTernaryExprSyntax` middle when not operator-folded).
    static func asTernary(_ expr: ExprSyntax) -> (cond: ExprSyntax, then: ExprSyntax, els: ExprSyntax)? {
        if let t = expr.as(TernaryExprSyntax.self) {
            return (t.condition, t.thenExpression, t.elseExpression)
        }
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            // `cond  <UnresolvedTernary then>  else`
            if elems.count == 3, let mid = elems[1].as(UnresolvedTernaryExprSyntax.self) {
                return (elems[0], mid.thenExpression, elems[2])
            }
        }
        return nil
    }

    /// Lower a ternary RHS by lowering each arm with `armLower` and gluing the guest
    /// condition: `(<cond> ? <thenGuest> : <elseGuest>)`. Returns nil if the condition
    /// isn't guest-evaluable or either arm fails to lower (→ demote, never a wrong arm).
    mutating func ternaryGuest(_ expr: ExprSyntax,
                               _ armLower: (inout UIKitEmitter, ExprSyntax) -> String?) -> String? {
        guard let tern = Self.asTernary(expr) else { return nil }
        guard let cond = guestBoolCondition(tern.cond) else { return nil }
        guard let thenG = armLower(&self, tern.then) else { return nil }
        guard let elseG = armLower(&self, tern.els) else { return nil }
        return "(\(cond) ? \(thenG) : \(elseG))"
    }

    // MARK: - Ternary-aware value resolvers (instance wrappers over the static literals)

    /// A guest `ColorRef` expression for a property value — a plain color literal, OR a
    /// `cond ? colorA : colorB` ternary over a marshalled condition. nil → demote.
    mutating func colorValue(_ expr: ExprSyntax) -> ColorRefLit? {
        if let c = Self.colorLiteral(expr) { return c }
        if let g = ternaryGuest(expr, { _, arm in Self.colorLiteral(arm)?.guest }) {
            return ColorRefLit(guest: g)
        }
        return nil
    }

    /// A guest `ColorRef` for a property value, EXTENDED with the design-system color
    /// TOKEN channel (Lever D): a literal/ternary (via `colorValue`) wins; otherwise a
    /// custom color expression the guest can't reconstruct but the cross-file thunk CAN
    /// (`SemanticColors.View.backgroundDefault`) lowers as `.hostToken(id)` and records a
    /// token resolver. Returns nil ONLY when neither applies (a token referencing a
    /// body-local / `private` member, or a non-color expression) → the caller demotes.
    mutating func colorValueOrToken(_ expr: ExprSyntax) -> ColorRefLit? {
        if let c = colorValue(expr) { return c }
        if let id = recordColorTokenIfResolvable(expr) {
            return ColorRefLit(guest: ".hostToken(\"\(id)\")")
        }
        return nil
    }

    /// Record a DESIGN-SYSTEM COLOR token for `expr` and return its content-stable id, or
    /// nil if `expr` isn't a build-time-resolvable color token. Eligibility (demote-safe):
    ///   * STRUCTURALLY a plausible color value — a member access (`Palette.brand`,
    ///     `Asset.Colors.x.color`) or a method call whose callee is a member access
    ///     (`UIColor.brand.withAlphaComponent(0.5)`), NOT a bare type/identifier/literal
    ///     (those are handled by the literal path or aren't a token), and
    ///   * the thunk closure `{ <expr> }` must compile in the cross-file extension — so it
    ///     references NO body-local view name and NO `private`/`fileprivate` member.
    /// The id matches the thunk generator's derivation (FNV over the source) so push +
    /// build agree with no shared state.
    mutating func recordColorTokenIfResolvable(_ expr: ExprSyntax) -> String? {
        guard Self.isPlausibleColorTokenExpr(expr) else { return nil }
        let blocked = localNames.union(inaccessibleNames)
        if !blocked.isEmpty, ReferencedNameScanner.referencesAny(expr, of: blocked) {
            return nil
        }
        let source = expr.trimmedDescription
        guard !source.isEmpty else { return nil }
        let id = "uict_" + Self.stableHash64(source)
        if !hostTokens.contains(where: { $0.id == id }) {
            hostTokens.append(.init(id: id, source: source, kind: .color))
        }
        return id
    }

    // MARK: - Design-system NUMERIC token channel (Lever D for numbers)

    /// A guest numeric EXPRESSION for a numeric value position (a constraint
    /// `equalToConstant:`/`constant:`/`multiplier:`, or a numeric property like
    /// `cornerRadius`/`spacing`/`alpha`/slider value), EXTENDED with the design-system
    /// NUMERIC TOKEN channel. Tries, in order:
    ///   1. the existing literal / namespace-constant / ternary path (`doubleValueExpr`)
    ///      — a value already foldable to a guest literal (`8`, `UX.spacing` → `8`, a
    ///      `big ? 12 : 4` over a marshalled bool), and
    ///   2. otherwise a CROSS-FILE-or-computed numeric design constant the guest can't
    ///      fold but the cross-file thunk CAN evaluate natively
    ///      (`TPMenuUX.UX.viewCornerRadius`, `Theme.Radius.card`, `Layout.spacing * 0.5`):
    ///      it lowers as a `.number` host token — a reserved `__numtok_<id>` `.double`
    ///      input is recorded, the guest reads it from the merged model JSON, and the
    ///      thunk's number-token resolver evaluates the REAL constant expression over
    ///      `self` → the `Double` the SDK merges in (mirrors the SwiftUI numeric token).
    /// Returns nil ONLY when neither applies (a token referencing a model field /
    /// body-local / `private` member, or a non-numeric expression) → the caller demotes
    /// (faithful over a wrong dimension).
    mutating func numericValueOrToken(_ expr: ExprSyntax) -> String? {
        if let g = doubleValueExpr(expr) { return g }
        if let id = recordNumericTokenIfResolvable(expr) {
            // The guest reads the natively-resolved value from the merged model JSON.
            let key = BodyLowering.numericTokenInputKey(id)
            recordNumericTokenInput(key: key)
            return key
        }
        return nil
    }

    /// Record a DESIGN-SYSTEM NUMERIC token for `expr` and return its content-stable id,
    /// or nil if `expr` isn't a build-time-resolvable numeric token. Eligibility
    /// (demote-safe, mirrors `recordColorTokenIfResolvable`):
    ///   * STRUCTURALLY a plausible numeric value — a member access (`Theme.Radius.card`,
    ///     `TPMenuUX.UX.viewCornerRadius`), a numeric free-fn/cast call (`min(a,b)`,
    ///     `CGFloat(x)`), a binary-arithmetic / force-unwrap / ternary of plausibles —
    ///     NOT a bare type/identifier (a bare identifier is either a marshalled input
    ///     already folded by the literal path, or a local the thunk can't reach) and NOT
    ///     a literal (the literal path handled those), and
    ///   * the thunk closure `{ Double(<expr>) }` must compile in the cross-file extension
    ///     — so it references NO marshalled model field, NO body-local view name, and NO
    ///     `private`/`fileprivate` member.
    /// The id matches the thunk generator's derivation (FNV over the source) so push +
    /// build agree with no shared state.
    mutating func recordNumericTokenIfResolvable(_ expr: ExprSyntax) -> String? {
        guard Self.isPlausibleNumericTokenExpr(expr) else { return nil }
        // Block any reference to a body-local view name, an inaccessible (`private`)
        // member, OR a marshalled model field: a model-derived numeric must stay on its
        // own (guest-folded) path; a body-local / `private` one can't be reached by the
        // cross-file thunk. (`localNames`/`inaccessibleNames` mirror the color path; the
        // marshalled input names guard against host-resolving a model-driven value.)
        let blocked = localNames.union(inaccessibleNames).union(marshalledInputNames())
        if !blocked.isEmpty, ReferencedNameScanner.referencesAny(expr, of: blocked) {
            return nil
        }
        let source = expr.trimmedDescription
        guard !source.isEmpty else { return nil }
        let id = "uint_" + Self.stableHash64(source)
        if !hostTokens.contains(where: { $0.id == id }) {
            hostTokens.append(.init(id: id, source: source, kind: .number))
        }
        return id
    }

    /// The flat (top-level) names of the cell's MARSHALLED model inputs — used to reject
    /// host-tokenizing a numeric that READS a model field (that value already rides the
    /// model JSON and the guest folds it directly; host-resolving it over `self` in the
    /// thunk would be wrong — the thunk's `self` is the cell, not the row model).
    func marshalledInputNames() -> Set<String> {
        var names: Set<String> = []
        for inp in inputs {
            names.insert(Self.flatInputName(inp.name))      // the guest-read key (`title`)
            // Also the model-qualified name's leaf (`model.title` → `model`, `title`).
            for part in inp.name.split(separator: ".") { names.insert(String(part)) }
        }
        return names
    }

    /// Register a synthetic `.double` input for a numeric host token (`__numtok_<id>`) so
    /// the guest preamble scans it (`_patchScanDouble`) from the model JSON the SDK merges
    /// the resolved value into. Idempotent (a repeated token id adds one input only). The
    /// default is `0` — when the SDK can't supply the token the cell demotes natively
    /// upstream (the host checks every needed token id is provided before installing), so
    /// this default is never the rendered value.
    mutating func recordNumericTokenInput(key: String) {
        guard !inputs.contains(where: { $0.name == key }) else { return }
        inputs.append(BodyLowering.ViewInput(name: key, kind: .double, defaultLiteral: "0"))
    }

    /// Is `expr` STRUCTURALLY a plausible design-system NUMERIC token — a member access
    /// (`Theme.Radius.card`, `TPMenuUX.UX.viewCornerRadius`), a numeric free-function /
    /// cast call (`min(a,b)`, `CGFloat(x)`, `abs(d)`), a binary-arithmetic expression, a
    /// force-unwrap, or a ternary/parenthesized thereof? Rejects a bare identifier/type
    /// ref (a marshalled input or a local — handled / demoted elsewhere), a literal (the
    /// literal path), a leading-dot member (an enum case, not a number), and a
    /// member-access CALL (`Theme.color.withAlpha(…)` — that's the color/font shape).
    static func isPlausibleNumericTokenExpr(_ expr: ExprSyntax) -> Bool {
        // `a.b.c` — a QUALIFIED member-access chain (`Theme.Radius.card`). A LEADING-DOT
        // member (`.large`) is an enum/option case in a numeric position — never a number.
        if let m = expr.as(MemberAccessExprSyntax.self) { return m.base != nil }
        // `min(a,b)` / `CGFloat(x)` / `abs(d)` — a numeric free-fn/cast whose callee is a
        // bare numeric name and whose args are each plausible. A MEMBER-access callee
        // (`Theme.color.withAlpha(…)`) is the color/font shape — reject.
        if let call = expr.as(FunctionCallExprSyntax.self) {
            guard let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
                  Self.numericTokenCallees.contains(callee.baseName.text) else { return false }
            return call.arguments.allSatisfy { isPlausibleNumericTokenExpr($0.expression) }
        }
        // A folded binary-arithmetic expression (`Theme.Radius.card * 0.5`, `a + b`).
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return isPlausibleNumericTokenExpr(infix.leftOperand)
                && isPlausibleNumericTokenExpr(infix.rightOperand)
        }
        // A numeric literal arg INSIDE an arithmetic/call (`* 0.5`, `min(x, 8)`): a bare
        // literal alone never reaches here (the literal path handled it), but as an
        // operand it's plausible.
        if expr.is(IntegerLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self) { return true }
        // `Theme.radius!` — a force-unwrap of a plausible token.
        if let f = expr.as(ForceUnwrapExprSyntax.self) { return isPlausibleNumericTokenExpr(f.expression) }
        // `(expr)` — parenthesized single element.
        if let tup = expr.as(TupleExprSyntax.self), tup.elements.count == 1,
           let only = tup.elements.first, only.label == nil {
            return isPlausibleNumericTokenExpr(only.expression)
        }
        // `(cond ? a : b)` — a ternary whose arms are each plausible.
        if let tern = asTernary(expr) {
            return isPlausibleNumericTokenExpr(tern.then) && isPlausibleNumericTokenExpr(tern.els)
        }
        return false
    }

    /// Free-function / cast callees a numeric token may legitimately be built from
    /// (matches the SwiftUI numeric-token callees).
    static let numericTokenCallees: Set<String> =
        ["min", "max", "abs", "CGFloat", "Double", "Float", "Int"]

    /// Is `expr` STRUCTURALLY a plausible design-system COLOR token — a member access
    /// (`Theme.Colors.ink`), a member-access call (`UIColor.brand.withAlphaComponent(0.5)`,
    /// `Asset.Colors.x.color`), a force-unwrap of one, or a ternary whose arms are each
    /// plausible? Rejects a bare identifier/type ref, a literal, a leading-dot member (a
    /// `.systemBlue` is the literal path, not a token), and anything that ISN'T a color
    /// (a view/struct constructor `SomeView()` — its callee is a bare DeclReference, not a
    /// member access — would be mis-recorded as a color otherwise).
    static func isPlausibleColorTokenExpr(_ expr: ExprSyntax) -> Bool {
        // `a.b.c` — a member-access chain (any base). A LEADING-DOT member (`.whiteAlpha16`)
        // is admitted too: in a color property position it's an implicit-`UIColor` extension
        // static (the literal path already handled the KNOWN system names, so a leading-dot
        // reaching here is a CUSTOM color-extension static the thunk resolves as
        // `(.whiteAlpha16) as UIColor`). It's never an unrelated enum case here — the only
        // callers are color positions (`backgroundColor`/`textColor`/`tintColor`/title).
        if expr.as(MemberAccessExprSyntax.self) != nil { return true }
        // `Foo.bar(...)` / `x.y.withAlphaComponent(0.5)` — a call whose callee is a member
        // access (a method on a namespace/value). A bare-DeclReference callee (`Foo()`) is
        // a constructor — reject (it isn't a color token).
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return call.calledExpression.as(MemberAccessExprSyntax.self) != nil
        }
        // `Theme.color!` — a force-unwrap of a plausible token.
        if let f = expr.as(ForceUnwrapExprSyntax.self) { return isPlausibleColorTokenExpr(f.expression) }
        // `(cond ? a : b)` — a ternary whose arms are each plausible.
        if let tern = asTernary(expr) {
            return isPlausibleColorTokenExpr(tern.then) && isPlausibleColorTokenExpr(tern.els)
        }
        return false
    }

    /// A guest `IRFont` expression for a font value — a plain font literal OR a ternary.
    mutating func fontValue(_ expr: ExprSyntax) -> FontLit? {
        if let f = Self.fontLiteral(expr) { return f }
        if let g = ternaryGuest(expr, { _, arm in Self.fontLiteral(arm)?.guest }) {
            return FontLit(guest: g)
        }
        return nil
    }

    /// A guest `Double` expression for a numeric value — a plain numeric literal, a
    /// resolved numeric NAMESPACE CONSTANT (`UX.spacing`, Lever B), OR a ternary
    /// (`enabled ? 1.0 : 0.5`). Returns a guest STRING (so a ternary can ride); numeric
    /// props store this as the emitted text, not a folded `Double`.
    mutating func doubleValueExpr(_ expr: ExprSyntax) -> String? {
        if let d = resolveDouble(expr) { return Self.numLit(d) }
        if let g = ternaryGuest(expr, { e, arm in e.resolveDouble(arm).map(Self.numLit) }) {
            return g
        }
        return nil
    }

    /// A guest `Int` expression for an integer value — a plain int literal, a resolved
    /// integral namespace constant, OR a ternary.
    mutating func intValueExpr(_ expr: ExprSyntax) -> String? {
        if let i = resolveInt(expr) { return String(i) }
        if let g = ternaryGuest(expr, { e, arm in e.resolveInt(arm).map(String.init) }) {
            return g
        }
        return nil
    }

    /// A guest `Bool` expression for a boolean value — a plain bool literal, a resolved
    /// bool namespace constant, OR a ternary.
    mutating func boolValueExpr(_ expr: ExprSyntax) -> String? {
        if let b = resolveBool(expr) { return b ? "true" : "false" }
        if let g = ternaryGuest(expr, { e, arm in e.resolveBool(arm).map { $0 ? "true" : "false" } }) {
            return g
        }
        return nil
    }

    /// A guest `String` expression for a text/title value — a string literal / input
    /// read / interpolation (via `literalString`) OR a ternary whose arms are each such.
    mutating func stringValue(_ expr: ExprSyntax) -> ExprLit? {
        if let lit = literalString(expr) { return lit }
        if let g = ternaryGuest(expr, { e, arm in e.literalString(arm)?.guest }) {
            return ExprLit(guest: g)
        }
        return nil
    }

    // MARK: - Model-driven conditional construction (`if cond { … } else { … }`)

    /// Lower a standalone `if cond { … } [else { … }]` whose condition is guest-evaluable
    /// over the marshalled model (Lever 1). Each branch is walked under a VISIBILITY
    /// context so a view ADDED inside it is gated (`.hidden(!cond)` in the then-branch,
    /// `.hidden(cond)` in the else). The branch BODIES must themselves be the recognized
    /// construction grammar; a non-guest-evaluable condition (a trait/geometry query, a
    /// `private`/body-local read) demotes the whole method — honest, never a wrong branch.
    ///
    /// Bounded by design (faithful over clever):
    ///   * only an `if`/`else` whose condition lowers — `else if` chains lower
    ///     recursively (the else-branch is itself an `if`),
    ///   * the gate is VISIBILITY, not structural removal: the gated view stays in the
    ///     tree but doesn't paint unless its condition holds (a stack collapses it). This
    ///     keeps the static-tree IR intact — no new IR case, no per-row structural diff.
    mutating func handleConditional(_ ifExpr: IfExprSyntax) {
        // Exactly one `if cond` (no `if let`/`case`/multi-clause — those aren't a guest
        // boolean over the marshalled model).
        guard ifExpr.conditions.count == 1,
              let cond = ifExpr.conditions.first?.condition.as(ExprSyntax.self) else {
            bail("conditional with a non-boolean clause (if let/case/multi) — demote"); return
        }
        guard let guestCond = guestBoolCondition(cond) else {
            bail("conditional condition not guest-evaluable (trait/geometry/private read) — demote"); return
        }

        // THEN branch: views added here are gated on the condition.
        let savedThen = pendingVisibility
        pendingVisibility = combine(savedThen, andGuest: guestCond)
        walkBlock(ifExpr.body.statements)
        pendingVisibility = savedThen
        if bailed { return }

        // ELSE branch: gated on the INVERSE. An `else if` is itself an `IfExprSyntax`;
        // recurse so the chain lowers (each link gated on the running inverse).
        guard let elseBody = ifExpr.elseBody else { return }
        let inverse = "!(\(guestCond))"
        let savedElse = pendingVisibility
        pendingVisibility = combine(savedElse, andGuest: inverse)
        switch elseBody {
        case .codeBlock(let block):
            walkBlock(block.statements)
        case .ifExpr(let nested):
            handleConditional(nested)
        }
        pendingVisibility = savedElse
    }

    /// AND a new guest condition into an (optional) existing visibility context.
    private func combine(_ existing: String?, andGuest new: String) -> String {
        guard let existing else { return new }
        return "(\(existing)) && (\(new))"
    }

    /// Gate a view's visibility on `condition` (it paints only when `condition` holds):
    /// set the guest `isHiddenExpr` to `!(condition)`, AND-ing with any existing gate.
    mutating func applyPendingVisibility(to viewName: String, condition: String) {
        guard let build = views[viewName] else { return }
        // R2-#7 (build-safe = demote-safe): a CUSTOM-slot leaf does NOT ride the chainable
        // prop block at emit (`emitNode`'s `.custom` case returns a bare `UI.slot(...)` BEFORE
        // the `.hidden(…)`/`.background(…)` chain), so a visibility gate set here would be
        // SILENTLY DROPPED → a conditionally-added custom child (`if isPremium { stack.add(
        // badge) }` where `badge` is a custom view) would ALWAYS render. We can't faithfully
        // gate the slot's visibility, so demote the whole method (honest, never a wrong always-
        // visible child). A LOWERED widget gates fine (its `.hidden(expr)` rides the chain).
        if case .custom = build.widget {
            bail("conditionally-gated custom-slot child can't carry visibility — demote")
            return
        }
        // Record the gate context so `emit()` can confirm any conditional PROPERTY set on this
        // view (R2-#30/#92) was made under a context the view is gated on.
        gateContexts[viewName, default: []].insert(condition)
        let hide = "!(\(condition))"
        if let existing = views[viewName]?.props.isHiddenExpr {
            // Already gated (e.g. an explicit `.isHidden = …` then conditionally added):
            // hide if EITHER says hide.
            views[viewName]?.props.isHiddenExpr = "(\(existing)) || (\(hide))"
        } else {
            views[viewName]?.props.isHiddenExpr = hide
        }
    }
}
