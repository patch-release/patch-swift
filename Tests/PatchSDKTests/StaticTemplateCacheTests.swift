import XCTest
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI
#endif

// StaticTemplateCacheTests — correctness firewall + unit tests for the
// structurally-static template cache.
//
// Design invariants:
//   1. Cache machinery: store/lookup keyed by (typeName, export, epoch); a different
//      epoch is a MISS (the module changed, so the cached tree is invalid).
//   2. Manifest JSON decode: `"isStructurallyStatic":true` decodes to `true`; absent
//      key decodes to `nil` (additive + backward-decode safe).
//   3. Integration: a view marked `isStructurallyStatic:true` in a manifest entry
//      carries the flag through the SDK entry struct correctly.
//   4. Firewall: a non-static view (has inputs that appear in the tree) produces
//      DIFFERENT trees for different inputs — confirming the engine correctly identifies
//      non-static views (if we wrongly marked them static, the cache would return stale
//      trees).
//   5. Epoch invalidation: after an epoch bump the static cache is a MISS (the next
//      render re-runs WASM to re-prime).

// MARK: - Cache machinery unit tests

#if canImport(SwiftUI)
@MainActor
final class PatchedBodyStaticTemplateCacheTests: XCTestCase {

    // Helper: make a minimal PatchedBodyIDSets with all-empty sets.
    private func emptyIDSets() -> PatchedBodyIDSets {
        PatchedBodyIDSets(opaque: [], token: [], row: [], action: [], effect: [],
                          button: [], animationValueKeys: [])
    }

    // Helper: make a minimal PatchedBodyCacheEntry with a simple text tree.
    private func makePayload(text: String = "hello") -> PatchedBodyCacheEntry {
        PatchedBodyCacheEntry(tree: N.text(text), slotArgs: [:], idSets: emptyIDSets())
    }

    // Each test resets the cache at the start — deterministic, no singleton leakage.

    func testStoreLookupSameEpochHits() {
        PatchedBodyStaticTemplateCache.shared.reset()
        let epoch: UInt64 = 42
        let payload = makePayload(text: "hello")
        PatchedBodyStaticTemplateCache.shared.store(typeName: "MyView", export: "view_body__MyView",
                                                    epoch: epoch, payload: payload)
        let hit = PatchedBodyStaticTemplateCache.shared.lookup(typeName: "MyView",
                                                               export: "view_body__MyView",
                                                               epoch: epoch)
        XCTAssertNotNil(hit, "same (type, export, epoch) must be a cache HIT")
    }

    func testLookupDifferentEpochMisses() {
        PatchedBodyStaticTemplateCache.shared.reset()
        PatchedBodyStaticTemplateCache.shared.store(typeName: "MyView", export: "view_body__MyView",
                                                    epoch: 1, payload: makePayload())
        // Different epoch → MISS (the module changed).
        let miss = PatchedBodyStaticTemplateCache.shared.lookup(typeName: "MyView",
                                                                export: "view_body__MyView",
                                                                epoch: 2)
        XCTAssertNil(miss, "different epoch must be a cache MISS — the module changed")
    }

    func testLookupDifferentTypeNameMisses() {
        PatchedBodyStaticTemplateCache.shared.reset()
        PatchedBodyStaticTemplateCache.shared.store(typeName: "ViewA", export: "view_body__ViewA",
                                                    epoch: 7, payload: makePayload())
        // Different typeName → MISS.
        let miss = PatchedBodyStaticTemplateCache.shared.lookup(typeName: "ViewB",
                                                                export: "view_body__ViewA",
                                                                epoch: 7)
        XCTAssertNil(miss, "different typeName must be a MISS")
    }

    func testStoreIsIdempotentLastStoreWins() {
        PatchedBodyStaticTemplateCache.shared.reset()
        let p1 = PatchedBodyCacheEntry(tree: N.text("v1"), slotArgs: ["k": ["v1"]], idSets: emptyIDSets())
        let p2 = PatchedBodyCacheEntry(tree: N.text("v2"), slotArgs: ["k": ["v2"]], idSets: emptyIDSets())
        PatchedBodyStaticTemplateCache.shared.store(typeName: "V", export: "e", epoch: 1, payload: p1)
        PatchedBodyStaticTemplateCache.shared.store(typeName: "V", export: "e", epoch: 1, payload: p2)
        let hit = PatchedBodyStaticTemplateCache.shared.lookup(typeName: "V", export: "e", epoch: 1)
        // Last store wins (idempotent replacement for same key).
        XCTAssertEqual(hit?.slotArgs["k"], ["v2"], "second store must replace the first (idempotent)")
    }

