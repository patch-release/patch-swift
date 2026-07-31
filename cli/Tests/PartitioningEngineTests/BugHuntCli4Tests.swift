// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler
@testable import ViewNodeIR

/// Regression tests for the FOURTH CLI/engine bug-hunt pass. Each test FAILS on the
/// pre-fix code and PASSES after the surgical fix. See /tmp/bughunt_cli4_progress.md.
final class BugHuntCli4Tests: XCTestCase {

    // MARK: - BUG 1 (P1): SwiftUI dispatch event ids must be DETERMINISTIC
    //
    // The Button action id + `.onTapGesture` event id were derived from
    // `String.hashValue`, which Swift SEEDS PER PROCESS (random per launch). So the
    // SAME interactive view lowered twice produced DIFFERENT event ids — the
    // emitted guest source (and thus the WASM module) churned every build:
    // non-reproducible builds, broken artifact diffing/caching, and a dispatch
    // tree whose ids drift run-to-run. The fix uses a stable FNV-1a hash.

    private let tapSource = """
    import SwiftUI
    struct CounterView: View {
        @State var count: Int = 0
        var body: some View {
            VStack {
                Text("Count")
                    .onTapGesture { count = count >= 9 ? 0 : count + 1 }
                Button("Reset") { count = 0 }
            }
        }
    }
    """

    /// Lowering the SAME view yields BYTE-IDENTICAL guest source across calls — the
    /// event ids must not depend on a per-process hash seed.
    func testDispatchEventIDsAreDeterministicAcrossLowerings() {
        let a = BodyLowering().emitGuestBody(source: tapSource)
        let b = BodyLowering().emitGuestBody(source: tapSource)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b, "the lowered guest body (incl. event ids) must be deterministic")

