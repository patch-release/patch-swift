// SPDX-License-Identifier: Apache-2.0

import Foundation
import PartitioningEngine
import CodeGenerator
import SwiftParser
import SwiftSyntax

// =============================================================================
// LEVER #2 — the BUILD-WIRING pass for the generalized "call what's already
// linked" host bridge (DESIGN.md `experiments/host-bridge-generalized/`).
//
// This is the engine-side glue that joins the four PROVEN-standalone components
// into the GENERAL-LOGIC build path so routing fires automatically during
// `patchcli build`:
//
//   FunctionRecord (forced-native)          → body source slice
//     → HostBridgeCallExtractor.extract      → [Candidate]                (front-end)
//     → GeneralBridgeRewriter.classify       → .route(CallSite) / .demote (gate)
//     → HostBridgeABI                         → HostBridgeSymbol + manifest (ABI core)
//     → HostBridgeThunkGenerator(.realSDK)    → resolver-thunk source      (App-Store-clean resolution)
//        + BridgeThunkValidator               → compiles-or-demote net
//
// ARTIFACTS produced (into `.Patch/build/`):
//   * `patch_host_symbols.json` — the SDK reads this on module activation, resolves
//     each `canonicalSignature` against the compiled-in dispatch table (DESIGN §4.2),
//     and serves `patch_host.call(id, …)` from it.
//   * `PatchHostBridges.generated.swift` — the App-Store-clean resolver-thunk source
//     `prepare` inserts into the app target (the compiled-in, statically-type-checked
//     dispatch table). The compiles-or-demote net drops any symbol whose thunk won't
//     compile against the app's real types BEFORE this file is written.
//
// DISCIPLINE — ADDITIVE + DEMOTE-SAFE + OPT-IN. Gated behind `PATCH_HOST_BRIDGE=1`
// (default OFF), exactly like `PATCH_REAL_SOURCE`. It can ONLY convert a
// forced-native function to (partly) routed; with the flag OFF the build is
// byte-identical to today. The three-layer fail-closed net holds:
//   1. `GeneralBridgeRewriter.classify` demotes on any doubt (no false routing),
//   2. `BridgeThunkValidator` host-`swiftc -typecheck`s each thunk and drops a
//      non-compiling symbol (build-safe = demote-safe),
//   3. the runtime `have()` pre-flight + `.error` fallback the emitted guest
//      sequence carries demotes a routed call that fails to resolve on-device.
//
// SCOPE NOTE: this pass produces the manifest + the validated resolver-thunk
// source, REPORTS which symbols routed, AND — via `buildGuestEmission(routed:)` +
// `SwiftWasmCompiler.compileGenericHostBridgeGuest` (wired into `BuildPipeline`'s
// flag-gated host-bridge block) — now actually SHIPS the re-lowered guest bodies:
// the routed `patch_host.call` sequences are compiled into a real
// `module.hostbridge.wasm` (instantiable in WasmKit, exporting `patch_host_symbols`)
// and PMOD-appended to the default module as a SEPARATE additive instance. The SHIP
// gap is CLOSED (proven by `HostBridgeModuleWireTests`). Still a follow-up: wiring the
// generated resolver-thunk file into the app target via the existing pbxproj/Package
// integration (`prepare` insertion) — the on-device dispatch table the SDK's
// GenericHostBridge resolves against. The manifest + thunk + the SHIPPED guest module
// are the load-bearing, demote-safe deliverables.
// =============================================================================

public struct HostBridgeLowering {

    /// One routed call site, fully resolved to everything the manifest + the
    /// resolver thunk need. Carries the proven guest sequence the engine would
    /// splice in (reported for the re-split follow-up + asserted by the proof test).
    public struct Routed: Sendable, Equatable {
        /// The forced-native function the routed call lives in (`FunctionRecord.id`).
        public let functionID: String
        /// The canonical, content-addressed symbol the engine routes.
        public let symbol: HostBridgeSymbol
        /// The resolver-thunk input (the App-Store-clean compiled-in dispatch entry).
        public let routedSymbol: RoutedSymbol
        /// The verbatim native call this routes (the demote-safe fallback path).
        public let nativeExpr: String
        /// The emitted guest `patch_host.call` sequence (the `have()`-guarded closure
        /// the FusionRewriter hook produces) — what the re-split would splice in.
        public let guestSequence: String
        /// The routed call's marshalled args (each: a placeholder guest-literal expr +
        /// its TLV tag), used to build the SHIPPABLE, guest-COMPILABLE probe (the same
        /// `patch_host.call(id, …)` the rewriter emits, but with the native fallback
        /// replaced by a guest-safe default — the receiver `PricingEngine` doesn't
        /// exist in-guest). The routed symbol id is what must ship + instantiate.
        public let probeArgs: [HostBridgeABI.ArgSpec]
        /// The routed call's declared return type (drives the probe's `@_cdecl` shape).
        public let returnType: String

        public static func == (lhs: Routed, rhs: Routed) -> Bool {
            lhs.functionID == rhs.functionID && lhs.symbol == rhs.symbol
                && lhs.routedSymbol == rhs.routedSymbol && lhs.nativeExpr == rhs.nativeExpr
                && lhs.guestSequence == rhs.guestSequence && lhs.returnType == rhs.returnType
                && lhs.probeArgs == rhs.probeArgs
        }
    }

