import Foundation

/// The Patch RESOURCE-OVERLAY chunk decoder — the on-device counterpart of the CLI's
/// `PatchResourceOverlay`. A small, versioned, NON-WASM table the SDK installs as a
/// name-lookup redirection so a patch can override named **colors** and localized
/// **strings** (and carry the hook for bundle **images**) in BOTH SwiftUI and
/// UIKit/storyboard apps, with no view-IR (see `docs/UIKIT-COVERAGE.md` §B.2).
///
/// The overlay rides the patch artifact as an outer `POVR` envelope around the WASM
/// module (`PatchOverlayArtifact`); the SDK strips it, verifies + caches it alongside
/// the module in `ModuleStorage`, and a redirection layer (`ResourceOverlayRedirect`,
/// installed by ObjC swizzling the shipped accessors) consults the active overlay
/// FIRST, else falls through to the bundle.
///
/// ## Wire format (little-endian) — MUST match the CLI encoder byte-for-byte
/// ```
/// magic   : 4 bytes = "PROV"            (Patch ResourceOVerlay)
/// version : u8      = 1
/// flags   : u8      = 0
/// reserved: u16     = 0
/// colorCount  : u32
///   for each color: nameLen u32, name UTF-8, hasDark u8, light 4×f64, dark 4×f64?
/// localeCount : u32
///   for each locale: localeLen u32, locale UTF-8, entryCount u32,
///       for each entry: keyLen u32 key, valLen u32 value, tableLen u32 table
/// imageCount  : u32
///   for each image: nameLen u32 name, kind u8, scale u8, mimeLen u32 mime,
///                   payloadLen u32, payload bytes
/// ```
public enum PatchResourceOverlay {

    public static let magic: [UInt8] = [0x50, 0x52, 0x4F, 0x56]  // "PROV"
    public static let version: UInt8 = 1

    // MARK: - Model

    /// An sRGB color override (light + optional dark variant), components in 0…1.
    public struct Color: Equatable, Sendable {
        public var r: Double, g: Double, b: Double, a: Double
        public var dark: RGBA?
        public init(r: Double, g: Double, b: Double, a: Double = 1, dark: RGBA? = nil) {
            self.r = r; self.g = g; self.b = b; self.a = a; self.dark = dark
        }
        public var light: RGBA { RGBA(r: r, g: g, b: b, a: a) }
    }

    public struct RGBA: Equatable, Sendable {
        public var r: Double, g: Double, b: Double, a: Double
        public init(r: Double, g: Double, b: Double, a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
    }

    public struct StringOverride: Equatable, Sendable {
        public var key: String
        public var value: String
        public var table: String
        public init(key: String, value: String, table: String = "") {
            self.key = key; self.value = value; self.table = table
        }
    }

    public struct ImageOverride: Equatable, Sendable {
        public enum Kind: UInt8, Equatable, Sendable { case inline = 0, ref = 1 }
        public var kind: Kind
        public var scale: UInt8
        public var mime: String
        public var payload: [UInt8]
        public init(kind: Kind, scale: UInt8 = 0, mime: String = "", payload: [UInt8]) {
            self.kind = kind; self.scale = scale; self.mime = mime; self.payload = payload
        }
    }

    /// The full overlay table: named colors, localized strings (grouped by locale),
    /// named images. All maps are keyed by the bundle LOOKUP NAME.
    public struct Table: Equatable, Sendable {
        public var colors: [String: Color]
        /// locale ("" = base) → key → override.
        public var strings: [String: [String: StringOverride]]
        public var images: [String: ImageOverride]
        public init(colors: [String: Color] = [:],
                    strings: [String: [String: StringOverride]] = [:],
                    images: [String: ImageOverride] = [:]) {
            self.colors = colors; self.strings = strings; self.images = images
        }

        public var isEmpty: Bool { colors.isEmpty && strings.isEmpty && images.isEmpty }
        public var stringCount: Int { strings.values.reduce(0) { $0 + $1.count } }

        // MARK: Lookup (the redirect's read path)

        /// The color override for `name`, or nil.
        public func color(named name: String) -> Color? { colors[name] }

