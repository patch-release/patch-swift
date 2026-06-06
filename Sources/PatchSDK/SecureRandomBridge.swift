import Foundation
import WasmKit
#if canImport(Security)
import Security
#endif

// MARK: - SecureRandom bridge (cryptographically-secure random bytes)
//
// secure_random_bytes(count: i32) -> packed-i64 blob (0 = failure / invalid count)
//
// Gives an OTA patch access to the system CSPRNG — the same source
// `SecRandomCopyBytes(kSecRandomDefault, …)` draws from — without statically
// linking the Security framework into the (Embedded) wasm. The guest asks for N
// bytes; the host fills a buffer from the secure generator and returns the bytes
// as a packed `(ptr<<32)|len` blob (0 on failure or an out-of-range count).
//
// ## Cross-platform core + injected dependency (guide Rule 2)
// The native capability (`SecRandomCopyBytes`) is injected as a
// `@Sendable (_ count: Int) -> [UInt8]?` generator so the struct + its
// `register(...)` marshalling compile + unit-test on macOS without binding the
// real Security call at the top level. Tests inject a DETERMINISTIC generator
// (e.g. a counter) and assert the requested count + dispatch. The convenience
// `init()` wires the real `SecRandomCopyBytes` under `#if canImport(Security)`.
//
// The requested count is validated by a pure `static func clampCount(_:)`:
// non-positive counts and counts above a sane cap (4096 bytes — far more than
// any key/nonce a patch needs) are rejected (→ 0). This is the single source of
// truth and is unit-tested directly.
public struct SecureRandomBridge: Bridge {
    /// Produce `count` cryptographically-secure random bytes, or nil on failure.
    /// `count` is already validated (`1...maxBytes`) by the host function.
    public typealias Generator = @Sendable (_ count: Int) -> [UInt8]?

    /// Upper bound on a single request. 4096 bytes covers every realistic use
    /// (256-bit keys, nonces, salts, tokens) while bounding a guest's allocation.
    public static let maxBytes = 4096

    public let module = "patch"
    private let generate: Generator

    /// Cross-platform designated init — tests inject a deterministic generator.
    public init(generate: @escaping Generator) { self.generate = generate }

    #if canImport(Security)
    /// Convenience default init: wires the real `SecRandomCopyBytes` CSPRNG.
    /// Guarded by `canImport(Security)` (available on every Apple platform) so
    /// the cross-platform core still compiles where Security is absent.
    public init() {
        self.init(generate: { count in
            var bytes = [UInt8](repeating: 0, count: count)
            let status = bytes.withUnsafeMutableBytes { raw -> Int32 in
                SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
            }
            return status == errSecSuccess ? bytes : nil
        })
    }
    #endif

    /// Validate a requested byte count. Returns the clamped count to request, or
    /// nil if the request is invalid (non-positive or above `maxBytes`). Pure +
    /// directly unit-tested — the single source of truth for the bounds policy.
    public static func clampCount(_ count: Int) -> Int? {
        guard count > 0, count <= maxBytes else { return nil }
        return count
    }

    /// The exact bytes the `secure_random_bytes` host function packs: validate the
    /// count, then consult the injected generator. Returns nil (→ packed 0) for an
    /// invalid count or a generator failure. Exposed (internally) so the dispatch
    /// path — count validated, generator consulted — is unit-tested without a wasm
    /// fixture exporting `call_secure_random_bytes`.
    func bytesPayload(count: Int) -> [UInt8]? {
        guard let n = Self.clampCount(count) else { return nil }
        return generate(n)
    }

    public func register(into imports: inout Imports, store: Store) {
        let bridge = self
        imports.host(module, "secure_random_bytes", [.i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let count = Int(Int32(bitPattern: args[0].i32))
            return [try ctx.packedResult(bridge.bytesPayload(count: count))]
        }
    }
}
