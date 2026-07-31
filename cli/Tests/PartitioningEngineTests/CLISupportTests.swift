// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler
@testable import PartitioningEngine

// MARK: - .Patch.yml config parsing

final class PatchConfigTests: XCTestCase {
    func testParsesPlanSchema() throws {
        let yaml = """
        version: 1
        app_key: pak_abc123def456
        project: MyApp.xcodeproj
        target: MyApp
        exclude:
          - Sources/App/AppDelegate.swift
          - Sources/Generated/
        bridges:
          networking: true
          userDefaults: true
          notifications: false
          navigation: true
          keychain: true
          dateLocale: true
          logging: true
        build:
          optimization: size
          stripDebugInfo: true
        """
        let cfg = try PatchConfig.parse(yaml)
        XCTAssertEqual(cfg.version, 1)
        XCTAssertEqual(cfg.appKey, "pak_abc123def456")
        XCTAssertEqual(cfg.project, "MyApp.xcodeproj")
        XCTAssertEqual(cfg.target, "MyApp")
        XCTAssertEqual(cfg.exclude, ["Sources/App/AppDelegate.swift", "Sources/Generated/"])
        XCTAssertEqual(cfg.bridges["networking"], true)
        XCTAssertEqual(cfg.bridges["notifications"], false)
        XCTAssertEqual(cfg.buildOptimization, "size")
        XCTAssertEqual(cfg.buildStripDebugInfo, true)
        XCTAssertEqual(cfg.buildSwiftUI, true, "swiftui defaults ON when omitted from .Patch.yml")
    }

    func testSwiftUIDefaultsOnAndOptsOut() throws {
        // Omitted → ON by default.
        let onByDefault = try PatchConfig.parse("""
        version: 1
        app_key: k
        project: P.xcodeproj
        target: P
        build:
          optimization: size
        """)
        XCTAssertTrue(onByDefault.buildSwiftUI, "SwiftUI lowering is ON when `swiftui` is omitted")

        // Explicit opt-out.
        let off = try PatchConfig.parse("""
        version: 1
        app_key: k
        project: P.xcodeproj
        target: P
        build:
          swiftui: false
        """)
        XCTAssertFalse(off.buildSwiftUI, "`swiftui: false` keeps views native")

        // Round-trips: a serialized config carries `swiftui` and parses back.
        var cfg = PatchConfig(appKey: "k", project: "P.xcodeproj", target: "P")
        cfg.buildSwiftUI = false
        let reparsed = try PatchConfig.parse(cfg.yamlString())
        XCTAssertFalse(reparsed.buildSwiftUI, "swiftui survives a serialize → parse round-trip")
    }

    func testRoundTripsThroughYAML() throws {
        var cfg = PatchConfig(appKey: "k", project: "P.xcodeproj", target: "P")
        cfg.appId = "11111111-1111-1111-1111-111111111111"
        cfg.workspaceId = "22222222-2222-2222-2222-222222222222"
        cfg.bundleId = "com.acme.app"
        cfg.exclude = ["A.swift"]
        cfg.bridges["notifications"] = false
        let text = cfg.yamlString()
        let parsed = try PatchConfig.parse(text)
        XCTAssertEqual(parsed.appId, cfg.appId)
        XCTAssertEqual(parsed.workspaceId, cfg.workspaceId)
        XCTAssertEqual(parsed.bundleId, "com.acme.app")
        XCTAssertEqual(parsed.exclude, cfg.exclude)
        XCTAssertEqual(parsed.bridges["notifications"], false)
        XCTAssertEqual(parsed.target, "P")
    }

    func testIgnoresCommentsAndUnknownKeys() throws {
        let yaml = """
        version: 1   # schema version
        app_key: abc
        future_key: whatever
        target: T
        project: T.xcodeproj
        """
        let cfg = try PatchConfig.parse(yaml)
        XCTAssertEqual(cfg.appKey, "abc")
        XCTAssertEqual(cfg.target, "T")
    }

