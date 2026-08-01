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
