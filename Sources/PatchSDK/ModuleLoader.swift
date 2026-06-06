import Foundation

/// Downloads, decompresses, verifies, caches, and activates OTA modules.
///
/// ## Pipeline (full-module path — always correct)
/// 1. **Download** `module_url` bytes via the injectable `HTTPTransport`
///    (mockable; tests use `file://` or a mock `URLProtocol`).
/// 2. **Decompress** — the backend serves brotli `.wasm.br` (the `module_gcs_path`
///    it returns is the compressed one). If the URL ends in `.br` (or
///    `forceBrotli` is set), inflate it with `Brotli`. The decompressed bytes are
///    the raw `.wasm`.
/// 3. **Verify** SHA-256 of the **raw** bytes against the backend's `sha256`
///    (which is computed over the uncompressed wasm).
///    A mismatch is rejected (no caching, no activation).
/// 4. **Cache** the verified bytes into `ModuleStorage` as the new current
///    (demoting the old current to previous).
/// 5. **Activate** via `Patch.activate(bytes:)`.
///
/// ## Diff path (bandwidth saver, with safe fallback)
/// When the response carries a `diff_url`, the loader downloads the bsdiff4
/// (BSDIFF40) patch, applies it to the **cached previous** module with
/// `BSDIFF40Patch.apply`, SHA-256-verifies the reconstruction, and uses it.
/// **Any** diff failure (no previous on disk, download error, malformed patch,
/// hash mismatch) cleanly falls back to the full-module download. Diff-apply is
/// fully implemented (libbz2-backed), not stubbed.
public final class ModuleLoader: @unchecked Sendable {

    public enum LoadError: Error, CustomStringConvertible {
        case badURL(String)
        case httpStatus(Int, url: String)
        case transport(Error)
        case decompression(Error)
        case hashMismatch(expected: String, got: String)
        case diffUnavailable(String)
        case activation(Error)
        public var description: String {
            switch self {
            case .badURL(let s): return "loader: bad URL \(s)"
            case .httpStatus(let c, let u): return "loader: HTTP \(c) for \(u)"
            case .transport(let e): return "loader: transport error: \(e)"
            case .decompression(let e): return "loader: decompression failed: \(e)"
            case .hashMismatch(let e, let g): return "loader: SHA-256 mismatch (expected \(e), got \(g))"
            case .diffUnavailable(let r): return "loader: diff path unavailable: \(r)"
            case .activation(let e): return "loader: activation failed: \(e)"
            }
        }
    }

    /// What the loader produced for a single update.
    public struct LoadResult: Sendable {
        public let version: String
        public let sha256: String
        /// Whether the bytes were reconstructed from a diff (vs full download).
        public let usedDiff: Bool
        public let byteCount: Int
    }

    private let transport: HTTPTransport
    private let storage: ModuleStorage

    public init(storage: ModuleStorage, transport: HTTPTransport = URLSessionTransport()) {
        self.storage = storage
        self.transport = transport
    }

    // MARK: - Download

    private func download(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw LoadError.badURL(urlString) }
        if url.isFileURL {
            do { return try Data(contentsOf: url) }
            catch { throw LoadError.transport(error) }
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        do {
            let (data, status) = try await transport.send(req)
            guard (200...299).contains(status) else {
                throw LoadError.httpStatus(status, url: urlString)
            }
            return data
        } catch let e as LoadError {
            throw e
        } catch {
            throw LoadError.transport(error)
        }
    }

    /// Inflate if brotli, else return as-is. Brotli is detected from the URL
    /// suffix `.br` (the backend's `module.wasm.br`) or `forceBrotli`.
    private func maybeDecompress(_ data: Data, url: String, sizeHint: Int, forceBrotli: Bool) throws -> Data {
        let isBrotli = forceBrotli || url.hasSuffix(".br")
        guard isBrotli else { return data }
        do { return try Brotli.decompress(data, sizeHint: sizeHint) }
        catch { throw LoadError.decompression(error) }
    }

    // MARK: - Verify

    private func verify(_ raw: Data, expected sha: String) throws {
        let got = SHA256Hash.hexString(of: raw)
        guard got.caseInsensitiveCompare(sha) == .orderedSame else {
            throw LoadError.hashMismatch(expected: sha, got: got)
        }
    }

    // MARK: - Diff-only fetch (reconstruct without activating)

