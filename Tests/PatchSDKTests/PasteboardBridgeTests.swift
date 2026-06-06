import XCTest
import WasmKit
@testable import PatchSDK

/// PasteboardBridge — round-trips the three clipboard host functions
/// (`pasteboard_get_string` / `pasteboard_set_string` / `pasteboard_has_strings`)
/// through the real guest -> host bridge layer.
///
/// Per the bridge guide, the prebuilt `BridgeFixture.wasm` does NOT export
/// `call_pasteboard_*`, so this suite embeds its OWN tiny wasm fixture (compiled
/// from WAT with `wat2wasm`; bytes inlined below so the test needs no external
/// tool at run time). The fixture imports the three `patch.pasteboard_*`
/// functions and exports `call_*` wrappers + `memory`/`patch_malloc`/`patch_free`,
/// so the full `(ptr,len)` + packed-i64 marshalling path is exercised with real
/// guest memory. The native clipboard is injected as an in-memory spy
/// (`PasteboardSpy`) backed by a single `String?`.
final class PasteboardBridgeTests: XCTestCase {

    // MARK: - In-memory spy (the injected native capability)

    /// Spy clipboard backed by an in-memory string; records set() calls so the
    /// dispatch can be asserted without real UIKit.
    private final class PasteboardSpy: PasteboardProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        private(set) var setCallCount = 0

        init(initial: String? = nil) { self.value = initial }

        func getString() -> String? { lock.lock(); defer { lock.unlock() }; return value }
        func setString(_ v: String) {
            lock.lock(); value = v; setCallCount += 1; lock.unlock()
        }
        func hasStrings() -> Bool { lock.lock(); defer { lock.unlock() }; return value != nil }

