// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Patch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "patchcli", targets: ["PatchCLI"]),
        .library(name: "PartitioningEngine", targets: ["PartitioningEngine"]),
        .library(name: "CodeGenerator", targets: ["CodeGenerator"]),
        .library(name: "Compiler", targets: ["Compiler"]),
        // The shared SwiftUI→WASM ViewNode IR (the wire-format contract). Promoted
        // out of the standalone `swiftui-wasm` research package so the engine codegen
        // AND the on-device SDK renderer can depend on ONE canonical schema. Pure
        // value types (no platform deps); the guest emits this tree in WASM and the
        // SDK renderer reconstitutes real SwiftUI from it.
        .library(name: "ViewNodeIR", targets: ["ViewNodeIR"]),
    ],
    dependencies: [
        // Pinned for Swift 6.3.2 (arm64-apple-macosx26.0). 603.0.1 is the latest
        // stable swift-syntax release aligned with the Swift 6.2/6.3 toolchain line.
        .package(url: "https://github.com/apple/swift-syntax.git", exact: "603.0.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.1"),
        // TEST-ONLY: the same WasmKit the SDK ships, so the codegen test suite can
        // host-RUN a generated module (encode args → invoke @_cdecl export → decode
        // result) and prove the emitted ABI is genuinely executable end-to-end. Not
        // a dependency of the shipped `patchcli` binary or any library product.
        .package(url: "https://github.com/swiftwasm/WasmKit.git", exact: "0.2.2"),
        // Cap swift-system below 1.7.0 — WasmKit 0.2.2's `SystemExtras` miscompiles
        // against swift-system 1.7.0 (its new public `struct Stat` shadows the
        // `var stat: stat = stat()` in SystemExtras, so a fresh resolve that picks
        // 1.7.x breaks the WasmKit-dependent test target). Mirrors the SDK's cap
        // (CLAUDE.md §5 / memory `wasmkit-swift-system-170-cap`). The CLI has no
        // external library consumers, so anchoring `SystemPackage` on the test
        // target below is sufficient — there is no consumer to prune the dep. Drop
        // this once we bump to a WasmKit release carrying swiftwasm/WasmKit#349.
        .package(url: "https://github.com/apple/swift-system", "1.5.0" ..< "1.7.0"),
    ],
    targets: [
        .target(
            name: "PartitioningEngine",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        // The shared ViewNode IR — pure Foundation Codable value types, no UI / no
        // platform deps. Compiles unchanged into BOTH the host engine AND a
        // wasm32 guest. This is the single wire-format contract the SDK renderer
        // must match (schema = the synthesized Codable JSON shape).
        .target(name: "ViewNodeIR"),
        .target(
            name: "CodeGenerator",
            dependencies: [
                "PartitioningEngine",
                "ViewNodeIR",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                // Fold unresolved `SequenceExprSyntax` (SwiftParser leaves operator
                // sequences unfolded) into structured infix/ternary trees so the
                // SwiftUI dispatch lowering can recognize `@State` mutation grammar.
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ],
            resources: [
                // The embeddable ViewNode IR sources, copied verbatim into the
                // SwiftUI guest WASM module at build time (the guest BUILDS the
                // ViewNode tree in WASM and serializes it via EmbeddedJSON). Kept as
                // `.swifttext` resources (not compiled into CodeGenerator itself) so
                // there is ONE canonical IR — a guard test asserts they match the
                // `ViewNodeIR` target byte-for-byte, catching any drift.
                .copy("GuestIR"),
            ]
        ),
        .target(
            name: "Compiler",
            dependencies: [
                "PartitioningEngine",
                "CodeGenerator",
            ]
        ),
        .executableTarget(
            name: "PatchProbe",
            dependencies: [
                "PartitioningEngine",
                "CodeGenerator",
                "Compiler",
            ]
        ),
        .executableTarget(
            name: "PatchCLI",
            dependencies: [
                "PartitioningEngine",
                "CodeGenerator",
                "Compiler",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "PartitioningEngineTests",
            dependencies: [
                "PartitioningEngine",
                "CodeGenerator",
                "Compiler",
                "ViewNodeIR",
                // `@testable import PatchCLI` for the push-flow fingerprint-gate
                // decision tests (PushFlow.evaluateFingerprintGate). Importing the
                // executable target is supported by SwiftPM and adds no runtime cost.
                "PatchCLI",
                // Test-only: host-run generated wasm to prove the emitted ABI works.
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmKitWASI", package: "WasmKit"),
                // Anchors the swift-system "1.5.0"..<"1.7.0" cap (declared above)
                // onto the resolution graph so a fresh `swift build` can't float
                // WasmKit's transitive swift-system up to 1.7.x.
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
    ]
)
