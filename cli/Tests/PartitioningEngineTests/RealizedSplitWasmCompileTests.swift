// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftParser
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// optimization-sweep verification: the NEW concrete fragments the extended
/// splitter realizes (cross-statement-threaded + switch/branch value lifts) really
/// compile to a `.wasm` module via the swift.org SDK. Skipped when the toolchain
/// is absent so the suite stays green everywhere.
final class RealizedSplitWasmCompileTests: XCTestCase {
    private func realWasmCompile(_ wasmSource: String, exports: [String], label: String) throws {
        let compiler = SwiftWasmCompiler()
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping real compile")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rs-\(UUID().uuidString)")
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

    private func emit(_ source: String, nativeCallees: Set<String> = []) -> CodeEmitter.EmittedFiles? {
        let recs = SwiftParserEngine().parse(source: source, file: URL(fileURLWithPath: "/tmp/x.swift"))
        guard let r = recs.first(where: { $0.id.contains("S.run") }),
              let plan = FunctionSplitter(nativeCalleeNames: nativeCallees).plan(for: r, source: source)
        else { return nil }
        return CodeEmitter().emit(plan)
    }

    /// Emit the split for a member whose id ENDS with `idSuffix` (host-projection
    /// targets are computed properties / methods, not `S.run`).
    private func emitMember(_ source: String, _ idSuffix: String) -> CodeEmitter.EmittedFiles? {
        let recs = SwiftParserEngine().parse(source: source, file: URL(fileURLWithPath: "/tmp/x.swift"))
        guard let r = recs.first(where: { $0.id.hasSuffix("." + idSuffix) }),
              let plan = FunctionSplitter().plan(for: r, source: source)
        else { return nil }
        return CodeEmitter().emit(plan)
    }

    /// Cross-statement-threaded fragment: `let a = items.count; let b = a+1; let c = b*2`
    /// now types `c: Int` concretely → ABI-eligible → compiles to wasm.
    func testThreadedArithmeticFragmentCompilesToWasm() throws {
        let source = """
        import Foundation
        struct S {
            func run(_ items: [Int], _ path: String) {
                let a = items.count
                let b = a + 1
                let c = b * 2
                FileManager.default.createFile(atPath: path, contents: Data(count: c))
            }
        }
        """
        guard let files = emit(source) else { return XCTFail("no plan") }
        XCTAssertTrue(files.exportSymbols.contains("_sp_run_prepare"),
                      "threaded fragment must be a real export. Exports: \(files.exportSymbols)")
        try realWasmCompile(files.wasmSource, exports: files.exportSymbols, label: "threaded-arith")
    }

    /// Switch-arm value lift: `let factor = switch tier { case 0:1; default:3 }` now
    /// types `factor: Int` concretely (arm-type inference) → ABI-eligible → compiles.
    func testSwitchValueFragmentCompilesToWasm() throws {
        let source = """
        import Foundation
        struct S {
            func run(_ tier: Int, _ path: String) -> Int {
                let factor = switch tier {
                case 0: 1
                case 1: 2
                default: 3
                }
                let leaked = capturedHelper(factor)
                FileManager.default.createFile(atPath: path, contents: Data(count: factor))
                return leaked
            }
        }
        """
        guard let files = emit(source, nativeCallees: ["capturedHelper"]) else { return XCTFail("no plan") }
        XCTAssertTrue(files.exportSymbols.contains { $0.hasPrefix("_sp_run_") },
                      "switch fragment must be a real export. Exports: \(files.exportSymbols)")
        XCTAssertFalse(files.wasmSource.contains("capturedHelper"),
                       "ZERO-FALSE-NEGATIVE: native callee must never enter WASM")
        try realWasmCompile(files.wasmSource, exports: files.exportSymbols, label: "switch-value")
    }

    /// Host-projected reactive read: a pure value member of an @Observable type that
    /// reads scalar/String reactive props is lifted into a fragment whose inputs are
    /// the PROJECTED reads (`self.<prop>` rewritten to the parameter). The fragment
    /// must compile to a real `.wasm` module — the demote-safety ground truth.
    func testHostProjectedReactiveReadFragmentCompilesToWasm() throws {
        let source = """
        import Foundation
        final class VM: ObservableObject {
            @Published var counter: Int = 0
            @Published var name: String = ""
            var summary: String { "\\(name): \\(counter * 2)" }
        }
        """
        guard let files = emitMember(source, "summary") else { return XCTFail("no host-projection plan") }
        XCTAssertTrue(files.exportSymbols.contains { $0.hasPrefix("_sp_summary_") },
                      "host-projected fragment must be a real export. Exports: \(files.exportSymbols)")
        // The lifted fragment must reference the PROJECTED parameters, never `self`.
        XCTAssertFalse(files.wasmSource.contains("self."),
                       "ZERO-FALSE-NEGATIVE: the host-projected fragment must be self-free")
        try realWasmCompile(files.wasmSource, exports: files.exportSymbols, label: "host-projection")
    }
}
