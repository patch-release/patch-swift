// SPDX-License-Identifier: Apache-2.0

import Foundation
import PartitioningEngine
import CodeGenerator
import SwiftParser

/// Orchestrates the REAL engine end-to-end for `Patch build` (Track F1):
///   parse → classify (PartitioningEngine) → split mixed functions
///   (FunctionSplitter) → emit `_wasm.swift` (CodeEmitter) → compile to a real
///   `.wasm` (WasmCompiler via WasmConvergence).
///
/// The pipeline is library code (not the CLI command) so it is unit-testable and
/// reusable. It performs no I/O beyond the source directory and the configured
/// output/work directories.
/// [R2-#9/#10/#11/#34/#35/#36] The authoritative record of what a build ACTUALLY shipped
/// OTA — written by `BuildPipeline.run` to `<buildDir>/shipped-ota.json` and read by
/// `ProjectFingerprinter.snapshot`. The fingerprint strips a view/cell/function body ONLY
/// when this manifest confirms the build shipped it; a body the build DROPPED to native
/// stays hashed verbatim, so a later edit to it churns the native-shell fingerprint (the
/// native rebuild the device truly needs). Absent manifest → the fingerprint strips nothing
/// (the conservative fallback when no successful build has run yet).
public struct ShippedOTAManifest: Codable, Sendable, Equatable {
    public static let fileName = "shipped-ota.json"
    /// View type names whose lowered `var body` actually rode WASM + shipped (survived the
    /// guest-compile bisect + convergence). ONLY these bodies may be stripped.
    public var shippedSwiftUIViews: [String]
    /// Cell/VC type names whose declarative construction method actually shipped OTA.
    public var shippedUIKitCells: [String]
    /// Whether the general-logic (`wasmEligible`) WASM module compiled CLEAN (a real module,
    /// no demotions, no CORE failure). When false, the fingerprint hashes every wasmEligible
    /// body verbatim (it can't tell which function dropped) — over-conservative, never
    /// false-stable.
    public var generalLogicTrusted: Bool

    /// [divergence-fix] A content hash over the developer's full `.swift` source set
    /// (raw bytes, path-sorted) at the moment this manifest was written. Lets a later
    /// `fingerprint diff` decide whether the manifest is STILL FRESH against the current
    /// source — if any source byte changed, the manifest's shipped-set / trust verdict may
    /// no longer reflect what a build would now ship, so diff rebuilds (or, sans toolchain,
    /// prints an explicit "estimate" warning) rather than reuse a stale verdict. Optional so
    /// a manifest written by an OLDER patchcli (no field) decodes fine; an absent value reads
    /// as "freshness unknown" → diff treats it as stale (conservative). Computed by
    /// `Self.sourceSetHash(projectDir:)`.
    public var sourceHash: String?

    public init(shippedSwiftUIViews: [String], shippedUIKitCells: [String],
                generalLogicTrusted: Bool, sourceHash: String? = nil) {
        self.shippedSwiftUIViews = shippedSwiftUIViews
        self.shippedUIKitCells = shippedUIKitCells
        self.generalLogicTrusted = generalLogicTrusted
        self.sourceHash = sourceHash
    }

    /// Read the manifest a prior build wrote under `projectDir/.Patch/build/`. Returns nil
    /// when no successful build has run (the fingerprint then strips nothing — conservative).
    public static func read(projectDir: URL) -> ShippedOTAManifest? {
        let url = projectDir
            .appendingPathComponent(".Patch")
            .appendingPathComponent("build")
            .appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(ShippedOTAManifest.self, from: data) else { return nil }
        return m
    }

    /// [divergence-fix] A deterministic content hash over EVERY developer `.swift` source
    /// the lowering ingests (raw bytes, path-sorted) — the freshness key for `sourceHash`.
    /// Built from the SHARED `crossFileLoweringSources` set so it tracks EXACTLY the files
    /// whose content drives the build's shipped-set / general-trust verdict. A change to any
    /// of these bytes flips the hash → a stored manifest with a different `sourceHash` is
    /// stale (its verdict may no longer match a fresh build). Conservative by construction:
    /// it over-invalidates on an OTA-only body edit (which is exactly what we want — diff
    /// must reflect BUILD truth, and a body edit CAN change whether a view still lowers).
    public static func sourceSetHash(projectDir: URL, excludes: [String] = []) -> String {
        let sources = ProjectFingerprinter.crossFileLoweringSources(
            projectDir: projectDir, excludes: excludes)
        // `crossFileLoweringSources` already returns `(key: standardizedPath, source)`
        // SORTED by path, so this join is order-deterministic. Hash `path\u{0}body` per
        // file (the NUL separates path from body so a rename vs. an edit can't collide).
        let joined = sources.map { "\($0.key)\u{0}\($0.source)" }.joined(separator: "\u{1}")
        return Fingerprinter.hash(joined)
    }

    /// [divergence-fix] Is THIS manifest still fresh against the current source set?
    /// True only when it carries a `sourceHash` that equals the current
    /// `sourceSetHash(projectDir:)`. An absent `sourceHash` (older patchcli / hand-written
    /// manifest) reads as NOT fresh — diff then rebuilds or warns rather than trusting a
    /// verdict it can't validate.
    public func isFresh(projectDir: URL, excludes: [String] = []) -> Bool {
        guard let sourceHash else { return false }
        return sourceHash == Self.sourceSetHash(projectDir: projectDir, excludes: excludes)
    }
}

public struct BuildPipeline {
    public let registry: NativeRegistry

    public init(registry: NativeRegistry = .standard) {
        self.registry = registry
    }

    /// [R2-#95] View names `patchcli prepare`'s `ThunkGenerator` will NOT thunk because a
    /// non-View struct shares the name (2+ top-level struct decls of that name) OR it's a
    /// generic view carrying a `where` clause. Such a view renders NATIVE on device (no
    /// `@_dynamicReplacement` thunk), even though the engine's collision check (which counts
    /// only View-conforming lowered types) would otherwise ship + mark it `thunkSafe`. The
    /// build/fingerprint must not auto-route a view prepare can't thunk. Computed from the
    /// shared lowering sources (`crossFileLoweringSources` texts).
    public static func thunkIneligibleViewNames(sources: [String]) -> Set<String> {
        // Approximates `ThunkGenerator.discover`'s top-level struct counting (that type is
        // internal to CodeGenerator). Count TOP-LEVEL `struct` decls per name across the
        // source set; a name declared 2+ times (a View + a same-named non-View model) gets
        // NO prepare thunk → renders native, so the build/fingerprint must not auto-route
        // it. "Top-level" is approximated by `struct ` / `<access> struct ` at the START of
        // a line (no leading indentation — a nested type is indented). Conservative: a true
        // nested same-named struct is rare and only LOWERS coverage here, never false-stable.
        var structDeclCounts: [String: Int] = [:]
        for src in sources {
            for rawLine in src.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                // Must start at column 0 (no leading whitespace) to be top-level.
                guard let first = line.first, first != " ", first != "\t" else { continue }
                var toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                // Drop leading access/modifier keywords so `public struct X` / `final struct X`
                // still match; keep scanning until we hit `struct`.
                let modifiers: Set<String> = ["public", "private", "fileprivate", "internal",
                                              "open", "final", "indirect"]
                while let head = toks.first, modifiers.contains(head) { toks.removeFirst() }
                guard toks.count >= 2, toks[0] == "struct" else { continue }
                let name = toks[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { structDeclCounts[String(name), default: 0] += 1 }
            }
        }
        var ineligible = Set<String>()
        for (name, n) in structDeclCounts where n > 1 { ineligible.insert(name) }
        return ineligible
    }

    public struct Result: Sendable {
        public let report: CoverageReport
        /// `mixed` functions for which the splitter produced a real plan.
        public let splitFunctions: [String]
        /// Generated `_wasm.swift` files written to the build dir.
        public let generatedWasmSources: [URL]
        /// Generated `_bridge.swift` files written to the build dir.
        public let generatedBridgeSources: [URL]
        /// Fragment export symbols offered to the compiler.
        public let exportSymbols: [String]
        /// Final compile outcome (nil if `--dry-run` skipped the compile).
        public let compileOutcome: WasmConvergence.Outcome?
        /// The emitted `.wasm` path (nil if dry-run / nothing compiled / no toolchain).
        /// `var` so a CLEANLY-lowered SwiftUI/UIKit guest module can be PROMOTED to be
        /// the shipped `module.wasm` when the default general-logic convergence produced
        /// none (otherwise `release` throws "nothing to release" and the patch is lost).
        public var moduleURL: URL?
        /// The smallest packaging tier the classifier picked for the module (the
        /// start tier handed to the convergence loop). T0 Embedded is the default.
        public let selectedTier: PackagingTier
        /// Why that tier (the deciding factor — grep result / embedded blockers).
        public let tierRationale: String
        /// Pure exports the dependency-closure bundler rejected (kept native):
        /// (export name, reason). For an honest build report.
        public let rejectedExports: [(name: String, reason: String)]

        /// REAL-SOURCE additive path (PATCH_REAL_SOURCE=1). When the switch is on, the
        /// engine ALSO builds a second module of real-source-convertible pure exports
        /// the default engine could not ship; these fields report it. `nil`/0 when the
        /// switch is off — the default build is byte-identical.
        public var realSourceCompiledUnits: Int = 0
        /// The additional real-source module path (a second `.wasm`), nil when off /
        /// nothing extra compiled.
        public var realSourceModuleURL: URL? = nil
        /// Export symbols the real-source module added (beyond the default engine).
        public var realSourceAddedExports: [String] = []
        /// Whether the additive real-source module was MERGED into the shippable
        /// default `module.wasm` (the P0 ship-plumbing fix). When true, the single
        /// uploaded artifact carries BOTH the default and real-source exports, so the
        /// real-source gain ships by default. When false (no `wasm-merge`, or nothing
        /// extra to merge) the default module is untouched — the gain is reported but
        /// not shipped (never a regression).
        public var realSourceMergedIntoDefault: Bool = false

        // ---- SWIFTUI LOWERING (ON by default) -----------------------------------
        // Lowers `View.body` to the ViewNode IR and ships a guest `view_body` WASM
        // export (the proven swiftui-wasm lowering, wired into the production
        // engine). Like OTA units, the build REPORTS how much it lowered. ON by
        // default; all `0`/`nil`/empty when opted out (PATCH_SWIFTUI=0) or the
        // toolchain is unavailable.
        /// View bodies the engine lowered to a WASM `view_body` export.
        public var loweredViewBodies: Int = 0
        /// Total body ELEMENTS (nodes + modifiers) across the lowered views.
        public var loweredViewElements: Int = 0
        /// The subset of those elements that ride WASM (the rest are `.opaque`
        /// native-fallback slots). `loweredViewElementsWasm / loweredViewElements`
        /// is the headline coverage (the proven package measured ~98.5%).
        public var loweredViewElementsWasm: Int = 0
        /// Per-view detail: (viewName, exportSymbol, elements, wasmElements).
        public var loweredViews: [(view: String, export: String, elements: Int, wasm: Int)] = []
        /// The separate SwiftUI guest module path (a `module.swiftui.wasm`), nil when
        /// nothing lowered / the toolchain is unavailable.
        public var swiftUIModuleURL: URL? = nil
        /// The `view_body*` export symbols the SwiftUI module added.
        public var swiftUIExports: [String] = []
        /// Whether the SwiftUI guest module was MERGED into the shippable
        /// `module.wasm` (so the `view_body` export ships through the normal upload
        /// path). False when `wasm-merge` is unavailable — reported but not shipped.
        public var swiftUIMergedIntoDefault: Bool = false

        // ---- UIKIT CELL LOWERING (ON by default, additive) ----------------------
        // Lowers a declarative UIKit cell's construction (`configure(with:)`) to the
        // UIKitNode IR and ships a guest `uikit_configure` WASM export. The UIKit
        // analogue of the SwiftUI lowering above; same demote-safe, report-what-lowered
        // contract. All `0`/`nil`/empty when no cell lowered or the toolchain is absent.
        /// Cell constructions the engine lowered to a `uikit_configure` export.
        public var loweredCells: Int = 0
        /// Per-cell detail: (cellName, exportSymbol).
        public var loweredCellDetail: [(cell: String, export: String)] = []
        /// The separate UIKit guest module path (`module.uikit.wasm`), nil when nothing
        /// lowered / the toolchain is unavailable.
        public var uikitModuleURL: URL? = nil
        /// The `uikit_configure*`/`patch_uikit_manifest` export symbols the module added.
        public var uikitExports: [String] = []
        /// Whether the UIKit guest module was MERGED into the shippable `module.wasm`.
        public var uikitMergedIntoDefault: Bool = false

        // ---- HOST-BRIDGE LOWERING (Lever #2, opt-in PATCH_HOST_BRIDGE=1) --------
        // The generalized "call what's already linked" path: for a function forced
        // native BECAUSE of bridgeable call sites, route each routable call through
        // the single `patch_host.call` import so the function's pure remainder can
        // lower instead of staying native. ADDITIVE + DEMOTE-SAFE + OPT-IN (default
        // OFF — flag-OFF builds are byte-identical). When on, the pass writes the
        // `patch_host_symbols.json` manifest + the App-Store-clean resolver-thunk
        // source (`PatchHostBridges.generated.swift`) into `.Patch/build/` and reports
        // which calls routed. All `0`/`nil`/empty when off / nothing routed.
        /// Native call sites routed through the generic host bridge (count of unique
        /// content-addressed symbols emitted into the manifest + the resolver thunk).
        public var hostBridgeRoutedSymbols: Int = 0
        /// The `patch_host_symbols.json` manifest path (nil when off / nothing routed).
        public var hostBridgeManifestURL: URL? = nil
        /// The generated resolver-thunk source path `prepare` inserts into the app
        /// target (`PatchHostBridges.generated.swift`), nil when off / all demoted.
        public var hostBridgeThunkURL: URL? = nil
        /// Per-routed-symbol detail: (functionID, canonicalSignature).
        public var hostBridgeRouted: [(functionID: String, signature: String)] = []
        /// Forced-native functions the pass examined (the headline denominator).
        public var hostBridgeExaminedForcedNative: Int = 0
        /// Forced-native functions that FLIPPED native→OTA: their bridgeable calls
        /// were spliced to the `patch_host.call` guest sequence and the rewritten
        /// body re-lowered (the re-split). THE Lever-#2 coverage-lift number.
        public var hostBridgeLoweredFunctions: Int = 0
        /// Per-lowered-function detail: (functionID, routedCallCount).
        public var hostBridgeLowered: [(functionID: String, routedCalls: Int)] = []
        /// The compiled generic-host-bridge guest sub-module (`module.hostbridge.wasm`)
        /// — the SHIP artifact that closes the Lever-#2 gap: the re-lowered bodies'
        /// routed `patch_host.call` sequences are PRESENT + INSTANTIABLE here, and it
        /// exports `patch_host_symbols`. Nil when off / nothing routed / the toolchain
        /// is unavailable (demote-safe — the rest of the patch still ships). This is a
        /// SEPARATE PMOD-additive sub-module (it never touches the default module).
        public var hostBridgeModuleURL: URL? = nil
        /// The `@_cdecl` exports the host-bridge sub-module added (the per-function
        /// probes + `patch_host_symbols` + the allocator).
        public var hostBridgeModuleExports: [String] = []

        // ---- WASM-OPT SIZE FINALIZE (default-on, safe) --------------------------
        // The shippable `module.wasm` is run through a feature-preserving
        // `wasm-opt -Oz --strip-debug --strip-producers` finalize pass (the last step
        // of `run`, AFTER the multi-memory lowering so it sees a single-memory module).
        // It strips debug/producer sections + size-optimizes with ZERO behavior change,
        // cutting the module ~25-30%. Best-effort: when `wasm-opt` is unavailable / the
        // result isn't smaller, the module is left intact and these fields report no
        // change (never a regression). All `0`/false when the module was never compiled.
        /// Whether the finalize pass shrank `module.wasm`.
        public var wasmOptimized: Bool = false
        /// `module.wasm` size before the finalize pass (bytes).
        public var moduleSizeBeforeOpt: Int = 0
        /// `module.wasm` size after the finalize pass (bytes). Equals the before-size
        /// when no optimization happened.
        public var moduleSizeAfterOpt: Int = 0

        /// [BUG-4] Whether the built module has NO real OTA coverage — i.e. it would
        /// ship to users without actually patching any code. Returns a human reason
        /// when degenerate, nil when the module carries genuine OTA exports. The
        /// `release` command refuses such a module by default (overridable with
        /// `--allow-empty`) so an empty patch isn't shipped silently.
        ///
        /// "Degenerate" means either of:
        ///   - the only shipped exports are infrastructure — the shared allocator
        ///     (`patch_malloc`/`patch_free`) and/or the fallback version probe
        ///     (`patch_module_version`), i.e. ZERO real function/view exports; or
        ///   - the module is suspiciously tiny (< 1 KiB), which a real compiled
        ///     Swift→WASM unit never is (the 317-byte E2E case). This backstop only
        ///     fires when the export check passed, so a reason is reported once.
        public func degenerateCoverageReason(moduleSize: Int?) -> String? {
            let infra: Set<String> = ["patch_malloc", "patch_free", "patch_module_version"]
            var shipped: Set<String> = []
            if let outcome = compileOutcome {
                for c in outcome.compiled { shipped.formUnion(c.exports) }
            } else {
                shipped.formUnion(exportSymbols)
            }
            // [BUG] Only count exports that ACTUALLY MERGED into the shipped
            // `module.wasm`. swiftUIExports/uikitExports/realSourceAddedExports are
            // populated whenever the lowering produced a guest module, but the merge
            // into `module.wasm` is best-effort (it silently no-ops on a binaryen-less
            // machine — the *MergedIntoDefault flag stays false). Counting an unmerged
            // export here would let the degenerate gate pass and `release` ship a
            // coverage-less module believing it has OTA coverage. Gate each union on its
            // merge flag so the reported export set is exactly what the shipped
            // container holds.
            if realSourceMergedIntoDefault { shipped.formUnion(realSourceAddedExports) }
            if swiftUIMergedIntoDefault { shipped.formUnion(swiftUIExports) }
            if uikitMergedIntoDefault { shipped.formUnion(uikitExports) }
            let realExports = shipped.subtracting(infra)

            if realExports.isEmpty {
                return "The module exports no patchable code (only the version probe / allocator)."
            }
            if let sz = moduleSize, sz < 1024 {
                return "The module is only \(sz) bytes — too small to contain real compiled OTA logic."
            }
            return nil
        }
    }

    /// Run the full pipeline.
    ///
    /// - Parameters:
    ///   - sourceDir: the app's source directory to analyze.
    ///   - buildDir: where generated sources + module.wasm land (e.g. `.Patch/build`).
    ///   - compiler: the WASM compiler (real `SwiftWasmCompiler` or a stub in tests).
    ///   - dryRun: when true, generate sources + report but skip the compile.
    ///   - outputModule: the EXACT `.wasm` path to write the linked module to. When
    ///     nil, the module lands at `buildDir/module.wasm` (the historical default).
    ///     Honors a `--output <path>` whose filename is not `module.wasm` (the
    ///     previous behaviour ignored the requested filename and always wrote
    ///     `module.wasm`).
    public func run(
        sourceDir: URL,
        buildDir: URL,
        compiler: WasmCompiling,
        dryRun: Bool,
        outputModule: URL? = nil,
        // SwiftUI lowering toggle (from .Patch.yml `swiftui`, default on). An
        // explicit PATCH_SWIFTUI env var still overrides it per-run.
        swiftUIEnabled: Bool = true
    ) throws -> Result {
        let engine = PartitioningEngine(registry: registry)
        let report = try engine.analyze(directory: sourceDir)

        // Native callee names so the splitter / sub-tree extractor keep native
        // helper calls in the shell. Same anchor set as Analyze.computeRealized:
        // every `native` function + every `forcesNative` record + any `mixed`
        // function that carries a native hit (a deep-forced helper reclassified to
        // mixed is still a boundary that must stay native). Conservative — keeping a
        // call native can only reduce fragments, never lift an unsafe statement.
        var nativeCalleeNames: Set<String> = []
        func simpleNameOf(_ id: String) -> String? {
            id.split(separator: ".").last.map(String.init)?
                .split(separator: "(").first.map(String.init)
        }
        for r in report.results where r.classification == .native {
            if let simple = simpleNameOf(r.functionID) { nativeCalleeNames.insert(simple) }
        }
        for (id, rec) in report.records where rec.forcesNative {
            if let simple = simpleNameOf(id) { nativeCalleeNames.insert(simple) }
        }
        for r in report.results where r.classification == .mixed && !r.nativeHits.isEmpty {
            if let simple = simpleNameOf(r.functionID) { nativeCalleeNames.insert(simple) }
        }
        let splitter = FunctionSplitter(registry: registry, nativeCalleeNames: nativeCalleeNames)
        let emitter = CodeEmitter()

        let fm = FileManager.default
        try fm.createDirectory(at: buildDir, withIntermediateDirectories: true)

        // [BUG-1] Invalidate stale generated artifacts BEFORE emitting this build's.
        // The build re-emits a generated file per function/export it produces THIS
        // run, but an artifact for something the PREVIOUS build produced and this one
        // does not (a renamed/removed export, a function that demoted, a type that is
        // no longer reconstructed) would otherwise survive as an ORPHAN — and be
        // re-ingested as source (poisoning classification/bundling) or re-compiled
        // into the module. That is the stale-build failure: a re-release after a
        // source edit ships a NEW sha that still runs OLD code. Clearing only the
        // engine's OWN generated files (never the developer's source, which never
        // lives under `.Patch/build`) makes every release start from a clean staging
        // dir, so a re-release ALWAYS reflects the current source. This is the
        // content-correct equivalent of "rm -rf .Patch/build" the report's clean
        // build performed manually, scoped so an unrelated file dropped in the dir is
        // left alone.
        Self.invalidateStagedArtifacts(in: buildDir, fm: fm)

        // Group mixed functions by file; parse each file's tree once.
        let mixed = report.results.filter { $0.classification == .mixed }
        var byFile: [URL: [String]] = [:]
        for r in mixed {
            guard let rec = report.records[r.functionID] else { continue }
            byFile[rec.sourceFile, default: []].append(r.functionID)
        }

        var wasmSources: [URL] = []
        var bridgeSources: [URL] = []
        var exportsBySource: [URL: [String]] = [:]
        var exportSymbols: [String] = []
        var splitFns: [String] = []
        // Pure exports rejected by the dependency-closure bundler (kept native) —
        // (export, reason). Surfaced in the build report so demotions are honest.
        var rejectedExports: [(String, String)] = []
        // Developer source files whose pure logic a pure-export wrapper calls into
        // — always compiled into the module (never demoted as candidates).
        var supportSources: Set<URL> = []

        // ---- (1) Mixed functions: split → fragment exports + rewired bridge ----
        // We generate the fragment sources here but DEFER admitting them to the
        // compile unit until the module closure is known (section 2 computes the
        // bundled value types). A mixed fragment that references an unbundled app
        // type (e.g. `Country`) or carries a generic `@_cdecl` export is filtered
        // out PRE-COMPILE and kept native — far faster + safer than feeding the
        // convergence demote loop a fragment that can never compile.
        struct PendingMixed {
            let id: String
            let wasmURL: URL
            let bridgeURL: URL
            let plan: SplitPlan
            let wasmSource: String   // probe copy (allocator-on) for the closure check
            let bridgeSource: String
            let exports: [String]
        }
        var pendingMixed: [PendingMixed] = []
        for (file, ids) in byFile.sorted(by: { $0.key.path < $1.key.path }) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Parse + index each file once; reuse across its mixed functions.
            let index = DeclarationIndex(source: source)
            for id in ids.sorted() {
                guard let rec = report.records[id] else { continue }
                var outcome: FunctionSplitter.Outcome = .noBody
                guard let plan = splitter.plan(for: rec, index: index,
                                               inferredTypes: report.inferredTypes[id] ?? [:],
                                               outcome: &outcome),
                      !plan.pureFragments.isEmpty,
                      !plan.nativeStatementsSummary.isEmpty else { continue }
                let files = emitter.emit(plan)
                let wasmURL = buildDir.appendingPathComponent(files.wasmFileName)
                let bridgeURL = buildDir.appendingPathComponent(files.bridgeFileName)
                pendingMixed.append(PendingMixed(
                    id: id, wasmURL: wasmURL, bridgeURL: bridgeURL, plan: plan,
                    wasmSource: files.wasmSource, bridgeSource: files.bridgeSource,
                    exports: files.exportSymbols))
            }
        }

        // ---- (2) Pure wasm-eligible functions: whole-function @_cdecl exports ----
        // The biggest auto-generation unlock: a pure app (no mixed split) ships its
        // real logic. We export each instance-less pure function across the JSON
        // (ptr,len) ABI and bundle the **transitive dependency closure** of its
        // value types + helper functions into the module (so the compile unit is
        // self-contained). DEPENDENCY-CLOSURE BUNDLING — the production-blocker fix:
        // we no longer drop the whole developer file (which references the app's own
        // types/UIKit/unavailable inits and never compiles standalone). The bundler
        // reconstructs only the needed value types as minimal Codable structs/enums
        // and emits only the needed pure functions; if an export's closure reaches a
        // class/protocol/native symbol it is REJECTED (stays native) — never broken.
        let pureByFile = pureEligibleByFile(report)
        let scanner = PureExportScanner()
        let bundler = DependencyClosureBundler(registry: registry)
        let allFiles = swiftFiles(in: sourceDir)
        let declIndex = bundler.index(for: allFiles)

        // BREAKTHROUGH-#7 generic-monomorphization context: feed the GenericSpecializer
        // the project-wide knowledge that unlocks instantiation beyond the fixed
        // `{Int,Double,String}` stdlib set. ADDITIVE + compile-or-demote: every new
        // instantiation still passes the isABICodable gate and is dropped by the real
        // WASM compile if it doesn't hold (proven zero-false-positive). Off when the
        // env opt-out is set (parity / debugging).
        let genericContext: GenericSpecializer.Context =
            ProcessInfo.processInfo.environment["PATCH_GENERICS_B7"] == "0"
            ? .empty
            : buildGenericContext(allFiles: allFiles, declIndex: declIndex)

