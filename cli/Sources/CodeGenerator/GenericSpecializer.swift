// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser

/// Concrete monomorphization of GENERIC eligible functions (the wave-2 unlock).
///
/// A `@_cdecl` export cannot be generic, so EVERY generic-signature eligible
/// function would otherwise drop — e.g. swift-algorithms is 100% wasmEligible but
/// ships ~0 because its API is generic over `Collection`/`Sequence`/`Element`.
///
/// This component takes a generic function/method declaration and, for each chosen
/// CONCRETE instantiation (e.g. `Self = [Int]`, `Element = Int`, or a free generic
/// `T = Int`), substitutes the generic placeholders in its parameter / return types.
/// If — AND ONLY IF — every post-substitution boundary type is ABI-codable (a scalar
/// or a concrete Codable container/value, no closures / `inout` / opaque / generic
/// leftovers / library-generic wrapper return) it emits a concrete `PureExport`
/// whose wrapper calls the developer's UNCHANGED generic function at that concrete
/// type. Swift monomorphizes the call automatically; the generic body is bundled
/// VERBATIM into the module (Swift compiles generics to WASM fine).
///
/// SAFETY / no-false-negatives: an instantiation is only admitted when it is
/// provably pure + ABI-typed. Any constraint we cannot concretely satisfy (an
/// unrecognised protocol bound, a closure/`inout`/`some`/`any` param, a generic
/// leftover in the return, a library-generic wrapper return like
/// `CombinationsSequence<Self>`, effectful `async`/`throws`) → the function is left
/// generic and stays native. We never specialize speculatively past these gates.
public struct GenericSpecializer {

    public init() {}

    /// Project-wide knowledge fed in from the build pipeline that unlocks the
    /// BREAKTHROUGH-#7 instantiation sources beyond the fixed `{Int, Double, String}`
    /// stdlib path. Empty by default (so the pure-syntax callers / existing tests get
    /// the unchanged behavior). All three sources reuse the SAME `Instantiation` /
    /// `buildExport` / `isABICodable` machinery and the build pipeline's
    /// compile-or-demote backstop, so they can never ship a false positive.
    public struct Context: Sendable {
        /// Custom protocol → its VALUE-type (struct/enum) conformers declared in the
        /// project. A generic bounded by such a protocol monomorphizes at each value
        /// conformer (reference-type conformers are excluded → they correctly
        /// fail-compile and demote, as proven in Breakthrough-#7 Limit B).
        public var valueConformersByProtocol: [String: [String]]
        /// Generic free/static function simple name → the concrete VALUE types it is
        /// actually called with somewhere in the module (call-site mining). Drives an
        /// instantiation per observed concrete argument type.
        public var callSiteValueTypes: [String: Set<String>]
        /// All value-type (struct/enum) names freshly declared in the project — admitted
        /// as ABI-codable boundary leaves (the build pipeline reconstructs them as
        /// `Codable` value types, and the real WASM compile is the final arbiter).
        public var projectValueTypeNames: Set<String>

        public init(valueConformersByProtocol: [String: [String]] = [:],
                    callSiteValueTypes: [String: Set<String>] = [:],
                    projectValueTypeNames: Set<String> = []) {
            self.valueConformersByProtocol = valueConformersByProtocol
            self.callSiteValueTypes = callSiteValueTypes
            self.projectValueTypeNames = projectValueTypeNames
        }

        public static let empty = Context()

        public var isEmpty: Bool {
            valueConformersByProtocol.isEmpty && callSiteValueTypes.isEmpty
                && projectValueTypeNames.isEmpty
        }
    }

    /// Injected project context (empty by default → unchanged behavior).
    public var context: Context = .empty

