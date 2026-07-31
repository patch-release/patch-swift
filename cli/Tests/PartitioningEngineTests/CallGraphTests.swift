// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PartitioningEngine

final class CallGraphTests: XCTestCase {
    private func graph(_ source: String) -> CallGraph {
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        return CallGraphBuilder().build(from: records)
    }

    func testEdgesAreBuilt() {
        let g = graph(Fixtures.sample)
        // square -> multiply
        let squareID = g.nodes.first { $0.contains("Calc.square") }
        let multiplyID = g.nodes.first { $0.contains("Calc.multiply") }
        XCTAssertNotNil(squareID); XCTAssertNotNil(multiplyID)
        XCTAssertTrue(g.callees(of: squareID!).contains(multiplyID!),
                      "square should call multiply. edges: \(g.edges[squareID!] ?? [])")
        // reverse edge present
        XCTAssertTrue(g.callers(of: multiplyID!).contains(squareID!))
    }

    func testTransitiveClosure() {
        let g = graph(Fixtures.sample)
        let squareID = g.nodes.first { $0.contains("Calc.square") }!
        let multiplyID = g.nodes.first { $0.contains("Calc.multiply") }!
        let closure = g.transitiveClosure(from: squareID)
        XCTAssertTrue(closure.contains(squareID))
        XCTAssertTrue(closure.contains(multiplyID), "Closure of square should include multiply")
    }

    func testTransitiveClosureIsCycleSafe() {
        let src = """
        struct R {
            func a() { b() }
            func b() { a() }
        }
        """
        let g = graph(src)
        let aID = g.nodes.first { $0.contains("R.a") }!
        let closure = g.transitiveClosure(from: aID)
        XCTAssertTrue(closure.contains(aID))
        XCTAssertEqual(closure.count, 2, "Mutual recursion should terminate with both nodes")
    }

    // MARK: - Robustness: duplicate-id de-dup must not TRAP

    /// `build(from:)` keys records by `.id` via `Dictionary(uniquingKeysWith:)`.
    /// Two DISTINCT records sharing the same `.id` (e.g. two closures the parser
    /// emits on the same line) must NOT crash the engine. `dedupe` renames the
    /// collision to `<id>#n`; the keep-first guard then makes the Dictionary build
    /// trap-proof even if `dedupe`'s contract ever changes.
    func testBuildWithDuplicateRecordIDsDoesNotTrap() {
        let url = Fixtures.fixtureURL
        let dupID = "App.Type.handler(_:)"
        let records = [
            FunctionRecord(id: dupID, kind: .closure, sourceFile: url,
                           startLine: 10, endLine: 10, bodyReferences: []),
            // A SECOND, distinct record with the SAME id — would TRAP a
            // `Dictionary(uniqueKeysWithValues:)`.
            FunctionRecord(id: dupID, kind: .closure, sourceFile: url,
                           startLine: 10, endLine: 10,
                           bodyReferences: [Reference(name: "foo", kind: .functionCall, line: 10)]),
        ]
        // Must not crash.
        let g = CallGraphBuilder().build(from: records)
        // The original id survives (keep-first); the collision is renamed, so BOTH
        // records are retained as distinct nodes (the synthetic ambiguous sink may
        // also be present).
        XCTAssertTrue(g.nodes.contains(dupID), "Original id must be kept (keep-first).")
        XCTAssertTrue(g.nodes.contains("\(dupID)#2"), "Collision must be renamed, not dropped.")
        // Keep-first means the node at the original id is the FIRST record (no body refs).
        XCTAssertEqual(g.records[dupID]?.startLine, 10)
        XCTAssertTrue(g.records[dupID]?.bodyReferences.isEmpty == true,
                      "Keep-first: the original id maps to the first (empty-body) record.")
    }
}
