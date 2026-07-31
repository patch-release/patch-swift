// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser
import PartitioningEngine

/// Lightweight CALL-SITE MINING for Breakthrough-#7 generic monomorphization.
///
/// Walks a source file and, for each single-argument function call `f(arg)`,
/// records the concrete VALUE type of `arg` when it can be proven syntactically:
///   * `f(Foo(...))`              → the called initializer's type `Foo`
///   * `f(Foo.bar)` / `f(.bar)`   → `Foo` (a static member / case on a value type)
///   * `f(x)` where a same-function `let x = Foo(...)` / `var x: Foo` / a param
///     `x: Foo` binds `x` to a value type → `Foo`
///
/// Only concrete project VALUE types (in `valueTypeNames`) are recorded. Everything
/// uncertain is dropped — the GenericSpecializer further restricts to single-param
/// declared generics, and the real WASM compile is the final arbiter, so a spurious
/// entry can at worst produce an instantiation that fails to compile and demotes.
///
/// SAFETY: read-only inference; never marks anything eligible by itself.
final class CallSiteArgTypeVisitor: SyntaxVisitor {
    /// funcName → set of concrete value types it was called with (single-arg sites).
    private(set) var callArgTypes: [String: Set<String>] = [:]
    private let valueTypeNames: Set<String>

    /// Local bindings in scope of the current function: name → concrete value type.
    /// A simple flat scope (function-level); nested closures share it (conservative
    /// over-approximation is fine — a wrong binding only yields a demoting spec).
    private var localBindings: [[String: String]] = [[:]]

    init(valueTypeNames: Set<String>) {
        self.valueTypeNames = valueTypeNames
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Scope tracking (params + locals)

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        var scope: [String: String] = [:]
        for p in node.signature.parameterClause.parameters {
            let name = (p.secondName ?? p.firstName).text
            let leading = SymbolTable.leadingNominal(p.type.trimmedDescription) ?? p.type.trimmedDescription
            if name != "_", valueTypeNames.contains(leading) { scope[name] = leading }
        }
        localBindings.append(scope)
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { localBindings.removeLast() }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for b in node.bindings {
            guard let name = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            // Explicit type annotation `let x: Foo`.
            if let ann = b.typeAnnotation?.type.trimmedDescription,
               let leading = SymbolTable.leadingNominal(ann), valueTypeNames.contains(leading) {
                bind(name, leading); continue
            }
            // Initializer `let x = Foo(...)`.
            if let initExpr = b.initializer?.value, let t = valueTypeOfExpr(initExpr) {
                bind(name, t)
            }
        }
        return .visitChildren
    }

    // MARK: - Call sites

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // The callee must be a bare identifier `f(...)` or a `Type.f(...)` static call;
        // we record under the SIMPLE function name (the specializer keys on it).
        let calleeName: String?
        if let ident = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            calleeName = ident.baseName.text
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            calleeName = member.declName.baseName.text
        } else {
            calleeName = nil
        }
        // Single positional argument only (the common `score(x)` shape). A multi-arg
        // or labelled-arg call is left to the conformer / pin sources.
        if let calleeName, node.arguments.count == 1,
           let arg = node.arguments.first, arg.label == nil,
           let t = valueTypeOfExpr(arg.expression) {
            callArgTypes[calleeName, default: []].insert(t)
        }
        return .visitChildren
    }

    // MARK: - Expression → concrete value type

    /// The concrete project VALUE type an expression evaluates to, if provable.
    private func valueTypeOfExpr(_ expr: ExprSyntax) -> String? {
        // `Foo(...)` initializer call.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ident = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = ident.baseName.text
            if valueTypeNames.contains(name) { return name }
        }
        // `Foo.bar` static member / `Foo.case` on a value type.
        if let member = expr.as(MemberAccessExprSyntax.self),
           let base = member.base?.as(DeclReferenceExprSyntax.self) {
            let name = base.baseName.text
            if valueTypeNames.contains(name) { return name }
        }
        // A bound local / param identifier.
        if let ident = expr.as(DeclReferenceExprSyntax.self) {
            return lookup(ident.baseName.text)
        }
        return nil
    }

    private func bind(_ name: String, _ type: String) {
        if localBindings.isEmpty { localBindings = [[:]] }
        localBindings[localBindings.count - 1][name] = type
    }
    private func lookup(_ name: String) -> String? {
        for scope in localBindings.reversed() { if let t = scope[name] { return t } }
        return nil
    }
}
