# PatchSDKDemo — on-simulator validation of PatchSDK + WasmKit

A minimal SwiftUI iOS app that links **PatchSDK** (via SwiftPM, local path) and,
on launch, loads a real `.wasm` module through `WASMRuntime` and displays the
computed result. It shows that WasmKit + PatchSDK load and execute a
WebAssembly module on Apple's CoreSimulator runtime, and serves as the
realistic, dead-stripped binary-size measurement target.

## Layout

```
Examples/PatchSDKDemo/
├── project.yml                 # xcodegen spec: app + unit-test + UI-test targets
├── Sources/
│   ├── PatchSDKDemoApp.swift   # @main SwiftUI app
│   ├── ContentView.swift       # shows add/fib/reverse results + a "WASM executed OK" label
│   └── DemoRuntime.swift       # loads demo.wasm via WASMRuntime, runs 3 exports, os_log's the result
├── Resources/
│   ├── demo.wat / demo.wasm    # 292-byte hand-written module: add, fib, reverse((ptr,len) ABI)
│   └── MinimalSwift.wasm       # the real 5.5 MB Swift-compiled WASI reactor fixture (reused from Tests)
├── UnitTests/
│   └── WasmOnSimulatorTests.swift   # hosted XCTest: WASMRuntime runs both modules on the sim (PRIMARY proof)
└── UITestsBundle/
    └── DemoUITests.swift            # XCUITest: launches the app, asserts on-screen success (secondary proof)
```

`demo.wasm` is self-contained (no WASI imports, no `patch.*` bridges) so it
instantiates on a stock `WASMRuntime` and runs identically on simulator, device,
and macOS. It exercises a plain scalar export (`add`), a heavier compute export
(`fib`), and the **Patch v0 `(ptr,len)` string ABI** (`reverse`, returning a
packed `(ptr<<32)|len` `i64`, the same convention `Bridges.swift` uses).

`MinimalSwift.wasm` is a *real* `wasm32-unknown-wasip1` Swift reactor (14 WASI
imports, exports `_initialize` + `add`); running it proves `WasmKitWASI`'s
Preview 1 host + reactor init work on the simulator.

## Generate the project

```bash
brew install xcodegen          # if needed
cd Examples/PatchSDKDemo
xcodegen generate
```

## Build (release, size-optimized, dead-stripped)

The app target sets `SWIFT_OPTIMIZATION_LEVEL=-Osize`,
`GCC_OPTIMIZATION_LEVEL=z`, `DEAD_CODE_STRIPPING=YES`, and
`LD_GENERATE_MAP_FILE=YES`.

```bash
DD=/tmp/PatchDemoDD
xcodebuild -project PatchSDKDemo.xcodeproj -scheme PatchSDKDemo \
  -configuration Release -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath "$DD" -jobs 4 build
```

## Run it on a booted simulator + capture launch evidence

```bash
SIM=643440EC-7C6F-44BD-AA01-A1381337615B     # iPhone 17 Pro, iOS 26.5
xcrun simctl boot "$SIM"; xcrun simctl bootstatus "$SIM" -b
APP="$DD/Build/Products/Release-iphonesimulator/PatchSDKDemo.app"
xcrun simctl install "$SIM" "$APP"

# stream the app's os_log (subsystem dev.patch.PatchSDKDemo) while launching:
xcrun simctl spawn "$SIM" log stream --level debug --style compact \
  --predicate 'subsystem == "dev.patch.PatchSDKDemo"' &
xcrun simctl launch "$SIM" dev.patch.PatchSDKDemo
```

**Captured launch log (iPhone 17 Pro, iOS 26.5, PID 31240):**

```
PatchSDKDemo[31240] [dev.patch.PatchSDKDemo:demo] PATCHDEMO loading demo.wasm (292 bytes)
PatchSDKDemo[31240] [dev.patch.PatchSDKDemo:demo] PATCHDEMO WASMRuntime instantiated; memory=262144 bytes
PatchSDKDemo[31240] [dev.patch.PatchSDKDemo:demo] PATCHDEMO results add=42 fib=6765 reverse=KDShctaP ok=true
PatchSDKDemo[31240] [dev.patch.PatchSDKDemo:demo] PATCHDEMO SUCCESS: WasmKit executed demo.wasm via PatchSDK on this runtime
```

## Automated proof: XCTest on the simulator

The **primary, headless proof** is the hosted unit-test bundle, which drives
`WASMRuntime` directly inside the app process on the simulator (no UI):

```bash
xcodebuild -project PatchSDKDemo.xcodeproj -scheme PatchSDKDemo \
  -configuration Release -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=643440EC-7C6F-44BD-AA01-A1381337615B' \
  -derivedDataPath "$DD" -only-testing:PatchSDKDemoTests test
```

Result:

```
Test Case '-[PatchSDKDemoTests.WasmOnSimulatorTests testDemoModuleRunsOnSimulator]' passed (0.003 seconds).
Test Case '-[PatchSDKDemoTests.WasmOnSimulatorTests testRealSwiftModuleRunsOnSimulator]' passed (0.026 seconds).
Test Suite 'All tests' passed
```

- `testDemoModuleRunsOnSimulator` — WasmKit instantiates `demo.wasm` and
  invokes `add(40,2)==42`, `fib(20)==6765`, and the `(ptr,len)` `reverse`
  round-trip (`"PatchSDK"` → `"KDShctaP"`).
- `testRealSwiftModuleRunsOnSimulator` — WasmKit + WasmKitWASI instantiate the
  **real 5.5 MB Swift-compiled WASI reactor**, run `_initialize`, invoke
  `add(40,2)==42`. This is the same code path real Patch OTA modules take.

The **secondary proof** is a full UI launch (XCUITest), asserting the on-screen
"WASM executed OK" label and the computed values render:

```bash
xcodebuild ... -only-testing:PatchSDKDemoUITests test
# Test Case '-[PatchSDKDemoUITests.DemoUITests testWasmModuleRunsAndUIShowsSuccess]' passed (5.508 seconds)
```

## Environment used

- macOS host: Swift 6.3.2, Xcode 26.5 (17F42), xcodegen 2.45.4
- Simulator device: **iPhone 17 Pro**, UDID `643440EC-7C6F-44BD-AA01-A1381337615B`
- Runtime: **iOS 26.5 (23F77)** — `com.apple.CoreSimulator.SimRuntime.iOS-26-5`

## Cleanup

```bash
xcrun simctl terminate "$SIM" dev.patch.PatchSDKDemo 2>/dev/null
xcrun simctl uninstall "$SIM" dev.patch.PatchSDKDemo 2>/dev/null
xcrun simctl shutdown "$SIM"
rm -rf /tmp/PatchDemoDD
```

The `PatchSDKDemo.xcodeproj` is xcodegen-generated and can be regenerated at any
time with `xcodegen generate`; it is safe to leave in place or delete.
