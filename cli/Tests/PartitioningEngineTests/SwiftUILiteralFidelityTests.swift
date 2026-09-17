// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR
import SwiftSyntax
import SwiftParser

/// FIDELITY of the values the string-literal LIFTER sends to WASM, and of the byte ranges it
/// hands the fingerprint walker.
///
/// A lifted literal makes a round trip the rest of the lowering does not:
///
///   developer source  →  lifter VALUE  →  guest Swift literal (re-escaped by
///   `SwiftUIGuestEmitter.swiftStringLiteralBody`)  →  `BodyEmission.slotArgs`  →  the thunk's
///   `a[k]`  →  the native call
///
/// so the lifter's VALUE must be the literal's DECODED runtime value. Recording the raw source
/// text instead double-escapes every escape sequence, and the device renders the characters
/// `\n` where the developer wrote a line break — a wrong render of a view that reported shipped.
///
/// The RANGES have their own invariant: they are normalized out of the native-shell hash BEFORE
/// the line-based body-span strip, so a range that spans a newline renumbers the file and
/// neutralizes the wrong function bodies (a native edit shipping with a stale fingerprint).
final class SwiftUILiteralFidelityTests: XCTestCase {

    private func lower(_ source: String) -> [BodyLowering.LoweredView] {
        BodyLowering().lowerAllViews(source: source, sameFileThunk: true)
    }

    /// The runtime value a lifted arg ACTUALLY has on device: the guest bakes
    /// `slotArgsLiteral`'s Swift source, so decoding that literal back is exactly what the
    /// guest's compiler does.
    private func guestRuntimeValues(_ leaf: BodyLowering.OpaqueLeaf) -> [String] {
        guard let literal = SwiftUIGuestEmitter.slotArgsLiteral([leaf.id: leaf.stringArgs]) else { return [] }
        // `["id": ["a", "b"]]` → decode each baked Swift string literal.
        let source = "let __probe: [String: [String]] = \(literal)"
        return StringLiteralValueCollector.values(inSwiftSource: source).filter { $0 != leaf.id }
    }

    // MARK: - Escape round trip

    /// THE WRONG-RENDER BUG: `Text`/custom-view literals carrying `\n`, `\"` or `\\` were lifted
    /// as their SOURCE text and re-escaped by the guest emitter, so the device rendered the
    /// escape sequence itself. Every lifted arg must survive the round trip byte-for-byte.
    func testEscapedLiteralsSurviveTheGuestRoundTrip() {
        let lowered = lower("""
        import SwiftUI
        struct V: View {
            let flag: Bool
            var body: some View {
                MyRow(title: "Line1\\nLine2", note: "Quote \\" here", path: "a\\\\b", tab: "x\\ty")
            }
        }
        """)
        let leaves = lowered.flatMap(\.opaqueLeaves).filter { !$0.stringArgs.isEmpty }
        XCTAssertEqual(leaves.count, 1, "the custom-view call should lift its plain string args")
        guard let leaf = leaves.first else { return }
        XCTAssertEqual(leaf.stringArgs, ["Line1\nLine2", "Quote \" here", "a\\b", "x\ty"],
                       "the lifted VALUE must be the literal's DECODED value, not its source text")
        XCTAssertEqual(guestRuntimeValues(leaf), ["Line1\nLine2", "Quote \" here", "a\\b", "x\ty"],
                       "what the guest bakes must decode back to the developer's literal — a "
                       + "double-escape here renders the characters `\\n` on device")
    }

