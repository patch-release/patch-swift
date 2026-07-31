// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The four-way classification of a function.
public enum Classification: String, Sendable, Codable, Hashable, CaseIterable {
    /// Pure: nothing native in the transitive closure.
    case wasmEligible
    /// Uses native APIs, but every native symbol touched has a pre-built bridge.
    case bridged
    /// Pure logic mixed with native calls that could be lifted into a thin
    /// native shell → auto-split candidate.
    case mixed
    /// Must stay native; cannot be safely split.
    case native
}

/// The result of classifying a single function, with the evidence behind it.
public struct ClassificationResult: Sendable, Hashable {
    public let functionID: String
    public let classification: Classification
    /// Native symbols encountered in the transitive closure (with bridge info).
    public let nativeHits: [NativeSymbol]
    /// Human-readable reasons (forced-native flags, unresolved refs, etc.).
    public let reasons: [String]
    /// The smallest packaging tier this function can compile at (the "embedded
    /// axis"). Only meaningful for OTA-bound functions (`wasmEligible`/`bridged`/
    /// `mixed`); `native` functions don't ship to WASM (defaults to `t2Foundation`
    /// as a conservative placeholder). T0 Embedded is the default + smallest;
    /// embedded-incompatible code falls back to T1/T2. See `EmbeddedCompatibility`.
    public let tier: PackagingTier
    /// Embedded-incompatible constructs found (empty when T0). For reports.
    public let tierBlockers: [String]

    public init(functionID: String, classification: Classification, nativeHits: [NativeSymbol], reasons: [String],
                tier: PackagingTier = .t0Embedded, tierBlockers: [String] = []) {
        self.functionID = functionID
        self.classification = classification
        self.nativeHits = nativeHits
        self.reasons = reasons
        self.tier = tier
        self.tierBlockers = tierBlockers
    }
}

/// Classifies functions as wasmEligible / bridged / mixed / native.
///
/// Agent A2 scope.
///
/// SAFETY INVARIANT (NON-NEGOTIABLE): zero false negatives. A function that
/// touches a native symbol anywhere in its transitive closure must NEVER be
/// classified `wasmEligible`. Every code path below that could return
/// `.wasmEligible` is guarded by the explicit `hasAnyNative` check, and the
/// default for anything we cannot prove pure is `.native`. False positives
/// (pure code marked native) are acceptable — they only cost OTA coverage.
public struct Classifier {
    public let registry: NativeRegistry

    /// Names the project itself declares as nominal types (struct/class/enum/
    /// actor/protocol/typealias). A registry symbol whose name appears here is
    /// SHADOWED: an unqualified reference to it in this project resolves to the
    /// PROJECT's type, not the framework one, so the registry hit is a false
    /// positive (e.g. swift-collections' own `Path`/`Index`/`Element`, RxSwift's
    /// own `Observable`/`Element`, Alamofire's own `Stream`/`Host`/`State`).
    ///
    /// SAFETY: this only ever SUPPRESSES a native hit when the project provably
    /// redeclares that exact nominal name — Swift unqualified name lookup binds
    /// such a reference to the project declaration, so the suppressed framework
    /// symbol genuinely is not the one referenced. Attribute / selector refs
    /// (`@State`, `@objc`, `#selector`) are NEVER shadowed (a `struct State`
    /// cannot be written `@State`), so forced-native interop detection is intact.
    /// Empty set ⇒ behaviour identical to the original name-only registry scan.
    public let projectTypeNames: Set<String>

    public init(registry: NativeRegistry = .standard,
                projectTypeNames: Set<String> = []) {
        self.registry = registry
        self.projectTypeNames = projectTypeNames
    }

    /// Resolve a reference against the registry, honouring project-type shadowing.
    /// Returns nil when the reference resolves to a project-declared type (the
    /// framework symbol is shadowed) — except for attribute/selector references,
    /// which are never shadowed (they cannot denote a plain project type).
    func registryMatch(_ ref: Reference) -> NativeSymbol? {
        guard let hit = registry.match(ref) else { return nil }
        // Attributes / selectors always count (cannot be a shadowing project type).
        if ref.kind == .attribute || ref.kind == .selector { return hit }
        // If the project declares a nominal type by the matched symbol's name, an
        // UNQUALIFIED reference to it is the PROJECT type → suppress the hit.
        if projectTypeNames.contains(hit.symbol) {
            // BUT a MODULE-QUALIFIED reference (`Foundation.Timer`) is NOT shadowed
            // by a project `struct Timer` — Swift binds the qualified form to the
            // framework type. Such a reference appears as a member access whose
            // member name IS the matched symbol and whose base is the qualifier
            // (`name == hit.symbol`, `base != nil`). Don't suppress that — doing so
            // would misclassify a genuine framework use as pure and ship broken WASM.
            let moduleQualified =
                ref.kind == .memberAccess && ref.name == hit.symbol && ref.base != nil
            if !moduleQualified { return nil }
        }
        return hit
    }

