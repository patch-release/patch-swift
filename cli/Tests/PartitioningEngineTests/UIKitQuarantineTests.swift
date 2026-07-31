// SPDX-License-Identifier: Apache-2.0

// UIKitQuarantineTests — Goal 1: GRANULAR PER-STATEMENT PARTITIONING.
// =============================================================================
// Verifies that a single unrecognized-but-isolatable imperative statement is
// QUARANTINED as a native effect (so the surrounding declarative construction still
// lowers) instead of demoting the WHOLE method (the old all-or-nothing rule), AND
// that the demote-safe + build-safe guards hold (an order/data-dependency, a thunk-
// unreachable member, or a modeled-property double-set STILL demotes the method).

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

final class UIKitQuarantineTests: XCTestCase {

    // MARK: - 1. A single weird imperative line no longer demotes the method

    /// A VC `setupViews()` with lowerable declarative statements + 1 unrecognized
    /// `self`-effect (`navigationItem.largeTitleDisplayMode = .always`): the declarative
    /// part lowers, the 1 is a native effect — the whole method NO LONGER demotes.
    func testSelfEffectIsQuarantinedNotContagious() throws {
        let src = """
        import UIKit
        final class HeroVC: UIViewController {
            let titleLabel = UILabel()
            let stack = UIStackView()
            var headline = "Hi"
            func setupViews() {
                titleLabel.text = headline
                titleLabel.font = .boldSystemFont(ofSize: 20)
                stack.axis = .vertical
                stack.spacing = 8
                stack.addArrangedSubview(titleLabel)
                view.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12)
                ])
                navigationItem.largeTitleDisplayMode = .always
            }
        }
        """
        let cells = UIKitCellLowering().lowerAllCells(source: src)
        let vc = try XCTUnwrap(cells.first, "method should lower (not demote)")
        XCTAssertTrue(vc.guestBody.contains("UI.stack(axis: .vertical"), "declarative construction lowered: \(vc.guestBody)")
        XCTAssertEqual(vc.nativeEffects.count, 1, "the one weird line is a native effect")
        let eff = try XCTUnwrap(vc.nativeEffects.first)
        XCTAssertEqual(eff.source, "navigationItem.largeTitleDisplayMode = .always", "verbatim, unchanged")
    }

    // MARK: - 2. A delegate set on a stored (slotted) view quarantines verbatim

    /// `tableView.delegate = self` / `tableView.dataSource = self` on a STORED view (a
    /// `UITableView` that renders as a SLOTTED custom leaf = the real `self.tableView`) is a
    /// non-modeled property set → a native effect replayed VERBATIM against `self` (a bare
    /// `tableView.delegate = self` resolves to `self.tableView` in the thunk's extension).
    func testStoredViewDelegateSetQuarantinesVerbatim() throws {
        let src = """
        import UIKit
        final class ListVC: UIViewController {
            let tableView = UITableView()
            let header = UILabel()
            func setupViews() {
                header.text = "Items"
                view.addSubview(header)
                view.addSubview(tableView)
                tableView.delegate = self
                tableView.dataSource = self
            }
        }
        """
        let cells = UIKitCellLowering().lowerAllCells(source: src)
        let vc = try XCTUnwrap(cells.first, "method lowers (the delegate sets quarantine)")
        XCTAssertTrue(vc.guestBody.contains("UI.label(\"Items\""), "the header label lowers: \(vc.guestBody)")
        let sources = vc.nativeEffects.map(\.source)
        XCTAssertEqual(sources, ["tableView.delegate = self", "tableView.dataSource = self"],
                       "the delegate/dataSource sets quarantine verbatim: \(sources)")
    }

    // MARK: - 2b. A CELL's bare-`self` background set quarantines (no double-set conflict)

    /// A cell's bare `backgroundColor = .clear` (a `self`-set the tree does NOT model — the
    /// content tree is rooted at `contentView`, the CELL's own background is a disjoint
    /// layer behind it) quarantines as a native effect replayed verbatim against `self`,
    /// so the declarative construction still lowers instead of the whole method demoting.
    /// A KNOWN VIEW's modeled-prop set still demotes (test #5) — the new path is bare-`self`
    /// only (head=nil), where no tree double-set can occur.
    func testCellSelfBackgroundSetQuarantines() throws {
        let src = """
        import UIKit
        final class StartUIIconCell: UITableViewCell {
            let iconView = UIImageView()
            let titleLabel = UILabel()
            func setupViews() {
                backgroundColor = .clear
                titleLabel.font = .systemFont(ofSize: 15)
                contentView.addSubview(iconView)
                contentView.addSubview(titleLabel)
            }
        }
        """
        let cells = UIKitCellLowering().lowerAllCells(source: src)
        let cell = try XCTUnwrap(cells.first, "the cell lowers (the self background set quarantines)")
        XCTAssertTrue(cell.guestBody.contains("UI.label("), "the declarative construction lowered: \(cell.guestBody)")
        XCTAssertEqual(cell.nativeEffects.map(\.source), ["backgroundColor = .clear"],
                       "the cell's own backgroundColor set is replayed verbatim against self")
    }

