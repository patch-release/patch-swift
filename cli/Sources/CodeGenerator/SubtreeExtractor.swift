// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser
import PartitioningEngine

/// AGGRESSIVE sub-tree extraction (research/subtree-extraction prototype).
///
/// Where `FunctionSplitter` lifts top-level statement runs / a single best
/// sub-expression out of a `mixed` function, `SubtreeExtractor` pushes the
/// cutting edge per the project mandate: **the unit of OTA is the pure
/// computation, wherever it is buried.** It recursively walks an ENTIRE body —
/// every statement, every nested expression, and every closure literal passed to
/// `map`/`filter`/`reduce`/`sorted(by:)`/`sink`/UIKit callbacks — and extracts the
/// MAXIMAL pure sub-trees, regardless of the function's overall classification
/// (including functions the classifier marks `native`).
///
/// Each extracted sub-tree becomes a named WASM-eligible `PureFragment`; the
/// surrounding statement is rewritten into a thin native caller that binds the
/// fragment's result and substitutes it in place. The output is an ordinary
/// `SplitPlan`, so the existing `CodeEmitter` turns it into a compilable `.wasm`
/// + native bridge with no emitter changes.
///
/// ZERO FALSE NEGATIVES — a sub-tree is extractable ONLY if `PurityScanner`
/// proves it captures no `mustStayNative` symbol, no native callee, no
/// `self`/`super`, no `await`/`try`, no assignment/in-out, no key-path/macro, and
/// every free identifier it reads is an available, concretely-typed param/local
/// (so the lifted fragment compiles and never references a captured native value).
/// Anything we cannot positively prove pure & typed is left native.
public struct SubtreeExtractor {
    public let registry: NativeRegistry
    /// Simple names of callees that must stay native (forced-native / native
    /// helpers). Identical contract to `FunctionSplitter.nativeCalleeNames`.
    public let nativeCalleeNames: Set<String>
    /// Minimum syntactic size (character count of the trimmed expression) for a
    /// candidate to be worth lifting — avoids ABI noise from trivial `a + 1`.
    public let minLiftSize: Int
    /// DEEP MODE (wave2/subtree-deep). When `false`, the extractor reproduces the
    /// COMMITTED `cli/` behavior exactly (no typed-closure-param HOF hints, no
    /// per-interpolation-segment lifting) — used by the A/B driver as the baseline.
    /// When `true`, the deep extraction shapes are enabled.
    public let deep: Bool
    /// When `true` (deep only), a pure sub-tree whose inputs include a closure-local
    /// element param is shipped by substituting it with an INLINE `Patch.call(...)`
    /// expression inside the closure body (vs. a top-level bound temp it cannot use).
    /// This is what makes the map/filter/reduce/sorted predicate/transform lifts
    /// actually ship. Off ⇒ such lifts are reported but left native (measurement).
    public let closureLocalRewrite: Bool

    public init(registry: NativeRegistry = .standard,
                nativeCalleeNames: Set<String> = [],
                minLiftSize: Int = 6,
                deep: Bool = true,
                closureLocalRewrite: Bool = true) {
        self.registry = registry
        self.nativeCalleeNames = nativeCalleeNames
        self.minLiftSize = minLiftSize
        self.deep = deep
        self.closureLocalRewrite = closureLocalRewrite
    }

    /// One extracted maximal pure sub-tree, before SplitPlan assembly.
    public struct Extraction: Sendable, Equatable {
        /// Where the sub-tree lived (for reporting / dedupe).
        public let hostLine: Int
        /// The exact trimmed source text of the lifted sub-tree.
        public let exprText: String
        /// Concrete inferred result type (always non-`_`; ABI-eligible).
        public let resultType: String
        /// Free identifiers (params/locals) the sub-tree reads — fragment inputs.
        public let inputs: [String]
        /// Whether the sub-tree was found inside a closure literal body.
        public let insideClosure: Bool
        /// True iff this sub-tree was assembled into the emitted `SplitPlan` shell
        /// (its inputs are all in scope at the top-level statement, so the current
        /// `CodeEmitter` produces a sound `subExprCall`). A found-but-not-shippable
        /// extraction (e.g. a pure predicate over a closure-local element param) is
        /// still a real, provably-pure WASM-eligible sub-tree — it just needs the
        /// closure-local-rewrite emitter (FINDINGS § integration) to actually ship.
        public let shippableToday: Bool
    }

    public struct Result: Sendable {
        public let plan: SplitPlan?
        public let extractions: [Extraction]
        /// Count of distinct maximal pure sub-trees found.
        public var count: Int { extractions.count }
        /// Sub-trees that the current emitter can ship as-is (top-level-scoped).
        public var shippableCount: Int { extractions.filter { $0.shippableToday }.count }
    }

    public func extract(from record: FunctionRecord, source: String) -> Result {
        extract(from: record, tree: Parser.parse(source: source))
    }

    public func extract(from record: FunctionRecord, tree: SourceFileSyntax) -> Result {
        let index = DeclarationIndex(tree: tree)
        return extract(from: record, index: index, tree: tree)
    }

