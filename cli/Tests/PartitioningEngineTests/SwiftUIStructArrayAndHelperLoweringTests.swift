// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// Tests for two engine-lowering limit-shrinks (both DEMOTE-SAFE — a form the guest
/// can't faithfully + compilably lower slots to `.opaque`/demotes to native; the
/// module ALWAYS compiles):
///
///   TASK 1 — `ForEach`/`List(items)` over a FLAT-struct array (`[SomeStruct]`,
///     all stored fields scalar/string). The engine marshals it as a JSON
///     array-of-objects, generates a mirroring guest `struct` + an array scanner, and
///     emits a real guest loop binding `item` so `item.<field>` resolves. A struct
///     with a non-scalar/nested field, or a row that uses the element in a non-field
///     way (bare `item`, a method call), DEMOTES the whole ForEach.
///
///   TASK 2 — a body referencing a SAME-STRUCT `some View`/`@ViewBuilder` helper
///     (`var header: some View`, `func makeRow() -> some View`) inline-lowers the
///     helper's body into the parent IR (no `.opaque` slot for it). A helper that
///     takes arguments, is in another type, or isn't body-lowerable keeps slotting.
final class SwiftUIStructArrayAndHelperLoweringTests: XCTestCase {

    // MARK: - TASK 1: ForEach over a flat-struct array → bound guest loop

