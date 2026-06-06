import XCTest
import WasmKit
@testable import PatchSDK

/// Regression: a FAILED `reloadAsync()` (the staged module won't activate) must
/// NOT corrupt the already-running good `current` module.
///
/// The staged bytes are never installed as `current` before activation, so the
/// on-disk current slot is still the good module that was running. The failure
/// path must re-activate that good current (via the fallback chain), not run
/// `recoverFromBadCurrent()`, which would demote/discard the good current and
/// needlessly downgrade to `previous` / bundled / disabled.
final class ReloadFailurePreservesCurrentTests: XCTestCase {

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-reloadfail-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func marshalBytes() throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm"))
        return [UInt8](try Data(contentsOf: url))
    }

    private struct RoutingTransport: HTTPTransport {
        let route: @Sendable (URLRequest) -> (Data, Int)
        func send(_ request: URLRequest) async throws -> (Data, Int) { route(request) }
    }

    private let apiBase = URL(string: "https://api.test/api/v1")!

    func testFailedReloadKeepsGoodCurrentActive() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        // 1. A GOOD current module (v1.0.0) installed + active.
        let good = try marshalBytes()
        let goodSHA = SHA256Hash.hexString(of: Data(good))
        let storage = try ModuleStorage(appKey: "reloadfail", baseDirectory: dir)
        try storage.installCurrent(version: "1.0.0", sha256: goodSHA, bytes: good)

        // 2. A CORRUPT staged update (v2.0.0): bytes are NOT a valid wasm module,
        //    so they pass the loader's sha check (sha matches the corrupt bytes)
        //    but FAIL activation/instantiation.
        let bad: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0xff, 0xff, 0xff, 0xff] + [UInt8](repeating: 0x00, count: 32)
        let badSHA = SHA256Hash.hexString(of: Data(bad))
        let badFile = dir.appendingPathComponent("v2.wasm")
        try Data(bad).write(to: badFile)
        let response = UpdateCheckResponse(
            has_update: true, version: "2.0.0",
            module_url: badFile.absoluteString, sha256: badSHA,
            size: bad.count, mandatory: false, release_notes: nil)
        let checkJSON = try JSONEncoder().encode(response)

        let transport = RoutingTransport { req in
            let path = req.url?.absoluteString ?? ""
            if path.hasSuffix("/modules/check") { return (checkJSON, 200) }
            if path.hasSuffix("/events") { return (Data(), 201) }
            return (Data(), 404)
        }
        let checker = UpdateChecker(baseURL: apiBase, transport: transport)
        let patch = Patch()
        patch.bridges.registerDefaults()
        patch.injectForTesting(
            configuration: PatchConfiguration(
                appKey: "reloadfail", appID: "abcabcab-0000-0000-0000-000000000000",
                apiBaseURL: apiBase, fingerprint: "fp", deviceID: "dev",
                channel: .production),
            storage: storage, checker: checker)

        // Bring the good current online (activates v1.0.0).
        _ = patch.activateBestLocal()
        XCTAssertTrue(patch.hasActiveModule)
        XCTAssertEqual(storage.currentVersion, "1.0.0")

        // 3. Stage + attempt to reload the corrupt v2 — activation must fail.
        _ = try await patch.checkForUpdate()
        let staged = try await patch.fetchUpdate()
        XCTAssertTrue(staged, "corrupt-but-sha-valid bytes should stage")

        do {
            try await patch.reloadAsync()
            XCTFail("expected reloadAsync to throw on a module that can't activate")
        } catch let e as Patch.UpdateError {
            if case .activation = e {} else { XCTFail("wrong error: \(e)") }
        }

        // 4. The good current is PRESERVED: still active, still v1.0.0 on disk —
        //    NOT discarded/downgraded by a spurious recoverFromBadCurrent().
        XCTAssertTrue(patch.hasActiveModule, "good current must stay active after a failed reload")
        XCTAssertEqual(storage.currentVersion, "1.0.0",
                       "the on-disk current must remain the good v1.0.0")
        XCTAssertNil(storage.previousVersion,
                     "previous must not have been promoted over the good current")
    }
}
