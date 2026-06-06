import Foundation
import CryptoKit

/// SHA-256 helper used by the loader to verify downloaded / reconstructed
/// modules against the `sha256` the backend reports in an update check.
///
/// Uses Apple `CryptoKit` (available on iOS 13+ / macOS 10.15+), so there is no
/// third-party crypto dependency and it is identical on device + simulator.
public enum SHA256Hash {
    /// Lowercase hex SHA-256 of `data`. This matches the backend, which stores
    /// `hashlib.sha256(wasm_bytes).hexdigest()` (lowercase hex of the **raw**,
    /// uncompressed `.wasm`).
    public static func hexString(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex SHA-256 of a byte array.
    public static func hexString(of bytes: [UInt8]) -> String {
        hexString(of: Data(bytes))
    }

    /// Constant-time-ish comparison of an actual digest against an expected
    /// hex string. Case-insensitive on the expected side; rejects mismatches.
    public static func verify(_ data: Data, matches expectedHex: String) -> Bool {
        let actual = hexString(of: data)
        return actual.caseInsensitiveCompare(expectedHex) == .orderedSame
    }
}
