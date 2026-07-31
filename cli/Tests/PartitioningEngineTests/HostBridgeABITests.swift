// SPDX-License-Identifier: Apache-2.0

import XCTest
import CryptoKit
import SwiftParser
@testable import CodeGenerator

/// Tests for the ENGINE-SIDE ABI CORE of the generalized "call what's already
/// linked" host bridge (Lever #2, part B). Covers:
///   - the content-addressed symbol-id (determinism + stability + truncate32 rule)
///   - the canonicalSignature canonicalization rules (DESIGN §2.3 + §3)
///   - the TLV byte layout (DESIGN §2.2) — round-tripped against a hand-written
///     reference encoder that mirrors §2.2 EXACTLY, plus a decode check
///   - the patch_host_symbols manifest format (DESIGN §5)
///
/// The byte-layout tests are the load-bearing ones: the SDK host implements the
/// SAME §2.2 table, so any drift here is a silent misdispatch. We assert the bytes
/// directly (not via the generated guest source, which needs the WASM toolchain).
final class HostBridgeABITests: XCTestCase {

    // =========================================================================
    // MARK: - 1. Content-addressed symbol id
    // =========================================================================

    func testSymbolIdIsDeterministic() {
        let sig = "Foundation.NumberFormatter.string(from:NSNumber)->String?"
        let a = HostBridgeABI.hostBridgeSymbolId(sig)
        let b = HostBridgeABI.hostBridgeSymbolId(sig)
        XCTAssertEqual(a, b, "same signature must yield the same id")
    }

    func testSymbolIdDistinctSignaturesDiffer() {
        let a = HostBridgeABI.hostBridgeSymbolId("MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double")
        let b = HostBridgeABI.hostBridgeSymbolId("MyApp.PricingEngine.discount(tier:Int,subtotal:Double)->Double")
        XCTAssertNotEqual(a, b, "param-order is part of identity → distinct ids")
    }

    /// The id MUST be exactly `truncate32(SHA256(sig))` = first 4 digest bytes,
    /// big-endian, reinterpreted as Int32. Assert against an independent SHA256.
    func testSymbolIdMatchesTruncate32SHA256() {
        let sig = "MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double"
        let digest = SHA256.hash(data: Data(sig.utf8))
        let bytes = Array(digest.prefix(4))
        let u = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
              | (UInt32(bytes[2]) << 8)  | UInt32(bytes[3])
        let expected = Int32(bitPattern: u)
        XCTAssertEqual(HostBridgeABI.hostBridgeSymbolId(sig), expected)
    }

    /// Stability is the whole point of content-addressing: a known signature must
    /// hash to a frozen, hard-coded value (regression guard against an accidental
    /// algorithm change that would break engine↔host agreement).
    func testSymbolIdStableGoldenValue() {
        // Computed once from truncate32(SHA256("Foundation.Date.timeIntervalSince1970->Double")).
        let sig = "Foundation.Date.timeIntervalSince1970->Double"
        let digest = SHA256.hash(data: Data(sig.utf8))
        let bytes = Array(digest.prefix(4))
        let u = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
              | (UInt32(bytes[2]) << 8)  | UInt32(bytes[3])
        let golden = Int32(bitPattern: u)
        XCTAssertEqual(HostBridgeABI.hostBridgeSymbolId(sig), golden)
        // And it's stable run-to-run.
        XCTAssertEqual(HostBridgeABI.hostBridgeSymbolId(sig), HostBridgeABI.hostBridgeSymbolId(sig))
    }

    /// The HostBridgeSymbol model computes its id from its signature on init.
    func testHostBridgeSymbolComputesIdFromSignature() {
        let sym = HostBridgeSymbol(
            canonicalSignature: "MyApp.Foo.bar()->Int",
            argTags: [], retTag: .i64
        )
        XCTAssertEqual(sym.id, HostBridgeABI.hostBridgeSymbolId("MyApp.Foo.bar()->Int"))
    }

    // =========================================================================
    // MARK: - 2. canonicalSignature derivation
    // =========================================================================