    /// Aggregated tier flags + native hits over a node (locally or over a closure).
    ///
    /// Native hits are deduped *as they are unioned* (keyed by symbol name). On
    /// the very dense corpus call graphs a node's closure can reach thousands of
    /// native references; without dedupe-on-union the aggregate arrays grow into
    /// the tens of thousands and the final dedupe dominates runtime. Keeping a
    /// `Set<String>` guard bounds each aggregate to the number of *distinct*
    /// native symbols (a few dozen at most).
    struct TierFlags {
        /// THIS node directly carries a forced-native flag (its own `@objc`,
        /// `#selector`, `dynamic`, `withUnsafe…`, a blanket-native enclosing type,
        /// or a reactive-property touch). Such interop is un-liftable, so the node
        /// itself can never be split → native.
        var localForcedNative = false
        /// SOME node in the closure carries forced-native (this node and/or a
        /// callee). Blocks the pure path. For callers (where `localForcedNative`
        /// is false) a forced-native *callee* behaves like a `mustStayNative`
        /// dependency: it can still be split out (Strategy A/B) → mixed.
        var forcedNative = false
        /// THIS node is a "pure-logic-over-reactive-reads" member: it reads
        /// reactive/stored properties the native shell can HOST-PROJECT into a
        /// lifted WASM fragment (`FunctionRecord.hostProjectableReads`). Such a
        /// member is NOT pure (it depends on reactive reads), so it must not be
        /// `wasmEligible`; it is routed to `mixed` (the shell projects the reads,
        /// the fragment runs the pure logic). Local-only, like `localForcedNative`
        /// (it describes the node, not its closure).
        var hostProjectable = false
        var mustStayNative = false
        var bridgeable = false
        var nativeHits: [NativeSymbol] = []
        var reasons: [String] = []
        /// Embedded-compatibility axis, aggregated over the closure: the largest
        /// (worst) tier any node in the closure requires, plus the blockers. A
        /// module's tier is the max over its functions, so unioning by `max` here
        /// gives each function its whole-closure tier automatically.
        var embeddedTier: PackagingTier = .t0Embedded
        var embeddedBlockers: [String] = []
        private var seenSymbols: Set<String> = []
        private var seenReasons: Set<String> = []
        private var seenBlockers: Set<String> = []

        mutating func addHit(_ hit: NativeSymbol) {
            if seenSymbols.insert(hit.symbol).inserted { nativeHits.append(hit) }
        }
        mutating func addReason(_ reason: String) {
            if seenReasons.insert(reason).inserted { reasons.append(reason) }
        }
        mutating func raiseTier(_ tier: PackagingTier, blockers: [String]) {
            embeddedTier = Swift.max(embeddedTier, tier)
            for b in blockers where seenBlockers.insert(b).inserted { embeddedBlockers.append(b) }
        }

        mutating func formUnion(_ other: TierFlags) {
            // NB: `localForcedNative` is intentionally NOT unioned — it describes
            // only the node it was computed for. The closure-aggregate forced flag
            // travels via `forcedNative`.
            forcedNative = forcedNative || other.forcedNative
            mustStayNative = mustStayNative || other.mustStayNative
            bridgeable = bridgeable || other.bridgeable
            for h in other.nativeHits { addHit(h) }
            for r in other.reasons { addReason(r) }
            raiseTier(other.embeddedTier, blockers: other.embeddedBlockers)
        }
    }

    /// The embedded-compatibility analyzer (the "embedded axis").
    let embeddedCompat = EmbeddedCompatibility()