        // And the derived event id must be the STABLE FNV-1a value, not a random one.
        let lowered = BodyLowering().lowerAllViews(source: tapSource)
        let model = lowered.first?.stateModel
        XCTAssertNotNil(model, "interactive view yields a state model")
        // Every emitted event id appears verbatim in the guest body (tree carries it).
        for rule in model?.rules ?? [] {
            XCTAssertTrue(a?.contains("\"\(rule.eventID)\"") ?? false,
                          "event id \(rule.eventID) must appear in the lowered tree")
        }
    }

    /// The stable hash is process-INDEPENDENT: a fixed input maps to a fixed value
    /// regardless of the per-process hash seed. The pinned constant is what catches a
    /// regression back to `String.hashValue` (which would yield a random value here).
    /// Pinned FNV-1a full-64-bit hex values (computed offline).
    ///
    /// NOTE: The return type changed from `Int` (mod 100000) to `String` (full 16-hex-char)
    /// in the fix for the FALSE-NATIVE collision bug — two buttons with the same label
    /// but different actions were colliding in the 100k-bucket space, making the
    /// `viewBodyContentHash` identical for semantically-different views.
    func testStableEventHashIsFixedForKnownInput() {
        XCTAssertEqual(Emitter.stableEventHash("count = 0"), "d7747033cdaadc9b",
                       "FNV-1a of \"count = 0\" (full 64-bit hex) is fixed across processes")
        XCTAssertEqual(Emitter.stableEventHash("count += 1"), "3df5ddbedb44225b")
        // Two DIFFERENT source slices get different ids (no trivial collapse).
        XCTAssertNotEqual(Emitter.stableEventHash("count = 0"),
                          Emitter.stableEventHash("count += 1"))
    }

    // MARK: - BUG 2 (P1): T0 value-type reconstruction must not pick a REORDERING init
    //
    // `valueTypeShape` chose `exact.first` — ANY init with the right param count —
    // even when its labels reorder the stored fields (e.g. `init(y:, x:)` on a
    // struct whose stored order is `x, y`). The T0 reconstruction pairs value[i]
    // with label[i], so a reordering init SWAPS the field values silently and ships
    // WRONG computed results. The fix rejects a labeled init whose labels don't
    // match the field names positionally (→ routes to the name-keyed T2 wrapper).

    private func shape(for typeName: String, source: String) throws
        -> CodeEmitter.PureExport.ValueTypeShape? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bughunt4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Types.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let bundler = DependencyClosureBundler()
        let index = bundler.index(for: [file])
        return bundler.valueTypeShape(for: typeName, index: index)
    }

    /// A struct with a REORDERING custom init must NOT produce a T0 shape (it would
    /// swap field values). It correctly returns nil → the name-keyed T2 path.
    func testReorderingInitIsNotUsedForT0Reconstruction() throws {
        let s = try shape(for: "Point", source: """
        struct Point {
            let x: Int
            let y: Int
            init(y: Int, x: Int) { self.x = x; self.y = y }
        }
        """)
        XCTAssertNil(s, "a field-reordering init must NOT yield a T0 reconstruction shape")
    }

    /// A struct with the conventional memberwise-matching init still reconstructs at
    /// T0, with the labels in stored-field order (no regression).
    func testMemberwiseMatchingInitStillReconstructs() throws {
        let s = try XCTUnwrap(try shape(for: "Point", source: """
        struct Point {
            let x: Int
            let y: Int
            init(x: Int, y: Int) { self.x = x; self.y = y }
        }
        """))
        XCTAssertEqual(s.fields.map { $0.name }, ["x", "y"])
        XCTAssertEqual(s.initLabels ?? [], ["x", "y"])
    }

    /// A Euclid-style ALL-POSITIONAL init (`init(_ x, _ y)`) still reconstructs at
    /// T0 (the convention is positional == stored order).
    func testAllPositionalInitStillReconstructs() throws {
        let s = try XCTUnwrap(try shape(for: "Vec", source: """
        struct Vec {
            var x: Double
            var y: Double
            init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
        }
        """))
        XCTAssertEqual(s.initLabels ?? [], ["_", "_"])
    }

    /// The synthesized memberwise init (no explicit init) still reconstructs with
    /// field-name labels.
    func testSynthesizedMemberwiseInitReconstructs() throws {
        let s = try XCTUnwrap(try shape(for: "P", source: """
        struct P { var a: Int; var b: Int }
        """))
        XCTAssertEqual(s.initLabels ?? [], ["a", "b"])
    }

    // MARK: - Codable-return bridge: enrichValueTypeShapes attaches a return shape

    /// `enrichValueTypeShapes` must attach a `returnShape` for a function returning a
    /// flat-scalar value type, so the T0 emitter hand-encodes the result (the
    /// encode-side of the value-type / Codable-return bridge). A non-reconstructable
    /// return must get NO shape (demote-safe → Foundation T2).
    func testEnrichAttachesReturnShapeForFlatScalarValueType() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("enrich-ret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Types.swift")
        try """
        struct User { var id: Int; var name: String }
        struct Wrapped { var inner: User }   // nested value type — reconstructable via LEVER #1
        struct HasDecimal { var amount: Decimal }   // a non-reconstructable field → no shape
        """.write(to: file, atomically: true, encoding: .utf8)
        let bundler = DependencyClosureBundler()
        let index = bundler.index(for: [file])
        let pipeline = BuildPipeline()

        // Flat-scalar return → shape attached, and the T0 emitter selects T0.
        let flat = CodeEmitter.PureExport(
            exportName: "makeUser", callee: "makeUser",
            parameters: [(label: "_", name: "id", type: "Int")], returnType: "User")
        let enriched = pipeline.enrichValueTypeShapes(flat, bundler: bundler, index: index)
        let rs = try XCTUnwrap(enriched.returnShape, "a flat-scalar value-type return must get a shape")
        XCTAssertEqual(rs.typeName, "User")
        XCTAssertEqual(rs.fields.map { $0.name }, ["id", "name"])
        let t0 = CodeEmitter().emitPureExportFile(enriched, includeAllocator: true)
        XCTAssertFalse(t0.source.contains("JSONEncoder"),
                       "an enriched flat-scalar return must ride the hand-encoded T0 wrapper\n\(t0.source)")
        XCTAssertTrue(t0.source.contains("_patchEncodeObj_makeUser"))

        // LEVER #1 — a NESTED value-type return (`Wrapped { inner: User }`) now gets a
        // RECURSIVE shape (User is flat-scalar) → rides T0 with hand-(de)coding.
        let nested = CodeEmitter.PureExport(
            exportName: "makeWrapped", callee: "makeWrapped",
            parameters: [(label: "_", name: "n", type: "Int")], returnType: "Wrapped")
        let enrichedNested = pipeline.enrichValueTypeShapes(nested, bundler: bundler, index: index)
        let nestedShape = try XCTUnwrap(enrichedNested.returnShape,
                     "a nested-struct return whose inner type is flat-scalar now gets a T0 shape (LEVER #1)")
        XCTAssertEqual(nestedShape.typeName, "Wrapped")
        let innerField = try XCTUnwrap(nestedShape.fields.first { $0.name == "inner" })
        XCTAssertEqual(innerField.nestedShape?.typeName, "User",
                       "the inner field carries User's reconstruction shape")
        XCTAssertEqual(innerField.nestedShape?.fields.map { $0.name }, ["id", "name"])
        let t0Nested = CodeEmitter().emitPureExportFile(enrichedNested, includeAllocator: true)
        XCTAssertFalse(t0Nested.source.contains("JSONEncoder"),
                       "a nested-but-reconstructable return now rides the hand-encoded T0 wrapper\n\(t0Nested.source)")

        // DEMOTE-SAFE — a struct with a TRULY non-reconstructable field (`Decimal`,
        // no flat-scalar form) still gets NO shape → Foundation (T2).
        let dec = CodeEmitter.PureExport(
            exportName: "makeDec", callee: "makeDec",
            parameters: [(label: "_", name: "n", type: "Int")], returnType: "HasDecimal")
        let enrichedDec = pipeline.enrichValueTypeShapes(dec, bundler: bundler, index: index)
        XCTAssertNil(enrichedDec.returnShape,
                     "a Decimal-backed field has no flat-scalar form → no T0 shape (demote-safe)")
        let t2 = CodeEmitter().emitPureExportFile(enrichedDec, includeAllocator: true)
        XCTAssertTrue(t2.source.contains("JSONEncoder"),
                      "a non-reconstructable return must stay on the Foundation wrapper")
    }

    /// LEVER #1 — the bundler builds a RECURSIVE nested shape, and a self-referential
    /// cycle (`Node.next: Node`) is rejected (no finite JSON form → nil → T2).
    func testNestedShapeRecursesAndCutsCycles() throws {
        let nested = try XCTUnwrap(try shape(for: "Profile", source: """
        struct Address { var city: String; var zip: Int }
        struct Profile { var id: Int; var address: Address }
        """))
        let addr = try XCTUnwrap(nested.fields.first { $0.name == "address" }?.nestedShape)
        XCTAssertEqual(addr.typeName, "Address")
        XCTAssertEqual(addr.fields.map { $0.name }, ["city", "zip"])

        // A self-referential value type has no finite reconstruction → nil.
        let cyclic = try shape(for: "Node", source: """
        struct Node { var value: Int; var next: Node }
        """)
        XCTAssertNil(cyclic, "a self-referential value type must not yield a (non-terminating) shape")
    }
}
