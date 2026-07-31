// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator
import PartitioningEngine

/// Tests the HYBRID thunk placement — the new default `patchcli prepare` mode.
///
/// Per view, the engine decides:
///   • SEPARATE-FILE (the common case): the whole thunk lands in a dedicated generated
///     file; the developer's view file gets ONLY the `dynamic` keyword. No big appended
///     block.
///   • SAME-FILE (factored): a view whose body host-resolves a `private`/`fileprivate`
///     member keeps ONLY its helper methods in its own file (Swift access control is
///     file-scoped) + an actionable comment NAMING those members. Its body-replacement
///     still rides the generated file (minimal in-file footprint).
final class ThunkGeneratorHybridTests: XCTestCase {
    private func run(_ files: [(name: String, text: String)]) -> ThunkGenerator.Result {
        let sources = files.map {
            ThunkGenerator.SourceFile(url: URL(fileURLWithPath: "/x/\($0.name)"), text: $0.text)
        }
        return ThunkGenerator().prepare(sources: sources, hybrid: true)
    }
    private func text(_ r: ThunkGenerator.Result, named name: String) -> String {
        r.modifiedFiles.first { $0.url.lastPathComponent == name }?.text ?? ""
    }

    // MARK: - Non-private view → SEPARATE FILE

    func testNonPrivateViewGoesSeparateFile() {
        let r = run([("Hello.swift", """
        import SwiftUI
        struct Hello: View {
            var body: some View { Text("hi") }
        }
        """)])
        XCTAssertTrue(r.hybrid)
        XCTAssertEqual(r.viewNames, ["Hello"])
        XCTAssertEqual(r.placements["Hello"], .separateFile)

        // The view's OWN file gets ONLY `dynamic` — NO same-file block.
        let view = text(r, named: "Hello.swift")
        XCTAssertTrue(view.contains("dynamic var body: some View"), view)
        XCTAssertFalse(view.contains(ThunkGenerator.sameFileBeginMarker),
                       "a non-private view must NOT get a same-file block:\n\(view)")
        XCTAssertFalse(view.contains("extension Hello {"),
                       "the whole thunk lives in the generated file, not the view file:\n\(view)")
        XCTAssertTrue(ThunkGenerator.parses(view), view)

        // The whole thunk (replacement + helper methods) is in the generated file.
        let gen = r.generatedFileContents
        XCTAssertTrue(gen.contains("extension Hello {"), gen)
        XCTAssertTrue(gen.contains("@_dynamicReplacement(for: body)"), gen)
        XCTAssertTrue(gen.contains(#"typeName: "Hello""#), gen)
        XCTAssertTrue(gen.contains("func __patchSlots() -> [String: ([String]) -> AnyView]"), gen)
        XCTAssertTrue(gen.contains("func __patchTokens() -> [String: PatchHostToken]"), gen)
        XCTAssertTrue(gen.contains("func __patchRowSlots() -> [String: PatchRowSlot]"), gen)
        XCTAssertTrue(ThunkGenerator.parses(gen), gen)
    }

    // MARK: - Private-member view → SAME FILE (factored + annotated)

    func testPrivateMemberViewStaysSameFileFactoredAndAnnotated() {
        // CardView reads a PRIVATE @State struct field (`profile.name`). Under the
        // separate-file contract that read is inaccessible (file-scoped private), so its
        // helper methods MUST stay same-file.
        let r = run([("CardView.swift", """
        import SwiftUI
        struct CardView: View {
            struct Profile { var name: String; var age: Int }
            @State private var profile = Profile(name: "Ada", age: 36)
            var body: some View {
                VStack {
                    Text(profile.name)
                    Text("static")
                }
            }
        }
        """)])
        XCTAssertEqual(r.viewNames, ["CardView"])
        guard case .sameFileBecausePrivate(let members)? = r.placements["CardView"] else {
            return XCTFail("CardView should be same-file-because-private; got \(String(describing: r.placements["CardView"]))")
        }
        XCTAssertTrue(members.contains("profile"),
                      "the annotation should name the private member `profile`: \(members)")

        let view = text(r, named: "CardView.swift")
        // The view file gets `dynamic` + the FACTORED block (helper methods only) + the
        // actionable comment.
        XCTAssertTrue(view.contains("dynamic var body"), view)
        XCTAssertTrue(view.contains(ThunkGenerator.sameFileBeginMarker), view)
        XCTAssertTrue(view.contains("reads private member(s): profile"),
                      "the kept-in-file comment must name the member + how to remove it:\n\(view)")
        XCTAssertTrue(view.contains("make those member(s) `internal`")
                      || view.contains("`internal`"),
                      "the comment must say how to move it out:\n\(view)")
        // The factored block carries the HELPER methods…
        XCTAssertTrue(view.contains("func __patchTokens() -> [String: PatchHostToken]"), view)
        // …but NOT the body-replacement (that rides the generated file).
        XCTAssertFalse(view.contains("@_dynamicReplacement(for: body)"),
                       "the body-replacement must NOT be in the developer's file (it needs no private access):\n\(view)")
        XCTAssertTrue(ThunkGenerator.parses(view), view)

        // The generated file carries the body-replacement (every view) but NOT this
        // view's helper methods (those are same-file).
        let gen = r.generatedFileContents
        XCTAssertTrue(gen.contains("@_dynamicReplacement(for: body)"), gen)
        XCTAssertTrue(gen.contains(#"typeName: "CardView""#), gen)
        XCTAssertFalse(gen.contains("func __patchTokens"),
                       "a same-file view's helper methods must NOT be duplicated in the generated file:\n\(gen)")
        XCTAssertTrue(ThunkGenerator.parses(gen), gen)
    }

    // MARK: - Mixed project: one separate, one same-file

    func testMixedProjectRoutesEachViewIndependently() {
        let r = run([
            ("Hello.swift", """
            import SwiftUI
            struct Hello: View { var body: some View { Text("hi") } }
            """),
            ("CardView.swift", """
            import SwiftUI
            struct CardView: View {
                struct Profile { var name: String }
                @State private var profile = Profile(name: "Ada")
                var body: some View { Text(profile.name) }
            }
            """),
        ])
        XCTAssertEqual(r.placements["Hello"], .separateFile)
        guard case .sameFileBecausePrivate? = r.placements["CardView"] else {
            return XCTFail("CardView should be same-file; got \(String(describing: r.placements["CardView"]))")
        }
        // Hello's file: just dynamic, no block.
        XCTAssertFalse(text(r, named: "Hello.swift").contains(ThunkGenerator.sameFileBeginMarker))
        // CardView's file: factored block.
        XCTAssertTrue(text(r, named: "CardView.swift").contains(ThunkGenerator.sameFileBeginMarker))
        // The generated file replacement-routes BOTH views.
        XCTAssertTrue(r.generatedFileContents.contains(#"typeName: "Hello""#))
        XCTAssertTrue(r.generatedFileContents.contains(#"typeName: "CardView""#))
        // Hello's helper methods are in the generated file; CardView's are not.
        XCTAssertTrue(r.generatedFileContents.contains("extension Hello {"))
        XCTAssertFalse(r.generatedFileContents.contains("extension CardView {\n    /// Native"))
        XCTAssertTrue(ThunkGenerator.parses(r.generatedFileContents))
    }

    // MARK: - Bug R2-#28: private members declared in a `private extension`

    /// A view whose body reads members declared in a `private extension` (Swift makes EVERY
    /// member of a `private extension` file-scoped private, even with no per-member modifier)
    /// must be placed SAME-FILE. Before the fix, `privateNamesByView` walked only the struct
    /// decl, missed the extension-declared privates, and routed the view SEPARATE — the
    /// separate-file thunk's slot source `Text(label).foregroundStyle(accentColor)` would then
    /// fail the developer's build (`'label' is inaccessible due to 'private'`).
    func testPrivateExtensionMembersForceSameFile() {
        let r = run([("CardView.swift", """
        import SwiftUI
        struct CardView: View {
            var body: some View { Text(label).foregroundStyle(accentColor) }
        }
        private extension CardView {
            var label: String { "x" }
            var accentColor: Color { .red }
        }
        """)])
        XCTAssertEqual(r.viewNames, ["CardView"])
        guard case .sameFileBecausePrivate(let members)? = r.placements["CardView"] else {
            return XCTFail("a view reading `private extension` members must be same-file; got "
                           + "\(String(describing: r.placements["CardView"]))")
        }
        XCTAssertTrue(members.contains("label") && members.contains("accentColor"),
                      "the annotation must name the extension-private members: \(members)")
        // The helper block (with the slot source) stays in the view's own file…
        let view = text(r, named: "CardView.swift")
        XCTAssertTrue(view.contains(ThunkGenerator.sameFileBeginMarker), view)
        XCTAssertTrue(view.contains("func __patchSlots() -> [String: ([String]) -> AnyView]"), view)
        XCTAssertTrue(ThunkGenerator.parses(view), view)
        // …and the slot source (which reads the private members) is NOT in the separate
        // generated file (which couldn't compile it).
        XCTAssertFalse(r.generatedFileContents.contains("foregroundStyle(accentColor)"),
                       "the private-reading slot source must not leak into the separate file:\n"
                       + r.generatedFileContents)
        XCTAssertTrue(ThunkGenerator.parses(r.generatedFileContents))
    }

    /// A `fileprivate extension` is equally file-scoped → same-file placement too.
    func testFileprivateExtensionMembersForceSameFile() {
        let r = run([("CardView.swift", """
        import SwiftUI
        struct CardView: View {
            var body: some View { Text(label) }
        }
        fileprivate extension CardView {
            var label: String { "x" }
        }
        """)])
        guard case .sameFileBecausePrivate(let members)? = r.placements["CardView"] else {
            return XCTFail("a view reading a `fileprivate extension` member must be same-file; got "
                           + "\(String(describing: r.placements["CardView"]))")
        }
        XCTAssertTrue(members.contains("label"), members.description)
    }

    /// A member explicitly marked `private` inside a NON-private extension is also caught.
    func testPerMemberPrivateInPlainExtensionForcesSameFile() {
        let r = run([("CardView.swift", """
        import SwiftUI
        struct CardView: View {
            var body: some View { Text(label) }
        }
        extension CardView {
            private var label: String { "x" }
        }
        """)])
        guard case .sameFileBecausePrivate(let members)? = r.placements["CardView"] else {
            return XCTFail("a view reading a per-member `private` extension var must be same-file; got "
                           + "\(String(describing: r.placements["CardView"]))")
        }
        XCTAssertTrue(members.contains("label"), members.description)
    }

    /// An INTERNAL (default-access) extension member is reachable cross-file → the view may
    /// still go SEPARATE (no false same-file forcing).
    func testInternalExtensionMemberStaysSeparate() {
        let r = run([("CardView.swift", """
        import SwiftUI
        struct CardView: View {
            var body: some View { Text(label) }
        }
        extension CardView {
            var label: String { "x" }
        }
        """)])
        XCTAssertEqual(r.placements["CardView"], .separateFile,
                       "an internal extension member is cross-file-reachable; the view should be separate")
    }

    // MARK: - Idempotency of the same-file factored block

    func testSameFileFactoredBlockIsIdempotent() {
        let original = """
        import SwiftUI
        struct CardView: View {
            struct Profile { var name: String }
            @State private var profile = Profile(name: "Ada")
            var body: some View { Text(profile.name) }
        }
        """
        let r1 = run([("CardView.swift", original)])
        let once = text(r1, named: "CardView.swift")
        let r2 = run([("CardView.swift", once)])
        let twice = text(r2, named: "CardView.swift")
        XCTAssertEqual(r2.dynamicInsertions, 0, "dynamic must not be inserted twice")
        XCTAssertEqual(once, twice, "the same-file factored block must be a fixed point")
        XCTAssertEqual(twice.components(separatedBy: ThunkGenerator.sameFileBeginMarker).count - 1, 1,
                       "exactly one factored block after re-run")
        XCTAssertTrue(ThunkGenerator.parses(twice))
    }

    // MARK: - Empty project

    func testNoViewsProducesNoGeneratedFile() {
        let r = run([("Helper.swift", "import Foundation\nstruct Helper {}")])
        XCTAssertTrue(r.viewNames.isEmpty)
        XCTAssertTrue(r.generatedFileContents.isEmpty)
        XCTAssertTrue(r.placements.isEmpty)
    }

    // MARK: - PER-VIEW ISOLATION (the meta-fix): one bad view never disables the rest

    /// A project with several NORMAL views + ONE view that previously corrupted the thunk
    /// (a mid-`body` `#if` fragment). The engine must DEMOTE just the bad view (no thunk)
    /// and KEEP the rest — and the generated file must always PARSE (the prerequisite for
    /// `patchcli prepare` not aborting). This is the central guarantee: one `#if`/`switch`
    /// view cannot disable OTA patching for the whole app.
    func testPerViewIsolationDemotesOneKeepsRest() {
        let r = run([
            ("Good1.swift", """
            import SwiftUI
            struct Good1: View { var body: some View { Text("a") } }
            """),
            ("Good2.swift", """
            import SwiftUI
            struct Good2: View { let n: Int; var body: some View { VStack { Text("\\(n)") } } }
            """),
            ("Bad.swift", """
            import SwiftUI
            struct Bad: View {
                let t: String
                var body: some View {
                    Text(t)
                    #if os(tvOS)
                        .font(.system(size: 21))
                    #else
                        .font(.caption)
                    #endif
                }
            }
            """),
        ])
        // The two good views still get thunks; the project is NOT aborted.
        XCTAssertTrue(r.viewNames.contains("Good1"), "Good1 must still thunk: \(r.viewNames)")
        XCTAssertTrue(r.viewNames.contains("Good2"), "Good2 must still thunk: \(r.viewNames)")
        // The generated file always parses (the must-hold prerequisite for prepare).
        XCTAssertTrue(ThunkGenerator.parses(r.generatedFileContents), r.generatedFileContents)
        // Every modified source file still parses (we never leave a broken splice).
        for f in r.modifiedFiles { XCTAssertTrue(ThunkGenerator.parses(f.text), f.text) }
        // The generated file carries the good views' replacements.
        XCTAssertTrue(r.generatedFileContents.contains("extension Good1 {"))
        XCTAssertTrue(r.generatedFileContents.contains("extension Good2 {"))
    }

    /// A `private struct X: View` can't be extended from the separate generated file
    /// (`'X' is inaccessible due to 'private'`). Its WHOLE thunk (replacement + helpers) must
    /// be SAME-FILE, and it must NOT appear in the generated file's extensions.
    func testPrivateViewTypeGoesFullSameFile() {
        let r = run([("AccountSwitcher.swift", """
        import SwiftUI
        struct AccountSwitcher: View {
            var body: some View { VStack { AccountChip(name: "a") } }
        }
        private struct AccountChip: View {
            let name: String
            var body: some View { Text(name) }
        }
        """)])
        let view = text(r, named: "AccountSwitcher.swift")
        // The private type's FULL thunk (replacement + helpers) is SAME-FILE.
        XCTAssertTrue(view.contains(ThunkGenerator.sameFileBeginMarker), view)
        XCTAssertTrue(view.contains("extension AccountChip {"), "private type thunk must be same-file:\n\(view)")
        XCTAssertTrue(view.contains("@_dynamicReplacement(for: body)"), view)
        XCTAssertTrue(ThunkGenerator.parses(view), view)
        // The generated file must NOT extend the private type (would be inaccessible cross-file).
        XCTAssertFalse(r.generatedFileContents.contains("extension AccountChip {"),
                       "the generated (separate) file must NOT extend a private view type:\n\(r.generatedFileContents)")
        XCTAssertTrue(ThunkGenerator.parses(r.generatedFileContents), r.generatedFileContents)
    }

    /// A `switch`-with-`return` view alongside a normal view. The switch view demotes (its
    /// thunk would not compile), the normal one keeps its thunk, the output parses.
    func testPerViewIsolationSwitchReturnDemotes() {
        let r = run([
            ("Normal.swift", """
            import SwiftUI
            struct Normal: View { var body: some View { Text("ok") } }
            """),
            ("Switchy.swift", """
            import SwiftUI
            struct Switchy: View {
                let rating: Int
                var body: some View {
                    switch rating {
                    case 1: return Text("a")
                    default: return Text("b")
                    }
                }
            }
            """),
        ])
        XCTAssertTrue(r.viewNames.contains("Normal"), "Normal must still thunk: \(r.viewNames)")
        XCTAssertTrue(ThunkGenerator.parses(r.generatedFileContents), r.generatedFileContents)
        for f in r.modifiedFiles { XCTAssertTrue(ThunkGenerator.parses(f.text), f.text) }
    }
}
