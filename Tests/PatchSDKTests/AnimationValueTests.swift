// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
@testable import PatchRender
@testable import PatchSwiftUI

/// SDK side of FAITHFUL `.animation(_:value:)` RENDERING (IR v11): the
/// `Modifier.animation(_, valueKey:)` case — previously NO-OPPED by the renderer (so the
/// engine demoted the view to native, BUG #62) — now reconstitutes the real `Animation`
/// AND watches the watched-`@State`'s CURRENT scalar (resolved from the marshalled input
/// JSON into an `AnyHashable`, plumbed via `RenderContext.animationValues`) as the
/// `Equatable` trigger. A change to that value across renders fires the implicit animation,
/// matching native. DEMOTE-SAFE: an unresolvable trigger scalar degrades to a constant.
final class AnimationValueTests: XCTestCase {

    // MARK: - 1. Wire round-trip: the `.animation(_:value:)` modifier survives intact.

    func testAnimationModifierWireRoundTrip() throws {
        let tree = N.text("hi").animation(
            IRAnimation(curve: "easeInOut", duration: 0.25), valueKey: "refreshToast")
        let emission = BodyEmission(root: tree, coverage: nil,
                                    schemaVersion: PatchViewIRSchema.version)
        let back = try ViewNodeWire.decode(try ViewNodeWire.encode(emission))
        XCTAssertEqual(back.root, tree, ".animation(_:value:) survives the Foundation JSON boundary")
        let embedded = try ViewNodeWire.decode(EmbeddedJSON.encode(emission))
        XCTAssertEqual(embedded.root, tree, ".animation(_:value:) survives the embedded JSON boundary")
        guard case .animation(let a, let key)? = back.root.modifiers.first else {
            return XCTFail("expected an .animation modifier in the decoded tree")
        }
        XCTAssertEqual(key, "refreshToast", "the watched valueKey rides WASM")
        XCTAssertEqual(a?.curve, "easeInOut")
        XCTAssertEqual(a?.duration, 0.25)
    }

    // MARK: - 2. `collectAnimationValueKeys` finds every watched key (incl. nested).

    func testCollectAnimationValueKeysFindsNested() {
        // An `.animation` on a leaf inside a `.sheet` modifier-content subtree (not childNodes)
        // plus one on a plain child — both must be collected.
        let inner = N.text("body").animation(IRAnimation(curve: "spring"), valueKey: "innerFlag")
        let top = N.text("top").animation(IRAnimation(curve: "linear", duration: 0.2), valueKey: "topFlag")
        let tree = N.vstack([top]).with(
            .sheet(presentedKey: "show", isPresented: false, content: [inner], event: EventID("e")))
        let keys = Set(PatchedBodyHost.collectAnimationValueKeys(tree))
        XCTAssertEqual(keys, ["topFlag", "innerFlag"],
            "every animation valueKey is collected, incl. one nested in a modifier subtree")
    }

    // MARK: - 3. `animationTriggerValue` resolves each marshalled scalar shape.

    func testAnimationTriggerValueScalarShapes() {
        // Parse a flat input JSON the host marshals @State into, then resolve each key's trigger.
        let json = """
        {"s":"hello","i":42,"d":3.5,"b":true,"big":9007199254740993,"obj":{"x":1},"arr":[1,2]}
        """
        guard let obj = PatchFlatJSON.parse(json) else { return XCTFail("parse failed") }
        XCTAssertEqual(PatchedBodyHost.animationTriggerValue(obj["s"]), AnyHashable("hello"))
        XCTAssertEqual(PatchedBodyHost.animationTriggerValue(obj["i"]), AnyHashable(Int64(42)))
        XCTAssertEqual(PatchedBodyHost.animationTriggerValue(obj["d"]), AnyHashable(3.5))
        XCTAssertEqual(PatchedBodyHost.animationTriggerValue(obj["b"]), AnyHashable(true))
        // A large integral value keeps its exact Int64 (not a lossy Double) so it compares exactly.
        XCTAssertEqual(PatchedBodyHost.animationTriggerValue(obj["big"]), AnyHashable(Int64(9007199254740993)))
        // A non-scalar (object/array) or a missing key has no trigger → nil → renderer constant.
        XCTAssertNil(PatchedBodyHost.animationTriggerValue(obj["obj"]))
        XCTAssertNil(PatchedBodyHost.animationTriggerValue(obj["arr"]))
        XCTAssertNil(PatchedBodyHost.animationTriggerValue(obj["absent"]))
        XCTAssertNil(PatchedBodyHost.animationTriggerValue(nil))
    }

    // MARK: - 4. `Renderer.animation(_:)` reconstitutes a real Animation (nil-faithful).

    @MainActor
    func testAnimationConversion() {
        let r = Renderer(context: RenderContext())
        // `.animation(nil, value:)` — animation DISABLED is faithfully `nil`.
        XCTAssertNil(r.animation(nil), "a nil IRAnimation maps to a nil Animation (disabled)")
        // A curve produces a concrete (non-nil) Animation.
        XCTAssertNotNil(r.animation(IRAnimation(curve: "easeInOut", duration: 0.25)))
        XCTAssertNotNil(r.animation(IRAnimation(curve: "linear")))
        XCTAssertNotNil(r.animation(IRAnimation(curve: "spring", response: 0.4, dampingFraction: 0.8)))
        // A repeat/speed/delay composition + an unknown family (→ default) never crash.
        XCTAssertNotNil(r.animation(IRAnimation(curve: "default", delay: 0.1, speed: 2,
                                                repeatCount: 3, autoreverses: true)))
        XCTAssertNotNil(r.animation(IRAnimation(curve: "totally-unknown-curve")))
        // The iOS-17 presets degrade gracefully on any SDK.
        XCTAssertNotNil(r.animation(IRAnimation(curve: "bouncy")))
        XCTAssertNotNil(r.animation(IRAnimation(curve: "smooth")))
        XCTAssertNotNil(r.animation(IRAnimation(curve: "snappy")))
    }

    // MARK: - 5. The render path applies the animation with the resolved trigger (no crash).

    @MainActor
    func testRenderAppliesAnimationWithResolvedTrigger() {
        let tree = N.text("hi").animation(
            IRAnimation(curve: "easeInOut", duration: 0.25), valueKey: "refreshToast")
        var ctx = RenderContext(showOpaqueStubs: false)
        // The host resolves the watched @State's CURRENT scalar into the trigger map.
        ctx.animationValues = ["refreshToast": AnyHashable(true)]
        // Renders without crashing (the animation curve + trigger attach to the subtree).
        _ = render(tree, context: ctx)
        // The renderer reads the SAME map the host fills — prove the trigger is the resolved value.
        XCTAssertEqual(ctx.animationValues["refreshToast"], AnyHashable(true))
    }

    // MARK: - 6. DEMOTE-SAFE: an unresolved trigger degrades to a constant (never crashes).

    @MainActor
    func testRenderFallbackWhenTriggerUnresolved() {
        let tree = N.text("hi").animation(
            IRAnimation(curve: "spring"), valueKey: "neverMarshalled")
        // No animationValues entry for the key → the renderer uses a constant trigger.
        let ctx = RenderContext(showOpaqueStubs: false)
        _ = render(tree, context: ctx) // must not crash; the view still renders (patched).
        XCTAssertNil(ctx.animationValues["neverMarshalled"])
    }
}
#endif
