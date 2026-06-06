import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `BiometricsBridge` (FaceID / TouchID / OpticID).
///
/// Per the bridge-implementation guide we do NOT rely on the prebuilt
/// `BridgeFixture.wasm` (it does not export `call_biometry_*`). Instead this
/// suite carries its OWN tiny hand-written WASM module inline (base64 below) that
/// imports `patch.biometry_type` / `patch.biometry_evaluate` and exports callers,
/// so we can drive a REAL guest -> host round-trip: the guest forwards the
/// `(ptr,len)` reason into linear memory, the host decodes it, invokes the
/// injected spy, and encodes the i32 result back. LocalAuthentication itself is
/// iOS-only and never touched here — the native capability is injected as spies.
final class BiometricsBridgeTests: XCTestCase {

    // MARK: - Inline fixture (no bundled resource, no shared-file edits)

    /// `BiometricsFixture.wasm` (232 bytes), built from a hand-written `.wat`:
    ///   (import "patch" "biometry_type"     (func (result i32)))
    ///   (import "patch" "biometry_evaluate" (func (param i32 i32) (result i32)))
    ///   exports: memory, patch_malloc, patch_free,
    ///            call_biometry_type, call_biometry_evaluate
    private static let fixtureBase64 = """
    AGFzbQEAAAABFARgAAF/YAJ/fwF/YAF/AX9gAX8AAjECBXBhdGNoDWJpb21ldHJ5X3R5cGUAAAVw\
    YXRjaBFiaW9tZXRyeV9ldmFsdWF0ZQABAwUEAgMAAQUDAQACBgcBfwFBgAgLB1QFBm1lbW9yeQIA\
    DHBhdGNoX21hbGxvYwACCnBhdGNoX2ZyZWUAAxJjYWxsX2Jpb21ldHJ5X3R5cGUABBZjYWxsX2Jp\
    b21ldHJ5X2V2YWx1YXRlAAUKKgQXAQF/IwAhASMAIABqQQdqQXhxJAAgAQsCAAsEABAACwgAIAAg\
    ARABCw==
    """

    private func fixtureBytes() throws -> [UInt8] {
        let data = try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64,
                                      options: .ignoreUnknownCharacters))
        return [UInt8](data)
    }

    /// Build a runtime over the inline fixture with the given bridge installed.
    private func makeRuntime(_ bridge: BiometricsBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry()
        registry.register(bridge)
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    /// Allocate guest memory, write `s`, return (ptr,len).
    private func writeString(_ s: String, into rt: WASMRuntime) throws -> (UInt32, UInt32) {
        try rt.writeBuffer([UInt8](s.utf8))
    }

    // MARK: - biometry_type: dispatch + i32 encoding

    func testBiometryTypeReturnsInjectedFaceID() throws {
        let rt = try makeRuntime(BiometricsBridge(
            type: { BiometricsBridge.BiometryType.faceID.rawValue },
            evaluate: { _ in true }))
        let res = try rt.invoke("call_biometry_type")
        XCTAssertEqual(Int32(bitPattern: res[0].i32), 2, "faceID encodes as 2")
    }

    func testBiometryTypeReturnsEachKind() throws {
        let cases: [(BiometricsBridge.BiometryType, Int32)] = [
            (.none, 0), (.touchID, 1), (.faceID, 2), (.opticID, 3),
        ]
        for (kind, code) in cases {
            let rt = try makeRuntime(BiometricsBridge(type: { kind.rawValue },
                                                      evaluate: { _ in true }))
            let res = try rt.invoke("call_biometry_type")
            XCTAssertEqual(Int32(bitPattern: res[0].i32), code,
                           "\(kind) must encode as \(code)")
        }
    }

    // MARK: - biometry_evaluate: decode reason + dispatch + result encoding

    func testEvaluateSuccessDecodesReasonAndReturnsOne() throws {
        let seen = ReasonBox()
        let rt = try makeRuntime(BiometricsBridge(
            type: { BiometricsBridge.BiometryType.faceID.rawValue },
            evaluate: { reason in seen.set(reason); return true }))

        let (p, l) = try writeString("Unlock your vault", into: rt)
        let res = try rt.invoke("call_biometry_evaluate", [.i32(p), .i32(l)])

        XCTAssertEqual(Int32(bitPattern: res[0].i32), 1, "success encodes as 1")
        XCTAssertEqual(seen.get(), "Unlock your vault",
                       "the reason string must be decoded from guest memory and passed through")
    }

    func testEvaluateFailureReturnsZero() throws {
        let seen = ReasonBox()
        let rt = try makeRuntime(BiometricsBridge(
            type: { BiometricsBridge.BiometryType.touchID.rawValue },
            evaluate: { reason in seen.set(reason); return false }))

        let (p, l) = try writeString("Confirm purchase", into: rt)
        let res = try rt.invoke("call_biometry_evaluate", [.i32(p), .i32(l)])

        XCTAssertEqual(Int32(bitPattern: res[0].i32), 0, "failure/cancel encodes as 0")
        XCTAssertEqual(seen.get(), "Confirm purchase")
    }

    func testEvaluateEmptyReason() throws {
        let seen = ReasonBox()
        let rt = try makeRuntime(BiometricsBridge(
            type: { 0 },
            evaluate: { reason in seen.set(reason); return true }))
        // Empty reason → (ptr,len) == (0,0); the host must decode it as "".
        let res = try rt.invoke("call_biometry_evaluate", [.i32(0), .i32(0)])
        XCTAssertEqual(Int32(bitPattern: res[0].i32), 1)
        XCTAssertEqual(seen.get(), "")
    }

    // MARK: - Pure value mapping (no wasm)

    func testBiometryTypeRawValues() {
        XCTAssertEqual(BiometricsBridge.BiometryType.none.rawValue, 0)
        XCTAssertEqual(BiometricsBridge.BiometryType.touchID.rawValue, 1)
        XCTAssertEqual(BiometricsBridge.BiometryType.faceID.rawValue, 2)
        XCTAssertEqual(BiometricsBridge.BiometryType.opticID.rawValue, 3)
    }

    // MARK: - Registry composition

    func testRegistersWithoutError() throws {
        // The bridge installs cleanly alongside the default set (no name clashes;
        // module namespace is "patch").
        let registry = BridgeRegistry().registerDefaults()
        registry.register(BiometricsBridge(type: { 2 }, evaluate: { _ in true }))
        XCTAssertNoThrow(try WASMRuntime(bytes: try fixtureBytes(),
                                         hostImports: registry.hostImports()))
    }
}

/// Thread-safe box capturing the reason string handed to the evaluate spy.
private final class ReasonBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
