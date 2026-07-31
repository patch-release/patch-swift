// SPDX-License-Identifier: Apache-2.0

// UIKitVCLoweringTests — the engine-side tests for Goal 2: extending the UIKit
// view-IR from cell `configure(with:)` to a PROGRAMMATIC view-controller's
// declarative construction (`setupViews()`/`viewDidLoad`).
// =============================================================================
// Mirrors `UIKitCellLoweringTests` but for a VC container:
//   1. a declarative `UIViewController.setupViews()` (or `viewDidLoad`) lowers to a
//      `UI.*`-building guest body rooted at the VC's `view`, with NO demote,
//   2. a VC roots its content at `view`/`self.view` (cell roots at `contentView`),
//   3. an un-lowerable subview → a `UI.slot` (native, never dropped),
//   4. an imperative/unknown statement demotes the WHOLE method (cardinal rule),
//   5. the generated thunk installs into `self.view` with `model: self` and (for a
//      `viewDidLoad` build) repeats `override`,
//   6. the guest emitter wraps it identically to a cell (same UIKitNode IR + export).

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

final class UIKitVCLoweringTests: XCTestCase {

    // A representative programmatic VC: a vertical stack with a title + a subtitle
    // label, built in `setupViews()` and pinned into the VC's root `view`. Exactly the
    // addSubview / property-config / NSLayoutConstraint.activate grammar — at `view`.
    private let profileVCSource = """
    import UIKit

    final class ProfileViewController: UIViewController {
        let titleLabel = UILabel()
        let subtitleLabel = UILabel()
        let stack = UIStackView()
        var headline = "Welcome"
        var caption = "Tap to begin"

        override func viewDidLoad() {
            super.viewDidLoad()
            setupViews()
        }

        func setupViews() {
            titleLabel.text = headline
            titleLabel.font = .boldSystemFont(ofSize: 22)
            titleLabel.textColor = .label

            subtitleLabel.text = caption
            subtitleLabel.font = .systemFont(ofSize: 15)
            subtitleLabel.textColor = .secondaryLabel
            subtitleLabel.numberOfLines = 0

            stack.axis = .vertical
            stack.spacing = 8
            stack.alignment = .leading
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(subtitleLabel)

            view.addSubview(stack)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24)
            ])
        }
    }
    """

    // MARK: - 1. A programmatic VC lowers (setupViews rooted at `view`)

    func testDeclarativeVCLowers() throws {
        let lowered = UIKitCellLowering().lowerAllCells(source: profileVCSource)
        XCTAssertEqual(lowered.count, 1, "should find exactly one VC")
        let vc = try XCTUnwrap(lowered.first)
        XCTAssertEqual(vc.typeName, "ProfileViewController")
        XCTAssertEqual(vc.containerKind, .viewController, "recognized as a VC, not a cell")
        // The preferred construction method is the dedicated `setupViews()` helper.
        XCTAssertEqual(vc.methodName, "setupViews", "prefers the setupViews helper over viewDidLoad")

        let g = vc.guestBody
        // The stack lowers as the content root (the single subview added to `view`).
        XCTAssertTrue(g.contains("UI.stack(axis: .vertical"), "the stack lowers: \(g)")
        XCTAssertTrue(g.contains("UI.label(headline"), "title reads the marshalled stored prop `headline`: \(g)")
        XCTAssertTrue(g.contains("UI.label(caption"), "subtitle reads the stored prop `caption`: \(g)")
        XCTAssertTrue(g.contains("IRFont(size: 22, weight: .bold)"), "boldSystemFont lowers: \(g)")
        XCTAssertTrue(g.contains(".named(\"label\")"), ".label color lowers: \(g)")
        // Constraints: the stack pinned to the VC's `view` → `superview`.
        XCTAssertTrue(g.contains(".pin(.leading, to: .leading, of: .superview, constant: 16)"),
                      "stack→view leading pin lowers (view → superview): \(g)")
        XCTAssertTrue(g.contains(".pin(.top, to: .top, of: .superview, constant: 24)"),
                      "stack→view top pin lowers: \(g)")
        // No slot — the whole construction rides WASM.
        XCTAssertFalse(g.contains("UI.slot("), "fully declarative VC has no native slot: \(g)")
        XCTAssertTrue(vc.customSlots.isEmpty, "no custom slots")
        XCTAssertTrue(vc.thunkSafe, "a fully-lowered VC is thunkSafe")
        XCTAssertFalse(vc.referencesUnmarshalledInput, "the stored props are flat scalars")

        // The marshalled inputs are the VC's flat stored props (the view props skipped).
        XCTAssertTrue(vc.inputs.contains { $0.name == "headline" && $0.kind == .string },
                      "headline is a marshalled String input: \(vc.inputs)")
        XCTAssertTrue(vc.inputs.contains { $0.name == "caption" && $0.kind == .string })
        XCTAssertFalse(vc.inputs.contains { $0.name == "stack" }, "view-typed props are not inputs")
    }

