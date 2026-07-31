// SPDX-License-Identifier: MIT

import XCTest
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI
#endif

// RenderMemoizationTests — P0 PERF CORRECTNESS GATE for the input-hash render cache.
// ==================================================================================
// The render cache (PatchedBodyRenderCache) skips the WASM invoke + JSON decode + the
// 6 collect*IDs tree walks on a byte-identical input. A STALE cache = WRONG UI, which
// is worse than slow — so these tests guard the false-render hazard directly:
//   (a) an UNCHANGED input on the 2nd render is a HIT and yields the SAME tree;
//   (b) a CHANGED input is a MISS → a DIFFERENT (fresh) tree (no stale reuse);
//   (c) a moduleEpoch bump invalidates → re-fetches from WASM (no cross-epoch stale tree);
//   (d) the LRU bound holds (the Nth+1 distinct input evicts the oldest).
// Plus a collision-safety test (hash bucket must compare the full string).
#if canImport(SwiftUI)
@MainActor
final class RenderMemoizationTests: XCTestCase {

    // MARK: - Fixtures (mirror RenderHotPathBenchmarkTests)

    struct RichInstance {
        var notificationsOn: Bool = true
        var badgeCount: Int = 3
        var displayName: String = "Ada"
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

    private func bodyExport(_ patch: Patch) -> String {
        patch.hasFunction("view_body") ? "view_body" : "view_body__SettingsView"
    }

    /// A small WASM-derived payload synthesized from a real tree, so the cache class
    /// tests work even without driving the full host. (idSets are exercised on the real
    /// integration path below.)
    private func payload(tree: ViewNode, slotArgs: [String: [String]] = [:]) -> PatchedBodyCacheEntry {
        PatchedBodyCacheEntry(
            tree: tree,
            slotArgs: slotArgs,
            idSets: PatchedBodyIDSets(opaque: [], token: [], row: [], action: [], effect: [], button: [], animationValueKeys: []))
    }

    // Each test resets the shared cache up-front. NOTE: we do NOT override `setUp()` —
    // XCTestCase.setUp() is nonisolated, so a synchronous override can't touch the
    // @MainActor `PatchedBodyRenderCache.shared`, and an `async` override trips Swift 6
    // strict-concurrency ("sending main actor-isolated XCTestCase"). The class is
    // @MainActor, so resetting at the top of each (MainActor-isolated) test method is
    // the proven-clean pattern — mirrors RenderHotPathBenchmarkTests.

    // MARK: - (a) Unchanged input → HIT → SAME tree

    func testUnchangedInputIsHitAndSameTree() throws {
        PatchedBodyRenderCache.shared.reset()
        let patch = try makePatch()
        let export = bodyExport(patch)
        let state = "" // guest defaults — deterministic
        let epoch = patch.moduleEpoch

        // First render: MISS — no entry yet.
        XCTAssertNil(PatchedBodyRenderCache.shared.lookup(
            typeName: "SettingsView", export: export, input: state, epoch: epoch),
            "first lookup must be a MISS")

        // Produce the WASM tree (as the body does on a miss) and store it.
        let emission = try patch.viewBodyEmission(state: state, export: export)
        let tree = emission.root
        PatchedBodyRenderCache.shared.store(
            typeName: "SettingsView", export: export, input: state, epoch: epoch,
            payload: payload(tree: tree, slotArgs: emission.slotArgs ?? [:]))

        // Second render with the SAME input: HIT, and the tree is byte-identical.
        let hit = PatchedBodyRenderCache.shared.lookup(
            typeName: "SettingsView", export: export, input: state, epoch: epoch)
        XCTAssertNotNil(hit, "identical input must be a cache HIT")
        XCTAssertEqual(hit!.tree, tree, "cache HIT must return the SAME tree the WASM emitted")

        // And it equals a FRESH WASM emission for the same input (determinism invariant #5).
        let fresh = try patch.viewBodyEmission(state: state, export: export).root
        XCTAssertEqual(hit!.tree, fresh, "cached tree must equal a fresh WASM tree for the same input")
    }

    // MARK: - (b) Changed input → MISS → DIFFERENT (fresh) tree

