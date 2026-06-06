import Foundation

/// On-disk module cache.
///
/// Holds up to three module slots per the plan's fallback chain
/// (current → previous → bundled → disabled):
///
/// - **current**  — the active OTA module the loader last verified + activated.
/// - **previous** — the prior OTA module, kept so a failed `current` can roll
///   back one step without a network round-trip.
/// - **bundled**  — a module shipped inside the app bundle (registered by the
///   host app); the last-resort OTA module before falling all the way to
///   "disabled" (native-only).
///
/// Layout under the cache directory (default: app's Caches dir):
/// ```
/// <root>/PatchSDK/<appKey>/
///   manifest.json              # which version is current/previous + sha + size
///   modules/<version>.wasm     # raw, inflated, verified module bytes
/// ```
/// Each slot's bytes are stored **raw and pre-verified** (the loader inflates +
/// SHA-256-checks before handing them here), so activation never re-fetches or
/// re-decompresses. The plan budgets 3–6 MB per module; keeping current +
/// previous is ~6–12 MB, within the "3–6 MB" per-slot intent.
///
/// Writes are **atomic**: bytes land in a temp file then `replaceItem` swaps
/// them into place, and the manifest is rewritten atomically, so a crash mid-swap
/// never leaves a torn "current".
public final class ModuleStorage: @unchecked Sendable {