    /// The enclosing context of the declaration being specialized.
    enum Receiver {
        /// A free function or a `static` method on `Type` — no `self`.
        ///   - callPrefix: `""` for a free func, `"Type."` for a static method.
        case free(callPrefix: String)
        /// An instance method on `extension <ProtocolConstraint> [where Element: B]`
        /// (Sequence / Collection / …). `Self` is the generic receiver; the concrete
        /// receiver type substitutes for it (e.g. `[Int]`). `elementBound` is the
        /// `where Element: <B>` constraint (if any), so element instantiations that
        /// don't satisfy `B` are dropped.
        case sequenceExtension(constraint: String, elementBound: String?)
    }

    /// One concrete instantiation: a substitution map placeholder→concrete plus a
    /// short tag for the export name and a human label for the report.
    struct Instantiation {
        let subst: [String: String]   // e.g. ["Self": "[Int]", "Element": "Int", "T": "Int"]
        let tag: String               // e.g. "Int"
        let label: String             // e.g. "Self=[Int], Element=Int"
    }

    // The concrete element types we specialize sequence/collection/`Element`-style
    // generics over. Codable + ABI-typeable, cover the overwhelming bulk of real
    // call sites for library/algorithm code. Deterministic order.
    static let elementTypes: [(elem: String, tag: String)] = [
        ("Int", "Int"), ("Double", "Double"), ("String", "String"),
    ]

    /// Produce the concrete `PureExport`s for one generic decl, or `[]` if no
    /// instantiation is safely ABI-typeable (→ stays native). `funcName` is the
    /// simple name; `enclosingType` is the static-method namespace (nil for free).
    func specialize(
        funcNode: FunctionDeclSyntax,
        receiver: Receiver,
        funcName: String,
        enclosingType: String?,
        verbatimDefinition: String,
        definitionKey: String
    ) -> [CodeEmitter.PureExport] {
        // Effectful generics never cross a synchronous, total WASM export.
        if let effects = funcNode.signature.effectSpecifiers,
           effects.asyncSpecifier != nil || effects.throwsClause != nil { return [] }

        // Gather the generic parameters declared on THIS function + the receiver's
        // implicit `Self`/`Element` (for an `extension Sequence/Collection`).
        let declaredGenerics = collectGenericParamNames(funcNode)

        // A same-type element pin (`where C.Element == Int`, `where Element == Int`)
        // forces a specific element type — instantiations whose driving element
        // contradicts the pin are inconsistent and would fail to compile, so they are
        // dropped (conservative). nil → no pin (all driving elements allowed).
        let elementPin = collectElementPin(funcNode)

        // Build the candidate instantiation set from the receiver + declared params.
        var instantiations = chooseInstantiations(
            receiver: receiver, declaredGenerics: declaredGenerics, funcNode: funcNode)
        if let pin = elementPin {
            instantiations = instantiations.filter { $0.subst["Element"] == pin || $0.tag == pin }
        }
        guard !instantiations.isEmpty else { return [] }

        var out: [CodeEmitter.PureExport] = []
        for inst in instantiations {
            guard let export = buildExport(
                funcNode: funcNode, receiver: receiver, funcName: funcName,
                enclosingType: enclosingType, inst: inst,
                verbatimDefinition: verbatimDefinition, definitionKey: definitionKey)
            else { continue }
            out.append(export)
        }
        return out
    }

    // MARK: - Instantiation choice

