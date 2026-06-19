import XCTest
import Foundation
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI

/// SDK side of NATIVE EFFECT-MODIFIER SLOTS: a view with an undispatchable EFFECT modifier
/// (`.task { await load() }`/`.onAppear`/`.refreshable`/`.onSubmit`/gesture) keeps the effect
/// NATIVE but lowers the REST of the view. The effect lowers to a `Modifier.nativeEffectSlot(id)`
/// over a normally-lowered subtree; the build-time thunk's `__patchEffectSlots()` supplies
/// `[id: (AnyView) -> AnyView]` applying the real modifier expression (over `self`) to its
/// content. The renderer applies that closure to the rendered subtree; an uncovered id demotes
/// the WHOLE view (mirrors the opaque-leaf / action-slot demote-safety) — never strips a body
/// whose effect it can't supply.
final class EffectSlotTests: XCTestCase {

    // MARK: - 1. Wire round-trip: the modifier survives the JSON boundary on a lowered subtree.

    func testNativeEffectSlotWireRoundTrip() throws {
        // A normally-lowered subtree carrying a `.nativeEffectSlot` modifier (the `.task` etc.
        // kept native) — the modified content rides WASM.
        let content = N.vstack([N.text("Loading…"), N.text("Hello")])
            .with(.nativeEffectSlot("eff_load"))
        let real = N.navigationStack([content])

        let emission = BodyEmission(root: real, coverage: nil,
                                    schemaVersion: PatchViewIRSchema.version)
        // Foundation codec.
        let back = try ViewNodeWire.decode(try ViewNodeWire.encode(emission))
        XCTAssertEqual(back.root, real, "nativeEffectSlot survives the Foundation JSON boundary")
        // Embedded (Foundation-free) emitter → the same bytes the guest ships.
        let embedded = try ViewNodeWire.decode(EmbeddedJSON.encode(emission))
        XCTAssertEqual(embedded.root, real, "nativeEffectSlot survives the embedded JSON boundary")
        // The slot id rides WASM and is preserved; the modified subtree's text lowered.
        guard let slotted = findEffectSlot(back.root) else {
            return XCTFail("expected a node carrying a nativeEffectSlot modifier")
        }
        XCTAssertTrue(slotted.modifiers.contains(.nativeEffectSlot("eff_load")))
        XCTAssertGreaterThanOrEqual(PatchViewIRSchema.version, 10)
        XCTAssertTrue(PatchViewIRSchema.isSupported(10))
    }

    // MARK: - 2. Renderer: the modified subtree gets the thunk's native effect applied.

    /// The headline render-correctness proof: a subtree carrying `.nativeEffectSlot(id)` with a
    /// registered effect-application closure has THAT closure applied to its rendered subtree — so
    /// the real native `.task`/`.onAppear` (here a stand-in transform) runs over the lowered content.
    @MainActor
    func testNativeEffectSlotAppliesNativeClosure() {
        let id = "eff_appear"
        var applied = 0
        // The closure the thunk's `__patchEffectSlots()` supplies — closes over `self`, so the real
        // `content.onAppear { self.start() }` would run here. We just record + pass through.
        let nativeEffect: (AnyView) -> AnyView = { content in applied += 1; return content }

        let tree = N.text("Body").with(.nativeEffectSlot(id))
        let ctx = RenderContext(showOpaqueStubs: false)
        ctx.effectSlots.set(id, nativeEffect)

        // The renderer reconstitutes the view, applying the effect closure to the subtree.
        _ = render(tree, context: ctx)
        XCTAssertEqual(applied, 1, "the renderer applies the thunk's native effect closure to the subtree")

        // And the SAME table the renderer reads returns the registered closure by id.
        let resolved = ctx.effectSlots.apply(for: id)
        XCTAssertNotNil(resolved, "the renderer resolves the native effect closure by id")
    }

    /// DEMOTE-SAFE: the renderer's missing-slot fallback never crashes (identity passthrough).
    @MainActor
    func testRendererFallbackIsSafeWhenEffectSlotMissing() {
        let id = "eff_missing"
        let tree = N.text("X").with(.nativeEffectSlot(id))
        // No closure registered → the subtree renders unchanged, never a crash.
        let ctx = RenderContext(showOpaqueStubs: false)
        _ = render(tree, context: ctx)
    }

    // MARK: - 3. PatchedBodyHost demote-safety: an uncovered effect-slot id is collected.

    /// `collectEffectSlotIDs` finds every effect-slot MODIFIER id in the tree (incl. one nested in
    /// a modifier content subtree — a `.task` on a `.sheet` body's content). This is the set
    /// `PatchedBodyHost` requires the thunk to cover (else it demotes the whole view).
    func testCollectEffectSlotIDsFindsNested() {
        // An effect slot on a top-level subtree, AND one inside a `.sheet` content body.
        let inner = N.vstack([N.text("Sheet")]).with(.nativeEffectSlot("eff_inner"))
        let top = N.text("Top").with(.nativeEffectSlot("eff_top"))
        let tree = N.vstack([top]).with(
            .sheet(presentedKey: "show", isPresented: false, content: [inner], event: EventID("e")))
        let ids = Set(PatchedBodyHost.collectEffectSlotIDs(tree))
        XCTAssertEqual(ids, ["eff_top", "eff_inner"],
            "every effect-slot id is collected, incl. one nested in a modifier content subtree")
    }

    // MARK: - helpers

    private func findEffectSlot(_ node: ViewNode) -> ViewNode? {
        if node.modifiers.contains(where: { if case .nativeEffectSlot = $0 { return true }; return false }) {
            return node
        }
        for child in node.childNodes { if let f = findEffectSlot(child) { return f } }
        for m in node.modifiers { for c in m.contentNodes { if let f = findEffectSlot(c) { return f } } }
        return nil
    }
}
#endif
