// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

// =============================================================================
// HostBridgeABI — the ENGINE-SIDE ABI CORE for the generalized "call what's
// already linked" host bridge (Lever #2, part B).
//
// This is the single shared encode/id layer the call-site REWRITER and the
// build-time RESOLVER-THUNK generator both build on. It is the canonical home of
//   1. the content-addressed symbol-id  (`hostBridgeSymbolId`)
//   2. the canonical-signature derivation rules (`canonicalSignature`)
//   3. the guest-side TLV CODEGEN (Foundation-free Swift the engine emits around
//      a rewritten call site — rides the T0 embedded tier)
//   4. the `patch_host_symbols` MANIFEST emission the SDK reads on activation
//   5. the canonical `TLVTag` enum + `HostBridgeSymbol` model
//
// The DESIGN contract is `experiments/host-bridge-generalized/DESIGN.md`. §2.2 is
// the SINGLE SOURCE OF TRUTH for the byte layout; the SDK host implements the same
// table. This file's emitted bytes MUST equal §2.2 exactly — the prototype guest
// (`experiments/host-bridge-generalized/guest/Sources/Guest/main.swift`) is the
// reference for the Foundation-free packing.
//
// NB on toolchains: this file runs on the HOST (Apple/Xcode toolchain), so it can
// use CryptoKit for SHA256. The CODE IT EMITS is wasm32 guest source and is
// strictly embedded-Swift-safe (no Codable / JSONEncoder / ICU): it only does
// byte-array append, integer shifts, and `Array(String.utf8)` — exactly what the
// curated FusionRewriter shims already ride to T0.
// =============================================================================

// MARK: - The canonical TLV tag table (DESIGN §2.2)

/// The self-describing value tag. Every value crossing the generic-bridge boundary
/// is one TLV record `[tag:u8][payload]`. Raw values are FROZEN by DESIGN §2.2 — the
/// SDK host decodes by the same numbers, so these MUST NOT be reordered or renumbered.
///
/// | tag | type   | payload                                              |
/// |-----|--------|------------------------------------------------------|
/// |  0  | nil    | —                                                    |
/// |  1  | i64    | 8 bytes LE                                           |
/// |  2  | f64    | 8 bytes LE bitpattern (finite-clamped)               |
/// |  3  | bool   | 1 byte 0/1                                           |
/// |  4  | string | [len:u32 LE][utf8]                                   |
/// |  5  | bytes  | [len:u32 LE][raw]                                    |
/// |  6  | handle | 4 bytes LE Int32 (opaque native-object proxy)        |
/// |  7  | error  | [len:u32 LE][utf8 message] (host failure → demote)   |
public enum TLVTag: UInt8, Sendable, Hashable, CaseIterable, Codable {
    case nilValue = 0
    case i64      = 1
    case f64      = 2
    case bool     = 3
    case string   = 4
    case bytes    = 5
    case handle   = 6
    case error    = 7

    /// The fixed-size scalar payload byte count, or `nil` for variable-length
    /// (string/bytes/error are `[len:u32][payload]`) and the zero-payload `nilValue`.
    public var fixedPayloadBytes: Int? {
        switch self {
        case .nilValue: return 0
        case .i64:      return 8
        case .f64:      return 8
        case .bool:     return 1
        case .handle:   return 4
        case .string, .bytes, .error: return nil // length-prefixed
        }
    }
}

// MARK: - The canonical symbol model

/// One callable native symbol the engine intends to route through the generic
/// dispatch import. This is the canonical engine-side description the REWRITER
/// produces and the RESOLVER-THUNK + MANIFEST both consume.
///
/// `canonicalSignature` is the content key (§2.3): `id = truncate32(SHA256(sig))`,
/// stable across patch rebuilds (same signature → same id) and the exact string the
/// build-time generated dispatch switch matches.
public struct HostBridgeSymbol: Sendable, Hashable, Codable {
    /// The fully-qualified, demangled canonical signature (the content key). See
    /// `HostBridgeABI.canonicalSignature(...)` for the construction rules.
    public let canonicalSignature: String
    /// `truncate32(SHA256(canonicalSignature))` — the stable integer dispatch id.
    public let id: Int32
    /// Argument TLV tags in call order. For a method, index 0 is the receiver
    /// `handle` (a by-reference receiver) — see `canonicalSignature` rules.
    public let argTags: [TLVTag]
    /// The return TLV tag (`.nilValue` for `Void`/`-> ()`).
    public let retTag: TLVTag

