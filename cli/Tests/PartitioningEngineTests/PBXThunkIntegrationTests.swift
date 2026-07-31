// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler

/// `PBXThunkIntegration` — the `patchcli prepare` project surgery that wires the
/// generated thunk file into a target's Sources phase and links the PatchSwiftUI
/// product, plus the SwiftPM `Package.swift` counterpart.
///
/// Two pbxproj group shapes are exercised:
///   • CLASSIC groups — the file MUST get an explicit ref + build file.
///   • SYNCHRONIZED groups (Xcode 16) — the file is auto-included by location,
///     so NO ref/build file may be added (that would double-compile it).
final class PBXThunkIntegrationTests: XCTestCase {

    // The generated thunk's conventional name.
    private static let thunkName = "PatchThunks.generated.swift"

    // MARK: - Fixtures

    /// Reuse the classic-group app fixture from OnboardingTests (no packages).
    private static var classic: String { OnboardingTests.pbxprojNoPackages }

    /// An Xcode-16 project whose `Demo` target owns a
    /// PBXFileSystemSynchronizedRootGroup at `path = Sync`. No classic source
    /// references — files are picked up by folder membership.
    static let synchronized = """
    // !$*UTF8*$!
    {
    \tarchiveVersion = 1;
    \tclasses = {
    \t};
    \tobjectVersion = 77;
    \tobjects = {

    /* Begin PBXFileSystemSynchronizedRootGroup section */
    \t\tAA0000000000000000000010 /* Sync */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Sync; sourceTree = "<group>"; };
    /* End PBXFileSystemSynchronizedRootGroup section */

    /* Begin PBXFrameworksBuildPhase section */
    \t\tAA0000000000000000000004 /* Frameworks */ = {
    \t\t\tisa = PBXFrameworksBuildPhase;
    \t\t\tbuildActionMask = 2147483647;
    \t\t\tfiles = (
    \t\t\t);
    \t\t\trunOnlyForDeploymentPostprocessing = 0;
    \t\t};
    /* End PBXFrameworksBuildPhase section */

    /* Begin PBXFileReference section */
    \t\tAA0000000000000000000003 /* Demo.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Demo.app; sourceTree = BUILT_PRODUCTS_DIR; };
    /* End PBXFileReference section */

    /* Begin PBXGroup section */
    \t\tAA0000000000000000000005 = {
    \t\t\tisa = PBXGroup;
    \t\t\tchildren = (
    \t\t\t\tAA0000000000000000000010 /* Sync */,
    \t\t\t\tAA0000000000000000000003 /* Demo.app */,
    \t\t\t);
    \t\t\tsourceTree = "<group>";
    \t\t};
    /* End PBXGroup section */

    /* Begin PBXNativeTarget section */
    \t\tAA0000000000000000000006 /* Demo */ = {
    \t\t\tisa = PBXNativeTarget;
    \t\t\tbuildConfigurationList = AA0000000000000000000007 /* Build configuration list for PBXNativeTarget "Demo" */;
    \t\t\tbuildPhases = (
    \t\t\t\tAA0000000000000000000008 /* Sources */,
    \t\t\t\tAA0000000000000000000004 /* Frameworks */,
    \t\t\t);
    \t\t\tbuildRules = (
    \t\t\t);
    \t\t\tdependencies = (
    \t\t\t);
    \t\t\tfileSystemSynchronizedGroups = (
    \t\t\t\tAA0000000000000000000010 /* Sync */,
    \t\t\t);
    \t\t\tname = Demo;
    \t\t\tproductName = Demo;
    \t\t\tproductReference = AA0000000000000000000003 /* Demo.app */;
    \t\t\tproductType = "com.apple.product-type.application";
    \t\t};
    /* End PBXNativeTarget section */

    /* Begin PBXProject section */
    \t\tAA0000000000000000000009 /* Project object */ = {
    \t\t\tisa = PBXProject;
    \t\t\tbuildConfigurationList = AA000000000000000000000A /* Build configuration list for PBXProject "Demo" */;
    \t\t\tcompatibilityVersion = "Xcode 16.0";
    \t\t\tdevelopmentRegion = en;
    \t\t\tmainGroup = AA0000000000000000000005;
    \t\t\tproductRefGroup = AA0000000000000000000005;
    \t\t\ttargets = (
    \t\t\t\tAA0000000000000000000006 /* Demo */,
    \t\t\t);
    \t\t};
    /* End PBXProject section */

    /* Begin PBXSourcesBuildPhase section */
    \t\tAA0000000000000000000008 /* Sources */ = {
    \t\t\tisa = PBXSourcesBuildPhase;
    \t\t\tbuildActionMask = 2147483647;
    \t\t\tfiles = (
    \t\t\t);
    \t\t\trunOnlyForDeploymentPostprocessing = 0;
    \t\t};
    /* End PBXSourcesBuildPhase section */

    /* Begin XCBuildConfiguration section */
    \t\tAA000000000000000000000B /* Release */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.demo;
    \t\t\t};
    \t\t\tname = Release;
    \t\t};
    /* End XCBuildConfiguration section */

    /* Begin XCConfigurationList section */
    \t\tAA0000000000000000000007 /* Build configuration list for PBXNativeTarget "Demo" */ = {
    \t\t\tisa = XCConfigurationList;
    \t\t\tbuildConfigurations = (
    \t\t\t\tAA000000000000000000000B /* Release */,
    \t\t\t);
    \t\t\tdefaultConfigurationIsVisible = 0;
    \t\t\tdefaultConfigurationName = Release;
    \t\t};
    \t\tAA000000000000000000000A /* Build configuration list for PBXProject "Demo" */ = {
    \t\t\tisa = XCConfigurationList;
    \t\t\tbuildConfigurations = (
    \t\t\t\tAA000000000000000000000B /* Release */,
    \t\t\t);
    \t\t\tdefaultConfigurationIsVisible = 0;
    \t\t\tdefaultConfigurationName = Release;
    \t\t};
    /* End XCConfigurationList section */
    \t};
    \trootObject = AA0000000000000000000009 /* Project object */;
    }
    """

