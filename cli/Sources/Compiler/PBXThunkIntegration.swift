// SPDX-License-Identifier: Apache-2.0

// PBXThunkIntegration.swift — the project-surgery backend for ProjectIntegrator.
// Adds the generated thunk file to an Xcode target's Sources build phase and
// links the PatchSwiftUI product; ensures a SwiftPM target depends on it.
//
// Philosophy is identical to `XcodeProjectEditor` (whose lower-level helpers
// this reuses): PURE string transforms whose insertion points are located with
// certainty, an `apply`-style orchestrator that backs the file up first and
// restores it byte-for-byte on ANY `plutil -lint` failure, and `.unsupported`
// (never a guess) for any shape it can't edit safely.
//
// Two pbxproj group shapes are handled for the generated thunk file:
//
//   • CLASSIC groups — the file is NOT in the compile set until it has an
//     explicit `PBXFileReference` + `PBXBuildFile` in the target's Sources
//     phase, so we add all three (ref, build file, group membership).
//
//   • SYNCHRONIZED groups (Xcode 16 `PBXFileSystemSynchronizedRootGroup`) — if
//     the target owns a synchronized root group whose folder, on disk, CONTAINS
//     the generated file, Xcode auto-includes the file by location. Adding a
//     PBXBuildFile/PBXFileReference too would double-compile it ("duplicate
//     symbol" / redeclaration), so in that case we add NOTHING for the file and
//     only ensure the product link.

import Foundation

enum PBXThunkIntegration {

    // The product this wires in is PatchSwiftUI (the SwiftUI renderer), a
    // sibling product of the same `patch-swift` package XcodeProjectEditor adds.
    static let productName = "PatchSwiftUI"
    static let packageName = XcodeProjectEditor.packageName   // "patch-swift"
    static let packageURL  = XcodeProjectEditor.packageURL
    static let minimumVersion = XcodeProjectEditor.minimumVersion

    typealias Outcome = ProjectIntegrator.Outcome
    typealias Err = ProjectIntegrator.IntegratorError

    // MARK: - xcodeproj wiring

    static func wire(projectURL: URL, target: String, fileURL: URL, fm: FileManager) throws -> Outcome {
        let pbxprojURL = projectURL.appendingPathComponent("project.pbxproj")
        guard let original = try? String(contentsOf: pbxprojURL, encoding: .utf8) else {
            throw Err.unsupported("Could not read \(pbxprojURL.path).")
        }
        let (outcome, edited) = try transform(
            pbxproj: original, projectURL: projectURL, target: target, fileURL: fileURL, fm: fm)
        guard outcome == .added else { return outcome }

        // backup → write → plutil-lint verify → restore-on-fail (mirrors
        // XcodeProjectEditor.apply exactly).
        let backupURL = pbxprojURL.appendingPathExtension(
            String(XcodeProjectEditor.backupSuffix.dropFirst()))
        try? fm.removeItem(at: backupURL)
        try original.write(to: backupURL, atomically: true, encoding: .utf8)
        try edited.write(to: pbxprojURL, atomically: true, encoding: .utf8)

        if let lintError = XcodeProjectEditor.plutilLint(pbxprojURL) {
            try? original.write(to: pbxprojURL, atomically: true, encoding: .utf8)
            throw Err.unsupported(
                "Edited project.pbxproj failed plist validation (restored the original): \(lintError)")
        }
        return .added
    }

