// SPDX-License-Identifier: Apache-2.0

// HostBridgeProjectIntegrator.swift — LEVER #2, the `prepare`-side wiring that
// joins the engine-generated host-bridge resolver thunk into the developer's app
// so the generalized "call what's already linked" bridge works with ZERO manual
// steps (`HostBridgeLowering` produces the file; this installs it).
//
// It does the two things `prepare` does for the SwiftUI thunk, mirrored exactly:
//
//   1. ADD THE GENERATED FILE TO THE APP TARGET. `HostBridgeLowering` writes
//      `PatchHostBridges.generated.swift` (the App-Store-clean, compiled-in
//      dispatch table). This file must be compiled INTO the app target, and the
//      `PatchSDK`/`PatchHostBridge` product (a sibling of the `patch-swift`
//      package the SwiftUI/SDK integration already links) must be a dependency.
//      Reuses the SAME project-shape machinery the SwiftUI thunk uses:
//        • `PBXThunkIntegration` low-level helpers (synchronized-group detection,
//          `fileAlreadyInTarget`, `addSourceFile`) for the pbxproj file membership
//          (classic groups get an explicit ref+build file; Xcode-16 synchronized
//          root groups auto-include by location, so we add NOTHING for the file),
//        • `XcodeProjectEditor.addPackage` / `PackageManifestEditor.addPackage`
//          for the `PatchSDK` product link (idempotent — `Patch.configure`
//          injection already links it, so this is normally `.alreadyPresent`),
//      each with the existing BACKUP → write → VERIFY (plutil-lint / dump-package)
//      → RESTORE-ON-FAIL safety. NEVER corrupts the developer's project.
//
//   2. INJECT THE ONE-TIME REGISTRAR INSTALL into the `@main` app entry, exactly
//      like `AppEntryInjector` injects `Patch.configure`. The SDK exposes
//      `Patch.shared.onRegisterHostBridges(__patchRegisterHostBridges)` — the app
//      installs the generated registrar once at configure. We insert that single
//      line right after the `Patch.configure(…)` call (the registrar must run
//      at/after configure, before `start()`), with a diff preview, idempotency
//      (skip if already present), and a printed-manual-steps fallback.
//
// DISCIPLINE — ADDITIVE + DEMOTE-SAFE + IDEMPOTENT + OPT-IN. Gated behind the
// SAME `PATCH_HOST_BRIDGE=1` flag the lowering uses (default OFF): with the flag
// off, `prepare` does nothing host-bridge-related and the project is byte-
// identical to today. A re-run is a no-op (file already a member, product already
// linked, registrar line already present). Any shape it can't edit with certainty
// falls back to a printed instruction — it never writes a guess.

import Foundation
import CodeGenerator

public enum HostBridgeProjectIntegrator {

    public enum Outcome: Sendable, Equatable { case added, alreadyPresent, notFound }

    /// The generated resolver-thunk file name (`HostBridgeLowering` writes it).
    public static var generatedFileName: String { HostBridgeThunkGenerator.fileName }
    /// The function the generated file declares + the app installs once.
    public static var registerFunctionName: String { HostBridgeThunkGenerator.registerFunctionName }

    /// The one-time install line injected into the app entry (after `Patch.configure`).
    public static var registrarInstallCall: String {
        "Patch.shared.onRegisterHostBridges(\(registerFunctionName))"
    }

    /// The env switch (default OFF) — the SAME one `HostBridgeLowering` gates on.
    public static func isEnabled(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["PATCH_HOST_BRIDGE"] == "1"
    }

    // =========================================================================
    // MARK: - (1) File → app target
    // =========================================================================

    /// Add the generated resolver-thunk file to `target`'s Sources phase (classic
    /// groups) — or rely on auto-inclusion (synchronized groups) — and ensure the
    /// `PatchSDK` product is linked. Mirrors `PBXThunkIntegration.wire`'s backup →
    /// write → plutil-lint → restore-on-fail, reusing its low-level helpers so the
    /// project-shape matrix (classic vs synchronized) is handled identically.
    public static func wireFile(
        projectURL: URL, target: String, fileURL: URL, fm: FileManager
    ) throws -> Outcome {
        let pbxprojURL = projectURL.appendingPathComponent("project.pbxproj")
        guard let original = try? String(contentsOf: pbxprojURL, encoding: .utf8) else {
            throw ProjectIntegrator.IntegratorError.unsupported("Could not read \(pbxprojURL.path).")
        }
        let (outcome, edited) = try transformFile(
            pbxproj: original, projectURL: projectURL, target: target, fileURL: fileURL, fm: fm)
        guard outcome == .added else { return outcome }

        let backupURL = pbxprojURL.appendingPathExtension(
            String(XcodeProjectEditor.backupSuffix.dropFirst()))
        try? fm.removeItem(at: backupURL)
        try original.write(to: backupURL, atomically: true, encoding: .utf8)
        try edited.write(to: pbxprojURL, atomically: true, encoding: .utf8)

        if let lintError = XcodeProjectEditor.plutilLint(pbxprojURL) {
            try? original.write(to: pbxprojURL, atomically: true, encoding: .utf8)
            throw ProjectIntegrator.IntegratorError.unsupported(
                "Edited project.pbxproj failed plist validation (restored the original): \(lintError)")
        }
        return .added
    }

