import Foundation
import WasmKit

// MARK: - HandoffBridge (start/stop an NSUserActivity for Handoff)
//
// Two host functions exposed to the guest:
//
//   * `start_handoff(ptr,len) -> []` — start (and make current) an
//     `NSUserActivity` describing the user's current task so it can continue on
//     another device. The guest passes a JSON object `(ptr,len)`; the host decodes
//     it into a `HandoffActivity` and hands it to an injected starter.
//   * `stop_handoff(ptr,len) -> []` — invalidate the current Handoff activity for
//     the given `activityType` string `(ptr,len)`.
//
// Both are fire-and-forget — no result is returned (like NavigationBridge).
//
// Wire format for start (`activityType` required, rest optional):
//   {"activityType":"com.acme.reading","title":"Reading",
//    "webpageURL":"https://acme.com/p/1","userInfo":{"id":"1"},
//    "eligibleForHandoff":true}
//
// ## Cross-platform core + injected dependencies (Rule 2)
// `NSUserActivity` is Foundation (it exists on macOS too), but its Handoff
// behaviour is device-bound, so we still inject the native capability as two
// `@Sendable` closures (start / stop) — keeping the bridge testable with spies and
// avoiding any live activity registration during `swift test`. The JSON decode is
// pulled into `static func parse(...)` and tested directly. The convenience
// `init()` wires real `NSUserActivity` start/stop under `#if canImport(Foundation)`.

/// A parsed Handoff activity handed to the injected starter. `activityType` is
/// required by the wire format; the rest are optional metadata.
public struct HandoffActivity: Sendable, Equatable {
    public let activityType: String
    public let title: String?
    public let webpageURL: String?
    public let userInfo: [String: String]
    public let eligibleForHandoff: Bool

    public init(
        activityType: String,
        title: String?,
        webpageURL: String?,
        userInfo: [String: String],
        eligibleForHandoff: Bool
    ) {
        self.activityType = activityType
        self.title = title
        self.webpageURL = webpageURL
        self.userInfo = userInfo
        self.eligibleForHandoff = eligibleForHandoff
    }
}

public struct HandoffBridge: Bridge {
    /// Start (and make current) the given Handoff activity.
    public typealias Start = @Sendable (_ activity: HandoffActivity) -> Void
    /// Stop / invalidate the current activity of the given type.
    public typealias Stop = @Sendable (_ activityType: String) -> Void

    public let module = "patch"
    private let start: Start
    private let stop: Stop

    /// Cross-platform designated init — tests inject spies here.
    public init(start: @escaping Start, stop: @escaping Stop) {
        self.start = start
        self.stop = stop
    }

    #if canImport(Foundation)
    /// Convenience default init wiring real `NSUserActivity`. A small thread-safe
    /// registry keeps the currently-active activities (keyed by type) so `stop`
    /// can invalidate the right one. All `NSUserActivity` mutation hops to the main
    /// thread (it is UI/responder-chain bound). Guarded by `canImport(Foundation)`
    /// (always true on Apple platforms) to mirror the guide's pattern.
    public init() {
        let store = HandoffStore()
        self.init(
            start: { activity in store.start(activity) },
            stop: { type in store.stop(type) })
    }
    #endif

    /// Decode the start payload into a `HandoffActivity`.
    ///
    /// `activityType` is required and non-empty (else nil → the host fn no-ops).
    /// `title` / `webpageURL` are optional strings. `userInfo` is a string→string
    /// map (non-string values dropped). `eligibleForHandoff` defaults to true.
    /// Pure + unit-tested directly.
    public static func parse(_ bytes: [UInt8]) -> HandoffActivity? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let activityType = obj["activityType"] as? String, !activityType.isEmpty
        else { return nil }
        let title = obj["title"] as? String
        let webpageURL = obj["webpageURL"] as? String
        var userInfo: [String: String] = [:]
        if let raw = obj["userInfo"] as? [String: Any] {
            for (k, v) in raw { if let s = v as? String { userInfo[k] = s } }
        }
        let eligible = (obj["eligibleForHandoff"] as? Bool) ?? true
        return HandoffActivity(
            activityType: activityType, title: title, webpageURL: webpageURL,
            userInfo: userInfo, eligibleForHandoff: eligible)
    }

    public func register(into imports: inout Imports, store: Store) {
        let start = self.start
        let stop = self.stop
        // start_handoff(ptr,len) -> [] : decode + start; no-op on invalid JSON.
        imports.host(module, "start_handoff", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            if let activity = Self.parse(bytes) { start(activity) }
            return []
        }
        // stop_handoff(ptr,len) -> [] : invalidate the activity of the given type.
        imports.host(module, "stop_handoff", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let type = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            stop(type)
            return []
        }
    }
}

#if canImport(Foundation)
/// Thread-safe registry of currently-active `NSUserActivity`s, keyed by type, so
/// `stop` can invalidate the matching one. All `NSUserActivity` mutation hops to
/// the main thread.
private final class HandoffStore: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [String: NSUserActivity] = [:]

    func start(_ activity: HandoffActivity) {
        // All NSUserActivity work happens on the main thread; we never capture the
        // non-Sendable NSUserActivity in a @Sendable closure (it stays inside the
        // main-thread body). `MainActor.assumeIsolated`-free path: dispatch sync.
        let work = MainThreadWork {
            let ua = NSUserActivity(activityType: activity.activityType)
            ua.title = activity.title
            if let s = activity.webpageURL, let url = URL(string: s) { ua.webpageURL = url }
            if !activity.userInfo.isEmpty { ua.userInfo = activity.userInfo }
            ua.isEligibleForHandoff = activity.eligibleForHandoff
            self.lock.lock(); self.active[activity.activityType] = ua; self.lock.unlock()
            ua.becomeCurrent()
        }
        work.run()
    }

    func stop(_ activityType: String) {
        let work = MainThreadWork {
            self.lock.lock(); let ua = self.active.removeValue(forKey: activityType); self.lock.unlock()
            ua?.invalidate()
        }
        work.run()
    }
}

/// Runs a body on the main thread (synchronously if already there, else via a
/// blocking `DispatchQueue.main.sync`) without exposing a `@Sendable` closure that
/// captures non-Sendable AppKit/Foundation objects. The body is `@unchecked
/// Sendable` because all its captured state is only ever touched on main.
private struct MainThreadWork: @unchecked Sendable {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func run() {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.sync(execute: body)
        }
    }
}
#endif