    /// One forced-native function the pass actually RE-LOWERED to OTA: the
    /// bridgeable calls in its body were spliced to the `patch_host.call` guest
    /// sequence (the re-split), so a function whose only native-ness was bridgeable
    /// calls now ships a guest WASM body instead of staying native. The headline
    /// Lever-#2 deliverable — a function that flipped native→OTA.
    public struct Lowered: Sendable, Equatable {
        /// The forced-native function that flipped to OTA (`FunctionRecord.id`).
        public let functionID: String
        /// The sanitized `@_cdecl` export symbol the guest fragment carries
        /// (`patch_relower__<base>`). Deterministic from the function's simple name.
        public let exportSymbol: String
        /// The REWRITTEN guest body source: the function's original body with each
        /// routed call's verbatim native expr replaced by its `patch_host.call`
        /// guest sequence. This is the body that now lowers to WASM (the re-split).
        public let guestBody: String
        /// The content-addressed symbol ids the re-lowered body routes (a subset of
        /// the manifest — exactly the bridged calls inside THIS function). The thunk
        /// + manifest cover these.
        public let routedSymbolIDs: [Int32]
        /// How many bridgeable call sites in this function were spliced (≥1).
        public let routedCallCount: Int
    }

    public struct Result: Sendable {
        /// The symbols actually routed + emitted (post compiles-or-demote net), in
        /// id order. Empty when the flag is off or nothing routed.
        public let routed: [Routed]
        /// The forced-native functions that flipped native→OTA: their bridgeable
        /// calls were spliced to the guest `patch_host.call` sequence and the
        /// rewritten body lowers. THE coverage-lift deliverable. Empty when the flag
        /// is off, nothing routed, or no routed function's body could re-lower
        /// (demote-safe: a function whose remainder isn't liftable stays native).
        public let lowered: [Lowered]
        /// `patch_host_symbols.json` path (nil when nothing routed).
        public let manifestURL: URL?
        /// `PatchHostBridges.generated.swift` path (nil when nothing routed / all
        /// demoted by the typecheck net). This file is what `prepare` inserts.
        public let thunkURL: URL?
        /// Candidate call sites the classifier demoted (kept native), with the reason.
        /// For the honest build report + the "why didn't this route" diagnostic.
        public let demoted: [(functionID: String, nativeExpr: String, reason: String)]
        /// Symbols the compiles-or-demote net dropped (the thunk didn't type-check
        /// against the app's real types), with the reason. Kept native.
        public let thunkDemoted: [(id: Int32, signature: String, reason: String)]
        /// Forced-native functions the pass examined (for the report headline).
        public let examinedForcedNativeFunctions: Int

        public static let empty = Result(
            routed: [], lowered: [], manifestURL: nil, thunkURL: nil,
            demoted: [], thunkDemoted: [], examinedForcedNativeFunctions: 0)
    }

    /// The opt-in env switch (default OFF). Mirrors `PATCH_REAL_SOURCE`'s posture.
    public static func isEnabled(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["PATCH_HOST_BRIDGE"] == "1"
    }

    public let moduleName: String

    public init(moduleName: String = "MyApp") {
        self.moduleName = moduleName
    }

    // -------------------------------------------------------------------------
    // MARK: - The pass
    // -------------------------------------------------------------------------

