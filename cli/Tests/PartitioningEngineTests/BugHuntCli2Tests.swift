// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// Minimal WasmKit host runner for the T0 (ptr,len)+packed-i64 ABI, providing the
/// full `patch_host` bridge surface — mirrors T0EmbeddedCodegenTests.T0Runner.
private final class T0UnsignedRunner {
    let store: Store
    let instance: Instance
    let wasi: WASIBridgeToHost
    init(wasm: [UInt8]) throws {
        let engine = Engine()
        self.store = Store(engine: engine)
        self.wasi = try WASIBridgeToHost()
        var imports = Imports()
        wasi.link(to: &imports, store: store)
        PatchHostTestImports.register(into: &imports, store: store)
        let module = try parseWasm(bytes: wasm)
        self.instance = try module.instantiate(store: store, imports: imports)
        try wasi.initialize(instance)
    }
    func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
        guard let mem = instance.exports[memory: "memory"],
              let malloc = instance.exports[function: "patch_malloc"],
              let fn = instance.exports[function: name] else {
            throw NSError(domain: "t0u", code: 1)
        }
        let inPtr = try malloc([.i32(UInt32(input.count))])[0].i32
        mem.withUnsafeMutableBufferPointer(offset: UInt(inPtr), count: input.count) { $0.copyBytes(from: input) }
        let packed = try fn([.i32(inPtr), .i32(UInt32(input.count))])[0].i64
        let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
        let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
        let all = mem.data
        return [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
    }
}

/// Regression tests for the second CLI/engine bug-hunt pass. Each test FAILS on the
/// pre-fix code and PASSES after the surgical fix. See /tmp/bughunt_cli2_progress.md.
final class BugHuntCli2Tests: XCTestCase {

    // MARK: - BUG 1 (P1): T0 unsigned-integer return must not trap at runtime

    /// A `UInt64`-returning function is T0-eligible. The old codegen encoded the
    /// result with `Int64(_result)`, which TRAPS for any value > Int64.max — the
    /// module ships then crashes at runtime. The fix routes unsigned returns through
    /// the dedicated `UInt64` overload (no `Int64(...)` conversion in the call path).
    func testT0UnsignedReturnDoesNotEmitTrappingInt64Conversion() {
        let export = CodeEmitter.PureExport(
            exportName: "bitmask", callee: "Bits.bitmask",
            parameters: [(label: "_", name: "n", type: "Int")],
            returnType: "UInt64")
        guard let t0 = CodeEmitter().emitEmbeddedPureExportFile(export, includeAllocator: true) else {
            return XCTFail("a UInt64-return scalar function must take the T0 (embedded) path")
        }
        // The crash bug: encoding the result via `Int64(_result)` traps for
        // UInt64 > Int64.max. The fixed path uses the UInt64 overload instead.
        XCTAssertFalse(t0.source.contains("_patchEncodeResult(Int64(_result))"),
                       "unsigned return must NOT be funneled through Int64(_result) (traps > Int64.max)\n\(t0.source)")
        XCTAssertTrue(t0.source.contains("_patchEncodeResult(UInt64(_result))"),
                      "unsigned return must use the UInt64 encode overload\n\(t0.source)")
        // And the UInt64 overload must actually be emitted into the file.
        XCTAssertTrue(t0.source.contains("_patchEncodeResult(_ value: UInt64)"),
                      "the UInt64 encode overload must be present in the T0 helpers\n\(t0.source)")
    }

    /// Signed integer returns are unchanged (still the Int64 path) — the fix is
    /// narrowly scoped to the unsigned types only.
    func testT0SignedReturnStillUsesInt64Path() {
        let export = CodeEmitter.PureExport(
            exportName: "total", callee: "Calc.total",
            parameters: [(label: "_", name: "n", type: "Int")],
            returnType: "Int")
        guard let t0 = CodeEmitter().emitEmbeddedPureExportFile(export, includeAllocator: true) else {
            return XCTFail("an Int-return scalar function must take the T0 path")
        }
        XCTAssertTrue(t0.source.contains("_patchEncodeResult(Int64(_result))"),
                      "signed return path must be unchanged\n\(t0.source)")
    }

