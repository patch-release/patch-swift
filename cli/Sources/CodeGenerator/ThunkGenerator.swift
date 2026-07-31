// SPDX-License-Identifier: Apache-2.0

// ThunkGenerator.swift — build-time codegen for OUT-OF-THE-BOX view patching.
// =============================================================================
// Makes a SwiftUI app's view bodies patchable with ZERO developer changes to the
// views themselves. Two outputs, both compiled INTO the app (App-Store-legal —
// only DATA changes at runtime, never code):
//
//   1. `dynamic` is inserted on every eligible `var body: some View` (one word,
//      placed precisely before the `var` keyword via SwiftSyntax token offsets,
//      so attributes/access-modifiers/formatting are preserved). This is what
//      makes the body REPLACEABLE — the same thing Xcode Previews does.
//   2. A generated `PatchThunks.generated.swift` with one
//      `@_dynamicReplacement(for: body)` extension per View. Each thunk asks the
//      SDK for a patched body; if the active OTA module ships one it renders the
//      WASM tree, else it falls through to the ORIGINAL `body` (a direct call to
//      `body` inside the replacement reaches the original — verified).
//
// The discovery matches the engine's lowering scope (top-level structs declaring
// `: View`), computed GLOBALLY across all sources so a body declared in a
// different file than its struct (or in an `extension`) is still handled.
//
// IDEMPOTENT + re-runnable: a body already `dynamic` is left as-is; the thunk
// file is regenerated wholesale.

import Foundation
import SwiftSyntax
import SwiftParser

public struct ThunkGenerator {
    public init() {}

    /// Cheap structural verification for a generated/edited Swift source: parse it and
    /// report whether SwiftSyntax saw NO error tokens (unbalanced braces, missing
    /// delimiters, etc.). It is a SYNTAX check, not a full type-check — but it catches the
    /// edit-corruption classes (a stray brace from a bad splice, an unterminated block) the
    /// backup/restore discipline guards against. Used by `patchcli prepare` to restore the
    /// original file if a same-file thunk append somehow produced unparseable source.
    public static func parses(_ source: String) -> Bool {
        let tree = Parser.parse(source: source)
        return !tree.hasError
    }

    /// The fixed property name each generated replacement uses (unique per type;
    /// each lives in its own `extension`, so reuse across types is fine).
    public static let replacementPropertyName = "__patchedBody"
    /// The per-view method exposing native slot closures for mixed views.
    public static let slotsMethodName = "__patchSlots"
    /// The per-view method exposing native DESIGN-SYSTEM TOKEN values (resolved
    /// `Color`/`Font` for `Theme.Colors.ink` / `Theme.Font.body(…)`), keyed by the
    /// content-stable id the shipped tree carries in `.hostToken(id)`/`.fontToken(id)`.
    public static let tokensMethodName = "__patchTokens"
    /// The per-view method exposing PER-ROW INDEXED NATIVE-ACTION SLOTS (a row count +
    /// per-row factory `(Int) -> AnyView` per `.indexedForEachSlot(id:…)` node), keyed by
    /// the content-stable id the shipped tree carries.
    public static let rowSlotsMethodName = "__patchRowSlots"
    /// The per-view method exposing NATIVE-ACTION SLOTS (a `() -> Void` action closure per
    /// `.actionSlotButton(id:…)` node — an actions-list Button whose action is a native method
    /// call), keyed by the content-stable id the shipped tree carries.
    public static let actionSlotsMethodName = "__patchActionSlots"
    /// The per-view method exposing NATIVE EFFECT-MODIFIER SLOTS (a `(AnyView) -> AnyView`
    /// effect-application closure per `.nativeEffectSlot(id)` modifier — an undispatchable
    /// `.task`/`.onAppear`/`.refreshable`/`.onSubmit`/gesture whose closure runs a native
    /// side-effect), keyed by the content-stable id the shipped tree carries.
    public static let effectSlotsMethodName = "__patchEffectSlots"
    /// The per-view method exposing CHILD-VIEW CALLBACK SLOTS (an `AnyView`-returning opaque closure
    /// per `.callbackSlot(id:…)` node — a child-view call whose `() -> Void` closure arg was
    /// dispatchable and lowers to WASM; the native thunk supplies the full child-view rendering with
    /// a stable forwarding closure replacing the original callback), keyed by the position-stable id.
    public static let callbackSlotsMethodName = "__patchCallbackSlots"
    /// The per-view CHILD-VIEW CALLBACK DISPATCHER method. The stable forwarding closure baked into
    /// each callback slot (`{ self.__patchDispatchCallback("<id>") }`) calls this; it routes the
    /// callback into the SDK's WASM dispatch for this view by the position-keyed id. Must match the
    /// literal name `SwiftUIEmitter.tryRecordCallbackSlot` bakes into the forwarder.
    public static let dispatchCallbackMethodName = "__patchDispatchCallback"
    /// The generated thunk file name (legacy SEPARATE-file mode).
    public static let thunkFileName = "PatchThunks.generated.swift"

    /// Markers delimiting the SAME-FILE generated thunk block appended to a view's own
    /// source file. Everything between them (inclusive) is regenerated wholesale on each
    /// `patchcli prepare` — stripped, then re-appended — so the block is idempotent and
    /// never duplicates. Placing the thunk in the SAME file as the view is what lets it
    /// reach the view's `private`/`fileprivate` members (Swift access control is
    /// file-scoped), which unblocks lowering a view whose body host-resolves a private
    /// member (e.g. a `private @Environment` read).
    public static let sameFileBeginMarker = "// PATCH-THUNKS-BEGIN (generated by `patchcli prepare` — DO NOT EDIT)"
    public static let sameFileEndMarker = "// PATCH-THUNKS-END"

    // MARK: - Do-not-edit banners (emitted inside the generated block / file headers)

    /// Multi-line `//`-comment banner emitted at the TOP of every same-file thunk block
    /// (between the BEGIN and END markers) AND at the top of every generated file.
    /// Uses the `@generated` machine token recognised by many editors, IDEs, and AI
    /// coding assistants as a signal that the content is autogenerated and must not be
    /// edited by hand or by tooling.
    static let doNotEditBanner = """
        // @generated
        // =========================================================================
        // AUTOGENERATED BY `patchcli prepare` — DO NOT EDIT THIS SECTION.
        //
        // Do NOT edit any code in this generated section — neither by hand NOR with
        // an AI coding assistant (Copilot, Cursor, Claude, etc.).
        //
        // Reason: this block is REGENERATED on every `patchcli prepare` run (which
        // also runs automatically inside `patchcli build`/`push`/`release`). Any
        // manual change here is SILENTLY OVERWRITTEN on the next prepare, and an
        // inconsistent thunk can break the OTA fingerprint (causing a MISMATCH that
        // blocks your release).
        //
        // To change a view's behaviour: edit the VIEW SOURCE FILE itself — never
        // this generated thunk. To remove this section entirely, delete the block
        // from BEGIN to END and re-run `patchcli prepare` (it recreates it).
        // =========================================================================
        """

    /// Single-line footer emitted just BEFORE the END marker so an editor scrolled
    /// to the bottom of a long block still sees the do-not-edit reminder.
    static let doNotEditFooter =
        "// @generated — END OF AUTOGENERATED SECTION. DO NOT EDIT ABOVE (regenerated by `patchcli prepare`)."

    public struct SourceFile {
        public let url: URL
        public let text: String
        public init(url: URL, text: String) { self.url = url; self.text = text }
    }

    /// Where a view's generated thunk lands in HYBRID placement (the new default).
    public enum Placement: Sendable, Equatable {
        /// The whole thunk goes into the dedicated generated folder's separate file —
        /// the developer's view file gets ONLY the one `dynamic` keyword. Chosen when the
        /// view's thunk needs no `private`/`fileprivate` access (the common case).
        case separateFile
        /// The view's HELPER methods (`__patchSlots()`/`__patchTokens()`/
        /// `__patchRowSlots()`) must stay in the view's own file because the thunk reads
        /// these `private`/`fileprivate` member(s) (Swift access control is file-scoped).
        /// The `@_dynamicReplacement` body-replacement still rides the separate file
        /// (it needs no private access) — minimal in-file footprint. The associated names
        /// are surfaced to the developer in an actionable comment.
        case sameFileBecausePrivate(members: [String])
    }

    public struct Result {
        /// Files whose source changed — `dynamic` inserted on a body AND/OR the same-file
        /// generated thunk block appended (in SAME-FILE mode). New text each.
        public var modifiedFiles: [(url: URL, text: String)]
        /// The generated thunk file contents (LEGACY separate-file mode — one extension
        /// per view). Empty in SAME-FILE mode (the thunks are appended to view files).
        public var thunkFileContents: String
        /// The view type names that got a thunk (sorted, deterministic).
        public var viewNames: [String]
        /// Total `dynamic` keywords inserted across all files this run.
        public var dynamicInsertions: Int
        /// True when the thunks were generated SAME-FILE (appended to each view's own
        /// source file) rather than into a separate `PatchThunks.generated.swift`.
        public var sameFile: Bool = false
        /// HYBRID placement only: the contents of the dedicated generated-folder file
        /// (`Patch/Generated/PatchThunks.generated.swift`) — carries the body-replacement
        /// extension for EVERY thunk view + the helper methods for the views that need no
        /// private access. Empty unless `hybrid` was true. The same-file factored blocks
        /// (helper methods + actionable comment) for private-member views ride
        /// `modifiedFiles` exactly like the legacy same-file path.
        public var generatedFileContents: String = ""
        /// HYBRID placement only: per-view placement decision (separate-file vs
        /// same-file-because-private, with the named members). Empty unless `hybrid`.
        public var placements: [String: Placement] = [:]
        /// True when the thunks were generated HYBRID (the new default): separate-file by
        /// default, same-file (factored + annotated) only for private-member views.
        public var hybrid: Bool = false
        /// HYBRID only: each thunk view → the source file that declares it. Lets a caller
        /// that had to RESTORE a file (its source edit broke parsing, dropping the spliced
        /// `dynamic` + same-file helpers) find which views to drop from the generated file —
        /// else a private-member view's `@_dynamicReplacement` orphans a now-non-`dynamic`
        /// body (and calls a now-missing `__patchSlots`), breaking the whole app build.
        public var viewDeclaringFile: [String: URL] = [:]
        /// HYBRID only: re-render `generatedFileContents` EXCLUDING the given view names
        /// (used to drop views whose declaring file had to be restored). nil outside hybrid.
        public var regenerateGeneratedFileExcluding: ((Set<String>) -> String)? = nil
    }

    // MARK: - Public API