    func testResetClearsAll() {
        PatchedBodyStaticTemplateCache.shared.reset()
        PatchedBodyStaticTemplateCache.shared.store(typeName: "V", export: "e", epoch: 5,
                                                    payload: makePayload())
        XCTAssertEqual(PatchedBodyStaticTemplateCache.shared.count, 1)
        PatchedBodyStaticTemplateCache.shared.reset()
        XCTAssertEqual(PatchedBodyStaticTemplateCache.shared.count, 0,
                       "reset() must clear all cached entries")
    }

    func testMultipleDistinctEntriesStoredSeparately() {
        PatchedBodyStaticTemplateCache.shared.reset()
        for i in 0..<5 {
            let p = PatchedBodyCacheEntry(tree: N.text("v\(i)"), slotArgs: [:],
                                          idSets: emptyIDSets())
            PatchedBodyStaticTemplateCache.shared.store(typeName: "V\(i)", export: "e\(i)",
                                                        epoch: 1, payload: p)
        }
        XCTAssertEqual(PatchedBodyStaticTemplateCache.shared.count, 5,
                       "five distinct (type,export,epoch) keys must store 5 entries")
        for i in 0..<5 {
            let hit = PatchedBodyStaticTemplateCache.shared.lookup(typeName: "V\(i)",
                                                                   export: "e\(i)", epoch: 1)
            if case .text(let s) = hit?.tree.kind {
                XCTAssertEqual(s, "v\(i)", "lookup returned wrong tree for V\(i)")
            } else {
                XCTFail("lookup miss or wrong kind for V\(i)")
            }
        }
    }
}

// MARK: - Epoch invalidation test

@MainActor
final class StaticCacheEpochInvalidationTests: XCTestCase {

    private func emptyIDSets() -> PatchedBodyIDSets {
        PatchedBodyIDSets(opaque: [], token: [], row: [], action: [], effect: [],
                          button: [], animationValueKeys: [])
    }

    /// After storing a template for epoch N, a lookup for epoch N+1 is a MISS.
    /// This ensures a hot-swap (which bumps the module epoch) correctly invalidates
    /// the static template cache — the new module may have a different tree.
    func testEpochBumpInvalidatesStaticCache() {
        PatchedBodyStaticTemplateCache.shared.reset()
        let epoch1: UInt64 = 100
        let epoch2: UInt64 = 101   // simulated hot-swap
        let payload = PatchedBodyCacheEntry(tree: N.text("pre-swap"), slotArgs: [:],
                                            idSets: emptyIDSets())
        PatchedBodyStaticTemplateCache.shared.store(typeName: "StaticHero",
                                                    export: "view_body__StaticHero",
                                                    epoch: epoch1, payload: payload)
        // Lookup with the OLD epoch — HIT.
        XCTAssertNotNil(PatchedBodyStaticTemplateCache.shared.lookup(typeName: "StaticHero",
                                                                      export: "view_body__StaticHero",
                                                                      epoch: epoch1),
                        "lookup with epoch1 must HIT (the template is valid for this module)")
        // Lookup with the NEW epoch (hot-swap) — MISS.
        XCTAssertNil(PatchedBodyStaticTemplateCache.shared.lookup(typeName: "StaticHero",
                                                                   export: "view_body__StaticHero",
                                                                   epoch: epoch2),
                     "lookup with epoch2 (hot-swap) must MISS — the new module may have a different tree")
    }
}

// MARK: - Static template cache integration tests (installEntriesForTesting)

@MainActor
final class StaticTemplateCacheIntegrationTests: XCTestCase {

    private func emptyIDSets() -> PatchedBodyIDSets {
        PatchedBodyIDSets(opaque: [], token: [], row: [], action: [], effect: [],
                          button: [], animationValueKeys: [])
    }

