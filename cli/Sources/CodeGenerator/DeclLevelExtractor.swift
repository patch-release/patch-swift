// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser
import PartitioningEngine

/// DECL-LEVEL real-source closure extraction — the widening of the coarse
/// `PATCH_REAL_SOURCE` path (`research/wave3/BREAKTHROUGH-real-source-
/// compilation.md`, follow-up).
///
/// ## The problem with the coarse path
/// The coarse real-source compile feeds the WHOLE admissible module source to the
/// WASM SDK. It works where the entire module compiles (Euclid, CryptoSwift) but
/// gets **+0** wherever ANY file in the module is "poison" — a file that cannot
/// compile to WASM (an unconditional `import SwiftUI`/`pthread`, a C-sibling target
/// like swift-markdown's `internal import CAtomic`, an external-library import, a
/// top-level-statement script). One poison file fails the whole compile unit, and
/// every clean export demotes with it.
///
/// ## The widening
/// For a demoted export, instead of the whole module, walk the symbol table to the
/// **minimal set of DECLARATIONS the export transitively needs** (types, members,
/// free funcs, operators, extensions, typealiases, globals), pulling decls OUT of
/// files that also contain WASM-unavailable code, and compile only that decl set +
/// the wrapper against the WASM SDK. This ROUTES AROUND the poison files: the
/// `import CAtomic` line and the `AtomicCounter` struct stay behind unless an export
/// actually needs them (in which case that one export reaches a forced-native symbol
/// and demotes alone — the gate below).
///
/// ## The gate (same as the bundler/classifier)
/// Reachability-driven: BFS the decl reference graph from each export's seed. An
/// export's closure is REJECTED (the export demotes) if any reached decl references
/// a `mustStayNative` registry symbol (`NSRegularExpression`, `pthread`, …) — the
/// same gate the dependency-closure bundler already uses. Unlike the bundler, we do
/// NOT reject classes/protocols/generics: the REAL Swift compiler resolves those
/// against the real spans, so they ship fine. The arbiter of truth remains the real
/// WASM compile (the convergence loop demotes anything that still fails).
///
/// ## Output
/// The minimal real decl spans (verbatim `node.trimmedDescription`) of the UNION
/// closure across all eligible exports, written into synthesized `.swift` file(s)
/// with a clean `import Foundation`. These replace the coarse whole-module
/// `realSources` fed to `RealSourceWasmCompiler`, so the existing convergence /
/// additive machinery drives it unchanged.
public struct DeclLevelExtractor {
    public let registry: NativeRegistry
    /// T0-ISOLATION mode: when true, a type's `Codable`/`CustomReflectable`/`Encoder`/
    /// `Decoder`/`Mirror`-reaching EXTENSION is NOT pulled by a bare type reference
    /// (`hardDecls`). Such an extension is an EMBEDDED BLOCKER (Codable synthesis, the
    /// reflection runtime) that the Embedded/T0 SDK cannot compile — but a clean-math
    /// export NEVER calls `init(from:)`/`encode(to:)`/`customMirror`, so dropping the
    /// extension lets the export's geometry closure (`Vector` + `dot`/`cross`/`length`)
    /// ride T0 while routing AROUND the type's serialization surface. The SPECIFIC clean
    /// extension member an export DOES call is still pulled by the member-owner path (it
    /// filters native AND, here, embedded-blocker siblings). Off by default — the coarse
    /// decl-level fallback keeps the full type surface (it compiles at T2 anyway).
    public let excludeEmbeddedBlockerExtensions: Bool

    public init(registry: NativeRegistry = .standard,
                excludeEmbeddedBlockerExtensions: Bool = false) {
        self.registry = registry
        self.excludeEmbeddedBlockerExtensions = excludeEmbeddedBlockerExtensions
    }

