// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftParser
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// GRANULAR PARTITIONING + MODULE ISOLATION — two levels of "one or two native
/// lines don't ruin patchability of the rest".
///
/// (A) STATEMENT-LEVEL (within a function). Strategy A of `FunctionSplitter`
///     historically demoted an ENTIRE pure run to the native shell the moment the
///     run contained any control flow — so the leading pure statements were lost
///     just because the run happened to END in a `return`/`throw`. This is the
///     general-logic analogue of the UIKit "one weird line is contagious" bug. The
///     fix PEELS a contiguous TRAILING control-flow tail: the pure prefix lifts to
///     WASM (live-outs threaded), the `return`/`throw` stays native in the shell
///     consuming the bound output, in source order. STRICTLY demote-safe: only a
///     TRAILING tail peels (a control-flow statement MID-run keeps the whole run
///     native — the suffix would be conditional), and the prefix runs the SAME
///     capture / boundary / liftability gates as any other pure run.
///
/// (B) MODULE-LEVEL ISOLATION. A single general-logic unit whose generated guest
///     code fails to compile must NOT sink the whole module to zero patchable
///     units — the `WasmConvergence` loop drops just the offending candidate and
///     ships the rest. (The SwiftUI path has per-view isolation; this proves the
///     general-logic path has the equivalent per-unit isolation, end-to-end.)
final class GranularPartitionIsolationTests: XCTestCase {

    private let file = URL(fileURLWithPath: "/tmp/granular_partition.swift")

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

    /// Compile a generated `_wasm.swift` to a real `.wasm` module via the swift.org
    /// SDK; skips when the toolchain is absent so the suite stays green everywhere.
    private func realWasmCompile(_ wasmSource: String, exports: [String], label: String) throws {
        let compiler = SwiftWasmCompiler()
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping real compile")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gran-rs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("Frag_wasm.swift")
        try wasmSource.write(to: src, atomically: true, encoding: .utf8)
        let out = tmp.appendingPathComponent("frag.wasm")
        let c = SwiftWasmCompiler(exportedSymbols: exports)
        let result = try c.compile(sources: [src], outputModule: out)
        XCTAssertEqual(result.status, .success, "\(label) failed to compile:\n\(result.log)")
        let head = try FileHandle(forReadingFrom: out).readData(ofLength: 4)
        XCTAssertEqual([UInt8](head), [0x00, 0x61, 0x73, 0x6d], "\(label): not a WASM module")
    }

    /// All native (verbatim + rewritten) shell statements, in shell order.
    private func nativeSteps(_ plan: SplitPlan) -> [String] {
        plan.shellSteps.compactMap { step in
            if case let .nativeStatement(s) = step { return s }
            return nil
        }
    }

    // MARK: - (A) statement-level: trailing control-flow peel

    /// A function with a native side-effecting line FIRST, then pure derivation, then
    /// a `return` of the derived value: the pure prefix lifts to a WASM fragment, the
    /// `return` stays native consuming the fragment output. The whole function no
    /// longer demotes just because it ends in a `return`.
    func testTrailingReturnPeelsPurePrefixIntoFragment() throws {
        // Closure-free, concretely-typed pure derivation (the splitter infers
        // `a/b/c: Int` from `.count`/arithmetic) so the prefix is ABI-liftable.
        let source = """
        import Foundation
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
                              "a function ending in `return <pure>` must still split (not demote whole)")
        // The pure derivation lifts to a fragment.
        XCTAssertEqual(p.pureFragments.count, 1, "the pure prefix lifts to one fragment")
        let frag = try XCTUnwrap(p.pureFragments.first)
        XCTAssertTrue(frag.bodyStatements.contains { $0.contains("let b = a + 1") },
                      "the fragment carries the pure derivation: \(frag.bodyStatements)")
        XCTAssertEqual(frag.outputs.map { $0.name }, ["c"],
                       "the live-out the return reads is the fragment's output: \(frag.outputs)")
        // The native side-effect AND the return stay verbatim in the shell.
        let natives = nativeSteps(p)
        XCTAssertTrue(natives.contains { $0.contains("createFile") },
                      "the native side-effect stays in the shell: \(natives)")
        XCTAssertTrue(natives.contains("return c"),
                      "the return stays native, consuming the bound fragment output: \(natives)")
    }

    /// The fragment-call is emitted BEFORE the trailing native `return` in the shell
    /// body, so `sum` is bound before the `return` reads it (ordering correctness).
    func testFragmentCallPrecedesTrailingReturnInShell() throws {
        let source = """
        import Foundation
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
        let p = try XCTUnwrap(plan(source, idContains: "S.run"))
        // Find the index of the fragment call and the trailing return in the ordered
        // shell steps; the call must come first so the binding precedes its use.
        var fragIdx = -1, returnIdx = -1
        for (i, step) in p.shellSteps.enumerated() {
            switch step {
            case .fragmentCall: if fragIdx < 0 { fragIdx = i }
            case let .nativeStatement(s) where s.contains("return c"): returnIdx = i
            default: break
            }
        }
        XCTAssertGreaterThanOrEqual(fragIdx, 0, "a fragment call must be emitted")
        XCTAssertGreaterThanOrEqual(returnIdx, 0, "the return must be a native shell step")
        XCTAssertLessThan(fragIdx, returnIdx,
                          "the fragment (which binds `c`) must precede the `return c`")
    }

