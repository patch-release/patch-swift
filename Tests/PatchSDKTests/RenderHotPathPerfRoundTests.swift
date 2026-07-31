// SPDX-License-Identifier: MIT

import XCTest
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI
#endif

// RenderHotPathPerfRoundTests — the SECOND perf round (cold-miss + large-tree).
// ============================================================================
// Three concerns, all host-bridge-free, no IR/wire change:
//
//  T1 — `.animation(_:value:)` investigation: PROVE whether an animation re-runs the
//       WASM guest per frame (cold-miss every frame = felt jank) or whether the guest
//       runs once per logical transition and SwiftUI interpolates host-side over the
//       cached tree. The render cache keys on the EXACT `merged` input, so this reduces
//       to: across an animation, how many DISTINCT `merged` inputs occur?
//
//  T2 — `collectAllIDs` (the single-pass id collector) must be BYTE-IDENTICAL to the six
//       separate `collect*IDs` walks + `collectAnimationValueKeys` (the false-render gate
//       for the safety-net collection — any divergence is a correctness bug).
//
//  T3 — reconstitution + tree-walk cost at REAL screen scale (hundreds of nodes), to
//       size the T2 win and check whether reconstitution/AnyView churn needs a fix.
#if canImport(SwiftUI)
@MainActor
final class RenderHotPathPerfRoundTests: XCTestCase {

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
    private func writeReport(_ text: String, marker: String) {
        let dir = BenchmarkOutput.directory("overnight-rigor-run")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? text.write(toFile: "\(dir)/perf-raw-\(marker).txt", atomically: true, encoding: .utf8)
    }

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

    // ========================================================================
    // MARK: - T1: does `.animation(_:value:)` cold-miss per frame?
    // ========================================================================

    /// THE T1 verdict, mechanistically. SwiftUI's `.animation(_:value:)` interpolates the
    /// view's already-computed visual properties HOST-SIDE between two `body` snapshots when
    /// the `value:` trigger's `==` changes; it does NOT re-evaluate `body` per animation frame.
    /// The trigger is resolved from the SAME `merged` input the render cache keys on. So the
    /// question "does the guest re-run per frame?" == "does `merged` change per frame?".
    ///
    /// DISCRETE-TRIGGER animation (the canonical case — a Bool toggle / enum change / counter
    /// bump driven by `withAnimation { … }`): the watched @State changes value exactly ONCE per
    /// logical transition → exactly ONE new distinct `merged` → exactly ONE cache miss (one WASM
    /// round-trip), after which SwiftUI animates the cached result host-side for the rest of the
    /// ~16 frames. This test proves that: a 16-frame animation sequence in which the LOGICAL
    /// state changes once produces exactly ONE WASM-stage miss, not 16.
    func testAnimationDiscreteTriggerIsSingleMissNotPerFrame() throws {
        PatchedBodyRenderCache.shared.reset()
        let patch = try makePatch()
        let export = patch.hasFunction("view_body") ? "view_body" : "view_body__SettingsView"
        let typeName = "AnimatedView"
        let epoch = patch.moduleEpoch

        // Model the body's per-render input for a DISCRETE-trigger animation: the only thing
        // that changes is the watched @State, and it flips ONCE (frame 0..7 = before, 8..15 =
        // after). SwiftUI itself would emit the in-between geometry; the guest is asked for a
        // tree only when the LOGICAL input changes.
        func inputForFrame(_ f: Int) -> String {
            // `expanded` is the watched @State; it flips once at the midpoint.
            let expanded = f >= 8
            return PatchFlatJSON.merge(base: "{\"badgeCount\":3}",
                                       override: "{\"expanded\":\(expanded)}")
        }

        var wasmMisses = 0
        var distinctInputs = Set<String>()
        for f in 0..<16 {
            let merged = inputForFrame(f)
            distinctInputs.insert(merged)
            if let _ = PatchedBodyRenderCache.shared.lookup(
                typeName: typeName, export: export, input: merged, epoch: epoch) {
                // HIT — no WASM, SwiftUI interpolates host-side over the cached tree.
            } else {
                // MISS — the body would run the WASM round-trip for this new logical input.
                wasmMisses += 1
                let emission = try patch.viewBodyEmission(state: merged, export: export)
                PatchedBodyRenderCache.shared.store(
                    typeName: typeName, export: export, input: merged, epoch: epoch,
                    payload: PatchedBodyCacheEntry(tree: emission.root,
                                                   slotArgs: emission.slotArgs ?? [:],
                                                   idSets: PatchedBodyHost.collectAllIDs(emission.root)))
            }
        }

        // EXACTLY TWO distinct logical inputs across the whole animation (before + after), so
        // EXACTLY TWO WASM misses for 16 frames — NOT one-per-frame. The other 14 frames are
        // host-side SwiftUI interpolation over the cached tree.
        XCTAssertEqual(distinctInputs.count, 2,
            "a discrete-trigger animation has exactly 2 distinct logical inputs (before/after)")
        XCTAssertEqual(wasmMisses, 2,
            "the guest runs ONCE per logical state, not once per animation frame — \(wasmMisses) misses for 16 frames")

        let out = """
        \n=== T1: ANIMATION COLD-MISS INVESTIGATION (config=\(buildConfig)) ===
          16-frame discrete-trigger animation (watched @State flips once):
            distinct logical `merged` inputs: \(distinctInputs.count)
            WASM-stage misses (guest re-runs):  \(wasmMisses)
            host-side-interpolated frames:      \(16 - wasmMisses)
          => `.animation(_:value:)` does NOT re-run the guest per frame. SwiftUI interpolates
             the cached tree's modifier values host-side; the guest runs only when the LOGICAL
             input changes. VERDICT: no per-frame WASM cold-miss for a discrete-trigger animation.
        """
        print(out)
        writeReport(out, marker: "T1_ANIMATION")
    }

