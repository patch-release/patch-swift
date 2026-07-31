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
        let placeholder = CLISupport.placeholderAppKey
        let keySource: String = {
            if let env = ProcessInfo.processInfo.environment["PATCH_API_KEY"],
               !env.isEmpty, env != placeholder { return "env PATCH_API_KEY" }
            if let k = config.apiKey, !k.isEmpty, k != placeholder { return ".Patch.yml api_key" }
            if !config.appKey.isEmpty, config.appKey != placeholder { return ".Patch.yml app_key" }
            return "(none)"
        }()

        if json {
            var obj: [String: Any] = [
                "config": configURL.path,
                "project": config.project,
                "target": config.target,
                "baseURL": base,
                "apiKeyConfigured": hasKey,
                "apiKeySource": keySource,
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
        print("API key:        \(hasKey ? "configured (\(keySource))" : "NOT configured")")

        // Surface what a `push`/`release` still needs, so the developer learns the
        // gaps HERE (offline, one command) instead of hitting them one-at-a-time as
        // mid-flow errors. A pinned bundle_id can stand in for app_id/workspace_id
        // (they're resolved + cached on the first push), so it's not "missing".
        var missing: [String] = []
        if !hasKey { missing.append("app_key (or api_key) — from the dashboard") }
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
