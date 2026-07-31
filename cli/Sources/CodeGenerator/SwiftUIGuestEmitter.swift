// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Emits the **SwiftUI guest WASM module** that ships a lowered `View.body`.
///
/// ## What this produces
/// The proven `swiftui-wasm` package showed that a declarative SwiftUI body can be
/// LOWERED to a `ViewNode` IR that is *built and serialized by real WASM*, then
/// reconstituted into native SwiftUI by the on-device SDK renderer. This emitter is
/// the production-engine half: given the `FrontierLower` Emitter's `N.`-builder
/// expression for a body, it generates a self-contained guest compile unit:
///
///   * the embeddable ViewNode IR sources (copied verbatim from the canonical
///     `ViewNodeIR` target via CodeGenerator resources — ONE source of truth), and
///   * a `_PatchSwiftUI.swift` file with the SDK's `patch_malloc`/`patch_free`
///     allocator and one `@_cdecl("view_body__<View>")(ptr:i32,len:i32) -> i64`
///     export per lowered view. Each export BUILDS the ViewNode tree in WASM (via
///     the emitted `N.*` expression) and returns the packed `(outPtr<<32)|outLen`
///     of the JSON-encoded `BodyEmission` (root tree + self-reported coverage).
///
/// ## Wire format (the contract the SDK renderer must match)
///   * ABI: `view_body[/__<View>](ptr,len) -> i64`, packed `(outPtr<<32)|outLen`.
///   * Payload: JSON of `BodyEmission` = `{ "root": <ViewNode>, "coverage": {…}? }`,
///     where the ViewNode JSON is Swift's *synthesized Codable* shape (an enum case
///     is a single-key object). `EmbeddedJSON` (Foundation-free) emits exactly that,
///     so the SDK's `JSONDecoder` reads it unchanged at any tier.
///
/// The single `view_body` export (no suffix) is also emitted for the FIRST lowered
/// view, so a single-view app keeps the canonical export name the SDK expects.
public struct SwiftUIGuestEmitter {
    public init() {}

    /// A lowered view ready to emit into the guest: a sanitized export base name, the
    /// `N.`-builder expression (from `BodyLowering.lowerAllViews`), and the view's
    /// inputs (the stored properties the body references, marshalled in from JSON).
    public struct GuestView: Sendable {
        public let viewName: String
        /// The `N.<…>` expression that builds the ViewNode tree.
        public let guestBody: String
        /// The body's inputs, bound from the JSON `(ptr,len)` blob at call time.
        public let inputs: [BodyLowering.ViewInput]
        /// The interactive state model (Breakthrough #5 productization). When set
        /// (≥1 field + ≥1 rule), the emitter ALSO ships a `dispatch` export that
        /// applies the UPDATE rules IN WASM and re-emits `{newState, newTree}`.
        public let stateModel: BodyLowering.StateModel?
        /// Whether this view's body lowered COMPLETELY (every node + modifier rode
        /// WASM, zero `.opaque` fallbacks). Only a fully-lowered body is safe to
        /// AUTO-ROUTE through the on-device renderer with no `PatchView`: a partial
        /// lowering would drop a modifier or render an empty slot where native
        /// content belongs. Surfaced per-view in the `patch_view_manifest` so the
        /// SDK's view-patching registry routes only `thunkSafe` views and leaves the
        /// rest native. (A non-thunkSafe view can still render via the explicit
        /// `Patch.patchView(viewBodyExport:)`.)
        public let thunkSafe: Bool
        /// True when the body contains ≥1 `GeometryReader` (C): the guest must bind
        /// the reserved `__geo_*` inputs (width/height/minX/minY) from the input JSON
        /// so the lowered child compiles + reads the SDK-injected live proxy values.
        public let usesGeometry: Bool
        /// The HOST TOKENS the lowered body references that ride the INPUT JSON — a
        /// NUMERIC design token (`Theme.Radius.lg` in a `.cornerRadius(…)`/`.padding(…)`/
        /// `frame` position) bound under `__numtok_<id>`, and a STRING host token (an
        /// enum's computed-String `Text(…)` content like `confidence.label`) bound under
        /// `__strtok_<id>`. Each binds from the input JSON (the SDK injects the
        /// thunk-resolved value there, like a `__geo_*` input) — so the body reads the
        /// real value in WASM instead of leaking `Theme`/the enum input as a free symbol.
        /// (Color/font tokens are NOT here — they ride the rendered tree.)
        public let inputTokens: [BodyLowering.HostToken]
        /// PARAMETERIZED NATIVE SLOTS — for each `.opaque` slot id in this view's
        /// lowered body whose native custom-view call had simple string-literal
        /// args LIFTED out, the lifted values in source order. The emitter bakes
        /// these into the guest's `BodyEmission.slotArgs` so the CURRENT literal
        /// values ride WASM; the SDK renders the leaf via the thunk's
        /// parameterized factory applied to them. Editing a literal recompiles the
        /// guest (new value here) but the structural slot id is UNCHANGED, so the
        /// edit ships OTA and the native-shell fingerprint stays stable. Empty for
        /// a view with no parameterized slot.
        public let slotArgs: [String: [String]]
        /// The MINIMUM IR schema version a host must support to render this view (per-view
        /// version gate). Default 8 (the current feature surface); 9 for a view that marshals a
        /// reactive view-model collection (needs the SDK's reactive-`extract`, IR v9). The SDK
        /// gates PER-VIEW on this — an older host renders the views it can and DEMOTES only the
        /// ones requiring a newer schema (so one v9 view never poisons its v8 siblings).
        public let minSchemaVersion: Int
        /// The per-view body content hash (NATIVE-FAST-PATH) — `BodyLowering.viewBodyContentHash`
        /// over this view's `guestBody` + parameterized-slot literals. Emitted into the manifest
        /// as `"bodyHash"` so the SDK can compare it against the thunk's baked `baselineHash`: a
        /// MATCH means the active module's body for this view is byte-identical to the build's
        /// shipped baseline (no OTA patch touched it), so the thunk renders NATIVE with zero WASM.
        /// `nil` (legacy/unhashable) ⇒ no fast-path key emitted (the SDK fail-safes to WASM).
        public let bodyHash: String?
        /// STRUCTURALLY-STATIC CACHE: when true, the engine proved that the WASM-emitted ViewNode
        /// tree for this view is identical across ALL inputs — no bound input name appears in a live
        /// tree position, no input-riding host token is present, no GeometryReader, and no interactive
        /// state model. The SDK may cache the decoded tree after the FIRST WASM call and skip WASM on
        /// ALL subsequent renders. Emitted as `"isStructurallyStatic":true` in the manifest (omitted
        /// when false to keep the JSON compact). ADDITIVE + backward-decode safe: `false`/absent =
        /// always-WASM (the safe prior behavior).
        public let isStructurallyStatic: Bool
        public init(viewName: String, guestBody: String,
                    inputs: [BodyLowering.ViewInput] = [],
                    stateModel: BodyLowering.StateModel? = nil,
                    thunkSafe: Bool = false,
                    usesGeometry: Bool = false,
                    inputTokens: [BodyLowering.HostToken] = [],
                    slotArgs: [String: [String]] = [:],
                    minSchemaVersion: Int = 8,
                    bodyHash: String? = nil,
                    isStructurallyStatic: Bool = false) {
            self.viewName = viewName
            self.guestBody = guestBody
            self.inputs = inputs
            self.stateModel = stateModel
            self.thunkSafe = thunkSafe
            self.usesGeometry = usesGeometry
            self.inputTokens = inputTokens
            self.slotArgs = slotArgs
            self.minSchemaVersion = minSchemaVersion
            self.bodyHash = bodyHash
            self.isStructurallyStatic = isStructurallyStatic
        }
    }

    /// One generated file to write into the guest compile unit.
    public struct File: Sendable {
        public let fileName: String
        public let contents: String
        public init(fileName: String, contents: String) {
            self.fileName = fileName
            self.contents = contents
        }
    }

    public struct Emission: Sendable {
        /// All `.swift` files to compile into the guest module (IR + wrapper).
        public let files: [File]
        /// The `@_cdecl` export symbols the module offers (view bodies + allocator).
        public let exports: [String]
        public init(files: [File], exports: [String]) {
            self.files = files
            self.exports = exports
        }
    }

    public enum EmitError: Error, CustomStringConvertible {
        case irResourcesMissing
        public var description: String {
            switch self {
            case .irResourcesMissing:
                return "SwiftUI guest IR resources (GuestIR/*.swifttext) not found in the CodeGenerator bundle"
            }
        }
    }

    /// The embeddable IR resource basenames, copied verbatim into the guest module.
    /// (ViewNode + Builder + BodyEmission + Dispatch + JSONEmit — the Foundation-free
    /// subset; the host-only `ABI.swift` JSONEncoder path is NOT shipped.)
    static let irResourceNames = ["ViewNode", "Builder", "BodyEmission", "Dispatch", "JSONEmit"]

    /// Read the canonical IR sources from the CodeGenerator resource bundle.
    public func irSources() throws -> [File] {
        var out: [File] = []
        for name in Self.irResourceNames {
            guard let url = Bundle.module.url(
                    forResource: name, withExtension: "swifttext", subdirectory: "GuestIR"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw EmitError.irResourcesMissing
            }
            out.append(File(fileName: "_ViewNodeIR_\(name).swift", contents: text))
        }
        return out
    }

    /// The embeddable UIKit IR resource basenames (the UIKit analogue of the
    /// SwiftUI `irResourceNames`). These live in `GuestIR/UIKit/` and define the
    /// `UIKitNode` IR + its `UI.` builder + the Foundation-free
    /// `UIKitEmbeddedJSON` emitter. They REUSE the shared value types
    /// (`IRColor`/`ColorRef`/`IRFont`/`IREdgeInsets`/`EventID`) AND the
    /// `JSONOut`/`EmbeddedJSON` plumbing declared in the SwiftUI IR sources
    /// (`ViewNode`/`JSONEmit`), so a UIKit guest module ships BOTH the SwiftUI IR
    /// (`irSources()`) AND these — never these alone.
    static let uikitIRResourceNames = ["UIKitNode", "UIKitBuilder", "UIKitJSONEmit"]

    /// Read the canonical UIKit IR sources from the CodeGenerator resource bundle
    /// (the `GuestIR/UIKit/` subdirectory). A guard test asserts each is
    /// byte-identical to the canonical `ViewNodeIR` source, catching drift.
    public func uikitIRSources() throws -> [File] {
        var out: [File] = []
        for name in Self.uikitIRResourceNames {
            guard let url = Bundle.module.url(
                    forResource: name, withExtension: "swifttext", subdirectory: "GuestIR/UIKit"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw EmitError.irResourcesMissing
            }
            out.append(File(fileName: "_ViewNodeIR_\(name).swift", contents: text))
        }
        return out
    }

    /// The guest export name carrying the view manifest (must match the SDK's
    /// `PatchViewManifest.exportName`).
    public static let manifestExport = "patch_view_manifest"
    /// The manifest's BASE feature-surface schema version — the floor a host needs to render a
    /// view that uses only the always-available surface. The ACTUAL module stamp is the MAX of the
    /// per-view `minVersion`s (see `moduleSchemaVersion` below), and each view that uses a
    /// version-gated feature bumps its own `minVersion` so an older host demotes only that view.
    /// v4 adds the design-system token cases (`ColorRef.hostToken`/`Modifier.fontToken`).
    /// v5 adds the scroll/layout modifier cases (scrollDisabled/scrollIndicators/
    /// scrollTargetBehavior/scrollTargetLayout/scrollBounceBehavior/contentMargins/
    /// safeAreaPadding).
    /// v8 adds the per-row indexed native-action slot (`NodeKind.indexedForEachSlot`).
    /// v9 adds the reactive-collection marshalling capability + `NodeKind.actionSlotButton`
    /// (per-view-gated). v10 adds the `Modifier.nativeEffectSlot` case (per-view-gated to 10).
    /// v11 adds FAITHFUL `.animation(_:value:)` rendering (no new wire case — a per-view RENDER-
    /// FIDELITY gate: a view USING `.animation(value:)` stamps `minVersion` 11 so an older host,
    /// whose renderer would NO-OP the animation, demotes it to native instead of rendering the
    /// value change instantly; per-view-gated to 11).
    /// The current SDK `PatchViewIRSchema.version` is 11; this base stays 8 because a non-gated
    /// view renders on a v8 host (the gated views stamp their own higher `minVersion`).
    public static let manifestSchemaVersion = 8

