// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Adds the Patch SDK dependency to a SwiftPM `Package.swift` — the
/// Swift-package counterpart of `XcodeProjectEditor`. Same philosophy:
/// a PURE string transform (`addPackage(to:targetName:)`) that throws
/// `.unsupported` for any shape it can't edit with certainty, plus an
/// `apply` orchestrator with backup → write → verify (`swift package
/// dump-package`) → restore-on-fail.
///
/// What "adding the package" means in manifest terms:
///   1. `.package(url: "https://github.com/patch-release/patch-swift", from: "1.0.0")`
///      appended to the PACKAGE-level `dependencies:` array (created before
///      `targets:` when the manifest has none), and
///   2. `.product(name: "PatchSDK", package: "patch-swift")` appended to the
///      chosen target's `dependencies:` array (created after its `name:`
///      argument when the target has none).
///
/// The scanner that locates those insertion points is string- and
/// comment-aware (a `[` inside a URL, string literal, or comment never
/// confuses the bracket depth), and only trusts labels found at the exact
/// argument depth they belong to — a target-level `dependencies:` is never
/// mistaken for the package-level one.
public enum PackageManifestEditor {

    public typealias EditResult = XcodeProjectEditor.EditResult
    public typealias EditError = XcodeProjectEditor.EditError

    public static let packageDependencyLine =
        ".package(url: \"\(XcodeProjectEditor.packageURL)\", from: \"\(XcodeProjectEditor.minimumVersion)\")"
    public static let productDependencyLine =
        ".product(name: \"\(XcodeProjectEditor.productName)\", package: \"\(XcodeProjectEditor.packageName)\")"

    // MARK: - Pure transform

    public static func addPackage(
        to manifest: String, targetName: String
    ) throws -> (result: EditResult, contents: String) {
        if manifest.contains("patch-release/patch-swift") {
            return (.alreadyPresent, manifest)
        }

        // Two independent edits. Each re-scans the (possibly already mutated)
        // text from scratch — String indices do not survive mutation, so no
        // range from one scan is ever used after an insertion.
        let afterTargetEdit = try addProductToTarget(in: manifest, targetName: targetName)
        let afterPackageEdit = try addPackageDependency(in: afterTargetEdit)
        return (.added, afterPackageEdit)
    }

    /// Append `.product(name: "PatchSDK", …)` to the target's dependencies.
    private static func addProductToTarget(in manifest: String, targetName: String) throws -> String {
        guard let packageCall = argumentRange(ofCall: "Package", in: manifest) else {
            throw EditError.unsupported(
                "Could not find the Package(...) initializer in Package.swift — "
                + "add the dependency manually (see the printed snippet).")
        }
        let packageArgs = labeledArguments(in: manifest, range: packageCall)
        guard let targetsArg = packageArgs["targets"] else {
            throw EditError.unsupported(
                "Package.swift has no targets: array — add the dependency manually.")
        }
        guard let targetCall = targetEntry(named: targetName, in: manifest,
                                           targetsArray: targetsArg.value) else {
            throw EditError.unsupported(
                "Could not find target `\(targetName)` in Package.swift — "
                + "add the dependency manually.")
        }
        let targetArgs = labeledArguments(in: manifest, range: targetCall)
        var text = manifest
        if let deps = targetArgs["dependencies"],
           let bracket = text.range(of: "[", range: deps.value) {
            text.insert(contentsOf: "\n                \(productDependencyLine),",
                        at: bracket.upperBound)
        } else if let nameArg = targetArgs["name"] {
            // No dependencies argument — append one right after the name
            // argument's value (back past any trailing whitespace so the comma
            // lands flush against the closing quote).
            var insertAt = nameArg.value.upperBound
            while insertAt > nameArg.value.lowerBound,
                  text[text.index(before: insertAt)].isWhitespace {
                insertAt = text.index(before: insertAt)
            }
            let insertion = ",\n            dependencies: [\n                \(productDependencyLine),\n            ]"
            text.insert(contentsOf: insertion, at: insertAt)
        } else {
            throw EditError.unsupported(
                "Target `\(targetName)` has no name: argument to anchor on — "
                + "add the dependency manually.")
        }
        return text
    }