    /// Run the host-bridge lowering pass over a coverage report's forced-native
    /// functions. Pure analysis + codegen + (optional) host-typecheck — performs
    /// I/O only to WRITE the two artifacts into `buildDir` (never reads/writes the
    /// developer's source). When `runThunkTypecheck` is true and a host `swiftc` is
    /// available, the compiles-or-demote net drops non-compiling thunks; otherwise
    /// every routed symbol is emitted (the syntax-only floor still parses each).
    public func run(report: CoverageReport,
                    sourceDir: URL,
                    buildDir: URL,
                    runThunkTypecheck: Bool = true) throws -> Result {
        // (1) Collect the forced-native functions. A function is forced native when
        // its `FunctionRecord.forcesNative` is set OR the classifier landed it
        // `.native` — the bucket whose routable call sites we try to bridge.
        let forcedNative = collectForcedNative(report: report)
        guard !forcedNative.isEmpty else { return .empty }

        let extractor = HostBridgeCallExtractor(moduleName: moduleName)
        let rewriter = GeneralBridgeRewriter(abi: HostBridgeABIAdapter())

        // A return-type oracle over the project's OWN declarations: `<Receiver>.<fn>`
        // → declared return type, harvested from every `func`/`static func` in the
        // source. A method's return type is NOT visible from a pure call site, so the
        // engine injects these as the extractor's `returnTypeHints` (the documented
        // seam) — letting an app-local `PricingEngine.discount(...)` resolve its
        // `Double` return instead of demoting on unknown. Honest: a hint is only
        // emitted from a real, parsed declaration, never guessed.
        let returnOracle = buildReturnTypeOracle(sourceDir: sourceDir)

        var routed: [Routed] = []
        var demoted: [(functionID: String, nativeExpr: String, reason: String)] = []
        // Cache file contents so we slice each source file once.
        var fileCache: [URL: [Substring]] = [:]
        // The sliced body source per forced-native function, kept so the re-lower
        // step (below) can splice the routed sequences back into it.
        var bodyByFunction: [String: String] = [:]
        var recordByFunction: [String: FunctionRecord] = [:]

        for rec in forcedNative {
            guard let bodySource = sliceBody(of: rec, cache: &fileCache) else { continue }
            bodyByFunction[rec.id] = bodySource
            recordByFunction[rec.id] = rec
            // Feed the project-derived return-type hints the extractor consumes — a
            // method's return type isn't visible from a pure call site, so without
            // these an app-local call demotes on an unknown return (demote-on-doubt).
            let candidates = extractor.extract(fromSource: bodySource, returnTypeHints: returnOracle)
            for candidate in candidates {
                switch rewriter.classify(candidate) {
                case .demote(let reason):
                    demoted.append((rec.id, candidate.nativeExpr, reason.rawValue))
                case .route(let site):
                    // A routed call → its content-addressed symbol + the App-Store-clean
                    // resolver-thunk input. The SAME symbol called from two functions
                    // resolves to ONE dispatch entry — the manifest + thunk de-dupe by id
                    // later (`uniqueHostBridgeSymbols`/`uniqueRoutedSymbols`); we record
                    // each call SITE here so the report names every routed location.
                    let symbol = HostBridgeSymbol(
                        canonicalSignature: site.canonicalSignature,
                        argTags: site.args.map { tlvTag($0.tag) },
                        retTag: tlvTag(site.returnTag))
                    let guestSequence = rewriter.emitGuestSequence(site)
                    guard let routedSymbol = makeRoutedSymbol(
                        candidate: candidate, site: site, symbol: symbol) else {
                        // No clean call-template (a receiver shape the generator can't
                        // express) → keep native rather than emit a broken thunk.
                        demoted.append((rec.id, candidate.nativeExpr,
                                        "no resolvable call-template for the resolver thunk"))
                        continue
                    }
                    // The shippable probe's args: a guest-LITERAL placeholder per TLV
                    // tag (the routed `patch_host.call(id, blob)` for the content-
                    // addressed id is what must ship + instantiate — not a particular
                    // input). The TLV blob shape (argc + per-arg tag) matches the
                    // rewriter's `guestSequence` exactly; only the leaf values differ.
                    let probeArgs = site.args.map {
                        HostBridgeABI.ArgSpec(expr: placeholderLiteral(for: tlvTag($0.tag)),
                                              tag: tlvTag($0.tag))
                    }
                    routed.append(Routed(
                        functionID: rec.id, symbol: symbol, routedSymbol: routedSymbol,
                        nativeExpr: site.nativeExpr, guestSequence: guestSequence,
                        probeArgs: probeArgs, returnType: candidate.returnType))
                }
            }
        }

        guard !routed.isEmpty else {
            return Result(routed: [], lowered: [], manifestURL: nil, thunkURL: nil,
                          demoted: demoted, thunkDemoted: [],
                          examinedForcedNativeFunctions: forcedNative.count)
        }

        // (2) Generate the App-Store-clean resolver thunk for the UNIQUE routed
        // symbols + run the compiles-or-demote net against the dev's real source.
        let uniqueSymbols = uniqueRoutedSymbols(routed)
        let appTypeStub = runThunkTypecheck ? readAppSource(sourceDir: sourceDir) : ""
        let generator = HostBridgeThunkGenerator(target: .realSDK)
        let validator: BridgeThunkValidator? = runThunkTypecheck ? BridgeThunkValidator() : nil
        let thunkResult = generator.generate(
            symbols: uniqueSymbols, validate: validator, appTypeStub: appTypeStub)

        // Drop the routed entries whose symbol the net demoted (kept native). The
        // emitted manifest must list ONLY the symbols whose thunk actually shipped.
        let keptIDs = Set(thunkResult.emittedSymbolIDs)
        let keptRouted = routed.filter { keptIDs.contains($0.symbol.id) }
        for d in thunkResult.demoted {
            demoted.append(("(resolver-thunk)", d.signature, d.reason))
        }

        // (3) Write the artifacts. The manifest lists only the KEPT symbols (the ones
        // whose compiled-in thunk resolves on-device). The thunk file is `prepare`'s
        // insertion input.
        let fm = FileManager.default
        try fm.createDirectory(at: buildDir, withIntermediateDirectories: true)

        var manifestURL: URL? = nil
        var thunkURL: URL? = nil

        if !keptRouted.isEmpty {
            let manifestSymbols = uniqueHostBridgeSymbols(keptRouted)
            let manifestData = try HostBridgeABI.emitManifestJSON(manifestSymbols)
            let mURL = buildDir.appendingPathComponent(Self.manifestFileName)
            try manifestData.write(to: mURL)
            manifestURL = mURL

            // SECONDARY: also emit the manifest as a GUEST EXPORT named
            // `patch_host_symbols` (the SAME packed-(ptr,len)->i64 ABI as
            // `patch_view_manifest`). The JSON file above stays for engine-side
            // debugging; THIS guest source is what ships in the module so the SDK's
            // activation cross-check reads the routed-symbol set. Allocator emitted
            // here (standalone host-bridge guest module); a merge with a guest that
            // already exports `patch_malloc` strips it via the dedup pass.
            let guestSource = try HostBridgeABI.emitManifestGuestExport(
                manifestSymbols, includeAllocator: true)
            let gURL = buildDir.appendingPathComponent(Self.manifestGuestFileName)
            try guestSource.write(to: gURL, atomically: true, encoding: .utf8)
        }

        if !thunkResult.fileContents.isEmpty {
            let tURL = buildDir.appendingPathComponent(HostBridgeThunkGenerator.fileName)
            try thunkResult.fileContents.write(to: tURL, atomically: true, encoding: .utf8)
            thunkURL = tURL
        }

        // (4) THE RE-SPLIT (the headline Lever-#2 step). For each forced-native
        // function whose calls KEPT routing (survived the thunk-typecheck net),
        // splice each routed call's `patch_host.call` guest sequence back INTO the
        // function's body, then prove the rewritten body actually lowers. A function
        // whose ONLY native-ness was bridgeable calls now flips native→OTA: its
        // rewritten body ships a guest WASM fragment. DEMOTE-SAFE: a function whose
        // remainder is NOT liftable (a residual `self`/native call beyond the bridged
        // ones, an unmarshallable boundary) stays native — the re-lower simply
        // declines it. Only the KEPT-routed symbols are spliced (an id dropped by the
        // thunk net is left native, so its guest sequence would `have()==0`-demote;
        // we never splice a sequence the manifest doesn't carry).
        let keptByFunction = Dictionary(grouping: keptRouted, by: { $0.functionID })
        var lowered: [Lowered] = []
        for (fnID, fnRouted) in keptByFunction.sorted(by: { $0.key < $1.key }) {
            guard let body = bodyByFunction[fnID], let rec = recordByFunction[fnID] else { continue }
            guard let l = reLowerFunction(record: rec, bodySource: body, routed: fnRouted) else {
                // The remainder isn't liftable → keep native (demote-safe). Record it
                // so the "why didn't this lower" report can name it.
                demoted.append((fnID, fnRouted.first?.nativeExpr ?? "",
                                "routed call(s) bridged but the function body did not re-lower (residual native remainder)"))
                continue
            }
            lowered.append(l)
        }

        return Result(
            routed: keptRouted.sorted { $0.symbol.id < $1.symbol.id },
            lowered: lowered.sorted { $0.functionID < $1.functionID },
            manifestURL: manifestURL,
            thunkURL: thunkURL,
            demoted: demoted,
            thunkDemoted: thunkResult.demoted,
            examinedForcedNativeFunctions: forcedNative.count)
    }