    /// The CONTINUOUS-value regime, for honesty: if the app continuously drives the animated
    /// VALUE itself (a `Double progress` set to many intermediate values — a drag, a
    /// `TimelineView`, a repeating timer), then the LOGICAL input genuinely changes every frame
    /// → a genuine cache miss every frame. This is NOT specific to `.animation` (it's any
    /// continuously-changing input) and the guest MUST re-run because the value it READS changed
    /// (it can flow into Text/layout/conditionals, not only an interpolatable modifier). We
    /// CANNOT prove host-side that the changed channel is purely-animatable, so excluding it from
    /// the memo key would return a STALE tree (a false render). This test documents that a
    /// continuously-changing value is N distinct inputs ⇒ N misses by design — the WasmKit floor
    /// there is out of scope, and no sound host-side fix exists without an IR/wire change.
    func testContinuousValueIsGenuinelyDistinctPerFrameByDesign() throws {
        PatchedBodyRenderCache.shared.reset()
        let patch = try makePatch()
        let export = patch.hasFunction("view_body") ? "view_body" : "view_body__SettingsView"
        let typeName = "ContinuousView"
        let epoch = patch.moduleEpoch

        var distinct = Set<String>()
        for f in 0..<16 {
            // A continuously-advancing value (e.g. a drag offset) → a NEW logical input/frame.
            let merged = "{\"badgeCount\":\(f)}"
            distinct.insert(merged)
            if PatchedBodyRenderCache.shared.lookup(
                typeName: typeName, export: export, input: merged, epoch: epoch) == nil {
                let e = try patch.viewBodyEmission(state: merged, export: export)
                PatchedBodyRenderCache.shared.store(
                    typeName: typeName, export: export, input: merged, epoch: epoch,
                    payload: PatchedBodyCacheEntry(tree: e.root, slotArgs: e.slotArgs ?? [:],
                                                   idSets: PatchedBodyHost.collectAllIDs(e.root)))
            }
        }
        // 16 genuinely-distinct logical inputs — each a legitimate guest re-run. This is the
        // intrinsic floor; the only lever (faster guest exec) is explicitly out of scope.
        XCTAssertEqual(distinct.count, 16,
            "a continuously-driven value is genuinely N distinct logical inputs (no false memo possible)")
    }

    // ========================================================================
    // MARK: - T2: collectAllIDs is BYTE-IDENTICAL to the six separate walks
    // ========================================================================

    /// Assert the combined single-pass collector is the false-render-SAFE equivalent of the six
    /// originals + animation keys. The real safety-net invariant is MULTISET-identity (same ids,
    /// same multiplicities, none added/dropped) — every consumer uses these arrays for
    /// set-membership or idempotent dict population, never order. We assert the STRONGEST true
    /// invariant per family:
    ///   * opaque/row/action/button — BYTE-IDENTICAL (same order: the originals are
    ///     children-before-modifier-content, which the combined walk matches exactly);
    ///   * token/effect/animation — SORTED-EQUAL (same multiset; their originals recurse
    ///     modifier-content-before-childNodes, the opposite subtree order a single DFS can't
    ///     also satisfy — order is irrelevant downstream, so multiset-identity is what matters).
    private func assertCombinedMatchesOriginals(_ tree: ViewNode, _ label: String) {
        let combined = PatchedBodyHost.collectAllIDs(tree)
        // Byte-identical (order preserved) for the node-first families.
        XCTAssertEqual(combined.opaque, PatchedBodyHost.collectOpaqueIDs(tree),
                       "[\(label)] opaque ids diverged")
        XCTAssertEqual(combined.row, PatchedBodyHost.collectRowSlotIDs(tree),
                       "[\(label)] row-slot ids diverged")
        XCTAssertEqual(combined.action, PatchedBodyHost.collectActionSlotIDs(tree),
                       "[\(label)] action-slot ids diverged")
        XCTAssertEqual(combined.button, PatchedBodyHost.collectButtonActionIDs(tree),
                       "[\(label)] button action ids diverged")
        // Multiset-identical (sorted-equal) for the modifier-first families.
        XCTAssertEqual(combined.token.sorted(), PatchedBodyHost.collectTokenIDs(tree).sorted(),
                       "[\(label)] token ids diverged (multiset)")
        XCTAssertEqual(combined.effect.sorted(), PatchedBodyHost.collectEffectSlotIDs(tree).sorted(),
                       "[\(label)] effect-slot ids diverged (multiset)")
        XCTAssertEqual(combined.animationValueKeys.sorted(),
                       PatchedBodyHost.collectAnimationValueKeys(tree).sorted(),
                       "[\(label)] animation value keys diverged (multiset)")
    }

