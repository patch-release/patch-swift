// SPDX-License-Identifier: Apache-2.0

// PatchUninstaller.swift — the engine behind `patchcli unprepare` (and the automatic cleanup of
// files newly added to `.Patch.yml` `exclude:`). Removes EXACTLY what `patchcli prepare` / `init`
// added, and nothing else:
//
//   • SOURCES — the PATCH-ACCESS forwarder block and any PATCH-THUNKS block (exact markers, must be
//     terminated), and the `dynamic` keyword prepare inserted on `var body: some View`. Which `dynamic`
//     is prepare's comes from the prepare RECORD (`Patch/Generated/prepare-record.json`, written on
//     every prepare). With no record (e.g. a fresh clone — the folder is gitignored) the documented
//     fallback is "every `dynamic var body: some View` of a View type in a file prepare touched"
//     (a file carrying a Patch block, or a view Patch/Generated/ replaces) — reported as such;
//     `--keep-dynamic` never touches `dynamic`.
//   • FILES — every `Patch/Generated/` folder, `PatchUIKitThunks.generated.swift`, and the
//     `.patch-backup` copies prepare/init leave beside edited files.
//   • PROJECT — pbxproj references to the generated files + the PatchSwiftUI/PatchUIKit product link
//     (classic groups; synchronized groups had nothing added); `Package.swift`'s PatchSwiftUI product
//     line; the `.gitignore` rule prepare appended. With `removeSDK`, also the PatchSDK product +
//     patch-swift package reference (pbxproj and Package.swift) and the injected `Patch.configure`
//     startup code in the `@main` App.
//
// Same safety discipline as `XcodeProjectEditor`/`PackageManifestEditor`: PURE text transforms (each
// the exact inverse of the corresponding insertion, so prepare→unprepare is byte-identical on a
// standard project), then backup → write → verify (`plutil -lint` / `swift package dump-package` /
// SwiftSyntax parse) → restore-on-fail.

import Foundation
import CodeGenerator
import PartitioningEngine

public enum PatchUninstaller {

    // MARK: - Prepare record

    public static let recordFileName = "prepare-record.json"
    public static let generatedFolderSuffix = "Patch/Generated"

    public struct Record: Codable, Equatable {
        public var version: Int = 1
        /// Project-root-relative source path → View type names whose `var body` prepare made `dynamic`.
        public var dynamicInsertions: [String: [String]] = [:]
        public init() {}
    }

    /// Merge this run's insertions into the record in `genDir` (created if absent).
    /// `droppingTypes`: views whose prepare-inserted `dynamic` has since been REMOVED by Patch itself
    /// (kept native via `.Patch.yml` `native_views:` / `prepare --verify`) — forgotten, so a `dynamic`
    /// the developer later writes on such a view is never mistaken for prepare's.
    public static func updateRecord(genDir: URL, root: URL, inserted: [URL: [String]],
                                    droppingTypes: Set<String> = [], fm: FileManager = .default) {
        let url = genDir.appendingPathComponent(recordFileName)
        let existing = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard !inserted.isEmpty || (existing != nil && !droppingTypes.isEmpty) else { return }
        var rec = existing ?? Record()
        for (file, types) in inserted {
            let rel = relativePath(file, root: root)
            rec.dynamicInsertions[rel] = Array(Set(rec.dynamicInsertions[rel] ?? []).union(types)).sorted()
        }
        if !droppingTypes.isEmpty {
            for (k, v) in rec.dynamicInsertions {
                let kept = v.filter { !droppingTypes.contains($0) }
                rec.dynamicInsertions[k] = kept.isEmpty ? nil : kept
            }
        }
        try? fm.createDirectory(at: genDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(rec).write(to: url, options: .atomic)
    }

    /// The union of every record found under `root` (nil when there is none).
    public static func loadRecord(root: URL, fm: FileManager = .default) -> Record? {
        var merged: Record?
        for dir in generatedFolders(under: root, fm: fm) {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(recordFileName)),
                  let rec = try? JSONDecoder().decode(Record.self, from: data) else { continue }
            var m = merged ?? Record()
            for (k, v) in rec.dynamicInsertions { m.dynamicInsertions[k] = Array(Set(m.dynamicInsertions[k] ?? []).union(v)).sorted() }
            merged = m
        }
        return merged
    }

    // MARK: - Discovery

