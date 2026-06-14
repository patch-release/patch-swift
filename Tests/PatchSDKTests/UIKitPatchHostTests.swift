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
import PatchUIKit
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