    /// Extract using a prebuilt per-file index (parse/index the file ONCE, reuse
    /// across all its records — the giant-app time budget pattern the realized
    /// pass already uses). `inferredTypes` are the resolver's per-function local
    /// types (`ResolvedProject.localTypes[record.id]`). `propertyIndex` (DEEP) maps
    /// each enclosing type's stored/computed property names to declared types, so a
    /// pure expression reading an ABI-typed `self` property (`!isEmpty`,
    /// `prices.filter{…}`, `discount * 100`) can be typed + lifted (the property is
    /// passed as a fragment input; the native shell supplies `self.<prop>`).
    public func extract(from record: FunctionRecord, index: DeclarationIndex,
                        tree: SourceFileSyntax,
                        inferredTypes: [String: String] = [:],
                        propertyIndex: TypePropertyIndex? = nil) -> Result {
        guard let decl = index.lookup(startLine: record.startLine,
                                      simpleName: simpleName(of: record)),
              let body = decl.foundBody else {
            return Result(plan: nil, extractions: [])
        }

        // Build the symbol-environment: declared param types + resolver-inferred
        // local types + locally-inferred local types, threaded to a fixpoint in
        // source order (same scheme as FunctionSplitter, so a local initialised
        // from an earlier local resolves concretely).
        let rawBase = simpleName(of: record).split(separator: "(").first.map(String.init)
            ?? simpleName(of: record)
        let base = sanitizeIdentifier(rawBase)
        var typeByName = Dictionary(decl.parameters.map { ($0.name, $0.type) },
                                    uniquingKeysWith: { a, _ in a })
        for (n, t) in inferredTypes where typeByName[n] == nil { typeByName[n] = t }
        // DEEP: seed the enclosing type's ABI-typed properties (only when deep, only
        // names a local/param does NOT shadow). Scoped to the record's enclosing
        // type so a same-named property on another type can't mis-type.
        // `seededProperties` records which names came from the property index (an
        // implicit-`self` read the shell supplies) so plan-assembly can guard the
        // SHADOWING case below (BUG R2-#45).
        var seededProperties: Set<String> = []
        if deep, let propertyIndex {
            let enclosing = enclosingTypeName(of: record)
            for (n, t) in propertyIndex.properties(of: enclosing) where typeByName[n] == nil {
                if SubtreeTypeInference.isABIType(t) { typeByName[n] = t; seededProperties.insert(n) }
            }
        }
        let statements = Array(body)
        var changed = true, rounds = 0
        while changed && rounds < statements.count + 1 {
            changed = false; rounds += 1
            for stmt in statements {
                for (n, t) in inferredLocalTypes(in: stmt, known: typeByName) where typeByName[n] == nil {
                    typeByName[n] = t; changed = true
                }
            }
        }

        // Walk the WHOLE body (recursing into nested closures), threading the set
        // of identifiers available at each point. Collect every maximal pure
        // sub-tree, then assemble fragments + a rewritten shell.
        let walker = MaximalSubtreeWalker(
            registry: registry, nativeCalleeNames: nativeCalleeNames,
            typeByName: typeByName, paramNames: Set(decl.parameters.map { $0.name }),
            minLiftSize: minLiftSize, deep: deep)
        walker.walk(body)

        guard !walker.found.isEmpty else { return Result(plan: nil, extractions: []) }

        // BUG R2-#45 — property/local SHADOW guard. A seeded property is fed to its
        // fragment as a BARE name (`Args(scale: scale)` — `CodeEmitter.fragmentCallLine`
        // passes inputs by bare name; for a property the shell relies on implicit
        // `self`). If a LOCAL of the SAME name is bound anywhere in the body, that
        // bare `scale` at the shell point resolves to the LOCAL, not `self.scale` —
        // feeding the fragment the WRONG value (or a compile error if the types
        // differ). Collect every local binding name so plan-assembly can DEMOTE any
        // candidate whose inputs include a property name shadowed by a local.
        let shadowedProperties: Set<String>
        if seededProperties.isEmpty {
            shadowedProperties = []
        } else {
            let lc = LocalBindingNameCollector()
            lc.walk(body)
            shadowedProperties = seededProperties.intersection(lc.names)
        }

        // Assemble a SplitPlan. We keep the WHOLE original body as native shell
        // statements but, per top-level statement, rewrite any contained extracted
        // sub-tree into a bound temp fed from the fragment. (Sub-trees inside
        // nested closures are reported but only rewritten when they sit in a
        // top-level statement substring we can uniquely substitute — corrupt
        // rewrites are never emitted.)
        var fragments: [SplitPlan.PureFragment] = []
        var shellSteps: [SplitPlan.ShellStep] = []
        var extractions: [Extraction] = []
        var liftIndex = 0

        // Group found candidates by the top-level statement they belong to.
        let stmtRanges = statements.map { $0.positionAfterSkippingLeadingTrivia ..< $0.endPosition }
        var byStmt: [Int: [MaximalSubtreeWalker.Found]] = [:]
        for f in walker.found {
            if let i = stmtRanges.firstIndex(where: { $0.contains(f.position) }) {
                byStmt[i, default: []].append(f)
            }
        }

        for (i, stmt) in statements.enumerated() {
            var text = stmt.trimmedDescription
            let cands = (byStmt[i] ?? []).sorted { $0.size > $1.size } // largest first
            var usedHere: [MaximalSubtreeWalker.Found] = []
            // Top-level lifts bind a temp BEFORE the statement; closure-local lifts
            // substitute an inline `Patch.call(...)` IN PLACE inside the statement.
            // We accumulate both into `text` and emit ONE final statement per host
            // statement (with leading `.fragmentCall` binds for the top-level ones) —
            // avoiding the duplicate-statement emission a per-candidate `subExprCall`
            // would produce for a multi-lift statement.
            var topLevelBinds: [SplitPlan.PureFragment] = []
            for cand in cands {
                // Skip a candidate fully contained in an already-lifted larger one.
                if usedHere.contains(where: { $0.exprText.contains(cand.exprText) && $0.exprText != cand.exprText }) {
                    continue
                }
                // SOUNDNESS: if any input resolved to no concrete ABI type, skip the
                // candidate entirely — never emit a generic `<T0>` fragment (it would
                // not compile / not ship). (Applies to both shippable + reported.)
                let inputs = cand.inputs.sorted().map {
                    (name: $0, type: cand.inputTypes[$0] ?? typeByName[$0] ?? "_")
                }
                guard inputs.allSatisfy({ $0.type != "_" && SubtreeTypeInference.isABIType($0.type) }) else { continue }

                // BUG R2-#45: a candidate whose inputs include a seeded property that
                // a body-local SHADOWS would have the bare-name shell arg (`Args(scale:
                // scale)`) resolve to the LOCAL, not `self.scale` — the wrong value.
                // Demote (keep native) rather than ship a wrong / non-compiling shell.
                if !shadowedProperties.isEmpty,
                   inputs.contains(where: { shadowedProperties.contains($0.name) }) {
                    continue
                }

                func reportOnly(_ shippable: Bool) {
                    extractions.append(Extraction(
                        hostLine: cand.line, exprText: cand.exprText, resultType: cand.resultType,
                        inputs: inputs.map { $0.name }, insideClosure: cand.insideClosure,
                        shippableToday: shippable))
                }

                // Unique-substring gate (never emit a corrupt rewrite).
                let occ = text.components(separatedBy: cand.exprText).count - 1
                guard occ == 1 else { reportOnly(false); continue }

                let label = cand.insideClosure ? "closure\(liftIndex)" : "subtree\(liftIndex)"
                liftIndex += 1
                let fragName = "_se_\(base)_\(label)"
                let boundName = "\(fragName)_v"
                let fragment = SplitPlan.PureFragment(
                    name: fragName, inputs: inputs,
                    outputs: [(name: boundName, type: cand.resultType)],
                    bodyStatements: ["return (\(cand.exprText))"])

                if cand.inputsAreTopLevel && !cand.conditionallyEvaluated {
                    // TOP-LEVEL SCOPE, UNCONDITIONAL: bind the fragment result before
                    // the statement, substitute the bound name in place (committed
                    // semantics). Safe to hoist the bind because the native code
                    // ALWAYS evaluates this position too.
                    fragments.append(fragment)
                    topLevelBinds.append(fragment)
                    text = text.replacingOccurrences(of: cand.exprText, with: boundName)
                    usedHere.append(cand)
                    reportOnly(true)
                } else if deep && closureLocalRewrite {
                    // (a) CLOSURE-LOCAL SCOPE (DEEP): an input is a closure-local
                    //     element param, out of scope at top level. Ship it by
                    //     substituting the pure sub-tree with an INLINE `Patch.call(...)`
                    //     expression — valid anywhere, including inside the closure body
                    //     where the element param IS in scope.
                    // (b) CONDITIONALLY-EVALUATED top-level sub-tree (BUG R2-#3/#16):
                    //     the SAME inline substitution is the SAFE path — it replaces
                    //     the sub-tree IN PLACE (inside the `&&`/`||` RHS or ternary
                    //     arm), so the `Patch.call` runs only when the native code
                    //     reaches that position. A `/0` / overflow stays short-circuited
                    //     exactly as in the original. (An unconditional top-level bind
                    //     would have run it always — that is the trap we refuse above.)
                    // No new emitter step: the rewritten statement is emitted verbatim
                    // and the fragment's `Args`/`Out` envelopes are generated because
                    // the fragment is in `pureFragments`.
                    let inlineCall = inlineFragmentCallExpr(sym: fragName, inputs: inputs, outName: boundName)
                    text = text.replacingOccurrences(of: cand.exprText, with: inlineCall)
                    fragments.append(fragment)
                    usedHere.append(cand)
                    reportOnly(true)
                } else {
                    // Closure-local input OR conditionally-evaluated, with the inline
                    // rewrite disabled — keep it native (demote-safe). Never take the
                    // unconditional top-level bind for a conditional sub-tree.
                    reportOnly(false)
                }
            }
            // Emit the per-statement steps: top-level fragment binds (pure WASM call
            // lines) followed by ONE rewritten statement carrying every substitution.
            if usedHere.isEmpty {
                shellSteps.append(.nativeStatement(stmt.trimmedDescription))
            } else {
                for f in topLevelBinds { shellSteps.append(.fragmentCall(fragment: f)) }
                shellSteps.append(.nativeStatement(text))
            }
        }

        // We may have found pure sub-trees that aren't shippable today (closure-local
        // inputs) — report them even with no emitted fragment, so the measurement
        // captures the FULL additional-pure-computation surface the mandate asks for.
        guard !extractions.isEmpty else { return Result(plan: nil, extractions: []) }
        guard !fragments.isEmpty else { return Result(plan: nil, extractions: extractions) }
        let plan = SplitPlan(
            originalID: record.id,
            originalSimpleName: simpleName(of: record),
            pureFragments: fragments,
            nativeSignature: decl.signatureText ?? simpleName(of: record),
            originalParameters: decl.parameters.map { (name: $0.name, type: $0.type) },
            returnType: decl.returnType, isAsync: decl.isAsync, isThrows: decl.isThrows,
            shellSteps: shellSteps)
        return Result(plan: plan, extractions: extractions)
    }

