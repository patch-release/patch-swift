// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler

/// `Patch rollback` — roll back the active module (or roll back to a specific
/// `--to <version>`) via the backend rollback endpoint. Takes effect within ~60s
/// (applies on the device's next update check).
struct Rollback: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Roll back to the previous module (or --to <version>)."
    )

    @Option(name: .long, help: "Release channel (default: production).")
    var channel: String = "production"

    @Option(name: .long, help: "Roll back to a specific version (rolls back everything newer first).")
    var to: String?

    @Option(name: .long, help: "Backend base URL override.")
    var baseURL: String?

    @Flag(name: .long, help: "Show what would be rolled back without calling the backend.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Output JSON.")
    var json: Bool = false

    func run() throws {
        let (config, _) = try CLISupport.loadConfig()
        let appId = try CLISupport.requireAppID(config)
        let api = try CLISupport.makeAPI(config: config, baseURLOverride: baseURL)

        let modules = try Spinner.run("Fetching modules") {
            try api.listModules(appId: appId, channel: channel)
        }
        guard let active = modules.first(where: { $0.isActive }) else {
            throw ValidationError("No active module on channel \(channel) — nothing to roll back.")
        }

        if let target = to {
            // Roll back active module(s) newer than `target` until `target` is active.
            // The backend's rollback re-activates the most recent OTHER module, so we
            // repeatedly roll back the current active until it equals `target`.
            guard modules.contains(where: { $0.version == target }) else {
                throw ValidationError("Version \(target) not found on channel \(channel).")
            }
            if active.version == target {
                print("Version \(target) is already active — nothing to do.")
                return
            }
            if dryRun {
                print("Dry run — would roll back from \(active.version) toward \(target) on \(channel).")
                return
            }
            var current = active
            var steps: [String] = []
            var guardCount = 0
            // Track which active versions we've already rolled THROUGH. If a rollback
            // doesn't change the active version (or re-activates one we've already
            // seen), we are NOT making progress toward `target` — it is unreachable by
            // rolling back (e.g. `--to` a version NEWER than active, or a backend that
            // cycles). Stop immediately rather than keep firing destructive rollbacks
            // up to the 32-step cap, each one demoting a real release.
            var seenActive: Set<String> = [current.version]
            try Spinner.run("Rolling back toward \(target)") {
                while current.version != target && guardCount < 32 {
                    guardCount += 1
                    let result = try api.rollback(moduleID: current.id)
                    steps.append(result.version)
                    let refreshed = try api.listModules(appId: appId, channel: channel)
                    guard let nowActive = refreshed.first(where: { $0.isActive }) else { break }
                    // No-progress / cycle guard: the active version didn't advance toward
                    // a NEW one, so `target` can't be reached this way. Stop.
                    if RollbackPlan.stalled(seen: &seenActive, nowActive: nowActive.version) {
                        current = nowActive
                        break
                    }
                    current = nowActive
                    if nowActive.version == target { break }
                }
            }
            if current.version != target {
                throw ValidationError(
                    "Could not reach version \(target) by rolling back on \(channel) "
                    + "(stopped at \(current.version)). Is \(target) NEWER than the active "
                    + "version? Rollback only moves to OLDER releases. Rolled back: "
                    + (steps.isEmpty ? "(none)" : steps.joined(separator: ", ")))
            }
            reportResult(to: current.version, rolledBack: steps, json: json, channel: channel)
            return
        }

        // Default: roll back the active module → previous becomes active.
        if dryRun {
            print("Dry run — would roll back active version \(active.version) on \(channel).")
            return
        }
        let (result, nowActive): (ModuleRecord, ModuleRecord?) = try Spinner.run("Rolling back") {
            let result = try api.rollback(moduleID: active.id)
            let refreshed = try api.listModules(appId: appId, channel: channel)
            return (result, refreshed.first(where: { $0.isActive }))
        }
        reportSingle(rolledBack: result, nowActive: nowActive, json: json, channel: channel)
    }

    private func reportSingle(rolledBack: ModuleRecord, nowActive: ModuleRecord?, json: Bool, channel: String) {
        if json {
            CLISupport.printJSON([
                "channel": channel,
                "rolledBack": rolledBack.version,
                "nowActive": nowActive?.version ?? NSNull(),
                "rolledBackAt": rolledBack.rolledBackAt ?? NSNull(),
            ])
            return
        }
        print("Patch rollback (\(channel))")
        print("==========================")
        print("Rolled back:   \(rolledBack.version)  (now inactive)")
        if let nowActive {
            print("Now active:    \(nowActive.version)  (rollout \(nowActive.rolloutPct)%)")
        } else {
            print("Now active:    (none — no previous version on this channel)")
        }
        print("\nTakes effect on each device's next update check.")
    }

    private func reportResult(to version: String, rolledBack: [String], json: Bool, channel: String) {
        if json {
            CLISupport.printJSON(["channel": channel, "nowActive": version, "rolledBack": rolledBack])
            return
        }
        print("Patch rollback (\(channel))")
        print("==========================")
        print("Rolled back:   \(rolledBack.joined(separator: ", "))")
        print("Now active:    \(version)")
        print("\nTakes effect on each device's next update check.")
    }
}
