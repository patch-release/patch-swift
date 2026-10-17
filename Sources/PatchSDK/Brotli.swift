// SPDX-License-Identifier: MIT

import Foundation
import CBrotliDec

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
/// Uses Google's reference Brotli decoder, vendored as the `CBrotliDec` target
/// (MIT, see `Sources/CBrotliDec/README.md`), instead of Apple's `Compression`
/// framework, so the same code path builds and behaves identically on Apple
/// platforms and Android.
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

    /// Upper bound on inflated output; a stream that would exceed it is
    /// rejected as corrupt (guards against decompression bombs).
    private static let maxOutput = 512 * 1024 * 1024

    /// Size of the scratch buffer each decoder step writes into.
    private static let chunkSize = 64 * 1024

    /// Inflate a brotli stream. `sizeHint` pre-sizes the output buffer (use the
    /// backend-reported uncompressed `size` when known); the output grows as
    /// needed if the hint is too small or absent.
    public static func decompress(_ input: Data, sizeHint: Int = 0) throws -> Data {
        guard !input.isEmpty else { throw BrotliError.empty }
        guard let state = BrotliDecoderCreateInstance(nil, nil, nil) else {
            throw BrotliError.decodeFailed
        }
        defer { BrotliDecoderDestroyInstance(state) }

        var output = Data()
        // Brotli ratios on wasm are typically 2–4x.
        output.reserveCapacity(min(max(sizeHint, input.count * 4), maxOutput))
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        return try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            var nextIn = src.bindMemory(to: UInt8.self).baseAddress
            var availableIn = src.count
            while true {
                let result = try chunk.withUnsafeMutableBufferPointer { buf -> BrotliDecoderResult in
                    var nextOut = buf.baseAddress
                    var availableOut = buf.count
                    let result = BrotliDecoderDecompressStream(
                        state, &availableIn, &nextIn, &availableOut, &nextOut, nil)
                    let produced = buf.count - availableOut
                    if produced > 0, let base = buf.baseAddress {
                        guard output.count + produced <= maxOutput else { throw BrotliError.decodeFailed }
                        output.append(base, count: produced)
                    }
                    return result
                }
                switch result {
                case BROTLI_DECODER_RESULT_SUCCESS:
                    // Trailing bytes after the end of the stream mean the
                    // payload is not a single well-formed brotli stream.
                    guard availableIn == 0 else { throw BrotliError.decodeFailed }
                    return output
                case BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT:
                    continue
                default:
                    // ERROR, or NEEDS_MORE_INPUT: all input consumed but the
                    // stream is incomplete (truncated download).
                    throw BrotliError.decodeFailed
                }
            }
        }
    }
}
