// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser

/// The project-wide output of the type-resolution layer, keyed by
/// `FunctionRecord.id`:
///   - `resolvedEdges[id]`  — concrete callee record-ids each function resolves to
///     (the type-resolved replacement for name-based call resolution),
///   - `unresolvedCallNames[id]` — call-site names that did NOT resolve to a
///     project record (free/stdlib/native calls), kept for the registry scan,
///   - `localTypes[id]`     — inferred concrete types of the function's locals +
///     params, used by the splitter to give fragments concrete types.
///
/// SAFETY: every map here is purely *additive precision*. The call graph still
/// keeps unresolved names for the registry, and the classifier still defaults to
/// native for anything not proven. Nothing here can turn a native-touching
/// function eligible — it only removes spurious edges and adds concrete types.
public struct ResolvedProject: Sendable {
    public let table: SymbolTable
    /// Resolved caller→callee record-id edges per function.
    public let resolvedEdges: [String: Set<String>]
    /// Call-site names per function that did not resolve to a project record.
    public let unresolvedCallNames: [String: Set<String>]
    /// Inferred local/param types per function.
    public let localTypes: [String: [String: String]]
    /// Whether a function's calls were ALL precisely resolved (no project-wide
    /// name fallback). Lets the call graph trust the resolved edge set.
    public let fullyResolved: [String: Bool]

    public init(table: SymbolTable,
                resolvedEdges: [String: Set<String>],
                unresolvedCallNames: [String: Set<String>],
                localTypes: [String: [String: String]],
                fullyResolved: [String: Bool]) {
        self.table = table
        self.resolvedEdges = resolvedEdges
        self.unresolvedCallNames = unresolvedCallNames
        self.localTypes = localTypes
        self.fullyResolved = fullyResolved
    }

    public static let empty = ResolvedProject(
        table: .empty, resolvedEdges: [:], unresolvedCallNames: [:],
        localTypes: [:], fullyResolved: [:])

    /// Nominal type names the project declares (struct/class/enum/actor/protocol)
    /// plus typealiases — the names that SHADOW any framework symbol of the same
    /// name for unqualified references inside this project. Fed to the classifier
    /// so its registry scan does not flag a project's own `Path`/`Index`/
    /// `Observable`/`Stream`/… as the framework symbol.
    ///
    /// SAFETY: a declared nominal name binds an unqualified reference to the
    /// project type under Swift name lookup, so suppressing the framework hit for
    /// these names can never hide a real native dependency — the reference simply
    /// is not the framework symbol. Attribute/selector refs are never shadowed by
    /// the classifier, so forced-native interop detection is unaffected.
    public static func projectTypeNames(from table: SymbolTable,
                                        registry: NativeRegistry = .standard) -> Set<String> {
        // ONLY fresh VALUE-type declarations (struct/enum) + SAFE typealiases
        // shadow framework symbols. Rationale:
        //   • Never `table.types.keys` — that includes framework types the project
        //     merely EXTENDS (`extension UIView {…}`), which must NOT be shadowed.
        //   • Value-type collisions (swift-collections' `Path`/`Index`, SDK value
        //     models) are a monotonic realized-OTA win.
        //   • Pervasive reference types that anchor auto-splits (RxSwift's
        //     `Observable` class) are excluded: shadowing them is *correct* for
        //     eligibility but shrinks the native-anchor set the realized splitter
        //     relies on, net-reducing realized OTA. Conservative by design — this
        //     can only ever leave a hit in place (cost coverage), never hide one.
        var names = table.freshlyDeclaredValueTypeNames
        // SAFETY: a typealias that resolves to a NATIVE framework type (e.g.
        // RxExample's `typealias Image = UIImage`) does NOT shadow — the alias IS
        // the native type, so suppressing its hit would be a false negative. Drop
        // any alias whose RHS canonical target is a non-WASM registry symbol AND
        // is not itself a fresh project declaration (an alias to a project type the
        // project also redeclares — e.g. `typealias Pure = Path` where `Path` is a
        // project struct — is still a pure value collision and stays shadowed).
        for (alias, target) in table.typeAliases {
            let canon = SymbolTable.leadingNominal(target) ?? target
            if table.freshlyDeclaredTypeNames.contains(canon) { continue } // alias to a project type → keep
            if let entry = registry.entry(for: canon), entry.tier != .wasmSafeFoundation {
                names.remove(alias)
            }
        }
        return names
    }
}

/// Builds a `ResolvedProject` from a directory or explicit files. One parse per
/// file; reuses the per-file tree for both the symbol table and per-function
/// resolution.
public struct ProjectResolver {
    /// A per-function resolution can be skipped above this many functions in a
    /// single file to keep giant files inside the time budget; such functions
    /// degrade to name-based (safe). Generous — real files are far below it.
    public let perFileFunctionCap: Int

    public init(perFileFunctionCap: Int = 20_000) {
        self.perFileFunctionCap = perFileFunctionCap
    }

    public func resolve(directory: URL) -> ResolvedProject {
        let files = (try? SwiftParserEngine.swiftFiles(in: directory)) ?? []
        return resolve(files: files)
    }

    public func resolve(files: [URL]) -> ResolvedProject {
        var sources: [(String, URL)] = []
        for f in files {
            if let s = try? String(contentsOf: f, encoding: .utf8) {
                sources.append((s, f))
            } else if let d = try? Data(contentsOf: f) {
                sources.append((String(decoding: d, as: UTF8.self), f))
            }
        }
        return resolve(sources: sources)
    }

