// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import PatchViewIR
@testable import PatchSDK
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI
#endif

/// BUG-HUNT ROUND 9 — three independent defects, each of which breaks one of the SDK's
/// three hard invariants:
///
///  1. **Never render something different from what the developer wrote.** The token
///     demote-gate (`collectTokenIDs` / `collectAllIDs`) only scanned a hand-listed subset
///     of MODIFIERS for `ColorRef.hostToken(id)`, so a token in any other renderer-reachable
///     position slipped past the gate and `Renderer.color(_:)` painted `.primary`.
///  2. **A patch must never be silently dropped.** `activate()`/`hotSwap()` bumped
///     `moduleEpoch` without invalidating the cached `patch_view_manifest` bytes, so a body
///     evaluation landing in the (multi-ms) window pinned the PREVIOUS module's view entries
///     against the NEW epoch for the rest of that epoch.
///  3. **Never crash / never silently stop updating.** Brotli detection tested the WHOLE
///     download URL for a `.br` suffix, so any URL carrying a query (a signed GCS/S3 link, a
///     CDN cache-buster) skipped inflation and failed SHA-256 verification forever.
final class BugHuntSDK9Tests: XCTestCase {

    // MARK: - Shared helpers

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-bh9-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // =====================================================================================
    // MARK: - BUG 1 — the design-system TOKEN demote gate missed most token positions
    // =====================================================================================
    //
    // `Renderer.color(_:)` resolves `.hostToken(id)` from `RenderContext.tokens` and falls
    // back to `.primary` when the id is absent. That fallback is only safe because
    // `PatchedBodyHost` is supposed to pre-scan the tree for EVERY token id and demote the
    // whole view when one is uncovered. The scan missed:
    //
    //   * `NodeKind.color(.hostToken(id))` — a `Color` LEAF. `SwiftUIEmitter` emits exactly
    //     this for `Color.brandPrimary` / `Color("Brand")` / `Color(uiColor:)` / `Color(hex:)`
    //     (SwiftUIEmitter.swift `case "Color"` and the member-access path), i.e. the single
    //     most common design-system token position in a real app.
    //   * `.underline(color:)` / `.strikethrough(color:)` / `.listItemTint` /
    //     `.listRowSeparatorTint` / `.listSectionSeparatorTint` / `.colorMultiply`.
    //   * a token inside a GRADIENT stop, or the `IRShapeStyle.shadow` ShapeStyle form.
    //   * a Canvas draw-op's `IRShapeStyle`.
    //
    // USER IMPACT: the view renders with a BLACK/WHITE (`.primary`) fill where the brand
    // color belongs, instead of demoting to the developer's real native body.

    #if canImport(SwiftUI)

    /// The regression that matters most: a `Color` LEAF carrying a host token.
    @MainActor
    func testColorLeafHostTokenIsCollectedByTheDemoteGate() {
        let tree = N.vstack([
            N.text("Hi"),
            N.color(.hostToken("brand_bg")).frame(width: 40, height: 40)
        ])
        XCTAssertTrue(PatchedBodyHost.collectTokenIDs(tree).contains("brand_bg"),
                      "a `Color` leaf's host token must be gated — otherwise an unsupplied "
                      + "id renders `.primary` instead of demoting the view to native")
        XCTAssertTrue(PatchedBodyHost.collectAllIDs(tree).token.contains("brand_bg"),
                      "the combined single-pass collector must agree with collectTokenIDs")
    }