        // The REAL-SOURCE CLOSURE COMPILATION path (opt-in: PATCH_REAL_SOURCE=1) is
        // ADDITIVE and runs at the END of `run` (after the default module is built):
        // it adds a second module of real-source-convertible pure exports the default
        // engine could not ship, so a canary can only GAIN units (never regress). See
        // the call site below the default convergence.
        var pureExportNames: Set<String> = []
        // Module-level closure, deduped across exports. VALUE TYPES and HELPER
        // functions (transitive, non-seed) are SHARED in one support file. Each
        // export's SEED function (the eligible function the classifier may have
        // over-approximated as pure) goes in that export's OWN candidate file, so a
        // seed that turns out non-self-contained demotes ONLY that export — never
        // the whole module. (This is what lets a module ship 1/2 functions when one
        // is genuinely impure.)
        var mergedTypes: [String] = []
        var mergedHelpers: [(name: String, enclosing: String?)] = []
        var mergedHelperKeys: Set<String> = []
        // Merged PURE MEMBER SURFACE across all shippable exports: `type → ordered
        // member names`. A value-type method/computed-property is reconstructed once
        // onto the shared bundled type (so a function calling `v.dot(u)` compiles).
        var mergedMembers: [String: [String]] = [:]
        var shippedClosures = 0
        // Value-type names freshly declared in the corpus — passed to the scanner so
        // an instance method declared in an `extension` of a value type (Euclid's
        // `Vector.dot`, in `extension Vector`) is recognised as a value-type-export
        // target (the scanner can't tell from the extension alone).
        let valueTypeNames: Set<String> = declIndex.valueTypeNames
        // Generic concrete-monomorphization (wave-2): verbatim generic definitions to
        // bundle once into the module, deduped by definitionKey. The native body of a
        // generic library function is emitted UNCHANGED; only the @_cdecl wrapper is
        // concrete (it calls the generic at e.g. `[Int]`, which Swift monomorphizes).
        var genericDefs: [String: String] = [:]   // definitionKey → verbatim source
        let genericFileSafe: [String: Bool] = [:]  // definitionKey → imports-safe?
        var genericSpecCount = 0
        // SELF-FREE instance methods lowered to receiver-less free functions. The
        // synthetic free-function definition is INLINED into its own candidate file
        // (self-contained: wrapper + free fn), so a body referencing a native/external
        // symbol demotes ALONE. Counter only (for the build summary).
        var selfFreeCount = 0
        // FUSION × self-free COMPOSITION: a self-free body that touches a canonical
        // bridgeable Foundation builder (`RelativeDateTimeFormatter`,
        // `Calendar.current.startOfDay`, a `NumberFormatter`/regex builder) is
        // rewritten to a `patch_host.*` host bridge BEFORE emission — exactly the join
        // that lets `SettingsScreen.relativeString` ship instead of demoting
        // (`RelativeDateTimeFormatter` does not exist in WASM-corelib Foundation, so
        // the verbatim body could never compile at any tier). The fired leaf ids are
        // collected so we emit ONE shared fusion-shim support file (importing CHost,
        // whose header now declares the fusion flat-import ABI). Demote-safe: the
        // rewriter only fires on the exact canonical shape; an unusual/configured
        // formatter is left verbatim and demotes alone as before.
        var firedFusionLeaves = Set<String>()
        let fusionRewriter = FusionRewriter()
        // The set of module source files whose imports are ALL WASM-safe (no external
        // library like `RealModule`). A generic specialization is bundled by shipping
        // this whole intra-module closure verbatim — that resolves transitive sibling
        // helpers (`partitioningIndex`, `_minImplementation`, …) the way the library
        // itself compiles. A file whose imports are NOT all safe is excluded; a spec
        // whose defining file is excluded is left native (conservative).
        let safeLibraryFiles: [URL] = allFiles.filter { url in
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return genericFileImportsSafe(s)
        }
        let safeLibraryFilePaths = Set(safeLibraryFiles.map { $0.path })
        // Type names DEFINED in the bundled library closure. When that closure is
        // shipped (a generic spec admitted), these types' REAL definitions are already
        // present in `_PatchGenerics.swift`, so the separate value-type / operator
        // RECONSTRUCTION (`_PatchClosure.swift`) is redundant AND can be broken for a
        // generic-nested type (e.g. swift-algorithms' `Index` whose fields are
        // `Base.Index`). We suppress those reconstructions / operator exports to avoid
        // poisoning the shared module — the library's own copy is authoritative.
        var bundledLibraryTypeNames: Set<String> = []
        for f in safeLibraryFiles {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            collectDeclaredTypeNames(s, into: &bundledLibraryTypeNames)
        }
        // PRE-PASS: will the whole-library generic closure actually ship? Only then is
        // suppressing a library type's reconstruction correct (the bundle carries its
        // real definition). If NO generic spec is admittable, we must NOT suppress —
        // doing so would silently drop working operator/value exports (Euclid/Alamofire
        // regression). A spec is admittable iff its defining file is import-safe and the
        // scanner produced ≥1 genericSpec export for some eligible function.
        var willShipLibraryBundle = false
        for (file, names) in pureByFile {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let exps = scanner.scan(source: source, eligibleSimpleNames: names,
                                    valueTypeNames: valueTypeNames, bundleKey: file.path,
                                    genericContext: genericContext)
            if exps.contains(where: { $0.genericSpec != nil }) && safeLibraryFilePaths.contains(file.path) {
                willShipLibraryBundle = true; break
            }
        }
        // The suppression set is empty unless the library bundle actually ships.
        let suppressLibraryTypes: Set<String> = willShipLibraryBundle ? bundledLibraryTypeNames : []
        struct PendingPure { let wasmURL: URL; let baseSource: String; let seedFns: [(name: String, enclosing: String?)]; let exports: [String] }
        var pendingPure: [PendingPure] = []
        for (file, names) in pureByFile.sorted(by: { $0.key.path < $1.key.path }) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let scannedForFile = scanner.scan(source: source, eligibleSimpleNames: names,
                                              valueTypeNames: valueTypeNames, bundleKey: file.path,
                                              genericContext: genericContext)
            // VALUE-TYPE RECEIVER AT T0: enrich each export with its receiver / value-type-arg
            // reconstruction shape so a flat-scalar instance method (Euclid `v.dot(u)`,
            // `v.length`) can ride the embedded host-bridge (T0) wrapper instead of the
            // Foundation (T2) one. A non-reconstructable boundary gets no shape → unchanged T2.
            let exportsForFile = scannedForFile.map {
                enrichValueTypeShapes($0, bundler: bundler, index: declIndex)
            }
            guard !exportsForFile.isEmpty else { continue }
            for export in exportsForFile where !pureExportNames.contains(export.exportName) {
                // ---- Generic concrete-monomorphization export -----------------------
                // The seed body is GENERIC (cannot pass the bundler's no-generic gate),
                // so we DON'T compute a function closure for it. We bundle its verbatim
                // definition + the concrete boundary types, then verify self-containment
                // (the verbatim body must reference only bundled / stdlib / WASM-safe
                // symbols) — exactly the conservative gate used for mixed fragments.
                if let gspec = export.genericSpec {
                    let sigTypes = signatureNominalTypes(of: export)
                    // Bundle the concrete boundary VALUE types (Int/String/etc. are
                    // leaves; any user value type in the boundary is reconstructed).
                    let typeClo = bundler.closureForTypes(
                        exportName: export.exportName, signatureTypes: sigTypes, index: declIndex)
                    guard typeClo.shippable else {
                        rejectedExports.append((export.exportName, typeClo.rejectionReason ?? "generic boundary unbundlable"))
                        continue
                    }
                    // SELF-CONTAINMENT GATE (conservative, no false positives): the
                    // generic body lives in the module's intra-library closure, which
                    // we bundle as the WHOLE set of WASM-safe-import source files
                    // (`safeLibraryFiles`) so transitive sibling helpers resolve the
                    // way the library compiles. A spec whose DEFINING file imports a
                    // non-WASM-safe module (e.g. `RandomSample.swift` → `RealModule`)
                    // is excluded and left native.
                    _ = genericFileSafe  // (cache kept for symmetry; gate is the set below)
                    guard safeLibraryFilePaths.contains(gspec.definitionKey) else {
                        rejectedExports.append((export.exportName, "generic defining file imports a non-WASM-safe module"))
                        continue
                    }
                    pureExportNames.insert(export.exportName)
                    for t in typeClo.neededTypes where !mergedTypes.contains(t) && !suppressLibraryTypes.contains(t) { mergedTypes.append(t) }
                    // Bundle the whole safe intra-library closure ONCE (keyed by a
                    // module-wide sentinel), verbatim, so every spec's generic body +
                    // its transitive helpers compile. Swift monomorphizes each concrete
                    // wrapper call automatically.
                    if genericDefs["__module_closure__"] == nil {
                        var merged = ""
                        for f in safeLibraryFiles.sorted(by: { $0.path < $1.path }) {
                            if let s = try? String(contentsOf: f, encoding: .utf8) {
                                merged += "// ---- " + f.lastPathComponent + " ----\n" + stripImports(s) + "\n\n"
                            }
                        }
                        genericDefs["__module_closure__"] = merged
                    }
                    genericSpecCount += 1
                    shippedClosures += 1
                    let (fileName, src, exports) = emitPureExport(
                        emitter, export, sigTypes: sigTypes, includeAllocator: false)
                    let wasmURL = buildDir.appendingPathComponent(fileName)
                    pendingPure.append(PendingPure(
                        wasmURL: wasmURL, baseSource: src, seedFns: [], exports: exports))
                    continue
                }

                // ---- SELF-FREE instance-method export (receiver-less free fn) -------
                // A self-free instance method (`SettingsScreen.relativeString`) is
                // lowered to a synthetic FREE function whose body references only its
                // params. We bundle that verbatim definition + the boundary VALUE types
                // (a Date/String boundary is scalar-leaf; a user value-type param/return
                // is reconstructed). The synthetic function is NOT in the on-disk index,
                // so we drive a TYPE-ONLY closure for its signature types (like the
                // operator/generic paths). DEMOTE-SAFE: if the body actually reaches
                // `self`/an instance member, the bundled free function fails to compile
                // and the convergence loop drops ONLY this export.
                if let sff = export.selfFreeFreeFunction {
                    let sigTypes = signatureNominalTypes(of: export)
                    let typeClo = bundler.closureForTypes(
                        exportName: export.exportName, signatureTypes: sigTypes, index: declIndex)
                    guard typeClo.shippable else {
                        rejectedExports.append((export.exportName, typeClo.rejectionReason ?? "self-free boundary unbundlable"))
                        continue
                    }
                    // Fix S1: prove the ABI boundary is Codable before emitting the wrapper.
                    let sffBundledCodable = Set(typeClo.neededTypes).union(mergedTypes)
                    if let bad = firstNonCodableBoundaryLeaf(of: export, bundledCodableTypes: sffBundledCodable) {
                        rejectedExports.append((export.exportName,
                            "ABI boundary type `\(bad)` is not provably Codable (kept native)"))
                        continue
                    }
                    pureExportNames.insert(export.exportName)
                    for t in typeClo.neededTypes where !mergedTypes.contains(t) && !suppressLibraryTypes.contains(t) { mergedTypes.append(t) }
                    for (t, ms) in typeClo.neededMembers {
                        var existing = mergedMembers[t] ?? []
                        for m in ms where !existing.contains(m) { existing.append(m) }
                        mergedMembers[t] = existing
                    }
                    selfFreeCount += 1
                    shippedClosures += 1
                    // The synthetic free function is INLINED into THIS export's own
                    // candidate file (not a shared support file). A self-free body that
                    // turns out to reference a native/external symbol (`Superwall`,
                    // `Entitlement`) — which the body-level self-free check (it only
                    // flags unbound LOWERCASE identifiers as implicit-self) cannot rule
                    // out for an UPPERCASE type reference — then fails to compile and the
                    // convergence loop demotes ONLY this export, never poisons the module.
                    let (fileName, src, exports) = emitPureExport(
                        emitter, export, sigTypes: sigTypes, includeAllocator: false)
                    var selfContained = src + "\n\n"
                        + "// SELF-FREE instance method lowered to a receiver-less free function.\n"
                        + sff.verbatimDefinition + "\n"
                    // FUSION rewrite: collapse a canonical bridgeable Foundation builder
                    // in the self-free body to its `patch_host.*` host-bridge shim. Only
                    // SYNC bridges are admitted here — an ASYNC bridge needs the executor
                    // continuation registry (CExec) the default compile unit doesn't link,
                    // and a self-free `async` body is classified separately anyway; admitting
                    // one would emit an undefined `_patchFusion*` shim and poison the unit.
                    let rw = fusionRewriter.rewrite(selfContained)
                    let firedHere = rw.bridgedLeaves
                    let anyAsyncFired = fusionRewriter.bridges(forLeaves: firedHere).contains { $0.isAsync }
                    if rw.didRewrite && !anyAsyncFired {
                        selfContained = rw.source
                        firedFusionLeaves.formUnion(firedHere)
                    }
                    let wasmURL = buildDir.appendingPathComponent(fileName)
                    pendingPure.append(PendingPure(
                        wasmURL: wasmURL, baseSource: selfContained, seedFns: [], exports: exports))
                    continue
                }
                // SUPPRESS reconstruction of a type that is ALREADY defined in the
                // bundled library closure (only relevant when that closure ships, i.e.
                // a generic spec was admitted). The library's real definition is
                // authoritative; a separate top-level reconstruction would duplicate it
                // and, for a generic-nested type (swift-algorithms' `Index` with
                // `Base.Index` fields), would be broken and poison the whole module.
                // Such an operator/value export is kept native; the type still ships its
                // real (generic) form inside the library bundle.
                let definingTypeForSuppression = export.operatorDefiningType ?? export.receiverType
                if !suppressLibraryTypes.isEmpty,
                   let dt = definingTypeForSuppression,
                   suppressLibraryTypes.contains(SymbolTable.leadingNominal(dt) ?? dt) {
                    rejectedExports.append((export.exportName, "type `\(dt)` ships in the bundled library closure (reconstruction suppressed)"))
                    continue
                }
                // Compute the dependency closure; skip (keep native) if unbundlable.
                var sigTypes = signatureNominalTypes(of: export)
                let clo: DependencyClosureBundler.ExportClosure
                if let opType = export.operatorDefiningType {
                    // Fix A integration: an OPERATOR can't be resolved as a free
                    // function by the bundler (operators aren't indexed as callees).
                    // Its definition rides along with the TYPE reconstruction (which
                    // carries the type's pure operator members), so bundle the
                    // defining type + boundary signature types — a TYPE-rooted
                    // closure with no function seed.
                    if !sigTypes.contains(opType) { sigTypes.insert(opType, at: 0) }
                    if let token = export.operatorToken {
                        // Seed the member-surface walk from the operator's body so the
                        // pure members it reaches (`==` → `compare` → `count`/`subscript`)
                        // are reconstructed and the operator isn't dropped.
                        clo = bundler.closureForOperator(
                            exportName: export.exportName, operatorToken: token,
                            definingType: opType, signatureTypes: sigTypes, index: declIndex)
                    } else {
                        clo = bundler.closureForTypes(exportName: export.exportName,
                                                      signatureTypes: sigTypes, index: declIndex)
                    }
                } else {
                    // An instance method's receiver type is part of the boundary
                    // closure; seed the bundler with the qualified `<Type>.<method>`.
                    let seedCallee: String
                    if let rt = export.receiverType {
                        if !sigTypes.contains(rt) { sigTypes.insert(rt, at: 0) }
                        seedCallee = "\(rt).\(export.callee)"
                    } else {
                        seedCallee = export.callee
                    }
                    clo = bundler.closure(exportName: export.exportName, callee: seedCallee,
                                          signatureTypes: sigTypes, index: declIndex)
                }
                guard clo.shippable else {
                    rejectedExports.append((export.exportName, clo.rejectionReason ?? "unbundlable"))
                    continue
                }
                // Fix S1: PROVE the ABI boundary is Codable before emitting the wrapper.
                // The closure is shippable, but a boundary leaf that is neither a known
                // Codable leaf nor a reconstructed (force-Codable) value type would make
                // the synthesized `_Args`/`_Out` conformance fail — LOUD on the guest,
                // but RED in the dev's Xcode build via the native-bridge mirror. Demote
                // to native instead (already ships as a non-exported function).
                let bundledCodable = Set(clo.neededTypes).union(mergedTypes)
                if let bad = firstNonCodableBoundaryLeaf(of: export, bundledCodableTypes: bundledCodable) {
                    rejectedExports.append((export.exportName,
                        "ABI boundary type `\(bad)` is not provably Codable (kept native)"))
                    continue
                }
                pureExportNames.insert(export.exportName)
                // Value types + ALL closure functions are SHARED (deduped) so a
                // helper/seed namespace (`enum Filter`) is declared exactly once.
                // The strengthened closure gate (rejects `self`/instance-state leaks)
                // keeps the shared file self-contained; an export whose closure isn't
                // bundlable was already rejected above (kept native).
                for t in clo.neededTypes where !mergedTypes.contains(t) && !suppressLibraryTypes.contains(t) { mergedTypes.append(t) }
                // Merge the pure member surface (dedup, preserve order) so each
                // value-type method/computed-property is reconstructed exactly once.
                for (t, ms) in clo.neededMembers {
                    var existing = mergedMembers[t] ?? []
                    for m in ms where !existing.contains(m) { existing.append(m) }
                    mergedMembers[t] = existing
                }
                // The SEED (first needed fn — the eligible function the classifier may
                // have over-approximated as pure) goes in THIS export's own candidate
                // file, so a seed that turns out non-self-contained (e.g. calls a
                // value-type method we didn't reconstruct) demotes ONLY this export.
                // Transitive HELPERS go in the shared, deduped helpers file.
                let seed = clo.neededFns.first
                let seedFns = seed.map { [$0] } ?? []
                for h in clo.neededFns.dropFirst() {
                    let k = "\(h.enclosing ?? "")::\(h.name)"
                    if mergedHelperKeys.insert(k).inserted { mergedHelpers.append(h) }
                }
                shippedClosures += 1
                // The pure-export wrapper (JSON ABI). The shared `_PatchRuntime.swift`
                // owns the single allocator, so wrappers never emit one.
                let (fileName, src, exports) = emitPureExport(
                    emitter, export, sigTypes: sigTypes, includeAllocator: false)
                let wasmURL = buildDir.appendingPathComponent(fileName)
                pendingPure.append(PendingPure(
                    wasmURL: wasmURL, baseSource: src, seedFns: seedFns, exports: exports))
            }
        }
        // ---- (1a2) Mixed-fragment value-type bundling pre-pass ------------------
        // A deferred mixed fragment is admitted today only if every type it references
        // is ALREADY bundled by some pure export (section 2). That leaves on the table
        // a real cluster of fragments whose ONLY unbound symbol is a clean, top-level,
        // Codable-storage VALUE TYPE the developer owns — e.g. NetNewsWire's
        // `_sp_createStarredEntries_prepare(_ entries: [Int]) -> FeedbinStarredEntry`
        // (construct a payload struct) and `plan.totalCount > 0` (read a scalar prop).
        // This pass tries to bundle each such fragment's unbound value types via the
        // SAME full closure machinery the pure path uses. A type is admitted ONLY if
        // its whole closure is shippable (the bundler validates stored-property /
        // member-surface / sibling-type / generic / native gates — zero false
        // negatives), so we never ship a type that can't compile. Fragments whose
        // unbound symbols include anything non-bundlable are left for section 1b to
        // demote, exactly as before.
        let bundleMixedValueTypes = ProcessInfo.processInfo.environment["PATCH_NO_MIXED_VT"] == nil
        if bundleMixedValueTypes {
            let already = Set(mergedTypes)
            // Collect the candidate value types across all pending mixed fragments,
            // each with the bundler's full closure verified shippable. Cache per type.
            var typeClosureCache: [String: DependencyClosureBundler.ExportClosure?] = [:]
            func shippableClosure(_ t: String) -> DependencyClosureBundler.ExportClosure? {
                if let c = typeClosureCache[t] { return c }
                let clo = bundler.closureForTypes(exportName: "_mvt_\(t)", signatureTypes: [t], index: declIndex)
                let result: DependencyClosureBundler.ExportClosure? = clo.shippable ? clo : nil
                typeClosureCache[t] = result
                return result
            }
            for pm in pendingMixed {
                guard let unbound = bundler.fragmentUnboundSymbols(in: pm.wasmSource, bundledTypes: already),
                      !unbound.isEmpty else { continue }
                // Every unbound symbol must be a bundlable value type whose full
                // closure ships — otherwise the fragment stays native (section 1b).
                var closures: [DependencyClosureBundler.ExportClosure] = []
                var allBundlable = true
                for sym in unbound {
                    if already.contains(sym) || mergedTypes.contains(sym) { continue }
                    guard let clo = shippableClosure(sym) else { allBundlable = false; break }
                    closures.append(clo)
                }
                guard allBundlable else { continue }
                // Merge the bundled types + member surface (dedup, preserve order),
                // exactly as the pure-export path does.
                for clo in closures {
                    for t in clo.neededTypes where !mergedTypes.contains(t) && !suppressLibraryTypes.contains(t) {
                        mergedTypes.append(t)
                    }
                    for (t, ms) in clo.neededMembers {
                        var existing = mergedMembers[t] ?? []
                        for m in ms where !existing.contains(m) { existing.append(m) }
                        mergedMembers[t] = existing
                    }
                }
            }
        }

        let bundledTypeNames = Set(mergedTypes)
        // Namespace enums (`enum ContactsDataStore`) carrying STATIC seed/helper
        // methods are NOT reconstructed value types and NOT system types. Each is
        // declared exactly ONCE in a shared support file (below); every seed/helper
        // method group then emits `extension <T> { … }` instead of redeclaring
        // `enum <T>`. Without this, two exports whose seed is a static method on the
        // same namespace each emit `enum <T>` → `invalid redeclaration` → the linker
        // blames both files → both demote → 0 units (the dominant large-app 0/N cause).
        let systemNames = DependencyClosureBundler.systemTypeNames
        // Real type declarations bundled verbatim in the module closure (_PatchGenerics):
        // a namespace `enum T {}` of the SAME name would `invalid redeclaration` / make
        // every use ambiguous and poison the whole module (tinode `class Tinode`,
        // PhoneNumberKit `struct PhoneNumber`, swift-collections `_HashTable`). Methods on
        // such a type still emit as `extension T`, but we must NOT also declare `enum T {}`.
        let verbatimDeclaredTypes = Self.topLevelTypeNames(in: genericDefs["__module_closure__"] ?? "")
        var namespaceTypes = Set<String>()
        for pp in pendingPure { for f in pp.seedFns { if let e = f.enclosing { namespaceTypes.insert(e) } } }
        for h in mergedHelpers { if let e = h.enclosing { namespaceTypes.insert(e) } }
        namespaceTypes.subtract(bundledTypeNames)
        namespaceTypes.subtract(systemNames)
        // Methods emit as `extension` for any type declared somewhere (the namespaces we
        // will declare + the real types in the verbatim closure).
        let declaredExtensionTypes = namespaceTypes.union(verbatimDeclaredTypes)
        for pp in pendingPure {
            var src = pp.baseSource
            // A seed whose enclosing type is declared verbatim in the closure is ALREADY
            // defined there (e.g. `PhoneNumber.notPhoneNumber`); re-emitting it as an
            // `extension` would `invalid redeclaration`. Skip it — the wrapper calls the
            // closure's definition directly.
            let seedsToEmit = pp.seedFns.filter { $0.enclosing == nil || !verbatimDeclaredTypes.contains($0.enclosing!) }
            let seedSrc = bundler.emitExportFunctions(fns: seedsToEmit, index: declIndex,
                                                      bundledTypes: bundledTypeNames, surfaceMembers: mergedMembers,
                                                      declaredExtensionTypes: declaredExtensionTypes)
            if !seedSrc.isEmpty { src += "\n\n" + seedSrc }
            try src.write(to: pp.wasmURL, atomically: true, encoding: .utf8)
            wasmSources.append(pp.wasmURL)
            exportsBySource[pp.wasmURL] = pp.exports
            exportSymbols.append(contentsOf: pp.exports)
        }
        // The SHARED support file: the allocator + reconstructed Codable value types
        // (with pure member surface) + deduped transitive helper functions. Always
        // present (the allocator never rides a demotable candidate).
        // Tracks whether the single module allocator has been emitted (by the shared
        // runtime file, or — when only mixed/value-lift ship — by the first such file).
        var firstPureFileEmitted = false
        if shippedClosures > 0 {
            let runtime = emitter.emitModuleRuntimeFile()
            let runtimeURL = buildDir.appendingPathComponent(runtime.fileName)
            try runtime.source.write(to: runtimeURL, atomically: true, encoding: .utf8)
            supportSources.insert(runtimeURL)
            exportSymbols.append(contentsOf: runtime.exports)
            firstPureFileEmitted = true  // shared runtime owns the allocator

            // FUSION × self-free: emit ONE shared shim support file for the bridges a
            // self-free body fired. The shims `import CHost` (whose header declares the
            // fusion flat-import ABI) + the developer's rewritten body calls them. A
            // broken shim can't happen (the shims are pre-proven), so one shared file is
            // safe; if no self-free body fired a bridge the file is never written.
            if !firedFusionLeaves.isEmpty {
                let firedBridges = fusionRewriter.bridges(forLeaves: firedFusionLeaves)
                let shimSrc = fusionRewriter.swiftBridgeSource(
                    for: firedBridges, cTargetName: CHeaderBridge.cTargetName)
                let shimURL = buildDir.appendingPathComponent("_PatchFusionShims.swift")
                try ("// Auto-generated by Patch — FUSION host-bridge shims for self-free /\n"
                     + "// pure exports. The CHost C target declares the flat imports. DO NOT EDIT.\n\n"
                     + shimSrc).write(to: shimURL, atomically: true, encoding: .utf8)
                supportSources.insert(shimURL)
            }

            // Emit each transitive helper as its OWN isolatable support file
            // (`_PatchHelper_<i>_<name>.swift`). A broken helper (one that reads
            // instance state, or calls a member of an incompletely-reconstructed type)
            // is then DROPPED by the convergence loop instead of poisoning the whole
            // module via the shared-helpers core file — the clean candidates (e.g. a
            // font-size export) still ship. Each file is one `extension <T> { func }`
            // (or a free func); <T> is declared once in _PatchNamespaces or is a
            // bundled/system type, so multiple single-method extensions never collide.
            for (i, h) in mergedHelpers.enumerated() {
                // A helper already declared verbatim in the closure must not be re-emitted
                // (invalid redeclaration). The closure carries its definition.
                if let e = h.enclosing, verbatimDeclaredTypes.contains(e) { continue }
                let src = bundler.emitExportFunctions(
                    fns: [h], index: declIndex, bundledTypes: bundledTypeNames,
                    surfaceMembers: mergedMembers, declaredExtensionTypes: declaredExtensionTypes)
                guard !src.isEmpty else { continue }
                let safe = String(("\(h.enclosing ?? "free")_\(h.name)").map { ($0.isLetter || $0.isNumber) ? $0 : "_" })
                let hURL = buildDir.appendingPathComponent("_PatchHelper_\(i)_\(safe).swift")
                try ("// Auto-generated by Patch — isolatable pure helper. DO NOT EDIT.\nimport Foundation\n\n" + src)
                    .write(to: hURL, atomically: true, encoding: .utf8)
                supportSources.insert(hURL)
            }

            // Declare each namespace enum exactly once (empty) in a shared support
            // file; the seed/helper extensions above attach the methods. An empty enum
            // can't fail to compile, so one shared file is safe (no per-type isolation
            // needed). Skips any namespace that is also a reconstructed value type.
            let nsToDeclare = namespaceTypes.subtracting(bundledTypeNames).subtracting(verbatimDeclaredTypes).sorted()
            if !nsToDeclare.isEmpty {
                var nsSrc = "// Auto-generated by Patch — shared namespace declarations. DO NOT EDIT.\n\n"
                for t in nsToDeclare { nsSrc += "enum \(t) {}\n" }
                let nsURL = buildDir.appendingPathComponent("_PatchNamespaces.swift")
                try nsSrc.write(to: nsURL, atomically: true, encoding: .utf8)
                supportSources.insert(nsURL)
            }

            // Emit each reconstructed value type as its OWN support file
            // (`_PatchType_<Name>.swift`). One-per-file lets the convergence loop
            // ISOLATE a broken reconstruction (a non-Codable / `#if !$Embedded`-guarded
            // type): only the candidates referencing the broken type demote, while the
            // independent candidates still ship — instead of one shared
            // `_PatchClosure.swift` failure killing the whole module (the dominant
            // "poison-one-fail-all" cause that left ~66% of apps emitting 0).
            for t in mergedTypes.sorted() {
                guard let src = bundler.emitSingleValueTypeSource(
                    type: t, index: declIndex, surfaceMembers: mergedMembers,
                    bundledTypes: Array(mergedTypes),
                    header: "reconstructed value type") else { continue }
                let safe = String(t.map { ($0.isLetter || $0.isNumber) ? $0 : "_" })
                let typeURL = buildDir.appendingPathComponent("_PatchType_\(safe).swift")
                try src.write(to: typeURL, atomically: true, encoding: .utf8)
                supportSources.insert(typeURL)
            }

            // Wave-2 generic monomorphization: emit each verbatim generic definition
            // ONCE (deduped by key) into a shared support file. Swift compiles these
            // generic bodies to WASM unchanged; the concrete @_cdecl wrappers (in the
            // candidate files) call them at the chosen concrete instantiation types.
            if !genericDefs.isEmpty {
                var gsrc = "// Auto-generated by Patch — bundled GENERIC definitions for\n"
                gsrc += "// concrete monomorphization (\(genericSpecCount) specialized exports). The\n"
                gsrc += "// developer's generic source is emitted UNCHANGED; only the @_cdecl wrappers\n"
                gsrc += "// are concrete. Swift monomorphizes each call at the boundary type. DO NOT EDIT.\n"
                gsrc += "import Foundation\n\n"
                for key in genericDefs.keys.sorted() {
                    gsrc += (genericDefs[key] ?? "") + "\n\n"
                }
                let gURL = buildDir.appendingPathComponent("_PatchGenerics.swift")
                try gsrc.write(to: gURL, atomically: true, encoding: .utf8)
                supportSources.insert(gURL)
            }

        }

        // ---- (1b) Admit only SELF-CONTAINED mixed fragments ---------------------
        // Now that the module closure's bundled value types are known, filter the
        // deferred mixed candidates: a fragment that references an unbundled app
        // type, or carries a generic @_cdecl export, is kept native (skipped). This
        // is the conservative pre-compile gate that keeps the build fast and never
        // ships a fragment that can't compile.
        let bundledTypeSet = Set(mergedTypes)
        // DIAGNOSTIC: tally the coarse category of each unbound symbol so we can see
        // whether the dominant "mixed fragment references unbundled" bucket is
        // genuinely native or an addressable value type.
        let demoteCatsEnabled = ProcessInfo.processInfo.environment["PATCH_DEMOTE_CATS"] != nil
        var unboundCats: [String: Int] = [:]
        for pm in pendingMixed {
            if let unbound = bundler.fragmentUnboundSymbol(in: pm.wasmSource, bundledTypes: bundledTypeSet) {
                if demoteCatsEnabled {
                    let cat = bundler.classifyUnboundSymbol(unbound, index: declIndex)
                    unboundCats["MIXED::\(cat)", default: 0] += 1
                    if cat == "value-type(ADDRESSABLE)",
                       ProcessInfo.processInfo.environment["PATCH_DEMOTE_DUMP"] != nil {
                        FileHandle.standardError.write(Data("ADDR-FRAG \(pm.id) unbound=\(unbound)\n----\n\(pm.wasmSource)\n====\n".utf8))
                    }
                }
                rejectedExports.append((pm.id, "mixed fragment references unbundled `\(unbound)`"))
                continue
            }
            // Re-emit with the correct module-wide allocator flag (one allocator per
            // module). `firstPureFileEmitted` also covers the value-lift path.
            let emitted = emitter.emit(pm.plan, includeAllocator: !firstPureFileEmitted)
            firstPureFileEmitted = true
            try emitted.wasmSource.write(to: pm.wasmURL, atomically: true, encoding: .utf8)
            try emitted.bridgeSource.write(to: pm.bridgeURL, atomically: true, encoding: .utf8)
            wasmSources.append(pm.wasmURL)
            // The bridge file is the native shell (App Store binary); not compiled
            // into the module, but written so `push` can pick it up.
            exportsBySource[pm.wasmURL] = emitted.exportSymbols
            exportSymbols.append(contentsOf: emitted.exportSymbols)
            splitFns.append(pm.id)
            bridgeSources.append(pm.bridgeURL)
        }

        // ---- (1c) Sub-tree extraction over `native` bodies + closures -----------
        // research/subtree-extraction: the unit of OTA is the pure computation,
        // wherever it is buried. `native`-classified functions are NEVER fed to the
        // FunctionSplitter, yet they routinely hold pure predicates / layout math /
        // version strings, and their nested closures hold pure transforms. The
        // SubtreeExtractor recursively walks each native body (INTO closure
        // literals) and lifts the maximal pure sub-trees into WASM fragments,
        // leaving the WHOLE body in the native shell (so the fingerprint is stable
        // and correctness cannot regress). Same self-contained admission gate as
        // mixed fragments: a fragment referencing an unbundled app type is kept
        // native. Each emitted fragment's inputs are concretely ABI-typed by
        // construction (the extractor drops any `_`-typed lift).
        let extractor = SubtreeExtractor(registry: registry, nativeCalleeNames: nativeCalleeNames)
        let nativeIDs = report.results.filter { $0.classification == .native }
        var nativeByFile: [URL: [String]] = [:]
        for r in nativeIDs {
            guard let rec = report.records[r.functionID] else { continue }
            nativeByFile[rec.sourceFile, default: []].append(r.functionID)
        }
        // Two native functions with the same simple name (e.g. two `body` members on
        // different view types) would emit colliding `_se_body_*` export symbols /
        // file names → a duplicate-`@_cdecl` link error. Dedupe by export symbol +
        // wasm file name across the whole module (a collision keeps that fragment
        // native — conservative, never ships a broken module).
        var seenExportSymbols = Set(exportSymbols)
        var seenWasmFileNames = Set(wasmSources.map { $0.lastPathComponent })
        for (file, ids) in nativeByFile.sorted(by: { $0.key.path < $1.key.path }) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let tree = SwiftParser.Parser.parse(source: source)
            let index = DeclarationIndex(tree: tree)
            // DEEP (wave2/subtree-deep): per-file index of each declared type's
            // ABI-typed properties, so a pure expression reading an ABI-typed `self`
            // property can be typed + lifted (the property is passed as a fragment
            // input; the native shell supplies `self.<prop>`).
            let propertyIndex = TypePropertyIndex(tree: tree)
            for id in ids.sorted() {
                guard let rec = report.records[id] else { continue }
                let res = extractor.extract(from: rec, index: index, tree: tree,
                                            inferredTypes: report.inferredTypes[id] ?? [:],
                                            propertyIndex: propertyIndex)
                guard let plan = res.plan else { continue }
                let abiFrags = plan.pureFragments.filter { emitter.isABIEligible($0) }
                guard !abiFrags.isEmpty else { continue }
                // Probe-emit (allocator-on) to run the unbundled-symbol gate.
                let probe = emitter.emit(plan, includeAllocator: true)
                if let unbound = bundler.fragmentUnboundSymbol(in: probe.wasmSource, bundledTypes: bundledTypeSet) {
                    if demoteCatsEnabled {
                        let cat = bundler.classifyUnboundSymbol(unbound, index: declIndex)
                        unboundCats["SUBTREE::\(cat)", default: 0] += 1
                    }
                    rejectedExports.append((id, "native sub-tree fragment references unbundled `\(unbound)`"))
                    continue
                }
                // Drop on any export-symbol / file-name collision (conservative).
                let fnEsc = probe.exportSymbols.filter { $0 != "patch_malloc" && $0 != "patch_free" }
                if seenWasmFileNames.contains(probe.wasmFileName)
                    || fnEsc.contains(where: { seenExportSymbols.contains($0) }) {
                    rejectedExports.append((id, "native sub-tree fragment name collides with an existing export"))
                    continue
                }
                let emitted = emitter.emit(plan, includeAllocator: !firstPureFileEmitted)
                firstPureFileEmitted = true
                let wasmURL = buildDir.appendingPathComponent(emitted.wasmFileName)
                let bridgeURL = buildDir.appendingPathComponent(emitted.bridgeFileName)
                try emitted.wasmSource.write(to: wasmURL, atomically: true, encoding: .utf8)
                try emitted.bridgeSource.write(to: bridgeURL, atomically: true, encoding: .utf8)
                wasmSources.append(wasmURL)
                exportsBySource[wasmURL] = emitted.exportSymbols
                exportSymbols.append(contentsOf: emitted.exportSymbols)
                seenWasmFileNames.insert(emitted.wasmFileName)
                for s in fnEsc { seenExportSymbols.insert(s) }
                splitFns.append(id)
                bridgeSources.append(bridgeURL)
            }
        }

        // ---- (2b) SwiftUI value-lift: freed pure VALUE members of view types ----
        // A design token / label / value helper on a (per-member-freed) View
        // becomes a `_pv_<Type>_<member>` WASM function + a native getter shim that
        // reads it via Patch.value/.call. The view's `body` is untouched, so the
        // shell fingerprint is stable across value-only OTA edits (font 17→22, a
        // label string). These scalar/string values are embeddable (T0), so they
        // ride the same tiny-module path as the pure exports.
        let valueScanner = ValueExportScanner()
        var valueExportNames: Set<String> = []
        var valueBridgeSources: [URL] = []
        for (file, names) in pureByFile.sorted(by: { $0.key.path < $1.key.path }) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let groups = valueScanner.scan(source: source, eligibleSimpleNames: names)
            for group in groups {
                var emittedForType: [CodeEmitter.ValueExport] = []
                for export in group.exports where !valueExportNames.contains(export.exportName) {
                    valueExportNames.insert(export.exportName)
                    let (fileName, src, exports) = emitter.emitValueExportFile(
                        export, includeAllocator: !firstPureFileEmitted)
                    firstPureFileEmitted = true
                    let wasmURL = buildDir.appendingPathComponent(fileName)
                    try src.write(to: wasmURL, atomically: true, encoding: .utf8)
                    wasmSources.append(wasmURL)
                    exportsBySource[wasmURL] = exports
                    exportSymbols.append(contentsOf: exports)
                    emittedForType.append(export)
                }
                // One frozen native-shell shim file per view type.
                if !emittedForType.isEmpty {
                    let (bridgeName, bridgeSrc) = emitter.emitValueBridgeFile(
                        typeName: group.typeName, exports: emittedForType)
                    let bridgeURL = buildDir.appendingPathComponent(bridgeName)
                    try bridgeSrc.write(to: bridgeURL, atomically: true, encoding: .utf8)
                    bridgeSources.append(bridgeURL)
                    valueBridgeSources.append(bridgeURL)
                }
            }
        }
        _ = valueBridgeSources  // (bridge files are native-shell; not compiled into the module)

        // ---- (2c) S2 BUILD-SAFETY NET: host-typecheck the native-shell bridges ----
        // The `*_bridge.swift` files are the native shell the DEVELOPER's Xcode build
        // compiles — but the engine never compiled them, so a wrong hardcoded
        // type/optionality shipped as a "successful build" and broke the dev's build.
        // Host-`swiftc -typecheck` every bridge against the dev's own source (+ a
        // PatchSDK shim) and DEMOTE any bridge that fails (drop the bridge AND its
        // paired WASM export, keep that unit native) — a non-compiling bridge can
        // never reach the developer. SAFETY VALVE: if the dev source doesn't
        // type-check on its own (unresolvable third-party imports), the net is
        // inconclusive and SKIPS — it only demotes when it can PROVE the bridge broke
        // an otherwise-clean compile. Env escape hatch: PATCH_NO_BRIDGE_TYPECHECK=1.
        let bridgeTypecheckEnabled =
            ProcessInfo.processInfo.environment["PATCH_NO_BRIDGE_TYPECHECK"] == nil
        if bridgeTypecheckEnabled && !bridgeSources.isEmpty {
            let devFiles = swiftFiles(in: sourceDir)
            let tcOutcome = BridgeTypecheck.run(
                devSwiftFiles: devFiles, bridges: bridgeSources, enabled: true)
            if !tcOutcome.failingBridges.isEmpty {
                // Drop each failing bridge and its paired `<base>_wasm.swift` export so
                // the unit stays fully native (never half-shipped). Pairing is by file
                // base: `<base>_bridge.swift` <-> `<base>_wasm.swift`.
                for bridge in tcOutcome.failingBridges {
                    let base = bridge.lastPathComponent.replacingOccurrences(of: "_bridge.swift", with: "")
                    let wasmURL = wasmSources.first {
                        $0.lastPathComponent == "\(base)_wasm.swift"
                    }
                    if let wasmURL {
                        let wasmExports = exportsBySource[wasmURL] ?? []
                        // The first pure wasm file carries the shared allocator
                        // (`patch_malloc`/`patch_free`). Removing that file would strip
                        // the allocator from the whole module — so KEEP the wasm file in
                        // that case (its now-orphaned export is harmless, never called)
                        // and only drop the BRIDGE (the thing that breaks the dev build).
                        let carriesAllocator = wasmExports.contains("patch_malloc")
                        if !carriesAllocator {
                            exportSymbols.removeAll { wasmExports.contains($0) }
                            exportsBySource[wasmURL] = nil
                            wasmSources.removeAll { $0 == wasmURL }
                        }
                    }
                    rejectedExports.append((base,
                        "native bridge failed host type-check (kept native — would break the dev's Xcode build)"))
                    bridgeSources.removeAll { $0 == bridge }
                    try? fm.removeItem(at: bridge)
                }
            }
            if ProcessInfo.processInfo.environment["PATCH_BRIDGE_TYPECHECK_DEBUG"] != nil {
                FileHandle.standardError.write(Data("[bridge-typecheck] \(tcOutcome.note)\n".utf8))
            }
        }

        // ---- (3) Fallback: nothing exportable → a real version-probe module ----
        // Keeps `build` producing a genuine instantiable .wasm so the
        // push/CDN/activate paths are still exercised when an app has no
        // auto-generatable OTA surface.
        if wasmSources.isEmpty {
            let probe = buildDir.appendingPathComponent("PatchModule_wasm.swift")
            try """
            // Auto-generated by Patch — reactor entry for the OTA module.
            // (No mixed split and no pure-export surface in this build; this
            // exports a version probe so the module is a real, instantiable .wasm.)
            // No `import Foundation`: the probe uses only `@_cdecl` + Int32, so it must
            // compile at the EMBEDDED (T0) tier too, where Foundation does not exist.

            @_cdecl("patch_module_version")
            public func patch_module_version() -> Int32 { 1 }
            """.write(to: probe, atomically: true, encoding: .utf8)
            wasmSources.append(probe)
            exportsBySource[probe] = ["patch_module_version"]
            exportSymbols.append("patch_module_version")
        }

        // Honor an explicit `--output <path>` (exact filename), else the default.
        let moduleURL = outputModule ?? buildDir.appendingPathComponent("module.wasm")
        if let parent = outputModule?.deletingLastPathComponent() {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        // ---- Tier selection: pick the SMALLEST viable start tier for the module.
        // Rule (research SYNTHESIS step 2 + classify-tier.sh):
        //   1. The classifier's embedded axis gives each OTA-bound function its
        //      smallest tier; the module's start tier is the MAX over the shipped
        //      functions (a module is one compile unit at one tier).
        //   2. grep `import Foundation` in the generated/support sources: if the
        //      compile unit needs in-module Foundation, it can't start at T0
        //      (Foundation values that have host bridges are the exception, but
        //      the generated JSON-ABI wrappers use in-module Codable, which is T2).
        // The convergence loop ESCALATES the tier on a whole-unit compile failure,
        // so this only needs to be a good starting guess — never a final verdict.
        let (startTier, tierRationale) = selectStartTier(
            report: report, wasmSources: wasmSources, supportSources: supportSources)

        if demoteCatsEnabled && !unboundCats.isEmpty {
            FileHandle.standardError.write(Data("DEMOTE-CATS (unbound-symbol breakdown):\n".utf8))
            for (k, n) in unboundCats.sorted(by: { $0.value > $1.value }) {
                FileHandle.standardError.write(Data("  [\(n)] \(k)\n".utf8))
            }
        }

        if dryRun {
            return Result(report: report, splitFunctions: splitFns,
                          generatedWasmSources: wasmSources, generatedBridgeSources: bridgeSources,
                          exportSymbols: exportSymbols, compileOutcome: nil, moduleURL: nil,
                          selectedTier: startTier, tierRationale: tierRationale,
                          rejectedExports: rejectedExports.map { (name: $0.0, reason: $0.1) })
        }

        let candidates = wasmSources.map {
            WasmConvergence.Candidate(functionID: $0.lastPathComponent, sourceFile: $0,
                                      exports: exportsBySource[$0] ?? [])
        }
        var convergence = WasmConvergence(compiler: compiler)
        convergence.supportSources = supportSources.sorted { $0.path < $1.path }
        let outcome = try convergence.converge(candidates, outputModule: moduleURL, startTier: startTier)

        var result = Result(report: report, splitFunctions: splitFns,
                      generatedWasmSources: wasmSources, generatedBridgeSources: bridgeSources,
                      exportSymbols: exportSymbols, compileOutcome: outcome,
                      moduleURL: outcome.moduleURL,
                      selectedTier: startTier, tierRationale: tierRationale,
                      rejectedExports: rejectedExports.map { (name: $0.0, reason: $0.1) })

        // ---- REAL-SOURCE CLOSURE COMPILATION (additive, opt-in) -----------------
        // The research breakthrough (research/wave3/BREAKTHROUGH-real-source-
        // compilation.md). When PATCH_REAL_SOURCE=1, ADD a second module of pure
        // exports compiled against the developer's REAL, verbatim module source — the
        // ones the default engine's RECONSTRUCTION could not ship (classes/protocols/
        // generics it rejects; value types it can't rebuild). The default module above
        // is untouched (canaries can only GAIN), and an export demotes only on a real
        // WASM compile failure (the convergence loop's existing guarantee). Skipped
        // when the toolchain is unavailable (the default outcome already reflects that).
        // OPT-IN (PATCH_REAL_SOURCE=1) pending the merge/closure P0 fixes — the merged
        // module currently has 2 memories (real-source half never _initialize'd → traps in
        // WasmKit). Re-enable default-on once a merged module is proven to instantiate +
        // execute both default and real-source exports in WasmKit (the SDK runtime).
        if ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE"] != nil,
           !(outcome.toolchainUnavailable) {
            // Export symbols the default engine ALREADY shipped — don't duplicate them.
            let already = Set(outcome.compiled.flatMap { $0.exports })
            if let add = try runRealSourceAdditive(
                report: report, sourceDir: sourceDir, buildDir: buildDir,
                pureByFile: pureByFile, scanner: scanner,
                valueTypeNames: declIndex.valueTypeNames,
                emitter: emitter, compiler: compiler,
                alreadyShipped: already, defaultModule: moduleURL) {
                result.realSourceCompiledUnits = add.compiledUnits
                result.realSourceModuleURL = add.moduleURL
                result.realSourceAddedExports = add.addedExports

                // ---- P0 SHIP-PLUMBING: merge the additive module into the default --
                // The additive module is a separate `module.realsource.wasm`; without
                // this merge, `release`/`push` (which upload only `module.wasm`) drop
                // the real-source/fusion gains entirely. Merging both into the single
                // `module.wasm` makes the gain SHIP BY DEFAULT through the unchanged
                // upload path. Best-effort + atomic: if `wasm-merge` is unavailable or
                // the merge fails, the default module is left intact (the gain is
                // reported but not shipped — never a regression). Skipped when there
                // is no additive module or it added no NEW exports.
                if let rsModule = add.moduleURL, add.compiledUnits > 0,
                   FileManager.default.fileExists(atPath: rsModule.path),
                   FileManager.default.fileExists(atPath: moduleURL.path) {
                    let merger = WasmModuleMerger()
                    result.realSourceMergedIntoDefault =
                        merger.mergeIfPossible(primary: moduleURL, secondary: rsModule)
                }
            }
        }

        // ---- SWIFTUI BODY LOWERING (additive, ON by default) --------------------
        // Lower `View.body` declarations to the proven ViewNode IR and ship a guest
        // `view_body` WASM export, instead of DEMOTING the body to native. ADDITIVE:
        // the default module above is untouched (canaries can only GAIN a view
        // export), and a view that doesn't compile demotes via the convergence loop.
        // ON by default — SwiftUI views ship over the air. Controlled by the
        // .Patch.yml `swiftui` setting (`swiftUIEnabled`, default on if omitted);
        // an explicit PATCH_SWIFTUI env var overrides it per-run (=0 off, else on).
        // Skipped when the toolchain is unavailable (the default outcome reflects it).
        let swiftUIOn = ProcessInfo.processInfo.environment["PATCH_SWIFTUI"]
            .map { $0 != "0" } ?? swiftUIEnabled
        if swiftUIOn, !(outcome.toolchainUnavailable) {
            if let sw = try runSwiftUILowering(
                sourceDir: sourceDir, buildDir: buildDir,
                compiler: compiler, defaultModule: moduleURL) {
                result.loweredViewBodies = sw.loweredViewBodies
                result.loweredViewElements = sw.loweredViewElements
                result.loweredViewElementsWasm = sw.loweredViewElementsWasm
                result.loweredViews = sw.loweredViews
                result.swiftUIModuleURL = sw.moduleURL
                result.swiftUIExports = sw.exports

                // SHIP-PLUMBING: merge the SwiftUI guest module into the default
                // `module.wasm` so the `view_body` export ships through the normal
                // upload path. Best-effort + atomic (same contract as real-source):
                // if `wasm-merge` is unavailable the default module is left intact —
                // the lowering is reported but not shipped (never a regression).
                if let swModule = sw.moduleURL, sw.loweredViewBodies > 0,
                   FileManager.default.fileExists(atPath: swModule.path) {
                    if FileManager.default.fileExists(atPath: moduleURL.path) {
                        let merger = WasmModuleMerger()
                        result.swiftUIMergedIntoDefault =
                            merger.mergeIfPossible(primary: moduleURL, secondary: swModule)
                    } else if Self.promoteGuestToPrimary(guest: swModule, primary: moduleURL) {
                        // No primary `module.wasm` (default general-logic convergence
                        // produced none) but the SwiftUI guest compiled clean — promote
                        // it to BE the shipped `module.wasm` so `release` has something to
                        // upload. The promoted module is now the primary, so it counts as
                        // merged-into-default (its `view_body` export ships).
                        result.moduleURL = moduleURL
                        result.swiftUIMergedIntoDefault = true
                    }
                }
            }
        }

        // ---- UIKIT CELL LOWERING (default-on, additive) -------------------------
        // Lowers a declarative UIKit cell's construction to a guest `uikit_configure`
        // export + ships it. Gated by the SAME `swiftui` toggle (the UIKit path is part
        // of the same view-patching feature) and skipped without the toolchain.
        if swiftUIOn, !(outcome.toolchainUnavailable) {
            if let uk = try runUIKitLowering(
                sourceDir: sourceDir, buildDir: buildDir,
                compiler: compiler, defaultModule: moduleURL) {
                result.loweredCells = uk.loweredCells
                result.loweredCellDetail = uk.detail
                result.uikitModuleURL = uk.moduleURL
                result.uikitExports = uk.exports
                if let ukModule = uk.moduleURL, uk.loweredCells > 0,
                   FileManager.default.fileExists(atPath: ukModule.path) {
                    if FileManager.default.fileExists(atPath: moduleURL.path) {
                        // A primary module exists (default convergence shipped one, OR
                        // the SwiftUI block above promoted its guest) — merge into it.
                        let merger = WasmModuleMerger()
                        result.uikitMergedIntoDefault =
                            merger.mergeIfPossible(primary: moduleURL, secondary: ukModule)
                    } else if Self.promoteGuestToPrimary(guest: ukModule, primary: moduleURL) {
                        // No primary `module.wasm` and no SwiftUI guest promoted it —
                        // promote the clean UIKit guest to BE the shipped module.
                        result.moduleURL = moduleURL
                        result.uikitMergedIntoDefault = true
                    }
                }
            }
        }

        // ---- HOST-BRIDGE LOWERING (Lever #2, opt-in PATCH_HOST_BRIDGE=1) --------
        // For a function forced native BECAUSE of bridgeable call sites, route each
        // routable call through the single `patch_host.call` import. ADDITIVE +
        // DEMOTE-SAFE + OPT-IN (default OFF — flag-OFF is byte-identical to today):
        // the default module above is untouched; this only EMITS the manifest + the
        // App-Store-clean resolver-thunk source `prepare` inserts, and reports which
        // calls routed. The three-layer fail-closed net (classifier demote → thunk
        // typecheck-or-demote → runtime have()/.error) holds; a call that can't be
        // safely routed stays native (the existing path). See `HostBridgeLowering`.
        if HostBridgeLowering.isEnabled() {
            let lowering = HostBridgeLowering(moduleName: moduleName(for: sourceDir))
            let hb = try lowering.run(report: report, sourceDir: sourceDir, buildDir: buildDir)
            result.hostBridgeRoutedSymbols = Set(hb.routed.map { $0.symbol.id }).count
            result.hostBridgeManifestURL = hb.manifestURL
            result.hostBridgeThunkURL = hb.thunkURL
            result.hostBridgeRouted = hb.routed.map {
                (functionID: $0.functionID, signature: $0.symbol.canonicalSignature)
            }
            result.hostBridgeExaminedForcedNative = hb.examinedForcedNativeFunctions
            result.hostBridgeLoweredFunctions = hb.lowered.count
            result.hostBridgeLowered = hb.lowered.map {
                (functionID: $0.functionID, routedCalls: $0.routedCallCount)
            }
            let hbVerbose = ProcessInfo.processInfo.environment["PATCH_HOST_BRIDGE_VERBOSE"] != nil
            if hbVerbose {
                let n = result.hostBridgeRoutedSymbols
                var msg = "[host-bridge] routed \(n) symbol(s) across "
                msg += "\(hb.examinedForcedNativeFunctions) forced-native function(s); "
                msg += "RE-LOWERED \(hb.lowered.count) function(s) native→OTA; "
                msg += "demoted \(hb.demoted.count) call site(s)\n"
                for r in hb.routed { msg += "  ROUTE \(r.symbol.canonicalSignature) (id \(r.symbol.id))\n" }
                for l in hb.lowered { msg += "  LOWER \(l.functionID) (\(l.routedCallCount) routed call(s))\n" }
                FileHandle.standardError.write(Data(msg.utf8))
            }

            // ---- SHIP STEP (the Lever-#2 gap close) ----------------------------
            // Compile the re-lowered guest bodies into a real `module.hostbridge.wasm`
            // sub-module: the routed `patch_host.call` sequences become PRESENT +
            // INSTANTIABLE, and it exports `patch_host_symbols`. Then ship it as a
            // PMOD-ADDITIVE sub-module (its OWN WasmKit instance — NOT a memory-merge,
            // which would be unsound; the container keeps it byte-for-byte intact).
            // Demote-safe: a compile failure / unavailable toolchain leaves the default
            // module untouched and the rest of the patch still ships. Only a flipped
            // function contributes; nothing here runs with the flag OFF (the guard).
            if !hb.routed.isEmpty,
               let swiftWasm = compiler as? SwiftWasmCompiler,
               swiftWasm.toolchainAvailable,
               let emission = try lowering.buildGuestEmission(routed: hb.routed) {
                let hbModule = moduleURL.deletingPathExtension()
                    .appendingPathExtension("hostbridge.wasm")
                let compiled = try swiftWasm.compileGenericHostBridgeGuest(
                    emission: emission, outputModule: hbModule)
                if case .success = compiled.status,
                   let m = compiled.moduleURL,
                   FileManager.default.fileExists(atPath: m.path) {
                    result.hostBridgeModuleURL = m
                    result.hostBridgeModuleExports = emission.exports
                    // Ship it: append to the default module's PMOD container (separate
                    // instance on-device — sound by construction). Best-effort + atomic.
                    if FileManager.default.fileExists(atPath: moduleURL.path) {
                        _ = WasmModuleMerger().mergeIfPossible(primary: moduleURL, secondary: m)
                    }
                    if hbVerbose {
                        let line = "[host-bridge] shipped \(emission.exports.count) export(s) in "
                            + "\(m.lastPathComponent) (PMOD-additive)\n"
                        FileHandle.standardError.write(Data(line.utf8))
                    }
                } else if hbVerbose {
                    let line = "[host-bridge] guest sub-module did NOT compile — kept native "
                        + "(demote-safe):\n\(compiled.log)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
        }

        // ---- WASM-OPT SIZE FINALIZE (default-on, safe, LAST step) ---------------
        // After every merge + multi-memory lowering, shrink the single shippable
        // `module.wasm` with a feature-preserving `wasm-opt -Oz --strip-debug
        // --strip-producers` pass. This runs AFTER the merge/lowering so it always
        // sees a SINGLE-memory module (the merger guarantees that — a module that
        // couldn't be lowered was never shipped). Always-safe baseline size win on
        // EVERY shipped module (default-engine, real-source, SwiftUI): strips
        // debug/producer sections and size-optimizes with no behavior change, and
        // only ever shrinks (best-effort + atomic; the module is untouched on any
        // failure). Disabled by `PATCH_WASM_OPT=0`. Skipped when nothing compiled.
        if ProcessInfo.processInfo.environment["PATCH_WASM_OPT"] != "0",
           let m = result.moduleURL,
           FileManager.default.fileExists(atPath: m.path) {
            let opt = WasmOptimizer().optimizeInPlace(module: m)
            result.wasmOptimized = opt.optimized
            result.moduleSizeBeforeOpt = opt.beforeBytes
            result.moduleSizeAfterOpt = opt.afterBytes
            if opt.optimized,
               ProcessInfo.processInfo.environment["PATCH_WASM_OPT_VERBOSE"] != nil {
                let msg = "[wasm-opt] module.wasm \(opt.beforeBytes) → \(opt.afterBytes) bytes "
                    + "(\(String(format: "%.1f", opt.percentSaved))% smaller)\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }
        // ---- SHIPPED-OTA MANIFEST (the build→fingerprint hand-off) ---------------
        // [R2-#9/#10/#11/#34/#35/#36] The native-shell fingerprint must strip a view /
        // cell / function body ONLY if the build ACTUALLY shipped it OTA. The fingerprint
        // runs in a SEPARATE process (`register`/`diff`) that re-derived its strip set
        // STATICALLY (a pre-compile `isAutoRouted` prediction), so it stripped bodies the
        // build's WASM-compile bisect later dropped to native — a real native-shell edit
        // to such a body then produced NO churn (a FALSE-STABLE: the edit looks OTA-benign
        // but never reaches the device, and no native rebuild is forced). We persist the
        // AUTHORITATIVE set the build shipped here; `ProjectFingerprinter.snapshot` reads
        // it and strips ONLY bodies in it (a body the build dropped stays hashed verbatim,
        // so a later edit churns and forces the native update the device truly needs).
        // Absent / failed build → no manifest → the fingerprint strips NOTHING (the
        // conservative fallback). Written to the CANONICAL `<projectRoot>/.Patch/build/`
        // — the SAME path `ShippedOTAManifest.read` loads — regardless of `--output`
        // (a `--output dist/…` build sets `buildDir` to `dist/`, where the reader would
        // never look, so the fresh manifest would be ignored and the gate fall back to a
        // stale/over-conservative static set).
        Self.writeShippedManifest(buildDir: buildDir, sourceDir: sourceDir, result: result)
        return result
    }

    /// [R2-#9/#10/#11/#34/#35/#36] Persist the set of view / cell / general-logic bodies
    /// the build ACTUALLY shipped OTA, so the native-shell fingerprint strips only THOSE
    /// (a body the build dropped to native stays hashed → an edit to it churns). Written to
    /// the CANONICAL `<projectRoot>/.Patch/build/shipped-ota.json` — the EXACT path
    /// `ShippedOTAManifest.read(projectDir:)` loads — derived from `sourceDir` (walk up to
    /// the `.Patch.yml`), NOT from the caller's `buildDir` (a `--output dist/…` build points
    /// `buildDir` at `dist/`, where the reader never looks). Falls back to `buildDir` when no
    /// project root is discoverable (configless / test builds — preserves prior behavior).
    static func writeShippedManifest(buildDir: URL, sourceDir: URL, result: Result) {
        // General-logic (`wasmEligible`) coverage is sound to strip ONLY when the general
        // WASM module compiled with NO demotions / CORE failure. A demotion
        // (`reclassifiedNative` non-empty) or a CORE failure (`moduleURL == nil` while
        // exports were offered) means SOME wasmEligible body dropped to native and the
        // fingerprint can't cheaply tell which (the functionID↔export mapping is lost in
        // the emitter), so we mark general coverage UNTRUSTED → the fingerprint hashes
        // every wasmEligible body verbatim (over-conservative = a benign sibling edit may
        // churn, but NEVER false-stable). Trusted only when a real module shipped clean.
        let generalDemoted = result.compileOutcome?.reclassifiedNative.isEmpty == false
        let generalCoreFailed = (result.compileOutcome != nil)
            && result.compileOutcome?.moduleURL == nil
            && !(result.exportSymbols.filter { $0 != "patch_malloc" && $0 != "patch_free" }.isEmpty)
        let generalTrusted = (result.compileOutcome != nil) && !generalDemoted && !generalCoreFailed
        // A lowered view/cell is "shipped" — and thus safe for the fingerprint to STRIP
        // (so an edit to its body is treated OTA-benign) — ONLY when its guest module
        // actually MERGED into / was promoted to the shipped `module.wasm`. When the merge
        // was skipped (no primary module to merge into and no promotion, or `wasm-merge`
        // unavailable), the lowered `view_body`/`uikit_configure` export never reached the
        // device; the view/cell renders NATIVE. Recording it as shipped here would be
        // FALSE-STABLE: the fingerprint would strip the body, and a later native-shell edit
        // to it would churn nothing yet never reach the device. Mirrors `generalLogicTrusted`
        // — only trust what the build genuinely shipped.
        let shippedViews = result.swiftUIMergedIntoDefault
            ? result.loweredViews.map { $0.view }.sorted() : []
        let shippedCells = result.uikitMergedIntoDefault
            ? result.loweredCellDetail.map { $0.cell }.sorted() : []
        // [divergence-fix] Stamp the source-set hash so a later `fingerprint diff` can tell
        // whether this manifest is still FRESH (the source it was built from is unchanged)
        // before trusting its shipped-set / trust verdict. Hashed over the same
        // `crossFileLoweringSources` set the build lowered (no excludes — mirrors the build's
        // own `crossFileLoweringSources(projectDir:)` call), keyed off `sourceDir` (the
        // project root). A diff whose source bytes differ from this sees a stale manifest and
        // rebuilds (or warns) rather than trusting a verdict that may no longer match a build.
        let srcHash = ShippedOTAManifest.sourceSetHash(projectDir: sourceDir)
        let manifest = ShippedOTAManifest(
            shippedSwiftUIViews: shippedViews,
            shippedUIKitCells: shippedCells,
            generalLogicTrusted: generalTrusted,
            sourceHash: srcHash)
        // Resolve the CANONICAL build dir the fingerprint reads (`<projectRoot>/.Patch/build`)
        // so the manifest the reader loads is THIS fresh one — not a stale static fallback.
        // `ShippedOTAManifest.read` looks under `projectDir/.Patch/build`; the project root is
        // where `.Patch.yml` lives. Fall back to the caller's `buildDir` when none is found.
        let manifestDir: URL
        if let configURL = PatchConfig.find(startingAt: sourceDir) {
            manifestDir = configURL.deletingLastPathComponent()
                .appendingPathComponent(".Patch")
                .appendingPathComponent("build")
        } else {
            manifestDir = buildDir
        }
        let url = manifestDir.appendingPathComponent(ShippedOTAManifest.fileName)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Promote a CLEANLY-lowered SwiftUI/UIKit guest module to BE the shippable
    /// `module.wasm` when the default general-logic convergence produced none. Without
    /// this, a SwiftUI-only / UIKit-only patch (no `wasmEligible` general logic) compiles
    /// a clean guest module that nothing ever moves to the canonical `module.wasm` path,
    /// so `release` throws "nothing to release" and the patch is silently lost.
    ///
    /// Conservative + atomic: only ever invoked when `primary` does NOT already exist on
    /// disk (caller's guard) and `guest` does; copies the guest bytes to `primary` and
    /// returns whether the copy succeeded. On any failure nothing is shipped (the guest
    /// module is reported but not promoted — never a regression, never a broken module).
    /// Copies (not moves) so the original guest path stays valid for reporting.
    @discardableResult
    static func promoteGuestToPrimary(guest: URL, primary: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: guest.path),
              !fm.fileExists(atPath: primary.path) else { return false }
        do {
            try fm.createDirectory(at: primary.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.copyItem(at: guest, to: primary)
            return fm.fileExists(atPath: primary.path)
        } catch {
            return false
        }
    }

    // MARK: - SwiftUI body lowering (PATCH_SWIFTUI)

    /// Result of the additive SwiftUI lowering build.
    struct SwiftUILoweringResult {
        let loweredViewBodies: Int
        let loweredViewElements: Int
        let loweredViewElementsWasm: Int
        let loweredViews: [(view: String, export: String, elements: Int, wasm: Int)]
        let moduleURL: URL?
        let exports: [String]
    }

    /// The opt-in SwiftUI lowering path. Scans every `.swift` file under `sourceDir`
    /// for `View`-conforming structs, lowers each `body` to the ViewNode IR via the
    /// `FrontierLower` Classifier+Emitter, emits a guest `view_body` module (the
    /// builder expression + the embeddable ViewNode IR), and compiles it to a second
    /// `module.swiftui.wasm`. Returns nil when no view lowered or nothing compiled.
    ///
    /// ADDITIVE + demote-safe: a view whose emitted body doesn't compile demotes via
    /// the convergence loop (the whole guest module is one compile unit here — v1 is
    /// coarse: it ships all lowered views or none, exactly the proven package's
    /// guarantee for the static + simple-interactive subset).
    func runSwiftUILowering(
        sourceDir: URL, buildDir: URL,
        compiler: WasmCompiling, defaultModule: URL
    ) throws -> SwiftUILoweringResult? {
        let fm = FileManager.default
        let verbose = ProcessInfo.processInfo.environment["PATCH_SWIFTUI_VERBOSE"] != nil
        func log(_ s: String) { if verbose { FileHandle.standardError.write(Data("[swiftui] \(s)\n".utf8)) } }

        // (1) Scan source for View structs + lower each body.
        // SAME-FILE THUNK PLACEMENT (the default): `patchcli prepare` now emits each
        // view's `@_dynamicReplacement(for: body)` thunk + its `__patchSlots()`/
        // `__patchTokens()` helpers as an extension in the SAME FILE as the view, so the
        // thunk can reach the view's own `private`/`fileprivate` members. That lets the
        // engine host-resolve a read of a private member (slot / token) — the unblock for
        // a view like SettingsScreen whose sole blocker is a `private @Environment` read.
        // `PATCH_SAMEFILE_THUNK=0` forces the legacy separate-file contract (private reads
        // stay inaccessible → such a view stays native) for verification / a project that
        // opts out of same-file thunk generation.
        // SINGLE SOURCE OF TRUTH (shared with the fingerprint) — the fingerprint walks MUST pass
        // the identical value to `lowerAllViews`, or a `PATCH_SAMEFILE_THUNK=0` build's private-member
        // lowering diverges from the fingerprint's default-`true` lowering and a benign OTA edit churns.
        let sameFileThunk = ProjectFingerprinter.sameFileThunkEnabled
        let lowering = BodyLowering()
        var guestViews: [SwiftUIGuestEmitter.GuestView] = []
        var detail: [(view: String, export: String, elements: Int, wasm: Int)] = []
        var totalElements = 0, totalWasm = 0
        var seenExports = Set<String>()
        // View names EXCLUDED from guest emission (render natively, not OTA-patchable):
        // a body that can't produce COMPILABLE guest code is never emitted into the
        // module — emitting it would fail the single SwiftUI compile unit and ship NO
        // views. Surfaced as a concise non-verbose warning at the end (DEFECT 5).
        var excludedViews: [String] = []
        // DIAGNOSTIC (DX): per-view, WHY it couldn't lower — surfaced in the always-on
        // demote warning so a dev sees the actionable cause (which property blocked it,
        // and whether it's the SwiftData wall) instead of just a view name.
        var demoteReasons: [String: String] = [:]

        // SAME-NAME COLLISION (PRE-PASS — soundness): two views that sanitize to the
        // SAME guest export base (`view_body__<name>`) — e.g. two `ContentView`s in
        // different files/modules — can NEITHER be auto-routed CORRECTLY. The SDK
        // identifies a live view ONLY by the unqualified type-name string baked
        // statically into its generated thunk (`thunkBody(typeName: "ContentView", …)`)
        // and routes on `entries[typeName]`. Two views named `ContentView` produce
        // thunks that BOTH bake `"ContentView"` and BOTH look up the SAME manifest
        // slot — so shipping EITHER body would route the OTHER view's instance through
        // it (render view A's body for view B). Suffix-hashing the export symbol would
        // let both COMPILE into WASM, but the routing KEY (the type name) still
        // collides, so it cannot make routing sound. We therefore EXCLUDE *every* view
        // sharing a colliding name (not just the second): keeping the first as a
        // routable manifest entry is itself a latent mis-route (a second module's
        // same-named view would route to the first's shipped body). Dropping all of
        // them renders every claimant native — strictly safe, no regression, no
        // possible mis-route. (Found ~17× on the real-app corpus; documented in
        // docs/SWIFTUI-COVERAGE.md as a binary-symbol-adjacent impossibility: the
        // runtime carries no module qualifier to disambiguate.)
        var loweredNameCounts: [String: Int] = [:]
        // Lower each file ONCE in the pre-pass and reuse the results in the main loop
        // (lowering is pure; recomputing would only waste build time).
        var loweredViews: [BodyLowering.LoweredView] = []
        // CROSS-FILE reactive resolution: a view's reactive model class + its element structs
        // usually live in OTHER files than the view. Build the project-wide HOST-PROJECTION
        // catalogs (scalar/collection/string — all demote-safe) + the reactive-collection SHAPE
        // catalog (element shapes PRE-RESOLVED) ONCE from ALL sources, and feed them to every
        // per-file lowering so a `ForEach(vm.items)` over a cross-file model lowers. The riskier
        // cross-file STRUCT/ENUM marshalling-input catalogs stay DORMANT (the shape catalog already
        // carries fully-resolved element fields, so they aren't needed here). MUST stay in sync with
        // ProjectFingerprint's cross-file catalogs, or the auto-routed-body stripping diverges.
        // SHARED with the fingerprint — `crossFileLoweringSources` is the single source of truth for
        // which `.swift` files the lowering ingests, so the build's auto-routed-view set is byte-
        // identical to what `ProjectFingerprint` strips. A divergence here (e.g. the build ingesting a
        // stray `*_wasm.swift` / hidden-tree source the fingerprint skipped) would wrongly churn the
        // native-shell fingerprint on a benign OTA edit — the user's #1 P0. The list is sorted, so the
        // cross-file catalog merge is order-deterministic across runs too.
        let loweringSources = ProjectFingerprinter.crossFileLoweringSources(projectDir: sourceDir)
        let crossFile = BodyLowering.crossFileBundle(sources: loweringSources.map(\.source))
        for (_, source) in loweringSources {
            guard source.contains("View") else { continue }
            for lowered in lowering.lowerAllViews(source: source, sameFileThunk: sameFileThunk, crossFile: crossFile)
            where lowered.report.totalElements > 0 {
                loweredViews.append(lowered)
                let base = SwiftUIGuestEmitter.exportSymbol(forView: lowered.viewName)
                loweredNameCounts[base, default: 0] += 1
            }
        }
        // The set of guest export bases claimed by 2+ lowered views (ambiguous → none
        // of their claimants is soundly routable).
        let collidingExportBases = Set(loweredNameCounts.filter { $0.value > 1 }.keys)
        // [R2-#95] Views `patchcli prepare`'s ThunkGenerator will NOT thunk because a
        // same-named non-View struct exists (2+ top-level struct decls) or a generic-`where`.
        // The engine's collision check above counts only View-conforming lowered types, so it
        // would otherwise ship + mark such a view `thunkSafe` even though no thunk is
        // generated → it renders NATIVE on device. EXCLUDE it here so it's neither shipped as
        // OTA-routable nor recorded in the shipped manifest (the fingerprint then keeps its
        // body hashed — no false-stable).
        let thunkIneligibleViews = Self.thunkIneligibleViewNames(sources: loweringSources.map(\.source))

        do {
            for lowered in loweredViews {
                let report = lowered.report
                let sym = SwiftUIGuestEmitter.exportSymbol(forView: lowered.viewName)
                // [R2-#95] A view prepare can't thunk renders native — don't ship it OTA.
                if thunkIneligibleViews.contains(lowered.viewName) {
                    excludedViews.append(lowered.viewName)
                    demoteReasons[lowered.viewName] = demoteReasons[lowered.viewName]
                        ?? "another top-level struct shares the name `\(lowered.viewName)` (or it's a "
                        + "generic view with a `where` clause), so `patchcli prepare` generates no "
                        + "@_dynamicReplacement thunk for it — it renders natively, not OTA-patchable"
                    log("EXCLUDE \(lowered.viewName): not thunk-eligible (duplicate top-level struct "
                        + "name / generic-where) — prepare won't thunk it, so it renders native")
                    continue
                }
                // SAME-NAME COLLISION: this view's guest export base is shared by 2+
                // views (see the pre-pass above). NEITHER can be routed correctly — the
                // SDK can't tell two same-named live types apart — so EXCLUDE every
                // claimant. Both render native (the thunk's fallback `body`); no
                // mis-route is possible. Belt-and-suspenders, the `seenExports` guard
                // below still prevents a duplicate `@_cdecl` ever reaching the compiler.
                if collidingExportBases.contains(sym) {
                    excludedViews.append(lowered.viewName)
                    log("EXCLUDE \(lowered.viewName) from guest emission: its guest export "
                        + "`\(sym)` is shared by another same-named view — the SDK routes a "
                        + "live view by its unqualified type name and can't disambiguate two, "
                        + "so neither is auto-routable (renders natively, not OTA-patchable)")
                    continue
                }
                // Defensive: a duplicate export base must never reach the emitter even
                // if the pre-pass under-counted (e.g. a non-deterministic source read).
                // Keeping the original keep-first guard guarantees the `@_cdecl` set is
                // unique no matter what; in practice the collision-exclusion above means
                // we never get here twice for one base.
                guard seenExports.insert(sym).inserted else {
                    log("skip \(lowered.viewName): export `\(sym)` collides with an earlier view")
                    continue
                }
                // EXCLUDE-FROM-EMISSION (DEFECT 3): a view whose body can't produce
                // COMPILABLE guest code must NOT be emitted into the module — the
                // SwiftUI guest is ONE compile unit, so a single broken `view_body__X`
                // fails the WHOLE module and ships NOTHING. The dominant "won't compile"
                // signal is reading an input the guest can't reconstruct (a struct /
                // enum / dictionary / custom value): the lowered tree would reference an
                // unqualified nested type (`Profile(...)`) or bind a struct as a scalar
                // default then access `.name` — both hard compile errors. Such a view is
                // EXCLUDED here (renders fully native via the thunk's fallback) instead
                // of merely flagged `thunkSafe = false` (which still emitted it).
                if lowered.referencesUnmarshalledInput {
                    excludedViews.append(lowered.viewName)
                    // The blocking reads, named (the actionable "why"). The SwiftData
                    // subset is the modern-SwiftUI-app wall — call it out explicitly.
                    let reads = lowered.blockingReadNames
                    let readsList = reads.isEmpty ? "" : " [\(reads.joined(separator: ", "))]"
                    let sd = lowered.swiftDataBlockers
                    if !lowered.inaccessibleReadNames.isEmpty {
                        // The "inaccessible-member wall": the blocking read is a
                        // `private`/`fileprivate` member (commonly a private @Environment
                        // service / @State). Its VALUE is otherwise host-resolvable, but
                        // the generated thunk lives in a SEPARATE file, and Swift's
                        // file-scoped private makes the member invisible there — so the
                        // view stays native. Name the real limit + the actionable fix.
                        let names = lowered.inaccessibleReadNames.joined(separator: ", ")
                        let fixNames = lowered.inaccessibleReadNames
                            .map { "`\($0)`" }.joined(separator: "/")
                        let reason = "reads private/fileprivate member(s) [\(names)] "
                            + "the cross-file patch thunk can't host-resolve (Swift file-scoped private)"
                            + " → fix: make \(fixNames) internal (remove private/fileprivate) "
                            + "to enable OTA host-projection"
                        demoteReasons[lowered.viewName] = reason
                        log("EXCLUDE \(lowered.viewName) from guest emission: lowered body \(reason) "
                            + "— renders natively, not OTA-patchable")
                    } else if !sd.isEmpty {
                        let reason = "reads SwiftData @Query/@Model/modelContext [\(sd.joined(separator: ", "))] "
                            + "— SwiftData model objects aren't marshallable into the patch guest"
                        demoteReasons[lowered.viewName] = reason
                        log("EXCLUDE \(lowered.viewName) from guest emission: \(reason) "
                            + "— renders natively, not OTA-patchable")
                    } else {
                        var reason = "reads non-reconstructable input(s)\(readsList) (struct/enum/dictionary/model)"
                        // ACTIONABLE FIX-HINT: if any blocking reads are tuple-typed, a
                        // named Codable struct would unblock them (tuples aren't Codable).
                        if !lowered.tupleBlockingNames.isEmpty {
                            let tupleNames = lowered.tupleBlockingNames
                                .map { "`\($0)`" }.joined(separator: "/")
                            reason += " → fix: replace the tuple type of \(tupleNames) "
                                + "with a named Codable struct to enable marshalling"
                        }
                        demoteReasons[lowered.viewName] = reason
                        log("EXCLUDE \(lowered.viewName) from guest emission: \(reason) "
                            + "— renders natively, not OTA-patchable")
                    }
                    continue
                }
                // EXCLUDE-FROM-EMISSION (the #1 real-app fix): a view whose emitted
                // guest body references a FREE identifier the guest scope can't resolve
                // — a computed property (`var height: CGFloat { … }`), a dropped
                // body-local `let` (`let owners = schedule.…`), a design-system static
                // in a NUMERIC position (`Theme.Radius.md`), or a Foundation type in an
                // input default (`Locale.current.…`). It compiles to `cannot find 'X'
                // in scope`, which (all view exports share ONE wrapper) demotes the
                // WHOLE module to zero views. Excluding just this view (it renders
                // natively) lets the OTHER views still ship — without this, ONE such
                // view on a real app silently demotes all 40+. The post-emit
                // convergence loop (below) is the backstop for anything this static
                // check misses, but this keeps the loop from ever having to bisect the
                // common cases.
                if lowered.referencesUnresolvedSymbol {
                    excludedViews.append(lowered.viewName)
                    if !lowered.inaccessibleReadNames.isEmpty {
                        let names = lowered.inaccessibleReadNames.joined(separator: ", ")
                        let fixNames = lowered.inaccessibleReadNames
                            .map { "`\($0)`" }.joined(separator: "/")
                        let reason = "reads private/fileprivate member(s) [\(names)] "
                            + "the cross-file patch thunk can't host-resolve (Swift file-scoped private)"
                            + " → fix: make \(fixNames) internal (remove private/fileprivate) "
                            + "to enable OTA host-projection"
                        demoteReasons[lowered.viewName] = reason
                        log("EXCLUDE \(lowered.viewName) from guest emission: lowered body \(reason) "
                            + "— renders natively, not OTA-patchable")
                    } else {
                        let reason = "references out-of-scope symbol(s) [\(lowered.unresolvedSymbols.joined(separator: ", "))] "
                            + "(computed property / body-local / design-system constant / Foundation type)"
                        demoteReasons[lowered.viewName] = reason
                        log("EXCLUDE \(lowered.viewName) from guest emission: lowered body \(reason) "
                            + "— renders natively, not OTA-patchable")
                    }
                    continue
                }
                // thunkSafe ⇒ the SDK may AUTO-ROUTE this view with no `PatchView`,
                // rendering it FAITHFULLY. The emitter NEVER drops a modifier it can't
                // lower — it renders the whole node natively via a mixed-view slot
                // instead — so faithfulness reduces to: every non-lowerable LEAF is
                // SLOTABLE (the build-time thunk can render it from a self-only
                // closure). A 100%-lowered body has no opaque leaves, so this subsumes
                // it. A view with a leaf referencing body-locals stays native (the
                // thunk falls through to the original `body`). We ALSO require ≥1
                // lowered CONTENT node: a pure routing/layout shell (only containers
                // + opaque slots — e.g. a root ContentView that just switches between
                // child screens) gains nothing from routing and would put a WASM call
                // on every frame, so it stays native.
                // A PER-ROW INDEXED NATIVE-ACTION SLOT is patchable CONTENT (the
                // surrounding structure — ScrollView/HStack/padding/the row-count guard —
                // rides WASM; the rows render natively per-index). So a view whose only
                // lowered "content" is an indexed-row slot still routes (the classifier
                // counts the `ForEach` row's custom view as native, so `hasLoweredContentNode`
                // would otherwise be false for such a view — `AccountSwitcher`).
                // DEAD-BUTTON GATE: a Button in a MODIFIER-ACTION LIST (alert /
                // confirmationDialog / toolbar / Menu / contextMenu) whose action is real but
                // NOT a recordable dispatch rule would RENDER from WASM yet do NOTHING on tap —
                // and the renderer can't slot a native control into an actions list. The emitter
                // flagged it (`hasUndispatchableAction`); force the view native (fully
                // functional) rather than auto-route it with a dead control.
                // DEAD/DESTRUCTIVE-EFFECT GATE: a BEHAVIORAL/LIFECYCLE modifier whose effect
                // isn't faithfully produced on device — `.task`/`.onChange` with a real closure
                // (never dispatched: no guest rule / the renderer attaches no value-watcher),
                // `.onDelete`/`.onMove` (a scalar-only guest can't apply the array mutation → the
                // delete/move silently reverts — a DATA-INTEGRITY bug), or `.onAppear`/
                // `.onDisappear`/`.onSubmit`/gestures with a non-trivial unrecordable closure.
                // A modifier closure has no native-slot fallback, so the WHOLE view must demote
                // (its real modifier then runs natively = production behavior).
                let thunkSafe = lowered.opaqueLeaves.allSatisfy { $0.slotable }
                    && (report.hasPatchableLoweredElement || !lowered.indexedRowSlots.isEmpty
                        || !lowered.actionSlots.isEmpty || !lowered.effectSlots.isEmpty
                        || !lowered.callbackSlots.isEmpty)
                    && !lowered.hasUndispatchableAction
                    && !lowered.hasUndispatchableEffect
                if lowered.hasUndispatchableAction && demoteReasons[lowered.viewName] == nil {
                    demoteReasons[lowered.viewName] = "has a Button in an alert/toolbar/menu "
                        + "actions list whose action isn't a guest-dispatchable rule (a complex "
                        + "action — Task/method call/multi-statement) — kept native so the control "
                        + "stays functional (an actions-list entry can't be a native slot)"
                }
                if lowered.hasUndispatchableEffect && demoteReasons[lowered.viewName] == nil {
                    demoteReasons[lowered.viewName] = "has a behavioral/lifecycle modifier whose "
                        + "effect can't be faithfully dispatched on device (a real .task/.onChange, "
                        + ".onDelete/.onMove, or a non-trivial .onAppear/.onDisappear/.onSubmit/"
                        + "gesture closure) — kept native so the effect actually runs (a .task that "
                        + "routed would render the screen EMPTY; an .onDelete would silently revert)"
                }
                // PARAMETERIZED NATIVE SLOTS: collect the lifted string-literal values
                // for every opaque slot that parameterized them, keyed by structural id,
                // so the guest bakes the CURRENT literals into `BodyEmission.slotArgs`.
                var slotArgs: [String: [String]] = [:]
                for leaf in lowered.opaqueLeaves where !leaf.stringArgs.isEmpty {
                    slotArgs[leaf.id] = leaf.stringArgs
                }
                guestViews.append(.init(viewName: lowered.viewName,
                                        guestBody: lowered.guestBody,
                                        inputs: lowered.inputs,
                                        stateModel: lowered.stateModel,
                                        thunkSafe: thunkSafe,
                                        usesGeometry: lowered.usesGeometry,
                                        inputTokens: lowered.hostTokens.filter { $0.ridesInputJSON },
                                        slotArgs: slotArgs,
                                        // Per-view IR-version gate: a reactive-collection-marshalling
                                        // view needs the SDK's v9 reactive-extract, and a view using a
                                        // NATIVE-ACTION SLOT carries the v9 `actionSlotButton` node; a
                                        // view using a NATIVE EFFECT-MODIFIER SLOT carries the v10
                                        // `nativeEffectSlot` Modifier case — an older host (without the
                                        // case) would fail to decode the whole tree, so gate it to the
                                        // matching version so such a host demotes ONLY this view (not its
                                        // siblings) to native instead of collapsing it. A view using
                                        // `.animation(_:value:)` needs the v11 renderer (an older host
                                        // NO-OPs the animation → renders the value change instantly, a
                                        // silently degraded effect), so gate it to v11 so an older host
                                        // demotes ONLY this view (where the real implicit animation runs)
                                        // instead of degrading it. Higher gates take precedence (max wins).
                                        minSchemaVersion:
                                            !lowered.callbackSlots.isEmpty ? 12
                                            : lowered.usesAnimationValue ? 11
                                            : !lowered.effectSlots.isEmpty ? 10
                                            : (lowered.usesReactiveMarshalling || !lowered.actionSlots.isEmpty) ? 9 : 8,
                                        // NATIVE-FAST-PATH: the per-view body content hash, computed by the
                                        // SAME `BodyLowering.viewBodyContentHash` over the SAME `LoweredView`
                                        // the ThunkGenerator hashes for its baked `baselineHash`. Equal by
                                        // construction for an unpatched view → the SDK renders native (no WASM).
                                        bodyHash: BodyLowering.viewBodyContentHash(lowered),
                                        // STRUCTURALLY-STATIC CACHE: the engine proved the tree is identical
                                        // across ALL inputs. The SDK caches after the first WASM call and
                                        // skips WASM on all subsequent renders. Propagated from `LoweredView`.
                                        isStructurallyStatic: lowered.isStructurallyStatic))
                totalElements += report.totalElements
                totalWasm += report.loweredElements
                detail.append((view: lowered.viewName, export: sym,
                               elements: report.totalElements, wasm: report.loweredElements))
                log("lowered \(lowered.viewName): \(report.loweredElements)/\(report.totalElements) elements WASM")
            }
        }
        guard !guestViews.isEmpty else {
            // Surface a non-verbose warning if we EXCLUDED views but ended up with
            // nothing to ship (the dev would otherwise see only "Build succeeded").
            warnDemotedViews(excludedViews, declined: !excludedViews.isEmpty, reasons: demoteReasons)
            log("no lowerable View body found — declining")
            return nil
        }

        // (2+3) Emit + compile the guest module, with PER-VIEW ISOLATION on failure.
        //
        // All view exports live in ONE `_PatchSwiftUI.swift` wrapper, so historically a
        // SINGLE view whose emitted body didn't compile (a construct the static scope
        // guard above didn't catch — a genuinely un-WASM-able reference) demoted the
        // WHOLE module → zero views shipped (the #1 real-app blast radius). We now
        // BISECT: when the wrapper fails to compile, attribute the failing line(s) to
        // the offending view function(s), drop ONLY those views, RE-EMIT the wrapper
        // without them, and retry. So the ~40 healthy views still ship even if one or
        // two can't compile. The static guard makes this the rare path; this is the
        // robustness backstop. The loop is bounded (drops ≥1 view per iteration, or
        // bails) so it always terminates.
        let guestEmitter = SwiftUIGuestEmitter()
        let swBuildDir = buildDir.appendingPathComponent("swiftui")
        try fm.createDirectory(at: swBuildDir, withIntermediateDirectories: true)
        let swModuleURL = defaultModule.deletingPathExtension()
            .appendingPathExtension("swiftui.wasm")
        let convergence = WasmConvergence(compiler: compiler)

        var activeViews = guestViews
        var isolatedViews: [String] = []   // views dropped by the bisecting isolation
        var lastOutcome: WasmConvergence.Outcome?
        var lastOfferedCount = 0
        // Bound iterations by the view count (each iteration drops ≥1 view or breaks).
        let maxIsolation = guestViews.count + 1
        var isolationIter = 0
        emitCompileLoop: while !activeViews.isEmpty && isolationIter < maxIsolation {
            isolationIter += 1
            let emission = try guestEmitter.emit(views: activeViews)
            var wasmSources: [URL] = []
            var exportsBySource: [URL: [String]] = [:]
            let offeredExports = emission.exports.filter { $0 != "patch_malloc" && $0 != "patch_free" }
            lastOfferedCount = offeredExports.count
            var wrapperURL: URL?
            for f in emission.files {
                let url = swBuildDir.appendingPathComponent(f.fileName)
                try f.contents.write(to: url, atomically: true, encoding: .utf8)
                wasmSources.append(url)
                exportsBySource[url] = (f.fileName == "_PatchSwiftUI.swift") ? emission.exports : []
                if f.fileName == "_PatchSwiftUI.swift" { wrapperURL = url }
            }
            if isolationIter == 1 {
                log("\(activeViews.count) view(s) lowered; \(offeredExports.count) view export(s); emitting guest module")
            } else {
                log("re-emitting guest module without \(isolatedViews.count) isolated view(s): \(activeViews.count) view(s), \(offeredExports.count) export(s)")
            }

            let candidates = wasmSources.map {
                WasmConvergence.Candidate(functionID: $0.lastPathComponent, sourceFile: $0,
                                          exports: exportsBySource[$0] ?? [])
            }
            let outcome = try convergence.converge(candidates, outputModule: swModuleURL,
                                                   startTier: .t2Foundation)
            lastOutcome = outcome
            // SHIP iff a module compiled AND it actually carries view exports. A subtle
            // trap: the convergence loop is FILE-level — on a wrapper compile error it
            // demotes the whole `_PatchSwiftUI.swift` candidate, then the leftover IR
            // SUPPORT files compile cleanly and it returns a NON-nil module that exports
            // ZERO views. We must NOT treat that as success — bisect to recover the
            // healthy views instead.
            let shipped = outcome.compiled.flatMap(\.exports)
                .filter { $0 != "patch_malloc" && $0 != "patch_free" }
            if outcome.moduleURL != nil, !shipped.isEmpty {
                break emitCompileLoop   // compiled WITH view exports — ship it.
            }
            // The wrapper failed to compile (or shipped no exports). Attribute the
            // failure to specific view FUNCTIONS in the wrapper (by mapping each error's
            // line to the view whose `_patchBuildTree__<View>` region contains it). Drop
            // those views and re-emit so the healthy views still ship.
            guard let wrapperURL,
                  let wrapperText = try? String(contentsOf: wrapperURL, encoding: .utf8) else {
                break emitCompileLoop
            }
            let blamed = Self.viewsBlamedByCompileError(
                log: outcome.log, wrapperFileName: wrapperURL.lastPathComponent,
                wrapperText: wrapperText, views: activeViews.map(\.viewName))
            guard !blamed.isEmpty else {
                // No single view attributable (a module-wide failure: a shared helper /
                // IR support source — or the toolchain is unavailable). Bisecting can't
                // help — give up (decline). The `lastOutcome` (possibly an export-less
                // module) is handled by the post-loop `shippedExports.isEmpty` guard.
                log("guest module compile failed with no attributable view — declining")
                break emitCompileLoop
            }
            isolatedViews.append(contentsOf: blamed)
            let blamedSet = Set(blamed)
            activeViews.removeAll { blamedSet.contains($0.viewName) }
            for v in blamed {
                log("ISOLATE \(v): emitted body failed the guest compile — dropping it so the other views still ship")
            }
        }

        // The detail/exclusion bookkeeping below treats isolated views the same as
        // up-front exclusions (both render natively, not OTA-patchable).
        excludedViews.append(contentsOf: isolatedViews)
        let offeredExports = lastOfferedCount
        let outcome = lastOutcome ?? WasmConvergence.Outcome(
            compiled: [], reclassifiedNative: [], moduleURL: nil,
            toolchainUnavailable: false, iterations: 0, log: "")
        let shippedExports = outcome.compiled.flatMap { $0.exports }
            .filter { $0 != "patch_malloc" && $0 != "patch_free" }
        log("guest module converged: \(outcome.compiled.count) compiled, \(outcome.reclassifiedNative.count) demoted; \(offeredExports) export(s) offered")
        guard outcome.moduleURL != nil, !shippedExports.isEmpty else {
            log("guest module shipped no view export — declining")
            // The guest module DECLINED to compile (or shipped no view export) — the
            // dev pushed expecting OTA-patchable views and gets a default-only module.
            // Warn non-verbosely (DEFECT 5): every candidate view + any excluded one.
            warnDemotedViews(detail.map { $0.view } + excludedViews, declined: true, reasons: demoteReasons)
            return nil
        }
        // Only count views whose export actually shipped (a demoted candidate file
        // drops its exports — though v1 is one unit, this stays honest).
        let shipped = Set(shippedExports)
        let shippedDetail = detail.filter { shipped.contains($0.export) }
        // Non-verbose warning (DEFECT 5): any candidate view that did NOT ship — either
        // EXCLUDED up front (non-reconstructable input) or DEMOTED by the convergence
        // loop — renders natively and is not OTA-patchable. Without this the dev sees
        // only "✓ Build succeeded" and no clue why a view doesn't update on device.
        let shippedNames = Set(shippedDetail.map { $0.view })
        let demotedByConvergence = detail.map { $0.view }.filter { !shippedNames.contains($0) }
        warnDemotedViews(excludedViews + demotedByConvergence, declined: false, reasons: demoteReasons)
        // Recompute element totals over the shipped views.
        var elems = 0, wasm = 0
        for d in shippedDetail { elems += d.elements; wasm += d.wasm }
        return SwiftUILoweringResult(
            loweredViewBodies: shippedDetail.count,
            loweredViewElements: elems,
            loweredViewElementsWasm: wasm,
            loweredViews: shippedDetail,
            moduleURL: outcome.moduleURL,
            exports: shippedExports)
    }

    // MARK: - UIKit cell lowering (the UIKit analogue of runSwiftUILowering)

    struct UIKitLoweringResult {
        let loweredCells: Int
        let detail: [(cell: String, export: String)]
        let moduleURL: URL?
        let exports: [String]
    }

    /// The opt-in UIKit cell lowering path. Scans every `.swift` file under `sourceDir`
    /// for reusable-cell subclasses with a declarative `configure(with:)`/`setup()`,
    /// lowers each to the UIKitNode IR via `UIKitCellLowering`, emits a guest
    /// `uikit_configure` module, and compiles it to `module.uikit.wasm`. Returns nil
    /// when no cell lowered or nothing compiled. Demote-safe: a cell whose construction
    /// isn't the recognized grammar is skipped (stays native).
    func runUIKitLowering(
        sourceDir: URL, buildDir: URL,
        compiler: WasmCompiling, defaultModule: URL
    ) throws -> UIKitLoweringResult? {
        let fm = FileManager.default
        let verbose = ProcessInfo.processInfo.environment["PATCH_SWIFTUI_VERBOSE"] != nil
        func log(_ s: String) { if verbose { FileHandle.standardError.write(Data("[uikit] \(s)\n".utf8)) } }

        // (1) Scan source for cells + lower each construction.
        let lowering = UIKitCellLowering()
        var guestCells: [UIKitGuestEmitter.GuestCell] = []
        var detail: [(cell: String, export: String)] = []
        var seenExports = Set<String>()
        var excluded: [String] = []
        for file in swiftFiles(in: sourceDir) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Cheap pre-filter: only files that mention a cell OR a view/VC base class
            // (Goal 2 added programmatic-VC `setupViews`/`viewDidLoad` lowering).
            guard source.contains("Cell") || source.contains("ReusableView")
                    || source.contains("UIViewController") || source.contains("UIView")
            else { continue }
            for cell in lowering.lowerAllCells(source: source) {
                let sym = UIKitGuestEmitter.exportSymbol(forCell: cell.typeName)
                guard seenExports.insert(sym).inserted else {
                    log("skip \(cell.typeName): export `\(sym)` collides with an earlier cell"); continue
                }
                // EXCLUDE a cell that reads a non-reconstructable model field (would not
                // compile in the single guest unit) — it renders native.
                if cell.referencesUnmarshalledInput {
                    excluded.append(cell.typeName)
                    log("EXCLUDE \(cell.typeName): reads a non-reconstructable model field"); continue
                }
                guestCells.append(UIKitGuestEmitter.GuestCell(from: cell))
                detail.append((cell: cell.typeName, export: sym))
                log("lowered \(cell.typeName) → \(sym)")
            }
        }
        guard !guestCells.isEmpty else { log("no lowerable cell found — declining"); return nil }

        // (2) Emit the guest module (shared + UIKit IR + the uikit_configure wrapper).
        let emission = try UIKitGuestEmitter().emit(cells: guestCells)
        let ukBuildDir = buildDir.appendingPathComponent("uikit")
        try fm.createDirectory(at: ukBuildDir, withIntermediateDirectories: true)
        var wasmSources: [URL] = []
        var exportsBySource: [URL: [String]] = [:]
        for f in emission.files {
            let url = ukBuildDir.appendingPathComponent(f.fileName)
            try f.contents.write(to: url, atomically: true, encoding: .utf8)
            wasmSources.append(url)
            exportsBySource[url] = (f.fileName == "_PatchUIKit.swift") ? emission.exports : []
        }
        log("\(guestCells.count) cell(s) lowered; emitting guest module")

        // (3) Compile the guest module (Foundation T2 tier, like the SwiftUI guest).
        let ukModuleURL = defaultModule.deletingPathExtension().appendingPathExtension("uikit.wasm")
        let candidates = wasmSources.map {
            WasmConvergence.Candidate(functionID: $0.lastPathComponent, sourceFile: $0,
                                      exports: exportsBySource[$0] ?? [])
        }
        let outcome = try WasmConvergence(compiler: compiler).converge(
            candidates, outputModule: ukModuleURL, startTier: .t2Foundation)
        let shippedExports = outcome.compiled.flatMap { $0.exports }
            .filter { $0 != "patch_malloc" && $0 != "patch_free" }
        guard outcome.moduleURL != nil, !shippedExports.isEmpty else {
            log("UIKit guest module shipped no cell export — declining")
            return nil
        }
        let shipped = Set(shippedExports)
        let shippedDetail = detail.filter { shipped.contains($0.export) }
        return UIKitLoweringResult(
            loweredCells: shippedDetail.count, detail: shippedDetail,
            moduleURL: outcome.moduleURL, exports: shippedExports)
    }

    /// Surface a concise NON-verbose warning (stderr) when ≥1 SwiftUI view could not
    /// be lowered to WASM — excluded up front (a non-reconstructable input) or demoted
    /// by the guest compile. Without this the build prints only "✓ Build succeeded" and
    /// the dev gets ZERO clue why a pushed view doesn't render on device (DEFECT 5).
    /// `declined` ⇒ the whole guest module shipped no view export (everything native).
    /// De-duplicates, sorts, and caps the named list so the line stays scannable.
    private func warnDemotedViews(_ names: [String], declined: Bool,
                                  reasons: [String: String] = [:]) {
        let unique = Array(Set(names)).sorted()
        guard !unique.isEmpty else { return }
        let shown = unique.prefix(8).joined(separator: ", ")
        let more = unique.count > 8 ? " (+\(unique.count - 8) more)" : ""
        let n = unique.count
        let noun = n == 1 ? "view" : "views"
        // When the whole guest module declined, NO view ships over the air at all;
        // otherwise these specific views fell back while the rest still ship.
        let lead = declined
            ? "⚠ SwiftUI lowering shipped no view export — \(n) \(noun) will render natively"
            : "⚠ \(n) SwiftUI \(noun) could not be lowered to WASM and will render natively"
        var msg = lead + " (not OTA-patchable): \(shown)\(more).\n"
        // DIAGNOSTIC: per-view WHY (the actionable cause), so the dev doesn't need to
        // re-run with PATCH_SWIFTUI_VERBOSE. Capped + sorted to stay scannable.
        let withReasons = unique.filter { reasons[$0] != nil }.prefix(8)
        for v in withReasons {
            msg += "    • \(v): \(reasons[v]!)\n"
        }
        // The SwiftData wall is the #1 modern-app blocker — surface a headline count.
        let sdViews = unique.filter { (reasons[$0] ?? "").contains("SwiftData") }
        if !sdViews.isEmpty {
            msg += "  → \(sdViews.count) blocked by SwiftData (@Query/@Model/modelContext) — "
                + "today these views render natively; move data reads behind a value-type "
                + "view model to make them OTA-patchable.\n"
        }
        // The verbose flag still gives ADDITIONAL detail (per-element t2Foundation
        // reasons, the full lowering table) beyond the one-line per-view cause, so always
        // point at it.
        msg += "  Set PATCH_SWIFTUI_VERBOSE=1 for the full per-element breakdown.\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    /// Attribute a guest-module compile failure to the specific VIEW(s) whose emitted
    /// functions the diagnostics blame — so the bisecting isolation can drop ONLY those
    /// and re-emit the wrapper without them (keeping the healthy views shipping).
    ///
    /// All view exports share one `_PatchSwiftUI.swift` wrapper, so the convergence loop
    /// (file-level) can only demote the WHOLE wrapper. We go finer: every error line in
    /// the wrapper carries a 1-based line number (`…/_PatchSwiftUI.swift:713:67: error:`);
    /// we map each such line to the view whose emitted region contains it. The emitter
    /// writes a stable per-view marker comment (`// Build the lowered \`<View>\` tree …`)
    /// immediately before each view's `_patchBuildTree__<View>`; the region from one
    /// marker to the next belongs to that view (its build-tree fn + body, the `@_cdecl`
    /// export, and any interactive state/update/dispatch — all emitted contiguously per
    /// view). Returns the deduped blamed view names (in `views` order). Empty ⇒ the
    /// failure is NOT attributable to any single view (a shared helper / IR support
    /// source / preamble region), so bisecting would not help.
    static func viewsBlamedByCompileError(
        log: String, wrapperFileName: String, wrapperText: String, views: [String]
    ) -> [String] {
        // Build the marker → line-number index from the wrapper text. The marker line
        // is `// Build the lowered \`<View>\` tree from a flat state/inputs JSON blob.`
        let wrapperLines = wrapperText.split(separator: "\n", omittingEmptySubsequences: false)
        // viewName → first line (1-based) of its region.
        var regionStart: [(name: String, line: Int)] = []
        let viewSet = Set(views)
        for (idx, line) in wrapperLines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("// Build the lowered `") else { continue }
            // Extract the backticked name.
            guard let open = trimmed.range(of: "`"),
                  let close = trimmed.range(of: "`", range: open.upperBound..<trimmed.endIndex)
            else { continue }
            let name = String(trimmed[open.upperBound..<close.lowerBound])
            // The marker carries the ORIGINAL (unsanitized) view name. Map it back to a
            // known view (markers are emitted with `v.viewName`, so it matches exactly).
            if viewSet.contains(name) {
                regionStart.append((name: name, line: idx + 1))  // 1-based
            }
        }
        guard !regionStart.isEmpty else { return [] }
        // Sort regions by start line; each view owns [start, nextStart).
        regionStart.sort { $0.line < $1.line }
        func viewOwning(line: Int) -> String? {
            var owner: String?
            for region in regionStart {
                if region.line <= line { owner = region.name } else { break }
            }
            return owner
        }

        // Parse error lines that blame the wrapper file, pull the line number, map it.
        var blamed: [String] = []
        var seen = Set<String>()
        for logLine in log.split(separator: "\n") where logLine.contains("error:") {
            let s = String(logLine)
            guard WasmConvergence.lineBlamesFile(logLine, wrapperFileName) else { continue }
            // Find `<wrapperFileName>:<line>:<col>:` and parse the line number.
            guard let r = s.range(of: wrapperFileName) else { continue }
            let after = s[r.upperBound...]
            // Expect `:<digits>:`
            guard after.first == ":" else { continue }
            let rest = after.dropFirst()
            let digits = rest.prefix { $0.isNumber }
            guard let lineNo = Int(digits) else { continue }
            if let owner = viewOwning(line: lineNo), seen.insert(owner).inserted {
                blamed.append(owner)
            }
        }

        // [R2-#33] WHOLE-FILE / SUPPORT-REGION BLAST RADIUS. A compile error in a SHARED
        // support definition (`struct _PatchRow_<Type>` / `enum _PatchEnum_<Type>`, emitted
        // per element type and used by MANY views) names a line OUTSIDE every per-view
        // region, so the line-based blame above finds no owner and the caller declines the
        // WHOLE module — dropping ~40 healthy views because ONE view's element type can't
        // be reconstructed. When line-based blame found NOTHING, fall back to CONTENT
        // attribution: pull each error's referenced support symbol / type name and blame
        // the view regions whose text references it (so only the views depending on the bad
        // type are dropped, and the healthy ones still ship). This only ever NARROWS the
        // decline (it runs solely when the whole module would otherwise be dropped), so it
        // is strictly a coverage win and never mis-attributes a healthy view.
        if blamed.isEmpty {
            // Region text per view (its [start, nextStart) line slice), lowercased once.
            func regionText(forIndex i: Int) -> String {
                let start = regionStart[i].line                       // 1-based
                let end = (i + 1 < regionStart.count) ? regionStart[i + 1].line - 1 : wrapperLines.count
                guard start >= 1, end >= start, end <= wrapperLines.count else { return "" }
                return wrapperLines[(start - 1)..<end].joined(separator: "\n")
            }
            // Collect referenced symbols from the error log: support symbols + any
            // 'Quoted' identifier the compiler names ("cannot find type 'Item'").
            var symbols = Set<String>()
            for logLine in log.split(separator: "\n") where logLine.contains("error:") {
                let s = String(logLine)
                for tok in s.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }) {
                    let t = String(tok)
                    if t.hasPrefix("_PatchRow_") || t.hasPrefix("_PatchEnum_") { symbols.insert(t) }
                }
                // Single-quoted identifiers (`'Item'`, `'_PatchRow_Item'`).
                var idx = s.startIndex
                while let open = s.range(of: "'", range: idx..<s.endIndex),
                      let close = s.range(of: "'", range: open.upperBound..<s.endIndex) {
                    let name = String(s[open.upperBound..<close.lowerBound])
                    if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                        symbols.insert(name)
                    }
                    idx = close.upperBound
                }
            }
            if !symbols.isEmpty {
                for i in regionStart.indices {
                    let text = regionText(forIndex: i)
                    if symbols.contains(where: { text.contains($0) }),
                       seen.insert(regionStart[i].name).inserted {
                        blamed.append(regionStart[i].name)
                    }
                }
            }
        }

        // Return in the caller's view order for stable logs.
        return views.filter { blamed.contains($0) }
    }

    // MARK: - Real-source closure compilation (PATCH_REAL_SOURCE)

    /// Result of the additive real-source build: how many extra units compiled, the
    /// extra module path, and the export symbols it added (beyond the default engine).
    struct RealSourceAddition { let compiledUnits: Int; let moduleURL: URL?; let addedExports: [String] }

    /// The opt-in real-source path (research/wave3/BREAKTHROUGH-real-source-
    /// compilation.md): compile `@_cdecl` export wrappers against the developer's REAL,
    /// verbatim module source under the WASM SDK, letting the actual Swift compiler
    /// resolve types/generics/protocols — instead of the default engine RECONSTRUCTING
    /// value types / abstracting locals (which demotes classes/protocols/generics
    /// outright). Demote ONLY on a real compile failure (the convergence loop's
    /// guarantee, via `RealSourceWasmCompiler`).
    ///
    /// ADDITIVE: builds a SECOND module of the eligible functions the DEFAULT engine
    /// could NOT ship (`alreadyShipped` holds the default module's exports, so we never
    /// duplicate one). The default module is left untouched — a canary can only GAIN.
    ///
    /// COARSE first increment (per the brief): the compile unit is the whole admissible
    /// module source (Euclid compiles whole-library). A clean export's wrapper rides it;
    /// a wrapper referencing a genuinely-native symbol fails + demotes alone. Returns
    /// nil (no extra module) when there is no admissible source or no NEW eligible export.
    func runRealSourceAdditive(
        report: CoverageReport, sourceDir: URL, buildDir: URL,
        pureByFile: [URL: Set<String>], scanner: PureExportScanner,
        valueTypeNames: Set<String>,
        emitter: CodeEmitter, compiler: WasmCompiling,
        alreadyShipped: Set<String>, defaultModule: URL
    ) throws -> RealSourceAddition? {
        let fm = FileManager.default
        let verbose = ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_VERBOSE"] != nil
        func log(_ s: String) { if verbose { FileHandle.standardError.write(Data("[real-source] \(s)\n".utf8)) } }

        // (1) Real module source files — the closure the wrappers ride. Include ALL the
        // module's real source and let the WASM compiler's own `#if canImport(...)` /
        // `#if !arch(wasm32)` evaluation inert the genuinely-native bits (the prototype
        // proved the whole Euclid library compiles to a valid .wasm — its AppKit/
        // SceneKit/Dispatch references are all behind such guards). We exclude only a
        // file whose UNCONDITIONAL top-level import is a native-only module, the SwiftPM
        // manifest (poisons the closure with `no such module 'PackageDescription'`), and
        // files in actual test/example/plugin DIRECTORIES. We re-walk (not `allFiles`)
        // because the engine's `isTestFile` filter wrongly drops production files NAMED
        // like a test (CryptoSwift's `PrimeTest.swift`, which DEFINES `isPrime`).
        let realSources = realSourceClosureFiles(in: sourceDir).filter { url in
            guard Self.realSourceURLAdmissible(url),
                  let s = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return Self.realSourceFileAdmissible(s)
        }
        guard !realSources.isEmpty else { log("no admissible module source — declining"); return nil }

        let moduleName = realSourceModuleName(realSources: realSources, sourceDir: sourceDir)
        log("module=\(moduleName), \(realSources.count) real source files; default already shipped \(alreadyShipped.count) exports")

        // FUSION: widen the eligible set. Normally only `.wasmEligible` (pure) functions
        // are offered to the scanner; a function blocked ONLY by a fusion-bridgeable leaf
        // is classified `.bridged`/`.mixed` and excluded. When fusion is on, ALSO offer
        // those — the leaf will be rewritten to a host bridge, so the function compiles.
        // A function whose body reaches a NON-fusable native symbol is still excluded
        // (and, if offered by mistake, fails the real compile and demotes alone).
        var eligibleByFile = pureByFile
        if ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_FUSION"] != nil {
            let added = fusionEligibleByFile(report)
            for (file, names) in added { eligibleByFile[file, default: []].formUnion(names) }
            let addedCount = added.values.reduce(0) { $0 + $1.count }
            if addedCount > 0 { log("fusion: +\(addedCount) fusion-eligible function(s) offered") }
        }

        // (2) Scan every pure-eligible function → emit a Foundation JSON wrapper per
        // export NOT already shipped by the default engine. We emit for ALL such
        // eligible exports (the real compiler is the arbiter, not the reconstruction
        // gate). A wrapper that references a genuinely-native symbol fails the real
        // compile and demotes ALONE.
        let rsBuildDir = buildDir.appendingPathComponent("realsource")
        try fm.createDirectory(at: rsBuildDir, withIntermediateDirectories: true)
        var wrapperSources: [URL] = []
        var exportsBySource: [URL: [String]] = [:]
        var addedExports: [String] = []
        var emittedNames = Set<String>()
        // DECL-LEVEL: the extractor seeds (one set of dotted callees / type names per
        // emitted export) so we can pull the MINIMAL decl closure instead of the whole
        // module. Empty when decl-level is off.
        var declSeeds: [String] = []
        // BREAKTHROUGH #9 — track whether EVERY emitted wrapper took the embedded
        // (T0) host-bridge form. If so the whole additive module can START at T0
        // (the order-of-magnitude size win). A single Foundation-fallback wrapper
        // (a struct/array boundary the host bridge can't reduce) means the compile
        // unit has in-module Foundation → start at T2. Either way the convergence
        // loop ESCALATES on a real embedded-link failure, so this is only the start
        // guess, never a final verdict.
        var allWrappersT0 = true
        // DECL-LEVEL T0 ISOLATION: per-wrapper metadata so the isolation pass can
        // compute EACH export's own minimal decl closure + route it independently.
        var emittedWrappers: [EmittedWrapper] = []
        // VALUE-TYPE RECEIVER AT T0: a decl index over the real module source so we can
        // resolve a receiver's (and a value-type arg's) reconstruction shape — stored
        // fields + init labels — and enrich each export. An instance-method export whose
        // receiver/args are flat-scalar value types then rides T0 (instance-method math
        // like `v.dot(u)` / `v.length`) instead of being forced to the ~60 MB T2 tier.
        let shapeBundler = DependencyClosureBundler(registry: registry)
        let shapeIndex = shapeBundler.index(for: realSources)
        // BREAKTHROUGH-#7 context over the real-source closure (same gates apply).
        let rsGenericContext: GenericSpecializer.Context =
            ProcessInfo.processInfo.environment["PATCH_GENERICS_B7"] == "0"
            ? .empty
            : buildGenericContext(allFiles: realSources, declIndex: shapeIndex)
        for (file, names) in eligibleByFile.sorted(by: { $0.key.path < $1.key.path }) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let scanned = scanner.scan(source: source, eligibleSimpleNames: names,
                                       valueTypeNames: valueTypeNames, bundleKey: file.path,
                                       genericContext: rsGenericContext)
            let exps = scanned.map { enrichValueTypeShapes($0, bundler: shapeBundler, index: shapeIndex) }
            for export in exps where !emittedNames.contains(export.exportName) {
                // Skip exports the default engine already shipped (no duplicates).
                let sym = CodeEmitter.sanitizedExportSymbol(export.exportName)
                if alreadyShipped.contains(sym) || alreadyShipped.contains(export.exportName) { continue }
                let (fileName, src, exports, t0Eligible) = emitRealSourceWrapper(emitter, export)
                guard !exports.isEmpty else { continue }
                if !t0Eligible { allWrappersT0 = false }
                emittedNames.insert(export.exportName)
                let wasmURL = rsBuildDir.appendingPathComponent("_PatchReal_" + fileName)
                try src.write(to: wasmURL, atomically: true, encoding: .utf8)
                wrapperSources.append(wasmURL)
                exportsBySource[wasmURL] = exports
                addedExports.append(contentsOf: exports.filter { $0 != "patch_malloc" && $0 != "patch_free" })
                let seeds = declSeedsFor(export)
                declSeeds.append(contentsOf: seeds)
                emittedWrappers.append(EmittedWrapper(
                    wasmURL: wasmURL, exports: exports, seeds: seeds, t0Eligible: t0Eligible))
            }
        }
        guard !wrapperSources.isEmpty else { log("no NEW eligible pure export — declining"); return nil }
        log("\(wrapperSources.count) additive export wrappers emitted (all-T0=\(allWrappersT0))")

        // BREAKTHROUGH #9 — start tier. When every wrapper is the embedded (T0)
        // host-bridge form the whole module can start at T0 (the ~60 MB → ~110 KB
        // win); otherwise a Foundation wrapper forces T2. An env override
        // (PATCH_REAL_SOURCE_NO_T0) pins T2 for A/B measurement / a kill-switch.
        let t0Routed = allWrappersT0
            && ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_NO_T0"] == nil
        let startTier: PackagingTier = t0Routed ? .t0Embedded : .t2Foundation
        log("real-source start tier: \(startTier.rawValue)")

        // (3) Shared runtime (the single allocator). Never demoted. At T0 it MUST be
        // the embedded (Foundation-free) allocator — a single `import Foundation`
        // anywhere poisons the whole embedded compile.
        let runtime = startTier == .t0Embedded
            ? emitter.emitEmbeddedModuleRuntimeFile()
            : emitter.emitModuleRuntimeFile()
        let runtimeURL = rsBuildDir.appendingPathComponent("_PatchRuntime.swift")
        try runtime.source.write(to: runtimeURL, atomically: true, encoding: .utf8)
        let usesRealSourceAdapter = compiler is SwiftWasmCompiler

        // (4) The additive module is a SECOND `.wasm` alongside the default. (Merging
        // the two into one module is a linker step left as follow-up; reporting them
        // separately keeps the default module's coverage guaranteed-intact.)
        let rsModuleURL = defaultModule.deletingPathExtension()
            .appendingPathExtension("realsource.wasm")
        let candidates = wrapperSources.map {
            WasmConvergence.Candidate(functionID: $0.lastPathComponent, sourceFile: $0,
                                      exports: exportsBySource[$0] ?? [])
        }
        let maxIter = ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_MAXITER"]
            .flatMap(Int.init) ?? max(64, candidates.count + 8)

        // FUSION (breakthrough #2): gated by PATCH_REAL_SOURCE_FUSION (within the
        // PATCH_REAL_SOURCE path). When on, each closure's bridgeable native leaves
        // (UserDefaults/Locale/logging — the registry `.bridgeable` set) are rewritten
        // to `patch`/`patch_host` host-bridge imports BEFORE the compile, and a
        // FusionCHost target carrying those imports is added to the package. A function
        // that was pure value logic blocked ONLY by such a leaf now COMPILES; a leaf the
        // rewriter does not recognize (genuinely native) is untouched and still demotes
        // via the convergence loop. Additive + gated + demote-on-real-failure unchanged.
        let fusionEnabled = ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_FUSION"] != nil

        // One convergence attempt against a given real-source closure. The wrappers,
        // shared runtime, allocator + the SECOND-module additive contract are identical;
        // only the real-source closure (`closureSources`) differs.
        func attempt(_ closureSources: [URL], label: String) throws -> WasmConvergence.Outcome {
            var supportSources: [URL] = [runtimeURL]
            // FUSION: rewrite bridgeable leaves in the closure (no-op when disabled or
            // when no leaf matches — then `effectiveClosure == closureSources` and
            // `fusionFiles` is empty, i.e. the manifest stays single-target).
            let (effectiveClosure, fusionFiles) = try applyFusionRewrite(
                closureSources, enabled: fusionEnabled, moduleName: moduleName,
                rsBuildDir: rsBuildDir, label: label, log: log)
            // For the production compiler the REAL closure is injected module-named by
            // `RealSourceWasmCompiler`; for any OTHER `WasmCompiling` (a test recording
            // compiler that can't rename the package) include it as support sources.
            if !usesRealSourceAdapter { supportSources.append(contentsOf: effectiveClosure) }
            let realCompiler: WasmCompiling
            if let swiftWasm = compiler as? SwiftWasmCompiler {
                realCompiler = RealSourceWasmCompiler(
                    base: swiftWasm, moduleName: moduleName, realSources: effectiveClosure,
                    fusionBridgeFiles: fusionFiles)
            } else {
                realCompiler = compiler
            }
            var convergence = WasmConvergence(compiler: realCompiler)
            convergence.supportSources = supportSources
            let o = try convergence.converge(candidates, outputModule: rsModuleURL,
                                             startTier: startTier, maxIterations: maxIter,
                                             bailOnUnattributableFailure: true)
            log("[\(label)] converged: \(o.compiled.count) compiled, \(o.reclassifiedNative.count) demoted, \(o.iterations) iterations")
            if ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_DUMPLOG"] != nil {
                FileHandle.standardError.write(Data(o.log.utf8))
            }
            return o
        }

        // COARSE first: the whole admissible module source. It WINS wherever the entire
        // module compiles (Euclid, CryptoSwift) — its closure is complete, so it never
        // misses a fileprivate global / collides on a merged span. DECL-LEVEL is the
        // FALLBACK (PATCH_REAL_SOURCE_DECL): only when the coarse whole-module compile
        // ships NOTHING (a poison file — CAtomic, an external lib — failed the entire
        // unit) do we retry the SAME wrappers against the minimal decl closure that
        // routes AROUND the poison. Coarse-first + take-the-best makes decl-level
        // strictly additive: it can only convert apps coarse gets 0 on, never regress an
        // app coarse already ships.
        // BREAKTHROUGH #9 — T0 closure preprocessing. Real library files almost always
        // carry a defensive top-level `import Foundation` even when their code uses NO
        // genuine Foundation symbol. At T0 (embedded) that single import is fatal
        // (`no such module 'Foundation'`) and would force the whole module to escalate
        // to T1/T2 (~5.5–53 MB) — losing the entire size win. So when starting at T0,
        // compile against a STRIPPED copy of the closure: each file whose
        // embedded-compat verdict is T0 (no real Foundation/`any`/Mirror use) gets its
        // unconditional `import Foundation` removed; a file that GENUINELY needs
        // Foundation keeps the import and so fails the T0 compile — at which point the
        // convergence loop escalates to T1/T2 against the ORIGINAL (un-stripped)
        // closure (correctness preserved: the genuine-Foundation type still resolves).
        // We take the best of the two attempts, so this is strictly additive: it can
        // only make a Foundation-free closure tiny, never break a Foundation-needing one.
        let t0Stripping = startTier == .t0Embedded
            && ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_NO_T0_STRIP"] == nil
        var outcome: WasmConvergence.Outcome
        if t0Stripping {
            let stripped = try stripFoundationForT0(realSources, rsBuildDir: rsBuildDir, log: log)
            let t0Outcome = try attempt(stripped, label: "coarse-t0")
            if t0Outcome.compiled.isEmpty {
                // The stripped/T0 attempt shipped nothing (a file genuinely needs
                // Foundation, or another embedded blocker). Retry against the ORIGINAL
                // closure so the full SDK can resolve it (escalation lands at T1/T2).
                log("T0 attempt shipped 0 — retrying coarse against original closure (full SDK)")
                let fullOutcome = try attempt(realSources, label: "coarse-full")
                outcome = fullOutcome.compiled.count >= t0Outcome.compiled.count ? fullOutcome : t0Outcome
            } else {
                outcome = t0Outcome
            }
        } else {
            outcome = try attempt(realSources, label: "coarse")
        }
        if outcome.compiled.isEmpty,
           ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_DECL"] != nil {
            if let extracted = try extractDeclLevelRealSources(
                sourceDir: sourceDir, rsBuildDir: rsBuildDir, declSeeds: declSeeds, log: log) {
                let declOutcome = try attempt(extracted, label: "decl-level")
                if declOutcome.compiled.count > outcome.compiled.count { outcome = declOutcome }
            } else {
                log("decl-level extraction yielded no spans — keeping coarse outcome")
            }
        }

        // ---- DECL-LEVEL T0 ISOLATION (size optimizer) ---------------------------
        // The FINAL size lever. The coarse outcome above ships the whole additive
        // module at ONE tier — for a real library (Euclid, CryptoSwift) that's T2
        // (~60 MB) because some closure file mixes clean math with Foundation/Mirror.
        // This pass pulls every export whose OWN minimal decl closure is genuinely
        // embedded-clean into a TINY T0 module (the clean math), leaving T2 only for
        // the Foundation-touching remainder (or nothing). It runs EVEN WHEN coarse
        // succeeded at T2 (take-the-best), and ships via a PMOD container (tiny T0 +
        // only-if-needed T2). Gated by PATCH_REAL_SOURCE_DECL_ISOLATE; falls back to
        // the coarse outcome whenever isolation can't beat it (never a regression).
        if ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_DECL_ISOLATE"] != nil,
           compiler is SwiftWasmCompiler {
            if let isolated = try runDeclLevelT0Isolation(
                sourceDir: sourceDir, rsBuildDir: rsBuildDir, moduleName: moduleName,
                emittedWrappers: emittedWrappers, runtimeURL: runtimeURL,
                coarseClosure: realSources, compiler: compiler,
                rsModuleURL: rsModuleURL, coarse: outcome, log: log) {
                outcome = isolated
            }
        }

        let shippedExports = outcome.compiled.flatMap { $0.exports }
            .filter { $0 != "patch_malloc" && $0 != "patch_free" }
        return RealSourceAddition(compiledUnits: outcome.compiled.count,
                                  moduleURL: outcome.moduleURL,
                                  addedExports: shippedExports)
    }

    /// BREAKTHROUGH #9 — produce a T0 copy of the real-source closure with the
    /// defensive `import Foundation` removed from every file that does NOT genuinely
    /// use Foundation (its `EmbeddedCompatibility.analyzeSource` verdict is T0). A file
    /// that DOES use a real Foundation/`any`/Mirror symbol keeps its import verbatim,
    /// so it fails the embedded compile and the convergence loop escalates the whole
    /// unit to T1/T2 against the original closure (the take-the-best in the caller).
    ///
    /// Only an UNCONDITIONAL top-level `import Foundation` is removed (a `#if`-guarded
    /// import is left alone — the embedded compiler inerts it). The stripped copies are
    /// written into `rsBuildDir/t0closure/`; files needing no change pass through by
    /// path so the closure set is otherwise byte-identical. Conservative: stripping a
    /// truly-unused import can never change behavior; keeping an import that IS needed
    /// is handled by the escalation fallback.
    func stripFoundationForT0(_ closure: [URL], rsBuildDir: URL, log: (String) -> Void) throws -> [URL] {
        let fm = FileManager.default
        let compat = EmbeddedCompatibility()
        let outDir = rsBuildDir.appendingPathComponent("t0closure")
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        var out: [URL] = []
        var stripped = 0
        for (i, url) in closure.enumerated() {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { out.append(url); continue }
            // Keep the import iff the file genuinely needs Foundation (T0 verdict means
            // no real blocker — the only thing blocking T0 is the import line itself).
            let verdict = compat.analyzeSource(src)
            guard verdict.tier == .t0Embedded, Self.hasUnconditionalFoundationImport(src) else {
                out.append(url); continue
            }
            let rewritten = Self.removeUnconditionalFoundationImport(src)
            let dst = outDir.appendingPathComponent("\(i)_\(url.lastPathComponent)")
            try rewritten.write(to: dst, atomically: true, encoding: .utf8)
            out.append(dst)
            stripped += 1
        }
        if stripped > 0 { log("T0: stripped defensive `import Foundation` from \(stripped)/\(closure.count) Foundation-free closure file(s)") }
        return out
    }

    /// Whether `src` has an UNCONDITIONAL (not `#if`-guarded) top-level
    /// `import Foundation` (or `import FoundationEssentials`).
    static func hasUnconditionalFoundationImport(_ src: String) -> Bool {
        var ifDepth = 0
        for raw in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if") { ifDepth += 1; continue }
            if t.hasPrefix("#endif") { ifDepth = max(0, ifDepth - 1); continue }
            if t.hasPrefix("#else") || t.hasPrefix("#elseif") { continue }
            guard ifDepth == 0 else { continue }
            if t == "import Foundation" || t == "import FoundationEssentials" { return true }
            if let mod = importedModule(from: raw), mod == "Foundation" || mod == "FoundationEssentials" { return true }
        }
        return false
    }

    /// Remove every UNCONDITIONAL top-level `import Foundation`/`FoundationEssentials`
    /// line from `src` (guarded imports inside `#if … #endif` are kept). The removed
    /// line is replaced with a comment so line numbers in compiler diagnostics still
    /// line up with the original file.
    static func removeUnconditionalFoundationImport(_ src: String) -> String {
        var ifDepth = 0
        var lines: [String] = []
        for raw in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(raw)
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if") { ifDepth += 1; lines.append(s); continue }
            if t.hasPrefix("#endif") { ifDepth = max(0, ifDepth - 1); lines.append(s); continue }
            if t.hasPrefix("#else") || t.hasPrefix("#elseif") { lines.append(s); continue }
            if ifDepth == 0,
               (t == "import Foundation" || t == "import FoundationEssentials"
                || { if let m = importedModule(from: Substring(s)) { return m == "Foundation" || m == "FoundationEssentials" }; return false }()) {
                lines.append("// [Patch T0] removed unused defensive Foundation import")
                continue
            }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }

    /// FUSION (breakthrough #2): rewrite the bridgeable native leaves in a real-source
    /// closure to `patch`/`patch_host` host-bridge imports, and produce the package
    /// files for the `FusionCHost` C target + Swift bridge shims those rewrites call.
    ///
    /// Returns `(effectiveClosure, fusionFiles)`:
    ///   - `effectiveClosure`: the closure files to compile. For any file whose source
    ///     contained a recognized bridgeable leaf, a REWRITTEN copy (written into
    ///     `rsBuildDir`) replaces the original; untouched files pass through verbatim.
    ///   - `fusionFiles`: the FusionCHost header/shim + the Swift bridge shim (only the
    ///     leaves that actually fired). Empty when fusion is off or no leaf matched —
    ///     in which case `effectiveClosure == closureSources` and the compile is
    ///     byte-identical to the non-fusion real-source path.
    ///
    /// DEMOTE-SAFETY is preserved: the rewriter is conservative (only exact,
    /// syntactically-unambiguous bridgeable call forms are rewritten). A native symbol
    /// the rewriter does not recognize is left verbatim, so it still fails the real WASM
    /// compile and the dependent wrapper demotes alone via the convergence loop.
    func applyFusionRewrite(
        _ closureSources: [URL], enabled: Bool, moduleName: String,
        rsBuildDir: URL, label: String, log: (String) -> Void
    ) throws -> (closure: [URL], files: [RealSourceWasmCompiler.FusionPackageFile]) {
        guard enabled else { return (closureSources, []) }
        let fm = FileManager.default
        let rewriter = FusionRewriter()
        var effective: [URL] = []
        var firedLeaves = Set<String>()
        var rewrittenFiles = 0
        let rewriteDir = rsBuildDir.appendingPathComponent("fusion-\(label)")
        try? fm.createDirectory(at: rewriteDir, withIntermediateDirectories: true)

        for (i, url) in closureSources.enumerated() {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else {
                effective.append(url); continue
            }
            let result = rewriter.rewrite(src)
            guard result.didRewrite else { effective.append(url); continue }
            firedLeaves.formUnion(result.bridgedLeaves)
            rewrittenFiles += 1
            // Write the rewritten copy with a unique, original-derived name (de-dup by
            // index so two files with the same basename don't clobber).
            let dst = rewriteDir.appendingPathComponent("\(i)_\(url.lastPathComponent)")
            try result.source.write(to: dst, atomically: true, encoding: .utf8)
            effective.append(dst)
        }

        guard !firedLeaves.isEmpty else {
            log("[\(label)] fusion: no bridgeable leaf matched — closure unchanged")
            return (closureSources, [])
        }

        let bridges = rewriter.bridges(forLeaves: firedLeaves)
        let safeModule = SwiftWasmCompiler.sanitizedModuleName(moduleName)
        // The Swift bridge shim goes into the real module's target dir; use the
        // `__MODULE__` token so the compiler can substitute the package's actual
        // (sanitized) module name when it writes the file.
        let raw = rewriter.files(bridges: bridges, swiftTargetName: "__MODULE__",
                                 cTargetName: FusionRewriter.cTargetName)
        let files = raw.map {
            RealSourceWasmCompiler.FusionPackageFile(relativePath: $0.relativePath, contents: $0.contents)
        }
        _ = safeModule
        log("[\(label)] fusion: rewrote \(rewrittenFiles) file(s); bridged leaves: "
            + bridges.map { $0.id }.sorted().joined(separator: ", "))
        return (effective, files)
    }

    /// The extractor seeds for one pure export — the dotted callees / type names whose
    /// transitive decl closure the export's wrapper needs at the real boundary:
    ///   - an OPERATOR export rides its defining type (`BigUInt` carries `==`);
    ///   - an INSTANCE-method export seeds `<Receiver>.<callee>`;
    ///   - a FREE/STATIC function export seeds its `callee`;
    ///   - PLUS every nominal in the parameter/return signature (the Codable boundary
    ///     value types the in-module JSON envelope must round-trip).
    private func declSeedsFor(_ export: CodeEmitter.PureExport) -> [String] {
        var seeds: [String] = []
        if let opType = export.operatorDefiningType {
            seeds.append(opType)
        } else if let rt = export.receiverType {
            seeds.append("\(rt).\(export.callee)")
            seeds.append(rt)
        } else {
            seeds.append(export.callee)
        }
        for t in signatureNominalTypes(of: export) { seeds.append(t) }
        return seeds
    }

    /// DECL-LEVEL extraction: build a decl index over ALL the module's source files
    /// (INCLUDING poison files — we pull decls OUT of them), compute the union closure
    /// of `declSeeds`, and write the gathered REAL decl spans into synthesized
    /// `.swift` file(s) with a clean `import Foundation`. Returns the synthesized files
    /// to use as `realSources` (routing around poison), or nil if nothing was pulled
    /// (caller falls back to the coarse whole-module closure).
    ///
    /// The index walks files admissible BY PATH (manifest/test/plugin/entry exclusion)
    /// but does NOT apply the coarse import-safety filter — that is the whole point: a
    /// file with an unconditional `import CAtomic` is still indexed, and the extractor
    /// pulls only the clean decls from it (the `import` line and any decl reaching a
    /// forced-native symbol are left behind). Per-seed rejection keeps the union
    /// compilable: a seed whose closure reaches `mustStayNative` is dropped (its export
    /// demotes), so the emitted span set never contains a forced-native reference.
    private func extractDeclLevelRealSources(
        sourceDir: URL, rsBuildDir: URL, declSeeds: [String],
        log: (String) -> Void
    ) throws -> [URL]? {
        guard !declSeeds.isEmpty else { return nil }
        // Files admissible by PATH (drop manifests / tests / plugins / entry files),
        // but NOT by import-safety — we want to pull decls out of poison files too.
        let indexFiles = realSourceClosureFiles(in: sourceDir).filter { Self.realSourceURLAdmissible($0) }
        guard !indexFiles.isEmpty else { return nil }
        let extractor = DeclLevelExtractor(registry: registry)
        let idx = extractor.index(files: indexFiles)
        let dedupedSeeds = Array(Set(declSeeds)).sorted()
        if ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_DECL_DUMPSEEDS"] != nil {
            FileHandle.standardError.write(Data("[decl-seeds] \(dedupedSeeds.joined(separator: ", "))\n".utf8))
        }
        let extraction = extractor.extract(seeds: dedupedSeeds, index: idx)
        log("decl-level: \(extraction.declCount) decls pulled from \(extraction.sourceFileCount) files; "
            + "\(extraction.rejectedSeeds.count) seed(s) rejected (reach native)")
        if ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_DECL_DUMPREJECTS"] != nil {
            for (seed, reason) in extraction.rejectedSeeds.prefix(60) {
                FileHandle.standardError.write(Data("[decl-reject] \(seed) :: \(reason)\n".utf8))
            }
        }
        guard !extraction.spans.isEmpty else { return nil }
        // Write the union span set into a single synthesized closure file. (Splitting
        // into one-decl-per-file would let convergence isolate a broken span, but a
        // single file keeps self-references resolving without import qualification and
        // is what the prototype proved compiles; the convergence loop still demotes any
        // WRAPPER that fails.)
        var src = "// Auto-generated by Patch — DECL-LEVEL real-source closure.\n"
        src += "// Minimal decl set the additive exports need, pulled verbatim from the\n"
        src += "// developer's real module source, routing AROUND WASM-unavailable files.\n"
        src += "import Foundation\n\n"
        src += extraction.spans.joined(separator: "\n\n")
        src += "\n"
        let url = rsBuildDir.appendingPathComponent("_PatchDeclClosure.swift")
        try src.write(to: url, atomically: true, encoding: .utf8)
        return [url]
    }

    // MARK: - Decl-level T0 isolation (the FINAL size lever)

    /// One emitted real-source wrapper + the metadata the isolation pass needs to route
    /// its export independently: its decl seeds (for the per-export closure walk) and
    /// whether its boundary is T0-shaped (the embedded host-bridge wrapper, no in-module
    /// Foundation). A wrapper that is NOT T0-shaped (struct/array boundary, value-type
    /// receiver) can never ride T0 regardless of its closure, so it routes straight to T2.
    struct EmittedWrapper {
        let wasmURL: URL
        let exports: [String]
        let seeds: [String]
        let t0Eligible: Bool
    }

    /// The per-export decl-level T0-isolation pass — the gate to re-enable default-on for
    /// real libraries. For EACH additive export, compute its OWN minimal decl closure
    /// (`DeclLevelExtractor`, per-export not union), Foundation-strip it, and PROBE-compile
    /// `{the export's T0 wrapper + its minimal closure + the embedded runtime}` against the
    /// EMBEDDED (T0) SDK, capped at T0 (no escalation) so the `unsatisfiableEnvImports`
    /// guard converts an uninstantiable embedded module into a failure. An export whose
    /// probe SUCCEEDS is T0-clean (its clean-math closure has no Foundation/String-interp/
    /// Mirror/native dependency); the rest are the genuine-Foundation remainder.
    ///
    /// We then build a TINY T0 module from the union of the T0-clean exports' closures and
    /// — only if a remainder exists — a T2 module for the rest (the coarse whole-module
    /// closure, which always compiles the library that already compiled coarse). The two
    /// ship as a PMOD container (the SDK instantiates each sub-module separately). Take-
    /// the-best: returns the isolated outcome only when it ships ≥ the coarse export count
    /// AND is meaningfully smaller; otherwise nil (caller keeps coarse — never a regression).
    func runDeclLevelT0Isolation(
        sourceDir: URL, rsBuildDir: URL, moduleName: String,
        emittedWrappers: [EmittedWrapper], runtimeURL: URL,
        coarseClosure: [URL], compiler: WasmCompiling,
        rsModuleURL: URL, coarse: WasmConvergence.Outcome,
        log: (String) -> Void
    ) throws -> WasmConvergence.Outcome? {
        guard let swiftWasm = compiler as? SwiftWasmCompiler else { return nil }
        let fm = FileManager.default
        let isoDir = rsBuildDir.appendingPathComponent("decl-isolate")
        try? fm.createDirectory(at: isoDir, withIntermediateDirectories: true)

        // (1) Index the WHOLE module corpus once (including poison files — we pull clean
        //     decls OUT of them). Per-export extraction reuses this index.
        let indexFiles = realSourceClosureFiles(in: sourceDir).filter { Self.realSourceURLAdmissible($0) }
        guard !indexFiles.isEmpty else { return nil }
        // T0-ISOLATION mode: route AROUND each type's Codable/reflection extension (an
        // embedded blocker a clean-math export never calls) so the geometry/crypto math
        // closure rides T0 instead of being dragged to T2 by the type's serialization surface.
        let extractor = DeclLevelExtractor(registry: registry, excludeEmbeddedBlockerExtensions: true)
        let idx = extractor.index(files: indexFiles)

        // The EMBEDDED (T0) shared runtime (Foundation-free allocator) — used by the
        // tiny T0 module's compile. A separate Foundation runtime is used for the T2
        // remainder (the existing `runtimeURL` is already the right one for that tier;
        // but the isolation T0 module needs the embedded one).
        let emitter = CodeEmitter()
        let t0Runtime = emitter.emitEmbeddedModuleRuntimeFile()
        let t0RuntimeURL = isoDir.appendingPathComponent("_PatchRuntimeT0.swift")
        try t0Runtime.source.write(to: t0RuntimeURL, atomically: true, encoding: .utf8)

        // Build one probe convergence: a SINGLE wrapper candidate + the export's own
        // Foundation-stripped decl closure, T0-pinned (start AND cap at T0). A success
        // means the closure is genuinely embedded-clean; a failure (env-import guard or
        // a real Foundation symbol) means the export belongs in the T2 remainder.
        func probeT0(_ w: EmittedWrapper) throws -> (clean: Bool, closure: [URL]) {
            // Per-export minimal decl closure. A seed reaching a forced-native symbol
            // REJECTS (the extractor drops it) — so a closure that survives never holds
            // a native reference. An empty span set means a scalar-only export with no
            // project decls (already T0 by construction) — clean with an empty closure.
            let extraction = extractor.extract(seeds: Array(Set(w.seeds)).sorted(), index: idx)
            // A rejected seed (reaches native) means this export can't be T0-clean.
            guard extraction.rejectedSeeds.isEmpty else {
                log("  [probe] \(w.exports.first ?? "?"): seed rejected (\(extraction.rejectedSeeds.first?.reason ?? "native")) → T2")
                return (false, [])
            }
            // Synthesize the per-export closure file, Foundation-stripped: the decl spans
            // come verbatim, with NO `import Foundation` (the embedded compile has none).
            // A span that genuinely needs Foundation then fails to compile/instantiate →
            // the probe reports not-clean and the export routes to T2.
            var closureFiles: [URL] = []
            if !extraction.spans.isEmpty {
                var src = "// Auto-generated by Patch — per-export DECL-LEVEL T0 closure.\n"
                src += "// Minimal embedded-clean decl set for one export; NO Foundation import.\n\n"
                src += extraction.spans.joined(separator: "\n\n") + "\n"
                let cu = isoDir.appendingPathComponent("_T0Closure_\(CodeEmitter.sanitizedExportSymbol(w.exports.first ?? "x")).swift")
                try src.write(to: cu, atomically: true, encoding: .utf8)
                closureFiles = [cu]
            }
            let probeOut = isoDir.appendingPathComponent("probe_\(CodeEmitter.sanitizedExportSymbol(w.exports.first ?? "x")).wasm")
            let realCompiler = RealSourceWasmCompiler(
                base: swiftWasm, moduleName: moduleName, realSources: closureFiles)
            var conv = WasmConvergence(compiler: realCompiler)
            conv.supportSources = [t0RuntimeURL]
            let cand = WasmConvergence.Candidate(
                functionID: w.wasmURL.lastPathComponent, sourceFile: w.wasmURL, exports: w.exports)
            let o = try conv.converge([cand], outputModule: probeOut,
                                      startTier: .t0Embedded, maxIterations: 4,
                                      bailOnUnattributableFailure: true, maxTier: .t0Embedded)
            let clean = !o.compiled.isEmpty && o.finalTier == .t0Embedded
            log("  [probe] \(w.exports.first ?? "?"): \(clean ? "T0-CLEAN" : "→T2") (\(extraction.declCount) decls, \(o.iterations) iter)")
            return (clean, closureFiles)
        }

        // (2) Partition every T0-SHAPED wrapper by its probe; non-T0-shaped wrappers go
        //     straight to the T2 remainder (their boundary can't ride T0).
        var t0Wrappers: [EmittedWrapper] = []
        var t0ClosureFiles: [URL] = []
        var t2Wrappers: [EmittedWrapper] = []
        var seenClosure = Set<String>()
        for w in emittedWrappers {
            guard w.t0Eligible else { t2Wrappers.append(w); continue }
            let (clean, closure) = try probeT0(w)
            if clean {
                t0Wrappers.append(w)
                for c in closure where seenClosure.insert(c.path).inserted { t0ClosureFiles.append(c) }
            } else {
                t2Wrappers.append(w)
            }
        }
        log("decl-isolate: \(t0Wrappers.count) export(s) → T0, \(t2Wrappers.count) → T2 (of \(emittedWrappers.count))")
        if let dump = ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_DECL_ISOLATE_DUMP"], !dump.isEmpty {
            let line = "[decl-isolate split] T0={\(t0Wrappers.flatMap{$0.exports}.filter{$0 != "patch_malloc" && $0 != "patch_free"}.joined(separator: ","))} "
                + "T2={\(t2Wrappers.flatMap{$0.exports}.filter{$0 != "patch_malloc" && $0 != "patch_free"}.joined(separator: ","))}\n"
            FileHandle.standardError.write(Data(line.utf8))
        }

        // Nothing rides T0 → isolation can't help; keep coarse.
        guard !t0Wrappers.isEmpty else { log("decl-isolate: no T0-clean export — keeping coarse"); return nil }

        // (3) Build the TINY T0 module from the union of the T0-clean exports' closures.
        //     One UNION closure file keeps cross-decl self-references resolving (the
        //     prototype-proven shape); each clean export already compiled against its own
        //     subset, so the union is clean too. T0-pinned (start+cap at T0) so the
        //     env-import guard rejects any non-instantiable embedded module.
        let unionClosure = try unionT0ClosureFile(t0ClosureFiles, isoDir: isoDir)
        let t0ModuleURL = rsModuleURL.deletingPathExtension().appendingPathExtension("t0.wasm")
        let t0Cands = t0Wrappers.map {
            WasmConvergence.Candidate(functionID: $0.wasmURL.lastPathComponent,
                                      sourceFile: $0.wasmURL, exports: $0.exports)
        }
        let t0Compiler = RealSourceWasmCompiler(
            base: swiftWasm, moduleName: moduleName, realSources: unionClosure)
        var t0Conv = WasmConvergence(compiler: t0Compiler)
        t0Conv.supportSources = [t0RuntimeURL]
        let t0Out = try t0Conv.converge(t0Cands, outputModule: t0ModuleURL,
                                        startTier: .t0Embedded,
                                        maxIterations: max(8, t0Cands.count + 4),
                                        bailOnUnattributableFailure: false, maxTier: .t0Embedded)
        guard !t0Out.compiled.isEmpty, let t0Module = t0Out.moduleURL else {
            log("decl-isolate: T0 module compiled nothing — keeping coarse"); return nil
        }
        let t0Size = (try? fm.attributesOfItem(atPath: t0Module.path)[.size] as? Int) ?? 0
        log("decl-isolate: T0 module shipped \(t0Out.compiled.count) export(s), \(t0Size) B, tier \(t0Out.finalTier?.rawValue ?? "?")")

        // (4) Build the T2 remainder module (only if there IS a remainder). Use the
        //     coarse whole-module closure (it already compiled coarse, so it always
        //     compiles here). Its runtime is the Foundation allocator.
        var shippedModule = t0Module
        var t2Out: WasmConvergence.Outcome? = nil
        // [BUG] Track whether the T2 remainder ACTUALLY MERGED into the shipped T0
        // container. The merge is best-effort (a binaryen-less machine drops it,
        // logging "shipping T0 only"); the reported export set / win-guard / finalTier
        // below must reflect only what the shipped container holds, never the T2
        // exports that were silently dropped (counting them = false-stable / a render
        // of code not in the container).
        var t2Merged = false
        if !t2Wrappers.isEmpty {
            let t2ModuleURL = rsModuleURL.deletingPathExtension().appendingPathExtension("t2.wasm")
            let t2Cands = t2Wrappers.map {
                WasmConvergence.Candidate(functionID: $0.wasmURL.lastPathComponent,
                                          sourceFile: $0.wasmURL, exports: $0.exports)
            }
            let t2Compiler = RealSourceWasmCompiler(
                base: swiftWasm, moduleName: moduleName, realSources: coarseClosure)
            var t2Conv = WasmConvergence(compiler: t2Compiler)
            t2Conv.supportSources = [runtimeURL]   // the Foundation runtime
            let o = try t2Conv.converge(t2Cands, outputModule: t2ModuleURL,
                                        startTier: .t2Foundation,
                                        maxIterations: max(8, t2Cands.count + 4),
                                        bailOnUnattributableFailure: false)
            t2Out = o
            if !o.compiled.isEmpty, let t2Module = o.moduleURL {
                let t2Size = (try? fm.attributesOfItem(atPath: t2Module.path)[.size] as? Int) ?? 0
                log("decl-isolate: T2 remainder shipped \(o.compiled.count) export(s), \(t2Size) B")
                // PMOD-merge the T2 remainder INTO the T0 module (container; each
                // sub-module instantiated separately on-device).
                let merger = WasmModuleMerger()
                if merger.mergeIfPossible(primary: t0Module, secondary: t2Module) {
                    shippedModule = t0Module
                    t2Merged = true
                    log("decl-isolate: merged T0 + T2 into a PMOD container")
                } else {
                    log("decl-isolate: PMOD merge unavailable — shipping T0 only (T2 remainder dropped)")
                }
            } else {
                log("decl-isolate: T2 remainder shipped nothing")
            }
        }

        // (5) TAKE-THE-BEST. Count what isolation actually ships vs coarse.
        // [BUG] Include the T2 exports ONLY when they merged into the shipped
        // container — an unmerged T2 remainder is NOT in `shippedModule`, so counting
        // its exports would over-report coverage (false-stable) and bias the win-guard.
        let isolatedCompiled = t0Out.compiled + (t2Merged ? (t2Out?.compiled ?? []) : [])
        let isolatedExportCount = isolatedCompiled.flatMap { $0.exports }
            .filter { $0 != "patch_malloc" && $0 != "patch_free" }.count
        let coarseExportCount = coarse.compiled.flatMap { $0.exports }
            .filter { $0 != "patch_malloc" && $0 != "patch_free" }.count
        let isoSize = (try? fm.attributesOfItem(atPath: shippedModule.path)[.size] as? Int) ?? 0
        let coarseSize = coarse.moduleURL.flatMap { (try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0 } ?? Int.max
        log("decl-isolate: isolated ships \(isolatedExportCount) export(s) @ \(isoSize) B vs coarse \(coarseExportCount) @ \(coarseSize) B")

        // Accept isolation only when it ships AT LEAST as many exports AND is smaller
        // (the whole point). Otherwise keep coarse — strictly additive, never a regression.
        guard isolatedExportCount >= coarseExportCount, isolatedExportCount > 0, isoSize < coarseSize else {
            log("decl-isolate: not a win (exports \(isolatedExportCount) vs \(coarseExportCount), size \(isoSize) vs \(coarseSize)) — keeping coarse")
            return nil
        }
        // The shipped module is the container at `shippedModule`. Place it at the
        // canonical `rsModuleURL` (the caller / merge plumbing reads that path).
        if shippedModule.path != rsModuleURL.path {
            if fm.fileExists(atPath: rsModuleURL.path) { try? fm.removeItem(at: rsModuleURL) }
            try fm.copyItem(at: shippedModule, to: rsModuleURL)
        }
        log("decl-isolate: WIN — shipping isolated module (\(isoSize) B, \(isolatedExportCount) exports) at \(rsModuleURL.lastPathComponent)")
        return WasmConvergence.Outcome(
            compiled: isolatedCompiled,
            reclassifiedNative: t0Out.reclassifiedNative + (t2Out?.reclassifiedNative ?? []),
            moduleURL: rsModuleURL, toolchainUnavailable: false,
            iterations: t0Out.iterations + (t2Out?.iterations ?? 0),
            log: coarse.log + "\n[decl-isolate]\n" + t0Out.log + "\n" + (t2Out?.log ?? ""),
            // [BUG] The shipped container is T2 ONLY when the T2 remainder actually
            // merged in; an unmerged remainder leaves a pure-T0 container.
            finalTier: t2Merged ? .t2Foundation : .t0Embedded)
    }

    /// Combine the per-export T0 decl-closure files into ONE union closure file (deduped
    /// by decl span), so the tiny T0 module compiles all its clean exports against a
    /// single self-resolving closure. Returns `[]` when there are no closure files (all
    /// T0 exports were scalar-only with no project decls — a valid empty closure).
    private func unionT0ClosureFile(_ files: [URL], isoDir: URL) throws -> [URL] {
        guard !files.isEmpty else { return [] }
        var seen = Set<String>()
        var spans: [String] = []
        for f in files {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            // The per-export files are "header comment + spans"; split on the blank-line
            // separator the writer used and keep the non-comment chunks, deduped.
            for chunk in s.components(separatedBy: "\n\n") {
                let t = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty || t.hasPrefix("//") { continue }
                let key = String(t.prefix(64)) + "#\(t.count)"
                if seen.insert(key).inserted { spans.append(t) }
            }
        }
        guard !spans.isEmpty else { return [] }
        var out = "// Auto-generated by Patch — UNION T0 decl closure (all T0-clean exports).\n"
        out += "// Embedded-clean decl set; NO Foundation import.\n\n"
        out += spans.joined(separator: "\n\n") + "\n"
        let url = isoDir.appendingPathComponent("_PatchT0UnionClosure.swift")
        try out.write(to: url, atomically: true, encoding: .utf8)
        return [url]
    }

    /// Enumerate the `.swift` files for the REAL-SOURCE closure. Unlike the engine's
    /// `swiftFiles(in:)` (which drops any file NAMED like a test via `isTestFile` — a
    /// heuristic that wrongly excludes production files such as CryptoSwift's
    /// `swiftFiles(in:)` (which drops any file NAMED like a test via `isTestFile` — a
    /// heuristic that wrongly excludes production files such as CryptoSwift's
    /// `PrimeTest.swift` that DEFINE needed symbols), this excludes only files inside
    /// an actual test DIRECTORY. Build/hidden dirs are still skipped. Over-inclusion is
    /// safe here: a genuinely-XCTest file fails the real WASM compile and convergence
    /// demotes the dependent wrappers (it never ships a broken module).
    private func realSourceClosureFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            let lower = url.path.lowercased()
            // Exclude build/hidden dirs INCLUDING the engine's own .Patch/build output —
            // ingesting our generated _wasm.swift/_PatchType_*.swift poisons the real-source
            // closure with "invalid redeclaration"/"ambiguous", killing the gain on any
            // non-pristine release (release always builds into .Patch/build). [BUG-1]
            if lower.contains("/.build/") || lower.contains("/.git/")
                || lower.contains("/.patch/") { continue }
            if SwiftParserEngine.isBuildArtifactPath(lower) { continue }
            // Exclude only actual test/example/plugin DIRECTORIES (not by file name).
            if lower.contains("/tests/") || lower.contains("/uitests/")
                || lower.contains("/unittests/") { continue }
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Derive the real module name (the package/module the source is compiled as, so
    /// `<Module>.foo` self-qualified refs resolve). In priority order:
    ///   1. The `Sources/<Module>/` target directory holding the most source files
    ///      (the standard SPM layout — e.g. `Sources/Euclid/Vector.swift`).
    ///   2. The package name from a `Package.swift` at/above the source dir (the
    ///      `name: "Euclid"` argument) — covers a `path: "Sources"` flat layout.
    ///   3. The source-dir name. Sanitized to a Swift identifier by the compiler.
    private func realSourceModuleName(realSources: [URL], sourceDir: URL) -> String {
        // (1) The SPM target = the directory immediately under a `Sources` segment,
        // at ANY depth (files may live in `Sources/<Module>/<subdir>/...` — e.g.
        // swift-markdown's `Sources/Markdown/Block Directives/...`). Count files per
        // such `<Module>` and pick the most populous.
        var perDir: [String: Int] = [:]
        var flatLayoutFiles = 0   // files DIRECTLY under `Sources/` (path: "Sources")
        for f in realSources {
            let comps = f.pathComponents
            if let i = comps.firstIndex(of: "Sources"), i + 1 < comps.count {
                let next = comps[i + 1]
                // A file DIRECTLY under `Sources/` means a flat `path: "Sources"` target
                // (e.g. CodableCSV, the corpus Euclid) — its module is the PACKAGE name,
                // not a subdir. Count these separately.
                if next.hasSuffix(".swift") { flatLayoutFiles += 1; continue }
                perDir[next, default: 0] += 1
            }
        }
        // (2) Package name from Package.swift (search the source dir and its parents).
        let pkg = packageName(near: sourceDir)
        // A flat layout (files directly under `Sources/`) → the package name is the
        // module. Otherwise the most-populous `Sources/<Module>/` dir is the target.
        // When both exist, prefer whichever describes more files.
        let bestSubdir = perDir.max(by: { $0.value < $1.value })
        if flatLayoutFiles > (bestSubdir?.value ?? 0), let pkg, !pkg.isEmpty {
            return SwiftWasmCompiler.sanitizedModuleName(pkg)
        }
        if let best = bestSubdir?.key, !best.isEmpty {
            return SwiftWasmCompiler.sanitizedModuleName(best)
        }
        if let pkg, !pkg.isEmpty {
            return SwiftWasmCompiler.sanitizedModuleName(pkg)
        }
        // (3) Source-dir name.
        let dirName = sourceDir.lastPathComponent
        return SwiftWasmCompiler.sanitizedModuleName(dirName.isEmpty ? "PatchReal" : dirName)
    }

    /// The package name from the nearest `Package.swift` (the `Package(name: "X"…)`
    /// argument), searching `dir` and up to a few parent directories. Lightweight
    /// scan — good enough to name the real-source module.
    private func packageName(near dir: URL) -> String? {
        var d = dir
        for _ in 0..<4 {
            let manifest = d.appendingPathComponent("Package.swift")
            if let s = try? String(contentsOf: manifest, encoding: .utf8),
               let r = s.range(of: "name:") {
                // Find the first quoted string after `name:`.
                let tail = s[r.upperBound...]
                if let q1 = tail.firstIndex(of: "\"") {
                    let after = tail[tail.index(after: q1)...]
                    if let q2 = after.firstIndex(of: "\"") {
                        let name = String(after[after.startIndex..<q2])
                        if !name.isEmpty { return name }
                    }
                }
            }
            let parent = d.deletingLastPathComponent()
            if parent == d { break }
            d = parent
        }
        return nil
    }

    /// Emit a single `@_cdecl` JSON-ABI wrapper for `export`, to be compiled against
    /// the REAL module source. Identical wrapper to the default pure-export path
    /// (reuses the emitter), but ALWAYS the Foundation (T2) JSON envelope: the real
    /// boundary types are the developer's actual `Codable` value types (not
    /// reconstructed leaves), so the in-module JSON coder round-trips them. A
    /// non-`Codable` boundary makes this wrapper fail to compile → that export demotes
    /// alone (correct). Includes no allocator (the shared runtime owns it).
    /// Emit the additive real-source wrapper for an export. BREAKTHROUGH #9: try the
    /// EMBEDDED (T0) host-bridge wrapper first — when the export's boundary is
    /// host-JSON-reducible (scalar/String/Double args + return) it emits an
    /// `import CHost` wrapper with NO in-module Foundation/JSON coder, which lets the
    /// whole real-source module ride T0 (~110 KB) instead of T2 (~60 MB). The
    /// Foundation (T2) wrapper is the fallback for shapes the host bridge can't reduce
    /// (struct/array boundaries, value-type receivers) — always correct, only larger.
    /// The convergence loop's tier escalation handles a closure that turns out to need
    /// in-module Foundation even with a T0-shaped wrapper.
    private func emitRealSourceWrapper(_ emitter: CodeEmitter, _ export: CodeEmitter.PureExport)
        -> (fileName: String, source: String, exports: [String], t0Eligible: Bool) {
        if ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_NO_T0"] == nil,
           let t0 = emitter.emitEmbeddedPureExportFile(export, includeAllocator: false) {
            return (t0.fileName, t0.source, t0.exports, true)
        }
        let f = emitter.emitFoundationPureExportFilePublic(export, includeAllocator: false)
        return (f.fileName, f.source, f.exports, false)
    }

    /// Test-only access to `emitRealSourceWrapper` so the T0-vs-T2 wrapper routing
    /// (BREAKTHROUGH #9) can be asserted directly (`t0Eligible` flag + the emitted
    /// source shape) without driving a full build.
    static func emitRealSourceWrapperForTesting(_ emitter: CodeEmitter, _ export: CodeEmitter.PureExport)
        -> (fileName: String, source: String, exports: [String], t0Eligible: Bool) {
        BuildPipeline().emitRealSourceWrapper(emitter, export)
    }

    /// VALUE-TYPE RECEIVER AT T0: enrich an export with the reconstruction shapes for
    /// its value-type receiver and any value-type parameters, so the T0 emitter can
    /// rebuild them field-by-field from JSON (instead of forcing the Foundation T2
    /// tier). A shape is attached only when the type is a FLAT-SCALAR value type with a
    /// usable initializer (`valueTypeShape`); a non-reconstructable boundary gets no
    /// shape and the export stays T2 (unchanged behaviour). Free / static exports and
    /// operators (no receiver) pass through untouched unless they carry a value-type
    /// param that is reconstructable.
    func enrichValueTypeShapes(_ export: CodeEmitter.PureExport,
                               bundler: DependencyClosureBundler,
                               index: DependencyClosureBundler.Index) -> CodeEmitter.PureExport {
        // Only the ordinary instance-method / value-param path benefits; an operator is
        // invoked positionally (not via `_receiver`) and is left to its existing path.
        if export.operatorFixity != nil { return export }
        let receiverShape = export.receiverType.flatMap { bundler.valueTypeShape(for: $0, index: index) }
        var paramShapes: [String: CodeEmitter.PureExport.ValueTypeShape] = [:]
        for p in export.parameters {
            if let shape = bundler.valueTypeShape(for: p.type, index: index) { paramShapes[p.name] = shape }
        }
        // RETURN-side reconstruction shape (the Codable-return bridge): a function
        // returning a flat-scalar value type (`func decode(json:) -> Model`) can
        // hand-encode its result field-by-field at T0 instead of demoting to the
        // Codable-dependent T2 wrapper. Only attach a shape for a value-type return
        // (the scalar/Void cases ride the existing scalar hand-encoder, and the
        // emitter pins the shape to non-scalar returns anyway). `valueTypeShape` is
        // already fidelity-safe — it returns nil for a Foundation-backed / nested /
        // reordering-init type, so an unencodable return simply gets no shape → T2.
        let returnShape = bundler.valueTypeShape(for: export.returnType, index: index)
        if receiverShape == nil && paramShapes.isEmpty && returnShape == nil { return export }
        return CodeEmitter.PureExport(
            exportName: export.exportName, callee: export.callee,
            parameters: export.parameters, returnType: export.returnType,
            receiverType: export.receiverType,
            operatorFixity: export.operatorFixity, operatorToken: export.operatorToken,
            operatorDefiningType: export.operatorDefiningType,
            genericSpec: export.genericSpec, isProperty: export.isProperty,
            receiverShape: receiverShape, valueParamShapes: paramShapes,
            returnShape: returnShape)
    }

    /// Native-only modules that never link on wasm32. A file with an UNCONDITIONAL
    /// top-level `import <one of these>` cannot compile to wasm and is excluded from
    /// the real-source closure. A guarded import (`#if canImport(UIKit)`) is fine —
    /// the compiler inerts it on wasm32 — so the guard-awareness below is essential.
    private static let realSourceNativeOnlyModules: Set<String> = [
        "UIKit", "AppKit", "SwiftUI", "SceneKit", "RealityKit", "SpriteKit",
        "CoreText", "CoreGraphics", "QuartzCore", "Cocoa", "Carbon", "WatchKit",
        "MetalKit", "GLKit", "ARKit", "WebKit", "MapKit", "CoreData", "CloudKit",
        "Combine", "simd", "Metal",
    ]

    /// Whether a real source file is admissible into the real-source closure (the
    /// coarse increment's permissive gate). A file is admitted unless it has an
    /// UNCONDITIONAL top-level `import` of a native-only module — i.e. an import that
    /// is NOT inside any `#if … #endif` conditional block. Imports inside `#if
    /// canImport(...)` / `#if !arch(wasm32)` are fine (the wasm compiler evaluates the
    /// condition false and the import never happens). A standalone script (shebang) is
    /// excluded (it is not a library file).
    static func realSourceFileAdmissible(_ src: String) -> Bool {
        if src.hasPrefix("#!") { return false }
        var ifDepth = 0
        for rawLine in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = rawLine.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if") { ifDepth += 1; continue }
            if t.hasPrefix("#endif") { ifDepth = max(0, ifDepth - 1); continue }
            if t.hasPrefix("#else") || t.hasPrefix("#elseif") { continue }
            guard ifDepth == 0, let mod = importedModule(from: rawLine) else { continue }
            // A SwiftPM MANIFEST (`import PackageDescription`) is NOT module source —
            // compiling it as a target file poisons the whole closure with
            // `no such module 'PackageDescription'` (and the error names the manifest,
            // not a wrapper, so convergence can't attribute it → a death spiral that
            // demotes every clean export). Exclude any file that imports it. (The
            // by-PATH exclusion of `Package*.swift` is in the URL-level filter.)
            if mod == "PackageDescription" { return false }
            if realSourceNativeOnlyModules.contains(mod) { return false }
            // An UNCONDITIONAL import of a module that is NOT WASM-self-contained (a
            // sibling C target like swift-markdown's `CAtomic`, or another external
            // library) leaves an undefined module — `no such module 'CAtomic'` poisons
            // the whole closure. We can't pull a sibling target into the standalone
            // real-source package, so exclude the file; a clean export's closure routes
            // around it (decl-level extraction would do better — noted as follow-up).
            if !Self.realSourceSafeImportModules.contains(mod) { return false }
        }
        return true
    }

    /// Modules a real-source closure file may UNCONDITIONALLY import and still be
    /// WASM-self-contained (the guest links these from the SDK). Anything else (a
    /// sibling C target, an external library) leaves an undefined module. A
    /// `#if`-guarded import of anything is always fine (the compiler inerts it).
    private static let realSourceSafeImportModules: Set<String> = [
        "Foundation", "FoundationEssentials", "Swift", "Glibc", "Darwin",
        "_Concurrency", "WASILibc", "SwiftWASILibc",
    ]

    /// Path-level admission for the real-source closure: excludes SwiftPM manifests
    /// (`Package.swift`, `Package@swift-5.9.swift`), plugin/snippet/example dirs, and
    /// any path the engine already skips. A manifest compiled as a target file poisons
    /// the whole module (`no such module 'PackageDescription'`).
    static func realSourceURLAdmissible(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == "Package.swift" || name.hasPrefix("Package@") { return false }
        // Top-level-statement entry files (`main.swift`, `LinuxMain.swift`) are NOT
        // library module source — compiled into a library target they error with
        // `expressions are not allowed at the top level`, poisoning the whole closure.
        if name == "main.swift" || name == "LinuxMain.swift" || name == "XCTestManifests.swift" { return false }
        let p = url.path
        // SwiftPM plugins / snippets / examples are not part of the library module.
        for seg in ["/Plugins/", "/Snippets/", "/Examples/", "/Example/", "/Benchmarks/"] {
            if p.contains(seg) { return false }
        }
        return true
    }

    /// Names of types DECLARED at any indentation in a blob of Swift source
    /// (`class`/`struct`/`enum`/`protocol`/`actor` Foo). Heuristic line scan (no
    /// SwiftSyntax — the verbatim closure can be tens of thousands of lines): used to
    /// avoid declaring a namespace `enum T {}` that would collide with a real `T`
    /// already bundled verbatim. Over-inclusion is safe (it only suppresses a
    /// namespace declaration, which then isolates if actually needed).
    static func topLevelTypeNames(in source: String) -> Set<String> {
        guard !source.isEmpty else { return [] }
        let kinds: Set<String> = ["class", "struct", "enum", "protocol", "actor"]
        let nonName: Set<String> = ["func", "var", "let"]
        var names = Set<String>()
        for line in source.split(separator: "\n") {
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            var i = 0
            while i + 1 < toks.count {
                if kinds.contains(String(toks[i])) {
                    let raw = toks[i + 1]
                    if !nonName.contains(String(raw)) {
                        let name = raw.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                        if !name.isEmpty { names.insert(String(name)) }
                    }
                }
                i += 1
            }
        }
        return names
    }

    /// Pick the smallest viable START tier for the whole module (the convergence
    /// loop escalates from here if the compile fails). See the call site for the
    /// rule. Exposed (internal) for unit testing.
    func selectStartTier(report: CoverageReport, wasmSources: [URL], supportSources: Set<URL>)
        -> (tier: PackagingTier, rationale: String) {
        let compat = EmbeddedCompatibility()

        // 1. Max embedded-axis tier over the OTA-bound (shipped) functions.
        var tier: PackagingTier = .t0Embedded
        var rationale = "all shipped functions are embeddable (T0)"
        for r in report.results where r.classification == .wasmEligible
            || r.classification == .bridged || r.classification == .mixed {
            if r.tier > tier {
                tier = r.tier
                rationale = "function `\(r.functionID)` requires \(r.tier.rawValue)"
                    + (r.tierBlockers.isEmpty ? "" : ": \(r.tierBlockers.first!)")
            }
        }

        // 2. grep `import Foundation` + embedded-incompatible tokens in the actual
        //    sources that will be compiled (generated wrappers + developer code).
        //    The generated JSON-ABI wrappers use in-module Codable → T2; honour it.
        var allSources = wasmSources
        allSources.append(contentsOf: supportSources)
        for url in allSources {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let verdict = compat.analyzeSource(src)
            if verdict.tier > tier {
                tier = verdict.tier
                rationale = "source `\(url.lastPathComponent)` requires \(verdict.tier.rawValue)"
                    + (verdict.blockers.isEmpty ? "" : ": \(verdict.blockers.first!)")
            }
        }
        return (tier, rationale)
    }

    /// Whether a function's enclosing type is one of the bundled (shared) value
    /// types — if so its emission is owned by the shared support file, not the
    /// per-export candidate.
    private func mergedTypesContains(_ enclosing: String?, _ mergedTypes: [String]) -> Bool {
        guard let enclosing else { return false }
        return mergedTypes.contains(enclosing)
    }

    /// [BUG-1] Remove the engine's OWN generated artifacts from a staging dir so a
    /// rebuild can never reuse a stale compiled wrapper / re-ingest a stale
    /// reconstruction. Conservative: deletes only files this engine emits (the
    /// generated `.swift` sources, the linked module + its variants, and the
    /// real-source/SwiftUI sub-build dirs) and leaves anything else in `.Patch/build`
    /// untouched. Safe to call when the dir is empty/new (a fresh build is a no-op).
    static func invalidateStagedArtifacts(in buildDir: URL, fm: FileManager = .default) {
        // Top-level generated files. A generated `.swift` is either a name-suffixed
        // wrapper/bridge (`*_wasm.swift` / `*_bridge.swift`) or a `_Patch*` support
        // file (`_PatchType_*`, `_PatchHelper_*`, `_PatchGenerics`, `_PatchNamespaces`,
        // `_PatchRuntime`, `_PatchClosure`, …). The linked module is `module.wasm`
        // plus the additive `module.realsource.wasm` / `module.swiftui.wasm` and any
        // `.br`. We also sweep stray `.patch-merge-*.bin` temp files.
        func isGeneratedSwift(_ name: String) -> Bool {
            name.hasSuffix("_wasm.swift") || name.hasSuffix("_bridge.swift")
                || name.hasPrefix("_Patch")
                // The host-bridge resolver-thunk source (Lever #2). Swept at the start
                // of every build so a stale thunk from a prior PATCH_HOST_BRIDGE=1 run
                // can't survive into `prepare` when the flag is later off / nothing
                // routes — the pass re-emits it fresh when it routes anything this run.
                || name == HostBridgeThunkGenerator.fileName
                // The host-bridge `patch_host_symbols` GUEST-EXPORT source (Lever #2).
                || name == HostBridgeLowering.manifestGuestFileName
        }
        func isGeneratedModule(_ name: String) -> Bool {
            name == "module.wasm" || name.hasPrefix("module.")  // .realsource.wasm/.swiftui.wasm/.br
                || name.hasPrefix(".patch-merge-")
                || name == HostBridgeLowering.manifestFileName  // patch_host_symbols.json (Lever #2)
        }
        let entries = (try? fm.contentsOfDirectory(at: buildDir,
            includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        for url in entries {
            let name = url.lastPathComponent
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                // The additive sub-build dirs are entirely engine-owned.
                if name == "realsource" || name == "swiftui" {
                    try? fm.removeItem(at: url)
                }
                continue
            }
            if isGeneratedSwift(name) || isGeneratedModule(name) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Enumerate `.swift` files under a directory (skipping build/hidden dirs and
    /// test files, which never define shippable production logic).
    /// Best-effort module name for the host-bridge pass's canonical-signature
    /// receiver prefix (an app-local nominal `MyApp.PricingEngine`). Uses the source
    /// directory's last path component — the SwiftPM target convention
    /// (`Sources/<Target>`) — falling back to `MyApp`. Only steers the content-hash of
    /// app-local symbols; a framework receiver uses its own canonical module spelling,
    /// and a mismatch only costs coverage (a symbol id the resolver thunk won't match
    /// → demote), never soundness.
    private func moduleName(for sourceDir: URL) -> String {
        // Swift sanitizes a target/module name's non-identifier chars to `_`
        // (`hb-demo` → `hb_demo`); mirror that so the canonical-signature prefix
        // matches the module name the resolver thunk + SDK actually compile under.
        let raw = sourceDir.lastPathComponent
        let sanitized = String(raw.map { ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
        let ok = !sanitized.isEmpty && raw != "Sources" && raw != "src"
            && (sanitized.first?.isLetter ?? false)
        return ok ? sanitized : "MyApp"
    }

    private func swiftFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            let p = url.path
            let lower = p.lowercased()
            if p.contains("/.build/") || p.contains("/.git/") { continue }
            // [BUG-1] Exclude the engine's own prior-run output under `.Patch/build`
            // from `allFiles` (the bundler's decl index, the generic context, etc.).
            // A stale `_PatchType_*`/`_PatchGenerics.swift` from the last build holds
            // the OLD reconstructed bodies; ingesting it lets a re-release re-bundle
            // the OLD code. `realSourceClosureFiles` already excludes `/.patch/`; this
            // closes the same gap on the default path's source walk.
            if lower.contains("/.patch/") || lower.contains("/.swiftpm/") { continue }
            // Exclude build-tool output that lives INSIDE the project tree — Xcode's
            // DerivedData (esp. `-derivedDataPath ./DerivedData`), resolved SwiftPM
            // dependency clones, CocoaPods/Carthage. Walking these ingests THOUSANDS
            // of transitive-dependency sources (WasmKit, swift-nio, …) which both
            // hangs SwiftSyntax classification at 100% CPU and destabilises the
            // native-shell fingerprint. The dev's OWN code never lives here.
            if SwiftParserEngine.isBuildArtifactPath(lower) { continue }
            // Fix B: never bundle test code into the WASM module's dependency
            // closure either — its XCTest/swift-testing symbols can't compile to
            // WASM. Mirror the analysis-pass exclusion (SwiftParserEngine.isTestFile).
            if SwiftParserEngine.isTestFile(url) { continue }
            // Never ingest `patchcli prepare`'s OWN generated thunk file: it imports
            // PatchSDK/PatchSwiftUI and emits `@_dynamicReplacement` extensions that
            // compile into the NATIVE app, never the WASM module. Pulling it into the
            // closure would leak those host-only symbols into a guest compile unit. (It
            // declares no View structs, so the lowering pass already ignores it; this
            // also keeps it out of the decl index / symbol table.)
            if url.lastPathComponent == ThunkGenerator.thunkFileName { continue }
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: - BREAKTHROUGH-#7 generic-monomorphization context

    /// Build the project-wide context that feeds the GenericSpecializer's three
    /// Breakthrough-#7 instantiation sources (same-type pins, call-site mining, custom
    /// value-type conformers). Pure analysis over the source set; everything it admits
    /// still passes the isABICodable gate + the real WASM compile-or-demote backstop.
    private func buildGenericContext(
        allFiles: [URL], declIndex: DependencyClosureBundler.Index
    ) -> GenericSpecializer.Context {
        let table = SymbolTableBuilder().build(files: allFiles)
        let valueTypeNames = declIndex.valueTypeNames

        // (iii) Custom protocol → its VALUE-type conformers. A protocol whose
        // conformers are ALL value types (struct/enum) admits each as an instantiation;
        // a protocol with ANY reference-type (class/actor) conformer is EXCLUDED here
        // (those would fail-compile + demote — we never even offer them, keeping the
        // instantiation set clean). Only fresh project protocols are considered.
        var valueConformersByProtocol: [String: [String]] = [:]
        for (name, decl) in table.types where decl.kind == .protocol {
            let conformers = table.conformers(of: name)
            guard !conformers.isEmpty else { continue }
            var valueConformers: [String] = []
            var hasReferenceConformer = false
            for c in conformers {
                guard let cd = table.types[c] else { continue }
                if cd.kind == .struct || cd.kind == .enum {
                    if valueTypeNames.contains(c) { valueConformers.append(c) }
                } else if cd.kind == .class || cd.kind == .actor {
                    hasReferenceConformer = true
                }
            }
            // Conservative: only admit when EVERY conformer is a value type. A mixed
            // protocol (value + reference conformers) is left native (the value ones
            // are rare and the safest policy is to not split a protocol's conformers).
            if !hasReferenceConformer, !valueConformers.isEmpty {
                valueConformersByProtocol[name] = valueConformers.sorted()
            }
        }

        // (ii) Call-site mining: the concrete VALUE types each generic free/static
        // function is actually invoked with. Lightweight argument-type inference over
        // call expressions (`score(GameMove(...))`, `score(x)` where `x: GameMove`).
        let callSiteValueTypes = mineCallSiteValueTypes(
            files: allFiles, table: table, valueTypeNames: valueTypeNames)

        return GenericSpecializer.Context(
            valueConformersByProtocol: valueConformersByProtocol,
            callSiteValueTypes: callSiteValueTypes,
            projectValueTypeNames: valueTypeNames)
    }

    /// Mine concrete VALUE-type argument types each (potentially generic) free/static
    /// function is called with across the module. Single-argument call sites only
    /// (`f(Foo(...))` → `Foo`, `f(local)` where a same-scope `let local = Foo(...)` or
    /// a param `local: Foo`). Conservative: a type that isn't a known project value
    /// type is dropped; the specializer further filters to declared generics + the
    /// real WASM compile is the final arbiter.
    private func mineCallSiteValueTypes(
        files: [URL], table: SymbolTable, valueTypeNames: Set<String>
    ) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for file in files {
            guard let src = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let tree = SwiftParser.Parser.parse(source: src)
            let v = CallSiteArgTypeVisitor(valueTypeNames: valueTypeNames)
            v.walk(tree)
            for (fn, types) in v.callArgTypes { out[fn, default: []].formUnion(types) }
        }
        return out
    }

    /// The leading nominal type names appearing in a pure export's parameters +
    /// return type (the boundary types the bundler must close over and the JSON
    /// envelope must Codable-encode). Decomposes `[T]`/`[K:V]`/`T?` element types.
    private func signatureNominalTypes(of export: CodeEmitter.PureExport) -> [String] {
        var out: [String] = []
        func leaves(_ raw: String) {
            for leaf in DependencyClosureBundler.decompose(raw) {
                if let n = decompLeading(leaf), !out.contains(n) { out.append(n) }
            }
        }
        for p in export.parameters { leaves(p.type) }
        if !export.returnType.isEmpty, export.returnType != "Void" { leaves(export.returnType) }
        // A specialized generic receiver (`[Int]`, `[MyValue]`) is also a boundary the
        // module must Codable-encode and the closure must reconstruct.
        if let rt = export.receiverType { leaves(rt) }
        return out
    }

    /// Fix S1 — PROVE every ABI boundary type is Codable before the T2 wrapper emits.
    ///
    /// The Foundation (T2) ABI wrapper synthesizes `private struct _Args: Decodable`
    /// / `_Out: Encodable` over the dev's VERBATIM arg/return field types. Swift only
    /// synthesizes the conformance when EVERY stored field conforms — so a boundary
    /// type that is a non-Codable struct/class, a closure-bearing type, or a type
    /// whose Codable comes only from a same-file extension NOT in the closure makes
    /// the wrapper fail to compile. That fails LOUD on the guest (the convergence loop
    /// demotes) but the NATIVE-BRIDGE mirror compiles in the DEV's Xcode project, so
    /// the same non-conformance surfaces as a red error after `patchcli build`
    /// reported success.
    ///
    /// A boundary leaf is provably Codable iff it is a known stdlib/Foundation Codable
    /// leaf/container, OR a value type the closure RECONSTRUCTS (reconstruction force-
    /// adds `Codable`, so `bundledCodableTypes` — `clo.neededTypes` ∪ the already-
    /// merged set — are Codable). A leaf that is neither cannot be proven Codable →
    /// the export DEMOTES to native (it already ships as a non-exported native
    /// function), mirroring `isFullyScalarReconstructable`'s prove-or-demote
    /// discipline for the T0 path. Returns the unprovable leaf name (for the demote
    /// reason), or nil when the whole boundary is provably Codable.
    private func firstNonCodableBoundaryLeaf(
        of export: CodeEmitter.PureExport, bundledCodableTypes: Set<String>) -> String? {
        for leaf in signatureNominalTypes(of: export) {
            if DependencyClosureBundler.isKnownCodableLeaf(leaf) { continue }
            if DependencyClosureBundler.systemTypeNames.contains(leaf) { continue }
            if bundledCodableTypes.contains(leaf) { continue }
            // A generic placeholder (single uppercase letter, or `T`/`U`/`Element`)
            // is not a concrete boundary type here — generic exports route to the T2
            // bundle path with their real instantiations; leave them to that path.
            if leaf.count <= 1 { continue }
            return leaf
        }
        return nil
    }

    /// Collect the simple names of all `struct`/`enum`/`class`/`actor` declarations
    /// in a source (top-level and nested) by lightweight token scanning — used to
    /// know which types' authoritative definitions are already in the bundled library
    /// closure, so the redundant reconstruction can be suppressed.
    private func collectDeclaredTypeNames(_ src: String, into out: inout Set<String>) {
        for line in src.split(separator: "\n") {
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for (i, t) in toks.enumerated() where ["struct", "enum", "class", "actor"].contains(t) {
                guard i + 1 < toks.count else { continue }
                // The next token is the name (strip a generic clause / `:`).
                var name = toks[i + 1]
                if let cut = name.firstIndex(where: { $0 == "<" || $0 == ":" || $0 == "{" }) {
                    name = String(name[name.startIndex..<cut])
                }
                if let first = name.first, first.isLetter || first == "_" { out.insert(name) }
            }
        }
    }

    /// WASM-safe modules a bundled generic file may import (the guest links these
    /// from the SDK). Anything else (`RealModule`, `Numerics`, another library) would
    /// leave undefined symbols → the generic is left native (conservative).
    private static let wasmSafeImportModules: Set<String> = [
        "Foundation", "Swift", "Glibc", "Darwin", "_Concurrency",
    ]

    /// Markers that make a bundled library file NOT WASM-self-contained even if its
    /// imports are safe: SwiftPM resource access (`Bundle.module`) and other host-only
    /// surface. A file containing one is excluded from the generic library bundle
    /// (conservative — its generics stay native rather than break the module compile).
    private static let unsafeBundleMarkers: [String] = [
        "Bundle.module", ".module.url", "Bundle(for:", "NSClassFromString",
    ]

    /// Foundation surface that DOES NOT EXIST in the wasm SDK's Foundation (it lives in
    /// FoundationNetworking / Dispatch / host-only runtime). A file is import-`safe`
    /// (it only imports `Foundation`) yet still cannot compile to wasm if it USES one
    /// of these types — and because the whole-library closure is ONE compile unit,
    /// such a file poisons every generic spec in the module (the NetNewsWire 11.9k-line
    /// `_PatchGenerics.swift` failed wholesale on `Thread`/`URLRequest`/`HTTPURLResponse`,
    /// dropping the bundle and demoting every spec that needed it). We exclude any file
    /// that references one of these as a whole-word identifier — conservative: its
    /// generics stay native rather than break the shared bundle. Pure math / collection
    /// libraries (the canaries) never touch this surface, so they are unaffected.
    private static let wasmUnavailableFoundationTokens: [String] = [
        // Networking (FoundationNetworking on Linux/wasm, not in base Foundation).
        "URLRequest", "URLResponse", "HTTPURLResponse", "URLSession", "URLSessionTask",
        "URLSessionWebSocketTask", "URLSessionDataTask", "URLSessionConfiguration",
        "URLCredential", "URLProtectionSpace", "URLCache", "CachedURLResponse",
        // Threading / run-loop / dispatch (no host scheduler in a reactor module).
        "DispatchQueue", "DispatchSemaphore", "DispatchGroup", "DispatchWorkItem",
        "DispatchSource", "DispatchTime", "Thread", "RunLoop", "Timer", "OperationQueue",
        "NSCondition", "NSLock", "NSRecursiveLock", "Operation",
        // Dynamic runtime / KVO / notifications wiring that has no wasm backing.
        "NSObject", "NSCoder", "NSKeyedArchiver", "NSKeyedUnarchiver",
        "FileManager", "FileHandle", "Process", "Pipe", "Host",
    ]

    /// True iff `src` references `token` as a WHOLE-WORD identifier (not a substring of a
    /// longer identifier — so `Timer` does not match `TimerView`, `Thread` not `ThreadID`).
    private static func referencesWholeWord(_ src: String, _ token: String) -> Bool {
        var search = src.startIndex
        while let r = src.range(of: token, range: search..<src.endIndex) {
            let before = r.lowerBound == src.startIndex ? nil : src[src.index(before: r.lowerBound)]
            let after = r.upperBound == src.endIndex ? nil : src[r.upperBound]
            let isIdent: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
            if !(before.map(isIdent) ?? false) && !(after.map(isIdent) ?? false) { return true }
            search = r.upperBound
        }
        return false
    }

    /// True iff (a) every top-level `import` is in the WASM-safe module allowlist AND
    /// (b) the file uses no host-only resource/runtime marker. A file with no imports
    /// and no markers is trivially safe.
    /// If `line` is an import in ANY form — bare, attributed (`@_exported`,
    /// `@_implementationOnly`, `@_spi(...)`), or access-level-modified (`internal
    /// import`, `public import`, `package import`, a Swift-6 feature) — return its
    /// leading module component, else nil. The old prefix check missed the modified
    /// forms, letting a C-only file (swift-markdown's `internal import CAtomic`) slip
    /// into the bundled closure and break the compile.
    static func importedModule(from rawLine: Substring) -> String? {
        var t = rawLine.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("@") {                                  // strip leading attribute(s)
            guard let sp = t.firstIndex(of: " ") else { return nil }
            t = String(t[t.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
        }
        for kw in ["internal ", "public ", "package ", "private ", "fileprivate ", "open "] {
            if t.hasPrefix(kw) { t = String(t.dropFirst(kw.count)); break }
        }
        guard t.hasPrefix("import ") else { return nil }
        var mod = String(t.dropFirst("import ".count)).trimmingCharacters(in: .whitespaces)
        for kind in ["func ", "class ", "struct ", "enum ", "protocol ", "typealias ", "var ", "let "] {
            if mod.hasPrefix(kind) { mod = String(mod.dropFirst(kind.count)); break }   // `import func Foo.bar`
        }
        return mod.split(separator: ".").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
    }

    private func genericFileImportsSafe(_ src: String) -> Bool {
        // A standalone script (shebang) is not a library file — its `#!/usr/bin/swift`
        // line and top-level statements break the bundled module (e.g. NetNewsWire's
        // VerifyNoBS.swift). Exclude it outright.
        if src.hasPrefix("#!") { return false }
        for line in src.split(separator: "\n") {
            guard let mod = Self.importedModule(from: line) else { continue }
            if !Self.wasmSafeImportModules.contains(mod) { return false }
        }
        for marker in Self.unsafeBundleMarkers where src.contains(marker) { return false }
        // Exclude files that USE wasm-unavailable Foundation surface (networking /
        // threading / dynamic runtime). They import only `Foundation` (so the import
        // check passes) yet cannot compile to wasm, and would poison the shared
        // whole-library bundle for every generic spec in the module.
        for token in Self.wasmUnavailableFoundationTokens where Self.referencesWholeWord(src, token) {
            return false
        }
        return true
    }

    /// Strip leading `import …` lines from a bundled generic source file (the shared
    /// `_PatchGenerics.swift` already imports Foundation; an in-package `import
    /// <Module>` of the library itself would not resolve). Conservative: only removes
    /// top-level `import` statements, leaving all declarations untouched.
    private func stripImports(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { Self.importedModule(from: $0) == nil }  // strip ALL import forms (incl. access-modified)
            .joined(separator: "\n")
    }

    private func decompLeading(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let first = s.first, first.isLetter || first == "_" else { return nil }
        var ident = ""
        for ch in s { if ch.isLetter || ch.isNumber || ch == "_" { ident.append(ch) } else { break } }
        return ident.isEmpty ? nil : ident
    }

    /// Emit the pure-export wrapper. When the export's boundary carries a
    /// reconstructed value type (a non-scalar), it normally uses the Foundation JSON
    /// wrapper (T2) so the envelope can `Codable`-encode it; pure-scalar exports keep
    /// the tiny T0 host-bridge wrapper.
    ///
    /// VALUE-TYPE RECEIVER AT T0: when the export was ENRICHED with reconstruction
    /// shapes (a flat-scalar receiver / value-type args) the embedded emitter can
    /// rebuild those value types from the nested JSON via `json_get_subobject` — so
    /// `emitPureExportFile` returns a T0 wrapper. We try it FIRST in that case; if it
    /// declines (any boundary not flat-scalar-reconstructable, or a value-type return)
    /// we fall back to the Foundation (T2) wrapper. A scalar export is unchanged.
    private func emitPureExport(_ emitter: CodeEmitter, _ export: CodeEmitter.PureExport,
                                sigTypes: [String], includeAllocator: Bool)
        -> (fileName: String, source: String, exports: [String]) {
        // A GENERIC-SPECIALIZATION export ALWAYS uses the Foundation (T2) wrapper: its
        // generic body is bundled as real library source (`_PatchGenerics.swift`,
        // `import Foundation`) and compiled at the module tier, which is T2 whenever
        // that closure needs Foundation/Codable. A T0 host-bridge wrapper (no
        // Foundation, `import CHost`) cannot coexist with a Foundation-tier generic
        // bundle in one compile unit (the embedded compile rejects the bundle's
        // `import Foundation`/`Codable`; mixing tiers demotes the whole unit). Routing
        // genericSpec to T2 matches the pre-B7 generic path (`[Int]` receivers already
        // fell through to T2) and keeps the custom-value-type instantiations shippable.
        if export.genericSpec != nil {
            return emitter.emitFoundationPureExportFilePublic(export, includeAllocator: includeAllocator)
        }
        // A SELF-FREE instance-method export INLINES its verbatim free-function body
        // (`import Foundation`) into this candidate file, so it compiles at the
        // Foundation (T2) tier — the body routinely uses wasm-safe Foundation
        // (`DateFormatter`, etc.). A T0 host-bridge wrapper (`import CHost`, no
        // Foundation) cannot coexist with that body in one compile unit. Route to the
        // Foundation JSON wrapper to match the inlined body's tier.
        if export.selfFreeFreeFunction != nil {
            return emitter.emitFoundationPureExportFilePublic(export, includeAllocator: includeAllocator)
        }
        // If the export carries reconstruction shapes, let the T0 emitter attempt the
        // value-type receiver/arg rebuild (it returns nil → T2 when not reducible).
        if export.receiverShape != nil || !export.valueParamShapes.isEmpty,
           let t0 = emitter.emitEmbeddedPureExportFile(export, includeAllocator: includeAllocator) {
            return t0
        }
        let hasValueTypeBoundary = sigTypes.contains { !DependencyClosureBundler.isScalarLeaf($0) }
        // A value-type boundary / `_receiver` with NO usable reconstruction shape (a
        // nested value type, a Decimal/Foundation field, a specialized generic
        // receiver like `[Int]`) must use the Foundation JSON wrapper (T2): the T0
        // host-scalar bridge cannot rebuild it.
        if hasValueTypeBoundary || export.receiverType != nil {
            return emitter.emitFoundationPureExportFilePublic(export, includeAllocator: includeAllocator)
        }
        return emitter.emitPureExportFile(export, includeAllocator: includeAllocator)
    }

    /// Group the simple names of `wasmEligible` (pure) functions by their source
    /// file, so the pure-export scanner can find exportable signatures per file.
    private func pureEligibleByFile(_ report: CoverageReport) -> [URL: Set<String>] {
        var out: [URL: Set<String>] = [:]
        for r in report.results where r.classification == .wasmEligible {
            guard let rec = report.records[r.functionID] else { continue }
            // Simple function name without the `(...)` signature suffix.
            let simple = r.functionID.split(separator: ".").last.map(String.init)?
                .split(separator: "(").first.map(String.init)
            guard let simple else { continue }
            out[rec.sourceFile, default: []].insert(simple)
        }
        return out
    }

    /// The registry symbol names the `FusionRewriter` can rewrite to a host bridge —
    /// the subset of the `.bridgeable` tier the fusion actually handles today. A
    /// function blocked ONLY by these is fusion-eligible (the leaf is rewritten; the
    /// function compiles). Kept in lock-step with `FusionRewriter.allBridges`.
    static let fusionRewriteableSymbols: Set<String> = [
        "UserDefaults",                       // string get/set + typed bool/int/double get/set
        "Locale", "TimeZone",                 // .current.identifier
        "NSLog", "OSLog", "Logger", "os_log", "syslog",  // logging (single-arg NSLog rewritten)
        // Business-logic action/onChange leaves. A function whose remaining native
        // hit is one of these AND is the exact bridged FORM (post(name:object:nil) /
        // UIApplication.shared.open(<url>)) lowers in WASM via patch.notify_post /
        // patch.open_url. Any OTHER member of these types (a non-nil notification
        // object:, UIApplication.keyWindow, …) is NOT matched by the rewriter, so the
        // real WASM compile fails and the function demotes alone (demote-safe — the
        // gate only widens the candidate set; the compile is the final arbiter).
        // The rewriter lowers ONLY post(name:object:nil); `addObserver` is deliberately
        // NOT rewritten (a guest closure registered as an observer would outlive the
        // WASM instance — use-after-free). An addObserver function still ships as a
        // whole-function `.bridged` native call (NotificationCenter is .bridgeable);
        // fusion just declines to lower it IN WASM — it does not regress.
        "NotificationCenter",                 // .default.post(name:object:nil)
        "UIApplication",                      // .shared.open(<url>)
        // Breakthrough #8 host-ABI bridge family (read-only leaves). A function
        // blocked ONLY by these is fusion-eligible: the FusionRewriter rewrites the
        // call site to a patch_host.* import the SDK serves. File WRITE members are
        // kept native by the registry's mustStayNative member-call guard, so a
        // file-writer carries a non-rewriteable hit and is excluded here.
        "FileManager",                        // read-only: fileExists/contents/attributes .size
        "Bundle",                             // object(forInfoDictionaryKey:) / path(forResource:)
        "ProcessInfo",                        // environment[...] / operatingSystemVersion
        // Breakthrough #6 NETWORKING (async). A function that is async ONLY because it
        // `await`s `URLSession.shared.data(from:)`, then decodes JSON + runs value
        // logic, is fusion-eligible: the FusionRewriter rewrites that leaf to the async
        // `patch_host.http_get` import the SDK serves. ONLY `URLSession` is listed:
        //   - `data(for: URLRequest)` is DEFERRED — `URLRequest` is absent in the
        //     WASM-SDK guest Foundation (a function building one won't compile in WASM),
        //     so `URLRequest` is NOT rewriteable and a function touching it is excluded.
        //   - the streaming/websocket/upload/download/delegate surface is kept native
        //     by the registry's mustStayNative split (a non-rewriteable hit → excluded).
        // The request/response VALUE types (`URLResponse`/`HTTPURLResponse`) are
        // wasm-safe Foundation (available in the guest), so they are not native hits.
        "URLSession",                         // .shared.data(from:)
    ]

    /// FUSION: group the simple names of functions blocked ONLY by a fusion-rewriteable
    /// bridgeable leaf, by source file — the headroom the fusion adds on top of the pure
    /// (`.wasmEligible`) set. A function qualifies iff it is NOT pure-eligible already,
    /// is NOT genuinely native, and EVERY native symbol it hits is in
    /// `fusionRewriteableSymbols` (with ≥1 such hit). The real WASM compile remains the
    /// final arbiter: an offered function whose body actually reaches something the
    /// rewriter misses fails the compile and demotes alone via the convergence loop.
    private func fusionEligibleByFile(_ report: CoverageReport) -> [URL: Set<String>] {
        var out: [URL: Set<String>] = [:]
        let rewriteable = Self.fusionRewriteableSymbols
        for r in report.results {
            // Already shipped as pure → not the fusion's added headroom.
            if r.classification == .wasmEligible { continue }
            // Genuinely native (forced by ObjC/threading/UI/unsafe) → never fusion-eligible.
            if r.classification == .native { continue }
            // Must have ≥1 native hit and EVERY hit must be fusion-rewriteable.
            guard !r.nativeHits.isEmpty,
                  r.nativeHits.allSatisfy({ rewriteable.contains($0.symbol) }) else { continue }
            guard let rec = report.records[r.functionID] else { continue }
            let simple = r.functionID.split(separator: ".").last.map(String.init)?
                .split(separator: "(").first.map(String.init)
            guard let simple else { continue }
            out[rec.sourceFile, default: []].insert(simple)
        }
        return out
    }
}
