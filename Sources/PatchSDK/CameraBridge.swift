import Foundation
import WasmKit
// NOTE (guide Rule 2 + the SwiftUI re-export gotcha): capturing a still requires
// a live camera session + (typically) UIKit presentation, which is iOS-family
// only. We deliberately gate the convenience `init()` on
// `#if os(iOS) || os(tvOS) || os(visionOS)` (NOT canImport) and import AVFoundation
// only inside that guard so the macOS host/test build never pulls a UI stack into
// the module's overload namespace. The cross-platform core + injected handler
// compile and unit-test on macOS.
#if os(iOS) || os(tvOS) || os(visionOS)
import AVFoundation
#endif

// MARK: - CameraBridge (media & capture — still photo)
//
// Captures a still photo from the device camera. One host function:
//
//   * `capture_photo(ptr,len) -> []`
//        The guest passes a JSON object
//        `{"camera":"back","flash":"auto","quality":"high"}` (all optional) as
//        `(ptr,len)`. Decoded into a `CapturePhotoRequest` and forwarded to an
//        injected handler. Fire-and-forget: the captured image is delivered to
//        the app NATIVELY (the shell drives `AVCapturePhotoOutput` + its own
//        `AVCapturePhotoCaptureDelegate` and routes the photo through its own
//        pipeline), exactly mirroring how `PhotoPickerBridge` / `ShareSheetBridge`
//        model native delivery.
//
// Per the bridge guide's TWO HARD RULES the native capability is injected as an
// `@Sendable` closure so the struct + `register(...)` marshalling compile and
// unit-test on macOS (no AVFoundation at the top level). The cross-platform
// designated `init(capture:)` takes the handler tests inject; the iOS-family
// convenience `init()` wires a real `AVCapturePhotoOutput` capture.
public struct CameraBridge: Bridge {
    /// The injected native capability: start a still capture for the given
    /// request (camera / flash / quality).
    public typealias Handler = @Sendable (_ request: CapturePhotoRequest) -> Void

    public let module = "patch"
    private let capture: Handler

    /// Cross-platform designated init. Tests inject a spy that records the decoded
    /// `CapturePhotoRequest`; apps can inject any custom capture pipeline.
    public init(capture: @escaping Handler) { self.capture = capture }

    #if os(iOS) || os(tvOS) || os(visionOS)
    /// Convenience default init: wire a real `AVCapturePhotoOutput` capture,
    /// fire-and-forget. iOS-family only (camera UI).
    public init() {
        self.init(capture: { request in
            NativeCameraCapture.shared.capture(request)
        })
    }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let capture = self.capture
        // capture_photo(ptr,len) -> [] : decode JSON, forward (fire-and-forget).
        imports.host(module, "capture_photo", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            capture(CapturePhotoRequest.parse(bytes))
            return []
        }
    }
}

// MARK: - CapturePhotoRequest

/// A decoded still-capture request. All fields optional with safe defaults.
public struct CapturePhotoRequest: Sendable, Equatable {
    /// Which camera — "back" or "front".
    public let camera: String
    /// Flash mode — "auto", "on", or "off".
    public let flash: String
    /// Quality prioritization — "speed", "balanced", or "high".
    public let quality: String

    public init(camera: String = "back", flash: String = "auto", quality: String = "balanced") {
        self.camera = camera
        self.flash = flash
        self.quality = quality
    }

    /// Decode a `capture_photo` JSON payload.
    ///
    /// All fields are optional; each is normalized to its allowed set, falling
    /// back to the default for nil / unknown values:
    ///   * camera  → "back" (default) | "front"
    ///   * flash   → "auto" (default) | "on" | "off"
    ///   * quality → "balanced" (default) | "speed" | "high"
    /// Invalid / non-object JSON → the all-defaults request (never nil; capture is
    /// fire-and-forget so a bad payload still attempts a sensible capture). Pure
    /// `static` func so the decode is unit-tested directly (per the bridge guide).
    public static func parse(_ bytes: [UInt8]) -> CapturePhotoRequest {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return CapturePhotoRequest()
        }
        return CapturePhotoRequest(
            camera: normalize(obj["camera"] as? String, allowed: ["back", "front"], default: "back"),
            flash: normalize(obj["flash"] as? String, allowed: ["auto", "on", "off"], default: "auto"),
            quality: normalize(obj["quality"] as? String, allowed: ["speed", "balanced", "high"], default: "balanced"))
    }

    /// Lowercase+trim `raw` and return it if it is in `allowed`, else `default`.
    static func normalize(_ raw: String?, allowed: Set<String>, default def: String) -> String {
        guard let raw else { return def }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowed.contains(v) ? v : def
    }
}

// MARK: - Native capture (iOS family)

#if os(iOS) || os(tvOS) || os(visionOS)
/// Drives a real `AVCaptureSession` + `AVCapturePhotoOutput` to capture a still.
/// A shared, long-lived object so the session/output survive past the
/// fire-and-forget bridge call. The captured photo is delivered to the app's own
/// pipeline (the shell installs the real delegate), so this stays fire-and-forget.
final class NativeCameraCapture: NSObject, @unchecked Sendable {
    static let shared = NativeCameraCapture()
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.patch.sdk.camera")

    /// Configure (once) and trigger a still capture for `request`. Fire-and-forget.
    func capture(_ request: CapturePhotoRequest) {
        queue.async { [self] in
            configureIfNeeded(request)
            guard session.isRunning else { return }
            let settings = AVCapturePhotoSettings()
            switch request.flash {
            case "on": settings.flashMode = .on
            case "off": settings.flashMode = .off
            default: settings.flashMode = .auto
            }
            // The shell supplies the real `AVCapturePhotoCaptureDelegate`; if it
            // hasn't installed one, the capture is still issued (no-op delivery).
            output.capturePhoto(with: settings, delegate: ShellPhotoDelegate.shared)
        }
    }

    private func configureIfNeeded(_ request: CapturePhotoRequest) {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        let position: AVCaptureDevice.Position = request.camera == "front" ? .front : .back
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
    }
}

/// A no-op default delegate so a capture issued before the shell installs its own
/// delegate doesn't crash. The real app replaces this with its own delivery sink.
final class ShellPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    static let shared = ShellPhotoDelegate()
}
#endif