    /// Classify every node in the graph.
    ///
    /// Performance: the corpus call graphs are very dense (name-based resolution
    /// can produce 100k+ edges over ~8k nodes), so re-walking each node's
    /// transitive closure independently is O(V·E) — minutes. Instead we:
    ///   1. compute each node's LOCAL tier flags once,
    ///   2. condense the graph into strongly-connected components (Tarjan),
    ///   3. propagate flags over the condensed DAG in reverse-topological order
    ///      so every node's closure-aggregate flags are computed in O(V+E).
    /// Cycle-safe by construction (all nodes in an SCC share the same closure
    /// flags). Cuts 8k-function analysis from ~3 min to a few seconds.
    public func classifyAll(_ graph: CallGraph) -> [String: ClassificationResult] {
        // 1. Local flags per node.
        var local: [String: TierFlags] = [:]
        local.reserveCapacity(graph.nodes.count)
        for node in graph.nodes { local[node] = localFlags(node, in: graph) }

        // 2. SCC condensation + reverse-topological flag propagation.
        let closureFlags = ClosureFlagSolver.solve(graph: graph, local: local)

        // 3. Decide each node from its aggregated flags. The closure aggregate
        //    loses `localForcedNative` (it is deliberately not unioned), so we
        //    restore it from the node's own LOCAL flags — only the node that
        //    directly does un-liftable interop is barred from splitting.
        var results: [String: ClassificationResult] = [:]
        results.reserveCapacity(graph.nodes.count)
        for node in graph.nodes {
            var flags = closureFlags[node] ?? local[node] ?? TierFlags()
            flags.localForcedNative = local[node]?.localForcedNative ?? false
            // `hostProjectable` describes the node itself (like `localForcedNative`)
            // and is not unioned over the closure — restore it from local flags.
            flags.hostProjectable = local[node]?.hostProjectable ?? false
            results[node] = decide(node, flags: flags, graph: graph)
        }
        return results
    }

    /// LOCAL (single-node) tier flags from this node's own forced flag + refs.
    private func localFlags(_ node: String, in graph: CallGraph) -> TierFlags {
        var f = TierFlags()
        if let record = graph.records[node], record.forcesNative {
            f.forcedNative = true
            f.localForcedNative = true
            for flag in record.nativeFlags { f.addReason("\(node): \(flag)") }
        }
        // Host-projectable "pure-logic-over-reactive-reads" member: the native
        // shell projects its reactive reads into a lifted WASM fragment. Recorded
        // by the FunctionExtractor only when the reactive read is the SOLE native
        // reason AND every read + the return type is value-marshallable, so the
        // member is otherwise pure — but it still depends on reactive reads, so it
        // is routed to `mixed`, never `wasmEligible`.
        if let record = graph.records[node], !record.hostProjectableReads.isEmpty {
            f.hostProjectable = true
            let names = record.hostProjectableReads.map { $0.name }.joined(separator: ", ")
            f.addReason("\(node): reads host-projectable reactive state (\(names))")
        }
        let refs = graph.unresolvedReferences[node] ?? []
        for ref in refs {
            if let hit = registryMatch(ref) {
                switch hit.tier {
                case .mustStayNative:
                    f.addHit(hit); f.mustStayNative = true
                case .bridgeable:
                    f.addHit(hit); f.bridgeable = true
                case .wasmSafeFoundation:
                    break // recognised eligible — does NOT bar wasmEligible
                }
            }
        }
        // Embedded-compatibility axis: the smallest packaging tier THIS node's own
        // references allow (T0 by default; T1/T2 if it touches an embedded-rejected
        // construct that no host bridge covers). Aggregated over the closure by
        // the SCC solver via `formUnion`/`raiseTier`.
        let verdict = embeddedCompat.analyze(references: allReferences(node, in: graph),
                                             reasonsPrefix: "\(node): ")
        f.raiseTier(verdict.tier, blockers: verdict.blockers)
        return f
    }

    /// All references on a node (the parser's body refs + any unresolved refs the
    /// graph carries), for the embedded axis.
    private func allReferences(_ node: String, in graph: CallGraph) -> [Reference] {
        var refs = graph.unresolvedReferences[node] ?? []
        if let rec = graph.records[node] { refs += rec.bodyReferences }
        return refs
    }

