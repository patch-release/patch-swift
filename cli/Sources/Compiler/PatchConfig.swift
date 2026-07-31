// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The parsed `.Patch.yml` configuration (plan schema, ~987–1008).
///
/// A deliberately small, hand-rolled YAML reader: the schema is a fixed,
/// shallow shape (scalars, one string list `exclude`, and two flat sub-maps
/// `bridges` / `build`), so a full YAML dependency would be overkill. The
/// reader supports `key: value`, nested two-space maps, and `- item` lists —
/// enough for this schema and nothing more. Unknown keys are ignored so the
/// file can carry comments / future fields without breaking the CLI.
public struct PatchConfig: Sendable, Equatable {
    public var version: Int
    public var appKey: String
    public var project: String
    public var target: String
    public var exclude: [String]
    public var bridges: [String: Bool]
    public var buildOptimization: String      // "size" | "speed"
    public var buildStripDebugInfo: Bool
    /// Lower SwiftUI `View.body` to WASM so views ship over the air. ON by default
    /// (on if omitted from .Patch.yml); set `swiftui: false` to keep views native.
    public var buildSwiftUI: Bool
    /// Auto-run `patchcli prepare` (insert `dynamic` + generate the thunks for any
    /// newly-added views) BEFORE every `build`/`push`/`release`. ON by default (on if
    /// omitted from .Patch.yml) so adding a view never needs a remembered manual step;
    /// set `auto_prepare: false` to opt out (e.g. when prepare must not touch source).
    /// The `--no-prepare` flag overrides this per-run.
    public var buildAutoPrepare: Bool

    /// Identity used by the backend (UUIDs). These are NOT part of the plan's
    /// minimal schema but are required by the real API (`app_id`/`workspace_id`
    /// are FK-backed UUIDs). Stored alongside the config so a developer doesn't
    /// re-type them on every push. Optional so `analyze`/`build` work offline.
    public var appId: String?
    public var workspaceId: String?
    /// The app's bundle identifier (e.g. `com.acme.app`). Discovered from the
    /// Xcode project / Info.plist at `init`. Used to resolve `app_id` from the
    /// backend when `app_id` is absent, so a developer doesn't have to paste a
    /// UUID by hand.
    public var bundleId: String?
    /// Backend base URL + API key (env overrides these at call time).
    public var apiBaseURL: String?
    public var apiKey: String?
    /// Optional path (relative to the project root) to a resource-overlay spec JSON
    /// (Phase 1b — named color/string/image OTA overrides; see `OverlaySpecReader`).
    /// When set, `patchcli build` auto-packages it into the built module artifact
    /// (the same wrap `patchcli overlay package` does). Nil = no overlay (the artifact
    /// is byte-identical to today).
    public var overlaySpec: String?

    public init(
        version: Int = 1,
        appKey: String = "",
        project: String = "",
        target: String = "",
        exclude: [String] = [],
        bridges: [String: Bool] = PatchConfig.defaultBridges,
        buildOptimization: String = "size",
        buildStripDebugInfo: Bool = true,
        buildSwiftUI: Bool = true,
        buildAutoPrepare: Bool = true,
        appId: String? = nil,
        workspaceId: String? = nil,
        bundleId: String? = nil,
        apiBaseURL: String? = nil,
        apiKey: String? = nil,
        overlaySpec: String? = nil
    ) {
        self.version = version
        self.appKey = appKey
        self.project = project
        self.target = target
        self.exclude = exclude
        self.bridges = bridges
        self.buildOptimization = buildOptimization
        self.buildStripDebugInfo = buildStripDebugInfo
        self.buildSwiftUI = buildSwiftUI
        self.buildAutoPrepare = buildAutoPrepare
        self.appId = appId
        self.workspaceId = workspaceId
        self.bundleId = bundleId
        self.apiBaseURL = apiBaseURL
        self.apiKey = apiKey
        self.overlaySpec = overlaySpec
    }

