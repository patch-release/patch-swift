// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator
@testable import Compiler
@testable import PatchCLI

/// Tests for `patchcli doctor` — the read-only setup/health preflight. Each test
/// builds a synthetic project directory with / without a given piece and asserts
/// the matching check reports the right ✓ / ⚠ / ✗.
final class DoctorTests: XCTestCase {

    // MARK: - Temp project scaffolding

    /// Make a temp dir; register teardown. Returns the dir URL.
    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A doctor instance with default flag values (offline so no check touches the network).
    private func doctor(offline: Bool = true) -> Doctor {
        var d = Doctor()
        d.offline = offline
        return d
    }

    // MARK: - Check 1: .Patch.yml

    func testConfigMissingIsFail() throws {
        let d = doctor()
        let (check, config) = d.checkConfig(configURL: nil)
        XCTAssertEqual(check.status, .fail)
        XCTAssertNil(config)
        XCTAssertNotNil(check.fix)
        XCTAssertTrue(check.fix!.contains("patchcli init"))
    }

    func testConfigWithKeyAndAppIdIsPass() throws {
        let dir = try makeTempDir("cfg-ok")
        let configURL = dir.appendingPathComponent(".Patch.yml")
        try write("""
        version: 1
        app_key: pak_abc123
        publish_token: ppt_abc123
        project: App.xcodeproj
        target: App
        app_id: 11111111-2222-3333-4444-555555555555
        """, to: configURL)
        let d = doctor()
        let (check, config) = d.checkConfig(configURL: configURL)
        XCTAssertEqual(check.status, .pass)
        XCTAssertEqual(config?.appId, "11111111-2222-3333-4444-555555555555")
    }

    func testConfigPlaceholderKeyIsFail() throws {
        let dir = try makeTempDir("cfg-placeholder")
        let configURL = dir.appendingPathComponent(".Patch.yml")
        try write("""
        version: 1
        app_key: pak_REPLACE_ME
        project: App.xcodeproj
        target: App
        """, to: configURL)
        let d = doctor()
        let (check, _) = d.checkConfig(configURL: configURL)
        XCTAssertEqual(check.status, .fail)
        XCTAssertTrue(check.fix!.contains("patchcli login"),
                      "must point at the command that supplies a publish token")
    }

    func testConfigKeySetButNoAppIdIsWarn() throws {
        let dir = try makeTempDir("cfg-noappid")
        let configURL = dir.appendingPathComponent(".Patch.yml")
        try write("""
        version: 1
        app_key: pak_abc123
        publish_token: ppt_abc123
        project: App.xcodeproj
        target: App
        """, to: configURL)
        let d = doctor()
        let (check, _) = d.checkConfig(configURL: configURL)
        XCTAssertEqual(check.status, .warn)
    }

    func testConfigKeyNoAppIdButBundleIdIsWarnWithResolveHint() throws {
        let dir = try makeTempDir("cfg-bundle")
        let configURL = dir.appendingPathComponent(".Patch.yml")
        try write("""
        version: 1
        app_key: pak_abc123
        publish_token: ppt_abc123
        project: App.xcodeproj
        target: App
        bundle_id: com.acme.app
        """, to: configURL)
        let d = doctor()
        let (check, _) = d.checkConfig(configURL: configURL)
        XCTAssertEqual(check.status, .warn)
        XCTAssertTrue(check.fix!.contains("bundle_id") || check.fix!.contains("resolve"))
    }

    /// An `app_key` alone is NOT a usable credential: it ships inside the app
    /// binary (recoverable with `strings`) and the backend rejects it for
    /// pushes. Doctor must fail, and must name `patchcli login` as the fix.
    func testConfigWithOnlyAnAppKeyIsFail() throws {
        let dir = try makeTempDir("cfg-appkey-only")
        let configURL = dir.appendingPathComponent(".Patch.yml")
        try write("""
        version: 1
        app_key: pak_abc123
        project: App.xcodeproj
        target: App
        app_id: 11111111-2222-3333-4444-555555555555
        """, to: configURL)
        let d = doctor()
        let (check, _) = d.checkConfig(configURL: configURL)
        XCTAssertEqual(check.status, .fail,
                       "an app_key is a public device identifier, not a publish credential")
        XCTAssertTrue(check.fix!.contains("patchcli login"))
    }

