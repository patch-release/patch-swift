// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator

/// Tests for `BodyLowering.defaultLiteralIsGuestSafe` — the gate deciding whether a
/// marshalled input's DECLARED default (`= …` initializer) can be baked into the guest
/// `?? <default>` binding verbatim, or must be replaced by the type-appropriate zero.
///
/// The default is DEAD CODE (the SDK always marshals the live value in; the `??` fallback
/// only matters at COMPILE time), so over-rejecting is correctness-neutral — but a default
/// that leaks into an UNCOMPILABLE guest binding drops the WHOLE view via the convergence
/// loop. Two hazard classes: (1) a FREE IDENTIFIER the guest can't resolve
/// (`Locale.current.…` — caught by the scope-check); (2) a method/function CALL whose base
/// is a literal so the scope-check passes, but the method is absent from the Foundation-free
/// guest (`"🥇".image()` — GoCycling's real convergence-drop). Both must return false.
final class SwiftUIDefaultLiteralTests: XCTestCase {

    // MARK: guest-safe (kept verbatim) — literals + member/operator exprs, NO call
    func testPlainStringLiteralIsSafe() { XCTAssertTrue(BodyLowering.defaultLiteralIsGuestSafe("\"hello\"")) }
    func testIntLiteralIsSafe() { XCTAssertTrue(BodyLowering.defaultLiteralIsGuestSafe("42")) }
    func testBoolLiteralIsSafe() { XCTAssertTrue(BodyLowering.defaultLiteralIsGuestSafe("true")) }
    func testEmptyStringIsSafe() { XCTAssertTrue(BodyLowering.defaultLiteralIsGuestSafe("\"\"")) }
    func testStringConcatOperatorIsSafe() { XCTAssertTrue(BodyLowering.defaultLiteralIsGuestSafe("\"a\" + \"b\"")) }
    func testNumericExprIsSafe() { XCTAssertTrue(BodyLowering.defaultLiteralIsGuestSafe("1 + 2")) }

    // MARK: NOT guest-safe — a CALL leaks a possibly-absent guest method (the GoCycling fix)
    func testCustomStringMethodCallIsUnsafe() {
        // GoCycling's exact convergence-drop: `?? "🥇".image()` (custom String.image()).
        XCTAssertFalse(BodyLowering.defaultLiteralIsGuestSafe("\"🥇\".image()"))
    }
    func testFoundationInitCallIsUnsafe() {
        XCTAssertFalse(BodyLowering.defaultLiteralIsGuestSafe("Date()"))
        XCTAssertFalse(BodyLowering.defaultLiteralIsGuestSafe("UUID().uuidString"))
    }
    func testFormattedCallIsUnsafe() {
        XCTAssertFalse(BodyLowering.defaultLiteralIsGuestSafe("3.14.formatted()"))
    }

    // MARK: NOT guest-safe — an IMPLICIT MEMBER (`.zero`) the `Double(…)` wrapper makes ambiguous
    func testImplicitMemberDefaultIsUnsafe() {
        // exyte-Chat's exact convergence-drop: a Double input default `.zero` → the guest binding
        // wraps it `Double(.zero)` → "ambiguous use of 'init(_:)'".
        XCTAssertFalse(BodyLowering.defaultLiteralIsGuestSafe(".zero"))
        XCTAssertFalse(BodyLowering.defaultLiteralIsGuestSafe(".pi"))
        XCTAssertFalse(BodyLowering.defaultLiteralIsGuestSafe(".infinity"))
    }

    // MARK: NOT guest-safe — a FREE IDENTIFIER (the pre-existing scope-check case)
    func testFreeIdentifierDefaultIsUnsafe() {
        XCTAssertFalse(BodyLowering.defaultLiteralIsGuestSafe("Locale.current.identifier"))
    }
}
