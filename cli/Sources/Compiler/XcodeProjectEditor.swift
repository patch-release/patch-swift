// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Adds the Patch SDK SwiftPM dependency to an Xcode project by editing
/// `project.pbxproj` directly — the "one less manual step" half of
/// `patchcli init`. Deliberately conservative:
///
///   - PURE string transform (`addPackage(to:targetName:)`) so every shape is
///     unit-testable; file IO + backup + `plutil -lint` verification live in
///     `apply(projectURL:targetName:)`.
///   - Any project shape it doesn't recognize with certainty throws
///     `.unsupported` — the caller falls back to printing the manual
///     Xcode steps. It must never write a guess.
///   - The original file is backed up first and restored on ANY verification
///     failure, so a failed attempt leaves the project byte-identical.
///
/// What "adding the package" means in pbxproj terms (exactly what Xcode's
/// File ▸ Add Package Dependencies… writes):
///   1. an `XCRemoteSwiftPackageReference` (the repo URL + version rule),
///   2. an `XCSwiftPackageProductDependency` (the `PatchSDK` product),
///   3. a `PBXBuildFile` linking that product,
///   4. the reference appended to the project's `packageReferences`,
///   5. the product appended to the target's `packageProductDependencies`,
///   6. the build file appended to the target's Frameworks build phase.
public enum XcodeProjectEditor {

    public static let packageURL = "https://github.com/patch-release/patch-swift"
    public static let packageName = "patch-swift"
    public static let productName = "PatchSDK"
    public static let minimumVersion = "1.0.0"

    public enum EditResult: Sendable, Equatable {
        case added
        /// The project already references patch-swift / PatchSDK — nothing to do.
        case alreadyPresent
    }

    public enum EditError: Error, CustomStringConvertible, Equatable {
        case unsupported(String)
        case verificationFailed(String)

        public var description: String {
            switch self {
            case .unsupported(let m): return m
            case .verificationFailed(let m): return m
            }
        }
    }

    // MARK: - Pure transform

    /// Add the Patch package to `pbxproj` (the raw file text), wiring it into
    /// the target named `targetName`. Returns the new text, or
    /// `.alreadyPresent` via the result when nothing needs doing.
    public static func addPackage(
        to pbxproj: String, targetName: String
    ) throws -> (result: EditResult, contents: String) {
        guard pbxproj.hasPrefix("// !$*UTF8*$!") else {
            throw EditError.unsupported(
                "project.pbxproj is not in the OpenStep plist format Xcode writes "
                + "(unexpected header) — add the package in Xcode instead.")
        }
        if pbxproj.contains(packageURL) || pbxproj.contains("patch-release/patch-swift") {
            return (.alreadyPresent, pbxproj)
        }

        let refID = generateID(excluding: pbxproj)
        let prodID = generateID(excluding: pbxproj + refID)
        let fileID = generateID(excluding: pbxproj + refID + prodID)
        var text = pbxproj

        // --- locate the target block -------------------------------------
        guard let targetRange = nativeTargetBlockRange(in: text, targetName: targetName) else {
            throw EditError.unsupported(
                "Could not find target `\(targetName)` in project.pbxproj — "
                + "add the package in Xcode instead.")
        }
        let targetBlock = String(text[targetRange])

        // --- find the target's Frameworks build phase ---------------------
        guard let frameworksPhaseID = buildPhaseID(inTargetBlock: targetBlock, comment: "Frameworks") else {
            throw EditError.unsupported(
                "Target `\(targetName)` has no Frameworks build phase — "
                + "add the package in Xcode instead.")
        }

        // 1. XCRemoteSwiftPackageReference entry (create section if missing).
        let refEntry = """
        \t\t\(refID) /* XCRemoteSwiftPackageReference "\(packageName)" */ = {
        \t\t\tisa = XCRemoteSwiftPackageReference;
        \t\t\trepositoryURL = "\(packageURL)";
        \t\t\trequirement = {
        \t\t\t\tkind = upToNextMajorVersion;
        \t\t\t\tminimumVersion = \(minimumVersion);
        \t\t\t};
        \t\t};
        """
        text = try insert(entry: refEntry, intoSection: "XCRemoteSwiftPackageReference", of: text)

        // 2. XCSwiftPackageProductDependency entry.
        let prodEntry = """
        \t\t\(prodID) /* \(productName) */ = {
        \t\t\tisa = XCSwiftPackageProductDependency;
        \t\t\tpackage = \(refID) /* XCRemoteSwiftPackageReference "\(packageName)" */;
        \t\t\tproductName = \(productName);
        \t\t};
        """
        text = try insert(entry: prodEntry, intoSection: "XCSwiftPackageProductDependency", of: text)

        // 3. PBXBuildFile entry.
        let buildFileEntry =
            "\t\t\(fileID) /* \(productName) in Frameworks */ = "
            + "{isa = PBXBuildFile; productRef = \(prodID) /* \(productName) */; };"
        text = try insert(entry: buildFileEntry, intoSection: "PBXBuildFile", of: text)

        // 4. project packageReferences.
        text = try addProjectPackageReference(refID: refID, to: text)

        // 5. target packageProductDependencies. (Re-locate the block — the
        //    insertions above shifted offsets.)
        text = try addTargetProductDependency(prodID: prodID, targetName: targetName, to: text)

        // 6. Frameworks phase files list.
        text = try addBuildFileToFrameworksPhase(fileID: fileID, phaseID: frameworksPhaseID, to: text)

        return (.added, text)
    }

