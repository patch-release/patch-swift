// SPDX-License-Identifier: Apache-2.0

// UIKitR2BugTests — regression tests for the round-2 adversarial UIKit lowering bugs
// (build-safe = demote-safe: a wrong/unsafe shape DEMOTES to native; never a dead
// control, a non-compiling thunk, or a silent wrong-render).
//
//   * R2-#2/#31 — addTarget to a SENDER-taking #selector handler (`@objc func tap(_:)`)
//     demotes (the thunk replays `self.tap()` with 0 args → would compile-fail). A
//     zero-arg handler still lowers + wires.
//   * R2-#7 — a conditionally-added CUSTOM-slot child demotes (the slot can't carry the
//     visibility gate, so it would always render).
//   * R2-#8 — a `self.<method>(...)` call (a same-class helper) is NOT quarantined as a
//     native effect (it may build views re-run on every reuse) → demote.
//   * R2-#29 — a color/number token over an EXTENSION-declared private member demotes
//     (the thunk can't reach it).
//   * R2-#30/#92 — a conditional property set on a view added unconditionally demotes
//     (the property would apply across all rows).
//   * R2-#32 — a multi-label construction selector (`configure(with:animated:)`) demotes.
//   * R2-#90 — an async/throws/non-Void construction method demotes.
//   * R2-#91 — UISwitch `isOn` bound to a marshalled Bool (or ternary) LOWERS (coverage).
//   * R2-#93 — a gesture/observer construction referencing a method-local demotes.
//   * R2-#94 — an anonymous `_:` model param demotes (can't forward `configure(nil)`).

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

final class UIKitR2BugTests: XCTestCase {

    // MARK: - R2-#2/#31: addTarget sender-arg selector arity

