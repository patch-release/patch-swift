import Foundation
import WasmKit

// MARK: - NetworkImage bridge (download + cache a remote image → bytes)
//
// network_image(ptr,len) -> packed-i64 blob (0 = invalid URL / fetch failure)
//
// Downloads the image at a remote URL and returns its raw bytes to the guest,
// with an in-process cache so a repeated URL is served from memory instead of
// re-fetching. This lets an OTA patch load remote artwork/icons without owning a
// URLSession or an image cache. The guest gets the bytes and decodes them with
// whatever it has (or hands them to another bridge).
//
// ## Cross-platform core + injected dependency (guide Rule 2)
// The transport (a blocking GET, exactly like `URLSessionBridge.syncGet`) is
// injected as a `@Sendable (_ url: URL) -> [UInt8]?` fetcher so the struct + its
// `register(...)` + the cache logic compile and unit-test on macOS without
// hitting the network. Tests inject a stub fetcher (a fixed URL→bytes map that
// counts calls) and assert: invalid URLs reject, a hit caches, and a second
// request for the same URL is served WITHOUT a second fetch. The convenience
// `init()` wires a real blocking `URLSession` GET (default `.shared`).
//
// URL validation is a pure `static func validURL(_:)` (requires an http/https
// scheme + host) and is unit-tested directly.
public struct NetworkImageBridge: Bridge {
    /// Fetch the bytes at `url` (blocking). Returns nil on any failure.
    public typealias Fetcher = @Sendable (_ url: URL) -> [UInt8]?

    public let module = "patch"
    private let fetch: Fetcher
    private let cache = ByteCache()

    /// Cross-platform designated init — tests inject a stub fetcher.
    public init(fetch: @escaping Fetcher) { self.fetch = fetch }

    /// Convenience default init: wires a real blocking `URLSession` GET, mirroring
    /// `URLSessionBridge.syncGet`. Fully cross-platform (URLSession is Foundation),
    /// so no `#if` is needed; tests inject a stub fetcher rather than the network.
    public init(session: URLSession = .shared) {
        self.init(fetch: { url in
            let sem = DispatchSemaphore(value: 0)
            let box = ImageByteBox()
            let task = session.dataTask(with: url) { data, _, _ in
                if let data { box.set([UInt8](data)) }
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 30)
            return box.get()
        })
    }

    /// Validate an image URL: must parse and carry an http/https scheme + host.
    /// Pure + unit-tested directly. Returns the `URL` to fetch, or nil to reject.
    public static func validURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// The exact bytes the `network_image` host function packs: validate the URL,
    /// serve from cache if present, else fetch (and cache on success). Returns nil
    /// (→ packed 0) for an invalid URL or a fetch failure. Exposed (internally) so
    /// the validate→cache→fetch path is unit-tested without a wasm fixture.
    func imagePayload(urlString: String) -> [UInt8]? {
        guard let url = Self.validURL(urlString) else { return nil }
        let key = url.absoluteString
        if let cached = cache.get(key) { return cached }
        guard let bytes = fetch(url), !bytes.isEmpty else { return nil }
        cache.set(key, bytes)
        return bytes
    }

    public func register(into imports: inout Imports, store: Store) {
        let bridge = self
        imports.host(module, "network_image", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let urlString = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [try ctx.packedResult(bridge.imagePayload(urlString: urlString))]
        }
    }
}

/// Tiny thread-safe in-process cache: URL string → downloaded bytes.
///
/// BOUNDED (count + total bytes) with FIFO eviction. An earlier version was an
/// unbounded dictionary: a guest fetching many distinct image URLs (or a hostile
/// module iterating URLs) grew host memory without limit until the app was OOM-
/// killed. The caps keep the cache useful (repeat hits stay fast) while capping
/// the worst-case footprint regardless of guest behavior.
final class ByteCache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: [UInt8]] = [:]
    /// Insertion order, used for FIFO eviction when a cap is exceeded.
    private var order: [String] = []
    private var totalBytes = 0

    /// Max number of cached entries.
    let maxEntries: Int
    /// Max total cached bytes across all entries.
    let maxTotalBytes: Int

    init(maxEntries: Int = 128, maxTotalBytes: Int = 64 * 1024 * 1024) {
        self.maxEntries = maxEntries
        self.maxTotalBytes = maxTotalBytes
    }

    func get(_ key: String) -> [UInt8]? { lock.lock(); defer { lock.unlock() }; return store[key] }

    func set(_ key: String, _ value: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        // A single value larger than the whole budget is never cached (it would
        // immediately evict everything and still overflow) — serve it but skip it.
        if value.count > maxTotalBytes { return }
        if let existing = store[key] {
            totalBytes -= existing.count
            if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
        }
        store[key] = value
        order.append(key)
        totalBytes += value.count
        // Evict oldest entries until both caps are satisfied.
        while (store.count > maxEntries || totalBytes > maxTotalBytes), let oldest = order.first {
            order.removeFirst()
            if let removed = store.removeValue(forKey: oldest) { totalBytes -= removed.count }
        }
    }

    /// Number of cached entries (for tests).
    var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }
}

/// Thread-safe box so the URLSession completion handler can hand bytes back to
/// the blocking caller without a data-race warning (mirrors `ByteBox`).
private final class ImageByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [UInt8]?
    func set(_ v: [UInt8]) { lock.lock(); value = v; lock.unlock() }
    func get() -> [UInt8]? { lock.lock(); defer { lock.unlock() }; return value }
}
