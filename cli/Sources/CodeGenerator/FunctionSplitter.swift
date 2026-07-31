// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSyntax
import SwiftParser
import PartitioningEngine

/// Splits a `mixed` function into pure fragments (→ WASM) and a native shell
/// (Strategy A, statement-level). Agent A3 scope.
///
/// Day-2: this performs a *real* statement-level partition with def/use
/// (liveness) analysis so the emitted bridge genuinely threads values through
/// `Patch.call(...)`. The function body's top-level statements are partitioned
/// into contiguous runs of "liftable" (pure / wasm-safe Foundation / bridged)
/// statements and "must-stay-native" statements. Each liftable run becomes a
/// fragment whose:
///   - inputs  = identifiers it reads that were bound before the run (live-in),
///   - outputs = bindings it introduces that are read after the run (live-out).
/// The shell re-emits the body in order, replacing each liftable run with a
/// `Patch.call` that binds its outputs and feeds it the live-ins, and keeping
/// native statements verbatim.
///
/// Conservative: if a split cannot be proven safe (control flow straddling a
/// native boundary, a `return`/`throw` inside what would be a fragment, an
/// output whose type can't be determined and would break threading), the
/// splitter returns `nil` and the caller keeps the function `native` — Strategy
/// B (guard/conditional split) is attempted first for the common early-guard
/// shape.
public struct FunctionSplitter {
    public let registry: NativeRegistry
    /// Simple names of callees that must stay native (forced-native functions —
    /// `@objc`/`#selector`/unsafe — or functions classified `native`). A
    /// statement that calls one of these is kept in the shell, NOT lifted to a
    /// WASM fragment. Without this the splitter would treat a call to a native
    /// helper as pure and wrongly lift a native call into WASM (a correctness
    /// hole opened by the native→mixed lever, which makes callers-of-native
    /// functions split candidates). Supplied by the caller from the call graph.
    public let nativeCalleeNames: Set<String>

    public init(registry: NativeRegistry = .standard, nativeCalleeNames: Set<String> = []) {
        self.registry = registry
        self.nativeCalleeNames = nativeCalleeNames
    }

    public func plan(for record: FunctionRecord, sourceFile: URL) -> SplitPlan? {
        guard let source = try? String(contentsOf: sourceFile, encoding: .utf8) else { return nil }
        return plan(for: record, source: source)
    }

    public func plan(for record: FunctionRecord, source: String) -> SplitPlan? {
        plan(for: record, tree: Parser.parse(source: source))
    }

    /// Why a split was (or was not) produced — used by `analyze --split-diagnostics`
    /// to find the next lever. Not part of the realized-coverage contract.
    public enum Outcome: Sendable, Equatable {
        case splitA          // contiguous statement-level run (Strategy A)
        case splitSubExpr    // sub-expression lift (Strategy A2)
        case splitGuard      // guard/conditional lift (Strategy B)
        case splitSwitch     // switch / branch value lift (Strategy C)
        case noBody          // couldn't find the function body
        case emptyBody
        case noNativeRun     // no mustStayNative statement at all
        case noPureRun       // nothing liftable
        case controlFlowOnly // the only pure work is control-flow (no sub-expr/guard lift found)
        case noLiveThreading // a split existed but threading couldn't be proven
    }

    /// Diagnostic variant of `plan` that also reports the outcome category.
    public func planDiagnostic(for record: FunctionRecord, tree: SourceFileSyntax) -> (SplitPlan?, Outcome) {
        var outcome: Outcome = .noBody
        let plan = plan(for: record, tree: tree, outcome: &outcome)
        return (plan, outcome)
    }

    /// Plan against an already-parsed tree. The realized-coverage pass parses
    /// each source file ONCE and reuses the tree across every `mixed` function in
    /// it — avoiding O(functions) re-parses of giant files (the watchdog risk on
    /// `wire-ios`, where ~23k mixed functions would otherwise re-parse 5.8k files).
    public func plan(for record: FunctionRecord, tree: SourceFileSyntax) -> SplitPlan? {
        var ignored: Outcome = .noBody
        return plan(for: record, tree: tree, outcome: &ignored)
    }

    /// Per-top-level-statement analysis shared by every strategy.
    struct Stmt {
        let syntax: CodeBlockItemSyntax
        let text: String
        let isNative: Bool
        let defs: Set<String>     // bindings introduced
        let uses: Set<String>     // identifiers read
        let controlFlow: Bool     // return/throw/break/continue/if/for/while/guard/switch
    }

    func plan(for record: FunctionRecord, tree: SourceFileSyntax, outcome: inout Outcome) -> SplitPlan? {
        // Build a per-file declaration index ONCE and reuse it across every mixed
        // function in the file. Per-call this is O(file); the indexed overload
        // below avoids re-walking giant files thousands of times (the wire-ios
        // watchdog risk: 25k mixed functions × full-tree walk each).
        let index = DeclarationIndex(tree: tree)
        return plan(for: record, index: index, outcome: &outcome)
    }

    /// Plan using a prebuilt per-file declaration index (the realized-coverage pass
    /// and BuildPipeline build one index per file and reuse it for all the file's
    /// mixed functions — keeping giant-app analysis inside the time budget).
    ///
    /// `inferredTypes` is the type-resolution layer's per-function inferred types
    /// of params + locals (`ResolvedProject.localTypes[record.id]`). These let a
    /// fragment threading a local (not just a param) carry a CONCRETE type so the
    /// emitted `_wasm.swift` type-checks — converting today's "un-inferrable →
    /// native" cases into realized splits. Empty = no resolver (name-based types
    /// only, unchanged behaviour).
    public func plan(for record: FunctionRecord, index: DeclarationIndex,
                     inferredTypes: [String: String] = [:], outcome: inout Outcome) -> SplitPlan? {
        // Locate the declaration by start line (works for funcs, methods,
        // initializers, computed properties, accessors and closures), falling back
        // to a simple-signature match for plain functions. This recovers the large
        // "body not found" bucket: the old finder only matched plain `func` decls.
        guard let decl = index.lookup(startLine: record.startLine, simpleName: simpleName(of: record)),
              let body = decl.foundBody else { outcome = .noBody; return nil }

        let statements = Array(body)
        guard !statements.isEmpty else { outcome = .emptyBody; return nil }

        var items: [Stmt] = []
        for stmt in statements {
            // A statement stays in the shell (treated like native by Strategy A) if
            // it touches a mustStayNative symbol/native callee, OR it references
            // `self`/`super`, OR it is an assignment/mutation. The latter two cannot
            // be lifted into a standalone WASM value fragment (no `self` there; an
            // assignment is a side effect, not a value), so lifting them would emit
            // an uncompilable / semantically wrong fragment. Keeping them native is
            // safe and is what makes splitting `init`/computed-property bodies sound.
            let isNative = statementTouchesMustStayNative(stmt) || statementIsShellOnly(stmt)
            let (defs, uses) = defUse(of: stmt)
            items.append(Stmt(
                syntax: stmt,
                text: stmt.trimmedDescription,
                isNative: isNative,
                defs: defs,
                uses: uses,
                controlFlow: isControlFlow(stmt)
            ))
        }

        let rawBase = simpleName(of: record).split(separator: "(").first.map(String.init)
            ?? simpleName(of: record)
        // Sanitise to a valid Swift identifier (closure simple names like
        // `closure@L318` and accessors like `name.get` contain `@`/`.`), so the
        // generated `_sp_<base>_…` fragment names compile.
        let base = sanitizeIdentifier(rawBase)
        let paramNames = Set(decl.parameters.map { $0.name })
        var paramTypeByName = Dictionary(decl.parameters.map { ($0.name, $0.type) },
                                         uniquingKeysWith: { a, _ in a })
        // Type-resolution layer: fold in the resolver's inferred local/param types
        // FIRST (the richest source — scope-threaded member/return-type inference).
        // The declared param types above still win where both are present.
        for (name, type) in inferredTypes where paramTypeByName[name] == nil {
            paramTypeByName[name] = type
        }
        // Infer concrete types of local `let`/`var` bindings from their explicit
        // annotation or constructor/literal initializer. This lets fragments that
        // thread a local (not just a param) be NON-generic and genuinely
        // type-check/compile, instead of falling back to an `_`→generic parameter
        // that breaks the moment the local is operated on. (Backstop for locals the
        // resolver did not type.)
        //
        // CROSS-STATEMENT THREADING (optimization-sweep #3): the original single
        // pass typed each local only from params + resolver types, so a multi-stmt
        // pure region like `let a = items.count; let b = a + 1; let c = b * 2`
        // typed only `a` (off `.count`→Int) and abandoned `b`/`c` as un-inferrable.
        // We now iterate to a fixpoint in *source order*, feeding each newly-typed
        // local back into `known` so a later binding initialised from an earlier
        // local resolves concretely. Bounded by the statement count (monotonic:
        // each round only ADDS types), so it terminates and stays cheap. Still
        // best-effort: anything not confidently typed is simply left out (→ `_`),
        // which is safe (the run stays generic/native, never mistyped).
        var changed = true
        var rounds = 0
        while changed && rounds < statements.count + 1 {
            changed = false
            rounds += 1
            for stmt in statements {
                for (name, type) in inferredLocalTypes(in: stmt, known: paramTypeByName)
                where paramTypeByName[name] == nil {
                    paramTypeByName[name] = type
                    changed = true
                }
            }
        }

        let ctx = PlanContext(
            base: base, items: items, paramNames: paramNames, paramTypeByName: paramTypeByName,
            decl: decl, record: record)

        // ---- Strategy H: host-projected reactive reads. ----
        // For a "pure-logic-over-reactive-reads" member the classifier marked
        // host-projectable (`record.hostProjectableReads`), lift the WHOLE body
        // into one value fragment whose inputs are the projected reactive reads.
        // The native shell reads `self.<prop>` and feeds it to the fragment. Tried
        // FIRST because such a member's statements all read `self`, so every other
        // strategy keeps them in the shell (no fragment) — only this one realises it.
        if !record.hostProjectableReads.isEmpty,
           let plan = strategyHostProjection(ctx) {
            outcome = .splitA
            return plan
        }

        // ---- Strategy H2: host-projected reactive reads, PARTIAL (subset (b)). ----
        // For a MULTI-STATEMENT method that reads reactive props among otherwise-
        // pure statements AND keeps native statements (a non-reactive `self.x = …`
        // write, a Void return): project the reactive reads into shell locals, then
        // statement-level-partition the rewritten body — the pure middle rides WASM,
        // the native writes stay verbatim in the shell. Tried after the whole-body
        // projection (which a Void/writing method fails) and before Strategy A
        // (which would keep every `self`-reading statement in the shell, lifting
        // nothing). Demote-safe: realises only when ≥1 sound pure run lifts.
        if record.hostProjectablePartial, !record.hostProjectableReads.isEmpty,
           let plan = strategyHostProjectionPartial(ctx) {
            outcome = .splitA
            return plan
        }

        // ---- Strategy A: contiguous statement-level pure/native runs. ----
        if let plan = strategyA(ctx) {
            outcome = .splitA
            return plan
        }

        // The function has at least one native statement (it is `mixed`), but
        // Strategy A found no liftable top-level pure run. Try the finer-grained
        // strategies that recover OTA work hidden *inside* statements.
        let hasNative = items.contains { $0.isNative }
        guard hasNative else { outcome = .noNativeRun; return nil }

        // ---- Strategy B: guard / conditional split (pure condition or branch). ----
        if let plan = strategyB(ctx) {
            outcome = .splitGuard
            return plan
        }

        // ---- Strategy C: switch / branch value lifting (optimization-sweep #1). ----
        // Lift a pure top-level `switch`/`if` expression-statement (or a
        // `let x = switch/if {…}` binding) whose scrutinee + ALL arms are pure and
        // produce one concrete-typed value, into a value fragment. Recovers the
        // `controlFlowOnly` bucket that Strategy A deliberately skips.
        if let plan = strategySwitch(ctx) {
            outcome = .splitSwitch
            return plan
        }

        // ---- Strategy A2: sub-expression lifting inside a native statement. ----
        if let plan = strategySubExpr(ctx) {
            outcome = .splitSubExpr
            return plan
        }

        // Nothing liftable that we can prove safe + compilable → keep native.
        let anyControlFlow = items.contains { $0.controlFlow }
        outcome = anyControlFlow ? .controlFlowOnly : .noPureRun
        return nil
    }

    // MARK: - Shared planning context

    struct PlanContext {
        let base: String
        let items: [Stmt]
        let paramNames: Set<String>
        let paramTypeByName: [String: String]
        let decl: DeclInfo
        let record: FunctionRecord

        /// A binding read by some statement at-or-after `end`.
        func usesAfter(_ end: Int) -> Set<String> {
            var s: Set<String> = []
            for k in end..<items.count { s.formUnion(items[k].uses) }
            return s
        }
        /// A binding available before `start` (a param or defined earlier).
        func definedBefore(_ start: Int) -> Set<String> {
            var s = paramNames
            for k in 0..<start { s.formUnion(items[k].defs) }
            return s
        }
    }

    private func makePlan(_ ctx: PlanContext, fragments: [SplitPlan.PureFragment],
                          shellSteps: [SplitPlan.ShellStep]) -> SplitPlan {
        SplitPlan(
            originalID: ctx.record.id,
            originalSimpleName: simpleName(of: ctx.record),
            pureFragments: fragments,
            nativeSignature: ctx.decl.signatureText ?? simpleName(of: ctx.record),
            originalParameters: ctx.decl.parameters.map { (name: $0.name, type: $0.type) },
            returnType: ctx.decl.returnType,
            isAsync: ctx.decl.isAsync,
            isThrows: ctx.decl.isThrows,
            shellSteps: shellSteps)
    }

    // MARK: - Strategy A (contiguous statement-level runs)

