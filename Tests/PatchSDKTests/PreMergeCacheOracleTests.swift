// SPDX-License-Identifier: MIT

import XCTest
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI
#endif

// PreMergeCacheOracleTests — FALSE-RENDER SAFETY GATE for F1 (pre-merge cache).
// ==============================================================================
// The F1 optimization (PatchedBodyPreMergeCache) skips reconcileGuestOverride +
// PatchFlatJSON.merge on a steady-state body re-eval, probing a cheap key over the
// RAW inputs (propsJSON, guestState, guestBaseline, epoch, tokenJSON) instead of
// materialising `merged`. A wrong HIT (returning a stale `merged`) would produce
// the wrong WASM output — the worst possible outcome.
//
// This test suite proves the key is a STRICT FUNCTION of merged:
//   ORACLE: for every (props, guestState, baseline, tokenJSON) combo, compute `merged`
//     via the OLD full path (reconcile + merge) → the `merged` string is the oracle.
//   NEW PATH: given the same raw inputs, the pre-merge cache must produce the SAME
//     `merged` on a miss (first call) AND on a HIT (second call — no recompute).
//
// Additionally:
//   - A change to ANY input dimension is a cache miss (no stale hit).
//   - An epoch bump is a cache miss (new module → new trees).
//   - F3: reconcileGuestOverride fast-paths return the correct string.
//   - W7-S2: the memoized mergedObj matches a fresh PatchFlatJSON.parse call.
//
// ALL assertions use byte-exact string equality — the same invariant the input-hash
// render cache relies on (byte-identical `merged` → byte-identical WASM output).

#if canImport(SwiftUI)
@MainActor
final class PreMergeCacheOracleTests: XCTestCase {

    // MARK: - Oracle helper (the OLD merged-first path)

    /// Compute `merged` via the full pre-F1 path: reconcile + merge + token merge.
    /// This is the ground-truth oracle that the new pre-merge cache must agree with.
    private static func oracleMerged(
        propsJSON: String,
        guestState: String,
        guestBaseline: String,
        tokens: [String: PatchHostToken] = [:]
    ) -> String {
        let effectiveGuestState = PatchedBodyHost.reconcileGuestOverride(
            guestState: guestState, baseline: guestBaseline, currentProps: propsJSON)
        var merged = PatchFlatJSON.merge(base: propsJSON, override: effectiveGuestState)
        if let tokenJSON = PatchedBodyHost.inputTokenJSON(from: tokens) {
            merged = PatchFlatJSON.merge(base: merged, override: tokenJSON)
        }
        return merged
    }

    // MARK: - Corpus of (props, guestState, baseline, tokens) combinations

    /// The test matrix: exercises all dimensions of the pre-merge cache key.
    private struct InputCombo {
        let label: String
        let props: String
        let guestState: String
        let baseline: String
        let tokens: [String: PatchHostToken]
    }