    // MARK: - File orchestration (backup → write → verify → restore-on-fail)

    /// The on-disk backup suffix; left in place after a SUCCESSFUL edit too, so
    /// a developer can always diff/revert what `patchcli init` changed.
    public static let backupSuffix = ".patch-backup"

    @discardableResult
    public static func apply(
        projectURL: URL, targetName: String, fm: FileManager = .default
    ) throws -> EditResult {
        let pbxprojURL = projectURL.appendingPathComponent("project.pbxproj")
        guard let original = try? String(contentsOf: pbxprojURL, encoding: .utf8) else {
            throw EditError.unsupported("Could not read \(pbxprojURL.path).")
        }
        let (result, edited) = try addPackage(to: original, targetName: targetName)
        guard result == .added else { return result }

        let backupURL = pbxprojURL.appendingPathExtension(String(backupSuffix.dropFirst()))
        try? fm.removeItem(at: backupURL)
        try original.write(to: backupURL, atomically: true, encoding: .utf8)
        try edited.write(to: pbxprojURL, atomically: true, encoding: .utf8)

        // Verify the edited plist still parses; restore the original on failure.
        if let lintError = plutilLint(pbxprojURL) {
            try? original.write(to: pbxprojURL, atomically: true, encoding: .utf8)
            throw EditError.verificationFailed(
                "Edited project.pbxproj failed plist validation (restored the original): \(lintError)")
        }
        return .added
    }

    /// `plutil -lint` the file; nil on success, the error output on failure.
    static func plutilLint(_ url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        p.arguments = ["-lint", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "could not run plutil: \(error)" }
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? "plutil exited \(p.terminationStatus)"
    }

    // MARK: - Pieces (internal for tests)

    /// A fresh 24-hex-uppercase object ID not already present in `excluding`.
    static func generateID(excluding existing: String) -> String {
        while true {
            let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let id = String(raw.prefix(24))
            if !existing.contains(id) { return id }
        }
    }

    /// Insert `entry` into `/* Begin <section> section */ … /* End … */`,
    /// creating the section when the project has none (alphabetical placement
    /// is an Xcode aesthetic, not a requirement — appended after the last
    /// existing section).
    static func insert(entry: String, intoSection section: String, of text: String) throws -> String {
        let begin = "/* Begin \(section) section */"
        if let range = text.range(of: begin) {
            var out = text
            out.insert(contentsOf: "\n" + entry, at: range.upperBound)
            return out
        }
        // Section absent — create it after the LAST `/* End … section */`.
        guard let lastEnd = text.range(of: " section */", options: .backwards),
              let lineEnd = text.range(of: "\n", range: lastEnd.upperBound..<text.endIndex) else {
            throw EditError.unsupported(
                "project.pbxproj has no recognizable object sections — add the package in Xcode instead.")
        }
        let block = "\n\(begin)\n\(entry)\n/* End \(section) section */\n"
        var out = text
        out.insert(contentsOf: block, at: lineEnd.lowerBound)
        return out
    }

    /// The `\t\tID /* name */ = { … };` block for the PBXNativeTarget named
    /// `targetName` (quoted or bare), within the PBXNativeTarget section.
    static func nativeTargetBlockRange(in text: String, targetName: String) -> Range<String.Index>? {
        guard let sectionStart = text.range(of: "/* Begin PBXNativeTarget section */"),
              let sectionEnd = text.range(of: "/* End PBXNativeTarget section */") else { return nil }
        let section = sectionStart.upperBound..<sectionEnd.lowerBound

        var searchStart = section.lowerBound
        while let open = text.range(of: " = {", range: searchStart..<section.upperBound) {
            // Block body runs to the matching "\n\t\t};".
            guard let close = text.range(of: "\n\t\t};", range: open.upperBound..<section.upperBound) else {
                return nil
            }
            // Block start: walk back to the beginning of the line containing `open`.
            var lineStart = open.lowerBound
            while lineStart > section.lowerBound && text[text.index(before: lineStart)] != "\n" {
                lineStart = text.index(before: lineStart)
            }
            let block = text[lineStart..<close.upperBound]
            if block.contains("name = \(targetName);") || block.contains("name = \"\(targetName)\";") {
                return lineStart..<close.upperBound
            }
            searchStart = close.upperBound
        }
        return nil
    }