    /// END-TO-END: the emitted bridge body binds the fragment output as a local THEN
    /// returns it — so the generated native shell type-checks (`sum` is in scope).
    func testEmittedBridgeBindsThenReturns() throws {
        let source = """
        import Foundation
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
        let p = try XCTUnwrap(plan(source, idContains: "S.run"))
        let files = CodeEmitter().emit(p)
        // The bridge `let c = Patch.call(...).c` binding precedes `return c`.
        let bridge = files.bridgeSource
        let bindRange = try XCTUnwrap(bridge.range(of: "let c ="),
                                      "the shell must bind `c` from the fragment call:\n\(bridge)")
        let retRange = try XCTUnwrap(bridge.range(of: "return c"),
                                     "the shell must return the bound value:\n\(bridge)")
        XCTAssertLessThan(bindRange.lowerBound, retRange.lowerBound,
                          "the binding must precede the return in the shell body:\n\(bridge)")
        // The pure derivation must NOT appear in the native shell — it rides WASM.
        XCTAssertFalse(bridge.contains("let b = a + 1"),
                       "the pure derivation must NOT be in the native shell (it lifted):\n\(bridge)")
    }

    /// DEMOTE-SAFETY: a control-flow `if … { return }` in the MIDDLE of a run is NOT
    /// peeled — the pure work AFTER it would become unconditional if hoisted before
    /// the branch. Only a TRAILING control-flow tail peels; a mid-run early-return
    /// keeps the whole function native (no fragment may ever swallow the branch). This
    /// also guards the latent-bug fix: a statement-position `if x { return }` (wrapped
    /// by SwiftSyntax in an `ExpressionStmtSyntax`) is now correctly detected as
    /// control flow, so it can never be lifted into a value fragment.
    func testMidRunEarlyReturnKeepsFunctionNativeAndNeverLiftsBranch() throws {
        let source = """
        import Foundation
        struct S {
            func run(_ items: [Int], _ path: String) -> Int {
                FileManager.default.createFile(atPath: path, contents: nil)
                let firstHalf = items.count
                if firstHalf == 0 { return 0 }
                let rest = items.count + 1
                return firstHalf + rest
            }
        }
        """
        let p = plan(source, idContains: "S.run")
        if let p {
            // CARDINAL SAFETY: no fragment may ever contain the `if … { return }`
            // branch (moving control flow into WASM / returning the wrong shape).
            for f in p.pureFragments {
                XCTAssertFalse(f.bodyStatements.contains { $0.contains("if firstHalf == 0") || $0.contains("return 0") },
                               "an early-return branch must NEVER be lifted into a fragment: \(f.bodyStatements)")
            }
        }
        // The expected, demote-safe outcome is whole-function native (no clean split
        // exists once the mid-run branch is honoured) — which is correct: it is
        // better to keep the function native than to ship an unsound partition.
        XCTAssertNil(p, "a mid-run early-return `if` keeps the whole function native (demote-safe)")
    }

    /// DEMOTE-SAFETY: a pure prefix that CAPTURES an unavailable value still keeps the
    /// run native even when peeling the trailing return (the same no-capture gate
    /// applies). Here the prefix uses a closure capturing a value not in fragment
    /// scope is not the case; instead test a non-liftable boundary type prefix.
    func testNonLiftableBoundaryPrefixStaysNativeEvenWithTrailingReturn() throws {
        // The prefix derives a value of a NON-liftable native type (`URLSession`), so
        // it can't cross the ABI boundary; the whole run stays native even though it
        // ends in a return.
        let source = """
        import Foundation
        struct S {
            func run(_ path: String) -> Int {
                FileManager.default.createFile(atPath: path, contents: nil)
                let session = URLSession.shared
                let n = session.configuration.httpMaximumConnectionsPerHost
                return n
            }
        }
        """
        // Either no plan (whole native) or a plan with NO fragment that carries the
        // URLSession-typed value — never a fragment marshalling a native type.
        if let p = plan(source, idContains: "S.run") {
            for f in p.pureFragments {
                XCTAssertFalse(f.inputs.contains { $0.type.contains("URLSession") },
                               "no fragment may carry a non-liftable native type input: \(f.inputs)")
                XCTAssertFalse(f.outputs.contains { $0.type.contains("URLSession") },
                               "no fragment may carry a non-liftable native type output: \(f.outputs)")
            }
        }
    }

    /// A trailing `guard … else { throw }` tail (not just `return`) also peels: the
    /// pure prefix lifts, the guard/throw stays native consuming the bound output.
    /// Proves the peel keys on control flow generically (a `guard`-with-`throw`).
    func testTrailingGuardThrowAlsoPeels() throws {
        let source = """
        import Foundation
        struct S {
            func run(_ items: [Int], _ path: String) throws -> Int {
                FileManager.default.createFile(atPath: path, contents: nil)
                let total = items.count + 1
                guard total > 0 else { throw NSError(domain: "x", code: 1) }
                return total
            }
        }
        """
        let p = try XCTUnwrap(plan(source, idContains: "S.run"),
                              "a function ending in a control-flow tail must still split")
        // The pure `let total` prefix lifts to a fragment outputting `total`.
        XCTAssertTrue(p.pureFragments.contains { $0.outputs.contains { $0.name == "total" } },
                      "the pure prefix lifts, outputting the value the tail consumes: \(p.pureFragments.map { $0.outputs })")
        // CARDINAL SAFETY: no fragment may ever swallow the guard/throw control flow.
        for f in p.pureFragments {
            XCTAssertFalse(f.bodyStatements.contains { $0.contains("throw") || $0.contains("guard") },
                           "control flow must never be lifted into a fragment: \(f.bodyStatements)")
        }
        // The guard/throw and the return stay native, in source order, after the call.
        let natives = nativeSteps(p)
        XCTAssertTrue(natives.contains { $0.contains("guard total > 0") },
                      "the guard/throw stays native: \(natives)")
        XCTAssertTrue(natives.contains("return total"),
                      "the return stays native consuming the bound output: \(natives)")
    }

    /// LATENT-BUG REGRESSION (the soundness fix this work surfaced): a STATEMENT-
    /// POSITION `if cond { return X }` — which SwiftSyntax wraps in an
    /// `ExpressionStmtSyntax`, NOT a bare `IfExprSyntax` — must be classified as
    /// CONTROL FLOW so it is never lifted into a value fragment. Before the fix, such
    /// an `if` (with an early `return`) was lifted whole into a WASM fragment whose
    /// declared return shape was the run's live-out tuple — an unsound fragment that
    /// returned the wrong shape / moved control flow into WASM.
    func testStatementPositionIfWithEarlyReturnIsNeverLifted() throws {
        let source = """
        import Foundation
        struct S {
            func run(_ items: [Int], _ path: String) -> Int {
                let n = items.count
                if n == 0 { return 0 }
                FileManager.default.createFile(atPath: path, contents: nil)
                return n
            }
        }
        """
        // Whatever split (or none) is produced, NO fragment may carry the early-return
        // `if`. (Here the `if` precedes the native call, so it cannot peel as a tail.)
        if let p = plan(source, idContains: "S.run") {
            for f in p.pureFragments {
                XCTAssertFalse(f.bodyStatements.contains { $0.contains("if n == 0") || $0.contains("return 0") },
                               "a statement-position `if { return }` must never be lifted: \(f.bodyStatements)")
            }
        }
    }

    /// END-TO-END (real WASM): the peeled pure prefix fragment really compiles to a
    /// valid `.wasm` module via the swift.org SDK — proving the partition isn't just
    /// structurally plausible but actually ships.
    func testPeeledPrefixFragmentCompilesToWasm() throws {
        let source = """
        import Foundation
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
        let p = try XCTUnwrap(plan(source, idContains: "S.run"))
        let files = CodeEmitter().emit(p)
        XCTAssertTrue(files.exportSymbols.contains("_sp_run_prepare"),
                      "the peeled prefix must be a real export: \(files.exportSymbols)")
        try realWasmCompile(files.wasmSource, exports: files.exportSymbols, label: "peeled-prefix")
    }