    private func chooseInstantiations(
        receiver: Receiver, declaredGenerics: [(name: String, bound: String?)],
        funcNode: FunctionDeclSyntax
    ) -> [Instantiation] {
        switch receiver {
        case .sequenceExtension(_, let elementBound):
            // The receiver `Self` is the sequence/collection; `Element` is its
            // element. Specialize `Self = [E]`, `Element = E` for E in Int/Double/
            // String — but ONLY for element types that satisfy the extension's
            // `where Element: <Bound>` constraint (so `Element: Numeric` excludes
            // String, and an unrecognised bound excludes everything → stays native).
            // ANY ADDITIONAL declared generic on the function (a second type param,
            // e.g. `uniqued<Subject: Hashable>`) must ALSO be concretizable; if it
            // cannot be tied to `Element` we bail (no false specialization).
            var insts: [Instantiation] = []
            for (elem, tag) in Self.elementTypes {
                guard concreteFor(bound: elementBound, preferred: elem) != nil else { continue }
                var subst = ["Self": "[\(elem)]", "Element": elem]
                var ok = true
                for g in declaredGenerics {
                    // A function-level generic in a sequence extension we can only
                    // safely bind if it has NO bound (pick the element type) or a
                    // bound we recognise as satisfied by the element type.
                    guard let concrete = concreteFor(bound: g.bound, preferred: elem) else { ok = false; break }
                    subst[g.name] = concrete
                }
                if ok { insts.append(Instantiation(subst: subst, tag: tag, label: substLabel(subst))) }
            }
            return insts
        case .free:
            // Free / static generic. Each declared generic param gets a concrete type
            // from its bound, all driven by one element choice so the export name stays
            // a single tag. A param bound by a SEQUENCE/COLLECTION protocol becomes the
            // concrete container `[E]` (not the element `E`); a scalar/comparable bound
            // becomes the element `E`. Also fold a `where C.Element == E` requirement so
            // the param's element is pinned. Zero declared generics ⇒ not generic.
            guard !declaredGenerics.isEmpty else { return [] }
            // Associated-type pins: `where C.Element == Int` forces C's element. We read
            // them only to VALIDATE (a same-type pin to a non-driving type would make a
            // concrete instantiation inconsistent); we drive by the element choice.
            // BREAKTHROUGH-#7 (i): a DIRECT same-type pin (`where T == Concrete`) on a
            // declared param FORCES that param — a stdlib element instantiation that
            // binds it to a contradicting type would never compile, so it is dropped
            // (and the pin source re-adds the single correct one below). This also
            // suppresses the pre-existing over-emission of `f_Double`/`f_String` for a
            // `where T == Int` pin (they were demoting at compile; now never emitted).
            let directPins = collectDirectParamPins(funcNode, params: declaredGenerics)
            var insts: [Instantiation] = []
            for (elem, tag) in Self.elementTypes {
                var subst: [String: String] = [:]
                var ok = true
                for g in declaredGenerics {
                    // A param pinned to a concrete type only admits the matching element.
                    if let pinned = directPins[g.name] {
                        if pinned == elem { subst[g.name] = pinned } else { ok = false; break }
                        continue
                    }
                    if let bound = g.bound, isSequenceLikeBound(bound) {
                        subst[g.name] = "[\(elem)]"          // C: Collection → [E]
                    } else if let concrete = concreteFor(bound: g.bound, preferred: elem) {
                        subst[g.name] = concrete             // T: Comparable / unbounded → E
                    } else { ok = false; break }
                }
                if ok { insts.append(Instantiation(subst: subst, tag: tag, label: substLabel(subst))) }
            }
            // ---- BREAKTHROUGH-#7 instantiation sources (additive) -----------------
            // These are appended to (never replace) the stdlib `{Int,Double,String}`
            // set above. Each produced instantiation flows through the SAME buildExport
            // + isABICodable gate + the pipeline's compile-or-demote backstop, so a
            // bad one is dropped harmlessly. Deduped by their substitution map below.
            insts += breakthrough7Instantiations(
                declaredGenerics: declaredGenerics, funcNode: funcNode)
            return dedupInstantiations(insts)
        }
    }

