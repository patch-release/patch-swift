// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Builds a `CallGraph` from a flat list of `FunctionRecord`s.
///
/// Resolution strategy (conservative for safety — Agent A1):
///   1. Index records by *simple call name* (e.g. `validateOrder(_:)` and the
///      bare `validateOrder`). A call resolves to a function when its name
///      matches a known record's simple name or base name.
///   2. Dynamic dispatch: when a call's simple name matches *several* records
///      (e.g. a protocol method implemented by several types), edges are added
///      to ALL of them — we never guess a single target.
///   3. Anything that does not match a known function is retained as an
///      *unresolved reference* on the node, so the classifier can test it
///      against the NativeRegistry (and default to native when in doubt).
public struct CallGraphBuilder {
    /// Maximum number of candidate targets a single call name may resolve to
    /// before it is treated as *over-ambiguous dynamic dispatch*. Name-based
    /// resolution on a giant app (e.g. `setUp` defined 800+ times) would
    /// otherwise add N² edges from one name — `wire-ios` produced 10.5M edges and
    /// stalled the analyzer for >2 min. Above this cap we add a single edge to a
    /// synthetic *ambiguous-native sink* instead of N precise edges. This is
    /// SAFE (zero false negatives): the sink `forcesNative`, so any caller whose
    /// closure reaches it is classified `native` — strictly more conservative
    /// than the old behaviour (which could have propagated purity through the
    /// candidate set). It only ever *reduces* coverage, never breaks safety, and
    /// it bounds total edges to ~`cap × callSites`, making analysis linear.
    public static let dynamicDispatchFanoutCap = 300

    /// Synthetic node id for over-ambiguous call targets. It carries a
    /// `forcesNative` record so the classifier treats reaching it as native.
    public static let ambiguousSinkID = "__Patch.ambiguousDynamicDispatch__"

    public let fanoutCap: Int

    /// The optional type-resolution layer. When supplied, a function whose calls
    /// were ALL precisely resolved (`ResolvedProject.fullyResolved == true`) uses
    /// its *resolved* callee record-ids — eliminating the spurious name-based
    /// fan-out (the `setUp`-overload explosion) that forced conservative-native.
    /// Functions the resolver could not fully resolve fall back to name-based
    /// resolution unchanged. Always nil-safe: with no resolver, behaviour is
    /// identical to the original name-based builder.
    public let resolved: ResolvedProject?

    public init(fanoutCap: Int = CallGraphBuilder.dynamicDispatchFanoutCap,
                resolved: ResolvedProject? = nil) {
        self.fanoutCap = fanoutCap
        self.resolved = resolved
    }