    func testForEachOverFlatStructArrayLowersToBoundLoop() throws {
        let source = """
        import SwiftUI
        struct Player { var name: String; var score: Int }
        struct Leaderboard: View {
            @State private var players: [Player] = []
            var body: some View {
                VStack {
                    ForEach(players, id: \\.name) { player in
                        HStack {
                            Text(player.name)
                            Text("\\(player.score)")
                        }
                    }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let g = lowered.guestBody

        // A real guest loop binds `player` over the marshalled struct array — NOT a
        // native `.opaque` slot, NOT an unbound free identifier.
        XCTAssertTrue(g.contains("for player in players"),
                      "ForEach must bind the loop var over the struct array: \(g)")
        XCTAssertTrue(g.contains("N.forEach("), "still a forEach node: \(g)")
        XCTAssertFalse(g.contains("N.opaque"),
                       "a flat-struct-array ForEach must NOT demote: \(g)")
        // The element's fields reach the row body as live member accesses.
        XCTAssertTrue(g.contains("player.name"), "row reads item.name: \(g)")
        XCTAssertTrue(g.contains("player.score"), "row reads item.score: \(g)")

        // The input is classified as a guest-reconstructable struct-array → no demote.
        let players = try XCTUnwrap(lowered.inputs.first { $0.name == "players" })
        XCTAssertEqual(players.kind, .structArray)
        XCTAssertTrue(players.kind.guestReconstructable)
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "reading a reconstructable struct array must not force demotion")
        let element = try XCTUnwrap(players.structElement)
        XCTAssertEqual(element.typeName, "Player")
        XCTAssertEqual(element.fields.map(\.name), ["name", "score"])
        XCTAssertEqual(element.fields.map(\.kind), [.string, .int])
    }

    func testFlatStructArrayGuestEmitsMirrorStructAndScanner() throws {
        let source = """
        import SwiftUI
        struct Player { var name: String; var score: Int }
        struct Leaderboard: View {
            let players: [Player] = []
            var body: some View {
                List(players, id: \\.name) { p in
                    Text(p.name)
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody, inputs: lowered.inputs)
        let emission = try SwiftUIGuestEmitter().emit(views: [view])
        let wrapper = try XCTUnwrap(emission.files.first { $0.fileName == "_PatchSwiftUI.swift" })

        // A mirroring guest struct with the flat fields is emitted.
        XCTAssertTrue(wrapper.contents.contains("struct _PatchRow_Player {"),
                      "a mirroring guest struct is generated")
        XCTAssertTrue(wrapper.contents.contains("var name: String = \"\""))
        XCTAssertTrue(wrapper.contents.contains("var score: Int = 0"))
        // The input binds via the array-of-objects scanner (real value, not a default).
        XCTAssertTrue(wrapper.contents.contains("_patchScanPlayerRowArray(_patchInputs, \"players\")"),
                      "the struct-array input binds via the generated scanner")
        // A dynamic List over the struct array lowers (no native slot).
        XCTAssertTrue(lowered.guestBody.contains("N.list("))
        XCTAssertFalse(lowered.guestBody.contains("N.opaque"))
    }

    // MARK: - TASK 1: demote-safe boundaries

    func testForEachOverNestedStructArrayNowLowersToBoundLoop() throws {
        // `Item` has a NESTED struct field (`addr: Address`). Recursive marshalling now
        // reconstructs nested structs (render-correctness proven by
        // `SwiftUIRichInputMarshalTests.testNestedStructArrayExecutesInWasm`), so
        // `[Item]` is a `.structArray` and the ForEach lowers to a REAL bound guest
        // loop — no longer a native demote.
        let source = """
        import SwiftUI
        struct Address { var city: String }
        struct Item { var name: String; var addr: Address }
        struct ItemList: View {
            let items: [Item] = []
            var body: some View {
                VStack {
                    ForEach(items, id: \\.name) { it in
                        Text(it.name)
                    }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let items = try XCTUnwrap(lowered.inputs.first { $0.name == "items" })
        XCTAssertEqual(items.kind, .structArray, "a nested-struct array now reconstructs")
        XCTAssertTrue(items.kind.guestReconstructable)
        XCTAssertTrue(lowered.guestBody.contains("N.forEach("), "still a forEach node")
        XCTAssertTrue(lowered.guestBody.contains("for it in items"),
                      "lowers to a real BOUND guest loop: \(lowered.guestBody)")
        // SAFETY INVARIANT (preserved): the loop var is properly BOUND, never leaked as
        // a free identifier that would fail the guest module compile.
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "a reconstructed struct-array loop is not a live unmarshalled read")
    }

    func testForEachStructArrayWithBareElementUseDemotes() throws {
        // The row uses `p` BARE (`Text("\\(p)")` interpolates the whole struct) — the
        // guest struct isn't CustomStringConvertible, so this can't compile. Demote.
        let source = """
        import SwiftUI
        struct P { var name: String }
        struct L: View {
            let ps: [P] = []
            var body: some View {
                VStack { ForEach(ps, id: \\.name) { p in Text("\\(p)") } }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("N.opaque"),
                      "a bare-element use in a struct-array row demotes: \(g)")
        XCTAssertFalse(g.contains("for p in ps"))
    }

    func testForEachStructArrayWithMethodCallOnElementDemotes() throws {
        // `p.name.uppercased()` chains a method onto the field — not guest-safe
        // (the scalar field is a plain value; a method call may pull Unicode tables).
        let source = """
        import SwiftUI
        struct P { var name: String }
        struct L: View {
            let ps: [P] = []
            var body: some View {
                VStack { ForEach(ps, id: \\.name) { p in Text(p.name.uppercased()) } }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("N.opaque"),
                      "a method call on a struct-array element field demotes: \(g)")
        XCTAssertFalse(g.contains("for p in ps"))
    }

    func testStructWithScalarArrayFieldNowReconstructs() {
        // RICH-INPUT WIDENING: a struct with a SCALAR-ARRAY field is now reconstructable
        // (the guest decodes the nested array). It classifies `.structArray`, not
        // `.unsupported` — the array field rides as a guest `[String]`.
        let arr = """
        import SwiftUI
        struct Tagged { var name: String; var tags: [String] }
        struct V: View { let xs: [Tagged] = []; var body: some View { ForEach(xs, id: \\.name) { x in Text(x.name) } } }
        """
        let lowered = BodyLowering().lowerAllViews(source: arr).first
        let xs = lowered?.inputs.first { $0.name == "xs" }
        XCTAssertEqual(xs?.kind, .structArray, "a struct with a scalar-array field now reconstructs")
    }

    func testStructWithOptionalScalarFieldNowReconstructs() {
        // OPTIONAL-SCALAR struct fields are RECONSTRUCTABLE since the recursive
        // FieldShape widening (see `SwiftUIRichInputMarshalTests` optional-scalar tests):
        // a `var nick: String?` no longer disqualifies the struct. With the row reading
        // only the non-optional `x.name`, the `[Bad]` input lowers as `.structArray`
        // (an optional field used in an UNSAFE way — a bare read, not `?? default`/`==nil`
        // — would still demote at the row-usage gate, but the input KIND reconstructs).
        let arr = """
        import SwiftUI
        struct Bad { var name: String; var nick: String? }
        struct V: View { let xs: [Bad] = []; var body: some View { ForEach(xs, id: \\.name) { x in Text(x.name) } } }
        """
        let lowered = BodyLowering().lowerAllViews(source: arr).first
        let xs = lowered?.inputs.first { $0.name == "xs" }
        XCTAssertEqual(xs?.kind, .structArray,
                       "an optional-SCALAR field reconstructs (FieldShape.optionalScalar) — no longer disqualifies")
    }

    // MARK: - TASK 2: inline-lower a same-struct helper

    func testSomeViewHelperPropertyInlinesNoOpaque() throws {
        let source = """
        import SwiftUI
        struct Screen: View {
            let title: String = "Hi"
            var header: some View {
                HStack {
                    Image(systemName: "star.fill")
                    Text(title)
                }
            }
            var body: some View {
                VStack {
                    header
                    Text("body")
                }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        // The helper's body is substituted inline — its leaves are lowered, NOT slotted.
        XCTAssertFalse(g.contains("N.opaque"),
                       "the `header` helper inlines with no opaque slot: \(g)")
        XCTAssertTrue(g.contains("N.image(systemName: \"star.fill\")"),
                      "the helper's Image lowered inline: \(g)")
        // The header's HStack is in the tree (the inlined content), and `title` resolves.
        XCTAssertTrue(g.contains("N.hstack"), "the helper's HStack lowered inline: \(g)")
        XCTAssertTrue(g.contains("N.text(title)"), "the helper reads the view's input: \(g)")

        // Coverage reflects the inlined content (the view is thunkSafe-eligible).
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertTrue(lowered.opaqueLeaves.isEmpty, "no opaque leaves for an inlined helper")
        XCTAssertTrue(lowered.report.hasLoweredContentNode)
    }

    func testExplicitSelfHelperReferenceInlines() throws {
        // `self.header` (explicit `self.`) must inline the same as a bare `header`.
        let source = """
        import SwiftUI
        struct Screen: View {
            var badge: some View { Text("!") }
            var body: some View { VStack { self.badge } }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(g.contains("N.opaque"), "self.badge inlines: \(g)")
        XCTAssertTrue(g.contains("N.text(\"!\")"), "self.badge lowered inline: \(g)")
    }

    func testViewBuilderHelperFunctionInlines() throws {
        let source = """
        import SwiftUI
        struct Screen: View {
            @ViewBuilder
            func makeFooter() -> some View {
                Divider()
                Text("footer")
            }
            var body: some View {
                VStack {
                    Text("top")
                    makeFooter()
                }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(g.contains("N.opaque"),
                       "a no-arg @ViewBuilder helper func inlines: \(g)")
        XCTAssertTrue(g.contains("N.divider"), "the helper's Divider lowered inline: \(g)")
        XCTAssertTrue(g.contains("N.text(\"footer\")"), "the helper's Text lowered inline: \(g)")
        // The multi-statement helper body wraps in a group (@ViewBuilder semantics).
        XCTAssertTrue(g.contains("N.group("), "a multi-view helper body groups: \(g)")
    }

    func testHelperWithArgumentsKeepsSlotting() throws {
        // `makeRow(_:)` takes an argument → NOT inlinable (its param isn't in the parent
        // scope). The call stays a native `.opaque` slot.
        let source = """
        import SwiftUI
        struct Screen: View {
            @ViewBuilder
            func makeRow(_ s: String) -> some View { Text(s) }
            var body: some View {
                VStack {
                    Text("top")
                    makeRow("a")
                }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("N.opaque"),
                      "an arg-taking helper call keeps slotting: \(g)")
        XCTAssertTrue(g.contains("N.text(\"top\")"), "the rest of the body still lowers: \(g)")
    }

    func testHelperWithConcreteReturnTypeStillInlinesWhenViewShaped() throws {
        // A `some View` helper that returns a single concrete view inlines fine.
        let source = """
        import SwiftUI
        struct Screen: View {
            var badge: some View { Text("!") }
            var body: some View { VStack { badge } }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(g.contains("N.opaque"))
        XCTAssertTrue(g.contains("N.text(\"!\")"), "the single-view helper inlined: \(g)")
    }

    func testNonHelperReferenceStillSlots() throws {
        // A reference to a `let card = ...` body-local (not a same-struct view helper)
        // still slots — TASK 2 must not over-reach.
        let source = """
        import SwiftUI
        struct Screen: View {
            var body: some View {
                VStack {
                    let card = Text("x")
                    card
                }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("N.opaque"), "a body-local reference still slots: \(g)")
    }

    func testHelperWithBuilderLocalLetIsNotInlined() throws {
        // A helper whose builder declares a local `let` would emit a LIVE reference to
        // an unbound guest name (the emitter skips the decl) → it must NOT inline (keep
        // slotting), so the single-unit guest module can never be broken by it.
        let source = """
        import SwiftUI
        struct Screen: View {
            var header: some View {
                let label = "computed"
                Text(label)
            }
            var body: some View { VStack { header } }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("N.opaque"),
                      "a helper with a builder-local `let` keeps slotting (guest-safe): \(g)")
        // The unbound local must NEVER appear as a live identifier in the guest tree.
        XCTAssertFalse(BodyLowering.guestBodyReferencesAny(g, names: ["label"]),
                       "the helper's local must not leak into the guest tree: \(g)")
    }

    func testInteractiveHelperWithActionClosureLetStillInlines() throws {
        // A `let` inside an ACTION closure (`Button { let d = …; … }`) is NOT a builder
        // statement (the closure body is behavior, not a node), so the HELPER STILL
        // INLINES — the action-closure local doesn't disqualify it. The enclosing VStack
        // lowers, and the Button lives inside the inlined helper.
        //
        // NOTE (dead-button correctness fix): this Button's action is a MULTI-statement body
        // (`let delta = 1; count += delta`) — NOT a recordable single dispatch rule — so the
        // Button itself now SLOTS to a native control (a real, working button via the thunk's
        // self-context) rather than lowering to a bare `N.button` that would dispatch NOTHING
        // on tap (the old latent dead button). The helper-inlining is unaffected.
        let source = """
        import SwiftUI
        struct Screen: View {
            @State private var count = 0
            var stepper: some View {
                Button("Add") {
                    let delta = 1
                    count += delta
                }
            }
            var body: some View { VStack { stepper } }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let g = lowered.guestBody
        // The helper inlined: the enclosing VStack lowered (not slotted as a helper call).
        XCTAssertTrue(g.contains("N.vstack("),
                      "the interactive helper inlines into the lowered VStack: \(g)")
        // The multi-statement-action Button slots to a native control (the dead-button fix) —
        // NOT a bare dead `N.button(actionID:)`.
        XCTAssertTrue(g.contains("N.opaque"),
                      "the multi-statement-action Button slots to a working native control: \(g)")
        XCTAssertFalse(g.contains("N.button(actionID:"),
                       "no dead bare button is emitted for the undispatchable action: \(g)")
        // The Button slot is self-only (reads `count`) → slotable → the view still routes.
        XCTAssertTrue(lowered.opaqueLeaves.allSatisfy { $0.slotable },
                      "the Button slot is slotable (reads only @State count): \(lowered.opaqueLeaves)")
        XCTAssertFalse(lowered.hasUndispatchableAction,
                       "a BODY-context Button slot does not force the view to demote")
    }

    func testRecursiveHelperGuardDemotes() throws {
        // A helper referencing itself must not expand forever — the re-entrant use
        // slots (faithful) and the module stays finite/compilable.
        let source = """
        import SwiftUI
        struct Screen: View {
            var loop: some View {
                VStack {
                    Text("a")
                    loop
                }
            }
            var body: some View { loop }
        }
        """
        // Must terminate (no infinite expansion) and produce a finite tree.
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("N.text(\"a\")"), "the helper lowered once: \(g)")
        XCTAssertTrue(g.contains("N.opaque"), "the recursive self-reference slots: \(g)")
    }

    // MARK: - TASK 1 END-TO-END: a flat-struct-array ForEach runs in WASM

    func testFlatStructArrayForEachExecutesInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__Leaderboard", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping struct-array WASM run")

        let source = """
        import SwiftUI
        struct Player { var name: String; var score: Int }
        struct Leaderboard: View {
            let players: [Player] = []
            var body: some View {
                VStack {
                    ForEach(players, id: \\.name) { player in
                        HStack {
                            Text(player.name)
                            Text("score=\\(player.score)")
                        }
                    }
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "structarray-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        let runner = try Runner(wasm: wasm)

        // Marshal a REAL array-of-objects in — the WASM loop must unroll one row per
        // element, reading each element's marshalled fields.
        let inputs = Data(#"{"players":[{"name":"Ada","score":10},{"name":"Bob","score":20}]}"#.utf8)
        let outBytes = try runner.callPacked("view_body", [UInt8](inputs))
        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
        let desc = body.root.describe()

        // The unrolled rows reflect the struct array — proving the guest struct +
        // scanner + loop binding compiled AND ran in WASM (not the empty default).
        XCTAssertTrue(desc.contains("ForEach"), "the tree has a ForEach node: \(desc)")
        XCTAssertTrue(desc.contains("Ada"), "row 0 name from the array: \(desc)")
        XCTAssertTrue(desc.contains("score=10"), "row 0 score from the array: \(desc)")
        XCTAssertTrue(desc.contains("Bob"), "row 1 name from the array: \(desc)")
        XCTAssertTrue(desc.contains("score=20"), "row 1 score from the array: \(desc)")
        // Exactly two rows.
        let rowCount = desc.components(separatedBy: "score=").count - 1
        XCTAssertEqual(rowCount, 2, "exactly one row per array element: \(desc)")

        // An EMPTY array yields zero rows (the loop ran, appended nothing).
        let empty = try Runner(wasm: wasm).callPacked("view_body", [UInt8](Data(#"{"players":[]}"#.utf8)))
        let emptyDesc = try JSONDecoder().decode(BodyEmission.self, from: Data(empty)).root.describe()
        XCTAssertFalse(emptyDesc.contains("score="), "empty array → no rows: \(emptyDesc)")

        // A MISSING field in an element falls back to the struct default (no crash):
        // the second element omits `score` → renders score=0.
        let partial = try Runner(wasm: wasm).callPacked(
            "view_body", [UInt8](Data(#"{"players":[{"name":"X","score":5},{"name":"Y"}]}"#.utf8)))
        let partialDesc = try JSONDecoder().decode(BodyEmission.self, from: Data(partial)).root.describe()
        XCTAssertTrue(partialDesc.contains("score=5"), "element 0 score: \(partialDesc)")
        XCTAssertTrue(partialDesc.contains("score=0"), "missing field → default 0: \(partialDesc)")
        XCTAssertTrue(partialDesc.contains("Y"), "element 1 name still parsed: \(partialDesc)")
    }

    /// REACTIVE-COLLECTION MARSHALLING, end-to-end in WASM: a `ForEach(vm.players)` over a
    /// reactive view-model's collection compiles to a bound guest loop and renders the real
    /// rows from the SDK's nested-object marshalling (`{"vm":{"players":[…]}}`). Proves the
    /// synthetic flat-struct input + nested struct-array reconstruction + loop binding compile
    /// AND run in WASM — the full lever, not just the emitted source.
    func testReactiveCollectionForEachExecutesInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__Leaderboard", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping reactive-collection WASM run")
        let source = """
        import SwiftUI
        import Combine
        struct Player { var name: String; var score: Int }
        final class GameVM: ObservableObject {
            @Published var players: [Player] = []
        }
        struct Leaderboard: View {
            @StateObject var vm = GameVM()
            var body: some View {
                VStack {
                    ForEach(vm.players, id: \\.name) { player in
                        HStack {
                            Text(player.name)
                            Text("score=\\(player.score)")
                        }
                    }
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "reactive-collection-exec")
        let wasm = [UInt8](try Data(contentsOf: module))

        // The SDK marshals the reactive object as a NESTED object under its member name.
        let inputs = Data(#"{"vm":{"players":[{"name":"Ada","score":10},{"name":"Bob","score":20}]}}"#.utf8)
        let outBytes = try Runner(wasm: wasm).callPacked("view_body", [UInt8](inputs))
        let desc = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes)).root.describe()
        XCTAssertTrue(desc.contains("ForEach"), "tree has a ForEach node: \(desc)")
        XCTAssertTrue(desc.contains("Ada") && desc.contains("score=10"), "row 0 from the reactive array: \(desc)")
        XCTAssertTrue(desc.contains("Bob") && desc.contains("score=20"), "row 1 from the reactive array: \(desc)")
        XCTAssertEqual(desc.components(separatedBy: "score=").count - 1, 2, "exactly one row per element: \(desc)")

        // Empty reactive collection → zero rows (the loop ran, appended nothing).
        let empty = try Runner(wasm: wasm).callPacked("view_body", [UInt8](Data(#"{"vm":{"players":[]}}"#.utf8)))
        let emptyDesc = try JSONDecoder().decode(BodyEmission.self, from: Data(empty)).root.describe()
        XCTAssertFalse(emptyDesc.contains("score="), "empty reactive array → no rows: \(emptyDesc)")
    }

    // MARK: - TASK 2 END-TO-END: an inlined helper compiles + runs in WASM

    func testInlinedHelperExecutesInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__Screen", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping inlined-helper WASM run")

        let source = """
        import SwiftUI
        struct Screen: View {
            let title: String = ""
            var header: some View {
                HStack {
                    Image(systemName: "star.fill")
                    Text(title)
                }
            }
            var body: some View {
                VStack {
                    header
                    Text("body")
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "inlinehelper-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        let runner = try Runner(wasm: wasm)
        // The inlined `header` reads the view's `title` input — marshal a real value.
        let outBytes = try runner.callPacked("view_body", [UInt8](Data(#"{"title":"Patched"}"#.utf8)))
        let desc = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes)).root.describe()
        // The inlined helper's content is in the WASM-built tree (compiled + ran).
        XCTAssertTrue(desc.contains("HStack"), "the inlined helper's HStack is in the tree: \(desc)")
        XCTAssertTrue(desc.contains("star.fill"), "the helper's Image inlined + ran: \(desc)")
        XCTAssertTrue(desc.contains("Patched"), "the helper read the marshalled input: \(desc)")
        XCTAssertTrue(desc.contains("body"), "the sibling Text rode WASM too: \(desc)")
    }

    // MARK: - Helpers (mirror SwiftUIForEachLoweringTests)

    private func compileSwiftUIModule(source: String, into label: String) throws -> URL {
        let lowering = BodyLowering()
        let lowered = lowering.lowerAllViews(source: source)
        let guestViews = lowered
            .filter { !$0.referencesUnmarshalledInput }
            .map { SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody,
                                                 inputs: $0.inputs, stateModel: $0.stateModel) }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.swiftui.wasm")
        let compiler = SwiftWasmCompiler(
            exportedSymbols: emission.exports + ["patch_malloc", "patch_free"])
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "guest WASM compile failed:\n\(result.log)")
        return out
    }

    private final class Runner {
        let store: Store
        let instance: Instance
        let wasi: WASIBridgeToHost
        init(wasm: [UInt8]) throws {
            let engine = Engine()
            self.store = Store(engine: engine)
            self.wasi = try WASIBridgeToHost()
            var imports = Imports()
            wasi.link(to: &imports, store: store)
            PatchHostTestImports.register(into: &imports, store: store)
            let module = try parseWasm(bytes: wasm)
            self.instance = try module.instantiate(store: store, imports: imports)
            try wasi.initialize(instance)
        }
        func memory() throws -> Memory {
            guard let m = instance.exports[memory: "memory"] else { throw NSError(domain: "abi", code: 1) }
            return m
        }
        func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
            guard let fn = instance.exports[function: name],
                  let malloc = instance.exports[function: "patch_malloc"] else {
                throw NSError(domain: "abi", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing export \(name)"])
            }
            let ptr = try malloc([.i32(UInt32(input.count))])[0].i32
            let mem = try memory()
            mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: input.count) { raw in
                raw.copyBytes(from: input)
            }
            let packed = try fn([.i32(ptr), .i32(UInt32(input.count))])[0].i64
            let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
            let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
            let all = try memory().data
            return [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
        }
    }

    // MARK: - Custom-child-view row over marshalled struct array → indexedForEachSlot

    /// `ForEach(items){ item in RowView(item:item) }` over a marshalled struct-array input
    /// where each row is a CUSTOM (non-lowerable) child view — the "AppE style"
    /// pattern. Previously: the ElementUsageScanner rejected the bare `item` usage → the
    /// whole ForEach became ONE opaque slot (a single native leaf). Now: lowers to
    /// `N.indexedForEachSlot`, the thunk supplies a per-row `(Int)->AnyView` factory, and
    /// the SDK reconstitutes rows natively — the ForEach STRUCTURE is now OTA-editable.
    func testMarshalledStructArrayCustomRowLowersToIndexedSlot() throws {
        let source = """
        import SwiftUI
        struct Plant { var name: String; var wateringInterval: Int; var notes: String }
        struct PlantRowView: View {
            let plant: Plant
            var body: some View { Text(plant.name) }
        }
        struct PlantListView: View {
            @State private var items: [Plant] = []
            var body: some View {
                List {
                    ForEach(items, id: \\.name) { item in
                        PlantRowView(plant: item)
                    }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(
            BodyLowering().lowerAllViews(source: source).first(where: { $0.viewName == "PlantListView" }),
            "PlantListView must be found")

        // The ForEach now lowers to an indexedForEachSlot, NOT a plain opaque slot.
        XCTAssertTrue(lowered.guestBody.contains("N.indexedForEachSlot("),
                      "struct-array custom-row ForEach must lower to indexedForEachSlot: \(lowered.guestBody)")
        XCTAssertFalse(lowered.guestBody.contains("N.opaque"),
                       "must NOT emit a whole-ForEach opaque leaf: \(lowered.guestBody)")

        // The indexed row slot records the correct collection source + loop var + row.
        XCTAssertEqual(lowered.indexedRowSlots.count, 1,
                       "exactly one indexed row slot: \(lowered.indexedRowSlots)")
        let slot = try XCTUnwrap(lowered.indexedRowSlots.first)
        XCTAssertEqual(slot.collectionSource, "items",
                       "collectionSource must be the marshalled array name: \(slot.collectionSource)")
        XCTAssertEqual(slot.loopVar, "item",
                       "loop var matches the closure parameter: \(slot.loopVar)")
        XCTAssertTrue(slot.rowSource.hasPrefix("PlantRowView("),
                      "rowSource is the custom row call: \(slot.rowSource)")

        // No opaque leaves (no native slots needed beyond the indexed-row machinery).
        XCTAssertTrue(lowered.opaqueLeaves.isEmpty,
                      "no opaque leaves: \(lowered.opaqueLeaves.map { $0.label })")

        // The input is still classified as a reconstructable struct array.
        let items = try XCTUnwrap(lowered.inputs.first { $0.name == "items" })
        XCTAssertEqual(items.kind, .structArray)
        XCTAssertFalse(lowered.referencesUnmarshalledInput)
    }

    /// The custom-row slot resolves its collectionSource by thunk-accessible name.
    /// A ForEach WITHOUT a List wrapper: bare `indexedForEachSlot` as the body root.
    func testMarshalledStructArrayCustomRowBareForEachLowersToIndexedSlot() throws {
        let source = """
        import SwiftUI
        struct Task { var title: String; var done: Bool }
        struct TaskCell: View {
            let task: Task
            var body: some View { Text(task.title) }
        }
        struct TasksView: View {
            let tasks: [Task]
            var body: some View {
                ForEach(tasks, id: \\.title) { t in
                    TaskCell(task: t)
                }
            }
        }
        """
        let lowered = try XCTUnwrap(
            BodyLowering().lowerAllViews(source: source).first(where: { $0.viewName == "TasksView" }),
            "TasksView must be found")

        XCTAssertTrue(lowered.guestBody.contains("N.indexedForEachSlot("),
                      "bare ForEach over struct array with custom row must emit indexedForEachSlot: \(lowered.guestBody)")
        XCTAssertFalse(lowered.guestBody.contains("N.opaque"),
                       "must not emit whole-ForEach opaque: \(lowered.guestBody)")
        let slot = try XCTUnwrap(lowered.indexedRowSlots.first)
        XCTAssertEqual(slot.collectionSource, "tasks")
        XCTAssertEqual(slot.loopVar, "t")
        XCTAssertTrue(slot.rowSource.contains("TaskCell("))
    }

    /// DEMOTE-SAFETY: a struct-array ForEach row that reads `item.field` (NOT the whole
    /// element) keeps the EXISTING guest-loop path (a real `for item in items` loop).
    /// The indexed-slot path fires ONLY when the row ROOT is a custom (non-lowerable) view.
    func testMarshalledStructArrayFieldReadRowKeepsGuestLoop() throws {
        let source = """
        import SwiftUI
        struct Player { var name: String; var score: Int }
        struct Leaderboard: View {
            let players: [Player]
            var body: some View {
                VStack {
                    ForEach(players, id: \\.name) { player in
                        HStack {
                            Text(player.name)
                            Text("\\(player.score)")
                        }
                    }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        // Standard-view rows still use the GUEST LOOP path (not an indexed slot).
        XCTAssertTrue(lowered.guestBody.contains("for player in players"),
                      "field-read row must keep the real guest loop: \(lowered.guestBody)")
        XCTAssertFalse(lowered.guestBody.contains("N.indexedForEachSlot"),
                       "standard-view rows must NOT use the indexed-slot path: \(lowered.guestBody)")
        XCTAssertTrue(lowered.indexedRowSlots.isEmpty,
                      "no indexed row slot for a standard-view row")
    }

    /// DEMOTE-SAFETY: a struct-array ForEach whose row reads a PRIVATE member or body-local
    /// that is NOT the loop var must NOT produce an indexed slot (the thunk can't compile it).
    func testMarshalledStructArrayCustomRowWithBodyLocalDemotes() throws {
        let source = """
        import SwiftUI
        struct Item { var name: String }
        struct ItemCard: View {
            let item: Item
            let extra: String
            var body: some View { Text(item.name + extra) }
        }
        struct ItemList: View {
            let items: [Item]
            var body: some View {
                let prefix = "row-"
                ForEach(items, id: \\.name) { item in
                    ItemCard(item: item, extra: prefix)
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source)
            .first(where: { $0.viewName == "ItemList" }))
        // `prefix` is a body-local → row is NOT slotable → no indexed slot.
        XCTAssertTrue(lowered.indexedRowSlots.isEmpty,
                      "row reading a body-local must not produce an indexed slot")
        // The ForEach falls back to ONE opaque leaf (the established safe path).
        XCTAssertFalse(lowered.guestBody.contains("N.indexedForEachSlot"),
                       "a non-slotable row must not use indexedForEachSlot: \(lowered.guestBody)")
    }
}
