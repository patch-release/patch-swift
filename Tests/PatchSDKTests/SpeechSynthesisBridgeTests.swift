import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `SpeechSynthesisBridge` — the text-to-speech host bridge.
///
/// Two layers, per the bridge implementation guide:
///   1. `SpeechRequest.parse(_:)` — the pure JSON → SpeechRequest decode, tested
///      directly with deterministic inputs (text required → nil if missing,
///      optional rate/pitch/language, non-number/non-string coercion).
///   2. Dispatch — the registered `patch.speak` / `patch.stop_speaking` host
///      functions decode the guest arg and invoke the injected spies. Driven
///      end-to-end through WasmKit via a tiny hand-built module (imports both
///      host fns, exports `call_speak` / `call_stop_speaking`) so no shared
///      fixture is touched and the test runs on macOS without speaking.
final class SpeechSynthesisBridgeTests: XCTestCase {

    // MARK: - SpeechRequest.parse(_:) pure decode

    /// Full payload: text + all optional tuning fields decode.
    func testParseAllFields() throws {
        let req = try XCTUnwrap(SpeechRequest.parse(
            Array(#"{"text":"hello","rate":0.5,"pitch":1.0,"language":"en-US"}"#.utf8)))
        XCTAssertEqual(req.text, "hello")
        XCTAssertEqual(req.rate, 0.5)
        XCTAssertEqual(req.pitch, 1.0)
        XCTAssertEqual(req.language, "en-US")
    }

    /// Only `text` is required; the optional fields stay nil when omitted.
    func testParseTextOnlyOptionalsNil() throws {
        let req = try XCTUnwrap(SpeechRequest.parse(Array(#"{"text":"just text"}"#.utf8)))
        XCTAssertEqual(req.text, "just text")
        XCTAssertNil(req.rate, "missing rate → nil")
        XCTAssertNil(req.pitch, "missing pitch → nil")
        XCTAssertNil(req.language, "missing language → nil")
    }

    /// Missing `text` → the whole payload is rejected (nil).
    func testParseMissingTextIsNil() {
        XCTAssertNil(SpeechRequest.parse(Array(#"{"rate":0.5,"pitch":1.0}"#.utf8)))
    }

    /// Empty-string `text` is treated as missing → nil.
    func testParseEmptyTextIsNil() {
        XCTAssertNil(SpeechRequest.parse(Array(#"{"text":""}"#.utf8)))
    }

    /// Non-string `text` (wrong type) → nil.
    func testParseNonStringTextIsNil() {
        XCTAssertNil(SpeechRequest.parse(Array(#"{"text":42}"#.utf8)))
    }

    /// Integer rate/pitch coerce to Double (JSON numbers are not always floats).
    func testParseIntegerRateAndPitchCoerceToDouble() throws {
        let req = try XCTUnwrap(SpeechRequest.parse(Array(#"{"text":"hi","rate":1,"pitch":2}"#.utf8)))
        XCTAssertEqual(req.rate, 1.0)
        XCTAssertEqual(req.pitch, 2.0)
    }

    /// Non-number rate/pitch are treated as absent (stay nil), text still parses.
    func testParseNonNumberRateAndPitchTreatedAsAbsent() throws {
        let req = try XCTUnwrap(SpeechRequest.parse(
            Array(#"{"text":"hi","rate":"fast","pitch":{"x":1}}"#.utf8)))
        XCTAssertEqual(req.text, "hi")
        XCTAssertNil(req.rate, "non-number rate → nil")
        XCTAssertNil(req.pitch, "non-number pitch → nil")
    }

    /// Non-string language is treated as absent (stays nil).
    func testParseNonStringLanguageTreatedAsAbsent() throws {
        let req = try XCTUnwrap(SpeechRequest.parse(Array(#"{"text":"hi","language":123}"#.utf8)))
        XCTAssertNil(req.language)
    }

    /// Invalid / non-object JSON → nil (never throws).
    func testParseInvalidAndNonObjectJSONIsNil() {
        XCTAssertNil(SpeechRequest.parse(Array("not json at all {".utf8)))
        XCTAssertNil(SpeechRequest.parse(Array(#"["text"]"#.utf8)))   // top-level array
        XCTAssertNil(SpeechRequest.parse([]))                          // empty bytes
    }

    /// Unicode text is preserved through the decode.
    func testParsePreservesUnicode() throws {
        let req = try XCTUnwrap(SpeechRequest.parse(Array(#"{"text":"café 🎉"}"#.utf8)))
        XCTAssertEqual(req.text, "café 🎉")
    }

    /// The documented defaults are exposed for callers that fill omitted fields.
    func testDefaultsExposed() {
        XCTAssertEqual(SpeechRequest.defaultRate, 0.5)
        XCTAssertEqual(SpeechRequest.defaultPitch, 1.0)
    }

    // MARK: - Dispatch (guest -> host) through a hand-built module

    /// A minimal wasm module compiled (wat2wasm) from:
    ///   (module
    ///     (import "patch" "speak" (func $speak (param i32 i32)))
    ///     (import "patch" "stop_speaking" (func $stop))
    ///     (memory (export "memory") 1)
    ///     (global $bump (mut i32) (i32.const 1024))
    ///     (func $patch_malloc (export "patch_malloc") (param $n i32) (result i32) … bump …)
    ///     (func $patch_free (export "patch_free") (param i32))
    ///     (func (export "call_speak") (param i32 i32)
    ///       (call $speak (local.get 0) (local.get 1)))
    ///     (func (export "call_stop_speaking") (call $stop)))
    /// It forwards (ptr,len) straight to the host `patch.speak` import (and the
    /// no-arg `patch.stop_speaking`), exactly like the guest would. Embedded as
    /// base64 so the test is self-contained.
    private static let fixtureBase64 =
        "AGFzbQEAAAABEgRgAn9/AGAAAGABfwF/YAF/AAIlAgVwYXRjaAVzcGVhawAABXBhdGNoDXN0b3Bfc3BlYWtpbmcAAQMFBAIDAAEFAwEAAQYHAX8BQYAICwdIBQZtZW1vcnkCAAxwYXRjaF9tYWxsb2MAAgpwYXRjaF9mcmVlAAMKY2FsbF9zcGVhawAEEmNhbGxfc3RvcF9zcGVha2luZwAFCioEFwEBfyMAIQEjACAAakEHakF4cSQAIAELAgALCAAgACABEAALBAAQAQs="

    private func fixtureBytes() throws -> [UInt8] {
        let data = try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64))
        return [UInt8](data)
    }

    private func makeRuntime(_ bridge: SpeechSynthesisBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(bridge)
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    private func makeBridge(_ spy: SpeechSpy) -> SpeechSynthesisBridge {
        SpeechSynthesisBridge(
            speak: { request in spy.recordSpeak(request) },
            stop: { spy.recordStop() })
    }

    /// `speak` decodes the JSON arg into a `SpeechRequest` and invokes the spy.
    func testSpeakDispatchesDecodedRequest() throws {
        let spy = SpeechSpy()
        let rt = try makeRuntime(makeBridge(spy))

        let json = #"{"text":"speak me","rate":0.6,"pitch":1.2,"language":"fr-FR"}"#
        let (ptr, len) = try rt.writeBuffer([UInt8](json.utf8))
        let results = try rt.invoke("call_speak", [.i32(ptr), .i32(len)])

        XCTAssertTrue(results.isEmpty, "speak returns no value")
        XCTAssertEqual(spy.spoken.count, 1)
        XCTAssertEqual(spy.spoken.first, SpeechRequest(text: "speak me", rate: 0.6, pitch: 1.2, language: "fr-FR"))
        XCTAssertEqual(spy.stopCount, 0)
    }

    /// `speak` with text only still fires, with nil optionals.
    func testSpeakTextOnlyFiresWithNilOptionals() throws {
        let spy = SpeechSpy()
        let rt = try makeRuntime(makeBridge(spy))

        let (ptr, len) = try rt.writeBuffer([UInt8](#"{"text":"only text"}"#.utf8))
        _ = try rt.invoke("call_speak", [.i32(ptr), .i32(len)])

        XCTAssertEqual(spy.spoken.count, 1)
        let req = try XCTUnwrap(spy.spoken.first)
        XCTAssertEqual(req.text, "only text")
        XCTAssertNil(req.rate)
        XCTAssertNil(req.pitch)
        XCTAssertNil(req.language)
    }

    /// Invalid/missing-text payload is silently dropped (handler NOT invoked),
    /// and never throws back into the guest.
    func testSpeakInvalidPayloadDoesNotFire() throws {
        let spy = SpeechSpy()
        let rt = try makeRuntime(makeBridge(spy))

        let (p1, l1) = try rt.writeBuffer([UInt8]("garbage".utf8))
        _ = try rt.invoke("call_speak", [.i32(p1), .i32(l1)])
        let (p2, l2) = try rt.writeBuffer([UInt8](#"{"rate":0.5}"#.utf8))   // no text
        _ = try rt.invoke("call_speak", [.i32(p2), .i32(l2)])

        XCTAssertEqual(spy.spoken.count, 0, "no valid SpeechRequest → handler not invoked")
    }

    /// `stop_speaking` invokes the stop spy once per guest call, no args/result.
    func testStopSpeakingDispatches() throws {
        let spy = SpeechSpy()
        let rt = try makeRuntime(makeBridge(spy))

        let results = try rt.invoke("call_stop_speaking")
        XCTAssertTrue(results.isEmpty, "stop_speaking returns no value")
        XCTAssertEqual(spy.stopCount, 1)

        _ = try rt.invoke("call_stop_speaking")
        XCTAssertEqual(spy.stopCount, 2, "stop count tracks guest invocations 1:1")
        XCTAssertEqual(spy.spoken.count, 0)
    }

    /// The bridge module namespace is "patch".
    func testModuleNamespace() {
        XCTAssertEqual(makeBridge(SpeechSpy()).module, "patch")
    }

    /// Registering via a registry must not throw / double-define.
    func testRegistersWithoutConflict() throws {
        let spy = SpeechSpy()
        let registry = BridgeRegistry()
        registry.register(makeBridge(spy))
        let rt = try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
        _ = try rt.invoke("call_stop_speaking")
        XCTAssertEqual(spy.stopCount, 1)
    }
}

/// Thread-safe spy recording the speak requests / stop calls the bridge fires.
private final class SpeechSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _spoken: [SpeechRequest] = []
    private var _stopCount = 0
    func recordSpeak(_ request: SpeechRequest) {
        lock.lock(); _spoken.append(request); lock.unlock()
    }
    func recordStop() { lock.lock(); _stopCount += 1; lock.unlock() }
    var spoken: [SpeechRequest] { lock.lock(); defer { lock.unlock() }; return _spoken }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
}