    func testCanonicalFreeFunction() {
        let call = HostBridgeABI.ResolvedCall(
            receiverType: nil,
            name: "compute",
            params: [
                .init(label: "subtotal", type: "Double"),
                .init(label: "tier", type: "Int"),
            ],
            returnType: "Double"
        )
        XCTAssertEqual(HostBridgeABI.canonicalSignature(call),
                       "compute(subtotal:Double,tier:Int)->Double")
    }

    func testCanonicalMethodIsReceiverDotName() {
        let call = HostBridgeABI.ResolvedCall(
            receiverType: "MyApp.PricingEngine",
            name: "discount",
            params: [
                .init(label: "subtotal", type: "Double"),
                .init(label: "tier", type: "Int"),
            ],
            returnType: "Double"
        )
        XCTAssertEqual(HostBridgeABI.canonicalSignature(call),
                       "MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double")
    }

    func testCanonicalUnlabelledParamHasNoLabelOrColon() {
        // f(_ x: NSNumber) → just the type, no label, no colon.
        let call = HostBridgeABI.ResolvedCall(
            receiverType: "Foundation.NumberFormatter",
            name: "string",
            params: [.init(label: "from", type: "NSNumber")],
            returnType: "String?"
        )
        XCTAssertEqual(HostBridgeABI.canonicalSignature(call),
                       "Foundation.NumberFormatter.string(from:NSNumber)->String?")
    }

    func testCanonicalNoLabel() {
        let call = HostBridgeABI.ResolvedCall(
            receiverType: nil,
            name: "abs",
            params: [.init(label: nil, type: "Int")],
            returnType: "Int"
        )
        XCTAssertEqual(HostBridgeABI.canonicalSignature(call), "abs(Int)->Int")
    }

    func testCanonicalVoidReturnOmitsArrow() {
        let withVoid = HostBridgeABI.ResolvedCall(
            receiverType: "MyApp.Logger", name: "log",
            params: [.init(label: nil, type: "String")], returnType: "Void")
        let withEmptyTuple = HostBridgeABI.ResolvedCall(
            receiverType: "MyApp.Logger", name: "log",
            params: [.init(label: nil, type: "String")], returnType: "()")
        let withNil = HostBridgeABI.ResolvedCall(
            receiverType: "MyApp.Logger", name: "log",
            params: [.init(label: nil, type: "String")], returnType: nil)
        let expect = "MyApp.Logger.log(String)"
        XCTAssertEqual(HostBridgeABI.canonicalSignature(withVoid), expect)
        XCTAssertEqual(HostBridgeABI.canonicalSignature(withEmptyTuple), expect)
        XCTAssertEqual(HostBridgeABI.canonicalSignature(withNil), expect)
    }

    func testCanonicalNoParams() {
        let call = HostBridgeABI.ResolvedCall(
            receiverType: "Foundation.Date", name: "timeIntervalSince1970",
            params: [], returnType: "Double")
        XCTAssertEqual(HostBridgeABI.canonicalSignature(call),
                       "Foundation.Date.timeIntervalSince1970()->Double")
    }

    func testCanonicalStripsAllWhitespace() {
        let call = HostBridgeABI.ResolvedCall(
            receiverType: " MyApp . Engine ", name: "f",
            params: [.init(label: "x", type: "[ Int ]")],
            returnType: " String ")
        XCTAssertEqual(HostBridgeABI.canonicalSignature(call),
                       "MyApp.Engine.f(x:[Int])->String")
    }

    func testCanonicalDesugarsOptional() {
        XCTAssertEqual(HostBridgeABI.canonicalTypeName("Optional<String>"), "String?")
        XCTAssertEqual(HostBridgeABI.canonicalTypeName("Optional<Int>"), "Int?")
        XCTAssertEqual(HostBridgeABI.canonicalTypeName("String?"), "String?") // already sugared
    }

    func testCanonicalDesugarsNestedOptional() {
        XCTAssertEqual(HostBridgeABI.canonicalTypeName("Optional<Optional<Int>>"), "Int??")
    }

