import XCTest
import Foundation
import WasmKit
@testable import PatchSDK

/// DeviceInfoBridge — `patch.device_info() -> packed-i64 JSON`. The native read
/// (UIDevice/UIScreen) is iOS-only and injected as a `@Sendable () -> DeviceInfo`
/// provider, so these tests inject a FIXED `DeviceInfo` and assert the JSON the
/// guest would receive. The pure `encode(_:)` logic is tested directly (no wasm
/// instance needed), and the registered host function is exercised through a spy
/// provider to prove the dispatch path.
final class DeviceInfoBridgeTests: XCTestCase {

    private func fixture() -> DeviceInfo {
        DeviceInfo(
            model: "iPhone15,3",
            systemName: "iOS",
            systemVersion: "17.4",
            name: "Jane's iPhone",
            idiom: "phone",
            screenWidth: 390,
            screenHeight: 844,
            scale: 3.0
        )
    }

    // MARK: - encode: exact JSON shape

    func testEncodeProducesExactJSON() {
        let json = String(decoding: DeviceInfoBridge.encode(fixture()), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"model":"iPhone15,3","systemName":"iOS","systemVersion":"17.4","name":"Jane's iPhone","idiom":"phone","screenWidth":390,"screenHeight":844,"scale":3}"#
        )
    }

    /// The encoded bytes must parse back to a JSON object with the documented
    /// fields and values (numbers compare numerically, so 3 == 3.0).
    func testEncodeRoundTripsThroughJSONSerialization() throws {
        let bytes = DeviceInfoBridge.encode(fixture())
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
        )
        XCTAssertEqual(obj["model"] as? String, "iPhone15,3")
        XCTAssertEqual(obj["systemName"] as? String, "iOS")
        XCTAssertEqual(obj["systemVersion"] as? String, "17.4")
        XCTAssertEqual(obj["name"] as? String, "Jane's iPhone")
        XCTAssertEqual(obj["idiom"] as? String, "phone")
        XCTAssertEqual((obj["screenWidth"] as? NSNumber)?.doubleValue, 390)
        XCTAssertEqual((obj["screenHeight"] as? NSNumber)?.doubleValue, 844)
        XCTAssertEqual((obj["scale"] as? NSNumber)?.doubleValue, 3.0)
    }

    /// Fractional metrics (e.g. an iPad's 2x scale on a 1080.5pt screen) keep their
    /// exact decimal value.
    func testEncodeKeepsFractionalNumbers() throws {
        let info = DeviceInfo(
            model: "iPad13,1", systemName: "iPadOS", systemVersion: "17.0",
            name: "iPad", idiom: "pad",
            screenWidth: 820.5, screenHeight: 1180, scale: 2.0
        )
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(DeviceInfoBridge.encode(info))) as? [String: Any]
        )
        XCTAssertEqual((obj["screenWidth"] as? NSNumber)?.doubleValue, 820.5)
        XCTAssertEqual((obj["screenHeight"] as? NSNumber)?.doubleValue, 1180)
        XCTAssertEqual((obj["idiom"] as? String), "pad")
    }

    /// Strings containing JSON-significant characters must be escaped so the output
    /// stays valid JSON (a quote in the device name is the realistic case).
    func testEncodeEscapesSpecialCharactersInStrings() throws {
        let tricky = "Tab\tand \"quote\" and \\slash"
        let info = DeviceInfo(
            model: "x", systemName: "iOS", systemVersion: "1.0",
            name: tricky, idiom: "phone",
            screenWidth: 100, screenHeight: 200, scale: 1.0
        )
        let bytes = DeviceInfoBridge.encode(info)
        // Must still parse, and the name must survive the escape round-trip.
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
        )
        XCTAssertEqual(obj["name"] as? String, tricky)
    }

    // MARK: - registered host function dispatches through the injected provider

    /// The registered `device_info` host fn packs `encode(provider())`. We assert
    /// the SAME dispatch path via `snapshotPayload()` (the internal seam the host
    /// closure uses): the injected provider must be consulted, and its DeviceInfo
    /// must encode to the expected JSON — no wasm fixture / `call_device_info`
    /// export required.
    func testRegisteredFunctionUsesInjectedProvider() throws {
        let calls = CallCounter()
        let bridge = DeviceInfoBridge(provider: {
            calls.bump()
            return DeviceInfo(
                model: "iPhone15,3", systemName: "iOS", systemVersion: "17.4",
                name: "Jane's iPhone", idiom: "phone",
                screenWidth: 390, screenHeight: 844, scale: 3.0
            )
        })

        let payload = bridge.snapshotPayload()
        XCTAssertEqual(calls.count, 1, "host fn must consult the injected provider exactly once")
        XCTAssertEqual(
            String(decoding: payload, as: UTF8.self),
            #"{"model":"iPhone15,3","systemName":"iOS","systemVersion":"17.4","name":"Jane's iPhone","idiom":"phone","screenWidth":390,"screenHeight":844,"scale":3}"#
        )

        // Each call re-reads the (live, on device) snapshot.
        _ = bridge.snapshotPayload()
        XCTAssertEqual(calls.count, 2, "each device_info call re-reads the provider")

        // Registering into a real Imports set builds without throwing.
        let registry = BridgeRegistry()
        registry.register(bridge)
        XCTAssertNotNil(registry.hostImports())
    }
}

/// Thread-safe call counter for the provider spy.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func bump() { lock.lock(); _count += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}
