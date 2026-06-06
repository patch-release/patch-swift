import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `DocumentPickerBridge` — the system document-picker host bridge.
///
/// Two layers, per the bridge implementation guide:
///   1. `parsePicker(_:)` / `parseExport(_:)` — the pure JSON decoders, tested
///      directly with deterministic inputs (mode + types parse for the picker;
///      filename + base64-decode for export).
///   2. Dispatch — the registered `patch.present_document_picker` /
///      `patch.export_document` host functions decode the guest `(ptr,len)` arg
///      and invoke the injected handler with the right request. Driven
///      end-to-end through WasmKit via a tiny hand-built module (imports both
///      host fns, exports `call_present` / `call_export`) so no shared fixture is
///      touched and the test runs on macOS without UIKit.
final class DocumentPickerBridgeTests: XCTestCase {

    // MARK: - parsePicker(_:) pure decode

    func testParsePickerImportWithTypes() {
        let req = DocumentPickerBridge.parsePicker(
            Array(#"{"mode":"import","types":["public.json","public.text"]}"#.utf8))
        XCTAssertEqual(req?.mode, "import")
        XCTAssertEqual(req?.types, ["public.json", "public.text"])
    }

    func testParsePickerExportMode() {
        let req = DocumentPickerBridge.parsePicker(
            Array(#"{"mode":"export","types":["public.json"]}"#.utf8))
        XCTAssertEqual(req?.mode, "export")
        XCTAssertEqual(req?.types, ["public.json"])
    }

    func testParsePickerMissingTypesDefaultsToEmpty() {
        let req = DocumentPickerBridge.parsePicker(Array(#"{"mode":"import"}"#.utf8))
        XCTAssertEqual(req?.mode, "import")
        XCTAssertEqual(req?.types, [], "missing types key → empty array")
    }

    func testParsePickerMissingModeDefaultsToEmptyString() {
        let req = DocumentPickerBridge.parsePicker(Array(#"{"types":["public.png"]}"#.utf8))
        XCTAssertEqual(req?.mode, "", "missing mode key → empty string")
        XCTAssertEqual(req?.types, ["public.png"])
    }

    func testParsePickerDropsNonStringTypeEntries() {
        // Numeric / object entries in `types` are dropped, not crash-inducing.
        let req = DocumentPickerBridge.parsePicker(
            Array(#"{"mode":"import","types":["public.json",42,{"x":1}]}"#.utf8))
        XCTAssertEqual(req?.types, ["public.json"])
    }

    func testParsePickerInvalidJSONReturnsNil() {
        XCTAssertNil(DocumentPickerBridge.parsePicker(Array("not json {".utf8)))
    }

    func testParsePickerNonObjectJSONReturnsNil() {
        // A top-level array (valid JSON, wrong shape) → nil.
        XCTAssertNil(DocumentPickerBridge.parsePicker(Array(#"["import"]"#.utf8)))
    }

    func testParsePickerEmptyBytesReturnsNil() {
        XCTAssertNil(DocumentPickerBridge.parsePicker([]))
    }

    // MARK: - parseExport(_:) pure decode (incl. base64)

    func testParseExportDecodesBase64() {
        let payload = "Hello, Patch!"
        let b64 = Data(payload.utf8).base64EncodedString()
        let json = #"{"filename":"out.txt","data_base64":"\#(b64)"}"#
        let req = DocumentPickerBridge.parseExport(Array(json.utf8))
        XCTAssertEqual(req?.filename, "out.txt")
        XCTAssertEqual(req?.data, Data(payload.utf8))
        XCTAssertEqual(req.map { String(decoding: $0.data, as: UTF8.self) }, payload)
    }

    func testParseExportDecodesBinaryBase64() {
        let bytes = Data([0x00, 0x01, 0xFE, 0xFF, 0x10, 0x20])
        let b64 = bytes.base64EncodedString()
        let json = #"{"filename":"blob.bin","data_base64":"\#(b64)"}"#
        let req = DocumentPickerBridge.parseExport(Array(json.utf8))
        XCTAssertEqual(req?.filename, "blob.bin")
        XCTAssertEqual(req?.data, bytes)
    }

    func testParseExportMissingDataDefaultsToEmpty() {
        let req = DocumentPickerBridge.parseExport(Array(#"{"filename":"empty.dat"}"#.utf8))
        XCTAssertEqual(req?.filename, "empty.dat")
        XCTAssertEqual(req?.data, Data(), "missing data_base64 → empty Data")
    }

    func testParseExportMalformedBase64DefaultsToEmpty() {
        // "!!!!" is not valid base64; the bytes fall back to empty rather than nil.
        let req = DocumentPickerBridge.parseExport(
            Array(#"{"filename":"x","data_base64":"!!!!"}"#.utf8))
        XCTAssertEqual(req?.filename, "x")
        XCTAssertEqual(req?.data, Data())
    }

    func testParseExportMissingFilenameDefaultsToEmptyString() {
        let b64 = Data("hi".utf8).base64EncodedString()
        let req = DocumentPickerBridge.parseExport(
            Array(#"{"data_base64":"\#(b64)"}"#.utf8))
        XCTAssertEqual(req?.filename, "")
        XCTAssertEqual(req?.data, Data("hi".utf8))
    }

    func testParseExportInvalidJSONReturnsNil() {
        XCTAssertNil(DocumentPickerBridge.parseExport(Array("garbage".utf8)))
    }

    func testParseExportEmptyBytesReturnsNil() {
        XCTAssertNil(DocumentPickerBridge.parseExport([]))
    }

    // MARK: - Dispatch (guest -> host) through a hand-built module

    /// A minimal wasm module (compiled from WAT with wat2wasm):
    ///   (module
    ///     (import "patch" "present_document_picker" (func $present (param i32 i32)))
    ///     (import "patch" "export_document"         (func $export  (param i32 i32)))
    ///     (memory (export "memory") 1)
    ///     (global $bump (mut i32) (i32.const 1024))
    ///     (func $patch_malloc (export "patch_malloc") (param $n i32) (result i32) … bump …)
    ///     (func $patch_free (export "patch_free") (param i32))
    ///     (func (export "call_present") (param i32 i32)
    ///       (call $present (local.get 0) (local.get 1)))
    ///     (func (export "call_export") (param i32 i32)
    ///       (call $export (local.get 0) (local.get 1))))
    /// It forwards (ptr,len) straight to the host imports, exactly like the guest
    /// would. Embedded as base64 so the test is self-contained.
    private static let fixtureBase64 =
        "AGFzbQEAAAABDwNgAn9/AGABfwF/YAF/AAI5AgVwYXRjaBdwcmVzZW50X2RvY3VtZW50X3BpY2tlcgAABXBhdGNoD2V4cG9ydF9kb2N1bWVudAAAAwUEAQIAAAUDAQABBgcBfwFBgAgLB0MFBm1lbW9yeQIADHBhdGNoX21hbGxvYwACCnBhdGNoX2ZyZWUAAwxjYWxsX3ByZXNlbnQABAtjYWxsX2V4cG9ydAAFCi4EFwEBfyMAIQEjACAAakEHakF4cSQAIAELAgALCAAgACABEAALCAAgACABEAEL"

    private func fixtureBytes() throws -> [UInt8] {
        let data = try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64))
        return [UInt8](data)
    }

    /// Build a runtime over the fixture with the given bridge installed.
    private func makeRuntime(_ bridge: DocumentPickerBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(bridge)
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    func testPresentDispatchDecodesArgsAndInvokesHandler() throws {
        let spy = PickerSpy()
        let rt = try makeRuntime(DocumentPickerBridge(
            present: { req in spy.recordPresent(req) },
            export: { _ in }))

        let json = #"{"mode":"import","types":["public.json"]}"#
        let (ptr, len) = try rt.writeBuffer([UInt8](json.utf8))
        _ = try rt.invoke("call_present", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.presented.count, 1)
        XCTAssertEqual(spy.presented.first?.mode, "import")
        XCTAssertEqual(spy.presented.first?.types, ["public.json"])
        XCTAssertTrue(spy.exported.isEmpty, "present must not invoke the export handler")
    }

    func testPresentDispatchInvalidJSONDoesNotFire() throws {
        // Invalid JSON → parsePicker returns nil → handler is NOT invoked
        // (the call still returns cleanly, never throwing back into the guest).
        let spy = PickerSpy()
        let rt = try makeRuntime(DocumentPickerBridge(
            present: { req in spy.recordPresent(req) },
            export: { _ in }))

        let (ptr, len) = try rt.writeBuffer([UInt8]("garbage".utf8))
        _ = try rt.invoke("call_present", [.i32(ptr), .i32(len)])

        XCTAssertTrue(spy.presented.isEmpty, "invalid JSON must not reach the present handler")
    }

    func testExportDispatchDecodesArgsAndBase64() throws {
        let spy = PickerSpy()
        let rt = try makeRuntime(DocumentPickerBridge(
            present: { _ in },
            export: { req in spy.recordExport(req) }))

        let payload = "exported bytes 🎉"
        let b64 = Data(payload.utf8).base64EncodedString()
        let json = #"{"filename":"report.json","data_base64":"\#(b64)"}"#
        let (ptr, len) = try rt.writeBuffer([UInt8](json.utf8))
        _ = try rt.invoke("call_export", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.exported.count, 1)
        XCTAssertEqual(spy.exported.first?.filename, "report.json")
        XCTAssertEqual(spy.exported.first?.data, Data(payload.utf8))
        XCTAssertTrue(spy.presented.isEmpty, "export must not invoke the present handler")
    }

    func testExportDispatchInvalidJSONDoesNotFire() throws {
        let spy = PickerSpy()
        let rt = try makeRuntime(DocumentPickerBridge(
            present: { _ in },
            export: { req in spy.recordExport(req) }))

        let (ptr, len) = try rt.writeBuffer([UInt8]("not json".utf8))
        _ = try rt.invoke("call_export", [.i32(ptr), .i32(len)])

        XCTAssertTrue(spy.exported.isEmpty, "invalid JSON must not reach the export handler")
    }
}

/// Thread-safe spy recording the requests the bridge handlers are invoked with.
private final class PickerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _presented: [DocumentPickerBridge.PickerRequest] = []
    private var _exported: [DocumentPickerBridge.ExportRequest] = []
    func recordPresent(_ r: DocumentPickerBridge.PickerRequest) {
        lock.lock(); _presented.append(r); lock.unlock()
    }
    func recordExport(_ r: DocumentPickerBridge.ExportRequest) {
        lock.lock(); _exported.append(r); lock.unlock()
    }
    var presented: [DocumentPickerBridge.PickerRequest] {
        lock.lock(); defer { lock.unlock() }; return _presented
    }
    var exported: [DocumentPickerBridge.ExportRequest] {
        lock.lock(); defer { lock.unlock() }; return _exported
    }
}
