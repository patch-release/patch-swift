import Foundation
import WasmKit
// NOTE (guide Rule 2 + the SwiftUI re-export gotcha): on macOS, importing
// MediaPlayer transitively re-exports SwiftUI, whose `Optional: Gesture`
// conformance collides with Marshalling's generic `Optional: WASMBridgeable` and
// breaks the module build. So we gate the import on
// `#if os(iOS) || os(tvOS) || os(visionOS)` (NOT canImport) and import MediaPlayer
// ONLY inside that guard. The cross-platform core + injected `NowPlayingPublishing`
// keep the struct + `register(...)` marshalling compiling and unit-testable on
// macOS; the convenience `init()` (which wires the real `MPNowPlayingInfoCenter`)
// is the only thing absent on the host build.
#if os(iOS) || os(tvOS) || os(visionOS)
import MediaPlayer
#endif

// MARK: - MediaInfoBridge (media & capture — now-playing info)
//
// Publishes "now playing" metadata to the system (lock screen / Control Center)
// via `MPNowPlayingInfoCenter`. Two host functions:
//
//   * `set_now_playing(ptr,len) -> []`
//        The guest passes a JSON object
//        `{"title":"…","artist":"…","album":"…","duration":210,"elapsed":12,"rate":1.0}`
//        (`title` required) as `(ptr,len)`. Decoded into `NowPlayingInfo` and
//        forwarded to the injected center. Fire-and-forget.
//   * `clear_now_playing() -> []`
//        Clear the published now-playing info.
//
// Per the bridge guide's TWO HARD RULES the native capability is injected as a
// `NowPlayingPublishing` protocol so the struct + `register(...)` marshalling
// compile and unit-test on macOS. The cross-platform designated
// `init(center:)` takes the spy/impl tests inject; the `#if os(iOS) || os(tvOS) || os(visionOS)`
// convenience `init()` wires the real `MPNowPlayingInfoCenter`.
public struct MediaInfoBridge: Bridge {
    public let module = "patch"
    private let center: NowPlayingPublishing

    /// Cross-platform designated init. Tests inject a spy conforming to
    /// `NowPlayingPublishing`; apps can inject any custom sink.
    public init(center: NowPlayingPublishing) { self.center = center }

    #if os(iOS) || os(tvOS) || os(visionOS)
    /// Convenience default init: wire the real `MPNowPlayingInfoCenter`.
    public init() { self.init(center: NativeNowPlayingCenter()) }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let center = self.center
        // set_now_playing(ptr,len) -> [] : decode JSON, publish (fire-and-forget).
        imports.host(module, "set_now_playing", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            if let info = NowPlayingInfo.parse(bytes) {
                center.set(info)
            }
            return []
        }
        // clear_now_playing() -> [].
        imports.host(module, "clear_now_playing", [], [], store: store) { _, _ in
            center.clear(); return []
        }
    }
}

// MARK: - NowPlayingPublishing (injected native capability)

/// The native now-playing capability the bridge drives. Conformed by the real
/// `MPNowPlayingInfoCenter` on Apple platforms and by a spy in tests.
public protocol NowPlayingPublishing: Sendable {
    /// Publish `info` as the current now-playing item.
    func set(_ info: NowPlayingInfo)
    /// Clear the published now-playing info.
    func clear()
}

// MARK: - NowPlayingInfo

/// Decoded now-playing metadata. `title` is required; the rest are optional.
public struct NowPlayingInfo: Sendable, Equatable {
    /// Track / item title (required).
    public let title: String
    /// Artist / author (optional).
    public let artist: String?
    /// Album / collection (optional).
    public let album: String?
    /// Total duration in seconds (optional).
    public let duration: Double?
    /// Elapsed playback time in seconds (optional).
    public let elapsed: Double?
    /// Playback rate (1.0 = playing, 0.0 = paused; optional).
    public let rate: Double?

    public init(title: String, artist: String? = nil, album: String? = nil,
                duration: Double? = nil, elapsed: Double? = nil, rate: Double? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.rate = rate
    }

    /// Decode a `set_now_playing` JSON payload.
    ///
    /// `title` is REQUIRED → returns `nil` if absent, non-string, or empty. The
    /// optional string fields read as strings (non-string → nil); the numeric
    /// fields read as numbers (non-number → nil). Invalid / non-object JSON →
    /// `nil`. Pure `static` func so the decode is unit-tested directly (per the
    /// bridge guide).
    public static func parse(_ bytes: [UInt8]) -> NowPlayingInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let title = obj["title"] as? String, !title.isEmpty
        else { return nil }
        return NowPlayingInfo(
            title: title,
            artist: obj["artist"] as? String,
            album: obj["album"] as? String,
            duration: (obj["duration"] as? NSNumber)?.doubleValue,
            elapsed: (obj["elapsed"] as? NSNumber)?.doubleValue,
            rate: (obj["rate"] as? NSNumber)?.doubleValue)
    }
}

// MARK: - Native center (MediaPlayer)

#if os(iOS) || os(tvOS) || os(visionOS)
/// Publishes to the real `MPNowPlayingInfoCenter`. Stateless wrapper; all calls
/// hop to the main thread (the info center is main-thread bound).
struct NativeNowPlayingCenter: NowPlayingPublishing {
    func set(_ info: NowPlayingInfo) {
        onMain {
            var dict: [String: Any] = [MPMediaItemPropertyTitle: info.title]
            if let artist = info.artist { dict[MPMediaItemPropertyArtist] = artist }
            if let album = info.album { dict[MPMediaItemPropertyAlbumTitle] = album }
            if let duration = info.duration { dict[MPMediaItemPropertyPlaybackDuration] = duration }
            if let elapsed = info.elapsed { dict[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
            if let rate = info.rate { dict[MPNowPlayingInfoPropertyPlaybackRate] = rate }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = dict
        }
    }

    func clear() {
        onMain { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
    }

    private func onMain(_ body: @escaping @Sendable () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}
#endif