    /// Every remaining renderer-reachable token position. Each sub-case is a position where
    /// `Render.swift` calls `color(_:)` (and therefore would paint `.primary` on a miss).
    @MainActor
    func testEveryRendererReachableTokenPositionIsGated() {
        func ids(_ n: ViewNode) -> Set<String> { Set(PatchedBodyHost.collectTokenIDs(n)) }

        // Text decoration colors (Render.swift:372/373 + 1496/1501 both call `color($0)`).
        XCTAssertTrue(ids(N.text("x").underline(true, color: .hostToken("t_under")))
                        .contains("t_under"), "`.underline(color:)` token must be gated")
        XCTAssertTrue(ids(N.text("x").strikethrough(true, color: .hostToken("t_strike")))
                        .contains("t_strike"), "`.strikethrough(color:)` token must be gated")

        // List chrome tints (Render.swift:2009/2014/2016).
        XCTAssertTrue(ids(N.text("x").listItemTint(.hostToken("t_item")))
                        .contains("t_item"), "`.listItemTint` token must be gated")
        XCTAssertTrue(ids(ViewNode(.text("x"), modifiers: [.listRowSeparatorTint(.hostToken("t_rowsep"), edges: "all")]))
                        .contains("t_rowsep"), "`.listRowSeparatorTint` token must be gated")
        XCTAssertTrue(ids(ViewNode(.text("x"), modifiers: [.listSectionSeparatorTint(.hostToken("t_secsep"), edges: "all")]))
                        .contains("t_secsep"), "`.listSectionSeparatorTint` token must be gated")

        // Color effects (Render.swift:2048).
        XCTAssertTrue(ids(N.text("x").colorMultiply(.hostToken("t_mult")))
                        .contains("t_mult"), "`.colorMultiply` token must be gated")

        // A token nested in a GRADIENT stop (Render.swift:2642/3790 map every stop
        // through `color($0.color)`).
        let gradient = IRGradient(stops: [
            IRGradientStop(color: .named("clear"), location: 0),
            IRGradientStop(color: .hostToken("t_stop"), location: 1)
        ])
        XCTAssertTrue(ids(ViewNode(.shape(.capsule),
                                   modifiers: [.fill(.linearGradient(gradient, startPoint: .top, endPoint: .bottom),
                                                     eoFill: false)]))
                        .contains("t_stop"),
                      "a host token inside a gradient stop must be gated")

        // The ShapeStyle `.shadow` form's color.
        XCTAssertTrue(ids(ViewNode(.text("x"),
                                   modifiers: [.foregroundStyle([.shadow(IRShadowStyle(color: .hostToken("t_shadow"),
                                                                                       radius: 2))])]))
                        .contains("t_shadow"),
                      "a host token inside an IRShapeStyle.shadow must be gated")

        // A Canvas draw-op's ShapeStyle.
        let canvas = N.canvas([.fillPath(commands: [.addRect(x: 0, y: 0, width: 4, height: 4)],
                                         style: .color(.hostToken("t_canvas")))])
        XCTAssertTrue(ids(canvas).contains("t_canvas"),
                      "a host token in a Canvas draw op's style must be gated")
    }

    /// The gate must find tokens at ANY depth, including inside a MODIFIER content subtree
    /// (`.background { … }` / a sheet body) — that is the path a partially-covered patch
    /// takes, and the walker must agree in both collectors.
    @MainActor
    func testNestedColorLeafTokenIsGatedInModifierContent() {
        let tree = ViewNode(.text("row"), modifiers: [
            .backgroundContent(alignment: nil, content: [N.color(.hostToken("nested_tok"))])
        ])
        XCTAssertTrue(PatchedBodyHost.collectTokenIDs(tree).contains("nested_tok"))
        XCTAssertEqual(Set(PatchedBodyHost.collectAllIDs(tree).token),
                       Set(PatchedBodyHost.collectTokenIDs(tree)),
                       "the two collectors must never disagree — they are the same gate")
    }

    /// A tree with NO tokens must still collect nothing (the fix must not over-collect,
    /// which would demote views that render perfectly today).
    @MainActor
    func testTokenGateDoesNotOverCollect() {
        let tree = N.vstack([
            N.color(.named("blue")),
            N.text("x").underline(true, color: .rgba(IRColor(r: 1, g: 0, b: 0, a: 1))),
            N.text("y").colorMultiply(.named("red"))
        ])
        XCTAssertTrue(PatchedBodyHost.collectTokenIDs(tree).isEmpty,
                      "only `.hostToken` colors are tokens; a named/rgba color must not be gated")
    }

    #endif

    // =====================================================================================
    // MARK: - BUG 2 — a module swap left the PREVIOUS module's view manifest cached
    // =====================================================================================
    //
    // `activate()` swapped the module set and bumped `moduleEpoch` under `lock.write`, then
    // released the lock and only afterwards ran `prewarmViewBodyExports()` (which invokes
    // every `view_body__*` export — milliseconds of real work) to refill
    // `_cachedManifestBytes`. In that window `moduleEpoch` named the NEW module while
    // `cachedManifestBytes()` still returned the OLD module's manifest.
    //
    // `PatchViewPatchRegistry.syncWithModuleEpoch` reloads its entries ONLY when the epoch
    // CHANGES, and it prefers `cachedManifestBytes()`. A SwiftUI body evaluation landing in
    // the window therefore loaded the OLD entries and stamped them with the NEW epoch —
    // pinning them for the entire epoch.
    //
    // USER IMPACT: a view the new patch changed keeps the OLD `bodyHash`, so the
    // native-fast-path gate in `thunkBody` matches and returns nil — THE PATCH IS SILENTLY
    // NOT APPLIED. Stale `minVersion`/`minOS`/`isStructurallyStatic` mis-route other views.
    // Activation runs on a background queue while the UI renders, so the race is real.

