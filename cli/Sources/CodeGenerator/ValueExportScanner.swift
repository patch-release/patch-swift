// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser
import PartitioningEngine

/// Scans a source file for **SwiftUI value members** the engine freed to
/// `wasmEligible` — pure design tokens / labels / value helpers on a (per-member)
/// view-DSL type whose whole getter body can be lifted into WASM and read back
/// through `Patch.value(...)` / `Patch.call(...)`.
///
/// Unlike `PureExportScanner` (which exports instance-less free/static funcs),
/// this lifts **instance** computed properties and instance methods of a view
/// type, because their body needs no `self` (a freed value member touches no
/// reactive state or `self`-stored properties — that is exactly what made it
/// freeable). The getter body becomes a standalone `_pv_<Type>_<member>` WASM
/// function; the native shell keeps a thin getter shim.
///
/// Only confidently-liftable scalar/string value types are accepted (the
/// `liftableValueTypes` allow-list). CGFloat crosses the ABI as Double. A member
/// returning a view, an opaque/`any` type, or a non-allow-listed type is skipped
/// (it stays in the native shell verbatim — never a safety issue, only lost
/// coverage). The enclosing type must be a view-DSL conformer (the same set the
/// extractor uses for per-member forcing).
public struct ValueExportScanner {
    public init() {}

    /// Value types we lift as OTA-updatable scalars/strings. CGFloat is included
    /// (crosses as Double). Color/Font are NOT here — they are `mustStayNative`,
    /// so a member constructing one is never freed in the first place.
    public static let liftableValueTypes: Set<String> = [
        "String", "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "CGFloat", "Bool", "TimeInterval",
    ]

    /// View-DSL conformances whose freed value members are lift candidates. Must
    /// match `FunctionExtractor.viewDSLConformances`.
    public static let viewDSLConformances: Set<String> = [
        "View", "App", "Scene", "ViewModifier", "Commands", "ToolbarContent",
        "Shape", "PreviewProvider", "DynamicProperty", "WidgetBundle", "Widget",
    ]

    /// Find liftable value members in `source`, restricted to the simple member
    /// names the engine marked eligible. Returns the exports grouped by type name
    /// (deterministic order). `eligibleSimpleNames` holds e.g. `primaryFontSize`,
    /// `badgeLabel`.
    public func scan(source: String, eligibleSimpleNames: Set<String>) -> [(typeName: String, exports: [CodeEmitter.ValueExport])] {
        let tree = Parser.parse(source: source)
        let collector = Collector(eligible: eligibleSimpleNames)
        collector.walk(tree)
        // Group by type, deterministic order, de-dup by (type, member).
        var byType: [String: [CodeEmitter.ValueExport]] = [:]
        var seen = Set<String>()
        for e in collector.exports.sorted(by: { $0.key < $1.key }) {
            guard seen.insert(e.key).inserted else { continue }
            byType[e.typeName, default: []].append(e)
        }
        return byType.keys.sorted().map { (typeName: $0, exports: byType[$0]!) }
    }

    final class Collector: SyntaxVisitor {
        let eligible: Set<String>
        private(set) var exports: [CodeEmitter.ValueExport] = []
        /// Stack of (typeName, isViewDSL, instanceMembers) for enclosing nominal types.
        /// `instanceMembers` = the type's non-static stored/computed props + methods; a
        /// value member whose body reads any of them (or bare `self`) CANNOT be lifted to
        /// a standalone function (no receiver) — emitting it produces a `cannot find 'X'
        /// in scope` fragment that poisons the whole module. So we reject those.
        private var typeStack: [(name: String, isViewDSL: Bool, instanceMembers: Set<String>)] = []

        init(eligible: Set<String>) {
            self.eligible = eligible
            super.init(viewMode: .sourceAccurate)
        }

        // MARK: type context