    /// Prepare a whole project: discover View types, make their bodies `dynamic`,
    /// and generate the replacement thunks.
    ///
    /// `hybrid` (the new default `patchcli prepare` mode) makes placement a PER-VIEW
    /// decision: a view whose thunk needs NO `private`/`fileprivate` access has its WHOLE
    /// thunk emitted into a dedicated generated file (`generatedFileContents`) — the
    /// developer's view file gets ONLY the one `dynamic` keyword (no big appended block).
    /// A view whose thunk DOES read a private member keeps only its helper methods
    /// (`__patchSlots()`/`__patchTokens()`/`__patchRowSlots()`) in its own file (factored
    /// to the minimum that genuinely needs file-scoped access), annotated with an
    /// actionable comment naming the members; the `@_dynamicReplacement` body-replacement
    /// still rides the generated file. `placements` records each view's choice.
    ///
    /// `sameFile` (the legacy default, used when `hybrid == false`) appends each view's
    /// `@_dynamicReplacement(for: body)` extension + its `__patchSlots()`/`__patchTokens()`
    /// helpers to the SAME source file that declares the view, inside an idempotent
    /// BEGIN/END-marker block. This is what lets the thunk reach the view's own
    /// `private`/`fileprivate` members (Swift access control is file-scoped). When
    /// `sameFile == false` (and not `hybrid`), the OLDEST behavior: all thunks are emitted
    /// into one separate `PatchThunks.generated.swift` (`thunkFileContents`), where
    /// private members are unreachable.
    public func prepare(sources: [SourceFile], sameFile: Bool = true, hybrid: Bool = false) -> Result {
        // (1) GLOBAL discovery across all files. Collect View type names, count how
        // many top-level struct decls share each name (duplicates are unsafe to
        // thunk — `extension Name` would be ambiguous), and flag generic views with
        // a `where` clause (their extension members are constraint-fragile).
        var viewNames = Set<String>()
        var structDeclCounts: [String: Int] = [:]
        var genericWhereViews = Set<String>()
        // View types whose declaration is `private`/`fileprivate` — their thunk MUST be
        // same-file (a separate-file extension can't reach a file-scoped private type).
        var privateViewTypes = Set<String>()
        // Which file URL DECLARES each view's struct (for SAME-FILE placement — the
        // generated extension must live in the file holding the view's private members;
        // a struct's private members are file-scoped to where the struct is declared).
        var declaringFile: [String: URL] = [:]
        let parsed: [(file: SourceFile, tree: SourceFileSyntax)] = sources.map {
            ($0, Parser.parse(source: $0.text))
        }
        for (file, tree) in parsed {
            let d = Self.discover(in: tree)
            viewNames.formUnion(d.viewNames)
            for (name, n) in d.structCounts { structDeclCounts[name, default: 0] += n }
            genericWhereViews.formUnion(d.genericWhereViews)
            privateViewTypes.formUnion(d.privateViewTypes)
            for name in d.structDeclaredNames where declaringFile[name] == nil {
                declaringFile[name] = file.url
            }
        }

        // Thunk-ELIGIBLE views: a discovered View whose name is unique (exactly one
        // top-level struct decl) and not a generic-with-`where`. (A name reachable
        // only via `extension X: View` has 0 struct decls of that name and stays
        // eligible — there's no ambiguity.) Bodies of non-eligible views are left
        // untouched (no `dynamic`, no thunk) — they simply render native.
        let eligible = viewNames.filter {
            structDeclCounts[$0, default: 0] <= 1 && !genericWhereViews.contains($0)
        }

        // (2) Per file: insert `dynamic` before each eligible view body (skipping
        // bodies inside `#if` — their availability is config-dependent, so a thunk
        // referencing them could fail to compile in another configuration). The result
        // text per file (with `dynamic` spliced in, and any STALE generated block
        // stripped) is what a same-file block is later appended to.
        var fileText: [URL: String] = [:]            // URL → current working text
        var fileInsertions: [URL: Int] = [:]
        var viewsWithBody = Set<String>()
        for (file, tree) in parsed {
            let collector = BodyCollector(viewNames: eligible)
            collector.walk(tree)
            for hit in collector.hits { viewsWithBody.insert(hit.type) }
            // Always start from the file with any prior generated SAME-FILE block stripped
            // (idempotent regeneration — never duplicate). Then splice `dynamic`.
            let stripped = Self.stripSameFileBlock(from: file.text)
            let toInsert = collector.hits.filter { !$0.alreadyDynamic }.map { $0.offset }
            let withDynamic = toInsert.isEmpty
                ? stripped : Self.insertDynamic(into: stripped, atUTF8Offsets: toInsert)
            if stripped != file.text || !toInsert.isEmpty {
                fileText[file.url] = withDynamic
            }
            fileInsertions[file.url] = toInsert.count
        }
        let totalInsertions = fileInsertions.values.reduce(0, +)

        // (3) LOCK-STEP: a thunk only for a view whose `body` we actually located
        // (and therefore made `dynamic`) — `@_dynamicReplacement(for: body)` only
        // type-checks when `body` is `dynamic`. A view with no findable body gets
        // no thunk. (Pared down per-view below by the build-safety validation.)
        var thunkViews = eligible.intersection(viewsWithBody).sorted()

        // (4) MIXED-VIEW SLOTS + DESIGN-SYSTEM TOKENS: lower each thunk view's body
        // (same code path the engine uses at push) to find its SLOTABLE opaque leaves
        // AND its host tokens (`Theme.Colors.ink`, `Theme.Font.body(…)`), and gather the
        // native closures the thunk exposes. Both leaf ids and token ids are content-
        // stable, so they match the ids the engine emits into the shipped tree. We lower
        // with the SAME `sameFile` contract the engine uses, so a SAME-FILE thunk's slot/
        // token closures may reference the view's private members (they compile in-file).
        // HYBRID placement lowers each view assuming the SAME-FILE access contract
        // (`sameFileThunk: true`) — the slot/token/row closures are emitted assuming they
        // CAN reach private members. Whether a given view's thunk ACTUALLY needs that
        // access (→ same-file factoring) is decided separately below from a
        // `sameFileThunk: false` pass's `inaccessibleReadNames`. The legacy modes lower
        // with their own `sameFile` contract exactly as before.
        let loweringContract = hybrid ? true : sameFile
        let lowering = BodyLowering()
        // CROSS-FILE BUNDLE (bug R2-#27): the build (`BuildPipeline`) and the fingerprint
        // (`ProjectFingerprint`) both lower with `crossFile: crossFileBundle(sources:)` so a
        // view's reactive model + element structs (usually in OTHER files) resolve — which can
        // turn a `ForEach(store.players)` into an `indexedForEachSlot`/marshalled array, or
        // host-project a cross-file `model.title`. ThunkGenerator MUST lower with the SAME
        // bundle, or its slot/token/row-slot ID set diverges from the shipped tree (the thunk
        // exposes ids the build didn't emit, or omits ones it did) → a cross-file view DEMOTES
        // on device. Build it from the exact source set prepare already parsed.
        let crossFile = BodyLowering.crossFileBundle(sources: parsed.map { $0.file.text })
        var viewSlots: [String: [BodyLowering.OpaqueLeaf]] = [:]
        var viewTokens: [String: [BodyLowering.HostToken]] = [:]
        var viewRowSlots: [String: [BodyLowering.IndexedRowSlot]] = [:]
        var viewActionSlots: [String: [BodyLowering.ActionSlot]] = [:]
        var viewEffectSlots: [String: [BodyLowering.EffectSlot]] = [:]
        var viewCallbackSlots: [String: [BodyLowering.CallbackSlot]] = [:]
        // NATIVE-FAST-PATH: each view's body content hash, baked into its thunk's
        // `thunkBody(baselineHash:)` call. Computed by the SAME
        // `BodyLowering.viewBodyContentHash` (over the SAME `LoweredView` lowered with the
        // SAME `sameFileThunk`/`crossFile` contract as the build's manifest emitter), so for
        // an UNPATCHED view the baked baselineHash EQUALS the active module's manifest
        // bodyHash and the SDK renders native (zero WASM). A view that doesn't lower here
        // gets no entry → its thunk bakes `nil` → the SDK fail-safes that view to WASM.
        var viewBaselineHashes: [String: String] = [:]
        for (file, _) in parsed {
            for lv in lowering.lowerAllViews(source: file.text, sameFileThunk: loweringContract,
                                             crossFile: crossFile)
            where thunkViews.contains(lv.viewName) {
                let slotable = lv.opaqueLeaves.filter { $0.slotable && !$0.source.isEmpty }
                // De-dup by id across files (a view's body lives in one place).
                if viewSlots[lv.viewName] == nil { viewSlots[lv.viewName] = slotable }
                if viewTokens[lv.viewName] == nil { viewTokens[lv.viewName] = lv.hostTokens }
                if viewRowSlots[lv.viewName] == nil { viewRowSlots[lv.viewName] = lv.indexedRowSlots }
                if viewActionSlots[lv.viewName] == nil { viewActionSlots[lv.viewName] = lv.actionSlots }
                if viewEffectSlots[lv.viewName] == nil { viewEffectSlots[lv.viewName] = lv.effectSlots }
                if viewCallbackSlots[lv.viewName] == nil { viewCallbackSlots[lv.viewName] = lv.callbackSlots }
                if viewBaselineHashes[lv.viewName] == nil {
                    viewBaselineHashes[lv.viewName] = BodyLowering.viewBodyContentHash(lv)
                }
            }
        }

        // PER-VIEW BUILD-SAFETY VALIDATION (the meta-fix). A view's thunk must ALWAYS
        // compile. Render each view's full thunk (replacement + helper methods, the half
        // that embeds the slot `AnyView(<src>)` / token `.string(<src>)` sources) in
        // isolation and PARSE it. A view whose generated thunk does NOT parse (a corrupt
        // splice — a slotted `#if`-fragment leaving `#endif) }`, a statement source) is
        // DEMOTED: dropped from `thunkViews` so it ships NO thunk (renders native) while
        // EVERY other view still prepares. This is the per-view isolation that makes the
        // whole pipeline fail-safe — one bad view can never disable patching for the rest,
        // and a non-parsing thunk can never reach the developer's build.
        thunkViews = thunkViews.filter {
            Self.viewThunkValidates(name: $0, slots: viewSlots[$0] ?? [],
                                    tokens: viewTokens[$0] ?? [], rowSlots: viewRowSlots[$0] ?? [],
                                    actionSlots: viewActionSlots[$0] ?? [],
                                    effectSlots: viewEffectSlots[$0] ?? [],
                                    callbackSlots: viewCallbackSlots[$0] ?? [])
        }

        if hybrid {
            return Self.renderHybrid(
                parsed: parsed, fileText: fileText, declaringFile: declaringFile,
                thunkViews: thunkViews, privateViewTypes: privateViewTypes, lowering: lowering,
                crossFile: crossFile,
                viewSlots: viewSlots, viewTokens: viewTokens, viewRowSlots: viewRowSlots,
                viewActionSlots: viewActionSlots, viewEffectSlots: viewEffectSlots,
                viewCallbackSlots: viewCallbackSlots,
                baselineHashes: viewBaselineHashes,
                totalInsertions: totalInsertions)
        }

        if !sameFile {
            // LEGACY separate-file mode: one `PatchThunks.generated.swift` for all thunks.
            let imports = Self.collectImports(parsed.map { $0.tree })
            let thunkFile = Self.renderThunkFile(viewNames: thunkViews, slots: viewSlots,
                                                 tokens: viewTokens, rowSlots: viewRowSlots,
                                                 actionSlots: viewActionSlots,
                                                 effectSlots: viewEffectSlots,
                                                 callbackSlots: viewCallbackSlots,
                                                 baselineHashes: viewBaselineHashes,
                                                 extraImports: imports)
            let modified: [(url: URL, text: String)] = parsed.compactMap { (file, _) in
                fileText[file.url].map { (file.url, $0) }
            }
            return Result(modifiedFiles: modified, thunkFileContents: thunkFile,
                          viewNames: thunkViews, dynamicInsertions: totalInsertions,
                          sameFile: false)
        }

        // (5) SAME-FILE mode: append each view's thunk extension to the file that
        // DECLARES it (so the extension shares the file with the view's private members).
        // Group thunk views by their declaring file, render one BEGIN/END block per file.
        var viewsByFile: [URL: [String]] = [:]
        for view in thunkViews {
            // Place at the declaring file; fall back to a file whose text contains the
            // struct decl (covers an `extension X: View`-only conformance, rare).
            let target = declaringFile[view]
                ?? parsed.first { $0.file.text.contains("struct \(view)") }?.file.url
            guard let target else { continue }
            viewsByFile[target, default: []].append(view)
        }
        // Per-file imports the slot closures may need (third-party types in a view body).
        // Carry the WHOLE-project import union to every block (cheap, `#if canImport`-
        // guarded, de-duped against what the block already imports).
        let imports = Self.collectImports(parsed.map { $0.tree })
        for (url, views) in viewsByFile {
            // Base text = the file with `dynamic` spliced + any prior block stripped.
            let base = fileText[url] ?? Self.stripSameFileBlock(
                from: parsed.first { $0.file.url == url }?.file.text ?? "")
            let block = Self.renderSameFileBlock(viewNames: views.sorted(), slots: viewSlots,
                                                 tokens: viewTokens, rowSlots: viewRowSlots,
                                                 actionSlots: viewActionSlots,
                                                 effectSlots: viewEffectSlots,
                                                 callbackSlots: viewCallbackSlots,
                                                 baselineHashes: viewBaselineHashes,
                                                 extraImports: imports)
            let trimmed = base.hasSuffix("\n") ? base : base + "\n"
            fileText[url] = trimmed + "\n" + block
        }

        let modified: [(url: URL, text: String)] = parsed.compactMap { (file, _) in
            fileText[file.url].map { (file.url, $0) }
        }
        return Result(modifiedFiles: modified, thunkFileContents: "",
                      viewNames: thunkViews, dynamicInsertions: totalInsertions,
                      sameFile: true)
    }

