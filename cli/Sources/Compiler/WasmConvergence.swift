// SPDX-License-Identifier: Apache-2.0

import Foundation
import PartitioningEngine

/// Drives the **auto-reclassify-on-compile-failure** loop (DECISIONS / plan
/// Days 2-8). Given a set of candidate WASM source files (one per OTA-eligible
/// function or fragment), it attempts a real compile; if compilation fails, the
/// offending source is dropped and reclassified `native`, and the build retries
/// with the survivors. This is conservative and safe: a function that does not
/// compile to WASM can never run OTA, so demoting it to native is always correct
/// (it only costs coverage, never safety).
public struct WasmConvergence {
    public let compiler: WasmCompiling

    public init(compiler: WasmCompiling) {
        self.compiler = compiler
        self.supportSources = []
    }

    /// One candidate unit of WASM-bound code.
    public struct Candidate: Sendable, Hashable {
        /// The originating function id (for the reclassify report).
        public let functionID: String
        /// The generated `_wasm.swift` file for this unit.
        public let sourceFile: URL
        /// Symbols this unit exports (fragment entry points).
        public let exports: [String]

        public init(functionID: String, sourceFile: URL, exports: [String]) {
            self.functionID = functionID
            self.sourceFile = sourceFile
            self.exports = exports
        }
    }

    /// Support sources always included in the compile unit but never demoted
    /// (e.g. the developer's pure `.swift` files that the generated `@_cdecl`
    /// wrappers call into, and the types they reference). If one of these fails to
    /// compile, the whole module fails — but that is correct: a pure-export
    /// wrapper cannot run without its underlying logic, so there is nothing to
    /// salvage. The failure is reported via the final outcome (no module).
    public var supportSources: [URL]

    public init(compiler: WasmCompiling, supportSources: [URL]) {
        self.compiler = compiler
        self.supportSources = supportSources
    }

    public struct Outcome: Sendable {
        /// Candidates that compiled and ship OTA.
        public let compiled: [Candidate]
        /// Candidates demoted to native because their WASM source failed to compile.
        public let reclassifiedNative: [Candidate]
        /// The final emitted module (nil if nothing compiled or toolchain absent).
        public let moduleURL: URL?
        /// True if the toolchain was unavailable (everything stays as-is, no demotions).
        public let toolchainUnavailable: Bool
        public let iterations: Int
        public let log: String
        /// The tier the module actually compiled at (after any escalation). nil if
        /// nothing compiled / toolchain absent.
        public let finalTier: PackagingTier?

        public init(compiled: [Candidate], reclassifiedNative: [Candidate], moduleURL: URL?,
                    toolchainUnavailable: Bool, iterations: Int, log: String,
                    finalTier: PackagingTier? = nil) {
            self.compiled = compiled
            self.reclassifiedNative = reclassifiedNative
            self.moduleURL = moduleURL
            self.toolchainUnavailable = toolchainUnavailable
            self.iterations = iterations
            self.log = log
            self.finalTier = finalTier
        }
    }