    /// BREAKTHROUGH-#7: the three new instantiation sources for a free/static generic.
    /// Returns the additional `Instantiation`s (over the stdlib element set); each is
    /// still validated by `buildExport`/`isABICodable` downstream.
    private func breakthrough7Instantiations(
        declaredGenerics: [(name: String, bound: String?)],
        funcNode: FunctionDeclSyntax
    ) -> [Instantiation] {
        var out: [Instantiation] = []

        // (i) SAME-TYPE PINS — `where T == Concrete` self-monomorphize: the pinned
        // param is forced to the concrete type. If EVERY declared generic param is
        // pinned we emit one concrete instantiation. The cleanest, highest-volume
        // source. (An ASSOCIATED-type pin like `R.Bound == Int` does NOT, on its own,
        // give a concrete param type — `R` could be `Range<Int>` or `ClosedRange<Int>`
        // — so it is deliberately NOT treated as a pin here; such a generic stays
        // native unless its param BOUND concretizes via the stdlib path.)
        let pins = collectDirectParamPins(funcNode, params: declaredGenerics)
        if !pins.isEmpty {
            var subst: [String: String] = [:]
            var allPinned = true
            for g in declaredGenerics {
                if let pinned = pins[g.name] {
                    subst[g.name] = pinned
                } else {
                    // A non-pinned param: only admissible if it has a concretizable
                    // stdlib bound (drive it at Int — the pin path is for the common
                    // single-param case; multi-param mixes stay conservative).
                    allPinned = false; break
                }
            }
            if allPinned, !subst.isEmpty {
                let tag = pinTag(subst)
                out.append(Instantiation(subst: subst, tag: tag, label: substLabel(subst)))
            }
        }

        // (iii) CUSTOM VALUE-TYPE CONFORMERS — a generic param bounded by a CUSTOM
        // protocol whose project conformers are ALL value types monomorphizes at each
        // value conformer. (Reference-type conformers are excluded by the pipeline →
        // they fail-compile + demote, proven safe.)
        if !context.valueConformersByProtocol.isEmpty {
            // Only single-custom-bound generics (the common `func f<T: P>(_:)` shape):
            // a multi-param custom mix would explode the product and is left to the
            // call-site source. Identify the lone custom-protocol-bounded param.
            let customParams = declaredGenerics.filter { g in
                guard let b = g.bound else { return false }
                return customProtocolConformers(for: b) != nil
            }
            if customParams.count == 1, declaredGenerics.count == 1,
               let g = customParams.first,
               let conformers = customProtocolConformers(for: g.bound!) {
                for conformer in conformers {
                    out.append(Instantiation(
                        subst: [g.name: conformer], tag: conformer,
                        label: substLabel([g.name: conformer])))
                }
            }
        }

        // (ii) CALL-SITE MINING — the concrete VALUE types this generic is actually
        // called with somewhere in the module. For a single-param generic, bind the
        // param to each observed value type. The export name is tagged by the type.
        if declaredGenerics.count == 1, let g = declaredGenerics.first,
           let observed = context.callSiteValueTypes[funcNode.name.text] {
            // Only admit a call-site type that satisfies the param's bound: a custom
            // value type is fine for an unbounded / custom-protocol param; we never
            // bind it to a sequence-like or numeric stdlib bound it can't satisfy.
            let boundOK = g.bound.map { !isSequenceLikeBound($0) } ?? true
            if boundOK {
                for t in observed.sorted() where context.projectValueTypeNames.contains(t) {
                    out.append(Instantiation(
                        subst: [g.name: t], tag: t, label: substLabel([g.name: t])))
                }
            }
        }

        return out
    }

    /// The VALUE-type conformers of `bound` if it is a single CUSTOM protocol with
    /// project conformers that are ALL value types; else nil. A composed bound
    /// (`A & B`), a stdlib bound, or a protocol with a reference-type conformer is
    /// not admitted here (stays native / handled elsewhere).
    private func customProtocolConformers(for bound: String) -> [String]? {
        let parts = bound.split(separator: "&").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 1 else { return nil }
        let proto = parts[0]
        // A bound the stdlib path already recognises is NOT a custom protocol.
        if concreteFor(bound: proto, preferred: "Int") != nil { return nil }
        guard let conformers = context.valueConformersByProtocol[proto], !conformers.isEmpty else {
            return nil
        }
        return conformers
    }

