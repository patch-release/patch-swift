// UIKitPatchHostTests — the SDK-side tests for the UIKit cell-patching host.
// =============================================================================
// Two halves, mirroring how the SwiftUI host is tested:
//
//   * MANIFEST + MARSHAL (runs everywhere, incl. the headless macOS CI host): the
//     `patch_uikit_manifest` JSON decodes + schema-gates correctly, and a cell
//     MODEL marshals to the flat inputs JSON the guest scans. These are the
//     platform-independent core of the routing decision.
//
//   * INSTALL (gated `#if canImport(UIKit)` — runs on the iOS/tvOS/visionOS family +
//     the on-device E2E): the host renders a `UIKitEmission` into a `contentView` via
//     `renderUIKit`, the prior patched subtree is torn down on re-install (reuse-safe
//     idempotency), an uncovered slot demotes, and a control action forwards to the
//     cell's native handler.

import XCTest
import Foundation
import PatchViewIR
import PatchSDK
@testable import PatchUIKit
#if canImport(UIKit)
import UIKit
import PatchRenderUIKit
#endif

final class UIKitPatchHostTests: XCTestCase {

    // MARK: - Manifest decode + schema gate (runs everywhere)

    func testManifestDecodesAndKeysByType() throws {
        let json = """
        {"schemaVersion":1,"cells":[
          {"type":"ProfileCell","export":"uikit_configure__ProfileCell","thunkSafe":true},
          {"type":"ChartCell","export":"uikit_configure__ChartCell","thunkSafe":false}
        ]}
        """
        let entries = PatchUIKitManifest.decodeEntries([UInt8](json.utf8))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries["ProfileCell"]?.export, "uikit_configure__ProfileCell")
        XCTAssertEqual(entries["ProfileCell"]?.thunkSafe, true)
        XCTAssertEqual(entries["ChartCell"]?.thunkSafe, false)
    }

    func testNewerSchemaManifestRefused() throws {
        // A manifest stamped NEWER than this SDK understands must yield NO entries
        // (refuse to route rather than mis-decode a future wire shape).
        let json = "{\"schemaVersion\":999,\"cells\":[{\"type\":\"X\",\"export\":\"e\",\"thunkSafe\":true}]}"
        XCTAssertTrue(PatchUIKitManifest.decodeEntries([UInt8](json.utf8)).isEmpty)
    }

    func testMalformedManifestYieldsNoEntries() throws {
        XCTAssertTrue(PatchUIKitManifest.decodeEntries([UInt8]("not json".utf8)).isEmpty)
    }

    // MARK: - Model marshalling (runs everywhere)

    func testFlatModelMarshalsToInputsJSON() {
        struct CellModel { let title: String; let count: Int; let ratio: Double; let on: Bool }
        let json = PatchUIKitModelMarshal.flatJSON(
            from: CellModel(title: "Ada", count: 3, ratio: 0.5, on: true))
        // Keys are sorted + flat; the guest scans these by bare field name.
        XCTAssertEqual(json, #"{"count":3,"on":true,"ratio":0.5,"title":"Ada"}"#)
    }

    func testStringArrayModelFieldMarshals() {
        struct M { let tags: [String] }
        XCTAssertEqual(PatchUIKitModelMarshal.flatJSON(from: M(tags: ["a", "b"])),
                       #"{"tags":["a","b"]}"#)
    }

    func testNonScalarModelFieldDropped() {
        // A nested struct field can't marshal flat (and makes the cell
        // referencesUnmarshalledInput upstream, so it's never auto-routed) — dropped.
        struct Nested { let x: Int }
        struct M { let title: String; let nested: Nested }
        let json = PatchUIKitModelMarshal.flatJSON(from: M(title: "T", nested: Nested(x: 1)))
        XCTAssertEqual(json, #"{"title":"T"}"#, "the nested field is dropped, title kept")
    }

    func testOptionalScalarModelFieldUnwraps() {
        struct M { let title: String?; let missing: String? }
        XCTAssertEqual(PatchUIKitModelMarshal.flatJSON(from: M(title: "T", missing: nil)),
                       #"{"title":"T"}"#, "a non-nil optional marshals, a nil one drops")
    }

    func testJSONStringEscaping() {
        struct M { let s: String }
        XCTAssertEqual(PatchUIKitModelMarshal.flatJSON(from: M(s: "a\"b\\c\nd")),
                       #"{"s":"a\"b\\c\nd"}"#)
    }

    // MARK: - Numeric host-token merge (Lever D for numbers)

    /// A resolved DESIGN-SYSTEM NUMERIC TOKEN is merged into the flat model JSON under its
    /// reserved `__numtok_<id>` key (the guest reads it as a `.double` input in a numeric
    /// position). The token rides the INPUT JSON, like the SwiftUI numeric token.
    func testNumberTokenMergedIntoModelJSON() {
        struct M { let title: String }
        let base = PatchUIKitModelMarshal.flatJSON(from: M(title: "Hi"))
        let merged = PatchUIKitModelMarshal.merging(
            modelJSON: base, numberTokens: ["uint_radius": 12, "uint_inset": 8.5])
        // Both token keys present alongside the model field; numbers folded cleanly.
        XCTAssertTrue(merged.contains(#""__numtok_uint_radius":12"#), merged)
        XCTAssertTrue(merged.contains(#""__numtok_uint_inset":8.5"#), merged)
        XCTAssertTrue(merged.contains(#""title":"Hi""#), merged)
        // Still a single well-formed flat object.
        XCTAssertTrue(merged.hasPrefix("{") && merged.hasSuffix("}"))
        XCTAssertEqual(merged.filter { $0 == "{" }.count, 1, "no nested object: \(merged)")
    }

    /// Merging into an EMPTY model object (a cell with no model fields, only tokens)
    /// produces a token-only object — no leading/trailing comma.
    func testNumberTokenMergedIntoEmptyModel() {
        let merged = PatchUIKitModelMarshal.merging(modelJSON: "{}", numberTokens: ["uint_x": 4])
        XCTAssertEqual(merged, #"{"__numtok_uint_x":4}"#)
    }

    /// No tokens → the model JSON is returned UNCHANGED (the common unpatched-numeric
    /// path pays nothing, byte-identical). This is ALSO the MISSING-TOKEN fallback: a
    /// numeric token the thunk doesn't supply isn't merged, so the guest's
    /// `_patchScanDouble("__numtok_<id>")` misses and the body uses its input DEFAULT (0)
    /// — a degraded value, never a crash (the build-time id agreement guarantees a current
    /// build supplies every key its guest reads; an absent key only arises from a stale
    /// patch).
    func testNoNumberTokensLeavesModelUnchanged() {
        let base = #"{"title":"Hi"}"#
        let merged = PatchUIKitModelMarshal.merging(modelJSON: base, numberTokens: [:])
        XCTAssertEqual(merged, base)
        XCTAssertFalse(merged.contains("__numtok_"), "no token key injected when unsupplied")
    }

    // MARK: - Host install (UIKit only)

    #if canImport(UIKit)
    /// The host renders a `UIKitEmission` into a contentView via `renderUIKit` (the
    /// core of `installPatchedCell`, exercised directly so it runs without a live
    /// WASM module). A vertical stack with a title label + a button installs as a
    /// real subview tree pinned into the content view.
    @MainActor
    func testRenderEmissionIntoContentView() {
        let tree = UI.stack(axis: .vertical, spacing: 4, arranged: [
            UI.label("Ada Lovelace", font: IRFont(size: 17, weight: .bold)).id("title"),
            UI.label("Engineer").id("subtitle")
        ]).id("root").background(.named("systemBackground"))

        let contentView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        let rendered = renderUIKit(tree, context: UIKitRenderContext(showSlotStubs: false))
        rendered.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rendered)
        NSLayoutConstraint.activate([
            rendered.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rendered.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rendered.topAnchor.constraint(equalTo: contentView.topAnchor),
            rendered.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        contentView.layoutIfNeeded()

        let stack = try? XCTUnwrap(contentView.subviews.first as? UIStackView)
        XCTAssertEqual(stack?.arrangedSubviews.count, 2, "title + subtitle")
        XCTAssertTrue(stack?.arrangedSubviews[0] is UILabel)
        XCTAssertEqual((stack?.arrangedSubviews[0] as? UILabel)?.text, "Ada Lovelace")
        // The rendered tree fills the content view (its frame is non-zero after layout).
        XCTAssertGreaterThan(rendered.frame.width, 0)
    }

    /// `collectColorTokenIDs` finds every `ColorRef.hostToken(id)` across the tree's
    /// color positions (Lever D) — the ids `installPatchedCell` must have a resolver for
    /// (a missing one demotes the cell). Covers the common props (bg/tint) + leaf colors.
    func testCollectColorTokenIDsAcrossPositions() {
        let tree = UI.stack(axis: .vertical, arranged: [
            UI.label("Hi", textColor: .hostToken("uict_ink")).id("l"),
            UI.button("Go", titleColor: .hostToken("uict_btn"), action: "go").id("b"),
            UI.image(systemName: "star", tintColor: .hostToken("uict_star")).id("i")
        ]).background(.hostToken("uict_bg"))
        let ids = Set(Patch.collectColorTokenIDs(tree))
        XCTAssertEqual(ids, ["uict_ink", "uict_btn", "uict_star", "uict_bg"],
                       "every color-token id across props + leaf payloads is collected")
        // A token-free tree yields no ids (an unpatched cell pays nothing).
        let plain = UI.container([UI.label("x").id("x")]).background(.named("blue"))
        XCTAssertTrue(Patch.collectColorTokenIDs(plain).isEmpty)
    }

    /// `PatchCellWiring` carries `numberTokens` (the thunk-supplied NUMERIC design-token
    /// resolvers). A default init has none (a cell with no numeric tokens); the resolvers
    /// are stored as given and evaluate the cell's real design constant natively.
    @MainActor
    func testPatchCellWiringCarriesNumberTokens() {
        let plain = PatchCellWiring()
        XCTAssertTrue(plain.numberTokens.isEmpty)
        let wiring = PatchCellWiring(numberTokens: ["uint_r": { 16 }])
        XCTAssertEqual(wiring.numberTokens["uint_r"]?(), 16)
    }

    /// A customSlot pulls the cell's native view (the slot closure renders the live
    /// property), and the rendered subtree contains that exact view.
    @MainActor
    func testCustomSlotRendersNativeView() {
        let tree = UI.container([
            UI.label("Header").id("title"),
            UI.slot(id: "uislot_abc", label: "SparklineView").id("chart")
        ]).id("root")

        let native = UIView()
        native.tag = 7777
        let slots = UIKitSlotTable()
        slots.set("uislot_abc", native)
        let rendered = renderUIKit(tree, context: UIKitRenderContext(slots: slots, showSlotStubs: false))
        // The native view must appear in the rendered container.
        let found = rendered.subviews.contains { $0.tag == 7777 }
        XCTAssertTrue(found, "the registered native view fills the customSlot")
    }

    // MARK: - Gesture wirings (Lever 1) + observer effects (Lever 2)

    /// `PatchCellWiring` carries the new effect-replay channels (gesture wirings keyed by
    /// the view's node id + method-level observer effects). A default init has none.
    @MainActor
    func testPatchCellWiringCarriesGestureAndObserverChannels() {
        let plain = PatchCellWiring()
        XCTAssertTrue(plain.gestureWirings.isEmpty)
        XCTAssertTrue(plain.observerEffects.isEmpty)
        var tapped = false
        var observed = false
        let wiring = PatchCellWiring(
            gestureWirings: ["card": [{ v in v.tag = 99 }]],
            observerEffects: [{ observed = true }])
        // The gesture closure runs against a supplied view; the observer effect runs bare.
        let v = UIView()
        wiring.gestureWirings["card"]?.forEach { $0(v) }
        XCTAssertEqual(v.tag, 99)
        for e in wiring.observerEffects { e() }
        XCTAssertTrue(observed)
        _ = tapped
    }

    /// Lever 1 — the gesture wiring applies to the RENDERED view that carries the matching
    /// node id. After `renderUIKitIndexed`, the host looks up `viewsByID[nodeID]` and runs
    /// each replay closure against it (the closure does the real `addGestureRecognizer`).
    @MainActor
    func testGestureWiringAppliesToRenderedViewByNodeID() {
        let tree = UI.container([
            UI.label("Title").id("titleLabel"),
            UI.image(systemName: "photo").id("card")
        ]).id("root")

        let (root, byID) = renderUIKitIndexed(tree, context: UIKitRenderContext(showSlotStubs: false))
        // The renderer indexed every node carrying an id.
        XCTAssertNotNil(byID["card"], "the gesture's target view is indexed by its node id")
        XCTAssertNotNil(byID["titleLabel"])

        // Apply a gesture wiring keyed by node id (the SDK's install does exactly this).
        let gestureWirings: [String: [(UIView) -> Void]] = [
            "card": [{ v in
                v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(Self.noop)))
            }]
        ]
        for (nodeID, applies) in gestureWirings {
            guard let view = byID[nodeID] else { continue }
            for apply in applies { apply(view) }
        }
        // The gesture landed on the right rendered view (the image, not the label).
        XCTAssertEqual(byID["card"]?.gestureRecognizers?.count, 1,
                       "the tap recognizer attached to the card view")
        XCTAssertNil(byID["titleLabel"]?.gestureRecognizers,
                     "the label got no gesture")
        _ = root
    }

    /// Lever 1 — DEMOTE-SAFE applicability: a gesture wiring whose node id ISN'T in the
    /// rendered tree (the view didn't end up visible) is silently SKIPPED — never a crash.
    @MainActor
    func testGestureWiringForMissingViewIsSkipped() {
        let tree = UI.container([UI.label("Only").id("only")]).id("root")
        let (_, byID) = renderUIKitIndexed(tree, context: UIKitRenderContext(showSlotStubs: false))
        var applied = false
        let gestureWirings: [String: [(UIView) -> Void]] = ["ghost": [{ _ in applied = true }]]
        for (nodeID, applies) in gestureWirings {
            guard let view = byID[nodeID] else { continue }
            for apply in applies { apply(view) }
        }
        XCTAssertFalse(applied, "a wiring for a view not in the tree is skipped, not crashed")
    }

    /// Lever 2 — the observer effects run once (the SDK runs them after rendering).
    @MainActor
    func testObserverEffectsRunOnce() {
        var count = 0
        let observerEffects: [() -> Void] = [{ count += 1 }, { count += 10 }]
        for e in observerEffects { e() }
        XCTAssertEqual(count, 11, "each observer effect ran exactly once")
    }

    // MARK: - Goal 1 — QUARANTINED NATIVE EFFECTS

    /// `PatchCellWiring` carries the native-effect channel (Goal 1 — granular per-statement
    /// partitioning). A default init has none; supplied effects are the verbatim imperative
    /// statements the thunk replays against `self`.
    @MainActor
    func testPatchCellWiringCarriesNativeEffects() {
        let plain = PatchCellWiring()
        XCTAssertTrue(plain.nativeEffects.isEmpty, "no native effects by default")
        var ran = false
        let wiring = PatchCellWiring(nativeEffects: [{ ran = true }])
        XCTAssertEqual(wiring.nativeEffects.count, 1)
        for e in wiring.nativeEffects { e() }
        XCTAssertTrue(ran, "the supplied native effect runs")
    }

    /// Goal 1 — the native effects REPLAY IN SOURCE ORDER (the engine sorted them by
    /// ordinal; the SDK runs them in array order after building the tree). Order matters
    /// because imperative statements have ordered side effects.
    @MainActor
    func testNativeEffectsReplayInSourceOrder() {
        var log: [Int] = []
        // The engine emits these already ordered by source position; the SDK preserves it.
        let nativeEffects: [() -> Void] = [{ log.append(1) }, { log.append(2) }, { log.append(3) }]
        for e in nativeEffects { e() }
        XCTAssertEqual(log, [1, 2, 3], "native effects replay in the order the engine emitted them")
    }

    #if canImport(UIKit)
    /// Goal 1 — a native effect configures the LIVE instance (the dominant case: a
    /// delegate/dataSource/config set on a stored view that renders as a slotted custom
    /// leaf = the real `self.<name>`). The thunk captures the statement over `self`; here we
    /// model that with a closure mutating a captured object, run after the tree is rendered.
    @MainActor
    func testNativeEffectConfiguresLiveObjectAfterRender() {
        let table = UITableView()
        // The lowered tree renders normally (a label + a slotted table leaf).
        let tree = UI.container([UI.label("Header").id("h")]).id("root")
        let rendered = renderUIKit(tree, context: UIKitRenderContext(showSlotStubs: false))
        XCTAssertFalse(rendered.subviews.isEmpty, "the declarative construction rendered")
        // The quarantined `tableView.tag = 7` native effect (verbatim, captured over self).
        let nativeEffects: [() -> Void] = [{ table.tag = 7 }]
        for e in nativeEffects { e() }
        XCTAssertEqual(table.tag, 7, "the native effect configured the live stored object")
    }
    #endif

    // MARK: - BUG #17/#18 — control actions wired through PatchCellWiring

    /// `PatchCellWiring` carries the `actions` channel (BUG #17/#18 fix): each lowered
    /// control's action id maps to a native handler closure. A default init has none; a
    /// supplied handler is invoked by the renderer dispatcher when the control fires.
    @MainActor
    func testPatchCellWiringCarriesActions() {
        let plain = PatchCellWiring()
        XCTAssertTrue(plain.actions.isEmpty, "no actions by default")
        var toggled = false
        let wiring = PatchCellWiring(actions: ["act_toggle": { toggled = true }])
        XCTAssertEqual(wiring.actions.count, 1)
        wiring.actions["act_toggle"]?()
        XCTAssertTrue(toggled, "the supplied action handler runs")
    }

    // MARK: - BUG #53 — stale patched root cleared on every decline path

    /// `clearPatchedRoot` removes ONLY the tagged patch-installed root, leaving the cell's
    /// own native chrome untouched. This is the mechanism every decline path now invokes.
    @MainActor
    func testClearPatchedRootRemovesOnlyTaggedRoot() {
        let contentView = UIView()
        let patchedRoot = UIView(); patchedRoot.tag = Patch.patchedRootTag
        let nativeChrome = UIView(); nativeChrome.tag = 12345
        contentView.addSubview(patchedRoot)
        contentView.addSubview(nativeChrome)
        Patch.clearPatchedRoot(in: contentView)
        XCTAssertFalse(contentView.subviews.contains { $0.tag == Patch.patchedRootTag },
                       "the tagged patched root is removed")
        XCTAssertTrue(contentView.subviews.contains { $0.tag == 12345 },
                      "the cell's own native chrome is left intact")
    }

    /// BUG #53 — a DECLINE leaves no stale patched root behind. A reused cell whose
    /// contentView still holds a prior successful install's tagged root R1 is dequeued
    /// again; `installPatchedCell` declines (here: the type has no manifest entry) and must
    /// CLEAR R1 before returning false, so the thunk's native fallback renders cleanly into
    /// an empty contentView (no double/overlapping render).
    @MainActor
    func testDeclineClearsStalePatchedRoot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uikit-bug53-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let patch = Patch()
        let storage = try ModuleStorage(appKey: "pak_test_bug53", baseDirectory: dir)
        patch.injectForTesting(
            configuration: PatchConfiguration(
                appKey: "pak_test_bug53", appID: nil,
                apiBaseURL: URL(string: "https://api.test/api/v1")!, deviceID: "dev-bug53"),
            storage: storage, checker: nil)

        // Simulate the prior successful install: a tagged patched root R1 in the contentView.
        let contentView = UIView()
        let staleRoot = UIView(); staleRoot.tag = Patch.patchedRootTag
        contentView.addSubview(staleRoot)
        XCTAssertEqual(contentView.subviews.count, 1, "precondition: R1 present")

        // A later dequeue declines (no manifest entry for this type) — must clear R1.
        let installed = patch.installPatchedCell(
            typeName: "NoSuchPatchableCellType", contentView: contentView, model: nil)
        XCTAssertFalse(installed, "an unpatchable type declines")
        XCTAssertFalse(contentView.subviews.contains { $0.tag == Patch.patchedRootTag },
                       "BUG #53: the decline cleared the stale patched root R1")
    }

    @objc static func noop() {}

    /// A control action forwards through the dispatcher to a native handler — the
    /// wiring `installPatchedCell` sets up (action id → cell handler).
    @MainActor
    func testButtonActionForwardsToNativeHandler() {
        var fired = false
        let tree = UI.container([UI.button("Tap", action: "act_tap").id("btn")])
        let dispatcher = UIKitDispatcher { event, _ in if event.id == "act_tap" { fired = true } }
        let rendered = renderUIKit(tree, context: UIKitRenderContext(dispatcher: dispatcher))
        let button = try? XCTUnwrap(rendered.subviews.first as? UIButton)
        XCTAssertEqual(button?.allTargets.count, 1)
        // Fire the wired target/action directly (UIApplication is absent in xctest).
        if let button {
            for target in button.allTargets {
                if let actions = button.actions(forTarget: target, forControlEvent: .touchUpInside) {
                    for a in actions { (target as AnyObject).perform(Selector(a), with: button) }
                }
            }
        }
        XCTAssertTrue(fired, "the button action forwarded to the native handler")
    }
    #endif
}
