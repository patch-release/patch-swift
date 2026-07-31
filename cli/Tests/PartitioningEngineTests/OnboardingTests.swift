// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler

/// The `patchcli init` onboarding automation: the link-wait poll loop, the
/// pbxproj package editor, and the App.swift startup-code injector.
final class OnboardingTests: XCTestCase {

    // MARK: - CliLinkWait (poll-loop decision logic)

    private struct ScriptedLinkAPI: CliLinkAPI {
        let script: [Result<CliLinkPollResult, Error>]
        // Class box so the value-typed API can advance through the script.
        final class Counter: @unchecked Sendable { var i = 0 }
        let counter = Counter()

        func createLink(bundleId: String, name: String, platform: String) throws -> CliLinkSession {
            CliLinkSession(code: "c", pollSecret: "s", connectURL: "u",
                           expiresInSeconds: 900, pollIntervalSeconds: 1)
        }
        func poll(code: String, secret: String) throws -> CliLinkPollResult {
            defer { counter.i += 1 }
            let step = min(counter.i, script.count - 1)
            switch script[step] {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }

    private let testApp = CliLinkPollResult.LinkedApp(
        id: "app-1", workspaceId: "ws-1", name: "Demo", bundleId: "com.x.demo", appKey: "pak_abc")

    private func session(expires: Int = 900) -> CliLinkSession {
        CliLinkSession(code: "c", pollSecret: "s", connectURL: "u",
                       expiresInSeconds: expires, pollIntervalSeconds: 1)
    }

    func testWaitReturnsLinkedAfterPending() {
        let api = ScriptedLinkAPI(script: [
            .success(.pending), .success(.pending),
            .success(.confirmed(app: testApp, reusedExisting: true)),
        ])
        let outcome = CliLinkWait.wait(api: api, session: session(), sleeper: { _ in })
        XCTAssertEqual(outcome, .linked(testApp, reusedExisting: true))
    }

    func testWaitToleratesTransientErrorsThenSucceeds() {
        struct Boom: Error {}
        let api = ScriptedLinkAPI(script: [
            .failure(Boom()), .failure(Boom()),
            .success(.confirmed(app: testApp, reusedExisting: false)),
        ])
        let outcome = CliLinkWait.wait(api: api, session: session(), sleeper: { _ in })
        XCTAssertEqual(outcome, .linked(testApp, reusedExisting: false))
    }

    func testWaitGivesUpAfterConsecutiveErrors() {
        struct Boom: Error {}
        let api = ScriptedLinkAPI(script: [.failure(Boom())])
        let outcome = CliLinkWait.wait(api: api, session: session(), sleeper: { _ in })
        if case .failed = outcome {} else {
            XCTFail("expected .failed after persistent errors, got \(outcome)")
        }
    }

    func testWaitExpiredAndConsumedAreTerminal() {
        XCTAssertEqual(
            CliLinkWait.wait(api: ScriptedLinkAPI(script: [.success(.expired)]),
                             session: session(), sleeper: { _ in }),
            .expired)
        XCTAssertEqual(
            CliLinkWait.wait(api: ScriptedLinkAPI(script: [.success(.consumed)]),
                             session: session(), sleeper: { _ in }),
            .consumed)
    }

    func testWaitTimesOutAtDeadline() {
        let api = ScriptedLinkAPI(script: [.success(.pending)])
        // Clock that jumps past the deadline after the first poll.
        final class Clock: @unchecked Sendable { var calls = 0 }
        let clock = Clock()
        let outcome = CliLinkWait.wait(
            api: api, session: session(expires: 10),
            now: {
                clock.calls += 1
                return clock.calls <= 2 ? Date(timeIntervalSince1970: 0)
                                        : Date(timeIntervalSince1970: 1_000)
            },
            sleeper: { _ in })
        XCTAssertEqual(outcome, .timedOut)
    }

    // MARK: - XcodeProjectEditor fixtures

    /// A minimal but structurally-faithful Xcode app project with NO existing
    /// package dependencies (the section-creation path).
    static let pbxprojNoPackages = """
    // !$*UTF8*$!
    {
    \tarchiveVersion = 1;
    \tclasses = {
    \t};
    \tobjectVersion = 56;
    \tobjects = {

    /* Begin PBXBuildFile section */
    \t\tAA0000000000000000000001 /* DemoApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA0000000000000000000002 /* DemoApp.swift */; };
    /* End PBXBuildFile section */

    /* Begin PBXFileReference section */
    \t\tAA0000000000000000000002 /* DemoApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DemoApp.swift; sourceTree = "<group>"; };
    \t\tAA0000000000000000000003 /* Demo.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Demo.app; sourceTree = BUILT_PRODUCTS_DIR; };
    /* End PBXFileReference section */

    /* Begin PBXFrameworksBuildPhase section */
    \t\tAA0000000000000000000004 /* Frameworks */ = {
    \t\t\tisa = PBXFrameworksBuildPhase;
    \t\t\tbuildActionMask = 2147483647;
    \t\t\tfiles = (
    \t\t\t);
    \t\t\trunOnlyForDeploymentPostprocessing = 0;
    \t\t};
    /* End PBXFrameworksBuildPhase section */

    /* Begin PBXGroup section */
    \t\tAA0000000000000000000005 = {
    \t\t\tisa = PBXGroup;
    \t\t\tchildren = (
    \t\t\t\tAA0000000000000000000002 /* DemoApp.swift */,
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
    \t\t\tname = Demo;
    \t\t\tproductName = Demo;
    \t\t\tproductReference = AA0000000000000000000003 /* Demo.app */;
    \t\t\tproductType = "com.apple.product-type.application";
    \t\t};
    /* End PBXNativeTarget section */

    /* Begin PBXProject section */
    \t\tAA0000000000000000000009 /* Project object */ = {
    \t\t\tisa = PBXProject;
    \t\t\tattributes = {
    \t\t\t\tBuildIndependentTargetsInParallel = 1;
    \t\t\t};
    \t\t\tbuildConfigurationList = AA000000000000000000000A /* Build configuration list for PBXProject "Demo" */;
    \t\t\tcompatibilityVersion = "Xcode 14.0";
    \t\t\tdevelopmentRegion = en;
    \t\t\thasScannedForEncodings = 0;
    \t\t\tknownRegions = (
    \t\t\t\ten,
    \t\t\t\tBase,
    \t\t\t);
    \t\t\tmainGroup = AA0000000000000000000005;
    \t\t\tproductRefGroup = AA0000000000000000000005;
    \t\t\tprojectDirPath = "";
    \t\t\tprojectRoot = "";
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
    \t\t\t\tAA0000000000000000000001 /* DemoApp.swift in Sources */,
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

    /// A project that ALREADY has one package dependency (the append path),
    /// with an existing packageReferences / packageProductDependencies list.
    static let pbxprojWithPackages = pbxprojNoPackages
        .replacingOccurrences(
            of: "\t\t\tmainGroup = AA0000000000000000000005;",
            with: "\t\t\tmainGroup = AA0000000000000000000005;\n"
                + "\t\t\tpackageReferences = (\n"
                + "\t\t\t\tBB0000000000000000000001 /* XCRemoteSwiftPackageReference \"swift-collections\" */,\n"
                + "\t\t\t);")
        .replacingOccurrences(
            of: "\t\t\tname = Demo;",
            with: "\t\t\tname = Demo;\n"
                + "\t\t\tpackageProductDependencies = (\n"
                + "\t\t\t\tBB0000000000000000000002 /* Collections */,\n"
                + "\t\t\t);")
        .replacingOccurrences(
            of: "/* End XCConfigurationList section */",
            with: """
            /* End XCConfigurationList section */

            /* Begin XCRemoteSwiftPackageReference section */
            \t\tBB0000000000000000000001 /* XCRemoteSwiftPackageReference "swift-collections" */ = {
            \t\t\tisa = XCRemoteSwiftPackageReference;
            \t\t\trepositoryURL = "https://github.com/apple/swift-collections";
            \t\t\trequirement = {
            \t\t\t\tkind = upToNextMajorVersion;
            \t\t\t\tminimumVersion = 1.0.0;
            \t\t\t};
            \t\t};
            /* End XCRemoteSwiftPackageReference section */

            /* Begin XCSwiftPackageProductDependency section */
            \t\tBB0000000000000000000002 /* Collections */ = {
            \t\t\tisa = XCSwiftPackageProductDependency;
            \t\t\tpackage = BB0000000000000000000001 /* XCRemoteSwiftPackageReference "swift-collections" */;
            \t\t\tproductName = Collections;
            \t\t};
            /* End XCSwiftPackageProductDependency section */
            """)

    // MARK: - XcodeProjectEditor

    func assertPatchWiring(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(text.contains("repositoryURL = \"https://github.com/patch-release/patch-swift\""),
                      "package reference missing", file: file, line: line)
        XCTAssertTrue(text.contains("productName = PatchSDK"), "product dependency missing", file: file, line: line)
        XCTAssertTrue(text.contains("/* PatchSDK in Frameworks */ = {isa = PBXBuildFile;"),
                      "build file missing", file: file, line: line)
        // Wired into the project + target + frameworks phase.
        XCTAssertTrue(text.contains("packageReferences = ("), file: file, line: line)
        XCTAssertTrue(text.contains("packageProductDependencies = ("), file: file, line: line)
        // The Frameworks files list must reference the build file.
        guard let phase = text.range(of: "isa = PBXFrameworksBuildPhase;") else {
            return XCTFail("no frameworks phase", file: file, line: line)
        }
        let after = text[phase.upperBound...]
        XCTAssertTrue(after.contains("/* PatchSDK in Frameworks */,"),
                      "frameworks phase files list not updated", file: file, line: line)
    }

    func testAddPackageToProjectWithoutAnyPackages() throws {
        let (result, text) = try XcodeProjectEditor.addPackage(
            to: Self.pbxprojNoPackages, targetName: "Demo")
        XCTAssertEqual(result, .added)
        assertPatchWiring(text)
        // Created the two sections it needed.
        XCTAssertTrue(text.contains("/* Begin XCRemoteSwiftPackageReference section */"))
        XCTAssertTrue(text.contains("/* Begin XCSwiftPackageProductDependency section */"))
    }

    func testAddPackageAppendsToExistingPackageLists() throws {
        let (result, text) = try XcodeProjectEditor.addPackage(
            to: Self.pbxprojWithPackages, targetName: "Demo")
        XCTAssertEqual(result, .added)
        assertPatchWiring(text)
        // The pre-existing package survives untouched.
        XCTAssertTrue(text.contains("swift-collections"))
        XCTAssertTrue(text.contains("BB0000000000000000000002 /* Collections */,"))
    }

    func testAddPackageIsIdempotent() throws {
        let (_, once) = try XcodeProjectEditor.addPackage(
            to: Self.pbxprojNoPackages, targetName: "Demo")
        let (again, twice) = try XcodeProjectEditor.addPackage(to: once, targetName: "Demo")
        XCTAssertEqual(again, .alreadyPresent)
        XCTAssertEqual(once, twice)
    }

    func testAddPackageUnknownTargetThrows() {
        XCTAssertThrowsError(
            try XcodeProjectEditor.addPackage(to: Self.pbxprojNoPackages, targetName: "Nope"))
    }

    func testAddPackageRejectsNonOpenStepFormats() {
        XCTAssertThrowsError(
            try XcodeProjectEditor.addPackage(to: "<?xml version=\"1.0\"?>", targetName: "Demo"))
    }

    func testQuotedTargetNameIsFound() throws {
        let quoted = Self.pbxprojNoPackages
            .replacingOccurrences(of: "name = Demo;", with: "name = \"My Demo\";")
        let (result, text) = try XcodeProjectEditor.addPackage(to: quoted, targetName: "My Demo")
        XCTAssertEqual(result, .added)
        assertPatchWiring(text)
    }

    /// End-to-end through `apply`: backup written, plutil verification passes,
    /// and the edited file still parses as a plist.
    func testApplyEditsRealFileWithBackupAndVerification() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbxedit-\(UUID().uuidString)/Demo.xcodeproj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let pbx = dir.appendingPathComponent("project.pbxproj")
        try Self.pbxprojNoPackages.write(to: pbx, atomically: true, encoding: .utf8)

        let result = try XcodeProjectEditor.apply(projectURL: dir, targetName: "Demo")
        XCTAssertEqual(result, .added)
        let edited = try String(contentsOf: pbx, encoding: .utf8)
        assertPatchWiring(edited)
        // Backup holds the original bytes.
        let backup = try String(
            contentsOf: dir.appendingPathComponent("project.pbxproj.patch-backup"),
            encoding: .utf8)
        XCTAssertEqual(backup, Self.pbxprojNoPackages)
        // And the edited file is plutil-clean.
        XCTAssertNil(XcodeProjectEditor.plutilLint(pbx))
    }

    // MARK: - AppEntryInjector

    static let appSwift = """
    import SwiftUI

    @main
    struct DemoApp: App {
        var body: some Scene {
            WindowGroup {
                ContentView()
            }
        }
    }
    """

    func testInjectAddsImportAndInit() throws {
        let out = try XCTUnwrap(AppEntryInjector.inject(into: Self.appSwift, appKey: "pak_test123"))
        XCTAssertTrue(out.contains("import PatchSDK"))
        XCTAssertTrue(out.contains("Patch.configure(.init(appKey: \"pak_test123\"))"))
        XCTAssertTrue(out.contains("Task { await Patch.shared.start() }"))
        // import lands after the existing import, init inside the struct.
        let importPos = try XCTUnwrap(out.range(of: "import PatchSDK")).lowerBound
        let swiftUIPos = try XCTUnwrap(out.range(of: "import SwiftUI")).lowerBound
        XCTAssertGreaterThan(importPos, swiftUIPos)
        let initPos = try XCTUnwrap(out.range(of: "init() {")).lowerBound
        let bodyPos = try XCTUnwrap(out.range(of: "var body")).lowerBound
        XCTAssertLessThan(initPos, bodyPos)
    }

    func testInjectFullFormBakesAppIDAndFingerprint() throws {
        // init's blessed path: appID keeps pre-1.0.2 SDKs polling, fingerprint
        // opts the device into exact native-shell gating.
        let fp = String(repeating: "ab", count: 32)
        let out = try XCTUnwrap(AppEntryInjector.inject(
            into: Self.appSwift, appKey: "pak_full",
            appID: "1da466cb-e7f4-451c-b71b-aeb1e86c38a4", fingerprint: fp))
        XCTAssertTrue(out.contains("appKey: \"pak_full\""))
        XCTAssertTrue(out.contains("appID: \"1da466cb-e7f4-451c-b71b-aeb1e86c38a4\""))
        XCTAssertTrue(out.contains("fingerprint: \"\(fp)\""))
        XCTAssertTrue(out.contains("Task { await Patch.shared.start() }"))
        // The configure call still precedes the start() task.
        let cfgPos = try XCTUnwrap(out.range(of: "Patch.configure")).lowerBound
        let taskPos = try XCTUnwrap(out.range(of: "Patch.shared.start")).lowerBound
        XCTAssertLessThan(cfgPos, taskPos)
    }

    func testConfigureCallShapes() {
        // Key-only stays a single line; extra args go one-per-line.
        let single = AppEntryInjector.configureCall(
            appKey: "pak_a", appID: nil, fingerprint: nil, indent: "    ")
        XCTAssertEqual(single, "    Patch.configure(.init(appKey: \"pak_a\"))\n")
        let full = AppEntryInjector.configureCall(
            appKey: "pak_a", appID: "id-1", fingerprint: "ff", indent: "    ")
        XCTAssertEqual(full, """
                Patch.configure(.init(
                    appKey: "pak_a",
                    appID: "id-1",
                    fingerprint: "ff"))

            """)
        // Empty strings are treated as absent, not emitted as empty literals.
        let blanks = AppEntryInjector.configureCall(
            appKey: "pak_a", appID: "", fingerprint: "", indent: "")
        XCTAssertFalse(blanks.contains("appID"))
        XCTAssertFalse(blanks.contains("fingerprint"))
    }

    func testFingerprintLiteralScan() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inj-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // No configure call → nil.
        XCTAssertNil(AppEntryInjector.fingerprintLiteral(in: dir))

        let fp = String(repeating: "cd", count: 32)
        let injected = try XCTUnwrap(AppEntryInjector.inject(
            into: Self.appSwift, appKey: "pak_scan", appID: "id-2", fingerprint: fp))
        try injected.write(
            to: dir.appendingPathComponent("DemoApp.swift"), atomically: true, encoding: .utf8)

        let found = try XCTUnwrap(AppEntryInjector.fingerprintLiteral(in: dir))
        XCTAssertEqual(found.value, fp)
        XCTAssertEqual(found.file.lastPathComponent, "DemoApp.swift")
    }

    func testInjectMergesIntoExistingInit() throws {
        let withInit = Self.appSwift.replacingOccurrences(
            of: "var body: some Scene {",
            with: "init() {\n        setup()\n    }\n\n    var body: some Scene {")
        let out = try XCTUnwrap(AppEntryInjector.inject(into: withInit, appKey: "pak_x"),
                                "an existing init must be merged into, not bailed on")
        // The Patch lines land at the TOP of the existing init, before setup().
        let configurePos = try XCTUnwrap(out.range(of: "Patch.configure")).lowerBound
        let setupPos = try XCTUnwrap(out.range(of: "setup()")).lowerBound
        XCTAssertLessThan(configurePos, setupPos)
        // Exactly ONE init — no second one was added.
        XCTAssertEqual(out.components(separatedBy: "init()").count - 1, 1)
        XCTAssertTrue(out.contains("import PatchSDK"))
    }

    func testInjectHandlesExtraProtocolsAndModifiers() throws {
        let fancy = """
        import SwiftUI

        @main
        public struct DemoApp: App, Sendable {
            public var body: some Scene { WindowGroup { Text("hi") } }
        }
        """
        let out = try XCTUnwrap(AppEntryInjector.inject(into: fancy, appKey: "pak_y"))
        XCTAssertTrue(out.contains("Patch.configure"))
    }

    func testInjectIgnoresNonAppMain() {
        let cliMain = """
        @main
        struct Tool {
            static func main() {}
        }
        """
        XCTAssertNil(AppEntryInjector.inject(into: cliMain, appKey: "pak_z"))
    }

    func testNestedInitInsideBodyDoesNotBlockInjection() throws {
        let nested = """
        import SwiftUI

        @main
        struct DemoApp: App {
            var body: some Scene {
                WindowGroup { ContentView(model: Model(init: true)) }
            }
        }

        struct Other {
            init() {}
        }
        """
        // The only `init` tokens are nested/in another type — injection proceeds.
        let out = AppEntryInjector.inject(into: nested, appKey: "pak_n")
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("Patch.configure"))
    }

    func testProposeFindsEntryPointAndProducesDiff() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.appSwift.write(to: dir.appendingPathComponent("DemoApp.swift"),
                                atomically: true, encoding: .utf8)
        try "struct ContentView {}".write(to: dir.appendingPathComponent("ContentView.swift"),
                                          atomically: true, encoding: .utf8)

        guard case .proposed(let injection) = AppEntryInjector.propose(in: dir, appKey: "pak_p") else {
            return XCTFail("expected a proposal")
        }
        XCTAssertEqual(injection.fileURL.lastPathComponent, "DemoApp.swift")
        XCTAssertTrue(injection.diff.contains("+ import PatchSDK"))
        XCTAssertTrue(injection.diff.contains("+     init() {"))
        // Applying the proposal then re-proposing reports already-configured.
        try injection.newContents.write(to: injection.fileURL, atomically: true, encoding: .utf8)
        guard case .alreadyConfigured = AppEntryInjector.propose(in: dir, appKey: "pak_p") else {
            return XCTFail("expected alreadyConfigured after applying")
        }
    }

    func testProposeNotFoundOnUIKitApp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inject-uikit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        import UIKit
        @main
        class AppDelegate: UIResponder, UIApplicationDelegate {}
        """.write(to: dir.appendingPathComponent("AppDelegate.swift"),
                  atomically: true, encoding: .utf8)
        guard case .notFound = AppEntryInjector.propose(in: dir, appKey: "pak_u") else {
            return XCTFail("UIKit AppDelegate apps must fall back to the manual snippet")
        }
    }
}

// MARK: - Bundle-id discovery must not pick a test target's id

extension OnboardingTests {

