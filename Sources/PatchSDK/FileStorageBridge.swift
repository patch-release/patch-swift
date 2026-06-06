import Foundation
import WasmKit

// MARK: - File storage bridge (sandboxed read/write/delete)
//
// Gives an OTA patch the ability to persist small blobs in the app's sandbox —
// the Documents directory (user data that should be backed up) or the Caches
// directory (regenerable data the OS may evict). The guest passes a scope
// ("documents" / "caches") plus a relative path and (for writes) the bytes; the
// host resolves the path UNDER an injected base directory and performs the file
// operation with `FileManager` / `Data(contentsOf:)`.
//
// ## Cross-platform note (TWO HARD RULES, Rule 2)
// `FileManager` is plain cross-platform Foundation, so unlike the iOS-only
// bridges (UIKit/StoreKit/…) this one compiles AND runs on macOS directly. We
// still inject the **base directory** so tests can point it at a temp dir
// instead of clobbering the developer's real `~/Documents`. The convenience
// `init()` wires the real sandbox dir (Documents) resolved via `FileManager`,
// guarded by `#if canImport(Foundation)` (always true on Apple platforms, but
// kept explicit to mirror the guide's pattern).
//
// ## Security: path scoping + traversal guard
// Every path is resolved through `FileStorageBridge.resolve(base:scope:path:)`,
// which (a) selects the sub-scope directory, (b) standardizes the path, and
// (c) REJECTS any path that escapes the scope directory (`..` traversal,
// absolute paths, etc.). A rejected path returns nil → the host function fails
// closed (write/delete return 0, read returns 0/"no value", exists returns 0).
//
// ## Host functions (module "patch")
//   * file_write(scopePtr,scopeLen, pathPtr,pathLen, dataPtr,dataLen) -> i32
//        1 = written, 0 = rejected / IO error.
//   * file_read(scopePtr,scopeLen, pathPtr,pathLen) -> packed i64 (ptr<<32|len)
//        the file bytes, or 0 if absent / rejected.
//   * file_exists(scopePtr,scopeLen, pathPtr,pathLen) -> i32  (1 / 0)
//   * file_delete(scopePtr,scopeLen, pathPtr,pathLen) -> i32  (1 / 0)
public struct FileStorageBridge: Bridge {
    /// The two sandbox sub-scopes a patch may target.
    public enum Scope: String, Sendable {
        case documents
        case caches
    }

    public let module = "patch"

    /// Injected base directory. Each `Scope` maps to a subdirectory under this
    /// base (`<base>/documents`, `<base>/caches`). Tests inject a temp dir; the
    /// default `init()` injects the real sandbox container.
    private let baseDirectory: URL

    /// Cross-platform designated init — tests inject a temp dir here.
    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    #if canImport(Foundation)
    /// Real-sandbox convenience init. Uses the OS-provided Documents directory as
    /// the base; each `Scope` then nests under it (`<Documents>/documents`,
    /// `<Documents>/caches`). `FileManager` is cross-platform Foundation, so this
    /// compiles + runs on macOS too. Falls back to the temp dir if the sandbox
    /// directory can't be resolved.
    public init() {
        let fm = FileManager.default
        let docs = (try? fm.url(for: .documentDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.init(baseDirectory: docs)
    }
    #endif

    // MARK: - Path resolution + traversal guard (pure, unit-tested)

    /// Resolve a guest `(scope, path)` pair to a concrete file URL under `base`,
    /// or `nil` if the path is unsafe (traversal / escape / absolute).
    ///
    /// Rules:
    ///   * `scope` must be a known `Scope` ("documents" / "caches"). The scope
    ///     directory is `<base>/<scope>` — i.e. each scope is isolated in its own
    ///     subtree so "documents" data can never read "caches" data and vice
    ///     versa, regardless of what `base` points at.
    ///   * `path` must be relative. Leading `/` (absolute) is rejected.
    ///   * After standardizing, the resolved path MUST remain inside the scope
    ///     directory. Any `..` that climbs out (or an empty path) is rejected.
    ///
    /// - Returns: the resolved `URL`, or `nil` if rejected.
    public static func resolve(base: URL, scope: String, path: String) -> URL? {
        guard let scope = Scope(rawValue: scope) else { return nil }
        guard !path.isEmpty else { return nil }
        // Reject absolute paths outright (would escape the scope dir).
        if path.hasPrefix("/") { return nil }

        // Scope directory = <base>/<scope>, standardized to an absolute path.
        let scopeDir = base.appendingPathComponent(scope.rawValue, isDirectory: true)
            .standardizedFileURL
        let candidate = scopeDir.appendingPathComponent(path).standardizedFileURL

        // Containment check: the standardized candidate must live inside the
        // scope dir. `standardizedFileURL` collapses `..`, so an escaping path
        // produces a candidate whose path no longer has the scope-dir prefix.
        let scopePath = scopeDir.path
        let candidatePath = candidate.path
        let prefix = scopePath.hasSuffix("/") ? scopePath : scopePath + "/"
        guard candidatePath.hasPrefix(prefix) else { return nil }
        return candidate
    }

    // MARK: - File operations (operate on a resolved, in-scope URL)

    /// Write `data` to the resolved URL, creating intermediate directories.
    /// Returns false on any IO error (fail-closed).
    static func write(_ data: [UInt8], to url: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data(data).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Read bytes from the resolved URL, or nil if absent / unreadable.
    static func read(_ url: URL) -> [UInt8]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return [UInt8](data)
    }

    /// True if a file exists at the resolved URL.
    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Delete the file at the resolved URL. Returns true if it was removed (or
    /// did not exist); false only on a real removal error.
    static func delete(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }
        do { try fm.removeItem(at: url); return true } catch { return false }
    }

    // MARK: - Registration

    public func register(into imports: inout Imports, store: Store) {
        let base = self.baseDirectory

        imports.host(module, "file_write", [.i32, .i32, .i32, .i32, .i32, .i32], [.i32],
                     store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let scope = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let path = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            let data = try ctx.readBytes(ptr: args[4].i32, len: args[5].i32)
            guard let url = Self.resolve(base: base, scope: scope, path: path) else {
                return [.i32(0)]
            }
            return [.i32(Self.write(data, to: url) ? 1 : 0)]
        }

        imports.host(module, "file_read", [.i32, .i32, .i32, .i32], [.i64],
                     store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let scope = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let path = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            guard let url = Self.resolve(base: base, scope: scope, path: path) else {
                return [.i64(0)]
            }
            return [try ctx.packedResult(Self.read(url))]
        }

        imports.host(module, "file_exists", [.i32, .i32, .i32, .i32], [.i32],
                     store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let scope = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let path = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            guard let url = Self.resolve(base: base, scope: scope, path: path) else {
                return [.i32(0)]
            }
            return [.i32(Self.exists(url) ? 1 : 0)]
        }

        imports.host(module, "file_delete", [.i32, .i32, .i32, .i32], [.i32],
                     store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let scope = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let path = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            guard let url = Self.resolve(base: base, scope: scope, path: path) else {
                return [.i32(0)]
            }
            return [.i32(Self.delete(url) ? 1 : 0)]
        }
    }
}
