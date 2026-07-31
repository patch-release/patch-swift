// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import Compiler

/// Tests for the SAFE `wasm-opt -Oz` finalize pass that shrinks the shippable
/// `module.wasm` (the OTA-size fix). Two layers:
///   - Pure/safety behavior (no toolchain): a non-wasm file is never touched; a
///     missing `wasm-opt` is a clean no-op; the module is never grown.
///   - End-to-end PROOF (toolchain + Binaryen gated): compile a real module, run
///     the optimize pass, assert it SHRANK the module AND the export still executes
///     correctly under WasmKit — i.e. the size win never strips needed code, and the
///     optimized module uses only features the device runtime can instantiate.
final class WasmOptimizerTests: XCTestCase {

    // MARK: - Pure / safety behavior (no toolchain)

    /// A non-wasm file (no `\0asm` magic) is never optimized — left byte-identical,
    /// `optimized == false`.
    func testNonWasmFileIsUntouched() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("opt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("module.wasm")
        try Data("definitely not wasm — should be left alone".utf8).write(to: file)
        let before = try Data(contentsOf: file)

        let outcome = WasmOptimizer().optimizeInPlace(module: file)
        XCTAssertFalse(outcome.optimized, "a non-wasm file must not be optimized")
        XCTAssertEqual(try Data(contentsOf: file), before,
                       "a non-wasm file must be left byte-identical")
    }