    /// END-TO-END proof: a `UInt64`-returning function whose value exceeds
    /// Int64.max round-trips correctly through the T0 module instead of TRAPPING.
    /// The pre-fix `Int64(_result)` would crash the module at runtime; the fixed
    /// UInt64 overload encodes the true magnitude. Skipped without the WASM toolchain.
    func testT0UnsignedReturnRoundTripsBeyondInt64Max() throws {
        let compiler = SwiftWasmCompiler(exportedSymbols: ["bigMask", "patch_malloc", "patch_free"],
                                         tier: .t0Embedded)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping T0 unsigned round-trip")

        // Logic returns a value > Int64.max (which `Int64(_result)` would trap on).
        let logic = """
        public enum Bits {
            public static func bigMask(_ shift: Int) -> UInt64 {
                return UInt64.max >> UInt64(shift)   // shift 0 → UInt64.max (> Int64.max)
            }
        }
        """
        let export = CodeEmitter.PureExport(
            exportName: "bigMask", callee: "Bits.bigMask",
            parameters: [(label: "_", name: "shift", type: "Int")],
            returnType: "UInt64")
        guard let emitted = CodeEmitter().emitEmbeddedPureExportFile(export, includeAllocator: true) else {
            return XCTFail("UInt64 return must take the T0 path")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("t0u-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let supportURL = tmp.appendingPathComponent("Logic.swift")
        try logic.write(to: supportURL, atomically: true, encoding: .utf8)
        let wrapperURL = tmp.appendingPathComponent(emitted.fileName)
        try emitted.source.write(to: wrapperURL, atomically: true, encoding: .utf8)
        let out = tmp.appendingPathComponent("module.wasm")
        let result = try compiler.compile(sources: [supportURL, wrapperURL], outputModule: out)
        XCTAssertEqual(result.status, .success, "T0 unsigned-return compile failed:\n\(result.log)")

        // The generated JSON `{"value":18446744073709551615}` (UInt64.max) must
        // decode losslessly — proving no Int64 truncation/trap happened.
        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try T0UnsignedRunner(wasm: wasm)
        struct Args: Encodable { let shift: Int }
        struct Out: Decodable { let value: UInt64 }
        let bytes = try runner.callPacked("bigMask", [UInt8](try JSONEncoder().encode(Args(shift: 0))))
        let decoded = try JSONDecoder().decode(Out.self, from: Data(bytes))
        XCTAssertEqual(decoded.value, UInt64.max,
                       "UInt64.max (> Int64.max) must round-trip without trapping/truncating")
    }

    // MARK: - BUG 2 (P1): convergence must not demote a candidate via substring match

    /// A diagnostic line referencing `foofoo_wasm.swift` must NOT be read as blaming
    /// `foo_wasm.swift` (a substring). The whole-path-component matcher prevents a
    /// healthy OTA unit from being demoted because its filename is a substring of the
    /// real culprit's.
    func testLineBlamesFileRejectsSubstringFilenames() {
        let errLine = Substring("/build/foofoo_wasm.swift:3:5: error: boom")
        XCTAssertTrue(WasmConvergence.lineBlamesFile(errLine, "foofoo_wasm.swift"),
                      "the real culprit must be blamed")
        XCTAssertFalse(WasmConvergence.lineBlamesFile(errLine, "foo_wasm.swift"),
                       "a SUBSTRING filename must NOT be blamed (would demote a healthy unit)")
        // Boundary cases: a leading-substring name and an embedded name.
        let err2 = Substring("/x/Xa_wasm.swift:1:1: error: e")
        XCTAssertFalse(WasmConvergence.lineBlamesFile(err2, "a_wasm.swift"),
                       "`a_wasm.swift` is a substring of `Xa_wasm.swift` — must NOT match")
        XCTAssertTrue(WasmConvergence.lineBlamesFile(err2, "Xa_wasm.swift"))
    }

    /// End-to-end: with a candidate whose name is a SUBSTRING of the failing
    /// candidate, only the genuine culprit is demoted — the substring-named healthy
    /// candidate still ships.
    func testConvergenceDemotesOnlyTrueCulpritNotSubstringSibling() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-sub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // `foo_wasm.swift` is healthy; `foofoo_wasm.swift` is the culprit. The
        // culprit's name CONTAINS the healthy one's basename as a substring.
        let healthy = tmp.appendingPathComponent("foo_wasm.swift")
        let culprit = tmp.appendingPathComponent("foofoo_wasm.swift")
        try "func a() {}".write(to: healthy, atomically: true, encoding: .utf8)
        try "func b() {}".write(to: culprit, atomically: true, encoding: .utf8)

        let convergence = WasmConvergence(compiler: SubstringScriptedCompiler(failing: "foofoo_wasm.swift"))
        let outcome = try convergence.converge(
            [
                .init(functionID: "foo", sourceFile: healthy, exports: ["a"]),
                .init(functionID: "foofoo", sourceFile: culprit, exports: ["b"]),
            ],
            outputModule: tmp.appendingPathComponent("out.wasm"))

        XCTAssertEqual(outcome.compiled.map { $0.functionID }, ["foo"],
                       "the healthy substring-named candidate must still ship")
        XCTAssertEqual(outcome.reclassifiedNative.map { $0.functionID }, ["foofoo"],
                       "only the genuine culprit must be demoted")
    }

    // MARK: - BUG 3 (P2): FusionRewriter must not rewrite inside string literals / comments

    func testFusionDoesNotRewriteInsideStringLiteral() {
        let src = #"""
        func describe() -> String {
            // a real call below
            let id = Locale.current.identifier
            let note = "uses Locale.current.identifier as the key"
            return id + note
        }
        """#
        let result = FusionRewriter().rewrite(src)
        // The real CODE call IS rewritten…
        XCTAssertTrue(result.source.contains("let id = _patchFusionLocaleIdentifier()"),
                      "the genuine code call must still be bridged\n\(result.source)")
        // …but the STRING LITERAL value must be left verbatim (no corruption).
        XCTAssertTrue(result.source.contains(#""uses Locale.current.identifier as the key""#),
                      "a string-literal value must NOT be rewritten\n\(result.source)")
        XCTAssertFalse(result.source.contains(#""uses _patchFusionLocaleIdentifier()"#),
                       "string-literal content was corrupted by the rewrite\n\(result.source)")
    }

    func testFusionDoesNotRewriteInsideLineComment() {
        let src = """
        func f() {
            // TODO: replace UserDefaults.standard.string(forKey: "k") later
            let v = UserDefaults.standard.string(forKey: "k")
            _ = v
        }
        """
        let result = FusionRewriter().rewrite(src)
        XCTAssertTrue(result.source.contains(#"let v = _patchFusionDefaultsGetString("k")"#),
                      "the real call must be bridged\n\(result.source)")
        XCTAssertTrue(result.source.contains(#"// TODO: replace UserDefaults.standard.string(forKey: "k") later"#),
                      "a comment must NOT be rewritten\n\(result.source)")
    }

    /// The codeMask helper itself: code regions are true, string/comment regions false.
    func testFusionCodeMaskMarksStringsAndComments() {
        let s = #"let a = "x" // y"#  // positions: code, then "x" string, then // y comment
        let mask = FusionRewriter.codeMask(s)
        let u = Array(s.utf16)
        let quoteIdx = u.firstIndex(of: 0x22)!          // first "
        XCTAssertFalse(mask[quoteIdx], "opening quote is inside the string region")
        // The 'x' between the quotes is masked out.
        XCTAssertFalse(mask[quoteIdx + 1], "string content must be masked")
        // The leading `let` is code.
        XCTAssertTrue(mask[0], "leading code must be unmasked")
        // The `// y` comment tail is masked out.
        let commentSlash = u.lastIndex(of: 0x2F)!       // last '/'
        XCTAssertFalse(mask[commentSlash], "comment must be masked")
    }

    // MARK: - BUG 4 (P1): fingerprint exclude must not over-match sibling files

    func testExcludeMatchesAnchorsOnPathSegmentBoundary() {
        // A bare prefix `Generated` must NOT exclude a sibling file `GeneratedHelpers.swift`.
        XCTAssertFalse(
            ProjectFingerprinter.excludeMatches(
                "Generated", relativePath: "GeneratedHelpers.swift", fileName: "GeneratedHelpers.swift"),
            "a directory-style exclude must not drop a sibling file with the same prefix")
        // It DOES exclude the directory's contents.
        XCTAssertTrue(
            ProjectFingerprinter.excludeMatches(
                "Generated", relativePath: "Generated/Stub.swift", fileName: "Stub.swift"),
            "a directory exclude must drop files inside that directory")
        // Trailing-slash directory entry works the same.
        XCTAssertTrue(
            ProjectFingerprinter.excludeMatches(
                "Sources/Generated/", relativePath: "Sources/Generated/X.swift", fileName: "X.swift"))
        XCTAssertFalse(
            ProjectFingerprinter.excludeMatches(
                "Sources/Generated/", relativePath: "Sources/Generated2/X.swift", fileName: "X.swift"),
            "must not match a differently-named sibling directory")
        // Exact relative path + bare filename still match.
        XCTAssertTrue(ProjectFingerprinter.excludeMatches(
            "Sources/App/AppDelegate.swift", relativePath: "Sources/App/AppDelegate.swift", fileName: "AppDelegate.swift"))
        XCTAssertTrue(ProjectFingerprinter.excludeMatches(
            "AppDelegate.swift", relativePath: "Sources/App/AppDelegate.swift", fileName: "AppDelegate.swift"))
    }

    /// End-to-end: with exclude `Generated`, a sibling file `GeneratedHelpers.swift`
    /// must STAY in the native fingerprint, so changing it CHANGES the fingerprint
    /// (the OTA-compatibility gate still protects users from an incompatible push).
    func testSiblingFileStaysInFingerprintWhenDirExcluded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fp-excl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sibling = dir.appendingPathComponent("GeneratedHelpers.swift")
        try "struct A { let x = 1 }".write(to: sibling, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Generated"), withIntermediateDirectories: true)
        try "struct G {}".write(
            to: dir.appendingPathComponent("Generated/Stub.swift"), atomically: true, encoding: .utf8)

        let fp = ProjectFingerprinter()
        let before = fp.snapshot(projectDir: dir, bridges: PatchConfig.defaultBridges,
                                 excludes: ["Generated"]).fingerprint
        // Change the SIBLING file (a real native-shell change).
        try "struct A { let x = 2 }".write(to: sibling, atomically: true, encoding: .utf8)
        let after = fp.snapshot(projectDir: dir, bridges: PatchConfig.defaultBridges,
                                excludes: ["Generated"]).fingerprint
        XCTAssertNotEqual(before, after,
                          "changing GeneratedHelpers.swift must change the fingerprint; the exclude `Generated` must NOT drop it")
    }

    // MARK: - BUG 5 (P2): rollback --to must stop when target is unreachable

    func testRollbackStalledDetectsNoProgress() {
        var seen: Set<String> = ["v3"]   // currently active
        // First rollback re-activates v2 (progress).
        XCTAssertFalse(RollbackPlan.stalled(seen: &seen, nowActive: "v2"))
        // Next rollback re-activates v1 (progress).
        XCTAssertFalse(RollbackPlan.stalled(seen: &seen, nowActive: "v1"))
        // A rollback that re-activates an already-seen version = no progress → stall.
        XCTAssertTrue(RollbackPlan.stalled(seen: &seen, nowActive: "v2"),
                      "re-activating an already-rolled-through version signals a cycle / unreachable target")
        // And re-activating the original active is also a stall.
        XCTAssertTrue(RollbackPlan.stalled(seen: &seen, nowActive: "v3"))
    }
}

/// A scripted compiler whose error line names the failing file in the standard
/// `<path>:line:col: error:` Swift-diagnostic form, so the convergence loop's
/// path-component attribution is exercised exactly as in production.
private struct SubstringScriptedCompiler: WasmCompiling {
    let failing: String
    func compile(sources: [URL], outputModule: URL) throws -> WasmCompileResult {
        if let bad = sources.first(where: { $0.lastPathComponent == failing }) {
            return WasmCompileResult(
                status: .failure(reason: "scripted"),
                moduleURL: nil,
                log: "\(bad.path):2:3: error: scripted compile failure\n")
        }
        try? Data().write(to: outputModule)
        return WasmCompileResult(status: .success, moduleURL: outputModule, log: "ok")
    }
}