    // -------------------------------------------------------------------------
    // MARK: - The RE-SPLIT (re-lower a forced-native function to OTA)
    // -------------------------------------------------------------------------

    /// Re-lower one forced-native function whose bridgeable calls routed: splice each
    /// routed call's `patch_host.call` guest sequence into the body in place of the
    /// verbatim native call, then PROVE the rewritten body is now a liftable guest
    /// fragment. Returns the `Lowered` (the function flips native→OTA) or nil (the
    /// body did not re-lower → keep native, demote-safe).
    ///
    /// PROOF / DEMOTE-SAFETY (returns nil unless ALL hold):
    ///   * every routed call's `nativeExpr` occurs EXACTLY ONCE in the body (so the
    ///     splice is unambiguous; a 0- or N-occurrence span is left verbatim and that
    ///     call simply doesn't bridge),
    ///   * the rewritten body PARSES cleanly (a corrupt splice never ships — a span
    ///     that, substituted, produces un-parseable Swift keeps the function native),
    ///   * at least one routed sequence was spliced (else there is no OTA work).
    /// The spliced sequence itself is the PROVEN guest emission (`have()` pre-flight +
    /// `__patchHostCall` dispatch + verbatim-native `.error`/absent fallback), so the
    /// re-lowered body is correct WHERE it routes and demotes to the real native call
    /// wherever a symbol is unresolved on-device. ANY residual native code the splice
    /// could NOT bridge stays VERBATIM in the body — caught downstream: the routed
    /// symbols ride the manifest+thunk (which the SDK resolves) and the WASM compile's
    /// convergence loop is the final compile-or-demote net for a body whose remainder
    /// genuinely can't lower. This method's job is the ENGINE-side flip: it returns a
    /// body that NO LONGER routes only-native (it now carries ≥1 `patch_host.call`),
    /// which is exactly "the function flips native→OTA via the bridge."
    func reLowerFunction(record: FunctionRecord,
                         bodySource: String,
                         routed: [Routed]) -> Lowered? {
        var rewritten = bodySource
        var splicedIDs: [Int32] = []
        var splicedCount = 0

        // Splice each routed call's native expr → its guest sequence. Apply in
        // descending native-expr LENGTH order so a longer expr (which may CONTAIN a
        // shorter routed expr as a sub-span) is substituted first — preventing a
        // shorter span from corrupting a longer one. Occurrence-exact: a span that
        // doesn't occur exactly once is skipped (its call stays native verbatim).
        for r in routed.sorted(by: { $0.nativeExpr.count > $1.nativeExpr.count }) {
            let occurrences = rewritten.components(separatedBy: r.nativeExpr).count - 1
            guard occurrences == 1 else { continue }
            rewritten = rewritten.replacingOccurrences(of: r.nativeExpr, with: r.guestSequence)
            splicedIDs.append(r.symbol.id)
            splicedCount += 1
        }
        guard splicedCount >= 1 else { return nil }

        // The rewritten body must PARSE (a corrupt splice never ships).
        guard !Parser.parse(source: rewritten).hasError else { return nil }

        let base = HostBridgeLowering.sanitizedBase(record.id)
        let exportSymbol = "patch_relower__\(base)"
        return Lowered(
            functionID: record.id,
            exportSymbol: exportSymbol,
            guestBody: rewritten,
            routedSymbolIDs: splicedIDs.sorted(),
            routedCallCount: splicedCount)
    }

    /// A stable, collision-free identifier base for the re-lowered export, derived
    /// from the function's fully-qualified id (drop the parameter clause, keep the
    /// type path, map non-identifier chars to `_`).
    static func sanitizedBase(_ id: String) -> String {
        let noParams = id.split(separator: "(").first.map(String.init) ?? id
        var out = ""
        for ch in noParams {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else { out.append("_") }
        }
        if let first = out.first, !(first.isLetter || first == "_") { out = "_" + out }
        return out.isEmpty ? "_anon" : out
    }

    /// The manifest file the SDK reads on module activation.
    public static let manifestFileName = "patch_host_symbols.json"

    /// The GUEST-EXPORT manifest source: a `@_cdecl("patch_host_symbols")` that
    /// returns the manifest JSON over the packed (ptr,len)->i64 ABI. The compiled
    /// version of THIS is what the SDK reads on-device; the `.json` file above is
    /// engine-side debugging metadata.
    public static let manifestGuestFileName = "patch_host_symbols.guest.swift"

