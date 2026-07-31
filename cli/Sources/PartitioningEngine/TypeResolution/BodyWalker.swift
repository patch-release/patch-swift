// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax

/// Walks a function body, threading a `Scope` so each local binding's inferred
/// type is available to later statements, and records every call site resolved to
/// its concrete target(s) by the `TypeResolver`.
///
/// It is NOT a SyntaxVisitor subclass for the binding threading (binding requires
/// ordered, scope-sensitive processing the visitor's post-order doesn't give us),
/// but it uses a nested visitor to find call sites within each statement.
final class BodyWalker {
    let resolver: TypeResolver
    var scope: Scope
    private(set) var calls: [TypeResolver.ResolvedCall] = []

    init(resolver: TypeResolver, scope: Scope) {
        self.resolver = resolver
        self.scope = scope
    }

    func walk(_ body: CodeBlockItemListSyntax) {
        for item in body { walkItem(item) }
    }

    private func walkItem(_ item: CodeBlockItemSyntax) {
        // First, resolve calls in the statement against the CURRENT scope.
        resolveCalls(in: Syntax(item))
        // Then bind any locals the statement introduces (visible to later stmts).
        switch item.item {
        case .decl(let decl):
            if let varDecl = decl.as(VariableDeclSyntax.self) { bindVariables(varDecl) }
        case .stmt, .expr:
            break
        }
        // `if let`/`guard let`/`for x in` bindings are intentionally not threaded
        // as typed locals (their element types are hard to infer soundly); leaving
        // them untyped is safe — downstream stays conservative.
    }

    private func bindVariables(_ varDecl: VariableDeclSyntax) {
        let typer = ExprTyper(table: resolver.table, scope: scope)
        for binding in varDecl.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            // (1) Explicit annotation wins.
            if let t = binding.typeAnnotation?.type.trimmedDescription {
                scope.bind(name, type: t)
                continue
            }
            // (2) Infer from initializer.
            if let initVal = binding.initializer?.value, let t = typer.type(of: initVal) {
                scope.bind(name, type: t)
            }
        }
    }

    /// Find call sites in a syntax subtree and resolve each against the current
    /// scope. Resolution of the receiver type uses the (already-threaded) scope,
    /// so a `let x = Foo()` earlier in the body lets `x.bar()` resolve to `Foo.bar`.
    private func resolveCalls(in node: Syntax) {
        let finder = CallSiteFinder()
        finder.walk(node)
        let typer = ExprTyper(table: resolver.table, scope: scope)
        for site in finder.sites {
            let receiverType: String?
            if let baseExpr = site.receiver {
                // `Type.method` static call → receiver type is the Type name itself.
                if let ref = baseExpr.as(DeclReferenceExprSyntax.self),
                   let f = ref.baseName.text.first, f.isUppercase,
                   resolver.table.types[ref.baseName.text] != nil {
                    receiverType = ref.baseName.text
                } else {
                    receiverType = typer.type(of: baseExpr)
                }
            } else {
                receiverType = nil
            }
            let resolved = resolver.resolveCall(
                name: site.name, argLabels: site.argLabels, receiverType: receiverType)
            calls.append(resolved)
        }
    }
}

/// Collects call sites (name, labels, receiver expression) within a statement,
/// WITHOUT descending into nested function/closure decls' own bodies beyond the
/// statement (closures are themselves separate records).
final class CallSiteFinder: SyntaxVisitor {
    struct Site { let name: String; let argLabels: [String]; let receiver: ExprSyntax? }
    private(set) var sites: [Site] = []
    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let labels = node.arguments.map { $0.label?.text ?? "" }
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            sites.append(Site(name: member.declName.baseName.text, argLabels: labels, receiver: member.base))
        } else if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            sites.append(Site(name: ref.baseName.text, argLabels: labels, receiver: nil))
        }
        return .visitChildren
    }
}
