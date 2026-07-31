// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator

/// Tests for `Emitter.safeLabel` — the sanitizer for the COSMETIC label baked into an
/// `N.opaque(id:…, label: "…")` Swift string literal in the guest body.
///
/// The label carries (truncated) slot SOURCE, which can contain characters that are
/// ILLEGAL inside a double-quoted Swift literal: a `"` (closes the literal), a `\`
/// (starts an escape — a lone source backslash from a regex/path → "invalid escape
/// sequence in literal"), and CONTROL characters — a raw newline/CR/TAB, plus the
/// `\u{1}k\u{1}` lifted-arg sentinels the StringLiteralLifter injects → "unprintable
/// ASCII character found in source file". If any leaks through, the WHOLE guest module
/// fails to compile and production's convergence loop silently drops the view to native.
/// (Real corpus convergence-drops fixed by this: Pulse, swiftui-introspect, WWDC's
/// escape error — found via the `--wasm-compile` corpus sweep.)
///
/// CONTRACT: `safeLabel(s)` must produce a string that is LEGAL verbatim inside a
/// double-quoted Swift literal — no `"`, no `\`, no control char (< 0x20 or 0x7F).
final class SwiftUISafeLabelTests: XCTestCase {

    /// Every scalar in the result must be legal inside a `"…"` Swift literal.
    private func assertLiteralSafe(_ out: String, _ message: String = "") {
        for scalar in out.unicodeScalars {
            XCTAssertFalse(scalar == "\"", "label leaks a quote (closes the literal): \(message)")
            XCTAssertFalse(scalar == "\\", "label leaks a backslash (invalid escape): \(message)")
            XCTAssertFalse(scalar.value < 0x20 || scalar.value == 0x7F,
                           "label leaks a control char U+\(String(scalar.value, radix: 16)): \(message)")
        }
    }

    func testStripsTheLiftedArgSentinel() {
        // `\u{1}0\u{1}` is the StringLiteralLifter's k-th-arg placeholder. Raw in a
        // literal it is "unprintable ASCII" (swiftui-introspect / Pulse).
        let out = Emitter.safeLabel("Text(LocalizedStringKey(\u{1}0\u{1}))")
        assertLiteralSafe(out, "sentinel")
        XCTAssertFalse(out.unicodeScalars.contains("\u{1}"), "the 0x01 sentinel must be gone")
    }

    func testStripsRawTabAndNewline() {
        // Swift REJECTS a raw tab/newline inside a literal (must be \t/\n). Slot source
        // indentation bakes raw tabs into the label.
        let out = Emitter.safeLabel("List {\n\t\tText(\"hi\")\n}")
        assertLiteralSafe(out, "tab/newline")
    }

    func testEscapesLoneBackslash() {
        // A lone source backslash (a regex/path literal in the slot) → "invalid escape
        // sequence in literal" (WWDC). Must not survive as `\`.
        let out = Emitter.safeLabel(#"Text("\d+ items")"#)
        assertLiteralSafe(out, "backslash")
    }

    func testReplacesEmbeddedQuote() {
        let out = Emitter.safeLabel("Text(\"hello\")")
        assertLiteralSafe(out, "quote")
        XCTAssertFalse(out.unicodeScalars.contains("\""), "embedded quote must be replaced")
    }

    func testPreservesPlainPrintableContent() {
        // No hazardous chars → content (modulo the 60-char cap) is preserved verbatim;
        // a normal opaque-slot label of a COMPILING view must not churn.
        let plain = "HStack { Text(title); Spacer() }"
        XCTAssertEqual(Emitter.safeLabel(plain), plain)
    }

    func testTruncatesTo60() {
        let long = String(repeating: "A", count: 200)
        XCTAssertEqual(Emitter.safeLabel(long).count, 60)
    }

    func testCombinedHazardsAllSanitized() {
        // The real corpus shape: tabs + sentinel + quote + backslash together.
        let nasty = "List {\n\t\tText(LocalizedStringKey(\u{1}0\u{1})) // \"x\" \\n"
        assertLiteralSafe(Emitter.safeLabel(nasty), "combined")
    }
}
