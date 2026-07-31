// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser

/// Builds a project-wide `SymbolTable` by parsing every `.swift` file once.
///
/// The member `recordID`s it emits use the SAME id scheme as
/// `FunctionExtractor` (`module + typeStack + signature`) so the call graph can
/// add a precise caller→callee edge to the resolved target's record.
public struct SymbolTableBuilder {
    public init() {}

    /// Build from a directory of sources.
    public func build(directory: URL) -> SymbolTable {
        let files = (try? SwiftParserEngine.swiftFiles(in: directory)) ?? []
        return build(files: files)
    }

    /// Build from explicit file URLs.
    public func build(files: [URL]) -> SymbolTable {
        var collector = Collector()
        for file in files {
            let source: String
            if let utf8 = try? String(contentsOf: file, encoding: .utf8) {
                source = utf8
            } else if let data = try? Data(contentsOf: file) {
                source = String(decoding: data, as: UTF8.self)
            } else {
                continue
            }
            collector.collect(source: source, file: file)
        }
        return collector.finish()
    }

    /// Build from in-memory sources (tests). Each tuple is (source, file).
    public func build(sources: [(String, URL)]) -> SymbolTable {
        var collector = Collector()
        for (source, file) in sources { collector.collect(source: source, file: file) }
        return collector.finish()
    }

    /// Convenience for a single source string.
    public func build(source: String, file: URL) -> SymbolTable {
        build(sources: [(source, file)])
    }
}

/// Accumulates declarations across files, then merges same-named types
/// (conservatively unioning members — more candidates, never fewer).
private struct Collector {
    var typeMembers: [String: (kind: SymbolTable.TypeDecl.Kind, inherits: Set<String>, members: [SymbolTable.Member])] = [:]
    var freeFunctions: [String: [SymbolTable.Member]] = [:]
    var typeAliases: [String: String] = [:]
    var globals: [String: String] = [:]
    var freshlyDeclared: Set<String> = []
    var freshlyDeclaredValueTypes: Set<String> = []

    mutating func collect(source: String, file: URL) {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: file.path, tree: tree)
        let module = file.deletingLastPathComponent().lastPathComponent
        let visitor = DeclVisitor(moduleName: module.isEmpty ? "Module" : module, converter: converter)
        visitor.walk(tree)
        freshlyDeclared.formUnion(visitor.freshlyDeclared)
        freshlyDeclaredValueTypes.formUnion(visitor.freshlyDeclaredValueTypes)
        for (name, info) in visitor.typeMembers {
            if var existing = typeMembers[name] {
                existing.inherits.formUnion(info.inherits)
                existing.members.append(contentsOf: info.members)
                typeMembers[name] = existing
            } else {
                typeMembers[name] = info
            }
        }
        for (name, fns) in visitor.freeFunctions { freeFunctions[name, default: []].append(contentsOf: fns) }
        for (a, b) in visitor.typeAliases where typeAliases[a] == nil { typeAliases[a] = b }
        for (g, t) in visitor.globals where globals[g] == nil { globals[g] = t }
    }

    func finish() -> SymbolTable {
        var types: [String: SymbolTable.TypeDecl] = [:]
        for (name, info) in typeMembers {
            types[name] = SymbolTable.TypeDecl(
                name: name, kind: info.kind,
                inherits: Array(info.inherits), members: info.members)
        }
        // Typealiases are fresh declarations too (they introduce a new name that
        // shadows a same-named framework type for unqualified references). They
        // are treated as value-safe (an alias for a pure type is a pure value
        // collision, e.g. swift-collections `typealias Path = …`).
        var fresh = freshlyDeclared
        fresh.formUnion(typeAliases.keys)
        var freshValue = freshlyDeclaredValueTypes
        freshValue.formUnion(typeAliases.keys)
        return SymbolTable(types: types, freeFunctions: freeFunctions,
                           typeAliases: typeAliases, globals: globals,
                           freshlyDeclaredTypeNames: fresh,
                           freshlyDeclaredValueTypeNames: freshValue)
    }
}

/// Per-file declaration visitor producing members with `FunctionExtractor`-style
/// record ids.
private final class DeclVisitor: SyntaxVisitor {
    let moduleName: String
    let converter: SourceLocationConverter

    var typeStack: [String] = []
    var typeKindStack: [SymbolTable.TypeDecl.Kind] = []
    var functionStack: [String] = []

    var typeMembers: [String: (kind: SymbolTable.TypeDecl.Kind, inherits: Set<String>, members: [SymbolTable.Member])] = [:]
    var freeFunctions: [String: [SymbolTable.Member]] = [:]
    var typeAliases: [String: String] = [:]
    var globals: [String: String] = [:]
    /// Names introduced by a FRESH nominal declaration (struct/class/enum/actor/
    /// protocol) — NOT extensions. Only these shadow a framework symbol.
    var freshlyDeclared: Set<String> = []
    /// Subset of `freshlyDeclared` that are VALUE types (struct/enum). Used for
    /// the conservative shadowing policy (value-type collisions are the safe,
    /// monotonic win; shadowing pervasive reference types can perturb the
    /// realized-split anchor set and is gated out by default).
    var freshlyDeclaredValueTypes: Set<String> = []