    // MARK: - HYBRID placement

    /// Render the HYBRID result (the new default): decide per view whether its thunk can
    /// go SEPARATE-file (no private access needed) or must stay SAME-FILE (factored to the
    /// helper methods + an actionable annotation), then build (a) the dedicated
    /// generated-folder file and (b) the same-file factored blocks.
    ///
    /// The placement decision is BUILD-SAFE BY CONSTRUCTION: a view's helper methods can
    /// move to the separate generated file ONLY when NONE of the slot/token/row-slot SOURCES
    /// the thunk actually emits reference one of that view's own `private`/`fileprivate`
    /// members. We scan exactly the emitted source (lowered under the SAME same-file
    /// contract used to generate it), so a view routed separate is GUARANTEED to compile
    /// from a cross-file extension (Swift's file-scoped private can't bite it). A view whose
    /// emitted source DOES touch a private member keeps its helper methods co-located, and
    /// the referenced members are exactly the ones named in the developer-facing comment.
    /// (Cross-checked against the engine's `inaccessibleReadNames` for the diagnostic; the
    /// emitted-source scan is the authority — it never under-reports a real private read.)
    static func renderHybrid(
        parsed: [(file: SourceFile, tree: SourceFileSyntax)],
        fileText: [URL: String],
        declaringFile: [String: URL],
        thunkViews: [String],
        privateViewTypes: Set<String>,
        lowering: BodyLowering,
        crossFile: BodyLowering.CrossFileBundle,
        viewSlots: [String: [BodyLowering.OpaqueLeaf]],
        viewTokens: [String: [BodyLowering.HostToken]],
        viewRowSlots: [String: [BodyLowering.IndexedRowSlot]],
        viewActionSlots: [String: [BodyLowering.ActionSlot]],
        viewEffectSlots: [String: [BodyLowering.EffectSlot]] = [:],
        viewCallbackSlots: [String: [BodyLowering.CallbackSlot]] = [:],
        baselineHashes: [String: String] = [:],
        totalInsertions: Int
    ) -> Result {
        var fileText = fileText
        // A `private`/`fileprivate struct X: View` can't be EXTENDED from the separate
        // generated file (Swift file-scoped access), so its WHOLE thunk — the
        // `@_dynamicReplacement` body-replacement AND its helper methods — must live SAME-FILE
        // (its declaring file). It's excluded from the generated file's replacement set and
        // gets a full same-file thunk below. Build-safe: a private type can never produce a
        // cross-file `'X' is inaccessible due to 'private'` error.
        let sameFileFullViews = thunkViews.filter { privateViewTypes.contains($0) }.sorted()
        let sameFileFullSet = Set(sameFileFullViews)
        // (A) PER-VIEW PLACEMENT DECISION.
        // Each view's own `private`/`fileprivate` member names (bare + `$`-prefixed for a
        // wrapper projection), keyed by view name. A struct's privates are file-scoped to its
        // declaration — but they can be declared on the struct decl OR in a SEPARATE
        // `extension X { … }` in the same file (and EVERY member of a `private`/`fileprivate
        // extension X` is private regardless of its own modifier). Union both (bug R2-#28): a
        // separate-file thunk reading such an extension-declared private member would fail the
        // dev's build, so we must catch it here and force same-file placement.
        var privateNamesByView: [String: Set<String>] = [:]
        let thunkViewSet = Set(thunkViews)
        for (_, tree) in parsed {
            for stmt in tree.statements {
                if let s = stmt.item.as(StructDeclSyntax.self), thunkViewSet.contains(s.name.text) {
                    privateNamesByView[s.name.text, default: []]
                        .formUnion(BodyLowering.inaccessibleMemberNames(of: s))
                } else if let e = stmt.item.as(ExtensionDeclSyntax.self) {
                    let name = Self.baseTypeName(e.extendedType)
                    guard thunkViewSet.contains(name) else { continue }
                    privateNamesByView[name, default: []]
                        .formUnion(Self.inaccessibleExtensionMemberNames(e))
                }
            }
        }
        // The engine's own diagnostic (separate-file lowering) — used to enrich the named
        // members when our emitted-source scan needs no private access but the engine still
        // flagged a blocking private read (belt-and-suspenders for the annotation).
        var engineFlaggedPrivate: [String: [String]] = [:]
        for (file, _) in parsed {
            // Same cross-file bundle as the lowering pass above (and as the build) so the
            // separate-file `inaccessibleReadNames` diagnostic resolves cross-file reads the
            // same way (bug R2-#27).
            for lv in lowering.lowerAllViews(source: file.text, sameFileThunk: false,
                                             crossFile: crossFile)
            where thunkViews.contains(lv.viewName) && engineFlaggedPrivate[lv.viewName] == nil {
                engineFlaggedPrivate[lv.viewName] = lv.inaccessibleReadNames
            }
        }
        var placements: [String: Placement] = [:]
        var separateViews: [String] = []
        // view → the private member names that force same-file placement.
        var sameFileViews: [String: [String]] = [:]
        for view in thunkViews {
            // A private VIEW TYPE is forced fully same-file (handled below) — record its
            // placement for the diagnostic and skip the member-based decision.
            if sameFileFullSet.contains(view) {
                placements[view] = .sameFileBecausePrivate(members: ["<private view type>"])
                continue
            }
            let privates = privateNamesByView[view] ?? []
            // The slot/token/row-slot/action-slot SOURCES this view's thunk actually emits.
            var sources: [String] = []
            for leaf in viewSlots[view] ?? [] where !leaf.source.isEmpty { sources.append(leaf.source) }
            for tok in viewTokens[view] ?? [] { sources.append(tok.source) }
            for rs in viewRowSlots[view] ?? [] {
                sources.append(rs.collectionSource)
                if let c = rs.rowClosureText { sources.append(c) } else { sources.append(rs.rowSource) }
            }
            // An action-slot's closure body (`deleteSubscription(self.sel)`) runs over `self` in
            // the thunk — if it reads a `private` member, the thunk MUST be same-file (Swift
            // file-scoped access). (The emitter already proved it touches no body-local; a private
            // SELF read is allowed by the emitter's slotability check only because a SAME-FILE
            // thunk can reach it — so this placement scan is what makes that hold.)
            for asl in viewActionSlots[view] ?? [] { sources.append(asl.source) }
            // An effect-slot's re-application (`content.task { await self.load() }`) runs over `self`
            // in the thunk — if it reads a `private` member, the thunk MUST be same-file (Swift
            // file-scoped access), exactly like an action slot. (The emitter's slotability check
            // permits a private SELF read only because a SAME-FILE thunk reaches it — this scan is
            // what makes that hold.)
            for esl in viewEffectSlots[view] ?? [] { sources.append(esl.applySource) }
            // A callback-slot's slot source (the child-view call with stable forwarder) runs over
            // `self` in the thunk — if it reads a `private` member, the thunk MUST be same-file.
            for csl in viewCallbackSlots[view] ?? [] { sources.append(csl.slotSource) }
            // Which of the view's privates does the emitted source genuinely reference?
            let referenced = privates.isEmpty ? [] : sources.flatMap { src in
                BodyLowering.identifierReferences(in: src).intersection(privates)
            }
            // Union with the engine's flagged blocking reads (in case a private read lives
            // in a path our source list doesn't surface) — guarantees we never separate a
            // view that genuinely needs file-scoped access.
            var blocking = Set(referenced).union(engineFlaggedPrivate[view] ?? [])
            // Report bare names (drop the `$`-projection alias) for the developer comment.
            blocking = Set(blocking.map { $0.hasPrefix("$") ? String($0.dropFirst()) : $0 })
            if blocking.isEmpty {
                placements[view] = .separateFile
                separateViews.append(view)
            } else {
                let members = blocking.sorted()
                placements[view] = .sameFileBecausePrivate(members: members)
                sameFileViews[view] = members
            }
        }

        let imports = Self.collectImports(parsed.map { $0.tree })

        // (B) THE DEDICATED GENERATED FILE. The body-replacement extension for every thunk
        // view EXCEPT private view types (those can't be extended cross-file) + the
        // helper-methods extension for the separate-file views. Same-file views' helper
        // methods are emitted into their own file (C); private view types get a FULL same-
        // file thunk (D). Empty when there are no separate/same-file-member thunk views.
        let generatedReplacementViews = thunkViews.filter { !sameFileFullSet.contains($0) }
        let generatedFile = generatedReplacementViews.isEmpty ? "" : Self.renderGeneratedFolderFile(
            replacementViews: generatedReplacementViews,
            methodViews: separateViews.sorted(),
            slots: viewSlots, tokens: viewTokens, rowSlots: viewRowSlots,
            actionSlots: viewActionSlots, effectSlots: viewEffectSlots,
            callbackSlots: viewCallbackSlots,
            baselineHashes: baselineHashes,
            extraImports: imports)

        // (C+D) SAME-FILE BLOCKS, ONE per declaring file (a file may declare several views):
        //   (C) FACTORED helper methods (+ an actionable annotation) for private-MEMBER
        //       views — their `@_dynamicReplacement` rides the generated file;
        //   (D) the FULL thunk (replacement + helper methods) for private VIEW TYPES — they
        //       can't be extended cross-file, so even the replacement must be co-located.
        // Both go into the SAME idempotent BEGIN/END block per file (never two markers).
        var factoredByFile: [URL: [String]] = [:]
        for (view, _) in sameFileViews {
            let target = declaringFile[view]
                ?? parsed.first { $0.file.text.contains("struct \(view)") }?.file.url
            guard let target else { continue }
            factoredByFile[target, default: []].append(view)
        }
        var fullByFile: [URL: [String]] = [:]
        for view in sameFileFullViews {
            let target = declaringFile[view]
                ?? parsed.first { $0.file.text.contains("struct \(view)") }?.file.url
            guard let target else { continue }
            fullByFile[target, default: []].append(view)
        }
        let sameFileFiles = Set(factoredByFile.keys).union(fullByFile.keys)
        for url in sameFileFiles {
            let base = fileText[url] ?? Self.stripSameFileBlock(
                from: parsed.first { $0.file.url == url }?.file.text ?? "")
            let block = Self.renderSameFileCombinedBlock(
                factoredViews: (factoredByFile[url] ?? []).sorted(),
                fullViews: (fullByFile[url] ?? []).sorted(),
                privateMembers: sameFileViews,
                slots: viewSlots, tokens: viewTokens, rowSlots: viewRowSlots,
                actionSlots: viewActionSlots, effectSlots: viewEffectSlots,
                callbackSlots: viewCallbackSlots,
                baselineHashes: baselineHashes,
                extraImports: imports)
            let trimmed = base.hasSuffix("\n") ? base : base + "\n"
            fileText[url] = trimmed + "\n" + block
        }

        let modified: [(url: URL, text: String)] = parsed.compactMap { (file, _) in
            fileText[file.url].map { (file.url, $0) }
        }
        return Result(modifiedFiles: modified, thunkFileContents: "",
                      viewNames: thunkViews, dynamicInsertions: totalInsertions,
                      sameFile: false,
                      generatedFileContents: generatedFile,
                      placements: placements, hybrid: true,
                      viewDeclaringFile: declaringFile,
                      regenerateGeneratedFileExcluding: { excluded in
                          let reps = generatedReplacementViews.filter { !excluded.contains($0) }
                          return reps.isEmpty ? "" : Self.renderGeneratedFolderFile(
                              replacementViews: reps,
                              methodViews: separateViews.sorted().filter { !excluded.contains($0) },
                              slots: viewSlots, tokens: viewTokens, rowSlots: viewRowSlots,
                              actionSlots: viewActionSlots, effectSlots: viewEffectSlots,
                              callbackSlots: viewCallbackSlots,
                              baselineHashes: baselineHashes,
                              extraImports: imports)
                      })
    }