    /// Escape a string for embedding as the BODY of a Swift `"..."` literal (the
    /// manifest JSON is baked into the guest source as a string literal).
    static func swiftStringLiteralBody(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }

    /// Render a `[String:[String]]` Swift DICTIONARY LITERAL for a view's
    /// parameterized-slot args (`["op_abc": ["Settings"], …]`), with keys + values
    /// escaped as Swift string literals. Returns `nil` when empty (the emitter
    /// then leaves `BodyEmission.slotArgs` at its `nil` default — no wire bytes).
    /// Emitted in SORTED key order for deterministic output.
    static func slotArgsLiteral(_ slotArgs: [String: [String]]) -> String? {
        guard !slotArgs.isEmpty else { return nil }
        var pairs: [String] = []
        for id in slotArgs.keys.sorted() {
            // A lifted slot VALUE is baked as a guest string literal too, so a non-ASCII one
            // (a lifted `Text("録画品質")` inside a slotted view) rides the same toolchain-robust
            // byte form; ASCII values stay a plain quoted literal (byte-identical). Keys are
            // content-hash ids (always ASCII).
            let values = (slotArgs[id] ?? [])
                .map { GuestNonASCIIEncoder.containsNonASCII($0)
                        ? GuestNonASCIIEncoder.byteDecodeExpr($0)
                        : "\"\(swiftStringLiteralBody($0))\"" }
                .joined(separator: ", ")
            pairs.append("\"\(swiftStringLiteralBody(id))\": [\(values)]")
        }
        return "[\(pairs.joined(separator: ", "))]"
    }

    /// The guest export symbol for a view body. The FIRST view also gets the bare
    /// `view_body` (the canonical SDK contract for single-view apps).
    public static func exportSymbol(forView name: String) -> String {
        "view_body__" + sanitizedViewName(name)
    }

    /// The guest `dispatch` export symbol for an interactive view. The FIRST
    /// interactive view also gets the bare `dispatch` (the canonical SDK contract).
    public static func dispatchExportSymbol(forView name: String) -> String {
        "dispatch__" + sanitizedViewName(name)
    }

