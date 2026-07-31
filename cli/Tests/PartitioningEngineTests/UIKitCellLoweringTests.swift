// SPDX-License-Identifier: Apache-2.0

// UIKitCellLoweringTests — the engine-side tests for the UIKit cell-wedge lowering.
// =============================================================================
// Mirrors `SwiftUILoweringTests` for the UIKit pipeline:
//   1. a declarative `UITableViewCell.configure(with:)` lowers to a `UI.*`-building
//      guest body with the right nodes/constraints + NO demote,
//   2. a non-declarative cell (imperative loop / unknown call) DEMOTES (no patch),
//   3. an un-lowerable subview (a custom UIView subclass) → a `UI.slot`,
//   4. the guest emitter wraps it into a module with the `uikit_configure__<Type>`
//      export + the `patch_uikit_manifest` + the embedded UIKit IR,
//   5. THE GOLD PROOF — when the WASM toolchain is present: the guest COMPILES,
//      host-runs `uikit_configure__<Type>` with a marshalled model, and the decoded
//      `UIKitEmission` tree reflects the model (a label node text == the model title).

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

final class UIKitCellLoweringTests: XCTestCase {

    // A representative declarative cell: a vertical stack with an avatar + a title +
    // a subtitle, configured from a flat `Model`, pinned into contentView. This is
    // exactly the addSubview / property-config / NSLayoutConstraint.activate grammar.
    private let profileCellSource = """
    import UIKit

    struct CellModel {
        let title: String
        let subtitle: String
    }

    final class ProfileCell: UITableViewCell {
        let avatar = UIImageView()
        let titleLabel = UILabel()
        let subtitleLabel = UILabel()
        let stack = UIStackView()

        func configure(with model: CellModel) {
            avatar.image = UIImage(systemName: "person.crop.circle")
            avatar.tintColor = .systemBlue
            avatar.translatesAutoresizingMaskIntoConstraints = false

            titleLabel.text = model.title
            titleLabel.font = .boldSystemFont(ofSize: 17)
            titleLabel.textColor = .label

            subtitleLabel.text = model.subtitle
            subtitleLabel.font = .systemFont(ofSize: 13)
            subtitleLabel.textColor = .secondaryLabel
            subtitleLabel.numberOfLines = 0

            stack.axis = .vertical
            stack.spacing = 4
            stack.alignment = .leading
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(subtitleLabel)

            contentView.addSubview(avatar)
            contentView.addSubview(stack)

            NSLayoutConstraint.activate([
                avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                avatar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                avatar.widthAnchor.constraint(equalToConstant: 40),
                avatar.heightAnchor.constraint(equalToConstant: 40),
                stack.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
            ])
        }
    }
    """

    // MARK: - 1. Host-side lowering (always runs, no toolchain)

    func testDeclarativeCellLowers() throws {
        let lowering = UIKitCellLowering()
        let cells = lowering.lowerAllCells(source: profileCellSource)
        XCTAssertEqual(cells.count, 1, "should find exactly one cell")
        let cell = try XCTUnwrap(cells.first)
        XCTAssertEqual(cell.typeName, "ProfileCell")
        XCTAssertEqual(cell.methodName, "configure(with:)")

        let g = cell.guestBody
        // The content root is a container of [avatar, stack].
        XCTAssertTrue(g.contains("UI.container("), "content root is a container: \(g)")
        XCTAssertTrue(g.contains("UI.image(systemName: \"person.crop.circle\""), "avatar image lowers: \(g)")
        XCTAssertTrue(g.contains("UI.stack(axis: .vertical"), "the stack lowers: \(g)")
        // The title reads the marshalled model field (flattened to `title`).
        XCTAssertTrue(g.contains("UI.label(title"), "title reads the marshalled model.title: \(g)")
        XCTAssertTrue(g.contains("UI.label(subtitle"), "subtitle reads model.subtitle: \(g)")
        // Fonts + colors lower.
        XCTAssertTrue(g.contains("IRFont(size: 17, weight: .bold)"), "boldSystemFont lowers: \(g)")
        XCTAssertTrue(g.contains(".named(\"label\")"), ".label color lowers: \(g)")
        XCTAssertTrue(g.contains(".named(\"blue\")"), ".systemBlue → blue: \(g)")
        // Constraints lower: a constant size + a sibling pin + a superview pin.
        XCTAssertTrue(g.contains(".size(.width, 40)"), "constant width lowers: \(g)")
        XCTAssertTrue(g.contains(".pin(.leading, to: .trailing, of: .sibling(id: \"avatar\")"),
                      "stack→avatar sibling pin lowers: \(g)")
        XCTAssertTrue(g.contains(".pin(.leading, to: .leading, of: .superview, constant: 16)"),
                      "avatar→contentView leading pin lowers (contentView → superview): \(g)")
        // No slot — the whole construction rides WASM.
        XCTAssertFalse(g.contains("UI.slot("), "fully declarative cell has no native slot: \(g)")
        XCTAssertTrue(cell.customSlots.isEmpty, "no custom slots")
        XCTAssertTrue(cell.thunkSafe, "a fully-lowered cell is thunkSafe")
        XCTAssertFalse(cell.referencesUnmarshalledInput, "the model fields are all flat scalars")

        // The marshalled inputs are the model's flat fields.
        XCTAssertTrue(cell.inputs.contains { $0.name == "model.title" && $0.kind == .string })
        XCTAssertTrue(cell.inputs.contains { $0.name == "model.subtitle" && $0.kind == .string })
    }