    /// Converge: compile all candidates together; on failure, demote the
    /// implicated candidate(s) and retry until the set compiles or empties.
    ///
    /// Bisection-free strategy: because the candidates are independent source
    /// files, a failure names a file in its diagnostic. We parse the failing
    /// file path out of the log; if we cannot attribute the failure to a single
    /// file, we fall back to demoting candidates one at a time (slow but safe).
    ///
    /// ## Tier escalation (the smallest-viable-tier safety net)
    /// The build starts at the smallest tier the classifier picked (`startTier`,
    /// default T0 Embedded). When the WHOLE set fails to compile (no single
    /// candidate is implicated, and no support source is the culprit), the module
    /// is **escalated to the next-larger tier** (T0 → T1 → T2) and retried with
    /// the full survivor set, BEFORE demoting any candidate. This realizes
    /// "pick the smallest viable tier" without ever shipping a broken module: a
    /// construct embedded rejects (an existential, a Foundation type with no
    /// bridge) is recovered by re-compiling at T1/T2 rather than dropped. Only
    /// when even T2 cannot place a candidate is it demoted to native.
    /// When `bailOnUnattributableFailure` is true, a compile failure that names NO
    /// candidate and NO support source (a MODULE-WIDE poison — e.g. a real-source
    /// closure that doesn't compile as a whole, or a wrong module name) ends the loop
    /// immediately with no module, instead of slowly demoting candidates one-by-one
    /// (which can never recover from a module-wide poison and wastes a full recompile
    /// per candidate). Used by the real-source closure path: a poison there means the
    /// whole additive module can't ship, so the right answer is 0 extra units, fast.
    /// `maxTier` caps tier ESCALATION: the loop never escalates past it, so a candidate
    /// that needs a larger tier is DEMOTED (kept out of this module) instead of dragging
    /// the whole module up to a bigger SDK. This is the lever for decl-level T0
    /// ISOLATION: a T0-pinned convergence (`startTier == .t0Embedded`, `maxTier ==
    /// .t0Embedded`) ships ONLY the exports whose closure is genuinely embedded-clean and
    /// demotes the Foundation-needing ones — the caller then re-routes those to a separate
    /// T2 module. Default `nil` = no cap (escalate freely to T2, the historical behavior).
    public func converge(_ candidates: [Candidate], outputModule: URL,
                         startTier: PackagingTier = .t0Embedded,
                         maxIterations: Int = 64,
                         bailOnUnattributableFailure: Bool = false,
                         maxTier: PackagingTier? = nil) throws -> Outcome {
        var survivors = candidates
        var demoted: [Candidate] = []
        var fullLog = ""
        var iteration = 0
        var tier = startTier
        // Mutable support set: a broken per-type reconstruction (`_PatchType_<T>.swift`)
        // can be dropped (and its dependent candidates demoted) without killing the
        // whole module — this is what lets independent candidates still ship.
        var activeSupport = supportSources

        while iteration < maxIterations {
            iteration += 1
            if survivors.isEmpty {
                return Outcome(compiled: [], reclassifiedNative: demoted, moduleURL: nil,
                               toolchainUnavailable: false, iterations: iteration, log: fullLog,
                               finalTier: nil)
            }

            let sources = survivors.map(\.sourceFile) + activeSupport
            // The guest allocator (`patch_malloc`/`patch_free`) lives in a SHARED
            // support source (so demoting any candidate can't strip it). Its export
            // symbols therefore aren't in any candidate's `exports`; add them here so
            // the linker always exports the allocator the host needs to marshal I/O.
            var exports = survivors.flatMap(\.exports)
            exports.append(contentsOf: ["patch_malloc", "patch_free"])
            let result = try compileWith(sources: sources, exports: exports,
                                         outputModule: outputModule, tier: tier)
            fullLog += "\n--- iteration \(iteration) (\(survivors.count) candidates, tier \(tier.rawValue)) ---\n" + result.log

            switch result.status {
            case .success:
                return Outcome(compiled: survivors, reclassifiedNative: demoted,
                               moduleURL: result.moduleURL, toolchainUnavailable: false,
                               iterations: iteration, log: fullLog, finalTier: tier)
            case .toolchainUnavailable:
                return Outcome(compiled: survivors, reclassifiedNative: [], moduleURL: nil,
                               toolchainUnavailable: true, iterations: iteration, log: fullLog,
                               finalTier: nil)
            case .failure:
                // (1) Try escalating the whole module to a larger tier first. A
                //     failure with no single attributable candidate is usually an
                //     embedded/stdlib-feature gap, recoverable at a higher tier.
                let attributable = attributeFailure(in: result.log, among: survivors) != nil
                // Respect the escalation CAP: don't climb past `maxTier`. When capped at
                // the current tier, fall through to candidate demotion so the
                // closure/wrapper that needs a bigger tier leaves THIS module (the
                // caller re-routes it). `maxTier == nil` = uncapped (escalate to T2).
                let capReached = maxTier.map { tier >= $0 } ?? false
                if !attributable, !capReached, let next = nextTier(after: tier) {
                    fullLog += "\n[tier] compile failed at \(tier.rawValue) (no single culprit) — escalating to \(next.rawValue)\n"
                    tier = next
                    continue
                }
                if !attributable, capReached {
                    fullLog += "\n[tier] compile failed at \(tier.rawValue) but escalation capped at \(maxTier!.rawValue) — demoting culprit(s) instead\n"
                }
                // (2) If a SUPPORT source is the culprit, try to ISOLATE it. A broken
                //     per-type reconstruction (`_PatchType_<T>.swift` — e.g. a non-Codable
                //     or `#if !$Embedded`-guarded type) is dropped, and only the candidates
                //     that reference that type are demoted; the independent candidates still
                //     ship. This cascades transitively across recompiles. Only a CORE support
                //     failure (allocator/helpers/generics) is non-recoverable.
                let failingSupport = activeSupport.filter { s in
                    result.log.split(separator: "\n").contains {
                        $0.contains("error:") && Self.lineBlamesFile($0, s.lastPathComponent) }
                }
                if !failingSupport.isEmpty {
                    let typeFiles = failingSupport.filter { $0.lastPathComponent.hasPrefix("_PatchType_") }
                    // `_PatchGenerics.swift` (the verbatim whole-library closure, for
                    // generic monomorphization) is treated like a helper: a large/complex
                    // library closure that references an unbundled symbol or trips strict
                    // concurrency is DROPPED, so candidates that DON'T depend on it (pure
                    // exports with their own reconstruction — e.g. NetNewsWire's UTF
                    // transcoders) still ship instead of all dying on the shared file.
                    let helperFiles = failingSupport.filter {
                        $0.lastPathComponent.hasPrefix("_PatchHelper_") || $0.lastPathComponent == "_PatchGenerics.swift" }
                    let coreFiles = failingSupport.filter {
                        !$0.lastPathComponent.hasPrefix("_PatchType_")
                        && !$0.lastPathComponent.hasPrefix("_PatchHelper_")
                        && $0.lastPathComponent != "_PatchGenerics.swift" }
                    if coreFiles.isEmpty && (!typeFiles.isEmpty || !helperFiles.isEmpty) {
                        for tf in typeFiles {
                            let typeName = String(tf.lastPathComponent.dropFirst("_PatchType_".count).dropLast(".swift".count))
                            let deps = survivors.filter { candidateReferencesType($0, typeName) }
                            demoted.append(contentsOf: deps)
                            survivors.removeAll { c in deps.contains(c) }
                            activeSupport.removeAll { $0 == tf }
                            fullLog += "[isolate] broken type support \(tf.lastPathComponent) dropped; demoted \(deps.count) dependent candidate(s)\n"
                        }
                        // A broken transitive helper (reads instance state, or calls a
                        // member of an incompletely-reconstructed type) is simply DROPPED.
                        // Any candidate that actually called it then fails the NEXT compile
                        // and is demoted via attributeFailures — so the clean candidates in
                        // the same module still ship instead of all dying on a shared file.
                        for hf in helperFiles {
                            activeSupport.removeAll { $0 == hf }
                            fullLog += "[isolate] broken helper support \(hf.lastPathComponent) dropped\n"
                        }
                        continue
                    }
                    // A core support source (the developer's shared pure logic / allocator)
                    // failed — not recoverable by demoting a candidate.
                    return Outcome(compiled: [], reclassifiedNative: survivors + demoted,
                                   moduleURL: nil, toolchainUnavailable: false,
                                   iterations: iteration, log: fullLog, finalTier: nil)
                }
                // (3) Demote EVERY candidate the diagnostics blame in one pass (a
                //     compile reports all failing files at once), so a module with N
                //     bad candidates converges in ~1 extra iteration instead of N
                //     slow recompiles. If none is attributable, demote the first
                //     survivor (safe fallback).
                let culprits = attributeFailures(in: result.log, among: survivors)
                if culprits.isEmpty && bailOnUnattributableFailure {
                    // Module-wide poison the loop can't attribute or escalate around —
                    // bail fast (no module) rather than demote one survivor per slow
                    // recompile. The default module is unaffected (separate build).
                    fullLog += "\n[bail] unattributable module-wide failure — stopping (no module).\n"
                    return Outcome(compiled: [], reclassifiedNative: survivors + demoted,
                                   moduleURL: nil, toolchainUnavailable: false,
                                   iterations: iteration, log: fullLog, finalTier: nil)
                }
                let toDemote = culprits.isEmpty ? [survivors[0]] : culprits
                demoted.append(contentsOf: toDemote)
                survivors.removeAll { toDemote.contains($0) }
            }
        }

        // Iteration budget exhausted WITHOUT a successful compile (moduleURL == nil):
        // the surviving candidates did NOT ship. They must be reported as DEMOTED, not
        // `compiled` — otherwise callers misreport a non-zero "compiled" count with no
        // module (e.g. `release` printing "Compiled OTA units: N" though nothing was
        // emitted), and the real-source `alreadyShipped` set would wrongly treat these
        // phantom exports as shipped and suppress the additive path. Keep `compiled`
        // consistent with `moduleURL`: both empty/nil here.
        return Outcome(compiled: [], reclassifiedNative: survivors + demoted, moduleURL: nil,
                       toolchainUnavailable: false, iterations: iteration, log: fullLog,
                       finalTier: nil)
    }

