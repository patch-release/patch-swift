// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Reads a developer-authored **overlay-spec file** (JSON) into a
/// `PatchResourceOverlay.Table`. This is the minimal, documented CLI authoring path
/// for the resource overlay (colors / strings / images), bundled into the patch by
/// `patchcli overlay package` (or folded into `build` via the `.Patch.yml`
/// `overlay:` key).
///
/// ## Spec shape (JSON)
/// ```json
/// {
///   "colors": {
///     "brand":      { "light": "#0A7AFF", "dark": "#3391FF" },
///     "accent":     "#FF3B30",
///     "panel":      { "light": [0.95, 0.95, 0.97, 1.0] }
///   },
///   "strings": {
///     "welcome_title": "Welcome back!",
///     "cta_button":    { "value": "Get started", "table": "Onboarding" },
///     "fr": {
///       "welcome_title": "Bon retour !"
///     }
///   },
///   "images": {
///     "logo": { "path": "Assets/logo@2x.png", "scale": 2 }
///   }
/// }
/// ```
///
/// ### Colors
/// A value is either a hex string (`"#RRGGBB"` / `"#RRGGBBAA"` / 3- or 4-digit short
/// form) OR an object with `light` (required) and optional `dark`, each a hex string
/// or a `[r,g,b]` / `[r,g,b,a]` array (components 0…1). A bare hex/array value = the
/// light variant with no dark override.
///
/// ### Strings
/// A top-level key whose VALUE is a string (or `{value, table}`) is a BASE-locale
/// override. A top-level key whose value is an OBJECT-of-strings is treated as a
/// LOCALE code (`"fr"`, `"es"`, `"pt-BR"`), scoping its entries to that locale. A
/// short reserved set of object keys (`value`, `table`) is what distinguishes a
/// `{value,table}` override from a locale map.
///
/// ### Images (honest size caveat)
/// `{ "path": "...", "scale": N }` inlines the file's raw bytes (MIME inferred from
/// the extension). Large images bloat the artifact (it rides the upload/download
/// path), so the spec also accepts `{ "ref": "external-id", "scale": N }` to reference
/// a bytes-out-of-band asset for a future large-asset channel.
public enum OverlaySpecReader {

    public enum SpecError: Error, CustomStringConvertible {
        case notFound(String)
        case malformed(String)
        case badColor(name: String, reason: String)
        case imageFileMissing(name: String, path: String)
        public var description: String {
            switch self {
            case .notFound(let p): return "overlay spec not found at \(p)"
            case .malformed(let m): return "overlay spec is malformed: \(m)"
            case .badColor(let n, let r): return "overlay color '\(n)': \(r)"
            case .imageFileMissing(let n, let p): return "overlay image '\(n)': file not found at \(p)"
            }
        }
    }

    /// Reserved object keys that mark a string override (vs a locale map).
    private static let stringOverrideKeys: Set<String> = ["value", "table"]

    /// Load + parse the spec at `url`. `baseDir` (default: the spec's own directory)
    /// resolves relative image `path`s.
    public static func load(from url: URL, baseDir: URL? = nil) throws -> PatchResourceOverlay.Table {
        guard let data = try? Data(contentsOf: url) else { throw SpecError.notFound(url.path) }
        let base = baseDir ?? url.deletingLastPathComponent()
        return try parse(data, baseDir: base)
    }