    /// Protocol conformances / symbols that make an EXTENSION an embedded (T0) blocker:
    /// Codable synthesis (`Encoder`/`Decoder`/`CodingKey`) and the reflection runtime
    /// (`Mirror`/`CustomReflectable`), none of which exist in Embedded Swift. A bare
    /// type reference does NOT need these extensions; the member-owner path still pulls
    /// the clean members an export actually calls.
    static let embeddedBlockerExtensionSymbols: Set<String> = [
        "Codable", "Encodable", "Decodable", "Encoder", "Decoder",
        "KeyedEncodingContainer", "KeyedDecodingContainer", "UnkeyedDecodingContainer",
        "SingleValueDecodingContainer", "CodingKey", "CodingKeys",
        "Mirror", "CustomReflectable", "CustomLeafReflectable",
    ]

    /// Whether a (extension) decl is an embedded-blocker: its conformance list or body
    /// references a Codable/reflection symbol. Used only in T0-isolation mode.
    func isEmbeddedBlockerExtension(_ d: TopDecl) -> Bool {
        guard d.kind == .ext else { return false }
        for t in d.referencedTypes {
            let nominal = SymbolTable.leadingNominal(t) ?? t
            if Self.embeddedBlockerExtensionSymbols.contains(nominal) { return true }
        }
        for c in d.referencedCalls where Self.embeddedBlockerExtensionSymbols.contains(c) { return true }
        return false
    }


    // MARK: - Decl index

    /// A top-level (file-scope) declaration with its verbatim source span and the
    /// symbols it references. Multiple decls can share a name (a type + its
    /// extensions; an overloaded free func).
    struct TopDecl {
        enum Kind { case type, ext, function, operatorFunc, typealias_, global, importLine, other }
        let kind: Kind
        /// The nominal name this decl DEFINES (a type's name; a func's name; an
        /// extension's extended type). nil for an `import`/`operator`/global we keep
        /// unconditionally or skip.
        let definedName: String?
        /// For an extension: the extended nominal (so we attach it to that type).
        let extendedType: String?
        /// The verbatim source text (real span).
        let span: String
        /// Capitalized type names + bare call names referenced in this decl.
        let referencedTypes: Set<String>
        let referencedCalls: Set<String>
        /// Member names referenced (`.dot`, `.length`) — followed into member graph.
        let referencedMembers: Set<String>
        /// True iff this decl (or its imports) is intrinsically WASM-unavailable
        /// (references a `mustStayNative` registry symbol at the top level of the span).
        let reachesNative: String?  // the offending native symbol, or nil
        /// Source file (for diagnostics).
        let file: URL
    }

    /// The parse-once index over the corpus.
    public struct Index {
        /// definedName → all top-level decls with that name (type + extensions +
        /// overloads).
        let byName: [String: [TopDecl]]
        /// All extension decls keyed by extended type (so a type pulls ITS extensions).
        let extensionsByType: [String: [TopDecl]]
        /// Free `prefix/infix/postfix operator` declarations (kept if any operator
        /// member is pulled — cheap, harmless).
        let operatorDecls: [TopDecl]
        /// Member name → set of (owning type) — so a `.member` reference can pull the
        /// owning type's surface.
        let memberOwners: [String: Set<String>]
    }

    // MARK: - Indexing

    public func index(files: [URL]) -> Index {
        var byName: [String: [TopDecl]] = [:]
        var extByType: [String: [TopDecl]] = [:]
        var operatorDecls: [TopDecl] = []
        var memberOwners: [String: Set<String>] = [:]

        for file in files {
            guard let src = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // A file that imports a non-WASM-safe module (a C-sibling target like
            // swift-markdown's `CAtomic`, or an external library) is POISON-TAINTED: a
            // decl in it likely calls that module's symbols (free C functions the index
            // can't resolve, e.g. `_cmarkup_current_unique_id`). We index its decls (so
            // a clean sibling decl is still discoverable) but MARK them poison, so the
            // closure walk routes AROUND them — the export that needs such a decl demotes
            // alone instead of poisoning the whole compile. (`#if`-guarded native
            // imports — UIKit/AppKit behind `canImport` — are inert on wasm, so they do
            // NOT taint; only an effective import does.)
            let poison = Self.filePoisonImport(src)
            let tree = Parser.parse(source: src)
            for item in tree.statements {
                let decl = item.item
                collectTop(decl, file: file, filePoison: poison, byName: &byName, extByType: &extByType,
                           operatorDecls: &operatorDecls, memberOwners: &memberOwners)
            }
        }
        return Index(byName: byName, extensionsByType: extByType,
                     operatorDecls: operatorDecls, memberOwners: memberOwners)
    }