    // MARK: - helpers (mirrors FunctionSplitter's private ones)

    /// The inline `Patch.call(...)` EXPRESSION that the closure-local rewrite
    /// substitutes for a pure sub-tree. Must mirror `CodeEmitter.bridgeEnvelopes`
    /// (struct names `<sym>_Args`/`<sym>_Out`) and `CodeEmitter.fragmentCallLine`
    /// (the `Patch.call(name, Args(...), returning: Out.self)` shape) so it resolves
    /// against the emitter-generated envelopes. The single-output projection
    /// `.<outName>` yields the fragment's scalar result as a sub-expression valid
    /// anywhere the original sub-tree was — including inside the closure body where
    /// the element param is in scope.
    ///
    /// NOTE: `sym` here is the raw fragment name; the emitter sanitizes it via
    /// `sanitizedExportSymbol`. Our fragment names (`_se_<base>_<label>`) are already
    /// valid identifiers, so sanitization is the identity — we use the raw name to
    /// stay decoupled from `CodeEmitter`'s internals (the prototype need not import
    /// its private API). If a base ever sanitized non-trivially this would need the
    /// shared helper; flagged in the integration notes.
    /// Backtick-escape a reserved Swift keyword used in an identifier/label position,
    /// delegating to the single source of truth (`CodeEmitter.keywordSafeFieldName`,
    /// same module) so the inline rewrite's `Args(...)` labels/values match the
    /// emitter-generated escaped envelope fields exactly. A non-keyword name is
    /// returned unchanged.
    private func keywordSafeFieldName(_ name: String) -> String {
        CodeEmitter.keywordSafeFieldName(name)
    }

    private func inlineFragmentCallExpr(sym: String, inputs: [(name: String, type: String)],
                                        outName: String) -> String {
        let argsType = "\(sym)_Args"
        let outType = "\(sym)_Out"
        // BUG R4-#340: a keyword-named input (`default`, `where`, …) must be backtick-
        // escaped in BOTH the init LABEL and the VALUE position, matching the (escaped)
        // `Args` struct fields the emitter generates (CodeEmitter.bridgeEnvelopes via
        // keywordSafeFieldName) and CodeEmitter.fragmentCallLine. The value-position
        // bare keyword (`Args(default: default)`) is an unambiguous parse error
        // otherwise. (Replicates CodeEmitter.keywordSafeFieldName.)
        let argsInit = inputs.isEmpty
            ? "\(argsType)()"
            : "\(argsType)(" + inputs.map {
                "\(keywordSafeFieldName($0.name)): \(keywordSafeFieldName($0.name))"
              }.joined(separator: ", ") + ")"
        let safeOut = keywordSafeFieldName(outName)
        return "(Patch.call(\"\(sym)\", \(argsInit), returning: \(outType).self).\(safeOut))"
    }

    /// The enclosing type name of a record id `Module.Type.Nested.method(...)` —
    /// the component immediately before the trailing member signature. Best-effort:
    /// returns "" when the id has no type path (a free function).
    private func enclosingTypeName(of record: FunctionRecord) -> String {
        let parts = record.id.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return "" }
        // Drop the trailing member signature; the last remaining path component is
        // the enclosing type (computed-prop accessors append `.get` — already split
        // off as its own component, so the type is one further back).
        var idx = parts.count - 2
        if parts.count >= 3, parts[parts.count - 1] == "get" { idx = parts.count - 3 }
        return idx >= 0 ? parts[idx] : ""
    }

    private func simpleName(of record: FunctionRecord) -> String {
        record.id.split(separator: ".").last.map(String.init) ?? record.id
    }

    private func sanitizeIdentifier(_ s: String) -> String {
        let mapped = s.map { ch -> Character in (ch.isLetter || ch.isNumber || ch == "_") ? ch : "_" }
        let out = String(mapped)
        return out.isEmpty ? "frag" : out
    }

    private func inferredLocalTypes(in stmt: CodeBlockItemSyntax,
                                    known: [String: String]) -> [(String, String)] {
        guard let varDecl = stmt.item.as(DeclSyntax.self)?.as(VariableDeclSyntax.self) else { return [] }
        var out: [(String, String)] = []
        for binding in varDecl.bindings {
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            if let t = binding.typeAnnotation?.type.trimmedDescription { out.append((ident, t)); continue }
            guard let initExpr = binding.initializer?.value else { continue }
            if let t = SubtreeTypeInference.infer(initExpr, known: known) { out.append((ident, t)) }
        }
        return out
    }
}

/// Walks an entire body (recursing INTO closure literals) and records every
/// MAXIMAL pure sub-tree of inferable concrete type whose free identifiers are all
/// available, concretely-typed values. "Maximal" = we record the largest pure
/// node on each root-to-leaf path: when a node qualifies we record it and do NOT
/// descend (its pure children are subsumed); when it does not, we keep descending
/// to find smaller pure sub-trees inside it. This is what turns
/// `view.text = formatPrice(total * (1 - rate))` into one lift of the whole pure
/// `formatPrice(total * (1 - rate))` argument rather than a fistful of fragments.
final class MaximalSubtreeWalker: SyntaxVisitor {
    struct Found: Equatable {
        let position: AbsolutePosition
        let line: Int
        let exprText: String
        let resultType: String
        let inputs: Set<String>
        /// The resolved concrete type of each input, captured from the walker's
        /// THREADED type env at the lift site (a closure param / nested local may be
        /// typed here but absent from the top-level map). The extractor uses THIS so
        /// the emitted fragment input types are never silently `_` (which would leak
        /// a generic, non-compiling `<T0>` fragment).
        let inputTypes: [String: String]
        let size: Int
        let insideClosure: Bool
        /// True iff EVERY free identifier the sub-tree reads is in scope at the
        /// enclosing TOP-LEVEL statement (a function param / top-level local) —
        /// i.e. none is a closure-local parameter or a closure-internal local.
        /// Only such lifts can be assembled into a `subExprCall` shell step with the
        /// CURRENT emitter, which binds the fragment result at top-level statement
        /// scope and re-references the inputs there. A lift over a closure-local
        /// element param IS a provably-pure sub-tree (counted in `found`), but
        /// shipping it requires a closure-local-rewrite emitter (see FINDINGS §
        /// integration) — so the plan-assembly gates on this flag to keep the
        /// emitted shell sound today.
        let inputsAreTopLevel: Bool
        /// True iff the sub-tree sits in a position the native code may SKIP at
        /// runtime — the RHS of a short-circuiting `&&`/`||`, or a ternary
        /// then/else arm (folded `TernaryExprSyntax` OR unfolded
        /// `SequenceExpr` + `UnresolvedTernaryExprSyntax`). The unconditional
        /// top-level-bind path (`let _v = Patch.call(...)` BEFORE the statement)
        /// would then EVALUATE it ALWAYS — a `count / divisor` guarded by
        /// `divisor != 0 && …`, or a `b != 0 ? a / b : 0`, would TRAP (div-by-zero
        /// / overflow) where the native code short-circuited past it. Plan-assembly
        /// therefore REFUSES the top-level bind for such a candidate (mirrors
        /// `FunctionSplitter`/`LiftableSubExprCollector.isConditionallyEvaluated`).
        /// The closure-local INLINE-`Patch.call` rewrite substitutes IN PLACE, so
        /// it preserves the conditionality and stays safe. See BUG R2-#3 / R2-#16.
        let conditionallyEvaluated: Bool
    }

    let registry: NativeRegistry
    let nativeCalleeNames: Set<String>
    let typeByName: [String: String]
    let paramNames: Set<String>
    let minLiftSize: Int
    /// Enable the wave2/subtree-deep extraction shapes (HOF element-type closure
    /// param hints, per-interpolation-segment lifting). `false` ⇒ committed behavior.
    let deep: Bool
    private(set) var found: [Found] = []

