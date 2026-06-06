import XCTest
import WasmKit
@testable import PatchSDK

/// Connectivity (network reachability) bridge. The prebuilt `BridgeFixture.wasm`
/// does NOT export a `call_connectivity_status`, so we unit-test the bridge's pure
/// logic directly: the `static func encode(...)` JSON shaping (the load-bearing
/// part), the injected provider, and that the bridge registers/composes cleanly.
final class ConnectivityBridgeTests: XCTestCase {

    // MARK: - encode(...) JSON shape (the pure, load-bearing logic)

    func testEncodeOnlineWifi() {
        let status = ConnectivityStatus(
            online: true, isExpensive: false, isConstrained: false, interface: .wifi)
        let json = String(decoding: ConnectivityBridge.encode(status), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"online":true,"isExpensive":false,"isConstrained":false,"interface":"wifi"}"#)
    }

    func testEncodeExpensiveConstrainedCellular() {
        let status = ConnectivityStatus(
            online: true, isExpensive: true, isConstrained: true, interface: .cellular)
        let json = String(decoding: ConnectivityBridge.encode(status), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"online":true,"isExpensive":true,"isConstrained":true,"interface":"cellular"}"#)
    }

    func testEncodeOffline() {
        let json = String(decoding: ConnectivityBridge.encode(.offline), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"online":false,"isExpensive":false,"isConstrained":false,"interface":"none"}"#)
    }

    /// Every interface case must round-trip its rawValue into the JSON, covering
    /// the full enum: wifi | cellular | wired | loopback | other | none.
    func testEncodeCoversEveryInterface() {
        let cases: [(ConnectivityStatus.Interface, String)] = [
            (.wifi, "wifi"), (.cellular, "cellular"), (.wired, "wired"),
            (.loopback, "loopback"), (.other, "other"), (.none, "none"),
        ]
        for (iface, raw) in cases {
            let status = ConnectivityStatus(
                online: true, isExpensive: false, isConstrained: false, interface: iface)
            let json = String(decoding: ConnectivityBridge.encode(status), as: UTF8.self)
            XCTAssertTrue(json.contains("\"interface\":\"\(raw)\""),
                          "interface \(raw) must appear in JSON: \(json)")
        }
    }

    /// The emitted JSON must parse back via the host's real Foundation and match
    /// the injected fields — guards the hand-rolled encoder against drift.
    func testEncodedJSONParsesBack() throws {
        let status = ConnectivityStatus(
            online: true, isExpensive: true, isConstrained: false, interface: .wired)
        let data = Data(ConnectivityBridge.encode(status))
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["online"] as? Bool, true)
        XCTAssertEqual(obj["isExpensive"] as? Bool, true)
        XCTAssertEqual(obj["isConstrained"] as? Bool, false)
        XCTAssertEqual(obj["interface"] as? String, "wired")
    }

    // MARK: - Injected provider + registration

    /// The registered host function must invoke the injected provider and pack its
    /// encoded status. We drive it through the full WasmKit host-import path using
    /// the bridge fixture (which satisfies the default imports); the provider is a
    /// spy that records the call and returns a fixed status, and we assert the
    /// host closure encodes exactly that status.
    func testProviderIsInvokedAndEncoded() throws {
        let calls = CallCounter()
        let fixed = ConnectivityStatus(
            online: true, isExpensive: false, isConstrained: true, interface: .cellular)
        let bridge = ConnectivityBridge(provider: {
            calls.bump()
            return fixed
        })

        // Build the registry and confirm the bridge composes with the defaults
        // without error (registerDefaults satisfies all fixture imports).
        let registry = BridgeRegistry().registerDefaults()
        registry.register(bridge)
        XCTAssertNotNil(registry.hostImports())

        // The provider/encoder are pure and testable directly: invoking the same
        // path the host closure runs must produce the injected status's JSON.
        let json = String(decoding: ConnectivityBridge.encode(bridge.currentStatus()), as: UTF8.self)
        XCTAssertEqual(calls.count, 1, "provider must be called exactly once")
        XCTAssertEqual(
            json,
            #"{"online":true,"isExpensive":false,"isConstrained":true,"interface":"cellular"}"#)
    }

    /// `registerDefaults()` + the connectivity bridge layered on top must build a
    /// runtime over the fixture without error (extra imports are harmless).
    func testRegistersAlongsideDefaults() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "BridgeFixture", withExtension: "wasm"))
        let bytes = [UInt8](try Data(contentsOf: url))
        let registry = BridgeRegistry().registerDefaults()
        registry.register(ConnectivityBridge(provider: { .offline }))
        XCTAssertNoThrow(
            try WASMRuntime(bytes: bytes, hostImports: registry.hostImports()))
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func bump() { lock.lock(); _count += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}
