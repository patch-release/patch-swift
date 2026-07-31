// SPDX-License-Identifier: Apache-2.0

// UIKitThunkGenerator.swift — build-time codegen for OUT-OF-THE-BOX UIKit cell
// patching (the interception layer).
// =============================================================================
// The UIKit analogue of `ThunkGenerator`. Makes a cell's recognized construction
// method patchable with ZERO developer changes to the cell. Two outputs, both
// compiled INTO the app (App-Store-legal — only DATA changes at runtime):
//
//   1. `dynamic` is inserted on each recognized construction method (`func
//      configure(with:)` / `setup()`), placed precisely before the `func` keyword
//      via SwiftSyntax token offsets so attributes/access-modifiers/formatting are
//      preserved. This is what makes the method REPLACEABLE.
//   2. A generated `PatchUIKitThunks.generated.swift` with one
//      `@_dynamicReplacement(for: configure(with:))` extension per cell. Each thunk
//      asks the SDK to install a patched construction; if the active OTA module ships
//      one it renders the WASM tree into `contentView` and RETURNS (skipping the
//      native build), else it calls the ORIGINAL method (a direct call inside the
//      replacement reaches the original — the same mechanism the SwiftUI thunk uses).
//
// IDEMPOTENT + re-runnable: a method already `dynamic` is left as-is; the thunk file
// is regenerated wholesale.
//
// The thunk supplies the LIVE wiring: native slot closures for the cell's custom
// subview leaves (rendering `self.<prop>`) + action handlers mapping the lowered
// control ids to the cell's `#selector` methods, all captured over `self`.

import Foundation
import SwiftSyntax
import SwiftParser
import ViewNodeIR

public struct UIKitThunkGenerator {
    public init() {}

    /// The generated thunk file name.
    public static let thunkFileName = "PatchUIKitThunks.generated.swift"

    public struct SourceFile {
        public let url: URL
        public let text: String
        public init(url: URL, text: String) { self.url = url; self.text = text }
    }

    public struct Result {
        /// Files whose source changed (a `dynamic` was inserted), new text each.
        public var modifiedFiles: [(url: URL, text: String)]
        /// The generated thunk file contents (one extension per cell).
        public var thunkFileContents: String
        /// The cell type names that got a thunk (sorted, deterministic).
        public var cellNames: [String]
        /// Total `dynamic` keywords inserted across all files this run.
        public var dynamicInsertions: Int
    }

    // MARK: - Public API

    /// Prepare a whole project: discover cell types with a recognized declarative
    /// construction, make that method `dynamic`, and generate the replacement-thunk
    /// file. A cell whose construction DOESN'T lower (the cardinal demote) gets no
    /// `dynamic` + no thunk — it stays 100% native.
    public func prepare(sources: [SourceFile]) -> Result {
        let lowering = UIKitCellLowering()

        // (1) Lower every cell across all files; keep only those that lowered AND are
        // thunkSafe (a non-thunkSafe cell — an unslotable leaf / unmarshalled input —
        // stays native). A cell type that appears in >1 file (ambiguous extension
        // target) is dropped (conservative, like the SwiftUI generator).
        var loweredByType: [String: UIKitCellLowering.LoweredCell] = [:]
        var typeFileCount: [String: Int] = [:]
        for file in sources {
            for cell in lowering.lowerAllCells(source: file.text) {
                typeFileCount[cell.typeName, default: 0] += 1
                guard cell.thunkSafe else { continue }
                if loweredByType[cell.typeName] == nil { loweredByType[cell.typeName] = cell }
            }
        }
        let eligible = loweredByType.filter { typeFileCount[$0.key, default: 0] <= 1 }

        // (2) Per file: insert `dynamic` before each eligible cell's construction
        // method (skipping methods inside `#if`).
        var modifiedFiles: [(url: URL, text: String)] = []
        var totalInsertions = 0
        for file in sources {
            let tree = Parser.parse(source: file.text)
            let collector = MethodCollector(cellSelectors: eligible.mapValues { $0.replacedSelector })
            collector.walk(tree)
            let toInsert = collector.hits.filter { !$0.alreadyDynamic }.map { $0.offset }
            guard !toInsert.isEmpty else { continue }
            let newText = Self.insertDynamic(into: file.text, atUTF8Offsets: toInsert)
            modifiedFiles.append((file.url, newText))
            totalInsertions += toInsert.count
        }

        // (3) The thunk file (one extension per eligible cell, sorted).
        let cellNames = eligible.keys.sorted()
        let imports = Self.collectImports(sources)
        let thunkFile = Self.renderThunkFile(
            cells: cellNames.compactMap { eligible[$0] }, extraImports: imports)

        return Result(modifiedFiles: modifiedFiles,
                      thunkFileContents: thunkFile,
                      cellNames: cellNames,
                      dynamicInsertions: totalInsertions)
    }

