import Foundation
import WasmKit

// MARK: - FileDownloadBridge (download a URL to a sandboxed file)
//
// `download_file(ptr,len) -> i64 (packed)` — synchronously download the URL the
// guest passes as a UTF-8 string `(ptr,len)`, move the downloaded bytes into a
// stable file in the app's Caches sandbox, and return that file's local path as a
// packed-i64 `(ptr,len)` UTF-8 blob (0 on error). This is sync-over-async exactly
// like `URLSessionBridge.syncGet`: the guest call blocks on a `DispatchSemaphore`
// while a `URLSession` download task runs.
//
// `URLSession.downloadTask` writes to a temp file that is deleted the moment the
// completion handler returns, so the handler immediately MOVES it under the
// injected destination directory (the default init uses Caches). The returned
// path is the moved file, which persists for the guest to read.
//
// ## Cross-platform core + injected dependencies (Rule 2)
// `URLSession` + `FileManager` are plain Foundation (compile AND run on macOS),
// so unlike the UIKit bridges this one needs no platform guard for the real path.
// We still inject the `URLSession` (so tests use a mock/ephemeral session) and the
// destination directory (so tests point it at a temp dir, never the real sandbox).
// The download → move → path logic is pulled into `static func syncDownload(...)`
// and the filename derivation into `static func destinationName(...)`, both
// unit-tested directly without touching the network.
public struct FileDownloadBridge: Bridge {
    public let module = "patch"
    private let session: URLSession
    private let destinationDirectory: URL

    /// Cross-platform designated init — tests inject an ephemeral/mock session and
    /// a temp destination directory.
    public init(session: URLSession, destinationDirectory: URL) {
        self.session = session
        self.destinationDirectory = destinationDirectory
    }

    #if canImport(Foundation)
    /// Convenience default init: a shared `URLSession` writing into a `Downloads`
    /// folder under the app's Caches sandbox (regenerable data the OS may evict).
    /// Falls back to the temp dir if the Caches directory can't be resolved.
    public init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("PatchDownloads", isDirectory: true)
        self.init(session: .shared, destinationDirectory: dir)
    }
    #endif

    /// Derive a stable, collision-resistant filename for a downloaded URL inside
    /// the destination directory. Uses the URL's last path component when it has a
    /// usable name, else a generic "download" base, then prefixes a short hash of
    /// the full URL so distinct URLs with the same basename don't clobber each
    /// other. Pure + unit-tested directly.
    public static func destinationName(for url: URL) -> String {
        let last = url.lastPathComponent
        let base: String
        if last.isEmpty || last == "/" || last == "." || last == ".." {
            base = "download"
        } else {
            base = last
        }
        // Short stable hash of the absolute string (djb2) → hex, to disambiguate.
        var hash: UInt32 = 5381
        for byte in url.absoluteString.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return String(format: "%08x-", hash) + base
    }

    /// Blocking download (the guest call is synchronous). Downloads `urlString`
    /// with `session`, moves the result under `destinationDirectory` using a name
    /// from `destinationName(for:)`, and returns the destination path (or nil on
    /// any error). The temp file from `downloadTask` is moved inside the
    /// completion handler before it is auto-deleted.
    static func syncDownload(
        _ urlString: String,
        session: URLSession,
        destinationDirectory: URL
    ) -> String? {
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        let fm = FileManager.default
        // Ensure the destination directory exists.
        try? fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let sem = DispatchSemaphore(value: 0)
        let box = PathBox()
        let dest = destinationDirectory.appendingPathComponent(destinationName(for: url))

        let task = session.downloadTask(with: url) { tempURL, response, _ in
            defer { sem.signal() }
            guard let tempURL else { return }
            // Treat non-2xx HTTP responses as failures.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return
            }
            // Replace any existing file at the destination, then move into place.
            try? fm.removeItem(at: dest)
            do {
                try fm.moveItem(at: tempURL, to: dest)
                box.set(dest.path)
            } catch {
                // Move can fail across volumes; fall back to a copy.
                if (try? fm.copyItem(at: tempURL, to: dest)) != nil {
                    box.set(dest.path)
                }
            }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 60)
        return box.get()
    }

    public func register(into imports: inout Imports, store: Store) {
        let session = self.session
        let dir = self.destinationDirectory
        imports.host(module, "download_file", [.i32, .i32], [.i64], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let url = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let path = Self.syncDownload(url, session: session, destinationDirectory: dir)
            return [try ctx.packedResult(path)]
        }
    }
}

/// Tiny thread-safe box so the download completion handler can hand the local
/// path back to the blocking caller without a data-race warning.
private final class PathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