    // -------------------------------------------------------------------------
    // MARK: - Forced-native collection
    // -------------------------------------------------------------------------

    /// Every function the engine keeps native — the bucket whose routable call sites
    /// this pass tries to bridge. Includes both the `forcesNative` records and any
    /// function the classifier landed `.native`. De-duped by id, source-ordered.
    func collectForcedNative(report: CoverageReport) -> [FunctionRecord] {
        var ids = Set<String>()
        for r in report.results where r.classification == .native { ids.insert(r.functionID) }
        for (id, rec) in report.records where rec.forcesNative { ids.insert(id) }
        return ids.compactMap { report.records[$0] }
            .sorted { ($0.sourceFile.path, $0.startLine) < ($1.sourceFile.path, $1.startLine) }
    }

    /// Slice a function's whole declaration text from its source file (1-based
    /// `startLine...endLine`). `HostBridgeCallExtractor.extract(fromSource:)` parses
    /// it + seeds the param types, so the whole `func` decl is the right granularity.
    func sliceBody(of rec: FunctionRecord, cache: inout [URL: [Substring]]) -> String? {
        let lines: [Substring]
        if let cached = cache[rec.sourceFile] {
            lines = cached
        } else {
            guard let text = try? String(contentsOf: rec.sourceFile, encoding: .utf8) else { return nil }
            let split = text.split(separator: "\n", omittingEmptySubsequences: false)
            cache[rec.sourceFile] = split
            lines = split
        }
        let start = max(0, rec.startLine - 1)
        let end = min(lines.count, rec.endLine)
        guard start < end else { return nil }
        return lines[start..<end].joined(separator: "\n")
    }

