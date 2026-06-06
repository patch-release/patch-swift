import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `SpeechRecognitionBridge` — transcribe an audio file to text.
///
/// Two layers (per the bridge guide):
///   1. `TranscribeRequest.parse(_:)` — the pure JSON decode, tested directly.
///   2. Dispatch — the registered `patch.speech_transcribe` host function decodes
///      the arg, invokes the injected (sync-over-async) `transcribe` spy, and
///      returns the transcript as a packed string. Driven through WasmKit via a
///      hand-built module (imports the host fn, exports `call_a`).
final class SpeechRecognitionBridgeTests: XCTestCase {

    // MARK: - TranscribeRequest.parse(_:)

    func testParsePathAndLocale() throws {
        let req = try XCTUnwrap(TranscribeRequest.parse(
            Array(#"{"path":"/tmp/a.m4a","locale":"fr-FR"}"#.utf8)))
        XCTAssertEqual(req.path, "/tmp/a.m4a")
        XCTAssertEqual(req.locale, "fr-FR")
    }

    func testParsePathOnlyLocaleNil() throws {
        let req = try XCTUnwrap(TranscribeRequest.parse(Array(#"{"path":"/tmp/a.m4a"}"#.utf8)))
        XCTAssertNil(req.locale)
    }

    func testParseEmptyLocaleBecomesNil() throws {
        let req = try XCTUnwrap(TranscribeRequest.parse(Array(#"{"path":"/p","locale":"  "}"#.utf8)))
        XCTAssertNil(req.locale)
    }

    func testParseMissingOrEmptyPathIsNil() {
        XCTAssertNil(TranscribeRequest.parse(Array(#"{"locale":"en-US"}"#.utf8)))
        XCTAssertNil(TranscribeRequest.parse(Array(#"{"path":""}"#.utf8)))
        XCTAssertNil(TranscribeRequest.parse(Array("not json".utf8)))
        XCTAssertNil(TranscribeRequest.parse([]))
    }

    // MARK: - Fixture (imports patch.speech_transcribe as `fn`; exports call_a)

    /// Generic single-import `(ptr,len)->i64` forwarder. The host import is named
    /// `patch.fn`, so the test bridge is registered under that name (see
    /// `makeRuntime`) — exercising the exact marshalling the real
    /// `speech_transcribe` import uses.
    private static let fixtureBase64 =
        "AGFzbQEAAAABEANgAn9/AX5gAX8Bf2ABfwACDAEFcGF0Y2gCZm4AAAMEAwECAAUDAQABBgcBfwFBgAgLBy8EBm1lbW9yeQIADHBhdGNoX21hbGxvYwABCnBhdGNoX2ZyZWUAAgZjYWxsX2EAAwolAxcBAX8jACEBIwAgAGpBB2pBeHEkACABCwIACwgAIAAgARAACw=="

    private func fixtureBytes() throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64)))
    }

    /// Registers the bridge under the fixture's import name `fn` by registering a
    /// raw host function that delegates to the bridge's transcribe path. This lets
    /// the generic `call_a` fixture drive the real decode + packing.
    private func makeRuntime(_ transcribe: @escaping @Sendable (TranscribeRequest) -> String?) throws -> WASMRuntime {
        let registry = BridgeRegistry()
        registry.registerFunction(name: "fn", parameters: [.i32, .i32], results: [.i64]) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            guard let request = TranscribeRequest.parse(bytes) else { return [.i64(0)] }
            return [try ctx.packedResult(transcribe(request))]
        }
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    private func readPacked(_ packed: UInt64, from rt: WASMRuntime) throws -> [UInt8] {
        if packed == 0 { return [] }
        return try rt.read(ptr: UInt32(packed >> 32), len: UInt32(packed & 0xffff_ffff))
    }

    // MARK: - Dispatch

    func testTranscribeReturnsPackedTranscript() throws {
        let captured = RequestBox()
        let rt = try makeRuntime { req in captured.set(req); return "hello world" }
        let (p, l) = try rt.writeBuffer([UInt8](#"{"path":"/tmp/a.m4a","locale":"en-US"}"#.utf8))
        let res = try rt.invoke("call_a", [.i32(p), .i32(l)])
        let bytes = try readPacked(res[0].i64, from: rt)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "hello world")
        XCTAssertEqual(captured.get(), TranscribeRequest(path: "/tmp/a.m4a", locale: "en-US"))
    }

    func testTranscribeNilResultPacksZero() throws {
        let rt = try makeRuntime { _ in nil }   // recognizer found no speech
        let (p, l) = try rt.writeBuffer([UInt8](#"{"path":"/tmp/a.m4a"}"#.utf8))
        let res = try rt.invoke("call_a", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i64, 0, "nil transcript → packed 0")
    }

    func testTranscribeInvalidPayloadPacksZeroWithoutCallingEngine() throws {
        let calls = CounterBox()
        let rt = try makeRuntime { _ in calls.bump(); return "x" }
        let (p, l) = try rt.writeBuffer([UInt8]("garbage".utf8))
        let res = try rt.invoke("call_a", [.i32(p), .i32(l)])
        XCTAssertEqual(res[0].i64, 0)
        XCTAssertEqual(calls.value, 0, "bad payload → engine not invoked")
    }

    func testModuleNamespace() {
        XCTAssertEqual(SpeechRecognitionBridge(transcribe: { _ in nil }).module, "patch")
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: TranscribeRequest?
    func set(_ r: TranscribeRequest) { lock.lock(); v = r; lock.unlock() }
    func get() -> TranscribeRequest? { lock.lock(); defer { lock.unlock() }; return v }
}
private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