    /// Render the dedicated generated-folder file: the `@_dynamicReplacement` body-
    /// replacement extension for every `replacementViews` + the helper-methods extension
    /// for every `methodViews`. (In hybrid mode `replacementViews` = all thunk views and
    /// `methodViews` = the separate-file subset; same-file views' methods live in their
    /// own file with an annotation, but their replacement still rides here.)
    static func renderGeneratedFolderFile(
        replacementViews: [String],
        methodViews: [String],
        slots: [String: [BodyLowering.OpaqueLeaf]],
        tokens: [String: [BodyLowering.HostToken]],
        rowSlots: [String: [BodyLowering.IndexedRowSlot]],
        actionSlots: [String: [BodyLowering.ActionSlot]] = [:],
        effectSlots: [String: [BodyLowering.EffectSlot]] = [:],
        callbackSlots: [String: [BodyLowering.CallbackSlot]] = [:],
        baselineHashes: [String: String] = [:],
        extraImports: [String]
    ) -> String {
        var out = """
        // PatchThunks.generated.swift — GENERATED BY `patchcli prepare`. DO NOT EDIT.
        // @generated
        // =========================================================================
        // AUTOGENERATED FILE — DO NOT EDIT BY HAND OR WITH AN AI CODING ASSISTANT.
        //
        // This file is regenerated on every `patchcli prepare` run (which also runs
        // automatically inside `patchcli build`/`push`/`release`). Any manual edit
        // here is SILENTLY OVERWRITTEN on the next prepare. An inconsistent thunk
        // can break the OTA fingerprint (causing a MISMATCH that blocks your release).
        //
        // To change a view's behaviour: edit the VIEW SOURCE FILE itself — never
        // this generated thunk. To regenerate from scratch, delete this file and
        // run `patchcli prepare`.
        // =========================================================================
        // This file lives in a dedicated, gitignored `Patch/Generated/` folder so the
        // generated patch thunks never clutter YOUR source. Your view files get only the
        // one `dynamic` keyword on `var body` (Swift requires `dynamic` on the
        // declaration — it can't be added from an extension). Everything else is here.
        //
        // For each SwiftUI View in this target: an `@_dynamicReplacement(for: body)` that
        // routes the body through the Patch OTA renderer when a patch is active, else the
        // original compiled `body`. Most views also have their `__patchSlots()`/
        // `__patchTokens()`/`__patchRowSlots()` helpers here. A view whose thunk must read
        // a `private`/`fileprivate` member keeps ONLY those helper methods in its own file
        // (Swift access control is file-scoped) — its replacement still rides this file.
        //
        // Regenerated wholesale on every `patchcli prepare`. Safe to delete this whole
        // folder — `patchcli prepare` recreates it (and re-inserts the `dynamic` keywords).

        #if canImport(SwiftUI)
        import SwiftUI
        import PatchSDK
        import PatchSwiftUI
        import PatchRender

        """
        for imp in extraImports {
            out += "#if canImport(\(imp))\nimport \(imp)\n#endif\n"
        }
        // The body-replacement extensions (every view).
        for name in replacementViews {
            out += "\n" + Self.renderReplacementExtension(name: name, baselineHash: baselineHashes[name])
        }
        // The helper-methods extensions (separate-file views only).
        for name in methodViews {
            out += "\n" + Self.renderMethodsExtension(
                name: name, slots: slots[name] ?? [],
                tokens: tokens[name] ?? [], rowSlots: rowSlots[name] ?? [],
                actionSlots: actionSlots[name] ?? [], effectSlots: effectSlots[name] ?? [],
                callbackSlots: callbackSlots[name] ?? [])
        }
        out += "#endif\n"
        return out
    }

    /// Render the SAME-FILE FACTORED block for HYBRID private-member views: ONLY the
    /// helper-methods extension(s) (the `@_dynamicReplacement` body-replacement rides the
    /// separate generated file), preceded by an actionable comment that explains WHY the
    /// block is in the developer's file and HOW to remove it — naming the exact
    /// `private`/`fileprivate` members forcing it. BEGIN/END-marked + regenerated
    /// wholesale (idempotent; same markers as the legacy same-file path so re-running
    /// strips cleanly).
    static func renderSameFileFactoredBlock(
        views: [String],
        privateMembers: [String: [String]],
        slots: [String: [BodyLowering.OpaqueLeaf]],
        tokens: [String: [BodyLowering.HostToken]],
        rowSlots: [String: [BodyLowering.IndexedRowSlot]],
        actionSlots: [String: [BodyLowering.ActionSlot]] = [:],
        effectSlots: [String: [BodyLowering.EffectSlot]] = [:],
        callbackSlots: [String: [BodyLowering.CallbackSlot]] = [:],
        baselineHashes: [String: String] = [:],
        extraImports: [String]
    ) -> String {
        renderSameFileCombinedBlock(
            factoredViews: views, fullViews: [], privateMembers: privateMembers,
            slots: slots, tokens: tokens, rowSlots: rowSlots, actionSlots: actionSlots,
            effectSlots: effectSlots, callbackSlots: callbackSlots,
            baselineHashes: baselineHashes,
            extraImports: extraImports)
    }