    /// Parse `where`-clause DIRECT same-type pins on a declared generic param:
    /// `where T == Concrete` (LHS is exactly the bare param name `T`). Maps the param
    /// name → the concrete pin. ASSOCIATED-type pins (`R.Bound == Int`, `C.Element ==
    /// String`) are intentionally NOT returned here — they constrain an associated
    /// type, not the param's own identity, so they can't yield a concrete param type.
    /// Only pins to an ABI-admissible concrete type (a stdlib leaf, project value type,
    /// or codable container) are kept; `params` is the set of declared generic names.
    private func collectDirectParamPins(
        _ fn: FunctionDeclSyntax, params: [(name: String, bound: String?)]
    ) -> [String: String] {
        guard let wc = fn.genericWhereClause else { return [:] }
        let paramNames = Set(params.map { $0.name })
        var pins: [String: String] = [:]
        for req in wc.requirements {
            guard let same = req.requirement.as(SameTypeRequirementSyntax.self) else { continue }
            let lhs = same.leftType.trimmedDescription
            let rhs = same.rightType.trimmedDescription
            // Exactly one side must be a bare declared param name; the other a concrete
            // ABI-admissible type.
            func tryPin(_ placeholder: String, _ concrete: String) {
                guard paramNames.contains(placeholder) else { return }
                guard isPinnableConcrete(concrete) else { return }
                pins[placeholder] = concrete
            }
            if paramNames.contains(lhs) { tryPin(lhs, rhs) }
            else if paramNames.contains(rhs) { tryPin(rhs, lhs) }
        }
        return pins
    }

    /// A concrete type usable as a same-type pin target: a stdlib ABI leaf, a project
    /// value type, or an ABI-codable container thereof. Rejects anything with a
    /// leftover placeholder (handled by `isABICodable` later too).
    private func isPinnableConcrete(_ type: String) -> Bool {
        let t = type.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        // Must not itself be a single bare placeholder (uppercase, no leaf/value match).
        return isABICodable(t)
    }

    private func pinTag(_ subst: [String: String]) -> String {
        // A single-pin export gets the pinned type's tag; multi-pin joins them.
        let vals = subst.sorted { $0.key < $1.key }.map { sanitizeTag($0.value) }
        return vals.joined(separator: "_")
    }

    private func sanitizeTag(_ t: String) -> String {
        var s = ""
        for c in t where c.isLetter || c.isNumber || c == "_" { s.append(c) }
        return s.isEmpty ? "T" : s
    }

    /// Dedup instantiations by their substitution map (a pin / conformer that
    /// coincides with a stdlib element instantiation is collapsed). First wins.
    private func dedupInstantiations(_ insts: [Instantiation]) -> [Instantiation] {
        var seen: Set<String> = []
        var out: [Instantiation] = []
        for i in insts {
            let key = i.subst.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            if seen.insert(key).inserted { out.append(i) }
        }
        return out
    }

    /// The concrete type to bind a generic param with the given protocol `bound` to,
    /// `preferred` being the driving element type (Int/Double/String). Returns nil
    /// for a bound we cannot provably satisfy with a concrete ABI value type — which
    /// forces the whole instantiation to be skipped (conservative).
    /// Whether a generic param's bound makes it a sequence/collection (so it should
    /// be instantiated as the container `[E]`, not the element `E`).
    private func isSequenceLikeBound(_ bound: String) -> Bool {
        let parts = bound.split(separator: "&").map { $0.trimmingCharacters(in: .whitespaces) }
        let seqLike: Set<String> = [
            "Sequence", "Collection", "BidirectionalCollection",
            "RandomAccessCollection", "RangeReplaceableCollection", "MutableCollection",
        ]
        return parts.contains { seqLike.contains($0) }
    }

