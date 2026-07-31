// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Merges the default engine module and the additive REAL-SOURCE module into ONE
/// shippable `.wasm`, so the real-source/fusion coverage gains actually reach
/// users on a normal `release`/`push`.
///
/// ## Why this exists (the P0 ship-plumbing fix)
/// `BuildPipeline` produces two artifacts when `PATCH_REAL_SOURCE=1`:
///   - the DEFAULT `module.wasm` (the reconstruction engine's exports), and
///   - the ADDITIVE `module.realsource.wasm` (the extra exports only the real
///     compiler could ship).
/// `release`/`push` upload only `module.wasm`, so the additive exports were
/// silently dropped on a real ship. This merger combines the two into a single
/// `module.wasm` (the upload path is untouched), so the gain ships by default.
///
/// ## The multi-memory P0 (why this combines into a CONTAINER, not a single module)
/// Each input is an INDEPENDENTLY-linked Swift module that defines its own linear
/// memory (base 0), its own `__stack_pointer`, its own heap/allocator (`patch_malloc`)
/// and its own reactor `_initialize`/runtime metadata. There is no sound way to fuse
/// the two into ONE wasm module that WasmKit 0.2.2 (the SDK device runtime) can run:
///   - `wasm-merge` keeps BOTH memories for two genuinely-distinct real modules (e.g.
///     Euclid's default-engine module vs the real-source module) → a **multi-memory**
///     module WasmKit **refuses to instantiate** (`multiple memories are not
///     permitted`). [Reproduced.]
///   - Forcing one memory (`--skip-export-conflicts` + `wasm-opt
///     --multi-memory-lowering`) drops the second module's allocator + `_initialize`,
///     so the real-source export runs against the WRONG heap and returns nothing.
///     [Proven empirically in WasmKit: the default export works, the real-source
///     export returns 0 — UNSOUND.]
///
/// So this combines the two modules into the Patch **CONTAINER** (`PatchModuleContainer`,
/// magic `PMOD`): each module is kept BYTE-FOR-BYTE intact, and the SDK instantiates
/// each as its OWN WasmKit instance (its own memory/allocator/`_initialize` — sound by
/// construction) and routes each call to whichever instance exports the symbol. The
/// container is an OPAQUE blob to the backend (it never parses wasm magic), so it ships
/// through the EXISTING upload/download/storage/diff path with NO contract change.
/// Verified in WasmKit: BOTH a default-tier export AND a real-source export return their
/// correct values (`WasmModuleMergerTests.testMergedRealSourceExecutesInWasmKit`).
///
/// ## Safety / fallback contract
/// The combine is STRICTLY additive and never loses the default module:
///   - If an input is missing, or is not a real wasm binary (e.g. a test stub), or is
///     multi-memory (a single sub-module must be single-memory — WasmKit can't run it
///     otherwise), the default `module.wasm` is left exactly as the default build
///     produced it. The real-source gain is then reported but not shipped — never a
///     regression. (The container itself needs NO external tool.)
///   - The combine writes atomically (to a temp file, then replaces the default), so a
///     partial/failed combine can never corrupt the shippable module.
public struct WasmModuleMerger {
    /// Where to find `wasm-merge`. Searched in order; first existing wins.
    public let candidatePaths: [URL]

    public init(candidatePaths: [URL]? = nil) {
        self.candidatePaths = candidatePaths ?? Self.defaultCandidatePaths
    }

    /// Standard install locations for Binaryen's `wasm-merge` (Homebrew on
    /// Apple-silicon + Intel, plus a plain PATH lookup fallback).
    public static var defaultCandidatePaths: [URL] {
        var paths = [
            "/opt/homebrew/bin/wasm-merge",
            "/usr/local/bin/wasm-merge",
            "/usr/bin/wasm-merge",
        ].map { URL(fileURLWithPath: $0) }
        // Honor an explicit override (CI / non-standard installs).
        if let override = ProcessInfo.processInfo.environment["PATCH_WASM_MERGE"] {
            paths.insert(URL(fileURLWithPath: override), at: 0)
        }
        return paths
    }

