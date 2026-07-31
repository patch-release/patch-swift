// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import SwiftParser
import WasmKit
import WasmKitWASI
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// Verifies the codegen-robustness blockers from `research/build-triage/FINDINGS.md`
/// — fixes that each break a fragment in NEARLY EVERY app and are invisible if you
/// only test a hand-picked pure free function:
///
///   A. operator-named codegen (`==`/`<`/`*`/… → invalid `@_cdecl("==")` /
///      `struct ==_Args`) — sanitize the symbol, still call the real operator.
///   C. codegen crash on an empty/anonymous fragment name (a bare `/_wasm.swift` /
///      `_wasm.swift` that crashed YPImagePicker).
///   D. T0 host-bridge helpers (`_patchReadArgs`/`_patchEncodeResult`) emitted only
///      into the FIRST wrapper file → a 2nd T0 export fails `cannot find` them.
///   E. non-Codable boundary types — synthesize Codable for plain value types,
///      demote conservatively when a boundary type genuinely can't conform.
///   B. test code (XCTest / swift-testing / XCUIApplication) excluded from OTA.
final class CodegenRobustnessTests: XCTestCase {

    // MARK: - Host runner for T0 (mirrors T0EmbeddedCodegenTests / FoundationBridge)

    private final class T0Runner {
        let store: Store; let instance: Instance; let wasi: WASIBridgeToHost
        init(wasm: [UInt8]) throws {
            let engine = Engine()
            self.store = Store(engine: engine)
            self.wasi = try WASIBridgeToHost()
            var imports = Imports()
            wasi.link(to: &imports, store: store)
            // Full patch_host bridge surface (the generated C header declares all
            // imports, so a T0 module imports the whole set even when unused).
            PatchHostTestImports.register(into: &imports, store: store)
            let module = try parseWasm(bytes: wasm)
            self.instance = try module.instantiate(store: store, imports: imports)
            try wasi.initialize(instance)
        }

        func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
            guard let mem = instance.exports[memory: "memory"],
                  let malloc = instance.exports[function: "patch_malloc"],
                  let fn = instance.exports[function: name] else { throw NSError(domain: "t0", code: 1) }
            let inPtr = try malloc([.i32(UInt32(input.count))])[0].i32
            mem.withUnsafeMutableBufferPointer(offset: UInt(inPtr), count: input.count) { $0.copyBytes(from: input) }
            let packed = try fn([.i32(inPtr), .i32(UInt32(input.count))])[0].i64
            let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
            let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
            let all = mem.data
            return [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
        }
    }

    private func compileT0OrSkip(support: String, wrapper: (name: String, content: String),
                                 exports: [String]) throws -> [UInt8] {
        let compiler = SwiftWasmCompiler(exportedSymbols: exports, tier: .t0Embedded)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping T0 round-trip")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cgr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let supportURL = tmp.appendingPathComponent("Logic.swift")
        try support.write(to: supportURL, atomically: true, encoding: .utf8)
        let wrapperURL = tmp.appendingPathComponent(wrapper.name)
        try wrapper.content.write(to: wrapperURL, atomically: true, encoding: .utf8)
        let out = tmp.appendingPathComponent("module.wasm")
        let result = try compiler.compile(sources: [supportURL, wrapperURL], outputModule: out)
        XCTAssertEqual(result.status, .success, "T0 compile failed:\n\(result.log)")
        return [UInt8](try Data(contentsOf: out))
    }

    /// Compile multiple wrapper files + support into ONE module (for Fix D: two T0
    /// exports in the same compile unit).
    private func compileT0MultiOrSkip(support: String, wrappers: [(name: String, content: String)],
                                      exports: [String]) throws -> [UInt8] {
        let compiler = SwiftWasmCompiler(exportedSymbols: exports, tier: .t0Embedded)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping T0 multi-export compile")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cgr-multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        let supportURL = tmp.appendingPathComponent("Logic.swift")
        try support.write(to: supportURL, atomically: true, encoding: .utf8); sources.append(supportURL)
        for w in wrappers {
            let u = tmp.appendingPathComponent(w.name)
            try w.content.write(to: u, atomically: true, encoding: .utf8); sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "T0 multi-export compile failed:\n\(result.log)")
        return [UInt8](try Data(contentsOf: out))
    }