    /// A pbxproj where the TEST target's build configuration serializes before
    /// the app target's (the real-world shape that surfaced
    /// `com.acme.app.tests` as "the" bundle id). The target-aware lookup must
    /// return the app's id; the ranked heuristic must too (the app id is the
    /// dotted prefix of its companions).
    static let pbxprojTestsFirst: String = {
        var p = OnboardingTests.pbxprojNoPackages
        // Add a tests configuration BEFORE the app's (AA…0B) in the file: give
        // the existing XCBuildConfiguration section a preceding tests entry.
        p = p.replacingOccurrences(
            of: "/* Begin XCBuildConfiguration section */",
            with: """
            /* Begin XCBuildConfiguration section */
            \t\tCC000000000000000000000B /* Release */ = {
            \t\t\tisa = XCBuildConfiguration;
            \t\t\tbuildSettings = {
            \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.demo.tests;
            \t\t\t};
            \t\t\tname = Release;
            \t\t};
            """)
        // And a matching test target + its configuration list.
        p = p.replacingOccurrences(
            of: "/* Begin PBXNativeTarget section */",
            with: """
            /* Begin PBXNativeTarget section */
            \t\tCC0000000000000000000006 /* DemoTests */ = {
            \t\t\tisa = PBXNativeTarget;
            \t\t\tbuildConfigurationList = CC0000000000000000000007 /* Build configuration list for PBXNativeTarget "DemoTests" */;
            \t\t\tbuildPhases = (
            \t\t\t);
            \t\t\tname = DemoTests;
            \t\t\tproductName = DemoTests;
            \t\t\tproductType = "com.apple.product-type.bundle.unit-test";
            \t\t};
            """)
        p = p.replacingOccurrences(
            of: "/* Begin XCConfigurationList section */",
            with: """
            /* Begin XCConfigurationList section */
            \t\tCC0000000000000000000007 /* Build configuration list for PBXNativeTarget "DemoTests" */ = {
            \t\t\tisa = XCConfigurationList;
            \t\t\tbuildConfigurations = (
            \t\t\t\tCC000000000000000000000B /* Release */,
            \t\t\t);
            \t\t\tdefaultConfigurationIsVisible = 0;
            \t\t\tdefaultConfigurationName = Release;
            \t\t};
            """)
        return p
    }()

