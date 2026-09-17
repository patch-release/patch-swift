// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler

/// The RESUMABLE upload protocol (`/modules/upload-url` → direct PUT → `/modules/finalize`),
/// driven through the same `URLProtocol` stub the rest of the HTTP tests use. These
/// exercise `putBytes` directly with a small payload — the production trigger is a
/// module over 24 MiB, which is the same code path with a bigger body.
final class ResumableUploadTests: XCTestCase {
    private let base = URL(string: "http://api.test")!
    private let session = URL(string: "http://storage.test/session/1")!

    override func setUp() { super.setUp(); StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }

    private func makeAPI() -> HTTPPatchAPI {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return HTTPPatchAPI(baseURL: base, apiKey: "k", session: URLSession(configuration: cfg))
    }

    private var meta: ModuleUploadMetadata {
        ModuleUploadMetadata(appId: "A", workspaceId: "W", version: "1.0.0",
                             fingerprintId: "F", channel: "production", mandatory: false,
                             rolloutPct: 100, releaseNotes: nil)
    }

    private func puts() -> [URLRequest] {
        StubURLProtocol.all().filter { $0.httpMethod == "PUT" }
    }

    // MARK: - Happy path

    func testUploadURLThenPutThenFinalize() throws {
        StubURLProtocol.router = { req in
            let u = req.url?.absoluteString ?? ""
            if u.hasSuffix("/modules/upload-url") {
                return .init(status: 200, body: try! JSONSerialization.data(withJSONObject: [
                    "upload_url": "http://storage.test/session/1", "staging_key": "stage/1",
                ]), headers: [:])
            }
            if u.hasPrefix("http://storage.test/") { return .init(status: 200, body: Data(), headers: [:]) }
            if u.hasSuffix("/modules/finalize") {
                return .init(status: 201, body: try! JSONSerialization.data(withJSONObject: [
                    "id": "m1", "app_id": "A", "version": "1.0.0", "channel": "production",
                    "sha256": "abc", "size_bytes": 10, "rollout_pct": 100, "mandatory": false,
                    "is_active": true, "module_gcs_path": "p", "pushed_at": "t",
                ]), headers: [:])
            }
            return nil
        }
        let wasm = Data([0, 97, 115, 109, 1, 2, 3, 4, 5, 6])
        let record = try makeAPI().uploadModuleResumable(metadata: meta, wasm: wasm, sha256: "abc")
        XCTAssertEqual(record?.id, "m1")
        XCTAssertEqual(puts().count, 1, "the body must be sent exactly once")
        XCTAssertEqual(puts().first?.value(forHTTPHeaderField: "Content-Range"), "bytes 0-9/10")
        // The session URI is its own credential — the API key must NOT ride along.
        XCTAssertNil(puts().first?.value(forHTTPHeaderField: "X-API-Key"))
        // The finalize body carries the sha of the RAW wasm bytes + the staging key.
        let finalize = StubURLProtocol.captured.first { $0.request.url?.absoluteString.hasSuffix("finalize") == true }
        let body = try XCTUnwrap(finalize?.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["sha256"] as? String, "abc")
        XCTAssertEqual(json["staging_key"] as? String, "stage/1")
    }

    // MARK: - Retry policy