    /// The build-phase object ID annotated `/* <comment> */` in the target
    /// block's `buildPhases = ( … );` list.
    static func buildPhaseID(inTargetBlock block: String, comment: String) -> String? {
        guard let phasesStart = block.range(of: "buildPhases = (") else { return nil }
        guard let phasesEnd = block.range(of: ");", range: phasesStart.upperBound..<block.endIndex) else {
            return nil
        }
        let list = block[phasesStart.upperBound..<phasesEnd.lowerBound]
        for line in list.split(separator: "\n") {
            if line.contains("/* \(comment) */"),
               let id = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first {
                return String(id)
            }
        }
        return nil
    }

    /// Append `refID` to the PBXProject's `packageReferences` list, creating
    /// the list (after `mainGroup = …;`) when the project has no packages yet.
    static func addProjectPackageReference(refID: String, to text: String) throws -> String {
        guard let sectionStart = text.range(of: "/* Begin PBXProject section */"),
              let sectionEnd = text.range(of: "/* End PBXProject section */") else {
            throw EditError.unsupported(
                "project.pbxproj has no PBXProject section — add the package in Xcode instead.")
        }
        let refLine = "\t\t\t\t\(refID) /* XCRemoteSwiftPackageReference \"\(packageName)\" */,"
        var out = text
        if let listStart = text.range(of: "packageReferences = (",
                                      range: sectionStart.upperBound..<sectionEnd.lowerBound) {
            out.insert(contentsOf: "\n" + refLine, at: listStart.upperBound)
            return out
        }
        // No packageReferences list yet — add one after the mainGroup line.
        guard let mainGroup = text.range(of: "mainGroup = ",
                                         range: sectionStart.upperBound..<sectionEnd.lowerBound),
              let lineEnd = text.range(of: "\n", range: mainGroup.upperBound..<sectionEnd.lowerBound) else {
            throw EditError.unsupported(
                "Could not find the project's mainGroup — add the package in Xcode instead.")
        }
        let listBlock = "\t\t\tpackageReferences = (\n\(refLine)\n\t\t\t);\n"
        out.insert(contentsOf: listBlock, at: lineEnd.upperBound)
        return out
    }

    /// Append `prodID` to the target's `packageProductDependencies` list,
    /// creating the list (after the `name = …;` line) when absent.
    static func addTargetProductDependency(prodID: String, targetName: String, to text: String) throws -> String {
        guard let targetRange = nativeTargetBlockRange(in: text, targetName: targetName) else {
            throw EditError.unsupported("Could not re-locate target `\(targetName)` after editing.")
        }
        let block = String(text[targetRange])
        let prodLine = "\t\t\t\t\(prodID) /* \(productName) */,"
        var newBlock = block
        if let listStart = block.range(of: "packageProductDependencies = (") {
            newBlock.insert(contentsOf: "\n" + prodLine, at: listStart.upperBound)
        } else if let nameLine = block.range(of: "name = \(targetName);")
                    ?? block.range(of: "name = \"\(targetName)\";"),
                  let lineEnd = block.range(of: "\n", range: nameLine.upperBound..<block.endIndex) {
            let listBlock = "\t\t\tpackageProductDependencies = (\n\(prodLine)\n\t\t\t);\n"
            newBlock.insert(contentsOf: listBlock, at: lineEnd.upperBound)
        } else {
            throw EditError.unsupported(
                "Could not find an insertion point in target `\(targetName)` — add the package in Xcode instead.")
        }
        return text.replacingCharacters(in: targetRange, with: newBlock)
    }

    /// Append `fileID` to the `files = ( … );` list of the Frameworks build
    /// phase object `phaseID`.
    static func addBuildFileToFrameworksPhase(fileID: String, phaseID: String, to text: String) throws -> String {
        guard let phaseStart = text.range(of: "\t\t\(phaseID) ") else {
            throw EditError.unsupported(
                "Could not find the Frameworks build phase — add the package in Xcode instead.")
        }
        guard let filesStart = text.range(of: "files = (", range: phaseStart.upperBound..<text.endIndex) else {
            throw EditError.unsupported(
                "The Frameworks build phase has no files list — add the package in Xcode instead.")
        }
        let fileLine = "\t\t\t\t\(fileID) /* \(productName) in Frameworks */,"
        var out = text
        out.insert(contentsOf: "\n" + fileLine, at: filesStart.upperBound)
        return out
    }
}