    func testBundleIDPrefersTheNamedTargetsConfiguration() {
        XCTAssertEqual(
            ProjectDiscovery.bundleID(inPBXProj: Self.pbxprojTestsFirst, forTarget: "Demo"),
            "com.example.demo",
            "the APP target's id must win even when the tests config serializes first")
        XCTAssertEqual(
            ProjectDiscovery.bundleID(inPBXProj: Self.pbxprojTestsFirst, forTarget: "DemoTests"),
            "com.example.demo.tests",
            "asking for the test target explicitly still works")
    }

    func testRankedHeuristicPrefersThePrefixBaseId() {
        // No target name available → the dotted-prefix base must outrank the
        // tests id that appears FIRST in the file.
        XCTAssertEqual(
            ProjectDiscovery.rankedBundleID(inPBXProj: Self.pbxprojTestsFirst),
            "com.example.demo")
    }

    func testRankedHeuristicSkipsNonAppSuffixesWithoutAPrefixBase() {
        let only = """
        PRODUCT_BUNDLE_IDENTIFIER = com.acme.other.uitests;
        PRODUCT_BUNDLE_IDENTIFIER = com.acme.main;
        """
        XCTAssertEqual(ProjectDiscovery.rankedBundleID(inPBXProj: only), "com.acme.main")
    }

