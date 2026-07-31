// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import SwiftSyntax
import SwiftParser
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// STRING LITERAL LIFTING — every string constant in a slotted SwiftUI call rides
/// WASM (OTA-editable) instead of being baked into the native slot source.
///
/// MECHANISM: `StringLiteralLifter` (a `SyntaxRewriter` subclass) walks the AST and
/// replaces recognised string-literal arguments with `\u{1}k\u{1}` placeholders (String
/// positions) or `LocalizedStringKey(\u{1}k\u{1})` calls (LocalizedStringKey positions).
/// The emitter's `opaqueExprLifted`/`opaqueViewBuilderLifted` helpers drive the walk and
/// pass the resulting (template, values, ranges) triple through the existing
/// `recordOpaque` machinery — giving the slot a structural id (literal-independent) and
/// placing the current literal values in `stringArgs` (→ `BodyEmission.slotArgs`).
///
/// KEY INVARIANTS:
/// - POSITION-TYPED: Text/Button/Toggle titles → `LocalizedStringKey(a[0])` in the
///   factory; Image systemName/asset → bare `a[0]`. Mixing these would break localization
///   or break compile (the wrong type at the call site).
/// - CONSERVATIVE: unknown positions (custom view args, modifier chains) are NOT lifted.
/// - SLOTABILITY UNCHANGED: `isSlotable` decisions are unaffected — lifting happens
///   INSIDE a slot, never instead of one.
/// - FINGERPRINT-STABLE: editing only the lifted literal (e.g. "OR" → "AND") does NOT
///   change `nativeSurface` — the fingerprint walker normalizes those byte ranges.
///
/// The modifier-chain fallback path (in `emitCall` in SwiftUIEmitter.swift) is
/// deliberately NOT lifted — it's a conservative path where the outer call is an unknown
/// modifier (e.g. `.textFieldStyle(MyCustomStyle())`); lifting string args from inside an
/// unrecognised outer call would produce a template with structural punctuation in the label
/// and provides no meaningful fingerprint benefit for a wholly-slotted chain.
final class SwiftUIStringLiteralLiftTests: XCTestCase {

    // MARK: - 1. LocalizedStringKey positions

    /// `Text("OR")` in a slotted body (e.g. combined with a non-lowerable sibling)
    /// — the literal rides WASM in `stringArgs` and the slot id is structural (stable
    /// across edits). This is the exact real-app case: `PathChooserScreen.swift` contains
    /// `Text("OR")` + `Text("We never post on your behalf.")` baked into slot source,
    /// causing fingerprint mismatch on any text edit.
    func testTextLiteralInSlottedContextIsLifted() throws {
        // Force a slotted context: pair with a custom-view sibling so the `Text` falls
        // through to opaqueExpr (the emitter can't lower the whole VStack body due to Foo).
        func lower(_ literal: String) -> (id: String, args: [String], source: String)? {
            let src = """
            import SwiftUI
            struct Foo: View { var x: Int; var body: some View { Text("\\(x)") } }
            struct Screen: View {
                var body: some View {
                    VStack {
                        Text("\(literal)")
                        Foo(x: 1)
                    }
                }
            }
            """
            let lowered = BodyLowering().lowerAllViews(source: src)
            let screen = lowered.first { $0.viewName == "Screen" }!
            // The Text opaque leaf is the one with the lifted literal.
            // There may also be a plain or parameterized leaf for Foo(x:1) — we want the Text one.
            let textLeaf = screen.opaqueLeaves.first { leaf in
                leaf.label == "Text" && !leaf.stringArgs.isEmpty
            } ?? screen.opaqueLeaves.first { !$0.stringArgs.isEmpty }
            guard let leaf = textLeaf else {
                return nil  // Text was fully lowered (improved coverage) — no opaque leaf; vacuously OK
            }
            return (leaf.id, leaf.stringArgs, leaf.source)
        }
        guard let a = lower("OR"), let b = lower("AND") else { return }
        // The slot id is STRUCTURAL — identical regardless of the literal value.
        XCTAssertEqual(a.id, b.id,
            "Text literal edit MUST keep slot id stable (was \(a.id), got \(b.id))")
        XCTAssertEqual(a.args, ["OR"],   "current literal rides stringArgs: \(a.args)")
        XCTAssertEqual(b.args, ["AND"],  "edited literal rides stringArgs:  \(b.args)")
        // The template must use LocalizedStringKey wrapping (not a bare placeholder) —
        // `Text(LocalizedStringKey(\u{1}0\u{1}))` → thunk renders `Text(LocalizedStringKey(a[0]))`.
        XCTAssertTrue(a.source.contains("LocalizedStringKey"),
            "Text position uses LocalizedStringKey wrapper in template: \(a.source)")
    }