    /// Persisted record of what is cached. Codable so it survives launches.
    public struct Manifest: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var version: String
            public var sha256: String
            public var size: Int
            public init(version: String, sha256: String, size: Int) {
                self.version = version; self.sha256 = sha256; self.size = size
            }
        }
        public var current: Entry?
        public var previous: Entry?
        public init(current: Entry? = nil, previous: Entry? = nil) {
            self.current = current; self.previous = previous
        }
        public static let empty = Manifest()
    }

    public enum StorageError: Error, CustomStringConvertible {
        case slotEmpty(String)
        case io(Error)
        public var description: String {
            switch self {
            case .slotEmpty(let s): return "storage: slot \(s) is empty"
            case .io(let e): return "storage: I/O error: \(e)"
            }
        }
    }

    private let root: URL
    private let modulesDir: URL
    private let manifestURL: URL
    private let fm = FileManager.default
    private let lock = NSLock()

    /// Bytes the host app registered as the bundled fallback (shipped in-app).
    /// Not stored on disk — it already lives in the app bundle.
    private var bundled: (version: String, bytes: [UInt8])?

    /// - Parameters:
    ///   - appKey: namespaces the cache so multiple apps/keys don't collide.
    ///   - baseDirectory: parent dir; default is the app's Caches directory.
    public init(appKey: String, baseDirectory: URL? = nil) throws {
        let base = baseDirectory ?? Self.defaultCachesDirectory()
        self.root = base.appendingPathComponent("PatchSDK/\(appKey)", isDirectory: true)
        self.modulesDir = root.appendingPathComponent("modules", isDirectory: true)
        self.manifestURL = root.appendingPathComponent("manifest.json")
        try fm.createDirectory(at: modulesDir, withIntermediateDirectories: true)
    }

    private static func defaultCachesDirectory() -> URL {
        if let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return url
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
    }

    // MARK: - Manifest

    /// Read the persisted manifest (empty if none / unreadable).
    public func manifest() -> Manifest {
        lock.lock(); defer { lock.unlock() }
        return readManifestLocked()
    }

    private func readManifestLocked() -> Manifest {
        guard let data = try? Data(contentsOf: manifestURL),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return .empty
        }
        return m
    }

    private func writeManifestLocked(_ m: Manifest) throws {
        let data = try JSONEncoder().encode(m)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func moduleURL(version: String) -> URL {
        // Sanitize version into a safe filename component.
        let safe = version.replacingOccurrences(of: "/", with: "_")
                          .replacingOccurrences(of: "..", with: "_")
        return modulesDir.appendingPathComponent("\(safe).wasm")
    }

    // MARK: - Bundled slot (in-app fallback)

    /// Register the app-bundled module as the bundled fallback slot.
    public func registerBundled(version: String, bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        bundled = (version, bytes)
    }

    public var hasBundled: Bool {
        lock.lock(); defer { lock.unlock() }
        return bundled != nil
    }

    public func bundledBytes() throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        guard let b = bundled else { throw StorageError.slotEmpty("bundled") }
        return b.bytes
    }

    public func bundledVersion() -> String? {
        lock.lock(); defer { lock.unlock() }
        return bundled?.version
    }

    // MARK: - Current / previous

    public var currentVersion: String? { manifest().current?.version }
    public var previousVersion: String? { manifest().previous?.version }

    /// Install `bytes` (already inflated + verified) as the new **current**,
    /// demoting the existing current to **previous**. Atomic: the file is
    /// written to a temp path then swapped, and the manifest is updated last.
    public func installCurrent(version: String, sha256: String, bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        var m = readManifestLocked()

        let dst = moduleURL(version: version)
        try writeAtomically(Data(bytes), to: dst)

        // Demote the old current to previous (if it differs), and prune the
        // module file that previous used to point at (keep at most 2 on disk).
        if let oldCurrent = m.current, oldCurrent.version != version {
            // The file that *was* previous is now eligible for deletion.
            if let oldPrev = m.previous, oldPrev.version != version,
               oldPrev.version != oldCurrent.version {
                try? fm.removeItem(at: moduleURL(version: oldPrev.version))
            }
            m.previous = oldCurrent
        }
        m.current = Manifest.Entry(version: version, sha256: sha256, size: bytes.count)
        try writeManifestLocked(m)
    }

    /// Promote **previous** to **current** (used by the fallback chain after the
    /// current module is rejected). The demoted current's file is removed.
    /// Returns the bytes now in the current slot, or throws if there is no
    /// previous to promote.
    @discardableResult
    public func promotePreviousToCurrent() throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        var m = readManifestLocked()
        guard let prev = m.previous else { throw StorageError.slotEmpty("previous") }
        let bytes = try loadBytesLocked(version: prev.version)

        if let badCurrent = m.current, badCurrent.version != prev.version {
            try? fm.removeItem(at: moduleURL(version: badCurrent.version))
        }
        m.current = prev
        m.previous = nil
        try writeManifestLocked(m)
        return bytes
    }

    /// Drop the current slot entirely (e.g. when falling to bundled/disabled).
    public func clearCurrent() {
        lock.lock(); defer { lock.unlock() }
        var m = readManifestLocked()
        if let cur = m.current { try? fm.removeItem(at: moduleURL(version: cur.version)) }
        m.current = nil
        try? writeManifestLocked(m)
    }

    public func currentBytes() throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        guard let cur = readManifestLocked().current else { throw StorageError.slotEmpty("current") }
        return try loadBytesLocked(version: cur.version)
    }

    public func previousBytes() throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        guard let prev = readManifestLocked().previous else { throw StorageError.slotEmpty("previous") }
        return try loadBytesLocked(version: prev.version)
    }

    private func loadBytesLocked(version: String) throws -> [UInt8] {
        do {
            return [UInt8](try Data(contentsOf: moduleURL(version: version)))
        } catch { throw StorageError.io(error) }
    }

    /// Wipe the on-disk cache (current + previous). Does not touch bundled.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        try? fm.removeItem(at: modulesDir)
        try? fm.createDirectory(at: modulesDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: manifestURL)
    }

    // MARK: - Atomic write

    private func writeAtomically(_ data: Data, to dst: URL) throws {
        do {
            let tmp = modulesDir.appendingPathComponent(".tmp-\(UUID().uuidString)")
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: dst.path) {
                _ = try fm.replaceItemAt(dst, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dst)
            }
        } catch { throw StorageError.io(error) }
    }
}
