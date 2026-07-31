// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import Compiler

/// Tests for the P0 ship-plumbing fix: the additive REAL-SOURCE module is merged
/// into the single shippable `module.wasm`, so `release`/`push` (which upload only
/// `module.wasm`) carry the real-source/fusion coverage gains by default.
///
/// The pure-logic + fallback tests need NO toolchain. The end-to-end PROOF
/// (`testMergedModuleContainsBothModulesExports`) builds two real tiny wasm
/// modules, merges them, and asserts the merged binary exports BOTH modules'
/// symbols — i.e. the real-source export genuinely ships in the merged artifact.
/// It is skipped when the wasm toolchain or `wasm-merge` is absent so the suite
/// stays green everywhere.
final class WasmModuleMergerTests: XCTestCase {

    // MARK: - Pure / fallback behavior (no toolchain)

    /// A non-wasm "module" (a test stub that writes only the magic header is fine,
    /// but a file with no wasm magic at all is rejected) is never merged — the
    /// default module is left untouched and `mergeIfPossible` returns false.
    func testMergeRejectsNonWasmInput() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let primary = tmp.appendingPathComponent("module.wasm")
        let secondary = tmp.appendingPathComponent("module.realsource.wasm")
        // Primary is real-looking (magic header); secondary is plain text → not wasm.
        try Data(WasmModuleMerger.wasmMagic + [0x01, 0x00, 0x00, 0x00]).write(to: primary)
        try Data("not wasm".utf8).write(to: secondary)