    /// Download a diff, apply it to the cached previous, and SHA-256-verify the
    /// result. Returns the raw reconstructed bytes. Throws `diffUnavailable` for
    /// any recoverable diff problem so the caller can fall back to a full fetch.
    public func fetchViaDiff(
        diffURL: String,
        baseVersion baseHint: String?,
        expectedSHA: String,
        sizeHint: Int
    ) async throws -> Data {
        let base: [UInt8]
        do {
            // The diff is "from previous"; the cached previous (or current, if
            // the device already runs the base) is the patch base. Prefer
            // previous, fall back to current.
            if let prev = try? storage.previousBytes() { base = prev }
            else { base = try storage.currentBytes() }
        } catch {
            throw LoadError.diffUnavailable("no cached base module to patch against")
        }

        let patchData: Data
        do { patchData = try await download(diffURL) }
        catch { throw LoadError.diffUnavailable("diff download failed: \(error)") }

        let reconstructed: Data
        do { reconstructed = try BSDIFF40Patch.apply(patch: patchData, to: Data(base)) }
        catch { throw LoadError.diffUnavailable("patch apply failed: \(error)") }

        // Verify the reconstruction against the new module's sha256.
        let got = SHA256Hash.hexString(of: reconstructed)
        guard got.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
            throw LoadError.diffUnavailable(
                "reconstructed sha mismatch (expected \(expectedSHA), got \(got))")
        }
        _ = baseHint  // accepted for API clarity; base selection is by slot today
        return reconstructed
    }

    // MARK: - Full-module fetch

    /// Download + decompress + verify a full module, returning raw verified bytes.
    public func fetchFull(
        moduleURL: String,
        expectedSHA: String,
        sizeHint: Int
    ) async throws -> Data {
        let downloaded = try await download(moduleURL)
        let raw = try maybeDecompress(downloaded, url: moduleURL, sizeHint: sizeHint, forceBrotli: false)
        try verify(raw, expected: expectedSHA)
        return raw
    }

    // MARK: - Acquire (fetch + verify, no activate, no cache)

    /// What `acquire` produced: the verified raw module bytes plus metadata,
    /// ready to be staged or activated by the caller.
    public struct AcquiredModule: Sendable {
        public let version: String
        public let sha256: String
        public let bytes: [UInt8]
        public let usedDiff: Bool
    }

    /// Acquire the module described by `response` (diff if possible, else full)
    /// and SHA-256-verify it, but do **not** activate or cache it. This is the
    /// "stage" half of the imperative update API: `fetchUpdate()` calls this
    /// to download+verify a pending update, holding the bytes until the developer
    /// calls `reloadAsync()`.
    public func acquire(_ response: UpdateCheckResponse) async throws -> AcquiredModule {
        guard let version = response.version,
              let moduleURL = response.module_url,
              let sha = response.sha256 else {
            throw LoadError.diffUnavailable("update response missing version/module_url/sha256")
        }
        let sizeHint = response.size ?? 0

        var raw: Data
        var usedDiff = false
        if let diffURL = response.diff_url {
            do {
                raw = try await fetchViaDiff(
                    diffURL: diffURL,
                    baseVersion: storage.previousVersion ?? storage.currentVersion,
                    expectedSHA: sha,
                    sizeHint: sizeHint)
                usedDiff = true
            } catch {
                raw = try await fetchFull(moduleURL: moduleURL, expectedSHA: sha, sizeHint: sizeHint)
            }
        } else {
            raw = try await fetchFull(moduleURL: moduleURL, expectedSHA: sha, sizeHint: sizeHint)
        }
        return AcquiredModule(version: version, sha256: sha, bytes: [UInt8](raw), usedDiff: usedDiff)
    }

    // MARK: - Orchestrated load

    /// Acquire the module described by `response` (diff if possible, else full),
    /// cache it as the new current, and activate it on `patch`.
    ///
    /// `activate` defaults to `Patch.shared.activate`; tests inject a closure to
    /// observe activation without a global. On success the new current is cached.
    /// Throws on hash mismatch or activation failure (the caller — typically the
    /// `FallbackManager` — then drives the chain).
    @discardableResult
    public func acquireAndActivate(
        _ response: UpdateCheckResponse,
        activate: ([UInt8]) throws -> Void
    ) async throws -> LoadResult {
        guard let version = response.version,
              let moduleURL = response.module_url,
              let sha = response.sha256 else {
            throw LoadError.diffUnavailable("update response missing version/module_url/sha256")
        }
        let sizeHint = response.size ?? 0

        var raw: Data
        var usedDiff = false
        if let diffURL = response.diff_url {
            do {
                raw = try await fetchViaDiff(
                    diffURL: diffURL,
                    baseVersion: storage.previousVersion ?? storage.currentVersion,
                    expectedSHA: sha,
                    sizeHint: sizeHint)
                usedDiff = true
            } catch {
                // Any diff problem → full download (always-correct fallback).
                raw = try await fetchFull(moduleURL: moduleURL, expectedSHA: sha, sizeHint: sizeHint)
            }
        } else {
            raw = try await fetchFull(moduleURL: moduleURL, expectedSHA: sha, sizeHint: sizeHint)
        }

        let bytes = [UInt8](raw)
        // Activate first; only cache if activation succeeds, so a trap-on-load
        // module never becomes the cached current.
        do { try activate(bytes) }
        catch { throw LoadError.activation(error) }
        try storage.installCurrent(version: version, sha256: sha, bytes: bytes)

        return LoadResult(version: version, sha256: sha, usedDiff: usedDiff, byteCount: bytes.count)
    }
}