    private func bannerModule() throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: "AutoPatchBanner", withExtension: "wasm") else {
            throw XCTSkip("AutoPatchBanner.wasm fixture missing")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    private func manifestlessModule() throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm") else {
            throw XCTSkip("MarshalFixture.release.wasm fixture missing")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    /// A thread-safe capture box for the value observed INSIDE the activation window.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [UInt8]??
        private var epoch: UInt64 = 0
        func set(_ v: [UInt8]?, epoch e: UInt64) { lock.lock(); value = .some(v); epoch = e; lock.unlock() }
        var captured: [UInt8]?? { lock.lock(); defer { lock.unlock() }; return value }
        var capturedEpoch: UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
    }

    /// THE INVARIANT: at no point between the epoch bump and the manifest refill may
    /// `cachedManifestBytes()` describe a module other than the active one. Clearing the
    /// cache inside the swap's critical section makes the window read `nil`, which makes
    /// the registry fall back to calling the LIVE module's manifest export.
    func testActivateNeverLeavesThePreviousModulesManifestCachedUnderTheNewEpoch() throws {
        let patch = Patch()
        try patch.activate(bytes: try bannerModule())

        let bannerManifest = patch.cachedManifestBytes()
        XCTAssertNotNil(bannerManifest, "the Banner fixture exports patch_view_manifest")
        let bannerEpoch = patch.moduleEpoch

        // Observe the state at the START of the post-swap prewarm — i.e. inside the window.
        let box = Box()
        patch._onPrewarmForTesting = { [weak patch] in
            guard let patch else { return }
            box.set(patch.cachedManifestBytes(), epoch: patch.moduleEpoch)
        }

        // Swap to a module with NO view manifest at all.
        try patch.activate(bytes: try manifestlessModule())
        patch._onPrewarmForTesting = nil

        let observed = try XCTUnwrap(box.captured, "prewarm hook did not fire")
        XCTAssertGreaterThan(box.capturedEpoch, bannerEpoch,
                             "the window is observed AFTER the epoch bump (that is the hazard)")
        XCTAssertNotEqual(observed, bannerManifest,
                          "STALE MANIFEST: the new epoch was visible while cachedManifestBytes() "
                          + "still returned the PREVIOUS module's manifest — a body eval in this "
                          + "window pins the old view entries (and their bodyHashes) for the whole "
                          + "epoch, silently dropping the patch")
        XCTAssertNil(observed,
                     "the cache must be INVALIDATED in the same critical section as the epoch bump")

        // And after activation settles the cache reflects the now-active (manifest-less) module.
        XCTAssertNil(patch.cachedManifestBytes())
    }

    /// The same invariant on the hot-swap commit path.
    func testHotSwapNeverLeavesThePreviousModulesManifestCachedUnderTheNewEpoch() throws {
        let patch = Patch()
        try patch.activate(bytes: try bannerModule())
        let bannerManifest = patch.cachedManifestBytes()
        XCTAssertNotNil(bannerManifest)

        let box = Box()
        patch._onPrewarmForTesting = { [weak patch] in
            guard let patch else { return }
            box.set(patch.cachedManifestBytes(), epoch: patch.moduleEpoch)
        }
        try patch.hotSwap(bytes: try manifestlessModule())
        patch._onPrewarmForTesting = nil

        let observed = try XCTUnwrap(box.captured, "prewarm hook did not fire on the hotSwap path")
        XCTAssertNotEqual(observed, bannerManifest,
                          "hotSwap must invalidate the manifest cache alongside the epoch bump")
        XCTAssertNil(observed)
    }

    /// Forward direction: activating a module that DOES ship a manifest still ends with that
    /// module's manifest cached (the fix must not disable the W5b pre-warm optimisation).
    func testActivationStillPrewarmsTheNewModulesManifest() throws {
        let patch = Patch()
        try patch.activate(bytes: try manifestlessModule())
        XCTAssertNil(patch.cachedManifestBytes())
        try patch.activate(bytes: try bannerModule())
        let cached = try XCTUnwrap(patch.cachedManifestBytes(),
                                   "the W5b pre-warm must still populate the cache after the fix")
        let manifest = try JSONDecoder().decode(PatchViewManifest.self, from: Data(cached))
        XCTAssertTrue(manifest.views.contains { $0.type == "Banner" })
    }

    // =====================================================================================
    // MARK: - BUG 3 — brotli detection broke on any URL carrying a query string
    // =====================================================================================
    //
    // `maybeDecompress` decided "is this brotli?" with `url.hasSuffix(".br")` over the WHOLE
    // URL string. The backend's `public_url` happens to be query-free today, but a signed
    // GCS/S3 URL (`…/module.wasm.br?X-Goog-Signature=…`), a CDN cache-buster (`?v=3`) or any
    // self-hosted backend's presigned link does NOT end in `.br` — so the compressed bytes
    // went straight to SHA-256 verification, never matched, and `fetchFull` threw
    // `hashMismatch`.
    //
    // USER IMPACT: the device rejects EVERY patch, forever and silently. The user simply
    // never receives updates; the dashboard sees a stream of `error` telemetry.

    func testBrotliDetectionIgnoresQueryAndFragment() {
        XCTAssertTrue(ModuleLoader.urlPathIndicatesBrotli("https://cdn/x/module.wasm.br"),
                      "the plain production shape must be unchanged")
        XCTAssertTrue(ModuleLoader.urlPathIndicatesBrotli(
            "https://storage.googleapis.com/b/module.wasm.br?X-Goog-Signature=deadbeef&X-Goog-Expires=900"),
                      "a SIGNED url still points at a brotli object")
        XCTAssertTrue(ModuleLoader.urlPathIndicatesBrotli("https://cdn/x/module.wasm.br?v=3"),
                      "a cache-buster query must not defeat brotli detection")
        XCTAssertTrue(ModuleLoader.urlPathIndicatesBrotli("https://cdn/x/module.wasm.br#frag"))
        // Must NOT over-trigger: an uncompressed module stays uncompressed.
        XCTAssertFalse(ModuleLoader.urlPathIndicatesBrotli("https://cdn/x/module.wasm"))
        XCTAssertFalse(ModuleLoader.urlPathIndicatesBrotli("https://cdn/x/module.wasm?q=a.br"),
                       "a `.br` that appears only in the QUERY is not a brotli object")
    }

    /// End-to-end through `fetchFull`: a brotli module served at a SIGNED url must inflate
    /// and verify, exactly as the query-free url does.
    func testSignedBrotliURLInflatesAndVerifies() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rawURL = try XCTUnwrap(Bundle.module.url(forResource: "diff_new", withExtension: "bin"))
        let brURL = try XCTUnwrap(Bundle.module.url(forResource: "diff_new", withExtension: "br"))
        let raw = try Data(contentsOf: rawURL)
        let compressed = try Data(contentsOf: brURL)
        let sha = SHA256Hash.hexString(of: raw)

        struct StubTransport: HTTPTransport {
            let body: Data
            func send(_ request: URLRequest) async throws -> (Data, Int) { (body, 200) }
        }
        let storage = try ModuleStorage(appKey: "bh9-brotli", baseDirectory: dir)
        let loader = ModuleLoader(storage: storage, transport: StubTransport(body: compressed))

        let signed = "https://storage.googleapis.com/bucket/modules/1.0.0/module.wasm.br"
            + "?X-Goog-Algorithm=GOOG4-RSA-SHA256&X-Goog-Expires=900&X-Goog-Signature=abc123"
        let fetched = try await loader.fetchFull(moduleURL: signed, expectedSHA: sha, sizeHint: raw.count)
        XCTAssertEqual(fetched, raw,
                       "a brotli module served at a SIGNED url must inflate before verification")
    }

    // =====================================================================================
    // MARK: - BUG 8 — `apiBaseURL: nil` did not actually disable remote update checks
    // =====================================================================================
    //
    // `PatchConfiguration.apiBaseURL` documents `nil` as "disable remote update checks
    // entirely", and `configure` replaces `_storage` unconditionally — but the update checker
    // was installed under `if let base = configuration.apiBaseURL`, so a RE-configure with
    // `nil` left the checker from the first call in place and the SDK kept polling the old
    // backend after the app explicitly turned remote checks off.

    func testReconfiguringWithNilAPIBaseDisablesTheUpdateChecker() {
        Patch.configure(.init(appKey: "bh9-cfg", apiBaseURL: URL(string: "https://api.test/api/v1")))
        XCTAssertNotNil(Patch.shared.updateChecker, "precondition: a base URL installs a checker")
        Patch.configure(.init(appKey: "bh9-cfg", apiBaseURL: nil))
        XCTAssertNil(Patch.shared.updateChecker,
                     "`apiBaseURL: nil` must DISABLE remote checks, not silently keep polling "
                     + "the previously configured backend")
    }

    // =====================================================================================
    // MARK: - BUG 9 — a rolled-back patch could come back through the staged-update path
    // =====================================================================================
    //
    // The imperative `checkForUpdate()` revert path clears `_pendingResponse`/`_staged`; the
    // auto-apply `checkAndApply()` one did not. An app using BOTH flows (auto-apply at launch
    // plus a "Download now / Reload" button) could have already STAGED the exact bytes the
    // server is now recalling — and those bytes survived the recall in memory, so the next
    // `reloadAsync()` re-activated the KNOWN-BAD module the rollback existed to remove.

    private struct RoutingTransport: HTTPTransport {
        let route: @Sendable (URLRequest) -> (Data, Int)
        func send(_ request: URLRequest) async throws -> (Data, Int) { route(request) }
    }

    func testRevertDropsStagedBytesSoARecalledPatchCannotBeReloaded() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = try manifestlessModule()
        let sha = SHA256Hash.hexString(of: Data(bytes))
        let apiBase = URL(string: "https://api.test/api/v1")!

        let storage = try ModuleStorage(appKey: "bh9-revert", baseDirectory: dir)
        try storage.installCurrent(version: "1.0.0", sha256: sha, bytes: bytes)

        // Phase 1 the backend offers 2.0.0; phase 2 it RECALLS it (revert:true).
        final class Phase: @unchecked Sendable {
            private let lock = NSLock()
            private var _reverting = false
            var reverting: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _reverting }
                set { lock.lock(); _reverting = newValue; lock.unlock() }
            }
        }
        let phase = Phase()
        // Serve the module from a file:// URL — `ModuleLoader` builds its own transport for
        // module downloads, so only file:// (or the real network) reaches it from a test.
        let moduleFile = dir.appendingPathComponent("module-2.0.0.wasm")
        try Data(bytes).write(to: moduleFile)
        let offer = try JSONEncoder().encode(UpdateCheckResponse(
            has_update: true, version: "2.0.0",
            module_url: moduleFile.absoluteString, sha256: sha, size: bytes.count))
        let recall = try JSONEncoder().encode(UpdateCheckResponse(has_update: false, revert: true))
        let transport = RoutingTransport { req in
            let p = req.url?.absoluteString ?? ""
            if p.hasSuffix("/modules/check") { return (phase.reverting ? recall : offer, 200) }
            if p.hasSuffix("/events") { return (Data(), 201) }
            if p.hasSuffix("module.wasm") { return (Data(bytes), 200) }
            return (Data(), 404)
        }

        let patch = Patch()
        patch.bridges.registerDefaults()
        patch.injectForTesting(
            configuration: PatchConfiguration(appKey: "bh9-revert", apiBaseURL: apiBase,
                                              fingerprint: "fp", deviceID: "dev",
                                              autoApply: false),
            storage: storage,
            checker: UpdateChecker(baseURL: apiBase, transport: transport))

        // Stage 2.0.0 through the imperative flow (the "Download now" button).
        let staged = try await patch.fetchUpdate()
        XCTAssertTrue(staged, "precondition: 2.0.0 stages")

        // The server now RECALLS 2.0.0 and the auto-apply path sees it.
        phase.reverting = true
        _ = await patch.checkAndApply()

        // The staged (recalled) bytes must be gone: a later "Reload" must find nothing.
        do {
            try await patch.reloadAsync()
            XCTFail("a RECALLED patch was re-activated from the staged bytes — the rollback "
                    + "directive must drop them")
        } catch let e as Patch.UpdateError {
            guard case .nothingStaged = e else {
                return XCTFail("expected .nothingStaged after a revert, got \(e)")
            }
        }
    }
}

