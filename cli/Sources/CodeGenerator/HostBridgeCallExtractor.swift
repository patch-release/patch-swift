// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser

// ===========================================================================
// LEVER #2 (part B) — the CALL-SITE EXTRACTOR (the rewriter's FRONT-END).
//
// `GeneralBridgeRewriter` (sibling) owns the CLASSIFIER (`classify(Candidate) ->
// Verdict`) + the guest-sequence emission, and `HostBridgeABI` (parallel) owns
// the TLV ABI core + the `canonicalSignature` derivation. THIS file is the
// missing front-end: given a function the engine currently keeps NATIVE (a
// forced-native or mixed function's SwiftSyntax body), it WALKS the body, finds
// the native call sites inside it, and produces the structured `Candidate`s the
// classifier consumes (+ enough info to build a `ResolvedCall` for the ABI core).
//
// It GENERALIZES the curated `FusionRewriter` leaf-matching (a closed, hand-
// authored leaf set) to ARBITRARY `recv.method(args)` / static `Type.method(args)`
// / free `f(args)` call sites.
//
// DISCIPLINE — OPTIMISTIC but SAFE. The downstream net is FAIL-CLOSED on three
// layers, so this front-end may PROPOSE a candidate even when its type resolution
// is imperfect:
//   1. the classifier (`GeneralBridgeRewriter.classify`) DEMOTES on any
//      unmarshallable / unknown arg or return, any structural hazard flag, and
//      any hard-token in the raw expression (inout/unsafe/.self/#selector);
//   2. the resolver-thunk generator's `swiftc -typecheck` net drops any candidate
//      whose generated thunk won't compile against the app's real types;
//   3. the runtime `have()`-preflight + `.error`-fallback demotes a routed call
//      that fails to resolve on-device.
// So the extractor's job is to surface PLAUSIBLE candidates with accurate-as-
// possible types + HONEST "unknown" markers. It NEVER fabricates a type it cannot
// justify — a wrong type that happens to compile would MIS-MARSHAL. When the type
// is unknown-from-syntax, it is marked with `Self.unresolvedType` so the classifier
// demotes (DEMOTE-ON-DOUBT). It also NEVER emits a candidate for a hard-native
// shape (inout/closure/generic/unsafe/variadic/metatype/selector) — those are
// flagged so the classifier demotes them.
// ===========================================================================

public struct HostBridgeCallExtractor {

    /// The sentinel "I could not resolve this type from syntax" marker. The
    /// classifier's `marshallableTag` does not recognise it → `.unmarshallableArgType`
    /// / `.unmarshallableReturn` demote. NEVER a real Swift type, so it can never be
    /// mistaken for one.
    public static let unresolvedType = "<unresolved>"

    /// The module the extracted call sites belong to (the prefix for an
    /// app-local symbol's canonical receiver, e.g. `MyApp.PricingEngine`). A
    /// receiver the extractor can confidently attribute to a framework
    /// (`Foundation`/`UIKit`/…) is prefixed with that framework instead.
    public let moduleName: String

    /// Names → canonical receiver-type spellings for a curated stateless
    /// Foundation quartet the survey calls out (DESIGN §4.1 example set). A call
    /// whose `recv` text matches one of these keys is tagged `.foundationStateless`
    /// (so the classifier's `foundationStateless` form fires) and the receiver is
    /// module-qualified from the value. Everything ELSE goes through the generic
    /// `freeOrStatic` path. This is a small recognition table, NOT the closed
    /// curated-leaf set — it only steers the FORM tag + canonical receiver spelling.
    static let foundationStatelessReceivers: [String: (canonical: String, module: String)] = [
        "NotificationCenter.default": ("Foundation.NotificationCenter", "Foundation"),
        "FileManager.default":        ("Foundation.FileManager", "Foundation"),
        "UIApplication.shared":       ("UIKit.UIApplication", "UIKit"),
        "NSWorkspace.shared":         ("AppKit.NSWorkspace", "AppKit"),
    ]