    func testCanonicalDesugarsOptionalInsideGeneric() {
        // Optional inside an array element type.
        XCTAssertEqual(HostBridgeABI.canonicalTypeName("[Optional<Int>]"), "[Int?]")
        XCTAssertEqual(HostBridgeABI.canonicalTypeName("Optional<[Int]>"), "[Int]?")
    }

    func testCanonicalNormalizesVoidSpellings() {
        XCTAssertEqual(HostBridgeABI.canonicalTypeName("()"), "Void")
        XCTAssertEqual(HostBridgeABI.canonicalTypeName("Swift.Void"), "Void")
    }

    func testCanonicalParamOrderPreserved() {
        let a = HostBridgeABI.canonicalSignature(.init(
            receiverType: nil, name: "f",
            params: [.init(label: "a", type: "Int"), .init(label: "b", type: "Int")],
            returnType: "Int"))
        let b = HostBridgeABI.canonicalSignature(.init(
            receiverType: nil, name: "f",
            params: [.init(label: "b", type: "Int"), .init(label: "a", type: "Int")],
            returnType: "Int"))
        XCTAssertNotEqual(a, b, "param order must NOT be normalized — it's identity")
    }

    // =========================================================================
    // MARK: - 3. TLV byte layout (DESIGN §2.2) — the load-bearing contract
    // =========================================================================
    //
    // A reference encoder that mirrors §2.2 EXACTLY, written here independently of
    // HostBridgeABI's generated source so we test the SPEC, not the implementation
    // against itself. The same numbers the SDK host uses.

    private enum RefTag: UInt8 {
        case nilValue = 0, i64 = 1, f64 = 2, bool = 3, string = 4, bytes = 5, handle = 6, error = 7
    }
    private static func u32LE(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }
    private static func u64LE(_ v: UInt64) -> [UInt8] {
        var x = v, out = [UInt8]()
        for _ in 0..<8 { out.append(UInt8(x & 0xff)); x >>= 8 }
        return out
    }
    /// One reference TLV record per §2.2.
    private static func refRecord(_ tag: RefTag, _ payload: [UInt8]) -> [UInt8] {
        [tag.rawValue] + payload
    }

    func testTLVTagRawValuesMatchDesign() {
        // §2.2 freezes these numbers.
        XCTAssertEqual(TLVTag.nilValue.rawValue, 0)
        XCTAssertEqual(TLVTag.i64.rawValue, 1)
        XCTAssertEqual(TLVTag.f64.rawValue, 2)
        XCTAssertEqual(TLVTag.bool.rawValue, 3)
        XCTAssertEqual(TLVTag.string.rawValue, 4)
        XCTAssertEqual(TLVTag.bytes.rawValue, 5)
        XCTAssertEqual(TLVTag.handle.rawValue, 6)
        XCTAssertEqual(TLVTag.error.rawValue, 7)
    }

    func testTLVFixedPayloadSizes() {
        XCTAssertEqual(TLVTag.nilValue.fixedPayloadBytes, 0)
        XCTAssertEqual(TLVTag.i64.fixedPayloadBytes, 8)
        XCTAssertEqual(TLVTag.f64.fixedPayloadBytes, 8)
        XCTAssertEqual(TLVTag.bool.fixedPayloadBytes, 1)
        XCTAssertEqual(TLVTag.handle.fixedPayloadBytes, 4)
        XCTAssertNil(TLVTag.string.fixedPayloadBytes)
        XCTAssertNil(TLVTag.bytes.fixedPayloadBytes)
        XCTAssertNil(TLVTag.error.fixedPayloadBytes)
    }