    /// Render ONE same-file BEGIN/END block for a file, carrying BOTH:
    ///   * `factoredViews` — private-MEMBER views: only their helper-methods extension
    ///     (their `@_dynamicReplacement` rides the separate generated file), with an
    ///     actionable annotation naming the members;
    ///   * `fullViews` — private VIEW TYPES: their FULL thunk (replacement + helper methods),
    ///     because a `private`/`fileprivate struct X: View` can't be extended cross-file.
    /// Both kinds need the SAME file (Swift access control is file-scoped) and share one
    /// idempotent block so re-running `patchcli prepare` strips + regenerates exactly one.
    static func renderSameFileCombinedBlock(
        factoredViews: [String],
        fullViews: [String],
        privateMembers: [String: [String]],
        slots: [String: [BodyLowering.OpaqueLeaf]],
        tokens: [String: [BodyLowering.HostToken]],
        rowSlots: [String: [BodyLowering.IndexedRowSlot]],
        actionSlots: [String: [BodyLowering.ActionSlot]] = [:],
        effectSlots: [String: [BodyLowering.EffectSlot]] = [:],
        callbackSlots: [String: [BodyLowering.CallbackSlot]] = [:],
        baselineHashes: [String: String] = [:],
        extraImports: [String]
    ) -> String {
        var out = Self.sameFileBeginMarker + "\n"
        out += Self.doNotEditBanner + "\n"
        out += """
        // Patch kept the patch-thunk code for the view(s) below in YOUR file because each is
        // declared `private`/`fileprivate` (or its body host-resolves a `private` member) —
        // and Swift access control is file-scoped, so a thunk in the separate
        // `Patch/Generated/` folder cannot reach it. Only the minimum that genuinely needs
        // file-scoped access is here.

        """
        for name in factoredViews {
            let members = (privateMembers[name] ?? []).joined(separator: ", ")
            out += """
            // \(name): helper methods kept here — its body reads private member(s): \(members).
            //   To move this into Patch/Generated/, make those member(s) `internal` (drop
            //   `private`/`fileprivate`) and re-run `patchcli prepare`.

            """
        }
        for name in fullViews {
            out += """
            // \(name): full thunk kept here — `\(name)` is a `private`/`fileprivate` View type
            //   (can't be extended from another file). To move it into Patch/Generated/, make
            //   `\(name)` `internal` (drop `private`/`fileprivate`) and re-run `patchcli prepare`.

            """
        }
        out += """
        #if canImport(SwiftUI)
        import SwiftUI
        import PatchSDK
        import PatchSwiftUI
        import PatchRender

        """
        for imp in extraImports {
            out += "#if canImport(\(imp))\nimport \(imp)\n#endif\n"
        }
        // Private-MEMBER views: helper methods only (replacement rides the generated file).
        for name in factoredViews {
            out += "\n" + Self.renderMethodsExtension(
                name: name, slots: slots[name] ?? [],
                tokens: tokens[name] ?? [], rowSlots: rowSlots[name] ?? [],
                actionSlots: actionSlots[name] ?? [], effectSlots: effectSlots[name] ?? [],
                callbackSlots: callbackSlots[name] ?? [])
        }
        // Private VIEW TYPES: the FULL thunk (replacement + helper methods) — co-located.
        for name in fullViews {
            out += "\n" + Self.renderExtension(
                name: name, slots: slots[name] ?? [],
                tokens: tokens[name] ?? [], rowSlots: rowSlots[name] ?? [],
                actionSlots: actionSlots[name] ?? [], effectSlots: effectSlots[name] ?? [],
                callbackSlots: callbackSlots[name] ?? [],
                baselineHash: baselineHashes[name])
        }
        out += "#endif\n"
        out += Self.doNotEditFooter + "\n"
        out += Self.sameFileEndMarker + "\n"
        return out
    }

    /// The union of `import` MODULE names across the view files, minus the ones the thunk
    /// file always declares (SwiftUI / PatchSDK / PatchSwiftUI / PatchRender). These let a
    /// slot closure / token source reference a third-party type used in a view body.
    ///
    /// Bug R2-#89: we must NOT drop SCOPED (`import struct DesignKit.Brand`) or SUBMODULE
    /// (`import os.log`) imports — a slotted leaf / token source that references `Brand` /
    /// `OSLog` then compiles in the original file but NOT in the separate generated file
    /// (`cannot find 'Brand' in scope`) → dev build fails. We carry the TOP-LEVEL module of
    /// any such import (a `#if canImport(Module)`-guarded plain `import Module` re-exposes the
    /// scoped type; a submodule path keeps its full form). `@_exported`/`@testable`-attributed
    /// imports are still skipped (their semantics don't survive a re-emit and aren't needed
    /// for type lookup).
    static func collectImports(_ trees: [SourceFileSyntax]) -> [String] {
        var seen = Set<String>(["SwiftUI", "PatchSDK", "PatchSwiftUI", "PatchRender"])
        var out: [String] = []
        for tree in trees {
            for stmt in tree.statements {
                guard let imp = stmt.item.as(ImportDeclSyntax.self) else { continue }
                // Skip attributed imports (`@_exported`/`@testable`) — keep every plain or
                // SCOPED (`import struct …`) import.
                guard imp.attributes.isEmpty else { continue }
                let path = imp.path.trimmedDescription
                guard !path.isEmpty else { continue }
                // A SCOPED import (`import struct DesignKit.Brand`) names the symbol's full
                // path; the MODULE is the FIRST path component (`DesignKit`). A plain
                // submodule import (`import os.log`) keeps its whole path. A plain top-level
                // import (`import Foundation`) uses the path verbatim.
                let module: String
                if imp.importKindSpecifier != nil {
                    // Scoped: `struct DesignKit.Brand` → module `DesignKit`.
                    module = path.split(separator: ".").first.map(String.init) ?? path
                } else {
                    // Plain (possibly a submodule like `os.log`) — keep the full path so the
                    // submodule resolves; a `canImport(os.log)` guard is valid.
                    module = path
                }
                guard !module.isEmpty, seen.insert(module).inserted else { continue }
                out.append(module)
            }
        }
        return out.sorted()
    }

    // MARK: - View discovery (matches the engine's lowering scope)

    struct Discovery {
        var viewNames: Set<String> = []
        var structCounts: [String: Int] = [:]
        var genericWhereViews: Set<String> = []
        /// View names whose STRUCT is declared (not just `extension`-conformed) in this
        /// file — i.e. the file that holds the view's `private`/`fileprivate` members, so
        /// the SAME-FILE thunk extension must go HERE.
        var structDeclaredNames: Set<String> = []
        /// View names whose STRUCT DECLARATION is itself `private`/`fileprivate`. Swift
        /// access control is file-scoped, so a `private struct X: View` CANNOT be extended
        /// from the separate generated file (`'X' is inaccessible due to 'private'`). Its
        /// thunk MUST live SAME-FILE (the declaring file) — including the
        /// `@_dynamicReplacement` body-replacement, which the hybrid path otherwise always
        /// routes separate.
        var privateViewTypes: Set<String> = []
    }

    /// Discover top-level View types in one file: structs declaring `: View`, plus
    /// types a top-level `extension T: View` retroactively conforms. Also counts
    /// top-level struct decls per name (duplicate detection) and flags generic
    /// views carrying a `where` clause.
    static func discover(in tree: SourceFileSyntax) -> Discovery {
        var d = Discovery()
        for stmt in tree.statements {
            if let s = stmt.item.as(StructDeclSyntax.self) {
                d.structCounts[s.name.text, default: 0] += 1
                if declaresViewConformance(s.inheritanceClause) {
                    d.viewNames.insert(s.name.text)
                    d.structDeclaredNames.insert(s.name.text)
                    if s.genericParameterClause != nil, s.genericWhereClause != nil {
                        d.genericWhereViews.insert(s.name.text)
                    }
                    // A `private`/`fileprivate struct X: View` can't be extended cross-file,
                    // so its thunk must be SAME-FILE — flag it.
                    if s.modifiers.contains(where: {
                        $0.name.tokenKind == .keyword(.private)
                            || $0.name.tokenKind == .keyword(.fileprivate)
                    }) {
                        d.privateViewTypes.insert(s.name.text)
                    }
                }
            } else if let e = stmt.item.as(ExtensionDeclSyntax.self),
                      declaresViewConformance(e.inheritanceClause) {
                let name = Self.baseTypeName(e.extendedType)
                d.viewNames.insert(name)
                if e.genericWhereClause != nil { d.genericWhereViews.insert(name) }
            }
        }
        return d
    }

    /// Top-level View type names in a file (convenience for tests).
    static func topLevelViewNames(in tree: SourceFileSyntax) -> Set<String> {
        discover(in: tree).viewNames
    }

