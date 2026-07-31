// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftParser
@testable import PartitioningEngine
@testable import CodeGenerator

/// research/subtree-extraction: tests for the aggressive maximal-pure-sub-tree
/// extractor. Two themes, mirroring the project's safety contract:
///   1. COVERAGE — a pure sub-expression inside an otherwise-native statement IS
///      extracted; a pure transform inside a closure passed to map/filter IS
///      extracted; the lift is MAXIMAL (whole pure arg, not its fragments).
///   2. SAFETY (zero false negatives) — a closure/expression capturing `self`,
///      reactive state, a native symbol, a native callee, `await`/`try`, or an
///      assignment is NEVER extracted. Untyped (`$0`) captures never qualify.
final class SubtreeExtractionTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/se.swift")

    /// Run the extractor on the record whose id contains `idSubstring`.
    private func extract(_ source: String, id idSubstring: String,
                         nativeCallees: Set<String> = [],
                         inferred: [String: String] = [:],
                         deep: Bool = true,
                         closureLocalRewrite: Bool = true) -> SubtreeExtractor.Result {
        let recs = SwiftParserEngine().parse(source: source, file: file)
        let tree = Parser.parse(source: source)
        guard let r = recs.first(where: { $0.id.contains(idSubstring) }) else {
            return SubtreeExtractor.Result(plan: nil, extractions: [])
        }
        let index = DeclarationIndex(tree: tree)
        let propIndex = TypePropertyIndex(tree: tree)
        return SubtreeExtractor(nativeCalleeNames: nativeCallees, deep: deep,
                                closureLocalRewrite: closureLocalRewrite)
            .extract(from: r, index: index, tree: tree, inferredTypes: inferred,
                     propertyIndex: propIndex)
    }

    private func allExprText(_ res: SubtreeExtractor.Result) -> [String] {
        res.extractions.map { $0.exprText }
    }

    // MARK: - Coverage

    /// A pure sub-expression inside a NATIVE statement is lifted (the headline
    /// case from the mandate): `view.text = formatPrice(total * (1 - rate))` lifts
    /// the pure arithmetic feeding the native assignment.
    func testPureSubExprInsideNativeStatementIsExtracted() {
        let source = """
        import UIKit
        class C {
            func render(_ total: Double, _ rate: Double, _ view: UILabel) {
                view.text = describe(total * (1 - rate))
            }
            func describe(_ d: Double) -> String { "\\(d)" }
        }
        """
        let res = extract(source, id: "render(")
        XCTAssertNotNil(res.plan, "expected an extraction plan")
        XCTAssertTrue(allExprText(res).contains { $0.contains("total * (1 - rate)") },
                      "pure arithmetic feeding a native assignment must be lifted. Got: \(allExprText(res))")
        // The lifted fragment must be ABI-executable (concrete Double type).
        let abi = res.plan!.pureFragments.filter { CodeEmitter().isABIEligible($0) }
        XCTAssertFalse(abi.isEmpty, "lifted arithmetic must be ABI-eligible")
    }

    /// A pure transform inside a closure passed to `map` is lifted even though the
    /// surrounding call is on a native-ish receiver. Uses a typed closure param so
    /// the body is concretely typed.
    func testPureClosureBodyTransformIsExtracted() {
        let source = """
        struct S {
            func scale(_ xs: [Int], _ factor: Int) -> [Int] {
                return xs.map { (n: Int) in n * factor + 1 }
            }
        }
        """
        let res = extract(source, id: "scale(")
        XCTAssertNotNil(res.plan)
        XCTAssertTrue(allExprText(res).contains { $0.contains("n * factor + 1") || $0.contains("factor + 1") },
                      "pure closure transform must be lifted. Got: \(allExprText(res))")
        XCTAssertTrue(res.extractions.contains { $0.insideClosure },
                      "the extraction must be flagged as inside-closure")
    }

    /// String interpolation built from typed params inside a native call is lifted.
    func testInterpolatedStringFeedingNativeCallIsExtracted() {
        let source = """
        import Foundation
        struct S {
            func write(_ name: String, _ count: Int, _ path: String) {
                FileManager.default.createFile(atPath: "\\(name)-\\(count).json", contents: nil)
            }
        }
        """
        let res = extract(source, id: "write(")
        XCTAssertNotNil(res.plan)
        XCTAssertTrue(allExprText(res).contains { $0.contains("\\(name)") },
                      "interpolated string must be lifted. Got: \(allExprText(res))")
    }

    /// The lift is MAXIMAL: the whole pure argument expression is one fragment,
    /// not several. `describe(a * b - c)` lifts the entire pure arg once.
    func testMaximalLiftPrefersWholePureArgument() {
        let source = """
        import UIKit
        class C {
            func go(_ a: Int, _ b: Int, _ c: Int, _ v: UILabel) {
                v.tag = a * b - c
            }
        }
        """
        let res = extract(source, id: "go(")
        XCTAssertNotNil(res.plan)
        // Exactly one fragment for the whole `a * b - c` (maximal), not one per op.
        XCTAssertEqual(res.extractions.count, 1, "expected a single maximal lift, got \(allExprText(res))")
        XCTAssertTrue(allExprText(res)[0].contains("a * b - c"))
    }

    // MARK: - Safety (zero false negatives)

    /// A closure that captures `self` is NEVER extracted (no `self` in WASM).
    func testClosureCapturingSelfNeverExtracts() {
        let source = """
        import Combine
        class VM {
            var multiplier = 2
            func bind(_ xs: [Int]) -> [Int] {
                return xs.map { (n: Int) in n * self.multiplier }
            }
        }
        """
        let res = extract(source, id: "bind(")
        XCTAssertFalse(allExprText(res).contains { $0.contains("self") },
                       "a sub-tree reading self must NEVER be lifted. Got: \(allExprText(res))")
    }

    /// A sub-expression calling a NATIVE callee is never lifted.
    func testNativeCalleeSubExprNeverExtracts() {
        let source = """
        struct S {
            func run(_ a: Int) -> Int {
                let x = nativeHelper(a) + 1
                return x
            }
        }
        """
        let res = extract(source, id: "run(", nativeCallees: ["nativeHelper"])
        XCTAssertFalse(allExprText(res).contains { $0.contains("nativeHelper") },
                       "a native callee must never enter a WASM fragment. Got: \(allExprText(res))")
    }

    /// A sub-expression touching a `mustStayNative` registry symbol is never lifted.
    func testMustStayNativeSymbolNeverExtracts() {
        let source = """
        import UIKit
        class C {
            func tint(_ v: UIView) {
                v.backgroundColor = UIColor.red
            }
        }
        """
        let res = extract(source, id: "tint(")
        XCTAssertFalse(allExprText(res).contains { $0.contains("UIColor") },
                       "UIColor (mustStayNative) must never be lifted. Got: \(allExprText(res))")
    }

    /// `await`/`try` effect-bearing sub-expressions are never lifted.
    func testAwaitAndTrySubExprNeverExtract() {
        let source = """
        struct S {
            func load(_ a: Int) async throws -> Int {
                let x = try await fetch(a) + 1
                return x
            }
            func fetch(_ a: Int) async throws -> Int { a }
        }
        """
        let res = extract(source, id: "load(", nativeCallees: ["fetch"])
        XCTAssertFalse(allExprText(res).contains { $0.contains("await") || $0.contains("fetch") },
                       "await/try sub-tree must never be lifted. Got: \(allExprText(res))")
    }

    /// An untyped `$0` shorthand closure capture is never lifted (no concrete type
    /// → not ABI-eligible → stays native; never references an untyped value).
    func testUntypedShorthandClosureParamNeverExtracts() {
        let source = """
        struct S {
            func f(_ xs: [Int]) -> [Int] {
                return xs.map { $0 * $0 + 1 }
            }
        }
        """
        let res = extract(source, id: "f(")
        // `$0` has no concrete type, so any candidate reading it is rejected.
        XCTAssertFalse(res.extractions.contains { $0.exprText.contains("$0") },
                       "a sub-tree over an untyped $0 must never be lifted. Got: \(allExprText(res))")
    }

    /// SOUNDNESS regression: a ternary whose CONDITION contains `==` but whose
    /// VALUE is a non-ABI type (`[T]`/enum case) must NOT be mistyped `Bool` and
    /// lifted. (Caught on MovieSwiftUI: `movieId == 0 ? .placeholder : []`.)
    func testTernaryWithComparisonConditionNotMistypedBool() {
        let source = """
        import SwiftUI
        struct Row: View {
            let movieId: Int
            var body: some View {
                Text(label(movieId == 0 ? .placeholder : []))
            }
            func label(_ xs: [Int]) -> String { "" }
        }
        """
        let res = extract(source, id: "body")
        XCTAssertFalse(allExprText(res).contains { $0.contains("? .placeholder") },
                       "a ternary yielding a non-ABI value must never be lifted as Bool. Got: \(allExprText(res))")
    }

    /// SOUNDNESS regression: arithmetic with an operand of UNKNOWN type
    /// (`.now() + 2.5`, Date arithmetic) must NOT be mistyped Double and lifted.
    /// (Caught on MovieSwiftUI; the lifted fragment did not even compile.)
    func testArithmeticWithUnknownOperandNotMistyped() {
        let source = """
        import Foundation
        struct S {
            func schedule(_ cb: (Date) -> Void) {
                cb(.now() + 2.5)
            }
        }
        """
        let res = extract(source, id: "schedule(")
        XCTAssertFalse(allExprText(res).contains { $0.contains(".now()") },
                       "arithmetic over an untypeable operand must never be lifted. Got: \(allExprText(res))")
    }

    /// A genuine scalar ternary (`flag ? 1 : 2`) still lifts (no over-rejection).
    func testGenuineScalarTernaryStillLifts() {
        let source = """
        import UIKit
        class C {
            func go(_ flag: Bool, _ v: UILabel) {
                v.tag = flag ? 100 : 200
            }
        }
        """
        let res = extract(source, id: "go(")
        XCTAssertTrue(allExprText(res).contains { $0.contains("flag ? 100 : 200") },
                      "a pure scalar ternary must still lift. Got: \(allExprText(res))")
    }

    /// COVERAGE (general-logic milk-more): a ternary whose ELSE arm is a bare `nil`
    /// literal and whose THEN arm is an ABI scalar is `T?` — and lifts. Before the
    /// fix it was mistyped `String`, emitting `return (flag ? "x" : nil)` into a
    /// `-> String` fragment that FAILED to compile and demoted (the real
    /// ScheduleService.runAnalysis `message: scrapeFailed ? "scrape_unavailable" : nil`
    /// bug). The lifted fragment now ships as a `-> String?` export.
    func testTernaryWithNilElseArmLiftsAsOptional() {
        let source = """
        struct Result { var message: String? }
        enum Builder {
            static func make(_ scrapeFailed: Bool) -> Result {
                Result(message: scrapeFailed ? "scrape_unavailable" : nil)
            }
        }
        """
        let res = extract(source, id: "make(")
        XCTAssertTrue(allExprText(res).contains { $0.contains(#"? "scrape_unavailable" : nil"#) },
                      "a `T? = flag ? x : nil` ternary must lift. Got: \(allExprText(res))")
        // The fragment's plan must type the output `String?` (so the emitted `-> String?`
        // fragment compiles and round-trips Optional through Codable).
        guard let plan = res.plan else { return XCTFail("no plan") }
        let opt = plan.pureFragments.flatMap { $0.outputs }.first { $0.type.hasSuffix("?") }
        XCTAssertEqual(opt?.type, "String?",
                       "nil-arm ternary output type must be Optional. Plan: \(plan.pureFragments.map { $0.outputs })")
    }

    /// SAFETY: a ternary whose OTHER arm is of UNKNOWN type (not a `nil` literal)
    /// must NOT be typed off the inferable arm — it would mis-type a differently
    /// typed arm that merely failed inference. Demote-safe: stays native.
    func testTernaryWithUnknownArmNeverLiftsByGuessingOtherArm() {
        let source = """
        import UIKit
        class C {
            func go(_ flag: Bool, _ v: UILabel) {
                v.attributedText = label(flag ? "x" : someUnknownNativeThing())
            }
            func label(_ s: Any) -> NSAttributedString { NSAttributedString(string: "") }
        }
        """
        let res = extract(source, id: "go(")
        XCTAssertFalse(allExprText(res).contains { $0.contains("someUnknownNativeThing") },
                       "a ternary with an untypeable non-nil arm must never lift. Got: \(allExprText(res))")
    }

    /// The whole pipeline: an extracted fragment from a NATIVE-classified function
    /// is emitted as an ABI-eligible WASM export by the existing CodeEmitter.
    func testExtractionFromNativeBodyEmitsABIExport() {
        let source = """
        import UIKit
        class C {
            func update(_ price: Double, _ taxRate: Double, _ label: UILabel) {
                label.text = format(price * (1 + taxRate))
            }
            func format(_ d: Double) -> String { "\\(d)" }
        }
        """
        let res = extract(source, id: "update(")
        guard let plan = res.plan else { return XCTFail("no plan") }
        let files = CodeEmitter().emit(plan)
        XCTAssertTrue(files.exportSymbols.contains { $0.hasPrefix("_se_update_") },
                      "extracted sub-tree must be a real WASM export. Exports: \(files.exportSymbols)")
        XCTAssertFalse(files.wasmSource.contains("UILabel"),
                       "native type must never enter the WASM module")
        XCTAssertFalse(files.wasmSource.contains("label.text"),
                       "the native assignment must stay in the shell, not the WASM module")
    }

    // MARK: - BUG R2-#3 / R2-#16: conditionally-evaluated sub-tree must not hoist

    /// Inspect the plan's shell steps: returns the `.nativeStatement` texts and the
    /// list of unconditional pre-bind fragment names (a leading `.fragmentCall`).
    private func shellInfo(_ plan: SplitPlan) -> (natives: [String], preBinds: [String]) {
        var natives: [String] = []
        var preBinds: [String] = []
        for step in plan.shellSteps {
            switch step {
            case let .nativeStatement(t): natives.append(t)
            case let .fragmentCall(f): preBinds.append(f.name)
            case let .subExprCall(f, t): preBinds.append(f.name); natives.append(t)
            case let .guardConditionCall(f, t): preBinds.append(f.name); natives.append(t)
            }
        }
        return (natives, preBinds)
    }

    /// SOUNDNESS (BUG R2-#3/#16): a pure sub-tree natively evaluated only on the RHS
    /// of a short-circuiting `&&` (the whole `&&` reads `self`, so it is NOT liftable
    /// whole) must NEVER be hoisted to an UNCONDITIONAL top-level bind — that would
    /// run a `amount / quantity` ALWAYS, trapping (div-by-zero) where the native code
    /// short-circuited past it on `quantity == 0`. It may only ship via the INLINE
    /// `Patch.call(...)` substitution (position-preserving, stays conditional).
    func testConditionalAndRhsSubTreeNeverHoistedToTopLevelBind() {
        let source = """
        class C {
            var isEnabled = false
            func render(_ amount: Int, _ quantity: Int) {
                flag = self.isEnabled && (amount / quantity) > 0
            }
        }
        """
        let res = extract(source, id: "render(")
        guard let plan = res.plan else {
            // No plan at all is also safe (nothing hoisted). Pass.
            return
        }
        let info = shellInfo(plan)
        // The division must NOT be bound unconditionally before the statement.
        let preBindBodies = plan.pureFragments
            .filter { info.preBinds.contains($0.name) }
            .flatMap { $0.bodyStatements }
            .joined(separator: "\n")
        XCTAssertFalse(preBindBodies.contains("amount / quantity"),
                       "a conditionally-evaluated `amount / quantity` must NOT be an unconditional pre-bind. Bodies:\n\(preBindBodies)")
        // If it ships at all, it must be INLINE inside the conditional position.
        let nativeText = info.natives.joined(separator: "\n")
        if plan.pureFragments.contains(where: { $0.bodyStatements.joined().contains("amount / quantity") }) {
            XCTAssertTrue(nativeText.contains("Patch.call") && nativeText.contains("&&"),
                          "a shipped conditional sub-tree must be substituted INLINE inside the `&&`. Native:\n\(nativeText)")
        }
    }

    /// With the inline closure-local rewrite DISABLED, a conditionally-evaluated
    /// top-level sub-tree must DEMOTE to native (never the unconditional bind).
    func testConditionalSubTreeDemotesWhenInlineDisabled() {
        let source = """
        class C {
            var isEnabled = false
            func render(_ amount: Int, _ quantity: Int) {
                flag = self.isEnabled && (amount / quantity) > 0
            }
        }
        """
        let res = extract(source, id: "render(", closureLocalRewrite: false)
        if let plan = res.plan {
            let info = shellInfo(plan)
            let preBindBodies = plan.pureFragments
                .filter { info.preBinds.contains($0.name) }
                .flatMap { $0.bodyStatements }.joined(separator: "\n")
            XCTAssertFalse(preBindBodies.contains("amount / quantity"),
                           "with inline disabled, the conditional division must stay native, not pre-bound. Bodies:\n\(preBindBodies)")
        }
        // A conditional candidate may still be REPORTED (found-but-not-shipped).
        let div = res.extractions.first { $0.exprText.contains("amount / quantity") }
        if let div { XCTAssertFalse(div.shippableToday,
                       "a conditional division with inline disabled must not be shippable") }
    }

    /// A pure sub-tree on a TERNARY ARM (the whole ternary not liftable because the
    /// condition reads `self`) must not be hoisted to an unconditional bind either.
    func testConditionalTernaryArmSubTreeNeverHoisted() {
        let source = """
        class C {
            var ok = false
            func go(_ a: Int, _ b: Int) {
                tag = self.ok ? (a / b) : 0
            }
        }
        """
        let res = extract(source, id: "go(")
        guard let plan = res.plan else { return }
        let info = shellInfo(plan)
        let preBindBodies = plan.pureFragments
            .filter { info.preBinds.contains($0.name) }
            .flatMap { $0.bodyStatements }.joined(separator: "\n")
        XCTAssertFalse(preBindBodies.contains("a / b"),
                       "a ternary-arm `a / b` must NOT be an unconditional pre-bind. Bodies:\n\(preBindBodies)")
    }

    /// REGRESSION: an UNCONDITIONAL pure sub-tree (no `&&`/`||`/ternary guard) STILL
    /// lifts via the top-level bind — the conditional guard must not over-reject.
    func testUnconditionalSubTreeStillHoists() {
        let source = """
        import UIKit
        class C {
            func render(_ a: Int, _ b: Int, _ v: UILabel) {
                v.text = describe((a * b) + 7)
            }
            func describe(_ d: Int) -> String { "\\(d)" }
        }
        """
        let res = extract(source, id: "render(")
        XCTAssertTrue(allExprText(res).contains { $0.contains("(a * b) + 7") || $0.contains("a * b") },
                      "an unconditional sub-tree must still lift. Got: \(allExprText(res))")
        XCTAssertTrue(res.extractions.contains { $0.shippableToday },
                      "the unconditional lift must be shippable")
    }

    // MARK: - BUG R2-#45: property/local shadow guard

    /// A seeded property fed by BARE name must NOT be lifted when a body-LOCAL of the
    /// same name shadows it — the shell's `Args(scale: scale)` would resolve to the
    /// LOCAL, feeding the fragment the WRONG value. Such a candidate demotes.
    func testShadowedPropertyInputDemotes() {
        let source = """
        class Box {
            var scale: Double = 2.0
            func layout(_ overrideScale: Double, _ k: Double) -> Double {
                let scale = overrideScale
                return scale * 100.0 + k
            }
        }
        """
        // `scale` is BOTH a property (seeded Double) and a body-local. A lift whose
        // input set includes `scale` must be rejected (shadow ambiguity).
        let res = extract(source, id: "layout(")
        let shipped = res.extractions.filter { $0.shippableToday && $0.inputs.contains("scale") }
        XCTAssertTrue(shipped.isEmpty,
                      "a lift over the shadowed `scale` must demote (not ship the wrong value). Shipped: \(shipped.map { $0.exprText })")
        if let plan = res.plan {
            for frag in plan.pureFragments where frag.inputs.contains(where: { $0.name == "scale" }) {
                XCTFail("no shipped fragment may take the shadowed `scale` as input: \(frag.name)")
            }
        }
    }

    /// REGRESSION: a property with NO shadowing local still lifts (the guard is
    /// scoped to the genuine shadow case only — no coverage regression).
    func testUnshadowedPropertyStillLifts() {
        let source = """
        class Box {
            var scale: Double = 2.0
            func layout(_ k: Double) -> Double {
                return scale * 100.0 + k
            }
        }
        """
        let res = extract(source, id: "layout(")
        XCTAssertTrue(allExprText(res).contains { $0.contains("scale * 100.0") || $0.contains("scale * 100") },
                      "an UNshadowed property read must still lift. Got: \(allExprText(res))")
    }

    // MARK: - DEEP (wave2/subtree-deep)

    /// DEEP: a `filter`/`map` predicate over a concretely ABI-typed `[Int]`
    /// receiver, written with a SHORTHAND-named param (`{ p in … }`), lifts even
    /// though the committed extractor leaves it native (no typed element).
    func testHOFElementShorthandParamPredicateLifts() {
        let source = """
        import UIKit
        final class C: UIViewController {
            var prices: [Int] = []
            override func viewDidLoad() {
                super.viewDidLoad()
                let expensive = prices.filter { p in p > 100 && p < 9999 }
                self.view.tag = expensive.count
            }
        }
        """
        let res = extract(source, id: "viewDidLoad")
        XCTAssertTrue(allExprText(res).contains { $0.contains("p > 100 && p < 9999") },
                      "a pure filter predicate over a typed [Int] element must lift. Got: \(allExprText(res))")
        XCTAssertTrue(res.extractions.contains { $0.insideClosure && $0.shippableToday },
                      "the closure-local lift must be marked shippable (inline-call rewrite)")
        // Committed mode (deep:false) must NOT lift it (no element typing).
        let committed = extract(source, id: "viewDidLoad", deep: false)
        XCTAssertFalse(allExprText(committed).contains { $0.contains("p > 100") },
                       "committed mode must not lift the typed-element predicate. Got: \(allExprText(committed))")
    }

    /// DEEP: the closure-local rewrite emits a valid INLINE `Patch.call(...)`
    /// expression inside the closure body (where the element param is in scope), and
    /// the element param is passed as the fragment's Arg. The WASM module contains
    /// only the pure predicate (no `prices`, no `self`).
    func testClosureLocalRewriteEmitsInlineCall() {
        let source = """
        import UIKit
        final class C: UIViewController {
            var prices: [Int] = []
            override func viewDidLoad() {
                let big = prices.filter { p in p * 2 > 1000 }
                self.view.tag = big.count
            }
        }
        """
        let res = extract(source, id: "viewDidLoad")
        guard let plan = res.plan else { return XCTFail("no plan") }
        let files = CodeEmitter().emit(plan)
        // The bridge calls into WASM from inside the closure body, passing `p`.
        XCTAssertTrue(files.bridgeSource.contains("Patch.call(\"_se_viewDidLoad_closure0\""),
                      "the closure-local rewrite must emit an inline Patch.call. Bridge:\n\(files.bridgeSource)")
        XCTAssertTrue(files.bridgeSource.contains("_Args(p: p)"),
                      "the closure element param `p` must be passed as the fragment Arg")
        // The pure-logic function body in the WASM module is exactly the predicate.
        XCTAssertTrue(files.wasmSource.contains("return (p * 2 > 1000)"))
        XCTAssertFalse(files.wasmSource.contains("prices"),
                       "the native receiver must never enter the WASM module")
        // No `self.`-member access reaches the WASM module (the `.self` metatype in
        // the auto JSON-ABI wrapper is unrelated, so match the member-access form).
        XCTAssertFalse(files.wasmSource.contains("self."),
                       "no self-member access may enter the WASM module")
    }

    /// DEEP: a `sorted(by:)` comparator over `[Int]` types BOTH closure params and
    /// lifts a pure pairwise comparison.
    func testSortedComparatorOverTypedArrayLifts() {
        let source = """
        import UIKit
        final class C: UIViewController {
            var xs: [Int] = []
            override func viewDidLoad() {
                let s = xs.sorted { a, b in a * a < b * b }
                self.view.tag = s.count
            }
        }
        """
        let res = extract(source, id: "viewDidLoad")
        XCTAssertTrue(allExprText(res).contains { $0.contains("a * a < b * b") },
                      "a pure sorted comparator over a typed array must lift. Got: \(allExprText(res))")
    }

    /// DEEP SAFETY: a HOF over a NON-ABI element type (`[Movie]`) must NEVER type
    /// the closure param, so a body over the element stays native (zero false
    /// positive — the element type isn't ABI-round-trippable).
    func testHOFOverNonABIElementNeverLifts() {
        let source = """
        import UIKit
        struct Movie { let id: Int }
        final class C: UIViewController {
            var movies: [Movie] = []
            override func viewDidLoad() {
                let r = movies.filter { m in m.id > 100 && m.id < 9999 }
                self.view.tag = r.count
            }
        }
        """
        let res = extract(source, id: "viewDidLoad")
        XCTAssertFalse(allExprText(res).contains { $0.contains("m.id") },
                       "a predicate over a non-ABI element type must never lift. Got: \(allExprText(res))")
    }

    /// DEEP SAFETY: `reduce` types ONLY the element (2nd) param, never the
    /// accumulator — a sub-tree reading the accumulator (unknown type) stays native.
    func testReduceAccumulatorParamNeverTyped() {
        let source = """
        import UIKit
        final class C: UIViewController {
            var xs: [Int] = []
            override func viewDidLoad() {
                let total = xs.reduce(into: SomeBox()) { acc, x in acc.add(x * 2) }
                self.view.tag = total.value
            }
        }
        """
        let res = extract(source, id: "viewDidLoad")
        // `acc.add(...)` reads the untyped accumulator → never lifts. `x * 2` reads
        // only the typed element, so IT may lift (a pure element transform).
        XCTAssertFalse(allExprText(res).contains { $0.contains("acc") },
                       "a sub-tree over the untyped reduce accumulator must never lift. Got: \(allExprText(res))")
    }

    /// DEEP SAFETY: the element hint NEVER types a `$0`/`$1` shorthand (an illegal
    /// fragment-input identifier), so `xs.filter { $0 > 100 && $0 < 9999 }` stays
    /// native even though `xs: [Int]`.
    func testElementHintNeverTypesDollarShorthand() {
        let source = """
        import UIKit
        final class C: UIViewController {
            var xs: [Int] = []
            override func viewDidLoad() {
                let r = xs.filter { $0 > 100 && $0 < 9999 }
                self.view.tag = r.count
            }
        }
        """
        let res = extract(source, id: "viewDidLoad")
        XCTAssertFalse(res.extractions.contains { $0.exprText.contains("$0") },
                       "an implicit $0 must never be typed/lifted (illegal fragment input). Got: \(allExprText(res))")
    }

    /// DEEP: an ABI-typed `self` PROPERTY read inside a native body lifts a pure
    /// expression over it (the property is passed as a fragment input; the native
    /// shell supplies `self.<prop>`).
    func testPropertyTypedPureExprLifts() {
        let source = """
        import UIKit
        final class C: UIViewController {
            var discount: Double = 0
            var taxRate: Double = 0
            override func viewDidLoad() {
                self.view.tag = Int(discount * taxRate * 1000)
            }
        }
        """
        let res = extract(source, id: "viewDidLoad")
        XCTAssertTrue(allExprText(res).contains { $0.contains("discount * taxRate") },
                      "a pure expr over ABI-typed self properties must lift. Got: \(allExprText(res))")
        XCTAssertTrue(res.extractions.contains { $0.shippableToday },
                      "a property-only lift is top-level-scoped → shippable today")
    }

    /// DEEP SAFETY: the closure-local rewrite can be DISABLED; then a typed-element
    /// predicate is reported but left native (not shippable) — proving the rewrite
    /// is the unlock and the report stays honest.
    func testClosureLocalRewriteDisabledLeavesNative() {
        let source = """
        import UIKit
        final class C: UIViewController {
            var xs: [Int] = []
            override func viewDidLoad() {
                let r = xs.filter { p in p > 100 && p < 9999 }
                self.view.tag = r.count
            }
        }
        """
        let res = extract(source, id: "viewDidLoad", closureLocalRewrite: false)
        XCTAssertTrue(res.extractions.contains { $0.exprText.contains("p > 100") && !$0.shippableToday },
                      "with the rewrite off, the typed-element predicate is reported but NOT shippable")
        // No shippable fragment for it → no ABI export with that closure label form
        // that ships the predicate (plan may be nil if nothing else shippable).
        if let plan = res.plan {
            XCTAssertFalse(plan.pureFragments.contains { $0.bodyStatements.joined().contains("p > 100") },
                           "with the rewrite off, no fragment for the closure-local predicate is emitted")
        }
    }
}
