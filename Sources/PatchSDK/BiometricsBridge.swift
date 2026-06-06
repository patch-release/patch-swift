import Foundation
import WasmKit
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

// MARK: - Biometrics (FaceID / TouchID / OpticID)
//
// Exposes the device's biometric authentication to the guest. Two host
// functions under the `"patch"` namespace:
//
//   * `biometry_type() -> i32`
//        Which biometry the device supports/enrolled:
//        0 = none, 1 = TouchID, 2 = FaceID, 3 = OpticID.
//   * `biometry_evaluate(reasonPtr: i32, reasonLen: i32) -> i32`
//        Prompt the user to authenticate with biometrics, showing `reason`.
//        Returns 1 on success, 0 on failure/cancel. The guest call is
//        SYNCHRONOUS — like `URLSessionBridge.syncGet`, the host blocks on a
//        `DispatchSemaphore` until the (async) LocalAuthentication callback
//        fires, then hands the boolean back.
//
// ## Rule 2 — cross-platform core + injected native dependency
// LocalAuthentication (`LAContext`/`LAPolicy`/`LAError`) is iOS-only and will
// NOT compile under `swift test` on macOS at the top level, so the bridge stores
// the capability as two injected closures:
//   * `type:     @Sendable () -> Int32`                  → the biometry type code
//   * `evaluate: @Sendable (_ reason: String) -> Bool`   → run the policy (sync)
// Tests inject spies (always-FaceID, evaluate→true/false). The convenience
// `init()` wires the real `LAContext` /
// `LAPolicy.deviceOwnerAuthenticationWithBiometrics` path, guarded by
// `#if canImport(LocalAuthentication)`.
public struct BiometricsBridge: Bridge {
    /// Biometry kinds the device may report. Matches the host-function i32 codes.
    public enum BiometryType: Int32, Sendable {
        case none = 0
        case touchID = 1
        case faceID = 2
        case opticID = 3
    }

    public let module = "patch"

    /// Returns the device's biometry type code (0 none / 1 touchID / 2 faceID / 3 opticID).
    private let typeProvider: @Sendable () -> Int32
    /// Runs the biometric policy synchronously, showing `reason`; true = success.
    private let evaluate: @Sendable (_ reason: String) -> Bool

    /// Cross-platform designated init — tests inject spies here.
    public init(
        type typeProvider: @escaping @Sendable () -> Int32,
        evaluate: @escaping @Sendable (_ reason: String) -> Bool
    ) {
        self.typeProvider = typeProvider
        self.evaluate = evaluate
    }

    #if canImport(LocalAuthentication)
    /// Convenience default init wiring the real LocalAuthentication path.
    public init() {
        self.init(
            type: { Self.deviceBiometryType() },
            evaluate: { reason in Self.evaluateDeviceOwnerBiometrics(reason: reason) }
        )
    }

    /// Map the device's enrolled biometry to the bridge's i32 code, using a real
    /// `LAContext` and `LAPolicy.deviceOwnerAuthenticationWithBiometrics`.
    static func deviceBiometryType() -> Int32 {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return BiometryType.none.rawValue
        }
        switch ctx.biometryType {
        case .touchID: return BiometryType.touchID.rawValue
        case .faceID: return BiometryType.faceID.rawValue
        default:
            // `.opticID` exists only on visionOS / newer SDKs; reference it by
            // raw value so this compiles on SDKs that predate the enum case.
            if ctx.biometryType.rawValue == Int(BiometryType.opticID.rawValue) {
                return BiometryType.opticID.rawValue
            }
            return BiometryType.none.rawValue
        }
    }

    /// Run `deviceOwnerAuthenticationWithBiometrics` synchronously. The real
    /// `LAContext.evaluatePolicy` is async (completion handler), so block on a
    /// semaphore exactly like `URLSessionBridge.syncGet` does for the network.
    /// On any `LAError` (cancel / lockout / not enrolled) the callback reports
    /// `success == false`, so the bridge returns 0.
    static func evaluateDeviceOwnerBiometrics(reason: String) -> Bool {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        let sem = DispatchSemaphore(value: 0)
        let box = BoolBox()
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            box.set(success)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 60)
        return box.get()
    }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let typeProvider = self.typeProvider
        let evaluate = self.evaluate

        // biometry_type() -> i32 (0 none / 1 touchID / 2 faceID / 3 opticID)
        imports.host(module, "biometry_type", [], [.i32], store: store) { _, _ in
            [.i32(UInt32(bitPattern: typeProvider()))]
        }

        // biometry_evaluate(reasonPtr, reasonLen) -> i32 (1 success / 0 fail)
        imports.host(module, "biometry_evaluate", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let reason = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [.i32(evaluate(reason) ? 1 : 0)]
        }
    }
}

/// Tiny thread-safe box so the LocalAuthentication completion handler can hand
/// its result back to the blocking caller without a data-race warning. Mirrors
/// the `ByteBox` used by `URLSessionBridge.syncGet`.
private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