    /// Pure transform: add the generated file to `target`'s Sources phase (or
    /// no-op for a synchronized group / when already a member) and ensure the
    /// `PatchSDK` product link. Returns `.alreadyPresent` (text unchanged) when
    /// both are in place. Throws `.unsupported` for any shape it can't edit.
    static func transformFile(
        pbxproj: String, projectURL: URL, target: String, fileURL: URL, fm: FileManager
    ) throws -> (Outcome, String) {
        guard pbxproj.hasPrefix("// !$*UTF8*$!") else {
            throw ProjectIntegrator.IntegratorError.unsupported(
                "project.pbxproj is not in the OpenStep plist format Xcode writes "
                + "(unexpected header) — wire the file in Xcode instead.")
        }
        guard let targetRange = XcodeProjectEditor.nativeTargetBlockRange(in: pbxproj, targetName: target) else {
            throw ProjectIntegrator.IntegratorError.unsupported(
                "Could not find target `\(target)` in project.pbxproj — wire the file in Xcode instead.")
        }
        let targetBlock = String(pbxproj[targetRange])

        var text = pbxproj
        var didChange = false

        // ---- The generated source file (classic vs synchronized) -------------
        // A synchronized root group whose folder on disk contains the file
        // auto-includes it; adding an explicit ref would double-compile it.
        let autoIncluded = PBXThunkIntegration.fileIsInSynchronizedGroup(
            of: targetBlock, pbxproj: text, projectURL: projectURL, fileURL: fileURL, fm: fm)
        if autoIncluded {
            // Nothing to add for the file.
        } else if PBXThunkIntegration.fileAlreadyInTarget(
            text, targetBlock: targetBlock, fileURL: fileURL, projectURL: projectURL) {
            // Already an explicit member of this target's Sources phase.
        } else {
            text = try PBXThunkIntegration.addSourceFile(
                to: text, target: target, fileURL: fileURL, projectURL: projectURL)
            didChange = true
        }

        // ---- The PatchSDK product link ---------------------------------------
        // The generated file `import PatchSDK` / `import PatchHostBridge` (both
        // products of the `patch-swift` package). `XcodeProjectEditor.addPackage`
        // links `PatchSDK` and is idempotent (it returns `.alreadyPresent` when
        // patch-swift is already referenced — the usual case, since `Patch.configure`
        // injection links it first).
        let (linkResult, linked) = try XcodeProjectEditor.addPackage(to: text, targetName: target)
        if linkResult == .added {
            text = linked
            didChange = true
        }

        return (didChange ? .added : .alreadyPresent, text)
    }

    /// Ensure a SwiftPM `target` depends on the `PatchSDK` product (the generated
    /// file is in the target's source tree by LOCATION for SwiftPM globs, so only
    /// the product link is needed). Reuses `PackageManifestEditor.apply`'s backup
    /// → dump-package verify → restore-on-fail.
    public static func wirePackage(packageDir: URL, target: String, fm: FileManager) throws -> Outcome {
        switch try PackageManifestEditor.apply(packageDir: packageDir, targetName: target, fm: fm) {
        case .added: return .added
        case .alreadyPresent: return .alreadyPresent
        }
    }

    // =========================================================================
    // MARK: - (2) Registrar install → app entry
    // =========================================================================

    public struct RegistrarInjection: Sendable, Equatable {
        public let fileURL: URL
        public let newContents: String
        /// A human-readable preview (insertion-only diff) of exactly what changes.
        public let diff: String
    }

    public enum RegistrarOutcome: Sendable, Equatable {
        case proposed(RegistrarInjection)
        /// The sources already install the registrar — nothing to do.
        case alreadyInstalled(in: URL)
        /// No recognizable `Patch.configure(…)` call to anchor on — the caller
        /// prints the manual one-liner.
        case notFound
    }