    /// A `#` that is PART OF A VALUE (an API key, a URL fragment) must NOT be
    /// treated as a comment — the old parser truncated from the first `#`, silently
    /// corrupting any value containing one (e.g. an API key → broken auth with a
    /// confusing downstream error).
    func testHashInValueIsNotTreatedAsComment() throws {
        let yaml = """
        version: 1
        app_key: abc
        project: T.xcodeproj
        target: T
        api_key: sk-live-abc#def123
        api_base_url: http://host/path#frag
        """
        let cfg = try PatchConfig.parse(yaml)
        XCTAssertEqual(cfg.apiKey, "sk-live-abc#def123",
                       "a `#` glued to a value must be preserved, not stripped")
        XCTAssertEqual(cfg.apiBaseURL, "http://host/path#frag")
    }

    /// A `#` AFTER whitespace is still a real trailing comment (YAML rule) — the fix
    /// must not break the legitimate comment case.
    func testWhitespacePrecededHashStillStripsComment() throws {
        let yaml = """
        version: 1
        app_key: abc   # the workspace key
        project: T.xcodeproj
        target: T
        """
        let cfg = try PatchConfig.parse(yaml)
        XCTAssertEqual(cfg.appKey, "abc", "a whitespace-preceded `#` is a trailing comment")
    }

    func testEmptyExcludeInline() throws {
        let yaml = """
        version: 1
        app_key: abc
        project: T.xcodeproj
        target: T
        exclude: []
        bridges:
          networking: true
        """
        let cfg = try PatchConfig.parse(yaml)
        XCTAssertTrue(cfg.exclude.isEmpty)
        XCTAssertEqual(cfg.bridges["networking"], true)
    }

    func testLoadFromDiskAndFind() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
        let sub = tmp.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cfgURL = tmp.appendingPathComponent(".Patch.yml")
        try PatchConfig(appKey: "k", project: "P", target: "T").yamlString()
            .write(to: cfgURL, atomically: true, encoding: .utf8)

        let found = PatchConfig.find(startingAt: sub)
        XCTAssertEqual(found?.standardizedFileURL.path, cfgURL.standardizedFileURL.path)
        let loaded = try PatchConfig.load(from: cfgURL)
        XCTAssertEqual(loaded.appKey, "k")
    }
}

// MARK: - Project discovery (target inference + bundle id)

