import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - MapsDirections bridge (open Apple Maps to a place / for directions)
//
// maps_open(ptr,len) -> i32 — open Apple Maps from a JSON request; 1 if a valid
// Maps URL was produced and handed to the opener, 0 if the request was invalid.
//
// The guest passes a JSON object describing a destination (and optional source /
// transport mode). The host builds the canonical `https://maps.apple.com/?...`
// URL and hands it to an injected opener (the real iOS shell calls
// `UIApplication.shared.open(_:)`). Building a Maps URL is the meaty, testable
// part, so it lives in a pure `static func buildURL(_:)` that is unit-tested
// directly; opening is just a closure.
//
// Request JSON (all coordinates are decimal degrees):
//   {"destLat":37.33,"destLng":-122.03}              // pin a coordinate
//   {"destAddress":"1 Infinite Loop, Cupertino"}     // pin / search an address
//   {"destLat":37.33,"destLng":-122.03,
//    "srcLat":37.78,"srcLng":-122.41,"mode":"walking"} // directions src->dest
//
// `mode` is one of "driving" | "walking" | "transit" (default "driving"); it maps
// to Apple Maps' `dirflg` (d/w/r). A request must carry EITHER dest coordinates
// (both lat+lng) OR a non-empty dest address, else it is rejected (→ 0).
//
// ## Cross-platform core + injected dependency (guide Rule 2)
// The opener is injected as `@Sendable (_ url: String) -> Bool` so the struct +
// its `register(...)` marshalling compile + unit-test on macOS without UIKit at
// the top level. Tests inject a spy recording the built URL; the convenience
// `init()` wires `UIApplication.shared.open` under `#if canImport(UIKit)`.
public struct MapsDirectionsBridge: Bridge {
    /// Open the given (already-built) Maps URL. Returns whether it was opened.
    public typealias Opener = @Sendable (_ url: String) -> Bool

    public let module = "patch"
    private let open: Opener

    /// Cross-platform designated init — tests inject a spy opener.
    public init(open: @escaping Opener) { self.open = open }

    #if canImport(UIKit)
    /// Convenience default init: wires `UIApplication.shared.open(_:)` (main-thread
    /// affine). Guarded by `canImport(UIKit)` so the cross-platform core compiles
    /// on macOS. Maps URLs use the universal `https://maps.apple.com` host which
    /// the system routes to the Maps app.
    public init() {
        self.init(open: { urlString in
            guard let url = URL(string: urlString) else { return false }
            // Concurrency hop: `UIApplication.shared.open` is main-actor-isolated;
            // opening Maps is fire-and-forget (we report success as soon as the URL is
            // valid, exactly as before), so hop onto the main actor with
            // `Task { @MainActor in … }` (capturing only the Sendable `URL`). A Task is
            // used rather than `MainActor.assumeIsolated` (iOS 17+) to keep the iOS 16
            // floor.
            Task { @MainActor in UIApplication.shared.open(url, options: [:]) }
            return true
        })
    }
    #endif

    /// A decoded Maps request. Either `destCoordinate` or `destAddress` is set.
    public struct Request: Sendable, Equatable {
        public let destLat: Double?
        public let destLng: Double?
        public let destAddress: String?
        public let srcLat: Double?
        public let srcLng: Double?
        public let mode: String   // "driving" | "walking" | "transit"
    }

    /// Parse the request JSON into a `Request`, or nil if it carries no usable
    /// destination (needs both dest coordinates OR a non-empty dest address).
    /// Pure + unit-tested directly.
    public static func parse(_ bytes: [UInt8]) -> Request? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return nil
        }
        let destLat = (obj["destLat"] as? NSNumber)?.doubleValue
        let destLng = (obj["destLng"] as? NSNumber)?.doubleValue
        let destAddress = (obj["destAddress"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCoord = destLat != nil && destLng != nil
        let hasAddress = !(destAddress ?? "").isEmpty
        guard hasCoord || hasAddress else { return nil }
        return Request(
            destLat: destLat,
            destLng: destLng,
            destAddress: hasAddress ? destAddress : nil,
            srcLat: (obj["srcLat"] as? NSNumber)?.doubleValue,
            srcLng: (obj["srcLng"] as? NSNumber)?.doubleValue,
            mode: normalizeMode(obj["mode"] as? String)
        )
    }

    /// Normalize a transport mode to "driving" | "walking" | "transit"
    /// (default "driving").
    static func normalizeMode(_ raw: String?) -> String {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "walking", "walk", "w": return "walking"
        case "transit", "transport", "r": return "transit"
        default: return "driving"
        }
    }

    /// Build the canonical `https://maps.apple.com/?...` URL for a request.
    /// Returns nil only if the request carries no destination (already guaranteed
    /// by `parse`, but re-checked so the builder is safe in isolation). Coordinate
    /// destinations use `daddr=lat,lng`; address destinations are percent-encoded
    /// into `daddr`. A source (when both src coords present) adds `saddr`. The
    /// transport mode maps to `dirflg` (d/w/r). Pure + unit-tested directly.
    public static func buildURL(_ req: Request) -> String? {
        var items: [URLQueryItem] = []
        if let lat = req.destLat, let lng = req.destLng {
            items.append(URLQueryItem(name: "daddr", value: "\(num(lat)),\(num(lng))"))
        } else if let addr = req.destAddress, !addr.isEmpty {
            items.append(URLQueryItem(name: "daddr", value: addr))
        } else {
            return nil
        }
        if let sLat = req.srcLat, let sLng = req.srcLng {
            items.append(URLQueryItem(name: "saddr", value: "\(num(sLat)),\(num(sLng))"))
        }
        items.append(URLQueryItem(name: "dirflg", value: dirFlag(req.mode)))
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "maps.apple.com"
        comps.path = "/"
        comps.queryItems = items
        return comps.url?.absoluteString
    }

    /// Apple Maps `dirflg` value for a normalized mode: d=drive, w=walk, r=transit.
    private static func dirFlag(_ mode: String) -> String {
        switch mode {
        case "walking": return "w"
        case "transit": return "r"
        default: return "d"
        }
    }

    /// Render a coordinate Double compactly (integral → no ".0").
    private static func num(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    /// The dispatch the `maps_open` host function runs: parse → build URL → open.
    /// Returns 0 if the request can't produce a Maps URL (never consulting the
    /// opener), else the opener's result as 1/0. Exposed (internally) so the
    /// parse→build→open path is unit-tested with a spy opener (no wasm fixture).
    func openPayload(_ bytes: [UInt8]) -> Int32 {
        guard let req = Self.parse(bytes), let url = Self.buildURL(req) else { return 0 }
        return open(url) ? 1 : 0
    }

    public func register(into imports: inout Imports, store: Store) {
        let bridge = self
        imports.host(module, "maps_open", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            return [.i32(UInt32(bitPattern: bridge.openPayload(bytes)))]
        }
    }
}
