// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftParser
@testable import PartitioningEngine
@testable import CodeGenerator

/// Tests for the "pure-logic-over-reactive-reads" host-projection lift (general
/// partitioning-engine path — NOT the SwiftUI view-body path).
///
/// A member that would be forced native ONLY because it READS reactive/stored
/// properties — writing none, touching no other native interop, returning a
/// value-marshallable type, and reading only value-marshallable reactive props —
/// is HOST-PROJECTED: the native shell reads `self.<prop>` and marshals it into a
/// lifted WASM fragment that runs the pure logic over the projected value (it
/// never touches reactive state). Such a member classifies `mixed` and the
/// FunctionSplitter realizes it.
///
/// Two themes, mirroring the project's safety contract:
///   1. COVERAGE — a pure read of a scalar / String / Bool / scalar-array reactive
///      prop lifts to `mixed` and realizes to a compilable, ABI-executable fragment.
///   2. DEMOTE-SAFETY (cardinal rule) — a member that WRITES reactive state, reads
///      a NATIVE-typed reactive prop, touches any other native API, or returns an
///      unmarshallable type STAYS NATIVE. When in doubt → native.
final class HostProjectedReactiveReadTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/hostproject.swift")

    private func classify(_ source: String) -> [String: ClassificationResult] {
        let records = SwiftParserEngine().parse(source: source, file: file)
        let g = CallGraphBuilder().build(from: records)
        return Classifier().classifyAll(g)
    }

    /// Result for a member matched against the FINAL path component (a trailing
    /// `(...)` signature is ignored), or the last TWO for a `Type.member` query.
    private func result(_ results: [String: ClassificationResult], _ query: String) -> ClassificationResult? {
        let wantQualified = query.contains(".")
        return results.first { key, _ in
            let comps = key.split(separator: ".").map(String.init)
            guard let last = comps.last else { return false }
            let memberName = last.split(separator: "(").first.map(String.init) ?? last
            if wantQualified {
                guard comps.count >= 2 else { return false }
                return "\(comps[comps.count - 2]).\(memberName)" == query
            }
            return memberName == query
        }?.value
    }

    private func record(_ source: String, _ idSuffix: String) -> FunctionRecord? {
        SwiftParserEngine().parse(source: source, file: file)
            .first { $0.id.hasSuffix("." + idSuffix) || $0.id.contains("." + idSuffix + "(") }
    }

    /// Plan a member through the FunctionSplitter (the realization ground truth).
    private func plan(_ source: String, _ idSuffix: String,
                      nativeCallees: Set<String> = []) -> SplitPlan? {
        guard let rec = record(source, idSuffix) else { return nil }
        let tree = Parser.parse(source: source)
        let index = DeclarationIndex(tree: tree)
        var outcome: FunctionSplitter.Outcome = .noBody
        return FunctionSplitter(nativeCalleeNames: nativeCallees)
            .plan(for: rec, index: index, inferredTypes: [:], outcome: &outcome)
    }

    // MARK: - Coverage (positive lifts → mixed)

    /// Scalar / String / Bool reads on an @Observable view-model → host-projected.
    func testScalarStringBoolReadsLiftToMixed() {
        let src = """
        import Foundation
        @Observable final class VM {
            @Published var counter: Int = 0
            @Published var name: String = ""
            @Published var active: Bool = false
            var doubled: Int { counter * 2 }
            var greeting: String { "Hi " + name }
            var status: Bool { active && counter > 0 }
            func describe() -> String { active ? name : "off" }
        }
        """
        let r = classify(src)
        for m in ["doubled", "greeting", "status", "describe"] {
            let c = result(r, m)?.classification
            XCTAssertNotEqual(c, .wasmEligible, "\(m) reads reactive state → never wasmEligible")
            XCTAssertEqual(c, .mixed, "\(m) is a pure read of value-typed reactive state → host-projected (mixed)")
        }
    }

    /// A scalar-array (`[Int]`) reactive read → host-projected (subset (b)).
    func testScalarArrayReadLiftsToMixed() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var scores: [Int] = []
            var total: Int { scores.reduce(0, +) }
            var topThree: [Int] { scores.sorted().suffix(3).map { $0 } }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "total")?.classification, .mixed,
                       "reading [Int] @Published and summing → host-projected (mixed)")
        XCTAssertEqual(result(r, "topThree")?.classification, .mixed,
                       "reading [Int] @Published and returning [Int] → host-projected (mixed)")
    }

    /// The record carries exactly the reactive reads it projects, with types.
    func testRecordCarriesProjectedReadsWithTypes() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var a: Int = 0
            @Published var b: String = ""
            var combined: String { "\\(a)-" + b }
        }
        """
        let rec = record(src, "combined")
        XCTAssertNotNil(rec)
        let reads = Dictionary(uniqueKeysWithValues: (rec?.hostProjectableReads ?? []).map { ($0.name, $0.type) })
        XCTAssertEqual(reads["a"], "Int")
        XCTAssertEqual(reads["b"], "String")
        XCTAssertFalse(rec!.forcesNative, "a host-projectable member is no longer forced native")
    }

    // MARK: - Realization (the FunctionSplitter ground truth)

    /// A host-projected member realizes to a single fragment whose input is the
    /// projected reactive prop and whose body is the rewritten (self-free) logic.
    func testRealizesToProjectedFragment() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var handle: String = ""
            var atHandle: String { "@" + handle }
        }
        """
        guard let plan = plan(src, "atHandle") else {
            return XCTFail("expected a host-projection split plan for atHandle")
        }
        XCTAssertEqual(plan.pureFragments.count, 1)
        let frag = plan.pureFragments[0]
        // Input = the projected reactive read, with its concrete type.
        XCTAssertEqual(frag.inputs.map { $0.name }, ["handle"])
        XCTAssertEqual(frag.inputs.first?.type, "String")
        // Output is the returned value, concretely typed (→ ABI-executable).
        XCTAssertEqual(frag.outputs.first?.type, "String")
        XCTAssertTrue(CodeEmitter().isABIEligible(frag), "the projected fragment must be ABI-executable")
        // The fragment body refers to the PARAMETER, never `self`.
        let body = frag.bodyStatements.joined(separator: "\n")
        XCTAssertFalse(body.contains("self"), "the lifted fragment must be self-free. Got: \(body)")
        XCTAssertTrue(body.contains("handle"), "the lifted fragment uses the projected value")
        // The shell projects `self.handle` and returns the fragment's result.
        let shell = plan.nativeStatementsSummary.joined(separator: "\n")
        XCTAssertTrue(shell.contains("let handle = self.handle"),
                      "the native shell must project the reactive read. Got: \(shell)")
    }

    /// The emitted WASM source for a host-projected member is well-formed (the
    /// `self.<prop>` read was rewritten to the parameter; the ABI envelope matches).
    func testEmittedWasmRewritesSelfToParameter() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var count: Int = 0
            var label: String { "n=\\(count)" }
        }
        """
        guard let plan = plan(src, "label") else { return XCTFail("no plan") }
        let files = CodeEmitter().emit(plan)
        XCTAssertTrue(files.wasmSource.contains("_args.count"),
                      "the ABI shim feeds the projected `count` to the fragment")
        // The pure helper signature takes the projected value as a parameter, and
        // the body must not reference `self`.
        XCTAssertTrue(files.wasmSource.contains("count: Int") || files.wasmSource.contains("_ count: Int"),
                      "the fragment takes the projected reactive read as a parameter")
        let helperRange = files.wasmSource
        XCTAssertFalse(helperRange.contains("self.count"),
                       "the WASM fragment must not read self.count (it must use the parameter)")
    }

    /// A METHOD that mixes its own parameters with reactive reads lifts: the
    /// fragment threads BOTH the projected reads and the params (passed by the shell).
    func testMethodWithParamsAndReactiveReadsRealizes() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var prefix: String = ""
            func decorate(_ suffix: String, times: Int) -> String {
                return prefix + suffix + String(times)
            }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "decorate")?.classification, .mixed,
                       "a method mixing params + a value-typed reactive read → host-projected (mixed)")
        guard let plan = plan(src, "decorate") else {
            return XCTFail("expected a host-projection split plan for decorate")
        }
        let frag = plan.pureFragments.first
        let inputNames = Set(frag?.inputs.map { $0.name } ?? [])
        XCTAssertTrue(inputNames.isSuperset(of: ["prefix", "suffix", "times"]),
                      "the fragment must thread the projected read AND the method params. Got: \(inputNames)")
        let body = (frag?.bodyStatements ?? []).joined(separator: "\n")
        XCTAssertFalse(body.contains("self"), "the lifted fragment must be self-free")
        XCTAssertTrue(CodeEmitter().isABIEligible(frag!), "the fragment must be ABI-executable")
    }

    // MARK: - Closure-captured reactive reads (subset (a): the #1 lever)

    /// A pure higher-order transform over a SCALAR-ARRAY reactive read — a `.map`/
    /// `.filter`/`.reduce` whose closure reads only `$0`/its own param — realizes:
    /// the closure shorthand (`$0`) is bound by the closure, NOT a free capture, so
    /// the WHOLE transform lifts with the projected array as the fragment input.
    func testClosureMapOverScalarArrayRealizes() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var scores: [Int] = []
            var doubled: [Int] { scores.map { $0 * 2 } }
            var labels: [String] { scores.map { String($0) } }
            var positives: [Int] { scores.filter { $0 > 0 } }
            var total: Int { scores.reduce(0) { acc, x in acc + x } }
        }
        """
        let r = classify(src)
        for m in ["doubled", "labels", "positives", "total"] {
            XCTAssertEqual(result(r, m)?.classification, .mixed,
                           "\(m) is a pure closure transform over a scalar-array reactive read → host-projected (mixed)")
        }
        // Realization ground truth: the closure transform splits into a fragment
        // whose input is the projected array and whose body is self-free.
        guard let plan = plan(src, "doubled") else {
            return XCTFail("expected a host-projection split plan for doubled")
        }
        XCTAssertEqual(plan.pureFragments.count, 1)
        let frag = plan.pureFragments[0]
        XCTAssertEqual(frag.inputs.map { $0.name }, ["scores"])
        XCTAssertEqual(frag.inputs.first?.type, "[Int]")
        let body = frag.bodyStatements.joined(separator: "\n")
        XCTAssertFalse(body.contains("self"), "the lifted closure fragment must be self-free. Got: \(body)")
        XCTAssertTrue(body.contains("scores.map"), "the fragment runs the projected transform. Got: \(body)")
        XCTAssertTrue(CodeEmitter().isABIEligible(frag), "the closure-transform fragment must be ABI-executable")
    }

    /// A method whose body mixes its params, a projected reactive read AND a pure
    /// closure transform realizes (the param + the projected read are both fragment
    /// inputs; the closure shorthand is bound).
    func testMethodWithClosureAndReactiveReadRealizes() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var scores: [Int] = []
            func aboveThreshold(_ threshold: Int) -> [Int] {
                return scores.filter { $0 > threshold }
            }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "aboveThreshold")?.classification, .mixed,
                       "a method mixing a param + a closure over a reactive read → host-projected (mixed)")
        guard let plan = plan(src, "aboveThreshold") else {
            return XCTFail("expected a host-projection split plan for aboveThreshold")
        }
        let frag = plan.pureFragments.first
        let inputs = Set(frag?.inputs.map { $0.name } ?? [])
        XCTAssertTrue(inputs.isSuperset(of: ["scores", "threshold"]),
                      "fragment threads the projected read AND the method param. Got: \(inputs)")
        let body = (frag?.bodyStatements ?? []).joined(separator: "\n")
        XCTAssertFalse(body.contains("self"), "the lifted fragment must be self-free")
        XCTAssertTrue(CodeEmitter().isABIEligible(frag!))
    }

    /// The emitted WASM source for a closure transform over a projected read is
    /// well-formed: the array parameter feeds the fragment and the body is self-free.
    func testEmittedClosureFragmentIsSelfFree() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var values: [Double] = []
            var halved: [Double] { values.map { $0 / 2.0 } }
        }
        """
        guard let plan = plan(src, "halved") else { return XCTFail("no plan") }
        let files = CodeEmitter().emit(plan)
        XCTAssertFalse(files.wasmSource.contains("self.values"),
                       "the WASM fragment must not read self.values (it must use the parameter)")
        XCTAssertTrue(files.wasmSource.contains("values.map") || files.wasmSource.contains("values: [Double]"),
                      "the fragment takes the projected array and runs the transform")
    }

    // MARK: - Closure demote-safety (a free capture / native touch keeps native)

    /// A closure whose body reads a NON-projected captured local (`limit`, an
    /// instance member that is NOT a projected reactive read) keeps the member
    /// native — the fragment would reference an undeclared value. Here the
    /// projected read is a scalar but the closure also reads `self.cap`, a NATIVE-
    /// typed reactive prop that disqualifies host-projection entirely.
    func testClosureReadingNativeTypedReactiveStaysNative() {
        let src = """
        import Foundation
        import FirebaseAuth
        final class VM: ObservableObject {
            @Published var scores: [Int] = []
            @Published var owner: User?
            // Reads scores (projectable) AND owner (native User? → disqualifies).
            var filtered: [Int] { scores.filter { _ in owner != nil } }
        }
        """
        let r = classify(src)
        XCTAssertNotEqual(result(r, "filtered")?.classification, .wasmEligible,
                          "a closure touching a native-typed reactive read must never be wasmEligible")
        XCTAssertNil(record(src, "filtered")?.hostProjectableReads.first,
                     "a member whose closure reads a native-typed reactive prop must NOT be host-projectable")
    }

    /// A closure that calls a NATIVE API inside its body keeps the member native
    /// even though the projected read is value-marshallable (the fragment can't run
    /// the native call). Demote-safe: stays native, never a broken split.
    func testClosureCallingNativeAPIStaysNative() {
        let src = """
        import Foundation
        import CoreLocation
        final class VM: ObservableObject {
            @Published var coords: [Double] = []
            // Pure projected read, but the closure constructs a native CLLocation.
            func distances() -> [Double] {
                return coords.map { CLLocation(latitude: $0, longitude: 0).coordinate.latitude }
            }
        }
        """
        let r = classify(src)
        XCTAssertNotEqual(result(r, "distances")?.classification, .wasmEligible,
                          "a closure touching a native API must never be wasmEligible")
        // Even if the classifier marks it host-projectable, the splitter (ground
        // truth) must refuse to realize a split that runs a native call in WASM.
        if let plan = plan(src, "distances") {
            for frag in plan.pureFragments {
                XCTAssertFalse(frag.bodyStatements.joined().contains("CLLocation"),
                               "a realized fragment must never contain a native CLLocation construction")
            }
        }
    }

    /// A closure body that MUTATES a captured local or writes through `self` keeps
    /// the member native (a mutation is a side effect, not a value projection).
    func testClosureWithSelfWriteStaysNative() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var scores: [Int] = []
            @Published var sum: Int = 0
            // forEach with a self write → not a pure value transform.
            func recompute() -> Int {
                scores.forEach { sum += $0 }
                return sum
            }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "recompute")?.classification, .native,
                       "a closure that writes reactive state → must stay native")
    }

    // MARK: - Demote-safety (cardinal rule: never lift an unsafe member)

    /// A member that WRITES reactive state stays native (a write can't be projected).
    func testReactiveWriteStaysNative() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var count: Int = 0
            @Published var flag: Bool = false
            @Published var items: [Int] = []
            func bump() -> Int { count += 1; return count }      // compound assign
            func set() -> Int { count = 9; return count }         // assign
            func toggle() -> Bool { flag.toggle(); return flag }  // mutating method
            func push() -> Int { items.append(1); return items.count } // mutating method on array
        }
        """
        let r = classify(src)
        for m in ["bump", "set", "toggle", "push"] {
            XCTAssertEqual(result(r, m)?.classification, .native,
                           "\(m) MUTATES reactive state → must stay native")
            XCTAssertNil(record(src, m)?.hostProjectableReads.isEmpty == false ? "x" : nil,
                         "\(m) must NOT be recorded host-projectable")
        }
    }

    /// A member reading a NATIVE-typed reactive prop stays native — the value is
    /// not marshallable (the `user: User?` / `[SomeModel]` safety boundary).
    func testNativeTypedReactiveReadStaysNative() {
        let src = """
        import Foundation
        import FirebaseAuth
        final class Auth: ObservableObject {
            @Published var user: User?
            @Published var date: Date = Date()
            var isSignedIn: Bool { user != nil }     // reads native User → native
            var stamp: Double { date.timeIntervalSince1970 } // Date is wasm-safe but not in the scalar set → native
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "isSignedIn")?.classification, .native,
                       "reading a native-typed (User?) reactive prop must stay native")
        XCTAssertNil(record(src, "isSignedIn")?.hostProjectableReads.first,
                     "a native-typed reactive read must not be host-projectable")
        // Date is deliberately NOT in the projectable scalar set (subset deferred),
        // so a Date read stays native too — conservative, never wrong.
        XCTAssertEqual(result(r, "stamp")?.classification, .native,
                       "a Date reactive read is not in the projectable set → native (conservative)")
    }

    /// A member that reads a reactive prop AND touches a genuine native API stays
    /// native (host-projection requires the reactive read to be the SOLE reason).
    func testReactiveReadPlusNativeAPIStaysNative() {
        let src = """
        import Foundation
        import CoreLocation
        final class VM: ObservableObject {
            @Published var radius: Double = 0
            // Reads a scalar reactive prop BUT also constructs a native CLLocation.
            func near() -> Double {
                let loc = CLLocation(latitude: 0, longitude: radius)
                return loc.coordinate.longitude
            }
        }
        """
        let r = classify(src)
        XCTAssertNotEqual(result(r, "near")?.classification, .wasmEligible,
                          "a native API touch must never be wasmEligible")
        XCTAssertNil(record(src, "near")?.hostProjectableReads.first,
                     "a member that also touches a native API must NOT be host-projectable")
    }

    /// A member returning an UNMARSHALLABLE type stays native even if its reads are
    /// value-typed (the return value can't cross the JSON ABI in this increment).
    func testUnmarshallableReturnStaysNative() {
        let src = """
        import Foundation
        struct Pair { let a: Int; let b: Int }
        final class VM: ObservableObject {
            @Published var x: Int = 0
            var pair: Pair { Pair(a: x, b: x) }            // custom struct return → not (yet) marshallable
            var tuple: (Int, Int) { (x, x) }               // tuple return → not marshallable
            var dict: [String: Int] { ["x": x] }           // dictionary return → not marshallable
        }
        """
        let r = classify(src)
        for m in ["pair", "tuple", "dict"] {
            XCTAssertNotEqual(result(r, m)?.classification, .wasmEligible,
                              "\(m) reads reactive state → never wasmEligible")
            XCTAssertNil(record(src, m)?.hostProjectableReads.first,
                         "\(m) returns an unmarshallable type → must NOT be host-projectable (stays native)")
        }
    }

    /// A SETTER (and `init`) is never host-projected — only getter-shaped value
    /// members are. A computed property's `set` reads `newValue` + writes state.
    func testSetterAndInitNeverProjected() {
        let src = """
        import Foundation
        final class VM: ObservableObject {
            @Published var raw: Int = 0
            var wrapped: Int {
                get { raw + 1 }
                set { raw = newValue - 1 }
            }
            init(_ v: Int) { raw = v }
        }
        """
        let r = classify(src)
        // The getter IS host-projected (pure read of a scalar reactive prop).
        XCTAssertEqual(result(r, "wrapped.get")?.classification, .mixed,
                       "the getter is a pure scalar read → host-projected (mixed)")
        // The setter writes reactive state → native.
        XCTAssertEqual(result(r, "wrapped.set")?.classification, .native,
                       "a setter writes reactive state → native")
        XCTAssertNil(record(src, "init(_:)")?.hostProjectableReads.first,
                     "an initializer is never host-projected")
    }

    /// A type with NO reactive props is unaffected — a pure helper stays eligible,
    /// nothing is spuriously marked host-projectable.
    func testNonReactiveTypeUnaffected() {
        let src = """
        struct Calc {
            let base: Int
            func plus(_ n: Int) -> Int { base + n }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "plus")?.classification, .wasmEligible,
                       "a pure helper on a non-reactive type stays wasmEligible (unchanged)")
        XCTAssertNil(record(src, "plus(_:)")?.hostProjectableReads.first,
                     "no reactive props → nothing host-projectable")
    }

    // MARK: - @Observable-macro widening (plain stored props, NO @Published wrapper)

    /// LEVER 2 WIDENING: under the Observation `@Observable` macro, a PLAIN STORED
    /// `var` (no `@Published`/`@State` wrapper) is reactive — the macro synthesizes
    /// the observation accessors. A pure read of a value-marshallable such prop
    /// host-projects to `mixed` (the modern view-model pattern); previously these
    /// plain props were invisible to the reactive scan and a reader was either
    /// wasmEligible-but-unshippable (instance method on a class) or, worse, a WRITER
    /// was wrongly wasmEligible. Both are fixed here.
    func testObservableMacroPlainStoredPropsHostProject() {
        let src = """
        import Observation
        @Observable final class VM {
            var completed: Int = 0
            var total: Int = 10
            var label: String = "x"
            var isReady: Bool = false
            func progressLabel() -> String { "\\(completed)/\\(total)" }
            var ratio: Double { total == 0 ? 0 : Double(completed) / Double(total) }
            func summary() -> String { isReady ? label : "off" }
        }
        """
        let r = classify(src)
        for m in ["progressLabel", "ratio", "summary"] {
            let c = result(r, m)?.classification
            XCTAssertNotEqual(c, .wasmEligible, "\(m): an @Observable plain-stored read is never pure-eligible")
            XCTAssertEqual(c, .mixed, "\(m): pure read of @Observable scalar state → host-projected (mixed)")
        }
        // The projected reads are recorded with their types.
        let reads = Dictionary(uniqueKeysWithValues:
            (record(src, "progressLabel()")?.hostProjectableReads ?? []).map { ($0.name, $0.type) })
        XCTAssertEqual(reads["completed"], "Int")
        XCTAssertEqual(reads["total"], "Int")
    }

    /// DEMOTE-SAFETY: under `@Observable`, a method that WRITES a plain stored prop
    /// stays NATIVE (a reactive write can never be projected — this also FIXES the
    /// prior latent over-free where such a writer was wasmEligible). A read of a
    /// NATIVE-typed stored prop stays native (the native-typed boundary). An
    /// `@ObservationIgnored` prop is NOT observed → reads of it stay pure-eligible.
    func testObservableMacroDemoteSafety() {
        let src = """
        import Observation
        struct Item { let id: Int }
        @Observable final class VM {
            var query: String = ""
            var items: [Item] = []
            @ObservationIgnored var seed: Int = 0
            func clear() { query = "" }            // reactive WRITE → native
            func count() -> Int { items.count }    // native-typed read → native
            func seeded() -> Int { seed * 2 }      // @ObservationIgnored → pure-eligible
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "clear")?.classification, .native,
                       "a write to an @Observable stored prop stays native")
        XCTAssertEqual(result(r, "count")?.classification, .native,
                       "reading a NATIVE-typed @Observable prop stays native (boundary)")
        XCTAssertEqual(result(r, "seeded")?.classification, .wasmEligible,
                       "@ObservationIgnored is not observed → a read of it is pure-eligible")
        // The writer must NOT be host-projectable (no false positive).
        XCTAssertNil(record(src, "clear()")?.hostProjectableReads.first,
                     "a reactive writer is never recorded host-projectable")
    }

    /// SHADOWING SAFETY (a render/compute-correctness fix): a function PARAMETER (or
    /// local binding) that SHADOWS a reactive prop name is NOT a reactive read — the
    /// body's reference is the local, not `self.<prop>`. Host-projecting it would
    /// project the WRONG value (project `self.count` while the body uses the param
    /// `count`). The shadowed reader must stay pure-eligible; an EXPLICIT `self.<prop>`
    /// read in the same body still counts. Covers both `@Observable` and `@Published`.
    func testParameterShadowingNotTreatedAsReactiveRead() {
        let src = """
        import Observation
        @Observable final class VM {
            var count: Int = 5
            var tag: String = "t"
            func echo(count: Int) -> Int { count + 1 }       // param shadows → pure
            func bumped() -> Int { count + 1 }               // real self.count → mixed
            func mix(count: Int) -> Int { count + self.tag.count }  // param + self.tag read
            func local() -> Int { let count = 9; return count } // local shadows → pure
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "echo")?.classification, .wasmEligible,
                       "a param shadowing a reactive prop is the local → pure, never projected")
        XCTAssertEqual(result(r, "bumped")?.classification, .mixed,
                       "a genuine self.count read still host-projects")
        XCTAssertEqual(result(r, "local")?.classification, .wasmEligible,
                       "a local binding shadowing a reactive prop is the local → pure")
        // `mix` uses the param `count` (NOT reactive) AND reads `self.tag` (reactive).
        // It must project ONLY `tag`, never `count`.
        let mixReads = (record(src, "mix(count:)")?.hostProjectableReads ?? []).map { $0.name }
        XCTAssertFalse(mixReads.contains("count"), "the shadowed param `count` must NOT be projected")
        XCTAssertEqual(result(r, "mix")?.classification, .mixed,
                       "mix reads self.tag (reactive) → host-projected over tag only")
    }

    /// A plain (non-`@Observable`) class is UNAFFECTED — its plain stored props are
    /// NOT reactive, so a reader stays whatever it was (wasmEligible). The widening
    /// is gated strictly on the macro attribute.
    func testPlainClassWithoutObservableUnaffected() {
        let src = """
        final class Plain {
            var n: Int = 0
            func doubled() -> Int { n * 2 }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, "doubled")?.classification, .wasmEligible,
                       "a plain class (no @Observable) keeps its plain stored props non-reactive")
        XCTAssertNil(record(src, "doubled()")?.hostProjectableReads.first,
                     "no @Observable → no host-projection of plain stored props")
    }
}
