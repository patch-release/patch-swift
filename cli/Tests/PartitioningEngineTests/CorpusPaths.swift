// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where the local measurement corpus lives.
///
/// Several suites in this target are *measurement harnesses* — they run the
/// engine over a checkout of real open-source Swift apps to report coverage or
/// module sizes. That corpus is large and local-only (gitignored), so those
/// suites are all env-gated and skip when it is absent.
///
/// This resolves the corpus location without depending on any one machine's
/// home directory: an explicit `PATCH_CORPUS` / `PATCH_CORPUS_ROOT` override
/// wins, otherwise it falls back to `<repo>/corpus/repos`, derived from this
/// source file's own path so it is correct in any checkout or git worktree.
enum CorpusPaths {

    /// The repository root, derived from this file's compile-time path
    /// (`<repo>/cli/Tests/PartitioningEngineTests/CorpusPaths.swift`).
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PartitioningEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // cli
            .deletingLastPathComponent()   // <repo>
    }

    /// Default corpus location when no environment override is set.
    static var defaultRepos: String {
        repoRoot.appendingPathComponent("corpus/repos").path
    }

    /// The corpus root to use, honouring `PATCH_CORPUS` then `PATCH_CORPUS_ROOT`.
    /// Returns `nil` when nothing exists on disk (callers skip).
    static func resolvedRoot() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["PATCH_CORPUS"], env["PATCH_CORPUS_ROOT"], defaultRepos]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        for c in candidates {
            let u = URL(fileURLWithPath: c, isDirectory: true)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}
