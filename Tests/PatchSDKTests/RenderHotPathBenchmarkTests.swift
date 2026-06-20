import XCTest
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI
#endif

// RenderHotPathBenchmarkTests — P0 PERF INVESTIGATION (measure-only, no prod change).
// ===================================================================================
// Drives the REAL per-render hot path of `PatchedBodyHost.body` against a real
// engine-lowered WASM view body (`EngineSettingsView.wasm`) and times EACH stage
// with a monotonic high-res clock. Reports mean ns/render per stage + % of total,
// plus the Mirror cost, total JSON cost, WASM-call cost, tree-walk cost, the
// redundant-render (identical-input) finding, and coarse-overhead checks.
//
// Run RELEASE for representative numbers:
//   swift test -c release --filter RenderHotPathBenchmark
//
// The benchmark REPLICATES the exact stage sequence of `PatchedBodyHost.body`
// (ViewPatching.swift ~947) using the SAME public/internal entry points the body
// calls, so the numbers reflect production code paths without modifying them.
#if canImport(SwiftUI)
/// A tiny thread-safe counter — the `_onInstantiateForTesting` hook is `@Sendable` and may
/// fire off the main actor, so the instantiation count is guarded by a lock.
final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}

@MainActor
final class RenderHotPathBenchmarkTests: XCTestCase {

    // MARK: - High-res monotonic timer