        /// The string override for `key` in `table`, resolved with locale fallback:
        /// the requested `locale` → its language-only prefix (`pt-BR` → `pt`) → base
        /// ("") . `nil` table arg matches both the default-table override (`table==""`)
        /// and a same-key override regardless of table (best-effort). Returns nil if
        /// no override matches.
        public func string(forKey key: String, table tableName: String?, locale: String?) -> String? {
            // Build the locale lookup chain, most-specific first.
            var chain: [String] = []
            if let locale, !locale.isEmpty {
                chain.append(locale)
                if let dash = locale.firstIndex(where: { $0 == "-" || $0 == "_" }) {
                    chain.append(String(locale[..<dash]))
                }
            }
            chain.append("")   // base
            for loc in chain {
                guard let entries = strings[loc], let o = entries[key] else { continue }
                // Match the table when one was requested + the override pins a table.
                if let want = tableName, !want.isEmpty, !o.table.isEmpty, o.table != want { continue }
                return o.value
            }
            return nil
        }

        /// The image override for `name`, or nil.
        public func image(named name: String) -> ImageOverride? { images[name] }
    }

    // MARK: - Decode

    public static func isOverlay(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && Array(bytes.prefix(4)) == magic
    }

    public static func decode(_ bytes: [UInt8]) -> Table? {
        guard isOverlay(bytes), bytes.count >= 8, bytes[4] == version else { return nil }
        var i = 8
        var table = Table()

        guard let colorCount = readU32(bytes, &i) else { return nil }
        for _ in 0..<colorCount {
            guard let name = readString(bytes, &i), i < bytes.count else { return nil }
            let hasDark = bytes[i]; i += 1
            guard let r = readF64(bytes, &i), let g = readF64(bytes, &i),
                  let b = readF64(bytes, &i), let a = readF64(bytes, &i) else { return nil }
            var dark: RGBA?
            if hasDark == 1 {
                guard let dr = readF64(bytes, &i), let dg = readF64(bytes, &i),
                      let db = readF64(bytes, &i), let da = readF64(bytes, &i) else { return nil }
                dark = RGBA(r: dr, g: dg, b: db, a: da)
            }
            table.colors[name] = Color(r: r, g: g, b: b, a: a, dark: dark)
        }

        guard let localeCount = readU32(bytes, &i) else { return nil }
        for _ in 0..<localeCount {
            guard let locale = readString(bytes, &i),
                  let entryCount = readU32(bytes, &i) else { return nil }
            var entries: [String: StringOverride] = [:]
            for _ in 0..<entryCount {
                guard let key = readString(bytes, &i),
                      let value = readString(bytes, &i),
                      let tbl = readString(bytes, &i) else { return nil }
                entries[key] = StringOverride(key: key, value: value, table: tbl)
            }
            table.strings[locale] = entries
        }

        guard let imageCount = readU32(bytes, &i) else { return nil }
        for _ in 0..<imageCount {
            guard let name = readString(bytes, &i), i < bytes.count else { return nil }
            guard let kind = ImageOverride.Kind(rawValue: bytes[i]) else { return nil }
            i += 1
            guard i < bytes.count else { return nil }
            let scale = bytes[i]; i += 1
            guard let mime = readString(bytes, &i),
                  let payloadLen = readU32(bytes, &i),
                  i + Int(payloadLen) <= bytes.count else { return nil }
            let payload = Array(bytes[i..<i + Int(payloadLen)]); i += Int(payloadLen)
            table.images[name] = ImageOverride(kind: kind, scale: scale, mime: mime, payload: payload)
        }
        return table
    }

    /// Encode a `Table` (used by tests; the CLI is the production producer). Mirrors
    /// the CLI encoder exactly so a round-trip is byte-stable.
    public static func encode(_ table: Table) -> [UInt8] {
        var out = magic
        out.append(version); out.append(0); out.append(0); out.append(0)
        appendU32(&out, UInt32(table.colors.count))
        for name in table.colors.keys.sorted() {
            let c = table.colors[name]!
            appendString(&out, name)
            out.append(c.dark == nil ? 0 : 1)
            appendF64(&out, c.r); appendF64(&out, c.g); appendF64(&out, c.b); appendF64(&out, c.a)
            if let d = c.dark { appendF64(&out, d.r); appendF64(&out, d.g); appendF64(&out, d.b); appendF64(&out, d.a) }
        }
        appendU32(&out, UInt32(table.strings.count))
        for locale in table.strings.keys.sorted() {
            let entries = table.strings[locale]!
            appendString(&out, locale)
            appendU32(&out, UInt32(entries.count))
            for key in entries.keys.sorted() {
                let o = entries[key]!
                appendString(&out, o.key); appendString(&out, o.value); appendString(&out, o.table)
            }
        }
        appendU32(&out, UInt32(table.images.count))
        for name in table.images.keys.sorted() {
            let img = table.images[name]!
            appendString(&out, name)
            out.append(img.kind.rawValue); out.append(img.scale)
            appendString(&out, img.mime)
            appendU32(&out, UInt32(img.payload.count))
            out.append(contentsOf: img.payload)
        }
        return out
    }

