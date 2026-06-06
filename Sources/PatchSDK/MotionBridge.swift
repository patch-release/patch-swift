import Foundation
import WasmKit
// CoreMotion's `CMMotionManager` is `@available(macOS, unavailable)` even though
// `canImport(CoreMotion)` is true on macOS — so we gate on the OS family that
// actually ships the accelerometer/gyro (iOS / watchOS / visionOS), NOT on
// `canImport`, exactly the trap the bridge guide flags for SwiftUI-style symbols.
#if os(iOS) || os(watchOS) || os(visionOS)
import CoreMotion
#endif

// MARK: - MotionSample value type
//
// A cross-platform snapshot of a one-shot inertial read: the latest
// accelerometer and gyroscope vectors. A plain `Sendable` struct (no CoreMotion
// types) so the bridge core compiles + unit-tests on macOS; the iOS shell fills
// it from `CMMotionManager` via the `#if canImport(CoreMotion)` init.
public struct MotionSample: Sendable, Equatable {
    /// Accelerometer reading in g (gravitational units), per axis.
    public let accelX: Double
    public let accelY: Double
    public let accelZ: Double
    /// Gyroscope rotation rate in radians/second, per axis.
    public let gyroX: Double
    public let gyroY: Double
    public let gyroZ: Double

    public init(
        accelX: Double, accelY: Double, accelZ: Double,
        gyroX: Double, gyroY: Double, gyroZ: Double
    ) {
        self.accelX = accelX
        self.accelY = accelY
        self.accelZ = accelZ
        self.gyroX = gyroX
        self.gyroY = gyroY
        self.gyroZ = gyroZ
    }
}

// MARK: - Motion bridge (one-shot accelerometer / gyro read)
//
// motion_read() -> packed-i64 JSON blob (0 if motion data is unavailable):
//   {"accelX":0.01,"accelY":-0.98,"accelZ":0.02,"gyroX":0.0,"gyroY":0.0,"gyroZ":0.0}
//
// A single-sample read of the device's inertial sensors — enough for orientation
// hints, shake detection, and simple tilt UIs without the patch owning a polling
// `CMMotionManager`. The native read is iOS-only, so it is injected as a
// `@Sendable () -> MotionSample?` provider (nil = sensors unavailable). Tests
// inject a fixed sample and assert the JSON; the convenience `init()` wires a
// real `CMMotionManager` one-shot read. The JSON encoding is a `static func` so
// it is unit-tested directly with deterministic inputs.
public struct MotionBridge: Bridge {
    public let module = "patch"
    private let provider: @Sendable () -> MotionSample?

    /// Cross-platform designated init: tests inject a fixed `MotionSample?`.
    public init(provider: @escaping @Sendable () -> MotionSample?) {
        self.provider = provider
    }

    #if os(iOS) || os(watchOS) || os(visionOS)
    /// Convenience default init for the iOS shell. A single `CMMotionManager` is
    /// started for device-motion updates and read on demand; the latest cached
    /// accelerometer/gyro vectors are returned (nil until the first sample lands
    /// or if the hardware is unavailable). Gated on the OS family that ships
    /// `CMMotionManager` (iOS/watchOS/visionOS) so the cross-platform core
    /// compiles on macOS, where the type is unavailable despite canImport.
    public init() {
        let manager = CMMotionManager()
        manager.accelerometerUpdateInterval = 0.1
        manager.gyroUpdateInterval = 0.1
        if manager.isAccelerometerAvailable { manager.startAccelerometerUpdates() }
        if manager.isGyroAvailable { manager.startGyroUpdates() }
        let box = MotionManagerBox(manager)
        self.init(provider: {
            let m = box.manager
            let a = m.accelerometerData?.acceleration
            let g = m.gyroData?.rotationRate
            // Require at least one live reading; otherwise report "unavailable".
            guard a != nil || g != nil else { return nil }
            return MotionSample(
                accelX: a?.x ?? 0, accelY: a?.y ?? 0, accelZ: a?.z ?? 0,
                gyroX: g?.x ?? 0, gyroY: g?.y ?? 0, gyroZ: g?.z ?? 0
            )
        })
    }
    #endif

    /// Encode a `MotionSample` into the JSON byte payload the guest receives.
    /// Pulled out (and unit-tested directly) so the round-trip is asserted without
    /// a wasm instance. Keys are emitted in a stable order; doubles render via
    /// their shortest decimal (integral values without a fractional part).
    public static func encode(_ sample: MotionSample) -> [UInt8] {
        let payload: [(String, Double)] = [
            ("accelX", sample.accelX), ("accelY", sample.accelY), ("accelZ", sample.accelZ),
            ("gyroX", sample.gyroX), ("gyroY", sample.gyroY), ("gyroZ", sample.gyroZ),
        ]
        let body = payload.map { "\"\($0.0)\":\(jsonNumber($0.1))" }.joined(separator: ",")
        return [UInt8]("{\(body)}".utf8)
    }

    /// Render a Double as a JSON number — integral values without a fractional
    /// part, fractional values via their exact shortest decimal. (JSON treats `0`
    /// and `0.0` as the same number, so this stays spec-equivalent.)
    ///
    /// Non-finite values (NaN / ±Infinity) are not valid JSON and `String(.nan)`
    /// emits the bare token `nan`, which corrupts the entire `motion_read` blob so
    /// the guest can't decode any axis. Motion samples legitimately go NaN when a
    /// sensor is unavailable/uncalibrated, so collapse them to `0`.
    private static func jsonNumber(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        if d == d.rounded() && abs(d) < 1e15 {
            return String(Int64(d))
        }
        return String(d)
    }

    /// The exact bytes the `motion_read` host function packs: consult the injected
    /// provider; nil (sensors unavailable) → nil (→ packed 0). Exposed (internally)
    /// so the dispatch path is unit-tested without a wasm fixture exporting
    /// `call_motion_read`.
    func samplePayload() -> [UInt8]? {
        guard let sample = provider() else { return nil }
        return Self.encode(sample)
    }

    public func register(into imports: inout Imports, store: Store) {
        let bridge = self
        imports.host(module, "motion_read", [], [.i64], store: store) { caller, _ in
            let ctx = BridgeContext(caller: caller)
            return [try ctx.packedResult(bridge.samplePayload())]
        }
    }
}

#if os(iOS) || os(watchOS) || os(visionOS)
/// Holds the long-lived `CMMotionManager` so the provider closure can read its
/// latest cached samples. `@unchecked Sendable` because `CMMotionManager`'s
/// cached `*Data` properties are read-only from the closure.
private final class MotionManagerBox: @unchecked Sendable {
    let manager: CMMotionManager
    init(_ manager: CMMotionManager) { self.manager = manager }
}
#endif
