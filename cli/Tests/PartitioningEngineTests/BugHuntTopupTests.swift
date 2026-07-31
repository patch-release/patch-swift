// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import PartitioningEngine
@testable import CodeGenerator

/// Regression tests for the CLI "top-up" bug-hunt pass (item A of the cli3
/// findings): the Foundation (non-T0) export path must never ship a result blob
/// the SDK's default `JSONDecoder` cannot read.
///
/// Each test FAILS on the pre-fix code and PASSES after the fix.
final class BugHuntTopupTests: XCTestCase {

    // MARK: - BUG A (P1): Foundation-path non-finite Double/Float crashes SDK decode

    /// The Foundation wrapper encodes the `_Out` envelope with a default
    /// `JSONEncoder`, which THROWS on a non-finite (NaN/±Inf) Double/Float. The
    /// wrapper's `try?` then degrades the result to `Data("{}".utf8)` — so the
    /// SDK decoding `_Out { value: Double }` fails on the MISSING `value` field
    /// (`try!` → crash), not just a wrong number. A tuple `(Double, Double)`
    /// return forces the Foundation TUPLE path; both components must be clamped
    /// via `_patchFinite(...)` so the encoder always gets a finite, encodable
    /// number and the wire stays a plain JSON number the SDK decodes.
    func testFoundationTupleWrapperClampsNonFiniteFloatComponents() {
        let export = CodeEmitter.PureExport(
            exportName: "minmax", callee: "Stats.minmax",
            parameters: [(label: "_", name: "xs", type: "[Double]")],
            returnType: "(Double, Double)")
        // A `[Double]` arg + tuple return is NOT host-scalar reducible → Foundation.
        XCTAssertNil(
            CodeEmitter().emitEmbeddedPureExportFile(export, includeAllocator: true),
            "an array-arg / tuple-return export must not ride the T0 host-bridge path")

        let f = CodeEmitter().emitFoundationPureExportFilePublic(export, includeAllocator: true)
        // The non-finite guard helper must be present...
        XCTAssertTrue(f.source.contains("func _patchFinite"),
                      "Foundation file must define the non-finite float guard\n\(f.source)")
        // ...and BOTH Double components must flow through it before encoding.
        XCTAssertTrue(f.source.contains("_patchFinite(_result.0)"),
                      "first Double tuple component must be clamped\n\(f.source)")
        XCTAssertTrue(f.source.contains("_patchFinite(_result.1)"),
                      "second Double tuple component must be clamped\n\(f.source)")
    }

    /// A Foundation SINGLE-output Double result (e.g. a struct-arg function that
    /// can't ride T0) must clamp `_result` before building the `_Out` envelope.
    func testFoundationSingleDoubleOutputIsClamped() {
        let export = CodeEmitter.PureExport(
            exportName: "area", callee: "Shape.area",
            parameters: [(label: "_", name: "p", type: "Point")],  // struct arg → Foundation
            returnType: "Double")
        XCTAssertNil(
            CodeEmitter().emitEmbeddedPureExportFile(export, includeAllocator: true),
            "a struct-arg export must not ride T0")
        let f = CodeEmitter().emitFoundationPureExportFilePublic(export, includeAllocator: true)
        XCTAssertTrue(f.source.contains("value: _patchFinite(_result)"),
                      "single Double output must be clamped before encoding\n\(f.source)")
    }

    /// A non-float output (e.g. `String`) must NOT be wrapped — the clamp only
    /// applies to the float types the encoder would reject.
    func testFoundationNonFloatOutputIsNotClamped() {
        let export = CodeEmitter.PureExport(
            exportName: "describe", callee: "Shape.describe",
            parameters: [(label: "_", name: "p", type: "Point")],
            returnType: "String")
        let f = CodeEmitter().emitFoundationPureExportFilePublic(export, includeAllocator: true)
        XCTAssertTrue(f.source.contains("value: _result"),
                      "a String output must pass through unclamped\n\(f.source)")
        XCTAssertFalse(f.source.contains("_patchFinite(_result)"),
                       "a non-float output must not be clamped")
    }

    /// The float-type classifier underpins the clamp decision: it must recognize
    /// the stdlib float types backed by Double/Float (including a top-level
    /// Optional) and reject everything else.
    func testIsClampableFloatTypeClassifier() {
        for t in ["Double", "Float", "Float64", "Float32", "TimeInterval",
                  "Double?", " Float ", "TimeInterval?"] {
            XCTAssertTrue(CodeEmitter.isClampableFloatType(t),
                          "\(t) must be treated as a clampable float type")
        }
        for t in ["Int", "String", "Bool", "[Double]", "CGFloat", "Point", "UInt64"] {
            XCTAssertFalse(CodeEmitter.isClampableFloatType(t),
                           "\(t) must NOT be treated as a clampable float type")
        }
    }

