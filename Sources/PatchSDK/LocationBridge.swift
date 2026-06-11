import Foundation
import WasmKit
#if canImport(CoreLocation)
import CoreLocation
#endif

// MARK: - Location (one-shot GPS) bridge
//
// `location_current()` -> packed-i64 JSON blob describing the device's current
// location fix, or `0` if location is unavailable / permission is denied. The
// guest unpacks `(ptr,len)`, reads the JSON, and frees it (the standard Patch v0
// ABI). Shape:
//
//   {"lat":37.3349,"lng":-122.009,"accuracy":5,"timestamp":1700000000000}
//
//   * lat / lng   — WGS-84 coordinate, degrees (Double).
//   * accuracy    — horizontal accuracy in meters (Double); smaller is better.
//   * timestamp   — Unix epoch MILLISECONDS the fix was taken (Int64).
//
// ## Rule 2 — cross-platform core + injected native dependency
// CoreLocation (`CLLocationManager` / `CLLocation`) requires real hardware +
// authorization and is awkward to exercise under `swift test`, so the bridge
// stores the capability as an injected `@Sendable () -> LocationFix?` provider.
// Tests inject a fixed fix and a `nil` (unavailable/denied) case and assert the
// JSON the pure `static func encode(...)` produces. The convenience default
// `init()` wires a real one-shot `CLLocationManager` request, guarded by
// `#if canImport(CoreLocation)`: it kicks a `requestLocation()` and blocks on a
// `DispatchSemaphore` (bounded wait) until the delegate callback fires — exactly
// the sync-over-async shape `URLSessionBridge.syncGet` uses for the network.

/// A single GPS fix. Injected into `LocationBridge` so the marshalling/encoding
/// is testable without CoreLocation (Rule 2). `nil` from the provider means the
/// location is unavailable or permission was denied → the host returns `0`.
public struct LocationFix: Sendable, Equatable {
    /// Latitude in degrees (WGS-84).
    public var lat: Double
    /// Longitude in degrees (WGS-84).
    public var lng: Double
    /// Horizontal accuracy in meters (smaller is better).
    public var accuracy: Double
    /// Unix epoch MILLISECONDS the fix was taken.
    public var timestamp: Int64

    public init(lat: Double, lng: Double, accuracy: Double, timestamp: Int64) {
        self.lat = lat
        self.lng = lng
        self.accuracy = accuracy
        self.timestamp = timestamp
    }
}

/// Exposes `location_current()` returning a packed-i64 JSON blob describing the
/// device's current location fix (or `0` if unavailable/denied). Inject a
/// `@Sendable () -> LocationFix?` provider for deterministic tests; the default
/// `init()` wires a one-shot `CLLocationManager` request.
public struct LocationBridge: Bridge {
    public let module = "patch"
    private let provider: @Sendable () -> LocationFix?

    /// Cross-platform designated init: the provider supplies the current fix
    /// (or `nil` when location is unavailable / denied). Tests inject here.
    public init(provider: @escaping @Sendable () -> LocationFix?) {
        self.provider = provider
    }

    #if canImport(CoreLocation)
    /// Convenience default init: perform a one-shot `CLLocationManager` request
    /// on each call, blocking on a `DispatchSemaphore` (bounded wait) for the
    /// delegate callback — the same sync-over-async pattern as
    /// `URLSessionBridge.syncGet`. Returns `nil` on denial / timeout / error.
    public init() {
        self.init(provider: { Self.requestOneShotFix() })
    }