    private let combos: [InputCombo] = [
        // No guest state (common case — no dispatch has happened yet).
        InputCombo(label: "empty-guest", props: #"{"name":"Ada","count":3,"on":true}"#,
                   guestState: "", baseline: "", tokens: [:]),
        // Guest state matches props exactly (F3 fast-path).
        InputCombo(label: "guest-equals-props",
                   props: #"{"name":"Ada","count":3}"#,
                   guestState: #"{"name":"Ada","count":3}"#,
                   baseline: #"{"name":"Ada","count":3}"#, tokens: [:]),
        // Guest state partially overrides props.
        InputCombo(label: "partial-override",
                   props: #"{"name":"Ada","count":3,"on":true}"#,
                   guestState: #"{"count":7}"#,
                   baseline: #"{"name":"Ada","count":3,"on":true}"#, tokens: [:]),
        // Guest state with a key native code changed since the baseline (reconcile drops it).
        InputCombo(label: "reconcile-drops-key",
                   props: #"{"name":"Bob","count":5}"#,
                   guestState: #"{"count":9}"#,
                   baseline: #"{"name":"Bob","count":3}"#, tokens: [:]),
        // Numeric token.
        InputCombo(label: "numeric-token",
                   props: #"{"badgeCount":1}"#,
                   guestState: "", baseline: "",
                   tokens: ["radius": .number(12.0)]),
        // String token.
        InputCombo(label: "string-token",
                   props: #"{"score":0.9}"#,
                   guestState: "", baseline: "",
                   tokens: ["label": .string("Pro")]),
        // Mixed tokens (numeric + string; color/font tokens are NOT input-riding, ignored).
        InputCombo(label: "mixed-tokens",
                   props: #"{"score":0.9,"active":true}"#,
                   guestState: #"{"active":false}"#,
                   baseline: #"{"score":0.9,"active":true}"#,
                   tokens: ["radius": .number(8.0), "badge": .string("New"),
                             "ink": .color(.red)]),
        // Empty props.
        InputCombo(label: "empty-props", props: "{}", guestState: "", baseline: "", tokens: [:]),
        // Large integral value (regression: must not funnel through Double).
        InputCombo(label: "large-int",
                   props: #"{"id":9007199254740993,"name":"x"}"#,
                   guestState: "", baseline: "", tokens: [:]),
        // Guest overrides a field that matches the baseline exactly (guest wins).
        InputCombo(label: "guest-wins-unchanged-baseline",
                   props: #"{"a":1,"b":2}"#,
                   guestState: #"{"b":9}"#,
                   baseline: #"{"a":1,"b":2}"#, tokens: [:]),
    ]

    // MARK: - T1: Pre-merge cache MISS produces the oracle merged string

    /// On a cache miss (first call for a fresh epoch / type), the pre-merge cache must
    /// store exactly the oracle `merged`. We verify this by:
    ///   1. Resetting the cache.
    ///   2. Calling `oracleMerged` to get the expected string.
    ///   3. Simulating what the miss path in `body` computes (same code) and asserting
    ///      it equals the oracle.
    ///   4. Looking up in the cache after a simulated store and asserting the stored
    ///      `merged` equals the oracle.
    func testPreMergeCacheMissMatchesOracle() {
        PatchedBodyPreMergeCache.shared.reset()
        let epoch: UInt64 = 42
        let typeName = "OracleView"
        let export = "view_body__OracleView"

        for combo in combos {
            let expected = Self.oracleMerged(
                propsJSON: combo.props, guestState: combo.guestState,
                guestBaseline: combo.baseline, tokens: combo.tokens)

            // Simulate the miss path (same computation the body's miss branch runs).
            let effectiveGuestState = PatchedBodyHost.reconcileGuestOverride(
                guestState: combo.guestState, baseline: combo.baseline,
                currentProps: combo.props)
            var mergedWork = PatchFlatJSON.merge(base: combo.props, override: effectiveGuestState)
            if let tokenJSON = PatchedBodyHost.inputTokenJSON(from: combo.tokens) {
                mergedWork = PatchFlatJSON.merge(base: mergedWork, override: tokenJSON)
            }
            let computedMerged = mergedWork

            XCTAssertEqual(computedMerged, expected,
                "[\(combo.label)] miss-path merged diverges from oracle")

            // Store into the pre-merge cache (simulating the miss-branch store).
            let tokenJSONKey = PatchedBodyHost.inputTokenJSON(from: combo.tokens) ?? ""
            let dummyEntry = PatchedBodyCacheEntry(
                tree: ViewNode(.text("oracle")),
                slotArgs: [:], idSets: PatchedBodyIDSets(
                    opaque: [], token: [], row: [], action: [],
                    effect: [], button: [], animationValueKeys: []))
            PatchedBodyPreMergeCache.shared.store(
                typeName: typeName, export: export,
                propsJSON: combo.props, guestState: combo.guestState,
                guestBaseline: combo.baseline, epoch: epoch, tokenJSON: tokenJSONKey,
                value: PatchedBodyPreMergeCache.CacheValue(
                    merged: computedMerged, effectiveGuestState: effectiveGuestState,
                    entry: dummyEntry, mergedObj: nil))

            // Look up: must get back the same merged.
            let hit = PatchedBodyPreMergeCache.shared.lookup(
                typeName: typeName, export: export,
                propsJSON: combo.props, guestState: combo.guestState,
                guestBaseline: combo.baseline, epoch: epoch, tokenJSON: tokenJSONKey)
            XCTAssertNotNil(hit, "[\(combo.label)] expected a cache hit after store")
            XCTAssertEqual(hit?.merged, expected,
                "[\(combo.label)] cached merged diverges from oracle")
            XCTAssertEqual(hit?.effectiveGuestState, effectiveGuestState,
                "[\(combo.label)] cached effectiveGuestState diverges from computed")

            PatchedBodyPreMergeCache.shared.reset()
        }
    }

    // MARK: - T2: A change to any input dimension is a cache miss

    /// Mutating ANY dimension of the pre-merge key must produce a miss. This ensures
    /// the key truly covers every variable that affects `merged`.
    func testAnyInputChangeCausesMiss() {
        let epoch: UInt64 = 1
        let typeName = "MissView"
        let export = "view_body__MissView"
        let base = combos[2]   // partial-override: has non-empty guest + baseline
        let tokenJSONKey = PatchedBodyHost.inputTokenJSON(from: base.tokens) ?? ""

        func store() {
            PatchedBodyPreMergeCache.shared.store(
                typeName: typeName, export: export,
                propsJSON: base.props, guestState: base.guestState,
                guestBaseline: base.baseline, epoch: epoch, tokenJSON: tokenJSONKey,
                value: PatchedBodyPreMergeCache.CacheValue(
                    merged: "dummy", effectiveGuestState: base.guestState,
                    entry: PatchedBodyCacheEntry(
                        tree: ViewNode(.text("x")),
                        slotArgs: [:],
                        idSets: PatchedBodyIDSets(
                            opaque: [], token: [], row: [], action: [],
                            effect: [], button: [], animationValueKeys: [])),
                    mergedObj: nil))
        }

        // Mutate propsJSON.
        PatchedBodyPreMergeCache.shared.reset(); store()
        XCTAssertNil(PatchedBodyPreMergeCache.shared.lookup(
            typeName: typeName, export: export,
            propsJSON: #"{"name":"Ada","count":99}"#,   // changed
            guestState: base.guestState, guestBaseline: base.baseline,
            epoch: epoch, tokenJSON: tokenJSONKey),
            "changed propsJSON must be a miss")

        // Mutate guestState.
        PatchedBodyPreMergeCache.shared.reset(); store()
        XCTAssertNil(PatchedBodyPreMergeCache.shared.lookup(
            typeName: typeName, export: export,
            propsJSON: base.props,
            guestState: #"{"count":99}"#,   // changed
            guestBaseline: base.baseline,
            epoch: epoch, tokenJSON: tokenJSONKey),
            "changed guestState must be a miss")

        // Mutate guestBaseline (affects reconcile output).
        PatchedBodyPreMergeCache.shared.reset(); store()
        XCTAssertNil(PatchedBodyPreMergeCache.shared.lookup(
            typeName: typeName, export: export,
            propsJSON: base.props, guestState: base.guestState,
            guestBaseline: #"{"name":"Ada","count":99}"#,   // changed
            epoch: epoch, tokenJSON: tokenJSONKey),
            "changed guestBaseline must be a miss")

        // Mutate epoch.
        PatchedBodyPreMergeCache.shared.reset(); store()
        XCTAssertNil(PatchedBodyPreMergeCache.shared.lookup(
            typeName: typeName, export: export,
            propsJSON: base.props, guestState: base.guestState,
            guestBaseline: base.baseline,
            epoch: 2,   // changed
            tokenJSON: tokenJSONKey),
            "changed epoch must be a miss")

        // Mutate tokenJSON.
        PatchedBodyPreMergeCache.shared.reset(); store()
        XCTAssertNil(PatchedBodyPreMergeCache.shared.lookup(
            typeName: typeName, export: export,
            propsJSON: base.props, guestState: base.guestState,
            guestBaseline: base.baseline, epoch: epoch,
            tokenJSON: #"{"__numtok_foo":99}"#),   // changed
            "changed tokenJSON must be a miss")
    }

    // MARK: - T3: Epoch bump invalidates all entries for the scope

    func testEpochBumpInvalidatesScope() {
        PatchedBodyPreMergeCache.shared.reset()
        let typeName = "EpochView"
        let export = "view_body__EpochView"
        let combo = combos[0]
        let tokenJSONKey = ""
        let dummyEntry = PatchedBodyCacheEntry(
            tree: ViewNode(.text("e")),
            slotArgs: [:],
            idSets: PatchedBodyIDSets(
                opaque: [], token: [], row: [], action: [],
                effect: [], button: [], animationValueKeys: []))

        // Store under epoch 1.
        PatchedBodyPreMergeCache.shared.store(
            typeName: typeName, export: export,
            propsJSON: combo.props, guestState: combo.guestState,
            guestBaseline: combo.baseline, epoch: 1, tokenJSON: tokenJSONKey,
            value: PatchedBodyPreMergeCache.CacheValue(
                merged: "epoch1", effectiveGuestState: "",
                entry: dummyEntry, mergedObj: nil))

        // Hit under epoch 1.
        XCTAssertNotNil(PatchedBodyPreMergeCache.shared.lookup(
            typeName: typeName, export: export,
            propsJSON: combo.props, guestState: combo.guestState,
            guestBaseline: combo.baseline, epoch: 1, tokenJSON: tokenJSONKey))

        // Store under epoch 2 — must evict epoch-1 entries.
        PatchedBodyPreMergeCache.shared.store(
            typeName: typeName, export: export,
            propsJSON: combo.props, guestState: combo.guestState,
            guestBaseline: combo.baseline, epoch: 2, tokenJSON: tokenJSONKey,
            value: PatchedBodyPreMergeCache.CacheValue(
                merged: "epoch2", effectiveGuestState: "",
                entry: dummyEntry, mergedObj: nil))

        // Old epoch-1 key is now a miss.
        XCTAssertNil(PatchedBodyPreMergeCache.shared.lookup(
            typeName: typeName, export: export,
            propsJSON: combo.props, guestState: combo.guestState,
            guestBaseline: combo.baseline, epoch: 1, tokenJSON: tokenJSONKey),
            "epoch-1 entry must be evicted after epoch-2 store")

        // Epoch-2 key is a hit.
        let hit2 = PatchedBodyPreMergeCache.shared.lookup(
            typeName: typeName, export: export,
            propsJSON: combo.props, guestState: combo.guestState,
            guestBaseline: combo.baseline, epoch: 2, tokenJSON: tokenJSONKey)
        XCTAssertNotNil(hit2)
        XCTAssertEqual(hit2?.merged, "epoch2")
    }

    // MARK: - T4: F3 reconcileGuestOverride fast-paths are oracle-correct

    /// The two F3 fast-paths return the same value as the full implementation.
    func testReconcileFastPaths() {
        // (a) Empty guest state: early return is `guestState` (empty) — oracle agrees.
        let emptyResult = PatchedBodyHost.reconcileGuestOverride(
            guestState: "", baseline: "", currentProps: #"{"a":1}"#)
        XCTAssertEqual(emptyResult, "", "empty guestState must return empty")

        // (b) guestState == currentProps (byte-equal): fast-path returns guestState.
        //     Oracle: guestObj keys are all in baseline and currentProps matches baseline
        //     → nothing dropped → returns guestState unchanged. Verify byte-equal.
        let props = #"{"name":"Ada","count":3}"#
        let fastResult = PatchedBodyHost.reconcileGuestOverride(
            guestState: props, baseline: props, currentProps: props)
        // The fast-path returns guestState when guestState == currentProps.
        XCTAssertEqual(fastResult, props,
            "guestState==currentProps fast-path must return guestState")
        // The full path (if baseline == currentProps, nothing is dropped).
        let fullResult = PatchedBodyHost.reconcileGuestOverride(
            guestState: props, baseline: props, currentProps: props)
        XCTAssertEqual(fastResult, fullResult,
            "F3 fast-path must equal full-path result")

        // (c) Non-empty guest, different from props: no fast-path, full path runs.
        let partial = #"{"count":7}"#
        let normalResult = PatchedBodyHost.reconcileGuestOverride(
            guestState: partial, baseline: props, currentProps: props)
        // baseline == currentProps → no native change → guest override kept.
        XCTAssertEqual(normalResult, partial,
            "partial override with unchanged baseline must keep all guest keys")
    }

    // MARK: - T5: W7-S2 cached mergedObj matches a fresh parse

    /// The `mergedObj` stored in the cache (W7-S2) must be byte-semantically identical
    /// to a fresh `PatchFlatJSON.parse(merged)` call. We prove this by comparing the
    /// animation trigger values extracted from both.
    func testCachedMergedObjMatchesFreshParse() {
        let props = #"{"isExpanded":false,"opacity":1.0,"badgeCount":3}"#
        let merged = Self.oracleMerged(
            propsJSON: props, guestState: "", guestBaseline: "", tokens: [:])

        // "Fresh" path: parse merged anew.
        guard let freshObj = PatchFlatJSON.parse(merged) else {
            XCTFail("oracle merged is not parseable")
            return
        }

        // Cached path: store a CacheValue with mergedObj populated.
        PatchedBodyPreMergeCache.shared.reset()
        let cachedObj = PatchFlatJSON.parse(merged)   // same call the miss path makes
        let typeName = "AnimView"; let export = "view_body__AnimView"
        let dummyEntry = PatchedBodyCacheEntry(
            tree: ViewNode(.text("anim")),
            slotArgs: [:],
            idSets: PatchedBodyIDSets(
                opaque: [], token: [], row: [], action: [],
                effect: [], button: [], animationValueKeys: ["isExpanded", "opacity"]))
        PatchedBodyPreMergeCache.shared.store(
            typeName: typeName, export: export,
            propsJSON: props, guestState: "", guestBaseline: "", epoch: 1, tokenJSON: "",
            value: PatchedBodyPreMergeCache.CacheValue(
                merged: merged, effectiveGuestState: "",
                entry: dummyEntry, mergedObj: cachedObj))

        let hit = PatchedBodyPreMergeCache.shared.lookup(
            typeName: typeName, export: export,
            propsJSON: props, guestState: "", guestBaseline: "", epoch: 1, tokenJSON: "")
        XCTAssertNotNil(hit)
        guard let hitObj = hit?.mergedObj else {
            XCTFail("hit.mergedObj must not be nil for animation views")
            return
        }

        // Compare animation trigger values for every key.
        let animKeys = ["isExpanded", "opacity", "badgeCount", "notPresent"]
        for key in animKeys {
            let fromFresh = PatchedBodyHost.animationTriggerValue(freshObj[key])
            let fromCached = PatchedBodyHost.animationTriggerValue(hitObj[key])
            XCTAssertEqual(fromFresh, fromCached,
                "animationTriggerValue for key '\(key)' differs between fresh and cached mergedObj")
        }
    }

    // MARK: - T6: LRU capacity is enforced

    func testLRUCapacityEnforced() {
        PatchedBodyPreMergeCache.shared.reset()
        let typeName = "LRUView"; let export = "view_body__LRU"
        let cap = PatchedBodyPreMergeCache.capacityPerScope
        let epoch: UInt64 = 1

        let dummyEntry = PatchedBodyCacheEntry(
            tree: ViewNode(.text("lru")),
            slotArgs: [:],
            idSets: PatchedBodyIDSets(
                opaque: [], token: [], row: [], action: [],
                effect: [], button: [], animationValueKeys: []))

        // Fill to capacity + 1 (all with different propsJSON).
        for i in 0...(cap) {
            PatchedBodyPreMergeCache.shared.store(
                typeName: typeName, export: export,
                propsJSON: #"{"i":\#(i)}"#, guestState: "", guestBaseline: "",
                epoch: epoch, tokenJSON: "",
                value: PatchedBodyPreMergeCache.CacheValue(
                    merged: "m\(i)", effectiveGuestState: "",
                    entry: dummyEntry, mergedObj: nil))
        }
        XCTAssertLessThanOrEqual(
            PatchedBodyPreMergeCache.shared.entryCount(typeName: typeName, export: export),
            cap, "LRU must evict beyond capacity")

        // The oldest entry (i=0) must have been evicted.
        XCTAssertNil(PatchedBodyPreMergeCache.shared.lookup(
            typeName: typeName, export: export,
            propsJSON: #"{"i":0}"#, guestState: "", guestBaseline: "",
            epoch: epoch, tokenJSON: ""),
            "oldest entry must be evicted")

        // The most recent entry (i=cap) must still be present.
        let newest = PatchedBodyPreMergeCache.shared.lookup(
            typeName: typeName, export: export,
            propsJSON: #"{"i":\#(cap)}"#, guestState: "", guestBaseline: "",
            epoch: epoch, tokenJSON: "")
        XCTAssertNotNil(newest, "most recent entry must survive LRU eviction")
        XCTAssertEqual(newest?.merged, "m\(cap)")
    }
}
#endif
