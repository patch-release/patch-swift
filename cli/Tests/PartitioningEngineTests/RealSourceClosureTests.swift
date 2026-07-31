// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// Tests for the opt-in REAL-SOURCE closure compilation path
/// (`PATCH_REAL_SOURCE=1`) — the research breakthrough that compiles `@_cdecl`
/// export wrappers against the developer's verbatim module source instead of the
/// engine's reconstruction, demoting only on a real compile failure.
///
/// These tests need NO WASM toolchain: the admissibility/name logic is pure, and
/// the end-to-end path is exercised with a recording `WasmCompiling` stub that
/// captures what reaches the compiler (and can script a per-wrapper failure to
/// prove demote-on-real-failure via the existing convergence loop).
final class RealSourceClosureTests: XCTestCase {

    // MARK: - Source admissibility (guard-aware)

    /// A file whose ONLY native import is behind `#if canImport(...)` is admitted —
    /// the wasm compiler inerts the guarded import on wasm32. (This is the fix that
    /// lets the whole Euclid library — incl. its AppKit/SceneKit/Dispatch files —
    /// form the real-source closure; the over-strict `genericFileImportsSafe` gate
    /// wrongly dropped them and cascaded the closure to an empty module.)
    func testGuardedNativeImportIsAdmissible() {
        let src = """
        import Foundation
        #if canImport(UIKit)
        import UIKit
        #endif
        public struct Vec { public var x: Double }
        """
        XCTAssertTrue(BuildPipeline.realSourceFileAdmissible(src),
                      "a #if canImport(UIKit) import must NOT exclude the file")
    }

    /// An UNCONDITIONAL top-level native-only import (no `#if` guard) excludes the
    /// file — it cannot compile to wasm.
    func testUnconditionalNativeImportIsExcluded() {
        let src = """
        import SwiftUI
        public struct V: View { public var body: some View { EmptyView() } }
        """
        XCTAssertFalse(BuildPipeline.realSourceFileAdmissible(src),
                       "a top-level `import SwiftUI` must exclude the file")
    }

    /// A pure Foundation/stdlib file is always admissible. A shebang script is not.
    func testPlainFileAdmissibleScriptExcluded() {
        XCTAssertTrue(BuildPipeline.realSourceFileAdmissible(
            "import Foundation\nfunc f() -> Int { 1 }\n"))
        XCTAssertFalse(BuildPipeline.realSourceFileAdmissible(
            "#!/usr/bin/swift\nprint(\"hi\")\n"))
    }

    /// `#if !arch(wasm32)` guarding a Dispatch import is admitted (inert on wasm).
    func testArchGuardedImportAdmissible() {
        let src = """
        import Foundation
        #if canImport(Dispatch) && !arch(wasm32)
        import Dispatch
        #endif
        func g() { }
        """
        XCTAssertTrue(BuildPipeline.realSourceFileAdmissible(src))
    }

    // MARK: - Module-name derivation

    func testModuleNameSanitization() {
        XCTAssertEqual(SwiftWasmCompiler.sanitizedModuleName("Euclid"), "Euclid")
        XCTAssertEqual(SwiftWasmCompiler.sanitizedModuleName("my-lib.core"), "my_lib_core")
        XCTAssertEqual(SwiftWasmCompiler.sanitizedModuleName("123abc"), "_123abc")
        XCTAssertEqual(SwiftWasmCompiler.sanitizedModuleName(""), "PatchReal")
    }

    // MARK: - End-to-end pipeline path (recording compiler, no toolchain)

    /// A recording `WasmCompiling` stub: captures the source set it is asked to
    /// compile (so the test can assert the REAL module source + the wrappers both
    /// reach the compiler), and can script a single wrapper file to "fail" so the
    /// convergence loop's demote path is exercised.
    private final class RecordingCompiler: WasmCompiling, @unchecked Sendable {
        var lastSources: [URL] = []
        let failWrapperNamed: String?
        init(failWrapperNamed: String? = nil) { self.failWrapperNamed = failWrapperNamed }
        func compile(sources: [URL], outputModule: URL) throws -> WasmCompileResult {
            lastSources = sources
            if let bad = failWrapperNamed,
               let u = sources.first(where: { $0.lastPathComponent == bad }) {
                return WasmCompileResult(status: .failure(reason: "scripted"),
                                         moduleURL: nil,
                                         log: "\(u.path):1:1: error: scripted real-source failure\n")
            }
            try? Data([0x00, 0x61, 0x73, 0x6d]).write(to: outputModule)  // \0asm
            return WasmCompileResult(status: .success, moduleURL: outputModule, log: "ok")
        }
    }

