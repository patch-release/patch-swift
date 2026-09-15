// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler
import CodeGenerator
import PartitioningEngine

/// `patchcli prepare` — make this app's SwiftUI views patchable out of the box.
///
/// Runs the build-time codegen that lets OTA patches re-render view bodies with
/// NO changes to the views themselves (no `PatchView` wrapping):
///   1. Inserts the `dynamic` keyword on every `var body: some View` (the same
///      thing Xcode Previews does — it makes the body REPLACEABLE).
///   2. Generates `PatchThunks.generated.swift` with one
///      `@_dynamicReplacement(for: body)` per View that routes the body through
///      the Patch renderer when a patch is live, else the original `body`.
///   3. Adds the generated file + the PatchSwiftUI product to the target.
///
/// Idempotent + re-runnable: existing `dynamic` keywords are left alone and the
/// thunk file is regenerated. Run it once at setup (it's also invoked by
/// `patchcli init`), and again whenever you ADD a new View (so it gets a thunk).
struct Prepare: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare",
        abstract: "Make this app's SwiftUI views patchable out of the box (dynamic-replacement thunks)."
    )

    @Argument(help: "Project directory (default: the directory of .Patch.yml, else CWD).")
    var path: String?

    @Flag(name: .customLong("yes"), help: "Apply source changes without asking.")
    var assumeYes: Bool = false

    @Flag(name: .long, help: "Only regenerate the thunk file; never edit existing sources. (For a build phase.)")
    var thunksOnly: Bool = false

    @Flag(name: .long, help: "Report views that aren't patch-ready (missing `dynamic`) and exit non-zero if any. (For CI / pre-push.)")
    var check: Bool = false

    @Flag(name: .long, help: "Less output.")
    var quiet: Bool = false

    @Flag(name: .long, help: "After preparing, BUILD the project (xcodebuild, or swift build for a package) and keep native any view whose prepared code breaks the build — repeated until the build is clean. Kept-native views are recorded under `native_views:` in .Patch.yml.")
    var verify: Bool = false

    @Option(name: .long, help: "Per-build timeout in seconds for --verify.")
    var verifyTimeout: Int = Int(PrepareVerifier.defaultTimeout)

    @Option(name: .long, help: "Also write the full per-view compatibility report (Markdown) to this path.")
    var report: String?

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // Resolve project root + target + excludes from .Patch.yml when present.
        let root: URL
        var excludes: [String] = []
        var target: String?
        if let explicit = path {
            root = URL(fileURLWithPath: explicit).standardizedFileURL
        } else if let configURL = PatchConfig.find(startingAt: cwd) {
            root = CLISupport.projectRoot(for: configURL)
            let cfg = try? PatchConfig.load(from: configURL)
            excludes = cfg?.exclude ?? []
            target = cfg?.target
        } else {
            root = cwd
        }

        _ = try Self.execute(root: root, excludes: excludes, target: target,
                             assumeYes: assumeYes, thunksOnly: thunksOnly, check: check, quiet: quiet,
                             verify: verify, verifyTimeout: TimeInterval(max(verifyTimeout, 10)),
                             reportPath: report.map { URL(fileURLWithPath: $0, relativeTo: cwd).path })
    }

    /// The prepare pipeline, callable from `patchcli init` too. Returns the number
    /// of views thunked (0 if none / nothing to do).
    @discardableResult
    static func execute(root: URL, excludes: [String], target: String?,
                        assumeYes: Bool, thunksOnly: Bool, check: Bool, quiet: Bool,
                        verify: Bool = false,
                        verifyTimeout: TimeInterval = PrepareVerifier.defaultTimeout,
                        reportPath: String? = nil) throws -> Int {
        let fm = FileManager.default
        // Views `.Patch.yml` keeps native (`native_views:` — recorded by `--verify` when a view's
        // prepared code broke the app build): no `dynamic`, no thunk. The build + fingerprint
        // read the same list, so all three agree.
        let keptNative = PatchConfig.nativeViewNames(near: root)

        // Scanning every Swift file + generating the thunks is the slow part; spin
        // while it runs. Stay silent under `quiet` (the auto-prepare path inside
        // build/push/release, which has its own output + the compile spinner).
        let scan: () throws -> (sources: [Src], result: ThunkGenerator.Result) = {
            let sources = Self.swiftSources(in: root, excludes: excludes)
            guard !sources.isEmpty else {
                throw ValidationError("No Swift sources found under \(root.path).")
            }
            // HYBRID placement (the default): separate-file thunks in a dedicated
            // gitignored generated folder for views that need no private access; same-file
            // (factored helper methods + an actionable comment) only for private-member
            // views. Keeps the developer's source files clean (just the `dynamic` keyword).
            // Only views the build target actually COMPILES get `dynamic` + a thunk (a thunk
            // for a widget/watch/macOS/package view breaks the app build). All sources still
            // feed the cross-file lowering bundle, exactly as the build lowers.
            let result = ThunkGenerator().prepare(sources: sources.map {
                ThunkGenerator.SourceFile(url: $0.url, text: $0.text)
            }, hybrid: true, nativeViews: keptNative, accessForwarding: Self.accessForwardingEnabled,
               thunkableFiles: Self.targetCompileSet(root: root, target: target, sources: sources))
            return (sources, result)
        }
        let (sources, result) = quiet
            ? try scan()
            : try Spinner.run("Scanning Swift sources for views", scan)

        if !quiet {
            print("Patch prepare")
            print("=============")
            print("Scanned:  \(sources.count) Swift file(s) under \(root.lastPathComponent)/")
            print("Views:    \(result.viewNames.count) SwiftUI view(s) — \(result.viewNames.joined(separator: ", "))")
            print("")
        }

        // Files matching `.Patch.yml` `exclude:` get no thunks — so any Patch artifacts an earlier
        // prepare left in them (a PATCH-ACCESS / PATCH-THUNKS block, prepare's `dynamic`) are stale.
        // Remove them automatically (never for `--check` / `--thunks-only`, which don't edit sources).
        if !check, !thunksOnly {
            Self.cleanExcludedFiles(root: root, excludes: excludes, quiet: quiet, assumeYes: assumeYes,
                                    sources: sources,
                                    targetCompileSet: Self.targetCompileSet(root: root, target: target, sources: sources))
        }

        guard !result.viewNames.isEmpty else {
            if !quiet { print("No top-level SwiftUI `View` structs found — nothing to prepare.") }
            return 0
        }

        // --check: report any view bodies still missing `dynamic` and exit non-zero.
        if check {
            if result.dynamicInsertions == 0 {
                print("✓ All \(result.viewNames.count) view(s) are patch-ready (`dynamic` present).")
                return result.viewNames.count
            }
            print("✗ \(result.dynamicInsertions) view bod(y/ies) are NOT patch-ready (missing `dynamic`).")
            print("  Run `patchcli prepare` to fix, then rebuild + ship.")
            throw ExitCode(2)
        }

        // HYBRID placement (the default): the bulk of every thunk lands in a dedicated,
        // gitignored `Patch/Generated/` folder so the developer's source files stay clean
        // (just the `dynamic` keyword). A view whose helpers read `private` members gets a compact
        // PATCH-ACCESS forwarder extension in its file (`PatchAccessForwarding`); only a `private`
        // View type or an unforwardable member keeps a compact same-file thunk block. Those in-file
        // edits ride `result.modifiedFiles`.
        let separateCount = result.placements.values.filter {
            if case .sameFileBecausePrivate = $0 { return false }
            return true
        }.count
        let forwardedViews = result.placements
            .compactMap { (view, placement) -> (String, [String])? in
                if case .forwardedPrivateAccess(let members) = placement { return (view, members) }
                return nil
            }
            .sorted { $0.0 < $1.0 }
        let sameFileViews = result.placements
            .compactMap { (view, placement) -> (String, [String])? in
                if case .sameFileBecausePrivate(let members) = placement { return (view, members) }
                return nil
            }
            .sorted { $0.0 < $1.0 }

        // (1) Apply source edits (insert `dynamic`, append the factored same-file helper
        // block for private-member views). `--thunks-only` suppresses these source edits
        // (it's for a build phase that only regenerates the generated folder); the
        // generated file is still written below.
        // Files the backup-verify had to RESTORE (their source edit broke parsing) — tracked
        // so their views get dropped from the generated file below (else an orphaned
        // @_dynamicReplacement over a now-non-`dynamic` body breaks the whole app build).
        var restoredFiles: [String] = []
        if !thunksOnly, !result.modifiedFiles.isEmpty {
            if !quiet {
                print("The following source files get `dynamic` added to their view `body`"
                      + (sameFileViews.isEmpty && forwardedViews.isEmpty ? " (one word each):"
                         : " (and, for views reading private members, a small PATCH-ACCESS forwarder extension):"))
                for f in result.modifiedFiles {
                    print("  • \(Self.relativePath(f.url, root: root))")
                }
                print("")
            }
            guard assumeYes || quiet || Self.confirm("Apply these edits?") else {
                print("Skipped source edits. (Re-run with --yes to apply.)")
                return 0
            }
            restoredFiles = try Self.writeSourcesWithBackupVerify(result.modifiedFiles, fm: fm)
            if !quiet, result.dynamicInsertions > 0 {
                print("✓ Added `dynamic` to \(result.dynamicInsertions) view bod(y/ies).")
            }
            // PER-FILE ISOLATION: a file whose same-file thunk block couldn't be appended
            // safely was RESTORED + SKIPPED (its view(s) stay native); the rest still got
            // their thunks. Surface it without aborting — the project is still patchable.
            if !restoredFiles.isEmpty, !quiet {
                print("⚠ Kept \(restoredFiles.count) file(s) native (their thunk block couldn't be appended "
                      + "safely; the rest are patchable): \(restoredFiles.joined(separator: ", "))")
            }
        } else if !thunksOnly, !quiet {
            print("✓ All view bodies already marked `dynamic`.")
        }

        // (2) Write the dedicated generated-folder file (the separate-file thunks + every
        // view's body-replacement) into `Patch/Generated/`, add that folder to the app's
        // `.gitignore`, and wire it into the build target (both project shapes).
        // Drop any RESTORED file's views from the generated file: their `dynamic` + same-file
        // helpers were reverted, so emitting their `@_dynamicReplacement` here would orphan a
        // now-non-`dynamic` body (and a call to a now-missing `__patchSlots`) → the whole app
        // build breaks. Re-render the generated file without those views.
        var generatedContents = result.generatedFileContents
        var restoredViews = Set<String>()
        if !restoredFiles.isEmpty, let regen = result.regenerateGeneratedFileExcluding {
            let restoredSet = Set(restoredFiles)
            restoredViews = Set(result.viewDeclaringFile
                .filter { restoredSet.contains($0.value.lastPathComponent) }
                .map { $0.key })
            if !restoredViews.isEmpty { generatedContents = regen(restoredViews) }
        }
        // Record which `dynamic` keywords prepare inserted, so `patchcli unprepare` removes only its own.
        if !thunksOnly {
            let restoredSet = Set(restoredFiles)
            PatchUninstaller.updateRecord(
                genDir: Self.generatedDirectory(for: result, sources: sources, root: root, alsoAnchorOn: keptNative),
                root: root,
                inserted: result.dynamicInsertedTypes.filter { !restoredSet.contains($0.key.lastPathComponent) },
                droppingTypes: keptNative, fm: fm)
        }
        let genURL = Self.generatedDirectory(for: result, sources: sources, root: root, alsoAnchorOn: keptNative)
            .appendingPathComponent(ThunkGenerator.thunkFileName)
        if !generatedContents.isEmpty {
            let genDir = Self.generatedDirectory(for: result, sources: Self.thunkableSources(sources, root: root, target: target),
                                                 root: root, alsoAnchorOn: keptNative)
            let genURL = genDir.appendingPathComponent(ThunkGenerator.thunkFileName)
            try fm.createDirectory(at: genDir, withIntermediateDirectories: true)
            try generatedContents.write(to: genURL, atomically: true, encoding: .utf8)
            Self.ignoreGeneratedFolder(genDir: genDir, root: root, fm: fm, quiet: quiet)
            if !quiet {
                print("✓ Generated \(Self.relativePath(genURL, root: root)) "
                      + "(\(separateCount) separate-file thunk(s) of \(result.viewNames.count)).")
                if !forwardedViews.isEmpty {
                    print("  \(forwardedViews.count) view(s) read private members — their thunks are in Patch/Generated/ too; "
                          + "each file got a compact PATCH-ACCESS forwarder extension: "
                          + forwardedViews.map { "\($0.0) [\($0.1.joined(separator: ", "))]" }.joined(separator: "; "))
                }
                if !sameFileViews.isEmpty {
                    print("  \(sameFileViews.count) view(s) kept a compact thunk block in their own file "
                          + "(\(sameFileViews.map { $0.0 }.joined(separator: ", "))) — the reason for each is in the summary below.")
                }
            }
            // Wire the generated file + the PatchSwiftUI product into the target.
            try Self.integrateIntoProject(root: root, target: target, thunkURL: genURL, fm: fm, quiet: quiet)
        } else {
            // A generated file left by an earlier run would now carry STALE replacements (for
            // views that are no longer prepared — e.g. newly kept native) → neutralize it.
            if fm.fileExists(atPath: genURL.path) {
                try? Self.emptyGeneratedFile.write(to: genURL, atomically: true, encoding: .utf8)
            }
            // No separate-file thunks (e.g. every view reads a private member). Still link
            // the product; the same-file factored blocks are in files already in the
            // compile set. Anchor on an existing view file so xcodeproj membership no-ops.
            let anchor = result.modifiedFiles.first?.url
                ?? Self.generatedDirectory(for: result, sources: sources, root: root)
            try Self.integrateIntoProject(root: root, target: target, thunkURL: anchor, fm: fm, quiet: quiet)
        }

        // (3) COMPATIBILITY SUMMARY (reporting-only — never changes lowering/thunks/fingerprint):
        // how many views are OTA-patchable vs kept native, with a one-line reason per native /
        // beside-source / partially-native view. Printed after prepare/init; `--report <path>`
        // writes the full Markdown table.
        if !quiet || reportPath != nil {
            let compat = ViewCompatibilityReport.build(from: result, sources: sources.map(\.text))
            if !quiet {
                print("")
                for line in compat.consoleLines() { print(line) }
            }
            if let reportPath {
                let url = URL(fileURLWithPath: reportPath)
                do {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try compat.markdown(projectName: root.lastPathComponent)
                        .write(to: url, atomically: true, encoding: .utf8)
                    if !quiet { print("✓ Wrote the compatibility report to \(Self.relativePath(url, root: root)).") }
                } catch {
                    FileHandle.standardError.write(Data("⚠ Couldn't write the compatibility report to \(reportPath): \(error)\n".utf8))
                }
            }
        }

        // (3) COMPILE VALIDATION (`--verify`; `init` runs it by default). Build the prepared
        // project; any view whose prepared code breaks the build is kept native (its original
        // source span restored, its thunk dropped) and the build re-run, until clean.
        var preparedCount = result.viewNames.count
        if verify, !thunksOnly, !result.viewNames.isEmpty,
           ProcessInfo.processInfo.environment["PATCH_NO_VERIFY"] != "1" {
            preparedCount = Self.verifyPreparedProject(
                root: root, target: target, sources: sources, genURL: genURL,
                preparedViews: Set(result.viewNames), keptNative: keptNative.union(restoredViews),
                timeout: verifyTimeout, quiet: quiet, fm: fm)
            // Views --verify demoted had their `dynamic` removed by Patch: forget them in the record.
            let demoted = PatchConfig.nativeViewNames(near: root).subtracting(keptNative)
            if !demoted.isEmpty {
                PatchUninstaller.updateRecord(genDir: genURL.deletingLastPathComponent(), root: root,
                                              inserted: [:], droppingTypes: demoted, fm: fm)
            }
        }

        // (4) UIKit cell patching (additive): make any declarative UIKit cell's
        // construction patchable too — insert `dynamic` on the recognized method +
        // generate the UIKit thunk file. A cell whose construction isn't the
        // recognized grammar is untouched (stays native).
        Self.prepareUIKitCells(root: root, target: target, sources: sources,
                               assumeYes: assumeYes, thunksOnly: thunksOnly, quiet: quiet, fm: fm)

        if !quiet {
            print("")
            print("Done. Your views are now patchable over-the-air:")
            print("  • Edit a view body, then `patchcli release -m \"...\"` — it renders on devices with no App Store review.")
            print("  • Re-run `patchcli prepare` after adding a NEW view so it gets a thunk.")
        }
        return preparedCount
    }

    /// The generated-folder file written when no view needs a separate-file thunk (compiles to
    /// nothing; keeps an Xcode file reference valid).
    static let emptyGeneratedFile = """
    // PatchThunks.generated.swift — GENERATED BY `patchcli prepare`. DO NOT EDIT.
    // @generated
    // No separate-file thunks right now (every view is either kept native or keeps its thunk
    // in its own file). Regenerated on every `patchcli prepare`.

    """

    // MARK: - --verify (compile validation + per-view demotion)

    /// Build the prepared project and keep native every view whose prepared code breaks the
    /// build (see `PrepareVerifier`). Rewrites the sources/generated file for each demotion round,
    /// records the demoted views in `.Patch.yml` `native_views:` (so the next prepare/build/
    /// fingerprint keep them native too) and prints which views were kept native and why.
    /// Returns the number of views still prepared.
    static func verifyPreparedProject(root: URL, target: String?, sources: [Src], genURL: URL,
                                      preparedViews: Set<String>, keptNative: Set<String>,
                                      timeout: TimeInterval, quiet: Bool, fm: FileManager) -> Int {
        guard let invocation = PrepareVerifier.detectBuild(root: root, scheme: target, fm: fm) else {
            if !quiet {
                print("")
                print("→ Skipped build verification: no .xcodeproj/.xcworkspace or Package.swift at \(root.lastPathComponent)/.")
            }
            return preparedViews.count
        }
        if !quiet {
            print("")
            print("Verifying the prepared project builds (\(invocation.label); up to \(Int(timeout))s per build — "
                  + "skip with --no-verify / PATCH_NO_VERIFY=1)…")
        }
        var buildNumber = 0
        let report = PrepareVerifier.run(
            preparedViews: preparedViews, keptNative: keptNative,
            apply: { native in Self.reapplyPrepare(sources: sources, native: native, genURL: genURL, fm: fm,
                                                   thunkableFiles: Self.targetCompileSet(root: root, target: target,
                                                                                         sources: sources)) },
            build: {
                buildNumber += 1
                let spin = quiet ? nil : Spinner("Build \(buildNumber) (\(invocation.label))")
                spin?.start()
                let outcome = PrepareVerifier.runBuild(invocation, timeout: timeout)
                spin?.clear()
                if !quiet {
                    let errs = PrepareVerifier.parseDiagnostics(outcome.log).count
                    let verdict = outcome.timedOut ? "timed out"
                        : (outcome.exitCode == 0 && errs == 0 ? "succeeded" : "failed with \(errs) error(s)")
                    print("  build \(buildNumber): \(verdict) in \(Int(outcome.seconds))s")
                }
                return outcome
            },
            readFile: { try? String(contentsOfFile: $0, encoding: .utf8) },
            progress: { if !quiet { print("  • \($0)") } })

        // Persist the demotions so every later prepare/build/fingerprint agrees.
        let demotedNames = report.demoted.map(\.view)
        var persisted = false
        if !demotedNames.isEmpty, let cfgURL = PatchConfig.find(startingAt: root),
           var cfg = try? PatchConfig.load(from: cfgURL) {
            for v in demotedNames where !cfg.nativeViews.contains(v) { cfg.nativeViews.append(v) }
            persisted = (try? cfg.yamlString().write(to: cfgURL, atomically: true, encoding: .utf8)) != nil
        }
        let finalPrepared = preparedViews.subtracting(demotedNames).count
        guard !quiet else { return finalPrepared }
        if !report.demoted.isEmpty {
            print("Kept \(report.demoted.count) view(s) native — their prepared code broke the build:")
            for (view, diags) in report.demoted {
                print("  • \(view) — \(diags.first.map { "\($0)" } ?? "build error")"
                      + (diags.count > 1 ? " (+\(diags.count - 1) more)" : ""))
            }
            print(persisted
                  ? "  Recorded under `native_views:` in .Patch.yml (remove a name to retry it with a newer patchcli)."
                  : "  (No .Patch.yml to record them in — run `patchcli init`, or they will be re-prepared next time.)")
        }
        if report.clean {
            print("✓ Verified: the prepared project builds cleanly.")
        } else if report.timedOut {
            print("⚠ Verification timed out — views left as prepared. Build in Xcode, or re-run "
                  + "`patchcli prepare --verify --verify-timeout \(Int(timeout) * 2)`.")
        } else {
            let remaining = report.preExisting + report.unattributed
            if let why = report.inconclusive { print("⚠ Verification inconclusive: \(why).") }
            if !remaining.isEmpty {
                print("⚠ The build still fails with \(remaining.count) error(s) NOT caused by Patch's changes "
                      + "(present with them removed, or outside any prepared view):")
                for d in remaining.prefix(5) { print("    \(d)") }
            }
        }
        return finalPrepared
    }

    /// Regenerate the prepared state from the ORIGINAL sources keeping `native` views native, and
    /// write every file whose on-disk text differs (so a view demoted after an earlier round gets
    /// its original source back). A file whose regenerated text would not parse is restored to
    /// its original text and its views are kept native too. Returns the views that carry a thunk.
    static func reapplyPrepare(sources: [Src], native: Set<String>, genURL: URL, fm: FileManager,
                               thunkableFiles: Set<String>? = nil) -> Set<String> {
        // The SAME target-membership filter as the initial prepare — a verify round must never
        // re-thunk a widget/package view the first pass (correctly) left alone.
        let r = ThunkGenerator().prepare(sources: sources.map {
            ThunkGenerator.SourceFile(url: $0.url, text: $0.text)
        }, hybrid: true, nativeViews: native, accessForwarding: Self.accessForwardingEnabled,
           thunkableFiles: thunkableFiles)
        var desired: [URL: String] = [:]
        for m in r.modifiedFiles { desired[m.url] = m.text }
        var broken = Set<String>()
        for src in sources {
            let want = desired[src.url] ?? src.text
            let onDisk = try? String(contentsOf: src.url, encoding: .utf8)
            guard onDisk != want else { continue }
            if want != src.text, ThunkGenerator.parses(src.text), !ThunkGenerator.parses(want) {
                try? src.text.write(to: src.url, atomically: true, encoding: .utf8)
                broken.formUnion(r.viewDeclaringFile.filter { $0.value == src.url }.map(\.key))
            } else {
                try? want.write(to: src.url, atomically: true, encoding: .utf8)
            }
        }
        if !broken.isEmpty, !broken.isSubset(of: native) {
            return reapplyPrepare(sources: sources, native: native.union(broken), genURL: genURL, fm: fm,
                                  thunkableFiles: thunkableFiles)
        }
        let gen = r.generatedFileContents.isEmpty ? Self.emptyGeneratedFile : r.generatedFileContents
        if fm.fileExists(atPath: genURL.path) || !r.generatedFileContents.isEmpty {
            try? fm.createDirectory(at: genURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? gen.write(to: genURL, atomically: true, encoding: .utf8)
        }
        return Set(r.viewNames)
    }

    /// Run the UIKit cell-patching codegen alongside the SwiftUI one: insert `dynamic`
    /// on each declarative cell's recognized construction method + write the UIKit thunk
    /// file + wire it into the target. Additive + best-effort — a project with no
    /// lowerable cells is a silent no-op. Mirrors the SwiftUI steps above.
    static func prepareUIKitCells(root: URL, target: String?, sources: [Src],
                                  assumeYes: Bool, thunksOnly: Bool, quiet: Bool, fm: FileManager) {
        let result = UIKitThunkGenerator().prepare(sources: sources.map {
            UIKitThunkGenerator.SourceFile(url: $0.url, text: $0.text)
        })
        guard !result.cellNames.isEmpty else { return }   // no lowerable cells — nothing to do.

        // PER-FILE THUNK PARSE GATE (bug R2-#96). The SwiftUI path validates EACH view's thunk
        // (`viewThunkValidates`) and demotes a non-parsing one before it can reach the build;
        // the UIKit path had NO such gate — a malformed cell thunk (a bad sender-handler call, a
        // quarantined native-effect statement that doesn't compile in the cross-file extension,
        // an out-of-scope custom-slot source) was written verbatim and ABORTED the whole app
        // build. The cell thunk renderer is internal to the engine, so we gate at the only
        // surface we own: if the generated thunk FILE doesn't PARSE, we DON'T write it (and
        // skip the `dynamic` edits + wiring) — every cell in it demotes to native, the rest of
        // the project stays patchable, and a broken file never reaches the developer's build.
        guard ThunkGenerator.parses(result.thunkFileContents) else {
            if !quiet {
                print("")
                print("⚠ Kept \(result.cellNames.count) UIKit cell(s) native — the generated cell thunk "
                      + "didn't parse cleanly, so it was NOT written (the rest of the project is still patchable).")
            }
            return
        }

        if !quiet {
            print("")
            print("UIKit cells: \(result.cellNames.count) patchable cell(s) — \(result.cellNames.joined(separator: ", "))")
        }
        // Insert `dynamic` on the construction methods (unless --thunks-only) — through the
        // SAME backup→write→parse-verify→restore-on-fail discipline as the SwiftUI source edits
        // (bug R2-#96): a `dynamic`-insertion that somehow corrupted a cell file is restored +
        // skipped, never left broken in the developer's tree.
        if !thunksOnly, !result.modifiedFiles.isEmpty {
            if assumeYes || quiet || Self.confirm("Add `dynamic` to \(result.dynamicInsertions) cell construction method(s)?") {
                let restored = (try? Self.writeSourcesWithBackupVerify(result.modifiedFiles, fm: fm)) ?? []
                if !quiet {
                    print("✓ Added `dynamic` to \(result.dynamicInsertions) cell method(s).")
                    if !restored.isEmpty {
                        print("⚠ Kept \(restored.count) cell file(s) native (their `dynamic` edit couldn't be "
                              + "applied safely): \(restored.joined(separator: ", "))")
                    }
                }
            } else if !quiet {
                print("Skipped UIKit cell edits. (Re-run with --yes to apply.)")
                return
            }
        }
        // Write the UIKit thunk file next to a cell file (in the compile set).
        let thunkDir: URL = result.modifiedFiles.first?.url.deletingLastPathComponent()
            ?? sources.first { src in result.cellNames.contains { src.text.contains("class \($0)") } }?
                .url.deletingLastPathComponent()
            ?? root
        let thunkURL = thunkDir.appendingPathComponent(UIKitThunkGenerator.thunkFileName)
        try? fm.createDirectory(at: thunkDir, withIntermediateDirectories: true)
        try? result.thunkFileContents.write(to: thunkURL, atomically: true, encoding: .utf8)
        if !quiet { print("✓ Generated \(Self.relativePath(thunkURL, root: root)) (\(result.cellNames.count) cell thunk(s)).") }

        // Wire the file + the PatchUIKit product into the target.
        Self.integrateUIKitIntoProject(root: root, target: target, thunkURL: thunkURL, fm: fm, quiet: quiet)
    }

    /// Surface how to wire the UIKit thunk file + the PatchUIKit product into the build.
    /// The thunk file is written into a cell file's directory, so SPM globs +
    /// Xcode-16 synchronized folder groups + xcodegen pick it up by LOCATION; what a
    /// dev must do is link the `PatchUIKit` product (the UIKit analogue of the
    /// PatchSwiftUI link the SwiftUI path wires). We print that instruction rather than
    /// extend the SwiftUI-specific `ProjectIntegrator` (which hardcodes PatchSwiftUI).
    /// A classic (non-synchronized) pbxproj also needs the file added to the target's
    /// Sources phase — the same one-time step the SwiftUI path documents.
    static func integrateUIKitIntoProject(root: URL, target: String?, thunkURL: URL, fm: FileManager, quiet: Bool) {
        guard !quiet else { return }
        let rel = Self.relativePath(thunkURL, root: root)
        print("→ UIKit cells need the PatchUIKit product linked: add it to the \(target ?? "app") "
              + "target (Xcode: Frameworks/SwiftPM; Package.swift: a `.product(name: \"PatchUIKit\", package: \"patch-swift\")` dep).")
        print("  (\(rel) is in the compile set by location for SPM / synchronized folder groups.)")
    }

    /// Private-access forwarding is the default; `PATCH_ACCESS_FORWARDING=0` restores the legacy
    /// same-file helper blocks (an escape hatch — the fingerprint is identical either way).
    static var accessForwardingEnabled: Bool {
        let v = ProcessInfo.processInfo.environment["PATCH_ACCESS_FORWARDING"]?.lowercased()
        return !(v == "0" || v == "false" || v == "off" || v == "no")
    }

    /// Strip Patch artifacts from files `.Patch.yml` excludes (see `execute`). Blocks always go;
    /// `dynamic` goes when the prepare record lists it, or — with no record — when the file carries
    /// a Patch block (proof prepare touched it). Parse-verified; a file that would stop parsing is
    /// left untouched.
    ///
    /// `targetCompileSet` (the build target's compile set, when known): scanned files OUTSIDE it —
    /// a widget/watch target's file, a local package, a file dropped from the project — get no
    /// thunks either, so Patch artifacts an older prepare left there (a same-file block that
    /// `import PatchSDK`s into a target that doesn't link it) are cleaned the same way.
    static func cleanExcludedFiles(root: URL, excludes: [String], quiet: Bool, assumeYes: Bool = true,
                                   sources: [Src] = [], targetCompileSet: Set<String>? = nil) {
        var candidates = excludes.isEmpty ? [] : swiftSources(in: root, excludes: [], onlyExcludedBy: excludes)
        if let targetCompileSet {
            let inTarget = Set(targetCompileSet.map(ThunkGenerator.normalizedPath))
            let seen = Set(candidates.map { $0.url.path })
            candidates += sources.filter {
                !seen.contains($0.url.path) && !inTarget.contains(ThunkGenerator.normalizedPath($0.url.path))
            }
        }
        guard !candidates.isEmpty else { return }
        let record = PatchUninstaller.loadRecord(root: root)
        var pending: [(url: URL, rel: String, text: String)] = []
        for src in candidates {
            let text = src.text
            let hasBlock = text.contains(ThunkGenerator.sameFileBeginMarker) || text.contains(PatchAccessForwarding.beginMarker)
            guard hasBlock || text.contains("dynamic var body") else { continue }
            let rel = PatchUninstaller.relativePath(src.url, root: root)
            let recorded = record.map { Set($0.dynamicInsertions[rel] ?? []) }
            let c = PatchUninstaller.cleanSource(text, dynamicTypes: recorded, hasEvidence: false, keepDynamic: false)
            guard c.text != text, !ThunkGenerator.parses(text) || ThunkGenerator.parses(c.text) else { continue }
            pending.append((src.url, rel, c.text))
        }
        guard !pending.isEmpty else { return }
        // Interactive `prepare` (no --yes) asks first, like every other source edit it makes.
        if !assumeYes, !quiet,
           !confirm("Remove stale Patch code from \(pending.count) excluded file(s) (\(pending.map { $0.rel }.joined(separator: ", ")))?") {
            return
        }
        var cleaned: [String] = []
        for p in pending where (try? p.text.write(to: p.url, atomically: true, encoding: .utf8)) != nil {
            cleaned.append(p.rel)
        }
        if !quiet, !cleaned.isEmpty {
            print("✓ Removed stale Patch code from \(cleaned.count) excluded file(s): \(cleaned.joined(separator: ", "))")
        }
    }

    // MARK: - Source discovery (mirrors the engine's swiftFiles exclusions)

    struct Src { let url: URL; let text: String }

    /// `onlyExcludedBy`: when non-nil, return ONLY the files those exclude entries match (the same
    /// substring rule `excludes` uses), after every other filter.
    static func swiftSources(in directory: URL, excludes: [String], onlyExcludedBy: [String]? = nil) -> [Src] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [Src] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            let p = url.path, lower = p.lowercased()
            if p.contains("/.build/") || p.contains("/.git/") { continue }
            if lower.contains("/.patch/") || lower.contains("/.swiftpm/") { continue }
            if SwiftParserEngine.isBuildArtifactPath(lower) { continue }  // DerivedData / SourcePackages / Pods / …
            if lower.hasSuffix(ThunkGenerator.thunkFileName.lowercased()) { continue }  // never scan our own output
            // SwiftPM manifests are tooling files, not app sources — they declare no
            // views and `import PackageDescription` would leak into the thunk's imports.
            let base = url.lastPathComponent
            if base == "Package.swift" || base.hasPrefix("Package@swift-") { continue }
            if url.lastPathComponent.hasSuffix("_wasm.swift") || url.lastPathComponent.hasSuffix("_bridge.swift") { continue }
            // SHARED test-exclusion (bug R2-#105): use the SAME predicate the build +
            // fingerprint use (`SwiftParserEngine.isTestFile` — dir-name + filename + content
            // sniff for XCTest/swift-testing) so prepare never thunks a view the build emits
            // no guest body for (which would route to a non-existent WASM body → demote).
            if SwiftParserEngine.isTestFile(url) { continue }
            if excludes.contains(where: { p.contains($0) }) { continue }
            if let only = onlyExcludedBy, !only.contains(where: { p.contains($0) }) { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append(Src(url: url, text: text))
        }
        return out.sorted { $0.url.path < $1.url.path }
    }

    /// The standardized paths of the Swift files the configured Xcode target compiles (see
    /// `XcodeTargetSources`), or nil when there's no `.xcodeproj` at `root`, no target, or the
    /// membership can't be determined — nil means "every scanned file is thunkable". Also nil
    /// when the resolved compile set shares NO file with the scanned `sources` (our reading of
    /// the project doesn't match what's on disk — keep the historical scan-everything behavior
    /// rather than silently thunk nothing).
    static func targetCompileSet(root: URL, target: String?, sources: [Src]? = nil,
                                 fm: FileManager = .default) -> Set<String>? {
        guard let target, !target.isEmpty else { return nil }
        let projects = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasSuffix(".xcodeproj") }.sorted()
        for name in projects {
            guard let files = XcodeTargetSources.swiftFiles(projectURL: root.appendingPathComponent(name),
                                                            target: target, fm: fm) else { continue }
            let scanned = sources ?? Self.swiftSources(in: root, excludes: [])
            let normalized = Set(files.map(ThunkGenerator.normalizedPath))
            guard scanned.contains(where: { normalized.contains(ThunkGenerator.normalizedPath($0.url.path)) }) else {
                return nil
            }
            return files
        }
        return nil
    }

    /// `sources` restricted to the target's compile set (all of them when undeterminable).
    static func thunkableSources(_ sources: [Src], root: URL, target: String?) -> [Src] {
        guard let set = targetCompileSet(root: root, target: target, sources: sources) else { return sources }
        let normalized = Set(set.map(ThunkGenerator.normalizedPath))
        return sources.filter { normalized.contains(ThunkGenerator.normalizedPath($0.url.path)) }
    }

    /// Where to write the thunk file: the directory of the first source that has a
    /// view (so whatever includes that file includes ours). Falls back to root.
    static func thunkDirectory(for result: ThunkGenerator.Result, sources: [Src], root: URL) -> URL {
        // Prefer a modified file's directory (definitely a view file in the target).
        if let first = result.modifiedFiles.first { return first.url.deletingLastPathComponent() }
        // Else the directory of the first source containing one of the view names.
        for src in sources {
            if result.viewNames.contains(where: { src.text.contains("struct \($0)") }) {
                return src.url.deletingLastPathComponent()
            }
        }
        return root
    }

    /// The dedicated, gitignored generated-folder NAME (a two-segment path so it reads as
    /// clearly Patch-owned in the navigator and in `.gitignore`).
    static let generatedFolderName = "Patch/Generated"

    /// Where to write the HYBRID separate-file thunks: a dedicated `Patch/Generated/`
    /// folder NESTED under a view source's directory. Nesting it under a view file's
    /// directory keeps it inside the build target's source tree, so SwiftPM target globs
    /// and Xcode-16 synchronized folder groups pick it up BY LOCATION (no per-file project
    /// surgery); a classic `.xcodeproj` gets the file wired in explicitly. Deterministic:
    /// anchored on the lexicographically-first view directory so re-runs land in the same
    /// place (idempotent regeneration). Falls back to `root`.
    static func generatedDirectory(for result: ThunkGenerator.Result, sources: [Src], root: URL,
                                   alsoAnchorOn extraViews: Set<String> = []) -> URL {
        // The directories that actually declare a thunked view (deterministic, sorted). Kept-native
        // views (`alsoAnchorOn`) anchor too, so keeping a view native never MOVES the generated
        // folder (which would orphan the old file with stale thunks).
        let anchorViews = result.viewNames + extraViews.sorted()
        var viewDirs: [URL] = []
        for src in sources where anchorViews.contains(where: { src.text.contains("struct \($0)") }) {
            let dir = src.url.deletingLastPathComponent()
            if !viewDirs.contains(dir) { viewDirs.append(dir) }
        }
        let anchor = viewDirs.sorted { $0.path < $1.path }.first
            ?? result.modifiedFiles.map { $0.url.deletingLastPathComponent() }.sorted { $0.path < $1.path }.first
            ?? root
        return anchor.appendingPathComponent(Self.generatedFolderName)
    }

    /// Ensure the dedicated generated folder is git-ignored, BOTH ways:
    ///   • Append an ignore rule for it to the project root's `.gitignore` (creating that
    ///     file if absent) — the rule a developer expects to see at the repo root.
    ///   • Write a self-contained `.gitignore` INSIDE the generated folder (`*` +
    ///     `!.gitignore`) so the whole folder is ignored even if the project root is a
    ///     different directory than `root` (a Sources-subdir checkout, a monorepo).
    /// Idempotent: never duplicates a rule it already wrote.
    static func ignoreGeneratedFolder(genDir: URL, root: URL, fm: FileManager, quiet: Bool) {
        // (a) In-folder .gitignore — ignores everything in the generated folder.
        let innerIgnore = genDir.appendingPathComponent(".gitignore")
        let innerBody = """
        # Patch-generated thunk files — recreated by `patchcli prepare`. Do not commit.
        *
        !.gitignore

        """
        try? innerBody.write(to: innerIgnore, atomically: true, encoding: .utf8)

        // (b) Root .gitignore — append a path rule for the generated folder. Resolve
        // symlinks on BOTH paths first (on macOS `/tmp` → `/private/tmp`, and
        // FileManager.enumerator hands back the resolved form, so a raw prefix check
        // against the un-resolved `root` would wrongly fall back to the bare folder name).
        let rootIgnore = root.appendingPathComponent(".gitignore")
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedGen = genDir.standardizedFileURL.resolvingSymlinksInPath().path
        let rel = resolvedGen.hasPrefix(resolvedRoot)
            ? String(resolvedGen.dropFirst(resolvedRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : Self.relativePath(genDir, root: root)
        // A trailing-slash path rule (relative to the repo root) — falls back to the bare
        // `Patch/Generated` folder name when the generated folder isn't under `root`.
        let rule = rel.isEmpty ? Self.generatedFolderName : rel
        let marker = "# Patch generated thunks (patchcli prepare)"
        let existing = (try? String(contentsOf: rootIgnore, encoding: .utf8)) ?? ""
        guard !existing.contains("\(rule)/") && !existing.contains(marker) else {
            return   // already ignored.
        }
        var updated = existing
        if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        if !updated.isEmpty { updated += "\n" }
        updated += "\(marker)\n\(rule)/\n"
        do {
            try updated.write(to: rootIgnore, atomically: true, encoding: .utf8)
            if !quiet { print("✓ Added \(rule)/ to .gitignore.") }
        } catch {
            if !quiet { print("→ Add \(rule)/ to your .gitignore (generated thunks shouldn't be committed).") }
        }
    }

    // MARK: - Project integration

    /// Wire the generated thunk file + the PatchSwiftUI product into the build.
    ///
    /// Handles the project shapes:
    ///   • SPM package (Package.swift): the file is in the target's source tree by
    ///     location; ensure the PatchSwiftUI product is a target dependency.
    ///   • Xcode project (.xcodeproj): add the file to the target's Sources phase
    ///     and link the PatchSwiftUI product (handles classic + synchronized groups).
    static func integrateIntoProject(root: URL, target: String?, thunkURL: URL, fm: FileManager, quiet: Bool) throws {
        let projects = (try? fm.contentsOfDirectory(atPath: root.path))?.filter { $0.hasSuffix(".xcodeproj") } ?? []
        let rel = Self.relativePath(thunkURL, root: root)

        if let projName = projects.first, let target {
            // ProjectIntegrator drives the pbxproj surgery (add file to Sources +
            // link PatchSwiftUI), handling classic + synchronized groups.
            do {
                switch try ProjectIntegrator.wire(projectURL: root.appendingPathComponent(projName),
                                                  target: target, fileURL: thunkURL, fm: fm) {
                case .added: if !quiet { print("✓ Added \(thunkURL.lastPathComponent) + PatchSwiftUI to target \(target).") }
                case .alreadyPresent: if !quiet { print("✓ \(thunkURL.lastPathComponent) + PatchSwiftUI already wired into \(target).") }
                }
            } catch {
                if !quiet {
                    print("→ Couldn't wire \(thunkURL.lastPathComponent) into \(projName) automatically (\(error)).")
                    print("  Add \(rel) to the \(target) target and link the PatchSwiftUI product in Xcode.")
                }
            }
            return
        }

        if fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path), let target {
            switch (try? ProjectIntegrator.wirePackage(packageDir: root, target: target, fm: fm)) ?? .alreadyPresent {
            case .added: if !quiet { print("✓ Added the PatchSwiftUI product to target \(target) in Package.swift.") }
            case .alreadyPresent: if !quiet { print("✓ PatchSwiftUI product present for target \(target).") }
            }
            return
        }

        if !quiet {
            print("→ Ensure \(rel) is compiled into your app target and the PatchSwiftUI product is linked.")
        }
    }

    // MARK: - Small helpers

    static func relativePath(_ url: URL, root: URL) -> String {
        url.path.hasPrefix(root.path)
            ? String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : url.lastPathComponent
    }

    static func confirm(_ prompt: String) -> Bool {
        guard isatty(0) == 1 else { return false }
        print("\(prompt) [Y/n] ", terminator: "")
        guard let line = readLine() else { return false }
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        return t.isEmpty || t == "y" || t == "yes"
    }

    /// Apply edited source files with BACKUP → write → PARSE-VERIFY → restore-on-fail
    /// discipline (the same guarantee `XcodeProjectEditor`/`PBXThunkIntegration` give for
    /// the pbxproj). For each file: back up the original to `<file>.patch-backup`, write
    /// the new text, then re-parse the new text. If it no longer parses (a corrupt splice),
    /// restore the original byte-for-byte — never leave a developer's source broken. On
    /// success the backup is left in place so the dev can diff/revert what `patchcli prepare`
    /// changed (matching the pbxproj editor's behavior). The verify is skipped for a file
    /// that DIDN'T parse to begin with (we don't block on pre-existing syntax issues we
    /// didn't introduce).
    ///
    /// PER-FILE ISOLATION (the meta-fix): a file that would corrupt is RESTORED and SKIPPED,
    /// and the rest are still written — `patchcli prepare` NEVER aborts the whole project
    /// because one file's same-file factored block couldn't be appended safely (the engine's
    /// per-view validation makes that case rare, but this is the always-on backstop). The
    /// names of any restored files are returned so the caller can report them; an empty
    /// return means every file was written cleanly.
    @discardableResult
    static func writeSourcesWithBackupVerify(_ files: [(url: URL, text: String)],
                                             fm: FileManager) throws -> [String] {
        let backupSuffix = "patch-backup"
        var restored: [String] = []
        for f in files {
            let original = (try? String(contentsOf: f.url, encoding: .utf8))
            let originalParsed = original.map(ThunkGenerator.parses) ?? true
            let backupURL = f.url.appendingPathExtension(backupSuffix)
            if let original {
                try? fm.removeItem(at: backupURL)
                try? original.write(to: backupURL, atomically: true, encoding: .utf8)
            }
            try? f.text.write(to: f.url, atomically: true, encoding: .utf8)
            // Only restore-and-skip if WE broke a file that parsed before — RESTORE it and
            // CONTINUE with the rest (never abort the whole prepare run for one file).
            if originalParsed, !ThunkGenerator.parses(f.text) {
                if let original {
                    try? original.write(to: f.url, atomically: true, encoding: .utf8)
                }
                restored.append(f.url.lastPathComponent)
            }
        }
        return restored
    }
}
