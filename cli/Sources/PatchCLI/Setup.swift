// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler

/// `patchcli setup` — install the swift.org Swift toolchain + WebAssembly SDK that
/// `patchcli build`/`release` compile against.
///
/// Best practice for a dev tool with a heavyweight toolchain dependency (cf.
/// `rustup`, `flutter doctor`/`precache`, `gcloud components install`): wrap the
/// multi-step install behind ONE command the developer already trusts, with the
/// versions + checksum pinned in the binary — instead of asking them to paste a
/// `curl … | bash && swift sdk install <long-url> --checksum <64 hex>` one-liner
/// that looks like malware. The download is still from swift.org; we just drive it.
struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Install the Swift→WebAssembly toolchain `patchcli release` needs (one-time).")

    @Flag(name: .long, help: "Reinstall even if a toolchain is already detected.")
    var force: Bool = false

    // Pinned swift.org artifacts. These MUST match the SDK the engine builds with
    // (`SwiftWasmCompiler.swiftSDK` = "swift-6.3.2-RELEASE_wasm"). The checksum is
    // verified by `swift sdk install` against the downloaded bundle.
    static let toolchainPkgURL =
        "https://download.swift.org/swift-6.3.2-release/xcode/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE-osx.pkg"
    static let wasmSDKURL =
        "https://download.swift.org/swift-6.3.2-release/wasm-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_wasm.artifactbundle.tar.gz"
    static let wasmSDKChecksum =
        "a61f0584c93283589f8b2f42db05c1f9a182b506c2957271402992655591dd7c"

    func run() throws {
        #if !os(macOS)
        throw ValidationError(
            "`patchcli setup` supports macOS today. On Linux, install the swift.org "
            + "6.3.2 toolchain + the WebAssembly SDK manually — see docs.patchrelease.com.")
        #else
        let detector = SwiftWasmCompiler(exportedSymbols: [])
        if detector.toolchainAvailable && !force {
            print("✓ Swift WebAssembly toolchain already installed.")
            print("  swift: \(SwiftWasmCompiler.defaultToolchainSwift.path)")
            print("  You're ready — run:  patchcli release")
            return
        }

        print("Installing the swift.org Swift toolchain + WebAssembly SDK (one-time).")
        print("`patchcli release` compiles your Swift to WebAssembly with it — Xcode's")
        print("Apple toolchain can't target wasm. Downloads are from swift.org (~1 GB);")
        print("this takes a few minutes.\n")

        // 1. The swift.org toolchain (installed into ~/Library/Developer/Toolchains,
        //    where the engine looks — see SwiftWasmCompiler.defaultToolchainSwift).
        let pkg = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patchcli-swift-6.3.2-RELEASE.pkg")
        print("→ Downloading the Swift 6.3.2 toolchain from swift.org…")
        try runStreaming("/usr/bin/curl", ["-fL", "--retry", "3", "-o", pkg.path, Setup.toolchainPkgURL])
        print("→ Installing the toolchain…")
        try runStreaming("/usr/sbin/installer", ["-pkg", pkg.path, "-target", "CurrentUserHomeDirectory"])
        try? FileManager.default.removeItem(at: pkg)

        let swift = SwiftWasmCompiler.defaultToolchainSwift
        guard FileManager.default.fileExists(atPath: swift.path) else {
            throw ValidationError(
                "Toolchain installed but `swift` was not found at \(swift.path). "
                + "See docs.patchrelease.com for manual steps.")
        }

        // 2. The matching WebAssembly Swift SDK (checksum-verified by swift sdk).
        print("→ Installing the WebAssembly SDK…")
        do {
            try runStreaming(swift.path, [
                "sdk", "install", Setup.wasmSDKURL, "--checksum", Setup.wasmSDKChecksum,
            ])
        } catch {
            // A re-run hits "already installed" — tolerate it; the verify below (and
            // the first real build) is the source of truth on whether it's usable.
            print("  (note: \(error.localizedDescription) — continuing; likely already installed)")
        }

        guard SwiftWasmCompiler(exportedSymbols: []).toolchainAvailable else {
            throw ValidationError(
                "Install finished but the toolchain still isn't detected at \(swift.path). "
                + "See docs.patchrelease.com.")
        }
        print("\n✓ Done. Swift WebAssembly toolchain installed — run:  patchcli release")
        #endif
    }

    /// Run an executable, streaming its stdout/stderr live so the developer sees
    /// download/install progress; throw a clean error on non-zero exit.
    private func runStreaming(_ launchPath: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw ValidationError(
                "`\(([launchPath] + args).joined(separator: " "))` failed (exit \(p.terminationStatus)).")
        }
    }
}