    /// Classify a single function by walking its transitive closure (kept for
    /// direct/test use; `classifyAll` uses the memoized fast path above).
    ///
    /// Day-2 three-tier decision tree:
    ///   - touches any `mustStayNative` (not separable)      → native
    ///   - touches `mustStayNative` separably + pure/bridged → mixed (split)
    ///   - touches only `bridgeable` (+ pure/wasmSafe)       → bridged
    ///   - pure + `wasmSafeFoundation` only                  → wasmEligible
    /// Cap on the number of distinct nodes a single-node closure walk may visit
    /// before we stop and classify the function `native`. On a giant app a
    /// single function's callee-closure can reach tens of thousands of nodes;
    /// exploring it fully per-node is the watchdog stall. Stopping at the cap is
    /// SAFE (conservative): an un-explored closure is treated as native, a false
    /// positive only. Logged when it fires.
    public static let closureExplorationCap = 50_000

    public func classify(_ node: String, in graph: CallGraph) -> ClassificationResult {
        let (closure, capped) = graph.transitiveClosure(from: node, cap: Self.closureExplorationCap)
        if capped {
            FileHandle.standardError.write(Data(
                "[Patch] closure-exploration cap (\(Self.closureExplorationCap)) hit for \(node) — classifying native (conservative)\n".utf8))
            return ClassificationResult(
                functionID: node, classification: .native, nativeHits: [],
                reasons: ["closure exploration exceeded cap (\(Self.closureExplorationCap)) — conservatively native"]
            )
        }
        var flags = TierFlags()
        for member in closure {
            flags.formUnion(localFlags(member, in: graph))
        }
        return decide(node, flags: flags, graph: graph)
    }

    /// Turn aggregated tier flags into a classification (shared by both paths).
    private func decide(_ node: String, flags: TierFlags, graph: CallGraph) -> ClassificationResult {
        let nativeHits = flags.nativeHits
        var reasons = flags.reasons
        let sawForcedNative = flags.forcedNative
        let sawMustStayNative = flags.mustStayNative
        let sawBridgeable = flags.bridgeable
        // Only the node ITSELF doing un-liftable interop bars splitting. A node
        // that merely *calls* a forced-native helper can still be split (the call
        // stays in the shell). This is the native→mixed lever (2a): it stops a
        // few forced-native roots from poisoning thousands of pure callers.
        let localForced = flags.localForcedNative
        // A forced-native dependency reached only via a callee behaves like a
        // mustStayNative dependency for the caller.
        let closureForcedDependency = sawForcedNative && !localForced

        // Anything that is native-or-bridged blocks the pure path.
        let hasNonWasmDependency = sawForcedNative || sawMustStayNative || sawBridgeable

        // ---- Decision tree (safety-ordered) ----

        // (A0) HOST-PROJECTABLE "pure-logic-over-reactive-reads" member with NO
        //      other native dependency in its closure => mixed. Its only impurity
        //      is reading reactive/stored props the native shell can project into
        //      the lifted WASM fragment (the SwiftUI `@State` trick, generalised).
        //      It must NOT be `wasmEligible` (it depends on reactive reads), and it
        //      need not go through the native paths (there is no other native dep).
        //      The FunctionSplitter's host-projection strategy is the ground truth:
        //      if it cannot realize a compilable projection, the member ships
        //      nothing OTA and counts as native in the realized pass — demote-safe.
        //      Guarded by `!hasNonWasmDependency` so a member that ALSO touches a
        //      genuine native dependency falls through to the existing tree (which
        //      decides native-callee-separable → mixed, or native).
        if flags.hostProjectable && !hasNonWasmDependency {
            reasons.append("pure logic over host-projectable reactive reads — auto-split candidate")
            return ClassificationResult(
                functionID: node, classification: .mixed,
                nativeHits: [], reasons: reasons,
                tier: flags.embeddedTier, tierBlockers: flags.embeddedBlockers
            )
        }

        // (A) Nothing native/bridged anywhere => wasmEligible. This is the ONLY
        //     path to wasmEligible, guarded by `!hasNonWasmDependency`. WASM-safe
        //     Foundation symbols (Decimal/Date/Codable/…) keep this path open.
        if !hasNonWasmDependency {
            return ClassificationResult(
                functionID: node, classification: .wasmEligible,
                nativeHits: [], reasons: reasons.isEmpty ? ["pure + WASM-safe Foundation only"] : reasons,
                tier: flags.embeddedTier, tierBlockers: flags.embeddedBlockers
            )
        }

        // (B) The node ITSELF does forced native interop (ObjC/selector/dynamic/
        //     unsafe, blanket-native type, reactive-property touch) => native, no
        //     splitting. Such interop can never be lifted to WASM nor bridged.
        if localForced {
            reasons.append("forced native (ObjC/selector/dynamic/unsafe interop)")
            return ClassificationResult(
                functionID: node, classification: .native,
                nativeHits: dedupeHits(nativeHits), reasons: reasons
            )
        }

        // (C) Touches a mustStayNative (or forced-native callee) AND has separable
        //     pure/bridged logic locally => mixed (auto-split candidate). Splitting
        //     ships the separable part OTA while the native call stays in the shell.
        if (sawMustStayNative || closureForcedDependency)
            && hasLocalSplittablePureLogic(node, in: graph,
                                           closureForcedDependency: closureForcedDependency) {
            reasons.append("native call separable from pure/bridged logic — auto-split candidate")
            return ClassificationResult(
                functionID: node, classification: .mixed,
                nativeHits: dedupeHits(nativeHits), reasons: reasons,
                tier: flags.embeddedTier, tierBlockers: flags.embeddedBlockers
            )
        }

        // (D) Touches a mustStayNative / forced-native dependency with no safe
        //     split => native.
        if sawMustStayNative || closureForcedDependency {
            reasons.append("native API in closure with no safe split — native")
            return ClassificationResult(
                functionID: node, classification: .native,
                nativeHits: dedupeHits(nativeHits), reasons: reasons
            )
        }

        // (E) Only bridgeable symbols (+ pure/wasmSafe), nothing tier-1 => bridged.
        //     The whole function runs OTA, calling Patch.call(...) into the host
        //     bridge for each bridgeable site.
        if sawBridgeable {
            reasons.append("only bridgeable native symbols — runs OTA via host bridges")
            return ClassificationResult(
                functionID: node, classification: .bridged,
                nativeHits: dedupeHits(nativeHits), reasons: reasons,
                tier: flags.embeddedTier, tierBlockers: flags.embeddedBlockers
            )
        }

        // (F) Default: native. Conservative fallback — when in doubt, native.
        reasons.append("native API in closure with no safe split — defaulting to native")
        return ClassificationResult(
            functionID: node, classification: .native,
            nativeHits: dedupeHits(nativeHits), reasons: reasons
        )
    }

