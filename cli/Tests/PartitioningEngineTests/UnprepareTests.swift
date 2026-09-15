// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
@testable import Compiler
@testable import PatchCLI

/// `patchcli unprepare` + automatic excluded-file cleanup. The core property: `init`-style SDK add +
/// `Patch.configure` injection + `prepare` → `unprepare --remove-sdk` restores every file of the project
/// BYTE-FOR-BYTE, for classic xcodeproj, Xcode-16 synchronized-group projects, and SwiftPM packages.
final class UnprepareTests: XCTestCase {

    private func tmp(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unprep-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// Every file under `dir` (relative path → contents).
    private func snapshot(_ dir: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = dir.resolvingSymlinksInPath().path
        for case let u as URL in FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)! {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let p = u.resolvingSymlinksInPath().path
            out[String(p.dropFirst(base.count + 1))] = read(u)
        }
        return out
    }

    private func prepare(_ dir: URL, target: String, excludes: [String] = []) throws {
        _ = try Prepare.execute(root: dir, excludes: excludes, target: target,
                                assumeYes: true, thunksOnly: false, check: false, quiet: true)
    }

    private func unprepare(_ dir: URL, removeSDK: Bool = false, keepDynamic: Bool = false) -> [String] {
        let plan = PatchUninstaller.plan(root: dir, options: .init(removeSDK: removeSDK, keepDynamic: keepDynamic))
        return PatchUninstaller.apply(plan)
    }

    private static let appSwift = OnboardingTests.appSwift + "\n"
    private static let mix = PatchAccessForwardingTests.mixView + "\n"
    private static let hello = "import SwiftUI\nstruct Hello: View {\n    var body: some View { Text(\"hi\") }\n}\n"

    /// `OnboardingTests.pbxprojNoPackages` with MixView.swift + Hello.swift actually IN the Demo
    /// target (prepare only thunks views its build target compiles — `XcodeTargetSources`).
    private static let classicWithViews: String = {
        var s = OnboardingTests.pbxprojNoPackages
        func after(_ anchor: String, _ add: String) {
            precondition(s.components(separatedBy: anchor).count == 2, "fixture anchor: \(anchor)")
            s = s.replacingOccurrences(of: anchor, with: anchor + add)
        }
        let files = [("MixView.swift", "AA00000000000000000000F1", "AA00000000000000000000F2"),
                     ("Hello.swift", "AA00000000000000000000F3", "AA00000000000000000000F4")]
        for (name, bf, ref) in files {
            after("fileRef = AA0000000000000000000002 /* DemoApp.swift */; };\n",
                  "\t\t\(bf) /* \(name) in Sources */ = {isa = PBXBuildFile; fileRef = \(ref) /* \(name) */; };\n")
            after("path = DemoApp.swift; sourceTree = \"<group>\"; };\n",
                  "\t\t\(ref) /* \(name) */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \(name); sourceTree = \"<group>\"; };\n")
            after("AA0000000000000000000002 /* DemoApp.swift */,\n", "\t\t\t\t\(ref) /* \(name) */,\n")
            after("AA0000000000000000000001 /* DemoApp.swift in Sources */,\n", "\t\t\t\t\(bf) /* \(name) in Sources */,\n")
        }
        return s
    }()

    // MARK: - Round trips

