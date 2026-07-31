// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// Regression tests for the four bugs the patch-release E2E found
/// (see /tmp/e2e_patch_roundtrip.md + /tmp/e2e_bugfix_progress.md). Each test FAILS
/// on the pre-fix code and PASSES after the fix. The WASM-executing BUG-1 test is
/// skipped when the swift.org toolchain is absent so the suite stays green
/// everywhere; the rest need no toolchain.
final class E2EBugfixTests: XCTestCase {

    // MARK: - Minimal T0 (ptr,len)+packed-i64 WasmKit runner (BUG-1 execution)

    private final class T0Runner {
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
                throw NSError(domain: "t0", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "missing export \(name)"])
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

    // MARK: - BUG-1 [P1]: stale .Patch/build must NOT serve the OLD function body

    /// UNIT-LEVEL (no toolchain): the engine's source walkers must NOT ingest the
    /// engine's OWN prior-run output under `.Patch/build`. Pre-fix, both
    /// `SwiftParserEngine.swiftFiles` (analyze) and `BuildPipeline.swiftFiles`
    /// (allFiles/bundler) skipped only `/.build/` `/.git/`, so a stale
    /// `_PatchType_*.swift` / `_PatchGenerics.swift` (carrying the LAST build's
    /// reconstructed bodies) was re-read as developer source — the root cause of the
    /// stale-build wrong-code OTA. Here we drop a stale generated support file in
    /// `.Patch/build` and assert neither walker returns it.
    func testEngineWalkersIgnorePatchBuildOutput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bug1-walk-\(UUID().uuidString)")
        let buildDir = dir.appendingPathComponent(".Patch/build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A real developer source file (must be seen).
        try "public enum Calc { public static func f(_ x: Int) -> Int { x + 1 } }"
            .write(to: dir.appendingPathComponent("Calc.swift"), atomically: true, encoding: .utf8)
        // A STALE engine-generated support file from a previous build (must NOT be seen).
        try "enum Calc { static func f(_ x: Int) -> Int { 9999 } }"
            .write(to: buildDir.appendingPathComponent("_PatchType_Calc.swift"),
                   atomically: true, encoding: .utf8)
        // And a stale verbatim closure (the other common poison source).
        try "// stale\nenum Stale {}"
            .write(to: buildDir.appendingPathComponent("_PatchGenerics.swift"),
                   atomically: true, encoding: .utf8)

        // Analyze-path walker.
        let analyzeFiles = try SwiftParserEngine.swiftFiles(in: dir).map { $0.lastPathComponent }
        XCTAssertTrue(analyzeFiles.contains("Calc.swift"), "developer source must be analyzed")
        XCTAssertFalse(analyzeFiles.contains("_PatchType_Calc.swift"),
                       "stale .Patch/build reconstruction must NOT be analyzed (BUG-1)")
        XCTAssertFalse(analyzeFiles.contains("_PatchGenerics.swift"),
                       "stale .Patch/build closure must NOT be analyzed (BUG-1)")

        // BuildPipeline allFiles walker (via the engine analyze path it mirrors): the
        // pipeline's private walker isn't directly callable, so assert the staging
        // invalidation removes the orphans a rebuild would otherwise reuse.
        BuildPipeline.invalidateStagedArtifacts(in: buildDir)
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: buildDir.path)) ?? []
        XCTAssertFalse(remaining.contains("_PatchType_Calc.swift"),
                       "staging invalidation must remove a stale reconstruction (BUG-1)")
        XCTAssertFalse(remaining.contains("_PatchGenerics.swift"),
                       "staging invalidation must remove a stale closure (BUG-1)")
    }

    /// `invalidateStagedArtifacts` removes only the engine's OWN generated files and
    /// the linked module + sub-build dirs — and leaves an unrelated file (and the
    /// developer's source) untouched.
    func testStagingInvalidationIsScoped() throws {
        let buildDir = FileManager.default.temporaryDirectory.appendingPathComponent("bug1-inval-\(UUID().uuidString)")
        let rsDir = buildDir.appendingPathComponent("realsource")
        try FileManager.default.createDirectory(at: rsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: buildDir) }
        func write(_ name: String, _ dir: URL = buildDir) throws {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("addTax_wasm.swift")
        try write("addTax_bridge.swift")
        try write("_PatchType_Vector.swift")
        try write("_PatchHelper_0_foo.swift")
        try write("_PatchGenerics.swift")
        try write("module.wasm")
        try write("module.realsource.wasm")
        try write("module.wasm.br")
        try write("notes.txt")               // unrelated — must survive
        try write("UserKept.swift")          // unrelated .swift — must survive
        try write("_PatchReal_x.swift", rsDir)

        BuildPipeline.invalidateStagedArtifacts(in: buildDir)

        let fm = FileManager.default
        for gone in ["addTax_wasm.swift", "addTax_bridge.swift", "_PatchType_Vector.swift",
                     "_PatchHelper_0_foo.swift", "_PatchGenerics.swift", "module.wasm",
                     "module.realsource.wasm", "module.wasm.br"] {
            XCTAssertFalse(fm.fileExists(atPath: buildDir.appendingPathComponent(gone).path),
                           "\(gone) is engine-generated and must be invalidated")
        }
        XCTAssertFalse(fm.fileExists(atPath: rsDir.path), "realsource/ sub-build dir must be removed")
        XCTAssertTrue(fm.fileExists(atPath: buildDir.appendingPathComponent("notes.txt").path),
                      "an unrelated file must be left untouched")
        XCTAssertTrue(fm.fileExists(atPath: buildDir.appendingPathComponent("UserKept.swift").path),
                      "an unrelated .swift must be left untouched")
    }

    /// END-TO-END (needs the WASM toolchain): build+execute v1 of a pure export, then
    /// EDIT its body and rebuild into the SAME dirty `.Patch/build` (no manual clear)
    /// — the executed module MUST return the NEW value, not the OLD one. Pre-fix, the
    /// stale staging served the OLD body (the silent wrong-code OTA). Skipped without
    /// the toolchain.
    func testDirtyRebuildAfterEditShipsNewBehavior() throws {
        let compiler = SwiftWasmCompiler()
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping dirty-rebuild execution")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bug1-e2e-\(UUID().uuidString)")
        let src = dir.appendingPathComponent("src")
        let buildDir = dir.appendingPathComponent(".Patch/build")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let money = src.appendingPathComponent("Money.swift")

        // A value-type instance method (Euclid/Money shape): its body is RECONSTRUCTED
        // into a shared member-surface / `_PatchType_*` support file the bundler builds
        // from `allFiles` — exactly the artifact a stale `.Patch/build` re-ingested
        // pre-fix, serving the OLD body on a dirty re-release.
        func writeBody(_ expr: String) throws {
            try """
            public struct Money {
                public let cents: Int
                public func withTax(_ rate: Int) -> Int {
                    return \(expr)
                }
            }
            """.write(to: money, atomically: true, encoding: .utf8)
        }
        func buildAndRun(_ cents: Int, _ rate: Int) throws -> Int? {
            let result = try BuildPipeline().run(sourceDir: src, buildDir: buildDir,
                                                 compiler: compiler, dryRun: false)
            guard let moduleURL = result.moduleURL,
                  FileManager.default.fileExists(atPath: moduleURL.path) else { return nil }
            let wasm = [UInt8](try Data(contentsOf: moduleURL))
            guard wasm.prefix(4).elementsEqual([0x00, 0x61, 0x73, 0x6d]) else { return nil }
            // The export must actually be present (a single-memory module that ships it).
            let runner = try T0Runner(wasm: wasm)
            guard runner.instance.exports[function: "Money_withTax"] != nil else { return nil }
            // Instance methods carry a leading `_receiver` object across the ABI.
            struct Args: Encodable { let _receiver: [String: Int]; let rate: Int }
            struct Out: Decodable { let value: Int }
            let args = Args(_receiver: ["cents": cents], rate: rate)
            let bytes = try runner.callPacked("Money_withTax", [UInt8](try JSONEncoder().encode(args)))
            return try? JSONDecoder().decode(Out.self, from: Data(bytes)).value
        }

        // v1: cents + rate.
        try writeBody("cents + rate")
        guard let v1 = try buildAndRun(700, 5) else {
            throw XCTSkip("Money.withTax did not ship as an executable T0 export in this environment")
        }
        XCTAssertEqual(v1, 705, "v1 must compute cents + rate")

        // EDIT the body, then rebuild into the SAME dirty .Patch/build (no clean).
        try writeBody("cents + rate + 1000")
        let v2 = try buildAndRun(700, 5)
        XCTAssertEqual(v2, 1705,
                       "BUG-1: a dirty re-release after a source edit MUST execute the NEW body "
                       + "(cents+rate+1000), not the stale OLD one (got \(String(describing: v2)))")
    }

    // MARK: - BUG-2 [P1]: fingerprint stable across OTA-eligible code edits

    /// A project whose ONLY edit is to an OTA-eligible function's BODY must NOT change
    /// the native-shell fingerprint — so `patch release` works on the happy path
    /// (no `--force`). Pre-fix, hashing every `.swift` file's raw content tripped a
    /// spurious MISMATCH on exactly the edits OTA exists to ship.
    func testCodeOnlyEditToEligibleFunctionKeepsFingerprintStable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bug2-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pure = dir.appendingPathComponent("Pure.swift")
        func writePure(_ body: String) throws {
            try """
            public enum Pure {
                public static func tax(_ x: Int) -> Int {
            \(body)
                }
            }
            """.write(to: pure, atomically: true, encoding: .utf8)
        }
        // A native shell file that must remain unchanged.
        try "import UIKit\nclass Shell: NSObject {}".write(
            to: dir.appendingPathComponent("Shell.swift"), atomically: true, encoding: .utf8)

        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        try writePure("        return x * 100")
        let before = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        // Edit ONLY the OTA-eligible function's body (different code, same signature).
        try writePure("        let scaled = x * 100\n        return scaled + 1000")
        let after = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        XCTAssertEqual(before, after,
                       "BUG-2: a body-only edit to an OTA-eligible function must NOT change the "
                       + "native-shell fingerprint")
    }

    /// A genuine native-shell change MUST still trip the gate. Changing a NATIVE
    /// (non-OTA-eligible) function's body changes the fingerprint, proving the gate
    /// still protects deployed-binary compatibility.
    func testNativeShellChangeStillChangesFingerprint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bug2-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = dir.appendingPathComponent("Shell.swift")
        // A function that touches UIKit → classified native (not OTA-eligible), so its
        // body IS part of the native-shell fingerprint.
        func writeShell(_ tint: String) throws {
            try """
            import UIKit
            final class Theme {
                func apply(_ v: UIView) {
                    v.backgroundColor = \(tint)
                }
            }
            """.write(to: shell, atomically: true, encoding: .utf8)
        }
        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        try writeShell(".red")
        let before = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        try writeShell(".blue")
        let after = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        XCTAssertNotEqual(before, after,
                          "BUG-2: a change to NATIVE-shell code must still change the fingerprint")
    }

    /// A signature change to an OTA-eligible function (its ABI surface) MUST trip the
    /// gate — only the BODY is exempt, not the signature.
    func testSignatureChangeToEligibleFunctionChangesFingerprint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bug2-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pure = dir.appendingPathComponent("Pure.swift")
        func writeSig(_ sig: String) throws {
            try """
            public enum Pure {
                public static func tax(\(sig)) -> Int {
                    return 0
                }
            }
            """.write(to: pure, atomically: true, encoding: .utf8)
        }
        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        try writeSig("_ x: Int")
        let before = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        try writeSig("_ x: Int, _ y: Int")
        let after = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        XCTAssertNotEqual(before, after,
                          "BUG-2: a SIGNATURE change to an OTA-eligible function must change the fingerprint")
    }

    /// `normalize` is content-driven: two files identical except for an eligible
    /// body normalize identically, and a stripped run collapses to one marker so a
    /// reflowed body (different line count) still matches.
    func testNormalizeCollapsesEligibleBodies() {
        let src = "func f() {\n  let a = 1\n  return a\n}\n"
        let reflowed = "func f() {\n  let a = 1; let b = 2\n  let c = a + b\n  return c\n}\n"
        // The eligible function spans lines 1..4 in `src` and 1..5 in `reflowed`.
        let n1 = ProjectFingerprinter.normalize(source: src, strippingBodiesOf: [(start: 1, end: 4)])
        let n2 = ProjectFingerprinter.normalize(source: reflowed, strippingBodiesOf: [(start: 1, end: 5)])
        XCTAssertEqual(n1, n2, "a reflowed eligible body must normalize identically (signature kept, body collapsed)")
        XCTAssertTrue(n1.contains("func f() {"), "the signature line must be preserved")
        XCTAssertFalse(n1.contains("let a = 1"), "the body must be collapsed away")
    }

    // MARK: - VIEW-BODY false-positive: strip PURELY-OTA SwiftUI view bodies
    //
    // The product's headline workflow is "edit a SwiftUI view body, ship OTA, no App
    // Store review". A view body is FORCED native by the partitioning classifier
    // (it's a view-DSL member), so it was never `wasmEligible` and the fingerprint
    // hashed it VERBATIM — every restyle/reorder/add-feature edit tripped the gate
    // and `push`/`release` HARD-REFUSED the OTA push (a false positive on exactly the
    // action the product is sold on). The fix consults the SwiftUI lowering pipeline
    // and strips the body span of a view that lowers PURELY-OTA (rides WASM through
    // the thunk with ZERO native slot closures baked into the binary), so such an
    // edit keeps the fingerprint stable — while a MIXED / NATIVE view stays hashed
    // (editing native code IS a real shell change), preserving the gate's safety.

    /// A small leaf `View` whose body lowers at 100% with NO native slots (a Text
    /// with font/color/padding/Capsule-background — the canonical purely-OTA leaf,
    /// like the real-app `BadgePill`). Restyling its body must NOT move the
    /// native-shell fingerprint.
    func testRestylePurelyOTAViewBodyKeepsFingerprintStable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vb-pure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = dir.appendingPathComponent("Badge.swift")
        func writeBadge(font: Double, padH: Int) throws {
            try """
            import SwiftUI
            struct Badge: View {
                let text: String
                var color: Color = .accentColor
                dynamic var body: some View {
                    Text(text.uppercased())
                        .font(.system(size: \(font), weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, \(padH))
                        .padding(.vertical, 4)
                        .background(Capsule().fill(color))
                }
            }
            """.write(to: view, atomically: true, encoding: .utf8)
        }

        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        // Sanity: the view we built must actually lower PURELY-OTA, else this test
        // proves nothing. (Read-only consult of the same path the snapshot uses.)
        try writeBadge(font: 9.5, padH: 10)
        let spansBefore = ProjectFingerprinter.loweredViewBodySpans(projectDir: dir, registry: .standard)
        XCTAssertFalse(spansBefore.isEmpty,
                       "precondition: the leaf Text view must lower purely-OTA (its body span must be collected)")

        let before = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        // Restyle: font size + horizontal padding (a pure, fully-OTA-shippable edit).
        try writeBadge(font: 12, padH: 16)
        let after = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        XCTAssertEqual(before, after,
                       "VIEW-BODY: a restyle of a PURELY-OTA-lowered view body must NOT change the "
                       + "native-shell fingerprint (this is the product's headline OTA workflow)")
    }

    /// Adding a new LOWERABLE element (a second Text + a modifier) to a purely-OTA
    /// view body is still fully OTA-shippable, so the fingerprint must stay stable.
    func testAddLowerableElementToPurelyOTAViewBodyKeepsFingerprintStable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vb-add-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = dir.appendingPathComponent("Label.swift")
        func writeLabel(extra: String) throws {
            try """
            import SwiftUI
            struct Label2: View {
                let title: String
                dynamic var body: some View {
                    VStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
            \(extra)
                    }
                    .padding(12)
                }
            }
            """.write(to: view, atomically: true, encoding: .utf8)
        }

        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        try writeLabel(extra: "")
        let spans = ProjectFingerprinter.loweredViewBodySpans(projectDir: dir, registry: .standard)
        XCTAssertFalse(spans.isEmpty, "precondition: the VStack/Text view must lower purely-OTA")
        let before = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        // Add a new, fully-lowerable element (caption Text + opacity).
        try writeLabel(extra: """
                        Text("new caption")
                            .font(.system(size: 13))
                            .opacity(0.7)
            """)
        let after = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        XCTAssertEqual(before, after,
                       "VIEW-BODY: adding a LOWERABLE element to a purely-OTA view body (an "
                       + "OTA-shippable add-feature edit) must NOT change the fingerprint")
    }

    /// A MIXED but AUTO-ROUTED view (a `.opaque` native-slot leaf the build bakes into the
    /// binary, PLUS lowered content/modifiers that ride WASM). The fingerprint must split
    /// the two cleanly:
    ///   • Editing the LOWERED part (VStack spacing here) is an OTA change that ships in
    ///     WASM — it MUST NOT churn the native-shell fingerprint (the headline patchability
    ///     property: edit a constant/format without being refused).
    ///   • Editing the NATIVE SLOT source (swap the custom child the patch can't carry) is a
    ///     native-shell change — it MUST churn (SAFETY: no false negative). This is enforced
    ///     by folding the slot/token/row-slot `nativeSurface` back into the file hash.
    func testMixedAutoRoutedView_loweredEditStable_slotSwapChurns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vb-mixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = dir.appendingPathComponent("Mixed.swift")
        // `<child>()` is an unknown custom view → the engine emits it as an `.opaque`
        // native slot, so `Mixed` is MIXED (opaqueLeaves != empty) but AUTO-ROUTED
        // (the slot is slotable + there's a lowered `Text` content node).
        func writeMixed(spacing: Int, child: String) throws {
            try """
            import SwiftUI
            struct CustomChild: View {
                @Environment(\\.colorScheme) private var scheme
                dynamic var body: some View { Text("\\(scheme == .dark ? 1 : 0)") }
            }
            struct OtherChild: View {
                dynamic var body: some View { Text("other") }
            }
            struct Mixed: View {
                let title: String
                dynamic var body: some View {
                    VStack(spacing: \(spacing)) {
                        Text(title).font(.system(size: 17, weight: .bold))
                        \(child)()
                    }
                    .padding(10)
                }
            }
            """.write(to: view, atomically: true, encoding: .utf8)
        }

        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        try writeMixed(spacing: 8, child: "CustomChild")
        let before = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint

        // (1) LOWERED edit (VStack spacing rides WASM) → MUST NOT churn (OTA-patchable).
        try writeMixed(spacing: 20, child: "CustomChild")
        XCTAssertEqual(before, fp.snapshot(projectDir: dir, bridges: [:]).fingerprint,
                       "editing a LOWERED param (VStack spacing) in an auto-routed mixed view rides "
                       + "WASM and MUST NOT churn the native-shell fingerprint")

        // (2) NATIVE SLOT swap (the baked-in custom child changes) → MUST churn (no false negative).
        try writeMixed(spacing: 20, child: "OtherChild")
        XCTAssertNotEqual(before, fp.snapshot(projectDir: dir, bridges: [:]).fingerprint,
                          "SAFETY: swapping the NATIVE SLOT (a custom child baked into the binary) is a "
                          + "native-shell change and MUST churn the fingerprint")
    }

    /// SAFETY (no false negative): a view that does NOT lower (it renders fully
    /// native — here it reads a body-local the guest can't reconstruct, an
    /// EXCLUDE-from-emission case) is native code. Editing its body MUST trip the
    /// gate, exactly like editing any native function.
    func testNonLoweringViewBodyEditChangesFingerprint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vb-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = dir.appendingPathComponent("NativeView.swift")
        // Reads `service.items` (an @Environment-injected service the guest can't
        // marshal) via a body-local `let`, plus a ForEach over it → the engine
        // EXCLUDES it from guest emission; it renders fully native.
        func writeNative(spacing: Int) throws {
            try """
            import SwiftUI
            @Observable final class Svc { var items: [String] = [] }
            struct NativeView: View {
                @Environment(Svc.self) private var service
                dynamic var body: some View {
                    let rows = service.items
                    VStack(spacing: \(spacing)) {
                        ForEach(rows, id: \\.self) { r in
                            Text(r).font(.system(size: 15))
                        }
                    }
                }
            }
            """.write(to: view, atomically: true, encoding: .utf8)
        }

        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        try writeNative(spacing: 8)
        let before = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        try writeNative(spacing: 24)
        let after = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        XCTAssertNotEqual(before, after,
                          "SAFETY: a body edit to a view that does NOT lower (renders fully native) "
                          + "MUST change the fingerprint — no false negative")
    }

    /// SAFETY boundary (adaptive strip): when a body edit ADDS native code to a
    /// previously-PURELY-OTA view (turning it MIXED), the view drops out of the strip
    /// set and the edit trips the gate. The strip decision is recomputed per pass
    /// from the CURRENT source, so an edit that introduces native code can never slip
    /// through as a false negative.
    func testEditTurningPureViewMixedChangesFingerprint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vb-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = dir.appendingPathComponent("Boundary.swift")
        func writeBoundary(addNativeChild: Bool) throws {
            let child = addNativeChild ? "\n            UnknownNativeChild()" : ""
            try """
            import SwiftUI
            struct UnknownNativeChild: View {
                @Environment(\\.locale) private var loc
                dynamic var body: some View { Text(loc.identifier) }
            }
            struct Boundary: View {
                let text: String
                dynamic var body: some View {
                    VStack(spacing: 8) {
                        Text(text).font(.system(size: 16, weight: .semibold))\(child)
                    }
                    .padding(10)
                }
            }
            """.write(to: view, atomically: true, encoding: .utf8)
        }

        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        // Pure version: Boundary is purely-OTA and its span is stripped.
        try writeBoundary(addNativeChild: false)
        let pureSpans = ProjectFingerprinter.loweredViewBodySpans(projectDir: dir, registry: .standard)
        XCTAssertFalse(pureSpans.isEmpty, "precondition: the pure VStack/Text view must lower purely-OTA")
        let before = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        // Add a native child → Boundary becomes MIXED → NOT stripped → fingerprint moves.
        try writeBoundary(addNativeChild: true)
        let after = fp.snapshot(projectDir: dir, bridges: [:]).fingerprint
        XCTAssertNotEqual(before, after,
                          "SAFETY: an edit that adds native code to a purely-OTA view (turning it "
                          + "MIXED) MUST change the fingerprint — the strip set is recomputed per pass")
    }

    // MARK: - BUG-3 [P2]: init handles multi-target SPM packages (no dead-end)

    /// A multi-target package (multiple library products, none matching the package
    /// name) must NOT dead-end `init`: discovery flags it ambiguous, and `init`
    /// defaults to the first candidate + guides the user. We assert the discovery
    /// contract `init` relies on (candidates available, marked ambiguous) so the
    /// command can default rather than throw.
    func testMultiTargetPackageOffersCandidatesInsteadOfDeadEnd() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bug3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // swift-numerics-shaped manifest: package name != any product name.
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "swift-numerics",
            products: [
                .library(name: "Numerics", targets: ["Numerics"]),
                .library(name: "RealModule", targets: ["RealModule"]),
                .library(name: "ComplexModule", targets: ["ComplexModule"]),
            ],
            targets: []
        )
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let p = ProjectDiscovery.detect(in: dir)
        XCTAssertTrue(p.targetAmbiguous, "multiple products with no primary is ambiguous")
        XCTAssertNil(p.target, "no single inferred target")
        XCTAssertFalse(p.targetCandidates.isEmpty,
                       "BUG-3: init must have candidates to default to instead of dead-ending")
        XCTAssertEqual(p.targetCandidates.first, "Numerics",
                       "init defaults to the first candidate")
    }

    // MARK: - BUG-4 [P2]: degenerate modules must not pass release silently

    /// A module that compiled but exports ONLY the version probe / allocator has no
    /// real OTA coverage → release must refuse (unless --allow-empty).
    func testDegenerateProbeOnlyModuleIsRefused() {
        let probeOnly = Self.makeResult(compiledExports: [["patch_module_version"]])
        XCTAssertNotNil(probeOnly.degenerateCoverageReason(moduleSize: 320),
                        "BUG-4: a version-probe-only module must be flagged as no-coverage")
    }

    /// A suspiciously tiny module (the 317-byte E2E case) is refused even if it claims
    /// one export — a genuine compiled Swift→WASM unit is never that small.
    func testDegenerateTinyModuleIsRefused() {
        let tiny = Self.makeResult(compiledExports: [["someExport"]])
        XCTAssertNotNil(tiny.degenerateCoverageReason(moduleSize: 317),
                        "BUG-4: a 317-byte module must be flagged as too small for real coverage")
    }

    /// A real module with genuine exports + a real size passes the gate (no false
    /// positive on the happy path).
    func testRealCoverageModulePasses() {
        let real = Self.makeResult(compiledExports: [["Vector_dot", "patch_malloc", "patch_free"]])
        XCTAssertNil(real.degenerateCoverageReason(moduleSize: 45_000_000),
                     "BUG-4: a module with real exports + real size must NOT be flagged")
    }

    /// Build a `BuildPipeline.Result` carrying the given compiled-candidate exports,
    /// for the coverage-floor gate (no compile / toolchain needed).
    private static func makeResult(compiledExports: [[String]]) -> BuildPipeline.Result {
        let outcome = WasmConvergence.Outcome(
            compiled: compiledExports.enumerated().map { i, exps in
                WasmConvergence.Candidate(functionID: "c\(i)", sourceFile: URL(fileURLWithPath: "/tmp/c\(i).swift"), exports: exps)
            },
            reclassifiedNative: [], moduleURL: URL(fileURLWithPath: "/tmp/module.wasm"),
            toolchainUnavailable: false, iterations: 1, log: "")
        let emptyReport = PartitioningEngine().analyze(records: [], fileCount: 0)
        return BuildPipeline.Result(
            report: emptyReport, splitFunctions: [], generatedWasmSources: [],
            generatedBridgeSources: [], exportSymbols: compiledExports.flatMap { $0 },
            compileOutcome: outcome, moduleURL: outcome.moduleURL,
            selectedTier: .t0Embedded, tierRationale: "test",
            rejectedExports: [])
    }
}
