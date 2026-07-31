// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftParser
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// SOUNDNESS regressions for the general-logic partitioning engine
/// (`FunctionSplitter` / `FusionRewriter`). Each test pins a bug where the engine
/// produced TRAPPING or NON-COMPILING output, and asserts the CORE INVARIANT
/// "build-safe = demote-safe": the unsound shape now DEMOTES to native (or is not
/// lifted), never ships code that traps or computes the wrong result.
final class PartitioningSoundnessRound1Tests: XCTestCase {

    private let file = URL(fileURLWithPath: "/tmp/partition_soundness_round1.swift")

    private func plan(_ source: String, idContains: String,
                      nativeCallees: Set<String> = []) -> SplitPlan? {
        let recs = SwiftParserEngine().parse(source: source, file: file)
        guard let r = recs.first(where: { $0.id.contains(idContains) }) else { return nil }
        let tree = Parser.parse(source: source)
        let index = DeclarationIndex(tree: tree)
        var outcome: FunctionSplitter.Outcome = .noBody
        return FunctionSplitter(nativeCalleeNames: nativeCallees)
            .plan(for: r, index: index, inferredTypes: [:], outcome: &outcome)
    }

    /// Every shell step's text, in shell order (native verbatim + rewritten lines).
    private func shellText(_ plan: SplitPlan) -> String {
        plan.shellSteps.map { step -> String in
            switch step {
            case let .nativeStatement(s): return s
            case let .guardConditionCall(_, rewritten): return rewritten
            case let .subExprCall(_, rewritten): return rewritten
            case .fragmentCall: return ""
            }
        }.joined(separator: "\n")
    }

    // MARK: - BUG #4 — sub-expression lifting must not hoist a conditional operand

    /// `self.ready && (count / divisor > 0)` — the RHS divide is short-circuited
    /// natively (only runs when `ready == true`). Lifting it would emit an
    /// UNCONDITIONAL `let frag_v = Patch.call(...)` that divides even when
    /// `ready == false`, trapping on `divisor == 0`. The sub-expression must NOT
    /// be lifted (the statement stays native → demote-safe).
    func testShortCircuitRHSDivideIsNeverLifted() {
        let source = """
        struct S {
            let ready: Bool
            func check(_ count: Int, _ divisor: Int) -> Bool {
                return self.ready && (count / divisor > 0)
            }
        }
        """
        let p = plan(source, idContains: "S.check")
        // Whatever plan (or none) results, NO fragment may carry the short-circuited
        // divide, and no rewritten statement may dispatch it.
        if let p {
            for f in p.pureFragments {
                XCTAssertFalse(f.bodyStatements.contains { $0.contains("count / divisor") },
                               "the short-circuited divide must never be lifted: \(f.bodyStatements)")
            }
            XCTAssertFalse(shellText(p).contains("_v"),
                           "no sub-expr temp may dispatch the conditional operand:\n\(shellText(p))")
        }
        // Expected demote-safe outcome: whole-statement native (the only statement
        // touches `self`, and the only liftable sub-expr is conditionally evaluated).
        XCTAssertNil(p, "a short-circuited operand keeps the statement native (demote-safe)")
    }

    /// A ternary branch `cond ? (a / b) : 0` — the `a / b` only runs on the true
    /// arm. Lifting it would divide unconditionally (trap on `b == 0`). Never lift.
    func testTernaryBranchDivideIsNeverLifted() {
        let source = """
        struct S {
            let flag: Bool
            func pick(_ a: Int, _ b: Int) -> Int {
                return self.flag ? (a / b) : 0
            }
        }
        """
        let p = plan(source, idContains: "S.pick")
        if let p {
            for f in p.pureFragments {
                XCTAssertFalse(f.bodyStatements.contains { $0.contains("a / b") },
                               "a ternary-branch divide must never be lifted: \(f.bodyStatements)")
            }
        }
        XCTAssertNil(p, "a ternary-branch operand keeps the statement native (demote-safe)")
    }

