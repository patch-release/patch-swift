// SPDX-License-Identifier: Apache-2.0

import Foundation
import PartitioningEngine

/// Explains, in plain language, WHY native functions in source files are not
/// OTA-patchable — by running the partitioning engine and translating its
/// classification reasons. Used by `fingerprint diff --explain` (and to annotate
/// the changed files in a mismatch) so a developer who edits a native function
/// understands why it changed the shell, instead of a cryptic "native swift files
/// changed". Baseline-free: works on the current tree, no backend/register needed.
public enum FingerprintExplain {
    public struct FileReasons: Sendable {
        public let relPath: String
        public let nativeFunctions: [String]   // short names
        public let dominantReason: String      // plain language
    }

    /// Run analysis ONCE and return, for each requested rel path that contains
    /// native functions, the native function names + a dominant plain reason.
    /// `relPaths == nil` ⇒ explain every native file in the project. Best-effort:
    /// returns [] if analysis fails.
    public static func explain(projectDir: URL, relPaths: Set<String>? = nil,
                               registry: NativeRegistry = .standard) -> [FileReasons] {
        guard let report = try? PartitioningEngine(registry: registry).analyze(directory: projectDir) else {
            return []
        }
        let base = projectDir.standardizedFileURL.path
        // rel -> (functions, reasons[])
        var byFile: [String: (fns: [String], reasons: [String])] = [:]
        for r in report.results where r.classification == .native {
            guard let rec = report.records[r.functionID] else { continue }
            let p = rec.sourceFile.standardizedFileURL.path
            guard p.hasPrefix(base) else { continue }
            let rel = String(p.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let want = relPaths, !want.contains(rel) { continue }
            // Skip synthesized closure sub-nodes — report the enclosing member only.
            if r.functionID.contains(".closure@") { continue }
            var entry = byFile[rel] ?? (fns: [], reasons: [])
            entry.fns.append(shortName(r.functionID))
            entry.reasons.append(contentsOf: r.reasons)
            entry.reasons.append(contentsOf: r.nativeHits.map { "native symbol \($0.symbol)" })
            byFile[rel] = entry
        }
        return byFile.map { rel, v in
            FileReasons(relPath: rel,
                        nativeFunctions: Array(Set(v.fns)).sorted(),
                        dominantReason: plainReason(v.reasons))
        }.sorted { $0.relPath < $1.relPath }
    }

    /// Last path component of a qualified function id, without the type/module
    /// qualifiers: `Services.ScheduleService.availableOwners` → `availableOwners`,
    /// `A.B.foo(bar:)` → `foo(bar:)`.
    static func shortName(_ functionID: String) -> String {
        guard let parenIdx = functionID.firstIndex(of: "(") else {
            return String(functionID.split(separator: ".").last ?? Substring(functionID))
        }
        let head = String(functionID[..<parenIdx])
        let tail = String(functionID[parenIdx...])
        let member = String(head.split(separator: ".").last ?? Substring(head))
        return member + tail
    }

    /// Collapse a function's classification reasons into ONE plain-language line.
    /// Ordered most-specific-first; falls back to the engine's own wording.
    static func plainReason(_ reasons: [String]) -> String {
        let joined = reasons.joined(separator: " ")
        func has(_ needles: String...) -> Bool {
            needles.contains { joined.range(of: $0, options: .caseInsensitive) != nil }
        }
        if has("reactive property", "@State", "@Published", "@Observable", "ObservableObject") {
            return "reads observable/state (@Observable/@State/@Published/SwiftData) — runs natively"
        }
        if has("UIKit lifecycle", "UIKit inherited", "super access") {
            return "UIKit lifecycle / inherited member — runs natively"
        }
        if has("view-DSL", "some View", "@ViewBuilder") {
            return "SwiftUI view member — patched via the view path, not as a standalone function"
        }
        if has("dynamic") { return "declared `dynamic` — runs natively" }
        if has("@objc", "selector", "#selector", "unsafe", "withUnsafe") {
            return "Objective-C / selector / unsafe-pointer interop — runs natively"
        }
        if let sym = reasons.compactMap({ r -> String? in
            guard let range = r.range(of: "native symbol ") else { return nil }
            return String(r[range.upperBound...])
        }).first {
            return "calls native API `\(sym)` (no host bridge) — runs natively"
        }
        if let specific = reasons.first(where: { $0.contains(": ") }) {
            return String(specific.split(separator: ": ").last ?? Substring(specific))
        }
        return reasons.first ?? "runs natively"
    }
}
