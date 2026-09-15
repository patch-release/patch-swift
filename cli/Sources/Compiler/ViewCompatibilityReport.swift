// SPDX-License-Identifier: Apache-2.0

import Foundation
import CodeGenerator

/// The per-view COMPATIBILITY SUMMARY `patchcli prepare`/`init` print after generating thunks:
/// how many SwiftUI views are OTA-patchable (auto-routed), how many stay native, and a one-line
/// reason for every native view, every view whose thunk had to stay beside its source, and every
/// view that keeps a piece (a `ToolbarContent` toolbar) native.
///
/// REPORTING-ONLY. Built from data prepare already computed — `ThunkGenerator.Result`'s lowered
/// views / placements / skipped views — and the build's own verdict + diagnostics
/// (`ProjectFingerprinter.isAutoRouted`, the `blockingReadNames`/`inaccessibleReadNames`/
/// `swiftDataBlockers`/`tupleBlockingNames` demote diagnostics). It never feeds back into
/// lowering, placement, thunks, or the fingerprint. The verdict is the STATIC prediction; the
/// build's WASM compile can still drop a view (the build warning names those).
public struct ViewCompatibilityReport: Sendable {
    public enum Status: String, Sendable { case patchable, native }

    public struct Entry: Sendable {
        public let view: String
        public let status: Status
        /// A native view: why it isn't patchable. A patchable view: nil.
        public let reason: String?
        /// A patchable view whose helper code had to stay in its own source file (it names
        /// a private member / file-private type): the explanation. nil otherwise.
        public let placementNote: String?
        /// Pieces of a patchable view kept native (e.g. `.toolbar` over ToolbarContent).
        public let nativeParts: [String]
        /// A patchable view whose thunk reaches private members / file-private types through its
        /// PATCH-ACCESS forwarders (thunk in Patch/Generated/). Informational — Markdown report only.
        public var accessNote: String? = nil
    }

    public let entries: [Entry]
    public var patchableCount: Int { entries.filter { $0.status == .patchable }.count }
    public var nativeCount: Int { entries.filter { $0.status == .native }.count }

    /// Build the report for a hybrid/same-file `prepare` result. `sources` = the same source
    /// texts prepare scanned (for the build's thunk-eligibility rule).
    public static func build(from result: ThunkGenerator.Result, sources: [String]) -> ViewCompatibilityReport {
        var lowered: [String: BodyLowering.LoweredView] = [:]
        var exportBaseCounts: [String: Int] = [:]
        for lv in result.loweredViews {
            if lowered[lv.viewName] == nil { lowered[lv.viewName] = lv }
            if lv.report.totalElements > 0 {
                exportBaseCounts[SwiftUIGuestEmitter.exportSymbol(forView: lv.viewName), default: 0] += 1
            }
        }
        let collidingBases = Set(exportBaseCounts.filter { $0.value > 1 }.keys)
        let thunkIneligible = BuildPipeline.thunkIneligibleViewNames(sources: sources)

        var entries: [Entry] = []
        let all = Set(result.viewNames).union(result.skippedViews.keys).sorted()
        for view in all {
            if let skipped = result.skippedViews[view] {
                entries.append(Entry(view: view, status: .native, reason: skipped,
                                     placementNote: nil, nativeParts: []))
                continue
            }
            guard let lv = lowered[view] else {
                entries.append(Entry(view: view, status: .native,
                                     reason: "body isn't lowered (only a `struct X: View` declaring its own `body` is)",
                                     placementNote: nil, nativeParts: []))
                continue
            }
            guard ProjectFingerprinter.isAutoRouted(lv, collidingBases: collidingBases,
                                                    thunkIneligible: thunkIneligible) else {
                entries.append(Entry(view: view, status: .native,
                                     reason: nativeReason(lv, collidingBases: collidingBases,
                                                          thunkIneligible: thunkIneligible),
                                     placementNote: nil, nativeParts: []))
                continue
            }
            var note: String?
            var accessNote: String?
            if case .sameFileBecausePrivate(let names)? = result.placements[view] {
                let types = result.privateSymbolReferences[view] ?? []
                let members = names.filter { !types.contains($0) && $0 != "<private view type>" }
                var parts: [String] = []
                if names.contains("<private view type>") { parts.append("is declared private") }
                if !types.isEmpty { parts.append("references private type/symbol \(types.joined(separator: ", "))") }
                if !members.isEmpty { parts.append("reads private member \(members.joined(separator: ", "))") }
                // What stopped private-access forwarding (each member that forces same-file + why).
                if let blockers = result.forwardingBlockers[view], !blockers.isEmpty {
                    parts.append("can't forward " + blockers.sorted { $0.key < $1.key }
                        .map { "`\($0.key)` (\($0.value))" }.joined(separator: ", "))
                }
                note = parts.joined(separator: "; ") + " (thunk kept beside source)"
            } else if case .forwardedPrivateAccess(let members)? = result.placements[view] {
                // Not a warning: the thunk is in Patch/Generated/; the file only carries forwarders.
                accessNote = "reaches private \(members.joined(separator: ", ")) via PATCH-ACCESS forwarders (thunk in Patch/Generated/)"
            }
            var nativeParts: [String] = []
            if lv.effectSlots.contains(where: { $0.label == "toolbar" }) {
                nativeParts.append("toolbar — ToolbarContent kept native")
            }
            entries.append(Entry(view: view, status: .patchable, reason: nil,
                                 placementNote: note, nativeParts: nativeParts, accessNote: accessNote))
        }
        return ViewCompatibilityReport(entries: entries)
    }