    private func withRealSourceEnv(_ body: () throws -> Void) rethrows {
        setenv("PATCH_REAL_SOURCE", "1", 1)
        defer { unsetenv("PATCH_REAL_SOURCE") }
        try body()
    }

    private func makeApp() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rs-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("Sources/Geo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        // A value type with a pure instance method (the category the default
        // reconstruction path demotes; real source compiles it). Codable so the
        // JSON envelope round-trips.
        try """
        import Foundation
        public struct Vec: Codable {
            public var x: Double
            public var y: Double
            public func dot(_ o: Vec) -> Double { x * o.x + y * o.y }
        }
        """.write(to: src.appendingPathComponent("Vec.swift"), atomically: true, encoding: .utf8)
        // A throwaway Package.swift so the module name resolves to `Geo`.
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Geo", targets: [.target(name: "Geo")])
        """.write(to: tmp.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        return tmp
    }

    /// An app whose only eligible function references a CLASS the default engine
    /// rejects (the reconstruction bundler refuses reference types) — so the default
    /// ships nothing, and the ADDITIVE real-source path is what compiles it against
    /// the real source. Proves the additive module exists, adds the export, and that
    /// the REAL module source (not a reconstruction) reached the compiler.
    private func makeClassApp() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsc-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("Sources/Geo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        // A free function over a value the default reconstruction can rebuild, but we
        // also reference a CLASS-backed helper so the default bundler rejects it (it
        // categorically refuses classes), leaving the additive path to ship it.
        try """
        import Foundation
        public final class Box { public let v: Int; public init(_ v: Int) { self.v = v } }
        public func boxedDouble(_ x: Int) -> Int { Box(x).v * 2 }
        """.write(to: src.appendingPathComponent("Box.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Geo", targets: [.target(name: "Geo")])
        """.write(to: tmp.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        return tmp
    }

    func testAdditivePathShipsExportTheDefaultRejected() throws {
        let app = try makeClassApp()
        defer { try? FileManager.default.removeItem(at: app) }
        let build = app.appendingPathComponent("build")
        let rec = RecordingCompiler()
        try withRealSourceEnv {
            let result = try BuildPipeline().run(
                sourceDir: app.appendingPathComponent("Sources/Geo"),
                buildDir: build, compiler: rec, dryRun: false,
                outputModule: build.appendingPathComponent("module.wasm"))
            // The additive real-source module was built and added the export.
            XCTAssertNotNil(result.realSourceModuleURL, "additive module must be built")
            XCTAssertGreaterThan(result.realSourceCompiledUnits, 0,
                                 "additive units: \(result.realSourceCompiledUnits)")
            XCTAssertTrue(result.realSourceAddedExports.contains("boxedDouble"),
                          "added: \(result.realSourceAddedExports)")
            // The default module is UNTOUCHED (still produced) — additive, never a regression.
            XCTAssertNotNil(result.moduleURL)
        }
        // The REAL module source reached the compiler — NOT a reconstructed
        // `_PatchType_Box.swift`. BREAKTHROUGH #9: the scalar export `boxedDouble`
        // routes to T0, so the closure file `Box.swift` arrives as its T0-stripped
        // copy `<i>_Box.swift` (defensive `import Foundation` removed) rather than
        // byte-verbatim — still the developer's real source, just Foundation-free.
        let realFile = rec.lastSources.first {
            $0.lastPathComponent == "Box.swift" || $0.lastPathComponent.hasSuffix("_Box.swift")
        }
        XCTAssertNotNil(realFile,
                        "real module source must be in the additive compile unit: \(rec.lastSources.map { $0.lastPathComponent })")
        // No reconstruction file leaked in.
        XCTAssertFalse(rec.lastSources.contains { $0.lastPathComponent.hasPrefix("_PatchType_") },
                       "the real-source path must not ship a `_PatchType_` reconstruction")
        // The real `Box` definition survived the T0 strip verbatim (only the unused
        // `import Foundation` was removed).
        if let realFile, let src = try? String(contentsOf: realFile, encoding: .utf8) {
            XCTAssertTrue(src.contains("public final class Box"),
                          "the developer's real `Box` type must reach the compiler verbatim")
        }
    }

    /// A wrapper that fails the real compile is demoted by the convergence loop; a
    /// clean wrapper in the same additive module still ships (demote-on-real-failure).
    func testRealSourceDemotesOnlyTheFailingWrapper() throws {
        // Two free functions referencing a class (default rejects → both go to the
        // additive path), one scripted to fail the real compile.
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("rsd-\(UUID().uuidString)")
        let src = app.appendingPathComponent("Sources/Geo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        try """
        import Foundation
        public final class Box { public let v: Int; public init(_ v: Int) { self.v = v } }
        public func dotBox(_ x: Int) -> Int { Box(x).v }
        public func len2Box(_ x: Int) -> Int { Box(x).v * Box(x).v }
        """.write(to: src.appendingPathComponent("Box.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Geo", targets: [.target(name: "Geo")])
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let build = app.appendingPathComponent("build")
        // Script the `dotBox` wrapper to fail; `len2Box` must still ship.
        let rec = RecordingCompiler(failWrapperNamed: "_PatchReal_dotBox_wasm.swift")
        try withRealSourceEnv {
            let result = try BuildPipeline().run(
                sourceDir: app.appendingPathComponent("Sources/Geo"),
                buildDir: build, compiler: rec, dryRun: false,
                outputModule: build.appendingPathComponent("module.wasm"))
            // The additive module shipped the clean wrapper and dropped the failing one.
            XCTAssertTrue(result.realSourceAddedExports.contains("len2Box"),
                          "the clean wrapper must still ship; added=\(result.realSourceAddedExports)")
            XCTAssertFalse(result.realSourceAddedExports.contains("dotBox"),
                          "the failing wrapper must demote (not be added); added=\(result.realSourceAddedExports)")
            XCTAssertGreaterThanOrEqual(result.realSourceCompiledUnits, 1)
        }
    }

    /// With the switch OFF, the pipeline uses the DEFAULT engine only: no additive
    /// real-source module is built (the opt-in path is inert — canaries are safe).
    func testSwitchOffNoAdditiveModule() throws {
        let app = try makeApp()
        defer { try? FileManager.default.removeItem(at: app) }
        let build = app.appendingPathComponent("build")
        unsetenv("PATCH_REAL_SOURCE")
        let result = try BuildPipeline().run(
            sourceDir: app.appendingPathComponent("Sources/Geo"),
            buildDir: build, compiler: RecordingCompiler(), dryRun: false,
            outputModule: build.appendingPathComponent("module.wasm"))
        XCTAssertNil(result.realSourceModuleURL, "switch OFF must not build the additive module")
        XCTAssertEqual(result.realSourceCompiledUnits, 0)
    }

    // MARK: - BREAKTHROUGH #9: real-source T0 tier routing (no toolchain)
    //
    // The lever that makes real-source OTA modules ~6,800x smaller (57 MB T2 →
    // 8.8 KB brotli T0): route the real-source closure to the EMBEDDED (T0) SDK
    // whenever every export wrapper is the host-bridge form (scalar boundary, no
    // in-module Foundation), and fall back to T2 only for a shape the host bridge
    // can't reduce. These tests assert the ROUTING DECISIONS deterministically,
    // with no WASM toolchain (the size + executing-WASM proof is the harness Bar).

    /// A scalar-boundary export (Int args + Int return) routes to the EMBEDDED (T0)
    /// host-bridge wrapper: NO `import Foundation`, `import CHost`, hand-encoded
    /// result — and `emitRealSourceWrapper` reports it `t0Eligible == true`.
    func testScalarExportRoutesToEmbeddedT0Wrapper() {
        let emitter = CodeEmitter()
        let export = CodeEmitter.PureExport(
            exportName: "scaleSum", callee: "scaleSum",
            parameters: [(label: "_", name: "a", type: "Int"),
                         (label: "_", name: "b", type: "Int")],
            returnType: "Int")
        let (_, source, _, t0Eligible) =
            BuildPipeline.emitRealSourceWrapperForTesting(emitter, export)
        XCTAssertTrue(t0Eligible, "a scalar-boundary export must be T0-eligible")
        XCTAssertFalse(source.contains("import Foundation"),
                       "the T0 wrapper must carry NO in-module Foundation")
        XCTAssertTrue(source.contains("import CHost"),
                      "the T0 wrapper must import the CHost host-bridge")
    }

    /// A value-type-boundary export (a struct arg the host scalar bridge can't
    /// decode) must FALL BACK to the Foundation (T2) wrapper: it carries
    /// `import Foundation` + the in-module JSON coder, and reports `t0Eligible == false`.
    func testStructBoundaryExportFallsBackToFoundationT2Wrapper() {
        let emitter = CodeEmitter()
        // An instance method on a value type forces the Foundation wrapper (the T0
        // host bridge has no way to decode a Codable `_receiver`).
        let export = CodeEmitter.PureExport(
            exportName: "Vec_dot", callee: "dot",
            parameters: [(label: "_", name: "o", type: "Vec")],
            returnType: "Double", receiverType: "Vec")
        let (_, source, _, t0Eligible) =
            BuildPipeline.emitRealSourceWrapperForTesting(emitter, export)
        XCTAssertFalse(t0Eligible, "a value-type-boundary export must NOT be T0-eligible")
        XCTAssertTrue(source.contains("import Foundation"),
                      "the T2 fallback wrapper carries in-module Foundation")
    }

    /// The PATCH_REAL_SOURCE_NO_T0 kill-switch pins every wrapper to the Foundation
    /// (T2) form — the A/B / rollback lever.
    func testNoT0EnvForcesFoundationWrapper() {
        setenv("PATCH_REAL_SOURCE_NO_T0", "1", 1)
        defer { unsetenv("PATCH_REAL_SOURCE_NO_T0") }
        let emitter = CodeEmitter()
        let export = CodeEmitter.PureExport(
            exportName: "scaleSum", callee: "scaleSum",
            parameters: [(label: "_", name: "a", type: "Int")],
            returnType: "Int")
        let (_, source, _, t0Eligible) =
            BuildPipeline.emitRealSourceWrapperForTesting(emitter, export)
        XCTAssertFalse(t0Eligible, "NO_T0 must pin the Foundation wrapper")
        XCTAssertTrue(source.contains("import Foundation"))
    }

    /// The shared runtime allocator has an EMBEDDED (Foundation-free) variant for
    /// the T0 path. A single `import Foundation` anywhere poisons the embedded
    /// compile, so the T0 runtime must NOT import it; the T2 runtime does.
    func testEmbeddedRuntimeHasNoFoundationImport() {
        let emitter = CodeEmitter()
        let t0 = emitter.emitEmbeddedModuleRuntimeFile()
        let t2 = emitter.emitModuleRuntimeFile()
        XCTAssertFalse(t0.source.contains("import Foundation"),
                       "the embedded (T0) shared runtime must be Foundation-free")
        XCTAssertTrue(t2.source.contains("import Foundation"),
                      "the T2 shared runtime carries Foundation")
        // Both export the same allocator contract (the host marshals I/O via it).
        XCTAssertEqual(t0.exports, ["patch_malloc", "patch_free"])
        XCTAssertEqual(t2.exports, t0.exports)
        XCTAssertEqual(t0.fileName, "_PatchRuntime.swift")
    }

    /// The real-source manifest's TIER branches: at T0 it emits the Embedded
    /// feature + `-wmo` and declares the CHost C target; at T2 it does not enable
    /// Embedded but STILL declares CHost (so a T0-shaped wrapper that escalated to
    /// T2 keeps `import CHost` resolving).
    func testRealSourceManifestTierBranches() {
        let t0 = SwiftWasmCompiler(exportedSymbols: ["scaleSum"], tier: .t0Embedded)
        let m0 = t0.realSourceManifestForTesting(moduleName: "Geo", exports: ["scaleSum"])
        XCTAssertTrue(m0.contains("enableExperimentalFeature(\"Embedded\")"),
                      "T0 manifest must enable the Embedded feature")
        XCTAssertTrue(m0.contains("-wmo"), "T0 manifest must build whole-module")
        XCTAssertTrue(m0.contains("name: \"\(CHeaderBridge.cTargetName)\")"),
                      "T0 manifest must declare the CHost C target")

        let t2 = SwiftWasmCompiler(exportedSymbols: ["scaleSum"], tier: .t2Foundation)
        let m2 = t2.realSourceManifestForTesting(moduleName: "Geo", exports: ["scaleSum"])
        XCTAssertFalse(m2.contains("enableExperimentalFeature(\"Embedded\")"),
                       "T2 manifest must NOT enable Embedded")
        XCTAssertTrue(m2.contains("name: \"\(CHeaderBridge.cTargetName)\")"),
                      "T2 manifest must STILL declare CHost so an escalated T0 wrapper links")
    }

    /// Foundation-import stripping for T0: a Foundation-free file (T0 verdict) with
    /// a defensive top-level `import Foundation` has that import removed; a file that
    /// GENUINELY uses Foundation (a non-T0 verdict) keeps its import verbatim so it
    /// fails the embedded compile and the loop escalates. Guarded imports survive.
    func testFoundationStrippingForT0() {
        // (a) Unconditional top-level import is detected + removed.
        let defensive = "import Foundation\npublic func f(_ x: Int) -> Int { x * 2 }\n"
        XCTAssertTrue(BuildPipeline.hasUnconditionalFoundationImport(defensive))
        let stripped = BuildPipeline.removeUnconditionalFoundationImport(defensive)
        XCTAssertFalse(stripped.contains("import Foundation"),
                       "an unconditional `import Foundation` must be stripped")
        XCTAssertTrue(stripped.contains("x * 2"), "the code body must survive verbatim")

        // (b) A `#if`-guarded import is NOT detected as unconditional and is kept.
        let guarded = """
        #if canImport(Foundation)
        import Foundation
        #endif
        public func g(_ x: Int) -> Int { x }
        """
        XCTAssertFalse(BuildPipeline.hasUnconditionalFoundationImport(guarded),
                       "a #if-guarded import is not unconditional")
        let guardedOut = BuildPipeline.removeUnconditionalFoundationImport(guarded)
        XCTAssertTrue(guardedOut.contains("import Foundation"),
                      "a guarded import must be kept (the embedded compiler inerts it)")
    }

    /// The T0 unsatisfiable-import guard: a hand-built WASM module with an
    /// `env.<sym>` import (the unsatisfiable stdlib namespace, e.g. left by
    /// `Double(String)` under `--allow-undefined`) is flagged; a module importing
    /// only `patch_host.*` / `wasi_snapshot_preview1.*` is clean. This is what makes
    /// a T0 build that LINKED-but-can't-INSTANTIATE escalate to T2 instead of
    /// shipping a module that crashes the SDK with `unknown import env.…`.
    func testT0UnsatisfiableEnvImportGuard() {
        // Build a minimal valid WASM module: magic+version, then one import section
        // (id 2) with `count` func imports of (module, field).
        func wasm(imports: [(String, String)]) -> [UInt8] {
            func leb(_ n: Int) -> [UInt8] {
                var v = n, out: [UInt8] = []
                repeat { var b = UInt8(v & 0x7f); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
                return out
            }
            func name(_ s: String) -> [UInt8] { let b = [UInt8](s.utf8); return leb(b.count) + b }
            var sect: [UInt8] = leb(imports.count)
            for (m, f) in imports { sect += name(m) + name(f) + [0x00] + leb(0) } // func desc, typeidx 0
            var mod: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
            mod += [0x02] + leb(sect.count) + sect
            return mod
        }
        // Clean: only host-bridge + WASI.
        let clean = wasm(imports: [("patch_host", "json_get_i64"),
                                   ("wasi_snapshot_preview1", "random_get")])
        XCTAssertEqual(SwiftWasmCompiler.unsatisfiableEnvImports(clean), [],
                       "a clean T0 module has NO env imports")
        // Poisoned: an `env.*` stdlib import survived.
        let poisoned = wasm(imports: [("patch_host", "json_get_string"),
                                      ("env", "_swift_stdlib_strtod_clocale")])
        XCTAssertEqual(SwiftWasmCompiler.unsatisfiableEnvImports(poisoned),
                       ["_swift_stdlib_strtod_clocale"],
                       "an env.* import must be flagged so the T0 build escalates")
        // Not-a-wasm bytes → nil (no verdict; caller defers to toolchain error path).
        XCTAssertNil(SwiftWasmCompiler.unsatisfiableEnvImports([0x01, 0x02, 0x03]))
    }

    /// `stripFoundationForT0` keeps the import on a file that GENUINELY needs
    /// Foundation (its embedded verdict is NOT T0) so that file fails the embedded
    /// compile and the loop escalates to T2 — and strips it from a Foundation-free file.
    func testStripFoundationForT0KeepsGenuineFoundationFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("strip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // (a) Foundation-free file (only a defensive import).
        let freeURL = tmp.appendingPathComponent("Free.swift")
        try "import Foundation\npublic func add(_ a: Int, _ b: Int) -> Int { a + b }\n"
            .write(to: freeURL, atomically: true, encoding: .utf8)
        // (b) File that GENUINELY uses Foundation (JSONEncoder → non-T0 verdict).
        let needsURL = tmp.appendingPathComponent("Needs.swift")
        try """
        import Foundation
        public func enc() -> Data { try! JSONEncoder().encode([1, 2, 3]) }
        """.write(to: needsURL, atomically: true, encoding: .utf8)

        let out = try BuildPipeline().stripFoundationForT0(
            [freeURL, needsURL], rsBuildDir: tmp, log: { _ in })
        XCTAssertEqual(out.count, 2)
        let freeSrc = try String(contentsOf: out[0], encoding: .utf8)
        let needsSrc = try String(contentsOf: out[1], encoding: .utf8)
        XCTAssertFalse(freeSrc.contains("import Foundation"),
                       "the Foundation-free file has its defensive import stripped")
        XCTAssertTrue(needsSrc.contains("import Foundation"),
                      "the genuine-Foundation file KEEPS its import (it must fail T0 → escalate)")
    }
}
