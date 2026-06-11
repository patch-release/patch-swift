import Foundation
import WasmKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

// MARK: - WatchConnectivityBridge (send a message to the paired watch)
//
// `send_watch_message(ptr,len) -> []` — send a message dictionary to the paired
// Apple Watch app. The guest passes a JSON object `(ptr,len)`; the host decodes it
// into a `[String: String]` payload and hands it to an injected sender.
// Fire-and-forget — no result is returned to the guest (the watch's reply, if
// any, is delivered natively via the WCSession delegate, like NavigationBridge).
//
// Wire format: a flat JSON object of string→string pairs, e.g.
//   {"action":"refresh","id":"42"}
// (WCSession messages must be property-list types; we restrict to strings here so
// the payload is always representable and the decode is trivially testable.)
//
// ## Cross-platform core + injected dependency (Rule 2)
// `WCSession` is WatchConnectivity-only, so the native capability is injected as a
// `@Sendable ([String: String]) -> Void` sender. The bridge struct + its
// `register(...)` + the JSON decode therefore compile on macOS (no direct
// WatchConnectivity at the top level); tests inject a spy and assert the decoded
// payload. The convenience `init()` sends via `WCSession.default.sendMessage(...)`
// (only when the session is activated and the watch is reachable), guarded by
// `#if canImport(WatchConnectivity)`.
public struct WatchConnectivityBridge: Bridge {
    /// The injected native capability: deliver the message dictionary to the watch.
    public typealias Sender = @Sendable (_ message: [String: String]) -> Void

    public let module = "patch"
    private let send: Sender

    /// Cross-platform designated init — tests inject a spy here.
    public init(send: @escaping Sender) {
        self.send = send
    }

    #if canImport(WatchConnectivity)
    /// Convenience default init wiring `WCSession.default`. Activates the session
    /// once (WatchConnectivity requires an activated session with a delegate) and
    /// sends the message only when the counterpart is reachable; unreachable sends
    /// are dropped (the guest is fire-and-forget). Guarded by
    /// `canImport(WatchConnectivity)` so the macOS host build never references it.
    public init() {
        let session = WatchSessionHolder.shared
        self.init(send: { message in session.send(message) })
    }
    #endif

    /// Decode the message JSON object into a `[String: String]` payload. Only
    /// string values are kept (WCSession messages must be plist types and we
    /// restrict to strings); non-string values and non-object JSON yield an empty
    /// dictionary. Pure + unit-tested directly.
    public static func parse(_ bytes: [UInt8]) -> [String: String] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
        }
        return out
    }

    public func register(into imports: inout Imports, store: Store) {
        let send = self.send
        imports.host(module, "send_watch_message", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            send(Self.parse(bytes))
            return []
        }
    }
}

#if canImport(WatchConnectivity)
/// Lazily-activated `WCSession` holder. WatchConnectivity requires the default
/// session to be activated with a delegate before use; a single shared holder
/// owns that lifecycle. Sends are dropped when the session is unsupported, not yet
/// activated, or the counterpart is unreachable (the guest call is fire-and-forget).
private final class WatchSessionHolder: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSessionHolder()

    private override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    func send(_ message: [String: String]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    // MARK: WCSessionDelegate (minimal — we only send)
    // `WCSessionDelegate` is an `@objc` protocol, so under Swift 6 its witnesses
    // must be explicitly `@objc` (implicit-`@objc` inference for NSObject-subclass
    // protocol witnesses is no longer applied). Marking them `@objc` only makes the
    // existing ObjC dispatch explicit — behavior is unchanged.
    @objc(session:activationDidCompleteWithState:error:)
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    #if os(iOS)
    @objc func sessionDidBecomeInactive(_ session: WCSession) {}
    @objc func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate so a newly-paired watch can be reached again.
        session.activate()
    }
    #endif
}
#endif