    /// Append `.package(url: …patch-swift…)` to the package-level dependencies
    /// (creating the array before the `targets:` label when absent).
    private static func addPackageDependency(in manifest: String) throws -> String {
        guard let packageCall = argumentRange(ofCall: "Package", in: manifest) else {
            throw EditError.unsupported("Could not re-locate Package(...) after editing.")
        }
        let packageArgs = labeledArguments(in: manifest, range: packageCall)
        var text = manifest
        if let deps = packageArgs["dependencies"],
           let bracket = text.range(of: "[", range: deps.value) {
            text.insert(contentsOf: "\n        \(packageDependencyLine),", at: bracket.upperBound)
        } else if let targetsArg = packageArgs["targets"] {
            let block = "dependencies: [\n        \(packageDependencyLine),\n    ],\n    "
            text.insert(contentsOf: block, at: targetsArg.label.lowerBound)
        } else {
            throw EditError.unsupported("Could not re-locate targets: after editing.")
        }
        return text
    }

    // MARK: - File orchestration

    @discardableResult
    public static func apply(
        packageDir: URL, targetName: String, fm: FileManager = .default
    ) throws -> EditResult {
        let manifestURL = packageDir.appendingPathComponent("Package.swift")
        guard let original = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            throw EditError.unsupported("Could not read \(manifestURL.path).")
        }
        let (result, edited) = try addPackage(to: original, targetName: targetName)
        guard result == .added else { return result }

        let backupURL = manifestURL.appendingPathExtension(
            String(XcodeProjectEditor.backupSuffix.dropFirst()))
        try? fm.removeItem(at: backupURL)
        try original.write(to: backupURL, atomically: true, encoding: .utf8)
        try edited.write(to: manifestURL, atomically: true, encoding: .utf8)