    /// Drive a single `CLLocationManager.requestLocation()` synchronously. The
    /// CoreLocation delegate callbacks are async, so block on a semaphore with a
    /// bounded wait (like `URLSessionBridge.syncGet`). Returns the first fix, or
    /// `nil` on denial / error / timeout.
    static func requestOneShotFix(timeout: TimeInterval = 15) -> LocationFix? {
        let box = FixBox()
        let sem = DispatchSemaphore(value: 0)
        // The manager + delegate must outlive this scope until the callback
        // fires; the delegate self-retains until it signals. The delegate gates
        // on its own manager's authorization status (denied/restricted → nil).
        let delegate = OneShotLocationDelegate(box: box, semaphore: sem)
        // CoreLocation requires its manager to be created on a thread with an
        // active run loop and the delegate set before requesting. Drive it on the
        // main queue so callbacks are delivered, and wait off that queue.
        DispatchQueue.main.async {
            delegate.start()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return box.get()
    }
    #endif

    /// Pure JSON encoder for a `LocationFix`. Exposed (and unit-tested) directly
    /// so the round-trip can be asserted without a wasm instance. The key order
    /// is fixed so the output is deterministic. A `nil` fix encodes to `nil`
    /// (which `packedResult` turns into the `0` "no value" sentinel).
    public static func encode(_ fix: LocationFix?) -> [UInt8]? {
        guard let fix else { return nil }
        // Hand-rolled to guarantee key order + compact numeric form, keeping the
        // blob minimal and stable. `numberString` strips a trailing ".0" so an
        // integral coordinate/accuracy is emitted as a bare integer.
        let json = "{"
            + "\"lat\":\(numberString(fix.lat)),"
            + "\"lng\":\(numberString(fix.lng)),"
            + "\"accuracy\":\(numberString(fix.accuracy)),"
            + "\"timestamp\":\(fix.timestamp)"
            + "}"
        return [UInt8](json.utf8)
    }

    /// Render a `Double` for JSON: an integral value as a bare integer ("5"),
    /// otherwise its shortest round-trippable decimal form. Non-finite values
    /// (NaN/Inf — not valid JSON) collapse to `0`.
    static func numberString(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    public func register(into imports: inout Imports, store: Store) {
        let provider = self.provider
        imports.host(module, "location_current", [], [.i64], store: store) { caller, _ in
            let ctx = BridgeContext(caller: caller)
            return [try ctx.packedResult(Self.encode(provider()))]
        }
    }

    /// Internal accessor exercising the injected provider exactly as the
    /// registered `location_current` host closure does. Used by tests to assert
    /// dispatch.
    func currentFix() -> LocationFix? { provider() }
}

/// Tiny thread-safe box so the CoreLocation delegate callback can hand its fix
/// back to the blocking caller without a data-race warning. Mirrors the
/// `ByteBox` used by `URLSessionBridge.syncGet`.
private final class FixBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LocationFix?
    func set(_ v: LocationFix?) { lock.lock(); value = v; lock.unlock() }
    func get() -> LocationFix? { lock.lock(); defer { lock.unlock() }; return value }
}

#if canImport(CoreLocation)
/// One-shot `CLLocationManagerDelegate`: requests a single location, captures the
/// first fix (or a denial/error), signals the semaphore, and self-retains until
/// the callback fires so the bridge's blocking call resolves.
private final class OneShotLocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let box: FixBox
    private let semaphore: DispatchSemaphore
    private var finished = false
    private let lock = NSLock()
    /// Self-retain so the delegate outlives the async request.
    private var selfRef: OneShotLocationDelegate?

    init(box: FixBox, semaphore: DispatchSemaphore) {
        self.box = box
        self.semaphore = semaphore
        super.init()
        self.selfRef = self
        manager.delegate = self
    }

    /// Begin the one-shot request. Must run where the manager's run loop is live
    /// (the bridge dispatches this to the main queue).
    func start() {
        // Authorization gate: if already denied/restricted there is no point
        // starting a request (the callback would just error) — finish with nil.
        switch manager.authorizationStatus {
        case .denied, .restricted:
            finish(nil)
            return
        case .notDetermined:
            // Request when-in-use authorization; the system surfaces the prompt
            // and `locationManagerDidChangeAuthorization` fires once resolved.
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestLocation()
    }

    private func finish(_ fix: LocationFix?) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        box.set(fix)
        semaphore.signal()
        // Drop the self-retain now that we're done.
        selfRef = nil
    }

    // `CLLocationManagerDelegate` is an `@objc` protocol; under Swift 6 its
    // witnesses must be explicitly `@objc` (implicit-`@objc` inference for
    // NSObject-subclass protocol witnesses is no longer applied). Behavior
    // unchanged — only the existing ObjC dispatch is made explicit.
    @objc func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { finish(nil); return }
        let millis = Int64((loc.timestamp.timeIntervalSince1970 * 1000).rounded())
        finish(LocationFix(
            lat: loc.coordinate.latitude,
            lng: loc.coordinate.longitude,
            accuracy: loc.horizontalAccuracy,
            timestamp: millis))
    }

    @objc func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    @objc func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // If the user resolves authorization to denied/restricted, abandon the
        // request so the blocking caller isn't left waiting for the full timeout.
        switch manager.authorizationStatus {
        case .denied, .restricted: finish(nil)
        default: break
        }
    }
}
#endif