    public static func sanitizedViewName(_ raw: String) -> String {
        let s = String(raw.map { ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
        if let f = s.first, f.isNumber { return "_" + s }
        return s.isEmpty ? "View" : s
    }

    /// Swift reserved words that, used as a bare identifier (an enum CASE name here),
    /// MUST be backtick-escaped to emit valid Swift. A source enum may legally declare
    /// `case \`default\``/`\`repeat\``/`\`class\``; `EnumCaseDeclSyntax.name.text`
    /// strips the backticks, so the emitter must re-add them when interpolating the
    /// name into the generated guest `case <name>` / `.<name>` positions. The JSON
    /// `"case"` STRING literal stays the bare name (the wire form uses the bare name).
    static let swiftReservedWords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
        "import", "init", "inout", "internal", "let", "open", "operator", "private",
        "precedencegroup", "protocol", "public", "rethrows", "static", "struct",
        "subscript", "typealias", "var", "break", "case", "continue", "default", "defer",
        "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
        "switch", "where", "while", "as", "false", "is", "nil", "self", "Self", "super",
        "throw", "throws", "true", "try", "Any", "catch", "_",
    ]

    /// Strip any surrounding backticks a source identifier may already carry. The
    /// SwiftSyntax `EnumCaseDeclSyntax.name.text` may or may not keep the backticks of
    /// a `case \`default\`` declaration depending on the toolchain version, so we
    /// normalize to the BARE name and re-add escaping deterministically.
    static func bareIdentifier(_ name: String) -> String {
        var s = Substring(name)
        if s.hasPrefix("`") { s = s.dropFirst() }
        if s.hasSuffix("`") { s = s.dropLast() }
        return String(s)
    }

    /// Backtick-escape a source identifier (an enum case name) when it is a Swift
    /// reserved word, so the emitted guest `case <id>` / `.<id>` is valid Swift. Any
    /// pre-existing backticks are normalized away first (so we never double-wrap).
    static func escapeIdentifier(_ name: String) -> String {
        let bare = bareIdentifier(name)
        return swiftReservedWords.contains(bare) ? "`\(bare)`" : bare
    }

    /// Emit the complete SwiftUI guest module (IR sources + wrapper) for `views`.
    public func emit(views: [GuestView]) throws -> Emission {
        var files = try irSources()
        var exports = ["patch_malloc", "patch_free"]

        var wrapper = """
        // Auto-generated by Patch — SwiftUI guest module. The lowered View.body runs
        // in WASM here: it BUILDS a ViewNode tree (via the `N.` IR builder) and
        // returns the packed (ptr,len) of its JSON-encoded BodyEmission. The native
        // SDK renderer reconstitutes real SwiftUI from that tree. DO NOT EDIT.
        //
        // ABI: view_body[/__<View>](ptr,len) -> i64 = (outPtr<<32)|outLen.
        // Payload: EmbeddedJSON(BodyEmission{root, coverage}) — Codable JSON shape.

        // MARK: - Allocator (SDK malloc/free convention)

        @_cdecl("patch_malloc")
        public func patch_malloc(_ size: Int32) -> UnsafeMutableRawPointer? {
            UnsafeMutableRawPointer.allocate(byteCount: Int(max(size, 1)), alignment: 8)
        }

        @_cdecl("patch_free")
        public func patch_free(_ ptr: UnsafeMutableRawPointer?) {
            ptr?.deallocate()
        }

        // MARK: - Packed (ptr,len) emit

        private func _patchEmit(_ bytes: [UInt8]) -> Int64 {
            let n = bytes.count
            let out = UnsafeMutableRawPointer.allocate(byteCount: max(n, 1), alignment: 8)
            let outBytes = out.assumingMemoryBound(to: UInt8.self)
            for i in 0..<n { outBytes[i] = bytes[i] }
            let outPtr = Int32(bitPattern: UInt32(UInt(bitPattern: out)))
            return (Int64(outPtr) << 32) | Int64(n)
        }

        // MARK: - Foundation-free input marshalling (scalar values from a flat JSON
        // object). The host writes the view's inputs as `{"name":"…","flag":true,…}`;
        // these pull each value out by key. Works at any tier (no JSONDecoder).

        private func _patchReadBytes(_ ptr: Int32, _ len: Int32) -> [UInt8] {
            guard len > 0, let base = UnsafePointer<UInt8>(bitPattern: Int(ptr)) else { return [] }
            return Array(UnsafeBufferPointer(start: base, count: Int(len)))
        }

        private func _patchFind(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
            if needle.isEmpty || haystack.count < needle.count { return nil }
            let last = haystack.count - needle.count
            var i = 0
            while i <= last {
                var j = 0
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
                i += 1
            }
            return nil
        }

        // ONE shared JSON string-escape decoder, called by EVERY string-body decoder
        // (_patchScanString, _patchScanStringArray, _patchObjectEntries,
        // _patchReadStringBytes) so they can never drift on the escape set. s[i]
        // is the backslash; appends the decoded byte(s) to `out` and returns how many
        // input bytes the escape consumed (2 for a simple escape, 6 for a uXXXX BMP
        // escape, 12 for a high+low surrogate pair). A malformed/truncated escape
        // preserves the escaped byte (best-effort) and consumes 2.
        private func _patchDecodeEscape(_ s: [UInt8], _ i: Int, _ hi: Int, _ out: inout [UInt8]) -> Int {
            guard i + 1 < hi else { out.append(0x5C); return 1 }
            let n = s[i + 1]
            switch n {
            case 0x6E: out.append(0x0A); return 2   // n -> newline
            case 0x74: out.append(0x09); return 2   // t -> tab
            case 0x72: out.append(0x0D); return 2   // r -> CR
            case 0x62: out.append(0x08); return 2   // b -> backspace
            case 0x66: out.append(0x0C); return 2   // f -> form feed
            case 0x2F: out.append(0x2F); return 2   // escaped solidus
            case 0x22: out.append(0x22); return 2
            case 0x5C: out.append(0x5C); return 2
            case 0x75:                              // uXXXX (+ optional low surrogate)
                func hex(_ b: UInt8) -> UInt32? {
                    switch b {
                    case 0x30...0x39: return UInt32(b - 0x30)
                    case 0x41...0x46: return UInt32(b - 0x41 + 10)
                    case 0x61...0x66: return UInt32(b - 0x61 + 10)
                    default: return nil
                    }
                }
                guard i + 5 < hi,
                      let h3 = hex(s[i+2]), let h2 = hex(s[i+3]),
                      let h1 = hex(s[i+4]), let h0 = hex(s[i+5]) else {
                    out.append(n); return 2   // malformed — preserve the 'u'
                }
                let u = h3 << 12 | h2 << 8 | h1 << 4 | h0
                // A high surrogate (D800-DBFF) needs a following low surrogate escape.
                if u >= 0xD800, u <= 0xDBFF,
                   i + 11 < hi, s[i+6] == 0x5C, s[i+7] == 0x75,
                   let g3 = hex(s[i+8]), let g2 = hex(s[i+9]),
                   let g1 = hex(s[i+10]), let g0 = hex(s[i+11]) {
                    let lo = g3 << 12 | g2 << 8 | g1 << 4 | g0
                    if lo >= 0xDC00, lo <= 0xDFFF {
                        let cp = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
                        if let scalar = Unicode.Scalar(cp) {
                            out.append(contentsOf: Array(String(scalar).utf8)); return 12
                        }
                    }
                }
                if let scalar = Unicode.Scalar(u) {
                    out.append(contentsOf: Array(String(scalar).utf8)); return 6
                }
                out.append(n); return 2   // unpaired/invalid surrogate — best-effort
            default: out.append(n); return 2
            }
        }

        // Position just after `"<key>":` (skipping whitespace), or nil. JSON allows
        // ANY of space / tab / CR / LF as whitespace around `:` and the value — a
        // pretty-printed or CRLF blob must parse the same as a compact one. Skipping
        // ONLY 0x20 silently left the value-start on a newline/tab, so every input
        // fell back to its default (wrong values shipped).
        //
        // KEY-POSITION + DEPTH-0 ANCHORED: a key matches ONLY when it is a real
        // top-level KEY of the passed-in object bytes — preceded (after whitespace)
        // by `{` / `,` / buffer-start and FOLLOWED (after whitespace) by `:`, at the
        // object's own nesting depth (depth 1 inside a leading `{…}`, else depth 0 for
        // a brace-stripped body). This stops a like-named key INSIDE a nested object/
        // array (or a VALUE string that equals another field's name) from being
        // mistaken for the field — the root cause of the nested-collision family.
        private func _patchValueStart(_ s: [UInt8], _ key: String) -> Int? {
            let kbytes = Array(key.utf8)
            // The object's own key depth: 1 if the buffer (after leading whitespace)
            // opens with `{`, else 0 (a brace-stripped body, as the dict scanners pass).
            var p = 0
            while p < s.count, s[p] == 0x20 || s[p] == 0x09 || s[p] == 0x0A || s[p] == 0x0D { p += 1 }
            let keyDepth = (p < s.count && s[p] == 0x7B) ? 1 : 0
            var i = 0
            var depth = 0
            var inStr = false
            var strStart = -1
            while i < s.count {
                let c = s[i]
                if inStr {
                    if c == 0x5C { i += 2; continue }   // skip an escaped char
                    if c == 0x22 {
                        inStr = false
                        // A closed string at key depth is a candidate KEY iff it is
                        // followed (after whitespace) by `:` and its decoded bytes equal
                        // `key`. (A VALUE string is never followed by `:`, so it's skipped.)
                        if depth == keyDepth {
                            var j = i + 1
                            while j < s.count, s[j] == 0x20 || s[j] == 0x09 || s[j] == 0x0A || s[j] == 0x0D { j += 1 }
                            if j < s.count, s[j] == 0x3A {
                                // Compare the raw key bytes [strStart+1, i) to `key`'s
                                // UTF-8 (keys with escapes are rare; a raw compare is
                                // exact for the common unescaped case the engine emits).
                                let klen = i - (strStart + 1)
                                if klen == kbytes.count {
                                    var eq = true, t = 0
                                    while t < klen { if s[strStart + 1 + t] != kbytes[t] { eq = false; break }; t += 1 }
                                    if eq {
                                        var v = j + 1   // just past ':'
                                        while v < s.count, s[v] == 0x20 || s[v] == 0x09 || s[v] == 0x0A || s[v] == 0x0D { v += 1 }
                                        return v < s.count ? v : nil
                                    }
                                }
                            }
                        }
                    }
                    i += 1; continue
                }
                if c == 0x22 { inStr = true; strStart = i }
                else if c == 0x7B || c == 0x5B { depth += 1 }
                else if c == 0x7D || c == 0x5D { depth -= 1 }
                i += 1
            }
            return nil
        }

        private func _patchScanString(_ s: [UInt8], _ key: String) -> String? {
            guard let start = _patchValueStart(s, key), s[start] == 0x22 else { return nil }
            var i = start + 1
            var out: [UInt8] = []
            while i < s.count {
                let c = s[i]
                if c == 0x5C { i += _patchDecodeEscape(s, i, s.count, &out); continue }
                if c == 0x22 { break }
                out.append(c); i += 1
            }
            return String(decoding: out, as: UTF8.self)
        }

        // Scan a bare JSON token (number / true / false) after a key.
        private func _patchScanToken(_ s: [UInt8], _ key: String) -> String? {
            guard let start = _patchValueStart(s, key) else { return nil }
            var i = start
            var out: [UInt8] = []
            while i < s.count {
                let c = s[i]
                // End the bare token at a delimiter (`,`, `}`, `]`) or ANY JSON
                // whitespace (space, tab, CR, LF). Breaking only on a plain space let a
                // trailing newline/tab leak into the token, so the numeric/bool parse
                // returned nil and the input silently fell back to its default.
                if c == 0x2C || c == 0x7D || c == 0x5D
                    || c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { break }
                out.append(c); i += 1
            }
            return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
        }

        private func _patchScanBool(_ s: [UInt8], _ key: String) -> Bool? {
            guard let t = _patchScanToken(s, key) else { return nil }
            if t == "true" { return true }
            if t == "false" { return false }
            return nil
        }
        private func _patchScanInt(_ s: [UInt8], _ key: String) -> Int? {
            // Int64 parse + 32-bit-`Int` clamp: a value valid on the 64-bit host (e.g.
            // an epoch ms / large id) is PRESERVED (clamped) on the wasm32 guest where
            // `Int` is 32-bit, rather than failing `Int(String)` and silently dropping.
            guard let t = _patchScanToken(s, key) else { return nil }
            if let v = Int(t) { return v }
            if let v64 = Int64(t) {
                let lo = Int64(Int.min), hi = Int64(Int.max)
                return Int(v64 < lo ? lo : (v64 > hi ? hi : v64))
            }
            return nil
        }
        private func _patchScanDouble(_ s: [UInt8], _ key: String) -> Double? {
            _patchScanToken(s, key).flatMap { Double($0) }
        }

        // MARK: - Foundation-free ARRAY-of-scalar input marshalling
        //
        // A `[Int]`/`[String]`/`[Double]`/`[Bool]` `@State`/`let` marshals in as a
        // JSON array (`{"tags":["a","b"]}`); these scan it into a concrete `[T]` so
        // the lowered body reads the REAL array (a `ForEach(items)`, `items.count`,
        // etc.) rather than its compiled-in default. Whitespace-tolerant, byte-level.

        // The byte range [start, end) of the JSON array value for `key` (the bytes
        // between the opening `[` and its matching `]`), or nil if absent/not array.
        private func _patchArrayBody(_ s: [UInt8], _ key: String) -> (Int, Int)? {
            guard let start = _patchValueStart(s, key), start < s.count, s[start] == 0x5B else { return nil }
            var i = start + 1
            var depth = 1
            var inStr = false
            while i < s.count {
                let c = s[i]
                if inStr {
                    if c == 0x5C { i += 2; continue }   // skip an escaped char
                    if c == 0x22 { inStr = false }
                } else {
                    if c == 0x22 { inStr = true }
                    else if c == 0x5B { depth += 1 }
                    else if c == 0x5D { depth -= 1; if depth == 0 { return (start + 1, i) } }
                }
                i += 1
            }
            return nil
        }

        // The byte range [start, end) INCLUSIVE of the surrounding braces of the JSON
        // OBJECT value for `key` (a nested `{…}`), or nil if absent/not an object. Used
        // by the single flat-struct input scanner (TASK 1): it cuts the object's own bytes
        // so the scalar scanners read its fields without matching a like-named key OUTSIDE
        // the object. Brace-matched + string-aware (a `}` inside a string doesn't close it).
        private func _patchObjectBody(_ s: [UInt8], _ key: String) -> (Int, Int)? {
            guard let start = _patchValueStart(s, key), start < s.count, s[start] == 0x7B else { return nil }
            var i = start + 1
            var depth = 1
            var inStr = false
            while i < s.count {
                let c = s[i]
                if inStr {
                    if c == 0x5C { i += 2; continue }   // skip an escaped char
                    if c == 0x22 { inStr = false }
                } else {
                    if c == 0x22 { inStr = true }
                    else if c == 0x7B { depth += 1 }
                    else if c == 0x7D { depth -= 1; if depth == 0 { return (start, i + 1) } }
                }
                i += 1
            }
            return nil
        }

        // Split the array body into element byte-ranges at top-level commas (commas
        // inside nested arrays/objects/strings don't split). Each range is one
        // element's raw bytes (trimmed of surrounding whitespace by the callers).
        private func _patchArrayElements(_ s: [UInt8], _ lo: Int, _ hi: Int) -> [(Int, Int)] {
            var out: [(Int, Int)] = []
            var i = lo
            var elemStart = lo
            var depth = 0
            var inStr = false
            // An empty array body (lo == hi) yields no elements.
            while i < hi {
                let c = s[i]
                if inStr {
                    if c == 0x5C { i += 2; continue }
                    if c == 0x22 { inStr = false }
                } else if c == 0x22 { inStr = true }
                else if c == 0x5B || c == 0x7B { depth += 1 }
                else if c == 0x5D || c == 0x7D { depth -= 1 }
                else if c == 0x2C && depth == 0 { out.append((elemStart, i)); elemStart = i + 1 }
                i += 1
            }
            if elemStart < hi { out.append((elemStart, hi)) }
            return out
        }

        private func _patchTrimRange(_ s: [UInt8], _ lo: Int, _ hi: Int) -> (Int, Int) {
            var a = lo, b = hi
            func ws(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
            while a < b, ws(s[a]) { a += 1 }
            while b > a, ws(s[b - 1]) { b -= 1 }
            return (a, b)
        }

        private func _patchScanIntArray(_ s: [UInt8], _ key: String) -> [Int]? {
            guard let (lo, hi) = _patchArrayBody(s, key) else { return nil }
            var out: [Int] = []
            for (es, ee) in _patchArrayElements(s, lo, hi) {
                let (a, b) = _patchTrimRange(s, es, ee)
                guard a < b else { continue }
                // Int64 parse + 32-bit-`Int` clamp (wasm32): preserve a 64-bit-host
                // element value rather than dropping the whole array on overflow.
                if let v = _patchRangeInt(s, a, b) { out.append(v) } else { return nil }
            }
            return out
        }
        private func _patchScanDoubleArray(_ s: [UInt8], _ key: String) -> [Double]? {
            guard let (lo, hi) = _patchArrayBody(s, key) else { return nil }
            var out: [Double] = []
            for (es, ee) in _patchArrayElements(s, lo, hi) {
                let (a, b) = _patchTrimRange(s, es, ee)
                guard a < b else { continue }
                if let v = Double(String(decoding: s[a..<b], as: UTF8.self)) { out.append(v) } else { return nil }
            }
            return out
        }
        private func _patchScanBoolArray(_ s: [UInt8], _ key: String) -> [Bool]? {
            guard let (lo, hi) = _patchArrayBody(s, key) else { return nil }
            var out: [Bool] = []
            for (es, ee) in _patchArrayElements(s, lo, hi) {
                let (a, b) = _patchTrimRange(s, es, ee)
                guard a < b else { continue }
                let t = String(decoding: s[a..<b], as: UTF8.self)
                if t == "true" { out.append(true) } else if t == "false" { out.append(false) } else { return nil }
            }
            return out
        }
        private func _patchScanStringArray(_ s: [UInt8], _ key: String) -> [String]? {
            guard let (lo, hi) = _patchArrayBody(s, key) else { return nil }
            var out: [String] = []
            for (es, ee) in _patchArrayElements(s, lo, hi) {
                let (a, b) = _patchTrimRange(s, es, ee)
                guard a < b, s[a] == 0x22 else { return nil }
                // Decode the element string via the SHARED escape decoder so `\\uXXXX`
                // (and surrogate pairs / `\\b` / `\\f`) decode identically everywhere.
                var i = a + 1
                var bytes: [UInt8] = []
                while i < b {
                    let c = s[i]
                    if c == 0x5C { i += _patchDecodeEscape(s, i, b, &bytes); continue }
                    if c == 0x22 { break }
                    bytes.append(c); i += 1
                }
                out.append(String(decoding: bytes, as: UTF8.self))
            }
            return out
        }

        // MARK: - Foundation-free `[String: Scalar]` DICTIONARY input marshalling
        //
        // A `[String: T]` `@State`/`let`/struct-field marshals in as a JSON OBJECT
        // (`{"a":1,"b":2}`). These scan it into a concrete `[String: T]` so the lowered
        // body reads the REAL dictionary (a `dict["k"]`, `dict.count`). Byte-level: cut
        // the object body, split it into top-level `key:value` entries, decode each.

        // The byte range [start, end) of the JSON OBJECT body for `key` (between the
        // opening `{` and matching `}`), or nil if absent/not an object.
        private func _patchDictBody(_ s: [UInt8], _ key: String) -> (Int, Int)? {
            guard let (a, b) = _patchObjectBody(s, key), b - a >= 2 else { return nil }
            return (a + 1, b - 1)   // strip the surrounding braces
        }

        // The key STRINGS of a JSON object body [lo, hi). Each entry is `"key":value` at
        // top level (commas/colons inside nested values don't split). Returns the decoded
        // key strings IN ORDER. (Kept for callers that only need the key set; value
        // reads should use `_patchObjectEntries` to avoid re-searching by key.)
        private func _patchObjectKeys(_ s: [UInt8], _ lo: Int, _ hi: Int) -> [String] {
            return _patchObjectEntries(s, lo, hi).map { $0.0 }
        }

        // The top-level entries of a JSON object body [lo, hi): for each, the DECODED
        // key string AND the value's raw byte range [vstart, vend) (whitespace-trimmed).
        // Position-based — the caller reads each value by RANGE, never re-searching by a
        // (possibly escaped, or nested-shadowed) key. This is the robust fix for the
        // escaped-key-drop and the nested-same-name-shadow hazards.
        private func _patchObjectEntries(_ s: [UInt8], _ lo: Int, _ hi: Int) -> [(String, Int, Int)] {
            var out: [(String, Int, Int)] = []
            var i = lo
            var depth = 0
            var inStr = false
            var expectKey = true       // at top level, the next string is a KEY
            var pendingKey: String? = nil
            var valueStart = -1
            while i < hi {
                let c = s[i]
                if inStr {
                    if c == 0x5C { i += 2; continue }
                    if c == 0x22 { inStr = false }
                    i += 1; continue
                }
                if c == 0x22 {
                    if depth == 0 && expectKey {
                        // Decode this key in place via the SHARED escape decoder.
                        var j = i + 1
                        var bytes: [UInt8] = []
                        while j < hi {
                            let d = s[j]
                            if d == 0x5C { j += _patchDecodeEscape(s, j, hi, &bytes); continue }
                            if d == 0x22 { break }
                            bytes.append(d); j += 1
                        }
                        pendingKey = String(decoding: bytes, as: UTF8.self)
                        i = j + 1
                        // Skip whitespace + the ':' to the value start.
                        while i < hi, s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0A || s[i] == 0x0D { i += 1 }
                        if i < hi, s[i] == 0x3A { i += 1 }
                        while i < hi, s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0A || s[i] == 0x0D { i += 1 }
                        valueStart = i
                        expectKey = false
                        continue
                    }
                    inStr = true; i += 1; continue
                }
                if c == 0x5B || c == 0x7B { depth += 1 }
                else if c == 0x5D || c == 0x7D { depth -= 1 }
                else if c == 0x2C && depth == 0 {
                    if let k = pendingKey, valueStart >= 0 {
                        let (a, b) = _patchTrimRange(s, valueStart, i)
                        out.append((k, a, b))
                    }
                    pendingKey = nil; valueStart = -1; expectKey = true
                }
                i += 1
            }
            // The final entry (no trailing comma).
            if let k = pendingKey, valueStart >= 0 {
                let (a, b) = _patchTrimRange(s, valueStart, hi)
                out.append((k, a, b))
            }
            return out
        }

        // Parse a scalar value from a raw byte RANGE [a, b) (a value the caller already
        // located by position). These mirror the by-key scanners but never re-search.
        private func _patchRangeString(_ s: [UInt8], _ a: Int, _ b: Int) -> String? {
            guard a < b, s[a] == 0x22 else { return nil }
            var i = a + 1
            var out: [UInt8] = []
            while i < b {
                let c = s[i]
                if c == 0x5C { i += _patchDecodeEscape(s, i, b, &out); continue }
                if c == 0x22 { break }
                out.append(c); i += 1
            }
            return String(decoding: out, as: UTF8.self)
        }
        private func _patchRangeToken(_ s: [UInt8], _ a: Int, _ b: Int) -> String? {
            guard a < b else { return nil }
            return String(decoding: s[a..<b], as: UTF8.self)
        }
        // Int from a value range — Int64 parse + 32-bit-`Int` clamp so a 64-bit-host
        // dictionary value (e.g. an epoch ms) is PRESERVED (clamped), not dropped, on
        // the wasm32 guest where `Int` is 32-bit.
        private func _patchRangeInt(_ s: [UInt8], _ a: Int, _ b: Int) -> Int? {
            guard let t = _patchRangeToken(s, a, b) else { return nil }
            if let v = Int(t) { return v }
            if let v64 = Int64(t) {
                let lo = Int64(Int.min), hi = Int64(Int.max)
                return Int(v64 < lo ? lo : (v64 > hi ? hi : v64))
            }
            return nil
        }
        private func _patchRangeDouble(_ s: [UInt8], _ a: Int, _ b: Int) -> Double? {
            _patchRangeToken(s, a, b).flatMap { Double($0) }
        }
        private func _patchRangeBool(_ s: [UInt8], _ a: Int, _ b: Int) -> Bool? {
            guard let t = _patchRangeToken(s, a, b) else { return nil }
            if t == "true" { return true }
            if t == "false" { return false }
            return nil
        }

        private func _patchScanStringDict(_ s: [UInt8], _ key: String) -> [String: String]? {
            guard let (lo, hi) = _patchDictBody(s, key) else { return nil }
            var out: [String: String] = [:]
            for (k, a, b) in _patchObjectEntries(s, lo, hi) {
                if let v = _patchRangeString(s, a, b) { out[k] = v }
            }
            return out
        }
        private func _patchScanIntDict(_ s: [UInt8], _ key: String) -> [String: Int]? {
            guard let (lo, hi) = _patchDictBody(s, key) else { return nil }
            var out: [String: Int] = [:]
            for (k, a, b) in _patchObjectEntries(s, lo, hi) {
                if let v = _patchRangeInt(s, a, b) { out[k] = v }
            }
            return out
        }
        private func _patchScanDoubleDict(_ s: [UInt8], _ key: String) -> [String: Double]? {
            guard let (lo, hi) = _patchDictBody(s, key) else { return nil }
            var out: [String: Double] = [:]
            for (k, a, b) in _patchObjectEntries(s, lo, hi) {
                if let v = _patchRangeDouble(s, a, b) { out[k] = v }
            }
            return out
        }
        private func _patchScanBoolDict(_ s: [UInt8], _ key: String) -> [String: Bool]? {
            guard let (lo, hi) = _patchDictBody(s, key) else { return nil }
            var out: [String: Bool] = [:]
            for (k, a, b) in _patchObjectEntries(s, lo, hi) {
                if let v = _patchRangeBool(s, a, b) { out[k] = v }
            }
            return out
        }

        // MARK: - Lowered view bodies

        """

        // If ANY view is interactive, prepend the shared dispatch-envelope scanners
        // (event-id bytes + typed event value) ONCE — these parse the `{state,event}`
        // the host sends to `dispatch`. Reused by every per-view `dispatch` export.
        let anyInteractive = views.contains { $0.stateModel?.isInteractive == true }
        if anyInteractive { wrapper += Self.dispatchScannerPreamble }

        // STRUCT-ARRAY support (TASK 1): for every distinct flat-struct element type
        // any view's `[SomeStruct]` input uses, emit ONCE a mirroring guest `struct`
        // (`_PatchRow_<Type>` with the flat fields) + an array-of-objects scanner that
        // parses `[{…},{…}]` into `[that struct]` (reusing the byte-level array
        // splitters above). A `ForEach(items)` row then iterates the bound struct array
        // and reads `item.<field>` against the guest struct.
        wrapper += Self.structRowSupport(for: views)

        // ENUM support (TASK 2): for every distinct raw-value enum type any view's
        // `.enumValue` input uses, emit ONCE a mirroring guest `enum` (raw-value typed)
        // + a case scanner that reads the SDK's `{"case":"<name>"}` marshalling by case
        // NAME. A body reading `s == .case` / `switch s` / `s.rawValue` resolves against it.
        wrapper += Self.enumSupport(for: views)

        var firstInteractiveEmitted = false
        // Collected per-view manifest entries (JSON objects) for `patch_view_manifest`.
        var manifestEntries: [String] = []
        for (i, v) in views.enumerated() {
            let sym = Self.exportSymbol(forView: v.viewName)
            // Indent the builder expression so the emitted Swift is readable.
            let body = v.guestBody.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "        " + $0 }.joined(separator: "\n")
            // Bind each input the body references from the JSON blob (falling back to
            // its declared default). This is the marshalling that makes a body reading
            // `name`/`flag` compile + run in WASM. When the body has a GeometryReader,
            // ALSO bind the reserved `__geo_*` inputs the SDK host wrapper injects.
            let binds = inputBindings(v.inputs, usesGeometry: v.usesGeometry,
                                      inputTokens: v.inputTokens)
            let buildSym = "_patchBuildTree__" + Self.sanitizedViewName(v.viewName)
            // PARAMETERIZED NATIVE SLOTS: bake this view's lifted string-literal
            // values into `BodyEmission.slotArgs` so the CURRENT literals ride WASM.
            // `nil` (no parameterized slot) leaves the field at its default — no bytes.
            let slotArgsAssign: String
            if let lit = Self.slotArgsLiteral(v.slotArgs) {
                slotArgsAssign = "\n                emission.slotArgs = \(lit)"
            } else {
                slotArgsAssign = ""
            }
            wrapper += """

            // Build the lowered `\(v.viewName)` tree from a flat state/inputs JSON blob.
            // Shared by `view_body` (initial render) and `dispatch` (re-render), so the
            // SAME body runs in WASM on both the first paint and every state update.
            private func \(buildSym)(_ _patchInputs: [UInt8]) -> ViewNode {
            \(binds)
                let root: ViewNode =
            \(body)
                return root
            }

            /// Lowered body of `\(v.viewName)` — built + serialized in WASM.
            @_cdecl("\(sym)")
            public func \(sym)(_ ptr: Int32, _ len: Int32) -> Int64 {
                let root = \(buildSym)(_patchReadBytes(ptr, len))
                var emission = BodyEmission(root: root, computeCoverage: true)\(slotArgsAssign)
                return _patchEmit(EmbeddedJSON.encode(emission))
            }

            """
            exports.append(sym)

            // The FIRST view also gets the canonical bare `view_body` export, so a
            // single-view app keeps the export name the SDK's `callJSON("view_body")`
            // drives. It just forwards to the per-view export.
            if i == 0 {
                wrapper += """

                @_cdecl("view_body")
                public func view_body(_ ptr: Int32, _ len: Int32) -> Int64 {
                    \(sym)(ptr, len)
                }

                """
                exports.append("view_body")
            }

            // INTERACTIVE: also emit the state struct + UPDATE function + `dispatch`
            // export so this view's state-mutation logic runs IN WASM (Breakthrough #5
            // productization). The `dispatch` applies the rule, then rebuilds the tree
            // via the SAME `\(buildSym)` the body uses (re-render of the new state).
            if let model = v.stateModel, model.isInteractive {
                let dsym = Self.dispatchExportSymbol(forView: v.viewName)
                wrapper += dispatchUnit(view: v.viewName, model: model, buildSym: buildSym)
                wrapper += """

                /// Interactive `dispatch(state,event) -> {newState,newTree}` for
                /// `\(v.viewName)` — the UPDATE logic runs IN WASM.
                @_cdecl("\(dsym)")
                public func \(dsym)(_ ptr: Int32, _ len: Int32) -> Int64 {
                    let _bytes = _patchReadBytes(ptr, len)
                    let _stateStr = _patchDispatchState(_bytes)
                    let _stateBytes = Array(_stateStr.utf8)
                    var _state = _PatchState_\(Self.sanitizedViewName(v.viewName)).fromJSON(_stateBytes)
                    let _idBytes = _patchDispatchEventID(_bytes) ?? []
                    let _value = _patchDispatchValue(_bytes)
                    _state = _patchUpdate_\(Self.sanitizedViewName(v.viewName))(_state, _idBytes, _value)
                    let _newJSON = _state.toJSON()
                    let _newTree = \(buildSym)(Array(_newJSON.utf8))
                    let _cov = BodyEmission(root: _newTree, computeCoverage: true).coverage
                    let _result = DispatchResult(state: _newJSON, tree: _newTree, coverage: _cov)
                    return _patchEmit(EmbeddedJSON.encodeDispatch(_result))
                }

                """
                exports.append(dsym)
                if !firstInteractiveEmitted {
                    wrapper += """

                    @_cdecl("dispatch")
                    public func dispatch(_ ptr: Int32, _ len: Int32) -> Int64 {
                        \(dsym)(ptr, len)
                    }

                    """
                    exports.append("dispatch")
                    firstInteractiveEmitted = true
                }
            }

            // Record this view's manifest entry. `type` is the sanitized view name
            // (the SAME literal the generated thunk passes to `thunkBody`); `dispatch`
            // points at the per-view dispatch export when interactive (always emitted
            // for interactive views), else null; `thunkSafe` says the body lowered
            // COMPLETELY so the SDK may auto-route it with no `PatchView`.
            let isInteractive = v.stateModel?.isInteractive == true
            let dispatchField = isInteractive
                ? "\"\(Self.dispatchExportSymbol(forView: v.viewName))\"" : "null"
            // NATIVE-FAST-PATH: the per-view body content hash. The SDK compares it
            // against the thunk's baked `baselineHash`; a match renders native (no WASM).
            // Computed by the SAME `BodyLowering.viewBodyContentHash` the thunk uses, so
            // for an unpatched view the two are EQUAL by construction. Omitted when nil
            // (legacy emission path) — the SDK then fail-safes to WASM.
            let bodyHashField = v.bodyHash.map { ",\"bodyHash\":\"\($0)\"" } ?? ""
            // STRUCTURALLY-STATIC CACHE: when true, the SDK caches the decoded tree after
            // the first WASM call and skips WASM on ALL subsequent renders (the tree is a
            // pure constant — identical regardless of input). Omitted when false (the
            // common case) to keep the manifest compact. Additive + backward-decode safe:
            // an older host that doesn't know this field treats it as always-WASM.
            let staticField = v.isStructurallyStatic ? ",\"isStructurallyStatic\":true" : ""
            manifestEntries.append(
                "{\"type\":\"\(Self.sanitizedViewName(v.viewName))\","
                + "\"export\":\"\(sym)\","
                + "\"dispatch\":\(dispatchField),"
                + "\"thunkSafe\":\(v.thunkSafe ? "true" : "false"),"
                + "\"minVersion\":\(v.minSchemaVersion)"
                + "\(bodyHashField)"
                + "\(staticField)}")
        }

        // Emit the VIEW MANIFEST export: a compile-time JSON literal describing every
        // lowered view (type → export/dispatch/thunkSafe). The SDK's view-patching
        // registry calls this ONCE per module activation to decide which view types it
        // can auto-route through the renderer. Foundation-free: it's a baked literal,
        // no runtime JSON building. Schema version matches PatchViewIRSchema.version.
        // Module stamp = the MAX per-view minVersion (so an OLDER SDK that only knows the
        // whole-module gate coarse-demotes a module containing a newer view; a NEWER SDK ignores
        // this and gates per-view via each entry's `minVersion`). Defaults to the feature-surface
        // constant when there are no views.
        let moduleSchemaVersion = views.map { $0.minSchemaVersion }.max() ?? Self.manifestSchemaVersion
        let manifestJSON = "{\"schemaVersion\":\(moduleSchemaVersion),\"views\":["
            + manifestEntries.joined(separator: ",") + "]}"
        wrapper += """

        // MARK: - View manifest (out-of-the-box auto-routing)

        @_cdecl("\(Self.manifestExport)")
        public func \(Self.manifestExport)(_ ptr: Int32, _ len: Int32) -> Int64 {
            _ = (ptr, len)
            let json = "\(Self.swiftStringLiteralBody(manifestJSON))"
            return _patchEmit(Array(json.utf8))
        }

        """
        exports.append(Self.manifestExport)

        files.append(File(fileName: "_PatchSwiftUI.swift", contents: wrapper))
        return Emission(files: files, exports: exports)
    }

