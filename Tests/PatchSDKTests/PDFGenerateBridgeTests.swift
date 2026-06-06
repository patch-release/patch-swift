import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `PDFGenerateBridge` — render text → PDF bytes.
///
/// Layers (per the bridge guide):
///   1. `PDFRequest.parse(_:)` — the pure JSON decode, tested directly.
///   2. `render(_:)` — the real CoreGraphics/CoreText path, exercised directly on
///      macOS (it runs on the host) and asserted to produce a `%PDF-` document.
///   3. Dispatch — the registered `pdf_from_text` host fn decodes the arg and
///      packs the rendered bytes. Driven through WasmKit via the generic
///      `(ptr,len)->i64` fixture (import name `fn`).
final class PDFGenerateBridgeTests: XCTestCase {

    // MARK: - PDFRequest.parse(_:)

    func testParseAllFields() throws {
        let req = try XCTUnwrap(PDFRequest.parse(Array(
            #"{"text":"hi","fontSize":18,"pageWidth":300,"pageHeight":400,"margin":10}"#.utf8)))
        XCTAssertEqual(req, PDFRequest(text: "hi", fontSize: 18, pageWidth: 300, pageHeight: 400, margin: 10))
    }

    func testParseTextOnlyUsesDefaults() throws {
        let req = try XCTUnwrap(PDFRequest.parse(Array(#"{"text":"only"}"#.utf8)))
        XCTAssertEqual(req.fontSize, PDFRequest.defaultFontSize)
        XCTAssertEqual(req.pageWidth, PDFRequest.defaultPageWidth)
        XCTAssertEqual(req.pageHeight, PDFRequest.defaultPageHeight)
        XCTAssertEqual(req.margin, PDFRequest.defaultMargin)
    }

    func testParseNonPositiveGeometryFallsBack() throws {
        let req = try XCTUnwrap(PDFRequest.parse(Array(#"{"text":"t","fontSize":0,"pageWidth":-5}"#.utf8)))
        XCTAssertEqual(req.fontSize, PDFRequest.defaultFontSize)
        XCTAssertEqual(req.pageWidth, PDFRequest.defaultPageWidth)
    }

    func testParseMissingOrEmptyTextIsNil() {
        XCTAssertNil(PDFRequest.parse(Array(#"{"fontSize":12}"#.utf8)))
        XCTAssertNil(PDFRequest.parse(Array(#"{"text":""}"#.utf8)))
        XCTAssertNil(PDFRequest.parse(Array("not json".utf8)))
    }

    // MARK: - render (real CoreGraphics/CoreText on macOS)

    func testRenderProducesPDFDocument() throws {
        let out = try XCTUnwrap(PDFGenerateBridge.render(PDFRequest(text: "Hello PDF")))
        XCTAssertFalse(out.isEmpty)
        // "%PDF-" header.
        XCTAssertEqual(Array(out.prefix(5)), [0x25, 0x50, 0x44, 0x46, 0x2D])
    }

    func testRenderLongTextPaginates() throws {
        // Enough text to overflow one page; render must still succeed (multi-page).
        let long = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 400)
        let out = try XCTUnwrap(PDFGenerateBridge.render(PDFRequest(text: long)))
        XCTAssertEqual(Array(out.prefix(5)), [0x25, 0x50, 0x44, 0x46, 0x2D])
    }

    // MARK: - Fixture (generic (ptr,len)->i64; import name `fn`, export `call_a`)

    private static let fixtureBase64 =
        "AGFzbQEAAAABEANgAn9/AX5gAX8Bf2ABfwACDAEFcGF0Y2gCZm4AAAMEAwECAAUDAQABBgcBfwFBgAgLBy8EBm1lbW9yeQIADHBhdGNoX21hbGxvYwABCnBhdGNoX2ZyZWUAAgZjYWxsX2EAAwolAxcBAX8jACEBIwAgAGpBB2pBeHEkACABCwIACwgAIAAgARAACw=="

    private func fixtureBytes() throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64)))
    }

    private func makeRuntime(_ render: @escaping @Sendable (PDFRequest) -> [UInt8]?) throws -> WASMRuntime {
        let registry = BridgeRegistry()
        registry.registerFunction(name: "fn", parameters: [.i32, .i32], results: [.i64]) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            guard let req = PDFRequest.parse(bytes) else { return [.i64(0)] }
            return [try ctx.packedResult(render(req))]
        }
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    private func readPacked(_ packed: UInt64, from rt: WASMRuntime) throws -> [UInt8] {
        if packed == 0 { return [] }
        return try rt.read(ptr: UInt32(packed >> 32), len: UInt32(packed & 0xffff_ffff))
    }

    // MARK: - Dispatch

    func testDispatchDecodesAndPacksRealPDF() throws {
        let rt = try makeRuntime { req in PDFGenerateBridge.render(req) }
        let (p, l) = try rt.writeBuffer([UInt8](#"{"text":"Round trip"}"#.utf8))
        let res = try rt.invoke("call_a", [.i32(p), .i32(l)])
        let out = try readPacked(res[0].i64, from: rt)
        XCTAssertEqual(Array(out.prefix(5)), [0x25, 0x50, 0x44, 0x46, 0x2D])
    }

    func testDispatchInvalidPayloadPacksZero() throws {
        let rt = try makeRuntime { req in PDFGenerateBridge.render(req) }
        let (p, l) = try rt.writeBuffer([UInt8]("garbage".utf8))
        let res = try rt.invoke("call_a", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i64, 0)
    }

    func testModuleNamespace() {
        XCTAssertEqual(PDFGenerateBridge(render: { _ in nil }).module, "patch")
    }
}