    /// Identifiers available at the current point: params + locals bound so far +
    /// closure parameters of any enclosing closure. Threaded as we descend.
    private var available: Set<String>
    /// Concrete types known at the current point (extends `typeByName` with
    /// closure params we can type and locals bound inside closures).
    private var typeEnv: [String: String]
    private var closureDepth = 0
    /// DEEP: when the NEXT closure we descend into is the predicate/transform of a
    /// known higher-order collection method (`map`/`filter`/`first(where:)`/…), the
    /// concrete ABI element type(s) of its positional parameter(s). Set by the
    /// enclosing `FunctionCallExpr` visit just before it walks the closure, consumed
    /// (and cleared) by the closure visit. This is what lets a pure predicate over a
    /// named element param lift even when the receiver pipeline (`results.compactMap`,
    /// a native `self.items`) is itself native — the closure BODY is pure over a
    /// concretely ABI-typed element. nil ⇒ closure params stay untyped (never lift),
    /// exactly as the committed extractor.
    ///
    /// The array gives the element type for each positional param the method passes:
    ///   - single-element HOFs (`map`/`filter`/`first`/…): `[T]`
    ///   - pairwise HOFs (`sorted(by:)`/`min(by:)`/`max(by:)`): `[T, T]`
    ///   - `reduce(_:_:)`: `[nil, T]` — only the *element* (2nd) param is typed; the
    ///     accumulator (1st) is left untyped (its type is the result, not generally
    ///     inferable), so only sub-trees over the element alone lift.
    private var pendingClosureParamTypes: [String?]?
    /// Names bound by an ENCLOSING closure (closure params + locals declared inside a
    /// closure body) — i.e. names NOT in scope at the top-level statement. Used to
    /// mark a lift's inputs as top-level-scoped (ship-safe today) or not.
    private var closureBoundNames: Set<String> = []

    init(registry: NativeRegistry, nativeCalleeNames: Set<String>,
         typeByName: [String: String], paramNames: Set<String>, minLiftSize: Int,
         deep: Bool) {
        self.registry = registry
        self.nativeCalleeNames = nativeCalleeNames
        self.typeByName = typeByName
        self.paramNames = paramNames
        self.minLiftSize = minLiftSize
        self.deep = deep
        self.available = paramNames
        // Seed available with every name we have a type for (locals/params the
        // resolver typed) — sound because a lift still requires the name be read
        // only where the value exists, and the per-statement thread below adds
        // locals in order. We start permissive on type knowledge but gate on
        // purity + concrete typing, which is the real safety boundary.
        self.available.formUnion(typeByName.keys)
        self.typeEnv = typeByName
        super.init(viewMode: .sourceAccurate)
    }

    // Consider an expression as a maximal-lift candidate. Returns true if it was
    // recorded (caller should NOT descend further into it). `anchor` overrides the
    // recorded position for synthetic nodes (an assignment-RHS sub-sequence built
    // from detached elements has no meaningful tree position of its own; we anchor
    // it to a real node inside the host statement so plan assembly finds it).
    @discardableResult
    private func consider(_ expr: ExprSyntax, anchor: AbsolutePosition? = nil) -> Bool {
        let trimmed = expr.trimmedDescription
        guard trimmed.count >= minLiftSize else { return false }
        guard isNonTrivial(expr) else { return false }
        guard let type = SubtreeTypeInference.infer(expr, known: typeEnv),
              SubtreeTypeInference.isABIType(type) else { return false }
        let scanner = PurityScanner(registry: registry, nativeCalleeNames: nativeCalleeNames)
        scanner.walk(expr)
        guard scanner.isPure else { return false }
        // Every free identifier must be an available, concretely-typed value.
        let free = scanner.identifiers
        guard free.isSubset(of: available) else { return false }
        guard free.allSatisfy({ typeEnv[$0] != nil && SubtreeTypeInference.isABIType(typeEnv[$0]!) }) else {
            return false
        }
        var inputTypes: [String: String] = [:]
        for n in free { inputTypes[n] = typeEnv[n] }   // resolved at the lift site
        // A lift is ship-safe with TODAY's emitter only if none of its inputs is a
        // closure-local name (which would be out of scope at the top-level shell
        // rewrite point). Lifts over outer captures / top-level locals stay safe.
        let inputsAreTopLevel = free.isDisjoint(with: closureBoundNames)
        // SOUNDNESS (BUG R2-#3 / R2-#16): a sub-tree natively evaluated only
        // CONDITIONALLY (short-circuit `&&`/`||` RHS, ternary arm) must NOT be
        // hoisted to the unconditional top-level bind — that would run it always,
        // trapping where the native code short-circuited past a `/0` / overflow.
        let condEval = isConditionallyEvaluated(expr)
        found.append(Found(
            position: anchor ?? expr.positionAfterSkippingLeadingTrivia,
            line: 0, exprText: trimmed, resultType: type, inputs: free, inputTypes: inputTypes,
            size: expr.description.count, insideClosure: closureDepth > 0,
            inputsAreTopLevel: inputsAreTopLevel, conditionallyEvaluated: condEval))
        return true
    }

    /// True iff `expr` sits in a position the native statement may SKIP at runtime,
    /// so hoisting it to an UNCONDITIONAL fragment bind would change evaluation
    /// order (and can TRAP where the native code short-circuited past it). Mirrors
    /// `FunctionSplitter.LiftableSubExprCollector.isConditionallyEvaluated`: walks
    /// the ancestor chain looking for
    ///   * the RHS of a short-circuiting `&&` / `||` (an operand positioned AFTER a
    ///     `&&`/`||` operator token inside an enclosing `SequenceExpr`),
    ///   * a FOLDED ternary's then/else arm (`TernaryExprSyntax`), and
    ///   * an UNFOLDED ternary's then/else arm (`UnresolvedTernaryExprSyntax`, or a
    ///     `SequenceExpr` element positioned after one).
    /// Conservative: ANY such enclosing context (no matter how deep) returns true.
    private func isConditionallyEvaluated(_ expr: ExprSyntax) -> Bool {
        var child = Syntax(expr)
        var node = Syntax(expr)
        while let parent = node.parent {
            // FOLDED ternary `cond ? then : else`: the then/else sub-trees are
            // conditionally evaluated (the condition is not).
            if let ternary = parent.as(TernaryExprSyntax.self) {
                if node.id == Syntax(ternary.thenExpression).id
                    || node.id == Syntax(ternary.elseExpression).id {
                    return true
                }
            }
            // UNFOLDED ternary: `cond ? then : else` parses as a `SequenceExpr`
            // `[cond, UnresolvedTernaryExprSyntax(? then :), else]`. Anything INSIDE
            // the `? then :` middle is the then-arm (conditional).
            if parent.is(UnresolvedTernaryExprSyntax.self) {
                return true
            }
            if let seq = parent.as(SequenceExprSyntax.self) {
                let elements = Array(seq.elements)
                if let myIndex = elements.firstIndex(where: { $0.id == child.id }) {
                    for i in 0..<myIndex {
                        // Short-circuit operand: positioned AFTER a `&&`/`||` operator.
                        if let op = elements[i].as(BinaryOperatorExprSyntax.self)?.operator.text,
                           op == "&&" || op == "||" {
                            return true
                        }
                        // Ternary else-arm: positioned AFTER an unfolded `? then :`.
                        if elements[i].is(UnresolvedTernaryExprSyntax.self) {
                            return true
                        }
                    }
                }
            }
            child = node
            node = parent
        }
        return false
    }

    /// A node worth lifting: an operation/transform, not a bare value/member/literal.
    private func isNonTrivial(_ expr: ExprSyntax) -> Bool {
        if expr.is(DeclReferenceExprSyntax.self) || expr.is(IntegerLiteralExprSyntax.self)
            || expr.is(FloatLiteralExprSyntax.self) || expr.is(BooleanLiteralExprSyntax.self)
            || expr.is(NilLiteralExprSyntax.self) || expr.is(MemberAccessExprSyntax.self) {
            return false
        }
        // A plain string literal with no interpolation is a constant — not worth a
        // round-trip. (Interpolated strings ARE worth it: they compute.)
        if let str = expr.as(StringLiteralExprSyntax.self) {
            return str.segments.contains { $0.is(ExpressionSegmentSyntax.self) }
        }
        return true
    }

