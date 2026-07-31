// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import PartitioningEngine
import Compiler

/// `Patch build` (Track F1) — run the REAL engine (parse → classify → split via
/// PartitioningEngine + CodeGenerator), then compile the generated `_wasm.swift`
/// to an actual `.wasm` via the REAL `WasmCompiler` (swift.org toolchain +
/// `--swift-sdk swift-6.3.2-RELEASE_wasm`). Prints the coverage report and
/// writes the module to `.Patch/build/module.wasm`.
struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Parse → classify → split → compile to a real .wasm module. Track F1."
    )

    @Argument(help: "Source directory to build (default: project root from .Patch.yml, else CWD).")
    var path: String?

    @Flag(name: .long, help: "Verbose: print generated sources + per-function table.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Generate sources + coverage report but skip the WASM compile.")
    var dryRun: Bool = false

    @Option(name: .long, help: "Write the coverage report (JSON) to this path.")
    var report: String?

    @Option(name: .long, help: "Optimization: size | speed.")
    var optimization: String?

    @Option(name: .long, help: "Output .wasm path (default: .Patch/build/module.wasm).")
    var output: String?

    @Flag(name: .customLong("no-prepare"),
          help: "Skip the automatic `prepare` step (don't add `dynamic`/thunks to new views before building).")
    var noPrepare: Bool = false

    func run() throws {
        // Resolve source dir + build dir from config when present (optional).
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var sourceDir: URL
        var buildRoot: URL
        var opt = optimization ?? "size"
        var swiftUIEnabled = true  // .Patch.yml `swiftui` (default on if no config)
        // Phase 1b: a `.Patch.yml` `overlay: <spec.json>` auto-packages the resource
        // overlay (colors/strings/images) into the built module. Resolved relative to
        // the project root; nil = no overlay.
        var overlaySpecURL: URL?
        // Auto-prepare context (resolved alongside the build inputs below).
        var prepareRoot: URL
        var prepareExcludes: [String] = []
        var prepareTarget: String?
        var resolvedConfig: PatchConfig?

        if let configURL = PatchConfig.find(startingAt: cwd) {
            let cfg = try PatchConfig.load(from: configURL)
            let root = CLISupport.projectRoot(for: configURL)
            sourceDir = path.map { URL(fileURLWithPath: $0) } ?? root
            buildRoot = root.appendingPathComponent(".Patch/build")
            if optimization == nil { opt = cfg.buildOptimization }
            swiftUIEnabled = cfg.buildSwiftUI
            if let spec = cfg.overlaySpec, !spec.isEmpty {
                overlaySpecURL = spec.hasPrefix("/")
                    ? URL(fileURLWithPath: spec)
                    : root.appendingPathComponent(spec)
            }
            prepareRoot = root
            prepareExcludes = cfg.exclude
            prepareTarget = cfg.target.isEmpty ? nil : cfg.target
            resolvedConfig = cfg
        } else {
            // No config — build whatever path is given (or CWD).
            sourceDir = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            buildRoot = cwd.appendingPathComponent(".Patch/build")
            prepareRoot = sourceDir
        }

        // Auto-prepare: make any NEW SwiftUI views patchable (insert `dynamic` + thunks)
        // BEFORE we build, so the developer never has to remember `patchcli prepare`.
        // Idempotent + quiet (silent when nothing's new); degrades gracefully on failure.
        AutoPrepare.run(root: prepareRoot, excludes: prepareExcludes, target: prepareTarget,
                        noPrepareFlag: noPrepare, config: resolvedConfig)
        // `--output <path>`: the build directory holds generated sources next to the
        // requested module; the module itself is written to the EXACT path/filename.
        var outputModule: URL?
        if let output {
            let outURL = URL(fileURLWithPath: output)
            buildRoot = outURL.deletingLastPathComponent()
            outputModule = outURL
        }

        guard ["size", "speed"].contains(opt) else {
            throw ValidationError("--optimization must be 'size' or 'speed', got '\(opt)'.")
        }

        let compiler = SwiftWasmCompiler()
        print("Patch build")
        print("===========")
        print("Source:         \(sourceDir.path)")
        print("Build dir:      \(buildRoot.path)")
        print("Optimization:   \(opt)")
        print("WASM toolchain: \(compiler.toolchainAvailable ? "available" : "NOT FOUND (compile will be skipped)")")
        print("")

        let pipeline = BuildPipeline()
        // Spin during the (silent, multi-second) real compile — but not a dry run.
        let willCompile = !(dryRun || !compiler.toolchainAvailable)
        let compileSpinner = willCompile ? Spinner("Compiling Swift → WebAssembly") : nil
        compileSpinner?.start()
        defer { compileSpinner?.clear() }
        let result = try pipeline.run(
            sourceDir: sourceDir,
            buildDir: buildRoot,
            compiler: compiler,
            dryRun: dryRun || !compiler.toolchainAvailable,
            outputModule: outputModule,
            swiftUIEnabled: swiftUIEnabled
        )
        compileSpinner?.succeed("Compiled to WebAssembly")

        // Phase 1b: package the resource overlay into the built module artifact (if a
        // spec is configured and a real module was emitted). Done AFTER the pipeline's
        // wasm-opt finalize so it wraps the final shippable bytes; the result rides the
        // unchanged push/upload path.
        if let specURL = overlaySpecURL, let moduleURL = result.moduleURL,
           FileManager.default.fileExists(atPath: moduleURL.path) {
            try packageOverlay(specURL: specURL, moduleURL: moduleURL)
        }

        printCoverage(result.report, split: result.splitFunctions)

        print("\nCode generation:")
        print("  WASM fragment sources:  \(result.generatedWasmSources.count)")
        print("  Native bridge sources:  \(result.generatedBridgeSources.count)")
        print("  Exported symbols:       \(result.exportSymbols.count)")
        print("  Packaging tier (start): \(tierLabel(result.selectedTier))")
        print("    \(result.tierRationale)")
        if verbose {
            for s in result.generatedWasmSources { print("    + \(s.path)") }
            for s in result.generatedBridgeSources { print("    + \(s.path)") }
        }
        if verbose && !result.rejectedExports.isEmpty {
            // Why classifier-eligible functions did NOT become OTA fragments — grouped
            // by reason (specific names in backticks collapsed) so the dominant
            // realization gap is visible. This is the lever for raising units/app.
            print("  Rejected pure exports (eligible but not emitted): \(result.rejectedExports.count)")
            var byReason: [String: Int] = [:]
            for r in result.rejectedExports {
                let cat = r.reason.replacingOccurrences(
                    of: "`[^`]*`", with: "`…`", options: .regularExpression)
                byReason[cat, default: 0] += 1
            }
            for (reason, n) in byReason.sorted(by: { $0.value > $1.value }) {
                print("    [\(n)] \(reason)")
            }
        }

        if dryRun {
            print("\nDry run — skipped WASM compile. Generated sources written to \(buildRoot.path).")
        } else if !compiler.toolchainAvailable {
            print("\nWASM toolchain unavailable — generated sources only. Install the swift.org")
            print("toolchain + WebAssembly SDK to emit a real .wasm.")
        } else if let outcome = result.compileOutcome {
            if outcome.toolchainUnavailable {
                print("\nWASM toolchain reported unavailable mid-build — no module emitted.")
            } else {
                print("\nWASM compile:")
                print("  Iterations:           \(outcome.iterations)")
                if let ft = outcome.finalTier {
                    print("  Final tier:           \(tierLabel(ft))")
                }
                print("  Compiled OTA units:   \(outcome.compiled.count)")
                print("  Demoted to native:    \(outcome.reclassifiedNative.count)")
                for d in outcome.reclassifiedNative {
                    print("    - \(d.functionID) (failed WASM compile → native)")
                }
                if let module = result.moduleURL,
                   let size = try? FileManager.default.attributesOfItem(atPath: module.path)[.size] as? Int {
                    print("\n  Module: \(module.path) (\(byteString(size)))")
                    // Size finalize pass (wasm-opt -Oz). Report the cut when it ran.
                    if result.wasmOptimized, result.moduleSizeBeforeOpt > result.moduleSizeAfterOpt {
                        let pct = 100.0 * Double(result.moduleSizeBeforeOpt - result.moduleSizeAfterOpt)
                            / Double(result.moduleSizeBeforeOpt)
                        print(String(format: "    wasm-opt -Oz: %@ → %@ (%.1f%% smaller, debug/producers stripped)",
                                     byteString(result.moduleSizeBeforeOpt),
                                     byteString(result.moduleSizeAfterOpt), pct))
                    } else if result.moduleSizeBeforeOpt > 0 {
                        print("    wasm-opt -Oz: not applied (Binaryen `wasm-opt` not found — `brew install binaryen` to shrink the module)")
                    }
                    print("  ✓ Build succeeded — push with: patchcli push")
                } else {
                    print("\n  No module emitted.")
                }
                // Additive real-source closure compilation (PATCH_REAL_SOURCE=1).
                if result.realSourceModuleURL != nil || result.realSourceCompiledUnits > 0 {
                    print("\n  Real-source closure (PATCH_REAL_SOURCE):")
                    print("    Additional OTA units: \(result.realSourceCompiledUnits)  (compiled against real module source)")
                    let totalUnits = outcome.compiled.count + result.realSourceCompiledUnits
                    print("    Total OTA units:      \(totalUnits)  (default \(outcome.compiled.count) + real-source \(result.realSourceCompiledUnits))")
                    if let m = result.realSourceModuleURL,
                       let size = try? FileManager.default.attributesOfItem(atPath: m.path)[.size] as? Int {
                        print("    Real-source module:   \(m.path) (\(byteString(size)))")
                    }
                    // P0 ship-plumbing: did the additive exports get merged into the
                    // single shippable module.wasm (so `push`/`release` ship the gain)?
                    if result.realSourceMergedIntoDefault {
                        print("    Merged into module:   ✓ real-source exports are in module.wasm (ship with `Patch push`)")
                    } else if result.realSourceCompiledUnits > 0 {
                        print("    Merged into module:   ✗ could not combine — real-source exports NOT in module.wasm.")
                        print("                          (Set PATCH_REAL_SOURCE_VERBOSE=1 to see why; the default module still ships.)")
                    }
                }

                // SwiftUI body lowering (on by default) — reported like OTA units.
                if result.loweredViewBodies > 0 || result.swiftUIModuleURL != nil {
                    print("\n  SwiftUI lowering:")
                    let pct = result.loweredViewElements > 0
                        ? Double(result.loweredViewElementsWasm) / Double(result.loweredViewElements) * 100 : 0
                    print("    View bodies lowered:  \(result.loweredViewBodies)  (View.body → WASM view_body export)")
                    print(String(format: "    Body elements → WASM: %d/%d  (%.1f%% ride WASM; rest are native-fallback)",
                                 result.loweredViewElementsWasm, result.loweredViewElements, pct))
                    for v in result.loweredViews {
                        let vp = v.elements > 0 ? Double(v.wasm) / Double(v.elements) * 100 : 0
                        print(String(format: "      - %@ → %@  (%d/%d, %.0f%%)", v.view, v.export, v.wasm, v.elements, vp))
                    }
                    if let m = result.swiftUIModuleURL,
                       let size = try? FileManager.default.attributesOfItem(atPath: m.path)[.size] as? Int {
                        print("    SwiftUI module:       \(m.path) (\(byteString(size)))")
                    }
                    if result.swiftUIMergedIntoDefault {
                        print("    Merged into module:   ✓ view_body export is in module.wasm (ship with `Patch push`)")
                    } else if result.loweredViewBodies > 0 {
                        print("    Merged into module:   ✗ could not combine — view_body NOT in module.wasm.")
                        print("                          (Set PATCH_REAL_SOURCE_VERBOSE=1 to see why; the default module still ships.)")
                    }
                }
            }
        }

        // ---- HOST-BRIDGE INTEGRATION (Lever #2, opt-in PATCH_HOST_BRIDGE=1) -----
        // When the host-bridge lowering routed at least one symbol it wrote the
        // App-Store-clean resolver thunk (`PatchHostBridges.generated.swift`). Wire
        // it INTO the app exactly like the SwiftUI thunk: add the file to the target
        // + link the PatchSDK product (pbxproj AND Package.swift, backup/verify/
        // restore-on-fail) and inject the one-time
        // `Patch.shared.onRegisterHostBridges(__patchRegisterHostBridges)` install
        // into the app entry. Idempotent; flag-OFF (the usual case) is a no-op.
        if HostBridgeProjectIntegrator.isEnabled(), let thunkURL = result.hostBridgeThunkURL {
            Self.integrateHostBridge(
                generatedFileInBuildDir: thunkURL,
                root: prepareRoot, target: prepareTarget,
                routedSymbols: result.hostBridgeRoutedSymbols)
        }

        // Optional JSON report.
        if let report {
            let obj = reportJSON(result)
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: report))
            print("\nWrote report: \(report)")
        }
    }

    private func printCoverage(_ report: CoverageReport, split: [String]) {
        let registrySize = NativeRegistry.standard.count
        print("Coverage report:")
        print("  Files parsed:           \(report.fileCount)")
        print("  Functions analyzed:     \(report.functionCount)")
        print("  Native registry:        \(registrySize)")
        line("  WASM-eligible (pure)", report.count(.wasmEligible), report.functionCount)
        line("  WASM-eligible (bridged)", report.count(.bridged), report.functionCount)
        line("  Mixed (auto-split)", report.count(.mixed), report.functionCount)
        line("  Native (stays in shell)", report.count(.native), report.functionCount)
        let realizedOTA = report.count(.wasmEligible) + report.count(.bridged) + split.count
        let pct = report.functionCount > 0 ? Double(realizedOTA) / Double(report.functionCount) * 100 : 0
        print(String(format: "  OTA-updatable (realized): %.1f%%  (%d mixed actually split)", pct, split.count))
        print(String(format: "  OTA-updatable (optimistic): %.1f%%", report.otaUpdatablePercent))
    }

    private func line(_ label: String, _ count: Int, _ total: Int) {
        let pct = total > 0 ? Double(count) / Double(total) * 100 : 0
        print(String(format: "%@ %4d  (%.1f%%)", label.padding(toLength: 28, withPad: " ", startingAt: 0), count, pct))
    }

    private func reportJSON(_ result: BuildPipeline.Result) -> [String: Any] {
        let r = result.report
        var obj: [String: Any] = [
            "files": r.fileCount,
            "functions": r.functionCount,
            "wasmEligible": r.count(.wasmEligible),
            "bridged": r.count(.bridged),
            "mixed": r.count(.mixed),
            "native": r.count(.native),
            "mixedSplit": result.splitFunctions.count,
            "exportSymbols": result.exportSymbols,
            "otaUpdatablePercentOptimistic": r.otaUpdatablePercent,
            "packagingTierStart": result.selectedTier.rawValue,
            "packagingTierRationale": result.tierRationale,
        ]
        if let outcome = result.compileOutcome {
            obj["compiled"] = outcome.compiled.count
            obj["demotedToNative"] = outcome.reclassifiedNative.map { $0.functionID }
            if let ft = outcome.finalTier { obj["packagingTierFinal"] = ft.rawValue }
        }
        if let m = result.moduleURL { obj["module"] = m.path }
        if result.loweredViewBodies > 0 || result.swiftUIModuleURL != nil {
            obj["swiftUILoweredViewBodies"] = result.loweredViewBodies
            obj["swiftUILoweredElements"] = result.loweredViewElements
            obj["swiftUILoweredElementsWasm"] = result.loweredViewElementsWasm
            obj["swiftUIExports"] = result.swiftUIExports
            obj["swiftUIMergedIntoDefault"] = result.swiftUIMergedIntoDefault
            if let m = result.swiftUIModuleURL { obj["swiftUIModule"] = m.path }
        }
        return obj
    }

    private func byteString(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return "\(n) bytes"
    }

    /// Read the overlay spec + wrap the built module in place (the same wrap
    /// `patchcli overlay package` does). Throws a friendly error on a bad spec.
    ///
    /// Shared (static) so `Patch release` wraps the module IDENTICALLY to
    /// `Patch build` — a release must never ship a different artifact than a
    /// build of the same sources (the overlay would otherwise be silently
    /// dropped from `release`).
    static func packageOverlay(specURL: URL, moduleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: specURL.path) else {
            throw ValidationError("Overlay spec (from .Patch.yml `overlay:`) not found at \(specURL.path).")
        }
        let table: PatchResourceOverlay.Table
        do { table = try OverlaySpecReader.load(from: specURL) }
        catch { throw ValidationError("Could not read overlay spec at \(specURL.path): \(error)") }
        guard !table.isEmpty else {
            print("\nResource overlay: spec \(specURL.lastPathComponent) is empty — module left unwrapped.")
            return
        }
        let inner = [UInt8](try Data(contentsOf: moduleURL))
        // Unwrap a prior POVR wrapper (re-build) so we never nest.
        let innerWasm = PatchOverlayArtifact.decode(inner)?.inner ?? inner
        let wrapped = PatchOverlayArtifact.package(inner: innerWasm, table: table)
        try Data(wrapped).write(to: moduleURL)
        print("\nResource overlay (from .Patch.yml `overlay:`):")
        print("  Spec:    \(specURL.path)")
        print("  Colors:  \(table.colors.count)   Strings: \(table.stringCount) (\(table.strings.count) locale(s))   Images: \(table.images.count)")
        print("  Wrapped into \(moduleURL.lastPathComponent) (\(byteStringStatic(wrapped.count))) — ships with `patchcli push`.")
    }

    /// Static byte formatter for `packageOverlay` (the instance `byteString`
    /// can't be called from a static context). Same output.
    static func byteStringStatic(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return "\(n) bytes"
    }

    /// Instance wrapper kept for the `build` call site.
    private func packageOverlay(specURL: URL, moduleURL: URL) throws {
        try Self.packageOverlay(specURL: specURL, moduleURL: moduleURL)
    }

    private func tierLabel(_ tier: PackagingTier) -> String {
        switch tier {
        case .t0Embedded:  return "T0 Embedded + bridges (\(tier.approxBrotliFloor))"
        case .t1Stdlib:    return "T1 stdlib-only (\(tier.approxBrotliFloor))"
        case .t2Foundation: return "T2 full Foundation (\(tier.approxBrotliFloor))"
        }
    }

    // MARK: - Host-bridge integration (Lever #2, PATCH_HOST_BRIDGE=1)

    /// Wire the engine-generated host-bridge resolver thunk into the app: copy it
    /// from the (gitignored) build dir into the source-tree `Patch/Generated/`
    /// folder so it compiles into the app target, gitignore it, wire it into the
    /// target (pbxproj AND Package.swift, backup/verify/restore-on-fail), and inject
    /// the one-time `Patch.shared.onRegisterHostBridges(__patchRegisterHostBridges)`
    /// install into the app entry. Idempotent + best-effort: any project shape it
    /// can't edit with certainty degrades to a printed manual instruction (never a
    /// corrupting guess). Build is non-interactive, so the registrar edit prints its
    /// diff and applies it (with backup), matching the auto-prepare posture.
    static func integrateHostBridge(
        generatedFileInBuildDir buildFileURL: URL, root: URL, target: String?,
        routedSymbols: Int
    ) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: buildFileURL.path) else { return }

        print("\nHost bridge (Lever #2, PATCH_HOST_BRIDGE): routed \(routedSymbols) symbol(s).")

        // (1) Place the generated file in the source tree (the build-dir copy is
        //     gitignored + outside the compile set). The dedicated Patch/Generated/
        //     folder is the same one `prepare` uses for the SwiftUI thunk — keep the
        //     developer's own sources clean. Gitignore it.
        let genDir = root.appendingPathComponent(Prepare.generatedFolderName)
        let genURL = genDir.appendingPathComponent(HostBridgeProjectIntegrator.generatedFileName)
        do {
            try fm.createDirectory(at: genDir, withIntermediateDirectories: true)
            let contents = try String(contentsOf: buildFileURL, encoding: .utf8)
            // Idempotent: only rewrite when the content changed.
            let existing = try? String(contentsOf: genURL, encoding: .utf8)
            if existing != contents {
                try contents.write(to: genURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("→ Couldn't place \(HostBridgeProjectIntegrator.generatedFileName) (\(error)).")
            print("  Add \(buildFileURL.path) to your app target manually.")
            return
        }
        Prepare.ignoreGeneratedFolder(genDir: genDir, root: root, fm: fm, quiet: true)

        // (2) Wire the file + PatchSDK product into the target (both project shapes).
        integrateHostBridgeFile(root: root, target: target, fileURL: genURL, fm: fm)

        // (3) Inject the one-time registrar install into the app entry.
        installHostBridgeRegistrar(root: root, fm: fm)
    }

    /// Wire the host-bridge file into the build target — xcodeproj (Sources phase +
    /// PatchSDK product) or Package.swift (PatchSDK product; the file is in the
    /// source tree by location). Mirrors `Prepare.integrateIntoProject`.
    private static func integrateHostBridgeFile(root: URL, target: String?, fileURL: URL, fm: FileManager) {
        let rel = Prepare.relativePath(fileURL, root: root)
        let projects = (try? fm.contentsOfDirectory(atPath: root.path))?.filter { $0.hasSuffix(".xcodeproj") } ?? []

        if let projName = projects.first, let target {
            do {
                switch try HostBridgeProjectIntegrator.wireFile(
                    projectURL: root.appendingPathComponent(projName),
                    target: target, fileURL: fileURL, fm: fm) {
                case .added: print("✓ Added \(fileURL.lastPathComponent) + PatchSDK to target \(target).")
                case .alreadyPresent: print("✓ \(fileURL.lastPathComponent) + PatchSDK already wired into \(target).")
                case .notFound: break
                }
            } catch {
                print("→ Couldn't wire \(fileURL.lastPathComponent) into \(projName) automatically (\(error)).")
                print("  Add \(rel) to the \(target) target and link the PatchSDK product in Xcode.")
            }
            return
        }

        if fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path), let target {
            switch (try? HostBridgeProjectIntegrator.wirePackage(packageDir: root, target: target, fm: fm)) ?? .alreadyPresent {
            case .added: print("✓ Added the PatchSDK product to target \(target) in Package.swift.")
            case .alreadyPresent: print("✓ PatchSDK product present for target \(target).")
            case .notFound: break
            }
            return
        }

        print("→ Ensure \(rel) is compiled into your app target and the PatchSDK product is linked.")
    }

    /// Inject `Patch.shared.onRegisterHostBridges(__patchRegisterHostBridges)` into
    /// the app entry, right after `Patch.configure(…)`. Prints the diff and applies
    /// with backup/restore (build is non-interactive). Idempotent; falls back to a
    /// printed one-liner when there's no recognizable configure call to anchor on.
    private static func installHostBridgeRegistrar(root: URL, fm: FileManager) {
        switch HostBridgeProjectIntegrator.proposeRegistrar(in: root, fm: fm) {
        case .alreadyInstalled:
            print("✓ Host-bridge registrar already installed.")
        case .proposed(let injection):
            print("Installing the host-bridge registrar in \(injection.fileURL.lastPathComponent):")
            print(injection.diff)
            do {
                try HostBridgeProjectIntegrator.applyRegistrar(injection, fm: fm)
                print("✓ Installed \(HostBridgeProjectIntegrator.registrarInstallCall).")
            } catch {
                print("→ Couldn't write the registrar install (\(error)). Add this once at Patch.configure:")
                print("    \(HostBridgeProjectIntegrator.registrarInstallCall)")
            }
        case .notFound:
            print("→ Add this line once after Patch.configure(…) so the host bridge resolves on-device:")
            print("    \(HostBridgeProjectIntegrator.registrarInstallCall)")
        }
    }
}