    /// Return types KNOWN from the framework for the curated Foundation-stateless
    /// quartet's method names. A method's return type is not visible from pure call
    /// syntax, but for THESE well-known stateless members it is a stable framework
    /// fact, so the extractor can supply it honestly (it is not a guess — it is the
    /// documented signature). Keyed by `<canonicalReceiver>.<method>`. Anything not
    /// in this table reports its return UNRESOLVED (demote-on-doubt) unless the
    /// engine injects a hint via `TypeContext.returnTypeHints`.
    static let foundationStatelessReturns: [String: String] = [
        "Foundation.NotificationCenter.post": "Void",
        "Foundation.FileManager.fileExists": "Bool",
        "Foundation.FileManager.removeItem": "Void",
        "Foundation.FileManager.createDirectory": "Void",
        "UIKit.UIApplication.open": "Bool",
        "AppKit.NSWorkspace.open": "Bool",
    ]

    public init(moduleName: String = "MyApp") {
        self.moduleName = moduleName
    }

    // =======================================================================
    // MARK: - The type context
    //
    // The available type information the extractor reasons over. It is supplied by
    // the engine (which has the function's params/locals from the FunctionExtractor
    // pass) OR derived locally by `extract(fromBody:)` from the body's own `let`/
    // `var` bindings + the function signature. NO whole-program type checker is
    // assumed — we infer from SYNTAX only and mark anything ambiguous unresolved.
    // =======================================================================
    public struct TypeContext: Sendable, Equatable {
        /// name → declared/inferred Swift type for every in-scope value (params +
        /// locals). A value-type-resolvable name maps to its concrete type
        /// (`"Double"`); a name we cannot type is simply ABSENT (a reference to an
        /// absent name infers `unresolvedType`).
        public var locals: [String: String]
        /// Names bound to the result of a PRIOR routed call (handle-producing → the
        /// value is a host-side proxy held by handle). A later call passing such a
        /// name marks that arg `isHandle: true` (the §3.2 chain).
        public var handleNames: Set<String>
        /// Engine-supplied return-type hints keyed by `<receiver>.<function>` (the
        /// shape's receiver text + the member name). A method's return type is NOT
        /// visible from pure call syntax; when the engine HAS resolved it (it has the
        /// decl in the type-checker pass), it injects it here so the extractor reports
        /// an accurate return instead of `unresolvedType`. Absent → the extractor
        /// falls back to the curated framework table, then to unresolved (demote).
        public var returnTypeHints: [String: String]

        public init(locals: [String: String] = [:],
                    handleNames: Set<String> = [],
                    returnTypeHints: [String: String] = [:]) {
            self.locals = locals
            self.handleNames = handleNames
            self.returnTypeHints = returnTypeHints
        }
    }

    // =======================================================================
    // MARK: - Public entry points
    // =======================================================================

    /// Walk a function body given as SOURCE TEXT (a whole `func`/closure or just its
    /// `{ … }` body). Parses, seeds the type context from the signature + body
    /// bindings, layers any engine-supplied return-type hints, and returns every
    /// extracted candidate in source order. The convenience the tests + the engine
    /// integration both call.
    ///
    /// `returnTypeHints` is keyed by `<receiver>.<function>` (or just `<function>`
    /// for a bare free fn) — the engine injects resolved return types it has from
    /// the type-checker pass; absent ones fall back to the curated framework table
    /// then to unresolved (demote-on-doubt).
    public func extract(fromSource source: String,
                        returnTypeHints: [String: String] = [:])
        -> [GeneralBridgeRewriter.Candidate]
    {
        let tree = Parser.parse(source: source)
        // Seed the context from the FIRST function declaration's signature (params)
        // if the source is a whole decl; otherwise an empty seed (body-local binding
        // discovery still runs during the walk).
        var seed = Self.seedContext(from: Syntax(tree))
        seed.returnTypeHints = returnTypeHints
        return extract(body: Syntax(tree), context: seed)
    }

    /// Walk an already-parsed body node with a caller-supplied (or empty) context.
    /// The body's own `let`/`var` bindings are discovered DURING the walk in source
    /// order, so a binding flows into the type context for calls that follow it
    /// (including the handle-chain: a `let f = makeFormatter()` routed call makes
    /// `f` a handle name for the `f.string(…)` call below it).
    public func extract(body: Syntax,
                        context: TypeContext) -> [GeneralBridgeRewriter.Candidate] {
        let walker = CallWalker(extractor: self, context: context)
        walker.walk(body)
        return walker.candidates
    }