        // Verify the edited manifest still evaluates (`swift package
        // dump-package` compiles it); restore the original on failure. A
        // missing/odd swift toolchain is NOT a failure — the backup exists and
        // the edit was made by the certainty-checked transform above.
        if let failure = dumpPackageFailure(packageDir: packageDir) {
            try? original.write(to: manifestURL, atomically: true, encoding: .utf8)
            throw EditError.verificationFailed(
                "Edited Package.swift failed `swift package dump-package` "
                + "(restored the original): \(failure)")
        }
        return .added
    }

    /// Run `swift package dump-package`; nil on success OR when the toolchain
    /// is unavailable/hung (can't verify ≠ broken), the error output when the
    /// manifest genuinely fails to evaluate.
    static func dumpPackageFailure(packageDir: URL, timeout: TimeInterval = 60) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        p.arguments = ["package", "dump-package"]
        p.currentDirectoryURL = packageDir
        let pipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = pipe
        do { try p.run() } catch { return nil }  // no toolchain — can't verify
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if p.isRunning {
            p.terminate()
            return nil  // hung toolchain — can't verify
        }
        guard p.terminationStatus != 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8) ?? ""
        return message.isEmpty ? "exit \(p.terminationStatus)" : message
    }

    // MARK: - Manifest scanning (internal for tests)

    /// The range of the argument list (between the parentheses, exclusive) of
    /// the first top-level call to `name(` — e.g. `Package(`.
    static func argumentRange(ofCall name: String, in text: String) -> Range<String.Index>? {
        var search = text.startIndex
        while let hit = text.range(of: "\(name)(", range: search..<text.endIndex) {
            // Word boundary on the left so `MyPackage(` doesn't match `Package(`.
            if hit.lowerBound == text.startIndex
                || !(text[text.index(before: hit.lowerBound)].isLetter
                     || text[text.index(before: hit.lowerBound)].isNumber
                     || text[text.index(before: hit.lowerBound)] == "_") {
                let open = text.index(before: hit.upperBound)
                if let close = matchingDelimiter(in: text, openingAt: open) {
                    return text.index(after: open)..<close
                }
            }
            search = hit.upperBound
        }
        return nil
    }

    /// The index of the delimiter closing the one at `open` (`(`→`)`, `[`→`]`),
    /// honoring string literals and comments.
    static func matchingDelimiter(in text: String, openingAt open: String.Index) -> String.Index? {
        let openCh = text[open]
        let closeCh: Character = openCh == "(" ? ")" : "]"
        var depth = 0
        var i = open
        var inString = false
        var inLineComment = false
        var inBlockComment = false
        var prev: Character = " "
        while i < text.endIndex {
            let ch = text[i]
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
                case openCh: depth += 1
                case closeCh:
                    depth -= 1
                    if depth == 0 { return i }
                default: break
                }
            }
            prev = ch
            i = text.index(after: i)
        }
        return nil
    }

    /// A labeled argument's location: the label token itself and its value
    /// (from the first non-whitespace after the `:` up to but not including
    /// the value-terminating top-level comma / list end).
    struct Argument {
        let label: Range<String.Index>
        let value: Range<String.Index>
    }

    /// The labeled arguments at the TOP nesting level of `range` (an argument
    /// list). Nested labels (inside brackets/parens/strings) are invisible here.
    static func labeledArguments(
        in text: String, range: Range<String.Index>
    ) -> [String: Argument] {
        var results: [String: Argument] = [:]
        var depth = 0
        var inString = false
        var inLineComment = false
        var inBlockComment = false
        var prev: Character = " "
        var i = range.lowerBound
        var pendingLabel: (name: String, range: Range<String.Index>)?
        var valueStart: String.Index?
        var wordStart: String.Index?

        func closeValue(at end: String.Index) {
            if let label = pendingLabel, let start = valueStart {
                results[label.name] = Argument(label: label.range, value: start..<end)
                pendingLabel = nil
                valueStart = nil
            }
        }

        while i < range.upperBound {
            let ch = text[i]
            if inLineComment {
                if ch == "\n" { inLineComment = false }
            } else if inBlockComment {
                if prev == "*" && ch == "/" { inBlockComment = false }
            } else if inString {
                if ch == "\"" && prev != "\\" { inString = false }
            } else {
                // A value starts at the first non-whitespace character after
                // the label's colon — INCLUDING `"`, `[`, `(` openers, which
                // the switch below also consumes (this must run first or
                // string/array values are never recorded).
                if pendingLabel != nil && valueStart == nil && !ch.isWhitespace && ch != ":" {
                    valueStart = i
                }
                switch ch {
                case "\"": inString = true; wordStart = nil
                case "/" where prev == "/": inLineComment = true
                case "*" where prev == "/": inBlockComment = true
                case "(", "[": depth += 1; wordStart = nil
                case ")", "]": depth -= 1; wordStart = nil
                case ",":
                    if depth == 0 { closeValue(at: i) }
                    wordStart = nil
                case ":":
                    if depth == 0, let ws = wordStart {
                        closeValue(at: ws)  // previous label's value ends where this one began
                        pendingLabel = (String(text[ws..<i]), ws..<i)
                        valueStart = nil
                        wordStart = nil
                    }
                default:
                    if ch.isLetter || ch.isNumber || ch == "_" {
                        if wordStart == nil { wordStart = i }
                    } else if !ch.isWhitespace {
                        wordStart = nil
                    }
                }
            }
            prev = ch
            i = text.index(after: i)
        }
        closeValue(at: range.upperBound)
        return results
    }

    /// The argument-list range of the `.target(...)`-style entry named
    /// `targetName` inside the targets array.
    static func targetEntry(
        named targetName: String, in text: String, targetsArray: Range<String.Index>
    ) -> Range<String.Index>? {
        var search = targetsArray.lowerBound
        while let dot = text.range(of: ".", range: search..<targetsArray.upperBound) {
            search = dot.upperBound
            // Read the entry kind (target / executableTarget / testTarget / …).
            var j = dot.upperBound
            while j < targetsArray.upperBound,
                  text[j].isLetter || text[j].isNumber || text[j] == "_" {
                j = text.index(after: j)
            }
            guard j < targetsArray.upperBound, text[j] == "(" else { continue }
            guard let close = matchingDelimiter(in: text, openingAt: j) else { return nil }
            let args = text.index(after: j)..<close
            let labels = labeledArguments(in: text, range: args)
            if let nameArg = labels["name"] {
                let value = text[nameArg.value].trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("\"\(targetName)\"") {
                    return args
                }
            }
            search = close
        }
        return nil
    }
}
