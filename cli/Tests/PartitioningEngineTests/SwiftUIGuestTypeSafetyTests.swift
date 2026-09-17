// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

/// THE CONVERGENCE-DROP FAMILY: a view that lowers STATICALLY but whose emitted guest module
/// does not compile. Every view of an app shares ONE generated `_PatchSwiftUI.swift`, so one bad
/// expression takes the whole module down — production's build-time convergence loop then drops
/// views to native with no diagnostic, and the developer sees a patch that "shipped" but changed
/// nothing.
///
/// `SwiftUIGuestScopeCheck` is the guard, but it was a NAME resolver only: it answers "is every
/// identifier in scope", never "does this type-check". These are the shapes that passed it and
/// still failed the guest compile — each found by the corpus `--wasm-compile` sweep on a real
/// app. The fix in every case is to DEMOTE (the view renders natively, faithfully), never to
/// emit a guess.
final class SwiftUIGuestTypeSafetyTests: XCTestCase {

    private func lowerBody(_ body: String, props: String = "let title: String") -> BodyLowering.LoweredView? {
        BodyLowering().lowerAllViews(source: """
        import SwiftUI
        struct V: View {
            \(props)
            var body: some View {
                \(body)
            }
        }
        """, sameFileThunk: true).first { $0.viewName == "V" }
    }

    // MARK: - `if a, b` is an AND, not a tuple  (IceCubesApp)

    /// Swift's multi-clause `if a, b { … }` is a conjunction, but its SOURCE is comma-separated
    /// and the guest form is a TERNARY — so splicing the raw source emitted `((a, b) ? … : …)`,
    /// i.e. a `(Bool, Bool)` tuple where a `Bool` is required. IceCubesApp's whole module failed
    /// on it (91 views, zero shipped).
    func testMultiClauseIfConditionJoinsWithAndNotComma() {
        guard let v = lowerBody("""
        VStack {
            if flag, count > 0 { Text("both") } else { Text("no") }
        }
        """, props: "let flag: Bool\n    let count: Int") else { return XCTFail("no view") }
        XCTAssertTrue(v.guestBody.contains("(flag) && (count > 0)"),
                      "multi-clause conditions must join with `&&`:\n\(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains("flag, count > 0"),
                       "a comma-joined condition is a TUPLE in the emitted ternary:\n\(v.guestBody)")
        XCTAssertTrue(v.unresolvedSymbols.isEmpty, "\(v.unresolvedSymbols)")
    }

    /// The three-clause form, and the single-clause form (which must stay byte-identical — no
    /// gratuitous parentheses, so no fingerprint/bodyHash churn for existing apps).
    func testSingleClauseConditionIsUnchangedAndThreeClausesJoin() {
        guard let one = lowerBody("""
        VStack { if flag { Text("y") } }
        """, props: "let flag: Bool") else { return XCTFail("no view") }
        XCTAssertTrue(one.guestBody.contains("((flag) ?"), one.guestBody)
        guard let three = lowerBody("""
        VStack { if flag, count > 0, count < 9 { Text("y") } }
        """, props: "let flag: Bool\n    let count: Int") else { return XCTFail("no view") }
        XCTAssertTrue(three.guestBody.contains("(flag) && (count > 0) && (count < 9)"), three.guestBody)
    }

    // MARK: - `Double(nil)` / `Double(.appConstant)`  (WWDC, firefox-ios)

    /// `.frame(height: hidden ? 0 : nil)` — SwiftUI's height is `CGFloat?`, but the emitter wraps
    /// numeric positions as `Double(<expr>)`, so the `nil` arm became `Double(… ? 0 : nil)`.
    /// `nil` is a safe global, so the name check waved it through. The view must demote.
    func testNilArmInNumericPositionDoesNotShipABrokenGuest() {
        guard let v = lowerBody("""
        Text(title).frame(height: hidden ? 0 : nil)
        """, props: "let title: String\n    let hidden: Bool") else { return XCTFail("no view") }
        assertNoBrokenNumericConversion(v)
    }