    private func strategyA(_ ctx: PlanContext) -> SplitPlan? {
        let items = ctx.items
        // Build contiguous runs of same-native-ness.
        var runs: [(isNative: Bool, range: Range<Int>)] = []
        var i = 0
        while i < items.count {
            var j = i + 1
            while j < items.count && items[j].isNative == items[i].isNative { j += 1 }
            runs.append((items[i].isNative, i..<j))
            i = j
        }
        let hasNative = runs.contains { $0.isNative }
        let hasPure = runs.contains { !$0.isNative }
        guard hasNative, hasPure else { return nil }

        var fragments: [SplitPlan.PureFragment] = []
        var shellSteps: [SplitPlan.ShellStep] = []
        let labels = ["prepare", "process", "finalize", "compute", "derive", "assemble"]
        var pureRunIndex = 0

        for run in runs {
            if run.isNative {
                for k in run.range { shellSteps.append(.nativeStatement(items[k].text)) }
                continue
            }
            // A pure run with top-level control flow can't be lifted WHOLE as a value
            // fragment (that would move control flow into WASM). Historically the
            // entire run then demoted to the shell — so the leading pure statements
            // were lost just because the run happened to END in a `return`/`throw`
            // (`let d = items.map{…}; let s = d.reduce(0,+); return s`). That is the
            // statement-level analogue of the UIKit "one weird line is contagious"
            // bug. PEEL a contiguous TRAILING block of control-flow statements off the
            // run: the pure PREFIX lifts as a value fragment (its live-outs threaded
            // into the shell), and the peeled control-flow statement(s) stay native in
            // the shell, consuming those bound outputs in SOURCE ORDER. Demote-safe:
            // we only peel a TRAILING control-flow tail (the pure prefix is provably
            // unconditional — a control-flow statement in the MIDDLE of the run makes
            // the suffix conditional, so we keep the whole run native, as before). The
            // prefix then runs the SAME capture / boundary / liftability gates as any
            // other pure run (via `liftPureRun`), so an unsound peel can never ship.
            let runItems = run.range.map { items[$0] }
            var liftRange = run.range
            var cfTail: Range<Int>? = nil
            if runItems.contains(where: { $0.controlFlow }) {
                // The first control-flow statement: everything before it is the pure
                // prefix; from it onward is the (native) control-flow tail.
                let firstCF = run.range.first { items[$0].controlFlow }!
                // Only peelable when control flow forms the run's TRAILING tail (every
                // statement at-or-after `firstCF` is control flow) AND there is a
                // non-empty pure prefix. A control-flow statement mid-run (pure work
                // AFTER it) is NOT peelable — that suffix would be conditional.
                let tailAllCF = (firstCF..<run.range.upperBound).allSatisfy { items[$0].controlFlow }
                guard tailAllCF, firstCF > run.range.lowerBound else {
                    for k in run.range { shellSteps.append(.nativeStatement(items[k].text)) }
                    continue
                }
                liftRange = run.range.lowerBound..<firstCF
                cfTail = firstCF..<run.range.upperBound
            }

            let lifted = liftPureRun(liftRange, ctx: ctx, items: items,
                                     pureRunIndex: &pureRunIndex, labels: labels,
                                     fragments: &fragments, shellSteps: &shellSteps)
            if !lifted {
                // The prefix didn't lift (capture / non-liftable boundary) — keep it
                // native (conservative, exactly the prior behaviour).
                for k in liftRange { shellSteps.append(.nativeStatement(items[k].text)) }
            }
            // Emit the peeled control-flow tail VERBATIM, in source order, AFTER the
            // prefix (whether the prefix lifted or stayed native). Its reads of any
            // prefix-defined value are satisfied: a lifted prefix binds them as the
            // fragment's outputs (live-out analysis includes the tail); a native
            // prefix leaves them as ordinary shell locals.
            if let cfTail {
                for k in cfTail { shellSteps.append(.nativeStatement(items[k].text)) }
            }
        }

        guard !fragments.isEmpty else { return nil }
        return makePlan(ctx, fragments: fragments, shellSteps: shellSteps)
    }

    /// Lift one contiguous PURE statement range (no control flow) as a value
    /// fragment, threading its live-ins as inputs and its live-outs (values read
    /// at-or-after the range's end) as outputs. Appends the fragment + a
    /// `.fragmentCall` shell step and returns true on success; returns false (and
    /// appends NOTHING) when the range can't lift soundly — a closure CAPTURE of an
    /// unavailable value, or an input/output whose type isn't a liftable ABI
    /// boundary. The caller then keeps the range native (conservative). This is the
    /// extraction of Strategy A's per-run logic so a pure PREFIX of a
    /// control-flow-tailed run reuses the exact same demote-safe gates.
    private func liftPureRun(_ range: Range<Int>, ctx: PlanContext, items: [Stmt],
                             pureRunIndex: inout Int, labels: [String],
                             fragments: inout [SplitPlan.PureFragment],
                             shellSteps: inout [SplitPlan.ShellStep]) -> Bool {
        guard !range.isEmpty else { return false }
        let runItems = range.map { items[$0] }
        // Defensive: never lift control flow (the caller already peels the tail, but
        // keep this self-contained so a future call site can't regress).
        if runItems.contains(where: { $0.controlFlow }) { return false }

        let available = ctx.definedBefore(range.lowerBound)
        var runDefs: Set<String> = []
        var runUses: Set<String> = []
        for it in runItems { runDefs.formUnion(it.defs); runUses.formUnion(it.uses) }

        // INPUT-COMPLETENESS / NO-CAPTURE GATE (order-sensitive): thread an
        // `availableInRun` set statement-by-statement. Every *value identifier* a
        // statement reads must already be available (a param / earlier local / a local
        // bound by an EARLIER statement in the run) — only then do that statement's
        // own bindings become available to later ones. Correctly rejects
        // self-shadowing captures like `var x = x` (the RHS `x` is checked BEFORE the
        // LHS `x` is added). A capture keeps the run native (the fragment would
        // otherwise reference an undeclared value). Type/function/global symbols are
        // uppercase or in callee/type position, so `JSONEncoder()`/`Decimal(...)` are
        // not flagged.
        var availableInRun = available
        for it in runItems {
            let vs = ValueIdentifierScanner()
            vs.walk(it.syntax)
            if !vs.valueIdentifiers.isSubset(of: availableInRun) { return false }
            availableInRun.formUnion(it.defs)
        }

        let inputs = runUses.intersection(available).subtracting(runDefs).sorted()
        let liveAfter = ctx.usesAfter(range.upperBound)
        let outputs = runDefs.intersection(liveAfter).sorted()

        // SOUNDNESS: a lifted run's live-out is bound in the native shell as a `let`
        // (`let total = Frag().total`, CodeEmitter.fragmentCallLine). If a downstream
        // native statement REASSIGNS that name (`for x in extra { total += x }`, or
        // `if total > 100 { total = 100 }`), the generated `*_bridge.swift` won't
        // compile ('cannot assign to value: total is a let constant'). Rather than
        // ship a non-compiling shell, keep the whole run native when any output is
        // mutated after the range (build-safe = demote-safe). See BUG #6 / BUG #25.
        var mutatedAfter: Set<String> = []
        for k in range.upperBound..<items.count {
            let ms = MutatedNameScanner()
            ms.walk(items[k].syntax)
            mutatedAfter.formUnion(ms.mutated)
        }
        if !outputs.allSatisfy({ !mutatedAfter.contains($0) }) { return false }

        let inputPairs = inputs.map { (name: $0, type: ctx.paramTypeByName[$0] ?? "_") }
        // Use inferred concrete output types where known so the fragment's return type
        // is real (not a generic) and type-checks.
        let outputPairs = outputs.map { (name: $0, type: ctx.paramTypeByName[$0] ?? "_") }

        // A concretely-typed input/output naming a `mustStayNative` type (e.g.
        // `URLRequest` is wasm-safe, but `UIView`/`URLSession` are not) can't be an ABI
        // boundary value — keep the run native.
        //
        // BUG R4-#454 (CRIT): an UN-INFERABLE (`_`) input/output is NOT ABI-eligible
        // (CodeEmitter.abiEligible rejects `_`), so the emitter SKIPS the fragment's
        // envelopes and `fragmentCallLine` emits a `fatalError(...)` string — leaving
        // the live-out unbound and the generated `*_bridge.swift` non-compiling. The
        // peer strategies (517/527/885-886/962/1099/1169) all gate `$0.type != "_"`;
        // this run path omitted it. `typeIsLiftable("_")` returns true (it isn't a
        // mustStayNative type), so the bare liftability check let a generic fragment
        // through. Keep any run with an un-inferable boundary value native (demote-safe).
        guard inputPairs.allSatisfy({ $0.type != "_" && typeIsLiftable($0.type) }),
              outputPairs.allSatisfy({ $0.type != "_" && typeIsLiftable($0.type) }) else { return false }

        let label = pureRunIndex < labels.count ? labels[pureRunIndex] : "part\(pureRunIndex)"
        pureRunIndex += 1
        let fragName = "_sp_\(ctx.base)_\(label)"

        var fragBody = runItems.map { $0.text }
        if outputs.count == 1 {
            fragBody.append("return \(outputs[0])")
        } else if outputs.count > 1 {
            fragBody.append("return (" + outputs.map { "\($0): \($0)" }.joined(separator: ", ") + ")")
        }

        let fragment = SplitPlan.PureFragment(
            name: fragName, inputs: inputPairs, outputs: outputPairs, bodyStatements: fragBody)
        fragments.append(fragment)
        shellSteps.append(.fragmentCall(fragment: fragment))
        return true
    }

    // MARK: - Strategy H (host-projected reactive reads)

    /// Realise a "pure-logic-over-reactive-reads" member (one the classifier
    /// marked host-projectable) by lifting its WHOLE body into a single value
    /// fragment whose inputs are the reactive properties it reads — PROJECTED by
    /// the native shell from `self.<prop>`. This generalises the SwiftUI view-body
    /// path's `@State` projection to the partitioning engine: the shell reads the
    /// reactive props, marshals their values across the JSON ABI, and the fragment
    /// runs the pure logic over those values (it never touches reactive state).
    ///
    /// Emitted shape (for `var label: String { "@" + handle }` reading `@State handle`):
    ///   fragment `_sp_label_compute(handle: String) -> String { return "@" + handle }`
    ///   shell:    `let handle = self.handle`
    ///             `let _hp = Patch.call("_sp_label_compute", Args(handle: handle), …)`
    ///             `return _hp`
    ///
    /// DEMOTE-SAFETY (returns nil → member stays native unless ALL hold):
    ///   * every projected read has a CONCRETE, liftable (non-native) type,
    ///   * the member returns a concrete, liftable, non-Void value type,
    ///   * after rewriting `self.<prop>` → `<prop>`, the fragment body is
    ///     SELF-FREE (no remaining `self`/`super`), reads no identifier that is not
    ///     a projected prop / a name it binds locally / a type-or-global symbol,
    ///     and touches no `mustStayNative` symbol, native callee, `await`, `try`,
    ///     assignment, or `inout` (the `PurityScanner`/`ShellOnlyScanner` gates),
    ///   * the body ends in a single returned value.
    /// Any failure keeps the member native; the realized pass then reports it as
    /// shipping nothing OTA. The fragment is the ground truth — a member only earns
    /// OTA credit when this produces a genuinely compilable, ABI-eligible fragment.
    private func strategyHostProjection(_ ctx: PlanContext) -> SplitPlan? {
        let reads = ctx.record.hostProjectableReads
        guard !reads.isEmpty else { return nil }

        // Return type must be a concrete, liftable, non-Void value.
        let returnType = ctx.decl.returnType
        guard !returnType.isEmpty, returnType != "Void", returnType != "()",
              !returnType.contains("_"), typeIsLiftable(returnType) else { return nil }

        // Inputs = the projected reactive reads, with their proven concrete types.
        // (The extractor already restricted these to value-marshallable scalar /
        // String / Bool / scalar-array types.) Re-check liftability defensively.
        let projected = reads.map { (name: $0.name, type: $0.type) }
            .sorted { $0.name < $1.name }
        guard projected.allSatisfy({ $0.type != "_" && typeIsLiftable($0.type) }) else { return nil }
        let projectedNames = Set(projected.map { $0.name })

        // The member's OWN parameters (for a `method`) are also threaded into the
        // fragment — the shell passes them directly (they are in scope), so a method
        // that mixes its params with reactive reads (`func near(_ p: String) ->
        // String { p + name }`) lifts too. Every param must have a concrete, liftable
        // type; if any is `_`/native, keep the member native (the fragment couldn't
        // marshal it). A param must not collide with a projected reactive name.
        let memberParams = ctx.decl.parameters.map { (name: $0.name, type: $0.type) }
        guard memberParams.allSatisfy({ $0.type != "_" && typeIsLiftable($0.type) }) else { return nil }
        let paramNames = Set(memberParams.map { $0.name })
        guard paramNames.isDisjoint(with: projectedNames) else { return nil }

        // Rewrite every body statement: `self.<prop>`/`.<prop>` (for a projected
        // prop) → the bare projected name `<prop>`. The bare name is the fragment
        // parameter, so the rewritten body refers to the parameter, not `self`.
        let rewriter = SelfReactiveReadRewriter(projectedNames: projectedNames)
        var rewrittenStmts: [CodeBlockItemSyntax] = []
        for item in ctx.items {
            guard let rewritten = rewriter.rewriteItem(item.syntax) else { return nil }
            rewrittenStmts.append(rewritten)
        }

        // Verify the rewritten body is SELF-FREE and PURE. Any `self`/`super`,
        // native symbol/callee, await/try/assignment/inout, OR a free identifier
        // that is neither a projected prop nor a name bound inside the body keeps
        // the member native (the fragment would not compile / would be unsound).
        var boundInBody: Set<String> = []
        for stmt in rewrittenStmts {
            let du = DefUseAnalyzer(); du.walk(stmt); boundInBody.formUnion(du.defs)
        }
        // A local that shadows a projected name / param would redeclare the
        // fragment's parameter (a compile error) — keep the member native.
        if !boundInBody.isDisjoint(with: projectedNames) { return nil }
        if !boundInBody.isDisjoint(with: paramNames) { return nil }
        // Identifiers the fragment may freely reference: projected reads, the
        // member's own params, and names it binds locally.
        let allowedFree = projectedNames.union(paramNames)
        for stmt in rewrittenStmts {
            // Self / super / effect / assignment / inout → not liftable.
            let shell = ShellOnlyScanner(); shell.walk(stmt)
            if shell.shellOnly { return nil }
            // Native symbol or native callee anywhere → not liftable.
            if statementTouchesMustStayNative(stmt) { return nil }
            // Defense-in-depth: a mutating-method call on a projected prop (now a
            // by-value `let` parameter) would not compile / would silently drop the
            // mutation. Reject (the extractor's denylist should already keep such a
            // member native, but the splitter is the ground truth). Note: params are
            // checked too since a mutating call on a by-value param param is likewise
            // a dropped mutation.
            let mut = ProjectedMutationScanner(projectedNames: allowedFree); mut.walk(stmt)
            if mut.mutates { return nil }
            // Free value identifiers must be projected props, member params, or
            // locally bound. CLOSURE-SCOPE-AWARE: a name bound by an enclosing
            // closure (a named closure param or a `$N` shorthand) — or a `let`/`var`
            // declared inside a closure — is NOT a free capture, so a pure
            // higher-order transform over a projected read (`scores.map { $0 * 2 }`,
            // `items.filter { $0 > limit }`, `xs.reduce(0) { acc, x in acc + x }`)
            // lifts. Only a GENUINELY free identifier (one not bound anywhere in
            // scope and not a projected prop / member param) keeps the member native.
            let free = HostProjectionFreeIdentifierScanner(
                preBound: allowedFree.union(boundInBody))
            free.walk(stmt)
            if !free.freeIdentifiers.isEmpty { return nil }
        }

        // Build the fragment body, guaranteeing it ends in a single returned value.
        guard let fragBody = hostProjectionFragmentBody(rewrittenStmts) else { return nil }

        // Fragment inputs = projected reactive reads + the member's own params
        // (deterministic order: projected first (sorted), then params in declared
        // order). `fragmentCallLine` passes each by name; the params are in the
        // shell's scope and the projected reads are bound by the projection steps.
        let fragInputs = projected.map { (name: $0.name, type: $0.type) }
            + memberParams.map { (name: $0.name, type: $0.type) }
        let fragName = "_sp_\(ctx.base)_hostproject"
        let outputName = "_hp_result"
        let fragment = SplitPlan.PureFragment(
            name: fragName,
            inputs: fragInputs,
            outputs: [(name: outputName, type: returnType)],
            bodyStatements: fragBody)

        // The shell: project each reactive read into a plain local the fragment
        // call passes by name (`fragmentCallLine` emits `Args(name: name)`), invoke
        // the fragment, then return its single output. The projection reads
        // `self.<prop>` in the native shell — exactly the reactive state the WASM
        // fragment must not touch. The member's params are already in scope.
        var shellSteps: [SplitPlan.ShellStep] = []
        for p in projected {
            shellSteps.append(.nativeStatement("let \(p.name) = self.\(p.name)"))
        }
        shellSteps.append(.fragmentCall(fragment: fragment))
        shellSteps.append(.nativeStatement("return \(outputName)"))

        return makePlan(ctx, fragments: [fragment], shellSteps: shellSteps)
    }