    /// BUG: a PERMANENT storage error (an expired/invalid signed session URI → 403)
    /// was retried 5 times, RE-SENDING THE WHOLE MODULE each time. On the >24 MiB
    /// modules that use this path that is minutes of pointless upload before an
    /// opaque failure. A 4xx that isn't 408/429 can never succeed on retry.
    func testPermanentStorageErrorFailsImmediately() throws {
        StubURLProtocol.router = { _ in .init(status: 403, body: Data("expired".utf8), headers: [:]) }
        let started = Date()
        XCTAssertThrowsError(try makeAPI().putBytes(to: session, data: Data(repeating: 7, count: 1024))) { error in
            guard case APIError.http(let status, let body) = error else {
                return XCTFail("expected the real HTTP status, got \(error)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertTrue(body.contains("expired"), "the server's explanation must survive")
        }
        XCTAssertEqual(puts().count, 1, "the module must be sent once, not five times")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "no backoff sleeps on a permanent error")
    }

    /// A TRANSIENT failure (503) is still retried, resuming from the committed offset.
    func testTransientStorageErrorIsRetried() throws {
        final class Box: @unchecked Sendable { var n = 0 }
        let box = Box()
        StubURLProtocol.router = { req in
            guard req.url?.absoluteString.hasPrefix("http://storage.test/") == true else { return nil }
            box.n += 1
            if box.n == 1 { return .init(status: 503, body: Data(), headers: [:]) }
            return .init(status: 200, body: Data(), headers: [:])
        }
        XCTAssertNoThrow(try makeAPI().putBytes(to: session, data: Data(repeating: 7, count: 64)))
        XCTAssertGreaterThanOrEqual(puts().count, 2)
    }

    // MARK: - Resume / 308 handling

    /// A partial commit re-sends only the TAIL.
    func testPartialCommitResumesFromTheCommittedOffset() throws {
        final class Box: @unchecked Sendable { var n = 0 }
        let box = Box()
        StubURLProtocol.router = { req in
            guard req.url?.absoluteString.hasPrefix("http://storage.test/") == true else { return nil }
            box.n += 1
            if box.n == 1 { return .init(status: 308, body: Data(), headers: ["Range": "bytes=0-499"]) }
            return .init(status: 200, body: Data(), headers: [:])
        }
        try makeAPI().putBytes(to: session, data: Data(repeating: 7, count: 1024))
        XCTAssertEqual(puts().map { $0.value(forHTTPHeaderField: "Content-Range") },
                       ["bytes 0-1023/1024", "bytes 500-1023/1024"])
    }

    /// BUG: when the session reported EVERY byte committed (`Range: bytes=0-1023`
    /// of 1024) the next request was built from offset == total, producing the
    /// invalid header `Content-Range: bytes 1024-1023/1024`. The server rejects
    /// that, so the release failed with an opaque error even though every byte was
    /// already uploaded — and it did it four times over.
    func testFullyCommittedSessionCompletesInsteadOfSendingAnInvalidRange() throws {
        final class Box: @unchecked Sendable { var n = 0 }
        let box = Box()
        StubURLProtocol.router = { req in
            guard req.url?.absoluteString.hasPrefix("http://storage.test/") == true else { return nil }
            box.n += 1
            // First the chunk PUT 308s with everything committed; the status probe
            // that follows reports the object complete.
            if box.n == 1 { return .init(status: 308, body: Data(), headers: ["Range": "bytes=0-1023"]) }
            return .init(status: 200, body: Data(), headers: [:])
        }
        XCTAssertNoThrow(try makeAPI().putBytes(to: session, data: Data(repeating: 7, count: 1024)))
        let ranges = puts().compactMap { $0.value(forHTTPHeaderField: "Content-Range") }
        XCTAssertEqual(ranges, ["bytes 0-1023/1024", "bytes */1024"])
        for r in ranges {
            XCTAssertFalse(r.hasPrefix("bytes 1024-1023"), "invalid Content-Range emitted: \(r)")
        }
    }

    /// The request builder itself can never emit a backwards range.
    func testChunkRequestNeverEmitsABackwardsRange() {
        let api = makeAPI()
        let data = Data(repeating: 1, count: 100)
        XCTAssertEqual(api.uploadChunkRequest(url: session, data: data, from: 0, total: 100)
                        .value(forHTTPHeaderField: "Content-Range"), "bytes 0-99/100")
        XCTAssertEqual(api.uploadChunkRequest(url: session, data: data, from: 40, total: 100)
                        .value(forHTTPHeaderField: "Content-Range"), "bytes 40-99/100")
        // At (or past) the end: a status probe, not `bytes 100-99/100`.
        XCTAssertEqual(api.uploadChunkRequest(url: session, data: data, from: 100, total: 100)
                        .value(forHTTPHeaderField: "Content-Range"), "bytes */100")
        XCTAssertEqual(api.uploadChunkRequest(url: session, data: data, from: 999, total: 100)
                        .value(forHTTPHeaderField: "Content-Range"), "bytes */100")
        XCTAssertEqual(api.uploadChunkRequest(url: session, data: Data(), from: 0, total: 0)
                        .value(forHTTPHeaderField: "Content-Range"), "bytes */0")
    }

    func testRetryableStatusClassification() {
        for s in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(HTTPPatchAPI.isRetryableUploadStatus(s), "\(s) should be retried")
        }
        for s in [400, 401, 403, 404, 409, 410, 412, 416] {
            XCTAssertFalse(HTTPPatchAPI.isRetryableUploadStatus(s), "\(s) can never succeed on retry")
        }
    }

    func testSessionStatusReadsTheCommittedOffset() {
        StubURLProtocol.router = { _ in .init(status: 308, body: Data(), headers: ["Range": "bytes=0-9"]) }
        XCTAssertEqual(makeAPI().sessionStatus(url: session, total: 100), .incomplete(offset: 10))
        StubURLProtocol.reset()
        StubURLProtocol.router = { _ in .init(status: 200, body: Data(), headers: [:]) }
        XCTAssertEqual(makeAPI().sessionStatus(url: session, total: 100), .complete)
        StubURLProtocol.reset()
        StubURLProtocol.router = { _ in .init(status: 308, body: Data(), headers: [:]) }
        XCTAssertEqual(makeAPI().sessionStatus(url: session, total: 100), .unknown)
    }

    // MARK: - Fallback

    /// A backend with no direct-upload route (501/404/405) or an unexpected response
    /// shape must fall back to the multipart path, not fail the release.
    func testFallsBackToMultipartWhenTheBackendHasNoDirectRoute() throws {
        for status in [404, 405, 501] {
            StubURLProtocol.reset()
            StubURLProtocol.router = { _ in .init(status: status, body: Data(), headers: [:]) }
            XCTAssertNil(try makeAPI().uploadModuleResumable(metadata: meta, wasm: Data([1, 2, 3]), sha256: "s"),
                         "status \(status) must fall back")
        }
        StubURLProtocol.reset()
        StubURLProtocol.router = { _ in
            .init(status: 200, body: try! JSONSerialization.data(withJSONObject: ["nope": 1]), headers: [:])
        }
        XCTAssertNil(try makeAPI().uploadModuleResumable(metadata: meta, wasm: Data([1, 2, 3]), sha256: "s"))
    }
}
