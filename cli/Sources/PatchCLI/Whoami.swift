// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler

/// `Patch whoami` — print the configured identity from `.Patch.yml`: app_id,
/// workspace_id, the resolved backend base URL, the default channel, and whether
/// an API key is configured (the key itself is NOT printed). Purely local — no
/// network call — so it works offline for quick "what am I pointed at?" checks.
struct Whoami: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whoami",
        abstract: "Print the configured app_id / workspace_id / base URL / channel from .Patch.yml."
    )

    @Option(name: .long, help: "Backend base URL override (to preview what would be used).")
    var baseURL: String?

    @Flag(name: .long, help: "Output JSON.")
    var json: Bool = false

    func run() throws {
        let (config, configURL) = try CLISupport.loadConfig()
        let base = CLISupport.resolveBaseURL(baseURL, config: config)
        let hasKey = CLISupport.resolveAPIKey(config: config) != nil
        // Mask the key for display: show only the source. Mirror resolveAPIKey's
        // precedence AND its placeholder/empty filtering, so we never report a
        // source for the unset `pak_REPLACE_ME` placeholder (hasKey would be false).
        // NOTE `app_key` is deliberately NOT a source here: it is a public device
        // identifier that ships inside the app binary, and the backend rejects it
        // as a publish credential. Reporting it as "configured" is what made the
        // two credentials look interchangeable.
        let placeholder = CLISupport.placeholderAppKey
        func usable(_ value: String?) -> Bool {
            guard let value else { return false }
            let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && t != placeholder && !t.hasPrefix(CLISupport.appKeyPrefix)
        }
        let keySource: String = {
            if usable(ProcessInfo.processInfo.environment["PATCH_API_KEY"]) { return "env PATCH_API_KEY" }
            if usable(config.publishToken) { return ".Patch.yml publish_token" }
            if usable(config.apiKey) { return ".Patch.yml api_key" }
            return "(none)"
        }()

        if json {
            var obj: [String: Any] = [
                "config": configURL.path,
                "project": config.project,
                "target": config.target,
                "baseURL": base,
                "publishTokenConfigured": hasKey,
                "publishTokenSource": keySource,
                "appKeyConfigured": Init.isRealKey(config.appKey),
            ]
            if let id = config.appId { obj["appId"] = id }
            if let ws = config.workspaceId { obj["workspaceId"] = ws }
            CLISupport.printJSON(obj)
            return
        }

        print("Patch whoami")
        print("============")
        print("Config file:    \(configURL.path)")
        print("Project:        \(config.project.isEmpty ? "—" : config.project)")
        print("Target:         \(config.target.isEmpty ? "—" : config.target)")
        print("App id:         \(config.appId ?? "(not set — add app_id: <uuid>)")")
        print("Workspace id:   \(config.workspaceId ?? "(not set — add workspace_id: <uuid>)")")
        print("Base URL:       \(base)")
        print("Publish token:  \(hasKey ? "configured (\(keySource))" : "NOT configured")")
        print("App key:        \(Init.isRealKey(config.appKey) ? "set (public — ships in your app)" : "not set")")

        // Surface what a `push`/`release` still needs, so the developer learns the
        // gaps HERE (offline, one command) instead of hitting them one-at-a-time as
        // mid-flow errors. A pinned bundle_id can stand in for app_id/workspace_id
        // (they're resolved + cached on the first push), so it's not "missing".
        var missing: [String] = []
        if !hasKey { missing.append("a publish token — run `patchcli login`") }
        let haveBundle = !(config.bundleId ?? "").isEmpty
        if (config.appId ?? "").isEmpty && !haveBundle {
            missing.append("app_id (or bundle_id, to resolve it automatically)")
        }
        if (config.workspaceId ?? "").isEmpty && !haveBundle {
            missing.append("workspace_id (or bundle_id, to resolve it automatically)")
        }
        if missing.isEmpty {
            print("\nReady to push. ✓")
        } else {
            print("\nStill needed before `patchcli push`:")
            for m in missing { print("  - \(m)") }
        }
    }
}