    // MARK: - Fix A: operator-name sanitization

    func testSanitizerMapsOperatorsToStableValidIdentifiers() {
        XCTAssertEqual(CodeEmitter.sanitizedExportSymbol("=="), "op_eqeq")
        XCTAssertEqual(CodeEmitter.sanitizedExportSymbol("<"), "op_lt")
        XCTAssertEqual(CodeEmitter.sanitizedExportSymbol("<="), "op_lteq")
        XCTAssertEqual(CodeEmitter.sanitizedExportSymbol(">="), "op_gteq")
        XCTAssertEqual(CodeEmitter.sanitizedExportSymbol("+"), "op_plus")
        XCTAssertEqual(CodeEmitter.sanitizedExportSymbol("*"), "op_star")
        XCTAssertEqual(CodeEmitter.sanitizedExportSymbol("/"), "op_slash")
        XCTAssertEqual(CodeEmitter.sanitizedExportSymbol("&&"), "op_ampamp")
        XCTAssertEqual(CodeEmitter.sanitizedExportSymbol("+="), "op_pluseq")
        // Each result is a valid Swift identifier (starts letter/_, ident chars only).
        for op in ["==", "<", "<=", ">=", "+", "*", "/", "&&", "+=", "|=", "^=", "~", "%"] {
            let s = CodeEmitter.sanitizedExportSymbol(op)
            XCTAssertTrue(s.first!.isLetter || s.first! == "_", "\(op) → \(s) bad first char")
            XCTAssertTrue(s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }, "\(op) → \(s) bad chars")
        }
        // Distinct operators map to distinct symbols (no collisions for <= vs >= vs ==).
        let ops = ["==", "<", ">", "<=", ">=", "+", "-", "*", "/", "&&", "||"]
        let mapped = Set(ops.map { CodeEmitter.sanitizedExportSymbol($0) })
        XCTAssertEqual(mapped.count, ops.count, "operator symbols must be collision-free")
        // Stability: a valid identifier is returned UNCHANGED (no churn on existing exports).
        XCTAssertEqual(CodeEmitter.sanitizedExportSymbol("checkout"), "checkout")
        XCTAssertEqual(CodeEmitter.sanitizedExportSymbol("_pv_Card_fontSize"), "_pv_Card_fontSize")
    }

    /// The emitted `==` wrapper now contains NO invalid `@_cdecl("==")` / `struct
    /// ==_Args` / `func ==(...)`; it uses the sanitized symbol and calls the REAL
    /// operator (`a == b`) inside.
    func testOperatorExportEmitsValidSwift() {
        let scanned = PureExportScanner().scan(source: """
        struct Money: Equatable {
            let cents: Int
            static func == (lhs: Money, rhs: Money) -> Bool { lhs.cents == rhs.cents }
        }
        """, eligibleSimpleNames: ["=="])
        guard let op = scanned.first else { return XCTFail("operator export not produced (was it skipped?)") }
        XCTAssertEqual(op.operatorFixity, .infix)
        XCTAssertEqual(op.operatorToken, "==")
        let emitted = CodeEmitter().emitFoundationPureExportFilePublic(op, includeAllocator: true)
        XCTAssertFalse(emitted.source.contains("@_cdecl(\"==\")"), "must not emit raw operator @_cdecl")
        XCTAssertFalse(emitted.source.contains("struct ==_Args"), "must not emit invalid struct name")
        XCTAssertFalse(emitted.fileName.contains("=="), "file name must be sanitized: \(emitted.fileName)")
        XCTAssertTrue(emitted.source.contains("op_eqeq"), "must use the sanitized symbol")
        // The REAL operator is invoked inside (infix), not a labelled member call.
        XCTAssertTrue(emitted.source.contains("_args.lhs == _args.rhs"),
                      "must call the real operator infix:\n\(emitted.source)")
        XCTAssertFalse(emitted.source.contains(".==(lhs:"), "must not use the invalid labelled member call")
        // The export symbol the native bridge calls is the sanitized one.
        XCTAssertTrue(emitted.exports.contains("Money_op_eqeq") || emitted.exports.contains { $0.contains("op_eqeq") },
                      "exports: \(emitted.exports)")
    }

    /// A PREFIX operator (`-`) is detected as prefix and emitted as `-x` (not the
    /// invalid `Type.-(...)` form), with a sanitized symbol.
    func testPrefixOperatorExportEmitsPrefixCall() {
        let scanned = PureExportScanner().scan(source: """
        struct V: Equatable {
            let x: Int
            static prefix func - (v: V) -> V { V(x: -v.x) }
        }
        """, eligibleSimpleNames: ["-"])
        guard let op = scanned.first(where: { $0.operatorToken == "-" }) else {
            return XCTFail("prefix operator export not produced")
        }
        XCTAssertEqual(op.operatorFixity, .prefix)
        let emitted = CodeEmitter().emitFoundationPureExportFilePublic(op, includeAllocator: true)
        XCTAssertTrue(emitted.source.contains("op_minus"))
        XCTAssertTrue(emitted.source.contains("-_args.v") || emitted.source.contains("- _args.v")
                      || emitted.source.contains("-_args."), "prefix call form:\n\(emitted.source)")
        XCTAssertFalse(emitted.source.contains("@_cdecl(\"-\")"))
    }

    /// END-TO-END: an `==` fragment compiles to a REAL `.wasm` (T0, returns Bool) and
    /// round-trips through the host bridge — the headline triage blocker.
    func testOperatorEqEqCompilesToWasmAndRoundTrips() throws {
        // `==` on two Ints is T0-eligible (Int args, Bool return). Use a free-standing
        // logic type so the wrapper's call target resolves in the compile unit.
        let logic = """
        public enum IntEq {
            public static func eq(_ lhs: Int, _ rhs: Int) -> Bool { lhs == rhs }
        }
        """
        // Emulate the scanner's operator export by hand (operatorFixity=infix).
        let op = CodeEmitter.PureExport(
            exportName: "IntEq_op_eqeq", callee: "IntEq.eq",
            parameters: [(label: "_", name: "lhs", type: "Int"), (label: "_", name: "rhs", type: "Int")],
            returnType: "Bool", operatorFixity: .infix, operatorToken: "==")
        let emitted = CodeEmitter().emitPureExportFile(op, includeAllocator: true)
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded)
        XCTAssertTrue(emitted.source.contains("lhs == rhs"), "infix call:\n\(emitted.source)")
        XCTAssertTrue(emitted.exports.contains("IntEq_op_eqeq"))

        let wasm = try compileT0OrSkip(support: logic,
                                       wrapper: (emitted.fileName, emitted.source), exports: emitted.exports)
        let runner = try T0Runner(wasm: wasm)
        struct Args: Encodable { let lhs: Int; let rhs: Int }
        struct Out: Decodable { let value: Int }
        func eq(_ a: Int, _ b: Int) throws -> Int {
            try JSONDecoder().decode(Out.self, from: Data(
                try runner.callPacked("IntEq_op_eqeq", [UInt8](try JSONEncoder().encode(Args(lhs: a, rhs: b)))))).value
        }
        XCTAssertEqual(try eq(3, 3), 1, "3 == 3 → true")
        XCTAssertEqual(try eq(3, 4), 0, "3 == 4 → false")
    }

    /// END-TO-END: a `<` fragment compiles to a REAL `.wasm` and round-trips.
    func testOperatorLessThanCompilesToWasmAndRoundTrips() throws {
        let logic = """
        public enum IntCmp {
            public static func lt(_ lhs: Int, _ rhs: Int) -> Bool { lhs < rhs }
        }
        """
        let op = CodeEmitter.PureExport(
            exportName: "IntCmp_op_lt", callee: "IntCmp.lt",
            parameters: [(label: "_", name: "lhs", type: "Int"), (label: "_", name: "rhs", type: "Int")],
            returnType: "Bool", operatorFixity: .infix, operatorToken: "<")
        let emitted = CodeEmitter().emitPureExportFile(op, includeAllocator: true)
        XCTAssertTrue(emitted.source.contains("lhs < rhs"))
        let wasm = try compileT0OrSkip(support: logic,
                                       wrapper: (emitted.fileName, emitted.source), exports: emitted.exports)
        let runner = try T0Runner(wasm: wasm)
        struct Args: Encodable { let lhs: Int; let rhs: Int }
        struct Out: Decodable { let value: Int }
        func lt(_ a: Int, _ b: Int) throws -> Int {
            try JSONDecoder().decode(Out.self, from: Data(
                try runner.callPacked("IntCmp_op_lt", [UInt8](try JSONEncoder().encode(Args(lhs: a, rhs: b)))))).value
        }
        XCTAssertEqual(try lt(2, 5), 1)
        XCTAssertEqual(try lt(5, 2), 0)
    }

    // MARK: - Fix C: empty / anonymous fragment name guard

    func testEmptyAndOperatorFileBaseNeverBreaksPaths() {
        // The triage crash: a `/` export produced `/_wasm.swift` → "folder doesn't
        // exist". Sanitized base must be a plain identifier (no `/`, never empty).
        XCTAssertEqual(CodeEmitter.sanitizedFileBase(""), "_anon")
        XCTAssertEqual(CodeEmitter.sanitizedFileBase("/"), "op_slash")
        for raw in ["", "/", "==", "+", "*", "  "] {
            let base = CodeEmitter.sanitizedFileBase(raw)
            XCTAssertFalse(base.isEmpty, "base for '\(raw)' must not be empty")
            XCTAssertFalse(base.contains("/"), "base for '\(raw)' must not contain a path separator: \(base)")
            XCTAssertNotEqual(base + "_wasm.swift", "_wasm.swift", "must not be a bare _wasm.swift")
        }
    }

    /// A mixed-function plan with an empty/operator original name still emits files
    /// with safe names (no bare `_wasm.swift`, no `/`), so codegen never crashes and
    /// the app's other fragments still emit (YPImagePicker / lottie-ios fix).
    func testEmptyNamedPlanEmitsSafeFileNames() {
        let frag = SplitPlan.PureFragment(
            name: "_sp_anon_prepare",
            inputs: [(name: "a", type: "Int")],
            outputs: [(name: "r", type: "Int")],
            bodyStatements: ["return a + 1"])
        // originalSimpleName = "" (anonymous) — the Fix C case.
        let plan = SplitPlan(originalID: "M.anon", originalSimpleName: "",
                             pureFragments: [frag], nativeSignature: "",
                             originalParameters: [(name: "a", type: "Int")], returnType: "Int",
                             shellSteps: [.fragmentCall(fragment: frag), .nativeStatement("return r")])
        let files = CodeEmitter().emit(plan)
        XCTAssertEqual(files.wasmFileName, "_anon_wasm.swift")
        XCTAssertEqual(files.bridgeFileName, "_anon_bridge.swift")
        XCTAssertFalse(files.wasmFileName.contains("/"))
        // And an OPERATOR original name.
        let planOp = SplitPlan(originalID: "M.==", originalSimpleName: "==",
                               pureFragments: [frag], nativeSignature: "",
                               originalParameters: [(name: "a", type: "Int")], returnType: "Int",
                               shellSteps: [.fragmentCall(fragment: frag), .nativeStatement("return r")])
        let filesOp = CodeEmitter().emit(planOp)
        XCTAssertEqual(filesOp.wasmFileName, "op_eqeq_wasm.swift")
        XCTAssertTrue(filesOp.bridgeSource.contains("enum Op_eqeqBridge"),
                      "bridge type name must be a valid identifier:\n\(filesOp.bridgeSource.prefix(400))")
    }

    // MARK: - Fix D: T0 host-bridge helpers emitted unconditionally

    func testT0HelpersEmittedRegardlessOfAllocator() {
        let export = CodeEmitter.PureExport(
            exportName: "second", callee: "Logic.second",
            parameters: [(label: "_", name: "x", type: "Int")], returnType: "Int")
        // includeAllocator:false simulates the 2nd+ T0 export in a module.
        guard let emitted = CodeEmitter().emitEmbeddedPureExportFile(export, includeAllocator: false) else {
            return XCTFail("scalar export should take the T0 path")
        }
        XCTAssertTrue(emitted.source.contains("_patchReadArgs"),
                      "T0 helper _patchReadArgs must be emitted even when includeAllocator:false")
        XCTAssertTrue(emitted.source.contains("_patchEncodeResult"))
        // The allocator (@_cdecl) stays once-per-module → NOT in a non-first file.
        XCTAssertFalse(emitted.source.contains("patch_malloc"),
                       "the @_cdecl allocator must remain once-per-module")
        // And the helpers are `private` so two files can each carry them.
        XCTAssertTrue(emitted.source.contains("private func _patchReadArgs"))
    }

    /// END-TO-END: TWO T0 exports in ONE module (the 2nd with includeAllocator:false)
    /// both compile — proving the helpers resolve in every T0 file (no `cannot find
    /// '_patchReadArgs' in scope`).
    func testTwoT0ExportsCompileInOneModule() throws {
        let logic = """
        public enum Logic {
            public static func first(_ x: Int) -> Int { x * 2 }
            public static func second(_ x: Int) -> Int { x + 100 }
        }
        """
        let e1 = CodeEmitter.PureExport(exportName: "first", callee: "Logic.first",
            parameters: [(label: "_", name: "x", type: "Int")], returnType: "Int")
        let e2 = CodeEmitter.PureExport(exportName: "second", callee: "Logic.second",
            parameters: [(label: "_", name: "x", type: "Int")], returnType: "Int")
        let w1 = CodeEmitter().emitEmbeddedPureExportFile(e1, includeAllocator: true)!  // first → allocator
        let w2 = CodeEmitter().emitEmbeddedPureExportFile(e2, includeAllocator: false)! // second → no allocator
        let exports = Array(Set(w1.exports + w2.exports))
        let wasm = try compileT0MultiOrSkip(
            support: logic,
            wrappers: [(w1.fileName, w1.source), (w2.fileName, w2.source)],
            exports: exports)
        let runner = try T0Runner(wasm: wasm)
        struct Args: Encodable { let x: Int }
        struct Out: Decodable { let value: Int }
        func call(_ name: String, _ x: Int) throws -> Int {
            try JSONDecoder().decode(Out.self, from: Data(
                try runner.callPacked(name, [UInt8](try JSONEncoder().encode(Args(x: x)))))).value
        }
        XCTAssertEqual(try call("first", 21), 42)
        XCTAssertEqual(try call("second", 5), 105)
    }

    // MARK: - Fix E: non-Codable boundary types

    func testPlainValueTypeGetsCodableSynthesized() {
        let bundler = DependencyClosureBundler()
        let src = """
        struct Point { let x: Int; let y: Int }
        enum Pricing { static func origin() -> Point { Point(x: 0, y: 0) } }
        """
        let idx = bundler.index(for: [fileFor(src)])
        let support = bundler.emitValueTypesSource(types: ["Point"], index: idx, header: "test")
        XCTAssertTrue(support.contains("struct Point: Codable"),
                      "a plain value type must be reconstructed Codable:\n\(support)")
    }

    func testNonCodableBoundaryTypeIsDemotedConservatively() {
        let bundler = DependencyClosureBundler()
        // A struct storing a reference type (class) cannot synthesize Codable → the
        // export's closure must be rejected (kept native), not shipped broken.
        let src = """
        final class Session {}
        struct Wrapper { let s: Session; let n: Int }
        enum API { static func make(_ w: Wrapper) -> Int { w.n } }
        """
        let idx = bundler.index(for: [fileFor(src)])
        let clo = bundler.closure(exportName: "make", callee: "API.make",
                                  signatureTypes: ["Wrapper"], index: idx)
        XCTAssertFalse(clo.shippable, "a non-Codable boundary must be demoted, not shipped")
        XCTAssertNotNil(clo.rejectionReason)
    }

    // MARK: - Fix B: test code excluded from OTA eligibility

    func testIsTestFileDetectsPathAndContent() {
        func u(_ p: String) -> URL { URL(fileURLWithPath: p) }
        // Path-based.
        XCTAssertTrue(SwiftParserEngine.isTestFile(u("/app/Tests/FooTests.swift")))
        XCTAssertTrue(SwiftParserEngine.isTestFile(u("/app/UITests/Flow.swift")))
        XCTAssertTrue(SwiftParserEngine.isTestFile(u("/app/Sources/PricingTests.swift")))
        XCTAssertTrue(SwiftParserEngine.isTestFile(u("/app/MySpec.swift")))
        // Production paths are NOT test files.
        XCTAssertFalse(SwiftParserEngine.isTestFile(u("/app/Sources/Pricing.swift")))
        XCTAssertFalse(SwiftParserEngine.isTestFile(u("/app/Sources/Contestant.swift")))
        // Content-based.
        XCTAssertTrue(SwiftParserEngine.sourceLooksLikeTest("import XCTest\nclass T: XCTestCase {}"))
        XCTAssertTrue(SwiftParserEngine.sourceLooksLikeTest("import Testing\n@Test func f() { #expect(true) }"))
        XCTAssertTrue(SwiftParserEngine.sourceLooksLikeTest("let app = XCUIApplication()"))
        XCTAssertFalse(SwiftParserEngine.sourceLooksLikeTest("import Foundation\nfunc add(_ a: Int) -> Int { a }"))
    }

    /// A test target's symbols never reach OTA eligibility: the file enumeration
    /// (used by analysis + codegen) skips them, so the engine never tries to ship
    /// un-bundlable XCTest/swift-testing symbols.
    func testTestFilesExcludedFromAnalysis() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cgr-tx-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources")
        let tests = root.appendingPathComponent("Tests")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "enum Pricing { static func total(_ a: Int) -> Int { a + 1 } }"
            .write(to: sources.appendingPathComponent("Pricing.swift"), atomically: true, encoding: .utf8)
        try "import XCTest\nfinal class PricingTests: XCTestCase { func testTotal() { _ = 1 } }"
            .write(to: tests.appendingPathComponent("PricingTests.swift"), atomically: true, encoding: .utf8)
        let files = try SwiftParserEngine.swiftFiles(in: root)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "Pricing.swift" })
        XCTAssertFalse(files.contains { $0.lastPathComponent == "PricingTests.swift" },
                       "test file must be excluded; got \(files.map { $0.lastPathComponent })")
        // The analyzed report must NOT contain the test class's symbols.
        let report = try PartitioningEngine().analyze(directory: root)
        XCTAssertFalse(report.records.keys.contains { $0.contains("testTotal") },
                       "test symbols must never enter the coverage report")
    }

    // MARK: - helpers

    private func fileFor(_ source: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("cgr-src-\(UUID().uuidString).swift")
        try? source.write(to: u, atomically: true, encoding: .utf8)
        return u
    }
}