#if canImport(SwiftUI)

// =========================================================================================
// MARK: - Host-level demotes (no WASM: the render caches are primed, as in
//         RenderCapabilityDemoteTests)
// =========================================================================================

@MainActor
final class BugHuntSDK9HostTests: XCTestCase {

    private let typeName = "BH9View"
    private var export: String { "view_body__\(typeName)" }

    private func entry(dispatch: String?) -> PatchViewManifest.Entry {
        PatchViewManifest.Entry(type: typeName, export: export, dispatch: dispatch,
                                thunkSafe: true, minVersion: 8)
    }

    private func prepare(_ e: PatchViewManifest.Entry) -> () -> Void {
        Patch.configure(.init(appKey: "test-bh9", apiBaseURL: nil))
        let savedOS = PatchViewPatchRegistry.runningOS
        PatchedBodyRenderCache.shared.reset()
        PatchedBodyPreMergeCache.shared.reset()
        PatchedBodyStaticTemplateCache.shared.reset()
        PatchViewPatchRegistry.shared.resetForTesting()
        PatchViewPatchRegistry.shared.installEntriesForTesting([e])
        return {
            PatchViewPatchRegistry.runningOS = savedOS
            PatchViewPatchRegistry.shared.resetForTesting()
            PatchedBodyRenderCache.shared.reset()
            PatchedBodyPreMergeCache.shared.reset()
            PatchedBodyStaticTemplateCache.shared.reset()
        }
    }

