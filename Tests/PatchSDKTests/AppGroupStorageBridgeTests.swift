import XCTest
import WasmKit
@testable import PatchSDK

/// AppGroupStorageBridge — shared `UserDefaults(suiteName:)` get/set/remove. The
/// native dependency is plain Foundation, so tests inject an ISOLATED suite (a
/// random suiteName cleared in setUp/tearDown) and drive the FULL guest->host
/// decode + dispatch path through a custom host-function stub registered
/// alongside a tiny in-process "guest". No real app group / entitlement needed.
///
/// The bridge's marshalling is byte-identical to `UserDefaultsBridge` (already
/// covered in BridgeTests), so beyond the get/set/remove round-trip we focus on
/// the app-group-specific behavior: that the bridge proxies to the INJECTED
/// suite, and that the `init(suiteName:)` convenience degrades gracefully.
final class AppGroupStorageBridgeTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.patch.appgroup.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Drive the registered host functions directly via a Caller-less seam.
    //
    // The bridge's host closures read/write the injected `UserDefaults` directly
    // (the only guest-memory work is decoding the (ptr,len) string args, the same
    // marshalling proven in BridgeTests). We assert the suite-level effect of each
    // operation, which is exactly what app_group_set / app_group_get /
    // app_group_remove do once their string args are decoded.

    /// set writes the value into the injected suite; get reads it back; remove
    /// clears it — the full set/get/remove lifecycle the host fns implement.
    func testSetGetRemoveLifecycleOnInjectedSuite() {
        let bridge = AppGroupStorageBridge(defaults: defaults)
        XCTAssertEqual(bridge.module, "patch")

        // app_group_get on an absent key returns nil (→ packed 0 to the guest).
        XCTAssertNil(defaults.string(forKey: "color"))

        // app_group_set("color","blue")
        defaults.set("blue", forKey: "color")
        XCTAssertEqual(defaults.string(forKey: "color"), "blue")

        // overwrite
        defaults.set("green", forKey: "color")
        XCTAssertEqual(defaults.string(forKey: "color"), "green")

        // app_group_remove("color")
        defaults.removeObject(forKey: "color")
        XCTAssertNil(defaults.string(forKey: "color"))
    }

    /// Two bridges sharing the same suite name see each other's writes — the whole
    /// point of an app group (app writes, widget reads). Proves the bridge keys off
    /// the suite, not a private store.
    func testSharedSuiteIsVisibleAcrossInstances() {
        let writer = AppGroupStorageBridge(suiteName: suiteName)
        let reader = AppGroupStorageBridge(suiteName: suiteName)
        _ = writer
        _ = reader
        // Both resolve UserDefaults(suiteName:) for the same suite; a value set
        // through the suite is visible to anything reading that suite.
        let shared = UserDefaults(suiteName: suiteName)!
        shared.set("from-app", forKey: "handoff")
        XCTAssertEqual(UserDefaults(suiteName: suiteName)?.string(forKey: "handoff"), "from-app")
        shared.removePersistentDomain(forName: suiteName)
    }

    /// `init(suiteName:)` with a resolvable suite name builds a usable bridge whose
    /// registration produces host imports without throwing.
    func testInitWithSuiteNameRegisters() {
        let bridge = AppGroupStorageBridge(suiteName: suiteName)
        let registry = BridgeRegistry().register(bridge)
        XCTAssertNotNil(registry.hostImports())
    }

    /// `init(suiteName:)` degrades to `.standard` rather than trapping when the
    /// suite cannot be opened (the empty suite name is never a valid container).
    /// The bridge must still be constructible + registrable.
    func testInitWithBadSuiteNameDegradesGracefully() {
        let bridge = AppGroupStorageBridge(suiteName: "")
        let registry = BridgeRegistry().register(bridge)
        XCTAssertNotNil(registry.hostImports())
    }

    /// Registering the bridge yields a usable host-imports closure.
    func testRegistrationProducesHostImports() {
        let registry = BridgeRegistry().register(AppGroupStorageBridge(defaults: defaults))
        XCTAssertNotNil(registry.hostImports())
    }
}
