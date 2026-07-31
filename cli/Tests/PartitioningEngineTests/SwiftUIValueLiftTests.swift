// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PartitioningEngine
@testable import CodeGenerator

/// Tests for the SwiftUI value-lift feature (P0 per-member View forcing + P1
/// value-export codegen). Two themes:
///   1. CORRECTNESS — pure value members of a View become wasmEligible; `body`,
///      `some View`-returning, `@ViewBuilder`, and reactive-reading members stay
///      native.
///   2. SAFETY (zero false negatives) — a member that secretly reads reactive
///      state (`@Environment`/`@State`/…) or touches a native symbol stays native
///      even though it "looks pure". The per-member rule only ever REMOVES the
///      blanket flag and re-runs the unchanged downstream checks.
final class SwiftUIValueLiftTests: XCTestCase {
    private func classify(_ source: String) -> [String: ClassificationResult] {
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        let g = CallGraphBuilder().build(from: records)
        return Classifier().classifyAll(g)
    }
    /// Find the result for a member by name — matched against the id's FINAL path
    /// component (or, for a `Type.member` query, the last TWO components). NOT a
    /// substring: closure ids embed every enclosing getter name as a path prefix
    /// (`…cornerRadius.…body.closure@Lnn`), so a naive `contains` would collide
    /// with that native closure. A trailing `(...)` signature is ignored.
    private func result(_ results: [String: ClassificationResult], containing query: String) -> ClassificationResult? {
        let wantQualified = query.contains(".")
        return results.first { key, _ in
            let comps = key.split(separator: ".").map(String.init)
            guard let last = comps.last else { return false }
            let memberName = last.split(separator: "(").first.map(String.init) ?? last
            if wantQualified {
                guard comps.count >= 2 else { return false }
                let qualified = "\(comps[comps.count - 2]).\(memberName)"
                return qualified == query
            }
            return memberName == query
        }?.value
    }

    /// The worked example: a View with pure tokens/labels (freed), a `body`
    /// (native), an `@Environment`-reading helper (native), a `@ViewBuilder`
    /// (native), and a `some View` helper (native).
    private static let profileCard = """
    import SwiftUI
    struct ProfileCard: View {
        @Environment(\\.colorScheme) private var colorScheme
        @State private var expanded = false
        let userName: String
        let unreadCount: Int

        // ---- PURE DESIGN TOKENS — should be FREED ----
        var primaryFontSize: CGFloat { 17 }
        var secondaryFontSize: CGFloat { primaryFontSize - 4 }
        var cornerRadius: CGFloat { 12 }
        var horizontalPadding: Double { 16 }
        var animationDuration: Double { 0.25 }

        // ---- PURE LABEL / VALUE HELPERS — should be FREED ----
        var greeting: String { "Hi" }
        func badgeLabel(count: Int) -> String {
            if count <= 0 { return "" }
            if count > 99 { return "99+" }
            return "\\(count)"
        }
        func rowHeight(for index: Int) -> CGFloat { index == 0 ? 64 : 44 }

        // ---- MUST STAY NATIVE ----
        var body: some View {
            VStack(spacing: 8) {
                Text(greeting + ", " + userName)
                    .font(.system(size: primaryFontSize))
            }
        }
        @ViewBuilder var headerView: some View {
            if expanded { Text("Profile") } else { EmptyView() }
        }
        var tintedBadge: some View {
            Text(badgeLabel(count: unreadCount))
                .foregroundColor(colorScheme == .dark ? .white : .black)
        }
        func avatar() -> some View {
            Circle().frame(width: rowHeight(for: 0))
        }
    }
    """

    // MARK: - Correctness

    func testWorkedExampleFreesPureValuesKeepsViewDSLNative() {
        let r = classify(Self.profileCard)
        // FREED → wasmEligible (pure design tokens / labels / value helpers).
        for frag in ["primaryFontSize", "secondaryFontSize", "cornerRadius",
                     "horizontalPadding", "animationDuration", "greeting",
                     "badgeLabel", "rowHeight"] {
            XCTAssertEqual(result(r, containing: frag)?.classification, .wasmEligible,
                           "\(frag) is a pure value member of a View → should be freed to wasmEligible")
        }
        // KEPT NATIVE — view DSL / reactive.
        XCTAssertEqual(result(r, containing: "body")?.classification, .native,
                       "body is view DSL → native")
        XCTAssertEqual(result(r, containing: "headerView")?.classification, .native,
                       "@ViewBuilder member → native")
        XCTAssertEqual(result(r, containing: "tintedBadge")?.classification, .native,
                       "reads @Environment colorScheme → native")
        XCTAssertEqual(result(r, containing: "avatar")?.classification, .native,
                       "returns some View → native")
    }

