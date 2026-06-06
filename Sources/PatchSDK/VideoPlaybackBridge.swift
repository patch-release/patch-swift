import Foundation
import WasmKit
// NOTE (guide Rule 2): AVFoundation's `AVPlayer` compiles on macOS too, so the
// real path also builds in the host/test build — but the capability is injected
// as a protocol so tests drive a spy (no real playback) and the cross-platform
// core compiles everywhere.
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - VideoPlaybackBridge (media & capture — video playback)
//
// Controls a single shared video player (an `AVPlayer` on Apple platforms) via
// three host functions:
//
//   * `video_play(ptr,len) -> []`
//        The guest passes a video URL string as `(ptr,len)`. If a (non-empty,
//        parseable) URL is supplied the host loads + plays it; an empty payload
//        resumes the currently-loaded item. Fire-and-forget.
//   * `video_pause() -> []`  — pause the current item.
//   * `video_stop()  -> []`  — pause and seek back to the start (tear-down).
//
// Per the bridge guide's TWO HARD RULES the native capability is injected as a
// `VideoPlaying` protocol so the struct + its `register(...)` marshalling compile
// and unit-test on macOS. The cross-platform designated `init(player:)` takes the
// spy/impl the tests inject; the `#if canImport(AVFoundation)` convenience
// `init()` wires a real `AVPlayer`.
public struct VideoPlaybackBridge: Bridge {
    public let module = "patch"
    private let player: VideoPlaying

    /// Cross-platform designated init. Tests inject a spy conforming to
    /// `VideoPlaying`; apps can inject any custom player.
    public init(player: VideoPlaying) { self.player = player }

    #if canImport(AVFoundation)
    /// Convenience default init: wire a real `AVPlayer`-backed engine.
    public init() { self.init(player: NativeVideoPlayer()) }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let player = self.player
        // video_play(ptr,len) -> [] : load+play `url`; empty url resumes.
        imports.host(module, "video_play", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let url = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            player.play(url: Self.normalizeURL(url))
            return []
        }
        // video_pause() -> [].
        imports.host(module, "video_pause", [], [], store: store) { _, _ in
            player.pause(); return []
        }
        // video_stop() -> [].
        imports.host(module, "video_stop", [], [], store: store) { _, _ in
            player.stop(); return []
        }
    }

    /// Normalize the play payload: trim whitespace and map an empty string to
    /// `nil` (resume the loaded item). Pure `static` func so it is unit-tested
    /// directly (per the bridge guide).
    public static func normalizeURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - VideoPlaying (injected native capability)

/// The native video-playback capability the bridge drives. Conformed by the real
/// `AVPlayer` engine on Apple platforms and by a spy in tests.
public protocol VideoPlaying: Sendable {
    /// Play `url` (loading it first); a `nil` url resumes the loaded item.
    func play(url: String?)
    /// Pause the current item.
    func pause()
    /// Stop: pause and reset to the start.
    func stop()
}

// MARK: - Native engine (AVFoundation)

#if canImport(AVFoundation)
/// Wraps a long-lived `AVPlayer`. Reference type so the player survives past the
/// call; all access hops to the main thread (AVPlayer is main-thread bound).
final class NativeVideoPlayer: VideoPlaying, @unchecked Sendable {
    private let player = AVPlayer()

    func play(url urlString: String?) {
        onMain {
            if let urlString, let url = URL(string: urlString) {
                self.player.replaceCurrentItem(with: AVPlayerItem(url: url))
            }
            self.player.play()
        }
    }

    func pause() { onMain { self.player.pause() } }

    func stop() {
        onMain {
            self.player.pause()
            self.player.seek(to: .zero)
        }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            let box = UncheckedSendableBoxVP(body)
            DispatchQueue.main.async { box.value() }
        }
    }
}

/// Lets a non-Sendable closure cross the `DispatchQueue.main` `@Sendable`
/// boundary; safe because the wrapped work only ever runs on main.
private struct UncheckedSendableBoxVP<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
#endif
