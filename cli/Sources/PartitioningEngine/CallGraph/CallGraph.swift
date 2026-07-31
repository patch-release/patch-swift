// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A directed call graph over parsed functions.
///
/// Nodes are function ids (`FunctionRecord.id`). Edges go caller → callee.
/// `reverseEdges` go callee → caller. `transitiveClosure(from:)` returns every
/// node reachable from a starting node (the callee-side closure used by the
/// classifier).
///
/// Agent A1 scope. Edge resolution is intentionally conservative: when a call
/// cannot be resolved to a single known function, we (a) keep it as an
/// *unresolved reference* on the node so the classifier can fall back to
/// native, and (b) for dynamic dispatch over a protocol/superclass, we add
/// edges to *all* plausible concrete implementations.
public struct CallGraph: Sendable {
    public typealias Node = String

    public private(set) var nodes: Set<Node>
    public private(set) var edges: [Node: Set<Node>]
    public private(set) var reverseEdges: [Node: Set<Node>]

    /// Records keyed by id, for classifier lookups.
    public let records: [Node: FunctionRecord]

    /// References on each node that could not be resolved to a known function
    /// (free/library calls, member accesses, type names). The classifier
    /// inspects these against the NativeRegistry.
    public let unresolvedReferences: [Node: [Reference]]

    public init(
        nodes: Set<Node>,
        edges: [Node: Set<Node>],
        reverseEdges: [Node: Set<Node>],
        records: [Node: FunctionRecord],
        unresolvedReferences: [Node: [Reference]]
    ) {
        self.nodes = nodes
        self.edges = edges
        self.reverseEdges = reverseEdges
        self.records = records
        self.unresolvedReferences = unresolvedReferences
    }

    /// Direct callees of `node`.
    public func callees(of node: Node) -> Set<Node> {
        edges[node] ?? []
    }

    /// Direct callers of `node`.
    public func callers(of node: Node) -> Set<Node> {
        reverseEdges[node] ?? []
    }

    /// Every node reachable from `node` following caller→callee edges,
    /// *including* `node` itself. Iterative + cycle-safe (visited set).
    public func transitiveClosure(from node: Node) -> Set<Node> {
        transitiveClosure(from: node, cap: Int.max).visited
    }

    /// Iterative, cap-bounded transitive closure. Explores callee→callee edges
    /// with an explicit stack and a visited-set (never recursive — safe on the
    /// dense corpus graphs). If exploration would exceed `cap` distinct nodes the
    /// walk stops early and `capped == true` is returned; the caller MUST then
    /// treat the function conservatively (classify `native`). This is the
    /// per-node safety valve for giant apps: stopping early can only ever cause a
    /// FALSE POSITIVE (pure code marked native), never a false negative.
    public func transitiveClosure(from node: Node, cap: Int) -> (visited: Set<Node>, capped: Bool) {
        var visited: Set<Node> = []
        var stack: [Node] = [node]
        while let current = stack.popLast() {
            guard !visited.contains(current) else { continue }
            visited.insert(current)
            if visited.count > cap { return (visited, true) }
            for callee in edges[current] ?? [] where !visited.contains(callee) {
                stack.append(callee)
            }
        }
        return (visited, false)
    }

    /// Total number of caller→callee edges.
    public var edgeCount: Int {
        edges.values.reduce(0) { $0 + $1.count }
    }
}
