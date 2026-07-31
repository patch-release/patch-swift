// SPDX-License-Identifier: Apache-2.0

// UIKitNodeIRTests — the wire-format contract tests for the UIKitNode IR.
// ========================================================================
// The UIKit analogue of the SwiftUI ViewNode wire tests. Asserts:
//   1. ROUND-TRIP through the Foundation-free embedded emitter:
//      tree → UIKitEmbeddedJSON.encode → JSONDecoder → equal tree.
//   2. The embedded emitter's bytes match the SYNTHESIZED Codable's wire shape:
//      JSONEncoder(tree) decodes to the same tree the embedded bytes decode to,
//      so the host renderer (which reads either tier) sees one schema. (Both
//      JSONEncoder and the embedded emitter feed JSONDecoder; if either drifts
//      from the synthesized Codable, decode fails or yields a different tree.)
//   3. The drift guard: the shipped guest IR copies are byte-identical to the
//      canonical ViewNodeIR sources (mirrors testEmbeddedIRMatchesCanonicalViewNodeIR).

import XCTest
import Foundation
@testable import ViewNodeIR
@testable import CodeGenerator

final class UIKitNodeIRTests: XCTestCase {

    /// A representative tree exercising every node kind, the view props, the
    /// shared value types (IRColor/ColorRef/IRFont), and the full constraint
    /// grammar (eq/ge/le, every IRAnchorTarget, constant size, multiplier,
    /// priority).
    private func sampleTree() -> UIKitNode {
        let avatar = UI.image(systemName: "person.crop.circle",
                              tintColor: .named("blue"),
                              contentMode: .scaleAspectFit)
            .id("avatar")
            .cornerRadius(20)
            .clipsToBounds(true)
            .size(.width, 40)
            .size(.height, 40)
            .pin(.top, to: .top, of: .safeArea, constant: 12)
            .pin(.leading, to: .leading, of: .superview, constant: 16)

        let title = UI.label("Ada Lovelace",
                             font: IRFont(size: 17, weight: .semibold),
                             textColor: .named("primary"),
                             numberOfLines: 1,
                             alignment: .left)
            .id("title")
            .pin(.leading, to: .trailing, of: .sibling(id: "avatar"), constant: 8)
            .pin(.centerY, to: .centerY, of: .sibling(id: "avatar"))
            .pin(.trailing, to: .trailing, of: .superview, relation: .le, constant: -16)

        let follow = UI.button("Follow",
                               titleColor: .rgba(IRColor(r: 1, g: 1, b: 1)),
                               font: IRFont(style: .body, weight: .bold),
                               action: "followTapped")
            .id("follow")
            .background(.named("blue"))
            .cornerRadius(8)
            .alpha(0.95)
            .size(.height, 44, relation: .ge)
            // a multiplier + priority constraint (width == 0.5 * superview width @999)
            .pin(.width, to: .width, of: .superview, multiplier: 0.5, priority: 999)

        let toggle = UI.switchControl(isOn: true, event: "notify")
            .id("notifySwitch")
        let slider = UI.slider(value: 0.4, min: 0, max: 1, event: "vol")
        let field = UI.textField(text: "Ada", placeholder: "Name", event: "name")
        let native = UI.slot(id: "mapView", label: "MKMapView")
            .hidden(false)
            .accessibilityIdentifier("map")

        let row = UI.stack(axis: .horizontal, spacing: 8, alignment: .center,
                           distribution: .fill,
                           arranged: [avatar, title, follow])
            .id("row")

        let column = UI.stack(axis: .vertical, spacing: 12, alignment: .fill,
                              distribution: .equalSpacing,
                              arranged: [row, toggle, slider, field, native])
            .id("column")
            .background(.rgba(IRColor(r: 0.95, g: 0.95, b: 0.97)))

        // A plain container wrapping the stack, pinned to all edges.
        return UI.container([column])
            .id("root")
            .background(.named("systemBackground"))
            .withConstraintsEdges()
    }

    // MARK: - 1 + 2. Wire round-trip through BOTH codecs