    // MARK: - Check 2: PatchSDK package

    func testPackageXcodeprojWithSDKLinkedIsPass() throws {
        let dir = try makeTempDir("pkg-xcode-ok")
        let pbx = dir.appendingPathComponent("App.xcodeproj/project.pbxproj")
        try write("""
        // !$*UTF8*$!
        { /* references */
          url = "https://github.com/patch-release/patch-swift";
          productRef = X /* PatchSDK */;
        }
        """, to: pbx)
        let check = doctor().checkPackage(root: dir, target: "App")
        XCTAssertEqual(check.status, .pass)
    }

    func testPackageXcodeprojWithoutSDKIsFail() throws {
        let dir = try makeTempDir("pkg-xcode-missing")
        let pbx = dir.appendingPathComponent("App.xcodeproj/project.pbxproj")
        try write("// !$*UTF8*$!\n{ /* empty project */ }\n", to: pbx)
        let check = doctor().checkPackage(root: dir, target: "App")
        XCTAssertEqual(check.status, .fail)
        XCTAssertTrue(check.fix!.contains("init") || check.fix!.contains("PatchSDK"))
    }

    func testPackageXcodeprojRefButNoProductLinkIsWarn() throws {
        let dir = try makeTempDir("pkg-xcode-noproduct")
        let pbx = dir.appendingPathComponent("App.xcodeproj/project.pbxproj")
        // References the package but never links the PatchSDK product.
        try write("""
        // !$*UTF8*$!
        { repositoryURL = "https://github.com/patch-release/patch-swift"; }
        """, to: pbx)
        let check = doctor().checkPackage(root: dir, target: "App")
        XCTAssertEqual(check.status, .warn)
    }

    func testPackageSPMWithSDKProductIsPass() throws {
        let dir = try makeTempDir("pkg-spm-ok")
        try write("""
        // swift-tools-version:6.0
        import PackageDescription
        let package = Package(name: "App", dependencies: [
            .package(url: "https://github.com/patch-release/patch-swift", from: "1.0.0"),
        ], targets: [
            .target(name: "App", dependencies: [
                .product(name: "PatchSDK", package: "patch-swift"),
            ]),
        ])
        """, to: dir.appendingPathComponent("Package.swift"))
        let check = doctor().checkPackage(root: dir, target: "App")
        XCTAssertEqual(check.status, .pass)
    }

    func testPackageSPMWithoutDepIsFail() throws {
        let dir = try makeTempDir("pkg-spm-missing")
        try write("""
        // swift-tools-version:6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.target(name: "App")])
        """, to: dir.appendingPathComponent("Package.swift"))
        let check = doctor().checkPackage(root: dir, target: "App")
        XCTAssertEqual(check.status, .fail)
    }

    func testPackageNoProjectFileIsFail() throws {
        let dir = try makeTempDir("pkg-noproject")
        let check = doctor().checkPackage(root: dir, target: nil)
        XCTAssertEqual(check.status, .fail)
    }

    // MARK: - Check 3: Patch.configure + start()

    func testConfigureFullyWiredIsPass() throws {
        let dir = try makeTempDir("cfg-wired")
        try write("""
        import SwiftUI
        import PatchSDK

        @main
        struct MyApp: App {
            init() {
                Patch.configure(.init(appKey: "pak_x"))
                Task { await Patch.shared.start() }
            }
            var body: some Scene { WindowGroup { Text("hi") } }
        }
        """, to: dir.appendingPathComponent("MyApp.swift"))
        let check = doctor().checkConfigureCall(root: dir)
        XCTAssertEqual(check.status, .pass)
    }