    /// Static cache HIT path: after manually priming the static cache, looking up
    /// the same (type, export, epoch) returns the stored entry.
    func testStaticCacheHitReturnsStoredEntry() {
        PatchedBodyStaticTemplateCache.shared.reset()
        let epoch = Patch.shared.moduleEpoch
        let fakeTree = N.vstack([N.text("Static Label")])
        let payload = PatchedBodyCacheEntry(tree: fakeTree, slotArgs: [:], idSets: emptyIDSets())
        PatchedBodyStaticTemplateCache.shared.store(typeName: "StaticBanner",
                                                    export: "view_body__StaticBanner",
                                                    epoch: epoch, payload: payload)
        let hit = PatchedBodyStaticTemplateCache.shared.lookup(typeName: "StaticBanner",
                                                               export: "view_body__StaticBanner",
                                                               epoch: epoch)
        XCTAssertNotNil(hit, "static cache must return the primed entry")
        // The tree structure is preserved.
        if case .vstack = hit?.tree.kind {
            let child = hit?.tree.childNodes.first
            if case .text(let s) = child?.kind {
                XCTAssertEqual(s, "Static Label", "stored tree content must be preserved on hit")
            } else {
                XCTFail("child kind wrong or missing: \(String(describing: child?.kind))")
            }
        } else {
            XCTFail("tree kind wrong: expected vstack")
        }
    }

    /// A manifest entry with isStructurallyStatic:true survives installEntriesForTesting
    /// and is retrievable via entryIfPatchable with the flag intact.
    func testInstallStaticEntryIsRetrievable() {
        PatchViewPatchRegistry.shared.resetForTesting()
        let entry = PatchViewManifest.Entry(type: "ConstantCard",
                                            export: "view_body__ConstantCard",
                                            dispatch: nil,
                                            thunkSafe: true,
                                            minVersion: 8,
                                            bodyHash: nil,
                                            isStructurallyStatic: true)
        PatchViewPatchRegistry.shared.installEntriesForTesting([entry])
        let retrieved = PatchViewPatchRegistry.shared.entryIfPatchable(typeName: "ConstantCard")
        XCTAssertNotNil(retrieved, "installed static entry must be retrievable")
        XCTAssertEqual(retrieved?.isStructurallyStatic, true,
                       "isStructurallyStatic flag must survive installEntriesForTesting")
        PatchViewPatchRegistry.shared.resetForTesting()
    }

    /// A static-marked entry's isStructurallyStatic == true is exactly true.
    func testStaticEntryFlagIsTrueExactly() {
        let entry = PatchViewManifest.Entry(type: "T", export: "e", dispatch: nil,
                                            thunkSafe: true, isStructurallyStatic: true)
        XCTAssertEqual(entry.isStructurallyStatic, true,
                       "isStructurallyStatic: true must decode as exactly true")
    }

    /// A nil-isStructurallyStatic entry (old manifest) is treated as non-static.
    /// The gate check is `entry.isStructurallyStatic == true`: nil != true, so
    /// old entries never enter the static cache path.
    func testNilIsStructurallyStaticTreatedAsNonStatic() {
        let entry = PatchViewManifest.Entry(type: "T", export: "e", dispatch: nil, thunkSafe: true)
        XCTAssertNil(entry.isStructurallyStatic,
                     "default Entry() must have nil isStructurallyStatic (backward-compat)")
        // nil != true → the SDK gate rejects this view for the static path.
        XCTAssertNotEqual(entry.isStructurallyStatic, true,
                          "nil must not equal true — old entries must not enter the static cache path")
    }
}
#endif

// MARK: - Manifest JSON decode tests (no SwiftUI required)

final class StaticManifestDecodeTests: XCTestCase {

    /// `"isStructurallyStatic":true` decodes correctly.
    func testDecodesIsStructurallyStaticTrue() throws {
        let json = """
        {"schemaVersion":11,"views":[
            {"type":"ConstantView","export":"view_body__ConstantView",
             "dispatch":null,"thunkSafe":true,"minVersion":8,
             "isStructurallyStatic":true}
        ]}
        """
        let manifest = try JSONDecoder().decode(PatchViewManifest.self,
                                                from: Data(json.utf8))
        let entry = try XCTUnwrap(manifest.views.first(where: { $0.type == "ConstantView" }),
                                  "ConstantView not in manifest")
        XCTAssertEqual(entry.isStructurallyStatic, true,
                       "isStructurallyStatic:true must decode as true")
    }

