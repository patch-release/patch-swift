// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import PartitioningEngine
import CodeGenerator
import Compiler
import SwiftParser

struct Analyze: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analysis only, for CI. Reports OTA coverage; exits 1 if the native shell changed."
    )

    @Argument(help: "Path to a directory (or a single .swift file) to analyze.")
    var path: String

    @Option(name: .long, help: "Output format: text (default) or json.")
    var format: String = "text"

    @Flag(name: .long, help: "Print the per-function classification table.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Skip the realized-split pass (faster; reports only the optimistic mixed-inclusive OTA%).")
    var fastNoSplitCheck: Bool = false

    @Flag(name: .long, help: "Print the per-strategy realized-split outcome breakdown (A / sub-expr / guard / unrealized reasons).")
    var splitDiagnostics: Bool = false

    @Flag(name: .long, help: "CI gate: exit 1 if the native-shell fingerprint differs from the baseline (.Patch.yml + backend, or --fingerprint-baseline).")
    var checkFingerprint: Bool = false

    @Option(name: .long, help: "Expected native-shell fingerprint to compare against (CI; avoids a backend call).")
    var fingerprintBaseline: String?

    @Option(name: .long, help: "Backend base URL override (for --check-fingerprint).")
    var baseURL: String?

    func run() throws {
        let url = URL(fileURLWithPath: path)
        let engine = PartitioningEngine()
        // Parsing + classifying a whole project is silent and can take a while —
        // spin so it doesn't look stuck (stderr-only, so --format json stays clean).
        let report = try Spinner.run("Analyzing project (parse + classify)") {
            try engine.analyze(directory: url)
        }
        let realized = fastNoSplitCheck ? nil : Spinner.run("Computing realized OTA split") {
            computeRealized(report)
        }

        switch format.lowercased() {
        case "json":
            printJSON(report, realized: realized)
        default:
            printText(report, realized: realized)
        }

        if checkFingerprint {
            try runFingerprintGate(analyzePath: url)
        }
    }

    /// CI gate: compute the native-shell fingerprint and compare it to a
    /// baseline. Mismatch → exit code 1 (the native shell changed, so an OTA
    /// push would be incompatible; CI should fail and force an App Store ship).
    private func runFingerprintGate(analyzePath: URL) throws {
        // Project root: prefer .Patch.yml's directory, else the analyzed path.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var config = PatchConfig()
        var root = analyzePath
        if let configURL = PatchConfig.find(startingAt: cwd) {
            config = (try? PatchConfig.load(from: configURL)) ?? config
            root = CLISupport.projectRoot(for: configURL)
        }
        let snapshot = Spinner.run("Computing native-shell fingerprint") {
            ProjectFingerprinter().snapshot(
                projectDir: root, bridges: config.bridges, excludes: config.exclude,
                buildSwiftUI: config.buildSwiftUI)
        }

        // Resolve the baseline: explicit flag wins, else the backend's active fp.
        var baseline = fingerprintBaseline
        if baseline == nil, let appId = config.appId,
           let api = try? CLISupport.makeAPI(config: config, baseURLOverride: baseURL) {
            baseline = Spinner.run("Fetching the baseline fingerprint") {
                (try? api.getActiveFingerprint(appId: appId))?.fingerprint
            }
        }

        guard let baseline else {
            FileHandle.standardError.write(Data(
                "\n[fingerprint gate] No baseline available (pass --fingerprint-baseline or set app_id + backend). Skipping gate.\n".utf8))
            return
        }

        if snapshot.fingerprint == baseline {
            print("\n[fingerprint gate] ✓ native shell UNCHANGED (\(snapshot.fingerprint.prefix(12))…) — OTA-safe.")
        } else {
            FileHandle.standardError.write(Data("""

            [fingerprint gate] ✗ NATIVE SHELL CHANGED
              current:  \(snapshot.fingerprint)
              baseline: \(baseline)
            An OTA update is NOT compatible with installed apps. Ship via the App Store.

            """.utf8))
            throw ExitCode(1)
        }
    }

    /// The honest realized split outcome: how many `mixed` functions the
    /// FunctionSplitter can ACTUALLY decompose into compilable WASM fragments +
    /// a retained native shell. A `mixed` function only earns OTA credit if its
    /// split is real; the rest count as native. Per-file source is cached so a
    /// whole-corpus app stays well under the analyze time budget.
    struct Realized {
        var mixedTotal = 0
        var mixedSplit = 0         // mixed functions with a real split
        var fragments = 0          // total pure fragments emitted
        /// Mixed functions whose split carries ≥1 ABI-eligible (concrete-typed,
        /// genuinely WASM-EXECUTABLE) fragment. A generic (`_`-typed) fragment
        /// compiles but cannot cross the JSON ABI, so it never ships OTA. This is
        /// the *executable* realized rate (optimization-sweep headline metric).
        var abiSplits = 0
        var abiFragments = 0       // total ABI-eligible fragments emitted
        /// research/subtree-extraction: `native`-classified functions (never fed to
        /// the FunctionSplitter) from which the SubtreeExtractor lifted ≥1
        /// ABI-eligible pure sub-tree (incl. sub-trees inside nested closures). Each
        /// such function ships a real WASM fragment with its whole body kept in the
        /// native shell, so this is purely additive coverage.
        var subtreeSplits = 0          // native functions newly earning ≥1 ABI fragment
        var subtreeFragments = 0       // total ABI-eligible sub-tree fragments
        /// OTA% counting only realized splits (the honest headline).
        var otaPercent = 0.0
        /// OTA% counting only splits with an ABI-EXECUTABLE fragment — the
        /// genuinely-shippable number (a `_`-typed fragment compiles but cannot
        /// cross the JSON ABI, so it never ships OTA).
        var abiOtaPercent = 0.0
        /// Per-outcome tally (diagnostics).
        var outcomes: [FunctionSplitter.Outcome: Int] = [:]
    }

    private func computeRealized(_ report: CoverageReport) -> Realized {
        // Native-callee names so the splitter keeps calls to native helpers in
        // the shell (sound lifts under the native→mixed lever).
        //
        // The anchor set is the union of:
        //   • every `native`-classified function, AND
        //   • every function whose RECORD `forcesNative` (ObjC/selector/unsafe
        //     interop) — REGARDLESS of its final classification.
        // The second clause matters once the closure-forced-dependency boundary
        // widening reclassifies deep-forced-native helpers from `native` to
        // `mixed`: such a helper still performs un-liftable interop that must stay
        // in the shell, so it is still a valid split anchor. Without it, widening
        // the mixed set shrinks the anchor set and net-REDUCES realized splits
        // (the RxSwift coupling). Sound: a forced-native function's call is always
        // a legitimate native boundary to split around.
        var nativeCalleeNames: Set<String> = []
        func simpleName(_ id: String) -> String? {
            id.split(separator: ".").last.map(String.init)?
                .split(separator: "(").first.map(String.init)
        }
        for r in report.results where r.classification == .native {
            if let simple = simpleName(r.functionID) { nativeCalleeNames.insert(simple) }
        }
        for (id, record) in report.records where record.forcesNative {
            if let simple = simpleName(id) { nativeCalleeNames.insert(simple) }
        }
        // Also anchor on any function that carries a native hit even if it landed
        // `mixed` (the closure-forced-dependency widening reclassifies former
        // `native` helpers to `mixed`; their native touch is still a boundary a
        // caller must keep in the shell). Conservative: keeping a call in the
        // shell is always sound — it can only ever reduce fragments, never lift an
        // unsafe statement.
        for r in report.results where r.classification == .mixed && !r.nativeHits.isEmpty {
            if let simple = simpleName(r.functionID) { nativeCalleeNames.insert(simple) }
        }
        let splitter = FunctionSplitter(nativeCalleeNames: nativeCalleeNames)
        let mixed = report.results.filter { $0.classification == .mixed }
        // Group mixed functions by source file and parse each file's tree ONCE.
        var byFile: [URL: [String]] = [:]
        for r in mixed {
            guard let record = report.records[r.functionID] else { continue }
            byFile[record.sourceFile, default: []].append(r.functionID)
        }
        var out = Realized()
        out.mixedTotal = mixed.count
        for (file, ids) in byFile {
            guard let s = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Parse + index each file ONCE; reuse the index across all its mixed
            // functions (keeps giant files inside the analyze time budget).
            let tree = SwiftParser.Parser.parse(source: s)
            let index = DeclarationIndex(tree: tree)
            for id in ids {
                guard let record = report.records[id] else { continue }
                var outcome: FunctionSplitter.Outcome = .noBody
                let plan = splitter.plan(for: record, index: index,
                                         inferredTypes: report.inferredTypes[id] ?? [:],
                                         outcome: &outcome)
                out.outcomes[outcome, default: 0] += 1
                if let plan, !plan.pureFragments.isEmpty, !plan.nativeStatementsSummary.isEmpty {
                    out.mixedSplit += 1
                    out.fragments += plan.pureFragments.count
                    let emitter = CodeEmitter()
                    let abiFrags = plan.pureFragments.filter { emitter.isABIEligible($0) }
                    if !abiFrags.isEmpty {
                        out.abiSplits += 1
                        out.abiFragments += abiFrags.count
                    }
                }
            }
        }
        // ---- research/subtree-extraction: native-body + closure sub-tree pass ----
        // Feed every `native`-classified function (NEVER handed to the splitter
        // today) to the SubtreeExtractor. It recursively walks the whole body,
        // INCLUDING nested closure literals, and lifts the maximal pure sub-trees
        // (predicates, layout math, version strings, pure `combineLatest`/`map`
        // transforms) into WASM fragments, leaving the entire body in the native
        // shell. A native function earns OTA credit only when ≥1 ABI-EXECUTABLE
        // fragment is produced. Purely additive: the native shell is unchanged, so
        // the fingerprint gate is unaffected and correctness cannot regress.
        let extractor = SubtreeExtractor(registry: NativeRegistry.standard,
                                         nativeCalleeNames: nativeCalleeNames)
        let nativeResults = report.results.filter { $0.classification == .native }
        var nativeByFile: [URL: [String]] = [:]
        for r in nativeResults {
            guard let record = report.records[r.functionID] else { continue }
            nativeByFile[record.sourceFile, default: []].append(r.functionID)
        }
        let emitter = CodeEmitter()
        for (file, ids) in nativeByFile {
            guard let s = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let tree = SwiftParser.Parser.parse(source: s)
            let index = DeclarationIndex(tree: tree)
            // DEEP (wave2/subtree-deep): per-file ABI-typed property index (shape C).
            let propertyIndex = TypePropertyIndex(tree: tree)
            for id in ids {
                guard let record = report.records[id] else { continue }
                let res = extractor.extract(from: record, index: index, tree: tree,
                                            inferredTypes: report.inferredTypes[id] ?? [:],
                                            propertyIndex: propertyIndex)
                guard let plan = res.plan else { continue }
                let abiFrags = plan.pureFragments.filter { emitter.isABIEligible($0) }
                if !abiFrags.isEmpty {
                    out.subtreeSplits += 1
                    out.subtreeFragments += abiFrags.count
                }
            }
        }

        // Realized OTA = wasmEligible + bridged + mixed splits + native sub-tree
        // splits (each a function that previously shipped 0% OTA).
        let otaRealized = report.count(.wasmEligible) + report.count(.bridged)
            + out.mixedSplit + out.subtreeSplits
        out.otaPercent = report.functionCount > 0
            ? Double(otaRealized) / Double(report.functionCount) * 100 : 0
        // ABI-executable OTA%: only mixed splits with a concrete-typed (genuinely
        // WASM-executable) fragment count toward shippable OTA. wasmEligible +
        // bridged are already executable; abiSplits is the executable mixed subset;
        // subtreeSplits are ABI-executable by construction (filtered above).
        let otaABI = report.count(.wasmEligible) + report.count(.bridged)
            + out.abiSplits + out.subtreeSplits
        out.abiOtaPercent = report.functionCount > 0
            ? Double(otaABI) / Double(report.functionCount) * 100 : 0
        return out
    }

    // MARK: - Text report (matches the plan's "Patch Build Report")

    private func printText(_ report: CoverageReport, realized: Realized?) {
        let registrySize = NativeRegistry.standard.count
        var out = ""
        out += "Patch Build Report\n"
        out += "=======================\n"
        out += "Files parsed:                    \(report.fileCount)\n"
        out += "Total functions analyzed:        \(report.functionCount)\n"
        out += "Call-graph edges:                \(report.edgeCount)\n"
        out += "Native API registry entries:     \(registrySize)\n"
        out += "\n"
        out += line("WASM-eligible (pure)", report.count(.wasmEligible), report.functionCount)
        out += line("WASM-eligible (bridged)", report.count(.bridged), report.functionCount)
        out += line("Mixed (auto-split candidate)", report.count(.mixed), report.functionCount)
        out += line("Native (stays in shell)", report.count(.native), report.functionCount)
        out += "\n"
        if let realized {
            // Honest headline: only mixed functions that ACTUALLY split earn OTA.
            out += String(format: "OTA-updatable code (realized):   %.1f%%\n", realized.otaPercent)
            out += String(format: "  of %d mixed, %d split into %d WASM fragments (%.1f%% realize)\n",
                          realized.mixedTotal, realized.mixedSplit, realized.fragments,
                          realized.mixedTotal > 0 ? Double(realized.mixedSplit) / Double(realized.mixedTotal) * 100 : 0)
            out += String(format: "  of those, %d carry an ABI-EXECUTABLE fragment (%.1f%% of mixed) — %d ABI fragments\n",
                          realized.abiSplits,
                          realized.mixedTotal > 0 ? Double(realized.abiSplits) / Double(realized.mixedTotal) * 100 : 0,
                          realized.abiFragments)
            if realized.subtreeSplits > 0 {
                out += String(format: "  + %d native functions ship ≥1 pure sub-tree fragment (%d ABI sub-tree fragments)\n",
                              realized.subtreeSplits, realized.subtreeFragments)
            }
            // The genuinely-shippable headline: only mixed functions whose split
            // carries an ABI-EXECUTABLE (concrete-typed) fragment earn OTA credit.
            // A `_`-typed fragment compiles but cannot cross the JSON ABI boundary,
            // so it never ships OTA. This is the honest "what actually runs OTA" %.
            out += String(format: "OTA-updatable code (ABI-executable):   %.1f%%\n", realized.abiOtaPercent)
            out += String(format: "OTA-updatable (optimistic, all mixed): %.1f%%\n", report.otaUpdatablePercent)
            if splitDiagnostics {
                out += "\nSplit-outcome breakdown (mixed functions):\n"
                let order: [(FunctionSplitter.Outcome, String)] = [
                    (.splitA, "realized: Strategy A (statement runs)"),
                    (.splitSubExpr, "realized: sub-expression lift"),
                    (.splitGuard, "realized: guard/conditional lift"),
                    (.splitSwitch, "realized: switch/branch value lift"),
                    (.controlFlowOnly, "unrealized: control-flow only (no liftable cond/expr)"),
                    (.noPureRun, "unrealized: no liftable pure work"),
                    (.noNativeRun, "unrealized: no native statement"),
                    (.noBody, "unrealized: body not found"),
                    (.emptyBody, "unrealized: empty body"),
                    (.noLiveThreading, "unrealized: threading unprovable"),
                ]
                for (oc, label) in order {
                    if let n = realized.outcomes[oc], n > 0 {
                        out += "  \(String(n).padding(toLength: 7, withPad: " ", startingAt: 0)) \(label)\n"
                    }
                }
            }
        } else {
            out += String(format: "OTA-updatable code (optimistic): %.1f%%\n", report.otaUpdatablePercent)
        }

        if !report.perCategoryNativeHits.isEmpty {
            out += "\nNative usage by category:\n"
            for category in NativeCategory.allCases {
                if let n = report.perCategoryNativeHits[category], n > 0 {
                    out += "  \(category.rawValue.padding(toLength: 26, withPad: " ", startingAt: 0)) \(n)\n"
                }
            }
        }

        // Top reasons that pulled functions native (diagnostic lever-finder).
        let nativeResults = report.results.filter { $0.classification == .native }
        if !nativeResults.isEmpty {
            var reasonCounts: [String: Int] = [:]
            for r in nativeResults {
                // Bucket the *last* (decisive) reason, normalised.
                let key = normalizeReason(r.reasons.last ?? "unknown")
                reasonCounts[key, default: 0] += 1
            }
            out += "\nTop reasons functions stay native:\n"
            for (reason, n) in reasonCounts.sorted(by: { $0.value > $1.value }).prefix(8) {
                out += "  \(String(n).padding(toLength: 7, withPad: " ", startingAt: 0)) \(reason)\n"
            }
        }

        if verbose {
            out += "\nPer-function classification:\n"
            for r in report.results {
                let tag = r.classification.rawValue
                let why = r.reasons.last.map { " — \($0)" } ?? ""
                out += "  \(tag.padding(toLength: 14, withPad: " ", startingAt: 0)) \(r.functionID)\(why)\n"
            }
        }

        print(out, terminator: "")
    }

    /// Collapse a per-function reason into a bucket key by stripping the
    /// function-specific id prefix and quoted property names.
    private func normalizeReason(_ reason: String) -> String {
        var r = reason
        if let colon = r.firstIndex(of: ":"), r[..<colon].contains(".") {
            r = String(r[r.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        // Drop quoted identifiers (property names) so they bucket together.
        while let open = r.firstIndex(of: "'"),
              let close = r[r.index(after: open)...].firstIndex(of: "'") {
            r.replaceSubrange(open...close, with: "'…'")
        }
        return r
    }

    private func line(_ label: String, _ count: Int, _ total: Int) -> String {
        let pct = total > 0 ? (Double(count) / Double(total)) * 100.0 : 0
        let labelPad = label.padding(toLength: 30, withPad: " ", startingAt: 0)
        return String(format: "  %@ %4d  (%.1f%%)\n", labelPad, count, pct)
    }

    // MARK: - JSON report (--format json)

    private func printJSON(_ report: CoverageReport, realized: Realized?) {
        // Build the typed, Encodable payload and emit it via JSONEncoder so the
        // output is valid by construction (the old hand-assembled `[String: Any]`
        // could not be type-checked and risked invalid JSON). Field names match
        // the previous emitter so existing consumers/CI keep parsing.
        let metrics = realized.map {
            CoverageReport.RealizedMetrics(
                otaPercent: $0.otaPercent,
                abiOtaPercent: $0.abiOtaPercent,
                mixedSplit: $0.mixedSplit,
                fragments: $0.fragments,
                abiSplits: $0.abiSplits,
                abiFragments: $0.abiFragments,
                subtreeSplits: $0.subtreeSplits,
                subtreeFragments: $0.subtreeFragments)
        }
        let payload = report.jsonReport(realized: metrics)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
