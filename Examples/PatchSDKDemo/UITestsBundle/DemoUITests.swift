import XCTest

/// Launches the PatchSDKDemo app on the booted simulator and asserts the UI
/// shows that WasmKit successfully executed the bundled `.wasm` module. This is
/// the on-simulator proof that PatchSDK + WasmKit load and run a module on
/// Apple's CoreSimulator runtime.
final class DemoUITests: XCTestCase {
    func testWasmModuleRunsAndUIShowsSuccess() throws {
        let app = XCUIApplication()
        app.launch()

        // The `.task` runs synchronously-fast (292-byte module), but allow time
        // for app launch + first render on a cold simulator.
        let status = app.staticTexts["demoStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 30),
                      "demo status label never appeared")
        XCTAssertEqual(status.label, "WASM executed OK",
                       "WasmKit did not execute the module successfully on the simulator")

        // The computed values must be visible too (proves real execution, not a stub).
        XCTAssertTrue(app.staticTexts["6765"].exists, "fib(20) result missing")
        XCTAssertTrue(app.staticTexts["KDShctaP"].exists, "reverse() result missing")
    }
}