    // MARK: - 2. A non-declarative cell DEMOTES (no patch)

    func testImperativeLoopCellDemotes() throws {
        let source = """
        import UIKit
        final class GridCell: UICollectionViewCell {
            let stack = UIStackView()
            func configure(with model: GridModel) {
                contentView.addSubview(stack)
                // An imperative loop building rows is NOT the recognized flat grammar.
                for item in model.items {
                    let label = UILabel()
                    label.text = item
                    stack.addArrangedSubview(label)
                }
            }
        }
        """
        let cells = UIKitCellLowering().lowerAllCells(source: source)
        XCTAssertTrue(cells.isEmpty, "an imperative-loop construction must demote (stay native)")
    }

    /// A construction that calls into an unknown helper (not the flat grammar) demotes.
    func testUnknownCallCellDemotes() throws {
        let source = """
        import UIKit
        final class FancyCell: UITableViewCell {
            let label = UILabel()
            func configure(with model: M) {
                contentView.addSubview(label)
                applyTheme(to: label)   // an unknown arg-taking call → demote
                label.text = model.title
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: source).isEmpty,
                      "an unknown call in the construction demotes the whole cell")
    }

    /// A class that ISN'T a cell (not a reusable-cell subclass) is ignored.
    func testNonCellClassIgnored() throws {
        let source = """
        import UIKit
        final class PlainView: UIView {
            let label = UILabel()
            func configure(with model: M) {
                addSubview(label)
                label.text = model.title
            }
        }
        """
        XCTAssertTrue(UIKitCellLowering().lowerAllCells(source: source).isEmpty,
                      "a non-cell UIView subclass isn't a cell-wedge target")
    }

    // MARK: - 3. An un-lowerable subview → a customSlot (native, never dropped)

    func testCustomSubviewBecomesSlot() throws {
        let source = """
        import UIKit
        struct ChartModel { let title: String }
        final class ChartCell: UITableViewCell {
            let titleLabel = UILabel()
            let chart = SparklineView()
            let stack = UIStackView()
            func configure(with model: ChartModel) {
                titleLabel.text = model.title
                stack.axis = .vertical
                stack.addArrangedSubview(titleLabel)
                stack.addArrangedSubview(chart)
                contentView.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: contentView.topAnchor),
                    stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
                ])
            }
        }
        """
        let cell = try XCTUnwrap(UIKitCellLowering().lowerAllCells(source: source).first)
        let g = cell.guestBody
        // The stack + label lower; the custom SparklineView becomes a slot (not dropped).
        XCTAssertTrue(g.contains("UI.stack(axis: .vertical"), "the stack lowers: \(g)")
        XCTAssertTrue(g.contains("UI.label(title"), "the title lowers: \(g)")
        XCTAssertTrue(g.contains("UI.slot(id: \"uislot_"), "the custom chart becomes a native slot: \(g)")
        XCTAssertEqual(cell.customSlots.count, 1, "exactly one custom slot")
        let slot = try XCTUnwrap(cell.customSlots.first)
        // A stored custom view slots as `self.<name>` — the thunk renders the cell's
        // LIVE property (it already created the view), not a fresh instance.
        XCTAssertEqual(slot.source, "self.chart", "the slot renders the cell's live chart property")
        XCTAssertTrue(slot.slotable, "a self member is slotable")
        // A cell with a slotable slot is still thunkSafe (the thunk renders the leaf).
        XCTAssertTrue(cell.thunkSafe, "a slotable custom leaf keeps the cell thunkSafe")
    }

    // MARK: - 4. Guest module emission

    func testGuestEmitterProducesConfigureExport() throws {
        let lowering = UIKitCellLowering()
        let cells = lowering.lowerAllCells(source: profileCellSource)
        let guestCells = cells.map { UIKitGuestEmitter.GuestCell(from: $0) }
        let emission = try UIKitGuestEmitter().emit(cells: guestCells)

        // Exports: the per-cell `uikit_configure__ProfileCell`, the canonical
        // `uikit_configure`, the manifest, plus the allocator.
        XCTAssertTrue(emission.exports.contains("patch_malloc"))
        XCTAssertTrue(emission.exports.contains("uikit_configure"))
        XCTAssertTrue(emission.exports.contains("uikit_configure__ProfileCell"))
        XCTAssertTrue(emission.exports.contains("patch_uikit_manifest"))

        // Files: the embeddable UIKit IR sources + the SwiftUI IR (shared types) + the
        // wrapper.
        let names = Set(emission.files.map { $0.fileName })
        XCTAssertTrue(names.contains("_PatchUIKit.swift"))
        XCTAssertTrue(names.contains("_ViewNodeIR_UIKitNode.swift"))
        XCTAssertTrue(names.contains("_ViewNodeIR_ViewNode.swift"), "shared IR types ship too")

        let wrapper = try XCTUnwrap(emission.files.first { $0.fileName == "_PatchUIKit.swift" })
        XCTAssertTrue(wrapper.contents.contains("@_cdecl(\"uikit_configure__ProfileCell\")"))
        XCTAssertTrue(wrapper.contents.contains("UIKitEmbeddedJSON.encode("))
    }

    // MARK: - 4b. Thunk generation (the interception layer)

    func testThunkInsertsDynamicAndGeneratesReplacement() throws {
        let url = URL(fileURLWithPath: "/tmp/ProfileCell.swift")
        let result = UIKitThunkGenerator().prepare(
            sources: [.init(url: url, text: profileCellSource)])

        // `dynamic` is inserted on the construction method.
        XCTAssertEqual(result.dynamicInsertions, 1, "one dynamic inserted on configure(with:)")
        let modified = try XCTUnwrap(result.modifiedFiles.first?.text)
        XCTAssertTrue(modified.contains("dynamic func configure(with model: CellModel)"),
                      "configure(with:) is made dynamic: \(modified)")

        // The thunk file has a signature-matching replacement that routes through the host.
        XCTAssertEqual(result.cellNames, ["ProfileCell"])
        let thunk = result.thunkFileContents
        XCTAssertTrue(thunk.contains("extension ProfileCell"), thunk)
        XCTAssertTrue(thunk.contains("@_dynamicReplacement(for: configure(with:))"), thunk)
        XCTAssertTrue(thunk.contains("func __patch_configure(with model: CellModel)"),
                      "the replacement mirrors the original signature: \(thunk)")
        XCTAssertTrue(thunk.contains("Patch.shared.installPatchedCell("), thunk)
        XCTAssertTrue(thunk.contains("typeName: \"ProfileCell\""), thunk)
        XCTAssertTrue(thunk.contains("model: model)"), "the model value is forwarded: \(thunk)")
        // Falls through to the ORIGINAL when not patched.
        XCTAssertTrue(thunk.contains("configure(with: model)"),
                      "the replacement calls the original when not installed: \(thunk)")
    }

    /// A cell whose construction DOESN'T lower gets NO dynamic + NO thunk (it stays
    /// 100% native — the cardinal demote rule applied at the thunk layer).
    func testNonLoweringCellGetsNoThunk() throws {
        let source = """
        import UIKit
        final class LoopCell: UICollectionViewCell {
            let stack = UIStackView()
            func configure(with model: M) {
                contentView.addSubview(stack)
                for x in model.items { stack.addArrangedSubview(UILabel()) }
            }
        }
        """
        let result = UIKitThunkGenerator().prepare(
            sources: [.init(url: URL(fileURLWithPath: "/tmp/LoopCell.swift"), text: source)])
        XCTAssertEqual(result.dynamicInsertions, 0, "a non-lowering cell gets no dynamic")
        XCTAssertTrue(result.cellNames.isEmpty, "and no thunk")
    }

    /// The thunk for a cell with a CUSTOM subview slot supplies the native slot closure.
    func testThunkSuppliesSlotClosures() throws {
        let source = """
        import UIKit
        struct ChartModel { let title: String }
        final class ChartCell: UITableViewCell {
            let titleLabel = UILabel()
            let chart = SparklineView()
            let stack = UIStackView()
            func configure(with model: ChartModel) {
                titleLabel.text = model.title
                stack.axis = .vertical
                stack.addArrangedSubview(titleLabel)
                stack.addArrangedSubview(chart)
                contentView.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: contentView.topAnchor)
                ])
            }
        }
        """
        let result = UIKitThunkGenerator().prepare(
            sources: [.init(url: URL(fileURLWithPath: "/tmp/ChartCell.swift"), text: source)])
        let thunk = result.thunkFileContents
        XCTAssertTrue(thunk.contains("__slots["), "the thunk supplies a slot closure: \(thunk)")
        XCTAssertTrue(thunk.contains("{ self.chart }"),
                      "the slot renders the cell's live chart property: \(thunk)")
        XCTAssertTrue(thunk.contains("PatchCellWiring(slots: __slots)"), thunk)
    }

    /// THE THUNK COMPILE PROOF: the generated thunk + the `dynamic`-patched cell must
    /// be well-formed Swift that correctly calls the host API — a thunk that doesn't
    /// compile is worthless. We type-check (for the iOS simulator triple, so UIKit +
    /// `@_dynamicReplacement` resolve) the modified cell + the thunk + a STUB of the
    /// exact `PatchSDK`/`PatchUIKit` host surface the thunk calls (`Patch.shared
    /// .installPatchedCell` + `PatchCellWiring`). Stubbing the host (instead of importing
    /// the real WasmKit-backed module) keeps the proof self-contained + fast while still
    /// catching every thunk-codegen bug (wrong signature, bad arg labels, mis-shaped
    /// wiring closure). The real thunk↔PatchUIKit integration is covered by the iOS
    /// cross-compile of PatchUIKit + the SDK host tests. Skips without the iOS SDK.
    func testGeneratedThunkTypeChecksForIOS() throws {
        let sdkPath = Self.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(sdkPath != nil && !(sdkPath ?? "").isEmpty, "no iphonesimulator SDK")

        // Includes BOTH a custom-view slot (`chart`) AND a design-system COLOR TOKEN
        // (`Palette.ink` — Lever D) so the type-check proves the generated wiring body
        // (`slots` + `colorTokens`) is well-formed Swift for iOS.
        let cellSrc = """
        import UIKit
        enum Palette { static var ink: UIColor { .label } }
        struct CellModel { let title: String; let subtitle: String }
        final class ProfileCell: UITableViewCell {
            let avatar = UIImageView()
            let titleLabel = UILabel()
            let chart = SparklineView()
            let stack = UIStackView()
            func configure(with model: CellModel) {
                titleLabel.text = model.title
                titleLabel.textColor = Palette.ink
                avatar.image = UIImage(systemName: "star")
                stack.axis = .vertical
                stack.addArrangedSubview(titleLabel)
                stack.addArrangedSubview(chart)
                contentView.addSubview(avatar)
                contentView.addSubview(stack)
                NSLayoutConstraint.activate([
                    avatar.widthAnchor.constraint(equalToConstant: 40),
                    stack.topAnchor.constraint(equalTo: contentView.topAnchor)
                ])
            }
        }
        """
        let url = URL(fileURLWithPath: "/tmp/ProfileCell.swift")
        let result = UIKitThunkGenerator().prepare(sources: [.init(url: url, text: cellSrc)])
        XCTAssertEqual(result.dynamicInsertions, 1)
        // The thunk supplies BOTH a slot closure and a color-token resolver (Lever D).
        XCTAssertTrue(result.thunkFileContents.contains("__colorTokens["),
                      "the thunk supplies a color-token resolver: \(result.thunkFileContents)")
        XCTAssertTrue(result.thunkFileContents.contains("(Palette.ink) as UIColor"),
                      "the token resolver evaluates the real design-system color: \(result.thunkFileContents)")
        XCTAssertTrue(result.thunkFileContents.contains("colorTokens: __colorTokens"),
                      "PatchCellWiring carries the colorTokens: \(result.thunkFileContents)")
        let modifiedCell = try XCTUnwrap(result.modifiedFiles.first?.text)

        // A STUB of the exact host surface the thunk references. The thunk's generated
        // file imports `PatchSDK`/`PatchUIKit`; we shadow those names with local stubs
        // (by stripping the imports + supplying the symbols in the same compile unit),
        // so the type-check exercises the thunk's CALL SHAPE without the WasmKit deps.
        let thunkNoImports = result.thunkFileContents
            .replacingOccurrences(of: "import PatchSDK\n", with: "")
            .replacingOccurrences(of: "import PatchUIKit\n", with: "")
        let hostStub = """
        import UIKit
        final class SparklineView: UIView {}
        struct PatchCellWiring {
            var slots: [String: () -> UIView]
            var actions: [String: () -> Void]
            var colorTokens: [String: () -> UIColor]
            init(slots: [String: () -> UIView] = [:],
                 actions: [String: () -> Void] = [:],
                 colorTokens: [String: () -> UIColor] = [:]) {
                self.slots = slots; self.actions = actions; self.colorTokens = colorTokens
            }
        }
        final class Patch {
            static let shared = Patch()
            @discardableResult
            func installPatchedCell(typeName: String, contentView: UIView, model: Any?,
                                    wiring: () -> PatchCellWiring = { PatchCellWiring() }) -> Bool { false }
        }
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uikit-thunk-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try modifiedCell.write(to: tmp.appendingPathComponent("ProfileCell.swift"), atomically: true, encoding: .utf8)
        try thunkNoImports.write(to: tmp.appendingPathComponent("Thunks.swift"), atomically: true, encoding: .utf8)
        try hostStub.write(to: tmp.appendingPathComponent("HostStub.swift"), atomically: true, encoding: .utf8)

        let args = [
            "-typecheck",
            "-sdk", sdkPath!,
            "-target", "arm64-apple-ios16.0-simulator",
            tmp.appendingPathComponent("ProfileCell.swift").path,
            tmp.appendingPathComponent("Thunks.swift").path,
            tmp.appendingPathComponent("HostStub.swift").path
        ]
        let log = Self.run("/usr/bin/swiftc", args, captureStderr: true) ?? ""
        XCTAssertFalse(log.contains("error:"),
                       "the generated thunk + patched cell must type-check for iOS:\n\(log)")
    }

    /// The generated NUMERIC-token thunk must type-check for iOS too: a cross-file numeric
    /// design constant in a constraint constant / `cornerRadius` lowers as a `.number` host
    /// token, and the thunk's `__numberTokens[id] = { Double(<source>) }` resolver + the
    /// `PatchCellWiring(numberTokens:)` call must be well-formed Swift. (The number rides
    /// the input JSON — no renderer-table application — but the THUNK code that resolves it
    /// must still compile against the real cell scope.)
    func testGeneratedNumberTokenThunkTypeChecksForIOS() throws {
        let sdkPath = Self.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(sdkPath != nil && !(sdkPath ?? "").isEmpty, "no iphonesimulator SDK")

        // `Theme.Radius.card` + `Theme.Spacing.row` are numeric design constants. They're
        // declared as DERIVED values (`= baseUnit()`) so the build-time literal-fold (Lever
        // B) can't reduce them to a literal — they MUST host-tokenize (the deferred-lever
        // path, structurally identical to a cross-file constant: the engine tokenizes by
        // shape, not by file). The thunk's `Double(Theme.Radius.card)` resolver proves the
        // generated number-token wiring is well-formed Swift for iOS.
        let cellSrc = """
        import UIKit
        func baseUnit() -> CGFloat { 4 }
        enum Theme {
            enum Radius { static let card: CGFloat = baseUnit() * 3 }
            enum Spacing { static let row: CGFloat = baseUnit() * 2 }
        }
        struct CellModel { let title: String }
        final class CardyCell: UITableViewCell {
            let titleLabel = UILabel()
            let stack = UIStackView()
            func configure(with model: CellModel) {
                titleLabel.text = model.title
                stack.axis = .vertical
                stack.spacing = Theme.Spacing.row
                stack.addArrangedSubview(titleLabel)
                contentView.addSubview(stack)
                contentView.layer.cornerRadius = Theme.Radius.card
                titleLabel.widthAnchor.constraint(equalToConstant: Theme.Radius.card).isActive = true
            }
        }
        """
        let url = URL(fileURLWithPath: "/tmp/CardyCell.swift")
        let result = UIKitThunkGenerator().prepare(sources: [.init(url: url, text: cellSrc)])
        XCTAssertEqual(result.dynamicInsertions, 1)
        XCTAssertTrue(result.thunkFileContents.contains("__numberTokens["),
                      "the thunk supplies a number-token resolver: \(result.thunkFileContents)")
        XCTAssertTrue(result.thunkFileContents.contains("Double(Theme.Radius.card)"),
                      "the resolver evaluates the real numeric constant: \(result.thunkFileContents)")
        XCTAssertTrue(result.thunkFileContents.contains("numberTokens: __numberTokens"),
                      "PatchCellWiring carries the numberTokens: \(result.thunkFileContents)")
        let modifiedCell = try XCTUnwrap(result.modifiedFiles.first?.text)

        let thunkNoImports = result.thunkFileContents
            .replacingOccurrences(of: "import PatchSDK\n", with: "")
            .replacingOccurrences(of: "import PatchUIKit\n", with: "")
        let hostStub = """
        import UIKit
        struct PatchCellWiring {
            var slots: [String: () -> UIView]
            var actions: [String: () -> Void]
            var colorTokens: [String: () -> UIColor]
            var numberTokens: [String: () -> Double]
            init(slots: [String: () -> UIView] = [:],
                 actions: [String: () -> Void] = [:],
                 colorTokens: [String: () -> UIColor] = [:],
                 numberTokens: [String: () -> Double] = [:]) {
                self.slots = slots; self.actions = actions
                self.colorTokens = colorTokens; self.numberTokens = numberTokens
            }
        }
        final class Patch {
            static let shared = Patch()
            @discardableResult
            func installPatchedCell(typeName: String, contentView: UIView, model: Any?,
                                    wiring: () -> PatchCellWiring = { PatchCellWiring() }) -> Bool { false }
        }
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uikit-numthunk-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try modifiedCell.write(to: tmp.appendingPathComponent("CardyCell.swift"), atomically: true, encoding: .utf8)
        try thunkNoImports.write(to: tmp.appendingPathComponent("Thunks.swift"), atomically: true, encoding: .utf8)
        try hostStub.write(to: tmp.appendingPathComponent("HostStub.swift"), atomically: true, encoding: .utf8)

        let args = [
            "-typecheck",
            "-sdk", sdkPath!,
            "-target", "arm64-apple-ios16.0-simulator",
            tmp.appendingPathComponent("CardyCell.swift").path,
            tmp.appendingPathComponent("Thunks.swift").path,
            tmp.appendingPathComponent("HostStub.swift").path
        ]
        let log = Self.run("/usr/bin/swiftc", args, captureStderr: true) ?? ""
        XCTAssertFalse(log.contains("error:"),
                       "the generated number-token thunk + patched cell must type-check for iOS:\n\(log)")
    }

    /// The generated GESTURE + OBSERVER wiring thunk (Levers 1+2) must type-check for iOS:
    /// the gesture closure's `__v.addGestureRecognizer(UITapGestureRecognizer(target: self,
    /// action: #selector(self.handleTap)))` and the observer closure's verbatim
    /// `NotificationCenter.default.addObserver(self, selector: #selector(self.onNote(_:)),…)`
    /// must compile against the REAL cell scope (the `#selector`s resolve, the wiring labels
    /// are right) — a thunk that doesn't compile is worthless. Stubs the host surface
    /// (`PatchCellWiring` + `Patch.shared.installPatchedCell`) like the slot/token tests.
    func testGeneratedGestureAndObserverThunkTypeChecksForIOS() throws {
        let sdkPath = Self.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(sdkPath != nil && !(sdkPath ?? "").isEmpty, "no iphonesimulator SDK")

        // A CELL whose `configure(with:)` wires a gesture on a known view AND an observer —
        // the rest of the body (the tree) lowers. `handleTap` / `onNote` are `@objc`
        // (selector-able) and accessible (not private), so the thunk's `#selector`s resolve.
        let cellSrc = """
        import UIKit
        struct CardModel { let title: String }
        final class TappableCardCell: UITableViewCell {
            let card = UIImageView()
            let titleLabel = UILabel()
            func configure(with model: CardModel) {
                titleLabel.text = model.title
                card.contentMode = .scaleAspectFill
                contentView.addSubview(card)
                contentView.addSubview(titleLabel)
                card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
                NotificationCenter.default.addObserver(self, selector: #selector(onNote(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
            }
            @objc func handleTap() {}
            @objc func onNote(_ n: Notification) {}
        }
        """
        let url = URL(fileURLWithPath: "/tmp/TappableCardCell.swift")
        let result = UIKitThunkGenerator().prepare(sources: [.init(url: url, text: cellSrc)])
        XCTAssertEqual(result.dynamicInsertions, 1)
        let thunk = result.thunkFileContents
        XCTAssertTrue(thunk.contains("__gestureWirings["),
                      "the thunk supplies a gesture wiring: \(thunk)")
        XCTAssertTrue(thunk.contains("__v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))"),
                      "the gesture closure replays the verbatim wiring: \(thunk)")
        XCTAssertTrue(thunk.contains("__observerEffects.append { [self] in NotificationCenter.default.addObserver(self, selector: #selector(onNote(_:))"),
                      "the observer closure replays the verbatim addObserver: \(thunk)")
        XCTAssertTrue(thunk.contains("gestureWirings: __gestureWirings"), thunk)
        XCTAssertTrue(thunk.contains("observerEffects: __observerEffects"), thunk)
        let modifiedCell = try XCTUnwrap(result.modifiedFiles.first?.text)

        let thunkNoImports = thunk
            .replacingOccurrences(of: "import PatchSDK\n", with: "")
            .replacingOccurrences(of: "import PatchUIKit\n", with: "")
        let hostStub = """
        import UIKit
        struct PatchCellWiring {
            var slots: [String: () -> UIView]
            var actions: [String: () -> Void]
            var colorTokens: [String: () -> UIColor]
            var numberTokens: [String: () -> Double]
            var gestureWirings: [String: [(UIView) -> Void]]
            var observerEffects: [() -> Void]
            init(slots: [String: () -> UIView] = [:],
                 actions: [String: () -> Void] = [:],
                 colorTokens: [String: () -> UIColor] = [:],
                 numberTokens: [String: () -> Double] = [:],
                 gestureWirings: [String: [(UIView) -> Void]] = [:],
                 observerEffects: [() -> Void] = []) {
                self.slots = slots; self.actions = actions
                self.colorTokens = colorTokens; self.numberTokens = numberTokens
                self.gestureWirings = gestureWirings; self.observerEffects = observerEffects
            }
        }
        final class Patch {
            static let shared = Patch()
            @discardableResult
            func installPatchedCell(typeName: String, contentView: UIView, model: Any?,
                                    wiring: () -> PatchCellWiring = { PatchCellWiring() }) -> Bool { false }
        }
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uikit-gesturethunk-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try modifiedCell.write(to: tmp.appendingPathComponent("TappableCardCell.swift"), atomically: true, encoding: .utf8)
        try thunkNoImports.write(to: tmp.appendingPathComponent("Thunks.swift"), atomically: true, encoding: .utf8)
        try hostStub.write(to: tmp.appendingPathComponent("HostStub.swift"), atomically: true, encoding: .utf8)

        let args = [
            "-typecheck",
            "-sdk", sdkPath!,
            "-target", "arm64-apple-ios16.0-simulator",
            tmp.appendingPathComponent("TappableCardCell.swift").path,
            tmp.appendingPathComponent("Thunks.swift").path,
            tmp.appendingPathComponent("HostStub.swift").path
        ]
        let log = Self.run("/usr/bin/swiftc", args, captureStderr: true) ?? ""
        XCTAssertFalse(log.contains("error:"),
                       "the generated gesture+observer thunk + patched cell must type-check for iOS:\n\(log)")
    }

    /// BUG #2 + #17/#18 thunk-compile proof: a `viewDidLoad`-built VC thunk (which must
    /// NOT emit `override func __patch_viewDidLoad()` — a non-compiling thunk) AND a cell
    /// with an `addTarget(self, action: #selector(handler), …)` (whose handler the thunk
    /// must wire as `__actions[id] = { [self] in self.<handler>() }`) must both type-check
    /// for iOS. A regression on either fix produces a thunk that doesn't compile / a dead
    /// control — exactly what this build-safety harness catches.
    func testGeneratedActionAndViewDidLoadThunksTypeCheckForIOS() throws {
        let sdkPath = Self.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(sdkPath != nil && !(sdkPath ?? "").isEmpty, "no iphonesimulator SDK")

        // (1) A button cell wiring a `self`/`#selector` action — the thunk must emit a
        // native handler. (2) A programmatic VC building its view tree in `viewDidLoad` —
        // its replacement must be `func __patch_viewDidLoad()` (NOT `override`).
        let cellSrc = """
        import UIKit
        struct M { let label: String }
        final class TapCell: UITableViewCell {
            let btn = UIButton(type: .system)
            func configure(with m: M) {
                btn.setTitle(m.label, for: .normal)
                btn.addTarget(self, action: #selector(tap), for: .touchUpInside)
                contentView.addSubview(btn)
            }
            @objc func tap() {}
        }
        final class FeedViewController: UIViewController {
            let titleLabel = UILabel()
            var heading = "Feed"
            override func viewDidLoad() {
                super.viewDidLoad()
                titleLabel.text = heading
                view.addSubview(titleLabel)
                NSLayoutConstraint.activate([
                    titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                    titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
                ])
            }
        }
        """
        let url = URL(fileURLWithPath: "/tmp/TapAndFeed.swift")
        let result = UIKitThunkGenerator().prepare(sources: [.init(url: url, text: cellSrc)])
        let thunk = result.thunkFileContents
        // BUG #17/#18: the action handler is wired (not dead).
        XCTAssertTrue(thunk.contains("__actions["), "the thunk supplies an action handler: \(thunk)")
        XCTAssertTrue(thunk.contains("self.tap()"), "the action calls the cell's native handler: \(thunk)")
        XCTAssertTrue(thunk.contains("actions: __actions"), thunk)
        // BUG #2: the viewDidLoad replacement is NOT override (would not compile otherwise).
        XCTAssertTrue(thunk.contains("func __patch_viewDidLoad()"), thunk)
        XCTAssertFalse(thunk.contains("override func __patch_viewDidLoad()"),
                       "the viewDidLoad replacement must NOT be override: \(thunk)")

        let modified = result.modifiedFiles.map { $0.text }.joined(separator: "\n")
        let thunkNoImports = thunk
            .replacingOccurrences(of: "import PatchSDK\n", with: "")
            .replacingOccurrences(of: "import PatchUIKit\n", with: "")
        let hostStub = """
        import UIKit
        struct PatchCellWiring {
            var slots: [String: () -> UIView]
            var actions: [String: () -> Void]
            init(slots: [String: () -> UIView] = [:],
                 actions: [String: () -> Void] = [:]) {
                self.slots = slots; self.actions = actions
            }
        }
        final class Patch {
            static let shared = Patch()
            @discardableResult
            func installPatchedCell(typeName: String, contentView: UIView, model: Any?,
                                    wiring: () -> PatchCellWiring = { PatchCellWiring() }) -> Bool { false }
        }
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uikit-action-vdl-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try modified.write(to: tmp.appendingPathComponent("Source.swift"), atomically: true, encoding: .utf8)
        try thunkNoImports.write(to: tmp.appendingPathComponent("Thunks.swift"), atomically: true, encoding: .utf8)
        try hostStub.write(to: tmp.appendingPathComponent("HostStub.swift"), atomically: true, encoding: .utf8)

        let args = [
            "-typecheck",
            "-sdk", sdkPath!,
            "-target", "arm64-apple-ios16.0-simulator",
            tmp.appendingPathComponent("Source.swift").path,
            tmp.appendingPathComponent("Thunks.swift").path,
            tmp.appendingPathComponent("HostStub.swift").path
        ]
        let log = Self.run("/usr/bin/swiftc", args, captureStderr: true) ?? ""
        XCTAssertFalse(log.contains("error:"),
                       "the generated action + viewDidLoad thunks + patched source must type-check for iOS:\n\(log)")
    }

    /// Run a tool, returning stdout (or stdout+stderr when `captureStderr`). nil on
    /// spawn failure.
    static func run(_ launchPath: String, _ args: [String], captureStderr: Bool = false) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = captureStderr ? out : Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 5. END-TO-END: lower → compile → host-run uikit_configure in WASM

    func testCellConfigureExecutesInWasm() throws {
        let lowering = UIKitCellLowering()
        let cells = lowering.lowerAllCells(source: profileCellSource)
        let guestCells = cells.map { UIKitGuestEmitter.GuestCell(from: $0) }
        let emission = try UIKitGuestEmitter().emit(cells: guestCells)

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping uikit_configure execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uikit-exec-\(UUID().uuidString)")
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
        XCTAssertEqual(result.status, .success, "UIKit guest WASM compile failed:\n\(result.log)")

        // Host-run uikit_configure with a marshalled model.
        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        let inputs = Data(#"{"title":"Ada Lovelace","subtitle":"Engineer"}"#.utf8)
        let outBytes = try runner.callPacked("uikit_configure", [UInt8](inputs))
        XCTAssertFalse(outBytes.isEmpty, "uikit_configure returned no bytes")

        // Decode the UIKitEmission and assert the tree reflects the marshalled model.
        let body = try JSONDecoder().decode(UIKitEmission.self, from: Data(outBytes))
        // Find the title label node (text == model.title).
        XCTAssertTrue(Self.containsLabel(body.root, text: "Ada Lovelace"),
                      "the title label carries the marshalled model.title")
        XCTAssertTrue(Self.containsLabel(body.root, text: "Engineer"),
                      "the subtitle label carries the marshalled model.subtitle")
        // The avatar image rode WASM.
        XCTAssertTrue(Self.containsImage(body.root, systemName: "person.crop.circle"),
                      "the avatar image node is in the WASM-built tree")
        // Zero native fallback — the whole cell rode WASM.
        XCTAssertEqual(body.root.slotNodeCount, 0, "no node fell back to a native slot")
        // The constraints rode through (the avatar's 40×40 + the pins).
        XCTAssertGreaterThanOrEqual(body.root.constraintCount, 6,
                                    "the lowered constraints are in the tree")
    }

    // MARK: - Tree search helpers

    static func containsLabel(_ node: UIKitNode, text: String) -> Bool {
        if case .label(let t, _, _, _, _) = node.kind, t == text { return true }
        return node.childNodes.contains { containsLabel($0, text: text) }
    }
    static func containsImage(_ node: UIKitNode, systemName: String) -> Bool {
        if case .imageView(let img, _, _) = node.kind, case .systemName(let n) = img, n == systemName { return true }
        return node.childNodes.contains { containsImage($0, systemName: systemName) }
    }

    // MARK: - Minimal WasmKit host runner (mirrors SwiftUILoweringTests.Runner)

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
