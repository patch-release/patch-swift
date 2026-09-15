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
/// native (no body route, no thunk — their original source span restored), and rebuilds, looping
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

    /// Message of the pseudo-diagnostics `parseCompilerCrashes` produces.
    public static let compilerCrashMessage = "the Swift compiler crashed"

    /// A compiler CRASH prints no `file:line:col: error:` — only a stack dump whose `While …`
    /// frames name the declaration being processed (`… for getter for __patchedBody (at
    /// /abs/PatchThunks.generated.swift:62:9)`). Each crash dump contributes ONE pseudo-diagnostic
    /// at its INNERMOST (last-printed) source location, so a crash inside a prepared view's
    /// generated code is attributed to that view like any other error. De-duplicated.
    public static func parseCompilerCrashes(_ log: String) -> [Diagnostic] {
        var out: [Diagnostic] = []
        var seen = Set<Diagnostic>()
        var inDump = false
        var innermost: Diagnostic?
        func flush() {
            if let d = innermost, seen.insert(d).inserted { out.append(d) }
            innermost = nil
        }
        for raw in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.contains("Stack dump:") {
                flush()
                inDump = true
                continue
            }
            guard inDump else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            // Frames are numbered (`3.\tWhile evaluating …`) with optional continuation lines
            // (` for getter for x (at /p.swift:1:2)`); anything else ends the dump.
            let isFrame = t.first?.isNumber == true || t.hasPrefix("for ") || t.hasPrefix("at ") || t.hasPrefix("(at ")
            if isFrame {
                if let d = swiftLocation(in: line) { innermost = d }
            } else if !t.isEmpty {
                flush()
                inDump = false
            }
        }
        flush()
        return out
    }

    /// The first `/abs/File.swift:12:5` in `line` → a crash pseudo-diagnostic.
    static func swiftLocation(in line: String) -> Diagnostic? {
        guard let dot = line.range(of: ".swift:") else { return nil }
        guard let slash = line[..<dot.lowerBound].lastIndex(where: { $0 == " " || $0 == "(" || $0 == "\"" || $0 == "\t" }) else {
            return nil
        }
        let path = String(line[line.index(after: slash)..<dot.lowerBound]) + ".swift"
        guard path.hasPrefix("/") else { return nil }
        let nums = line[dot.upperBound...].split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard let ln = nums.first.flatMap({ Int($0) }) else { return nil }
        let col = nums.dropFirst().first.flatMap { Int($0.prefix { $0.isNumber }) } ?? 1
        return Diagnostic(file: path, line: ln, column: col, message: compilerCrashMessage)
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
                // Every in-file generated block: the compact PATCH-THUNKS block, the PATCH-ACCESS
                // forwarder block (an error in a forwarder is attributed to its `extension <View>`) and
                // the PATCH-ROUTE native fallback (`fileprivate extension View` — generated, but shared
                // by the file's routed bodies, so never pinned on one view).
                if l.hasPrefix(ThunkGenerator.sameFileBeginMarker) || l.hasPrefix(PatchAccessForwarding.beginMarker)
                    || l.hasPrefix(ThunkGenerator.routeFallbackBeginMarker) {
                    open = i + 1
                } else if l.hasPrefix(ThunkGenerator.sameFileEndMarker) || l.hasPrefix(PatchAccessForwarding.endMarker)
                            || l.hasPrefix(ThunkGenerator.routeFallbackEndMarker),
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

        /// The line is Patch-GENERATED code (the generated thunk file, or an in-file PATCH-THUNKS /
        /// PATCH-ACCESS block) — an error there can never be the developer's own.
        func isGenerated(line: Int) -> Bool {
            isGeneratedFile || blocks.contains { line >= $0.0 && line <= $0.1 }
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
    /// `scheme` defaults to the `.Patch.yml` target, else the project's name. `configuration` nil
    /// builds the scheme's default (Debug); otherwise `-configuration <name>` for xcodebuild, or
    /// `-c release` for SwiftPM when it is anything but Debug (SwiftPM knows only the two).
    public static func detectBuild(root: URL, scheme: String?, configuration: String? = nil,
                                   fm: FileManager = .default) -> BuildInvocation? {
        let entries = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        let scratch = verifyScratchDirectory(for: root)
        let workspace = entries.filter { $0.hasSuffix(".xcworkspace") }.sorted().first
        let project = entries.filter { $0.hasSuffix(".xcodeproj") }.sorted().first
        if let container = workspace ?? project {
            let stem = (container as NSString).deletingPathExtension
            let s = (scheme?.isEmpty == false ? scheme! : stem)
            var args = [workspace != nil ? "-workspace" : "-project", container, "-scheme", s]
            if let configuration { args += ["-configuration", configuration] }
            args += ["-destination", "generic/platform=iOS Simulator",
                     "-derivedDataPath", scratch.appendingPathComponent("DerivedData").path,
                     "build",
                     "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
                     "COMPILER_INDEX_STORE_ENABLE=NO"]
            return BuildInvocation(executable: "/usr/bin/xcodebuild", arguments: args, workingDirectory: root,
                                   label: "xcodebuild -scheme \(s)" + (configuration.map { " -configuration \($0)" } ?? ""))
        }
        if entries.contains("Package.swift") {
            let release = configuration.map { $0.lowercased() != "debug" } ?? false
            return BuildInvocation(executable: "/usr/bin/swift",
                                   arguments: ["build", "--scratch-path", scratch.appendingPathComponent("spm").path]
                                       + (release ? ["-c", "release"] : []),
                                   workingDirectory: root, label: release ? "swift build -c release" : "swift build")
        }
        return nil
    }

    // MARK: - Which configurations to verify

    /// What `--verify` builds. Debug proves the everyday build; the ARCHIVE configuration (usually
    /// Release: `-O`, whole-module) is what ships — an optimizer-only compiler bug in generated code
    /// breaks only that build, so verifying Debug alone can miss a break that stops an archive.
    public enum ConfigurationPlan: String, Sendable, CaseIterable {
        /// Debug only (one build).
        case debug
        /// The archive configuration only.
        case release
        /// Debug, then the archive configuration.
        case all

        /// `debug` / `release` (or `archive`) / `all` (or `both`).
        public init?(argument: String) {
            switch argument.lowercased() {
            case "debug": self = .debug
            case "release", "archive": self = .release
            case "all", "both": self = .all
            default: return nil
            }
        }
    }

    /// The configuration the project ARCHIVES with: the `ArchiveAction buildConfiguration` of the
    /// shared (else per-user) scheme named `scheme` — else the scheme named like the container, else
    /// the only scheme — in an `.xcworkspace`/`.xcodeproj` at `root`. "Release" when no scheme file
    /// names one (Xcode's default) and for a Package.swift project.
    public static func archiveConfiguration(root: URL, scheme: String?, fm: FileManager = .default) -> String {
        let entries = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        let containers = entries.filter { $0.hasSuffix(".xcworkspace") } + entries.filter { $0.hasSuffix(".xcodeproj") }
        var schemeDirs: [URL] = []
        for c in containers {
            let base = root.appendingPathComponent(c)
            schemeDirs.append(base.appendingPathComponent("xcshareddata/xcschemes"))
            let userData = base.appendingPathComponent("xcuserdata")
            for u in ((try? fm.contentsOfDirectory(atPath: userData.path)) ?? []).sorted() {
                schemeDirs.append(userData.appendingPathComponent(u).appendingPathComponent("xcschemes"))
            }
        }
        let schemes = schemeDirs.flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".xcscheme") }.sorted()
                .map { dir.appendingPathComponent($0) }
        }
        func named(_ n: String?) -> [URL] {
            guard let n, !n.isEmpty else { return [] }
            return schemes.filter { $0.deletingPathExtension().lastPathComponent == n }
        }
        let stem = containers.first.map { ($0 as NSString).deletingPathExtension }
        for url in named(scheme) + named(stem) + (schemes.count == 1 ? schemes : []) {
            if let xml = try? String(contentsOf: url, encoding: .utf8), let config = archiveConfiguration(schemeXML: xml) {
                return config
            }
        }
        return "Release"
    }

    /// `<ArchiveAction buildConfiguration = "AppStore" …>` → "AppStore".
    public static func archiveConfiguration(schemeXML: String) -> String? {
        guard let tag = schemeXML.range(of: "<ArchiveAction") else { return nil }
        let end = schemeXML.range(of: ">", range: tag.upperBound..<schemeXML.endIndex)?.lowerBound ?? schemeXML.endIndex
        let attrs = schemeXML[tag.upperBound..<end]
        guard let key = attrs.range(of: "buildConfiguration"),
              let q1 = attrs.range(of: "\"", range: key.upperBound..<attrs.endIndex),
              let q2 = attrs.range(of: "\"", range: q1.upperBound..<attrs.endIndex) else { return nil }
        let value = attrs[q1.upperBound..<q2.lowerBound].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// The builds `plan` verifies, in order: Debug first (cheaper, and it catches most breaks), then
    /// the archive configuration. A project that archives with Debug is built once.
    public static func verificationBuilds(root: URL, scheme: String?, plan: ConfigurationPlan,
                                          fm: FileManager = .default) -> [BuildInvocation] {
        let archive = archiveConfiguration(root: root, scheme: scheme, fm: fm)
        let archiveIsDebug = archive.lowercased() == "debug"
        let configs: [String?]
        switch plan {
        case .debug: configs = [nil]
        case .release: configs = [archiveIsDebug ? nil : archive]
        case .all: configs = archiveIsDebug ? [nil] : [nil, archive]
        }
        return configs.compactMap { detectBuild(root: root, scheme: scheme, configuration: $0, fm: fm) }
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
        /// Set when the failure is SYSTEMIC: more than half of the prepared views fail inside
        /// Patch-generated code (or crash the compiler) in one build. Generated code has the same
        /// shape for every view, so that is a Patch/toolchain bug — never the developer's code —
        /// and nothing is demoted for it (keeping the whole app native would silently turn Patch
        /// off); the caller reports it as a Patch bug instead.
        public var systemic: SystemicFailure?
        public init() {}
    }

    public struct SystemicFailure: Sendable, Equatable {
        /// Prepared views with an error (or compiler crash) in their generated code.
        public var failingViews: [String]
        /// Views prepared when it happened.
        public var preparedCount: Int
        /// At least one of those failures is a compiler crash.
        public var compilerCrash: Bool
        /// A representative diagnostic (a crash when there is one).
        public var example: Diagnostic
    }

    /// A build is systemic when strictly more than this share of the prepared views fail in
    /// generated code — and at least `systemicMinimumViews` do (two broken views out of three is
    /// still worth demoting individually).
    public static let systemicFraction = 0.5
    public static let systemicMinimumViews = 3

    /// The systemic-failure test (see `Report.systemic`): more than half of the prepared views (and
    /// at least `systemicMinimumViews`) fail in generated code in this build — OR a compiler crash
    /// in generated code hits a SECOND distinct view (`priorCrashViews` are views an earlier round
    /// demoted for one). A whole-module (Release) compile stops at its first crash, so a crash on
    /// the thunk pattern itself surfaces one view per build; the second is the proof.
    static func systemicFailure(_ attribution: Attribution, prepared: Set<String>,
                                readFile: (String) -> String?,
                                priorCrashViews: Set<String> = []) -> SystemicFailure? {
        var cache: [String: FileIndex] = [:]
        var failing: [String] = []
        var crash = false
        var example: Diagnostic?
        var crashViews = Set<String>()
        for (view, ds) in attribution.byView.sorted(by: { $0.key < $1.key }) where prepared.contains(view) {
            let generated = ds.filter { d in
                if d.message == compilerCrashMessage { return true }
                if cache[d.file] == nil, let text = readFile(d.file) { cache[d.file] = FileIndex(path: d.file, text: text) }
                return cache[d.file]?.isGenerated(line: d.line) ?? false
            }
            guard !generated.isEmpty else { continue }
            failing.append(view)
            if let c = generated.first(where: { $0.message == compilerCrashMessage }) {
                crash = true
                crashViews.insert(view)
                if example?.message != compilerCrashMessage { example = c }
            } else if example == nil {
                example = generated[0]
            }
        }
        guard let example else { return nil }
        let widespread = failing.count >= systemicMinimumViews
            && Double(failing.count) > Double(prepared.count) * systemicFraction
        let repeatedCrash = !crashViews.isEmpty && crashViews.union(priorCrashViews).count >= 2
        guard widespread || repeatedCrash else { return nil }
        let allFailing = repeatedCrash ? Array(Set(failing).union(priorCrashViews)).sorted() : failing
        return SystemicFailure(failingViews: allFailing, preparedCount: prepared.count + priorCrashViews.count,
                               compilerCrash: crash, example: example)
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
        // Views demoted in an earlier round for a compiler crash in their generated code.
        var crashDemoted = Set<String>()
        // Views whose triggering diagnostics were ALL in generated code when they were demoted.
        var generatedOnly = Set<String>()
        var indexCache: [String: FileIndex] = [:]
        func inGeneratedCode(_ d: Diagnostic) -> Bool {
            if d.message == compilerCrashMessage, (d.file as NSString).lastPathComponent == ThunkGenerator.thunkFileName {
                return true
            }
            if indexCache[d.file] == nil, let text = readFile(d.file) { indexCache[d.file] = FileIndex(path: d.file, text: text) }
            return indexCache[d.file]?.isGenerated(line: d.line) ?? false
        }

        for _ in 0..<maxIterations {
            let outcome = build()
            report.builds += 1
            if outcome.timedOut {
                report.timedOut = true
                progress("Build timed out after \(Int(outcome.seconds))s — verification stopped.")
                break
            }
            let diags = parseDiagnostics(outcome.log) + parseCompilerCrashes(outcome.log)
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
            //
            // Never for a view demoted ONLY for errors inside Patch-GENERATED code: removing the view
            // regenerates that code, so another view's generated code now sits at the same file:line
            // and can report the same message (the whole-module crash on the thunk pattern did exactly
            // that) — it is not evidence the error is the project's own.
            for (view, trig) in demotedFor where !generatedOnly.contains(view)
                && Set(trig.map(\.stableKey)).isSubset(of: present) {
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
            // SYSTEMIC: most prepared views fail in generated code in this one build → a Patch bug.
            // Stop without demoting (see `Report.systemic`).
            if var systemic = systemicFailure(attribution, prepared: prepared, readFile: readFile,
                                              priorCrashViews: crashDemoted) {
                // Undo the demotions earlier rounds made for generated-code crashes: they were the
                // same Patch bug (a whole-module build crashes once per build, so it surfaces one
                // view per round), not a problem with those views.
                let undo = crashDemoted.intersection(native)
                if !undo.isEmpty {
                    native.subtract(undo)
                    for v in undo { demotedFor[v] = nil }
                    demotionOrder.removeAll { undo.contains($0) }
                    prepared = try apply(native)
                }
                systemic.preparedCount = max(systemic.preparedCount, prepared.count)
                report.systemic = systemic
                report.unattributed = attribution.unattributed + attribution.byView.flatMap { $0.value }
                progress("\(systemic.failingViews.count) of \(systemic.preparedCount) prepared views "
                         + (systemic.compilerCrash ? "crash the Swift compiler in" : "fail in")
                         + " Patch-generated code (e.g. \(systemic.example)) — a Patch bug, not your code; "
                         + "no view was kept native for it.")
                break
            }
            // A re-promoted view is never demoted again in this run (guarantees termination).
            let newDemotes = attribution.byView.filter { !native.contains($0.key) && !repromoted.contains($0.key) }
            for (view, ds) in newDemotes.sorted(by: { $0.key < $1.key }) {
                if ds.contains(where: { $0.message == compilerCrashMessage }) { crashDemoted.insert(view) }
                if ds.allSatisfy(inGeneratedCode) { generatedOnly.insert(view) }
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
        if !report.clean && !report.timedOut && report.inconclusive == nil && report.systemic == nil
            && report.builds >= maxIterations {
            report.inconclusive = "stopped after \(maxIterations) builds"
        }
        report.demoted = demotionOrder.map { ($0, (demotedFor[$0] ?? []).sorted { $0.line < $1.line }) }
        report.preExisting = preExisting.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
        return report
    }
}
