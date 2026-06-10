import Foundation
import Compression

/// Brotli decompression for downloaded modules.
///
/// The backend stores **both** the raw `.wasm` and a brotli-compressed
/// `.wasm.br`, and `update_check` returns the **compressed** path as
/// `module_url` (see `backend/app/services/storage.py`: `module_gcs_path`
/// is the `.br`). So the on-wire bytes the loader downloads are brotli; it must
/// inflate them before hashing/activating.
///
/// **Hashing contract (important for backend alignment):** the backend computes
/// `sha256` over the **raw, uncompressed** `.wasm` bytes
/// (`hashlib.sha256(wasm_bytes)` in `routes/modules.py`, before brotli). So the
/// loader inflates first, then verifies the inflated bytes against `sha256`.
///
/// Uses Apple's `Compression` framework (`COMPRESSION_BROTLI`, available on
/// macOS 12+ / iOS 15+ — within the SDK's macOS 14 / iOS 16 floor). Verified to
/// round-trip Python's `brotli.compress()` output. No third-party dependency.
public enum Brotli {

    public enum BrotliError: Error, CustomStringConvertible, Equatable {
        case decodeFailed
        case empty

        public var description: String {
            switch self {
            case .decodeFailed: return "brotli: decompression failed (corrupt stream?)"
            case .empty: return "brotli: empty input"
            }
        }
    }

    /// Inflate a brotli stream. `sizeHint` seeds the output buffer (use the
    /// backend-reported uncompressed `size` when known); the buffer grows
    /// automatically if the hint is too small.
    public static func decompress(_ input: Data, sizeHint: Int = 0) throws -> Data {
        guard !input.isEmpty else { throw BrotliError.empty }
        // Brotli ratios on wasm are typically 2–4x; start at 8x the input (or
        // the hint, whichever is larger) and grow on overflow.
        var capacity = max(sizeHint, max(input.count * 8, 64 * 1024))
        let maxCapacity = 512 * 1024 * 1024
        while true {
            var produced = 0
            var overflowed = false
            let dst = try decodeOnce(input, capacity: capacity, produced: &produced, overflowed: &overflowed)
            if overflowed {
                guard capacity < maxCapacity else { throw BrotliError.decodeFailed }
                capacity = min(capacity * 2, maxCapacity)
                continue
            }
            guard let dst else { throw BrotliError.decodeFailed }
            return dst.prefix(produced)
        }
    }

    private static func decodeOnce(
        _ input: Data,
        capacity: Int,
        produced: inout Int,
        overflowed: inout Bool
    ) throws -> Data? {
        var dst = Data(count: capacity)
        let n = dst.withUnsafeMutableBytes { (dstPtr: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dstPtr.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstBase, capacity,
                    srcBase, input.count,
                    nil, COMPRESSION_BROTLI)
            }
        }
        // `compression_decode_buffer` returns 0 on error OR when the source was
        // genuinely empty. When the result exactly fills `capacity` the output
        // was very likely truncated, so grow and retry to be safe.
        if n == 0 { return nil }
        if n == capacity { overflowed = true; return dst }
        produced = n
        return dst
    }
}
