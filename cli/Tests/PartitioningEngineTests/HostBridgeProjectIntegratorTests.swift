// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler
import CodeGenerator

/// `HostBridgeProjectIntegrator` — LEVER #2's `prepare`/`build`-side wiring that
/// installs the engine-generated host-bridge resolver thunk into the developer's
/// app with zero manual steps:
///
///   (1) add `PatchHostBridges.generated.swift` to the app target (pbxproj Sources
///       phase + the PatchSDK product link, OR Package.swift product link), reusing
///       the SAME PBXThunkIntegration / XcodeProjectEditor / PackageManifestEditor
///       machinery the SwiftUI thunk uses (classic + synchronized groups), and
///   (2) inject the one-time `Patch.shared.onRegisterHostBridges(__patchRegisterHostBridges)`
///       install into the `@main` app entry, mirroring AppEntryInjector.
///
/// The discipline asserted here: ADD-ONCE (idempotent re-run = no-op) and
/// BACKUP/RESTORE-ON-FAIL (a malformed project restores byte-for-byte, never
/// corrupted).
final class HostBridgeProjectIntegratorTests: XCTestCase {

    // The engine's generated resolver-thunk file name.
    private static var thunkName: String { HostBridgeThunkGenerator.fileName }

    // Reuse the existing fixtures (classic + synchronized pbxproj).
    private static var classic: String { OnboardingTests.pbxprojNoPackages }
    private static var synchronized: String { PBXThunkIntegrationTests.synchronized }

    // MARK: - Project fixture helpers (mirror PBXThunkIntegrationTests)

    private func makeProject(
        _ pbxproj: String, projName: String = "Demo",
        fileRelativeToSourceRoot relPath: String
    ) throws -> (root: URL, projectURL: URL, fileURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hb-integ-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectURL = root.appendingPathComponent("\(projName).xcodeproj")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try pbxproj.write(to: projectURL.appendingPathComponent("project.pbxproj"),
                          atomically: true, encoding: .utf8)
        let fileURL = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// \(Self.thunkName)\nfunc \(HostBridgeThunkGenerator.registerFunctionName)(_ b: Any) {}"
            .write(to: fileURL, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, projectURL, fileURL)
    }

    private func pbx(_ projectURL: URL) throws -> String {
        try String(contentsOf: projectURL.appendingPathComponent("project.pbxproj"), encoding: .utf8)
    }

    // MARK: - (1) File → app target (classic groups)

