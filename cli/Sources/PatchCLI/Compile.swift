// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import PartitioningEngine
import CodeGenerator
import Compiler

/// `Patch compile <path>` — generate `_wasm.swift` for the OTA-eligible
/// functions of a directory and compile them to a real `.wasm` module using the
/// swift.org toolchain + the WebAssembly Swift SDK. Runs the
/// auto-reclassify-on-compile-failure convergence loop.
///
/// This is the end-to-end proof that the engine produces compilable WASM. It is
/// intentionally conservative: it only attempts to compile generated fragment
/// sources, and any source that fails to compile is dropped and reported as
/// reclassified-native (safe — non-compiling code can never run OTA).
struct Compile: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compile",
        abstract: "Generate _wasm.swift for OTA-eligible code and compile it to a real .wasm module."
    )

    @Argument(help: "Path to a directory of generated _wasm.swift files (or a single .swift file) to compile.")
    var path: String

    @Option(name: .long, help: "Output .wasm path.")
    var output: String = "patch.wasm"

    @Option(name: .long, help: "Swift SDK identifier for the WASM target.")
    var swiftSDK: String = "swift-6.3.2-RELEASE_wasm"

    @Option(name: .long, help: "Comma-separated symbols to export from the module.")
    var exports: String = ""

    func run() throws {
        let url = URL(fileURLWithPath: path)
        let sources = try collectSources(url)
        guard !sources.isEmpty else {
            print("No .swift sources found at \(path).")
            return
        }

        let exportList = exports.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let compiler = SwiftWasmCompiler(swiftSDK: swiftSDK, exportedSymbols: exportList)

        print("Patch compile")
        print("=============")
        print("Sources:        \(sources.count)")
        print("Swift SDK:      \(swiftSDK)")
        print("Toolchain:      \(compiler.toolchainSwift.path)")
        print("Available:      \(compiler.toolchainAvailable ? "yes" : "NO — will report toolchainUnavailable")")
        print("")

        // Drive the convergence loop: each source is its own candidate so a
        // single non-compiling fragment is demoted rather than failing the whole.
        let candidates = sources.map {
            WasmConvergence.Candidate(functionID: $0.lastPathComponent, sourceFile: $0, exports: exportList)
        }
        let convergence = WasmConvergence(compiler: compiler)
        // The compile + reclassify convergence loop is silent and multi-second.
        let outcome = try Spinner.run("Compiling Swift → WebAssembly") {
            try convergence.converge(candidates, outputModule: URL(fileURLWithPath: output))
        }

        if outcome.toolchainUnavailable {
            print("WASM toolchain unavailable — affected functions would be reclassified native.")
            return
        }

        print("Iterations:     \(outcome.iterations)")
        print("Compiled OTA:   \(outcome.compiled.count)")
        print("Demoted native: \(outcome.reclassifiedNative.count)")
        for d in outcome.reclassifiedNative {
            print("  - \(d.functionID) (failed WASM compile → native)")
        }
        if let module = outcome.moduleURL,
           let size = try? FileManager.default.attributesOfItem(atPath: module.path)[.size] as? Int {
            print("")
            print("Emitted module: \(module.path) (\(size) bytes)")
        } else {
            print("\nNo module emitted.")
        }
    }

    private func collectSources(_ url: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ValidationError("Path not found: \(url.path)")
        }
        if !isDir.boolValue {
            return url.pathExtension == "swift" ? [url] : []
        }
        var out: [URL] = []
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let f as URL in e where f.pathExtension == "swift" { out.append(f) }
        }
        return out.sorted { $0.path < $1.path }
    }
}