    /// Emit the `let <name> = ...` bindings for a view's inputs, each decoded from
    /// the JSON blob with a fallback to its default literal. A scalar/string input is
    /// marshalled in; an `unsupported`-typed input is bound to its literal default so
    /// the body still compiles (it just isn't host-updatable). Indented two levels.
    private func inputBindings(_ inputs: [BodyLowering.ViewInput], usesGeometry: Bool = false,
                               inputTokens: [BodyLowering.HostToken] = []) -> String {
        // The reserved GeometryReader inputs (C): the SDK host wrapper injects the
        // live proxy's size/frame into the SAME flat JSON blob, so the lowered child's
        // `__geo_width`/etc. references resolve. Default 0 (the proxy is unknown until
        // the first layout). Bound first so they're in scope for the whole body.
        var lines: [String] = []
        if usesGeometry {
            lines.append("    let __geo_width = _patchScanDouble(_patchInputs, \"__geo_width\") ?? 0")
            lines.append("    let __geo_height = _patchScanDouble(_patchInputs, \"__geo_height\") ?? 0")
            lines.append("    let __geo_minX = _patchScanDouble(_patchInputs, \"__geo_minX\") ?? 0")
            lines.append("    let __geo_minY = _patchScanDouble(_patchInputs, \"__geo_minY\") ?? 0")
        }
        // HOST INPUT TOKENS: each binds from the input JSON under its reserved key (the
        // SDK merges the thunk-resolved value there). A NUMERIC token (`__numtok_<id>`)
        // binds as a Double (default 0); a STRING token (`__strtok_<id>`) binds as a
        // String (default ""). The SDK always supplies it — the default is
        // belt-and-suspenders, matching geo. Bound up front so the lowered body's
        // `Double(__numtok_<id>)` / `__strtok_<id>` references resolve.
        let inputTokenKeys = inputTokens.map { $0.inputKey }
        for tok in inputTokens {
            let key = tok.inputKey
            if tok.kind == .string {
                lines.append("    let \(key) = _patchScanString(_patchInputs, \"\(key)\") ?? \"\"")
            } else {
                lines.append("    let \(key) = _patchScanDouble(_patchInputs, \"\(key)\") ?? 0")
            }
        }
        guard !inputs.isEmpty else {
            // No stored-property inputs. Bind the blob away (unless geo / numeric-token
            // bindings above already consumed it) to avoid an unused-variable warning.
            if usesGeometry {
                // Reference the geo binds so they're not "unused" if the body somehow
                // doesn't read one, and discard the blob marker.
                lines.append("    _ = (__geo_width, __geo_height, __geo_minX, __geo_minY)")
            }
            if !inputTokenKeys.isEmpty {
                lines.append("    _ = (\(inputTokenKeys.joined(separator: ", ")))")
            }
            lines.append("    _ = _patchInputs")
            return lines.joined(separator: "\n")
        }
        for inp in inputs {
            switch inp.kind {
            case .string:
                lines.append("    let \(inp.name) = _patchScanString(_patchInputs, \"\(inp.name)\") ?? \(inp.defaultLiteral)")
            case .bool:
                lines.append("    let \(inp.name) = _patchScanBool(_patchInputs, \"\(inp.name)\") ?? \(inp.defaultLiteral)")
            case .int:
                lines.append("    let \(inp.name) = _patchScanInt(_patchInputs, \"\(inp.name)\") ?? \(inp.defaultLiteral)")
            case .double:
                lines.append("    let \(inp.name) = _patchScanDouble(_patchInputs, \"\(inp.name)\") ?? Double(\(inp.defaultLiteral))")
            case .intArray:
                lines.append("    let \(inp.name) = _patchScanIntArray(_patchInputs, \"\(inp.name)\") ?? \(inp.defaultLiteral)")
            case .doubleArray:
                lines.append("    let \(inp.name) = _patchScanDoubleArray(_patchInputs, \"\(inp.name)\") ?? \(inp.defaultLiteral)")
            case .boolArray:
                lines.append("    let \(inp.name) = _patchScanBoolArray(_patchInputs, \"\(inp.name)\") ?? \(inp.defaultLiteral)")
            case .stringArray:
                lines.append("    let \(inp.name) = _patchScanStringArray(_patchInputs, \"\(inp.name)\") ?? \(inp.defaultLiteral)")
            case .structArray:
                // `[SomeStruct]` (TASK 1): bind to the generated guest struct array via
                // the per-element-type array-of-objects scanner. The struct type +
                // scanner are emitted ONCE per element type by `structRowSupport`.
                if let el = inp.structElement {
                    let scanner = Self.structArrayScannerName(el.typeName)
                    lines.append("    let \(inp.name) = \(scanner)(_patchInputs, \"\(inp.name)\") ?? []")
                }
            case .flatStruct:
                // SINGLE flat struct (`let item: Product`, TASK 1): bind to the generated
                // mirroring guest struct via the per-type single-OBJECT scanner. The struct
                // type + scanner are emitted ONCE per type by `structRowSupport` (shared with
                // the struct-array path). A missing/blank object falls back to the struct's
                // zero-value default (faithful; the SDK marshals the real value in regardless).
                if let el = inp.structElement {
                    let scanner = Self.structRowScannerName(el.typeName)
                    let typeName = Self.structRowTypeName(el.typeName)
                    lines.append("    let \(inp.name) = \(scanner)(_patchInputs, \"\(inp.name)\") ?? \(typeName)()")
                }
            case .enumValue:
                // RAW-VALUE enum (`let s: Status`, TASK 2): bind to the generated mirroring
                // guest enum via the per-type case scanner reading the SDK's `{"case":"…"}`
                // marshalling. A missing/unknown case falls back to the FIRST declared case
                // (faithful default; the SDK marshals the real case in regardless).
                if let el = inp.enumElement {
                    let scanner = Self.enumScannerName(el.typeName)
                    let firstCase = el.caseNames.first ?? ""
                    lines.append("    let \(inp.name) = \(scanner)(_patchInputs, \"\(inp.name)\") ?? .\(Self.escapeIdentifier(firstCase))")
                }
            case .unsupported:
                // The guest can't reconstruct a struct/enum/dictionary — and a body
                // that READS such an input is EXCLUDED from guest emission entirely
                // (`LoweredView.referencesUnmarshalledInput` ⇒ BuildPipeline never
                // hands the view to this emitter), so a view that DOES reach here
                // never references the input in its lowered tree. We therefore emit
                // NO binding for it. Binding the declared default verbatim was unsafe:
                // a struct default is an UNQUALIFIED nested-type constructor
                // (`Profile(name:…)` — there is no `import` of the app module here, and
                // a nested type isn't visible unqualified), which is a hard compile
                // error that fails the SINGLE SwiftUI guest unit and ships NO views.
                // Since the binding is always dead code (the body can't reference it),
                // omitting it is strictly safe and removes the failure mode (DEFECT 3).
                break
            }
        }
        // Silence "never used" for inputs the body didn't actually reference (we bind
        // all stored properties; some may be unused after lowering).
        if usesGeometry {
            lines.append("    _ = (__geo_width, __geo_height, __geo_minX, __geo_minY)")
        }
        if !inputTokenKeys.isEmpty {
            lines.append("    _ = (\(inputTokenKeys.joined(separator: ", ")))")
        }
        lines.append("    _ = _patchInputs")
        return lines.joined(separator: "\n")
    }