    // MARK: - Byte helpers (little-endian)

    static func appendU32(_ out: inout [UInt8], _ n: UInt32) {
        out.append(UInt8(n & 0xFF)); out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8((n >> 16) & 0xFF)); out.append(UInt8((n >> 24) & 0xFF))
    }
    static func appendF64(_ out: inout [UInt8], _ v: Double) {
        var bits = v.bitPattern
        for _ in 0..<8 { out.append(UInt8(bits & 0xFF)); bits >>= 8 }
    }
    static func appendString(_ out: inout [UInt8], _ s: String) {
        let b = Array(s.utf8); appendU32(&out, UInt32(b.count)); out.append(contentsOf: b)
    }
    static func readU32(_ bytes: [UInt8], _ i: inout Int) -> UInt32? {
        guard i + 4 <= bytes.count else { return nil }
        let n = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
            | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
        i += 4; return n
    }
    static func readF64(_ bytes: [UInt8], _ i: inout Int) -> Double? {
        guard i + 8 <= bytes.count else { return nil }
        var bits: UInt64 = 0
        for k in 0..<8 { bits |= UInt64(bytes[i + k]) << (8 * k) }
        i += 8; return Double(bitPattern: bits)
    }
    static func readString(_ bytes: [UInt8], _ i: inout Int) -> String? {
        guard let len = readU32(bytes, &i), i + Int(len) <= bytes.count else { return nil }
        let s = String(decoding: bytes[i..<i + Int(len)], as: UTF8.self)
        i += Int(len); return s
    }
}

/// The Patch OVERLAY ARTIFACT wrapper decoder — the on-device counterpart of the CLI's
/// `PatchOverlayArtifact`. A thin `POVR` envelope `[header][overlay chunk][inner
/// artifact]`. The SDK strips the overlay (installs the redirection table) and hands
/// the INNER bytes — a verbatim raw `.wasm` / `PMOD` — to the unchanged module
/// instantiation path. A blob WITHOUT the `POVR` magic decodes to nil → the SDK
/// treats it as a raw module exactly as before (full back-compat).
///
/// ## Wire format (little-endian) — MUST match the CLI encoder
/// ```
/// magic    : 4 bytes = "POVR"
/// version  : u8 = 1, reserved u8, reserved u16
/// overlayLen : u32, overlayBytes : overlayLen
/// innerLen   : u32, innerBytes   : innerLen
/// ```
public enum PatchOverlayArtifact {

    public static let magic: [UInt8] = [0x50, 0x4F, 0x56, 0x52]  // "POVR"
    public static let version: UInt8 = 1

    public static func isOverlayArtifact(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && Array(bytes.prefix(4)) == magic
    }

    public struct Decoded: Equatable, Sendable {
        public let overlay: [UInt8]
        public let inner: [UInt8]
    }

    public static func decode(_ bytes: [UInt8]) -> Decoded? {
        guard isOverlayArtifact(bytes), bytes.count >= 8, bytes[4] == version else { return nil }
        var i = 8
        guard let overlayLen = readU32(bytes, &i), i + Int(overlayLen) <= bytes.count else { return nil }
        let overlay = Array(bytes[i..<i + Int(overlayLen)]); i += Int(overlayLen)
        guard let innerLen = readU32(bytes, &i), i + Int(innerLen) <= bytes.count else { return nil }
        let inner = Array(bytes[i..<i + Int(innerLen)]); i += Int(innerLen)
        return Decoded(overlay: overlay, inner: inner)
    }

    /// Encode (used by tests; the CLI is the production producer).
    public static func encode(inner: [UInt8], overlay: [UInt8]) -> [UInt8] {
        var out = magic
        out.append(version); out.append(0); out.append(0); out.append(0)
        appendU32(&out, UInt32(overlay.count)); out.append(contentsOf: overlay)
        appendU32(&out, UInt32(inner.count)); out.append(contentsOf: inner)
        return out
    }

    static func appendU32(_ out: inout [UInt8], _ n: UInt32) {
        out.append(UInt8(n & 0xFF)); out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8((n >> 16) & 0xFF)); out.append(UInt8((n >> 24) & 0xFF))
    }
    static func readU32(_ bytes: [UInt8], _ i: inout Int) -> UInt32? {
        guard i + 4 <= bytes.count else { return nil }
        let n = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
            | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
        i += 4; return n
    }
}
