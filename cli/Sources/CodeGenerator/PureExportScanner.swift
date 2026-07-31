// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser
import PartitioningEngine

/// Scans a source file for pure functions that can be exported wholesale across
/// the JSON (ptr,len) WASM ABI — i.e. functions the engine classified
/// `wasmEligible` and whose call site needs no instance (`self`).
///
/// Exportable shapes:
///   * a free function (`func f(...)` at file scope), called as `f(...)`, or
///   * a `static` method on an `enum`/`struct`/`final class` / a method inside an
///     `enum` (enums have no instances, so all their methods are effectively
///     static-callable via `Type.method`), called as `Type.method(...)`.
/// Instance methods are excluded (they need a `self` that does not exist in a
/// standalone WASM module).
///
/// Only the developer's *own* concrete value types may appear in the signature;
/// the BuildPipeline supplies the source file so those types compile into the
/// module, and the convergence/compiler proves they are `Codable` (a
/// non-`Codable` type makes the generated envelope fail to compile and the export
/// is dropped — safe). Generic / opaque (`some`/`any`) signatures are skipped.
public struct PureExportScanner {
    public init() {}

    /// Find exportable pure functions in `source`, restricted to the function ids
    /// the engine marked eligible (`eligibleSimpleNames` holds their simple names,
    /// e.g. `checkout`). Returns deterministic, de-duplicated exports.
    ///
    /// `valueTypeNames` is the set of names the corpus freshly declares as a VALUE
    /// type (struct/enum): an instance method declared in an `extension` of such a
    /// type (Euclid's `Vector.dot`, in `extension Vector`) is then a valid
    /// value-type-export target — the dependency bundler reconstructs the
    /// receiver's pure member surface so the export compiles.
    ///
    /// `bundleKey` identifies the source unit a GENERIC specialization's verbatim body
    /// (and its sibling helpers) is bundled from — the BuildPipeline passes the file
    /// path so a generic's whole defining file is bundled once (deduped). When omitted
    /// (tests / single-source callers) a stable per-source key is derived.
    public func scan(source: String, eligibleSimpleNames: Set<String>,
                     valueTypeNames: Set<String> = [],
                     bundleKey: String? = nil,
                     genericContext: GenericSpecializer.Context = .empty) -> [CodeEmitter.PureExport] {
        let tree = Parser.parse(source: source)
        let key = bundleKey ?? "src::\(source.hashValue)"
        let collector = Collector(eligible: eligibleSimpleNames,
                                  valueTypeNames: valueTypeNames,
                                  bundleFileKey: key,
                                  genericContext: genericContext)
        collector.walk(tree)
        // Deterministic order + de-dup by export name (first wins).
        var seen = Set<String>()
        return collector.exports
            .sorted { $0.exportName < $1.exportName }
            .filter { seen.insert($0.exportName).inserted }
    }

    final class Collector: SyntaxVisitor {
        let eligible: Set<String>
        let valueTypeNames: Set<String>
        /// The bundle key for any GENERIC specialization found here (the defining
        /// source unit — a file path from the pipeline). The pipeline maps it back to
        /// the verbatim source it bundles once into the module.
        let bundleFileKey: String
        private(set) var exports: [CodeEmitter.PureExport] = []
        /// Stack of enclosing nominal type names (for `Type.method` call sites).
        private var typeStack: [String] = []
        /// Whether the current enclosing type is an `enum` (instance-less).
        private var enumStack: [Bool] = []
        /// Whether the current enclosing type is a VALUE type (struct/enum) declared
        /// freshly here (so an instance method can be exported as `_receiver.method`,
        /// the receiver decoded as a Codable value). Classes / extensions on unknown
        /// types are NOT value-type-export targets (conservative).
        private var valueTypeStack: [Bool] = []
        /// When the enclosing decl is an `extension <SequenceLikeProtocol> [where …]`,
        /// the protocol constraint + the `where`-clause text — used to specialize a
        /// generic instance method over a concrete `Self = [Element]` (the wave-2
        /// generic-monomorphization unlock). nil when not in such an extension.
        private var sequenceExtensionStack: [(constraint: String, whereClause: String?)?] = []
        private let specializer: GenericSpecializer