    /// Prime the pre-merge cache exactly as a first `PatchedBodyHost.body` eval would key it.
    private func primeHost(_ tree: ViewNode, entry e: PatchViewManifest.Entry, props: String = "{}") {
        let cacheEntry = PatchedBodyCacheEntry(tree: tree, slotArgs: [:],
                                               idSets: PatchedBodyHost.collectAllIDs(tree))
        PatchedBodyPreMergeCache.shared.store(
            typeName: typeName, export: e.export, propsJSON: props, guestState: "", guestBaseline: "",
            epoch: Patch.shared.moduleEpoch, tokenJSON: "",
            value: .init(merged: props, effectiveGuestState: "", entry: cacheEntry, mergedObj: nil))
    }

    private func settleDeferredDemotes() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: BUG 1, end to end — an unsupplied token DEMOTES instead of painting `.primary`

    /// A `Color` LEAF carrying a token the thunk does NOT supply must demote the whole view.
    /// Before the fix the id was invisible to the gate, so `Renderer.color(_:)` fell through
    /// to `?? .primary` and the app showed a BLACK/WHITE block where the brand color belongs.
    func testUnsuppliedColorLeafTokenDemotesTheView() async {
        let e = entry(dispatch: nil)
        let cleanup = prepare(e); defer { cleanup() }
        let tree = ViewNode(.vstack(alignment: nil, spacing: 0, children: [
            ViewNode(.text("Header")),
            ViewNode(.color(.hostToken("brand_bg")))
        ]))
        primeHost(tree, entry: e)
        // NO tokens supplied — exactly the "patch changed native token code not in this build" case.
        let host = PatchedBodyHost(typeName: typeName, entry: e, propsJSON: "{}", writebacks: [], tokens: [:])
        _ = host.body
        await settleDeferredDemotes()
        XCTAssertNil(PatchViewPatchRegistry.shared.entryIfPatchable(typeName: typeName),
                     "an unsupplied `Color` leaf token must demote the view to its native body, "
                     + "never render `.primary` in place of the brand color")
    }