    public init(canonicalSignature: String, argTags: [TLVTag], retTag: TLVTag) {
        self.canonicalSignature = canonicalSignature
        self.id = HostBridgeABI.hostBridgeSymbolId(canonicalSignature)
        self.argTags = argTags
        self.retTag = retTag
    }
}

// MARK: - The ABI core

public enum HostBridgeABI {

    /// The TLV/manifest schema version. Bumped only on a wire-format change; the SDK
    /// refuses a manifest version it can't parse and demotes the generic-bridge
    /// sub-module (PMOD-additive — the rest of the patch still ships). DESIGN §5.
    public static let schemaVersion = 1

    // -------------------------------------------------------------------------
    // MARK: 1. Content-addressed symbol id (DESIGN §2.3)
    // -------------------------------------------------------------------------

    /// `id = truncate32(SHA256(canonicalSignature))`.
    ///
    /// Deterministic and stable: the same canonical signature always yields the same
    /// id across processes, machines, and patch rebuilds. The engine and the on-device
    /// resolver compute the SAME id from the SAME signature string, so the guest's
    /// `symbolId` and the host's compiled-in dispatch switch agree without a shared
    /// constant.
    ///
    /// Truncation: the first 4 bytes of the 32-byte SHA256 digest, interpreted
    /// big-endian, then reinterpreted as `Int32` (so the value matches whatever a
    /// natural "first 4 bytes as a 32-bit integer" read produces; the wire only ever
    /// compares ids for equality, so the signed/unsigned interpretation is irrelevant
    /// as long as engine and host agree — which they do, both using THIS function).
    public static func hostBridgeSymbolId(_ canonicalSignature: String) -> Int32 {
        let digest = SHA256.hash(data: Data(canonicalSignature.utf8))
        // First 4 bytes, big-endian → UInt32 → bit-reinterpret to Int32.
        var u: UInt32 = 0
        for (i, byte) in digest.prefix(4).enumerated() {
            u |= UInt32(byte) << (UInt32(3 - i) * 8)
        }
        return Int32(bitPattern: u)
    }

    // -------------------------------------------------------------------------
    // MARK: 2. canonicalSignature derivation (DESIGN §2.3)
    // -------------------------------------------------------------------------

    /// A resolved call to canonicalize. The engine produces this from the call site +
    /// its resolved types; the resolver-thunk produces the identical string from the
    /// app's compiled types. Both MUST agree byte-for-byte → both call
    /// `canonicalSignature(_:)`.
    public struct ResolvedCall: Sendable, Hashable {
        /// The fully-qualified, MODULE-prefixed declaring type for a method
        /// (`"Foundation.NumberFormatter"`, `"MyApp.PricingEngine"`), or `nil` for a
        /// FREE function. The module prefix is required (disambiguates an app type
        /// from a same-named SDK type).
        public let receiverType: String?
        /// The method / free-function base name (no parens, no labels).
        public let name: String
        /// The parameters in declaration order. For a free function this is the whole
        /// list; for a method these are the parameters AFTER the receiver (the
        /// receiver is implied by `receiverType` and prepended in canonical form).
        public let params: [Param]
        /// The return type in canonical form (see `canonicalTypeName`), or `nil` for
        /// `Void` / `-> ()`.
        public let returnType: String?

        public init(receiverType: String?, name: String, params: [Param], returnType: String?) {
            self.receiverType = receiverType
            self.name = name
            self.params = params
            self.returnType = returnType
        }

        public struct Param: Sendable, Hashable {
            /// The argument label as written at the call site (`from`, `forKey`), or
            /// `nil` for an unlabelled (`_`) parameter.
            public let label: String?
            /// The parameter's canonical type name (see `canonicalTypeName`).
            public let type: String
            public init(label: String?, type: String) {
                self.label = label
                self.type = type
            }
        }
    }

