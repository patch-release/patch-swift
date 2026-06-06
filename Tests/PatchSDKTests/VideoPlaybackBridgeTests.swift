import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `VideoPlaybackBridge` — play/pause/stop a video URL.
///
/// Two layers (per the bridge guide):
///   1. `VideoPlaybackBridge.normalizeURL(_:)` — the pure trim/empty→nil mapping.
///   2. Dispatch — the registered `patch.video_*` host functions decode args and
///      invoke an injected `VideoPlaying` spy, driven through WasmKit via a
///      hand-built module (imports the three host fns, exports `call_*`).
final class VideoPlaybackBridgeTests: XCTestCase {

    // MARK: - normalizeURL

    func testNormalizeURLTrims() {
        XCTAssertEqual(VideoPlaybackBridge.normalizeURL("  https://x/y.mp4  "), "https://x/y.mp4")
    }
    func testNormalizeEmptyOrWhitespaceIsNil() {
        XCTAssertNil(VideoPlaybackBridge.normalizeURL(""))
        XCTAssertNil(VideoPlaybackBridge.normalizeURL("   \n "))
    }

    // MARK: - Fixture (imports patch.video_*, exports call_*)

    private static let fixtureBase64 =
        "AGFzbQEAAAABEgRgAn9/AGAAAGABfwF/YAF/AAI7AwVwYXRjaAp2aWRlb19wbGF5AAAFcGF0Y2gLdmlkZW9fcGF1c2UAAQVwYXRjaAp2aWRlb19zdG9wAAEDBgUCAwABAQUDAQABBgcBfwFBgAgLB10GBm1lbW9yeQIADHBhdGNoX21hbGxvYwADCnBhdGNoX2ZyZWUABA9jYWxsX3ZpZGVvX3BsYXkABRBjYWxsX3ZpZGVvX3BhdXNlAAYPY2FsbF92aWRlb19zdG9wAAcKLwUXAQF/IwAhASMAIABqQQdqQXhxJAAgAQsCAAsIACAAIAEQAAsEABABCwQAEAIL"

    private func fixtureBytes() throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64)))
    }

    private func makeRuntime(_ spy: VideoSpy) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(VideoPlaybackBridge(player: spy))
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    // MARK: - Dispatch

    func testPlayForwardsURL() throws {
        let spy = VideoSpy()
        let rt = try makeRuntime(spy)
        let (p, l) = try rt.writeBuffer([UInt8]("https://cdn/v.mp4".utf8))
        let res = try rt.invoke("call_video_play", [.i32(p), .i32(l)])
        XCTAssertTrue(res.isEmpty)
        XCTAssertEqual(spy.played, [.some("https://cdn/v.mp4")])
    }

    func testPlayEmptyURLResumes() throws {
        let spy = VideoSpy()
        let rt = try makeRuntime(spy)
        let (p, l) = try rt.writeBuffer([UInt8]("".utf8))
        _ = try rt.invoke("call_video_play", [.i32(p), .i32(l)])
        XCTAssertEqual(spy.played.count, 1)
        XCTAssertEqual(spy.played.first!, Optional<String>.none, "empty url → resume (nil)")
    }

    func testPauseAndStopDispatch() throws {
        let spy = VideoSpy()
        let rt = try makeRuntime(spy)
        _ = try rt.invoke("call_video_pause")
        _ = try rt.invoke("call_video_stop")
        _ = try rt.invoke("call_video_pause")
        XCTAssertEqual(spy.pauseCount, 2)
        XCTAssertEqual(spy.stopCount, 1)
    }

    func testModuleNamespace() {
        XCTAssertEqual(VideoPlaybackBridge(player: VideoSpy()).module, "patch")
    }
}

/// Thread-safe spy conforming to `VideoPlaying`. Records the (optional) URLs
/// passed to `play` and counts pause/stop.
private final class VideoSpy: VideoPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _played: [String?] = []
    private var _pause = 0
    private var _stop = 0
    func play(url: String?) { lock.lock(); _played.append(url); lock.unlock() }
    func pause() { lock.lock(); _pause += 1; lock.unlock() }
    func stop() { lock.lock(); _stop += 1; lock.unlock() }
    var played: [String?] { lock.lock(); defer { lock.unlock() }; return _played }
    var pauseCount: Int { lock.lock(); defer { lock.unlock() }; return _pause }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stop }
}
