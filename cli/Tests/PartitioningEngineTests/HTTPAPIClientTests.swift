// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler

// MARK: - URLProtocol stub (intercepts URLSession — no live network)

/// A `URLProtocol` that serves scripted responses keyed by a matcher on the
/// request, and records every request it sees. Installed on an ephemeral
/// `URLSession` so the real `HTTPPatchAPI` transport (multipart build, header
/// auth, status→error mapping, JSON decode) is exercised end-to-end without a
/// backend.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    /// A captured request plus its fully-materialized body. `URLSession` may move
    /// a request body into `httpBodyStream` (especially multipart), so we read the
    /// stream here and expose the bytes as `body`.
    struct Captured {
        let request: URLRequest
        let body: Data
    }

    /// (request) -> stub. First matcher returning non-nil wins.
    nonisolated(unsafe) static var router: (@Sendable (URLRequest) -> Stub?)?
    nonisolated(unsafe) static var captured: [Captured] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        router = nil
        captured = []
    }

    static func record(_ c: Captured) {
        lock.lock(); defer { lock.unlock() }
        captured.append(c)
    }

    /// All captured requests (body merged in via `httpBody` when present).
    static func all() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured.map(\.request)
    }

    /// The materialized body of the first captured request (stream-drained).
    static func firstBody() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return captured.first?.body
    }

    private static func materializeBody(_ req: URLRequest) -> Data {
        if let b = req.httpBody { return b }
        guard let stream = req.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubURLProtocol.record(Captured(request: request,
                                        body: StubURLProtocol.materializeBody(request)))
        let stub = StubURLProtocol.router?(request)
            ?? Stub(status: 500, body: Data("no stub".utf8), headers: [:])
        let resp = HTTPURLResponse(
            url: request.url!, statusCode: stub.status,
            httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: cfg)
}

private func json(_ obj: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: obj)
}

// MARK: - Real HTTPPatchAPI transport behavior

final class HTTPPatchAPIClientTests: XCTestCase {
    private let base = URL(string: "http://api.test")!

    override func setUp() { super.setUp(); StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }

    private func makeClient(key: String = "test-key") -> HTTPPatchAPI {
        HTTPPatchAPI(baseURL: base, apiKey: key, session: stubSession())
    }

    // ---- lookupApp ----------------------------------------------------------

