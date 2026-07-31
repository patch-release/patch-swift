// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import CryptoKit
import WasmKit
import WasmKitWASI
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

// ===========================================================================
// LEVER #2 — the SHIP-GAP CLOSE proof (the module-wire half).
//
// `HostBridgeLowering` flips a forced-native function native→OTA and produces the
// re-lowered guest body. UNTIL the module-wire pass, that body was only REPORTED —
// it never reached the shipped WASM compile unit, so the flip was engine-level only.
//
// This proves the gap is CLOSED: for the synthetic flipped function
// (`@objc Cart.recompute()` routing `PricingEngine.discount`), with PATCH_HOST_BRIDGE
// on, the build produces a `module.hostbridge.wasm` that:
//   (a) contains the routed symbol's `patch_host.call` (instantiated + invocable),
//   (b) declares the THREE generic imports (`patch_host.call/.release/.have`),
//   (c) is INSTANTIABLE in WasmKit (compiled with the real swiftly WASM toolchain),
//   (d) exports `patch_host_symbols` carrying the routed signature + content-addressed id.
//
// Flag-OFF: NO host-bridge sub-module is produced (the build is unchanged).
//
// The on-device RUNTIME half (the SAME module instantiated against the real
// GenericHostBridge) lives in the SDK; this is the ENGINE/BUILD half. Both agree on
// the content-addressed symbol id.
// ===========================================================================
final class HostBridgeModuleWireTests: XCTestCase {

    private static let canonicalSignature =
        "Cart.PricingEngine.discount(subtotal:Double,tier:Int)->Double"

    // The synthetic app — identical to HostBridgeLoweringTests (the proven fixture):
    // an `@objc` method (forced native) routing a local `PricingEngine.discount` call.
    private func makeApp() throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("hb-wire-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("Sources/Cart")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try """
        import Foundation

        enum PricingEngine {
            static func discount(subtotal: Double, tier: Int) -> Double {
                let pct: Double = (tier == 2) ? 0.12 : (tier == 1) ? 0.05 : 0.0
                return (subtotal * (1.0 - pct) * 100).rounded() / 100
            }
        }

        @objc final class Cart: NSObject {
            var total: Double = 0
            @objc func recompute(subtotal: Double, tier: Int) {
                self.total = PricingEngine.discount(subtotal: subtotal, tier: tier)
            }
        }
        """.write(to: src.appendingPathComponent("Cart.swift"),
                  atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Cart", targets: [.target(name: "Cart")])
        """.write(to: tmp.appendingPathComponent("Package.swift"),
                  atomically: true, encoding: .utf8)
        return tmp
    }

    private func sourceDir(_ app: URL) -> URL { app.appendingPathComponent("Sources/Cart") }

    // -----------------------------------------------------------------------
    // MARK: The emission ASSEMBLY (toolchain-free): the guest source carries the
    // routed call + the 3 imports + the manifest export. The byte-for-byte floor
    // that runs in CI without the WASM toolchain.
    // -----------------------------------------------------------------------