    /// Build from in-memory sources (tests + the engine's parse-once path).
    public func resolve(sources: [(String, URL)]) -> ResolvedProject {
        // 1. Symbol table over all files.
        let table = SymbolTableBuilder().build(sources: sources)
        let resolver = TypeResolver(table: table)

        var resolvedEdges: [String: Set<String>] = [:]
        var unresolvedNames: [String: Set<String>] = [:]
        var localTypes: [String: [String: String]] = [:]
        var fullyResolved: [String: Bool] = [:]

        // 2. Per-file: walk decls, resolve each function body.
        for (source, file) in sources {
            let tree = Parser.parse(source: source)
            let converter = SourceLocationConverter(fileName: file.path, tree: tree)
            let module = file.deletingLastPathComponent().lastPathComponent
            let walker = FunctionResolutionVisitor(
                moduleName: module.isEmpty ? "Module" : module,
                resolver: resolver, cap: perFileFunctionCap)
            _ = converter
            walker.walk(tree)
            for (id, edges) in walker.resolvedEdges { resolvedEdges[id, default: []].formUnion(edges) }
            for (id, names) in walker.unresolvedNames { unresolvedNames[id, default: []].formUnion(names) }
            for (id, types) in walker.localTypes { localTypes[id] = types }
            for (id, full) in walker.fullyResolved { fullyResolved[id] = full }
        }

        return ResolvedProject(
            table: table, resolvedEdges: resolvedEdges,
            unresolvedCallNames: unresolvedNames, localTypes: localTypes,
            fullyResolved: fullyResolved)
    }
}

/// Walks one file's declarations, mirroring `FunctionExtractor`'s id scheme, and
/// resolves each function/method/init/computed-property body via the
/// `TypeResolver`.
private final class FunctionResolutionVisitor: SyntaxVisitor {
    let moduleName: String
    let resolver: TypeResolver
    let cap: Int

    var typeStack: [String] = []
    var functionStack: [String] = []
    var fnCount = 0

    var resolvedEdges: [String: Set<String>] = [:]
    var unresolvedNames: [String: Set<String>] = [:]
    var localTypes: [String: [String: String]] = [:]
    var fullyResolved: [String: Bool] = [:]

    init(moduleName: String, resolver: TypeResolver, cap: Int) {
        self.moduleName = moduleName
        self.resolver = resolver
        self.cap = cap
        super.init(viewMode: .sourceAccurate)
    }

    private func qualifiedID(_ signature: String, closure: Bool = false) -> String {
        var components = [moduleName] + typeStack
        if closure { components += functionStack }
        return (components + [signature]).joined(separator: ".")
    }

    private func sig(name: String, params: FunctionParameterListSyntax) -> String {
        let labels = params.map { "\($0.firstName.text):" }.joined()
        return "\(name)(\(labels))"
    }

    // type context
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { typeStack.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { typeStack.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { typeStack.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { typeStack.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { typeStack.append(node.name.text); return .visitChildren }
    override func visitPost(_ node: ProtocolDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(SymbolTable.leadingNominal(node.extendedType.trimmedDescription) ?? node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    private func paramTypeMap(_ params: FunctionParameterListSyntax) -> [String: String] {
        var out: [String: String] = [:]
        for p in params {
            let name = (p.secondName ?? p.firstName).text
            if name != "_" { out[name] = p.type.trimmedDescription }
        }
        return out
    }

    private func recordResolution(id: String, body: CodeBlockItemListSyntax, paramTypes: [String: String]) {
        guard fnCount < cap else { return }
        fnCount += 1
        let selfType = typeStack.last
        let resolved = resolver.resolve(body: body, selfType: selfType, paramTypes: paramTypes)
        var edges: Set<String> = []
        var unresolved: Set<String> = []
        var allPrecise = true
        for call in resolved.resolvedCalls {
            if call.targetRecordIDs.isEmpty {
                unresolved.insert(call.name)
                if !call.isPrecise { allPrecise = false }
            } else {
                for t in call.targetRecordIDs where t != id { edges.insert(t) }
                if !call.isPrecise { allPrecise = false }
            }
        }
        resolvedEdges[id] = edges
        unresolvedNames[id] = unresolved
        localTypes[id] = resolved.localTypes
        fullyResolved[id] = allPrecise
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let signature = sig(name: node.name.text, params: node.signature.parameterClause.parameters)
        let id = qualifiedID(signature)
        if let body = node.body?.statements {
            recordResolution(id: id, body: body,
                             paramTypes: paramTypeMap(node.signature.parameterClause.parameters))
        }
        functionStack.append(signature)
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { if !functionStack.isEmpty { functionStack.removeLast() } }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let signature = sig(name: "init", params: node.signature.parameterClause.parameters)
        let id = qualifiedID(signature)
        if let body = node.body?.statements {
            recordResolution(id: id, body: body,
                             paramTypes: paramTypeMap(node.signature.parameterClause.parameters))
        }
        functionStack.append(signature)
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) { if !functionStack.isEmpty { functionStack.removeLast() } }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let accessor = binding.accessorBlock else { continue }
            let propName = binding.pattern.trimmedDescription
            switch accessor.accessors {
            case .getter(let codeBlock):
                recordResolution(id: qualifiedID(propName), body: codeBlock, paramTypes: [:])
            case .accessors(let list):
                for acc in list where acc.body != nil && acc.accessorSpecifier.text == "get" {
                    if let b = acc.body?.statements {
                        recordResolution(id: qualifiedID("\(propName).get"), body: b, paramTypes: [:])
                    }
                }
            }
        }
        return .visitChildren
    }
}
