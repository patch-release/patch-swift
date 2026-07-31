// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftSyntax
import SwiftParser
@testable import CodeGenerator

/// `Emitter.conditionReferencesBodyLocal` must subtract names bound WITHIN the condition's own
/// closures/bindings before deciding a condition can't ride the guest — exactly as `isSlotable`
/// does. The real false-demote it closes: a NAMED closure param in a condition (`if rows.allSatisfy
/// { row in row.done }`) collides with a body-local `row` collected elsewhere in the body, so the
/// condition was flagged and the whole `if` block demoted. (NOTE: implicit `$0` is NOT collected by
/// `LocalNameCollector` — it has no declaration node — so `$0` can never be in `bodyLocals`; the
/// shorthand case is therefore not a real demote source, only the NAMED-param case is.)
final class ConditionInternalBindingFixTests: XCTestCase {
    private func cond(_ s: String) throws -> ConditionElementListSyntax {
        let tree = Parser.parse(source: "func __f() { if \(s) { } }")
        final class Finder: SyntaxVisitor {
            var c: ConditionElementListSyntax?
            override func visit(_ n: IfExprSyntax) -> SyntaxVisitorContinueKind {
                if c == nil { c = n.conditions }
                return .visitChildren
            }
        }
        let f = Finder(viewMode: .sourceAccurate); f.walk(tree)
        return try XCTUnwrap(f.c)
    }

    func testNamedClosureParamInConditionNotCountedAsBodyLocal() throws {
        // A NAMED closure param bound in the condition's own closure (`{ row in … }`) is internal —
        // NOT a free body-local reference, even if a body-local of the same name exists elsewhere.
        XCTAssertFalse(try Emitter.conditionReferencesBodyLocal(
            cond("rows.allSatisfy { row in row.done }"), bodyLocals: ["row"]))
        XCTAssertFalse(try Emitter.conditionReferencesBodyLocal(
            cond("items.contains(where: { item in item.active })"), bodyLocals: ["item"]))
        // An `if let` binding in the condition is likewise internal.
        XCTAssertFalse(try Emitter.conditionReferencesBodyLocal(
            cond("let first = pages.first, first.ready"), bodyLocals: ["first"]))
    }

    func testDroppedLetBodyLocalReadByConditionStillDemotes() throws {
        // A genuinely-dropped `let` body-local READ by the condition is NOT internally bound →
        // still flagged → the `if` correctly demotes (demote-safety preserved).
        XCTAssertTrue(try Emitter.conditionReferencesBodyLocal(
            cond("owners.isEmpty"), bodyLocals: ["owners"]))
        XCTAssertTrue(try Emitter.conditionReferencesBodyLocal(
            cond("count > threshold"), bodyLocals: ["threshold"]))
        // A body-local used as the BASE of a member access in the condition is still caught.
        XCTAssertTrue(try Emitter.conditionReferencesBodyLocal(
            cond("vmList.filter { row in !row.isEmpty }.count == 0"), bodyLocals: ["vmList"]))
    }

    func testNonBodyLocalNameNeverFlagged() throws {
        // A marshalled input (not in bodyLocals) is never flagged regardless of the closure shape.
        XCTAssertFalse(try Emitter.conditionReferencesBodyLocal(
            cond("items.allSatisfy { row in row.done }"), bodyLocals: ["row"]))
        XCTAssertFalse(try Emitter.conditionReferencesBodyLocal(
            cond("items.isEmpty"), bodyLocals: ["owners"]))
    }
}