    func testEndToEndBundleIdentifierWithTargetName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bid-\(UUID().uuidString)/Demo.xcodeproj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try Self.pbxprojTestsFirst.write(
            to: dir.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ProjectDiscovery.bundleIdentifier(in: dir.deletingLastPathComponent(), target: "Demo"),
            "com.example.demo")
    }
}

// MARK: - Injection into real-world App structs with existing inits

extension OnboardingTests {

    /// The real app shape that surfaced the bug: Firebase + services configured
    /// in an existing init, an @UIApplicationDelegateAdaptor, @State services,
    /// strings/comments containing braces, and sibling types after the struct.
    static let realWorldApp = """
    import SwiftUI
    import SwiftData
    import FirebaseCore
    import SuperwallKit

    @main
    struct SampleFeedApp: App {
        @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

        @State private var auth: AuthService

        let modelContainer: ModelContainer

        init() {
            // Firebase must be configured *before* any service touches its SDK.
            if FirebaseSetup.isBundledPlistValid() {
                FirebaseApp.configure()
            }

            _auth = State(wrappedValue: AuthService())

            do {
                modelContainer = try ModelContainer(
                    for: LocalUserProfile.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: false)
                )
            } catch {
                fatalError("Failed to initialize ModelContainer: \\(error)")
            }
        }

        var body: some Scene {
            WindowGroup {
                ContentView()
                    .environment(auth)
                    .task {
                        await auth.refresh()
                    }
            }
        }
    }

    enum FirebaseSetup {
        static func isBundledPlistValid() -> Bool {
            return true
        }
    }

    final class AppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication,
            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            return true
        }
    }
    """