    /// A VC whose build lives DIRECTLY in `viewDidLoad` (no `setupViews` helper) lowers
    /// too — the leading `super.viewDidLoad()` is tolerated, and the content roots at
    /// `view`.
    func testViewDidLoadConstructionLowers() throws {
        let src = """
        import UIKit
        final class BannerViewController: UIViewController {
            let banner = UILabel()
            var message = "Hi"
            override func viewDidLoad() {
                super.viewDidLoad()
                banner.text = message
                banner.font = .systemFont(ofSize: 17)
                view.addSubview(banner)
                NSLayoutConstraint.activate([
                    banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                    banner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
                ])
            }
        }
        """
        let vc = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertEqual(vc.containerKind, .viewController)
        XCTAssertEqual(vc.methodName, "viewDidLoad", "the build lives in viewDidLoad")
        let g = vc.guestBody
        XCTAssertTrue(g.contains("UI.label(message"), "banner reads stored prop `message`: \(g)")
        XCTAssertTrue(g.contains(".pin(.centerX, to: .centerX, of: .superview)"),
                      "centerX→view pin lowers: \(g)")
        XCTAssertTrue(vc.thunkSafe)
    }

    /// A `UIView` subclass that builds INTO ITSELF (`addSubview(child)`, no receiver) in
    /// `setupViews()` lowers — the bare `addSubview` roots at `self`.
    func testUIViewSubclassBuildingIntoSelfLowers() throws {
        let src = """
        import UIKit
        final class CardView: UIView {
            let label = UILabel()
            var caption = "x"
            func setupViews() {
                label.text = caption
                addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: topAnchor, constant: 8)
                ])
            }
        }
        """
        let vc = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        XCTAssertEqual(vc.containerKind, .viewController)
        let g = vc.guestBody
        XCTAssertTrue(g.contains("UI.label(caption"), "label reads the stored prop: \(g)")
        XCTAssertTrue(vc.thunkSafe)
    }

    // MARK: - 2. The cardinal demote rule still holds for VCs

    /// A VC `setupViews()` with an imperative loop building rows demotes (stays native).
    func testImperativeLoopVCDemotes() throws {
        let src = """
        import UIKit
        final class GridViewController: UIViewController {
            let stack = UIStackView()
            var items: [String] = []
            func setupViews() {
                view.addSubview(stack)
                for item in items {
                    let label = UILabel()
                    label.text = item
                    stack.addArrangedSubview(label)
                }
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "an imperative-loop VC construction must demote (stay native)")
    }

    /// A VC `setupViews()` that wires a delegate is no longer all-or-nothing (Goal 1 —
    /// GRANULAR PER-STATEMENT PARTITIONING, §B.5): the declarative construction LOWERS and
    /// the `tableView.dataSource = self` delegate-wiring is QUARANTINED as a native effect
    /// the thunk replays verbatim against `self`. (`tableView` renders as a slotted custom
    /// leaf = the real `self.tableView`, so configuring `self.tableView.dataSource` targets
    /// exactly the shown view.) The win over the old whole-method demote: the layout/styling
    /// becomes OTA-patchable instead of staying 100% native.
    func testDelegateWiringVCQuarantines() throws {
        let src = """
        import UIKit
        final class ListViewController: UIViewController {
            let tableView = UITableView()
            func setupViews() {
                view.addSubview(tableView)
                tableView.dataSource = self
            }
        }
        """
        let lowered = UIKitCellLowering().lowerAllCells(source: src)
        let vc = try XCTUnwrap(lowered.first, "the method lowers (the delegate set quarantines)")
        XCTAssertEqual(vc.nativeEffects.map(\.source), ["tableView.dataSource = self"],
                       "the delegate wiring is a native effect, not a demote: \(vc.nativeEffects)")
    }

    /// A `UITableViewController` is NOT a VC-wedge target — its root view IS the table,
    /// so there's no `view.addSubview` declarative tree to lower.
    func testTableViewControllerNotATarget() throws {
        let src = """
        import UIKit
        final class FeedViewController: UITableViewController {
            func setupViews() {
                let header = UILabel()
                header.text = "Feed"
                view.addSubview(header)
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: src).isEmpty,
                      "a UITableViewController is excluded from the VC view-IR wedge")
    }