    /// Turn the rewritten body statements into a fragment body that ends in a
    /// single returned value. Handles the common getter shapes:
    ///   * a single bare value expression (implicit-return getter) → `return <expr>`,
    ///   * a body whose LAST statement is already a `return` → keep verbatim,
    ///   * `let`/`var` locals followed by a final bare value expression → wrap the
    ///     trailing expression in `return`.
    /// Returns nil for anything else (a body with no clear single trailing value,
    /// or a trailing control-flow statement) — keeping the member native.
    private func hostProjectionFragmentBody(_ stmts: [CodeBlockItemSyntax]) -> [String]? {
        guard let last = stmts.last else { return nil }
        var out = stmts.dropLast().map { $0.trimmedDescription }
        // Already an explicit `return …` as the final statement.
        if case .stmt(let s) = last.item, s.is(ReturnStmtSyntax.self) {
            out.append(last.trimmedDescription)
            return Array(out)
        }
        // A trailing bare VALUE expression (the implicit-return value). Reject a
        // trailing statement that is control flow / a declaration / an assignment.
        if case .expr(let e) = last.item {
            // `if`/`switch` expression-statements straddle control flow — reject
            // (a value `if`/`switch` would be a binding's initializer, handled by
            // the explicit-return / let-binding shapes, not a bare statement).
            if e.is(IfExprSyntax.self) || e.is(SwitchExprSyntax.self) { return nil }
            out.append("return \(last.trimmedDescription)")
            return Array(out)
        }
        return nil
    }

    // MARK: - Strategy H2 (host-projected reactive reads, PARTIAL / multi-statement)

    /// Realise a MULTI-STATEMENT method that reads reactive props among otherwise-
    /// pure statements and KEEPS native statements (a non-reactive `self.x = …`
    /// write, a Void return). The native shell projects each reactive read into a
    /// plain local (`let published = self.published`); after rewriting `self.<prop>`
    /// → `<prop>` in the body, the projected reads are ordinary in-scope values. We
    /// then statement-level-partition the rewritten body EXACTLY like Strategy A —
    /// contiguous pure runs become WASM fragments threaded through the shell, native
    /// statements (anything still touching `self`/`super`, an assignment, a native
    /// call) stay verbatim. The pure middle rides WASM; the native writes stay in
    /// the App Store binary.
    ///
    /// Shape (for `func update() { let x = published; let y = compute(x); self.cache
    /// = transform(y) }` reading `@Published published`, `compute`/`transform` pure):
    ///   shell: `let published = self.published`
    ///          `let (x, y) = Patch.call("_sp_update_hp0", Args(published:…), …)`  // fragment
    ///          `self.cache = transform(y)`                                        // native
    ///
    /// SAFETY (cardinal — never a wrong split; returns nil → member stays native
    /// unless ALL hold for the lifted runs):
    ///   * every projected read has a CONCRETE, liftable (non-native) type, and the
    ///     method's own params are concrete + liftable too,
    ///   * NO projected name / param is shadowed by a body-local (would redeclare a
    ///     fragment input),
    ///   * a lifted run reads ONLY values available before it (projected reads,
    ///     params, earlier locals) — the SAME order-sensitive no-capture gate
    ///     Strategy A uses, so the fragment never references an undeclared value,
    ///   * a lifted run contains NO control flow, NO `self`/`super`, NO native
    ///     symbol/callee, NO assignment/await/try/inout, NO mutating call on a
    ///     projected value — anything impure keeps the run native,
    ///   * a lifted run's inputs AND outputs are all concretely-typed + liftable
    ///     (else the fragment is generic / not ABI-eligible),
    ///   * the body MUTATES no reactive property anywhere (the extractor's gate
    ///     already requires this; re-checked defensively per projected value),
    ///   * ≥1 fragment is produced (else there is no OTA work — return nil).
    /// Native runs are emitted verbatim in original order, so a kept `self.cache =
    /// transform(y)` write executes natively AFTER the fragment binds `y` — the
    /// statement ORDER is preserved exactly, never reordered.
    private func strategyHostProjectionPartial(_ ctx: PlanContext) -> SplitPlan? {
        let reads = ctx.record.hostProjectableReads
        guard !reads.isEmpty else { return nil }

        // Projected reactive reads with proven concrete, liftable types.
        let projected = reads.map { (name: $0.name, type: $0.type) }
            .sorted { $0.name < $1.name }
        guard projected.allSatisfy({ $0.type != "_" && typeIsLiftable($0.type) }) else { return nil }
        let projectedNames = Set(projected.map { $0.name })

        // The method's own params must also be concrete + liftable (a fragment that
        // threads a param needs a real type), and must not collide with a projected
        // reactive name.
        let memberParams = ctx.decl.parameters.map { (name: $0.name, type: $0.type) }
        guard memberParams.allSatisfy({ $0.type != "_" && typeIsLiftable($0.type) }) else { return nil }
        let paramNames = Set(memberParams.map { $0.name })
        guard paramNames.isDisjoint(with: projectedNames) else { return nil }

        // Rewrite the body: `self.<prop>` → `<prop>` for every projected prop, so a
        // statement reading only projected props is no longer a `self` reference.
        let rewriter = SelfReactiveReadRewriter(projectedNames: projectedNames)
        var rewritten: [CodeBlockItemSyntax] = []
        for item in ctx.items {
            guard let r = rewriter.rewriteItem(item.syntax) else { return nil }
            rewritten.append(r)
        }

        // A local binding may not shadow a projected read / param (it would
        // redeclare the fragment input the shell projects). Reject if so.
        var allBound: Set<String> = []
        for stmt in rewritten {
            let du = DefUseAnalyzer(); du.walk(stmt); allBound.formUnion(du.defs)
        }
        if !allBound.isDisjoint(with: projectedNames) { return nil }
        if !allBound.isDisjoint(with: paramNames) { return nil }

        // Build per-statement analysis over the REWRITTEN body. A statement is
        // native (shell-only) if — after the rewrite — it still touches a
        // mustStayNative symbol / native callee, OR it references `self`/`super`, OR
        // it is an assignment / mutation. (Identical predicate to the main
        // `plan(...)` loop, run over the rewritten tree.)
        struct PStmt {
            let text: String
            let isNative: Bool
            let defs: Set<String>
            let uses: Set<String>
            let controlFlow: Bool
            let syntax: CodeBlockItemSyntax
        }
        var pitems: [PStmt] = []
        for stmt in rewritten {
            let isNative = statementTouchesMustStayNative(stmt) || statementIsShellOnly(stmt)
            let (defs, uses) = defUse(of: stmt)
            pitems.append(PStmt(
                text: stmt.trimmedDescription, isNative: isNative,
                defs: defs, uses: uses, controlFlow: isControlFlow(stmt), syntax: stmt))
        }

        // PARTIAL means partial: there MUST be at least one native shell statement
        // to keep (a non-reactive `self.x = …` write, a Void side-effect). A member
        // with NO native statement is a clean value member already handled (or
        // soundly rejected) by the whole-body gate — re-admitting it here would route
        // an unmarshallable-return computed property to `mixed`. Require a native run.
        guard let firstNativeIndex = pitems.firstIndex(where: { $0.isNative }) else { return nil }

        // PROJECTION-FRESHNESS ORDERING SAFETY (cardinal — never read a stale value).
        // The shell HOISTS every reactive read to the TOP (`let counter =
        // self.counter`) before any native statement runs. That is only sound if NO
        // native statement BEFORE a projected read could change it: a native call
        // (`self.helper()`) earlier in the body might mutate `counter`, so reading it
        // pre-hoisted would feed the fragment a STALE value (wrong behaviour). We
        // conservatively require that NO statement at-or-after the FIRST native
        // statement references ANY projected read — i.e. every reactive read is
        // consumed by the pure prefix that runs before the first native statement, so
        // hoisting the read to the top changes nothing. (A reactive WRITE is already
        // excluded by the extractor gate; this also rules out a native statement
        // re-reading/aliasing the projected value after a side effect.) If any later
        // statement touches a projected read, bail → the member stays native.
        for k in firstNativeIndex..<pitems.count where !pitems[k].uses.isDisjoint(with: projectedNames) {
            return nil
        }

        // The projected reads + the method's params are available before the body
        // (the shell projects/holds them); a binding becomes available after the
        // statement that defines it.
        let entryAvailable = projectedNames.union(paramNames)
        func definedBefore(_ start: Int) -> Set<String> {
            var s = entryAvailable
            for k in 0..<start { s.formUnion(pitems[k].defs) }
            return s
        }
        func usesAfter(_ end: Int) -> Set<String> {
            var s: Set<String> = []
            for k in end..<pitems.count { s.formUnion(pitems[k].uses) }
            return s
        }

        // Contiguous runs of same-native-ness (Strategy A's partition, over the
        // rewritten body).
        var runs: [(isNative: Bool, range: Range<Int>)] = []
        var i = 0
        while i < pitems.count {
            var j = i + 1
            while j < pitems.count && pitems[j].isNative == pitems[i].isNative { j += 1 }
            runs.append((pitems[i].isNative, i..<j))
            i = j
        }

        // Types known for fragment I/O: projected reads (their proven types), the
        // method's params, and body locals. The `ctx.paramTypeByName` local
        // inference ran over the ORIGINAL body, where a read appears as `self.<prop>`
        // (a MemberAccess the inferrer can't type) — so a local derived from a
        // projected read (`let doubled = counter * 2`) was left UN-typed there. We
        // RE-RUN the local-type fixpoint over the REWRITTEN body, seeding the
        // projected reads' concrete types, so such locals now infer concretely and
        // the fragment is ABI-eligible. (Same bounded source-order fixpoint as the
        // main planner; monotonic → terminates; best-effort → an un-inferrable local
        // stays `_` and keeps its run native, never mistyped.)
        var typeByName = ctx.paramTypeByName
        for p in projected where typeByName[p.name] == nil { typeByName[p.name] = p.type }
        var tChanged = true
        var tRounds = 0
        while tChanged && tRounds < rewritten.count + 1 {
            tChanged = false
            tRounds += 1
            for stmt in rewritten {
                for (name, type) in inferredLocalTypes(in: stmt, known: typeByName)
                where typeByName[name] == nil {
                    typeByName[name] = type
                    tChanged = true
                }
            }
        }

        var fragments: [SplitPlan.PureFragment] = []
        var shellSteps: [SplitPlan.ShellStep] = []
        // Project every reactive read into the shell first (in deterministic order).
        for p in projected {
            shellSteps.append(.nativeStatement("let \(p.name) = self.\(p.name)"))
        }

        let labels = ["hp0", "hp1", "hp2", "hp3", "hp4", "hp5"]
        var pureRunIndex = 0
        var liftedAny = false

        for run in runs {
            if run.isNative {
                for k in run.range { shellSteps.append(.nativeStatement(pitems[k].text)) }
                continue
            }
            let runItems = run.range.map { pitems[$0] }
            // A pure run with top-level control flow can't be a value fragment.
            if runItems.contains(where: { $0.controlFlow }) {
                for k in run.range { shellSteps.append(.nativeStatement(pitems[k].text)) }
                continue
            }

            let available = definedBefore(run.range.lowerBound)
            var runDefs: Set<String> = []
            var runUses: Set<String> = []
            for it in runItems { runDefs.formUnion(it.defs); runUses.formUnion(it.uses) }

            // INPUT-COMPLETENESS / NO-CAPTURE GATE (order-sensitive, closure-aware) —
            // mirrors Strategy A. Every free value identifier a statement reads must
            // already be available (projected read / param / earlier-or-same-run
            // local); a closure-bound `$N`/param is not free. A genuine capture keeps
            // the whole run native.
            var availableInRun = available
            var hasCapture = false
            for it in runItems {
                let free = HostProjectionFreeIdentifierScanner(preBound: availableInRun)
                free.walk(it.syntax)
                if !free.freeIdentifiers.isEmpty { hasCapture = true; break }
                availableInRun.formUnion(it.defs)
            }
            if hasCapture {
                for k in run.range { shellSteps.append(.nativeStatement(pitems[k].text)) }
                continue
            }
            // Defense-in-depth: a mutating stdlib call on a projected value (now a
            // by-value `let`) would silently drop the mutation — keep native.
            var mutatesProjected = false
            for it in runItems {
                let mut = ProjectedMutationScanner(projectedNames: projectedNames.union(paramNames))
                mut.walk(it.syntax)
                if mut.mutates { mutatesProjected = true; break }
            }
            if mutatesProjected {
                for k in run.range { shellSteps.append(.nativeStatement(pitems[k].text)) }
                continue
            }

            let inputs = runUses.intersection(available).subtracting(runDefs).sorted()
            let liveAfter = usesAfter(run.range.upperBound)
            let outputs = runDefs.intersection(liveAfter).sorted()

            // BUG R4-#878 (HIGH): a lifted run's live-out is bound in the native shell
            // as a `let` (`let total = Frag().total`, CodeEmitter.fragmentCallLine). If a
            // downstream native statement REASSIGNS that name (`total += extra`), the
            // generated `*_bridge.swift` won't compile ('cannot assign to value: total
            // is a let constant'). `liftPureRun` already guards this (438-444); the H2
            // run loop lacked it. Keep the whole run native when any output is mutated
            // after the range (build-safe = demote-safe).
            var mutatedAfter: Set<String> = []
            for k in run.range.upperBound..<pitems.count {
                let ms = MutatedNameScanner()
                ms.walk(pitems[k].syntax)
                mutatedAfter.formUnion(ms.mutated)
            }
            if !outputs.allSatisfy({ !mutatedAfter.contains($0) }) {
                for k in run.range { shellSteps.append(.nativeStatement(pitems[k].text)) }
                continue
            }

            let inputPairs = inputs.map { (name: $0, type: typeByName[$0] ?? "_") }
            let outputPairs = outputs.map { (name: $0, type: typeByName[$0] ?? "_") }

            // Inputs AND outputs must be concretely-typed + liftable (else the
            // fragment is generic / not ABI-eligible — keep the run native).
            if !inputPairs.allSatisfy({ $0.type != "_" && typeIsLiftable($0.type) })
                || !outputPairs.allSatisfy({ $0.type != "_" && typeIsLiftable($0.type) }) {
                for k in run.range { shellSteps.append(.nativeStatement(pitems[k].text)) }
                continue
            }
            // A lifted run that produces NO live-out value buys no OTA work and would
            // emit a void fragment — keep it native (no value to thread).
            if outputPairs.isEmpty {
                for k in run.range { shellSteps.append(.nativeStatement(pitems[k].text)) }
                continue
            }

            let label = pureRunIndex < labels.count ? labels[pureRunIndex] : "hp\(pureRunIndex)"
            pureRunIndex += 1
            let fragName = "_sp_\(ctx.base)_\(label)"
            var fragBody = runItems.map { $0.text }
            if outputs.count == 1 {
                fragBody.append("return \(outputs[0])")
            } else {
                fragBody.append("return (" + outputs.map { "\($0): \($0)" }.joined(separator: ", ") + ")")
            }
            let fragment = SplitPlan.PureFragment(
                name: fragName, inputs: inputPairs, outputs: outputPairs, bodyStatements: fragBody)
            fragments.append(fragment)
            shellSteps.append(.fragmentCall(fragment: fragment))
            liftedAny = true
        }

        guard liftedAny, !fragments.isEmpty else { return nil }
        return makePlan(ctx, fragments: fragments, shellSteps: shellSteps)
    }