    /// The next-larger tier to escalate to, or nil if already at the largest.
    private func nextTier(after tier: PackagingTier) -> PackagingTier? {
        switch tier {
        case .t0Embedded: return .t1Stdlib
        case .t1Stdlib: return .t2Foundation
        case .t2Foundation: return nil
        }
    }

    private func compileWith(sources: [URL], exports: [String], outputModule: URL,
                             tier: PackagingTier? = nil) throws -> WasmCompileResult {
        if let realSrc = compiler as? RealSourceWasmCompiler {
            // Real-source closure compile: re-instantiate the wrapped compiler with
            // this iteration's export list (tier is fixed at the base — the wrappers
            // use the in-module JSON coder, i.e. T2 Foundation).
            let b = realSrc.base
            let c = SwiftWasmCompiler(
                toolchainSwift: b.toolchainSwift, swiftlyEnv: b.swiftlyEnv,
                exportedSymbols: exports, jobs: b.jobs, tier: tier ?? b.tier)
            let adapter = RealSourceWasmCompiler(
                base: c, moduleName: realSrc.moduleName, realSources: realSrc.realSources,
                fusionBridgeFiles: realSrc.fusionBridgeFiles)  // FUSION: forward the bridge files unchanged.
            return try adapter.compile(sources: sources, outputModule: outputModule)
        }
        if let real = compiler as? SwiftWasmCompiler {
            // Re-instantiate with the right export list (and tier) for this iteration.
            let c = SwiftWasmCompiler(
                toolchainSwift: real.toolchainSwift,
                swiftlyEnv: real.swiftlyEnv, exportedSymbols: exports, jobs: real.jobs,
                tier: tier ?? real.tier)
            return try c.compile(sources: sources, outputModule: outputModule)
        }
        return try compiler.compile(sources: sources, outputModule: outputModule)
    }