    /// A missing module is a clean no-op (never throws, never reports a change).
    func testMissingModuleIsNoOp() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("optmiss-\(UUID().uuidString)")
        let outcome = WasmOptimizer().optimizeInPlace(module: tmp.appendingPathComponent("nope.wasm"))
        XCTAssertFalse(outcome.optimized)
        XCTAssertEqual(outcome.beforeBytes, 0)
        XCTAssertEqual(outcome.afterBytes, 0)
    }

    /// When `wasm-opt` is unavailable (no candidate path exists), the pass is a
    /// no-op and the module is untouched — never a regression on a machine without
    /// Binaryen.
    func testNoToolIsNoOp() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("optnotool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("module.wasm")
        // A real wasm magic header, but point the optimizer at a non-existent tool.
        try Data(WasmOptimizer.wasmMagic + [0x01, 0x00, 0x00, 0x00]).write(to: file)
        let before = try Data(contentsOf: file)

        let opt = WasmOptimizer(candidatePaths: [tmp.appendingPathComponent("no-such-wasm-opt")])
        XCTAssertFalse(opt.isAvailable)
        let outcome = opt.optimizeInPlace(module: file)
        XCTAssertFalse(outcome.optimized)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    // MARK: - End-to-end PROOF (real wasm, toolchain + wasm-opt gated)

    /// Build a real JSON-(ptr,len) ABI module, run the optimize pass, and assert:
    ///   (1) the module SHRANK (the size win is real),
    ///   (2) the export still returns the CORRECT value through WasmKit (the size
    ///       win preserves behavior AND uses only runtime-instantiable features).
    func testOptimizePreservesCorrectnessAndShrinks() throws {
        let compiler = SwiftWasmCompiler()
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping optimize proof")
        let optimizer = WasmOptimizer()
        try XCTSkipUnless(optimizer.isAvailable,
                          "wasm-opt (Binaryen) not installed — skipping optimize proof")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("opt-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A pure Foundation JSON (ptr,len) export: sum two ints. This carries the
        // full Foundation JSON envelope (the real-source wrapper shape), so the
        // optimize pass operates on a representative, feature-rich module.
        let src = tmp.appendingPathComponent("sum_wasm.swift")
        try """
        import Foundation
        @_cdecl("patch_malloc") public func patch_malloc(_ n: Int32) -> UnsafeMutableRawPointer? { malloc(Int(n)) }
        @_cdecl("patch_free") public func patch_free(_ p: UnsafeMutableRawPointer?) { free(p) }
        private struct In: Decodable { let a: Int; let b: Int }
        private struct Out: Encodable { let value: Int }
        @_cdecl("patch_export_sum") public func patch_export_sum(_ ptr: UnsafePointer<UInt8>?, _ len: Int32) -> UInt64 {
            guard let ptr else { return 0 }
            let data = Data(bytes: ptr, count: Int(len))
            guard let args = try? JSONDecoder().decode(In.self, from: data) else { return 0 }
            let out = (try? JSONEncoder().encode(Out(value: args.a + args.b))) ?? Data()
            let n = out.count
            let buf = malloc(n)!
            out.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: n)
            return (UInt64(UInt(bitPattern: buf)) << 32) | UInt64(n)
        }
        """.write(to: src, atomically: true, encoding: .utf8)

        let module = tmp.appendingPathComponent("module.wasm")
        let c = SwiftWasmCompiler(exportedSymbols: ["patch_export_sum", "patch_malloc", "patch_free"])
        let r = try c.compile(sources: [src], outputModule: module)
        try XCTSkipUnless(r.status == .success, "module compile failed:\n\(r.log)")

        // Correctness BEFORE optimizing (baseline 5+7 = 12).
        XCTAssertEqual(try runSum(module: module, a: 5, b: 7), 12,
                       "baseline module must compute the right sum")

        let beforeSize = (try Data(contentsOf: module)).count
        let outcome = optimizer.optimizeInPlace(module: module)
        XCTAssertTrue(outcome.optimized, "optimize must shrink a real Foundation module")
        let afterSize = (try Data(contentsOf: module)).count
        XCTAssertLessThan(afterSize, beforeSize, "optimized module must be smaller")
        XCTAssertEqual(outcome.beforeBytes, beforeSize)
        XCTAssertEqual(outcome.afterBytes, afterSize)

        // Correctness AFTER optimizing: same export, still instantiates under WasmKit,
        // still returns 12 — the size win stripped no needed code and introduced no
        // feature the device runtime can't handle.
        XCTAssertEqual(try runSum(module: module, a: 5, b: 7), 12,
                       "optimized module must still compute the right sum under WasmKit")
    }

    /// CONTAINER size pass: build two real modules, combine into a `PMOD` container,
    /// run the optimize pass, and assert it shrank EACH sub-module (so the container is
    /// smaller) while keeping each part single-memory + valid wasm. Prints before/after
    /// sizes (the Step-4 measurement) and proves the size win reaches the container case.
    func testOptimizeShrinksContainerSubModules() throws {
        let compiler = SwiftWasmCompiler()
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping container size proof")
        let optimizer = WasmOptimizer()
        try XCTSkipUnless(optimizer.isAvailable,
                          "wasm-opt (Binaryen) not installed — skipping container size proof")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("opt-ctr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        func buildJSON(_ name: String, _ expr: String, export: String) throws -> URL {
            let src = tmp.appendingPathComponent("\(name).swift")
            try WasmModuleMergerTests.jsonExportSource(name: export, expr: expr)
                .write(to: src, atomically: true, encoding: .utf8)
            let out = tmp.appendingPathComponent("\(name).wasm")
            let r = try SwiftWasmCompiler(exportedSymbols: [export, "patch_malloc", "patch_free"])
                .compile(sources: [src], outputModule: out)
            try XCTSkipUnless(r.status == .success, "\(name) compile failed:\n\(r.log)")
            return out
        }
        let def = try buildJSON("def", "args.a + args.b", export: "patch_export_sum")
        let rs = try buildJSON("rs", "args.a * args.b + 7", export: "patch_export_combine")

        // Combine into a container exactly as BuildPipeline does.
        let container = tmp.appendingPathComponent("module.wasm")
        try FileManager.default.copyItem(at: def, to: container)
        let merger = WasmModuleMerger()
        try merger.merge(primary: container, secondary: rs, output: container)
        XCTAssertTrue(PatchModuleContainer.isContainer([UInt8](try Data(contentsOf: container))))

        let before = (try Data(contentsOf: container)).count
        let outcome = optimizer.optimizeInPlace(module: container)
        let after = (try Data(contentsOf: container)).count
        XCTAssertTrue(outcome.optimized, "container size pass must shrink the sub-modules")
        XCTAssertLessThan(after, before, "optimized container must be smaller")
        print(String(format: "[SIZE] container %d → %d bytes (%.1f%% smaller via per-sub-module -Oz)",
                     before, after, 100.0 * Double(before - after) / Double(before)))

        // Each sub-module must still be a single-memory wasm AND still execute correctly.
        let parts = try XCTUnwrap(PatchModuleContainer.decode([UInt8](try Data(contentsOf: container))))
        XCTAssertEqual(parts.count, 2)
        for (i, m) in parts.enumerated() {
            let p = tmp.appendingPathComponent("opt-part\(i).wasm")
            try Data(m).write(to: p)
            XCTAssertTrue(WasmOptimizer.looksLikeWasm(m), "sub-module \(i) must stay valid wasm")
            XCTAssertEqual(merger.memoryCount(of: p), 1, "sub-module \(i) must stay single-memory")
        }
        // The DEFAULT export still runs correctly after the container size pass.
        let p0 = tmp.appendingPathComponent("opt-part0.wasm")
        XCTAssertEqual(try runSum(module: p0, a: 5, b: 7), 12,
                       "optimized container sub-module must still compute the right value under WasmKit")
    }

    /// Host-run the `patch_export_sum` JSON (ptr,len) export via WasmKit.
    private func runSum(module: URL, a: Int, b: Int) throws -> Int {
        let bytes = [UInt8](try Data(contentsOf: module))
        let engine = Engine()
        let store = Store(engine: engine)
        let wasi = try WASIBridgeToHost()
        var imports = Imports()
        wasi.link(to: &imports, store: store)
        // The Foundation module's CHost bridge declares the full `patch_host.*`
        // import surface (decimal/json/date), so satisfy it exactly as the SDK's
        // FoundationBridge does — even though this export uses only in-module JSON.
        PatchHostTestImports.register(into: &imports, store: store)
        let parsed = try parseWasm(bytes: bytes)
        let instance = try parsed.instantiate(store: store, imports: imports)
        try wasi.initialize(instance)
        guard let mem = instance.exports[memory: "memory"],
              let malloc = instance.exports[function: "patch_malloc"],
              let sum = instance.exports[function: "patch_export_sum"] else {
            throw NSError(domain: "opt", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing export"])
        }
        let payload = Array(#"{"a":\#(a),"b":\#(b)}"#.utf8)
        let ptr = try malloc([.i32(UInt32(payload.count))])[0].i32
        mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: payload.count) { raw in
            raw.copyBytes(from: payload)
        }
        let packed = try sum([.i32(ptr), .i32(UInt32(payload.count))])[0].i64
        let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
        let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
        let all = mem.data
        let out = [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
        guard let obj = try JSONSerialization.jsonObject(with: Data(out)) as? [String: Any],
              let v = obj["value"] as? Int else {
            throw NSError(domain: "opt", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad json: \(String(decoding: out, as: UTF8.self))"])
        }
        return v
    }
}
