// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax

/// Collects all symbol references inside a function/closure body.
///
/// We capture:
///   - function calls (`foo(...)`, `Type(...)`)
///   - member accesses (`URLSession.shared`, `.standard`, `obj.method`)
///   - type references in expressions / type annotations
///   - `#selector(...)` macro uses (force native)
///   - `performSelector` style calls (force native)
///
/// `forcedNativeReasons` accumulates patterns that the classifier must treat as
/// hard native, independent of the registry. This is part of the
/// zero-false-negative safety invariant.
struct ReferenceCollector {
    let converter: SourceLocationConverter
    var references: [Reference] = []
    var forcedNativeReasons: [String] = []

    init(converter: SourceLocationConverter) {
        self.converter = converter
    }

    mutating func walk(_ node: Syntax) {
        let visitor = _Visitor(converter: converter)
        visitor.walk(node)
        references = visitor.references
        forcedNativeReasons = visitor.forcedNativeReasons
    }

    /// Names that, when called, ALWAYS indicate ObjC dynamic dispatch / unsafe
    /// pointer use, regardless of argument labels. (Label-sensitive KVC calls —
    /// `setValue`/`value`/`perform` — are handled separately in `isNativeCall`
    /// so that same-named plain-Swift methods like
    /// `URLRequest.setValue(_:forHTTPHeaderField:)` are not falsely forced native.)
    static let nativeCallNames: Set<String> = [
        "performSelector", "respondsToSelector",
        "withUnsafePointer", "withUnsafeBytes", "withUnsafeMutableBytes",
        "withUnsafeMutablePointer",
        "withUnsafeMutableBufferPointer", "withUnsafeBufferPointer",
    ]

    private final class _Visitor: SyntaxVisitor {
        let converter: SourceLocationConverter
        var references: [Reference] = []
        var forcedNativeReasons: [String] = []

        init(converter: SourceLocationConverter) {
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        private func line(_ node: some SyntaxProtocol) -> Int {
            converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        }

        // Function / initializer calls: `foo(...)`, `Type(...)`, `a.b(...)`.
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            let callee = node.calledExpression
            let argLabels = node.arguments.compactMap { $0.label?.text }
            if let member = callee.as(MemberAccessExprSyntax.self) {
                let memberName = member.declName.baseName.text
                let baseText = member.base?.trimmedDescription
                references.append(
                    Reference(name: memberName, kind: .functionCall, base: baseText, line: line(node))
                )
                if let baseText {
                    references.append(
                        Reference(name: baseText, kind: .identifier, line: line(member))
                    )
                }
                if isNativeCall(memberName, labels: argLabels) {
                    forcedNativeReasons.append("call:\(memberName)")
                }
            } else if let ident = callee.as(DeclReferenceExprSyntax.self) {
                let name = ident.baseName.text
                references.append(
                    Reference(name: name, kind: .functionCall, line: line(node))
                )
                if isNativeCall(name, labels: argLabels) {
                    forcedNativeReasons.append("call:\(name)")
                }
            }
            return .visitChildren
        }

        /// Whether a call is genuine ObjC-runtime / unsafe-pointer dispatch.
        ///
        /// KVC selectors (`setValue`/`value`/`perform`) are only native when used
        /// with their ObjC-runtime argument labels (`forKey:`/`forKeyPath:`/
        /// `with:`). Plain Swift methods that merely share the *base name* — e.g.
        /// `URLRequest.setValue(_:forHTTPHeaderField:)`, `Dictionary.value`,
        /// `OperationQueue.perform` — are NOT ObjC interop and must not be forced
        /// native (that false-native was pulling networking code out of `bridged`).
        private func isNativeCall(_ name: String, labels: [String]) -> Bool {
            switch name {
            case "setValue", "value":
                return labels.contains("forKey") || labels.contains("forKeyPath")
            case "perform":
                // `perform(_:with:)`/`perform(_:)` ObjC selector dispatch. A
                // Swift `perform` with named labels (e.g. block-based APIs) is not.
                return labels.isEmpty || labels.contains("with") || labels.contains("afterDelay")
            default:
                return ReferenceCollector.nativeCallNames.contains(name)
            }
        }

        // Member access: `URLSession.shared`, `.standard`, `user.tier`.
        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            let memberName = node.declName.baseName.text
            let baseText = node.base?.trimmedDescription
            references.append(
                Reference(name: memberName, kind: .memberAccess, base: baseText, line: line(node))
            )
            return .visitChildren
        }

        // Bare identifiers / type names used as values: `URLSession`, `Decimal`.
        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            let name = node.baseName.text
            // Heuristic: capitalized => likely a type name; else an identifier.
            let kind: Reference.ReferenceKind =
                name.first.map { $0.isUppercase } == true ? .typeName : .identifier
            references.append(Reference(name: name, kind: kind, line: line(node)))
            return .visitChildren
        }

        // Type annotations / generic args: `let x: URLSession`, `[CartItem]`.
        override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
            references.append(
                Reference(name: node.name.text, kind: .typeName, line: line(node))
            )
            return .visitChildren
        }

        // `#selector(...)` => ObjC selector => hard native.
        override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
            let macro = node.macroName.text
            references.append(Reference(name: "#\(macro)", kind: .selector, line: line(node)))
            if macro == "selector" {
                forcedNativeReasons.append("#selector")
            }
            return .visitChildren
        }

        // Closures crossing into the body are themselves visited by the outer
        // FunctionExtractor; here we conservatively note their presence so the
        // classifier can be cautious if needed. (No forced-native here — pure
        // map/filter/reduce closures must stay eligible.)
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            return .visitChildren
        }
    }
}