        /// Parse the `Element: <Bound>` (or `Self.Element: <Bound>`) conformance from
        /// an extension's `where`-clause text (e.g. `where Element: Comparable` →
        /// `"Comparable"`; multiple bounds joined with `&`). nil when the element is
        /// unconstrained. Other requirements (`Self.Index == …`) are ignored here.
        static func elementBound(fromWhereClause whereClause: String?) -> String? {
            guard let wc = whereClause else { return nil }
            // Strip a leading `where`.
            var body = wc.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("where") { body = String(body.dropFirst(5)) }
            var bounds: [String] = []
            for req in body.split(separator: ",") {
                let parts = req.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }   // skip same-type (`==`) reqs
                let lhs = parts[0]
                if lhs == "Element" || lhs == "Self.Element" {
                    bounds.append(parts[1])
                }
            }
            return bounds.isEmpty ? nil : bounds.joined(separator: " & ")
        }

        /// Protocol constraints whose `Self` is a sequence/collection of `Element` and
        /// can be concretely instantiated as `[Int]`/`[Double]`/`[String]`.
        static let sequenceLikeConstraints: Set<String> = [
            "Sequence", "Collection", "BidirectionalCollection",
            "RandomAccessCollection", "RangeReplaceableCollection",
        ]

        init(eligible: Set<String>, valueTypeNames: Set<String> = [], bundleFileKey: String,
             genericContext: GenericSpecializer.Context = .empty) {
            self.eligible = eligible
            self.valueTypeNames = valueTypeNames
            self.bundleFileKey = bundleFileKey
            var spec = GenericSpecializer()
            spec.context = genericContext
            self.specializer = spec
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
            typeStack.append(node.name.text); enumStack.append(true); valueTypeStack.append(true); sequenceExtensionStack.append(nil); return .visitChildren
        }
        override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast(); enumStack.removeLast(); valueTypeStack.removeLast(); sequenceExtensionStack.removeLast() }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            typeStack.append(node.name.text); enumStack.append(false); valueTypeStack.append(true); sequenceExtensionStack.append(nil); return .visitChildren
        }
        override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast(); enumStack.removeLast(); valueTypeStack.removeLast(); sequenceExtensionStack.removeLast() }

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            typeStack.append(node.name.text); enumStack.append(false); valueTypeStack.append(false); sequenceExtensionStack.append(nil); return .visitChildren
        }
        override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast(); enumStack.removeLast(); valueTypeStack.removeLast(); sequenceExtensionStack.removeLast() }

        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
            // An extension's extended type kind is unknown from the extension alone,
            // but `valueTypeNames` (freshly-declared struct/enum names from the whole
            // corpus) tells us if it's a VALUE type. If so, its pure instance methods
            // ARE exportable via the `_receiver` path (Euclid's `Vector.dot` lives in
            // `extension Vector`) — the bundler reconstructs the receiver's member
            // surface so the export compiles. A non-value-type extension stays
            // conservative (static methods still export via the `Type.method` path).
            let extended = node.extendedType.trimmedDescription
            let nominal = SymbolTable.leadingNominal(extended) ?? extended
            let isValueType = valueTypeNames.contains(nominal)
            typeStack.append(extended); enumStack.append(false); valueTypeStack.append(isValueType)
            // Recognise `extension Sequence/Collection/… [where …]` so a generic
            // instance method over `Self`/`Element` can specialize concretely.
            if Self.sequenceLikeConstraints.contains(extended) {
                sequenceExtensionStack.append((constraint: extended,
                                               whereClause: node.genericWhereClause?.trimmedDescription))
            } else {
                sequenceExtensionStack.append(nil)
            }
            return .visitChildren
        }
        override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast(); enumStack.removeLast(); valueTypeStack.removeLast(); sequenceExtensionStack.removeLast() }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            let name = node.name.text
            guard eligible.contains(name) else { return .visitChildren }
            // Fix A: an operator (`==`, `+`, …) is NO LONGER skipped. Its export
            // symbol is SANITIZED by the emitter (`==` → `op_eqeq`) and the wrapper
            // invokes the REAL operator inside, so it ships OTA like any other pure
            // function (this is the ~37/52-app blocker). Detect operator-ness +
            // fixity here so the emitter builds the correct `a == b` call form.
            let isOperatorName = !(name.first.map { $0.isLetter || $0 == "_" } ?? false)
            var operatorFixity: CodeEmitter.PureExport.OperatorFixity? = nil
            if isOperatorName {
                if node.modifiers.contains(where: { $0.name.text == "prefix" }) {
                    operatorFixity = .prefix
                } else if node.modifiers.contains(where: { $0.name.text == "postfix" }) {
                    operatorFixity = .postfix
                } else {
                    operatorFixity = .infix  // Swift default for an operator func.
                }
            }

            let isStatic = node.modifiers.contains {
                $0.name.text == "static" || $0.name.text == "class"
            }
            let isMutating = node.modifiers.contains { $0.name.text == "mutating" }
            let enclosing = typeStack.last
            let inEnum = enumStack.last ?? false
            let inValueType = valueTypeStack.last ?? false

            // Determine the call site:
            //   * free function          → `name`
            //   * static / enum method   → `Type.name`           (instance-less)
            //   * value-type instance    → `name` + receiverType (decode receiver)
            // A `mutating` instance method is skipped: its mutation of the receiver
            // would be discarded across the value-copy ABI (only the return value
            // crosses back), so exporting it would silently lose effects.
            let seqExt = sequenceExtensionStack.last ?? nil

            // ---- Generic concrete-monomorphization branch (wave-2 unlock) --------
            // A `@_cdecl` export cannot be generic, so a generic function/method would
            // otherwise drop. If this is (a) an instance method on `extension
            // Sequence/Collection/…` (its `Self`/`Element` are generic) or (b) a
            // generic free / static function, hand it to the GenericSpecializer, which
            // emits a CONCRETE wrapper per ABI-typeable instantiation (`[Int]` etc.)
            // calling the developer's unchanged generic function — or NOTHING if no
            // instantiation is provably pure + ABI-typed (stays native). Operators and
            // mutating methods are excluded (handled / skipped below).
            if !isOperatorName && !isMutating {
                if let seqExt {
                    // Instance method on a sequence-like extension. The generic body
                    // (and its sibling helpers) is bundled by the pipeline as the WHOLE
                    // defining source file (deduped by file path), so transitive helpers
                    // like `min(count:sortedBy:)`/`_minImplementation` resolve. The
                    // extension's `where Element: <Bound>` restricts which element
                    // types may specialize.
                    let elemBound = Self.elementBound(fromWhereClause: seqExt.whereClause)
                    let specs = specializer.specialize(
                        funcNode: node,
                        receiver: .sequenceExtension(constraint: seqExt.constraint, elementBound: elemBound),
                        funcName: name, enclosingType: nil,
                        verbatimDefinition: "", definitionKey: bundleFileKey)
                    exports.append(contentsOf: specs)
                    return .visitChildren
                } else if node.genericParameterClause != nil,
                          enclosing == nil || isStatic || inEnum {
                    // Generic FREE / static function. The whole defining file is bundled
                    // (deduped) so the generic body + its helpers resolve.
                    let prefix = (isStatic || inEnum) ? "\(enclosing ?? "")." : ""
                    let specs = specializer.specialize(
                        funcNode: node,
                        receiver: .free(callPrefix: prefix),
                        funcName: name, enclosingType: enclosing,
                        verbatimDefinition: "", definitionKey: bundleFileKey)
                    exports.append(contentsOf: specs)
                    return .visitChildren
                }
            }

            // SELF-FREE INSTANCE-METHOD LOWERING (the receiver-less lift).
            //
            // An instance method whose body references NO `self` member — `self.x`,
            // `self`, or a bare instance-member reference — is a pure function of its
            // parameters (`SettingsScreen.relativeString(from:)`). It needs no
            // receiver; decoding `_receiver: <View>` is exactly what demoted it (a
            // SwiftUI View isn't Decodable). Lower it to a synthetic FREE function
            // carrying its verbatim body, and export THAT (no `_receiver`).
            // Applies to a struct/enum/class instance method (NOT static — that
            // already exports cleanly; NOT mutating — a value-copy ABI would lose the
            // mutation; NOT an operator). Demote-safe: the synthetic free function
            // fails to compile if the body actually touches `self`, and the
            // convergence loop drops only that export.
            let isPlainInstanceMethod = !isOperatorName && enclosing != nil
                && !isStatic && !isMutating
            let selfFree = isPlainInstanceMethod && Self.bodyIsSelfFree(node)

            let callee: String
            var receiverType: String? = nil
            var selfFreeFn: CodeEmitter.PureExport.SelfFreeFreeFunction? = nil
            if isOperatorName {
                // An operator is invoked with the real operator (`a == b`), never via
                // `_receiver` or a labelled member call — so it needs no callee /
                // receiver threading. (`callee` is unused when operatorFixity != nil.)
                callee = name
            } else if let enclosing, selfFree {
                // Receiver-less free-function lowering: synthesize a standalone `func`
                // with the original body and call it directly. `receiverType` stays nil.
                let symbol = Self.selfFreeSymbol(type: enclosing, name: name)
                selfFreeFn = Self.makeSelfFreeFreeFunction(node: node, symbol: symbol)
                callee = symbol
            } else if let enclosing {
                if isStatic {
                    callee = "\(enclosing).\(name)"
                } else if (inValueType || inEnum) && !isMutating {
                    // Pure instance method on a value type — struct OR enum-with-cases.
                    // An enum's instance method (`func title() -> String { switch self
                    // {…} }`) was previously mis-emitted as a static `Enum.title()` call,
                    // which fails to compile ("instance member cannot be used on type")
                    // and demoted. An enum is a value type: decode the receiver and call
                    // `_receiver.title()`. (A static method keeps `isStatic` → static.)
                    callee = name
                    receiverType = enclosing
                } else {
                    return .visitChildren // instance method on a class / mutating: skip
                }
            } else {
                callee = name
            }

            // Read parameters (label, internal name, type). A remaining generic
            // clause here means a generic that the specializer above did NOT handle
            // (e.g. a generic instance method on a value type) — skip conservatively.
            if node.genericParameterClause != nil { return .visitChildren }
            var params: [(label: String, name: String, type: String)] = []
            var ok = true
            for p in node.signature.parameterClause.parameters {
                let label = p.firstName.text
                let internalName = (p.secondName ?? p.firstName).text
                let type = p.type.trimmedDescription
                if !typeIsExportable(type) { ok = false; break }
                params.append((label: label, name: internalName, type: type))
            }
            guard ok else { return .visitChildren }

            let ret = node.signature.returnClause?.type.trimmedDescription ?? ""
            if !ret.isEmpty, ret != "Void", !typeIsExportable(ret) { return .visitChildren }

            // Skip effectful functions — a WASM export is synchronous & total.
            if let effects = node.signature.effectSpecifiers,
               effects.asyncSpecifier != nil || effects.throwsClause != nil {
                return .visitChildren
            }

            // The export name is the deterministic simple function name; an instance
            // method is qualified `<Type>_<name>` to avoid colliding with a free
            // function or another type's same-named method in the module. An OPERATOR
            // is qualified by its enclosing type and uses the SANITIZED operator stem
            // (`Money_op_eqeq`) so two types' `==` don't collide and the emitter's
            // sanitizer leaves the already-valid symbol intact.
            let exportName: String
            if isOperatorName {
                let opStem = CodeEmitter.sanitizedExportSymbol(name)  // `==` → `op_eqeq`
                exportName = enclosing.map { "\($0)_\(opStem)" } ?? opStem
            } else if selfFreeFn != nil {
                // Qualify a self-free instance method by its enclosing type so two
                // types' same-named methods (and a free function of that name) don't
                // collide in the module.
                exportName = enclosing.map { "\($0)_\(name)" } ?? name
            } else {
                exportName = receiverType.map { "\($0)_\(name)" } ?? name
            }
            exports.append(CodeEmitter.PureExport(
                exportName: exportName, callee: callee, parameters: params, returnType: ret,
                receiverType: receiverType,
                operatorFixity: operatorFixity,
                operatorToken: isOperatorName ? name : nil,
                operatorDefiningType: isOperatorName ? enclosing : nil,
                selfFreeFreeFunction: selfFreeFn))
            return .visitChildren
        }

        /// Scalar/string return types we lift for an instance-less COMPUTED PROPERTY.
        /// Restricted to ABI-leaf scalars + String (no user value types): a property
        /// carries no parameters, so the only boundary is the return — keeping it a
        /// scalar/string sidesteps the Codable-envelope reconstruction the bundler
        /// would otherwise need for a value-type return, and these are exactly the
        /// trivially-liftable design tokens (Money's `AED.code`/`minorUnit`,
        /// SwiftyJSON-style constants) the function-only scanner skipped.
        static let liftablePropertyReturnTypes: Set<String> = [
            "String", "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Double", "Float", "CGFloat", "Bool", "TimeInterval", "Character",
        ]

        /// Export an instance-less COMPUTED PROPERTY that returns a liftable
        /// scalar/string. Two callable shapes (mirroring the method visitor):
        ///   * `static var p: T { … }`  on any value type  → `Type.p`   (instance-less)
        ///   * `var p: T { … }`         inside an `enum`    → `_receiver.p` (enum is a
        ///     value type; the receiver is decoded — a no-`self`-state property still
        ///     compiles, and one reading `self`/native is REJECTED by the bundler).
        /// Stored properties (no accessor block / a `willSet`/`didSet` observer only),
        /// `lazy`, effectful (`async`/`throws`) accessors, and multi-binding decls are
        /// all skipped. The dependency-closure bundler + the real WASM compile are the
        /// final safety net: a property whose getter touches `self`-state or a native
        /// symbol is demoted, never shipped broken.
        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            guard let enclosing = typeStack.last else { return .visitChildren }
            let inEnum = enumStack.last ?? false
            let inValueType = valueTypeStack.last ?? false
            let isStatic = node.modifiers.contains {
                $0.name.text == "static" || $0.name.text == "class"
            }
            // `lazy` is stored-with-init; never a pure computed value.
            if node.modifiers.contains(where: { $0.name.text == "lazy" }) { return .visitChildren }
            // Exactly one binding with an explicit name + type + a getter body.
            guard node.bindings.count == 1, let binding = node.bindings.first else { return .visitChildren }
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                return .visitChildren
            }
            guard eligible.contains(ident) else { return .visitChildren }
            // The return must be ABI-marshallable. Two admitted shapes:
            //   * a scalar/string LEAF (`liftablePropertyReturnTypes`) — rides the
            //     tiny T0 host-bridge wrapper, no reconstruction needed; OR
            //   * a RECONSTRUCTABLE VALUE TYPE return (a concrete struct/enum the
            //     bundler can already rebuild as a Codable leaf for the existing
            //     value-lift path). The function-only scanner ALREADY admits such
            //     value-type returns (via `typeIsExportable`); a property carries no
            //     parameters, so the return is its only boundary. We admit it here and
            //     let the dependency-closure bundler + the real WASM compile be the
            //     arbiter: a return type that is NOT bundle-reconstructable (a
            //     class/protocol/native/opaque type) makes the closure non-shippable
            //     and the export demotes ALONE — never ships broken. The Foundation
            //     (T2) envelope already round-trips a reconstructed value type for the
            //     instance-method/operator paths; a value-returning property reuses it.
            guard let typeAnn = binding.typeAnnotation?.type.trimmedDescription,
                  Self.liftablePropertyReturnTypes.contains(typeAnn)
                    || typeIsExportable(typeAnn) else { return .visitChildren }
            // Must be COMPUTED: an accessor block that is a getter (a code block, or an
            // explicit `get`), NOT a stored property or a `willSet`/`didSet`-only var.
            guard let accessor = binding.accessorBlock else { return .visitChildren }
            switch accessor.accessors {
            case .getter:
                break  // `var p: T { <expr> }` — implicit getter.
            case .accessors(let list):
                // Has an explicit `get`, and no setter/observer that would make it
                // non-pure/stateful (a `set`/`willSet`/`didSet` implies stored backing).
                let kinds = list.map { $0.accessorSpecifier.text }
                guard kinds.contains("get"),
                      !kinds.contains(where: { ["set", "willSet", "didSet", "_modify"].contains($0) })
                else { return .visitChildren }
                // An effectful getter (`get async`/`get throws`) can't be a sync export.
                if list.contains(where: { $0.effectSpecifiers != nil }) { return .visitChildren }
            }

            // Call shape: a static property is `Type.p` (instance-less); a non-static
            // enum property decodes the receiver and reads `_receiver.p`.
            let callee: String
            var receiverType: String? = nil
            if isStatic {
                callee = "\(enclosing).\(ident)"
            } else if inEnum && inValueType {
                callee = ident
                receiverType = enclosing
            } else {
                return .visitChildren  // instance property on a struct/class — skip.
            }
            let exportName = receiverType.map { "\($0)_\(ident)" } ?? "\(enclosing)_\(ident)"
            exports.append(CodeEmitter.PureExport(
                exportName: exportName, callee: callee, parameters: [], returnType: typeAnn,
                receiverType: receiverType, isProperty: true))
            return .visitChildren
        }

        /// A type usable in the JSON envelope: not opaque (`some`/`any`), not a
        /// closure/function type, not inout. Concrete user/value types are allowed
        /// (their `Codable` conformance is proven by the actual WASM compile).
        private func typeIsExportable(_ type: String) -> Bool {
            let t = type.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return false }
            if t.contains("->") { return false }                 // function type
            if t.hasPrefix("some ") || t.hasPrefix("any ") { return false }
            if t.contains("inout ") { return false }
            return true
        }

        // MARK: - Self-free instance-method detection + free-function synthesis

        /// True iff an instance method's body references NO `self` — neither an
        /// explicit `self`/`self.x` nor a bare reference to an instance member of the
        /// enclosing type (implicit self). Conservative: we treat ANY explicit `self`
        /// as a disqualifier, and any bare lowercase identifier READ that is NOT a
        /// parameter, a locally-introduced binding, or a known global as a *possible*
        /// implicit-self member → NOT self-free (so we never claim self-free for a
        /// method that actually reaches `self`). The WASM compile of the synthesized
        /// free function is the final ground truth — an over-claim demotes that export
        /// alone, never a false negative.
        static func bodyIsSelfFree(_ node: FunctionDeclSyntax) -> Bool {
            guard let body = node.body else { return false }
            let v = SelfFreeVisitor(viewMode: .sourceAccurate)
            // Parameters are in scope (the only legitimate inputs).
            for p in node.signature.parameterClause.parameters {
                v.bound.insert((p.secondName ?? p.firstName).text)
            }
            v.walk(Syntax(body))
            return !v.usesSelf && v.unboundReads.isEmpty
        }

        /// The deterministic synthetic free-function symbol for a self-free instance
        /// method (`SettingsScreen.relativeString` → `__patch_sf_SettingsScreen_relativeString`).
        /// Sanitized to a valid Swift identifier (an extension's `Foo.Bar` qualifier
        /// or a generic `<…>` is folded to underscores).
        static func selfFreeSymbol(type: String, name: String) -> String {
            let safe = { (s: String) in String(s.map { ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" }) }
            return "__patch_sf_\(safe(type))_\(safe(name))"
        }

        /// Synthesize the standalone free-function definition for a self-free instance
        /// method: the original parameter clause, return clause, and body verbatim,
        /// renamed to the synthetic symbol with NO enclosing type. (Attributes /
        /// modifiers are dropped — `private`/`func`-only is the surface that matters;
        /// `static`/`mutating`/generics were excluded upstream.)
        static func makeSelfFreeFreeFunction(node: FunctionDeclSyntax, symbol: String)
            -> CodeEmitter.PureExport.SelfFreeFreeFunction {
            let paramsSrc = node.signature.parameterClause.trimmedDescription
            let retSrc = node.signature.returnClause.map { " \($0.trimmedDescription)" } ?? ""
            let bodySrc = node.body?.trimmedDescription ?? "{}"
            let def = "func \(symbol)\(paramsSrc)\(retSrc) \(bodySrc)"
            return CodeEmitter.PureExport.SelfFreeFreeFunction(verbatimDefinition: def, symbolName: symbol)
        }

        /// Scope walker for `bodyIsSelfFree`. Tracks bound names (params + locals +
        /// closure params) and flags any explicit `self` use or any UNBOUND lowercase
        /// identifier read (a possible implicit-`self` member). Mirrors the bundler's
        /// `freeFunctionInstanceLeak` ScopeVisitor so the two agree on what "self-free"
        /// means (the bundler is the runtime ground truth).
        final class SelfFreeVisitor: SyntaxVisitor {
            var bound: Set<String> = []
            var unboundReads: Set<String> = []
            var usesSelf = false

            override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
                bound.insert(node.identifier.text); return .visitChildren
            }
            override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
                bound.insert(node.name.text); return .visitChildren
            }
            override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
                bound.insert((node.secondName ?? node.firstName).text); return .visitChildren
            }
            override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
                // A nested function's own parameters are in scope inside it.
                bound.insert((node.secondName ?? node.firstName).text); return .visitChildren
            }
            override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
                let n = node.baseName.text
                if n == "self" { usesSelf = true; return .skipChildren }
                // A `.member` of a member-access is not a free read (its base is).
                if let parent = node.parent?.as(MemberAccessExprSyntax.self),
                   parent.declName == node { return .visitChildren }
                if let f0 = n.first, f0.isLowercase || f0 == "_",
                   !bound.contains(n), !PureExportScanner.knownSelfFreeGlobals.contains(n) {
                    unboundReads.insert(n)
                }
                return .visitChildren
            }
        }
    }

    /// stdlib / common free identifiers a self-free method body may reference unbound
    /// without it implying `self` (mirrors the bundler's `knownGlobals`, plus the
    /// Foundation value-type entry points a date/number helper uses). An unbound name
    /// NOT in this set is treated as a possible implicit-self member → NOT self-free.
    static let knownSelfFreeGlobals: Set<String> = [
        "print", "abs", "min", "max", "swap", "assert", "assertionFailure",
        "precondition", "preconditionFailure", "fatalError", "zip", "stride",
        "repeatElement", "sequence", "true", "false", "nil",
        "sqrt", "cbrt", "pow", "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
        "floor", "ceil", "round", "log", "log2", "log10", "exp", "hypot", "fmod",
    ]
}
