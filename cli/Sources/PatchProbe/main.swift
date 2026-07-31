// SPDX-License-Identifier: Apache-2.0

import Foundation
import PartitioningEngine
import CodeGenerator
import Compiler

// Diagnostic driver: run BuildPipeline against a real app dir and surface the
// REAL swiftc errors (the production pipeline swallows them into "→ native").
// Usage: PatchProbe <source-dir> [<build-dir>] [--dry]

let args = CommandLine.arguments

guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: PatchProbe <source-dir> [build-dir] [--dry]\n".utf8))
    exit(2)
}
let dryRun = args.contains("--dry")
let positional = args.dropFirst().filter { !$0.hasPrefix("--") }
let sourceDir = URL(fileURLWithPath: positional[positional.startIndex])
let buildDir = positional.count >= 2
    ? URL(fileURLWithPath: positional[positional.index(positional.startIndex, offsetBy: 1)])
    : FileManager.default.temporaryDirectory.appendingPathComponent("patchprobe-\(UUID().uuidString)")

print("== PatchProbe ==")
print("source: \(sourceDir.path)")
print("build:  \(buildDir.path)")

let compiler = SwiftWasmCompiler()
print("toolchain available: \(compiler.toolchainAvailable)")

let pipeline = BuildPipeline()
let started = Date()
let result = try pipeline.run(sourceDir: sourceDir, buildDir: buildDir, compiler: compiler, dryRun: dryRun)
let elapsed = Date().timeIntervalSince(started)
print("rejected exports (kept native): \(result.rejectedExports.count)")
for r in result.rejectedExports.prefix(20) { print("  REJECT \(r.name): \(r.reason)") }

print(String(format: "elapsed: %.1fs", elapsed))
print("functions: \(result.report.functionCount)")
print("wasmEligible: \(result.report.count(.wasmEligible))  bridged: \(result.report.count(.bridged))  mixed: \(result.report.count(.mixed))  native: \(result.report.count(.native))")
print("generated wasm sources: \(result.generatedWasmSources.count)")
print("export symbols: \(result.exportSymbols.count)")
print("start tier: \(result.selectedTier.rawValue) — \(result.tierRationale)")

if let outcome = result.compileOutcome {
    print("--- compile outcome ---")
    print("toolchainUnavailable: \(outcome.toolchainUnavailable)")
    print("iterations: \(outcome.iterations)")
    print("compiled units: \(outcome.compiled.count)")
    print("demoted: \(outcome.reclassifiedNative.count)")
    print("finalTier: \(String(describing: outcome.finalTier))")
    if let m = outcome.moduleURL,
       let size = try? FileManager.default.attributesOfItem(atPath: m.path)[.size] as? Int {
        print("MODULE: \(m.path) (\(size) bytes)")
    } else {
        print("MODULE: <none>")
    }
    // Surface the raw log (the swallowed swiftc errors).
    print("--- RAW COMPILE LOG (tail) ---")
    let lines = outcome.log.split(separator: "\n", omittingEmptySubsequences: false)
    let errLines = lines.filter { $0.contains("error:") }
    print("error lines: \(errLines.count)")
    for l in errLines.prefix(40) { print(l) }
    print("--- log tail ---")
    for l in lines.suffix(30) { print(l) }
}