    /// CONTROL: an UNCONDITIONAL pure sub-expression inside a native statement still
    /// lifts (the fix is surgical — it only rejects conditionally-evaluated operands).
    func testUnconditionalSubExprStillLifts() throws {
        let source = """
        struct S {
            let label: String
            func tag(_ a: Int, _ b: Int) -> String {
                return self.label + String(a * b + 1)
            }
        }
        """
        let p = try XCTUnwrap(plan(source, idContains: "S.tag"),
                              "an unconditional pure sub-expr must still lift")
        XCTAssertTrue(p.pureFragments.contains { $0.bodyStatements.contains { $0.contains("a * b") } },
                      "the unconditional `a * b + 1` lifts: \(p.pureFragments.map { $0.bodyStatements })")
    }

    // MARK: - BUG #6 / #25 — a lifted live-out reassigned downstream must demote

    /// A pure prefix binds `var total = items.reduce(0, +)`; a trailing `for` tail
    /// MUTATES `total`. The shell would bind it `let total = Frag().total`, then the
    /// peeled `for x in extra { total += x }` would assign to a `let` — a
    /// non-compiling native shell. The run must stay native (demote-safe).
    func testTrailingMutatingTailKeepsRunNative() {
        let source = """
        struct S {
            func sum(_ items: [Int], _ extra: [Int]) -> Int {
                var total = items.reduce(0, +)
                for x in extra { total += x }
                return total
            }
        }
        """
        let p = plan(source, idContains: "S.sum")
        // No fragment may output `total` (it is reassigned by the native tail), so the
        // shell never binds `total` as a `let` from a fragment.
        if let p {
            for f in p.pureFragments {
                XCTAssertFalse(f.outputs.contains { $0.name == "total" },
                               "a downstream-mutated value must not be a fragment live-out: \(f.outputs)")
            }
        }
        XCTAssertNil(p, "a lifted output mutated by the native tail keeps the run native (demote-safe)")
    }

    /// strategyA's pure-prefix peel must NOT make `var total = items.reduce(0,+)` a
    /// fragment live-out when a downstream statement-position `if total > 100
    /// { total = 100 }` REASSIGNS it — the shell would bind `let total = Frag().total`
    /// (un-assignable). The engine may still find OTHER sound lifts (e.g. the `if`
    /// condition); the cardinal invariant is that NO fragment outputs a value the
    /// native tail reassigns, AND the `total` reduce stays native.
    func testDownstreamIfReassignmentDoesNotLiftMutatedLiveOut() {
        let source = """
        struct S {
            func compute(_ items: [Int], _ path: String) -> Int {
                FileManager.default.createFile(atPath: path, contents: nil)
                var total = items.reduce(0, +)
                if total > 100 { total = 100 }
                return total
            }
        }
        """
        guard let p = plan(source, idContains: "S.compute") else {
            return   // whole-function native is also a valid demote-safe outcome
        }
        for f in p.pureFragments {
            XCTAssertFalse(f.outputs.contains { $0.name == "total" },
                           "a downstream-reassigned value must not be a fragment live-out: \(f.outputs)")
        }
        // The `var total = items.reduce` declaration stays native (it is the mutated
        // value's source) — it must NOT have been lifted into a fragment body.
        for f in p.pureFragments {
            XCTAssertFalse(f.bodyStatements.contains { $0.contains("var total = items.reduce") },
                           "the mutated value's declaration must stay native: \(f.bodyStatements)")
        }
        // The emitted bridge must never bind `total` from a fragment as a `let` it then
        // reassigns: if `total` is bound, the shell must not also reassign that binding.
        let bridge = CodeEmitter().emit(p).bridgeSource
        if bridge.contains("let total = ") {
            XCTAssertFalse(bridge.contains("total = 100"),
                           "a `let`-bound fragment output must never be reassigned in the shell:\n\(bridge)")
        }
    }

