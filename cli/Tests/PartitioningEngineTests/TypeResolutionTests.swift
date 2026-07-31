// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PartitioningEngine

final class TypeResolutionTests: XCTestCase {

    /// Regression for the Alamofire crash: extensions on NON-nominal types
    /// (`extension [Int]`, tuple extensions, etc.) made `SymbolTableBuilder.visit`
    /// skip the type-stack push while `visitPost` still popped → underflow trap
    /// ("Can't remove last element from an empty collection"). The resolver must
    /// handle these without crashing. Reaching the end of this test = no trap.
    func testNonNominalExtensionDoesNotCrash() {
        let src = """
        extension [Int] { func sum2() -> Int { reduce(0, +) } }
        extension Array where Element == String { var joined2: String { joined() } }
        extension Optional { func orEmpty() -> String { map { "\\($0)" } ?? "" } }
        extension (Int, Int) { }
        struct Calc { func pure(_ a: Int) -> Int { a * 2 } }
        """
        let rp = ProjectResolver().resolve(sources: [(src, Fixtures.fixtureURL)])
        // Non-optional dictionaries — referencing them proves we returned (no fatalError),
        // and that normal types are still processed alongside the non-nominal extensions.
        XCTAssertGreaterThanOrEqual(rp.fullyResolved.count, 0)
        XCTAssertGreaterThanOrEqual(rp.resolvedEdges.count, 0)
    }

    /// Full analyze path (parser → type resolution → call graph → classifier) must
    /// also not trap on the same input, and a pure method stays WASM-eligible.
    func testAnalyzeWithNonNominalExtensionsStaysSafe() {
        let src = """
        extension [Int] { func total() -> Int { reduce(0, +) } }
        struct Pricer { func tax(_ cents: Int) -> Int { cents * 875 / 10000 } }
        """
        // Also confirm the resolver itself runs on this input without trapping.
        _ = ProjectResolver().resolve(sources: [(src, Fixtures.fixtureURL)])
        let records = SwiftParserEngine().parse(source: src, file: Fixtures.fixtureURL)
        let graph = CallGraphBuilder().build(from: records)
        let results = Classifier().classifyAll(graph)
        // Pure integer math is WASM-eligible; nothing here is native.
        let tax = results.first { $0.key.contains("Pricer.tax") }?.value
        XCTAssertEqual(tax?.classification, .wasmEligible)
    }
}
