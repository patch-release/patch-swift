import XCTest
import WasmKit
@testable import PatchSDK

/// D2 — ModuleLoader: download (file://) → decompress → SHA-256 verify
/// (pass + tamper-fail) → cache → activate a real fixture. Plus the diff path.
final class ModuleLoaderTests: XCTestCase {

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-loader-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func marshalFixtureBytes() throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm"))
        return [UInt8](try Data(contentsOf: url))
    }

    private func storage(in dir: URL) throws -> ModuleStorage {
        try ModuleStorage(appKey: "loader-test", baseDirectory: dir)
    }

    // MARK: - Full download path against a real wasm fixture

    func testDownloadVerifyCacheActivateRealModule() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = try marshalFixtureBytes()
        let sha = SHA256Hash.hexString(of: Data(bytes))

        // Write the (raw, uncompressed) module to a file:// URL the loader fetches.
        let moduleFile = dir.appendingPathComponent("module.wasm")
        try Data(bytes).write(to: moduleFile)

        let store = try storage(in: dir)
        let loader = ModuleLoader(storage: store)

        let activated = ActivationSpy()
        let patch = Patch()
        let response = UpdateCheckResponse(
            has_update: true, version: "1.0.0",
            module_url: moduleFile.absoluteString, sha256: sha, size: bytes.count)

        let result = try await loader.acquireAndActivate(response) { wasmBytes in
            try patch.activate(bytes: wasmBytes)   // real WASM activation
            activated.record(wasmBytes.count)
        }

        XCTAssertEqual(result.version, "1.0.0")
        XCTAssertFalse(result.usedDiff)
        XCTAssertEqual(activated.count, 1)
        XCTAssertTrue(patch.hasActiveModule)
        // The real module runs after activation.
        XCTAssertEqual(Int64(bitPattern: try patch.call("add_i64", [.i64(20), .i64(22)])[0].i64), 42)
        // Cached as current.
        XCTAssertEqual(store.currentVersion, "1.0.0")
        XCTAssertEqual(try store.currentBytes(), bytes)
    }

    // MARK: - SHA-256 tamper rejection

    func testHashMismatchIsRejectedNoCacheNoActivate() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = try marshalFixtureBytes()

        let moduleFile = dir.appendingPathComponent("module.wasm")
        try Data(bytes).write(to: moduleFile)

        let store = try storage(in: dir)
        let loader = ModuleLoader(storage: store)
        let activated = ActivationSpy()

        // WRONG sha (tampered expectation).
        let response = UpdateCheckResponse(
            has_update: true, version: "1.0.0",
            module_url: moduleFile.absoluteString,
            sha256: String(repeating: "0", count: 64), size: bytes.count)

        do {
            _ = try await loader.acquireAndActivate(response) { _ in activated.record(0) }
            XCTFail("expected hash mismatch")
        } catch let e as ModuleLoader.LoadError {
            if case .hashMismatch = e {} else { XCTFail("wrong error: \(e)") }
        }
        XCTAssertEqual(activated.count, 0, "must not activate on hash mismatch")
        XCTAssertNil(store.currentVersion, "must not cache on hash mismatch")
    }

    func testTamperedBytesFailVerification() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var bytes = try marshalFixtureBytes()
        let originalSHA = SHA256Hash.hexString(of: Data(bytes))
        // Corrupt one byte AFTER computing the expected sha.
        bytes[bytes.count / 2] = bytes[bytes.count / 2] &+ 1

        let moduleFile = dir.appendingPathComponent("module.wasm")
        try Data(bytes).write(to: moduleFile)
        let store = try storage(in: dir)
        let loader = ModuleLoader(storage: store)

        let response = UpdateCheckResponse(
            has_update: true, version: "1.0.0",
            module_url: moduleFile.absoluteString, sha256: originalSHA, size: bytes.count)
        do {
            _ = try await loader.acquireAndActivate(response) { _ in }
            XCTFail("expected hash mismatch on corrupted bytes")
        } catch let e as ModuleLoader.LoadError {
            if case .hashMismatch = e {} else { XCTFail("wrong error: \(e)") }
        }
    }

    // MARK: - Brotli (.wasm.br) download path

    func testBrotliCompressedDownloadInflatesThenVerifies() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Use the small brotli fixture (backend-produced) as the "module".
        let rawURL = try XCTUnwrap(Bundle.module.url(forResource: "diff_new", withExtension: "bin"))
        let brURL = try XCTUnwrap(Bundle.module.url(forResource: "diff_new", withExtension: "br"))
        let raw = try Data(contentsOf: rawURL)
        let sha = SHA256Hash.hexString(of: raw)

        // Serve the .br file at a file:// URL ending in .br so the loader inflates it.
        let served = dir.appendingPathComponent("module.wasm.br")
        try Data(contentsOf: brURL).write(to: served)

        let store = try storage(in: dir)
        let loader = ModuleLoader(storage: store)
        // Verify-only via fetchFull (no activation, since this blob isn't a real wasm).
        let fetched = try await loader.fetchFull(
            moduleURL: served.absoluteString, expectedSHA: sha, sizeHint: raw.count)
        XCTAssertEqual(fetched, raw, "brotli .br module must inflate to the raw bytes and verify")
    }

    // MARK: - Diff path (reconstruct from cached previous)

    func testDiffPathReconstructsFromCachedBase() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let oldURL = try XCTUnwrap(Bundle.module.url(forResource: "diff_old", withExtension: "bin"))
        let newURL = try XCTUnwrap(Bundle.module.url(forResource: "diff_new", withExtension: "bin"))
        let patchURL = try XCTUnwrap(Bundle.module.url(forResource: "diff", withExtension: "patch"))
        let old = try Data(contentsOf: oldURL)
        let expectedNew = try Data(contentsOf: newURL)
        let newSHA = SHA256Hash.hexString(of: expectedNew)

        // Seed the cache: 'old' is the previous module the diff patches against.
        let store = try storage(in: dir)
        try store.installCurrent(version: "1.0", sha256: SHA256Hash.hexString(of: old), bytes: [UInt8](old))
        // Install a second so 'old' moves to previous.
        try store.installCurrent(version: "1.1", sha256: "x", bytes: [9, 9, 9])
        // Now previous = 1.0 (= old). Good.

        let loader = ModuleLoader(storage: store)
        let reconstructed = try await loader.fetchViaDiff(
            diffURL: patchURL.absoluteString,
            baseVersion: "1.0", expectedSHA: newSHA, sizeHint: expectedNew.count)
        XCTAssertEqual(reconstructed, expectedNew)
    }

    func testDiffFallsBackToFullDownloadWhenNoBase() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // No cached base → diff must fail and the orchestrator falls back to full.
        let bytes = try marshalFixtureBytes()
        let sha = SHA256Hash.hexString(of: Data(bytes))
        let moduleFile = dir.appendingPathComponent("module.wasm")
        try Data(bytes).write(to: moduleFile)
        // A bogus diff URL that won't matter, since there's no base to patch.
        let bogusDiff = dir.appendingPathComponent("nope.patch")
        try Data([0]).write(to: bogusDiff)

        let store = try storage(in: dir)   // empty cache
        let loader = ModuleLoader(storage: store)
        let patch = Patch()
        let response = UpdateCheckResponse(
            has_update: true, version: "2.0.0",
            module_url: moduleFile.absoluteString,
            diff_url: bogusDiff.absoluteString,
            sha256: sha, size: bytes.count)

        let result = try await loader.acquireAndActivate(response) { try patch.activate(bytes: $0) }
        XCTAssertFalse(result.usedDiff, "no cached base → must fall back to full download")
        XCTAssertTrue(patch.hasActiveModule)
        XCTAssertEqual(store.currentVersion, "2.0.0")
    }
}

/// Records activation invocations for the loader tests.
private final class ActivationSpy: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var lastSize = 0
    func record(_ size: Int) { lock.lock(); count += 1; lastSize = size; lock.unlock() }
}