    // MARK: - Interactive dispatch codegen (Breakthrough #5 productization)

    /// The shared `{state, event}` envelope scanners, emitted ONCE when any view is
    /// interactive. `_patchDispatchState` pulls the opaque guest-state JSON STRING;
    /// `_patchDispatchEventID` returns the event id RAW BYTES (matched by bytes in
    /// `update`, avoiding String-equivalence Unicode tables under Embedded Swift);
    /// `_patchDispatchValue` parses the typed event payload. (Mirrors the standalone
    /// interactive proof's `JSONScan.swift`.)
    static let dispatchScannerPreamble: String = """

        // MARK: - Dispatch envelope scanners (interactive views)

        /// A typed event payload value scanned from the dispatch envelope.
        enum _PatchValue: Equatable {
            case none, bool(Bool), int(Int), double(Double), string(String)
        }

        // The top-level `"state":"<escaped json>"` — the opaque guest state the host
        // round-trips. `_patchScanString` decodes the escapes back to the inner JSON.
        private func _patchDispatchState(_ s: [UInt8]) -> String {
            _patchScanString(s, "state") ?? ""
        }

        // The event id raw bytes from `…"event":{"event":{"id":"<X>"}…`. We anchor on
        // the FIRST `"event"` key, then the first `"id":"…"` after it, so an `"id"`
        // inside the opaque state string can't be mistaken for it.
        private func _patchDispatchEventID(_ s: [UInt8]) -> [UInt8]? {
            let from = _patchFind(s, Array("\\"event\\"".utf8)) ?? 0
            let idKey = Array("\\"id\\"".utf8)
            guard let k = _patchFind2(s, idKey, from: from) else { return nil }
            var i = k + idKey.count
            while i < s.count, s[i] == 0x3A || s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0A || s[i] == 0x0D { i += 1 }
            return _patchReadStringBytes(s, i)?.0
        }

        // The typed event value from `…"value":{ "<case>":{ "_0":<v> } }…`.
        private func _patchDispatchValue(_ s: [UInt8]) -> _PatchValue {
            guard let vKey = _patchFind(s, Array("\\"value\\"".utf8)) else { return .none }
            var i = vKey + 7
            while i < s.count, s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0A || s[i] == 0x0D { i += 1 }
            guard i < s.count, s[i] == 0x3A else { return .none }
            i += 1
            while i < s.count, s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0A || s[i] == 0x0D { i += 1 }
            guard i < s.count, s[i] == 0x7B else { return .none }
            i += 1
            while i < s.count, s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0A || s[i] == 0x0D { i += 1 }
            guard let (caseBytes, after) = _patchReadStringBytes(s, i) else { return .none }
            var j = after
            func payloadStart() -> Int? {
                guard let p = _patchFind2(s, Array("\\"_0\\"".utf8), from: j) else { return nil }
                var k = p + 4
                while k < s.count, k >= 0, s[k] == 0x3A || s[k] == 0x20 || s[k] == 0x09 || s[k] == 0x0A || s[k] == 0x0D { k += 1 }
                return k
            }
            if _patchBytesEq(caseBytes, "none") { return .none }
            if _patchBytesEq(caseBytes, "bool") {
                if let k = payloadStart() {
                    if _patchFind2(s, Array("true".utf8), from: k) == k { return .bool(true) }
                    if _patchFind2(s, Array("false".utf8), from: k) == k { return .bool(false) }
                }
                return .none
            }
            if _patchBytesEq(caseBytes, "int") {
                if var k = payloadStart(), let n = _patchReadInt(s, &k) { return .int(n) }
                return .none
            }
            if _patchBytesEq(caseBytes, "double") {
                if let k = payloadStart(), let d = _patchReadDouble(s, k) { return .double(d) }
                return .none
            }
            if _patchBytesEq(caseBytes, "string") {
                if let k = payloadStart(), let (str, _) = _patchReadString(s, k) { return .string(str) }
                return .none
            }
            return .none
        }

        // --- byte-level scan primitives (Foundation-free; Embedded-clean) ---

        private func _patchFind2(_ haystack: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
            if needle.isEmpty || haystack.count < needle.count { return nil }
            let last = haystack.count - needle.count
            var i = from < 0 ? 0 : from
            while i <= last {
                var k = 0
                while k < needle.count, haystack[i + k] == needle[k] { k += 1 }
                if k == needle.count { return i }
                i += 1
            }
            return nil
        }

        private func _patchReadStringBytes(_ s: [UInt8], _ start: Int) -> ([UInt8], Int)? {
            guard start < s.count, s[start] == 0x22 else { return nil }
            var i = start + 1
            var out: [UInt8] = []
            while i < s.count {
                let c = s[i]
                // Use the SHARED escape decoder so a dispatch string value decodes the
                // SAME escape set as the input scanner (incl. `\\uXXXX` / surrogate
                // pairs / `\\b` / `\\f`) — the SDK encoder emits those for control chars.
                if c == 0x5C { i += _patchDecodeEscape(s, i, s.count, &out); continue }
                if c == 0x22 { return (out, i + 1) }
                out.append(c); i += 1
            }
            return nil
        }
        private func _patchReadString(_ s: [UInt8], _ start: Int) -> (String, Int)? {
            guard let (b, e) = _patchReadStringBytes(s, start) else { return nil }
            return (String(decoding: b, as: UTF8.self), e)
        }
        private func _patchReadInt(_ s: [UInt8], _ i: inout Int) -> Int? {
            var neg = false
            if i < s.count, s[i] == 0x2D { neg = true; i += 1 }
            // Accumulate in Int64 with overflow checks so a 64-bit-host payload
            // (e.g. a millisecond timestamp / large id) does NOT trap the wasm32
            // guest, where `Int` is 32-bit. On overflow return nil (the caller's
            // `if case .int` simply doesn't fire → prior state preserved), and on a
            // value outside the 32-bit `Int` range clamp to that range rather than
            // trap on the final `Int(v)` conversion.
            var have = false
            var v: Int64 = 0
            while i < s.count, s[i] >= 0x30, s[i] <= 0x39 {
                let d = Int64(s[i] - 0x30)
                let (m, mo) = v.multipliedReportingOverflow(by: 10)
                if mo { return nil }
                let (a, ao) = m.addingReportingOverflow(d)
                if ao { return nil }
                v = a; i += 1; have = true
            }
            guard have else { return nil }
            let signed = neg ? -v : v
            let lo = Int64(Int.min), hi = Int64(Int.max)
            let clamped = signed < lo ? lo : (signed > hi ? hi : signed)
            return Int(clamped)
        }
        private func _patchReadDouble(_ s: [UInt8], _ start: Int) -> Double? {
            var i = start
            var neg = false
            if i < s.count, s[i] == 0x2D { neg = true; i += 1 }
            else if i < s.count, s[i] == 0x2B { i += 1 }   // accept a leading '+'
            var intPart = 0.0, haveDigits = false
            while i < s.count, s[i] >= 0x30, s[i] <= 0x39 { intPart = intPart * 10 + Double(s[i] - 0x30); i += 1; haveDigits = true }
            var frac = 0.0, scale = 1.0
            if i < s.count, s[i] == 0x2E {
                i += 1
                while i < s.count, s[i] >= 0x30, s[i] <= 0x39 { scale *= 10; frac += Double(s[i] - 0x30) / scale; i += 1; haveDigits = true }
            }
            guard haveDigits else { return nil }
            var v = intPart + frac
            // SCIENTIFIC NOTATION: the host's JSONEncoder/`String(Double)` formats small
            // or very large magnitudes as `1e-07` / `1e+18`. Consume an optional
            // `e`/`E` + sign + exponent digits and apply the power-of-ten scale; without
            // this the parse stopped at 'e' and the dispatched value was corrupted.
            if i < s.count, s[i] == 0x65 || s[i] == 0x45 {
                i += 1
                var expNeg = false
                if i < s.count, s[i] == 0x2D { expNeg = true; i += 1 }
                else if i < s.count, s[i] == 0x2B { i += 1 }
                var exp = 0, haveExp = false
                while i < s.count, s[i] >= 0x30, s[i] <= 0x39 { exp = exp * 10 + Int(s[i] - 0x30); i += 1; haveExp = true }
                if haveExp {
                    var p = 1.0
                    var e = exp
                    while e > 0 { p *= 10; e -= 1 }
                    v = expNeg ? v / p : v * p
                }
            }
            return neg ? -v : v
        }
        private func _patchBytesEq(_ a: [UInt8], _ s: String) -> Bool {
            let b = Array(s.utf8)
            if a.count != b.count { return false }
            var i = 0
            while i < a.count { if a[i] != b[i] { return false }; i += 1 }
            return true
        }

        // Foundation-free helpers shared by every emitted state struct.
        private func _patchIntToString(_ n: Int) -> String {
            if n == 0 { return "0" }
            var v = n
            let neg = v < 0
            if neg { v = -v }
            var digits: [UInt8] = []
            while v > 0 { digits.append(UInt8(0x30 + (v % 10))); v /= 10 }
            if neg { digits.append(0x2D) }
            return String(decoding: digits.reversed(), as: UTF8.self)
        }
        private func _patchInt64ToString(_ n: Int64) -> String {
            if n == 0 { return "0" }
            var v = n
            let neg = v < 0
            var digits: [UInt8] = []
            // Build from the low digit using a sign-preserving step so Int64.min
            // (which has no positive magnitude) doesn't trap on negation.
            while v != 0 {
                let r = v % 10            // -9...9
                let d = r < 0 ? -r : r    // 0...9 (safe: |r| <= 9, never Int64.min)
                digits.append(UInt8(0x30 + Int(d))); v /= 10
            }
            if neg { digits.append(0x2D) }
            return String(decoding: digits.reversed(), as: UTF8.self)
        }
        private func _patchDoubleToString(_ d: Double) -> String {
            // A whole-valued Double in 64-bit Int64 range formats as an integer (no
            // ".0" / exponent). `Int(d)` would TRAP on wasm32 for |d| > Int32.max, so
            // route the fast path through Int64 (matching the SDK's String(Int64(d))).
            if d == d.rounded() && abs(d) < 9.007199254740992e15 {
                return _patchInt64ToString(Int64(d))
            }
            return String(d)
        }
        // Byte-safe JSON string escape (UTF-8 bytes only — no grapheme tables).
        private func _patchEscape(_ s: String) -> String {
            var out: [UInt8] = []
            for b in s.utf8 {
                switch b {
                case 0x22: out.append(0x5C); out.append(0x22)
                case 0x5C: out.append(0x5C); out.append(0x5C)
                case 0x0A: out.append(0x5C); out.append(0x6E)
                case 0x0D: out.append(0x5C); out.append(0x72)
                case 0x09: out.append(0x5C); out.append(0x74)
                case 0x00..<0x20:
                    // Other C0 control bytes escape to a six-char unicode form (u + 00 + hex).
                    // A raw control byte makes the SDK strict JSONSerialization reject the
                    // dispatch state, silently dropping EVERY write-back (typed/pasted text lost).
                    let hex: [UInt8] = Array("0123456789abcdef".utf8)
                    out.append(0x5C); out.append(0x75); out.append(0x30); out.append(0x30)
                    out.append(hex[Int(b >> 4)]); out.append(hex[Int(b & 0x0F)])
                default: out.append(b)
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
        // Truncate to ≤ maxBytes UTF-8 bytes without splitting a multi-byte sequence.
        private func _patchTruncUTF8(_ s: String, _ maxBytes: Int) -> String {
            let bytes = Array(s.utf8)
            if bytes.count <= maxBytes { return s }
            var end = maxBytes
            while end > 0, (bytes[end] & 0xC0) == 0x80 { end -= 1 }
            return String(decoding: bytes[0..<end], as: UTF8.self)
        }
        private func _patchClampI(_ v: Int, _ lo: Int, _ hi: Int) -> Int { v < lo ? lo : (v > hi ? hi : v) }
        private func _patchClampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? lo : (v > hi ? hi : v) }

        """