    public static let defaultBridges: [String: Bool] = [
        "networking": true,
        "userDefaults": true,
        "notifications": true,
        "navigation": true,
        "keychain": true,
        "dateLocale": true,
        "logging": true,
        // Wave-5 bridges
        "analytics": true,
        "fileStorage": true,
        "connectivity": true,
        "biometrics": true,
        "appReview": true,
        "pasteboard": true,
        "haptics": true,
        "deviceInfo": true,
        "shareSheet": true,
        "openURL": true,
        // Wave-5 part 2
        "location": true,
        "calendar": true,
        "contacts": true,
        "appBadge": true,
        "mailCompose": true,
        "inAppPurchase": true,
        "speechSynthesis": true,
        "documentPicker": true,
        "systemSound": true,
        "photoPicker": true,
        // Wave-6 bridges
        "secureRandom": true,
        "appGroupStorage": true,
        "screenControl": true,
        "audioPlayback": true,
        "motion": true,
        "mapsDirections": true,
        "networkImage": true,
        "spotlightIndex": true,
        "backgroundTask": true,
        "fileDownload": true,
        "accessibility": true,
        "appShortcuts": true,
        "handoff": true,
        "watchConnectivity": true,
        "nfcRead": true,
        "processInfo": true,
        "audioRecording": true,
        "videoPlayback": true,
        "speechRecognition": true,
        "mediaInfo": true,
        "imageFilter": true,
        "pdfGenerate": true,
        "qrGenerate": true,
        "camera": true,
    ]

    public static let bridgeOrder = [
        "networking", "userDefaults", "notifications", "navigation",
        "keychain", "dateLocale", "logging",
        "analytics", "fileStorage", "connectivity", "biometrics", "appReview",
        "pasteboard", "haptics", "deviceInfo", "shareSheet", "openURL",
        "location", "calendar", "contacts", "appBadge", "mailCompose",
        "inAppPurchase", "speechSynthesis", "documentPicker", "systemSound", "photoPicker",
        "secureRandom", "appGroupStorage", "screenControl", "audioPlayback", "motion",
        "mapsDirections", "networkImage", "spotlightIndex", "backgroundTask", "fileDownload",
        "accessibility", "appShortcuts", "handoff", "watchConnectivity", "nfcRead",
        "processInfo", "audioRecording", "videoPlayback", "speechRecognition", "mediaInfo",
        "imageFilter", "pdfGenerate", "qrGenerate", "camera",
    ]

    // MARK: - Serialization

    /// Render the config back to the plan's `.Patch.yml` shape.
    public func yamlString() -> String {
        var out = ""
        out += "version: \(version)\n"
        out += "app_key: \(appKey)\n"
        out += "project: \(project)\n"
        out += "target: \(target)\n"
        if let appId { out += "app_id: \(appId)\n" }
        if let workspaceId { out += "workspace_id: \(workspaceId)\n" }
        if let bundleId { out += "bundle_id: \(bundleId)\n" }
        if let apiBaseURL { out += "api_base_url: \(apiBaseURL)\n" }
        if let apiKey { out += "api_key: \(apiKey)\n" }
        if let overlaySpec { out += "overlay: \(overlaySpec)\n" }
        out += "exclude:\n"
        if exclude.isEmpty {
            out += "  []\n"
        } else {
            for e in exclude { out += "  - \(e)\n" }
        }
        out += "bridges:\n"
        for key in PatchConfig.bridgeOrder {
            let v = bridges[key] ?? false
            out += "  \(key): \(v)\n"
        }
        out += "build:\n"
        out += "  optimization: \(buildOptimization)\n"
        out += "  stripDebugInfo: \(buildStripDebugInfo)\n"
        out += "  swiftui: \(buildSwiftUI)\n"
        out += "  auto_prepare: \(buildAutoPrepare)\n"
        return out
    }

    // MARK: - Parsing

    public enum ConfigError: Error, CustomStringConvertible {
        case notFound(String)
        case malformed(String)

        public var description: String {
            switch self {
            case .notFound(let p): return ".Patch.yml not found at \(p). Run `patch init` first."
            case .malformed(let m): return "Could not parse .Patch.yml: \(m)"
            }
        }
    }