    private func collectTop(
        _ node: CodeBlockItemSyntax.Item, file: URL, filePoison: String?,
        byName: inout [String: [TopDecl]],
        extByType: inout [String: [TopDecl]],
        operatorDecls: inout [TopDecl],
        memberOwners: inout [String: Set<String>]
    ) {
        // Unwrap an `#if … #endif` so a decl behind a platform guard (DynamicColor's
        // AppKit/UIKit `#if`s, swift-markdown's `#if compiler(>=6.0)`) is still indexed.
        if let ifc = node.as(IfConfigDeclSyntax.self) {
            for clause in ifc.clauses {
                guard let elements = clause.elements?.as(CodeBlockItemListSyntax.self) else { continue }
                for inner in elements {
                    collectTop(inner.item, file: file, filePoison: filePoison, byName: &byName, extByType: &extByType,
                               operatorDecls: &operatorDecls, memberOwners: &memberOwners)
                }
            }
            return
        }
        if let s = node.as(StructDeclSyntax.self) {
            addType(Syntax(s), name: s.name.text, members: s.memberBlock, file: file,
                    filePoison: filePoison, byName: &byName, memberOwners: &memberOwners)
        } else if let e = node.as(EnumDeclSyntax.self) {
            addType(Syntax(e), name: e.name.text, members: e.memberBlock, file: file,
                    filePoison: filePoison, byName: &byName, memberOwners: &memberOwners)
        } else if let c = node.as(ClassDeclSyntax.self) {
            addType(Syntax(c), name: c.name.text, members: c.memberBlock, file: file,
                    filePoison: filePoison, byName: &byName, memberOwners: &memberOwners)
        } else if let a = node.as(ActorDeclSyntax.self) {
            addType(Syntax(a), name: a.name.text, members: a.memberBlock, file: file,
                    filePoison: filePoison, byName: &byName, memberOwners: &memberOwners)
        } else if let p = node.as(ProtocolDeclSyntax.self) {
            addType(Syntax(p), name: p.name.text, members: p.memberBlock, file: file,
                    filePoison: filePoison, byName: &byName, memberOwners: &memberOwners)
        } else if let ext = node.as(ExtensionDeclSyntax.self) {
            let extName = SymbolTable.leadingNominal(ext.extendedType.trimmedDescription) ?? ext.extendedType.trimmedDescription
            let refs = referencesIn(Syntax(ext))
            let native = filePoison ?? nativeHit(refs.types)
            let d = TopDecl(kind: .ext, definedName: extName, extendedType: extName,
                            span: ext.trimmedDescription, referencedTypes: refs.types,
                            referencedCalls: refs.calls, referencedMembers: refs.members,
                            reachesNative: native, file: file)
            extByType[extName, default: []].append(d)
            // Record member names declared in this extension so a `.member` reference
            // pulls the owning type (which pulls this extension).
            recordMembers(ext.memberBlock, owner: extName, into: &memberOwners)
        } else if let f = node.as(FunctionDeclSyntax.self) {
            let isOp = !(f.name.text.first.map { $0.isLetter || $0 == "_" } ?? false)
            let refs = referencesIn(Syntax(f))
            let native = filePoison ?? nativeHit(refs.types)
            let d = TopDecl(kind: isOp ? .operatorFunc : .function, definedName: f.name.text,
                            extendedType: nil, span: f.trimmedDescription,
                            referencedTypes: refs.types, referencedCalls: refs.calls,
                            referencedMembers: refs.members, reachesNative: native, file: file)
            byName[f.name.text, default: []].append(d)
        } else if let ta = node.as(TypeAliasDeclSyntax.self) {
            let refs = referencesIn(Syntax(ta))
            let d = TopDecl(kind: .typealias_, definedName: ta.name.text, extendedType: nil,
                            span: ta.trimmedDescription, referencedTypes: refs.types,
                            referencedCalls: refs.calls, referencedMembers: refs.members,
                            reachesNative: filePoison ?? nativeHit(refs.types), file: file)
            byName[ta.name.text, default: []].append(d)
        } else if let v = node.as(VariableDeclSyntax.self) {
            // A top-level (global) let/var. Name each binding so a reference can pull it.
            let refs = referencesIn(Syntax(v))
            let native = filePoison ?? nativeHit(refs.types)
            for b in v.bindings {
                guard let name = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                let d = TopDecl(kind: .global, definedName: name, extendedType: nil,
                                span: v.trimmedDescription, referencedTypes: refs.types,
                                referencedCalls: refs.calls, referencedMembers: refs.members,
                                reachesNative: native, file: file)
                byName[name, default: []].append(d)
            }
        } else if let op = node.as(OperatorDeclSyntax.self) {
            operatorDecls.append(TopDecl(kind: .other, definedName: op.name.text, extendedType: nil,
                                         span: op.trimmedDescription, referencedTypes: [],
                                         referencedCalls: [], referencedMembers: [],
                                         reachesNative: nil, file: file))
        } else if node.as(PrecedenceGroupDeclSyntax.self) != nil {
            operatorDecls.append(TopDecl(kind: .other, definedName: nil, extendedType: nil,
                                         span: node.trimmedDescription, referencedTypes: [],
                                         referencedCalls: [], referencedMembers: [],
                                         reachesNative: nil, file: file))
        }
        // import statements, top-level expressions etc. are intentionally NOT indexed
        // — the extractor emits its own clean `import Foundation`, and a top-level
        // statement would be a poison we route around.
    }