    /// A one-line reason for a native view — the build's demote diagnostic wording (cli 1.6.4 /
    /// 1.6.27 fix hints), in the order `isAutoRouted` evaluates its gates.
    static func nativeReason(_ lv: BodyLowering.LoweredView, collidingBases: Set<String>,
                             thunkIneligible: Set<String>) -> String {
        if thunkIneligible.contains(lv.viewName) {
            return "another top-level struct shares its name (or generic `where`) — no thunk"
        }
        if collidingBases.contains(SwiftUIGuestEmitter.exportSymbol(forView: lv.viewName)) {
            return "another view has the same type name — can't be routed unambiguously"
        }
        if lv.referencesUnmarshalledInput || lv.referencesUnresolvedSymbol {
            if !lv.inaccessibleReadNames.isEmpty {
                let names = lv.inaccessibleReadNames.map { "`\($0)`" }.joined(separator: "/")
                return "reads private member(s) \(names) → fix: make them internal"
            }
            if !lv.swiftDataBlockers.isEmpty {
                return "reads SwiftData @Query/@Model [\(lv.swiftDataBlockers.joined(separator: ", "))]"
            }
            if lv.referencesUnmarshalledInput {
                var r = "reads non-reconstructable input(s)"
                if !lv.blockingReadNames.isEmpty { r += " [\(lv.blockingReadNames.joined(separator: ", "))]" }
                if !lv.tupleBlockingNames.isEmpty {
                    r += " → fix: replace the tuple type of "
                        + lv.tupleBlockingNames.map { "`\($0)`" }.joined(separator: "/")
                        + " with a named Codable struct"
                }
                return r
            }
            return "references out-of-scope symbol(s) [\(lv.unresolvedSymbols.joined(separator: ", "))]"
        }
        if lv.report.totalElements == 0 { return "nothing in the body lowers" }
        if lv.hasUndispatchableAction {
            return "a Button in an alert/toolbar/menu has an action that can't be dispatched OTA"
        }
        if lv.hasUndispatchableEffect {
            return "a .task/.onChange/.onDelete/gesture effect can't run faithfully OTA"
        }
        if let leaf = lv.opaqueLeaves.first(where: { !$0.slotable }) {
            let label = leaf.label.isEmpty ? "a leaf" : "`\(leaf.label)`"
            return "\(label) can't be rendered natively from the thunk (reads a body-local, or isn't a View)"
        }
        return "pure layout/routing shell — nothing patchable to route"
    }

    // MARK: - Rendering

    /// The concise console summary: a count line + one line per noteworthy view (native views
    /// first). At most `limit` detail lines; the rest are summarized.
    public func consoleLines(limit: Int = 20) -> [String] {
        var out = ["Compatibility: \(patchableCount) of \(entries.count) view(s) patchable OTA, "
                   + "\(nativeCount) kept native."]
        let details = detailLines()
        for line in details.prefix(limit) { out.append("  • " + line) }
        if details.count > limit {
            out.append("  … \(details.count - limit) more (write them all with `patchcli prepare --report <path>`)")
        }
        return out
    }

    /// One line per noteworthy view: native views, then beside-source placements, then
    /// patchable views with a native piece.
    func detailLines() -> [String] {
        var native: [String] = [], placed: [String] = [], parts: [String] = []
        for e in entries {
            switch e.status {
            case .native:
                native.append("\(e.view) — native: \(e.reason ?? "unknown")")
            case .patchable:
                if let note = e.placementNote { placed.append("\(e.view) — \(note)") }
                for p in e.nativeParts { parts.append("\(e.view).\(p)") }
            }
        }
        return native + placed + parts
    }

    /// The full report as Markdown (every view), for `patchcli prepare --report <path>`.
    public func markdown(projectName: String) -> String {
        var md = """
        # Patch view compatibility — \(projectName)

        Generated by `patchcli prepare`. **\(patchableCount)** of **\(entries.count)** SwiftUI view(s) \
        are patchable over-the-air; **\(nativeCount)** stay native. (Static prediction — \
        `patchcli build` confirms each view compiles to WASM.)

        | View | Status | Notes |
        |---|---|---|

        """
        func cell(_ s: String) -> String {
            s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        for e in entries {
            let notes: [String]
            switch e.status {
            case .native: notes = [e.reason ?? ""]
            case .patchable: notes = [e.placementNote, e.accessNote].compactMap { $0 } + e.nativeParts
            }
            md += "| `\(e.view)` | \(e.status == .patchable ? "patchable" : "native") | \(cell(notes.joined(separator: "; "))) |\n"
        }
        return md
    }
}