    static func walk(_ root: URL, fm: FileManager) -> [URL] {
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            let lower = url.path.lowercased()
            if lower.contains("/.git/") || lower.hasSuffix("/.git") || lower.contains("/.build/") || lower.hasSuffix("/.build")
                || SwiftParserEngine.isBuildArtifactPath(lower) {
                en.skipDescendants(); continue
            }
            out.append(url)
        }
        return out
    }

    public static func generatedFolders(under root: URL, fm: FileManager = .default) -> [URL] {
        walk(root, fm: fm).filter {
            var isDir: ObjCBool = false
            return $0.path.hasSuffix("/" + generatedFolderSuffix) && fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }.sorted { $0.path < $1.path }
    }

    public static func relativePath(_ url: URL, root: URL) -> String {
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : url.lastPathComponent
    }

    // MARK: - Source cleaning

    public struct SourceClean: Equatable {
        public var text: String
        public var removedBlocks: Int
        public var removedDynamic: [String]
    }

    /// Strip every Patch block and (unless `keepDynamic`) prepare's `dynamic` from one source file.
    /// `dynamicTypes`: the recorded View types for this file; nil = no record → the fallback rule
    /// (all View bodies, but only when the file shows prepare evidence — `hasEvidence`).
    public static func cleanSource(_ text: String, dynamicTypes: Set<String>?, hasEvidence: Bool,
                                   keepDynamic: Bool) -> SourceClean {
        let blocks = [ThunkGenerator.sameFileBeginMarker, PatchAccessForwarding.beginMarker]
            .map { text.components(separatedBy: $0).count - 1 }.reduce(0, +)
        var out = blocks > 0 ? PatchAccessForwarding.stripAllGeneratedBlocks(from: text) : text
        var removed: [String] = []
        if !keepDynamic {
            if let types = dynamicTypes {
                if !types.isEmpty {
                    let r = PatchAccessForwarding.removeDynamic(from: out, onlyTypes: types)
                    out = r.text; removed = r.types
                }
            } else if hasEvidence || blocks > 0 {
                let r = PatchAccessForwarding.removeDynamic(from: out, onlyTypes: nil)
                out = r.text; removed = r.types
            }
        }
        return SourceClean(text: out, removedBlocks: blocks, removedDynamic: removed)
    }

    /// View type names the generated thunk files under `root` replace (evidence of prepare, used by
    /// the no-record fallback).
    static func replacedViewTypes(root: URL, fm: FileManager) -> Set<String> {
        var names = Set<String>()
        let re = try! NSRegularExpression(pattern: #"typeName: "([A-Za-z_][A-Za-z0-9_]*)""#)
        for dir in generatedFolders(under: root, fm: fm) {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(ThunkGenerator.thunkFileName), encoding: .utf8) else { continue }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { names.insert(String(text[r])) }
            }
        }
        return names
    }

    // MARK: - Plan

    public struct FileEdit: Equatable {
        public let url: URL
        public let original: String
        public let updated: String
        public let summary: String
        /// How to verify the edit before keeping it.
        public enum Verify: Equatable { case swiftParse, plutil, dumpPackage(URL), none }
        public let verify: Verify
    }

    public struct Plan {
        public var edits: [FileEdit] = []
        public var deletions: [URL] = []
        public var notes: [String] = []
        public var isEmpty: Bool { edits.isEmpty && deletions.isEmpty }
    }

    public struct Options {
        public var removeSDK = false
        public var keepDynamic = false
        public init(removeSDK: Bool = false, keepDynamic: Bool = false) {
            self.removeSDK = removeSDK; self.keepDynamic = keepDynamic
        }
    }

    /// Everything `unprepare` would change under `root`. Pure w.r.t. the filesystem (reads only).
    public static func plan(root: URL, options: Options, fm: FileManager = .default) -> Plan {
        var plan = Plan()
        let all = walk(root, fm: fm)
        let record = loadRecord(root: root, fm: fm)
        let replaced = replacedViewTypes(root: root, fm: fm)
        if record == nil && !options.keepDynamic {
            plan.notes.append("No prepare record found (Patch/Generated/\(recordFileName)); removing `dynamic` from "
                              + "`var body: some View` only in files that carry a Patch block or whose view Patch/Generated/ replaces.")
        }
        let genFolders = generatedFolders(under: root, fm: fm)
        let genPaths = genFolders.map { $0.path + "/" }

        // (1) Swift sources.
        for url in all where url.pathExtension == "swift" {
            if genPaths.contains(where: { url.path.hasPrefix($0) }) { continue }
            let name = url.lastPathComponent
            if name == UIKitThunkGenerator.thunkFileName { plan.deletions.append(url); continue }
            if name == "Package.swift" || name.hasPrefix("Package@swift-") { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let hasBlock = text.contains(ThunkGenerator.sameFileBeginMarker) || text.contains(PatchAccessForwarding.beginMarker)
            let hasDynamicBody = text.contains("dynamic var body")
            let hasEntry = options.removeSDK && (text.contains("Patch.configure(") || text.contains("import PatchSDK"))
            let hasRegistrar = text.contains(HostBridgeProjectIntegrator.registrarInstallCall)
            guard hasBlock || hasDynamicBody || hasEntry || hasRegistrar else { continue }

            var updated = text
            var parts: [String] = []
            if hasBlock || hasDynamicBody {
                let rel = relativePath(url, root: root)
                let recorded = record.map { Set($0.dynamicInsertions[rel] ?? []) }
                let evidence = replaced.contains { text.contains("struct \($0)") }
                let c = cleanSource(updated, dynamicTypes: recorded, hasEvidence: evidence, keepDynamic: options.keepDynamic)
                updated = c.text
                if c.removedBlocks > 0 { parts.append("\(c.removedBlocks) generated block(s)") }
                if !c.removedDynamic.isEmpty { parts.append("`dynamic` on \(c.removedDynamic.sorted().joined(separator: ", "))") }
                if hasDynamicBody, c.removedDynamic.isEmpty, !options.keepDynamic, record != nil {
                    // Left alone deliberately: not recorded as inserted by prepare.
                }
            }
            if hasRegistrar {
                updated = removeLines(in: updated) { $0.trimmingCharacters(in: .whitespaces) == HostBridgeProjectIntegrator.registrarInstallCall }
                parts.append("host-bridge registrar line")
            }
            if options.removeSDK, updated.contains("Patch.configure(") || updated.contains("import PatchSDK") {
                let (t, did) = removeAppEntryInjection(updated)
                if did { updated = t; parts.append("`Patch.configure` startup code") }
            }
            if updated != text {
                plan.edits.append(FileEdit(url: url, original: text, updated: updated,
                                           summary: parts.joined(separator: " + "), verify: .swiftParse))
            }
        }
        if options.removeSDK {
            // Anything still importing the SDK after the planned edits would stop compiling.
            let editedByURL = Dictionary(plan.edits.map { ($0.url, $0.updated) }, uniquingKeysWith: { a, _ in a })
            let stillImporting = all.filter { $0.pathExtension == "swift" }.compactMap { u -> String? in
                if genPaths.contains(where: { u.path.hasPrefix($0) }) || u.lastPathComponent == UIKitThunkGenerator.thunkFileName { return nil }
                let t = editedByURL[u] ?? (try? String(contentsOf: u, encoding: .utf8)) ?? ""
                return ["import PatchSDK", "import PatchSwiftUI", "import PatchUIKit", "import PatchRender"]
                    .contains(where: { t.contains($0) }) ? relativePath(u, root: root) : nil
            }
            if !stillImporting.isEmpty {
                plan.notes.append("Kept the patch-swift package: these files still import it — "
                                  + stillImporting.sorted().joined(separator: ", "))
            }
        }
        let removeSDK = options.removeSDK && !plan.notes.contains { $0.hasPrefix("Kept the patch-swift package") }

        // (2) Generated folders (+ an emptied `Patch/` parent) and backups.
        for dir in genFolders { plan.deletions.append(dir) }
        for url in all where url.lastPathComponent.hasSuffix(XcodeProjectEditor.backupSuffix) {
            plan.deletions.append(url)
        }

        // (3) Project files.
        for url in all where url.pathExtension == "xcodeproj" {
            let pbx = url.appendingPathComponent("project.pbxproj")
            guard let text = try? String(contentsOf: pbx, encoding: .utf8) else { continue }
            let (updated, removed) = removePatchReferences(pbxproj: text, removeSDK: removeSDK)
            if updated != text {
                plan.edits.append(FileEdit(url: pbx, original: text, updated: updated,
                                           summary: removed.joined(separator: ", "), verify: .plutil))
            }
        }
        for url in all where url.lastPathComponent == "Package.swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let updated = removePackageManifestReferences(text, removeSDK: removeSDK)
            if updated != text {
                plan.edits.append(FileEdit(url: url, original: text, updated: updated,
                                           summary: removeSDK ? "patch-swift products + package" : "PatchSwiftUI product",
                                           verify: .dumpPackage(url.deletingLastPathComponent())))
            }
        }
        let gi = root.appendingPathComponent(".gitignore")
        if let text = try? String(contentsOf: gi, encoding: .utf8) {
            let updated = removeGitignoreRule(text)
            if updated != text {
                if updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    plan.deletions.append(gi)
                } else {
                    plan.edits.append(FileEdit(url: gi, original: text, updated: updated,
                                               summary: "Patch/Generated ignore rule", verify: .none))
                }
            }
        }
        // `native_views:` (views `prepare --verify` proved break the build once prepared) already have
        // their original source back — nothing to restore. The list stays so a later prepare keeps them native.
        let native = PatchConfig.nativeViewNames(near: root)
        if !native.isEmpty, !plan.isEmpty {
            plan.notes.append("Kept `native_views:` in .Patch.yml (\(native.sorted().joined(separator: ", "))) — those views are "
                              + "already un-prepared; the list keeps them native if you prepare again.")
        }
        if options.removeSDK {
            plan.notes.append("`.Patch.yml` was left in place (it holds your app key). Delete it yourself if you're removing Patch entirely.")
        }
        plan.deletions = Array(Set(plan.deletions)).sorted { $0.path < $1.path }
        return plan
    }

    /// Apply a plan: each edit is backed up in memory, written, verified, and restored on failure.
    /// Returns human-readable failures (empty = everything applied).
    @discardableResult
    public static func apply(_ plan: Plan, fm: FileManager = .default) -> [String] {
        var failures: [String] = []
        for e in plan.edits {
            do {
                try e.updated.write(to: e.url, atomically: true, encoding: .utf8)
            } catch {
                failures.append("\(e.url.lastPathComponent): write failed (\(error))"); continue
            }
            var problem: String?
            switch e.verify {
            case .swiftParse:
                if ThunkGenerator.parses(e.original), !ThunkGenerator.parses(e.updated) { problem = "no longer parses" }
            case .plutil:
                problem = XcodeProjectEditor.plutilLint(e.url)
            case .dumpPackage(let dir):
                problem = PackageManifestEditor.dumpPackageFailure(packageDir: dir)
            case .none: break
            }
            if let problem {
                try? e.original.write(to: e.url, atomically: true, encoding: .utf8)
                failures.append("\(e.url.lastPathComponent): verification failed, original restored (\(problem))")
            }
        }
        for url in plan.deletions {
            try? fm.removeItem(at: url)
            // Remove an emptied `Patch/` parent of a generated folder.
            if url.path.hasSuffix("/" + generatedFolderSuffix) {
                let parent = url.deletingLastPathComponent()
                if ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? ["x"]).filter({ $0 != ".DS_Store" }).isEmpty {
                    try? fm.removeItem(at: parent)
                }
            }
        }
        return failures
    }

    // MARK: - Pure transforms

    static func removeLines(in text: String, where pred: (String) -> Bool) -> String {
        text.components(separatedBy: "\n").filter { !pred($0) }.joined(separator: "\n")
    }

    /// Exact inverse of `AppEntryInjector.inject`: drop the `Patch.configure(…)` call (single- or
    /// multi-line), the `Task { await Patch.shared.start() }` line, an `init()` left empty by that
    /// (plus the blank line the injector added after it), and `import PatchSDK` when nothing else in
    /// the file still uses `Patch`.
    public static func removeAppEntryInjection(_ source: String) -> (String, Bool) {
        var lines = source.components(separatedBy: "\n")
        var changed = false
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Patch.configure(.init(") {
                var j = i
                if !(t.hasSuffix("))")) {
                    while j + 1 < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).hasSuffix("))") { j += 1 }
                }
                lines.removeSubrange(i...j); changed = true; continue
            }
            if t == "Task { await Patch.shared.start() }" || t == HostBridgeProjectIntegrator.registrarInstallCall {
                lines.remove(at: i); changed = true
                // Merged into an existing `init() {`: the injector's leading newline left a blank line.
                if t.hasPrefix("Task"), i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                   i > 0, lines[i - 1].trimmingCharacters(in: .whitespaces).hasSuffix("{"),
                   i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces) != "}" {
                    lines.remove(at: i)
                }
                continue
            }
            i += 1
        }
        guard changed else { return (source, false) }
        // An `init() {` immediately closed by `}` → remove (it was created by the injector).
        var k = 0
        while k + 1 < lines.count {
            if lines[k].trimmingCharacters(in: .whitespaces) == "init() {",
               lines[k + 1].trimmingCharacters(in: .whitespaces) == "}" {
                lines.removeSubrange(k...(k + 1))
                if k < lines.count, lines[k].trimmingCharacters(in: .whitespaces).isEmpty,
                   k > 0, lines[k - 1].trimmingCharacters(in: .whitespaces).hasSuffix("{") {
                    lines.remove(at: k)
                }
                continue
            }
            k += 1
        }
        let rest = lines.filter { $0.trimmingCharacters(in: .whitespaces) != "import PatchSDK" }.joined(separator: "\n")
        let stillUsesPatch = rest.range(of: #"\bPatch[A-Za-z]*\."#, options: .regularExpression) != nil
        if !stillUsesPatch { lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == "import PatchSDK" } }
        return (lines.joined(separator: "\n"), true)
    }

    static let generatedFileNames: Set<String> = [ThunkGenerator.thunkFileName, UIKitThunkGenerator.thunkFileName,
                                                  HostBridgeProjectIntegrator.generatedFileName]

    /// Remove the pbxproj objects `patchcli prepare`/`init` add: the generated-file PBXFileReference +
    /// PBXBuildFile (+ their group/phase list entries), the PatchSwiftUI/PatchUIKit product dependency +
    /// its build file, and with `removeSDK` the PatchSDK product and the patch-swift package reference.
    /// Line-level exact inverse of the insertions (each inserted as `"\n" + line(s)`), then any section
    /// left empty (only ever one we created) and an emptied `packageReferences` list are dropped.
    public static func removePatchReferences(pbxproj: String, removeSDK: Bool) -> (String, [String]) {
        guard pbxproj.hasPrefix("// !$*UTF8*$!") else { return (pbxproj, []) }
        var lines = pbxproj.components(separatedBy: "\n")
        func objectID(_ line: String) -> String? {
            guard line.hasPrefix("\t\t"), !line.hasPrefix("\t\t\t") else { return nil }
            return line.dropFirst(2).split(separator: " ").first.map(String.init)
        }
        var ids = Set<String>()
        var described: [String] = []
        // Pass 1: file refs + product deps + package ref.
        var i = 0
        var patchSwiftRef: String?
        while i < lines.count {
            let line = lines[i]
            if let id = objectID(line) {
                if line.contains("isa = PBXFileReference;"),
                   let path = PBXThunkIntegration.inlineFieldValue("path", in: line),
                   generatedFileNames.contains((path as NSString).lastPathComponent) {
                    ids.insert(id); described.append((path as NSString).lastPathComponent)
                } else if line.hasSuffix("= {") {
                    var j = i + 1
                    while j < lines.count, lines[j] != "\t\t};" { j += 1 }
                    let block = lines[i...min(j, lines.count - 1)].joined(separator: "\n")
                    if block.contains("isa = XCRemoteSwiftPackageReference;"), block.contains("patch-release/patch-swift") {
                        patchSwiftRef = id
                    }
                    if block.contains("isa = XCSwiftPackageProductDependency;"),
                       let prod = PBXThunkIntegration.quotedOrBareValue(of: "productName", in: block) {
                        let removable: Set<String> = removeSDK ? ["PatchSwiftUI", "PatchUIKit", "PatchSDK", "PatchRender", "PatchHostBridge"]
                                                                : ["PatchSwiftUI", "PatchUIKit"]
                        if removable.contains(prod) { ids.insert(id); described.append("\(prod) product") }
                    }
                    i = j
                }
            }
            i += 1
        }
        // Pass 2: build files referencing removed refs/products.
        for line in lines {
            guard let id = objectID(line), line.contains("isa = PBXBuildFile;") else { continue }
            let ref = PBXThunkIntegration.inlineFieldValue("fileRef", in: line) ?? PBXThunkIntegration.inlineFieldValue("productRef", in: line)
            if let ref, ids.contains(ref) { ids.insert(id) }
        }
        // The patch-swift package reference goes once no remaining product dependency uses it.
        if let ref = patchSwiftRef {  // an orphaned patch-swift reference (no product left using it) goes too
            // Any XCSwiftPackageProductDependency not being removed that points at the ref keeps it.
            var keeps = false
            var k = 0
            while k < lines.count {
                if let id = objectID(lines[k]), lines[k].hasSuffix("= {"), !ids.contains(id) {
                    var j = k + 1
                    while j < lines.count, lines[j] != "\t\t};" { j += 1 }
                    let block = lines[k...min(j, lines.count - 1)].joined(separator: "\n")
                    if block.contains("isa = XCSwiftPackageProductDependency;"), block.contains("package = \(ref) ") { keeps = true }
                    k = j
                }
                k += 1
            }
            if !keeps { ids.insert(ref); described.append("patch-swift package reference") }
        }
        guard !ids.isEmpty else { return (pbxproj, []) }
        // Pass 3: delete definitions + list references.
        var out: [String] = []
        i = 0
        while i < lines.count {
            let line = lines[i]
            if let id = objectID(line), ids.contains(id) {
                if line.hasSuffix("= {") {
                    var j = i + 1
                    while j < lines.count, lines[j] != "\t\t};" { j += 1 }
                    i = j + 1; continue
                }
                i += 1; continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\t\t\t"), trimmed.hasSuffix(","),
               let first = trimmed.split(separator: " ").first.map({ String($0).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }),
               ids.contains(first) {
                i += 1; continue
            }
            out.append(line); i += 1
        }
        // Pass 4: empty sections and an emptied packageReferences list.
        let removedProduct = described.contains { $0.hasSuffix(" product") }
        var cleaned: [String] = []
        var k = 0
        // Each section the editors CREATED was inserted with one trailing blank line; drop one blank
        // line per removed empty section right after the run of removed sections.
        var pendingBlanks = 0
        while k < out.count {
            if k + 1 < out.count, out[k].hasPrefix("/* Begin "), out[k].hasSuffix(" section */"),
               out[k + 1] == out[k].replacingOccurrences(of: "/* Begin ", with: "/* End ") {
                k += 2; pendingBlanks += 1; continue
            }
            if pendingBlanks > 0, out[k].isEmpty { pendingBlanks -= 1; k += 1; continue }
            pendingBlanks = 0
            // A target's `packageProductDependencies` list emptied by removing our product(s): the
            // editors create it when absent, so dropping it restores such a project byte-for-byte (an
            // Xcode-template project that had it empty just loses a no-op key Xcode re-adds on save).
            if removedProduct, k + 1 < out.count, out[k] == "\t\t\tpackageProductDependencies = (", out[k + 1] == "\t\t\t);" {
                k += 2; continue
            }
            if k + 1 < out.count, out[k] == "\t\t\tpackageReferences = (", out[k + 1] == "\t\t\t);", ids.contains(patchSwiftRef ?? "") {
                k += 2; continue
            }
            cleaned.append(out[k]); k += 1
        }
        return (cleaned.joined(separator: "\n"), described)
    }

    /// Remove the `.product(…patch-swift…)` target dependency lines prepare/init added (and, with
    /// `removeSDK`, the `.package(url: …patch-swift…)` line), plus a `dependencies: [ ]` array the
    /// editors created that is now empty.
    public static func removePackageManifestReferences(_ manifest: String, removeSDK: Bool) -> String {
        let products = removeSDK ? ["PatchSwiftUI", "PatchUIKit", "PatchSDK", "PatchRender"] : ["PatchSwiftUI", "PatchUIKit"]
        var text = manifest
        for p in products {
            let line = ".product(name: \"\(p)\", package: \"\(XcodeProjectEditor.packageName)\")"
            text = removeLines(in: text) { let t = $0.trimmingCharacters(in: .whitespaces); return t == line + "," || t == line }
        }
        if removeSDK {
            text = removeLines(in: text) {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix(".package(url: \"\(XcodeProjectEditor.packageURL)\"") && (t.hasSuffix("),") || t.hasSuffix(")"))
            }
        }
        // Arrays the editors CREATED and that are now empty.
        text = text.replacingOccurrences(of: ",\n            dependencies: [\n            ]", with: "")
        text = text.replacingOccurrences(of: "dependencies: [\n    ],\n    ", with: "")
        return text
    }

    /// Inverse of `Prepare.ignoreGeneratedFolder`'s root `.gitignore` append.
    public static func removeGitignoreRule(_ text: String) -> String {
        let marker = "# Patch generated thunks (patchcli prepare)"
        var lines = text.components(separatedBy: "\n")
        guard let m = lines.firstIndex(of: marker) else { return text }
        var end = m
        if m + 1 < lines.count, lines[m + 1].hasSuffix("/"), lines[m + 1].contains("Patch/Generated") || lines[m + 1].hasSuffix("Generated/") {
            end = m + 1
        }
        lines.removeSubrange(m...end)
        if m > 0, m - 1 < lines.count, lines[m - 1].isEmpty, m - 1 > 0 { lines.remove(at: m - 1) }
        return lines.joined(separator: "\n")
    }
}
