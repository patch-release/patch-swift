// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler

/// `Patch push` (Track F2) — upload the built `.wasm` (+ metadata) to the backend
/// `POST /api/v1/modules` (multipart), gated on a fingerprint-compatibility check
/// FIRST. If the locally-computed native-shell fingerprint does not match the
/// backend's active fingerprint, the push is refused with an actionable message
/// (ship via the App Store + re-register), per the plan.
///
/// The fingerprint-gate + upload logic lives in `PushFlow` so that `Patch release`
/// (build → push in one shot) reuses the EXACT same code and HTTP client — no
/// duplication of the network layer.
struct Push: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Upload the built .wasm to the backend (gated on fingerprint compatibility). Track F2."
    )

    @Option(name: .long, help: "Release channel (default: production).")
    var channel: String = "production"

    @Option(name: .long, help: "Rollout percentage 0-100 (default: 100).")
    var rollout: Int = 100

    @Option(name: .long, help: "Release notes / changelog message.")
    var message: String?

    @Option(name: .long, help: "Module version (default: timestamp-derived).")
    var version: String?

    @Option(name: .long, help: "Path to the .wasm to push (default: .Patch/build/module.wasm).")
    var module: String?

    @Option(name: .long, help: "Backend base URL override.")
    var baseURL: String?

    @Flag(name: .long, help: "Mark the update as mandatory.")
    var mandatory: Bool = false

    @Option(name: .long, help: "Only deliver to app versions ≥ this (e.g. 2.1.0). Absent = all versions.")
    var minAppVersion: String?

    @Option(name: .long, help: "Only deliver to app versions ≤ this (e.g. 3.0.0). Absent = no upper bound.")
    var maxAppVersion: String?

    @Option(name: .long, help: "Only deliver to OS versions ≥ this (e.g. 16.0). Absent = all OS versions.")
    var minOsVersion: String?

    @Option(name: .long, help: "Restrict the rollout to a named cohort/segment. Absent = all devices.")
    var targetCohort: String?

    @Flag(name: .long, help: "Run all checks + show what would be sent, but do not upload.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Upload even if the native-shell fingerprint gate reports a MISMATCH (dangerous; skips the compatibility refusal).")
    var force: Bool = false

    @Flag(name: .long, help: "Ship the patch when the native shell drifted ONLY in ways the OTA patch can't see (a package / Info.plist / entitlements / deployment-target change, with no native-source change). Refused if any change is patch-affecting. The non-interactive form of the native-drift prompt.")
    var allowNativeDrift: Bool = false

    @Flag(name: .customLong("no-prepare"),
          help: "Skip the automatic `prepare` step (don't add `dynamic`/thunks to new views before pushing).")
    var noPrepare: Bool = false

    func run() throws {
        // Auto-prepare: make any NEW SwiftUI views patchable (insert `dynamic` + thunks)
        // so the next build picks them up — the developer never needs `patchcli prepare`.
        // Idempotent + quiet (silent when nothing's new); degrades gracefully on failure.
        // (When `release` runs, it preps once before building and ships via PushFlow
        // directly, so this never double-runs.)
        if let configURL = PatchConfig.find(
            startingAt: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)),
           let cfg = try? PatchConfig.load(from: configURL) {
            let root = CLISupport.projectRoot(for: configURL)
            AutoPrepare.run(root: root, excludes: cfg.exclude,
                            target: cfg.target.isEmpty ? nil : cfg.target,
                            noPrepareFlag: noPrepare, config: cfg)
        }

        try PushFlow.run(PushFlow.Options(
            channel: channel,
            rollout: rollout,
            message: message,
            version: version,
            module: module,
            baseURL: baseURL,
            mandatory: mandatory,
            dryRun: dryRun,
            force: force,
            allowNativeDrift: allowNativeDrift,
            minAppVersion: minAppVersion,
            maxAppVersion: maxAppVersion,
            minOsVersion: minOsVersion,
            targetCohort: targetCohort
        ))
    }
}
