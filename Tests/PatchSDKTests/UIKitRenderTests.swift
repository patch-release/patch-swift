// UIKitRenderTests — the SDK-side tests for the UIKitNode IR + UIKit renderer.
// =============================================================================
// Two halves, mirroring how the SwiftUI renderer is tested:
//
//   * IR ROUND-TRIP (runs everywhere, incl. the headless macOS CI host):
//     a UIKitNode tree → UIKitEmbeddedJSON.encode → JSONDecoder → equal tree,
//     and the synthesized Codable agrees. This proves the SDK's vendored copy of
//     the IR decodes exactly what the engine's guest emits.
//
//   * RENDER (gated `#if canImport(UIKit)` — runs on the iOS/tvOS/visionOS family
//     + the on-device E2E; UIKit is absent on macOS): renderUIKit(tree) returns a
//     real non-nil UIView with the expected subview count + the expected number
//     of activated constraints, a customSlot pulls the registered native view,
//     and a button's target/action forwards into the dispatcher.

import XCTest
import Foundation
import PatchViewIR
import PatchRenderUIKit

final class UIKitRenderTests: XCTestCase {

    /// A representative tree: a vertical stack with a horizontal row (image +
    /// label + button), a switch, and a native slot — exercising every node kind,
    /// the view props, and the constraint grammar.
    private func sampleTree(slotID: String = "mapView") -> UIKitNode {
        let avatar = UI.image(systemName: "person.crop.circle",
                              tintColor: .named("blue"),
                              contentMode: .scaleAspectFit)
            .id("avatar")
            .size(.width, 40)
            .size(.height, 40)

        let title = UI.label("Ada", font: IRFont(size: 17, weight: .semibold),
                             textColor: .named("primary"))
            .id("title")
            .pin(.leading, to: .trailing, of: .sibling(id: "avatar"), constant: 8)

        let follow = UI.button("Follow", action: "followTapped")
            .id("follow")
            .background(.named("blue"))
            .cornerRadius(8)
            .size(.height, 44)

        let row = UI.stack(axis: .horizontal, spacing: 8, alignment: .center,
                           arranged: [avatar, title, follow]).id("row")
        let toggle = UI.switchControl(isOn: true, event: "notify").id("toggle")
        let native = UI.slot(id: slotID, label: "MKMapView").id("native")

        return UI.stack(axis: .vertical, spacing: 12, alignment: .fill,
                        distribution: .equalSpacing,
                        arranged: [row, toggle, native])
            .id("column")
            .background(.named("systemBackground"))
    }

    // MARK: - IR round-trip (runs everywhere)

    func testIRRoundTripThroughBothCodecs() throws {
        let tree = sampleTree()
        let emission = UIKitEmission(
            root: tree,
            coverage: UIKitCoverage(totalNodes: tree.nodeCount,
                                    slotNodes: tree.slotNodeCount,
                                    totalConstraints: tree.constraintCount))
        let embedded = UIKitEmbeddedJSON.encode(emission)
        let fromEmbedded = try JSONDecoder().decode(UIKitEmission.self, from: Data(embedded))
        XCTAssertEqual(fromEmbedded, emission)
        let fromSynth = try JSONDecoder().decode(
            UIKitEmission.self, from: try JSONEncoder().encode(emission))
        XCTAssertEqual(fromSynth, fromEmbedded,
                       "SDK vendored IR: embedded emitter diverged from synthesized Codable")
    }

    func testTreeStatistics() {
        let tree = sampleTree()
        // column(1) + row(1) + 3 row children + toggle + native = 7.
        XCTAssertEqual(tree.nodeCount, 7)
        XCTAssertEqual(tree.slotNodeCount, 1)
    }

    // MARK: - Render (UIKit only)

    #if canImport(UIKit)
    @MainActor
    func testRenderProducesRealViewTreeWithConstraints() {
        let tree = sampleTree()
        let root = renderUIKit(tree)

        // The root is a real UIStackView (the column) with 3 arranged subviews.
        let column = try? XCTUnwrap(root as? UIStackView)
        XCTAssertEqual(column?.arrangedSubviews.count, 3,
                       "column should have row + toggle + native")
        XCTAssertEqual(root.translatesAutoresizingMaskIntoConstraints, false)

        // The first arranged subview is the row stack with 3 arranged subviews.
        let row = column?.arrangedSubviews.first as? UIStackView
        XCTAssertEqual(row?.arrangedSubviews.count, 3,
                       "row should have avatar + title + button")
        XCTAssertTrue(row?.arrangedSubviews[0] is UIImageView)
        XCTAssertTrue(row?.arrangedSubviews[1] is UILabel)
        XCTAssertTrue(row?.arrangedSubviews[2] is UIButton)

        // The constraint count: avatar w+h (2) + title leading-to-sibling (1) +
        // follow height (1) = 4 activated constraints in the whole subtree.
        let activated = collectActiveConstraints(in: root)
        XCTAssertEqual(activated, 4, "expected 4 activated IR constraints")

        // View props applied: the button's corner radius + background.
        let button = row?.arrangedSubviews[2]
        XCTAssertEqual(button?.layer.cornerRadius, 8)
        XCTAssertNotNil(button?.backgroundColor)
    }

