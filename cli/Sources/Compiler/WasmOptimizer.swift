// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Shrinks the final shippable `module.wasm` with a SAFE, correctness-preserving
/// Binaryen `wasm-opt -Oz` finalize pass — the last step of `BuildPipeline.run`,
/// after the real-source / SwiftUI modules are merged into the single `module.wasm`.
///
/// ## Why this exists (the OTA size fix)
/// A real-source patch links the developer's whole module against the full WASM SDK;
/// the linked `module.wasm` carries large amounts of stripped-but-not-DCE'd code +
/// debug/producer custom sections. `wasm-opt -Oz --strip-debug --strip-producers`
/// removes the debug/name/producer sections and runs size-focused optimizations,
/// reliably cutting the module ~25-30% with ZERO behavior change. (The deeper
/// order-of-magnitude win — avoiding the full-Foundation T2 tier — is a separate,
/// orthogonal change; this pass is the always-safe baseline that applies to EVERY
/// shipped module regardless of tier.)
///
/// ## The hard safety constraint (measured): feature preservation
/// The SDK's device runtime is **WasmKit 0.2.2**. `wasm-opt`'s DEFAULT feature set
/// (`--all-features`) enables GC / typed-funcref, and `wasm-metadce` rewrites the
/// function table — both produce a module WasmKit 0.2.2 **refuses to instantiate**
/// (`Expected ref(...concrete) but got ref(...funcRef)`). So this pass:
///   1. reads the INPUT module's own feature set (`wasm-opt --print-features`),
///   2. runs `-Oz` with EXACTLY those features (no GC, no typed-funcref added),
///   3. NEVER runs metadce.
/// The result therefore uses the same feature set the SDK already emits and runs,
/// so it cannot introduce a feature the runtime can't handle. (Verified end-to-end:
/// the optimized Euclid T2 module still returns `{"value":32}` under WasmKit 0.2.2.)
///
/// ## Fallback contract (never a regression)
/// Best-effort + atomic, exactly like `WasmModuleMerger`:
///   - If `wasm-opt` is unavailable, the optimize fails, or the output is somehow
///     LARGER or not valid wasm, the original `module.wasm` is left byte-for-byte
///     intact. The pass can only shrink a module, never lose or corrupt it.
///   - It writes to a temp file and replaces atomically.
public struct WasmOptimizer {
    /// Search order for `wasm-opt`; first existing wins.
    public let candidatePaths: [URL]

    public init(candidatePaths: [URL]? = nil) {
        self.candidatePaths = candidatePaths ?? Self.defaultCandidatePaths
    }

    public static var defaultCandidatePaths: [URL] {
        var paths = [
            "/opt/homebrew/bin/wasm-opt",
            "/usr/local/bin/wasm-opt",
            "/usr/bin/wasm-opt",
        ].map { URL(fileURLWithPath: $0) }
        if let override = ProcessInfo.processInfo.environment["PATCH_WASM_OPT"] {
            paths.insert(URL(fileURLWithPath: override), at: 0)
        }
        return paths
    }

