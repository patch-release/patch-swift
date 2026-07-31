// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Locates an iOS app's primary app icon inside a project directory, WITHOUT
/// mutating anything. Used by `Patch init` (and `push`) to upload the icon so the
/// console can display it next to the app.
///
/// Two best-effort strategies, in priority order:
///   1. The asset catalog: the largest PNG inside any `AppIcon.appiconset` (the
///      modern, authoritative source — Xcode's app-icon asset). A single-image
///      catalog (a 1024×1024 marketing icon) is the common case; older catalogs
///      list many idiom/scale variants, so we pick the BIGGEST file (largest icon).
///   2. The `Info.plist` `CFBundleIcons` → `CFBundlePrimaryIcon` →
///      `CFBundleIconFiles` last entry (the legacy loose-PNG layout), resolved to a
///      file on disk next to the plist (matching the base name + an `@2x`/`@3x`
///      variant when present).
///
/// Everything is deterministic (sorted traversal, byte size as the tie-break) and
/// purely read-only. Returns `nil` when no icon can be found — callers SKIP cleanly
/// (an app without an icon must never fail a command).
public enum AppIconLocator {
    /// A located icon: its file URL plus the raw bytes (read once here so callers
    /// don't re-read) and a best-effort MIME type from the file extension.
    public struct Icon: Equatable, Sendable {
        public let url: URL
        public let data: Data
        public let mimeType: String
        public var byteCount: Int { data.count }

        public init(url: URL, data: Data, mimeType: String) {
            self.url = url
            self.data = data
            self.mimeType = mimeType
        }
    }

    /// Find the app's primary icon under `root`. Returns nil when none is found.
    public static func locate(in root: URL, fm: FileManager = .default) -> Icon? {
        if let fromCatalog = locateInAssetCatalog(root: root, fm: fm) {
            return fromCatalog
        }
        if let fromPlist = locateViaInfoPlist(root: root, fm: fm) {
            return fromPlist
        }
        return nil
    }

    // MARK: - Strategy 1: asset catalog AppIcon.appiconset

    /// The largest PNG inside any `*.appiconset` directory whose name starts with
    /// `AppIcon` (the conventional primary-icon set). When several `AppIcon*` sets
    /// exist (e.g. `AppIcon`, `AppIcon-Dark`), the one named exactly `AppIcon`
    /// wins; otherwise the lexicographically-first, so the choice is deterministic.
    static func locateInAssetCatalog(root: URL, fm: FileManager) -> Icon? {
        var iconSets: [URL] = []
        DiscoveryWalk.walk(root, fm: fm, keys: [.isDirectoryKey]) { url in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return true }
            let name = url.lastPathComponent
            if url.pathExtension == "appiconset" && name.hasPrefix("AppIcon") {
                iconSets.append(url)
            }
            return true
        }
        guard !iconSets.isEmpty else { return nil }
        // Prefer the canonically-named `AppIcon.appiconset`; else stable order.
        let chosen = iconSets.first { $0.lastPathComponent == "AppIcon.appiconset" }
            ?? iconSets.min(by: { $0.path < $1.path })!
        return largestPNG(in: chosen, fm: fm)
    }

    /// The largest `.png` directly inside `dir` (icon sets are flat). Ties broken by
    /// path for determinism. Reads the chosen file's bytes.
    static func largestPNG(in dir: URL, fm: FileManager) -> Icon? {
        let entries = (try? fm.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        let pngs = entries.filter { $0.pathExtension.lowercased() == "png" }
        guard !pngs.isEmpty else { return nil }
        // Sort by (size desc, path asc) so the largest — and, on a tie, a stable
        // pick — is chosen deterministically.
        let sorted = pngs.sorted { a, b in
            let sa = fileSize(a, fm: fm), sb = fileSize(b, fm: fm)
            if sa != sb { return sa > sb }
            return a.path < b.path
        }
        for png in sorted {
            if let data = try? Data(contentsOf: png), !data.isEmpty {
                return Icon(url: png, data: data, mimeType: "image/png")
            }
        }
        return nil
    }

    // MARK: - Strategy 2: Info.plist CFBundleIcons (legacy loose PNGs)

    /// Resolve the primary icon from the first `Info.plist` that declares
    /// `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles`. The last entry is the
    /// highest-resolution base name (Apple lists them ascending); we resolve it to a
    /// real file beside the plist, preferring an `@3x`/`@2x` variant when present.
    static func locateViaInfoPlist(root: URL, fm: FileManager) -> Icon? {
        var plists: [URL] = []
        DiscoveryWalk.walk(root, fm: fm) { url in
            if url.lastPathComponent == "Info.plist" { plists.append(url) }
            return true
        }
        // Deterministic: try plists in path order.
        for plist in plists.sorted(by: { $0.path < $1.path }) {
            guard let base = primaryIconBaseName(inInfoPlist: plist) else { continue }
            if let icon = resolveIconFile(baseName: base, near: plist, fm: fm) {
                return icon
            }
        }
        return nil
    }

    /// Parse `CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconFiles` and return the
    /// LAST (highest-res) base name, or nil when the plist doesn't carry one.
    static func primaryIconBaseName(inInfoPlist url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        guard let icons = dict["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last(where: { !$0.isEmpty }) else { return nil }
        return last
    }

    /// Find a PNG on disk for `baseName` next to (or under the parent of) the plist.
    /// Prefers the highest scale variant (`@3x` > `@2x` > base) and the largest file.
    static func resolveIconFile(baseName: String, near plist: URL, fm: FileManager) -> Icon? {
        let dir = plist.deletingLastPathComponent()
        // Candidate file names, highest-res first.
        let names = ["\(baseName)@3x.png", "\(baseName)@2x.png", "\(baseName).png"]
        var matches: [URL] = []
        DiscoveryWalk.walk(dir, fm: fm) { url in
            guard url.pathExtension.lowercased() == "png" else { return true }
            let fileName = url.lastPathComponent
            // Match exact scale-variant names, OR a name that begins with the
            // base name (covers `AppIcon60x60@2x.png`-style asset-catalog spills).
            if names.contains(fileName) || fileName.hasPrefix(baseName) {
                matches.append(url)
            }
            return true
        }
        guard !matches.isEmpty else { return nil }
        // Largest file (highest resolution); stable tie-break by path.
        let chosen = matches.sorted { a, b in
            let sa = fileSize(a, fm: fm), sb = fileSize(b, fm: fm)
            if sa != sb { return sa > sb }
            return a.path < b.path
        }.first!
        guard let data = try? Data(contentsOf: chosen), !data.isEmpty else { return nil }
        return Icon(url: chosen, data: data, mimeType: "image/png")
    }

    // MARK: - Helpers

    private static func fileSize(_ url: URL, fm: FileManager) -> Int {
        ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }
}
