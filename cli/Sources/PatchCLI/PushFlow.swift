// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler

/// Shared push pipeline used by BOTH `Patch push` and `Patch release`.
///
/// Encapsulates the fingerprint-compatibility gate (BEFORE upload) and the
/// multipart upload to `POST /api/v1/modules`, so the two commands share ONE
/// implementation and ONE HTTP client (`HTTPPatchAPI`). Neither command
/// duplicates the network code — they both call `PushFlow.run(...)`.
enum PushFlow {
    /// Inputs for a push, deliberately mirroring the `push` flag set so `release`
    /// can forward its push flags straight through.
    struct Options {
        var channel: String
        var rollout: Int
        var message: String?
        var version: String?
        /// Explicit module path; when nil, defaults to `.Patch/build/module.wasm`.
        var module: String?
        var baseURL: String?
        var mandatory: Bool
        var dryRun: Bool
        /// Bypass the fingerprint-compatibility refusal and upload anyway. Loud,
        /// dangerous: the module may be incompatible with installed app shells.
        var force: Bool = false
        /// Opt-in to ship the patch when the native shell drifted ONLY in ways the
        /// OTA module can't see (a package/Info.plist/entitlements/deployment-target
        /// change, with NO change to the native swift surface). Unlike `--force`, this
        /// is NOT a blanket override: it is honored ONLY when every changed component
        /// is classified native-only. If ANY change is patch-affecting, the gate still
        /// refuses (this flag does nothing) and `--force` remains the only escape.
        /// The non-interactive form of the "proceed anyway?" prompt.
        var allowNativeDrift: Bool = false
        /// When true (the default), an interactive TTY may be prompted to proceed on a
        /// native-only drift. `release`/`push` leave this on; tests / piped invocations
        /// rely on `allowNativeDrift` instead (no prompt is shown without a TTY).
        var interactive: Bool = true
        // Optional release targeting. nil = no constraint (targets everyone),
        // unchanged from the pre-targeting behavior. Forwarded verbatim into the
        // upload metadata (and printed in the preflight when set).
        var minAppVersion: String? = nil
        var maxAppVersion: String? = nil
        var minOsVersion: String? = nil
        var targetCohort: String? = nil
        /// `release` already ran the paid-rollout pre-check BEFORE building, so it
        /// sets this to skip the (otherwise duplicate) entitlements round-trip
        /// here. `push` leaves it false and runs the pre-check itself.
        var skipPaidRolloutPrecheck: Bool = false
    }

    /// Validate the rollout flag the same way for both commands.
    static func validate(rollout: Int) throws {
        guard (0...100).contains(rollout) else {
            throw ValidationError("--rollout must be between 0 and 100, got \(rollout).")
        }
    }