    /// `HStack(spacing: .gutter)` over an app's `extension CGFloat { static let gutter }` became
    /// `Double(.gutter)` — the implicit member has no identifier for the name check to resolve,
    /// and the guest picks some other `Double.init` overload. The view must demote (the emitter
    /// deliberately emits an unresolved numeric verbatim, relying on this check to catch it).
    func testAppImplicitMemberInNumericPositionDoesNotShipABrokenGuest() {
        guard let v = lowerBody("""
        HStack(spacing: .gutter) { Text(title) }
        """) else { return XCTFail("no view") }
        assertNoBrokenNumericConversion(v)
    }

    /// The cheap pre-filter in front of the parse must never say "safe" when the real scan would
    /// say otherwise — a false negative silently disables the net. Over-approximating (paying for
    /// a parse that finds nothing) is free.
    func testNumericPreFilterNeverMissesANilOrImplicitMember() {
        for shouldParse in [".gutter", "(.gutter)", "flag ? .a : .b", "max(.x, 2)", " .a",
                            "flag ? 1 : nil", "x ?? nil", "nil"] {
            XCTAssertTrue(Emitter.mayHoldNilOrImplicitMember(shouldParse), shouldParse)
            XCTAssertFalse(Emitter.numericExprIsGuestTypeSafe(shouldParse), shouldParse)
        }
        // The common numeric forms skip the parse entirely and stay safe.
        for plain in ["0.5", "geo.size.width", "width * 0.66", "Theme.Radius.lg", "max(a, b)",
                      "nilCount", "isNilled"] {
            XCTAssertFalse(Emitter.mayHoldNilOrImplicitMember(plain), plain)
            XCTAssertTrue(Emitter.numericExprIsGuestTypeSafe(plain), plain)
        }
    }

    /// The stdlib `FloatingPoint` statics that DO type-check under `Double(_:)` stay allowed —
    /// this net must not demote a legitimate `.infinity`.
    func testStdlibFloatingPointStaticsStayAllowed() {
        XCTAssertTrue(Emitter.numericExprIsGuestTypeSafe(".infinity"))
        XCTAssertTrue(Emitter.numericExprIsGuestTypeSafe("width * 0.5"))
        XCTAssertTrue(Emitter.numericExprIsGuestTypeSafe("flag ? 1 : 0"))
        XCTAssertFalse(Emitter.numericExprIsGuestTypeSafe(".gutter"))
        XCTAssertFalse(Emitter.numericExprIsGuestTypeSafe("flag ? 0 : nil"))
    }

    /// THE INVARIANT, however the view reaches it: either the type-unsafe numeric never reaches
    /// the guest body (it slotted / host-projected), or the view is marked unresolved so the
    /// build EXCLUDES it. What must never happen is a clean-looking view carrying a
    /// `Double(nil)` / `Double(.appConstant)` into the shared guest module.
    private func assertNoBrokenNumericConversion(_ v: BodyLowering.LoweredView,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        let unsafeInBody = !Emitter.numericExprIsGuestTypeSafe(v.guestBody)
        guard unsafeInBody else { return }   // never emitted — the strongest outcome
        XCTAssertTrue(v.referencesUnresolvedSymbol,
                      "a type-unsafe numeric reached the guest body but the view was NOT flagged "
                      + "— the whole module would fail to compile:\n\(v.guestBody)",
                      file: file, line: line)
    }

    /// The scope check itself, on the exact bodies the two apps produced.
    func testScopeCheckFlagsTypeUnsafeNumericConversions() {
        let nilArm = SwiftUIGuestScopeCheck.check(
            guestBody: #"N.text(t).frame(height: Double((x == 0) ? 0 : nil))"#,
            inputNames: ["t", "x"], usesGeometry: false)
        XCTAssertFalse(nilArm.isCompilable, "Double(… : nil) must be flagged")
        let implicit = SwiftUIGuestScopeCheck.check(
            guestBody: #"N.hstack(spacing: Double(.horizontalSpacing), [N.text(t)])"#,
            inputNames: ["t"], usesGeometry: false)
        XCTAssertFalse(implicit.isCompilable, "Double(.appConstant) must be flagged")
        // …and the legitimate forms still pass.
        let ok = SwiftUIGuestScopeCheck.check(
            guestBody: #"N.hstack(spacing: Double(gap), [N.text(t).frame(width: Double(.infinity))])"#,
            inputNames: ["t", "gap"], usesGeometry: false)
        XCTAssertTrue(ok.isCompilable, "\(ok.unresolved)")
    }