    public func build(from records: [FunctionRecord]) -> CallGraph {
        // `dedupe` uniquifies by `.id` (renaming any collision to `<id>#n` against a running
        // `seen` set), so the mapped keys are unique by construction today. `Dictionary(
        // uniqueKeysWithValues:)` TRAPS on a duplicate key, though — a hard crash inside the
        // engine that, unlike a demote, has NO backstop and aborts the whole app's module build
        // (the same bug class as the `buildStateModel` fix in SwiftUIBodyLowering). Build it
        // defensively with `uniquingKeysWith:` so a future change to `dedupe` (or a record set
        // that de-dupes by value rather than `.id`) can never reintroduce that trap. Keep FIRST,
        // matching `dedupe`'s own keep-first intent.
        var recordsByID = Dictionary(
            dedupe(records).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Synthetic ambiguous-dynamic-dispatch sink: forces native. Edges to it
        // are added in place of an over-ambiguous candidate fan-out.
        let sinkID = Self.ambiguousSinkID
        recordsByID[sinkID] = FunctionRecord(
            id: sinkID, kind: .function,
            sourceFile: URL(fileURLWithPath: "/__patch_synthetic__"),
            startLine: 0, endLine: 0, bodyReferences: [],
            forcesNative: true,
            nativeFlags: ["over-ambiguous dynamic dispatch (>\(fanoutCap) candidates) — conservatively native"]
        )
        let nodes = Set(recordsByID.keys)

        // Index: simple call name -> set of record ids that could satisfy it.
        var nameIndex: [String: Set<String>] = [:]
        for record in recordsByID.values where record.id != sinkID {
            for key in callNameKeys(for: record) {
                nameIndex[key, default: []].insert(record.id)
            }
        }

        var edges: [String: Set<String>] = [:]
        var reverseEdges: [String: Set<String>] = [:]
        var unresolved: [String: [Reference]] = [:]

        for record in recordsByID.values where record.id != sinkID {
            // ---- Type-resolved fast path ----------------------------------
            // When the resolver fully resolved this function's calls, use its
            // PRECISE callee record-ids (bounded to the receiver's real type /
            // its real conformers) instead of name-based fan-out. This removes
            // the spurious overload explosion that forced conservative-native.
            // The unresolved-reference set (for the registry scan) is STILL built
            // from every body reference below — so a resolved-but-native call
            // (e.g. `URLSession.shared.data(for:)`) is still caught. SAFE: precise
            // edges are a SUBSET of (or equal to) the name-based ones, never a
            // superset that could hide a native dependency.
            let useResolved = (resolved?.fullyResolved[record.id] == true)
            if useResolved, let resolvedTargets = resolved?.resolvedEdges[record.id] {
                for target in resolvedTargets where target != record.id && nodes.contains(target) {
                    edges[record.id, default: []].insert(target)
                    reverseEdges[target, default: []].insert(record.id)
                }
            }

            for ref in record.bodyReferences {
                guard ref.kind == .functionCall || ref.kind == .memberAccess else {
                    // Type names / identifiers / attributes / selectors are not
                    // call edges; pass them through as unresolved for the
                    // classifier to scan against the registry.
                    if ref.kind == .typeName || ref.kind == .attribute || ref.kind == .selector {
                        unresolved[record.id, default: []].append(ref)
                    }
                    continue
                }

                // Always keep the reference for the registry/native scan — both in
                // the resolved and name-based path. A resolved call may itself be a
                // native API; the classifier scans edges AND unresolved refs.
                unresolved[record.id, default: []].append(ref)

                // In the resolved fast path, edges already came from the resolver;
                // skip name-based edge resolution entirely (the whole point — no
                // fan-out).
                if useResolved { continue }

                // ---- Name-based fallback (resolver unavailable / partial) ----
                let candidates = resolve(ref: ref, in: nameIndex)
                if candidates.isEmpty {
                    // Unresolved => already kept above for native scanning.
                } else if candidates.count > fanoutCap {
                    // Over-ambiguous dynamic dispatch: route to the native sink
                    // instead of fanning out N edges. Conservative + bounded.
                    edges[record.id, default: []].insert(sinkID)
                    reverseEdges[sinkID, default: []].insert(record.id)
                } else {
                    for target in candidates where target != record.id {
                        edges[record.id, default: []].insert(target)
                        reverseEdges[target, default: []].insert(record.id)
                    }
                }
            }
        }

        return CallGraph(
            nodes: nodes,
            edges: edges,
            reverseEdges: reverseEdges,
            records: recordsByID,
            unresolvedReferences: unresolved
        )
    }

    // MARK: - Resolution helpers

    /// Resolve a call/member reference to candidate function ids.
    private func resolve(ref: Reference, in index: [String: Set<String>]) -> Set<String> {
        var result: Set<String> = []
        // Match by exact simple name (e.g. "validateOrder").
        if let ids = index[ref.name] { result.formUnion(ids) }
        return result
    }

    /// The set of index keys under which a record can be called.
    private func callNameKeys(for record: FunctionRecord) -> [String] {
        // The simple name is the substring before "(" in the last id component.
        let lastComponent = record.id.split(separator: ".").last.map(String.init) ?? record.id
        let simple = lastComponent.split(separator: "(").first.map(String.init) ?? lastComponent
        if simple.isEmpty { return [lastComponent] }
        return [simple]
    }

    /// Drop exact-duplicate ids (e.g. two closures on the same line) keeping the first.
    private func dedupe(_ records: [FunctionRecord]) -> [FunctionRecord] {
        var seen: Set<String> = []
        var result: [FunctionRecord] = []
        for r in records {
            var id = r.id
            var n = 1
            while seen.contains(id) {
                n += 1
                id = "\(r.id)#\(n)"
            }
            seen.insert(id)
            if id == r.id {
                result.append(r)
            } else {
                result.append(
                    FunctionRecord(
                        id: id, kind: r.kind, sourceFile: r.sourceFile,
                        startLine: r.startLine, endLine: r.endLine,
                        bodyReferences: r.bodyReferences,
                        forcesNative: r.forcesNative, nativeFlags: r.nativeFlags
                    )
                )
            }
        }
        return result
    }
}
