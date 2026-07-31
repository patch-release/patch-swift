// SPDX-License-Identifier: Apache-2.0

// UIKitEffectWiringTests — engine-side tests for the two "effect-replay" wiring
// levers that extend the established `addTarget` action-wiring mechanism:
//
//   * LEVER 1 — `addGestureRecognizer` (view-attached): a gesture on a KNOWN view
//     with a `self` target + `#selector` action is recorded as a GESTURE WIRING
//     (view node id + verbatim gesture source) rather than demoting the method.
//   * LEVER 2 — `NotificationCenter.default.addObserver(self, selector:#selector(…),
//     name:…, object:…)` (method-level): recorded as an OBSERVER EFFECT.
//
// Both are demote-safe / ALL-OR-NOTHING-PER-METHOD: each test proves the construct
// LOWERS (the rest of the body rides WASM) AND that a native-touching variant STILL
// DEMOTES (a gesture on an unknown view / non-self target / non-selector action; the
// block-based observer; a private selector). No IR/wire change — the wirings ride the
// thunk + the view's node id, not the guest tree.

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

final class UIKitEffectWiringTests: XCTestCase {

    // MARK: - Lever 1: addGestureRecognizer

    /// A `setupViews` whose only non-declarative statement is `addGestureRecognizer`
    /// (the wiring that used to bail) now LOWERS: the view tree rides WASM and the
    /// gesture is recorded as a view-attached wiring keyed to the view's node id.
    func testGestureRecognizerWiringLowers() throws {
        let src = """
        import UIKit
        final class PhotoCardView: UIView {
            let photoView = UIImageView()
            func setupViews() {
                photoView.contentMode = .scaleAspectFill
                addSubview(photoView)
                photoView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
            }
            @objc func handleTap() {}
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        // The body lowered (the tree rides WASM) — no demote.
        XCTAssertTrue(cell.guestBody.contains("UI.image("), cell.guestBody)
        XCTAssertFalse(cell.guestBody.contains("UI.slot("), "no native slot: \(cell.guestBody)")
        // The gesture wiring is recorded against the view's node id (its local name) with the
        // VERBATIM gesture construction (selector intact for native replay).
        XCTAssertEqual(cell.gestureWirings.count, 1)
        let g = try XCTUnwrap(cell.gestureWirings.first)
        XCTAssertEqual(g.viewNodeID, "photoView")
        XCTAssertEqual(g.source,
                       "UITapGestureRecognizer(target: self, action: #selector(handleTap))")
        XCTAssertTrue(cell.thunkSafe, "a gesture wiring doesn't break thunk-safety")
    }

    /// Each recognized gesture type rides the wiring channel; multiple gestures on one
    /// view accumulate; a SECOND view's gesture keys separately.
    func testMultipleGestureTypesAndViews() throws {
        let src = """
        import UIKit
        final class BoardView: UIView {
            let tile = UIView()
            let handle = UIView()
            func setupViews() {
                addSubview(tile)
                addSubview(handle)
                tile.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
                tile.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(press)))
                handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan)))
            }
            @objc func tap() {}
            @objc func press() {}
            @objc func pan() {}
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertEqual(cell.gestureWirings.count, 3)
        XCTAssertEqual(cell.gestureWirings.filter { $0.viewNodeID == "tile" }.count, 2)
        XCTAssertEqual(cell.gestureWirings.filter { $0.viewNodeID == "handle" }.count, 1)
        XCTAssertTrue(cell.gestureWirings.contains { $0.source.contains("UILongPressGestureRecognizer") })
        XCTAssertTrue(cell.gestureWirings.contains { $0.source.contains("UIPanGestureRecognizer") })
    }

    /// DEMOTE-SAFE: a gesture whose `target` is NOT `self` (a delegate, a coordinator)
    /// demotes the whole method — we can't replay it against `self` faithfully.
    func testGestureNonSelfTargetDemotes() {
        let src = """
        import UIKit
        final class V: UIView {
            let box = UIView()
            func setupViews() {
                addSubview(box)
                box.addGestureRecognizer(UITapGestureRecognizer(target: coordinator, action: #selector(tap)))
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a non-self gesture target must demote (faithful)")
    }

    /// DEMOTE-SAFE: a gesture on an UNKNOWN view (not a constructed local) demotes — we
    /// have no rendered node to attach it to.
    func testGestureOnUnknownViewDemotes() {
        let src = """
        import UIKit
        final class V: UIView {
            let box = UIView()
            func setupViews() {
                addSubview(box)
                mysteryView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
            }
            @objc func tap() {}
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a gesture on an unknown view must demote")
    }

    /// DEMOTE-SAFE: a stored / pre-configured recognizer passed by name (not a
    /// constructor with a #selector) demotes — there's no `#selector` to replay.
    func testGestureNonConstructorArgDemotes() {
        let src = """
        import UIKit
        final class V: UIView {
            let box = UIView()
            let recognizer = UITapGestureRecognizer()
            func setupViews() {
                addSubview(box)
                box.addGestureRecognizer(recognizer)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a non-constructor gesture argument must demote")
    }

    /// DEMOTE-SAFE: a gesture whose `#selector` targets a PRIVATE method is unreachable
    /// from the cross-file thunk extension — demote rather than emit a non-compiling thunk.
    func testGesturePrivateSelectorDemotes() {
        let src = """
        import UIKit
        final class V: UIView {
            let box = UIView()
            func setupViews() {
                addSubview(box)
                box.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(secretTap)))
            }
            private func secretTap() {}
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a private gesture selector is thunk-unreachable → demote")
    }

    // MARK: - Lever 2: NotificationCenter.addObserver

    /// A `viewDidLoad`/`setupViews` whose only non-declarative statement is the canonical
    /// `addObserver(self, selector:#selector(…), name:…, object:…)` now LOWERS: the tree
    /// rides WASM and the observer is recorded as a method-level effect.
    func testObserverEffectLowers() throws {
        let src = """
        import UIKit
        final class KeyboardView: UIView {
            let field = UITextField()
            func setupViews() {
                addSubview(field)
                NotificationCenter.default.addObserver(self, selector: #selector(onKeyboard(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
            }
            @objc func onKeyboard(_ note: Notification) {}
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.guestBody.contains("UI.textField("), cell.guestBody)
        XCTAssertFalse(cell.guestBody.contains("UI.slot("), cell.guestBody)
        XCTAssertEqual(cell.observerEffects.count, 1)
        let o = try XCTUnwrap(cell.observerEffects.first)
        XCTAssertTrue(o.source.hasPrefix("NotificationCenter.default.addObserver(self, selector: #selector(onKeyboard"),
                      o.source)
        XCTAssertTrue(o.source.contains("keyboardWillShowNotification"), o.source)
        XCTAssertTrue(o.id.hasPrefix("uiobs_"), o.id)
        XCTAssertTrue(cell.thunkSafe)
    }

    /// DEMOTE-SAFE: the BLOCK-based `addObserver(forName:object:queue:using:)` (a closure
    /// = guest-unreconstructable logic) is NOT the selector shape → demote.
    func testBlockBasedObserverDemotes() {
        let src = """
        import UIKit
        final class V: UIView {
            let field = UITextField()
            func setupViews() {
                addSubview(field)
                NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { note in
                    self.field.text = "shown"
                }
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "the block-based observer must demote (its closure is opaque logic)")
    }

    /// DEMOTE-SAFE: an observer whose `#selector` targets a PRIVATE method is unreachable
    /// from the cross-file thunk → demote.
    func testObserverPrivateSelectorDemotes() {
        let src = """
        import UIKit
        final class V: UIView {
            let field = UITextField()
            func setupViews() {
                addSubview(field)
                NotificationCenter.default.addObserver(self, selector: #selector(secretNote(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
            }
            private func secretNote(_ n: Notification) {}
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a private observer selector is thunk-unreachable → demote")
    }

    /// Both levers compose: a construction that wires BOTH a gesture and an observer (and
    /// builds a tree) lowers, recording each on its own channel.
    func testGestureAndObserverCompose() throws {
        let src = """
        import UIKit
        final class Composite: UIView {
            let card = UIView()
            func setupViews() {
                addSubview(card)
                card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
                NotificationCenter.default.addObserver(self, selector: #selector(note(_:)), name: .UIApplicationDidBecomeActive, object: nil)
            }
            @objc func tap() {}
            @objc func note(_ n: Notification) {}
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertEqual(cell.gestureWirings.count, 1)
        XCTAssertEqual(cell.observerEffects.count, 1)
        XCTAssertTrue(cell.thunkSafe)
    }
}