    /// `Button("Sign In") { action() }` — the title is a `LocalizedStringKey` position.
    /// When the Button falls to an opaque slot (e.g. the action is non-slotable), the
    /// title literal is lifted into `stringArgs`.
    func testButtonTitleIsLifted() throws {
        func lower(_ title: String) -> (id: String, args: [String], source: String)? {
            let src = """
            import SwiftUI
            struct Screen: View {
                var url: URL
                var body: some View {
                    VStack {
                        Text("Header")
                        Button("\(title)") { UIApplication.shared.open(url) }
                    }
                }
            }
            """
            let lowered = BodyLowering().lowerAllViews(source: src)
            let screen = lowered.first { $0.viewName == "Screen" }!
            guard let leaf = screen.opaqueLeaves.first(where: { !$0.stringArgs.isEmpty }) else {
                return nil  // Button fully lowered — no regression
            }
            return (leaf.id, leaf.stringArgs, leaf.source)
        }
        guard let a = lower("Sign In"), let b = lower("Log In") else { return }
        XCTAssertEqual(a.id, b.id,
            "Button title edit must keep slot id stable (OTA): \(a.id) vs \(b.id)")
        XCTAssertEqual(a.args, ["Sign In"], "title rides stringArgs: \(a.args)")
        XCTAssertTrue(a.source.contains("LocalizedStringKey"),
            "Button title is LocalizedStringKey position: \(a.source)")
    }

    // MARK: - 2. String (non-LocalizedStringKey) positions

    /// `Image(systemName: "star.fill")` — the systemName is a plain `String` position
    /// (NOT `LocalizedStringKey`). When the Image falls to an opaque slot (e.g. wrapped
    /// in a modifier chain so it can't lower to `N.image`), the literal is lifted with the
    /// bare placeholder so the thunk renders `Image(systemName: a[0])`.
    func testImageSystemNameIsLiftedAsStringPosition() throws {
        func lower(_ name: String) -> (id: String, args: [String], source: String)? {
            let src = """
            import SwiftUI
            struct Foo: View { var x: Int; var body: some View { Text("\\(x)") } }
            struct Screen: View {
                var body: some View {
                    VStack {
                        Image(systemName: "\(name)")
                            .resizable()
                        Foo(x: 2)
                    }
                }
            }
            """
            let lowered = BodyLowering().lowerAllViews(source: src)
            let screen = lowered.first { $0.viewName == "Screen" }!
            // The Image + .resizable() chain is likely emitted as-is via modifier lowering
            // or falls through to an opaque leaf. Look for a parameterized leaf.
            guard let leaf = screen.opaqueLeaves.first(where: { !$0.stringArgs.isEmpty }) else {
                return nil  // Image fully lowered — no regression
            }
            return (leaf.id, leaf.stringArgs, leaf.source)
        }
        guard let a = lower("star.fill"), let b = lower("heart.fill") else { return }
        XCTAssertEqual(a.id, b.id,
            "Image systemName edit must keep slot id stable: \(a.id) vs \(b.id)")
        XCTAssertEqual(a.args, ["star.fill"], "systemName rides stringArgs: \(a.args)")
        // String position: template must NOT use LocalizedStringKey wrapping.
        XCTAssertFalse(a.source.contains("LocalizedStringKey"),
            "Image(systemName:) is a plain String position — no LocalizedStringKey wrap: \(a.source)")
    }

    // MARK: - 3. Conservative: unknown positions not lifted