    // The "maximal" visitor hooks: at each expression node, try to record it; if
    // recorded, skip its children (subsumed). Otherwise visit children.
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        // An assignment (`lhs = rhs`) flattens into ONE SequenceExpr in SwiftSyntax
        // (`[lhs, =, a, *, b]`), so the pure RHS is not a distinct node to lift. If
        // the sequence is exactly `lhs = <rhs>`, fold the trailing RHS elements into
        // a synthetic SequenceExpr and try to lift THAT — this recovers
        // `view.tag = a * b - c` (lift the whole `a * b - c`, native assignment in
        // the shell). The assignment itself is never lifted (impure).
        let els = Array(node.elements)
        if let assignIdx = els.firstIndex(where: { $0.is(AssignmentExprSyntax.self) }),
           assignIdx + 1 < els.count {
            let rhsElems = Array(els[(assignIdx + 1)...])
            let anchor = rhsElems[0].positionAfterSkippingLeadingTrivia
            if rhsElems.count == 1 {
                // Single RHS expression — consider it directly, then visit its
                // children if it wasn't liftable whole.
                let rhs = rhsElems[0]
                if consider(rhs) { return .skipChildren }
                walk(rhs)
                for e in els[..<assignIdx] { walk(e) }
                return .skipChildren
            }
            // Multi-element RHS: fold into a synthetic SequenceExpr (with normalised
            // trivia so its trimmed text matches the substring in the host
            // statement) and lift the whole pure RHS, anchored to its first element.
            let normalised = rhsElems.enumerated().map { i, e in
                i == 0 ? e.with(\.leadingTrivia, []) : e
            }
            let synthetic = SequenceExprSyntax(elements: ExprListSyntax(normalised))
            if consider(ExprSyntax(synthetic), anchor: anchor) { return .skipChildren }
            return .visitChildren
        }
        return consider(ExprSyntax(node)) ? .skipChildren : .visitChildren
    }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Try the whole call as a lift (a pure transform like `formatPrice(x*y)`).
        if consider(ExprSyntax(node)) { return .skipChildren }
        // DEEP: a higher-order collection method `recv.<hof> { $0 ... }` whose
        // receiver has a concrete ABI element type `T` — type the trailing
        // closure's single positional parameter `T` so a PURE predicate/transform
        // over the element lifts, even when `recv` (and the surrounding statement)
        // is native. We compute the hint here and walk the children manually so the
        // closure visit can consume it for exactly the trailing closure of THIS call
        // (not a nested unrelated closure). Everything else descends normally.
        if let hint = closureElementTypeHint(node) {
            let savedHint = pendingClosureParamTypes
            // Walk the callee + arguments normally (no hint), then the trailing
            // closure WITH the hint armed.
            walk(node.calledExpression)
            for arg in node.arguments { walk(arg) }
            if let tc = node.trailingClosure {
                pendingClosureParamTypes = hint
                walk(tc)
                pendingClosureParamTypes = savedHint
            }
            for ac in node.additionalTrailingClosures { walk(ac) }
            return .skipChildren
        }
        // Not liftable whole — but its ARGUMENTS may contain pure sub-trees worth
        // lifting (compute in WASM, pass to the native shell). Keep descending.
        return .visitChildren
    }

    /// If `node` is `receiver.<hof>(...) { … }` where `<hof>` is an element-wise
    /// higher-order method, and the receiver's element type is a concrete ABI
    /// scalar/array, return the per-positional-param element types for the trailing
    /// closure. Otherwise nil.
    ///
    /// SOUNDNESS: the method must be in the closed allow-list (each entry's closure
    /// arity is known), and the receiver's element type must resolve to a confident
    /// ABI type — never guessed. A wrong element type can at worst mis-type a closure
    /// param, which the lift gate then rejects (the body would fail to type-check) —
    /// but we keep it tight anyway.
    private func closureElementTypeHint(_ node: FunctionCallExprSyntax) -> [String?]? {
        guard deep else { return nil }                      // committed mode: off
        guard node.trailingClosure != nil else { return nil }
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return nil }
        let method = member.declName.baseName.text
        // Closure receives ONE element.
        let singleElementHOFs: Set<String> = [
            "map", "compactMap", "flatMap", "filter", "first", "last",
            "contains", "allSatisfy", "drop", "prefix", "firstIndex", "lastIndex",
            "forEach", "partition",
        ]
        // Closure receives TWO elements (a comparator).
        let pairwiseHOFs: Set<String> = ["sorted", "min", "max"]
        guard let base = member.base else { return nil }
        guard let recvType = SubtreeTypeInference.infer(base, known: typeEnv) else { return nil }
        let tt = recvType.trimmingCharacters(in: .whitespaces)
        guard tt.hasPrefix("["), tt.hasSuffix("]") else { return nil }
        let inner = String(tt.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard SubtreeTypeInference.abiScalars.contains(inner) else { return nil }
        if singleElementHOFs.contains(method) { return [inner] }
        if pairwiseHOFs.contains(method) { return [inner, inner] }
        if method == "reduce" {
            // `reduce(initial) { acc, element in … }` — only the 2nd param (the
            // element) is concretely typed; the accumulator type is the result type,
            // not generally inferable here, so leave it untyped.
            return [nil, inner]
        }
        return nil
    }
    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        consider(ExprSyntax(node)) ? .skipChildren : .visitChildren
    }
    override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        consider(ExprSyntax(node)) ? .skipChildren : .visitChildren
    }
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        // Whole interpolated string liftable? (Every segment ABI-typed.) Take it.
        if consider(ExprSyntax(node)) { return .skipChildren }
        // Committed mode: descend into children (default walk) exactly as before.
        guard deep else { return .visitChildren }
        // DEEP: the WHOLE string is native (a segment reads `self`/a native member,
        // or is non-ABI), but an INDIVIDUAL `\(expr)` segment may itself be a pure,
        // ABI-typed computation worth lifting (compute the value in WASM, leave the
        // native interpolation in the shell with the bound result substituted). Visit
        // each interpolation's expression as a lift candidate. `consider` enforces
        // non-triviality, so a bare `\(name)` / `\(self.x)` segment is never lifted —
        // only computing segments like `\(price * qty)` or `\(a.uppercased())`.
        for seg in node.segments {
            if let e = seg.as(ExpressionSegmentSyntax.self) {
                for arg in e.expressions { walk(arg.expression) }
            }
        }
        return .skipChildren
    }
    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        consider(ExprSyntax(node)) ? .skipChildren : .visitChildren
    }
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        consider(ExprSyntax(node)) ? .skipChildren : .visitChildren
    }

    // Thread a local binding's name + inferred type as we pass it (source order).
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            available.insert(name)
            // A local declared INSIDE a closure body is closure-scoped (not in scope
            // at the top-level shell rewrite point) → mark it so a lift reading it is
            // flagged not-top-level (correctly gated out of today's shell assembly).
            if closureDepth > 0 { closureBoundNames.insert(name) }
            if let t = binding.typeAnnotation?.type.trimmedDescription { typeEnv[name] = t }
            else if let initE = binding.initializer?.value, let t = SubtreeTypeInference.infer(initE, known: typeEnv) {
                typeEnv[name] = t
            }
        }
        return .visitChildren
    }

    // Recurse INTO closure literals — the mandate's "closure body / sub-parts of
    // closures passed to map/filter/reduce/sink" requirement. The closure's
    // parameters become available (typed `_` unless annotated → not concretely
    // typed, so a sub-tree depending on them stays native; but sub-trees over
    // captured concretely-typed outer locals/params still lift). `$0`/`$1` are
    // never concretely typed, so they never qualify (safe).
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        closureDepth += 1
        let savedAvail = available
        let savedTypes = typeEnv
        let savedClosureBound = closureBoundNames
        // Consume any element-type hint armed by the enclosing HOF call — it applies
        // to THIS closure's positional parameters only. Cleared immediately so a
        // NESTED closure inside the body does not inherit it (its params are
        // different values). A nil hint (or nil per-param entry) leaves that param
        // untyped, as before.
        let elementHints = pendingClosureParamTypes
        pendingClosureParamTypes = nil
        if let sig = node.signature, let clause = sig.parameterClause {
            if let typed = clause.as(ClosureParameterClauseSyntax.self) {
                let params = Array(typed.parameters)
                for (i, p) in params.enumerated() {
                    let n = (p.secondName ?? p.firstName).text
                    available.insert(n)
                    closureBoundNames.insert(n)        // closure-local scope
                    if let t = p.type?.trimmedDescription { typeEnv[n] = t }
                    // Apply the element hint ONLY to an UNTYPED, legally-named param.
                    else if let hints = elementHints, i < hints.count,
                            let hint = hints[i], !n.hasPrefix("$") {
                        typeEnv[n] = hint
                    }
                }
            } else if let shorthand = clause.as(ClosureShorthandParameterListSyntax.self) {
                // A `{ p, q in … }` shorthand list: the names ARE legal identifiers
                // (unlike implicit `$0`), so we DO type them from the element hint.
                // SOUNDNESS: a `$0`-shaped name would become a fragment INPUT named
                // `$0` — not a legal identifier in the emitted ABI wrapper — so any
                // `$`-prefixed name is never typed (stays untyped → never lifts).
                let params = Array(shorthand)
                for (i, p) in params.enumerated() {
                    let n = p.name.text
                    available.insert(n); closureBoundNames.insert(n)
                    if let hints = elementHints, i < hints.count,
                       let hint = hints[i], !n.hasPrefix("$") {
                        typeEnv[n] = hint
                    }
                }
            }
        }
        // NOTE: a signature-less `{ $0 ... }` closure also reaches here with no
        // param clause. We deliberately do NOT type `$0` (see soundness note above):
        // a `$0` fragment input is not a legal identifier. Named params only.
        // Manually walk the closure body so bindings thread correctly, then
        // restore the outer scope. (We return skipChildren to avoid a double walk.)
        for item in node.statements { walk(item) }
        available = savedAvail
        typeEnv = savedTypes
        closureBoundNames = savedClosureBound
        closureDepth -= 1
        return .skipChildren
    }
}