    /// Parse spec `data` into a `Table`. `baseDir` resolves relative image paths.
    public static func parse(_ data: Data, baseDir: URL) throws -> PatchResourceOverlay.Table {
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: data) }
        catch { throw SpecError.malformed("\(error)") }
        guard let root = any as? [String: Any] else {
            throw SpecError.malformed("top level must be a JSON object")
        }
        var table = PatchResourceOverlay.Table()

        if let colors = root["colors"] as? [String: Any] {
            for (name, raw) in colors {
                table.colors[name] = try parseColor(name: name, raw)
            }
        }
        if let strings = root["strings"] as? [String: Any] {
            try parseStrings(strings, into: &table)
        }
        if let images = root["images"] as? [String: Any] {
            for (name, raw) in images {
                table.images[name] = try parseImage(name: name, raw, baseDir: baseDir)
            }
        }
        return table
    }

    // MARK: - Colors

    private static func parseColor(name: String, _ raw: Any) throws -> PatchResourceOverlay.Color {
        // Bare value: a hex string or [r,g,b(,a)] array = light only.
        if let light = try? rgba(name: name, raw) {
            return PatchResourceOverlay.Color(r: light.r, g: light.g, b: light.b, a: light.a)
        }
        // Object: { light: ..., dark?: ... }.
        guard let obj = raw as? [String: Any] else {
            throw SpecError.badColor(name: name, reason: "expected a hex string, [r,g,b(,a)] array, or { light, dark } object")
        }
        guard let lightRaw = obj["light"] else {
            throw SpecError.badColor(name: name, reason: "object form requires a `light` value")
        }
        let light = try rgba(name: name, lightRaw)
        var dark: PatchResourceOverlay.RGBA?
        if let darkRaw = obj["dark"] { dark = try rgba(name: name, darkRaw) }
        return PatchResourceOverlay.Color(r: light.r, g: light.g, b: light.b, a: light.a, dark: dark)
    }

    /// Parse one RGBA from a hex string or a `[r,g,b(,a)]` array.
    private static func rgba(name: String, _ raw: Any) throws -> PatchResourceOverlay.RGBA {
        if let hex = raw as? String {
            guard let c = parseHex(hex) else {
                throw SpecError.badColor(name: name, reason: "invalid hex color '\(hex)'")
            }
            return c
        }
        if let arr = raw as? [Any] {
            let nums = arr.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard nums.count == 3 || nums.count == 4 else {
                throw SpecError.badColor(name: name, reason: "color array must be [r,g,b] or [r,g,b,a]")
            }
            return PatchResourceOverlay.RGBA(r: nums[0], g: nums[1], b: nums[2], a: nums.count == 4 ? nums[3] : 1)
        }
        throw SpecError.badColor(name: name, reason: "expected a hex string or [r,g,b(,a)] array")
    }

    /// Parse `#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA` into 0…1 components.
    static func parseHex(_ s: String) -> PatchResourceOverlay.RGBA? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        // Expand short forms (#RGB / #RGBA → #RRGGBB / #RRGGBBAA).
        if hex.count == 3 || hex.count == 4 {
            hex = String(hex.flatMap { [$0, $0] })
        }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        func byte(_ start: Int) -> Double {
            let i = hex.index(hex.startIndex, offsetBy: start)
            let j = hex.index(i, offsetBy: 2)
            return Double(UInt8(hex[i..<j], radix: 16) ?? 0) / 255.0
        }
        let a = hex.count == 8 ? byte(6) : 1.0
        return PatchResourceOverlay.RGBA(r: byte(0), g: byte(2), b: byte(4), a: a)
    }

    // MARK: - Strings

    private static func parseStrings(_ strings: [String: Any], into table: inout PatchResourceOverlay.Table) throws {
        for (topKey, raw) in strings {
            if let s = raw as? String {
                // Base-locale plain override.
                addString(&table, locale: "", key: topKey, value: s, tableName: "")
            } else if let obj = raw as? [String: Any] {
                if isStringOverrideObject(obj) {
                    // Base-locale {value, table} override.
                    let value = (obj["value"] as? String) ?? ""
                    let tableName = (obj["table"] as? String) ?? ""
                    addString(&table, locale: "", key: topKey, value: value, tableName: tableName)
                } else {
                    // A locale map: topKey is a locale code; recurse for its entries.
                    let locale = topKey
                    for (key, inner) in obj {
                        if let s = inner as? String {
                            addString(&table, locale: locale, key: key, value: s, tableName: "")
                        } else if let io = inner as? [String: Any], isStringOverrideObject(io) {
                            let value = (io["value"] as? String) ?? ""
                            let tableName = (io["table"] as? String) ?? ""
                            addString(&table, locale: locale, key: key, value: value, tableName: tableName)
                        } else {
                            throw SpecError.malformed("strings.\(locale).\(key) must be a string or {value, table}")
                        }
                    }
                }
            } else {
                throw SpecError.malformed("strings.\(topKey) must be a string, {value, table}, or a locale map")
            }
        }
    }

    /// True iff `obj` looks like a `{value, table}` override (vs a locale map). An
    /// override object has a `value` key (and only reserved keys).
    private static func isStringOverrideObject(_ obj: [String: Any]) -> Bool {
        obj["value"] != nil && Set(obj.keys).isSubset(of: stringOverrideKeys)
    }

    private static func addString(_ table: inout PatchResourceOverlay.Table,
                                  locale: String, key: String, value: String, tableName: String) {
        table.strings[locale, default: [:]][key] =
            PatchResourceOverlay.StringOverride(key: key, value: value, table: tableName)
    }

    // MARK: - Images

    private static func parseImage(name: String, _ raw: Any, baseDir: URL) throws -> PatchResourceOverlay.ImageOverride {
        guard let obj = raw as? [String: Any] else {
            throw SpecError.malformed("images.\(name) must be an object")
        }
        let scale = UInt8(((obj["scale"] as? NSNumber)?.intValue) ?? 0)
        // External ref (large-asset channel — bytes out of band).
        if let ref = obj["ref"] as? String {
            return PatchResourceOverlay.ImageOverride(
                kind: .ref, scale: scale, mime: (obj["mime"] as? String) ?? "",
                payload: Array(ref.utf8))
        }
        // Inline a local file's bytes.
        guard let path = obj["path"] as? String else {
            throw SpecError.malformed("images.\(name) requires a `path` or `ref`")
        }
        let fileURL = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : baseDir.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: fileURL) else {
            throw SpecError.imageFileMissing(name: name, path: fileURL.path)
        }
        let mime = (obj["mime"] as? String) ?? mimeForExtension(fileURL.pathExtension)
        return PatchResourceOverlay.ImageOverride(
            kind: .inline, scale: scale, mime: mime, payload: [UInt8](data))
    }

    private static func mimeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "pdf": return "application/pdf"
        case "heic": return "image/heic"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return ""
        }
    }
}