final class ProjectDiscoveryTests: XCTestCase {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("disc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testInfersTargetFromSinglePackageProduct() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "Acme",
            products: [ .library(name: "AcmeKit", targets: ["AcmeKit"]) ],
            targets: [ .target(name: "AcmeKit") ]
        )
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let p = ProjectDiscovery.detect(in: dir)
        XCTAssertEqual(p.kind, .swiftPackage)
        XCTAssertEqual(p.target, "AcmeKit")
        XCTAssertFalse(p.targetAmbiguous)
    }

    func testAmbiguousWhenMultiplePackageProductsAndNoPrimary() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try """
        import PackageDescription
        let package = Package(
            name: "Acme",
            products: [
                .library(name: "Foo", targets: ["Foo"]),
                .executable(name: "Bar", targets: ["Bar"]),
            ]
        )
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let p = ProjectDiscovery.detect(in: dir)
        XCTAssertNil(p.target, "no single obvious target → ambiguous")
        XCTAssertTrue(p.targetAmbiguous)
        XCTAssertEqual(Set(p.targetCandidates), ["Foo", "Bar"])
    }

    func testPackageNameWinsWhenItMatchesAProduct() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try """
        import PackageDescription
        let package = Package(
            name: "Acme",
            products: [
                .library(name: "Acme", targets: ["Acme"]),
                .library(name: "AcmeExtras", targets: ["AcmeExtras"]),
            ]
        )
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let p = ProjectDiscovery.detect(in: dir)
        XCTAssertEqual(p.target, "Acme", "the product matching the package name is the primary")
        XCTAssertFalse(p.targetAmbiguous)
    }

    func testInfersTargetAndBundleIdFromXcodeProject() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let proj = dir.appendingPathComponent("MyApp.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let pbx = """
        // !$*UTF8*$!
        {
            objects = {
                AAAA = { isa = PBXNativeTarget; name = MyApp; };
                BBBB = { isa = PBXNativeTarget; name = MyAppTests; };
                CCCC = { isa = XCBuildConfiguration; buildSettings = {
                    PRODUCT_BUNDLE_IDENTIFIER = com.acme.myapp;
                }; };
            };
        }
        """
        try pbx.write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

        let p = ProjectDiscovery.detect(in: dir)
        XCTAssertEqual(p.kind, .xcodeproj)
        XCTAssertEqual(p.project, "MyApp.xcodeproj")
        XCTAssertEqual(p.target, "MyApp", "test target excluded → single app target")
        XCTAssertFalse(p.targetAmbiguous)

        let bundleId = ProjectDiscovery.bundleIdentifier(in: dir)
        XCTAssertEqual(bundleId, "com.acme.myapp")
    }

    func testBundleIdFromInfoPlistWhenNoPbxproj() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let plist: [String: Any] = ["CFBundleIdentifier": "com.acme.plistapp"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Info.plist"))
        XCTAssertEqual(ProjectDiscovery.bundleIdentifier(in: dir), "com.acme.plistapp")
    }

    func testBundleIdSkipsPlaceholderInPbxProj() throws {
        // $(...) placeholders are not resolvable → treated as absent.
        let s = "PRODUCT_BUNDLE_IDENTIFIER = \"$(PRODUCT_BUNDLE_IDENTIFIER)\";"
        XCTAssertNil(ProjectDiscovery.firstBundleID(inPBXProj: s))
        let s2 = "PRODUCT_BUNDLE_IDENTIFIER = com.real.id;"
        XCTAssertEqual(ProjectDiscovery.firstBundleID(inPBXProj: s2), "com.real.id")
    }
}

// MARK: - Project fingerprint

final class ProjectFingerprintTests: XCTestCase {
    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try "import UIKit\nclass V {}".write(to: tmp.appendingPathComponent("View.swift"),
                                              atomically: true, encoding: .utf8)
        try "import Foundation\nstruct M {}".write(to: tmp.appendingPathComponent("Model.swift"),
                                                    atomically: true, encoding: .utf8)
        try "// generated".write(to: tmp.appendingPathComponent("Frag_wasm.swift"),
                                  atomically: true, encoding: .utf8)
        return tmp
    }

    func testDeterministicAndExcludesWasmSources() throws {
        let dir = try makeProject()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        let a = fp.snapshot(projectDir: dir, bridges: PatchConfig.defaultBridges)
        let b = fp.snapshot(projectDir: dir, bridges: PatchConfig.defaultBridges)
        XCTAssertEqual(a.fingerprint, b.fingerprint, "fingerprint must be deterministic")
        XCTAssertEqual(a.fingerprint.count, 64)
        // _wasm.swift is OTA-updatable and must NOT be counted as a native file.
        XCTAssertFalse(a.components.nativeSwiftFiles.contains { $0.contains("Frag_wasm.swift") },
                       "generated _wasm.swift must be excluded from the native fingerprint")
        XCTAssertEqual(a.components.nativeSwiftFiles.count, 2, "View.swift + Model.swift")
    }

    func testChangingANativeFileChangesFingerprint() throws {
        let dir = try makeProject()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        let before = fp.snapshot(projectDir: dir, bridges: PatchConfig.defaultBridges).fingerprint
        try "import UIKit\nclass V { func x() {} }".write(
            to: dir.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)
        let after = fp.snapshot(projectDir: dir, bridges: PatchConfig.defaultBridges).fingerprint
        XCTAssertNotEqual(before, after, "editing a native swift file must change the fingerprint")
    }

    func testEditingWasmSourceDoesNotChangeFingerprint() throws {
        let dir = try makeProject()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        let before = fp.snapshot(projectDir: dir, bridges: PatchConfig.defaultBridges).fingerprint
        try "// generated v2 — different".write(
            to: dir.appendingPathComponent("Frag_wasm.swift"), atomically: true, encoding: .utf8)
        let after = fp.snapshot(projectDir: dir, bridges: PatchConfig.defaultBridges).fingerprint
        XCTAssertEqual(before, after, "OTA-updatable _wasm.swift must NOT affect the native fingerprint")
    }

    func testChangingBridgesChangesFingerprint() throws {
        let dir = try makeProject()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        let withAll = fp.snapshot(projectDir: dir, bridges: PatchConfig.defaultBridges).fingerprint
        var fewer = PatchConfig.defaultBridges; fewer["keychain"] = false
        let withFewer = fp.snapshot(projectDir: dir, bridges: fewer).fingerprint
        XCTAssertNotEqual(withAll, withFewer, "changing the bridge set must change the fingerprint")
    }

    /// SAFETY: a change to a BINARY Info.plist that differs only in invalid-UTF-8
    /// bytes must change the fingerprint. The old `String(decoding:as:UTF8)` content
    /// hash collapsed every invalid byte to U+FFFD, so two different binary plists
    /// hashed identically and a real native-shell change slipped past the gate.
    func testBinaryInfoPlistChangeChangesFingerprint() throws {
        let dir = try makeProject()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fp = ProjectFingerprinter(swiftCompilerVersion: "6.3.2")
        let plist = dir.appendingPathComponent("Info.plist")
        // bplist header + a byte that decodes to U+FFFD (invalid as a standalone byte).
        try Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0xFF, 0x01]).write(to: plist)
        let before = fp.snapshot(projectDir: dir, bridges: PatchConfig.defaultBridges).fingerprint
        // Differ ONLY in the invalid-UTF-8 byte (0xFF -> 0xFE) — same lossy decode.
        try Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0xFE, 0x01]).write(to: plist)
        let after = fp.snapshot(projectDir: dir, bridges: PatchConfig.defaultBridges).fingerprint
        XCTAssertNotEqual(before, after,
                          "a binary Info.plist change must change the fingerprint (raw-byte hash)")
    }
}

// MARK: - Build pipeline (real engine, stub compiler — no toolchain needed)

final class BuildPipelineTests: XCTestCase {
    func testEmitsSourcesAndDriversConvergence() throws {
        // OrderApp-style mixed function: pure Decimal logic + UserDefaults.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bp-\(UUID().uuidString)")
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        import Foundation
        struct S {
            func loyalty(_ points: Int) -> Int {
                let base = points * 10
                let scaled = base + 5
                UserDefaults.standard.set(scaled, forKey: "p")
                return scaled
            }
        }
        """.write(to: src.appendingPathComponent("S.swift"), atomically: true, encoding: .utf8)

        let buildDir = dir.appendingPathComponent("build")
        let pipeline = BuildPipeline()
        // Dry-run: exercises parse→classify→split→emit without the heavy toolchain.
        let result = try pipeline.run(sourceDir: src, buildDir: buildDir,
                                      compiler: StubWasmCompiler(), dryRun: true)
        XCTAssertGreaterThan(result.report.functionCount, 0)
        XCTAssertFalse(result.generatedWasmSources.isEmpty,
                       "pipeline should emit at least one WASM source (split fragment or version probe)")
        for s in result.generatedWasmSources {
            XCTAssertTrue(FileManager.default.fileExists(atPath: s.path))
        }
    }

    func testProducesProbeWhenNothingSplits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bp2-\(UUID().uuidString)")
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Purely native file → no mixed splits → pipeline emits a version probe.
        try "import UIKit\nclass V: UIViewController {}".write(
            to: src.appendingPathComponent("V.swift"), atomically: true, encoding: .utf8)
        let result = try BuildPipeline().run(sourceDir: src, buildDir: dir.appendingPathComponent("build"),
                                             compiler: StubWasmCompiler(), dryRun: true)
        XCTAssertEqual(result.generatedWasmSources.count, 1)
        XCTAssertTrue(result.exportSymbols.contains("patch_module_version"))
    }
}

