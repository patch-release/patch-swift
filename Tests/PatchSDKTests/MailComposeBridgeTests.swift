import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `MailComposeBridge` — the iOS mail-compose host bridge.
///
/// Two layers, per the bridge implementation guide:
///   1. `parse(_:)` — the pure JSON→`MailDraft` decode, tested directly with
///      deterministic inputs (`to` as an array, missing keys → empty/nil,
///      non-array `to` → empty, non-string elements dropped, etc.).
///   2. Dispatch — the registered `patch.compose_mail` host function decodes the
///      guest `(ptr,len)` arg and invokes the injected handler with the right
///      `MailDraft`. Driven end-to-end through WasmKit via a tiny hand-built
///      module (imports `patch.compose_mail`, exports `call_compose_mail`) so no
///      shared fixture is touched and the test runs on macOS without MessageUI.
final class MailComposeBridgeTests: XCTestCase {

    // MARK: - parse(_:) pure decode

    func testParseAllFieldsPresent() {
        let draft = MailComposeBridge.parse(
            Array(#"{"to":["a@b.com","c@d.com"],"subject":"Hi","body":"Hello there"}"#.utf8))
        XCTAssertEqual(draft.to, ["a@b.com", "c@d.com"])
        XCTAssertEqual(draft.subject, "Hi")
        XCTAssertEqual(draft.body, "Hello there")
    }

    func testParseToOnly() {
        let draft = MailComposeBridge.parse(Array(#"{"to":["only@me.com"]}"#.utf8))
        XCTAssertEqual(draft.to, ["only@me.com"])
        XCTAssertNil(draft.subject, "missing subject → nil")
        XCTAssertNil(draft.body, "missing body → nil")
    }

    func testParseMissingToYieldsEmptyArray() {
        let draft = MailComposeBridge.parse(Array(#"{"subject":"S","body":"B"}"#.utf8))
        XCTAssertEqual(draft.to, [], "missing `to` key → empty array")
        XCTAssertEqual(draft.subject, "S")
        XCTAssertEqual(draft.body, "B")
    }

    func testParseEmptyObjectAllDefaults() {
        let draft = MailComposeBridge.parse(Array("{}".utf8))
        XCTAssertEqual(draft.to, [])
        XCTAssertNil(draft.subject)
        XCTAssertNil(draft.body)
    }

    func testParseNonArrayToYieldsEmpty() {
        // A `to` that is a bare string (not an array) → empty recipient list.
        let draft = MailComposeBridge.parse(
            Array(#"{"to":"single@x.com","subject":"S"}"#.utf8))
        XCTAssertEqual(draft.to, [], "non-array `to` → empty")
        XCTAssertEqual(draft.subject, "S")
    }

    func testParseToWithNonStringElementsDropped() {
        // Non-string array elements (numbers, objects, null) are dropped; the
        // string elements are preserved in order.
        let draft = MailComposeBridge.parse(
            Array(#"{"to":["keep@x.com",42,{"nested":true},null,"also@y.com"]}"#.utf8))
        XCTAssertEqual(draft.to, ["keep@x.com", "also@y.com"])
    }

    func testParseNonStringSubjectAndBodyTreatedAsNil() {
        let draft = MailComposeBridge.parse(
            Array(#"{"to":["a@b.com"],"subject":99,"body":{"x":1}}"#.utf8))
        XCTAssertEqual(draft.to, ["a@b.com"])
        XCTAssertNil(draft.subject, "non-string subject → nil")
        XCTAssertNil(draft.body, "non-string body → nil")
    }

    func testParseInvalidJSONAllDefaults() {
        let draft = MailComposeBridge.parse(Array("not json at all {".utf8))
        XCTAssertEqual(draft.to, [])
        XCTAssertNil(draft.subject)
        XCTAssertNil(draft.body)
    }

    func testParseNonObjectJSONAllDefaults() {
        // A top-level array (valid JSON, wrong shape) → all defaults.
        let draft = MailComposeBridge.parse(Array(#"["to","subject"]"#.utf8))
        XCTAssertEqual(draft.to, [])
        XCTAssertNil(draft.subject)
        XCTAssertNil(draft.body)
    }

    func testParseEmptyBytesAllDefaults() {
        let draft = MailComposeBridge.parse([])
        XCTAssertEqual(draft.to, [])
        XCTAssertNil(draft.subject)
        XCTAssertNil(draft.body)
    }

    func testParsePreservesUnicodeAndEmptyStrings() {
        let draft = MailComposeBridge.parse(
            Array(#"{"to":["café@é.com"],"subject":"","body":"níce 🎉"}"#.utf8))
        XCTAssertEqual(draft.to, ["café@é.com"])
        XCTAssertEqual(draft.subject, "", "explicit empty string is preserved (not nil)")
        XCTAssertEqual(draft.body, "níce 🎉")
    }

    func testParseEmptyToArrayStaysEmpty() {
        let draft = MailComposeBridge.parse(Array(#"{"to":[],"subject":"S"}"#.utf8))
        XCTAssertEqual(draft.to, [])
        XCTAssertEqual(draft.subject, "S")
    }

    // MARK: - Dispatch (guest -> host) through a hand-built module

    /// A minimal wasm module assembled from this WAT (via wat2wasm):
    ///   (module
    ///     (import "patch" "compose_mail" (func $compose (param i32 i32)))
    ///     (memory (export "memory") 1)
    ///     (global $bump (mut i32) (i32.const 1024))
    ///     (func $patch_malloc (export "patch_malloc") (param $n i32) (result i32)
    ///       (local $p i32)
    ///       (local.set $p (global.get $bump))
    ///       (global.set $bump
    ///         (i32.and (i32.add (i32.add (global.get $bump) (local.get $n)) (i32.const 7))
    ///                  (i32.const -8)))
    ///       (local.get $p))
    ///     (func $patch_free (export "patch_free") (param i32))
    ///     (func (export "call_compose_mail") (param i32 i32)
    ///       (call $compose (local.get 0) (local.get 1))))
    /// It forwards (ptr,len) straight to the host `patch.compose_mail` import,
    /// exactly like the guest would. Embedded as base64 so the test is
    /// self-contained (no shared fixture / no rebuild).
    private static let composeFixtureBase64 =
        "AGFzbQEAAAABDwNgAn9/AGABfwF/YAF/AAIWAQVwYXRjaAxjb21wb3NlX21haWwAAAMEAwECAAUDAQABBgcBfwFBgAgLBzoEBm1lbW9yeQIADHBhdGNoX21hbGxvYwABCnBhdGNoX2ZyZWUAAhFjYWxsX2NvbXBvc2VfbWFpbAADCiUDFwEBfyMAIQEjACAAakEHakF4cSQAIAELAgALCAAgACABEAAL"

    private func composeFixtureBytes() throws -> [UInt8] {
        let data = try XCTUnwrap(Data(base64Encoded: Self.composeFixtureBase64))
        return [UInt8](data)
    }

    /// Build a runtime over the compose fixture with the given bridge installed.
    private func makeRuntime(_ bridge: MailComposeBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(bridge)
        return try WASMRuntime(bytes: try composeFixtureBytes(), hostImports: registry.hostImports())
    }

    func testDispatchDecodesArgsAndInvokesHandler() throws {
        let spy = MailSpy()
        let rt = try makeRuntime(MailComposeBridge(compose: { draft in spy.record(draft) }))

        let json = #"{"to":["x@y.com","z@w.com"],"subject":"Hey","body":"Body text"}"#
        let (ptr, len) = try rt.writeBuffer([UInt8](json.utf8))
        _ = try rt.invoke("call_compose_mail", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.to, ["x@y.com", "z@w.com"])
        XCTAssertEqual(spy.calls.first?.subject, "Hey")
        XCTAssertEqual(spy.calls.first?.body, "Body text")
    }

    func testDispatchToOnlyPassesNilSubjectAndBody() throws {
        let spy = MailSpy()
        let rt = try makeRuntime(MailComposeBridge(compose: { draft in spy.record(draft) }))

        let (ptr, len) = try rt.writeBuffer([UInt8](#"{"to":["only@me.com"]}"#.utf8))
        _ = try rt.invoke("call_compose_mail", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.to, ["only@me.com"])
        XCTAssertNil(spy.calls.first?.subject)
        XCTAssertNil(spy.calls.first?.body)
    }

    func testDispatchInvalidJSONStillFiresWithDefaults() throws {
        // Fire-and-forget: even garbage input invokes the handler (with an empty
        // draft), never throwing back into the guest.
        let spy = MailSpy()
        let rt = try makeRuntime(MailComposeBridge(compose: { draft in spy.record(draft) }))

        let (ptr, len) = try rt.writeBuffer([UInt8]("garbage".utf8))
        _ = try rt.invoke("call_compose_mail", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.to, [])
        XCTAssertNil(spy.calls.first?.subject)
        XCTAssertNil(spy.calls.first?.body)
    }
}

/// Thread-safe spy recording the `MailDraft` the bridge handler is invoked with.
private final class MailSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [MailDraft] = []
    func record(_ draft: MailDraft) {
        lock.lock(); _calls.append(draft); lock.unlock()
    }
    var calls: [MailDraft] { lock.lock(); defer { lock.unlock() }; return _calls }
}