    /// Derive the canonical signature string for a resolved call.
    ///
    /// CANONICAL FORM RULES (frozen — the resolver-thunk MUST follow these exactly):
    ///
    /// 1. **Qualification.** A method is `<ReceiverType>.<name>(<params>)-><ret>`; a
    ///    free function is `<name>(<params>)-><ret>` with no leading dot. The
    ///    receiver type and every named param/return type is MODULE-QUALIFIED
    ///    (`Foundation.NumberFormatter`, `MyApp.PricingEngine`). The receiver is NOT
    ///    listed as a param — it is implied by the prefix (and rides the wire as the
    ///    arg-0 `handle`).
    /// 2. **Param list.** `label:Type` joined by `,` with NO spaces. An unlabelled
    ///    parameter (`_ x: T` / `f(_:)`) is written as just `Type` (no label, no
    ///    colon). Labels are the EXTERNAL argument labels (call-site spelling), not
    ///    the internal parameter names.
    /// 3. **Optionals.** Sugared: `String?`, `[Int]?`. A nested optional is `T??`.
    ///    Always the `?` sugar, never `Optional<T>`.
    /// 4. **Return.** `->Type` with no spaces. A `Void`/`()` return is OMITTED
    ///    entirely (no `->`), so `f()` and `f()->Void` canonicalize the SAME — a
    ///    void-returning call is keyed without a return clause.
    /// 5. **Whitespace.** NONE anywhere — the string is a dense token, never
    ///    pretty-printed. (`canonicalTypeName` strips all internal whitespace too.)
    /// 6. **Ordering.** Params keep DECLARATION order (NOT sorted) — order is part of
    ///    the symbol's identity (`discount(subtotal:,tier:)` ≠ `discount(tier:,subtotal:)`).
    public static func canonicalSignature(_ call: ResolvedCall) -> String {
        var s = ""
        if let recv = call.receiverType {
            s += canonicalTypeName(recv) + "."
        }
        s += call.name + "("
        s += call.params.map { p -> String in
            let t = canonicalTypeName(p.type)
            if let label = p.label, !label.isEmpty {
                return "\(label):\(t)"
            }
            return t
        }.joined(separator: ",")
        s += ")"
        if let ret = call.returnType {
            let r = canonicalTypeName(ret)
            // A Void/() return contributes no `->` clause (rule 4).
            if !isVoidType(r) {
                s += "->" + r
            }
        }
        return s
    }

    /// Normalize a type spelling to canonical form: strip all whitespace, collapse
    /// `Optional<T>` sugar to `T?`, and normalize `()`/`Swift.Void` to `Void`. This
    /// is intentionally syntactic (the engine and resolver both feed in already-
    /// resolved, module-qualified type strings from the same type checker, so a full
    /// structural re-parse isn't needed — only a stable spelling normalization).
    public static func canonicalTypeName(_ raw: String) -> String {
        var t = raw
        // 1. Remove ALL whitespace.
        t = t.filter { !$0.isWhitespace }
        // 2. Normalize the empty tuple / Void spellings.
        if t == "()" || t == "Swift.Void" { t = "Void" }
        // 3. Desugar `Optional<...>` → `...?` (handles nesting, innermost-first).
        t = desugarOptionals(t)
        return t
    }

    /// True for any spelling of the empty return.
    private static func isVoidType(_ canonical: String) -> Bool {
        canonical == "Void" || canonical == "()" || canonical.isEmpty
    }

    /// Collapse every `Optional<X>` to `X?`. Repeatedly rewrites the INNERMOST
    /// `Optional<...>` (one with no nested `Optional<` in its argument) so nesting
    /// like `Optional<Optional<Int>>` becomes `Int??`. Whitespace is already stripped
    /// by the caller.
    private static func desugarOptionals(_ input: String) -> String {
        var s = input
        let marker = "Optional<"
        while let range = innermostOptionalRange(in: s, marker: marker) {
            // range covers `Optional<` ... matching `>`. Pull out the inner type.
            let innerStart = s.index(range.lowerBound, offsetBy: marker.count)
            let innerEnd = s.index(before: range.upperBound) // the matching `>`
            let inner = String(s[innerStart..<innerEnd])
            s.replaceSubrange(range, with: inner + "?")
        }
        return s
    }