/// Collects every LOCAL binding name introduced anywhere in a function body — the
/// `let`/`var` binding identifiers AND closure parameter names. Used by the
/// property/local SHADOW guard (BUG R2-#45): a seeded property fed to a fragment
/// by bare name is unsound if a body-local of the same name shadows it.
final class LocalBindingNameCollector: SwiftSyntax.SyntaxVisitor {
    private(set) var names: Set<String> = []
    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            collectPatternNames(binding.pattern)
        }
        return .visitChildren
    }

    // Optional/`case`/`if let` bindings introduce locals too.
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        collectPatternNames(node.pattern)
        return .visitChildren
    }

    // Closure parameters (named + shorthand) are body-locals for the shadow check.
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        if let sig = node.signature, let clause = sig.parameterClause {
            if let typed = clause.as(ClosureParameterClauseSyntax.self) {
                for p in typed.parameters { names.insert((p.secondName ?? p.firstName).text) }
            } else if let shorthand = clause.as(ClosureShorthandParameterListSyntax.self) {
                for p in shorthand { names.insert(p.name.text) }
            }
        }
        return .visitChildren
    }

    private func collectPatternNames(_ pattern: PatternSyntax) {
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            names.insert(ident.identifier.text)
        } else if let tuple = pattern.as(TuplePatternSyntax.self) {
            for el in tuple.elements { collectPatternNames(el.pattern) }
        } else if let bound = pattern.as(ValueBindingPatternSyntax.self) {
            collectPatternNames(bound.pattern)
        }
    }
}

/// DEEP (wave2/subtree-deep): a per-file index of each declared type's
/// stored/computed property names → declared types. Built once per file (reused
/// across all its records, like `DeclarationIndex`). Lets the extractor type an
/// ABI-typed `self` property read inside a `native`/`mixed` body so a pure
/// expression over it (`!isEmpty`, `discount * 100`, `prices.filter { … }`) is
/// liftable — the property becomes a fragment input that the native shell supplies
/// from `self.<prop>` (a value read, identical semantics to the original).
///
/// SAFETY: only properties with an EXPLICIT declared type are recorded (no
/// guessing). The extractor additionally re-checks `isABIType` before seeding, and
/// the universal lift gate still requires purity + a confident ABI result type — so
/// a recorded property can only ever ADD a provable lift, never weaken any gate.
/// Nested-type ambiguity is avoided by keying on the simple type name and only
/// seeding when the record's enclosing type matches.
public struct TypePropertyIndex: Sendable {
    /// type simple-name → (property name → declared type).
    private let byType: [String: [String: String]]

    public init(tree: SourceFileSyntax) {
        let collector = PropertyTypeCollector()
        collector.walk(tree)
        self.byType = collector.byType
    }

    public func properties(of type: String) -> [String: String] {
        byType[type] ?? [:]
    }
}

/// Walks a file collecting each nominal type's explicitly-typed stored/computed
/// properties. Only declared-type bindings are kept (no inferred-init guessing) so
/// the recorded types are exact. `static`/`class` and `let`/`var` are all included
/// (a static read is still a pure value the shell can pass), but only when the
/// binding carries an explicit `: Type` annotation.
final class PropertyTypeCollector: SyntaxVisitor {
    private(set) var byType: [String: [String: String]] = [:]
    private var typeStack: [String] = []
    /// Depth of function/closure nesting — properties are only collected at type
    /// member scope (funcDepth == 0), never locals inside a method body.
    private var funcDepth = 0

    init() { super.init(viewMode: .sourceAccurate) }

