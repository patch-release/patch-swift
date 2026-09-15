// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftParser
import SwiftSyntax
import CodeGenerator

/// `patchcli prepare --verify` — the COMPILE-VALIDATION safety net for prepared projects.
///
/// Static gates (the emitter's scope/type-provability checks, the per-view parse gate, the
/// reserved-guest-identifier net) close every KNOWN way generated code can break the app build,
/// but only the real compiler can prove it: a toolchain-specific type-checker budget ("unable to
/// type-check this expression in reasonable time"), an app type the syntax-only lowering can't
/// see, a brand-new codegen bug. This verifier BUILDS the prepared project, attributes each
/// `file:line:col: error:` to the view whose prepared code it lands in, keeps ONLY those views
/// native (no `dynamic`, no thunk — their original source span restored), and rebuilds, looping
/// until the build is clean or nothing attributable is left.
///
/// FAIL-SAFE BY CONSTRUCTION:
///   * it only ever REMOVES Patch's changes (a demoted view renders exactly as written);
///   * an error it can't pin on a prepared view (a pre-existing project error, a missing
///     dependency, a signing problem) never demotes anything — it is reported, not "fixed";
///   * a view demoted for errors that ALL persist once its prepared code is gone was never the
///     cause — it is re-promoted and those errors are reported as pre-existing;
///   * bounded: a wall-clock timeout per build and a hard iteration cap.
public enum PrepareVerifier {

    /// Default per-build wall-clock budget. A cold `xcodebuild` of a real app (package
    /// resolution + dependencies) can take minutes; later loop iterations are incremental.
    public static let defaultTimeout: TimeInterval = 600
    /// Hard cap on build → demote → rebuild rounds.
    public static let maxIterations = 8

    // MARK: - Diagnostics

    public struct Diagnostic: Hashable, Sendable, CustomStringConvertible {
        public let file: String
        public let line: Int
        public let column: Int
        public let message: String
        public init(file: String, line: Int, column: Int, message: String) {
            self.file = file; self.line = line; self.column = column; self.message = message
        }
        public var description: String {
            "\((file as NSString).lastPathComponent):\(line):\(column): \(message)"
        }
        /// Identity ACROSS demotion rounds: file + line + message, NOT the column. Removing the
        /// `dynamic ` prepare inserted shifts every column after it on the `var body` line (a
        /// body-getter type-check timeout is reported at the body's `{`), while line numbers stay
        /// put (`dynamic` is inline; generated blocks are appended at the end of the file).
        var stableKey: String { "\(file)\u{1}\(line)\u{1}\(message)" }
    }