    func testEmbeddedEmitterRoundTripsThroughFoundationDecoder() throws {
        let tree = sampleTree()
        let emission = UIKitEmission(
            root: tree,
            coverage: UIKitCoverage(totalNodes: tree.nodeCount,
                                    slotNodes: tree.slotNodeCount,
                                    totalConstraints: tree.constraintCount))

        // (1) Embedded (Foundation-free) emit → Foundation decode → equal.
        let embeddedBytes = UIKitEmbeddedJSON.encode(emission)
        let fromEmbedded = try JSONDecoder().decode(UIKitEmission.self,
                                                    from: Data(embeddedBytes))
        XCTAssertEqual(fromEmbedded, emission,
                       "UIKitNode tree did not survive embedded-encode → decode")

        // (2) Synthesized Codable emit → Foundation decode → equal. If the
        // embedded emitter's wire shape differed from the synthesized Codable,
        // these two decoded trees could not both equal `emission`.
        let synthBytes = try JSONEncoder().encode(emission)
        let fromSynth = try JSONDecoder().decode(UIKitEmission.self,
                                                 from: synthBytes)
        XCTAssertEqual(fromSynth, fromEmbedded,
                       "embedded emitter wire shape diverged from synthesized Codable")
    }

    /// A focused round-trip of EVERY node kind in isolation (so a single broken
    /// case is pinpointed, not masked inside the big tree).
    func testEachNodeKindRoundTrips() throws {
        let kinds: [UIKitNode] = [
            UI.label("L", font: IRFont(size: 12), textColor: .named("red"),
                     numberOfLines: 0, alignment: .justified),
            UI.label("bare"),                                   // all-nil optionals
            UI.button("B", action: "a"),
            UI.image(systemName: "star"),
            UI.image(named: "Logo", tintColor: .named("blue"), contentMode: .center),
            UI.stack(axis: .vertical, arranged: [UI.label("x")]),
            UI.container([UI.label("y")]),
            UI.switchControl(isOn: false, event: "s"),
            UI.slider(value: 3, min: 1, max: 10, event: "sl"),
            UI.textField(text: "t", placeholder: "p", event: "tf"),
            UI.slot(id: "n", label: "Native"),
        ]
        for node in kinds {
            let emission = UIKitEmission(root: node)
            let bytes = UIKitEmbeddedJSON.encode(emission)
            let decoded = try JSONDecoder().decode(UIKitEmission.self, from: Data(bytes))
            XCTAssertEqual(decoded, emission, "round-trip failed for: \(node.kind)")
            // And the synthesized Codable agrees.
            let synth = try JSONDecoder().decode(
                UIKitEmission.self, from: try JSONEncoder().encode(emission))
            XCTAssertEqual(synth, decoded, "synth/embedded mismatch for: \(node.kind)")
        }
    }

    /// Every IRAnchorTarget form + relation + constant/multiplier/priority knob.
    func testConstraintGrammarRoundTrips() throws {
        let targets: [IRAnchorTarget] = [
            .superview, .safeArea, .selfView, .sibling(id: "other"),
        ]
        var node = UI.label("anchored").id("anchored")
        for (i, t) in targets.enumerated() {
            node = node.pin(.leading, to: .trailing, of: t,
                            relation: i % 2 == 0 ? .ge : .le,
                            multiplier: 1.5, constant: Double(i), priority: 750)
        }
        node = node.size(.width, 100).size(.height, 50, relation: .le)
        let emission = UIKitEmission(root: node)
        let bytes = UIKitEmbeddedJSON.encode(emission)
        let decoded = try JSONDecoder().decode(UIKitEmission.self, from: Data(bytes))
        XCTAssertEqual(decoded, emission)
        XCTAssertEqual(decoded.root.constraints.count, targets.count + 2)
        // The synthesized Codable agrees on the constraint wire shape too.
        let synth = try JSONDecoder().decode(
            UIKitEmission.self, from: try JSONEncoder().encode(emission))
        XCTAssertEqual(synth, decoded)
    }