    /// A `#selector(handler(_:))` whose handler takes a SENDER demotes — the thunk would
    /// replay `self.handler()` (0 args) against a 1-arg method → app build break.
    func testSenderArgSelectorActionDemotes() throws {
        let src = """
        import UIKit
        struct M { let on: Bool }
        final class ToggleCell: UITableViewCell {
            let toggle = UISwitch()
            func configure(with m: M) {
                contentView.addSubview(toggle)
                toggle.addTarget(self, action: #selector(didToggle(_:)), for: .valueChanged)
            }
            @objc func didToggle(_ sender: UISwitch) {}
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a sender-taking #selector handler demotes (no zero-arg thunk replay)")
    }

    /// COMPANION (no over-demote): a ZERO-arg handler still lowers + wires.
    func testZeroArgSelectorActionStillLowers() throws {
        let src = """
        import UIKit
        struct M { let on: Bool }
        final class ToggleCell: UITableViewCell {
            let toggle = UISwitch()
            func configure(with m: M) {
                contentView.addSubview(toggle)
                toggle.addTarget(self, action: #selector(didToggle), for: .valueChanged)
            }
            @objc func didToggle() {}
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertEqual(cell.actionWirings.first?.selector, "didToggle")
    }

    /// An inherited / cross-file (unknown-arity) selector demotes (can't vouch arity 0).
    func testUnknownAritySelectorActionDemotes() throws {
        let src = """
        import UIKit
        struct M { let on: Bool }
        final class ToggleCell: UITableViewCell {
            let toggle = UISwitch()
            func configure(with m: M) {
                contentView.addSubview(toggle)
                toggle.addTarget(self, action: #selector(someInheritedHandler), for: .valueChanged)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "an unknown-arity selector demotes (engine can't vouch zero-arg)")
    }

    // MARK: - R2-#7: conditionally-gated custom-slot child

    /// `if isPremium { stack.addArrangedSubview(badge) }` where `badge` is a CUSTOM view
    /// demotes — the slot can't carry the visibility gate (it would always render).
    func testConditionalCustomSlotChildDemotes() throws {
        let src = """
        import UIKit
        struct M { let isPremium: Bool }
        final class RowCell: UITableViewCell {
            let title = UILabel()
            let badge = PremiumBadgeView()
            let stack = UIStackView()
            func configure(with m: M) {
                stack.axis = .vertical
                stack.addArrangedSubview(title)
                if m.isPremium {
                    stack.addArrangedSubview(badge)
                }
                contentView.addSubview(stack)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a conditionally-gated custom-slot child demotes (can't gate the slot)")
    }

    // MARK: - R2-#8: self-method call quarantine

    /// A `self.<method>(...)` same-class helper call is NOT quarantined (it may build view
    /// structure re-run on reuse) → the whole method demotes.
    func testSelfMethodCallDemotes() throws {
        let src = """
        import UIKit
        struct M { let style: Int }
        final class FooCell: UITableViewCell {
            let stack = UIStackView()
            let title = UILabel()
            func configure(with m: M) {
                stack.addArrangedSubview(title)
                contentView.addSubview(stack)
                self.decorate(for: m.style)
            }
            func decorate(for style: Int) {}
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a self.<method>(...) helper call demotes (not quarantined)")
    }

    // MARK: - R2-#29: extension-private token member

    /// A color token whose source references an EXTENSION-declared private member (as a base
    /// identifier in a member-access/call) demotes — the cross-file thunk can't reach it
    /// (would compile-fail). Without the extension-aware `inaccessibleMemberNames`, the engine
    /// wouldn't know `themeColor` is private and would emit a non-compiling token resolver.
    func testExtensionPrivateColorTokenDemotes() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class FooCell: UITableViewCell {
            let title = UILabel()
            func configure(with m: M) {
                title.text = m.title
                title.textColor = themeColor.withAlphaComponent(0.5)
                contentView.addSubview(title)
            }
        }
        private extension FooCell {
            var themeColor: UIColor { .systemRed }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a color token over an extension-private member demotes")
    }

    /// COMPANION (no over-demote): the SAME token over a PUBLIC extension member still lowers
    /// (it IS reachable from the cross-file thunk).
    func testExtensionPublicColorTokenLowers() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class FooCell: UITableViewCell {
            let title = UILabel()
            func configure(with m: M) {
                title.text = m.title
                title.textColor = themeColor.withAlphaComponent(0.5)
                contentView.addSubview(title)
            }
        }
        extension FooCell {
            var themeColor: UIColor { .systemRed }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.hostTokens.contains { $0.kind == .color },
                      "a token over a public extension member lowers: \(cell.hostTokens)")
    }

    // MARK: - R2-#30/#92: conditional property set on an ungated view

    /// `if isError { titleLabel.textColor = .systemRed }` with `titleLabel` added OUTSIDE
    /// the branch demotes (the color would apply unconditionally across all rows).
    func testConditionalPropertyOnUngatedViewDemotes() throws {
        let src = """
        import UIKit
        struct M { let isError: Bool }
        final class RowCell: UITableViewCell {
            let titleLabel = UILabel()
            let stack = UIStackView()
            func configure(with m: M) {
                stack.addArrangedSubview(titleLabel)
                if m.isError { titleLabel.textColor = .systemRed }
                contentView.addSubview(stack)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a conditional property set on an unconditionally-added view demotes")
    }

    /// R2-#92: a badge CONFIGURED in a branch but ADDED by a later unconditional
    /// variadic `addSubviews(stack, badge)` demotes (its conditional props would apply
    /// unconditionally).
    func testConditionalConfigThenUnconditionalAddDemotes() throws {
        let src = """
        import UIKit
        struct M { let isPremium: Bool }
        final class RowCell: UITableViewCell {
            let stack = UIStackView()
            let badge = UILabel()
            func configure(with m: M) {
                if m.isPremium { badge.text = "PRO" }
                contentView.addSubviews(stack, badge)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a view configured in a branch but added unconditionally demotes")
    }

    /// COMPANION (no over-demote): configure + add in the SAME branch still lowers.
    func testConditionalConfigAndAddInSameBranchLowers() throws {
        let src = """
        import UIKit
        struct M { let isPremium: Bool }
        final class RowCell: UITableViewCell {
            let stack = UIStackView()
            let badge = UILabel()
            func configure(with m: M) {
                stack.axis = .vertical
                if m.isPremium {
                    badge.text = "PRO"
                    stack.addArrangedSubview(badge)
                }
                contentView.addSubview(stack)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.guestBody.contains(".hidden(!(isPremium))"),
                      "configure+add in the same branch stays gated + lowers: \(cell.guestBody)")
    }

    // MARK: - R2-#32: multi-label construction selector

    /// `configure(with model:, animated:)` demotes — `originalCall` can't forward the
    /// extra `animated:` param (it would emit an uncompilable call).
    func testMultiLabelConstructionMethodDemotes() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class FooCell: UITableViewCell {
            let title = UILabel()
            func configure(with model: M, animated: Bool) {
                title.text = model.title
                contentView.addSubview(title)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a multi-param construction method demotes (can't forward extra params)")
    }

    // MARK: - R2-#90: async/throws/non-Void construction method

    func testThrowingConstructionMethodDemotes() throws {
        let src = """
        import UIKit
        final class FooVC: UIViewController {
            let title = UILabel()
            func setupViews() throws {
                view.addSubview(title)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a throwing construction method demotes (thunk signature would mismatch)")
    }

    func testNonVoidConstructionMethodDemotes() throws {
        let src = """
        import UIKit
        final class FooVC: UIViewController {
            let title = UILabel()
            func setupViews() -> Bool {
                view.addSubview(title)
                return true
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a non-Void construction method demotes")
    }

    // MARK: - R2-#91: UISwitch isOn bound to a marshalled Bool (coverage win)

    func testSwitchIsOnBoundInputLowers() throws {
        let src = """
        import UIKit
        struct M { let isEnabled: Bool }
        final class ToggleCell: UITableViewCell {
            let toggle = UISwitch()
            func configure(with model: M) {
                toggle.isOn = model.isEnabled
                contentView.addSubview(toggle)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.guestBody.contains("UI.switchControl(isOn: isEnabled"),
                      "isOn binds the marshalled Bool input: \(cell.guestBody)")
        XCTAssertTrue(cell.inputs.contains { $0.name == "model.isEnabled" && $0.kind == .bool })
    }

    func testSwitchIsOnTernaryLowers() throws {
        let src = """
        import UIKit
        struct M { let isEnabled: Bool }
        final class ToggleCell: UITableViewCell {
            let toggle = UISwitch()
            func configure(with model: M) {
                toggle.isOn = model.isEnabled ? true : false
                contentView.addSubview(toggle)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.guestBody.contains("UI.switchControl(isOn: (isEnabled ? true : false)"),
                      "isOn binds a model-driven ternary: \(cell.guestBody)")
    }

    func testSwitchIsOnLiteralStillLowers() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class ToggleCell: UITableViewCell {
            let toggle = UISwitch()
            func configure(with model: M) {
                toggle.isOn = true
                contentView.addSubview(toggle)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.guestBody.contains("UI.switchControl(isOn: true"),
                      "a literal isOn still folds: \(cell.guestBody)")
    }

    // MARK: - R2-#93: gesture/observer referencing a method-local

    /// A gesture construction referencing a method-LOCAL binding demotes — the verbatim
    /// replay in the cross-file thunk couldn't see it.
    func testGestureReferencingMethodLocalDemotes() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class FooCell: UITableViewCell {
            let avatar = UIImageView()
            func configure(with m: M) {
                contentView.addSubview(avatar)
                let localThreshold = 10
                avatar.addGestureRecognizer(MyTapGesture(target: self, action: #selector(handleTap), threshold: localThreshold))
            }
            @objc func handleTap() {}
        }
        """
        // MyTapGesture isn't a recognized gesture type → already demotes on the type gate;
        // assert demote regardless (the construction never ships a thunk-unreachable replay).
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a gesture construction referencing a method-local demotes")
    }

    /// An observer registration whose `object:` arg references a method-local demotes.
    func testObserverReferencingMethodLocalDemotes() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class FooCell: UITableViewCell {
            let title = UILabel()
            func configure(with m: M) {
                title.text = m.title
                contentView.addSubview(title)
                let localOwner = NSObject()
                NotificationCenter.default.addObserver(self, selector: #selector(onPing), name: .myPing, object: localOwner)
            }
            @objc func onPing() {}
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "an observer registration referencing a method-local demotes")
    }

    /// COMPANION (no over-demote): an observer whose args are all reachable (a global
    /// notification name, self) still lowers as an effect.
    func testReachableObserverStillLowers() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class FooCell: UITableViewCell {
            let title = UILabel()
            func configure(with m: M) {
                title.text = m.title
                contentView.addSubview(title)
                NotificationCenter.default.addObserver(self, selector: #selector(onPing), name: .myPing, object: nil)
            }
            @objc func onPing() {}
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertEqual(cell.observerEffects.count, 1,
                       "a fully-reachable observer registration still lowers: \(cell.observerEffects)")
    }

    // MARK: - R2-#94: anonymous model param

    /// `configure(_: Model)` (anonymous, no internal name) demotes — the thunk can't forward
    /// the param (it would fabricate `configure(nil)`).
    func testAnonymousModelParamDemotes() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class FooCell: UITableViewCell {
            let title = UILabel()
            var stored = "hi"
            func configure(_: M) {
                title.text = stored
                contentView.addSubview(title)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "an anonymous `_:` model param demotes (can't forward configure(nil))")
    }

    /// COMPANION (no over-demote): a NAMED `_ model:` param forwards fine + still lowers.
    func testNamedUnlabeledModelParamLowers() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class FooCell: UITableViewCell {
            let title = UILabel()
            func configure(_ model: M) {
                title.text = model.title
                contentView.addSubview(title)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertEqual(cell.modelParamName, "model")
        XCTAssertTrue(cell.guestBody.contains("UI.label(title"), cell.guestBody)
    }
}
