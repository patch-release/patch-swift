// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import SwiftParser
import CryptoKit
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

// ===========================================================================
// LEVER #2 — the BUILD-WIRING PASS proof (the engine half, general-logic path).
//
// Proves `HostBridgeLowering` (the new pass that joins the four proven host-bridge
// components into `patchcli build`) end-to-end on a SYNTHETIC app whose function the
// engine forces native BUT which contains a routable call to a local symbol:
//
//   @objc final class Cart {              // @objc → the method is forced NATIVE
//     @objc func recompute() {
//       self.total = PricingEngine.discount(subtotal: subtotal, tier: tier)
//     }                                    // PricingEngine.discount → ROUTABLE
//   }
//
// With PATCH_HOST_BRIDGE=1 the build must:
//   (1) classify `recompute()` forced-native (the premise),
//   (2) ROUTE the `PricingEngine.discount(subtotal:tier:)` call (the guest carries
//       the `patch_host`/`__patchHostCall` sequence),
//   (3) emit `patch_host_symbols.json` listing the symbol with the engine's
//       content-addressed id (truncate32(SHA256(canonicalSignature))),
//   (4) generate a resolver thunk (`PatchHostBridges.generated.swift`) that
//       host-`swiftc -typecheck`s against the app's real `PricingEngine`.
//
// With the flag OFF: NO host-bridge artifacts, build unchanged (the no-regression
// guarantee — the flag-OFF build is byte-identical to today).
// ===========================================================================
final class HostBridgeLoweringTests: XCTestCase {

    // The routable call the synthetic app makes. The content-addressed id the
    // manifest must carry (both halves recompute the same SHA256-derived id).
    private static let canonicalSignature =
        "Cart.PricingEngine.discount(subtotal:Double,tier:Int)->Double"

    /// A synthetic app: an `@objc` method (forced native) whose body calls a local
    /// `PricingEngine.discount(subtotal:tier:)` — the routable call. The source dir
    /// last component is `Cart` so the pass's module name → `Cart` (the canonical
    /// receiver prefix the id keys on).
    private func makeApp() throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("hb-lower-\(UUID().uuidString)")
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

            // @objc forces this method native; the body's call to the local
            // PricingEngine.discount(subtotal:tier:) is the routable site. The args are
            // method PARAMETERS (typed) so the call is provably marshallable.
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
    // MARK: Premise — the method IS forced native
    // -----------------------------------------------------------------------

    func testPremiseRecomputeIsForcedNative() throws {
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let report = try PartitioningEngine().analyze(directory: sourceDir(app))
        let recompute = report.results.first { $0.functionID.contains("recompute") }
        XCTAssertNotNil(recompute, "recompute must be in the report; ids=\(report.results.map(\.functionID))")
        XCTAssertEqual(recompute?.classification, .native,
                       "an @objc method must be forced native (the premise of the routing pass)")
    }

    // -----------------------------------------------------------------------
    // MARK: (1)+(2) The pass ROUTES the call (guest carries the host-call sequence)
    // -----------------------------------------------------------------------

    func testPassRoutesTheLocalDiscountCall() throws {
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let report = try PartitioningEngine().analyze(directory: sourceDir(app))
        let buildDir = app.appendingPathComponent("build")
        // Run the pass WITHOUT the typecheck net so the result is deterministic in CI
        // without a host swiftc (a separate test exercises the net).
        let r = try HostBridgeLowering(moduleName: "Cart")
            .run(report: report, sourceDir: sourceDir(app), buildDir: buildDir,
                 runThunkTypecheck: false)

        XCTAssertGreaterThanOrEqual(r.examinedForcedNativeFunctions, 1,
                                    "the pass must examine the forced-native recompute()")
        XCTAssertEqual(r.routed.count, 1, "exactly the discount call routes; got \(r.routed.map(\.symbol.canonicalSignature))")
        let routed = try XCTUnwrap(r.routed.first)
        XCTAssertEqual(routed.symbol.canonicalSignature, Self.canonicalSignature)

        // The content-addressed id matches an independent SHA256 derivation.
        let digest = SHA256.hash(data: Data(Self.canonicalSignature.utf8))
        let b = Array(digest.prefix(4))
        let u = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        XCTAssertEqual(routed.symbol.id, Int32(bitPattern: u),
                       "the routed id must be truncate32(SHA256(canonicalSignature))")

        // The guest sequence carries the generic-bridge routing (the `have()`
        // pre-flight + the `__patchHostCall` dispatch), NOT the raw native call alone.
        XCTAssertTrue(routed.guestSequence.contains("patch_host_have"),
                      "the routed guest sequence must pre-flight the symbol; got:\n\(routed.guestSequence)")
        XCTAssertTrue(routed.guestSequence.contains("__patchHostCall"),
                      "the routed guest sequence must dispatch through the generic bridge; got:\n\(routed.guestSequence)")
        // The fallback path keeps the verbatim native call (demote-safe).
        XCTAssertTrue(routed.guestSequence.contains("PricingEngine.discount"),
                      "the demote-safe fallback must keep the verbatim native call")
    }

