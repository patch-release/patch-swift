// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
@testable import Compiler
@testable import PatchCLI

/// The per-view COMPATIBILITY SUMMARY printed after `patchcli prepare`/`init` (and written by
/// `prepare --report <path>`). Reporting-only: it must never change what prepare generates.
final class ViewCompatibilityReportTests: XCTestCase {

    private func tmp(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("compat-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A view that stays native: its child slot reads a body-local `let` the thunk can't see.
    static let nativeView = """
    import SwiftUI
    struct ScoreView: View {
        var body: some View {
            let n = Int.random(in: 0...3)
            VStack { Text("score"); ScoreRow(n: n) }
        }
    }
    struct ScoreRow: View { let n: Int; var body: some View { Text("\\(n)") } }
    """

    private func makeProject() throws -> URL {
        let dir = try tmp("proj")
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", platforms: [.iOS(.v17)], targets: [ .target(name: "App") ])
        """, to: dir.appendingPathComponent("Package.swift"))
        let src = dir.appendingPathComponent("Sources/App")
        try write(ThunkHybridMultiFileCompileTests.mixToolPanel, to: src.appendingPathComponent("MixToolPanel.swift"))
        try write(ThunkHybridMultiFileCompileTests.keyframeToolPanel, to: src.appendingPathComponent("KeyframeToolPanel.swift"))
        try write(ThunkHybridMultiFileCompileTests.helloFile, to: src.appendingPathComponent("HelloPanel.swift"))
        try write(Self.nativeView, to: src.appendingPathComponent("ScoreView.swift"))
        return dir
    }

    func testReportNamesPrivateTypeToolbarAndNativeReasons() throws {
        let dir = try makeProject()
        let sources = Prepare.swiftSources(in: dir, excludes: [])
        let result = ThunkGenerator().prepare(sources: sources.map { .init(url: $0.url, text: $0.text) }, hybrid: true)
        let report = ViewCompatibilityReport.build(from: result, sources: sources.map(\.text))
        let byName = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.view, $0) })

        XCTAssertEqual(byName["HelloPanel"]?.status, .patchable)
        XCTAssertNil(byName["HelloPanel"]?.placementNote)

        // Private-access forwarding (the default): the private child view types are reached through
        // PATCH-ACCESS factories, so nothing is kept beside the source — an info note only.
        let mix = try XCTUnwrap(byName["MixToolPanel"])
        XCTAssertEqual(mix.status, .patchable)
        XCTAssertNil(mix.placementNote, String(describing: mix.placementNote))
        XCTAssertTrue(mix.accessNote?.contains("reaches private MixGainRow, MixTrackRow via PATCH-ACCESS forwarders") == true,
                      String(describing: mix.accessNote))
        // With forwarding off (legacy layout), the report still names the private types forcing same-file.
        let legacy = ThunkGenerator().prepare(sources: sources.map { .init(url: $0.url, text: $0.text) },
                                              hybrid: true, accessForwarding: false)
        let legacyMix = try XCTUnwrap(ViewCompatibilityReport.build(from: legacy, sources: sources.map(\.text))
            .entries.first { $0.view == "MixToolPanel" })
        XCTAssertTrue(legacyMix.placementNote?.contains("private type/symbol MixGainRow, MixTrackRow") == true,
                      String(describing: legacyMix.placementNote))
        XCTAssertTrue(legacyMix.placementNote?.contains("thunk kept beside source") == true)

        let keyframe = try XCTUnwrap(byName["KeyframeToolPanel"])
        XCTAssertEqual(keyframe.status, .patchable, "the ToolbarContent view still auto-routes")
        XCTAssertEqual(keyframe.nativeParts, ["toolbar — ToolbarContent kept native"])

        let score = try XCTUnwrap(byName["ScoreView"])
        XCTAssertEqual(score.status, .native)
        XCTAssertTrue(score.reason?.contains("`ScoreRow`") == true && score.reason?.contains("body-local") == true,
                      String(describing: score.reason))

        let lines = report.consoleLines()
        XCTAssertTrue(lines[0].hasPrefix("Compatibility: \(report.patchableCount) of \(report.entries.count) view(s) patchable OTA"), lines[0])
        XCTAssertTrue(lines.contains { $0.contains("ScoreView — native:") }, lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("MixToolPanel —") },
                       "a forwarded view is not a console warning:\n" + lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("KeyframeToolPanel.toolbar — ToolbarContent kept native") },
                      lines.joined(separator: "\n"))
        // Native views are listed first.
        let firstDetail = try XCTUnwrap(lines.dropFirst().first)
        XCTAssertTrue(firstDetail.contains("native:"), lines.joined(separator: "\n"))
    }

    /// `--report <path>` writes the Markdown table, and it is REPORTING-ONLY: a prepare with
    /// the report produces byte-identical sources/thunks to one without.
    func testReportFileIsWrittenAndPrepareOutputIsUnchanged() throws {
        let a = try makeProject()
        let b = try makeProject()
        let reportURL = a.appendingPathComponent("out/patch-compatibility.md")
        _ = try Prepare.execute(root: a, excludes: [], target: "App", assumeYes: true, thunksOnly: false,
                                check: false, quiet: true, reportPath: reportURL.path)
        _ = try Prepare.execute(root: b, excludes: [], target: "App", assumeYes: true, thunksOnly: false,
                                check: false, quiet: true)
        let md = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(md.contains("| `MixToolPanel` | patchable | reaches private MixGainRow, MixTrackRow via PATCH-ACCESS forwarders"), md)
        XCTAssertTrue(md.contains("| `ScoreView` | native |"), md)
        XCTAssertTrue(md.contains("| `KeyframeToolPanel` | patchable |"), md)

        for rel in ["Sources/App/MixToolPanel.swift", "Sources/App/KeyframeToolPanel.swift",
                    "Sources/App/HelloPanel.swift", "Sources/App/ScoreView.swift",
                    "Sources/App/Patch/Generated/PatchThunks.generated.swift"] {
            let ta = try String(contentsOf: a.appendingPathComponent(rel), encoding: .utf8)
            let tb = try String(contentsOf: b.appendingPathComponent(rel), encoding: .utf8)
            XCTAssertEqual(ta, tb, "\(rel) must be identical with/without --report")
        }
    }
}