    func testInjectMergesIntoRealWorldFirebaseApp() throws {
        let out = try XCTUnwrap(
            AppEntryInjector.inject(into: Self.realWorldApp, appKey: "pak_real"),
            "the mainstream Firebase-style App struct must be injectable")
        // Lands at the very top of the existing init — before the Firebase
        // comment/configure — and only once.
        let configurePos = try XCTUnwrap(out.range(of: "Patch.configure")).lowerBound
        let firebasePos = try XCTUnwrap(out.range(of: "// Firebase must be configured")).lowerBound
        XCTAssertLessThan(configurePos, firebasePos)
        XCTAssertEqual(out.components(separatedBy: "Patch.configure").count - 1, 1)
        // Import goes after the LAST import (SuperwallKit).
        let importPos = try XCTUnwrap(out.range(of: "import PatchSDK")).lowerBound
        let superwallPos = try XCTUnwrap(out.range(of: "import SuperwallKit")).lowerBound
        XCTAssertLessThan(superwallPos, importPos)
        // The AppDelegate's methods are untouched (no stray init injection).
        XCTAssertFalse(out.components(separatedBy: "class AppDelegate").last!.contains("Patch.configure"))
    }

    func testTopLevelInitScannerIgnoresStringsCommentsAndNesting() {
        // "init" in a comment, a string, and a nested type — none count; the
        // struct genuinely has no top-level init.
        let tricky = """
            // about init: do not call init here
            let label = "init { fake }"
            var body: some Scene {
                WindowGroup { Text(label) }
            }
            struct Nested {
                init() {}
            }
        }
        """
        XCTAssertNil(AppEntryInjector.topLevelInitBodyStart(inStructBody: tricky))
        // …and a real one IS found despite a closure-typed property before it.
        let real = """
            let onDone: (Int) -> Void = { _ in }
            init() {
                setup()
            }
        }
        """
        XCTAssertNotNil(AppEntryInjector.topLevelInitBodyStart(inStructBody: real))
    }

    /// End-to-end: propose → apply → re-propose reports already-configured,
    /// for the existing-init shape (the full idempotency loop).
    func testProposeMergeIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inject-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.realWorldApp.write(to: dir.appendingPathComponent("SampleFeedApp.swift"),
                                    atomically: true, encoding: .utf8)
        guard case .proposed(let injection) = AppEntryInjector.propose(in: dir, appKey: "pak_m") else {
            return XCTFail("expected a merge proposal")
        }
        XCTAssertTrue(injection.diff.contains("+         Patch.configure"))
        try injection.newContents.write(to: injection.fileURL, atomically: true, encoding: .utf8)
        guard case .alreadyConfigured = AppEntryInjector.propose(in: dir, appKey: "pak_m") else {
            return XCTFail("expected alreadyConfigured after applying the merge")
        }
    }
}