    // MARK: - Stdlib types the APP extended  (wire-ios)

    /// `String.formated(key:…)` — wire-ios extends `String` with its own static. `String` is a
    /// safe global and the scanner only resolved the BASE of a member access, so the call sailed
    /// through and the guest failed with `type 'String' has no member 'formated'`.
    func testAppDefinedStaticOnAStdlibTypeIsFlagged() {
        let r = SwiftUIGuestScopeCheck.check(
            guestBody: #"N.text(String.formated(key: "a.b", team))"#,
            inputNames: ["team"], usesGeometry: false)
        XCTAssertEqual(r.unresolved, ["String.formated"])
    }

    /// Genuine stdlib statics — and the nested-TYPE references the engine itself emits
    /// (`UTF8.self` from the non-ASCII literal encoder) — must keep resolving.
    func testGenuineStdlibStaticsStillResolve() {
        for body in [#"N.text(String(decoding: [233, 140] as [UInt8], as: UTF8.self))"#,
                     #"N.text(t).frame(width: Double(Int.max))"#,
                     #"N.text(t).opacity(Double(Double.infinity))"#] {
            let r = SwiftUIGuestScopeCheck.check(guestBody: body, inputNames: ["t"], usesGeometry: false)
            XCTAssertTrue(r.isCompilable, "\(body) → \(r.unresolved)")
        }
    }

    // MARK: - Foundation-only String members outside the `Text(…)` position  (wire-ios)

    /// The `Text(…)` content path host-projects a Foundation-only String member to a `__strtok_`,
    /// but an `if` CONDITION emitted it verbatim: wire-ios's
    /// `if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` reached the guest
    /// and failed the module. Checking the FINISHED body covers every position at once.
    func testFoundationOnlyStringMemberInAConditionIsFlagged() {
        let r = SwiftUIGuestScopeCheck.check(
            guestBody: #"((!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? N.text(message) : N.group([]))"#,
            inputNames: ["message"], usesGeometry: false)
        XCTAssertFalse(r.isCompilable, "a Foundation-only String member must demote the view")
        XCTAssertTrue(r.unresolved.contains(".trimmingCharacters"), "\(r.unresolved)")
    }

    /// End to end: the whole view demotes rather than shipping the broken module.
    func testConditionWithFoundationStringMemberDemotesTheView() {
        guard let v = lowerBody("""
        VStack {
            if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text(message) }
        }
        """, props: "let message: String") else { return XCTFail("no view") }
        if v.guestBody.contains("trimmingCharacters") {
            XCTAssertTrue(v.referencesUnresolvedSymbol,
                          "emitted verbatim, so it must be flagged: \(v.unresolvedSymbols)")
        }
    }

    // MARK: - TYPE names in casts

    /// `if value is Special { … }` — the type in an `is`/`as?`/`as!` cast is `TypeSyntax`, not a
    /// `DeclReferenceExpr`, so the free-IDENTIFIER scan never saw it. The condition lowered and
    /// the guest failed with `cannot find type 'Special' in scope`, taking the whole module down.
    /// No app type exists in the guest, so the view must demote.
    func testAppTypeInAnIsCastIsFlagged() {
        guard let v = lowerBody("""
        VStack {
            if value is Special { Text("s") } else { Text("n") }
            Text(title)
        }
        """, props: "let title: String\n    let value: Int") else { return XCTFail("no view") }
        XCTAssertTrue(v.referencesUnresolvedSymbol, "an app type in a cast must demote the view")
        XCTAssertTrue(v.unresolvedSymbols.contains("Special"), "\(v.unresolvedSymbols)")
    }

