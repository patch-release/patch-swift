// SPDX-License-Identifier: Apache-2.0

// UIKitGrammarLeversTests — the engine-side tests for the UIKit-view "milk-more"
// grammar levers (wave-2-B): ROOT-view property config (Lever A), namespace
// static-constant resolution (Lever B), and the broadened construction grammar
// (Lever C: variadic `addSubviews`, root/safe-area anchors).
// =============================================================================
// Every lever is demote-safe / ALL-OR-NOTHING-PER-METHOD. Each test proves BOTH
// directions where it matters: the construct LOWERS (rides WASM) AND a
// native-touching form STILL DEMOTES (no false negative). A WASM round-trip
// proves a root-configured VC using a namespace constant renders faithfully.

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

final class UIKitGrammarLeversTests: XCTestCase {

    // MARK: - Lever A: root-view property configuration

    /// A `UIView` subclass setting its OWN `backgroundColor` / `layer.cornerRadius` /
    /// `clipsToBounds` (bare implicit-self) lowers: the props fold onto the synthetic
    /// root container node, the single child stays a child of it.
    func testRootViewPropertyConfigLowers() throws {
        let src = """
        import UIKit
        final class RoundedSegmentedView: UIView {
            let stack = UIStackView()
            func setupViews() {
                layer.cornerRadius = 12
                layer.masksToBounds = true
                backgroundColor = .systemBlue
                addSubview(stack)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.container("), "root is a styled container: \(g)")
        XCTAssertTrue(g.contains(".background(.named(\"blue\"))"), "root background folds: \(g)")
        XCTAssertTrue(g.contains(".cornerRadius(12)"), "root corner radius folds: \(g)")
        XCTAssertTrue(g.contains(".clipsToBounds(true)"), "root masksToBounds folds: \(g)")
        XCTAssertTrue(cell.thunkSafe)
        XCTAssertFalse(g.contains("UI.slot("), "no native slot: \(g)")
    }

    /// `view.backgroundColor = .systemGroupedBackground` on a VC's `view` lowers (the VC
    /// root form). With no content children added it still produces the styled root.
    func testVCRootViewBackgroundLowersAlone() throws {
        let src = """
        import UIKit
        final class PlainVC: UIViewController {
            let label = UILabel()
            func setupViews() {
                view.backgroundColor = .systemBackground
                label.text = "hi"
                view.addSubview(label)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.container("), g)
        XCTAssertTrue(g.contains(".background(.named(\"systemBackground\"))"), g)
        XCTAssertTrue(g.contains("UI.label(\"hi\")"), g)
    }

    /// Goal 1 (§B.5 — GRANULAR PER-STATEMENT PARTITIONING): a root property we don't model
    /// but that is a SAFE self-effect (`self.title = "Settings"` — the VC's nav title, a
    /// non-content-tree surface) is no longer a whole-method demote: it QUARANTINES as a
    /// native effect the thunk replays verbatim against `self` (setting the VC's title
    /// natively is exactly right), so the declarative construction still lowers.
    func testUnmodelableRootPropertyQuarantines() throws {
        let src = """
        import UIKit
        final class TitledVC: UIViewController {
            let label = UILabel()
            func setupViews() {
                self.title = "Settings"
                view.addSubview(label)
            }
        }
        """
        let lowered = UIKitCellLowering().lowerAllCells(source: src)
        let vc = try XCTUnwrap(lowered.first, "the method lowers (the title set quarantines)")
        XCTAssertEqual(vc.nativeEffects.map(\.source), ["self.title = \"Settings\""],
                       "the nav-title set is a native effect, not a demote: \(vc.nativeEffects)")
    }

    /// A root background set to a custom design-system color (a member-access path the
    /// cross-file thunk CAN evaluate) now LOWERS via the color-token channel (Lever D) —
    /// it rides as `.hostToken(id)` rather than demoting. (The OLD pre-Lever-D behavior
    /// demoted; the token channel is the coverage win.)
    func testRootCustomColorLowersViaToken() throws {
        let src = """
        import UIKit
        final class CustomColorVC: UIViewController {
            let label = UILabel()
            func setupViews() {
                view.backgroundColor = SomeUnknownPalette.deep
                view.addSubview(label)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.guestBody.contains(".background(.hostToken(\""), cell.guestBody)
        XCTAssertEqual(cell.hostTokens.first?.source, "SomeUnknownPalette.deep")
    }

    // MARK: - Lever B: namespace static-constant resolution

    /// A constraint `constant: UX.spacing` referencing a caseless-namespace static-let
    /// SIMPLE LITERAL resolves to the value at build time (no demote).
    func testNamespaceConstantConstraintResolves() throws {
        let src = """
        import UIKit
        enum UX {
            static let spacing: CGFloat = 12
            static let iconSize: CGFloat = 24
        }
        final class HeaderView: UIView {
            let icon = UIImageView()
            func setupViews() {
                addSubview(icon)
                NSLayoutConstraint.activate([
                    icon.topAnchor.constraint(equalTo: topAnchor, constant: UX.spacing),
                    icon.widthAnchor.constraint(equalToConstant: UX.iconSize)
                ])
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("constant: 12"), "UX.spacing resolved to 12: \(g)")
        XCTAssertTrue(g.contains("size(.width, 24"), "UX.iconSize resolved to 24: \(g)")
        XCTAssertFalse(g.contains("UI.slot("), g)
    }

    /// A namespace constant in a NUMERIC property position (`spacing`, `numberOfLines`)
    /// resolves too — the design-system constant table generalizes.
    func testNamespaceConstantPropertyResolves() throws {
        let src = """
        import UIKit
        enum Metrics { static let gap: CGFloat = 8; static let lines = 2 }
        final class RowView: UIView {
            let stack = UIStackView()
            let label = UILabel()
            func setupViews() {
                stack.axis = .vertical
                stack.spacing = Metrics.gap
                label.numberOfLines = Metrics.lines
                stack.addArrangedSubview(label)
                addSubview(stack)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("spacing: 8"), "Metrics.gap resolved: \(g)")
        XCTAssertTrue(g.contains("numberOfLines: 2"), "Metrics.lines resolved: \(g)")
    }

    /// A NESTED namespace (`enum Layout { enum UX { static let pad = 16 } }`) resolves via
    /// the immediate-path form (`UX.pad`).
    func testNestedNamespaceConstantResolves() throws {
        let src = """
        import UIKit
        enum Layout { enum UX { static let pad: CGFloat = 16 } }
        final class PadView: UIView {
            let inner = UIView()
            func setupViews() {
                addSubview(inner)
                inner.topAnchor.constraint(equalTo: topAnchor, constant: Layout.UX.pad).isActive = true
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.guestBody.contains("constant: 16"), "Layout.UX.pad resolved: \(cell.guestBody)")
    }

    /// A cell's OWN nested `enum UX` constants resolve (the closer scope).
    func testCellNestedNamespaceConstantResolves() throws {
        let src = """
        import UIKit
        final class TileCell: UICollectionViewCell {
            enum UX { static let radius: CGFloat = 10 }
            let card = UIView()
            func configure() {
                card.layer.cornerRadius = UX.radius
                contentView.addSubview(card)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.guestBody.contains(".cornerRadius(10)"), cell.guestBody)
    }

    /// A NON-literal namespace static (a computed/derived value `= computeSpacing()`) is
    /// NOT build-time foldable (so Lever B can't print a literal), but it IS a stable,
    /// thunk-reachable design constant — so it now LOWERS via the NUMERIC host-token
    /// channel (Lever D for numbers) rather than demoting: the guest reads a reserved
    /// `__numtok_<id>` input and the thunk resolves `Double(UX.derived)` natively → the
    /// real value the SDK merges in. (The OLD behavior demoted because there was no
    /// host-resolution path; this is the deferred-lever coverage win.)
    func testNonLiteralNamespaceConstantLowersViaToken() throws {
        let src = """
        import UIKit
        enum UX { static let derived: CGFloat = computeSpacing() }
        final class DerivedView: UIView {
            let inner = UIView()
            func setupViews() {
                addSubview(inner)
                inner.topAnchor.constraint(equalTo: topAnchor, constant: UX.derived).isActive = true
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.guestBody.contains("constant: __numtok_"),
                      "a derived namespace static host-tokenizes: \(cell.guestBody)")
        XCTAssertFalse(cell.guestBody.contains("UX.derived"), "no symbol leaks into WASM: \(cell.guestBody)")
        let tok = try XCTUnwrap(cell.hostTokens.first { $0.kind == .number })
        XCTAssertEqual(tok.source, "UX.derived")
    }

    // MARK: - Lever C: broadened grammar (variadic addSubviews + root/safe-area anchors)

    /// A variadic `self.addSubviews(a, b, c)` (the common helper-extension convention)
    /// lowers: each arg is added as a content-root child, in order.
    func testVariadicAddSubviewsLowers() throws {
        let src = """
        import UIKit
        final class StatusView: UIView {
            let icon = UIImageView()
            let label = UILabel()
            let arrow = UIImageView()
            func setupViews() {
                self.addSubviews(icon, label, arrow)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.container("), g)
        // All three children present (icon + arrow are imageViews, label is a label).
        XCTAssertEqual(g.components(separatedBy: "UI.image(").count - 1, 2, "two imageViews: \(g)")
        XCTAssertTrue(g.contains("UI.label("), g)
        XCTAssertFalse(g.contains("UI.slot("), g)
    }

    /// A variadic `stack.addArrangedSubviews(a, b)` adds arranged children.
    func testVariadicAddArrangedSubviewsLowers() throws {
        let src = """
        import UIKit
        final class BarView: UIView {
            let stack = UIStackView()
            let a = UILabel()
            let b = UILabel()
            func setupViews() {
                stack.axis = .horizontal
                stack.addArrangedSubviews(a, b)
                addSubview(stack)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.stack(axis: .horizontal"), g)
        XCTAssertEqual(g.components(separatedBy: "UI.label(").count - 1, 2, "two arranged labels: \(g)")
    }

    /// A constraint to `self.topAnchor` / bare `safeAreaLayoutGuide.topAnchor` (a UIView/VC
    /// subclass building into itself) resolves to `.superview` / `.safeArea`.
    func testRootAndSafeAreaAnchorsResolve() throws {
        let src = """
        import UIKit
        final class PinView: UIView {
            let inner = UIView()
            func setupViews() {
                addSubview(inner)
                NSLayoutConstraint.activate([
                    inner.topAnchor.constraint(equalTo: self.topAnchor, constant: 8),
                    inner.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)
                ])
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("of: .superview"), "self.topAnchor → superview: \(g)")
        XCTAssertTrue(g.contains("of: .safeArea"), "safeAreaLayoutGuide → safeArea: \(g)")
        XCTAssertFalse(g.contains("UI.slot("), g)
    }

    /// DEMOTE-SAFE: a variadic `addSubviews` whose arg is a literal `UIView()` (not a known
    /// view) still demotes — we never silently add a non-view.
    func testVariadicAddSubviewsLiteralArgDemotes() throws {
        let src = """
        import UIKit
        final class BadView: UIView {
            let a = UILabel()
            func setupViews() {
                self.addSubviews(a, UIView())
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a literal-view arg in addSubviews must demote")
    }

    // MARK: - Lever F: `[viewList].forEach { … }` / `.forEach(parent.addSubview)`

    /// A METHOD-REFERENCE forEach — `[a, b].forEach(stack.addArrangedSubview)` (the #1
    /// remaining UIKit-construction demote idiom) — adds each array element as an arranged
    /// child of the stack, in array order.
    func testForEachMethodRefAddArrangedSubviewLowers() throws {
        let src = """
        import UIKit
        final class BreachView: UIView {
            let stack = UIStackView()
            let titleLabel = UILabel()
            let descriptionLabel = UILabel()
            let button = UIButton()
            func setupViews() {
                stack.axis = .vertical
                [titleLabel, descriptionLabel, button].forEach(stack.addArrangedSubview)
                addSubview(stack)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.stack(axis: .vertical"), g)
        // Two labels + one button, all arranged inside the stack.
        XCTAssertEqual(g.components(separatedBy: "UI.label(").count - 1, 2, "two arranged labels: \(g)")
        XCTAssertTrue(g.contains("UI.button("), "the button lowers as an arranged child: \(g)")
        XCTAssertFalse(g.contains("UI.slot("), "no native slot — the forEach wiring lowers: \(g)")
        XCTAssertTrue(cell.thunkSafe)
    }

    /// A bare-method-reference forEach — `[a, b].forEach(addSubview)` (implicit self /
    /// content root, the VC/View-into-self form) — adds each element to the content root.
    func testForEachBareMethodRefAddSubviewLowers() throws {
        let src = """
        import UIKit
        final class HandleField: UIView {
            let prefixLabel = UILabel()
            let handleTextField = UITextField()
            let domainLabel = UILabel()
            func setupViews() {
                [prefixLabel, handleTextField, domainLabel].forEach(addSubview)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.container("), "three content-root children → a container: \(g)")
        XCTAssertEqual(g.components(separatedBy: "UI.label(").count - 1, 2, "two labels: \(g)")
        XCTAssertFalse(g.contains("UI.slot("), g)
    }

    /// A CLOSURE forEach doing only a TAMIC no-op + an `addSubview($0)` wiring lowers: the
    /// TAMIC set is tolerated (the renderer sets it uniformly), the add wires each element.
    func testForEachClosureTamicPlusAddSubviewLowers() throws {
        let src = """
        import UIKit
        final class PlaceholderContainer: UIView {
            let placeholderView = UILabel()
            let searchResultsView = UILabel()
            func setupViews() {
                [placeholderView, searchResultsView].forEach {
                    $0.translatesAutoresizingMaskIntoConstraints = false
                    addSubview($0)
                }
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.container("), g)
        XCTAssertEqual(g.components(separatedBy: "UI.label(").count - 1, 2, "both views wired: \(g)")
        XCTAssertFalse(g.contains("UI.slot("), g)
    }

    /// A NAMED-PARAM closure (`{ view in … }`) over a parent's `addArrangedSubview` lowers.
    func testForEachNamedParamClosureLowers() throws {
        let src = """
        import UIKit
        final class ButtonBar: UIView {
            let stack = UIStackView()
            let undo = UIButton()
            let confirm = UIButton()
            func setupViews() {
                [undo, confirm].forEach { button in
                    button.translatesAutoresizingMaskIntoConstraints = false
                    stack.addArrangedSubview(button)
                }
                addSubview(stack)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.stack("), g)
        XCTAssertEqual(g.components(separatedBy: "UI.button(").count - 1, 2, "two arranged buttons: \(g)")
    }

    /// A TAMIC-ONLY closure forEach (no add) is a pure no-op — accepted, lowers nothing of
    /// its own, and the surrounding construction still lowers.
    func testForEachTamicOnlyClosureToleratedAndOthersLower() throws {
        let src = """
        import UIKit
        final class FormView: UIView {
            let emailField = UITextField()
            let passwordField = UITextField()
            let contentStack = UIStackView()
            func setupViews() {
                [passwordField, emailField, contentStack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
                contentStack.addArrangedSubview(emailField)
                contentStack.addArrangedSubview(passwordField)
                addSubview(contentStack)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.stack("), "the stack lowers; the TAMIC-only forEach is a no-op: \(g)")
        XCTAssertFalse(g.contains("UI.slot("), g)
    }

    /// DEMOTE-SAFE: a forEach over an array containing a NON-view (a literal `UIView()` or
    /// a non-view value) demotes — we never silently add a non-view.
    func testForEachNonViewArrayElementDemotes() throws {
        let src = """
        import UIKit
        final class BadView: UIView {
            let a = UILabel()
            func setupViews() {
                [a, UIView()].forEach(addSubview)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a non-view element in a forEach array must demote")
    }

    /// DEMOTE-SAFE: a forEach CLOSURE with a per-element statement we can't model (a
    /// property set on `$0`, an `NSLayoutConstraint.activate` of `$0`-relative anchors)
    /// demotes — that's per-element structure the flat tree can't capture.
    func testForEachClosureWithUnmodeledStatementDemotes() throws {
        let src = """
        import UIKit
        final class GradientView: UIView {
            let dot1 = UIView()
            let dot2 = UIView()
            func setupViews() {
                [dot1, dot2].forEach {
                    $0.backgroundColor = .red
                    addSubview($0)
                }
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a forEach closure with an unmodeled per-element property set must demote")
    }

    /// DEMOTE-SAFE: a forEach over a NAMED collection (`sectionButtons.forEach { … }`, not
    /// an array LITERAL of known views) demotes — the element set isn't statically known.
    func testForEachOverNamedCollectionDemotes() throws {
        let src = """
        import UIKit
        final class TabView: UIView {
            let container = UIStackView()
            func setupViews() {
                sectionButtons.forEach(container.addArrangedSubview)
                addSubview(container)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a forEach over a non-literal collection must demote (elements unknown)")
    }

    // MARK: - Lever D: design-system color tokens

    /// A custom design-system color (`SemanticColors.View.backgroundDefault`) on the root
    /// / a label lowers as a `.hostToken(id)` — recorded with a resolver source — instead
    /// of demoting. The guest tree carries only the id; no `Semantic…` leaks into WASM.
    func testDesignSystemColorTokenLowers() throws {
        let src = """
        import UIKit
        struct M { let name: String }
        final class BrandCell: UITableViewCell {
            let nameLabel = UILabel()
            func configure(with model: M) {
                contentView.backgroundColor = SemanticColors.View.backgroundDefault
                nameLabel.text = model.name
                nameLabel.textColor = Palette.ink
                contentView.addSubview(nameLabel)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains(".background(.hostToken(\""), "root color is a token: \(g)")
        XCTAssertTrue(g.contains("textColor: .hostToken(\""), "label color is a token: \(g)")
        XCTAssertFalse(g.contains("SemanticColors"), "no design-system symbol leaks into WASM: \(g)")
        XCTAssertFalse(g.contains("Palette"), g)
        XCTAssertEqual(cell.hostTokens.count, 2, "two color tokens recorded")
        XCTAssertTrue(cell.hostTokens.allSatisfy { $0.kind == .color })
        XCTAssertTrue(cell.hostTokens.contains { $0.source == "SemanticColors.View.backgroundDefault" })
        XCTAssertTrue(cell.hostTokens.contains { $0.source == "Palette.ink" })
        XCTAssertTrue(cell.thunkSafe, "a token cell is auto-routable")
    }

    /// A token id is content-stable (FNV over the source) — the thunk + engine agree.
    func testColorTokenIDIsStable() throws {
        let src = """
        import UIKit
        final class V: UIView {
            let l = UILabel()
            func setupViews() { l.textColor = Theme.Colors.accent; addSubview(l) }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let token = try XCTUnwrap(cell.hostTokens.first)
        XCTAssertTrue(token.id.hasPrefix("uict_"), token.id)
        // Re-lowering the same source yields the SAME id.
        let cell2 = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertEqual(token.id, cell2.hostTokens.first?.id)
    }

    /// DEMOTE-SAFE: a color expression that references a `private` member (the cross-file
    /// thunk closure can't see it) is NOT tokenized → the color stays unresolvable → the
    /// whole method demotes (never a wrong default color). The established `private` wall.
    func testColorTokenReferencingPrivateMemberDemotes() throws {
        let src = """
        import UIKit
        final class V: UIView {
            private var accent: UIColor = .red
            let l = UILabel()
            func setupViews() {
                l.textColor = self.accent.withAlphaComponent(0.5)
                addSubview(l)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a color token over a private member must demote (the private wall)")
    }

    /// DEMOTE-SAFE: a color expression referencing a body-LOCAL (`let c = ...; v.tint = c`)
    /// is NOT tokenized (the slot closure can't reach a method local) → demote.
    func testColorTokenReferencingBodyLocalDemotes() throws {
        let src = """
        import UIKit
        final class V: UIView {
            let iv = UIImageView()
            func setupViews() {
                let c = computeAccent()
                iv.tintColor = c
                addSubview(iv)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a color token over a body-local must demote")
    }

    /// NOT-A-COLOR-GUARD: a custom-VIEW background-color position (a bare-DeclReference
    /// constructor `SomeView()`) is NOT mis-recorded as a color token — it isn't a
    /// plausible color expression, so the color set demotes (it's nonsense as a color).
    func testNonColorExpressionNotTokenized() throws {
        let src = """
        import UIKit
        final class V: UIView {
            let l = UILabel()
            func setupViews() {
                l.textColor = makeColor()
                addSubview(l)
            }
        }
        """
        // `makeColor()` — a bare-DeclReference call (not a member-access call) — is not a
        // plausible color token, so it isn't recorded; the textColor set demotes.
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a bare-function-call color is not tokenized (could be anything)")
    }

    // MARK: - WASM round-trip: a root-configured VC with a namespace constant

    /// GOLD PROOF: a `UIView` subclass that configures its ROOT (Lever A) and pins a child
    /// with a NAMESPACE-CONSTANT constant (Lever B) compiles to WASM, host-runs, and the
    /// decoded tree carries the root background + the resolved constraint constant.
    func testRootConfigAndConstantExecuteInWasm() throws {
        let src = """
        import UIKit
        enum UX { static let inset: CGFloat = 16 }
        struct Row { let title: String }
        final class GoldRootCell: UITableViewCell {
            let titleLabel = UILabel()
            func configure(with model: Row) {
                contentView.backgroundColor = .systemBlue
                titleLabel.text = model.title
                contentView.addSubview(titleLabel)
                titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: UX.inset).isActive = true
            }
        }
        """
        let lowered = UIKitCellLowering().lowerAllCells(source: src)
        let cell = try XCTUnwrap(lowered.first)
        XCTAssertTrue(cell.thunkSafe)
        XCTAssertTrue(cell.guestBody.contains("constant: 16"), "UX.inset resolved: \(cell.guestBody)")
        XCTAssertTrue(cell.guestBody.contains(".background(.named(\"blue\"))"), cell.guestBody)

        let guestCells = lowered.map { UIKitGuestEmitter.GuestCell(from: $0) }
        let emission = try UIKitGuestEmitter().emit(cells: guestCells)
        XCTAssertTrue(emission.exports.contains("uikit_configure__GoldRootCell"))

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uikit-rootconst-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.uikit.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "root-config guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        let bytes = try runner.callPacked("uikit_configure__GoldRootCell",
            [UInt8](Data(#"{"title":"Hello"}"#.utf8)))
        let em = try JSONDecoder().decode(UIKitEmission.self, from: Data(bytes))
        // The styled root carries the background.
        XCTAssertEqual(em.root.props.backgroundColor, .named("blue"), "root background painted")
        // The title label is present and pinned with the resolved constant.
        let title = try XCTUnwrap(Self.findLabel(em.root, text: "Hello"))
        let leadingC = try XCTUnwrap(title.constraints.first { $0.first == .leading })
        XCTAssertEqual(leadingC.constant, 16, "namespace-constant constraint constant resolved")
    }

    /// GOLD PROOF (Lever D): a cell whose root + label use DESIGN-SYSTEM color tokens
    /// compiles to WASM, host-runs, and the decoded tree carries `.hostToken(id)` (NOT a
    /// wrong default) at each color position — the id the SDK resolves natively.
    func testColorTokenExecutesInWasm() throws {
        let src = """
        import UIKit
        struct Row { let title: String }
        final class TokenCell: UITableViewCell {
            let titleLabel = UILabel()
            func configure(with model: Row) {
                contentView.backgroundColor = SemanticColors.View.backgroundDefault
                titleLabel.text = model.title
                titleLabel.textColor = Palette.ink
                contentView.addSubview(titleLabel)
            }
        }
        """
        let lowered = UIKitCellLowering().lowerAllCells(source: src)
        let cell = try XCTUnwrap(lowered.first)
        let bgToken = try XCTUnwrap(cell.hostTokens.first { $0.source.contains("backgroundDefault") })
        let inkToken = try XCTUnwrap(cell.hostTokens.first { $0.source == "Palette.ink" })

        let guestCells = lowered.map { UIKitGuestEmitter.GuestCell(from: $0) }
        let emission = try UIKitGuestEmitter().emit(cells: guestCells)
        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uikit-token-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.uikit.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "token guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        let bytes = try runner.callPacked("uikit_configure__TokenCell",
            [UInt8](Data(#"{"title":"Hello"}"#.utf8)))
        let em = try JSONDecoder().decode(UIKitEmission.self, from: Data(bytes))
        // The root carries the bg token id (NOT a baked default color).
        XCTAssertEqual(em.root.props.backgroundColor, .hostToken(bgToken.id), "root bg is the token id")
        let title = try XCTUnwrap(Self.findLabel(em.root, text: "Hello"))
        if case .label(_, _, let tc, _, _) = title.kind {
            XCTAssertEqual(tc, .hostToken(inkToken.id), "label color is the ink token id")
        } else { XCTFail("title node is not a label") }
    }

    // MARK: - Lever D for NUMBERS: cross-file numeric design tokens

    /// A constraint `equalToConstant:` reading a CROSS-FILE numeric design constant
    /// (`TPMenuUX.UX.viewCornerRadius` — declared in another file, so NOT a same-file
    /// namespace constant and NOT a literal) now LOWERS via the NUMERIC host-token channel
    /// (Lever D for numbers): the guest reads a reserved `__numtok_<id>` `.double` input,
    /// and a `.number` host token is recorded with the real constant as its resolver
    /// source. The OLD behavior demoted on "non-literal equalToConstant".
    func testCrossFileNumericConstraintConstantLowers() throws {
        let src = """
        import UIKit
        struct Row { let title: String }
        final class IconCell: UITableViewCell {
            let icon = UIImageView()
            func configure(with model: Row) {
                contentView.addSubview(icon)
                icon.widthAnchor.constraint(equalToConstant: TPMenuUX.UX.iconSize).isActive = true
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        // The constant rides as the reserved input key, not a baked literal / leaked symbol.
        XCTAssertTrue(g.contains("size(.width, __numtok_"), "constant is a numeric token: \(g)")
        XCTAssertFalse(g.contains("TPMenuUX"), "no design-system symbol leaks into WASM: \(g)")
        let tok = try XCTUnwrap(cell.hostTokens.first { $0.kind == .number })
        XCTAssertEqual(tok.source, "TPMenuUX.UX.iconSize")
        XCTAssertTrue(tok.id.hasPrefix("uint_"), tok.id)
        // The synthetic `.double` input is registered so the guest scans it.
        XCTAssertTrue(cell.inputs.contains { $0.name == "__numtok_\(tok.id)" && $0.kind == .double },
                      "a __numtok_ .double input is registered: \(cell.inputs)")
        XCTAssertTrue(cell.thunkSafe, "a number-token cell is auto-routable")
    }

    /// A `layer.cornerRadius` / `spacing` reading a cross-file design constant lowers as a
    /// numeric token too (the property-position path, not just constraints).
    func testCrossFileNumericPropertyLowers() throws {
        let src = """
        import UIKit
        final class CardCell: UITableViewCell {
            let stack = UIStackView()
            func setup() {
                contentView.addSubview(stack)
                stack.spacing = Theme.Spacing.row
                contentView.layer.cornerRadius = Theme.Radius.card
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("spacing: __numtok_"), "stack spacing is a token: \(g)")
        XCTAssertTrue(g.contains(".cornerRadius(__numtok_"), "root corner radius is a token: \(g)")
        XCTAssertEqual(cell.hostTokens.filter { $0.kind == .number }.count, 2)
        XCTAssertTrue(cell.hostTokens.contains { $0.source == "Theme.Spacing.row" })
        XCTAssertTrue(cell.hostTokens.contains { $0.source == "Theme.Radius.card" })
        XCTAssertFalse(g.contains("Theme."), "no design-system symbol leaks: \(g)")
    }

    /// A numeric token id is content-stable (FNV over the source) — engine + thunk agree.
    func testNumericTokenIDIsStable() throws {
        let src = """
        import UIKit
        final class V: UIView {
            let l = UILabel()
            func setupViews() {
                addSubview(l)
                l.widthAnchor.constraint(equalToConstant: Layout.Sizes.thumb).isActive = true
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let tok = try XCTUnwrap(cell.hostTokens.first { $0.kind == .number })
        XCTAssertEqual(tok.source, "Layout.Sizes.thumb")
        let cell2 = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertEqual(tok.id, cell2.hostTokens.first { $0.kind == .number }?.id)
    }

    /// A SAME-FILE namespace constant (`UX.inset` — Lever B) still folds to a LITERAL (the
    /// established path); it is NOT host-tokenized (the guest can compute it as written).
    func testSameFileNamespaceConstantStaysLiteral() throws {
        let src = """
        import UIKit
        enum UX { static let inset: CGFloat = 12 }
        final class V: UIView {
            let l = UILabel()
            func setupViews() {
                addSubview(l)
                l.widthAnchor.constraint(equalToConstant: UX.inset).isActive = true
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.guestBody.contains("size(.width, 12"), "same-file constant folds to literal: \(cell.guestBody)")
        XCTAssertTrue(cell.hostTokens.filter { $0.kind == .number }.isEmpty,
                      "no numeric token recorded for a foldable same-file constant")
    }

    /// DEMOTE-SAFE: a constraint constant DERIVED from the `with:` MODEL
    /// (`model.height` — a marshalled field) is NOT host-tokenized (the thunk's `self` is
    /// the cell, not the row model — resolving it natively would be wrong). It stays on its
    /// own path; here a bare model field isn't a numeric-token shape, so the cell demotes
    /// rather than host-resolve a model value.
    func testModelDerivedNumericConstantNotTokenized() throws {
        let src = """
        import UIKit
        struct Row { let height: Double }
        final class V: UITableViewCell {
            let l = UILabel()
            func configure(with model: Row) {
                contentView.addSubview(l)
                l.heightAnchor.constraint(equalToConstant: model.height).isActive = true
            }
        }
        """
        let lowered = UIKitCellLowering().lowerAllCells(source: src)
        // No NUMERIC host token may be recorded over a marshalled model field.
        for cell in lowered {
            XCTAssertFalse(cell.hostTokens.contains { $0.kind == .number && $0.source.contains("model") },
                           "a model-derived numeric must NOT host-tokenize: \(cell.hostTokens)")
        }
    }

    /// DEMOTE-SAFE: a numeric constant referencing a body-LOCAL (`let r = compute(); … r`)
    /// is NOT tokenized (the cross-file thunk closure can't reach a method local) → the
    /// whole method demotes (never a wrong dimension).
    func testNumericConstantReferencingBodyLocalDemotes() throws {
        let src = """
        import UIKit
        final class V: UIView {
            let l = UILabel()
            func setupViews() {
                let r = computeRadius()
                addSubview(l)
                l.layer.cornerRadius = r
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a numeric token over a body-local must demote")
    }

    /// DEMOTE-SAFE: a numeric constant referencing a `private` member (`self.privateRadius`)
    /// is NOT tokenized (the cross-file `@_dynamicReplacement` thunk can't read it) → demote.
    func testNumericConstantReferencingPrivateMemberDemotes() throws {
        let src = """
        import UIKit
        final class V: UIView {
            private let privateRadius: CGFloat = 8
            let l = UILabel()
            func setupViews() {
                addSubview(l)
                l.layer.cornerRadius = self.privateRadius
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a numeric token over a private member must demote (the private wall)")
    }

    /// GOLD PROOF (Lever D for numbers): a cell whose constraint constant is a cross-file
    /// numeric token compiles to WASM, host-runs with the resolved value MERGED into the
    /// input JSON under `__numtok_<id>`, and the decoded tree carries the REAL constant.
    func testNumericTokenExecutesInWasm() throws {
        let src = """
        import UIKit
        struct Row { let title: String }
        final class NumTokenCell: UITableViewCell {
            let icon = UIImageView()
            func configure(with model: Row) {
                contentView.addSubview(icon)
                icon.widthAnchor.constraint(equalToConstant: TPMenuUX.UX.iconSize).isActive = true
            }
        }
        """
        let lowered = UIKitCellLowering().lowerAllCells(source: src)
        let cell = try XCTUnwrap(lowered.first)
        let tok = try XCTUnwrap(cell.hostTokens.first { $0.kind == .number })
        let key = "__numtok_\(tok.id)"

        let guestCells = lowered.map { UIKitGuestEmitter.GuestCell(from: $0) }
        let emission = try UIKitGuestEmitter().emit(cells: guestCells)
        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uikit-numtoken-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.uikit.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "numeric-token guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        // The SDK MERGES the resolved token value into the input JSON; emulate that here:
        // the constant is 44 (the resolved `TPMenuUX.UX.iconSize`).
        let inputJSON = #"{"title":"Hello","\#(key)":44}"#
        let bytes = try runner.callPacked("uikit_configure__NumTokenCell",
            [UInt8](Data(inputJSON.utf8)))
        let em = try JSONDecoder().decode(UIKitEmission.self, from: Data(bytes))
        let icon = try XCTUnwrap(Self.findFirstWidthConstrained(em.root))
        let widthC = try XCTUnwrap(icon.constraints.first { $0.first == .width })
        XCTAssertEqual(widthC.constant, 44, "the numeric token resolved to the merged value")
    }

    // MARK: - Tree search helpers

    static func findFirstWidthConstrained(_ node: UIKitNode) -> UIKitNode? {
        if node.constraints.contains(where: { $0.first == .width }) { return node }
        for c in node.childNodes { if let f = findFirstWidthConstrained(c) { return f } }
        return nil
    }

    static func findLabel(_ node: UIKitNode, text: String) -> UIKitNode? {
        if case .label(let t, _, _, _, _) = node.kind, t == text { return node }
        for c in node.childNodes { if let f = findLabel(c, text: text) { return f } }
        return nil
    }

    // MARK: - Minimal WasmKit host runner (mirrors UIKitConditionalLoweringTests.Runner)

    private final class Runner {
        let store: Store
        let instance: Instance
        let wasi: WASIBridgeToHost
        init(wasm: [UInt8]) throws {
            let engine = Engine()
            self.store = Store(engine: engine)
            self.wasi = try WASIBridgeToHost()
            var imports = Imports()
            wasi.link(to: &imports, store: store)
            PatchHostTestImports.register(into: &imports, store: store)
            let module = try parseWasm(bytes: wasm)
            self.instance = try module.instantiate(store: store, imports: imports)
            try wasi.initialize(instance)
        }
        func memory() throws -> Memory {
            guard let m = instance.exports[memory: "memory"] else { throw NSError(domain: "abi", code: 1) }
            return m
        }
        func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
            guard let fn = instance.exports[function: name],
                  let malloc = instance.exports[function: "patch_malloc"] else {
                throw NSError(domain: "abi", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing export \(name)"])
            }
            let ptr = try malloc([.i32(UInt32(input.count))])[0].i32
            let mem = try memory()
            mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: input.count) { raw in
                raw.copyBytes(from: input)
            }
            let packed = try fn([.i32(ptr), .i32(UInt32(input.count))])[0].i64
            let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
            let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
            let all = try memory().data
            return [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
        }
    }
}