    /// The resolved `wasm-merge` binary, or nil when none is installed. The CONTAINER
    /// combine needs NO external tool; this is retained only so tests can REPRODUCE the
    /// original (broken) `wasm-merge` single-module path to demonstrate the bug.
    public var toolURL: URL? {
        candidatePaths.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public var isAvailable: Bool { toolURL != nil }

    public enum MergeError: Error, CustomStringConvertible {
        case toolUnavailable
        case inputMissing(URL)
        case notWasm(URL)
        case mergeFailed(String)
        /// The merge produced a multi-memory module and it could not be lowered to a
        /// single memory (no `wasm-opt`, lowering failed, or still >1 memory after).
        /// WasmKit 0.2.2 cannot instantiate multi-memory — so the merge is rejected
        /// rather than ship a module the device runtime would reject.
        case multiMemoryUnlowerable(String)

        public var description: String {
            switch self {
            case .toolUnavailable: return "wasm-merge not found"
            case .inputMissing(let u): return "merge input missing: \(u.path)"
            case .notWasm(let u): return "not a wasm binary: \(u.path)"
            case .mergeFailed(let log): return "wasm-merge failed: \(log)"
            case .multiMemoryUnlowerable(let why):
                return "merged module is multi-memory and could not be lowered to a single memory (WasmKit can't instantiate it): \(why)"
            }
        }
    }

    /// The 4-byte wasm magic `\0asm`. A real Binaryen merge requires both inputs to
    /// be genuine wasm — a test stub that writes only the magic header is not enough
    /// for `wasm-merge` to parse, so callers should prefer `mergeIfPossible`.
    public static let wasmMagic: [UInt8] = [0x00, 0x61, 0x73, 0x6d]

    /// True iff the file begins with the wasm magic header.
    public static func looksLikeWasm(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = h.readData(ofLength: 4)
        return Array(head) == wasmMagic
    }

    /// Combine `primary` (default) + `secondary` (additive) into `output` as a Patch
    /// CONTAINER (`PMOD`): both modules kept verbatim, instantiated separately on-device.
    ///
    /// If `output == primary` (the in-place ship path), the container WRAPS the prior
    /// container or raw module already at `primary` and APPENDS `secondary` — so calling
    /// this once for real-source and again for SwiftUI yields a 3-module container, not
    /// a nested one. Throws on any failure (the caller decides whether to fall back).
    public func merge(primary: URL, secondary: URL, output: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: primary.path) else { throw MergeError.inputMissing(primary) }
        guard fm.fileExists(atPath: secondary.path) else { throw MergeError.inputMissing(secondary) }
        // The additive (secondary) input must be a real, single-memory wasm — a
        // multi-memory sub-module would itself be uninstantiable on-device.
        guard Self.looksLikeWasm(secondary) else { throw MergeError.notWasm(secondary) }
        let secMem = memoryCount(of: secondary)
        guard secMem == 1 else {
            throw MergeError.multiMemoryUnlowerable(
                "additive module \(secondary.lastPathComponent) has \(secMem) memories (must be single-memory)")
        }

        // The primary may already be a CONTAINER (a prior merge) or a raw wasm. Build
        // the module LIST from it, then append the additive module.
        let primaryBytes = [UInt8](try Data(contentsOf: primary))
        var modules: [[UInt8]]
        if let existing = PatchModuleContainer.decode(primaryBytes) {
            modules = existing
        } else {
            guard Self.looksLikeWasm(primary) else { throw MergeError.notWasm(primary) }
            let priMem = memoryCount(of: primary)
            guard priMem == 1 else {
                throw MergeError.multiMemoryUnlowerable(
                    "default module \(primary.lastPathComponent) has \(priMem) memories (must be single-memory)")
            }
            modules = [primaryBytes]
        }
        modules.append([UInt8](try Data(contentsOf: secondary)))

        let container = PatchModuleContainer.encode(modules)

        // Write atomically — to a temp file, then replace in place — so a partial/failed
        // combine can never corrupt OR LOSE the shippable default module. We must NOT
        // unlink the only copy of `output` before the replacement is in place: a failed
        // move would then destroy module.wasm entirely (atomicity-contract violation).
        let tmp = output.deletingLastPathComponent()
            .appendingPathComponent(".patch-merge-\(UUID().uuidString).bin")
        defer { try? fm.removeItem(at: tmp) }
        try Data(container).write(to: tmp)
        if fm.fileExists(atPath: output.path) {
            // Atomic replace: leaves the original `output` byte-for-byte intact if it fails.
            _ = try fm.replaceItemAt(output, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: output)
        }
    }