    // MARK: - Strategy B (guard / conditional split)

    /// Lift a PURE boolean condition out of a `guard` or `if` statement into a
    /// WASM fragment that returns `Bool`, then rewrite the statement to test the
    /// fragment result. The branch bodies (which may be native, e.g. `throw` /
    /// native cleanup) stay verbatim in the shell.
    ///
    /// Safe & compilable iff the condition:
    ///   * is a single boolean expression (NO optional/`case`/`let` binding — those
    ///     introduce values the rest of the body depends on, which we don't thread),
    ///   * touches no `mustStayNative` symbol and no native callee,
    ///   * reads only params / locals available at that point (all of known type so
    ///     the fragment is non-generic and type-checks),
    ///   * performs no assignment / mutation (pure).
    /// The whole rest of the function body is preserved as native shell statements,
    /// so semantics are identical; only the boolean test is computed in WASM.
    private func strategyB(_ ctx: PlanContext) -> SplitPlan? {
        let items = ctx.items
        var fragments: [SplitPlan.PureFragment] = []
        var shellSteps: [SplitPlan.ShellStep] = []
        var liftIndex = 0
        var liftedAny = false

        for (idx, stmt) in items.enumerated() {
            guard let lifted = liftableCondition(in: stmt.syntax) else {
                shellSteps.append(.nativeStatement(stmt.text))
                continue
            }
            // NO-CAPTURE GATE: EVERY identifier the condition reads must be a param
            // or an earlier local (available). If it reads anything else (an
            // instance member / capture like `!cancelled`), the Bool fragment would
            // reference an undeclared value → keep the statement native.
            let available = ctx.definedBefore(idx)
            guard lifted.usedIdentifiers.isSubset(of: available) else {
                shellSteps.append(.nativeStatement(stmt.text))
                continue
            }
            let inputs = lifted.usedIdentifiers.sorted()
            let typedInputs: [(name: String, type: String)] = inputs.map {
                (name: $0, type: ctx.paramTypeByName[$0] ?? "_")
            }
            // Compilability gate: every input the WASM Bool fragment needs must
            // have a concrete (non-`_`) type that is itself liftable (not a
            // `mustStayNative` type like `URLAuthenticationChallenge` that wouldn't
            // exist in the WASM module).
            guard typedInputs.allSatisfy({ $0.type != "_" && typeIsLiftable($0.type) }) else {
                shellSteps.append(.nativeStatement(stmt.text))
                continue
            }
            let label = "cond\(liftIndex)"
            liftIndex += 1
            let fragName = "_sp_\(ctx.base)_\(label)"
            let boundName = "\(fragName)_v"
            let fragment = SplitPlan.PureFragment(
                name: fragName,
                inputs: typedInputs,
                // The output name IS the bound name the shell binds and the
                // rewritten guard/if references — they must match exactly.
                outputs: [(name: boundName, type: "Bool")],
                bodyStatements: ["return (\(lifted.conditionText))"])
            fragments.append(fragment)
            // Rewrite: replace the condition with the fragment-result placeholder.
            // The shell binds the Bool from Patch.call, then runs the original
            // statement with the condition replaced by that bound name.
            shellSteps.append(.guardConditionCall(
                fragment: fragment,
                rewrittenStatement: lifted.rewrite(boundName)))
            liftedAny = true
        }

        guard liftedAny, items.contains(where: { $0.isNative }) else { return nil }
        return makePlan(ctx, fragments: fragments, shellSteps: shellSteps)
    }

    /// A pure boolean condition lifted from a guard/if, with the machinery to
    /// rewrite the original statement to test a bound Bool instead.
    private struct LiftedCondition {
        let conditionText: String
        let usedIdentifiers: Set<String>
        /// Produces the rewritten statement text given the name the shell binds
        /// the fragment's Bool result to.
        let rewrite: (_ boundName: String) -> String
    }

    /// If `stmt` is a `guard <pureBool> else { ... }` or `if <pureBool> { ... }
    /// [else ...]` whose condition is a single pure boolean expression, return the
    /// liftable condition; otherwise nil.
    private func liftableCondition(in stmt: CodeBlockItemSyntax) -> LiftedCondition? {
        // guard <cond> else { <body> }
        if case let .stmt(s) = stmt.item, let g = s.as(GuardStmtSyntax.self) {
            guard let cond = singleBooleanCondition(g.conditions),
                  let purity = pureBooleanExpr(cond) else { return nil }
            let elseText = g.body.trimmedDescription
            return LiftedCondition(
                conditionText: purity.text,
                usedIdentifiers: purity.identifiers,
                rewrite: { bound in "guard \(bound) else \(elseText)" })
        }
        // if <cond> { <then> } [else <else>]
        if case let .expr(ex) = stmt.item, let e = ex.as(IfExprSyntax.self) {
            // No else-if chains (those nest IfExpr in the else); keep it simple/safe.
            if case .ifExpr = e.elseBody { return nil }
            guard let cond = singleBooleanCondition(e.conditions),
                  let purity = pureBooleanExpr(cond) else { return nil }
            let thenText = e.body.trimmedDescription
            let elseText: String
            if case let .codeBlock(block)? = e.elseBody {
                elseText = " else \(block.trimmedDescription)"
            } else {
                elseText = ""
            }
            return LiftedCondition(
                conditionText: purity.text,
                usedIdentifiers: purity.identifiers,
                rewrite: { bound in "if \(bound) \(thenText)\(elseText)" })
        }
        return nil
    }

    /// A condition list that is exactly one boolean expression (no `let`/`case`/
    /// `where` binding). Returns the expression.
    private func singleBooleanCondition(_ conditions: ConditionElementListSyntax) -> ExprSyntax? {
        guard conditions.count == 1, let only = conditions.first else { return nil }
        guard case let .expression(expr) = only.condition else { return nil }
        return expr
    }

    /// Prove a boolean expression is pure & liftable. Returns its text + the
    /// identifiers it reads.
    private func pureBooleanExpr(_ expr: ExprSyntax) -> (text: String, identifiers: Set<String>)? {
        let scanner = PurityScanner(registry: registry, nativeCalleeNames: nativeCalleeNames)
        scanner.walk(expr)
        guard scanner.isPure else { return nil }
        return (expr.trimmedDescription, scanner.identifiers)
    }

    // MARK: - Strategy A2 (sub-expression lifting inside a native statement)

    /// Within a single native statement, lift a self-contained PURE sub-expression
    /// of *inferable concrete type* into a WASM fragment, bind it to a temp in the
    /// shell, and substitute the temp into the native statement. Only fires when a
    /// statement-level split (Strategy A) found nothing — it recovers OTA work that
    /// is wedged inside a statement that also touches native.
    ///
    /// Conservative gates (all required, so the fragment provably compiles & is
    /// semantically safe):
    ///   * the sub-expression is pure (no native symbol / native callee / mutation /
    ///     `await` / `try`),
    ///   * its value type is one we can concretely infer (Bool / Int / Double /
    ///     String) so the fragment is non-generic and type-checks,
    ///   * every identifier it reads is a param/earlier-local of known concrete type,
    ///   * it is "non-trivial" (an operation, not a bare identifier/literal) — a
    ///     bare value buys no OTA and risks ABI noise.
    private func strategySubExpr(_ ctx: PlanContext) -> SplitPlan? {
        let items = ctx.items
        var fragments: [SplitPlan.PureFragment] = []
        var shellSteps: [SplitPlan.ShellStep] = []
        var liftIndex = 0
        var liftedAny = false

        for (idx, stmt) in items.enumerated() {
            guard stmt.isNative else {
                shellSteps.append(.nativeStatement(stmt.text))
                continue
            }
            let available = ctx.definedBefore(idx)
            let collector = LiftableSubExprCollector(
                registry: registry, nativeCalleeNames: nativeCalleeNames,
                available: available, paramTypeByName: ctx.paramTypeByName)
            collector.walk(stmt.syntax)
            guard let best = collector.best else {
                shellSteps.append(.nativeStatement(stmt.text))
                continue
            }
            let label = "expr\(liftIndex)"
            liftIndex += 1
            let fragName = "_sp_\(ctx.base)_\(label)"
            let boundName = "\(fragName)_v"
            let inputs = best.inputs.sorted().map { (name: $0, type: ctx.paramTypeByName[$0] ?? "_") }
            // All inputs must be concretely typed AND liftable (else a generic
            // fragment may not type-check the operation, e.g. `T0 + T1`, or a
            // native-typed input wouldn't exist in the WASM module).
            guard inputs.allSatisfy({ $0.type != "_" && typeIsLiftable($0.type) }) else {
                shellSteps.append(.nativeStatement(stmt.text))
                continue
            }
            // Substitute the lifted sub-expression in the native statement with the
            // bound temp. Require the substring to occur EXACTLY once: if it occurs
            // zero times (trivia mismatch) or more than once (ambiguous), bail and
            // keep the statement native — a corrupt rewrite must never be emitted.
            let occurrences = stmt.text.components(separatedBy: best.text).count - 1
            guard occurrences == 1 else {
                shellSteps.append(.nativeStatement(stmt.text))
                continue
            }
            let fragment = SplitPlan.PureFragment(
                name: fragName,
                inputs: inputs,
                // Output name == bound name the rewritten native statement uses.
                outputs: [(name: boundName, type: best.resultType)],
                bodyStatements: ["return (\(best.text))"])
            fragments.append(fragment)
            let rewritten = stmt.text.replacingOccurrences(of: best.text, with: boundName)
            shellSteps.append(.subExprCall(fragment: fragment, rewrittenStatement: rewritten))
            liftedAny = true
        }

        guard liftedAny else { return nil }
        return makePlan(ctx, fragments: fragments, shellSteps: shellSteps)
    }

