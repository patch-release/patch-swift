// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftSyntax
import SwiftParser
@testable import CodeGenerator

/// A member NAME in a member access (`Color.recording`, `vm.title`) is a field SELECTOR,
/// never a free-variable reference. `ReferencedNameScanner` must NOT count it — pre-fix it
/// did, so `Color.recording` falsely matched a body-local `recording` (from
/// `.onChange(of:) { _, recording in … }`), demoting the view. These tests pin the fix:
/// the BASE of a member access (and bare refs) ARE references; the `.declName` selector is NOT.
final class ReferencedNameScannerMemberFixTests: XCTestCase {
    private func refs(_ src: String, _ names: Set<String>) -> Bool {
        let tree = Parser.parse(source: src)
        return ReferencedNameScanner.referencesAnyInSource(tree, of: names)
    }

    func testMemberNameIsNotAReference() {
        // THE BUG: `Color.recording` must NOT match a body-local `recording`.
        XCTAssertFalse(refs("let x = Color.recording.opacity(0.3)", ["recording"]),
                       "the member selector `.recording` must not match a body-local `recording`")
        XCTAssertFalse(refs("let x = isRecording ? Color.recording : Color.brandRed", ["recording"]))
    }

    func testBaseOfMemberAccessIsStillAReference() {
        // The documented intent: catch the BASE of a member access.
        XCTAssertTrue(refs("let x = recording.opacity(0.3)", ["recording"]),
                      "the base `recording` of a member access IS a reference")
        XCTAssertTrue(refs("let x = foo.bar", ["foo"]))
        XCTAssertFalse(refs("let x = foo.bar", ["bar"]))
    }

    func testBareReferenceStillMatches() {
        XCTAssertTrue(refs("let x = recording", ["recording"]))
        XCTAssertTrue(refs("if recording { a() }", ["recording"]))
    }

    func testNestedMemberAccessOnlyBaseCounts() {
        // a.b.c → `a` is the base (counts); `b`/`c` are selectors (don't).
        XCTAssertTrue(refs("let x = a.b.c", ["a"]))
        XCTAssertFalse(refs("let x = a.b.c", ["b"]))
        XCTAssertFalse(refs("let x = a.b.c", ["c"]))
    }

    func testMethodCallOnMemberOnlyReceiverCounts() {
        // item.foo() → `item` counts; `foo` (the called selector) does not.
        XCTAssertTrue(refs("let x = item.foo()", ["item"]))
        XCTAssertFalse(refs("let x = item.foo()", ["foo"]))
    }

    func testBaseInsideMemberAccessStillCaughtWhenBodyLocal() {
        // a body-local used as the BASE must still be caught (so a real leak still demotes).
        XCTAssertTrue(refs("let x = condition.isEmpty", ["condition"]))
    }

    func testSelfMemberSelectorIsStillAReference() {
        // THE PRIVATE WALL: `self.<member>` / `Self.<member>` IS a real reference to the
        // instance/type's member — which may be a BLOCKED private member the cross-file thunk
        // can't read (`self.accent`, `self.privateRadius`). Unlike a FOREIGN-type selector
        // (`Color.recording`), a self/Self-member selector MUST still match, or a token over a
        // private member would wrongly lower (UIKitGrammarLevers private-wall regression).
        XCTAssertTrue(refs("let x = self.accent.withAlphaComponent(0.5)", ["accent"]),
                      "a `self.<member>` selector must stay matched (the private wall)")
        XCTAssertTrue(refs("let x = self.privateRadius", ["privateRadius"]))
        XCTAssertTrue(refs("let x = Self.shared", ["shared"]))
        // The body-local fix still holds: a FOREIGN-type selector of the same name does NOT match.
        XCTAssertFalse(refs("let x = Theme.accent", ["accent"]))
        // A leading-dot contextual member (`.accent`) is NOT a self member → still skipped.
        XCTAssertFalse(refs("let x: Color = .accent", ["accent"]))
    }
}