        private func push(_ name: String, _ inheritance: InheritanceClauseSyntax?,
                          _ members: MemberBlockItemListSyntax?) {
            typeStack.append((name, Self.isViewDSL(inheritance), Self.instanceMemberNames(of: members)))
        }
        /// Non-static stored/computed property + method names declared by the type.
        private static func instanceMemberNames(of members: MemberBlockItemListSyntax?) -> Set<String> {
            guard let members else { return [] }
            var names = Set<String>()
            for item in members {
                if let v = item.decl.as(VariableDeclSyntax.self) {
                    if v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
                    for b in v.bindings { names.insert(b.pattern.trimmedDescription) }
                } else if let f = item.decl.as(FunctionDeclSyntax.self) {
                    if f.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
                    names.insert(f.name.text)
                }
            }
            return names
        }
        /// Whether a lifted member's body reads `self` or any instance member of the
        /// enclosing type — which it cannot, standalone. Word-boundary, excludes
        /// member-access (`foo.content` on another object is fine).
        private static func bodyReadsInstanceState(_ body: [String], members: Set<String>) -> Bool {
            let text = body.joined(separator: "\n")
            if referencesIdentifier(text, "self") { return true }
            for m in members where referencesIdentifier(text, m) { return true }
            return false
        }
        private static func referencesIdentifier(_ text: String, _ id: String) -> Bool {
            guard !id.isEmpty else { return false }
            let isIdent: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
            var start = text.startIndex
            while let r = text.range(of: id, range: start..<text.endIndex) {
                let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
                let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
                let memberAccess = (before == ".")
                if !(before.map(isIdent) ?? false) && !(after.map(isIdent) ?? false) && !memberAccess { return true }
                start = r.upperBound
            }
            return false
        }
        private var currentViewInstanceMembers: Set<String> {
            guard let top = typeStack.last, top.isViewDSL else { return [] }
            return top.instanceMembers
        }
        private static func isViewDSL(_ inheritance: InheritanceClauseSyntax?) -> Bool {
            guard let inheritance else { return false }
            for inh in inheritance.inheritedTypes {
                let leading = inh.type.trimmedDescription.split(separator: ".").first.map(String.init)
                    ?? inh.type.trimmedDescription
                if ValueExportScanner.viewDSLConformances.contains(leading) { return true }
            }
            return false
        }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            push(node.name.text, node.inheritanceClause, node.memberBlock.members); return .visitChildren
        }
        override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }
        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
            push(node.name.text, node.inheritanceClause, node.memberBlock.members); return .visitChildren
        }
        override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }
        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            push(node.name.text, node.inheritanceClause, node.memberBlock.members); return .visitChildren
        }
        override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }

        /// Only consider members whose nearest enclosing type is a view-DSL type.
        private var currentViewType: String? {
            guard let top = typeStack.last, top.isViewDSL else { return nil }
            return top.name
        }

        // MARK: computed properties

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            guard let typeName = currentViewType else { return .visitChildren }
            for binding in node.bindings {
                guard let accessor = binding.accessorBlock else { continue }
                let propName = binding.pattern.trimmedDescription
                guard eligible.contains(propName) else { continue }
                guard let declType = binding.typeAnnotation?.type.trimmedDescription,
                      Self.isLiftable(declType) else { continue }
                // Result-builder properties (@ViewBuilder) are view DSL — skip.
                if Self.hasResultBuilderAttr(node.attributes) { continue }
                // Only a simple getter body (not a get/set pair) is a value getter.
                guard case .getter(let codeBlock) = accessor.accessors else { continue }
                let body = Self.statements(of: codeBlock)
                guard !body.isEmpty else { continue }
                // Reject a getter that reads instance state / `self` — it can't compile
                // as a standalone WASM function (no receiver) and would poison the module.
                guard !Self.bodyReadsInstanceState(body, members: currentViewInstanceMembers) else { continue }
                exports.append(makeExport(typeName: typeName, member: propName,
                                          isMethod: false, params: [],
                                          returnType: declType, body: body))
            }
            return .visitChildren
        }

        // MARK: methods

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            guard let typeName = currentViewType else { return .visitChildren }
            let name = node.name.text
            guard eligible.contains(name) else { return .visitChildren }
            if Self.hasResultBuilderAttr(node.attributes) { return .visitChildren }
            if node.genericParameterClause != nil { return .visitChildren }
            // Synchronous, total: a value lookup is synchronous.
            if let eff = node.signature.effectSpecifiers,
               eff.asyncSpecifier != nil || eff.throwsClause != nil { return .visitChildren }

            let ret = node.signature.returnClause?.type.trimmedDescription ?? ""
            guard Self.isLiftable(ret) else { return .visitChildren }

            var params: [(label: String, name: String, declType: String, abiType: String)] = []
            for p in node.signature.parameterClause.parameters {
                let label = p.firstName.text
                let internalName = (p.secondName ?? p.firstName).text
                let type = p.type.trimmedDescription
                guard Self.isLiftable(type) else { return .visitChildren }
                params.append((label: label, name: internalName, declType: type,
                               abiType: CodeEmitter.abiType(for: type)))
            }
            guard let bodyBlock = node.body else { return .visitChildren }
            let body = Self.statements(of: bodyBlock)
            guard !body.isEmpty else { return .visitChildren }
            // Reject a method whose body reads instance state / `self` — no receiver
            // standalone; emitting it would produce an uncompilable poison fragment.
            guard !Self.bodyReadsInstanceState(body, members: currentViewInstanceMembers) else { return .visitChildren }
            exports.append(CodeEmitter.ValueExport(
                typeName: typeName, memberName: name, isMethod: true,
                parameters: params, returnType: ret,
                abiReturnType: CodeEmitter.abiType(for: ret), bodyStatements: body))
            return .visitChildren
        }

        // MARK: helpers

        private func makeExport(typeName: String, member: String, isMethod: Bool,
                                params: [(label: String, name: String, declType: String, abiType: String)],
                                returnType: String, body: [String]) -> CodeEmitter.ValueExport {
            CodeEmitter.ValueExport(
                typeName: typeName, memberName: member, isMethod: isMethod,
                parameters: params, returnType: returnType,
                abiReturnType: CodeEmitter.abiType(for: returnType), bodyStatements: body)
        }

        /// Is a declared type a confidently-liftable scalar/string value? Strips an
        /// optional `?` (still must be in the allow-list as the wrapped type).
        static func isLiftable(_ type: String) -> Bool {
            let t = type.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "Void" { return false }
            if t.contains("->") || t.hasPrefix("some ") || t.hasPrefix("any ") { return false }
            let bare = t.hasSuffix("?") ? String(t.dropLast()) : t
            return ValueExportScanner.liftableValueTypes.contains(bare)
        }

        /// Does an attribute list carry a SwiftUI result-builder attribute? (Local
        /// copy — `FunctionExtractor` is internal to PartitioningEngine.)
        static let resultBuilderAttrs: Set<String> = [
            "ViewBuilder", "SceneBuilder", "ToolbarContentBuilder", "CommandsBuilder",
            "WidgetBundleBuilder", "AccessibilityRotorContentBuilder",
        ]
        static func hasResultBuilderAttr(_ attributes: AttributeListSyntax?) -> Bool {
            guard let attributes else { return false }
            for attr in attributes {
                guard let a = attr.as(AttributeSyntax.self) else { continue }
                if resultBuilderAttrs.contains(a.attributeName.trimmedDescription) { return true }
            }
            return false
        }

        /// Getter bodies in SwiftSyntax come as a `CodeBlockItemListSyntax`.
        static func statements(of block: CodeBlockItemListSyntax) -> [String] {
            block.map { $0.trimmedDescription }
        }
        /// Method bodies come wrapped in a `CodeBlockSyntax`.
        static func statements(of block: CodeBlockSyntax) -> [String] {
            block.statements.map { $0.trimmedDescription }
        }
    }
}
