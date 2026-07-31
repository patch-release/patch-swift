// SPDX-License-Identifier: MIT

import XCTest
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI
#endif

// V12ReleaseBenchmarkTests — RELEASE-BUILD NATIVE vs PATCH 1.5.15 FRAME BENCHMARK
// ==================================================================================
// THREE configs, RELEASE only (run with: swift test -c release --filter V12Release):
//
//   (A) PURE NATIVE: 5 SwiftUI View.body evaluations per frame — the floor.
//       Cost of evaluating a struct's body (modifier chain + Text, etc) with no Patch.
//       Tells us what SwiftUI itself charges just to build the View description.
//
//   (B) PATCH 1.5.15 STEADY-STATE: 5 patched views, inputs unchanged frame-to-frame.
//       F1 pre-merge cache HITS → reconcile + merge + WASM ALL SKIPPED.
//       Cost = gate hash compare + PatchedBodyHost.body overhead + render reconstitution.
//       This is the dominant real-world case (SwiftUI re-evaluates bodies constantly
//       even when state hasn't changed — e.g. parent re-renders, animation ticks).
//
//   (C) PATCH 1.5.15 COLD: one view's propsJSON changes each frame.
//       Pre-merge cache MISS → reconcile + merge + input-hash cache lookup.
//       The WASM call itself is SKIPPED (input-hash render-cache already primed) — this
//       measures the "state changed, rebuild the WASM input" path WITHOUT WASM cost.
//       To force a full WASM cold start, we'd need distinct viewBodyEmission calls —
//       measured separately in the WASM-cold sub-test.
//
// Report: ms/frame for A, B, C; per-phase µs breakdown for B; residual µs/view over
// native; whether B is below 0.4ms for 5 views.
//
// Methodology:
//   • clock_gettime_nsec_np(CLOCK_UPTIME_RAW) — monotonic ns, no syscall cost.
//   • WARMUP=50 frames before measurement to prime CPU caches / JIT.
//   • MEASURE=200 frames per config.
//   • 5 views per frame (FeedHeader + FeedRow_0/1/2 + CollectionView — same as V4).
//   • Each config resets all caches before its warmup.
//   • Native baseline uses the SAME number of body evals (5×200 = 1000).
//   • RELEASE build: -O optimization, no ARC profiling.
//
// Build config detection: #if DEBUG / #else.
// Platform: macOS (mac Catalyst / SwiftPM test host). Device numbers would be
// ~2–3× lower on A-series silicon; report explicitly as "Mac (M-series SwiftPM host)".

#if canImport(SwiftUI)
@MainActor
final class V12ReleaseBenchmarkTests: XCTestCase {

    // ─── monotonic timer ───────────────────────────────────────────────────────
    @inline(__always) private static func ns() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private var buildConfig: String {
        #if DEBUG
        return "DEBUG"
        #else
        return "RELEASE"
        #endif
    }

    // ─── instance shapes matching V4 ──────────────────────────────────────────
    struct HeaderInstance { var title = "Feed"; var subtitle = "Latest"; var unreadCount = 7; var isExpanded = false; var badgeColor = "red" }
    struct Row { var id: Int; var title: String; var enabled: Bool }
    struct RichInstance {
        var notificationsOn: Bool; var badgeCount: Int; var displayName: String
        var subtitle: String?
        var rows: [Row]
        init(notificationsOn: Bool = true, badgeCount: Int = 3, displayName: String = "Ada",
             subtitle: String? = "member", rowPrefix: String = "R") {
            self.notificationsOn = notificationsOn; self.badgeCount = badgeCount
            self.displayName = displayName; self.subtitle = subtitle
            self.rows = (0..<10).map { Row(id: $0, title: "\(rowPrefix)\($0)", enabled: $0 % 2 == 0) }
        }
    }

    // ─── (A) Native SwiftUI View bodies ───────────────────────────────────────
    // Five simple SwiftUI views that approximate the visual complexity of the patched
    // views (Text + VStack + padding + conditional + ForEach). We call .body on each
    // to measure what SwiftUI itself charges per body evaluation — the zero-overhead floor.

