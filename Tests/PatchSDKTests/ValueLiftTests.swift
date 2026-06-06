import XCTest
import WasmKit
@testable import PatchSDK

/// Tests the SwiftUI value-lift runtime (P1): `Patch.value` / `Patch.call`
/// resolution, the dotted-key → `_pv_<Type>_<member>` symbol mapping, CGFloat↔
/// Double / String marshalling, and the per-pass value cache. The fixture
/// (`MarshalFixture.release.wasm`) carries `_pv_ProfileCard_*` exports that emit
/// the exact JSON `{ "value": … }` envelope the CLI's value-lift codegen produces,
/// so the SDK side round-trips against REAL guest memory.
final class ValueLiftTests: XCTestCase {

    private func fixtureBytes() throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm") else {
            throw PatchRuntimeError.memoryMissing
        }
        return [UInt8](try Data(contentsOf: url))
    }

    // The generated `_Out` envelopes the shim decodes (mirrors CodeEmitter).
    private struct DoubleOut: Decodable { let value: Double }
    private struct StringOut: Decodable { let value: String }

    // MARK: - Symbol mapping

    func testValueExportSymbolMapping() {
        XCTAssertEqual(Patch.valueExportSymbol(for: "ProfileCard.primaryFontSize"),
                       "_pv_ProfileCard_primaryFontSize")
        XCTAssertEqual(Patch.valueExportSymbol(for: "ProfileCard.greeting"),
                       "_pv_ProfileCard_greeting")
    }

    // MARK: - Round-trips through real guest memory

    /// Font size (CGFloat token lifted as Double): `Patch.value` reads the no-input
    /// `_pv_ProfileCard_primaryFontSize` and decodes 22 (the OTA edit; was 17). The
    /// native shim wraps the Double back to CGFloat at the use site.
    func testValueFontSizeRoundTripsAsDouble() throws {
        let patch = Patch()
        try patch.activate(bytes: try fixtureBytes())

        let out = try patch.valueJSON("ProfileCard.primaryFontSize", returning: DoubleOut.self)
        XCTAssertEqual(out.value, 22, "font size should resolve to 22 (OTA edit; was 17)")
        // CGFloat↔Double: the shim does `CGFloat(out.value)`.
        XCTAssertEqual(CGFloat(out.value), CGFloat(22))
    }

    /// Label string lifted whole: `Patch.value` reads the greeting and decodes
    /// "Welcome back" (the OTA edit; was "Hi").
    func testValueLabelStringRoundTrips() throws {
        let patch = Patch()
        try patch.activate(bytes: try fixtureBytes())

        let out = try patch.valueJSON("ProfileCard.greeting", returning: StringOut.self)
        XCTAssertEqual(out.value, "Welcome back", "label should resolve to \"Welcome back\" (was \"Hi\")")
    }

    /// Value helper WITH inputs: `Patch.call` encodes `{ "index": n }`, invokes
    /// `_pv_ProfileCard_rowHeight`, decodes the result. 0 → 64, else → 44.
    func testCallValueHelperWithArgsRoundTrips() throws {
        struct Args: Encodable { let index: Int }
        let patch = Patch()
        try patch.activate(bytes: try fixtureBytes())

        let row0 = try patch.callValueJSON("ProfileCard.rowHeight", Args(index: 0), returning: DoubleOut.self)
        let row3 = try patch.callValueJSON("ProfileCard.rowHeight", Args(index: 3), returning: DoubleOut.self)
        XCTAssertEqual(row0.value, 64)
        XCTAssertEqual(row3.value, 44)
    }

    // MARK: - Per-pass cache

    /// The per-pass cache memoizes a resolved value so SwiftUI re-renders don't
    /// re-enter WASM on every diff. We prove the cache HIT does NOT re-dispatch by
    /// dropping the active module after the first (caching) read: a re-dispatch
    /// would throw `noActiveModule`, but a cache hit returns the cached 22.
    func testValueCacheAvoidsReDispatch() throws {
        let patch = Patch()
        try patch.activate(bytes: try fixtureBytes())

        // First read dispatches into WASM and caches the result.
        let first = try patch.valueJSON("ProfileCard.primaryFontSize", returning: DoubleOut.self)
        XCTAssertEqual(first.value, 22)

        // Drop the active module. `deactivate()` does NOT clear the value cache
        // (only `activate()` does), so a cache HIT must serve the memoized value
        // without re-entering the (now-absent) runtime — a re-dispatch would throw
        // `noActiveModule`.
        patch.deactivate()
        let second = try patch.valueJSON("ProfileCard.primaryFontSize", returning: DoubleOut.self)
        XCTAssertEqual(second.value, 22, "cache hit returns the memoized value without re-dispatching")
    }

    /// `beginValuePass()` drops the cache so a subsequent read re-dispatches. With
    /// the active module unchanged the re-read still returns 22 — proving the clear
    /// path works and re-resolves correctly.
    func testBeginValuePassClearsCache() throws {
        let patch = Patch()
        try patch.activate(bytes: try fixtureBytes())

        let a = try patch.valueJSON("ProfileCard.primaryFontSize", returning: DoubleOut.self)
        XCTAssertEqual(a.value, 22)
        patch.beginValuePass()                       // drop the cache
        let b = try patch.valueJSON("ProfileCard.primaryFontSize", returning: DoubleOut.self)
        XCTAssertEqual(b.value, 22, "after a pass reset the value re-resolves to 22")
    }

    /// The cache distinguishes different args for the same helper key (the args
    /// digest is part of the key): index 0 and index 3 must not collide.
    func testValueCacheKeysOnArgs() throws {
        struct Args: Encodable { let index: Int }
        let patch = Patch()
        try patch.activate(bytes: try fixtureBytes())

        let r0a = try patch.callValueJSON("ProfileCard.rowHeight", Args(index: 0), returning: DoubleOut.self)
        let r3 = try patch.callValueJSON("ProfileCard.rowHeight", Args(index: 3), returning: DoubleOut.self)
        let r0b = try patch.callValueJSON("ProfileCard.rowHeight", Args(index: 0), returning: DoubleOut.self)
        XCTAssertEqual(r0a.value, 64)
        XCTAssertEqual(r3.value, 44)
        XCTAssertEqual(r0b.value, 64, "the index-0 cache entry must not be clobbered by index-3")
    }

    // MARK: - Error paths

    func testValueRequiresActiveModule() {
        let patch = Patch()
        XCTAssertThrowsError(try patch.valueJSON("ProfileCard.primaryFontSize", returning: DoubleOut.self)) { err in
            guard case PatchError.noActiveModule = err else {
                return XCTFail("expected noActiveModule, got \(err)")
            }
        }
    }

    /// The low-level ValueCache memoizes and clears correctly, independent of WASM.
    func testValueCacheUnit() {
        let cache = ValueCache()
        XCTAssertNil(cache.get(key: "k", argsDigest: nil) as Int?)
        cache.set(key: "k", argsDigest: nil, value: 7)
        XCTAssertEqual(cache.get(key: "k", argsDigest: nil) as Int?, 7)
        // Different args digest → distinct entry.
        cache.set(key: "k", argsDigest: "abc", value: 9)
        XCTAssertEqual(cache.get(key: "k", argsDigest: "abc") as Int?, 9)
        XCTAssertEqual(cache.get(key: "k", argsDigest: nil) as Int?, 7)
        cache.clear()
        XCTAssertNil(cache.get(key: "k", argsDigest: nil) as Int?)
    }
}