    /// A KNOWN VIEW's `backgroundColor` set we can't lower must still DEMOTE (no silent
    /// native double-set on a view the tree renders) — the bare-`self` carve-out is scoped.
    func testKnownViewBackgroundDoubleSetStillDemotes() throws {
        let src = """
        import UIKit
        final class BadgeCell: UITableViewCell {
            let badge = UIView()
            func setupViews() {
                contentView.addSubview(badge)
                badge.backgroundColor = themeColor()
            }
            func themeColor() -> UIColor { .red }
        }
        """
        let diags = UIKitCellLowering().diagnoseAllCells(source: src)
        let d = try XCTUnwrap(diags.first)
        XCTAssertFalse(d.lowered, "a known view's modeled-prop set we can't lower still demotes: \(d.reason)")
    }

    // MARK: - 3. Source order is preserved (replay ordinal)

    func testNativeEffectsKeepSourceOrder() throws {
        let src = """
        import UIKit
        final class OrderVC: UIViewController {
            let stack = UIStackView()
            let badge = UILabel()
            func setupViews() {
                stack.axis = .vertical
                stack.addArrangedSubview(badge)
                view.addSubview(stack)
                navigationItem.title = "A"
                edgesForExtendedLayout = []
                extendedLayoutIncludesOpaqueBars = true
            }
        }
        """
        let cells = UIKitCellLowering().lowerAllCells(source: src)
        let vc = try XCTUnwrap(cells.first)
        let sources = vc.nativeEffects.sorted { $0.ordinal < $1.ordinal }.map { $0.source }
        XCTAssertEqual(sources, ["navigationItem.title = \"A\"",
                                 "edgesForExtendedLayout = []",
                                 "extendedLayoutIncludesOpaqueBars = true"],
                       "native effects replay in source order: \(sources)")
    }

    // MARK: - 4. DEMOTE-SAFETY: a thunk-unreachable receiver demotes

    /// A method-LOCAL view (`let scratch = UIView()`) the construction never renders, with
    /// a config call on it, is NOT thunk-reachable as a stored member → the whole method
    /// must demote (the cross-file thunk can't reference `scratch`). Build-safe over coverage.
    func testMethodLocalReceiverDemotes() throws {
        let src = """
        import UIKit
        final class LocalVC: UIViewController {
            let stack = UIStackView()
            func setupViews() {
                let scratch = UIScrollView()
                stack.addArrangedSubview(UILabel())
                view.addSubview(stack)
                scratch.delegate = self
            }
        }
        """
        // `scratch` is a method-local view var of a non-widget type → a slotted custom leaf
        // referencing a body-local name (un-slotable), and the `scratch.delegate = self`
        // effect references the method-local `scratch` → not thunk-reachable → demote.
        let diags = UIKitCellLowering().diagnoseAllCells(source: src)
        let d = try XCTUnwrap(diags.first)
        XCTAssertFalse(d.lowered, "a method-local receiver effect demotes: \(d.reason)")
    }

    /// A `private` member reference inside an effect is unreachable from the cross-file
    /// thunk → demote (the established private-wall, generalized to native effects).
    func testPrivateMemberInEffectDemotes() throws {
        let src = """
        import UIKit
        final class PrivVC: UIViewController {
            let stack = UIStackView()
            private let coordinator = NSObject()
            func setupViews() {
                stack.addArrangedSubview(UILabel())
                view.addSubview(stack)
                view.addInteraction(coordinator.makeInteraction())
            }
        }
        """
        let diags = UIKitCellLowering().diagnoseAllCells(source: src)
        let d = try XCTUnwrap(diags.first)
        XCTAssertFalse(d.lowered, "an effect reading a private member demotes: \(d.reason)")
    }

    // MARK: - 5. DEMOTE-SAFETY: a modeled-property double-set is NOT a silent native effect

    /// A set of a MODELED property to a value we can't lower (`label.text = computeText()`)
    /// must DEMOTE — never become a silent native effect that double-sets a property the
    /// tree also expresses. (A modeled prop quarantine would risk build-order disagreement.)
    func testModeledPropertyDoubleSetDemotes() throws {
        let src = """
        import UIKit
        final class TextVC: UIViewController {
            let label = UILabel()
            func setupViews() {
                view.addSubview(label)
                label.text = computeText()
            }
            func computeText() -> String { "x" }
        }
        """
        let diags = UIKitCellLowering().diagnoseAllCells(source: src)
        let d = try XCTUnwrap(diags.first)
        XCTAssertFalse(d.lowered, "a modeled-property set we can't lower demotes (no silent native double-set): \(d.reason)")
    }

    // MARK: - 6. DEMOTE-SAFETY: a marshalled-model read in an effect demotes

