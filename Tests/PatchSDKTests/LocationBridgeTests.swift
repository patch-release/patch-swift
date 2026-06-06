import XCTest
import WasmKit
@testable import PatchSDK

/// Location (one-shot GPS) bridge. The prebuilt `BridgeFixture.wasm` does NOT
/// export a `call_location_current`, so we unit-test the bridge's pure logic
/// directly: the `static func encode(...)` JSON shaping (the load-bearing part),
/// the injected provider (a fixed fix + the nil/denied case), and that the
/// bridge registers/composes cleanly with the defaults.
final class LocationBridgeTests: XCTestCase {

    // MARK: - encode(...) JSON shape (the pure, load-bearing logic)

    /// A fix with integral coordinates emits bare integers (compact form).
    func testEncodeIntegralFix() {
        let fix = LocationFix(lat: 37, lng: -122, accuracy: 5, timestamp: 1_700_000_000_000)
        let json = String(decoding: try! XCTUnwrap(LocationBridge.encode(fix)), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"lat":37,"lng":-122,"accuracy":5,"timestamp":1700000000000}"#)
    }

    /// A fix with fractional coordinates round-trips its decimal form.
    func testEncodeFractionalFix() throws {
        let fix = LocationFix(
            lat: 37.3349, lng: -122.009, accuracy: 5.5, timestamp: 1_700_000_000_123)
        let json = String(decoding: try XCTUnwrap(LocationBridge.encode(fix)), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"lat":37.3349,"lng":-122.009,"accuracy":5.5,"timestamp":1700000000123}"#)
    }

    /// The nil (unavailable / denied) case encodes to nil so `packedResult`
    /// returns the `0` "no value" sentinel.
    func testEncodeNilFixIsNil() {
        XCTAssertNil(LocationBridge.encode(nil))
    }

    /// The emitted JSON must parse back via the host's real Foundation and match
    /// the injected fields — guards the hand-rolled encoder against drift.
    func testEncodedJSONParsesBack() throws {
        let fix = LocationFix(
            lat: 51.5074, lng: -0.1278, accuracy: 12.25, timestamp: 1_699_999_999_000)
        let data = Data(try XCTUnwrap(LocationBridge.encode(fix)))
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["lat"] as? Double, 51.5074)
        XCTAssertEqual(obj["lng"] as? Double, -0.1278)
        XCTAssertEqual(obj["accuracy"] as? Double, 12.25)
        XCTAssertEqual((obj["timestamp"] as? NSNumber)?.int64Value, 1_699_999_999_000)
    }

    /// Negative + zero coordinates and a zero accuracy must encode correctly
    /// (the equator / prime meridian and a perfectly-accurate stub).
    func testEncodeZeroAndNegative() throws {
        let fix = LocationFix(lat: 0, lng: 0, accuracy: 0, timestamp: 0)
        let json = String(decoding: try XCTUnwrap(LocationBridge.encode(fix)), as: UTF8.self)
        XCTAssertEqual(json, #"{"lat":0,"lng":0,"accuracy":0,"timestamp":0}"#)
    }

    /// `numberString` formats integral Doubles as bare integers, fractional as
    /// decimals, and collapses non-finite (NaN/Inf — not valid JSON) to 0.
    func testNumberStringForms() {
        XCTAssertEqual(LocationBridge.numberString(5), "5")
        XCTAssertEqual(LocationBridge.numberString(-122), "-122")
        XCTAssertEqual(LocationBridge.numberString(5.5), "5.5")
        XCTAssertEqual(LocationBridge.numberString(.nan), "0")
        XCTAssertEqual(LocationBridge.numberString(.infinity), "0")
    }

    // MARK: - Injected provider + registration

    /// The registered host path must invoke the injected provider and pack its
    /// encoded fix. The provider is a spy that records the call and returns a
    /// fixed fix; invoking the same path the host closure runs must produce that
    /// fix's JSON.
    func testProviderIsInvokedAndEncoded() {
        let calls = CallCounter()
        let fixed = LocationFix(
            lat: 37.3349, lng: -122.009, accuracy: 5, timestamp: 1_700_000_000_000)
        let bridge = LocationBridge(provider: {
            calls.bump()
            return fixed
        })

        let json = String(decoding: try! XCTUnwrap(LocationBridge.encode(bridge.currentFix())),
                          as: UTF8.self)
        XCTAssertEqual(calls.count, 1, "provider must be called exactly once")
        XCTAssertEqual(
            json,
            #"{"lat":37.3349,"lng":-122.009,"accuracy":5,"timestamp":1700000000000}"#)
    }

    /// A provider returning nil (unavailable/denied) flows through to a nil
    /// encoding, which the host packs as the `0` sentinel.
    func testNilProviderEncodesNil() {
        let bridge = LocationBridge(provider: { nil })
        XCTAssertNil(bridge.currentFix())
        XCTAssertNil(LocationBridge.encode(bridge.currentFix()))
    }

    /// `registerDefaults()` + the location bridge layered on top must build a
    /// runtime over the fixture without error (extra imports are harmless).
    func testRegistersAlongsideDefaults() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "BridgeFixture", withExtension: "wasm"))
        let bytes = [UInt8](try Data(contentsOf: url))
        let registry = BridgeRegistry().registerDefaults()
        registry.register(LocationBridge(provider: { nil }))
        XCTAssertNoThrow(
            try WASMRuntime(bytes: bytes, hostImports: registry.hostImports()))
    }

    /// The bridge composes with the defaults without error and exposes the
    /// `"patch"` module namespace expected by the registry.
    func testComposesWithDefaults() {
        let bridge = LocationBridge(provider: {
            LocationFix(lat: 1, lng: 2, accuracy: 3, timestamp: 4)
        })
        XCTAssertEqual(bridge.module, "patch")
        let registry = BridgeRegistry().registerDefaults()
        registry.register(bridge)
        XCTAssertNotNil(registry.hostImports())
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func bump() { lock.lock(); _count += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}