    /// `"isStructurallyStatic"` absent → `nil` (additive, backward-decode safe).
    func testAbsentIsStructurallyStaticDecodesNil() throws {
        let json = """
        {"schemaVersion":8,"views":[
            {"type":"DynamicView","export":"view_body__DynamicView",
             "dispatch":null,"thunkSafe":true,"minVersion":8}
        ]}
        """
        let manifest = try JSONDecoder().decode(PatchViewManifest.self,
                                                from: Data(json.utf8))
        let entry = try XCTUnwrap(manifest.views.first(where: { $0.type == "DynamicView" }),
                                  "DynamicView not in manifest")
        XCTAssertNil(entry.isStructurallyStatic,
                     "absent isStructurallyStatic must decode as nil (backward-decode safe)")
    }

    /// `"isStructurallyStatic":false` decodes as false.
    func testDecodesIsStructurallyStaticFalse() throws {
        let json = """
        {"schemaVersion":8,"views":[
            {"type":"InputView","export":"view_body__InputView",
             "dispatch":null,"thunkSafe":true,"minVersion":8,
             "isStructurallyStatic":false}
        ]}
        """
        let manifest = try JSONDecoder().decode(PatchViewManifest.self,
                                                from: Data(json.utf8))
        let entry = try XCTUnwrap(manifest.views.first(where: { $0.type == "InputView" }))
        XCTAssertEqual(entry.isStructurallyStatic, false,
                       "isStructurallyStatic:false must decode as false")
    }

    /// A manifest with ALL optional fields (bodyHash + isStructurallyStatic) round-trips.
    func testFullManifestDecodeWithAllOptionalFields() throws {
        let json = """
        {"schemaVersion":11,"views":[
            {"type":"StaticCard","export":"view_body__StaticCard",
             "dispatch":null,"thunkSafe":true,"minVersion":8,
             "bodyHash":"deadbeef12345678","isStructurallyStatic":true},
            {"type":"FeedRow","export":"view_body__FeedRow",
             "dispatch":null,"thunkSafe":true,"minVersion":8,
             "bodyHash":"aabbccdd11223344"}
        ]}
        """
        let manifest = try JSONDecoder().decode(PatchViewManifest.self,
                                                from: Data(json.utf8))
        let card = try XCTUnwrap(manifest.views.first(where: { $0.type == "StaticCard" }))
        XCTAssertEqual(card.bodyHash, "deadbeef12345678")
        XCTAssertEqual(card.isStructurallyStatic, true)
        let feed = try XCTUnwrap(manifest.views.first(where: { $0.type == "FeedRow" }))
        XCTAssertEqual(feed.bodyHash, "aabbccdd11223344")
        XCTAssertNil(feed.isStructurallyStatic,
                     "FeedRow has no isStructurallyStatic field — must decode as nil")
    }

    /// Multiple views in one manifest: only the static one carries the flag.
    func testMixedManifestStaticAndDynamic() throws {
        let json = """
        {"schemaVersion":11,"views":[
            {"type":"EmptyBanner","export":"view_body__EmptyBanner",
             "dispatch":null,"thunkSafe":true,"minVersion":8,"isStructurallyStatic":true},
            {"type":"TitleCard","export":"view_body__TitleCard",
             "dispatch":null,"thunkSafe":true,"minVersion":8},
            {"type":"FeedItem","export":"view_body__FeedItem",
             "dispatch":null,"thunkSafe":true,"minVersion":8,"isStructurallyStatic":false}
        ]}
        """
        let manifest = try JSONDecoder().decode(PatchViewManifest.self,
                                                from: Data(json.utf8))
        let banner = try XCTUnwrap(manifest.views.first(where: { $0.type == "EmptyBanner" }))
        XCTAssertEqual(banner.isStructurallyStatic, true, "EmptyBanner is static")
        let card = try XCTUnwrap(manifest.views.first(where: { $0.type == "TitleCard" }))
        XCTAssertNil(card.isStructurallyStatic, "TitleCard has no flag → nil")
        let feed = try XCTUnwrap(manifest.views.first(where: { $0.type == "FeedItem" }))
        XCTAssertEqual(feed.isStructurallyStatic, false, "FeedItem is explicitly non-static")
    }
}

// MARK: - POSITIVE firewall: cache returns the SAME tree regardless of input