    /// Find the byte range of an INNERMOST `Optional<...>` (its angle-bracket body
    /// contains no further `Optional<`), with brackets balanced. Returns `nil` when
    /// none remain.
    private static func innermostOptionalRange(in s: String, marker: String) -> Range<String.Index>? {
        // Scan for the LAST occurrence of the marker whose matching `>` body has no
        // nested `Optional<` — i.e. process innermost-first by taking the last marker.
        guard let lastMarker = s.range(of: marker, options: .backwards) else { return nil }
        // Find the matching `>` for the `<` that ends `lastMarker`.
        var depth = 0
        var idx = s.index(before: lastMarker.upperBound) // the `<`
        var i = idx
        while i < s.endIndex {
            let c = s[i]
            if c == "<" { depth += 1 }
            else if c == ">" {
                depth -= 1
                if depth == 0 {
                    let close = s.index(after: i)
                    return lastMarker.lowerBound..<close
                }
            }
            i = s.index(after: i)
        }
        _ = idx
        return nil
    }

    // -------------------------------------------------------------------------
    // MARK: 3. Guest-side TLV CODEGEN (DESIGN §2.2)
    // -------------------------------------------------------------------------
    //
    // The engine emits this Swift around a rewritten call site. It is embedded-
    // Swift-safe: no Codable, no JSON, no ICU — only byte-array append + integer
    // shifts + `Array(String.utf8)`, exactly mirroring the prototype guest's
    // `ArgWriter`/`decodeResult` and the curated FusionRewriter shims.

    /// One arg to pack: the Swift EXPRESSION producing the value, plus its TLV tag.
    /// `expr` is spliced verbatim into the generated builder (it must be a single
    /// Swift expression of the type the tag implies).
    public struct ArgSpec: Sendable, Hashable {
        public let expr: String
        public let tag: TLVTag
        public init(expr: String, tag: TLVTag) {
            self.expr = expr
            self.tag = tag
        }
    }

