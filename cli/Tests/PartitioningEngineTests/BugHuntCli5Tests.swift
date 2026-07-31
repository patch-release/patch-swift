// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import PartitioningEngine
@testable import Compiler

/// Bug-hunt wave 5 (CLI + engine). Each test pins a real defect found in this
/// pass (FIXED in the same change) so a regression re-trips it, plus coverage for
/// the new app-icon extraction feature.
final class BugHuntCli5Tests: XCTestCase {

    // MARK: - P1: computed-property / accessor function-stack leak corrupted
    //         every closure id parsed LATER in the same file.

    /// A computed property (and a get/set accessor) used to push onto the
    /// extractor's function-name stack but never pop it (only `func`/`init` had a
    /// matching `visitPost`). So the FIRST computed property before any closure
    /// permanently polluted the qualified id of every subsequent closure — the
    /// call-graph key. After the fix, a closure inside a plain method is qualified
    /// by THAT method only, regardless of an earlier computed property.
    func testComputedPropertyDoesNotLeakIntoLaterClosureIds() {
        let src = """
        struct Widget {
            var doubled: Int {
                let xs = [1, 2, 3]
                return xs.map { $0 * 2 }.reduce(0, +)
            }
            func process() {
                let ys = [4, 5]
                _ = ys.map { $0 + 1 }
            }
        }
        """
        let recs = SwiftParserEngine().parse(
            source: src, file: URL(fileURLWithPath: "/tmp/WidgetMod/Widget.swift"))
        let closures = recs.filter { $0.kind == .closure }
        XCTAssertEqual(closures.count, 2, "expected one closure per body; got \(closures.map(\.id))")

        // The closure inside `process()` must be qualified by `process`, NOT by the
        // earlier computed property `doubled` (the leak symptom).
        guard let processClosure = closures.first(where: { $0.id.contains("process(") }) else {
            return XCTFail("no closure qualified by process(); got \(closures.map(\.id))")
        }
        XCTAssertFalse(processClosure.id.contains("doubled"),
            "process()'s closure id leaked the earlier computed property: \(processClosure.id)")

        // And the computed property's own closure must be qualified by `doubled`,
        // not by some unrelated prefix.
        guard let doubledClosure = closures.first(where: { $0.id.contains("doubled") }) else {
            return XCTFail("no closure qualified by doubled; got \(closures.map(\.id))")
        }
        XCTAssertFalse(doubledClosure.id.contains("process"),
            "the computed-property closure id should not contain process: \(doubledClosure.id)")
    }

    /// Stronger form: TWO computed properties in a row, then a method with a
    /// closure. Pre-fix, the method-closure id accumulated BOTH leaked property
    /// names. The id must contain neither.
    func testMultipleComputedPropertiesDoNotAccumulateInClosureId() {
        let src = """
        struct Store {
            var a: Int { return 1 }
            var b: Int { return 2 }
            func run() {
                _ = [1].map { $0 }
            }
        }
        """
        let recs = SwiftParserEngine().parse(
            source: src, file: URL(fileURLWithPath: "/tmp/StoreMod/Store.swift"))
        guard let closure = recs.first(where: { $0.kind == .closure }) else {
            return XCTFail("expected a closure record")
        }
        XCTAssertTrue(closure.id.contains("run("),
            "closure should be qualified by run(); got \(closure.id)")
        XCTAssertFalse(closure.id.contains(".a") || closure.id.contains(".b"),
            "closure id leaked computed-property names: \(closure.id)")
    }

    // MARK: - P2: WasmModuleMerger.memoryCount mis-parsed a TABLE import, which
    //         could desync the import-section scan on a module importing a table
    //         before its memory.

    /// A synthesized wasm module that imports a table (kind 0x01) and then a memory
    /// (kind 0x02) must be counted as exactly ONE memory. The old parser read the
    /// table's limits-flags byte as the min LEB and inspected a stale byte for the
    /// max bit, desyncing the cursor.
    func testMemoryCountParsesTableImportBeforeMemoryImport() throws {
        // Build a minimal valid-enough wasm: magic+version, then an Import section
        // with [import "env"."t" table, import "env"."m" memory].
        var bytes: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]

        func leb(_ n: Int) -> [UInt8] {
            var v = n, out: [UInt8] = []
            repeat {
                var b = UInt8(v & 0x7f); v >>= 7
                if v != 0 { b |= 0x80 }
                out.append(b)
            } while v != 0
            return out
        }
        func nameBytes(_ s: String) -> [UInt8] { leb(s.utf8.count) + Array(s.utf8) }

