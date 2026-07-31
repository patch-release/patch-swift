// SPDX-License-Identifier: MIT

import XCTest
@testable import PatchSDK
import WasmKit

/// Regex host-bridge round-trips through executing WASM — the guest -> host -> real
/// ICU `NSRegularExpression` -> value path the CLI's FusionRewriter routes
/// `String.range(of:options:.regularExpression)` / `replacingOccurrences(...)` and the
/// bare `NSRegularExpression(pattern:)` member forms onto.
///
/// Like the other bridge suites, this drives `RegexFixture.wasm` (hand-written WAT,
/// imports patch_host.regex_test / regex_capture / regex_count / regex_replace, exports
/// memory/patch_malloc/patch_free + call_* trampolines), so the FULL bridge path is
/// exercised through WasmKit, not just the static helper.
final class RegexBridgeTests: XCTestCase {

    private func fixtureBytes() throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "RegexFixture", withExtension: "wasm"))
        return [UInt8](try Data(contentsOf: url))
    }

    private func makeRuntime() throws -> WASMRuntime {
        // FoundationBridge serves all four regex host fns under patch_host.
        let registry = BridgeRegistry().registerDefaults()
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    private func write(_ s: String, into rt: WASMRuntime) throws -> (UInt32, UInt32) {
        try rt.writeBuffer([UInt8](s.utf8))
    }
    private func readPacked(_ packed: UInt64, from rt: WASMRuntime) throws -> String {
        if packed == 0 { return "" }
        let bytes = try rt.read(ptr: UInt32(packed >> 32), len: UInt32(packed & 0xffff_ffff))
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - regex_test (the validation form)

    func testRegexTestRoundTrip() throws {
        let rt = try makeRuntime()
        let (sp, sl) = try write("user@example.com", into: rt)
        let (pp, pl) = try write("^[^@]+@[^@]+\\.[^@]+$", into: rt)
        let r = try rt.invoke("call_test", [.i32(sp), .i32(sl), .i32(pp), .i32(pl)])
        XCTAssertEqual(r[0].i32, 1, "a valid email must match through the bridge")

        let (sp2, sl2) = try write("nope", into: rt)
        let r2 = try rt.invoke("call_test", [.i32(sp2), .i32(sl2), .i32(pp), .i32(pl)])
        XCTAssertEqual(r2[0].i32, 0, "a non-email must not match")
    }

    // MARK: - regex_capture (capture-group extraction)

    func testRegexCaptureRoundTrip() throws {
        let rt = try makeRuntime()
        let (sp, sl) = try write("order ABC-1234 ships", into: rt)
        let (pp, pl) = try write("([A-Z]{3})-([0-9]{4})", into: rt)
        // Group 0 = whole match.
        let g0 = try rt.invoke("call_capture", [.i32(sp), .i32(sl), .i32(pp), .i32(pl), .i32(0)])
        XCTAssertEqual(try readPacked(g0[0].i64, from: rt), "ABC-1234")
        // Group 1 / 2 = the captures.
        let g1 = try rt.invoke("call_capture", [.i32(sp), .i32(sl), .i32(pp), .i32(pl), .i32(1)])
        XCTAssertEqual(try readPacked(g1[0].i64, from: rt), "ABC")
        let g2 = try rt.invoke("call_capture", [.i32(sp), .i32(sl), .i32(pp), .i32(pl), .i32(2)])
        XCTAssertEqual(try readPacked(g2[0].i64, from: rt), "1234")
        // No match → 0-packed (nil).
        let (np, nl) = try write("no codes here", into: rt)
        let none = try rt.invoke("call_capture", [.i32(np), .i32(nl), .i32(pp), .i32(pl), .i32(0)])
        XCTAssertEqual(none[0].i64, 0, "no match → 0-packed nil")
    }

    // MARK: - regex_count

    func testRegexCountRoundTrip() throws {
        let rt = try makeRuntime()
        let (sp, sl) = try write("a1 b22 c333", into: rt)
        let (pp, pl) = try write("[0-9]+", into: rt)
        let r = try rt.invoke("call_count", [.i32(sp), .i32(sl), .i32(pp), .i32(pl)])
        XCTAssertEqual(r[0].i32, 3, "three digit groups matched through the bridge")
    }

    // MARK: - regex_replace (ICU template replace)

    func testRegexReplaceRoundTrip() throws {
        let rt = try makeRuntime()
        let (sp, sl) = try write("a1 b22 c333", into: rt)
        let (pp, pl) = try write("[0-9]+", into: rt)
        let (tp, tl) = try write("#", into: rt)
        let r = try rt.invoke("call_replace", [.i32(sp), .i32(sl), .i32(pp), .i32(pl), .i32(tp), .i32(tl)])
        XCTAssertEqual(try readPacked(r[0].i64, from: rt), "a# b# c#")
    }

    func testRegexReplaceTemplateBackReference() throws {
        let rt = try makeRuntime()
        let (sp, sl) = try write("John Smith", into: rt)
        let (pp, pl) = try write("(\\w+) (\\w+)", into: rt)
        let (tp, tl) = try write("$2, $1", into: rt)
        let r = try rt.invoke("call_replace", [.i32(sp), .i32(sl), .i32(pp), .i32(pl), .i32(tp), .i32(tl)])
        XCTAssertEqual(try readPacked(r[0].i64, from: rt), "Smith, John",
                       "ICU `$1`/`$2` back-references resolve through the bridge")
    }

    // MARK: - served-by-defaults

    /// The fixture instantiates cleanly against `registerDefaults()` — i.e. all four
    /// regex imports are served out of the box (FoundationBridge is in the defaults).
    func testFixtureInstantiatesAgainstRegisterDefaults() throws {
        let registry = BridgeRegistry().registerDefaults()
        XCTAssertNoThrow(try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports()),
                         "registerDefaults() must serve regex_test/capture/count/replace")
    }
}