    /// The shared guest preamble: the `__PatchTLVWriter` value type + the
    /// `__patchHostCall` dispatcher + the result reader. Emitted ONCE per guest
    /// module that uses the generic bridge (idempotent; guard with a generated-once
    /// flag in the rewriter). Declares no imports — it assumes the CBridge flat
    /// imports (`patch_host_call`/`_release`/`_have`) and `patch_malloc` are linked
    /// (the same CBridge target the prototype carries; the resolver/rewriter wires it).
    ///
    /// This is the canonical Foundation-free runtime the emitted call sites use. Its
    /// byte layout is asserted byte-for-byte against §2.2 in the test suite.
    public static func emitGuestPreamble() -> String {
        """
        // ----- Patch generic host-bridge guest runtime (TLV ABI, DESIGN §2.2) -----
        // Embedded-Swift-safe (byte-array + integer ops only). Emitted by HostBridgeABI.

        @inline(__always)
        private func __patchTLVUnpack(_ packed: Int64) -> (ptr: Int, len: Int) {
            (Int((UInt64(bitPattern: packed) >> 32) & 0xffff_ffff),
             Int(UInt64(bitPattern: packed) & 0xffff_ffff))
        }

        private struct __PatchTLVWriter {
            var buf: [UInt8] = []
            var count: UInt8 = 0
            private mutating func putU32(_ v: UInt32) {
                buf.append(UInt8(v & 0xff)); buf.append(UInt8((v >> 8) & 0xff))
                buf.append(UInt8((v >> 16) & 0xff)); buf.append(UInt8((v >> 24) & 0xff))
            }
            private mutating func putU64(_ v: UInt64) {
                var x = v
                for _ in 0..<8 { buf.append(UInt8(x & 0xff)); x >>= 8 }
            }
            mutating func i64(_ v: Int64)  { count += 1; buf.append(1); putU64(UInt64(bitPattern: v)) }
            mutating func f64(_ v: Double) {
                count += 1; buf.append(2)
                // finite-clamp per the SDK float invariant (no NaN/Inf bit-patterns)
                let c = v.isFinite ? v : 0
                putU64(c.bitPattern)
            }
            mutating func bool(_ v: Bool)  { count += 1; buf.append(3); buf.append(v ? 1 : 0) }
            mutating func string(_ s: String) {
                count += 1; buf.append(4)
                let u = Array(s.utf8); putU32(UInt32(u.count)); buf.append(contentsOf: u)
            }
            mutating func bytes(_ b: [UInt8]) {
                count += 1; buf.append(5)
                putU32(UInt32(b.count)); buf.append(contentsOf: b)
            }
            mutating func handle(_ v: Int32) { count += 1; buf.append(6); putU32(UInt32(bitPattern: v)) }
            mutating func nilValue() { count += 1; buf.append(0) }
            func finish() -> [UInt8] { [count] + buf }
        }

        private enum __PatchTLVValue {
            case nilValue
            case i64(Int64)
            case f64(Double)
            case bool(Bool)
            case string(String)
            case bytes([UInt8])
            case handle(Int32)
            case error(String)
        }

        @inline(__always)
        private func __patchTLVDecode(_ packed: Int64) -> __PatchTLVValue {
            let (ptr, len) = __patchTLVUnpack(packed)
            if ptr == 0 || len == 0 { return .nilValue }
            guard let base = UnsafePointer<UInt8>(bitPattern: ptr) else { return .error("null") }
            let b = Array(UnsafeBufferPointer(start: base, count: len))
            if b.isEmpty { return .nilValue }
            let tag = b[0]
            func u32(_ o: Int) -> UInt32 {
                UInt32(b[o]) | (UInt32(b[o+1]) << 8) | (UInt32(b[o+2]) << 16) | (UInt32(b[o+3]) << 24)
            }
            func u64(_ o: Int) -> UInt64 {
                var v: UInt64 = 0
                var i = 0
                while i < 8 { v |= UInt64(b[o+i]) << (UInt64(i) * 8); i += 1 }
                return v
            }
            switch tag {
            case 0: return .nilValue
            case 1: return .i64(Int64(bitPattern: u64(1)))
            case 2: return .f64(Double(bitPattern: u64(1)))
            case 3: return .bool(b[1] != 0)
            case 6: return .handle(Int32(bitPattern: u32(1)))
            case 4, 5, 7:
                let n = Int(u32(1)); let start = 5
                let end = start + n <= b.count ? start + n : b.count
                let slice = Array(b[start..<end])
                if tag == 5 { return .bytes(slice) }
                let s = String(decoding: slice, as: UTF8.self)
                return tag == 7 ? .error(s) : .string(s)
            default: return .error("badtag")
            }
        }

        @inline(__always)
        private func __patchHostCall(_ symbolId: Int32, _ w: __PatchTLVWriter) -> __PatchTLVValue {
            let blob = w.finish()
            let packed = blob.withUnsafeBufferPointer { bp in
                patch_host_call(symbolId, bp.baseAddress, Int32(bp.count))
            }
            return __patchTLVDecode(packed)
        }
        """
    }

