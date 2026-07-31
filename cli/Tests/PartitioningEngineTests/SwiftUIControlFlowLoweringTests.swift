// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

/// Wave 2 — CONTROL-FLOW / EXPRESSION / BINDING lowering tests (BodyLowering region):
/// body-local `let` (G33), `#if`/`#available` compilation/availability conditionals
/// (G24/G25), if/switch in a value position (G28), and Text variants (G31). Each
/// construct must LOWER (ride WASM) when guest-resolvable and DEMOTE-SAFELY (slot or
/// stay native, never break the whole-module compile) otherwise.
final class SwiftUIControlFlowLoweringTests: XCTestCase {

    private func lowerOne(_ src: String, sameFileThunk: Bool = true) throws -> BodyLowering.LoweredView {
        let views = BodyLowering().lowerAllViews(source: src, sameFileThunk: sameFileThunk)
        return try XCTUnwrap(views.first)
    }

    // MARK: - G33 body-local `let` binding

    /// A body-local `let` whose RHS is guest-resolvable over a marshalled input
    /// (`let r = size * 0.235`) is EMITTED as a real guest binding (wrapped in an IIFE),
    /// so a sibling node reading `r` resolves in WASM — the view lowers, no demote.
    func testBodyLocalLetResolvableLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let size: Double
            var body: some View {
                let r = size * 0.235
                RoundedRectangle(cornerRadius: r)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("let r = size * 0.235"),
                      "the resolvable let should be emitted as a guest binding, got: \(v.guestBody)")
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "no free symbol should leak — unresolved: \(v.unresolvedSymbols)")
        XCTAssertFalse(v.guestBody.contains("N.opaque("),
                       "the body should lower, not slot")
    }

    /// A body-local `let` whose RHS references an OUT-OF-SCOPE symbol (a service the
    /// guest can't reconstruct) is DROPPED — and the sibling node reading it then
    /// demotes via the body-level scope check (faithful over a broken guest compile).
    func testBodyLocalLetUnresolvableDemotesSafely() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let title: String
            var body: some View {
                let owners = AccountService.shared.owners
                Text(owners)
            }
        }
        """
        let v = try lowerOne(src)
        // The let is not emitted (its RHS is out-of-scope), so the sibling `Text(owners)`
        // leaks `owners` → the view is excluded (demote-safe), NOT silently mis-rendered.
        XCTAssertFalse(v.guestBody.contains("let owners ="),
                       "an unresolvable let must NOT be emitted, got: \(v.guestBody)")
        XCTAssertTrue(v.referencesUnresolvedSymbol,
                      "the sibling reading the dropped let should leave a free symbol")
    }

    /// Multiple chained body-local lets (`let a = ...; let b = a * 2`) all lower, with
    /// the later let resolving against the earlier one.
    func testChainedBodyLocalLetsLower() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let size: Double
            var body: some View {
                let a = size * 0.5
                let b = a + 4
                RoundedRectangle(cornerRadius: b)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("let a = size * 0.5"))
        XCTAssertTrue(v.guestBody.contains("let b = a + 4"))
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "chained lets should resolve — unresolved: \(v.unresolvedSymbols)")
    }

    /// A body-local `let` whose RHS is a guest-resolvable string used by a sibling Text
    /// lowers (the Text reads the bound let).
    func testBodyLocalLetStringLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let name: String
            var body: some View {
                let greeting = "Hi, " + name
                Text(greeting)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("let greeting ="))
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "the string let should resolve — unresolved: \(v.unresolvedSymbols)")
    }

    // MARK: - G31 Text variants (markdown literal)

    /// A `Text("…[link](url)…")` markdown LINK literal lowers to a markdown styledText
    /// node (the SDK renderer reconstitutes `AttributedString(markdown:)`).
    func testMarkdownLinkLiteralLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("Read the [docs](https://example.com) now")
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("N.styledText(") && v.guestBody.contains("markdown: true"),
                      "a markdown link literal should lower as styledText(markdown:), got: \(v.guestBody)")
        XCTAssertFalse(v.referencesUnresolvedSymbol)
    }

    /// A `Text("**bold**")` markdown emphasis literal lowers to a markdown styledText.
    func testMarkdownBoldLiteralLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("This is **important** text")
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("markdown: true"),
                      "a bold markdown literal should lower as styledText(markdown:), got: \(v.guestBody)")
    }

    /// A PLAIN literal with NO markdown markers stays a plain text node (no false
    /// markdown match — an underscore in plain text must not trigger emphasis).
    func testPlainLiteralStaysPlainText() throws {
        let src = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("item_count is fine here")
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertFalse(v.guestBody.contains("markdown: true"),
                       "a plain underscore literal must NOT be treated as markdown, got: \(v.guestBody)")
        XCTAssertTrue(v.guestBody.contains("N.text("),
                      "plain literal should stay a plain text node")
    }

    // MARK: - G24 `#if` compilation conditionals

    /// A `#if os(iOS) … #else … #endif` in a body picks the iOS branch and lowers it
    /// inline (the other-platform branch is dropped).
    func testIfConfigPicksIOSBranch() throws {
        let src = """
        import SwiftUI
        struct V: View {
            var body: some View {
                VStack {
                    #if os(iOS)
                    Text("on iOS")
                    #else
                    Text("elsewhere")
                    #endif
                    Text("always")
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("on iOS"),
                      "the iOS branch should lower, got: \(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains("elsewhere"),
                       "the non-iOS branch should be dropped, got: \(v.guestBody)")
        XCTAssertTrue(v.guestBody.contains("always"))
        XCTAssertFalse(v.referencesUnresolvedSymbol)
    }

    /// A `#if os(macOS) … #else … #endif` picks the `#else` branch on iOS.
    func testIfConfigMacOSPicksElse() throws {
        let src = """
        import SwiftUI
        struct V: View {
            var body: some View {
                VStack {
                    #if os(macOS)
                    Text("on mac")
                    #else
                    Text("on phone")
                    #endif
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("on phone"),
                      "iOS should take the #else branch, got: \(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains("on mac"))
    }

    /// `#if canImport(UIKit)` is taken on iOS; `#if canImport(AppKit)` is not.
    func testIfConfigCanImportUIKit() throws {
        let src = """
        import SwiftUI
        struct V: View {
            var body: some View {
                VStack {
                    #if canImport(UIKit)
                    Text("uikit")
                    #endif
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("uikit"), "canImport(UIKit) should be taken on iOS")
    }

    // MARK: - G25 `if #available`

    /// `if #available(iOS NN, *) { … } else { … }` takes the AVAILABLE branch (the
    /// device running an OTA patch meets the SDK floor) and lowers it; the else is dropped.
    func testAvailabilityTakesAvailableBranch() throws {
        let src = """
        import SwiftUI
        struct V: View {
            var body: some View {
                VStack {
                    if #available(iOS 17, *) {
                        Text("new api")
                    } else {
                        Text("legacy")
                    }
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("new api"),
                      "the available branch should lower, got: \(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains("legacy"),
                       "the else (legacy) branch should be dropped, got: \(v.guestBody)")
        XCTAssertFalse(v.referencesUnresolvedSymbol)
    }

    /// `if #available` with NO else still lowers the available branch.
    func testAvailabilityNoElse() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let name: String
            var body: some View {
                VStack {
                    if #available(iOS 16, *) {
                        Text(name)
                    }
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("N.text(name)"),
                      "the available branch should lower, got: \(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains("N.opaque("),
                       "an #available with no else should not slot")
    }

    // MARK: - G28 if/switch-EXPRESSION in a value position

    /// A `let w = if flag { … } else { … }` if-EXPRESSION in a value position lowers
    /// (it rides the guest let binding verbatim and resolves over the in-scope flag).
    func testIfExpressionInLetLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let flag: Bool
            var body: some View {
                let w = if flag { 10.0 } else { 20.0 }
                RoundedRectangle(cornerRadius: w)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("let w = if flag"),
                      "the if-expression let should ride the guest verbatim, got: \(v.guestBody)")
        XCTAssertFalse(v.referencesUnresolvedSymbol)
    }

    /// A `let h: Double = switch n { … }` switch-EXPRESSION in a value position lowers.
    func testSwitchExpressionInLetLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let n: Int
            var body: some View {
                let h: Double = switch n { case 0: 4.0; default: 12.0 }
                RoundedRectangle(cornerRadius: h)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("switch n"),
                      "the switch-expression let should ride the guest verbatim, got: \(v.guestBody)")
        XCTAssertFalse(v.referencesUnresolvedSymbol)
    }

    /// A top-level `if cond { … }` with NO else lowers (the missing else is an empty
    /// group — the construct doesn't demote).
    func testTopLevelIfNoElseLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let show: Bool
            let name: String
            var body: some View {
                VStack {
                    if show {
                        Text(name)
                    }
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("(show) ?"),
                      "a no-else if should lower to a ternary with an empty else, got: \(v.guestBody)")
        XCTAssertTrue(v.guestBody.contains("N.group([])"))
        XCTAssertFalse(v.referencesUnresolvedSymbol)
    }

    // MARK: - G42 computed scalar property host-projection

    /// A computed `var status: String { state.label }` read by `Text(status)` is
    /// host-projected: a `.string` host token (resolved by the thunk over `self`), bound
    /// from the reserved `__strtok_<id>` input key. The view lowers, no demote.
    func testComputedStringPropertyHostProjects() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let store: AppStore
            var status: String { store.statusLabel }
            var body: some View {
                Text(status)
            }
        }
        """
        let v = try lowerOne(src)
        let strTokens = v.hostTokens.filter { $0.kind == .string && $0.source == "status" }
        XCTAssertEqual(strTokens.count, 1,
                       "the computed String prop should record a .string host token, tokens: \(v.hostTokens)")
        XCTAssertTrue(v.guestBody.contains("__strtok_"),
                      "the Text should read the reserved string token key, got: \(v.guestBody)")
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "no free symbol should leak — unresolved: \(v.unresolvedSymbols)")
    }

    /// A computed `var inset: CGFloat { state.isPlus ? 16 : 8 }` read by `.padding(inset)`
    /// is host-projected as a `.number` token (bound from `__numtok_<id>`).
    func testComputedNumberPropertyHostProjects() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let store: AppStore
            let title: String
            var inset: CGFloat { store.isPlus ? 16 : 8 }
            var body: some View {
                Text(title).padding(inset)
            }
        }
        """
        let v = try lowerOne(src)
        let numTokens = v.hostTokens.filter { $0.kind == .number && $0.source == "inset" }
        XCTAssertEqual(numTokens.count, 1,
                       "the computed CGFloat prop should record a .number host token, tokens: \(v.hostTokens)")
        XCTAssertTrue(v.guestBody.contains("__numtok_"),
                      "the padding should read the reserved number token key, got: \(v.guestBody)")
        XCTAssertFalse(v.referencesUnresolvedSymbol)
    }

    /// A PRIVATE computed property. With a SEPARATE-file thunk it is NOT host-projected
    /// (the cross-file extension can't call `self.<name>`) — the view demotes safely
    /// instead of shipping a token the thunk can't supply. With a SAME-FILE thunk (the
    /// default) it IS host-projected: the thunk lives in the view's own file, so its
    /// `__patchTokens()` can call the private `self.status` natively → a `.string` token.
    func testPrivateComputedPropertyProjectionDependsOnThunkPlacement() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let store: AppStore
            private var status: String { store.statusLabel }
            var body: some View {
                Text(status)
            }
        }
        """
        // Separate-file: the private computed prop must NOT become a host token.
        let separate = try lowerOne(src, sameFileThunk: false)
        XCTAssertTrue(separate.hostTokens.filter { $0.source == "status" }.isEmpty,
                      "separate-file: a private computed prop must NOT become a host token")
        // Same-file: it IS host-projected as a `.string` token the thunk resolves over self.
        let same = try lowerOne(src, sameFileThunk: true)
        XCTAssertEqual(same.hostTokens.filter { $0.source == "status" && $0.kind == .string }.count, 1,
                       "same-file: a private computed String prop host-projects as a string token: "
                       + "\(same.hostTokens)")
        XCTAssertFalse(same.referencesUnresolvedSymbol,
                       "same-file: the private read no longer leaks a free symbol")
    }

    // MARK: - G26 computed property wrapping Foundation (DateFormatter/Calendar) as scalar

    /// A computed `var formatted: String { df.string(from: date) }` wrapping a Foundation
    /// formatter, read by `Text(formatted)`, host-projects exactly like G42 (the thunk
    /// evaluates the Foundation-using accessor natively over `self`). No special-casing —
    /// it's a computed String prop, resolved as a `.string` host token.
    func testComputedFoundationScalarHostProjects() throws {
        let src = """
        import SwiftUI
        import Foundation
        struct V: View {
            let date: Date
            private let df = DateFormatter()
            var formatted: String { df.string(from: date) }
            var body: some View {
                Text(formatted)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertEqual(v.hostTokens.filter { $0.kind == .string && $0.source == "formatted" }.count, 1,
                       "a Foundation-wrapping computed String prop should host-project, tokens: \(v.hostTokens)")
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "no free symbol should leak — unresolved: \(v.unresolvedSymbols)")
    }

    /// A computed property returning a NON-scalar Foundation type (`var df: DateFormatter`)
    /// is NOT host-projected (it's not a scalar) — only its scalar USE (the String result)
    /// projects, never the formatter object itself.
    func testComputedNonScalarFoundationNotProjected() throws {
        let src = """
        import SwiftUI
        import Foundation
        struct V: View {
            var df: DateFormatter { DateFormatter() }
            let title: String
            var body: some View {
                Text(title)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.hostTokens.filter { $0.source == "df" }.isEmpty,
                      "a non-scalar computed prop must NOT host-project")
    }

    // MARK: - G30 ForEach(.enumerated()) over a scalar array

    /// `ForEach(items.enumerated(), id: \.offset) { (i, v) in … }` over a marshalled
    /// scalar array lowers to a real guest `for (i, v) in items.enumerated()` loop.
    func testEnumeratedDestructuredLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let items: [String]
            var body: some View {
                VStack {
                    ForEach(Array(items.enumerated()), id: \\.offset) { (i, v) in
                        Text(v)
                    }
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("for (i, v) in items.enumerated()"),
                      "enumerated destructured should emit a real guest loop, got: \(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains("N.opaque("),
                       "the ForEach should lower, not slot")
        XCTAssertFalse(v.referencesUnresolvedSymbol)
    }

    /// `ForEach(items.enumerated(), id: \.0) { pair in … pair.element … }` single-tuple
    /// form lowers to a guest loop binding `pair`.
    func testEnumeratedSingleTupleLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let items: [String]
            var body: some View {
                VStack {
                    ForEach(items.enumerated(), id: \\.0) { pair in
                        Text(pair.element)
                    }
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("for pair in items.enumerated()"),
                      "enumerated single-tuple should emit a guest loop, got: \(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains("N.opaque("))
    }

    /// A ForEach ROW with a body-local `let` (`let isPeak = idx == peakIdx`) lowers — the
    /// row-local binding rides the guest (G33 inside a row) instead of being dropped (a
    /// dropped row-local would leave a free reference that excludes the whole view). This
    /// is the demote-safe-regression case the AppA Onboard2Illustration build caught.
    func testForEachRowLocalLetLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let heights: [Double]
            let labels: [String]
            let peakIdx: Int
            var body: some View {
                HStack {
                    ForEach(Array(heights.enumerated()), id: \\.offset) { idx, h in
                        let isPeak = idx == peakIdx
                        VStack {
                            RoundedRectangle(cornerRadius: isPeak ? 8 : 4).frame(width: 22, height: h)
                            Text(labels[idx])
                        }
                    }
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("let isPeak = idx == peakIdx"),
                      "the row-local let should ride the guest, got: \(v.guestBody)")
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "a row-local let must not leave a free reference — unresolved: \(v.unresolvedSymbols)")
        XCTAssertFalse(v.referencesUnmarshalledInput)
    }

    /// An array-literal default with no type annotation (`days = ["M","T","W"]`) is
    /// inferred as a guest-reconstructable `.stringArray` so a subscript/ForEach over it
    /// lowers (instead of being `.unsupported` → demote). This is what unblocked
    /// Onboard2Illustration's `Text(days[idx])`.
    func testArrayLiteralDefaultInfersStringArray() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let days = ["M", "T", "W"]
            let idx: Int
            var body: some View {
                Text(days[idx])
            }
        }
        """
        let v = try lowerOne(src)
        let daysInput = v.inputs.first { $0.name == "days" }
        XCTAssertEqual(daysInput?.kind, .stringArray,
                       "an all-string-literal default should infer .stringArray, got: \(String(describing: daysInput?.kind))")
        XCTAssertFalse(v.referencesUnmarshalledInput)
        XCTAssertFalse(v.referencesUnresolvedSymbol)
    }

    /// A numeric-literal default array stays `.unsupported` (ambiguous [Int]/[Double]) —
    /// conservatively slots, no false reconstruction.
    func testNumericLiteralDefaultStaysUnsupported() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let xs = [1, 2, 3]
            let title: String
            var body: some View {
                Text(title)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertEqual(v.inputs.first { $0.name == "xs" }?.kind, .unsupported,
                       "a numeric literal array default is ambiguous and must stay .unsupported")
    }

    /// `.enumerated()` over a NON-marshalled collection (a computed member) slots safely
    /// (no unbound loop var leaks).
    func testEnumeratedNonMarshalledSlots() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let title: String
            var body: some View {
                VStack {
                    ForEach(model.rows.enumerated(), id: \\.offset) { (i, v) in
                        Text(v.name)
                    }
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("N.opaque("),
                      "an enumerated over a non-marshalled collection should slot, got: \(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains("for "),
                       "no unbound guest loop should be emitted")
    }

    // MARK: - G39 Section { } header: { } footer: { } multi-trailing-closure

    /// The `Section { } header: { } footer: { }` multi-trailing-closure form lowers fully
    /// (header + footer + content all ride WASM).
    func testSectionMultiTrailingClosureLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let name: String
            var body: some View {
                Form {
                    Section {
                        Text(name)
                    } header: {
                        Text("Header")
                    } footer: {
                        Text("Footer")
                    }
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("N.section(header:") && v.guestBody.contains("footer:"),
                      "Section header/footer trailing closures should lower, got: \(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains("N.opaque("),
                       "the Section should fully lower")
        XCTAssertFalse(v.referencesUnresolvedSymbol)
    }

    // MARK: - G40 Picker over enum.allCases (slots gracefully — full lowering needs
    // enum-selection marshalling, a later wave)

    /// A `Picker(selection: $enumSel) { ForEach(Enum.allCases) { … .tag($0) } }` over an
    /// enum selection SLOTS gracefully (the rest of the view ships) — it does NOT leak a
    /// free symbol or demote the whole module. This is the demote-safe outcome until enum
    /// selection marshalling lands.
    func testEnumPickerSlotsGracefully() throws {
        let src = """
        import SwiftUI
        enum Fruit: String, CaseIterable { case apple, pear }
        struct V: View {
            @State var sel: Fruit = .apple
            let caption: String
            var body: some View {
                VStack {
                    Picker("Fruit", selection: $sel) {
                        ForEach(Fruit.allCases, id: \\.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    Text(caption)
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("N.opaque(") && v.guestBody.contains("Picker"),
                      "the enum Picker should slot, got: \(v.guestBody)")
        XCTAssertTrue(v.guestBody.contains("N.text(caption)"),
                      "the sibling text should still lower (view ships)")
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "slotting must not leak a free symbol — unresolved: \(v.unresolvedSymbols)")
    }
}