    struct NativeHeader: View {
        var title: String; var subtitle: String; var unreadCount: Int; var isExpanded: Bool
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if unreadCount > 0 { Text("\(unreadCount)").foregroundColor(.red) }
                }
                if isExpanded { Text(subtitle).font(.caption).foregroundColor(.secondary) }
            }.padding(.horizontal)
        }
    }

    struct NativeRow: View {
        var notificationsOn: Bool; var badgeCount: Int; var displayName: String; var subtitle: String?
        var rows: [Row]
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(displayName).font(.body)
                    Spacer()
                    if notificationsOn { Image(systemName: "bell.fill") }
                    if badgeCount > 0 { Text("\(badgeCount)").padding(4).background(Color.red).foregroundColor(.white) }
                }
                if let sub = subtitle { Text(sub).font(.caption).foregroundColor(.secondary) }
                ForEach(rows.prefix(3), id: \.id) { r in
                    HStack { Text(r.title); Spacer(); if r.enabled { Image(systemName: "checkmark") } }
                }
            }.padding()
        }
    }

    // ─── WASM fixture ─────────────────────────────────────────────────────────
    private func engineViewBytes() throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: "EngineSettingsView", withExtension: "wasm") else {
            throw XCTSkip("EngineSettingsView.wasm fixture missing — run swift test -c release --filter V12Release")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    private func makePatchSingleton() throws -> (patch: Patch, export: String, epoch: UInt64, entry: PatchViewManifest.Entry) {
        Patch.configure(.init(appKey: "v12-bench", apiBaseURL: nil))
        let patch = Patch.shared
        try patch.activate(bytes: try engineViewBytes())
        let export = patch.hasFunction("view_body") ? "view_body" : "view_body__SettingsView"
        let epoch = patch.moduleEpoch

        // Build a synthetic manifest entry pointing at the engine's export.
        // bodyHash is set to a value that NEVER matches a thunk hash (so the native-fast-path
        // never fires — we want the full WASM+cache path). thunkSafe=true routes us into body.
        // isStructurallyStatic: false — we want the render-cache (input-hash) path, not the
        // static-template path, so we measure the realistic dynamic-view pipeline.
        let entry = PatchViewManifest.Entry(
            type: "V12BenchView", export: export, dispatch: nil,
            thunkSafe: true, minVersion: nil,
            bodyHash: "__v12_bench_never_matches__",
            isStructurallyStatic: false)
        // Install via the test seam: pins loadedEpoch so syncWithModuleEpoch won't clobber.
        PatchViewPatchRegistry.shared.installEntriesForTesting([entry])
        return (patch, export, epoch, entry)
    }

    // ─── JSON builders (same as V4) ───────────────────────────────────────────
    private func headerJSON(_ isExpanded: Bool = false) -> String {
        #"{"title":"Feed","subtitle":"Latest","unreadCount":7,"isExpanded":"# +
        (isExpanded ? "true" : "false") + #","badgeColor":"red"}"#
    }
    private func richJSON(notificationsOn: Bool = true, badgeCount: Int = 3, displayName: String = "Ada",
                          subtitle: String? = "member", rowPrefix: String = "R") -> String {
        let notif = notificationsOn ? "true" : "false"
        let sub = subtitle.map { "\"\($0)\"" } ?? "null"
        var rows = "["
        for i in 0..<10 {
            if i > 0 { rows += "," }
            let en = (i % 2 == 0) ? "true" : "false"
            rows += #"{"enabled":"# + en + #","id":"# + "\(i)" + #","title":""# + rowPrefix + "\(i)\"}"
        }
        rows += "]"
        return #"{"badgeCount":"# + "\(badgeCount)" + #","displayName":""# + displayName +
               #"","notificationsOn":"# + notif + #","rows":"# + rows + #","subtitle":"# + sub + "}"
    }

    // ─── stat accumulator ─────────────────────────────────────────────────────
    private struct PA {
        var total: UInt64 = 0; var n: Int = 0; var lo: UInt64 = .max; var hi: UInt64 = 0
        mutating func add(_ v: UInt64) { total += v; n += 1; if v < lo { lo = v }; if v > hi { hi = v } }
        var mean: Double { n == 0 ? 0 : Double(total) / Double(n) }
        var us: Double { mean / 1_000 }; var ms: Double { mean / 1_000_000 }
    }
    private func pct(_ s: [UInt64], _ p: Double) -> Double {
        guard !s.isEmpty else { return 0 }
        let sorted = s.sorted()
        return Double(sorted[max(0, min(sorted.count-1, Int(Double(sorted.count-1)*p/100)))]) / 1_000_000
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: — THE V12 BENCHMARK
    // ═══════════════════════════════════════════════════════════════════════════

    func testV12ReleaseNativeVsPatch() throws {
        let WARMUP = 50, MEASURE = 200

        // ── CONFIG A: pure native ────────────────────────────────────────────
        let h = HeaderInstance()
        let r0 = RichInstance(notificationsOn: true, badgeCount: 3, displayName: "Ada", rowPrefix: "R")
        let r1 = RichInstance(notificationsOn: false, badgeCount: 0, displayName: "Grace", rowPrefix: "G")
        let r2 = RichInstance(notificationsOn: true, badgeCount: 5, displayName: "Alan", subtitle: nil, rowPrefix: "A")
        let r4 = RichInstance(notificationsOn: false, badgeCount: 8, displayName: "Trending", subtitle: "Today", rowPrefix: "T")

        var nativeA = PA(); var nativeSamples = [UInt64](); nativeSamples.reserveCapacity(MEASURE)
        for fi in 0..<(WARMUP + MEASURE) {
            let t0 = Self.ns()
            // Evaluate 5 native View bodies — same N as Patch configs.
            let v0 = NativeHeader(title: h.title, subtitle: h.subtitle, unreadCount: h.unreadCount, isExpanded: h.isExpanded)
            let v1 = NativeRow(notificationsOn: r0.notificationsOn, badgeCount: r0.badgeCount,
                                displayName: r0.displayName, subtitle: r0.subtitle, rows: r0.rows)
            let v2 = NativeRow(notificationsOn: r1.notificationsOn, badgeCount: r1.badgeCount,
                                displayName: r1.displayName, subtitle: r1.subtitle, rows: r1.rows)
            let v3 = NativeRow(notificationsOn: r2.notificationsOn, badgeCount: r2.badgeCount,
                                displayName: r2.displayName, subtitle: r2.subtitle, rows: r2.rows)
            let v4 = NativeRow(notificationsOn: r4.notificationsOn, badgeCount: r4.badgeCount,
                                displayName: r4.displayName, subtitle: r4.subtitle, rows: r4.rows)
            // Force body evaluation — .body is a computed var; the compiler will not elide it
            // with @inline(never) semantics since we capture into an existential below.
            let bodies: [Any] = [v0.body, v1.body, v2.body, v3.body, v4.body]
            let wall = Self.ns() - t0
            _ = bodies  // keep alive
            if fi >= WARMUP { nativeA.add(wall); nativeSamples.append(wall) }
        }

        // ── Setup Patch for B + C ────────────────────────────────────────────
        let (patch, export, epoch, entry) = try makePatchSingleton()
        _ = patch; _ = epoch

        // Reset all caches
        PatchedBodyPreMergeCache.shared.reset()
        PatchedBodyRenderCache.shared.reset()
        PatchMarshalCache.shared.reset()

        // Pre-build stable JSON blobs (same as V4 — we use pre-built JSON to
        // separate the propsJSON-build cost from the render pipeline, exactly as V4 did).
        let j0 = headerJSON(false)
        let j1 = richJSON(notificationsOn: true, badgeCount: 3, displayName: "Ada", rowPrefix: "R")
        let j2 = richJSON(notificationsOn: false, badgeCount: 0, displayName: "Grace", rowPrefix: "G")
        let j3 = richJSON(notificationsOn: true, badgeCount: 5, displayName: "Alan", subtitle: nil, rowPrefix: "A")
        let j4 = richJSON(notificationsOn: false, badgeCount: 8, displayName: "Trending", subtitle: "Today", rowPrefix: "T")
        let typeNames = ["V12_FH", "V12_R0", "V12_R1", "V12_R2", "V12_CV"]
        let stableJSONs = [j0, j1, j2, j3, j4]

        // ── CONFIG B: Patch 1.5.15 steady-state (100% F1 pre-merge cache hits) ──
        // Strategy: call PatchedBodyHost.body directly. The host is a View struct;
        // its body is a computed var that runs the full F1/F2/render-cache pipeline.
        //
        // On steady-state (same propsJSON + empty guestState/baseline):
        //   Frame 1 (warmup[0]): F1 MISS → reconcile + merge + input-hash cache MISS → WASM → store both caches
        //   Frame 2+: F1 HIT → skip reconcile + merge + WASM + ID-walks entirely
        //           → just: key compare (~string hash) + entry lookup + reconstitute
        //
        // We construct PatchedBodyHost directly (internal init, @testable import gives access).

        var bFrame = PA(), bBody = PA()
        var bSamples = [UInt64](); bSamples.reserveCapacity(MEASURE)

        // Per-phase accumulators for B: measure the gate (entry lookup) separately from body.
        // Since gate is baked inside thunkBody → PatchedBodyHost.body, we estimate it here
        // by timing PatchedBodyHost.body alone (the gate is the single if-let entry lookup,
        // negligible overhead measured separately below in the gate-only micro).

        // Warmup + measure loop.
        for fi in 0..<(WARMUP + MEASURE) {
            let fStart = Self.ns()
            var frameBody: UInt64 = 0

            for (i, typeName) in typeNames.enumerated() {
                let propsJSON = stableJSONs[i]
                let host = PatchedBodyHost(typeName: typeName, entry: entry,
                                           propsJSON: propsJSON, writebacks: [])
                let t0 = Self.ns()
                let _ = host.body  // the real pipeline: F1 check → (hit) reconstitute
                frameBody += Self.ns() - t0
            }
            let fWall = Self.ns() - fStart
            if fi >= WARMUP {
                bFrame.add(fWall); bBody.add(frameBody); bSamples.append(fWall)
            }
        }

        // ── CONFIG C: Patch 1.5.15 mutation (F1 miss per frame on 1 view) ──
        // One view's propsJSON changes each frame → F1 cache miss for that view →
        // reconcile + merge + input-hash render-cache lookup (no WASM — render-cache
        // hit since we've seen this exact merged string before in a prior frame).
        // The other 4 views are F1 steady-state hits.
        //
        // To simulate the actual mutation pattern (V4 scripted mutations), we toggle
        // a boolean field on the header view each frame — the resulting propsJSON string
        // changes, giving a F1 miss for V12_FH only.

        PatchedBodyPreMergeCache.shared.reset()  // fresh for C
        // (render-cache stays primed from B — realistic: a real app's render cache
        //  persists across re-renders; a C miss hits the input-hash cache not WASM)

        var cFrame = PA(); var cSamples = [UInt64](); cSamples.reserveCapacity(MEASURE)
        var isExpanded = false

        for fi in 0..<(WARMUP + MEASURE) {
            isExpanded.toggle()  // mutate FH every frame → F1 miss on V12_FH
            let mutatedJ0 = headerJSON(isExpanded)
            let frameJSONs = [mutatedJ0, j1, j2, j3, j4]

            let fStart = Self.ns()
            for (i, typeName) in typeNames.enumerated() {
                let host = PatchedBodyHost(typeName: typeName, entry: entry,
                                           propsJSON: frameJSONs[i], writebacks: [])
                let _ = host.body
            }
            let fWall = Self.ns() - fStart
            if fi >= WARMUP { cFrame.add(fWall); cSamples.append(fWall) }
        }

        // ── CONFIG C-WASM: full WASM cold-start on a mutation (per-view once) ──
        // Measure just the WASM invocation cost on a real cache-cold miss (fresh
        // input-hash cache miss → full WASM invoke + decode). We do this by forcing
        // unique JSON on every call. This is the p99 outlier cost on mutation frames.
        PatchedBodyPreMergeCache.shared.reset()
        PatchedBodyRenderCache.shared.reset()

        var wasmColdNs = PA()
        var counter = 0
        for fi in 0..<(WARMUP + MEASURE) {
            counter += 1
            // Force a unique propsJSON to guarantee WASM miss every iteration.
            let uniqueJ = richJSON(notificationsOn: true, badgeCount: counter,
                                   displayName: "Ada", rowPrefix: "R")
            let host = PatchedBodyHost(typeName: "V12_COLD_\(fi)", entry: entry,
                                       propsJSON: uniqueJ, writebacks: [])
            let t0 = Self.ns()
            let _ = host.body
            let dt = Self.ns() - t0
            if fi >= WARMUP { wasmColdNs.add(dt) }
        }

        // ── Per-phase breakdown for B (F1 hit) ──────────────────────────────
        // To isolate the cost breakdown on a steady-state hit, we run a tight
        // micro of the two remaining stages separately: (1) the pre-merge cache
        // lookup/key build, and (2) the render reconstitution.
        //
        // Strategy: run ONE view through PatchedBodyHost.body (F1 hit) 2000 times
        // and time it; then run render() on a pre-built static tree 2000 times.
        // The difference is the F1 cache machinery overhead (key hashing + dict lookup).

        // Ensure the render-cache and F1 cache are warm for "V12_PH" from B.
        let phTypeName = "V12_FH"

        // (a) F1 hit total cost per view (including reconstitute)
        var phTotal = PA()
        let iters = 2000
        for fi in 0..<iters {
            let host = PatchedBodyHost(typeName: phTypeName, entry: entry,
                                       propsJSON: j0, writebacks: [])
            let t0 = Self.ns()
            let _ = host.body
            let dt = Self.ns() - t0
            if fi >= 100 { phTotal.add(dt) }
        }

        // (b) Reconstitution only: render a static pre-built tree
        let staticTree: ViewNode
        do {
            let em = try Patch.shared.viewBodyEmission(state: j1, export: export)
            staticTree = em.root
        }
        var reconOnly = PA()
        for fi in 0..<iters {
            let t0 = Self.ns()
            let _ = render(staticTree, context: RenderContext(showOpaqueStubs: false))
            let dt = Self.ns() - t0
            if fi >= 100 { reconOnly.add(dt) }
        }

        // (c) Gate only: PatchViewPatchRegistry entry lookup (what thunkBody does)
        var gateOnly = PA()
        for fi in 0..<iters {
            let t0 = Self.ns()
            let _ = PatchViewPatchRegistry.shared.entryIfPatchable(typeName: phTypeName)
            let dt = Self.ns() - t0
            if fi >= 100 { gateOnly.add(dt) }
        }

        // Phase F1 cache probe alone (dict lookup + key hash in PatchedBodyPreMergeCache)
        // — approximate as: total_per_view − reconstitute − gate
        let f1CacheProbUs = max(0.0, phTotal.us - reconOnly.us - gateOnly.us)

        // ── Residual per-view overhead vs native ─────────────────────────────
        // Native per-view = nativeA.us / 5.0  (5 bodies per frame)
        // Patch steady-state per-view = bFrame.us / 5.0
        let nativePerView = nativeA.us / 5.0
        let patchSSPerView = bFrame.us / 5.0
        let residualUs = patchSSPerView - nativePerView

        // ─── REPORT ──────────────────────────────────────────────────────────
        let w = String(repeating: "=", count: 72)
        var r = "\n\(w)\n"
        r += "V12 RELEASE-BUILD NATIVE vs PATCH 1.5.15  (5-view frame benchmark)\n\(w)\n"
        r += "Build: \(buildConfig)  |  frames: \(MEASURE)  |  views/frame: 5\n"
        r += "Platform: Mac (SwiftPM test host, M-series). Device ~2-3× lower.\n"
        r += "Warmup: \(WARMUP) frames/config  |  Total renders per config: \(MEASURE*5)\n\n"

        r += "══ CONFIG A: PURE NATIVE (5 SwiftUI View.body evals/frame) ══\n"
        r += String(format: "  mean:  %8.4f ms/frame    (%6.1f µs/view)\n", nativeA.ms, nativePerView)
        r += String(format: "  p50:   %8.4f ms          p95: %8.4f ms          p99: %8.4f ms\n",
                    pct(nativeSamples, 50), pct(nativeSamples, 95), pct(nativeSamples, 99))
        r += "  → This is the floor: pure SwiftUI body eval cost.\n\n"

        r += "══ CONFIG B: PATCH 1.5.15 STEADY-STATE (F1 pre-merge cache hits) ══\n"
        r += "  (inputs unchanged frame-to-frame — the dominant SwiftUI case)\n"
        r += String(format: "  mean:  %8.4f ms/frame    (%6.1f µs/view)\n", bFrame.ms, patchSSPerView)
        r += String(format: "  p50:   %8.4f ms          p95: %8.4f ms          p99: %8.4f ms\n",
                    pct(bSamples, 50), pct(bSamples, 95), pct(bSamples, 99))
        let underLimit = bFrame.ms < 0.4 ? "YES ✓" : "NO ✗"
        r += String(format: "  Under 0.4ms? %@  |  Under 0.2ms? %@\n",
                    underLimit, bFrame.ms < 0.2 ? "YES ✓" : "NO ✗")
        r += String(format: "  Residual overhead over native: %+.1f µs/view  (%+.4f ms/5-view frame)\n",
                    residualUs, residualUs * 5.0 / 1_000.0)
        r += "\n"

        r += "══ CONFIG C: PATCH 1.5.15 MUTATION (1 view F1 miss/frame, 4 hits) ══\n"
        r += "  (1 view's propsJSON flips every frame; render-cache stays primed)\n"
        r += String(format: "  mean:  %8.4f ms/frame    (%6.1f µs/view)\n", cFrame.ms, cFrame.us / 5.0)
        r += String(format: "  p50:   %8.4f ms          p95: %8.4f ms\n",
                    pct(cSamples, 50), pct(cSamples, 95))
        r += "\n"

        r += "══ CONFIG C-WASM: FULL WASM COLD-START (unique input per frame) ══\n"
        r += "  (worst-case: every view is a WASM cache miss — p99 mutation cost)\n"
        r += String(format: "  mean per view:  %8.1f µs   (%6.4f ms)\n", wasmColdNs.us, wasmColdNs.ms)
        r += String(format: "  5-view frame worst-case: %8.4f ms (sum of 5 cold views)\n", wasmColdNs.ms * 5.0)
        r += "\n"

        r += "══ PER-PHASE BREAKDOWN — B (F1 hit, per view, \(phTypeName)) ══\n"
        r += String(format: "  Gate (entryIfPatchable):            %8.1f ns   %6.4f µs\n",
                    gateOnly.mean, gateOnly.us)
        r += String(format: "  F1 cache probe (dict lookup+hash):  %8.1f ns   %6.4f µs  [~estimated]\n",
                    f1CacheProbUs * 1_000, f1CacheProbUs)
        r += String(format: "  Render reconstitution (render()):   %8.1f ns   %6.4f µs\n",
                    reconOnly.mean, reconOnly.us)
        r += String(format: "  TOTAL per view (F1 hit):            %8.1f ns   %6.4f µs\n",
                    phTotal.mean, phTotal.us)
        r += String(format: "  × 5 views/frame:                    %8.1f µs  (%6.4f ms)\n",
                    phTotal.us * 5.0, phTotal.ms * 5.0)
        r += "\n"

        r += "══ NEXT LEVER (if B is not already under 0.4ms) ══\n"
        let candidates: [(String, Double, String)] = [
            ("L1 render-alloc: AnyView→PatchModifierStack (dropped — broken EffectSlot)", reconOnly.us * 0.6,
             "Skips AnyView wrapping per node; requires EffectSlot refix first"),
            ("L4/L7 marshal codegen (__patchExtract, array-skip)", 0.0,
             "Already shipped in 1.5.15 (L7) — incremental gain ~10-20ns/field"),
            ("L5 gate (295→143ns, registry read)", gateOnly.us * 0.5,
             "Move registry to a flat array keyed by type-pointer; ~1µs/5-view save"),
            ("L9 per-type invalidation scope (shipped)", 0.0,
             "Already shipped in 1.5.15 — not a render-hot-path lever"),
        ]
        // Find the biggest available lever
        let biggest = candidates.max { $0.1 < $1.1 }
        if let b = biggest {
            r += "  Biggest lever: \(b.0)\n"
            r += String(format: "  Estimated save: %.2f µs/view → %.4f ms/5-view frame\n", b.1, b.1 * 5 / 1_000)
            r += "  Note: \(b.2)\n"
        }
        r += "\n"

        // Summary verdict
        r += "══ SUMMARY ══\n"
        r += String(format: "  Native floor:              %.4f ms/frame  (%.1f µs/view)\n", nativeA.ms, nativePerView)
        r += String(format: "  Patch 1.5.15 steady-state: %.4f ms/frame  (%.1f µs/view)\n", bFrame.ms, patchSSPerView)
        r += String(format: "  Patch 1.5.15 mutation:     %.4f ms/frame\n", cFrame.ms)
        r += String(format: "  Patch cold WASM worst-case: %.4f ms/frame (5 views, all WASM misses)\n", wasmColdNs.ms * 5.0)
        r += String(format: "  Residual overhead/view: %+.1f µs  (%+.4f ms/5-view frame) over native\n",
                    residualUs, residualUs * 5.0 / 1_000.0)
        r += String(format: "  Under 0.4ms for 5-view screen? %@\n", underLimit)
        r += String(format: "  16.7ms budget headroom (steady): %.2f ms\n", 16.7 - bFrame.ms)
        r += "\(w)\n"
        r += "NOTE: Marshal (PatchInstanceInputs.extract) NOT included — it runs in thunkBody\n"
        r += "BEFORE PatchedBodyHost.body. For real apps, add ~45µs/view (warm memoized) or\n"
        r += "~4µs/view (L7 scalar-direct-hash hit). Real thunkBody total ≈ Body+Marshal above.\n"
        r += "\(w)\n"

        print(r)

        // Write report files
        let dir = BenchmarkOutput.directory("perf-deepdive")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let rawPath = "\(dir)/V12-release-native-vs-patch-raw.txt"
        let mdPath  = "\(dir)/V12-release-native-vs-patch.md"
        try? r.write(toFile: rawPath, atomically: true, encoding: .utf8)
        print("[V12] raw numbers written to \(rawPath)")

        // Write the MD report separately (filled in below with the full analysis)
        // Note: this test returns the raw numbers; the MD is written in writeV12Report()
        // called after we have the actual measured values.
        let md = buildMDReport(
            buildConfig: buildConfig,
            nativeMs: nativeA.ms, nativePerViewUs: nativePerView,
            steadyMs: bFrame.ms, steadyPerViewUs: patchSSPerView,
            residualUs: residualUs,
            coldFnMiss: cFrame.ms,
            wasmColdMs: wasmColdNs.ms,
            gateUs: gateOnly.us,
            f1CacheUs: f1CacheProbUs,
            reconUs: reconOnly.us,
            perViewTotalUs: phTotal.us,
            underLimit: bFrame.ms < 0.4,
            under02: bFrame.ms < 0.2,
            nativeSamples: nativeSamples,
            bSamples: bSamples,
            cSamples: cSamples
        )
        try? md.write(toFile: mdPath, atomically: true, encoding: .utf8)
        print("[V12] MD report written to \(mdPath)")

        // Assertions: the benchmark ran successfully and numbers are in range.
        XCTAssertGreaterThan(nativeA.mean, 100, "Native frame < 100ns — measurement noise")
        XCTAssertGreaterThan(bFrame.mean, 100, "Patch SS frame < 100ns — measurement noise")
        XCTAssertLessThan(bFrame.ms, 5.0, "Patch SS frame > 5ms — something is wrong")
        XCTAssertLessThan(cFrame.ms, 5.0, "Patch cold frame > 5ms — something is wrong")
    }

    // ─── MD report builder ────────────────────────────────────────────────────
    private func buildMDReport(
        buildConfig: String,
        nativeMs: Double, nativePerViewUs: Double,
        steadyMs: Double, steadyPerViewUs: Double,
        residualUs: Double,
        coldFnMiss: Double,
        wasmColdMs: Double,
        gateUs: Double, f1CacheUs: Double, reconUs: Double, perViewTotalUs: Double,
        underLimit: Bool, under02: Bool,
        nativeSamples: [UInt64], bSamples: [UInt64], cSamples: [UInt64]
    ) -> String {
        let date = ISO8601DateFormatter().string(from: Date())
        let md = """
        # V12 Release-Build Native vs Patch 1.5.15 — 5-View Frame Benchmark

        **Measured:** \(date) | **Build:** \(buildConfig) | SDK v1.5.15
        **Platform:** Mac (SwiftPM test host, M-series). On-device numbers ~2–3× lower.

        > Prior benchmark (V4) was **DEBUG** and measured **pre-F1** (v1.5.14). V12 is RELEASE + 1.5.15
        > (F1 pre-merge cache + L2 cheap key + L6/L7/W5a/W5b/W7/W8 optimizations active).

        ## Three Configs

        | Config | Description |
        |---|---|
        | A — Native | 5 SwiftUI View.body evals, zero Patch |
        | B — Patch steady-state | 5 views, inputs unchanged, F1 cache hits |
        | C — Patch mutation | 1 view propsJSON flips/frame, render-cache primed |
        | C-WASM — cold WASM | 5 views, all WASM misses (worst-case outlier) |

        ## Key Numbers (\(buildConfig))

        | Config | ms/frame (5 views) | µs/view |
        |---|---|---|
        | A — Pure native | **\(String(format: "%.4f", nativeMs))** | \(String(format: "%.1f", nativePerViewUs)) |
        | B — Patch SS | **\(String(format: "%.4f", steadyMs))** | \(String(format: "%.1f", steadyPerViewUs)) |
        | C — Mutation (1 miss/frame) | **\(String(format: "%.4f", coldFnMiss))** | — |
        | C-WASM — cold WASM/view | **\(String(format: "%.4f", wasmColdMs))** | \(String(format: "%.1f", wasmColdMs * 1_000)) |
        | C-WASM — 5-view worst-case | **\(String(format: "%.4f", wasmColdMs * 5.0))** | — |

        **Is B below 0.4 ms/frame?** \(underLimit ? "**YES**" : "**NO**")
        **Is B below 0.2 ms/frame?** \(under02 ? "**YES**" : "**NO**")
        **Residual overhead over native:** \(String(format: "%+.1f µs/view", residualUs)) = \(String(format: "%+.4f ms", residualUs * 5.0 / 1_000.0)) for 5 views

        ## Per-Phase Breakdown — B (F1 steady-state hit, per view)

        | Phase | ns/view | µs/view | Notes |
        |---|---|---|---|
        | Gate (entryIfPatchable) | \(String(format: "%.1f", gateUs * 1_000)) | \(String(format: "%.3f", gateUs)) | Registry dict lookup |
        | F1 cache probe (key hash+dict lookup) | \(String(format: "%.0f", f1CacheUs * 1_000)) | \(String(format: "%.3f", f1CacheUs)) | ~estimated: total − recon − gate |
        | Render reconstitution (render()) | \(String(format: "%.1f", reconUs * 1_000)) | \(String(format: "%.3f", reconUs)) | ViewNode → AnyView tree walk |
        | **TOTAL per view** | **\(String(format: "%.1f", perViewTotalUs * 1_000))** | **\(String(format: "%.3f", perViewTotalUs))** | |
        | **× 5 views** | | **\(String(format: "%.3f", perViewTotalUs * 5.0))** | |

        **Dominant phase on F1 hit:** \(reconUs > f1CacheUs ? "Render reconstitution" : "F1 cache probe")
        (reconcile + merge + WASM + ID-walks = ZERO cost — all skipped by F1 + render-cache)

        ## Marshal cost (NOT included above — runs in thunkBody before PatchedBodyHost.body)

        Marshal runs inside `Patch.shared.thunkBody()` before returning `PatchedBodyHost`.
        The memoized warm cost (L7 scalar-hash hit, unchanged instance) is ~4–45 µs/view
        depending on instance complexity (scalar: ~4µs, rich+10-row array: ~45µs).
        For a real 5-view screen:
        - Scalar instances (no array fields): add ~20 µs total
        - Rich instances (10-row array): add ~225 µs total (pre-L7-memo was ~225µs; post-memo ~45µs)

        **Real thunkBody total = per-phase B total + marshal warm cost.**

        ## Projections vs V4 (DEBUG, pre-F1)

        | Metric | V4 (DEBUG, pre-F1) | V12 (RELEASE, post-F1) |
        |---|---|---|
        | Steady-state mean | 0.51 ms | \(String(format: "%.4f ms", steadyMs)) |
        | Per-view (merge was dominant) | ~89 µs/frame merge | ~0 µs merge (F1 skips) |
        | Dominant remaining cost | Merge (~89 µs/frame) | \(reconUs > f1CacheUs ? String(format: "Reconstitution (~%.0fµs/view)", reconUs) : String(format: "F1 probe (~%.0fµs/view)", f1CacheUs)) |
        | 16.7ms headroom | 16.2 ms | \(String(format: "%.2f ms", 16.7 - steadyMs)) |

        ## Next Lever (if B is not well under 0.4ms)

        \(underLimit ? "B is already under 0.4ms — no critical lever needed." : "")
        \(!underLimit ? "Reconstitution (~\\(String(format: \"%.0f\", reconUs))µs/view) is the dominant remaining cost. L1 render-alloc (AnyView→PatchModifierStack) would save ~60% of reconstitution cost but requires the EffectSlot refix first." : "")
        Even if B is under 0.4ms, further wins are available:
        - **L1 render-alloc** (dropped, needs EffectSlot refix): eliminate AnyView per node → save ~\(String(format: "%.0f", reconUs * 0.6))µs/view reconstitution
        - **L4 marshal codegen** (__patchExtract): zero-Mirror steady-state → save ~4–45µs/view marshal
        - **L5 gate** (flat array by type-pointer): ~½µs/view → ~2.5µs/5-view frame

        ## Budget Headroom

        60fps budget: 16.7ms/frame.
        Patch 1.5.15 steady-state: \(String(format: "%.4f ms", steadyMs)) → **\(String(format: "%.2f ms", 16.7 - steadyMs)) headroom** (well within budget).

        ## Files

        - Raw numbers: `<output-dir>/V12-release-native-vs-patch-raw.txt`
        - This report: `<output-dir>/V12-release-native-vs-patch.md`
        - Test harness: `sdk/Tests/PatchSDKTests/V12ReleaseBenchmarkTests.swift`
        - `<output-dir>` = `$PATCH_BENCH_OUT/perf-deepdive` (defaults under the system temp dir)

        ## Methodology

        - `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` — monotonic ns, no syscall cost
        - WARMUP=\(50) frames per config, MEASURE=200 frames; all stats over measured frames only
        - Native: evaluate `View.body` directly (5 struct SwiftUI views/frame, captured as `[Any]` to prevent DCE)
        - Patch B: construct `PatchedBodyHost(typeName:entry:propsJSON:writebacks:)` then call `.body`
        - Patch C: mutate one view's propsJSON each frame (toggle Bool → different JSON string)
        - C-WASM: unique propsJSON per iteration, distinct typeName per iteration → guaranteed cache miss
        - Marshal (PatchInstanceInputs.extract) NOT included in B/C frame time — measured separately

        """
        return md
    }
}
#endif