    func testClassicXcodeProjectFullRoundTripIsByteIdentical() throws {
        let dir = try tmp("classic")
        try write(Self.classicWithViews, to: dir.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        try write(Self.appSwift, to: dir.appendingPathComponent("DemoApp.swift"))
        try write(Self.mix, to: dir.appendingPathComponent("MixView.swift"))
        try write(Self.hello, to: dir.appendingPathComponent("Hello.swift"))
        let before = snapshot(dir)

        // What `patchcli init` + `prepare` do to a project.
        try XcodeProjectEditor.apply(projectURL: dir.appendingPathComponent("Demo.xcodeproj"), targetName: "Demo")
        let appURL = dir.appendingPathComponent("DemoApp.swift")
        try write(AppEntryInjector.inject(into: read(appURL), appKey: "pak_x", appID: "app_1", fingerprint: "abc")!, to: appURL)
        try prepare(dir, target: "Demo")
        let prepared = snapshot(dir)
        XCTAssertTrue(prepared["MixView.swift"]!.contains(PatchAccessForwarding.beginMarker))
        XCTAssertTrue(prepared["Demo.xcodeproj/project.pbxproj"]!.contains("PatchThunks.generated.swift"))
        XCTAssertNotEqual(before, prepared)

        XCTAssertEqual(unprepare(dir, removeSDK: true), [])
        let after = snapshot(dir)
        XCTAssertEqual(Set(after.keys), Set(before.keys), "leftover/missing files: \(Set(after.keys).symmetricDifference(before.keys))")
        for (k, v) in before where after[k] != v {
            XCTFail("\(k) not restored:\n--- expected ---\n\(v)\n--- got ---\n\(after[k] ?? "<missing>")")
        }
    }

    func testClassicXcodeProjectKeepsSDKWithoutRemoveSDK() throws {
        let dir = try tmp("classic-keep")
        try write(Self.classicWithViews, to: dir.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        try write(Self.appSwift, to: dir.appendingPathComponent("DemoApp.swift"))
        try write(Self.hello, to: dir.appendingPathComponent("Hello.swift"))
        try XcodeProjectEditor.apply(projectURL: dir.appendingPathComponent("Demo.xcodeproj"), targetName: "Demo")
        let appURL = dir.appendingPathComponent("DemoApp.swift")
        try write(AppEntryInjector.inject(into: read(appURL), appKey: "pak_x")!, to: appURL)
        let initOnly = snapshot(dir).filter { !$0.key.hasSuffix(".patch-backup") }
        try prepare(dir, target: "Demo")
        XCTAssertEqual(unprepare(dir), [])
        // Back to exactly the post-`init` state: PatchSDK + configure stay, everything prepare added is gone.
        XCTAssertEqual(snapshot(dir), initOnly)
        XCTAssertNil(XcodeProjectEditor.plutilLint(dir.appendingPathComponent("Demo.xcodeproj/project.pbxproj")))
    }

    func testSynchronizedGroupProjectRoundTrip() throws {
        let dir = try tmp("sync")
        try write(PBXThunkIntegrationTests.synchronized, to: dir.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        try write(Self.mix, to: dir.appendingPathComponent("Sync/MixView.swift"))
        try write(Self.hello, to: dir.appendingPathComponent("Sync/Hello.swift"))
        let before = snapshot(dir)
        try prepare(dir, target: "Demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sync/Patch/Generated/PatchThunks.generated.swift").path))
        XCTAssertEqual(unprepare(dir), [])
        XCTAssertEqual(snapshot(dir), before)
    }

    func testSwiftPMPackageRoundTrip() throws {
        let dir = try tmp("spm")
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            platforms: [.iOS(.v16)],
            targets: [ .target(name: "App") ]
        )

        """, to: dir.appendingPathComponent("Package.swift"))
        try write(Self.mix, to: dir.appendingPathComponent("Sources/App/MixView.swift"))
        try write(Self.hello, to: dir.appendingPathComponent("Sources/App/Hello.swift"))
        let before = snapshot(dir)
        try prepare(dir, target: "App")
        XCTAssertTrue(read(dir.appendingPathComponent("Package.swift")).contains("PatchSwiftUI"))
        XCTAssertEqual(unprepare(dir, removeSDK: true), [])
        let after = snapshot(dir)
        for (k, v) in before where after[k] != v {
            XCTFail("\(k) not restored:\n--- expected ---\n\(v)\n--- got ---\n\(after[k] ?? "<missing>")")
        }
        XCTAssertEqual(Set(after.keys), Set(before.keys))
    }

    // MARK: - Only prepare's own `dynamic`

    func testDevelopersOwnDynamicIsKept() throws {
        let dir = try tmp("own-dynamic")
        try write("// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [ .target(name: \"App\") ])\n",
                  to: dir.appendingPathComponent("Package.swift"))
        let own = "import SwiftUI\nstruct Mine: View {\n    dynamic var body: some View { Text(\"mine\") }\n}\n"
        try write(own, to: dir.appendingPathComponent("Sources/App/Mine.swift"))
        try write(Self.hello, to: dir.appendingPathComponent("Sources/App/Hello.swift"))
        try prepare(dir, target: "App")
        XCTAssertEqual(unprepare(dir), [])
        XCTAssertEqual(read(dir.appendingPathComponent("Sources/App/Mine.swift")), own, "a `dynamic` prepare didn't insert must stay")
        XCTAssertEqual(read(dir.appendingPathComponent("Sources/App/Hello.swift")), Self.hello)
    }

    /// `--keep-dynamic` leaves prepare's body edits (the route) in place but removes the thunk blocks;
    /// the kept route keeps its PATCH-ROUTE fallback so the file still builds.
    func testKeepDynamicLeavesDynamicButRemovesBlocks() throws {
        let dir = try tmp("keep-dyn")
        try write("// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [ .target(name: \"App\") ])\n",
                  to: dir.appendingPathComponent("Package.swift"))
        try write(Self.mix, to: dir.appendingPathComponent("Sources/App/MixView.swift"))
        try prepare(dir, target: "App")
        XCTAssertEqual(unprepare(dir, keepDynamic: true), [])
        let t = read(dir.appendingPathComponent("Sources/App/MixView.swift"))
        XCTAssertTrue(t.contains("__patchRoute {"), t)
        XCTAssertFalse(t.contains(PatchAccessForwarding.beginMarker) || t.contains(ThunkGenerator.sameFileBeginMarker))
        XCTAssertTrue(t.hasSuffix("\n" + ThunkGenerator.routeFallbackBlock), t)
        XCTAssertTrue(ThunkGenerator.parses(t), t)
    }

    // MARK: - (13) Excluded files are cleaned automatically

    func testNewlyExcludedFileIsRestoredAndDroppedFromGeneratedFile() throws {
        let dir = try tmp("exclude")
        try write("// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [ .target(name: \"App\") ])\n",
                  to: dir.appendingPathComponent("Package.swift"))
        let mixURL = dir.appendingPathComponent("Sources/App/Mix/MixView.swift")
        try write(Self.mix, to: mixURL)
        try write(Self.hello, to: dir.appendingPathComponent("Sources/App/Hello.swift"))
        try prepare(dir, target: "App")
        XCTAssertTrue(read(mixURL).contains(PatchAccessForwarding.beginMarker))

        // The developer adds the file to `.Patch.yml` `exclude:` and prepares again (or builds —
        // auto-prepare runs the same code). No manual restore needed.
        try prepare(dir, target: "App", excludes: ["Mix/MixView.swift"])
        XCTAssertEqual(read(mixURL), Self.mix, "an excluded file must be restored to its original source")
        let gens = PatchUninstaller.generatedFolders(under: dir)
        let genText = gens.map { read($0.appendingPathComponent(ThunkGenerator.thunkFileName)) }.joined()
        XCTAssertFalse(genText.contains(#"typeName: "MixView""#), "excluded views must be dropped from the generated file")
        XCTAssertTrue(genText.contains(#"typeName: "Hello""#))
    }

    // MARK: - `prepare --verify` understands the PATCH-ACCESS block

    func testVerifierAttributesForwarderBlockErrorsToTheirView() throws {
        let r = ThunkGenerator().prepare(sources: [.init(url: URL(fileURLWithPath: "/p/MixView.swift"), text: Self.mix)],
                                         hybrid: true)
        let text = try XCTUnwrap(r.modifiedFiles.first?.text)
        let lines = text.components(separatedBy: "\n")
        let fwdLine = try XCTUnwrap(lines.firstIndex { $0.contains("__patch_subtitle") }) + 1
        let d = PrepareVerifier.Diagnostic(file: "/p/MixView.swift", line: fwdLine, column: 5, message: "error: boom")
        let a = PrepareVerifier.attribute([d], preparedViews: ["MixView", "MixTrackRow"], readFile: { _ in text })
        XCTAssertEqual(a.byView["MixView"]?.count, 1, "an error inside the forwarder block belongs to its view")
        // And keeping that view native restores its file (forwarders + body route gone).
        let native = ThunkGenerator().prepare(sources: [.init(url: URL(fileURLWithPath: "/p/MixView.swift"), text: text)],
                                              hybrid: true, nativeViews: ["MixView"])
        let restored = native.modifiedFiles.first?.text ?? text
        XCTAssertFalse(restored.contains(PatchAccessForwarding.beginMarker), restored)
        XCTAssertFalse(restored.contains("var body: some View { __patchRoute {\n        VStack"), restored)
        XCTAssertTrue(restored.contains("var body: some View {\n        VStack"), restored)
    }

    // MARK: - Pure transforms

    func testAppEntryInjectionInverseBothShapes() throws {
        // Fresh init created.
        let fresh = Self.appSwift
        let injected = try XCTUnwrap(AppEntryInjector.inject(into: fresh, appKey: "pak_x", appID: "a", fingerprint: "f"))
        XCTAssertEqual(PatchUninstaller.removeAppEntryInjection(injected).0, fresh)
        // Merged into an existing init.
        let withInit = """
        import SwiftUI

        @main
        struct DemoApp: App {
            init() {
                FirebaseApp.configure()
            }
            var body: some Scene { WindowGroup { Text("x") } }
        }

        """
        let merged = try XCTUnwrap(AppEntryInjector.inject(into: withInit, appKey: "pak_x"))
        XCTAssertEqual(PatchUninstaller.removeAppEntryInjection(merged).0, withInit)
    }

    func testGitignoreRuleInverse() {
        let original = "DerivedData/\n*.xcuserstate\n"
        let appended = original + "\n# Patch generated thunks (patchcli prepare)\nSources/App/Patch/Generated/\n"
        XCTAssertEqual(PatchUninstaller.removeGitignoreRule(appended), original)
    }
}