    /// Validate an explicit `--version` against the backend's accepted charset
    /// BEFORE the (expensive) build/upload. The backend's `ModuleMetadata.version`
    /// requires `^[A-Za-z0-9._-]+$`, max 50 chars (the value flows straight into the
    /// on-disk storage path, so `/`, `..`, and whitespace are rejected as
    /// path-traversal). Without this, a `--version "v1 beta"` built the whole WASM
    /// module and only 422'd at upload with an opaque server message. nil (the
    /// timestamp default) always passes.
    static func validate(version: String?) throws {
        guard let v = version else { return }
        if v.isEmpty {
            throw ValidationError("--version must not be empty.")
        }
        if v.count > 50 {
            throw ValidationError("--version is too long (\(v.count) chars; max 50).")
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard v.allSatisfy({ allowed.contains($0) }), !v.contains("..") else {
            throw ValidationError(
                "--version `\(v)` is invalid. Use only letters, digits, '.', '_' or '-' "
                + "(no '/', '..', or spaces).")
        }
    }

    /// Pre-check a PAID-ONLY rollout against the workspace plan (B3).
    ///
    /// Call this BEFORE the expensive WASM build. If the request asks for a
    /// paid-only feature (a non-100 `rollout` or a non-production `channel`) and
    /// the plan can't do it, throw a `ValidationError` carrying the SAME upgrade
    /// message + URL the server's 402 would return — skipping the build entirely.
    ///
    /// Cost / fallback contract:
    ///   - Common path (`rollout == 100` on `production`): returns immediately
    ///     with NO network round-trip, so the happy path adds zero latency.
    ///   - If the entitlements call fails (offline / old backend without the
    ///     endpoint), we SWALLOW the error and fall back to today's behavior:
    ///     build, then let the upload's server-side gate decide. We never block a
    ///     legitimate push on a pre-check that couldn't run.
    static func precheckPaidRollout(
        api: PatchAPI, workspaceId: String, channel: String, rollout: Int
    ) throws {
        // Common path → no round-trip, no added latency.
        guard PaidRolloutPrecheck.requiresPaidPlan(channel: channel, rollout: rollout) else {
            return
        }

        let ent: Entitlements
        do {
            ent = try api.entitlements(workspaceId: workspaceId)
        } catch {
            // Offline / old backend / transient error → fall back to the server
            // gate on upload. Never block a legitimate push.
            return
        }

        if let msg = PaidRolloutPrecheck.upgradeMessage(
            channel: channel, rollout: rollout, entitlements: ent
        ) {
            var text = msg
            if !ent.upgradeURL.isEmpty { text += "\n\n  Upgrade: \(ent.upgradeURL)" }
            throw ValidationError(text)
        }
    }

    /// Run the fingerprint gate + upload. Loads config from the CWD-relative
    /// `.Patch.yml` exactly as `push` did, so behavior is identical whether the
    /// caller is `push` or `release`.
    static func run(_ opts: Options) throws {
        try validate(rollout: opts.rollout)
        try validate(version: opts.version)

        var (config, configURL) = try CLISupport.loadConfig()
        let root = CLISupport.projectRoot(for: configURL)
        let api = try CLISupport.makeAPI(config: config, baseURLOverride: opts.baseURL)

        // Resolve app_id: explicit `app_id:` wins, else look it up by `bundle_id:`
        // and cache the result back into .Patch.yml. `config` is updated in place
        // so workspace_id resolved during the lookup is visible below.
        let appId = try CLISupport.resolveAppID(config: &config, configURL: configURL, api: api)
        let workspaceId = try CLISupport.requireWorkspaceID(config)

        // --- 0. Paid-only rollout pre-check (B3) ---------------------------
        // For `push`, the .wasm already exists, but we still fail fast here with
        // the server's exact upgrade message before uploading. `release` already ran
        // this pre-check BEFORE the build, so it sets `skipPaidRolloutPrecheck`
        // to avoid a duplicate entitlements round-trip on the paid path.
        // Common path (rollout 100 / production) makes NO round-trip regardless.
        if !opts.skipPaidRolloutPrecheck {
            try precheckPaidRollout(api: api, workspaceId: workspaceId,
                                    channel: opts.channel, rollout: opts.rollout)
        }

        // Resolve the module path.
        let moduleURL = opts.module.map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(".Patch/build/module.wasm")
        guard FileManager.default.fileExists(atPath: moduleURL.path) else {
            throw ValidationError("No .wasm at \(moduleURL.path). Run `patchcli build` first (or pass --module).")
        }
        let wasm = try Data(contentsOf: moduleURL)
        let rawSHA = Fingerprinter.hash(String(decoding: wasm, as: UTF8.self))  // informational only
        _ = rawSHA

        // --- 1. Fingerprint compatibility gate (BEFORE upload) -------------
        // Hashing the native shell + the backend round-trip are silent; spin so the
        // gate doesn't look hung between the build and the upload.
        let (snapshot, activeFingerprint): (ProjectFingerprinter.Snapshot, FingerprintRecord?) =
            try Spinner.run("Checking fingerprint compatibility") {
                let snap = FingerprintCommand.computeSnapshot(config: config, root: root)
                return (snap, try api.getActiveFingerprint(appId: appId))
            }
        guard let active = activeFingerprint else {
            throw ValidationError(
                "No active fingerprint registered for this app on the backend.\n"
                + "Register the native-shell fingerprint first:  patchcli fingerprint register\n"
                + "Or run `patchcli doctor` to check your whole setup.")
        }
        let fingerprintMatches = active.fingerprint == snapshot.fingerprint
        // Forced through the gate via the native-only-drift escape (vs `--force`),
        // so the preflight can label it accurately ("forced" vs "native-only drift").
        var proceededOnNativeDrift = false

        // Evaluate the gate as a PURE decision (no I/O), then act on it. Keeping the
        // policy in one testable function means the only side-effect left here is the
        // interactive prompt, which is itself guarded by a TTY check.
        let decision = evaluateFingerprintGate(
            snapshot: snapshot, active: active,
            force: opts.force, allowNativeDrift: opts.allowNativeDrift)
        switch decision {
        case .compatible:
            break  // matches — nothing to do.
        case .refuse(let message):
            throw ValidationError(message)
        case .forced(let warning):
            print(warning)  // --force: proceed despite the mismatch, loudly.
        case .proceedNativeDrift(let note):
            // Explicit --allow-native-drift on a sound (all-native-only) drift.
            print(note)
            proceededOnNativeDrift = true
        case .promptNativeDrift(let prompt, let approvedNote, let declinedMessage):
            // Native-only drift, no flag: ask an interactive TTY. `promptYesNo`
            // returns false without a TTY, so a piped/CI run falls through to the
            // SAFE refusal (the explicit flag is the non-interactive path).
            if opts.interactive, promptYesNo(prompt) {
                print(approvedNote)
                proceededOnNativeDrift = true
            } else {
                throw ValidationError(declinedMessage)
            }
        }

        // The device-side `fingerprint:` literal (baked into Patch.configure by
        // `patchcli init`) must track the CURRENT shell: app builds shipped with
        // a stale literal mis-report their shell and stop being served updates
        // gated on the new one. Warn loudly; don't block (the upload itself is
        // gated on the REGISTERED fingerprint above).
        if let literal = AppEntryInjector.fingerprintLiteral(in: root),
           literal.value != snapshot.fingerprint {
            print("""
                ⚠️  STALE fingerprint literal in \(literal.file.lastPathComponent):
                    sources pin fingerprint: \(literal.value.prefix(12))… but the current
                    native shell is \(snapshot.fingerprint.prefix(12))…. App builds made from
                    these sources will report the OLD shell and won't receive updates
                    gated on the new one. Update the literal before your next App Store
                    build (or delete the Patch.configure call and re-run `patchcli init`).

                """)
        }

        print("Patch push")
        print("==========")
        print("Module:        \(moduleURL.path) (\(wasm.count) bytes)")
        print("Channel:       \(opts.channel)")
        print("Rollout:       \(opts.rollout)%")
        print("Mandatory:     \(opts.mandatory)")
        if fingerprintMatches {
            print("Fingerprint:   ✓ compatible (\(active.fingerprint.prefix(12))…, id \(active.id))")
        } else if proceededOnNativeDrift {
            print("Fingerprint:   ⚠ native-only drift — patch unaffected (\(active.fingerprint.prefix(12))…, id \(active.id))")
        } else {
            print("Fingerprint:   ✗ MISMATCH — forced (\(active.fingerprint.prefix(12))…, id \(active.id))")
        }

        let resolvedVersion = opts.version ?? defaultVersion()
        print("Version:       \(resolvedVersion)")

        // Show targeting in the preflight when any constraint is set; absent =
        // no line printed (untargeted release, identical to prior output).
        if let targeting = targetingSummary(opts) {
            print("Targeting:     \(targeting)")
        }

        if opts.dryRun {
            print("\nDry run — not uploading. All preflight checks passed.")
            return
        }

        // --- 2. Upload -----------------------------------------------------
        let meta = ModuleUploadMetadata(
            appId: appId,
            workspaceId: workspaceId,
            version: resolvedVersion,
            fingerprintId: active.id,
            channel: opts.channel,
            mandatory: opts.mandatory,
            rolloutPct: opts.rollout,
            releaseNotes: opts.message,
            minAppVersion: opts.minAppVersion,
            maxAppVersion: opts.maxAppVersion,
            minOsVersion: opts.minOsVersion,
            targetCohort: opts.targetCohort
        )
        let record = try Spinner.run("Uploading module (\(wasm.count) bytes)") {
            try api.uploadModule(metadata: meta, wasm: wasm)
        }

        // --- 2b. App-icon upload (best-effort, never fails the push) -------
        // Locate the app's primary icon and upload it so the console can display
        // it next to the app. ANY failure here (no icon found, missing endpoint,
        // network error) is swallowed — a push must never fail over a cosmetic
        // icon upload. Skipped on a dry run (handled above by the early return).
        uploadAppIconBestEffort(api: api, appId: appId, root: root)

        print("\n✓ Pushed module \(record.version)")
        print("  Module id:   \(record.id)")
        print("  SHA-256:     \(record.sha256)")
        print("  Size:        \(record.sizeBytes) bytes")
        print("  Rollout:     \(record.rolloutPct)%")
        print("  Active:      \(record.isActive)")
        print("  Served path: \(record.modulePath)")
        // Known wire-protocol note: the served path is the brotli-compressed
        // `.wasm.br`, while `sha256` is computed over the RAW wasm bytes the
        // device decompresses to. The SDK verifies sha256 AFTER decompression.
        if record.modulePath.hasSuffix(".br") {
            print("\nNote: served path is brotli-compressed (.wasm.br); the sha256 above is")
            print("      over the RAW decompressed .wasm — the device verifies post-decompress.")
        }
    }

    /// Locate the app's primary icon under `root` and upload it (best-effort).
    /// Prints a one-line result. NEVER throws / never fails the push: a missing
    /// icon or a backend without the icon endpoint is reported and skipped.
    static func uploadAppIconBestEffort(api: PatchAPI, appId: String, root: URL) {
        guard let icon = AppIconLocator.locate(in: root) else {
            // No icon found — this is normal for SPM libraries / icon-less apps.
            return
        }
        do {
            _ = try api.uploadAppIcon(
                appId: appId,
                icon: icon.data,
                fileName: icon.url.lastPathComponent,
                mimeType: icon.mimeType)
            print("  App icon:    ✓ uploaded \(icon.url.lastPathComponent) (\(icon.byteCount) bytes)")
        } catch {
            // The endpoint may not be deployed yet, or the network hiccupped. The
            // module already shipped; the icon is cosmetic, so just note + move on.
            print("  App icon:    found \(icon.url.lastPathComponent) but upload was skipped (\(error))")
        }
    }

    /// One-line human summary of the targeting flags, or nil when none are set
    /// (untargeted release). E.g. "app ≥ 2.1.0, iOS ≥ 16.0, cohort beta".
    static func targetingSummary(_ opts: Options) -> String? {
        var parts: [String] = []
        if let v = opts.minAppVersion { parts.append("app ≥ \(v)") }
        if let v = opts.maxAppVersion { parts.append("app ≤ \(v)") }
        if let v = opts.minOsVersion { parts.append("iOS ≥ \(v)") }
        if let v = opts.targetCohort { parts.append("cohort \(v)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - Fingerprint gate (pure decision)

    /// The outcome of the fingerprint-compatibility gate, separated from I/O so the
    /// policy (when do we ship / refuse / prompt) is unit-testable without a network
    /// or a TTY. The associated strings are the exact messages `run` prints/throws.
    enum FingerprintGate: Equatable {
        /// Local == backend fingerprint: ship, nothing to print.
        case compatible
        /// Refuse the push (mismatch with no sound skip available). Carries the
        /// actionable error message.
        case refuse(message: String)
        /// `--force`: proceed despite the mismatch (overrides everything). Carries the
        /// loud warning to print.
        case forced(warning: String)
        /// `--allow-native-drift` on an all-native-only drift: proceed; carries the
        /// confirmation note.
        case proceedNativeDrift(note: String)
        /// Native-only drift, NO flag: ask an interactive TTY. Carries the prompt, the
        /// note to print on yes, and the refusal message to throw on no/non-interactive.
        case promptNativeDrift(prompt: String, approvedNote: String, declinedMessage: String)
    }

    /// Decide the fingerprint gate outcome PURELY from the snapshot, the backend
    /// record, and the two override flags. No I/O — the caller prints/prompts/throws.
    ///
    /// SAFETY MODEL (the heart of the partial-patch feature):
    ///   1. Match → `.compatible`.
    ///   2. `--force` → `.forced` (blanket override; the existing escape hatch).
    ///   3. Mismatch, no force: classify the changed components.
    ///      • EVERY change native-only (`report.allNativeOnly`) → the OTA module
    ///        provably can't see the drift, so the patch IS compatible. Offer the skip
    ///        (`--allow-native-drift` → proceed; else prompt; else SAFE refuse).
    ///      • ANY change patch-affecting (or no component detail at all) → refuse.
    ///        `--allow-native-drift` does NOT bypass this; `--force` is the only escape.
    /// When in doubt (no componentHashes to classify), `allNativeOnly` is false, so we
    /// refuse — never silently ship.
    static func evaluateFingerprintGate(
        snapshot: ProjectFingerprinter.Snapshot,
        active: FingerprintRecord,
        force: Bool,
        allowNativeDrift: Bool
    ) -> FingerprintGate {
        if active.fingerprint == snapshot.fingerprint { return .compatible }

        // Human-readable "what changed" block, shared across messages.
        let changed = ProjectFingerprinter.changedComponents(local: snapshot, backend: active.components)
        let whatChanged = changed.isEmpty
            ? "(See `patchcli fingerprint diff` for which components changed.)"
            : "What changed in the native shell:\n" + changed.joined(separator: "\n")
                + "\n\n  Why these aren't OTA-patchable (which functions are native):"
                + "\n      patchcli fingerprint diff --explain"

        if force {
            return .forced(warning: """
                ⚠️  WARNING: --force overriding the FINGERPRINT MISMATCH gate.
                    local native-shell fingerprint:  \(snapshot.fingerprint)
                    backend active fingerprint:       \(active.fingerprint)

                \(whatChanged)

                    This OTA module may be INCOMPATIBLE with installed app shells and
                    could crash users on the old native binary. Proceeding anyway.

                """)
        }

        let report = ProjectFingerprinter.componentDeltas(local: snapshot, backend: active.components)
        guard report.allNativeOnly else {
            // Either no component detail (old record) or a patch-affecting change.
            let affectingNote = report.hasPatchAffecting
                ? "\n\n  At least one change is PATCH-AFFECTING (it can change the surface the\n"
                  + "  patch is built against), so --allow-native-drift will NOT bypass this."
                : ""
            return .refuse(message: """
                FINGERPRINT MISMATCH — refusing to push.

                  local native-shell fingerprint:  \(snapshot.fingerprint)
                  backend active fingerprint:       \(active.fingerprint)

                \(whatChanged)\(affectingNote)

                The native shell changed since the last App Store release, so this OTA
                module is NOT compatible with installed apps. Ship the change THROUGH
                THE APP STORE, then re-register:

                      patchcli fingerprint register

                Not sure what drifted or whether your setup is correct? Run:

                      patchcli doctor

                To override this safety gate anyway, re-run with --force.
                """)
        }

        // All-native-only drift: the patch IS compatible. Build the explanation.
        let summary = report.nativeOnly
            .map { "    • \(ProjectFingerprinter.titleForLabel($0.label))" }
            .joined(separator: "\n")
        let explanation = """
            NATIVE-ONLY DRIFT — your patched views are unaffected.

              The native shell changed, but ONLY in ways an OTA patch can't see:
            \(summary)

              None of these is part of the surface your view patch ships, so a patch
              built from the current source is COMPATIBLE with installed apps.
              (Still ship the native change through the App Store + re-register so
               future devices report the new shell.)
            """
        if allowNativeDrift {
            return .proceedNativeDrift(note: "✓ \(explanation)\n  Proceeding (--allow-native-drift).\n")
        }
        return .promptNativeDrift(
            prompt: "\(explanation)\n\nShip the view patch anyway?",
            approvedNote: "✓ Proceeding on native-only drift.\n",
            declinedMessage: """
                FINGERPRINT MISMATCH — native-only drift, not shipped.

                \(explanation)

                To ship the patch on this native-only drift, re-run with:
                      --allow-native-drift
                (or run `patchcli fingerprint diff` to review the breakdown).
                """)
    }

    /// Print a prompt and read a y/N answer from stdin. Returns false (the SAFE
    /// default) when there's no interactive TTY, when stdin is closed, or on any
    /// answer that isn't an explicit yes — so a piped / CI invocation never silently
    /// ships on a drift it wasn't told to (`--allow-native-drift` is the explicit,
    /// non-interactive path). Only "y"/"yes" (case-insensitive) is a yes.
    static func promptYesNo(_ message: String) -> Bool {
        // No TTY (piped stdin, CI) → never prompt; default to the safe "no".
        guard isatty(fileno(stdin)) != 0 else { return false }
        print("\n\(message) [y/N] ", terminator: "")
        guard let line = readLine(strippingNewline: true) else { return false }
        let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    static func defaultVersion() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd.HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }
}