    private func addType(_ node: Syntax, name: String, members: MemberBlockSyntax, file: URL,
                         filePoison: String?, byName: inout [String: [TopDecl]],
                         memberOwners: inout [String: Set<String>]) {
        let refs = referencesIn(node)
        let native = filePoison ?? nativeHit(refs.types)
        let d = TopDecl(kind: .type, definedName: name, extendedType: nil,
                        span: node.trimmedDescription, referencedTypes: refs.types,
                        referencedCalls: refs.calls, referencedMembers: refs.members,
                        reachesNative: native, file: file)
        byName[name, default: []].append(d)
        recordMembers(members, owner: name, into: &memberOwners)
    }

    /// If `src` effectively imports a module that is NOT WASM-self-contained (a
    /// C-sibling target like `CAtomic`, an external library, or a native-only
    /// framework imported UNCONDITIONALLY), return that module name — the file's decls
    /// are poison-tainted (route around them). An import INSIDE a `#if canImport(...)`
    /// / `#if !arch(wasm32)` guard is inert on wasm32 and does NOT taint. A
    /// `#if compiler(>=X)` guard (swift-markdown's `CAtomic`) is NOT a platform guard —
    /// it IS active on wasm — so an import under it DOES taint. Returns nil for a
    /// WASM-safe file.
    static func filePoisonImport(_ src: String) -> String? {
        var guardStack: [Bool] = []   // true = the current `#if` is a platform/arch guard (inert on wasm)
        for rawLine in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = rawLine.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if") {
                guardStack.append(Self.isPlatformGuard(t)); continue
            }
            if t.hasPrefix("#elseif") { if !guardStack.isEmpty { guardStack[guardStack.count - 1] = Self.isPlatformGuard(t) }; continue }
            if t.hasPrefix("#else") { continue }   // keep enclosing guard state
            if t.hasPrefix("#endif") { if !guardStack.isEmpty { guardStack.removeLast() }; continue }
            // An import under a platform/arch guard is inert on wasm — skip it.
            if guardStack.contains(true) { continue }
            guard let mod = importedModuleName(from: t) else { continue }
            if Self.wasmSafeImportModules.contains(mod) { continue }
            return mod
        }
        return nil
    }

    /// A `#if` condition that is a platform / arch guard (`canImport(UIKit)`, `os(iOS)`,
    /// `!arch(wasm32)`, `targetEnvironment(...)`) — its body is inert on wasm32. A
    /// `compiler(>=…)` / `swift(>=…)` / feature condition is NOT a platform guard (it
    /// is active on wasm).
    private static func isPlatformGuard(_ cond: String) -> Bool {
        for tok in ["canImport(", "os(", "arch(", "targetEnvironment(", "_runtime("] {
            if cond.contains(tok) { return true }
        }
        return false
    }

    /// The leading module component of an `import` line in any form (bare, attributed,
    /// access-modified, `import func Foo.bar`), or nil if the line is not an import.
    static func importedModuleName(from line: String) -> String? {
        var t = line.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("@") {
            guard let sp = t.firstIndex(of: " ") else { return nil }
            t = String(t[t.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
        }
        for kw in ["internal ", "public ", "package ", "private ", "fileprivate ", "open "] {
            if t.hasPrefix(kw) { t = String(t.dropFirst(kw.count)); break }
        }
        guard t.hasPrefix("import ") else { return nil }
        var mod = String(t.dropFirst("import ".count)).trimmingCharacters(in: .whitespaces)
        for kind in ["func ", "class ", "struct ", "enum ", "protocol ", "typealias ", "var ", "let "] {
            if mod.hasPrefix(kind) { mod = String(mod.dropFirst(kind.count)); break }
        }
        return mod.split(separator: ".").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
    }

    /// Modules a real-source decl's file may import and still be WASM-self-contained.
    private static let wasmSafeImportModules: Set<String> = [
        "Foundation", "FoundationEssentials", "Swift", "Glibc", "Darwin",
        "_Concurrency", "WASILibc", "SwiftWASILibc",
    ]

    private func recordMembers(_ members: MemberBlockSyntax, owner: String,
                               into memberOwners: inout [String: Set<String>]) {
        for m in members.members {
            if let f = m.decl.as(FunctionDeclSyntax.self) {
                memberOwners[f.name.text, default: []].insert(owner)
            } else if let v = m.decl.as(VariableDeclSyntax.self) {
                for b in v.bindings {
                    if let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                        memberOwners[n, default: []].insert(owner)
                    }
                }
            }
        }
    }

    // MARK: - Closure walk

    /// The extracted closure for a SET of export seeds: the minimal decl spans, the
    /// export seeds that REJECTED (reached a native symbol), and the union of all
    /// source files we pulled FROM (for diagnostics).
    public struct Extraction {
        /// The union decl set's verbatim spans, in a deterministic order.
        public let spans: [String]
        /// Export-seed callees that reached a forced-native symbol — demote these.
        public let rejectedSeeds: [(seed: String, reason: String)]
        /// Number of distinct top-level decls pulled.
        public let declCount: Int
        /// Number of distinct source files the decls came from.
        public let sourceFileCount: Int
    }

    /// Compute the UNION decl closure across `seeds` (each a free-function name, a
    /// `Type.method` dotted name, or a bare type name). A seed whose closure reaches
    /// a `mustStayNative` symbol is reported in `rejectedSeeds` and its decls are NOT
    /// pulled (the export demotes — the wrapper for it is dropped upstream). All other
    /// seeds' decls are unioned into one minimal span set that routes around poison
    /// files. Pulling a TYPE pulls its primary decl + ALL its extensions + the
    /// transitive closure of everything they reference.
    public func extract(seeds: [String], index: Index) -> Extraction {
        // The accumulated UNION across all clean seeds. A decl's identity is a
        // content key (file path + span length + span head/tail) — stable and
        // dedups a type pulled by two seeds, or a type and its own extension.
        var unionKeys = Set<String>()
        var unionOrder: [TopDecl] = []
        var rejected: [(String, String)] = []
        var anyPulled = false

        func contentKey(_ d: TopDecl) -> String {
            "\(d.file.path)#\(d.span.count)#\(d.span.prefix(48))#\(d.span.suffix(24))"
        }

        // Per-seed: walk its OWN closure into a local set; if it reaches a forced-
        // native symbol, REJECT this seed (its decls are discarded so the union stays
        // clean and compilable). Otherwise merge the local closure into the union.
        for seed in seeds {
            var localDecls: [TopDecl] = []
            var localKeys = Set<String>()
            var nativeReason: String? = nil

            // Seed the name worklist. A dotted `Type.method` pulls the receiver type
            // (which carries the method via its decl/extensions) AND the bare method
            // name (resolved through `memberOwners`).
            var nameWork: [String] = []
            let leaf = seed.split(separator: ".").last.map(String.init) ?? seed
            if seed.contains("."), let owner = seed.split(separator: ".").dropLast().last.map(String.init) {
                nameWork.append(owner)
            }
            nameWork.append(leaf)

            var nameVisited = Set<String>()
            // Two classes of decls a name resolves to:
            //  (a) HARD — definitions of the name itself (a free func / type / global /
            //      typealias) + ALL extensions of that name (when it is a type). These
            //      are directly referenced, so a native one REJECTS the seed.
            //  (b) MEMBER-OWNER — a `.member` reference resolves to every type that
            //      DECLARES a member of that name (across overloads). A member name is
            //      AMBIGUOUS (swift-markdown has `RangeReplaceableCollection.ensuringCount`
            //      AND a Markdown table type's `ensuringCount`), and only ONE overload is
            //      actually called. So a native member-owner is SKIPPED (best-effort),
            //      not a seed-killer — taking the clean overload's decls. (The wrapper
            //      that picks the wrong overload would fail the real compile and demote
            //      alone — the arbiter-of-truth net.)
            func hardDecls(_ name: String) -> [TopDecl] {
                var out = index.byName[name] ?? []
                // Pull extensions for a PROJECT type (a bare type reference needs the
                // type's whole surface). But for a SKIPPABLE stdlib type (`Array`,
                // `String`, `Collection`), do NOT pull its extensions here: a bare
                // `Array(...)`/`[T]` reference needs no extension, and a stdlib type
                // routinely has BOTH a clean project extension and a native one
                // (swift-markdown extends `Array` cleanly AND with a `Table`-reaching
                // method). Pulling all of them would reject the seed on the native
                // sibling even though it is never called. The SPECIFIC stdlib-extension
                // member a body DOES call is pulled by the member-owner path (which
                // filters native siblings).
                if !isSkippable(name), let exts = index.extensionsByType[name] {
                    // T0-ISOLATION: drop a type's Codable/reflection extension (an embedded
                    // blocker). A bare type reference doesn't need it; the member-owner path
                    // still pulls the clean members an export actually calls.
                    out += excludeEmbeddedBlockerExtensions
                        ? exts.filter { !isEmbeddedBlockerExtension($0) }
                        : exts
                }
                return out
            }
            func memberOwnerDecls(_ name: String) -> [TopDecl] {
                guard let owners = index.memberOwners[name] else { return [] }
                var out: [TopDecl] = []
                for owner in owners {
                    // Extensions of the owner (where stdlib-extension members like
                    // CryptoSwift's `.batched`, swift-markdown's `.ensuringCount` live).
                    // T0-ISOLATION also filters embedded-blocker (Codable/reflection)
                    // extensions — the export's `.member` is in a CLEAN sibling, and the
                    // Codable `init(from:)` overload is never the one being called.
                    if let exts = index.extensionsByType[owner] {
                        out += exts.filter { $0.reachesNative == nil
                            && !(excludeEmbeddedBlockerExtensions && isEmbeddedBlockerExtension($0)) }
                    }
                    // A member on the owner's PRIMARY decl rides that type, unless it is a
                    // skippable stdlib container (its member then lives in an extension,
                    // already added above).
                    if !isSkippable(owner), let prim = index.byName[owner] { out += prim.filter { $0.reachesNative == nil } }
                }
                return out
            }
            while let name = nameWork.first {
                nameWork.removeFirst()
                if !nameVisited.insert(name).inserted { continue }
                // A forced-native TYPE reference anywhere in the closure rejects the
                // seed (real-source native gate — `cInterop` raw-memory excluded; it
                // compiles to WASM).
                if isRealSourceNative(name) {
                    nativeReason = "reaches native `\(name)` (\(registry.entry(for: name)?.reason ?? ""))"; break
                }
                // (a) HARD decls — a native one rejects the seed.
                var defs = hardDecls(name)
                var hadNative = false
                for d in defs {
                    let key = contentKey(d)
                    if localKeys.contains(key) { continue }
                    if let nat = d.reachesNative {
                        nativeReason = "decl `\(name)` in \(d.file.lastPathComponent) reaches native `\(nat)`"
                        hadNative = true; break
                    }
                    localKeys.insert(key)
                    localDecls.append(d)
                    nameWork.append(contentsOf: d.referencedTypes)
                    nameWork.append(contentsOf: d.referencedCalls)
                    nameWork.append(contentsOf: d.referencedMembers)
                }
                if hadNative { break }
                // (b) MEMBER-OWNER decls — best-effort (a native sibling overload is
                // skipped, not a seed-killer).
                defs = memberOwnerDecls(name)
                for d in defs {
                    let key = contentKey(d)
                    if localKeys.contains(key) { continue }
                    localKeys.insert(key)
                    localDecls.append(d)
                    nameWork.append(contentsOf: d.referencedTypes)
                    nameWork.append(contentsOf: d.referencedCalls)
                    nameWork.append(contentsOf: d.referencedMembers)
                }
            }

            if let reason = nativeReason { rejected.append((seed, reason)); continue }
            for d in localDecls where unionKeys.insert(contentKey(d)).inserted {
                unionOrder.append(d)
                anyPulled = true
            }
        }

        var spans = unionOrder.map { $0.span }
        // Operator + precedence-group declarations are cheap; include them all when
        // any decl shipped (a pulled operator member may need its `operator`/precedence
        // declaration, and an unused one is harmless).
        if anyPulled {
            for op in index.operatorDecls { spans.append(op.span) }
        }
        let files = Set(unionOrder.map { $0.file.path })
        return Extraction(spans: spans, rejectedSeeds: rejected,
                          declCount: unionOrder.count, sourceFileCount: files.count)
    }

    // MARK: - Helpers

    /// Names that are never a project decl to pull: scalars, stdlib containers,
    /// wasm-safe Foundation, module qualifiers, generic single-letter placeholders.
    private func isSkippable(_ name: String) -> Bool {
        if Self.safeLeaves.contains(name) { return true }
        if Self.safeContainers.contains(name) { return true }
        if Self.moduleQualifiers.contains(name) { return true }
        if Self.swiftKeywordsLike.contains(name) { return true }
        // A WASM-safe Foundation value type in the registry needs no pulling.
        if let e = registry.entry(for: name), e.tier == .wasmSafeFoundation { return true }
        // Single uppercase letter (or letter+digit) — a generic placeholder (`T`, `U`, `R0`).
        if name.count <= 2, let f = name.first, f.isUppercase,
           name.dropFirst().allSatisfy({ $0.isNumber }) { return true }
        return false
    }

    /// The first REAL-SOURCE-native symbol among a set of referenced type names, if any.
    private func nativeHit(_ types: Set<String>) -> String? {
        for t in types {
            let nominal = SymbolTable.leadingNominal(t) ?? t
            if isRealSourceNative(nominal) { return nominal }
        }
        return nil
    }

    /// Whether a symbol forces native in the REAL-SOURCE decl-level path. This is the
    /// classifier's `mustStayNative` gate MINUS the categories the real WASM SDK can
    /// actually compile:
    ///   - `.cInterop` (raw memory / `Unsafe*Pointer` / `withUnsafeBytes` / `memcpy`):
    ///     the default engine demotes these because it RECONSTRUCTS types and cannot
    ///     rebuild pointer arithmetic — but real source compiles them to WASM verbatim
    ///     (CryptoSwift's `DataConversion`/`SecureBytes`/`AES` use them throughout and
    ///     compile fine). Excluding this category is what lets decl-level MATCH the
    ///     coarse whole-module gains while still routing around true framework poison.
    /// Genuine framework categories (UIKit/SwiftUI, graphics, networking, storage,
    /// sensors, system services, keychain, notifications, concurrency primitives, app
    /// lifecycle, ObjC interop) remain hard rejects — they have no WASM backing. If a
    /// `.cInterop` symbol turns out NOT to compile (`CVarArg`/`va_list`), the real
    /// compile fails and the convergence loop demotes that wrapper alone (the
    /// arbiter-of-truth guarantee — never a broken module).
    func isRealSourceNative(_ nominal: String) -> Bool {
        // A handful of STDLIB pointer/memory types are registered native (they're
        // miscategorized alongside SQLite/storage, or are cInterop) but compile to
        // WASM verbatim under the real SDK — the real-source path uses them directly.
        if Self.wasmSafePointerTypes.contains(nominal) { return false }
        guard let e = registry.entry(for: nominal), e.tier == .mustStayNative else { return false }
        if e.category == .cInterop { return false }
        return true
    }

    /// Stdlib pointer/memory types that are registered `mustStayNative` (so the default
    /// engine, which reconstructs types, demotes them) but compile to WASM under the
    /// real SDK. The real-source path emits them verbatim, so they must NOT reject.
    private static let wasmSafePointerTypes: Set<String> = [
        "OpaquePointer", "MemoryLayout",
    ]

    private func referencesIn(_ node: Syntax) -> (types: Set<String>, calls: Set<String>, members: Set<String>) {
        let v = DLRefVisitor(viewMode: .sourceAccurate)
        v.walk(node)
        return (v.types, v.calls, v.members)
    }

    private static let safeLeaves: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "Float16", "Float80", "Bool", "String", "Character",
        "Substring", "Decimal", "Date", "URL", "UUID", "Data",
        "TimeInterval", "CGFloat", "Void", "Never", "Any", "AnyObject",
        "Self", "Comparable", "Equatable", "Hashable", "Codable", "Encodable",
        "Decodable", "Error", "Sendable", "CustomStringConvertible",
        "ExpressibleByIntegerLiteral", "ExpressibleByStringLiteral",
        "ExpressibleByArrayLiteral", "ExpressibleByFloatLiteral", "Numeric",
        "SignedNumeric", "BinaryInteger", "FixedWidthInteger", "FloatingPoint",
        "Collection", "Sequence", "Iterator", "IteratorProtocol", "RawRepresentable",
        "Result", "Range", "ClosedRange", "Bundle",
    ]
    private static let safeContainers: Set<String> = ["Array", "Dictionary", "Set", "Optional", "ContiguousArray", "Slice", "ArraySlice"]
    private static let moduleQualifiers: Set<String> = [
        "Swift", "Foundation", "FoundationEssentials", "Darwin", "Glibc",
        "Dispatch", "ObjectiveC", "CoreFoundation", "_Concurrency", "WASILibc",
    ]
    private static let swiftKeywordsLike: Set<String> = ["Type", "Protocol"]
}

