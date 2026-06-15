import XCTest
@testable import PatchSDK
import WasmKit

/// Foundation VALUE bridge round-trips (date math / ISO8601) — the guest -> host ->
/// value path the CLI's FusionRewriter routes `Date().timeIntervalSince*` and
/// `ISO8601DateFormatter().string(from:)`/`.date(from:)` onto.
///
/// Like the other bridge suites, this embeds its OWN tiny wasm fixture (hand-written
/// WAT, compiled with `wat2wasm`, bytes inlined) that imports the three patch_host
/// value functions (`now_unix_millis` / `iso8601_format` / `iso8601_parse`) and
/// exports `memory`/`patch_malloc`/`patch_free` + `call_*` wrappers, so the FULL
/// bridge path (guest call -> FoundationBridge host fn -> real Foundation -> value
/// back into guest memory) is exercised through WasmKit, not just the static helper.
final class FoundationValueBridgeTests: XCTestCase {

    /// `DateValueFixture.wasm` bytes (wat2wasm). Imports patch_host.now_unix_millis /
    /// iso8601_format / iso8601_parse; exports memory/patch_malloc/patch_free +
    /// call_now / call_iso8601_format / call_iso8601_parse.
    private static let fixtureBytes: [UInt8] = [
        0, 97, 115, 109, 1, 0, 0, 0, 1, 25, 5, 96, 0, 1, 126, 96, 1, 126, 1, 126,
        96, 2, 127, 127, 1, 126, 96, 1, 127, 1, 127, 96, 1, 127, 0, 2, 85, 3, 10, 112,
        97, 116, 99, 104, 95, 104, 111, 115, 116, 15, 110, 111, 119, 95, 117, 110, 105, 120, 95, 109,
        105, 108, 108, 105, 115, 0, 0, 10, 112, 97, 116, 99, 104, 95, 104, 111, 115, 116, 14, 105,
        115, 111, 56, 54, 48, 49, 95, 102, 111, 114, 109, 97, 116, 0, 1, 10, 112, 97, 116, 99,
        104, 95, 104, 111, 115, 116, 13, 105, 115, 111, 56, 54, 48, 49, 95, 112, 97, 114, 115, 101,
        0, 2, 3, 6, 5, 3, 4, 0, 1, 2, 5, 3, 1, 0, 2, 6, 7, 1, 127, 1,
        65, 128, 8, 11, 7, 92, 6, 6, 109, 101, 109, 111, 114, 121, 2, 0, 12, 112, 97, 116,
        99, 104, 95, 109, 97, 108, 108, 111, 99, 0, 3, 10, 112, 97, 116, 99, 104, 95, 102, 114,
        101, 101, 0, 4, 8, 99, 97, 108, 108, 95, 110, 111, 119, 0, 5, 19, 99, 97, 108, 108,
        95, 105, 115, 111, 56, 54, 48, 49, 95, 102, 111, 114, 109, 97, 116, 0, 6, 18, 99, 97,
        108, 108, 95, 105, 115, 111, 56, 54, 48, 49, 95, 112, 97, 114, 115, 101, 0, 7, 10, 49,
        5, 23, 1, 1, 127, 35, 0, 33, 1, 35, 0, 32, 0, 106, 65, 7, 106, 65, 120, 113,
        36, 0, 32, 1, 11, 2, 0, 11, 4, 0, 16, 0, 11, 6, 0, 32, 0, 16, 1, 11,
        8, 0, 32, 0, 32, 1, 16, 2, 11,
    ]

    /// A fixed instant for determinism: 2021-01-01T00:00:00Z.
    private static let fixedMillis: Int64 = 1_609_459_200_000

    /// Build a runtime with a FIXED-clock FoundationBridge so `now_unix_millis` is
    /// deterministic, plus the ISO8601 host fns (no injectable state — pure ICU).
    private func makeRuntime() throws -> WASMRuntime {
        let registry = BridgeRegistry()
        // FoundationBridge serves all three: now_unix_millis (clock-injected here),
        // iso8601_format, iso8601_parse.
        registry.register(FoundationBridge(clock: { Date(timeIntervalSince1970: Double(Self.fixedMillis) / 1000.0) }))
        return try WASMRuntime(bytes: Self.fixtureBytes, hostImports: registry.hostImports())
    }