    @MainActor
    func testCustomSlotPullsRegisteredNativeView() {
        let tree = sampleTree(slotID: "myMap")
        let nativeView = UIView()
        nativeView.tag = 4242
        let slots = UIKitSlotTable()
        slots.set("myMap", nativeView)
        let context = UIKitRenderContext(slots: slots)
        let root = renderUIKit(tree, context: context)

        // The native view must appear as the 3rd arranged subview of the column.
        let column = root as? UIStackView
        XCTAssertEqual((column?.arrangedSubviews[2] as? UIView)?.tag, 4242,
                       "the registered native view should fill the customSlot")
    }

    @MainActor
    func testUnregisteredSlotRendersVisibleStub() {
        let tree = UI.container([UI.slot(id: "missing", label: "MKMapView")])
        let root = renderUIKit(tree, context: UIKitRenderContext(showSlotStubs: true))
        let stub = root.subviews.first as? UILabel
        XCTAssertNotNil(stub, "an unregistered slot should render a labeled stub")
        XCTAssertTrue(stub?.text?.contains("missing") ?? false)
    }

    /// Fire a control's registered target/action(s) DIRECTLY, bypassing
    /// `UIControl.sendActions(for:)` — which routes through `UIApplication` and is
    /// a no-op in a host-app-less `xctest` process ("UIApp is nil … cannot
    /// dispatch control actions"). This still verifies the renderer wired the
    /// real target/action; it just invokes it the way `UIApplication` would.
    @MainActor
    private func fireActions(_ control: UIControl, for event: UIControl.Event) {
        for target in control.allTargets {
            guard let actions = control.actions(forTarget: target, forControlEvent: event) else { continue }
            for action in actions {
                (target as AnyObject).perform(Selector(action), with: control)
            }
        }
    }

    @MainActor
    func testButtonActionForwardsToDispatcher() {
        var received: (EventID, IRValue)?
        let dispatcher = UIKitDispatcher { event, value in received = (event, value) }
        let tree = UI.container([UI.button("Tap", action: "tapped").id("btn")])
        let root = renderUIKit(tree, context: UIKitRenderContext(dispatcher: dispatcher))
        let button = try? XCTUnwrap(root.subviews.first as? UIButton)
        // The renderer must have registered exactly one target/action.
        XCTAssertEqual(button?.allTargets.count, 1, "button should have one wired target")
        if let button { fireActions(button, for: .touchUpInside) }
        guard let (event, value) = received else {
            return XCTFail("button action did not forward to the dispatcher")
        }
        XCTAssertEqual(event.id, "tapped")
        // `IRValue.none` (a bare button carries no value) — match the payload, not
        // an Optional; `value` is a non-optional `IRValue` here.
        if case .none = value {} else { XCTFail("bare button should send IRValue.none payload") }
    }

    @MainActor
    func testSwitchValueChangeForwardsBoolToDispatcher() {
        var received: (EventID, IRValue)?
        let dispatcher = UIKitDispatcher { event, value in received = (event, value) }
        let tree = UI.container([UI.switchControl(isOn: false, event: "notify").id("sw")])
        let root = renderUIKit(tree, context: UIKitRenderContext(dispatcher: dispatcher))
        let sw = try? XCTUnwrap(root.subviews.first as? UISwitch)
        sw?.isOn = true
        if let sw { fireActions(sw, for: .valueChanged) }
        XCTAssertEqual(received?.0.id, "notify")
        if case .bool(let b) = received?.1 { XCTAssertTrue(b) }
        else { XCTFail("switch should send a .bool payload") }
    }

    /// Count the constraints THIS renderer activated from the IR, across the whole
    /// view tree. The renderer stamps each with `UIKitRenderer.constraintIdentifier`,
    /// so they're cleanly distinguishable from UIKit's own internal constraints
    /// (e.g. a UIStackView's axis engine) regardless of which view owns them.
    @MainActor
    private func collectActiveConstraints(in root: UIView) -> Int {
        var total = 0
        func walk(_ v: UIView) {
            total += v.constraints.filter {
                $0.isActive && $0.identifier == patchUIKitConstraintIdentifier
            }.count
            for sub in v.subviews { walk(sub) }
            if let stack = v as? UIStackView {
                for arranged in stack.arrangedSubviews where !v.subviews.contains(arranged) {
                    walk(arranged)
                }
            }
        }
        walk(root)
        return total
    }
    #endif
}
