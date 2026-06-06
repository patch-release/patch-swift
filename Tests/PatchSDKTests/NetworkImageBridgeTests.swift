import XCTest
import WasmKit
@testable import PatchSDK

/// NetworkImageBridge — `patch.network_image(url) -> packed-i64 blob`. The
/// transport is injected as a `@Sendable (URL) -> [UInt8]?` fetcher, so tests
/// inject a STUB (a URL→bytes map that counts calls). Two layers:
///   1. `validURL(_:)` — http/https + host validation, tested directly.
///   2. `imagePayload(urlString:)` — the validate→cache→fetch path the host fn
///      runs: invalid URLs reject, a hit caches, and a repeat is served WITHOUT a
///      second fetch. No real network / wasm fixture required.
final class NetworkImageBridgeTests: XCTestCase {

    // MARK: - validURL

    func testValidURLAcceptsHTTPAndHTTPS() {
        XCTAssertNotNil(NetworkImageBridge.validURL("https://cdn.example.com/a.png"))
        XCTAssertNotNil(NetworkImageBridge.validURL("http://example.com/x.jpg"))
        XCTAssertNotNil(NetworkImageBridge.validURL("  https://example.com/y.png  "), "trims whitespace")
    }

    func testValidURLRejectsBadInput() {
        XCTAssertNil(NetworkImageBridge.validURL(""), "empty")
        XCTAssertNil(NetworkImageBridge.validURL("   "), "whitespace")
        XCTAssertNil(NetworkImageBridge.validURL("file:///etc/passwd"), "non-http scheme")
        XCTAssertNil(NetworkImageBridge.validURL("ftp://example.com/a.png"), "non-http scheme")
        XCTAssertNil(NetworkImageBridge.validURL("not a url"), "no scheme")
        XCTAssertNil(NetworkImageBridge.validURL("https://"), "no host")
    }

    // MARK: - imagePayload (validate → cache → fetch)

    /// A counting stub fetcher over a fixed URL→bytes map.
    private final class FetchStub: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var callCount = 0
        private(set) var requested: [String] = []
        private let map: [String: [UInt8]]
        init(_ map: [String: [UInt8]]) { self.map = map }
        var fetch: NetworkImageBridge.Fetcher {
            { [self] url in
                lock.lock(); callCount += 1; requested.append(url.absoluteString); lock.unlock()
                return map[url.absoluteString]
            }
        }
    }

    func testFetchesAndReturnsBytes() {
        let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47]   // PNG magic
        let stub = FetchStub(["https://cdn.example.com/a.png": bytes])
        let bridge = NetworkImageBridge(fetch: stub.fetch)

        let out = bridge.imagePayload(urlString: "https://cdn.example.com/a.png")
        XCTAssertEqual(out, bytes)
        XCTAssertEqual(stub.callCount, 1)
    }

    /// A second request for the same URL is served from cache (no second fetch).
    func testCachesAndServesRepeatWithoutRefetch() {
        let bytes: [UInt8] = [1, 2, 3, 4, 5]
        let stub = FetchStub(["https://cdn.example.com/a.png": bytes])
        let bridge = NetworkImageBridge(fetch: stub.fetch)

        XCTAssertEqual(bridge.imagePayload(urlString: "https://cdn.example.com/a.png"), bytes)
        XCTAssertEqual(bridge.imagePayload(urlString: "https://cdn.example.com/a.png"), bytes)
        XCTAssertEqual(stub.callCount, 1, "second request served from cache — fetched only once")
    }

    /// Distinct URLs each fetch (and cache) independently.
    func testDistinctURLsFetchSeparately() {
        let stub = FetchStub([
            "https://cdn.example.com/a.png": [1],
            "https://cdn.example.com/b.png": [2],
        ])
        let bridge = NetworkImageBridge(fetch: stub.fetch)
        XCTAssertEqual(bridge.imagePayload(urlString: "https://cdn.example.com/a.png"), [1])
        XCTAssertEqual(bridge.imagePayload(urlString: "https://cdn.example.com/b.png"), [2])
        XCTAssertEqual(stub.callCount, 2)
    }

    /// An invalid URL returns nil WITHOUT consulting the fetcher.
    func testInvalidURLSkipsFetcher() {
        let stub = FetchStub([:])
        let bridge = NetworkImageBridge(fetch: stub.fetch)
        XCTAssertNil(bridge.imagePayload(urlString: "not a url"))
        XCTAssertNil(bridge.imagePayload(urlString: "file:///x"))
        XCTAssertEqual(stub.callCount, 0, "invalid URLs must not reach the fetcher")
    }

    /// A fetch miss (nil / empty) returns nil and is NOT cached (so a retry can
    /// fetch again).
    func testFetchFailureNotCached() {
        let stub = FetchStub([:])   // every URL misses
        let bridge = NetworkImageBridge(fetch: stub.fetch)
        XCTAssertNil(bridge.imagePayload(urlString: "https://cdn.example.com/missing.png"))
        XCTAssertNil(bridge.imagePayload(urlString: "https://cdn.example.com/missing.png"))
        XCTAssertEqual(stub.callCount, 2, "failures are not cached — both attempts fetch")
    }

    // MARK: - ByteCache unit

    func testByteCacheSetGet() {
        let cache = ByteCache()
        XCTAssertNil(cache.get("k"))
        cache.set("k", [9, 9])
        XCTAssertEqual(cache.get("k"), [9, 9])
        XCTAssertEqual(cache.count, 1)
    }

    // MARK: - Bridge shape / registration

    func testModuleNamespaceAndRegistration() {
        let bridge = NetworkImageBridge(fetch: { _ in nil })
        XCTAssertEqual(bridge.module, "patch")
        XCTAssertNotNil(BridgeRegistry().register(bridge).hostImports())
    }

    /// The cross-platform convenience init (real URLSession) is constructible +
    /// registrable without throwing (no network is touched here).
    func testDefaultInitRegisters() {
        XCTAssertNotNil(BridgeRegistry().register(NetworkImageBridge()).hostImports())
    }
}