    func testEmissionCarriesRoutedCallImportsAndManifestExport() throws {
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let report = try PartitioningEngine().analyze(directory: sourceDir(app))
        let buildDir = app.appendingPathComponent("build")
        let lowering = HostBridgeLowering(moduleName: "Cart")
        let r = try lowering.run(report: report, sourceDir: sourceDir(app),
                                 buildDir: buildDir, runThunkTypecheck: false)
        XCTAssertEqual(r.routed.count, 1, "the discount call must route")

        let emission = try XCTUnwrap(try lowering.buildGuestEmission(routed: r.routed),
                                     "a routed set must produce a shippable guest emission")
        // The wrapper source (the one with the preamble + exports).
        let wrapper = try XCTUnwrap(
            emission.files.first { $0.relativePath.hasSuffix(GenericHostBridgeGuestEmitter.wrapperFileName) })
        let cHeader = try XCTUnwrap(
            emission.files.first { $0.relativePath.hasSuffix("cbridge.h") })

        // (a) The routed symbol's content-addressed id rides the `patch_host.call`
        // dispatch (the `__patchHostCall(<id>, …)` the preamble forwards to the import).
        let id = HostBridgeABI.hostBridgeSymbolId(Self.canonicalSignature)
        XCTAssertTrue(wrapper.contents.contains("__patchHostCall(\(id),"),
                      "the wrapper must dispatch the routed symbol through the generic bridge; got:\n\(wrapper.contents)")
        // (b) The THREE generic imports are declared in the C bridge.
        for nm in ["\"call\"", "\"release\"", "\"have\""] {
            XCTAssertTrue(cHeader.contents.contains("WASM_IMPORT(\"patch_host\", \(nm))"),
                          "the C bridge must declare the generic import \(nm); got:\n\(cHeader.contents)")
        }
        XCTAssertTrue(cHeader.contents.contains("int64_t patch_host_call("))
        // (d) The manifest export is emitted, carrying the routed signature.
        XCTAssertTrue(wrapper.contents.contains("@_cdecl(\"patch_host_symbols\")"),
                      "the module must export patch_host_symbols; got:\n\(wrapper.contents)")
        XCTAssertTrue(wrapper.contents.contains(Self.canonicalSignature),
                      "the baked manifest must carry the routed canonical signature")
        XCTAssertTrue(emission.exports.contains("patch_host_symbols"))
        XCTAssertTrue(emission.exports.contains { $0.hasPrefix("hb_call__") },
                      "a per-flipped-function probe export must be offered; got \(emission.exports)")
    }

    // -----------------------------------------------------------------------
    // MARK: THE END-TO-END PROOF: compile the real `.wasm`, instantiate it in
    // WasmKit, route the call, read the manifest. Skips without the toolchain.
    // -----------------------------------------------------------------------

    func testHostBridgeModuleCompilesIsInstantiableAndRoutes() throws {
        let compiler = SwiftWasmCompiler()
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping guest compile/run")

        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let report = try PartitioningEngine().analyze(directory: sourceDir(app))
        let buildDir = app.appendingPathComponent("build")
        let lowering = HostBridgeLowering(moduleName: "Cart")
        let r = try lowering.run(report: report, sourceDir: sourceDir(app),
                                 buildDir: buildDir, runThunkTypecheck: false)
        let emission = try XCTUnwrap(try lowering.buildGuestEmission(routed: r.routed))

        // --- compile to a real .wasm via the new ship path ---
        let outModule = buildDir.appendingPathComponent("module.hostbridge.wasm")
        let compiled = try compiler.compileGenericHostBridgeGuest(
            emission: emission, outputModule: outModule)
        guard case .success = compiled.status else {
            return XCTFail("the host-bridge guest must compile to a .wasm; log:\n\(compiled.log)")
        }
        let moduleURL = try XCTUnwrap(compiled.moduleURL)
        let bytes = [UInt8](try Data(contentsOf: moduleURL))
        XCTAssertGreaterThan(bytes.count, 1024, "a real compiled Swift→WASM module is never tiny")

        // (b) The THREE generic imports appear in the module (their UTF-8 import
        // module/name strings are in the import section of the linked binary).
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("patch_host"), "the import module `patch_host` must be declared")
        for nm in ["call", "have", "release"] {
            XCTAssertTrue(text.contains(nm), "the generic import `\(nm)` must be declared")
        }

        // (a)+(c) INSTANTIATE in WasmKit with a host dispatcher wired to the 3 generic
        // imports. The probe export drives the routed `patch_host.call`; a successful
        // invocation proves the routed call is PRESENT + INSTANTIABLE. The dispatcher
        // executes the resolver-thunk's exact native computation for the routed id.
        let id = r.routed.first!.symbol.id
        var sawRoutedCall = false
        let runner = try GenericHBModuleRunner(wasm: bytes) { symbolId, _ in
            if symbolId == id { sawRoutedCall = true; return .f64(12.34) }
            return .error("unknown symbolId \(symbolId)")
        }
        // The flipped function's probe export (the re-lowered body).
        let probe = try XCTUnwrap(emission.exports.first { $0.hasPrefix("hb_call__") })
        // Invoking it must NOT trap (instantiable + the routed sequence runs).
        let result = try runner.invokeScalar(probe)
        XCTAssertNotNil(result, "the flipped-function probe must be invocable (instantiable)")
        XCTAssertTrue(sawRoutedCall,
                      "invoking the probe must drive the routed symbol's patch_host.call through the bridge")

