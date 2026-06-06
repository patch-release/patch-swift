import Foundation
import WasmKit
// NOTE (guide Rule 2): the Speech framework (`SFSpeechRecognizer`) is available
// on macOS too, so the real path compiles in the host/test build — but the
// capability is injected as a closure so tests drive a spy (no real recognition)
// and the cross-platform core compiles everywhere.
#if canImport(Speech)
import Speech
#endif

// MARK: - SpeechRecognitionBridge (media & capture — speech-to-text)
//
// Transcribes a recorded audio file to text via the native recognizer (an
// `SFSpeechRecognizer` on Apple platforms). One host function:
//
//   * `speech_transcribe(ptr,len) -> i64`
//        The guest passes a JSON object `{"path":"…","locale":"en-US"}` (only
//        `path` required) as `(ptr,len)`. The host runs recognition and returns
//        the transcript as a packed string (`0` on failure / empty result).
//
// The guest call is SYNCHRONOUS but recognition is async, so the bridge is
// sync-over-async: the injected `transcribe` closure blocks (on a semaphore in
// the real impl) and returns the final transcript. This mirrors
// `URLSessionBridge.syncGet` / `InAppPurchaseBridge`.
//
// Per the bridge guide's TWO HARD RULES the native capability is injected as an
// `@Sendable` closure so the struct + `register(...)` marshalling compile and
// unit-test on macOS. The cross-platform designated `init(transcribe:)` takes
// the spy/impl tests inject; the `#if canImport(Speech)` convenience `init()`
// wires a real `SFSpeechRecognizer`.
public struct SpeechRecognitionBridge: Bridge {
    /// The injected native capability: synchronously transcribe a request,
    /// returning the transcript (nil on failure / no speech detected).
    public typealias Transcribe = @Sendable (_ request: TranscribeRequest) -> String?

    public let module = "patch"
    private let transcribe: Transcribe

    /// Cross-platform designated init. Tests inject a spy that returns a canned
    /// transcript; apps can inject any custom recognizer.
    public init(transcribe: @escaping Transcribe) { self.transcribe = transcribe }

    #if canImport(Speech)
    /// Convenience default init: wire a real `SFSpeechRecognizer`, blocking on a
    /// semaphore so the guest's synchronous call gets the final transcript.
    public init() {
        self.init(transcribe: { request in
            NativeSpeechRecognizer.transcribeSync(request)
        })
    }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let transcribe = self.transcribe
        // speech_transcribe(ptr,len) -> i64 packed transcript (0 on failure).
        imports.host(module, "speech_transcribe", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            guard let request = TranscribeRequest.parse(bytes) else { return [.i64(0)] }
            return [try ctx.packedResult(transcribe(request))]
        }
    }
}

// MARK: - TranscribeRequest

/// A decoded transcription request. `path` is required; `locale` is an optional
/// BCP-47 recognizer locale (defaults to the device locale when omitted).
public struct TranscribeRequest: Sendable, Equatable {
    /// Path to the audio file to transcribe (required).
    public let path: String
    /// BCP-47 locale identifier for the recognizer (nil = device default).
    public let locale: String?

    public init(path: String, locale: String? = nil) {
        self.path = path
        self.locale = locale
    }

    /// Decode a `speech_transcribe` JSON payload.
    ///
    /// `path` is REQUIRED → returns `nil` if absent, non-string, or empty.
    /// `locale` is read as a string (non-string / empty → nil). Invalid /
    /// non-object JSON → `nil`. Pure `static` func so the decode is unit-tested
    /// directly (per the bridge guide).
    public static func parse(_ bytes: [UInt8]) -> TranscribeRequest? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let path = obj["path"] as? String, !path.isEmpty
        else { return nil }
        var locale = obj["locale"] as? String
        if let l = locale, l.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { locale = nil }
        return TranscribeRequest(path: path, locale: locale)
    }
}

// MARK: - Native recognizer (Speech)

#if canImport(Speech)
/// Drives a real `SFSpeechRecognizer` against a file URL, blocking on a
/// semaphore so a synchronous guest call gets the final transcript.
enum NativeSpeechRecognizer {
    /// Run recognition synchronously. Returns the best transcript, or `nil` on
    /// any failure (unavailable recognizer, no speech, timeout).
    static func transcribeSync(_ request: TranscribeRequest) -> String? {
        let locale = request.locale.map { Locale(identifier: $0) } ?? Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return nil
        }
        let url = URL(fileURLWithPath: request.path)
        let recognitionRequest = SFSpeechURLRecognitionRequest(url: url)
        recognitionRequest.shouldReportPartialResults = false

        let sem = DispatchSemaphore(value: 0)
        let box = TranscriptBox()
        let task = recognizer.recognitionTask(with: recognitionRequest) { result, error in
            if let result, result.isFinal {
                box.set(result.bestTranscription.formattedString)
                sem.signal()
            } else if error != nil {
                sem.signal()
            }
        }
        if sem.wait(timeout: .now() + 60) == .timedOut { task.cancel() }
        return box.get()
    }
}

/// Thread-safe box so the recognition callback can hand the transcript back to
/// the blocking caller without a data race.
private final class TranscriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
