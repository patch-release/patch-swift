// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler
import PartitioningEngine
import CodeGenerator

/// Round-2 fingerprint/build bug fixes (P4-Fingerprint-Build partition). Each test asserts
/// the CORE INVARIANT: the native-shell fingerprint must CHURN on a real native-code change
/// and stay STABLE on a benign OTA-patchable edit — and, the dominant R2 theme, must NEVER
/// be FALSE-STABLE (strip a body the build dropped to native, so a real native edit looks
/// OTA-benign and a stale binary mismatch ships).
final class FingerprintRound2Tests: XCTestCase {

    private func tmpRoot(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-fp2-\(tag)-\(UUID().uuidString)")
    }
    private func write(_ root: URL, _ rel: String, _ contents: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: u, atomically: true, encoding: .utf8)
    }
    /// Write a `shipped-ota.json` manifest at the conventional `.Patch/build/` location.
    private func writeManifest(_ root: URL, views: [String] = [], cells: [String] = [],
                              generalTrusted: Bool = true) throws {
        let m = ShippedOTAManifest(shippedSwiftUIViews: views, shippedUIKitCells: cells,
                                   generalLogicTrusted: generalTrusted)
        let dir = root.appendingPathComponent(".Patch/build")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(m).write(to: dir.appendingPathComponent(ShippedOTAManifest.fileName))
    }

    // MARK: - R2-#13: UIKit thunk file must be excluded from the native-shell hash

    func testUIKitThunkFileExcludedFromFingerprint() throws {
        let root = tmpRoot("uikitthunk")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "App/Foo.swift", "import UIKit\nfinal class Foo: UIView {}\n")
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()
        // prepare writes the UIKit thunk file into the source tree — it is regenerated
        // scaffolding, NOT the developer's shell, so it must not churn the fingerprint.
        try write(root, "App/\(UIKitThunkGenerator.thunkFileName)",
                  "// generated\nextension Foo {}\n")
        XCTAssertEqual(fp(), base,
            "the generated UIKit thunk file must be excluded from the native-shell hash (no false MISMATCH)")
    }

    // MARK: - R2-#14: stripInsertedDynamicModifier covers setupViews/viewDidLoad/etc.

    func testStripInsertedDynamicHandlesUIKitSetupMethods() {
        // prepare inserts `dynamic` before a programmatic-VC construction method. Stripping
        // it must make the line invariant to that insertion for the full method-name set.
        for name in ["setupViews", "viewDidLoad", "setupUI", "buildViews", "commonInit", "configure"] {
            let withDyn = "    dynamic func \(name)() {"
            let without = "    func \(name)() {"
            XCTAssertEqual(ProjectFingerprinter.stripInsertedDynamicModifier(withDyn), without,
                "inserted `dynamic` before \(name)() must be stripped so the hash is prepare-invariant")
        }
        // `var body` still handled.
        XCTAssertEqual(
            ProjectFingerprinter.stripInsertedDynamicModifier("    dynamic var body: some View {"),
            "    var body: some View {")
        // A developer's OWN dynamic func with a non-construction name is left intact.
        let unrelated = "    dynamic func handleTap() {"
        XCTAssertEqual(ProjectFingerprinter.stripInsertedDynamicModifier(unrelated), unrelated,
            "a developer dynamic func that is not a construction method must be left as-is")
    }

    // MARK: - R2-#37: a native app file named *Test/*Spec must NOT be excluded

    func testSingularTestSuffixAppFileIsHashed() throws {
        let root = tmpRoot("abtest")
        defer { try? FileManager.default.removeItem(at: root) }
        // A real NATIVE app file named ABTest.swift (singular `Test`) with no test imports.
        // The function calls a NATIVE symbol (UserDefaults) so its body is NOT wasmEligible —
        // i.e. it's genuine native shell whose edit MUST churn (the point of #37).
        try write(root, "App/ABTest.swift", """
        import Foundation
        enum ABTest {
            static func bucket(_ id: Int) -> Int {
                UserDefaults.standard.integer(forKey: "ab_\\(id)")
            }
        }
        """)
        let file = root.appendingPathComponent("App/ABTest.swift")
        // It must NOT be classified as a test file (no test path segment, no test import).
        XCTAssertFalse(SwiftParserEngine.isTestFile(file),
            "a native app file named ABTest.swift (no test import) must NOT be excluded as a test")
        // Editing its NATIVE body MUST churn the fingerprint (no false-stable).
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()
        var s = try String(contentsOf: file, encoding: .utf8)
        s = s.replacingOccurrences(of: #""ab_\(id)""#, with: #""bucket_\(id)""#)
        try s.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "editing native code in ABTest.swift must churn the fingerprint (it ships in the app binary)")
    }

    func testGenuineTestFileStillDetected() throws {
        let root = tmpRoot("realtest")
        defer { try? FileManager.default.removeItem(at: root) }
        // A genuine single-`Test`-suffixed file that imports XCTest is still a test.
        try write(root, "App/FeatureTest.swift", """
        import XCTest
        final class FeatureTest: XCTestCase { func testX() {} }
        """)
        XCTAssertTrue(
            SwiftParserEngine.isTestFile(root.appendingPathComponent("App/FeatureTest.swift")),
            "a real single-Test file importing XCTest must still be detected as a test")
        // Plural Tests suffix is still detected by basename alone.
        try write(root, "App/WidgetTests.swift", "struct WidgetTests {}\n")
        XCTAssertTrue(
            SwiftParserEngine.isTestFile(root.appendingPathComponent("App/WidgetTests.swift")),
            "the plural Tests suffix stays a basename-only test signal")
    }

    // MARK: - R2-#127: stripPatchScaffolding must match the EXACT marker + require END

    func testStrayBeginPrefixDoesNotEatRealCode() {
        // A developer comment that merely BEGINS with the short prefix must NOT be treated
        // as the generated begin marker and drop all following real code.
        let src = """
        // PATCH-THUNKS-BEGIN region for clarity
        let secret = computeNative()
        func realNativeThing() { fatalError() }
        """
        let out = ProjectFingerprinter.stripPatchScaffolding(src)
        XCTAssertTrue(out.contains("computeNative()"),
            "a stray `// PATCH-THUNKS-BEGIN …` comment must not drop real native code")
        XCTAssertTrue(out.contains("realNativeThing"))
    }

    func testExactGeneratedMarkerBlockIsStripped() {
        // The EXACT generated marker block (with a matching END) is stripped.
        let src = """
        struct Keep {}
        \(ThunkGenerator.sameFileBeginMarker)
        extension Keep { @_dynamicReplacement(for: body) var __patch_body: some View { body } }
        \(ThunkGenerator.sameFileEndMarker)
        struct AlsoKeep {}
        """
        let out = ProjectFingerprinter.stripPatchScaffolding(src)
        XCTAssertTrue(out.contains("struct Keep"))
        XCTAssertTrue(out.contains("struct AlsoKeep"))
        XCTAssertFalse(out.contains("__patch_body"),
            "the exact generated thunk block must be stripped")
    }

    func testUnterminatedExactMarkerStripsNothing() {
        // A begin marker with NO matching end (a truncated paste) must strip NOTHING — never
        // eat real source to EOF.
        let src = """
        \(ThunkGenerator.sameFileBeginMarker)
        let realCodeAfterTruncatedBegin = 1
        func native() {}
        """
        let out = ProjectFingerprinter.stripPatchScaffolding(src)
        XCTAssertTrue(out.contains("realCodeAfterTruncatedBegin"),
            "an unterminated begin marker must not drop real code to EOF")
        XCTAssertTrue(out.contains("func native"))
    }

    // MARK: - R2-#95: a view whose name collides with a non-View struct is not stripped

    func testViewWithSameNamedModelStructNotStripped() throws {
        let root = tmpRoot("dupname")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "App/ProfileView.swift", """
        import SwiftUI
        struct Profile: View { var body: some View { Text("hi").padding(8) } }
        """)
        try write(root, "App/Model.swift", """
        import Foundation
        struct Profile: Codable { let name: String }
        """)
        // prepare won't thunk `Profile` (2 top-level struct decls) → renders native →
        // editing its body MUST churn (no false-stable). No manifest present → static path.
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()
        let view = root.appendingPathComponent("App/ProfileView.swift")
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #"Text("hi")"#, with: #"Text("hello")"#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "a View whose name has a same-named non-View struct gets no thunk — its body edit must churn")
    }

    func testThunkIneligibleViewNamesDetectsDuplicate() {
        let a = "struct Profile: View { var body: some View { Text(\"a\") } }"
        let b = "struct Profile: Codable { let name: String }"
        let c = "struct Other { let x = 1 }"
        let names = BuildPipeline.thunkIneligibleViewNames(sources: [a, b, c])
        XCTAssertTrue(names.contains("Profile"), "a name with 2+ top-level struct decls is ineligible")
        XCTAssertFalse(names.contains("Other"), "a singly-declared struct is eligible")
    }

    // MARK: - R2-#9/#34/#35/#36: build-confirmed shipped set gates the view-body strip

    private func makeLowerableViewProject(_ tag: String) throws -> URL {
        let root = tmpRoot(tag)
        try write(root, "App/Card.swift", """
        import SwiftUI
        struct Card: View {
            var body: some View {
                VStack {
                    Text("Title")
                    Text("Body")
                }
            }
        }
        """)
        return root
    }

    func testManifestPresentAndShipped_BodyEditStable() throws {
        let root = try makeLowerableViewProject("shipped")
        defer { try? FileManager.default.removeItem(at: root) }
        // Sanity: Card auto-routes statically (else the test proves nothing).
        let auto = ProjectFingerprinter.loweredAutoRoutedViewData(projectDir: root, registry: .standard)
        try XCTSkipUnless(auto.bodySpansByFile.values.contains(where: { !$0.isEmpty }),
            "Card did not auto-route in this engine build — skip")
        // Manifest says Card SHIPPED → its body rides WASM → a body edit is STABLE.
        try writeManifest(root, views: ["Card"])
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()
        let view = root.appendingPathComponent("App/Card.swift")
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #"Text("Title")"#, with: #"Text("Changed")"#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "with the build manifest confirming Card shipped OTA, a body edit must NOT churn")
    }

    func testManifestPresentButNotShipped_BodyEditChurns() throws {
        let root = try makeLowerableViewProject("dropped")
        defer { try? FileManager.default.removeItem(at: root) }
        let auto = ProjectFingerprinter.loweredAutoRoutedViewData(projectDir: root, registry: .standard)
        try XCTSkipUnless(auto.bodySpansByFile.values.contains(where: { !$0.isEmpty }),
            "Card did not auto-route in this engine build — skip")
        // THE FALSE-STABLE CASE: the static gate predicted Card auto-routes, but the build
        // DROPPED it to native (it is NOT in the manifest's shipped set). Its body must stay
        // hashed → a body edit MUST churn (forcing the native update the device needs).
        try writeManifest(root, views: [])   // built, but shipped ZERO views
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()
        let view = root.appendingPathComponent("App/Card.swift")
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #"Text("Title")"#, with: #"Text("Changed")"#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "FALSE-STABLE GUARD: a view the build dropped to native must keep its body hashed → edit churns")
    }

    // MARK: - R2-#10: general-logic strip gated on a clean build

    func testGeneralLogicUntrustedKeepsBodiesHashed() throws {
        let root = tmpRoot("general")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "App/Calc.swift", """
        import Foundation
        func price(for n: Int) -> Int { n * 2 + 1 }
        """)
        // Sanity: price() is wasmEligible (else nothing to test).
        let spansClean = ProjectFingerprinter.otaEligibleBodySpans(projectDir: root, registry: .standard)
        try XCTSkipUnless(spansClean.values.contains(where: { !$0.isEmpty }),
            "price() is not wasmEligible in this engine build — skip")
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let calc = root.appendingPathComponent("App/Calc.swift")
        func editBody() throws {
            var s = try String(contentsOf: calc, encoding: .utf8)
            s = s.replacingOccurrences(of: "n * 2 + 1", with: "n * 3 + 7")
            try s.write(to: calc, atomically: true, encoding: .utf8)
        }
        // (a) Manifest: general logic TRUSTED (clean build) → body strip applies → STABLE.
        try writeManifest(root, generalTrusted: true)
        let baseTrusted = fp()
        try editBody()
        XCTAssertEqual(fp(), baseTrusted,
            "clean general build → a wasmEligible body edit rides WASM → no churn")
        // (b) Manifest: general logic UNTRUSTED (a demotion/CORE failure) → bodies hashed
        //     verbatim → the same edit MUST churn (no false-stable).
        // reset body
        var s = try String(contentsOf: calc, encoding: .utf8)
        s = s.replacingOccurrences(of: "n * 3 + 7", with: "n * 2 + 1")
        try s.write(to: calc, atomically: true, encoding: .utf8)
        try writeManifest(root, generalTrusted: false)
        let baseUntrusted = fp()
        try editBody()
        XCTAssertNotEqual(fp(), baseUntrusted,
            "FALSE-STABLE GUARD: untrusted general build → wasmEligible bodies stay hashed → edit churns")
    }

    // MARK: - R2-#11: UIKit cell strip gated on the build-shipped set

    func testUIKitCellNotShipped_BodyEditChurns() throws {
        let root = tmpRoot("cellnotshipped")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "App/ProductCell.swift", """
        import UIKit
        struct ProductModel { var title: String }
        final class ProductCell: UITableViewCell {
            let titleLabel = UILabel()
            func configure(with model: ProductModel) {
                contentView.addSubview(titleLabel)
                titleLabel.text = model.title
                titleLabel.textColor = .label
            }
        }
        """)
        let cellSrc = try String(
            contentsOf: root.appendingPathComponent("App/ProductCell.swift"), encoding: .utf8)
        try XCTSkipUnless(
            UIKitCellLowering().lowerAllCells(source: cellSrc)
                .contains(where: { $0.typeName == "ProductCell" && !$0.referencesUnmarshalledInput }),
            "ProductCell did not lower — skip")
        // Manifest present but the cell was NOT shipped (the single UIKit wrapper demoted) →
        // its configure(with:) renders native → editing it MUST churn.
        try writeManifest(root, cells: [])
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()
        let cell = root.appendingPathComponent("App/ProductCell.swift")
        var s = try String(contentsOf: cell, encoding: .utf8)
        s = s.replacingOccurrences(of: "titleLabel.textColor = .label",
                                   with: "titleLabel.textColor = .secondaryLabel")
        try s.write(to: cell, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "FALSE-STABLE GUARD: a UIKit cell the build dropped to native must keep its body hashed → edit churns")
    }

    // MARK: - R2-#12: a demoted (native) view's slot literals stay hashed

    func testNonAutoRoutedViewSlotLiteralChurns() throws {
        let root = tmpRoot("slotlit")
        defer { try? FileManager.default.removeItem(at: root) }
        // CardView demotes to NATIVE (an undispatchable `.task` effect), so its slotted
        // `DisplayText(text: "Welcome")` renders from the SIGNED binary — editing the
        // literal IS a native change and must churn (the #12 false-stable guard). Sanity:
        // confirm it really does NOT auto-route in this engine build first.
        let src = """
        import SwiftUI
        struct DisplayText: View { let text: String; var body: some View { Text(text) } }
        struct CardView: View {
            var body: some View {
                VStack {
                    DisplayText(text: "Welcome")
                    Text("hi")
                }
                .task { await loadStuff() }
            }
            func loadStuff() async {}
        }
        """
        try write(root, "App/CardView.swift", src)
        let lowered = BodyLowering().lowerAllViews(
            source: src, sameFileThunk: true, crossFile: BodyLowering.crossFileBundle(sources: [src]))
        let card = lowered.first { $0.viewName == "CardView" }
        try XCTSkipUnless(card != nil && !ProjectFingerprinter.isAutoRouted(card!, collidingBases: []),
            "CardView unexpectedly auto-routes in this engine build — skip (test is about the demoted case)")
        try XCTSkipUnless(card!.opaqueLeaves.contains(where: { !$0.stringArgRanges.isEmpty }),
            "CardView's slot has no lifted literal in this engine build — skip")
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()
        let view = root.appendingPathComponent("App/CardView.swift")
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #""Welcome""#, with: #""Hello""#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "a slot literal in a NATIVE-rendered (non-auto-routed) view must stay hashed → edit churns")
    }

    // MARK: - P0-A no-over-correction: auto-routed view's lifted literal STILL stays stable

    /// Regression guard: after the P0-A fix, a FULLY AUTO-ROUTED view (all leaves slotable,
    /// thunkSafe=true) with a lifted string literal must STILL be fingerprint-stable — the
    /// fix must not over-correct and block OTA edits that genuinely ride WASM.
    func testAutoRoutedLiftedLiteralIsStillStable() throws {
        let root = tmpRoot("autorouted-lit-stable")
        defer { try? FileManager.default.removeItem(at: root) }
        // A view where the ONLY opaque leaf (DisplayText) is slotable (no body-local reads).
        // Its `text:` arg is a plain string literal → lifted into stringArgs.
        // The view IS auto-routed (all leaves slotable) → the lifted literal MUST normalize.
        let src = """
        import SwiftUI
        struct DisplayText: View { let text: String; var body: some View { Text(text) } }
        struct CardView: View {
            var title: String
            var body: some View {
                VStack {
                    DisplayText(text: "Settings")
                    Text(title)
                }
            }
        }
        """
        try write(root, "App/CardView.swift", src)
        let lb = BodyLowering()
        let cf = BodyLowering.crossFileBundle(sources: [src])
        let views = lb.lowerAllViews(source: src, sameFileThunk: true, crossFile: cf)
        let card = views.first { $0.viewName == "CardView" }
        try XCTSkipUnless(card != nil, "CardView did not lower — skip")
        try XCTSkipUnless(ProjectFingerprinter.isAutoRouted(card!, collidingBases: []),
            "CardView does not auto-route in this build — skip (test is about the auto-routed case)")
        try XCTSkipUnless(card!.opaqueLeaves.contains(where: { !$0.stringArgRanges.isEmpty }),
            "CardView has no lifted string literal — skip (engine changed)")
        // Manifest: CardView shipped.
        try writeManifest(root, views: ["CardView"])
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()
        let view = root.appendingPathComponent("App/CardView.swift")
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #""Settings""#, with: #""Preferences""#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "NO-OVER-CORRECTION: editing a lifted literal in a FULLY AUTO-ROUTED view "
            + "(all leaves slotable, thunkSafe=true) must still be fingerprint-STABLE "
            + "after the P0-A fix — that literal genuinely rides WASM (OTA-deliverable)")
    }

    // MARK: - P0: non-slotable-leaf slot literal must produce MISMATCH (silent-drop guard)

    /// The user P0 bug: `OnboardingFlow.var body` calls a custom `-> some View` helper
    /// (e.g. `onboardingContent(title: "Plan the day") { … }`) where the `body:` trailing
    /// closure references a body-local let binding, making the leaf non-slotable.
    /// `isAutoRouted=false` because `!opaqueLeaves.allSatisfy({ $0.slotable })`.
    /// Before the fix: the `title:` string range is NOT normalized → editing `"Plan the day"`
    /// P0-A SILENT-DROP GUARD: a non-thunkSafe view (non-slotable leaf) with a lifted
    /// string literal must produce a FINGERPRINT CHURN (MISMATCH) when that literal is
    /// edited — NOT fingerprint stability. The view renders from the ORIGINAL NATIVE body
    /// (the SDK's `entryIfPatchable` returns nil for thunkSafe=false), so its WASM
    /// `slotArgs` are never consumed on-device. Normalizing the literal byte ranges would
    /// cause a SILENT DROP: `release` reports ✓ compatible but the device always renders
    /// the OLD compiled-in literal. A MISMATCH is the safe failure — the dev knows to
    /// rebuild the native binary. A genuinely-native edit still churns too.
    func testNonSlotableLeafParamLiteralChurns() throws {
        let root = tmpRoot("paramlit-churns")
        defer { try? FileManager.default.removeItem(at: root) }
        // A view whose `page(title:content:)` helper has a non-slotable trailing closure
        // (the closure captures body-local `note`) BUT a lifted `title:` string literal.
        // The view also has `Text("Content").padding()` which lowers normally (ensures
        // totalElements > 0 and that the view isn't excluded from WASM emission).
        let src = """
        import SwiftUI
        struct MyView: View {
            var body: some View {
                let note = "extra"
                VStack {
                    Text("Content").padding()
                    page(title: "Plan the day") { Text(note) }
                }
            }
            func page(title: String, @ViewBuilder content: () -> some View) -> some View {
                VStack { Text(title); content() }
            }
        }
        """
        let nativeSrc = """
        import Foundation
        func fetchConfig(key: String) -> String {
            UserDefaults.standard.string(forKey: key) ?? ""
        }
        """
        try write(root, "App/MyView.swift", src)
        try write(root, "App/NativeConfig.swift", nativeSrc)

        // Sanity: confirm MyView has a non-slotable leaf with stringArgRanges (else skip).
        let lb = BodyLowering()
        let cf = BodyLowering.crossFileBundle(sources: [src, nativeSrc])
        let views = lb.lowerAllViews(source: src, sameFileThunk: true, crossFile: cf)
        let mv = views.first { $0.viewName == "MyView" }
        try XCTSkipUnless(mv != nil, "MyView did not lower in this engine build — skip")
        let hasNonSlotableWithRanges = mv!.opaqueLeaves.contains {
            !$0.slotable && !$0.stringArgRanges.isEmpty
        }
        try XCTSkipUnless(hasNonSlotableWithRanges,
            "MyView has no non-slotable leaf with lifted string literal — skip (engine changed)")
        // Also confirm isAutoRouted=false (it's specifically the non-slotable-leaf case).
        try XCTSkipUnless(!ProjectFingerprinter.isAutoRouted(mv!, collidingBases: []),
            "MyView unexpectedly auto-routes — skip (this test is about the non-auto-routed case)")
        // Confirm that loweredParameterizedSlotLiteralRanges returns NO ranges for this
        // non-thunkSafe view file — the P0-A fix means non-slotable-leaf views don't
        // normalize their literals (they churn, preventing a silent drop).
        let litRanges = ProjectFingerprinter.loweredParameterizedSlotLiteralRanges(projectDir: root, registry: .standard)
        let viewFileKey = root.appendingPathComponent("App/MyView.swift").standardizedFileURL.path
        XCTAssertNil(litRanges[viewFileKey],
            "P0-A: a non-thunkSafe view's literal ranges must NOT be normalized "
            + "(normalizing causes silent drop — WASM slotArgs never consumed on-device)")

        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()

        // PART 1 — editing the slot-arg title literal MUST churn (MISMATCH, not silent drop).
        // The view is non-thunkSafe → always renders native → WASM slotArgs never consumed.
        // Normalizing the literal would cause a silent drop; churning is the safe behavior.
        let view = root.appendingPathComponent("App/MyView.swift")
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #""Plan the day""#, with: #""Plan the YEAR""#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "P0-A SILENT-DROP GUARD: editing a lifted literal in a NON-thunkSafe view must "
            + "CHURN the fingerprint (MISMATCH) — the device always renders the native body "
            + "with the OLD literal; a stable fingerprint here causes a silent drop")

        // Restore, then check PART 2 — a genuine native edit also churns (sanity).
        s = s.replacingOccurrences(of: #""Plan the YEAR""#, with: #""Plan the day""#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        let baseRestored = fp()
        XCTAssertEqual(baseRestored, base, "restoring the literal must restore the fingerprint")

        let native = root.appendingPathComponent("App/NativeConfig.swift")
        var ns = try String(contentsOf: native, encoding: .utf8)
        ns = ns.replacingOccurrences(of: #"?? """#, with: #"?? "default""#)
        try ns.write(to: native, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), baseRestored,
            "editing a genuinely-native function body (UserDefaults call) MUST churn the fingerprint")
    }

    // MARK: - R2-#33: support-region compile failure attributes to the dependent views only

    func testViewsBlamedByCompileError_SupportSymbolAttribution() {
        // Two per-view regions in the wrapper. A compile error in a SHARED support symbol
        // (`_PatchRow_Item`) names a line OUTSIDE both regions → the line-based blame finds
        // nothing → the content fallback must blame ONLY the view whose region references it.
        let wrapper = """
        // line 1 preamble
        // Build the lowered `Healthy` tree from a flat state/inputs JSON blob.
        let a = Text("ok")
        // Build the lowered `Broken` tree from a flat state/inputs JSON blob.
        let rows = _patchScanItemRowArray(s, "items") as [_PatchRow_Item]
        // support region (no view marker) below
        struct _PatchRow_Item { let x: Int }
        """
        // Error blames a support-region line (line 7) — owned by no view region.
        let log = "_PatchSwiftUI.swift:7:10: error: cannot find type '_PatchRow_Item' in scope"
        let blamed = BuildPipeline.viewsBlamedByCompileError(
            log: log, wrapperFileName: "_PatchSwiftUI.swift",
            wrapperText: wrapper, views: ["Healthy", "Broken"])
        XCTAssertEqual(blamed, ["Broken"],
            "a support-symbol error must blame ONLY the view region that references it (not the healthy view)")
    }

    // MARK: - R2-#104: symlinked source is not double-counted

    func testSymlinkedSourceDedup() throws {
        let root = tmpRoot("symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "Shared/FooView.swift", """
        import SwiftUI
        struct FooView: View { var body: some View { Text("x").padding(4) } }
        """)
        // Create a directory symlink `Mirror -> Shared` inside the project.
        let link = root.appendingPathComponent("Mirror")
        try? FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appendingPathComponent("Shared"))
        let sources = ProjectFingerprinter.crossFileLoweringSources(projectDir: root)
        let fooCount = sources.filter { $0.source.contains("struct FooView") }.count
        XCTAssertEqual(fooCount, 1,
            "a symlinked source must be counted once (else its view export base double-counts → false collision)")
    }

    // MARK: - R2-#128: .Patch.yml excludes are honored by crossFileLoweringSources

    func testExcludesHonoredInLoweringSources() throws {
        let root = tmpRoot("excludes")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "App/Main.swift", "import SwiftUI\nstruct Main: View { var body: some View { Text(\"a\") } }\n")
        try write(root, "Legacy/Old.swift", "import SwiftUI\nstruct Old: View { var body: some View { Text(\"b\") } }\n")
        let all = ProjectFingerprinter.crossFileLoweringSources(projectDir: root)
        XCTAssertTrue(all.contains(where: { $0.source.contains("struct Old") }),
            "without excludes, Legacy/Old.swift is in the lowering set")
        let filtered = ProjectFingerprinter.crossFileLoweringSources(projectDir: root, excludes: ["Legacy/"])
        XCTAssertFalse(filtered.contains(where: { $0.source.contains("struct Old") }),
            "an excluded directory must be dropped from the lowering source set")
        XCTAssertTrue(filtered.contains(where: { $0.source.contains("struct Main") }),
            "a non-excluded source stays")
    }

    // MARK: - R2-#129: hidden-tree source is included (matches prepare)

    func testHiddenTreeSourceIncluded() throws {
        let root = tmpRoot("hidden")
        defer { try? FileManager.default.removeItem(at: root) }
        // A view under a leading-dot dir other than the build/engine ones prepare walks it.
        try write(root, ".sourcery/Generated/CardView.swift", """
        import SwiftUI
        struct CardView: View { var body: some View { Text("g").padding(2) } }
        """)
        let sources = ProjectFingerprinter.crossFileLoweringSources(projectDir: root)
        XCTAssertTrue(sources.contains(where: { $0.source.contains("struct CardView") }),
            "a view under a hidden (.sourcery) dir must be in the lowering set (prepare thunks it)")
    }

    func testBuildArtifactsStillExcluded() throws {
        let root = tmpRoot("artifacts")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "App/Real.swift", "import SwiftUI\nstruct Real: View { var body: some View { Text(\"r\") } }\n")
        // A dependency checkout + a .build tree must stay excluded even without skipsHiddenFiles.
        try write(root, ".build/checkouts/Dep/Sources/DepView.swift",
                  "import SwiftUI\nstruct DepView: View { var body: some View { Text(\"d\") } }\n")
        try write(root, "SourcePackages/checkouts/X/Y.swift",
                  "import SwiftUI\nstruct YView: View { var body: some View { Text(\"y\") } }\n")
        let sources = ProjectFingerprinter.crossFileLoweringSources(projectDir: root)
        XCTAssertTrue(sources.contains(where: { $0.source.contains("struct Real") }))
        XCTAssertFalse(sources.contains(where: { $0.source.contains("struct DepView") }),
            "a .build/checkouts dependency source must stay excluded")
        XCTAssertFalse(sources.contains(where: { $0.source.contains("struct YView") }),
            "a SourcePackages/checkouts dependency source must stay excluded")
    }

    // MARK: - ShippedOTAManifest round-trip

    func testManifestReadWriteRoundTrip() throws {
        let root = tmpRoot("manifest")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(ShippedOTAManifest.read(projectDir: root), "no manifest yet → nil")
        try writeManifest(root, views: ["A", "B"], cells: ["C"], generalTrusted: false)
        let read = ShippedOTAManifest.read(projectDir: root)
        XCTAssertEqual(read?.shippedSwiftUIViews, ["A", "B"])
        XCTAssertEqual(read?.shippedUIKitCells, ["C"])
        XCTAssertEqual(read?.generalLogicTrusted, false)
    }

    // MARK: - divergence-fix: register/diff must produce the BUILD-CONFIRMED fingerprint

    /// THE CORE REGRESSION TEST for the register↔release divergence.
    ///
    /// `register`/`diff` used to hash against the manifest-ABSENT static prediction, which
    /// OPTIMISTICALLY strips every `wasmEligible` body (it assumes general logic is trusted),
    /// while `release` runs the build and writes a manifest whose `generalLogicTrusted` is
    /// FALSE for apps whose general module doesn't fully lower → those bodies stay HASHED →
    /// a permanent false-MISMATCH. The fix makes register/diff hash WITH a fresh build-written
    /// manifest. This test proves the device-correct agreement two ways:
    ///   (1) For a CLEAN (general-trusted) build, the fingerprint a fresh manifest produces is
    ///       IDENTICAL to the manifest-absent static one — so a `register` that builds (writing
    ///       a clean manifest) registers the SAME value `release` will (which also writes a clean
    ///       manifest). register == release.
    ///   (2) For an UNTRUSTED build (`generalLogicTrusted:false`), the manifest-present
    ///       fingerprint DIFFERS from the optimistic static one — and the manifest-present value
    ///       is the DEVICE-CORRECT one `release` enforces (those bodies render NATIVELY on
    ///       device, so editing one SHOULD churn). Registering the static value here is the bug;
    ///       registering the build-confirmed (manifest-present) value is the fix. Both `register`
    ///       and `release` now build → both see the same `false` verdict → they AGREE.
    func testRegisterAndReleaseAgreeViaBuildConfirmedManifest() throws {
        let root = tmpRoot("converge")
        defer { try? FileManager.default.removeItem(at: root) }
        // A pure, wasmEligible function — exactly the body the static path optimistically strips.
        try write(root, "App/Calc.swift", """
        import Foundation
        func price(for n: Int) -> Int { n * 2 + 1 }
        """)
        let spans = ProjectFingerprinter.otaEligibleBodySpans(projectDir: root, registry: .standard)
        try XCTSkipUnless(spans.values.contains(where: { !$0.isEmpty }),
            "price() is not wasmEligible in this engine build — skip")
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }

        // (0) manifest-ABSENT static prediction (the OLD register/diff input) — optimistic strip.
        let staticFP = fp()

        // (1) CLEAN build manifest (generalLogicTrusted:true): `register`-builds == `release`.
        //     This is what `buildConfirmedSnapshot` registers after a clean compile, and it
        //     equals the static value — so on a clean app, register/release/diff all coincide.
        try writeManifest(root, generalTrusted: true)
        let cleanFP = fp()
        XCTAssertEqual(cleanFP, staticFP,
            "a CLEAN build manifest strips the same wasmEligible bodies as the static path → register==release")

        // (2) UNTRUSTED build manifest (generalLogicTrusted:false): bodies stay HASHED.
        //     This is the case that produced the false-MISMATCH: the OLD register hashed the
        //     STATIC (stripped) value, but `release` builds → writes `false` → hashes the body.
        //     The fix makes register ALSO build → it now registers THIS value → they agree.
        try writeManifest(root, generalTrusted: false)
        let untrustedFP = fp()
        XCTAssertNotEqual(untrustedFP, staticFP,
            "DIVERGENCE: an UNTRUSTED build keeps wasmEligible bodies hashed → its fingerprint differs "
            + "from the optimistic static one; register MUST register THIS (build-confirmed) value, not the static one")

        // DEVICE-CORRECTNESS (the INTENTIONAL behavior we document + lock in): with the untrusted
        // manifest, editing that body MUST churn — it renders NATIVELY on device, so a real edit
        // to it needs a native rebuild, never a silent OTA no-op (this is a false-STABLE guard).
        let calc = root.appendingPathComponent("App/Calc.swift")
        let baseUntrusted = fp()  // recompute under the still-present untrusted manifest
        var s = try String(contentsOf: calc, encoding: .utf8)
        s = s.replacingOccurrences(of: "n * 2 + 1", with: "n * 3 + 7")
        try s.write(to: calc, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), baseUntrusted,
            "DEVICE-CORRECT: a generalLogicTrusted:false body stays hashed → editing it churns (forces the native rebuild)")
    }

    // MARK: - divergence-fix: manifest source-set freshness (diff reuse vs rebuild)

    func testManifestSourceHashFreshness() throws {
        let root = tmpRoot("fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "App/View.swift", """
        import SwiftUI
        struct V: View { var body: some View { Text("a") } }
        """)
        // A manifest stamped with the CURRENT source hash is fresh (diff reuses it, no rebuild).
        let srcHash = ShippedOTAManifest.sourceSetHash(projectDir: root)
        let fresh = ShippedOTAManifest(shippedSwiftUIViews: ["V"], shippedUIKitCells: [],
                                       generalLogicTrusted: true, sourceHash: srcHash)
        let dir = root.appendingPathComponent(".Patch/build")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(fresh).write(to: dir.appendingPathComponent(ShippedOTAManifest.fileName))
        XCTAssertTrue(ShippedOTAManifest.read(projectDir: root)!.isFresh(projectDir: root),
            "a manifest stamped with the current source hash is fresh")

        // Editing ANY source byte makes it stale (diff must rebuild / warn, not trust the verdict).
        let view = root.appendingPathComponent("App/View.swift")
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #"Text("a")"#, with: #"Text("b")"#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertFalse(ShippedOTAManifest.read(projectDir: root)!.isFresh(projectDir: root),
            "any source byte change makes the manifest stale → diff must not reuse its verdict")

        // A manifest with NO sourceHash (older patchcli) reads as NOT fresh (conservative).
        let legacy = ShippedOTAManifest(shippedSwiftUIViews: [], shippedUIKitCells: [],
                                        generalLogicTrusted: true)
        XCTAssertNil(legacy.sourceHash)
        XCTAssertFalse(legacy.isFresh(projectDir: root),
            "a legacy manifest with no sourceHash is treated as stale (diff rebuilds/warns rather than trust it)")
    }

    /// `sourceHash` is OPTIONAL so a manifest written by an older patchcli (no field) still
    /// decodes — the fingerprint manifest is a local file, not a network wire format, but the
    /// backward-compat decode must hold so an upgrade never crashes reading an old manifest.
    func testManifestDecodesWithoutSourceHash() throws {
        let legacyJSON = """
        {"shippedSwiftUIViews":["A"],"shippedUIKitCells":[],"generalLogicTrusted":true}
        """
        let m = try JSONDecoder().decode(ShippedOTAManifest.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(m.shippedSwiftUIViews, ["A"])
        XCTAssertNil(m.sourceHash, "a legacy manifest with no sourceHash field decodes with sourceHash == nil")
    }

    // MARK: - Fingerprint granularity: sibling functions in a View file

    /// INVESTIGATION RESULT (fingerprint-granularity claim, the "AppI" scenario):
    ///
    /// Claim: "a change to ONE function/computed-property in a file that ALSO contains
    /// OTA-lowered views can flip the WHOLE file's hash → false FINGERPRINT MISMATCH,
    /// even when the changed code is itself OTA-eligible."
    ///
    /// FINDING: NOT A BUG. The fingerprint correctly handles this per-function, not per-file:
    ///   • A sibling function the partitioning engine classifies `.wasmEligible` IS stripped
    ///     by `otaEligibleBodySpans` — its body edit leaves the hash STABLE (OTA-compatible).
    ///   • A sibling function classified `.native` is NOT stripped because it IS native code in
    ///     the signed binary — its body edit CHURNS (correct: a real native-shell change).
    ///   • There is no case where an OTA-compatible change to a sibling wrongly churns: if the
    ///     function truly ships OTA (wasmEligible), its span IS stripped; if it is native, churn
    ///     is correct. The safety direction (never false-stable) is preserved in both cases.
    ///
    /// These two tests lock in both directions as a regression guard.

    /// A wasmEligible sibling in the same file as a lowered view — editing its body is STABLE
    /// (the span is stripped by `otaEligibleBodySpans`, just like a standalone wasmEligible fn).
    func testWasmEligibleSiblingInViewFile_EditIsStable() throws {
        let root = tmpRoot("sibling-ota")
        defer { try? FileManager.default.removeItem(at: root) }
        // FoodView lowers its `var body` OTA. `formattedCount` is a pure sibling computed
        // property (pure arithmetic over a marshallable Int) → wasmEligible → body stripped.
        try write(root, "App/FoodView.swift", """
        import SwiftUI
        struct FoodView: View {
            var count: Int
            /// Pure arithmetic helper — ships OTA via general-logic WASM module.
            var doubled: Int { count * 2 }
            var body: some View {
                VStack {
                    Text("items")
                    Text("count")
                }
            }
        }
        """)
        // Sanity check: (a) the view auto-routes (else the test only proves the non-view case)
        let sources = ProjectFingerprinter.crossFileLoweringSources(projectDir: root)
        let src = sources.first { $0.source.contains("FoodView") }?.source ?? ""
        let lowered = BodyLowering().lowerAllViews(
            source: src, sameFileThunk: true, crossFile: BodyLowering.crossFileBundle(sources: [src]))
        let fv = lowered.first { $0.viewName == "FoodView" }
        try XCTSkipUnless(fv != nil && ProjectFingerprinter.isAutoRouted(fv!, collidingBases: []),
            "FoodView did not auto-route in this engine build — skip (test is about the mixed-file case)")
        // Sanity check: (b) `doubled` IS wasmEligible (else the test would only prove a native-sibling case)
        let eligibleSpans = ProjectFingerprinter.otaEligibleBodySpans(projectDir: root, registry: .standard)
        let hasSiblingSpan = eligibleSpans.values.contains { spans in !spans.isEmpty }
        try XCTSkipUnless(hasSiblingSpan,
            "`doubled` is not wasmEligible in this engine build — skip (test is about the wasmEligible-sibling case)")

        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()

        // Edit ONLY the sibling wasmEligible body (the pure arithmetic) → rides WASM → STABLE.
        let file = root.appendingPathComponent("App/FoodView.swift")
        var s = try String(contentsOf: file, encoding: .utf8)
        s = s.replacingOccurrences(of: "count * 2", with: "count * 3")
        try s.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "GRANULARITY: editing a wasmEligible sibling in a View file must NOT churn the fingerprint — "
            + "the sibling body is stripped by otaEligibleBodySpans just like a standalone wasmEligible function; "
            + "the file-level hash does NOT flip on an OTA-compatible edit")
    }

    /// A genuinely-native sibling in the same file as a lowered view — editing it CHURNS.
    /// This is the SAFETY DIRECTION: a native-shell change must always be detected, even if
    /// the changed function is "isolated" from the view body (the fingerprint cannot prove
    /// call-path isolation without a full reachability analysis, so it errs conservative).
    func testNativeSiblingInViewFile_EditChurns() throws {
        let root = tmpRoot("sibling-native")
        defer { try? FileManager.default.removeItem(at: root) }
        // FoodView lowers its `var body` OTA. `loadFavorites` calls UserDefaults — it is
        // native (mustStayNative registry symbol) → its body is hashed verbatim → editing it
        // MUST churn (it IS native-shell code in the signed binary, regardless of whether the
        // view body directly calls it).
        try write(root, "App/FoodView.swift", """
        import SwiftUI
        import Foundation
        struct FoodView: View {
            var count: Int
            var body: some View {
                VStack {
                    Text("items")
                    Text("count")
                }
            }
        }
        /// Native helper in the same file — uses a mustStayNative symbol (UserDefaults).
        func loadFavorites() -> [String] {
            UserDefaults.standard.stringArray(forKey: "favorites") ?? []
        }
        """)
        // Sanity check: the view auto-routes.
        let sources = ProjectFingerprinter.crossFileLoweringSources(projectDir: root)
        let src = sources.first { $0.source.contains("FoodView") }?.source ?? ""
        let lowered = BodyLowering().lowerAllViews(
            source: src, sameFileThunk: true, crossFile: BodyLowering.crossFileBundle(sources: [src]))
        let fv = lowered.first { $0.viewName == "FoodView" }
        try XCTSkipUnless(fv != nil && ProjectFingerprinter.isAutoRouted(fv!, collidingBases: []),
            "FoodView did not auto-route in this engine build — skip")

        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()

        // Edit the native sibling body (UserDefaults key) → MUST churn.
        let file = root.appendingPathComponent("App/FoodView.swift")
        var s = try String(contentsOf: file, encoding: .utf8)
        s = s.replacingOccurrences(of: #""favorites""#, with: #""saved_favorites""#)
        try s.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "SAFETY: editing a NATIVE sibling in a View file MUST churn the fingerprint — "
            + "the function is native-shell code (UserDefaults call), so changing it is a real native-shell change "
            + "that requires a new App Store binary before the OTA patch can run against it")
    }

    // MARK: - Titled-control opaqueExpr fallback: title-literal must be fingerprint-STABLE

    /// `Link("Open Site", destination: url)` — destination is a non-literal (can't be
    /// resolved to a URL string), so the whole control becomes an opaque slot. The title
    /// "Open Site" is a plain string literal and, with the fix, is LIFTED via the
    /// parameterized-slot mechanism so it rides WASM via slotArgs. Editing only the title
    /// must NOT churn the native-shell fingerprint (it's OTA-patchable).
    ///
    /// SAFETY direction: a genuinely-native change (editing the native helper file) STILL churns.
    func testLinkTitleLiteralIsFingerprint_Stable() throws {
        let root = tmpRoot("link-title-fp")
        defer { try? FileManager.default.removeItem(at: root) }

        let viewSrc = """
        import SwiftUI
        struct MyView: View {
            var url: URL
            var body: some View {
                VStack {
                    Text("Content")
                    Link("Open Site", destination: url)
                }
            }
        }
        """
        let nativeSrc = """
        import Foundation
        func loadURL(key: String) -> String {
            UserDefaults.standard.string(forKey: key) ?? ""
        }
        """
        try write(root, "App/MyView.swift", viewSrc)
        try write(root, "App/NativeConfig.swift", nativeSrc)

        // Sanity: confirm the Link leaf has a lifted string arg (else skip — engine may have changed).
        let lb = BodyLowering()
        let cf = BodyLowering.crossFileBundle(sources: [viewSrc, nativeSrc])
        let views = lb.lowerAllViews(source: viewSrc, sameFileThunk: true, crossFile: cf)
        let mv = views.first { $0.viewName == "MyView" }
        try XCTSkipUnless(mv != nil, "MyView did not lower in this engine build — skip")
        let hasLiftedLinkTitle = mv!.opaqueLeaves.contains { !$0.stringArgRanges.isEmpty }
        try XCTSkipUnless(hasLiftedLinkTitle,
            "Link title is not lifted in this engine build — skip (engine may now lower Link differently)")

        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()

        // PART 1 — editing ONLY the Link title must NOT churn (the fix).
        let view = root.appendingPathComponent("App/MyView.swift")
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #""Open Site""#, with: #""Visit Us""#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "TITLED-CONTROL FIX: editing only the Link title literal must NOT churn the fingerprint "
            + "— it rides WASM via slotArgs (parameterized slot)")

        // Restore, verify fingerprint is back.
        s = s.replacingOccurrences(of: #""Visit Us""#, with: #""Open Site""#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        let baseRestored = fp()
        XCTAssertEqual(baseRestored, base, "restoring the literal must restore the fingerprint")

        // PART 2 — a genuinely-native edit MUST churn (safety direction).
        let native = root.appendingPathComponent("App/NativeConfig.swift")
        var ns = try String(contentsOf: native, encoding: .utf8)
        ns = ns.replacingOccurrences(of: #"?? """#, with: #"?? "default""#)
        try ns.write(to: native, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), baseRestored,
            "SAFETY: editing a genuinely-native function body MUST still churn the fingerprint")
    }

    /// Non-literal Link title (a variable) — the title is NOT lifted. Editing the
    /// variable's USAGE (inside the link call — structural change) MUST churn. This is
    /// the "no over-lift" safety direction: if the title isn't a plain string literal,
    /// it stays baked and any change to the expression is treated as native.
    func testLinkNonLiteralTitleEditChurns() throws {
        let root = tmpRoot("link-varytitle-fp")
        defer { try? FileManager.default.removeItem(at: root) }

        let viewSrc = """
        import SwiftUI
        struct MyView: View {
            var url: URL
            var linkTitle: String
            var body: some View {
                VStack {
                    Text("Content")
                    Link(linkTitle, destination: url)
                }
            }
        }
        """
        try write(root, "App/MyView.swift", viewSrc)

        // Sanity: confirm no lifted string args (else skip — engine may now lower differently).
        let views = BodyLowering().lowerAllViews(source: viewSrc, sameFileThunk: true)
        let mv = views.first { $0.viewName == "MyView" }
        try XCTSkipUnless(mv != nil, "MyView did not lower — skip")
        let hasLiftedArg = mv!.opaqueLeaves.contains { !$0.stringArgRanges.isEmpty }
        try XCTSkipUnless(!hasLiftedArg,
            "Link non-literal title unexpectedly lifted — skip (engine behaviour changed)")

        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()

        // Rename `linkTitle` → `linkTitleNew` in the body (structural change to the slot source).
        let view = root.appendingPathComponent("App/MyView.swift")
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: "Link(linkTitle,", with: "Link(linkTitleNew,")
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "NO OVER-LIFT: a non-literal Link title stays baked → structural change to the "
            + "slot source MUST churn the fingerprint (safety direction)")
    }

    // MARK: - Fallback-path lift fingerprint-stability (Picker / Section / ProgressView / Menu)

    /// FINGERPRINT-STABILITY: a `Picker("Period", ...)` whose rows have non-literal tags falls
    /// back to opaqueExprLifted. With the fallback-path lift, the title "Period" is extracted
    /// into `stringArgRanges` → the fingerprint walker strips those bytes → editing ONLY the
    /// Picker title is fingerprint-STABLE (no false MISMATCH). A structural edit (renaming the
    /// selection variable) MUST still churn.
    ///
    /// Mirrors the real AppJ InsightsScreen regression: editing `Picker("Period",…)`
    /// title used to FINGERPRINT MISMATCH before the fallback-path lift.
    func testFallbackPickerTitleLiteralIsFingerprint_Stable() throws {
        let root = tmpRoot("picker-title-fp")
        defer { try? FileManager.default.removeItem(at: root) }

        let viewSrc = """
        import SwiftUI
        enum Period: String, CaseIterable, Identifiable {
            case week, month, year
            var id: String { rawValue }
            var label: String { rawValue.capitalized }
        }
        struct InsightsScreen: View {
            @State private var selectedPeriod: Period = .week
            let items: [String]
            var body: some View {
                VStack {
                    Picker("Period", selection: $selectedPeriod) {
                        ForEach(Period.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    ForEach(items, id: \\.self) { Text($0) }
                }
            }
        }
        """
        let nativeSrc = """
        import Foundation
        func loadConfig(key: String) -> String {
            UserDefaults.standard.string(forKey: key) ?? ""
        }
        """
        try write(root, "App/InsightsScreen.swift", viewSrc)
        try write(root, "App/NativeConfig.swift", nativeSrc)

        // Sanity: confirm the Picker leaf has a lifted string arg — else engine changed behaviour.
        let views = BodyLowering().lowerAllViews(source: viewSrc, sameFileThunk: true)
        let mv = views.first { $0.viewName == "InsightsScreen" }
        try XCTSkipUnless(mv != nil, "InsightsScreen did not lower — skip")
        let hasLiftedPickerTitle = mv!.opaqueLeaves.contains { !$0.stringArgRanges.isEmpty }
        try XCTSkipUnless(hasLiftedPickerTitle,
            "Picker title is not lifted in this engine build — skip (engine may now lower Picker differently)")

        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()

        // PART 1 — editing ONLY the Picker title literal must NOT churn (the fix).
        let view = root.appendingPathComponent("App/InsightsScreen.swift")
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #""Period""#, with: #""Time Period""#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "FALLBACK-LIFT FIX: editing only the Picker title literal must NOT churn the fingerprint "
            + "— it rides WASM via slotArgs (stringArgRanges are normalised by fingerprint walker)")

        // Restore.
        s = s.replacingOccurrences(of: #""Time Period""#, with: #""Period""#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base, "restoring the Picker title must restore the fingerprint")

        // PART 2 — a genuinely-native edit MUST churn (safety direction).
        let native = root.appendingPathComponent("App/NativeConfig.swift")
        var ns = try String(contentsOf: native, encoding: .utf8)
        ns = ns.replacingOccurrences(of: #"?? """#, with: #"?? "default""#)
        try ns.write(to: native, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "SAFETY: editing a genuinely-native function body MUST still churn the fingerprint")
    }

    /// FINGERPRINT-STABILITY: a `Section("Recent") { ForEach(items) { CustomRow($0) } }` whose
    /// data row is a non-lowerable custom view falls back to opaqueExprLifted. Editing ONLY the
    /// section title "Recent" → "Latest" must be fingerprint-STABLE. A structural edit (renaming
    /// the items variable) MUST still churn.
    func testFallbackSectionTitleLiteralIsFingerprint_Stable() throws {
        let root = tmpRoot("section-title-fp")
        defer { try? FileManager.default.removeItem(at: root) }

        let viewSrc = """
        import SwiftUI
        struct CustomRow: View {
            let item: String
            var body: some View { Text(item).padding() }
        }
        struct FeedView: View {
            let items: [String]
            var body: some View {
                List {
                    Section("Recent") {
                        ForEach(items, id: \\.self) { item in
                            CustomRow(item: item)
                        }
                    }
                }
            }
        }
        """
        let nativeSrc = """
        import Foundation
        func loadFeed(key: String) -> String {
            UserDefaults.standard.string(forKey: key) ?? ""
        }
        """
        try write(root, "App/FeedView.swift", viewSrc)
        try write(root, "App/NativeFeed.swift", nativeSrc)

        // Sanity: confirm the Section leaf has a lifted string arg.
        let views = BodyLowering().lowerAllViews(source: viewSrc, sameFileThunk: true)
        let fv = views.first { $0.viewName == "FeedView" }
        try XCTSkipUnless(fv != nil, "FeedView did not lower — skip")
        let hasLiftedSectionTitle = fv!.opaqueLeaves.contains { !$0.stringArgRanges.isEmpty }
        try XCTSkipUnless(hasLiftedSectionTitle,
            "Section title is not lifted in this engine build — skip")

        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()

        // PART 1 — editing ONLY the Section title must NOT churn.
        let view = root.appendingPathComponent("App/FeedView.swift")
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #""Recent""#, with: #""Latest""#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "FALLBACK-LIFT FIX: editing only the Section title literal must NOT churn the fingerprint")

        // Restore.
        s = s.replacingOccurrences(of: #""Latest""#, with: #""Recent""#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base, "restoring the Section title must restore the fingerprint")

        // PART 2 — a genuinely-native edit MUST churn.
        let native = root.appendingPathComponent("App/NativeFeed.swift")
        var ns = try String(contentsOf: native, encoding: .utf8)
        ns = ns.replacingOccurrences(of: #"?? """#, with: #"?? "default""#)
        try ns.write(to: native, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "SAFETY: editing a genuinely-native function body MUST still churn the fingerprint")
    }
}
