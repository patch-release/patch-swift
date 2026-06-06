import XCTest
import WasmKit
@testable import PatchSDK

/// SecureRandomBridge — `patch.secure_random_bytes(count) -> packed-i64 blob`.
/// The native CSPRNG (`SecRandomCopyBytes`) is injected as a `@Sendable (Int) ->
/// [UInt8]?` generator, so these tests inject a DETERMINISTIC generator and
/// assert the count-validation policy + dispatch. Two layers:
///   1. The pure `clampCount(_:)` bounds policy, tested directly.
///   2. `bytesPayload(count:)` — the exact path the host fn packs — proving the
///      count is validated and the generator is consulted with the right value.
/// No real Security / wasm fixture required.
final class SecureRandomBridgeTests: XCTestCase {

    // MARK: - clampCount (pure bounds policy)

    func testClampCountAcceptsInRange() {
        XCTAssertEqual(SecureRandomBridge.clampCount(1), 1)
        XCTAssertEqual(SecureRandomBridge.clampCount(16), 16)
        XCTAssertEqual(SecureRandomBridge.clampCount(32), 32)
        XCTAssertEqual(SecureRandomBridge.clampCount(SecureRandomBridge.maxBytes), SecureRandomBridge.maxBytes)
    }

    func testClampCountRejectsNonPositive() {
        XCTAssertNil(SecureRandomBridge.clampCount(0))
        XCTAssertNil(SecureRandomBridge.clampCount(-1))
        XCTAssertNil(SecureRandomBridge.clampCount(Int(Int32.min)))
    }

    func testClampCountRejectsAboveCap() {
        XCTAssertNil(SecureRandomBridge.clampCount(SecureRandomBridge.maxBytes + 1))
        XCTAssertNil(SecureRandomBridge.clampCount(1_000_000))
    }

    // MARK: - Dispatch through the injected generator

    /// A deterministic generator: fills `count` bytes with their index (mod 256)
    /// and records the requested count.
    private final class SpyGenerator: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requested: [Int] = []
        var generate: SecureRandomBridge.Generator {
            { [self] count in
                lock.lock(); requested.append(count); lock.unlock()
                return (0..<count).map { UInt8($0 % 256) }
            }
        }
    }

    /// A valid count is validated, the generator is consulted with that count, and
    /// its bytes are returned verbatim.
    func testValidCountConsultsGeneratorAndReturnsBytes() {
        let spy = SpyGenerator()
        let bridge = SecureRandomBridge(generate: spy.generate)

        let payload = bridge.bytesPayload(count: 16)
        XCTAssertEqual(spy.requested, [16], "generator consulted once with the requested count")
        XCTAssertEqual(payload, (0..<16).map { UInt8($0 % 256) })
    }

    /// An invalid count never reaches the generator and yields nil (→ packed 0).
    func testInvalidCountSkipsGenerator() {
        let spy = SpyGenerator()
        let bridge = SecureRandomBridge(generate: spy.generate)

        XCTAssertNil(bridge.bytesPayload(count: 0))
        XCTAssertNil(bridge.bytesPayload(count: -5))
        XCTAssertNil(bridge.bytesPayload(count: SecureRandomBridge.maxBytes + 1))
        XCTAssertTrue(spy.requested.isEmpty, "generator must not be consulted for invalid counts")
    }

    /// A generator failure (nil) propagates as nil (→ packed 0).
    func testGeneratorFailurePropagates() {
        let bridge = SecureRandomBridge(generate: { _ in nil })
        XCTAssertNil(bridge.bytesPayload(count: 8))
    }

    // MARK: - Bridge shape / registration

    func testModuleNamespaceAndRegistration() {
        let bridge = SecureRandomBridge(generate: { count in [UInt8](repeating: 0, count: count) })
        XCTAssertEqual(bridge.module, "patch")
        let registry = BridgeRegistry().register(bridge)
        XCTAssertNotNil(registry.hostImports())
    }

    #if canImport(Security)
    /// On Security platforms the default init wires the real CSPRNG and produces
    /// the requested number of (non-trivially-zero) bytes.
    func testDefaultInitProducesRequestedBytes() {
        let bridge = SecureRandomBridge()
        let payload = bridge.bytesPayload(count: 32)
        XCTAssertEqual(payload?.count, 32, "real CSPRNG returns exactly the requested count")
    }
    #endif
}