    func testChangedInputIsMissAndFreshTree() throws {
        PatchedBodyRenderCache.shared.reset()
        let patch = try makePatch()
        let export = bodyExport(patch)
        let epoch = patch.moduleEpoch

        // Seed the cache for input A.
        let inputA = "{\"badgeCount\":3}"
        let treeA = try patch.viewBodyEmission(state: inputA, export: export).root
        PatchedBodyRenderCache.shared.store(
            typeName: "SettingsView", export: export, input: inputA, epoch: epoch,
            payload: payload(tree: treeA))

        // A DIFFERENT input B is a MISS — must NOT return A's tree.
        let inputB = "{\"badgeCount\":99}"
        XCTAssertNil(PatchedBodyRenderCache.shared.lookup(
            typeName: "SettingsView", export: export, input: inputB, epoch: epoch),
            "a changed input must be a cache MISS (no stale reuse of input A's tree)")

        // The fresh tree for B is computed from WASM and (if it differs) differs from A.
        let treeB = try patch.viewBodyEmission(state: inputB, export: export).root
        // We don't require treeA != treeB (the fixture may ignore badgeCount), but the
        // POINT is the cache returned nil so B went to WASM — proven above. Store B and
        // confirm A and B are cached independently and each returns its OWN tree.
        PatchedBodyRenderCache.shared.store(
            typeName: "SettingsView", export: export, input: inputB, epoch: epoch,
            payload: payload(tree: treeB))
        XCTAssertEqual(PatchedBodyRenderCache.shared.lookup(
            typeName: "SettingsView", export: export, input: inputA, epoch: epoch)!.tree, treeA)
        XCTAssertEqual(PatchedBodyRenderCache.shared.lookup(
            typeName: "SettingsView", export: export, input: inputB, epoch: epoch)!.tree, treeB)
    }

    // MARK: - (c) moduleEpoch bump → invalidate → re-fetch (no cross-epoch stale tree)

    func testEpochBumpInvalidates() throws {
        PatchedBodyRenderCache.shared.reset()
        let export = "view_body"
        let typeName = "SettingsView"
        let tree1 = ViewNode(.text("epoch-1"))
        let tree2 = ViewNode(.text("epoch-2"))
        let input = "{\"x\":1}"

        // Store under epoch 1.
        PatchedBodyRenderCache.shared.store(
            typeName: typeName, export: export, input: input, epoch: 1, payload: payload(tree: tree1))
        XCTAssertEqual(PatchedBodyRenderCache.shared.lookup(
            typeName: typeName, export: export, input: input, epoch: 1)!.tree, tree1)

        // Looking up the SAME input under a NEW epoch must MISS (cross-epoch never reused).
        XCTAssertNil(PatchedBodyRenderCache.shared.lookup(
            typeName: typeName, export: export, input: input, epoch: 2),
            "a moduleEpoch bump must invalidate — no cross-epoch stale tree")

        // Storing under epoch 2 drops the stale epoch-1 entry (epoch-scoped).
        PatchedBodyRenderCache.shared.store(
            typeName: typeName, export: export, input: input, epoch: 2, payload: payload(tree: tree2))
        XCTAssertEqual(PatchedBodyRenderCache.shared.lookup(
            typeName: typeName, export: export, input: input, epoch: 2)!.tree, tree2,
            "epoch-2 lookup must get the fresh epoch-2 tree")
        // The old epoch is gone (not just shadowed).
        XCTAssertNil(PatchedBodyRenderCache.shared.lookup(
            typeName: typeName, export: export, input: input, epoch: 1),
            "epoch-1 entry must have been dropped when epoch-2 stored")
        XCTAssertEqual(PatchedBodyRenderCache.shared.entryCount(typeName: typeName, export: export), 1,
            "only the current-epoch entry should remain")
    }

    // MARK: - (d) LRU bound holds — Nth+1 distinct input evicts the oldest

    func testLRUBoundEvictsOldest() throws {
        PatchedBodyRenderCache.shared.reset()
        let export = "view_body"
        let typeName = "SettingsView"
        let cap = PatchedBodyRenderCache.capacityPerScope
        let epoch: UInt64 = 1

        // Insert cap+2 distinct inputs.
        for i in 0..<(cap + 2) {
            let input = "{\"i\":\(i)}"
            PatchedBodyRenderCache.shared.store(
                typeName: typeName, export: export, input: input, epoch: epoch,
                payload: payload(tree: ViewNode(.text("t\(i)"))))
        }
        // Count is bounded to the capacity.
        XCTAssertEqual(PatchedBodyRenderCache.shared.entryCount(typeName: typeName, export: export), cap,
            "cache must be bounded to capacityPerScope")
        // The two oldest (0,1) were evicted; the most-recent cap survive.
        XCTAssertNil(PatchedBodyRenderCache.shared.lookup(
            typeName: typeName, export: export, input: "{\"i\":0}", epoch: epoch),
            "oldest input must be evicted")
        XCTAssertNil(PatchedBodyRenderCache.shared.lookup(
            typeName: typeName, export: export, input: "{\"i\":1}", epoch: epoch),
            "2nd-oldest input must be evicted")
        for i in 2..<(cap + 2) {
            XCTAssertNotNil(PatchedBodyRenderCache.shared.lookup(
                typeName: typeName, export: export, input: "{\"i\":\(i)}", epoch: epoch),
                "recent input \(i) must survive")
        }
    }

