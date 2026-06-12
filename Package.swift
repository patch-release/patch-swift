// swift-tools-version:6.0
import PackageDescription

// PatchSDK — the on-device runtime for Patch OTA updates.
//
// Day-2 scope (Track D / Agent D1): the WASM runtime + value marshalling core.
// The loader (download/verify/cache), native fallback, and generated bridges are
// Days 3–6 and are left as clearly-marked TODO stubs.
//
// Depends on WasmKit 0.2.2 (swiftwasm/WasmKit) and its WASI Preview 1
// implementation (`WasmKitWASI`), which is what lets real Swift-compiled
// `wasm32-unknown-wasip1` modules instantiate (they import 14–34
// `wasi_snapshot_preview1.*` functions). The package is declared for both macOS
// and iOS so the same sources cross-compile for the iOS Simulator/device; the
// PoC verified WasmKit 0.2.2 links for `arm64-apple-ios*-simulator`.
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
        // The shared ViewNode IR — the SAME schema the engine-lowering pipeline
        // emits into the guest. An app/engine can depend on JUST this to build or
        // inspect a ViewNode tree without pulling in WasmKit or SwiftUI.
        .library(name: "PatchViewIR", targets: ["PatchViewIR"]),
        // The native SwiftUI renderer (`render(_:)` + `PatchView`/`FrontierView`).
        // SwiftUI-only; depends on PatchViewIR.
        .library(name: "PatchRender", targets: ["PatchRender"]),
        // The SwiftUI glue that drives a LIVE Patch module's view_body/dispatch
        // exports into the renderer (the on-device interactive loop). Depends on
        // the runtime + IR + renderer; kept separate so SwiftUI stays out of the
        // core PatchSDK module.
        .library(name: "PatchSwiftUI", targets: ["PatchSwiftUI"])
    ],
    dependencies: [
        // Pinned exactly to 0.2.2 — the version proven in poc/wasmkit-ios.
        // Use the swiftwasm URL; the swiftlang/wasmkit path does NOT resolve.
        .package(url: "https://github.com/swiftwasm/WasmKit.git", exact: "0.2.2"),
        // Cap swift-system below 1.7.0. WasmKit 0.2.2 requires swift-system with
        // an OPEN upper bound (`from: "1.5.0"`), but its `SystemExtras` fails to
        // compile against swift-system 1.7.0: 1.7.0 added a public top-level
        // `struct Stat`, after which WasmKit's `var stat: stat = stat()` (a local
        // shadowing the C `stat` type) mis-resolves the `stat()` initializer to
        // `Stat` → "cannot convert value of type 'Stat' to specified type 'stat'".
        // Without this cap, ANY consumer app whose dependency graph floats
        // swift-system to 1.7.0 fails to build PatchSDK. We declare swift-system
        // directly so the resolver intersects to 1.5.0..<1.7.0 (newest safe is
        // 1.6.x). Fix submitted upstream: https://github.com/swiftwasm/WasmKit/pull/349
        // TODO(remove-cap): once that PR (or an equivalent) ships in a WasmKit
        // release we depend on, DROP this `swift-system` constraint and let it
        // float again. Tracked in CLAUDE.md §5 / memory `wasmkit-swift-system-170-cap`.
        .package(url: "https://github.com/apple/swift-system", "1.5.0" ..< "1.7.0")
    ],
    targets: [
        // System-library shim for libbz2 (ships in the macOS + iOS SDKs). Used by
        // the client-side bsdiff4 (BSDIFF40) diff applier to inflate the bz2
        // control/diff/extra blocks the backend produces. Pure system linkage —
        // no third-party code, cross-compiles for iOS device + simulator.
        .systemLibrary(name: "CBZ2", path: "Sources/CBZ2"),

        // The shared ViewNode IR (Breakthrough #3/#5). Pure Foundation `Codable`
        // value types — NO WasmKit, NO SwiftUI — so it compiles unchanged into
        // BOTH the native host AND a wasm32 guest. This is the schema the engine-
        // lowering pipeline emits; coordinate the wire format via
        // `PatchViewIRSchema` (Schema.swift). Vendored from swiftui-wasm's
        // `ViewNodeIR` with an added schema-version contract.
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
                // Binary-size note (Track D size pass): PatchSDK links these three
                // WasmKit products. They transitively pull exactly the runtime —
                // WasmParser, WasmTypes, SystemExtras, _CWasmKit, SystemPackage —
                // and NOTHING ELSE. The text-format / component tooling (WAT, WIT)
                // and the CLI's deps (NIO, ArgumentParser, swift-atomics/-collections
                // /-log) are NOT products we depend on, so they are never compiled
                // into or linked against the SDK. A release, dead-stripped arm64-iOS
                // link map confirms it: the only statically linked objects are
                // PatchSDK + the six above. The realistic dead-stripped contribution
                // is ~1.1-1.5 MiB (see README "Binary size"); do NOT add WAT/WIT here.
                .product(name: "WasmKit", package: "WasmKit"),
                // WASI Preview 1 host shim — required to instantiate real
                // Swift-compiled modules. iOS-safe (pure Swift).
                .product(name: "WasmKitWASI", package: "WasmKit"),
                // The core WASI module: WASIExitCode and friends.
                .product(name: "WASI", package: "WasmKit"),
                // SystemPackage (swift-system) — already pulled transitively by
                // WasmKit's SystemExtras, so listing it here adds NOTHING to the
                // link map. It is declared on the SHIPPED target on purpose: it
                // anchors the `swift-system "1.5.0"..<"1.7.0"` cap (see the
                // dependencies block above) into the product dependency closure so
                // the cap PROPAGATES TO CONSUMER APPS. It must NOT live on the test
                // target only — SwiftPM prunes test-target deps for consumers, so a
                // test-only anchor lets a consuming app float swift-system back to
                // 1.7.0 and hit the WasmKit `var stat: stat` build break (verified
                // against a real app, IceCubesApp). Remove together with the cap when
                // WasmKit PR #349 ships. iOS-safe (pure Swift).
                .product(name: "SystemPackage", package: "swift-system"),
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
                // D3 bridge round-trip fixture (hand-written; imports patch.* host fns).
                .copy("Fixtures/BridgeFixture.wasm"),
                // Embedded-Swift (T0) demo pricing module: imports patch_host.*
                // (decimal_op / json_get_i64) and computes the demo's order total
                // via the native shell's real Foundation Decimal. ~26 KB stripped
                // vs the ~57 MB full-Foundation module it replaces.
                .copy("Fixtures/DemoEmbeddedPricing.wasm"),
                // D2 diff/brotli format fixtures (generated by the backend's bsdiff4/brotli).
                .copy("Fixtures/diff_old.bin"),
                .copy("Fixtures/diff_new.bin"),
                .copy("Fixtures/diff.patch"),
                .copy("Fixtures/diff_new.br"),
                // Async executor proof guest (experiments/async-exec): exports the
                // patch_* pump contract + host-await round-trip. Drives the SDK's
                // on-device async pump tests.
                .copy("Fixtures/AsyncExecGuest.wasm"),
                // Breakthrough #6 networking proof guest (experiments/networking):
                // awaits patch_host.http_get, decodes JSON with JSONDecoder IN WASM,
                // NetworkingGuest.wasm (53 MB — full-Foundation JSONDecoder in WASM) is
                // NOT a declared resource: it's kept out of git (too large w/o LFS) and
                // loaded by source-relative path in PatchHTTPBridgeTests, which XCTSkips
                // when it's absent. Rebuild via experiments/networking.
                // Interactive SwiftUI guest (swiftui-wasm/guest-interactive): a TEA
                // loop emitting a ViewNode tree + running its UPDATE logic in WASM.
                // Drives the SDK's renderer + dispatch tests.
                .copy("Fixtures/FrontierGuestInteractive.wasm"),
                // ENGINE-EMITTED interactive guest: a SettingsView lowered through the
                // production PATCH_SWIFTUI engine path (BodyLowering + SwiftUIGuestEmitter),
                // exporting BOTH view_body AND the auto-generated dispatch. Proves the
                // engine's dispatch codegen drives the SDK's Patch.dispatch end-to-end.
                .copy("Fixtures/EngineSettingsView.wasm")
            ]
        )
    ]
)