    func testLookupAppDecodesSingleItemListAndSendsKey() throws {
        StubURLProtocol.router = { req in
            // Path + query are correct, key header present.
            guard let u = req.url?.absoluteString, u.contains("/api/v1/apps"),
                  u.contains("bundle_id=com.acme.app") else { return nil }
            return .init(status: 200, body: json([[
                "id": "app-1", "workspace_id": "ws-1", "name": "Acme",
                "bundle_id": "com.acme.app", "platform": "ios",
            ]]), headers: ["Content-Type": "application/json"])
        }
        let api = makeClient()
        let app = try api.lookupApp(bundleId: "com.acme.app")
        XCTAssertEqual(app?.id, "app-1")
        XCTAssertEqual(app?.workspaceId, "ws-1")
        XCTAssertEqual(app?.bundleId, "com.acme.app")
        // The X-API-Key header rode along.
        let sent = StubURLProtocol.all().first
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "X-API-Key"), "test-key")
    }

    func testLookupAppReturnsNilOn404() throws {
        StubURLProtocol.router = { _ in
            .init(status: 404, body: json(["detail": "No app found"]), headers: [:])
        }
        let api = makeClient()
        XCTAssertNil(try api.lookupApp(bundleId: "com.nope.app"),
                     "404 must map to nil, not throw")
    }

    func testLookupAppReturnsNilOnEmptyList() throws {
        StubURLProtocol.router = { _ in .init(status: 200, body: json([]), headers: [:]) }
        XCTAssertNil(try makeClient().lookupApp(bundleId: "com.empty.app"))
    }

    // ---- getActiveFingerprint ----------------------------------------------

    func testGetActiveFingerprintDecodes() throws {
        StubURLProtocol.router = { req in
            guard req.url?.absoluteString.contains("/fingerprints/app-1") == true else { return nil }
            return .init(status: 200, body: json([
                "id": "fp-9", "app_id": "app-1", "fingerprint": String(repeating: "a", count: 64),
                "is_active": true, "app_version": "1.2.0",
            ]), headers: [:])
        }
        let fp = try makeClient().getActiveFingerprint(appId: "app-1")
        XCTAssertEqual(fp?.id, "fp-9")
        XCTAssertEqual(fp?.isActive, true)
        XCTAssertEqual(fp?.appVersion, "1.2.0")
    }

    func testGetActiveFingerprintNilOn404() throws {
        StubURLProtocol.router = { _ in .init(status: 404, body: Data(), headers: [:]) }
        XCTAssertNil(try makeClient().getActiveFingerprint(appId: "absent"))
    }

    // ---- uploadModule (multipart) ------------------------------------------

    func testUploadModuleSendsMultipartAndDecodesRecord() throws {
        StubURLProtocol.router = { req in
            guard req.url?.absoluteString.hasSuffix("/api/v1/modules") == true else { return nil }
            return .init(status: 201, body: json([
                "id": "mod-1", "app_id": "A", "version": "1.0.0", "channel": "beta",
                "sha256": "deadbeef", "size_bytes": 5, "rollout_pct": 25, "mandatory": true,
                "is_active": true, "release_notes": "notes",
                "module_gcs_path": "app/x/module.wasm.br",
                "pushed_at": "2026-01-01T00:00:00Z", "rolled_back_at": NSNull(),
            ]), headers: [:])
        }
        let meta = ModuleUploadMetadata(appId: "A", workspaceId: "W", version: "1.0.0",
                                        fingerprintId: "F", channel: "beta", mandatory: true,
                                        rolloutPct: 25, releaseNotes: "notes")
        let rec = try makeClient().uploadModule(metadata: meta, wasm: Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(rec.id, "mod-1")
        XCTAssertEqual(rec.channel, "beta")
        XCTAssertEqual(rec.rolloutPct, 25)
        XCTAssertEqual(rec.mandatory, true)
        XCTAssertEqual(rec.modulePath, "app/x/module.wasm.br")

        // The request is a proper multipart POST carrying both the metadata field
        // and the raw wasm bytes.
        let sent = try XCTUnwrap(StubURLProtocol.all().first)
        XCTAssertEqual(sent.httpMethod, "POST")
        let ctype = sent.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(ctype.hasPrefix("multipart/form-data; boundary="), "got \(ctype)")
        let body = try XCTUnwrap(StubURLProtocol.firstBody())
        XCTAssertFalse(body.isEmpty, "multipart body should be materialized")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"metadata\""))
        XCTAssertTrue(text.contains("\"app_id\":\"A\""))
        XCTAssertTrue(text.contains("filename=\"module.wasm\""))
        XCTAssertTrue(body.range(of: Data([1, 2, 3, 4, 5])) != nil, "raw wasm bytes present")
    }

    func testUploadModuleIncludesTargetingKeysWhenSet() throws {
        StubURLProtocol.router = { req in
            guard req.url?.absoluteString.hasSuffix("/api/v1/modules") == true else { return nil }
            return .init(status: 201, body: json([
                "id": "mod-2", "app_id": "A", "version": "2.1.0", "channel": "production",
                "sha256": "x", "size_bytes": 1, "rollout_pct": 100, "mandatory": false,
                "is_active": true, "module_gcs_path": "p", "pushed_at": "t",
            ]), headers: [:])
        }
        let meta = ModuleUploadMetadata(appId: "A", workspaceId: "W", version: "2.1.0",
                                        fingerprintId: "F",
                                        minAppVersion: "2.1.0", maxAppVersion: "3.0.0",
                                        minOsVersion: "16.0", targetCohort: "beta")
        _ = try makeClient().uploadModule(metadata: meta, wasm: Data([1]))
        let body = try XCTUnwrap(StubURLProtocol.firstBody())
        let text = String(decoding: body, as: UTF8.self)
        // Wire keys must match the backend `ModuleMetadata` exactly.
        XCTAssertTrue(text.contains("\"min_app_version\":\"2.1.0\""), "got \(text)")
        XCTAssertTrue(text.contains("\"max_app_version\":\"3.0.0\""), "got \(text)")
        XCTAssertTrue(text.contains("\"min_os_version\":\"16.0\""), "got \(text)")
        XCTAssertTrue(text.contains("\"target_cohort\":\"beta\""), "got \(text)")
    }

    func testUploadModuleOmitsTargetingKeysWhenUnset() throws {
        StubURLProtocol.router = { req in
            guard req.url?.absoluteString.hasSuffix("/api/v1/modules") == true else { return nil }
            return .init(status: 201, body: json([
                "id": "mod-3", "app_id": "A", "version": "1.0.0", "channel": "production",
                "sha256": "x", "size_bytes": 1, "rollout_pct": 100, "mandatory": false,
                "is_active": true, "module_gcs_path": "p", "pushed_at": "t",
            ]), headers: [:])
        }
        // No targeting flags supplied => identical metadata to the pre-targeting CLI.
        let meta = ModuleUploadMetadata(appId: "A", workspaceId: "W", version: "1.0.0",
                                        fingerprintId: "F")
        _ = try makeClient().uploadModule(metadata: meta, wasm: Data([1]))
        let body = try XCTUnwrap(StubURLProtocol.firstBody())
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("min_app_version"), "untargeted upload must omit the key; got \(text)")
        XCTAssertFalse(text.contains("max_app_version"), "got \(text)")
        XCTAssertFalse(text.contains("min_os_version"), "got \(text)")
        XCTAssertFalse(text.contains("target_cohort"), "got \(text)")
    }

    // ---- uploadAppIcon (multipart, feature) ---------------------------------

    func testUploadAppIconSendsMultipartToIconEndpointAndReturnsURL() throws {
        StubURLProtocol.router = { req in
            guard req.url?.absoluteString.hasSuffix("/api/v1/apps/app-7/icon") == true else { return nil }
            return .init(status: 200, body: json(["icon_url": "https://cdn.test/app-7/icon.png"]),
                         headers: ["Content-Type": "application/json"])
        }
        let served = try makeClient().uploadAppIcon(
            appId: "app-7", icon: Data([0x89, 0x50, 0x4E, 0x47]),
            fileName: "Icon-1024.png", mimeType: "image/png")
        XCTAssertEqual(served, "https://cdn.test/app-7/icon.png")

        let sent = try XCTUnwrap(StubURLProtocol.all().first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-API-Key"), "test-key")
        let ctype = sent.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(ctype.hasPrefix("multipart/form-data; boundary="), "got \(ctype)")
        let body = try XCTUnwrap(StubURLProtocol.firstBody())
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"file\""), "icon must be sent as the `file` field; got \(text)")
        XCTAssertTrue(text.contains("filename=\"Icon-1024.png\""), "got \(text)")
        XCTAssertTrue(text.contains("Content-Type: image/png"), "got \(text)")
        XCTAssertTrue(body.range(of: Data([0x89, 0x50, 0x4E, 0x47])) != nil, "raw icon bytes present")
    }

    func testUploadAppIconThrowsOnMissingEndpointSoCallerCanSkip() throws {
        // A backend without the icon endpoint 404s; the API surfaces it as an error
        // and the CLI's best-effort caller swallows it (never fails the push).
        StubURLProtocol.router = { _ in .init(status: 404, body: Data(), headers: [:]) }
        XCTAssertThrowsError(
            try makeClient().uploadAppIcon(appId: "x", icon: Data([1]),
                                           fileName: "i.png", mimeType: "image/png"))
    }

    func testModuleRecordDecodesTargetingFromResponse() throws {
        StubURLProtocol.router = { req in
            guard let u = req.url?.absoluteString, u.contains("/api/v1/modules") else { return nil }
            return .init(status: 200, body: json([
                ["id": "m1", "app_id": "A", "version": "2.1.0", "channel": "production",
                 "sha256": "x", "size_bytes": 1, "rollout_pct": 100, "mandatory": false,
                 "is_active": true, "module_gcs_path": "p", "pushed_at": "t",
                 "min_app_version": "2.1.0", "min_os_version": "16.0", "target_cohort": "beta"],
            ]), headers: [:])
        }
        let mods = try makeClient().listModules(appId: "A", channel: "production")
        XCTAssertEqual(mods[0].minAppVersion, "2.1.0")
        XCTAssertEqual(mods[0].minOsVersion, "16.0")
        XCTAssertEqual(mods[0].targetCohort, "beta")
        XCTAssertNil(mods[0].maxAppVersion)
        XCTAssertEqual(mods[0].targetingSummary, "app ≥ 2.1.0, iOS ≥ 16.0, cohort beta")
    }

    // ---- listModules / rollout / rollback / stats ---------------------------

    func testListModulesPassesChannelFilterAndDecodesArray() throws {
        StubURLProtocol.router = { req in
            guard let u = req.url?.absoluteString, u.contains("/api/v1/modules") else { return nil }
            XCTAssertTrue(u.contains("app_id=A"))
            XCTAssertTrue(u.contains("channel=production"))
            return .init(status: 200, body: json([
                ["id": "m1", "app_id": "A", "version": "1.0.0", "channel": "production",
                 "sha256": "x", "size_bytes": 1, "rollout_pct": 100, "mandatory": false,
                 "is_active": true, "module_gcs_path": "p", "pushed_at": "t"],
            ]), headers: [:])
        }
        let mods = try makeClient().listModules(appId: "A", channel: "production")
        XCTAssertEqual(mods.count, 1)
        XCTAssertEqual(mods[0].version, "1.0.0")
    }

    func testUpdateRolloutSendsPatchWithBody() throws {
        StubURLProtocol.router = { req in
            guard req.url?.absoluteString.contains("/modules/m1/rollout") == true else { return nil }
            return .init(status: 200, body: json([
                "id": "m1", "app_id": "A", "version": "1.0.0", "channel": "production",
                "sha256": "x", "size_bytes": 1, "rollout_pct": 10, "mandatory": false,
                "is_active": true, "module_gcs_path": "p", "pushed_at": "t",
            ]), headers: [:])
        }
        let rec = try makeClient().updateRollout(moduleID: "m1", rolloutPct: 10)
        XCTAssertEqual(rec.rolloutPct, 10)
        let sent = try XCTUnwrap(StubURLProtocol.all().first)
        XCTAssertEqual(sent.httpMethod, "PATCH")
    }

    func testRollbackSendsPost() throws {
        StubURLProtocol.router = { req in
            guard req.url?.absoluteString.contains("/modules/m1/rollback") == true else { return nil }
            return .init(status: 200, body: json([
                "id": "m1", "app_id": "A", "version": "1.0.0", "channel": "production",
                "sha256": "x", "size_bytes": 1, "rollout_pct": 0, "mandatory": false,
                "is_active": false, "module_gcs_path": "p", "pushed_at": "t",
            ]), headers: [:])
        }
        let rec = try makeClient().rollback(moduleID: "m1")
        XCTAssertFalse(rec.isActive)
        XCTAssertEqual(StubURLProtocol.all().first?.httpMethod, "POST")
    }

    func testStatsDecodesAndComputesRates() throws {
        StubURLProtocol.router = { _ in
            .init(status: 200, body: json([
                "module_id": "m1", "version": "1.0.0",
                "downloads": 100, "activations": 80, "errors": 4,
            ]), headers: [:])
        }
        let stats = try makeClient().stats(moduleID: "m1")
        XCTAssertEqual(stats.downloads, 100)
        XCTAssertEqual(stats.adoptionRate, 0.8, accuracy: 0.001)
        XCTAssertEqual(stats.failureRate, 4.0 / 84.0, accuracy: 0.001)
    }

    // ---- HTTP error mapping -------------------------------------------------

    func testNon2xxMapsToHTTPError() throws {
        StubURLProtocol.router = { _ in
            .init(status: 409, body: json(["detail": "bundle exists"]), headers: [:])
        }
        XCTAssertThrowsError(try makeClient().uploadModule(
            metadata: ModuleUploadMetadata(appId: "A", workspaceId: "W",
                                           version: "1", fingerprintId: "F"),
            wasm: Data([0]))) { err in
            guard case APIError.http(let status, let body) = err else {
                return XCTFail("expected APIError.http, got \(err)")
            }
            XCTAssertEqual(status, 409)
            XCTAssertTrue(body.contains("bundle exists"))
        }
    }

    func testRegisterFingerprintRoundTrips() throws {
        StubURLProtocol.router = { req in
            guard req.url?.absoluteString.hasSuffix("/api/v1/fingerprints") == true,
                  req.httpMethod == "POST" else { return nil }
            return .init(status: 201, body: json([
                "id": "fp-new", "app_id": "A", "fingerprint": String(repeating: "b", count: 64),
                "is_active": true, "app_version": "2.0.0",
            ]), headers: [:])
        }
        let rec = try makeClient().registerFingerprint(
            appId: "A", fingerprint: String(repeating: "b", count: 64),
            components: ["layout": 1], appVersion: "2.0.0")
        XCTAssertEqual(rec.id, "fp-new")
        XCTAssertEqual(rec.appVersion, "2.0.0")
    }
}