// MARK: - API client (mocked — no live network in unit tests)

/// A scripted in-memory backend that records calls and returns canned wire JSON.
private final class MockAPI: PatchAPI, @unchecked Sendable {
    var registeredFingerprint: FingerprintRecord?
    var uploaded: [(ModuleUploadMetadata, Int)] = []
    var modules: [ModuleRecord] = []
    var rollbackCalls: [String] = []
    var rolloutCalls: [(String, Int)] = []
    /// Apps keyed by bundle id, returned by `lookupApp`.
    var appsByBundleId: [String: AppRecord] = [:]
    var lookupCalls: [String] = []

    func lookupApp(bundleId: String) throws -> AppRecord? {
        lookupCalls.append(bundleId)
        return appsByBundleId[bundleId]
    }
    func registerFingerprint(appId: String, fingerprint: String, components: [String: Any],
                             appVersion: String?) throws -> FingerprintRecord {
        let rec = FingerprintRecord(id: "fp-id-1", appId: appId, fingerprint: fingerprint,
                                    isActive: true, appVersion: appVersion)
        registeredFingerprint = rec
        return rec
    }
    func getActiveFingerprint(appId: String) throws -> FingerprintRecord? { registeredFingerprint }
    /// Scripted entitlements for the paid-rollout pre-check (B3). When nil the
    /// call throws (simulating offline / old backend → fall-back behavior).
    var entitlementsResult: Entitlements?
    var entitlementsCalls: [String] = []
    func entitlements(workspaceId: String) throws -> Entitlements {
        entitlementsCalls.append(workspaceId)
        guard let e = entitlementsResult else {
            throw APIError.transport("entitlements unavailable (mock)")
        }
        return e
    }
    /// Records icon uploads (appId, byteCount, fileName). When `iconUploadShouldFail`
    /// is set the call throws (simulating a missing endpoint), so we can assert the
    /// caller SKIPS cleanly.
    var iconUploads: [(String, Int, String)] = []
    var iconUploadShouldFail = false
    func uploadAppIcon(appId: String, icon: Data, fileName: String, mimeType: String) throws -> String? {
        if iconUploadShouldFail { throw APIError.http(status: 404, body: "no icon endpoint (mock)") }
        iconUploads.append((appId, icon.count, fileName))
        return "apps/\(appId)/icon.png"
    }
    func uploadModule(metadata: ModuleUploadMetadata, wasm: Data) throws -> ModuleRecord {
        uploaded.append((metadata, wasm.count))
        let rec = ModuleRecord(id: "mod-\(uploaded.count)", appId: metadata.appId, version: metadata.version,
                               channel: metadata.channel, sha256: "deadbeef", sizeBytes: wasm.count,
                               rolloutPct: metadata.rolloutPct, mandatory: metadata.mandatory, isActive: true,
                               releaseNotes: metadata.releaseNotes,
                               modulePath: "app/fingerprints/x/modules/\(metadata.version)/module.wasm.br",
                               pushedAt: "2026-01-01T00:00:00Z", rolledBackAt: nil)
        modules.insert(rec, at: 0)
        return rec
    }
    func listModules(appId: String, channel: String?) throws -> [ModuleRecord] {
        channel.map { c in modules.filter { $0.channel == c } } ?? modules
    }
    func updateRollout(moduleID: String, rolloutPct: Int) throws -> ModuleRecord {
        rolloutCalls.append((moduleID, rolloutPct))
        return modules.first { $0.id == moduleID }!
    }
    func rollback(moduleID: String) throws -> ModuleRecord {
        rollbackCalls.append(moduleID)
        return modules.first { $0.id == moduleID }!
    }
    func stats(moduleID: String) throws -> ModuleStats {
        ModuleStats(moduleId: moduleID, version: "1", downloads: 100, activations: 80, errors: 4)
    }
}