    func testClassicAddsFileToSourcesPhaseAndLinksPatchSDK() throws {
        let (_, projectURL, fileURL) = try makeProject(
            Self.classic, fileRelativeToSourceRoot: Self.thunkName)
        let outcome = try HostBridgeProjectIntegrator.wireFile(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        XCTAssertEqual(outcome, .added)

        let text = try pbx(projectURL)
        // Explicit ref + build file in Sources for the generated file.
        XCTAssertTrue(text.contains("/* \(Self.thunkName) */ = {isa = PBXFileReference;"),
                      "no PBXFileReference for the generated host-bridge file")
        XCTAssertTrue(text.contains("/* \(Self.thunkName) in Sources */ = {isa = PBXBuildFile; fileRef ="),
                      "no PBXBuildFile for the generated host-bridge file")
        let sourcesPhase = try XCTUnwrap(text.range(of: "isa = PBXSourcesBuildPhase;"))
        XCTAssertTrue(text[sourcesPhase.upperBound...].contains("/* \(Self.thunkName) in Sources */,"),
                      "generated file not added to the Sources phase files list")
        // The PatchSDK product is linked (the file imports PatchSDK/PatchHostBridge).
        XCTAssertTrue(text.contains("productName = PatchSDK"), "PatchSDK product not linked")
        XCTAssertTrue(text.contains("repositoryURL = \"https://github.com/patch-release/patch-swift\""),
                      "patch-swift package reference missing")
        // The edit still parses as a plist.
        XCTAssertNil(XcodeProjectEditor.plutilLint(
            projectURL.appendingPathComponent("project.pbxproj")))
    }

    func testClassicWritesBackupHoldingTheOriginal() throws {
        let (_, projectURL, fileURL) = try makeProject(
            Self.classic, fileRelativeToSourceRoot: Self.thunkName)
        _ = try HostBridgeProjectIntegrator.wireFile(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        let backup = try String(
            contentsOf: projectURL.appendingPathComponent("project.pbxproj.patch-backup"),
            encoding: .utf8)
        XCTAssertEqual(backup, Self.classic)
    }

    func testClassicIdempotentReRunIsNoOp() throws {
        let (_, projectURL, fileURL) = try makeProject(
            Self.classic, fileRelativeToSourceRoot: Self.thunkName)
        let first = try HostBridgeProjectIntegrator.wireFile(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        XCTAssertEqual(first, .added)
        let firstText = try pbx(projectURL)

        let second = try HostBridgeProjectIntegrator.wireFile(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        XCTAssertEqual(second, .alreadyPresent, "a second wire must be a no-op")
        XCTAssertEqual(try pbx(projectURL), firstText, "re-run must be byte-identical")
        // Exactly ONE build file + ONE PatchSDK product (no duplicates).
        XCTAssertEqual(
            firstText.components(separatedBy: "/* \(Self.thunkName) in Sources */ = {isa = PBXBuildFile;").count - 1,
            1, "the file must be added to Sources exactly once")
        XCTAssertEqual(
            firstText.components(separatedBy: "productName = PatchSDK;").count - 1, 1,
            "PatchSDK must be linked exactly once")
    }

    // MARK: - (1) File → app target (synchronized groups)

    func testSynchronizedDoesNotAddFileButLinksPatchSDK() throws {
        // File lives inside the synced folder on disk: <root>/Sync/<thunk>.
        let (_, projectURL, fileURL) = try makeProject(
            Self.synchronized, fileRelativeToSourceRoot: "Sync/\(Self.thunkName)")
        let outcome = try HostBridgeProjectIntegrator.wireFile(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default)
        XCTAssertEqual(outcome, .added, "the product still needs linking")

        let text = try pbx(projectURL)
        // CRITICAL: no explicit ref/build file — the synced folder auto-includes it
        // and a duplicate would double-compile (redeclaration of the registrar fn).
        XCTAssertFalse(text.contains(Self.thunkName),
                       "synchronized projects must NOT get an explicit ref for the generated file")
        XCTAssertTrue(text.contains("productName = PatchSDK"), "PatchSDK product not linked")
        XCTAssertNil(XcodeProjectEditor.plutilLint(
            projectURL.appendingPathComponent("project.pbxproj")))
    }

    // MARK: - (1) Restore-on-fail / certainty

    func testUnknownTargetThrowsAndLeavesProjectUntouched() throws {
        let (_, projectURL, fileURL) = try makeProject(
            Self.classic, fileRelativeToSourceRoot: Self.thunkName)
        XCTAssertThrowsError(try HostBridgeProjectIntegrator.wireFile(
            projectURL: projectURL, target: "Nope", fileURL: fileURL, fm: .default))
        // The transform throws BEFORE any write — project is byte-identical, no backup.
        XCTAssertEqual(try pbx(projectURL), Self.classic)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent("project.pbxproj.patch-backup").path),
            "a thrown (un-attempted) edit must not write a backup")
    }

    func testMalformedProjectRestoresCleanly() throws {
        // A header-valid OpenStep project missing the Frameworks build phase: the
        // file-add succeeds but the PatchSDK product link throws (no Frameworks
        // phase). The integrator must restore the original byte-for-byte.
        let noFrameworks = Self.classic
            .replacingOccurrences(
                of: "\t\t\t\tAA0000000000000000000004 /* Frameworks */,\n", with: "")
            .replacingOccurrences(
                of: """
                /* Begin PBXFrameworksBuildPhase section */
                \t\tAA0000000000000000000004 /* Frameworks */ = {
                \t\t\tisa = PBXFrameworksBuildPhase;
                \t\t\tbuildActionMask = 2147483647;
                \t\t\tfiles = (
                \t\t\t);
                \t\t\trunOnlyForDeploymentPostprocessing = 0;
                \t\t};
                /* End PBXFrameworksBuildPhase section */
                """, with: "")
        let (_, projectURL, fileURL) = try makeProject(
            noFrameworks, fileRelativeToSourceRoot: Self.thunkName)
        XCTAssertThrowsError(try HostBridgeProjectIntegrator.wireFile(
            projectURL: projectURL, target: "Demo", fileURL: fileURL, fm: .default))
        // Restored byte-for-byte — never left half-edited / corrupt.
        XCTAssertEqual(try pbx(projectURL), noFrameworks,
                       "a project that couldn't be fully wired must be restored unchanged")
    }

    func testNonOpenStepProjectThrows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hb-xml-\(UUID().uuidString)")
        let projectURL = root.appendingPathComponent("Demo.xcodeproj")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "<?xml version=\"1.0\"?>".write(
            to: projectURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try HostBridgeProjectIntegrator.wireFile(
            projectURL: projectURL, target: "Demo",
            fileURL: root.appendingPathComponent(Self.thunkName), fm: .default))
    }

    // MARK: - (1) Package.swift

    private static let manifest = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "Demo",
        platforms: [.iOS(.v16)],
        targets: [
            .target(name: "Demo"),
            .testTarget(name: "DemoTests", dependencies: ["Demo"]),
        ]
    )
    """

    func testWirePackageAddsPatchSDKProduct() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hb-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try Self.manifest.write(to: dir.appendingPathComponent("Package.swift"),
                                atomically: true, encoding: .utf8)

        let outcome = try HostBridgeProjectIntegrator.wirePackage(
            packageDir: dir, target: "Demo", fm: .default)
        XCTAssertEqual(outcome, .added)
        let edited = try String(contentsOf: dir.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(edited.contains(".product(name: \"PatchSDK\", package: \"patch-swift\")"))
        XCTAssertTrue(edited.contains(".package(url: \"https://github.com/patch-release/patch-swift\""))
        // Backup holds the original.
        let backup = try String(
            contentsOf: dir.appendingPathComponent("Package.swift.patch-backup"), encoding: .utf8)
        XCTAssertEqual(backup, Self.manifest)

        // Idempotent re-run.
        let again = try HostBridgeProjectIntegrator.wirePackage(
            packageDir: dir, target: "Demo", fm: .default)
        XCTAssertEqual(again, .alreadyPresent)
    }

    // MARK: - (2) Registrar injection (pure transform)

    private static let appKeyOnly = """
    import SwiftUI
    import PatchSDK