    /// CONTROL: a lifted live-out that is only READ (never reassigned) downstream
    /// still lifts — the fix only demotes when the value is MUTATED after the range.
    func testReadOnlyLiveOutStillLifts() throws {
        let source = """
        struct S {
            func run(_ items: [Int], _ path: String) -> Int {
                FileManager.default.createFile(atPath: path, contents: nil)
                let a = items.count
                let b = a + 1
                let c = b * 2
                return c
            }
        }
        """
        let p = try XCTUnwrap(plan(source, idContains: "S.run"),
                              "a read-only live-out prefix must still lift")
        XCTAssertTrue(p.pureFragments.contains { $0.outputs.contains { $0.name == "c" } },
                      "the read-only `c` lifts as a fragment output: \(p.pureFragments.map { $0.outputs })")
    }

    // MARK: - BUG R2-#44 — exotic l-value reassignment must be conservatively recorded

    /// A pure prefix binds `var total = items.reduce(0,+)` (a live-out), then a peeled
    /// trailing TUPLE-DESTRUCTURING assignment `(total, _) = …` REASSIGNS `total`
    /// through an l-value whose base is NOT a simple identifier. Before the fix
    /// `MutatedNameScanner.baseName` returned nil for the 2-element tuple and recorded
    /// NOTHING, so `total` was not flagged mutated → it was lifted as a `let`-bound
    /// fragment output → the shell `let total = Frag().total` then `(total, _) = …`
    /// reassigned a `let` (a non-compiling shell). `recordMutation` now OVER-records
    /// every identifier in an exotic l-value, so `total` stays native (demote-safe).
    func testTupleDestructuringReassignmentIsRecorded() {
        let source = """
        struct S {
            func clampSum(_ items: [Int]) -> Int {
                FileManager.default.createFile(atPath: "x", contents: nil)
                var total = items.reduce(0, +)
                (total, _) = (min(total, 100), 0)
                return total
            }
        }
        """
        guard let p = plan(source, idContains: "S.clampSum") else {
            return   // whole-function native is also a valid demote-safe outcome
        }
        // No fragment may output `total` (it is reassigned by the tuple-destructuring
        // tail), so the shell never binds `total` as a `let` from a fragment.
        for f in p.pureFragments {
            XCTAssertFalse(f.outputs.contains { $0.name == "total" },
                           "a tuple-destructuring-reassigned value must not be a fragment live-out: \(f.outputs)")
        }
        // The emitted shell must never bind `total` as a `let` then reassign it.
        let bridge = CodeEmitter().emit(p).bridgeSource
        if bridge.contains("let total = ") {
            XCTAssertFalse(bridge.contains("(total, _) ="),
                           "a `let`-bound fragment output must never be tuple-reassigned in the shell:\n\(bridge)")
        }
    }

    /// Direct unit test of the conservative over-record: `MutatedNameScanner` records
    /// `total` from a 2-element tuple-destructuring l-value (where the simple-base
    /// resolver fails), rather than silently recording nothing.
    func testMutatedNameScannerOverRecordsExoticLValue() {
        let stmt = Parser.parse(source: "(total, x) = (1, 2)").statements.first!
        let ms = MutatedNameScanner()
        ms.walk(stmt)
        XCTAssertTrue(ms.mutated.contains("total"),
                      "a tuple-destructuring l-value must record its identifiers: \(ms.mutated)")
        XCTAssertTrue(ms.mutated.contains("x"),
                      "every identifier in the exotic l-value is over-recorded: \(ms.mutated)")
    }

    /// CONTROL: a simple-identifier reassignment is still recorded exactly (no
    /// over-recording of unrelated RHS names).
    func testMutatedNameScannerSimpleReassignmentIsExact() {
        let stmt = Parser.parse(source: "total = a + b").statements.first!
        let ms = MutatedNameScanner()
        ms.walk(stmt)
        XCTAssertTrue(ms.mutated.contains("total"), "the LHS base is recorded: \(ms.mutated)")
        XCTAssertFalse(ms.mutated.contains("a"), "RHS reads are NOT mutations: \(ms.mutated)")
        XCTAssertFalse(ms.mutated.contains("b"), "RHS reads are NOT mutations: \(ms.mutated)")
    }

