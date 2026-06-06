import XCTest
import WasmKit
@testable import PatchSDK

/// ProcessInfoBridge — `process_info()` returns a packed-i64 JSON blob of process
/// / environment facts. The prebuilt `BridgeFixture.wasm` does NOT export a
/// `call_process_info`, so we unit-test the bridge's pure logic directly: the
/// `static func encode(...)` JSON shaping (the load-bearing part), the injected
/// provider dispatch, and that the bridge composes with the defaults cleanly.
final class ProcessInfoBridgeTests: XCTestCase {

    private static let sample = ProcessFacts(
        thermalState: .fair,
        lowPowerMode: true,
        osVersion: "17.4.1",
        processorCount: 10,
        activeProcessorCount: 8,
        physicalMemory: 17_179_869_184)

    // MARK: - encode(...) JSON shape (pure, load-bearing)

    func testEncodeFixedFacts() {
        let json = String(decoding: ProcessInfoBridge.encode(Self.sample), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"thermalState":"fair","lowPowerMode":true,"osVersion":"17.4.1","processorCount":10,"activeProcessorCount":8,"physicalMemory":17179869184}"#)
    }

    func testEncodeNominalNoLowPower() {
        let facts = ProcessFacts(
            thermalState: .nominal, lowPowerMode: false, osVersion: "14.0.0",
            processorCount: 6, activeProcessorCount: 6, physicalMemory: 4_294_967_296)
        let json = String(decoding: ProcessInfoBridge.encode(facts), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"thermalState":"nominal","lowPowerMode":false,"osVersion":"14.0.0","processorCount":6,"activeProcessorCount":6,"physicalMemory":4294967296}"#)
    }

    /// Every thermal state must round-trip its rawValue into the JSON.
    func testEncodeCoversEveryThermalState() {
        let cases: [(ProcessFacts.ThermalState, String)] = [
            (.nominal, "nominal"), (.fair, "fair"), (.serious, "serious"), (.critical, "critical"),
        ]
        for (state, raw) in cases {
            let facts = ProcessFacts(
                thermalState: state, lowPowerMode: false, osVersion: "1.0.0",
                processorCount: 1, activeProcessorCount: 1, physicalMemory: 1)
            let json = String(decoding: ProcessInfoBridge.encode(facts), as: UTF8.self)
            XCTAssertTrue(json.contains("\"thermalState\":\"\(raw)\""),
                          "thermal \(raw) must appear in JSON: \(json)")
        }
    }

    /// The emitted JSON must parse back via real Foundation and match the fields.
    func testEncodedJSONParsesBack() throws {
        let data = Data(ProcessInfoBridge.encode(Self.sample))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["thermalState"] as? String, "fair")
        XCTAssertEqual(obj["lowPowerMode"] as? Bool, true)
        XCTAssertEqual(obj["osVersion"] as? String, "17.4.1")
        XCTAssertEqual(obj["processorCount"] as? Int, 10)
        XCTAssertEqual(obj["activeProcessorCount"] as? Int, 8)
        XCTAssertEqual((obj["physicalMemory"] as? NSNumber)?.uint64Value, 17_179_869_184)
    }

    // MARK: - escape(...) defensive JSON escaping

    func testEscapeLeavesNormalVersionUntouched() {
        XCTAssertEqual(ProcessInfoBridge.escape("17.4.1"), "17.4.1")
    }

    func testEscapeQuotesAndBackslashes() {
        XCTAssertEqual(ProcessInfoBridge.escape("a\"b\\c"), #"a\"b\\c"#)
        XCTAssertEqual(ProcessInfoBridge.escape("x\ny"), "x\\ny")
    }

    // MARK: - Injected provider dispatch

    func testProviderIsInvokedAndEncoded() {
        let calls = CallCounter()
        let bridge = ProcessInfoBridge(provider: {
            calls.bump()
            return Self.sample
        })
        let json = String(decoding: ProcessInfoBridge.encode(bridge.currentFacts()), as: UTF8.self)
        XCTAssertEqual(calls.count, 1, "provider must be called exactly once")
        XCTAssertTrue(json.contains("\"osVersion\":\"17.4.1\""))
    }

    // MARK: - Composition with defaults over the real fixture

    func testRegistersAlongsideDefaults() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "BridgeFixture", withExtension: "wasm"))
        let bytes = [UInt8](try Data(contentsOf: url))
        let registry = BridgeRegistry().registerDefaults()
        registry.register(ProcessInfoBridge(provider: { Self.sample }))
        XCTAssertNoThrow(try WASMRuntime(bytes: bytes, hostImports: registry.hostImports()))
    }

    #if canImport(Foundation)
    /// The real `ProcessInfo` snapshot + default init must construct and encode
    /// without throwing (values are machine-dependent, so we only assert shape).
    func testDefaultInitSnapshotEncodes() {
        let facts = ProcessInfoBridge.snapshot()
        XCTAssertGreaterThan(facts.processorCount, 0)
        let json = String(decoding: ProcessInfoBridge.encode(facts), as: UTF8.self)
        XCTAssertTrue(json.hasPrefix("{\"thermalState\":"))
        XCTAssertNoThrow(BridgeRegistry().register(ProcessInfoBridge()))
    }
    #endif
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func bump() { lock.lock(); _count += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}