    // MARK: - Strategy C (switch / branch value lifting)

    /// A `let <name> = switch/if {…}` binding (or a bare top-level switch/if
    /// expression statement bound nowhere but consumed downstream) whose scrutinee
    /// and EVERY arm are pure and yield the SAME concrete scalar/string type. The
    /// whole branch becomes a value fragment returning that type; the binding's
    /// live-out flows to the (native) rest of the shell. Native arms keep the whole
    /// branch native (zero false negatives) — we only lift when ALL arms are pure.
    ///
    /// This is the "switch-arm lifting" lever: a `switch status { case .a: 1 … }`
    /// or `if cond { x } else { y }` sitting among native statements (e.g. a
    /// FileManager / UserDefaults call) used to be abandoned as `controlFlowOnly`;
    /// now its pure value computation runs OTA in WASM while the native I/O stays
    /// in the shell.
    private func strategySwitch(_ ctx: PlanContext) -> SplitPlan? {
        let items = ctx.items
        var fragments: [SplitPlan.PureFragment] = []
        var shellSteps: [SplitPlan.ShellStep] = []
        var liftIndex = 0
        var liftedAny = false

        for (idx, stmt) in items.enumerated() {
            // A switch/if binding is shell-only if it touches self/await/try/assign;
            // those are caught by `stmt.isNative`. Only consider a NON-native stmt.
            guard !stmt.isNative,
                  let lifted = liftableBranchBinding(stmt.syntax, known: ctx.paramTypeByName) else {
                shellSteps.append(.nativeStatement(stmt.text))
                continue
            }
            // NO-CAPTURE GATE: every value the branch reads must be available (a
            // param / earlier local), else the fragment references an undeclared
            // value. Also the live-out binding must be of a known concrete type.
            let available = ctx.definedBefore(idx)
            guard lifted.usedIdentifiers.isSubset(of: available) else {
                shellSteps.append(.nativeStatement(stmt.text))
                continue
            }
            let inputs = lifted.usedIdentifiers.sorted()
            let inputPairs = inputs.map { (name: $0, type: ctx.paramTypeByName[$0] ?? "_") }
            // Inputs must be concretely typed AND liftable (the scrutinee/operands
            // must round-trip the ABI; a generic/native-typed input is rejected).
            guard inputPairs.allSatisfy({ $0.type != "_" && typeIsLiftable($0.type) }),
                  typeIsLiftable(lifted.resultType) else {
                shellSteps.append(.nativeStatement(stmt.text))
                continue
            }
            // The binding is only worth lifting if its result is consumed later
            // (a live-out); otherwise lifting a dead computation buys nothing.
            let liveAfter = ctx.usesAfter(idx + 1)
            guard liveAfter.contains(lifted.boundName) else {
                shellSteps.append(.nativeStatement(stmt.text))
                continue
            }
            let label = "branch\(liftIndex)"
            liftIndex += 1
            let fragName = "_sp_\(ctx.base)_\(label)"
            let fragment = SplitPlan.PureFragment(
                name: fragName,
                inputs: inputPairs,
                // The fragment computes the branch value and returns it; the shell
                // binds it under the ORIGINAL name so downstream native code is
                // unchanged.
                outputs: [(name: lifted.boundName, type: lifted.resultType)],
                bodyStatements: ["return (\(lifted.valueText))"])
            fragments.append(fragment)
            shellSteps.append(.fragmentCall(fragment: fragment))
            liftedAny = true
        }

        guard liftedAny, items.contains(where: { $0.isNative }) else { return nil }
        return makePlan(ctx, fragments: fragments, shellSteps: shellSteps)
    }

    /// A liftable `let <name> = switch/if {…}` (value-producing branch) bound to a
    /// single local. Returns the bound name, the concrete result type, the value
    /// expression text (the whole switch/if), and the identifiers it reads.
    private struct LiftedBranch {
        let boundName: String
        let resultType: String
        let valueText: String
        let usedIdentifiers: Set<String>
    }

    private func liftableBranchBinding(_ stmt: CodeBlockItemSyntax,
                                       known: [String: String]) -> LiftedBranch? {
        // Only `let x = <switch/if expr>` with a single simple binding.
        guard let varDecl = stmt.item.as(DeclSyntax.self)?.as(VariableDeclSyntax.self),
              varDecl.bindings.count == 1,
              let binding = varDecl.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let initExpr = binding.initializer?.value else { return nil }

        // The initializer must be an expression-switch or expression-if whose every
        // arm yields a single value of one common concrete type.
        let armValues: [ExprSyntax]?
        if let sw = initExpr.as(SwitchExprSyntax.self) {
            armValues = switchArmValues(sw)
        } else if let ifE = initExpr.as(IfExprSyntax.self) {
            armValues = ifExprArmValues(ifE)
        } else {
            return nil
        }
        guard let resultType = inferBranchExprType(armValues: armValues, known: known) else { return nil }

        // Prove the WHOLE branch is pure (scrutinee + all arm values). Any native
        // symbol / native callee / self / await / try / mutation anywhere → bail.
        let scanner = PurityScanner(registry: registry, nativeCalleeNames: nativeCalleeNames)
        scanner.walk(initExpr)
        guard scanner.isPure else { return nil }

        return LiftedBranch(
            boundName: name,
            resultType: resultType,
            valueText: initExpr.trimmedDescription,
            usedIdentifiers: scanner.identifiers)
    }

    // MARK: - Helpers

    private func simpleName(of record: FunctionRecord) -> String {
        record.id.split(separator: ".").last.map(String.init) ?? record.id
    }

    /// A type usable as a WASM-fragment input/output: it must not name any
    /// `mustStayNative` symbol (e.g. `URLAuthenticationChallenge`, `UIView`),
    /// which would not exist in the standalone WASM module. Decomposes generics
    /// and tuples (`[Foo]`, `(A, B)`, `Foo?`) by scanning each identifier token.
    private func typeIsLiftable(_ type: String) -> Bool {
        var ident = ""
        func flush() -> Bool {
            defer { ident = "" }
            guard !ident.isEmpty else { return true }
            return registry.entry(for: ident)?.tier != .mustStayNative
        }
        for ch in type {
            if ch.isLetter || ch.isNumber || ch == "_" { ident.append(ch) }
            else { if !flush() { return false } }
        }
        return flush()
    }

    /// Best-effort concrete types of local bindings introduced by a statement.
    /// Only confident cases are returned (explicit annotation, a `Type(...)`
    /// constructor, or a literal); anything ambiguous is omitted so we never
    /// annotate a fragment input with a wrong type.
    private func inferredLocalTypes(in stmt: CodeBlockItemSyntax,
                                    known: [String: String]) -> [(String, String)] {
        guard let varDecl = stmt.item.as(DeclSyntax.self)?.as(VariableDeclSyntax.self) else { return [] }
        var out: [(String, String)] = []
        for binding in varDecl.bindings {
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            // (1) Explicit annotation wins.
            if let t = binding.typeAnnotation?.type.trimmedDescription {
                out.append((ident, t)); continue
            }
            guard let initExpr = binding.initializer?.value else { continue }
            if let t = inferExprType(initExpr, known: known) { out.append((ident, t)) }
        }
        return out
    }

    /// Best-effort concrete type of a value expression (only confident cases).
    private func inferExprType(_ expr: ExprSyntax, known: [String: String]) -> String? {
        // `Foo(...)` constructor → Foo (UpperCamelCase callee only).
        if let call = expr.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
           let first = callee.first, first.isUppercase {
            return callee
        }
        // `<seq>.reduce(<initial>, …)` → the type of the initial value (a very
        // common pure aggregation that otherwise yields an un-typeable fragment).
        // Only fires when the initial argument's type is itself confidently known
        // (a literal or a known-typed identifier), so the fragment stays sound.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "reduce",
           let initialArg = call.arguments.first?.expression {
            if let t = inferExprType(initialArg, known: known) { return t }
        }
        // Literals.
        if expr.is(IntegerLiteralExprSyntax.self) { return "Int" }
        if expr.is(FloatLiteralExprSyntax.self) { return "Double" }
        if expr.is(StringLiteralExprSyntax.self) { return "String" }
        if expr.is(BooleanLiteralExprSyntax.self) { return "Bool" }
        // Homogeneous scalar/string ARRAY literal → `[Element]` (Codable, so the
        // fragment round-trips the ABI). Only when EVERY element confidently infers
        // to the SAME scalar/string type — `[0.25, 0.5]` → `[Double]`,
        // `["a","b"]` → `[String]`. A heterogeneous / non-scalar array stays nil
        // (generic/native, safe). (optimization-sweep #3 — these were abandoned.)
        if let arr = expr.as(ArrayExprSyntax.self), !arr.elements.isEmpty {
            var elemType: String?
            for el in arr.elements {
                guard let t = inferExprType(el.expression, known: known), isScalarOrString(t) else {
                    elemType = nil; break
                }
                if let e = elemType { if e != t { elemType = nil; break } } else { elemType = t }
            }
            if let elemType { return "[\(elemType)]" }
        }
        // Bare identifier → its already-known type (cross-statement threading: a
        // `let b = a` where `a` was typed earlier). Lowercase value names only.
        if let ref = expr.as(DeclReferenceExprSyntax.self),
           let t = known[ref.baseName.text] { return t }
        // Member access `x.count`/`x.isEmpty`/known String members on a typed base.
        // Only the confidently-Int/Bool/String stdlib members, so the fragment
        // type-checks; anything else returns nil (→ generic/native, safe).
        if let member = expr.as(MemberAccessExprSyntax.self) {
            if let t = inferMemberType(member, known: known) { return t }
        }
        // Ternary `cond ? a : b` → the shared concrete type of the two branches
        // (a very common pure shape in mixed bodies). Only when both sides agree.
        if let tern = expr.as(TernaryExprSyntax.self) {
            let t1 = inferExprType(tern.thenExpression, known: known)
            let t2 = inferExprType(tern.elseExpression, known: known)
            if let t1, t1 == t2 { return t1 }
            // One literal side pins the type if the other is a same-kind value.
            if let t1, t2 == nil, isScalarOrString(t1) { return t1 }
            if let t2, t1 == nil, isScalarOrString(t2) { return t2 }
        }
        // Expression-`switch` / `if` (Swift 5.9 `let x = switch s { ... }`): the
        // result type is the common concrete type of every arm's value. Only when
        // ALL arms agree on a confidently-inferred scalar/string type — otherwise
        // nil (generic/native, safe). This is what lets switch-arm value lifts
        // produce an ABI-eligible (executable) fragment. (optimization-sweep #1)
        if let sw = expr.as(SwitchExprSyntax.self) {
            return inferBranchExprType(armValues: switchArmValues(sw), known: known)
        }
        if let ifE = expr.as(IfExprSyntax.self) {
            return inferBranchExprType(armValues: ifExprArmValues(ifE), known: known)
        }
        // Parenthesised → unwrap.
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression {
            return inferExprType(inner, known: known)
        }
        // `!x` → Bool.
        if let pre = expr.as(PrefixOperatorExprSyntax.self), pre.operator.text == "!" { return "Bool" }
        // Comparison / boolean operators → Bool; arithmetic → numeric of a known operand.
        if let seq = expr.as(SequenceExprSyntax.self) {
            var sawCmp = false, sawArith = false, sawStr = false
            for el in seq.elements {
                if let op = el.as(BinaryOperatorExprSyntax.self)?.operator.text {
                    switch op {
                    case "==", "!=", "<", ">", "<=", ">=", "&&", "||": sawCmp = true
                    case "+": sawArith = true
                    case "-", "*", "/", "%": sawArith = true
                    default: return nil
                    }
                } else if el.is(StringLiteralExprSyntax.self) { sawStr = true }
            }
            if sawCmp { return "Bool" }
            if sawArith {
                let numericTypes = ["Int","Double","Float","CGFloat","Decimal","Int64","Int32","UInt","TimeInterval"]
                for el in seq.elements {
                    if let ref = el.as(DeclReferenceExprSyntax.self), let t = known[ref.baseName.text],
                       numericTypes.contains(t) {
                        return t
                    }
                    if el.is(FloatLiteralExprSyntax.self) { return "Double" }
                    if let ref = el.as(DeclReferenceExprSyntax.self), known[ref.baseName.text] == "String" { return "String" }
                    // A non-trivial operand (e.g. `items.count`, a member access) whose
                    // own type confidently infers numeric pins the arithmetic type. This
                    // is what lets `let total = items.count + 1` infer `Int` (rather than
                    // `_`) so a legitimate Int live-out is liftable, NOT a generic blocked
                    // by the operator-position check below.
                    if !el.is(BinaryOperatorExprSyntax.self),
                       let t = inferExprType(ExprSyntax(el), known: known) {
                        if numericTypes.contains(t) { return t }
                        if t == "String" { return "String" }
                    }
                }
                if sawStr { return "String" }
                let intOnly = seq.elements.allSatisfy {
                    $0.is(IntegerLiteralExprSyntax.self) || $0.is(BinaryOperatorExprSyntax.self)
                }
                return intOnly ? "Int" : nil
            }
        }
        return nil
    }