// MARK: - Base-URL normalization (the `/api/v1` doubling P1)

/// The canonical production backend URL the SDK + docs publish is
/// `https://api.patchrelease.com/api/v1`. A developer who pasted THAT verbatim
/// into `.Patch.yml`'s `api_base_url` (or `--base-url`) used to get every request
/// sent to `…/api/v1/api/v1/…` → an opaque 404 on every networked command. These
/// tests pin the fix: `normalizedBase` strips a trailing `/api/v1` so `api/v1/...`
/// is appended exactly once, regardless of which form the developer supplies.
final class BaseURLNormalizationTests: XCTestCase {
    private func built(from base: String) -> URL {
        HTTPPatchAPI.normalizedBase(URL(string: base)!)
            .appendingPathComponent("api/v1")
            .appendingPathComponent("modules")
    }

    func testBareRootIsUnchanged() {
        XCTAssertEqual(built(from: "http://localhost:8000").absoluteString,
                       "http://localhost:8000/api/v1/modules")
    }

    func testTrailingSlashRootIsUnchanged() {
        XCTAssertEqual(built(from: "http://localhost:8000/").absoluteString,
                       "http://localhost:8000/api/v1/modules")
    }

    func testApiV1SuffixIsNotDoubled() {
        XCTAssertEqual(built(from: "https://api.patchrelease.com/api/v1").absoluteString,
                       "https://api.patchrelease.com/api/v1/modules",
                       "a base already ending in /api/v1 must NOT double to /api/v1/api/v1")
    }

    func testApiV1SuffixWithTrailingSlashIsNotDoubled() {
        XCTAssertEqual(built(from: "https://api.patchrelease.com/api/v1/").absoluteString,
                       "https://api.patchrelease.com/api/v1/modules")
    }

    /// End-to-end through the real transport: the actual request URL the
    /// `URLSession` sees carries exactly one `/api/v1` even with the suffixed base.
    func testTransportSendsSingleApiV1WithSuffixedBase() throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.router = { _ in
            .init(status: 404, body: Data("{}".utf8), headers: [:])
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let api = HTTPPatchAPI(
            baseURL: URL(string: "https://api.patchrelease.com/api/v1")!,
            apiKey: "k", session: URLSession(configuration: cfg))
        _ = try? api.getActiveFingerprint(appId: "app-1")
        let sent = StubURLProtocol.all().first?.url?.absoluteString ?? ""
        XCTAssertTrue(sent.contains("/api/v1/fingerprints/app-1"), "got: \(sent)")
        XCTAssertFalse(sent.contains("/api/v1/api/v1"),
                       "the suffixed base must not double the /api/v1 prefix; got: \(sent)")
    }
}