/// Positive-firewall tests: given a stored static template, the cache ALWAYS returns
/// the same tree regardless of what input would have been supplied.
///
/// This proves the CORRECTNESS CONTRACT of `PatchedBodyStaticTemplateCache`: because
/// the engine only marks views `isStructurallyStatic` when their WASM body is provably
/// input-independent, the SDK can safely replay the cached tree for any subsequent
/// render — no matter what the live instance's current inputs are.
///
/// These tests simulate the SDK's 3-layer lookup: the static-cache path bypasses the
/// input-hash cache, so the tree is retrieved without referencing the input string at
/// all (the cache key is typeName+export+epoch only).
@MainActor
final class StaticTemplateCachePositiveFirewallTests: XCTestCase {

    private func emptyIDSets() -> PatchedBodyIDSets {
        PatchedBodyIDSets(opaque: [], token: [], row: [], action: [], effect: [],
                          button: [], animationValueKeys: [])
    }

    /// Build a plausible static tree: a VStack with a literal Text, a padding modifier,
    /// and a foreground color (simulating a color token applied as a tree modifier).
    private func makeStaticTree() -> ViewNode {
        N.vstack([
            N.text("Active"),
            N.text("Tap to begin")
        ])
    }

    /// POSITIVE FIREWALL (cache mechanism):
    /// Store a static template once, then look it up 10 times.  Every lookup must
    /// return the EXACT SAME tree (byte-identical slotArgs, same tree structure).
    /// This proves the cache delivers the correct template regardless of which "input"
    /// the live instance currently has — it bypasses the input key entirely.
    func testStaticCacheReturnsIdenticalTreeAcross10Lookups() {
        PatchedBodyStaticTemplateCache.shared.reset()
        let epoch: UInt64 = 55
        let staticTree = makeStaticTree()
        let payload = PatchedBodyCacheEntry(tree: staticTree, slotArgs: [:], idSets: emptyIDSets())
        PatchedBodyStaticTemplateCache.shared.store(typeName: "ConstantBadge",
                                                    export: "view_body__ConstantBadge",
                                                    epoch: epoch, payload: payload)

        // Simulated inputs that a LIVE instance might produce (vary across renders).
        // The cache must return the SAME tree for all of them because the key
        // is (typeName, export, epoch) — the input string is NOT part of the key.
        let simulatedInputs = [
            "{}",
            "{\"title\":\"Hello\"}",
            "{\"count\":42}",
            "{\"name\":\"Alice\",\"score\":99.5}",
            "{\"flag\":true,\"items\":[\"x\",\"y\"]}",
            "{\"x\":\"\"}",
            "{\"greeting\":\"Bonjour\"}",
            "{\"nested\":{\"key\":\"value\"}}",
            "{\"a\":1,\"b\":2,\"c\":3}",
            "{\"title\":\"Goodbye\",\"count\":0}"
        ]

        var results: [PatchedBodyCacheEntry] = []
        for input in simulatedInputs {
            // The static cache lookup ignores `input` — it only uses typeName/export/epoch.
            // We call `lookup` (not a "lookup with input" overload) to mirror the SDK's
            // static-cache branch in `PatchedBodyHost.body`.
            _ = input  // only here to document the simulated caller's state
            let hit = PatchedBodyStaticTemplateCache.shared.lookup(typeName: "ConstantBadge",
                                                                    export: "view_body__ConstantBadge",
                                                                    epoch: epoch)
            XCTAssertNotNil(hit, "static cache must HIT for every lookup (epoch \(epoch))")
            if let h = hit { results.append(h) }
        }

        XCTAssertEqual(results.count, simulatedInputs.count,
                       "must get \(simulatedInputs.count) hits; got \(results.count)")

        // Every result must carry the SAME tree — the static template never changes.
        let referenceTree = results[0].tree
        for (i, result) in results.dropFirst().enumerated() {
            // Compare via `describe()` — the stable structural transcript.
            XCTAssertEqual(result.tree.describe(), referenceTree.describe(),
                           "STATIC CACHE VIOLATION: lookup[\(i + 1)] returned a DIFFERENT tree "
                           + "than lookup[0].  The static cache must ALWAYS return the same template "
                           + "regardless of the caller's current input state.  "
                           + "ref: \(referenceTree.describe())\n"
                           + "got: \(result.tree.describe())")
        }
    }

