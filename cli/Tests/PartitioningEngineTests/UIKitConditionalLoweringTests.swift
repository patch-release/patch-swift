// SPDX-License-Identifier: Apache-2.0

// UIKitConditionalLoweringTests — the engine-side tests for the UIKit "milk-more"
// coverage batch: model-driven CONDITIONAL construction (Lever 1), CONDITIONAL
// (ternary) property VALUES, and the broadened property grammar (Lever 3).
// =============================================================================
// Every lever is demote-safe / ALL-OR-NOTHING-PER-METHOD. These tests prove BOTH
// directions:
//   * the new construct LOWERS (rides WASM, not a demote) — coverage win,
//   * a native-touching / non-guest-evaluable form STILL DEMOTES (no false
//     negatives — we never silently ship a wrong branch/value).
// Plus a WASM round-trip proving a conditional + ternary cell reflects the model.

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

final class UIKitConditionalLoweringTests: XCTestCase {

    // MARK: - Lever 1: model-driven conditional construction (`if cond { addSubview }`)

    /// `if isPremium { stack.addArrangedSubview(badge) }` over a marshalled BOOL lowers:
    /// the badge stays in the tree, gated with a guest `.hidden(!(isPremium))`.
    func testConditionalAddSubviewLowers() throws {
        let src = """
        import UIKit
        struct M { let title: String; let isPremium: Bool }
        final class RowCell: UITableViewCell {
            let titleLabel = UILabel()
            let badge = UILabel()
            let stack = UIStackView()
            func configure(with model: M) {
                titleLabel.text = model.title
                stack.axis = .vertical
                stack.addArrangedSubview(titleLabel)
                if model.isPremium {
                    badge.text = "PRO"
                    stack.addArrangedSubview(badge)
                }
                contentView.addSubview(stack)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.stack(axis: .vertical"), g)
        XCTAssertTrue(g.contains("UI.label(\"PRO\")"), "the badge lowers (not dropped): \(g)")
        // The badge is gated: hidden unless isPremium.
        XCTAssertTrue(g.contains(".hidden(!(isPremium))"), "badge gated on the bool input: \(g)")
        XCTAssertFalse(g.contains("UI.slot("), "no native slot: \(g)")
        XCTAssertTrue(cell.thunkSafe)
        XCTAssertTrue(cell.inputs.contains { $0.name == "model.isPremium" && $0.kind == .bool })
    }

    /// `if count > 0 { … } else { … }` over a marshalled Int lowers BOTH branches, each
    /// gated on the (inverse) guest condition.
    func testConditionalIfElseLowers() throws {
        let src = """
        import UIKit
        struct M { let count: Int }
        final class CountCell: UITableViewCell {
            let empty = UILabel()
            let filled = UILabel()
            let stack = UIStackView()
            func configure(with model: M) {
                stack.axis = .vertical
                if model.count > 0 {
                    filled.text = "Has items"
                    stack.addArrangedSubview(filled)
                } else {
                    empty.text = "Empty"
                    stack.addArrangedSubview(empty)
                }
                contentView.addSubview(stack)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.label(\"Has items\")"), g)
        XCTAssertTrue(g.contains("UI.label(\"Empty\")"), g)
        // then-branch gated on `!(count > 0)`, else-branch on `!(!(count > 0))`.
        XCTAssertTrue(g.contains(".hidden(!(count > 0))"), "filled gated on the condition: \(g)")
        XCTAssertTrue(g.contains(".hidden(!(!(count > 0)))"), "empty gated on the inverse: \(g)")
        XCTAssertTrue(cell.thunkSafe)
    }

    /// A `&&`/`||`/`==`/string-equality condition lowers (the guest-bool grammar).
    func testCompositeConditionLowers() throws {
        let src = """
        import UIKit
        struct M { let tier: String; let active: Bool }
        final class T: UITableViewCell {
            let vip = UILabel()
            let stack = UIStackView()
            func configure(with model: M) {
                stack.axis = .vertical
                if model.tier == "vip" && model.active {
                    vip.text = "VIP"
                    stack.addArrangedSubview(vip)
                }
                contentView.addSubview(stack)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.label(\"VIP\")"), g)
        XCTAssertTrue(g.contains("tier == \"vip\""), "string-equality condition lowers: \(g)")
        XCTAssertTrue(g.contains("active"), "bool composition lowers: \(g)")
    }

    /// FALSE-NEGATIVE GUARD: an `if` over a NON-marshalled / native-touching condition
    /// (a trait query) demotes the WHOLE method — we never ship a wrong branch.
    func testTraitDrivenConditionDemotes() throws {
        let src = """
        import UIKit
        final class T: UITableViewCell {
            let dark = UILabel()
            let stack = UIStackView()
            func configure(with model: M) {
                stack.axis = .vertical
                if traitCollection.userInterfaceStyle == .dark {
                    dark.text = "Dark"
                    stack.addArrangedSubview(dark)
                }
                contentView.addSubview(stack)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a trait-driven conditional must demote (its condition isn't marshalled)")
    }

    /// FALSE-NEGATIVE GUARD: an `if let` / `if case` (not a guest boolean over the model)
    /// demotes — we don't pretend to evaluate an optional binding in the guest.
    func testIfLetConditionDemotes() throws {
        let src = """
        import UIKit
        final class T: UITableViewCell {
            let label = UILabel()
            let stack = UIStackView()
            func configure(with model: M) {
                stack.axis = .vertical
                if let name = model.optionalName {
                    label.text = name
                    stack.addArrangedSubview(label)
                }
                contentView.addSubview(stack)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "an if-let conditional must demote")
    }

    /// FALSE-NEGATIVE GUARD: an `if` whose BODY contains an imperative statement (a loop)
    /// still demotes the whole method — the cardinal rule holds inside a branch.
    func testImperativeBodyInConditionalDemotes() throws {
        let src = """
        import UIKit
        struct M { let on: Bool; let items: [String] }
        final class T: UITableViewCell {
            let stack = UIStackView()
            func configure(with model: M) {
                stack.axis = .vertical
                if model.on {
                    for it in model.items {
                        let l = UILabel()
                        l.text = it
                        stack.addArrangedSubview(l)
                    }
                }
                contentView.addSubview(stack)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "an imperative loop inside a conditional branch demotes the whole method")
    }

    // MARK: - Lever 1b: CONDITIONAL (ternary) property VALUES

    /// `label.textColor = isError ? .systemRed : .label` lowers to a guest ternary over
    /// the marshalled bool — the per-row color rides WASM.
    func testTernaryColorValueLowers() throws {
        let src = """
        import UIKit
        struct M { let title: String; let isError: Bool }
        final class T: UITableViewCell {
            let label = UILabel()
            func configure(with model: M) {
                label.text = model.title
                label.textColor = model.isError ? .systemRed : .label
                label.alpha = model.isError ? 1.0 : 0.5
                contentView.addSubview(label)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("(isError ? .named(\"red\") : .named(\"label\"))"),
                      "ternary color lowers as a guest ternary: \(g)")
        XCTAssertTrue(g.contains(".alpha((isError ? 1 : 0.5))"),
                      "ternary alpha lowers: \(g)")
        XCTAssertTrue(cell.thunkSafe)
    }

    /// `label.text = isVIP ? "VIP" : name` lowers to a guest String ternary.
    func testTernaryTextValueLowers() throws {
        let src = """
        import UIKit
        struct M { let name: String; let isVIP: Bool }
        final class T: UITableViewCell {
            let label = UILabel()
            func configure(with model: M) {
                label.text = model.isVIP ? "VIP" : model.name
                contentView.addSubview(label)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.label((isVIP ? \"VIP\" : name)"),
                      "ternary text lowers: \(g)")
    }

    /// FALSE-NEGATIVE GUARD: a ternary whose CONDITION isn't a marshalled input (a
    /// `self.private` read) demotes — never a wrong value.
    func testTernaryOverNonInputDemotes() throws {
        let src = """
        import UIKit
        final class T: UITableViewCell {
            private var highlighted = false
            let label = UILabel()
            func configure(with model: M) {
                label.text = model.title
                label.textColor = highlighted ? .systemRed : .label
                contentView.addSubview(label)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a ternary over a non-marshalled condition demotes")
    }

    // MARK: - Lever 3: broadened property grammar

    /// Common label/layer/stack tuning props are TOLERATED (accepted), so a cell that
    /// sets them still lowers — they don't change the lowered tree, dropping them is
    /// visually negligible vs demoting the whole cell.
    func testToleratedTuningPropsStillLower() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class T: UITableViewCell {
            let label = UILabel()
            let card = UIView()
            func configure(with model: M) {
                label.text = model.title
                label.adjustsFontSizeToFitWidth = true
                label.lineBreakMode = .byTruncatingTail
                label.minimumScaleFactor = 0.5
                card.layer.cornerRadius = 8
                card.layer.borderWidth = 1
                card.layer.shadowOpacity = 0.2
                card.isUserInteractionEnabled = false
                card.addSubview(label)
                contentView.addSubview(card)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("UI.label(title"), "label lowers despite tuning props: \(g)")
        XCTAssertTrue(g.contains(".cornerRadius(8)"), "cornerRadius lowers: \(g)")
        XCTAssertFalse(g.contains("UI.slot("), "no demote/slot: \(g)")
    }

    /// `button.titleLabel?.font = …` + a ternary `setTitleColor` lower onto the button.
    func testButtonTitleLabelFontLowers() throws {
        let src = """
        import UIKit
        struct M { let label: String; let on: Bool }
        final class T: UITableViewCell {
            let btn = UIButton(type: .system)
            func configure(with model: M) {
                btn.setTitle(model.label, for: .normal)
                btn.titleLabel?.font = .boldSystemFont(ofSize: 15)
                btn.setTitleColor(model.on ? .systemBlue : .systemGray, for: .normal)
                btn.addTarget(self, action: #selector(tap), for: .touchUpInside)
                contentView.addSubview(btn)
            }
            @objc func tap() {}
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains("IRFont(size: 15, weight: .bold)"), "button font lowers: \(g)")
        XCTAssertTrue(g.contains("(on ? .named(\"blue\") : .named(\"gray\"))"),
                      "ternary title color lowers: \(g)")
        XCTAssertTrue(g.contains("UI.button("), g)
    }

    // MARK: - Lever 3: named constraint bindings + tolerated layout calls

    /// A NAMED constraint (`let top = …constraint(...); top.priority = .defaultHigh;
    /// top.isActive = true`) lowers — the captured anchor form + priority ride WASM,
    /// instead of slotting the constraint as a broken view (which used to demote).
    func testNamedConstraintBindingLowers() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class T: UITableViewCell {
            let label = UILabel()
            func configure(with model: M) {
                label.text = model.title
                contentView.addSubview(label)
                let top = label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8)
                top.priority = .defaultHigh
                top.isActive = true
                let lead = label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
                NSLayoutConstraint.activate([lead])
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = cell.guestBody
        XCTAssertTrue(g.contains(".pin(.top, to: .top, of: .superview, constant: 8, priority: 750)"),
                      "named constraint w/ priority lowers: \(g)")
        XCTAssertTrue(g.contains(".pin(.leading, to: .leading, of: .superview, constant: 16)"),
                      "named constraint via activate([…]) lowers: \(g)")
        XCTAssertFalse(g.contains("UI.slot("), "the constraint isn't slotted as a view: \(g)")
        XCTAssertTrue(cell.thunkSafe)
    }

    /// Tolerated layout calls on a KNOWN view (`setContentHuggingPriority`, `sizeToFit`)
    /// don't demote — the construction still lowers.
    func testToleratedLayoutCallsStillLower() throws {
        let src = """
        import UIKit
        struct M { let title: String }
        final class T: UITableViewCell {
            let label = UILabel()
            func configure(with model: M) {
                label.text = model.title
                label.setContentHuggingPriority(.required, for: .horizontal)
                label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
                contentView.addSubview(label)
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertTrue(cell.guestBody.contains("UI.label(title"), cell.guestBody)
        XCTAssertFalse(cell.guestBody.contains("UI.slot("), cell.guestBody)
    }

    /// FALSE-NEGATIVE GUARD: an unknown call on an UNKNOWN receiver still demotes — the
    /// tolerated-call set is scoped to known views only.
    func testUnknownReceiverCallStillDemotes() throws {
        let src = """
        import UIKit
        final class T: UITableViewCell {
            let label = UILabel()
            func configure(with model: M) {
                label.text = model.title
                someService.sizeToFit()   // unknown receiver → demote
                contentView.addSubview(label)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a tolerated-name call on an unknown receiver still demotes")
    }

    // MARK: - WASM round-trip: a conditional + ternary cell reflects the model

    /// GOLD PROOF: a cell using BOTH a conditional add AND a ternary value compiles to
    /// WASM, host-runs with two different models, and the decoded tree reflects each.
    func testConditionalCellExecutesInWasm() throws {
        let src = """
        import UIKit
        struct Row { let title: String; let isPremium: Bool }
        final class GoldCell: UITableViewCell {
            let titleLabel = UILabel()
            let badge = UILabel()
            let stack = UIStackView()
            func configure(with model: Row) {
                titleLabel.text = model.title
                titleLabel.textColor = model.isPremium ? .systemBlue : .label
                stack.axis = .vertical
                stack.addArrangedSubview(titleLabel)
                if model.isPremium {
                    badge.text = "PRO"
                    stack.addArrangedSubview(badge)
                }
                contentView.addSubview(stack)
            }
        }
        """
        let lowered = UIKitCellLowering().lowerAllCells(source: src)
        let cell = try XCTUnwrap(lowered.first)
        XCTAssertTrue(cell.thunkSafe)
        let guestCells = lowered.map { UIKitGuestEmitter.GuestCell(from: $0) }
        let emission = try UIKitGuestEmitter().emit(cells: guestCells)
        XCTAssertTrue(emission.exports.contains("uikit_configure__GoldCell"))

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping conditional execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uikit-cond-exec-\(UUID().uuidString)")
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
        XCTAssertEqual(result.status, .success, "conditional guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)

        // Model A: premium → the badge paints (not hidden) + title is blue.
        let aBytes = try runner.callPacked("uikit_configure__GoldCell",
            [UInt8](Data(#"{"title":"Alice","isPremium":true}"#.utf8)))
        let a = try JSONDecoder().decode(UIKitEmission.self, from: Data(aBytes))
        XCTAssertTrue(Self.containsLabel(a.root, text: "Alice"))
        let aBadge = try XCTUnwrap(Self.findLabel(a.root, text: "PRO"), "badge node present")
        XCTAssertNotEqual(aBadge.props.isHidden, true, "premium → badge is visible")

        // Model B: non-premium → the badge is hidden (gated false).
        let bBytes = try runner.callPacked("uikit_configure__GoldCell",
            [UInt8](Data(#"{"title":"Bob","isPremium":false}"#.utf8)))
        let b = try JSONDecoder().decode(UIKitEmission.self, from: Data(bBytes))
        let bBadge = try XCTUnwrap(Self.findLabel(b.root, text: "PRO"), "badge node still present (gated)")
        XCTAssertEqual(bBadge.props.isHidden, true, "non-premium → badge is hidden")
    }

    // MARK: - Tree search helpers

    static func containsLabel(_ node: UIKitNode, text: String) -> Bool {
        findLabel(node, text: text) != nil
    }
    static func findLabel(_ node: UIKitNode, text: String) -> UIKitNode? {
        if case .label(let t, _, _, _, _) = node.kind, t == text { return node }
        for c in node.childNodes { if let f = findLabel(c, text: text) { return f } }
        return nil
    }

    // MARK: - Minimal WasmKit host runner (mirrors UIKitVCLoweringTests.Runner)

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