    /// The `private`/`fileprivate` member names declared in an `extension X { … }` (bare +
    /// `$`-prefixed for a wrapper projection). A member is inaccessible cross-file when it is
    /// itself marked `private`/`fileprivate`, OR when the WHOLE extension is — a
    /// `private extension X { var foo … }` makes `foo` private even though `foo` carries no
    /// modifier. Mirrors `BodyLowering.inaccessibleMemberNames(of:)` for the struct decl;
    /// together they form the complete same-file private-member set of a type (bug R2-#28).
    static func inaccessibleExtensionMemberNames(_ e: ExtensionDeclSyntax) -> Set<String> {
        let extensionIsInaccessible = e.modifiers.contains {
            $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)
        }
        func memberIsInaccessible(_ modifiers: DeclModifierListSyntax) -> Bool {
            extensionIsInaccessible || modifiers.contains {
                $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)
            }
        }
        var out = Set<String>()
        for member in e.memberBlock.members {
            if let v = member.decl.as(VariableDeclSyntax.self), memberIsInaccessible(v.modifiers) {
                for b in v.bindings {
                    let name = b.pattern.trimmedDescription
                    guard !name.isEmpty else { continue }
                    out.insert(name); out.insert("$" + name)
                }
            } else if let f = member.decl.as(FunctionDeclSyntax.self), memberIsInaccessible(f.modifiers) {
                out.insert(f.name.text)
            }
        }
        return out
    }

    static func declaresViewConformance(_ inh: InheritanceClauseSyntax?) -> Bool {
        guard let inh else { return false }
        return inh.inheritedTypes.contains { $0.type.trimmedDescription == "View" }
    }

    /// "Outer.Inner" → "Inner"? No — we keep the FULL path for the extension target,
    /// but match against struct names by the LAST component. For top-level structs
    /// the name has no dots, so this is the identity for the common case.
    static func baseTypeName(_ type: TypeSyntax) -> String {
        let desc = type.trimmedDescription
        // Strip generic args: `Row<Int>` → `Row`.
        let noGenerics = desc.split(separator: "<", maxSplits: 1).first.map(String.init) ?? desc
        return noGenerics
    }

    // MARK: - Precise `dynamic` insertion

    /// Insert "dynamic " at each given UTF-8 offset (the position of a `var`
    /// keyword). Offsets are sorted DESCENDING so earlier ones stay valid as we
    /// splice from the end backward.
    static func insertDynamic(into source: String, atUTF8Offsets offsets: [Int]) -> String {
        var bytes = Array(source.utf8)
        let token = Array("dynamic ".utf8)
        for off in offsets.sorted(by: >) {
            guard off >= 0, off <= bytes.count else { continue }
            bytes.insert(contentsOf: token, at: off)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Per-view build-safety validation

    /// Validate that ONE view's generated thunk is BUILD-SAFE — the per-view isolation gate.
    /// Renders the view's full thunk (the `@_dynamicReplacement` body-replacement + its
    /// `__patchSlots()`/`__patchTokens()`/`__patchRowSlots()` helpers — the half that embeds
    /// the slot `AnyView(<source>)` and token `.string(<source>)`/`.color(<source>)` sources
    /// where a corrupt capture would live) and PARSES it. A thunk that does NOT parse (a
    /// `#if`-fragment slot leaving `#endif) }`, a captured statement, an unbalanced splice)
    /// fails this gate and the caller DEMOTES just that view — never the whole project.
    ///
    /// The parse check is always-on (cheap, ~ms, catches every SYNTAX corruption class). A
    /// deeper host `swiftc -typecheck` of each view's thunk is gated behind
    /// `PATCH_THUNK_TYPECHECK=1` (it needs the app's own types in scope to be meaningful and
    /// is too slow for every prepare) — the type-class breaks are already closed up-front by
    /// the emitter's type-provability gates, with the compile-the-thunk harness as the net.
    static func viewThunkValidates(name: String,
                                   slots: [BodyLowering.OpaqueLeaf],
                                   tokens: [BodyLowering.HostToken],
                                   rowSlots: [BodyLowering.IndexedRowSlot],
                                   actionSlots: [BodyLowering.ActionSlot] = [],
                                   effectSlots: [BodyLowering.EffectSlot] = [],
                                   callbackSlots: [BodyLowering.CallbackSlot] = []) -> Bool {
        // Wrap the thunk in the same `#if canImport(SwiftUI)` + imports a real generated file
        // uses, plus a stub of the view type, so the extension parses in isolation. We only
        // assert it PARSES (no error tokens) — the type surface is supplied by the real app
        // at build; the harness/compile gates handle types.
        let thunk = renderExtension(name: name, slots: slots, tokens: tokens, rowSlots: rowSlots,
                                    actionSlots: actionSlots, effectSlots: effectSlots,
                                    callbackSlots: callbackSlots)
        let standalone = """
        import SwiftUI
        struct \(name) {}
        \(thunk)
        """
        guard Self.parses(standalone) else { return false }
        return true
    }

    // MARK: - Thunk file rendering

    static func renderThunkFile(viewNames: [String],
                                slots: [String: [BodyLowering.OpaqueLeaf]] = [:],
                                tokens: [String: [BodyLowering.HostToken]] = [:],
                                rowSlots: [String: [BodyLowering.IndexedRowSlot]] = [:],
                                actionSlots: [String: [BodyLowering.ActionSlot]] = [:],
                                effectSlots: [String: [BodyLowering.EffectSlot]] = [:],
                                callbackSlots: [String: [BodyLowering.CallbackSlot]] = [:],
                                baselineHashes: [String: String] = [:],
                                extraImports: [String] = []) -> String {
        var out = """
        // PatchThunks.generated.swift — GENERATED BY `patchcli prepare`. DO NOT EDIT.
        // @generated
        // =========================================================================
        // AUTOGENERATED FILE — DO NOT EDIT BY HAND OR WITH AN AI CODING ASSISTANT.
        //
        // This file is regenerated on every `patchcli prepare` run (which also runs
        // automatically inside `patchcli build`/`push`/`release`). Any manual edit
        // here is SILENTLY OVERWRITTEN on the next prepare. An inconsistent thunk
        // can break the OTA fingerprint (causing a MISMATCH that blocks your release).
        //
        // To change a view's behaviour: edit the VIEW SOURCE FILE itself — never
        // this generated thunk. To regenerate from scratch, delete this file and
        // run `patchcli prepare`.
        // =========================================================================
        // One `@_dynamicReplacement(for: body)` per SwiftUI View in this target. Each
        // thunk routes the view's body through the Patch OTA renderer when a patch is
        // active, and falls through to the original compiled `body` otherwise. This is
        // what makes view bodies patchable over-the-air with no changes to the views.
        //
        // For MIXED views (bodies that are only partly lowerable), each thunk also
        // exposes `__patchSlots()` — native closures that render the view's
        // non-lowerable leaves (custom child views, unsupported constructs), keyed by
        // the content-stable id the shipped tree carries. The renderer fills these in
        // so the lowered parts ride WASM (patchable) while the native leaves render
        // from this compiled-in code. (If a patch changes a native leaf, its id no
        // longer matches a slot and the SDK renders that view fully native — safe.)
        //
        // It ALSO exposes `__patchTokens()` — the view's DESIGN-SYSTEM TOKEN values
        // (`Theme.Colors.ink`, `Theme.Font.body(…)`) evaluated NATIVELY into a `Color`/
        // `Font`, keyed by the content-stable id the tree carries in `.hostToken(id)`/
        // `.fontToken(id)`. This is what lets token-using modifiers lower: the modifier
        // rides WASM (patchable) while its concrete color/font value comes from this
        // compiled-in app code (an OTA patch can re-select among these enumerated tokens
        // but can't invent a new native one — the App-Store wall).
        //
        // Regenerated wholesale on every `patchcli prepare`. Safe to delete — running
        // `patchcli prepare` recreates it (and re-inserts the `dynamic` keywords).

        #if canImport(SwiftUI)
        import SwiftUI
        import PatchSDK
        import PatchSwiftUI
        import PatchRender

        """
        for imp in extraImports {
            out += "#if canImport(\(imp))\nimport \(imp)\n#endif\n"
        }

        for name in viewNames {
            out += "\n" + renderExtension(name: name, slots: slots[name] ?? [],
                                          tokens: tokens[name] ?? [], rowSlots: rowSlots[name] ?? [],
                                          actionSlots: actionSlots[name] ?? [],
                                          effectSlots: effectSlots[name] ?? [],
                                          callbackSlots: callbackSlots[name] ?? [],
                                          baselineHash: baselineHashes[name])
        }

        out += "#endif\n"
        return out
    }

    /// Render ONE view's `@_dynamicReplacement(for: body)` extension + its
    /// `__patchSlots()`/`__patchTokens()` helpers. The body is IDENTICAL regardless of
    /// where the extension is placed — `self`-relative member names resolve in the
    /// view's own context. In SAME-FILE placement (the extension lives in the view's own
    /// file), those self-relative references include the view's `private`/`fileprivate`
    /// members, so a slot/token closure that reads one COMPILES — which is exactly what
    /// lets such a view lower.
    static func renderExtension(name: String,
                                slots: [BodyLowering.OpaqueLeaf],
                                tokens: [BodyLowering.HostToken],
                                rowSlots: [BodyLowering.IndexedRowSlot] = [],
                                actionSlots: [BodyLowering.ActionSlot] = [],
                                effectSlots: [BodyLowering.EffectSlot] = [],
                                callbackSlots: [BodyLowering.CallbackSlot] = [],
                                baselineHash: String? = nil) -> String {
        // The full thunk = the `@_dynamicReplacement` body-replacement extension +
        // the `__patchSlots()`/`__patchTokens()`/`__patchRowSlots()` helper-methods
        // extension. The two are independent extensions (Swift allows any number per
        // type), which is what lets the HYBRID placement split them: the replacement
        // never touches private members (it just forwards `self` + method references),
        // so it can always live in the SEPARATE generated file; only the helper methods
        // (which evaluate slot/token/row closures over `self`, possibly reading a
        // `private` member) must be co-located with the view. Same-file/legacy callers
        // emit both halves together (identical output to before).
        renderReplacementExtension(name: name, baselineHash: baselineHash)
            + renderMethodsExtension(name: name, slots: slots, tokens: tokens, rowSlots: rowSlots,
                                     actionSlots: actionSlots, effectSlots: effectSlots,
                                     callbackSlots: callbackSlots)
    }

    /// The `@_dynamicReplacement(for: body)` body-replacement extension for ONE view.
    /// It reads NO private member — it forwards `self` and references the view's
    /// `__patchSlots()`/`__patchTokens()`/`__patchRowSlots()` methods (which are
    /// `internal`, so callable cross-file within the module). That's why this half can
    /// always be emitted into the SEPARATE generated file even for a view whose helper
    /// methods must stay same-file (HYBRID factoring — minimal in-file footprint).
    static func renderReplacementExtension(name: String, baselineHash: String? = nil) -> String {
        // NATIVE-FAST-PATH: bake the view's body content hash as `baselineHash:`. The SDK
        // compares it to the active module's manifest `bodyHash`; an EQUAL hash means this
        // view is byte-identical to the build's shipped baseline (no OTA patch touched it),
        // so `thunkBody` returns nil and the ORIGINAL native body renders with ZERO WASM.
        // `nil` (a view we couldn't hash) omits the argument → the OLD always-route behavior
        // (fail-safe: the view runs WASM, never a false native that drops a real patch).
        let baselineArg = baselineHash.map { " baselineHash: \"\($0)\"," } ?? ""
        return """
        extension \(name) {
            @_dynamicReplacement(for: body)
            @MainActor @ViewBuilder
            var \(Self.replacementPropertyName): some View {
                if let __patched = Patch.shared.thunkBody(
                    typeName: "\(name)",\(baselineArg) instance: self,
                    slots: { self.__patchSlots() }, tokens: { self.__patchTokens() },
                    rowSlots: { self.__patchRowSlots() },
                    actionSlots: { self.__patchActionSlots() },
                    effectSlots: { self.__patchEffectSlots() },
                    callbackSlots: { self.__patchCallbackSlots() }) {
                    __patched
                } else {
                    body
                }
            }
        }

        """
    }

    /// The helper-methods extension (`__patchSlots()`/`__patchTokens()`/
    /// `__patchRowSlots()`) for ONE view. THIS is the half whose closures may read the
    /// view's `private`/`fileprivate` members (a slotted private-binding leaf, a token
    /// over a private computed property, a private body-local collection), so in HYBRID
    /// placement it goes same-file IFF the view needs that access; otherwise it rides the
    /// separate generated file alongside the replacement. The method bodies are byte-for-
    /// byte what `renderExtension` always emitted.
    static func renderMethodsExtension(name: String,
                                       slots: [BodyLowering.OpaqueLeaf],
                                       tokens: [BodyLowering.HostToken],
                                       rowSlots: [BodyLowering.IndexedRowSlot] = [],
                                       actionSlots: [BodyLowering.ActionSlot] = [],
                                       effectSlots: [BodyLowering.EffectSlot] = [],
                                       callbackSlots: [BodyLowering.CallbackSlot] = []) -> String {
        var out = """
        extension \(name) {
            /// Native renderers for this view's non-lowerable leaves, keyed by the
            /// shipped tree's opaque-slot id. Each is a FACTORY `([String]) -> AnyView`:
            /// a PARAMETERIZED leaf (a slotted custom view with lifted string-literal
            /// args) substitutes the runtime-supplied `a[k]` into its template, so an
            /// OTA patch that only edited a string ships through here (the id is
            /// structural/stable, the new value rides WASM in `BodyEmission.slotArgs`).
            /// A plain leaf ignores its args. Empty for a fully-lowered view.
            @MainActor func \(Self.slotsMethodName)() -> [String: ([String]) -> AnyView] {

        """
        if slots.isEmpty {
            out += "        [:]\n    }\n"
        } else {
            out += "        var __s: [String: ([String]) -> AnyView] = [:]\n"
            for leaf in slots {
                // The leaf source is emitted RAW (real Swift, captured over self);
                // self-member names resolve in this @MainActor method on the view.
                if leaf.stringArgs.isEmpty {
                    // Plain (non-parameterized) leaf — the source is rendered verbatim,
                    // ignoring the args.
                    out += "        __s[\"\(leaf.id)\"] = { (_: [String]) in AnyView(\(leaf.source)) }\n"
                } else {
                    // Parameterized leaf — `leaf.source` is the TEMPLATE with each lifted
                    // string-literal arg replaced by a `\u{1}k\u{1}` placeholder. Render it
                    // with the placeholders rewritten to `a[k]`, guarded by an arg-count
                    // check so a malformed/short args array demotes to EmptyView (never a
                    // crash). The values arrive from the shipped tree's `slotArgs[id]`.
                    let n = leaf.stringArgs.count
                    let rendered = Self.renderParameterizedTemplate(leaf.source, argCount: n)
                    out += "        __s[\"\(leaf.id)\"] = { (a: [String]) in a.count >= \(n) ? AnyView(\(rendered)) : AnyView(EmptyView()) }\n"
                }
            }
            out += "        return __s\n    }\n"
        }
        // The token-values method: evaluate each design-system token expression natively
        // (over self) into a `Color`/`Font`/`Double`/`String`. RAW source — self members
        // (incl. private, when same-file) / app types resolve in this method on the view.
        out += """

            /// Resolved design-system token values for this view's `.hostToken(id)`/
            /// `.fontToken(id)`/numeric/string token slots. Empty when the view uses none.
            @MainActor func \(Self.tokensMethodName)() -> [String: PatchHostToken] {

        """
        if tokens.isEmpty {
            out += "        [:]\n    }\n"
        } else {
            out += "        var __t: [String: PatchHostToken] = [:]\n"
            for tok in tokens {
                switch tok.kind {
                case .font:
                    out += "        __t[\"\(tok.id)\"] = .font(\(tok.source))\n"
                case .color:
                    out += "        __t[\"\(tok.id)\"] = .color(\(tok.source))\n"
                case .number:
                    // A numeric design token (`Theme.Radius.lg` → CGFloat) — resolved
                    // natively, carried as a Double. The SDK merges it into the guest's
                    // input JSON under the reserved `__numtok_<id>` key (the body reads it
                    // there). `Double(<src>)` widens CGFloat/Int uniformly.
                    out += "        __t[\"\(tok.id)\"] = .number(Double(\(tok.source)))\n"
                case .string:
                    // A host STRING token (an enum's computed-String `Text(…)` content like
                    // `confidence.label`) — resolved natively over `self`, carried as a
                    // String. The SDK merges it into the guest's input JSON under the
                    // reserved `__strtok_<id>` key (the Text content reads it there).
                    out += "        __t[\"\(tok.id)\"] = .string(\(tok.source))\n"
                }
            }
            out += "        return __t\n    }\n"
        }
        // The PER-ROW INDEXED NATIVE-ACTION SLOT method: for each `indexedForEachSlot`
        // node, natively evaluate the body-local collection (over `self`) and supply the
        // row COUNT + a per-row factory `(Int) -> AnyView`. The factory closes over the
        // evaluated collection AND `self`, so each row's REAL per-row native action
        // closure works. The loop var is bound to `__coll[offset]` via the collection's
        // own index (general over any `Collection`, not just `Array`). Raw source — self
        // members (incl. private when same-file) / app types resolve in this method.
        out += Self.renderRowSlotsMethod(rowSlots)
        // The NATIVE-ACTION SLOT method: for each `actionSlotButton` node, supply the action
        // closure `() -> Void` (over `self`, so the real native method call runs faithfully). Raw
        // source — self members (incl. private when same-file) / app types resolve in this method.
        out += Self.renderActionSlotsMethod(actionSlots)
        // The NATIVE EFFECT-MODIFIER SLOT method: for each `nativeEffectSlot` modifier, supply a
        // `(AnyView) -> AnyView` closure that applies the real `.task`/`.onAppear`/gesture/etc.
        // modifier (over `self`) to its content. Raw source — self members (incl. private when
        // same-file) / app types resolve in this method.
        out += Self.renderEffectSlotsMethod(effectSlots)
        // The CHILD-VIEW CALLBACK SLOT method: for each `callbackSlot` node, supply the full
        // child-view call (with the closure arg replaced by the stable forwarding closure) as an
        // `() -> AnyView` opaque closure. The callback body itself runs in WASM (OTA-patchable);
        // this slot provides the NATIVE wrapper the renderer fills the opaque slot with.
        out += Self.renderCallbackSlotsMethod(callbackSlots)
        // The CHILD-VIEW CALLBACK DISPATCHER: the stable forwarding closure baked into each callback
        // slot (`{ self.__patchDispatchCallback("<id>") }`) calls this. It routes the callback into the
        // SDK, which marshals the live instance's state, runs the guest's `dispatch(event: id)` (the
        // mutation rule recorded for this callback body), writes the new scalar state back into the
        // instance's @State, and SwiftUI re-renders the parent. Generated ONLY when the view has
        // callback slots — otherwise it would be dead code (and reference an unused SDK symbol).
        if !callbackSlots.isEmpty {
            out += """

                /// Routes a child-view callback (fired by the native slot's forwarding closure) into the
                /// SDK's WASM dispatch for this view, by the position-keyed callback id. The guest applies
                /// the recorded mutation rule; the SDK writes the result back into the live instance's
                /// @State, re-rendering the parent. The callback BODY rides WASM (OTA-patchable).
                @MainActor func \(Self.dispatchCallbackMethodName)(_ id: String) {
                    Patch.shared.dispatchCallback(typeName: "\(name)", instance: self, callbackId: id)
                }

            """
        }
        out += "}\n\n"
        return out
    }

    /// The generated `__patchEffectSlots()` method for a view. Returns `[:]` when the view has no
    /// native effect slots; otherwise a `[String: (AnyView) -> AnyView]` whose closures apply each
    /// undispatchable effect modifier's REAL expression (`.task { await self.load() }`/`.onAppear`/
    /// gesture) over `self` to the modified subtree. The application body is emitted RAW inside a
    /// `{ (content: AnyView) -> AnyView in AnyView(<applySource>) }` closure — `<applySource>` is the
    /// developer's original modifier re-rooted on `content`, captured over the live view instance, so
    /// the native effect runs faithfully (and an instance-state mutation re-renders the guest tree).
    static func renderEffectSlotsMethod(_ effectSlots: [BodyLowering.EffectSlot]) -> String {
        var out = """

            /// Native effect-modifier slots for this view's `.nativeEffectSlot` modifiers — an
            /// undispatchable `.task`/`.onAppear`/`.refreshable`/`.onSubmit`/gesture whose closure
            /// runs a native side-effect. Each closure (`(AnyView) -> AnyView`, over `self`) applies
            /// the real modifier to its content; the SDK applies it to the rendered subtree by id.
            /// Empty when the view has none.
            @MainActor func \(Self.effectSlotsMethodName)() -> [String: (AnyView) -> AnyView] {

        """
        if effectSlots.isEmpty {
            out += "        [:]\n    }\n"
            return out
        }
        out += "        var __e: [String: (AnyView) -> AnyView] = [:]\n"
        for slot in effectSlots {
            // The application source is the developer's original modifier re-rooted on `content`,
            // verbatim — wrapped in a `{ content in AnyView(content.<mod>(…)) }` closure run over
            // `self`. The emitter proved it references no body-local and (with same-file placement)
            // can reach any private SELF member, so this compiles.
            out += "        __e[\"\(slot.id)\"] = { (content: AnyView) -> AnyView in AnyView(\(slot.applySource)) }\n"
        }
        out += "        return __e\n    }\n"
        return out
    }

    /// The generated `__patchActionSlots()` method for a view. Returns `[:]` when the view has
    /// no native-action slots; otherwise a `[String: () -> Void]` whose closures run each
    /// actions-list Button's native action over `self`. The action body is emitted RAW inside a
    /// `{ … }` closure — exactly the developer's original action code, captured over the live view
    /// instance (so `deleteSubscription(self.selected)`/`resetAllData()` run faithfully on tap).
    static func renderActionSlotsMethod(_ actionSlots: [BodyLowering.ActionSlot]) -> String {
        var out = """

            /// Native-action slots for this view's `.actionSlotButton` nodes — an actions-list
            /// Button (`.swipeActions`/`.toolbar`/`.alert`/`Menu`/`.contextMenu`) whose action is a
            /// native method call. Each closure (`() -> Void`, over `self`) runs the real action;
            /// the SDK wires it to the reconstituted Button by id. Empty when the view has none.
            @MainActor func \(Self.actionSlotsMethodName)() -> [String: () -> Void] {

        """
        if actionSlots.isEmpty {
            out += "        [:]\n    }\n"
            return out
        }
        out += "        var __a: [String: () -> Void] = [:]\n"
        for slot in actionSlots {
            // The action body is the developer's original closure statements, verbatim — wrapped
            // in a `{ … }` closure run over `self`. The emitter proved it references no body-local
            // and no inaccessible member (same-file placement covers a private SELF read), so this
            // compiles.
            out += "        __a[\"\(slot.id)\"] = { \(slot.source) }\n"
        }
        out += "        return __a\n    }\n"
        return out
    }

    /// The generated `__patchCallbackSlots()` method for a view. Returns `[:]` when the view has
    /// no child-view callback slots; otherwise a `[String: () -> AnyView]` whose closures return
    /// the full child-view call (with the original closure arg replaced by a stable forwarding
    /// closure `{ self.__patchDispatchCallback("<id>") }`) as an `AnyView`. The renderer fills the
    /// `.callbackSlot`'s opaque position from this table; the WASM dispatch body (in the guest
    /// module's `dispatch__<View>` export) performs the actual state mutation OTA.
    static func renderCallbackSlotsMethod(_ callbackSlots: [BodyLowering.CallbackSlot]) -> String {
        var out = """

            /// Child-view callback slots for this view's `.callbackSlot` nodes — a custom child-view
            /// call whose `() -> Void` closure arg lowers to a WASM dispatch sequence. Each closure
            /// returns the full child-view `AnyView` with the callback arg replaced by a stable
            /// forwarder `{ self.__patchDispatchCallback("<id>") }`. The SDK fills the opaque slot
            /// position from this table by id. Empty when the view has no callback slots.
            @MainActor func \(Self.callbackSlotsMethodName)() -> [String: () -> AnyView] {

        """
        if callbackSlots.isEmpty {
            out += "        [:]\n    }\n"
            return out
        }
        out += "        var __cb: [String: () -> AnyView] = [:]\n"
        for slot in callbackSlots {
            // The slot source already has the closure arg replaced with the stable forwarder
            // (built by `tryRecordCallbackSlot`). Wrapped in `{ AnyView(<source>) }` so the
            // SDK's `([String]) -> AnyView` slot factory signature is satisfied.
            out += "        __cb[\"\(slot.id)\"] = { AnyView(\(slot.slotSource)) }\n"
        }
        out += "        return __cb\n    }\n"
        return out
    }

    /// The generated `__patchRowSlots()` method for a view. Returns `[:]` when the view
    /// has no per-row indexed slots; otherwise a `[String: PatchRowSlot]` populated by
    /// natively evaluating each slot's body-local collection + binding the loop var.
    static func renderRowSlotsMethod(_ rowSlots: [BodyLowering.IndexedRowSlot]) -> String {
        var out = """

            /// Per-row indexed native-action slots for this view's `.indexedForEachSlot`
            /// nodes. Each natively evaluates the body-local collection (over `self`) →
            /// a row count + a per-row factory `(Int) -> AnyView` (closing over `self`, so
            /// each row's real per-row native action works). Empty when the view has none.
            @MainActor func \(Self.rowSlotsMethodName)() -> [String: PatchRowSlot] {

        """
        if rowSlots.isEmpty {
            out += "        [:]\n    }\n"
            return out
        }
        out += "        var __r: [String: PatchRowSlot] = [:]\n"
        for slot in rowSlots {
            // Each slot is its own immediately-invoked closure so the per-slot
            // `__coll` doesn't collide. `__coll` is the live collection; the factory
            // indexes it by offset (general over any Collection). A defensive bounds
            // guard returns EmptyView if an out-of-range index is ever requested
            // (never a crash) — the host always asks for `0..<__coll.count`, so this
            // only bites a malformed tree.
            if let closureText = slot.rowClosureText {
                // `$0`-SHORTHAND row: INVOKE the original row closure with the element.
                // Swift's own scoping binds the closure's `$0` to the element; any
                // genuinely-nested closure inside the row keeps its OWN `$0`/params —
                // we never string/syntax-rewrite `$0`. The element type is inferred from
                // the collection (`__coll[i]` IS the `Element`), so no explicit type.
                out += """
                        __r["\(slot.id)"] = { () -> PatchRowSlot in
                            let __coll = \(slot.collectionSource)
                            return PatchRowSlot(count: __coll.count) { (__i: Int) in
                                guard __i >= 0, __i < __coll.count else { return AnyView(EmptyView()) }
                                return AnyView((\(closureText))(__coll[__coll.index(__coll.startIndex, offsetBy: __i)]))
                            }
                        }()

                """
            } else {
                out += """
                        __r["\(slot.id)"] = { () -> PatchRowSlot in
                            let __coll = \(slot.collectionSource)
                            return PatchRowSlot(count: __coll.count) { (__i: Int) in
                                guard __i >= 0, __i < __coll.count else { return AnyView(EmptyView()) }
                                let \(slot.loopVar) = __coll[__coll.index(__coll.startIndex, offsetBy: __i)]
                                return AnyView(\(slot.rowSource))
                            }
                        }()

                """
            }
        }
        out += "        return __r\n    }\n"
        return out
    }

    /// Rewrite a PARAMETERIZED slot template into a Swift expression the thunk
    /// factory can evaluate: each `\u{1}k\u{1}` placeholder (the kth lifted
    /// string-literal arg) becomes `a[k]` (the runtime-supplied value). E.g.
    /// `DisplayText(text: \u{1}0\u{1}, size: 28)` → `DisplayText(text: a[0], size: 28)`.
    /// The placeholders were written by the emitter's `opaqueCall` as bare
    /// identifiers, so a plain string replacement is exact (the sentinel `\u{1}`
    /// can't appear in real Swift source).
    static func renderParameterizedTemplate(_ template: String, argCount: Int) -> String {
        var out = template
        for k in 0..<argCount {
            out = out.replacingOccurrences(of: "\u{1}\(k)\u{1}", with: "a[\(k)]")
        }
        return out
    }

    // MARK: - Same-file generated block

    /// Render the SAME-FILE generated block appended to ONE view file: a BEGIN/END-marked
    /// region carrying the `@_dynamicReplacement(for: body)` extensions for the views
    /// DECLARED in that file. The block is `#if canImport(SwiftUI)`-guarded and self-
    /// contained (its own imports), and is regenerated wholesale (see `stripSameFileBlock`)
    /// so re-running `patchcli prepare` never duplicates it. Living in the view's own file
    /// is what makes the view's `private`/`fileprivate` members reachable from the thunk.
    static func renderSameFileBlock(viewNames: [String],
                                    slots: [String: [BodyLowering.OpaqueLeaf]] = [:],
                                    tokens: [String: [BodyLowering.HostToken]] = [:],
                                    rowSlots: [String: [BodyLowering.IndexedRowSlot]] = [:],
                                    actionSlots: [String: [BodyLowering.ActionSlot]] = [:],
                                    effectSlots: [String: [BodyLowering.EffectSlot]] = [:],
                                    callbackSlots: [String: [BodyLowering.CallbackSlot]] = [:],
                                    baselineHashes: [String: String] = [:],
                                    extraImports: [String] = []) -> String {
        var out = Self.sameFileBeginMarker + "\n"
        out += Self.doNotEditBanner + "\n"
        out += """
        // One `@_dynamicReplacement(for: body)` per SwiftUI View DECLARED in this file.
        // Each thunk routes the view's body through the Patch OTA renderer when a patch is
        // active, falling through to the original compiled `body` otherwise — so view
        // bodies are patchable over-the-air with no changes to the views. It also exposes
        // `__patchSlots()` (native renderers for non-lowerable leaves) and `__patchTokens()`
        // (natively-resolved design-system token values). Generated in THIS file (not a
        // separate one) so the thunk can reach the view's `private`/`fileprivate` members.
        //
        // Regenerated wholesale on every `patchcli prepare`. Safe to delete this whole
        // block (BEGIN..END) — `patchcli prepare` recreates it.
        #if canImport(SwiftUI)
        import SwiftUI
        import PatchSDK
        import PatchSwiftUI
        import PatchRender

        """
        for imp in extraImports {
            out += "#if canImport(\(imp))\nimport \(imp)\n#endif\n"
        }
        for name in viewNames {
            out += "\n" + renderExtension(name: name, slots: slots[name] ?? [],
                                          tokens: tokens[name] ?? [], rowSlots: rowSlots[name] ?? [],
                                          actionSlots: actionSlots[name] ?? [],
                                          effectSlots: effectSlots[name] ?? [],
                                          callbackSlots: callbackSlots[name] ?? [],
                                          baselineHash: baselineHashes[name])
        }
        out += "#endif\n"
        out += Self.doNotEditFooter + "\n"
        out += Self.sameFileEndMarker + "\n"
        return out
    }

    /// Remove any previously-generated SAME-FILE thunk block (everything from the BEGIN
    /// marker to the END marker, inclusive, plus the blank lines immediately before it)
    /// from `source`. Idempotent: a file with no block is returned unchanged; a file with
    /// one is returned with exactly the original (developer) content. This is the strip
    /// half of the idempotent regenerate — the caller appends a fresh block afterward.
    static func stripSameFileBlock(from source: String) -> String {
        guard let beginRange = source.range(of: Self.sameFileBeginMarker) else { return source }
        // Find the END marker after BEGIN; if a malformed (no-END) block somehow exists,
        // strip to end-of-file (conservative — we own everything from BEGIN onward).
        let afterBegin = beginRange.upperBound
        let endLowerBound: String.Index
        if let endRange = source.range(of: Self.sameFileEndMarker, range: afterBegin..<source.endIndex) {
            // Strip through the END marker's line (consume a trailing newline if present).
            var idx = endRange.upperBound
            if idx < source.endIndex, source[idx] == "\n" { idx = source.index(after: idx) }
            endLowerBound = idx
        } else {
            endLowerBound = source.endIndex
        }
        // Trim trailing whitespace/newlines the generator inserted before the BEGIN marker
        // so repeated strip→append cycles don't accumulate blank lines.
        var head = String(source[source.startIndex..<beginRange.lowerBound])
        while head.hasSuffix("\n") || head.hasSuffix(" ") { head.removeLast() }
        let tail = String(source[endLowerBound..<source.endIndex])
        let joined = tail.isEmpty ? head + "\n" : head + "\n" + tail
        return joined
    }
}

// MARK: - Body collector

private final class BodyCollector: SyntaxVisitor {
    let viewNames: Set<String>
    private var typeStack: [String] = []
    /// Depth of enclosing `#if` blocks: a body inside one is config-dependent, so
    /// we never touch it (a thunk referencing it could fail in another config).
    private var ifConfigDepth = 0
    /// (offset of the `var` keyword, enclosing type name, already `dynamic`?).
    private(set) var hits: [(offset: Int, type: String, alreadyDynamic: Bool)] = []

    init(viewNames: Set<String>) {
        self.viewNames = viewNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        ifConfigDepth += 1; return .visitChildren
    }
    override func visitPost(_ node: IfConfigDeclSyntax) { ifConfigDepth -= 1 }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(ThunkGenerator.baseTypeName(node.extendedType)); return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    // Track other type containers so a body's nearest enclosing type is correct
    // (a View struct nested in an enum, etc.) — only the LAST element is consulted.
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard ifConfigDepth == 0, let type = typeStack.last, viewNames.contains(type),
              Self.isBodySomeView(node) else { return .visitChildren }
        let offset = node.bindingSpecifier.positionAfterSkippingLeadingTrivia.utf8Offset
        let alreadyDynamic = node.modifiers.contains { $0.name.tokenKind == .keyword(.dynamic) }
        hits.append((offset, type, alreadyDynamic))
        return .visitChildren
    }

    /// `var body: some View` (and ONLY `some View` — never `some Scene` /
    /// `some Commands` / `some ToolbarContent` / `some WidgetConfiguration`).
    static func isBodySomeView(_ node: VariableDeclSyntax) -> Bool {
        guard node.bindings.count == 1, let b = node.bindings.first,
              b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "body",
              let t = b.typeAnnotation?.type else { return false }
        return t.trimmedDescription == "some View"
    }
}
