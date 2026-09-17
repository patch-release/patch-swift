// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler
@testable import CodeGenerator

/// THE MOST DANGEROUS FINGERPRINT CLASS: a source edit that SHOULD churn the native-shell hash
/// but doesn't — the patch then ships against a binary it wasn't built for.
///
/// The native-shell hash is computed in two passes over each file: first the lifted string
/// literals (which ride WASM, so their VALUE is not native shell) are replaced by a fixed
/// placeholder, THEN the OTA-eligible function bodies are neutralized BY LINE NUMBER. The second
/// pass is only correct if the first preserved the line numbering — which the walker's own
/// comment asserts ("a single-segment string literal is always on one line, and the placeholder
/// carries no newline, so line COUNT is invariant").
///
/// The lifter broke that assertion: it lifted `"""` MULTI-LINE literals too, so the placeholder
/// swallowed their newlines and every line after them shifted. The body-span strip then
/// neutralized the WRONG lines — i.e. real NATIVE code was normalized away, and editing it left
/// the fingerprint unchanged.
///
/// These tests pin both halves of the invariant from the outside: the hash of a real project,
/// before and after an edit.
final class FingerprintLiftedLiteralLineTests: XCTestCase {

    private func tmpRoot(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-fp-litline-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func write(_ root: URL, _ rel: String, _ contents: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: u, atomically: true, encoding: .utf8)
    }

    private func fingerprint(_ root: URL) -> String {
        ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint
    }

    /// THE MECHANISM, isolated: `shellNormalizedHash` replaces the lifted-literal byte ranges
    /// FIRST and strips the OTA-eligible body spans BY LINE second. A literal range spanning
    /// newlines collapses the file, so the line-based strip lands on the WRONG lines — here it
    /// would neutralize the NATIVE `native()` function that follows, and editing that function
    /// leaves the shell hash unchanged (the patch then ships against a binary it wasn't built
    /// for). With the line count preserved, the strip hits what it was computed for and the
    /// native edit churns.
    func testAMultiLineLiteralRangeDoesNotRenumberTheNativeCodeAfterIt() throws {
        let root = tmpRoot("mechanism")
        defer { try? FileManager.default.removeItem(at: root) }
        let q = "\"\"\""
        // Line 2 opens a 4-line literal (lines 2–5); the NATIVE function is lines 6–8.
        func file(_ nativeLine: String) -> String {
            """
            import SwiftUI
            let banner = \(q)
            Alpha
            Beta
            \(q)
            func native() {
                \(nativeLine)
            }
            """
        }
        // The OTA-eligible span is the `banner` declaration (lines 2–5): interior lines 3–5 are
        // neutralized. Collapsing the literal to one line would make "3–5" mean the NATIVE
        // function instead.
        let spans = [(start: 2, end: 5)]
        func hash(_ nativeLine: String) throws -> String {
            let url = root.appendingPathComponent("F.swift")
            try file(nativeLine).write(to: url, atomically: true, encoding: .utf8)
            let text = file(nativeLine)
            let lo = text.utf8.distance(from: text.startIndex, to: text.range(of: q)!.lowerBound)
            let hi = text.utf8.distance(from: text.startIndex,
                                        to: text.range(of: q, options: .backwards)!.upperBound)
            return ProjectFingerprinter.shellNormalizedHash(of: url, eligibleSpans: spans,
                                                            slotLiteralRanges: [lo..<hi])
        }
        let before = try hash(#"print("v1")"#)
        let after = try hash(#"print("v2-CHANGED")"#)
        XCTAssertNotEqual(before, after,
                          "a NATIVE line after a multi-line lifted literal MUST stay hashed — "
                          + "otherwise the literal's collapse renumbers the file, the body-span "
                          + "strip neutralizes the wrong lines, and a real native edit ships with "
                          + "a stale fingerprint (before=\(before) after=\(after))")
    }

    /// The other half: editing the SINGLE-LINE lifted literal (which genuinely rides WASM) must
    /// still leave the hash stable — the coverage this whole mechanism exists for.
    func testEditingASingleLineLiftedLiteralKeepsTheHashStable() throws {
        let root = tmpRoot("stable")
        defer { try? FileManager.default.removeItem(at: root) }
        func src(_ note: String) -> String {
            """
            import SwiftUI

            struct DetailScreen: View {
                let flag: Bool
                var body: some View {
                    MyRow(title: "Details", note: "\(note)")
                }
            }
            """
        }
        try write(root, "App/DetailScreen.swift", src("ok"))
        let before = fingerprint(root)
        try write(root, "App/DetailScreen.swift", src("okay then"))
        XCTAssertEqual(fingerprint(root), before,
                       "editing a lifted single-line literal rides WASM — it must NOT churn the "
                       + "native-shell hash (that would be a false MISMATCH)")
    }

    /// And the multi-line literal itself, now that it stays BAKED, must churn — the safe failure.
    /// (A MISMATCH tells the developer to rebuild; silently shipping would not.)
    func testEditingTheBakedMultiLineLiteralChurnsTheHash() throws {
        let root = tmpRoot("bakededit")
        defer { try? FileManager.default.removeItem(at: root) }
        let q = "\"\"\""
        func src(_ second: String) -> String {
            """
            import SwiftUI

            struct DetailScreen: View {
                let flag: Bool
                var body: some View {
                    MyRow(title: \(q)
                    Alpha
                    \(second)
                    \(q), note: "ok")
                }
            }
            """
        }
        try write(root, "App/DetailScreen.swift", src("Beta"))
        let before = fingerprint(root)
        try write(root, "App/DetailScreen.swift", src("Gamma"))
        XCTAssertNotEqual(fingerprint(root), before,
                          "a baked multi-line literal is native content — editing it must churn")
    }
}
