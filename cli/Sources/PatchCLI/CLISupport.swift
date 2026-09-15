// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler

/// Shared helpers for the developer-facing commands: config resolution, API
/// client construction (with env overrides), and small printing utilities.
enum CLISupport {
    /// The default backend the brew-distributed `patchcli` CLI talks to. This MUST be
    /// the live production API, not localhost: a developer who installs via
    /// `brew install patch-release/tap/patchcli` and runs `patchcli push` without setting
    /// `api_base_url` should reach the real backend, not get a connection-refused on
    /// a dev server that isn't running. (Override with `--base-url`, `PATCH_API_URL`,
    /// or `api_base_url:` in `.Patch.yml` for self-hosted / local dev.) The
    /// `/api/v1` suffix is appended by `HTTPPatchAPI.normalizedBase`, so the bare
    /// root is correct here.
    static let defaultBaseURL = "https://api.patchrelease.com"

    /// Load `.Patch.yml` by walking up from `start` (default: CWD). Throws a
    /// friendly error if not found.
    static func loadConfig(near start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        throws -> (config: PatchConfig, url: URL) {
        guard let url = PatchConfig.find(startingAt: start) else {
            throw ValidationError(
                ".Patch.yml not found (searched from \(start.path) up to the filesystem root).\n"
                + "Run `patchcli init` in your project root first.")
        }
        let cfg = try PatchConfig.load(from: url)
        return (cfg, url)
    }

    /// The project root is the directory containing `.Patch.yml`.
    static func projectRoot(for configURL: URL) -> URL {
        configURL.deletingLastPathComponent()
    }

    /// Resolve the backend base URL: `--base-url` > env `PATCH_API_URL` >
    /// config `api_base_url` > default localhost.
    static func resolveBaseURL(_ explicit: String?, config: PatchConfig) -> String {
        explicit
            ?? ProcessInfo.processInfo.environment["PATCH_API_URL"]
            ?? config.apiBaseURL
            ?? defaultBaseURL
    }

    /// The literal placeholder `Patch init` writes for `app_key`. It is NOT a real
    /// key — treating it as one made `whoami` report "API key: configured" and made
    /// every networked command send `pak_REPLACE_ME` to the backend, producing an
    /// opaque 401 instead of a clear "set your app_key first" message.
    static let placeholderAppKey = "pak_REPLACE_ME"

    /// Prefix of the PUBLIC per-app device identifier (`app_key`). Values with
    /// this prefix are never valid publish credentials — see `resolveAPIKey`.
    static let appKeyPrefix = "pak_"

    /// Prefix of the SECRET publish token — the credential that authorizes writes.
    static let publishTokenPrefix = "ppt_"

    /// The message shown when no publish credential is configured. Names the one
    /// command that fixes it — an opaque 401 is what made `app_key` and the
    /// publish token look interchangeable in the first place.
    static let noPublishCredentialMessage = """
        No publish token found — this command changes what your users run, so it \
        needs one.

        Run `patchcli login` to get one (opens your browser, takes ~10s), or set \
        the PATCH_API_KEY env var in CI.

        Note: `app_key` is NOT a publish credential. It is a public device \
        identifier that ships inside your app binary, so the backend rejects it \
        for pushes — otherwise anyone who downloaded your app could publish code \
        to all of your users.
        """

    /// Resolve the PUBLISH credential: env `PATCH_API_KEY` > config
    /// `publish_token` > config `api_key`.
    ///
    /// It deliberately does NOT fall back to `config.appKey`. That fallback was
    /// the client half of a critical vulnerability: `app_key` is baked into the
    /// developer's app source by `init`, so it ships in every IPA, and sending it
    /// as `X-API-Key` meant a value extractable with `strings` could authorize a
    /// push to every user of the app. The backend now rejects it too, so keeping
    /// the fallback would only turn a clear error into an opaque 401.
    ///
    /// Empty strings and the `pak_REPLACE_ME` placeholder are treated as unset.
    static func resolveAPIKey(config: PatchConfig) -> String? {
        func clean(_ s: String?) -> String? {
            guard let s else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != placeholderAppKey else { return nil }
            // An app key in a publish-credential slot is never usable. Treat it as
            // unset so the caller prints the actionable message below instead of
            // sending a credential the backend is guaranteed to reject.
            guard !trimmed.hasPrefix(appKeyPrefix) else { return nil }
            return trimmed
        }
        return clean(ProcessInfo.processInfo.environment["PATCH_API_KEY"])
            ?? clean(config.publishToken)
            ?? clean(config.apiKey)
    }

    /// Build a real HTTP API client from config + env. Throws if no key resolves.
    static func makeAPI(config: PatchConfig, baseURLOverride: String? = nil) throws -> HTTPPatchAPI {
        let base = resolveBaseURL(baseURLOverride, config: config)
        guard let url = URL(string: base) else {
            throw ValidationError("Invalid backend base URL: \(base)")
        }
        guard let key = resolveAPIKey(config: config) else {
            throw ValidationError(noPublishCredentialMessage)
        }
        return HTTPPatchAPI(baseURL: url, apiKey: key)
    }

    static func requireAppID(_ config: PatchConfig) throws -> String {
        guard let id = config.appId, !id.isEmpty else {
            throw ValidationError(
                "No app_id in .Patch.yml. Add `app_id: <uuid>` (your app's backend id), "
                + "or set `bundle_id:` so it can be resolved automatically.")
        }
        return id
    }

    /// Resolve the backend `app_id` for a push/release.
    ///
    /// Precedence:
    ///   1. An explicit `app_id` already pinned in `.Patch.yml` (no network call).
    ///   2. Otherwise look the app up by `bundle_id` via `GET /api/v1/apps?bundle_id=…`.
    ///      On success the resolved `app_id` (and `workspace_id`, when absent) is
    ///      written back into `.Patch.yml` so the lookup happens at most once.
    ///
    /// `config` is updated in place (so the caller can read the resolved
    /// `workspaceId`), and the new values are persisted to `configURL`.
    static func resolveAppID(
        config: inout PatchConfig,
        configURL: URL,
        api: PatchAPI
    ) throws -> String {
        if let id = config.appId, !id.isEmpty { return id }

        guard let bundleId = config.bundleId, !bundleId.isEmpty else {
            throw ValidationError(
                "No app_id and no bundle_id in .Patch.yml.\n"
                + "Add `app_id: <uuid>` (your app's backend id), or `bundle_id: <com.acme.app>` "
                + "so the app can be looked up automatically. `patchcli init` records bundle_id "
                + "when it can read it from your Xcode project.")
        }

        guard let app = try api.lookupApp(bundleId: bundleId) else {
            throw ValidationError(
                "No app found for bundle_id `\(bundleId)` on the backend.\n"
                + "Provision the app first (POST /api/v1/apps), or set `app_id:` in .Patch.yml directly.")
        }

        // Cache the resolved identity back into config so we never look up twice.
        config.appId = app.id
        if (config.workspaceId ?? "").isEmpty, !app.workspaceId.isEmpty {
            config.workspaceId = app.workspaceId
        }
        try? config.yamlString().write(to: configURL, atomically: true, encoding: .utf8)
        print("Resolved app_id from bundle_id `\(bundleId)` → \(app.id) (cached in .Patch.yml).")
        return app.id
    }

    static func requireWorkspaceID(_ config: PatchConfig) throws -> String {
        guard let id = config.workspaceId, !id.isEmpty else {
            throw ValidationError(
                "No workspace_id in .Patch.yml. Add `workspace_id: <uuid>` before pushing.")
        }
        return id
    }

    static func printJSON(_ obj: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    }
}

// MARK: - Keeping the publish token out of version control

/// Guards against committing a live publish credential.
///
/// Before the credential split, `.Patch.yml` held only `app_key` — a PUBLIC
/// identifier that also ships inside the app binary — so committing the file was
/// harmless and nothing ever ignored it. It now also holds `publish_token`, which
/// authorizes publishing code to every user of an app. The default path
/// (`patchcli init` → `git add .`) would therefore commit a live secret, so the
/// commands that WRITE a token add the ignore rule themselves rather than only
/// advising it.
enum GitIgnoreGuard {
    static let entry = ".Patch.yml"