    func testAppTypeInAnAsCastIsFlaggedButStdlibTypesAreNot() {
        let appType = SwiftUIGuestScopeCheck.check(
            guestBody: "N.text(t).opacity(Double((raw as? AppScore)?.value ?? 0))",
            inputNames: ["raw", "t"], usesGeometry: false)
        XCTAssertEqual(appType.unresolved, ["AppScore"])
        // The types the emitter itself names must keep resolving — `[UInt8]`/`UTF8` from the
        // non-ASCII literal encoder, `ViewNode` from the emitted row closures, the `IR*` family.
        let engineTypes = SwiftUIGuestScopeCheck.check(
            guestBody: """
            N.group({ () -> [ViewNode] in
              var out: [ViewNode] = []
              out.append(N.text(String(decoding: [233, 140] as [UInt8], as: UTF8.self)))
              return out
            }()).padding(IREdgeInsets(top: Double(0), leading: Double(0), bottom: Double(0), trailing: Double(0)))
            """,
            inputNames: [], usesGeometry: false)
        XCTAssertTrue(engineTypes.isCompilable, "\(engineTypes.unresolved)")
    }

    // MARK: - Lexical scope

    /// The bound-name collection was FLAT: a name bound ANYWHERE in the emitted body counted as
    /// in scope EVERYWHERE in it. So a body whose emitted row loop binds `item` accepted a
    /// SIBLING reference to a body-local also called `item` (the developer's
    /// `let item = store.current`, which the emitter drops) — and the engine deliberately emits
    /// such an inaccessible read VERBATIM, relying on this very check to demote the view. The
    /// result was a guest that fails `cannot find 'item' in scope`: the whole module, every view.
    func testANameBoundOnlyInsideALoopIsNotInScopeOutsideIt() {
        let r = SwiftUIGuestScopeCheck.check(
            guestBody: """
            N.vstack([
              N.forEach({ () -> [ViewNode] in
                var out: [ViewNode] = []
                for item in rows { out.append(N.text(item.name)) }
                return out
              }()),
              N.text(item.title)
            ])
            """,
            inputNames: ["rows"], usesGeometry: false)
        XCTAssertEqual(r.unresolved, ["item"],
                       "a reference outside the binding's scope must be flagged")
    }

    /// …while a reference INSIDE the loop / closure / `if let` still resolves (no false demote).
    func testNamesBoundByAnEnclosingScopeStillResolve() {
        let r = SwiftUIGuestScopeCheck.check(
            guestBody: """
            N.vstack([
              N.forEach({ () -> [ViewNode] in
                var out: [ViewNode] = []
                for (idx, item) in rows { out.append(N.text(item.name).opacity(Double(idx))) }
                return out
              }())
            ])
            """,
            inputNames: ["rows"], usesGeometry: false)
        XCTAssertTrue(r.isCompilable, "\(r.unresolved)")
    }

    /// End to end on the source shape that produces it.
    func testShadowedBodyLocalDemotesTheView() {
        guard let v = BodyLowering().lowerAllViews(source: """
        import SwiftUI
        struct Row: Identifiable { let id: Int; let name: String }
        struct V: View {
            let rows: [Row]
            @ObservedObject var store: Store
            var body: some View {
                let item = store.current
                VStack {
                    ForEach(rows) { item in Text(item.name) }
                    Text(item.title)
                }
            }
        }
        """, sameFileThunk: true).first(where: { $0.viewName == "V" }) else { return XCTFail("no view") }
        if v.guestBody.contains("N.text(item.title)") {
            XCTAssertTrue(v.referencesUnresolvedSymbol,
                          "the out-of-scope `item` must demote the view: \(v.unresolvedSymbols)")
        }
    }

    /// The stdlib String members must NOT be flagged (they compile in the guest).
    func testStdlibStringMembersAreNotFlagged() {
        let r = SwiftUIGuestScopeCheck.check(
            guestBody: #"N.text(name.uppercased()).opacity(Double(name.isEmpty ? 0 : 1))"#,
            inputNames: ["name"], usesGeometry: false)
        XCTAssertTrue(r.isCompilable, "\(r.unresolved)")
    }
}
