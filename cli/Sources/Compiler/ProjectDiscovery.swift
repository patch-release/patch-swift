// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Inspects a project directory to infer the build target and the app's bundle
/// identifier WITHOUT mutating anything. Used by `Patch init` (to scaffold
/// `.Patch.yml`) and by the push/ship flow (to resolve `app_id` from the bundle
/// id when it is not already pinned in config).
///
/// Everything here is best-effort and deterministic: it reads `Package.swift`,
/// the `.xcodeproj`/`.xcworkspace` directory names, `project.pbxproj`
/// (`PRODUCT_BUNDLE_IDENTIFIER`), and any `Info.plist` (`CFBundleIdentifier`).
public enum ProjectDiscovery {
    public enum Kind: Equatable, Sendable {
        case xcodeproj, xcworkspace, swiftPackage, none
    }

    public struct Project: Equatable, Sendable {
        public let kind: Kind
        /// The `project:` field for `.Patch.yml` (file name, e.g. `MyApp.xcodeproj`).
        public let project: String
        /// The inferred build target, or nil if it could not be determined / is
        /// ambiguous (multiple candidates with no single obvious choice).
        public let target: String?
        /// All target candidates considered, in priority order (for diagnostics).
        public let targetCandidates: [String]
        /// True when more than one plausible target exists and none is clearly
        /// the primary one — callers should require an explicit `--target`.
        public let targetAmbiguous: Bool

        public init(kind: Kind, project: String, target: String?,
                    targetCandidates: [String], targetAmbiguous: Bool) {
            self.kind = kind
            self.project = project
            self.target = target
            self.targetCandidates = targetCandidates
            self.targetAmbiguous = targetAmbiguous
        }
    }

    // MARK: - Target / project detection