    /// Outcome of `ensureIgnored`, so callers can print something honest rather
    /// than claiming a protection that didn't happen.
    enum Result {
        case added(URL)
        /// Already covered by an existing rule — nothing written.
        case alreadyIgnored
        /// Not a git repository (no `.git` at `root`), so there is nothing to
        /// ignore into. Deliberately does NOT create a `.gitignore`: writing one
        /// into a non-repo is litter, and into a subdirectory of someone else's
        /// repo is worse.
        case notAGitRepo
        /// Couldn't read/write `.gitignore` — never fatal; the caller warns.
        case failed(String)
    }

    /// Read-only counterpart to `ensureIgnored`, for callers that must not write
    /// (notably `doctor`, which is contractually read-only and CI-safe).
    enum State {
        case ignored
        case notIgnored
        case notAGitRepo
        case unknown(String)
    }

    static func ignoreState(root: URL) -> State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            return .notAGitRepo
        }
        let url = root.appendingPathComponent(".gitignore")
        guard fm.fileExists(atPath: url.path) else { return .notIgnored }
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
            return .unknown("unreadable .gitignore")
        }
        return isCovered(existing) ? .ignored : .notIgnored
    }

    /// A real ignore rule for `.Patch.yml` — not a comment mentioning it, and not
    /// a `!` negation (which explicitly UN-ignores and must never read as safe).
    private static func isCovered(_ contents: String) -> Bool {
        contents.split(whereSeparator: \.isNewline).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") || t.hasPrefix("!") { return false }
            return t == entry || t == "/\(entry)" || t == "\(entry)/"
        }
    }

    /// Add `.Patch.yml` to `<root>/.gitignore` unless it is already ignored.
    ///
    /// Conservative by construction: it only ever APPENDS, never rewrites, and it
    /// preserves the file's existing trailing-newline state so the diff is one
    /// line. A `.gitignore` is often hand-curated — mangling it would be a far
    /// worse outcome than a missing entry.
    @discardableResult
    static func ensureIgnored(root: URL) -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            return .notAGitRepo
        }

        let url = root.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        // Match a real rule, not a substring: `.Patch.yml` must not be considered
        // covered by a comment mentioning it, and `!.Patch.yml` is a NEGATION
        // (explicitly un-ignoring it) which must not read as already-ignored.
        if isCovered(existing) { return .alreadyIgnored }

        let block = """
            # Holds a live publish token (ppt_…) — the credential that authorizes
            # shipping code to your users. Keep it out of version control.
            \(entry)
            """
        // Separate from whatever precedes it, without introducing a blank line
        // into a file that didn't have one.
        var addition = ""
        if !existing.isEmpty {
            if !existing.hasSuffix("\n") { addition += "\n" }
            addition += "\n"
        }
        addition += block + "\n"

        do {
            try (existing + addition).write(to: url, atomically: true, encoding: .utf8)
            return .added(url)
        } catch {
            return .failed("\(error)")
        }
    }

    /// True when git currently TRACKS `.Patch.yml` — i.e. the secret is already
    /// committed and a `.gitignore` entry alone will not help (git ignores the
    /// ignore file for paths already in the index).
    ///
    /// Best-effort: any git failure returns false rather than a false alarm.
    static func isTracked(root: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", root.path, "ls-files", "--error-unmatch", entry]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// The remediation for an ALREADY-COMMITTED config. Untracking is not enough
    /// on its own — the token is in history and must be treated as compromised.
    static let alreadyCommittedAdvice = """
        .Patch.yml is tracked by git, so your publish token is committed (and in \
        history — anyone with repo access, past or present, can read it).

          1. Revoke the token: console → Settings → CLI publish tokens → Revoke.
          2. git rm --cached .Patch.yml && git commit -m "stop tracking .Patch.yml"
          3. Run `patchcli login` for a fresh token.

        For CI, set PATCH_API_KEY as a secret instead of committing the file.
        """
}