final class APIClientTests: XCTestCase {
    func testRegisterAndFetchFingerprint() throws {
        let api = MockAPI()
        let rec = try api.registerFingerprint(appId: "app-1", fingerprint: String(repeating: "a", count: 64),
                                              components: ["k": 1], appVersion: "2.0.0")
        XCTAssertEqual(rec.id, "fp-id-1")
        XCTAssertEqual(try api.getActiveFingerprint(appId: "app-1")?.fingerprint, rec.fingerprint)
    }

    func testUploadMetadataJSONMatchesBackendSchema() throws {
        let meta = ModuleUploadMetadata(appId: "A", workspaceId: "W", version: "1.2.3",
                                        fingerprintId: "F", channel: "beta", mandatory: true,
                                        rolloutPct: 25, releaseNotes: "notes")
        let json = meta.jsonString()
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(obj["app_id"] as? String, "A")
        XCTAssertEqual(obj["workspace_id"] as? String, "W")
        XCTAssertEqual(obj["fingerprint_id"] as? String, "F")
        XCTAssertEqual(obj["version"] as? String, "1.2.3")
        XCTAssertEqual(obj["channel"] as? String, "beta")
        XCTAssertEqual(obj["mandatory"] as? Bool, true)
        XCTAssertEqual(obj["rollout_pct"] as? Int, 25)
        XCTAssertEqual(obj["release_notes"] as? String, "notes")
    }