    private func readPacked(_ packed: UInt64, from rt: WASMRuntime) throws -> [UInt8] {
        if packed == 0 { return [] }
        return try rt.read(ptr: UInt32(packed >> 32), len: UInt32(packed & 0xffff_ffff))
    }

    // MARK: - now_unix_millis (Date().timeIntervalSince1970 bridge)

    /// `call_now()` returns the host's injected clock in millis — the value the
    /// `_patchFusionNowUnixSeconds()` shim divides by 1000 to a Double.
    func testNowUnixMillisRoundTrip() throws {
        let rt = try makeRuntime()
        let res = try rt.invoke("call_now")
        XCTAssertEqual(Int64(bitPattern: res[0].i64), Self.fixedMillis,
                       "the guest must read the shell's real clock through the bridge")
        // The shim's Double-seconds derivation matches the source semantics.
        XCTAssertEqual(Double(Self.fixedMillis) / 1000.0, 1_609_459_200.0)
    }

    // MARK: - iso8601_format (ISO8601DateFormatter().string(from:) bridge)

    func testISO8601FormatRoundTrip() throws {
        let rt = try makeRuntime()
        let res = try rt.invoke("call_iso8601_format", [.i64(UInt64(bitPattern: Self.fixedMillis))])
        let bytes = try readPacked(res[0].i64, from: rt)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "2021-01-01T00:00:00Z",
                       "fixed-format, locale-independent UTC ISO8601 string")
    }

    // MARK: - iso8601_parse (ISO8601DateFormatter().date(from:) bridge)

    func testISO8601ParseRoundTrip() throws {
        let rt = try makeRuntime()
        let s = [UInt8]("2021-01-01T00:00:00Z".utf8)
        let (p, l) = try rt.writeBuffer(s)
        let res = try rt.invoke("call_iso8601_parse", [.i32(p), .i32(l)])
        XCTAssertEqual(Int64(bitPattern: res[0].i64), Self.fixedMillis,
                       "a valid ISO8601 string parses to the same Unix millis the shim divides to a Date")
    }

    /// An unparseable string returns the INT64_MIN nil sentinel — the shim maps it to
    /// `nil`, matching `ISO8601DateFormatter().date(from:)` returning `nil`.
    func testISO8601ParseInvalidReturnsNilSentinel() throws {
        let rt = try makeRuntime()
        let s = [UInt8]("not a date".utf8)
        let (p, l) = try rt.writeBuffer(s)
        let res = try rt.invoke("call_iso8601_parse", [.i32(p), .i32(l)])
        XCTAssertEqual(Int64(bitPattern: res[0].i64), FoundationBridge.iso8601ParseNil,
                       "an unparseable ISO8601 string returns the nil sentinel (-> shim returns nil)")
    }

    /// Format then parse through the WASM bridge is an exact value round-trip — the
    /// invariant the two ISO8601 fusion shims rely on.
    func testISO8601FormatThenParseRoundTripThroughWasm() throws {
        let rt = try makeRuntime()
        let fmt = try rt.invoke("call_iso8601_format", [.i64(UInt64(bitPattern: Self.fixedMillis))])
        let str = try readPacked(fmt[0].i64, from: rt)
        let (p, l) = try rt.writeBuffer(str)
        let parsed = try rt.invoke("call_iso8601_parse", [.i32(p), .i32(l)])
        XCTAssertEqual(Int64(bitPattern: parsed[0].i64), Self.fixedMillis)
    }

    /// The fixture instantiates cleanly against `registerDefaults()` — i.e. the three
    /// value imports are served out of the box (FoundationBridge is in the defaults).
    func testFixtureInstantiatesAgainstRegisterDefaults() throws {
        let registry = BridgeRegistry().registerDefaults()
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.fixtureBytes, hostImports: registry.hostImports()),
                         "registerDefaults() must serve now_unix_millis / iso8601_format / iso8601_parse")
    }
}