    /// Emit the per-view state struct + UPDATE function (the interaction LOGIC that
    /// runs in WASM). The struct's fields are the view's participating scalar `@State`
    /// properties; `fromJSON`/`toJSON` round-trip the SAME flat object the body binds
    /// its inputs from (so `dispatch` rebuilds the tree from the new state). `update`
    /// matches the event id BY BYTES and applies the lowered mutation rule.
    func dispatchUnit(view: String, model: BodyLowering.StateModel, buildSym: String) -> String {
        let n = Self.sanitizedViewName(view)
        var s = "\n        // MARK: - Interactive state + UPDATE for `\(view)` (runs in WASM)\n\n"

        // State struct + (de)serialization.
        s += "        struct _PatchState_\(n) {\n"
        for f in model.fields {
            s += "            var \(f.name): \(Self.swiftType(f.kind)) = \(Self.defaultFor(f))\n"
        }
        s += "\n            func toJSON() -> String {\n"
        s += "                var out = \"{\"\n"
        for (idx, f) in model.fields.enumerated() {
            let comma = idx == 0 ? "" : ","
            switch f.kind {
            case .bool:
                s += "                out = out + \"\(comma)\\\"\(f.name)\\\":\" + (\(f.name) ? \"true\" : \"false\")\n"
            case .int:
                s += "                out = out + \"\(comma)\\\"\(f.name)\\\":\" + _patchIntToString(\(f.name))\n"
            case .double:
                s += "                out = out + \"\(comma)\\\"\(f.name)\\\":\" + _patchDoubleToString(\(f.name))\n"
            case .string, .unsupported,
                 .stringArray, .boolArray, .intArray, .doubleArray, .structArray, .flatStruct, .enumValue:
                s += "                out = out + \"\(comma)\\\"\(f.name)\\\":\\\"\" + _patchEscape(\(f.name)) + \"\\\"\"\n"
            }
        }
        s += "                return out + \"}\"\n"
        s += "            }\n\n"
        s += "            static func fromJSON(_ b: [UInt8]) -> _PatchState_\(n) {\n"
        s += "                var st = _PatchState_\(n)()\n"
        s += "                if b.isEmpty { return st }\n"
        for f in model.fields {
            switch f.kind {
            case .bool:
                s += "                if let v = _patchScanBool(b, \"\(f.name)\") { st.\(f.name) = v }\n"
            case .int:
                s += "                if let v = _patchScanInt(b, \"\(f.name)\") { st.\(f.name) = v }\n"
            case .double:
                s += "                if let v = _patchScanDouble(b, \"\(f.name)\") { st.\(f.name) = v }\n"
            case .string, .unsupported,
                 .stringArray, .boolArray, .intArray, .doubleArray, .structArray, .flatStruct, .enumValue:
                s += "                if let v = _patchScanString(b, \"\(f.name)\") { st.\(f.name) = v }\n"
            }
        }
        s += "                return st\n"
        s += "            }\n"
        s += "        }\n\n"

        // UPDATE function — matches the event id by bytes, applies the rule. This is
        // the interaction LOGIC, run IN WASM.
        s += "        func _patchUpdate_\(n)(_ state: _PatchState_\(n), _ id: [UInt8], _ value: _PatchValue) -> _PatchState_\(n) {\n"
        s += "            var s = state\n"
        for rule in model.rules {
            s += "            if _patchBytesEq(id, \"\(rule.eventID)\") {\n"
            s += Self.emitRuleBody(rule, indent: "                ")
            s += "                return s\n"
            s += "            }\n"
        }
        s += "            return s\n"
        s += "        }\n"
        return s
    }

