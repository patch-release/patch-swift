// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler
import PartitioningEngine
import CodeGenerator

/// Round-1 fingerprint bug fixes (B-fingerprint partition). Each test asserts the
/// CORE INVARIANT: churn on a real native-shell change, stable on a benign OTA edit;
/// and never FALSE-STABLE (a native change that wrongly does not churn).
final class FingerprintRound1Tests: XCTestCase {

    private func tmpRoot(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-fp-\(tag)-\(UUID().uuidString)")
    }
    private func write(_ root: URL, _ rel: String, _ contents: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: u, atomically: true, encoding: .utf8)
    }

    // MARK: - BUG #41: swift-version normalization (PATH-order nondeterminism)

    func testSwiftVersionNormalizationCollapsesVendorPrefixAndBuildSuffix() {
        // The SAME release reported by the Apple/Xcode vs swift.org/swiftly toolchains
        // (different first-on-PATH between the register shell and the WASM-compile shell)
        // must normalize to the SAME token, or registering in one shell + pushing in the
        // other trips a spurious MISMATCH.
        let apple = ProjectFingerprinter.normalizeSwiftVersion(
            "Apple Swift version 6.1.2 (swiftlang-6.1.2.0.1 clang-1700.0.13.5)")
        let org = ProjectFingerprinter.normalizeSwiftVersion(
            "Swift version 6.1.2 (swift-6.1.2-RELEASE)")
        XCTAssertEqual(apple, org, "same Swift release must normalize identically across toolchains")
        XCTAssertEqual(apple, "swift 6.1.2")
    }

    func testSwiftVersionNormalizationStillChurnsOnRealBump() {
        let a = ProjectFingerprinter.normalizeSwiftVersion("Apple Swift version 6.1.2 (...)")
        let b = ProjectFingerprinter.normalizeSwiftVersion("Apple Swift version 6.2.0 (...)")
        XCTAssertNotEqual(a, b, "a real compiler-version bump must still churn")
    }

    func testSwiftVersionNormalizationFallsBackWhenNoDottedVersion() {
        let s = ProjectFingerprinter.normalizeSwiftVersion("totally unexpected output")
        XCTAssertEqual(s, "totally unexpected output", "no dotted version → keep the trimmed original")
    }

    // MARK: - BUG #67: test-target Info.plist / entitlements / pbxproj must not churn

    private func makeTestTargetProject() throws -> URL {
        let root = tmpRoot("testtarget")
        try write(root, "App/Math.swift", "struct M { func f() -> Int { 1 + 1 } }")
        try write(root, "App/Info.plist", "<plist>APP</plist>")
        try write(root, "App/App.entitlements", "<plist>APPENT</plist>")
        // A UI-test target with its OWN Info.plist + entitlements (a separate test bundle).
        try write(root, "AppUITests/Info.plist", "<plist>UITEST</plist>")
        try write(root, "AppTests/Tests.entitlements", "<plist>TESTENT</plist>")
        return root
    }

    func testTestTargetPlistAndEntitlementsDoNotChurnFingerprint() throws {
        let root = try makeTestTargetProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()

        // Edit ONLY the test target's Info.plist → cannot affect the shipped app → STABLE.
        try write(root, "AppUITests/Info.plist", "<plist>UITEST-CHANGED</plist>")
        XCTAssertEqual(fp(), base, "editing a TEST-target Info.plist must NOT churn the app fingerprint")

        // Edit ONLY the test target's entitlements → STABLE.
        try write(root, "AppTests/Tests.entitlements", "<plist>TESTENT-CHANGED</plist>")
        XCTAssertEqual(fp(), base, "editing a TEST-target .entitlements must NOT churn the app fingerprint")
    }

    func testAppPlistAndEntitlementsStillChurn() throws {
        let root = try makeTestTargetProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()
        // Editing the APP's real Info.plist MUST churn (it ships in the binary).
        try write(root, "App/Info.plist", "<plist>APP-CHANGED</plist>")
        XCTAssertNotEqual(fp(), base, "editing the APP Info.plist MUST churn")

        // And the app's own entitlements MUST churn.
        let root2 = try makeTestTargetProject()
        defer { try? FileManager.default.removeItem(at: root2) }
        let fp2 = { ProjectFingerprinter().snapshot(projectDir: root2, bridges: [:]).fingerprint }
        let b2 = fp2()
        try write(root2, "App/App.entitlements", "<plist>APPENT-CHANGED</plist>")
        XCTAssertNotEqual(fp2(), b2, "editing the APP .entitlements MUST churn")
    }

    func testIsTestTargetInputPredicate() {
        XCTAssertTrue(ProjectFingerprinter.isTestTargetInput(URL(fileURLWithPath: "/p/AppUITests/Info.plist")))
        XCTAssertTrue(ProjectFingerprinter.isTestTargetInput(URL(fileURLWithPath: "/p/AppTests/x.entitlements")))
        XCTAssertFalse(ProjectFingerprinter.isTestTargetInput(URL(fileURLWithPath: "/p/App/Info.plist")))
    }

    // MARK: - BUG #68: single-line auto-routed body literal edit must be stable

    private func makeSingleLineViewProject() throws -> URL {
        let root = tmpRoot("oneline")
        try write(root, "App/Hi.swift", """
        import SwiftUI
        struct Hi: View { var body: some View { Text("Hello") } }
        """)
        return root
    }

    func testSingleLineViewBodyLiteralEditIsStable() throws {
        let root = try makeSingleLineViewProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = root.appendingPathComponent("App/Hi.swift")
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()
        // Edit the lowered single-line body literal → rides WASM → STABLE.
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #"Text("Hello")"#, with: #"Text("Hi")"#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "editing a literal in a SINGLE-LINE auto-routed view body must NOT churn (it rides WASM)")
    }

    func testStripBraceInteriorKeepsSignatureChurning() {
        // The signature (outside the braces) is preserved, so a signature edit still churns.
        let a = ProjectFingerprinter.stripBraceInterior(#"var body: some View { Text("Hello") }"#)
        let b = ProjectFingerprinter.stripBraceInterior(#"var body: some View { Text("Hi") }"#)
        XCTAssertEqual(a, b, "two single-line bodies differing only in body content normalize identically")
        let c = ProjectFingerprinter.stripBraceInterior(#"var body2: some View { Text("Hello") }"#)
        XCTAssertNotEqual(a, c, "a signature change (outside braces) must still differ")
        // No balanced braces → returned unchanged (safe).
        XCTAssertEqual(ProjectFingerprinter.stripBraceInterior("let x = 1"), "let x = 1")
    }

    // MARK: - BUG #19 / #42: swiftui:false ⇒ view bodies stay hashed (no false-stable)

    private func makeMultiLineViewProject() throws -> URL {
        let root = tmpRoot("swiftuioff")
        try write(root, "App/Screen.swift", """
        import SwiftUI
        struct Screen: View {
            var body: some View {
                VStack {
                    Text("Title")
                    Text("subtitle")
                }
            }
        }
        """)
        return root
    }

    func testViewBodyEditChurnsWhenSwiftUILoweringOff() throws {
        let root = try makeMultiLineViewProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = root.appendingPathComponent("App/Screen.swift")
        // buildSwiftUI:false → the build does NOT lower this body, it renders native →
        // editing it is a REAL native-shell change → MUST churn (no false-stable).
        let fp = { ProjectFingerprinter()
            .snapshot(projectDir: root, bridges: [:], buildSwiftUI: false).fingerprint }
        let base = fp()
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #"Text("Title")"#, with: #"Text("Changed")"#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "with swiftui:false the build ships the body NATIVE — a body edit MUST churn the fingerprint")
    }

    func testViewBodyEditStableWhenSwiftUILoweringOn() throws {
        let root = try makeMultiLineViewProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = root.appendingPathComponent("App/Screen.swift")
        // buildSwiftUI:true (default) → the body lowers + rides WASM → STABLE (unchanged behavior).
        let fp = { ProjectFingerprinter()
            .snapshot(projectDir: root, bridges: [:], buildSwiftUI: true).fingerprint }
        let base = fp()
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #"Text("Title")"#, with: #"Text("Changed")"#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "with swiftui:true the lowered body rides WASM — editing it must NOT churn")
    }

    func testSwiftUILoweringEnvOverrideWins() {
        // PATCH_SWIFTUI env overrides the config either way, mirroring BuildPipeline.
        let prior = ProcessInfo.processInfo.environment["PATCH_SWIFTUI"]
        setenv("PATCH_SWIFTUI", "0", 1)
        XCTAssertFalse(ProjectFingerprinter.swiftUILoweringOn(configBuildSwiftUI: true),
                       "PATCH_SWIFTUI=0 must force lowering OFF even with config on")
        setenv("PATCH_SWIFTUI", "1", 1)
        XCTAssertTrue(ProjectFingerprinter.swiftUILoweringOn(configBuildSwiftUI: false),
                      "PATCH_SWIFTUI=1 must force lowering ON even with config off")
        if let prior { setenv("PATCH_SWIFTUI", prior, 1) } else { unsetenv("PATCH_SWIFTUI") }
    }

    // MARK: - BUG #20: lowered UIKit cell configure(with:) edit must be stable

    private func makeUIKitCellProject() throws -> URL {
        let root = tmpRoot("uikitcell")
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
        return root
    }

    func testLoweredUIKitCellBodyEditIsStable() throws {
        let root = try makeUIKitCellProject()
        defer { try? FileManager.default.removeItem(at: root) }
        // Sanity: the cell actually lowers (else this test proves nothing).
        let cellSrc = try String(
            contentsOf: root.appendingPathComponent("App/ProductCell.swift"), encoding: .utf8)
        let lowered = UIKitCellLowering().lowerAllCells(source: cellSrc)
        try XCTSkipUnless(
            lowered.contains(where: { $0.typeName == "ProductCell" && !$0.referencesUnmarshalledInput }),
            "ProductCell did not lower in this engine build — skip (test is about the fingerprint strip)")

        let cell = root.appendingPathComponent("App/ProductCell.swift")
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()
        // Edit a lowered property value inside configure(with:) → rides WASM → STABLE.
        var s = try String(contentsOf: cell, encoding: .utf8)
        s = s.replacingOccurrences(of: "titleLabel.textColor = .label",
                                   with: "titleLabel.textColor = .secondaryLabel")
        try s.write(to: cell, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "editing a LOWERED UIKit cell configure(with:) body must NOT churn the fingerprint (it ships OTA)")
    }
}