    /// The single value expression each `switch` arm yields, when EVERY arm is a
    /// single-expression body (`case .x: value`). Returns nil if any arm has a
    /// multi-statement body / no value (then we can't type the result soundly).
    private func switchArmValues(_ sw: SwitchExprSyntax) -> [ExprSyntax]? {
        var out: [ExprSyntax] = []
        for arm in sw.cases {
            guard case let .switchCase(c) = arm else { return nil }   // @unknown / #if → bail
            guard let v = singleValueOfBlock(c.statements) else { return nil }
            out.append(v)
        }
        return out.isEmpty ? nil : out
    }

    /// The value expressions of an expression-`if` (`if c { a } else { b }`),
    /// flattening `else if` chains. nil if any branch isn't a single value or the
    /// chain isn't exhaustive (no final `else`).
    private func ifExprArmValues(_ ifE: IfExprSyntax) -> [ExprSyntax]? {
        var out: [ExprSyntax] = []
        guard let thenV = singleValueOfBlock(ifE.body.statements) else { return nil }
        out.append(thenV)
        switch ifE.elseBody {
        case let .codeBlock(block)?:
            guard let elseV = singleValueOfBlock(block.statements) else { return nil }
            out.append(elseV)
        case let .ifExpr(nested)?:
            guard let rest = ifExprArmValues(nested) else { return nil }
            out.append(contentsOf: rest)
        case .none:
            return nil   // no else → not an exhaustive value expression
        }
        return out
    }

    /// The single trailing value expression of a code block, or nil if the block
    /// isn't exactly one expression statement.
    private func singleValueOfBlock(_ stmts: CodeBlockItemListSyntax) -> ExprSyntax? {
        guard stmts.count == 1, let only = stmts.first else { return nil }
        if case let .expr(e) = only.item { return e }
        return nil
    }

    /// The common concrete type of a set of branch value expressions, when ALL of
    /// them confidently infer to the SAME scalar/string type. nil otherwise.
    private func inferBranchExprType(armValues: [ExprSyntax]?, known: [String: String]) -> String? {
        guard let armValues, !armValues.isEmpty else { return nil }
        var common: String?
        for v in armValues {
            guard let t = inferExprType(v, known: known), isScalarOrString(t) else { return nil }
            if let c = common { if c != t { return nil } } else { common = t }
        }
        return common
    }

    /// Whether a type is a scalar/string we can confidently round-trip as a
    /// fragment value (used to pin a ternary type from one literal branch).
    private func isScalarOrString(_ t: String) -> Bool {
        ["Int","Double","Float","CGFloat","Decimal","Int64","Int32","UInt",
         "TimeInterval","Bool","String"].contains(t)
    }

    /// Confident concrete type for a `base.member` access where `base`'s type is
    /// known: the small set of stdlib value-typed members the fragment can rely
    /// on. Conservative — returns nil for anything else.
    private func inferMemberType(_ member: MemberAccessExprSyntax, known: [String: String]) -> String? {
        let name = member.declName.baseName.text
        // Type-independent members that are always Int/Bool on a value collection
        // or string. `.count`/`.isEmpty` are universal on Collection/String.
        switch name {
        case "count": return "Int"
        case "isEmpty": return "Bool"
        default: break
        }
        // Base-type-specific members (only when the base resolves to a known type).
        guard let base = member.base else { return nil }
        let baseType: String?
        if let ref = base.as(DeclReferenceExprSyntax.self) { baseType = known[ref.baseName.text] }
        else { baseType = inferExprType(base, known: known) }
        guard let bt = baseType else { return nil }
        if bt == "String" {
            switch name {
            case "uppercased", "lowercased", "reversed": return "String"
            case "hasPrefix", "hasSuffix": return "Bool"
            default: return nil
            }
        }
        if ["Int","Double","Decimal","Bool","Float","Int64","Int32","UInt"].contains(bt) {
            switch name {
            case "description": return "String"
            default: return nil
            }
        }
        return nil
    }

    /// Map an arbitrary symbol fragment to a valid Swift identifier component:
    /// non-`[A-Za-z0-9_]` characters become `_`. Keeps generated fragment names
    /// compilable for closures (`closure@L318`) and accessors (`x.get`).
    private func sanitizeIdentifier(_ s: String) -> String {
        let mapped = s.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "_") ? ch : "_"
        }
        let out = String(mapped)
        return out.isEmpty ? "frag" : out
    }

    /// Does a statement reference a `mustStayNative` symbol, OR call a native
    /// callee? (Bridgeable and wasm-safe symbols are liftable, so only tier-1 and
    /// native callees keep a statement in the shell.)
    private func statementTouchesMustStayNative(_ stmt: CodeBlockItemSyntax) -> Bool {
        let scanner = NativeStatementScanner(registry: registry, nativeCalleeNames: nativeCalleeNames)
        scanner.walk(stmt)
        return scanner.touchedMustStayNative
    }

    /// A statement that cannot be lifted into a standalone WASM value fragment by
    /// Strategy A, independent of nativeness: it references `self`/`super` (no such
    /// value in a fragment) or it is an assignment/in-out mutation (a side effect,
    /// not a value). Keeping these in the shell is what makes splitting `init` and
    /// computed-property bodies sound (their bodies are full of `self.x = …`).
    private func statementIsShellOnly(_ stmt: CodeBlockItemSyntax) -> Bool {
        let scanner = ShellOnlyScanner()
        scanner.walk(stmt)
        return scanner.shellOnly
    }

    private func isControlFlow(_ stmt: CodeBlockItemSyntax) -> Bool {
        switch stmt.item {
        case .stmt(let s):
            if s.is(ReturnStmtSyntax.self) || s.is(ThrowStmtSyntax.self)
                || s.is(GuardStmtSyntax.self) || s.is(ForStmtSyntax.self)
                || s.is(WhileStmtSyntax.self) || s.is(RepeatStmtSyntax.self)
                || s.is(BreakStmtSyntax.self) || s.is(ContinueStmtSyntax.self)
                || s.is(DeferStmtSyntax.self) || s.is(DoStmtSyntax.self) {
                return true
            }
            // SwiftSyntax wraps a STATEMENT-POSITION `if`/`switch` (used for its side
            // effects / control flow, e.g. `if x == 0 { return }`) in an
            // `ExpressionStmtSyntax` whose inner expression is an `IfExpr`/`SwitchExpr`
            // — NOT the `.expr(IfExprSyntax)` shape below (that's only an `if` parsed
            // as a pure expression). Without unwrapping it here, such an `if` was NOT
            // flagged as control flow, so Strategy A LIFTED it — including any early
            // `return`/`break` inside its branches — into a value fragment, producing
            // an unsound fragment (a fragment whose body returns the wrong shape /
            // moves control flow into WASM). Treat the wrapped form as control flow.
            if let exprStmt = s.as(ExpressionStmtSyntax.self) {
                return exprStmt.expression.is(IfExprSyntax.self)
                    || exprStmt.expression.is(SwitchExprSyntax.self)
            }
            return false
        case .expr(let e):
            // `if`/`switch` used as expressions/statements straddle control flow.
            return e.is(IfExprSyntax.self) || e.is(SwitchExprSyntax.self)
        default:
            return false
        }
    }

    /// Best-effort def/use for a top-level statement.
    private func defUse(of stmt: CodeBlockItemSyntax) -> (defs: Set<String>, uses: Set<String>) {
        let analyzer = DefUseAnalyzer()
        analyzer.walk(stmt)
        return (analyzer.defs, analyzer.uses.subtracting(analyzer.defs))
    }
}

// MARK: - Syntax helpers

/// The body + signature info the splitter needs for one declaration.
struct DeclInfo {
    var foundBody: CodeBlockItemListSyntax?
    var parameters: [(name: String, type: String)] = []
    var signatureText: String?
    var returnType: String = "Void"
    var isAsync = false
    var isThrows = false
}

/// Per-file index of every splittable declaration, built in a SINGLE tree walk
/// and reused across all of the file's mixed functions. This replaces the old
/// per-function full-tree `FunctionBodyFinder.walk` — on giant files (wire-ios:
/// 25k mixed functions over 5.8k files) re-walking per function was the watchdog
/// stall. Lookup is O(1) by start line (precise for funcs/methods/inits/computed
/// props/accessors/closures), with a simple-signature fallback for plain funcs.
public final class DeclarationIndex: SyntaxVisitor {
    private var byLine: [Int: DeclInfo] = [:]
    private var bySignature: [String: DeclInfo] = [:]
    private let converter: SourceLocationConverter

    public init(tree: SourceFileSyntax) {
        self.converter = SourceLocationConverter(fileName: "", tree: tree)
        super.init(viewMode: .sourceAccurate)
        walk(tree)
    }

    /// Convenience: parse `source` and index it (for callers without SwiftParser).
    public convenience init(source: String) {
        self.init(tree: Parser.parse(source: source))
    }

    /// A populated finder-like value for the declaration at `startLine` (preferred)
    /// or matching `simpleName`. Returns nil if none / the body is empty.
    func lookup(startLine: Int, simpleName: String) -> DeclInfo? {
        if let info = byLine[startLine], info.foundBody != nil { return info }
        if let info = bySignature[simpleName], info.foundBody != nil { return info }
        return nil
    }

    private func line(of node: some SyntaxProtocol) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }
    private func record(_ info: DeclInfo, line: Int, signature: String?) {
        if byLine[line] == nil { byLine[line] = info }
        if let signature, bySignature[signature] == nil { bySignature[signature] = info }
    }

    override public func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let labels = node.signature.parameterClause.parameters.map { "\($0.firstName.text):" }.joined()
        let sig = "\(node.name.text)(\(labels))"
        var info = DeclInfo()
        info.foundBody = node.body?.statements
        info.parameters = node.signature.parameterClause.parameters.map { param in
            ((param.secondName?.text ?? param.firstName.text), param.type.trimmedDescription)
        }
        info.signatureText = node.name.text + node.signature.trimmedDescription
        if let ret = node.signature.returnClause?.type.trimmedDescription { info.returnType = ret }
        let effects = node.signature.effectSpecifiers
        info.isAsync = effects?.asyncSpecifier != nil
        info.isThrows = effects?.throwsClause != nil
        record(info, line: line(of: node), signature: sig)
        return .visitChildren
    }

    override public func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        var info = DeclInfo()
        info.foundBody = node.body?.statements
        info.parameters = node.signature.parameterClause.parameters.map { param in
            ((param.secondName?.text ?? param.firstName.text), param.type.trimmedDescription)
        }
        info.signatureText = "init" + node.signature.trimmedDescription
        let effects = node.signature.effectSpecifiers
        info.isAsync = effects?.asyncSpecifier != nil
        info.isThrows = effects?.throwsClause != nil
        record(info, line: line(of: node), signature: nil)
        return .visitChildren
    }

    override public func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let accessor = binding.accessorBlock else { continue }
            switch accessor.accessors {
            case .getter(let codeBlock):
                var info = DeclInfo()
                info.foundBody = codeBlock
                info.returnType = binding.typeAnnotation?.type.trimmedDescription ?? "Void"
                info.signatureText = binding.pattern.trimmedDescription
                // Computed property's record start line is the BINDING's line.
                record(info, line: line(of: binding), signature: nil)
            case .accessors(let list):
                for acc in list where acc.body != nil {
                    // Only `get` accessors are safe to split (set/willSet/didSet
                    // expose an untypeable implicit `newValue`).
                    guard acc.accessorSpecifier.text == "get" else { continue }
                    var info = DeclInfo()
                    info.foundBody = acc.body?.statements
                    info.returnType = binding.typeAnnotation?.type.trimmedDescription ?? "Void"
                    info.signatureText = binding.pattern.trimmedDescription + ".get"
                    record(info, line: line(of: acc), signature: nil)
                }
            }
        }
        return .visitChildren
    }

    override public func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        var info = DeclInfo()
        info.foundBody = node.statements
        // Typed (`{ (x: Int) in }`) or shorthand (`{ x in }`) params; shorthand →
        // `_` type (the no-capture gate still excludes runs needing an untyped
        // value). No explicit list → `$0`/`$1` treated as captures (safe).
        if let sig = node.signature, let clause = sig.parameterClause {
            if let typed = clause.as(ClosureParameterClauseSyntax.self) {
                info.parameters = typed.parameters.map { p in
                    ((p.secondName ?? p.firstName).text, p.type?.trimmedDescription ?? "_")
                }
            } else if let shorthand = clause.as(ClosureShorthandParameterListSyntax.self) {
                info.parameters = shorthand.map { ($0.name.text, "_") }
            }
        }
        record(info, line: line(of: node), signature: nil)
        return .visitChildren
    }
}

/// Collects lowercase-initial identifiers used in VALUE position (a value the
/// expression reads), excluding type names, the member name in `a.member`, and
/// the special `$N` shorthand / projected values. Used by Strategy A's no-capture
/// gate so a lifted fragment never references an undeclared captured local.
final class ValueIdentifierScanner: SyntaxVisitor {
    private(set) var valueIdentifiers: Set<String> = []
    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        // Candidate value locals: lowercase-initial bare identifiers, plus `$N`
        // closure shorthand (an implicit param of unknown type → treat as a
        // capture so the run stays in the shell rather than emitting an
        // uncompilable fragment that references `$0`). `self`/`super`/Types excluded.
        if name.hasPrefix("$") {
            valueIdentifiers.insert(name)
        } else if let first = name.first, first.isLowercase, name != "self", name != "super" {
            valueIdentifiers.insert(name)
        }
        return .visitChildren
    }
    // The member name in `base.member` is a label, not a free value identifier.
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if let base = node.base { walk(base) }
        return .skipChildren
    }
    // A function/method call. A BARE LOWERCASE callee (`foo(...)`) is either a
    // local helper or an implicit-`self` instance method — neither exists in a
    // standalone WASM fragment, so we flag it as a value identifier (→ the run is
    // kept native unless `foo` is an available local). An UpperCamelCase callee
    // (`MockView(...)`, `Decimal(...)`) is a Type/global symbol and is allowed.
    // For a member callee (`a.foo(...)`) we walk only the base (`a`).
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = callee.baseName.text
            if name.hasPrefix("$") || (name.first?.isLowercase ?? false) {
                valueIdentifiers.insert(name)
            }
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base {
            walk(base)
        }
        for arg in node.arguments { walk(arg.expression) }
        if let trailing = node.trailingClosure { walk(trailing) }
        for additional in node.additionalTrailingClosures { walk(additional.closure) }
        return .skipChildren
    }
}