    /// The positive control: the SAME tree with the token SUPPLIED keeps rendering patched.
    func testSuppliedColorLeafTokenKeepsTheViewPatched() async {
        let e = entry(dispatch: nil)
        let cleanup = prepare(e); defer { cleanup() }
        let tree = ViewNode(.vstack(alignment: nil, spacing: 0, children: [
            ViewNode(.text("Header")),
            ViewNode(.color(.hostToken("brand_bg")))
        ]))
        primeHost(tree, entry: e)
        let host = PatchedBodyHost(typeName: typeName, entry: e, propsJSON: "{}", writebacks: [],
                                   tokens: ["brand_bg": .color(.blue)])
        _ = host.body
        await settleDeferredDemotes()
        XCTAssertNotNil(PatchViewPatchRegistry.shared.entryIfPatchable(typeName: typeName),
                        "a covered token must NOT demote — the fix must not over-gate")
    }

    // MARK: BUG 4 — a lowered Button with no dispatch export was a DEAD button

    /// Buttons are wired to the guest ONLY inside `if let dispatchExport = entry.dispatch`.
    /// With `dispatch == nil` the renderer's `context.actions.action(for:) ?? {}` made every
    /// tap a silent no-op — a button that looks right and does nothing. That skew is
    /// reachable whenever the manifest ENTRY and the emitted TREE disagree about
    /// interactivity (a best-effort-merged PMOD, or a stale manifest). Demote instead.
    func testButtonWithoutADispatchExportDemotesRatherThanShippingADeadButton() async {
        let e = entry(dispatch: nil)
        let cleanup = prepare(e); defer { cleanup() }
        let tree = ViewNode(.vstack(alignment: nil, spacing: 0, children: [
            ViewNode(.button(actionID: "tap_save", role: nil, label: [ViewNode(.text("Save"))]))
        ]))
        primeHost(tree, entry: e)
        let host = PatchedBodyHost(typeName: typeName, entry: e, propsJSON: "{}", writebacks: [])
        _ = host.body
        await settleDeferredDemotes()
        XCTAssertNil(PatchViewPatchRegistry.shared.entryIfPatchable(typeName: typeName),
                     "a lowered Button with no dispatch export must demote — never ship a "
                     + "button that renders correctly and does nothing on tap")
    }

    /// Positive control: the same button tree WITH a dispatch export stays patched.
    func testButtonWithADispatchExportStaysPatched() async {
        let e = entry(dispatch: "dispatch__\(typeName)")
        let cleanup = prepare(e); defer { cleanup() }
        let tree = ViewNode(.vstack(alignment: nil, spacing: 0, children: [
            ViewNode(.button(actionID: "tap_save", role: nil, label: [ViewNode(.text("Save"))]))
        ]))
        primeHost(tree, entry: e)
        let host = PatchedBodyHost(typeName: typeName, entry: e, propsJSON: "{}", writebacks: [])
        _ = host.body
        await settleDeferredDemotes()
        XCTAssertNotNil(PatchViewPatchRegistry.shared.entryIfPatchable(typeName: typeName),
                        "an interactive view with its dispatch export must keep rendering patched")
    }

    // MARK: BUG 7 — a DESTRUCTIVE dead affordance: swipe-to-delete with no dispatcher

    /// `.onDelete` was attached whenever the EVENT was present, regardless of whether a
    /// dispatcher existed. With no dispatch export `d?.send` is a silent no-op — so the user
    /// swipes, SwiftUI ANIMATES THE ROW OUT, the data never changes and the row SNAPS BACK:
    /// the "animates out then REAPPEARS" data-integrity failure the `thunkSafe` gate exists
    /// to prevent. The host must demote the whole view instead.
    func testListEditAffordanceWithoutADispatchExportDemotes() async {
        let e = entry(dispatch: nil)
        let cleanup = prepare(e); defer { cleanup() }
        let rows = ViewNode(.forEach(children: [ViewNode(.text("a")), ViewNode(.text("b"))]),
                            modifiers: [.onDelete(EventID("del"))])
        primeHost(ViewNode(.list(children: [rows])), entry: e)
        let host = PatchedBodyHost(typeName: typeName, entry: e, propsJSON: "{}", writebacks: [])
        _ = host.body
        await settleDeferredDemotes()
        XCTAssertNil(PatchViewPatchRegistry.shared.entryIfPatchable(typeName: typeName),
                     "a swipe-to-delete that can never fire must demote the view — never offer "
                     + "an affordance that animates a row away and snaps it back")
    }