    /// Emit the statements that build the arg blob into a fresh `__PatchTLVWriter`
    /// named `writerName` and append `args` in order. Each tag selects the matching
    /// writer method; the arg's `expr` is spliced as that method's argument.
    ///
    /// Produces, e.g.:
    /// ```
    /// var w = __PatchTLVWriter()
    /// w.handle(__h)
    /// w.f64(amount)
    /// ```
    public static func emitArgBlobBuilder(args: [ArgSpec], writerName: String = "w") -> String {
        var lines = ["var \(writerName) = __PatchTLVWriter()"]
        for a in args {
            switch a.tag {
            case .nilValue: lines.append("\(writerName).nilValue()")
            case .i64:      lines.append("\(writerName).i64(Int64(\(a.expr)))")
            case .f64:      lines.append("\(writerName).f64(Double(\(a.expr)))")
            case .bool:     lines.append("\(writerName).bool(\(a.expr))")
            case .string:   lines.append("\(writerName).string(\(a.expr))")
            case .bytes:    lines.append("\(writerName).bytes(\(a.expr))")
            case .handle:   lines.append("\(writerName).handle(\(a.expr))")
            case .error:    lines.append("\(writerName).string(\(a.expr)) // error tag not arg-writable; sent as string")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Emit the decode of the single result record into `into` (a Swift `let`/`var`
    /// name). The generated code returns the typed Swift value on the success tag and
    /// FALLS THROUGH to the caller's native fallback (an emitted `else` the rewriter
    /// supplies) on `.error` / a tag mismatch — DESIGN §6's fail-closed demote.
    ///
    /// The emitted form binds the success value to `into` via a guard:
    /// ```
    /// guard case .f64(let into) = __r else { /* DEMOTE */ }
    /// ```
    /// where `__r` is `resultVar`. The rewriter splices its native-fallback body into
    /// `demoteBody`. For a `.nilValue` (Void) return the decoder just checks the call
    /// did not error.
    public static func emitResultDecoder(retTag: TLVTag, into: String,
                                         resultVar: String = "__r",
                                         demoteBody: String = "/* demote to native */") -> String {
        switch retTag {
        case .nilValue:
            // Void: success = anything that isn't a tagged error.
            return """
            if case .error = \(resultVar) { \(demoteBody) }
            """
        case .i64:
            return "guard case .i64(let \(into)) = \(resultVar) else { \(demoteBody) }"
        case .f64:
            return "guard case .f64(let \(into)) = \(resultVar) else { \(demoteBody) }"
        case .bool:
            return "guard case .bool(let \(into)) = \(resultVar) else { \(demoteBody) }"
        case .string:
            return "guard case .string(let \(into)) = \(resultVar) else { \(demoteBody) }"
        case .bytes:
            return "guard case .bytes(let \(into)) = \(resultVar) else { \(demoteBody) }"
        case .handle:
            return "guard case .handle(let \(into)) = \(resultVar) else { \(demoteBody) }"
        case .error:
            // No call legitimately RETURNS an error tag; treat as always-demote.
            return "\(demoteBody)"
        }
    }

    /// Convenience: the full rewritten call-site body — build args, dispatch by
    /// content-addressed id, decode (or demote). `resultName` binds the success value.
    /// The rewriter typically wraps this in the §6 `have()` pre-flight + native
    /// fallback; this is the inner happy/demote path.
    public static func emitCallSite(symbol: HostBridgeSymbol,
                                    args: [ArgSpec],
                                    resultName: String,
                                    demoteBody: String = "/* demote to native */") -> String {
        var s = emitArgBlobBuilder(args: args)
        s += "\nlet __r = __patchHostCall(\(symbol.id), w)\n"
        s += emitResultDecoder(retTag: symbol.retTag, into: resultName,
                               resultVar: "__r", demoteBody: demoteBody)
        return s
    }

    // -------------------------------------------------------------------------
    // MARK: 4. The `patch_host_symbols` manifest (DESIGN §2.3 / §5)
    // -------------------------------------------------------------------------

    /// The manifest the SDK reads once per module activation: `{ schemaVersion,
    /// symbols: [{ id, canonicalSignature, argTags[], retTag }] }`. The SDK resolves
    /// each `canonicalSignature` against the app's compiled-in generated dispatch
    /// table (DESIGN §4.2) and serves `patch_host_call(id, …)` from it.
    public struct Manifest: Sendable, Hashable, Codable {
        public let schemaVersion: Int
        public let symbols: [Entry]
        public struct Entry: Sendable, Hashable, Codable {
            public let id: Int32
            public let canonicalSignature: String
            public let argTags: [UInt8]
            public let retTag: UInt8
        }
    }

    /// Build the structured manifest from the routed symbol set.
    public static func buildManifest(_ entries: [HostBridgeSymbol]) -> Manifest {
        Manifest(
            schemaVersion: schemaVersion,
            symbols: entries.map { sym in
                Manifest.Entry(
                    id: sym.id,
                    canonicalSignature: sym.canonicalSignature,
                    argTags: sym.argTags.map { $0.rawValue },
                    retTag: sym.retTag.rawValue
                )
            }
        )
    }

    /// Serialize the manifest to the JSON the SDK reads (`patch_host_symbols`). Keys
    /// are sorted for byte-stable, content-addressable output (a rebuilt patch with
    /// the same routed set → byte-identical manifest). This rides as engine-side
    /// metadata alongside the module (NOT in the embedded guest), so JSON is fine
    /// here — the embedded-Swift constraint applies only to the guest TLV codegen.
    public static func emitManifestJSON(_ entries: [HostBridgeSymbol]) throws -> Data {
        let manifest = buildManifest(entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    /// String convenience for callers that want UTF-8 text (e.g. to write the
    /// manifest file next to the module).
    public static func emitManifestString(_ entries: [HostBridgeSymbol]) throws -> String {
        String(decoding: try emitManifestJSON(entries), as: UTF8.self)
    }

    /// The guest export name the SDK reads on activation (`Patch.hostSymbolManifestExportName`).
    /// SAME packed `(ptr,len)->i64` ABI as `patch_view_manifest` — the SDK calls it
    /// via `callPacked` and parses the returned JSON bytes as the routed-symbol side
    /// table. The JSON FILE (`patch_host_symbols.json`) stays for engine-side
    /// debugging; THIS guest export is what ships in the module so the SDK's
    /// activation cross-check (`HostBridgeActivation.refreshHostBridgeForActiveModuleSet`)
    /// sees the declared routed-symbol set.
    public static let manifestExportName = "patch_host_symbols"

    /// Back-compat alias used by `GenericHostBridgeGuestEmitter` (the module-wire
    /// guest assembler). Same wire name; `manifestExportName` is the source of truth.
    public static var manifestGuestExport: String { manifestExportName }

    /// Emit the `@_cdecl("patch_host_symbols")` GUEST export carrying the manifest
    /// JSON. The export ignores its `(ptr,len)` input and returns the packed
    /// `(outPtr<<32)|outLen` of the manifest bytes allocated via `patch_malloc` — the
    /// IDENTICAL ABI the SDK already decodes for `patch_view_manifest`. The JSON is a
    /// baked compile-time string literal (no in-guest JSON building → embedded-safe).
    ///
    /// `includeAllocator` emits the `patch_malloc`/`patch_free` + `_patchEmit`
    /// helpers; pass `false` when the host module already carries them (e.g. merged
    /// with a SwiftUI/general-logic guest that exports them) so the symbols don't
    /// collide. The standalone host-bridge guest module passes `true`.
    public static func emitManifestGuestExport(_ entries: [HostBridgeSymbol],
                                               includeAllocator: Bool = true) throws -> String {
        let json = try emitManifestString(entries)
        let literal = swiftStringLiteralBody(json)
        var out = """
        // Auto-generated by Patch — the `patch_host_symbols` routed-symbol manifest,
        // emitted as a GUEST EXPORT (packed (ptr,len)->i64, same ABI as
        // patch_view_manifest) so the SDK reads it on module activation. DO NOT EDIT.

        """
        if includeAllocator {
            out += """

            @_cdecl("patch_malloc")
            public func patch_malloc(_ size: Int32) -> UnsafeMutableRawPointer? {
                UnsafeMutableRawPointer.allocate(byteCount: Int(max(size, 1)), alignment: 8)
            }

            @_cdecl("patch_free")
            public func patch_free(_ ptr: UnsafeMutableRawPointer?) {
                ptr?.deallocate()
            }

            private func _patchHBEmit(_ bytes: [UInt8]) -> Int64 {
                let n = bytes.count
                let out = UnsafeMutableRawPointer.allocate(byteCount: max(n, 1), alignment: 8)
                let outBytes = out.assumingMemoryBound(to: UInt8.self)
                for i in 0..<n { outBytes[i] = bytes[i] }
                let outPtr = Int32(bitPattern: UInt32(UInt(bitPattern: out)))
                return (Int64(outPtr) << 32) | Int64(n)
            }

            """
        }
        out += """

        @_cdecl("\(manifestExportName)")
        public func \(manifestExportName)(_ ptr: Int32, _ len: Int32) -> Int64 {
            _ = (ptr, len)
            let json = "\(literal)"
            return _patchHBEmit(Array(json.utf8))
        }
        """
        return out
    }

    /// Escape a String for embedding inside a Swift `"…"` literal (the manifest JSON
    /// carries `"`, `\\`, and possibly control chars). Embedded-safe at runtime — the
    /// guest only does `Array(json.utf8)` over the baked literal.
    static func swiftStringLiteralBody(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u{%x}", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }
}