    // MARK: - 3. An un-lowerable subview → a slot (native, never dropped)

    func testCustomSubviewInVCBecomesSlot() throws {
        let src = """
        import UIKit
        final class DashboardViewController: UIViewController {
            let titleLabel = UILabel()
            let chart = SparklineView()
            let stack = UIStackView()
            var title = "Stats"
            func setupViews() {
                titleLabel.text = title
                stack.axis = .vertical
                stack.addArrangedSubview(titleLabel)
                stack.addArrangedSubview(chart)
                view.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: view.topAnchor),
                    stack.leadingAnchor.constraint(equalTo: view.leadingAnchor)
                ])
            }
        }
        """
        let vc = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let g = vc.guestBody
        XCTAssertTrue(g.contains("UI.stack(axis: .vertical"), "the stack lowers: \(g)")
        XCTAssertTrue(g.contains("UI.slot(id: \"uislot_"), "the custom chart becomes a slot: \(g)")
        XCTAssertEqual(vc.customSlots.count, 1, "exactly one custom slot")
        let slot = try XCTUnwrap(vc.customSlots.first)
        XCTAssertEqual(slot.source, "self.chart", "the slot renders the VC's live chart property")
        XCTAssertTrue(slot.slotable, "a self member is slotable")
        XCTAssertTrue(vc.thunkSafe, "a slotable custom leaf keeps the VC thunkSafe")
    }

    // MARK: - 4. The generated thunk targets `self.view` + `model: self`

