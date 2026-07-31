// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler

/// `Patch fingerprint diff` / `register` — compute the native-shell fingerprint
/// (SHA-256 over the plan's components), show the diff vs the last registered
/// fingerprint, and register it via `POST /api/v1/fingerprints`.
struct FingerprintCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fingerprint",
        abstract: "Compute / diff / register the native-shell fingerprint.",
        subcommands: [Diff.self, Register.self],
        defaultSubcommand: Diff.self
    )

    /// Shared helper: compute the local snapshot from config + project.
    static func computeSnapshot(config: PatchConfig, root: URL) -> ProjectFingerprinter.Snapshot {
        let fp = ProjectFingerprinter()
        return fp.snapshot(projectDir: root, bridges: config.bridges, excludes: config.exclude,
                           buildSwiftUI: config.buildSwiftUI)
    }

    /// [divergence-fix] The BUILD-CONFIRMED native-shell snapshot — the SAME fingerprint
    /// `release` enforces. This closes the #1 P0 divergence: `register`/`diff` used to hash
    /// against a STATIC (manifest-absent) prediction that OPTIMISTICALLY stripped every
    /// `wasmEligible` body (it assumes general logic is trusted), while `release` runs the
    /// build, which writes a `shipped-ota.json` whose `generalLogicTrusted` is FALSE for apps
    /// whose general module doesn't fully lower → those bodies stay HASHED → a permanent
    /// false-MISMATCH on every release even when the user only edited an OTA-able view.
    ///
    /// To agree with `release`, we RUN the build (`BuildPipeline.run`), which writes a fresh
    /// `shipped-ota.json` reflecting what ACTUALLY lowers, THEN compute the snapshot (which
    /// reads that fresh manifest). The result is the device-correct fingerprint: a
    /// `generalLogicTrusted:false` body renders NATIVELY on device, so editing it SHOULD churn.
    ///
    /// Returns `(snapshot, didBuild)`. When the WASM toolchain is ABSENT we CANNOT build, so we
    /// delete any stale manifest (preserving the R3-#16 "register is a pure function of source,
    /// not polluted by a STALE manifest" intent) and fall back to the static snapshot with
    /// `didBuild == false` — the caller must warn that the baseline is an ESTIMATE and to
    /// re-register/diff after a real `build`.
    ///
    /// SAFETY (false-stable guard): we DELETE any pre-existing manifest BEFORE the build, so a
    /// build that THROWS mid-way (before `BuildPipeline.run` reaches its final
    /// `writeShippedManifest`) can NEVER leave a STALE, possibly-OPTIMISTIC manifest for the
    /// snapshot below to read — which would strip a body the current source no longer lowers
    /// (a false-stable). After the delete, the snapshot reads ONLY a manifest THIS build wrote
    /// (a fully successful build) or NONE (a thrown build → the conservative manifest-absent
    /// static prediction). Either way the build-confirmed snapshot is NEVER more optimistic
    /// than the static one — it strips a body ONLY when a FRESH build's manifest CONFIRMS it
    /// shipped OTA. Both divergence directions remain false-REFUSES (safe), never a false-STABLE.
    static func buildConfirmedSnapshot(
        config: PatchConfig, root: URL, quiet: Bool = false
    ) -> (snapshot: ProjectFingerprinter.Snapshot, didBuild: Bool) {
        let compiler = SwiftWasmCompiler()
        let manifestURL = root
            .appendingPathComponent(".Patch")
            .appendingPathComponent("build")
            .appendingPathComponent(ShippedOTAManifest.fileName)

        // [false-stable guard] ALWAYS delete the prior manifest first. `BuildPipeline.run`
        // writes a fresh `shipped-ota.json` ONLY as its LAST step (a fully successful build);
        // a build that throws part-way leaves the PRIOR build's manifest in place, and
        // `invalidateStagedArtifacts` does NOT sweep it. Reading that stale manifest after a
        // source change could strip a body the current source no longer lowers → a false-stable.
        // Deleting up front means the snapshot reads ONLY this build's fresh manifest or none.
        try? FileManager.default.removeItem(at: manifestURL)

        guard compiler.toolchainAvailable else {
            // No toolchain → can't build. The manifest is already gone, so we hash the
            // deterministic manifest-absent static prediction (R3-#16: a pure function of
            // source, never a stale build verdict). The caller surfaces the estimate warning.
            return (computeSnapshot(config: config, root: root), false)
        }

        // Run the SAME build `release` runs, into the CANONICAL build dir the fingerprint
        // reads (`<root>/.Patch/build`). It writes a fresh `shipped-ota.json` reflecting what
        // actually lowered. A build failure is non-fatal: if it throws before writing the
        // manifest, the snapshot below falls back to the (now-deleted → absent) conservative
        // static prediction — the gate stays usable and never gets MORE optimistic than today.
        let buildDir = root.appendingPathComponent(".Patch/build")
        do {
            _ = try BuildPipeline().run(
                sourceDir: root,
                buildDir: buildDir,
                compiler: compiler,
                dryRun: false,
                outputModule: nil,
                swiftUIEnabled: config.buildSwiftUI)
        } catch {
            if !quiet {
                FileHandle.standardError.write(Data(
                    "  (note: the build-confirmation compile reported an error; the fingerprint uses the conservative static prediction)\n".utf8))
            }
        }
        return (computeSnapshot(config: config, root: root), true)
    }

    /// Compute + register the CURRENT native-shell fingerprint with the backend.
    /// Shared by `fingerprint register` and `patchcli init` (which auto-registers
    /// the current shell so the first push works without a manual step). Throws if
    /// there's no app_id or the backend call fails. Pass `precomputed` to reuse a
    /// snapshot the caller already computed (init hashes the tree once for both
    /// the injected `fingerprint:` literal and this registration).
    /// [divergence-fix] When `precomputed` is nil we register the BUILD-CONFIRMED snapshot
    /// (run the build, then hash the build-written manifest) so the registered baseline equals
    /// the one `release` enforces — no more false-MISMATCH on the first release. `init` passes
    /// its already-computed snapshot via `precomputed` and keeps its own (build-confirmed or
    /// static-fallback) flow; with no toolchain the helper falls back to the static snapshot.
    @discardableResult
    static func registerCurrent(
        config: PatchConfig, root: URL,
        baseURLOverride: String? = nil, appVersion: String? = nil,
        precomputed: ProjectFingerprinter.Snapshot? = nil
    ) throws -> FingerprintRecord {
        let appId = try CLISupport.requireAppID(config)
        let snapshot = precomputed ?? buildConfirmedSnapshot(config: config, root: root, quiet: true).snapshot
        let components = ProjectFingerprinter.componentsDictionary(snapshot)
        let api = try CLISupport.makeAPI(config: config, baseURLOverride: baseURLOverride)
        return try api.registerFingerprint(
            appId: appId,
            fingerprint: snapshot.fingerprint,
            components: components,
            appVersion: appVersion
        )
    }

    // MARK: - diff

    struct Diff: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "diff",
            abstract: "Show what changed in the native shell since the last registered fingerprint."
        )

        @Option(name: .long, help: "Backend base URL override.")
        var baseURL: String?

        @Flag(name: .long, help: "Output JSON.")
        var json: Bool = false

        @Flag(name: .long, help: "Also list the native (not OTA-patchable) functions in the shell and WHY each is native.")
        var explain: Bool = false

        @Flag(name: .customLong("no-build"),
              help: "Skip the build-confirmation compile; compute the STATIC estimate instead (faster, but the result is an estimate — the authoritative check runs at build/release).")
        var noBuild: Bool = false

        func run() throws {
            let (config, configURL) = try CLISupport.loadConfig()
            let root = CLISupport.projectRoot(for: configURL)
            // [divergence-fix] `diff` must reflect BUILD TRUTH — the SAME fingerprint
            // `register`/`release` enforce — or it false-mismatches against a build-confirmed
            // baseline (the #1 P0: after a release writes `shipped-ota.json` with
            // `generalLogicTrusted:false`, the old static diff strips bodies the build keeps
            // native and reports MISMATCH on an unchanged shell). Resolution, soundest-first:
            //   1) A FRESH manifest (its source-set hash matches the current source) → reuse
            //      it as-is (no rebuild — fast + already build-confirmed).
            //   2) Stale/absent manifest + WASM toolchain → BUILD to produce a fresh manifest,
            //      then hash (exactly what `register`/`release` do).
            //   3) Stale/absent manifest + NO toolchain → compute the STATIC estimate and PRINT
            //      an explicit warning that the authoritative check runs at build/release.
            // `--no-build` forces path 3 (the fast estimate) on demand.
            let compiler = SwiftWasmCompiler()
            let freshManifest = ShippedOTAManifest.read(projectDir: root)?
                .isFresh(projectDir: root) ?? false
            var diffIsEstimate = false
            let snapshot: ProjectFingerprinter.Snapshot
            if freshManifest {
                // Already build-confirmed and current — hash against it directly.
                snapshot = Spinner.run("Computing native-shell fingerprint") {
                    FingerprintCommand.computeSnapshot(config: config, root: root)
                }
            } else if !noBuild && compiler.toolchainAvailable {
                // Rebuild to refresh the manifest, then hash the build-confirmed result.
                snapshot = Spinner.run("Computing build-confirmed native-shell fingerprint") {
                    FingerprintCommand.buildConfirmedSnapshot(config: config, root: root, quiet: true).snapshot
                }
            } else {
                // No fresh manifest + (no toolchain OR --no-build) → static estimate.
                diffIsEstimate = true
                snapshot = Spinner.run("Computing native-shell fingerprint (estimate)") {
                    FingerprintCommand.computeSnapshot(config: config, root: root)
                }
            }

            // Try to fetch the last registered fingerprint (optional / best-effort).
            var registered: FingerprintRecord?
            if let appId = config.appId, let api = try? CLISupport.makeAPI(config: config, baseURLOverride: baseURL) {
                registered = Spinner.run("Checking the registered fingerprint") {
                    try? api.getActiveFingerprint(appId: appId)
                }
            }

            // Component-level delta breakdown (native-only vs patch-affecting),
            // computed once and reused by both the JSON and human output.
            let deltaReport = registered.map {
                ProjectFingerprinter.componentDeltas(local: snapshot, backend: $0.components)
            }

            if json {
                var obj: [String: Any] = [
                    "current": snapshot.fingerprint,
                    "components": snapshot.componentHashes.reduce(into: [String: String]()) { $0[$1.label] = $1.hash },
                ]
                if let registered { obj["registered"] = registered.fingerprint }
                obj["compatible"] = registered.map { $0.fingerprint == snapshot.fingerprint } ?? false
                if let deltaReport {
                    obj["changedComponents"] = deltaReport.deltas.map {
                        ["label": $0.label, "kind": $0.kind.rawValue]
                    }
                    // True only when there's a mismatch AND every changed component is
                    // native-only — the sole condition that permits skip-and-patch.
                    obj["nativeOnlyDrift"] = deltaReport.allNativeOnly
                }
                // [divergence-fix] Flag a non-authoritative (static) result so a consumer
                // doesn't treat an estimate as the build-confirmed truth.
                obj["estimate"] = diffIsEstimate
                CLISupport.printJSON(obj)
                return
            }

            print("Patch fingerprint diff")
            print("======================")
            if diffIsEstimate {
                print("⚠ ESTIMATE — the authoritative check runs at build/release.")
                print("  No fresh build manifest and \(noBuild ? "--no-build was passed" : "the WASM toolchain is unavailable"),")
                print("  so this is a STATIC prediction. Run `patchcli build` then `patchcli fingerprint diff`")
                print("  (or install the toolchain via `patchcli setup`) for an accurate result.")
                print("")
            }
            print("Current fingerprint:    \(snapshot.fingerprint)")
            print("Native swift files:     \(snapshot.components.nativeSwiftFiles.count)")
            print("Bridge definitions:     \(snapshot.components.bridgeDefinitions.joined(separator: ", "))")
            print("Linked frameworks:      \(snapshot.components.linkedFrameworks.joined(separator: ", "))")
            print("Deployment target:      \(snapshot.components.deploymentTarget)")
            print("Swift compiler:         \(snapshot.components.swiftCompilerVersion)")
            print("")

            if let registered {
                print("Registered fingerprint: \(registered.fingerprint)")
                if registered.fingerprint == snapshot.fingerprint {
                    print("\n✓ COMPATIBLE — the native shell is unchanged. OTA pushes will apply cleanly.")
                } else {
                    print("\n✗ MISMATCH — the native shell CHANGED since the last App Store release.")
                    let report = deltaReport ?? ProjectFingerprinter.DeltaReport(deltas: [])
                    if !report.changed {
                        print("\n  (Changing any of: native .swift files, bridges, Info.plist, entitlements,")
                        print("   linked frameworks, deployment target, or the Swift compiler version")
                        print("   alters the binary layout and breaks OTA compatibility.)")
                    } else {
                        // Component-level breakdown: every changed component, tagged
                        // native-only (the OTA patch can't see it) vs patch-affecting
                        // (CAN reach the shipped patch).
                        print("\nChanged components (tagged native-only vs patch-affecting):")
                        for delta in report.deltas {
                            let tag = delta.kind == ProjectFingerprinter.DeltaKind.nativeOnly
                                ? "[native-only]   " : "[patch-affecting]"
                            print("  \(tag) \(ProjectFingerprinter.titleForLabel(delta.label))")
                            // The detail lines already carry a "  • " prefix; print
                            // them with one extra level of indent under the header.
                            for line in delta.detailLines { print("  \(line)") }
                        }
                        if report.allNativeOnly {
                            print("""

                              → All changes are NATIVE-ONLY: the native shell drifted (e.g. a package,
                                Info.plist, entitlements, or deployment target) but NOTHING the OTA patch
                                ships was touched. A view patch built now is COMPATIBLE with installed apps.
                                `patchcli push`/`release` will offer to ship it (or pass --allow-native-drift).
                                You should STILL ship the native change through the App Store + re-register
                                so future devices report the new shell.
                            """)
                        } else {
                            print("""

                              → At least one change is PATCH-AFFECTING: it can change the surface the patch
                                is built against. An OTA module built now may be incompatible — you must
                                ship the change THROUGH THE APP STORE, then re-register:
                                    patchcli fingerprint register
                            """)
                        }
                    }
                    if !explain {
                        print("\n  (Run `patchcli fingerprint diff --explain` to see WHICH functions are")
                        print("   native — not OTA-patchable — and why.)")
                    }
                }
            } else {
                print("No registered fingerprint found on the backend for this app.")
                print("This is the FIRST registration: run `patchcli fingerprint register`")
                print("after your next App Store build so OTA pushes can be gated against it.")
            }

            // `--explain`: enumerate the native (not-OTA-patchable) shell with a
            // plain-language reason per file. Baseline-free — answers "why isn't my
            // edit shipping OTA / why did it change the fingerprint" without needing
            // a registration to diff against.
            if explain {
                print("\nNative shell (not OTA-patchable) — files & reasons:")
                let all = Spinner.run("Analyzing the native shell") {
                    FingerprintExplain.explain(projectDir: root)
                }
                if all.isEmpty {
                    print("  (no native functions found, or analysis unavailable)")
                } else {
                    for e in all {
                        print("  \(e.relPath): \(e.nativeFunctions.count) native fn(s) — \(e.dominantReason)")
                    }
                    print("\n  Everything else (pure logic + SwiftUI view bodies) is OTA-patchable and")
                    print("  does NOT contribute to fingerprint churn.")
                }
            }
        }
    }

    // MARK: - register

    struct Register: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "register",
            abstract: "Register the current native-shell fingerprint with the backend."
        )

        @Option(name: .long, help: "Backend base URL override.")
        var baseURL: String?

        @Option(name: .long, help: "App version string to record (e.g. 2.0.0).")
        var appVersion: String?

        @Flag(name: .long, help: "Compute + print the fingerprint but do not call the backend.")
        var dryRun: Bool = false

        @Flag(name: .long, help: "Output JSON.")
        var json: Bool = false

        @Flag(name: .customLong("no-prepare"),
              help: "Skip the automatic prepare step before hashing (advanced — risks a post-upgrade fingerprint mismatch on the next release).")
        var noPrepare: Bool = false

        func run() throws {
            let (config, configURL) = try CLISupport.loadConfig()
            let root = CLISupport.projectRoot(for: configURL)
            let appId = try CLISupport.requireAppID(config)
            // [divergence-fix] `register` must produce the BUILD-CONFIRMED fingerprint — the
            // SAME one `release` enforces — or it registers a baseline `release` can never
            // reproduce (a permanent false-MISMATCH on the first release). The OLD behavior
            // (AutoPrepare + DELETE the manifest → hash the static prediction) OPTIMISTICALLY
            // stripped every `wasmEligible` body, but `release` runs the build, which records
            // `generalLogicTrusted:false` for apps whose general module doesn't fully lower →
            // those bodies stay HASHED → the registered (stripped) baseline never matches the
            // release (hashed) one. The fix: RUN the build (which writes a fresh
            // `shipped-ota.json` reflecting what actually lowers), THEN hash — so register
            // == release. The build also runs AutoPrepare implicitly, so the prepared-state
            // symmetry (the prior reason AutoPrepare ran here) is preserved.
            //
            // A dry run must be a true NO-OP (it must not mutate the source tree / pbxproj /
            // .gitignore, nor write a manifest), so it hashes the CURRENT state statically and
            // notes that a real register builds first.
            var didBuild = false
            let snapshot: ProjectFingerprinter.Snapshot
            if dryRun {
                snapshot = Spinner.run("Computing native-shell fingerprint") {
                    FingerprintCommand.computeSnapshot(config: config, root: root)
                }
            } else {
                AutoPrepare.run(root: root, excludes: config.exclude,
                                target: config.target.isEmpty ? nil : config.target,
                                noPrepareFlag: noPrepare, config: config)
                (snapshot, didBuild) = Spinner.run("Computing build-confirmed native-shell fingerprint") {
                    FingerprintCommand.buildConfirmedSnapshot(config: config, root: root)
                }
                if !didBuild {
                    print("""
                        ⚠️  WASM toolchain not found — registered an ESTIMATE.
                            The authoritative native-shell fingerprint is the one a real BUILD
                            produces (it records which view/logic bodies actually ship OTA). Without
                            the toolchain this register used the static prediction, which can DIFFER
                            from what `patchcli release` will enforce. Install the toolchain
                            (`patchcli setup`) and re-run `patchcli fingerprint register` so the
                            baseline matches your releases.

                        """)
                }
            }

            let components = ProjectFingerprinter.componentsDictionary(snapshot)

            if dryRun {
                if json {
                    CLISupport.printJSON(["fingerprint": snapshot.fingerprint, "dryRun": true])
                } else {
                    print("Patch fingerprint register (dry run)")
                    print("Fingerprint: \(snapshot.fingerprint)")
                    print("Note: this dry run did NOT modify your project and did NOT build; a real")
                    print("      `register` prepares + BUILDS first (so its fingerprint reflects what")
                    print("      actually ships OTA) — the registered value may differ from this estimate.")
                    print("Would POST to \(CLISupport.resolveBaseURL(baseURL, config: config))/api/v1/fingerprints")
                }
                return
            }

            let api = try CLISupport.makeAPI(config: config, baseURLOverride: baseURL)
            let record = try Spinner.run("Registering fingerprint with the backend") {
                try api.registerFingerprint(
                    appId: appId,
                    fingerprint: snapshot.fingerprint,
                    components: components,
                    appVersion: appVersion
                )
            }

            // Keep the device-side `fingerprint:` literal baked into `Patch.configure` in
            // lockstep with the just-registered shell. The literal value is EXCLUDED from the
            // native-shell hash (`normalizeConfigureFingerprint`), so rebaking it is hash-inert —
            // but it is what each device REPORTS for exact update gating. Without this, a
            // re-register after a shell change (or after upgrading to the literal-excluded hash)
            // would leave device builds pinned to the OLD shell (served best-effort / blocked).
            // Best-effort + no-op when the app has no baked literal. Mirrors `init`'s rebake.
            let literalRebaked = AppEntryInjector.rebakeFingerprint(in: root, to: record.fingerprint)

            if json {
                CLISupport.printJSON([
                    "id": record.id, "fingerprint": record.fingerprint,
                    "appId": record.appId, "isActive": record.isActive,
                ])
                return
            }
            print("Patch fingerprint register")
            print("==========================")
            print("Registered fingerprint: \(record.fingerprint)")
            print("Backend fingerprint id: \(record.id)")
            print("App id:                 \(record.appId)")
            print("Active:                 \(record.isActive)")
            if literalRebaked {
                print("Updated the baked `fingerprint:` literal in your @main App to match.")
            }
            print("\nOTA pushes are now gated against this native-shell layout.")
        }
    }
}