    /// Whether a compiler error names one of the always-included support sources
    /// (the developer's pure logic). Such a failure is not recoverable by demoting
    /// a candidate.
    private func failureNamesSupportSource(in log: String) -> Bool {
        let names = Set(supportSources.map { $0.lastPathComponent })
        for line in log.split(separator: "\n") where line.contains("error:") {
            for n in names where Self.lineBlamesFile(line, n) { return true }
        }
        return false
    }

    /// Whether a diagnostic line genuinely blames `fileName`, matching it as a
    /// WHOLE path component rather than a bare substring. A Swift diagnostic names
    /// a file as `…/<fileName>:line:col: error: …`, so the basename is bounded by a
    /// path separator (or string start) before and a `:` after. A plain
    /// `line.contains(fileName)` instead let one candidate's name be a SUBSTRING of
    /// another's (`a_wasm.swift` ⊂ `Xa_wasm.swift`, `foo_wasm.swift` ⊂
    /// `foofoo_wasm.swift`) — so an error in the LONGER file wrongly demoted the
    /// SHORTER candidate too, silently dropping a healthy OTA unit (lost coverage).
    static func lineBlamesFile(_ line: Substring, _ fileName: String) -> Bool {
        guard !fileName.isEmpty else { return false }
        let s = String(line)
        var searchStart = s.startIndex
        while let r = s.range(of: fileName, range: searchStart..<s.endIndex) {
            let beforeOK: Bool
            if r.lowerBound == s.startIndex {
                beforeOK = true
            } else {
                let prev = s[s.index(before: r.lowerBound)]
                // A path separator or whitespace delimits the basename; an
                // identifier char before it means we're inside a LONGER name.
                beforeOK = (prev == "/" || prev == " " || prev == "\t")
            }
            let afterOK: Bool
            if r.upperBound == s.endIndex {
                afterOK = true
            } else {
                let next = s[r.upperBound]
                // The diagnostic appends `:line:col:`; whitespace/EOL also ends it.
                afterOK = (next == ":" || next == " " || next == "\t")
            }
            if beforeOK && afterOK { return true }
            searchStart = r.upperBound
        }
        return false
    }

    /// Find which candidate a compiler diagnostic blames, by matching the file
    /// name that appears before `error:` in the log.
    private func attributeFailure(in log: String, among candidates: [Candidate]) -> Candidate? {
        for line in log.split(separator: "\n") where line.contains("error:") {
            for c in candidates where Self.lineBlamesFile(line, c.sourceFile.lastPathComponent) {
                return c
            }
        }
        return nil
    }

    /// ALL candidates any error line blames (deduped, original order). Lets the
    /// loop demote every failing candidate in one pass.
    private func attributeFailures(in log: String, among candidates: [Candidate]) -> [Candidate] {
        var blamed = Set<String>()
        for line in log.split(separator: "\n") where line.contains("error:") {
            for c in candidates where Self.lineBlamesFile(line, c.sourceFile.lastPathComponent) {
                blamed.insert(c.sourceFile.lastPathComponent)
            }
        }
        return candidates.filter { blamed.contains($0.sourceFile.lastPathComponent) }
    }

    /// Whether a candidate's generated source references a reconstructed type by name
    /// (i.e. it depends on that type's `_PatchType_<T>.swift` support file). Word-boundary
    /// match so `Edge` does not match `EdgeInsets`.
    private func candidateReferencesType(_ candidate: Candidate, _ typeName: String) -> Bool {
        guard !typeName.isEmpty,
              let text = try? String(contentsOf: candidate.sourceFile, encoding: .utf8) else { return false }
        let isIdent: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        var start = text.startIndex
        while let r = text.range(of: typeName, range: start..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            if !(before.map(isIdent) ?? false) && !(after.map(isIdent) ?? false) { return true }
            start = r.upperBound
        }
        return false
    }
}