    init(moduleName: String, converter: SourceLocationConverter) {
        self.moduleName = moduleName
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    private func ensureType(_ name: String, _ kind: SymbolTable.TypeDecl.Kind, _ inherits: [String]) {
        if var t = typeMembers[name] {
            t.inherits.formUnion(inherits)
            typeMembers[name] = t
        } else {
            typeMembers[name] = (kind, Set(inherits), [])
        }
    }

    private func inheritedLeadings(_ clause: InheritanceClauseSyntax?) -> [String] {
        guard let clause else { return [] }
        return clause.inheritedTypes.compactMap {
            SymbolTable.leadingNominal($0.type.trimmedDescription)
        }
    }

    private func pushType(_ name: String, kind: SymbolTable.TypeDecl.Kind, inheritance: InheritanceClauseSyntax?) {
        ensureType(name, kind, inheritedLeadings(inheritance))
        // A fresh nominal declaration introduces (or re-affirms) this name as a
        // project type that shadows any framework symbol of the same name. We
        // record EVERY fresh declaration here; the consumer chooses which kinds
        // to honour (see `ResolvedProject.projectTypeNames`).
        freshlyDeclared.insert(name)
        if kind == .struct || kind == .enum { freshlyDeclaredValueTypes.insert(name) }
        typeStack.append(name)
        typeKindStack.append(kind)
    }
    private func popType() {
        if !typeStack.isEmpty { typeStack.removeLast() }
        if !typeKindStack.isEmpty { typeKindStack.removeLast() }
    }

    // MARK: type decls

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, kind: .struct, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { popType() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, kind: .class, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { popType() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, kind: .enum, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { popType() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, kind: .actor, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { popType() }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, kind: .protocol, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { popType() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let name = SymbolTable.leadingNominal(node.extendedType.trimmedDescription) else {
            // Non-nominal extended type (e.g. `extension [T]`, `extension (A, B)`): push a
            // sentinel so the paired visitPost popType() stays balanced (avoids a stack
            // underflow trap — this is the crash that hit Alamofire). Members under a "" type
            // simply won't resolve to a real type → conservatively unresolved/native.
            typeStack.append(""); typeKindStack.append(.struct)
            return .visitChildren
        }
        // Extensions default a type's kind to `.struct` if not seen yet (we don't
        // know — only affects metatype/instance dispatch nuance, which we treat
        // conservatively anyway). The inheritance clause adds protocol conformances.
        if typeMembers[name] == nil { ensureType(name, .struct, inheritedLeadings(node.inheritanceClause)) }
        else { ensureType(name, typeMembers[name]!.kind, inheritedLeadings(node.inheritanceClause)) }
        typeStack.append(name)
        typeKindStack.append(typeMembers[name]?.kind ?? .struct)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { popType() }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        if let rhs = SymbolTable.leadingNominal(node.initializer.value.trimmedDescription) {
            typeAliases[node.name.text] = rhs
        }
        return .visitChildren
    }

    // MARK: members

    private func qualifiedID(signature: String) -> String {
        let components = [moduleName] + typeStack + [signature]
        return components.joined(separator: ".")
    }

    private func sig(name: String, params: FunctionParameterListSyntax) -> String {
        let labels = params.map { "\($0.firstName.text):" }.joined()
        return "\(name)(\(labels))"
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let params = node.signature.parameterClause.parameters
        let argLabels = params.map { $0.firstName.text }
        let paramTypes = params.map { $0.type.trimmedDescription }
        let ret = node.signature.returnClause?.type.trimmedDescription
        let isStatic = node.modifiers.contains { ["static", "class"].contains($0.name.text) }
        let recordID = qualifiedID(signature: sig(name: name, params: params))
        let member = SymbolTable.Member(
            kind: .method, name: name, argLabels: argLabels, paramTypes: paramTypes,
            returnType: ret, isStatic: isStatic, recordID: recordID)
        if let owner = typeStack.last {
            typeMembers[owner]?.members.append(member)
        } else {
            freeFunctions[name, default: []].append(member)
        }
        functionStack.append(sig(name: name, params: params))
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { if !functionStack.isEmpty { functionStack.removeLast() } }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let params = node.signature.parameterClause.parameters
        let argLabels = params.map { $0.firstName.text }
        let paramTypes = params.map { $0.type.trimmedDescription }
        let recordID = qualifiedID(signature: sig(name: "init", params: params))
        let member = SymbolTable.Member(
            kind: .initializer, name: "init", argLabels: argLabels, paramTypes: paramTypes,
            returnType: typeStack.last, isStatic: true, recordID: recordID)
        if let owner = typeStack.last { typeMembers[owner]?.members.append(member) }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isStatic = node.modifiers.contains { ["static", "class"].contains($0.name.text) }
        for binding in node.bindings {
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            // Type: explicit annotation, else inferred from a simple initializer.
            var type = binding.typeAnnotation?.type.trimmedDescription
            if type == nil, let initVal = binding.initializer?.value {
                type = Self.simpleInitType(initVal)
            }
            // computed property record id (for resolution to a body record).
            var recordID: String? = nil
            if binding.accessorBlock != nil {
                recordID = qualifiedID(signature: ident)
            }
            let member = SymbolTable.Member(
                kind: .property, name: ident, argLabels: [], paramTypes: [],
                returnType: type, isStatic: isStatic, recordID: recordID)
            if let owner = typeStack.last {
                typeMembers[owner]?.members.append(member)
            } else if typeStack.isEmpty {
                if let type { globals[ident] = type }
            }
        }
        return .visitChildren
    }

    /// Best-effort type of a stored-property initializer (`= Foo(...)`, literal).
    private static func simpleInitType(_ expr: ExprSyntax) -> String? {
        if let call = expr.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
           let f = callee.first, f.isUppercase { return callee }
        if expr.is(IntegerLiteralExprSyntax.self) { return "Int" }
        if expr.is(FloatLiteralExprSyntax.self) { return "Double" }
        if expr.is(StringLiteralExprSyntax.self) { return "String" }
        if expr.is(BooleanLiteralExprSyntax.self) { return "Bool" }
        return nil
    }
}
