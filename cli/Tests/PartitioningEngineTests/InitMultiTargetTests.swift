// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import PatchCLI

/// [BUG-3] Subprocess test: `Patch init` on a MULTI-TARGET SPM package (Regex /
/// swift-numerics shape — multiple library products, none matching the package
/// name) must NOT dead-end. Pre-fix, `init` threw "Could not infer a single build
/// target …" and wrote no config, stranding a first-run user. The fix defaults to
/// the first candidate, writes `.Patch.yml`, and guides the user to switch targets.
///
/// The command struct lives in the non-importable `PatchCLI` executable, so we
/// exercise the real binary (mirrors ShipAliasTests).
final class InitMultiTargetTests: XCTestCase {

    private func patchBinary() throws -> URL {
        #if os(macOS)
        let bundle = Bundle(for: type(of: self))
        let productsDir = bundle.bundleURL.deletingLastPathComponent()
        let url = productsDir.appendingPathComponent("patchcli")
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        #endif
        let pkgRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let debug = pkgRoot.appendingPathComponent(".build/debug/patchcli")
        if FileManager.default.isExecutableFile(atPath: debug.path) { return debug }
        throw XCTSkip("patchcli binary not found — run `swift build` first.")
    }

    private func run(_ args: [String], cwd: URL) throws -> (out: String, err: String, code: Int32) {
        let proc = Process()
        proc.executableURL = try patchBinary()
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe; proc.standardError = errPipe
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self), proc.terminationStatus)
    }

    func testInitOnMultiTargetPackageSucceedsAndGuides() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("init-mt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
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

        let r = try run(["init"], cwd: dir)
        XCTAssertEqual(r.code, 0,
                       "BUG-3: init must NOT dead-end on a multi-target package. stderr:\n\(r.err)")
        // It wrote a config (no longer a hard failure).
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".Patch.yml").path),
                      "init must scaffold .Patch.yml on a multi-target package")
        // It defaulted to the first product and guided the user to the rest.
        XCTAssertTrue(r.out.contains("Numerics"), "init should report the defaulted target; got:\n\(r.out)")
        XCTAssertTrue(r.out.contains("Multiple build targets") && r.out.contains("--target"),
                      "init should list the candidates and how to switch; got:\n\(r.out)")
    }

    func testInitOnSingleTargetPackageStillInfersSilently() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("init-st-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "Solo",
            products: [ .library(name: "Solo", targets: ["Solo"]) ],
            targets: []
        )
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let r = try run(["init"], cwd: dir)
        XCTAssertEqual(r.code, 0, "single-target init should succeed; stderr:\n\(r.err)")
        XCTAssertTrue(r.out.contains("Solo (inferred)"),
                      "a single-target package must infer silently (no ambiguity notice); got:\n\(r.out)")
        XCTAssertFalse(r.out.contains("Multiple build targets"),
                       "no ambiguity notice for a single-target package; got:\n\(r.out)")
    }

    // MARK: - App-icon upload during `patchcli init` (feature)

    /// `patchcli init` locates the app's primary icon (the largest PNG in
    /// `AppIcon.appiconset`) and ATTEMPTS to upload it immediately after registration.
    /// When no backend is reachable (the common test case — no real key, no server),
    /// it falls back gracefully to a deferred "uploaded on push" message: init must
    /// NEVER fail because of a cosmetic icon upload.
    func testInitReportsDetectedAppIcon() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("init-icon-\(UUID().uuidString)")
        let iconSet = dir.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
        try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Solo", products: [.library(name: "Solo", targets: ["Solo"])], targets: [])
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // PNG magic + padding so it is a valid, non-empty PNG.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 2000))
        try png.write(to: iconSet.appendingPathComponent("Icon-1024.png"))

        let r = try run(["init"], cwd: dir)
        XCTAssertEqual(r.code, 0, "init should succeed; stderr:\n\(r.err)")
        // Without a real registered key/backend the upload falls back gracefully —
        // the icon line still reports the detected file, just deferred to push.
        XCTAssertTrue(r.out.contains("App icon:") && r.out.contains("Icon-1024.png"),
                      "init should report the detected app icon (upload or deferred); got:\n\(r.out)")
    }

    /// Icon upload failure (no backend reachable) MUST NOT fail init.
    /// Init must exit 0 even when the upload call throws.
    func testInitIconUploadFailureDoesNotFailInit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("init-icon-fail-\(UUID().uuidString)")
        let iconSet = dir.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
        try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Solo", products: [.library(name: "Solo", targets: ["Solo"])], targets: [])
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // Write a valid PNG icon so AppIconLocator finds it.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 2000))
        try png.write(to: iconSet.appendingPathComponent("AppIcon-1024.png"))
        // Write a pre-configured .Patch.yml with a fake key+app_id pointing at an
        // unreachable backend so the upload attempt throws a network error.
        try """
        version: 1
        app_key: pak_fakekey_for_icon_test
        project: Solo
        target: Solo
        app_id: 00000000-0000-0000-0000-000000000001
        workspace_id: 00000000-0000-0000-0000-000000000002
        api_base_url: http://127.0.0.1:19999
        """.write(to: dir.appendingPathComponent(".Patch.yml"), atomically: true, encoding: .utf8)

        let r = try run(["init", "--manual"], cwd: dir)
        // The icon upload will fail (no server at 19999) — init must still succeed.
        XCTAssertEqual(r.code, 0,
                       "init must exit 0 even when the icon upload fails; stderr:\n\(r.err)")
        // Icon line must still appear (either "✓ uploaded" or the fallback).
        XCTAssertTrue(r.out.contains("App icon:") && r.out.contains("AppIcon-1024.png"),
                      "init must still report the icon even when upload fails; got:\n\(r.out)")
    }

    /// No icon present → init does NOT print an icon line and still succeeds.
    func testInitWithoutIconOmitsIconLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("init-noicon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Solo", products: [.library(name: "Solo", targets: ["Solo"])], targets: [])
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let r = try run(["init"], cwd: dir)
        XCTAssertEqual(r.code, 0)
        XCTAssertFalse(r.out.contains("App icon:"),
                       "no icon present → no icon line; got:\n\(r.out)")
    }

    // MARK: - Placeholder app_key is NOT treated as a configured key (P2)

    /// `patch init` writes `app_key: pak_REPLACE_ME` as a placeholder. Treating it
    /// as a real key made `whoami` report "API key: configured" and made every
    /// networked command send `pak_REPLACE_ME` (an opaque 401). After the fix the
    /// placeholder resolves to "not configured" so the message is honest.
    func testPlaceholderAppKeyReportsNotConfigured() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("init-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A fresh init-style config carrying ONLY the placeholder app_key.
        try """
        version: 1
        app_key: pak_REPLACE_ME
        project: Solo
        target: Solo
        """.write(to: dir.appendingPathComponent(".Patch.yml"), atomically: true, encoding: .utf8)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PATCH_API_KEY")  // ensure the env doesn't supply one
        let proc = Process()
        proc.executableURL = try patchBinary()
        proc.arguments = ["whoami"]
        proc.currentDirectoryURL = dir
        proc.environment = env
        let outPipe = Pipe(); proc.standardOutput = outPipe; proc.standardError = Pipe()
        try proc.run()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        XCTAssertTrue(out.contains("Publish token:  NOT configured"),
                      "the pak_REPLACE_ME placeholder must read as NOT configured; got:\n\(out)")
    }

    // MARK: - Invalid --version fails fast (before the build), with a clear message

    /// The backend's `ModuleMetadata.version` requires `^[A-Za-z0-9._-]+$` (the
    /// value becomes a storage path segment). A `--version` with a space used to
    /// pass client-side, run the whole build, and only 422 at upload. `release`
    /// now validates the version BEFORE the build and refuses with a clear message.
    func testReleaseRejectsInvalidVersionBeforeBuild() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        version: 1
        app_key: pak_real_key
        project: Solo
        target: Solo
        app_id: 11111111-1111-1111-1111-111111111111
        workspace_id: 22222222-2222-2222-2222-222222222222
        """.write(to: dir.appendingPathComponent(".Patch.yml"), atomically: true, encoding: .utf8)

        let r = try run(["release", "--version", "v1 beta"], cwd: dir)
        XCTAssertNotEqual(r.code, 0, "an invalid --version must fail; stdout:\n\(r.out)\nstderr:\n\(r.err)")
        let combined = r.out + r.err
        XCTAssertTrue(combined.contains("--version") && combined.lowercased().contains("invalid"),
                      "the error must name --version as invalid; got out:\n\(r.out)\nerr:\n\(r.err)")
        // It must NOT have proceeded to a build (no coverage/toolchain banner).
        XCTAssertFalse(combined.contains("Coverage report:"),
                       "version validation must fail BEFORE the build; got out:\n\(r.out)")
    }

    // MARK: - First-run completeness: init scaffolds a COMPLETE, production-pointed config

    /// `patch init` must record a backend URL so the scaffolded project is complete.
    /// Pre-fix, no `api_base_url` was written, so a brew-installed CLI silently fell
    /// back to `http://localhost:8000` and every networked command failed with a
    /// connection-refused on a first run. It must default to the LIVE production API.
    func testInitWritesProductionBaseURLByDefault() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("init-baseurl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Solo", products: [.library(name: "Solo", targets: ["Solo"])], targets: [])
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let r = try run(["init"], cwd: dir)
        XCTAssertEqual(r.code, 0, "init should succeed; stderr:\n\(r.err)")
        let cfg = try String(contentsOf: dir.appendingPathComponent(".Patch.yml"), encoding: .utf8)
        XCTAssertTrue(cfg.contains("api_base_url: https://api.patchrelease.com"),
                      "init must record the production backend URL; got:\n\(cfg)")
        XCTAssertFalse(cfg.contains("localhost"),
                       "init must NOT scaffold a localhost backend; got:\n\(cfg)")
    }

    /// An explicit `--base-url` overrides the production default (self-hosted / local dev).
    func testInitBaseURLFlagOverridesDefault() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("init-baseurl2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Solo", products: [.library(name: "Solo", targets: ["Solo"])], targets: [])
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let r = try run(["init", "--base-url", "http://localhost:8787"], cwd: dir)
        XCTAssertEqual(r.code, 0, "init should succeed; stderr:\n\(r.err)")
        let cfg = try String(contentsOf: dir.appendingPathComponent(".Patch.yml"), encoding: .utf8)
        XCTAssertTrue(cfg.contains("api_base_url: http://localhost:8787"),
                      "an explicit --base-url must win; got:\n\(cfg)")
    }

    /// The `init` next-steps must point at the REAL public SDK repo + product, not a
    /// dead URL. Pre-fix it printed `github.com/patch-sh/patch-ios` `from: 0.1.0` and
    /// "add the `Patch` Swift package" — all three wrong (the repo 404s), a guaranteed
    /// first-step dead-end. The real package is `patch-release/patch-swift`,
    /// product `PatchSDK`, tag `1.0.0`.
    func testInitNextStepsPointAtRealSDK() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("init-sdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Solo", products: [.library(name: "Solo", targets: ["Solo"])], targets: [])
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let r = try run(["init"], cwd: dir)
        XCTAssertEqual(r.code, 0, "init should succeed; stderr:\n\(r.err)")
        XCTAssertTrue(r.out.contains("github.com/patch-release/patch-swift"),
                      "init must point at the real SDK repo; got:\n\(r.out)")
        XCTAssertTrue(r.out.contains("PatchSDK"),
                      "init must name the real SDK product (PatchSDK); got:\n\(r.out)")
        // The old dead URL must be gone.
        XCTAssertFalse(r.out.contains("patch-sh/patch-ios"),
                       "the dead SDK URL must not be printed; got:\n\(r.out)")
    }

    // MARK: - whoami surfaces the still-missing setup (so gaps are learned up front)

    /// A freshly-`init`'d config (placeholder key, no app_id/workspace_id/bundle_id)
    /// must tell the developer EXACTLY what's still needed before `patch push`, so the
    /// "no app_id / no workspace_id" gotcha is discoverable in ONE offline command
    /// instead of as a sequence of mid-flow errors.
    func testWhoamiListsMissingSetupForPush() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whoami-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        version: 1
        app_key: pak_REPLACE_ME
        project: Solo
        target: Solo
        """.write(to: dir.appendingPathComponent(".Patch.yml"), atomically: true, encoding: .utf8)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PATCH_API_KEY")
        let proc = Process()
        proc.executableURL = try patchBinary()
        proc.arguments = ["whoami"]
        proc.currentDirectoryURL = dir
        proc.environment = env
        let outPipe = Pipe(); proc.standardOutput = outPipe; proc.standardError = Pipe()
        try proc.run()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        XCTAssertTrue(out.contains("Still needed before `patchcli push`:"),
                      "whoami must list what's missing; got:\n\(out)")
        XCTAssertTrue(out.contains("publish token"),
                      "must flag the missing publish token; got:\n\(out)")
        XCTAssertTrue(out.contains("patchcli login"),
                      "must name the command that supplies it; got:\n\(out)")
        XCTAssertTrue(out.contains("app_id"), "must flag the missing app_id; got:\n\(out)")
        XCTAssertTrue(out.contains("workspace_id"), "must flag the missing workspace_id; got:\n\(out)")
    }

    /// A fully-configured project reports "Ready to push", and a pinned `bundle_id`
    /// (which resolves app_id/workspace_id on the first push) is treated as sufficient.
    func testWhoamiReadyWhenConfiguredOrBundleIdPresent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whoami-ready-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func whoami() throws -> String {
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "PATCH_API_KEY")
            let proc = Process()
            proc.executableURL = try patchBinary()
            proc.arguments = ["whoami"]
            proc.currentDirectoryURL = dir
            proc.environment = env
            let outPipe = Pipe(); proc.standardOutput = outPipe; proc.standardError = Pipe()
            try proc.run()
            let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            proc.waitUntilExit()
            return out
        }

        // An app_key ALONE is NOT ready: it is a public device identifier that
        // ships inside the app binary, and the backend rejects it for pushes.
        try """
        version: 1
        app_key: pak_realkey
        project: Solo
        target: Solo
        bundle_id: com.acme.app
        """.write(to: dir.appendingPathComponent(".Patch.yml"), atomically: true, encoding: .utf8)
        let appKeyOnly = try whoami()
        XCTAssertFalse(appKeyOnly.contains("Ready to push"),
                       "an app_key alone must NOT read as ready; got:\n\(appKeyOnly)")
        XCTAssertTrue(appKeyOnly.contains("publish token"),
                      "it must say what is actually missing; got:\n\(appKeyOnly)")

        // Publish token + bundle_id (app_id/workspace_id resolvable on first push).
        try """
        version: 1
        app_key: pak_realkey
        publish_token: ppt_realtoken
        project: Solo
        target: Solo
        bundle_id: com.acme.app
        """.write(to: dir.appendingPathComponent(".Patch.yml"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try whoami().contains("Ready to push"),
                      "publish token + bundle_id should read as ready")

        // Publish token + explicit app_id + workspace_id.
        try """
        version: 1
        app_key: pak_realkey
        publish_token: ppt_realtoken
        project: Solo
        target: Solo
        app_id: 11111111-1111-1111-1111-111111111111
        workspace_id: 22222222-2222-2222-2222-222222222222
        """.write(to: dir.appendingPathComponent(".Patch.yml"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try whoami().contains("Ready to push"),
                      "publish token + app_id + workspace_id should read as ready")
    }

    // MARK: - Resolve-timeout robustness (DX: init must never hang on a slow network)

    /// The constant that bounds both `xcodebuild -resolvePackageDependencies`
    /// and `swift package resolve` must be sensible — not so short that a slow
    /// (but live) registry is cut off immediately, not so long that a stalled
    /// network looks like a hang to the user.
    func testResolveTimeoutConstantIsReasonable() {
        // 30 s lower-bound: enough for a cold CDN hit on a fast connection.
        // 120 s upper-bound: beyond this the user's terminal feels unresponsive.
        XCTAssertGreaterThanOrEqual(Init.resolveTimeoutSeconds, 30,
            "resolve timeout must give a real connection at least 30 s")
        XCTAssertLessThanOrEqual(Init.resolveTimeoutSeconds, 120,
            "resolve timeout must not exceed 120 s (would feel like a hang to the user)")
    }

    /// `Init.forceKill` must terminate a long-running process AND leave it dead.
    /// We start `/bin/sleep 30`, call `forceKill`, and assert the process exits
    /// well within the 5 s test budget.  This directly exercises the SIGTERM +
    /// SIGKILL escalation path that guards both `resolvePackages` and
    /// `resolveSwiftPackage`.
    func testForceKillTerminatesLongRunningProcess() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        XCTAssertTrue(p.isRunning, "sleep should be running before we kill it")

        let start = Date()
        Init.forceKill(p)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(p.isRunning,
            "process must be dead after forceKill; elapsed \(elapsed) s")
        XCTAssertLessThan(elapsed, 5,
            "forceKill must complete in under 5 s; took \(elapsed) s")
    }

    /// A fast-path check: `patchcli init` on a package that already has no
    /// unresolved dependencies completes quickly (swift package resolve exits 0
    /// immediately when the lockfile is up to date with no deps to fetch).
    /// This guards the common case — package was already resolved — where the
    /// spinner should flash for < 5 s, not block for minutes.
    func testInitResolveFastPathCompletesQuickly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("init-resolve-fast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A package with NO external dependencies — swift package resolve exits 0
        // instantly (nothing to fetch), so this exercises the spinner fast path.
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "Solo",
            products: [.library(name: "Solo", targets: ["Solo"])],
            targets: [.target(name: "Solo")]
        )
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // Create a minimal source file so the target doesn't warn.
        let srcDir = dir.appendingPathComponent("Sources/Solo")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "// placeholder".write(to: srcDir.appendingPathComponent("Solo.swift"), atomically: true, encoding: .utf8)

        let start = Date()
        let r = try run(["init", "--manual"], cwd: dir)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(r.code, 0, "init must succeed; stderr:\n\(r.err)")
        // Generous budget: 30 s covers a slow CI machine but rules out a multi-
        // minute stall from a genuinely hung resolver.
        XCTAssertLessThan(elapsed, 30,
            "init must not hang — completed in \(elapsed) s. stdout:\n\(r.out)")
    }

    /// A config WITHOUT `api_base_url` (e.g. one scaffolded before this fix) must
    /// fall back to the PRODUCTION API, never localhost. `whoami` echoes the
    /// resolved base URL, so it's the cheapest end-to-end check of the default.
    func testDefaultBaseURLIsProductionNotLocalhost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baseurl-default-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // No api_base_url line on purpose.
        try """
        version: 1
        app_key: pak_realkey
        project: Solo
        target: Solo
        """.write(to: dir.appendingPathComponent(".Patch.yml"), atomically: true, encoding: .utf8)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PATCH_API_URL")
        let proc = Process()
        proc.executableURL = try patchBinary()
        proc.arguments = ["whoami"]
        proc.currentDirectoryURL = dir
        proc.environment = env
        let outPipe = Pipe(); proc.standardOutput = outPipe; proc.standardError = Pipe()
        try proc.run()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        XCTAssertTrue(out.contains("Base URL:       https://api.patchrelease.com"),
                      "the default backend must be the production API; got:\n\(out)")
        XCTAssertFalse(out.contains("localhost"),
                       "the default backend must NOT be localhost; got:\n\(out)")
    }
}
