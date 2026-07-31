// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator

/// Tests for private-computed-property scalar-field host-projection (same-file-thunk only).
///
/// A body reading `foo.totalCount` (Int) in a NUMERIC position (e.g. a `.badge` modifier
/// or a `if foo.totalCount > 0` guard) where `foo` is a `private var foo: Foo { … }`
/// (computed, type-annotated) should:
///  - lower `foo.totalCount` as a `__numtok_` input token (not a free identifier)
///  - make the view routable (was demoting before the fix)
///  - NOT cross the whole `Foo` object into WASM
///  - NOT apply this widening when the thunk is a SEPARATE file (`sameFileThunk: false`)
final class SwiftUIPrivateComputedFieldTests: XCTestCase {

    // MARK: - Positive: same-file thunk lowers private computed property's numeric fields

    /// A view that reads `foo.totalCount` (Int) in a NUMERIC guard position
    /// (`if foo.totalCount > 0`) and `foo.title` (String) in a Text node, where `foo`
    /// is a `private var foo: Foo { rows.first ?? Foo() }` — a computed property returning
    /// a cataloged type — should lower with host-projected tokens and be auto-routable.
    func testPrivateComputedPropertyScalarFieldsProject() throws {
        let src = """
        import SwiftUI

        class Foo {
            var totalCount: Int = 0
            var title: String = ""
        }

        struct V: View {
            private var _storage: [Foo] = []
            private var foo: Foo { _storage.first ?? Foo() }
            var body: some View {
                if foo.totalCount > 0 {
                    Text(foo.title)
                        .navigationTitle("Items")
                }
            }
        }
        """
        let lowering = BodyLowering()
        // Same-file thunk: private computed property fields SHOULD project.
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "V" },
                              "view V should be found in lowered output")

        // (1) The view routes (no unresolved symbols / unmarshalled blocking inputs).
        //     Before the fix, `foo.totalCount` would be a free identifier the scope check
        //     couldn't resolve — `referencesUnresolvedSymbol` would be true.
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "no free guest identifier after private-computed field projection; unresolved: \(v.unresolvedSymbols)")
        XCTAssertFalse(v.referencesUnmarshalledInput,
                       "no unmarshalled input reference (foo itself never crosses to WASM)")

        // (2) The guest body contains a __numtok_ for foo.totalCount (host-projected Int).
        //     `foo.totalCount > 0` in an `if` guard → numeric token so the guest can eval it.
        XCTAssertTrue(v.guestBody.contains("__numtok_"),
                      "foo.totalCount should host-project as a __numtok_ input token: \(v.guestBody)")

        // (3) The guest body contains a __strtok_ for foo.title (host-projected String).
        //     stringTypedMemberPaths already covers private computed properties;
        //     this confirms the string side is intact.
        XCTAssertTrue(v.guestBody.contains("__strtok_"),
                      "foo.title should host-project as a __strtok_ input token: \(v.guestBody)")

        // (4) The whole `foo` object does NOT appear as a free identifier in the guest
        //     body — the receiver never crosses to WASM.
        XCTAssertFalse(BodyLowering.guestBodyReferencesAny(v.guestBody, names: ["foo"]),
                       "the `foo` object must not leak as a free identifier into guest WASM: \(v.guestBody)")

        // (5) At least one .number host token exists (for foo.totalCount).
        let numberTokens = v.hostTokens.filter { $0.kind == .number }
        XCTAssertFalse(numberTokens.isEmpty,
                       "at least one .number host token for foo.totalCount: \(v.hostTokens)")

        // (6) The number token rides the input JSON (__numtok_ key), not the tree.
        for tok in numberTokens {
            XCTAssertTrue(tok.ridesInputJSON,
                          "numeric token for foo.totalCount must ride input JSON (__numtok_): \(tok)")
        }
    }

    // MARK: - Negative: separate-file thunk does NOT project private computed property fields

    /// With `sameFileThunk: false` (the separate-file legacy thunk), a `private var foo: Foo`
    /// computed property's numeric fields must NOT host-project — a separate-file extension
    /// can't call `self.foo` if `foo` is `private`. The view should demote.
    func testPrivateComputedPropertyDoesNotProjectWithSeparateFileThunk() throws {
        let src = """
        import SwiftUI

        class Foo {
            var totalCount: Int = 0
            var title: String = ""
        }

        struct V: View {
            private var _storage: [Foo] = []
            private var foo: Foo { _storage.first ?? Foo() }
            var body: some View {
                if foo.totalCount > 0 {
                    Text(foo.title)
                        .navigationTitle("Items")
                }
            }
        }
        """
        let lowering = BodyLowering()
        // SEPARATE-file thunk: `private foo` is inaccessible → `foo.totalCount` cannot
        // host-project via the new path → the scope check flags it as unresolved.
        let views = lowering.lowerAllViews(source: src, sameFileThunk: false)
        let v = try XCTUnwrap(views.first { $0.viewName == "V" },
                              "view V should still be found (just demoted)")

        // With separate-file thunk the numeric token for foo.totalCount must NOT be present
        // via the new code path — the private computed property was NOT widened.
        // Either the view has an unresolved symbol (blocked), or there are no .number tokens
        // from the new path. (String tokens from the existing stringTypedMemberPaths may
        // still appear — that path doesn't filter private; we only gate the NUMERIC side.)
        let numberTokensFromNewPath = v.hostTokens.filter {
            $0.kind == .number && $0.source.contains("foo.totalCount")
        }
        XCTAssertTrue(numberTokensFromNewPath.isEmpty,
            "separate-file thunk must NOT produce a numeric host token via the new private-computed path: "
            + "\(v.hostTokens.map { "\($0.kind):\($0.source)" })")

        // Additionally the scope check should block the view (totalCount is unresolved
        // since the numeric projection didn't fire).
        XCTAssertTrue(v.referencesUnresolvedSymbol || v.referencesUnmarshalledInput,
            "separate-file thunk must leave the view blocked (no projection of private computed field): "
            + "unresolved=\(v.unresolvedSymbols)")
    }

    // MARK: - Safety: collection fields of a computed property's type are NOT projected

    /// A computed property `private var box: Container { Container() }` where `Container`
    /// has an Int field `count` AND a collection field `items: [String]` — ONLY the scalar
    /// field should produce a __numtok_. The collection must be excluded.
    func testNonScalarFieldOfComputedPropertyDoesNotProject() throws {
        let src = """
        import SwiftUI

        struct Container {
            var count: Int = 0
            var items: [String] = []
        }

        struct W: View {
            private var box: Container {
                Container()
            }
            var body: some View {
                if box.count > 0 {
                    Text("non-empty")
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "W" })

        // box.count (Int) should project → __numtok_
        XCTAssertTrue(v.guestBody.contains("__numtok_"),
                      "box.count (Int) should host-project as __numtok_: \(v.guestBody)")

        // box.items (collection) must NOT appear as a host token — collections are excluded
        // by the `isCollectionType` guard in `privateComputedMemberScalarPaths`.
        let itemsTokens = v.hostTokens.filter { $0.source.contains("items") }
        XCTAssertTrue(itemsTokens.isEmpty,
                      "box.items (collection) must NOT produce a host token: \(itemsTokens)")

        // The view should be routable.
        XCTAssertFalse(v.referencesUnresolvedSymbol,
                       "W should be routable with box.count projected: \(v.unresolvedSymbols)")
    }

    // MARK: - Safety: Optional return type of computed property is excluded

    /// A computed property with an Optional return type (`private var foo: Foo? { … }`)
    /// must NOT project its fields — an Optional receiver makes `self.foo.field` potentially
    /// nil-crash at thunk-eval time. The view must demote.
    func testOptionalComputedPropertyDoesNotProject() throws {
        let src = """
        import SwiftUI

        struct Foo {
            var count: Int = 0
        }

        struct Z: View {
            private var foo: Foo? { nil }
            var body: some View {
                if (foo?.count ?? 0) > 0 {
                    Text("has items")
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "Z" })

        // The Optional-return computed property must NOT produce a numeric token for `count`.
        // (The body uses `foo?.count ?? 0` — a nil-coalescing optional chain — which is an
        // opaque expression to the engine and should demote or produce a different token type.)
        let fooCountTokens = v.hostTokens.filter {
            $0.kind == .number && $0.source.contains("foo")
        }
        XCTAssertTrue(fooCountTokens.isEmpty,
                      "Optional computed property must NOT produce a numeric token via the new path: \(fooCountTokens)")
    }
}