    /// The exact embedded-emitter byte shape for the tricky encodings: a
    /// payload-free enum case is `{"case":{}}` (NOT a bare string), a labeled
    /// single-payload case uses its label, an unlabeled one uses `_0`.
    func testEmbeddedWireShapeMatchesSynthesizedCodable() throws {
        // payload-free IRAnchorTarget.superview → {"superview":{}}
        let pinned = UI.label("x").pin(.top, to: .top, of: .superview)
        let bytes = UIKitEmbeddedJSON.encode(UIKitEmission(root: pinned))
        let s = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(s.contains("\"target\":{\"superview\":{}}"),
                      "payload-free case must encode as single-key empty object: \(s)")
        // labeled-payload IRAnchorTarget.sibling(id:) → {"sibling":{"id":"sib"}}
        let sib = UI.label("x").pin(.top, to: .top, of: .sibling(id: "sib"))
        let s2 = String(decoding: UIKitEmbeddedJSON.encode(UIKitEmission(root: sib)),
                        as: UTF8.self)
        XCTAssertTrue(s2.contains("\"sibling\":{\"id\":\"sib\"}"),
                      "labeled payload must use its label: \(s2)")
        // unlabeled-payload IRImageRef.systemName(_) → {"systemName":{"_0":"star"}}
        let img = UI.image(systemName: "star")
        let s3 = String(decoding: UIKitEmbeddedJSON.encode(UIKitEmission(root: img)),
                        as: UTF8.self)
        XCTAssertTrue(s3.contains("\"systemName\":{\"_0\":\"star\"}"),
                      "unlabeled payload must use _0: \(s3)")
    }

    // MARK: - 3. IR drift guard — shipped guest IR == canonical ViewNodeIR

    func testEmbeddedUIKitIRMatchesCanonicalViewNodeIR() throws {
        // The UIKit guest ships a COPY of the UIKit IR (CodeGenerator GuestIR/UIKit
        // resources). Assert each copy is byte-identical to the canonical
        // ViewNodeIR source, so the wire format the SDK renderer matches can never
        // silently drift. Mirrors testEmbeddedIRMatchesCanonicalViewNodeIR.
        let emitter = SwiftUIGuestEmitter()
        let shipped = try emitter.uikitIRSources()
        let here = URL(fileURLWithPath: #filePath)
        let pkgRoot = here.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()  // cli/
        let irDir = pkgRoot.appendingPathComponent("Sources/ViewNodeIR")
        XCTAssertFalse(shipped.isEmpty, "no UIKit guest IR resources shipped")
        for f in shipped {
            // `_ViewNodeIR_UIKitNode.swift` → `UIKitNode.swift`
            let base = f.fileName.replacingOccurrences(of: "_ViewNodeIR_", with: "")
            let canonical = irDir.appendingPathComponent(base)
            let canonicalText = try String(contentsOf: canonical, encoding: .utf8)
            XCTAssertEqual(f.contents, canonicalText,
                "shipped UIKit guest IR `\(base)` drifted from the canonical ViewNodeIR — "
                + "regenerate cli/Sources/CodeGenerator/GuestIR/UIKit/\(base.replacingOccurrences(of: ".swift", with: ".swifttext"))")
        }
    }

    // MARK: - Tree statistics

    func testTreeStatistics() {
        let tree = sampleTree()
        // root container(1) + column stack(1) + row stack(1) + 3 row children
        // (avatar/title/follow) + 4 column children (toggle/slider/field/native) = 10.
        XCTAssertEqual(tree.nodeCount, 10)
        XCTAssertEqual(tree.slotNodeCount, 1)   // the one customSlot (mapView)
        XCTAssertGreaterThan(tree.constraintCount, 0)
    }
}

// A tiny helper used only by the sample tree: pin all four edges to the superview.
private extension UIKitNode {
    func withConstraintsEdges() -> UIKitNode {
        self.pin(.top, to: .top, of: .superview)
            .pin(.leading, to: .leading, of: .superview)
            .pin(.trailing, to: .trailing, of: .superview)
            .pin(.bottom, to: .bottom, of: .superview)
    }
}