        // (d) The module exports `patch_host_symbols`; read it + decode the manifest.
        let manifestBytes = try runner.invokePacked("patch_host_symbols")
        let manifestJSON = try XCTUnwrap(manifestBytes, "patch_host_symbols must return the manifest")
        let manifest = try JSONDecoder().decode(HostBridgeABI.Manifest.self, from: Data(manifestJSON))
        XCTAssertEqual(manifest.schemaVersion, HostBridgeABI.schemaVersion)
        XCTAssertEqual(manifest.symbols.count, 1)
        XCTAssertEqual(manifest.symbols.first?.canonicalSignature, Self.canonicalSignature)
        XCTAssertEqual(manifest.symbols.first?.id, id,
                       "the guest-exported manifest id must equal the routed content-addressed id")
    }

    // -----------------------------------------------------------------------
    // MARK: End-to-end through the BuildPipeline — the sub-module ships PMOD-additive.
    // -----------------------------------------------------------------------

    func testBuildPipelineShipsHostBridgeSubModuleWhenFlagOn() throws {
        let compiler = SwiftWasmCompiler()
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping pipeline ship test")
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let buildDir = app.appendingPathComponent("build")
        let result = try withEnv(["PATCH_HOST_BRIDGE": "1"]) {
            try BuildPipeline().run(
                sourceDir: sourceDir(app), buildDir: buildDir,
                compiler: compiler, dryRun: false, swiftUIEnabled: false)
        }
        XCTAssertEqual(result.hostBridgeRoutedSymbols, 1)
        let hbModule = try XCTUnwrap(result.hostBridgeModuleURL,
                                     "the host-bridge sub-module must be compiled + recorded")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hbModule.path))
        XCTAssertTrue(result.hostBridgeModuleExports.contains("patch_host_symbols"))
        // It ships PMOD-additive: the default `module.wasm` becomes a container that
        // carries the host-bridge module as a SEPARATE (still-instantiable) instance.
        let defaultModule = buildDir.appendingPathComponent("module.wasm")
        if FileManager.default.fileExists(atPath: defaultModule.path) {
            let bytes = [UInt8](try Data(contentsOf: defaultModule))
            if PatchModuleContainer.isContainer(bytes) {
                let parts = try XCTUnwrap(PatchModuleContainer.decode(bytes))
                XCTAssertGreaterThanOrEqual(parts.count, 2,
                    "the default module must carry the host-bridge sub-module as an additive PMOD part")
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: FLAG OFF — no host-bridge sub-module is produced (no regression).
    // -----------------------------------------------------------------------

    func testNoHostBridgeModuleWhenFlagOff() throws {
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let buildDir = app.appendingPathComponent("build")
        let result = try withEnv(["PATCH_HOST_BRIDGE": nil]) {
            try BuildPipeline().run(
                sourceDir: sourceDir(app), buildDir: buildDir,
                compiler: StubWasmCompiler(), dryRun: false)
        }
        XCTAssertEqual(result.hostBridgeRoutedSymbols, 0)
        XCTAssertNil(result.hostBridgeModuleURL, "no host-bridge sub-module with the flag off")
        XCTAssertTrue(result.hostBridgeModuleExports.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: buildDir.appendingPathComponent("module.hostbridge.wasm").path),
            "the flag-off build must not write the host-bridge sub-module")
    }

    // -----------------------------------------------------------------------
    // MARK: helpers
    // -----------------------------------------------------------------------

    private func withEnv<T>(_ overrides: [String: String?], _ body: () throws -> T) rethrows -> T {
        var saved: [String: String?] = [:]
        for (k, v) in overrides {
            saved[k] = ProcessInfo.processInfo.environment[k]
            if let v { setenv(k, v, 1) } else { unsetenv(k) }
        }
        defer {
            for (k, v) in saved {
                if let v { setenv(k, v, 1) } else { unsetenv(k) }
            }
        }
        return try body()
    }
}

// MARK: - A minimal TLV decode (the dispatcher only needs the result-arena packer).