    /// Pure transform: returns `.alreadyPresent` (with the text unchanged) when
    /// both the file membership and the product link are already in place, or
    /// `.added` with the edited text. Throws `.unsupported` for any shape it
    /// cannot edit with certainty.
    ///
    /// `fileURL`/`projectURL`/`fm` are only consulted to decide whether the file
    /// lives inside a synchronized root group's folder (a disk question); the
    /// rest is a string transform so it stays unit-testable.
    static func transform(
        pbxproj: String, projectURL: URL, target: String, fileURL: URL, fm: FileManager
    ) throws -> (Outcome, String) {
        guard pbxproj.hasPrefix("// !$*UTF8*$!") else {
            throw Err.unsupported(
                "project.pbxproj is not in the OpenStep plist format Xcode writes "
                + "(unexpected header) — wire the file in Xcode instead.")
        }
        guard let targetRange = XcodeProjectEditor.nativeTargetBlockRange(in: pbxproj, targetName: target) else {
            throw Err.unsupported(
                "Could not find target `\(target)` in project.pbxproj — wire the file in Xcode instead.")
        }
        let targetBlock = String(pbxproj[targetRange])

        var text = pbxproj
        var didChange = false

        // ---- 1. The generated source file --------------------------------
        // Synchronized folder? If the target owns a synchronized root group
        // whose folder on disk contains fileURL, the file is auto-included; we
        // must NOT add a ref/build file for it.
        let autoIncluded = fileIsInSynchronizedGroup(
            of: targetBlock, pbxproj: text, projectURL: projectURL, fileURL: fileURL, fm: fm)

        if autoIncluded {
            // Nothing to add for the file — only the product link below.
        } else if fileAlreadyInTarget(text, targetBlock: targetBlock, fileURL: fileURL, projectURL: projectURL) {
            // Already an explicit member of this target's Sources phase.
        } else {
            text = try addSourceFile(to: text, target: target, fileURL: fileURL, projectURL: projectURL)
            didChange = true
        }

        // ---- 2. The PatchSwiftUI product link ----------------------------
        if productAlreadyLinked(text, targetName: target) {
            // Already linked to this target.
        } else {
            text = try addProductLink(to: text, target: target)
            didChange = true
        }

        return (didChange ? .added : .alreadyPresent, text)
    }

    // MARK: - Synchronized-group detection

    /// True when `target`'s block lists a `fileSystemSynchronizedGroups` entry
    /// for a `PBXFileSystemSynchronizedRootGroup` whose resolved folder on disk
    /// is an ancestor of `fileURL`. Conservative: any uncertainty (no synced
    /// groups, unresolved path) → false (we then add an explicit reference,
    /// which is correct for classic groups).
    static func fileIsInSynchronizedGroup(
        of targetBlock: String, pbxproj: String, projectURL: URL, fileURL: URL, fm: FileManager
    ) -> Bool {
        let syncedIDs = synchronizedGroupIDs(inTargetBlock: targetBlock)
        guard !syncedIDs.isEmpty else { return false }

        let file = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        // The project bundle (Foo.xcodeproj) sits beside the source tree; the
        // SOURCE_ROOT a synchronized group's relative path resolves against is
        // the directory CONTAINING the .xcodeproj.
        let sourceRoot = projectURL.deletingLastPathComponent()

        for id in syncedIDs {
            guard let folder = synchronizedRootGroupPath(
                id: id, pbxproj: pbxproj, sourceRoot: sourceRoot) else { continue }
            let folderResolved = folder.standardizedFileURL.resolvingSymlinksInPath()
            if isDescendant(file, of: folderResolved) { return true }
        }
        return false
    }