    // -----------------------------------------------------------------------
    // MARK: (2b) THE RE-SPLIT — the function flips native→OTA (guest body carries
    //            the routed sequence). The headline Lever-#2 deliverable.
    // -----------------------------------------------------------------------

    func testPassReLowersTheForcedNativeFunction() throws {
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let report = try PartitioningEngine().analyze(directory: sourceDir(app))
        let buildDir = app.appendingPathComponent("build")
        let r = try HostBridgeLowering(moduleName: "Cart")
            .run(report: report, sourceDir: sourceDir(app), buildDir: buildDir,
                 runThunkTypecheck: false)

        // The forced-native recompute() now RE-LOWERS to OTA (it was fully native
        // before; its sole native-ness was the bridgeable PricingEngine.discount call).
        XCTAssertEqual(r.lowered.count, 1,
                       "the forced-native recompute() must flip native→OTA; lowered=\(r.lowered.map(\.functionID))")
        let lowered = try XCTUnwrap(r.lowered.first)
        XCTAssertTrue(lowered.functionID.contains("recompute"),
                      "the lowered function is recompute(); got \(lowered.functionID)")
        XCTAssertEqual(lowered.routedCallCount, 1, "exactly one routed call was spliced")

        // The guest BODY carries the spliced routed sequence (the `have()` pre-flight
        // + `__patchHostCall` dispatch), NOT the raw native call alone — the re-split.
        XCTAssertTrue(lowered.guestBody.contains("patch_host_have"),
                      "the re-lowered body must pre-flight the routed symbol; got:\n\(lowered.guestBody)")
        XCTAssertTrue(lowered.guestBody.contains("__patchHostCall"),
                      "the re-lowered body must dispatch through the generic bridge; got:\n\(lowered.guestBody)")
        // The native shell write is preserved verbatim (the `self.total =` stays; only
        // its VALUE — the bridgeable call — was bridged).
        XCTAssertTrue(lowered.guestBody.contains("self.total ="),
                      "the re-lowered body keeps the native shell write verbatim; got:\n\(lowered.guestBody)")
        // The verbatim native call survives only as the demote-safe FALLBACK inside
        // the spliced sequence (never as the sole, un-bridged call).
        XCTAssertTrue(lowered.guestBody.contains("PricingEngine.discount"),
                      "the demote-safe fallback keeps the verbatim native call")
        // The body parses cleanly (a corrupt splice never ships).
        XCTAssertFalse(Parser.parse(source: lowered.guestBody).hasError,
                       "the re-lowered guest body must parse cleanly")
        // The routed id the body splices is the manifest's content-addressed id.
        XCTAssertEqual(lowered.routedSymbolIDs,
                       [HostBridgeABI.hostBridgeSymbolId(Self.canonicalSignature)])
    }

