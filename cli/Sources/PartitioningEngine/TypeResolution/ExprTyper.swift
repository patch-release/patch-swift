// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax

/// Best-effort expression type inference over a `Scope` + `SymbolTable`.
///
/// Handles the common cases the spec calls for: literals, declared types,
/// identifiers (locals/params/self/globals), initializers `T(...)`, member-access
/// chains (`a.b.c`), known stdlib/Foundation value types, function/method return
/// types, and `self`/property types. Returns nil whenever it cannot be confident
/// — never a guess. A nil result is safe everywhere downstream (the splitter
/// keeps a fragment generic/native, the classifier stays conservative).
struct ExprTyper {
    let table: SymbolTable
    let scope: Scope

    /// Known stdlib/Foundation value types whose member-result types we can infer
    /// without a declaration in the project. Conservative subset.
    static let stdlibMemberResults: [String: [String: String]] = [
        // collections / strings
        "String": ["count": "Int", "isEmpty": "Bool", "uppercased": "String",
                   "lowercased": "String", "trimmingCharacters": "String",
                   "hasPrefix": "Bool", "hasSuffix": "Bool", "first": "Character",
                   "last": "Character", "reversed": "String"],
        "Int": ["description": "String", "magnitude": "UInt"],
        "Double": ["description": "String", "rounded": "Double", "isFinite": "Bool"],
        "Decimal": ["description": "String"],
        "Bool": ["description": "String"],
    ]

    /// Infer the type of an arbitrary expression. Nil = not confidently known.
    func type(of expr: ExprSyntax) -> String? {
        // Literals.
        if expr.is(IntegerLiteralExprSyntax.self) { return "Int" }
        if expr.is(FloatLiteralExprSyntax.self) { return "Double" }
        if expr.is(BooleanLiteralExprSyntax.self) { return "Bool" }
        if let str = expr.as(StringLiteralExprSyntax.self) {
            return str.segments.allSatisfy { $0.is(StringSegmentSyntax.self) } || true ? "String" : nil
        }
        // Array / dictionary literal → no nominal member resolution; skip.
        if expr.is(ArrayExprSyntax.self) || expr.is(DictionaryExprSyntax.self) { return nil }

        // Bare identifier: local / param / self / property / global / a Type name.
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if let t = scope.typeOfIdentifier(name) { return t }
            // A bare UpperCamel identifier used as a value is most often an enum
            // case base or a metatype — not confidently a value type. Skip.
            return nil
        }

        // Parenthesised / tuple-of-one → unwrap.
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression {
            return type(of: inner)
        }

        // Force-unwrap / optional-chaining base: `x!`, `x?` → base type.
        if let force = expr.as(ForceUnwrapExprSyntax.self) { return type(of: force.expression) }
        if let opt = expr.as(OptionalChainingExprSyntax.self) { return type(of: opt.expression) }
        if let tryE = expr.as(TryExprSyntax.self) { return type(of: tryE.expression) }
        if let awaitE = expr.as(AwaitExprSyntax.self) { return type(of: awaitE.expression) }

        // `!x` → Bool.
        if let pre = expr.as(PrefixOperatorExprSyntax.self), pre.operator.text == "!" { return "Bool" }

        // Sequence expr: comparisons → Bool, arithmetic → numeric/string of operand.
        if let seq = expr.as(SequenceExprSyntax.self) { return typeOfSequence(seq) }