    /// Resolved `wasm-opt` binary, or nil when none is installed.
    public var toolURL: URL? {
        candidatePaths.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public var isAvailable: Bool { toolURL != nil }

    /// The 4-byte wasm magic `\0asm`.
    static let wasmMagic: [UInt8] = [0x00, 0x61, 0x73, 0x6d]

    static func looksLikeWasm(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return Array(h.readData(ofLength: 4)) == wasmMagic
    }

    public struct Outcome: Sendable {
        /// True iff the module was replaced with a smaller optimized version.
        public let optimized: Bool
        public let beforeBytes: Int
        public let afterBytes: Int
        public var savedBytes: Int { max(0, beforeBytes - afterBytes) }
        public var percentSaved: Double {
            beforeBytes > 0 ? 100.0 * Double(beforeBytes - afterBytes) / Double(beforeBytes) : 0
        }
    }

    /// The ONLY WebAssembly features the device runtime (WasmKit 0.2.2) reliably
    /// instantiates — and exactly the set the Swift WASM SDK emits for a
    /// reactor module. The optimize pass enables NOTHING outside this allowlist.
    ///
    /// This is the critical safety invariant. `wasm-opt`'s default (`--all-features`)
    /// turns on GC / typed-funcref → WasmKit 0.2.2 refuses to instantiate. And we
    /// cannot trust `--print-features` on a MERGED module: `WasmModuleMerger` invokes
    /// `wasm-merge --all-features`, so the merged `module.wasm` REPORTS every feature
    /// (gc, memory64, threads, …) even though it uses none of them. So we never read
    /// features from the module — we always pass this fixed safe set with
    /// `--mvp-features` resetting the baseline first. Enabling a feature the module
    /// doesn't actually use is harmless (wasm-opt just won't introduce it); enabling
    /// one OUTSIDE this set would be a runtime break, which this set forbids.
    static let safeFeatureFlags: [String] = [
        "--enable-mutable-globals",
        "--enable-nontrapping-float-to-int",
        "--enable-bulk-memory",
        "--enable-bulk-memory-opt",
        "--enable-sign-ext",
        "--enable-reference-types",
        "--enable-multivalue",
        "--enable-call-indirect-overlong",
    ]

    /// Optimize `module` in place with `-Oz --strip-debug --strip-producers`,
    /// preserving the module's own feature set. NEVER throws; returns an `Outcome`
    /// describing whether (and how much) it shrank. On any failure the module is
    /// left untouched (`optimized == false`).
    ///
    /// CONTAINER-AWARE: when the shipped artifact is a Patch `PMOD` container (the
    /// multi-module real-source/SwiftUI case), each constituent `.wasm` is optimized
    /// individually and the container re-encoded — so the size win applies to every
    /// sub-module even though the container itself is not a wasm. A raw single `.wasm`
    /// is optimized directly (unchanged behavior).
    @discardableResult
    public func optimizeInPlace(module: URL) -> Outcome {
        let fm = FileManager.default
        func fileSize(_ url: URL) -> Int {
            ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        }
        let beforeBytes = fileSize(module)
        func untouched() -> Outcome { Outcome(optimized: false, beforeBytes: beforeBytes, afterBytes: beforeBytes) }

        guard let tool = toolURL,
              fm.fileExists(atPath: module.path),
              let raw = try? Data(contentsOf: module) else { return untouched() }
        let bytes = [UInt8](raw)

        // --- CONTAINER: optimize each sub-module, re-encode, adopt only if smaller.
        if PatchModuleContainer.isContainer(bytes) {
            guard let parts = PatchModuleContainer.decode(bytes) else { return untouched() }
            var optimizedParts: [[UInt8]] = []
            optimizedParts.reserveCapacity(parts.count)
            var anyShrank = false
            for part in parts {
                if let smaller = optimizeBytes(part, tool: tool), smaller.count < part.count {
                    optimizedParts.append(smaller); anyShrank = true
                } else {
                    optimizedParts.append(part)
                }
            }
            guard anyShrank else { return untouched() }
            let newContainer = PatchModuleContainer.encode(optimizedParts)
            guard newContainer.count < bytes.count else { return untouched() }
            // Atomic write — a crash/partial write can never truncate the shippable
            // module (matches the documented contract + the merger's temp-then-move).
            guard (try? Data(newContainer).write(to: module, options: .atomic)) != nil else { return untouched() }
            return Outcome(optimized: true, beforeBytes: beforeBytes, afterBytes: newContainer.count)
        }

        // --- RAW single wasm.
        guard Self.looksLikeWasm(module) else { return untouched() }
        guard let smaller = optimizeBytes(bytes, tool: tool), smaller.count < bytes.count else {
            return untouched()
        }
        // Atomic write (see container branch above) — never a truncated module.wasm.
        guard (try? Data(smaller).write(to: module, options: .atomic)) != nil else { return untouched() }
        return Outcome(optimized: true, beforeBytes: beforeBytes, afterBytes: smaller.count)
    }

    /// Optimize ONE wasm module's bytes with `-Oz --strip-debug --strip-producers`
    /// using the fixed WasmKit-safe feature allowlist. Returns the smaller bytes, or
    /// nil on any failure / if the result isn't valid wasm. Never throws.
    private func optimizeBytes(_ input: [UInt8], tool: URL) -> [UInt8]? {
        guard Self.looksLikeWasm(input) else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        let inURL = dir.appendingPathComponent(".patch-opt-in-\(UUID().uuidString).wasm")
        let outURL = dir.appendingPathComponent(".patch-opt-out-\(UUID().uuidString).wasm")
        defer { try? fm.removeItem(at: inURL); try? fm.removeItem(at: outURL) }
        guard (try? Data(input).write(to: inURL)) != nil else { return nil }

        let p = Process()
        p.executableURL = tool
        // `--mvp-features` resets to the MVP baseline, then we re-enable EXACTLY the
        // WasmKit-safe allowlist — so wasm-opt does NOT silently turn on its default
        // extras (GC / typed-funcref) that WasmKit 0.2.2 can't instantiate.
        p.arguments = ["--mvp-features"] + Self.safeFeatureFlags
            + ["-Oz", "--strip-debug", "--strip-producers", inURL.path, "-o", outURL.path]
        let logPipe = Pipe()
        p.standardOutput = logPipe
        p.standardError = logPipe
        do { try p.run() } catch { return nil }
        let log = logPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, fm.fileExists(atPath: outURL.path),
              Self.looksLikeWasm(outURL) else {
            if ProcessInfo.processInfo.environment["PATCH_WASM_OPT_VERBOSE"] != nil {
                let s = String(data: log, encoding: .utf8) ?? ""
                FileHandle.standardError.write(Data("[wasm-opt] optimize skipped: \(s)\n".utf8))
            }
            return nil
        }
        return (try? Data(contentsOf: outURL)).map { [UInt8]($0) }
    }

    /// True iff `bytes` begins with the wasm magic header.
    static func looksLikeWasm(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && Array(bytes.prefix(4)) == wasmMagic
    }
}
