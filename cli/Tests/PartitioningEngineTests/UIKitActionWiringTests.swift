// SPDX-License-Identifier: Apache-2.0

// UIKitActionWiringTests — regression tests for the UIKit round-1 bug fixes:
//
//   * BUG #2  — a `viewDidLoad`-construction VC's generated thunk must NOT emit
//     `override func __patch_viewDidLoad()` (a non-compiling thunk that breaks the app
//     build). Covered in UIKitVCLoweringTests.testViewDidLoadThunkIsNotOverride.
//   * BUG #17/#18 — a lowered control's `addTarget(self, action: #selector(handler), …)`
//     must populate `PatchCellWiring.actions` in the generated thunk, else the control
//     renders but the user's tap/flip is DEAD on device. Here we prove the engine records
//     the id→selector wiring, the thunk emits the handler closure + passes `actions:`, AND
//     a non-`self`-target / `private`-selector addTarget DEMOTES (build-safe).
//   * BUG #39 — a conditionally-gated NON-ARRANGED (plain `addSubview`) child DEMOTES (its
//     active constraints would leave a phantom layout gap a hidden flag can't collapse),
//     while a conditionally-gated ARRANGED (stack) child keeps lowering.

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

final class UIKitActionWiringTests: XCTestCase {

    // MARK: - BUG #17/#18: control actions are wired (not dead) after patching

    /// A switch cell that wires `addTarget(self, action: #selector(didToggle), …)` LOWERS,
    /// records the id→selector action wiring, and the generated thunk supplies the native
    /// handler in `PatchCellWiring.actions` (`__actions[id] = { [self] in self.didToggle() }`).
    func testSwitchActionLowersAndThunkWiresHandler() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class ToggleCell: UITableViewCell {
            let toggle = UISwitch()
            func configure(with m: M) {
                contentView.addSubview(toggle)
                toggle.isOn = true
                toggle.addTarget(self, action: #selector(didToggle), for: .valueChanged)
            }
            @objc func didToggle() {}
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.thunkSafe, "the switch cell auto-routes")
        XCTAssertEqual(cell.actionWirings.count, 1, "one action wiring recorded: \(cell.actionWirings)")
        let wiring = try XCTUnwrap(cell.actionWirings.first)
        XCTAssertEqual(wiring.selector, "didToggle")
        // The action id the wiring carries is the SAME id the lowered control node carries
        // (so the renderer's dispatcher event id matches a handler).
        XCTAssertTrue(cell.guestBody.contains("event: \"\(wiring.id)\""),
                      "the lowered switch carries the action id: \(cell.guestBody)")

        let thunk = UIKitThunkGenerator.renderCellThunk(cell)
        XCTAssertTrue(thunk.contains("__actions[\"\(wiring.id)\"] = { [self] in self.didToggle() }"),
                      "the thunk supplies the native action handler: \(thunk)")
        XCTAssertTrue(thunk.contains("actions: __actions"),
                      "the wiring passes actions to PatchCellWiring: \(thunk)")
    }

    /// A button cell with `addTarget(self, action: #selector(tap), …)` (the exact
    /// `testButtonTitleLabelFontLowers` shape) lowers AND wires its handler — no dead button.
    func testButtonActionLowersAndThunkWiresHandler() throws {
        let src = """
        import UIKit
        struct M { let label: String }
        final class T: UITableViewCell {
            let btn = UIButton(type: .system)
            func configure(with m: M) {
                btn.setTitle(m.label, for: .normal)
                btn.addTarget(self, action: #selector(tap), for: .touchUpInside)
                contentView.addSubview(btn)
            }
            @objc func tap() {}
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.thunkSafe)
        XCTAssertTrue(cell.guestBody.contains("UI.button("), "the button lowers: \(cell.guestBody)")
        let wiring = try XCTUnwrap(cell.actionWirings.first)
        XCTAssertEqual(wiring.selector, "tap")
        let thunk = UIKitThunkGenerator.renderCellThunk(cell)
        XCTAssertTrue(thunk.contains("self.tap()"), "the button handler is wired: \(thunk)")
        XCTAssertTrue(thunk.contains("actions: __actions"), thunk)
    }

    /// DEMOTE-SAFE: a `#selector` handler that is `private` is unreachable from the
    /// cross-file `@_dynamicReplacement` thunk — the construction DEMOTES (rather than
    /// shipping a non-compiling thunk or a dead control).
    func testPrivateSelectorActionDemotes() throws {
        let src = """
        import UIKit
        struct M { let enabled: Bool }
        final class ToggleCell: UITableViewCell {
            let toggle = UISwitch()
            func configure(with m: M) {
                contentView.addSubview(toggle)
                toggle.addTarget(self, action: #selector(didToggle), for: .valueChanged)
            }
            @objc private func didToggle() {}
        }
        """
        let cells = UIKitCellLowering().lowerAllCells(source: src)
        XCTAssertTrue(cells.isEmpty, "a private-selector addTarget demotes the whole method")
    }

    /// DEMOTE-SAFE: an `addTarget` whose target ISN'T `self` (a coordinator/other object)
    /// can't be replayed as `self.<selector>()` from the thunk — the construction DEMOTES.
    func testNonSelfTargetActionDemotes() throws {
        let src = """
        import UIKit
        struct M { let enabled: Bool }
        final class ToggleCell: UITableViewCell {
            let toggle = UISwitch()
            var coordinator = NSObject()
            func configure(with m: M) {
                contentView.addSubview(toggle)
                toggle.addTarget(coordinator, action: #selector(NSObject.description), for: .valueChanged)
            }
        }
        """
        let cells = UIKitCellLowering().lowerAllCells(source: src)
        XCTAssertTrue(cells.isEmpty, "a non-self target addTarget demotes the whole method")
    }

    // MARK: - BUG #39: conditional non-arranged child demotes (no phantom gap)

    /// A model-gated badge laid out by EXPLICIT CONSTRAINTS (added via plain `addSubview`,
    /// NOT a stack) DEMOTES: hiding it would leave its 24pt height + sibling-relative
    /// constraints active → a phantom gap the native code (which never adds it) lacks.
    func testConditionalNonArrangedChildDemotes() throws {
        let src = """
        import UIKit
        struct M { let isPremium: Bool }
        final class RowCell: UITableViewCell {
            let title = UILabel()
            let badge = UILabel()
            func configure(with m: M) {
                contentView.addSubview(title)
                if m.isPremium { contentView.addSubview(badge) }
                NSLayoutConstraint.activate([
                    badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
                    badge.heightAnchor.constraint(equalToConstant: 24),
                    title.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 4)
                ])
            }
        }
        """
        let cells = UIKitCellLowering().lowerAllCells(source: src)
        XCTAssertTrue(cells.isEmpty,
                      "a conditionally-gated non-arranged (constraint-driven) child demotes")
    }

    /// COMPANION (no over-demote): the SAME conditional child added to a UIStackView
    /// (`addArrangedSubview`) STILL lowers — a hidden arranged subview collapses faithfully.
    func testConditionalArrangedChildStillLowers() throws {
        let src = """
        import UIKit
        struct M { let isPremium: Bool }
        final class RowCell: UITableViewCell {
            let title = UILabel()
            let badge = UILabel()
            let stack = UIStackView()
            func configure(with m: M) {
                stack.axis = .vertical
                stack.addArrangedSubview(title)
                if m.isPremium { stack.addArrangedSubview(badge) }
                contentView.addSubview(stack)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.guestBody.contains(".hidden(!(isPremium))"),
                      "the arranged child stays gated (collapses faithfully): \(cell.guestBody)")
    }
}
