import Foundation
import WasmKit
// NOTE (guide Rule 2): AVFoundation is available on macOS too, so the real
// `AVAudioRecorder` path also compiles in the host/test build — but the native
// capability is still injected through a protocol so tests drive a spy (they
// never touch the microphone) and the cross-platform core compiles everywhere.
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - AudioRecordingBridge (media & capture — audio recording)
//
// Records microphone audio to a file via the native engine (an `AVAudioRecorder`
// on Apple platforms). Three host functions:
//
//   * `audio_start_recording(ptr,len) -> i32`
//        The guest passes a JSON object `{"path":"…","format":"m4a","sampleRate":44100}`
//        (only `path` required) as `(ptr,len)`. Decoded into an `AudioRecordRequest`
//        and forwarded to the injected recorder. Returns `1` on success, `0` on
//        failure (already recording, bad request, engine error).
//   * `audio_stop_recording() -> i64`
//        Stops the active recording and returns the written file path as a packed
//        string (`0` if not recording / no file).
//   * `audio_is_recording() -> i32`
//        `1` while a recording is in progress, else `0`.
//
// Per the bridge guide's TWO HARD RULES, the native capability is injected as an
// `AudioRecording` protocol so the struct + its `register(...)` marshalling
// compile and unit-test on macOS. The cross-platform designated `init(recorder:)`
// takes the spy/impl the tests inject; the `#if canImport(AVFoundation)`
// convenience `init()` wires a real `AVAudioRecorder`.
public struct AudioRecordingBridge: Bridge {
    public let module = "patch"
    private let recorder: AudioRecording

    /// Cross-platform designated init. Tests inject a spy conforming to
    /// `AudioRecording`; apps can inject any custom engine.
    public init(recorder: AudioRecording) { self.recorder = recorder }

    #if canImport(AVFoundation)
    /// Convenience default init: wire a real `AVAudioRecorder`-backed engine.
    public init() { self.init(recorder: NativeAudioRecorder()) }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let recorder = self.recorder
        // audio_start_recording(ptr,len) -> i32 (1 ok / 0 fail).
        imports.host(module, "audio_start_recording", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            guard let request = AudioRecordRequest.parse(bytes) else { return [.i32(0)] }
            return [.i32(recorder.start(request) ? 1 : 0)]
        }
        // audio_stop_recording() -> i64 packed path (0 if not recording).
        imports.host(module, "audio_stop_recording", [], [.i64], store: store) { caller, _ in
            let ctx = BridgeContext(caller: caller)
            return [try ctx.packedResult(recorder.stop())]
        }
        // audio_is_recording() -> i32.
        imports.host(module, "audio_is_recording", [], [.i32], store: store) { _, _ in
            [.i32(recorder.isRecording ? 1 : 0)]
        }
    }
}

// MARK: - AudioRecording (injected native capability)

/// The native audio-recording capability the bridge drives. Conformed by the
/// real `AVAudioRecorder` engine on Apple platforms and by a spy in tests.
public protocol AudioRecording: Sendable {
    /// Begin recording for `request`. Returns `false` if a recording is already
    /// active or the engine failed to start.
    func start(_ request: AudioRecordRequest) -> Bool
    /// Stop the active recording; returns the written file path (nil if none).
    func stop() -> String?
    /// `true` while a recording is in progress.
    var isRecording: Bool { get }
}

// MARK: - AudioRecordRequest

/// A decoded start-recording request. `path` is required; `format`/`sampleRate`
/// are optional tuning knobs the native engine applies if set.
public struct AudioRecordRequest: Sendable, Equatable {
    /// Destination file path (required).
    public let path: String
    /// Container/codec hint, normalized lowercase (e.g. "m4a", "caf", "wav").
    public let format: String
    /// Sample rate in Hz (defaults to 44_100).
    public let sampleRate: Double

    public init(path: String, format: String = "m4a", sampleRate: Double = 44_100) {
        self.path = path
        self.format = format
        self.sampleRate = sampleRate
    }

    /// Default container applied when the payload omits `format`.
    public static let defaultFormat = "m4a"
    /// Default sample rate applied when the payload omits `sampleRate`.
    public static let defaultSampleRate: Double = 44_100

    /// Decode a `audio_start_recording` JSON payload.
    ///
    /// `path` is REQUIRED → returns `nil` if absent, non-string, or empty.
    /// `format` is lowercased+trimmed (default "m4a"); `sampleRate` is read as a
    /// positive number (non-number / non-positive falls back to 44_100). Invalid
    /// / non-object JSON → `nil`. Pure `static` func so the decode is unit-tested
    /// directly (per the bridge guide).
    public static func parse(_ bytes: [UInt8]) -> AudioRecordRequest? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let path = obj["path"] as? String, !path.isEmpty
        else { return nil }
        let format: String
        if let raw = obj["format"] as? String,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            format = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } else {
            format = defaultFormat
        }
        let sampleRate: Double
        if let n = obj["sampleRate"] as? NSNumber, n.doubleValue > 0 {
            sampleRate = n.doubleValue
        } else {
            sampleRate = defaultSampleRate
        }
        return AudioRecordRequest(path: path, format: format, sampleRate: sampleRate)
    }
}

// MARK: - Native engine (AVFoundation)

#if canImport(AVFoundation)
/// Wraps a real `AVAudioRecorder`. Reference type so the recorder survives past
/// the `start` call and the same instance is reused by `stop`/`isRecording`.
/// `@unchecked Sendable`: the recorder is only mutated under the internal lock.
final class NativeAudioRecorder: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: AVAudioRecorder?
    private var currentPath: String?

    func start(_ request: AudioRecordRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard recorder == nil else { return false }   // already recording
        let url = URL(fileURLWithPath: request.path)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: request.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings), rec.record() else {
            return false
        }
        recorder = rec
        currentPath = request.path
        return true
    }

    func stop() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let rec = recorder else { return nil }
        rec.stop()
        let path = currentPath
        recorder = nil
        currentPath = nil
        return path
    }

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return recorder?.isRecording ?? false
    }
}
#endif