    /// A RAW string literal's value is its source text (no escapes) — it must round-trip too,
    /// and its range must cover the `#` delimiters so the fingerprint normalizes the whole thing.
    func testRawStringLiteralRoundTripsAndCoversItsDelimiters() {
        let source = """
        import SwiftUI
        struct V: View {
            let flag: Bool
            var body: some View {
                MyRow(title: #"raw \\n text"#, note: "ok")
            }
        }
        """
        let leaves = lower(source).flatMap(\.opaqueLeaves).filter { !$0.stringArgs.isEmpty }
        guard let leaf = leaves.first else { return XCTFail("expected a parameterized leaf") }
        XCTAssertEqual(leaf.stringArgs.first, #"raw \n text"#)
        XCTAssertEqual(guestRuntimeValues(leaf).first, #"raw \n text"#)
        let bytes = Array(source.utf8)
        guard let range = leaf.stringArgRanges.first else { return XCTFail("expected a range") }
        XCTAssertEqual(String(decoding: bytes[range], as: UTF8.self), ##"#"raw \n text"#"##,
                       "the range must cover the whole literal incl. its `#` delimiters")
    }

    /// The control-character net: the guest's literal escaper must never emit a raw C0 scalar
    /// (`unprintable ASCII character found in source file` fails the WHOLE guest module, so the
    /// convergence loop silently drops every view in it).
    func testGuestStringLiteralBodyEscapesControlCharacters() {
        let escaped = SwiftUIGuestEmitter.swiftStringLiteralBody("a\u{1}b\u{7}c\u{7F}d")
        XCTAssertFalse(escaped.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F },
                       "no raw control scalar may reach the guest source: \(escaped.debugDescription)")
        XCTAssertEqual(escaped, "a\\u{1}b\\u{7}c\\u{7f}d")
        // The printable/known escapes are unchanged (zero churn for every existing app).
        XCTAssertEqual(SwiftUIGuestEmitter.swiftStringLiteralBody("a\nb\tc\"d\\e"),
                       "a\\nb\\tc\\\"d\\\\e")
    }

    // MARK: - Range line invariant

    /// A `"""` multi-line literal must NOT be lifted: its byte range spans newlines, and the
    /// fingerprint replaces lifted ranges BEFORE the line-based body-span strip — so lifting it
    /// renumbers the file and neutralizes the wrong bodies. Staying baked is the safe failure
    /// (editing it MISMATCHes rather than silently shipping against the wrong binary).
    func testMultiLineStringLiteralIsNotLifted() {
        let quote = "\"\"\""
        let source = """
        import SwiftUI
        struct V: View {
            let flag: Bool
            var body: some View {
                MyRow(title: \(quote)
                Alpha
                Beta
                \(quote), note: "ok")
            }
        }
        """
        let leaves = lower(source).flatMap(\.opaqueLeaves).filter { !$0.stringArgs.isEmpty }
        guard let leaf = leaves.first else { return XCTFail("expected a parameterized leaf") }
        XCTAssertEqual(leaf.stringArgs, ["ok"],
                       "only the single-line literal may lift; the multi-line one stays baked")
        assertEveryLiftedRangeIsSingleLine(source)
    }

    /// The general invariant, over a body mixing every literal shape.
    func testEveryLiftedRangeCoversExactlyOneLine() {
        let quote = "\"\"\""
        assertEveryLiftedRangeIsSingleLine("""
        import SwiftUI
        struct V: View {
            let flag: Bool
            var body: some View {
                VStack {
                    MyRow(title: "One", body: \(quote)
                    many
                    lines
                    \(quote))
                    MyChip(label: flag ? "On" : "Off", icon: "star")
                    MyNote(text: #"raw"#)
                }
            }
        }
        """)
    }

    private func assertEveryLiftedRangeIsSingleLine(_ source: String,
                                                    file: StaticString = #filePath, line: UInt = #line) {
        let bytes = Array(source.utf8)
        var checked = 0
        for view in lower(source) {
            for leaf in view.opaqueLeaves {
                for range in leaf.stringArgRanges {
                    guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
                        return XCTFail("lifted range out of bounds", file: file, line: line)
                    }
                    let covered = String(decoding: bytes[range], as: UTF8.self)
                    XCTAssertFalse(covered.contains("\n"),
                                   "a lifted literal range must never span a newline (it is "
                                   + "normalized before the line-based body strip): \(covered.debugDescription)",
                                   file: file, line: line)
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "fixture lifted nothing — it no longer exercises the invariant",
                             file: file, line: line)
    }

    /// The fingerprint side of the same invariant: normalizing a range NEVER changes the file's
    /// line count, whatever range it is handed (the line-based body-span strip runs next).
    func testNormalizeByteRangesPreservesLineCount() {
        let text = "line0\nlet s = \"\"\"\nA\nB\n\"\"\"\nlet t = 1\n"
        guard let start = text.range(of: "\"\"\"") else { return XCTFail("fixture") }
        let lo = text.utf8.distance(from: text.startIndex, to: start.lowerBound)
        let hi = text.utf8.distance(from: text.startIndex, to: text.range(of: "\"\"\"", options: .backwards)!.upperBound)
        let normalized = ProjectFingerprinter.normalizeByteRanges(in: text, ranges: [lo..<hi])
        XCTAssertEqual(normalized.filter { $0 == "\n" }.count, text.filter { $0 == "\n" }.count,
                       "normalizing a lifted literal must not renumber the file's lines")
        // A single-line range is byte-identical to the historical placeholder form (zero churn).
        let oneLine = "let a = \"hi\"\nlet b = 2\n"
        let r = oneLine.utf8.distance(from: oneLine.startIndex, to: oneLine.range(of: "\"hi\"")!.lowerBound)
        XCTAssertEqual(ProjectFingerprinter.normalizeByteRanges(in: oneLine, ranges: [r..<(r + 4)]),
                       "let a = \u{1}LIT\u{1}\nlet b = 2\n")
    }
}

/// Collects the DECODED value of every plain string literal in a Swift source snippet — used to
/// read back what the guest's compiler would see in the baked `slotArgs` literal.
private enum StringLiteralValueCollector {
    static func values(inSwiftSource source: String) -> [String] {
        let collector = Collector(viewMode: .sourceAccurate)
        collector.walk(Parser.parse(source: source))
        return collector.found
    }

    private final class Collector: SyntaxVisitor {
        var found: [String] = []
        override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            if let v = node.representedLiteralValue { found.append(v) }
            return .visitChildren
        }
    }
}