    /// Detect the project shape + infer a build target from `root`.
    public static func detect(in root: URL, fm: FileManager = .default) -> Project {
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])) ?? []

        if let ws = entries.first(where: { $0.pathExtension == "xcworkspace" }) {
            let name = ws.deletingPathExtension().lastPathComponent
            return Project(kind: .xcworkspace, project: ws.lastPathComponent,
                           target: name, targetCandidates: [name], targetAmbiguous: false)
        }

        if let proj = entries.first(where: { $0.pathExtension == "xcodeproj" }) {
            // Prefer real native targets parsed from project.pbxproj; the project
            // name itself is the fallback.
            let projName = proj.deletingPathExtension().lastPathComponent
            let targets = xcodeNativeTargets(projectDir: proj, fm: fm)
            return resolveTargets(kind: .xcodeproj, project: proj.lastPathComponent,
                                  candidates: targets, fallback: projName)
        }

        if entries.contains(where: { $0.lastPathComponent == "Package.swift" }) {
            let pkgURL = root.appendingPathComponent("Package.swift")
            let pkgName = packageName(pkgURL) ?? root.lastPathComponent
            // Candidates must be TARGET names — `PackageManifestEditor` wires the
            // SDK into a `.target(name:)`/`.executableTarget(name:)` declaration,
            // not a product (a product name often differs from its target's
            // name). Fall back to product names only when no target is declared.
            var candidates = packageTargets(pkgURL)
            if candidates.isEmpty { candidates = packageProducts(pkgURL) }
            return resolveTargets(kind: .swiftPackage, project: "Package.swift",
                                  candidates: candidates, fallback: pkgName)
        }

        // No recognizable project — derive a sane default but mark it ambiguous so
        // commands that REQUIRE a target ask the user to be explicit.
        let dirName = root.lastPathComponent
        return Project(kind: .none, project: "MyApp.xcodeproj", target: dirName,
                       targetCandidates: [], targetAmbiguous: false)
    }

    /// Pick the single inferred target from candidates, falling back to a name
    /// (project/package name) when no targets were parsed. Flags ambiguity when
    /// multiple genuinely-distinct candidates exist.
    private static func resolveTargets(kind: Kind, project: String,
                                       candidates: [String], fallback: String) -> Project {
        let unique = orderedUnique(candidates)
        if unique.isEmpty {
            return Project(kind: kind, project: project, target: fallback,
                           targetCandidates: [], targetAmbiguous: false)
        }
        if unique.count == 1 {
            return Project(kind: kind, project: project, target: unique[0],
                           targetCandidates: unique, targetAmbiguous: false)
        }
        // Multiple candidates: a target whose name matches the project/package
        // name is the obvious primary; otherwise it's ambiguous.
        if let primary = unique.first(where: { $0 == fallback }) {
            return Project(kind: kind, project: project, target: primary,
                           targetCandidates: unique, targetAmbiguous: false)
        }
        return Project(kind: kind, project: project, target: nil,
                       targetCandidates: unique, targetAmbiguous: true)
    }

    // MARK: - Bundle identifier discovery

    /// Best-effort `CFBundleIdentifier` / `PRODUCT_BUNDLE_IDENTIFIER` for the app.
    /// Pass the resolved build `target` when known — the id is then read from
    /// THAT target's own build configurations, never from a test/extension
    /// target that happens to serialize first in the pbxproj (a real project
    /// surfaced `com.acme.app.tests` as "the" bundle id that way). Returns nil
    /// when none is found (or when only `$(...)` placeholders are present).
    public static func bundleIdentifier(
        in root: URL, target: String? = nil, fm: FileManager = .default
    ) -> String? {
        // 1. project.pbxproj PRODUCT_BUNDLE_IDENTIFIER (most authoritative).
        //    DiscoveryWalk prunes node_modules/Pods/DerivedData/build/etc. and
        //    stops at the first match, so this stays fast on real app trees.
        var result: String?
        DiscoveryWalk.walk(root, fm: fm) { f in
            guard f.lastPathComponent == "project.pbxproj" else { return true }
            if let s = try? String(contentsOf: f, encoding: .utf8),
               let id = bundleID(inPBXProj: s, forTarget: target) {
                result = id
                return false  // stop the walk
            }
            return true
        }
        if let result { return result }
        // 2. Info.plist CFBundleIdentifier (skip $(...) placeholders).
        DiscoveryWalk.walk(root, fm: fm) { f in
            guard f.lastPathComponent == "Info.plist" else { return true }
            if let id = bundleID(inInfoPlist: f), !id.contains("$(") {
                result = id
                return false
            }
            return true
        }
        return result
    }

    /// The bundle id for `target` when resolvable from ITS build configurations,
    /// else the heuristically-ranked project-wide pick. Never returns a `$(...)`
    /// placeholder.
    static func bundleID(inPBXProj s: String, forTarget target: String?) -> String? {
        if let target, let id = bundleID(inPBXProj: s, ofTargetNamed: target) {
            return id
        }
        return rankedBundleID(inPBXProj: s)
    }

    /// Walk pbxproj structure for the EXACT target: its PBXNativeTarget block →
    /// `buildConfigurationList` → that XCConfigurationList's configuration ids →
    /// the first XCBuildConfiguration carrying a concrete bundle id.
    static func bundleID(inPBXProj s: String, ofTargetNamed target: String) -> String? {
        guard let targetRange = XcodeProjectEditor.nativeTargetBlockRange(in: s, targetName: target) else {
            return nil
        }
        let block = String(s[targetRange])
        guard let listID = firstMatch(#"buildConfigurationList = ([A-F0-9]{24})"#, in: block) else {
            return nil
        }
        // The XCConfigurationList block for that id, then its configuration ids.
        guard let listBlock = objectBlock(withID: listID, in: s),
              let configsRange = listBlock.range(of: "buildConfigurations = (") else {
            return nil
        }
        let configsTail = String(listBlock[configsRange.upperBound...])
        let configIDs = allMatches(#"([A-F0-9]{24})"#, in: String(configsTail.prefix(
            configsTail.range(of: ");").map { configsTail.distance(from: configsTail.startIndex, to: $0.lowerBound) }
                ?? configsTail.count)))
        for id in configIDs {
            guard let cfgBlock = objectBlock(withID: id, in: s) else { continue }
            if let raw = firstMatch(#"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);"#, in: cfgBlock) {
                let val = unquoteSetting(raw)
                if !val.isEmpty, !val.contains("$(") { return val }
            }
        }
        return nil
    }

    /// All concrete `PRODUCT_BUNDLE_IDENTIFIER`s, ranked so the APP's id wins
    /// over its derived companions when no target name is available:
    ///   1. an id that is a strict dotted PREFIX of another (test/extension ids
    ///      are conventionally `<app-id>.tests` / `<app-id>.widget`),
    ///   2. else an id NOT carrying an obvious non-app suffix,
    ///   3. else the first concrete id (old behavior).
    static func rankedBundleID(inPBXProj s: String) -> String? {
        var seen = Set<String>()
        var ids: [String] = []
        for raw in allMatches(#"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);"#, in: s) {
            let val = unquoteSetting(raw)
            if !val.isEmpty, !val.contains("$("), seen.insert(val).inserted {
                ids.append(val)
            }
        }
        guard !ids.isEmpty else { return nil }
        if let base = ids.first(where: { id in
            ids.contains { $0 != id && $0.hasPrefix(id + ".") }
        }) {
            return base
        }
        let nonApp = ["tests", "uitests", "watchkitapp", "watchkitextension",
                      "widget", "widgetextension", "appclip", "notificationservice"]
        if let plain = ids.first(where: { id in
            let last = id.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
            return !nonApp.contains(last)
        }) {
            return plain
        }
        return ids[0]
    }

    /// Back-compat shim (older call sites/tests): the ranked project-wide pick.
    static func firstBundleID(inPBXProj s: String) -> String? {
        rankedBundleID(inPBXProj: s)
    }

    // MARK: small pbxproj/regex helpers

    /// The `\t\t<ID> … = { … };` object block for a 24-hex object id.
    private static func objectBlock(withID id: String, in s: String) -> String? {
        guard let start = s.range(of: "\t\t\(id) "),
              let end = s.range(of: "\n\t\t};", range: start.upperBound..<s.endIndex) else {
            return nil
        }
        return String(s[start.lowerBound..<end.upperBound])
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        allMatches(pattern, in: s).first
    }

    private static func allMatches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .compactMap { m in
                m.numberOfRanges >= 2 ? ns.substring(with: m.range(at: 1)) : nil
            }
    }

    private static func unquoteSetting(_ raw: String) -> String {
        var val = raw.trimmingCharacters(in: .whitespaces)
        if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
            val = String(val.dropFirst().dropLast())
        }
        return val
    }

    static func bundleID(inInfoPlist url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let id = dict["CFBundleIdentifier"] as? String,
              !id.isEmpty
        else { return nil }
        return id
    }

    // MARK: - Package.swift parsing

    static func packageName(_ url: URL) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // `name: "X"` — the FIRST occurrence is the package name (Package(name:)).
        if let r = s.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) {
            return capture(String(s[r]))
        }
        return nil
    }

    /// Library/executable product names declared in `Package.swift`.
    /// NOTE: a product name can differ from the underlying target's name — for
    /// wiring the SDK into a target, use `packageTargets` (these are for display
    /// / last-resort fallback only).
    static func packageProducts(_ url: URL) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var names: [String] = []
        let pattern = #"\.(?:library|executable)\(\s*name:\s*"([^"]+)""#
        if let re = try? NSRegularExpression(pattern: pattern) {
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            where m.numberOfRanges >= 2 {
                names.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return names
    }

    /// Build-target names declared in `Package.swift` — the `.target(name:)` /
    /// `.executableTarget(name:)` declarations `PackageManifestEditor` actually
    /// matches when adding the SDK dependency. Excludes `.testTarget`,
    /// `.systemLibrary`, `.binaryTarget`, `.plugin`, and the dependency
    /// `.target(name:)` references inside a target's `dependencies:` list (those
    /// are NOT target declarations — they reference siblings/products).
    static func packageTargets(_ url: URL) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var names: [String] = []
        // Only the declaration forms; `.testTarget` is deliberately excluded so
        // the SDK is never wired into a test target. `.target` inside a
        // `dependencies: [ ... ]` array is a STRING-or-reference, not a
        // `.target(name:)` call with the trailing declaration args, but to be
        // safe we additionally require the match to be one of the top-level
        // declaration kinds (which `.executableTarget`/`.target` both are; a
        // `.target(name:)` dependency reference also matches `.target(name:`,
        // so we keep the conservative behavior: a name appearing only as a dep
        // reference will also appear as a real declaration in a valid manifest).
        let pattern = #"\.(?:executableTarget|target)\(\s*name:\s*"([^"]+)""#
        if let re = try? NSRegularExpression(pattern: pattern) {
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            where m.numberOfRanges >= 2 {
                names.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return names
    }

    private static func capture(_ match: String) -> String? {
        guard let q1 = match.firstIndex(of: "\""),
              let q2 = match.lastIndex(of: "\""), q1 < q2 else { return nil }
        return String(match[match.index(after: q1)..<q2])
    }

    // MARK: - Xcode project target parsing

    /// Product-type suffixes that are NOT a shippable app target — wiring
    /// PatchSDK into one of these (a test bundle, widget/extension, watch app,
    /// app clip, …) is a mis-link. Matched against the tail of
    /// `com.apple.product-type.<…>`.
    private static let nonAppProductTypeSuffixes: [String] = [
        "unit-test", "ui-testing", "bundle.unit-test", "bundle.ui-testing",
        "app-extension", "extensionkit-extension", "watchapp", "watchapp2",
        "watchapp2-container", "watchkit-extension", "watchkit2-extension",
        "app-extension.messages", "app-extension.intents-service",
        "application.on-demand-install-capable",  // App Clip
        "application.watchapp", "application.watchapp2",
        "framework", "static-library", "dynamic-library", "bundle",
        "instruments-package", "metal-library", "driver-extension",
        "system-extension", "xpc-service",
    ]

    /// Keyword fragments in a TARGET NAME that mark it as a non-app companion,
    /// used as a fallback when a block has no parseable `productType`. Mirrors
    /// (and extends) the bundle-id `nonApp` suffix list at `rankedBundleID`.
    private static let nonAppNameKeywords: [String] = [
        "tests", "uitests", "watchkitapp", "watchkitextension",
        "widget", "widgetextension", "appclip", "clip",
        "notificationservice", "intentsextension", "intents",
        "shareextension", "todayextension", "complication", "extension",
    ]

    /// Native target names from `<proj>.xcodeproj/project.pbxproj`, preferring
    /// the actual app target(s). A PBXNativeTarget is dropped when its
    /// `productType` is a non-app product (test bundle, widget/app-extension,
    /// watch app, app clip, framework, …); when a block has no parseable
    /// `productType`, a keyword check on its NAME is the fallback. Reusing the
    /// project name as the app target stays the last resort (callers fall back
    /// to it when this returns empty).
    static func xcodeNativeTargets(projectDir: URL, fm: FileManager) -> [String] {
        let pbx = projectDir.appendingPathComponent("project.pbxproj")
        guard let s = try? String(contentsOf: pbx, encoding: .utf8) else { return [] }
        // PBXNativeTarget entries:  ... isa = PBXNativeTarget; ... name = Foo;
        // ... productType = "com.apple.product-type.application"; ... (order varies).
        // Capture the block body up to the next `}` (the block's closing brace),
        // refusing to cross into the next target's `isa` — works for both the
        // real multi-line pbxproj layout and a single-line `{ … };` block.
        let pattern = #"isa = PBXNativeTarget;((?:(?!isa = PBXNativeTarget;)[^}])*)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = s as NSString
        var allNames: [String] = []
        var appNames: [String] = []
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        where m.numberOfRanges >= 2 {
            let block = ns.substring(with: m.range(at: 1))
            guard let name = unquotedSetting("name", in: block) else { continue }
            allNames.append(name)
            let productType = unquotedSetting("productType", in: block)
            if isAppTarget(name: name, productType: productType) {
                appNames.append(name)
            }
        }
        // Prefer the genuine app target(s); only when NONE survive the filter do
        // we hand back every name (better an ambiguous prompt than zero).
        return appNames.isEmpty ? allNames : appNames
    }

    /// A target counts as a shippable app when its `productType` IS the
    /// application product type; when the product type is absent/unparseable,
    /// fall back to a name-keyword check. A KNOWN non-app product type always
    /// excludes it regardless of name.
    private static func isAppTarget(name: String, productType: String?) -> Bool {
        if let productType, productType.hasPrefix("com.apple.product-type.") {
            if productType == "com.apple.product-type.application" { return true }
            let tail = String(productType.dropFirst("com.apple.product-type.".count))
            if nonAppProductTypeSuffixes.contains(tail) { return false }
            // Any other recognized application.* product type (catch-all for
            // future application sub-kinds) is treated as app-like, but a
            // non-`application` product type is not.
            return productType.hasPrefix("com.apple.product-type.application")
        }
        // No product type to trust → keyword-filter the name.
        let lower = name.lowercased()
        if name.hasSuffix("Tests") || name.hasSuffix("UITests") { return false }
        return !nonAppNameKeywords.contains { lower.hasSuffix($0) }
    }

    /// Extract `<key> = <value>;` from a pbxproj object block, stripping
    /// surrounding quotes. The key is matched on a word boundary so `name`
    /// never matches inside `productName`/`packageProductName`. Returns nil
    /// when the key is absent.
    private static func unquotedSetting(_ key: String, in block: String) -> String? {
        guard let raw = firstMatch(#"(?<![A-Za-z0-9_])"# + key + #" = ([^;\n]+);"#, in: block) else {
            return nil
        }
        let val = unquoteSetting(raw)
        return val.isEmpty ? nil : val
    }

    private static func orderedUnique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for x in xs where !x.isEmpty && !seen.contains(x) {
            seen.insert(x); out.append(x)
        }
        return out
    }
}