        // `Type(...)` initializer → Type.  (UpperCamel callee.)
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return typeOfCall(call)
        }

        // Member access `a.b` (not a call): resolve `a`'s type, then `b` on it.
        if let member = expr.as(MemberAccessExprSyntax.self) {
            return typeOfMemberAccess(member)
        }

        return nil
    }

    private func typeOfSequence(_ seq: SequenceExprSyntax) -> String? {
        var sawCmp = false, sawArith = false, sawStr = false
        for el in seq.elements {
            if let op = el.as(BinaryOperatorExprSyntax.self)?.operator.text {
                switch op {
                case "==", "!=", "<", ">", "<=", ">=", "&&", "||": sawCmp = true
                case "+": sawArith = true
                case "-", "*", "/", "%": sawArith = true
                default: return nil
                }
            } else if el.is(StringLiteralExprSyntax.self) { sawStr = true }
        }
        if sawCmp { return "Bool" }
        if sawArith {
            for el in seq.elements {
                if let t = type(of: el),
                   ["Int","Double","Float","CGFloat","Decimal","Int64","Int32","UInt","TimeInterval"].contains(t) {
                    return t
                }
                if el.is(FloatLiteralExprSyntax.self) { return "Double" }
                if let t = type(of: el), t == "String" { return "String" }
            }
            if sawStr { return "String" }
            let intOnly = seq.elements.allSatisfy {
                $0.is(IntegerLiteralExprSyntax.self) || $0.is(BinaryOperatorExprSyntax.self)
            }
            return intOnly ? "Int" : nil
        }
        return nil
    }

    /// The type of a call expression. Either `Type(...)` (→ Type) or
    /// `recv.method(...)` / `method(...)` (→ resolved member's return type).
    private func typeOfCall(_ call: FunctionCallExprSyntax) -> String? {
        if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = callee.baseName.text
            // `Type(...)` constructor.
            if let f = name.first, f.isUppercase { return name }
            // Free function → return type from the symbol table.
            if let fns = table.freeFunctions[name], let ret = fns.first?.returnType { return ret }
            return nil
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            let methodName = member.declName.baseName.text
            // Receiver type.
            let recvType = member.base.flatMap { type(of: $0) }
            if let recvType, let canon = table.canonicalType(recvType) {
                let ms = table.members(named: methodName, on: canon).filter { $0.kind == .method }
                if let ret = ExprTyper.unambiguousReturnType(ms) { return ret }
                // Known stdlib member result.
                if let r = ExprTyper.stdlibMemberResults[canon]?[methodName] { return r }
            }
            // `Type.method(...)` static call → return type if known.
            if let baseRef = member.base?.as(DeclReferenceExprSyntax.self),
               let f = baseRef.baseName.text.first, f.isUppercase {
                let ms = table.members(named: methodName, on: baseRef.baseName.text)
                if let ret = ExprTyper.unambiguousReturnType(ms) { return ret }
            }
            return nil
        }
        return nil
    }

    /// The single return type shared by ALL declared members in `members`, or nil
    /// when they disagree (or none declare one). SymbolTable unions same-name types
    /// across files (SymbolTable.swift:81-82), so a name declared with conflicting
    /// member shapes in two files would otherwise resolve to an arbitrary `.first`
    /// pick — a WRONG type baked into a lifted fragment signature. When the union is
    /// ambiguous we return nothing (no confident type), which is safe everywhere
    /// downstream (the fragment stays generic/native). Members with no declared
    /// return type are ignored; if some declare one and the declared ones all agree,
    /// that single type is returned.
    static func unambiguousReturnType(_ members: [SymbolTable.Member]) -> String? {
        let declared = Set(members.compactMap { $0.returnType })
        return declared.count == 1 ? declared.first : nil
    }

    /// `a.b` member access type: resolve `a`'s type, then property `b` on it.
    private func typeOfMemberAccess(_ member: MemberAccessExprSyntax) -> String? {
        let name = member.declName.baseName.text
        guard let base = member.base else { return nil }
        guard let baseType = type(of: base), let canon = table.canonicalType(baseType) else {
            // `.someCase` (implicit member) — can't type without context.
            return nil
        }
        // Property on a project type. Same-name types are unioned across files, so a
        // conflicting `Player.score: Int` (file A) vs `Player.score: String` (file B)
        // must NOT resolve to an arbitrary first pick — return nothing when ambiguous.
        let props = table.members(named: name, on: canon).filter { $0.kind == .property }
        if let t = ExprTyper.unambiguousReturnType(props) { return t }
        // Known stdlib value-type property (`.count`, `.isEmpty`).
        if let r = ExprTyper.stdlibMemberResults[canon]?[name] { return r }
        if name == "count" { return "Int" }
        if name == "isEmpty" { return "Bool" }
        return nil
    }
}