    func testVCThunkInstallsIntoViewWithSelfModel() throws {
        let vc = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: profileVCSource).first)
        let thunk = UIKitThunkGenerator.renderCellThunk(vc)
        XCTAssertTrue(thunk.contains("extension ProfileViewController {"), thunk)
        XCTAssertTrue(thunk.contains("@_dynamicReplacement(for: setupViews)"),
                      "replaces the setupViews hook: \(thunk)")
        XCTAssertTrue(thunk.contains("contentView: self.view"),
                      "a VC installs the patched tree into its root `view`: \(thunk)")
        XCTAssertTrue(thunk.contains("model: self"),
                      "a VC's model is `self` (its stored props): \(thunk)")
        // A non-viewDidLoad helper replacement is NOT an override.
        XCTAssertFalse(thunk.contains("override func __patch_setupViews"),
                       "a setupViews replacement isn't an override: \(thunk)")
    }

    /// A `viewDidLoad`-built VC's replacement is NOT `override` (BUG #2 regression). The
    /// replacement `__patch_viewDidLoad` is a separate method declared in an extension —
    /// Swift forbids `override` in an extension AND the fresh-named method overrides
    /// nothing, so `override func __patch_viewDidLoad()` is a hard compile error that
    /// would break the whole app build. The `@_dynamicReplacement(for: viewDidLoad)`
    /// attribute (not `override`) routes the original to it at runtime.
    func testViewDidLoadThunkIsNotOverride() throws {
        let src = """
        import UIKit
        final class SoloViewController: UIViewController {
            let label = UILabel()
            var msg = "x"
            override func viewDidLoad() {
                super.viewDidLoad()
                label.text = msg
                view.addSubview(label)
            }
        }
        """
        let vc = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: src).first)
        let thunk = UIKitThunkGenerator.renderCellThunk(vc)
        XCTAssertTrue(thunk.contains("func __patch_viewDidLoad()"),
                      "a viewDidLoad replacement exists: \(thunk)")
        XCTAssertFalse(thunk.contains("override func __patch_viewDidLoad()"),
                       "a viewDidLoad replacement is NOT override (won't compile): \(thunk)")
        XCTAssertFalse(thunk.contains("override "),
                       "the thunk emits no `override` at all: \(thunk)")
        XCTAssertTrue(thunk.contains("@_dynamicReplacement(for: viewDidLoad)"), thunk)
    }

    /// `prepare` inserts `dynamic` on the VC's construction method + emits the thunk.
    func testPrepareWiresVC() throws {
        let file = UIKitThunkGenerator.SourceFile(
            url: URL(fileURLWithPath: "/tmp/ProfileViewController.swift"), text: profileVCSource)
        let result = UIKitThunkGenerator().prepare(sources: [file])
        XCTAssertTrue(result.cellNames.contains("ProfileViewController"),
                      "the VC is wired: \(result.cellNames)")
        XCTAssertEqual(result.dynamicInsertions, 1, "one dynamic inserted on setupViews")
        let modified = try XCTUnwrap(result.modifiedFiles.first?.text)
        XCTAssertTrue(modified.contains("dynamic func setupViews()"),
                      "setupViews is made dynamic: \(modified)")
        XCTAssertTrue(result.thunkFileContents.contains("contentView: self.view"))
    }

    // MARK: - 5. END-TO-END: lower → compile → host-run a VC construction in WASM

    /// THE GOLD PROOF (Goal 2): a programmatic VC's `setupViews()` lowers, COMPILES to
    /// WASM through the SAME guest emitter the cell wedge uses, host-runs with a
    /// marshalled model, and the decoded `UIKitNode` tree reflects the model — proving
    /// the VC view-IR rides WASM end-to-end (not just a host-side string check). Skips
    /// without the swift.org WASM toolchain.
    func testVCConstructionExecutesInWasm() throws {
        let lowered = UIKitCellLowering().lowerAllCells(source: profileVCSource)
        let vc = try XCTUnwrap(lowered.first)
        XCTAssertEqual(vc.containerKind, .viewController)
        let guestCells = lowered.map { UIKitGuestEmitter.GuestCell(from: $0) }
        let emission = try UIKitGuestEmitter().emit(cells: guestCells)
        // The VC ships the SAME export shape as a cell.
        XCTAssertTrue(emission.exports.contains("uikit_configure__ProfileViewController"))

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping VC construction execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uikit-vc-exec-\(UUID().uuidString)")
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
        XCTAssertEqual(result.status, .success, "VC guest WASM compile failed:\n\(result.log)")

        // Host-run the VC's construction export with a marshalled `self`-model JSON
        // (the VC's stored props — exactly what the SDK's `PatchUIKitModelMarshal`
        // produces from `self`).
        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        let inputs = Data(#"{"headline":"Welcome back","caption":"Pick up where you left off"}"#.utf8)
        let outBytes = try runner.callPacked("uikit_configure__ProfileViewController", [UInt8](inputs))
        XCTAssertFalse(outBytes.isEmpty, "the VC construction returned no bytes")

        let body = try JSONDecoder().decode(UIKitEmission.self, from: Data(outBytes))
        // The marshalled stored props ride WASM into the label nodes.
        XCTAssertTrue(Self.containsLabel(body.root, text: "Welcome back"),
                      "the title label carries the marshalled `headline`")
        XCTAssertTrue(Self.containsLabel(body.root, text: "Pick up where you left off"),
                      "the subtitle label carries the marshalled `caption`")
        // Zero native fallback — the whole VC construction rode WASM.
        XCTAssertEqual(body.root.slotNodeCount, 0, "no node fell back to a native slot")
        // The constraints (the stack pinned to `view` → superview) rode through.
        XCTAssertGreaterThanOrEqual(body.root.constraintCount, 3,
                                    "the lowered constraints are in the tree")
    }

    // MARK: - Goal 1: a PARTIALLY-LOWERED method rides WASM (declarative lowers + the
    // native effect is set aside, in source order)

    /// A VC whose `setupViews()` mixes the recognized declarative grammar with ONE
    /// quarantinable imperative statement (`navigationItem.largeTitleDisplayMode = .always`,
    /// a self/global effect). Goal 1: the declarative construction still LOWERS to a guest
    /// `UIKitNode` tree that rides WASM correctly, and the imperative line is set aside as a
    /// `nativeEffect` (the thunk replays it natively) — NOT a whole-method demote, and NOT
    /// in the WASM tree (so it can't corrupt the render). Proves the partition is real
    /// end-to-end: the guest tree reflects the model, the native effect rides the thunk.
    func testPartiallyLoweredMethodRidesWasm() throws {
        let src = """
        import UIKit
        final class GranularVC: UIViewController {
            let titleLabel = UILabel()
            let subtitleLabel = UILabel()
            let stack = UIStackView()
            var headline = "Welcome"
            var caption = "Details"
            func setupViews() {
                titleLabel.text = headline
                titleLabel.font = .boldSystemFont(ofSize: 22)
                subtitleLabel.text = caption
                stack.axis = .vertical
                stack.spacing = 8
                stack.addArrangedSubview(titleLabel)
                stack.addArrangedSubview(subtitleLabel)
                view.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12)
                ])
                navigationItem.largeTitleDisplayMode = .always
            }
        }
        """
        let lowered = UIKitCellLowering().lowerAllCells(source: src)
        let vc = try XCTUnwrap(lowered.first, "the method lowers (granular partition, not a demote)")
        // The one imperative line was quarantined as a native effect, NOT in the guest tree.
        XCTAssertEqual(vc.nativeEffects.map(\.source), ["navigationItem.largeTitleDisplayMode = .always"],
                       "the imperative line is a native effect: \(vc.nativeEffects)")
        XCTAssertFalse(vc.guestBody.contains("largeTitleDisplayMode"),
                       "the native effect is NOT in the guest tree (can't corrupt the render): \(vc.guestBody)")

        let emission = try UIKitGuestEmitter().emit(cells: lowered.map { UIKitGuestEmitter.GuestCell(from: $0) })
        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping partial-lowering execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uikit-granular-exec-\(UUID().uuidString)")
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
        XCTAssertEqual(result.status, .success, "partial-lowering guest WASM compile failed:\n\(result.log)")

        let runner = try Runner(wasm: [UInt8](try Data(contentsOf: out)))
        let inputs = Data(#"{"headline":"Granular wins","caption":"the 9 lower, the 1 slots"}"#.utf8)
        let outBytes = try runner.callPacked("uikit_configure__GranularVC", [UInt8](inputs))
        let body = try JSONDecoder().decode(UIKitEmission.self, from: Data(outBytes))
        // The DECLARATIVE construction rode WASM correctly: the marshalled model is in the
        // rendered tree, the constraint rode through, and NOTHING fell back to a native slot
        // (the native effect lives on the thunk, not the tree).
        XCTAssertTrue(Self.containsLabel(body.root, text: "Granular wins"),
                      "the declarative title rode WASM")
        XCTAssertTrue(Self.containsLabel(body.root, text: "the 9 lower, the 1 slots"),
                      "the declarative subtitle rode WASM")
        XCTAssertEqual(body.root.slotNodeCount, 0, "no node fell back to a slot (the effect rides the thunk)")
        XCTAssertGreaterThanOrEqual(body.root.constraintCount, 1, "the lowered constraint rode through")
    }

    // MARK: - Tree search helpers

    static func containsLabel(_ node: UIKitNode, text: String) -> Bool {
        if case .label(let t, _, _, _, _) = node.kind, t == text { return true }
        return node.childNodes.contains { containsLabel($0, text: text) }
    }

    // MARK: - Minimal WasmKit host runner (mirrors UIKitCellLoweringTests.Runner)

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