    // MARK: - LRU recency: a HIT refreshes recency (keeps a hot input alive)

    func testLRURecencyOnHit() throws {
        PatchedBodyRenderCache.shared.reset()
        let export = "view_body"
        let typeName = "SettingsView"
        let cap = PatchedBodyRenderCache.capacityPerScope
        let epoch: UInt64 = 1

        for i in 0..<cap {
            PatchedBodyRenderCache.shared.store(
                typeName: typeName, export: export, input: "{\"i\":\(i)}", epoch: epoch,
                payload: payload(tree: ViewNode(.text("t\(i)"))))
        }
        // Touch input 0 (HIT) — it becomes most-recent, so it survives the next eviction.
        _ = PatchedBodyRenderCache.shared.lookup(
            typeName: typeName, export: export, input: "{\"i\":0}", epoch: epoch)
        // Insert a new input → evicts the now-oldest (input 1), NOT input 0.
        PatchedBodyRenderCache.shared.store(
            typeName: typeName, export: export, input: "{\"i\":new}", epoch: epoch,
            payload: payload(tree: ViewNode(.text("tnew"))))
        XCTAssertNotNil(PatchedBodyRenderCache.shared.lookup(
            typeName: typeName, export: export, input: "{\"i\":0}", epoch: epoch),
            "a HIT must refresh recency so the hot input survives")
        XCTAssertNil(PatchedBodyRenderCache.shared.lookup(
            typeName: typeName, export: export, input: "{\"i\":1}", epoch: epoch),
            "the least-recently-used input must be evicted")
    }

    // MARK: - Collision safety: the hash bucket compares the FULL string

    func testHashBucketComparesFullString() throws {
        PatchedBodyRenderCache.shared.reset()
        // We can't easily force a real hashValue collision, but we can prove the lookup
        // is gated on the EXACT input string: two different inputs never alias, and the
        // wrong-input lookup never returns the other's tree even if they shared a bucket.
        let export = "view_body"
        let typeName = "SettingsView"
        let epoch: UInt64 = 1
        let a = "{\"a\":1}"
        let b = "{\"b\":2}"
        let ta = ViewNode(.text("A"))
        let tb = ViewNode(.text("B"))
        PatchedBodyRenderCache.shared.store(typeName: typeName, export: export, input: a, epoch: epoch, payload: payload(tree: ta))
        PatchedBodyRenderCache.shared.store(typeName: typeName, export: export, input: b, epoch: epoch, payload: payload(tree: tb))
        XCTAssertEqual(PatchedBodyRenderCache.shared.lookup(typeName: typeName, export: export, input: a, epoch: epoch)!.tree, ta)
        XCTAssertEqual(PatchedBodyRenderCache.shared.lookup(typeName: typeName, export: export, input: b, epoch: epoch)!.tree, tb)
        // A never-stored input MISSes (no fuzzy/partial match).
        XCTAssertNil(PatchedBodyRenderCache.shared.lookup(typeName: typeName, export: export, input: "{\"c\":3}", epoch: epoch))
    }

    // MARK: - Scope isolation: different (typeName,export) never alias

    func testScopeIsolation() throws {
        PatchedBodyRenderCache.shared.reset()
        let epoch: UInt64 = 1
        let input = "{\"x\":1}"
        PatchedBodyRenderCache.shared.store(typeName: "A", export: "view_body", input: input, epoch: epoch, payload: payload(tree: ViewNode(.text("A"))))
        PatchedBodyRenderCache.shared.store(typeName: "B", export: "view_body", input: input, epoch: epoch, payload: payload(tree: ViewNode(.text("B"))))
        XCTAssertEqual(PatchedBodyRenderCache.shared.lookup(typeName: "A", export: "view_body", input: input, epoch: epoch)!.tree, ViewNode(.text("A")))
        XCTAssertEqual(PatchedBodyRenderCache.shared.lookup(typeName: "B", export: "view_body", input: input, epoch: epoch)!.tree, ViewNode(.text("B")))
        // Same typeName, DIFFERENT export → distinct scope (the geo-rebuild path differs by input,
        // not export, but two views with the same name and different exports must not alias).
        XCTAssertNil(PatchedBodyRenderCache.shared.lookup(typeName: "A", export: "view_body__Other", input: input, epoch: epoch))
    }
}
#endif