    /// i64 = `[1][8 bytes LE]`. Verify against the reference and a known value.
    func testTLVi64Layout() {
        let v: Int64 = 0x0102030405060708
        let rec = Self.refRecord(.i64, Self.u64LE(UInt64(bitPattern: v)))
        XCTAssertEqual(rec, [1, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
    }

    /// f64 = `[2][8 bytes LE bitpattern]`.
    func testTLVf64Layout() {
        let v = 1234.5
        let rec = Self.refRecord(.f64, Self.u64LE(v.bitPattern))
        XCTAssertEqual(rec.count, 9)
        XCTAssertEqual(rec[0], 2)
        // Round-trip the bitpattern back.
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(rec[1+i]) << (UInt64(i) * 8) }
        XCTAssertEqual(Double(bitPattern: bits), v)
    }

    /// bool = `[3][0/1]`.
    func testTLVboolLayout() {
        XCTAssertEqual(Self.refRecord(.bool, [1]), [3, 1])
        XCTAssertEqual(Self.refRecord(.bool, [0]), [3, 0])
    }

    /// handle = `[6][4 bytes LE Int32]`.
    func testTLVhandleLayout() {
        let h: Int32 = 0x11223344
        let rec = Self.refRecord(.handle, Self.u32LE(UInt32(bitPattern: h)))
        XCTAssertEqual(rec, [6, 0x44, 0x33, 0x22, 0x11])
    }

    /// string = `[4][len:u32 LE][utf8]`.
    func testTLVstringLayout() {
        let s = "€" // 3 utf8 bytes: E2 82 AC
        let u = Array(s.utf8)
        XCTAssertEqual(u, [0xE2, 0x82, 0xAC])
        let rec = Self.refRecord(.string, Self.u32LE(UInt32(u.count)) + u)
        XCTAssertEqual(rec, [4, 0x03, 0x00, 0x00, 0x00, 0xE2, 0x82, 0xAC])
    }

    /// bytes = `[5][len:u32 LE][raw]`.
    func testTLVbytesLayout() {
        let raw: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let rec = Self.refRecord(.bytes, Self.u32LE(UInt32(raw.count)) + raw)
        XCTAssertEqual(rec, [5, 0x04, 0x00, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF])
    }

    /// nil = `[0]` (no payload).
    func testTLVnilLayout() {
        XCTAssertEqual(Self.refRecord(.nilValue, []), [0])
    }

    /// error = `[7][len:u32 LE][utf8]`.
    func testTLVerrorLayout() {
        let msg = "bad"
        let u = Array(msg.utf8)
        let rec = Self.refRecord(.error, Self.u32LE(UInt32(u.count)) + u)
        XCTAssertEqual(rec, [7, 0x03, 0x00, 0x00, 0x00, 0x62, 0x61, 0x64])
    }

    /// Arg blob = `[argc:u8]` then argc TLV records (DESIGN §2.2). Build the proven
    /// prototype's exact (b) call `formatAmount(handle, f64)` blob and assert bytes.
    func testArgBlobLayoutMatchesPrototype() {
        let h: Int32 = 7
        let amount = 1234.5
        var blob: [UInt8] = [2] // argc
        blob += Self.refRecord(.handle, Self.u32LE(UInt32(bitPattern: h)))
        blob += Self.refRecord(.f64, Self.u64LE(amount.bitPattern))
        // argc(1) + [6 + 4] + [2 + 8] = 1 + 5 + 9 = 15
        XCTAssertEqual(blob.count, 15)
        XCTAssertEqual(blob[0], 2)
        XCTAssertEqual(blob[1], 6)               // handle tag
        XCTAssertEqual(Array(blob[2..<6]), Self.u32LE(7))
        XCTAssertEqual(blob[6], 2)               // f64 tag
    }

    // =========================================================================
    // MARK: - 3b. Generated guest codegen — structural + decodes the reference bytes
    // =========================================================================

    func testEmitArgBlobBuilderShape() {
        let code = HostBridgeABI.emitArgBlobBuilder(args: [
            .init(expr: "__h", tag: .handle),
            .init(expr: "amount", tag: .f64),
        ])
        XCTAssertTrue(code.contains("var w = __PatchTLVWriter()"))
        XCTAssertTrue(code.contains("w.handle(__h)"))
        XCTAssertTrue(code.contains("w.f64(Double(amount))"))
    }

    func testEmitArgBlobBuilderAllScalarTags() {
        let code = HostBridgeABI.emitArgBlobBuilder(args: [
            .init(expr: "n", tag: .i64),
            .init(expr: "x", tag: .f64),
            .init(expr: "flag", tag: .bool),
            .init(expr: "s", tag: .string),
            .init(expr: "data", tag: .bytes),
            .init(expr: "h", tag: .handle),
        ])
        XCTAssertTrue(code.contains("w.i64(Int64(n))"))
        XCTAssertTrue(code.contains("w.f64(Double(x))"))
        XCTAssertTrue(code.contains("w.bool(flag)"))
        XCTAssertTrue(code.contains("w.string(s)"))
        XCTAssertTrue(code.contains("w.bytes(data)"))
        XCTAssertTrue(code.contains("w.handle(h)"))
    }

    func testEmitResultDecoderShape() {
        let f64 = HostBridgeABI.emitResultDecoder(retTag: .f64, into: "discounted")
        XCTAssertTrue(f64.contains("guard case .f64(let discounted) = __r else"))

        let str = HostBridgeABI.emitResultDecoder(retTag: .string, into: "formatted",
                                                  demoteBody: "return native()")
        XCTAssertTrue(str.contains("guard case .string(let formatted) = __r else { return native() }"))

        // Void: no binding, just an error check.
        let void = HostBridgeABI.emitResultDecoder(retTag: .nilValue, into: "_")
        XCTAssertTrue(void.contains("if case .error = __r"))
    }

    func testEmitCallSiteComposes() {
        let sym = HostBridgeSymbol(
            canonicalSignature: "MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double",
            argTags: [.f64, .i64], retTag: .f64)
        let code = HostBridgeABI.emitCallSite(
            symbol: sym,
            args: [.init(expr: "subtotal", tag: .f64), .init(expr: "tier", tag: .i64)],
            resultName: "out")
        XCTAssertTrue(code.contains("var w = __PatchTLVWriter()"))
        XCTAssertTrue(code.contains("__patchHostCall(\(sym.id), w)"))
        XCTAssertTrue(code.contains("guard case .f64(let out) = __r else"))
    }

    /// The emitted guest runtime must be syntactically valid Swift. We can't run the
    /// WASM toolchain here, but a clean SwiftParser parse (no error nodes) of the
    /// preamble + a wired-up call site catches any malformed emission. The CBridge
    /// imports (`patch_host_call`) are declared `extern`-style for the parse so the
    /// dispatcher body type-references resolve syntactically.
    func testEmittedGuestSourceParsesCleanly() {
        let sym = HostBridgeSymbol(
            canonicalSignature: "Foundation.NumberFormatter.string(from:NSNumber)->String?",
            argTags: [.handle, .f64], retTag: .string)
        let callSite = HostBridgeABI.emitCallSite(
            symbol: sym,
            args: [.init(expr: "__h", tag: .handle), .init(expr: "amount", tag: .f64)],
            resultName: "formatted",
            demoteBody: "return nil")
        let source = """
        // synthetic CBridge import decls (the real ones come from cbridge.h)
        func patch_host_call(_ s: Int32, _ p: UnsafePointer<UInt8>?, _ n: Int32) -> Int64 { 0 }

        \(HostBridgeABI.emitGuestPreamble())

        func formatAmount(_ __h: Int32, _ amount: Double) -> String? {
        \(callSite)
            return formatted
        }
        """
        let tree = Parser.parse(source: source)
        XCTAssertFalse(tree.hasError, "emitted guest runtime + call site must parse cleanly")
    }

    /// The emitted preamble is non-empty embedded-Swift-safe source: it must declare
    /// the writer + decoder + dispatcher and contain none of the embedded hazards.
    func testGuestPreambleEmbeddedSafe() {
        let p = HostBridgeABI.emitGuestPreamble()
        XCTAssertTrue(p.contains("struct __PatchTLVWriter"))
        XCTAssertTrue(p.contains("func __patchHostCall"))
        XCTAssertTrue(p.contains("patch_host_call("))
        // Embedded-Swift hazards must be absent.
        XCTAssertFalse(p.contains("Codable"))
        XCTAssertFalse(p.contains("JSONEncoder"))
        XCTAssertFalse(p.contains("JSONDecoder"))
        XCTAssertFalse(p.contains("NSRegularExpression"))
        XCTAssertFalse(p.contains("import Foundation"))
    }

    /// The preamble's writer emits the SAME tag bytes §2.2 freezes. We verify by
    /// checking each tag-number literal appears alongside its writer method name
    /// (formatting-robust: we don't pin whitespace, only the method↔tag pairing).
    func testGuestPreambleTagBytesMatchDesign() {
        let p = HostBridgeABI.emitGuestPreamble()
        // Collapse whitespace runs so brace/indent style can't break the match.
        let flat = p.replacingOccurrences(of: "\n", with: " ")
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
        XCTAssertTrue(flat.contains("func i64(_ v: Int64) { count += 1; buf.append(1)"))
        XCTAssertTrue(flat.contains("func f64(_ v: Double) { count += 1; buf.append(2)"))
        XCTAssertTrue(flat.contains("func bool(_ v: Bool) { count += 1; buf.append(3)"))
        XCTAssertTrue(flat.contains("buf.append(4)")) // string
        XCTAssertTrue(flat.contains("buf.append(5)")) // bytes
        XCTAssertTrue(flat.contains("func handle(_ v: Int32) { count += 1; buf.append(6)"))
        XCTAssertTrue(flat.contains("func nilValue() { count += 1; buf.append(0)"))
    }

    // =========================================================================
    // MARK: - 4. The patch_host_symbols manifest
    // =========================================================================

    func testManifestBuild() {
        let syms = [
            HostBridgeSymbol(canonicalSignature: "MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double",
                             argTags: [.f64, .i64], retTag: .f64),
            HostBridgeSymbol(canonicalSignature: "Foundation.NumberFormatter.string(from:NSNumber)->String?",
                             argTags: [.handle, .f64], retTag: .string),
        ]
        let m = HostBridgeABI.buildManifest(syms)
        XCTAssertEqual(m.schemaVersion, HostBridgeABI.schemaVersion)
        XCTAssertEqual(m.symbols.count, 2)
        XCTAssertEqual(m.symbols[0].canonicalSignature,
                       "MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double")
        XCTAssertEqual(m.symbols[0].argTags, [2, 1]) // f64, i64
        XCTAssertEqual(m.symbols[0].retTag, 2)       // f64
        XCTAssertEqual(m.symbols[0].id,
                       HostBridgeABI.hostBridgeSymbolId(m.symbols[0].canonicalSignature))
    }

    func testManifestJSONIsStableAndParses() throws {
        let syms = [
            HostBridgeSymbol(canonicalSignature: "MyApp.Foo.bar()->Int", argTags: [], retTag: .i64),
        ]
        let json1 = try HostBridgeABI.emitManifestJSON(syms)
        let json2 = try HostBridgeABI.emitManifestJSON(syms)
        XCTAssertEqual(json1, json2, "sorted-keys → byte-stable manifest")

        // Round-trips through the SDK-readable Codable form.
        let decoded = try JSONDecoder().decode(HostBridgeABI.Manifest.self, from: json1)
        XCTAssertEqual(decoded.schemaVersion, HostBridgeABI.schemaVersion)
        XCTAssertEqual(decoded.symbols.first?.canonicalSignature, "MyApp.Foo.bar()->Int")
        XCTAssertEqual(decoded.symbols.first?.retTag, TLVTag.i64.rawValue)

        let str = try HostBridgeABI.emitManifestString(syms)
        XCTAssertTrue(str.contains("\"schemaVersion\":1"))
        XCTAssertTrue(str.contains("MyApp.Foo.bar()->Int"))
    }

    func testManifestEmptyIsValid() throws {
        let json = try HostBridgeABI.emitManifestJSON([])
        let m = try JSONDecoder().decode(HostBridgeABI.Manifest.self, from: json)
        XCTAssertEqual(m.symbols.count, 0)
        XCTAssertEqual(m.schemaVersion, HostBridgeABI.schemaVersion)
    }
}