    /// The body of one UPDATE rule (applies the mutation to `s.<field>`).
    static func emitRuleBody(_ rule: BodyLowering.MutationRule, indent ind: String) -> String {
        let f = "s.\(rule.field)"
        switch rule.op {
        case .setBool:
            // A payload sets the bool; a bare tap (no value) flips it.
            return ind + "if case .bool(let b) = value { \(f) = b } else { \(f) = !\(f) }\n"
        case .toggleBool:
            return ind + "\(f) = !\(f)\n"
        case .setIntClamped(let lo, let hi):
            if let lo, let hi {
                return ind + "if case .int(let n) = value { \(f) = _patchClampI(n, \(lo), \(hi)) }\n"
            }
            return ind + "if case .int(let n) = value { \(f) = n }\n"
        case .setDoubleClamped(let lo, let hi):
            return ind + "if case .double(let d) = value { \(f) = _patchClampD(d, \(Self.dbl(lo)), \(Self.dbl(hi))) }\n"
        case .setString:
            // Byte-safe cap as a runaway-allocation guardrail only — NOT a product
            // limit. The 1024-byte cap silently clipped realistic field input (a long
            // note / pasted paragraph / URL list); raise it well beyond any single
            // TextField's realistic content so typed/pasted text round-trips intact.
            return ind + "if case .string(let str) = value { \(f) = _patchTruncUTF8(str, 1_048_576) }\n"
        case .incInt(let step, let lo, let hi, let wrap):
            if wrap, let lo, let hi {
                return ind + "\(f) = \(f) >= \(hi) ? \(lo) : \(f) + \(step)\n"
            }
            if let hi {
                return ind + "\(f) = _patchClampI(\(f) + \(step), \(lo ?? 0), \(hi))\n"
            }
            return ind + "\(f) = \(f) + \(step)\n"
        case .decInt(let step, let lo, _):
            if let lo {
                return ind + "\(f) = \(f) - \(step) < \(lo) ? \(lo) : \(f) - \(step)\n"
            }
            return ind + "\(f) = \(f) - \(step)\n"
        case .assignIntLiteral(let v):
            return ind + "\(f) = \(v)\n"
        case .assignBoolLiteral(let v):
            return ind + "\(f) = \(v)\n"
        }
    }

    // The state-struct Swift type for an interactive field. Only SCALAR fields ever
    // reach here (mutation rules target scalars; `buildStateModel` filters the rest),
    // so the array/unsupported kinds map to String defensively — they're unreachable.
    static func swiftType(_ k: BodyLowering.ViewInput.Kind) -> String {
        switch k {
        case .bool: return "Bool"
        case .int: return "Int"
        case .double: return "Double"
        case .string, .unsupported,
             .stringArray, .boolArray, .intArray, .doubleArray, .structArray, .flatStruct, .enumValue: return "String"
        }
    }

    static func defaultFor(_ f: BodyLowering.ViewInput) -> String {
        switch f.kind {
        case .double: return "Double(\(f.defaultLiteral))"
        default: return f.defaultLiteral
        }
    }