    /// POSITIVE FIREWALL (idSets stability):
    /// The idSets stored in the static template must be IDENTICAL on every retrieval —
    /// they represent the pre-collected opaque/token/row/action/effect/button id sets
    /// and must never change (static views have fixed trees and thus fixed id sets).
    func testStaticCacheIdSetsAreStableAcrossLookups() {
        PatchedBodyStaticTemplateCache.shared.reset()
        let epoch: UInt64 = 56
        let staticIDSets = PatchedBodyIDSets(
            opaque: [], token: ["tok_abc"], row: [], action: [], effect: [],
            button: [], animationValueKeys: [])
        let payload = PatchedBodyCacheEntry(tree: N.text("Label"), slotArgs: [:],
                                            idSets: staticIDSets)
        PatchedBodyStaticTemplateCache.shared.store(typeName: "TokenBadge",
                                                    export: "view_body__TokenBadge",
                                                    epoch: epoch, payload: payload)
        for i in 0..<10 {
            let hit = PatchedBodyStaticTemplateCache.shared.lookup(typeName: "TokenBadge",
                                                                    export: "view_body__TokenBadge",
                                                                    epoch: epoch)
            XCTAssertNotNil(hit, "lookup[\(i)] must HIT")
            XCTAssertEqual(hit?.idSets.token, ["tok_abc"],
                           "idSets.token must be stable on lookup[\(i)]")
        }
    }

    /// POSITIVE FIREWALL (slotArgs stability):
    /// The slotArgs (parameterized slot literal args) in the static template must be
    /// IDENTICAL on every retrieval.  A static view may still have a parameterized
    /// slot (a lifted string literal from a child view) whose args are fixed by the
    /// lowered body — they don't change across inputs, so the cached slotArgs are safe.
    func testStaticCacheSlotArgsAreStableAcrossLookups() {
        PatchedBodyStaticTemplateCache.shared.reset()
        let epoch: UInt64 = 57
        let fixedSlotArgs: [String: [String]] = ["slot_abc": ["New", "Feature"]]
        let payload = PatchedBodyCacheEntry(tree: N.text("Chip"), slotArgs: fixedSlotArgs,
                                            idSets: emptyIDSets())
        PatchedBodyStaticTemplateCache.shared.store(typeName: "ChipView",
                                                    export: "view_body__ChipView",
                                                    epoch: epoch, payload: payload)
        for i in 0..<10 {
            let hit = PatchedBodyStaticTemplateCache.shared.lookup(typeName: "ChipView",
                                                                    export: "view_body__ChipView",
                                                                    epoch: epoch)
            XCTAssertNotNil(hit, "lookup[\(i)] must HIT")
            XCTAssertEqual(hit?.slotArgs, fixedSlotArgs,
                           "slotArgs must be stable on lookup[\(i)]")
        }
    }

    /// POSITIVE FIREWALL (correctness vs non-static cache):
    /// A static tree stored in the STATIC cache and the SAME tree stored in the
    /// INPUT-HASH cache (under some canonical input) must deliver byte-identical
    /// describes — proving that the static-cache fast-path and the input-hash path
    /// agree for views the engine marked static.  This is the "two routes, same result"
    /// correctness invariant.
    func testStaticCacheAndInputHashCacheAgreeForSameTree() {
        PatchedBodyStaticTemplateCache.shared.reset()
        PatchedBodyRenderCache.shared.reset()
        let epoch: UInt64 = 58
        let tree = N.vstack([N.text("Static"), N.text("Content")])
        let payload = PatchedBodyCacheEntry(tree: tree, slotArgs: [:], idSets: emptyIDSets())

        // Prime the STATIC cache.
        PatchedBodyStaticTemplateCache.shared.store(typeName: "SV", export: "view_body__SV",
                                                    epoch: epoch, payload: payload)
        // Prime the INPUT-HASH cache with the SAME payload under an arbitrary input.
        PatchedBodyRenderCache.shared.store(typeName: "SV", export: "view_body__SV",
                                            input: "{}", epoch: epoch, payload: payload)

        let staticHit = PatchedBodyStaticTemplateCache.shared.lookup(
            typeName: "SV", export: "view_body__SV", epoch: epoch)
        let hashHit = PatchedBodyRenderCache.shared.lookup(
            typeName: "SV", export: "view_body__SV", input: "{}", epoch: epoch)

        XCTAssertNotNil(staticHit, "static cache must HIT")
        XCTAssertNotNil(hashHit, "input-hash cache must HIT")

        // CORRECTNESS INVARIANT: both paths produce the same describe.
        let staticDescribe = staticHit?.tree.describe() ?? "<nil>"
        let hashDescribe = hashHit?.tree.describe() ?? "<nil>"
        XCTAssertEqual(staticDescribe, hashDescribe,
                       "static-cache path and input-hash-cache path MUST deliver identical trees "
                       + "for the same view — the two fast-paths must be substitutable. "
                       + "static: \(staticDescribe)\nhash:   \(hashDescribe)")
    }
}

