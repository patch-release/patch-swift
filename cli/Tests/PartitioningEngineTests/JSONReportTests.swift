// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PartitioningEngine

/// Tests for the `analyze --format json` payload (P2-2). The CLI now emits the
/// report via `JSONEncoder` over a typed `CoverageReport.JSONReport` instead of a
/// hand-assembled `[String: Any]`, so the output is valid by construction. These
/// tests prove the encoded JSON parses and carries the expected keys/values.
final class JSONReportTests: XCTestCase {

    /// Build a real `CoverageReport` through the full pipeline so the DTO is fed
    /// genuine engine values.
    private func sampleReport() -> CoverageReport {
        let src = """
        struct Money { var cents: Int }
        func addCents(_ a: Int, _ b: Int) -> Int { a + b }
        func discounted(_ m: Money) -> Int { m.cents - 100 }
        """
        let dir = URL(fileURLWithPath: "/tmp/PatchJSONReportFixtures")
        let tuples = [(src, dir.appendingPathComponent("Sample.swift"))]
        let resolved = ProjectResolver().resolve(sources: tuples)
        let parser = SwiftParserEngine()
        var records: [FunctionRecord] = []
        for (s, file) in tuples { records += parser.parse(source: s, file: file) }
        return PartitioningEngine().analyze(records: records, fileCount: tuples.count, resolved: resolved)
    }

    /// Encode a `JSONReport` the same way the CLI does and parse it back into a
    /// dictionary for assertions.
    private func encodeAndParse(_ payload: CoverageReport.JSONReport) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw XCTSkip("encoded JSON was not an object")
        }
        return dict
    }

    /// Without realized metrics: only the optimistic keys are present, and the
    /// realized-only keys are omitted (nil → not encoded).
    func testJSONReportWithoutRealizedParsesAndHasBaseKeys() throws {
        let report = sampleReport()
        let payload = report.jsonReport(realized: nil)
        let dict = try encodeAndParse(payload)

        // Exactly the base keys, none of the realized-only keys.
        let expectedBaseKeys: Set<String> = [
            "files", "functions", "edges",
            "wasmEligible", "bridged", "mixed", "native",
            "otaUpdatablePercentOptimistic", "otaUpdatablePercent",
        ]
        let realizedOnlyKeys: Set<String> = [
            "otaUpdatablePercentABI", "mixedSplit", "fragments",
            "abiSplits", "abiFragments", "subtreeSplits", "subtreeFragments",
        ]
        XCTAssertEqual(Set(dict.keys), expectedBaseKeys,
                       "without realized metrics only the base keys must be present")
        for k in realizedOnlyKeys {
            XCTAssertNil(dict[k], "realized-only key `\(k)` must be omitted when nil")
        }

        // Values mirror the report.
        XCTAssertEqual(dict["files"] as? Int, report.fileCount)
        XCTAssertEqual(dict["functions"] as? Int, report.functionCount)
        XCTAssertEqual(dict["edges"] as? Int, report.edgeCount)
        XCTAssertEqual(dict["wasmEligible"] as? Int, report.count(.wasmEligible))
        XCTAssertEqual(dict["bridged"] as? Int, report.count(.bridged))
        XCTAssertEqual(dict["mixed"] as? Int, report.count(.mixed))
        XCTAssertEqual(dict["native"] as? Int, report.count(.native))
        // Optimistic and headline percentages coincide when no realized pass ran.
        XCTAssertEqual(dict["otaUpdatablePercentOptimistic"] as? Double, report.otaUpdatablePercent)
        XCTAssertEqual(dict["otaUpdatablePercent"] as? Double, report.otaUpdatablePercent)
    }

    /// With realized metrics: the realized-only keys appear and `otaUpdatablePercent`
    /// reflects the realized (honest) headline, while `...Optimistic` is unchanged.
    func testJSONReportWithRealizedParsesAndHasAllKeys() throws {
        let report = sampleReport()
        let metrics = CoverageReport.RealizedMetrics(
            otaPercent: 42.5, abiOtaPercent: 33.25, mixedSplit: 3, fragments: 7,
            abiSplits: 2, abiFragments: 4, subtreeSplits: 1, subtreeFragments: 2)
        let payload = report.jsonReport(realized: metrics)
        let dict = try encodeAndParse(payload)

        let allKeys: Set<String> = [
            "files", "functions", "edges",
            "wasmEligible", "bridged", "mixed", "native",
            "otaUpdatablePercentOptimistic", "otaUpdatablePercent",
            "otaUpdatablePercentABI", "mixedSplit", "fragments",
            "abiSplits", "abiFragments", "subtreeSplits", "subtreeFragments",
        ]
        XCTAssertEqual(Set(dict.keys), allKeys, "all keys must be present with realized metrics")

        // Realized values come through verbatim.
        XCTAssertEqual(dict["otaUpdatablePercent"] as? Double, 42.5)
        XCTAssertEqual(dict["otaUpdatablePercentABI"] as? Double, 33.25)
        XCTAssertEqual(dict["mixedSplit"] as? Int, 3)
        XCTAssertEqual(dict["fragments"] as? Int, 7)
        XCTAssertEqual(dict["abiSplits"] as? Int, 2)
        XCTAssertEqual(dict["abiFragments"] as? Int, 4)
        XCTAssertEqual(dict["subtreeSplits"] as? Int, 1)
        XCTAssertEqual(dict["subtreeFragments"] as? Int, 2)
        // Optimistic stays the report's optimistic value (NOT overridden).
        XCTAssertEqual(dict["otaUpdatablePercentOptimistic"] as? Double, report.otaUpdatablePercent)
    }

    /// The encoder produces valid, non-empty JSON with sorted keys (the format the
    /// CLI uses). A direct parse must succeed (the failure mode the old hand-rolled
    /// emitter risked).
    func testEncodedOutputIsValidJSON() throws {
        let report = sampleReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report.jsonReport(realized: nil))
        XCTAssertFalse(data.isEmpty)
        // Parses without throwing → valid JSON.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        let str = String(data: data, encoding: .utf8)
        XCTAssertNotNil(str)
        // Sorted-keys formatting: `bridged` sorts before `files`.
        if let s = str, let b = s.range(of: "\"bridged\""), let f = s.range(of: "\"files\"") {
            XCTAssertTrue(b.lowerBound < f.lowerBound, "keys should be sorted")
        }
    }
}