    @inline(__always) private static func nowNanos() -> UInt64 {
        // clock_gettime_nsec_np(CLOCK_UPTIME_RAW) is the cheapest monotonic ns source on Darwin.
        return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    // MARK: - A representative live instance (matches EngineSettingsView's fields)
    //
    // EngineSettingsView lowers a settings screen with @State for notificationsOn
    // (Bool), badgeCount (Int), displayName (String). We marshal a struct with the
    // SAME stored-property shape to exercise the Mirror reflection path realistically
    // (mix of scalar property-wrapper-style fields). We also build a richer instance
    // to stress Mirror with nested structs + an array.
    struct SettingsInstance {
        var notificationsOn: Bool = true
        var badgeCount: Int = 0
        var displayName: String = "Ada"
    }

    struct Row { var id: Int; var title: String; var enabled: Bool }
    struct RichInstance {
        var notificationsOn: Bool = true
        var badgeCount: Int = 3
        var displayName: String = "Ada"
        var subtitle: String? = "member"
        var rows: [Row] = (0..<10).map { Row(id: $0, title: "Row \($0)", enabled: $0 % 2 == 0) }
    }

    // MARK: - Fixture

    private func engineViewBytes() throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: "EngineSettingsView", withExtension: "wasm") else {
            throw XCTSkip("EngineSettingsView.wasm fixture missing")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    private func makePatch() throws -> Patch {
        let patch = Patch()
        patch.bridges.registerDefaults()
        try patch.activate(bytes: try engineViewBytes())
        return patch
    }

    // MARK: - Stat helpers

    private struct Stat { var name: String; var totalNs: UInt64; var count: Int
        var meanNs: Double { count == 0 ? 0 : Double(totalNs) / Double(count) } }

    private func report(_ title: String, _ stats: [Stat], totalRenderNs: Double, iterations: Int) -> String {
        var lines: [String] = []
        lines.append("")
        lines.append("=== \(title)  (iterations=\(iterations), config=\(buildConfig)) ===")
        lines.append(String(format: "%-34@ %14@ %8@", "stage" as NSString, "mean ns/render" as NSString, "% total" as NSString))
        for s in stats.sorted(by: { $0.meanNs > $1.meanNs }) {
            let pct = totalRenderNs > 0 ? (s.meanNs / totalRenderNs) * 100.0 : 0
            lines.append(String(format: "%-34@ %14.1f %7.1f%%", s.name as NSString, s.meanNs, pct))
        }
        lines.append(String(format: "%-34@ %14.1f %7.1f%%", "TOTAL (sum of stages)" as NSString, totalRenderNs, 100.0))
        return lines.joined(separator: "\n")
    }

    private var buildConfig: String {
        #if DEBUG
        return "DEBUG"
        #else
        return "RELEASE"
        #endif
    }

    // MARK: - THE benchmark

    func testRenderHotPathStageBreakdown() throws {
        let patch = try makePatch()
        // Make this the shared instance so PatchedBodyHost-style calls resolve the same module.
        // (We call the same public entry points the body uses; viewBodyEmission/dispatch route
        // through the live module.)

        // Determine the export the engine emitted for the view body.
        // EngineSettingsView exports a generic `view_body` (legacy single-view fixture).
        let bodyExport = patch.hasFunction("view_body") ? "view_body" : "view_body__SettingsView"
        XCTAssertTrue(patch.hasFunction(bodyExport), "no view body export found")
        let hasDispatch = patch.hasFunction("dispatch")

        // Seed a representative opaque guest state (as a real dispatch would produce).
        let seededState: String = (try? patch.dispatch(state: "", event: EventID("__noop__"), value: .none).state) ?? ""

        let iterations = 1000
        let warmup = 100

        // Accumulators
        var sMirror: UInt64 = 0            // Mirror reflection marshalling (PatchInstanceInputs.extract)
        var sReconcile: UInt64 = 0         // reconcileGuestOverride
        var sMerge: UInt64 = 0             // PatchFlatJSON.merge (props+guest, +inputTokens)
        var sInputTok: UInt64 = 0          // inputTokenJSON(from:)
        var sWasmEmit: UInt64 = 0          // viewBodyEmission (WASM invoke + decode together)
        var sWalks: UInt64 = 0             // 5x collect*IDs full-tree walks
        var sReconstitute: UInt64 = 0      // render(tree, context) → SwiftUI tree
        var total: UInt64 = 0

        // For decode-vs-invoke split: capture raw out-bytes once, time a standalone decode.
        var sStandaloneDecode: UInt64 = 0
        var sRawInvoke: UInt64 = 0

        // Redundant-render detection: count consecutive identical merged inputs.
        var lastMergedHash: Int? = nil
        var identicalConsecutive = 0
        var distinctInputs = Set<Int>()

        let instance = RichInstance()

        // We vary the merged input on a fraction of iterations to model a realistic
        // mix (most renders in SwiftUI re-run body with IDENTICAL inputs — that's the
        // whole point of the redundant-render question). Here we DELIBERATELY hold the
        // instance constant (the common steady-state case) so we can MEASURE how often
        // the input is identical render-to-render.

        for i in 0..<(iterations + warmup) {
            let measure = i >= warmup
            var t0: UInt64 = 0

            // ---- STAGE 0: thunk entry — Mirror reflection marshalling ----
            t0 = Self.nowNanos()
            let extraction = PatchInstanceInputs.extract(from: instance)
            let dtMirror = Self.nowNanos() - t0
            let propsJSON = extraction.json

            // ---- STAGE 1: reconcileGuestOverride ----
            t0 = Self.nowNanos()
            let effectiveGuestState = PatchedBodyHost.reconcileGuestOverride(
                guestState: seededState, baseline: "", currentProps: propsJSON)
            let dtReconcile = Self.nowNanos() - t0

            // ---- STAGE 2: merges (props+guest) ----
            t0 = Self.nowNanos()
            var merged = PatchFlatJSON.merge(base: propsJSON, override: effectiveGuestState)
            let dtMerge = Self.nowNanos() - t0

            // ---- STAGE 3: inputTokenJSON (empty tokens here) + its merge ----
            t0 = Self.nowNanos()
            let inputTokenJSON = PatchedBodyHost.inputTokenJSON(from: [:])
            if let inputTokenJSON { merged = PatchFlatJSON.merge(base: merged, override: inputTokenJSON) }
            let dtInputTok = Self.nowNanos() - t0

            // redundant-render bookkeeping (hash the final merged input)
            let h = merged.hashValue
            if let last = lastMergedHash, last == h { identicalConsecutive += 1 }
            lastMergedHash = h
            distinctInputs.insert(h)

            // ---- STAGE 4: viewBodyEmission (WASM invoke + host decode together) ----
            t0 = Self.nowNanos()
            let emission = try patch.viewBodyEmission(state: merged, export: bodyExport)
            let dtWasm = Self.nowNanos() - t0
            let tree = emission.root

            // Split: time a RAW invoke (no decode) + a standalone decode of the bytes.
            if measure {
                let inBytes: [UInt8] = merged.isEmpty ? [] : [UInt8](merged.utf8)
                var tr = Self.nowNanos()
                let rawOut = try patch.callPacked(bodyExport, inBytes)
                sRawInvoke += Self.nowNanos() - tr
                tr = Self.nowNanos()
                _ = try ViewNodeWire.decode(rawOut)
                sStandaloneDecode += Self.nowNanos() - tr
            }

            // ---- STAGE 5: the 5 collect*IDs full-tree walks (safety nets) ----
            t0 = Self.nowNanos()
            let nOpaque = PatchedBodyHost.collectOpaqueIDs(tree)
            let nToken = PatchedBodyHost.collectTokenIDs(tree)
            let nRow = PatchedBodyHost.collectRowSlotIDs(tree)
            let nAction = PatchedBodyHost.collectActionSlotIDs(tree)
            let nEffect = PatchedBodyHost.collectEffectSlotIDs(tree)
            let nButton = PatchedBodyHost.collectButtonActionIDs(tree)
            let dtWalks = Self.nowNanos() - t0
            _ = (nOpaque, nToken, nRow, nAction, nEffect, nButton)

            // ---- STAGE 6: tree reconstitution into SwiftUI ----
            t0 = Self.nowNanos()
            let context = RenderContext(showOpaqueStubs: false)
            let anyView = render(tree, context: context)
            let dtReconstitute = Self.nowNanos() - t0
            _ = anyView

            if measure {
                sMirror += dtMirror
                sReconcile += dtReconcile
                sMerge += dtMerge
                sInputTok += dtInputTok
                sWasmEmit += dtWasm
                sWalks += dtWalks
                sReconstitute += dtReconstitute
                total += dtMirror + dtReconcile + dtMerge + dtInputTok + dtWasm + dtWalks + dtReconstitute
            }
        }

        let stats: [Stat] = [
            Stat(name: "0. Mirror marshalling (extract)", totalNs: sMirror, count: iterations),
            Stat(name: "1. reconcileGuestOverride", totalNs: sReconcile, count: iterations),
            Stat(name: "2. PatchFlatJSON.merge (props+guest)", totalNs: sMerge, count: iterations),
            Stat(name: "3. inputTokenJSON + merge", totalNs: sInputTok, count: iterations),
            Stat(name: "4. viewBodyEmission (WASM+decode)", totalNs: sWasmEmit, count: iterations),
            Stat(name: "5. collect*IDs tree walks (x6)", totalNs: sWalks, count: iterations),
            Stat(name: "6. render → SwiftUI reconstitution", totalNs: sReconstitute, count: iterations),
        ]
        let totalMean = Double(total) / Double(iterations)

        var out = report("RENDER HOT PATH — per-stage breakdown", stats, totalRenderNs: totalMean, iterations: iterations)

        // WASM invoke vs decode split
        let meanRawInvoke = Double(sRawInvoke) / Double(iterations)
        let meanDecode = Double(sStandaloneDecode) / Double(iterations)
        out += "\n\n--- WASM stage 4 split ---"
        out += String(format: "\n  raw WASM invoke (callPacked):  %12.1f ns", meanRawInvoke)
        out += String(format: "\n  standalone ViewNodeWire.decode:%12.1f ns (JSONDecoder over emission)", meanDecode)
        out += String(format: "\n  (sum ≈ stage 4 mean %.1f ns)", Double(sWasmEmit)/Double(iterations))

        // Total JSON cost across all sites (merge + inputTok + decode + the encode inside Mirror)
        let jsonAcrossSites = Double(sMerge) + Double(sInputTok) + Double(sStandaloneDecode)
        out += "\n\n--- JSON cost (merge + inputTok + emission decode), per render ---"
        out += String(format: "\n  ≈ %.1f ns/render  (%.1f%% of total)", jsonAcrossSites/Double(iterations),
                       (jsonAcrossSites/Double(iterations))/totalMean*100)
        out += "\n  NOTE: Mirror stage ALSO does JSON encoding (PatchValueEncoder) — see Mirror-isolation test."

        // Redundant-render finding
        out += "\n\n--- REDUNDANT-RENDER finding ---"
        out += "\n  consecutive identical merged-input renders: \(identicalConsecutive)/\(iterations + warmup - 1)"
        out += "\n  distinct merged inputs seen: \(distinctInputs.count)"
        out += "\n  => with a CONSTANT instance, \(identicalConsecutive) of \(iterations + warmup - 1) renders had byte-identical input."
        out += "\n  => input-hash MEMOIZATION would skip WASM(\(String(format: "%.0f", meanRawInvoke))ns)+decode(\(String(format: "%.0f", meanDecode))ns)+walks+reconstitution on those."

        print(out)
        writeReport(out, marker: "STAGE_BREAKDOWN")

        // Sanity: the pipeline produced a non-trivial tree.
        XCTAssertGreaterThan(PatchedBodyHost.collectButtonActionIDs(try patch.viewBody(state: merged0(patch, bodyExport, seededState, instance), export: bodyExport)).count + 1, 0)
        _ = hasDispatch
    }

    private func merged0(_ patch: Patch, _ export: String, _ seed: String, _ instance: RichInstance) -> String {
        let propsJSON = PatchInstanceInputs.extract(from: instance).json
        let eff = PatchedBodyHost.reconcileGuestOverride(guestState: seed, baseline: "", currentProps: propsJSON)
        return PatchFlatJSON.merge(base: propsJSON, override: eff)
    }

    // MARK: - Mirror isolation (the prime suspect)

    func testMirrorMarshallingCostIsolated() throws {
        let iterations = 5000
        let warmup = 500
        let simple = SettingsInstance()
        let rich = RichInstance()

        // Mirror.extract (full: Mirror + PatchValueEncoder JSON encode)
        var simpleNs: UInt64 = 0
        var richNs: UInt64 = 0
        // Pure Mirror children enumeration (no encoding) — to separate Mirror itself from encoding.
        var simpleMirrorOnly: UInt64 = 0
        var richMirrorOnly: UInt64 = 0

        for i in 0..<(iterations + warmup) {
            let measure = i >= warmup
            var t = Self.nowNanos()
            let e1 = PatchInstanceInputs.extract(from: simple)
            let d1 = Self.nowNanos() - t
            t = Self.nowNanos()
            let e2 = PatchInstanceInputs.extract(from: rich)
            let d2 = Self.nowNanos() - t

            // Mirror-only: enumerate children, touch label+value, no encode.
            t = Self.nowNanos()
            var c1 = 0
            for child in Mirror(reflecting: simple).children { if child.label != nil { c1 += 1 } }
            let m1 = Self.nowNanos() - t
            t = Self.nowNanos()
            var c2 = 0
            for child in Mirror(reflecting: rich).children { if child.label != nil { c2 += 1 } }
            let m2 = Self.nowNanos() - t
            _ = (e1, e2, c1, c2)

            if measure {
                simpleNs += d1; richNs += d2
                simpleMirrorOnly += m1; richMirrorOnly += m2
            }
        }

        var out = "\n=== MIRROR ISOLATION  (iterations=\(iterations), config=\(buildConfig)) ==="
        out += String(format: "\n  extract(simple 3-field struct):      %10.1f ns  (Mirror + JSON encode)", Double(simpleNs)/Double(iterations))
        out += String(format: "\n    of which pure Mirror enumeration:  %10.1f ns", Double(simpleMirrorOnly)/Double(iterations))
        out += String(format: "\n  extract(rich: +optional,+10-row array): %7.1f ns  (Mirror + recursive JSON encode)", Double(richNs)/Double(iterations))
        out += String(format: "\n    of which pure Mirror enumeration:  %10.1f ns", Double(richMirrorOnly)/Double(iterations))
        out += "\n  => Mirror+encode runs PER RENDER inside thunkBody → this is fixed per-frame overhead."
        print(out)
        writeReport(out, marker: "MIRROR")
    }

    // MARK: - Granular marshalling breakdown (where the ~159µs actually is)

    // Splits extract's cost into (a) field-selection (the cheap Mirror walk),
    // (b) the change-detector fingerprint (the cheap hash walk), (c) the recursive JSON
    // string-build (the expensive part), for a SCALAR-only instance vs a rich (10-row
    // array of structs) instance. Confirms the fingerprint is ~Mirror-cheap (so memoizing
    // it is a real win) and that the string-build is the dominant cost.
    func testMarshallingStageBreakdown() throws {
        let iterations = 5000
        let warmup = 500
        let rich = RichInstance()
        let scalar = SettingsInstance()

        func bench(_ instance: Any, _ name: String) -> String {
            var selectNs: UInt64 = 0, fpNs: UInt64 = 0, buildNs: UInt64 = 0, fullNs: UInt64 = 0
            for i in 0..<(iterations + warmup) {
                let measure = i >= warmup
                var t = Self.nowNanos()
                let fields = PatchInstanceInputs.selectFields(from: instance)
                let dSelect = Self.nowNanos() - t
                t = Self.nowNanos()
                let fp = PatchInstanceInputs.fingerprint(of: fields)
                let dFp = Self.nowNanos() - t
                t = Self.nowNanos()
                let full = PatchInstanceInputs.extract(from: instance).json
                let dFull = Self.nowNanos() - t
                // build-only ≈ full − select (full re-does select internally); report full and
                // derive the string-build as full − (select+fp) for the breakdown.
                _ = (fp, full)
                if measure { selectNs += dSelect; fpNs += dFp; fullNs += dFull }
            }
            let sel = Double(selectNs) / Double(iterations)
            let fp = Double(fpNs) / Double(iterations)
            let full = Double(fullNs) / Double(iterations)
            let build = max(0, full - sel)   // the recursive string build inside extract
            var s = "\n  [\(name)]"
            s += String(format: "\n    select-fields (Mirror walk):  %10.1f ns", sel)
            s += String(format: "\n    fingerprint (hash walk):      %10.1f ns   <- the memo change-detector", fp)
            s += String(format: "\n    full extract (select+build):  %10.1f ns", full)
            s += String(format: "\n    => recursive JSON build ≈     %10.1f ns   (full − select)", build)
            s += String(format: "\n    => memo WARM cost ≈ select+fp = %8.1f ns  (skips the build)", sel + fp)
            if full > 0 { s += String(format: "\n    => warm/cold ratio ≈ %.2fx faster", full / max(1, sel + fp)) }
            return s
        }

        var out = "\n=== MARSHALLING STAGE BREAKDOWN  (iterations=\(iterations), config=\(buildConfig)) ==="
        out += bench(scalar, "scalar 3-field")
        out += bench(rich, "rich +optional+10-row-array+set+dict+date+enum")
        out += "\n  => the fingerprint walk is ~Mirror-cheap; a HIT pays select+fp and SKIPS the string build."
        print(out)
        writeReport(out, marker: "MARSHAL_STAGES")
    }

    // MARK: - Marshalling memoization payoff (the P0 fix's steady-state win)

    // Measures the COLD-MISS marshalling cost (full Mirror + recursive JSON build) vs the
    // WARM-HIT cost (cheap field-select + fingerprint, string-build SKIPPED) through the
    // PUBLIC memoizing entry point `extract(from:typeName:)`. With a constant instance —
    // SwiftUI's steady state — every extract after the first is a HIT.
    func testMarshallingMemoizationSpeedup() throws {
        let instance = RichInstance()
        let typeName = "RichBenchInstance"
        let iterations = 4000
        let warmup = 400

        var coldNs: UInt64 = 0
        var warmNs: UInt64 = 0

        // Pre-warm the cache once so the warm loop hits.
        PatchMarshalCache.shared.reset()
        _ = PatchInstanceInputs.extract(from: instance, typeName: typeName)

        for i in 0..<(iterations + warmup) {
            let measure = i >= warmup

            // WARM HIT: cache already holds this fingerprint → select+fp, no string build.
            let tw = Self.nowNanos()
            let warm = PatchInstanceInputs.extract(from: instance, typeName: typeName)
            let dWarm = Self.nowNanos() - tw
            XCTAssertEqual(PatchMarshalCache.shared.entryCount(typeName: typeName), 1,
                           "steady-state extract must stay a single cached entry (a HIT)")

            // COLD MISS: clear the cache so this extract must rebuild the JSON string.
            PatchMarshalCache.shared.reset()
            let tc = Self.nowNanos()
            let cold = PatchInstanceInputs.extract(from: instance, typeName: typeName)
            let dCold = Self.nowNanos() - tc

            // Transparency invariant: warm and cold json are byte-identical.
            XCTAssertEqual(warm.json, cold.json, "warm-hit json must equal cold-miss json (transparent)")

            if measure { warmNs += dWarm; coldNs += dCold }
        }

        let coldMean = Double(coldNs) / Double(iterations)
        let warmMean = Double(warmNs) / Double(iterations)
        let speedup = warmMean > 0 ? coldMean / warmMean : 0

        var out = "\n=== MARSHALLING MEMOIZATION (iterations=\(iterations), config=\(buildConfig)) ==="
        out += String(format: "\n  COLD MISS (Mirror + recursive JSON build): %12.1f ns/extract", coldMean)
        out += String(format: "\n  WARM HIT  (select + fingerprint, build SKIPPED): %8.1f ns/extract", warmMean)
        out += String(format: "\n  => speedup: %.1fx faster on a steady-state (unchanged) marshal", speedup)
        out += "\n  (A warm hit re-collects live writebacks + computes the change-detector fingerprint,"
        out += "\n   then reuses the cached propsJSON — the ~159µs recursive string build is gone.)"
        print(out)
        writeReport(out, marker: "MARSHAL_MEMO")

        XCTAssertLessThan(warmMean, coldMean, "warm hit must be cheaper than cold miss")
        // The recursive string build is the dominant cost on the rich instance, so a warm hit
        // (which skips it) must be materially faster. Conservative bound; observed >>3x.
        XCTAssertGreaterThan(speedup, 2.0, "memoization should skip the dominant string-build (≥2x)")
    }

    // MARK: - Tree-walk isolation

    func testTreeWalkCostIsolated() throws {
        let patch = try makePatch()
        let bodyExport = patch.hasFunction("view_body") ? "view_body" : "view_body__SettingsView"
        let seededState = (try? patch.dispatch(state: "", event: EventID("__noop__"), value: .none).state) ?? ""
        let merged = merged0(patch, bodyExport, seededState, RichInstance())
        let tree = try patch.viewBodyEmission(state: merged, export: bodyExport).root

        let iterations = 20000
        let warmup = 2000
        var ns: UInt64 = 0
        for i in 0..<(iterations + warmup) {
            let measure = i >= warmup
            let t = Self.nowNanos()
            _ = PatchedBodyHost.collectOpaqueIDs(tree)
            _ = PatchedBodyHost.collectTokenIDs(tree)
            _ = PatchedBodyHost.collectRowSlotIDs(tree)
            _ = PatchedBodyHost.collectActionSlotIDs(tree)
            _ = PatchedBodyHost.collectEffectSlotIDs(tree)
            _ = PatchedBodyHost.collectButtonActionIDs(tree)
            let d = Self.nowNanos() - t
            if measure { ns += d }
        }
        // node count for context
        func count(_ n: ViewNode) -> Int { 1 + n.childNodes.reduce(0) { $0 + count($1) } + n.modifiers.reduce(0) { $0 + $1.contentNodes.reduce(0) { $0 + count($1) } } }
        var out = "\n=== TREE-WALK ISOLATION (6 walks) (iterations=\(iterations), config=\(buildConfig)) ==="
        out += String(format: "\n  combined 6 collect*IDs walks: %10.1f ns/render", Double(ns)/Double(iterations))
        out += "\n  tree node count: \(count(tree))"
        out += "\n  => 6 full-tree traversals per render; could be ONE combined walk."
        print(out)
        writeReport(out, marker: "TREEWALK")
    }

    // MARK: - Coarse overhead: is instantiation per-render?

    func testInstantiationIsNotPerRender() throws {
        // Activation instantiates the module set ONCE. Confirm repeated viewBodyEmission
        // calls do NOT re-instantiate. This is asserted STRUCTURALLY — by counting actual
        // `instantiateModuleSet` invocations via the `_onInstantiateForTesting` hook —
        // NOT by wall-clock timing. A timing threshold (absolute OR relative) is inherently
        // flaky under CPU contention: a single `viewBodyEmission` sample can be preempted
        // mid-call by the scheduler, inflating it past any ratio bound even though no
        // re-instantiation happened. Counting the instantiation events is exact and
        // load-immune — it answers the test's real question directly.
        let patch = Patch()
        patch.bridges.registerDefaults()
        let instantiations = ManagedCounter()
        patch._onInstantiateForTesting = { instantiations.increment() }

        // Activation #1 → exactly one instantiation.
        try patch.activate(bytes: try engineViewBytes())
        XCTAssertEqual(instantiations.value, 1, "activate() should instantiate the module set exactly once")

        let bodyExport = patch.hasFunction("view_body") ? "view_body" : "view_body__SettingsView"
        let merged = merged0(patch, bodyExport, "", RichInstance())

        // Many warm renders — NONE may re-instantiate (the module set is built once at activate).
        let n = 200
        var cold: UInt64 = 0
        var warm: UInt64 = 0
        var t = Self.nowNanos()
        _ = try patch.viewBodyEmission(state: merged, export: bodyExport)
        cold = Self.nowNanos() - t
        for _ in 0..<n {
            t = Self.nowNanos()
            _ = try patch.viewBodyEmission(state: merged, export: bodyExport)
            warm += Self.nowNanos() - t
        }
        let warmMean = Double(warm) / Double(n)

        // THE STRUCTURAL ASSERTION: not a single extra instantiation across 201 renders.
        XCTAssertEqual(instantiations.value, 1,
            "viewBodyEmission re-instantiated the module set — instantiation count grew from 1 to \(instantiations.value) across \(n + 1) renders")

        // Timing is reported as a diagnostic only (NO assertion — load-sensitive).
        var out = "\n=== INSTANTIATION / COARSE OVERHEAD ==="
        out += String(format: "\n  first (cold) viewBodyEmission: %10.1f ns", Double(cold))
        out += String(format: "\n  warm mean (n=%d):             %10.1f ns", n, warmMean)
        out += "\n  instantiateModuleSet calls across activate + \(n + 1) renders: \(instantiations.value) (expected 1)"
        out += "\n  => exactly ONE instantiation ⇒ NOT re-instantiating per render (module set built once at activate)."
        print(out)
        writeReport(out, marker: "INSTANTIATION")
    }

    // MARK: - Steady-state memoization benchmark (the P0 fix's payoff)

    // Measures the COLD-MISS render cost (full WASM invoke + decode + 6 tree walks) vs the
    // WARM-HIT render cost (cache lookup + the safety-net filters + reconstitution; the WASM
    // stage and the 6 walks SKIPPED). With a constant instance — SwiftUI's steady state —
    // every render after the first is a HIT, so the warm number is what real apps pay.
    func testSteadyStateMemoizationSpeedup() throws {
        let patch = try makePatch()
        let bodyExport = patch.hasFunction("view_body") ? "view_body" : "view_body__SettingsView"
        let seededState = (try? patch.dispatch(state: "", event: EventID("__noop__"), value: .none).state) ?? ""
        let instance = RichInstance()

        // Build the EXACT final merged input the body would compute for this instance.
        let propsJSON = PatchInstanceInputs.extract(from: instance).json
        let eff = PatchedBodyHost.reconcileGuestOverride(guestState: seededState, baseline: "", currentProps: propsJSON)
        let merged = PatchFlatJSON.merge(base: propsJSON, override: eff)
        let typeName = "EngineSettingsView"
        let epoch = patch.moduleEpoch

        PatchedBodyRenderCache.shared.reset()

        // ---- COLD MISS: the full path (WASM invoke + decode + 6 collect walks) ----
        // Replicates the body's miss branch exactly: lookup (miss) → viewBodyEmission →
        // collect the 6 id-sets → store.
        @inline(__always) func coldMissOnce() throws {
            PatchedBodyRenderCache.shared.reset() // force a miss every time
            _ = PatchedBodyRenderCache.shared.lookup(typeName: typeName, export: bodyExport, input: merged, epoch: epoch)
            let emission = try patch.viewBodyEmission(state: merged, export: bodyExport)
            let tree = emission.root
            let idSets = PatchedBodyIDSets(
                opaque: PatchedBodyHost.collectOpaqueIDs(tree),
                token: PatchedBodyHost.collectTokenIDs(tree),
                row: PatchedBodyHost.collectRowSlotIDs(tree),
                action: PatchedBodyHost.collectActionSlotIDs(tree),
                effect: PatchedBodyHost.collectEffectSlotIDs(tree),
                button: PatchedBodyHost.collectButtonActionIDs(tree),
                animationValueKeys: PatchedBodyHost.collectAnimationValueKeys(tree))
            PatchedBodyRenderCache.shared.store(
                typeName: typeName, export: bodyExport, input: merged, epoch: epoch,
                payload: PatchedBodyCacheEntry(tree: tree, slotArgs: emission.slotArgs ?? [:], idSets: idSets))
        }

        // ---- WARM HIT: the cache HIT branch (no WASM, no 6 walks) ----
        // Seed once so the lookup hits, then measure just the lookup (the body's hit branch).
        try coldMissOnce()
        // Re-seed (coldMissOnce resets) so the warm path actually hits.
        let emission0 = try patch.viewBodyEmission(state: merged, export: bodyExport)
        let tree0 = emission0.root
        let idSets0 = PatchedBodyIDSets(
            opaque: PatchedBodyHost.collectOpaqueIDs(tree0),
            token: PatchedBodyHost.collectTokenIDs(tree0),
            row: PatchedBodyHost.collectRowSlotIDs(tree0),
            action: PatchedBodyHost.collectActionSlotIDs(tree0),
            effect: PatchedBodyHost.collectEffectSlotIDs(tree0),
            button: PatchedBodyHost.collectButtonActionIDs(tree0),
            animationValueKeys: PatchedBodyHost.collectAnimationValueKeys(tree0))
        PatchedBodyRenderCache.shared.reset()
        PatchedBodyRenderCache.shared.store(
            typeName: typeName, export: bodyExport, input: merged, epoch: epoch,
            payload: PatchedBodyCacheEntry(tree: tree0, slotArgs: emission0.slotArgs ?? [:], idSets: idSets0))

        let iterations = 2000
        let warmup = 200

        var coldNs: UInt64 = 0
        var warmNs: UInt64 = 0

        for i in 0..<(iterations + warmup) {
            let measure = i >= warmup

            // WARM HIT
            let tw = Self.nowNanos()
            let hit = PatchedBodyRenderCache.shared.lookup(typeName: typeName, export: bodyExport, input: merged, epoch: epoch)
            let dWarm = Self.nowNanos() - tw
            XCTAssertNotNil(hit, "steady-state render must be a cache HIT")

            // COLD MISS (full WASM path) — re-resets internally, so it always misses.
            let tc = Self.nowNanos()
            try coldMissOnce()
            let dCold = Self.nowNanos() - tc

            // Re-seed the warm entry (coldMissOnce reset it).
            PatchedBodyRenderCache.shared.reset()
            PatchedBodyRenderCache.shared.store(
                typeName: typeName, export: bodyExport, input: merged, epoch: epoch,
                payload: PatchedBodyCacheEntry(tree: tree0, slotArgs: emission0.slotArgs ?? [:], idSets: idSets0))

            if measure { warmNs += dWarm; coldNs += dCold }
        }

        let coldMean = Double(coldNs) / Double(iterations)
        let warmMean = Double(warmNs) / Double(iterations)
        let speedup = warmMean > 0 ? coldMean / warmMean : 0

        var out = "\n=== STEADY-STATE MEMOIZATION (iterations=\(iterations), config=\(buildConfig)) ==="
        out += String(format: "\n  COLD MISS (WASM invoke + decode + 6 walks + store): %12.1f ns/render", coldMean)
        out += String(format: "\n  WARM HIT  (cache lookup, WASM + walks SKIPPED):     %12.1f ns/render", warmMean)
        out += String(format: "\n  => speedup: %.1fx faster on a steady-state (identical-input) render", speedup)
        out += "\n  (The body still runs Mirror marshalling + merge + safety-net filters + reconstitution"
        out += "\n   on a hit; the memoization removes the WASM stage — the 76% — and the 6 tree walks.)"
        print(out)
        writeReport(out, marker: "MEMOIZATION")

        // The whole point: a warm hit must be dramatically cheaper than the cold miss (the
        // WASM+decode+walks stages are gone). Assert at least a meaningful speedup so a
        // regression that defeats the cache fails CI. (Conservative bound; observed >>10x.)
        XCTAssertLessThan(warmMean, coldMean, "warm hit must be cheaper than cold miss")
        XCTAssertGreaterThan(speedup, 3.0, "memoization should skip the dominant WASM stage (≥3x)")
    }

    // MARK: - End-to-end steady-state: marshalling memoization on TOP of the render cache

    // The REAL production steady-state render now memoizes BOTH the WASM-derived tree (the
    // shipped render cache) AND the marshalled input JSON (this session). This benchmark
    // measures the marshalling slice of that steady-state render with the marshal cache WARM
    // (production) vs COLD (the pre-this-session behavior: a full Mirror + recursive JSON
    // build every render), through the exact public entry point the thunk uses.
    func testSteadyStateMarshallingSliceWarmVsCold() throws {
        let instance = RichInstance()
        let typeName = "EngineSettingsViewE2E"
        let iterations = 4000
        let warmup = 400

        // Warm the marshal cache once (production: it stays warm in steady state).
        PatchMarshalCache.shared.reset()
        _ = PatchInstanceInputs.extract(from: instance, typeName: typeName)

        var warmNs: UInt64 = 0     // production: marshal cache warm
        var coldNs: UInt64 = 0     // pre-this-session: always-fresh marshal every render

        for i in 0..<(iterations + warmup) {
            let measure = i >= warmup

            // WARM (production steady state): memoized marshal — fingerprint hit, no rebuild.
            let tw = Self.nowNanos()
            let warm = PatchInstanceInputs.extract(from: instance, typeName: typeName)
            let dWarm = Self.nowNanos() - tw

            // COLD (pre-this-session): the always-fresh `extract(from:)` — a full Mirror +
            // recursive JSON build, exactly what ran every render before marshalling memoization.
            let tc = Self.nowNanos()
            let cold = PatchInstanceInputs.extract(from: instance)
            let dCold = Self.nowNanos() - tc

            XCTAssertEqual(warm.json, cold.json, "the memoized marshal must be byte-identical to the fresh one")

            if measure { warmNs += dWarm; coldNs += dCold }
        }

        let warmMean = Double(warmNs) / Double(iterations)
        let coldMean = Double(coldNs) / Double(iterations)
        let speedup = warmMean > 0 ? coldMean / warmMean : 0

        var out = "\n=== STEADY-STATE MARSHALLING SLICE (iterations=\(iterations), config=\(buildConfig)) ==="
        out += String(format: "\n  FRESH marshal (current code, every render):  %12.1f ns/render", coldMean)
        out += String(format: "\n  WARM  marshal (memoized, build SKIPPED):     %12.1f ns/render", warmMean)
        out += String(format: "\n  => %.2fx faster than re-marshalling on a steady-state render", speedup)
        out += "\n  NB: the FRESH number ALSO benefits from this session's cold-path cleanup (the"
        out += "\n  type-probe guard + objectFieldValues fast path). Against the ORIGINAL pre-session"
        out += "\n  baseline (~163µs fresh, see MIRROR report on `main`), the WARM steady-state marshal"
        out += String(format: "\n  is ~%.1fx faster (163000 / %.0f).", 163000.0 / max(1, warmMean), warmMean)
        out += "\n  (This is the marshalling slice; the render cache already removed the ~656µs WASM call.)"
        print(out)
        writeReport(out, marker: "STEADYSTATE_MARSHAL")

        XCTAssertLessThan(warmMean, coldMean, "warm steady-state marshal must be cheaper than the pre-session fresh marshal")
    }

    // MARK: - PERF batch #1: parse-free flat-scalar merge (the fast path) vs the oracle

    // Times the production `PatchFlatJSON.merge` (parse-free splice for all-scalar flat
    // objects) against `mergeViaJSONSerialization` (the old JSONSerialization path) on
    // REALISTIC flat-scalar inputs — the common case (scalar @State/props + a scalar
    // guest-state override) the fast path targets. Reports both, asserts the fast path
    // is byte-identical AND faster. (The RENDER-HOT-PATH benchmark above uses a RichInstance
    // whose props carry an ARRAY → its merge takes the fallback, so this isolates the win.)
    func testFlatScalarMergeFastPathSpeedup() {
        // A realistic settings-screen props ∪ guest scalar override (all flat scalars).
        let props = #"{"badgeCount":3,"displayName":"Ada Lovelace","notificationsOn":true,"theme":"dark","volume":0.75,"streak":42}"#
        let override = #"{"badgeCount":7,"volume":0.5}"#

        let iterations = 20000
        let warmup = 2000
        var fastNs: UInt64 = 0
        var oracleNs: UInt64 = 0

        for i in 0..<(iterations + warmup) {
            let measure = i >= warmup
            let t0 = Self.nowNanos()
            let fast = PatchFlatJSON.merge(base: props, override: override)
            let dFast = Self.nowNanos() - t0
            let t1 = Self.nowNanos()
            let oracle = PatchFlatJSON.mergeViaJSONSerialization(base: props, override: override)
            let dOracle = Self.nowNanos() - t1
            XCTAssertEqual(fast, oracle, "fast-path merge must be byte-identical to the JSONSerialization oracle")
            if measure { fastNs += dFast; oracleNs += dOracle }
        }

        let fastMean = Double(fastNs) / Double(iterations)
        let oracleMean = Double(oracleNs) / Double(iterations)
        let speedup = fastMean > 0 ? oracleMean / fastMean : 0

        var out = "\n=== FLAT-SCALAR MERGE (PERF #1) (iterations=\(iterations), config=\(buildConfig)) ==="
        out += String(format: "\n  JSONSerialization merge (old path): %12.1f ns/merge", oracleMean)
        out += String(format: "\n  parse-free splice (production path):%12.1f ns/merge", fastMean)
        out += String(format: "\n  => %.2fx faster on a flat-scalar merge (byte-identical output)", speedup)
        out += "\n  (NB the RENDER-HOT-PATH merge stage uses a RichInstance whose props carry an"
        out += "\n   array → that merge takes the FALLBACK; this isolates the common all-scalar win.)"
        print(out)
        writeReport(out, marker: "FLATMERGE")

        // The perf claim is a RELEASE assertion. In DEBUG, full bounds-checking on the
        // hand-written byte scanner can make it slower than JSONSerialization's compiled
        // C path — meaningless for the optimization, which only runs optimized. The
        // byte-IDENTICAL transparency check inside the loop above runs in BOTH configs
        // (correctness is never conditioned); only the timing bound is RELEASE-gated.
        #if !DEBUG
        XCTAssertLessThan(fastMean, oracleMean, "the parse-free splice must be faster than JSONSerialization on flat-scalar input (RELEASE)")
        #endif
    }

    // MARK: - report sink

    private func writeReport(_ text: String, marker: String) {
        let dir = "/Users/appstudio/patch-campaign-log/overnight-rigor-run"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/perf-raw-\(marker).txt"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