    /// The union of plain top-level imports across the cell files, minus the ones the
    /// thunk file always declares (UIKit / PatchSDK / PatchUIKit). These let a slot
    /// closure reference a third-party custom-view type used in a cell.
    static func collectImports(_ sources: [SourceFile]) -> [String] {
        var seen = Set<String>(["UIKit", "PatchSDK", "PatchUIKit", "Foundation"])
        var out: [String] = []
        for src in sources {
            let tree = Parser.parse(source: src.text)
            for stmt in tree.statements {
                guard let imp = stmt.item.as(ImportDeclSyntax.self),
                      imp.attributes.isEmpty, imp.importKindSpecifier == nil else { continue }
                let path = imp.path.trimmedDescription
                guard !path.isEmpty, !path.contains("."), seen.insert(path).inserted else { continue }
                out.append(path)
            }
        }
        return out.sorted()
    }

    // MARK: - Precise `dynamic` insertion

    static func insertDynamic(into source: String, atUTF8Offsets offsets: [Int]) -> String {
        var bytes = Array(source.utf8)
        let token = Array("dynamic ".utf8)
        for off in offsets.sorted(by: >) {
            guard off >= 0, off <= bytes.count else { continue }
            bytes.insert(contentsOf: token, at: off)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Thunk file rendering

    static func renderThunkFile(cells: [UIKitCellLowering.LoweredCell],
                                extraImports: [String] = []) -> String {
        var out = """
        // PatchUIKitThunks.generated.swift — GENERATED BY `patchcli prepare`. DO NOT EDIT.
        // @generated
        // =========================================================================
        // AUTOGENERATED FILE — DO NOT EDIT BY HAND OR WITH AN AI CODING ASSISTANT.
        //
        // This file is regenerated on every `patchcli prepare` run (which also runs
        // automatically inside `patchcli build`/`push`/`release`). Any manual edit
        // here is SILENTLY OVERWRITTEN on the next prepare. An inconsistent thunk
        // can break the OTA fingerprint (causing a MISMATCH that blocks your release).
        //
        // To change a cell's behaviour: edit the CELL SOURCE FILE itself — never
        // this generated thunk. To regenerate from scratch, delete this file and
        // run `patchcli prepare`.
        // =========================================================================
        // One `@_dynamicReplacement(for:)` per UIKit cell whose declarative construction
        // is OTA-patchable. Each thunk routes the cell's construction through the Patch
        // UIKit host when a patch is active (rendering the WASM tree into contentView),
        // and falls through to the original compiled construction otherwise. This makes
        // a cell's construction patchable over-the-air with no changes to the cell.
        //
        // Each thunk also supplies the LIVE wiring: native slot closures for the cell's
        // non-lowerable subview leaves (rendering the cell's existing property), and
        // action handlers mapping the lowered control ids to the cell's native methods.
        // The host fills these in so the lowered parts ride WASM (patchable) while native
        // leaves render from this compiled-in code. (If a patch changes a native leaf,
        // its id no longer matches a slot and the host renders the cell fully native.)
        //
        // Regenerated wholesale on every `patchcli prepare`. Safe to delete — running
        // `patchcli prepare` recreates it (and re-inserts the `dynamic` keywords).

        #if canImport(UIKit)
        import UIKit
        import PatchSDK
        import PatchUIKit

        """
        for imp in extraImports {
            out += "#if canImport(\(imp))\nimport \(imp)\n#endif\n"
        }

        for cell in cells {
            out += Self.renderCellThunk(cell)
        }
        out += "#endif\n"
        return out
    }

    /// One cell's `@_dynamicReplacement` extension. The replacement is a SEPARATE
    /// method (`__patch_<base>`) with the SAME signature as the original construction
    /// (so `@_dynamicReplacement(for:)` type-checks), whose body asks the host to
    /// install the patch and — if it did — RETURNS (skipping the native build); else it
    /// calls the ORIGINAL (a direct call inside the replacement reaches the compiled
    /// method).
    static func renderCellThunk(_ cell: UIKitCellLowering.LoweredCell) -> String {
        let funcBase = Self.functionBase(cell.replacedSelector)   // `configure` / `setup` / `viewDidLoad`
        let replacementName = "__patch_\(funcBase)"
        let paramClause = cell.methodParameterClause.isEmpty ? "()" : cell.methodParameterClause
        // The original call forwards the bound parameters by label (`configure(with: model)`).
        let originalCall = Self.originalCall(selector: cell.replacedSelector,
                                             modelParam: cell.modelParamName)

        // Slot closures: each custom-view leaf renders its source over `self`.
        let slotEntries = cell.customSlots.filter { $0.slotable && !$0.source.isEmpty }
            .map { "            __slots[\"\($0.id)\"] = { \($0.source) }\n" }.joined()
        // Action handlers (BUG #17/#18 fix): each lowered control's action id maps to the
        // cell's native `#selector` handler, called DIRECTLY (`self.<selector>()`) — the
        // renderer's dispatcher invokes `actions[event.id]` when the user taps/flips/edits
        // the patched control. Without this the control rendered but the action was DEAD.
        // The `[self]` capture makes the member call explicit (an escaping closure). The
        // selector was vetted thunk-reachable (a `self` target, non-private) at lowering.
        let actionEntries = cell.actionWirings.filter { !$0.selector.isEmpty }
            .map { "            __actions[\"\($0.id)\"] = { [self] in self.\($0.selector)() }\n" }
            .joined()
        // Color-token resolvers (Lever D): each lowered `.hostToken(id)` evaluates its real
        // design-system color expression NATIVELY over `self`. `as UIColor` pins the result
        // type (a `UIColor?`-returning `.color` member coerces; a non-UIColor would not
        // compile — the token was structurally vetted as a color at lowering).
        let tokenEntries = cell.hostTokens.filter { $0.kind == .color && !$0.source.isEmpty }
            .map { "            __colorTokens[\"\($0.id)\"] = { (\($0.source)) as UIColor }\n" }.joined()
        // Number-token resolvers (Lever D for numbers): each lowered `.number` host token
        // evaluates its real cross-file/computed design-system NUMERIC constant NATIVELY
        // over `self` (`TPMenuUX.UX.viewCornerRadius`, `Theme.Radius.card`). `Double(...)`
        // pins the result type (a `CGFloat`/`Int`/`Double` constant coerces; a non-numeric
        // would not compile — the token was structurally vetted as a number at lowering).
        // The SDK MERGES the resolved value into the model JSON under the token's input
        // key, so the guest reads it as a `.double` input (rides the input JSON, like the
        // SwiftUI numeric token; no renderer-table application).
        let numberEntries = cell.hostTokens.filter { $0.kind == .number && !$0.source.isEmpty }
            .map { "            __numberTokens[\"\($0.id)\"] = { Double(\($0.source)) }\n" }.joined()
        // Gesture wirings (Lever 1): one native replay closure per gesture, keyed by the
        // attached view's node id. The `#selector` is resolved NATIVELY here (a compile-time
        // `#selector` in the generated thunk — the whole safety point). A view may carry
        // several gestures, so each key accumulates an array. The `[self]` capture makes the
        // `target: self` + `#selector(handler)` references explicit (Swift requires explicit
        // `self` for member references inside an escaping closure).
        let gestureEntries = cell.gestureWirings.filter { !$0.source.isEmpty }
            .map { "            __gestureWirings[\"\($0.viewNodeID)\", default: []].append { [self] __v in __v.addGestureRecognizer(\($0.source)) }\n" }
            .joined()
        // Observer effects (Lever 2): one native replay closure per registration. Each
        // re-runs the verbatim `NotificationCenter.default.addObserver(self, selector:…)`.
        // `[self]` makes the `self` observer target + `#selector(handler)` explicit.
        let observerEntries = cell.observerEffects.filter { !$0.source.isEmpty }
            .map { "            __observerEffects.append { [self] in \($0.source) }\n" }
            .joined()
        // QUARANTINED NATIVE EFFECTS (Goal 1): one native replay closure per isolatable
        // imperative statement, in SOURCE ORDER (the engine already sorted by ordinal). Each
        // runs once against `self` (`{ [self] in <source> }`); the whole statement is
        // emitted VERBATIM — the build-safety point (the engine vetted that it compiles in
        // this cross-file `extension <Cell>` scope + references no unreachable member, so a
        // bare `tableView.delegate = self` resolves to `self.tableView` here).
        let nativeEffectEntries = cell.nativeEffects.filter { !$0.source.isEmpty }
            .map { "            __nativeEffects.append { [self] in \($0.source) }\n" }
            .joined()
        let wiringBody: String
        if slotEntries.isEmpty && actionEntries.isEmpty && tokenEntries.isEmpty
            && numberEntries.isEmpty && gestureEntries.isEmpty && observerEntries.isEmpty
            && nativeEffectEntries.isEmpty {
            wiringBody = "PatchCellWiring()"
        } else {
            var setup = ""
            if !slotEntries.isEmpty { setup += "var __slots: [String: () -> UIView] = [:]\n\(slotEntries)" }
            if !actionEntries.isEmpty { setup += "            var __actions: [String: () -> Void] = [:]\n\(actionEntries)" }
            if !tokenEntries.isEmpty { setup += "            var __colorTokens: [String: () -> UIColor] = [:]\n\(tokenEntries)" }
            if !numberEntries.isEmpty { setup += "            var __numberTokens: [String: () -> Double] = [:]\n\(numberEntries)" }
            if !gestureEntries.isEmpty { setup += "            var __gestureWirings: [String: [(UIView) -> Void]] = [:]\n\(gestureEntries)" }
            if !observerEntries.isEmpty { setup += "            var __observerEffects: [() -> Void] = []\n\(observerEntries)" }
            if !nativeEffectEntries.isEmpty { setup += "            var __nativeEffects: [() -> Void] = []\n\(nativeEffectEntries)" }
            let args = [slotEntries.isEmpty ? nil : "slots: __slots",
                        actionEntries.isEmpty ? nil : "actions: __actions",
                        tokenEntries.isEmpty ? nil : "colorTokens: __colorTokens",
                        numberEntries.isEmpty ? nil : "numberTokens: __numberTokens",
                        gestureEntries.isEmpty ? nil : "gestureWirings: __gestureWirings",
                        observerEntries.isEmpty ? nil : "observerEffects: __observerEffects",
                        nativeEffectEntries.isEmpty ? nil : "nativeEffects: __nativeEffects"]
                .compactMap { $0 }.joined(separator: ", ")
            wiringBody = "{ \(setup)            return PatchCellWiring(\(args)) }()"
        }

        // A VC roots its content at `self.view` and its model is `self` (stored props);
        // a cell roots at `self.contentView` and forwards its bound `with:` model. The
        // host install + teardown-prior+rebuild (`clearPatchedRoot`) is identical — only
        // the host view + model source differ (Goal 2's manufactured tier-C seat).
        let isVC = cell.containerKind == .viewController
        // The replacement (`__patch_<base>`) is a SEPARATE method declared in an
        // `extension` — it is NEVER `override`, even when it replaces an overridden
        // lifecycle method like `viewDidLoad`. Two reasons it can't be: (1) Swift forbids
        // `override` on a declaration inside an extension, and (2) `__patch_viewDidLoad`
        // does not override any superclass method (it has a fresh name; the
        // `@_dynamicReplacement(for: viewDidLoad)` attribute — not `override` — is what
        // routes the original `viewDidLoad` to it at runtime). Emitting `override` here
        // produces a non-compiling thunk that breaks the whole app build, so it is dropped
        // unconditionally — the SwiftUI body-replacement thunk is non-`override` for the
        // exact same reason.
        let containerExpr = isVC ? "self.view" : "self.contentView"
        let modelArg = isVC ? "self" : (cell.modelParamName ?? "nil")

        return """

        extension \(cell.typeName) {
            @_dynamicReplacement(for: \(cell.replacedSelector))
            func \(replacementName)\(paramClause) {
                let __installed = Patch.shared.installPatchedCell(
                    typeName: "\(SwiftUIGuestEmitter.sanitizedViewName(cell.typeName))",
                    contentView: \(containerExpr),
                    model: \(modelArg)) {
                    \(wiringBody)
                }
                if !__installed {
                    \(originalCall)
                }
            }
        }

        """
    }

    /// The function base name of a selector (`configure(with:)` → `configure`).
    static func functionBase(_ selector: String) -> String {
        if let paren = selector.firstIndex(of: "(") { return String(selector[..<paren]) }
        return selector
    }

    /// The call that reaches the ORIGINAL method from inside the replacement, with the
    /// bound parameters forwarded by label. `configure(with:)` + model `model` →
    /// `configure(with: model)`; `setup()` → `setup()`.
    static func originalCall(selector: String, modelParam: String?) -> String {
        let base = functionBase(selector)
        // Extract the single label (cell hooks take one model param: `with`/`_`).
        guard let open = selector.firstIndex(of: "("),
              let close = selector.firstIndex(of: ")"), open < close else {
            return "\(base)()"
        }
        let labels = selector[selector.index(after: open)..<close]
        if labels.isEmpty { return "\(base)()" }
        // One labeled param: `configure(with:)` + `model` → `configure(with: model)`.
        // The `_:` (unlabeled) form: `configure(_:)` + `model` → `configure(model)`.
        let label = String(labels.dropLast())   // strip the trailing ':'
        let arg = modelParam ?? "nil"
        if label == "_" { return "\(base)(\(arg))" }
        return "\(base)(\(label): \(arg))"
    }
}

// MARK: - Method collector (find the construction method to make `dynamic`)

private final class MethodCollector: SyntaxVisitor {
    /// cell type name → the selector of its construction method (`configure(with:)`).
    let cellSelectors: [String: String]
    private var typeStack: [String] = []
    private var ifConfigDepth = 0
    /// (offset of the `func`/`init` keyword, enclosing type, already `dynamic`?).
    private(set) var hits: [(offset: Int, type: String, alreadyDynamic: Bool)] = []

    init(cellSelectors: [String: String]) {
        self.cellSelectors = cellSelectors
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        ifConfigDepth += 1; return .visitChildren
    }
    override func visitPost(_ node: IfConfigDeclSyntax) { ifConfigDepth -= 1 }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard ifConfigDepth == 0, let type = typeStack.last,
              let selector = cellSelectors[type] else { return .visitChildren }
        // Match the function by its selector (name + labels).
        let labels = node.signature.parameterClause.parameters.map {
            ($0.firstName.text == "_" ? "_" : $0.firstName.text) + ":"
        }.joined()
        let fnSelector = labels.isEmpty ? node.name.text : "\(node.name.text)(\(labels))"
        guard fnSelector == selector else { return .visitChildren }
        let offset = node.funcKeyword.positionAfterSkippingLeadingTrivia.utf8Offset
        let alreadyDynamic = node.modifiers.contains { $0.name.tokenKind == .keyword(.dynamic) }
        hits.append((offset, type, alreadyDynamic))
        return .visitChildren
    }
}
