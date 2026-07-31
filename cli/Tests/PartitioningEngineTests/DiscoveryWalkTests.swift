// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler

/// Regression tests for the `patch init` freeze: project discovery used a plain
/// recursive `FileManager.enumerator`, which walked `node_modules`/`Pods`/
/// `DerivedData`/`build` (100k+ files on a real app) and followed symlink
/// cycles — so `patch init` appeared to hang. `DiscoveryWalk` prunes those.
final class DiscoveryWalkTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dwtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Heavy dependency/build directories are never descended into.
    func testPrunesHeavyDirectories() throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        try "top".write(to: root.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)
        for heavy in ["node_modules", "Pods", "build", "DerivedData"] {
            let d = root.appendingPathComponent(heavy).appendingPathComponent("nested")
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try "buried".write(to: d.appendingPathComponent("buried.txt"), atomically: true, encoding: .utf8)
        }
        var visited: Set<String> = []
        DiscoveryWalk.walk(root, fm: fm) { url in visited.insert(url.lastPathComponent); return true }
        XCTAssertTrue(visited.contains("real.txt"), "should visit top-level files")
        XCTAssertFalse(visited.contains("buried.txt"),
                       "must NOT descend into node_modules/Pods/build/DerivedData")
    }

    /// A symlink cycle terminates instead of looping forever.
    func testSymlinkCycleTerminates() throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: sub.appendingPathComponent("loop"), withDestinationURL: root)
        var count = 0
        DiscoveryWalk.walk(root, fm: fm) { _ in count += 1; return count < 10_000 }
        XCTAssertLessThan(count, 10_000, "symlink cycle should be pruned, not looped")
    }

    /// `bundleIdentifier` ignores a decoy bundle id buried in `node_modules`.
    func testBundleIdentifierIgnoresNodeModulesDecoy() throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let decoy = root.appendingPathComponent("node_modules/dep/ios/Decoy.xcodeproj")
        try fm.createDirectory(at: decoy, withIntermediateDirectories: true)
        try "PRODUCT_BUNDLE_IDENTIFIER = com.decoy.fake;"
            .write(to: decoy.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        let real = root.appendingPathComponent("MyApp.xcodeproj")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try "PRODUCT_BUNDLE_IDENTIFIER = com.acme.real;"
            .write(to: real.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        let id = ProjectDiscovery.bundleIdentifier(in: root, fm: fm)
        XCTAssertEqual(id, "com.acme.real")
        XCTAssertNotEqual(id, "com.decoy.fake")
    }
}
