import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `AudioRecordingBridge` — start/stop audio recording to a file.
///
/// Two layers (per the bridge guide):
///   1. `AudioRecordRequest.parse(_:)` — the pure JSON decode, tested directly.
///   2. Dispatch — the registered `patch.audio_*` host functions decode args and
///      invoke an injected `AudioRecording` spy, driven through WasmKit via a
///      hand-built module (imports the three host fns, exports `call_*`).
final class AudioRecordingBridgeTests: XCTestCase {

    // MARK: - AudioRecordRequest.parse(_:)

    func testParseAllFields() throws {
        let req = try XCTUnwrap(AudioRecordRequest.parse(
            Array(#"{"path":"/tmp/a.m4a","format":"WAV","sampleRate":48000}"#.utf8)))
        XCTAssertEqual(req.path, "/tmp/a.m4a")
        XCTAssertEqual(req.format, "wav", "format is lowercased")
        XCTAssertEqual(req.sampleRate, 48000)
    }

    func testParsePathOnlyUsesDefaults() throws {
        let req = try XCTUnwrap(AudioRecordRequest.parse(Array(#"{"path":"/tmp/x.m4a"}"#.utf8)))
        XCTAssertEqual(req.format, AudioRecordRequest.defaultFormat)
        XCTAssertEqual(req.sampleRate, AudioRecordRequest.defaultSampleRate)
    }

    func testParseMissingOrEmptyPathIsNil() {
        XCTAssertNil(AudioRecordRequest.parse(Array(#"{"format":"m4a"}"#.utf8)))
        XCTAssertNil(AudioRecordRequest.parse(Array(#"{"path":""}"#.utf8)))
        XCTAssertNil(AudioRecordRequest.parse(Array(#"{"path":42}"#.utf8)))
    }

    func testParseNonPositiveOrNonNumberSampleRateFallsBack() throws {
        let zero = try XCTUnwrap(AudioRecordRequest.parse(Array(#"{"path":"/p","sampleRate":0}"#.utf8)))
        XCTAssertEqual(zero.sampleRate, AudioRecordRequest.defaultSampleRate)
        let str = try XCTUnwrap(AudioRecordRequest.parse(Array(#"{"path":"/p","sampleRate":"fast"}"#.utf8)))
        XCTAssertEqual(str.sampleRate, AudioRecordRequest.defaultSampleRate)
    }

    func testParseInvalidJSONIsNil() {
        XCTAssertNil(AudioRecordRequest.parse(Array("not json".utf8)))
        XCTAssertNil(AudioRecordRequest.parse([]))
    }

    // MARK: - Fixture (imports patch.audio_*, exports call_*)

    /// Hand-built module: imports start(ptr,len)->i32, stop()->i64,
    /// is_recording()->i32; exports the three `call_*` wrappers + memory/malloc/free.
    private static let fixtureBase64 =
        "AGFzbQEAAAABGAVgAn9/AX9gAAF+YAABf2ABfwF/YAF/AAJXAwVwYXRjaBVhdWRpb19zdGFydF9yZWNvcmRpbmcAAAVwYXRjaBRhdWRpb19zdG9wX3JlY29yZGluZwABBXBhdGNoEmF1ZGlvX2lzX3JlY29yZGluZwACAwYFAwQAAQIFAwEAAQYHAX8BQYAICwd5BgZtZW1vcnkCAAxwYXRjaF9tYWxsb2MAAwpwYXRjaF9mcmVlAAQaY2FsbF9hdWRpb19zdGFydF9yZWNvcmRpbmcABRljYWxsX2F1ZGlvX3N0b3BfcmVjb3JkaW5nAAYXY2FsbF9hdWRpb19pc19yZWNvcmRpbmcABwovBRcBAX8jACEBIwAgAGpBB2pBeHEkACABCwIACwgAIAAgARAACwQAEAELBAAQAgs="

    private func fixtureBytes() throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64)))
    }

    private func makeRuntime(_ spy: AudioSpy) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(AudioRecordingBridge(recorder: spy))
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    private func readPacked(_ packed: UInt64, from rt: WASMRuntime) throws -> [UInt8] {
        if packed == 0 { return [] }
        return try rt.read(ptr: UInt32(packed >> 32), len: UInt32(packed & 0xffff_ffff))
    }

    // MARK: - Dispatch

    func testStartDecodesRequestAndReturnsOne() throws {
        let spy = AudioSpy(startResult: true)
        let rt = try makeRuntime(spy)
        let (p, l) = try rt.writeBuffer([UInt8](#"{"path":"/tmp/r.m4a","sampleRate":22050}"#.utf8))
        let res = try rt.invoke("call_audio_start_recording", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i32, 1)
        XCTAssertEqual(spy.started.count, 1)
        XCTAssertEqual(spy.started.first, AudioRecordRequest(path: "/tmp/r.m4a", format: "m4a", sampleRate: 22050))
    }

    func testStartInvalidPayloadReturnsZeroAndDoesNotCallRecorder() throws {
        let spy = AudioSpy(startResult: true)
        let rt = try makeRuntime(spy)
        let (p, l) = try rt.writeBuffer([UInt8]("garbage".utf8))
        let res = try rt.invoke("call_audio_start_recording", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i32, 0, "bad payload → 0")
        XCTAssertEqual(spy.started.count, 0, "recorder not invoked for bad payload")
    }

    func testStartPropagatesRecorderFailure() throws {
        let spy = AudioSpy(startResult: false)   // engine refuses (already recording)
        let rt = try makeRuntime(spy)
        let (p, l) = try rt.writeBuffer([UInt8](#"{"path":"/tmp/r.m4a"}"#.utf8))
        let res = try rt.invoke("call_audio_start_recording", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i32, 0)
        XCTAssertEqual(spy.started.count, 1, "recorder was still asked")
    }

    func testStopReturnsPackedPath() throws {
        let spy = AudioSpy(startResult: true, stopPath: "/tmp/done.m4a")
        let rt = try makeRuntime(spy)
        let res = try rt.invoke("call_audio_stop_recording")
        let bytes = try readPacked(res[0].i64, from: rt)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "/tmp/done.m4a")
        XCTAssertEqual(spy.stopCount, 1)
    }

    func testStopReturnsZeroWhenNoFile() throws {
        let spy = AudioSpy(startResult: true, stopPath: nil)
        let rt = try makeRuntime(spy)
        let res = try rt.invoke("call_audio_stop_recording")
        XCTAssertEqual(res[0].i64, 0, "no file → packed 0")
    }

    func testIsRecordingReflectsSpy() throws {
        let spy = AudioSpy(startResult: true)
        let rt = try makeRuntime(spy)
        XCTAssertEqual(try rt.invoke("call_audio_is_recording")[0].i32, 0)
        spy.recording = true
        XCTAssertEqual(try rt.invoke("call_audio_is_recording")[0].i32, 1)
    }

    func testModuleNamespace() {
        XCTAssertEqual(AudioRecordingBridge(recorder: AudioSpy()).module, "patch")
    }
}

/// Thread-safe spy conforming to `AudioRecording`.
private final class AudioSpy: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private let startResult: Bool
    private let stopPath: String?
    private var _started: [AudioRecordRequest] = []
    private var _stopCount = 0
    private var _recording = false

    init(startResult: Bool = true, stopPath: String? = nil) {
        self.startResult = startResult
        self.stopPath = stopPath
    }

    func start(_ request: AudioRecordRequest) -> Bool {
        lock.lock(); _started.append(request); if startResult { _recording = true }; lock.unlock()
        return startResult
    }
    func stop() -> String? {
        lock.lock(); _stopCount += 1; _recording = false; lock.unlock(); return stopPath
    }
    var isRecording: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _recording }
    }
    var recording: Bool {
        get { isRecording }
        set { lock.lock(); _recording = newValue; lock.unlock() }
    }
    var started: [AudioRecordRequest] { lock.lock(); defer { lock.unlock() }; return _started }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
}