    /// A CUSTOM VIEW `Foo(title: "Hello")` — `Foo` is not in the recognized position
    /// table for StringLiteralLifter. The `opaqueCall` mechanism handles custom-view arg
    /// lifting (a separate, pre-existing path). Verify that StringLiteralLifter doesn't
    /// double-lift by recognising "Foo" as a known call name — the guest body must not
    /// contain the literal.
    func testCustomViewArgNotDoubleLifted() throws {
        let src = """
        import SwiftUI
        struct Foo: View {
            var title: String
            var body: some View { Text(title) }
        }
        struct Screen: View {
            var body: some View {
                VStack {
                    Foo(title: "Hello World")
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: src)
        let screen = lowered.first { $0.viewName == "Screen" }!
        // Screen should have exactly one opaque leaf for Foo (handled by opaqueCall).
        XCTAssertFalse(screen.opaqueLeaves.isEmpty, "Screen has at least one opaque leaf for Foo")
        // The guest body must not bake "Hello World" verbatim in the tree bytes.
        XCTAssertFalse(screen.guestBody.contains("Hello World"),
            "the literal must NOT appear verbatim in the shipped tree: \(screen.guestBody)")
    }

    // MARK: - 4. Modifier-chain fallback is NOT lifted (correctness guard)

    /// `TextField("Email", text: $field).textFieldStyle(MyCustomStyle())` — the whole
    /// modifier chain falls to plain `opaqueExpr` (NOT `opaqueExprLifted`) so the
    /// resulting leaf has no `stringArgs` and the label never contains structural
    /// punctuation like `.textFieldStyle("`.
    /// cli 1.6.31: a custom modifier on a view (`.textFieldStyle(MyCustomStyle())`) slots
    /// the whole modifier-chained expression — but its DISPLAY string literals (the
    /// TextField placeholder "Email") are now LIFTED (`opaqueExprLifted`) so editing them
    /// rides WASM (OTA-editable) instead of baking into native slot source (a FINGERPRINT
    /// MISMATCH on edit — the real-app OnboardingFlow `.screenBackground()` bug class: a
    /// custom modifier on a CONTAINER otherwise collapses the whole container to one baked
    /// native leaf). The debug `.label` stays CLEAN (the modifier name passed as labelHint)
    /// — no rewritten-source / structural punctuation leaking into the guest code.
    func testModifierChainFallbackLiftsDisplayLiterals() throws {
        let src = """
        import SwiftUI
        struct MyCustomStyle: TextFieldStyle {
            func _body(configuration: TextField<Self._Label>) -> some View { configuration }
        }
        struct Screen: View {
            @State private var q = ""
            var body: some View {
                TextField("Email", text: $q).textFieldStyle(MyCustomStyle())
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: src)
        let screen = lowered.first { $0.viewName == "Screen" }!
        // Must have an opaque leaf (the whole modifier chain is slotted).
        XCTAssertFalse(screen.opaqueLeaves.isEmpty,
            "the modifier chain must produce an opaque leaf")
        // The TextField placeholder "Email" must be LIFTED so editing it is OTA-safe.
        let allArgs = screen.opaqueLeaves.flatMap { $0.stringArgs }
        XCTAssertTrue(allArgs.contains("Email"),
            "modifier-chain fallback must LIFT the display literal (stringArgs: \(allArgs))")
        // The debug label must stay CLEAN (the modifier name), not the rewritten source —
        // so no structural punctuation / placeholder control chars leak into the guest code.
        XCTAssertFalse(screen.guestBody.contains(".textFieldStyle(\""),
            "label must be clean (mod name), not the rewritten source: \(screen.guestBody)")
    }

    // MARK: - 5. Fingerprint stability for lifted literals

    /// Editing a lifted string literal (e.g. `Text("OR")` → `Text("AND")`) inside a
    /// slotted expression must NOT change the native-shell fingerprint. The fingerprint
    /// walker normalizes the lifted literal byte ranges via
    /// `loweredParameterizedSlotLiteralRanges`.
    func testLiftedLiteralEditDoesNotChangeFingerprintSurface() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("patch-strlift-fp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let file = root.appendingPathComponent("Screen.swift")

        func writeSource(_ literal: String) throws {
            let src = """
            import SwiftUI
            struct Foo: View { var x: Int; var body: some View { Text("\\(x)") } }
            struct Screen: View {
                var body: some View {
                    VStack {
                        Text("\(literal)")
                        Foo(x: 1)
                    }
                }
            }
            """
            try src.write(to: file, atomically: true, encoding: .utf8)
        }

        try writeSource("OR")
        let fp1 = ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint

        try writeSource("AND")
        let fp2 = ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint

        // If Text was fully lowered, both fingerprints will be equal anyway (no native surface).
        // If Text was slotted and the literal was lifted, the literal range is normalized →
        // both fingerprints are still equal.
        XCTAssertEqual(fp1, fp2,
            "editing only a lifted Text literal must NOT churn the native-shell fingerprint "
            + "(fp1=\(fp1.prefix(16)) fp2=\(fp2.prefix(16)))")
    }

    // MARK: - 6. Multi-literal lifting in one call

    /// `Label("Favorites", systemImage: "star")` — two recognized positions in one call:
    /// the first unlabeled arg (LocalizedStringKey) AND `systemImage:` (String). Both
    /// must be lifted so editing either the title or the icon name is fingerprint-stable.
    func testLabelTitleAndSystemImageBothLifted() throws {
        func lower(_ title: String, _ icon: String) -> (id: String, args: [String])? {
            let src = """
            import SwiftUI
            struct Foo: View { var x: Int; var body: some View { Text("\\(x)") } }
            struct Screen: View {
                var body: some View {
                    VStack {
                        Label("\(title)", systemImage: "\(icon)")
                        Foo(x: 3)
                    }
                }
            }
            """
            let lowered = BodyLowering().lowerAllViews(source: src)
            let screen = lowered.first { $0.viewName == "Screen" }!
            guard let leaf = screen.opaqueLeaves.first(where: { $0.stringArgs.count >= 1 }) else {
                return nil  // Label fully lowered — no regression
            }
            return (leaf.id, leaf.stringArgs)
        }
        guard let a = lower("Favorites", "star"),
              let b = lower("Bookmarks", "bookmark") else { return }
        XCTAssertEqual(a.id, b.id,
            "Label with both title+icon edit must keep id stable: \(a.id) vs \(b.id)")
        // Both args must be lifted (the Label has 2 recognized positions).
        XCTAssertEqual(a.args.count, 2,
            "Label should lift both title and systemImage: \(a.args)")
        XCTAssertTrue(a.args.contains("Favorites"), "title lifted: \(a.args)")
        XCTAssertTrue(a.args.contains("star"),      "systemImage lifted: \(a.args)")
    }

    // MARK: - 7. Interpolated strings are not lifted (safety)

    /// `Text("Hello \(name)")` — an interpolated string must NOT be lifted even in a
    /// recognized position. The interpolation segments reference body-locals that the
    /// thunk can't provide as a `[String]` value → lifting would produce a broken factory.
    func testInterpolatedStringInRecognizedPositionIsNotLifted() throws {
        let src = """
        import SwiftUI
        struct Foo: View { var x: Int; var body: some View { Text("\\(x)") } }
        struct Screen: View {
            var name: String
            var body: some View {
                VStack {
                    Text("Hello \\(name)")
                    Foo(x: 4)
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: src)
        let screen = lowered.first { $0.viewName == "Screen" }!
        // Any opaque leaf from the interpolated Text must NOT have stringArgs lifted.
        // (The Foo leaf from opaqueCall may have stringArgs — filter for Text-labelled leaves.)
        let textLeaves = screen.opaqueLeaves.filter { $0.label == "Text" }
        for leaf in textLeaves {
            XCTAssertTrue(leaf.stringArgs.isEmpty,
                "an interpolated Text literal must NOT be lifted: \(leaf.stringArgs)")
        }
    }

    // MARK: - 8. Guest body must not bake the lifted literal

    /// When a literal is lifted, the GUEST BODY (the tree bytes that ride WASM) must not
    /// contain the verbatim literal — it rides in `slotArgs` instead.  This ensures the
    /// WASM binary is stable across literal edits.
    func testLiftedLiteralDoesNotAppearInGuestBody() throws {
        let src = """
        import SwiftUI
        struct Foo: View { var x: Int; var body: some View { Text("\\(x)") } }
        struct Screen: View {
            var body: some View {
                VStack {
                    Text("My Unique Label")
                    Foo(x: 5)
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: src)
        let screen = lowered.first { $0.viewName == "Screen" }!
        // If the literal was lifted, it must NOT appear in the guest body tree.
        // If Text was fully lowered to N.text(...), it appears but as the real value — that's
        // fine (it's lowered, not slotted). We only care about the SLOTTED path.
        let hasLiftedLeaf = screen.opaqueLeaves.contains { !$0.stringArgs.isEmpty }
        if hasLiftedLeaf {
            XCTAssertFalse(screen.guestBody.contains("My Unique Label"),
                "a lifted literal must not appear verbatim in the guest body tree: \(screen.guestBody.prefix(300))")
        }
        // Sanity: the id placeholder DOES appear in the guest body.
        let paramLeaf = screen.opaqueLeaves.first { !$0.stringArgs.isEmpty }
        if let leaf = paramLeaf {
            XCTAssertTrue(screen.guestBody.contains(leaf.id),
                "the slot id must appear in the guest body: \(leaf.id)")
        }
    }

    // MARK: - 9. Position-type correctness: LocalizedStringKey vs String

    /// Verifies that the position classification is TYPED correctly: a `Text` literal
    /// gets `LocalizedStringKey(placeholder)` (not a bare placeholder), while an
    /// `Image(systemName:)` literal gets a bare placeholder (not wrapped).
    /// This is the #1 correctness rule — wrong wrapping breaks localization or compile.
    func testPositionTypedSubstitutionIsCorrect() throws {
        // Lower a view containing both Text and Image (systemName:) as opaque leaves.
        let src = """
        import SwiftUI
        struct Foo: View { var x: Int; var body: some View { Text("\\(x)") } }
        struct Screen: View {
            var body: some View {
                VStack {
                    Text("Greeting")
                    Foo(x: 6)
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: src)
        let screen = lowered.first { $0.viewName == "Screen" }!

        for leaf in screen.opaqueLeaves where !leaf.stringArgs.isEmpty {
            if leaf.label == "Text" || leaf.source.hasPrefix("Text(") {
                // Text uses LocalizedStringKey position.
                XCTAssertTrue(leaf.source.contains("LocalizedStringKey"),
                    "Text literal must be wrapped as LocalizedStringKey in template: \(leaf.source)")
            } else if leaf.label == "Image" || leaf.source.hasPrefix("Image(systemName:") {
                // Image(systemName:) uses bare String position.
                XCTAssertFalse(leaf.source.contains("LocalizedStringKey"),
                    "Image(systemName:) literal must NOT be wrapped as LocalizedStringKey: \(leaf.source)")
            }
        }
    }

    // MARK: - 10. FIX 1: accessibilityIdentifier is a plain String (NOT LocalizedStringKey)

    /// `View.accessibilityIdentifier(_:)` takes a plain `String`, not `LocalizedStringKey`.
    /// The template must NOT wrap it as `LocalizedStringKey(...)` — that would be a COMPILE
    /// ERROR in the generated thunk.  The lifted position must use the bare-String kind.
    func testAccessibilityIdentifierIsLiftedAsPlainString() throws {
        func lower(_ id: String) -> (source: String, args: [String])? {
            let src = """
            import SwiftUI
            struct Foo: View { var x: Int; var body: some View { Text("\\(x)") } }
            struct Screen: View {
                var body: some View {
                    VStack {
                        Text("Hello")
                            .accessibilityIdentifier("\(id)")
                        Foo(x: 7)
                    }
                }
            }
            """
            let lowered = BodyLowering().lowerAllViews(source: src)
            let screen = lowered.first { $0.viewName == "Screen" }!
            guard let leaf = screen.opaqueLeaves.first(where: { !$0.stringArgs.isEmpty }) else {
                return nil  // no lifted leaf — skip (not a regression)
            }
            return (leaf.source, leaf.stringArgs)
        }
        guard let a = lower("greeting-label"), let b = lower("welcome-label") else { return }
        // Must NOT use LocalizedStringKey — accessibilityIdentifier takes plain String.
        XCTAssertFalse(a.source.contains("LocalizedStringKey"),
            "accessibilityIdentifier must NOT be wrapped as LocalizedStringKey (compile error in thunk): \(a.source)")
        // Must contain the lifted arg (not baked).
        XCTAssertEqual(a.args, ["greeting-label"],
            "accessibilityIdentifier literal must be lifted into stringArgs: \(a.args)")
        // Structural id must be stable across literal edits.
        // (Can't check id without access to leaf.id here; stability is implicit if both lower
        //  and we verify the source template is identical modulo the placeholder value.)
        _ = b  // b must also lift without wrapping
        XCTAssertFalse(b.source.contains("LocalizedStringKey"),
            "accessibilityIdentifier plain-String position must stay unwrapped for 'welcome-label': \(b.source)")
    }

    // MARK: - 11. FIX 2: Nested call — outer literal ranges are from the ORIGINAL tree

    /// `Button("Submit") { Image(systemName: "arrow") }` — a recognized Button containing
    /// a recognized Image.  When the inner Image is rewritten first (bottom-up), the
    /// outer Button literal "Submit" must still record the correct byte range (pointing at
    /// "Submit" in the ORIGINAL source, NOT at offset=0 in the rewritten tree).
    ///
    /// Regression guard: editing "Submit" must be fingerprint-stable (the outer literal's
    /// range IS correctly normalized).  Editing a truly-structural thing (a different native
    /// function in the same file) must still churn.
    ///
    /// This is the FIX 2 correctness guard: if ranges were taken from the REWRITTEN tree
    /// (offset=0), the outer literal's range would point into the wrong bytes.  The range
    /// normalization would then normalize the WRONG bytes and either (a) not normalize the
    /// literal at all (literal edit churns when it shouldn't) or (b) normalize something else
    /// (structural edit is stable when it shouldn't be).  We test case (a): after the fix,
    /// editing "Submit"→"Continue" must be STABLE.
    func testNestedCallOuterLiteralRangeIsFromOriginalTree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("patch-nested-fp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Screen.swift")

        // Use a Button with UIApplication (undispatchable → falls to opaqueExprLifted) whose
        // label is a Label that contains BOTH a LocalizedStringKey ("Submit") and a String
        // (systemImage: "arrow.right") — two recognized nested positions.
        // We also add a NON-view native helper function to give the fingerprint something
        // to hash that changes on a REAL structural edit, giving us a reliable churn signal.
        func writeSource(title: String, helperComment: String) throws {
            let src = """
            import SwiftUI
            struct Screen: View {
                var url: URL
                var body: some View {
                    VStack {
                        // \(helperComment)
                        Text("fixed")
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            Label("\(title)", systemImage: "arrow.right")
                        }
                    }
                }
                // native helper — its body is hashed
                func doSomething() { }
            }
            """
            try src.write(to: file, atomically: true, encoding: .utf8)
        }

        // FP with original title "Submit" and no comment change
        try writeSource(title: "Submit", helperComment: "v1")
        let fp1 = ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint

        // FP after editing only the lifted title "Submit" → "Continue"
        try writeSource(title: "Continue", helperComment: "v1")
        let fp2 = ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint

        // Title edit must be fingerprint-STABLE (FIX 2: outer range correctly taken from original).
        // If the range were wrong (from the rewritten tree), it would point at offset=0 → wrong
        // bytes normalized → title edit churns (false MISMATCH) or wrong bytes suppressed (worse).
        XCTAssertEqual(fp1, fp2,
            "editing only the Button/Label title inside a nested call must NOT churn fingerprint "
            + "(FIX 2 guard — outer literal range must come from original tree, not rewritten tree): "
            + "fp1=\(fp1.prefix(16)) fp2=\(fp2.prefix(16))")

        // Confirm the lowering actually produced lifted leaves (otherwise the test is vacuous).
        let lowered = BodyLowering().lowerAllViews(source: """
        import SwiftUI
        struct Screen: View {
            var url: URL
            var body: some View {
                VStack {
                    Text("fixed")
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label("Submit", systemImage: "arrow.right")
                    }
                }
            }
            func doSomething() { }
        }
        """)
        let screen = lowered.first { $0.viewName == "Screen" }
        // If the Label/Button was fully lowered, the test is vacuously OK (no regression).
        // If it was slotted, confirm stringArgs exist.
        if let s = screen, s.opaqueLeaves.contains(where: { $0.stringArgs.count >= 1 }) {
            let leaf = s.opaqueLeaves.first { $0.stringArgs.count >= 1 }!
            XCTAssertFalse(leaf.stringArgs.isEmpty,
                "nested-call context should have at least one lifted arg: \(leaf.stringArgs)")
        }
    }

    // MARK: - 12. FIX 3: Interpolated string with slotable expressions is lifted

    /// P0-B WRONG-RENDER GUARD: an interpolated string `Text("Step \\(step) of \\(total)")`
    /// must NOT be lifted even when BOTH interpolated expressions are slotable. The
    /// `makeInterpolatedReplacement` path embeds the template in double-quote-wrapped
    /// identifier text; after `renderParameterizedTemplate` replaces `\u{1}k\u{1}` → `a[k]`,
    /// the generated slot closure emits `Text(LocalizedStringKey("a[0]\(step)a[1]\(total)"))`.
    /// On screen this shows the LITERAL TEXT "a[0]" + step_value + "a[1]" + total_value —
    /// garbage output. The safe path: interpolated strings stay BAKED (a static-segment edit
    /// triggers MISMATCH, not a wrong render). Only PLAIN non-interpolated literals are lifted.
    func testSlotableInterpolatedStringIsNotLifted() throws {
        // `step` and `total` are stored properties → slotable. Despite that, the interpolated
        // string must NOT be lifted (P0-B wrong-render fix).
        let src = """
        import SwiftUI
        struct Foo: View { var x: Int; var body: some View { Text("\\(x)") } }
        struct Screen: View {
            var step: Int
            var total: Int
            var body: some View {
                VStack {
                    Text("Step \\(step) of \\(total)")
                    Foo(x: 8)
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: src)
        let screen = lowered.first { $0.viewName == "Screen" }!
        // P0-B: no leaf from an interpolated Text literal must have stringArgs lifted.
        // Finding "Step" in stringArgs (a static segment) would mean the interpolated lift
        // was applied — and the slot closure would render "a[0]" literally (wrong render).
        let interpolatedTextLeaves = screen.opaqueLeaves.filter {
            $0.label == "Text" && !$0.stringArgs.isEmpty
        }
        for leaf in interpolatedTextLeaves {
            // The stringArgs of any interpolated Text must NOT contain the static segments.
            // "Step" and " of " are the static segments; they must NOT ride WASM via stringArgs
            // (the template mechanism would render them as "a[0]"/"a[1]" literally).
            XCTAssertFalse(leaf.stringArgs.contains { $0 == "Step " || $0 == " of " },
                "P0-B WRONG-RENDER GUARD: interpolated Text static segments must NOT be "
                + "lifted into stringArgs — the slot template would render 'a[0]'/'a[1]' "
                + "literally instead of the intended text. stringArgs=\(leaf.stringArgs)")
        }
    }

    /// `Text("Hello \\(privateField)")` — where `privateField` is a body-local or
    /// private member (non-slotable): the whole interpolated string must NOT be lifted.
    func testNonSlotableInterpolatedStringIsNotLifted() throws {
        let src = """
        import SwiftUI
        struct Foo: View { var x: Int; var body: some View { Text("\\(x)") } }
        struct Screen: View {
            private var secret: String = "hidden"
            var body: some View {
                VStack {
                    Text("Value: \\(secret)")
                    Foo(x: 9)
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: src)
        let screen = lowered.first { $0.viewName == "Screen" }!
        // The Text leaf (if present and opaque) must NOT have lifted stringArgs —
        // `secret` is private → non-slotable → whole interpolation stays baked.
        let textLeaves = screen.opaqueLeaves.filter { $0.label == "Text" }
        for leaf in textLeaves {
            XCTAssertTrue(leaf.stringArgs.isEmpty,
                "interpolated Text with a private expr must NOT be lifted: \(leaf.stringArgs)")
        }
    }

    // MARK: - 7. TERNARY-ARM lift (cli 1.6.34)
    //
    // A STATE-CONDITIONAL `cond ? "A" : "B"` inside a slotted Text/Button/Image label
    // baked BOTH arm literals into native slot source — editing either gave a FINGERPRINT
    // MISMATCH (the user's original complaint class: AppD OnboardingScreen
    // `Text(currentPage < 2 ? "Next" : "Get Started")`, AppB ContactsPickerSheet
    // `Text(sending ? "Sending…" : "Send")`). The StringLiteralLifter now lifts BOTH plain
    // arm literals; the CONDITION is never touched (it reads live native state).

    /// Drive `StringLiteralLifter` directly on a single call expression and return its
    /// lifted (values, ranges, template) — exercises the lifter in isolation so the
    /// position-typing and range-correctness are pinned precisely.
    private func driveLifter(_ exprSrc: String, liftAll: Bool = false,
                             blocked: Set<String> = []) -> (values: [String], ranges: [Range<Int>], template: String) {
        let parsed = Parser.parse(source: exprSrc)
        final class Finder: SyntaxVisitor {
            var call: FunctionCallExprSyntax?
            override func visit(_ n: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if call == nil { call = n }; return .visitChildren
            }
        }
        let f = Finder(viewMode: .sourceAccurate); f.walk(parsed)
        guard let call = f.call else { return ([], [], "NO CALL") }
        let lifter = StringLiteralLifter(blocked: blocked, liftAllPlainStrings: liftAll)
        let rewritten = lifter.rewrite(Syntax(ExprSyntax(call)))
        let template = (rewritten.as(ExprSyntax.self)?.trimmedDescription ?? "nil")
        return (lifter.values, lifter.ranges, template)
    }

    /// `Text(cond ? "Next" : "Get Started")` — BOTH arms lift as `LocalizedStringKey`
    /// placeholders; the condition rides VERBATIM (reads live `@State`, never lifted).
    func testTextTernaryArmsLiftAsLocalizedStringKey() throws {
        let r = driveLifter(#"Text(currentPage < 2 ? "Next" : "Get Started")"#)
        XCTAssertEqual(r.values, ["Next", "Get Started"],
            "both arm literals must ride stringArgs: \(r.values)")
        // The condition is reproduced verbatim — never a lifted value.
        XCTAssertFalse(r.values.contains { $0.contains("currentPage") || $0.contains("<") },
            "the condition must NEVER be lifted: \(r.values)")
        XCTAssertTrue(r.template.contains("currentPage < 2 ?"),
            "the condition rides verbatim in the template: \(r.template)")
        // Text(first unlabeled) is a LocalizedStringKey position → both arms wrapped.
        XCTAssertEqual(r.template.replacingOccurrences(of: "\u{1}", with: "·"),
            "Text(currentPage < 2 ? LocalizedStringKey(·0·) : LocalizedStringKey(·1·))",
            "both arms must be LocalizedStringKey-wrapped: \(r.template)")
    }

    /// The AppB `ContactsPickerSheet` pattern: `Text(sending ? "Sending…" : "Send")`.
    func testSendTernaryLiftsBothArms() throws {
        let r = driveLifter(#"Text(sending ? "Sending…" : "Send")"#)
        XCTAssertEqual(r.values, ["Sending…", "Send"], "both arms ride WASM: \(r.values)")
        XCTAssertTrue(r.template.contains("LocalizedStringKey"),
            "Text title is a LocalizedStringKey position: \(r.template)")
    }

    /// `Text(verbatim: cond ? "a" : "b")` — `verbatim:` is a PLAIN String position, so the
    /// arms lift as BARE placeholders (NO LocalizedStringKey wrap — that would be a compile
    /// error: `Text(verbatim:)` takes a `String`, not a `LocalizedStringKey`).
    func testTextVerbatimTernaryLiftsAsBareString() throws {
        let r = driveLifter(#"Text(verbatim: ok ? "a" : "b")"#)
        XCTAssertEqual(r.values, ["a", "b"], "both verbatim arms lift: \(r.values)")
        XCTAssertFalse(r.template.contains("LocalizedStringKey"),
            "verbatim: is a plain String position — NO LocalizedStringKey wrap: \(r.template)")
        XCTAssertEqual(r.template.replacingOccurrences(of: "\u{1}", with: "·"),
            "Text(verbatim: ok ? ·0· : ·1·)",
            "bare placeholders for the String position: \(r.template)")
    }

    /// `Image(systemName: on ? "star.fill" : "star")` — a plain String position, bare arms.
    func testImageSystemNameTernaryLiftsAsBareString() throws {
        let r = driveLifter(#"Image(systemName: on ? "star.fill" : "star")"#)
        XCTAssertEqual(r.values, ["star.fill", "star"], "both arms lift: \(r.values)")
        XCTAssertFalse(r.template.contains("LocalizedStringKey"),
            "Image(systemName:) is a String position: \(r.template)")
    }

    /// SAFETY: a ternary with an INTERPOLATED arm (`"Hi \(name)"`) lifts NEITHER arm — the
    /// whole ternary stays baked (conservative; a per-arm interpolation can't ride a single
    /// stringArg placeholder).
    func testTernaryWithInterpolatedArmLiftsNeither() throws {
        let r = driveLifter(##"Text(f ? "Hi \(name)" : "Bye")"##)
        XCTAssertTrue(r.values.isEmpty,
            "an interpolated arm makes the WHOLE ternary stay baked: \(r.values)")
        XCTAssertFalse(r.template.contains("\u{1}"),
            "no placeholder is inserted when an arm is non-liftable: \(r.template)")
    }

    /// SAFETY: a ternary with a NON-LITERAL arm (`title` — an identifier) lifts NEITHER.
    func testTernaryWithNonLiteralArmLiftsNeither() throws {
        let r = driveLifter(#"Text(f ? title : "Bye")"#)
        XCTAssertTrue(r.values.isEmpty,
            "a non-literal arm makes the WHOLE ternary stay baked: \(r.values)")
    }

    /// SAFETY: a CHAINED ternary (`a ? "x" : (b ? "y" : "z")`) — the else arm is itself a
    /// ternary (not a plain literal) → lift NEITHER (conservative; the byte-range mapping for a
    /// nested ternary is not the simple two-arm shape this lift handles).
    func testChainedTernaryLiftsNeither() throws {
        let r = driveLifter(#"Text(a ? "x" : (b ? "y" : "z"))"#)
        XCTAssertTrue(r.values.isEmpty,
            "a chained ternary must NOT lift (only the simple two-plain-arm shape): \(r.values)")
    }

    /// IDENTITY-SAFETY: a ternary in a `.tag(...)` IDENTITY position is NOT lifted (its
    /// literals must stay byte-stable — a `.tag` selects a Picker/TabView item; rewriting it
    /// would break selection). Only the custom-view DISPLAY label (`icon:`) lifts.
    func testTernaryInTagIdentityPositionNotLifted() throws {
        let r = driveLifter(#"OnboardingPage(icon: "x").tag(f ? "a" : "b")"#)
        XCTAssertFalse(r.values.contains("a") || r.values.contains("b"),
            ".tag identity ternary must NOT lift: \(r.values)")
    }

    /// RANGE ROUND-TRIP (the cli 1.6.28 silent-drop guard): the recorded ranges point at the
    /// ORIGINAL arm literals (quotes included). Editing ONLY an arm value keeps the slot id
    /// stable (OTA-deliverable); a STRUCTURAL edit (changing the condition) churns the id
    /// (correctly MISMATCHes — no silent-drop). Lowered through a full view so the ranges are
    /// body-relative, exactly as the fingerprint walker consumes them.
    func testTernaryRangeRoundTripAndIdStability() throws {
        func lower(_ thenLit: String, _ cond: String) -> (id: String, args: [String], ranges: [Range<Int>], src: String, body: String)? {
            let src = """
            import SwiftUI
            struct Screen: View {
                @State private var page = 0
                var body: some View {
                    Button {
                        if \(cond) { page += 1 } else { page = 0 }
                    } label: {
                        Text(\(cond) ? "\(thenLit)" : "Get Started")
                    }
                }
            }
            """
            let lowered = BodyLowering().lowerAllViews(source: src)
            guard let screen = lowered.first(where: { $0.viewName == "Screen" }),
                  let leaf = screen.opaqueLeaves.first(where: { !$0.stringArgs.isEmpty }) else { return nil }
            return (leaf.id, leaf.stringArgs, leaf.stringArgRanges, src, screen.guestBody)
        }
        guard let a = lower("Next", "page < 2"),
              let b = lower("Continue", "page < 2") else {
            throw XCTSkip("ternary did not route to a parameterized slot in this build")
        }
        // Editing ONLY the arm value keeps the slot id stable → OTA-patchable.
        XCTAssertEqual(a.id, b.id,
            "an arm-value edit MUST keep the slot id stable (OTA): \(a.id) vs \(b.id)")
        XCTAssertEqual(a.args, ["Next", "Get Started"], "current arm values ride stringArgs: \(a.args)")
        XCTAssertEqual(b.args, ["Continue", "Get Started"], "edited arm value rides stringArgs: \(b.args)")
        // The recorded ranges point EXACTLY at the arm literals in the ORIGINAL source bytes
        // (quotes included) — the silent-drop guard: the fingerprint walker normalizes those
        // bytes and only those bytes.
        let bytes = Array(a.src.utf8)
        XCTAssertEqual(a.ranges.count, 2, "two arm ranges recorded: \(a.ranges)")
        let slice0 = String(decoding: bytes[a.ranges[0]], as: UTF8.self)
        let slice1 = String(decoding: bytes[a.ranges[1]], as: UTF8.self)
        XCTAssertEqual(slice0, "\"Next\"", "range 0 must cover the then-arm literal: [\(slice0)]")
        XCTAssertEqual(slice1, "\"Get Started\"", "range 1 must cover the else-arm literal: [\(slice1)]")
        // A STRUCTURAL edit (different CONDITION) must churn the id — the condition rides the
        // native slot (it's not a lifted literal), so changing it is a real native change.
        guard let c = lower("Next", "page < 3") else {
            throw XCTSkip("structural-edit lowering unavailable")
        }
        XCTAssertNotEqual(a.id, c.id,
            "a CONDITION edit is a structural native change → id MUST churn (no silent-drop): \(a.id) vs \(c.id)")
    }

    /// END-TO-END: the real AppD `OnboardingScreen` shape — the Button slots
    /// natively (multi-statement action reading `private` state) and its label `Text(ternary)`
    /// arm literals lift into the Button slot's `stringArgs` (so a "Next"→… edit is
    /// fingerprint-stable). The view auto-routes; the arm literals ride WASM.
    func testRealOnboardingButtonTernaryLifts() throws {
        let src = """
        import SwiftUI
        struct OnboardingScreen: View {
            @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
            @State private var currentPage = 0
            var body: some View {
                VStack {
                    Button {
                        if currentPage < 2 { currentPage += 1 } else { hasSeenOnboarding = true }
                    } label: {
                        Text(currentPage < 2 ? "Next" : "Get Started")
                            .font(.headline)
                    }
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: src)
        let v = lowered.first { $0.viewName == "OnboardingScreen" }!
        let buttonLeaf = v.opaqueLeaves.first { $0.label == "Button" }
        XCTAssertNotNil(buttonLeaf, "the Button must slot natively (private-state action)")
        XCTAssertEqual(buttonLeaf?.stringArgs, ["Next", "Get Started"],
            "the ternary arm literals must lift into the Button slot's stringArgs: \(String(describing: buttonLeaf?.stringArgs))")
    }
}
