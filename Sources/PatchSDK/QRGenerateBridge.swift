import Foundation
import WasmKit
// NOTE (guide Rule 2): this bridge is largely pure / cross-platform — CoreImage's
// `CIQRCodeGenerator` runs on macOS too, so the real generation path compiles AND
// runs in the host/test build and is exercised directly. The generator is also
// injectable for symmetry with the other bridges / for custom encoders.
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(ImageIO)
import ImageIO
#endif

// MARK: - QRGenerateBridge (media & capture — QR code generation)
//
// Generates a QR-code PNG from a string. One host function:
//
//   * `qr_generate(ptr,len) -> i64`
//        The guest passes a JSON object `{"text":"…","scale":10,"correction":"M"}`
//        (`text` required) OR a bare string (treated as the text with defaults)
//        as `(ptr,len)`. The host builds the QR code, rasterizes it as a PNG, and
//        returns the bytes as a packed `(ptr,len)` (`0` on failure).
//
// The generator is injected as an `@Sendable` closure for symmetry, but the real
// CoreImage implementation lives in the pure `generate(...)` static func, tested
// directly (CoreImage runs on macOS).
public struct QRGenerateBridge: Bridge {
    /// The injected native capability: generate QR PNG bytes for a request (nil
    /// on failure).
    public typealias Generate = @Sendable (_ request: QRRequest) -> [UInt8]?

    public let module = "patch"
    private let generate: Generate

    /// Cross-platform designated init. Tests inject a spy or the real static.
    public init(generate: @escaping Generate) { self.generate = generate }

    #if canImport(CoreImage)
    /// Convenience default init: wire the real CoreImage QR generator.
    public init() { self.init(generate: { request in QRGenerateBridge.generate(request) }) }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let generate = self.generate
        // qr_generate(ptr,len) -> i64 packed PNG bytes (0 on failure).
        imports.host(module, "qr_generate", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            guard let request = QRRequest.parse(bytes) else { return [.i64(0)] }
            return [try ctx.packedResult(generate(request))]
        }
    }
}

// MARK: - QRRequest

/// A decoded QR request: the payload `text`, an integer `scale` (output pixels
/// per QR module, the image is upscaled by this factor), and an error-`correction`
/// level (L/M/Q/H).
public struct QRRequest: Sendable, Equatable {
    /// The string to encode (required).
    public let text: String
    /// Upscale factor (pixels per QR module); clamped to `>= 1`.
    public let scale: Int
    /// Error-correction level, normalized to one of "L", "M", "Q", "H".
    public let correction: String

    public init(text: String, scale: Int = 10, correction: String = "M") {
        self.text = text
        // Clamp into 1...maxScale. `scale` is GUEST-CONTROLLED and feeds an image
        // upscale of `scale × scale` pixels per QR module: an unbounded value
        // (e.g. 100_000) asks CoreImage to rasterize a multi-trillion-pixel image,
        // exhausting memory and crashing/hanging the host. A QR module rarely
        // needs more than ~40px; 64 keeps the largest QR well under a few MB.
        self.scale = min(QRRequest.maxScale, max(1, scale))
        self.correction = QRRequest.normalizeCorrection(correction)
    }

    public static let defaultScale = 10
    public static let defaultCorrection = "M"
    /// Upper bound on the per-module upscale factor (DoS guard on a guest-supplied
    /// `scale`). 64 px/module renders even a dense QR crisply at a bounded size.
    public static let maxScale = 64

    /// Decode a `qr_generate` payload. Accepts either a JSON object
    /// `{"text":…,"scale":…,"correction":…}` OR a bare (non-JSON) string, which
    /// is taken as the `text` with default scale/correction.
    ///
    /// For the object form, `text` is REQUIRED → returns `nil` if absent /
    /// non-string / empty. `scale` clamps to `>= 1` (default 10); `correction`
    /// normalizes to L/M/Q/H (default M). Empty bytes → `nil`. Pure `static` func
    /// so the decode is unit-tested directly (per the bridge guide).
    public static func parse(_ bytes: [UInt8]) -> QRRequest? {
        if bytes.isEmpty { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] {
            guard let text = obj["text"] as? String, !text.isEmpty else { return nil }
            let scale = (obj["scale"] as? NSNumber).map { max(1, $0.intValue) } ?? defaultScale
            let correction = normalizeCorrection(obj["correction"] as? String ?? defaultCorrection)
            return QRRequest(text: text, scale: scale, correction: correction)
        }
        // Bare string fallback (not JSON): encode it verbatim with defaults.
        let s = String(decoding: bytes, as: UTF8.self)
        guard !s.isEmpty else { return nil }
        return QRRequest(text: s)
    }

    /// Normalize an error-correction level to L/M/Q/H, defaulting to "M".
    static func normalizeCorrection(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "L": return "L"
        case "Q": return "Q"
        case "H": return "H"
        default: return "M"
        }
    }
}

// MARK: - CoreImage implementation

#if canImport(CoreImage)
extension QRGenerateBridge {
    /// Generate a QR code for `request` and return PNG bytes. Returns `nil` only
    /// if the generator / rendering fails. Runs on macOS, so exercised directly
    /// in tests.
    public static func generate(_ request: QRRequest) -> [UInt8]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(request.text.utf8), forKey: "inputMessage")
        filter.setValue(request.correction, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // Upscale (nearest-neighbour to keep crisp module edges).
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: CGFloat(request.scale), y: CGFloat(request.scale)))
        let extent = scaled.extent
        guard !extent.isInfinite, !extent.isEmpty else { return nil }
        let context = CIContext(options: nil)
        guard let cg = context.createCGImage(scaled, from: extent) else { return nil }
        return encodePNG(cg)
    }

    /// Encode a `CGImage` to PNG bytes via ImageIO (no UIKit/AppKit).
    private static func encodePNG(_ cg: CGImage) -> [UInt8]? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](data as Data)
    }
}
#endif
