// SPDX-License-Identifier: MIT

import XCTest
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI
#endif

// RealisticFrameBenchmarkTests — V4 FRAME-LEVEL BENCHMARK
// =========================================================
// Simulates a realistic "Feed Screen" with 5 OTA-patched views rendering
// over a scripted interaction, measuring the real WASM render pipeline
// (marshal → merge → WASM/cache → reconstitute) per view per frame.
//
// Run RELEASE for representative numbers:
//   export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"; hash -r
//   swift test -c release --filter RealisticFrameBenchmark

#if canImport(SwiftUI)
@MainActor
final class RealisticFrameBenchmarkTests: XCTestCase {

    // -------------------------------------------------------------------------
    // MARK: - Helpers
    // -------------------------------------------------------------------------

    @inline(__always) private static func nowNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private var buildConfig: String {
        #if DEBUG
        return "DEBUG"
        #else
        return "RELEASE"
        #endif
    }

    // Accumulator for per-phase timing.
    private struct PA {
        var total: UInt64 = 0; var n: Int = 0
        var lo: UInt64 = .max; var hi: UInt64 = 0
        mutating func add(_ ns: UInt64) {
            total += ns; n += 1
            if ns < lo { lo = ns }; if ns > hi { hi = ns }
        }
        var mean: Double { n == 0 ? 0 : Double(total)/Double(n) }
        var us: Double { mean/1_000 }; var ms: Double { mean/1_000_000 }
    }

    private func pct(_ samples: [UInt64], _ p: Double) -> UInt64 {
        guard !samples.isEmpty else { return 0 }
        let s = samples.sorted()
        return s[max(0, min(s.count-1, Int(Double(s.count-1)*p/100)))]
    }

