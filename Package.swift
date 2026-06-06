// swift-tools-version:6.0
import PackageDescription

// PatchSDK — the on-device runtime for Patch OTA updates.
//
// Depends on WasmKit 0.2.2 (swiftwasm/WasmKit) and its WASI Preview 1
// implementation (`WasmKitWASI`), which is what lets real Swift-compiled
// `wasm32-unknown-wasip1` modules instantiate (they import 14–34
// `wasi_snapshot_preview1.*` functions). The package is declared for both macOS
// and iOS so the same sources cross-compile for the iOS Simulator and device.
let package = Package(
    name: "PatchSDK",
    platforms: [
        .macOS(.v14),   // WasmKit requires macOS 14+ on macOS hosts.
        .iOS(.v16),     // iOS 16+ floor for the SDK (WasmKit itself supports iOS 12+).
        .tvOS(.v16),    // SwiftUI renderer is platform-guarded for the Apple UI family.
        .visionOS(.v1)
    ],
    products: [
        .library(name: "PatchSDK", targets: ["PatchSDK"]),
        // The shared ViewNode IR — the same schema the engine emits into the
        // guest. Depend on just this to build or inspect a ViewNode tree without
        // pulling in WasmKit or SwiftUI.
        .library(name: "PatchViewIR", targets: ["PatchViewIR"]),
        // The native SwiftUI renderer (`render(_:)` + `PatchView`/`FrontierView`).
        // SwiftUI-only; depends on PatchViewIR.
        .library(name: "PatchRender", targets: ["PatchRender"]),
        // The SwiftUI glue that drives a live Patch module's view_body/dispatch
        // exports into the renderer (the on-device interactive loop). Depends on
        // the runtime + IR + renderer; kept separate so SwiftUI stays out of the
        // core PatchSDK module.
        .library(name: "PatchSwiftUI", targets: ["PatchSwiftUI"])
    ],
    dependencies: [
        // Pinned exactly to 0.2.2. swiftlang/wasmkit redirects here; use the
        // swiftwasm URL.
        .package(url: "https://github.com/swiftwasm/WasmKit.git", exact: "0.2.2")
    ],
    targets: [
        // System-library shim for libbz2 (ships in the macOS + iOS SDKs). Used by
        // the client-side bsdiff4 (BSDIFF40) diff applier to inflate the bz2
        // control/diff/extra blocks the backend produces. Pure system linkage —
        // no third-party code, cross-compiles for iOS device + simulator.
        .systemLibrary(name: "CBZ2", path: "Sources/CBZ2"),

        // The shared ViewNode IR. Pure Foundation `Codable`
        // value types — NO WasmKit, NO SwiftUI — so it compiles unchanged into
        // BOTH the native host AND a wasm32 guest. This is the schema the engine
        // emits; coordinate the wire format via `PatchViewIRSchema` (Schema.swift).
        .target(name: "PatchViewIR"),

        // The native SwiftUI renderer: `render(ViewNode) -> AnyView` + the
        // interactive `PatchView`/`FrontierView` dispatch loop. SwiftUI is
        // `#if canImport(SwiftUI)`-guarded inside the sources, so this target is a
        // no-op on platforms without SwiftUI (e.g. Linux) but builds real SwiftUI
        // on the Apple UI family. Depends only on the IR (no WasmKit), so it never
        // adds runtime weight on its own.
        .target(
            name: "PatchRender",
            dependencies: ["PatchViewIR"]
        ),

        .target(
            name: "PatchSDK",
            dependencies: [
                // Binary-size note: PatchSDK links ONLY these
                // three WasmKit products. They transitively pull exactly the
                // runtime — WasmParser, WasmTypes, SystemExtras, _CWasmKit,
                // SystemPackage — and NOTHING ELSE. The text-format / component
                // tooling (WAT, WIT) and the CLI's deps (NIO, ArgumentParser,
                // swift-atomics/-collections/-log) are NOT products we depend on,
                // so they are never compiled into or linked against the SDK. The
                // realistic dead-stripped contribution is ~1.1-1.5 MiB (see
                // README "Binary size"); do NOT add WAT/WIT here.
                .product(name: "WasmKit", package: "WasmKit"),
                // WASI Preview 1 host shim — required to instantiate real
                // Swift-compiled modules. iOS-safe (pure Swift).
                .product(name: "WasmKitWASI", package: "WasmKit"),
                // The core WASI module: WASIExitCode and friends.
                .product(name: "WASI", package: "WasmKit"),
                // libbz2 shim for diff decompression.
                "CBZ2"
            ]
        ),

        // The SwiftUI glue: wires a LIVE Patch module to the renderer (calls the
        // guest's view_body/dispatch over the packed-(ptr,len)+JSON ABI, decodes
        // + schema-checks the ViewNode tree, drives the interactive loop). Kept in
        // its OWN target so SwiftUI is NEVER imported into the core `PatchSDK`
        // module (a module-wide SwiftUI import perturbs overload resolution of the
        // marshalling layer's `Optional`/`Gesture` extensions). Depends on the
        // runtime (PatchSDK) + the IR + the renderer.
        .target(
            name: "PatchSwiftUI",
            dependencies: ["PatchSDK", "PatchViewIR", "PatchRender"]
        ),

        .testTarget(
            name: "PatchSDKTests",
            dependencies: [
                "PatchSDK",
                "PatchViewIR",
                "PatchRender",
                "PatchSwiftUI",
                .product(name: "WasmKit", package: "WasmKit")
            ],
            resources: [
                // Real Swift-compiled .wasm fixtures used by the runtime tests.
                .copy("Fixtures/MinimalNoFoundation.release.wasm"),
                .copy("Fixtures/MarshalFixture.release.wasm"),
                // Bridge round-trip fixture (hand-written; imports patch.* host fns).
                .copy("Fixtures/BridgeFixture.wasm"),
                // Embedded-Swift demo pricing module: imports patch_host.*
                // (decimal_op / json_get_i64) and computes an order total
                // via the native shell's real Foundation Decimal.
                .copy("Fixtures/DemoEmbeddedPricing.wasm"),
                // Diff/brotli format fixtures (generated by the backend's bsdiff4/brotli).
                .copy("Fixtures/diff_old.bin"),
                .copy("Fixtures/diff_new.bin"),
                .copy("Fixtures/diff.patch"),
                .copy("Fixtures/diff_new.br"),
                // Async executor guest: exports the patch_* pump contract +
                // host-await round-trip. Drives the SDK's on-device async pump tests.
                .copy("Fixtures/AsyncExecGuest.wasm"),
                // Networking guest: awaits patch_host.http_get and decodes JSON in
                // WASM. NetworkingGuest.wasm (a large full-Foundation guest) is NOT a
                // declared resource: it's kept out of git and loaded by source-relative
                // path in PatchHTTPBridgeTests, which XCTSkips when it's absent.
                // Interactive SwiftUI guest: a TEA loop emitting a ViewNode tree and
                // running its update logic in WASM. Drives the renderer + dispatch tests.
                .copy("Fixtures/FrontierGuestInteractive.wasm"),
                // Engine-emitted interactive guest: a SettingsView lowered through the
                // SwiftUI engine path, exporting BOTH view_body AND the auto-generated
                // dispatch. Exercises engine dispatch codegen against Patch.dispatch
                // end-to-end.
                .copy("Fixtures/EngineSettingsView.wasm")
            ]
        )
    ]
)