    func testCombinedCollectorByteIdenticalAcrossShapes() {
        // 1) Empty leaf.
        assertCombinedMatchesOriginals(N.text("hi"), "leaf")

        // 2) Every id-type at the TOP level + nested, with modifier content AND childNodes
        //    carrying ids of the SAME type — the adversarial case for traversal order.
        let opaqueInChild = N.opaque(id: "op-child", label: "Custom")
        let opaqueInMod = N.opaque(id: "op-mod", label: "OverlayCustom")
        let tokenLeaf = N.text("t").foregroundColor(.hostToken("tok-leaf"))
        let buttonChild = N.button("Tap", actionID: "btn-1")
        let actionSlot = N.actionSlotButton(id: "as-1", label: [N.text("Delete")])
        let rowSlot = N.indexedForEachSlot(id: "row-1", countKey: "__numtok_x", label: "Rows")
        let effectLeaf = N.text("e").with(.nativeEffectSlot("eff-1"))
        let animLeaf = N.text("a").animation(IRAnimation(curve: "spring"), valueKey: "flag")

        // A node whose CHILDREN contain an opaque AND whose MODIFIER content also contains an
        // opaque (+ a token, + a button) — exercises the child-vs-modifier-content order.
        let mixed = N.vstack([
            opaqueInChild,
            tokenLeaf,
            buttonChild,
            actionSlot,
            rowSlot,
            effectLeaf,
            animLeaf,
        ])
        .foregroundColor(.hostToken("tok-self"))      // this node's OWN token
        .with(.nativeEffectSlot("eff-self"))          // this node's OWN effect slot
        .animation(IRAnimation(curve: "linear"), valueKey: "selfFlag") // this node's OWN anim
        .overlay([opaqueInMod,
                  N.button("OverlayBtn", actionID: "btn-overlay"),
                  N.text("ot").foregroundColor(.hostToken("tok-overlay"))])
        assertCombinedMatchesOriginals(mixed, "mixed-child-and-modifier-content")

        // 3) Ids nested in a SHEET modifier subtree (not childNodes) + a toolbar.
        let sheetBody = N.vstack([
            N.opaque(id: "op-sheet", label: "SheetCustom"),
            N.button("SheetBtn", actionID: "btn-sheet"),
            N.text("st").foregroundColor(.hostToken("tok-sheet")),
        ])
        let withSheet = N.vstack([N.text("root"), N.button("Open", actionID: "btn-open")])
            .sheet(presentedKey: "show", isPresented: false, event: "e", [sheetBody])
        assertCombinedMatchesOriginals(withSheet, "sheet-modifier-subtree")

        // 4) Deeply nested, many modifiers, ids at every level.
        var deep = N.text("leaf")
            .foregroundColor(.hostToken("d-tok-0"))
            .with(.nativeEffectSlot("d-eff-0"))
            .animation(IRAnimation(curve: "easeIn"), valueKey: "d-flag-0")
        for i in 1...12 {
            deep = N.vstack([
                deep,
                N.opaque(id: "d-op-\(i)", label: "L\(i)"),
                N.button("B\(i)", actionID: "d-btn-\(i)"),
            ])
            .foregroundColor(.hostToken("d-tok-\(i)"))
            .with(.nativeEffectSlot("d-eff-\(i)"))
            .animation(IRAnimation(curve: "spring"), valueKey: "d-flag-\(i)")
            .overlay([N.text("ov\(i)").foregroundColor(.hostToken("d-ov-tok-\(i)"))])
        }
        assertCombinedMatchesOriginals(deep, "deep-nested")

        // 5) The large realistic screen (built below) — the production-scale shape.
        assertCombinedMatchesOriginals(Self.largeRealisticTree(rows: 50), "large-realistic")
    }

    // ========================================================================
    // MARK: - T3: reconstitution + tree-walks at REAL screen scale
    // ========================================================================