    // MARK: - Helpers

    /// Create `<tmp>/<projName>.xcodeproj/project.pbxproj` with the given text,
    /// plus optionally a file on disk at `<tmp>/<relPath>`. Returns the
    /// .xcodeproj URL and the (possibly created) file URL.
    private func makeProject(
        _ pbxproj: String, projName: String = "Demo",
        fileRelativeToSourceRoot relPath: String
    ) throws -> (projectURL: URL, fileURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbxthunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectURL = root.appendingPathComponent("\(projName).xcodeproj")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try pbxproj.write(to: projectURL.appendingPathComponent("project.pbxproj"),
                          atomically: true, encoding: .utf8)
        let fileURL = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// thunk".write(to: fileURL, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (projectURL, fileURL)
    }

    private func pbx(_ projectURL: URL) throws -> String {
        try String(contentsOf: projectURL.appendingPathComponent("project.pbxproj"), encoding: .utf8)
    }

    /// Assert the PatchSwiftUI product is fully linked into a target.
    private func assertProductLinked(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(text.contains("repositoryURL = \"https://github.com/patch-release/patch-swift\""),
                      "package reference missing", file: file, line: line)
        XCTAssertTrue(text.contains("productName = PatchSwiftUI"),
                      "PatchSwiftUI product dependency missing", file: file, line: line)
        XCTAssertTrue(text.contains("packageProductDependencies = ("),
                      "target packageProductDependencies missing", file: file, line: line)
        // A productRef build file (NO fileRef) for the Frameworks phase.
        XCTAssertTrue(text.contains("/* PatchSwiftUI in Frameworks */ = {isa = PBXBuildFile; productRef ="),
                      "productRef build file missing", file: file, line: line)
        XCTAssertFalse(
            text.contains("/* PatchSwiftUI in Frameworks */ = {isa = PBXBuildFile; productRef = ")
                && text.range(of: "/* PatchSwiftUI in Frameworks */ = {isa = PBXBuildFile; productRef = [^}]*fileRef",
                              options: .regularExpression) != nil,
            "the PatchSwiftUI build file must NOT carry a fileRef", file: file, line: line)
    }