    /// PROOF the clamping logic produces JSON the SDK's standard JSONDecoder can
    /// read for non-finite inputs. Reproduces the emitted `_patchFinite` + the
    /// default-`JSONEncoder` envelope and asserts the bytes decode into a Double
    /// (the pre-fix path produced `{}` → a missing-field decode failure).
    func testFoundationClampedEnvelopeDecodesForNonFinite() throws {
        struct Out: Codable { let value: Double }
        func patchFinite(_ v: Double) -> Double {
            if v.isNaN { return 0 }
            if v.isInfinite { return v < 0 ? -Double.greatestFiniteMagnitude : .greatestFiniteMagnitude }
            return v
        }
        for v in [Double.nan, .infinity, -.infinity, 3.5, 0.0] {
            let out = Out(value: patchFinite(v))
            // The default encoder must NOT throw now that the value is finite.
            let data = try JSONEncoder().encode(out)
            // And the SDK's default decoder reads the required `value` field.
            let decoded = try JSONDecoder().decode(Out.self, from: data)
            XCTAssertTrue(decoded.value.isFinite,
                          "decoded value must be finite for input \(v)")
        }

        // Counter-proof: the UNCLAMPED non-finite value makes the default encoder
        // throw — exactly the pre-fix failure that degraded the blob to `{}`.
        XCTAssertThrowsError(try JSONEncoder().encode(Out(value: .nan)),
                             "the default JSONEncoder must reject a raw NaN (pre-fix path)")
    }

    // MARK: - BUG D (P2): project-type shadowing must NOT suppress a MODULE-QUALIFIED native ref

    /// The classifier suppresses a registry hit whenever the project declares a
    /// nominal type by that name — correct for an UNQUALIFIED reference (Swift
    /// binds bare `Timer` to a project `struct Timer`). But a MODULE-QUALIFIED
    /// reference (`Foundation.Timer`) is NOT shadowed: Swift binds it to the
    /// framework type. The pre-fix code suppressed it anyway, misclassifying a
    /// genuine framework use as pure → it could ship broken WASM. The fix keeps
    /// the hit for the qualified form while still shadowing the bare form.
    ///
    /// End-to-end proof through the real pipeline: a project declaring `struct
    /// Timer` whose function uses the MODULE-QUALIFIED `Foundation.Timer` must NOT
    /// be classified wasmEligible (the native ref must survive shadow-suppression),
    /// while a function over the project's OWN bare `Timer` stays eligible.
    func testQualifiedNativeRefSurvivesShadowingInPipeline() {
        let src = """
        struct Timer { let ticks: Int
            func doubled() -> Int { ticks * 2 }
        }
        enum Scheduler {
            static func schedule() -> Int {
                let t = Foundation.Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in }
                return Int(t.timeInterval)
            }
        }
        """
        let report = analyzeTopup([(src, "Sched.swift")])
        let schedule = report.results.first { $0.functionID.contains("Scheduler.schedule") }
        XCTAssertNotNil(schedule, "expected a result for Scheduler.schedule")
        XCTAssertNotEqual(schedule?.classification, .wasmEligible,
            "ZERO-FALSE-NEGATIVE: `Foundation.Timer` is the real framework Timer and must not be shadowed by a project `struct Timer`")

        // Control: the project's own pure `Timer.doubled` IS eligible (bare ref
        // genuinely resolves to the project type).
        let doubled = report.results.first { $0.functionID.contains("Timer.doubled") }
        XCTAssertEqual(doubled?.classification, .wasmEligible,
            "a pure method over the project's own `Timer` stays wasmEligible")
    }

    /// Run the full parser → resolver → call-graph → classifier pipeline the way
    /// the engine does (mirrors ShadowingSafetyTests.analyze).
    private func analyzeTopup(_ sources: [(String, String)]) -> CoverageReport {
        let dir = URL(fileURLWithPath: "/tmp/PatchTopupFixtures")
        let tuples = sources.map { (src, name) in (src, dir.appendingPathComponent(name)) }
        let resolved = ProjectResolver().resolve(sources: tuples)
        let parser = SwiftParserEngine()
        var records: [FunctionRecord] = []
        for (src, file) in tuples { records += parser.parse(source: src, file: file) }
        return PartitioningEngine().analyze(records: records, fileCount: tuples.count, resolved: resolved)
    }
}
