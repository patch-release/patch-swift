// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler

/// `Patch status` — read the current deployment from the backend: version,
/// rollout %, device adoption, and failure rate (from module stats).
struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the current deployment: version, rollout %, adoption, failure rate."
    )

    @Option(name: .long, help: "Release channel (default: production).")
    var channel: String = "production"

    @Option(name: .long, help: "Backend base URL override.")
    var baseURL: String?

    @Flag(name: .long, help: "Output JSON.")
    var json: Bool = false

    func run() throws {
        let (config, _) = try CLISupport.loadConfig()
        let appId = try CLISupport.requireAppID(config)
        let api = try CLISupport.makeAPI(config: config, baseURLOverride: baseURL)

        let modules = try Spinner.run("Fetching deployment status") {
            try api.listModules(appId: appId, channel: channel)
        }
        let active = modules.first { $0.isActive }

        guard let active else {
            if json {
                CLISupport.printJSON(["channel": channel, "active": false, "moduleCount": modules.count])
            } else {
                print("Patch status (\(channel))")
                print("No active module on this channel (\(modules.count) total module(s)).")
            }
            return
        }

        let stats = try Spinner.run("Fetching device telemetry") {
            try api.stats(moduleID: active.id)
        }

        if json {
            var obj: [String: Any] = [
                "channel": channel,
                "version": active.version,
                "moduleId": active.id,
                "rolloutPct": active.rolloutPct,
                "mandatory": active.mandatory,
                "downloads": stats.downloads,
                "activations": stats.activations,
                "errors": stats.errors,
                "adoptionRate": stats.adoptionRate,
                "failureRate": stats.failureRate,
                "moduleCount": modules.count,
            ]
            // Echo any release targeting the backend reports (omitted when none).
            if let v = active.minAppVersion { obj["minAppVersion"] = v }
            if let v = active.maxAppVersion { obj["maxAppVersion"] = v }
            if let v = active.minOsVersion { obj["minOsVersion"] = v }
            if let v = active.targetCohort { obj["targetCohort"] = v }
            CLISupport.printJSON(obj)
            return
        }

        print("Patch status (\(channel))")
        print("=========================")
        print("Active version:   \(active.version)")
        print("Module id:        \(active.id)")
        print("Rollout:          \(active.rolloutPct)%")
        print("Mandatory:        \(active.mandatory)")
        if let targeting = active.targetingSummary {
            print("Targeting:        \(targeting)")
        }
        print("Pushed at:        \(active.pushedAt)")
        if let notes = active.releaseNotes, !notes.isEmpty {
            print("Release notes:    \(notes)")
        }
        print("")
        print("Device telemetry:")
        print("  Downloads:      \(stats.downloads)")
        print("  Activations:    \(stats.activations)")
        print("  Errors:         \(stats.errors)")
        print(String(format: "  Adoption:       %.1f%% (activations / downloads)", stats.adoptionRate * 100))
        print(String(format: "  Failure rate:   %.1f%% (errors / (activations+errors))", stats.failureRate * 100))
        if stats.failureRate > 0.02 {
            print("\n⚠ Failure rate exceeds 2% — consider `patchcli rollback`.")
        }
        if modules.count > 1 {
            print("\nOther versions on this channel:")
            for m in modules where m.id != active.id {
                print("  \(m.version)  (rollout \(m.rolloutPct)%, \(m.isActive ? "active" : "inactive"))")
            }
        }
    }
}
