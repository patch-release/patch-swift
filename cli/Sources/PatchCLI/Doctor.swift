// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler
import CodeGenerator
import PartitioningEngine

/// `patchcli doctor` — a one-shot setup/health preflight.
///
/// Diagnoses, in one command, exactly what's configured for OTA patching and
/// what's missing, with a one-line fix hint per failing/warning check. It is
/// strictly READ-ONLY — doctor never mutates the project (unlike `init` /
/// `prepare`), so it's safe to run anytime, in CI, or on someone else's machine.
///
/// The checks (each reported ✓ / ✗ / ⚠ with a fix hint pointing at the right
/// command), reusing the SAME helpers `init`/`prepare`/`fingerprint` use so the
/// diagnosis matches what those commands actually do:
///   1. `.Patch.yml` present + valid (has `app_key` (pak_…); `app_id` recommended).
///   2. PatchSDK package added to the project (xcodeproj OR Package.swift) and
///      linked into the target.
///   3. `Patch.configure(...)` + `Patch.shared.start()` in the `@main` App entry
///      (import PatchSDK).
///   4. Views are patch-ready — bodies marked `dynamic` + thunks. (A ⚠, not a ✗:
///      `build`/`push`/`release` auto-run prepare, so this self-heals on next release.)
///   5. Fingerprint registered AND the current native-shell fingerprint matches
///      it (needs network to check the registration; degrades to a ⚠ offline).
///   6. Summary: "N/M checks passed" + READY / NEEDS SETUP, exit non-zero on any
///      hard ✗ (so it's CI-usable, like `prepare --check`).
struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Preflight: check (read-only) that this project is set up for OTA patches, with a fix hint per gap."
    )

    @Argument(help: "Project directory (default: the directory of .Patch.yml, else CWD).")
    var path: String?

    @Option(name: .long, help: "Backend base URL override (for the fingerprint check).")
    var baseURL: String?

    @Flag(name: .long, help: "Skip every network call (the fingerprint-registration check degrades to a warning).")
    var offline: Bool = false

    @Flag(name: .long, help: "Output JSON (machine-readable).")
    var json: Bool = false

    // MARK: - Check model

    enum Status: String {
        case pass    // ✓ — configured correctly
        case warn    // ⚠ — works, but worth fixing (non-fatal)
        case fail    // ✗ — a hard gap that blocks OTA patching (fatal → non-zero exit)

        var glyph: String {
            switch self {
            case .pass: return "✓"
            case .warn: return "⚠"
            case .fail: return "✗"
            }
        }
    }

    struct Check {
        let id: String        // stable key for --json
        let title: String     // one-line headline
        let status: Status
        let detail: String?   // optional context line(s)
        let fix: String?      // one-line fix hint (command to run), for ✗/⚠

        var passed: Bool { status == .pass }
    }

    // MARK: - run

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // Resolve the project root + config. We do NOT use CLISupport.loadConfig()
        // here because a MISSING .Patch.yml is itself check #1 (a diagnosis, not a
        // hard error) — doctor must keep going and report the remaining gaps.
        let root: URL
        var configURL: URL?
        if let explicit = path {
            root = URL(fileURLWithPath: explicit).standardizedFileURL
            let candidate = root.appendingPathComponent(".Patch.yml")
            configURL = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        } else if let found = PatchConfig.find(startingAt: cwd) {
            configURL = found
            root = CLISupport.projectRoot(for: found)
        } else {
            root = cwd
            configURL = nil
        }

        // The checks scan the whole source tree, hash the native shell, and (online)
        // hit the backend — all silent. Spin while they run, then print the report.
        let checks: [Check] = Spinner.run("Running preflight checks") {
            var checks: [Check] = []

            // 1) .Patch.yml present + valid.
            let (configCheck, config) = checkConfig(configURL: configURL)
            checks.append(configCheck)

            // 2) PatchSDK package added + linked.
            checks.append(checkPackage(root: root, target: config?.target))

            // 3) Patch.configure + start() in @main App entry.
            checks.append(checkConfigureCall(root: root))

            // 4) prepare has been run (views dynamic + thunks).
            checks.append(checkPrepared(root: root, config: config))

            // 5) Fingerprint registered + current.
            checks.append(checkFingerprint(root: root, config: config))
            return checks
        }

        report(checks)

        // CI-usable exit code: non-zero if ANY hard ✗.
        if checks.contains(where: { $0.status == .fail }) {
            throw ExitCode(2)
        }
    }

    // MARK: - Check 1: .Patch.yml

    /// Returns the check AND the parsed config (nil if absent/malformed) so the
    /// later checks can reuse it (target name, app_id, bridges, excludes).
    func checkConfig(configURL: URL?) -> (Check, PatchConfig?) {
        guard let configURL else {
            return (Check(
                id: "config",
                title: ".Patch.yml present + valid",
                status: .fail,
                detail: "No .Patch.yml found (searched up to the filesystem root).",
                fix: "Run `patchcli init` in your project root to create it."
            ), nil)
        }

        let config: PatchConfig
        do {
            config = try PatchConfig.load(from: configURL)
        } catch {
            return (Check(
                id: "config",
                title: ".Patch.yml present + valid",
                status: .fail,
                detail: "Found \(configURL.path) but it could not be parsed: \(error).",
                fix: "Fix the YAML by hand, or re-run `patchcli init`."
            ), nil)
        }

        let key = CLISupport.resolveAPIKey(config: config)   // nil for empty / pak_REPLACE_ME placeholder
        let hasAppId = !(config.appId ?? "").isEmpty
        let hasBundle = !(config.bundleId ?? "").isEmpty

        if key == nil {
            return (Check(
                id: "config",
                title: ".Patch.yml present + valid",
                status: .fail,
                detail: "Found \(configURL.path) but `app_key` is not set (still the placeholder, empty, or missing).",
                fix: "Add your `app_key: pak_…` (from the dashboard) to .Patch.yml, or re-run `patchcli init`."
            ), config)
        }

        // app_id missing is a WARN (a bundle_id resolves it on first push; without
        // either, push/release can't reach the backend).
        if !hasAppId {
            let detail = hasBundle
                ? "app_key set; app_id absent but `bundle_id` is present (resolved + cached on first push)."
                : "app_key set; app_id absent (and no bundle_id to resolve it from)."
            return (Check(
                id: "config",
                title: ".Patch.yml present + valid",
                status: .warn,
                detail: detail,
                fix: hasBundle
                    ? "OK to proceed; `patchcli push` will resolve + cache `app_id` from bundle_id."
                    : "Add `app_id: <uuid>` (or `bundle_id:`) to .Patch.yml so push/release can reach the backend."
            ), config)
        }

        return (Check(
            id: "config",
            title: ".Patch.yml present + valid",
            status: .pass,
            detail: "app_key set; app_id \(config.appId!).",
            fix: nil
        ), config)
    }

    // MARK: - Check 2: PatchSDK package added + linked

    func checkPackage(root: URL, target: String?) -> Check {
        let fm = FileManager.default
        let id = "package"
        let title = "PatchSDK package added to the project"

        // Xcode project: scan project.pbxproj for the patch-swift package reference
        // and the PatchSDK product link. Same signals the XcodeProjectEditor uses to
        // decide `.alreadyPresent`.
        let xcodeprojs = (try? fm.contentsOfDirectory(atPath: root.path))?
            .filter { $0.hasSuffix(".xcodeproj") } ?? []
        if let projName = xcodeprojs.first {
            let pbxURL = root.appendingPathComponent(projName).appendingPathComponent("project.pbxproj")
            guard let pbx = try? String(contentsOf: pbxURL, encoding: .utf8) else {
                return Check(id: id, title: title, status: .fail,
                             detail: "Found \(projName) but couldn't read its project.pbxproj.",
                             fix: "Run `patchcli init` (or add the PatchSDK package in Xcode).")
            }
            let hasRef = pbx.contains(XcodeProjectEditor.packageURL)
                || pbx.contains("patch-release/patch-swift")
            if !hasRef {
                return Check(id: id, title: title, status: .fail,
                             detail: "\(projName) does not reference the patch-swift package.",
                             fix: "Run `patchcli init` to add the PatchSDK SwiftPM package (or add it in Xcode).")
            }
            // The product link (a PBXBuildFile for PatchSDK) — present when wired to a target.
            let hasProductLink = pbx.contains(XcodeProjectEditor.productName)
            if !hasProductLink {
                return Check(id: id, title: title, status: .warn,
                             detail: "\(projName) references patch-swift but the \(XcodeProjectEditor.productName) product isn't linked into a target.",
                             fix: "Run `patchcli init`, or link the PatchSDK product to \(target ?? "your app target") in Xcode (Frameworks/SwiftPM).")
            }
            return Check(id: id, title: title, status: .pass,
                         detail: "\(projName) references patch-swift and links the PatchSDK product.",
                         fix: nil)
        }

        // SwiftPM package: scan Package.swift for the patch-swift dependency + the
        // PatchSDK product dependency. Same signals PackageManifestEditor uses.
        let pkgURL = root.appendingPathComponent("Package.swift")
        if fm.fileExists(atPath: pkgURL.path) {
            guard let manifest = try? String(contentsOf: pkgURL, encoding: .utf8) else {
                return Check(id: id, title: title, status: .fail,
                             detail: "Found Package.swift but couldn't read it.",
                             fix: "Run `patchcli init` (or add the patch-swift dependency by hand).")
            }
            let hasDep = manifest.contains("patch-release/patch-swift")
            if !hasDep {
                return Check(id: id, title: title, status: .fail,
                             detail: "Package.swift does not depend on patch-swift.",
                             fix: "Run `patchcli init` to add the patch-swift dependency (or add it by hand).")
            }
            // A target must actually USE the PatchSDK product, not just declare the dep.
            let hasProduct = manifest.contains("\"\(XcodeProjectEditor.productName)\"")
                || manifest.contains("PatchSDK")
            if !hasProduct {
                return Check(id: id, title: title, status: .warn,
                             detail: "Package.swift depends on patch-swift but no target lists the PatchSDK product.",
                             fix: "Add `.product(name: \"PatchSDK\", package: \"patch-swift\")` to your target's dependencies (or re-run `patchcli init`).")
            }
            return Check(id: id, title: title, status: .pass,
                         detail: "Package.swift depends on patch-swift and uses the PatchSDK product.",
                         fix: nil)
        }

        return Check(id: id, title: title, status: .fail,
                     detail: "No .xcodeproj or Package.swift found at \(root.path) — can't verify the PatchSDK dependency.",
                     fix: "Run `patchcli doctor` from your app's project root, or `patchcli init` to set it up.")
    }

    // MARK: - Check 3: Patch.configure + start() in the @main App entry

    func checkConfigureCall(root: URL) -> Check {
        let id = "configure"
        let title = "Patch.configure(...) + start() in the @main App entry"

        // Reuse the SAME finder init uses: AppEntryInjector.propose returns
        // `.alreadyConfigured` when `Patch.configure(` is present anywhere in the
        // app's sources, `.proposed` when there's a @main App entry but no configure
        // yet, and `.notFound` when there's no recognizable SwiftUI @main entry.
        // (The appKey value is irrelevant here — we only read the outcome.)
        let outcome = AppEntryInjector.propose(in: root, appKey: "pak_unused")
        switch outcome {
        case .alreadyConfigured(let url):
            // Confirm the rest of the integration (start() + the import) is present
            // for a precise diagnosis — a configure with no start() never updates.
            let hasStart = sourcesContain(root: root, needle: "Patch.shared.start(")
            let hasImport = sourcesContain(root: root, needle: "import PatchSDK")
            if hasStart && hasImport {
                return Check(id: id, title: title, status: .pass,
                             detail: "Patch.configure(...) + Patch.shared.start() + import PatchSDK found (\(url.lastPathComponent)).",
                             fix: nil)
            }
            var missing: [String] = []
            if !hasImport { missing.append("`import PatchSDK`") }
            if !hasStart { missing.append("`Patch.shared.start()`") }
            return Check(id: id, title: title, status: .warn,
                         detail: "Patch.configure(...) is present but \(missing.joined(separator: " and ")) is missing — patches won't be fetched/applied.",
                         fix: "Add a `Task { await Patch.shared.start() }` (and `import PatchSDK`) in your @main App's init, or re-run `patchcli init`.")
        case .proposed:
            return Check(id: id, title: title, status: .fail,
                         detail: "Found a @main App entry but no Patch.configure(...) call.",
                         fix: "Run `patchcli init` to inject Patch.configure + Patch.shared.start() into your App entry.")
        case .notFound:
            // No recognizable @main SwiftUI App. Could be a UIKit AppDelegate app —
            // still need configure somewhere. Degrade to a warning (we can't be sure).
            let hasConfigure = sourcesContain(root: root, needle: "Patch.configure(")
            if hasConfigure {
                return Check(id: id, title: title, status: .pass,
                             detail: "Patch.configure(...) found (no SwiftUI @main App entry — likely a UIKit app).",
                             fix: nil)
            }
            return Check(id: id, title: title, status: .warn,
                         detail: "No SwiftUI @main App entry found and no Patch.configure(...) call located (UIKit AppDelegate app, or sources elsewhere).",
                         fix: "Call `Patch.configure(.init(appKey:))` + `Patch.shared.start()` once at launch (AppDelegate `didFinishLaunching`), or run `patchcli init`.")
        }
    }

    // MARK: - Check 4: prepare has been run (views dynamic + thunks)

    func checkPrepared(root: URL, config: PatchConfig?) -> Check {
        let id = "prepare"
        let title = "`patchcli prepare` has been run (views patchable)"

        // Reuse the SAME scan + ThunkGenerator prepare logic `patchcli prepare` uses.
        let excludes = config?.exclude ?? []
        let sources = Prepare.swiftSources(in: root, excludes: excludes)
        guard !sources.isEmpty else {
            return Check(id: id, title: title, status: .warn,
                         detail: "No Swift sources found under \(root.lastPathComponent)/ to scan for views.",
                         fix: "Run `patchcli doctor` from your app's project root.")
        }

        let result = ThunkGenerator().prepare(sources: sources.map {
            ThunkGenerator.SourceFile(url: $0.url, text: $0.text)
        })

        guard !result.viewNames.isEmpty else {
            // No SwiftUI views at all — prepare is a no-op, not a failure.
            return Check(id: id, title: title, status: .warn,
                         detail: "No top-level SwiftUI `View` structs found — nothing to prepare (UIKit-only app, or views elsewhere).",
                         fix: "If this app has SwiftUI views, run `patchcli prepare`; otherwise OK.")
        }

        // `dynamicInsertions` is the count of view bodies that are NOT yet `dynamic`
        // (i.e. prepare WOULD add the keyword) — mirrors `prepare --check`.
        //
        // This is a ⚠ (info), NOT a blocking ✗: `patchcli build`/`push`/`release` now
        // auto-run prepare before building, so an un-prepared view is fixed on the next
        // release with no manual step. We surface it so a CI gate (`prepare --check`) can
        // still catch it, but doctor must not report a hard failure that contradicts the
        // auto-prepare reality.
        if result.dynamicInsertions > 0 {
            return Check(id: id, title: title, status: .warn,
                         detail: "\(result.dynamicInsertions) of \(result.viewNames.count) view bod(y/ies) aren't marked `dynamic` yet — prepare runs automatically on your next `patchcli release`.",
                         fix: "Nothing needed — `patchcli build`/`push`/`release` auto-prepare these. (Run `patchcli prepare` now, or `patchcli prepare --check` in CI, if you prefer.)")
        }

        // Bodies are all `dynamic`. Now confirm the generated thunk blocks actually
        // exist on disk (prepare's same-file thunks carry a BEGIN marker; the legacy
        // mode writes PatchThunks.generated.swift). If `dynamic` is present but no
        // thunk block is, the prepare run was incomplete.
        let hasThunkBlock = sourcesContain(root: root, needle: ThunkGenerator.sameFileBeginMarker)
            || FileManager.default.fileExists(atPath:
                Prepare.thunkDirectory(for: result, sources: sources, root: root)
                    .appendingPathComponent(ThunkGenerator.thunkFileName).path)
            || anyFileNamed(ThunkGenerator.thunkFileName, under: root)
        if !hasThunkBlock {
            return Check(id: id, title: title, status: .warn,
                         detail: "All \(result.viewNames.count) view bod(y/ies) are `dynamic` but no generated thunk block was found.",
                         fix: "Run `patchcli prepare` to (re)generate the dynamic-replacement thunks.")
        }

        return Check(id: id, title: title, status: .pass,
                     detail: "\(result.viewNames.count) SwiftUI view(s) are `dynamic` + have generated thunks.",
                     fix: nil)
    }

    // MARK: - Check 5: fingerprint registered + current

    func checkFingerprint(root: URL, config: PatchConfig?) -> Check {
        let id = "fingerprint"
        let title = "Native-shell fingerprint registered + current"

        guard let config else {
            return Check(id: id, title: title, status: .warn,
                         detail: "Can't compute a fingerprint without a valid .Patch.yml.",
                         fix: "Fix .Patch.yml (check #1) first, then run `patchcli fingerprint register`.")
        }

        // Compute the CURRENT native-shell fingerprint locally (no network) — the
        // SAME computation `fingerprint diff`/`register` use.
        let snapshot = FingerprintCommand.computeSnapshot(config: config, root: root)
        let current = snapshot.fingerprint

        // Offline / no app_id / no key → can't fetch the registration. Report the
        // computed fingerprint and degrade to a ⚠ (we can't confirm it's registered).
        let hasAppId = !(config.appId ?? "").isEmpty
        let hasKey = CLISupport.resolveAPIKey(config: config) != nil
        if offline || !hasAppId || !hasKey {
            let why = offline ? "(--offline)"
                : (!hasAppId ? "(no app_id in .Patch.yml)" : "(no app_key configured)")
            return Check(id: id, title: title, status: .warn,
                         detail: "Computed current fingerprint \(shortFP(current)) \(why); couldn't check the registered one.",
                         fix: "Run `patchcli fingerprint register` after your next App Store build so OTA pushes are gated.")
        }

        // Query the backend for the active registration (best-effort — a network
        // failure is a ⚠, not a hard ✗, since doctor stays useful offline-ish).
        let registered: FingerprintRecord?
        do {
            let api = try CLISupport.makeAPI(config: config, baseURLOverride: baseURL)
            registered = try api.getActiveFingerprint(appId: config.appId!)
        } catch {
            return Check(id: id, title: title, status: .warn,
                         detail: "Computed current fingerprint \(shortFP(current)); backend check failed: \(error).",
                         fix: "Retry online, or `patchcli fingerprint diff` to inspect. (Pass --offline to skip this check.)")
        }

        guard let registered else {
            return Check(id: id, title: title, status: .warn,
                         detail: "No fingerprint registered on the backend for this app (current is \(shortFP(current))).",
                         fix: "Run `patchcli fingerprint register` after your next App Store build.")
        }

        if registered.fingerprint == current {
            return Check(id: id, title: title, status: .pass,
                         detail: "Registered fingerprint matches the current native shell (\(shortFP(current))).",
                         fix: nil)
        }
        return Check(id: id, title: title, status: .warn,
                     detail: "Registered fingerprint \(shortFP(registered.fingerprint)) != current \(shortFP(current)) — the native shell drifted since the last registration.",
                     fix: "After shipping the native change via the App Store, run `patchcli fingerprint register`. (Use `patchcli fingerprint diff` to see what changed.)")
    }

    // MARK: - Reporting

    func report(_ checks: [Check]) {
        let passed = checks.filter(\.passed).count
        let total = checks.count
        let hardFails = checks.filter { $0.status == .fail }.count

        if json {
            let obj: [String: Any] = [
                "checks": checks.map { c -> [String: Any] in
                    var o: [String: Any] = ["id": c.id, "title": c.title, "status": c.status.rawValue]
                    if let d = c.detail { o["detail"] = d }
                    if let f = c.fix { o["fix"] = f }
                    return o
                },
                "passed": passed,
                "total": total,
                "ready": hardFails == 0,
            ]
            CLISupport.printJSON(obj)
            return
        }

        print("Patch doctor")
        print("============")
        print("")
        for c in checks {
            print("\(c.status.glyph) \(c.title)")
            if let d = c.detail { print("    \(d)") }
            if c.status != .pass, let f = c.fix { print("    → fix: \(f)") }
        }
        print("")
        print("\(passed)/\(total) checks passed.")
        if hardFails == 0 {
            print("READY — this project is set up for OTA patches. ✓")
            if passed < total {
                print("(The ⚠ items above are non-fatal but worth addressing.)")
            }
        } else {
            print("NEEDS SETUP — \(hardFails) blocking issue(s). Address the ✗ items above, then re-run `patchcli doctor`.")
        }
    }

    // MARK: - Small helpers

    /// First N chars of a fingerprint for readable output.
    func shortFP(_ s: String) -> String {
        s.count > 12 ? String(s.prefix(12)) + "…" : s
    }

    /// Does any app source under `root` contain `needle`? Reuses the SAME bounded,
    /// build-artifact-skipping source scan `patchcli prepare` uses (which already
    /// excludes .build/Pods/DerivedData/tests/etc).
    func sourcesContain(root: URL, needle: String) -> Bool {
        for src in Prepare.swiftSources(in: root, excludes: []) {
            if src.text.contains(needle) { return true }
        }
        return false
    }

    /// Is there any file named `name` anywhere under `root` (bounded walk)?
    func anyFileNamed(_ name: String, under root: URL) -> Bool {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        var visited = 0
        for case let url as URL in en {
            visited += 1
            if visited > 8000 { break }
            let p = url.path.lowercased()
            if p.contains("/.build/") || p.contains("/.git/") { continue }
            if url.lastPathComponent == name { return true }
        }
        return false
    }
}
