// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

/// Tests for DESIGN-SYSTEM TOKEN lowering (the real-world blocker: production apps
/// use a `Theme`/`Brand` design system, and the lowering must resolve custom color +
/// font tokens so token-using views lower instead of demoting wholesale).
///
/// The mechanism: a custom color/font expression in a modifier value position becomes
/// a HOST TOKEN — the modifier rides WASM (`.hostToken(id)` / `.fontToken(id)`), its
/// VALUE is supplied natively by the build-time thunk (`__patchTokens()`). An
/// expression that can't be proven resolvable (references a body-local / inaccessible
/// member) still DEMOTES safely.
final class SwiftUITokenLoweringTests: XCTestCase {

    private func lowerOne(_ src: String, sameFileThunk: Bool = true) throws -> BodyLowering.LoweredView {
        let views = BodyLowering().lowerAllViews(source: src, sameFileThunk: sameFileThunk)
        return try XCTUnwrap(views.first)
    }

    // MARK: - Color tokens

    /// A custom `<Type>.<member>` color token (`Theme.Colors.ink`) lowers to a
    /// `.foregroundColor(.hostToken(id))` and records ONE color token.
    func testCustomColorTokenLowersAsHostToken() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Colors { static let ink = Color.black } }
        struct V: View {
            let label: String
            var body: some View {
                Text(label).foregroundStyle(Theme.Colors.ink)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains(".hostToken("),
                      "a custom color token should lower to a host-token color, got: \(v.guestBody)")
        let colorTokens = v.hostTokens.filter { $0.kind == .color }
        XCTAssertEqual(colorTokens.count, 1)
        XCTAssertEqual(colorTokens.first?.source, "Theme.Colors.ink")
        // The recorded token id is the one carried in the tree.
        let id = try XCTUnwrap(colorTokens.first?.id)
        XCTAssertTrue(v.guestBody.contains(id))
        // No opaque slot — the node lowered.
        XCTAssertFalse(v.guestBody.contains("N.opaque("),
                       "the Text node should lower, not slot")
    }

    /// A token used as a `.fill` style (`Capsule().fill(Theme.Colors.accent)`) lowers
    /// via `.color(.hostToken(id))`, and a shape-VIEW background composes (the whole
    /// view doesn't slot).
    func testShapeFillTokenAndShapeBackgroundLower() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Colors { static let accent = Color.blue } }
        struct V: View {
            let text: String
            var body: some View {
                Text(text)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(Theme.Colors.accent))
            }
        }
        """
        let v = try lowerOne(src)
        // The whole body must NOT be a single opaque slot.
        XCTAssertFalse(v.guestBody.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("N.opaque("),
                       "the shape-fill background should compose, not slot the whole view")
        XCTAssertTrue(v.guestBody.contains(".hostToken("), "the fill token should lower")
        XCTAssertTrue(v.guestBody.contains("N.shape(.capsule)"), "the Capsule shape should lower")
        XCTAssertEqual(v.hostTokens.filter { $0.kind == .color }.count, 1)
    }

    /// A ternary among colors (`selected ? .white : Theme.Colors.ink`) over an
    /// ACCESSIBLE prop becomes ONE host color token (the thunk evaluates the whole
    /// expression natively).
    func testColorTernaryOverAccessiblePropIsOneToken() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Colors { static let ink = Color.black } }
        struct V: View {
            let selected: Bool
            var body: some View {
                Text("x").foregroundStyle(selected ? .white : Theme.Colors.ink)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertEqual(v.hostTokens.filter { $0.kind == .color }.count, 1,
                       "a color ternary should be one host token")
        XCTAssertTrue(v.guestBody.contains(".hostToken("))
    }

    // MARK: - Font tokens

    /// A custom font-returning call (`Theme.Font.body(13, weight: .semibold)`) lowers
    /// to a `.fontToken(id)` and records ONE font token (NOT invalid IRFont code).
    func testCustomFontTokenLowersAsFontToken() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Font { static func body(_ s: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: s) } } }
        struct V: View {
            let label: String
            var body: some View {
                Text(label).font(Theme.Font.body(13, weight: .semibold))
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains(".fontToken("),
                      "a custom font token should lower to a font token, got: \(v.guestBody)")
        XCTAssertEqual(v.hostTokens.filter { $0.kind == .font }.count, 1)
        XCTAssertEqual(v.hostTokens.first(where: { $0.kind == .font })?.source,
                       "Theme.Font.body(13, weight: .semibold)")
        // CRUCIAL: no invalid `IRFont(style: .Theme...)` garbage in the guest body.
        XCTAssertFalse(v.guestBody.contains("IRFont(style: .Theme"),
                       "must NOT emit invalid IRFont code for a token font")
    }

    /// A real system font still lowers structurally (NOT as a token).
    func testSystemFontStillLowersStructurally() throws {
        let src = """
        import SwiftUI
        struct V: View {
            var body: some View { Text("x").font(.system(size: 14, weight: .bold)) }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("IRFont(size: Double(14)"),
                      "a system font lowers to a structured IRFont, got: \(v.guestBody)")
        XCTAssertTrue(v.hostTokens.isEmpty, "no token for a structured system font")
    }

    /// A named text style (`.font(.title)`) still lowers structurally (NOT a token).
    func testNamedTextStyleFontStillLowers() throws {
        let src = """
        import SwiftUI
        struct V: View { var body: some View { Text("x").font(.title) } }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.guestBody.contains("IRFont(style: .title)"))
        XCTAssertTrue(v.hostTokens.isEmpty)
    }

    // MARK: - Demote-safety (the honest boundary)

    /// A token expression referencing a PRIVATE member (`private var brandColor`). With a
    /// SEPARATE-file thunk it is NOT resolvable (the cross-file extension can't access it),
    /// so the modifier DEMOTES the node — never emits a token the thunk can't supply. With
    /// a SAME-FILE thunk (the default) the thunk CAN access `self.brandColor`, so it lowers
    /// as a color token resolved natively over `self`.
    func testPrivateMemberColorTokenDependsOnThunkPlacement() throws {
        let src = """
        import SwiftUI
        struct V: View {
            private var brandColor: Color { .black }
            var body: some View {
                Text("x").foregroundStyle(brandColor)
            }
        }
        """
        // Separate-file: not a token; the node slots (demote-safe).
        let separate = try lowerOne(src, sameFileThunk: false)
        XCTAssertTrue(separate.hostTokens.isEmpty,
                      "separate-file: a private-member color must NOT become a token")
        XCTAssertTrue(separate.guestBody.contains("N.opaque("),
                      "separate-file: an unresolvable color token demotes the node")
        // Same-file: it IS a color token (the in-file thunk resolves self.brandColor).
        let same = try lowerOne(src, sameFileThunk: true)
        XCTAssertEqual(same.hostTokens.filter { $0.kind == .color }.count, 1,
                       "same-file: a private-member color host-projects as a color token: "
                       + "\(same.hostTokens)")
    }

    /// A token expression referencing a CLOSURE-LOCAL (`ForEach { item in ... color }`)
    /// is not resolvable from a self-only thunk closure → demote-safe.
    func testBodyLocalColorIsNotAToken() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let rows: [String]
            var body: some View {
                ForEach(rows, id: \\.self) { row in
                    Text(row).foregroundStyle(Color(row))
                }
            }
        }
        """
        let v = try lowerOne(src)
        // `Color(row)` references the loop-local `row` → not a resolvable token.
        XCTAssertFalse(v.hostTokens.contains { $0.source.contains("row") },
                       "a color referencing a body-local must not be recorded as a token")
    }

    /// A custom VIEW constructor in a `.background(...)` must NOT be mis-recorded as a
    /// color token (it's a View, not a Color) — it renders as a background CHILD node.
    func testCustomViewBackgroundIsNotAColorToken() throws {
        let src = """
        import SwiftUI
        struct Card: View { var body: some View { Color.gray } }
        struct V: View {
            var body: some View {
                Text("x").background(Card())
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertFalse(v.hostTokens.contains { $0.source.contains("Card(") },
                       "a custom view constructor must NOT become a color token")
        XCTAssertFalse(v.guestBody.contains(".color(.hostToken"),
                       "must NOT emit a host-token color for a view background")
    }

    // MARK: - Edge-specific padding (composes with tokens; was the #1 outer blocker)

    func testEdgeSpecificPaddingLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("x").padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertFalse(v.guestBody.contains("N.opaque("),
                       "edge-specific padding should lower, got: \(v.guestBody)")
        XCTAssertTrue(v.guestBody.contains("IREdgeInsets(top: Double(0), leading: Double(14)"),
                      "horizontal padding maps to leading+trailing insets")
    }

    // MARK: - if-let safety (must not emit a broken ternary)

    /// An `if let` ViewBuilder binding must NOT produce a broken `((let x = …) ? …)`
    /// ternary — it demotes the `if` to a Group-wrapped slot (valid, compiles).
    func testIfLetDemotesToValidSlotNotBrokenTernary() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let subtitle: String?
            var body: some View {
                VStack {
                    Text("title")
                    if let subtitle { Text(subtitle) }
                }
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertFalse(v.guestBody.contains("(let subtitle"),
                       "must NOT emit a broken optional-binding ternary, got: \(v.guestBody)")
        // The if-let slot wraps in Group { } so the thunk's AnyView(...) is valid.
        let ifLeaf = v.opaqueLeaves.first { $0.source.contains("if let subtitle") }
        XCTAssertNotNil(ifLeaf, "the if-let should be an opaque leaf")
        XCTAssertTrue(ifLeaf?.source.hasPrefix("Group {") ?? false,
                      "the if-let slot source must be Group-wrapped for a valid AnyView() closure")
    }

    // MARK: - Numeric tokens (design-system CGFloat constants in numeric positions)

    /// A `Theme.Radius.<member>` (CGFloat) in a `.cornerRadius(…)` position becomes a
    /// NUMERIC host token: the lowered body reads the reserved `__numtok_<id>` input
    /// (resolved natively by the thunk) instead of leaking `Theme` as a free symbol.
    func testNumericRadiusTokenInCornerRadiusLowers() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Radius { static let lg: CGFloat = 20 } }
        struct V: View {
            let label: String
            var body: some View {
                Text(label).cornerRadius(Theme.Radius.lg)
            }
        }
        """
        let v = try lowerOne(src)
        let numTokens = v.hostTokens.filter { $0.kind == .number }
        XCTAssertEqual(numTokens.count, 1, "Theme.Radius.lg should be one numeric token")
        XCTAssertEqual(numTokens.first?.source, "Theme.Radius.lg")
        let id = try XCTUnwrap(numTokens.first?.id)
        XCTAssertTrue(v.guestBody.contains("Double(__numtok_\(id))"),
                      "the lowered body reads the numeric token input, got: \(v.guestBody)")
        // The view is NOT excluded — no free `Theme` reference survives.
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "a numeric-token view must not be excluded, unresolved: \(v.unresolvedSymbols)")
    }

    /// A `Theme.Radius.<member>` used as a `RoundedRectangle(cornerRadius:)` (a shape
    /// inside `.background`) lowers via the numeric token — the shape constructor's
    /// radius is host-resolved, not a free `Theme`.
    func testNumericRadiusTokenInRoundedRectangleLowers() throws {
        let src = """
        import SwiftUI
        enum Theme {
            enum Radius { static let md: CGFloat = 14 }
            enum Colors { static let surface = Color.white }
        }
        struct V: View {
            let label: String
            var body: some View {
                Text(label).background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Colors.surface)
                )
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertEqual(v.hostTokens.filter { $0.kind == .number }.count, 1,
                       "the shape radius is one numeric token")
        XCTAssertTrue(v.guestBody.contains("roundedRectangle(cornerRadius: Double(__numtok_"),
                      "the shape's radius reads the numeric token, got: \(v.guestBody)")
        XCTAssertFalse(v.referencesUnresolvedSymbol, "must not be excluded")
    }

    /// A `.padding(Theme.Spacing.m)` (all-edges, a numeric design token) lowers via the
    /// numeric token; an edge-specific `.padding(.horizontal, 14)` is unaffected (it's
    /// still an `IREdgeInsets` over a literal).
    func testNumericSpacingTokenInPaddingLowers() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Spacing { static let m: CGFloat = 16 } }
        struct V: View {
            var body: some View {
                Text("x").padding(Theme.Spacing.m)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertEqual(v.hostTokens.filter { $0.kind == .number }.count, 1)
        XCTAssertTrue(v.guestBody.contains("padding(Double(__numtok_"),
                      "all-edges padding reads the numeric token, got: \(v.guestBody)")
        XCTAssertFalse(v.referencesUnresolvedSymbol, "must not be excluded")
    }

    /// A SCALAR COMPUTED PROPERTY in a numeric position (`var height: CGFloat { width *
    /// 0.66 }` used in `.frame(height:)`) lowers via the numeric token — the thunk
    /// evaluates `height` natively over `self` (it sees `self.width`), so no free
    /// `height` survives. This is what makes the Onboard-illustration shape ship.
    func testComputedScalarPropertyInNumericPositionLowers() throws {
        let src = """
        import SwiftUI
        struct V: View {
            var width: CGFloat = 304
            var height: CGFloat { width * 0.66 }
            var body: some View {
                Color.gray.frame(width: width, height: height)
            }
        }
        """
        let v = try lowerOne(src)
        // `width` is a marshalled input → stays verbatim; `height` (computed) → token.
        XCTAssertTrue(v.guestBody.contains("width: Double(width)"),
                      "the marshalled `width` input stays verbatim, got: \(v.guestBody)")
        let numTokens = v.hostTokens.filter { $0.kind == .number }
        XCTAssertEqual(numTokens.count, 1, "the computed `height` is one numeric token")
        XCTAssertEqual(numTokens.first?.source, "height")
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "the computed-property numeric position must not exclude the view, unresolved: \(v.unresolvedSymbols)")
    }

    /// A plain numeric LITERAL / an expression over a marshalled input stays VERBATIM —
    /// no token is recorded (the guest computes it in WASM as before). Only a
    /// genuinely-out-of-scope numeric constant becomes a token.
    func testLiteralAndInputNumericsStayVerbatimNoToken() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let w: Double
            var body: some View {
                Color.gray.frame(width: w * 2, height: 40).cornerRadius(12)
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.hostTokens.filter { $0.kind == .number }.isEmpty,
                      "a literal / input-derived numeric needs no token, got tokens: \(v.hostTokens)")
        XCTAssertTrue(v.guestBody.contains("width: Double(w * 2)"), "input expr stays verbatim")
        XCTAssertTrue(v.guestBody.contains("cornerRadius(Double(12))"), "literal stays verbatim")
    }

    /// A numeric token referencing a PRIVATE member. Separate-file: NOT resolvable (the
    /// cross-file thunk can't access it) → the modifier demotes the node (faithful over
    /// wrong). Same-file (default): the in-file thunk resolves `self.radius` natively → a
    /// numeric token.
    func testPrivateNumericMemberTokenDependsOnThunkPlacement() throws {
        let src = """
        import SwiftUI
        struct V: View {
            private var radius: CGFloat { 18 }
            var body: some View {
                Text("x").cornerRadius(radius)
            }
        }
        """
        // Separate-file: not a numeric token; the node slots (demote-safe).
        let separate = try lowerOne(src, sameFileThunk: false)
        XCTAssertTrue(separate.hostTokens.filter { $0.kind == .number }.isEmpty,
                      "separate-file: a private-member radius must NOT become a numeric token")
        XCTAssertTrue(separate.guestBody.contains("N.opaque("),
                      "separate-file: an unresolvable numeric token demotes the node")
        // Same-file: it IS a numeric token (the in-file thunk resolves self.radius).
        let same = try lowerOne(src, sameFileThunk: true)
        XCTAssertEqual(same.hostTokens.filter { $0.kind == .number }.count, 1,
                       "same-file: a private-member radius host-projects as a numeric token: "
                       + "\(same.hostTokens)")
    }

    // MARK: - String host tokens (Text content)

    /// An enum's computed-String member used as `Text(…)` content (`confidence.label`,
    /// the AppA ConfidencePill blocker) becomes ONE host STRING token: the Text
    /// node lowers (it doesn't slot), the tree references the reserved `__strtok_<id>`
    /// input, and the leaked enum input disappears.
    func testEnumDerivedTextContentLowersAsStringToken() throws {
        let src = """
        import SwiftUI
        enum Confidence { case high, low
            var label: String { self == .high ? "High" : "AI" }
        }
        struct V: View {
            let confidence: Confidence
            var body: some View {
                Text(confidence.label.uppercased())
            }
        }
        """
        let v = try lowerOne(src)
        let strTokens = v.hostTokens.filter { $0.kind == .string }
        XCTAssertEqual(strTokens.count, 1, "the enum-derived Text content should be one string token")
        XCTAssertEqual(strTokens.first?.source, "confidence.label.uppercased()")
        let id = try XCTUnwrap(strTokens.first?.id)
        XCTAssertTrue(v.guestBody.contains("__strtok_\(id)"),
                      "the Text node must read the reserved __strtok_ input, got: \(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains("N.opaque("),
                       "the Text node should lower as a string token, not slot")
        // The leaked enum input must NOT appear as a live identifier in the tree.
        XCTAssertFalse(v.guestBody.contains("confidence.label"),
                       "the enum-derived content must be host-resolved, not leaked")
    }

    /// A ternary among enum-derived strings (`short ? c.label : c.longLabel`) is ONE
    /// string token (the thunk resolves the whole expression natively).
    func testStringTernaryIsOneStringToken() throws {
        let src = """
        import SwiftUI
        enum C { case a
            var label: String { "L" }
            var longLabel: String { "Long" }
        }
        struct V: View {
            let c: C
            var short: Bool = true
            var body: some View {
                Text((short ? c.label : c.longLabel).uppercased())
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertEqual(v.hostTokens.filter { $0.kind == .string }.count, 1,
                       "a string ternary should be one string token")
        XCTAssertTrue(v.guestBody.contains("__strtok_"))
    }

    /// A plain interpolation over a MARSHALLED input (`"\(name)"`) needs NO string token
    /// — it's guest-resolvable and stays verbatim (the body computes it in WASM).
    func testInputInterpolationNeedsNoStringToken() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let name: String
            var body: some View {
                Text("Hi \\(name)")
            }
        }
        """
        let v = try lowerOne(src)
        XCTAssertTrue(v.hostTokens.filter { $0.kind == .string }.isEmpty,
                      "an input-derived interpolation needs no string token, got: \(v.hostTokens)")
        XCTAssertTrue(v.guestBody.contains("N.text(\"Hi \\(name)\")"),
                      "input interpolation stays verbatim, got: \(v.guestBody)")
    }

    // MARK: - Foundation-only String member host-projection

    /// `Text(s.capitalized)` where `s: String` is a marshalled scalar input must HOST-PROJECT
    /// rather than emit verbatim: `.capitalized` is a Foundation extension on String that is
    /// ABSENT from the Foundation-free WASM guest stdlib, so verbatim emission would fail WASM
    /// compilation. The fix routes it via `__strtok_` (the thunk evaluates natively).
    func testScalarStringCapitalizedIsHostProjected() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let s: String
            var body: some View {
                Text(s.capitalized)
            }
        }
        """
        let v = try lowerOne(src)
        let strTokens = v.hostTokens.filter { $0.kind == .string }
        XCTAssertEqual(strTokens.count, 1,
                       "s.capitalized must become ONE string token (Foundation-only property), got: \(v.hostTokens)")
        XCTAssertEqual(strTokens.first?.source, "s.capitalized",
                       "token source must be the verbatim expression: \(String(describing: strTokens.first?.source))")
        let id = try XCTUnwrap(strTokens.first?.id)
        XCTAssertTrue(v.guestBody.contains("__strtok_\(id)"),
                      "the guest must read the __strtok_ placeholder, not `.capitalized` verbatim: \(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains(".capitalized"),
                       "Foundation-only `.capitalized` must NOT appear verbatim in the guest body: \(v.guestBody)")
    }

    /// `Text(s.trimmingCharacters(in: .whitespaces))` where `s: String` is a marshalled scalar
    /// input must HOST-PROJECT: `trimmingCharacters(in:)` requires Foundation (absent from WASM
    /// guest). The type-provability gate already passes (`trimmingCharacters` in stringReturningMethods).
    func testScalarStringTrimmingCharactersIsHostProjected() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let title: String
            var body: some View {
                Text(title.trimmingCharacters(in: .whitespaces))
            }
        }
        """
        let v = try lowerOne(src)
        let strTokens = v.hostTokens.filter { $0.kind == .string }
        XCTAssertEqual(strTokens.count, 1,
                       "title.trimmingCharacters(in:) must become a string token, got: \(v.hostTokens)")
        XCTAssertFalse(v.guestBody.contains("trimmingCharacters"),
                       "Foundation-only trimmingCharacters must NOT appear verbatim: \(v.guestBody)")
    }

    /// INERTNESS: a struct field NAMED `capitalized` (e.g. `Movie.capitalized: String`)
    /// must still emit VERBATIM — it's a stored String field in the mirrored guest struct,
    /// NOT a Foundation property. The `stringTypedMemberPaths` guard prevents interception.
    func testStructFieldNamedCapitalizedStaysVerbatim() throws {
        let src = """
        import SwiftUI
        struct Movie { var capitalized: String }
        struct V: View {
            let movie: Movie
            var body: some View {
                Text(movie.capitalized)
            }
        }
        """
        let v = try lowerOne(src)
        // `movie.capitalized` is a stored String field → must be in stringTypedMemberPaths →
        // verbatim (no string token recorded for this expression).
        let strTokens = v.hostTokens.filter { $0.kind == .string }
        XCTAssertTrue(strTokens.isEmpty,
                      "a stored struct field named `capitalized` must stay verbatim, not become a token: "
                      + "\(v.hostTokens)")
        XCTAssertTrue(v.guestBody.contains("movie.capitalized"),
                      "the stored-field path must appear verbatim in the guest body: \(v.guestBody)")
    }

    /// NEGATIVE: `Text(s.uppercased())` where `s: String` is a marshalled scalar must emit
    /// VERBATIM — `uppercased()` is a stdlib method available in the Foundation-free WASM guest,
    /// so no host-projection is needed. This guards against over-widening the Foundation-only set.
    func testScalarStringUppercasedStaysVerbatim() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let s: String
            var body: some View {
                Text(s.uppercased())
            }
        }
        """
        let v = try lowerOne(src)
        let strTokens = v.hostTokens.filter { $0.kind == .string }
        XCTAssertTrue(strTokens.isEmpty,
                      "uppercased() is a stdlib method — must NOT be host-projected, got: \(v.hostTokens)")
        XCTAssertTrue(v.guestBody.contains("s.uppercased()"),
                      "the stdlib uppercased() call must appear verbatim: \(v.guestBody)")
    }

    /// NEGATIVE: `Text(s.lowercased())` similarly stays verbatim (stdlib method).
    func testScalarStringLowercasedStaysVerbatim() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let s: String
            var body: some View {
                Text(s.lowercased())
            }
        }
        """
        let v = try lowerOne(src)
        let strTokens = v.hostTokens.filter { $0.kind == .string }
        XCTAssertTrue(strTokens.isEmpty,
                      "lowercased() is a stdlib method — must NOT be host-projected, got: \(v.hostTokens)")
        XCTAssertTrue(v.guestBody.contains("s.lowercased()"),
                      "the stdlib lowercased() call must appear verbatim: \(v.guestBody)")
    }

    /// CHAINED: `Text(s.capitalized.lowercased())` — the chain has a Foundation-only property
    /// in the base (`s.capitalized`). The whole expression must host-project even though the
    /// outermost call is the stdlib `lowercased()`.
    func testChainedCapitalizedLowercasedIsHostProjected() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let s: String
            var body: some View {
                Text(s.capitalized.lowercased())
            }
        }
        """
        let v = try lowerOne(src)
        let strTokens = v.hostTokens.filter { $0.kind == .string }
        XCTAssertEqual(strTokens.count, 1,
                       "chained .capitalized.lowercased() must host-project (Foundation base): \(v.hostTokens)")
        XCTAssertFalse(v.guestBody.contains(".capitalized"),
                       "Foundation-only capitalized must NOT appear verbatim in chain: \(v.guestBody)")
    }

    /// A string-content expression referencing a PRIVATE member. Separate-file: NOT
    /// resolvable in the cross-file thunk AND not slotable, so it must NOT become a
    /// `__strtok_` the thunk can't supply — the Text is emitted verbatim and the body-level
    /// scope check demotes the whole VIEW at BUILD time (honest over a non-fillable slot).
    /// Same-file (default): the in-file thunk resolves `self.secret.uppercased()` natively
    /// → a string token; the view lowers (the private read host-resolves).
    func testPrivateStringMemberTextDependsOnThunkPlacement() throws {
        let src = """
        import SwiftUI
        struct V: View {
            private var secret: String { "x" }
            var body: some View {
                Text(secret.uppercased())
            }
        }
        """
        // Separate-file: no string token; the view demotes at build time.
        let separate = try lowerOne(src, sameFileThunk: false)
        XCTAssertTrue(separate.hostTokens.filter { $0.kind == .string }.isEmpty,
                      "separate-file: a private-member string must NOT become a string token")
        XCTAssertTrue(separate.referencesUnmarshalledInput || separate.referencesUnresolvedSymbol,
                      "separate-file: a private-member Text the thunk can't reach must demote "
                      + "the VIEW at build time, got: \(separate.guestBody)")
        // Same-file: it IS a string token (the in-file thunk resolves self.secret).
        let same = try lowerOne(src, sameFileThunk: true)
        XCTAssertEqual(same.hostTokens.filter { $0.kind == .string }.count, 1,
                       "same-file: a private-member Text host-projects as a string token: "
                       + "\(same.hostTokens)")
        XCTAssertFalse(same.referencesUnresolvedSymbol,
                       "same-file: no free symbol leaks (the private read is host-resolved)")
    }
}
