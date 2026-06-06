import Foundation
import WasmKit
// NOTE (guide Rule 2): we render the PDF with a CoreGraphics PDF context +
// CoreText (both available AND runnable on macOS), NOT `UIGraphicsPDFRenderer`
// (UIKit-only). That keeps the real rendering path cross-platform so it is
// exercised directly in tests. CoreText is part of CoreGraphics' umbrella on
// Apple platforms; import it when available.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreText)
import CoreText
#endif

// MARK: - PDFGenerateBridge (media & capture — PDF generation)
//
// Renders text into a single-page (auto-paginated) PDF and returns the PDF
// bytes. One host function:
//
//   * `pdf_from_text(ptr,len) -> i64`
//        The guest passes a JSON object
//        `{"text":"…","fontSize":12,"pageWidth":612,"pageHeight":792,"margin":36}`
//        (`text` required) as `(ptr,len)`. The host lays the text out with
//        CoreText and renders pages into a CoreGraphics PDF context, returning
//        the bytes as a packed `(ptr,len)` (`0` on failure).
//
// The PDF-rendering capability is injected as an `@Sendable` closure so the
// struct + `register(...)` marshalling compile everywhere and tests can inject a
// spy. The real implementation lives in the pure `render(...)` static func,
// testable directly (CoreGraphics/CoreText run on macOS).
public struct PDFGenerateBridge: Bridge {
    /// The injected native capability: render a request to PDF bytes (nil on
    /// failure).
    public typealias Render = @Sendable (_ request: PDFRequest) -> [UInt8]?

    public let module = "patch"
    private let render: Render

    /// Cross-platform designated init. Tests inject a spy or the real static.
    public init(render: @escaping Render) { self.render = render }

    #if canImport(CoreGraphics) && canImport(CoreText)
    /// Convenience default init: wire the real CoreGraphics/CoreText renderer.
    public init() { self.init(render: { request in PDFGenerateBridge.render(request) }) }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let render = self.render
        // pdf_from_text(ptr,len) -> i64 packed PDF bytes (0 on failure).
        imports.host(module, "pdf_from_text", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            guard let request = PDFRequest.parse(bytes) else { return [.i64(0)] }
            return [try ctx.packedResult(render(request))]
        }
    }
}

// MARK: - PDFRequest

/// A decoded text→PDF request. `text` is required; the page geometry defaults to
/// US Letter (612×792 pt) with a 36pt margin and 12pt font.
public struct PDFRequest: Sendable, Equatable {
    /// The text to render (required).
    public let text: String
    /// Body font size in points.
    public let fontSize: Double
    /// Page width in points.
    public let pageWidth: Double
    /// Page height in points.
    public let pageHeight: Double
    /// Uniform page margin in points.
    public let margin: Double

    public init(text: String, fontSize: Double = 12, pageWidth: Double = 612,
                pageHeight: Double = 792, margin: Double = 36) {
        self.text = text
        // All geometry is GUEST-CONTROLLED. Clamp to sane bounds so a hostile
        // request can't (a) ask for an enormous mediaBox or (b) make the page so
        // small / the font so large that the paginator fits ~0 glyphs per page and
        // emits a page PER CHARACTER of a big `text` (pathological page explosion
        // → memory blow-up / hang). The caps are far past any real document.
        self.fontSize = Self.clamp(fontSize, 1, Self.maxFontSize, Self.defaultFontSize)
        self.pageWidth = Self.clamp(pageWidth, 1, Self.maxPageDimension, Self.defaultPageWidth)
        self.pageHeight = Self.clamp(pageHeight, 1, Self.maxPageDimension, Self.defaultPageHeight)
        self.margin = max(0, min(margin, Self.maxPageDimension))
    }

    /// Clamp `v` into `lo...hi`, falling back to `fallback` for a non-finite value.
    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
        guard v.isFinite else { return fallback }
        return Swift.min(hi, Swift.max(lo, v))
    }

    public static let defaultFontSize: Double = 12
    public static let defaultPageWidth: Double = 612    // US Letter
    public static let defaultPageHeight: Double = 792
    public static let defaultMargin: Double = 36
    /// DoS guards on guest-supplied geometry (points). 14_400 pt = 200 inches.
    public static let maxPageDimension: Double = 14_400
    public static let maxFontSize: Double = 1_000
    /// Hard cap on rendered pages (run-away pagination guard). 10k pages is far
    /// past any real text→PDF a patch would generate.
    public static let maxPages = 10_000

    /// Decode a `pdf_from_text` JSON payload.
    ///
    /// `text` is REQUIRED → returns `nil` if absent, non-string, or empty. The
    /// numeric geometry fields read as positive numbers (non-number / non-positive
    /// → the default). Invalid / non-object JSON → `nil`. Pure `static` func so
    /// the decode is unit-tested directly (per the bridge guide).
    public static func parse(_ bytes: [UInt8]) -> PDFRequest? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let text = obj["text"] as? String, !text.isEmpty
        else { return nil }
        func positive(_ key: String, _ fallback: Double) -> Double {
            if let n = obj[key] as? NSNumber, n.doubleValue > 0 { return n.doubleValue }
            return fallback
        }
        return PDFRequest(
            text: text,
            fontSize: positive("fontSize", defaultFontSize),
            pageWidth: positive("pageWidth", defaultPageWidth),
            pageHeight: positive("pageHeight", defaultPageHeight),
            margin: positive("margin", defaultMargin))
    }
}

// MARK: - CoreGraphics / CoreText rendering

#if canImport(CoreGraphics) && canImport(CoreText)
extension PDFGenerateBridge {
    /// Render `request.text` into a PDF (auto-paginating with CoreText framesetter)
    /// and return the PDF bytes. Returns `nil` only if the PDF context can't be
    /// created. Runs on macOS, so this is exercised directly in tests.
    public static func render(_ request: PDFRequest) -> [UInt8]? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: request.pageWidth, height: request.pageHeight)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(request.fontSize), nil)
        // Use the CoreText font attribute key (`kCTFontAttributeName`), NOT
        // `NSAttributedString.Key.font` — the latter is declared by UIKit/AppKit
        // and is absent in a pure-Foundation cross-platform (macOS host) build.
        let attributed = NSAttributedString(string: request.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)

        let textRect = CGRect(
            x: request.margin, y: request.margin,
            width: max(1, request.pageWidth - request.margin * 2),
            height: max(1, request.pageHeight - request.margin * 2))
        let path = CGPath(rect: textRect, transform: nil)

        var start = CFIndex(0)
        let total = attributed.length
        // Hard page cap: if the geometry fits almost no glyphs per page, the loop
        // advances ~1 char/page and would emit one page per character of a large
        // `text`. Bound the page count so a pathological request can't run away.
        var pages = 0
        repeat {
            pdf.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRangeMake(start, 0), path, nil)
            CTFrameDraw(frame, pdf)
            let visible = CTFrameGetVisibleStringRange(frame)
            // Advance; guard against zero-progress (e.g. a glyph too tall to fit).
            start += max(1, visible.length)
            pdf.endPDFPage()
            pages += 1
        } while start < total && pages < PDFRequest.maxPages
        pdf.closePDF()
        return [UInt8](data as Data)
    }
}
#endif