/// Reports GENUINELY-FREE lowercase value identifiers in a host-projection
/// fragment body — closure-scope aware — so a pure higher-order transform over a
/// projected reactive read (`scores.map { $0 * 2 }`, `items.filter { $0 > n }`,
/// `xs.reduce(0) { acc, x in acc + x }`) can be lifted, while a real captured
/// local (`!cancelled`) still keeps the member native.
///
/// A name is NOT free if it is:
///   * in `preBound` (a projected reactive read, the member's own param, or a
///     top-level local the body binds), OR
///   * bound by an enclosing CLOSURE in scope — a named closure parameter, OR a
///     `$N` shorthand used inside a closure (the closure implicitly binds `$0…`),
///     OR a `let`/`var`/`for`/`if let`/`case let` declared inside a closure body.
///
/// SAFETY (cardinal rule — never a false split): this only ever REMOVES a name
/// from the free set when it is provably bound (a closure param/shorthand or a
/// local binding inside the closure where it is read). Anything it cannot prove
/// bound stays FREE → the member stays native. So it can only widen coverage to
/// genuinely-closed transforms; it never lets an unbound capture through. A `$N`
/// at top level (outside any closure — not valid Swift in a getter body, but
/// defended anyway) is treated as free → keeps the member native.
final class HostProjectionFreeIdentifierScanner: SyntaxVisitor {
    private(set) var freeIdentifiers: Set<String> = []
    /// Names bound before/around this body (projected reads, member params, the
    /// body's top-level locals). Always in-scope.
    private let preBound: Set<String>
    /// Stack of name-sets bound by enclosing closure scopes (params + locals).
    private var closureScopes: [Set<String>] = []
    /// How many closures we are currently inside (so `$N` shorthand is bound).
    private var closureDepth = 0

    init(preBound: Set<String>) {
        self.preBound = preBound
        super.init(viewMode: .sourceAccurate)
    }

    /// Is `name` bound by any enclosing closure scope?
    private func boundInClosureScope(_ name: String) -> Bool {
        closureScopes.contains { $0.contains(name) }
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        record(node.baseName.text)
        return .visitChildren
    }

    private func record(_ name: String) {
        // `$N` shorthand: bound iff we are inside at least one closure scope.
        if name.hasPrefix("$") {
            if closureDepth == 0 { freeIdentifiers.insert(name) }
            return
        }
        guard let first = name.first, first.isLowercase, name != "self", name != "super"
        else { return }   // Types / `self` / `super` handled by other scanners.
        if preBound.contains(name) { return }
        if boundInClosureScope(name) { return }
        freeIdentifiers.insert(name)
    }

    // The member name in `base.member` is a label, not a free value identifier —
    // walk only the base. (`x.map`, `x.count`.)
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if let base = node.base { walk(base) }
        return .skipChildren
    }

    // A bare lowercase callee (`foo(...)`) is a local helper / implicit-self
    // method that won't exist in the fragment — record it (→ free unless bound).
    // For a member callee (`a.foo(...)`) walk only the base.
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            record(callee.baseName.text)
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                  let base = member.base {
            walk(base)
        }
        for arg in node.arguments { walk(arg.expression) }
        if let trailing = node.trailingClosure { walk(trailing) }
        for additional in node.additionalTrailingClosures { walk(additional.closure) }
        return .skipChildren
    }

    // Enter a closure scope: collect its parameter names (and `let`/`var`/binding
    // names declared inside its body) before walking its statements, so reads of
    // those names inside are correctly treated as bound (not free).
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        var scope: Set<String> = []
        if let sig = node.signature, let clause = sig.parameterClause {
            if let shorthand = clause.as(ClosureShorthandParameterListSyntax.self) {
                for p in shorthand { scope.insert(p.name.text) }
            } else if let typed = clause.as(ClosureParameterClauseSyntax.self) {
                for p in typed.parameters { scope.insert((p.secondName ?? p.firstName).text) }
            }
        }
        // Any binding introduced anywhere inside the closure body is in-scope for
        // the closure (over-approximate forward scope — safe, only adds bound names).
        let du = DefUseAnalyzer()
        du.walk(node.statements)
        scope.formUnion(du.defs)

        closureScopes.append(scope)
        closureDepth += 1
        // Walk the signature capture list / params and the body within this scope.
        walk(node.statements)
        closureDepth -= 1
        closureScopes.removeLast()
        return .skipChildren
    }
}

/// Rewrites `self.<prop>` (for a projected reactive prop) into the bare value
/// name `<prop>` so a host-projected fragment body refers to its parameter, not
/// `self`. Used only by `FunctionSplitter.strategyHostProjection`; the caller
/// then verifies the rewritten body is fully self-free (this rewriter only
/// touches the projected props, so any OTHER `self.` access survives and trips
/// the `ShellOnlyScanner` gate → the member stays native).
final class SelfReactiveReadRewriter: SyntaxRewriter {
    let projectedNames: Set<String>
    init(projectedNames: Set<String>) {
        self.projectedNames = projectedNames
        super.init()
    }

    /// Rewrite one statement; returns nil only on an unexpected node-type mismatch.
    func rewriteItem(_ item: CodeBlockItemSyntax) -> CodeBlockItemSyntax? {
        visit(item).as(CodeBlockItemSyntax.self)
    }

    override func visit(_ node: MemberAccessExprSyntax) -> ExprSyntax {
        // `self.<prop>` where <prop> is projected → bare `<prop>` (preserve trivia).
        if let base = node.base?.as(DeclReferenceExprSyntax.self),
           base.baseName.text == "self",
           projectedNames.contains(node.declName.baseName.text) {
            let name = node.declName.baseName.text
            let ref = DeclReferenceExprSyntax(baseName: .identifier(name))
                .with(\.leadingTrivia, node.leadingTrivia)
                .with(\.trailingTrivia, node.trailingTrivia)
            return ExprSyntax(ref)
        }
        // Recurse so a nested `self.<prop>` inside a larger member chain is handled,
        // and the member name itself is never rewritten (it is a label).
        return super.visit(node)
    }
}

/// Defense-in-depth for host-projection: flags a known stdlib MUTATING method
/// call whose receiver is a projected reactive prop (now a by-value `let`
/// parameter in the fragment). Such a call won't compile (mutating a `let`) and
/// would silently drop the mutation, so the splitter refuses to realize the
/// member. Mirrors the extractor's `ReactiveWriteScanner.mutatingMethods` for the
/// bounded scalar/String/scalar-array projectable universe.
final class ProjectedMutationScanner: SyntaxVisitor {
    let projectedNames: Set<String>
    private(set) var mutates = false
    static let mutatingMethods: Set<String> = [
        "toggle", "negate", "round", "formRemainder", "formTruncatingRemainder",
        "formSquareRoot", "addProduct",
        "append", "insert", "remove", "removeAll", "removeFirst", "removeLast",
        "removeSubrange", "removeRandomElement", "popLast", "popFirst",
        "replaceSubrange", "reserveCapacity", "sort", "reverse", "shuffle",
        "swapAt", "partition", "update", "subtract", "formUnion", "formIntersection",
        "formSymmetricDifference", "write",
    ]
    init(projectedNames: Set<String>) {
        self.projectedNames = projectedNames
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           let base = member.base?.as(DeclReferenceExprSyntax.self),
           projectedNames.contains(base.baseName.text),
           Self.mutatingMethods.contains(member.declName.baseName.text) {
            mutates = true
        }
        return .visitChildren
    }
}

/// Flags a top-level statement that must stay in the shell because it cannot
/// become a standalone WASM value fragment: it touches `self`/`super`, or it is
/// an assignment / in-out mutation.
final class ShellOnlyScanner: SyntaxVisitor {
    private(set) var shellOnly = false
    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if node.baseName.text == "self" || node.baseName.text == "super" { shellOnly = true }
        return .visitChildren
    }
    // `super.foo()` parses as SuperExprSyntax, NOT a DeclReferenceExpr — must be
    // caught here too (a `super` call is native dispatch; lifting it is unsafe).
    override func visit(_ node: SuperExprSyntax) -> SyntaxVisitorContinueKind {
        shellOnly = true; return .skipChildren
    }
    // `await` / `try` are effect-bearing: their placement must be preserved in the
    // shell, and they cannot run inside a synchronous, non-throwing WASM fragment.
    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
        shellOnly = true; return .skipChildren
    }
    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        shellOnly = true; return .skipChildren
    }
    override func visit(_ node: AssignmentExprSyntax) -> SyntaxVisitorContinueKind {
        shellOnly = true; return .skipChildren
    }
    override func visit(_ node: InOutExprSyntax) -> SyntaxVisitorContinueKind {
        shellOnly = true; return .skipChildren
    }
    // A binding declared WITHOUT an initializer (`var x: T`) is a forward
    // declaration mutated later by native code — not a pure value computation.
    // Lifting it produces a fragment that returns an uninitialised variable (won't
    // compile), so keep such declarations in the shell.
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings where binding.initializer == nil && binding.accessorBlock == nil {
            shellOnly = true
        }
        return .visitChildren
    }
}

/// Scans a statement subtree for any reference to a `mustStayNative` symbol.
final class NativeStatementScanner: SyntaxVisitor {
    let registry: NativeRegistry
    let nativeCalleeNames: Set<String>
    private(set) var touchedMustStayNative = false

    init(registry: NativeRegistry, nativeCalleeNames: Set<String> = []) {
        self.registry = registry
        self.nativeCalleeNames = nativeCalleeNames
        super.init(viewMode: .sourceAccurate)
    }

    private func check(_ name: String) {
        if registry.entry(for: name)?.tier == .mustStayNative { touchedMustStayNative = true }
        if nativeCalleeNames.contains(name) { touchedMustStayNative = true }
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        check(node.baseName.text); return .visitChildren
    }
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        check(node.name.text); return .visitChildren
    }
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if let base = node.base?.trimmedDescription { check(base) }
        return .visitChildren
    }
    // Catch `nativeHelper(...)` calls whose callee is a known native function.
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let ident = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            check(ident.baseName.text)
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            check(member.declName.baseName.text)
        }
        return .visitChildren
    }
}

/// Best-effort def/use analyzer for a single top-level statement. `defs` are the
/// names introduced by `let`/`var` pattern bindings; `uses` are identifiers read
/// anywhere in the statement.
final class DefUseAnalyzer: SyntaxVisitor {
    private(set) var defs: Set<String> = []
    private(set) var uses: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            collectPatternNames(binding.pattern, into: &defs)
        }
        return .visitChildren
    }

    // Optional bindings (`guard let x`, `if let x = …`) introduce names too —
    // tracking them keeps the no-capture gate accurate (a later run reading `x`
    // must see it as a def, not a captured local).
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        collectPatternNames(node.pattern, into: &defs)
        return .visitChildren
    }
    // `for x in …` and `case let .foo(x)` bindings.
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        collectPatternNames(node.pattern, into: &defs)
        return .visitChildren
    }
    override func visit(_ node: ValueBindingPatternSyntax) -> SyntaxVisitorContinueKind {
        collectPatternNames(node.pattern, into: &defs)
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        uses.insert(node.baseName.text)
        return .visitChildren
    }

    private func collectPatternNames(_ pattern: PatternSyntax, into set: inout Set<String>) {
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            set.insert(ident.identifier.text)
        } else if let tuple = pattern.as(TuplePatternSyntax.self) {
            for el in tuple.elements { collectPatternNames(el.pattern, into: &set) }
        } else if let bind = pattern.as(ValueBindingPatternSyntax.self) {
            collectPatternNames(bind.pattern, into: &set)
        }
        // `_` wildcard / expression patterns introduce no bindings.
    }
}

