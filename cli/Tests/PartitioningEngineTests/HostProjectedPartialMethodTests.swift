// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftParser
@testable import PartitioningEngine
@testable import CodeGenerator

/// Tests for the MULTI-STATEMENT / PARTIAL host-projection lift (subset (b)).
///
/// The whole-body host-projection (subset (a)) lifts a clean single-value member
/// (returns a marshallable value, writes nothing). Subset (b) is the dominant
/// real-world shape it misses: a METHOD that reads a value-marshallable reactive
/// prop among otherwise-pure statements AND keeps native statements — a Void
/// return, or a write to a NON-reactive stored property. Such a method is split
/// PARTIALLY: the native shell projects the reactive reads into locals, the pure
/// middle statements ride WASM (statement-level), and the native writes stay
/// verbatim in the shell, in original order.
///
/// Two themes (mirroring the project's safety contract):
///   1. COVERAGE — a method with a pure run over projected reactive reads, sitting
///      among native writes, realizes to ≥1 ABI-executable fragment.
///   2. DEMOTE-SAFETY (cardinal rule) — a method that WRITES reactive state, whose
///      pure work captures an unbound local, calls a native API, or has no liftable
///      pure run STAYS NATIVE. When in doubt → native; never a wrong split.
final class HostProjectedPartialMethodTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/hostproject_partial.swift")

    private func classify(_ source: String) -> [String: ClassificationResult] {
        let records = SwiftParserEngine().parse(source: source, file: file)
        let g = CallGraphBuilder().build(from: records)
        return Classifier().classifyAll(g)
    }

    private func result(_ results: [String: ClassificationResult], _ query: String) -> ClassificationResult? {
        results.first { key, _ in
            let comps = key.split(separator: ".").map(String.init)
            guard let last = comps.last else { return false }
            let memberName = last.split(separator: "(").first.map(String.init) ?? last
            return memberName == query
        }?.value
    }

    private func record(_ source: String, _ idSuffix: String) -> FunctionRecord? {
        SwiftParserEngine().parse(source: source, file: file)
            .first { $0.id.hasSuffix("." + idSuffix) || $0.id.contains("." + idSuffix + "(") }
    }

    private func plan(_ source: String, _ idSuffix: String,
                      nativeCallees: Set<String> = []) -> SplitPlan? {
        guard let rec = record(source, idSuffix) else { return nil }
        let tree = Parser.parse(source: source)
        let index = DeclarationIndex(tree: tree)
        var outcome: FunctionSplitter.Outcome = .noBody
        return FunctionSplitter(nativeCalleeNames: nativeCallees)
            .plan(for: rec, index: index, inferredTypes: [:], outcome: &outcome)
    }

    // MARK: - Coverage (positive partial lifts)

    /// The canonical subset (b) shape: read a reactive scalar, derive a pure value,
    /// then WRITE it to a NON-reactive stored property. The pure derivation lifts;
    /// the native write stays in the shell after the fragment binds its output.
    func testReadDeriveWriteNonReactiveRealizes() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var counter: Int = 0
            var cache: Int = 0
            func refresh() {
                let doubled = counter * 2
                let bumped = doubled + 1
                self.cache = bumped
            }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "refresh")?.classification, .mixed,
                       "a method reading a reactive scalar, deriving purely, then writing a non-reactive prop → host-projected partial (mixed)")
        let rec = record(src, "refresh")
        XCTAssertEqual(rec?.hostProjectablePartial, true, "must be a partial host-projection candidate")
        guard let plan = plan(src, "refresh") else {
            return XCTFail("expected a partial host-projection split plan for refresh")
        }
        XCTAssertEqual(plan.pureFragments.count, 1, "the pure middle lifts as one fragment")
        let frag = plan.pureFragments[0]
        XCTAssertEqual(frag.inputs.map { $0.name }, ["counter"], "the projected reactive read is the fragment input")
        XCTAssertEqual(frag.inputs.first?.type, "Int")
        XCTAssertEqual(frag.outputs.map { $0.name }, ["bumped"], "the live-out crossing to the native write")
        XCTAssertTrue(CodeEmitter().isABIEligible(frag), "the lifted fragment must be ABI-executable")
        let body = frag.bodyStatements.joined(separator: "\n")
        XCTAssertFalse(body.contains("self"), "the lifted fragment must be self-free. Got: \(body)")
        // Shell: projects the read, calls the fragment, THEN does the native write —
        // in that exact order (never reordered).
        let shell = plan.nativeStatementsSummary.joined(separator: "\n")
        XCTAssertTrue(shell.contains("let counter = self.counter"),
                      "the shell projects the reactive read. Got: \(shell)")
        XCTAssertTrue(shell.contains("self.cache = bumped"),
                      "the native write stays verbatim in the shell. Got: \(shell)")
    }

    /// A method that reads a reactive scalar, derives a value, writes a non-reactive
    /// prop, AND returns a value — the pure run lifts and threads its output to BOTH
    /// the native write and the returned value.
    func testReadDeriveWriteAndReturnRealizes() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var base: Int = 0
            var last: Int = 0
            func step(_ delta: Int) -> Int {
                let next = base + delta
                self.last = next
                return next
            }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "step")?.classification, .mixed,
                       "a method mixing a param + a reactive read + a native write → host-projected partial (mixed)")
        guard let plan = plan(src, "step") else {
            return XCTFail("expected a partial split plan for step")
        }
        XCTAssertGreaterThanOrEqual(plan.pureFragments.count, 1)
        let frag = plan.pureFragments[0]
        let inputs = Set(frag.inputs.map { $0.name })
        XCTAssertTrue(inputs.isSuperset(of: ["base", "delta"]),
                      "the fragment threads the projected read AND the method param. Got: \(inputs)")
        XCTAssertTrue(frag.outputs.map { $0.name }.contains("next"))
        XCTAssertTrue(CodeEmitter().isABIEligible(frag))
        let shell = plan.nativeStatementsSummary.joined(separator: "\n")
        XCTAssertTrue(shell.contains("self.last = next"), "the native write stays in the shell")
        XCTAssertTrue(shell.contains("return next"), "the return is preserved")
    }

    /// A pure closure transform over a projected scalar-array reactive read, written
    /// to a non-reactive prop, lifts (the closure shorthand is bound, not a capture).
    func testClosureTransformWriteRealizes() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var scores: [Int] = []
            var doubledCache: [Int] = []
            func recompute() {
                let doubled: [Int] = scores.map { $0 * 2 }
                self.doubledCache = doubled
            }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "recompute")?.classification, .mixed,
                       "a closure transform over a projected array, written to a non-reactive prop → partial (mixed)")
        guard let plan = plan(src, "recompute") else {
            return XCTFail("expected a partial split plan for recompute")
        }
        XCTAssertEqual(plan.pureFragments.count, 1)
        let frag = plan.pureFragments[0]
        XCTAssertEqual(frag.inputs.map { $0.name }, ["scores"])
        XCTAssertEqual(frag.inputs.first?.type, "[Int]")
        let body = frag.bodyStatements.joined(separator: "\n")
        XCTAssertFalse(body.contains("self"))
        XCTAssertTrue(body.contains("scores.map"))
        XCTAssertTrue(CodeEmitter().isABIEligible(frag))
    }

    /// The emitted WASM source is well-formed: the projected read feeds the fragment
    /// and the body is self-free; the native write is absent from WASM.
    func testEmittedPartialFragmentIsSelfFree() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var width: Double = 0
            var area: Double = 0
            func recompute() {
                let a = width * width
                self.area = a
            }
        }
        """
        guard let plan = plan(src, "recompute") else { return XCTFail("no plan") }
        let files = CodeEmitter().emit(plan)
        XCTAssertFalse(files.wasmSource.contains("self.width"),
                       "the WASM fragment must not read self.width (uses the parameter)")
        XCTAssertFalse(files.wasmSource.contains("self.area"),
                       "the native write must NEVER appear in WASM")
        XCTAssertTrue(files.wasmSource.contains("_args.width") || files.wasmSource.contains("width: Double"),
                      "the fragment takes the projected scalar")
    }

    // MARK: - Literal-initializer type inference (@Published without annotation)

    /// A `@Published` prop declared WITHOUT a type annotation (`@Published var
    /// isEnabled = true`) is still host-projectable: its type is inferred from the
    /// literal initializer. Real view models lean on inference heavily, so this
    /// widens the candidate set. Strictly additive (native→mixed only).
    func testInferredLiteralReactiveTypeRealizes() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var isEnabled = true
            @Published var searchText = ""
            @Published var count = 0
            @Published var ratio = 0.5
            var enabledLabel: String { isEnabled ? "on" : "off" }   // Bool
            var greeting: String { "Hi " + searchText }              // String
            var doubled: Int { count * 2 }                           // Int
            var scaled: Double { ratio * 100.0 }                     // Double
        }
        """
        let r = classify(src)
        for m in ["enabledLabel", "greeting", "doubled", "scaled"] {
            XCTAssertEqual(result(r, m)?.classification, .mixed,
                           "\(m) reads an inferred-type reactive prop → host-projected (mixed)")
        }
        // The record carries the inferred types.
        let reads = Dictionary(uniqueKeysWithValues:
            (record(src, "doubled")?.hostProjectableReads ?? []).map { ($0.name, $0.type) })
        XCTAssertEqual(reads["count"], "Int", "an integer-literal @Published infers Int")
    }

    /// An ambiguous (non-literal) initializer is NOT inferred — a `.member` /
    /// constructor initializer leaves the prop un-marshallable → reader stays native.
    /// Demote-safe: never mistype an enum/struct as a scalar.
    func testAmbiguousInitializerStaysNative() {
        let src = """
        import Foundation
        enum Speed { case normal, fast }
        final class VM: ObservableObject {
            @Published var speed = Speed.normal
            var isFast: Bool { speed == .fast }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "isFast")?.classification, .native,
                       "an enum-typed reactive prop (non-literal init) is not marshallable → native")
        XCTAssertNil(record(src, "isFast")?.hostProjectableReads.first)
    }

    // MARK: - Demote-safety (cardinal rule: never a wrong split)

    /// A method that WRITES a reactive property stays native — a reactive write can
    /// never be projected back across the ABI (the value would silently not update).
    func testReactiveWriteStaysNative() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var counter: Int = 0
            @Published var total: Int = 0
            func recompute() {
                let next = counter + 1
                self.total = next
            }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "recompute")?.classification, .native,
                       "a method that writes reactive state must stay native")
        XCTAssertNil(record(src, "recompute")?.hostProjectableReads.first,
                     "a reactive-writing method must NOT be host-projectable")
        XCTAssertEqual(record(src, "recompute")?.hostProjectablePartial, false)
    }

    /// A method whose pure run touches a NATIVE API stays native (the reactive read
    /// is not the sole native reason).
    func testNativeAPITouchStaysNative() {
        let src = """
        import Foundation
        import CoreLocation
        final class VM: ObservableObject {
            @Published var radius: Double = 0
            var cache: Double = 0
            func recompute() {
                let loc = CLLocation(latitude: 0, longitude: radius)
                self.cache = loc.coordinate.longitude
            }
        }
        """
        let r = classify(src)
        XCTAssertNotEqual(result(r, "recompute")?.classification, .wasmEligible)
        XCTAssertNil(record(src, "recompute")?.hostProjectableReads.first,
                     "a method that touches a native API must NOT be host-projectable")
        // Even if it somehow planned, no fragment may contain the native construction.
        if let plan = plan(src, "recompute") {
            for frag in plan.pureFragments {
                XCTAssertFalse(frag.bodyStatements.joined().contains("CLLocation"),
                               "a realized fragment must never construct CLLocation")
            }
        }
    }

    /// A method reading a NATIVE-typed reactive prop stays native (the value is not
    /// marshallable — the `user: User?` safety boundary).
    func testNativeTypedReactiveReadStaysNative() {
        let src = """
        import Foundation
        import FirebaseAuth
        final class VM: ObservableObject {
            @Published var user: User?
            var name: String = ""
            func sync() {
                let n = user?.displayName ?? ""
                self.name = n
            }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "sync")?.classification, .native,
                       "reading a native-typed (User?) reactive prop must stay native")
        XCTAssertNil(record(src, "sync")?.hostProjectableReads.first)
    }

    /// A method whose ONLY pure statement produces no live-out (a dead computation)
    /// produces NO fragment → stays native in the realized pass (nothing to ship).
    func testNoLiveOutPureRunStaysNativeRealized() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var counter: Int = 0
            var label: String = ""
            func touch() {
                self.label = "x"
                _ = counter + 1
            }
        }
        """
        // Classifier may mark it host-projectable, but the splitter is ground truth:
        // the only pure work has no live-out → no fragment → nil plan (native realized).
        let plan = plan(src, "touch")
        if let plan {
            XCTAssertTrue(plan.pureFragments.isEmpty,
                          "a dead pure computation must not produce a shippable fragment")
        }
        // (nil plan is the expected outcome; an empty-fragment plan would also be sound.)
    }

    /// A method whose pure work calls a bare lowercase helper (an implicit-self
    /// method / free function absent from the WASM fragment) keeps that run native —
    /// the fragment can't reference the helper. Demote-safe: stays native.
    func testHelperCallInPureRunStaysNative() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var counter: Int = 0
            var cache: Int = 0
            func recompute() {
                let v = transform(counter)
                self.cache = v
            }
            func transform(_ x: Int) -> Int { x * 3 }
        }
        """
        // `transform` is an instance method → not in the fragment; the splitter must
        // keep that statement native (it would reference an undeclared helper).
        if let plan = plan(src, "recompute", nativeCallees: ["transform"]) {
            for frag in plan.pureFragments {
                XCTAssertFalse(frag.bodyStatements.joined().contains("transform("),
                               "a fragment must never call the absent helper")
            }
        }
    }

    /// A pure run whose live-out local's type can't be inferred (an un-annotated
    /// `.map` over a projected array) keeps that run native — the fragment would
    /// have a generic (`_`) output that isn't ABI-eligible. Demote-safe: stays native
    /// rather than emit an un-typeable fragment. (Annotating the local lifts it; see
    /// `testClosureTransformWriteRealizes`.)
    func testUntypeableLiveOutStaysNative() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var scores: [Int] = []
            var cache: [Int] = []
            func recompute() {
                let doubled = scores.map { $0 * 2 }
                self.cache = doubled
            }
        }
        """
        if let plan = plan(src, "recompute") {
            for frag in plan.pureFragments {
                XCTAssertTrue(frag.outputs.allSatisfy { $0.type != "_" },
                              "a realized fragment must never have an un-typed (`_`) output")
            }
        }
        // nil plan (native realized) is also a sound outcome here.
    }

    /// PROJECTION-FRESHNESS: a method that runs a native statement (which might
    /// mutate the reactive prop) BEFORE consuming the reactive read must stay native.
    /// Hoisting the read to the top of the shell would feed the fragment a STALE
    /// value. The splitter must refuse the split (the read is used after the first
    /// native statement). Demote-safe: native, never a wrong (stale) split.
    func testReactiveReadAfterNativeStatementStaysNative() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var counter: Int = 0
            var cache: Int = 0
            var log: Int = 0
            func update() {
                self.log = 1                  // native statement (could affect counter)
                let derived = counter * 2     // reactive read AFTER the native write
                self.cache = derived
            }
        }
        """
        // The read of `counter` happens after a native statement, so projecting it at
        // the top of the shell would be stale → the splitter must NOT lift it.
        if let plan = plan(src, "update") {
            for frag in plan.pureFragments {
                XCTAssertFalse(frag.inputs.map { $0.name }.contains("counter"),
                               "must not host-project a reactive read consumed after a native statement (stale-value hazard)")
            }
        }
        // nil plan (native realized) is the expected, sound outcome.
    }

    /// A pure helper on a non-reactive type is unaffected — nothing spuriously marked
    /// partial-projectable.
    func testNonReactiveTypeUnaffected() {
        let src = """
        struct Calc {
            var cache: Int = 0
            mutating func update(_ n: Int) { cache = n * 2 }
        }
        """
        XCTAssertEqual(record(src, "update(_:)")?.hostProjectablePartial, false,
                       "no reactive props → nothing partial-projectable")
    }
}
