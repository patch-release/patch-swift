import XCTest
import WasmKit
@testable import PatchSDK

/// FileDownloadBridge — `download_file(ptr,len) -> i64 (packed path)`. Sync-over-
/// async like URLSessionBridge. We test:
///   1. `destinationName(for:)` — the pure filename-derivation logic.
///   2. `syncDownload(...)` end-to-end against a local `file://` URL (a default
///      `URLSession` can fetch `file://` with no network), asserting the bytes
///      land in the destination directory and the returned path is correct.
///   3. Dispatch of the registered `download_file` host function through a hand-
///      built wasm module, reading the packed path back out of guest memory.
final class FileDownloadBridgeTests: XCTestCase {

    // Hand-written wasm (wat2wasm). import download_file(i32,i32)->i64; exports
    // memory, patch_malloc (bump), patch_free, call_download(i32,i32)->i64.
    private static let fixture: [UInt8] = [
        0, 97, 115, 109, 1, 0, 0, 0, 1, 16, 3, 96, 2, 127, 127, 1, 126, 96, 1, 127, 1,
        127, 96, 1, 127, 0, 2, 23, 1, 5, 112, 97, 116, 99, 104, 13, 100, 111,
        119, 110, 108, 111, 97, 100, 95, 102, 105, 108, 101, 0, 0, 3, 4, 3, 1,
        2, 0, 5, 3, 1, 0, 1, 6, 7, 1, 127, 1, 65, 128, 8, 11, 7, 54, 4, 6,
        109, 101, 109, 111, 114, 121, 2, 0, 12, 112, 97, 116, 99, 104, 95,
        109, 97, 108, 108, 111, 99, 0, 1, 10, 112, 97, 116, 99, 104, 95, 102,
        114, 101, 101, 0, 2, 13, 99, 97, 108, 108, 95, 100, 111, 119, 110,
        108, 111, 97, 100, 0, 3, 10, 37, 3, 23, 1, 1, 127, 35, 0, 33, 1, 35,
        0, 32, 0, 106, 65, 7, 106, 65, 120, 113, 36, 0, 32, 1, 11, 2, 0, 11,
        8, 0, 32, 0, 32, 1, 16, 0, 11,
    ]

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDownloadBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
    }

    // MARK: - destinationName(for:) pure logic

    func testDestinationNameUsesLastComponent() {
        let url = URL(string: "https://acme.com/files/report.pdf")!
        let name = FileDownloadBridge.destinationName(for: url)
        XCTAssertTrue(name.hasSuffix("-report.pdf"), "got: \(name)")
        XCTAssertEqual(name.count, "report.pdf".count + 9, "8-hex prefix + dash + name")
    }

    func testDestinationNameFallsBackForNamelessURL() {
        let url = URL(string: "https://acme.com/")!
        let name = FileDownloadBridge.destinationName(for: url)
        XCTAssertTrue(name.hasSuffix("-download"), "got: \(name)")
    }

    func testDestinationNameDisambiguatesSameBasename() {
        let a = FileDownloadBridge.destinationName(for: URL(string: "https://a.com/x/file.txt")!)
        let b = FileDownloadBridge.destinationName(for: URL(string: "https://b.com/y/file.txt")!)
        XCTAssertNotEqual(a, b, "distinct URLs with same basename get distinct names")
        XCTAssertTrue(a.hasSuffix("-file.txt"))
        XCTAssertTrue(b.hasSuffix("-file.txt"))
    }

    func testDestinationNameStableForSameURL() {
        let url = URL(string: "https://a.com/x/file.txt")!
        XCTAssertEqual(
            FileDownloadBridge.destinationName(for: url),
            FileDownloadBridge.destinationName(for: url))
    }

    // MARK: - syncDownload against a local file:// URL (no network)

    func testSyncDownloadCopiesLocalFile() throws {
        let src = tmpDir.appendingPathComponent("source.bin")
        let payload = Data("hello patch download".utf8)
        try payload.write(to: src)
        let destDir = tmpDir.appendingPathComponent("dest", isDirectory: true)

        let path = FileDownloadBridge.syncDownload(
            src.absoluteString, session: .shared, destinationDirectory: destDir)

        let resolved = try XCTUnwrap(path, "download should succeed for a local file")
        XCTAssertTrue(resolved.hasPrefix(destDir.path), "lands under the dest dir: \(resolved)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: resolved)), payload)
    }

    func testSyncDownloadRejectsInvalidURL() {
        let path = FileDownloadBridge.syncDownload(
            "not a url", session: .shared,
            destinationDirectory: tmpDir.appendingPathComponent("d"))
        XCTAssertNil(path)
    }

    func testSyncDownloadMissingLocalFileReturnsNil() {
        let missing = tmpDir.appendingPathComponent("nope.bin")
        let path = FileDownloadBridge.syncDownload(
            missing.absoluteString, session: .shared,
            destinationDirectory: tmpDir.appendingPathComponent("d"))
        XCTAssertNil(path, "a nonexistent source yields no path")
    }

    // MARK: - Dispatch through the wasm fixture

    func testDispatchReturnsPackedPath() throws {
        let src = tmpDir.appendingPathComponent("data.txt")
        try Data("guest dispatch payload".utf8).write(to: src)
        let destDir = tmpDir.appendingPathComponent("dispatch-dest", isDirectory: true)

        let bridge = FileDownloadBridge(session: .shared, destinationDirectory: destDir)
        let rt = try WASMRuntime(
            bytes: Self.fixture, hostImports: BridgeRegistry().register(bridge).hostImports())

        let (ptr, len) = try rt.writeBuffer([UInt8](src.absoluteString.utf8))
        let result = try rt.invoke("call_download", [.i32(ptr), .i32(len)])
        let packed = result[0].i64
        XCTAssertNotEqual(packed, 0, "a successful download packs a non-zero (ptr,len)")

        let outBytes = try rt.read(ptr: UInt32(packed >> 32), len: UInt32(packed & 0xffff_ffff))
        let outPath = String(decoding: outBytes, as: UTF8.self)
        XCTAssertTrue(outPath.hasPrefix(destDir.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: outPath)),
                       Data("guest dispatch payload".utf8))
    }

    func testDispatchInvalidURLReturnsZero() throws {
        let bridge = FileDownloadBridge(
            session: .shared, destinationDirectory: tmpDir.appendingPathComponent("d"))
        let rt = try WASMRuntime(
            bytes: Self.fixture, hostImports: BridgeRegistry().register(bridge).hostImports())

        let (ptr, len) = try rt.writeBuffer([UInt8]("::::".utf8))
        let result = try rt.invoke("call_download", [.i32(ptr), .i32(len)])
        XCTAssertEqual(result[0].i64, 0)
    }

    #if canImport(Foundation)
    func testDefaultInitRegisters() throws {
        let registry = BridgeRegistry().register(FileDownloadBridge())
        XCTAssertNoThrow(try WASMRuntime(bytes: Self.fixture, hostImports: registry.hostImports()))
    }
    #endif
}