    /// Load and parse a `.Patch.yml` from disk.
    public static func load(from url: URL) throws -> PatchConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConfigError.notFound(url.path)
        }
        return try parse(text)
    }

    /// Locate `.Patch.yml` by walking up from `start` to the filesystem root.
    public static func find(startingAt start: URL) -> URL? {
        var dir = start.standardizedFileURL
        let fm = FileManager.default
        var guardCount = 0
        while guardCount < 64 {
            guardCount += 1
            let candidate = dir.appendingPathComponent(".Patch.yml")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// Minimal YAML parser for this fixed schema.
    public static func parse(_ text: String) throws -> PatchConfig {
        var cfg = PatchConfig(bridges: [:])
        var bridgesSeen = false
        // Current container: nil = top-level, else the sub-map name.
        enum Section { case top, exclude, bridges, build }
        var section: Section = .top

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Strip trailing comments per the YAML rule: a `#` starts a comment only
            // at the start of the line or when PRECEDED BY WHITESPACE. A `#` that is
            // part of a value token (`api_key: sk-live-abc#def`, a URL fragment
            // `http://h/#x`) is NOT a comment. The old code stripped from the FIRST
            // `#` unconditionally, silently truncating any value containing `#` —
            // e.g. an API key, corrupting auth with a confusing downstream error.
            let line = Self.stripComment(String(rawLine))
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A top-level key resets the section.
            if indent == 0 {
                if trimmed.hasPrefix("- ") {
                    throw ConfigError.malformed("unexpected list item at top level: \(trimmed)")
                }
                guard let (key, value) = splitKeyValue(trimmed) else {
                    throw ConfigError.malformed("expected key: value, got \(trimmed)")
                }
                switch key {
                case "version": cfg.version = Int(value) ?? cfg.version
                case "app_key": cfg.appKey = unquote(value)
                case "project": cfg.project = unquote(value)
                case "target": cfg.target = unquote(value)
                case "app_id": cfg.appId = emptyToNil(unquote(value))
                case "workspace_id": cfg.workspaceId = emptyToNil(unquote(value))
                case "bundle_id": cfg.bundleId = emptyToNil(unquote(value))
                case "api_base_url": cfg.apiBaseURL = emptyToNil(unquote(value))
                case "api_key": cfg.apiKey = emptyToNil(unquote(value))
                case "overlay": cfg.overlaySpec = emptyToNil(unquote(value))
                case "exclude":
                    section = .exclude
                    // inline empty list `exclude: []`
                    if unquote(value) == "[]" { section = .top }
                case "bridges":
                    section = .bridges; bridgesSeen = true
                case "build":
                    section = .build
                default:
                    section = .top   // unknown scalar key — ignore
                }
                continue
            }

            // Indented line belongs to the current section.
            switch section {
            case .exclude:
                if trimmed.hasPrefix("- ") {
                    cfg.exclude.append(unquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                } else if trimmed == "[]" {
                    // empty list block
                }
            case .bridges:
                if let (key, value) = splitKeyValue(trimmed) {
                    cfg.bridges[key] = parseBool(value)
                }
            case .build:
                if let (key, value) = splitKeyValue(trimmed) {
                    switch key {
                    case "optimization": cfg.buildOptimization = unquote(value)
                    case "stripDebugInfo": cfg.buildStripDebugInfo = parseBool(value)
                    case "swiftui": cfg.buildSwiftUI = parseBool(value)
                    case "auto_prepare": cfg.buildAutoPrepare = parseBool(value)
                    default: break
                    }
                }
            case .top:
                break
            }
        }

        if !bridgesSeen && cfg.bridges.isEmpty {
            cfg.bridges = PatchConfig.defaultBridges
        }
        return cfg
    }

    // MARK: - Scalar helpers

    /// Strip a trailing `#` comment per the YAML rule: a `#` is a comment delimiter
    /// only at the start of the line or when preceded by whitespace, and never when
    /// inside a single/double-quoted string. A `#` glued to a value token (an API
    /// key `sk-abc#def`, a URL fragment `http://h/#x`) is kept verbatim.
    static func stripComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var prev: Character? = nil
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "#" && !inSingle && !inDouble {
                // Comment only at start-of-line or after whitespace.
                if prev == nil || prev == " " || prev == "\t" {
                    return String(line[line.startIndex..<idx])
                }
            }
            prev = ch
            idx = line.index(after: idx)
        }
        return line
    }

    private static func splitKeyValue(_ s: String) -> (String, String)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let key = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    private static func emptyToNil(_ s: String) -> String? {
        s.isEmpty ? nil : s
    }

    private static func parseBool(_ s: String) -> Bool {
        let v = unquote(s).lowercased()
        return v == "true" || v == "yes" || v == "1" || v == "on"
    }
}
