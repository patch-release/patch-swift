// swift-tools-version: 6.0
import PackageDescription

// SwiftUI-lowering CORPUS COVERAGE harness.
// =========================================
// A standalone driver that runs the engine's `BodyLowering` over a set of real
// apps' Swift sources and reports, per app + aggregate, what fraction of `: View`
// structs actually LOWER to WASM (auto-route, `thunkSafe`) vs DEMOTE to native —
// plus a ranked histogram of WHY views demote.
//
// It depends on the engine's `CodeGenerator` library via a LOCAL PATH dependency
// (../../cli) so it always measures THIS worktree's lowering — no copy of the
// engine, no fork. The driver does NOT compile to WASM (no toolchain needed): a
// coverage census only needs the static classification + emission verdict, which
// is fast. Build host-side: `export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"; hash -r`.
let package = Package(
    name: "swiftui-corpus-coverage",
    platforms: [.macOS(.v13)],
    dependencies: [
        // The engine lives in the monorepo's cli/ package. Path-relative so the
        // harness measures the lowering in whatever worktree it sits in.
        .package(path: "../../cli"),
    ],
    targets: [
        .executableTarget(
            name: "swiftui-coverage",
            dependencies: [
                // The path-dependency's package identity is its DIRECTORY name (`cli`),
                // not its manifest `name:`.
                .product(name: "CodeGenerator", package: "cli"),
                .product(name: "ViewNodeIR", package: "cli"),
                // For --wasm-compile: emit each app's lowered views to a guest module
                // and actually compile it to WASM (catches "lowered-but-doesn't-compile").
                .product(name: "Compiler", package: "cli"),
            ]
        ),
    ]
)