    /// The renderer-level net (which also covers the hand-wired `Patch.patchView` path):
    /// with NO dispatcher the affordance is not attached at all, so the destructive
    /// animation can't happen even if a caller renders such a tree directly.
    func testRendererDoesNotAttachAListAffordanceWithoutADispatcher() {
        let rows = ViewNode(.forEach(children: [ViewNode(.text("a"))]),
                            modifiers: [.onDelete(EventID("del"))])
        // No dispatcher in the context → must render without trapping or attaching a dead
        // handler. (Rendering is the assertion: it must produce a view, not crash.)
        var ctx = RenderContext(showOpaqueStubs: false)
        ctx.dispatcher = nil
        _ = render(ViewNode(.list(children: [rows])), context: ctx)
        // With a dispatcher the affordance IS wired (the positive control).
        var live = RenderContext(showOpaqueStubs: false)
        var got: EventID?
        live.dispatcher = Dispatcher { e, _ in got = e }
        _ = render(ViewNode(.list(children: [rows])), context: live)
        live.dispatcher?.send(EventID("del"), .none)
        XCTAssertEqual(got?.id, "del", "a dispatcher-backed affordance must still be wired")
    }

    /// And a NON-interactive view with no dispatch export is untouched by the new gate.
    func testButtonlessViewWithoutDispatchStaysPatched() async {
        let e = entry(dispatch: nil)
        let cleanup = prepare(e); defer { cleanup() }
        primeHost(ViewNode(.text("read only")), entry: e)
        let host = PatchedBodyHost(typeName: typeName, entry: e, propsJSON: "{}", writebacks: [])
        _ = host.body
        await settleDeferredDemotes()
        XCTAssertNotNil(PatchViewPatchRegistry.shared.entryIfPatchable(typeName: typeName),
                        "a read-only view legitimately has no dispatch export — do not demote it")
    }

    // MARK: BUG 5 — the structurally-static template cache grew without bound

    /// Every other cache in `ViewPatching.swift` is explicitly bounded ("invariant #3:
    /// memory can't grow unbounded"). `PatchedBodyStaticTemplateCache` keyed entries by
    /// (typeName, export, EPOCH) and never removed the old ones, so every hot-swap leaked a
    /// fully decoded `ViewNode` tree per static view, forever. A stale-epoch entry is DEAD by
    /// construction — `lookup` only matches the live epoch — so sweeping is loss-free.
    func testStaticTemplateCacheDoesNotAccumulateStaleEpochs() {
        PatchedBodyStaticTemplateCache.shared.reset()
        defer { PatchedBodyStaticTemplateCache.shared.reset() }
        let payload = PatchedBodyCacheEntry(tree: ViewNode(.text("x")), slotArgs: [:],
                                            idSets: PatchedBodyHost.collectAllIDs(ViewNode(.text("x"))))
        for epoch in UInt64(1)...UInt64(20) {
            PatchedBodyStaticTemplateCache.shared.store(typeName: "A", export: "view_body__A",
                                                        epoch: epoch, payload: payload)
            PatchedBodyStaticTemplateCache.shared.store(typeName: "B", export: "view_body__B",
                                                        epoch: epoch, payload: payload)
        }
        XCTAssertEqual(PatchedBodyStaticTemplateCache.shared.count, 2,
                       "after 20 module swaps the cache must hold only the 2 LIVE-epoch "
                       + "templates, not 40 dead ones")
        // The live epoch's entries are still there (the sweep must not drop what it must keep).
        XCTAssertNotNil(PatchedBodyStaticTemplateCache.shared.lookup(typeName: "A",
                                                                    export: "view_body__A", epoch: 20))
        XCTAssertNotNil(PatchedBodyStaticTemplateCache.shared.lookup(typeName: "B",
                                                                    export: "view_body__B", epoch: 20))
    }

    // MARK: BUG 6 — enum @State write-back was dead for every non-String-raw enum

    private enum StringRaw: String, Codable, CaseIterable, Equatable { case alpha, beta }
    private enum IntRaw: Int, Codable, CaseIterable, Equatable { case alpha, beta }
    private enum NoRaw: Codable, CaseIterable, Equatable { case alpha, beta }
    private enum IntRawNotIterable: Int, Codable, Equatable { case alpha, beta }

