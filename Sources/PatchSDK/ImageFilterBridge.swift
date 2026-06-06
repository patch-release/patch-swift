import Foundation
import WasmKit
// NOTE (guide Rule 2): CoreImage is available on macOS too, so the real
// filtering path compiles AND runs in the host/test build — this bridge is
// largely cross-platform. The filter capability is still injected as a closure
// so tests can also drive a spy, but the real `applyFilter(...)` static is
// exercised directly on macOS with deterministic pixel input.
#if canImport(CoreImage)
import CoreImage
#endif
// ImageIO provides the PNG encoder (CGImageDestination*) on every Apple platform.
#if canImport(ImageIO)
import ImageIO
#endif
// UTType constants (public.png) come from UniformTypeIdentifiers / CoreServices;
// we pass the raw UTI string, so no extra import is required.

// MARK: - ImageFilterBridge (media & capture — image filtering)
//
// Applies a named Core Image filter to encoded image bytes and returns the
// filtered image (PNG) bytes. One host function:
//
//   * `apply_filter(imgPtr,imgLen, namePtr,nameLen) -> i64`
//        The guest passes raw image bytes (PNG/JPEG) `(imgPtr,imgLen)` and a
//        filter name `(namePtr,nameLen)` (one of the curated names below, or a
//        raw `CIFilter` name). The host decodes, applies the filter, re-encodes
//        as PNG, and returns the bytes as a packed `(ptr,len)` (`0` on failure).
//
// The filter capability is injected as an `@Sendable` closure so the struct +
// `register(...)` marshalling compile on every platform and tests can inject a
// spy. The real CoreImage implementation lives in the pure `applyFilter(...)`
// static func (testable directly, since CoreImage runs on macOS).
public struct ImageFilterBridge: Bridge {
    /// The injected native capability: filter `image` bytes with the named filter,
    /// returning re-encoded bytes (nil on failure).
    public typealias Filter = @Sendable (_ image: [UInt8], _ name: String) -> [UInt8]?

    public let module = "patch"
    private let filter: Filter

    /// Cross-platform designated init. Tests inject a spy or the real static.
    public init(filter: @escaping Filter) { self.filter = filter }

    #if canImport(CoreImage)
    /// Convenience default init: wire the real CoreImage filtering path.
    public init() { self.init(filter: { image, name in ImageFilterBridge.applyFilter(image, name: name) }) }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let filter = self.filter
        // apply_filter(imgPtr,imgLen, namePtr,nameLen) -> i64 packed bytes (0 fail).
        imports.host(module, "apply_filter", [.i32, .i32, .i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let image = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            let name = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            return [try ctx.packedResult(filter(image, Self.resolveFilterName(name)))]
        }
    }

    /// Map a curated, friendly filter name to its `CIFilter` class name. Unknown
    /// names pass through unchanged (so a caller can name any `CIFilter`
    /// directly). Lowercased + trimmed first. Pure `static` func so the mapping
    /// is unit-tested directly (per the bridge guide) without CoreImage.
    public static func resolveFilterName(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sepia": return "CISepiaTone"
        case "mono", "monochrome", "noir": return "CIPhotoEffectNoir"
        case "invert", "colorinvert": return "CIColorInvert"
        case "blur", "gaussianblur": return "CIGaussianBlur"
        case "fade": return "CIPhotoEffectFade"
        case "chrome": return "CIPhotoEffectChrome"
        default: return raw   // pass through a raw CIFilter name verbatim
        }
    }
}

// MARK: - CoreImage implementation

#if canImport(CoreImage)
extension ImageFilterBridge {
    /// Apply the (already-resolved) `CIFilter` named `name` to the encoded
    /// `image` bytes and return PNG bytes. Returns `nil` if the image cannot be
    /// decoded, the filter name is unknown, or rendering/encoding fails. CoreImage
    /// runs on macOS, so this is exercised directly in tests.
    public static func applyFilter(_ image: [UInt8], name: String) -> [UInt8]? {
        guard !image.isEmpty,
              let input = CIImage(data: Data(image)),
              let filter = CIFilter(name: name) else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        // Constrain the output extent: some filters (e.g. blur) return an
        // infinite extent — fall back to the input's extent for rendering.
        let extent = output.extent.isInfinite ? input.extent : output.extent
        guard !extent.isInfinite, !extent.isEmpty else { return nil }
        let context = CIContext(options: nil)
        guard let cg = context.createCGImage(output, from: extent) else { return nil }
        return encodePNG(cg)
    }

    /// Encode a `CGImage` to PNG bytes using ImageIO (available on every Apple
    /// platform — no UIKit/AppKit needed).
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