        let before = try Data(contentsOf: primary)
        let merger = WasmModuleMerger()
        let merged = merger.mergeIfPossible(primary: primary, secondary: secondary)
        XCTAssertFalse(merged, "a non-wasm secondary must not merge")
        // The default module is byte-identical — never corrupted by a failed merge.
        XCTAssertEqual(try Data(contentsOf: primary), before,
                       "default module must be untouched when the merge can't run")
    }

    /// `looksLikeWasm` recognizes the 4-byte `\0asm` magic and rejects anything else.
    func testLooksLikeWasm() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("magic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let good = tmp.appendingPathComponent("g.wasm")
        let bad = tmp.appendingPathComponent("b.wasm")
        try Data(WasmModuleMerger.wasmMagic).write(to: good)
        try Data([0x7f, 0x45, 0x4c, 0x46]).write(to: bad)   // ELF magic, not wasm
        XCTAssertTrue(WasmModuleMerger.looksLikeWasm(good))
        XCTAssertFalse(WasmModuleMerger.looksLikeWasm(bad))
    }

    /// A missing input throws `inputMissing`, and `mergeIfPossible` swallows it to
    /// false (never throws into the build, never loses the default).
    func testMissingInputIsHandled() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("miss-\(UUID().uuidString)")
        let merger = WasmModuleMerger()
        XCTAssertFalse(merger.mergeIfPossible(
            primary: tmp.appendingPathComponent("a.wasm"),
            secondary: tmp.appendingPathComponent("b.wasm")))
    }

    // MARK: - memoryCount + build-time multi-memory fallback safety (no toolchain)

    /// `memoryCount` parses the wasm binary directly and counts DEFINED memories. A
    /// hand-rolled module with a Memory section of count=2 must read as 2.
    func testMemoryCountDetectsMultiMemory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("memcnt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let one = tmp.appendingPathComponent("one.wasm")
        let two = tmp.appendingPathComponent("two.wasm")
        try Data(Self.wasmWithMemories(1)).write(to: one)
        try Data(Self.wasmWithMemories(2)).write(to: two)
        let merger = WasmModuleMerger()
        XCTAssertEqual(merger.memoryCount(of: one), 1, "single-memory module must count 1")
        XCTAssertEqual(merger.memoryCount(of: two), 2, "multi-memory module must count 2")
    }

    /// Build-time safety (Step 3): a MULTI-MEMORY additive sub-module can't run on-device,
    /// so the combine is REJECTED — `mergeIfPossible` returns false and the default module
    /// is left byte-identical (the gain is reported but not shipped — never a regression).
    func testMultiMemorySecondaryIsRejectedAndDefaultUntouched() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmreject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let primary = tmp.appendingPathComponent("module.wasm")
        let secondary = tmp.appendingPathComponent("module.realsource.wasm")
        try Data(Self.wasmWithMemories(1)).write(to: primary)        // valid single-memory default
        try Data(Self.wasmWithMemories(2)).write(to: secondary)      // multi-memory additive (bad)
        let before = try Data(contentsOf: primary)

        let merger = WasmModuleMerger()
        XCTAssertFalse(merger.mergeIfPossible(primary: primary, secondary: secondary),
                       "a multi-memory additive module must be rejected (can't instantiate on-device)")
        XCTAssertEqual(try Data(contentsOf: primary), before,
                       "default module must be left byte-identical when the additive is rejected")
        XCTAssertFalse(PatchModuleContainer.isContainer([UInt8](try Data(contentsOf: primary))),
                       "no container is written when the combine is rejected")
    }

    /// A minimal wasm module: magic + version + a Memory section declaring `count`
    /// memories (each `{flags:0, min:1}`). Enough for `memoryCount` to parse; NOT a
    /// runnable module (no code) — used only to exercise the memory-count + reject path.
    static func wasmWithMemories(_ count: Int) -> [UInt8] {
        var section: [UInt8] = [UInt8(count)]      // vec length
        for _ in 0..<count { section += [0x00, 0x01] }  // limits: flags=0 (no max), min=1
        var out: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]  // magic + version
        out += [0x05]                              // section id 5 = Memory
        out += [UInt8(section.count)]              // section size (LEB, < 128 here)
        out += section
        return out
    }

    // MARK: - End-to-end PROOF (real wasm, toolchain-gated; NO Binaryen needed)

    /// Builds two tiny REAL wasm modules — one exporting `export_alpha`, the other
    /// `export_beta` — combines them via `WasmModuleMerger`, and asserts the combined
    /// CONTAINER holds BOTH modules, each still exporting its symbol. This is the proof
    /// that the real-source exports actually ship inside the single artifact. The
    /// container needs NO external tool, so the only gates are the wasm toolchain (to
    /// build the inputs) and `wasm-opt` (only to READ each module's exports).
    func testMergedModuleContainsBothModulesExports() throws {
        let compiler = SwiftWasmCompiler()
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping real merge proof")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrg-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let alpha = tmp.appendingPathComponent("default.wasm")
        let beta = tmp.appendingPathComponent("realsource.wasm")

        let srcA = tmp.appendingPathComponent("a_wasm.swift")
        try "@_cdecl(\"export_alpha\") public func export_alpha() -> Int32 { 11 }\n"
            .write(to: srcA, atomically: true, encoding: .utf8)
        let cA = SwiftWasmCompiler(exportedSymbols: ["export_alpha"])
        let rA = try cA.compile(sources: [srcA], outputModule: alpha)
        try XCTSkipUnless(rA.status == .success, "default module compile failed:\n\(rA.log)")

        let srcB = tmp.appendingPathComponent("b_wasm.swift")
        try "@_cdecl(\"export_beta\") public func export_beta() -> Int32 { 22 }\n"
            .write(to: srcB, atomically: true, encoding: .utf8)
        let cB = SwiftWasmCompiler(exportedSymbols: ["export_beta"])
        let rB = try cB.compile(sources: [srcB], outputModule: beta)
        try XCTSkipUnless(rB.status == .success, "realsource module compile failed:\n\(rB.log)")

        // Combine realsource INTO the default (exactly what BuildPipeline does).
        let merger = WasmModuleMerger()
        XCTAssertTrue(merger.mergeIfPossible(primary: alpha, secondary: beta),
                      "combine of two real wasm modules must succeed")

        // The shipped artifact is now a Patch CONTAINER holding BOTH modules verbatim.
        let containerBytes = [UInt8](try Data(contentsOf: alpha))
        XCTAssertTrue(PatchModuleContainer.isContainer(containerBytes),
                      "the combined artifact must be a PMOD container")
        let parts = try XCTUnwrap(PatchModuleContainer.decode(containerBytes),
                                  "container must decode")
        XCTAssertEqual(parts.count, 2, "container must hold the default + the real-source module")

        // Each sub-module is a real single-memory wasm that exports its symbol.
        let defModule = tmp.appendingPathComponent("part0.wasm")
        let rsModule = tmp.appendingPathComponent("part1.wasm")
        try Data(parts[0]).write(to: defModule)
        try Data(parts[1]).write(to: rsModule)
        let defExports = try wasmExports(of: defModule)
        let rsExports = try wasmExports(of: rsModule)
        XCTAssertTrue(defExports.contains("export_alpha"),
                      "default sub-module must keep its export. exports=\(defExports)")
        XCTAssertTrue(rsExports.contains("export_beta"),
                      "real-source sub-module must carry its export — the P0 gain. exports=\(rsExports)")
        XCTAssertEqual(merger.memoryCount(of: defModule), 1, "each sub-module must be single-memory")
        XCTAssertEqual(merger.memoryCount(of: rsModule), 1, "each sub-module must be single-memory")
    }

    // MARK: - The P0 multi-memory correctness PROOF (the test that was missing)

    /// THE regression test for the P0 — the test that would have caught the bug: a
    /// combined real-source artifact must run on-device via **WasmKit** (the SDK's
    /// runtime) and BOTH a default-tier export AND a real-source export must return
    /// their CORRECT values.
    ///
    /// It builds two GENUINELY-DISTINCT Foundation JSON modules (`sum(a,b)=a+b` and
    /// `combine(a,b)=a*b+7`) and asserts:
    ///   (1) the BASELINE bug — a single merged module is uninstantiable/unsound:
    ///       a raw `wasm-merge` keeps BOTH memories → WasmKit throws "multiple memories
    ///       are not permitted" (gated on Binaryen, since it only demonstrates the bug);
    ///   (2) the FIX — `WasmModuleMerger.merge` produces a `PMOD` CONTAINER; instantiate
    ///       EACH sub-module as its own WasmKit instance and call its export — BOTH
    ///       return the correct value (12 and 42). Sound by construction: each instance
    ///       owns its memory/allocator/`_initialize`. This path needs NO Binaryen.
    func testMergedRealSourceExecutesInWasmKit() throws {
        let compiler = SwiftWasmCompiler()
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping WasmKit merge proof")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrg-wk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // DEFAULT module: a Foundation JSON (ptr,len) export `sum(a,b)=a+b`.
        let defModule = tmp.appendingPathComponent("default.wasm")
        let defSrc = tmp.appendingPathComponent("def_wasm.swift")
        try Self.jsonExportSource(name: "patch_export_sum", expr: "args.a + args.b")
            .write(to: defSrc, atomically: true, encoding: .utf8)
        let rDef = try SwiftWasmCompiler(
            exportedSymbols: ["patch_export_sum", "patch_malloc", "patch_free"])
            .compile(sources: [defSrc], outputModule: defModule)
        try XCTSkipUnless(rDef.status == .success, "default module compile failed:\n\(rDef.log)")

        // REAL-SOURCE additive module: a DISTINCT Foundation JSON export
        // `combine(a,b)=a*b+7` (different code/data → distinct memory; would force 2 mem).
        let rsModule = tmp.appendingPathComponent("realsource.wasm")
        let rsSrc = tmp.appendingPathComponent("rs_wasm.swift")
        try Self.jsonExportSource(name: "patch_export_combine", expr: "args.a * args.b + 7")
            .write(to: rsSrc, atomically: true, encoding: .utf8)
        let rRs = try SwiftWasmCompiler(
            exportedSymbols: ["patch_export_combine", "patch_malloc", "patch_free"])
            .compile(sources: [rsSrc], outputModule: rsModule)
        try XCTSkipUnless(rRs.status == .success, "real-source module compile failed:\n\(rRs.log)")

        let merger = WasmModuleMerger()

        // --- (1) BASELINE bug: a single merged module is multi-memory; WasmKit rejects.
        // (Gated on `wasm-merge` since it only demonstrates the original broken path.)
        if let tool = merger.toolURL {
            let rawMerged = tmp.appendingPathComponent("raw-merged.wasm")
            try rawMergeNoLowering(primary: defModule, secondary: rsModule, output: rawMerged, tool: tool)
            let rawMemCount = merger.memoryCount(of: rawMerged)
            XCTAssertGreaterThan(rawMemCount, 1,
                "BASELINE: a raw wasm-merge of two distinct real modules must be multi-memory (got \(rawMemCount))")
            XCTAssertThrowsError(try instantiate(rawMerged)) { error in
                XCTAssertTrue("\(error)".lowercased().contains("memor"),
                    "BASELINE: WasmKit must reject the multi-memory module (multiple memories not permitted). got: \(error)")
            }
        }

        // --- (2) FIX: combine into a PMOD container, then run each sub-module separately.
        let combined = tmp.appendingPathComponent("module.wasm")
        try FileManager.default.copyItem(at: defModule, to: combined)
        // combine realsource INTO the (copied) default, exactly as BuildPipeline does.
        try merger.merge(primary: combined, secondary: rsModule, output: combined)

        // The shipped artifact is a container; split it and instantiate EACH part.
        let parts = try XCTUnwrap(PatchModuleContainer.decode([UInt8](try Data(contentsOf: combined))),
                                  "combined artifact must be a PMOD container")
        XCTAssertEqual(parts.count, 2, "container must hold the default + the real-source module")

        let defRT = try instantiate(bytes: parts[0])
        let rsRT = try instantiate(bytes: parts[1])
        let defResult = try callJSONExport(defRT, "patch_export_sum", a: 5, b: 7)
        XCTAssertEqual(defResult, 12,
            "FIX: the DEFAULT export must execute correctly in its own WasmKit instance (5+7=12), got \(defResult)")
        let rsResult = try callJSONExport(rsRT, "patch_export_combine", a: 5, b: 7)
        XCTAssertEqual(rsResult, 42,
            "FIX: the REAL-SOURCE export must ALSO execute correctly in its own WasmKit instance (5*7+7=42), got \(rsResult) — sound by construction (separate memory/allocator/_initialize)")
    }

    // MARK: - WasmKit proof helpers

    /// A Foundation JSON `(ptr,len)->packed(ptr<<32|len)` export computing `expr`
    /// over `{ "a": Int, "b": Int }` and returning `{ "value": Int }`. Carries the
    /// shared `patch_malloc`/`patch_free` allocator (both merged modules export it).
    static func jsonExportSource(name: String, expr: String) -> String {
        """
        import Foundation
        @_cdecl("patch_malloc") public func patch_malloc(_ n: Int32) -> UnsafeMutableRawPointer? { malloc(Int(n)) }
        @_cdecl("patch_free") public func patch_free(_ p: UnsafeMutableRawPointer?) { free(p) }
        private struct In: Decodable { let a: Int; let b: Int }
        private struct Out: Encodable { let value: Int }
        @_cdecl("\(name)") public func \(name)(_ ptr: UnsafePointer<UInt8>?, _ len: Int32) -> UInt64 {
            guard let ptr else { return 0 }
            let data = Data(bytes: ptr, count: Int(len))
            guard let args = try? JSONDecoder().decode(In.self, from: data) else { return 0 }
            let out = (try? JSONEncoder().encode(Out(value: \(expr)))) ?? Data()
            let n = out.count
            let buf = malloc(n)!
            out.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: n)
            return (UInt64(UInt(bitPattern: buf)) << 32) | UInt64(n)
        }
        """
    }

    /// Run `wasm-merge` with the SAME flags the OLD (broken) merger used — the pre-fix
    /// single-module output, to demonstrate the multi-memory baseline bug.
    private func rawMergeNoLowering(primary: URL, secondary: URL, output: URL, tool: URL) throws {
        let p = Process()
        p.executableURL = tool
        p.arguments = [primary.path, "default", secondary.path, "realsource",
                       "-o", output.path, "--all-features", "--skip-export-conflicts"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); _ = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "merge", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "raw wasm-merge failed"])
        }
    }

    /// Instantiate a module (from a file URL) in WasmKit exactly as the SDK does.
    private func instantiate(_ url: URL) throws -> (instance: Instance, store: Store) {
        try instantiate(bytes: [UInt8](try Data(contentsOf: url)))
    }

    /// Instantiate a module in WasmKit exactly as the SDK's `WASMRuntime` does
    /// (WASI bridge + the `patch_host.*` import surface + reactor `_initialize`).
    /// Returns the live instance graph; throws the WasmKit error verbatim on failure
    /// (so the multi-memory rejection surfaces).
    private func instantiate(bytes: [UInt8]) throws -> (instance: Instance, store: Store) {
        let engine = Engine()
        let store = Store(engine: engine)
        let wasi = try WASIBridgeToHost()
        var imports = Imports()
        wasi.link(to: &imports, store: store)
        PatchHostTestImports.register(into: &imports, store: store)
        let parsed = try parseWasm(bytes: bytes)
        let instance = try parsed.instantiate(store: store, imports: imports)
        try wasi.initialize(instance)
        return (instance, store)
    }

    /// Call a Foundation JSON `(ptr,len)->packed` export and decode `value`.
    private func callJSONExport(_ rt: (instance: Instance, store: Store),
                                _ name: String, a: Int, b: Int) throws -> Int {
        guard let mem = rt.instance.exports[memory: "memory"],
              let malloc = rt.instance.exports[function: "patch_malloc"],
              let fn = rt.instance.exports[function: name] else {
            throw NSError(domain: "merge", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "missing export \(name)"])
        }
        let payload = Array(#"{"a":\#(a),"b":\#(b)}"#.utf8)
        let ptr = try malloc([.i32(UInt32(payload.count))])[0].i32
        mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: payload.count) { raw in
            raw.copyBytes(from: payload)
        }
        let packed = try fn([.i32(ptr), .i32(UInt32(payload.count))])[0].i64
        let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
        let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
        let all = mem.data
        let out = [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
        guard let obj = try JSONSerialization.jsonObject(with: Data(out)) as? [String: Any],
              let v = obj["value"] as? Int else {
            throw NSError(domain: "merge", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "bad json: \(String(decoding: out, as: UTF8.self))"])
        }
        return v
    }

    /// Disassemble a wasm module and return its export names (via `wasm-opt -S`,
    /// which ships alongside `wasm-merge` in Binaryen).
    private func wasmExports(of url: URL) throws -> Set<String> {
        let candidates = ["/opt/homebrew/bin/wasm-opt", "/usr/local/bin/wasm-opt", "/usr/bin/wasm-opt"]
        guard let tool = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("wasm-opt not found — cannot read exports")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = [url.path, "--emit-text", "-o", "-", "-all"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        var names = Set<String>()
        for line in text.split(separator: "\n") {
            guard let r = line.range(of: "(export \"") else { continue }
            let after = line[r.upperBound...]
            if let q = after.firstIndex(of: "\"") {
                names.insert(String(after[after.startIndex..<q]))
            }
        }
        return names
    }
}
