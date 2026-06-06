import XCTest
import WasmKit
@testable import PatchSDK

/// Tests for `ImageFilterBridge` — apply a named filter to image bytes.
///
/// Layers (per the bridge guide):
///   1. `resolveFilterName(_:)` — the pure friendly-name → CIFilter-name mapping.
///   2. `applyFilter(_:name:)` — the real CoreImage path, exercised directly on
///      macOS with a tiny embedded PNG (CoreImage runs on the host).
///   3. Dispatch — the registered `patch.apply_filter` host fn decodes both args
///      and packs the bytes the injected filter returns. Driven through WasmKit.
final class ImageFilterBridgeTests: XCTestCase {

    /// A valid 4×4 RGBA PNG (generated deterministically) used as filter input.
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAABKADAAQAAAABAAAABAAAAADmpNw4AAAAJUlEQVQIHWNkSNnyX4OBgQGGWRYgcTSBbJaFSAIgSbAKkAxMCwAQRgZgRYhLRQAAAABJRU5ErkJggg=="

    private func samplePNG() throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: Self.pngBase64)))
    }

    // MARK: - resolveFilterName

    func testResolveFriendlyNames() {
        XCTAssertEqual(ImageFilterBridge.resolveFilterName("sepia"), "CISepiaTone")
        XCTAssertEqual(ImageFilterBridge.resolveFilterName(" Noir "), "CIPhotoEffectNoir")
        XCTAssertEqual(ImageFilterBridge.resolveFilterName("INVERT"), "CIColorInvert")
        XCTAssertEqual(ImageFilterBridge.resolveFilterName("blur"), "CIGaussianBlur")
    }
    func testResolveUnknownPassesThrough() {
        XCTAssertEqual(ImageFilterBridge.resolveFilterName("CIBloom"), "CIBloom")
    }

    // MARK: - applyFilter (real CoreImage on macOS)

    func testApplyRealSepiaProducesPNG() throws {
        let out = try XCTUnwrap(ImageFilterBridge.applyFilter(try samplePNG(), name: "CISepiaTone"))
        XCTAssertFalse(out.isEmpty)
        // PNG magic number.
        XCTAssertEqual(Array(out.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testApplyInvalidInputBytesReturnsNil() {
        XCTAssertNil(ImageFilterBridge.applyFilter([0, 1, 2, 3], name: "CISepiaTone"))
        XCTAssertNil(ImageFilterBridge.applyFilter([], name: "CISepiaTone"))
    }

    func testApplyUnknownFilterReturnsNil() throws {
        XCTAssertNil(ImageFilterBridge.applyFilter(try samplePNG(), name: "CINotARealFilter"))
    }

    // MARK: - Fixture (imports patch.apply_filter; exports call_apply_filter)

    private static let fixtureBase64 =
        "AGFzbQEAAAABEgNgBH9/f38BfmABfwF/YAF/AAIWAQVwYXRjaAxhcHBseV9maWx0ZXIAAAMEAwECAAUDAQABBgcBfwFBgAgLBzoEBm1lbW9yeQIADHBhdGNoX21hbGxvYwABCnBhdGNoX2ZyZWUAAhFjYWxsX2FwcGx5X2ZpbHRlcgADCikDFwEBfyMAIQEjACAAakEHakF4cSQAIAELAgALDAAgACABIAIgAxAACw=="

    private func fixtureBytes() throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64)))
    }

    private func makeRuntime(_ bridge: ImageFilterBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(bridge)
        return try WASMRuntime(bytes: try fixtureBytes(), hostImports: registry.hostImports())
    }

    private func readPacked(_ packed: UInt64, from rt: WASMRuntime) throws -> [UInt8] {
        if packed == 0 { return [] }
        return try rt.read(ptr: UInt32(packed >> 32), len: UInt32(packed & 0xffff_ffff))
    }

    // MARK: - Dispatch (injected spy → verifies args + packs result)

    func testDispatchPassesResolvedNameAndImageThenPacks() throws {
        let box = FilterCallBox()
        let bridge = ImageFilterBridge(filter: { image, name in
            box.record(image: image, name: name)
            return [0x89, 0x50, 0x4E, 0x47, 0xAA]   // canned "PNG" bytes
        })
        let rt = try makeRuntime(bridge)

        let img = try samplePNG()
        let (ip, il) = try rt.writeBuffer(img)
        let (np, nl) = try rt.writeBuffer([UInt8]("sepia".utf8))
        let res = try rt.invoke("call_apply_filter", [.i32(ip), .i32(il), .i32(np), .i32(nl)])

        let out = try readPacked(res[0].i64, from: rt)
        XCTAssertEqual(out, [0x89, 0x50, 0x4E, 0x47, 0xAA])
        XCTAssertEqual(box.lastImage, img, "image bytes forwarded verbatim")
        XCTAssertEqual(box.lastName, "CISepiaTone", "friendly name is resolved before the closure sees it")
    }

    func testDispatchNilResultPacksZero() throws {
        let bridge = ImageFilterBridge(filter: { _, _ in nil })
        let rt = try makeRuntime(bridge)
        let (ip, il) = try rt.writeBuffer(try samplePNG())
        let (np, nl) = try rt.writeBuffer([UInt8]("sepia".utf8))
        let res = try rt.invoke("call_apply_filter", [.i32(ip), .i32(il), .i32(np), .i32(nl)])
        XCTAssertEqual(res[0].i64, 0)
    }

    func testModuleNamespace() {
        XCTAssertEqual(ImageFilterBridge(filter: { _, _ in nil }).module, "patch")
    }
}

private final class FilterCallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _image: [UInt8] = []
    private var _name = ""
    func record(image: [UInt8], name: String) { lock.lock(); _image = image; _name = name; lock.unlock() }
    var lastImage: [UInt8] { lock.lock(); defer { lock.unlock() }; return _image }
    var lastName: String { lock.lock(); defer { lock.unlock() }; return _name }
}