    /// `some View` / concrete-view return types keep a member native even when its
    /// body looks value-ish.
    func testSomeViewAndConcreteViewReturnsStayNative() {
        let src = """
        import SwiftUI
        struct V: View {
            var body: some View { Text("x") }
            func makeText() -> Text { Text("hi") }
            func makeAny() -> AnyView { AnyView(EmptyView()) }
            func makeStack() -> some View { VStack { } }
        }
        """
        let r = classify(src)
        for frag in ["body", "makeText", "makeAny", "makeStack"] {
            XCTAssertEqual(result(r, containing: frag)?.classification, .native,
                           "\(frag) returns a view → must stay native")
        }
    }

    /// App / Scene / ViewModifier / Shape are view-DSL conformances too: their
    /// `body`/result-builder members stay native, pure value members are freed.
    func testViewModifierAndShapePerMember() {
        let src = """
        import SwiftUI
        struct Shadowed: ViewModifier {
            var radius: CGFloat { 8 }
            func body(content: Content) -> some View { content }
        }
        struct Wedge: Shape {
            var inset: CGFloat { 4 }
            func path(in rect: CGRect) -> Path { Path() }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, containing: "Shadowed.radius")?.classification, .wasmEligible,
                       "pure CGFloat token on a ViewModifier → freed")
        XCTAssertEqual(result(r, containing: "Shadowed.body")?.classification, .native,
                       "ViewModifier.body(content:) returns some View → native")
        XCTAssertEqual(result(r, containing: "Wedge.inset")?.classification, .wasmEligible,
                       "pure CGFloat token on a Shape → freed")
        // path(in:) returns Path (a view-DSL return type) → native.
        XCTAssertEqual(result(r, containing: "Wedge.path")?.classification, .native,
                       "Shape.path(in:) returns Path → native")
    }

    /// A nested value type inside a View (e.g. `enum Icon`) is no longer blanket
    /// forced native; its pure members are freed.
    func testNestedValueTypeMembersFreed() {
        let src = """
        import SwiftUI
        struct IconSelectorView: View {
            enum Icon: String {
                case primary, secondary
                var appIconName: String { "AppIcon-\\(rawValue)" }
            }
            var body: some View { Text("x") }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, containing: "appIconName")?.classification, .wasmEligible,
                       "pure String member of a nested enum inside a View → freed")
    }

    // MARK: - Safety (zero false negatives) — the re-audit

    /// A value member that SECRETLY reads `@Environment` must stay native even
    /// though its declared type is a plain value.
    func testValueMemberReadingEnvironmentStaysNative() {
        let src = """
        import SwiftUI
        struct V: View {
            @Environment(\\.colorScheme) private var colorScheme
            // Returns a CGFloat (looks pure) but READS reactive @Environment state.
            var adaptiveSize: CGFloat { colorScheme == .dark ? 22 : 17 }
            var body: some View { Text("x") }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, containing: "adaptiveSize")?.classification, .native,
                       "ZERO-FALSE-NEGATIVE: a CGFloat getter reading @Environment must be native")
    }

    /// A value member that reads `@State`/`@Binding` is NEVER `wasmEligible`. When
    /// the read is of a VALUE-MARSHALLABLE prop whose type is known — by an explicit
    /// annotation OR an unambiguous LITERAL initializer (`= 0`/`= ""`/`= true`) — it
    /// is host-projected → `mixed` (the shell projects the value into the WASM
    /// fragment). When the type is NOT provable (no annotation AND a non-literal
    /// initializer), it stays native (conservative). Either way it never becomes
    /// pure-eligible.
    func testValueMemberReadingStateIsProjectedOrNative() {
        let src = """
        import SwiftUI
        struct V: View {
            @State private var count = 0                    // inferred Int (literal) → host-projected
            @State private var typedCount: Int = 0
            @State private var opaque = Self.makeSeed()     // non-literal init, no annotation → native
            @Binding var external: Int
            var label: String { "count: \\(count)" }       // reads inferred-Int @State → host-projected
            var typedLabel: String { "n: \\(typedCount)" }  // @State Int (annotated) → host-projected
            var opaqueLabel: String { "o: \\(opaque)" }     // un-typeable @State → native
            var doubled: Int { external * 2 }              // @Binding Int → host-projected
            var body: some View { Text(label) }
            static func makeSeed() -> Int { 0 }
        }
        """
        let r = classify(src)
        // A literal-initialized @State infers its type → host-projected (mixed).
        let label = result(r, containing: "label")?.classification
        XCTAssertNotEqual(label, .wasmEligible, "ZERO-FALSE-NEGATIVE: reading @State must never be wasmEligible")
        XCTAssertEqual(label, .mixed,
                       "reading a literal-initialized (inferred-type) @State → host-projected (mixed)")
        // A NON-literal, un-annotated @State has no provable type → native (conservative).
        XCTAssertEqual(result(r, containing: "opaqueLabel")?.classification, .native,
                       "reading an un-annotated @State with a non-literal initializer (type unknown) must stay native")
        // Annotated value-typed reactive reads → host-projected (mixed), never eligible.
        let typedLabel = result(r, containing: "typedLabel")?.classification
        XCTAssertNotEqual(typedLabel, .wasmEligible, "ZERO-FALSE-NEGATIVE: reading @State must never be wasmEligible")
        XCTAssertEqual(typedLabel, .mixed, "pure read of an annotated value-typed @State → host-projected (mixed)")
        let doubled = result(r, containing: "doubled")?.classification
        XCTAssertNotEqual(doubled, .wasmEligible, "ZERO-FALSE-NEGATIVE: reading @Binding must never be wasmEligible")
        XCTAssertEqual(doubled, .mixed, "pure read of a value-typed @Binding → host-projected (mixed)")
    }

    /// `@ScaledMetric` is Dynamic-Type reactive — any member reading it is native.
    func testValueMemberReadingScaledMetricStaysNative() {
        let src = """
        import SwiftUI
        struct V: View {
            @ScaledMetric private var unit: CGFloat = 8
            var padding: CGFloat { unit * 2 }
            var body: some View { Text("x") }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, containing: "padding")?.classification, .native,
                       "ZERO-FALSE-NEGATIVE: reading @ScaledMetric (reactive) must be native")
    }

    /// A value member touching a `mustStayNative` symbol (e.g. constructing a
    /// `Color`/`UIColor`, reading `GeometryReader`-derived size) stays native.
    func testValueMemberTouchingNativeSymbolStaysNative() {
        let src = """
        import SwiftUI
        import UIKit
        struct V: View {
            // Returns a value but constructs a UIColor (mustStayNative).
            func tint() -> CGFloat { UIColor.red.cgColor.alpha }
            var body: some View { Text("x") }
        }
        """
        let r = classify(src)
        XCTAssertNotEqual(result(r, containing: "tint")?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: touching UIColor must never be wasmEligible")
    }

    /// Hard-native conformances (NSObject, *Representable, system delegates) are
    /// UNCHANGED — still blanket-forced native, even pure-looking members.
    /// NB: `UIViewController`/`UIView` are NO LONGER blanket — they moved to the
    /// per-member UIKit rule (see `UIKitPerMemberTests`); the `*Representable`
    /// bridges and `NSObject` stay hard-blanket.
    func testHardNativeConformancesStillBlanketForced() {
        let src = """
        import UIKit
        import SwiftUI
        struct Rep: UIViewRepresentable {
            var spacing: CGFloat { 8 }
            func makeUIView(context: Context) -> UIView { UIView() }
        }
        class Obj: NSObject {
            func doubled(_ x: Int) -> Int { x * 2 }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, containing: "Rep.spacing")?.classification, .native,
                       "UIViewRepresentable members stay blanket-native")
        XCTAssertEqual(result(r, containing: "Obj.doubled")?.classification, .native,
                       "NSObject members stay blanket-native (ObjC root)")
    }

    /// The reverse-control: a plain (non-View) struct's pure members are eligible
    /// regardless — confirms the View rule isn't accidentally over-freeing or
    /// under-freeing by depending on conformance.
    func testNonViewStructUnaffected() {
        let src = """
        struct Tokens {
            var fontSize: Double { 17 }
            static func scale(_ x: Double) -> Double { x * 1.5 }
        }
        """
        let r = classify(src)
        XCTAssertEqual(result(r, containing: "fontSize")?.classification, .wasmEligible)
        XCTAssertEqual(result(r, containing: "scale")?.classification, .wasmEligible)
    }
}
