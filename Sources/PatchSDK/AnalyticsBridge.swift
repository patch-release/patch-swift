import Foundation
import WasmKit
#if canImport(os)
import os
#endif

// MARK: - Analytics (event tracking) bridge
//
// Lets an OTA patch fire product-analytics events (track / screen) through the
// host app's analytics SDK — Firebase, Amplitude, Segment, Mixpanel, etc. There
// is no single Apple analytics API, so unlike (say) UserDefaults this bridge has
// NO canonical native symbol to auto-classify; it is invoked *deliberately* via
// the Patch SDK facade. The host injects an `AnalyticsSink` that forwards to its
// real SDK; the bridge owns only the wasm<->native marshalling + JSON parsing.
//
// Host functions (module "patch", both fire-and-forget → no return value):
//   * analytics_track(ptr,len) -> []
//       arg = JSON `{"event":"checkout_completed",
//                    "props":{"amount":42,"currency":"USD"}}`
//       Parsed into (event, props) and dispatched to `sink.track(event:props:)`.
//       Prop values are COERCED to strings (numbers/bools → their textual form)
//       so the sink sees a uniform `[String:String]`, the lowest common
//       denominator every analytics SDK accepts.
//   * analytics_screen(ptr,len) -> []
//       arg = screen name string → dispatched to `sink.screen(_:)`.
//
// Cross-platform: the default init forwards to the SDK logger / `print`, so the
// bridge is usable out of the box with no #if needed at the bridge level. Tests
// inject a spy sink.

/// The native analytics capability the host injects. Implement this to forward
/// Patch analytics events into your app's analytics SDK (Firebase, Amplitude,
/// Segment, …). Both methods are fire-and-forget.
public protocol AnalyticsSink: Sendable {
    /// Record a tracked event with string-coerced properties.
    func track(event: String, props: [String: String])
    /// Record a screen view by name.
    func screen(_ name: String)
}

public struct AnalyticsBridge: Bridge {
    public let module = "patch"
    private let sink: AnalyticsSink

    /// Cross-platform designated init — tests inject a spy `AnalyticsSink`; the
    /// host injects an adapter over its real analytics SDK.
    public init(sink: AnalyticsSink) {
        self.sink = sink
    }

    /// Convenience default init. Wires a logging sink (os unified logging where
    /// available, else `print`) so the bridge is usable out of the box and every
    /// event is observable in the console even before a real SDK is wired up.
    /// Fully cross-platform — no #if canImport(UIKit) needed.
    public init() {
        self.init(sink: LoggingAnalyticsSink())
    }

    /// Parse the `analytics_track` JSON payload into `(event, props)`.
    ///
    /// Exposed as a `static func` (mirroring `FoundationBridge.jsonGetI64`) so the
    /// pure parsing logic is unit-tested directly without a wasm instance. The
    /// registered host function calls exactly this.
    ///
    /// - Requires a top-level object with a non-empty String `"event"`.
    /// - `"props"` is optional; when present it must be an object. Each value is
    ///   coerced to a String: strings pass through; numbers/bools render via
    ///   their textual form; nested objects/arrays/null are dropped (analytics
    ///   props are flat key→scalar by convention).
    /// - Returns nil if the bytes aren't a JSON object or `"event"` is missing/empty.
    public static func parseTrack(_ bytes: [UInt8]) -> (event: String, props: [String: String])? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let event = obj["event"] as? String, !event.isEmpty else {
            return nil
        }
        var props: [String: String] = [:]
        if let rawProps = obj["props"] as? [String: Any] {
            for (key, value) in rawProps {
                if let coerced = coerce(value) {
                    props[key] = coerced
                }
            }
        }
        return (event, props)
    }

    /// Coerce a single JSON prop value to a String. Returns nil for values that
    /// are not flat scalars (nested object/array) or JSON null, so they are
    /// dropped rather than serialized as noise.
    private static func coerce(_ value: Any) -> String? {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            // NSNumber covers JSON numbers AND bools. Render bools as
            // "true"/"false"; integers without a trailing ".0"; other numbers
            // via their natural description.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            if CFNumberIsFloatType(n) {
                return "\(n.doubleValue)"
            }
            return "\(n.int64Value)"
        default:
            // NSNull, nested [String:Any], [Any] → not a flat scalar; drop it.
            return nil
        }
    }

    /// Forward a parsed track payload to the sink. Factored out of the registered
    /// host closure so the dispatch path is unit-testable with a spy sink (the
    /// closure and the tests run identical code).
    func dispatchTrack(_ parsed: (event: String, props: [String: String])) {
        sink.track(event: parsed.event, props: parsed.props)
    }

    /// Forward a screen name to the sink. Same rationale as `dispatchTrack`.
    func dispatchScreen(_ name: String) {
        sink.screen(name)
    }

    public func register(into imports: inout Imports, store: Store) {
        let bridge = self
        // analytics_track(ptr,len) -> [] — parse JSON → (event, props), dispatch.
        imports.host(module, "analytics_track", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            if let parsed = Self.parseTrack(bytes) {
                bridge.dispatchTrack(parsed)
            }
            return []
        }
        // analytics_screen(ptr,len) -> [] — the arg IS the screen name string.
        imports.host(module, "analytics_screen", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let name = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            bridge.dispatchScreen(name)
            return []
        }
    }
}

/// Default cross-platform sink: routes analytics events to `os` unified logging
/// where available, else `print`. Lets a developer SEE events out of the box
/// before wiring a real analytics SDK adapter. No #if at the bridge level —
/// platform selection is contained here.
struct LoggingAnalyticsSink: AnalyticsSink {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.patch.sdk", category: "patch-analytics")
    #endif

    func track(event: String, props: [String: String]) {
        let rendered = props
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        #if canImport(os)
        Self.logger.info("track \(event, privacy: .public) \(rendered, privacy: .public)")
        #else
        print("[patch][analytics] track \(event) \(rendered)")
        #endif
    }

    func screen(_ name: String) {
        #if canImport(os)
        Self.logger.info("screen \(name, privacy: .public)")
        #else
        print("[patch][analytics] screen \(name)")
        #endif
    }
}