    /// FLAG OFF: the function stays fully native — NO re-lower (the no-regression
    /// premise, asserted via the BuildPipeline path so it exercises the real gate).
    func testFlagOffNoReLower() throws {
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let buildDir = app.appendingPathComponent("build")
        let result = try withEnv(["PATCH_HOST_BRIDGE": nil]) {
            try BuildPipeline().run(
                sourceDir: sourceDir(app), buildDir: buildDir,
                compiler: StubWasmCompiler(), dryRun: false)
        }
        XCTAssertEqual(result.hostBridgeLoweredFunctions, 0,
                       "no re-lower with the flag off (the function stays fully native)")
        XCTAssertTrue(result.hostBridgeLowered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: buildDir.appendingPathComponent("patch_host_symbols.guest.swift").path),
            "the flag-off build must not write the guest-export manifest")
    }

    // -----------------------------------------------------------------------
    // MARK: (5) The `patch_host_symbols` GUEST EXPORT is emitted (SDK reads it)
    // -----------------------------------------------------------------------

    func testGuestExportManifestEmittedAndParses() throws {
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let report = try PartitioningEngine().analyze(directory: sourceDir(app))
        let buildDir = app.appendingPathComponent("build")
        _ = try HostBridgeLowering(moduleName: "Cart")
            .run(report: report, sourceDir: sourceDir(app), buildDir: buildDir,
                 runThunkTypecheck: false)

        let guestURL = buildDir.appendingPathComponent("patch_host_symbols.guest.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: guestURL.path),
                      "the guest-export manifest source must be written")
        let src = try String(contentsOf: guestURL, encoding: .utf8)
        // The @_cdecl guest export with the SAME packed ABI as patch_view_manifest.
        XCTAssertTrue(src.contains("@_cdecl(\"patch_host_symbols\")"), src)
        XCTAssertTrue(src.contains("-> Int64"), "packed (ptr,len)->i64 ABI\n\(src)")
        XCTAssertTrue(src.contains("@_cdecl(\"patch_malloc\")"),
                      "the standalone guest module emits the allocator")
        // The baked JSON carries the routed symbol's canonical signature + id.
        XCTAssertTrue(src.contains("schemaVersion"), src)
        XCTAssertTrue(src.contains("PricingEngine.discount"), src)
        XCTAssertFalse(Parser.parse(source: src).hasError,
                       "the generated guest-export source must parse cleanly")
    }

    /// The guest-export emitter's JSON round-trips: the baked literal equals the
    /// manifest JSON the SDK decodes (so the on-device parse sees the same symbols
    /// as the engine-side `.json` file).
    func testGuestExportJSONMatchesManifest() throws {
        let symbols = [HostBridgeSymbol(
            canonicalSignature: Self.canonicalSignature,
            argTags: [.f64, .i64], retTag: .f64)]
        let jsonFile = try HostBridgeABI.emitManifestString(symbols)
        let guestSrc = try HostBridgeABI.emitManifestGuestExport(symbols)
        // The guest export bakes the EXACT manifest JSON (the SDK decodes the same).
        XCTAssertTrue(guestSrc.contains(jsonFile.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")),
            "the guest export must bake the exact manifest JSON")
    }

    // -----------------------------------------------------------------------
    // MARK: (3) The manifest is emitted with the content-addressed id
    // -----------------------------------------------------------------------

    func testManifestEmittedWithContentAddressedID() throws {
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let report = try PartitioningEngine().analyze(directory: sourceDir(app))
        let buildDir = app.appendingPathComponent("build")
        let r = try HostBridgeLowering(moduleName: "Cart")
            .run(report: report, sourceDir: sourceDir(app), buildDir: buildDir,
                 runThunkTypecheck: false)

        let manifestURL = try XCTUnwrap(r.manifestURL, "the manifest must be written")
        XCTAssertEqual(manifestURL.lastPathComponent, "patch_host_symbols.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(HostBridgeABI.Manifest.self, from: data)
        XCTAssertEqual(manifest.schemaVersion, HostBridgeABI.schemaVersion)
        XCTAssertEqual(manifest.symbols.count, 1)
        let entry = try XCTUnwrap(manifest.symbols.first)
        XCTAssertEqual(entry.canonicalSignature, Self.canonicalSignature)
        XCTAssertEqual(entry.id, HostBridgeABI.hostBridgeSymbolId(Self.canonicalSignature))
        // Double→f64, Int→i64 args; Double→f64 return (the wire tags the SDK decodes).
        XCTAssertEqual(entry.argTags, [TLVTag.f64.rawValue, TLVTag.i64.rawValue])
        XCTAssertEqual(entry.retTag, TLVTag.f64.rawValue)
    }

    // -----------------------------------------------------------------------
    // MARK: (4) The resolver thunk is generated + parses (real-SDK target)
    // -----------------------------------------------------------------------

    func testResolverThunkGeneratedAndParses() throws {
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let report = try PartitioningEngine().analyze(directory: sourceDir(app))
        let buildDir = app.appendingPathComponent("build")
        let r = try HostBridgeLowering(moduleName: "Cart")
            .run(report: report, sourceDir: sourceDir(app), buildDir: buildDir,
                 runThunkTypecheck: false)

        let thunkURL = try XCTUnwrap(r.thunkURL, "the resolver thunk must be written")
        XCTAssertEqual(thunkURL.lastPathComponent, "PatchHostBridges.generated.swift")
        let src = try String(contentsOf: thunkURL, encoding: .utf8)
        // The real-SDK registration shape (the integration contract).
        XCTAssertTrue(src.contains("import PatchHostBridge"), src)
        XCTAssertTrue(src.contains("{ (args: ArgReader, handles: HandleTable) throws -> TLVValue in"), src)
        // The real native call, statically type-checked, via the ArgReader accessors.
        XCTAssertTrue(src.contains("PricingEngine.discount(subtotal: try args.f64(0), tier: Int(try args.i64(1)))"),
                      "the thunk must call the real native symbol via the typed decode; got:\n\(src)")
        XCTAssertFalse(src.contains("\u{1}"), "no placeholder sentinel may survive")
        XCTAssertFalse(Parser.parse(source: src).hasError, "the generated thunk must parse cleanly")
    }

    // -----------------------------------------------------------------------
    // MARK: The compiles-or-demote net (real-SDK thunk type-checks against the app)
    // -----------------------------------------------------------------------

    func testThunkTypechecksAgainstRealAppSource() throws {
        guard BridgeThunkValidator.hostSwiftc() != nil else { throw XCTSkip("no host swiftc") }
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let report = try PartitioningEngine().analyze(directory: sourceDir(app))
        let buildDir = app.appendingPathComponent("build")
        // WITH the net on, the type-correct thunk for the real PricingEngine must be KEPT.
        let r = try HostBridgeLowering(moduleName: "Cart")
            .run(report: report, sourceDir: sourceDir(app), buildDir: buildDir,
                 runThunkTypecheck: true)
        XCTAssertEqual(r.routed.count, 1,
                       "a thunk that type-checks against the app's real PricingEngine must be kept; demoted=\(r.thunkDemoted)")
        XCTAssertNotNil(r.manifestURL)
        XCTAssertNotNil(r.thunkURL)
    }

    // -----------------------------------------------------------------------
    // MARK: End-to-end through the BuildPipeline (flag ON) + flag-OFF no-regression
    // -----------------------------------------------------------------------

    /// FLAG ON via the real `BuildPipeline.run` (dry-run, no WASM compile): the
    /// pipeline emits the host-bridge artifacts + reports the routed symbol.
    func testBuildPipelineEmitsHostBridgeArtifactsWhenFlagOn() throws {
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let buildDir = app.appendingPathComponent("build")
        let result = try withEnv(["PATCH_HOST_BRIDGE": "1"]) {
            try BuildPipeline().run(
                sourceDir: sourceDir(app), buildDir: buildDir,
                compiler: StubWasmCompiler(), dryRun: false)
        }
        XCTAssertEqual(result.hostBridgeRoutedSymbols, 1,
                       "the pipeline must route the discount call; routed=\(result.hostBridgeRouted)")
        XCTAssertNotNil(result.hostBridgeManifestURL, "manifest must be emitted")
        XCTAssertNotNil(result.hostBridgeThunkURL, "resolver thunk must be emitted")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: buildDir.appendingPathComponent("patch_host_symbols.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: buildDir.appendingPathComponent("PatchHostBridges.generated.swift").path))
        XCTAssertEqual(result.hostBridgeRouted.first?.signature, Self.canonicalSignature)
    }

    /// FLAG OFF (default): NO host-bridge artifacts, NO routed symbols — the build is
    /// unchanged. The no-regression guarantee.
    func testBuildPipelineUnchangedWhenFlagOff() throws {
        let app = try makeApp(); defer { try? FileManager.default.removeItem(at: app) }
        let buildDir = app.appendingPathComponent("build")
        // Ensure the flag is absent.
        let result = try withEnv(["PATCH_HOST_BRIDGE": nil]) {
            try BuildPipeline().run(
                sourceDir: sourceDir(app), buildDir: buildDir,
                compiler: StubWasmCompiler(), dryRun: false)
        }
        XCTAssertEqual(result.hostBridgeRoutedSymbols, 0, "no routing with the flag off")
        XCTAssertNil(result.hostBridgeManifestURL, "no manifest with the flag off")
        XCTAssertNil(result.hostBridgeThunkURL, "no thunk with the flag off")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: buildDir.appendingPathComponent("patch_host_symbols.json").path),
            "the flag-off build must not write the host-bridge manifest")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: buildDir.appendingPathComponent("PatchHostBridges.generated.swift").path),
            "the flag-off build must not write the resolver thunk")
    }

    // -----------------------------------------------------------------------
    // MARK: helpers
    // -----------------------------------------------------------------------

    /// Run `body` with the given env overrides applied to the process environment
    /// (a key mapped to nil is removed), restoring the prior values afterward. The
    /// pass reads `ProcessInfo.processInfo.environment`, so we mutate it for the run.
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