    static func dbl(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) + ".0" : String(d)
    }

    // MARK: - Struct-array row support (TASK 1)

    /// The guest struct type name mirroring a flat-struct array element. Sanitized +
    /// prefixed so it can't collide with the lowered tree's own identifiers.
    static func structRowTypeName(_ elementType: String) -> String {
        "_PatchRow_" + sanitizedViewName(elementType)
    }
    /// The per-element-type array-of-objects scanner name.
    static func structArrayScannerName(_ elementType: String) -> String {
        "_patchScan" + sanitizedViewName(elementType) + "RowArray"
    }
    /// The per-type SINGLE-OBJECT scanner name (TASK 1 — one flat-struct input).
    static func structRowScannerName(_ elementType: String) -> String {
        "_patchScan" + sanitizedViewName(elementType) + "Row"
    }

    /// Emit (once per distinct flat-struct element type used across `views`) a guest
    /// `struct _PatchRow_<Type>` with the element's flat scalar fields, plus a scanner
    /// `_patchScan<Type>RowArray(_ s, _ key) -> [_PatchRow_<Type>]?` that parses a JSON
    /// array-of-objects into `[that struct]`. The scanner reuses the byte-level
    /// `_patchArrayBody`/`_patchArrayElements` splitters (above in the wrapper) to cut
    /// the array into element byte-ranges, then runs the existing scalar scanners
    /// (`_patchScanString`/`Int`/`Double`/`Bool`) over EACH element's bytes by field
    /// name — so a missing field falls back to the struct's default (faithful, never
    /// a crash). Empty array → `[]`; a non-array value → nil (binding falls back to []).
    /// The per-type RAW-BYTES object builder (`_patchBuild<Type>` — takes an object's
    /// own bytes, returns a filled `_PatchRow_<Type>`). The recursion primitive: a
    /// nested-struct field calls the nested type's builder, a struct-array field its
    /// array-builder, so an arbitrarily deep value tree reconstructs.
    static func structRowBuilderName(_ elementType: String) -> String {
        "_patchBuild" + sanitizedViewName(elementType) + "Row"
    }

    static func structRowSupport(for views: [GuestView]) -> String {
        // Collect every struct element type REACHABLE from any `.structArray`/`.flatStruct`
        // input — RECURSIVELY, so a nested-struct / struct-array field's type also gets a
        // guest struct + builder. `needsArrayScanner`/`needsRowScanner` track which TOP-
        // LEVEL input kinds reference each type (a nested type may need neither directly,
        // but always needs its builder for the recursion). A raw-enum FIELD's enum type is
        // emitted by `enumSupport`; here we just reference its guest enum name.
        var byTypeName: [String: BodyLowering.ViewInput.StructElement] = [:]
        var needsArrayScanner = Set<String>()
        var needsRowScanner = Set<String>()
        var order: [String] = []

        // Recursively register a struct element + every nested struct it reaches.
        func register(_ el: BodyLowering.ViewInput.StructElement) {
            let key = sanitizedViewName(el.typeName)
            if byTypeName[key] == nil { byTypeName[key] = el; order.append(key) }
            for f in el.fields {
                switch f.shape {
                case .structValue(let nested), .structArray(let nested), .structDictionary(let nested):
                    register(nested)
                case .scalar, .enumValue, .scalarArray, .scalarDictionary, .optionalScalar:
                    break
                }
            }
        }
        for v in views {
            for inp in v.inputs {
                let isArray = inp.kind == .structArray
                let isRow = inp.kind == .flatStruct
                guard isArray || isRow, let el = inp.structElement else { continue }
                register(el)
                let key = sanitizedViewName(el.typeName)
                if isArray { needsArrayScanner.insert(key) }
                if isRow { needsRowScanner.insert(key) }
            }
        }
        guard !order.isEmpty else { return "" }

        var s = "\n        // MARK: - Struct decoding (nested structs, struct arrays, scalar arrays/dicts)\n"
        for key in order {
            guard let el = byTypeName[key] else { continue }
            let typeName = structRowTypeName(el.typeName)
            // The mirroring guest struct: each field typed by its recursive shape.
            s += "\n        struct \(typeName) {\n"
            for f in el.fields {
                s += "            var \(f.name): \(guestFieldType(f.shape)) = \(guestFieldDefault(f.shape))\n"
            }
            s += "        }\n"

            // The RAW-BYTES builder: fill every field from the object's own bytes.
            // Scalar → the scalar scanner; nested struct → its builder over the cut object
            // bytes; struct array → its array-builder; scalar array → the array scanner;
            // scalar dict → the dict scanner; raw enum → the enum scanner.
            let builder = structRowBuilderName(el.typeName)
            s += """

                    private func \(builder)(_ obj: [UInt8]) -> \(typeName) {
                        var row = \(typeName)()

                """
            s += guestFieldScans(el.fields, indent: "            ", objVar: "obj", rowVar: "row")
            s += """
                        return row
                    }

                """

            // The array-of-objects scanner (a TOP-LEVEL `[SomeStruct]` input): split the
            // array body into element ranges, then build each element via the builder.
            if needsArrayScanner.contains(key) {
                let scanner = structArrayScannerName(el.typeName)
                s += """

                        private func \(scanner)(_ s: [UInt8], _ key: String) -> [\(typeName)]? {
                            guard let (lo, hi) = _patchArrayBody(s, key) else { return nil }
                            var out: [\(typeName)] = []
                            for (es, ee) in _patchArrayElements(s, lo, hi) {
                                let (a, b) = _patchTrimRange(s, es, ee)
                                guard a < b else { continue }
                                out.append(\(builder)(Array(s[a..<b])))
                            }
                            return out
                        }

                    """
            }
            // The single-OBJECT scanner (a TOP-LEVEL `let item: SomeStruct` input): cut
            // the object's bytes for `key` and build it. Missing/non-object → nil.
            if needsRowScanner.contains(key) {
                let scanner = structRowScannerName(el.typeName)
                s += """

                        private func \(scanner)(_ s: [UInt8], _ key: String) -> \(typeName)? {
                            guard let (lo, hi) = _patchObjectBody(s, key) else { return nil }
                            return \(builder)(Array(s[lo..<hi]))
                        }

                    """
            }
        }
        return s
    }

    /// The guest Swift type text for a recursive field shape.
    private static func guestFieldType(_ shape: BodyLowering.FieldShape) -> String {
        switch shape {
        case .scalar(let k): return scalarSwiftType(k)
        case .structValue(let el): return structRowTypeName(el.typeName)
        case .enumValue(let el): return enumTypeName(el.typeName)
        case .scalarArray(let k): return "[\(scalarSwiftType(k))]"
        case .structArray(let el): return "[\(structRowTypeName(el.typeName))]"
        case .scalarDictionary(let k): return "[String: \(scalarSwiftType(k))]"
        case .structDictionary(let el): return "[String: \(structRowTypeName(el.typeName))]"
        case .optionalScalar(let k): return "\(scalarSwiftType(k))?"
        }
    }

    /// The default value for a recursive field shape (used when the JSON object lacks
    /// the key — faithful zero, never a crash). A nested struct defaults to its own
    /// zero struct; a raw enum to its FIRST case; collections to empty.
    private static func guestFieldDefault(_ shape: BodyLowering.FieldShape) -> String {
        switch shape {
        case .scalar(let k): return scalarDefault(k)
        case .structValue(let el): return "\(structRowTypeName(el.typeName))()"
        case .enumValue(let el):
            let first = el.caseNames.first ?? ""
            return ".\(escapeIdentifier(first))"
        case .scalarArray, .structArray: return "[]"
        case .scalarDictionary, .structDictionary: return "[:]"
        case .optionalScalar: return "nil"
        }
    }

    /// The per-OBJECT field-scan body: fill each field from `objVar`'s bytes into `rowVar`.
    /// Scalar fields use the scalar scanners; nested struct/array/dict/enum fields cut the
    /// nested bytes and recurse via the per-type builder / array / dict / enum scanner.
    private static func guestFieldScans(_ fields: [BodyLowering.StructField],
                                        indent: String, objVar: String, rowVar: String) -> String {
        var out = ""
        for f in fields {
            switch f.shape {
            case .scalar(let k):
                switch k {
                case .string:
                    out += "\(indent)if let v = _patchScanString(\(objVar), \"\(f.name)\") { \(rowVar).\(f.name) = v }\n"
                case .bool:
                    out += "\(indent)if let v = _patchScanBool(\(objVar), \"\(f.name)\") { \(rowVar).\(f.name) = v }\n"
                case .int:
                    out += "\(indent)if let v = _patchScanInt(\(objVar), \"\(f.name)\") { \(rowVar).\(f.name) = v }\n"
                case .double:
                    out += "\(indent)if let v = _patchScanDouble(\(objVar), \"\(f.name)\") { \(rowVar).\(f.name) = v }\n"
                default: break
                }
            case .structValue(let el):
                // Cut the nested object's bytes and build it recursively.
                let nb = structRowBuilderName(el.typeName)
                out += "\(indent)if let (nlo, nhi) = _patchObjectBody(\(objVar), \"\(f.name)\") { \(rowVar).\(f.name) = \(nb)(Array(\(objVar)[nlo..<nhi])) }\n"
            case .structArray(let el):
                // Cut the nested array body, split into element objects, build each.
                let nb = structRowBuilderName(el.typeName)
                out += "\(indent)if let (alo, ahi) = _patchArrayBody(\(objVar), \"\(f.name)\") {\n"
                out += "\(indent)    var __arr: [\(structRowTypeName(el.typeName))] = []\n"
                out += "\(indent)    for (es, ee) in _patchArrayElements(\(objVar), alo, ahi) {\n"
                out += "\(indent)        let (a, b) = _patchTrimRange(\(objVar), es, ee)\n"
                out += "\(indent)        if a < b { __arr.append(\(nb)(Array(\(objVar)[a..<b]))) }\n"
                out += "\(indent)    }\n"
                out += "\(indent)    \(rowVar).\(f.name) = __arr\n"
                out += "\(indent)}\n"
            case .enumValue(let el):
                let es = enumScannerName(el.typeName)
                out += "\(indent)if let v = \(es)(\(objVar), \"\(f.name)\") { \(rowVar).\(f.name) = v }\n"
            case .scalarArray(let k):
                let scanner: String
                switch k {
                case .string: scanner = "_patchScanStringArray"
                case .bool: scanner = "_patchScanBoolArray"
                case .int: scanner = "_patchScanIntArray"
                case .double: scanner = "_patchScanDoubleArray"
                default: scanner = "_patchScanStringArray"
                }
                out += "\(indent)if let v = \(scanner)(\(objVar), \"\(f.name)\") { \(rowVar).\(f.name) = v }\n"
            case .scalarDictionary(let k):
                let ds = scalarDictScannerName(k)
                out += "\(indent)if let v = \(ds)(\(objVar), \"\(f.name)\") { \(rowVar).\(f.name) = v }\n"
            case .optionalScalar(let k):
                // Optional scalar: the scalar scanner returns nil for a missing key OR a
                // `null`/wrong-typed value, so a successful scan sets `.some(v)` and any
                // other case leaves the field at its `nil` default — exactly the optional
                // semantics, no separate null handling needed.
                let scanner: String
                switch k {
                case .string: scanner = "_patchScanString"
                case .bool: scanner = "_patchScanBool"
                case .int: scanner = "_patchScanInt"
                case .double: scanner = "_patchScanDouble"
                default: scanner = "_patchScanString"
                }
                out += "\(indent)if let v = \(scanner)(\(objVar), \"\(f.name)\") { \(rowVar).\(f.name) = v }\n"
            case .structDictionary(let el):
                // Cut the dict object's body, then for each top-level ENTRY build the
                // value struct from its value byte RANGE (position-based, never a
                // re-search by key — so an escaped key or a nested same-name field can't
                // drop the entry or cut the wrong object).
                let nb = structRowBuilderName(el.typeName)
                let rt = structRowTypeName(el.typeName)
                out += "\(indent)if let (dlo, dhi) = _patchDictBody(\(objVar), \"\(f.name)\") {\n"
                out += "\(indent)    var __dict: [String: \(rt)] = [:]\n"
                out += "\(indent)    for (__k, __vlo, __vhi) in _patchObjectEntries(\(objVar), dlo, dhi) {\n"
                out += "\(indent)        if __vlo < __vhi, \(objVar)[__vlo] == 0x7B { __dict[__k] = \(nb)(Array(\(objVar)[__vlo..<__vhi])) }\n"
                out += "\(indent)    }\n"
                out += "\(indent)    \(rowVar).\(f.name) = __dict\n"
                out += "\(indent)}\n"
            }
        }
        return out
    }

    /// The `[String: Scalar]` dictionary scanner name (one per value scalar kind).
    static func scalarDictScannerName(_ valueKind: BodyLowering.ViewInput.Kind) -> String {
        switch valueKind {
        case .string: return "_patchScanStringDict"
        case .bool: return "_patchScanBoolDict"
        case .int: return "_patchScanIntDict"
        case .double: return "_patchScanDoubleDict"
        default: return "_patchScanStringDict"
        }
    }

    // MARK: - Raw-value enum support (TASK 2)

    /// The guest enum type name mirroring a raw-value enum input.
    static func enumTypeName(_ enumType: String) -> String {
        "_PatchEnum_" + sanitizedViewName(enumType)
    }
    /// The per-type enum case scanner name.
    static func enumScannerName(_ enumType: String) -> String {
        "_patchScan" + sanitizedViewName(enumType) + "Enum"
    }

    /// Emit (once per distinct raw-value enum type used across `views`) a guest
    /// `enum _PatchEnum_<Type>: <Raw> { case … }` mirroring the source enum's cases +
    /// raw values, plus a scanner `_patchScan<Type>Enum(_ s, _ key) -> _PatchEnum_<Type>?`
    /// that reads the SDK's `{"case":"<name>"}` marshalling by case NAME. A `let s: Status`
    /// input then binds `let s = _patchScan…Enum(blob,"s") ?? .<firstCase>`, so a body
    /// reading `s == .case` / `switch s` / `s.rawValue` resolves against the guest enum.
    static func enumSupport(for views: [GuestView]) -> String {
        var byTypeName: [String: BodyLowering.ViewInput.EnumElement] = [:]
        var order: [String] = []
        func add(_ el: BodyLowering.ViewInput.EnumElement) {
            let key = sanitizedViewName(el.typeName)
            if byTypeName[key] == nil { byTypeName[key] = el; order.append(key) }
        }
        // Recursively collect every enum type reachable from a struct's FIELDS. A
        // struct/struct-array/struct-dictionary input whose element has an `.enumValue`
        // field needs that enum's mirroring guest type + scanner emitted HERE — the
        // struct builder (`guestFieldScans`) references `_PatchEnum_<T>` / its scanner
        // unconditionally, so without this the guest module fails to compile and EVERY
        // view demotes (the bug fires even when the body never reads the enum field).
        func walkStruct(_ el: BodyLowering.ViewInput.StructElement) {
            for f in el.fields {
                switch f.shape {
                case .enumValue(let e): add(e)
                case .structValue(let n), .structArray(let n), .structDictionary(let n):
                    walkStruct(n)
                case .scalar, .scalarArray, .scalarDictionary, .optionalScalar:
                    break
                }
            }
        }
        for v in views {
            for inp in v.inputs {
                if inp.kind == .enumValue, let el = inp.enumElement { add(el) }
                if inp.kind == .structArray || inp.kind == .flatStruct,
                   let el = inp.structElement { walkStruct(el) }
            }
        }
        guard !order.isEmpty else { return "" }

        var s = "\n        // MARK: - Raw-value enum decoding (single `SomeEnum` inputs)\n"
        for key in order {
            guard let el = byTypeName[key] else { continue }
            let typeName = enumTypeName(el.typeName)
            let scanner = enumScannerName(el.typeName)
            let rawType = el.rawKind == .string ? "String" : "Int"
            // The mirroring guest enum (raw-value typed). Each case carries its EXPLICIT
            // raw value when the source declared one (`case active = "ACTIVE"`), so a body
            // reading `s.rawValue` gets the faithful value; an implicit case uses Swift's
            // implicit raw (case name for String, running index for Int) — matching source.
            s += "\n        enum \(typeName): \(rawType) {\n"
            for c in el.cases {
                // Backtick-escape a reserved-word case name (`case \`default\``) so the
                // emitted guest enum is valid Swift.
                let id = escapeIdentifier(c.name)
                if let raw = c.rawLiteral {
                    s += "            case \(id) = \(raw)\n"
                } else {
                    s += "            case \(id)\n"
                }
            }
            s += "        }\n"
            // The case scanner: read the `"case":"<name>"` string from the nested object
            // and map it back to a case by NAME. (A bare-string marshalling — `"active"` —
            // is also accepted as a fallback for a no-payload case the SDK might emit raw.)
            s += """

                    private func \(scanner)(_ s: [UInt8], _ key: String) -> \(typeName)? {
                        let name: String
                        if let (lo, hi) = _patchObjectBody(s, key),
                           let c = _patchScanString(Array(s[lo..<hi]), "case") {
                            name = c
                        } else if let direct = _patchScanString(s, key) {
                            name = direct
                        } else {
                            return nil
                        }
                        switch name {

                """
            for c in el.caseNames {
                // The JSON `"case"` key stays the BARE name (the wire form the SDK
                // marshals — `{"case":"default"}`); the returned member access
                // backtick-escapes a reserved word (`.\`default\``).
                s += "            case \"\(bareIdentifier(c))\": return .\(escapeIdentifier(c))\n"
            }
            s += """
                        default: return nil
                        }
                    }

                """
        }
        return s
    }

    /// The guest Swift type for a flat-struct scalar field.
    private static func scalarSwiftType(_ k: BodyLowering.ViewInput.Kind) -> String {
        switch k {
        case .string: return "String"
        case .bool: return "Bool"
        case .int: return "Int"
        case .double: return "Double"
        default: return "String"   // unreachable (flat fields are scalar)
        }
    }
    /// The default value for a flat-struct scalar field (used when a row's JSON object
    /// is missing the key — faithful, never a crash).
    private static func scalarDefault(_ k: BodyLowering.ViewInput.Kind) -> String {
        switch k {
        case .string: return "\"\""
        case .bool: return "false"
        case .int: return "0"
        case .double: return "0"
        default: return "\"\""
        }
    }
}