    /// Find the app entry that calls `Patch.configure(…)` and propose inserting the
    /// one-time registrar install right after it. Read-only — writing is the
    /// caller's decision (diff + confirm), exactly like `AppEntryInjector.propose`.
    public static func proposeRegistrar(in root: URL, fm: FileManager = .default) -> RegistrarOutcome {
        let candidates = AppEntryInjector.swiftFiles(in: root, fm: fm)
        // Already installed anywhere in the app's sources → done.
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains("onRegisterHostBridges(") { return .alreadyInstalled(in: url) }
        }
        // Anchor on the `Patch.configure(…)` call the app injection placed (the
        // registrar must run at/after configure). Prefer the same file.
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("Patch.configure(") else { continue }
            if let newText = injectRegistrar(into: text) {
                return .proposed(RegistrarInjection(
                    fileURL: url,
                    newContents: newText,
                    diff: AppEntryInjector.insertionDiff(
                        old: text, new: newText, path: url.lastPathComponent)))
            }
        }
        return .notFound
    }

    /// Pure transform (internal for tests): insert the registrar install line
    /// immediately after the LAST line of the `Patch.configure(…)` call, at the
    /// same indentation. Returns nil when there's no `Patch.configure(…)` to
    /// anchor on, and the SOURCE UNCHANGED-signalling nil when it's already there.
    static func injectRegistrar(into source: String) -> String? {
        if source.contains("onRegisterHostBridges(") { return nil }  // idempotent
        // Locate the `Patch.configure(` call and the matching close paren of its
        // argument list — depth-aware so the multi-line full form (one arg per
        // line) is handled as well as the one-line key-only form.
        guard let callStart = source.range(of: "Patch.configure(") else { return nil }
        guard let afterCall = matchingCloseParenEnd(in: source, openParenAfter: callStart.upperBound) else {
            return nil
        }
        // The configure STATEMENT ends at the end of the line containing that close
        // paren (skip a trailing `)` chain — `Patch.configure(.init(...))` — by
        // walking to the line break).
        var lineEnd = afterCall
        while lineEnd < source.endIndex, source[lineEnd] != "\n" { lineEnd = source.index(after: lineEnd) }

        // The indentation of the configure call's first line — re-used so the
        // injected line lines up with `Patch.configure`.
        let indent = leadingWhitespaceOfLine(containing: callStart.lowerBound, in: source)

        var text = source
        let insertion = "\n" + indent + registrarInstallCall
        text.insert(contentsOf: insertion, at: lineEnd)
        return text
    }

    /// The end index just AFTER the `)` that closes the argument list opened at
    /// `openParenAfter` (the index right after `Patch.configure(`). String- and
    /// comment-naive but depth-correct for parens — Swift call argument lists.
    static func matchingCloseParenEnd(in s: String, openParenAfter start: String.Index) -> String.Index? {
        var depth = 1
        var inString = false
        var prev: Character = " "
        var i = start
        while i < s.endIndex {
            let ch = s[i]
            if inString {
                if ch == "\"" && prev != "\\" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { return s.index(after: i) }
                default: break
                }
            }
            prev = ch
            i = s.index(after: i)
        }
        return nil
    }

    /// The leading whitespace of the line containing `idx`.
    static func leadingWhitespaceOfLine(containing idx: String.Index, in s: String) -> String {
        var lineStart = idx
        while lineStart > s.startIndex, s[s.index(before: lineStart)] != "\n" {
            lineStart = s.index(before: lineStart)
        }
        var ws = ""
        var i = lineStart
        while i < s.endIndex, s[i] == " " || s[i] == "\t" {
            ws.append(s[i]); i = s.index(after: i)
        }
        return ws
    }

    /// Write a proposed registrar injection to disk with BACKUP → write →
    /// restore-on-fail safety (mirrors `AppEntryInjector`'s caller posture). The
    /// backup is left in place on success so the dev can diff/revert.
    public static func applyRegistrar(_ injection: RegistrarInjection, fm: FileManager = .default) throws {
        let original = try? String(contentsOf: injection.fileURL, encoding: .utf8)
        let backupURL = injection.fileURL.appendingPathExtension(
            String(XcodeProjectEditor.backupSuffix.dropFirst()))
        if let original {
            try? fm.removeItem(at: backupURL)
            try original.write(to: backupURL, atomically: true, encoding: .utf8)
        }
        try injection.newContents.write(to: injection.fileURL, atomically: true, encoding: .utf8)
    }
}