    func testConfigureMissingEntirelyIsFail() throws {
        let dir = try makeTempDir("cfg-noconfigure")
        try write("""
        import SwiftUI

        @main
        struct MyApp: App {
            var body: some Scene { WindowGroup { Text("hi") } }
        }
        """, to: dir.appendingPathComponent("MyApp.swift"))
        let check = doctor().checkConfigureCall(root: dir)
        XCTAssertEqual(check.status, .fail)
        XCTAssertTrue(check.fix!.contains("init"))
    }

    func testConfigurePresentButNoStartIsWarn() throws {
        let dir = try makeTempDir("cfg-nostart")
        try write("""
        import SwiftUI
        import PatchSDK

        @main
        struct MyApp: App {
            init() {
                Patch.configure(.init(appKey: "pak_x"))
            }
            var body: some Scene { WindowGroup { Text("hi") } }
        }
        """, to: dir.appendingPathComponent("MyApp.swift"))
        let check = doctor().checkConfigureCall(root: dir)
        XCTAssertEqual(check.status, .warn)
        XCTAssertTrue(check.detail!.contains("start"))
    }

    // MARK: - Check 4: prepare run

    func testPrepareNotRunIsWarnNotFail() throws {
        // Auto-prepare runs on every build/push/release, so an un-prepared view is a
        // ⚠ (info: self-heals on next release), NOT a blocking ✗.
        let dir = try makeTempDir("prep-notrun")
        try write("""
        import SwiftUI
        struct MyView: View {
            var body: some View { Text("hi") }
        }
        """, to: dir.appendingPathComponent("MyView.swift"))
        let check = doctor().checkPrepared(root: dir, config: nil)
        XCTAssertEqual(check.status, .warn)
        // The detail/fix must reflect the auto-prepare reality (not "run prepare or else").
        XCTAssertTrue(check.detail!.contains("automatically") || check.fix!.contains("auto-prepare"),
                      "doctor must tell the dev prepare runs automatically on release")
    }

    func testPrepareDoneIsPass() throws {
        // A view whose body is `dynamic` AND a same-file thunk block marker present.
        let dir = try makeTempDir("prep-done")
        try write("""
        import SwiftUI
        struct MyView: View {
            dynamic var body: some View { Text("hi") }
        }

        \(ThunkGenerator.sameFileBeginMarker)
        extension MyView {}
        \(ThunkGenerator.sameFileEndMarker)
        """, to: dir.appendingPathComponent("MyView.swift"))
        let check = doctor().checkPrepared(root: dir, config: nil)
        XCTAssertEqual(check.status, .pass)
    }

    func testPrepareNoViewsIsWarn() throws {
        let dir = try makeTempDir("prep-noviews")
        try write("""
        import Foundation
        struct Helper { func go() {} }
        """, to: dir.appendingPathComponent("Helper.swift"))
        let check = doctor().checkPrepared(root: dir, config: nil)
        XCTAssertEqual(check.status, .warn)
    }

    // MARK: - Check 5: fingerprint (offline / local-only paths)

    func testFingerprintOfflineIsWarn() throws {
        let dir = try makeTempDir("fp-offline")
        try write("""
        import SwiftUI
        struct V: View { var body: some View { Text("x") } }
        """, to: dir.appendingPathComponent("V.swift"))
        var config = PatchConfig()
        config.appKey = "pak_x"
        config.appId = "11111111-2222-3333-4444-555555555555"
        let check = doctor(offline: true).checkFingerprint(root: dir, config: config)
        // Offline → can't confirm the registration, so a warn (computed-but-unverified).
        XCTAssertEqual(check.status, .warn)
        XCTAssertTrue(check.fix!.contains("register"))
    }

    func testFingerprintNoConfigIsWarn() throws {
        let dir = try makeTempDir("fp-noconfig")
        let check = doctor(offline: true).checkFingerprint(root: dir, config: nil)
        XCTAssertEqual(check.status, .warn)
    }
}
