import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `ContactsBridge` — the Contacts-framework host bridge.
///
/// Two layers, per the bridge implementation guide:
///   1. `parse(_:)` — the pure JSON→`ContactSpec` decode, tested directly with
///      deterministic inputs (valid, name-only, empty/no-name → nil, non-string
///      values, invalid JSON, unicode, etc.).
///   2. Dispatch — the registered `patch.contact_add` / `patch.contacts_count`
///      host functions, driven end-to-end through WasmKit via a tiny hand-built
///      module (imports both host functions, exports `call_contact_add` /
///      `call_contacts_count`). The native Contacts capability is injected as
///      spies, so the whole suite runs on macOS without the Contacts framework.
final class ContactsBridgeTests: XCTestCase {

    // MARK: - parse(_:) pure decode

    func testParseAllFieldsPresent() {
        let spec = ContactsBridge.parse(Array(#"""
        {"given":"Ada","family":"Lovelace","phone":"+15551234567","email":"ada@example.com"}
        """#.utf8))
        XCTAssertEqual(spec, ContactSpec(given: "Ada", family: "Lovelace",
                                         phone: "+15551234567", email: "ada@example.com"))
    }

    func testParseGivenNameOnly() {
        let spec = ContactsBridge.parse(Array(#"{"given":"Grace"}"#.utf8))
        XCTAssertEqual(spec, ContactSpec(given: "Grace"))
    }

    func testParseFamilyNameOnly() {
        let spec = ContactsBridge.parse(Array(#"{"family":"Hopper"}"#.utf8))
        XCTAssertEqual(spec, ContactSpec(family: "Hopper"))
    }

    func testParseNameWithPhoneNoEmail() {
        let spec = ContactsBridge.parse(Array(#"{"given":"Alan","phone":"+1800"}"#.utf8))
        XCTAssertEqual(spec, ContactSpec(given: "Alan", phone: "+1800"))
        XCTAssertNil(spec?.email)
    }

    func testParseEmptyObjectIsNil() {
        // No name at all → not a valid contact → nil.
        XCTAssertNil(ContactsBridge.parse(Array("{}".utf8)))
    }

    func testParseNoNameButOtherFieldsIsNil() {
        // phone/email present but neither given nor family → still nil.
        XCTAssertNil(ContactsBridge.parse(
            Array(#"{"phone":"+15550000","email":"x@y.z"}"#.utf8)))
    }

    func testParseEmptyNameStringsTreatedAsAbsent() {
        // Explicit empty-string names count as no name → nil.
        XCTAssertNil(ContactsBridge.parse(Array(#"{"given":"","family":""}"#.utf8)))
    }

    func testParseNonStringNamesTreatedAsAbsent() {
        // Numeric / object name values must decode as absent (not crash) → nil.
        XCTAssertNil(ContactsBridge.parse(
            Array(#"{"given":42,"family":{"nested":true}}"#.utf8)))
    }

    func testParseNonStringExtraFieldsDropped() {
        // Valid name, but phone/email are non-strings → dropped to nil.
        let spec = ContactsBridge.parse(
            Array(#"{"given":"Ada","phone":123,"email":null}"#.utf8))
        XCTAssertEqual(spec, ContactSpec(given: "Ada"))
    }

    func testParseEmptyExtraStringsTreatedAsAbsent() {
        let spec = ContactsBridge.parse(
            Array(#"{"family":"Turing","phone":"","email":""}"#.utf8))
        XCTAssertEqual(spec, ContactSpec(family: "Turing"))
        XCTAssertNil(spec?.phone)
        XCTAssertNil(spec?.email)
    }

    func testParsePreservesUnicode() {
        let spec = ContactsBridge.parse(
            Array(#"{"given":"José","family":"Núñez 🎉"}"#.utf8))
        XCTAssertEqual(spec, ContactSpec(given: "José", family: "Núñez 🎉"))
    }

    func testParseInvalidJSONIsNil() {
        XCTAssertNil(ContactsBridge.parse(Array("not json at all {".utf8)))
    }

    func testParseNonObjectJSONIsNil() {
        // Top-level array is valid JSON but the wrong shape → nil.
        XCTAssertNil(ContactsBridge.parse(Array(#"["given","family"]"#.utf8)))
    }

    func testParseEmptyBytesIsNil() {
        XCTAssertNil(ContactsBridge.parse([]))
    }

    // MARK: - Inline fixture (no bundled resource, no shared-file edits)

    /// `ContactsFixture.wasm` (222 bytes), compiled from a hand-written `.wat`:
    ///   (import "patch" "contacts_count" (func (result i32)))
    ///   (import "patch" "contact_add"    (func (param i32 i32) (result i32)))
    ///   exports: memory, patch_malloc (bump allocator), patch_free,
    ///            call_contacts_count, call_contact_add
    /// The callers forward straight to the host imports — exactly like the guest
    /// would — so the test drives the real `register(...)` dispatch on macOS
    /// without touching the shared BridgeFixture or the Contacts framework.
    private static let fixtureBase64 = """
    AGFzbQEAAAABFARgAAF/YAJ/fwF/YAF/AX9gAX8AAiwCBXBhdGNoDmNvbnRhY3RzX2NvdW50AAAF\
    cGF0Y2gLY29udGFjdF9hZGQAAQMFBAIDAAEFAwEAAQYHAX8BQYAICwdPBQZtZW1vcnkCAAxwYXRj\
    aF9tYWxsb2MAAgpwYXRjaF9mcmVlAAMTY2FsbF9jb250YWN0c19jb3VudAAEEGNhbGxfY29udGFj\
    dF9hZGQABQoqBBcBAX8jACEBIwAgAEEHampBeHEkACABCwIACwQAEAALCAAgACABEAEL
    """

    private func fixtureBytes() throws -> [UInt8] {
        let data = try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64,
                                      options: .ignoreUnknownCharacters))
        return [UInt8](data)
    }

    /// Build a runtime over the inline fixture with the given bridge installed.
    private func makeRuntime(_ bridge: ContactsBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(bridge)
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    /// A bridge whose `add` records the decoded spec into `spy` and returns
    /// `result`; whose `count` returns `count`.
    private func bridge(addResult: Bool, count: Int32, spy: SpecSpy) -> ContactsBridge {
        ContactsBridge(
            add: { spec in spy.record(spec); return addResult },
            count: { count })
    }

    // MARK: - contact_add: decode + dispatch + i32 result encoding

    func testContactAddDecodesSpecAndReturnsOneOnSuccess() throws {
        let spy = SpecSpy()
        let rt = try makeRuntime(bridge(addResult: true, count: 0, spy: spy))

        let json = #"{"given":"Ada","family":"Lovelace","phone":"+1555","email":"a@b.c"}"#
        let (ptr, len) = try rt.writeBuffer([UInt8](json.utf8))
        let res = try rt.invoke("call_contact_add", [.i32(ptr), .i32(len)])

        XCTAssertEqual(Int32(bitPattern: res[0].i32), 1, "success encodes as 1")
        XCTAssertEqual(spy.specs.count, 1)
        XCTAssertEqual(spy.specs.first,
                       ContactSpec(given: "Ada", family: "Lovelace",
                                   phone: "+1555", email: "a@b.c"))
    }

    func testContactAddReturnsZeroWhenInjectedAddFails() throws {
        let spy = SpecSpy()
        let rt = try makeRuntime(bridge(addResult: false, count: 0, spy: spy))

        let (ptr, len) = try rt.writeBuffer([UInt8](#"{"given":"Bob"}"#.utf8))
        let res = try rt.invoke("call_contact_add", [.i32(ptr), .i32(len)])

        XCTAssertEqual(Int32(bitPattern: res[0].i32), 0, "save failure encodes as 0")
        XCTAssertEqual(spy.specs.count, 1, "add is still invoked; it simply returned false")
    }

    func testContactAddInvalidJSONReturnsZeroAndDoesNotDispatch() throws {
        let spy = SpecSpy()
        // add would return true, but parse fails first → 0, no dispatch.
        let rt = try makeRuntime(bridge(addResult: true, count: 0, spy: spy))

        let (ptr, len) = try rt.writeBuffer([UInt8]("garbage".utf8))
        let res = try rt.invoke("call_contact_add", [.i32(ptr), .i32(len)])

        XCTAssertEqual(Int32(bitPattern: res[0].i32), 0, "unparseable input → 0")
        XCTAssertTrue(spy.specs.isEmpty, "the injected add must not be invoked on bad input")
    }

    func testContactAddNoNameReturnsZeroAndDoesNotDispatch() throws {
        let spy = SpecSpy()
        let rt = try makeRuntime(bridge(addResult: true, count: 0, spy: spy))

        let (ptr, len) = try rt.writeBuffer([UInt8](#"{"phone":"+15550000"}"#.utf8))
        let res = try rt.invoke("call_contact_add", [.i32(ptr), .i32(len)])

        XCTAssertEqual(Int32(bitPattern: res[0].i32), 0, "no name → 0")
        XCTAssertTrue(spy.specs.isEmpty, "no-name payload must not reach the injected add")
    }

    // MARK: - contacts_count: dispatch + i32 result encoding

    func testContactsCountReturnsInjectedValue() throws {
        let spy = SpecSpy()
        let rt = try makeRuntime(bridge(addResult: true, count: 42, spy: spy))
        let res = try rt.invoke("call_contacts_count")
        XCTAssertEqual(Int32(bitPattern: res[0].i32), 42)
    }

    func testContactsCountZeroWhenDenied() throws {
        let spy = SpecSpy()
        let rt = try makeRuntime(bridge(addResult: true, count: 0, spy: spy))
        let res = try rt.invoke("call_contacts_count")
        XCTAssertEqual(Int32(bitPattern: res[0].i32), 0, "denied/unavailable encodes as 0")
    }

    // MARK: - Module namespace + registry composition

    func testModuleNamespace() {
        XCTAssertEqual(ContactsBridge(add: { _ in true }, count: { 0 }).module, "patch")
    }

    func testRegistersAlongsideDefaultsWithoutConflict() throws {
        // Installs cleanly alongside the default bridge set (no name clashes;
        // module namespace is "patch").
        let registry = BridgeRegistry().registerDefaults()
        registry.register(ContactsBridge(add: { _ in true }, count: { 7 }))
        XCTAssertNoThrow(try WASMRuntime(bytes: try fixtureBytes(),
                                         hostImports: registry.hostImports()))
    }
}

/// Thread-safe spy recording the `ContactSpec`s the bridge's add closure receives.
private final class SpecSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _specs: [ContactSpec] = []
    func record(_ spec: ContactSpec) { lock.lock(); _specs.append(spec); lock.unlock() }
    var specs: [ContactSpec] { lock.lock(); defer { lock.unlock() }; return _specs }
}