        // import 1: env.t  table: reftype 0x70 (funcref), limits flags 0x00, min 1
        let imp1 = nameBytes("env") + nameBytes("t") + [0x01, 0x70, 0x00] + leb(1)
        // import 2: env.m  memory: limits flags 0x00, min 1
        let imp2 = nameBytes("env") + nameBytes("m") + [0x02, 0x00] + leb(1)

        let section = leb(2) + imp1 + imp2   // count = 2 imports
        let importSection: [UInt8] = [0x02] + leb(section.count) + section
        bytes += importSection

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("memcount-\(UUID().uuidString).wasm")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(bytes).write(to: tmp)

        let merger = WasmModuleMerger()
        XCTAssertEqual(merger.memoryCount(of: tmp), 1,
            "a table import before a memory import must still count exactly 1 memory")
    }

    // MARK: - Feature: app-icon extraction from an asset catalog.

    /// `AppIconLocator` picks the LARGEST PNG from `AppIcon.appiconset`.
    func testLocatesLargestPNGInAppIconSet() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let iconSet = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
        try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
        // A small 60pt and a big 1024pt PNG (size = byte length here).
        try Data(pngBytes(payload: 100)).write(to: iconSet.appendingPathComponent("Icon-60.png"))
        try Data(pngBytes(payload: 4000)).write(to: iconSet.appendingPathComponent("Icon-1024.png"))

        let icon = AppIconLocator.locate(in: root)
        XCTAssertNotNil(icon, "should find an icon in the asset catalog")
        XCTAssertEqual(icon?.url.lastPathComponent, "Icon-1024.png", "must pick the LARGEST PNG")
        XCTAssertEqual(icon?.mimeType, "image/png")
        XCTAssertEqual(icon?.byteCount, pngBytes(payload: 4000).count)
    }

    /// Prefers the canonically-named `AppIcon.appiconset` over an `AppIcon-Dark`
    /// variant even when the variant's PNG is larger (the primary icon wins).
    func testPrefersCanonicalAppIconSet() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("X.xcassets/AppIcon.appiconset")
        let dark = root.appendingPathComponent("X.xcassets/AppIcon-Dark.appiconset")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dark, withIntermediateDirectories: true)
        try Data(pngBytes(payload: 500)).write(to: primary.appendingPathComponent("p.png"))
        try Data(pngBytes(payload: 9000)).write(to: dark.appendingPathComponent("d.png"))

        let icon = AppIconLocator.locate(in: root)
        XCTAssertEqual(icon?.url.lastPathComponent, "p.png",
            "the canonical AppIcon.appiconset must win over AppIcon-Dark even if smaller")
    }

    /// Falls back to the `Info.plist` `CFBundleIcons` loose-PNG layout when there is
    /// no asset catalog.
    func testFallsBackToInfoPlistCFBundleIcons() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let appDir = root.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        // A plist naming AppIcon60x60 as the primary icon.
        let plist: [String: Any] = [
            "CFBundleIcons": [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconFiles": ["AppIcon29x29", "AppIcon60x60"],
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: appDir.appendingPathComponent("Info.plist"))
        // The actual PNGs on disk (an @2x variant should win as the largest).
        try Data(pngBytes(payload: 200)).write(to: appDir.appendingPathComponent("AppIcon60x60.png"))
        try Data(pngBytes(payload: 800)).write(to: appDir.appendingPathComponent("AppIcon60x60@2x.png"))

        let icon = AppIconLocator.locate(in: root)
        XCTAssertNotNil(icon, "should resolve the icon from Info.plist CFBundleIcons")
        XCTAssertTrue(icon?.url.lastPathComponent.hasPrefix("AppIcon60x60") ?? false,
            "resolved icon should match the plist base name; got \(icon?.url.lastPathComponent ?? "nil")")
        XCTAssertEqual(icon?.byteCount, pngBytes(payload: 800).count, "should pick the largest variant")
    }

    /// No icon anywhere → returns nil cleanly (callers SKIP, never fail).
    func testReturnsNilWhenNoIconPresent() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try "let x = 1".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        XCTAssertNil(AppIconLocator.locate(in: root), "no icon → nil (skip cleanly)")
    }

    /// An empty (0-byte) PNG is ignored — a placeholder asset must not be uploaded.
    func testIgnoresEmptyPNG() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let iconSet = root.appendingPathComponent("A.xcassets/AppIcon.appiconset")
        try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
        try Data().write(to: iconSet.appendingPathComponent("empty.png"))
        XCTAssertNil(AppIconLocator.locate(in: root), "an empty PNG must not be returned")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A byte buffer that begins with the PNG magic, padded to `payload` bytes so
    /// the file size is deterministic for the largest-PNG selection.
    private func pngBytes(payload: Int) -> [UInt8] {
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return magic + Array(repeating: 0x00, count: max(0, payload - magic.count))
    }
}