        /// Read-back for assertions.
        var current: String? { lock.lock(); defer { lock.unlock() }; return value }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return setCallCount }
    }

    // MARK: - Fixture (imports patch.pasteboard_*, exports call_* wrappers)

    /// `PasteboardFixture.wasm` bytes, compiled from a hand-written WAT module
    /// (`wat2wasm` 1.0.41). Imports the three pasteboard host functions and
    /// exports `call_pasteboard_*` plus `memory`/`patch_malloc`/`patch_free`.
    private static let fixtureBytes: [UInt8] = [
        0, 97, 115, 109, 1, 0, 0, 0, 1, 23, 5, 96, 1, 127, 1, 127, 96, 0, 1, 126, 96, 2, 127, 127, 0,
        96, 0, 1, 127, 96, 1, 127, 0, 2, 92, 3, 5, 112, 97, 116, 99, 104, 21, 112, 97, 115, 116, 101,
        98, 111, 97, 114, 100, 95, 103, 101, 116, 95, 115, 116, 114, 105, 110, 103, 0, 1, 5, 112, 97,
        116, 99, 104, 21, 112, 97, 115, 116, 101, 98, 111, 97, 114, 100, 95, 115, 101, 116, 95, 115,
        116, 114, 105, 110, 103, 0, 2, 5, 112, 97, 116, 99, 104, 22, 112, 97, 115, 116, 101, 98, 111,
        97, 114, 100, 95, 104, 97, 115, 95, 115, 116, 114, 105, 110, 103, 115, 0, 3, 3, 6, 5, 0, 4, 1,
        2, 3, 5, 3, 1, 0, 2, 6, 7, 1, 127, 1, 65, 128, 8, 11, 7, 126, 6, 6, 109, 101, 109, 111, 114,
        121, 2, 0, 12, 112, 97, 116, 99, 104, 95, 109, 97, 108, 108, 111, 99, 0, 3, 10, 112, 97, 116,
        99, 104, 95, 102, 114, 101, 101, 0, 4, 26, 99, 97, 108, 108, 95, 112, 97, 115, 116, 101, 98,
        111, 97, 114, 100, 95, 103, 101, 116, 95, 115, 116, 114, 105, 110, 103, 0, 5, 26, 99, 97, 108,
        108, 95, 112, 97, 115, 116, 101, 98, 111, 97, 114, 100, 95, 115, 101, 116, 95, 115, 116, 114,
        105, 110, 103, 0, 6, 27, 99, 97, 108, 108, 95, 112, 97, 115, 116, 101, 98, 111, 97, 114, 100,
        95, 104, 97, 115, 95, 115, 116, 114, 105, 110, 103, 115, 0, 7, 10, 47, 5, 23, 1, 1, 127, 35, 0,
        33, 1, 35, 0, 32, 0, 106, 65, 7, 106, 65, 120, 113, 36, 0, 32, 1, 11, 2, 0, 11, 4, 0, 16, 0, 11,
        8, 0, 32, 0, 32, 1, 16, 1, 11, 4, 0, 16, 2, 11,
    ]

    /// Build a runtime over the pasteboard fixture with the bridge injected.
    private func makeRuntime(provider: PasteboardProviding) throws -> WASMRuntime {
        let registry = BridgeRegistry()
        registry.register(PasteboardBridge(provider: provider))
        return try WASMRuntime(bytes: Self.fixtureBytes, hostImports: registry.hostImports())
    }

    private func writeString(_ s: String, into rt: WASMRuntime) throws -> (UInt32, UInt32) {
        try rt.writeBuffer([UInt8](s.utf8))
    }

    private func readPacked(_ packed: UInt64, from rt: WASMRuntime) throws -> [UInt8] {
        if packed == 0 { return [] }
        return try rt.read(ptr: UInt32(packed >> 32), len: UInt32(packed & 0xffff_ffff))
    }

    // MARK: - Round-trip through the guest -> host bridge

    func testSetThenGetRoundTrip() throws {
        let spy = PasteboardSpy()
        let rt = try makeRuntime(provider: spy)

        // set_string("copied!") — guest passes (ptr,len), host decodes + injects.
        let (p, l) = try writeString("copied!", into: rt)
        _ = try rt.invoke("call_pasteboard_set_string", [.i32(p), .i32(l)])
        XCTAssertEqual(spy.current, "copied!")
        XCTAssertEqual(spy.calls, 1, "set must invoke the injected provider exactly once")

        // get_string() -> packed (ptr,len) of the same value.
        let res = try rt.invoke("call_pasteboard_get_string")
        let bytes = try readPacked(res[0].i64, from: rt)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "copied!")
    }

    func testGetStringReturnsZeroWhenEmpty() throws {
        let spy = PasteboardSpy(initial: nil)
        let rt = try makeRuntime(provider: spy)

        let res = try rt.invoke("call_pasteboard_get_string")
        XCTAssertEqual(res[0].i64, 0, "no clipboard string -> packed 0 (nil)")
    }

    func testHasStringsTracksState() throws {
        let spy = PasteboardSpy(initial: nil)
        let rt = try makeRuntime(provider: spy)

        // Empty -> 0.
        XCTAssertEqual(try rt.invoke("call_pasteboard_has_strings")[0].i32, 0)

        // After a set -> 1.
        let (p, l) = try writeString("now present", into: rt)
        _ = try rt.invoke("call_pasteboard_set_string", [.i32(p), .i32(l)])
        XCTAssertEqual(try rt.invoke("call_pasteboard_has_strings")[0].i32, 1)
    }

    func testGetReadsPrePopulatedClipboard() throws {
        let spy = PasteboardSpy(initial: "from elsewhere")
        let rt = try makeRuntime(provider: spy)

        XCTAssertEqual(try rt.invoke("call_pasteboard_has_strings")[0].i32, 1)
        let res = try rt.invoke("call_pasteboard_get_string")
        let bytes = try readPacked(res[0].i64, from: rt)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "from elsewhere")
    }

    func testUnicodeRoundTrip() throws {
        let spy = PasteboardSpy()
        let rt = try makeRuntime(provider: spy)

        let value = "héllo 世界 🚀"
        let (p, l) = try writeString(value, into: rt)
        _ = try rt.invoke("call_pasteboard_set_string", [.i32(p), .i32(l)])
        XCTAssertEqual(spy.current, value)

        let res = try rt.invoke("call_pasteboard_get_string")
        XCTAssertEqual(String(decoding: try readPacked(res[0].i64, from: rt), as: UTF8.self), value)
    }

    // MARK: - Spy semantics (direct)

    func testSpyProviderSemantics() {
        let spy = PasteboardSpy()
        XCTAssertNil(spy.getString())
        XCTAssertFalse(spy.hasStrings())

        spy.setString("x")
        XCTAssertEqual(spy.getString(), "x")
        XCTAssertTrue(spy.hasStrings())
        XCTAssertEqual(spy.setCallCount, 1)
    }

    // MARK: - Registration wiring builds without error

    func testBridgeRegistersWithoutError() throws {
        let registry = BridgeRegistry()
        registry.register(PasteboardBridge(provider: PasteboardSpy()))
        XCTAssertNotNil(registry.hostImports())
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.fixtureBytes,
                                         hostImports: registry.hostImports()))
    }

    func testBridgeModuleNamespace() {
        XCTAssertEqual(PasteboardBridge(provider: PasteboardSpy()).module, "patch")
    }
}
