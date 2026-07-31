// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser
import PartitioningEngine

/// Gathers, for a WASM-bound export, the **transitive closure of its
/// dependencies** and emits them ALL into the module's compile unit so it
/// compiles standalone.
///
/// ## The production blocker this fixes
/// The pure-export path used to drop the *whole developer source file* into the
/// WASM compile unit as a "support source". That file references the app's OWN
/// types/helpers/imports (`PhoneNumberType`, `URL`, UIKit, unavailable inits,
/// extensions on framework types …) which are NOT in the compile unit — so
/// `swift build --swift-sdk …` fails with "cannot find type 'X' in scope" and
/// every fragment demotes to native. No shippable module is ever emitted.
///
/// ## What this does instead
/// Starting from each exported function's signature + body, it walks the
/// dependency graph and bundles ONLY the decls actually needed:
///   * **value types** the export uses (struct/enum), transitively over their
///     stored-property types — RECONSTRUCTED as minimal `Codable` value types
///     from the `SymbolTable`'s stored-property metadata (NOT the developer's
///     verbatim source), so extensions, unavailable inits, computed UIKit
///     members and framework-type extensions never enter the module;
///   * **helper free functions / static enum methods** the export calls, emitted
///     verbatim — but only when their own closure is bundlable;
///   * the **exported function itself**, emitted verbatim.
///
/// ## Conservative gate (never ship broken)
/// The closure STOPS at any unbundlable symbol — a reference type
/// (class/actor/protocol), a `mustStayNative` registry symbol, a generic decl, a
/// stored-property type that is neither a WASM-safe scalar/Foundation value nor a
/// bundlable project value type, or anything reaching UIKit/SwiftUI. When an
/// export's closure is not fully bundlable, the export is REJECTED (the build
/// keeps it native). Correctness over coverage.
public struct DependencyClosureBundler {
    public let registry: NativeRegistry

    public init(registry: NativeRegistry = .standard) {
        self.registry = registry
    }

    // MARK: - Decl index

    /// Opaque, parse-once declaration index. Build with `index(for:)`, then reuse
    /// across `closure(...)` / `emitSupportSource(...)` for every export in a build
    /// (one parse of the corpus per `Patch build`).
    public struct Index {
        let decls: [String: [Decl]]
        /// Names the corpus freshly declares as a VALUE type (struct/enum) — used to
        /// recognise an instance method declared in an `extension` of a value type as
        /// a value-type-export target (the scanner can't tell from the extension).
        public var valueTypeNames: Set<String> {
            Set(decls.compactMap { (name, ds) in ds.contains { $0.kind == .valueType } ? name : nil })
        }
        /// All member declarations (methods / computed properties / initializers /
        /// operators / subscripts) of each nominal type, gathered across its primary
        /// declaration AND every `extension`, keyed by the type's simple name. Used
        /// to reconstruct a value type's PURE member surface (so a bundled function
        /// calling `v.dot(...)` / `.acos(...)` resolves).
        let members: [String: [Syntax]]
    }

    /// One top-level (or static-callable) declaration the bundler can emit.
    struct Decl {
        enum Kind { case valueType, function, typealias_, global, refType, protocol_ }
        let kind: Kind
        /// Simple name (`PhoneNumber`, `notPhoneNumber`, `Pricing`).
        let name: String
        /// For a method: the enclosing type name (so we know it's `Type.method`).
        let enclosingType: String?
        /// The syntax node (used to reconstruct / read references).
        let node: Syntax
        /// `struct`/`enum`/`class`/`actor` kind for a type decl.
        let typeKind: SymbolTable.TypeDecl.Kind?
        /// Whether the decl (func/init) carries a generic clause.
        let isGeneric: Bool
    }

    /// The result for one export: the bundled support source (if any) and whether
    /// the export is shippable (its whole closure is bundlable).
    public struct ExportBundle {
        public let exportName: String
        public let shippable: Bool
        /// The single synthesized support-source string (value-type reconstructions
        /// + helper functions). Empty when nothing extra is needed.
        public let supportSource: String
        /// Why it was rejected (for the build report).
        public let rejectionReason: String?
        /// The concrete value types in this export's closure that must be Codable on
        /// the NATIVE side too (so the host bridge can encode/decode them). Used by
        /// the bridge emitter to mirror them.
        public let closureValueTypes: [String]
    }

    /// The closure of ONE export, before emission: shippability + the names of the
    /// value types and the (name, enclosing) keys of the helper functions it needs.
    /// The module-level emitter merges these across all shippable exports into one
    /// deduped support file (so a type used by two exports is emitted once).
    public struct ExportClosure {
        public let exportName: String
        public let shippable: Bool
        public let rejectionReason: String?
        public let neededTypes: [String]
        public let neededFns: [(name: String, enclosing: String?)]
        /// The PURE METHOD / COMPUTED-PROPERTY surface to reconstruct on each
        /// bundled value type: `type → ordered member names`. These are the
        /// non-operator members (methods, computed properties, subscripts) the
        /// shipped functions reach transitively through the type's member call
        /// graph — full bodies, reconstructed into the value type so a function
        /// calling `v.dot(u)` / `v.length` compiles. Operators ride along
        /// separately (sanitized upstream, emitted by `operatorExtensionSource`).
        /// Member-surface reconstruction is reachability-driven and conservatively
        /// gated: a member reaching native/class/protocol/generic/unsafe/`self`-on-
        /// a-free-fn rejects the WHOLE closure (zero false negatives).
        public let neededMembers: [String: [String]]
        public var closureValueTypes: [String] { neededTypes }

        public init(exportName: String, shippable: Bool, rejectionReason: String?,
                    neededTypes: [String], neededFns: [(name: String, enclosing: String?)],
                    neededMembers: [String: [String]] = [:]) {
            self.exportName = exportName; self.shippable = shippable
            self.rejectionReason = rejectionReason; self.neededTypes = neededTypes
            self.neededFns = neededFns; self.neededMembers = neededMembers
        }
    }

    // MARK: - Public entry

    /// Compute the bundle for one pure export, given all parsed source files.
    /// `callee` is the dotted call expression (`PhoneNumber.notPhoneNumber` or
    /// `summarize`); `signatureTypes` are the leading nominal type names that
    /// appear in the export's parameters / return type.
    public func bundle(
        exportName: String,
        callee: String,
        signatureTypes: [String],
        sourceFiles: [URL]
    ) -> ExportBundle {
        let index = index(for: sourceFiles)
        return bundle(exportName: exportName, callee: callee,
                      signatureTypes: signatureTypes, index: index)
    }

    /// Build the parse-once declaration index over the whole corpus.
    public func index(for files: [URL]) -> Index {
        var decls: [String: [Decl]] = [:]
        var members: [String: [Syntax]] = [:]
        for file in files {
            guard let src = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let tree = Parser.parse(source: src)
            collectDecls(Syntax(tree), into: &decls, members: &members, enclosing: nil)
        }
        return Index(decls: decls, members: members)
    }

    /// Validate that a GENERATED wasm candidate source (a mixed-split fragment
    /// file) is self-contained: every capitalized type it references must be a
    /// WASM-safe leaf, a type bundled in the module closure (`bundledTypes`), a
    /// type DEFINED in the same source, or a generic placeholder declared on a
    /// function in the file. Returns the first offending symbol, or nil if
    /// self-contained. A fragment that references an unbundled app type (e.g.
    /// `Country`) — or carries a generic `@_cdecl` export — is NOT shippable and
    /// the pipeline keeps it native instead of feeding the slow demote loop.
    public func fragmentUnboundSymbol(in source: String, bundledTypes: Set<String>) -> String? {
        let tree = Parser.parse(source: source)
        // Names defined locally (types, funcs, generic params) in this fragment file.
        var locallyDefined: Set<String> = []
        var genericParams: Set<String> = []
        collectLocalNames(Syntax(tree), into: &locallyDefined, generics: &genericParams)
        // A generic fragment function (the splitter failed to infer concrete types,
        // emitting `<T0,R0>` placeholders) cannot be a real export and usually
        // carries undefined locals — reject the whole fragment. (Concrete fragments
        // are the ones that ship.)
        if !genericParams.isEmpty { return "<generic fragment>" }
        // A generic `@_cdecl` export is illegal — reject the whole fragment.
        if hasGenericCdeclExport(Syntax(tree)) { return "<generic @_cdecl export>" }
        // No real export at all → nothing to ship; dropping avoids a dead, possibly
        // non-compiling fragment in the unit.
        if !hasCdeclExport(Syntax(tree)) { return "<no @_cdecl export>" }

        // The `@_cdecl` attribute's own name token (`_cdecl`) and `@_cdecl("name")`
        // string aren't type references; the RefVisitor skips attributes.
        let v = RefVisitor(viewMode: .sourceAccurate)
        v.walk(Syntax(tree))
        for t in v.types {
            let nominal = SymbolTable.leadingNominal(t) ?? t
            if isWasmSafeLeaf(nominal) { continue }
            if bundledTypes.contains(nominal) { continue }
            if locallyDefined.contains(nominal) { continue }
            if genericParams.contains(nominal) { continue }
            if Self.knownStdlibTypes.contains(nominal) { continue }
            if Self.abiBoundaryTypes.contains(nominal) { continue }
            return nominal
        }
        return nil
    }

    /// Like `fragmentUnboundSymbol`, but returns EVERY unbound nominal the fragment
    /// references (not just the first), or nil if the fragment is structurally
    /// non-bundlable (generic placeholders / generic `@_cdecl` / no real export). Used
    /// by the mixed-value-type bundling pre-pass: it tries to bundle each unbound
    /// nominal's full closure, and only then re-checks the fragment with the augmented
    /// bundled-type set. The empty set means "self-contained already".
    public func fragmentUnboundSymbols(in source: String, bundledTypes: Set<String>) -> Set<String>? {
        let tree = Parser.parse(source: source)
        var locallyDefined: Set<String> = []
        var genericParams: Set<String> = []
        collectLocalNames(Syntax(tree), into: &locallyDefined, generics: &genericParams)
        if !genericParams.isEmpty { return nil }
        if hasGenericCdeclExport(Syntax(tree)) { return nil }
        if !hasCdeclExport(Syntax(tree)) { return nil }
        let v = RefVisitor(viewMode: .sourceAccurate)
        v.walk(Syntax(tree))
        var out: Set<String> = []
        for t in v.types {
            let nominal = SymbolTable.leadingNominal(t) ?? t
            if isWasmSafeLeaf(nominal) { continue }
            if bundledTypes.contains(nominal) { continue }
            if locallyDefined.contains(nominal) { continue }
            if genericParams.contains(nominal) { continue }
            if Self.knownStdlibTypes.contains(nominal) { continue }
            if Self.abiBoundaryTypes.contains(nominal) { continue }
            out.insert(nominal)
        }
        return out
    }