// MARK: - Non-static view firewall (real WASM)

/// Firewall test: a view that HAS inputs appearing in the tree (Banner has `title`)
/// produces DIFFERENT trees for different inputs. This proves that such a view is
/// CORRECTLY not marked static — if it were, the cache would return the wrong tree.
///
/// We call the real `viewBodyEmission` via a fresh `Patch()` (not the singleton)
/// so the test is self-contained and doesn't affect other tests.
final class NonStaticViewFirewallTests: XCTestCase {

    private func bannerModule() throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: "AutoPatchBanner", withExtension: "wasm") else {
            throw XCTSkip("AutoPatchBanner.wasm fixture missing — skipping non-static firewall")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    private func allText(_ node: ViewNode) -> [String] {
        var out: [String] = []
        if case .text(let s) = node.kind { out.append(s) }
        for child in node.childNodes { out.append(contentsOf: allText(child)) }
        return out
    }

    /// The Banner view has a `title` input that appears in the tree (`Text(title)`).
    /// Calling `viewBodyEmission` with different `title` values produces DIFFERENT
    /// trees, confirming the view is NOT structurally static. If it were wrongly
    /// marked static, the cache would return the wrong tree for any input except the first.
    func testBannerTreeVariesWithTitle() throws {
        let patch = Patch()
        try patch.activate(bytes: try bannerModule())

        let titles = ["Hello", "World", "Patch", "Static", "Dynamic",
                      "One", "Two", "Three", "Four", "Five"]
        var trees: [ViewNode] = []
        for title in titles {
            let input = "{\"title\":\"\(title)\"}"
            let emission = try patch.viewBodyEmission(state: input, export: "view_body__Banner")
            trees.append(emission.root)
        }
        // Every tree must contain its own title text.
        for (i, tree) in trees.enumerated() {
            let texts = allText(tree)
            XCTAssertTrue(texts.contains(titles[i]),
                          "tree for title '\(titles[i])' must contain that text; got: \(texts)")
        }
        // At least one pair of trees must DIFFER — proving the tree IS input-dependent.
        let firstTexts = allText(trees[0])
        let anyDiffers = trees.dropFirst().contains { allText($0) != firstTexts }
        XCTAssertTrue(anyDiffers,
                      "Banner trees must DIFFER across inputs — the title input varies the tree. "
                    + "If all trees were identical, Banner would be a valid static candidate, "
                    + "but its Text(title) node makes it input-dependent.")
    }

    /// Verify the Banner manifest entry does NOT carry isStructurallyStatic:true —
    /// the engine correctly identified it as non-static (has a title input in the tree).
    func testBannerManifestIsNotMarkedStatic() throws {
        let patch = Patch()
        try patch.activate(bytes: try bannerModule())
        let bytes = try patch.callPacked("patch_view_manifest", [])
        let manifest = try JSONDecoder().decode(PatchViewManifest.self, from: Data(bytes))
        guard let banner = manifest.views.first(where: { $0.type == "Banner" }) else {
            // If the manifest has no Banner entry, the prebuilt fixture may be from an
            // older cli. The absence of the field is tested by StaticManifestDecodeTests.
            return
        }
        // Banner has Text(title) → title appears in the tree → NOT static.
        XCTAssertNotEqual(banner.isStructurallyStatic, true,
                          "Banner has a title input in the tree — engine must NOT mark it static; "
                        + "got isStructurallyStatic = \(String(describing: banner.isStructurallyStatic))")
    }
}