    /// Object IDs in the target block's `fileSystemSynchronizedGroups = ( … );`.
    static func synchronizedGroupIDs(inTargetBlock block: String) -> [String] {
        guard let start = block.range(of: "fileSystemSynchronizedGroups = (") else { return [] }
        guard let end = block.range(of: ");", range: start.upperBound..<block.endIndex) else { return [] }
        let list = block[start.upperBound..<end.lowerBound]
        var ids: [String] = []
        for line in list.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // `ID /* comment */,`  → take the leading token.
            if let id = trimmed.split(whereSeparator: { $0 == " " || $0 == "," }).first {
                ids.append(String(id))
            }
        }
        return ids
    }

    /// Resolve a `PBXFileSystemSynchronizedRootGroup`'s on-disk folder URL.
    /// Honors `sourceTree = "<group>"` / `SOURCE_ROOT` (both relative to the
    /// directory containing the .xcodeproj for a *root* group) and an absolute
    /// `sourceTree = "<absolute>"`. Returns nil if the object isn't a
    /// synchronized root group or has no usable path.
    static func synchronizedRootGroupPath(
        id: String, pbxproj: String, sourceRoot: URL
    ) -> URL? {
        guard let block = objectBlock(id: id, in: pbxproj) else { return nil }
        guard block.contains("isa = PBXFileSystemSynchronizedRootGroup;") else { return nil }
        guard let path = quotedOrBareValue(of: "path", in: block) else {
            // A root group with no `path` maps directly onto the source root.
            return sourceRoot
        }
        let tree = quotedOrBareValue(of: "sourceTree", in: block) ?? "<group>"
        if tree == "<absolute>" || path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        // "<group>" for a ROOT group, and SOURCE_ROOT, both anchor at the
        // directory containing the project bundle.
        return sourceRoot.appendingPathComponent(path)
    }

    /// `a` is `b` itself or nested anywhere beneath it.
    static func isDescendant(_ a: URL, of b: URL) -> Bool {
        let ac = a.standardizedFileURL.pathComponents
        let bc = b.standardizedFileURL.pathComponents
        guard ac.count >= bc.count else { return false }
        return Array(ac.prefix(bc.count)) == bc
    }

    // MARK: - Classic-group source-file insertion

    /// A path for `fileURL` expressed relative to the directory that contains
    /// the `.xcodeproj` (the conventional SOURCE_ROOT). Falls back to the last
    /// path component (with SOURCE_ROOT sourceTree) when it isn't a descendant.
    static func projectRelativePath(of fileURL: URL, projectURL: URL) -> (path: String, sourceTree: String) {
        let sourceRoot = projectURL.deletingLastPathComponent().standardizedFileURL
        let file = fileURL.standardizedFileURL
        let rootComps = sourceRoot.pathComponents
        let fileComps = file.pathComponents
        if fileComps.count > rootComps.count, Array(fileComps.prefix(rootComps.count)) == rootComps {
            let rel = fileComps.dropFirst(rootComps.count).joined(separator: "/")
            return (rel, "SOURCE_ROOT")
        }
        // Not under the source root — reference it by name; Xcode resolves
        // group-relative refs against the enclosing group, which for our newly
        // added ref is the main group at the source root.
        return (file.lastPathComponent, "SOURCE_ROOT")
    }

    /// True when the target's Sources phase already lists a build file whose
    /// referenced PBXFileReference path matches `fileURL` — i.e. the file is
    /// already an explicit member of THIS target. Idempotency guard.
    static func fileAlreadyInTarget(
        _ text: String, targetBlock: String, fileURL: URL, projectURL: URL
    ) -> Bool {
        guard let sourcesPhaseID = XcodeProjectEditor.buildPhaseID(inTargetBlock: targetBlock, comment: "Sources"),
              let phaseFiles = buildPhaseFileIDs(text, phaseID: sourcesPhaseID) else {
            return false
        }
        let base = fileURL.lastPathComponent
        for fileID in phaseFiles {
            guard let buildFile = objectInline(id: fileID, in: text),
                  let fileRef = inlineFieldValue("fileRef", in: buildFile) else { continue }
            if let ref = objectInline(id: fileRef, in: text),
               let refPath = inlineFieldValue("path", in: ref) {
                let refBase = (refPath as NSString).lastPathComponent
                if refBase == base { return true }
            }
        }
        return false
    }

    /// Add `fileURL` to `target`'s Sources phase: a PBXFileReference, a
    /// PBXBuildFile that references it, the build file into the Sources phase
    /// files list, and the file ref into the project's main group.
    static func addSourceFile(
        to text: String, target: String, fileURL: URL, projectURL: URL
    ) throws -> String {
        guard let targetRange = XcodeProjectEditor.nativeTargetBlockRange(in: text, targetName: target) else {
            throw Err.unsupported("Could not re-locate target `\(target)`.")
        }
        let targetBlock = String(text[targetRange])
        guard let sourcesPhaseID = XcodeProjectEditor.buildPhaseID(inTargetBlock: targetBlock, comment: "Sources") else {
            throw Err.unsupported(
                "Target `\(target)` has no Sources build phase — wire the file in Xcode instead.")
        }

        let refID = XcodeProjectEditor.generateID(excluding: text)
        let buildID = XcodeProjectEditor.generateID(excluding: text + refID)
        let name = fileURL.lastPathComponent
        let (relPath, sourceTree) = projectRelativePath(of: fileURL, projectURL: projectURL)

        var out = text

        // PBXFileReference.
        let refEntry =
            "\t\t\(refID) /* \(name) */ = {isa = PBXFileReference; "
            + "lastKnownFileType = sourcecode.swift; "
            + (relPath == name
               ? "path = \(plistQuote(relPath)); "
               : "name = \(plistQuote(name)); path = \(plistQuote(relPath)); ")
            + "sourceTree = \(sourceTree == "SOURCE_ROOT" ? "SOURCE_ROOT" : plistQuote(sourceTree)); };"
        out = try insertObject(refEntry, intoSection: "PBXFileReference", of: out)

        // PBXBuildFile.
        let buildEntry =
            "\t\t\(buildID) /* \(name) in Sources */ = "
            + "{isa = PBXBuildFile; fileRef = \(refID) /* \(name) */; };"
        out = try insertObject(buildEntry, intoSection: "PBXBuildFile", of: out)

        // Sources phase files list.
        out = try addBuildFileToPhase(
            fileID: buildID, phaseID: sourcesPhaseID, comment: "\(name) in Sources", to: out)

        // Group membership: append the ref to the project's main group so it's
        // visible in the navigator (purely cosmetic, but keeps the project tidy
        // and avoids an "orphaned reference" warning).
        out = addFileRefToMainGroup(refID: refID, name: name, to: out)

        return out
    }

    // MARK: - PatchSwiftUI product link

    /// True when `targetName` already lists a packageProductDependency whose
    /// XCSwiftPackageProductDependency is the PatchSwiftUI product (regardless
    /// of which patch-swift reference it points at). Idempotency guard.
    static func productAlreadyLinked(_ text: String, targetName: String) -> Bool {
        guard let targetRange = XcodeProjectEditor.nativeTargetBlockRange(in: text, targetName: targetName) else {
            return false
        }
        let block = String(text[targetRange])
        guard let deps = productDependencyIDs(inTargetBlock: block) else { return false }
        for id in deps {
            guard let obj = objectBlock(id: id, in: text),
                  obj.contains("isa = XCSwiftPackageProductDependency;") else { continue }
            if let prod = quotedOrBareValue(of: "productName", in: obj), prod == productName {
                return true
            }
        }
        return false
    }

    /// Add the PatchSwiftUI product link to `target`: ensure an
    /// XCRemoteSwiftPackageReference for patch-swift exists (creating it +
    /// wiring it into the project's packageReferences if missing), add an
    /// XCSwiftPackageProductDependency for "PatchSwiftUI", a PBXBuildFile that
    /// references the product (NO fileRef — a productRef build file), then wire
    /// the product into the target's packageProductDependencies and Frameworks
    /// phase.
    static func addProductLink(to text: String, target: String) throws -> String {
        guard let targetRange = XcodeProjectEditor.nativeTargetBlockRange(in: text, targetName: target) else {
            throw Err.unsupported("Could not find target `\(target)`.")
        }
        let targetBlock = String(text[targetRange])
        guard let frameworksPhaseID = XcodeProjectEditor.buildPhaseID(inTargetBlock: targetBlock, comment: "Frameworks") else {
            throw Err.unsupported(
                "Target `\(target)` has no Frameworks build phase — link the product in Xcode instead.")
        }

        var out = text

        // 1. Reuse an existing patch-swift XCRemoteSwiftPackageReference if the
        //    project already has one (e.g. from a prior PatchSDK add); otherwise
        //    create it + add it to the project's packageReferences.
        let refID: String
        if let existing = existingPatchSwiftReferenceID(out) {
            refID = existing
        } else {
            refID = XcodeProjectEditor.generateID(excluding: out)
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
            out = try insertObject(refEntry, intoSection: "XCRemoteSwiftPackageReference", of: out)
            out = try XcodeProjectEditor.addProjectPackageReference(refID: refID, to: out)
        }

        // 2. XCSwiftPackageProductDependency for PatchSwiftUI.
        let prodID = XcodeProjectEditor.generateID(excluding: out + refID)
        let prodEntry = """
        \t\t\(prodID) /* \(productName) */ = {
        \t\t\tisa = XCSwiftPackageProductDependency;
        \t\t\tpackage = \(refID) /* XCRemoteSwiftPackageReference "\(packageName)" */;
        \t\t\tproductName = \(productName);
        \t\t};
        """
        out = try insertObject(prodEntry, intoSection: "XCSwiftPackageProductDependency", of: out)

        // 3. PBXBuildFile referencing the PRODUCT (productRef) — NO fileRef.
        //    This is the shape generic pbxproj tooling chokes on; we emit it
        //    explicitly.
        let buildID = XcodeProjectEditor.generateID(excluding: out + refID + prodID)
        let buildEntry =
            "\t\t\(buildID) /* \(productName) in Frameworks */ = "
            + "{isa = PBXBuildFile; productRef = \(prodID) /* \(productName) */; };"
        out = try insertObject(buildEntry, intoSection: "PBXBuildFile", of: out)

        // 4. target packageProductDependencies (re-locate — offsets shifted).
        out = try addTargetProductDependency(prodID: prodID, targetName: target, to: out)

        // 5. Frameworks phase files list.
        out = try addBuildFileToPhase(
            fileID: buildID, phaseID: frameworksPhaseID, comment: "\(productName) in Frameworks", to: out)

        return out
    }

    /// The object ID of an EXISTING patch-swift XCRemoteSwiftPackageReference,
    /// if the project already references the package. (Lets a second product
    /// from the same package share one reference rather than duplicating it.)
    static func existingPatchSwiftReferenceID(_ text: String) -> String? {
        guard let sectionStart = text.range(of: "/* Begin XCRemoteSwiftPackageReference section */"),
              let sectionEnd = text.range(of: "/* End XCRemoteSwiftPackageReference section */") else {
            return nil
        }
        let section = String(text[sectionStart.upperBound..<sectionEnd.lowerBound])
        // Walk each `ID /* … */ = { … };` block; return the first whose
        // repositoryURL is patch-swift.
        var search = section.startIndex
        while let eq = section.range(of: " = {", range: search..<section.endIndex) {
            guard let close = section.range(of: "\n\t\t};", range: eq.upperBound..<section.endIndex) else { break }
            var lineStart = eq.lowerBound
            while lineStart > section.startIndex && section[section.index(before: lineStart)] != "\n" {
                lineStart = section.index(before: lineStart)
            }
            let block = section[lineStart..<close.upperBound]
            if block.contains(packageURL) || block.contains("patch-release/patch-swift") {
                let token = block.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first
                if let token { return String(token) }
            }
            search = close.upperBound
        }
        return nil
    }

    // MARK: - Target-block helpers (PatchSwiftUI-named; mirror XcodeProjectEditor)

    /// Object IDs in the target block's `packageProductDependencies = ( … );`.
    static func productDependencyIDs(inTargetBlock block: String) -> [String]? {
        guard let start = block.range(of: "packageProductDependencies = (") else { return nil }
        guard let end = block.range(of: ");", range: start.upperBound..<block.endIndex) else { return nil }
        let list = block[start.upperBound..<end.lowerBound]
        var ids: [String] = []
        for line in list.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let id = trimmed.split(whereSeparator: { $0 == " " || $0 == "," }).first {
                ids.append(String(id))
            }
        }
        return ids
    }

    /// Append `prodID` to the target's `packageProductDependencies` list,
    /// creating it after the `name = …;` line when absent. (XcodeProjectEditor's
    /// equivalent hard-codes the PatchSDK comment, so we carry our own.)
    static func addTargetProductDependency(prodID: String, targetName: String, to text: String) throws -> String {
        guard let targetRange = XcodeProjectEditor.nativeTargetBlockRange(in: text, targetName: targetName) else {
            throw Err.unsupported("Could not re-locate target `\(targetName)` after editing.")
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
            throw Err.unsupported(
                "Could not find an insertion point in target `\(targetName)` — link the product in Xcode instead.")
        }
        return text.replacingCharacters(in: targetRange, with: newBlock)
    }

    /// Append `fileID` to the `files = ( … );` list of build phase `phaseID`,
    /// annotated with `comment`. Works for any phase (Sources / Frameworks).
    static func addBuildFileToPhase(
        fileID: String, phaseID: String, comment: String, to text: String
    ) throws -> String {
        // Anchor on the phase OBJECT definition (`\n\t\tID `), not a stray
        // sub-string match against the trailing two tabs of a 4-tab membership
        // reference (which would otherwise win when the phase is defined AFTER
        // it is referenced).
        guard let phaseStart = objectDefinitionStart(id: phaseID, in: text) else {
            throw Err.unsupported("Could not find build phase \(phaseID).")
        }
        guard let filesStart = text.range(of: "files = (", range: phaseStart..<text.endIndex) else {
            throw Err.unsupported("Build phase \(phaseID) has no files list.")
        }
        let fileLine = "\t\t\t\t\(fileID) /* \(comment) */,"
        var out = text
        out.insert(contentsOf: "\n" + fileLine, at: filesStart.upperBound)
        return out
    }

    /// Append a PBXFileReference id to the project's main PBXGroup `children`
    /// list, so the navigator shows it. Best-effort: returns the text unchanged
    /// if the main group can't be located (the file is still in the compile set
    /// via the Sources phase — group membership is cosmetic).
    static func addFileRefToMainGroup(refID: String, name: String, to text: String) -> String {
        // Find the PBXProject's mainGroup id.
        guard let projStart = text.range(of: "/* Begin PBXProject section */"),
              let projEnd = text.range(of: "/* End PBXProject section */"),
              let mg = text.range(of: "mainGroup = ", range: projStart.upperBound..<projEnd.lowerBound) else {
            return text
        }
        var idEnd = mg.upperBound
        while idEnd < text.endIndex, text[idEnd] != ";" && text[idEnd] != " " { idEnd = text.index(after: idEnd) }
        let mainGroupID = String(text[mg.upperBound..<idEnd])
        guard !mainGroupID.isEmpty,
              let groupBlock = objectBlockRange(id: mainGroupID, in: text) else {
            return text
        }
        let block = String(text[groupBlock])
        guard let childrenStart = block.range(of: "children = (") else { return text }
        let childLine = "\t\t\t\t\(refID) /* \(name) */,"
        var newBlock = block
        newBlock.insert(contentsOf: "\n" + childLine, at: childrenStart.upperBound)
        return text.replacingCharacters(in: groupBlock, with: newBlock)
    }

    // MARK: - Low-level object utilities

    /// Insert `entry` into `/* Begin <section> section */ … /* End … */`,
    /// creating the section after the last existing one when absent. (Same
    /// behavior as XcodeProjectEditor.insert, re-implemented here so this file
    /// doesn't depend on that method being non-private.)
    static func insertObject(_ entry: String, intoSection section: String, of text: String) throws -> String {
        let begin = "/* Begin \(section) section */"
        if let range = text.range(of: begin) {
            var out = text
            out.insert(contentsOf: "\n" + entry, at: range.upperBound)
            return out
        }
        guard let lastEnd = text.range(of: " section */", options: .backwards),
              let lineEnd = text.range(of: "\n", range: lastEnd.upperBound..<text.endIndex) else {
            throw Err.unsupported(
                "project.pbxproj has no recognizable object sections — wire the file in Xcode instead.")
        }
        let block = "\n\(begin)\n\(entry)\n/* End \(section) section */\n"
        var out = text
        out.insert(contentsOf: block, at: lineEnd.lowerBound)
        return out
    }

    /// Locate an object DEFINITION line: `\n\t\tID ` (the id at EXACTLY the
    /// canonical two-tab indent at the start of a line). Anchoring on the
    /// newline + two tabs is essential — the same id also appears at FOUR-tab
    /// depth inside `( … )` membership lists, and a sub-string `\t\tID` would
    /// match the trailing two tabs of those. Returns the index of the id's
    /// first character.
    static func objectDefinitionStart(id: String, in text: String) -> String.Index? {
        guard let r = text.range(of: "\n\t\t\(id) ") else { return nil }
        return text.index(after: r.lowerBound)   // skip the leading "\n"
    }

    /// The full `ID … = { … };` text of a MULTI-LINE object (terminated by the
    /// canonical `\n\t\t};` Xcode writes for top-level objects).
    static func objectBlockRange(id: String, in text: String) -> Range<String.Index>? {
        guard let start = objectDefinitionStart(id: id, in: text) else { return nil }
        guard let open = text.range(of: " = {", range: start..<text.endIndex) else { return nil }
        guard let close = text.range(of: "\n\t\t};", range: open.upperBound..<text.endIndex) else { return nil }
        return start..<close.upperBound
    }

    static func objectBlock(id: String, in text: String) -> String? {
        objectBlockRange(id: id, in: text).map { String(text[$0]) }
    }

    /// The text of a SINGLE-LINE object (`\t\tID … = { … };` all on one line),
    /// used for PBXBuildFile / inline PBXFileReference entries.
    static func objectInline(id: String, in text: String) -> String? {
        guard let start = objectDefinitionStart(id: id, in: text) else { return nil }
        // Read to the end of the line.
        let lineEnd = text.range(of: "\n", range: start..<text.endIndex)?.lowerBound ?? text.endIndex
        return String(text[start..<lineEnd])
    }

    /// `field = value;` from a single-line object body (value un-quoted).
    static func inlineFieldValue(_ field: String, in line: String) -> String? {
        guard let r = line.range(of: "\(field) = ") else { return nil }
        var end = r.upperBound
        while end < line.endIndex, line[end] != ";" { end = line.index(after: end) }
        var value = String(line[r.upperBound..<end]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        // A fileRef value may carry a trailing `/* comment */` token; strip it.
        if let slash = value.range(of: " /*") { value = String(value[..<slash.lowerBound]) }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// The IDs in a build phase object's `files = ( … );` list.
    static func buildPhaseFileIDs(_ text: String, phaseID: String) -> [String]? {
        guard let block = objectBlock(id: phaseID, in: text) else { return nil }
        guard let start = block.range(of: "files = (") else { return nil }
        guard let end = block.range(of: ");", range: start.upperBound..<block.endIndex) else { return nil }
        let list = block[start.upperBound..<end.lowerBound]
        var ids: [String] = []
        for line in list.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let id = trimmed.split(whereSeparator: { $0 == " " || $0 == "," }).first {
                ids.append(String(id))
            }
        }
        return ids
    }

    /// `field = value;` (or `field = "value";`) from a multi-line object body.
    static func quotedOrBareValue(of field: String, in block: String) -> String? {
        guard let r = block.range(of: "\(field) = ") else { return nil }
        var end = r.upperBound
        // The value runs to the terminating `;` at this nesting — but a path or
        // url may itself be quoted; scan respecting one level of quoting.
        var inQuote = false
        while end < block.endIndex {
            let ch = block[end]
            if ch == "\"" { inQuote.toggle() }
            else if ch == ";" && !inQuote { break }
            end = block.index(after: end)
        }
        var value = String(block[r.upperBound..<end]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Quote a value for an OpenStep plist iff it needs it (Xcode quotes paths
    /// containing spaces/special characters; bare identifiers stay bare).
    static func plistQuote(_ s: String) -> String {
        let safe = s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "/" || $0 == "-" }
        return (safe && !s.isEmpty) ? s : "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    // MARK: - Package.swift wiring

    static func wirePackage(packageDir: URL, target: String, fm: FileManager) throws -> Outcome {
        let manifestURL = packageDir.appendingPathComponent("Package.swift")
        guard let original = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            throw Err.unsupported("Could not read \(manifestURL.path).")
        }
        let (outcome, edited) = try addProduct(to: original, targetName: target)
        guard outcome == .added else { return outcome }

        let backupURL = manifestURL.appendingPathExtension(
            String(XcodeProjectEditor.backupSuffix.dropFirst()))
        try? fm.removeItem(at: backupURL)
        try original.write(to: backupURL, atomically: true, encoding: .utf8)
        try edited.write(to: manifestURL, atomically: true, encoding: .utf8)

        // Verify with `swift package dump-package` (reusing PackageManifestEditor's
        // toolchain-tolerant runner); restore on a genuine evaluation failure.
        if let failure = PackageManifestEditor.dumpPackageFailure(packageDir: packageDir) {
            try? original.write(to: manifestURL, atomically: true, encoding: .utf8)
            throw Err.unsupported(
                "Edited Package.swift failed `swift package dump-package` (restored the original): \(failure)")
        }
        return .added
    }

    static let productLine =
        ".product(name: \"\(productName)\", package: \"\(packageName)\")"
    static let packageLine =
        ".package(url: \"\(packageURL)\", from: \"\(minimumVersion)\")"

    /// Pure transform: add `.product(name: "PatchSwiftUI", package: "patch-swift")`
    /// to `targetName`'s dependencies (and the package-level `.package(...)` line
    /// if patch-swift isn't already a dependency). Idempotent.
    static func addProduct(to manifest: String, targetName: String) throws -> (Outcome, String) {
        // Already wired? The product line is what we ensure; if it's present the
        // target already depends on PatchSwiftUI.
        if manifest.contains(productLine) {
            return (.alreadyPresent, manifest)
        }

        // 1. The product on the target.
        var text = try addProductToTarget(in: manifest, targetName: targetName)

        // 2. The package dependency, only if patch-swift isn't already declared
        //    (a prior PatchSDK add may have added it).
        if !text.contains("patch-release/patch-swift") {
            text = try addPackageDependency(in: text)
        }
        return (.added, text)
    }

    /// Append `.product(name: "PatchSwiftUI", …)` to the target's dependencies,
    /// reusing PackageManifestEditor's bracket-/string-/comment-aware scanners.
    static func addProductToTarget(in manifest: String, targetName: String) throws -> String {
        guard let packageCall = PackageManifestEditor.argumentRange(ofCall: "Package", in: manifest) else {
            throw Err.unsupported(
                "Could not find the Package(...) initializer in Package.swift — add the product manually.")
        }
        let packageArgs = PackageManifestEditor.labeledArguments(in: manifest, range: packageCall)
        guard let targetsArg = packageArgs["targets"] else {
            throw Err.unsupported("Package.swift has no targets: array — add the product manually.")
        }
        guard let targetCall = PackageManifestEditor.targetEntry(
            named: targetName, in: manifest, targetsArray: targetsArg.value) else {
            throw Err.unsupported(
                "Could not find target `\(targetName)` in Package.swift — add the product manually.")
        }
        let targetArgs = PackageManifestEditor.labeledArguments(in: manifest, range: targetCall)
        var text = manifest
        if let deps = targetArgs["dependencies"],
           let bracket = text.range(of: "[", range: deps.value) {
            text.insert(contentsOf: "\n                \(productLine),", at: bracket.upperBound)
        } else if let nameArg = targetArgs["name"] {
            var insertAt = nameArg.value.upperBound
            while insertAt > nameArg.value.lowerBound,
                  text[text.index(before: insertAt)].isWhitespace {
                insertAt = text.index(before: insertAt)
            }
            let insertion = ",\n            dependencies: [\n                \(productLine),\n            ]"
            text.insert(contentsOf: insertion, at: insertAt)
        } else {
            throw Err.unsupported(
                "Target `\(targetName)` has no name: argument to anchor on — add the product manually.")
        }
        return text
    }

    /// Append the patch-swift `.package(...)` line to the package-level
    /// dependencies (creating the array before `targets:` when absent).
    static func addPackageDependency(in manifest: String) throws -> String {
        guard let packageCall = PackageManifestEditor.argumentRange(ofCall: "Package", in: manifest) else {
            throw Err.unsupported("Could not re-locate Package(...) after editing.")
        }
        let packageArgs = PackageManifestEditor.labeledArguments(in: manifest, range: packageCall)
        var text = manifest
        if let deps = packageArgs["dependencies"],
           let bracket = text.range(of: "[", range: deps.value) {
            text.insert(contentsOf: "\n        \(packageLine),", at: bracket.upperBound)
        } else if let targetsArg = packageArgs["targets"] {
            let block = "dependencies: [\n        \(packageLine),\n    ],\n    "
            text.insert(contentsOf: block, at: targetsArg.label.lowerBound)
        } else {
            throw Err.unsupported("Could not re-locate targets: after editing.")
        }
        return text
    }
}