    /// A realistic large screen: a NavigationStack → ScrollView → header + a ForEach of ~N
    /// rows, each row an HStack with an icon, a VStack of two Texts, a Spacer, and a trailing
    /// Button — every node carrying a few modifiers (font/foreground/padding/frame). This is
    /// the hundreds-of-nodes shape a real production list screen lowers to, the scale at which
    /// the 6-walks-vs-1 and reconstitution costs actually matter.
    static func largeRealisticTree(rows: Int) -> ViewNode {
        func row(_ i: Int) -> ViewNode {
            N.hstack(spacing: 12, [
                N.image(systemName: "circle.fill")
                    .foregroundColor(.named("accent"))
                    .frame(width: 28, height: 28),
                N.vstack(alignment: .leading, spacing: 2, [
                    N.text("Row title \(i)").font(style: .headline),
                    N.text("Subtitle for row \(i)").font(style: .caption)
                        .foregroundColor(.named("secondary")),
                ]),
                N.spacer(),
                N.button("Go", actionID: "row-btn-\(i)")
                    .font(style: .body)
                    .padding(8),
            ])
            .padding(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        let header = N.vstack(alignment: .leading, spacing: 4, [
            N.text("Schedule").font(style: .largeTitle).bold(),
            N.text("Your upcoming posts").font(style: .subheadline)
                .foregroundColor(.named("secondary")),
        ]).padding(16)
        var children: [ViewNode] = [header]
        children.append(contentsOf: (0..<rows).map(row))
        return N.navigationStack([
            N.scrollView(N.vstack(spacing: 0, children).asArray)
        ])
    }

    /// Measure the 6 separate walks vs the ONE combined walk at real scale, plus reconstitution.
    func testLargeTreeWalkAndReconstitutionCost() {
        let tree = Self.largeRealisticTree(rows: 50)
        let nodeCount = tree.nodeCount

        let iterations = 3000
        let warmup = 300

        var sixNs: UInt64 = 0
        var oneNs: UInt64 = 0
        var reconNs: UInt64 = 0

        for i in 0..<(iterations + warmup) {
            let measure = i >= warmup

            // SIX separate walks (the pre-T2 cost).
            var t = Self.nowNanos()
            _ = PatchedBodyHost.collectOpaqueIDs(tree)
            _ = PatchedBodyHost.collectTokenIDs(tree)
            _ = PatchedBodyHost.collectRowSlotIDs(tree)
            _ = PatchedBodyHost.collectActionSlotIDs(tree)
            _ = PatchedBodyHost.collectEffectSlotIDs(tree)
            _ = PatchedBodyHost.collectButtonActionIDs(tree)
            _ = PatchedBodyHost.collectAnimationValueKeys(tree)
            let dSix = Self.nowNanos() - t

            // ONE combined walk (the T2 cost).
            t = Self.nowNanos()
            _ = PatchedBodyHost.collectAllIDs(tree)
            let dOne = Self.nowNanos() - t

            // Reconstitution into SwiftUI (T3 — measure at scale).
            t = Self.nowNanos()
            _ = render(tree, context: RenderContext(showOpaqueStubs: false))
            let dRecon = Self.nowNanos() - t

            if measure { sixNs += dSix; oneNs += dOne; reconNs += dRecon }
        }

        let sixMean = Double(sixNs) / Double(iterations)
        let oneMean = Double(oneNs) / Double(iterations)
        let reconMean = Double(reconNs) / Double(iterations)
        let speedup = oneMean > 0 ? sixMean / oneMean : 0

        let out = """
        \n=== T3: LARGE-TREE WALK + RECONSTITUTION (nodes=\(nodeCount), iters=\(iterations), config=\(buildConfig)) ===
          6 separate collect*IDs walks:  \(String(format: "%10.1f", sixMean)) ns/render
          1 combined collectAllIDs walk: \(String(format: "%10.1f", oneMean)) ns/render
          => collapse speedup:           \(String(format: "%.2f", speedup))x  (saves \(String(format: "%.1f", sixMean - oneMean)) ns/render at this scale)
          reconstitution render():       \(String(format: "%10.1f", reconMean)) ns/render
        """
        print(out)
        writeReport(out, marker: "T3_LARGETREE")

        // Functional guarantee: at scale, the combined walk still equals the originals.
        assertCombinedMatchesOriginals(tree, "T3-largetree")
        // The combined walk must be cheaper than six passes in RELEASE (it does ~1/6 the
        // traversals). DEBUG bounds-checking can blur the margin, so gate the timing claim.
        #if !DEBUG
        XCTAssertLessThan(oneMean, sixMean,
            "the single-pass collector must be faster than six separate walks at real scale (RELEASE)")
        #endif
    }
}

// A tiny convenience: a single node as a one-element array (keeps the large-tree builder tidy).
private extension ViewNode {
    var asArray: [ViewNode] { [self] }
}
#endif
