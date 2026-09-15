// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler
import CodeGenerator

/// `patchcli unprepare` — remove everything `patchcli prepare` added to a project (and, with
/// `--remove-sdk`, what `patchcli init` added too), restoring the original sources.
///
/// Shows the plan first; applies it with `--yes` (or after confirming at a terminal). Every edit is
/// verified (Swift parse / `plutil -lint` / `swift package dump-package`) and restored on failure.
/// See `PatchUninstaller` for exactly what is and isn't touched.
struct Unprepare: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unprepare",
        abstract: "Remove Patch's generated code, view-body routes and project wiring (the inverse of `prepare`).",
        discussion: """
        Removes the PATCH-ROUTE / PATCH-ACCESS / PATCH-THUNKS blocks and the `__patchRoute { … }` view-body \
        wrappers prepare inserted (and an older CLI's `dynamic` keywords), \
        deletes Patch/Generated/ (and PatchUIKitThunks.generated.swift, .patch-backup copies), and \
        unwires the generated files + PatchSwiftUI from the Xcode project / Package.swift. \
        Add --remove-sdk to also remove the PatchSDK package and the injected Patch.configure startup code. \
        Note: auto-prepare runs inside build/push/release — pass --no-prepare there (or set \
        build.auto_prepare: false) if you want the project to stay unprepared.
        """
    )

    @Argument(help: "Project directory (default: the directory of .Patch.yml, else CWD).")
    var path: String?

    @Flag(name: .customLong("yes"), help: "Apply without asking.")
    var assumeYes: Bool = false

    @Flag(name: .long, help: "Only print what would change.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Also remove the PatchSDK package dependency and the injected `Patch.configure` code.")
    var removeSdk: Bool = false

    @Flag(name: .long, help: "Leave prepare's view-body edits (routes / legacy `dynamic` keywords) in place.")
    var keepDynamic: Bool = false

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root: URL
        if let explicit = path {
            root = URL(fileURLWithPath: explicit).standardizedFileURL
        } else if let configURL = PatchConfig.find(startingAt: cwd) {
            root = CLISupport.projectRoot(for: configURL)
        } else {
            root = cwd
        }
        let plan = PatchUninstaller.plan(root: root, options: .init(removeSDK: removeSdk, keepDynamic: keepDynamic))
        print("Patch unprepare")
        print("===============")
        if plan.isEmpty {
            print("Nothing to remove — no Patch-generated code or wiring found under \(root.lastPathComponent)/.")
            return
        }
        for e in plan.edits {
            let removed = Self.removedLineCount(e.original, e.updated)
            print("  edit    \(Prepare.relativePath(e.url, root: root))  (−\(removed) line\(removed == 1 ? "" : "s"): \(e.summary))")
        }
        for d in plan.deletions {
            print("  delete  \(Prepare.relativePath(d, root: root))")
        }
        plan.notes.forEach { print("  note: \($0)") }
        print("")
        if dryRun {
            print("Dry run — nothing changed. Re-run with --yes to apply.")
            return
        }
        guard assumeYes || Prepare.confirm("Apply these changes?") else {
            print("Nothing changed. (Re-run with --yes to apply.)")
            return
        }
        let failures = PatchUninstaller.apply(plan)
        if failures.isEmpty {
            print("✓ Removed Patch's generated code and wiring.")
        } else {
            failures.forEach { print("⚠ \($0)") }
            throw ExitCode(1)
        }
        print("  Your native shell changed: rebuild the app (and `patchcli fingerprint register` if you re-prepare later).")
        print("  build/push/release auto-prepare again unless you pass --no-prepare.")
    }

    static func removedLineCount(_ a: String, _ b: String) -> Int {
        max(0, a.components(separatedBy: "\n").count - b.components(separatedBy: "\n").count)
    }
}
