import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `QRGenerateBridge` — generate a QR PNG from a string.
///
/// Layers (per the bridge guide):
///   1. `QRRequest.parse(_:)` / `normalizeCorrection(_:)` — pure decode, tested
///      directly (object form, bare-string fallback, clamping).
///   2. `generate(_:)` — the real CoreImage `CIQRCodeGenerator` path, exercised
///      directly on macOS, asserted to produce a PNG.
///   3. Dispatch — the registered `qr_generate` host fn decodes the arg and packs
///      the PNG. Driven through WasmKit via the generic `(ptr,len)->i64` fixture.
final class QRGenerateBridgeTests: XCTestCase {

    // MARK: - QRRequest.parse(_:)

    func testParseObjectAllFields() throws {
        let req = try XCTUnwrap(QRRequest.parse(Array(#"{"text":"hi","scale":4,"correction":"h"}"#.utf8)))
        XCTAssertEqual(req.text, "hi")
        XCTAssertEqual(req.scale, 4)
        XCTAssertEqual(req.correction, "H", "correction is uppercased + validated")
    }

    func testParseObjectDefaults() throws {
        let req = try XCTUnwrap(QRRequest.parse(Array(#"{"text":"x"}"#.utf8)))
        XCTAssertEqual(req.scale, QRRequest.defaultScale)
        XCTAssertEqual(req.correction, QRRequest.defaultCorrection)
    }

    func testParseScaleClampedToAtLeastOne() throws {
        let req = try XCTUnwrap(QRRequest.parse(Array(#"{"text":"x","scale":0}"#.utf8)))
        XCTAssertEqual(req.scale, 1)
    }

    func testParseUnknownCorrectionDefaultsToM() {
        XCTAssertEqual(QRRequest.normalizeCorrection("Z"), "M")
        XCTAssertEqual(QRRequest.normalizeCorrection(" q "), "Q")
    }

    func testParseBareStringFallback() throws {
        let req = try XCTUnwrap(QRRequest.parse(Array("https://patch.dev".utf8)))
        XCTAssertEqual(req.text, "https://patch.dev")
        XCTAssertEqual(req.scale, QRRequest.defaultScale)
        XCTAssertEqual(req.correction, QRRequest.defaultCorrection)
    }

    func testParseObjectMissingTextIsNil() {
        XCTAssertNil(QRRequest.parse(Array(#"{"scale":4}"#.utf8)))
        XCTAssertNil(QRRequest.parse(Array(#"{"text":""}"#.utf8)))
        XCTAssertNil(QRRequest.parse([]))
    }

    // MARK: - generate (real CoreImage on macOS)

    func testGenerateProducesPNG() throws {
        let out = try XCTUnwrap(QRGenerateBridge.generate(QRRequest(text: "https://patch.dev")))
        XCTAssertFalse(out.isEmpty)
        // PNG magic number.
        XCTAssertEqual(Array(out.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testGenerateScaleAffectsSize() throws {
        let small = try XCTUnwrap(QRGenerateBridge.generate(QRRequest(text: "AAA", scale: 1)))
        let big = try XCTUnwrap(QRGenerateBridge.generate(QRRequest(text: "AAA", scale: 12)))
        XCTAssertGreaterThan(big.count, small.count, "a larger scale → more pixels → bigger PNG")
    }

    // MARK: - Fixture (generic (ptr,len)->i64; import name `fn`, export `call_a`)

    private static let fixtureBase64 =
        "AGFzbQEAAAABEANgAn9/AX5gAX8Bf2ABfwACDAEFcGF0Y2gCZm4AAAMEAwECAAUDAQABBgcBfwFBgAgLBy8EBm1lbW9yeQIADHBhdGNoX21hbGxvYwABCnBhdGNoX2ZyZWUAAgZjYWxsX2EAAwolAxcBAX8jACEBIwAgAGpBB2pBeHEkACABCwIACwgAIAAgARAACw=="

    private func fixtureBytes() throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64)))
    }

    private func makeRuntime() throws -> WASMRuntime {
        let registry = BridgeRegistry()
        registry.registerFunction(name: "fn", parameters: [.i32, .i32], results: [.i64]) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            guard let req = QRRequest.parse(bytes) else { return [.i64(0)] }
            return [try ctx.packedResult(QRGenerateBridge.generate(req))]
        }
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    private func readPacked(_ packed: UInt64, from rt: WASMRuntime) throws -> [UInt8] {
        if packed == 0 { return [] }
        return try rt.read(ptr: UInt32(packed >> 32), len: UInt32(packed & 0xffff_ffff))
    }

    // MARK: - Dispatch

    func testDispatchDecodesAndPacksRealPNG() throws {
        let rt = try makeRuntime()
        let (p, l) = try rt.writeBuffer([UInt8](#"{"text":"round trip","scale":3}"#.utf8))
        let res = try rt.invoke("call_a", [.i32(p), .i32(l)])
        let out = try readPacked(res[0].i64, from: rt)
        XCTAssertEqual(Array(out.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testDispatchEmptyPayloadPacksZero() throws {
        let rt = try makeRuntime()
        let (p, l) = try rt.writeBuffer([])
        let res = try rt.invoke("call_a", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i64, 0, "empty bytes → nil request → packed 0")
    }

    func testModuleNamespace() {
        XCTAssertEqual(QRGenerateBridge(generate: { _ in nil }).module, "patch")
    }
}
