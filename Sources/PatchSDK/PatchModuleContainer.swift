import Foundation

/// The Patch multi-module CONTAINER format (`PMOD`) — the on-device decoder for the
/// artifact the CLI produces when a real-source/SwiftUI build adds an additive module
/// on top of the default-engine module.
///
/// ## Why a container (the multi-memory P0)
/// The default-engine module and the additive real-source module are two
/// INDEPENDENTLY-linked Swift modules. Each defines its own linear memory at base 0,
/// its own `__stack_pointer`, its own heap/allocator (`patch_malloc`) and its own
/// reactor `_initialize`/runtime metadata. Combining them into ONE wasm module is
/// unsound: keeping both memories yields a module **WasmKit 0.2.2 refuses to
/// instantiate** (`multiple memories are not permitted`); fusing the memories drops
/// the second module's allocator/`_initialize` so its exports run against the wrong
/// heap and return garbage. So the artifact instead ships both modules verbatim in a
/// container, and the SDK instantiates EACH as its own `WASMRuntime` instance (its own
/// memory/allocator/`_initialize` — sound by construction), routing each call to the
/// instance that exports the symbol.
///
/// ## Wire format (little-endian) — must match `cli`'s `PatchModuleContainer`
/// ```
/// magic   : 4 bytes  = "PMOD"  (0x50 0x4D 0x4F 0x44) — distinct from wasm "\0asm"
/// version : u8       = 1
/// count   : u8       = number of modules (>= 1)
/// reserved: u16      = 0
/// for each module: u32 length, then `length` bytes (a verbatim single-memory .wasm)
/// ```
/// A raw `.wasm` (legacy / single-module) is NOT a container; `decode` returns nil and
/// the SDK loads it as a single module exactly as before (full back-compat).
public enum PatchModuleContainer {
    /// Container magic `PMOD` — first byte `0x50` can never collide with wasm `0x00`.
    public static let magic: [UInt8] = [0x50, 0x4D, 0x4F, 0x44]
    public static let version: UInt8 = 1

    /// True iff `bytes` begins with the container magic.
    public static func isContainer(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && Array(bytes.prefix(4)) == magic
    }

    /// Decode a container blob into its constituent module byte buffers (default
    /// first). Returns nil when `bytes` is not a well-formed container — callers then
    /// treat it as a single raw `.wasm` module.
    public static func decode(_ bytes: [UInt8]) -> [[UInt8]]? {
        guard isContainer(bytes), bytes.count >= 8, bytes[4] == version else { return nil }
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
            guard n >= 0, i + n <= bytes.count else { return nil }
            modules.append(Array(bytes[i..<i + n]))
            i += n
        }
        return modules
    }

    /// Encode `modules` into a container blob (used by tests; the CLI is the producer
    /// in production).
    public static func encode(_ modules: [[UInt8]]) -> [UInt8] {
        precondition(modules.count >= 1 && modules.count <= 255, "1...255 modules")
        var out = magic
        out.append(version)
        out.append(UInt8(modules.count))
        out.append(0); out.append(0)
        for m in modules {
            let n = UInt32(m.count)
            out.append(UInt8(n & 0xFF)); out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8((n >> 16) & 0xFF)); out.append(UInt8((n >> 24) & 0xFF))
            out.append(contentsOf: m)
        }
        return out
    }
}
