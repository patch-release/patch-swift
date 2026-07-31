// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PartitioningEngine

final class ParserTests: XCTestCase {
    func testExtractsFunctionRecords() {
        let parser = SwiftParserEngine()
        let records = parser.parse(source: Fixtures.sample, file: Fixtures.fixtureURL)

        // Expect at least the named methods to be extracted.
        let ids = Set(records.map { $0.id })
        let simpleNames = Set(records.map { $0.id.split(separator: ".").last.map(String.init) ?? "" })

        XCTAssertFalse(records.isEmpty, "Parser should extract function records")
        XCTAssertTrue(simpleNames.contains("addNumbers(_:_:)"), "Got: \(simpleNames)")
        XCTAssertTrue(simpleNames.contains("square(_:)"))
        XCTAssertTrue(simpleNames.contains("fetch(_:)"))
        XCTAssertTrue(simpleNames.contains("saveCount(_:)"))

        // Qualified ids should include the enclosing type.
        XCTAssertTrue(ids.contains { $0.contains("Calc.addNumbers") }, "Got: \(ids)")
        XCTAssertTrue(ids.contains { $0.contains("NetworkService.fetch") })
    }

    func testCapturesBodyReferences() {
        let parser = SwiftParserEngine()
        let records = parser.parse(source: Fixtures.sample, file: Fixtures.fixtureURL)
        guard let fetch = records.first(where: { $0.id.contains("NetworkService.fetch") }) else {
            return XCTFail("fetch not found")
        }
        let refNames = Set(fetch.bodyReferences.map { $0.name })
        XCTAssertTrue(refNames.contains("URLSession"), "Expected URLSession reference. Got: \(refNames)")
    }

    func testForcedNativeOnObjcAttribute() {
        // @objc on a method of a plain (non-NSObject) type must force native,
        // while a sibling pure method stays splittable.
        let src = """
        import Foundation
        struct Handler {
            @objc func tapped() { let x = 1; print(x) }
            func pure() -> Int { return 42 }
        }
        """
        let parser = SwiftParserEngine()
        let records = parser.parse(source: src, file: Fixtures.fixtureURL)
        let tapped = records.first { $0.id.contains("tapped") }
        let pure = records.first { $0.id.contains("pure") }
        XCTAssertEqual(tapped?.forcesNative, true, "@objc must force native")
        XCTAssertEqual(pure?.forcesNative, false)
    }

    func testNSObjectSubclassForcesNative() {
        // NSObject subclasses use the ObjC runtime → every member is native.
        let src = """
        import Foundation
        class Handler: NSObject {
            func anything() -> Int { return 42 }
        }
        """
        let parser = SwiftParserEngine()
        let records = parser.parse(source: src, file: Fixtures.fixtureURL)
        let anything = records.first { $0.id.contains("anything") }
        XCTAssertEqual(anything?.forcesNative, true, "NSObject subclass members must be native")
    }

    func testSelectorForcesNative() {
        let src = """
        import Foundation
        class T: NSObject {
            func setup() {
                let s = #selector(T.handle)
                _ = s
            }
            @objc func handle() {}
        }
        """
        let parser = SwiftParserEngine()
        let records = parser.parse(source: src, file: Fixtures.fixtureURL)
        let setup = records.first { $0.id.contains("setup") }
        XCTAssertEqual(setup?.forcesNative, true, "#selector must force native")
    }

    func testExtractsClosures() {
        let src = """
        func run() {
            let f = { (x: Int) in x + 1 }
            _ = f
        }
        """
        let parser = SwiftParserEngine()
        let records = parser.parse(source: src, file: Fixtures.fixtureURL)
        XCTAssertTrue(records.contains { $0.kind == .closure }, "Closure literal should be extracted")
    }
}
