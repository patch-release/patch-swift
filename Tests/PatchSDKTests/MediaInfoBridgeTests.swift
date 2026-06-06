import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `MediaInfoBridge` — publish/clear now-playing info.
///
/// Two layers (per the bridge guide):
///   1. `NowPlayingInfo.parse(_:)` — the pure JSON decode, tested directly.
///   2. Dispatch — the registered `patch.set_now_playing` / `patch.clear_now_playing`
///      host functions decode args and invoke an injected `NowPlayingPublishing`
///      spy, driven through WasmKit via a hand-built module.
final class MediaInfoBridgeTests: XCTestCase {

    // MARK: - NowPlayingInfo.parse(_:)

    func testParseAllFields() throws {
        let info = try XCTUnwrap(NowPlayingInfo.parse(Array(
            #"{"title":"Song","artist":"A","album":"B","duration":210,"elapsed":12.5,"rate":1.0}"#.utf8)))
        XCTAssertEqual(info, NowPlayingInfo(title: "Song", artist: "A", album: "B",
                                            duration: 210, elapsed: 12.5, rate: 1.0))
    }

    func testParseTitleOnlyOptionalsNil() throws {
        let info = try XCTUnwrap(NowPlayingInfo.parse(Array(#"{"title":"Solo"}"#.utf8)))
        XCTAssertEqual(info.title, "Solo")
        XCTAssertNil(info.artist); XCTAssertNil(info.album)
        XCTAssertNil(info.duration); XCTAssertNil(info.elapsed); XCTAssertNil(info.rate)
    }

    func testParseMissingOrEmptyTitleIsNil() {
        XCTAssertNil(NowPlayingInfo.parse(Array(#"{"artist":"A"}"#.utf8)))
        XCTAssertNil(NowPlayingInfo.parse(Array(#"{"title":""}"#.utf8)))
        XCTAssertNil(NowPlayingInfo.parse(Array(#"{"title":5}"#.utf8)))
        XCTAssertNil(NowPlayingInfo.parse(Array("not json".utf8)))
    }

    func testParseNonNumberDurationIsNil() throws {
        let info = try XCTUnwrap(NowPlayingInfo.parse(Array(#"{"title":"T","duration":"long"}"#.utf8)))
        XCTAssertNil(info.duration)
    }

    // MARK: - Fixture (imports patch.set_now_playing / clear_now_playing)

    private static let fixtureBase64 =
        "AGFzbQEAAAABEgRgAn9/AGAAAGABfwF/YAF/AAIzAgVwYXRjaA9zZXRfbm93X3BsYXlpbmcAAAVwYXRjaBFjbGVhcl9ub3dfcGxheWluZwABAwUEAgMAAQUDAQABBgcBfwFBgAgLB1YFBm1lbW9yeQIADHBhdGNoX21hbGxvYwACCnBhdGNoX2ZyZWUAAxRjYWxsX3NldF9ub3dfcGxheWluZwAEFmNhbGxfY2xlYXJfbm93X3BsYXlpbmcABQoqBBcBAX8jACEBIwAgAGpBB2pBeHEkACABCwIACwgAIAAgARAACwQAEAEL"

    private func fixtureBytes() throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64)))
    }

    private func makeRuntime(_ spy: NowPlayingSpy) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(MediaInfoBridge(center: spy))
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    // MARK: - Dispatch

    func testSetDecodesAndPublishes() throws {
        let spy = NowPlayingSpy()
        let rt = try makeRuntime(spy)
        let (p, l) = try rt.writeBuffer([UInt8](#"{"title":"Now","artist":"X","duration":99}"#.utf8))
        let res = try rt.invoke("call_set_now_playing", [.i32(p), .i32(l)])
        XCTAssertTrue(res.isEmpty)
        XCTAssertEqual(spy.set.count, 1)
        XCTAssertEqual(spy.set.first, NowPlayingInfo(title: "Now", artist: "X", duration: 99))
    }

    func testSetInvalidPayloadDoesNotPublish() throws {
        let spy = NowPlayingSpy()
        let rt = try makeRuntime(spy)
        let (p, l) = try rt.writeBuffer([UInt8]("garbage".utf8))
        _ = try rt.invoke("call_set_now_playing", [.i32(p), .i32(l)])
        XCTAssertEqual(spy.set.count, 0)
    }

    func testClearDispatches() throws {
        let spy = NowPlayingSpy()
        let rt = try makeRuntime(spy)
        _ = try rt.invoke("call_clear_now_playing")
        _ = try rt.invoke("call_clear_now_playing")
        XCTAssertEqual(spy.clearCount, 2)
    }

    func testModuleNamespace() {
        XCTAssertEqual(MediaInfoBridge(center: NowPlayingSpy()).module, "patch")
    }
}

/// Thread-safe spy conforming to `NowPlayingPublishing`.
private final class NowPlayingSpy: NowPlayingPublishing, @unchecked Sendable {
    private let lock = NSLock()
    private var _set: [NowPlayingInfo] = []
    private var _clear = 0
    func set(_ info: NowPlayingInfo) { lock.lock(); _set.append(info); lock.unlock() }
    func clear() { lock.lock(); _clear += 1; lock.unlock() }
    var set: [NowPlayingInfo] { lock.lock(); defer { lock.unlock() }; return _set }
    var clearCount: Int { lock.lock(); defer { lock.unlock() }; return _clear }
}
