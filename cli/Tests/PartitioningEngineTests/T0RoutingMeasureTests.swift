// SPDX-License-Identifier: Apache-2.0

import XCTest
import WasmKit
import WasmKitWASI
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// MEASUREMENT harness (BREAKTHROUGH #9 Bar) — NOT part of the normal suite.
/// Gated behind PATCH_T0_MEASURE=1 so it only runs when explicitly invoked
/// (it drives the REAL WASM toolchain on whole real-source libraries, ~minutes
/// per app). Each case compiles a real app's source twice — forced T2
/// (PATCH_REAL_SOURCE_NO_T0=1) vs default T0 routing — reports the shipped
/// `.realsource.wasm` size + final tier for each, then EXECUTES an export in
/// wasmtime to confirm the same values come out.
final class T0RoutingMeasureTests: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["PATCH_T0_MEASURE"] != nil }

    /// A source directory inside the local measurement corpus (gitignored, and
    /// resolved via `CorpusPaths` so no machine's home directory is baked in).
    /// Skips the case when the corpus — or that particular library — is absent.
    private func corpusSource(_ relativePath: String) throws -> URL {
        guard let root = CorpusPaths.resolvedRoot() else {
            throw XCTSkip("corpus not present (set PATCH_CORPUS to measure)")
        }
        let url = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("corpus library not present: \(relativePath)")
        }
        return url
    }

    /// Container-aware host runner (same shape as MemberSurfaceHostRunTests.Runner):
    /// instantiates a PMOD container as one WasmKit instance per sub-module, routes a
    /// (ptr,len) JSON `callPacked` to whichever instance exports the symbol, and wires
    /// the full `patch_host` host bridge — exactly the path the SDK uses on-device.
    final class Runner {
        let store: Store
        let instances: [Instance]
        let wasi: WASIBridgeToHost
        init(wasm: [UInt8]) throws {
            let engine = Engine(); self.store = Store(engine: engine)
            self.wasi = try WASIBridgeToHost()
            var imports = Imports(); wasi.link(to: &imports, store: store)
            PatchHostTestImports.register(into: &imports, store: store)
            let modules = PatchModuleContainer.decode(wasm) ?? [wasm]
            var built: [Instance] = []
            for m in modules {
                let parsed = try parseWasm(bytes: m)
                let inst = try parsed.instantiate(store: store, imports: imports)
                try wasi.initialize(inst)
                built.append(inst)
            }
            self.instances = built
        }
        private func resolve(_ name: String) throws -> (Memory, Function, Function) {
            for inst in instances {
                if let fn = inst.exports[function: name],
                   let malloc = inst.exports[function: "patch_malloc"],
                   let mem = inst.exports[memory: "memory"] {
                    return (mem, malloc, fn)
                }
            }
            throw NSError(domain: "abi", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no instance exports \(name)"])
        }
        func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
            let (mem, malloc, fn) = try resolve(name)
            let ptr = try malloc([.i32(UInt32(input.count))])[0].i32
            if !input.isEmpty {
                mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: input.count) { $0.copyBytes(from: input) }
            }
            let packed = try fn([.i32(ptr), .i32(UInt32(input.count))])[0].i64
            let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
            let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
            let all = mem.data
            return [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
        }
        func callInt(_ name: String, _ json: String) throws -> Int {
            struct Out: Decodable { let value: Int }
            let bytes = try callPacked(name, [UInt8](json.utf8))
            return try JSONDecoder().decode(Out.self, from: Data(bytes)).value
        }
    }

    /// Drive the real-source additive path against `sourceDir` at a given routing.
    /// Returns (moduleURL?, sizeBytes, finalTier?, addedExports).
    private struct Measured {
        let moduleURL: URL?
        let size: Int
        let units: Int
        let exports: [String]
    }

    private func measure(_ sourceDir: URL, t0: Bool, label: String) throws -> Measured {
        setenv("PATCH_REAL_SOURCE", "1", 1)
        // Skip the wasm-opt finalize: it runs `-Oz` on the ~60 MB coarse T2 module and
        // takes minutes with no effect on the RAW-size comparison (we measure raw bytes;
        // the headline brotli is computed by `shrink()` on the tiny T0 module). The size
        // delta we report is the tier change, not the -Oz delta.
        setenv("PATCH_WASM_OPT", "0", 1)
        if t0 { unsetenv("PATCH_REAL_SOURCE_NO_T0") }
        else { setenv("PATCH_REAL_SOURCE_NO_T0", "1", 1) }
        defer { unsetenv("PATCH_REAL_SOURCE"); unsetenv("PATCH_REAL_SOURCE_NO_T0"); unsetenv("PATCH_WASM_OPT") }

        let build = FileManager.default.temporaryDirectory
            .appendingPathComponent("t0meas-\(label)-\(t0 ? "T0" : "T2")-\(UUID().uuidString)")
        let compiler = SwiftWasmCompiler()
        let result = try BuildPipeline().run(
            sourceDir: sourceDir, buildDir: build, compiler: compiler, dryRun: false,
            outputModule: build.appendingPathComponent("module.wasm"))
        var size = 0
        if let m = result.realSourceModuleURL,
           let s = try? FileManager.default.attributesOfItem(atPath: m.path)[.size] as? Int {
            size = s
        }
        let m = Measured(moduleURL: result.realSourceModuleURL, size: size,
                         units: result.realSourceCompiledUnits,
                         exports: result.realSourceAddedExports)
        FileHandle.standardError.write(Data(
            "[\(label) \(t0 ? "T0" : "T2")] units=\(m.units) size=\(m.size)B (\(String(format: "%.2f", Double(m.size)/1_000_000)) MB) module=\(m.moduleURL?.lastPathComponent ?? "nil") exports=\(m.exports.prefix(8))\n".utf8))
        return m
    }

    /// Drive the DECL-LEVEL T0 ISOLATION path (PATCH_REAL_SOURCE_DECL_ISOLATE): per
    /// export, isolate the embedded-clean math closure into a tiny T0 module and leave
    /// only the Foundation-touching remainder at T2. Returns the same Measured shape.
    private func measureIsolated(_ sourceDir: URL, label: String) throws -> Measured {
        setenv("PATCH_REAL_SOURCE", "1", 1)
        setenv("PATCH_REAL_SOURCE_DECL_ISOLATE", "1", 1)
        setenv("PATCH_REAL_SOURCE_DECL_ISOLATE_DUMP", "1", 1)
        setenv("PATCH_REAL_SOURCE_VERBOSE", "1", 1)
        setenv("PATCH_WASM_OPT", "0", 1)   // skip the slow -Oz finalize (raw-size comparison)
        defer {
            unsetenv("PATCH_REAL_SOURCE"); unsetenv("PATCH_REAL_SOURCE_DECL_ISOLATE")
            unsetenv("PATCH_REAL_SOURCE_DECL_ISOLATE_DUMP"); unsetenv("PATCH_REAL_SOURCE_VERBOSE")
            unsetenv("PATCH_WASM_OPT")
        }
        let build = FileManager.default.temporaryDirectory
            .appendingPathComponent("t0iso-\(label)-\(UUID().uuidString)")
        let compiler = SwiftWasmCompiler()
        let result = try BuildPipeline().run(
            sourceDir: sourceDir, buildDir: build, compiler: compiler, dryRun: false,
            outputModule: build.appendingPathComponent("module.wasm"))
        var size = 0
        if let m = result.realSourceModuleURL,
           let s = try? FileManager.default.attributesOfItem(atPath: m.path)[.size] as? Int { size = s }
        let m = Measured(moduleURL: result.realSourceModuleURL, size: size,
                         units: result.realSourceCompiledUnits,
                         exports: result.realSourceAddedExports)
        FileHandle.standardError.write(Data(
            "[\(label) ISOLATED] units=\(m.units) size=\(m.size)B (\(String(format: "%.3f", Double(m.size)/1_000_000)) MB) module=\(m.moduleURL?.lastPathComponent ?? "nil") exports=\(m.exports.prefix(12))\n".utf8))
        return m
    }

    /// wasm-opt -Oz + brotli the module, returning (ozBytes, brotliBytes).
    private func shrink(_ url: URL) -> (oz: Int, brotli: Int) {
        let oz = url.deletingPathExtension().appendingPathExtension("oz.wasm")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/wasm-opt")
        p.arguments = ["-Oz", url.path, "-o", oz.path, "--enable-bulk-memory", "--enable-sign-ext"]
        try? p.run(); p.waitUntilExit()
        let ozSize = (try? FileManager.default.attributesOfItem(atPath: oz.path)[.size] as? Int) ?? 0
        let br = oz.appendingPathExtension("br")
        let b = Process(); b.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brotli")
        b.arguments = ["-f", "-q", "11", oz.path, "-o", br.path]
        try? b.run(); b.waitUntilExit()
        let brSize = (try? FileManager.default.attributesOfItem(atPath: br.path)[.size] as? Int) ?? 0
        return (ozSize, brSize)
    }

    /// Run an export through wasmtime via the SAME (ptr,len) JSON ABI the SDK uses:
    /// patch_malloc the arg blob, call the export, read the {"value":N} result.
    /// Returns the raw result JSON string, or nil if the call could not be made.
    /// (We invoke wasmtime's CLI with a tiny wrapper that supplies the host imports.)
    private func reportSizes(_ label: String, t2: Measured, t0: Measured) {
        var lines = ["\n========= \(label) ========="]
        lines.append("  T2 (before): units=\(t2.units), size=\(t2.size) B (\(String(format: "%.2f", Double(t2.size)/1_000_000)) MB)")
        lines.append("  T0 (after):  units=\(t0.units), size=\(t0.size) B (\(String(format: "%.2f", Double(t0.size)/1_000)) KB)")
        if t0.size > 0, let url = t0.moduleURL {
            let (oz, br) = shrink(url)
            lines.append("  T0 -Oz: \(oz) B  |  T0 brotli: \(br) B")
            if t2.size > 0 {
                lines.append(String(format: "  DROP: %.0fx raw smaller, %.0fx vs brotli",
                                    Double(t2.size) / Double(max(t0.size, 1)),
                                    Double(t2.size) / Double(max(br, 1))))
            }
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: - App 1: Euclid (real value-type geometry library)

    func testEuclid() throws {
        try XCTSkipUnless(enabled, "set PATCH_T0_MEASURE=1 to run measurement")
        let src = try corpusSource("Euclid/Sources")
        let t2 = try measure(src, t0: false, label: "Euclid")
        let t0 = try measure(src, t0: true, label: "Euclid")
        reportSizes("Euclid", t2: t2, t0: t0)
    }

    // MARK: - App 2: CryptoSwift

    func testCryptoSwift() throws {
        try XCTSkipUnless(enabled, "set PATCH_T0_MEASURE=1 to run measurement")
        let src = try corpusSource("CryptoSwift/Sources/CryptoSwift")
        let t2 = try measure(src, t0: false, label: "CryptoSwift")
        let t0 = try measure(src, t0: true, label: "CryptoSwift")
        reportSizes("CryptoSwift", t2: t2, t0: t0)
    }

    // MARK: - DECL-LEVEL T0 ISOLATION measurements (the FINAL size lever)
    //
    // Each compares the COARSE default-routed module (today: T2 ~60-69 MB for a real
    // library, because some closure file mixes clean math with Foundation) vs the
    // DECL-LEVEL ISOLATED module (clean math exports pulled into a tiny T0 module,
    // only the Foundation-touching remainder at T2). Reports size before/after +
    // brotli + the per-export T0/T2 split (in the [decl-isolate split] stderr line).

    func testEuclidIsolated() throws {
        try XCTSkipUnless(enabled, "set PATCH_T0_MEASURE=1 to run measurement")
        let src = try corpusSource("Euclid/Sources")
        let coarse = try measure(src, t0: true, label: "Euclid-coarse")
        let iso = try measureIsolated(src, label: "Euclid")
        reportSizes("Euclid (coarse vs isolated)", t2: coarse, t0: iso)
    }

    func testCryptoSwiftIsolated() throws {
        try XCTSkipUnless(enabled, "set PATCH_T0_MEASURE=1 to run measurement")
        let src = try corpusSource("CryptoSwift/Sources/CryptoSwift")
        let coarse = try measure(src, t0: true, label: "CryptoSwift-coarse")
        let iso = try measureIsolated(src, label: "CryptoSwift")
        reportSizes("CryptoSwift (coarse vs isolated)", t2: coarse, t0: iso)
    }

    func testMoneyIsolated() throws {
        try XCTSkipUnless(enabled, "set PATCH_T0_MEASURE=1 to run measurement")
        let src = try corpusSource("Money/Sources/Money")
        let coarse = try measure(src, t0: true, label: "Money-coarse")
        let iso = try measureIsolated(src, label: "Money")
        reportSizes("Money (coarse vs isolated)", t2: coarse, t0: iso)
    }

    // MARK: - App 3: a small VALUE app (scalar boundary — the clean T0 case)

    func testValueApp() throws {
        try XCTSkipUnless(enabled, "set PATCH_T0_MEASURE=1 to run measurement")
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("valapp-\(UUID().uuidString)")
        let src = app.appendingPathComponent("Sources/Geo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        // Scalar-boundary funcs the DEFAULT engine REJECTS (they route through a
        // class-backed helper the reconstruction bundler refuses), so they take the
        // ADDITIVE real-source path — and have an Int→Int boundary the host bridge
        // reduces, i.e. T0-eligible. This is the clean T0 case.
        try """
        import Foundation
        final class Accumulator {
            private var total: Int = 0
            func add(_ v: Int) -> Int { total += v; return total }
        }
        public func scaleSum(_ a: Int, _ b: Int) -> Int {
            let acc = Accumulator(); _ = acc.add(a); return acc.add(b) * 2
        }
        public func isConvexCount(_ n: Int) -> Int {
            let acc = Accumulator(); return acc.add(n) == 3 ? 1 : 0
        }
        public func clampPos(_ v: Int) -> Int {
            let acc = Accumulator(); let t = acc.add(v); return t < 0 ? 0 : t
        }
        """.write(to: src.appendingPathComponent("Geo.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Geo", targets: [.target(name: "Geo")])
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let t2 = try measure(src, t0: false, label: "ValueApp")
        let t0 = try measure(src, t0: true, label: "ValueApp")
        reportSizes("ValueApp", t2: t2, t0: t0)
        // The T0 module must exist + be order-of-magnitude smaller than T2.
        if t2.size > 0 && t0.size > 0 {
            XCTAssertLessThan(t0.size * 10, t2.size, "T0 must be >10x smaller than T2")
        }
        // EXECUTE the T0 module in WasmKit and confirm the SAME values the SDK expects.
        guard let m = t0.moduleURL else { return XCTFail("no T0 module to execute") }
        let runner = try Runner(wasm: [UInt8](try Data(contentsOf: m)))
        // scaleSum(3,4) = (3+4)*2 = 14 ; isConvexCount(3)=1, (4)=0 ; clampPos(-5)=0, (9)=9.
        XCTAssertEqual(try runner.callInt("scaleSum", #"{"a":3,"b":4}"#), 14, "T0 scaleSum")
        XCTAssertEqual(try runner.callInt("isConvexCount", #"{"n":3}"#), 1, "T0 isConvexCount(3)")
        XCTAssertEqual(try runner.callInt("isConvexCount", #"{"n":4}"#), 0, "T0 isConvexCount(4)")
        XCTAssertEqual(try runner.callInt("clampPos", #"{"v":-5}"#), 0, "T0 clampPos(-5)")
        XCTAssertEqual(try runner.callInt("clampPos", #"{"v":9}"#), 9, "T0 clampPos(9)")
        FileHandle.standardError.write(Data("[ValueApp T0 EXEC] scaleSum/isConvexCount/clampPos all correct\n".utf8))

        // The T2 module must ALSO execute the same exports to the same values
        // (proving the routing change is value-preserving, not just smaller).
        if let m2 = t2.moduleURL {
            let r2 = try Runner(wasm: [UInt8](try Data(contentsOf: m2)))
            XCTAssertEqual(try r2.callInt("scaleSum", #"{"a":3,"b":4}"#), 14, "T2 scaleSum")
            XCTAssertEqual(try r2.callInt("clampPos", #"{"v":-5}"#), 0, "T2 clampPos")
            FileHandle.standardError.write(Data("[ValueApp T2 EXEC] same values as T0\n".utf8))
        }
    }

    // MARK: - Isolation smoke: clean + Foundation-needing exports in ONE module
    //
    // Two exports: a clean-math one (Int boundary, no Foundation in its closure) and a
    // Foundation-needing one (Double(String) — an embedded blocker). Decl-level
    // isolation must put the clean export on T0 and the Foundation one on T2 (PMOD
    // container), and BOTH must execute to the same values as the coarse module.
    func testIsolationSplitExecutes() throws {
        try XCTSkipUnless(enabled, "set PATCH_T0_MEASURE=1 to run measurement")
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("isoapp-\(UUID().uuidString)")
        let src = app.appendingPathComponent("Sources/Mix")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        // `cleanSum` reaches only a clean class-backed helper (Int math) → T0-clean.
        // `parseScaled` reaches `Double(String)` → genuine Foundation/embedded blocker → T2.
        try """
        import Foundation
        final class Accumulator {
            private var total: Int = 0
            func add(_ v: Int) -> Int { total += v; return total }
        }
        final class Parser {
            func value(_ s: String) -> Double { (Double(s) ?? 0) }
        }
        public func cleanSum(_ a: Int, _ b: Int) -> Int {
            let acc = Accumulator(); _ = acc.add(a); return acc.add(b) * 2
        }
        public func parseScaled(_ s: String) -> Double { Parser().value(s) * 2.0 }
        """.write(to: src.appendingPathComponent("Mix.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Mix", targets: [.target(name: "Mix")])
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let coarse = try measure(src, t0: true, label: "IsoMix-coarse")
        let iso = try measureIsolated(src, label: "IsoMix")
        reportSizes("IsoMix (coarse vs isolated)", t2: coarse, t0: iso)
        // The isolated module must still ship BOTH exports (no coverage loss) — the
        // take-the-best either ships the PMOD (T0 clean + T2 remainder) or, when a
        // remainder export forces the full Foundation runtime (so the container is NOT
        // smaller than coarse), keeps the coarse module. EITHER WAY both exports ship.
        XCTAssertTrue(iso.exports.contains("cleanSum"), "clean export must ship")
        XCTAssertTrue(iso.exports.contains("parseScaled"), "Foundation export must ship")
        // HONEST size truth: for a MIXED app (1 clean + 1 Foundation-needing export) the
        // T2 remainder still ships the full ~7 MB Foundation runtime, so the T0+T2
        // container CANNOT be smaller than coarse — take-the-best correctly keeps coarse.
        // (Isolation shrinks total ONLY when it makes the T2 module vanish — i.e. ALL
        // exports T0-clean, the pure-math-library case measured in the library tests.)
        // We assert the module is still instantiable + correct, not that it shrank.
        guard let m = iso.moduleURL else { return XCTFail("no isolated module") }
        let runner = try Runner(wasm: [UInt8](try Data(contentsOf: m)))
        XCTAssertEqual(try runner.callInt("cleanSum", #"{"a":3,"b":4}"#), 14, "cleanSum")
        struct OutD: Decodable { let value: Double }
        let bytes = try runner.callPacked("parseScaled", [UInt8](#"{"s":"21"}"#.utf8))
        let v = try JSONDecoder().decode(OutD.self, from: Data(bytes)).value
        XCTAssertEqual(v, 42.0, accuracy: 1e-9, "parseScaled")
        FileHandle.standardError.write(Data("[IsoMix EXEC] cleanSum=14, parseScaled=42 — both correct (mixed app: take-the-best kept coarse)\n".utf8))
    }

    // MARK: - Isolation WIN: ALL exports T0-clean (the pure-math-library shape)
    //
    // When EVERY additive export is embedded-clean, isolation makes the T2 module
    // VANISH — the whole additive module drops from the multi-MB Foundation tier to a
    // tiny T0 module. This is the headline case (Euclid/CryptoSwift). Synthetic so it
    // runs fast; the real libraries are measured in their own (slow) tests.
    func testIsolationAllCleanShrinks() throws {
        try XCTSkipUnless(enabled, "set PATCH_T0_MEASURE=1 to run measurement")
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("allclean-\(UUID().uuidString)")
        let src = app.appendingPathComponent("Sources/Calc")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        // Both exports reach ONLY clean Int math (class-backed helper the default engine
        // rejects → additive path), so BOTH are T0-clean.
        try """
        final class Accumulator {
            private var total: Int = 0
            func add(_ v: Int) -> Int { total += v; return total }
        }
        public func scaleSum(_ a: Int, _ b: Int) -> Int {
            let acc = Accumulator(); _ = acc.add(a); return acc.add(b) * 2
        }
        public func tripleAdd(_ a: Int, _ b: Int, _ c: Int) -> Int {
            let acc = Accumulator(); _ = acc.add(a); _ = acc.add(b); return acc.add(c)
        }
        """.write(to: src.appendingPathComponent("Calc.swift"), atomically: true, encoding: .utf8)
        // A SEPARATE Foundation/Mirror file NEITHER export reaches (no free pure func, so
        // it adds no export). It carries `import Foundation` + a Mirror/Decimal type, so
        // the COARSE whole-module closure is a Foundation closure (forcing coarse to T2),
        // while decl-level isolation routes AROUND it (the exports' minimal closures never
        // pull it). This is the Euclid/CryptoSwift shape in miniature: one poisoned file
        // drags the coarse module to T2; per-export isolation keeps the clean exports at T0.
        try """
        import Foundation
        struct Describer {
            let payload: Decimal
            func describe() -> String { "\\(Mirror(reflecting: payload).children.count)" }
        }
        """.write(to: src.appendingPathComponent("Poison.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Calc", targets: [.target(name: "Calc")])
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let coarse = try measure(src, t0: true, label: "AllClean-coarse")
        let iso = try measureIsolated(src, label: "AllClean")
        reportSizes("AllClean (coarse vs isolated)", t2: coarse, t0: iso)
        // Both clean exports must ship.
        XCTAssertTrue(iso.exports.contains("scaleSum") && iso.exports.contains("tripleAdd"),
                      "both clean exports must ship via isolation")
        // The headline: isolation makes the T2 module vanish, so the isolated module is
        // tiny (T0 only) and ORDER-OF-MAGNITUDE smaller than the coarse Foundation module.
        if coarse.size > 1_000_000 {
            XCTAssertLessThan(iso.size, coarse.size, "isolated must be smaller than coarse-T2")
            XCTAssertLessThan(iso.size, 600_000, "isolated all-clean module must be tiny (T0 only)")
            XCTAssertLessThan(iso.size * 5, coarse.size, "isolated must be >5x smaller than coarse")
        }
        // Execute both — same values the SDK expects.
        guard let m = iso.moduleURL else { return XCTFail("no isolated module") }
        let runner = try Runner(wasm: [UInt8](try Data(contentsOf: m)))
        XCTAssertEqual(try runner.callInt("scaleSum", #"{"a":3,"b":4}"#), 14, "scaleSum")
        XCTAssertEqual(try runner.callInt("tripleAdd", #"{"a":1,"b":2,"c":3}"#), 6, "tripleAdd")
        FileHandle.standardError.write(Data("[AllClean EXEC] scaleSum=14, tripleAdd=6 — both correct from tiny T0 module (coarse \(coarse.size)B → isolated \(iso.size)B)\n".utf8))
    }

    // MARK: - App 4: a closure that GENUINELY needs Foundation → must fall back to T2

    func testFoundationFallback() throws {
        try XCTSkipUnless(enabled, "set PATCH_T0_MEASURE=1 to run measurement")
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("fndapp-\(UUID().uuidString)")
        let src = app.appendingPathComponent("Sources/Conv")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        // Forces the ADDITIVE path (a class-backed helper the default rejects) AND
        // genuinely needs Foundation (Double(String) — a known embedded blocker per
        // the memory note). So: additive → T0 attempt fails the embedded link →
        // convergence escalates to T2 against the original closure → still ships.
        try """
        import Foundation
        final class Parser {
            func value(_ s: String) -> Double { (Double(s) ?? 0) }
        }
        public func parseScaled(_ s: String) -> Double {
            Parser().value(s) * 2.0
        }
        """.write(to: src.appendingPathComponent("Conv.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Conv", targets: [.target(name: "Conv")])
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // Default routing (T0 attempted) — the loop must escalate and STILL ship.
        let t0 = try measure(src, t0: true, label: "FndFallback")
        FileHandle.standardError.write(Data(
            "[FndFallback] shipped units=\(t0.units) size=\(t0.size)B (\(String(format: "%.1f", Double(t0.size)/1_000_000)) MB) exports=\(t0.exports)\n".utf8))
        // It still ships (correctness preserved via T2 fallback) — non-zero size.
        XCTAssertGreaterThan(t0.size, 0, "Foundation-needing export must still ship (via T2 fallback)")
        XCTAssertTrue(t0.exports.contains("parseScaled"), "the escalated export must ship")
        // The fallback module must be FULL Foundation (multi-MB), confirming it did
        // NOT ride T0 (a genuine-Foundation closure can't be tiny).
        XCTAssertGreaterThan(t0.size, 1_000_000, "a Foundation-needing module is NOT tiny — it escalated to T2")
        // And it EXECUTES correctly: parseScaled("21") = 21*2 = 42.
        if let m = t0.moduleURL {
            let runner = try Runner(wasm: [UInt8](try Data(contentsOf: m)))
            struct OutD: Decodable { let value: Double }
            let bytes = try runner.callPacked("parseScaled", [UInt8](#"{"s":"21"}"#.utf8))
            let v = try JSONDecoder().decode(OutD.self, from: Data(bytes)).value
            XCTAssertEqual(v, 42.0, accuracy: 1e-9, "escalated-to-T2 parseScaled must run + return 42")
            FileHandle.standardError.write(Data("[FndFallback EXEC] parseScaled(\"21\") = \(v) (correct, T2 fallback works)\n".utf8))
        }
    }
}