/// Reference visitor for the decl-level extractor: collects capitalized type names,
/// bare call names, and `.member` access names. (Independent of the bundler's
/// private `RefVisitor` so the extractor is self-contained and its policy can differ
/// — e.g. it does NOT skip classes/protocols/generics.)
private final class DLRefVisitor: SyntaxVisitor {
    var types: Set<String> = []
    var calls: Set<String> = []
    var members: Set<String> = []
    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        types.insert(node.name.text); return .visitChildren
    }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let ident = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let n = ident.baseName.text
            if let f = n.first, f.isUppercase { types.insert(n) } else { calls.insert(n) }
        } else if let m = node.calledExpression.as(MemberAccessExprSyntax.self),
                  let base = m.base?.as(DeclReferenceExprSyntax.self)?.baseName.text,
                  let f = base.first, f.isUppercase {
            types.insert(base)
            let member = m.declName.baseName.text
            if let mf = member.first, mf.isUppercase { types.insert(member) } else { calls.insert(member) }
        } else if let m = node.calledExpression.as(MemberAccessExprSyntax.self) {
            calls.insert(m.declName.baseName.text)
        }
        return .visitChildren
    }
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.declName.baseName.text
        if let f = name.first, f.isLowercase || f == "_" { members.insert(name) }
        else if let f = name.first, f.isUppercase { types.insert(name) }
        return .visitChildren
    }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let n = node.baseName.text
        if let f = n.first, f.isUppercase { types.insert(n) }
        return .visitChildren
    }
}
