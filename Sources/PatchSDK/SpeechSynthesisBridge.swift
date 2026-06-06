import Foundation
import WasmKit
// NOTE: AVFoundation is imported ONLY when available (iOS / macOS / tvOS / etc.).
// The cross-platform core + injected dependency (guide Rule 2) keeps the bridge
// struct + its `register(...)` marshalling compiling everywhere; only the
// convenience `init()` that wires the real `AVSpeechSynthesizer` is gated on
// `canImport(AVFoundation)`. AVFoundation is available on macOS too, so the
// real path also compiles in the host/test build — but tests still inject spies
// (they never speak) so CI stays silent and deterministic.
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - SpeechSynthesisBridge (text-to-speech)
//
// `speak(ptr,len)` — speak a phrase via the native TTS engine. The guest passes
// a JSON object `{"text":"…","rate":0.5,"pitch":1.0,"language":"en-US"}` as
// `(ptr,len)`; only `text` is required. The host decodes it into a
// `SpeechRequest` and hands it to an injected handler. Fire-and-forget: no
// result is returned to the guest.
//
// `stop_speaking()` — stop any in-progress / queued utterances. No args, no
// result; forwards to an injected stop handler.
//
// Cross-platform core + injected dependency (guide Rule 2): the bridge stores
// two `@Sendable` closures (speak / stop) so the whole struct + its
// `register(...)` marshalling compiles on macOS. Tests inject spies and assert
// the registered host functions decode args and invoke the injected handlers
// with the right values. The convenience `init()` (AVFoundation platforms)
// wires a real `AVSpeechSynthesizer` driving `AVSpeechUtterance`s.
//
// Mirrors `NavigationBridge` / `ShareSheetBridge` (injected handler, JSON arg,
// fire-and-forget void import).
public struct SpeechSynthesisBridge: Bridge {
    /// The injected "speak this request" native capability.
    public typealias Speak = @Sendable (_ request: SpeechRequest) -> Void
    /// The injected "stop all speech" native capability.
    public typealias Stop = @Sendable () -> Void

    public let module = "patch"
    private let speak: Speak
    private let stop: Stop

    /// Cross-platform designated init. Tests inject spies that record the decoded
    /// `SpeechRequest` / stop calls; apps can inject any custom engine.
    public init(speak: @escaping Speak, stop: @escaping Stop) {
        self.speak = speak
        self.stop = stop
    }

    #if canImport(AVFoundation)
    /// Convenience default init: wire a real `AVSpeechSynthesizer`. The
    /// synthesizer is retained for the process lifetime so utterances are not
    /// cut off when the bridge value goes out of scope, and all calls hop to the
    /// main thread (AVSpeechSynthesizer is main-thread / UI bound).
    public init() {
        let engine = NativeSpeechEngine()
        self.init(
            speak: { request in engine.speak(request) },
            stop: { engine.stop() })
    }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let speak = self.speak
        let stop = self.stop
        // speak(ptr,len) -> [] : decode JSON → SpeechRequest, forward (fire-and-forget).
        imports.host(module, "speak", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            if let request = SpeechRequest.parse(bytes) {
                speak(request)
            }
            return []
        }
        // stop_speaking() -> [] : fire-and-forget; no args, no result.
        imports.host(module, "stop_speaking", [], [], store: store) { _, _ in
            stop()
            return []
        }
    }
}

// MARK: - SpeechRequest

/// A decoded text-to-speech request. Only `text` is required; `rate`, `pitch`
/// and `language` are optional tuning knobs the native engine applies if set.
public struct SpeechRequest: Sendable, Equatable {
    /// The phrase to speak (required).
    public let text: String
    /// Speaking rate (engine-defined range; AVSpeechUtterance uses 0...1).
    public let rate: Double?
    /// Voice pitch multiplier (AVSpeechUtterance uses 0.5...2.0; 1.0 = normal).
    public let pitch: Double?
    /// BCP-47 language / voice identifier (e.g. "en-US").
    public let language: String?

    public init(text: String, rate: Double? = nil, pitch: Double? = nil, language: String? = nil) {
        self.text = text
        self.rate = rate
        self.pitch = pitch
        self.language = language
    }

    /// Default rate applied when the payload omits `rate` (mirrors the JSON
    /// example default). Exposed so callers/tests can reference the same value.
    public static let defaultRate: Double = 0.5
    /// Default pitch applied when the payload omits `pitch`.
    public static let defaultPitch: Double = 1.0

    /// Decode a `speak` JSON payload into a `SpeechRequest`.
    ///
    /// `text` is REQUIRED → returns `nil` if absent, non-string, or empty. The
    /// optional `rate`/`pitch` are read as numbers (any non-number is treated as
    /// absent → the field stays `nil`); `language` is read as a string. Invalid /
    /// non-object JSON → `nil`. Pulled out as a pure `static` func so the decode
    /// is unit-tested directly (per the bridge guide).
    public static func parse(_ bytes: [UInt8]) -> SpeechRequest? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let text = obj["text"] as? String, !text.isEmpty
        else { return nil }
        let rate = (obj["rate"] as? NSNumber)?.doubleValue
        let pitch = (obj["pitch"] as? NSNumber)?.doubleValue
        let language = obj["language"] as? String
        return SpeechRequest(text: text, rate: rate, pitch: pitch, language: language)
    }
}

// MARK: - Native engine (AVFoundation)

#if canImport(AVFoundation)
/// Wraps a long-lived `AVSpeechSynthesizer`, driving real `AVSpeechUtterance`s
/// on the main thread. Isolated from the cross-platform core so the bridge value
/// itself stays `Sendable` and the synthesizer survives past the call. A class
/// (reference type) so the same synthesizer is reused across `speak`/`stop`.
final class NativeSpeechEngine: @unchecked Sendable {
    // The synthesizer is non-Sendable; it is only ever touched on the main
    // thread (the `onMain` hops below), so its access is serialized there. The
    // engine itself is `@unchecked Sendable` because the two injected closures
    // (`speak`/`stop`) only capture `self` and forward to these methods.
    private let synthesizer = AVSpeechSynthesizer()

    /// Build an `AVSpeechUtterance` from the request (applying rate/pitch/voice
    /// when present) and speak it. Hops to the main thread if needed.
    func speak(_ request: SpeechRequest) {
        onMain {
            let utterance = AVSpeechUtterance(string: request.text)
            if let rate = request.rate { utterance.rate = Float(rate) }
            if let pitch = request.pitch { utterance.pitchMultiplier = Float(pitch) }
            if let language = request.language {
                utterance.voice = AVSpeechSynthesisVoice(language: language)
            }
            self.synthesizer.speak(utterance)
        }
    }

    /// Stop any in-progress / queued speech immediately.
    func stop() {
        onMain { self.synthesizer.stopSpeaking(at: .immediate) }
    }

    /// Run `body` on the main thread (synchronously if already there). `body`
    /// captures the non-Sendable synthesizer, so this deliberately does NOT
    /// require `@Sendable`; the engine confines all synthesizer use to main.
    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            let box = UncheckedSendableBox(body)
            DispatchQueue.main.async { box.value() }
        }
    }
}

/// Tiny wrapper that lets a non-Sendable closure cross the `DispatchQueue.main`
/// `@Sendable` boundary. Safe because the wrapped work only ever runs on main.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
#endif