    /// Count the defined+imported linear memories in a wasm module by parsing the
    /// binary's Memory and Import sections directly (no external tool — robust on any
    /// machine and not fooled by `wasm-merge --all-features` inflating feature reports).
    ///
    /// A wasm module has at most one Memory section (entries = defined memories) and
    /// at most one Import section (whose `memory` entries are imported memories). The
    /// total memory count is defined + imported. Returns 0 when the file can't be
    /// parsed (treated as "no memory" — the caller's >1 check then never fires).
    func memoryCount(of url: URL) -> Int {
        guard let data = try? Data(contentsOf: url), data.count > 8,
              Array(data.prefix(4)) == Self.wasmMagic else { return 0 }
        let bytes = [UInt8](data)
        var i = 8  // skip magic (4) + version (4)
        var defined = 0
        var imported = 0

        func readLEB(_ p: inout Int) -> Int? {
            var result = 0, shift = 0
            while p < bytes.count {
                let b = bytes[p]; p += 1
                result |= Int(b & 0x7f) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 35 { return nil }
            }
            return nil
        }

        while i < bytes.count {
            let sectionID = bytes[i]; i += 1
            guard let size = readLEB(&i) else { return defined + imported }
            let sectionStart = i
            let sectionEnd = i + size
            guard sectionEnd <= bytes.count else { return defined + imported }

            if sectionID == 5 {  // Memory section: count = number of defined memories
                var p = sectionStart
                if let count = readLEB(&p) { defined = count }
            } else if sectionID == 2 {  // Import section: count `memory` (kind 0x02) imports
                var p = sectionStart
                if let count = readLEB(&p) {
                    for _ in 0..<count where p < sectionEnd {
                        // module name
                        guard let mlen = readLEB(&p) else { break }
                        p += mlen
                        // field name
                        guard let flen = readLEB(&p) else { break }
                        p += flen
                        guard p < sectionEnd else { break }
                        let kind = bytes[p]; p += 1
                        switch kind {
                        case 0x00: _ = readLEB(&p)                       // func: type index
                        case 0x01:                                       // table: elemtype + limits
                            // A table import is a reftype byte THEN a `limits`
                            // (flags byte + min + optional max). The previous code
                            // read the flags byte AS the min LEB and then inspected a
                            // stale byte for the has-max bit — mis-parsing every table
                            // import, which could desync the whole import-section scan
                            // (and miscount memories) on a module that imports a table
                            // BEFORE its memory.
                            p += 1                                       // reftype
                            guard p < sectionEnd else { break }
                            let tflags = bytes[p]; p += 1                // limits flags
                            _ = readLEB(&p)                              // min
                            if tflags & 0x01 != 0 { _ = readLEB(&p) }    // max
                        case 0x02:                                       // memory
                            imported += 1
                            guard p < sectionEnd else { break }
                            let flags = bytes[p]; p += 1
                            _ = readLEB(&p)                              // min
                            if flags & 0x01 != 0 { _ = readLEB(&p) }     // max
                        case 0x03: p += 2                                // global: valtype + mut
                        case 0x04:                                       // tag (exception): attribute u8 + type index
                            guard p < sectionEnd else { break }
                            p += 1                                       // attribute byte
                            _ = readLEB(&p)                              // type index
                        default:
                            // An unknown import kind desyncs the scan: from here we can no
                            // longer trust the running count. Returning the (now possibly
                            // UNDER-counted) total could let a multi-memory secondary slip
                            // past the `== 1` guards. Fail CLOSED with an over-count sentinel
                            // so those guards reject the module and the merge is skipped
                            // (gain dropped, default module intact) — never an under-count.
                            return Int.max
                        }
                    }
                }
            }
            i = sectionEnd
        }
        return defined + imported
    }

    /// Best-effort merge that NEVER throws and never loses the default module.
    ///
    /// Returns true iff the merge happened (the default module now also carries the
    /// real-source exports). On any failure (no tool, non-wasm stub, merge error) it
    /// returns false and leaves the default module untouched — the additive gain is
    /// simply not shipped, which is the pre-fix behavior (never a regression).
    @discardableResult
    public func mergeIfPossible(primary: URL, secondary: URL) -> Bool {
        do {
            try merge(primary: primary, secondary: secondary, output: primary)
            return true
        } catch {
            if ProcessInfo.processInfo.environment["PATCH_REAL_SOURCE_VERBOSE"] != nil {
                FileHandle.standardError.write(
                    Data("[real-source] merge into default module skipped: \(error)\n".utf8))
            }
            return false
        }
    }
}