    private func concreteFor(bound: String?, preferred: String) -> String? {
        guard let bound, !bound.isEmpty else { return preferred }     // unconstrained
        // A composed bound (`A & B`) or `where`-driven bound: split on `&`.
        let parts = bound.split(separator: "&").map { $0.trimmingCharacters(in: .whitespaces) }
        for p in parts {
            switch p {
            // Protocols all three driving types conform to.
            case "Comparable", "Equatable", "Hashable", "Codable", "Encodable",
                 "Decodable", "Sendable", "CustomStringConvertible", "Any":
                continue
            // Numeric/arithmetic bounds: Int & Double satisfy; String does not.
            case "Numeric", "SignedNumeric", "AdditiveArithmetic", "BinaryInteger",
                 "FixedWidthInteger", "SignedInteger", "Strideable":
                if preferred == "String" { return nil }
                continue
            case "BinaryFloatingPoint", "FloatingPoint":
                if preferred != "Double" { return nil }
                continue
            default:
                // An unrecognised / library protocol bound → cannot prove a concrete
                // conformance safely. Skip (stays native).
                return nil
            }
        }
        return preferred
    }

    // MARK: - Per-instantiation export build

    private func buildExport(
        funcNode: FunctionDeclSyntax, receiver: Receiver, funcName: String,
        enclosingType: String?, inst: Instantiation,
        verbatimDefinition: String, definitionKey: String
    ) -> CodeEmitter.PureExport? {
        // Substitute the placeholders in each parameter type; reject anything that
        // does not reduce to an ABI-codable concrete type (closures/inout/opaque/
        // generic leftovers all fail `isABICodable`).
        var params: [(label: String, name: String, type: String)] = []
        for p in funcNode.signature.parameterClause.parameters {
            let label = p.firstName.text
            let internalName = (p.secondName ?? p.firstName).text
            let raw = p.type.trimmedDescription
            // A closure / autoclosure / variadic / inout param can't cross JSON.
            if raw.contains("->") || raw.contains("inout ") || p.ellipsis != nil { return nil }
            if raw.hasPrefix("some ") || raw.hasPrefix("any ") { return nil }
            let sub = substitute(raw, inst.subst)
            guard isABICodable(sub) else { return nil }
            params.append((label: label, name: internalName, type: sub))
        }

        // Substitute the return type; must be ABI-codable concrete (so a library
        // wrapper return like `CombinationsSequence<Self>` or a leftover `Element`
        // that didn't substitute is rejected → stays native).
        let rawRet = funcNode.signature.returnClause?.type.trimmedDescription ?? ""
        var ret = ""
        if !rawRet.isEmpty && rawRet != "Void" {
            if rawRet.hasPrefix("some ") || rawRet.hasPrefix("any ") { return nil }
            ret = substitute(rawRet, inst.subst)
            guard isABICodable(ret) else { return nil }
        }

        let spec = CodeEmitter.PureExport.GenericSpecialization(
            verbatimDefinition: verbatimDefinition, definitionKey: definitionKey,
            instantiation: inst.label)

        // Disambiguate overloads (`min(count:)` vs `min(count:sortedBy:)`) by folding
        // the argument labels into the export stem, so two overloads of the same
        // simple name don't both claim `min_Int` and silently drop one.
        let labelStem = funcNode.signature.parameterClause.parameters
            .compactMap { p -> String? in
                let l = p.firstName.text
                return l == "_" ? nil : l
            }
            .joined(separator: "_")
        let stem = labelStem.isEmpty ? funcName : "\(funcName)_\(labelStem)"

        switch receiver {
        case .sequenceExtension:
            guard let recv = inst.subst["Self"] else { return nil }
            // exportName is qualified by the labels + concrete element tag, e.g.
            // `min_count_Int`. The bundler dedups identical exportNames.
            let exportName = "\(stem)_\(inst.tag)"
            return CodeEmitter.PureExport(
                exportName: exportName, callee: funcName, parameters: params,
                returnType: ret, receiverType: recv, genericSpec: spec)
        case .free(let callPrefix):
            let exportName = "\(stem)_\(inst.tag)"
            return CodeEmitter.PureExport(
                exportName: exportName, callee: "\(callPrefix)\(funcName)",
                parameters: params, returnType: ret, genericSpec: spec)
        }
    }