    func testUploadRecordsAndStatsComputeRates() throws {
        let api = MockAPI()
        let meta = ModuleUploadMetadata(appId: "A", workspaceId: "W", version: "1.0.0", fingerprintId: "F")
        _ = try api.uploadModule(metadata: meta, wasm: Data(repeating: 0, count: 1234))
        XCTAssertEqual(api.uploaded.count, 1)
        XCTAssertEqual(api.uploaded[0].1, 1234)

        let stats = try api.stats(moduleID: "mod-1")
        XCTAssertEqual(stats.adoptionRate, 0.8, accuracy: 0.001)        // 80/100
        XCTAssertEqual(stats.failureRate, 4.0 / 84.0, accuracy: 0.001)  // 4/(80+4)
    }

    func testRollbackInvokesBackend() throws {
        let api = MockAPI()
        _ = try api.uploadModule(metadata: ModuleUploadMetadata(appId: "A", workspaceId: "W",
                                                                version: "1.0.0", fingerprintId: "F"),
                                 wasm: Data([0]))
        _ = try api.rollback(moduleID: "mod-1")
        XCTAssertEqual(api.rollbackCalls, ["mod-1"])
    }

    /// Mirrors `CLISupport.resolveAppID`: when `app_id` is absent but `bundle_id`
    /// is set, the app is looked up by bundle id and the result is cached back
    /// into `.Patch.yml` (with workspace_id filled in).
    func testResolveAppIDByBundleIdAndCachesBack() throws {
        let api = MockAPI()
        api.appsByBundleId["com.acme.app"] = AppRecord(
            id: "app-uuid-1", workspaceId: "ws-uuid-1",
            name: "Acme", bundleId: "com.acme.app", platform: "ios")

        var cfg = PatchConfig(appKey: "k", project: "P", target: "P")
        cfg.bundleId = "com.acme.app"
        XCTAssertNil(cfg.appId)

        // The resolution the CLI performs: look up, then write back.
        let app = try XCTUnwrap(try api.lookupApp(bundleId: cfg.bundleId!))
        cfg.appId = app.id
        if (cfg.workspaceId ?? "").isEmpty { cfg.workspaceId = app.workspaceId }

        XCTAssertEqual(cfg.appId, "app-uuid-1")
        XCTAssertEqual(cfg.workspaceId, "ws-uuid-1")
        XCTAssertEqual(api.lookupCalls, ["com.acme.app"])

        // Persisted form round-trips so the next push skips the lookup.
        let reparsed = try PatchConfig.parse(cfg.yamlString())
        XCTAssertEqual(reparsed.appId, "app-uuid-1")
        XCTAssertEqual(reparsed.workspaceId, "ws-uuid-1")
        XCTAssertEqual(reparsed.bundleId, "com.acme.app")
    }

    func testLookupAppMissingBundleIdReturnsNil() throws {
        let api = MockAPI()
        XCTAssertNil(try api.lookupApp(bundleId: "com.nope.app"))
    }
}