    /// Does THIS function's own body contain pure/bridged logic separable from
    /// its `mustStayNative` call(s)? A function qualifies for `mixed` only if it
    /// has both a tier-1 reference and at least one separable non-tier-1 piece
    /// (a pure/bridged callee, or local logic that uses only wasm-safe/bridged
    /// symbols).
    private func hasLocalSplittablePureLogic(_ node: String, in graph: CallGraph,
                                             closureForcedDependency: Bool = false) -> Bool {
        guard let record = graph.records[node] else { return false }
        if record.forcesNative { return false }
        let refs = graph.unresolvedReferences[node] ?? []
        let localMustStayNative = refs.contains {
            registryMatch($0)?.tier == .mustStayNative
        }
        // The native boundary may instead be a forced-native or native callee
        // (e.g. a function that calls a `@objc`/`perform`-based helper). Those are
        // separable too: the call stays in the shell, the pure work is lifted.
        let callsNative = graph.callees(of: node).contains { callee in
            if let cr = graph.records[callee], cr.forcesNative { return true }
            return classifyMemo(callee, in: graph) != .wasmEligible
        }
        // A DEEP forced-native dependency (reached transitively, not a direct
        // callee) is also a real native boundary: the native callee stays in the
        // shell, the function's local pure work is lifted. Without this, project-
        // type shadowing (which can reclassify a direct callee from mixed→eligible,
        // dropping `callsNative`) would demote a genuinely-splittable function to
        // native — losing the realized pure fragment it used to ship. Treating the
        // closure-forced dependency as a boundary keeps the candidate; the codegen
        // splitter remains the ground truth (returns nil if no clean split exists),
        // so this only widens the candidate set — never affects eligibility safety.
        let hasNativeBoundary = localMustStayNative || callsNative || closureForcedDependency
        guard hasNativeBoundary else { return false }

        // (1) When the native boundary is a LOCAL mustStayNative ref, a resolved
        //     non-native callee is itself liftable evidence (Day-2 behaviour).
        if localMustStayNative {
            for callee in graph.callees(of: node) {
                if let calleeRecord = graph.records[callee], calleeRecord.forcesNative {
                    continue
                }
                if classifyMemo(callee, in: graph) != .native { return true }
            }
        }

        // (2) Genuine liftable LOCAL work: the body references at least one
        //     wasm-safe Foundation symbol or a bridgeable symbol that the splitter
        //     can lift into a WASM fragment (e.g. `JSONDecoder().decode(...)` next
        //     to a `URLSession`/native call). This is the gate that keeps the
        //     `mixed` count honest — it requires real liftable statements, so the
        //     splitter will actually emit a fragment.
        let hasLiftableLocalWork = refs.contains { ref in
            switch registryMatch(ref)?.tier {
            case .wasmSafeFoundation, .bridgeable: return true
            default: return false
            }
        }
        if hasLiftableLocalWork { return true }

        // (3) When the boundary is a forced/native callee, the function is a split
        //     candidate if it also has separable PURE local work — either a
        //     resolved pure callee, or plain non-native local statements (pure
        //     arithmetic/string/collection logic that uses neither a native symbol
        //     nor the native callee). This is a cheap *candidate* signal; the
        //     codegen splitter is the ground truth and returns nil if no clean
        //     statement-level split exists, so over-marking here is safe (it only
        //     widens the candidate set the realized pass then filters).
        if callsNative || closureForcedDependency {
            for callee in graph.callees(of: node) {
                if let cr = graph.records[callee], cr.forcesNative { continue }
                if classifyMemo(callee, in: graph) == .wasmEligible { return true }
            }
            // Plain pure local statements: a body reference that is NOT a native
            // symbol and not itself a native callee is liftable arithmetic/logic.
            let nativeCalleeNames = Set(graph.callees(of: node).compactMap { callee -> String? in
                let isNative = (graph.records[callee]?.forcesNative ?? false)
                    || classifyMemo(callee, in: graph) == .native
                guard isNative else { return nil }
                return callee.split(separator: ".").last.map(String.init)?
                    .split(separator: "(").first.map(String.init)
            })
            let hasPureLocalLogic = refs.contains { ref in
                guard ref.kind == .functionCall || ref.kind == .memberAccess
                        || ref.kind == .identifier else { return false }
                // Shadow-aware: a name the project redeclares as its own type is
                // not native here, so it counts as pure local work.
                if registry.isNative(ref.name) && !projectTypeNames.contains(ref.name) { return false }
                if nativeCalleeNames.contains(ref.name) { return false }
                return true
            }
            if hasPureLocalLogic { return true }
        }
        return false
    }

