import XCTest
import WasmKit
@testable import PatchSDK

/// ScreenControlBridge — brightness (0...100 percent over the ABI) + idle-timer
/// keep-awake. The UIKit reads/writes are injected as `@Sendable` closures, so
/// tests inject spies over an in-memory store. Two layers:
///   1. Pure conversions (`clampPercent` / `percentToUnit` / `unitToPercent`),
///      the single source of truth, tested directly.
///   2. The dispatch seams (`readBrightnessPercent` / `applyBrightness` /
///      `applyIdleTimerDisabled`) the host fns run, exercised with spies.
/// No real UIKit / wasm fixture required.
final class ScreenControlBridgeTests: XCTestCase {

    // MARK: - Pure conversions

    func testClampPercent() {
        XCTAssertEqual(ScreenControlBridge.clampPercent(0), 0)
        XCTAssertEqual(ScreenControlBridge.clampPercent(50), 50)
        XCTAssertEqual(ScreenControlBridge.clampPercent(100), 100)
        XCTAssertEqual(ScreenControlBridge.clampPercent(-5), 0, "negative clamps to 0")
        XCTAssertEqual(ScreenControlBridge.clampPercent(250), 100, "above 100 clamps to 100")
    }

    func testPercentToUnit() {
        XCTAssertEqual(ScreenControlBridge.percentToUnit(0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(ScreenControlBridge.percentToUnit(50), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ScreenControlBridge.percentToUnit(100), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ScreenControlBridge.percentToUnit(-10), 0.0, accuracy: 1e-9, "clamps first")
        XCTAssertEqual(ScreenControlBridge.percentToUnit(150), 1.0, accuracy: 1e-9, "clamps first")
    }

    func testUnitToPercent() {
        XCTAssertEqual(ScreenControlBridge.unitToPercent(0.0), 0)
        XCTAssertEqual(ScreenControlBridge.unitToPercent(0.5), 50)
        XCTAssertEqual(ScreenControlBridge.unitToPercent(1.0), 100)
        XCTAssertEqual(ScreenControlBridge.unitToPercent(0.755), 76, "rounds to nearest percent")
        XCTAssertEqual(ScreenControlBridge.unitToPercent(-0.2), 0, "clamps below 0")
        XCTAssertEqual(ScreenControlBridge.unitToPercent(1.4), 100, "clamps above 1")
    }

    /// percent -> unit -> percent is a faithful round-trip for whole percents.
    func testBrightnessRoundTrip() {
        for p in [0, 1, 25, 50, 73, 99, 100] {
            let unit = ScreenControlBridge.percentToUnit(p)
            XCTAssertEqual(ScreenControlBridge.unitToPercent(unit), p)
        }
    }

    // MARK: - Spy-backed dispatch

    /// In-memory screen state backing the injected closures.
    private final class ScreenSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _brightnessUnit: Double = 0.5
        private(set) var idleDisabled: Bool = false
        var getBrightness: ScreenControlBridge.BrightnessGetter {
            { [self] in lock.lock(); defer { lock.unlock() }; return _brightnessUnit }
        }
        var setBrightness: ScreenControlBridge.BrightnessSetter {
            { [self] unit in lock.lock(); _brightnessUnit = unit; lock.unlock() }
        }
        var setIdle: ScreenControlBridge.IdleTimerSetter {
            { [self] d in lock.lock(); idleDisabled = d; lock.unlock() }
        }
        var brightnessUnit: Double { lock.lock(); defer { lock.unlock() }; return _brightnessUnit }
    }

    private func makeBridge(_ spy: ScreenSpy) -> ScreenControlBridge {
        ScreenControlBridge(getBrightness: spy.getBrightness,
                            setBrightness: spy.setBrightness,
                            setIdleTimerDisabled: spy.setIdle)
    }

    /// get reads the injected getter and converts to percent.
    func testReadBrightnessPercentUsesGetter() {
        let spy = ScreenSpy()      // starts at 0.5 unit
        let bridge = makeBridge(spy)
        XCTAssertEqual(bridge.readBrightnessPercent(), 50)
    }

    /// set clamps + converts the guest percent and pushes a unit value to the setter.
    func testApplyBrightnessConvertsAndClamps() {
        let spy = ScreenSpy()
        let bridge = makeBridge(spy)

        bridge.applyBrightness(percent: 80)
        XCTAssertEqual(spy.brightnessUnit, 0.8, accuracy: 1e-9)
        XCTAssertEqual(bridge.readBrightnessPercent(), 80, "set then get round-trips")

        bridge.applyBrightness(percent: 250)   // clamps
        XCTAssertEqual(spy.brightnessUnit, 1.0, accuracy: 1e-9)

        bridge.applyBrightness(percent: -30)    // clamps
        XCTAssertEqual(spy.brightnessUnit, 0.0, accuracy: 1e-9)
    }

    /// the keep-awake flag forwards to the idle-timer setter.
    func testApplyIdleTimerForwardsFlag() {
        let spy = ScreenSpy()
        let bridge = makeBridge(spy)
        XCTAssertFalse(spy.idleDisabled)

        bridge.applyIdleTimerDisabled(true)
        XCTAssertTrue(spy.idleDisabled, "keep-screen-awake set")

        bridge.applyIdleTimerDisabled(false)
        XCTAssertFalse(spy.idleDisabled, "auto-lock restored")
    }

    // MARK: - Bridge shape / registration

    func testModuleNamespaceAndRegistration() {
        let bridge = makeBridge(ScreenSpy())
        XCTAssertEqual(bridge.module, "patch")
        XCTAssertNotNil(BridgeRegistry().register(bridge).hostImports())
    }

    #if canImport(UIKit)
    func testDefaultInitRegistersOnUIKit() {
        XCTAssertNotNil(BridgeRegistry().register(ScreenControlBridge()).hostImports())
    }
    #endif
}