    /// Build a return-type oracle keyed by `<Receiver>.<function>` from every
    /// `func`/`static func` declared in the project's source. The extractor consumes
    /// it as `returnTypeHints` so an app-local call's return type resolves (the engine
    /// HAS the decl; the extractor sees only the call site). Honest by construction —
    /// only real, parsed declarations contribute; an absent key falls back to the
    /// curated framework table then to unresolved (demote). The key spelling matches
    /// the extractor's hint key: the call-site RECEIVER text + the member name (so a
    /// static `PricingEngine.discount` keys on `PricingEngine.discount`).
    func buildReturnTypeOracle(sourceDir: URL) -> [String: String] {
        var oracle: [String: String] = [:]
        for file in readAppSwiftFileURLs(sourceDir: sourceDir) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let tree = Parser.parse(source: text)
            let collector = ReturnTypeCollector(viewMode: .sourceAccurate)
            collector.walk(tree)
            // A method declared on a type keys under both `<Type>.<fn>` (static-call
            // spelling) and the bare `<fn>` (free-function spelling) — the extractor's
            // key is the receiver TEXT, which for a static call is the type name.
            for (key, ret) in collector.returns where oracle[key] == nil { oracle[key] = ret }
        }
        return oracle
    }

    // -------------------------------------------------------------------------
    // MARK: - RoutedSymbol construction (the resolver-thunk input)
    // -------------------------------------------------------------------------

    /// Build the `RoutedSymbol` (the App-Store-clean dispatch-table entry) from a
    /// routed call site. The call template re-spells the native call with each arg a
    /// `\u{1}k\u{1}` placeholder the generator substitutes with a typed TLV decode.
    /// Returns nil when no clean nominal call shape can be reconstructed (→ keep native).
    func makeRoutedSymbol(candidate: GeneralBridgeRewriter.Candidate,
                          site: GeneralBridgeRewriter.CallSite,
                          symbol: HostBridgeSymbol) -> RoutedSymbol? {
        guard let template = callTemplate(candidate: candidate) else { return nil }
        let argTypes: [ArgType] = candidate.args.map { argType(forTag: $0.isHandle, swiftType: $0.swiftType) }
        let retType = returnType(forTag: site.returnTag, swiftType: candidate.returnType)
        return RoutedSymbol(
            id: symbol.id,
            canonicalSignature: symbol.canonicalSignature,
            callTemplate: template,
            argTypes: argTypes,
            returnType: retType,
            requiredImports: requiredImports(for: candidate))
    }

    /// Re-spell the native call with placeholders for each argument. We rebuild the
    /// call from the parsed candidate (receiver + function + the original arg labels
    /// recovered from `nativeExpr`) rather than string-replacing inside `nativeExpr`,
    /// so a literal arg or a duplicated sub-expression can't mis-substitute. The
    /// labels are parsed from the native expression's argument clause.
    func callTemplate(candidate: GeneralBridgeRewriter.Candidate) -> String? {
        // KNOWN-SYMBOL BOUNDARY RECONSTRUCTION (additive). A curated framework symbol
        // whose wire-marshalled arg differs from its NATIVE parameter (the wire carries
        // a String, the real call needs a `Notification.Name` / `URL`) supplies the
        // exact native call expression the resolver-thunk must use. Prefer it when
        // present; a non-match (or a curated entry with no special template) falls
        // through to the default plain re-spell below — strictly additive, demote-safe.
        if let known = HostBridgeKnownSymbols.lookup(
            receiver: candidate.receiver, method: candidate.function, arity: candidate.args.count),
           let nativeTemplate = known.nativeCallTemplate {
            return nativeTemplate
        }
        // Parse the native call to recover the per-arg labels in order.
        guard let labels = argumentLabels(of: candidate.nativeExpr),
              labels.count == candidate.args.count else {
            // Arity/label mismatch (a complex call we can't faithfully re-spell) →
            // keep native (no broken thunk).
            return nil
        }
        let receiver: String
        switch candidate.kind {
        case .freeOrStatic:
            receiver = candidate.receiver.isEmpty ? "" : candidate.receiver + "."
        case .foundationStateless:
            receiver = candidate.receiver.isEmpty ? "" : candidate.receiver + "."
        }
        var parts: [String] = []
        for (k, label) in labels.enumerated() {
            let placeholder = "\u{1}\(k)\u{1}"
            if let label, !label.isEmpty {
                parts.append("\(label): \(placeholder)")
            } else {
                parts.append(placeholder)
            }
        }
        return "\(receiver)\(candidate.function)(\(parts.joined(separator: ", ")))"
    }

    /// Recover the per-argument labels (in order) from a native call expression by
    /// parsing it. A `nil` element = an unlabelled argument.
    func argumentLabels(of nativeExpr: String) -> [String?]? {
        let expr = Parser.parse(source: nativeExpr).statements.first?.item
        guard let call = expr?.as(FunctionCallExprSyntax.self)
                ?? findFirstCall(in: Syntax(Parser.parse(source: nativeExpr))) else {
            return nil
        }
        return call.arguments.map { $0.label?.text }
    }

    private func findFirstCall(in tree: Syntax) -> FunctionCallExprSyntax? {
        final class Finder: SyntaxVisitor {
            var found: FunctionCallExprSyntax?
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .skipChildren
            }
        }
        let f = Finder(viewMode: .sourceAccurate)
        f.walk(tree)
        return f.found
    }

    /// The plain `import` lines the call template needs in scope (the module the
    /// native symbol + its arg/return types live in). Best-effort from the candidate's
    /// canonical receiver module prefix; the generator emits each `#if canImport`-guarded.
    func requiredImports(for candidate: GeneralBridgeRewriter.Candidate) -> [String] {
        // The canonical signature is module-qualified (`Foundation.X`, `UIKit.Y`,
        // `MyApp.Z`). Extract the leading module of the receiver for the import.
        let sig = candidate.canonicalSignature
        guard let dot = sig.firstIndex(of: ".") else { return [] }
        let mod = String(sig[sig.startIndex..<dot])
        // The app module + Foundation are always in scope; only add a framework.
        let known: Set<String> = ["UIKit", "AppKit", "SwiftUI", "CoreGraphics", "CoreLocation"]
        return known.contains(mod) ? [mod] : []
    }

    // -------------------------------------------------------------------------
    // MARK: - De-dupe helpers (one dispatch entry per content-addressed id)
    // -------------------------------------------------------------------------

    func uniqueRoutedSymbols(_ routed: [Routed]) -> [RoutedSymbol] {
        var seen = Set<Int32>()
        var out: [RoutedSymbol] = []
        for r in routed where seen.insert(r.symbol.id).inserted { out.append(r.routedSymbol) }
        return out.sorted { $0.id < $1.id }
    }

    func uniqueHostBridgeSymbols(_ routed: [Routed]) -> [HostBridgeSymbol] {
        var seen = Set<Int32>()
        var out: [HostBridgeSymbol] = []
        for r in routed where seen.insert(r.symbol.id).inserted { out.append(r.symbol) }
        return out.sorted { $0.id < $1.id }
    }

    // -------------------------------------------------------------------------
    // MARK: - App source for the compiles-or-demote net
    // -------------------------------------------------------------------------

    /// The developer's real source, concatenated, as the `appTypeStub` the
    /// `BridgeThunkValidator` type-checks each generated thunk against. The net's
    /// own safety valve skips (keeps all) when this baseline can't compile on its
    /// own (unresolvable third-party imports) — so it only demotes when it can PROVE
    /// a thunk broke an otherwise-clean compile.
    func readAppSource(sourceDir: URL) -> String {
        readAppSwiftFileURLs(sourceDir: sourceDir)
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// The developer's real `.swift` source URLs (excluding build artifacts + test
    /// files), shared by the typecheck-net baseline + the return-type oracle.
    func readAppSwiftFileURLs(sourceDir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            let p = url.path
            if p.contains("/.build/") || p.contains("/.git/") || p.lowercased().contains("/.patch/") { continue }
            if SwiftParserEngine.isBuildArtifactPath(p.lowercased()) { continue }
            if SwiftParserEngine.isTestFile(url) { continue }
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    // -------------------------------------------------------------------------
    // MARK: - Tag / type mappings (the 1:1 wire ↔ Swift-decode view)
    // -------------------------------------------------------------------------

    /// `HostBridgeValueTag` (the rewriter's tag) → `TLVTag` (the ABI core's wire tag).
    /// The two enums share raw values (asserted in the vertical-slice test), so this
    /// is a total, lossless map.
    func tlvTag(_ tag: HostBridgeValueTag) -> TLVTag {
        TLVTag(rawValue: tag.rawValue) ?? .nilValue
    }

    /// The resolver-thunk's `ArgType` (which TLV decode to emit) for an arg.
    func argType(forTag isHandle: Bool, swiftType: String) -> ArgType {
        if isHandle { return .handle(canonicalType(swiftType)) }
        let t = swiftType.trimmingCharacters(in: .whitespaces)
        switch t {
        case "Int", "Int64", "Int32", "Int16", "Int8",
             "UInt", "UInt64", "UInt32", "UInt16", "UInt8":
            return .int
        case "Double", "Float", "CGFloat":
            return .double
        case "Bool":
            return .bool
        case "String":
            return .string
        case "Data", "[UInt8]":
            return .data
        default:
            // The classifier only routes a call whose args are marshallable; an
            // unrecognized type here means the classifier wouldn't have routed it.
            // Default to string conservatively (the thunk typecheck net catches drift).
            return .string
        }
    }

    /// The resolver-thunk's `ReturnType` (which TLV encode to emit) for the return.
    func returnType(forTag tag: HostBridgeValueTag, swiftType: String) -> ReturnType {
        switch tag {
        case .nilValue: return .void
        case .i64:      return .int
        case .f64:      return .double
        case .bool:     return .bool
        case .string:   return .string
        case .bytes:    return .data
        case .handle:   return .handle(canonicalType(swiftType))
        case .error:    return .void
        }
    }

    /// Strip a module prefix for the handle cast type spelling (the thunk casts the
    /// resolved handle to the bare nominal — `Foundation.NumberFormatter` → `NumberFormatter`).
    func canonicalType(_ t: String) -> String {
        t.split(separator: ".").last.map(String.init) ?? t
    }

    // -------------------------------------------------------------------------
    // MARK: - Shippable guest-module assembly (the SHIP step — Lever #2 close)
    // -------------------------------------------------------------------------

    /// A guest-COMPILABLE literal of the right Swift type for a probe arg of `tag`.
    /// The shipped probe needs SOME value to marshal — the routed `patch_host.call`
    /// for the content-addressed id is the load-bearing artifact, not the input — and
    /// it must compile standalone (the receiver type isn't reconstructable in-guest).
    func placeholderLiteral(for tag: TLVTag) -> String {
        switch tag {
        case .nilValue, .error: return "0"
        case .i64:              return "0"
        case .f64:              return "0.0"
        case .bool:             return "false"
        case .string:           return "\"\""
        case .bytes:            return "[UInt8]()"
        case .handle:           return "Int32(0)"
        }
    }

    /// Assemble the SHIPPABLE generic-host-bridge guest emission from a routed set:
    /// one `@_cdecl` probe PER FLIPPED FUNCTION (carrying that function's routed
    /// `patch_host.call` sequence, guest-compilable) + the `patch_host_symbols`
    /// manifest export. Returns nil when nothing routed (the pipeline ships no
    /// sub-module). The probe rebuilds the EXACT `emitCallSite` sequence the rewriter
    /// reported, but with a guest-safe demote (a default of the return type) so the
    /// module compiles + instantiates without the native receiver in scope.
    ///
    /// One probe PER FUNCTION (not per call site): a function that routes ≥1 call
    /// gets ONE export whose body chains its routed calls; here v1 ships one routed
    /// call per export (the dominant shape), keyed by the function id so two routed
    /// calls in one function each get a distinct, deterministic export name.
    public func buildGuestEmission(routed: [Routed]) throws
        -> GenericHostBridgeGuestEmitter.Emission? {
        guard !routed.isEmpty else { return nil }

        // Per-flipped-function probe. A function may carry >1 routed call — emit one
        // probe per (functionID, symbol-id) pair so each routed `patch_host.call` is
        // present, with a deterministic, collision-free export name.
        var flipped: [GenericHostBridgeGuestEmitter.FlippedFunction] = []
        var seenExport = Set<String>()
        for r in routed.sorted(by: { ($0.functionID, $0.symbol.id) < ($1.functionID, $1.symbol.id) }) {
            let base = "hb_call__" + sanitizeExport(r.functionID)
            var name = "\(base)__\(unsignedId(r.symbol.id))"
            // Defensive: a duplicate export name must never reach the compiler.
            var bump = 1
            while !seenExport.insert(name).inserted { name = "\(base)__\(unsignedId(r.symbol.id))_\(bump)"; bump += 1 }

            // The guest-safe re-lowered sequence: the rewriter's exact arg-blob +
            // dispatch + decode, with a literal demote (the native fallback can't
            // compile in-guest). `resultName` binds the routed result.
            let demote = guestSafeDemote(retTag: r.symbol.retTag)
            let callSite = HostBridgeABI.emitCallSite(
                symbol: r.symbol, args: r.probeArgs,
                resultName: "__routed", demoteBody: "return \(demote)")
            // Wrap into a `{ () -> Ret in … }()` so the probe body is one expression
            // the export wrapper returns (matching the FlippedFunction contract).
            let retType = swiftReturnTypeSpelling(r.symbol.retTag, raw: r.returnType)
            let sequence = """
            { () -> \(retType) in
                \(callSite.split(separator: "\n").joined(separator: "\n        "))
                return __routed
            }()
            """
            flipped.append(.init(exportName: name, guestSequence: sequence,
                                 returnType: r.returnType, argBindings: []))
        }

        let symbols = uniqueHostBridgeSymbols(routed)
        return try GenericHostBridgeGuestEmitter().emit(flipped: flipped, symbols: symbols)
    }

    /// A guest-compilable default of the routed return type — the demote path the
    /// shipped probe takes when `have()` is false / the result tag mismatches (on
    /// device the SDK always resolves the symbol, so this is the benign fallback).
    func guestSafeDemote(retTag: TLVTag) -> String {
        switch retTag {
        case .nilValue, .error: return "()"
        case .i64:              return "0"
        case .f64:              return "0.0"
        case .bool:             return "false"
        case .string:           return "\"\""
        case .bytes:            return "[UInt8]()"
        case .handle:           return "Int32(0)"
        }
    }

    /// The Swift type the routed result binds as (matches the ABI core's decode).
    func swiftReturnTypeSpelling(_ retTag: TLVTag, raw: String) -> String {
        switch retTag {
        case .nilValue, .error: return "Void"
        case .i64:              return "Int"
        case .f64:              return "Double"
        case .bool:             return "Bool"
        case .string:           return "String"
        case .bytes:            return "[UInt8]"
        case .handle:           return "Int32"
        }
    }

    /// Sanitize a function id into a valid C identifier fragment (the export name).
    func sanitizeExport(_ id: String) -> String {
        var out = ""
        for ch in id {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else { out.append("_") }
        }
        if let first = out.first, first.isNumber { out = "_" + out }
        return out.isEmpty ? "fn" : out
    }

    /// The symbol id as an unsigned decimal (a valid identifier fragment; the raw
    /// Int32 can be negative, which isn't a legal C identifier suffix).
    func unsignedId(_ id: Int32) -> UInt32 { UInt32(bitPattern: id) }
}

// =============================================================================
// MARK: - The ABI-core adapter
//
// `GeneralBridgeRewriter` codes against the small `HostBridgeABIProvider`
// interface so it built standalone against `StubHostBridgeABI`. At THIS
// integration we supply the REAL ABI core (`HostBridgeABI`) — content-addressed
// SHA256 symbol ids + the proven embedded-safe TLV writer/decoder shapes — so the
// guest sequence the rewriter emits uses the real id the manifest + the resolver
// thunk agree on, not the stub's legible fold.
// =============================================================================

struct HostBridgeABIAdapter: HostBridgeABIProvider {

    func symbolIdLiteral(forCanonicalSignature signature: String) -> String {
        // The REAL content-addressed id (truncate32(SHA256(sig))) the manifest +
        // the resolver thunk both key on — emitted as an Int32 literal so the guest
        // dispatches on the SAME id.
        "Int32(\(HostBridgeABI.hostBridgeSymbolId(signature)))"
    }

    func makeArgWriterExpression() -> String { "__PatchTLVWriter()" }

    func argEncodeStatement(writerVar: String, tag: HostBridgeValueTag, expr: String) -> String {
        // Mirror the real `HostBridgeABI.emitGuestPreamble`'s `__PatchTLVWriter` API.
        switch tag {
        case .i64:      return "\(writerVar).i64(Int64(\(expr)))"
        case .f64:      return "\(writerVar).f64(Double(\(expr)))"
        case .bool:     return "\(writerVar).bool(\(expr))"
        case .string:   return "\(writerVar).string(\(expr))"
        case .bytes:    return "\(writerVar).bytes(\(expr))"
        case .handle:   return "\(writerVar).handle(\(expr))"
        case .nilValue, .error: return "\(writerVar).nilValue()"
        }
    }

    func callImportExpression(symbolIdLiteral: String, writerVar: String) -> String {
        // The real preamble's dispatcher takes the writer by value.
        "__patchHostCall(\(symbolIdLiteral), \(writerVar))"
    }

    func haveImportCall(symbolIdLiteral: String) -> String {
        // The flat `patch_host.have` import the CBridge declares.
        "patch_host_have(\(symbolIdLiteral))"
    }

    func resultDecodeSuccessPattern(for tag: HostBridgeValueTag) -> String {
        switch tag {
        case .nilValue: return ".nilValue"
        case .i64:      return ".i64(let __v)"
        case .f64:      return ".f64(let __v)"
        case .bool:     return ".bool(let __v)"
        case .string:   return ".string(let __v)"
        case .bytes:    return ".bytes(let __v)"
        case .handle:   return ".handle(let __v)"
        case .error:    return ".error(let __v)"
        }
    }

    func resultSuccessExpression(for tag: HostBridgeValueTag) -> String {
        switch tag {
        case .nilValue: return "()"
        case .error:    return "()"
        case .handle:   return "__v"
        case .i64:      return "Int(__v)"
        case .f64:      return "__v"
        case .bool, .string, .bytes:
            return "__v"
        }
    }

    func swiftReturnType(for tag: HostBridgeValueTag, isHandle: Bool) -> String {
        if isHandle { return "Int32" }   // a handle proxy is an opaque Int32 guest-side
        switch tag {
        case .nilValue: return "Void"
        case .i64:      return "Int"
        case .f64:      return "Double"
        case .bool:     return "Bool"
        case .string:   return "String"
        case .bytes:    return "[UInt8]"
        case .handle:   return "Int32"
        case .error:    return "Void"
        }
    }
}

// =============================================================================
// MARK: - The return-type collector
//
// Walks a parsed file and records every `func`/`static func` declaration's
// return type, keyed by the call-site spelling the extractor's hint key uses:
//   * a method on `Type` keys under `<Type>.<fn>` (the static/instance receiver text),
//   * a free function keys under `<fn>`.
// A `Void` / absent return is recorded as `Void` (the extractor omits the arrow).
// Only declared-and-parsed return types contribute — never a guess.
// =============================================================================

private final class ReturnTypeCollector: SyntaxVisitor {
    var returns: [String: String] = [:]
    private var typeStack: [String] = []

    private func pushType(_ name: String) { typeStack.append(name) }
    private func popType() { if !typeStack.isEmpty { typeStack.removeLast() } }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { popType() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { popType() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { popType() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { popType() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // The extended type's last component is the receiver name.
        let name = node.extendedType.trimmedDescription.split(separator: ".").last.map(String.init)
            ?? node.extendedType.trimmedDescription
        pushType(name); return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { popType() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let fn = node.name.text
        let ret = node.signature.returnClause?.type.trimmedDescription ?? "Void"
        if let type = typeStack.last {
            if returns["\(type).\(fn)"] == nil { returns["\(type).\(fn)"] = ret }
        } else {
            if returns[fn] == nil { returns[fn] = ret }
        }
        return .visitChildren
    }
}