    /// An effect that reads a MARSHALLED model field can't be host-resolved over `self` in
    /// the thunk (the thunk's `self` is the cell, not the row model) → demote.
    func testEffectReadingMarshalledInputDemotes() throws {
        let src = """
        import UIKit
        final class RowCell: UITableViewCell {
            let stack = UIStackView()
            func configure(with model: RowModel) {
                stack.addArrangedSubview(UILabel())
                contentView.addSubview(stack)
                stack.accessibilityValue = model.title
            }
        }
        struct RowModel { var title: String }
        """
        let diags = UIKitCellLowering().diagnoseAllCells(source: src)
        let d = try XCTUnwrap(diags.first)
        XCTAssertFalse(d.lowered, "an effect reading a marshalled model field demotes: \(d.reason)")
    }

    // MARK: - 7. DEMOTE-SAFETY: a control-flow / decl statement still demotes

    /// A `for` loop building rows isn't an isolatable expression statement (it carries
    /// structure + binds a loop var) → it still demotes the whole method.
    func testControlFlowStillDemotes() throws {
        let src = """
        import UIKit
        final class LoopVC: UIViewController {
            let stack = UIStackView()
            func setupViews() {
                view.addSubview(stack)
                for i in 0..<3 { stack.addArrangedSubview(UILabel()) }
            }
        }
        """
        let diags = UIKitCellLowering().diagnoseAllCells(source: src)
        let d = try XCTUnwrap(diags.first)
        XCTAssertFalse(d.lowered, "a for-loop still demotes (not an isolatable effect): \(d.reason)")
    }

    /// A `let x = sideEffectingCall()` that binds a value later statements may consume is a
    /// data dependency the engine can't track across the thunk's separate closures → demote.
    func testLocalBindingStillDemotes() throws {
        let src = """
        import UIKit
        final class BindVC: UIViewController {
            let stack = UIStackView()
            func setupViews() {
                view.addSubview(stack)
                let gesture = makeGesture()
                stack.addGestureRecognizer(gesture)
            }
            func makeGesture() -> UIGestureRecognizer { UITapGestureRecognizer() }
        }
        """
        let diags = UIKitCellLowering().diagnoseAllCells(source: src)
        let d = try XCTUnwrap(diags.first)
        XCTAssertFalse(d.lowered, "a local binding consumed later demotes: \(d.reason)")
    }

    /// A partially-resolvable `NSLayoutConstraint.activate([...])` (an unresolvable
    /// constraint element) is NOT quarantined — activation IS the layout tree the IR models,
    /// and a partial resolve would double-apply with a native replay. It demotes.
    func testConstraintActivationNotQuarantined() throws {
        let src = """
        import UIKit
        final class ConstraintVC: UIViewController {
            let stack = UIStackView()
            func setupViews() {
                stack.addArrangedSubview(UILabel())
                view.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.widthAnchor.constraint(equalToConstant: someRuntimeWidth())
                ])
            }
            func someRuntimeWidth() -> CGFloat { 0 }
        }
        """
        let diags = UIKitCellLowering().diagnoseAllCells(source: src)
        let d = try XCTUnwrap(diags.first)
        XCTAssertFalse(d.lowered, "a partial constraint activation demotes, never quarantines: \(d.reason)")
    }

    // MARK: - 8. Multiple weird lines all quarantine (granularity, not just one)

    func testMultipleEffectsAllQuarantine() throws {
        let src = """
        import UIKit
        final class MultiVC: UIViewController {
            let stack = UIStackView()
            let label = UILabel()
            func setupViews() {
                stack.axis = .vertical
                stack.addArrangedSubview(label)
                view.addSubview(stack)
                navigationItem.title = "Home"
                edgesForExtendedLayout = []
                automaticallyAdjustsScrollViewInsets = false
            }
        }
        """
        let cells = UIKitCellLowering().lowerAllCells(source: src)
        let vc = try XCTUnwrap(cells.first, "method lowers with several native effects")
        XCTAssertTrue(vc.guestBody.contains("UI.stack"), "declarative part lowered")
        XCTAssertEqual(vc.nativeEffects.count, 3,
                       "all three non-lowerable self-effects quarantine: \(vc.nativeEffects.map(\.source))")
    }

    // MARK: - 9. The generated thunk emits the native-effect closures (build-safe shape)

    func testThunkEmitsNativeEffectClosures() throws {
        let src = """
        import UIKit
        final class ThunkVC: UIViewController {
            let stack = UIStackView()
            let label = UILabel()
            func setupViews() {
                stack.addArrangedSubview(label)
                view.addSubview(stack)
                navigationItem.title = "Home"
            }
        }
        """
        let gen = UIKitThunkGenerator()
        let file = UIKitThunkGenerator.SourceFile(url: URL(fileURLWithPath: "/tmp/ThunkVC.swift"), text: src)
        let result = gen.prepare(sources: [file])
        XCTAssertTrue(result.cellNames.contains("ThunkVC"), "the VC got a thunk")
        let thunk = result.thunkFileContents
        XCTAssertTrue(thunk.contains("__nativeEffects.append { [self] in"),
                      "the thunk appends a self native effect closure: \(thunk)")
        XCTAssertTrue(thunk.contains("navigationItem.title = \"Home\""),
                      "the verbatim statement is in the thunk closure: \(thunk)")
        XCTAssertTrue(thunk.contains("nativeEffects: __nativeEffects"),
                      "the wiring passes nativeEffects: \(thunk)")
    }
}
