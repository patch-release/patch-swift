// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Patch RESOURCE-OVERLAY chunk — a small, versioned, NON-WASM table shipped
/// alongside the WASM module(s) so a patch can override named **colors** and
/// localized **strings** (and carry the hook for bundle **images**) in BOTH SwiftUI
/// and UIKit/storyboard apps, with no view-IR (see `docs/UIKIT-COVERAGE.md` §B.2).
///
/// ## What this is (and is not)
/// This is *data*, not code. It maps a bundle lookup NAME (`UIColor(named:)`,
/// `Color("name")`, `NSLocalizedString`/`Bundle.localizedString`, `UIImage(named:)`)
/// to a Patch-shipped override. The on-device SDK installs a name-lookup redirection
/// (ObjC swizzling of the shipped accessors) that consults this table FIRST, else
/// falls through to the bundle — so overriding a color/string is ZERO dev work and
/// never touches the signed bundle. The table is the producer (CLI) side; the SDK
/// has a byte-for-byte-compatible decoder (`sdk`'s `PatchResourceOverlay`).
///
/// ## Wire format (little-endian) — KEEP IN SYNC with the SDK decoder
/// A self-describing TLV-ish layout, versioned so the format can grow:
/// ```
/// magic   : 4 bytes = "PROV"            (Patch ResourceOVerlay)
/// version : u8      = 1
/// flags   : u8      = 0                 (reserved)
/// reserved: u16     = 0
/// colorCount  : u32
///   for each color:
///     nameLen : u32, name : UTF-8 bytes
///     hasDark : u8  (0/1)
///     light   : 4×f64 (r,g,b,a in 0…1, sRGB)
///     dark    : 4×f64 (present iff hasDark==1)
/// localeCount : u32                      (a string table per locale; "" = base)
///   for each locale:
///     localeLen : u32, locale : UTF-8 bytes   ("" = base / unscoped)
///     entryCount : u32
///       for each entry:
///         keyLen : u32, key : UTF-8
///         valLen : u32, value : UTF-8
///         tableLen : u32, table : UTF-8        ("" = default .strings table)
/// imageCount  : u32
///   for each image:
///     nameLen : u32, name : UTF-8
///     kind    : u8   (0 = inline bytes, 1 = external ref by id)
///     scale   : u8   (1,2,3 — the @Nx; 0 = unspecified)
///     mimeLen : u32, mime : UTF-8         ("" = unspecified)
///     payloadLen : u32, payload : bytes   (raw image bytes when kind==0; the
///                                          external-id UTF-8 bytes when kind==1)
/// ```
/// Strings + colors are FULLY supported end-to-end. Images define the chunk + the
/// redirect path with an HONEST SIZE CAVEAT: inline image bytes bloat the artifact
/// (which rides Cloud Run's request path), so large images should ship via the
/// external-ref kind once a dedicated large-asset channel exists. The table format
/// and the on-device `UIImage(named:)` redirect are wired so colors/strings work
/// today and images are a drop-in once the payload channel lands.
public enum PatchResourceOverlay {

    /// Overlay chunk magic `PROV`. Distinct from wasm `\0asm` and the `PMOD`
    /// container magic so an overlay blob is never mistaken for either.
    public static let magic: [UInt8] = [0x50, 0x52, 0x4F, 0x56]  // "PROV"
    public static let version: UInt8 = 1

    // MARK: - Model

    /// An sRGB color override (light + optional dark variant), components in 0…1.
    public struct Color: Equatable, Sendable {
        public var r: Double, g: Double, b: Double, a: Double
        /// Optional dark-appearance variant. When nil the light color is used in
        /// both appearances (the SDK builds a non-dynamic `UIColor`).
        public var dark: RGBA?
        public init(r: Double, g: Double, b: Double, a: Double = 1, dark: RGBA? = nil) {
            self.r = r; self.g = g; self.b = b; self.a = a; self.dark = dark
        }
        public var light: RGBA { RGBA(r: r, g: g, b: b, a: a) }
    }

    /// A bare RGBA tuple (used for the optional dark variant).
    public struct RGBA: Equatable, Sendable {
        public var r: Double, g: Double, b: Double, a: Double
        public init(r: Double, g: Double, b: Double, a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
    }

    /// A single localized-string override. `table` scopes it to a `.strings`
    /// table name (empty = the default `Localizable.strings`); `locale` is held
    /// at the `Table.strings` level so the wire format groups by locale.
    public struct StringOverride: Equatable, Sendable {
        public var key: String
        public var value: String
        public var table: String
        public init(key: String, value: String, table: String = "") {
            self.key = key; self.value = value; self.table = table
        }
    }

    /// An image override. `kind == .inline` carries the raw bytes; `kind == .ref`
    /// carries an external id (for a future large-asset channel — the bytes are
    /// fetched out-of-band). See the size caveat in the type docs.
    public struct ImageOverride: Equatable, Sendable {
        public enum Kind: UInt8, Equatable, Sendable { case inline = 0, ref = 1 }
        public var kind: Kind
        /// The @Nx scale (1/2/3); 0 = unspecified.
        public var scale: UInt8
        /// MIME type (e.g. "image/png"); empty = unspecified.
        public var mime: String
        /// Raw bytes (kind == .inline) or the external id UTF-8 bytes (kind == .ref).
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

        /// Total string-override count across all locales (for build reporting).
        public var stringCount: Int { strings.values.reduce(0) { $0 + $1.count } }
    }

    // MARK: - Encode

    /// True iff `bytes` begins with the overlay magic.
    public static func isOverlay(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && Array(bytes.prefix(4)) == magic
    }

    /// Serialize a `Table` into the overlay chunk wire format.
    public static func encode(_ table: Table) -> [UInt8] {
        var out = magic
        out.append(version)
        out.append(0)            // flags
        out.append(0); out.append(0)   // reserved u16

        // Colors — sorted by name for a STABLE, reproducible artifact (so a repeat
        // build hashes identically: the backend SHAs the bytes).
        appendU32(&out, UInt32(table.colors.count))
        for name in table.colors.keys.sorted() {
            let c = table.colors[name]!
            appendString(&out, name)
            out.append(c.dark == nil ? 0 : 1)
            appendF64(&out, c.r); appendF64(&out, c.g); appendF64(&out, c.b); appendF64(&out, c.a)
            if let d = c.dark {
                appendF64(&out, d.r); appendF64(&out, d.g); appendF64(&out, d.b); appendF64(&out, d.a)
            }
        }

        // Strings — grouped by locale, both locale + key sorted for stability.
        appendU32(&out, UInt32(table.strings.count))
        for locale in table.strings.keys.sorted() {
            let entries = table.strings[locale]!
            appendString(&out, locale)
            appendU32(&out, UInt32(entries.count))
            for key in entries.keys.sorted() {
                let o = entries[key]!
                appendString(&out, o.key)
                appendString(&out, o.value)
                appendString(&out, o.table)
            }
        }

        // Images.
        appendU32(&out, UInt32(table.images.count))
        for name in table.images.keys.sorted() {
            let img = table.images[name]!
            appendString(&out, name)
            out.append(img.kind.rawValue)
            out.append(img.scale)
            appendString(&out, img.mime)
            appendU32(&out, UInt32(img.payload.count))
            out.append(contentsOf: img.payload)
        }
        return out
    }

    // MARK: - Decode

    /// Decode an overlay chunk; nil if the bytes are not a well-formed overlay.
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
