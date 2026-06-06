import XCTest
import WasmKit
@testable import PatchSDK

/// FileStorageBridge — sandboxed file read/write/exists/delete.
///
/// `FileManager` is cross-platform Foundation, so the bridge's real behavior is
/// exercised directly on macOS (no wasm fixture needed for the new `file_*`
/// callers — the BridgeFixture doesn't export them). Tests inject a TEMP base
/// directory so the developer's real `~/Documents` is never touched, round-trip
/// every operation, and assert the `..` traversal guard rejects escapes.
final class FileStorageBridgeTests: XCTestCase {

    /// Fresh temp base dir per test; cleaned up in `tearDown`.
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch.filestorage.test.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
        base = nil
    }

    // MARK: - resolve(base:scope:path:) — scoping + traversal guard

    func testResolvePlacesPathUnderScopeDir() throws {
        let docs = try XCTUnwrap(FileStorageBridge.resolve(base: base, scope: "documents", path: "notes/today.txt"))
        let caches = try XCTUnwrap(FileStorageBridge.resolve(base: base, scope: "caches", path: "thumb.png"))
        XCTAssertEqual(docs.path, base.appendingPathComponent("documents/notes/today.txt").standardizedFileURL.path)
        XCTAssertEqual(caches.path, base.appendingPathComponent("caches/thumb.png").standardizedFileURL.path)
    }

    func testResolveRejectsUnknownScope() {
        XCTAssertNil(FileStorageBridge.resolve(base: base, scope: "secrets", path: "a.txt"))
        XCTAssertNil(FileStorageBridge.resolve(base: base, scope: "", path: "a.txt"))
    }

    func testResolveRejectsEmptyPath() {
        XCTAssertNil(FileStorageBridge.resolve(base: base, scope: "documents", path: ""))
    }

    func testResolveRejectsAbsolutePath() {
        XCTAssertNil(FileStorageBridge.resolve(base: base, scope: "documents", path: "/etc/passwd"))
    }

    /// The core security requirement: `..` traversal MUST be rejected, whether it
    /// escapes one level, many levels, or hides in the middle of a path.
    func testResolveRejectsDotDotTraversal() {
        XCTAssertNil(FileStorageBridge.resolve(base: base, scope: "documents", path: ".."),
                     "bare .. must be rejected")
        XCTAssertNil(FileStorageBridge.resolve(base: base, scope: "documents", path: "../secret.txt"),
                     "single-level escape must be rejected")
        XCTAssertNil(FileStorageBridge.resolve(base: base, scope: "documents", path: "../../../../etc/passwd"),
                     "multi-level escape must be rejected")
        XCTAssertNil(FileStorageBridge.resolve(base: base, scope: "documents", path: "a/../../b.txt"),
                     "mid-path escape that climbs out of the scope must be rejected")
        XCTAssertNil(FileStorageBridge.resolve(base: base, scope: "documents", path: "../caches/x.txt"),
                     "escaping into a SIBLING scope must be rejected")
    }

    /// A `..` that stays inside the scope (cancels a prior component) is fine.
    func testResolveAllowsInScopeDotDot() throws {
        let url = try XCTUnwrap(FileStorageBridge.resolve(base: base, scope: "documents", path: "a/b/../c.txt"))
        XCTAssertEqual(url.path, base.appendingPathComponent("documents/a/c.txt").standardizedFileURL.path)
    }

    // MARK: - File operation round-trips (write / read / exists / delete)

    func testWriteReadExistsDeleteRoundTrip() throws {
        let url = try XCTUnwrap(FileStorageBridge.resolve(base: base, scope: "documents", path: "sub/dir/file.bin"))

        // Absent before write.
        XCTAssertFalse(FileStorageBridge.exists(url))
        XCTAssertNil(FileStorageBridge.read(url))

        // Write (creates intermediate dirs).
        let payload: [UInt8] = Array("hello patch".utf8)
        XCTAssertTrue(FileStorageBridge.write(payload, to: url))

        // Exists + read back identical bytes.
        XCTAssertTrue(FileStorageBridge.exists(url))
        XCTAssertEqual(FileStorageBridge.read(url), payload)

        // Overwrite with new bytes.
        let payload2: [UInt8] = [0x00, 0x01, 0x02, 0xFF]
        XCTAssertTrue(FileStorageBridge.write(payload2, to: url))
        XCTAssertEqual(FileStorageBridge.read(url), payload2)

        // Delete → gone.
        XCTAssertTrue(FileStorageBridge.delete(url))
        XCTAssertFalse(FileStorageBridge.exists(url))
        XCTAssertNil(FileStorageBridge.read(url))

        // Deleting an absent file is a no-op success.
        XCTAssertTrue(FileStorageBridge.delete(url))
    }

    /// Scopes are isolated subtrees: same relative path in each scope is a
    /// different file.
    func testScopesAreIsolated() throws {
        let docURL = try XCTUnwrap(FileStorageBridge.resolve(base: base, scope: "documents", path: "k.txt"))
        let cacheURL = try XCTUnwrap(FileStorageBridge.resolve(base: base, scope: "caches", path: "k.txt"))
        XCTAssertNotEqual(docURL.path, cacheURL.path)

        XCTAssertTrue(FileStorageBridge.write(Array("doc".utf8), to: docURL))
        XCTAssertTrue(FileStorageBridge.write(Array("cache".utf8), to: cacheURL))
        XCTAssertEqual(FileStorageBridge.read(docURL), Array("doc".utf8))
        XCTAssertEqual(FileStorageBridge.read(cacheURL), Array("cache".utf8))

        // Deleting one leaves the other intact.
        XCTAssertTrue(FileStorageBridge.delete(docURL))
        XCTAssertFalse(FileStorageBridge.exists(docURL))
        XCTAssertTrue(FileStorageBridge.exists(cacheURL))
    }

    // MARK: - Registration smoke

    /// The bridge registers its four host functions without error, and composes
    /// into a BridgeRegistry's host-import closure.
    func testRegistersHostFunctions() {
        let registry = BridgeRegistry()
        registry.register(FileStorageBridge(baseDirectory: base))
        XCTAssertNotNil(registry.hostImports())  // closure builds without throwing
    }

    /// Default `init()` (real-sandbox wiring) constructs without touching disk —
    /// proves the `#if canImport(Foundation)` convenience init compiles + runs on
    /// macOS. We do NOT write through it (would hit the real Documents dir).
    func testDefaultInitConstructs() {
        let bridge = FileStorageBridge()
        var imports = Imports()
        let store = Store(engine: Engine())
        bridge.register(into: &imports, store: store)  // registers against real base, no IO
    }
}
