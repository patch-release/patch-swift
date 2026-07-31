// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler

/// `patchcli init` — the one-command onboarding flow.
///
/// Detects the project, writes `.Patch.yml`, then automates the rest of setup
/// end-to-end, skipping anything already done:
///
///   1. **Register the app** — opens the console's `/cli-connect` page in the
///      browser (device-code-style hand-off; see `LinkAPI.swift`), and on
///      confirm writes the delivered `app_key`/`app_id`/`workspace_id` into
///      `.Patch.yml`. No more "create the app in the dashboard and paste three
///      values".
///   2. **Add the PatchSDK Swift package** — edits `project.pbxproj` exactly
///      the way Xcode's Add Package Dependencies… does (backup + plist-verify
///      + restore-on-fail; see `XcodeProjectEditor`).
///   3. **Insert the Patch startup code** — proposes a diff adding
///      `Patch.configure(...)` to the `@main` App struct and applies it only
///      after the developer confirms (see `AppEntryInjector`).
///
/// EVERY step degrades gracefully: anything that can't be done safely (no
/// bundle id, unrecognized project shape, declined confirmation, network
/// trouble) falls back to printing the exact manual steps — so the command can
/// never leave a developer worse off than the old scaffold-and-print behavior.
/// Re-running is idempotent: done steps are detected and reported as ✓.
struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Set up this app for Patch: detect the project, register the app, add the SDK, insert startup code."
    )

    @Argument(help: "Project directory (default: current directory).")
    var path: String?

    @Option(name: .long, help: "Build target. Optional: inferred from Package.swift / .xcodeproj / source layout when omitted.")
    var target: String?

    @Option(name: .long, help: "Backend base URL to record in .Patch.yml (root or .../api/v1 — both work). Default: the live production API.")
    var baseURL: String?

    /// The production backend `init` records by default so a freshly-scaffolded
    /// project talks to the live API out of the box (not localhost). Overridable
    /// with `--base-url` for self-hosted / local dev.
    static let productionBaseURL = "https://api.patchrelease.com"

    @Flag(name: .long, help: "Overwrite an existing .Patch.yml and start fresh.")
    var force: Bool = false

    @Flag(name: .long, help: "Skip all automation (browser registration, package add, code insertion); just write .Patch.yml and print the manual steps.")
    var manual: Bool = false

    @Flag(name: .long, help: "Don't auto-open the browser for registration (the URL is printed instead).")
    var noOpen: Bool = false

    @Flag(name: .customLong("yes"), help: "Apply proposed source-code changes without asking.")
    var assumeYes: Bool = false

    @Flag(name: .long, help: "Skip adding the PatchSDK Swift package to the Xcode project.")
    var skipPackage: Bool = false

    @Flag(name: .long, help: "Skip inserting the Patch startup code into App.swift.")
    var skipCode: Bool = false

    mutating func run() throws {
        let root = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath).standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ValidationError("Project directory not found: \(root.path)")
        }

        // --- Detect the project --------------------------------------------
        let detected = ProjectDiscovery.detect(in: root, fm: fm)

        // Resolve the target: explicit --target wins; otherwise use inference.
        // [BUG-3] A multi-target SPM package must NOT dead-end here — `init`
        // only scaffolds and the target is editable, so for an ambiguous
        // multi-target package we PICK a sensible default and print a notice.
        let targetName: String
        var ambiguousNotice: String?
        if let explicit = target {
            targetName = explicit
        } else if let inferred = detected.target {
            targetName = inferred
        } else if let firstCandidate = detected.targetCandidates.first {
            targetName = firstCandidate
            let list = detected.targetCandidates.joined(separator: ", ")
            ambiguousNotice =
                "Multiple build targets found: \(list).\n"
                + "  Defaulted to `\(firstCandidate)`. If that is not the one you ship,\n"
                + "  edit `target:` in .Patch.yml or re-run `patchcli init --force --target <name>`."
        } else {
            throw ValidationError(
                "Could not determine a build target for this project.\n"
                + "Re-run with `--target <name>` to choose one.")
        }

        // Target-aware: the id must come from the APP target's build configs,
        // not whichever (test/extension) target serializes first in the pbxproj.
        let bundleId = ProjectDiscovery.bundleIdentifier(in: root, target: targetName, fm: fm)

        // --- Load-or-scaffold .Patch.yml ------------------------------------
        // An existing config (without --force) is NOT an error anymore: init is
        // re-runnable and picks up wherever setup left off (a fresh key is only
        // fetched when the config still has the placeholder).
        let configURL = root.appendingPathComponent(".Patch.yml")
        var cfg: PatchConfig
        var reusedConfig = false
        if fm.fileExists(atPath: configURL.path) && !force {
            cfg = (try? PatchConfig.load(from: configURL)) ?? Self.freshConfig(
                detected: detected, targetName: targetName, bundleId: bundleId)
            reusedConfig = true
            if cfg.bundleId == nil {
                cfg.bundleId = bundleId
            } else if let bundleId, cfg.bundleId != bundleId, !Self.isRealKey(cfg.appKey) {
                // Nothing is registered yet and discovery now disagrees with the
                // stored id (e.g. an earlier run mis-detected a test target's id)
                // — trust the fresh target-aware detection.
                cfg.bundleId = bundleId
            }
        } else {
            cfg = Self.freshConfig(detected: detected, targetName: targetName, bundleId: bundleId)
        }
        cfg.apiBaseURL = baseURL ?? cfg.apiBaseURL ?? Init.productionBaseURL
        try cfg.yamlString().write(to: configURL, atomically: true, encoding: .utf8)

        // The bundle id driving registration: project discovery when it can see
        // one (Xcode projects), else whatever the developer pinned in
        // .Patch.yml — a bare SwiftPM package has no discoverable bundle id, so
        // a hand-filled `bundle_id:` must still light up the browser flow.
        let effectiveBundleId = bundleId ?? cfg.bundleId

        // --- Report the detection -------------------------------------------
        print("Patch init")
        print("==========")
        switch detected.kind {
        case .xcodeproj: print("Detected Xcode project:   \(detected.project)")
        case .xcworkspace: print("Detected Xcode workspace: \(detected.project)")
        case .swiftPackage: print("Detected Swift package:   \(detected.project)")
        case .none: print("No .xcodeproj / .xcworkspace / Package.swift detected — wrote a template you can edit.")
        }
        let targetSource = target == nil
            ? (ambiguousNotice == nil ? " (inferred)" : " (defaulted — multiple targets)")
            : ""
        print("Target:                   \(targetName)\(targetSource)")
        if let ambiguousNotice {
            print("")
            print("Note: \(ambiguousNotice)")
        }
        if let bundleId { print("Bundle id:                \(bundleId)") }
        // Icon line is printed AFTER registration (below) so we can report
        // "✓ uploaded" vs "uploaded on push" depending on outcome. Omit here.
        print("Backend:                  \(cfg.apiBaseURL ?? Init.productionBaseURL)")
        print("\(reusedConfig ? "Updated:" : "Wrote:")                  \(configURL.path)")
        print("")

        // --- Step 1: register the app (browser hand-off) --------------------
        var manualSteps: [String] = []
        var hasRealKey = Self.isRealKey(cfg.appKey) || Self.isRealKey(cfg.apiKey ?? "")

        if hasRealKey {
            step(1, "Register your app")
            ok("Already registered — app_key is configured in .Patch.yml.")
        } else if manual {
            step(1, "Register your app")
            note("Skipped (--manual).")
            manualSteps.append(Self.manualKeyInstructions(bundleIdKnown: bundleId != nil))
        } else if effectiveBundleId == nil {
            step(1, "Register your app")
            note("No bundle id detected, so the app can't be registered automatically.")
            manualSteps.append(Self.manualKeyInstructions(bundleIdKnown: false))
        } else {
            step(1, "Register your app")
            let outcome = registerViaBrowser(cfg: &cfg, configURL: configURL,
                                             bundleId: effectiveBundleId!, appName: targetName)
            switch outcome {
            case .linked:
                hasRealKey = true
            case .fallback(let why):
                note(why)
                manualSteps.append(Self.manualKeyInstructions(bundleIdKnown: true))
            }
        }
        // --- Icon upload (best-effort, after registration) ------------------
        // Now that we have an app_id + app_key (when registration succeeded),
        // upload the icon immediately so it appears in the console BEFORE the
        // first `patchcli push`. Graceful fallback on any failure: init MUST
        // NEVER fail because of a cosmetic icon upload. If registration didn't
        // complete (no real key / no app_id), fall back to the deferred note.
        if let icon = AppIconLocator.locate(in: root, fm: fm) {
            let rel = icon.url.path.hasPrefix(root.path)
                ? String(icon.url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : icon.url.lastPathComponent
            if hasRealKey, let appId = cfg.appId, !appId.isEmpty,
               let api = try? CLISupport.makeAPI(config: cfg, baseURLOverride: baseURL) {
                // Attempt the upload — mirrors PushFlow.uploadAppIconBestEffort exactly.
                do {
                    _ = try api.uploadAppIcon(
                        appId: appId,
                        icon: icon.data,
                        fileName: icon.url.lastPathComponent,
                        mimeType: icon.mimeType)
                    print("App icon:                 ✓ uploaded \(rel) (\(icon.byteCount) bytes)")
                } catch {
                    print("App icon:                 \(rel) (\(icon.byteCount) bytes — will upload on `patchcli push`)")
                }
            } else {
                // Not registered yet — defer to push (existing behavior).
                print("App icon:                 \(rel) (\(icon.byteCount) bytes — uploaded on `patchcli push`)")
            }
        }
        print("")

        // --- Step 2: add the PatchSDK package --------------------------------
        step(2, "Add the PatchSDK Swift package")
        var packageHandled = false
        if skipPackage {
            note("Skipped (--skip-package).")
        } else if manual {
            note("Skipped (--manual).")
        } else if let projectURL = Self.xcodeprojURL(root: root, detected: detected, fm: fm) {
            do {
                switch try XcodeProjectEditor.apply(projectURL: projectURL, targetName: targetName, fm: fm) {
                case .alreadyPresent:
                    ok("PatchSDK package already added to \(projectURL.lastPathComponent).")
                    packageHandled = true
                case .added:
                    ok("Added PatchSDK to \(projectURL.lastPathComponent) (target \(targetName)).")
                    note("Backup of the original saved at project.pbxproj\(XcodeProjectEditor.backupSuffix).")
                    resolvePackages(projectURL: projectURL)
                    note("Nothing to do in Xcode — it picks the package up automatically on open/build.")
                    packageHandled = true
                }
            } catch {
                note("Couldn't add the package automatically: \(error)")
            }
        } else if detected.kind == .swiftPackage {
            do {
                switch try PackageManifestEditor.apply(packageDir: root, targetName: targetName, fm: fm) {
                case .alreadyPresent:
                    ok("PatchSDK dependency already in Package.swift.")
                    packageHandled = true
                case .added:
                    ok("Added PatchSDK to Package.swift (target \(targetName)).")
                    note("Backup of the original saved at Package.swift\(XcodeProjectEditor.backupSuffix).")
                    resolveSwiftPackage(packageDir: root)
                    packageHandled = true
                }
            } catch {
                note("Couldn't add the dependency automatically: \(error)")
            }
        } else {
            note("No .xcodeproj found to edit.")
        }
        if !packageHandled && !skipPackage {
            manualSteps.append(Self.manualPackageInstructions(kind: detected.kind))
        } else if skipPackage {
            manualSteps.append(Self.manualPackageInstructions(kind: detected.kind))
        }
        print("")

        // --- Step 3: make the app's SwiftUI views patchable ------------------
        // Insert `dynamic` on every view body + generate the replacement thunks so
        // OTA patches re-render views with NO `PatchView` wrapping. Skipped under
        // --manual (the manual steps below cover it); honors --yes for the source edits.
        // Degrades gracefully — a failure just prints the manual `prepare`.
        //
        // [P0 init↔release fingerprint divergence — the "fingerprint changed straight
        // after init" bug] Prepare MUST run BEFORE the native-shell fingerprint is computed
        // below. `patchcli release` auto-prepares, so the fingerprint it enforces is the one
        // over the PREPARED tree — the inserted `dynamic var body` line is part of the hashed
        // shell (it is only stripped for a file that ALSO carries a same-file thunk block, e.g.
        // a view reading a private member; the common view gets a separate-file thunk + a bare
        // `dynamic`, which stays in the hash). The old order computed + registered the
        // fingerprint on the UNPREPARED tree (this prepare ran AFTER), so the FIRST `release`
        // recomputed a different, prepared-tree fingerprint and false-MISMATCHED — the exact
        // failure a user hit running `init` then editing a view. Prepare first, then hash.
        step(3, "Make your SwiftUI views patchable")
        if manual {
            note("Skipped (--manual).")
            manualSteps.append(Self.manualPrepareInstructions())
        } else {
            do {
                let n = try Prepare.execute(
                    root: root, excludes: cfg.exclude, target: targetName,
                    assumeYes: assumeYes, thunksOnly: false, check: false, quiet: false)
                if n == 0 {
                    note("No top-level SwiftUI views found yet — run `patchcli prepare` after you add views.")
                }
            } catch {
                note("Couldn't prepare views automatically (\(error)).")
                manualSteps.append(Self.manualPrepareInstructions())
            }
        }
        print("")

        // --- Step 4: insert the startup code ---------------------------------
        // Inject the `Patch.configure(…)` startup call BEFORE the native-shell snapshot
        // below, so the injected boilerplate (import PatchSDK + init + configure + the
        // `Task { await Patch.shared.start() }` line) is part of the hashed shell — exactly
        // what `patchcli release` auto-prepares to and computes over. The OLD order hashed
        // BEFORE injecting, so the first release saw a different, configure-bearing shell and
        // false-MISMATCHED (the second half of the "fingerprint changed straight after init"
        // bug). The real fingerprint isn't known until the snapshot is computed over this
        // now-injected tree, so we inject a PLACEHOLDER and rebake the real value below — the
        // fingerprint VALUE is excluded from the native-shell hash (it is the hash's own
        // output), so the rebake never moves the hash.
        step(4, "Insert the Patch startup code")
        var codeHandled = false
        if skipCode {
            note("Skipped (--skip-code).")
        } else if manual {
            note("Skipped (--manual).")
        } else if !hasRealKey {
            note("Skipped — needs the app_key from step 1 first. Re-run `patchcli init` once registered.")
        } else {
            switch AppEntryInjector.propose(
                in: root, appKey: cfg.appKey, appID: cfg.appId,
                fingerprint: AppEntryInjector.pendingFingerprintPlaceholder, fm: fm
            ) {
            case .alreadyConfigured(let url):
                ok("Patch startup code already present in \(url.lastPathComponent).")
                codeHandled = true
                // The baked `fingerprint:` literal is refreshed to the CURRENT shell by the
                // rebake below — no stale-literal warning needed, we just fix it.
            case .notFound:
                note("Couldn't find a @main SwiftUI App struct to edit safely.")
            case .proposed(let injection):
                print("  Proposed change to \(injection.fileURL.lastPathComponent):")
                print("")
                for line in injection.diff.components(separatedBy: "\n") {
                    print("    \(line)")
                }
                print("")
                if confirm("  Apply this change?") {
                    do {
                        try injection.newContents.write(to: injection.fileURL, atomically: true, encoding: .utf8)
                        ok("Inserted Patch.configure(…) into \(injection.fileURL.lastPathComponent).")
                        codeHandled = true
                    } catch {
                        note("Couldn't write \(injection.fileURL.path): \(error)")
                    }
                } else {
                    note("Skipped at your request.")
                }
            }
        }
        print("")

        // Now hash the PREPARED + CONFIGURE-INJECTED native shell — the exact tree
        // `patchcli release` auto-prepares to and computes over, so the registered baseline
        // EQUALS what release enforces (no first-release false-MISMATCH). Build-confirmed (run
        // the build, hash the build-written manifest); falls back to the static snapshot
        // without the WASM toolchain (init must never require it).
        let snapshot = hasRealKey
            ? FingerprintCommand.buildConfirmedSnapshot(config: cfg, root: root, quiet: true).snapshot : nil

        // Rebake the REAL native-shell fingerprint into the configure literal so devices
        // report their exact shell for precise update gating. Hash-inert (the value is
        // excluded from the native-shell hash). Covers BOTH the fresh-inject (placeholder →
        // real) and the already-configured (stale → current) cases.
        if codeHandled, let fp = snapshot?.fingerprint {
            AppEntryInjector.rebakeFingerprint(in: root, to: fp, fm: fm)
        }
        if !codeHandled {
            manualSteps.append(Self.manualCodeInstructions(
                appKey: hasRealKey ? cfg.appKey : nil,
                appID: cfg.appId, fingerprint: snapshot?.fingerprint))
        }
        print("")

        // Auto-register the CURRENT native-shell fingerprint so the first push
        // works with no manual step. Only when the app is connected (we have an
        // app_id + key) — best-effort: if it can't (offline, or the project isn't
        // fingerprintable yet) we fall back to the manual instruction below. The
        // `patchcli fingerprint register` command stays available for re-registering
        // after a native (App Store) change.
        //
        // GUARD: register ONLY when the tree is in the EXACT state `release` will enforce —
        // every view prepared (`dynamic` inserted; `countUnpreparedViews == 0`) AND the
        // configure call injected (`codeHandled`). If the user DECLINED either edit, the
        // registered fingerprint would not match release's (which auto-prepares + sees the
        // configure call), so we skip auto-register and let the manual `fingerprint register`
        // instruction cover it once they finish the setup.
        let treePrepared = AutoPrepare.countUnpreparedViews(root: root, excludes: cfg.exclude) == 0
        var fingerprintRegistered = false
        if hasRealKey, cfg.appId != nil, codeHandled, treePrepared,
           let record = try? FingerprintCommand.registerCurrent(
               config: cfg, root: root, precomputed: snapshot) {
            fingerprintRegistered = true
            print("✓ Registered the current native-shell fingerprint (\(record.fingerprint.prefix(12))…) — OTA pushes are gated against it.")
            print("")
        }

        // --- Summary ----------------------------------------------------------
        if manualSteps.isEmpty {
            print("All set! Next steps:")
        } else {
            print("Almost there — finish these manually:")
            for (i, s) in manualSteps.enumerated() {
                print("")
                print("  \(i + 1). \(s)")
            }
            print("")
            print("Then:")
        }
        print("  • Build & run your app once to verify it starts with Patch enabled.")
        if fingerprintRegistered {
            print("  • After a NATIVE change ships via the App Store (new native code, bridges,")
            print("    or frameworks change the shell), re-register: patchcli fingerprint register")
        } else {
            print("  • Before your first push, register the native-shell fingerprint")
            print("    (required ONCE): patchcli fingerprint register")
        }
        print("  • Ship an OTA update: patchcli release -m \"first patch\"")
        print("")
        print("Tip: `patchcli whoami` shows exactly what's configured (and what's still missing).")
    }

    // MARK: - Step 1 implementation (browser hand-off)

    private enum RegisterOutcome {
        case linked
        case fallback(String)
    }

    private func registerViaBrowser(
        cfg: inout PatchConfig, configURL: URL, bundleId: String, appName: String
    ) -> RegisterOutcome {
        let base = baseURL
            ?? ProcessInfo.processInfo.environment["PATCH_API_URL"]
            ?? cfg.apiBaseURL
            ?? Init.productionBaseURL
        guard let baseURLParsed = URL(string: base) else {
            return .fallback("Invalid backend base URL: \(base)")
        }
        let api = HTTPCliLinkAPI(baseURL: baseURLParsed)
        // Immediate feedback: this round-trip can take a few seconds (TLS + a
        // cold backend instance) and used to look like a silent hang.
        print("  Contacting \(baseURLParsed.host ?? base)…")
        let session: CliLinkSession
        do {
            session = try api.createLink(bundleId: bundleId, name: appName, platform: "ios")
        } catch {
            return .fallback("Couldn't reach the Patch backend (\(error)).")
        }

        print("  Confirm this app in your browser:")
        print("")
        print("      \(session.connectURL)")
        print("")
        if !noOpen {
            Self.openInBrowser(session.connectURL)
            print("  (Opened in your default browser — if not, paste the URL above.)")
        }
        print("  Sign in (or create your free account) and click Confirm.")
        print("  Waiting for confirmation… (Ctrl-C to abort; expires in \(session.expiresInSeconds / 60) min)")

        let isTTY = isatty(1) == 1
        let outcome = CliLinkWait.wait(api: api, session: session, onPoll: { attempt in
            if isTTY && attempt % 5 == 0 {
                print("  … still waiting (\(attempt * session.pollIntervalSeconds)s)")
            }
        })

        switch outcome {
        case .linked(let app, let reused):
            cfg.appKey = app.appKey
            cfg.appId = app.id
            cfg.workspaceId = app.workspaceId
            do {
                try cfg.yamlString().write(to: configURL, atomically: true, encoding: .utf8)
            } catch {
                return .fallback("Registered, but couldn't write .Patch.yml: \(error). "
                    + "Add app_key: \(app.appKey) manually.")
            }
            if reused {
                ok("Reconnected existing app “\(app.name)” (\(app.bundleId)) — its app key is saved in .Patch.yml.")
            } else {
                ok("Registered “\(app.name)” (\(app.bundleId)) — app key saved to .Patch.yml.")
            }
            return .linked
        case .expired, .timedOut:
            return .fallback("The browser confirmation wasn't completed in time.")
        case .consumed:
            return .fallback("This link was already used. Re-run `patchcli init` for a fresh one.")
        case .failed(let message):
            return .fallback("Gave up polling after repeated errors: \(message)")
        }
    }

    /// Open a URL in the default browser (macOS `open`). Best-effort.
    static func openInBrowser(_ url: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url]
        try? p.run()
    }

    // MARK: - Step 2 helper (resolve after add)

    /// Timeout in seconds for the best-effort package-resolution subprocesses
    /// (`xcodebuild -resolvePackageDependencies` and `swift package resolve`).
    /// 60 s is generous for a warm network; the user sees a spinner + a note
    /// up front so a stall is immediately recognisable, not an apparent hang.
    static let resolveTimeoutSeconds: TimeInterval = 60

    /// Best-effort `xcodebuild -resolvePackageDependencies` so the project opens
    /// in Xcode with PatchSDK already fetched. Never fails init — Xcode resolves
    /// on open anyway. Bounded so a wedged xcodebuild can't hang onboarding.
    private func resolvePackages(projectURL: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        p.arguments = ["-resolvePackageDependencies", "-project", projectURL.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            note("Couldn't run xcodebuild (\(error)) — Xcode will resolve the package on open.")
            return
        }
        // Silent subprocess (output → /dev/null) — animate so the user knows it's
        // working. Watchdog: give resolution up to resolveTimeoutSeconds, then move on.
        note("Fetching PatchSDK from GitHub (up to \(Int(Self.resolveTimeoutSeconds))s — skip with Ctrl-C, Xcode resolves on open).")
        let spin = Spinner("Resolving package dependencies (xcodebuild)")
        spin.start()
        let deadline = Date().addingTimeInterval(Self.resolveTimeoutSeconds)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        spin.clear()
        if p.isRunning {
            Self.forceKill(p)
            note("Package resolution timed out or appears stuck — skipped.")
            note("Finish manually: open the project in Xcode → File ▸ Packages ▸ Resolve Package Versions.")
        } else if p.terminationStatus == 0 {
            ok("Package dependencies resolved.")
        } else {
            note("xcodebuild couldn't resolve dependencies (exit \(p.terminationStatus)) — Xcode will retry on open.")
        }
    }

    /// Best-effort `swift package resolve` so the package opens with PatchSDK
    /// already fetched — the SwiftPM counterpart of `resolvePackages`. Never
    /// fails init; bounded by the same watchdog.
    private func resolveSwiftPackage(packageDir: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        p.arguments = ["package", "resolve"]
        p.currentDirectoryURL = packageDir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            note("Couldn't run swift (\(error)) — dependencies will resolve on the next build.")
            return
        }
        note("Fetching PatchSDK from GitHub (up to \(Int(Self.resolveTimeoutSeconds))s — skip with Ctrl-C, resolves on next build).")
        let spin = Spinner("Resolving package dependencies (swift package resolve)")
        spin.start()
        let deadline = Date().addingTimeInterval(Self.resolveTimeoutSeconds)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        spin.clear()
        if p.isRunning {
            Self.forceKill(p)
            note("Package resolution timed out or appears stuck — skipped.")
            note("Finish manually: run  swift package resolve  in the project directory.")
        } else if p.terminationStatus == 0 {
            ok("Package dependencies resolved.")
        } else {
            note("swift package resolve exited \(p.terminationStatus) — it will retry on the next build.")
        }
    }

    /// Terminate a subprocess gracefully (SIGTERM), then force-kill (SIGKILL) if
    /// it is still running after a short grace period. Prevents wedged xcodebuild
    /// or swift subprocesses from outliving `patchcli init`.
    ///
    /// Internal (not private) so the test suite can exercise the kill path
    /// directly without going through the full `patchcli init` binary.
    static func forceKill(_ p: Process) {
        p.terminate()  // SIGTERM — polite request
        // Allow up to 2 s for a clean exit, then send SIGKILL.
        let killDeadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Small helpers

    private static func freshConfig(
        detected: ProjectDiscovery.Project, targetName: String, bundleId: String?
    ) -> PatchConfig {
        PatchConfig(
            version: 1,
            appKey: CLISupport.placeholderAppKey,
            project: detected.project,
            target: targetName,
            exclude: [],
            bridges: PatchConfig.defaultBridges,
            buildOptimization: "size",
            buildStripDebugInfo: true,
            bundleId: bundleId
        )
    }

    static func isRealKey(_ key: String) -> Bool {
        !key.isEmpty && key != CLISupport.placeholderAppKey
    }

    /// The `.xcodeproj` to edit for the SPM add: the detected project when it
    /// IS one; for a workspace, the single `.xcodeproj` sitting next to it
    /// (ambiguity → nil → manual fallback).
    static func xcodeprojURL(
        root: URL, detected: ProjectDiscovery.Project, fm: FileManager
    ) -> URL? {
        switch detected.kind {
        case .xcodeproj:
            return root.appendingPathComponent(detected.project)
        case .xcworkspace:
            let candidates = (try? fm.contentsOfDirectory(atPath: root.path))?
                .filter { $0.hasSuffix(".xcodeproj") } ?? []
            return candidates.count == 1 ? root.appendingPathComponent(candidates[0]) : nil
        case .swiftPackage, .none:
            return nil
        }
    }

    private func confirm(_ prompt: String) -> Bool {
        if assumeYes { return true }
        guard isatty(0) == 1 else {
            // Non-interactive (CI, piped) — never write source changes blind.
            return false
        }
        print("\(prompt) [Y/n] ", terminator: "")
        guard let line = readLine() else { return false }
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        return t.isEmpty || t == "y" || t == "yes"
    }

    private func step(_ n: Int, _ title: String) {
        print("[\(n)/4] \(title)")
    }
    private func ok(_ message: String) {
        print("  ✓ \(message)")
    }
    private func note(_ message: String) {
        print("  → \(message)")
    }

    // MARK: - Manual fallback texts

    static func manualKeyInstructions(bundleIdKnown: Bool) -> String {
        var s = "Register the app & get its key: open https://app.patchrelease.com (Quick Start),\n"
            + "     create the app, then copy its credentials into .Patch.yml:\n"
            + "       app_key:       <pak_… from the dashboard>   (replaces pak_REPLACE_ME)\n"
            + "       app_id:        <your app's UUID>\n"
            + "       workspace_id:  <your workspace UUID>"
        if bundleIdKnown {
            s += "\n     (bundle_id is already set, so app_id/workspace_id can also be resolved\n"
                + "      automatically on the first push — but app_key is always required.)"
        }
        return s
    }

    static func manualPackageInstructions(kind: ProjectDiscovery.Kind) -> String {
        switch kind {
        case .swiftPackage:
            return "Add the Patch SDK to Package.swift:\n"
                + "       .package(url: \"https://github.com/patch-release/patch-swift\", from: \"1.0.0\")\n"
                + "     then add the `PatchSDK` product to your target's dependencies."
        default:
            return "Add the Patch SDK in Xcode: File > Add Package Dependencies… and paste\n"
                + "       https://github.com/patch-release/patch-swift\n"
                + "     then add the `PatchSDK` product to your app target.\n"
                + "     (SwiftPM manifest equivalent: .package(url: \"https://github.com/patch-release/patch-swift\", from: \"1.0.0\"))"
        }
    }

    static func manualPrepareInstructions() -> String {
        "Make your SwiftUI views patchable (inserts `dynamic` on view bodies +\n"
            + "     generates the replacement thunks, so OTA patches re-render with no\n"
            + "     PatchView wrapping): run  patchcli prepare"
    }

    static func manualCodeInstructions(
        appKey: String?, appID: String? = nil, fingerprint: String? = nil
    ) -> String {
        let key = appKey ?? "<your pak_… app key>"
        let configure = AppEntryInjector.configureCall(
            appKey: key, appID: appID, fingerprint: fingerprint, indent: "           ")
        return "Start Patch when your app launches — in your @main App struct:\n"
            + "       import PatchSDK\n"
            + "\n"
            + "       init() {\n"
            + configure
            + "           Task { await Patch.shared.start() }\n"
            + "       }"
    }
}
