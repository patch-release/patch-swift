// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler
@testable import PartitioningEngine
@testable import PatchCLI

/// Regression tests for a bug-hunt pass over the WASM ship pipeline + CLI:
/// project surgery (pbxproj / Package.swift), the PMOD container, the resumable
/// upload protocol, the `.Patch.yml` writer, and the release report.
///
/// Each test names the developer-visible failure it pins.
final class BugHuntPipelineTests: XCTestCase {

    // MARK: - Project surgery: "already present" must mean "wired into THIS target"

    /// BUG: a manifest that already declared patch-swift (a second target wired
    /// earlier, or `prepare` having added PatchSwiftUI) made `addPackage` report
    /// `.alreadyPresent` — so the target never got `.product(name: "PatchSDK", …)`
    /// and the app failed to build with `no such module 'PatchSDK'` right after
    /// `patchcli init` said it was done.
    func testPackageWiresTargetWhenThePackageIsAlreadyDeclared() throws {
        let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Demo",
            dependencies: [
                .package(url: "https://github.com/patch-release/patch-swift", from: "\(XcodeProjectEditor.minimumVersion)"),
            ],
            targets: [
                .target(name: "Demo"),
            ]
        )
        """
        let (result, text) = try PackageManifestEditor.addPackage(to: manifest, targetName: "Demo")
        XCTAssertEqual(result, .added)
        XCTAssertTrue(text.contains(PackageManifestEditor.productDependencyLine),
                      "the target must gain the PatchSDK product:\n\(text)")
        // …and the package is NOT declared a second time.
        XCTAssertEqual(text.components(separatedBy: "patch-release/patch-swift").count - 1, 1,
                       "the package must be declared exactly once:\n\(text)")
    }

    /// The same read for a MULTI-target package: target B is not wired just
    /// because target A is.
    func testPackageWiresSecondTargetOfTheSamePackage() throws {
        let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Demo",
            dependencies: [
                .package(url: "https://github.com/patch-release/patch-swift", from: "\(XcodeProjectEditor.minimumVersion)"),
            ],
            targets: [
                .target(name: "AppCore", dependencies: [
                    .product(name: "PatchSDK", package: "patch-swift"),
                ]),
                .target(name: "AppUI"),
            ]
        )
        """
        let (result, text) = try PackageManifestEditor.addPackage(to: manifest, targetName: "AppUI")
        XCTAssertEqual(result, .added)
        XCTAssertEqual(text.components(separatedBy: PackageManifestEditor.productDependencyLine).count - 1, 2,
                       "both targets must now link PatchSDK:\n\(text)")
        // Wiring an ALREADY-wired target stays a no-op.
        XCTAssertEqual(try PackageManifestEditor.addPackage(to: text, targetName: "AppCore").result,
                       .alreadyPresent)
    }

    /// BUG: a LOCAL patch-swift dependency (`.package(path: "../patch-swift")`) was
    /// invisible to the "is it declared?" check, so a remote `.package(url:)` for the
    /// same package name was added alongside it — SwiftPM then refuses the manifest.
    func testLocalPatchSwiftPackageIsNotDuplicated() throws {
        let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Demo",
            dependencies: [
                .package(path: "../patch-swift"),
            ],
            targets: [
                .target(name: "Demo"),
            ]
        )
        """
        let (result, text) = try PackageManifestEditor.addPackage(to: manifest, targetName: "Demo")
        XCTAssertEqual(result, .added)
        XCTAssertTrue(text.contains(PackageManifestEditor.productDependencyLine))
        XCTAssertFalse(text.contains(".package(url: \"\(XcodeProjectEditor.packageURL)\""),
                       "must not declare patch-swift twice:\n\(text)")
        XCTAssertEqual(text.components(separatedBy: ".package(path: \"../patch-swift\")").count - 1, 1)
    }

    /// A target's own `path:` argument is not a package path — it must never be
    /// mistaken for a local patch-swift dependency.
    func testTargetPathArgumentIsNotAPackagePath() {
        let manifest = """
        let package = Package(
            name: "Tool",
            targets: [ .target(name: "Tool", path: "Sources/patch-swift") ]
        )
        """
        XCTAssertFalse(PackageManifestEditor.declaresPatchSwiftPackage(manifest))
    }

    /// BUG (pbxproj half): `patchcli prepare` adds the patch-swift package
    /// reference to link PatchSwiftUI. A later `init` then saw "patch-swift is in
    /// the file" and reported `.alreadyPresent`, so PatchSDK was never linked and
    /// the `import PatchSDK` init had just injected did not compile.
    func testPbxprojLinksPatchSDKWhenPrepareAlreadyAddedTheReference() throws {
        let afterPrepare = try PBXThunkIntegration.addProductLink(
            to: OnboardingTests.pbxprojNoPackages, target: "Demo", product: "PatchSwiftUI")
        let (result, text) = try XcodeProjectEditor.addPackage(to: afterPrepare, targetName: "Demo")
        XCTAssertEqual(result, .added)
        XCTAssertTrue(text.contains("productName = PatchSDK"), "PatchSDK product missing:\n\(text)")
        XCTAssertTrue(text.contains("productName = PatchSwiftUI"), "PatchSwiftUI link must survive")
        // ONE package reference, shared by both products.
        XCTAssertEqual(text.components(separatedBy: "isa = XCRemoteSwiftPackageReference;").count - 1, 1,
                       "the patch-swift reference must not be duplicated")
        // And it is genuinely in the target + frameworks phase.
        XCTAssertTrue(PBXThunkIntegration.productAlreadyLinked(text, targetName: "Demo", product: "PatchSDK"))
        // Re-running is a no-op.
        XCTAssertEqual(try XcodeProjectEditor.addPackage(to: text, targetName: "Demo").result, .alreadyPresent)
    }

    /// A LOCAL Xcode package reference (Xcode 15 `XCLocalSwiftPackageReference`) is
    /// reused rather than shadowed by a new remote reference.
    func testPbxprojReusesALocalPatchSwiftReference() throws {
        let withLocal = OnboardingTests.pbxprojNoPackages.replacingOccurrences(
            of: "/* End XCConfigurationList section */",
            with: """
            /* End XCConfigurationList section */

            /* Begin XCLocalSwiftPackageReference section */
            \t\tCC0000000000000000000001 /* XCLocalSwiftPackageReference "../patch-swift" */ = {
            \t\t\tisa = XCLocalSwiftPackageReference;
            \t\t\trelativePath = ../patch-swift;
            \t\t};
            /* End XCLocalSwiftPackageReference section */
            """)
        let (result, text) = try XcodeProjectEditor.addPackage(to: withLocal, targetName: "Demo")
        XCTAssertEqual(result, .added)
        XCTAssertTrue(text.contains("productName = PatchSDK"))
        XCTAssertFalse(text.contains("isa = XCRemoteSwiftPackageReference;"),
                       "must reuse the local reference, not add a remote duplicate:\n\(text)")
        XCTAssertTrue(text.contains("package = CC0000000000000000000001 /* XCLocalSwiftPackageReference \"patch-swift\" */;"),
                      "the product must point at the local reference:\n\(text)")
    }

    // MARK: - Default module version must not depend on the developer's locale

    /// BUG: `defaultVersion()` used a `DateFormatter` with no locale, so it
    /// inherited the PROCESS locale's calendar and digits. On a th_TH machine the
    /// version was the Buddhist year (`2568.…` — accepted by the backend and wrong
    /// forever); on ar_SA/fa_IR it was Arabic-Indic digits, which the backend's
    /// `^[A-Za-z0-9._-]+$` rejects with a 422 AFTER the full build (and
    /// `validate(version:)` never sees it — that only checks an explicit --version).
    func testDefaultVersionIsGregorianASCIIRegardlessOfLocale() throws {
        let fixed = Date(timeIntervalSince1970: 1_750_000_000)  // 2025-06-15 15:06:40Z
        XCTAssertEqual(PushFlow.defaultVersion(now: fixed), "2025.06.15.150640")
        // It also passes the same validation an explicit --version must pass.
        XCTAssertNoThrow(try PushFlow.validate(version: PushFlow.defaultVersion(now: fixed)))
        XCTAssertNoThrow(try PushFlow.validate(version: PushFlow.defaultVersion()))

        // The hazard this pins: a locale-inheriting formatter (the old code) produces
        // a version the backend REJECTS, or a silently wrong year.
        for id in ["ar_SA", "fa_IR"] {
            let f = DateFormatter()
            f.dateFormat = "yyyy.MM.dd.HHmmss"
            f.timeZone = TimeZone(identifier: "UTC")
            f.locale = Locale(identifier: id)
            XCTAssertThrowsError(try PushFlow.validate(version: f.string(from: fixed)),
                                 "\(id) digits must be the rejected shape the fix avoids")
        }
        let thai = DateFormatter()
        thai.dateFormat = "yyyy.MM.dd.HHmmss"
        thai.timeZone = TimeZone(identifier: "UTC")
        thai.locale = Locale(identifier: "th_TH")
        XCTAssertNotEqual(thai.string(from: fixed), PushFlow.defaultVersion(now: fixed),
                          "a Buddhist-calendar machine must not decide the module version")
    }

    // MARK: - PMOD container: a malformed container must be DETECTED

    /// A container whose payload carries bytes beyond the last declared module is
    /// corrupt. Decoding it as "everything before the tail" silently loses a whole
    /// sub-module, and the optimizer/merger would then REWRITE the file from that
    /// truncated view — shipping an artifact missing a module.
    func testContainerRejectsTrailingBytes() {
        let wasm: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
        var blob = PatchModuleContainer.encode([wasm])
        XCTAssertNotNil(PatchModuleContainer.decode(blob))
        blob.append(contentsOf: [0xDE, 0xAD])
        XCTAssertNil(PatchModuleContainer.decode(blob), "trailing bytes = corrupt container")
    }

    /// A sub-module that is empty, or not a wasm binary at all, is not something the
    /// device can instantiate — reject it here rather than ship it.
    func testContainerRejectsNonWasmSubModule() {
        let wasm: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
        // Hand-frame a container with one wasm module and one junk module.
        var blob = PatchModuleContainer.magic + [PatchModuleContainer.version, 2, 0, 0]
        func frame(_ m: [UInt8]) -> [UInt8] {
            let n = UInt32(m.count)
            return [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)] + m
        }
        blob += frame(wasm) + frame([0x01, 0x02, 0x03, 0x04])
        XCTAssertNil(PatchModuleContainer.decode(blob), "a non-wasm sub-module is corrupt")

        // A zero-length sub-module too.
        var empty = PatchModuleContainer.magic + [PatchModuleContainer.version, 2, 0, 0]
        empty += frame(wasm) + frame([])
        XCTAssertNil(PatchModuleContainer.decode(empty))
    }

    /// The reserved u16 must be zero — a non-zero value means a writer we don't
    /// understand framed this blob.
    func testContainerRejectsNonZeroReservedField() {
        let wasm: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
        var blob = PatchModuleContainer.encode([wasm])
        blob[6] = 1
        XCTAssertNil(PatchModuleContainer.decode(blob))
    }

    /// The strictness must not change what a GOOD container round-trips to (the
    /// merger/optimizer depend on byte-exact sub-modules).
    func testWellFormedContainerStillRoundTrips() throws {
        let a: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 1, 2, 3]
        let b: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 9, 9]
        let parts = try XCTUnwrap(PatchModuleContainer.decode(PatchModuleContainer.encode([a, b])))
        XCTAssertEqual(parts, [a, b])
    }

    // MARK: - `.Patch.yml` writes must not destroy what the developer wrote

    /// BUG: every incremental write (caching `app_id` on the first push, `login`
    /// storing the publish token, `prepare` recording `native_views:`) rewrote the
    /// whole file from `yamlString()`, deleting the developer's comments and any key
    /// this schema doesn't know. A `patchcli release` wiped their config's notes.
    func testConfigWritePreservesCommentsAndUnknownKeys() throws {
        let existing = """
        # Patch config for Acme — CI sets PATCH_API_KEY instead of publish_token.
        version: 1
        app_key: pak_abc
        project: Acme.xcodeproj
        target: Acme

        # our own tooling reads this
        acme_release_train: canary
        exclude:
          - Sources/Legacy
        bridges:
          networking: true
        build:
          optimization: size
        """
        var cfg = try PatchConfig.parse(existing)
        cfg.appId = "app-123"
        cfg.workspaceId = "ws-9"
        let merged = cfg.yamlString(mergedInto: existing)

        XCTAssertTrue(merged.contains("# Patch config for Acme"), "comment lost:\n\(merged)")
        XCTAssertTrue(merged.contains("# our own tooling reads this"))
        XCTAssertTrue(merged.contains("acme_release_train: canary"), "unknown key lost:\n\(merged)")
        XCTAssertTrue(merged.contains("app_id: app-123"))
        XCTAssertTrue(merged.contains("workspace_id: ws-9"))
        // Everything still parses back to the same values.
        let reparsed = try PatchConfig.parse(merged)
        XCTAssertEqual(reparsed.appId, "app-123")
        XCTAssertEqual(reparsed.workspaceId, "ws-9")
        XCTAssertEqual(reparsed.appKey, "pak_abc")
        XCTAssertEqual(reparsed.exclude, ["Sources/Legacy"])
        XCTAssertEqual(reparsed.bridges["networking"], true)
    }

    /// An unchanged config writes back BYTE-IDENTICALLY (so a no-op push leaves no
    /// diff in the developer's repo).
    func testConfigWriteIsByteIdenticalWhenNothingChanged() throws {
        let existing = """
        # keep me
        version: 1
        app_key: pak_abc
        project: Acme.xcodeproj
        target: Acme
        app_id: app-1
        exclude:
          - A.swift
        bridges:
          networking: true
        build:
          swiftui: false

        """
        let cfg = try PatchConfig.parse(existing)
        XCTAssertEqual(cfg.yamlString(mergedInto: existing), existing)
    }

    /// `prepare` recording `native_views:` updates (and later clears) just that
    /// block, leaving the rest of the file alone.
    func testConfigWriteMaintainsNativeViewsBlockInPlace() throws {
        let existing = """
        # head
        version: 1
        app_key: pak_abc
        project: A.xcodeproj
        target: A
        exclude:
          []
        bridges:
          networking: true
        """
        var cfg = try PatchConfig.parse(existing)
        cfg.nativeViews = ["BrokenView", "OtherView"]
        let withViews = cfg.yamlString(mergedInto: existing)
        XCTAssertTrue(withViews.contains("native_views:\n  - BrokenView\n  - OtherView"), withViews)
        XCTAssertTrue(withViews.contains("# head"))
        XCTAssertEqual(try PatchConfig.parse(withViews).nativeViews, ["BrokenView", "OtherView"])

        // A second prepare adds one more — the block is replaced, not appended twice.
        var cfg2 = try PatchConfig.parse(withViews)
        cfg2.nativeViews.append("ThirdView")
        let updated = cfg2.yamlString(mergedInto: withViews)
        XCTAssertEqual(updated.components(separatedBy: "native_views:").count - 1, 1, updated)
        XCTAssertEqual(try PatchConfig.parse(updated).nativeViews,
                       ["BrokenView", "OtherView", "ThirdView"])

        // Clearing the list removes the block entirely, keeping the rest.
        var cfg3 = try PatchConfig.parse(updated)
        cfg3.nativeViews = []
        let cleared = cfg3.yamlString(mergedInto: updated)
        XCTAssertFalse(cleared.contains("native_views:"), cleared)
        XCTAssertTrue(cleared.contains("bridges:"))
        XCTAssertTrue(cleared.contains("# head"))
    }

    /// A brand-new (absent/empty) config still gets the canonical full rendering.
    func testConfigWriteFallsBackToFullRenderForANewFile() throws {
        var cfg = PatchConfig()
        cfg.appKey = "pak_x"
        XCTAssertEqual(cfg.yamlString(mergedInto: ""), cfg.yamlString())
        XCTAssertEqual(cfg.yamlString(mergedInto: "   \n\n"), cfg.yamlString())
    }

    func testConfigWriteToDiskPreservesComments() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".Patch.yml")
        let original = """
        # mine
        version: 1
        app_key: pak_abc
        project: A.xcodeproj
        target: A
        """
        try original.write(to: url, atomically: true, encoding: .utf8)
        var cfg = try PatchConfig.load(from: url)
        cfg.publishToken = "ppt_secret"
        try cfg.write(to: url)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("# mine"))
        XCTAssertTrue(onDisk.contains("publish_token: ppt_secret"))
        XCTAssertEqual(try PatchConfig.load(from: url).publishToken, "ppt_secret")
    }

    // MARK: - release must not report success for gains that never shipped

    /// BUG: when a lowering compiled but the combine into `module.wasm` failed,
    /// `build` said so and `release` said NOTHING — it uploaded a module with none
    /// of the view patches in it and printed a clean success. (The degenerate-
    /// coverage gate doesn't catch it: it only fires when nothing at all shipped.)
    func testUnshippedGainWarningsNameEachDroppedLowering() {
        var result = Self.emptyResult()
        result.loweredViewBodies = 12
        result.swiftUIMergedIntoDefault = false
        result.loweredCells = 2
        result.uikitMergedIntoDefault = false
        result.realSourceCompiledUnits = 3
        result.realSourceMergedIntoDefault = false
        let warnings = result.unshippedGainWarnings
        XCTAssertEqual(warnings.count, 3, "\(warnings)")
        XCTAssertTrue(warnings[0].contains("12 lowered SwiftUI view"))
        XCTAssertTrue(warnings[1].contains("2 lowered UIKit cell"))
        XCTAssertTrue(warnings[2].contains("3 real-source unit"))
    }

    func testNoWarningsWhenEverythingShipped() {
        var result = Self.emptyResult()
        result.loweredViewBodies = 12
        result.swiftUIMergedIntoDefault = true
        XCTAssertTrue(result.unshippedGainWarnings.isEmpty)
        // Nothing lowered at all → nothing to warn about.
        XCTAssertTrue(Self.emptyResult().unshippedGainWarnings.isEmpty)
    }

    /// BUG: Swift treats "\r\n" as ONE grapheme cluster, so the parser's
    /// `split(separator: "\n")` found NO line breaks in a CRLF `.Patch.yml` — the
    /// whole file parsed as a single `version:` line and every other key was
    /// silently dropped. The developer saw "No publish token found" / "No app_id in
    /// .Patch.yml" (and a silently different `swiftui:` setting) on a config that
    /// looks perfectly correct. CRLF comes from a Windows editor or
    /// `core.autocrlf=true`.
    func testConfigParsesCRLFLineEndings() throws {
        let crlf = "version: 1\r\napp_key: pak_abc\r\npublish_token: ppt_x\r\napp_id: app-1\r\n"
            + "exclude:\r\n  - A.swift\r\nbuild:\r\n  swiftui: false\r\n"
        let cfg = try PatchConfig.parse(crlf)
        XCTAssertEqual(cfg.appId, "app-1")
        XCTAssertEqual(cfg.appKey, "pak_abc")
        XCTAssertEqual(cfg.publishToken, "ppt_x")
        XCTAssertEqual(cfg.exclude, ["A.swift"])
        XCTAssertEqual(cfg.buildSwiftUI, false)
        // No stray carriage returns leak into a value (they'd be sent to the backend).
        XCTAssertFalse(cfg.yamlString().contains("\r"))
        // Old-Mac lone-CR files parse too.
        let cr = crlf.replacingOccurrences(of: "\r\n", with: "\r")
        XCTAssertEqual(try PatchConfig.parse(cr).appId, "app-1")
    }

    /// The merging writer must survive a CRLF file too — treating it as one line
    /// would overwrite the whole config with a single key.
    func testConfigMergeHandlesCRLFWithoutDestroyingTheFile() throws {
        let crlf = "# keep\r\nversion: 1\r\napp_key: pak_abc\r\nbundle_id: com.acme.app\r\n"
        var cfg = try PatchConfig.parse(crlf)
        cfg.appId = "app-1"
        let merged = cfg.yamlString(mergedInto: crlf)
        XCTAssertTrue(merged.contains("# keep"), merged)
        XCTAssertTrue(merged.contains("app_key: pak_abc"), merged)
        XCTAssertTrue(merged.contains("bundle_id: com.acme.app"), merged)
        XCTAssertTrue(merged.contains("app_id: app-1"), merged)
        XCTAssertFalse(merged.contains("\r"))
        let reparsed = try PatchConfig.parse(merged)
        XCTAssertEqual(reparsed.appKey, "pak_abc")
        XCTAssertEqual(reparsed.bundleId, "com.acme.app")
        XCTAssertEqual(reparsed.appId, "app-1")
    }

    // MARK: - `build` must not exit 0 when it produced nothing

    /// BUG: `patchcli build` printed "No module emitted." and exited 0 when the
    /// compile ran and emitted NOTHING — so a CI step running `patchcli build` went
    /// green on a build with no artifact (the failure only surfaced later at `push`:
    /// "No .wasm at …"). This pins the predicate the non-zero exit is gated on.
    func testEmittedModuleIsFalseWithoutAFileOnDisk() throws {
        var result = Self.emptyResult()
        XCTAssertFalse(Build.emittedModule(result), "no moduleURL at all = nothing emitted")

        result.moduleURL = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/module.wasm")
        XCTAssertFalse(Build.emittedModule(result), "a path with no file = nothing emitted")

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("emit-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let module = dir.appendingPathComponent("module.wasm")
        try Data([0x00, 0x61, 0x73, 0x6d]).write(to: module)
        result.moduleURL = module
        XCTAssertTrue(Build.emittedModule(result))
    }

    private static func emptyResult() -> BuildPipeline.Result {
        BuildPipeline.Result(
            report: PartitioningEngine().analyze(records: [], fileCount: 0),
            splitFunctions: [], generatedWasmSources: [], generatedBridgeSources: [],
            exportSymbols: [], compileOutcome: nil, moduleURL: nil,
            selectedTier: .t0Embedded, tierRationale: "test", rejectedExports: [])
    }
}