    private func engineViewBytes() throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: "EngineSettingsView", withExtension: "wasm") else {
            throw XCTSkip("EngineSettingsView.wasm fixture missing")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    private func makePatch() throws -> Patch {
        let p = Patch(); p.bridges.registerDefaults(); try p.activate(bytes: try engineViewBytes()); return p
    }

    private func writeReport(_ text: String, marker: String) {
        let dir = BenchmarkOutput.directory("perf-deepdive")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/V4-frame-benchmark-raw-\(marker).txt"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print("[benchmark] report written to \(path)")
    }

    // ---- Shared state for the benchmark loop ---------------------------------
    // Stored as instance properties to avoid placing large arrays on the stack.

    private var _patch: Patch?
    private var _export: String = ""
    private var _epoch: UInt64 = 0
    private var _seededState: String = ""

    // Instance "snapshots" stored as [String: Any] JSON (pre-marshalled once per frame).
    // Rather than putting BenchRichInst/BenchHeaderInst on the stack in the hot function,
    // we just pass a pre-built JSON string to the pipeline.

    private var _headerJSON: String = ""
    private var _row0JSON: String = ""
    private var _row1JSON: String = ""
    private var _row2JSON: String = ""
    private var _collJSON: String = ""
    private var _headerIsExpanded: Bool = false
    private var _row0BadgeCount: Int = 3
    private var _collDisplayName: String = "Trending"

    private func buildHeaderJSON(_ isExpanded: Bool) -> String {
        let exp = isExpanded ? "true" : "false"
        return "{\"title\":\"Feed\",\"subtitle\":\"Latest\",\"unreadCount\":7,\"isExpanded\":\(exp),\"badgeColor\":\"red\"}"
    }

    private func buildRichJSON(notificationsOn: Bool, badgeCount: Int, displayName: String,
                                subtitle: String?, rowPrefix: String) -> String {
        let notif = notificationsOn ? "true" : "false"
        let subStr: String
        if let s = subtitle { subStr = "\"\(s)\"" } else { subStr = "null" }
        var rows = "["; var first = true
        for i in 0..<10 {
            if !first { rows += "," }; first = false
            let enabled = (i % 2 == 0) ? "true" : "false"
            rows += "{\"id\":\(i),\"title\":\"\(rowPrefix)\(i)\",\"enabled\":\(enabled)}"
        }
        rows += "]"
        return "{\"notificationsOn\":\(notif),\"badgeCount\":\(badgeCount),\"displayName\":\"\(displayName)\",\"subtitle\":\(subStr),\"rows\":\(rows)}"
    }

    // ---- Single-view pipeline (called for each of the 5 views per frame) ----

    private struct VResult {
        var dtMarshal: UInt64; var dtMerge: UInt64; var dtWasm: UInt64
        var dtIdW: UInt64; var dtRecon: UInt64; var hit: Bool
    }

    private func runView(typeName: String, propsJSON: String) throws -> VResult {
        guard let patch = _patch else { fatalError("patch not set up") }
        let export = _export; let epoch = _epoch

        // A. Marshal: no-op here since propsJSON is pre-built; we just time the merge prep.
        // (The "marshal" stage is the JSON build — here we measure it as zero since we
        //  pre-built above. The realistic marshal cost comes from the JSON-build benchmarks;
        //  here we focus on merge+WASM+reconstitute which are the dominant costs.)
        let t0 = Self.nowNanos()
        // Simulate a lightweight reconcile (what PatchedBodyHost does with guestState).
        let g = PatchedBodyHost.reconcileGuestOverride(guestState: _seededState, baseline: "", currentProps: propsJSON)
        let dtMarshal = Self.nowNanos() - t0

        let t1 = Self.nowNanos()
        var merged = PatchFlatJSON.merge(base: propsJSON, override: g)
        if let itj = PatchedBodyHost.inputTokenJSON(from: [:]) {
            merged = PatchFlatJSON.merge(base: merged, override: itj)
        }
        let dtMerge = Self.nowNanos() - t1

        let t2 = Self.nowNanos()
        if let h = PatchedBodyRenderCache.shared.lookup(typeName: typeName, export: export, input: merged, epoch: epoch) {
            let dtWasm = Self.nowNanos() - t2
            let t3 = Self.nowNanos()
            let dummy = h.idSets.opaque.count &+ h.idSets.token.count; _ = dummy
            let dtIdW = Self.nowNanos() - t3
            let t4 = Self.nowNanos()
            _ = render(h.tree, context: RenderContext(showOpaqueStubs: false))
            let dtRecon = Self.nowNanos() - t4
            return VResult(dtMarshal: dtMarshal, dtMerge: dtMerge, dtWasm: dtWasm,
                           dtIdW: dtIdW, dtRecon: dtRecon, hit: true)
        } else {
            let em = try patch.viewBodyEmission(state: merged, export: export)
            let tree = em.root
            let ids = PatchedBodyHost.collectAllIDs(tree)
            PatchedBodyRenderCache.shared.store(typeName: typeName, export: export, input: merged, epoch: epoch,
                                                payload: PatchedBodyCacheEntry(tree: tree, slotArgs: em.slotArgs ?? [:], idSets: ids))
            let dtWasm = Self.nowNanos() - t2
            let t4 = Self.nowNanos()
            _ = render(tree, context: RenderContext(showOpaqueStubs: false))
            let dtRecon = Self.nowNanos() - t4
            return VResult(dtMarshal: dtMarshal, dtMerge: dtMerge, dtWasm: dtWasm,
                           dtIdW: 0, dtRecon: dtRecon, hit: false)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - THE benchmark: 120-frame realistic Feed Screen
    // -------------------------------------------------------------------------

    func testRealisticFeedScreen120Frames() throws {
        _patch = try makePatch()
        _export = _patch!.hasFunction("view_body") ? "view_body" : "view_body__SettingsView"
        _epoch  = _patch!.moduleEpoch
        _seededState = (try? _patch!.dispatch(state: "", event: EventID("__noop__"), value: .none).state) ?? ""

        PatchedBodyRenderCache.shared.reset()
        PatchMarshalCache.shared.reset()

        // Pre-build JSON blobs.
        _headerJSON = buildHeaderJSON(false)
        _row0JSON   = buildRichJSON(notificationsOn: true, badgeCount: 3, displayName: "Ada", subtitle: "member", rowPrefix: "R")
        _row1JSON   = buildRichJSON(notificationsOn: false, badgeCount: 0, displayName: "Grace", subtitle: "admin", rowPrefix: "G")
        _row2JSON   = buildRichJSON(notificationsOn: true, badgeCount: 5, displayName: "Alan", subtitle: nil, rowPrefix: "A")
        _collJSON   = buildRichJSON(notificationsOn: false, badgeCount: 8, displayName: "Trending", subtitle: "Today", rowPrefix: "T")

        let WARMUP = 10, MEASURE = 120
        var aMarshal = PA(), aMerge = PA(), aWasm = PA(), aIdW = PA(), aRecon = PA(), aFrame = PA()
        var frameSamples = [UInt64](); frameSamples.reserveCapacity(MEASURE)
        var totalHits = 0, totalMisses = 0

        for fi in 0..<(WARMUP + MEASURE) {
            let isMeasured = fi >= WARMUP
            let f = fi - WARMUP

            // Scripted mutations (rebuild affected JSON).
            if f == 30 {
                _headerIsExpanded.toggle()
                _headerJSON = buildHeaderJSON(_headerIsExpanded)
            }
            if f == 60 {
                _row0BadgeCount += 1
                _row0JSON = buildRichJSON(notificationsOn: true, badgeCount: _row0BadgeCount,
                                          displayName: "Ada", subtitle: "member", rowPrefix: "R")
            }
            if f == 90 {
                _collDisplayName = "Top Picks"
                _collJSON = buildRichJSON(notificationsOn: false, badgeCount: 8,
                                          displayName: _collDisplayName, subtitle: "Today", rowPrefix: "T")
            }

            let fStart = Self.nowNanos()

            let r0 = try runView(typeName: "V4_FH", propsJSON: _headerJSON)
            let r1 = try runView(typeName: "V4_R0", propsJSON: _row0JSON)
            let r2 = try runView(typeName: "V4_R1", propsJSON: _row1JSON)
            let r3 = try runView(typeName: "V4_R2", propsJSON: _row2JSON)
            let r4 = try runView(typeName: "V4_CV", propsJSON: _collJSON)

            let fWall = Self.nowNanos() - fStart

            if isMeasured {
                for r in [r0, r1, r2, r3, r4] {
                    aMarshal.add(r.dtMarshal); aMerge.add(r.dtMerge); aWasm.add(r.dtWasm)
                    aIdW.add(r.dtIdW); aRecon.add(r.dtRecon)
                    if r.hit { totalHits += 1 } else { totalMisses += 1 }
                }
                aFrame.add(fWall); frameSamples.append(fWall)
            }
        }

        // ---- Report ----
        let p50 = pct(frameSamples, 50); let p95 = pct(frameSamples, 95); let p99 = pct(frameSamples, 99)
        let hitPct  = Double(totalHits)/max(1,Double(totalHits+totalMisses))*100
        let missPct = 1.0 - hitPct/100.0
        let phaseSum = aMarshal.mean + aMerge.mean + aWasm.mean + aIdW.mean + aRecon.mean

        // NOTE: marshal phase here measures reconcileGuestOverride only (the JSON-build
        // is pre-done above to avoid the stack-size issue with large struct init in DEBUG).
        // The REAL marshal cost (Mirror+JSON build) from RenderHotPathBenchmarkTests is
        // ~45µs/view warm (memoized) and ~163µs cold. We add the warm number to projections.
        let realMarshalWarmUs = 45.0    // µs/view from RenderHotPathBenchmarkTests
        let realMarshalPerFrameUs = realMarshalWarmUs * 5.0  // 5 views

        // Conservative projections from CONSOLIDATED.md:
        let f1SaveUs  = aMerge.us * (1.0 - missPct)  // skip merge on hits
        let f2SaveUs  = aMerge.us * missPct * (1.0 - 1.0/1.72)  // 1.72x flat-merge on miss
        let w4SaveUs  = realMarshalPerFrameUs * (1.0 - 1.0/2.5)  // 2.5x marshal memo
        let projUs    = max(0.0, aFrame.us + (realMarshalPerFrameUs - aMarshal.us) - f1SaveUs - f2SaveUs - w4SaveUs)
        let projMs    = projUs / 1_000.0

        // Adjusted frame = our measured + actual marshal (replacing the stub reconcile cost)
        let adjustedFrameUs = aFrame.us + (realMarshalWarmUs*5.0 - aMarshal.us)
        let adjustedFrameMs = adjustedFrameUs / 1_000.0

        var r = "\n" + String(repeating: "=", count: 72) + "\n"
        r += "REALISTIC FEED SCREEN — 5-VIEW FRAME BENCHMARK (V4)\n"
        r += String(repeating: "=", count: 72) + "\n"
        r += "Config: \(buildConfig)  |  frames: \(MEASURE)  |  views/frame: 5\n"
        r += "Total renders: \(MEASURE*5)  |  WASM: EngineSettingsView.wasm\n"
        r += "Views: FeedHeader(scalar) + FeedRow_0/1/2(10-row JSON) + CollectionView\n"
        r += "Mutations: isExpanded@f30, badgeCount@f60, displayName@f90\n"
        r += "NOTE: Marshal phase = reconcileGuestOverride stub only. Real Marshal\n"
        r += "      (~45µs/view warm, ~163µs cold) from RenderHotPathBenchmarkTests.\n\n"

        r += "PER-FRAME WALL CLOCK (all 5 views, measured)\n"
        r += String(format: "  mean: %10.3f ms/frame\n", aFrame.ms)
        r += String(format: "  p50:  %10.3f ms/frame\n", Double(p50)/1_000_000)
        r += String(format: "  p95:  %10.3f ms/frame\n", Double(p95)/1_000_000)
        r += String(format: "  p99:  %10.3f ms/frame\n", Double(p99)/1_000_000)
        r += String(format: "  min:  %10.3f ms/frame\n", Double(aFrame.lo)/1_000_000)
        r += String(format: "  max:  %10.3f ms/frame\n", Double(aFrame.hi)/1_000_000)
        r += String(format: "  [Adjusted with real marshal: %.3f ms/frame]\n", adjustedFrameMs)
        r += String(format: "  16.7ms budget: headroom %.3f ms (%@) [adjusted]\n",
                    16.7-adjustedFrameMs, (16.7-adjustedFrameMs)>0 ? "WITHIN" as NSString : "OVER" as NSString)

        r += "\nPER-PHASE BREAKDOWN (per-frame sum, 5 views, mean)\n"
        r += String(format: "  A. Marshal/reconcile stub:         %7.1f µs  (real marshal: %.0f µs)\n",
                    aMarshal.us, realMarshalPerFrameUs)
        r += String(format: "  B. Merge (reconcile+flatMerge):    %7.1f µs\n", aMerge.us)
        r += String(format: "  C. WASM (cache-check+emission):    %7.1f µs\n", aWasm.us)
        r += String(format: "  D. ID-walks (hits):                %7.1f µs\n", aIdW.us)
        r += String(format: "  E. Reconstitute (render→AnyView):  %7.1f µs\n", aRecon.us)
        r += String(format: "  SUM measured:                      %7.1f µs\n", phaseSum/1_000)
        r += "  Gate (M3: 295ns×5, not measured):    1.5 µs\n"

        r += "\nRENDER-CACHE: hits=\(totalHits) misses=\(totalMisses) (hit rate=\(String(format:"%.0f%%",hitPct)))\n"
        r += "  Expected: 5 initial misses + 3 scripted mutations = 8 total misses\n"

        // Dominant non-marshal phase
        let domPhase = [("Merge", aMerge.us), ("WASM", aWasm.us), ("Reconstitute", aRecon.us)].max(by:{$0.1<$1.1})
        if let d = domPhase {
            r += "\nDOMINANT (non-marshal): \(d.0) — \(String(format:"%.1f µs/frame",d.1))\n"
        }

        r += "\nPROJECTIONS (F1+F2+W4 from CONSOLIDATED.md, conservative, adjusted)\n"
        r += String(format: "  Current (adjusted):          %8.3f ms/frame\n", adjustedFrameMs)
        r += String(format: "  -F1 merge-after-cache-hit:  -%.1f µs\n", f1SaveUs)
        r += String(format: "  -F2 1.72x flat-merge(miss): -%.1f µs\n", f2SaveUs)
        r += String(format: "  -W4 2.5x marshal memo:      -%.1f µs\n", w4SaveUs)
        r += String(format: "  Projected post-F1+F2+W4:     %8.3f ms/frame\n", projMs)
        r += String(format: "  Headroom vs 16.7ms:          %8.3f ms (%@)\n",
                    16.7-projMs, (16.7-projMs)>0 ? "WITHIN" as NSString : "OVER" as NSString)
        r += "(W6/W8/W2 excluded — numbers are conservative)\n"
        r += String(repeating: "=", count: 72) + "\n"

        print(r)
        writeReport(r, marker: "5view-120frames")

        XCTAssertGreaterThan(totalMisses, 0, "Need ≥5 initial cache misses")
        XCTAssertGreaterThan(aFrame.mean, 100, "Frame time < 100ns")
        XCTAssertLessThan(aFrame.ms, 5_000.0, "Frame > 5s")
    }

    // -------------------------------------------------------------------------
    // MARK: - Steady-state floor (100% cache hits)
    // -------------------------------------------------------------------------

    func testSteadyStateFeedScreen120Frames() throws {
        _patch = try makePatch()
        _export = _patch!.hasFunction("view_body") ? "view_body" : "view_body__SettingsView"
        _epoch  = _patch!.moduleEpoch
        _seededState = (try? _patch!.dispatch(state: "", event: EventID("__noop__"), value: .none).state) ?? ""

        let typeNames = ["V4SS_FH", "V4SS_R0", "V4SS_R1", "V4SS_R2", "V4SS_CV"]
        let jsons = [
            buildRichJSON(notificationsOn: true, badgeCount: 3, displayName: "Ada", subtitle: "member", rowPrefix: "R"),
            buildRichJSON(notificationsOn: false, badgeCount: 2, displayName: "Grace", subtitle: "admin", rowPrefix: "G"),
            buildRichJSON(notificationsOn: true, badgeCount: 5, displayName: "Alan", subtitle: nil, rowPrefix: "A"),
            buildRichJSON(notificationsOn: false, badgeCount: 0, displayName: "Trending", subtitle: "Today", rowPrefix: "T"),
            buildRichJSON(notificationsOn: true, badgeCount: 1, displayName: "Else", subtitle: nil, rowPrefix: "E"),
        ]

        PatchedBodyRenderCache.shared.reset(); PatchMarshalCache.shared.reset()
        let export = _export; let epoch = _epoch; let patch = _patch!
        for (i, typeName) in typeNames.enumerated() {
            let props = jsons[i]
            let g = PatchedBodyHost.reconcileGuestOverride(guestState: _seededState, baseline: "", currentProps: props)
            var merged = PatchFlatJSON.merge(base: props, override: g)
            if let itj = PatchedBodyHost.inputTokenJSON(from: [:]) { merged = PatchFlatJSON.merge(base: merged, override: itj) }
            let em = try patch.viewBodyEmission(state: merged, export: export)
            let ids = PatchedBodyHost.collectAllIDs(em.root)
            PatchedBodyRenderCache.shared.store(typeName: typeName, export: export, input: merged, epoch: epoch,
                                                payload: PatchedBodyCacheEntry(tree: em.root, slotArgs: em.slotArgs ?? [:], idSets: ids))
        }

        let WARMUP = 10, MEASURE = 120
        var aMarshal = PA(), aMerge = PA(), aLookup = PA(), aRecon = PA(), aFrame = PA()
        var frameSamples = [UInt64](); frameSamples.reserveCapacity(MEASURE)
        var hits = 0, misses = 0

        for fi in 0..<(WARMUP + MEASURE) {
            let isMeasured = fi >= WARMUP
            let fStart = Self.nowNanos()
            for (i, typeName) in typeNames.enumerated() {
                let props = jsons[i]
                let t0 = Self.nowNanos()
                let g = PatchedBodyHost.reconcileGuestOverride(guestState: _seededState, baseline: "", currentProps: props)
                let dtM = Self.nowNanos() - t0
                let t1 = Self.nowNanos()
                var merged = PatchFlatJSON.merge(base: props, override: g)
                if let itj = PatchedBodyHost.inputTokenJSON(from: [:]) { merged = PatchFlatJSON.merge(base: merged, override: itj) }
                let dtMerge = Self.nowNanos() - t1
                let t2 = Self.nowNanos()
                let cached = PatchedBodyRenderCache.shared.lookup(typeName: typeName, export: export, input: merged, epoch: epoch)
                let dtL = Self.nowNanos() - t2
                if let h = cached {
                    if isMeasured { hits += 1 }
                    let t3 = Self.nowNanos()
                    _ = render(h.tree, context: RenderContext(showOpaqueStubs: false))
                    let dtR = Self.nowNanos() - t3
                    if isMeasured { aMarshal.add(dtM); aMerge.add(dtMerge); aLookup.add(dtL); aRecon.add(dtR) }
                } else { if isMeasured { misses += 1 } }
            }
            let w = Self.nowNanos() - fStart
            if isMeasured { aFrame.add(w); frameSamples.append(w) }
        }

        let p95 = pct(frameSamples, 95)
        let hitPct = Double(hits)/max(1,Double(hits+misses))*100

        var r = "\n" + String(repeating: "=", count: 72) + "\n"
        r += "STEADY-STATE 5-VIEW (100% cache hits, V4)\n"
        r += String(repeating: "=", count: 72) + "\n"
        r += "Config: \(buildConfig)  |  frames: \(MEASURE)  |  views/frame: 5\n"
        r += "FLOOR: irreducible cost when nothing changes frame-to-frame.\n\n"
        r += String(format: "  mean: %.3f ms/frame  p95: %.3f ms\n", aFrame.ms, Double(p95)/1_000_000)
        r += String(format: "  min: %.3f ms  max: %.3f ms\n", Double(aFrame.lo)/1_000_000, Double(aFrame.hi)/1_000_000)
        r += String(format: "  16.7ms headroom: %.3f ms (%@)\n", 16.7-aFrame.ms,
                    (16.7-aFrame.ms)>0 ? "WITHIN" as NSString : "OVER" as NSString)
        r += "\nPer-phase (per-frame sum, 5 views, warm caches):\n"
        r += String(format: "  Reconcile/marshal stub: %7.1f µs\n", aMarshal.us)
        r += String(format: "  Merge:                  %7.1f µs\n", aMerge.us)
        r += String(format: "  Cache lookup:           %7.1f µs\n", aLookup.us)
        r += String(format: "  Reconstitute:           %7.1f µs\n", aRecon.us)
        r += String(format: "\nCache: %d hits, %d misses (%.0f%% hit rate)\n", hits, misses, hitPct)
        r += String(repeating: "=", count: 72) + "\n"

        print(r)
        writeReport(r, marker: "5view-steady-state")
        XCTAssertLessThan(aFrame.ms, 5_000.0)
    }
}
#endif