    /// Every compiler `error:` diagnostic (`/abs/File.swift:12:5: error: …`) in a build log,
    /// de-duplicated in first-seen order (xcodebuild repeats them).
    public static func parseDiagnostics(_ log: String) -> [Diagnostic] {
        var out: [Diagnostic] = []
        var seen = Set<Diagnostic>()
        for raw in log.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard let errRange = line.range(of: ": error: ") else { continue }
            let head = line[line.startIndex..<errRange.lowerBound]
            let message = String(line[errRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            // head = <path>.swift:<line>:<col>
            let parts = head.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 3, let col = Int(parts[parts.count - 1]),
                  let ln = Int(parts[parts.count - 2]) else { continue }
            let path = parts[0..<(parts.count - 2)].joined(separator: ":")
            guard path.hasSuffix(".swift") else { continue }
            let d = Diagnostic(file: path, line: ln, column: col, message: message)
            if seen.insert(d).inserted { out.append(d) }
        }
        return out
    }

    // MARK: - Attribution (diagnostic → prepared view)

    public struct Attribution: Sendable {
        public var byView: [String: [Diagnostic]] = [:]
        public var unattributed: [Diagnostic] = []
    }

    /// Map each diagnostic to the prepared view it lands in:
    ///   * inside the generated `PatchThunks.generated.swift`, or inside an in-file
    ///     `PATCH-THUNKS` block → the view named by the enclosing `extension <View>`;
    ///   * anywhere else in an app file → the innermost `struct <View>` / `extension <View>`
    ///     declaration whose line range contains it (this is how a type-checker timeout inside
    ///     a prepared view's own `body` is attributed).
    /// Only names in `preparedViews` are candidates; everything else is unattributed.
    public static func attribute(_ diagnostics: [Diagnostic], preparedViews: Set<String>,
                                 readFile: (String) -> String?) -> Attribution {
        var result = Attribution()
        var cache: [String: FileIndex] = [:]
        for d in diagnostics {
            if cache[d.file] == nil, let text = readFile(d.file) {
                cache[d.file] = FileIndex(path: d.file, text: text)
            }
            guard let index = cache[d.file],
                  let view = index.view(atLine: d.line, candidates: preparedViews) else {
                result.unattributed.append(d); continue
            }
            result.byView[view, default: []].append(d)
        }
        return result
    }

    /// Per-file line → enclosing view lookup.
    struct FileIndex {
        let isGeneratedFile: Bool
        let lines: [Substring]
        /// (begin line, end line) of each in-file generated block, 1-based inclusive.
        let blocks: [(Int, Int)]
        /// (view name, first line, last line) of every struct/extension decl, 1-based inclusive.
        let decls: [(name: String, start: Int, end: Int)]

        init(path: String, text: String) {
            isGeneratedFile = (path as NSString).lastPathComponent == ThunkGenerator.thunkFileName
            lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            var blocks: [(Int, Int)] = []
            var open: Int?
            for (i, l) in lines.enumerated() {
                // Both in-file generated blocks: the compact PATCH-THUNKS block and the PATCH-ACCESS
                // forwarder block (an error in a forwarder is attributed to its `extension <View>`).
                if l.hasPrefix(ThunkGenerator.sameFileBeginMarker) || l.hasPrefix(PatchAccessForwarding.beginMarker) {
                    open = i + 1
                } else if l.hasPrefix(ThunkGenerator.sameFileEndMarker) || l.hasPrefix(PatchAccessForwarding.endMarker),
                          let o = open {
                    blocks.append((o, i + 1)); open = nil
                }
            }
            self.blocks = blocks
            let tree = Parser.parse(source: text)
            let converter = SourceLocationConverter(fileName: path, tree: tree)
            let collector = TypeDeclLineCollector(converter: converter)
            collector.walk(tree)
            decls = collector.decls
        }

        func view(atLine line: Int, candidates: Set<String>) -> String? {
            let block = blocks.first { line >= $0.0 && line <= $0.1 }
            if isGeneratedFile || block != nil {
                // Nearest preceding `extension <Name>` header (within the block, if any).
                let floor = block?.0 ?? 1
                var i = min(line, lines.count)
                while i >= floor {
                    if let name = Self.extensionName(in: lines[i - 1]) {
                        return candidates.contains(name) ? name : nil
                    }
                    i -= 1
                }
                return nil
            }
            // Innermost enclosing declaration named like a prepared view.
            let containing = decls.filter { line >= $0.start && line <= $0.end && candidates.contains($0.name) }
            return containing.min { ($0.end - $0.start) < ($1.end - $1.start) }?.name
        }

        static func extensionName(in line: Substring) -> String? {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("extension ") else { return nil }
            let rest = t.dropFirst("extension ".count)
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
            return name.split(separator: ".").last.map(String.init)
        }
    }

    private final class TypeDeclLineCollector: SyntaxVisitor {
        let converter: SourceLocationConverter
        var decls: [(name: String, start: Int, end: Int)] = []
        init(converter: SourceLocationConverter) {
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }
        private func add(_ name: String, _ node: some SyntaxProtocol) {
            let s = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
            let e = converter.location(for: node.endPositionBeforeTrailingTrivia).line
            decls.append((name, s, e))
        }
        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            add(node.name.text, node); return .visitChildren
        }
        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
            let full = node.extendedType.trimmedDescription
            let base = full.split(separator: "<").first.map(String.init) ?? full
            add(base.split(separator: ".").last.map(String.init) ?? base, node); return .visitChildren
        }
    }

    // MARK: - Build invocation

    public struct BuildInvocation: Sendable, Equatable {
        public let executable: String
        public let arguments: [String]
        public let workingDirectory: URL
        /// Short human label (`xcodebuild -scheme App` / `swift build`).
        public let label: String
    }

    /// How to build this project for verification:
    ///   * an `.xcworkspace`/`.xcodeproj` at `root` → `xcodebuild … -scheme <scheme> -destination
    ///     'generic/platform=iOS Simulator' build` (no code signing, no index store), with a
    ///     per-project derived-data dir outside the project so rebuilds are incremental;
    ///   * a `Package.swift` → `swift build` (scratch path outside the project);
    ///   * otherwise nil (verification is skipped).
    /// `scheme` defaults to the `.Patch.yml` target, else the project's name.
    public static func detectBuild(root: URL, scheme: String?, fm: FileManager = .default) -> BuildInvocation? {
        let entries = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        let scratch = verifyScratchDirectory(for: root)
        let workspace = entries.filter { $0.hasSuffix(".xcworkspace") }.sorted().first
        let project = entries.filter { $0.hasSuffix(".xcodeproj") }.sorted().first
        if let container = workspace ?? project {
            let stem = (container as NSString).deletingPathExtension
            let s = (scheme?.isEmpty == false ? scheme! : stem)
            let args = [workspace != nil ? "-workspace" : "-project", container,
                        "-scheme", s,
                        "-destination", "generic/platform=iOS Simulator",
                        "-derivedDataPath", scratch.appendingPathComponent("DerivedData").path,
                        "build",
                        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
                        "COMPILER_INDEX_STORE_ENABLE=NO"]
            return BuildInvocation(executable: "/usr/bin/xcodebuild", arguments: args,
                                   workingDirectory: root, label: "xcodebuild -scheme \(s)")
        }
        if entries.contains("Package.swift") {
            return BuildInvocation(executable: "/usr/bin/swift",
                                   arguments: ["build", "--scratch-path", scratch.appendingPathComponent("spm").path],
                                   workingDirectory: root, label: "swift build")
        }
        return nil
    }

    /// A stable per-project scratch dir (outside the project tree, so nothing Patch-owned lands in
    /// the developer's repo and repeated verifications build incrementally).
    public static func verifyScratchDirectory(for root: URL) -> URL {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-verify-\(String(h, radix: 16))")
    }

    public struct BuildOutcome: Sendable {
        public var log: String
        public var exitCode: Int32
        public var timedOut: Bool
        public var seconds: Double
        public init(log: String, exitCode: Int32, timedOut: Bool, seconds: Double) {
            self.log = log; self.exitCode = exitCode; self.timedOut = timedOut; self.seconds = seconds
        }
    }

    /// Run the build with a wall-clock timeout (SIGTERM, then SIGKILL after 2s). Output goes to
    /// a temp file (never a pipe — a chatty xcodebuild would dead-lock a full pipe buffer).
    /// `tick` is called about twice a second with the elapsed seconds (for progress output).
    public static func runBuild(_ inv: BuildInvocation, timeout: TimeInterval,
                                tick: ((Double) -> Void)? = nil) -> BuildOutcome {
        let start = Date()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-verify-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: logURL) }
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            return BuildOutcome(log: "", exitCode: -1, timedOut: false, seconds: 0)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: inv.executable)
        p.arguments = inv.arguments
        p.currentDirectoryURL = inv.workingDirectory
        p.standardOutput = handle
        p.standardError = handle
        do { try p.run() } catch {
            try? handle.close()
            return BuildOutcome(log: "could not launch \(inv.executable): \(error)", exitCode: -1,
                                timedOut: false, seconds: 0)
        }
        let deadline = start.addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Date() >= deadline { timedOut = true; break }
            tick?(Date().timeIntervalSince(start))
            Thread.sleep(forTimeInterval: 0.5)
        }
        if timedOut {
            p.terminate()
            let killDeadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.1) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        try? handle.close()
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return BuildOutcome(log: log, exitCode: p.terminationStatus, timedOut: timedOut,
                            seconds: Date().timeIntervalSince(start))
    }

    // MARK: - The demote-and-retry loop

    public struct Report: Sendable {
        /// Views kept native by THIS verification, with the diagnostics that proved it.
        public var demoted: [(view: String, diagnostics: [Diagnostic])] = []
        /// Errors present with Patch's changes removed (not caused by prepare).
        public var preExisting: [Diagnostic] = []
        /// Errors in the final build that could not be attributed to any prepared view.
        public var unattributed: [Diagnostic] = []
        /// The final build succeeded with no errors.
        public var clean = false
        public var timedOut = false
        /// Set when verification stopped without a verdict (build failed with no compiler
        /// diagnostics, iteration cap, …).
        public var inconclusive: String?
        public var builds = 0
        public init() {}
    }

    /// Drive build → attribute → demote → rebuild until clean / nothing attributable is left.
    ///
    /// - Parameters:
    ///   - preparedViews: the views that currently carry a thunk (the first prepare's result).
    ///   - keptNative: views already kept native before verification (never re-promoted here).
    ///   - apply: regenerate + rewrite the prepared project keeping `native` views native;
    ///     returns the views that now carry a thunk.
    ///   - build: run one build.
    ///   - readFile: read a diagnostic's file (the prepared text on disk).
    ///   - progress: human progress lines.
    public static func run(preparedViews: Set<String>, keptNative: Set<String>,
                           apply: (Set<String>) throws -> Set<String>,
                           build: () -> BuildOutcome,
                           readFile: (String) -> String?,
                           progress: (String) -> Void = { _ in }) rethrows -> Report {
        var report = Report()
        var prepared = preparedViews
        var native = keptNative
        // view → the diagnostics that got it demoted during this run.
        var demotedFor: [String: [Diagnostic]] = [:]
        var demotionOrder: [String] = []
        var repromoted = Set<String>()
        var preExisting: [Diagnostic] = []
        var preExistingKeys = Set<String>()

        for _ in 0..<maxIterations {
            let outcome = build()
            report.builds += 1
            if outcome.timedOut {
                report.timedOut = true
                progress("Build timed out after \(Int(outcome.seconds))s — verification stopped.")
                break
            }
            let diags = parseDiagnostics(outcome.log)
            if outcome.exitCode == 0 && diags.isEmpty {
                report.clean = true
                report.unattributed = []
                break
            }
            if diags.isEmpty {
                report.inconclusive = "the build failed (exit \(outcome.exitCode)) without any compiler "
                    + "error to attribute (package resolution, signing, a missing SDK?)"
                break
            }
            let present = Set(diags.map(\.stableKey))
            // RE-PROMOTE: a view demoted earlier whose triggering errors ALL persist without its
            // prepared code was never the cause — give it back its thunk; the errors are the
            // project's own.
            var changed = false
            for (view, trig) in demotedFor where Set(trig.map(\.stableKey)).isSubset(of: present) {
                demotedFor[view] = nil
                demotionOrder.removeAll { $0 == view }
                native.remove(view)
                repromoted.insert(view)
                for d in trig where preExistingKeys.insert(d.stableKey).inserted { preExisting.append(d) }
                changed = true
                progress("\(view): its errors remain without Patch's changes — not caused by prepare; kept patchable.")
            }
            let attributable = diags.filter { !preExistingKeys.contains($0.stableKey) }
            let attribution = attribute(attributable, preparedViews: prepared, readFile: readFile)
            // A re-promoted view is never demoted again in this run (guarantees termination).
            let newDemotes = attribution.byView.filter { !native.contains($0.key) && !repromoted.contains($0.key) }
            for (view, ds) in newDemotes.sorted(by: { $0.key < $1.key }) {
                native.insert(view)
                demotedFor[view] = ds
                demotionOrder.append(view)
                changed = true
                progress("\(view): \(ds.count) error(s) in its prepared code (e.g. \(ds[0])) — keeping it native.")
            }
            report.unattributed = attribution.unattributed
                + attribution.byView.filter { newDemotes[$0.key] == nil }.flatMap { $0.value }
            guard changed else { break }
            prepared = try apply(native)
        }
        if !report.clean && !report.timedOut && report.inconclusive == nil && report.builds >= maxIterations {
            report.inconclusive = "stopped after \(maxIterations) builds"
        }
        report.demoted = demotionOrder.map { ($0, (demotedFor[$0] ?? []).sorted { $0.line < $1.line }) }
        report.preExisting = preExisting.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
        return report
    }
}
