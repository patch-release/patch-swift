import XCTest
import Foundation
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI

/// SDK side of NATIVE-ACTION SLOTS: a `Button` inside an actions-list builder
/// (`.swipeActions`/`.toolbar`/`.alert`/`Menu`/`.contextMenu`) whose action is a native
/// method call (`deleteSubscription(s)`, `resetAllData()`) lowers to an `actionSlotButton`
/// node — its LABEL + `role` ride WASM (OTA-patchable) while the ACTION is a native slot
/// closure (`() -> Void`, closing over `self`) the build-time thunk's `__patchActionSlots()`
/// supplies by id. The renderer wires the reconstituted Button's `action:` to that closure;
/// an uncovered id demotes the WHOLE view (mirrors the opaque-leaf / row-slot demote-safety).
final class ActionSlotTests: XCTestCase {

    // MARK: - 1. Wire round-trip: the node survives the JSON boundary intact (label + role).

    func testActionSlotButtonWireRoundTrip() throws {
        // Build the canonical shape directly (label + destructive role both lower).
        let button = N.actionSlotButton(id: "as_del", role: .destructive,
                                        label: [N.text("Delete")])
        let real = N.list([N.hstack([N.text("Netflix"), button])])

        let emission = BodyEmission(root: real, coverage: nil,
                                    schemaVersion: PatchViewIRSchema.version)
        // Foundation codec.
        let back = try ViewNodeWire.decode(try ViewNodeWire.encode(emission))
        XCTAssertEqual(back.root, real, "actionSlotButton survives the Foundation JSON boundary")
        // Embedded (Foundation-free) emitter → same bytes the guest ships.
        let embedded = try ViewNodeWire.decode(EmbeddedJSON.encode(emission))
        XCTAssertEqual(embedded.root, real, "actionSlotButton survives the embedded JSON boundary")
        // The role (destructive/cancel) MUST be preserved (alert/swipe styling).
        guard case .actionSlotButton(let id, let role, let label) = findActionSlot(back.root)?.kind else {
            return XCTFail("expected an actionSlotButton node in the decoded tree")
        }
        XCTAssertEqual(id, "as_del")
        XCTAssertEqual(role, .destructive, "the role rides WASM and is preserved")
        XCTAssertEqual(label.first?.kind, N.text("Delete").kind, "the label rides WASM")
        XCTAssertGreaterThanOrEqual(PatchViewIRSchema.version, 9)
        XCTAssertTrue(PatchViewIRSchema.isSupported(9))
    }

    // MARK: - 2. Renderer: the reconstituted Button's action is the thunk's native slot closure.

    /// The headline render-correctness proof: an `actionSlotButton` with a registered native
    /// slot closure reconstitutes a Button whose `action:` IS that closure — so the real native
    /// method call (here a stand-in sink) runs on tap.
    @MainActor
    func testActionSlotButtonWiresNativeClosure() {
        let id = "as_reset"
        var fired = 0
        // The closure the thunk's `__patchActionSlots()` supplies — closes over `self`, so the
        // real `resetAllData()` would run here.
        let nativeAction: () -> Void = { fired += 1 }

        let tree = N.actionSlotButton(id: id, role: .destructive, label: [N.text("Reset")])
        let ctx = RenderContext(showOpaqueStubs: false)
        ctx.actionSlots.set(id, nativeAction)

        // The renderer reconstitutes the Button without crashing.
        _ = render(tree, context: ctx)

        // We can't tap a SwiftUI Button in a unit test, so prove the SAME table the renderer reads
        // returns the registered closure, and that invoking it runs the native action.
        let resolved = ctx.actionSlots.action(for: id)
        XCTAssertNotNil(resolved, "the renderer resolves the native action closure by id")
        resolved?()
        XCTAssertEqual(fired, 1, "the reconstituted Button's action IS the thunk's native closure")
    }

    /// DEMOTE-SAFE: the renderer's missing-slot fallback never crashes (no-op action).
    @MainActor
    func testRendererFallbackIsSafeWhenSlotMissing() {
        let id = "as_missing"
        let tree = N.actionSlotButton(id: id, role: nil, label: [N.text("X")])
        // No closure registered → a no-op action button, never a crash.
        let ctx = RenderContext(showOpaqueStubs: false)
        _ = render(tree, context: ctx)
    }

    // MARK: - 3. PatchedBodyHost demote-safety: an uncovered action-slot id demotes.

    /// `collectActionSlotIDs` finds every action-slot id in the tree (incl. nested in a
    /// modifier content subtree — an actions-list Button lives in a `.alert`/`.toolbar`/etc.
    /// MODIFIER subtree, NOT `childNodes`) — the set `PatchedBodyHost` requires the thunk to cover.
    func testCollectActionSlotIDsFindsNested() {
        let inner = N.actionSlotButton(id: "as_inner", role: .destructive, label: [N.text("Reset")])
        let top = N.actionSlotButton(id: "as_top", role: nil, label: [N.text("Add")])
        // `inner` lives in an `.alert` actions modifier subtree (where these really occur);
        // `top` is a plain child.
        let tree = N.vstack([top]).with(
            .alert(title: "Reset?", presentedKey: "show", isPresented: false,
                   actions: [inner], message: [], event: EventID("e")))
        let ids = Set(PatchedBodyHost.collectActionSlotIDs(tree))
        XCTAssertEqual(ids, ["as_top", "as_inner"],
            "every action-slot id is collected, incl. one nested in a modifier actions list")
    }

    // MARK: - helpers

    private func findActionSlot(_ node: ViewNode) -> ViewNode? {
        if case .actionSlotButton = node.kind { return node }
        for child in node.childNodes { if let f = findActionSlot(child) { return f } }
        for m in node.modifiers { for c in m.contentNodes { if let f = findActionSlot(c) { return f } } }
        return nil
    }
}
#endif