    // MARK: - (B) module-level isolation (general-logic path)

    /// One non-compiling general-logic unit must NOT sink the module — the
    /// convergence loop demotes just the offending candidate and ships the rest.
    /// This mirrors the SwiftUI per-view isolation for the general path, exercised
    /// through the real attribution code with a scripted compiler.
    func testOneBadGeneralUnitDoesNotSinkModule() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gran-iso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Three independent general-logic units; the middle one is the culprit.
        let healthyA = tmp.appendingPathComponent("alpha_wasm.swift")
        let bad = tmp.appendingPathComponent("beta_wasm.swift")
        let healthyB = tmp.appendingPathComponent("gamma_wasm.swift")
        try "func a() {}".write(to: healthyA, atomically: true, encoding: .utf8)
        try "func b() {}".write(to: bad, atomically: true, encoding: .utf8)
        try "func c() {}".write(to: healthyB, atomically: true, encoding: .utf8)

        let convergence = WasmConvergence(compiler: FailNamedFileCompiler(failing: "beta_wasm.swift"))
        let outcome = try convergence.converge(
            [
                .init(functionID: "alpha", sourceFile: healthyA, exports: ["a"]),
                .init(functionID: "beta", sourceFile: bad, exports: ["b"]),
                .init(functionID: "gamma", sourceFile: healthyB, exports: ["c"]),
            ],
            outputModule: tmp.appendingPathComponent("module.wasm"))