    /// Lightweight closure-based classification used only to test a callee's
    /// nativeness while deciding splittability of the caller. Avoids infinite
    /// recursion by inspecting the callee's own local references + forced flag,
    /// not its full transitive caller chain.
    private func classifyMemo(_ node: String, in graph: CallGraph) -> Classification {
        guard let record = graph.records[node] else { return .native }
        if record.forcesNative { return .native }
        let refs = graph.unresolvedReferences[node] ?? []
        let touchesMustStayNative = refs.contains { registryMatch($0)?.tier == .mustStayNative }
        let touchesBridgeable = refs.contains { registryMatch($0)?.tier == .bridgeable }
        if touchesMustStayNative { return .mixed }
        if touchesBridgeable { return .bridged }
        return .wasmEligible
    }

    private func dedupeHits(_ hits: [NativeSymbol]) -> [NativeSymbol] {
        var seen: Set<String> = []
        var out: [NativeSymbol] = []
        for h in hits where !seen.contains(h.symbol) {
            seen.insert(h.symbol)
            out.append(h)
        }
        return out.sorted { $0.symbol < $1.symbol }
    }
}

// MARK: - Closure-flag solver (SCC condensation, O(V+E))

/// Computes, for every node, the union of LOCAL tier flags over its transitive
/// closure — in linear time — by condensing the (cyclic, very dense) call graph
/// into its strongly-connected components and propagating flags over the
/// resulting DAG in reverse-topological order.
///
/// Correctness: every node in an SCC reaches every other node in that SCC, so
/// they share identical closure flags (= union of the whole SCC's locals plus
/// all successor SCCs). The condensed graph is a DAG; processing it in reverse
/// topological order guarantees each component's successors are finalised first.
enum ClosureFlagSolver {
    static func solve(graph: CallGraph, local: [String: Classifier.TierFlags])
        -> [String: Classifier.TierFlags]
    {
        let nodes = Array(graph.nodes)
        // `graph.nodes` is a `Set<Node>`, so `nodes` carries no duplicate elements and
        // these keys are unique by construction today. `Dictionary(uniqueKeysWithValues:)`
        // TRAPS on a duplicate key, though — a hard crash inside the engine that, unlike a
        // demote, has NO backstop and aborts the whole app's module build (the same bug
        // class as the `buildStateModel` fix in SwiftUIBodyLowering). Build it defensively
        // with `uniquingKeysWith:` so a future change to the node source can never reintroduce
        // that trap. Keep FIRST: the earliest offset, matching this array's enumeration order.
        let indexOf = Dictionary(
            nodes.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let n = nodes.count

        // Adjacency as integer indices (callees that are known nodes).
        var adj: [[Int]] = Array(repeating: [], count: n)
        for (u, node) in nodes.enumerated() {
            for callee in graph.callees(of: node) {
                if let v = indexOf[callee] { adj[u].append(v) }
            }
        }

        // --- Tarjan SCC (iterative to avoid deep recursion on 8k+ nodes) ---
        var sccOf = Array(repeating: -1, count: n)
        var lowlink = Array(repeating: 0, count: n)
        var disc = Array(repeating: -1, count: n)
        var onStack = Array(repeating: false, count: n)
        var sccStack: [Int] = []
        var sccCount = 0
        var time = 0

        for start in 0..<n where disc[start] == -1 {
            // Explicit DFS stack of (node, nextChildIndex).
            var dfs: [(Int, Int)] = [(start, 0)]
            disc[start] = time; lowlink[start] = time; time += 1
            sccStack.append(start); onStack[start] = true

            while let (u, ci) = dfs.last {
                if ci < adj[u].count {
                    dfs[dfs.count - 1].1 += 1
                    let v = adj[u][ci]
                    if disc[v] == -1 {
                        disc[v] = time; lowlink[v] = time; time += 1
                        sccStack.append(v); onStack[v] = true
                        dfs.append((v, 0))
                    } else if onStack[v] {
                        lowlink[u] = min(lowlink[u], disc[v])
                    }
                } else {
                    // Done with u: if root of an SCC, pop it.
                    if lowlink[u] == disc[u] {
                        while true {
                            let w = sccStack.removeLast()
                            onStack[w] = false
                            sccOf[w] = sccCount
                            if w == u { break }
                        }
                        sccCount += 1
                    }
                    dfs.removeLast()
                    if let (parent, _) = dfs.last {
                        lowlink[parent] = min(lowlink[parent], lowlink[u])
                    }
                }
            }
        }

        // --- Condense: per-SCC local-flag union + inter-SCC edges. ---
        var sccFlags = Array(repeating: Classifier.TierFlags(), count: sccCount)
        for (u, node) in nodes.enumerated() {
            if let lf = local[node] { sccFlags[sccOf[u]].formUnion(lf) }
        }
        // Successor SCCs (dedup) per SCC.
        var sccSucc: [Set<Int>] = Array(repeating: [], count: sccCount)
        var indeg = Array(repeating: 0, count: sccCount)
        for u in 0..<n {
            for v in adj[u] where sccOf[u] != sccOf[v] {
                if sccSucc[sccOf[u]].insert(sccOf[v]).inserted {
                    indeg[sccOf[v]] += 1
                }
            }
        }

        // --- Topological order of the DAG (Kahn). ---
        var topo: [Int] = []
        topo.reserveCapacity(sccCount)
        var queue: [Int] = (0..<sccCount).filter { indeg[$0] == 0 }
        var qi = 0
        var localIndeg = indeg
        while qi < queue.count {
            let s = queue[qi]; qi += 1
            topo.append(s)
            for t in sccSucc[s] {
                localIndeg[t] -= 1
                if localIndeg[t] == 0 { queue.append(t) }
            }
        }
        // (Tarjan already yields SCCs in reverse-topological order, but Kahn is
        //  robust regardless; process topo in reverse so successors finalise first.)

        // --- Propagate flags: closure(scc) = local(scc) ∪ ⋃ closure(succ). ---
        for s in topo.reversed() {
            var agg = sccFlags[s]
            for t in sccSucc[s] { agg.formUnion(sccFlags[t]) }
            sccFlags[s] = agg
        }

        // --- Map back to nodes. ---
        var result: [String: Classifier.TierFlags] = [:]
        result.reserveCapacity(n)
        for (u, node) in nodes.enumerated() { result[node] = sccFlags[sccOf[u]] }
        return result
    }
}
