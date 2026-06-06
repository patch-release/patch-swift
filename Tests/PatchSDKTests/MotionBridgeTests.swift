import XCTest
import Foundation
import WasmKit
@testable import PatchSDK

/// MotionBridge — `patch.motion_read() -> packed-i64 JSON` (or 0 if sensors are
/// unavailable). The CoreMotion read is iOS-only and injected as a `@Sendable ()
/// -> MotionSample?` provider, so tests inject a FIXED sample (or nil) and assert
/// the JSON the guest would receive. The pure `encode(_:)` is tested directly,
/// and the dispatch path is exercised via `samplePayload()` — no wasm fixture.
final class MotionBridgeTests: XCTestCase {

    private static func fixture() -> MotionSample {
        MotionSample(accelX: 0.01, accelY: -0.98, accelZ: 0.02,
                     gyroX: 0.0, gyroY: 0.0, gyroZ: 0.0)
    }

    // MARK: - encode: exact JSON shape

    func testEncodeProducesExactJSON() {
        let json = String(decoding: MotionBridge.encode(Self.fixture()), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"accelX":0.01,"accelY":-0.98,"accelZ":0.02,"gyroX":0,"gyroY":0,"gyroZ":0}"#
        )
    }

    /// The encoded bytes parse back to a JSON object with the documented fields.
    func testEncodeRoundTripsThroughJSONSerialization() throws {
        let sample = MotionSample(accelX: 0.5, accelY: 1.0, accelZ: -0.25,
                                  gyroX: 2.5, gyroY: -3.0, gyroZ: 0.125)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(MotionBridge.encode(sample))) as? [String: Any]
        )
        XCTAssertEqual((obj["accelX"] as? NSNumber)?.doubleValue, 0.5)
        XCTAssertEqual((obj["accelY"] as? NSNumber)?.doubleValue, 1.0)
        XCTAssertEqual((obj["accelZ"] as? NSNumber)?.doubleValue, -0.25)
        XCTAssertEqual((obj["gyroX"] as? NSNumber)?.doubleValue, 2.5)
        XCTAssertEqual((obj["gyroY"] as? NSNumber)?.doubleValue, -3.0)
        XCTAssertEqual((obj["gyroZ"] as? NSNumber)?.doubleValue, 0.125)
    }

    /// Integral readings render without a fractional part (e.g. 0, not 0.0).
    func testEncodeRendersIntegralWithoutFraction() {
        let sample = MotionSample(accelX: 0, accelY: 1, accelZ: -1,
                                  gyroX: 0, gyroY: 0, gyroZ: 0)
        let json = String(decoding: MotionBridge.encode(sample), as: UTF8.self)
        XCTAssertEqual(json, #"{"accelX":0,"accelY":1,"accelZ":-1,"gyroX":0,"gyroY":0,"gyroZ":0}"#)
    }

    // MARK: - Dispatch through the injected provider

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _c = 0
        func bump() { lock.lock(); _c += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _c }
    }

    /// A live sample is consulted from the provider and encoded.
    func testSamplePayloadUsesProvider() throws {
        let calls = CallCounter()
        let sample = Self.fixture()
        let bridge = MotionBridge(provider: { calls.bump(); return sample })

        let payload = bridge.samplePayload()
        XCTAssertEqual(calls.count, 1, "provider consulted once")
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(payload), as: UTF8.self),
            #"{"accelX":0.01,"accelY":-0.98,"accelZ":0.02,"gyroX":0,"gyroY":0,"gyroZ":0}"#
        )
        _ = bridge.samplePayload()
        XCTAssertEqual(calls.count, 2, "each read re-consults the provider")
    }

    /// nil from the provider (sensors unavailable) → nil payload (→ packed 0).
    func testUnavailableSensorsYieldsNil() {
        let bridge = MotionBridge(provider: { nil })
        XCTAssertNil(bridge.samplePayload())
    }

    // MARK: - Bridge shape / registration

    func testModuleNamespaceAndRegistration() {
        let sample = Self.fixture()
        let bridge = MotionBridge(provider: { sample })
        XCTAssertEqual(bridge.module, "patch")
        XCTAssertNotNil(BridgeRegistry().register(bridge).hostImports())
    }

    #if os(iOS) || os(watchOS) || os(visionOS)
    func testDefaultInitRegisters() {
        XCTAssertNotNil(BridgeRegistry().register(MotionBridge()).hostImports())
    }
    #endif
}