    private func pushType(_ n: String) { typeStack.append(n) }
    override func visit(_ n: StructDeclSyntax) -> SyntaxVisitorContinueKind { pushType(n.name.text); return .visitChildren }
    override func visitPost(_ n: StructDeclSyntax) { typeStack.removeLast() }
    override func visit(_ n: ClassDeclSyntax) -> SyntaxVisitorContinueKind { pushType(n.name.text); return .visitChildren }
    override func visitPost(_ n: ClassDeclSyntax) { typeStack.removeLast() }
    override func visit(_ n: EnumDeclSyntax) -> SyntaxVisitorContinueKind { pushType(n.name.text); return .visitChildren }
    override func visitPost(_ n: EnumDeclSyntax) { typeStack.removeLast() }
    override func visit(_ n: ActorDeclSyntax) -> SyntaxVisitorContinueKind { pushType(n.name.text); return .visitChildren }
    override func visitPost(_ n: ActorDeclSyntax) { typeStack.removeLast() }
    override func visit(_ n: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(SymbolTable.leadingNominal(n.extendedType.trimmedDescription) ?? n.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ n: ExtensionDeclSyntax) { typeStack.removeLast() }

    override func visit(_ n: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { funcDepth += 1; return .visitChildren }
    override func visitPost(_ n: FunctionDeclSyntax) { funcDepth -= 1 }
    override func visit(_ n: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { funcDepth += 1; return .visitChildren }
    override func visitPost(_ n: InitializerDeclSyntax) { funcDepth -= 1 }
    override func visit(_ n: ClosureExprSyntax) -> SyntaxVisitorContinueKind { funcDepth += 1; return .visitChildren }
    override func visitPost(_ n: ClosureExprSyntax) { funcDepth -= 1 }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Only type-member properties (not locals inside a body).
        guard funcDepth == 0, let type = typeStack.last else { return .visitChildren }
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let declared = binding.typeAnnotation?.type.trimmedDescription else { continue }
            byType[type, default: [:]][name] = declared
        }
        return .visitChildren
    }
}

/// Broadened best-effort concrete type inference for the maximal-subtree walker.
/// A superset of `FunctionSplitter`'s private inference: literals, parenthesised,
/// `!x`, comparisons/boolean → Bool, arithmetic → numeric/String of a typed
/// operand, `.count`/`.isEmpty`, interpolated strings, `Type(...)` constructors,
/// ternaries, switch/if expressions, and string-returning stdlib members. Returns
/// nil unless confident — never a guess (a nil keeps the sub-tree native).
enum SubtreeTypeInference {
    /// Scalar/string/Codable-collection types we can round-trip across the JSON ABI.
    static let abiScalars: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16",
        "UInt32", "UInt64", "Double", "Float", "CGFloat", "Decimal", "TimeInterval",
        "Bool", "String",
    ]
    static func isABIType(_ t: String) -> Bool {
        let tt = t.trimmingCharacters(in: .whitespaces)
        if abiScalars.contains(tt) { return true }
        // OPTIONAL of an ABI scalar (`String?`): Codable round-trips `Optional<T>`,
        // so a `flag ? "x" : nil` fragment ships as a `-> String?` export. (No `[T]?`
        // / nested optional — keep the surface to the proven scalar-optional shape.)
        if tt.hasSuffix("?") {
            let inner = String(tt.dropLast()).trimmingCharacters(in: .whitespaces)
            return abiScalars.contains(inner)
        }
        // Homogeneous scalar array `[T]`.
        if tt.hasPrefix("["), tt.hasSuffix("]") {
            let inner = String(tt.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            return abiScalars.contains(inner)
        }
        return false
    }

    /// The Optional spelling of an ABI scalar (`String` → `String?`). Used when one
    /// ternary/if arm is a bare `nil` literal.
    static func optionalOf(_ t: String) -> String { "\(t)?" }

    /// True iff `expr` is a bare `nil` literal (so a ternary arm is `nil`, making the
    /// value type Optional). A parenthesized `(nil)` counts; anything else does not.
    static func isNilLiteral(_ expr: ExprSyntax) -> Bool {
        if expr.is(NilLiteralExprSyntax.self) { return true }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression { return isNilLiteral(inner) }
        return false
    }

    static func infer(_ expr: ExprSyntax, known: [String: String]) -> String? {
        if expr.is(IntegerLiteralExprSyntax.self) { return "Int" }
        if expr.is(FloatLiteralExprSyntax.self) { return "Double" }
        if expr.is(BooleanLiteralExprSyntax.self) { return "Bool" }
        if let str = expr.as(StringLiteralExprSyntax.self) {
            // SOUNDNESS: an interpolated string is only `String` if EVERY
            // interpolation `\(e)` is itself a confidently ABI-typed value. A
            // segment of unknown type (e.g. `\(error.localizedDescription)` where
            // `error` was mistyped, or a non-ABI value) means the lifted fragment
            // may reference a member that does not exist on the inferred type and
            // would not compile — bail. A plain (non-interpolated) literal is String.
            // (Caught a real false-positive on IceCubesApp.)
            for seg in str.segments {
                if let e = seg.as(ExpressionSegmentSyntax.self) {
                    for arg in e.expressions {
                        guard let t = infer(arg.expression, known: known), isABIType(t) else { return nil }
                    }
                }
            }
            return "String"
        }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression { return infer(inner, known: known) }
        if let ref = expr.as(DeclReferenceExprSyntax.self) { return known[ref.baseName.text] }
        if let force = expr.as(ForceUnwrapExprSyntax.self) { return infer(force.expression, known: known) }
        if let pre = expr.as(PrefixOperatorExprSyntax.self), pre.operator.text == "!" { return "Bool" }
        if let pre = expr.as(PrefixOperatorExprSyntax.self), pre.operator.text == "-" {
            return infer(pre.expression, known: known)
        }
        if let seq = expr.as(SequenceExprSyntax.self) { return inferSeq(seq, known: known) }
        if let arr = expr.as(ArrayExprSyntax.self), !arr.elements.isEmpty {
            var elem: String?
            for el in arr.elements {
                guard let t = infer(el.expression, known: known), abiScalars.contains(t) else { return nil }
                if let e = elem { if e != t { return nil } } else { elem = t }
            }
            if let elem { return "[\(elem)]" }
        }
        if let call = expr.as(FunctionCallExprSyntax.self) { return inferCall(call, known: known) }
        if let member = expr.as(MemberAccessExprSyntax.self) { return inferMember(member, known: known) }
        if let tern = expr.as(TernaryExprSyntax.self) {
            let a = infer(tern.thenExpression, known: known)
            let b = infer(tern.elseExpression, known: known)
            if let a, a == b { return a }
            // NIL-literal arm → the value type is OPTIONAL of the other arm's scalar.
            // `flag ? "x" : nil` is `String?`, NOT `String` — typing it `String`
            // emitted `return (… ? "x" : nil)` into a `-> String` fragment that
            // FAILED to compile and demoted (the real ScheduleService.runAnalysis
            // `message: scrapeFailed ? "scrape_unavailable" : nil` bug). `T?` is
            // Codable and round-trips the JSON ABI, so the fragment ships.
            if let a, isNilLiteral(tern.elseExpression), abiScalars.contains(a) { return optionalOf(a) }
            if let b, isNilLiteral(tern.thenExpression), abiScalars.contains(b) { return optionalOf(b) }
            // A branch whose type is merely UNKNOWN (not a `nil` literal) is NOT a
            // safe basis to assume the other arm's type — bail rather than guess
            // (a differently-typed arm that just failed inference would mis-type the
            // fragment). Demote-safe: the whole expression stays native.
        }
        if let sw = expr.as(SwitchExprSyntax.self) { return inferBranches(switchArms(sw), known: known) }
        if let ifE = expr.as(IfExprSyntax.self) { return inferBranches(ifArms(ifE), known: known) }
        return nil
    }

    private static func inferSeq(_ seq: SequenceExprSyntax, known: [String: String]) -> String? {
        // SOUNDNESS: an UNFOLDED ternary `a == b ? c : d` parses as a SequenceExpr
        // `[a, ==, b, UnresolvedTernaryExpr(c), d]`. The `==` here belongs to the
        // ternary CONDITION, not the expression's value — typing the whole thing
        // `Bool` off the comparison is WRONG (the value type is the arms'). If the
        // sequence contains an UnresolvedTernaryExpr, type it as a ternary: the
        // common concrete type of the then-arm (inside the unresolved node) and the
        // else-arm (the element after it). Bail (nil) unless both agree on an ABI
        // scalar — never guess. (Caught a real false-positive on MovieSwiftUI:
        // `movieId == 0 ? .placeholder : []` was mistyped Bool but is `[Movie]`.)
        let els = Array(seq.elements)
        if let tIdx = els.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }) {
            guard let ut = els[tIdx].as(UnresolvedTernaryExprSyntax.self) else { return nil }
            let thenExpr = ut.thenExpression
            let elseExpr: ExprSyntax? = (tIdx + 1 < els.count) ? els[tIdx + 1] : nil
            let thenT = infer(thenExpr, known: known)
            let elseT = elseExpr.flatMap { infer($0, known: known) }
            if let thenT, thenT == elseT, abiScalars.contains(thenT) { return thenT }
            // NIL-literal arm → OPTIONAL of the other arm's scalar (see the resolved
            // ternary path). The unfolded `a == b ? "x" : nil` form lands here.
            if let thenT, let elseExpr, isNilLiteral(elseExpr), abiScalars.contains(thenT) { return optionalOf(thenT) }
            if let elseT, isNilLiteral(thenExpr), abiScalars.contains(elseT) { return optionalOf(elseT) }
            // An arm whose type is merely UNKNOWN (not a `nil` literal) is not a safe
            // basis — bail (never guess the other arm's type).
            return nil
        }
        var sawCmp = false, sawArith = false
        for el in seq.elements {
            if let op = el.as(BinaryOperatorExprSyntax.self)?.operator.text {
                switch op {
                case "==", "!=", "<", ">", "<=", ">=", "&&", "||": sawCmp = true
                case "+": sawArith = true
                case "-", "*", "/", "%": sawArith = true
                default: return nil
                }
            }
        }
        if sawCmp {
            // SOUNDNESS: a comparison is only Bool if EVERY operand is a confidently
            // ABI-typed value (or a literal). An operand of unknown type (`.member`,
            // an untyped local) means the comparison may be over a type we can't
            // round-trip → bail rather than assert Bool.
            guard operandsAllABITyped(seq, known: known) else { return nil }
            return "Bool"
        }
        if sawArith {
            // SOUNDNESS: only type arithmetic when EVERY operand is a confidently
            // ABI-numeric value or a numeric literal. A single unknown operand
            // (`.now()`, a member of unknown type, a non-numeric value) means we
            // cannot prove the result type — bail. (Caught a real false-positive on
            // MovieSwiftUI: `.now() + 2.5` was mistyped Double but is Date arithmetic
            // that does not even compile.)
            // A non-literal numeric operand pins the result type. Integer literals
            // promote to whatever the pinned type is (`total * (1 - rate)` →
            // Double); we only bail when two DISTINCT non-literal numeric types
            // appear (`Int * Double`, genuinely ambiguous) or an operand is unknown.
            let numeric: Set<String> = ["Int","Double","Float","CGFloat","Decimal","Int64","Int32","UInt","TimeInterval"]
            var pinned: String?            // a non-literal numeric type
            var sawIntLiteral = false
            var sawStringOperand = false
            for el in seq.elements {
                if el.is(BinaryOperatorExprSyntax.self) { continue }
                // An integer literal (possibly negated / parenthesised) promotes.
                if isIntLiteralLike(el) { sawIntLiteral = true; continue }
                guard let t = infer(el, known: known) else { return nil }   // unknown operand → bail
                if t == "String" { sawStringOperand = true; continue }
                if t == "Int", isLiteralExpr(el) { sawIntLiteral = true; continue }
                guard numeric.contains(t) else { return nil }
                if let p = pinned { if p != t { return nil } } else { pinned = t }
            }
            if let pinned { return pinned }
            if sawStringOperand { return "String" }   // string concatenation
            if sawIntLiteral { return "Int" }          // pure integer-literal arithmetic
            return nil
        }
        return nil
    }

    /// An integer literal, possibly negated (`-1`) or parenthesised (`(1)`).
    private static func isIntLiteralLike(_ expr: ExprSyntax) -> Bool {
        if expr.is(IntegerLiteralExprSyntax.self) { return true }
        if let pre = expr.as(PrefixOperatorExprSyntax.self), pre.operator.text == "-" {
            return isIntLiteralLike(pre.expression)
        }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression { return isIntLiteralLike(inner) }
        return false
    }
    private static func isLiteralExpr(_ expr: ExprSyntax) -> Bool {
        expr.is(IntegerLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self)
    }

    /// Every non-operator operand of a sequence is a confidently ABI-typed value.
    private static func operandsAllABITyped(_ seq: SequenceExprSyntax, known: [String: String]) -> Bool {
        for el in seq.elements {
            if el.is(BinaryOperatorExprSyntax.self) || el.is(UnresolvedTernaryExprSyntax.self) { continue }
            guard let t = infer(el, known: known), isABIType(t) else { return false }
        }
        return true
    }

    private static func inferCall(_ call: FunctionCallExprSyntax, known: [String: String]) -> String? {
        // `Type(...)` constructor → Type (only if that Type is an ABI scalar like
        // `Double(x)`, `Int(y)`, `String(z)` — numeric/string conversions are the
        // common pure shape and round-trip the ABI).
        if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
           let first = callee.baseName.text.first, first.isUppercase {
            return abiScalars.contains(callee.baseName.text) ? callee.baseName.text : nil
        }
        // `base.member(...)` known stdlib transforms returning a scalar/String.
        // SOUNDNESS: require (a) the receiver base to be a confidently ABI-typed
        // value and (b) every argument to be a confidently ABI-typed value, so the
        // whole lifted call provably type-checks. (Caught `(1...4).contains(x.count)`
        // where `x: Double` had no `.count` — the argument was untypeable.)
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            // Every explicit argument must be ABI-typeable.
            for arg in call.arguments {
                guard let t = infer(arg.expression, known: known), isABIType(t) else { return nil }
            }
            let baseType: String? = member.base.flatMap { infer($0, known: known) }
            switch name {
            case "uppercased", "lowercased", "trimmingCharacters", "replacingOccurrences",
                 "reversed", "capitalized":
                return baseType == "String" ? "String" : nil
            case "description":
                guard let bt = baseType, abiScalars.contains(bt) else { return nil }
                return "String"
            case "hasPrefix", "hasSuffix":
                return baseType == "String" ? "Bool" : nil
            case "contains":
                // Valid on String / array bases only (we proved args ABI above).
                guard let bt = baseType, bt == "String" || (bt.hasPrefix("[") && bt.hasSuffix("]")) else { return nil }
                return "Bool"
            case "isMultiple":
                guard let bt = baseType, ["Int","Int64","Int32","UInt"].contains(bt) else { return nil }
                return "Bool"
            case "rounded", "squareRoot", "magnitude":
                guard let bt = baseType, ["Double","Float","CGFloat"].contains(bt) else { return nil }
                return bt
            default: return nil
            }
        }
        return nil
    }

    private static func inferMember(_ member: MemberAccessExprSyntax, known: [String: String]) -> String? {
        let name = member.declName.baseName.text
        // `.count`/`.isEmpty` are only valid on a COLLECTION/String base. SOUNDNESS:
        // a scalar base (`Double`/`Int`) has no `.count` — typing `elements.count`
        // Int when `elements: Double` emits a fragment that does not compile. Only
        // accept these when the base confidently resolves to a String or an array
        // type (or has no inferable base AND is therefore treated as a free
        // collection identifier the caller already gated as ABI-typed → still need
        // the base to be a collection, so bail when the base is a known scalar).
        if name == "count" || name == "isEmpty" {
            if let base = member.base, let bt = infer(base, known: known) {
                let isCollectionish = bt == "String"
                    || (bt.hasPrefix("[") && bt.hasSuffix("]"))
                guard isCollectionish else { return nil }   // scalar base → no .count
                return name == "count" ? "Int" : "Bool"
            }
            // Base type unknown → cannot prove it is a collection. Bail (safe).
            return nil
        }
        guard let base = member.base, let bt = infer(base, known: known) else { return nil }
        if bt == "String" {
            switch name {
            case "uppercased", "lowercased", "reversed", "capitalized": return "String"
            case "hasPrefix", "hasSuffix": return "Bool"
            default: return nil
            }
        }
        if ["Int","Double","Decimal","Bool","Float"].contains(bt), name == "description" { return "String" }
        return nil
    }

    private static func switchArms(_ sw: SwitchExprSyntax) -> [ExprSyntax]? {
        var out: [ExprSyntax] = []
        for arm in sw.cases {
            guard case let .switchCase(c) = arm else { return nil }
            guard c.statements.count == 1, let only = c.statements.first,
                  case let .expr(e) = only.item else { return nil }
            out.append(e)
        }
        return out.isEmpty ? nil : out
    }
    private static func ifArms(_ ifE: IfExprSyntax) -> [ExprSyntax]? {
        var out: [ExprSyntax] = []
        guard ifE.body.statements.count == 1, let t = ifE.body.statements.first,
              case let .expr(te) = t.item else { return nil }
        out.append(te)
        switch ifE.elseBody {
        case let .codeBlock(b)?:
            guard b.statements.count == 1, let e = b.statements.first, case let .expr(ee) = e.item else { return nil }
            out.append(ee)
        case let .ifExpr(nested)?:
            guard let rest = ifArms(nested) else { return nil }
            out.append(contentsOf: rest)
        case .none: return nil
        }
        return out
    }
    private static func inferBranches(_ arms: [ExprSyntax]?, known: [String: String]) -> String? {
        guard let arms, !arms.isEmpty else { return nil }
        var common: String?
        for v in arms {
            guard let t = infer(v, known: known), abiScalars.contains(t) else { return nil }
            if let c = common { if c != t { return nil } } else { common = t }
        }
        return common
    }
}