    private func hasCdeclExport(_ node: Syntax) -> Bool {
        let v = CdeclPresenceVisitor(viewMode: .sourceAccurate)
        v.walk(node)
        return v.found
    }
    private final class CdeclPresenceVisitor: SyntaxVisitor {
        var found = false
        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            for attr in node.attributes {
                let name = attr.as(AttributeSyntax.self)?.attributeName.trimmedDescription
                if name == "_cdecl" {
                    // Don't count the allocator (patch_malloc/patch_free) as a shippable export.
                    if node.name.text != "patch_malloc" && node.name.text != "patch_free" { found = true }
                }
            }
            return .visitChildren
        }
    }

    private static let knownStdlibTypes: Set<String> = [
        "Array", "Dictionary", "Set", "Optional", "Result", "Range", "ClosedRange",
        "String", "Substring", "Character", "Bool",
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float",
        "Data", "Date", "Decimal", "UUID", "URL", "Void",
    ]

    /// Raw-pointer types that the emitted `@_cdecl` boundary ITSELF introduces
    /// (allocator `patch_malloc`/`patch_free`, and the buffer-marshalling glue that
    /// copies Codable payloads across the WASM boundary — see `CodeEmitter`). They
    /// are NOT references to app symbols; they are WASM-stdlib types present in the
    /// WebAssembly SDK and compile unchanged. Without this allow-list the unbound-
    /// symbol gate mistakes Patch's own ABI plumbing for an unbundled app type and
    /// rejects an otherwise self-contained fragment (the dominant false-positive).
    private static let abiBoundaryTypes: Set<String> = [
        "UnsafeMutableRawPointer", "UnsafeRawPointer",
        "UnsafeMutablePointer", "UnsafePointer",
        "UnsafeRawBufferPointer", "UnsafeMutableRawBufferPointer",
        "UnsafeBufferPointer", "UnsafeMutableBufferPointer",
        "OpaquePointer",
    ]

    /// Types that EXIST in the WASM Foundation SDK and must be EXTENDED, never
    /// redeclared as an `enum` namespace (which shadows the real type and breaks
    /// every use site). Covers the stdlib types plus Foundation's geometry/number
    /// types that swift-corelibs-foundation provides on non-Apple platforms.
    private static let knownSystemTypes: Set<String> = knownStdlibTypes.union([
        "CGFloat", "CGPoint", "CGSize", "CGRect", "CGVector", "CGAffineTransform",
        "NSNumber", "IndexPath", "IndexSet", "CharacterSet", "NSRange",
        // Foundation date/locale/format types the wasm SDK's swift-corelibs-foundation
        // PROVIDES. They were missing here, so a namespace walk declared `enum Calendar
        // {}` / `enum Locale {}` / `enum TimeZone {}` that SHADOWED the real Foundation
        // type and broke every use site (SwiftDate's `Calendar.Component`, `.current`;
        // the dominant SwiftDate demote). Verified present in swift-6.3.2-RELEASE_wasm:
        // each compiles in a standalone reactor module. Listing them here makes the
        // pipeline EXTEND (never redeclare) them, so nested types / statics resolve.
        // SCOPE: only types extremely unlikely to be re-declared by an app under the
        // SAME name (deliberately excludes `Notification`/`ComparisonResult` — apps do
        // define those: isowords `struct Notification`, BigInt `enum ComparisonResult`).
        // A locally-declared type still reconstructs (local decl wins), so this only
        // affects the namespace-shadow + unbound-symbol gates.
        "Calendar", "Locale", "TimeZone", "DateComponents", "DateInterval",
        "DateFormatter", "NumberFormatter", "ISO8601DateFormatter",
    ])

    /// System/stdlib types that exist in the WASM SDK (extend, never redeclare).
    /// Exposed so the pipeline can exclude them when declaring namespace enums.
    public static var systemTypeNames: Set<String> { knownSystemTypes }

    private func collectLocalNames(_ node: Syntax, into names: inout Set<String>, generics: inout Set<String>) {
        for child in node.children(viewMode: .sourceAccurate) {
            if let s = child.as(StructDeclSyntax.self) { names.insert(s.name.text) }
            else if let e = child.as(EnumDeclSyntax.self) { names.insert(e.name.text) }
            else if let c = child.as(ClassDeclSyntax.self) { names.insert(c.name.text) }
            else if let f = child.as(FunctionDeclSyntax.self) {
                names.insert(f.name.text)
                if let gp = f.genericParameterClause {
                    for p in gp.parameters { generics.insert(p.name.text) }
                }
            }
            collectLocalNames(child, into: &names, generics: &generics)
        }
    }

    private func hasGenericCdeclExport(_ node: Syntax) -> Bool {
        let v = CdeclGenericVisitor(viewMode: .sourceAccurate)
        v.walk(node)
        return v.found
    }
    private final class CdeclGenericVisitor: SyntaxVisitor {
        var found = false
        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            let hasCdecl = node.attributes.contains { attr in
                attr.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "_cdecl"
            }
            if hasCdecl && node.genericParameterClause != nil { found = true }
            return .visitChildren
        }
    }

    /// Public closure entry over the opaque `Index`.
    public func closure(
        exportName: String, callee: String, signatureTypes: [String], index: Index
    ) -> ExportClosure {
        closure(exportName: exportName, callee: callee, signatureTypes: signatureTypes,
                index: index.decls, members: index.members)
    }

    /// Fix A integration: a TYPE-rooted closure with NO function seed, for an
    /// exported OPERATOR. The operator function can't be resolved as a free-function
    /// callee (operators are never indexed as callees), but it IS recorded as a pure
    /// MEMBER of its defining value type — so bundling the type (and its boundary
    /// signature types) carries the operator along via the type reconstruction. The
    /// closure is shippable iff every type in the closure is a bundlable value type.
    public func closureForTypes(
        exportName: String, signatureTypes: [String], index: Index
    ) -> ExportClosure {
        closure(exportName: exportName, callee: "", signatureTypes: signatureTypes,
                index: index.decls, members: index.members)
    }

    /// Operator-export closure: like `closureForTypes`, but also seeds the
    /// member-surface walk from the OPERATOR's body so the pure members it calls
    /// (`==` → `compare` → `count`/`subscript`) are reconstructed onto the type and the
    /// operator is not dropped as "reads unreconstructed member".
    public func closureForOperator(
        exportName: String, operatorToken: String, definingType: String,
        signatureTypes: [String], index: Index
    ) -> ExportClosure {
        closure(exportName: exportName, callee: "", signatureTypes: signatureTypes,
                index: index.decls, members: index.members,
                operatorSeed: (type: definingType, token: operatorToken))
    }

    /// Public module-level emit over the opaque `Index`.
    public func emitSupportSource(
        types: [String], fns: [(name: String, enclosing: String?)], index: Index,
        surfaceMembers: [String: [String]] = [:],
        header: String = "bundled dependency closure"
    ) -> String {
        emitSupportSource(types: types, fns: fns, index: index.decls, members: index.members,
                          surfaceMembers: surfaceMembers, header: header)
    }

    /// Emit ONLY the reconstructed value types (with their pure member surface) for
    /// the merged module closure. These go in the SHARED support file (always
    /// self-contained, never demoted). Helper/seed functions are emitted per-export
    /// via `emitExportFunctions` so a non-self-contained helper demotes alone.
    /// `surfaceMembers` carries the reachability-gated pure method/computed-property
    /// surface (`type → member names`) to reconstruct onto each value type.
    public func emitValueTypesSource(types: [String], index: Index,
                                     surfaceMembers: [String: [String]] = [:],
                                     header: String) -> String {
        var out = ""
        out += "// Auto-generated by Patch — \(header).\n"
        out += "// Codable reconstructions of the value types (with their pure member surface).\n"
        out += "// DO NOT EDIT.\n"
        // Foundation value types (Decimal/Date/URL/UUID/Data) + Codable synthesis
        // need Foundation in the compile unit (the corpus boundary forces T2).
        out += "import Foundation\n\n"
        for t in types.sorted() {
            guard let decl = resolveType(t, index: index.decls) else { continue }
            out += synthesizeValueType(decl, members: index.members,
                                       surfaceMembers: surfaceMembers, index: index.decls) + "\n\n"
        }
        return out
    }

    /// Emit the Codable reconstruction of a SINGLE value type into its own
    /// compile unit. Returns nil if the type can't be resolved. Splitting the
    /// reconstructed types one-per-file lets the convergence loop ISOLATE a
    /// broken reconstruction (e.g. a non-Codable / `#if !$Embedded`-guarded type):
    /// instead of one shared `_PatchClosure.swift` failure killing the whole
    /// module, only the candidates that reference the broken type demote, and the
    /// independent candidates still ship.
    public func emitSingleValueTypeSource(type t: String, index: Index,
                                          surfaceMembers: [String: [String]] = [:],
                                          bundledTypes: [String] = [],
                                          header: String) -> String? {
        guard let decl = resolveType(t, index: index.decls) else { return nil }
        // The full bundled value-type context (so custom-init eligibility resolves
        // cross-type construction, e.g. `Plane`'s init using `Vector`). Falls back to
        // the surface keys + this type when the caller does not supply the set.
        var ctx = Set(bundledTypes.filter { resolveType($0, index: index.decls)?.kind == .valueType })
        if ctx.isEmpty { ctx = Set(surfaceMembers.keys) }
        ctx.insert(t)
        var out = "// Auto-generated by Patch — \(header) (\(t)).\n// DO NOT EDIT.\n"
        out += "import Foundation\n\n"
        out += synthesizeValueType(decl, members: index.members,
                                   surfaceMembers: surfaceMembers, index: index.decls,
                                   bundledValueTypes: ctx) + "\n"
        return out
    }

    /// Emit the helper/seed FUNCTIONS for ONE export (free functions + static-helper
    /// enum namespaces), to be appended into that export's own candidate file. The
    /// value types are already in the shared support file (`bundledTypes`).
    /// `surfaceMembers` (type → member names already reconstructed into the shared
    /// value-type surface) are SKIPPED here, so a static method that is both a seed
    /// export AND a member-surface dependency (e.g. Euclid `Angle.radians`, pulled in
    /// by `Angle.remainder`) is emitted exactly ONCE — never duplicated into two
    /// `extension Type { static func … }` blocks (a `invalid redeclaration` link
    /// error that demotes the whole module).
    public func emitExportFunctions(fns: [(name: String, enclosing: String?)],
                                    index: Index, bundledTypes: Set<String>,
                                    surfaceMembers: [String: [String]] = [:],
                                    declaredExtensionTypes: Set<String> = []) -> String {
        emitFunctions(fns, index: index.decls, bundledTypes: bundledTypes,
                      surfaceMembers: surfaceMembers, declaredExtensionTypes: declaredExtensionTypes)
    }

    /// Reusable single-export bundle (used by tests). Computes the closure and
    /// emits a self-contained support source for just this export.
    func bundle(
        exportName: String,
        callee: String,
        signatureTypes: [String],
        index: Index
    ) -> ExportBundle {
        let c = closure(exportName: exportName, callee: callee, signatureTypes: signatureTypes, index: index)
        guard c.shippable else {
            return ExportBundle(exportName: exportName, shippable: false, supportSource: "",
                                rejectionReason: c.rejectionReason, closureValueTypes: [])
        }
        let src = emitSupportSource(types: c.neededTypes, fns: c.neededFns, index: index,
                                    surfaceMembers: c.neededMembers,
                                    header: "bundled dependency closure for export `\(exportName)`")
        return ExportBundle(exportName: exportName, shippable: true, supportSource: src,
                            rejectionReason: nil, closureValueTypes: c.neededTypes.sorted())
    }

    /// Compute the dependency closure of one export WITHOUT emitting — returns the
    /// needed value types + helper functions so the module-level emitter can merge
    /// them across all exports (dedup) into a single support file.
    func closure(
        exportName: String,
        callee: String,
        signatureTypes: [String],
        index: [String: [Decl]],
        members: [String: [Syntax]],
        operatorSeed: (type: String, token: String)? = nil
    ) -> ExportClosure {
        let calleeSimple = callee.split(separator: ".").last.map(String.init) ?? callee
        let enclosing: String? = callee.contains(".")
            ? callee.split(separator: ".").dropLast().last.map(String.init) : nil

        var needTypes: Set<String> = []
        var visitedFns: Set<String> = []
        var emittedTypeOrder: [String] = []
        var emittedFnOrder: [(name: String, enclosing: String?)] = []
        var rejection: String? = nil
        // Member-surface seeds: explicit `.member` names + implicit-self bare names
        // referenced in any needed function/member body, to follow the value-type
        // method/computed-property call graph.
        var memberSeeds: Set<String> = []

        // A type-only closure (empty callee, Fix A operator path) seeds from the
        // signature types alone — the operator rides along with its defining type's
        // reconstructed pure member surface, so there is no function to seed.
        var fnWork: [Decl] = []
        // The receiver method of an exported instance method (`Vector.dot`): seed the
        // member-surface walk with it directly so its body (and the members it calls)
        // are reconstructed onto the bundled type.
        var receiverMethodSeed: (type: String, member: String)? = nil
        if !callee.isEmpty {
            // An INSTANCE-method export (`<Type>.<method>` where Type is a bundlable
            // value type and the member is a non-`static` instance method/computed
            // property) is NOT a free/static function — resolve it as a MEMBER and
            // drive the member-surface walk. A STATIC factory (`PhoneNumber
            // .notPhoneNumber()`) is still a seed FUNCTION (emitted as an `extension`
            // by `emitFunctions`), so it must take the free/static path below.
            if let enclosing, let typeDecl = resolveType(enclosing, index: index),
               typeDecl.kind == .valueType,
               let m = memberDecl(named: calleeSimple, of: enclosing, members: members),
               !memberIsStatic(m) {
                receiverMethodSeed = (type: enclosing, member: calleeSimple)
                needTypes.insert(enclosing)
            } else {
                guard let seedFn = resolveFunction(name: calleeSimple, enclosing: enclosing, index: index) else {
                    return ExportClosure(exportName: exportName, shippable: false,
                                         rejectionReason: "could not locate decl for \(callee)",
                                         neededTypes: [], neededFns: [])
                }
                if seedFn.isGeneric {
                    return ExportClosure(exportName: exportName, shippable: false,
                                         rejectionReason: "\(callee) is generic — cannot be a @_cdecl export",
                                         neededTypes: [], neededFns: [])
                }
                fnWork = [seedFn]
                emittedFnOrder.append((name: seedFn.name, enclosing: seedFn.enclosingType))
                visitedFns.insert(fnKey(seedFn))
            }
        }
        for t in signatureTypes { needTypes.insert(t) }

        // OPERATOR EXPORT (Fix A): an exported operator (`==`, `<`, `+`) has no function
        // seed — its body rides along with the type reconstruction. To reconstruct the
        // members the operator's BODY reaches (e.g. `==` calls `BigUInt.compare`, which
        // reads `count` and `subscript`), seed the member-surface walk with the
        // operator body's member references. Without this the operator is dropped as
        // "reads unreconstructed member" even though those members are pure + bundlable.
        if let opSeed = operatorSeed,
           let opNode = operatorMemberNode(token: opSeed.token, of: opSeed.type, members: members) {
            if bodyHasForcedNativeInterop(opNode) {
                rejection = "operator `\(opSeed.token)` uses forced-native interop"
            } else {
                let (explicitMembers, _) = memberReferences(in: opNode)
                memberSeeds.formUnion(explicitMembers)
                let (opTypes, _) = references(in: opNode)
                for t in opTypes { needTypes.insert(t) }
            }
        }

        while let fn = fnWork.first {
            fnWork.removeFirst()
            // Forced-native interop in a helper body (`@objc`/`#selector`/unsafe
            // pointer) → not bundlable.
            if bodyHasForcedNativeInterop(fn.node) {
                rejection = "helper `\(fn.name)` uses forced-native interop (@objc/#selector/unsafe)"
                break
            }
            // Self-containment: a free/static function that reads instance state
            // (`self.x`, or a bare identifier that is an instance property of its
            // enclosing class — e.g. SwiftyBeaver's static `countDestinations()`
            // reading `queue`/`destinations`) is NOT pure and cannot be lifted as a
            // standalone export. Reject it (kept native). Instance methods on value
            // types legitimately use `self`, so this only applies to free/static fns.
            let fnIsStatic = (fn.node.as(FunctionDeclSyntax.self)?.modifiers.contains {
                ["static", "class"].contains($0.name.text) }) ?? false
            let fnIsFreeOrStatic = (fn.enclosingType == nil) || fnIsStatic
            if fnIsFreeOrStatic, let leak = freeFunctionInstanceLeak(fn, index: index) {
                rejection = "function `\(fn.name)` reads instance state `\(leak)` — not pure/standalone"
                break
            }
            let (types, calls) = references(in: fn.node)
            for t in types {
                // A referenced type that is a known `mustStayNative` registry symbol
                // (UIKit, NSRegularExpression, …) cannot be bundled.
                if let nominal = SymbolTable.leadingNominal(t) ?? Optional(t),
                   let e = registry.entry(for: nominal), e.tier == .mustStayNative {
                    rejection = "helper `\(fn.name)` references native `\(nominal)`"
                    break
                }
                needTypes.insert(t)
            }
            if rejection != nil { break }
            // Seed the member-surface walk with the member references in this body
            // (`v.dot(u)`, `.length`). A free function calling a value-type method
            // now follows that method into the reconstruction instead of demoting.
            let (explicitMembers, _) = memberReferences(in: fn.node)
            memberSeeds.formUnion(explicitMembers)
            for c in calls {
                if let helper = resolveFunction(name: c, enclosing: nil, index: index),
                   !visitedFns.contains(fnKey(helper)) {
                    if helper.isGeneric { rejection = "helper \(c) is generic"; break }
                    visitedFns.insert(fnKey(helper))
                    fnWork.append(helper)
                    emittedFnOrder.append((name: helper.name, enclosing: helper.enclosingType))
                }
            }
            if rejection != nil { break }
        }

        // ---- Member-surface walk (the value-type METHOD / COMPUTED-PROPERTY graph)
        // Reconstruct, for each bundled value type, the pure members the shipped
        // logic reaches transitively. A member body may pull in NEW types (its
        // return type / locals) and NEW members (sibling/cross-type calls); the
        // walk feeds those back into `needTypes` and the member worklist. ANY member
        // reaching native/class/protocol/generic/unsafe/`self`-misuse rejects the
        // WHOLE closure (zero false negatives — never ship a method that transitively
        // touches native). Runs BEFORE the type-validation walk so member-introduced
        // types are validated too.
        var memberOrder: [String: [String]] = [:]
        if rejection == nil {
            let r = resolveMemberSurface(
                receiverSeed: receiverMethodSeed, memberSeeds: memberSeeds,
                needTypes: &needTypes, members: members, index: index)
            if let reason = r.rejection { rejection = reason }
            else { memberOrder = r.order }
        }

        if rejection == nil {
            var typeWork = Array(needTypes)
            var visitedTypes: Set<String> = []
            while let t = typeWork.first {
                typeWork.removeFirst()
                let rawNominal = SymbolTable.leadingNominal(t) ?? t
                // Resolve a typealias (`Word` → `UInt`) before validating, so a member/
                // operator body referencing an aliased scalar isn't rejected as an
                // unbundlable type. Scalar-preference disambiguates same-named aliases.
                let nominal = resolveAliasChain(rawNominal, owner: nil, index: index)
                guard visitedTypes.insert(nominal).inserted else { continue }
                if isWasmSafeLeaf(nominal) { continue }
                // A module-qualifier (`Foundation`, `Swift`, …) over-collected by the
                // ref scan — not a real bundlable-type dependency. Skip, don't reject.
                if isNonDependencyTypeToken(nominal) { continue }
                // A native registry symbol referenced as a type → not bundlable.
                if let e = registry.entry(for: nominal), e.tier == .mustStayNative {
                    rejection = "type `\(nominal)` is native (\(e.reason))"; break
                }
                guard let decl = resolveType(nominal, index: index) else {
                    rejection = "type `\(nominal)` is not a bundlable value type (unknown/native)"
                    break
                }
                if decl.kind == .refType {
                    rejection = "type `\(nominal)` is a class/actor (reference type) — not bundlable"; break
                }
                if decl.kind == .protocol_ {
                    rejection = "type `\(nominal)` is a protocol — not bundlable"; break
                }
                if decl.isGeneric {
                    rejection = "type `\(nominal)` is generic — not bundlable"; break
                }
                if !emittedTypeOrder.contains(nominal) { emittedTypeOrder.append(nominal) }
                for (pt, ok) in storedPropertyLeafTypes(of: decl, index: index) {
                    if !ok { rejection = "type `\(nominal)` stored-property type `\(pt)` is not WASM-safe/bundlable"; break }
                    typeWork.append(pt)
                }
                if rejection != nil { break }
            }
        }

        if let rejection {
            return ExportClosure(exportName: exportName, shippable: false,
                                 rejectionReason: rejection, neededTypes: [], neededFns: [])
        }
        // Keep only member maps for types actually emitted.
        var finalMembers: [String: [String]] = [:]
        for t in emittedTypeOrder {
            if let order = memberOrder[t], !order.isEmpty { finalMembers[t] = order }
        }
        return ExportClosure(exportName: exportName, shippable: true, rejectionReason: nil,
                             neededTypes: emittedTypeOrder, neededFns: emittedFnOrder,
                             neededMembers: finalMembers)
    }

    // MARK: - Member-surface resolution (collect → fixpoint self-containment)

    struct MemberSurfaceResult {
        /// type → ordered member names to reconstruct (empty on rejection).
        let order: [String: [String]]
        /// Non-nil → the export is NOT shippable; this is the human-readable reason.
        let rejection: String?
    }

    /// Resolve the PURE MEMBER SURFACE to reconstruct for a closure, in two phases:
    ///
    /// 1. **Collect** (optimistic): transitively gather every member the shipped
    ///    logic reaches through the value-type member call graph (seed receiver
    ///    method + member references in needed bodies + sibling/cross-type member
    ///    calls). During collection a member is HARD-rejected only for an
    ///    *intrinsically* unbundlable property (native ref / generic / mutating /
    ///    async / unsafe / array-literal construction) — these reject the whole
    ///    export immediately. Member-introduced types feed `needTypes`.
    ///
    /// 2. **Fixpoint self-containment**: a collected member is only RECONSTRUCTABLE
    ///    if EVERY symbol its body references is accounted for in the reconstruction:
    ///    a stored field of a bundled type, another reconstructable member, a
    ///    reconstructed operator on a bundled type, a memberwise-init call (labels
    ///    matching the stored fields), a param/local, or a safe stdlib/global. A
    ///    member referencing a free global (`epsilon`), an unreconstructed static
    ///    (`.zero`), a custom init (`Plane(unchecked:)`), a dropped operator, or a
    ///    `.member` we don't carry is NOT self-contained → dropped. Dropping a member
    ///    invalidates callers that needed it → iterate to a fixpoint. If a member the
    ///    shipped logic DIRECTLY needs is dropped, the export is rejected (kept
    ///    native). This guarantees the reconstructed surface always COMPILES (zero
    ///    false negatives — never ships a method that can't build / touches native).
    func resolveMemberSurface(
        receiverSeed: (type: String, member: String)?,
        memberSeeds: Set<String>,
        needTypes: inout Set<String>,
        members: [String: [Syntax]],
        index: [String: [Decl]]
    ) -> MemberSurfaceResult {
        func valueTypesInClosure() -> [String] {
            // Bundled value types in the closure, EXPANDED transitively through their
            // stored-property field types (so a member like `BigInt.isZero { magnitude
            // .isZero }` can resolve `.isZero` onto BigUInt — the field type — even
            // before the later type-validation walk adds BigUInt to `needTypes`).
            var result: Set<String> = []
            var work: [String] = needTypes.compactMap { SymbolTable.leadingNominal($0) ?? $0 }
            while let t = work.first {
                work.removeFirst()
                let n = SymbolTable.leadingNominal(t) ?? t
                guard result.insert(n).inserted,
                      let d = resolveType(n, index: index), d.kind == .valueType else { continue }
                // Enqueue this type's stored-property field types (BigUInt for BigInt).
                for (pt, _) in storedPropertyLeafTypes(of: d, index: index) {
                    let pn = SymbolTable.leadingNominal(pt) ?? pt
                    if !result.contains(pn) { work.append(pn) }
                }
            }
            return result.filter { resolveType($0, index: index)?.kind == .valueType }
        }

        // ---- Phase 1: collect transitively reachable members (optimistic) --------
        struct MKey: Hashable { let type: String; let name: String }
        var collected: [MKey] = []        // members that PASSED the intrinsic gate.
        var collectedSet: Set<MKey> = []  // dedup of collected (reconstructable) members.
        var seen: Set<MKey> = []          // dedup of EVERY enqueued key (incl. rejected).
        var work: [MKey] = []
        // `directlyNeeded`: members the shipped FUNCTION logic needs directly (the
        // receiver method + members referenced in needed bodies). If one of these is
        // later dropped, the export is rejected (not silently shipped without it).
        var directlyNeeded: Set<MKey> = []
        func enqueue(_ k: MKey, direct: Bool) {
            if direct { directlyNeeded.insert(k) }
            guard seen.insert(k).inserted else { return }
            work.append(k)
        }
        // The receiver method of an exported instance method MUST reconstruct (its
        // export has no other body) → directly needed. Member references in a free/
        // helper FUNCTION body are NOT directly needed: a function-body member name is
        // resolved by NAME across all bundled types (so it over-collects, e.g. an enum
        // case `.notParsed` colliding with a same-named computed property). If such a
        // spurious member can't reconstruct, it is simply dropped — the function then
        // either compiles (it didn't really need it) or fails to compile and demotes
        // ALONE via the per-export seed file (never poisons the shared surface).
        if let s = receiverSeed { enqueue(MKey(type: s.type, name: s.member), direct: true) }
        for name in memberSeeds {
            for t in valueTypesInClosure() where memberDecl(named: name, of: t, members: members) != nil {
                enqueue(MKey(type: t, name: name), direct: false)
            }
        }
        var hardRejection: String? = nil
        while let item = work.first {
            work.removeFirst()
            guard let mdecl = memberDecl(named: item.name, of: item.type, members: members) else { continue }
            if let reason = memberRejection(mdecl, ownerType: item.type, index: index) {
                // An intrinsically unbundlable member the shipped logic directly needs
                // rejects the export. (A transitively-reached one is dropped here and
                // the fixpoint propagates the drop to its callers.)
                if directlyNeeded.contains(item) {
                    hardRejection = "member `\(item.type).\(item.name)` \(reason)"; break
                }
                // NOT reconstructable → never enters `collected`; the fixpoint then
                // drops any member that references it (it isn't available).
                continue
            }
            // Passed the intrinsic gate → a candidate reconstructable member.
            if collectedSet.insert(item).inserted { collected.append(item) }
            let (mtypes, _) = references(in: mdecl)
            for t in mtypes {
                if let nominal = SymbolTable.leadingNominal(t) ?? Optional(t),
                   let e = registry.entry(for: nominal), e.tier == .mustStayNative {
                    if directlyNeeded.contains(item) {
                        hardRejection = "member `\(item.type).\(item.name)` references native `\(nominal)`"; break
                    }
                    continue
                }
                needTypes.insert(t)
            }
            if hardRejection != nil { break }
            let (explicit, bare) = memberReferences(in: mdecl)
            for name in explicit {
                for t in valueTypesInClosure() where memberDecl(named: name, of: t, members: members) != nil {
                    enqueue(MKey(type: t, name: name), direct: false)
                }
            }
            for name in bare where memberDecl(named: name, of: item.type, members: members) != nil {
                enqueue(MKey(type: item.type, name: name), direct: false)
            }
        }
        if let hardRejection { return MemberSurfaceResult(order: [:], rejection: hardRejection) }

        // ---- Phase 2: fixpoint self-containment ----------------------------------
        let bundledValueTypes = Set(valueTypesInClosure())
        // Per-type: stored fields, reconstructed-operator tokens, member names that
        // collected (candidate reconstructable members), and memberwise-init labels.
        var storedFields: [String: Set<String>] = [:]
        var operatorSet: [String: Set<String>] = [:]
        var memberwiseLabels: [String: [String]] = [:]
        for t in bundledValueTypes {
            storedFields[t] = storedFieldNamesFromMembers(t, members: members)
            operatorSet[t] = reconstructedOperatorTokens(t, members: members, index: index)
            memberwiseLabels[t] = storedFieldOrderedNames(t, members: members)
        }
        // The set of (type,member) currently believed reconstructable.
        var live = Set(collected)
        // Member names available on a type (live members + stored fields) — for
        // `.member` validation.
        func memberAvailable(_ type: String, _ name: String) -> Bool {
            if storedFields[type]?.contains(name) == true { return true }
            return live.contains(MKey(type: type, name: name))
        }
        // The signatures of the custom inits the reconstruction WILL emit per type,
        // recomputed each pass from the current live surface (so a member calling
        // `Plane(unchecked:w:)` is accepted once that init is proven emittable). The
        // gate and the emitter share `eligibleCustomInits`, so acceptance ⇒ emission.
        func currentSurface() -> [String: [String]] {
            var s: [String: [String]] = [:]
            for k in collected where live.contains(k) { s[k.type, default: []].append(k.name) }
            return s
        }
        func currentInitSigs() -> [String: [InitSig]] {
            var sigs: [String: [InitSig]] = [:]
            let surface = currentSurface()
            for t in bundledValueTypes {
                let inits = eligibleCustomInits(for: t, bundledValueTypes: bundledValueTypes,
                                                surface: surface, members: members, index: index)
                if !inits.isEmpty { sigs[t] = inits.map { initSig(of: $0) } }
            }
            return sigs
        }
        var changed = true
        var dropReason: [MKey: String] = [:]
        while changed {
            changed = false
            let initSigs = currentInitSigs()
            for k in collected where live.contains(k) {
                guard let mdecl = memberDecl(named: k.name, of: k.type, members: members) else {
                    live.remove(k); changed = true; continue
                }
                if let reason = memberSelfContainmentFailure(
                    mdecl, ownerType: k.type, bundledValueTypes: bundledValueTypes,
                    storedFields: storedFields, operatorSet: operatorSet,
                    memberwiseLabels: memberwiseLabels, liveMember: memberAvailable,
                    index: index, members: members, customInitSigs: initSigs) {
                    live.remove(k); dropReason[k] = reason; changed = true
                }
            }
        }
        // A directly-needed member that did not survive → reject the export.
        for k in directlyNeeded where !live.contains(k) {
            let why = dropReason[k] ?? "not self-contained"
            return MemberSurfaceResult(order: [:],
                rejection: "member `\(k.type).\(k.name)` \(why) — cannot reconstruct standalone")
        }
        // Build the ordered surviving surface, preserving discovery order.
        var order: [String: [String]] = [:]
        for k in collected where live.contains(k) {
            if !(order[k.type]?.contains(k.name) ?? false) { order[k.type, default: []].append(k.name) }
        }
        return MemberSurfaceResult(order: order, rejection: nil)
    }

    /// Emit a single self-contained support source from a merged, deduped set of
    /// value types + helper functions (module level). The seed-export functions
    /// are included in `fns`. Value types are reconstructed as minimal Codable
    /// structs/enums; functions are emitted verbatim (free) / regrouped into a
    /// synthesized enclosing enum (static methods).
    func emitSupportSource(
        types: [String],
        fns: [(name: String, enclosing: String?)],
        index: [String: [Decl]],
        members: [String: [Syntax]],
        surfaceMembers: [String: [String]] = [:],
        header: String = "bundled dependency closure"
    ) -> String {
        var out = ""
        out += "// Auto-generated by Patch — \(header).\n"
        out += "// Codable reconstructions of the value types (with their pure member\n"
        out += "// surface) + the pure logic the shipped exports need, so the WASM compile\n"
        out += "// unit is self-contained. DO NOT EDIT.\n\n"
        let bundledValueTypes = Set(types.filter { resolveType($0, index: index)?.kind == .valueType })
        for t in types.sorted() {
            guard let decl = resolveType(t, index: index) else { continue }
            out += synthesizeValueType(decl, members: members,
                                       surfaceMembers: surfaceMembers, index: index,
                                       bundledValueTypes: bundledValueTypes) + "\n\n"
        }
        out += emitFunctions(fns, index: index, bundledTypes: Set(types))
        return out
    }

    /// If a free/static function reads instance state (so it cannot be a standalone
    /// pure export), return the offending name; else nil. Catches `self.x` reads and
    /// bare identifiers that resolve to neither a param, a local binding, a project
    /// free function/global, an enum case, nor a known stdlib name — i.e. an
    /// instance property of the enclosing type leaked into a static method.
    private func freeFunctionInstanceLeak(_ fn: Decl, index: [String: [Decl]]) -> String? {
        guard let f = fn.node.as(FunctionDeclSyntax.self) else { return nil }
        let v = ScopeVisitor(viewMode: .sourceAccurate)
        // Params are in scope.
        for p in f.signature.parameterClause.parameters {
            v.bound.insert((p.secondName ?? p.firstName).text)
        }
        v.walk(Syntax(f))
        // A free/static function reading `self.…` is reading instance state.
        if v.usedSelf { return "self" }
        // A bare lowercase identifier READ that resolves to nothing in scope (not a
        // param/local/global function/type/stdlib) is an instance-property leak
        // (e.g. SwiftyBeaver's static `countDestinations()` reading `queue` /
        // `destinations`). Reject — not a standalone pure export.
        for name in v.reads where !v.bound.contains(name)
            && index[name] == nil && !Self.knownGlobals.contains(name) {
            return name
        }
        return nil
    }

    /// stdlib / common free identifiers a pure function may reference unbound.
    private static let knownGlobals: Set<String> = [
        "print", "abs", "min", "max", "swap", "assert", "assertionFailure",
        "precondition", "preconditionFailure", "fatalError", "zip", "stride",
        "repeatElement", "sequence", "Swift", "true", "false", "nil",
        "sqrt", "cbrt", "pow", "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
        "floor", "ceil", "round", "log", "log2", "log10", "exp", "hypot", "fmod",
        "Int", "Double", "Float", "Bool", "String",
    ]

    private final class ScopeVisitor: SyntaxVisitor {
        var bound: Set<String> = []
        var reads: Set<String> = []
        var usedSelf = false

        // Bindings introduced in the function body are in scope.
        override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
            bound.insert(node.identifier.text); return .visitChildren
        }
        override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
            bound.insert(node.name.text); return .visitChildren
        }
        override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
            bound.insert((node.secondName ?? node.firstName).text); return .visitChildren
        }
        // A member access base like `a.b`: `a` is a read; `.b` is not a free read.
        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            // Skip the member name; only the base (visited as its own DeclRef) counts.
            return .visitChildren
        }
        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            let n = node.baseName.text
            if n == "self" { usedSelf = true; return .skipChildren }
            // Only a value READ of a lowercase identifier; `.member` names are
            // children of a MemberAccessExpr and are filtered by the parent check
            // below (a DeclRef that is the `declName` of a MemberAccess is skipped).
            if let parent = node.parent?.as(MemberAccessExprSyntax.self),
               parent.declName == node { return .visitChildren } // it's `.member`, skip
            if let f0 = n.first, f0.isLowercase || f0 == "_" { reads.insert(n) }
            return .visitChildren
        }
    }

    /// True when a function body carries forced-native interop the bundler must
    /// never lift (mirrors the classifier's hard-native invariant).
    private func bodyHasForcedNativeInterop(_ node: Syntax) -> Bool {
        let v = ForcedNativeVisitor(viewMode: .sourceAccurate)
        v.walk(node)
        return v.found
    }
    private final class ForcedNativeVisitor: SyntaxVisitor {
        var found = false
        static let unsafeCalls: Set<String> = [
            "performSelector", "respondsToSelector",
            "withUnsafePointer", "withUnsafeBytes", "withUnsafeMutableBytes",
            "withUnsafeMutablePointer",
            "withUnsafeMutableBufferPointer", "withUnsafeBufferPointer",
        ]
        override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
            if node.macroName.text == "selector" { found = true }
            return .visitChildren
        }
        override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
            let n = node.attributeName.trimmedDescription
            if n == "objc" || n == "_cdecl" { found = true }
            return .visitChildren
        }
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let ident = node.calledExpression.as(DeclReferenceExprSyntax.self),
               Self.unsafeCalls.contains(ident.baseName.text) { found = true }
            if let m = node.calledExpression.as(MemberAccessExprSyntax.self),
               Self.unsafeCalls.contains(m.declName.baseName.text) { found = true }
            return .visitChildren
        }
    }

    // MARK: - Index building

    func buildIndex(_ files: [URL]) -> [String: [Decl]] {
        var decls: [String: [Decl]] = [:]
        var members: [String: [Syntax]] = [:]
        for file in files {
            guard let src = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let tree = Parser.parse(source: src)
            collectDecls(Syntax(tree), into: &decls, members: &members, enclosing: nil)
        }
        return decls
    }

    private func collectDecls(_ node: Syntax, into index: inout [String: [Decl]],
                              members: inout [String: [Syntax]], enclosing: String?) {
        for child in node.children(viewMode: .sourceAccurate) {
            if let s = child.as(StructDeclSyntax.self) {
                index[s.name.text, default: []].append(Decl(kind: .valueType, name: s.name.text,
                    enclosingType: enclosing, node: Syntax(s), typeKind: .struct, isGeneric: s.genericParameterClause != nil))
                collectDecls(Syntax(s.memberBlock), into: &index, members: &members, enclosing: s.name.text)
            } else if let e = child.as(EnumDeclSyntax.self) {
                index[e.name.text, default: []].append(Decl(kind: .valueType, name: e.name.text,
                    enclosingType: enclosing, node: Syntax(e), typeKind: .enum, isGeneric: e.genericParameterClause != nil))
                collectDecls(Syntax(e.memberBlock), into: &index, members: &members, enclosing: e.name.text)
            } else if let c = child.as(ClassDeclSyntax.self) {
                index[c.name.text, default: []].append(Decl(kind: .refType, name: c.name.text,
                    enclosingType: enclosing, node: Syntax(c), typeKind: .class, isGeneric: c.genericParameterClause != nil))
                collectDecls(Syntax(c.memberBlock), into: &index, members: &members, enclosing: c.name.text)
            } else if let a = child.as(ActorDeclSyntax.self) {
                index[a.name.text, default: []].append(Decl(kind: .refType, name: a.name.text,
                    enclosingType: enclosing, node: Syntax(a), typeKind: .actor, isGeneric: a.genericParameterClause != nil))
            } else if let p = child.as(ProtocolDeclSyntax.self) {
                index[p.name.text, default: []].append(Decl(kind: .protocol_, name: p.name.text,
                    enclosingType: enclosing, node: Syntax(p), typeKind: .protocol, isGeneric: false))
            } else if let ext = child.as(ExtensionDeclSyntax.self) {
                let extName = SymbolTable.leadingNominal(ext.extendedType.trimmedDescription)
                collectDecls(Syntax(ext.memberBlock), into: &index, members: &members, enclosing: extName)
            } else if let f = child.as(FunctionDeclSyntax.self) {
                // Skip operators (cannot be a @_cdecl export by simple name).
                let isOperator = f.name.text.first.map { !($0.isLetter || $0 == "_") } ?? false
                if !isOperator {
                    index[f.name.text, default: []].append(Decl(kind: .function, name: f.name.text,
                        enclosingType: enclosing, node: Syntax(f),
                        typeKind: nil, isGeneric: f.genericParameterClause != nil))
                }
                // Record as a member of the enclosing type (includes operators) so
                // the value-type reconstruction can carry its full pure surface.
                if let enclosing { members[enclosing, default: []].append(Syntax(f)) }
            } else if let m = child.as(MemberBlockSyntax.self) {
                collectDecls(Syntax(m), into: &index, members: &members, enclosing: enclosing)
            } else if child.as(MemberBlockItemListSyntax.self) != nil
                        || child.as(CodeBlockItemListSyntax.self) != nil
                        || child.as(MemberBlockItemSyntax.self) != nil
                        || child.as(CodeBlockItemSyntax.self) != nil
                        // `#if`/`#elseif`/`#else` blocks: recurse into ALL clauses so a
                        // decl behind a platform guard (e.g. swift-numerics' Float16/
                        // Float80 extensions, DynamicColor's AppKit/UIKit `#if`s) is
                        // indexed. Index-only: adds decls; the purity/native gate still
                        // rejects anything unbundlable, and same-named branches are fine
                        // (`index` is keyed to a list).
                        || child.as(IfConfigDeclSyntax.self) != nil
                        || child.as(IfConfigClauseListSyntax.self) != nil
                        || child.as(IfConfigClauseSyntax.self) != nil {
                collectDecls(child, into: &index, members: &members, enclosing: enclosing)
            } else if let ta = child.as(TypeAliasDeclSyntax.self) {
                // Index typealiases (top-level AND nested) so the stored-property gate
                // can resolve an aliased scalar (`typealias Word = UInt`) instead of
                // rejecting the owning type as unbundlable.
                index[ta.name.text, default: []].append(Decl(kind: .typealias_, name: ta.name.text,
                    enclosingType: enclosing, node: Syntax(ta), typeKind: nil,
                    isGeneric: ta.genericParameterClause != nil))
                if let enclosing { members[enclosing, default: []].append(child) }
            } else if let enclosing {
                // Initializers, computed/stored properties, subscripts declared inside a
                // type/extension — part of the type's member surface.
                if child.is(InitializerDeclSyntax.self) || child.is(VariableDeclSyntax.self)
                    || child.is(SubscriptDeclSyntax.self) {
                    members[enclosing, default: []].append(child)
                }
                // A STATIC computed property (`static var code: String { … }`) is an
                // instance-less value seed exported as `Type.code` (no parens). Index it
                // like a zero-arg function so `resolveFunction`/`emitFunctions` can locate
                // and reconstruct it (emitted as `extension Type { static var code … }`).
                // Only a single-binding computed (getter) var qualifies — a stored
                // `static let`/`var = …` is not reconstructable in an extension and is
                // skipped. (Instance computed properties already ride the member-surface
                // walk via `members`; only the static seed needs an `index` entry.)
                if let v = child.as(VariableDeclSyntax.self),
                   v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }),
                   v.bindings.count == 1, let b = v.bindings.first,
                   let pn = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                   let acc = b.accessorBlock, isComputedGetter(acc) {
                    index[pn, default: []].append(Decl(kind: .function, name: pn,
                        enclosingType: enclosing, node: child, typeKind: nil, isGeneric: false))
                }
            }
        }
    }

    // MARK: - Member-surface resolution + purity gate

    /// Find the (non-operator, non-stored-property) member declaration named `name`
    /// on `typeName` — a method (`func`), computed property (`var x { … }`), or
    /// subscript — across the type's primary decl + all extensions. A STORED
    /// property is NOT a reconstructable member (it's already a field). Operators
    /// are handled separately by `operatorExtensionSource`. Returns the FIRST match
    /// (project value types rarely overload a member name with differing purity; a
    /// false match can only add a pure member, never ship a wrong one).
    func memberDecl(named name: String, of typeName: String, members: [String: [Syntax]]) -> Syntax? {
        guard let all = members[typeName] else { return nil }
        for m in all {
            if let f = m.as(FunctionDeclSyntax.self) {
                // Skip operators (a name not starting letter/`_`).
                let isOperator = !(f.name.text.first.map { $0.isLetter || $0 == "_" } ?? false)
                if !isOperator && f.name.text == name { return m }
            } else if let v = m.as(VariableDeclSyntax.self) {
                // COMPUTED property only — a getter accessor, NOT a stored property with
                // a `didSet`/`willSet` observer (that is a stored field, illegal in an
                // extension and not reconstructable). A static stored/computed `let`
                // (e.g. `static let zero`) is also not an instance member to follow.
                if v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
                for binding in v.bindings {
                    guard binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name else { continue }
                    guard let accessor = binding.accessorBlock else { continue }
                    if isComputedGetter(accessor) { return m }
                }
            } else if let s = m.as(SubscriptDeclSyntax.self), name == "subscript" {
                return Syntax(s)
            }
        }
        return nil
    }

    /// Find the operator FunctionDecl named `token` (`==`, `<`, `+`) declared on
    /// `typeName` (across its primary decl + extensions). Used to seed the
    /// member-surface walk from an exported operator's body.
    func operatorMemberNode(token: String, of typeName: String, members: [String: [Syntax]]) -> Syntax? {
        guard let all = members[typeName] else { return nil }
        for m in all {
            guard let f = m.as(FunctionDeclSyntax.self) else { continue }
            let isOperator = !(f.name.text.first.map { $0.isLetter || $0 == "_" } ?? false)
            if isOperator && f.name.text == token { return m }
        }
        return nil
    }

    /// Emit a member's source with any `set`ter DROPPED. For a subscript / computed
    /// property declared with explicit `get`/`set` accessors, re-emit it with only the
    /// getter (a read-only `{ … }` body). For an implicit-getter property, a method, or
    /// anything without a get/set split, return the verbatim source unchanged.
    private func getterOnlySource(of node: Syntax) -> String {
        guard let getter = explicitGetterBody(of: node) else { return node.trimmedDescription }
        let body = getter.trimmedDescription
        if let s = node.as(SubscriptDeclSyntax.self) {
            // `subscript(<params>) -> <Ret> { <getter body> }`
            let ret = s.returnClause.trimmedDescription
            let params = s.parameterClause.trimmedDescription
            let generics = s.genericParameterClause?.trimmedDescription ?? ""
            return "subscript\(generics)\(params) \(ret) {\n\(body)\n}"
        }
        if let v = node.as(VariableDeclSyntax.self), let b = v.bindings.first {
            // `var <name><: Type> { <getter body> }`
            let pat = b.pattern.trimmedDescription
            let typeAnn = b.typeAnnotation?.trimmedDescription ?? ""
            let kw = v.bindingSpecifier.text
            return "\(kw) \(pat)\(typeAnn) {\n\(body)\n}"
        }
        return node.trimmedDescription
    }

    /// For a subscript / computed property with explicit `get`/`set` accessors, return
    /// the GETTER accessor's code block (the body callers read). The reconstruction
    /// emits + validates the getter only; the `set` is dropped (it usually mutates via
    /// helpers we don't reconstruct, e.g. BigUInt's `subscript` set → `replace`/`extend`,
    /// and a value-copy ABI export never writes back anyway). Returns nil when there is
    /// no explicit get/set split (an implicit `{ … }` getter is already getter-only).
    private func explicitGetterBody(of node: Syntax) -> CodeBlockItemListSyntax? {
        func getterFrom(_ accessor: AccessorBlockSyntax?) -> CodeBlockItemListSyntax? {
            guard let accessor else { return nil }
            if case .accessors(let list) = accessor.accessors {
                for a in list where a.accessorSpecifier.text == "get" {
                    return a.body?.statements
                }
            }
            return nil
        }
        if let s = node.as(SubscriptDeclSyntax.self) { return getterFrom(s.accessorBlock) }
        if let v = node.as(VariableDeclSyntax.self) {
            for b in v.bindings { if let g = getterFrom(b.accessorBlock) { return g } }
        }
        return nil
    }

    /// True if a member decl (method / computed property / subscript) is `static` or
    /// `class` (called on the metatype, not an instance receiver).
    private func memberIsStatic(_ node: Syntax) -> Bool {
        if let f = node.as(FunctionDeclSyntax.self) {
            return f.modifiers.contains { ["static", "class"].contains($0.name.text) }
        }
        if let v = node.as(VariableDeclSyntax.self) {
            return v.modifiers.contains { ["static", "class"].contains($0.name.text) }
        }
        if let s = node.as(SubscriptDeclSyntax.self) {
            return s.modifiers.contains { ["static", "class"].contains($0.name.text) }
        }
        return false
    }

    /// True if a binding is a STORED property — no accessor, or only `didSet`/
    /// `willSet` OBSERVERS (an observed stored property is still a field, in the
    /// memberwise init / Codable). A computed getter is NOT stored.
    private func isStoredBinding(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessor = binding.accessorBlock else { return true }
        return !isComputedGetter(accessor)
    }

    /// True if a property's accessor block is a COMPUTED getter (a `{ … }` getter
    /// body, or explicit `get`/`set` accessors), NOT merely `didSet`/`willSet`
    /// observers on a STORED property. Only computed properties are reconstructable
    /// as extension members; an observed stored property stays a field.
    private func isComputedGetter(_ accessor: AccessorBlockSyntax) -> Bool {
        switch accessor.accessors {
        case .getter:
            return true  // `var x: T { … }` — implicit getter body.
        case .accessors(let list):
            for a in list {
                let kind = a.accessorSpecifier.text
                if kind == "get" || kind == "_read" || kind == "unsafeAddress" { return true }
            }
            return false  // only didSet/willSet → stored property with observers.
        }
    }

    /// Stored-property names of a value type (read from the `members` map). The
    /// member-surface gate treats reads of these as safe (they exist on the
    /// reconstructed type).
    private func storedFieldNamesFromMembers(_ typeName: String, members: [String: [Syntax]]) -> Set<String> {
        var names: Set<String> = []
        guard let all = members[typeName] else { return names }
        for m in all {
            guard let v = m.as(VariableDeclSyntax.self) else { continue }
            // INSTANCE stored props only — a `static let zero = Vector(…)` is NOT a
            // reconstructed field (the minimal type drops statics), so it must not be
            // treated as available (else a `.zero` read would falsely pass the gate).
            if v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
            for binding in v.bindings where isStoredBinding(binding) {
                // Only a TYPE-ANNOTATED stored prop is actually reconstructed as a field
                // (the synthesizer skips inferred-type bindings).
                guard binding.typeAnnotation != nil else { continue }
                if let id = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text { names.insert(id) }
            }
        }
        return names
    }

    /// Stored-property names in DECLARATION order (the memberwise init's label set).
    /// A call `Type(a: …, b: …)` whose labels equal these is the synthesized
    /// memberwise init the reconstruction provides; any other label set is a CUSTOM
    /// init the reconstruction lacks → the member using it is not self-contained.
    private func storedFieldOrderedNames(_ typeName: String, members: [String: [Syntax]]) -> [String] {
        var names: [String] = []
        guard let all = members[typeName] else { return names }
        for m in all {
            guard let v = m.as(VariableDeclSyntax.self) else { continue }
            if v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
            for binding in v.bindings where isStoredBinding(binding) {
                guard binding.typeAnnotation != nil else { continue }
                if let id = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text { names.append(id) }
            }
        }
        return names
    }

    /// Ordered stored fields (name + type) in declaration order. Only INSTANCE,
    /// type-annotated stored properties (the memberwise-init / Codable fields).
    private func storedFieldsOrdered(_ typeName: String, members: [String: [Syntax]])
        -> [(name: String, type: String)] {
        var out: [(name: String, type: String)] = []
        guard let all = members[typeName] else { return out }
        for m in all {
            guard let v = m.as(VariableDeclSyntax.self) else { continue }
            if v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
            for binding in v.bindings where isStoredBinding(binding) {
                guard let ann = binding.typeAnnotation?.type.trimmedDescription,
                      let id = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                else { continue }
                out.append((name: id, type: ann))
            }
        }
        return out
    }

    /// Build the T0 value-type RECONSTRUCTION shape for `typeName`, or nil when the
    /// type is not embedded-reconstructable as a flat scalar struct: it must be a
    /// value type with at least one stored field, ALL stored fields scalar
    /// (Int/Double/Bool/String), and a usable INITIALIZER whose labels we can emit.
    ///
    /// Init-label resolution (the reconstruction must construct the value):
    ///   * No explicit `init` declared → Swift synthesizes the memberwise init with
    ///     FIELD-NAME labels (`Vector(x:y:z:)`). Use field names.
    ///   * An explicit `init` whose parameter count == stored-field count → use THAT
    ///     init's labels in order (covers Euclid's `init(_ x, _ y, _ z = 0)` →
    ///     all-positional). If several qualify, prefer the one whose labels equal the
    ///     field names; else the first by source order.
    ///   * Otherwise (no matching init) → nil (not reconstructable here; T2 handles it).
    public func valueTypeShape(for typeName: String, index: Index)
        -> CodeEmitter.PureExport.ValueTypeShape? {
        valueTypeShape(for: typeName, index: index, visited: [])
    }

    /// Recursive shape builder. `visited` is the set of value types on the active
    /// nesting path: a field whose type is already being built (a cycle, `A.b: B`,
    /// `B.a: A`) is NOT reconstructable here (it would recurse forever / has no finite
    /// JSON form) → the whole shape is rejected → T2. Acyclic inputs never re-enter.
    private func valueTypeShape(for typeName: String, index: Index, visited: Set<String>)
        -> CodeEmitter.PureExport.ValueTypeShape? {
        let bare = typeName.trimmingCharacters(in: .whitespaces)
        if visited.contains(bare) { return nil }   // cycle — not finitely reconstructable
        guard let decl = resolveType(typeName, index: index.decls), decl.kind == .valueType else { return nil }
        let fields = storedFieldsOrdered(typeName, members: index.members)
        guard !fields.isEmpty else { return nil }
        // LEVER #1 (nested Codable): a field is reconstructable iff it is a T0 scalar
        // OR is itself a reconstructable value type (build its nested shape now). Any
        // other field type (Decimal/array/Foundation-backed/reference) → reject whole.
        var nestedShapes: [String: CodeEmitter.PureExport.ValueTypeShape] = [:]
        for f in fields {
            if CodeEmitter.T0Marshalling.isReadableArg(f.type) { continue }
            guard let nested = valueTypeShape(for: f.type, index: index,
                                              visited: visited.union([bare])) else { return nil }
            nestedShapes[f.name] = nested
        }

        let fieldNames = fields.map { $0.name }
        // Gather declared initializers (across primary decl + extensions).
        var inits: [[(label: String, hasDefault: Bool)]] = []
        if let all = index.members[typeName] {
            for m in all {
                guard let initDecl = m.as(InitializerDeclSyntax.self) else { continue }
                // Skip failable / generic / effectful inits — not safely callable here.
                if initDecl.optionalMark != nil { continue }
                if initDecl.genericParameterClause != nil { continue }
                if let eff = initDecl.signature.effectSpecifiers,
                   eff.asyncSpecifier != nil || eff.throwsClause != nil { continue }
                let params = initDecl.signature.parameterClause.parameters.map { p in
                    (label: p.firstName.text, hasDefault: p.defaultValue != nil)
                }
                inits.append(params)
            }
        }

        let labels: [String]
        if inits.isEmpty {
            // Synthesized memberwise init: field-name labels.
            labels = fieldNames
        } else {
            // We supply ALL stored fields IN STORED ORDER, so the chosen init must take
            // exactly `fields.count` params AND bind them to the fields in that same
            // order. Two shapes are safe:
            //   (a) labels match the field names positionally (conventional memberwise),
            //   (b) an ALL-POSITIONAL init (`init(_ x,_ y,_ z)`, every label `_`) — by
            //       convention positional order matches stored order (e.g. Euclid Vector).
            // A LABELED init whose labels do NOT match the field names positionally is
            // REJECTED here: blindly using `exact.first` would pair value[i] with
            // label[i] even when that init REORDERS the fields (e.g.
            // `init(y: Int, x: Int)`), silently swapping field values in the
            // reconstruction — shipping WRONG results. Returning nil routes such a type
            // to the T2 Foundation (Codable, name-keyed) wrapper, which is correct.
            let exact = inits.filter { $0.count == fields.count }
            func labelsMatchFields(_ ps: [(label: String, hasDefault: Bool)]) -> Bool {
                zip(ps, fieldNames).allSatisfy { $0.0.label == $0.1 }
            }
            func allPositional(_ ps: [(label: String, hasDefault: Bool)]) -> Bool {
                ps.allSatisfy { $0.label == "_" }
            }
            guard let chosen = exact.first(where: { labelsMatchFields($0) })
                ?? exact.first(where: { allPositional($0) }) else {
                return nil
            }
            labels = chosen.map { $0.label }
        }
        let shapeFields = fields.map {
            CodeEmitter.PureExport.ValueTypeShape.Field(
                name: $0.name, type: $0.type, nestedShape: nestedShapes[$0.name])
        }
        return CodeEmitter.PureExport.ValueTypeShape(typeName: typeName, fields: shapeFields, initLabels: labels)
    }

    /// All MEMBER names declared on a value type (instance + static methods,
    /// computed AND stored properties, including statics like `zero`). The
    /// self-containment gate uses the union of these across bundled types to detect a
    /// `.member` naming a value-type member that was NOT reconstructed.
    private func allDeclaredMemberNames(_ typeName: String, members: [String: [Syntax]]) -> Set<String> {
        var names: Set<String> = []
        guard let all = members[typeName] else { return names }
        for m in all {
            if let f = m.as(FunctionDeclSyntax.self) {
                let isOperator = !(f.name.text.first.map { $0.isLetter || $0 == "_" } ?? false)
                if !isOperator { names.insert(f.name.text) }
            } else if let v = m.as(VariableDeclSyntax.self) {
                for binding in v.bindings {
                    if let id = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text { names.insert(id) }
                }
            }
        }
        return names
    }

    /// The operator tokens (`+`, `-`, `==`, `<`, …) that `operatorExtensionSource`
    /// WILL reconstruct on `typeName`. Mirrors that function's drop conditions
    /// EXACTLY, so the self-containment gate only allows an operator the
    /// reconstruction actually provides (a member applying a DROPPED operator to a
    /// value-type operand would not compile). Conservative: if the predicate set
    /// here ever diverges from `operatorExtensionSource`, it can only mark an
    /// operator unavailable (rejecting more), never falsely available.
    private func reconstructedOperatorTokens(_ typeName: String, members: [String: [Syntax]],
                                             index: [String: [Decl]]) -> Set<String> {
        Set(reconstructedOperatorDecls(typeName, members: members, index: index).map { $0.name.text })
    }

    /// The operator `FunctionDecl`s `operatorExtensionSource` WILL reconstruct on
    /// `typeName`, computed as a FIXPOINT so an operator that applies ANOTHER value-type
    /// operator on the same type which is itself dropped (`BigInt.- { a + -b }` needs
    /// `+`, which is dropped because it calls `add`) is also dropped — otherwise it
    /// would be emitted referencing an operator the reconstruction lacks. Mirrors the
    /// per-operator drop conditions in `operatorExtensionSource` EXACTLY (single source
    /// of truth), plus the cross-operator fixpoint.
    /// `visited` carries the value types currently on the active recursion path
    /// (`reconstructedOperatorDecls` → `nonScalarStoredFieldNames` →
    /// `fieldTypeIsComparable` → back here). It bounds mutual recursion over
    /// value-type reference cycles (`A → B → A`): when descending into a field whose
    /// type is already on the path, the recursion is cut and that type is treated
    /// conservatively (not-further-decomposable / not-operator-safe). Acyclic inputs
    /// never re-encounter an active type, so their result is unchanged.
    private func reconstructedOperatorDecls(_ typeName: String, members: [String: [Syntax]],
                                            index: [String: [Decl]],
                                            surfaceOverride: Set<String>? = nil,
                                            visited: Set<String> = []) -> [FunctionDeclSyntax] {
        guard let all = members[typeName] else { return [] }
        let storedFields = storedPropertyNames(of: typeName, members: members)
        let nonScalarFields = nonScalarStoredFieldNames(of: typeName, members: members, index: index,
                                                        visited: visited.union([typeName]))
        // Which members an operator may read: the ACTUAL emitted surface when known
        // (emission time), else the intrinsic-purity set (walk time, pre-finalization).
        let reconMembers = surfaceOverride ?? reconstructableMemberNames(typeName, members: members, index: index)
        // Candidate operators that pass the LOCAL gates (native/member/array/compound).
        var candidates: [FunctionDeclSyntax] = []
        for m in all {
            guard let f = m.as(FunctionDeclSyntax.self) else { continue }
            let isOperator = !(f.name.text.first.map { $0.isLetter || $0 == "_" } ?? false)
            guard isOperator else { continue }
            if f.genericParameterClause != nil { continue }
            if isCompoundAssignmentOperator(f) { continue }
            if bodyHasForcedNativeInterop(Syntax(f)) { continue }
            let (types, _) = references(in: Syntax(f))
            var reject = false
            for t in types {
                let n = SymbolTable.leadingNominal(t) ?? t
                if let e = registry.entry(for: n), e.tier == .mustStayNative { reject = true; break }
            }
            if !reject, operatorReadsUnreconstructedMember(f, storedFields: storedFields, reconstructableMembers: reconMembers) { reject = true }
            if !reject, operatorReliesOnArrayLiteralConstruction(f) { reject = true }
            if !reject, operatorAccessesNonScalarField(f, nonScalarFields: nonScalarFields) { reject = true }
            // Drop an operator that APPLIES a value-type operator to a field whose type
            // does not reconstruct it (`BigInt.+` → BigUInt `+`, not reconstructed).
            if !reject, operatorAppliesUnreconstructedFieldOperator(f, ownerType: typeName, members: members, index: index, visited: visited.union([typeName])) { reject = true }
            if reject { continue }
            candidates.append(f)
        }
        // The universe of operator tokens DECLARED on the type (so we can tell a
        // value-type operator from a scalar/stdlib one inside an operator body).
        let declaredTokens = declaredOperatorTokens(typeName, members: members)
        // Fixpoint: drop a candidate that APPLIES a value-type operator (a declared
        // token) which is not (or no longer) a live candidate token. Scalar arithmetic
        // (`x &+ y` on words, `index < count`) uses tokens NOT declared on the type, so
        // it never trips this — only same-type value operators do.
        var liveTokens = Set(candidates.map { $0.name.text })
        var changed = true
        while changed {
            changed = false
            for f in candidates where liveTokens.contains(f.name.text) {
                let applied = appliedOperatorTokens(in: Syntax(f))
                // A declared value-type operator the body applies that is NOT live → drop.
                for tok in applied where declaredTokens.contains(tok) && !liveTokens.contains(tok) {
                    liveTokens.remove(f.name.text); changed = true; break
                }
            }
        }
        return candidates.filter { liveTokens.contains($0.name.text) }
    }

    /// Operator tokens APPLIED (as infix/prefix operators) inside a body — used by the
    /// operator fixpoint to detect an operator that depends on another (`-` applies `+`).
    private func appliedOperatorTokens(in node: Syntax) -> Set<String> {
        let v = AppliedOperatorVisitor(viewMode: .sourceAccurate)
        v.walk(node)
        return v.tokens
    }
    private final class AppliedOperatorVisitor: SyntaxVisitor {
        var tokens: Set<String> = []
        override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            tokens.insert(node.operator.text); return .visitChildren
        }
        override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            tokens.insert(node.operator.text); return .visitChildren
        }
    }

    /// THE PURITY GATE for a reconstructed value-type member. Returns nil if the
    /// member is safe to reconstruct (full body) onto the bundled value type, or a
    /// human-readable rejection clause otherwise. Zero false negatives: ANY of the
    /// following rejects (so the export needing the member demotes, never ships
    /// broken):
    ///   * a `mutating` method (its receiver mutation is discarded across the
    ///     value-copy ABI / its caller may rely on the effect) — conservative drop;
    ///   * forced-native interop (`@objc`/`#selector`/unsafe pointer);
    ///   * a generic member (cannot be reliably reconstructed/monomorphized);
    ///   * an `async`/`throws` member (a WASM export path is total & synchronous);
    ///   * a body referencing a `mustStayNative` registry symbol (UIKit/NS… ) as a
    ///     TYPE or a CALL (`UIColor`, `NSRegularExpression(...)`);
    ///   * a body using an ARRAY-LITERAL construction idiom (`[a, b, c]` returned as
    ///     the value type via `ExpressibleByArrayLiteral`, which the minimal Codable
    ///     reconstruction lacks) — e.g. Euclid `Vector.cross`.
    /// Members reached transitively (sibling/cross-type calls, return types) are
    /// validated by the walk itself; this gate validates the member in isolation.
    private func memberRejection(_ node: Syntax, ownerType: String, index: [String: [Decl]]) -> String? {
        if bodyHasForcedNativeInterop(node) { return "uses forced-native interop (@objc/#selector/unsafe)" }
        // Method-specific gates.
        if let f = node.as(FunctionDeclSyntax.self) {
            if f.genericParameterClause != nil { return "is generic — not reconstructable" }
            if f.modifiers.contains(where: { $0.name.text == "mutating" }) {
                return "is `mutating` — its receiver mutation is lost across the value ABI"
            }
            if let eff = f.signature.effectSpecifiers,
               eff.asyncSpecifier != nil || eff.throwsClause != nil {
                return "is async/throws — not a total synchronous member"
            }
        }
        if let s = node.as(SubscriptDeclSyntax.self), s.genericParameterClause != nil {
            return "is a generic subscript — not reconstructable"
        }
        // A computed property with a `set`ter that is non-trivial is fine to emit
        // (the getter is what callers read); but a `didSet`/`willSet` observer on a
        // STORED property is not a member we reconstruct (those are filtered out by
        // memberDecl requiring an accessorBlock, and stored-prop observers keep the
        // binding stored). No extra gate needed here.

        // Native TYPE / CALL references in the body.
        let (types, _) = references(in: node)
        for t in types {
            let nominal = SymbolTable.leadingNominal(t) ?? t
            if let e = registry.entry(for: nominal), e.tier == .mustStayNative {
                return "references native `\(nominal)`"
            }
        }
        // Array-literal value construction (`ExpressibleByArrayLiteral` idiom) — the
        // minimal Codable reconstruction lacks that conformance, so a returned
        // `[a, b, c]` would type as `[Element]` and fail to convert (Euclid `cross`).
        if let f = node.as(FunctionDeclSyntax.self), operatorReliesOnArrayLiteralConstruction(f) {
            return "constructs the value via an array literal (ExpressibleByArrayLiteral)"
        }
        if let v = node.as(VariableDeclSyntax.self) {
            let av = ArrayLiteralVisitor(viewMode: .sourceAccurate)
            av.walk(Syntax(v))
            if av.found { return "constructs the value via an array literal (ExpressibleByArrayLiteral)" }
        }
        return nil
    }

    /// If a member's declared RETURN type is a bundled value type and its body returns a
    /// bare integer/float literal (directly, or as a ternary/branch result), it relies
    /// on `ExpressibleBy{Integer,Float}Literal` — which the minimal Codable
    /// reconstruction does NOT conform to — so it would not compile. Return a reason,
    /// else nil. Conservative + local: only flags a numeric literal in RETURN position.
    private func returnsValueTypeFromNumericLiteral(_ node: Syntax, bundledValueTypes: Set<String>) -> String? {
        // Determine the declared return type's leading nominal.
        var retNominal: String? = nil
        if let f = node.as(FunctionDeclSyntax.self),
           let rt = f.signature.returnClause?.type.trimmedDescription {
            retNominal = SymbolTable.leadingNominal(rt)
        } else if let s = node.as(SubscriptDeclSyntax.self) {
            retNominal = SymbolTable.leadingNominal(s.returnClause.type.trimmedDescription)
        } else if let v = node.as(VariableDeclSyntax.self),
                  let t = v.bindings.first?.typeAnnotation?.type.trimmedDescription {
            retNominal = SymbolTable.leadingNominal(t)
        }
        guard let ret = retNominal, bundledValueTypes.contains(ret) else { return nil }
        let lv = ReturnNumericLiteralVisitor(viewMode: .sourceAccurate)
        lv.walk(node)
        if lv.found {
            return "returns `\(ret)` from a numeric literal (ExpressibleBy{Integer,Float}Literal not reconstructed)"
        }
        return nil
    }

    /// Detects a bare integer/float literal in RETURN position: a `return <lit>`, or a
    /// ternary `cond ? <lit> : …` / `… : <lit>` (the `signum() { isZero ? 0 : 1 }`
    /// idiom). Does NOT flag literals used as scalar operands (`storage.count - 1`),
    /// only literals that are the produced VALUE.
    private final class ReturnNumericLiteralVisitor: SyntaxVisitor {
        var found = false
        private func isNumeric(_ e: ExprSyntax?) -> Bool {
            guard var e = e else { return false }
            // Unwrap a leading `-`/`+` prefix (`-1`) and a parenthesized single value.
            if let p = e.as(PrefixOperatorExprSyntax.self) { e = p.expression }
            if let t = e.as(TupleExprSyntax.self), t.elements.count == 1 { e = t.elements.first!.expression }
            return e.is(IntegerLiteralExprSyntax.self) || e.is(FloatLiteralExprSyntax.self)
        }
        override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
            if isNumeric(node.expression) { found = true }
            return .visitChildren
        }
        // FOLDED ternary (`cond ? a : b` as a single node).
        override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
            if isNumeric(node.thenExpression) || isNumeric(node.elseExpression) { found = true }
            return .visitChildren
        }
        // UNFOLDED ternary — SwiftParser emits `cond ? a : b` as an
        // `UnresolvedTernaryExprSyntax` (carrying the `then` branch) inside a
        // `SequenceExprSyntax`, with the `else` branch as the following sequence
        // element. Flag a numeric `then`, and scan sequence elements for a numeric
        // operand adjacent to the `?`/`:` of an unresolved ternary.
        override func visit(_ node: UnresolvedTernaryExprSyntax) -> SyntaxVisitorContinueKind {
            if isNumeric(node.thenExpression) { found = true }
            return .visitChildren
        }
        override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
            let elems = Array(node.elements)
            for (i, e) in elems.enumerated() {
                guard e.is(UnresolvedTernaryExprSyntax.self) else { continue }
                // The element AFTER an unresolved ternary is the `else` branch.
                if i + 1 < elems.count, isNumeric(elems[i + 1]) { found = true }
            }
            return .visitChildren
        }
    }

    /// THE SELF-CONTAINMENT GATE for a candidate reconstructed member. Returns a
    /// reason if the member's body references a symbol the reconstruction does NOT
    /// provide (so it would not compile in the module), else nil. Checks:
    ///   * a bare lowercase identifier read/call that is not a param/local, a sibling
    ///     member of the owner type, a free function in the closure, or a safe
    ///     stdlib/math global → fail (catches a module-level `let epsilon`,
    ///     `shortestLineBetween(...)`);
    ///   * a `.member` (or `Type.static`) access whose member name is neither a safe
    ///     stdlib member nor an available (live/stored) member on a bundled value
    ///     type → fail (catches `.zero`/`.one` statics, `.interpolated`/`.direction`
    ///     when not reconstructed);
    ///   * a `Type(args)` call constructing a bundled value type with labels that are
    ///     NOT the synthesized memberwise-init labels → fail (catches a CUSTOM init
    ///     like `Plane(unchecked:w:)`);
    ///   * an operator whose operand cannot be proven scalar AND whose token is a
    ///     declared operator on some bundled value type that was NOT reconstructed →
    ///     fail (catches Euclid's `Vector` `+`/`-`/`*`/`/`, dropped by the array-literal
    ///     idiom). Scalar-on-scalar arithmetic (`x * other.x`) stays allowed.
    /// The walk's fixpoint re-checks members after drops, so a member calling a
    /// just-dropped sibling is dropped too. Provably compile-safe: every accepted
    /// member references only reconstructed symbols.
    func memberSelfContainmentFailure(
        _ node: Syntax, ownerType: String, bundledValueTypes: Set<String>,
        storedFields: [String: Set<String>], operatorSet: [String: Set<String>],
        memberwiseLabels: [String: [String]],
        liveMember: @escaping (String, String) -> Bool,
        index: [String: [Decl]], members: [String: [Syntax]],
        customInitSigs: [String: [InitSig]] = [:],
        asInitOfType: String? = nil
    ) -> String? {
        // A member that RETURNS a bundled value type from a bare integer/float literal
        // (`signum() -> BigUInt { isZero ? 0 : 1 }`) relies on
        // `ExpressibleByIntegerLiteral`/`ByFloatLiteral`, which the minimal Codable
        // reconstruction lacks → it would not compile. Drop it.
        if let reason = returnsValueTypeFromNumericLiteral(node, bundledValueTypes: bundledValueTypes) {
            return reason
        }
        let v = SelfContainmentVisitor(viewMode: .sourceAccurate)
        v.ownerType = ownerType
        v.ownerStored = storedFields[ownerType] ?? []
        v.bundledValueTypes = bundledValueTypes
        v.storedFields = storedFields
        v.memberAvailable = { type, name in liveMember(type, name) }
        v.scalarStoredFields = scalarStoredFieldMap(for: bundledValueTypes, members: members)
        // ONLY true module-scope free functions (enclosingType == nil) count as
        // available bare calls. An extension method is ALSO indexed as a `.function`
        // (with an enclosingType), but it needs `self` — it must resolve as a sibling
        // MEMBER, not a free function, else a method calling a native-tainted sibling
        // (`helper()`) would be wrongly admitted.
        v.freeFunctions = { name in
            index[name]?.contains { $0.kind == .function && $0.enclosingType == nil } ?? false
        }
        v.knownGlobals = Self.knownGlobals
        v.stdlibMembers = Self.stdlibValueMembers.union(Self.stdlibCallMembers)
        v.knownStdlibTypes = Self.knownStdlibTypes
        v.safeLeaves = Self.safeLeaves.union(Self.safeContainers)
        v.memberwiseLabels = memberwiseLabels
        v.customInitSigs = customInitSigs
        v.selfInitType = asInitOfType ?? ""
        // All declared member names across bundled value types (so a `.member`
        // naming a dropped value-type member is rejected, regardless of base shape).
        var declaredMembers: Set<String> = []
        for t in bundledValueTypes { declaredMembers.formUnion(allDeclaredMemberNames(t, members: members)) }
        v.declaredValueMembers = declaredMembers
        // Field-type map (type → field → leading-nominal type) for base-type inference.
        v.fieldTypes = fieldTypeMap(for: bundledValueTypes, members: members)
        // Seed bound names + param TYPES (for `param.member` base inference). A param
        // whose declared type is a SCALAR is recorded as a scalar local (so arithmetic
        // on it — `index < end - start` — is not mistaken for a dropped value operator).
        func seedParam(_ name: String, type: String) {
            v.bound.insert(name)
            if let nom = SymbolTable.leadingNominal(type) {
                v.localTypes[name] = nom
                if Self.isScalarLeaf(nom) || ["Double","Float","CGFloat","TimeInterval"].contains(nom) {
                    v.scalarLocals.insert(name)
                }
            }
        }
        if let f = node.as(FunctionDeclSyntax.self) {
            for p in f.signature.parameterClause.parameters {
                seedParam((p.secondName ?? p.firstName).text, type: p.type.trimmedDescription)
            }
        } else if let s = node.as(SubscriptDeclSyntax.self) {
            for p in s.parameterClause.parameters {
                seedParam((p.secondName ?? p.firstName).text, type: p.type.trimmedDescription)
            }
        } else if let initDecl = node.as(InitializerDeclSyntax.self) {
            for p in initDecl.signature.parameterClause.parameters {
                seedParam((p.secondName ?? p.firstName).text, type: p.type.trimmedDescription)
            }
        }
        // Enum-case pattern bindings with SCALAR associated values: `case .slice(from:
        // let start, to: let end)` (where Kind.slice is `(from: Int, to: Int)`) binds
        // `start`/`end` as Int. Record them scalar so `end - start` is scalar arithmetic.
        v.scalarLocals.formUnion(scalarEnumCaseBindings(in: node, members: members, index: index))
        // Operators NOT reconstructed on any bundled value type — used to reject a
        // value-type operand operator.
        var droppedOps: Set<String> = []
        for t in bundledValueTypes {
            let declared = declaredOperatorTokens(t, members: members)
            droppedOps.formUnion(declared.subtracting(operatorSet[t] ?? []))
        }
        v.droppedValueTypeOperators = droppedOps
        // For a subscript / computed property with an explicit `get`/`set`, validate
        // ONLY the getter (the `set` is dropped from the reconstruction). For a method
        // or implicit-getter property, validate the whole node.
        if let getter = explicitGetterBody(of: node) {
            v.walk(Syntax(getter))
        } else {
            v.walk(node)
        }
        return v.failure
    }

    /// Names bound in ENUM-CASE patterns inside `node` whose associated value is a
    /// SCALAR (Int/UInt/Double/…), so arithmetic on them is scalar (not a value-type
    /// operator). Resolves a pattern's case-name + position/label against the bundled
    /// enums' case declarations (`Kind.slice(from: Int, to: Int)` → `start`/`end` Int).
    private func scalarEnumCaseBindings(in node: Syntax, members: [String: [Syntax]],
                                        index: [String: [Decl]]) -> Set<String> {
        // Map: case name → [ (label?, scalarType?) ] across all bundled enums in scope.
        var caseParams: [String: [(label: String?, scalar: Bool)]] = [:]
        for (_, decls) in index {
            for d in decls where d.kind == .valueType && d.typeKind == .enum {
                guard let e = d.node.as(EnumDeclSyntax.self) else { continue }
                for m in e.memberBlock.members {
                    guard let cd = m.decl.as(EnumCaseDeclSyntax.self) else { continue }
                    for el in cd.elements {
                        guard let params = el.parameterClause?.parameters else { continue }
                        let entry = params.map { p -> (label: String?, scalar: Bool) in
                            let nom = SymbolTable.leadingNominal(p.type.trimmedDescription)
                                .map { resolveAliasChain($0, owner: nil, index: index) }
                            let isScalar = nom.map { Self.isScalarLeaf($0)
                                || ["Double","Float","CGFloat","TimeInterval"].contains($0) } ?? false
                            return (p.firstName?.text, isScalar)
                        }
                        // Keep the entry with the MOST scalar params for a case name (best-effort).
                        if caseParams[el.name.text] == nil { caseParams[el.name.text] = entry }
                    }
                }
            }
        }
        let v = EnumCaseBindingVisitor(viewMode: .sourceAccurate)
        v.caseParams = caseParams
        v.walk(node)
        return v.scalarBindings
    }

    private final class EnumCaseBindingVisitor: SyntaxVisitor {
        var caseParams: [String: [(label: String?, scalar: Bool)]] = [:]
        var scalarBindings: Set<String> = []
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            // A case pattern `.slice(from: let start, to: let end)` parses as a
            // FunctionCallExpr whose callee is a MemberAccessExpr `.slice`.
            guard let m = node.calledExpression.as(MemberAccessExprSyntax.self) else { return .visitChildren }
            let caseName = m.declName.baseName.text
            guard let params = caseParams[caseName] else { return .visitChildren }
            for (i, arg) in node.arguments.enumerated() {
                // Find the bound identifier inside `let X` / `X`.
                guard let name = boundName(in: arg.expression) else { continue }
                // Match by label if present, else by position.
                let scalar: Bool
                if let label = arg.label?.text {
                    scalar = params.first { $0.label == label }?.scalar ?? false
                } else if i < params.count {
                    scalar = params[i].scalar
                } else { scalar = false }
                if scalar { scalarBindings.insert(name) }
            }
            return .visitChildren
        }
        private func boundName(in expr: ExprSyntax) -> String? {
            if let p = expr.as(PatternExprSyntax.self) {
                if let vb = p.pattern.as(ValueBindingPatternSyntax.self),
                   let id = vb.pattern.as(IdentifierPatternSyntax.self) { return id.identifier.text }
                if let id = p.pattern.as(IdentifierPatternSyntax.self) { return id.identifier.text }
            }
            if let d = expr.as(DeclReferenceExprSyntax.self) { return d.baseName.text }
            return nil
        }
    }

    /// Operator tokens DECLARED (as `static func <op>`) on a value type, regardless
    /// of whether they reconstruct — the universe of value-type operators.
    private func declaredOperatorTokens(_ typeName: String, members: [String: [Syntax]]) -> Set<String> {
        var tokens: Set<String> = []
        guard let all = members[typeName] else { return tokens }
        for m in all {
            guard let f = m.as(FunctionDeclSyntax.self) else { continue }
            let isOperator = !(f.name.text.first.map { $0.isLetter || $0 == "_" } ?? false)
            if isOperator { tokens.insert(f.name.text) }
        }
        return tokens
    }

    /// Map of bundled-value-type → (stored-field name → its leading-nominal type),
    /// for base-type inference in the self-containment gate (so `origin.interpolated`
    /// resolves `origin: Vector` → `Vector.interpolated`).
    private func fieldTypeMap(for types: Set<String>, members: [String: [Syntax]]) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for t in types {
            guard let all = members[t] else { continue }
            var m: [String: String] = [:]
            for decl in all {
                guard let v = decl.as(VariableDeclSyntax.self) else { continue }
                if v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
                for binding in v.bindings where isStoredBinding(binding) {
                    guard let id = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                          let ty = binding.typeAnnotation?.type.trimmedDescription,
                          let nom = SymbolTable.leadingNominal(ty) else { continue }
                    m[id] = nom
                }
            }
            out[t] = m
        }
        return out
    }

    /// Map of bundled-value-type → set of its SCALAR stored-field names (fields whose
    /// declared type is an ABI scalar/Double/Int/Bool/String — so `obj.field`
    /// arithmetic is scalar-safe). Used by the operator-operand classifier.
    private func scalarStoredFieldMap(for types: Set<String>, members: [String: [Syntax]]) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for t in types {
            guard let all = members[t] else { continue }
            var fields: Set<String> = []
            for m in all {
                guard let v = m.as(VariableDeclSyntax.self) else { continue }
                if v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
                for binding in v.bindings where isStoredBinding(binding) {
                    guard let id = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                          let ty = binding.typeAnnotation?.type.trimmedDescription else { continue }
                    let leaves = Self.decompose(ty)
                    let scalar = !leaves.isEmpty && leaves.allSatisfy {
                        ["Int","Int8","Int16","Int32","Int64","UInt","UInt8","UInt16","UInt32","UInt64",
                         "Double","Float","Bool","String","Character","Substring","CGFloat","TimeInterval"].contains($0)
                    }
                    if scalar { fields.insert(id) }
                }
            }
            out[t] = fields
        }
        return out
    }

    /// Safe stdlib members that may appear as `.member` on a scalar/collection/value
    /// without reconstruction (a CALL form like `.squareRoot()` / `.rounded()`).
    private static let stdlibCallMembers: Set<String> = [
        "squareRoot", "rounded", "rounded(_:)", "magnitude", "distance", "advanced",
        "isFinite", "isNaN", "isInfinite", "isZero", "sign", "truncatingRemainder",
        "remainder", "negated", "map", "filter", "reduce", "contains", "sorted",
        "min", "max", "count", "first", "last", "isEmpty", "joined", "split",
        "lowercased", "uppercased", "hasPrefix", "hasSuffix", "trimmingCharacters",
        "appending", "dropFirst", "dropLast", "prefix", "suffix", "reversed",
        "clamped", "rawValue", "description", "hashValue", "toRadians", "toDegrees",
    ]

    private final class SelfContainmentVisitor: SyntaxVisitor {
        var ownerType: String = ""
        var ownerStored: Set<String> = []
        var bundledValueTypes: Set<String> = []
        var storedFields: [String: Set<String>] = [:]
        var scalarStoredFields: [String: Set<String>] = [:]
        /// type → field/param → declared leading-nominal type (for base inference).
        var fieldTypes: [String: [String: String]] = [:]
        /// param/local name → declared/inferred leading-nominal type, in THIS member.
        var localTypes: [String: String] = [:]
        var memberAvailable: (String, String) -> Bool = { _, _ in false }
        var freeFunctions: (String) -> Bool = { _ in false }
        var knownGlobals: Set<String> = []
        var stdlibMembers: Set<String> = []
        var knownStdlibTypes: Set<String> = []
        var safeLeaves: Set<String> = []
        var memberwiseLabels: [String: [String]] = [:]
        /// type → signatures of the CUSTOM inits the reconstruction emits (in addition
        /// to the memberwise init). A `Type(args)` / `.init(args)` / `self.init(args)`
        /// call matching one of these is accepted (the init is carried in the bundle).
        var customInitSigs: [String: [InitSig]] = [:]
        /// The type whose init body is being validated (so `self.init(args)` resolves to
        /// THIS type's inits). Empty when validating a non-init member.
        var selfInitType: String = ""
        var droppedValueTypeOperators: Set<String> = []
        var declaredValueMembers: Set<String> = []
        var bound: Set<String> = []
        /// Locals proven SCALAR (Int/Double/…) — params with a scalar type + enum-case
        /// pattern bindings whose associated value is scalar (`case .slice(from: let
        /// start, to: let end)` → start/end: Int). An operator on these is scalar (not a
        /// dropped value-type operator), so `index < end - start` is fine.
        var scalarLocals: Set<String> = []
        var failure: String? = nil

        private func fail(_ r: String) { if failure == nil { failure = r } }

        override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
            bound.insert(node.identifier.text); return .visitChildren
        }
        override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
            bound.insert(node.name.text); return .visitChildren
        }
        override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
            bound.insert((node.secondName ?? node.firstName).text); return .visitChildren
        }

        // `Type(args)` / `.init(args)` / `Type.init(args)` construction of a bundled
        // value type must use the synthesized memberwise-init labels (else it's a
        // custom init the reconstruction lacks → reject).
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            // `assert(...)` / `precondition(...)` — debug-only guards that the emitter
            // STRIPS from a reconstructed init (release builds compile them out). Their
            // argument expressions may reference members we don't reconstruct
            // (`assert(normal.isNormalized)`); since the call is dropped on emit, skip
            // validating its arguments (no compile dependency).
            if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
               ["assert", "precondition", "assertionFailure", "preconditionFailure"]
                   .contains(callee.baseName.text) {
                return .skipChildren
            }
            // `TypeName(args)`
            if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self) {
                checkInit(typeName: callee.baseName.text, node: node)
            } else if let m = node.calledExpression.as(MemberAccessExprSyntax.self),
                      m.declName.baseName.text == "init" {
                // `.init(args)` (contextual), `Type.init(args)`, or `self.init(args)`.
                if let base = m.base?.as(DeclReferenceExprSyntax.self)?.baseName.text,
                   base.first?.isUppercase ?? false {
                    checkInit(typeName: base, node: node)
                } else if let base = m.base?.as(DeclReferenceExprSyntax.self)?.baseName.text,
                          base == "self", !selfInitType.isEmpty {
                    // `self.init(args)` — a delegating init. It must target THIS type's
                    // memberwise init or an emitted custom init, else the delegation
                    // target is not carried in the reconstruction → reject.
                    checkInit(typeName: selfInitType, node: node)
                } else if m.base == nil {
                    // Contextual `.init(...)` — the target type is inferred. If the
                    // labels match NO bundled value type's memberwise init or emitted
                    // custom init AND any bundled value type is plausibly the target,
                    // reject. Conservative: reject when labels are non-empty and match
                    // no carried init set.
                    let labels = node.arguments.map { $0.label?.text ?? "_" }
                    if !labels.isEmpty {
                        let matchesMemberwise = bundledValueTypes.contains { memberwiseLabels[$0] == labels }
                        let matchesCustom = bundledValueTypes.contains {
                            (customInitSigs[$0] ?? []).contains { $0.accepts(callLabels: labels) }
                        }
                        let isSingleEnumish = labels == ["_"]  // `.init(rawValue)`-ish
                        if !matchesMemberwise && !matchesCustom && !isSingleEnumish {
                            fail("calls a contextual custom initializer `.init(\(labels.map { $0 + ":" }.joined()))` the reconstruction lacks")
                        }
                    }
                }
            }
            return .visitChildren
        }

        private func checkInit(typeName n: String, node: FunctionCallExprSyntax) {
            guard bundledValueTypes.contains(n) else { return }
            let labels = node.arguments.map { $0.label?.text ?? "_" }
            let expected = memberwiseLabels[n] ?? []
            let matchesMemberwise = labels == expected
            let allUnlabelledSingle = expected.count == labels.count
                && labels.allSatisfy { $0 == "_" } && expected.count <= 1
            // An emitted custom init whose signature accepts this call site.
            let matchesCustom = (customInitSigs[n] ?? []).contains { $0.accepts(callLabels: labels) }
            if !matchesMemberwise && !allUnlabelledSingle && !matchesCustom {
                fail("calls a custom initializer `\(n)(\(labels.map { $0 + ":" }.joined()))` the reconstruction lacks")
            }
        }

        /// Record `let x: T = …` / `let x = T(...)` local types for base inference.
        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            for b in node.bindings {
                guard let id = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                if let t = b.typeAnnotation?.type.trimmedDescription,
                   let nom = SymbolTable.leadingNominal(t) { localTypes[id] = nom }
                else if let call = b.initializer?.value.as(FunctionCallExprSyntax.self),
                        let ty = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
                        ty.first?.isUppercase ?? false { localTypes[id] = ty }
            }
            return .visitChildren
        }

        /// Best-effort: the leading-nominal TYPE of an expression, for `.member`
        /// receiver resolution. Returns nil when unknown (the caller then falls back
        /// to the conservative name-based rule).
        private func inferType(_ expr: ExprSyntax) -> String? {
            if expr.is(FunctionCallExprSyntax.self) {
                // `Type(...)` → Type;  `recv.method(...)` → unknown (return-type unknown).
                if let call = expr.as(FunctionCallExprSyntax.self),
                   let ty = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
                   ty.first?.isUppercase ?? false { return ty }
                return nil
            }
            if let d = expr.as(DeclReferenceExprSyntax.self) {
                let n = d.baseName.text
                if n == "self" { return ownerType }
                if let t = localTypes[n] { return t }
                // An owner stored field's type.
                if let t = fieldTypes[ownerType]?[n] { return t }
                return nil
            }
            if let m = expr.as(MemberAccessExprSyntax.self), let base = m.base {
                // `base.field` → field's declared type on base's type.
                if let bt = inferType(base), let ft = fieldTypes[bt]?[m.declName.baseName.text] { return ft }
                return nil
            }
            if let t = expr.as(TupleExprSyntax.self), t.elements.count == 1 {
                return inferType(t.elements.first!.expression)
            }
            return nil
        }

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            let member = node.declName.baseName.text
            guard let first = member.first else { return .visitChildren }
            if member == "init" { return .visitChildren } // handled by FunctionCall.
            // `.UpperCase` (enum case / nested type) — allow (cases are reconstructed,
            // nested types validated by the type closure).
            if first.isUppercase { return .visitChildren }
            if stdlibMembers.contains(member) { return .visitChildren }

            // TYPE-DIRECTED: if we can infer the base's type, resolve the member on
            // THAT exact type (so a `Line.interpolated` and a `Vector.interpolated`
            // don't alias). A member on a bundled value type that is not reconstructed
            // (live/stored) → reject.
            if let base = node.base, let bt = inferType(base) {
                if bundledValueTypes.contains(bt) {
                    if memberAvailable(bt, member) || (storedFields[bt]?.contains(member) ?? false) {
                        return .visitChildren
                    }
                    fail("reads unreconstructed member `\(bt).\(member)`"); return .skipChildren
                }
                // Base is a scalar/stdlib/non-bundled type → its member is a stdlib
                // member; allow (the type itself is validated by the type closure).
                return .visitChildren
            }

            // Base type UNKNOWN (complex expr, leading-dot static, chained call). Fall
            // back to the conservative name rule: a `.member` available on SOME bundled
            // value type is fine; one that NAMES a declared-but-unreconstructed
            // value-type member is rejected (covers `.zero`/`.one` statics,
            // `.direction`/`.normalized` when dropped).
            for t in bundledValueTypes where memberAvailable(t, member) || (storedFields[t]?.contains(member) ?? false) {
                return .visitChildren
            }
            if declaredValueMembers.contains(member) {
                fail("reads unreconstructed value-type member `.\(member)`"); return .skipChildren
            }
            return .visitChildren
        }

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            // Skip the `.member` name of a member-access (handled above).
            if let parent = node.parent?.as(MemberAccessExprSyntax.self), parent.declName == node {
                return .visitChildren
            }
            let n = node.baseName.text
            if n == "self" || n == "_" || n == "nil" || n == "true" || n == "false" { return .visitChildren }
            guard let first = n.first else { return .visitChildren }
            if first.isUppercase {
                // A type reference: allowed if a bundled value type, a safe leaf, or a
                // known stdlib type (validated by the type closure otherwise).
                return .visitChildren
            }
            // lowercase identifier read/call.
            if bound.contains(n) { return .visitChildren }
            if knownGlobals.contains(n) { return .visitChildren }
            if freeFunctions(n) { return .visitChildren }
            if ownerStored.contains(n) { return .visitChildren }       // implicit-self stored field
            if memberAvailable(ownerType, n) { return .visitChildren } // implicit-self live member
            fail("references unbundled free symbol `\(n)`")
            return .visitChildren
        }

        // Operators on a value-type operand whose token was NOT reconstructed.
        // SwiftParser produces UNFOLDED `SequenceExprSyntax` (a flat
        // operand/operator/operand list) rather than `InfixOperatorExprSyntax`, so we
        // inspect the sequence directly: for each binary operator token, check its two
        // adjacent operands. (Already-folded `InfixOperatorExprSyntax` is also handled
        // for robustness against pre-folded trees.)
        override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
            let elems = Array(node.elements)
            for (i, e) in elems.enumerated() {
                guard let bin = e.as(BinaryOperatorExprSyntax.self) else { continue }
                let op = bin.operator.text
                guard droppedValueTypeOperators.contains(op) else { continue }
                let lhs = i > 0 ? elems[i - 1] : nil
                let rhs = i + 1 < elems.count ? elems[i + 1] : nil
                let lhsScalar = lhs.map { isScalar($0) } ?? false
                let rhsScalar = rhs.map { isScalar($0) } ?? false
                if !(lhsScalar && rhsScalar) {
                    fail("applies unreconstructed value-type operator `\(op)` to a value operand")
                }
            }
            return .visitChildren
        }
        override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            if let op = node.operator.as(BinaryOperatorExprSyntax.self)?.operator.text,
               droppedValueTypeOperators.contains(op),
               !(isScalar(node.leftOperand) && isScalar(node.rightOperand)) {
                fail("applies unreconstructed value-type operator `\(op)` to a value operand")
            }
            return .visitChildren
        }
        override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            let op = node.operator.text
            if droppedValueTypeOperators.contains(op), !isScalar(node.expression) {
                fail("applies unreconstructed value-type prefix operator `\(op)` to a value operand")
            }
            return .visitChildren
        }

        private static let scalarStatics: Set<String> = [
            "pi", "infinity", "nan", "greatestFiniteMagnitude", "leastNormalMagnitude",
            "zero", "min", "max",  // on scalars; on a value type these were filtered above
        ]

        /// Best-effort: is `expr` provably a SCALAR (numeric/bool/string) value, so an
        /// operator on it is a stdlib scalar operator (always available)? Conservative
        /// — returns false when unsure (the operator must then be reconstructed).
        private func isScalar(_ expr: ExprSyntax) -> Bool {
            if expr.is(IntegerLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self)
                || expr.is(BooleanLiteralExprSyntax.self) { return true }
            if let t = expr.as(TupleExprSyntax.self), t.elements.count == 1 {
                return isScalar(t.elements.first!.expression)
            }
            if let infix = expr.as(InfixOperatorExprSyntax.self) {
                return isScalar(infix.leftOperand) && isScalar(infix.rightOperand)
            }
            if let pre = expr.as(PrefixOperatorExprSyntax.self) { return isScalar(pre.expression) }
            // A bare identifier that is a SCALAR stored field of the owner type, a scalar
            // param, or a scalar enum-case pattern binding.
            if let d = expr.as(DeclReferenceExprSyntax.self) {
                let n = d.baseName.text
                if scalarLocals.contains(n) { return true }
                if scalarStoredFields[ownerType]?.contains(n) ?? false { return true }
                return false
            }
            // `base.field` where field is a SCALAR stored field of SOME bundled type
            // (covers `other.x`, `self.x`). Also a `.squareRoot()`-style scalar member.
            if let m = expr.as(MemberAccessExprSyntax.self) {
                let name = m.declName.baseName.text
                for t in bundledValueTypes where scalarStoredFields[t]?.contains(name) ?? false { return true }
                if ["squareRoot","magnitude","rounded","distance","remainder"].contains(name) { return true }
                return false
            }
            // A function call returning a scalar (`dot(...)`) — best-effort: a call to
            // a member named like a known scalar-returning op.
            if let call = expr.as(FunctionCallExprSyntax.self),
               let m = call.calledExpression.as(MemberAccessExprSyntax.self) {
                if ["dot","distance","squareRoot"].contains(m.declName.baseName.text) { return true }
            }
            return false
        }
    }

    // MARK: - Resolution

    private func fnKey(_ d: Decl) -> String { "\(d.enclosingType ?? "")::\(d.name)" }

    private func resolveFunction(name: String, enclosing: String?, index: [String: [Decl]]) -> Decl? {
        guard let candidates = index[name] else { return nil }
        let fns = candidates.filter { $0.kind == .function }
        if let enclosing {
            return fns.first { $0.enclosingType == enclosing } ?? fns.first { $0.enclosingType == nil }
        }
        // Prefer a free function; else a static method.
        return fns.first { $0.enclosingType == nil } ?? fns.first
    }

    private func resolveType(_ name: String, index: [String: [Decl]]) -> Decl? {
        guard let candidates = index[name] else { return nil }
        // A fresh struct/enum/class/protocol decl (ignore extension-only entries).
        return candidates.first { $0.kind == .valueType || $0.kind == .refType || $0.kind == .protocol_ }
    }

    /// DIAGNOSTIC (env PATCH_DEMOTE_CATS): coarse-classify an unbound symbol that a
    /// mixed/native fragment references but the module closure doesn't bundle. Tells
    /// us whether the dominant "mixed fragment references unbundled X" bucket is
    /// genuinely native (class/protocol/native/generic) or an addressable value type
    /// the fragment path could reconstruct.
    public func classifyUnboundSymbol(_ name: String, index: Index) -> String {
        let nominal = SymbolTable.leadingNominal(name) ?? name
        if nominal == "<generic fragment>" { return "generic-fragment" }
        if nominal == "<generic @_cdecl export>" { return "generic-cdecl" }
        if nominal == "<no @_cdecl export>" { return "no-cdecl-export" }
        if isWasmSafeLeaf(nominal) { return "wasm-safe(false-positive)" }
        if isNonDependencyTypeToken(nominal) { return "module-qualifier(false-positive)" }
        if let e = registry.entry(for: nominal), e.tier == .mustStayNative {
            return "native-registry(\(e.category.rawValue))"
        }
        guard let decl = resolveType(nominal, index: index.decls) else {
            return "unknown(no-decl-found)"
        }
        if decl.kind == .refType { return "class/actor(refType)" }
        if decl.kind == .protocol_ { return "protocol" }
        if decl.isGeneric { return "generic-value-type" }
        // HONEST addressable test (fast, single-level — mirrors the bundler's own
        // boundary gate without the recursive member walk). A bare struct decl is not
        // enough: swift-collections' `SortedSet.Index` has a `_Tree.Index`
        // generic-nested stored prop and is NOT a clean Codable boundary.
        //   (a) Not nested inside another type (a nested type usually needs its
        //       enclosing (often generic) context).
        //   (b) Every stored-property leaf is a Codable leaf or a top-level value type.
        if decl.enclosingType != nil { return "value-type(nested-in-type)" }
        let leaves = storedPropertyLeafTypes(of: decl, index: index.decls)
        if leaves.allSatisfy({ $0.1 }) { return "value-type(ADDRESSABLE)" }
        return "value-type(non-codable-storage)"
    }

    // MARK: - References

    /// Collect the (capitalized type names, called bare-function names) referenced
    /// inside a decl's body/signature.
    private func references(in node: Syntax) -> (types: Set<String>, calls: Set<String>) {
        let v = RefVisitor(viewMode: .sourceAccurate)
        v.walk(node)
        return (v.types, v.calls)
    }

    /// Collect the MEMBER references (`.dot`, `.length`, `.squareRoot`) AND the
    /// implicit-`self` member references (a bare `lengthSquared` / `dot(self)` in a
    /// member body that names a sibling member of the same type) inside a member's
    /// body. Used to follow the value-type METHOD/COMPUTED-PROPERTY call graph.
    /// Returns: explicit `.member` names + bare lowercase identifiers (candidate
    /// implicit-self members; the caller intersects them with the type's member set).
    private func memberReferences(in node: Syntax) -> (explicit: Set<String>, bare: Set<String>) {
        let v = MemberRefVisitor(viewMode: .sourceAccurate)
        v.walk(node)
        return (v.explicitMembers, v.bareNames)
    }

    private final class MemberRefVisitor: SyntaxVisitor {
        /// `.member` access names (the RHS of any member-access expression).
        var explicitMembers: Set<String> = []
        /// Bare lowercase identifier reads/calls (candidate implicit-self members).
        var bareNames: Set<String> = []
        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            let name = node.declName.baseName.text
            if let f = name.first, f.isLowercase || f == "_" { explicitMembers.insert(name) }
            return .visitChildren
        }
        // A subscript access (`a[i]`, `self[i]`) reaches the type's `subscript` member,
        // which the reconstruction must carry. Seed it under the canonical name
        // `subscript` (how `memberDecl` indexes subscripts).
        override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
            explicitMembers.insert("subscript")
            return .visitChildren
        }
        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            // A bare identifier that is NOT the `.member` of a MemberAccessExpr is an
            // implicit-self / free reference; record lowercase ones as candidate
            // sibling-member implicit references.
            if let parent = node.parent?.as(MemberAccessExprSyntax.self), parent.declName == node {
                return .visitChildren // it's `.member`, handled above
            }
            let n = node.baseName.text
            if let f = n.first, f.isLowercase || f == "_" { bareNames.insert(n) }
            return .visitChildren
        }
    }

    private final class RefVisitor: SyntaxVisitor {
        var types: Set<String> = []
        var calls: Set<String> = []
        // An attribute (`@_cdecl("name")`, `@inline(__always)`, …) is NOT a type
        // reference: its `attributeName` is itself an `IdentifierTypeSyntax`, so
        // without skipping it the gate collects the attribute token (`_cdecl`) as an
        // unbound symbol and rejects the fragment. Skip the whole attribute subtree.
        override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
            return .skipChildren
        }
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
                // `Type.staticCall(...)` — collect the receiver type. But when the base
                // is a MODULE qualifier (`Foundation.acos(...)`, `Euclid.max(...)`),
                // the receiver is the module, not a type; collect the trailing member
                // ONLY when it names a TYPE (`Euclid.Vector(...)`). A module qualifier
                // is filtered out of `needTypes` later (`isNonDependencyTypeToken`).
                types.insert(base)
                let member = m.declName.baseName.text
                if let mf = member.first, mf.isUppercase { types.insert(member) } // `Module.Type(...)`
            }
            return .visitChildren
        }
        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            let n = node.baseName.text
            if let f = n.first, f.isUppercase { types.insert(n) }
            return .visitChildren
        }
    }

    // MARK: - WASM-safe leaves

    /// Scalar / stdlib / WASM-safe Foundation type names that need no bundling.
    private static let safeLeaves: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "Bool", "String", "Character",
        "Substring", "Decimal", "Date", "URL", "UUID", "Data",
        "TimeInterval", "CGFloat",
    ]
    /// Generic stdlib containers whose element types are checked separately.
    private static let safeContainers: Set<String> = ["Array", "Dictionary", "Set", "Optional"]

    /// Whether a leaf type name is a scalar/string the T0 host-bridge can marshal
    /// directly (so the boundary needs no in-module Codable). Public for the
    /// pipeline's tier choice.
    public static func isScalarLeaf(_ name: String) -> Bool {
        ["Int", "Int8", "Int16", "Int32", "Int64",
         "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Bool"].contains(name)
    }

    /// Whether a leaf nominal is a KNOWN-Codable stdlib/Foundation leaf or container
    /// (`Int`/`String`/`Date`/`Array`/`Dictionary`/…). Public so the pipeline can
    /// PROVE a T2 ABI-wrapper boundary is Codable BEFORE emitting the wrapper (Fix
    /// S1): the synthesized `_Args: Decodable` / `_Out: Encodable` only compiles when
    /// every boundary leaf conforms, so a leaf that is neither a known-Codable leaf
    /// NOR a bundled (reconstructed → force-Codable) value type must DEMOTE the
    /// export to native rather than emit a wrapper that fails in the dev's build.
    public static func isKnownCodableLeaf(_ name: String) -> Bool {
        codableLeaves.contains(name) || codableContainers.contains(name)
    }

    /// Public type-string decomposition (`[A:B]`/`[A]`/`A?`/`(A,B)`/`F<G>` →
    /// leaf nominal strings). Used by the pipeline to find boundary types.
    public static func decompose(_ raw: String) -> [String] {
        DependencyClosureBundler().decomposeLeaves(raw)
    }

    private func isWasmSafeLeaf(_ rawType: String) -> Bool {
        guard let nominal = SymbolTable.leadingNominal(rawType) ?? (rawType.isEmpty ? nil : rawType) else { return true }
        if Self.safeLeaves.contains(nominal) { return true }
        if Self.safeContainers.contains(nominal) { return true }
        // A registry WASM-safe Foundation value is fine.
        if let e = registry.entry(for: nominal), e.tier == .wasmSafeFoundation { return true }
        return false
    }

    /// Module-name qualifiers that the `RefVisitor` over-collects as "types" because
    /// they appear capitalized at the base of a member access (`Foundation.acos(…)`,
    /// `Swift.min(…)`). They are NOT app value types to bundle: the trailing member
    /// is what's referenced (a free function the body resolves on its own, or — when
    /// the member is itself capitalized, `Module.Type(…)` — a type collected
    /// separately by the visitor). Filtering these out of the dependency closure
    /// stops a false "not a bundlable value type" rejection for an otherwise pure
    /// export. Conservative: every name here is a real Swift module, never a type.
    private static let knownModuleNames: Set<String> = [
        "Swift", "Foundation", "Darwin", "Glibc", "WinSDK", "ucrt",
        "Dispatch", "ObjectiveC", "CoreFoundation", "_Concurrency",
    ]

    /// A capitalized token the closure walk must NOT treat as a bundlable-type
    /// dependency: a module-name qualifier (`Foundation`, `Swift`, …) over-collected
    /// by the ref scan. Returning `true` lets the validation walk skip the token
    /// instead of rejecting the whole export. (`Self` is deliberately NOT filtered
    /// here: skipping it admits instance-method exports whose member surface reaches
    /// unbundled scalar-extension members — they'd fail the real WASM compile and
    /// cascade-demote siblings via the shared reconstruction. Kept conservative.)
    private func isNonDependencyTypeToken(_ name: String) -> Bool {
        if Self.knownModuleNames.contains(name) { return true }
        return false
    }

    // MARK: - Stored-property closure

    /// For a value-type decl, return its stored-property leaf type names paired
    /// with whether each is bundlable (a WASM-safe leaf or a project value type).
    /// A `false` entry signals the type cannot be reconstructed → reject.
    /// Fix S5: rewrite a reconstructed struct field's VERBATIM type spelling into the
    /// resolved/unqualified LEAF spelling the validator (`appendLeaf`) accepted, so the
    /// reconstructed top-level type compiles after being severed from its enclosing
    /// scope. For each leaf nominal in the spelling:
    ///   (b) a MODULE-qualified leaf (`Euclid.Vector`) → its unqualified last component
    ///       (`Vector`) — the bundled top-level reconstruction has no `Euclid` module.
    ///   (a) a leaf that is an ENCLOSING-scope typealias whose chain bottoms out at a
    ///       Codable/known leaf is recorded in `neededAliases` so a `typealias` is
    ///       re-emitted (mirrors the enum path's enclosing-alias re-collection) — the
    ///       leaf spelling itself is preserved (the re-emitted alias makes it resolve).
    /// A leaf that is already a known leaf / a bundled value type is left as-is.
    /// Container/optional structure (`[A]`, `A?`, `[K:V]`, `F<G>`) is preserved by
    /// substituting only the leaf-nominal substrings.
    private func resolveFieldTypeSpelling(
        _ verbatim: String, owner: String?, enclosing: String?,
        index: [String: [Decl]], neededAliases: inout [(name: String, resolved: String)]
    ) -> String {
        // A function-type field (`() -> Void`) is left verbatim — it won't pass the
        // Codable gate, so it never reaches a SHIPPED reconstruction; preserve it.
        if verbatim.contains("->") { return verbatim }
        var spelling = verbatim
        for leaf in decomposeLeaves(verbatim) {
            guard let nominal = SymbolTable.leadingNominal(leaf) else { continue }
            // Resolve the leaf through any typealias chain the VALIDATOR followed
            // (`NS.Word` / `Word` → `UInt`). `owner` then `enclosing` scope, matching
            // `appendLeaf`'s resolution.
            let resolved = resolveAliasChain(nominal, owner: owner, index: index)
            let resolved2 = resolved == nominal
                ? resolveAliasChain(nominal, owner: enclosing, index: index) : resolved
            if resolved2 != nominal,
               isCodableLeaf(resolved2) || Self.knownSystemTypes.contains(resolved2) {
                // (a) An alias that bottoms out at a known/Codable leaf → substitute the
                // RESOLVED leaf directly (`[NS.Word]` → `[UInt]`, `[Word]` → `[UInt]`).
                // No `typealias` re-emit needed (the leaf is now a stdlib/Foundation type).
                spelling = replaceWholeToken(leaf, with: resolved2, in: spelling)
                continue
            }
            // An UNQUALIFIED enclosing-scope alias that resolves to a BUNDLED value type
            // (not a known leaf): re-emit a `typealias` so the (kept) leaf spelling
            // resolves on the severed reconstruction (mirrors the enum path). A
            // qualified such alias falls through to (b) unqualification.
            if resolved2 != nominal, !leaf.contains("."),
               resolveType(resolved2, index: index)?.kind == .valueType {
                neededAliases.append((name: nominal, resolved: resolved2))
                continue
            }
            if leaf.contains(".") {
                // (b) A MODULE/parent-qualified NON-alias leaf (`Euclid.Vector`) → emit
                // the unqualified last component (the bundled reconstruction has no
                // `Euclid` module; the unqualified `Vector` is the bundled value type).
                spelling = replaceWholeToken(leaf, with: nominal, in: spelling)
            }
            // Otherwise: a bundled value type (or a plain known leaf) — keep verbatim.
        }
        return spelling
    }

    /// Replace `token` with `replacement` in `s`, but only where `token` is a whole
    /// path/identifier (bounded by non-identifier, non-`.` characters), so a
    /// substring of a larger name is never clobbered. Used to strip a module qualifier
    /// from a field type spelling.
    private func replaceWholeToken(_ token: String, with replacement: String, in s: String) -> String {
        guard !token.isEmpty else { return s }
        func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." }
        var result = ""
        var idx = s.startIndex
        while idx < s.endIndex {
            if s[idx...].hasPrefix(token) {
                let before = idx == s.startIndex ? nil : s[s.index(before: idx)]
                let afterIdx = s.index(idx, offsetBy: token.count)
                let after = afterIdx < s.endIndex ? s[afterIdx] : nil
                let boundedBefore = before.map { !isIdentChar($0) } ?? true
                let boundedAfter = after.map { !isIdentChar($0) } ?? true
                if boundedBefore && boundedAfter {
                    result += replacement
                    idx = afterIdx
                    continue
                }
            }
            result.append(s[idx])
            idx = s.index(after: idx)
        }
        return result
    }

    private func storedPropertyLeafTypes(of decl: Decl, index: [String: [Decl]]) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        guard decl.typeKind == .struct || decl.typeKind == .enum else { return out }
        if decl.typeKind == .enum {
            // Associated-value enums: read associated value types; raw enums have none.
            if let e = decl.node.as(EnumDeclSyntax.self) {
                for member in e.memberBlock.members {
                    if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
                        for element in caseDecl.elements {
                            if let params = element.parameterClause?.parameters {
                                for p in params {
                                    // A nested enum's associated-value aliases (`Word`)
                                    // live in its ENCLOSING type's scope, so resolve
                                    // aliases there (falls back to scalar-preference).
                                    appendLeaf(p.type.trimmedDescription,
                                               owner: decl.enclosingType ?? decl.name,
                                               index: index, into: &out)
                                }
                            }
                        }
                    }
                }
            }
            return out
        }
        guard let s = decl.node.as(StructDeclSyntax.self) else { return out }
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            if v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
            // Stored properties only (no getter = stored; an observed `didSet` prop is
            // still a stored field).
            for binding in v.bindings {
                if !isStoredBinding(binding) { continue }
                guard let type = binding.typeAnnotation?.type.trimmedDescription else {
                    // Inferred-type stored property — best-effort: from a simple literal init.
                    continue
                }
                appendLeaf(type, owner: decl.name, index: index, into: &out)
            }
        }
        return out
    }

    /// Codable, boundary-safe value-leaf types: scalars/String + the Foundation
    /// VALUE types that are `Codable` (Decimal/Date/UUID/URL/Data/…). A reconstructed
    /// `Codable` struct may only store these (or other bundlable project value
    /// types). NSRegularExpression/Scanner/NSString/formatters are WASM-safe to
    /// USE but are NOT Codable value types — a struct storing one cannot synthesize
    /// Codable, so such a stored property makes the type unbundlable as a boundary.
    private static let codableLeaves: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "Bool", "String", "Character", "Substring",
        "Decimal", "Date", "UUID", "URL", "Data", "TimeInterval", "CGFloat",
        "DateComponents", "Locale", "TimeZone", "Calendar",
    ]
    private static let codableContainers: Set<String> = ["Array", "Dictionary", "Set", "Optional"]

    private func isCodableLeaf(_ name: String) -> Bool {
        Self.codableLeaves.contains(name) || Self.codableContainers.contains(name)
    }

    /// Follow a typealias chain to its underlying nominal (`Word` → `UInt`), bounded
    /// against cycles. Returns the input unchanged if it is not an alias.
    ///
    /// `owner` disambiguates when an alias name is declared in MORE than one scope
    /// (e.g. BigInt declares `BigUInt.Word = UInt`, `BigInt.Word = BigUInt.Word`,
    /// and two unrelated generic `typealias Word = Element` inside `Units`/`Array`
    /// extensions — all keyed under `"Word"`). Resolving a stored field of `BigUInt`
    /// must follow `BigUInt`'s OWN alias (→ `UInt`), not a stray generic one whose
    /// RHS (`Element`) is unresolvable and would falsely reject the type. Candidate
    /// preference per hop: (1) alias whose `enclosingType` == the current owner, then
    /// (2) any alias whose chain bottoms out in a known scalar/codable leaf, then
    /// (3) first declared. The owner advances to the chosen alias's enclosing type so
    /// a qualified hop (`BigInt.Word = BigUInt.Word`) re-resolves in the right scope.
    private func resolveAliasChain(_ name: String, owner: String?, index: [String: [Decl]]) -> String {
        var cur = name
        var curOwner = owner
        var depth = 0
        while depth < 8, let candidates = index[cur]?.filter({ $0.kind == .typealias_ }), !candidates.isEmpty {
            // Pick the best alias decl for this hop.
            let chosen = candidates.first { $0.enclosingType == curOwner && curOwner != nil }
                ?? candidates.first { aliasResolvesToScalar($0, index: index) }
                ?? candidates.first!
            guard let ta = chosen.node.as(TypeAliasDeclSyntax.self),
                  let rhs = SymbolTable.leadingNominal(ta.initializer.value.trimmedDescription),
                  rhs != cur else { break }
            // If the RHS was qualified (`BigUInt.Word`), advance the owner scope so the
            // next hop prefers that type's own alias.
            let rawRHS = ta.initializer.value.trimmedDescription
            if rawRHS.contains("."), let qual = rawRHS.split(separator: ".").dropLast().last.map(String.init) {
                curOwner = qual
            } else {
                curOwner = chosen.enclosingType
            }
            cur = rhs
            depth += 1
        }
        return cur
    }

    /// One-hop check: does this typealias's RHS bottom out in a scalar/codable leaf?
    /// Used to disambiguate same-named aliases (prefer `Word = UInt` over the generic
    /// `Word = Element`). Bounded; never recurses through `resolveAliasChain` (avoids
    /// mutual recursion) — it walks the chain locally with first-declared selection.
    private func aliasResolvesToScalar(_ alias: Decl, index: [String: [Decl]]) -> Bool {
        guard let ta0 = alias.node.as(TypeAliasDeclSyntax.self),
              var cur = SymbolTable.leadingNominal(ta0.initializer.value.trimmedDescription) else { return false }
        var depth = 0
        while depth < 8 {
            if isCodableLeaf(cur) || Self.safeLeaves.contains(cur) { return true }
            guard let ta = index[cur]?.first(where: { $0.kind == .typealias_ })?.node.as(TypeAliasDeclSyntax.self),
                  let rhs = SymbolTable.leadingNominal(ta.initializer.value.trimmedDescription),
                  rhs != cur else { return false }
            cur = rhs
            depth += 1
        }
        return false
    }

    private func appendLeaf(_ rawType: String, owner: String?, index: [String: [Decl]], into out: inout [(String, Bool)]) {
        // A function-typed stored field (`() -> Void`, `(Int) -> String`, even
        // `[() -> Void]`) is captured runtime state — not Codable, not reconstructable.
        // Mark it non-bundlable so the owning type is rejected, instead of silently
        // skipping it (which let swift-parsing's `Benchmarking._tearDown` closure pass
        // the gate and ship a broken candidate). A `->` only appears in a function type
        // within a stored-property type annotation.
        if rawType.contains("->") { out.append((rawType, false)); return }
        // Decompose Array/Dictionary/Optional element types.
        for leaf in decomposeLeaves(rawType) {
            guard let raw = SymbolTable.leadingNominal(leaf) else { continue }
            // Resolve typealias chains (`Word` → `UInt`) so an aliased scalar isn't
            // wrongly rejected as unbundlable. `owner` disambiguates same-named aliases.
            let nominal = resolveAliasChain(raw, owner: owner, index: index)
            if isCodableLeaf(nominal) { continue }
            if let d = resolveType(nominal, index: index) {
                if d.kind == .valueType { out.append((nominal, true)) }
                else { out.append((nominal, false)) } // class/protocol → not bundlable
            } else {
                // Unknown / non-Codable Foundation reference (NSRegularExpression,
                // Scanner, formatters …) → cannot reconstruct as a Codable boundary.
                out.append((nominal, false))
            }
        }
    }

    /// Decompose `[A: B]`, `[A]`, `A?`, `(A, B)` into their leaf nominal strings.
    private func decomposeLeaves(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("?") || s.hasSuffix("!") { s = String(s.dropLast()) }
        if s.hasPrefix("["), s.hasSuffix("]") {
            let inner = String(s.dropFirst().dropLast())
            if let colon = splitTopLevelColon(inner) {
                return decomposeLeaves(colon.0) + decomposeLeaves(colon.1)
            }
            return decomposeLeaves(inner)
        }
        if s.hasPrefix("("), s.hasSuffix(")") {
            let inner = String(s.dropFirst().dropLast())
            return splitTopLevelCommas(inner).flatMap { decomposeLeaves($0) }
        }
        // Generic `Foo<Bar>`: take Foo + its args.
        if let lt = s.firstIndex(of: "<"), s.hasSuffix(">") {
            let head = String(s[s.startIndex..<lt])
            let args = String(s[s.index(after: lt)..<s.index(before: s.endIndex)])
            return [head] + splitTopLevelCommas(args).flatMap { decomposeLeaves($0) }
        }
        return [s]
    }

    private func splitTopLevelColon(_ s: String) -> (String, String)? {
        var depth = 0
        for (i, ch) in s.enumerated() {
            if ch == "<" || ch == "[" || ch == "(" { depth += 1 }
            else if ch == ">" || ch == "]" || ch == ")" { depth -= 1 }
            else if ch == ":" && depth == 0 {
                let idx = s.index(s.startIndex, offsetBy: i)
                return (String(s[s.startIndex..<idx]), String(s[s.index(after: idx)...]))
            }
        }
        return nil
    }
    private func splitTopLevelCommas(_ s: String) -> [String] {
        var parts: [String] = []; var depth = 0; var cur = ""
        for ch in s {
            if ch == "<" || ch == "[" || ch == "(" { depth += 1 }
            else if ch == ">" || ch == "]" || ch == ")" { depth -= 1 }
            if ch == "," && depth == 0 { parts.append(cur); cur = "" } else { cur.append(ch) }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur) }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Custom initializers

    /// The call-site argument-label signature of an initializer's PARAMETERS, used to
    /// match a `Type(args)` / `.init(args)` call against the inits the reconstruction
    /// actually carries. `labels` is the ordered external argument labels (`_` for an
    /// unlabeled param); `requiredCount` is the number of LEADING params with no
    /// default value, so a call may omit trailing defaulted args.
    struct InitSig: Hashable {
        let labels: [String]
        let requiredCount: Int

        /// Does a call providing `callLabels` (in order) match this init's signature?
        /// The call must supply a prefix of `labels` of length ≥ `requiredCount`, with
        /// each supplied label equal to the corresponding param label. (Swift also
        /// allows omitting a non-trailing default, but value-type inits here are simple
        /// positional ones — a prefix match is sufficient and conservative.)
        func accepts(callLabels: [String]) -> Bool {
            guard callLabels.count >= requiredCount, callLabels.count <= labels.count else { return false }
            for (i, l) in callLabels.enumerated() where l != labels[i] { return false }
            return true
        }
    }

    /// Extract the external argument-label signature of an initializer declaration.
    private func initSig(of node: InitializerDeclSyntax) -> InitSig {
        var labels: [String] = []
        var required = 0
        var sawDefault = false
        for p in node.signature.parameterClause.parameters {
            // The EXTERNAL label is `firstName` unless it is `_`. A param with a
            // secondName still uses firstName as its external label.
            labels.append(p.firstName.text)
            if p.defaultValue != nil { sawDefault = true }
            else if !sawDefault { required += 1 }
        }
        return InitSig(labels: labels, requiredCount: required)
    }

    /// Candidate custom initializers declared on a value type (across its primary decl
    /// + extensions): non-failable, non-throwing, non-async, non-generic, with a body,
    /// whose parameter types are ALL reconstructable (bundled value types / WASM-safe
    /// leaves / stdlib). `init(from:)` (Codable), `ExpressibleBy…` conformance inits
    /// (`init(arrayLiteral:)`, `init(integerLiteral:)`, …), variadic, and
    /// platform-bridge inits (`init(_ p: CGPoint)`) are excluded — the minimal Codable
    /// reconstruction cannot reproduce them and emitting one would not compile (which
    /// would POISON the whole per-type file and cascade-demote dependents).
    ///
    /// `paramTypeSafe` decides whether a param's leaf types are all reconstructable. It
    /// is intentionally STRICTER than the stored-property gate: it admits a param type
    /// ONLY when every leaf is a bundled value type or a scalar/string leaf — NOT
    /// system geometry types (CGPoint/CGSize) whose construction relies on platform
    /// APIs the reconstruction never carries.
    private func candidateCustomInits(of typeName: String, bundledValueTypes: Set<String>,
                                      members: [String: [Syntax]], index: [String: [Decl]]) -> [InitializerDeclSyntax] {
        guard let all = members[typeName] else { return [] }
        // A type whose reconstruction is LOSSY (it conforms to a protocol the minimal
        // Codable struct cannot faithfully reproduce — `Collection`/`Sequence`/
        // `RandomAccessCollection`/`ExpressibleBy…`/…) must NOT have its inits emitted:
        // a caller constructing it (`Words(self)`) would otherwise be admitted into a
        // SHARED surface, and the type's broken reconstruction (a dropped conformance /
        // an unqualified nested return type) cascade-poisons every dependent when the
        // convergence loop isolates it. Reject up-front so such a construction stays a
        // "custom init the reconstruction lacks" (the conservative baseline behaviour).
        if !typeReconstructionIsFaithful(typeName, index: index) { return [] }
        func paramTypeSafe(_ raw: String) -> Bool {
            for leaf in decomposeLeaves(raw) {
                guard let nom0 = SymbolTable.leadingNominal(leaf) else { return false }
                let nom = resolveAliasChain(nom0, owner: typeName, index: index)
                if bundledValueTypes.contains(nom) { continue }
                if isCodableLeaf(nom) || Self.safeLeaves.contains(nom)
                    || Self.safeContainers.contains(nom) { continue }
                return false   // CGPoint / native / unknown → unsafe param type.
            }
            return true
        }
        // Conformance inits whose label set marks an `ExpressibleBy…` literal init —
        // never reconstructable (the minimal Codable type lacks the conformance).
        let literalConformanceLabels: Set<String> = [
            "arrayLiteral", "integerLiteral", "floatLiteral", "booleanLiteral",
            "stringLiteral", "unicodeScalarLiteral", "extendedGraphemeClusterLiteral",
            "dictionaryLiteral", "nilLiteral",
        ]
        var out: [InitializerDeclSyntax] = []
        for m in all {
            guard let initDecl = m.as(InitializerDeclSyntax.self) else { continue }
            if initDecl.optionalMark != nil { continue }                 // init? (failable)
            if initDecl.genericParameterClause != nil { continue }       // generic
            if let eff = initDecl.signature.effectSpecifiers,
               eff.asyncSpecifier != nil || eff.throwsClause != nil { continue }
            if initDecl.body == nil { continue }
            let params = initDecl.signature.parameterClause.parameters
            // `init(from decoder:)` — Codable synthesis provides it.
            if params.count == 1, params.first?.firstName.text == "from",
               (params.first?.type.trimmedDescription.contains("Decoder") ?? false) { continue }
            // `ExpressibleBy…` conformance init.
            if params.contains(where: { literalConformanceLabels.contains($0.firstName.text) }) { continue }
            // Variadic param (`Double...`) — forwarding/labeling unreliable.
            if params.contains(where: { $0.ellipsis != nil }) { continue }
            // Any param whose declared type is NOT fully reconstructable → emitting the
            // init would not compile. (Closures/inout/escaping are not codable leaves,
            // so they are rejected here too.)
            if params.contains(where: { !paramTypeSafe($0.type.trimmedDescription) }) { continue }
            // Structural gate: admit ONLY inits whose body is a sequence of plain
            // stored-field assignments (`self.x = …`) and/or delegations (`self.init(…)`
            // / `Type(…)`). A full self-replacement (`self = <expr>`) or any other
            // statement shape (loops, `guard`, array-mapping inits like
            // `self = stride(…).map { … }`) is rejected — the reconstruction cannot
            // guarantee such a body compiles, and a non-compiling init poisons the
            // whole per-type file.
            if !initBodyIsSimpleAssignmentsOrDelegation(initDecl) { continue }
            // A bare literal (`0`, `1.0`, `"x"`, `[…]`) passed as an argument to a
            // CONSTRUCTION (`self.init(…)`, `Type(…)`, `.init(…)`) may land on a bundled
            // value-type parameter whose reconstruction lacks the `ExpressibleBy…Literal`
            // conformance (e.g. BigInt's `self.init(sign: .plus, magnitude: 0)` where
            // `magnitude: BigUInt`) → would not compile. Reject such inits conservatively
            // (literals into enum-case constructors / scalar params are NOT
            // constructions, so `.inline(0, 0)` with scalar `Word` stays admitted).
            if initBodyHasLiteralConstructionArg(initDecl) { continue }
            out.append(initDecl)
        }
        return out
    }

    /// Stdlib protocols that the minimal Codable reconstruction CANNOT reproduce and
    /// whose loss CASCADES: the reconstruction drops the conformance while still
    /// emitting partial requirement members (a `subscript`/`startIndex` whose return
    /// type is an unqualified nested alias), and any use site relying on the protocol
    /// (iteration / indexing / literal construction) fails to compile. A type
    /// conforming to one of these (BigInt's `Words: RandomAccessCollection`) must NOT
    /// be treated as a clean construction target — otherwise admitting a caller into a
    /// shared surface cascade-poisons every dependent when the loop isolates it. App
    /// protocols (Euclid's `ApproximateEquality`/`Interpolatable`) are NOT here: the
    /// reconstruction simply omits them, harmless unless a use site needs them (and
    /// the member-surface gate already rejects such a use site).
    private static let cascadingProtocols: Set<String> = [
        "Collection", "BidirectionalCollection", "RandomAccessCollection",
        "MutableCollection", "RangeReplaceableCollection", "Sequence",
        "IteratorProtocol", "ExpressibleByArrayLiteral", "ExpressibleByDictionaryLiteral",
        "ExpressibleByStringLiteral", "ExpressibleByIntegerLiteral",
        "ExpressibleByFloatLiteral", "ExpressibleByBooleanLiteral",
        "OptionSet", "SetAlgebra",
        // Numeric protocols imply `ExpressibleByIntegerLiteral` + a large operator
        // surface the reconstruction cannot reproduce (BigInt's `BigUInt:
        // UnsignedInteger`, `BigInt: SignedInteger`). A literal (`magnitude: 0`) or a
        // protocol operator on such a type would not compile against the minimal
        // reconstruction → exclude from init-emission / construction-acceptance.
        "BinaryInteger", "FixedWidthInteger", "SignedInteger", "UnsignedInteger",
        "SignedNumeric", "Numeric", "BinaryFloatingPoint", "FloatingPoint",
        "Strideable",
    ]

    /// Whether `typeName`'s reconstruction is faithful enough to be a clean
    /// construction target — i.e. it does NOT conform to a `cascadingProtocols` member
    /// (across its primary decl AND any `extension Type: …` conformance). Conservative
    /// in the safe direction: only a KNOWN cascading conformance excludes the type;
    /// everything else (app protocols, value protocols) is admitted, matching the
    /// reconstruction's existing lossy-but-harmless omission of them.
    private func typeReconstructionIsFaithful(_ typeName: String, index: [String: [Decl]]) -> Bool {
        func clauseHasCascading(_ inh: InheritanceClauseSyntax?) -> Bool {
            guard let inh else { return false }
            for t in inh.inheritedTypes {
                guard let nom = SymbolTable.leadingNominal(t.type.trimmedDescription) else { continue }
                if Self.cascadingProtocols.contains(nom) { return true }
            }
            return false
        }
        // Primary decl + same-name extensions are all indexed under `typeName`.
        for d in index[typeName] ?? [] {
            if let s = d.node.as(StructDeclSyntax.self), clauseHasCascading(s.inheritanceClause) { return false }
            if let e = d.node.as(EnumDeclSyntax.self), clauseHasCascading(e.inheritanceClause) { return false }
            if let ext = d.node.as(ExtensionDeclSyntax.self), clauseHasCascading(ext.inheritanceClause) { return false }
        }
        return true
    }

    /// Does the init body pass a bare literal as an argument to a value-type
    /// CONSTRUCTION (`self.init(…)`, `Type(…)`, `.init(…)`)? Such a literal relies on an
    /// `ExpressibleBy…Literal` conformance the minimal reconstruction lacks when the
    /// target param is a bundled value type. Conservative (over-rejects: a literal into
    /// a genuinely scalar construction param is rare and not worth the type analysis).
    private func initBodyHasLiteralConstructionArg(_ initDecl: InitializerDeclSyntax) -> Bool {
        guard let body = initDecl.body else { return false }
        let v = LiteralConstructionArgVisitor(viewMode: .sourceAccurate)
        v.walk(Syntax(body))
        return v.found
    }

    private final class LiteralConstructionArgVisitor: SyntaxVisitor {
        var found = false
        private func isLiteral(_ e: ExprSyntax) -> Bool {
            if e.is(IntegerLiteralExprSyntax.self) || e.is(FloatLiteralExprSyntax.self)
                || e.is(BooleanLiteralExprSyntax.self) || e.is(StringLiteralExprSyntax.self)
                || e.is(ArrayExprSyntax.self) || e.is(NilLiteralExprSyntax.self) { return true }
            if let pre = e.as(PrefixOperatorExprSyntax.self), pre.operator.text == "-" {
                return pre.expression.is(IntegerLiteralExprSyntax.self)
                    || pre.expression.is(FloatLiteralExprSyntax.self)
            }
            return false
        }
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            // Construction calls: `Type(...)` (uppercase callee), `self.init(...)`,
            // `.init(...)`, `Type.init(...)`. (An enum case `.inline(...)` is a
            // MemberAccess whose declName is lowercase or not `init` — not a value-type
            // construction, so its scalar literal args are fine.)
            var isConstruction = false
            if let d = node.calledExpression.as(DeclReferenceExprSyntax.self),
               d.baseName.text.first?.isUppercase ?? false {
                isConstruction = true
            } else if let m = node.calledExpression.as(MemberAccessExprSyntax.self),
                      m.declName.baseName.text == "init" {
                isConstruction = true
            }
            if isConstruction, node.arguments.contains(where: { isLiteral($0.expression) }) {
                found = true
            }
            return .visitChildren
        }
    }

    /// True iff the init body is composed ONLY of statements that the reconstruction
    /// can faithfully reproduce: stored-field assignments (`self.field = expr`),
    /// a delegating call (`self.init(args)`), and `assert`/`precondition` guards. Any
    /// other statement (a `self = <expr>` replacement, control flow, a loop, a `let`
    /// binding, a bare method call) makes the body's compile-safety unprovable → the
    /// init is not emitted. Conservative: false negatives only (never admits a body it
    /// cannot vouch for).
    private func initBodyIsSimpleAssignmentsOrDelegation(_ initDecl: InitializerDeclSyntax) -> Bool {
        guard let body = initDecl.body else { return false }
        for stmt in body.statements {
            let item = stmt.item
            // `self.init(args)` delegation — a function call whose callee is `self.init`.
            if let call = item.as(FunctionCallExprSyntax.self) {
                if let m = call.calledExpression.as(MemberAccessExprSyntax.self),
                   m.declName.baseName.text == "init",
                   m.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
                    continue
                }
                // `assert(...)` / `precondition(...)` / `assertionFailure(...)` guard.
                if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
                   ["assert", "precondition", "assertionFailure", "preconditionFailure"]
                       .contains(callee.baseName.text) {
                    continue
                }
                return false
            }
            // `self.field = expr` assignment — a SequenceExpr `self.field` `=` `expr`,
            // or a pre-folded InfixOperatorExpr.
            if let seq = item.as(SequenceExprSyntax.self) {
                let elems = Array(seq.elements)
                guard elems.count == 3,
                      elems[1].as(AssignmentExprSyntax.self) != nil,
                      isSelfFieldAccess(elems[0]) else { return false }
                continue
            }
            if let infix = item.as(InfixOperatorExprSyntax.self) {
                guard infix.operator.as(AssignmentExprSyntax.self) != nil,
                      isSelfFieldAccess(infix.leftOperand) else { return false }
                continue
            }
            return false
        }
        return true
    }

    /// `self.field` (a member access whose base is `self`).
    private func isSelfFieldAccess(_ expr: ExprSyntax) -> Bool {
        guard let m = expr.as(MemberAccessExprSyntax.self) else { return false }
        return m.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
    }

    /// The set of custom initializers the reconstruction will EMIT for each bundled
    /// value type, computed deterministically from the bundled-type set + the
    /// reconstructed member surface. Shared SINGLE SOURCE OF TRUTH between (a) the
    /// member-surface gate (`resolveMemberSurface`, so a member calling one of these
    /// inits is accepted) and (b) the emitter (`synthesizeValueType`, which renders
    /// exactly this set). Both must agree or a member would be accepted but its init
    /// not carried (→ compile failure).
    ///
    /// An init is eligible iff its body is self-contained against: stored fields, the
    /// reconstructed operators, the reconstructed member surface, scalar leaves, AND
    /// — for `self.init(…)` / `Type(…)` delegations — the memberwise init or another
    /// eligible sibling init. A small fixpoint admits chains (`init(_:_:_:)` →
    /// `self.init(unchecked:…)`): start optimistic (all candidates eligible) and drop
    /// any whose body references a non-eligible target until stable.
    func eligibleCustomInits(
        for typeName: String, bundledValueTypes: Set<String>,
        surface: [String: [String]], members: [String: [Syntax]], index: [String: [Decl]]
    ) -> [InitializerDeclSyntax] {
        let candidates = candidateCustomInits(of: typeName, bundledValueTypes: bundledValueTypes,
                                              members: members, index: index)
        guard !candidates.isEmpty else { return [] }
        // Per-type context shared by the gate.
        var storedFields: [String: Set<String>] = [:]
        var operatorSet: [String: Set<String>] = [:]
        var memberwiseLabels: [String: [String]] = [:]
        for t in bundledValueTypes {
            storedFields[t] = storedFieldNamesFromMembers(t, members: members)
            operatorSet[t] = reconstructedOperatorTokens(t, members: members, index: index)
            memberwiseLabels[t] = storedFieldOrderedNames(t, members: members)
        }
        // A member is "live" iff it is in the emitted surface or a stored field — the
        // SAME definition the member gate used. Inits read members (`normal.direction`,
        // `position._quantized()`); those must be reconstructed too.
        func liveMember(_ type: String, _ name: String) -> Bool {
            if storedFields[type]?.contains(name) == true { return true }
            return surface[type]?.contains(name) ?? false
        }
        // Fixpoint over THIS type's candidate inits: start with all eligible, drop any
        // whose body fails self-containment given the currently-eligible init set.
        var eligible = candidates
        var changed = true
        while changed {
            changed = false
            var sigs: [String: [InitSig]] = [:]
            sigs[typeName] = eligible.map { initSig(of: $0) }
            var survivors: [InitializerDeclSyntax] = []
            for ini in eligible {
                let reason = memberSelfContainmentFailure(
                    Syntax(ini), ownerType: typeName, bundledValueTypes: bundledValueTypes,
                    storedFields: storedFields, operatorSet: operatorSet,
                    memberwiseLabels: memberwiseLabels, liveMember: liveMember,
                    index: index, members: members,
                    customInitSigs: sigs, asInitOfType: typeName)
                if reason == nil { survivors.append(ini) } else { changed = true }
            }
            eligible = survivors
            if eligible.isEmpty { break }
        }
        // Dedup by signature (an init may be indexed twice across extensions/files;
        // emitting two inits with the same labels is an `invalid redeclaration`).
        var seen: Set<InitSig> = []
        var unique: [InitializerDeclSyntax] = []
        for ini in eligible where seen.insert(initSig(of: ini)).inserted {
            // Also avoid colliding with the SYNTHESIZED memberwise init's label set.
            if initSig(of: ini).labels == (memberwiseLabels[typeName] ?? []) { continue }
            unique.append(ini)
        }
        return unique
    }

    /// Render a custom initializer for emission into the reconstructed type: access
    /// modifiers stripped (the bundled type is internal), `assert`/`precondition`
    /// guard statements DROPPED (they may reference members we don't reconstruct, and
    /// are debug-only no-ops in release). The init was already proven self-contained
    /// (its `self.field = …` assignments and `self.init(…)` delegations compile).
    private func renderCustomInit(_ node: InitializerDeclSyntax) -> String {
        var stripped = node
        if let body = node.body {
            let kept = body.statements.filter { stmt in
                guard let call = stmt.item.as(FunctionCallExprSyntax.self),
                      let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) else { return true }
                return !["assert", "precondition", "assertionFailure", "preconditionFailure"]
                    .contains(callee.baseName.text)
            }
            stripped = node.with(\.body, body.with(\.statements, kept))
        }
        return accessStripped(stripped.trimmedDescription)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    " + $0 }.joined(separator: "\n")
    }

    // MARK: - Synthesis

    /// Reconstruct a MINIMAL `Codable` value type — its stored properties / enum
    /// cases — PLUS the reachability-gated PURE MEMBER SURFACE (`surfaceMembers`):
    /// the methods / computed properties the shipped logic reaches transitively
    /// through the value type's member call graph (so a function calling `v.dot(u)`
    /// / `v.length` compiles in the module). The members were proven pure by the
    /// closure's member-surface walk (`memberRejection`), so emitting their full
    /// bodies is safe; an impure member was already rejected, demoting its caller.
    /// Operators ride along via `operatorExtensionSource`.
    private func synthesizeValueType(_ decl: Decl, members: [String: [Syntax]],
                                     surfaceMembers: [String: [String]], index: [String: [Decl]],
                                     bundledValueTypes: Set<String> = []) -> String {
        let surface = surfaceMembers[decl.name] ?? []
        if decl.typeKind == .enum, let e = decl.node.as(EnumDeclSyntax.self) {
            return synthesizeEnum(e, enclosingTypeName: decl.enclosingType, aliasIndex: index)
                + memberSurfaceExtension(decl.name, surface: surface, members: members)
                + operatorExtensionSource(decl.name, members: members, index: index, emittedSurface: Set(surface))
        }
        guard let s = decl.node.as(StructDeclSyntax.self) else {
            return "// (could not reconstruct \(decl.name))"
        }
        // Preserve auto-synthesized conformances (Swift synthesizes `==`/`hash` when all
        // stored fields conform — they did in the original). Dropping Equatable broke
        // `a == b` use sites (e.g. MessageKit HorizontalEdgeInsets). Comparable is NOT
        // auto-synthesized, so it is left to the reconstructed `<` operator instead.
        var structConformances = ["Codable"]
        if let inh = s.inheritanceClause {
            for t in inh.inheritedTypes {
                let n = t.type.trimmedDescription
                if ["Equatable", "Hashable", "Sendable"].contains(n) && !structConformances.contains(n) {
                    structConformances.append(n)
                }
            }
        }
        // If the reconstruction emits BOTH `==` and `<`, declare `Comparable` so the
        // derived `>`/`<=`/`>=` are available — a dependent value type (`BigInt.<`
        // comparing its `BigUInt magnitude` via `>`) then compiles, and a `Self`-typed
        // boundary that needs ordering works. Conditional on `<` being reconstructed so
        // the conformance is always satisfiable (Comparable requires `<`).
        let emittedOps = Set(reconstructedOperatorDecls(decl.name, members: members,
                                                        index: index, surfaceOverride: Set(surface)).map { $0.name.text })
        if emittedOps.contains("==") && emittedOps.contains("<") && !structConformances.contains("Comparable") {
            structConformances.append("Comparable")
        }
        var lines: [String] = ["struct \(decl.name): \(structConformances.joined(separator: ", ")) {"]
        // Fix S5: a reconstructed struct is severed from its enclosing scope, so a
        // field type spelled with an ALIAS (`NS.Word`/`Word`) or a MODULE qualifier
        // (`Euclid.Vector`) fails to compile in the new context even though the
        // VALIDATOR already accepted its alias-resolved/unqualified LEAF. Re-emit the
        // resolved/unqualified leaf spelling the validator computed (`resolveFieldType`),
        // AND collect any enclosing-scope typealias the resolution relied on so a leaf
        // genuinely spelled with a project alias still resolves (mirrors the enum path).
        var neededAliases: [(name: String, resolved: String)] = []
        var bodyLines: [String] = []
        let fieldOwner = decl.name
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
            // Skip `static`/`class` properties (not instance fields).
            if v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
            for binding in v.bindings {
                // A computed property (a GETTER accessor) is not a stored field. BUT a
                // stored property with a `didSet`/`willSet` OBSERVER *is* a field — emit
                // it as a plain stored field (drop the observer), else Codable/the
                // memberwise init lose it.
                if let accessor = binding.accessorBlock, isComputedGetter(accessor) { continue }
                guard let id = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let type = binding.typeAnnotation?.type.trimmedDescription else { continue }
                let kw = v.bindingSpecifier.text  // let / var
                let resolvedType = resolveFieldTypeSpelling(
                    type, owner: fieldOwner, enclosing: decl.enclosingType,
                    index: index, neededAliases: &neededAliases)
                bodyLines.append("    \(kw) \(id): \(resolvedType)")
            }
        }
        // Re-emit the enclosing-scope aliases the field types relied on (a leaf the
        // validator resolved through a project alias whose RHS is a Codable leaf, e.g.
        // `enum NS { typealias Word = UInt }; struct Big { let storage: [NS.Word] }`).
        var seenAlias = Set<String>()
        for a in neededAliases where seenAlias.insert(a.name).inserted {
            lines.append("    typealias \(a.name) = \(a.resolved)")
        }
        lines.append(contentsOf: bodyLines)
        // STATIC stored constants with a SIMPLE LITERAL initializer (string / number /
        // bool) are pure and reconstructed verbatim — e.g. a namespace struct of
        // `static let copyItem = "Copy"` (string/font/config tables). Reference sites
        // (`ContextMenuItems.copyItem`) then resolve. Non-literal statics
        // (`static let zero = Vector(0,0)`) are still dropped — they may reference the
        // type's own init or other unbundled state.
        for member in s.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self),
                  v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) else { continue }
            for binding in v.bindings {
                guard binding.accessorBlock == nil,                       // stored, not computed
                      let id = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let initVal = binding.initializer?.value,
                      Self.isSimpleLiteral(initVal) else { continue }
                let kw = v.bindingSpecifier.text
                let typePart = binding.typeAnnotation.map { ": \($0.type.trimmedDescription)" } ?? ""
                lines.append("    static \(kw) \(id)\(typePart) = \(initVal.trimmedDescription)")
            }
        }
        // Emit nested typealiases that resolve to a WASM-safe leaf, so a stored field
        // (or nested-enum case) spelled with the alias (`storage: [Word]`) compiles in
        // the reconstructed type. Emit the RESOLVED leaf (`= UInt`), which always
        // compiles, rather than the original RHS (which may be a qualified/aliased name).
        for member in s.memberBlock.members {
            guard let ta = member.decl.as(TypeAliasDeclSyntax.self) else { continue }
            let resolved = resolveAliasChain(ta.name.text, owner: decl.name, index: index)
            if isCodableLeaf(resolved) || Self.knownSystemTypes.contains(resolved) {
                lines.append("    typealias \(ta.name.text) = \(resolved)")
            }
        }
        // The memberwise init + Codable synthesis come for free.
        lines.append("}")
        // Emit the eligible CUSTOM inits in an EXTENSION (so the struct-body memberwise
        // init is preserved). Computed via the same `eligibleCustomInits` the member
        // gate used, so every accepted `Type(args)` call has its init carried here.
        let initExt = customInitExtension(decl.name, surfaceMembers: surfaceMembers,
                                          bundledValueTypes: bundledValueTypes.isEmpty
                                              ? Set(surfaceMembers.keys) : bundledValueTypes,
                                          members: members, index: index)
        return lines.joined(separator: "\n")
            + initExt
            + memberSurfaceExtension(decl.name, surface: surface, members: members)
            + operatorExtensionSource(decl.name, members: members, index: index, emittedSurface: Set(surface))
    }

    /// Render the eligible custom inits of `typeName` as an `extension … { init … }`
    /// block (empty string if none). Mirrors `memberSurfaceExtension` formatting.
    private func customInitExtension(_ typeName: String, surfaceMembers: [String: [String]],
                                     bundledValueTypes: Set<String>,
                                     members: [String: [Syntax]], index: [String: [Decl]]) -> String {
        let inits = eligibleCustomInits(for: typeName, bundledValueTypes: bundledValueTypes,
                                        surface: surfaceMembers, members: members, index: index)
        guard !inits.isEmpty else { return "" }
        let bodies = inits.map { renderCustomInit($0) }
        return "\n\nextension \(typeName) {\n" + bodies.joined(separator: "\n\n") + "\n}"
    }

    /// A pure compile-time literal initializer: string (no interpolation), integer,
    /// float, bool, or a negated number. Such a value can be reconstructed verbatim
    /// (no references to other declarations / runtime state).
    static func isSimpleLiteral(_ expr: ExprSyntax) -> Bool {
        if let str = expr.as(StringLiteralExprSyntax.self) {
            return str.segments.allSatisfy { $0.is(StringSegmentSyntax.self) }
        }
        if expr.is(IntegerLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self)
            || expr.is(BooleanLiteralExprSyntax.self) { return true }
        if let pre = expr.as(PrefixOperatorExprSyntax.self), pre.operator.text == "-" {
            return pre.expression.is(IntegerLiteralExprSyntax.self) || pre.expression.is(FloatLiteralExprSyntax.self)
        }
        return false
    }

    /// Emit the reconstructed PURE MEMBER SURFACE — the methods / computed
    /// properties named in `surface` — as `extension <Type> { … }`, full bodies,
    /// access modifiers stripped (so the bundled, internal type compiles). The
    /// members were proven pure by the closure walk; here we just render them. A
    /// `static` member keeps `static`; an instance member stays instance (its
    /// `self` is the decoded receiver / a sibling member's `self`). Computed
    /// properties keep their accessor block verbatim.
    private func memberSurfaceExtension(_ typeName: String, surface: [String],
                                        members: [String: [Syntax]]) -> String {
        guard !surface.isEmpty, members[typeName] != nil else { return "" }
        var bodies: [String] = []
        var emitted: Set<String> = []
        // Preserve the closure's discovery order for determinism.
        for name in surface {
            guard emitted.insert(name).inserted else { continue }
            guard let node = memberDecl(named: name, of: typeName, members: members) else { continue }
            let src = accessStripped(getterOnlySource(of: node))
            bodies.append(src.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    " + $0 }.joined(separator: "\n"))
        }
        guard !bodies.isEmpty else { return "" }
        return "\n\nextension \(typeName) {\n" + bodies.joined(separator: "\n\n") + "\n}"
    }

    /// Fix A integration: emit the type's pure OPERATOR members (`==`, `<`, `+`, …)
    /// as an `extension <Type> { … }`. Operators are the ONE part of the member
    /// surface we DO reconstruct on a bundled value type, because (a) an exported
    /// operator's wrapper calls the real operator (`a == b`) and so needs it in the
    /// module, and (b) operators are typically small, self-contained value
    /// comparisons/arithmetic. An operator whose body touches a forced-native
    /// construct or a `mustStayNative` symbol is DROPPED (so the type still
    /// compiles); an export needing a dropped operator fails to compile → demotes
    /// (kept native), conservative. Generic operators are dropped (can't be @_cdecl).
    private func operatorExtensionSource(_ typeName: String, members: [String: [Syntax]],
                                         index: [String: [Decl]],
                                         emittedSurface: Set<String> = []) -> String {
        // Emit EXACTLY the operators the fixpoint proved reconstructable against the
        // ACTUAL emitted member surface (`emittedSurface`). The fixpoint drops an
        // operator that reads a non-emitted member (`+` → `adding`, not in surface), is
        // a mutating compound-assignment (`*=`), or applies another DROPPED value-type
        // operator (`-` → `+`). This is the single source of truth shared with
        // `reconstructedOperatorTokens` (the walk's availability gate), so the emitted
        // set always compiles.
        let decls = reconstructedOperatorDecls(typeName, members: members, index: index,
                                               surfaceOverride: emittedSurface)
        var bodies: [String] = []
        // Dedup by operator signature: the same operator can be indexed more than once
        // (declared in multiple extensions / re-collected across files); emitting it
        // twice is an `invalid redeclaration` (BigInt's operators appeared duplicated).
        var seenOperatorSignatures: Set<String> = []
        for f in decls {
            let sig = f.name.text + "(" + f.signature.parameterClause.parameters
                .map { $0.type.trimmedDescription }.joined(separator: ",") + ")"
            guard seenOperatorSignatures.insert(sig).inserted else { continue }
            bodies.append(accessStripped(f.trimmedDescription)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    " + $0 }.joined(separator: "\n"))
        }
        guard !bodies.isEmpty else { return "" }
        return "\n\nextension \(typeName) {\n" + bodies.joined(separator: "\n") + "\n}"
    }

    /// Stored-property names of a value type (the only members the reconstruction
    /// carries besides operators).
    private func storedPropertyNames(of typeName: String, members: [String: [Syntax]]) -> Set<String> {
        var names: Set<String> = []
        guard let all = members[typeName] else { return names }
        for m in all {
            guard let v = m.as(VariableDeclSyntax.self) else { continue }
            for binding in v.bindings where isStoredBinding(binding) {
                if let id = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                    names.insert(id)
                }
            }
        }
        return names
    }

    /// Stored-property names whose declared type is NOT an ABI scalar AND whose type
    /// does NOT reconstruct its own comparison operators — i.e. a nested custom type
    /// whose operator surface the reconstruction omits. An operator touching such a
    /// field is dropped (see call site). A non-scalar field whose type is a bundled
    /// value type that reconstructs `==` and `<` (→ Comparable) is OK: comparing those
    /// fields (`a.magnitude < b.magnitude`) compiles against the field type's
    /// reconstructed operators.
    private func nonScalarStoredFieldNames(of typeName: String, members: [String: [Syntax]],
                                           index: [String: [Decl]]? = nil,
                                           visited: Set<String> = []) -> Set<String> {
        var names: Set<String> = []
        guard let all = members[typeName] else { return names }
        for m in all {
            guard let v = m.as(VariableDeclSyntax.self) else { continue }
            for binding in v.bindings where isStoredBinding(binding) {
                guard let id = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let t = binding.typeAnnotation?.type.trimmedDescription else { continue }
                // Scalar (Int/Double/Bool/String/…) or a homogeneous scalar array —
                // those support stdlib operators natively.
                let leaves = Self.decompose(t)
                let allScalar = !leaves.isEmpty && leaves.allSatisfy { Self.isScalarLeaf($0) }
                if allScalar { continue }
                // A single bundled value type whose reconstruction provides `==` and `<`
                // (Comparable + Equatable) is operator-safe — comparing it compiles.
                // `fieldType != typeName` is the 1-hop self-cycle guard; `!visited`
                // generalizes it to multi-hop cycles (`A → B → A`): a field type already
                // on the active recursion path is NOT descended into and is treated
                // conservatively as non-scalar (left in `names`), which terminates the
                // mutual recursion without ever marking something falsely operator-safe.
                if let index, leaves.count == 1, let fieldType = leaves.first,
                   fieldType != typeName,            // 1-hop self-cycle guard (subset of below)
                   !visited.contains(fieldType),     // multi-hop cycle guard (A → B → A)
                   resolveType(fieldType, index: index)?.kind == .valueType,
                   fieldTypeIsComparable(fieldType, members: members, index: index, visited: visited) {
                    continue
                }
                names.insert(id)
            }
        }
        return names
    }

    /// True if the bundled value type `fieldType` reconstructs BOTH `==` and `<` (so it
    /// conforms to Comparable/Equatable in the module and a dependent operator may
    /// compare its fields). Bounded: `visited` carries the active recursion path so the
    /// mutual recursion terminates on value-type reference cycles (`A → B → A`), not just
    /// 1-hop self-cycles.
    private func fieldTypeIsComparable(_ fieldType: String, members: [String: [Syntax]],
                                       index: [String: [Decl]],
                                       visited: Set<String> = []) -> Bool {
        let ops = Set(reconstructedOperatorDecls(fieldType, members: members, index: index,
                                                 visited: visited).map { $0.name.text })
        // An enum compares via auto-synthesized Equatable; allow `==`-only enums too.
        if resolveType(fieldType, index: index)?.typeKind == .enum { return true }
        return ops.contains("==") && ops.contains("<")
    }

    /// True if the operator is a COMPOUND-ASSIGNMENT / mutating operator: its first
    /// parameter is `inout` (`+=`, `*=`, `&=`, `<<=`). Such an operator mutates in
    /// place — discarded by the value-copy ABI — and its body usually writes via a
    /// subscript-setter or an in-place helper the reconstruction does not carry. The
    /// non-mutating binary forms (`+`, `*`, `==`) are what an export actually needs.
    private func isCompoundAssignmentOperator(_ f: FunctionDeclSyntax) -> Bool {
        guard let first = f.signature.parameterClause.parameters.first else { return false }
        if let attrType = first.type.as(AttributedTypeSyntax.self) {
            return attrType.specifiers.contains { $0.as(SimpleTypeSpecifierSyntax.self)?.specifier.text == "inout" }
        }
        return false
    }

    /// True if an operator body accesses a `.member` that is a NON-SCALAR stored
    /// field (so it would apply that field type's custom operator surface).
    private func operatorAccessesNonScalarField(_ f: FunctionDeclSyntax, nonScalarFields: Set<String>) -> Bool {
        guard !nonScalarFields.isEmpty else { return false }
        let v = MemberAccessVisitor(viewMode: .sourceAccurate)
        v.walk(Syntax(f))
        return !v.memberNames.isDisjoint(with: nonScalarFields)
    }

    /// True if the operator's body APPLIES a value-type operator token (arithmetic/
    /// bitwise/comparison) that is NOT reconstructed on the relevant operand type — so
    /// emitting it would fail to compile. Used IN ADDITION to the non-scalar-field gate:
    /// a `BigInt.<` comparing its `BigUInt magnitude` via `<`/`>` is fine (BigUInt is
    /// Comparable), but `BigInt.+` summing `magnitude` via BigUInt `+` (NOT
    /// reconstructed) must be dropped. Sound approximation: every applied value-type
    /// operator token must be reconstructed on the OWNER type itself OR on EVERY
    /// non-scalar struct field type the body touches (enum fields compare via the
    /// auto-synthesized `==`). Comparison tokens additionally ride Comparable
    /// (`<` reconstructed ⇒ `>`/`<=`/`>=` derived).
    private func operatorAppliesUnreconstructedFieldOperator(
        _ f: FunctionDeclSyntax, ownerType: String,
        members: [String: [Syntax]], index: [String: [Decl]],
        visited: Set<String> = []
    ) -> Bool {
        let applied = appliedOperatorTokens(in: Syntax(f))
        // Only value-type operators matter (scalar arithmetic on Int/UInt is native).
        let valueOps = applied.intersection(Self.valueTypeOperatorTokens)
        guard !valueOps.isEmpty else { return false }
        // The non-scalar STRUCT field types this body could apply operators to.
        var fieldStructTypes: Set<String> = []
        // A field type already on the active recursion path (`A → B → A`): descending
        // into it to compute its reconstructed operators would recurse unboundedly. The
        // body applies a value-type operator and we cannot prove this field type
        // reconstructs it without recursing, so be conservative and reject the operator
        // (returning true) — never falsely mark an operator reconstructable.
        var cyclicField = false
        if let all = members[ownerType] {
            for m in all {
                guard let v = m.as(VariableDeclSyntax.self) else { continue }
                for b in v.bindings where isStoredBinding(b) {
                    guard let t = b.typeAnnotation?.type.trimmedDescription else { continue }
                    let leaves = Self.decompose(t)
                    guard leaves.count == 1, let ft = leaves.first, ft != ownerType,
                          let d = resolveType(ft, index: index), d.kind == .valueType,
                          d.typeKind == .struct else { continue }
                    if visited.contains(ft) { cyclicField = true; continue }  // cycle: do not recurse
                    fieldStructTypes.insert(ft)
                }
            }
        }
        // A field type on the cycle is treated as not reconstructing the applied operator.
        if cyclicField { return true }
        guard !fieldStructTypes.isEmpty else { return false }
        // Reconstructed operator tokens per field struct type (+ Comparable-derived).
        func reconstructedClosure(_ type: String) -> Set<String> {
            var ops = Set(reconstructedOperatorDecls(type, members: members, index: index,
                                                     visited: visited).map { $0.name.text })
            if ops.contains("<") && ops.contains("==") { ops.formUnion([">", "<=", ">="]) }
            return ops
        }
        let perField = fieldStructTypes.map { reconstructedClosure($0) }
        for tok in valueOps {
            // The body applies value-type operators to FIELD-typed operands (it touches
            // a non-scalar struct field), so the token must be reconstructed on EVERY
            // such field type. (We do not consult the owner's own operators — that would
            // recurse into this very computation; the operands here are field-typed.)
            if !perField.allSatisfy({ $0.contains(tok) }) { return true }
        }
        return false
    }

    /// Value-type binary/prefix operator tokens (arithmetic, bitwise, comparison) that,
    /// when applied to a reconstructed value type's operand, need that type's operator
    /// surface. Scalar uses on Int/Double are native and not gated.
    private static let valueTypeOperatorTokens: Set<String> = [
        "+", "-", "*", "/", "%", "==", "!=", "<", ">", "<=", ">=",
        "&", "|", "^", "<<", ">>", "&+", "&-", "&*", "~",
    ]

    /// True if an operator body reads a `.member` on a value that is NOT a stored
    /// property — i.e. a computed property / method the reconstruction omits.
    /// Conservative: any member-access whose member name is a lowercase identifier
    /// and not in `storedFields`, not a reconstructable PURE member of the type
    /// (`reconstructableMembers` — methods/computed props/subscripts that pass the
    /// purity gate, e.g. BigUInt's `compare`/`count`, which DO get reconstructed onto
    /// the type), and not a safe stdlib member, rejects the operator.
    private func operatorReadsUnreconstructedMember(
        _ f: FunctionDeclSyntax, storedFields: Set<String>,
        reconstructableMembers: Set<String> = []
    ) -> Bool {
        let v = MemberAccessVisitor(viewMode: .sourceAccurate)
        v.walk(Syntax(f))
        for name in v.memberNames {
            guard let first = name.first, first.isLowercase else { continue } // skip Type.case etc.
            if storedFields.contains(name) { continue }
            if reconstructableMembers.contains(name) { continue }
            if Self.stdlibValueMembers.contains(name) { continue }
            return true
        }
        return false
    }

    /// The pure, reconstructable INSTANCE/STATIC member names of a value type: methods,
    /// computed properties, and subscripts whose purity gate (`memberRejection`) passes
    /// — i.e. the members the reconstruction CAN carry. An operator reading one of
    /// these is self-contained (the member is reconstructed alongside it). This walks
    /// the type's own member set only (the operator's transitive surface is seeded into
    /// `neededMembers` by the closure, then emitted by `memberSurfaceExtension`).
    private func reconstructableMemberNames(_ typeName: String, members: [String: [Syntax]],
                                            index: [String: [Decl]]) -> Set<String> {
        guard let all = members[typeName] else { return [] }
        let storedFields = storedPropertyNames(of: typeName, members: members)
        // Candidate members that pass the intrinsic PURITY gate, with their decl nodes.
        var candidates: [(name: String, node: Syntax)] = []
        for m in all {
            if let f = m.as(FunctionDeclSyntax.self) {
                let isOperator = !(f.name.text.first.map { $0.isLetter || $0 == "_" } ?? false)
                if isOperator { continue }
                if memberRejection(m, ownerType: typeName, index: index) == nil { candidates.append((f.name.text, m)) }
            } else if let v = m.as(VariableDeclSyntax.self) {
                if v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
                for b in v.bindings {
                    guard let accessor = b.accessorBlock, isComputedGetter(accessor),
                          let id = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                    if memberRejection(m, ownerType: typeName, index: index) == nil { candidates.append((id, m)) }
                }
            } else if let s = m.as(SubscriptDeclSyntax.self) {
                if memberRejection(m, ownerType: typeName, index: index) == nil { candidates.append(("subscript", Syntax(s))) }
            }
        }
        // FIXPOINT self-containment within the type: a candidate is reconstructable only
        // if every INSTANCE member it reads (`self.x`, `value.member`) is a stored field
        // or another reconstructable candidate or a safe stdlib member. This drops a
        // pure-but-non-self-contained member (`adding` reads `.add`, a MUTATING method
        // that never reconstructs) so a caller (`+` → `adding`) is correctly excluded —
        // keeping this per-type set CONSISTENT with the actual emitted surface (the
        // export walk's fixpoint reaches the same conclusion). Validate the GETTER only
        // for subscripts/computed props (the dropped setter may read more).
        var live = Set(candidates.map { $0.name })
        var changed = true
        while changed {
            changed = false
            for c in candidates where live.contains(c.name) {
                let scope: Syntax = explicitGetterBody(of: c.node).map { Syntax($0) } ?? c.node
                let v = MemberAccessVisitor(viewMode: .sourceAccurate)
                v.walk(scope)
                for name in v.memberNames {
                    guard let first = name.first, first.isLowercase else { continue }
                    if storedFields.contains(name) { continue }
                    if live.contains(name) { continue }
                    if Self.stdlibValueMembers.contains(name) || Self.stdlibCallMembers.contains(name) { continue }
                    live.remove(c.name); changed = true; break
                }
            }
        }
        return live
    }

    /// Stdlib members an operator may read on a stored scalar/collection without
    /// needing reconstruction (so they don't falsely reject a self-contained op).
    private static let stdlibValueMembers: Set<String> = [
        "count", "isEmpty", "first", "last", "magnitude", "rawValue",
        "description", "hashValue", "utf8", "unicodeScalars",
    ]

    private final class MemberAccessVisitor: SyntaxVisitor {
        var memberNames: Set<String> = []
        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            // Skip a CONTEXTUAL leading-dot enum case (`.orderedSame` with no base) — it
            // resolves to a case of a separately-validated type, not an instance member
            // the reconstruction must carry. A qualified `Type.member` is NOT skipped:
            // the member name still flows through the `reconstructableMembers` check so a
            // reconstructed static (`BigUInt.compare`) is allowed while an unreconstructed
            // one (`BigUInt.divide`) is flagged.
            if node.base == nil {
                return .visitChildren  // contextual `.case`
            }
            memberNames.insert(node.declName.baseName.text); return .visitChildren
        }
    }

    /// True if an operator body uses an ARRAY-LITERAL expression as a value (the
    /// `ExpressibleByArrayLiteral` type-construction idiom, e.g. Euclid's
    /// `static func + (…) -> Vector { [lhs.x+rhs.x, …] }`). The minimal Codable
    /// reconstruction lacks that conformance, so the literal would be typed
    /// `[Element]` and fail to convert to the operator's value type. Conservative:
    /// any array-literal expression node in the body rejects the operator (operators
    /// that genuinely return a stdlib array are rare and also non-ABI here).
    private func operatorReliesOnArrayLiteralConstruction(_ f: FunctionDeclSyntax) -> Bool {
        let v = ArrayLiteralVisitor(viewMode: .sourceAccurate)
        v.walk(Syntax(f))
        return v.found
    }

    private final class ArrayLiteralVisitor: SyntaxVisitor {
        var found = false
        override func visit(_ node: ArrayExprSyntax) -> SyntaxVisitorContinueKind {
            found = true; return .skipChildren
        }
    }

    private func synthesizeEnum(_ e: EnumDeclSyntax, enclosingTypeName: String?,
                                aliasIndex: [String: [Decl]]) -> String {
        // Raw-value or associated-value enum, reconstructed Codable. Methods /
        // computed properties go in the extension; here we keep cases + raw type.
        var rawType = ""
        var synthesizedConformances: [String] = []
        if let inh = e.inheritanceClause {
            // Any literal-representable raw type (the first inherited type when it is a
            // raw type; protocols won't be in this set). CGFloat/Float and the integer-
            // width variants matter for font-size / metric enums (`enum Size: CGFloat`),
            // which lost their raw type before and failed `case x = 12` reconstruction.
            let rawTypes: Set<String> = [
                "Int", "Int8", "Int16", "Int32", "Int64",
                "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
                "Double", "Float", "Float32", "Float64", "CGFloat",
                "String", "Substring", "Character", "Unicode.Scalar",
            ]
            var synth: [String] = []
            for t in inh.inheritedTypes {
                let n = t.type.trimmedDescription
                if rawTypes.contains(n) { rawType = ": \(n)" }
                // Preserve AUTO-SYNTHESIZED conformances the original declared — Swift
                // synthesizes `==` (Equatable), `hash` (Hashable), `allCases`
                // (CaseIterable) for free. Dropping them broke use sites (`a == b`,
                // `Type.allCases`). Comparable is NOT auto-synthesized → not preserved.
                else if ["Equatable", "Hashable", "CaseIterable", "Sendable"].contains(n) { synth.append(n) }
            }
            synthesizedConformances = synth
        }
        // A CASELESS enum is a NAMESPACE, not a value type — it can have no instances,
        // so it can never be a Codable boundary value. Emitting `: Codable` on it
        // fails ("cannot automatically synthesize 'Decodable' conformance for empty
        // enum", e.g. SwiftSoup `UTF8Arrays`) and poisons the module. Reconstruct it as
        // a plain namespace (`enum X {}`) with NO conformances; the method/operator
        // surface still attaches via the extensions below.
        let hasCases = e.memberBlock.members.contains { $0.decl.is(EnumCaseDeclSyntax.self) }
        var conformances: [String] = []
        if hasCases {
            if !rawType.isEmpty { conformances.append(String(rawType.dropFirst(2))) }
            conformances.append("Codable")
            for c in synthesizedConformances where !conformances.contains(c) { conformances.append(c) }
        }
        // Fix S5(c): preserve a TYPE-LEVEL `indirect` on a recursive enum. The header
        // is rebuilt from scratch (so the original modifier is otherwise dropped); a
        // recursive `indirect enum Expr { case add(Expr, Expr) }` then fails to compile
        // ("recursive enum 'Expr' is not marked 'indirect'"). Case-level `indirect`
        // survives via the verbatim case text below; only the type-level keyword is lost.
        let indirectPrefix = e.modifiers.contains { $0.name.text == "indirect" } ? "indirect " : ""
        let header = conformances.isEmpty
            ? "\(indirectPrefix)enum \(e.name.text) {"
            : "\(indirectPrefix)enum \(e.name.text): \(conformances.joined(separator: ", ")) {"
        var lines: [String] = [header]
        // Emit nested typealiases that resolve to a WASM-safe leaf BEFORE the cases, so
        // an associated value spelled with the alias (`case inline(Word, Word)`, where
        // `Word = UInt` is declared in the ENCLOSING type) resolves. A nested enum is
        // reconstructed as a TOP-LEVEL enum, severing it from its enclosing scope — so
        // without re-emitting `Word` the cases fail with "cannot find type 'Word'".
        // Resolve in the enclosing owner's scope (disambiguates same-named aliases).
        let aliasOwner = e.name.text
        for member in e.memberBlock.members {
            guard let ta = member.decl.as(TypeAliasDeclSyntax.self) else { continue }
            let resolved = resolveAliasChain(ta.name.text, owner: aliasOwner, index: aliasIndex)
            if isCodableLeaf(resolved) || Self.knownSystemTypes.contains(resolved) {
                lines.append("    typealias \(ta.name.text) = \(resolved)")
            }
        }
        // A nested enum may reference an alias declared in its ENCLOSING type (BigUInt's
        // `Word` used by `Kind.inline`). The enclosing alias is NOT a member of the
        // enum, so collect any associated-value alias names not yet emitted and resolve
        // them from the enclosing scope.
        var emittedAliases = Set(e.memberBlock.members.compactMap {
            $0.decl.as(TypeAliasDeclSyntax.self)?.name.text })
        for member in e.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                guard let params = element.parameterClause?.parameters else { continue }
                for p in params {
                    for leaf in decomposeLeaves(p.type.trimmedDescription) {
                        guard let nominal = SymbolTable.leadingNominal(leaf),
                              !emittedAliases.contains(nominal),
                              aliasIndex[nominal]?.contains(where: { $0.kind == .typealias_ }) ?? false else { continue }
                        let resolved = resolveAliasChain(nominal, owner: enclosingTypeName, index: aliasIndex)
                        if (isCodableLeaf(resolved) || Self.knownSystemTypes.contains(resolved)) && resolved != nominal {
                            lines.append("    typealias \(nominal) = \(resolved)")
                            emittedAliases.insert(nominal)
                        }
                    }
                }
            }
        }
        for member in e.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            lines.append("    " + caseDecl.trimmedDescription)
        }
        // STATIC stored constants with a SIMPLE LITERAL initializer (string / number /
        // bool) are pure and reconstructed verbatim — the namespace-enum analogue of the
        // struct path above. This is what lets a CASELESS namespace enum used as a
        // config table (`enum Config { static let url = "https://…" }`) carry its
        // constants, so a pure body reading `Config.url` resolves instead of demoting
        // (the real `AIService.hasCloudFunctions` fix: reads three `Config` string
        // constants). Non-literal statics (`static let zero = Vector(0,0)`, an
        // interpolated string, a member ref) are dropped — they may reach the type's own
        // init or unbundled state, exactly as the struct path leaves them.
        for member in e.memberBlock.members {
            guard let v = member.decl.as(VariableDeclSyntax.self),
                  v.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) else { continue }
            for binding in v.bindings {
                guard binding.accessorBlock == nil,                       // stored, not computed
                      let id = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let initVal = binding.initializer?.value,
                      Self.isSimpleLiteral(initVal) else { continue }
                let kw = v.bindingSpecifier.text
                let typePart = binding.typeAnnotation.map { ": \($0.type.trimmedDescription)" } ?? ""
                lines.append("    static \(kw) \(id)\(typePart) = \(initVal.trimmedDescription)")
            }
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// Emit verbatim helper/seed functions. Free functions stay free; static
    /// methods are placed in their enclosing type. When the enclosing type is a
    /// reconstructed value type (`bundledTypes`), the methods go into an
    /// `extension <Type>` (the type itself is already declared) — otherwise into a
    /// synthesized enclosing `enum` (an instance-less helper namespace) — so the
    /// `Type.method(...)` call site in the generated wrapper resolves with no
    /// duplicate-declaration collision.
    private func emitFunctions(_ fns: [(name: String, enclosing: String?)],
                               index: [String: [Decl]], bundledTypes: Set<String>,
                               surfaceMembers: [String: [String]] = [:],
                               declaredExtensionTypes: Set<String> = []) -> String {
        // A type is EXTENDED (not redeclared) when it is a reconstructed value type,
        // a real system type, OR a namespace already declared once in a shared support
        // file. The last case is what stops two exports whose seed is a static method
        // on the SAME namespace (`enum ContactsDataStore`) from each redeclaring it —
        // an `invalid redeclaration` that poisoned the whole module (the dominant 0/N
        // cause on large apps).
        func isExtensible(_ type: String) -> Bool {
            bundledTypes.contains(type) || Self.knownSystemTypes.contains(type) || declaredExtensionTypes.contains(type)
        }
        var out = ""
        // Free functions.
        let frees = fns.filter { $0.enclosing == nil }.sorted { $0.name < $1.name }
        for f in frees {
            if let d = resolveFunction(name: f.name, enclosing: nil, index: index),
               let fn = d.node.as(FunctionDeclSyntax.self) {
                out += staticStripped(fn.trimmedDescription) + "\n\n"
            }
        }
        // Methods grouped by enclosing type. A method on a BUNDLED value type goes
        // into an `extension <Type>` (the reconstructed struct/enum, which now
        // carries stored fields only). An instance method stays an instance method
        // (so `_receiver.method` resolves); a static method stays static. A method
        // on a NON-bundled namespace goes into a synthesized instance-less `enum`
        // helper namespace with `static`.
        var byType: [String: [String]] = [:]
        for f in fns where f.enclosing != nil {
            // Skip a method already reconstructed into the SHARED value-type member
            // surface (avoid a duplicate `extension Type { … }` → redeclaration).
            if surfaceMembers[f.enclosing!]?.contains(f.name) == true { continue }
            guard let d = resolveFunction(name: f.name, enclosing: f.enclosing, index: index) else { continue }
            // A STATIC computed-property seed (`static var code: String { … }`): emit it
            // verbatim into the type's extension (always static, always extensible —
            // it seeds from a real value type). Its getter body's dependencies were
            // already walked by the closure pass; here we just reconstruct the decl.
            if let v = d.node.as(VariableDeclSyntax.self) {
                byType[f.enclosing!, default: []].append(staticForced(accessStripped(v.trimmedDescription)))
                continue
            }
            guard let fn = d.node.as(FunctionDeclSyntax.self) else { continue }
            let isStatic = fn.modifiers.contains { ["static", "class"].contains($0.name.text) }
            if isExtensible(f.enclosing!) {
                // Reconstructed value type, real system type, OR a once-declared
                // namespace → extend it (never redeclare); preserve instance-ness so
                // `_receiver.method` resolves.
                byType[f.enclosing!, default: []].append(
                    isStatic ? staticForced(fn.trimmedDescription) : accessStripped(fn.trimmedDescription))
            } else {
                byType[f.enclosing!, default: []].append(staticForced(fn.trimmedDescription))
            }
        }
        for (type, methods) in byType.sorted(by: { $0.key < $1.key }) {
            let keyword = isExtensible(type) ? "extension" : "enum"
            out += "\(keyword) \(type) {\n"
            out += methods.map { indent($0) }.joined(separator: "\n\n")
            out += "\n}\n\n"
        }
        return out
    }

    /// Drop access modifiers (public/private/…) but PRESERVE instance-ness — for a
    /// pure instance method emitted into an `extension` of a reconstructed type.
    private func accessStripped(_ src: String) -> String {
        // Peel ALL leading declaration modifier tokens, not just a contiguous access
        // run. Swift's modifier order is FREE, so `static public func` is as valid as
        // `public static func`; an early-exit at the first non-access token (`static`)
        // left `public` stranded, and `staticForced`'s `static`-insertion then produced
        // `static public static func` (the SwiftSoup `Pattern.compile` demote). We peel
        // every leading modifier, REMEMBER the keepers (`static`/`class`/`mutating`/
        // `nonmutating`), and re-prepend them in canonical order. A naive substring
        // replace would mangle `fileprivate static` → `filestatic` (because "private "
        // is a substring of "fileprivate ") and clobber a `private` in the body — so we
        // strip token-by-token from the front instead.
        // `override`/`required`/`convenience`/`dynamic` are class-only and invalid once
        // a member is reconstructed into a value-type extension or a namespace enum
        // (e.g. a Realm `override static func primaryKey()`); they are dropped.
        let dropMods: Set<String> = ["public", "private", "internal", "open", "final", "fileprivate", "package",
                                     "override", "required", "convenience", "dynamic",
                                     "@inlinable", "@usableFromInline"]
        let keepMods: Set<String> = ["static", "class", "mutating", "nonmutating"]
        var rest = Substring(src).drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" })
        var keepers: [String] = []
        while true {
            let lead = rest.prefix(while: { $0.isLetter || $0 == "@" })
            let after = rest.dropFirst(lead.count).first
            guard let a = after, a == " " || a == "\t" else { break }
            let tok = String(lead)
            if dropMods.contains(tok) {
                rest = rest.dropFirst(lead.count).drop(while: { $0 == " " || $0 == "\t" })
            } else if keepMods.contains(tok) {
                if !keepers.contains(tok) { keepers.append(tok) }
                rest = rest.dropFirst(lead.count).drop(while: { $0 == " " || $0 == "\t" })
            } else {
                break
            }
        }
        let prefix = keepers.isEmpty ? "" : keepers.joined(separator: " ") + " "
        return prefix + String(rest)
    }

    /// Drop a leading `static`/`public`/`private` etc. from a free function.
    private func staticStripped(_ src: String) -> String { src }

    /// Ensure a method is `static` when placed inside a synthesized enum.
    private func staticForced(_ src: String) -> String {
        var s = accessStripped(src)
        // Normalize `class func` → `static func` (class methods aren't allowed on an
        // enum/struct namespace) and ensure exactly one `static`.
        s = s.replacingOccurrences(of: "class func ", with: "static func ")
        if !s.contains("static func"), let r = s.range(of: "func ") {
            s.replaceSubrange(r, with: "static func ")
        }
        return s
    }

    private func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }
}
