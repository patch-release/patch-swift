// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import PartitioningEngine
import Compiler

/// `Patch release` — `build` then `push` in a single command.
///
/// Runs the SAME `BuildPipeline` invocation `Patch build` uses (parse → classify
/// → split → compile to a real `.wasm` at `.Patch/build/module.wasm`), verifies
/// the module exists, then runs the SAME fingerprint-gate + upload as `Patch push`
/// by delegating to the shared `PushFlow`. The HTTP client is NOT duplicated —
/// both `push` and `release` go through `PushFlow.run(...)`.
///
/// `Patch ship` is a deprecated alias for this command (see `Ship` below); it
/// runs the exact same flow and prints a one-line deprecation notice to stderr.
struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Release a patch to your users: build the .wasm then upload it in one shot (fingerprint-gated)."
    )

    // --- build flags ------------------------------------------------------
    @Option(name: .long, help: "Optimization: size | speed.")
    var optimization: String?

    @Option(name: .long, help: "Output .wasm path (default: .Patch/build/module.wasm).")
    var output: String?

    // --- push flags -------------------------------------------------------
    @Option(name: .long, help: "Release channel (default: production).")
    var channel: String = "production"

    @Option(name: .long, help: "Rollout percentage 0-100 (default: 100).")
    var rollout: Int = 100

    @Option(name: .shortAndLong, help: "Release notes / changelog message.")
    var message: String?

    @Option(name: .long, help: "Module version (default: timestamp-derived).")
    var version: String?

    @Option(name: .long, help: "Backend base URL override.")
    var baseURL: String?

    @Flag(name: .long, help: "Mark the update as mandatory.")
    var mandatory: Bool = false

    @Option(name: .long, help: "Only deliver to app versions ≥ this (e.g. 2.1.0). Absent = all versions.")
    var minAppVersion: String?

    @Option(name: .long, help: "Only deliver to app versions ≤ this (e.g. 3.0.0). Absent = no upper bound.")
    var maxAppVersion: String?

    @Option(name: .long, help: "Only deliver to OS versions ≥ this (e.g. 16.0). Absent = all OS versions.")
    var minOsVersion: String?

    @Option(name: .long, help: "Restrict the rollout to a named cohort/segment. Absent = all devices.")
    var targetCohort: String?

    @Flag(name: .long, help: "Build, then run all push checks + show what would be sent, but do not upload.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Upload even if the native-shell fingerprint gate reports a MISMATCH (dangerous; skips the compatibility refusal).")
    var force: Bool = false

    @Flag(name: .long, help: "Ship the patch when the native shell drifted ONLY in ways the OTA patch can't see (a package / Info.plist / entitlements / deployment-target change, with no native-source change). Refused if any change is patch-affecting. The non-interactive form of the native-drift prompt.")
    var allowNativeDrift: Bool = false

    @Flag(name: .long, help: "Release even if the module has no real OTA coverage (only a version probe / a degenerate near-empty module). Off by default.")
    var allowEmpty: Bool = false

    @Flag(name: .customLong("no-prepare"),
          help: "Skip the automatic `prepare` step (don't add `dynamic`/thunks to new views before building).")
    var noPrepare: Bool = false

    func run() throws {
        // Validate the push flags up front so we fail BEFORE the (expensive) build.
        try PushFlow.validate(rollout: rollout)
        try PushFlow.validate(version: version)

        // --- 0. Paid-only rollout pre-check (B3) — BEFORE the build --------
        // If the developer asked for a paid-only rollout (non-100 --rollout or a
        // non-production --channel), check the workspace plan NOW and fail fast
        // with the server's exact upgrade message + URL — skipping the expensive
        // WASM compile entirely. The common path (rollout 100 / production) makes
        // NO round-trip and adds zero latency. An entitlements-call failure
        // (offline / old backend) falls back to today's behavior: build, then let
        // the upload's server-side gate decide (never block a legitimate push).
        if PaidRolloutPrecheck.requiresPaidPlan(channel: channel, rollout: rollout) {
            try precheckPaidRolloutBeforeBuild()
        }

        // --- 1. Resolve build inputs exactly like `Patch build` ------------
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var sourceDir: URL
        var buildRoot: URL
        var opt = optimization ?? "size"
        var swiftUIEnabled = true  // .Patch.yml `swiftui` (default on if no config)
        // Auto-prepare context (resolved alongside the build inputs).
        var prepareExcludes: [String] = []
        var prepareTarget: String?
        var resolvedConfig: PatchConfig?
        // Resource-overlay spec (.Patch.yml `overlay:`), resolved root-relative —
        // mirrors `Patch build` so `release` wraps the SAME artifact (a release
        // must never silently ship a module without the configured overlay).
        var overlaySpecURL: URL?

        if let configURL = PatchConfig.find(startingAt: cwd) {
            let cfg = try PatchConfig.load(from: configURL)
            let root = CLISupport.projectRoot(for: configURL)
            sourceDir = root
            buildRoot = root.appendingPathComponent(".Patch/build")
            if optimization == nil { opt = cfg.buildOptimization }
            swiftUIEnabled = cfg.buildSwiftUI
            prepareExcludes = cfg.exclude
            prepareTarget = cfg.target.isEmpty ? nil : cfg.target
            resolvedConfig = cfg
            if let spec = cfg.overlaySpec, !spec.isEmpty {
                overlaySpecURL = spec.hasPrefix("/")
                    ? URL(fileURLWithPath: spec)
                    : root.appendingPathComponent(spec)
            }
        } else {
            sourceDir = cwd
            buildRoot = cwd.appendingPathComponent(".Patch/build")
        }

        // Auto-prepare: make any NEW SwiftUI views patchable (insert `dynamic` + thunks)
        // BEFORE we build, so the developer never has to remember `patchcli prepare`.
        // Idempotent + quiet (silent when nothing's new); degrades gracefully on failure.
        AutoPrepare.run(root: sourceDir, excludes: prepareExcludes, target: prepareTarget,
                        noPrepareFlag: noPrepare, config: resolvedConfig)

        // `--output <path>`: the module is written to the EXACT path; generated
        // sources live next to it. Mirrors `Patch build`.
        var outputModule: URL?
        if let output {
            let outURL = URL(fileURLWithPath: output)
            buildRoot = outURL.deletingLastPathComponent()
            outputModule = outURL
        }

        guard ["size", "speed"].contains(opt) else {
            throw ValidationError("--optimization must be 'size' or 'speed', got '\(opt)'.")
        }

        let compiler = SwiftWasmCompiler()
        print("Patch release")
        print("=============")
        print("Source:         \(sourceDir.path)")
        print("Build dir:      \(buildRoot.path)")
        print("Optimization:   \(opt)")
        print("WASM toolchain: \(compiler.toolchainAvailable ? "available" : "NOT FOUND")")
        print("")

        guard compiler.toolchainAvailable else {
            throw ValidationError(
                "WASM toolchain unavailable — cannot produce a .wasm to release.\n"
                + "Install the swift.org toolchain + WebAssembly SDK, or run `patchcli build --dry-run`\n"
                + "to generate sources only.")
        }

        // --- 2. Run the SAME BuildPipeline `build` runs --------------------
        // The compile is silent and can take a couple of minutes — set expectations
        // up front, then show a live spinner so the user knows it's working (the
        // `defer` clears it even if it throws).
        print("This normally takes around 2 minutes to build.")
        let pipeline = BuildPipeline()
        let compileSpinner = Spinner("Compiling Swift → WebAssembly")
        compileSpinner.start()
        defer { compileSpinner.clear() }
        let result = try pipeline.run(
            sourceDir: sourceDir,
            buildDir: buildRoot,
            compiler: compiler,
            dryRun: false,
            outputModule: outputModule,
            swiftUIEnabled: swiftUIEnabled
        )
        compileSpinner.succeed("Compiled to WebAssembly")

        // --- 3. Verify the module exists -----------------------------------
        let moduleURL = result.moduleURL
            ?? outputModule
            ?? buildRoot.appendingPathComponent("module.wasm")
        guard FileManager.default.fileExists(atPath: moduleURL.path) else {
            // Surface why: failed compiles are demoted to native and may leave no module.
            var detail = ""
            if let outcome = result.compileOutcome, !outcome.reclassifiedNative.isEmpty {
                detail = "\n  Demoted to native (failed WASM compile): "
                    + outcome.reclassifiedNative.map { $0.functionID }.joined(separator: ", ")
            }
            throw ValidationError(
                "Build produced no .wasm at \(moduleURL.path) — nothing to release.\(detail)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: moduleURL.path)[.size] as? Int) ?? nil
        print("Build OK — module: \(moduleURL.path)\(size.map { " (\($0) bytes)" } ?? "")")
        print("Compiled OTA units: \(result.compileOutcome?.compiled.count ?? 0)")

        // R4 #161: wrap the built module with the configured resource overlay, mirroring
        // `Patch build`, so a release ships the SAME artifact as a build of the same sources
        // (the overlay was previously dropped from `release` — it would silently ship a
        // different module than `build`+`push`). Runs before the upload below.
        if let overlaySpecURL {
            try Build.packageOverlay(specURL: overlaySpecURL, moduleURL: moduleURL)
        }
        print("")

        // Host-bridge integration (Lever #2, opt-in PATCH_HOST_BRIDGE=1) — wire the
        // generated resolver thunk into the app + install the registrar, exactly as
        // `Patch build` does. Idempotent, so a prior build's wiring is a no-op here.
        if HostBridgeProjectIntegrator.isEnabled(), let thunkURL = result.hostBridgeThunkURL {
            Build.integrateHostBridge(
                generatedFileInBuildDir: thunkURL,
                root: sourceDir, target: prepareTarget,
                routedSymbols: result.hostBridgeRoutedSymbols)
        }

        // --- 3b. Degenerate-coverage gate (BUG-4) --------------------------
        // A module can compile + pass the fingerprint gate yet carry NO real OTA
        // surface: the fallback version-probe module (only `patch_module_version`),
        // or a degenerate near-empty module (e.g. a 317-byte wasm with 1 trivial
        // unit). Shipping it silently misleads the developer into thinking a
        // meaningful patch went out. Refuse such a release by default and tell the
        // developer how to proceed if it really is intentional (`--allow-empty`).
        if !allowEmpty, let reason = result.degenerateCoverageReason(moduleSize: size) {
            throw ValidationError(
                """
                NO REAL OTA COVERAGE — refusing to release.

                  \(reason)

                This module would ship to your users without actually patching any of
                your code. That usually means the engine could not extract OTA-eligible
                logic from this build (everything demoted to native), so there is
                nothing to update on-device.

                If this is intentional (e.g. shipping a deliberate no-op / version bump),
                re-run with --allow-empty.
                """)
        }

        // --- 4. Push via the SHARED PushFlow (same gate + upload as `push`) -
        // PushFlow re-runs the same paid-rollout pre-check before uploading. The
        // entitlements round-trip already happened above (pre-build); since the
        // request is unchanged it short-circuits identically, so a legitimate
        // paid push isn't blocked twice and the common path stays round-trip-free.
        try PushFlow.run(PushFlow.Options(
            channel: channel,
            rollout: rollout,
            message: message,
            version: version,
            module: moduleURL.path,
            baseURL: baseURL,
            mandatory: mandatory,
            dryRun: dryRun,
            force: force,
            allowNativeDrift: allowNativeDrift,
            minAppVersion: minAppVersion,
            maxAppVersion: maxAppVersion,
            minOsVersion: minOsVersion,
            targetCohort: targetCohort,
            // Already pre-checked above (pre-build); don't repeat the round-trip.
            skipPaidRolloutPrecheck: true
        ))
    }

    /// Resolve the API + workspace and run the paid-rollout pre-check BEFORE the
    /// build (B3). Only called when a paid-only rollout was requested, so the
    /// common path never reaches here.
    ///
    /// Best-effort by design: if config / API key / workspace_id can't be
    /// resolved here, we DON'T fail — the build proceeds and the normal push path
    /// surfaces the same error (or the server gate decides). The only hard failure
    /// this raises is a positive "your plan can't do this" from a successful
    /// entitlements lookup, which `PushFlow.precheckPaidRollout` turns into the
    /// server's exact upgrade message.
    private func precheckPaidRolloutBeforeBuild() throws {
        var config: PatchConfig
        let configURL: URL
        do {
            (config, configURL) = try CLISupport.loadConfig()
        } catch {
            return  // No config to resolve from → let the build/push path handle it.
        }

        let api: HTTPPatchAPI
        do {
            api = try CLISupport.makeAPI(config: config, baseURLOverride: baseURL)
        } catch {
            return  // No API key → can't pre-check; fall back to the build/push path.
        }

        // Resolve workspace_id (may require a bundle_id → app lookup). If anything
        // here fails, fall back rather than block — except a genuine plan refusal,
        // which propagates from precheckPaidRollout below.
        let workspaceId: String
        do {
            _ = try CLISupport.resolveAppID(config: &config, configURL: configURL, api: api)
            workspaceId = try CLISupport.requireWorkspaceID(config)
        } catch {
            return
        }

        try PushFlow.precheckPaidRollout(
            api: api, workspaceId: workspaceId, channel: channel, rollout: rollout)
    }
}

/// `Patch ship` — DEPRECATED alias for `Patch release`.
///
/// The command was renamed (the product is patchrelease.com). This alias is kept
/// so existing scripts / CI that call `patchcli ship` keep working: it accepts the
/// exact same flags, prints a one-line deprecation notice to **stderr**, and then
/// runs the identical `Release` flow. It is hidden from the top-level `--help`
/// listing (`shouldDisplay: false`) but `patchcli ship --help` still works.
struct Ship: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ship",
        abstract: "Deprecated alias for `release` — builds then pushes in one shot.",
        shouldDisplay: false
    )

    // --- build flags (mirror Release) -------------------------------------
    @Option(name: .long, help: "Optimization: size | speed.")
    var optimization: String?

    @Option(name: .long, help: "Output .wasm path (default: .Patch/build/module.wasm).")
    var output: String?

    // --- push flags (mirror Release) --------------------------------------
    @Option(name: .long, help: "Release channel (default: production).")
    var channel: String = "production"

    @Option(name: .long, help: "Rollout percentage 0-100 (default: 100).")
    var rollout: Int = 100

    @Option(name: .shortAndLong, help: "Release notes / changelog message.")
    var message: String?

    @Option(name: .long, help: "Module version (default: timestamp-derived).")
    var version: String?

    @Option(name: .long, help: "Backend base URL override.")
    var baseURL: String?

    @Flag(name: .long, help: "Mark the update as mandatory.")
    var mandatory: Bool = false

    @Option(name: .long, help: "Only deliver to app versions ≥ this (e.g. 2.1.0). Absent = all versions.")
    var minAppVersion: String?

    @Option(name: .long, help: "Only deliver to app versions ≤ this (e.g. 3.0.0). Absent = no upper bound.")
    var maxAppVersion: String?

    @Option(name: .long, help: "Only deliver to OS versions ≥ this (e.g. 16.0). Absent = all OS versions.")
    var minOsVersion: String?

    @Option(name: .long, help: "Restrict the rollout to a named cohort/segment. Absent = all devices.")
    var targetCohort: String?

    @Flag(name: .long, help: "Build, then run all push checks + show what would be sent, but do not upload.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Upload even if the native-shell fingerprint gate reports a MISMATCH (dangerous; skips the compatibility refusal).")
    var force: Bool = false

    @Flag(name: .long, help: "Ship the patch when the native shell drifted ONLY in ways the OTA patch can't see (a package / Info.plist / entitlements / deployment-target change, with no native-source change). Refused if any change is patch-affecting.")
    var allowNativeDrift: Bool = false

    @Flag(name: .long, help: "Release even if the module has no real OTA coverage (only a version probe / a degenerate near-empty module). Off by default.")
    var allowEmpty: Bool = false

    @Flag(name: .customLong("no-prepare"),
          help: "Skip the automatic `prepare` step (don't add `dynamic`/thunks to new views before building).")
    var noPrepare: Bool = false

    func run() throws {
        // One-line deprecation notice to stderr so it never pollutes stdout that
        // scripts may parse (and so the underlying `release` output is unchanged).
        FileHandle.standardError.write(
            Data("`patchcli ship` is now `patchcli release`\n".utf8))

        // Forward every flag verbatim into the real command and run it.
        var release = Release()
        release.optimization = optimization
        release.output = output
        release.channel = channel
        release.rollout = rollout
        release.message = message
        release.version = version
        release.baseURL = baseURL
        release.mandatory = mandatory
        release.minAppVersion = minAppVersion
        release.maxAppVersion = maxAppVersion
        release.minOsVersion = minOsVersion
        release.targetCohort = targetCohort
        release.dryRun = dryRun
        release.force = force
        release.allowNativeDrift = allowNativeDrift
        release.allowEmpty = allowEmpty
        release.noPrepare = noPrepare
        try release.run()
    }
}