    // MARK: - BUG #54 — non-decimal numeric literal must not route to String shim

    /// `set(0xFF, forKey:)` / `1e5` / `0b1010` / `0o17` are non-decimal numeric
    /// literals the decimal-only typed patterns miss. They must NOT be captured as a
    /// String value (which would pass an Int/Double literal to a `String`-typed shim,
    /// a guest WASM compile failure). The String set rewrite must NOT fire.
    func testNonDecimalNumericSetNotRoutedToStringShim() {
        for literal in ["0xFF", "1e5", "0b1010", "0o17"] {
            let src = "UserDefaults.standard.set(\(literal), forKey: \"mask\")"
            let r = FusionRewriter().rewrite(src)
            XCTAssertFalse(r.source.contains("_patchFusionDefaultsSetString"),
                           "`\(literal)` must NOT route through the String shim; got: \(r.source)")
        }
    }

    /// CONTROL: a genuine String value still routes to the String shim (the fix
    /// only excludes values BEGINNING with a digit — a String value never does).
    func testStringValueStillRoutesToStringShim() {
        let src = #"UserDefaults.standard.set(code, forKey: "currencyCode")"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.source.contains(#"_patchFusionDefaultsSetString(code, "currencyCode")"#),
                      "a String value must still lower: \(r.source)")
    }

    // MARK: - BUG #55 — codeMask must model raw string literals

    // A raw-string DELIMITER built explicitly so the test's own Swift literal is not
    // ambiguous (a `#"…"#` nested inside a `#"…"#` would not terminate).
    private static let rawOpen = "#\""    // the characters: #  "
    private static let rawClose = "\"#"   // the characters: "  #

    /// A call FORM appearing as DATA inside a raw string `#"…"#` must be masked as
    /// NON-CODE so it is never rewritten into a live call (corrupting the value).
    func testRawStringContentIsMaskedAsNonCode() {
        let inner = "To validate: text.range(of: pattern, options: .regularExpression) != nil"
        let doc = "let doc = \(Self.rawOpen)\(inner)\(Self.rawClose)"
        let mask = FusionRewriter.codeMask(doc)
        // The byte offset of `text.range` inside the raw string must be masked false.
        let ns = doc as NSString
        let rangeOfCall = ns.range(of: "text.range(of:")
        XCTAssertNotEqual(rangeOfCall.location, NSNotFound)
        XCTAssertFalse(mask[rangeOfCall.location],
                       "a call form inside a raw string literal must be masked as NON-code")
    }

    /// END-TO-END: the regex-test fusion rewrite must NOT corrupt a regex call form
    /// that lives as DATA inside a raw string literal (the wrong-render this guards).
    func testRegexCallInsideRawStringIsNotRewritten() {
        let inner = "text.range(of: pattern, options: .regularExpression) != nil"
        let rawLiteral = "\(Self.rawOpen)\(inner)\(Self.rawClose)"
        let src = "let doc = \(rawLiteral)"
        let r = FusionRewriter().rewrite(src)
        XCTAssertFalse(r.source.contains("_patchFusionRegexTest"),
                       "a regex call FORM inside a raw string is DATA, not code; got: \(r.source)")
        XCTAssertTrue(r.source.contains(rawLiteral),
                      "the raw string value must carry through verbatim; got: \(r.source)")
    }

    /// CONTROL: a real (un-quoted) regex-test call still rewrites — the raw-string
    /// modelling does not over-mask ordinary code.
    func testRealRegexCallStillRewrites() {
        let src = #"let ok = text.range(of: pattern, options: .regularExpression) != nil"#
        let r = FusionRewriter().rewrite(src)
        XCTAssertTrue(r.source.contains("_patchFusionRegexTest"),
                      "a genuine regex-test call must still lower; got: \(r.source)")
    }
}