    /// `PatchValueEncoder` marshals EVERY enum as `{"case":"<label>"}`, but the write-back
    /// reshaped that into a BARE STRING — the shape only a `String`-raw enum's synthesized
    /// decoder accepts. Measured synthesized encodings:
    ///     enum S: String → "beta"        (worked)
    ///     enum I: Int    → 1             (DEAD)
    ///     enum P:        → {"beta":{}}   (DEAD)
    /// So a `Picker`/segmented control bound to an `Int`-raw or plain enum `@State` moved the
    /// PATCHED view but never the native `@State`: `.onChange`, `didSet`, native siblings and
    /// any persistence kept the old value and the app's two halves diverged.
    func testEnumWriteBackRoundTripsForEveryEnumShape() {
        for value in StringRaw.allCases {
            let frag = PatchValueEncoder.encode(value)
            XCTAssertEqual(frag, "{\"case\":\"\(value)\"}")
            XCTAssertEqual(_patchDecodeJSON(StringRaw.self, from: frag ?? ""), value,
                           "String-raw enum write-back (worked before, must keep working)")
        }
        for value in IntRaw.allCases {
            XCTAssertEqual(_patchDecodeJSON(IntRaw.self, from: PatchValueEncoder.encode(value) ?? ""),
                           value, "Int-RAW enum write-back was DEAD — the native @State never moved")
        }
        for value in NoRaw.allCases {
            XCTAssertEqual(_patchDecodeJSON(NoRaw.self, from: PatchValueEncoder.encode(value) ?? ""),
                           value, "plain (non-RawRepresentable) enum write-back was DEAD")
        }
    }

    /// The recovery is by CASE LABEL via `swift_EnumCaseName` — never a raw-value guess — so
    /// it can only ever produce the case the encoder actually emitted, and it declines
    /// (write-back SKIPPED, never wrong) when it cannot prove the answer.
    func testEnumWriteBackNeverGuessesWrong() {
        // An unknown label resolves to nothing rather than falling back to the first case.
        XCTAssertNil(_patchDecodeJSON(IntRaw.self, from: "{\"case\":\"gamma\"}"),
                     "an unknown case label must be SKIPPED, never silently mapped to a case")
        // An Int-raw enum that is NOT CaseIterable genuinely cannot be recovered from a label;
        // it must still fail SAFE (nil → the write-back is skipped, never a wrong case).
        XCTAssertNil(_patchDecodeJSON(IntRawNotIterable.self,
                                      from: PatchValueEncoder.encode(IntRawNotIterable.beta) ?? ""))
        // A struct is untouched by the enum recovery paths.
        struct Row: Codable, Equatable { var id: Int; var name: String }
        let row = Row(id: 7, name: "seven")
        XCTAssertEqual(_patchDecodeJSON(Row.self, from: PatchValueEncoder.encode(row) ?? ""), row)
    }

    /// The full `applyWritebacks` path — what a dispatch actually runs — now reaches a live
    /// wrapper holding an Int-raw enum. (`Binding` is used rather than `State` because a
    /// `State` box only accepts writes while installed on a real SwiftUI view; `Binding`
    /// takes the IDENTICAL `_PatchScalarWrapper` / `_patchWriteJSON` code path.)
    func testApplyWritebacksReachesAnIntRawEnumBinding() {
        final class Box: @unchecked Sendable { var value: IntRaw = .alpha }
        let box = Box()
        let binding = Binding<IntRaw>(get: { box.value }, set: { box.value = $0 })
        PatchedBodyHost.applyWritebacks([PatchScalarWriteback(key: "mode", wrapper: binding)],
                                        newStateJSON: #"{"mode":{"case":"beta"}}"#)
        XCTAssertEqual(box.value, .beta,
                       "a guest-side Picker change on an Int-raw enum must reach the native binding")

        // A plain (non-RawRepresentable) enum too.
        final class PBox: @unchecked Sendable { var value: NoRaw = .alpha }
        let pbox = PBox()
        let pbinding = Binding<NoRaw>(get: { pbox.value }, set: { pbox.value = $0 })
        PatchedBodyHost.applyWritebacks([PatchScalarWriteback(key: "mode", wrapper: pbinding)],
                                        newStateJSON: #"{"mode":{"case":"beta"}}"#)
        XCTAssertEqual(pbox.value, .beta)

        // An UNKNOWN label must leave the binding untouched (skip, never a wrong case).
        final class UBox: @unchecked Sendable { var value: IntRaw = .alpha }
        let ubox = UBox()
        let ubinding = Binding<IntRaw>(get: { ubox.value }, set: { ubox.value = $0 })
        PatchedBodyHost.applyWritebacks([PatchScalarWriteback(key: "mode", wrapper: ubinding)],
                                        newStateJSON: #"{"mode":{"case":"gamma"}}"#)
        XCTAssertEqual(ubox.value, .alpha, "an unknown case label must not write anything")
    }
}

#endif