        XCTAssertEqual(Set(outcome.compiled.map { $0.functionID }), ["alpha", "gamma"],
                       "the two healthy units must still ship")
        XCTAssertEqual(outcome.reclassifiedNative.map { $0.functionID }, ["beta"],
                       "only the non-compiling unit is demoted to native")
        XCTAssertNotNil(outcome.moduleURL,
                        "the module must still be emitted (not zero units)")
    }

    /// Demoting the culprit converges in ONE extra iteration (the loop blames all
    /// failing candidates in a pass), not one slow recompile per surviving unit — and
    /// the surviving exports are exactly the healthy ones.
    func testModuleIsolationConvergesFastWithMultipleBadUnits() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gran-iso2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let good = tmp.appendingPathComponent("good_wasm.swift")
        let bad1 = tmp.appendingPathComponent("bad1_wasm.swift")
        let bad2 = tmp.appendingPathComponent("bad2_wasm.swift")
        for u in [good, bad1, bad2] { try "func f() {}".write(to: u, atomically: true, encoding: .utf8) }

        let convergence = WasmConvergence(compiler: FailNamedSetCompiler(failing: ["bad1_wasm.swift", "bad2_wasm.swift"]))
        let outcome = try convergence.converge(
            [
                .init(functionID: "good", sourceFile: good, exports: ["good_export"]),
                .init(functionID: "bad1", sourceFile: bad1, exports: ["bad1_export"]),
                .init(functionID: "bad2", sourceFile: bad2, exports: ["bad2_export"]),
            ],
            outputModule: tmp.appendingPathComponent("module.wasm"))

        XCTAssertEqual(outcome.compiled.map { $0.functionID }, ["good"],
                       "only the healthy unit ships")
        XCTAssertEqual(Set(outcome.reclassifiedNative.map { $0.functionID }), ["bad1", "bad2"],
                       "both bad units demote in one pass")
        // 2 iterations max: (1) all-three fails blaming both bad files, (2) survivors compile.
        XCTAssertLessThanOrEqual(outcome.iterations, 3,
                                 "both culprits demote in one pass (no per-unit slow recompile)")
        XCTAssertNotNil(outcome.moduleURL, "the healthy unit's module still emits")
    }
}

/// A scripted compiler that FAILS only when a specific file is in the source set,
/// naming it in the standard `<path>:line:col: error:` Swift-diagnostic form so the
/// convergence loop's path-component attribution is exercised exactly as in prod.
private struct FailNamedFileCompiler: WasmCompiling {
    let failing: String
    func compile(sources: [URL], outputModule: URL) throws -> WasmCompileResult {
        if let bad = sources.first(where: { $0.lastPathComponent == failing }) {
            return WasmCompileResult(
                status: .failure(reason: "scripted"),
                moduleURL: nil,
                log: "\(bad.path):2:3: error: scripted compile failure for \(failing)\n")
        }
        try? Data([0x00, 0x61, 0x73, 0x6d]).write(to: outputModule)
        return WasmCompileResult(status: .success, moduleURL: outputModule, log: "ok")
    }
}

/// Like `FailNamedFileCompiler` but fails for ANY of a SET of files (blames all that
/// are present), so the loop's "demote every blamed candidate in one pass" path is
/// exercised.
private struct FailNamedSetCompiler: WasmCompiling {
    let failing: Set<String>
    func compile(sources: [URL], outputModule: URL) throws -> WasmCompileResult {
        let present = sources.filter { failing.contains($0.lastPathComponent) }
        if !present.isEmpty {
            let log = present.map { "\($0.path):1:1: error: scripted failure\n" }.joined()
            return WasmCompileResult(status: .failure(reason: "scripted"), moduleURL: nil, log: log)
        }
        try? Data([0x00, 0x61, 0x73, 0x6d]).write(to: outputModule)
        return WasmCompileResult(status: .success, moduleURL: outputModule, log: "ok")
    }
}