    @main
    struct DemoApp: App {
        init() {
            Patch.configure(.init(appKey: "pak_x"))
            Task { await Patch.shared.start() }
        }
        var body: some Scene { WindowGroup { ContentView() } }
    }
    """

    private static let appFullForm = """
    import SwiftUI
    import PatchSDK

    @main
    struct DemoApp: App {
        init() {
            Patch.configure(.init(
                appKey: "pak_x",
                appID: "id-1",
                fingerprint: "ff"))
            Task { await Patch.shared.start() }
        }
        var body: some Scene { WindowGroup { ContentView() } }
    }
    """

    func testInjectRegistrarAfterConfigureKeyOnly() throws {
        let out = try XCTUnwrap(HostBridgeProjectIntegrator.injectRegistrar(into: Self.appKeyOnly))
        XCTAssertTrue(out.contains(HostBridgeProjectIntegrator.registrarInstallCall),
                      "registrar install line not inserted")
        // Inserted AFTER configure, BEFORE start().
        let cfgPos = try XCTUnwrap(out.range(of: "Patch.configure(")).lowerBound
        let regPos = try XCTUnwrap(out.range(of: "onRegisterHostBridges(")).lowerBound
        let startPos = try XCTUnwrap(out.range(of: "Patch.shared.start()")).lowerBound
        XCTAssertLessThan(cfgPos, regPos)
        XCTAssertLessThan(regPos, startPos)
        // Indented to match the configure call (8 spaces inside init()).
        XCTAssertTrue(out.contains("        \(HostBridgeProjectIntegrator.registrarInstallCall)"),
                      "registrar line not indented to match configure")
    }

    func testInjectRegistrarAfterMultiLineConfigure() throws {
        let out = try XCTUnwrap(HostBridgeProjectIntegrator.injectRegistrar(into: Self.appFullForm))
        // The multi-line `Patch.configure(.init( … ))` close paren is matched
        // depth-correctly, so the registrar lands after the WHOLE call, before start().
        let regPos = try XCTUnwrap(out.range(of: "onRegisterHostBridges(")).lowerBound
        let fpPos = try XCTUnwrap(out.range(of: "fingerprint: \"ff\"")).lowerBound
        let startPos = try XCTUnwrap(out.range(of: "Patch.shared.start()")).lowerBound
        XCTAssertLessThan(fpPos, regPos, "registrar must come after the full multi-line configure")
        XCTAssertLessThan(regPos, startPos)
    }

    func testInjectRegistrarIsIdempotent() throws {
        let once = try XCTUnwrap(HostBridgeProjectIntegrator.injectRegistrar(into: Self.appKeyOnly))
        // A second pass over the already-injected source is a no-op (returns nil).
        XCTAssertNil(HostBridgeProjectIntegrator.injectRegistrar(into: once),
                     "re-injecting must be a no-op")
        // Exactly one registrar line.
        XCTAssertEqual(once.components(separatedBy: "onRegisterHostBridges(").count - 1, 1)
    }

    func testInjectRegistrarNoConfigureReturnsNil() {
        let noConfigure = """
        import SwiftUI
        @main
        struct DemoApp: App {
            var body: some Scene { WindowGroup { ContentView() } }
        }
        """
        XCTAssertNil(HostBridgeProjectIntegrator.injectRegistrar(into: noConfigure),
                     "with no Patch.configure to anchor on, there's nothing to inject")
    }

    // MARK: - (2) Registrar injection (propose / apply on disk)

    private func makeAppDir(_ source: String, named name: String = "DemoApp.swift") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hb-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try source.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testProposeAndApplyRegistrarOnDisk() throws {
        let dir = try makeAppDir(Self.appKeyOnly)
        guard case .proposed(let injection) = HostBridgeProjectIntegrator.proposeRegistrar(in: dir) else {
            return XCTFail("expected a proposed registrar injection")
        }
        XCTAssertTrue(injection.diff.contains("+ "), "diff should show the inserted line")
        try HostBridgeProjectIntegrator.applyRegistrar(injection)
        let written = try String(contentsOf: injection.fileURL, encoding: .utf8)
        XCTAssertTrue(written.contains(HostBridgeProjectIntegrator.registrarInstallCall))
        // Backup holds the original.
        let backup = try String(
            contentsOf: injection.fileURL.appendingPathExtension("patch-backup"), encoding: .utf8)
        XCTAssertEqual(backup, Self.appKeyOnly)

        // Re-propose: now already installed → no-op.
        if case .alreadyInstalled = HostBridgeProjectIntegrator.proposeRegistrar(in: dir) {
            // expected
        } else {
            XCTFail("a second propose must report alreadyInstalled")
        }
    }

    func testProposeRegistrarNoEntryReturnsNotFound() throws {
        // An app whose sources never call Patch.configure → nothing to anchor on.
        let dir = try makeAppDir("""
        import SwiftUI
        struct ContentView: View { var body: some View { Text("hi") } }
        """)
        if case .notFound = HostBridgeProjectIntegrator.proposeRegistrar(in: dir) {
            // expected
        } else {
            XCTFail("expected notFound with no Patch.configure call")
        }
    }

    // MARK: - Flag gate (default OFF)

    func testIsEnabledDefaultsOff() {
        XCTAssertFalse(HostBridgeProjectIntegrator.isEnabled([:]))
        XCTAssertFalse(HostBridgeProjectIntegrator.isEnabled(["PATCH_HOST_BRIDGE": "0"]))
        XCTAssertTrue(HostBridgeProjectIntegrator.isEnabled(["PATCH_HOST_BRIDGE": "1"]))
    }
}
