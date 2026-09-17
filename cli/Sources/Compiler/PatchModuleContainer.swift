// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Patch multi-module CONTAINER format — the sound way to ship a default module
/// + an additive real-source/SwiftUI module as ONE artifact.
///
/// ## Why a container (not `wasm-merge`)
/// The default-engine module and the additive real-source module are two
/// INDEPENDENTLY-linked Swift modules. Each defines its own linear memory at base 0,
/// its own `__stack_pointer`, its own heap/allocator (`patch_malloc`) and its own
/// reactor `_initialize`/runtime metadata. `wasm-merge` either:
///   - keeps BOTH memories → a multi-memory module **WasmKit 0.2.2 refuses to
///     instantiate** (`multiple memories are not permitted`), OR
///   - fuses them and drops the second module's allocator/`_initialize`
///     (`--skip-export-conflicts`) → the second module's exports run against the
///     WRONG heap and return garbage / nothing (proven empirically — the real-source
///     export returns 0).
/// Either way a merged single module is UNSOUND. The container instead keeps each
/// module byte-for-byte intact; the SDK instantiates each as its OWN WasmKit instance
/// (its own memory/allocator/`_initialize` — sound by construction) and routes each
/// call to whichever instance exports the symbol.
///
/// ## Wire format (little-endian)
/// ```
/// magic   : 4 bytes  = "PMOD"  (0x50 0x4D 0x4F 0x44) — distinct from wasm "\0asm"
/// version : u8       = 1
/// count   : u8       = number of modules (>= 1)
/// reserved: u16      = 0
/// for each module:
///     length : u32   = module byte length
///     bytes  : length bytes  (a verbatim single-memory `.wasm`)
/// ```
/// The container is an OPAQUE blob to the backend (it never parses wasm magic — it
/// stores/serves/diffs/SHAs the bytes as-is), so it rides the EXISTING upload/download/
/// storage/diff path with NO contract change. A single (non-container) module is still
/// shipped as a raw `.wasm`; the SDK detects the `PMOD` magic and falls back to the
/// single-instance path when it is absent (full back-compat).
public enum PatchModuleContainer {
    /// Container magic `PMOD`. Chosen so it can never collide with the wasm magic
    /// `\0asm` (`0x00 0x61 0x73 0x6d`) — the first byte alone (`0x50` vs `0x00`)
    /// disambiguates a container from a raw wasm module.
    public static let magic: [UInt8] = [0x50, 0x4D, 0x4F, 0x44]  // "PMOD"
    public static let version: UInt8 = 1

    /// True iff `bytes` begins with the container magic.
    public static func isContainer(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && Array(bytes.prefix(4)) == magic
    }

    /// Encode `modules` (each a raw `.wasm` byte buffer) into a container blob.
    /// The order is preserved; the FIRST module is the default/primary one.
    public static func encode(_ modules: [[UInt8]]) -> [UInt8] {
        precondition(modules.count >= 1 && modules.count <= 255, "1...255 modules")
        // `decode` rejects both of these, so encoding one would produce a blob that
        // can never be read back — fail at the producer instead of on the device.
        precondition(modules.allSatisfy { $0.count >= 4 && Array($0.prefix(4)) == wasmMagic },
                     "every sub-module must be a non-empty wasm binary")
        var out = magic
        out.append(version)
        out.append(UInt8(modules.count))
        out.append(0); out.append(0)  // reserved u16
        for m in modules {
            let n = UInt32(m.count)
            out.append(UInt8(n & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8((n >> 16) & 0xFF))
            out.append(UInt8((n >> 24) & 0xFF))
            out.append(contentsOf: m)
        }
        return out
    }

    /// The wasm magic every sub-module must start with (`\0asm`). A container only
    /// ever holds verbatim single-memory wasm modules, so anything else is a
    /// corrupt/foreign blob — not something to hand a WasmKit instance.
    static let wasmMagic: [UInt8] = [0x00, 0x61, 0x73, 0x6d]

    /// Decode a container blob into its constituent module byte buffers. Returns nil
    /// when `bytes` is not a well-formed container — callers then treat it as a raw
    /// module (or, for the ship path, refuse to combine).
    ///
    /// "Well-formed" is checked STRICTLY, because every caller acts on the result:
    /// the optimizer rewrites the file from it and the merger appends to it, so a
    /// mis-parsed container would be re-encoded as a DIFFERENT artifact and the
    /// device would silently lose a sub-module. Rejected: a wrong magic/version, a
    /// zero `count`, a truncated frame, a declared length running past the end, a
    /// sub-module that is EMPTY or not a wasm binary, and any TRAILING bytes after
    /// the last declared module (a container whose frame count disagrees with its
    /// payload is corrupt — silently ignoring the tail would drop a whole module).
    public static func decode(_ bytes: [UInt8]) -> [[UInt8]]? {
        guard isContainer(bytes), bytes.count >= 8 else { return nil }
        guard bytes[4] == version else { return nil }
        guard bytes[6] == 0, bytes[7] == 0 else { return nil }  // reserved u16
        let count = Int(bytes[5])
        guard count >= 1 else { return nil }
        var i = 8
        var modules: [[UInt8]] = []
        modules.reserveCapacity(count)
        for _ in 0..<count {
            guard i + 4 <= bytes.count else { return nil }
            let n = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
                | (Int(bytes[i + 2]) << 16) | (Int(bytes[i + 3]) << 24)
            i += 4
            guard n > 0, i + n <= bytes.count else { return nil }
            let module = Array(bytes[i..<i + n])
            guard module.count >= 4, Array(module.prefix(4)) == wasmMagic else { return nil }
            modules.append(module)
            i += n
        }
        guard i == bytes.count else { return nil }  // no trailing bytes
        return modules
    }
}
