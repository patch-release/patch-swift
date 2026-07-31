// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Inserts the Patch SDK startup code into the app's `@main` SwiftUI entry
/// point — the last manual step of onboarding. String-surgical and
/// deliberately conservative: anything it can't place with certainty returns
/// `.notFound`/`.alreadyConfigured` and the caller prints the snippet instead.
/// The caller is responsible for showing the returned diff and asking the
/// developer to confirm BEFORE writing anything.
public enum AppEntryInjector {

    public struct Injection: Sendable, Equatable {
        public let fileURL: URL
        public let newContents: String
        /// A human-readable preview (unified-diff-ish) of exactly what changes.
        public let diff: String
    }

    public enum Outcome: Sendable, Equatable {
        case proposed(Injection)
        /// The sources already call `Patch.configure` — nothing to do.
        case alreadyConfigured(in: URL)
        /// No recognizable `@main … : App` entry point (UIKit AppDelegate apps,
        /// generated mains, …) — caller prints the manual snippet.
        case notFound
    }

    /// Directories never worth walking for the app entry point.
    static let skippedDirectories: Set<String> = [
        ".git", ".build", "Pods", "Carthage", "DerivedData", "build",
        ".swiftpm", "node_modules", "vendor", "Packages",
    ]

    /// Find the `@main` SwiftUI entry point under `root` and propose the
    /// startup-code insertion. Read-only — writing is the caller's decision.
    ///
    /// `appID` and `fingerprint` are baked into the configure call when known:
    /// `appID` keeps older SDKs (which require it for remote checks) working,
    /// and `fingerprint` opts the device into exact native-shell gating (a
    /// device reporting no fingerprint is served best-effort). Both optional —
    /// the key alone is a complete integration on SDK ≥ 1.0.3.
    public static func propose(
        in root: URL, appKey: String, appID: String? = nil,
        fingerprint: String? = nil, fm: FileManager = .default
    ) -> Outcome {
        let candidates = swiftFiles(in: root, fm: fm)
        // A `Patch.configure` anywhere in the app's sources means it is wired up.
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains("Patch.configure(") {
                return .alreadyConfigured(in: url)
            }
        }
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("@main") else { continue }
            if let newText = inject(
                into: text, appKey: appKey, appID: appID, fingerprint: fingerprint
            ) {
                return .proposed(Injection(
                    fileURL: url,
                    newContents: newText,
                    diff: insertionDiff(old: text, new: newText, path: url.lastPathComponent)
                ))
            }
        }
        return .notFound
    }

    /// Placeholder baked into a freshly-injected `Patch.configure(… fingerprint: "…")`
    /// before the native-shell fingerprint is known. `patchcli init` injects the configure
    /// call BEFORE computing the snapshot (so the injected boilerplate is part of the hashed
    /// shell), then `rebakeFingerprint(in:to:)` replaces this with the real value. The
    /// fingerprint VALUE is excluded from the native-shell hash
    /// (`ProjectFingerprinter.normalizeConfigureFingerprint`), so the rebake is hash-inert.
    public static let pendingFingerprintPlaceholder =
        "PENDING0000000000000000000000000000000000000000000000000000PENDING"

    /// Rewrite the baked `fingerprint: "…"` literal inside the app's `Patch.configure(…)`
    /// call to `fingerprint`, in place. Used by `patchcli init` to bake the REAL native-shell
    /// fingerprint after the snapshot is computed over the configure-injected tree (and to
    /// refresh a stale literal on a re-run). Hash-inert: the fingerprint value is excluded
    /// from the native-shell hash. Best-effort — returns whether a literal was rewritten.
    @discardableResult
    public static func rebakeFingerprint(
        in root: URL, to fingerprint: String, fm: FileManager = .default
    ) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"(fingerprint:\s*")[^"]*(")"#)
        else { return false }
        let template = "$1" + NSRegularExpression.escapedTemplate(for: fingerprint) + "$2"
        for url in swiftFiles(in: root, fm: fm) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("Patch.configure(") else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard regex.firstMatch(in: text, range: range) != nil else { continue }
            let rewritten = regex.stringByReplacingMatches(
                in: text, range: range, withTemplate: template)
            if (try? rewritten.write(to: url, atomically: true, encoding: .utf8)) != nil {
                return true
            }
        }
        return false
    }

    /// The `fingerprint: "…"` literal inside a `Patch.configure` call in the
    /// app's sources, if any. Used by push/release to warn when the baked-in
    /// literal goes stale (the native shell changed but the configure call
    /// still reports the old shell — new builds would mis-report until the
    /// literal is updated or `patchcli init` is re-run).
    public static func fingerprintLiteral(
        in root: URL, fm: FileManager = .default
    ) -> (file: URL, value: String)? {
        let pattern = #"fingerprint:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for url in swiftFiles(in: root, fm: fm) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("Patch.configure(") else { continue }
            if let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                return (url, String(text[r]))
            }
        }
        return nil
    }

    /// All `.swift` files under `root`, bounded (depth + count) so a giant tree
    /// can never hang init. Sorted shallowest-first so the app target's own
    /// `*App.swift` (typically at the top level) is found before test/support
    /// sources.
    static func swiftFiles(in root: URL, fm: FileManager, maxDepth: Int = 6, maxFiles: Int = 4000) -> [URL] {
        var results: [(depth: Int, url: URL)] = []
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty && visited < maxFiles {
            let (dir, depth) = queue.removeFirst()
            guard depth <= maxDepth,
                  let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                visited += 1
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if !skippedDirectories.contains(entry.lastPathComponent),
                       !entry.lastPathComponent.hasSuffix(".xcodeproj"),
                       !entry.lastPathComponent.hasSuffix(".xcassets") {
                        queue.append((entry, depth + 1))
                    }
                } else if entry.pathExtension == "swift" {
                    results.append((depth, entry))
                }
            }
        }
        return results.sorted {
            $0.depth != $1.depth ? $0.depth < $1.depth : $0.url.path < $1.url.path
        }.map(\.url)
    }

    // MARK: - Pure transform (internal for tests)

    /// The `Patch.configure(…)` call: one line for the key-only form, one
    /// argument per line once `appID`/`fingerprint` ride along (the full form
    /// is too wide for one line). `indent` prefixes every emitted line.
    public static func configureCall(
        appKey: String, appID: String?, fingerprint: String?, indent: String
    ) -> String {
        var args = ["appKey: \"\(appKey)\""]
        if let appID, !appID.isEmpty { args.append("appID: \"\(appID)\"") }
        if let fingerprint, !fingerprint.isEmpty {
            args.append("fingerprint: \"\(fingerprint)\"")
        }
        if args.count == 1 {
            return indent + "Patch.configure(.init(\(args[0])))\n"
        }
        var out = indent + "Patch.configure(.init(\n"
        for (i, arg) in args.enumerated() {
            out += indent + "    " + arg + (i == args.count - 1 ? "))\n" : ",\n")
        }
        return out
    }

    /// Inject `import PatchSDK` + the startup `init()` into a source file
    /// containing a `@main struct X: App`. Returns nil when the file has no
    /// recognizable SwiftUI entry point.
    static func inject(
        into source: String, appKey: String,
        appID: String? = nil, fingerprint: String? = nil
    ) -> String? {
        // `@main` followed by a struct declared `: … App` (allow access
        // modifiers and extra protocols; `App` must appear in the inheritance
        // clause before the opening brace).
        let pattern = #"@main[ \t\r\n]+(?:@\w+[ \t\r\n]+)*(?:public[ \t\r\n]+|internal[ \t\r\n]+)?struct[ \t\r\n]+\w+[ \t\r\n]*:[^{]*\bApp\b[^{]*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: source, range: NSRange(source.startIndex..., in: source)),
              let matchRange = Range(match.range, in: source) else {
            return nil
        }

        var text = source

        // The struct body's indentation: one level deeper than the `@main` line.
        let bodyIndent = "    "

        // Startup code. A struct that ALREADY has an init (Firebase setup,
        // service wiring, …) gets the two Patch lines MERGED at the top of that
        // init's body — real apps overwhelmingly have one, so bailing here used
        // to fail the mainstream case. A struct without one gets a fresh init.
        let structBody = String(source[matchRange.upperBound...])
        let configure = configureCall(
            appKey: appKey, appID: appID, fingerprint: fingerprint,
            indent: bodyIndent + "    ")
        if let bodyStart = topLevelInitBodyStart(inStructBody: structBody) {
            let insertAt = source.index(matchRange.upperBound, offsetBy: bodyStart)
            let lines = "\n"
                + configure
                + bodyIndent + "    Task { await Patch.shared.start() }\n"
            text.insert(contentsOf: lines, at: insertAt)
        } else {
            let initBlock = "\n"
                + bodyIndent + "init() {\n"
                + configure
                + bodyIndent + "    Task { await Patch.shared.start() }\n"
                + bodyIndent + "}\n"
            text.insert(contentsOf: initBlock, at: matchRange.upperBound)
        }

        // `import PatchSDK` after the LEADING top-level import block (the
        // contiguous run of unconditional imports at the top of the file),
        // NOT after the last import anywhere. A conditional import below the
        // `@main` struct (`#if canImport(WidgetKit)\nimport WidgetKit\n#endif`)
        // must not become the anchor — inserting there would land
        // `import PatchSDK` inside the `#if`, so PatchSDK would only be imported
        // when that guard is true (unresolved `Patch.configure` otherwise).
        if !text.contains("import PatchSDK") {
            var lines = text.components(separatedBy: "\n")
            let anchor = leadingTopLevelImportEnd(in: lines)
            if anchor >= 0 {
                lines.insert("import PatchSDK", at: anchor + 1)
            } else {
                lines.insert("import PatchSDK", at: 0)
            }
            text = lines.joined(separator: "\n")
        }
        return text
    }

    /// The index of the LAST line of the file's leading, unconditional,
    /// top-level `import` block — the contiguous run of `import …` lines at the
    /// top of the file (skipping blank lines and leading comments), stopping at
    /// the first `#if`/preprocessor directive or the first non-import
    /// declaration. Returns -1 when there is no leading top-level import.
    static func leadingTopLevelImportEnd(in lines: [String]) -> Int {
        var lastImport = -1
        var sawImport = false
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("//") {
                continue  // blanks / line comments don't break the leading run
            }
            if t.hasPrefix("#") {
                // A preprocessor directive (`#if`, `#endif`, …) ends the
                // unconditional leading import block — never anchor past it.
                break
            }
            if t.hasPrefix("import ") || t.hasPrefix("@_exported import ")
                || t.hasPrefix("@testable import ") {
                lastImport = i
                sawImport = true
                continue
            }
            // First real, non-import top-level token (e.g. `struct`, `@main`,
            // an attribute, `/* … */` is rare and conservatively stops here):
            // the leading import run is over.
            if sawImport { break }
            // Haven't seen an import yet and hit a non-import non-comment line:
            // there is no leading import block at all.
            break
        }
        return lastImport
    }

    /// Does the struct body (text following the opening brace) contain an
    /// `init` at its top nesting level? (Compatibility wrapper over
    /// `topLevelInitBodyStart` — kept for tests/readability.)
    static func hasTopLevelInit(inStructBody body: String) -> Bool {
        topLevelInitBodyStart(inStructBody: body) != nil
    }

    /// The offset (in `body`, the text following the struct's opening brace)
    /// just AFTER the opening `{` of the struct's top-level `init` — i.e. where
    /// merged startup lines go — or nil when the struct declares no init at its
    /// top nesting level. The scan is string-, comment-, and depth-aware:
    /// `init` inside `var body`, a nested type, a string literal, or a comment
    /// never counts (depth 0 = directly inside the struct).
    static func topLevelInitBodyStart(inStructBody body: String) -> Int? {
        var depth = 0
        var inString = false
        var inLineComment = false
        var inBlockComment = false
        var prev: Character = " "
        var i = body.startIndex
        var initAt: String.Index?

        while i < body.endIndex {
            let ch = body[i]
            if inLineComment {
                if ch == "\n" { inLineComment = false }
            } else if inBlockComment {
                if prev == "*" && ch == "/" { inBlockComment = false }
            } else if inString {
                if ch == "\"" && prev != "\\" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "/" where prev == "/": inLineComment = true
                case "*" where prev == "/": inBlockComment = true
                case "(", "[": depth += 1
                case ")", "]": depth -= 1
                case "{":
                    if let _ = initAt, depth == 0 {
                        // The opening brace of the top-level init's body.
                        return body.distance(from: body.startIndex,
                                             to: body.index(after: i))
                    }
                    depth += 1
                case "}":
                    if depth == 0 { return nil }  // struct closed — no init
                    depth -= 1
                default:
                    if depth == 0, initAt == nil, ch == "i", body[i...].hasPrefix("init") {
                        // Word-boundary check on both sides. A trailing `?`/`!`
                        // is the FAILABLE-init form (`init?`/`init!`) — those
                        // have the same signature as `init()`, so emitting a
                        // fresh `init()` alongside one is a hard redeclaration
                        // error. Treat them as a top-level init and merge into
                        // their body instead.
                        let after = body.index(i, offsetBy: 4)
                        let beforeOK = i == body.startIndex
                            || !body[body.index(before: i)].isLetter
                        let afterOK = after >= body.endIndex
                            || !(body[after].isLetter || body[after].isNumber
                                 || body[after] == "_")
                        if beforeOK && afterOK { initAt = i }
                    }
                }
            }
            prev = ch
            i = body.index(after: i)
        }
        return nil
    }

    /// A compact, insertion-only diff preview: added lines prefixed `+`, with
    /// up to `context` unchanged lines around each insertion run.
    static func insertionDiff(old: String, new: String, path: String, context: Int = 2) -> String {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        // A real LCS alignment (not a greedy single pass): a coincidental match
        // between an inserted line and the next pending source line no longer
        // shifts the attribution, so a genuinely-unchanged later line is never
        // shown as `+ added` (or vice versa). The transform only inserts, so
        // every newLine not on the LCS is a true addition.
        let common = longestCommonSubsequence(oldLines, newLines)
        var marks: [(line: String, added: Bool)] = []
        var ci = 0
        for line in newLines {
            if ci < common.count && common[ci] == line {
                marks.append((line, false)); ci += 1
            } else {
                marks.append((line, true))
            }
        }
        var keep = [Bool](repeating: false, count: marks.count)
        for (i, m) in marks.enumerated() where m.added {
            for j in max(0, i - context)...min(marks.count - 1, i + context) { keep[j] = true }
        }
        var out = ["--- \(path)", "+++ \(path) (proposed)"]
        var lastShown = -2
        for (i, m) in marks.enumerated() where keep[i] {
            if i > lastShown + 1 { out.append("  …") }
            out.append((m.added ? "+ " : "  ") + m.line)
            lastShown = i
        }
        return out.joined(separator: "\n")
    }

    /// Standard dynamic-programming longest-common-subsequence of two line
    /// arrays, returned as the sequence of shared lines in order. Used only for
    /// the human-facing diff preview, so the O(n·m) cost is bounded by the small
    /// source files `inject` touches.
    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return [] }
        // dp[i][j] = LCS length of a[i...] and b[j...].
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j]
                    ? dp[i + 1][j + 1] + 1
                    : Swift.max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var result: [String] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                result.append(a[i]); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
