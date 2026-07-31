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
                             assumeYes: assumeYes, thunksOnly: thunksOnly, check: check, quiet: quiet)
    }

    /// The prepare pipeline, callable from `patchcli init` too. Returns the number
    /// of views thunked (0 if none / nothing to do).
    @discardableResult
    static func execute(root: URL, excludes: [String], target: String?,
                        assumeYes: Bool, thunksOnly: Bool, check: Bool, quiet: Bool) throws -> Int {
        let fm = FileManager.default

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
            let result = ThunkGenerator().prepare(sources: sources.map {
                ThunkGenerator.SourceFile(url: $0.url, text: $0.text)
            }, hybrid: true)
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
        // (just the `dynamic` keyword). The ONLY same-file footprint is the helper methods
        // for views whose body host-resolves a `private`/`fileprivate` member — Swift
        // access control is file-scoped, so those can't move to the generated folder. Those
        // factored blocks (+ an actionable comment naming the members) ride
        // `result.modifiedFiles` exactly like the legacy same-file path.
        let separateCount = result.placements.values.filter { $0 == .separateFile }.count
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
                      + (sameFileViews.isEmpty ? " (one word each):"
                         : " (and, for views reading a private member, a small kept-in-file helper block):"))
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
        if !restoredFiles.isEmpty, let regen = result.regenerateGeneratedFileExcluding {
            let restoredSet = Set(restoredFiles)
            let restoredViews = Set(result.viewDeclaringFile
                .filter { restoredSet.contains($0.value.lastPathComponent) }
                .map { $0.key })
            if !restoredViews.isEmpty { generatedContents = regen(restoredViews) }
        }
        if !generatedContents.isEmpty {
            let genDir = Self.generatedDirectory(for: result, sources: sources, root: root)
            let genURL = genDir.appendingPathComponent(ThunkGenerator.thunkFileName)
            try fm.createDirectory(at: genDir, withIntermediateDirectories: true)
            try generatedContents.write(to: genURL, atomically: true, encoding: .utf8)
            Self.ignoreGeneratedFolder(genDir: genDir, root: root, fm: fm, quiet: quiet)
            if !quiet {
                print("✓ Generated \(Self.relativePath(genURL, root: root)) "
                      + "(\(separateCount) separate-file thunk(s) of \(result.viewNames.count)).")
                if !sameFileViews.isEmpty {
                    print("  \(sameFileViews.count) view(s) kept a small helper block in their own file "
                          + "(they read a private member): "
                          + sameFileViews.map { "\($0.0) [\($0.1.joined(separator: ", "))]" }.joined(separator: "; "))
                    print("  Make those member(s) `internal` and re-run `patchcli prepare` to move them too.")
                }
            }
            // Wire the generated file + the PatchSwiftUI product into the target.
            try Self.integrateIntoProject(root: root, target: target, thunkURL: genURL, fm: fm, quiet: quiet)
        } else {
            // No separate-file thunks (e.g. every view reads a private member). Still link
            // the product; the same-file factored blocks are in files already in the
            // compile set. Anchor on an existing view file so xcodeproj membership no-ops.
            let anchor = result.modifiedFiles.first?.url
                ?? Self.generatedDirectory(for: result, sources: sources, root: root)
            try Self.integrateIntoProject(root: root, target: target, thunkURL: anchor, fm: fm, quiet: quiet)
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
        return result.viewNames.count
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

    // MARK: - Source discovery (mirrors the engine's swiftFiles exclusions)

    struct Src { let url: URL; let text: String }

    static func swiftSources(in directory: URL, excludes: [String]) -> [Src] {
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
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append(Src(url: url, text: text))
        }
        return out.sorted { $0.url.path < $1.url.path }
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
    static func generatedDirectory(for result: ThunkGenerator.Result, sources: [Src], root: URL) -> URL {
        // The directories that actually declare a thunked view (deterministic, sorted).
        var viewDirs: [URL] = []
        for src in sources where result.viewNames.contains(where: { src.text.contains("struct \($0)") }) {
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