    // MARK: - Type substitution + ABI check

    /// Substitute generic placeholders inside a type string by whole-identifier
    /// replacement (so `Element` → `Int` rewrites `[Element]`→`[Int]`,
    /// `(min: Element, max: Element)?`→`(min: Int, max: Int)?`, but never touches a
    /// substring of a longer identifier like `Elements`). Longest keys first.
    func substitute(_ type: String, _ subst: [String: String]) -> String {
        var s = type
        for key in subst.keys.sorted(by: { $0.count > $1.count }) {
            guard let value = subst[key] else { continue }
            s = replaceIdentifier(key, with: value, in: s)
        }
        return s
    }

    private func replaceIdentifier(_ ident: String, with value: String, in s: String) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        while i < chars.count {
            // Try to match `ident` at i with word boundaries on both sides.
            if matchesAt(chars, i, ident) {
                let beforeOK = (i == 0) || !isWord(chars[i - 1])
                let after = i + ident.count
                let afterOK = (after >= chars.count) || !isWord(chars[after])
                // Don't replace `Self` when it's a member like `Self.Index` — but for
                // ABI we reject any non-substituted leftover later, so a literal
                // replacement is safe; still, only replace whole tokens.
                if beforeOK && afterOK {
                    out += value
                    i = after
                    continue
                }
            }
            out.append(chars[i]); i += 1
        }
        return out
    }
    private func matchesAt(_ chars: [Character], _ i: Int, _ ident: String) -> Bool {
        let id = Array(ident)
        guard i + id.count <= chars.count else { return false }
        for k in 0..<id.count where chars[i + k] != id[k] { return false }
        return true
    }

    /// A type that survives the JSON (ptr,len) ABI: a scalar/string, a Codable
    /// Foundation value, or a container/optional/tuple thereof. CRUCIALLY this
    /// REJECTS any leftover uppercase generic placeholder (`Self`, `Element`, `T`,
    /// `Subject`, …) and any library-generic wrapper (`CombinationsSequence<…>`),
    /// so an unspecialized boundary is never shipped (no false positives).
    func isABICodable(_ type: String) -> Bool {
        var s = type.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "Void" { return true }
        if s.contains("->") { return false }
        if s.hasPrefix("some ") || s.hasPrefix("any ") { return false }
        // Strip optionals.
        while s.hasSuffix("?") || s.hasSuffix("!") { s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
        // Tuple: every element must be ABI-codable.
        if s.hasPrefix("(") && s.hasSuffix(")") {
            let inner = String(s.dropFirst().dropLast())
            for part in splitTopLevel(inner, sep: ",") {
                // Drop a tuple label (`min: Element`).
                let t = part.contains(":") ? String(part.split(separator: ":", maxSplits: 1).last!) : part
                if !isABICodable(t.trimmingCharacters(in: .whitespaces)) { return false }
            }
            return true
        }
        // Array `[T]` / dictionary `[K: V]`.
        if s.hasPrefix("[") && s.hasSuffix("]") {
            let inner = String(s.dropFirst().dropLast())
            if let colon = topLevelColon(inner) {
                let k = String(inner[inner.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let v = String(inner[inner.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                return isABICodable(k) && isABICodable(v)
            }
            return isABICodable(inner.trimmingCharacters(in: .whitespaces))
        }
        // Generic container `Array<T>` / `Optional<T>` / `Set<T>` / `Dictionary<K,V>`.
        if let lt = s.firstIndex(of: "<"), s.hasSuffix(">") {
            let base = String(s[s.startIndex..<lt])
            guard ["Array", "Set", "Optional", "Dictionary"].contains(base) else { return false }
            let inner = String(s[s.index(after: lt)..<s.index(before: s.endIndex)])
            return splitTopLevel(inner, sep: ",").allSatisfy { isABICodable($0.trimmingCharacters(in: .whitespaces)) }
        }
        // Bare nominal: must be a known Codable scalar/value leaf OR a project VALUE
        // type (struct/enum) the build pipeline reconstructs as Codable (Breakthrough
        // #7 — custom value-type boundaries). A leftover generic placeholder
        // (Self/Element/T/…) is in NEITHER set → rejected.
        return Self.abiLeaves.contains(s) || context.projectValueTypeNames.contains(s)
    }

    static let abiLeaves: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "Bool", "String", "Character", "Substring",
        "Decimal", "Date", "UUID", "URL", "Data", "TimeInterval", "CGFloat",
    ]

    // MARK: - Generic-param collection

    /// All generic parameter (name, primary-bound) pairs declared on the function:
    /// from `<T: P, U>` AND from a trailing `where Element: P` clause (best-effort).
    private func collectGenericParamNames(_ fn: FunctionDeclSyntax) -> [(name: String, bound: String?)] {
        var out: [(name: String, bound: String?)] = []
        if let gp = fn.genericParameterClause {
            for p in gp.parameters {
                out.append((name: p.name.text, bound: p.inheritedType?.trimmedDescription))
            }
        }
        // Fold same-type / conformance requirements from the where clause into bounds.
        if let wc = fn.genericWhereClause {
            for req in wc.requirements {
                if let conf = req.requirement.as(ConformanceRequirementSyntax.self) {
                    let lhs = conf.leftType.trimmedDescription
                    let rhs = conf.rightType.trimmedDescription
                    if let idx = out.firstIndex(where: { $0.name == lhs }) {
                        let merged = (out[idx].bound.map { "\($0) & \(rhs)" }) ?? rhs
                        out[idx].bound = merged
                    }
                }
            }
        }
        return out
    }

    /// If a `where`-clause pins an element to a concrete driving type
    /// (`C.Element == Int`, `Element == String`, `Self.Element == Double`), return
    /// that type; else nil. Only pins to one of our driving element types count (a
    /// pin to some other concrete type makes NO driving instantiation valid → the
    /// caller drops all instantiations, staying native).
    private func collectElementPin(_ fn: FunctionDeclSyntax) -> String? {
        guard let wc = fn.genericWhereClause else { return nil }
        for req in wc.requirements {
            guard let same = req.requirement.as(SameTypeRequirementSyntax.self) else { continue }
            let lhs = same.leftType.trimmedDescription
            let rhs = same.rightType.trimmedDescription
            // Look for `<X>.Element == <Concrete>` (or the reverse).
            func pin(_ a: String, _ b: String) -> String? {
                guard a.hasSuffix(".Element") || a == "Element" else { return nil }
                return Self.elementTypes.map { $0.elem }.contains(b) ? b : "__unsatisfiable__"
            }
            if let p = pin(lhs, rhs) ?? pin(rhs, lhs) { return p }
        }
        return nil
    }

    private func substLabel(_ subst: [String: String]) -> String {
        subst.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }

    // MARK: - Tiny top-level splitters (bracket/paren/angle aware)

    private func splitTopLevel(_ s: String, sep: Character) -> [String] {
        var parts: [String] = []; var depth = 0; var cur = ""
        for c in s {
            if c == "(" || c == "[" || c == "<" { depth += 1 }
            else if c == ")" || c == "]" || c == ">" { depth -= 1 }
            if c == sep && depth == 0 { parts.append(cur); cur = "" } else { cur.append(c) }
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts
    }
    private func topLevelColon(_ s: String) -> String.Index? {
        var depth = 0
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "(" || c == "[" || c == "<" { depth += 1 }
            else if c == ")" || c == "]" || c == ">" { depth -= 1 }
            else if c == ":" && depth == 0 { return i }
            i = s.index(after: i)
        }
        return nil
    }
}