    // =======================================================================
    // MARK: - Context seeding from a parsed decl
    // =======================================================================

    /// Seed a `TypeContext.locals` from a parsed function declaration's parameter
    /// clause (the param names + their ANNOTATED types — the most reliable source).
    /// A param with no usable annotation is omitted (its uses infer unresolved).
    static func seedContext(from tree: Syntax) -> TypeContext {
        var locals: [String: String] = [:]
        final class ParamCollector: SyntaxVisitor {
            var locals: [String: String] = [:]
            var captured = false
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                // Only the OUTERMOST function's params seed the context (a nested
                // func's params are its own scope; the walk re-seeds for nesteds if
                // needed). Capture the first and stop descending into siblings.
                guard !captured else { return .skipChildren }
                captured = true
                for p in node.signature.parameterClause.parameters {
                    let name = (p.secondName ?? p.firstName).text
                    guard name != "_" else { continue }
                    let type = p.type.trimmedDescription
                    locals[name] = type
                }
                return .visitChildren
            }
        }
        let c = ParamCollector(viewMode: .sourceAccurate)
        c.walk(tree)
        locals = c.locals
        return TypeContext(locals: locals)
    }

    // =======================================================================
    // MARK: - Arg type inference (SYNTAX-only, demote-on-doubt)
    // =======================================================================

    /// Infer the Swift type of an argument expression from the available context.
    /// Returns a concrete type spelling when it can be JUSTIFIED from syntax, else
    /// `Self.unresolvedType` (NEVER a guess). The recognised sources, in order:
    ///   1. a literal (`1` → Int, `1.0` → Double, `true` → Bool, `"x"` → String);
    ///   2. an in-context local/param name (from `context.locals`);
    ///   3. an obvious scalar conversion / constructor (`Double(x)` → Double,
    ///      `Int(x)` → Int, `String(x)` → String, `Bool(x)` → Bool);
    ///   4. a `.member` access whose value type we CANNOT see → unresolved.
    /// Anything else (a method-call result, a property read, an enum case, an
    /// operator expression of unknown operand types) → unresolved.
    static func inferArgType(_ expr: ExprSyntax, context: TypeContext) -> String {
        // 1. Literals — unambiguous.
        if expr.is(IntegerLiteralExprSyntax.self) { return "Int" }
        if expr.is(FloatLiteralExprSyntax.self)   { return "Double" }
        if expr.is(BooleanLiteralExprSyntax.self) { return "Bool" }
        if let str = expr.as(StringLiteralExprSyntax.self) {
            // A plain (non-interpolated) string literal is `String`. An interpolated
            // one is still `String`, but if it embeds an unresolved sub-expr the
            // VALUE is still a String at runtime — interpolation always yields String.
            _ = str
            return "String"
        }

        // 2. A bare identifier in the type context (a param / a typed local).
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            if let t = context.locals[ref.baseName.text] { return t }
            return unresolvedType
        }

        // 3. An obvious scalar conversion / constructor whose RESULT type is the
        // callee name itself (`Double(x)`, `Int(x)`, `String(x)`, `Bool(x)`, the
        // unsigned/sized variants). The argument's own type doesn't matter — the
        // CONVERSION's result is the named scalar.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = callee.baseName.text
            if scalarConversionTypes.contains(name) { return name }
            // Any OTHER free/initializer call result — unknown without a checker.
            return unresolvedType
        }

        // 4. A `.member` access (`obj.prop`, `Enum.case`, `x.rawValue`): the value
        // type is not visible from syntax. `x.rawValue` is commonly String/Int but
        // we cannot PROVE which → unresolved (demote-on-doubt; the thunk-compile net
        // would catch a wrong guess, but we never guess).
        if expr.is(MemberAccessExprSyntax.self) {
            return unresolvedType
        }

        // 5. An `&x` inout sigil — the type is whatever `x` is, but the PRESENCE of
        // inout is itself a demote (flagged structurally too). Report the underlying
        // type best-effort so the canonical signature is still informative; the
        // structural `hasInoutArg` flag + the raw-token gate demote it regardless.
        if let inout_ = expr.as(InOutExprSyntax.self) {
            return inferArgType(inout_.expression, context: context)
        }

        // Everything else: not resolvable from syntax.
        return unresolvedType
    }

    /// Scalar-conversion / constructor callee names whose RESULT type is the name.
    static let scalarConversionTypes: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "CGFloat", "Bool", "String",
    ]

    /// The value-marshallable scalar/string types the wire carries by value. Used to
    /// decide whether a binding's inferred type makes it a CONSUMABLE arg later (vs.
    /// a handle / an unresolved type). Mirrors the classifier's `marshallableTag`.
    static let byValueTypes: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "CGFloat", "Bool", "String", "Data", "[UInt8]",
    ]

    // =======================================================================
    // MARK: - The walker
    // =======================================================================
    //
    // A SyntaxVisitor that, in SOURCE ORDER:
    //   - threads through `let`/`var` bindings into the live type context (so a
    //     binding's type is available to calls that follow it), AND records a
    //     binding whose initializer is a ROUTABLE call as a HANDLE name when that
    //     call returns a non-marshallable reference (the §3.2 chain producer);
    //   - for every `FunctionCallExprSyntax`, builds a `Candidate` (or skips a shape
    //     it cannot describe at all — a bare call with no resolvable callee).
    // =======================================================================
    final class CallWalker: SyntaxVisitor {
        let extractor: HostBridgeCallExtractor
        var context: TypeContext
        var candidates: [GeneralBridgeRewriter.Candidate] = []

        init(extractor: HostBridgeCallExtractor, context: TypeContext) {
            self.extractor = extractor
            self.context = context
            super.init(viewMode: .sourceAccurate)
        }

        // Thread a `let x = <init>` / `var x = <init>` binding into the live
        // context BEFORE descending, so the binding is visible to calls after it.
        // We visit the binding's initializer for nested calls via .visitChildren,
        // but we record the binding's type/handle-ness here first.
        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            for binding in node.bindings {
                guard let ident = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                else { continue }
                // An explicit annotation is the most reliable type source.
                if let annotated = binding.typeAnnotation?.type.trimmedDescription {
                    context.locals[ident] = annotated
                }
                // Inspect the initializer: a routable call's result either marshals
                // by value (a scalar local) OR is a non-marshallable reference held
                // by HANDLE — that makes `ident` a handle name for later calls.
                if let initExpr = binding.initializer?.value {
                    classifyBindingInitializer(name: ident, initExpr: initExpr,
                                               hadAnnotation: binding.typeAnnotation != nil)
                }
            }
            return .visitChildren
        }

        /// Decide what an initializer binding contributes to the context:
        ///   - if it is a routable call returning a NON-by-value reference (a type
        ///     not in `byValueTypes` and not unresolved), the binding is a HANDLE
        ///     name (the §3.2 producer): later calls passing `name` mark that arg a
        ///     handle. We also leave its `locals` type as the reference type so the
        ///     canonical signature of the consumer is informative.
        ///   - if it is a literal / scalar conversion, seed `locals[name]` with the
        ///     inferred by-value type (so a later call passing `name` resolves it).
        private func classifyBindingInitializer(name: String, initExpr: ExprSyntax,
                                                hadAnnotation: Bool) {
            // A call whose result is a reference the guest can't reconstruct →
            // handle producer. We recognise the producer SYNTACTICALLY: an
            // initializer that is a call (`makeFormatter()`, `NumberFormatter()`,
            // `Type.make(...)`) whose result type is NOT a by-value scalar.
            if let call = initExpr.as(FunctionCallExprSyntax.self) {
                let resultType = Self.resultTypeOfCall(call, context: context)
                if let resultType {
                    // A scalar/string result → seed the by-value local type.
                    if HostBridgeCallExtractor.byValueTypes.contains(resultType) {
                        if !hadAnnotation { context.locals[name] = resultType }
                        return
                    }
                    // A NON-by-value, NON-unresolved reference result → handle.
                    if resultType != HostBridgeCallExtractor.unresolvedType {
                        context.handleNames.insert(name)
                        if !hadAnnotation { context.locals[name] = resultType }
                        return
                    }
                }
                // Unresolved call result: if the binding had a by-value annotation,
                // it is already seeded; otherwise leave it absent (uses infer
                // unresolved). Do NOT speculatively mark a handle on an unknown.
                return
            }
            // Non-call initializer (a literal / conversion): seed the by-value type.
            if !hadAnnotation {
                let t = HostBridgeCallExtractor.inferArgType(initExpr, context: context)
                if t != HostBridgeCallExtractor.unresolvedType {
                    context.locals[name] = t
                }
            }
        }

        /// The result type of a constructor-style or routable call used as a binding
        /// initializer, best-effort from SYNTAX. A bare `Type(...)` constructor
        /// yields `Type` (a reference unless it is a scalar). A `recv.method(...)` /
        /// free `f(...)` whose return we cannot see → unresolved.
        static func resultTypeOfCall(_ call: FunctionCallExprSyntax,
                                     context: TypeContext) -> String? {
            // `Type(...)` — a bare nominal constructor. Its result is `Type`.
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                let name = callee.baseName.text
                if name.first?.isUppercase == true { return name }
                // A lowercase free function: result type unknown from syntax.
                return HostBridgeCallExtractor.unresolvedType
            }
            // `Type.init(...)` / `Module.Type(...)` member-constructor.
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                if member.declName.baseName.text == "init",
                   let base = member.base?.trimmedDescription {
                    return base.split(separator: ".").last.map(String.init)
                }
                // `recv.method(...)` — return type not visible from syntax.
                return HostBridgeCallExtractor.unresolvedType
            }
            return HostBridgeCallExtractor.unresolvedType
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let cand = extractor.makeCandidate(from: node, context: context) {
                candidates.append(cand)
            }
            // Descend so nested calls in the arguments are ALSO extracted (a routed
            // call can be an argument to another call). Each is classified on its own
            // merits; the engine routes the safe ones, demotes the rest.
            return .visitChildren
        }
    }

    // =======================================================================
    // MARK: - Candidate construction
    // =======================================================================

    /// Build a `Candidate` for one call expression, or `nil` if the call has no
    /// describable shape (no resolvable callee — e.g. a call on a complex computed
    /// receiver expression). A `nil` simply means "the extractor proposes nothing
    /// here" (the call stays native, like any un-extracted span).
    func makeCandidate(from call: FunctionCallExprSyntax,
                       context: TypeContext) -> GeneralBridgeRewriter.Candidate? {
        // ---- Resolve the call SHAPE (receiver / function / kind) ----
        let shape = callShape(call)
        guard let shape else { return nil }

        let nativeExpr = call.trimmedDescription

        // ---- Structural hazards (set the demote flags; the classifier honours
        // them). We inspect the args + the callee for the §8 hard limits. ----
        var hasInoutArg = false
        var hasEscapingClosureArg = false
        var isVariadic = false
        var isUnspecializedGeneric = false

        // An UNSPECIALISED generic at the call site: a callee carrying a metatype
        // `<...>` generic-argument clause we cannot resolve element types for is an
        // engine-side concern; the classifier's `isUnspecializedGeneric` flag is set
        // by the engine when it KNOWS the symbol is unspecialised. From pure syntax we
        // only flag the conservative case below (an arg typed to a bare uppercase
        // single-letter type-parameter spelling like `T`).

        // ---- Build the structured args (+ capture call-site labels for the
        // canonical signature). ----
        var args: [GeneralBridgeRewriter.Candidate.Arg] = []
        var argLabels: [String?] = []
        for argSyntax in call.arguments {
            let expr = argSyntax.expression
            let exprText = expr.trimmedDescription
            argLabels.append(argSyntax.label?.text)

            // inout `&x`.
            if expr.is(InOutExprSyntax.self) { hasInoutArg = true }

            // A closure argument (explicit `{ … }` in the parens or a trailing
            // closure handled below) → escaping-closure hazard. A trivial stateless
            // closure could in principle be pre-registered, but that is out of part-A
            // scope (DESIGN §8.2) → flag for demote.
            if expr.is(ClosureExprSyntax.self) { hasEscapingClosureArg = true }

            // A variadic pack at the site is not syntactically distinguishable from
            // a normal multi-arg call WITHOUT the declaration; the engine sets
            // `isVariadic` when it knows the param is variadic. We leave it to the
            // raw-token/structural net + the thunk-compile net.

            let swiftType = Self.inferArgType(expr, context: context)
            let isHandle = Self.argIsHandle(expr, context: context)
            // A bare type-parameter spelling (`T`/`U`/`Element`) inferred for an arg
            // means the call site does not concretize the generic → unspecialised.
            if Self.looksLikeTypeParameter(swiftType) { isUnspecializedGeneric = true }
            args.append(.init(expr: exprText, swiftType: swiftType, isHandle: isHandle))
        }

        // A TRAILING CLOSURE is an argument too — and an escaping-closure hazard.
        if call.trailingClosure != nil || !(call.additionalTrailingClosures.isEmpty) {
            hasEscapingClosureArg = true
        }

        // ---- Return type. A call's return type is NOT visible from pure call
        // syntax. We resolve it, in order of confidence:
        //   1. an engine-supplied hint (`returnTypeHints["<receiver>.<function>"]`)
        //      — the engine has the resolved decl from the type-checker pass;
        //   2. the curated framework table for a known Foundation-stateless member
        //      (`fileExists`→Bool, `post`→Void — documented signatures, not guesses);
        //   3. otherwise UNRESOLVED → the classifier demotes (demote-on-doubt).
        // A wrong return type would mis-decode the result, so we NEVER guess one. ----
        var returnType = resolveReturnType(shape: shape, context: context)
        let returnIsHandle = false

        // ---- KNOWN-SYMBOL CONFIDENT LOOKUP (the breadth foundation; ADDITIVE). ----
        // For a small curated set of high-frequency, KNOWN-bridgeable framework symbols
        // (`NotificationCenter.default.post(name:)`, `UserDefaults.standard.bool(forKey:)`,
        // `FileManager.default.fileExists(atPath:)`, `UIApplication.shared.open(_:)`, …)
        // the arg/return types are a DOCUMENTED, STABLE fact — not a syntactic guess.
        // When a call MATCHES a curated entry, we UPGRADE any `<unresolved>` arg/return
        // to the confident curated type (and module-qualify the receiver), bypassing the
        // `<unresolved>` demote for exactly those symbols. STRICTLY additive + safe:
        //   * it never OVERRIDES a conflicting concrete syntactic type (a mismatch means
        //     the call doesn't fit the curated overload → left to demote-on-doubt);
        //   * it runs DOWNSTREAM of the structural hazard flags (inout/closure/…), so a
        //     hazardous arg on a curated symbol still demotes;
        //   * a non-match leaves the syntactic resolution exactly as it was.
        // The hook touches ONLY the arg/return TYPES + the canonical-receiver spelling —
        // it does not re-walk the body or re-gate the classifier (parallel-agent surfaces).
        var knownCanonicalReceiver: String? = nil
        if let known = HostBridgeKnownSymbols.overloadEntry(
            receiver: shape.receiver, method: shape.function, arity: args.count,
            firstArgType: args.first?.swiftType),
           let resolved = HostBridgeKnownSymbols.resolve(
            known, syntacticArgTypes: args.map(\.swiftType)) {
            // Upgrade each arg's type in place (preserving its expr + handle-ness).
            for i in args.indices where i < resolved.argTypes.count {
                args[i] = .init(expr: args[i].expr,
                                swiftType: resolved.argTypes[i],
                                isHandle: args[i].isHandle)
            }
            returnType = resolved.returnType
            knownCanonicalReceiver = known.canonicalReceiver
        }

        // ---- Canonical signature (best-effort; the ABI core canonicalizes). The
        // string is built via the ABI core's `ResolvedCall` + `canonicalSignature`
        // so it follows the SAME rules the resolver-thunk uses (module-qualified
        // receiver, label:type params, optional desugaring, void-return omission). ----
        let canonical = HostBridgeABI.canonicalSignature(
            resolvedCall(shape: shape, args: args, labels: argLabels, returnType: returnType,
                         canonicalReceiverOverride: knownCanonicalReceiver))

        return GeneralBridgeRewriter.Candidate(
            kind: shape.kind,
            receiver: shape.receiver,
            function: shape.function,
            nativeExpr: nativeExpr,
            canonicalSignature: canonical,
            args: args,
            returnType: returnType,
            returnIsHandle: returnIsHandle,
            hasInoutArg: hasInoutArg,
            hasEscapingClosureArg: hasEscapingClosureArg,
            isUnspecializedGeneric: isUnspecializedGeneric,
            isVariadic: isVariadic,
            touchesCrossThreadObject: false,
            symbolResolvable: true /* the engine consults the routed-symbol set */)
    }

    /// Is an argument expression a HANDLE — a bare reference to a name bound to a
    /// prior routed call's reference result (the §3.2 chain consumer)?
    static func argIsHandle(_ expr: ExprSyntax, context: TypeContext) -> Bool {
        guard let ref = expr.as(DeclReferenceExprSyntax.self) else { return false }
        return context.handleNames.contains(ref.baseName.text)
    }

    /// Resolve a call's return type (NOT visible from pure call syntax), in order of
    /// confidence: an engine hint, then the curated framework table, then unresolved.
    func resolveReturnType(shape: CallShape, context: TypeContext) -> String {
        // 1. Engine-supplied hint keyed by the call-site receiver + member.
        let key = shape.receiver.isEmpty
            ? shape.function
            : "\(shape.receiver).\(shape.function)"
        if let hinted = context.returnTypeHints[key], !hinted.isEmpty {
            return hinted
        }
        // 2. Curated framework table for a known Foundation-stateless member.
        if shape.kind == .foundationStateless,
           let canon = Self.foundationStatelessReceivers[shape.receiver]?.canonical,
           let ret = Self.foundationStatelessReturns["\(canon).\(shape.function)"] {
            return ret
        }
        // 3. Unknown — demote-on-doubt.
        return Self.unresolvedType
    }

    // =======================================================================
    // MARK: - Call shape resolution
    // =======================================================================

    /// The resolved shape of a call site: its kind + receiver + function name.
    public struct CallShape: Sendable, Equatable {
        public let kind: GeneralBridgeRewriter.Candidate.Kind
        /// The qualifier (`"PricingEngine"`, `"NotificationCenter.default"`,
        /// `"formatter"`) or "" for a bare free function.
        public let receiver: String
        /// The called function/member base name.
        public let function: String
        /// True when the receiver is a known instance VALUE (a lowercase local), as
        /// opposed to a static `Type`/free function. Used only for canonical-sig
        /// receiver-type spelling.
        public let receiverIsInstance: Bool

        public init(kind: GeneralBridgeRewriter.Candidate.Kind, receiver: String,
                    function: String, receiverIsInstance: Bool) {
            self.kind = kind
            self.receiver = receiver
            self.function = function
            self.receiverIsInstance = receiverIsInstance
        }
    }

    /// Resolve a call's shape, or nil if no callee name is recoverable.
    func callShape(_ call: FunctionCallExprSyntax) -> CallShape? {
        // `f(args)` — a bare free function.
        if let ident = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return CallShape(kind: .freeOrStatic, receiver: "",
                             function: ident.baseName.text, receiverIsInstance: false)
        }
        // `recv.method(args)` — a member access callee.
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else {
            return nil
        }
        let function = member.declName.baseName.text
        guard let base = member.base else {
            // `.method(args)` — an implicit-base member (an enum case / leading-dot).
            // No receiver to qualify → not a describable routable shape.
            return nil
        }
        let baseText = base.trimmedDescription

        // A curated Foundation-stateless receiver path → the `foundationStateless`
        // form (steers the canonical-receiver spelling + the classifier form tag).
        if Self.foundationStatelessReceivers[baseText] != nil {
            return CallShape(kind: .foundationStateless, receiver: baseText,
                             function: function, receiverIsInstance: false)
        }

        // A STATIC call: the base is a Type reference (a leading-uppercase nominal,
        // possibly module-qualified `MyApp.PricingEngine`). The receiver is the Type.
        if base.is(DeclReferenceExprSyntax.self) || base.is(MemberAccessExprSyntax.self) {
            let leading = baseText.split(separator: ".").last.map(String.init) ?? baseText
            if leading.first?.isUppercase == true {
                return CallShape(kind: .freeOrStatic, receiver: baseText,
                                 function: function, receiverIsInstance: false)
            }
            // A lowercase base is an INSTANCE receiver (a local / property). Routable
            // only when that instance is a HANDLE (a prior routed reference) — but we
            // STILL describe the shape; the classifier/engine decides. The receiver
            // is the instance name; its canonical receiver TYPE is the local's type
            // when known.
            return CallShape(kind: .freeOrStatic, receiver: baseText,
                             function: function, receiverIsInstance: true)
        }
        // A complex receiver expression (`a.b().c.method()`): no clean nominal.
        return nil
    }

    /// Does an inferred type spelling look like an UNCONCRETIZED generic type
    /// parameter (`T`, `U`, `Element`, `Key`)? A bare single uppercase letter, or one
    /// of the conventional generic-param names, with no further structure. Used to
    /// set `isUnspecializedGeneric` (DESIGN §8.4 — no single native symbol to
    /// resolve). Conservative: a real one-letter TYPE (rare in app code) would also
    /// trip this, costing coverage, never soundness.
    static func looksLikeTypeParameter(_ type: String) -> Bool {
        let t = type.trimmingCharacters(in: .whitespaces)
        if t == unresolvedType { return false }
        if t.count == 1, let c = t.first, c.isUppercase, c.isLetter { return true }
        return ["Element", "Key", "Value", "Wrapped"].contains(t)
    }

    // =======================================================================
    // MARK: - ResolvedCall production for the ABI core (canonical signature)
    // =======================================================================

    /// Build the ABI core's `HostBridgeABI.ResolvedCall` from a call's shape + its
    /// inferred arg types/labels + return type. The ABI core's
    /// `canonicalSignature(_:)` consumes this to produce the content-addressed
    /// signature string (and the symbol id), following the SAME canonical rules the
    /// build-time resolver-thunk follows — so the engine's id and the on-device
    /// dispatch agree. Best-effort module qualification (see `canonicalReceiverSpelling`);
    /// the unresolved-type marker rides through verbatim and the classifier demotes it.
    public func resolvedCall(shape: CallShape,
                             args: [GeneralBridgeRewriter.Candidate.Arg],
                             labels: [String?],
                             returnType: String,
                             canonicalReceiverOverride: String? = nil) -> HostBridgeABI.ResolvedCall {
        // A known-symbol confident lookup may supply the module-qualified receiver
        // spelling directly (e.g. `Foundation.UserDefaults` for the `UserDefaults.standard`
        // instance receiver the syntax alone would key by the bare variable text).
        let receiverType: String? = canonicalReceiverOverride
            ?? (shape.receiver.isEmpty && shape.kind == .freeOrStatic
                ? nil                                  // a bare free function — no receiver
                : canonicalReceiverSpelling(shape: shape))
        let params: [HostBridgeABI.ResolvedCall.Param] = args.enumerated().map { i, a in
            HostBridgeABI.ResolvedCall.Param(
                label: i < labels.count ? labels[i] : nil,
                type: a.swiftType)
        }
        let ret: String? = (returnType.isEmpty || returnType == "Void" || returnType == "()")
            ? nil
            : returnType
        return HostBridgeABI.ResolvedCall(
            receiverType: receiverType, name: shape.function,
            params: params, returnType: ret)
    }

    // =======================================================================
    // MARK: - Canonical receiver spelling (best-effort module qualification)
    // =======================================================================

    /// The module-qualified receiver spelling for the canonical signature.
    /// An app-local nominal receiver is prefixed with `moduleName`; a curated-
    /// Foundation receiver uses its known canonical spelling; an already-qualified
    /// receiver keeps its prefix; an instance receiver uses its local TYPE when known
    /// (so `formatter.string(...)` qualifies as the formatter's type), else the bare
    /// receiver text. A bare free function is prefixed with `moduleName`.
    func canonicalReceiverSpelling(shape: CallShape) -> String {
        switch shape.kind {
        case .foundationStateless:
            return Self.foundationStatelessReceivers[shape.receiver]?.canonical ?? shape.receiver
        case .freeOrStatic:
            if shape.receiver.isEmpty { return moduleName }  // a bare free fn → module-prefixed
            // An instance receiver (a lowercase local): qualify by its KNOWN type so
            // the signature keys to the type, not the variable name. Unknown → the
            // bare receiver text (the unresolved-return marker still demotes it).
            if shape.receiverIsInstance {
                // (the walker threads the local's type into the context; but the shape
                // doesn't carry it — the engine layers the precise receiver type at
                // integration. From syntax we keep the instance name verbatim.)
                return shape.receiver
            }
            // An already module-qualified static receiver keeps its prefix; a bare
            // nominal gets the module prefix.
            if shape.receiver.contains(".") { return shape.receiver }
            return "\(moduleName).\(shape.receiver)"
        }
    }
}
