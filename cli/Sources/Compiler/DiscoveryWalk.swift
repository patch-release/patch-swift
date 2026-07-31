// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Bounded recursive filesystem walk for project discovery.
///
/// Plain `FileManager.enumerator(at:options:[.skipsHiddenFiles])` descends into
/// EVERY non-hidden directory — including `node_modules`, `Pods`, `Carthage`,
/// `DerivedData`, and `build`, which on a real app can hold 100k+ files. That
/// made `patch init` appear to hang (a multi-minute walk, or an unbounded one
/// through a symlink cycle). This helper prunes those directories and never
/// follows symlinked directories, so discovery stays fast and finite.
public enum DiscoveryWalk {
    /// Directory names never descended into: dependency caches, build artifacts,
    /// VCS metadata. (`.git` / `.build` / `.swiftpm` are already hidden and thus
    /// skipped by `.skipsHiddenFiles`, but are listed for clarity and in case
    /// hidden-skipping is ever relaxed.)
    public static let prunedDirNames: Set<String> = [
        "node_modules", "Pods", "Carthage", "DerivedData", "build", ".build",
        "vendor", ".git", ".svn", ".hg", ".swiftpm", ".gradle", ".cache",
        "dist", ".next", "__pycache__", ".terraform", "Frameworks",
    ]

    /// Recursively visit files/directories under `root`, pruning heavy
    /// directories and symlinked directories. Return `false` from `visit` to
    /// stop the walk early (e.g. the moment the first match is found). Any
    /// `keys` requested are pre-fetched for each URL.
    public static func walk(
        _ root: URL,
        fm: FileManager = .default,
        keys: [URLResourceKey] = [],
        visit: (URL) -> Bool
    ) {
        let probe: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let e = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(Set(keys).union(probe)),
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in e {
            let vals = try? url.resourceValues(forKeys: probe)
            let isDir = vals?.isDirectory ?? false
            let isLink = vals?.isSymbolicLink ?? false
            // Prune dependency/build caches and never follow a symlinked
            // directory (the classic way a recursive walk loops forever).
            if isDir && (isLink || prunedDirNames.contains(url.lastPathComponent)) {
                e.skipDescendants()
                continue
            }
            if !visit(url) { return }
        }
    }
}