/// Collects the names that a statement subtree REASSIGNS (mutates after their
/// declaration): the LHS identifier of a plain `=` assignment, of a compound
/// assignment (`+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`,
/// `&&=`, `||=`), and of an in-out `&x` argument. A `let`/`var` DECLARATION is
/// NOT a mutation (it introduces a fresh binding). Used to keep a lifted run
/// native when a downstream statement would assign to one of its `let`-bound
/// live-outs (which the native shell cannot do). Conservative: only the simple
/// base identifier of an assignable l-value is recorded (`x`, `x.y` → `x`,
/// `x[i]` → `x`); anything more exotic is OVER-recorded (every identifier in the
/// l-value), never under-recorded — see `recordMutation` (BUG R2-#44).
final class MutatedNameScanner: SyntaxVisitor {
    private(set) var mutated: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    /// The base identifier of an l-value expression (`x` → x, `x.y.z` → x,
    /// `x[i]` → x, `(x)` → x). Returns nil for a non-identifier-rooted l-value.
    private func baseName(of expr: ExprSyntax) -> String? {
        if let ref = expr.as(DeclReferenceExprSyntax.self) { return ref.baseName.text }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            return baseName(of: base)
        }
        if let sub = expr.as(SubscriptCallExprSyntax.self) { return baseName(of: sub.calledExpression) }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression {
            return baseName(of: inner)
        }
        return nil
    }

    /// Record the mutated name(s) for an assignable l-value `expr`. Resolves the
    /// simple base identifier when possible (`x`, `x.y`, `x[i]`, `(x)` → `x`).
    /// SOUNDNESS (conservative-by-FAILING — BUG R2-#44): when the base does NOT
    /// resolve to a single identifier (an exotic l-value the resolver can't reduce
    /// — a tuple-pattern assignment `(a, b) = …`, a subscript whose base is a call
    /// result, etc.), record ALL identifiers appearing in the l-value rather than
    /// recording NOTHING. Under-recording a mutated live-out lets a lifted run ship
    /// a `let`-bound output that a downstream branch then reassigns → the generated
    /// shell would not compile ('cannot assign to value: x is a let constant'). The
    /// liftability gate is build-safe = demote-safe, so OVER-recording at worst
    /// keeps a run native (no lost correctness); UNDER-recording ships a broken
    /// build. We therefore err toward over-recording.
    private func recordMutation(of expr: ExprSyntax) {
        if let name = baseName(of: expr) {
            mutated.insert(name)
            return
        }
        // Fallback: an l-value whose base is not a simple identifier. Conservatively
        // record EVERY identifier the l-value mentions (so any of them being a
        // lifted-run output keeps that run native).
        let ids = IdentifierCollector()
        ids.walk(expr)
        mutated.formUnion(ids.identifiers)
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (i, el) in elements.enumerated() where i > 0 {
            let isPlainAssign = el.is(AssignmentExprSyntax.self)
            // A compound-assignment operator is a binary operator whose text ends in
            // `=` but is NOT a comparison (`==`, `!=`, `<=`, `>=`).
            let isCompoundAssign: Bool = {
                guard let op = el.as(BinaryOperatorExprSyntax.self)?.operator.text else { return false }
                guard op.hasSuffix("=") else { return false }
                return !["==", "!=", "<=", ">="].contains(op)
            }()
            if isPlainAssign || isCompoundAssign {
                recordMutation(of: elements[i - 1])
            }
        }
        return .visitChildren
    }

    // `&x` in-out passes a mutable reference — treat the base as mutated.
    override func visit(_ node: InOutExprSyntax) -> SyntaxVisitorContinueKind {
        recordMutation(of: node.expression)
        return .visitChildren
    }
}

/// Collects every plain identifier (`DeclReferenceExprSyntax` base name) that
/// appears in an expression subtree. Used as the conservative over-record fallback
/// for an exotic l-value the `MutatedNameScanner` can't reduce to a single base.
final class IdentifierCollector: SyntaxVisitor {
    private(set) var identifiers: Set<String> = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        identifiers.insert(node.baseName.text)
        return .visitChildren
    }
}

// MARK: - Purity analysis (Strategy B / A2)

/// Walks an expression subtree and decides whether it is PURE enough to lift into
/// a WASM fragment, while collecting the free identifiers it reads.
///
/// SAFETY (zero false negatives): `isPure` becomes false on *any* of:
///   * a `mustStayNative` symbol or a native callee,
///   * `self` / `super` access (may read view/reactive state),
///   * an `await` / `try` (effect placement must be preserved in the shell),
///   * an assignment or in-out (`&`) — mutation is not a value computation,
///   * `#selector` / key-path / unresolved attribute.
/// Anything we cannot positively prove pure leaves `isPure == false`, so the
/// caller keeps the work in the native shell. The scanner deliberately
/// over-rejects; it can only cost OTA coverage, never correctness.
final class PurityScanner: SyntaxVisitor {
    let registry: NativeRegistry
    let nativeCalleeNames: Set<String>
    private(set) var isPure = true
    private(set) var identifiers: Set<String> = []
    /// Names bound *inside* the expression (closure params, `let` in conditions)
    /// — these are not free identifiers and must not be threaded as inputs.
    private var bound: Set<String> = []

    init(registry: NativeRegistry, nativeCalleeNames: Set<String>) {
        self.registry = registry
        self.nativeCalleeNames = nativeCalleeNames
        super.init(viewMode: .sourceAccurate)
    }

    private func fail() { isPure = false }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if name == "self" || name == "super" { fail(); return .skipChildren }
        if registry.entry(for: name)?.tier == .mustStayNative { fail() }
        if nativeCalleeNames.contains(name) { fail() }
        if !bound.contains(name) { identifiers.insert(name) }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if let base = node.base?.trimmedDescription {
            if base == "self" || base == "super" { fail(); return .skipChildren }
            if registry.entry(for: base)?.tier == .mustStayNative { fail() }
        }
        let member = node.declName.baseName.text
        if registry.entry(for: member)?.tier == .mustStayNative { fail() }
        if nativeCalleeNames.contains(member) { fail() }
        // Walk ONLY the base — the member name (`isEmpty`, `count`) is a label, not
        // a free value identifier; visiting it as a DeclReferenceExpr would wrongly
        // add it to `identifiers` and trip the no-capture gate.
        if let base = node.base { walk(base) }
        return .skipChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let ident = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let n = ident.baseName.text
            if registry.entry(for: n)?.tier == .mustStayNative { fail() }
            if nativeCalleeNames.contains(n) { fail() }
            // A bare lowercase callee is a local helper / implicit-self method that
            // won't exist in the WASM fragment — treat it as a free identifier so
            // the no-capture gate keeps the statement native unless it's available.
            if n.hasPrefix("$") || (n.first?.isLowercase ?? false) {
                if !bound.contains(n) { identifiers.insert(n) }
            }
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let n = member.declName.baseName.text
            if registry.entry(for: n)?.tier == .mustStayNative { fail() }
            if nativeCalleeNames.contains(n) { fail() }
        }
        return .visitChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        if registry.entry(for: node.name.text)?.tier == .mustStayNative { fail() }
        return .visitChildren
    }

    // Effect-bearing / mutating / interop constructs → not liftable.
    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind { fail(); return .skipChildren }
    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind { fail(); return .skipChildren }
    override func visit(_ node: InOutExprSyntax) -> SyntaxVisitorContinueKind { fail(); return .skipChildren }
    override func visit(_ node: AssignmentExprSyntax) -> SyntaxVisitorContinueKind { fail(); return .skipChildren }
    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind { fail(); return .skipChildren }
    override func visit(_ node: KeyPathExprSyntax) -> SyntaxVisitorContinueKind { fail(); return .skipChildren }

    // Track closure parameters so they are not threaded as fragment inputs.
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        if let sig = node.signature, let params = sig.parameterClause {
            if let list = params.as(ClosureShorthandParameterListSyntax.self) {
                for p in list { bound.insert(p.name.text) }
            } else if let clause = params.as(ClosureParameterClauseSyntax.self) {
                for p in clause.parameters { bound.insert((p.secondName ?? p.firstName).text) }
            }
        }
        return .visitChildren
    }
}

/// Finds the single best PURE sub-expression to lift out of a native statement
/// (Strategy A2). "Best" = the largest non-trivial pure sub-expression of an
/// inferable concrete type whose inputs are all available concretely-typed
/// values. Walks the statement, scoring candidate expressions, keeping the one
/// with the most descendant nodes (the biggest lift).
final class LiftableSubExprCollector: SyntaxVisitor {
    struct Candidate { let text: String; let resultType: String; let inputs: Set<String>; let size: Int }

    let registry: NativeRegistry
    let nativeCalleeNames: Set<String>
    let available: Set<String>
    let paramTypeByName: [String: String]
    private(set) var best: Candidate?

    init(registry: NativeRegistry, nativeCalleeNames: Set<String>,
         available: Set<String>, paramTypeByName: [String: String]) {
        self.registry = registry
        self.nativeCalleeNames = nativeCalleeNames
        self.available = available
        self.paramTypeByName = paramTypeByName
        super.init(viewMode: .sourceAccurate)
    }

    private func consider(_ expr: ExprSyntax) {
        // Must be a non-trivial operation, not a bare identifier/literal/member.
        guard isNonTrivial(expr) else { return }
        // SOUNDNESS: never lift a sub-expression evaluated CONDITIONALLY in the
        // native statement — the lift binds it to a temp UNCONDITIONALLY (the
        // `let frag_v = Patch.call(...)` runs before the rewritten statement). A
        // candidate that natively only runs when a short-circuit predecessor is
        // true (RHS of `&&`/`||`) or only on one branch of a ternary would then
        // execute always — a `count / divisor` with `divisor == 0`, or a `+`/`*`
        // that overflows, TRAPS where the native code short-circuited past it.
        // Keep such a candidate native (demote-safe). See BUG #4.
        guard !isConditionallyEvaluated(expr) else { return }
        // Must have an inferable concrete result type.
        guard let type = inferType(expr) else { return }
        // Must be pure.
        let scanner = PurityScanner(registry: registry, nativeCalleeNames: nativeCalleeNames)
        scanner.walk(expr)
        guard scanner.isPure else { return }
        // Every free identifier must be available (a param/earlier local) so the
        // fragment can receive it. Reject if it reads anything not available.
        guard scanner.identifiers.isSubset(of: available) else { return }
        let inputs = scanner.identifiers
        let size = expr.description.count
        if best == nil || size > best!.size {
            best = Candidate(text: expr.trimmedDescription, resultType: type, inputs: inputs, size: size)
        }
    }

    /// True iff `expr` sits in a position the native statement may SKIP at runtime,
    /// so hoisting it to an unconditional fragment call would change evaluation
    /// (and can trap where the native code short-circuited past it). Walks the
    /// ancestor chain looking for:
    ///   * the RHS of a short-circuiting `&&` / `||` (any operand positioned AFTER
    ///     a `&&`/`||` operator token inside an enclosing `SequenceExpr`), and
    ///   * the then-branch or else-branch of a ternary `cond ? then : else`.
    /// Conservative: ANY such enclosing context (no matter how deep) rejects the lift.
    private func isConditionallyEvaluated(_ expr: ExprSyntax) -> Bool {
        // Walk the ancestor chain, tracking the node we just came UP from (`child`)
        // so a parent can ask "which of my positions did the candidate descend from".
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
            // `[cond, UnresolvedTernaryExprSyntax(? then :), else]`. The THEN branch
            // lives INSIDE the `UnresolvedTernaryExprSyntax`; the ELSE branch is the
            // sequence element AFTER it. Either is conditionally evaluated.
            if parent.is(UnresolvedTernaryExprSyntax.self) {
                return true   // anything inside the `? then :` middle is the then-arm
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
            // `child` becomes the element node when the NEXT parent is the SequenceExpr
            // (the chain is element → ExprListSyntax → SequenceExpr); track the node
            // whose parent is the ExprList so the index lookup above matches.
            child = node
            node = parent
        }
        return false
    }

    /// Reject bare identifiers, literals, member accesses, and `self`/optionals —
    /// they buy no real OTA work and add ABI noise.
    private func isNonTrivial(_ expr: ExprSyntax) -> Bool {
        if expr.is(DeclReferenceExprSyntax.self) { return false }
        if expr.is(IntegerLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self)
            || expr.is(StringLiteralExprSyntax.self) || expr.is(BooleanLiteralExprSyntax.self) { return false }
        if expr.is(MemberAccessExprSyntax.self) { return false }
        if expr.is(NilLiteralExprSyntax.self) { return false }
        return true
    }

    /// Best-effort concrete type inference for the value of a pure expression.
    /// Conservative: returns nil unless we are confident (so the fragment compiles).
    private func inferType(_ expr: ExprSyntax) -> String? {
        // Parenthesised → unwrap.
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression {
            return inferType(inner)
        }
        // Boolean operators / comparisons → Bool.
        if let seq = expr.as(SequenceExprSyntax.self) {
            var sawComparison = false
            var sawArith = false
            var sawString = false
            for el in seq.elements {
                if let op = el.as(BinaryOperatorExprSyntax.self)?.operator.text {
                    switch op {
                    case "==", "!=", "<", ">", "<=", ">=", "&&", "||": sawComparison = true
                    case "+":
                        // `+` is ambiguous (numeric or String); resolve via operands below.
                        sawArith = true
                    case "-", "*", "/", "%": sawArith = true
                    default: return nil
                    }
                } else if el.is(StringLiteralExprSyntax.self) {
                    sawString = true
                }
            }
            if sawComparison { return "Bool" }
            if sawString && !sawArith { return "String" }
            if sawArith {
                // Resolve numeric vs string by the first typed operand.
                if let t = numericTypeOfOperands(seq) { return t }
                return nil
            }
            return nil
        }
        // `!x` → Bool.
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
            return "Bool"
        }
        // `a.isEmpty`, `a.count` style on a known collection → Bool / Int.
        if let member = expr.as(MemberAccessExprSyntax.self) {
            switch member.declName.baseName.text {
            case "isEmpty": return "Bool"
            case "count": return "Int"
            default: return nil
            }
        }
        // String interpolation literal → String.
        if let str = expr.as(StringLiteralExprSyntax.self),
           str.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) {
            return "String"
        }
        return nil
    }

    /// For an arithmetic SequenceExpr, infer the numeric (or String) result type
    /// from the first operand whose type we can read off a typed identifier.
    private func numericTypeOfOperands(_ seq: SequenceExprSyntax) -> String? {
        for el in seq.elements {
            if let ref = el.as(DeclReferenceExprSyntax.self),
               let t = paramTypeByName[ref.baseName.text] {
                if ["Int", "Double", "Float", "CGFloat", "Decimal", "Int64", "Int32", "UInt", "TimeInterval"].contains(t) {
                    return t
                }
                if t == "String" { return "String" }
            }
            if el.is(FloatLiteralExprSyntax.self) { return "Double" }
        }
        // Pure integer-literal arithmetic defaults to Int.
        let onlyIntLiterals = seq.elements.allSatisfy {
            $0.is(IntegerLiteralExprSyntax.self) || $0.is(BinaryOperatorExprSyntax.self)
        }
        return onlyIntLiterals ? "Int" : nil
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        consider(ExprSyntax(node)); return .visitChildren
    }
    override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        consider(ExprSyntax(node)); return .visitChildren
    }
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        consider(ExprSyntax(node)); return .visitChildren
    }
}
