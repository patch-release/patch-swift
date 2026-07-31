// SPDX-License-Identifier: Apache-2.0

import Foundation
import Compiler
import CodeGenerator

/// Auto-prepare: run the SAME `Prepare.execute(...)` logic `patchcli init` uses, but
/// AUTOMATICALLY and QUIETLY before every `build`/`push`/`release`, so a developer
/// never has to remember to re-run `patchcli prepare` after adding a new view.
///
/// The developer's mental model is now just: edit Swift → `patchcli release` → shipped.
/// Adding a NEW view "just works" — auto-prepare inserts `dynamic` + generates that
/// view's `@_dynamicReplacement` thunk on the next build, idempotently (existing
/// `dynamic`/thunks are left alone, so it's a no-op once the project is prepared).
///
/// SAFETY: prepare modifies the developer's SOURCE files. This wrapper preserves the
/// existing BACKUP → write → PARSE-VERIFY → restore-on-fail discipline (it calls the
/// very same `Prepare.execute`), and on ANY failure it DEGRADES GRACEFULLY: it prints
/// a one-line warning and lets the build continue with whatever is already prepared —
/// it never aborts a release opaquely or corrupts source.
enum AutoPrepare {
    /// Whether to auto-prepare, resolved from (highest precedence first):
    ///   1. the `--no-prepare` flag (forces OFF),
    ///   2. the `PATCH_AUTO_PREPARE` env var (`0`/`false`/`no`/`off` → OFF),
    ///   3. the `.Patch.yml` `build.auto_prepare` setting (default ON when omitted).
    static func enabled(noPrepareFlag: Bool, config: PatchConfig?) -> Bool {
        if noPrepareFlag { return false }
        if let env = ProcessInfo.processInfo.environment["PATCH_AUTO_PREPARE"] {
            let v = env.trimmingCharacters(in: .whitespaces).lowercased()
            if v == "0" || v == "false" || v == "no" || v == "off" { return false }
            if v == "1" || v == "true" || v == "yes" || v == "on" { return true }
        }
        return config?.buildAutoPrepare ?? true
    }

    /// Run prepare quietly before a build, if enabled. Resolves the same project root +
    /// excludes + target the build uses (passed in by the caller). Prints a brief,
    /// friendly one-liner ONLY when it actually prepared NEW views (otherwise silent),
    /// and NEVER throws — a failure is reported as a warning and the build proceeds.
    ///
    /// - Parameters:
    ///   - root: the project root (directory of `.Patch.yml`, else the source dir).
    ///   - excludes: `.Patch.yml` `exclude:` globs (so we scan the same files prepare does).
    ///   - target: the `.Patch.yml` `target` (for product-link integration), if any.
    ///   - noPrepareFlag: the command's `--no-prepare` flag.
    ///   - config: the loaded `.Patch.yml` (nil if none) — for the `auto_prepare` setting.
    static func run(root: URL, excludes: [String], target: String?,
                    noPrepareFlag: Bool, config: PatchConfig?) {
        guard enabled(noPrepareFlag: noPrepareFlag, config: config) else { return }

        // Count how many view bodies are NOT yet `dynamic` BEFORE we run, so we can
        // report "N new view(s) prepared" precisely (and stay silent when it's a no-op).
        let newViews = countUnpreparedViews(root: root, excludes: excludes)

        do {
            // `quiet: true` → Prepare suppresses its wall of progress output; `assumeYes:
            // true` → it applies the source edits without an interactive prompt (this is
            // an automatic step in a non-interactive build). The BACKUP/verify/restore
            // discipline inside `Prepare.execute` is unchanged.
            _ = try Prepare.execute(
                root: root, excludes: excludes, target: target,
                assumeYes: true, thunksOnly: false, check: false, quiet: true)
            if newViews > 0 {
                let s = newViews == 1 ? "" : "s"
                print("✓ Views ready to patch (\(newViews) new view\(s) prepared)")
            }
            // Silent when newViews == 0 (already prepared / no SwiftUI views) — no noise.
        } catch {
            // Degrade gracefully: warn, keep going. `Prepare.execute` already restores
            // any file it touched on a parse failure, so source is never left corrupt;
            // the build proceeds against whatever was already prepared.
            FileHandle.standardError.write(Data(
                ("⚠ Auto-prepare couldn't update your views (\(error)).\n"
                 + "  Continuing the build with the views as they are. "
                 + "Run `patchcli prepare` to retry, or `--no-prepare` to skip.\n").utf8))
        }
    }

    /// How many top-level SwiftUI view bodies are NOT yet marked `dynamic` (i.e. how
    /// many NEW views prepare will add a thunk for). Best-effort + read-only; returns 0
    /// on any error so we simply stay quiet. Mirrors `prepare --check` / the doctor's
    /// `dynamicInsertions` signal.
    static func countUnpreparedViews(root: URL, excludes: [String]) -> Int {
        let sources = Prepare.swiftSources(in: root, excludes: excludes)
        guard !sources.isEmpty else { return 0 }
        let result = ThunkGenerator().prepare(sources: sources.map {
            ThunkGenerator.SourceFile(url: $0.url, text: $0.text)
        })
        return result.dynamicInsertions
    }
}