    // MARK: - Classic groups: file added to Sources phase

    func testClassicAddsFileToSourcesPhaseAndLinksProduct() throws {
        let (projectURL, fileURL) = try makeProject(
            Self.classic, fileRelativeToSourceRoot: Self.thunkName)
        let outcome = try ProjectIntegrator.wire(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        XCTAssertEqual(outcome, .added)

        let text = try pbx(projectURL)
        // The generated file got an explicit ref + build file in Sources.
        XCTAssertTrue(text.contains("/* \(Self.thunkName) */ = {isa = PBXFileReference;"),
                      "no PBXFileReference for the thunk file")
        XCTAssertTrue(text.contains("/* \(Self.thunkName) in Sources */ = {isa = PBXBuildFile; fileRef ="),
                      "no PBXBuildFile for the thunk file")
        // It must be IN the Sources phase files list (after the Sources phase isa).
        let sourcesPhase = try XCTUnwrap(text.range(of: "isa = PBXSourcesBuildPhase;"))
        let afterPhase = text[sourcesPhase.upperBound...]
        XCTAssertTrue(afterPhase.contains("/* \(Self.thunkName) in Sources */,"),
                      "thunk build file not added to the Sources phase files list")
        // And the product is linked.
        assertProductLinked(text)
        // The edited project still parses as a plist.
        XCTAssertNil(XcodeProjectEditor.plutilLint(
            projectURL.appendingPathComponent("project.pbxproj")))
    }

    func testClassicWritesBackupAndPassesLint() throws {
        let (projectURL, fileURL) = try makeProject(
            Self.classic, fileRelativeToSourceRoot: Self.thunkName)
        _ = try ProjectIntegrator.wire(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        // backup written holding the ORIGINAL bytes.
        let backup = try String(
            contentsOf: projectURL.appendingPathComponent("project.pbxproj.patch-backup"),
            encoding: .utf8)
        XCTAssertEqual(backup, Self.classic)
    }

    func testClassicIdempotent() throws {
        let (projectURL, fileURL) = try makeProject(
            Self.classic, fileRelativeToSourceRoot: Self.thunkName)
        let first = try ProjectIntegrator.wire(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        XCTAssertEqual(first, .added)
        let firstText = try pbx(projectURL)

        let second = try ProjectIntegrator.wire(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        XCTAssertEqual(second, .alreadyPresent, "a second wire must be a no-op")
        // Byte-identical: no duplicate ref / build file / product.
        XCTAssertEqual(try pbx(projectURL), firstText)
        // Exactly ONE build file for the thunk.
        XCTAssertEqual(
            firstText.components(separatedBy: "/* \(Self.thunkName) in Sources */ = {isa = PBXBuildFile;").count - 1,
            1, "the thunk must be added to Sources exactly once")
        // Exactly ONE PatchSwiftUI product dependency.
        XCTAssertEqual(
            firstText.components(separatedBy: "productName = PatchSwiftUI;").count - 1, 1,
            "PatchSwiftUI must be linked exactly once")
    }

    // MARK: - Synchronized groups: file auto-included (NOT added)

    func testSynchronizedDoesNotAddFileButLinksProduct() throws {
        // The file lives inside the synced folder on disk: <root>/Sync/<thunk>.
        let (projectURL, fileURL) = try makeProject(
            Self.synchronized, fileRelativeToSourceRoot: "Sync/\(Self.thunkName)")
        let outcome = try ProjectIntegrator.wire(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        XCTAssertEqual(outcome, .added, "the product still needs linking")

        let text = try pbx(projectURL)
        // CRITICAL: no PBXBuildFile / PBXFileReference for the thunk — it's
        // auto-included by the synchronized folder, and a duplicate would
        // double-compile it.
        XCTAssertFalse(text.contains(Self.thunkName),
                       "synchronized projects must NOT get an explicit ref/build file for the thunk")
        // The product IS linked.
        assertProductLinked(text)
        XCTAssertNil(XcodeProjectEditor.plutilLint(
            projectURL.appendingPathComponent("project.pbxproj")))
    }

    func testSynchronizedIsIdempotentOnSecondWire() throws {
        let (projectURL, fileURL) = try makeProject(
            Self.synchronized, fileRelativeToSourceRoot: "Sync/\(Self.thunkName)")
        let first = try ProjectIntegrator.wire(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        XCTAssertEqual(first, .added)
        let firstText = try pbx(projectURL)
        let second = try ProjectIntegrator.wire(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        XCTAssertEqual(second, .alreadyPresent)
        XCTAssertEqual(try pbx(projectURL), firstText)
    }

    /// A file OUTSIDE every synchronized folder must still be treated as a
    /// classic addition (synced detection is by on-disk containment, not by the
    /// mere presence of a synced group).
    func testFileOutsideSynchronizedFolderIsAddedExplicitly() throws {
        // File at <root>/Elsewhere/<thunk> — NOT under <root>/Sync.
        let (projectURL, fileURL) = try makeProject(
            Self.synchronized, fileRelativeToSourceRoot: "Elsewhere/\(Self.thunkName)")
        let outcome = try ProjectIntegrator.wire(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        XCTAssertEqual(outcome, .added)
        let text = try pbx(projectURL)
        XCTAssertTrue(text.contains("/* \(Self.thunkName) */ = {isa = PBXFileReference;"),
                      "a file outside the synced folder must get an explicit reference")
        XCTAssertNil(XcodeProjectEditor.plutilLint(
            projectURL.appendingPathComponent("project.pbxproj")))
    }

    // MARK: - Product-link details

    func testProductReusesExistingPatchSwiftReference() throws {
        // Start from a project that already references patch-swift (for the
        // PatchSDK product, as a prior `patchcli init` would have added). The
        // product link must REUSE that one reference, not add a second.
        let withPatchSDK = try XcodeProjectEditor.addPackage(to: Self.classic, targetName: "Demo").contents
        let (projectURL, fileURL) = try makeProject(
            withPatchSDK, fileRelativeToSourceRoot: Self.thunkName)
        let outcome = try ProjectIntegrator.wire(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        XCTAssertEqual(outcome, .added)
        let text = try pbx(projectURL)
        // BOTH products present…
        XCTAssertTrue(text.contains("productName = PatchSDK"))
        XCTAssertTrue(text.contains("productName = PatchSwiftUI"))
        // …sharing exactly ONE patch-swift remote reference.
        XCTAssertEqual(
            text.components(separatedBy: "repositoryURL = \"https://github.com/patch-release/patch-swift\"").count - 1,
            1, "the two products must share a single XCRemoteSwiftPackageReference")
        assertProductLinked(text)
        XCTAssertNil(XcodeProjectEditor.plutilLint(
            projectURL.appendingPathComponent("project.pbxproj")))
    }

    func testUnknownTargetThrows() throws {
        let (projectURL, fileURL) = try makeProject(
            Self.classic, fileRelativeToSourceRoot: Self.thunkName)
        XCTAssertThrowsError(try ProjectIntegrator.wire(
            projectURL: projectURL, target: "Nope", fileURL: fileURL, fm: .default))
    }

    func testNonOpenStepProjectThrows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbxthunk-xml-\(UUID().uuidString)")
        let projectURL = root.appendingPathComponent("Demo.xcodeproj")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "<?xml version=\"1.0\"?>".write(
            to: projectURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ProjectIntegrator.wire(
            projectURL: projectURL, target: "Demo",
            fileURL: root.appendingPathComponent(Self.thunkName), fm: .default))
    }

    // MARK: - Package.swift (wirePackage)

    /// Compile-check an edited manifest exactly like init's verify step.
    private func assertManifestEvaluates(_ manifest: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-pswiftui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)
        if let failure = PackageManifestEditor.dumpPackageFailure(packageDir: dir) {
            XCTFail("edited manifest does not evaluate: \(failure)\n\(manifest)", file: file, line: line)
        }
    }

    private static let manifest = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "Demo",
        platforms: [.iOS(.v16)],
        dependencies: [
            .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
        ],
        targets: [
            .target(
                name: "Demo",
                dependencies: [
                    .product(name: "Collections", package: "swift-collections"),
                ]
            ),
            .testTarget(name: "DemoTests", dependencies: ["Demo"]),
        ]
    )
    """

    func testWirePackageAddsProductAndPackage() throws {
        let (outcome, text) = try PBXThunkIntegration.addProduct(
            to: Self.manifest, targetName: "Demo")
        XCTAssertEqual(outcome, .added)
        XCTAssertTrue(text.contains(".product(name: \"PatchSwiftUI\", package: \"patch-swift\")"),
                      "PatchSwiftUI product not added to the target")
        XCTAssertTrue(text.contains(".package(url: \"https://github.com/patch-release/patch-swift\", from: \"1.0.0\")"),
                      "patch-swift package dependency not added")
        // Landed in Demo, not the test target.
        let testPart = text.components(separatedBy: ".testTarget").last!
        XCTAssertFalse(testPart.contains("PatchSwiftUI"))
        // Existing deps survive.
        XCTAssertTrue(text.contains("swift-collections"))
        try assertManifestEvaluates(text)
    }

    /// When patch-swift is ALREADY a package dependency (a prior PatchSDK add),
    /// wirePackage adds only the product line — no duplicate `.package(...)`.
    func testWirePackageReusesExistingPatchSwiftDependency() throws {
        let withPatchSDK = try PackageManifestEditor.addPackage(
            to: Self.manifest, targetName: "Demo").contents
        let (outcome, text) = try PBXThunkIntegration.addProduct(
            to: withPatchSDK, targetName: "Demo")
        XCTAssertEqual(outcome, .added)
        // Both products on the target.
        XCTAssertTrue(text.contains(".product(name: \"PatchSDK\", package: \"patch-swift\")"))
        XCTAssertTrue(text.contains(".product(name: \"PatchSwiftUI\", package: \"patch-swift\")"))
        // Exactly ONE patch-swift package line.
        XCTAssertEqual(
            text.components(separatedBy: ".package(url: \"https://github.com/patch-release/patch-swift\"").count - 1,
            1, "patch-swift must be declared as a dependency only once")
        try assertManifestEvaluates(text)
    }

    func testWirePackageIdempotent() throws {
        let (_, once) = try PBXThunkIntegration.addProduct(to: Self.manifest, targetName: "Demo")
        let (again, twice) = try PBXThunkIntegration.addProduct(to: once, targetName: "Demo")
        XCTAssertEqual(again, .alreadyPresent)
        XCTAssertEqual(once, twice)
    }

    func testWirePackageUnknownTargetThrows() {
        XCTAssertThrowsError(
            try PBXThunkIntegration.addProduct(to: Self.manifest, targetName: "Nope"))
    }

    func testWirePackageBareTargetCreatesDependencyArrays() throws {
        let bare = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Solo",
            targets: [
                .target(name: "Solo"),
            ]
        )
        """
        let (outcome, text) = try PBXThunkIntegration.addProduct(to: bare, targetName: "Solo")
        XCTAssertEqual(outcome, .added)
        XCTAssertTrue(text.contains(".product(name: \"PatchSwiftUI\", package: \"patch-swift\")"))
        XCTAssertTrue(text.contains(".package(url: \"https://github.com/patch-release/patch-swift\""))
        try assertManifestEvaluates(text)
    }

    /// End-to-end through `wirePackage` (file IO + backup + dump-package verify).
    func testWirePackageApplyWritesBackupAndVerifies() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-apply-pswiftui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let manifestURL = dir.appendingPathComponent("Package.swift")
        try Self.manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        let outcome = try ProjectIntegrator.wirePackage(packageDir: dir, target: "Demo", fm: .default)
        XCTAssertEqual(outcome, .added)
        let edited = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(edited.contains(".product(name: \"PatchSwiftUI\", package: \"patch-swift\")"))
        let backup = try String(
            contentsOf: dir.appendingPathComponent("Package.swift.patch-backup"), encoding: .utf8)
        XCTAssertEqual(backup, Self.manifest)
    }
}