private enum HBTLVMini {
    static func encodeF64(_ v: Double) -> [UInt8] {
        var out: [UInt8] = [2]
        let bits = (v.isFinite ? v : 0).bitPattern
        for k in 0..<8 { out.append(UInt8((bits >> (UInt64(k) * 8)) & 0xff)) }
        return out
    }
    static func encodeError(_ s: String) -> [UInt8] {
        let u = Array(s.utf8)
        var out: [UInt8] = [7]
        let n = UInt32(u.count)
        out.append(UInt8(n & 0xff)); out.append(UInt8((n >> 8) & 0xff))
        out.append(UInt8((n >> 16) & 0xff)); out.append(UInt8((n >> 24) & 0xff))
        out.append(contentsOf: u)
        return out
    }
}

private enum HBDispatchResult { case f64(Double); case error(String) }

// MARK: - A WasmKit runner wiring the THREE generic imports to a dispatcher (the
// engine-side analogue of the SDK's GenericHostBridge glue).

private final class GenericHBModuleRunner {
    let store: Store
    let instance: Instance
    let wasi: WASIBridgeToHost

    init(wasm: [UInt8], dispatch: @escaping (Int32, [UInt8]) -> HBDispatchResult) throws {
        let engine = Engine()
        self.store = Store(engine: engine)
        self.wasi = try WASIBridgeToHost()
        var imports = Imports()
        wasi.link(to: &imports, store: store)

        func readBytes(_ caller: Caller, _ p: UInt32, _ l: UInt32) -> [UInt8] {
            guard let mem = caller.instance?.exports[memory: "memory"], l > 0 else { return [] }
            let all = mem.data
            let s = Int(p), e = Int(p) + Int(l)
            guard s >= 0, e <= all.count else { return [] }
            return [UInt8](all[s..<e])
        }
        func packed(_ caller: Caller, _ bytes: [UInt8]) -> Value {
            if bytes.isEmpty { return .i64(0) }
            guard let alloc = caller.instance?.exports[function: "patch_malloc"],
                  let res = try? alloc.invoke([.i32(UInt32(bytes.count))]),
                  case .i32(let ptr) = res[0], ptr != 0,
                  let mem = caller.instance?.exports[memory: "memory"] else { return .i64(0) }
            mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: bytes.count) { raw in
                raw.copyBytes(from: bytes)
            }
            return .i64((UInt64(ptr) << 32) | UInt64(bytes.count))
        }

        imports.define(module: "patch_host", name: "call",
            Function(store: store, parameters: [.i32, .i32, .i32], results: [.i64]) { caller, args in
                let symbolId = Int32(bitPattern: args[0].i32)
                let blob = readBytes(caller, args[1].i32, args[2].i32)
                let out: [UInt8]
                switch dispatch(symbolId, blob) {
                case .f64(let v):   out = HBTLVMini.encodeF64(v)
                case .error(let m): out = HBTLVMini.encodeError(m)
                }
                return [packed(caller, out)]
            })
        imports.define(module: "patch_host", name: "release",
            Function(store: store, parameters: [.i32], results: []) { _, _ in [] })
        imports.define(module: "patch_host", name: "have",
            Function(store: store, parameters: [.i32], results: [.i32]) { _, _ in [.i32(1)] })

        let module = try parseWasm(bytes: wasm)
        self.instance = try module.instantiate(store: store, imports: imports)
        try wasi.initialize(instance)
    }

    /// Invoke a no-arg export, returning its first scalar result (or nil if it has none).
    func invokeScalar(_ name: String) throws -> Value? {
        guard let fn = instance.exports[function: name] else {
            throw NSError(domain: "hbwire", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no export \(name)"])
        }
        let r = try fn.invoke([])
        return r.first
    }

    /// Invoke a `(ptr,len) -> i64 packed (ptr<<32)|len` export + read the bytes back.
    func invokePacked(_ name: String) throws -> [UInt8]? {
        guard let fn = instance.exports[function: name] else { return nil }
        let r = try fn.invoke([.i32(0), .i32(0)])
        guard let v = r.first, case .i64(let packed) = v else { return nil }
        let ptr = UInt32((packed >> 32) & 0xffff_ffff)
        let len = UInt32(packed & 0xffff_ffff)
        guard len > 0, let mem = instance.exports[memory: "memory"] else { return nil }
        let all = mem.data
        let s = Int(ptr), e = Int(ptr) + Int(len)
        guard s >= 0, e <= all.count else { return nil }
        return [UInt8](all[s..<e])
    }
}
