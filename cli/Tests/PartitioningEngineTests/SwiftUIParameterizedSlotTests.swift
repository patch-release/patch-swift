// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// PARAMETERIZED NATIVE SLOTS — the coverage lever that makes editing a SIMPLE
/// STRING LITERAL inside a SLOTTED custom view (`DisplayText(text: "Hello")`)
/// OTA-patchable.
///
/// A custom-view call is slotted natively (the view lives in the signed binary,
/// not the WASM). Previously the literal was BAKED into the slot closure AND the
/// slot id hashed the whole source (literal included), so editing the string moved
/// the id → the patch referenced a slot the installed app lacked → demote. Now the
/// emitter LIFTS each simple string-literal arg into a placeholder, the slot id is
/// STRUCTURAL (literal-independent → STABLE across edits + fingerprint-stable), the
/// values ride WASM in `BodyEmission.slotArgs`, and the thunk renders a FACTORY
/// `{ a in DisplayText(text: a[0], size: 28) }`. Editing the string ships OTA.
final class SwiftUIParameterizedSlotTests: XCTestCase {

    // MARK: - 1. STRUCTURAL ID STABILITY + slotArgs carry the current literal

    /// A view that slots `Foo(text: "Settings", size: 28)` (Foo custom): the `.opaque`
    /// slot id is STRUCTURAL (derived from the template with the literal normalized
    /// out), so it's IDENTICAL whether the literal is "Settings" or "SettingsX". The
    /// lifted value rides via the leaf's `stringArgs` (→ `BodyEmission.slotArgs[id]`).
    func testSlotIdIsStableAcrossStringEdit() throws {
        func lower(_ literal: String) -> (id: String, args: [String]) {
            let source = """
            import SwiftUI
            struct Foo: View { var text: String; var size: Double; var body: some View { Text(text) } }
            struct Screen: View {
                var body: some View {
                    VStack {
                        Text("hdr")
                        Foo(text: "\(literal)", size: 28)
                    }
                }
            }
            """
            let lowered = BodyLowering().lowerAllViews(source: source)
            let screen = lowered.first { $0.viewName == "Screen" }!
            // The custom-view call is the lone PARAMETERIZED opaque leaf (non-empty args).
            let leaf = screen.opaqueLeaves.first { !$0.stringArgs.isEmpty }!
            return (leaf.id, leaf.stringArgs)
        }
        let a = lower("Settings")
        let b = lower("SettingsX")
        XCTAssertEqual(a.id, b.id,
            "structural slot id MUST be identical across a string-literal edit "
            + "(id=\(a.id) vs \(b.id)) — otherwise the OTA patch references a missing slot")
        XCTAssertEqual(a.args, ["Settings"], "the CURRENT literal rides via stringArgs: \(a.args)")
        XCTAssertEqual(b.args, ["SettingsX"], "the EDITED literal rides via stringArgs: \(b.args)")
        XCTAssertTrue(a.id.hasPrefix("op_"), "id is an opaque slot id: \(a.id)")
    }

    /// The shipped TREE for a parameterized slot carries the structural id but NO
    /// literal in its label (the label is the view name). So the tree bytes are
    /// literal-independent — the whole point of the lever.
    func testSlotTreeCarriesIdNotLiteral() throws {
        let source = """
        import SwiftUI
        struct Foo: View { var text: String; var body: some View { Text(text) } }
        struct Screen: View {
            var body: some View { VStack { Text("h"); Foo(text: "Settings") } }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: source)
        let screen = lowered.first { $0.viewName == "Screen" }!
        let leaf = screen.opaqueLeaves.first { !$0.stringArgs.isEmpty }!
        // The lowered guest body emits `N.opaque(id: "<id>", label: "Foo")` — the
        // literal is NOT in the tree (it rides slotArgs).
        XCTAssertTrue(screen.guestBody.contains(leaf.id), "tree references the slot id")
        XCTAssertFalse(screen.guestBody.contains("Settings"),
            "the literal must NOT appear in the shipped tree (it rides slotArgs): \(screen.guestBody)")
    }

    /// Two STRUCTURALLY-identical sibling custom-view calls with DIFFERENT literals
    /// (`Foo(text:"A")` + `Foo(text:"B")`) must get DISTINCT slot ids — otherwise the
    /// second would render the first's value (a wrong-slot render).
    func testStructurallyIdenticalSiblingsGetDistinctIds() throws {
        let source = """
        import SwiftUI
        struct Foo: View { var text: String; var body: some View { Text(text) } }
        struct Screen: View {
            var body: some View {
                VStack {
                    Foo(text: "A")
                    Foo(text: "B")
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: source)
        let screen = lowered.first { $0.viewName == "Screen" }!
        let leaves = screen.opaqueLeaves.filter { !$0.stringArgs.isEmpty }
        XCTAssertEqual(leaves.count, 2, "both custom-view calls are parameterized leaves")
        XCTAssertNotEqual(leaves[0].id, leaves[1].id,
            "structurally-identical-but-differently-valued siblings MUST get distinct ids")
        XCTAssertEqual(Set(leaves.map { $0.stringArgs.first }), ["A", "B"],
            "each leaf carries its OWN value: \(leaves.map { $0.stringArgs })")
    }

    /// P0-B WRONG-RENDER GUARD: an INTERPOLATED string `"Hi \(name)"` whose dynamic part is a
    /// slotable self property must NOT lift its static segment. The original `makeInterpolatedReplacement`
    /// path embeds the template as a DeclReferenceExprSyntax identifier — after
    /// `renderParameterizedTemplate` replaces `\u{1}0\u{1}` → `a[0]`, the thunk emits
    /// `Foo(text: "a[0]\(name)")`. In Swift, `a[0]` here is the LITERAL TEXT "a[0]", not
    /// the slotArg value — so on-device it renders "a[0]Alice" instead of "Hi Alice".
    /// That is a WRONG RENDER. The safe path: leave true interpolations (`\(expr)`) baked.
    /// A "Hi " static-segment edit triggers a MISMATCH (the safe failure), not a wrong render.
    func testInterpolatedStringLiftsStaticWhenDynamicSlotable() throws {
        let source = """
        import SwiftUI
        struct Foo: View { var text: String; var body: some View { Text(text) } }
        struct Screen: View {
            var name = "x"
            var body: some View { VStack { Foo(text: "Hi \\(name)") } }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: source)
        let screen = lowered.first { $0.viewName == "Screen" }!
        // P0-B: the interpolated string must NOT be lifted. "Hi " must NOT appear in stringArgs.
        // If it did, the thunk would render "a[0]Alice" (literal "a[0]" + name) — wrong render.
        XCTAssertFalse(screen.opaqueLeaves.contains { $0.stringArgs.contains("Hi ") },
            "P0-B WRONG-RENDER GUARD: the static segment of a true interpolation must NOT be "
            + "lifted — the slot template would render 'a[0]' literally instead of 'Hi '. "
            + "stringArgs: \(screen.opaqueLeaves.map { $0.stringArgs })")
    }

    /// SAFETY (cli 1.6.32 lift-by-default must NOT regress this): an interpolation whose dynamic
    /// part is a NON-slotable BODY-LOCAL stays FULLY BAKED (no lift) — the lifter keeps the whole
    /// string native when any dynamic `\(expr)` can't be slotted (else the guest would bind a
    /// wrong default / leak a free identifier). The static "Hi " must NOT ride WASM here.
    func testInterpolatedStringWithBodyLocalDynamicStaysBaked() throws {
        let source = """
        import SwiftUI
        struct Foo: View { var text: String; var body: some View { Text(text) } }
        struct Screen: View {
            var body: some View {
                let n = String(describing: 1)
                return VStack { Foo(text: "Hi \\(n)") }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: source)
        let screen = lowered.first { $0.viewName == "Screen" }!
        XCTAssertTrue(screen.opaqueLeaves.allSatisfy { !$0.stringArgs.contains("Hi ") },
            "an interpolation with a body-local dynamic must NOT lift its static: "
            + "\(screen.opaqueLeaves.map { $0.stringArgs })")
    }

    /// Numbers / bools stay BAKED (only simple string literals are lifted).
    func testNumbersAndBoolsStayBaked() throws {
        let source = """
        import SwiftUI
        struct Foo: View { var text: String; var size: Double; var on: Bool; var body: some View { Text(text) } }
        struct Screen: View {
            var body: some View { VStack { Foo(text: "T", size: 28, on: true) } }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: source)
        let screen = lowered.first { $0.viewName == "Screen" }!
        let leaf = screen.opaqueLeaves.first { !$0.stringArgs.isEmpty }!
        XCTAssertEqual(leaf.stringArgs, ["T"], "only the string is lifted: \(leaf.stringArgs)")
        // The template keeps the number + bool baked.
        XCTAssertTrue(leaf.source.contains("size: 28"), "number stays baked: \(leaf.source)")
        XCTAssertTrue(leaf.source.contains("on: true"), "bool stays baked: \(leaf.source)")
    }

    // MARK: - 2. THUNK FACTORY: parameterized + plain

    /// The generated thunk's `__patchSlots()` is a FACTORY map; a parameterized leaf
    /// renders `{ (a: [String]) in a.count >= 1 ? AnyView(Foo(text: a[0], size: 28)) : AnyView(EmptyView()) }`.
    func testThunkEmitsParameterizedFactory() throws {
        let source = """
        import SwiftUI
        struct Foo: View { var text: String; var size: Double; var body: some View { Text(text) } }
        struct Screen: View {
            var body: some View { VStack { Text("h"); Foo(text: "Settings", size: 28) } }
        }
        """
        let gen = ThunkGenerator()
        let r = gen.prepare(sources: [.init(url: URL(fileURLWithPath: "/tmp/A.swift"), text: source)],
                            sameFile: true)
        let text = r.modifiedFiles.first?.text ?? ""
        XCTAssertTrue(text.contains("func __patchSlots() -> [String: ([String]) -> AnyView]"),
                      "slot map is a factory ABI: \(text)")
        XCTAssertTrue(text.contains("(a: [String]) in a.count >= 1 ? AnyView(Foo(text: a[0], size: 28))"),
                      "parameterized factory substitutes a[0] for the lifted string: \(text)")
        XCTAssertTrue(text.contains(": AnyView(EmptyView())"),
                      "arg-count guard demotes to EmptyView (never crash): \(text)")
        // The FACTORY line must not bake the literal — it rides a[0]. (The original
        // `body` is still present in the file's `else { body }` branch, so the literal
        // legitimately appears elsewhere; assert only the factory closure is clean.)
        let factoryLine = text.split(separator: "\n").first { $0.contains("__s[") } ?? ""
        XCTAssertFalse(factoryLine.contains("\"Settings\""),
                       "the literal is NOT baked into the factory closure (it rides a[0]): \(factoryLine)")
    }

    /// `renderParameterizedTemplate` substitution is exact for multiple args.
    func testRenderParameterizedTemplateSubstitution() {
        let template = "Foo(a: \u{1}0\u{1}, n: 3, b: \u{1}1\u{1})"
        let out = ThunkGenerator.renderParameterizedTemplate(template, argCount: 2)
        XCTAssertEqual(out, "Foo(a: a[0], n: 3, b: a[1])")
    }

    /// The generated GUEST source assigns `emission.slotArgs = [...]` with the
    /// current literal, so it rides WASM (independent of the WASM round-trip).
    func testGuestSourceBakesSlotArgs() throws {
        let source = """
        import SwiftUI
        struct Foo: View { var text: String; var size: Double; var body: some View { Text(text) } }
        struct Screen: View {
            var body: some View { VStack { Text("Header"); Foo(text: "Settings", size: 28) } }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: source)
        let guestViews = lowered.filter { !$0.referencesUnmarshalledInput }.map { lv -> SwiftUIGuestEmitter.GuestView in
            var sa: [String: [String]] = [:]
            for leaf in lv.opaqueLeaves where !leaf.stringArgs.isEmpty { sa[leaf.id] = leaf.stringArgs }
            return SwiftUIGuestEmitter.GuestView(viewName: lv.viewName, guestBody: lv.guestBody,
                                                 inputs: lv.inputs, stateModel: lv.stateModel, slotArgs: sa)
        }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)
        let wrapper = emission.files.first { $0.fileName.contains("PatchSwiftUI") }!.contents
        XCTAssertTrue(wrapper.contains("emission.slotArgs ="),
                      "guest source assigns slotArgs: \(wrapper)")
        XCTAssertTrue(wrapper.contains("[\"Settings\"]"),
                      "guest bakes the current literal into slotArgs: \(wrapper)")
    }

    // MARK: - 3. RENDER-CORRECTNESS in WASM (the decisive gate)

    /// END-TO-END: a parent view slotting `Foo(text: "Settings", size: 28)` (Foo
    /// custom) lowers → compiles to WASM → host-runs `view_body` → the emission's
    /// `slotArgs[id]` carries the CURRENT literal AND the tree's `.opaque` id matches.
    /// Then we re-lower with the EDITED literal "SettingsX" and assert the id is
    /// IDENTICAL (structural stability) while slotArgs carries the NEW value — i.e.
    /// editing the string ships OTA (id stable + value rides WASM).
    func testParameterizedSlotExecutesInWasmAndIsStable() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__Screen", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping parameterized-slot WASM run")

        func build(_ literal: String) throws -> (slotArgs: [String: [String]], opaqueIDs: [String]) {
            let source = """
            import SwiftUI
            struct Foo: View { var text: String; var size: Double; var body: some View { Text(text) } }
            struct Screen: View {
                var body: some View {
                    VStack {
                        Text("Header")
                        Foo(text: "\(literal)", size: 28)
                    }
                }
            }
            """
            let module = try compileSlotModule(source: source, into: "paramslot-\(literal)")
            let wasm = [UInt8](try Data(contentsOf: module))
            let runner = try Runner(wasm: wasm)
            // Call the SCREEN export specifically (bare `view_body` forwards to the
            // FIRST view = Foo, the custom child — not the parent we're testing).
            let out = try runner.callPacked("view_body__Screen", [])
            let emission = try JSONDecoder().decode(BodyEmission.self, from: Data(out))
            let ids = collectOpaqueIDs(emission.root)
            return (emission.slotArgs ?? [:], ids)
        }

        let a = try build("Settings")
        // The emission carries slotArgs for the parameterized slot, with the literal.
        XCTAssertEqual(a.slotArgs.count, 1, "one parameterized slot: \(a.slotArgs)")
        let id = try XCTUnwrap(a.slotArgs.keys.first)
        XCTAssertEqual(a.slotArgs[id], ["Settings"],
                       "slotArgs carries the current literal: \(a.slotArgs)")
        XCTAssertTrue(a.opaqueIDs.contains(id),
                      "the tree's opaque id matches the slotArgs key (\(id)) vs \(a.opaqueIDs)")

        // Edit the literal → recompile → the slot id is UNCHANGED, value updated.
        let b = try build("SettingsX")
        let idB = try XCTUnwrap(b.slotArgs.keys.first)
        XCTAssertEqual(id, idB,
            "EDITING the string keeps the slot id stable (OTA-patchable): \(id) vs \(idB)")
        XCTAssertEqual(b.slotArgs[idB], ["SettingsX"],
                       "the EDITED literal rides WASM in slotArgs: \(b.slotArgs)")
    }

    // MARK: - 4. TITLED CONTROLS (Link/Toggle/Slider) — title-literal fingerprint stability

    /// `Link("Open Site", destination: complexURL)` — the destination can't be resolved
    /// to a literal URL string, so the control falls back to an opaque slot. The TITLE
    /// "Open Site" is a plain string literal and MUST be lifted via the parameterized-
    /// slot mechanism (not baked into the slot source). Editing only the title must keep
    /// the structural slot id STABLE so the OTA patch still resolves the slot.
    func testLinkWithUnresolvableDestinationLiftsTitle() throws {
        func lower(_ title: String) -> (id: String, args: [String]) {
            let source = """
            import SwiftUI
            struct Screen: View {
                var url: URL
                var body: some View {
                    VStack {
                        Text("Header")
                        Link("\(title)", destination: url)
                    }
                }
            }
            """
            let lowered = BodyLowering().lowerAllViews(source: source)
            let screen = lowered.first { $0.viewName == "Screen" }!
            let leaf = screen.opaqueLeaves.first { !$0.stringArgs.isEmpty }!
            return (leaf.id, leaf.stringArgs)
        }
        let a = lower("Open Site")
        let b = lower("Visit Us")
        XCTAssertEqual(a.id, b.id,
            "structural slot id MUST be stable across a Link title edit "
            + "(id=\(a.id) vs \(b.id)) — false mismatch if it changes")
        XCTAssertEqual(a.args, ["Open Site"], "current title rides stringArgs: \(a.args)")
        XCTAssertEqual(b.args, ["Visit Us"], "edited title rides stringArgs: \(b.args)")
    }

    /// `Toggle("Dark Mode", isOn: $customProperty)` — the binding can't be extracted
    /// (`customProperty` is not a recognised marshalled field), so the control falls
    /// back to an opaque slot. The TITLE "Dark Mode" must be lifted (fingerprint-stable).
    func testToggleWithUnresolvableBindingLiftsTitle() throws {
        func lower(_ title: String) -> (id: String, args: [String]) {
            // `customFlag` is NOT a marshalled @State/@Binding the engine knows about, so
            // `eventArg(call, "isOn")` will fail and we fall through to the opaqueCall path.
            let source = """
            import SwiftUI
            struct Screen: View {
                @State var customFlag: Bool = false
                var body: some View {
                    VStack {
                        Text("Header")
                        Toggle("\(title)", isOn: $customFlag)
                    }
                }
            }
            """
            let lowered = BodyLowering().lowerAllViews(source: source)
            let screen = lowered.first { $0.viewName == "Screen" }!
            // Look for a parameterized leaf (lifted title).
            let paramLeaf = screen.opaqueLeaves.first { !$0.stringArgs.isEmpty }
            guard let leaf = paramLeaf else {
                // If eventArg succeeds (engine improvement), the view lowers normally and
                // there's no opaque leaf — the test is vacuously satisfied (no regression).
                return ("no-opaque-leaf", [title])
            }
            return (leaf.id, leaf.stringArgs)
        }
        let a = lower("Dark Mode")
        let b = lower("Enable Dark Mode")
        guard a.id != "no-opaque-leaf" else { return }  // view lowered fully — no bug
        XCTAssertEqual(a.id, b.id,
            "Toggle title edit must keep slot id stable: \(a.id) vs \(b.id)")
        XCTAssertEqual(a.args, ["Dark Mode"], "current title rides stringArgs: \(a.args)")
        XCTAssertEqual(b.args, ["Enable Dark Mode"], "edited title rides stringArgs: \(b.args)")
    }

    /// `Link("Title", destination: url)` where the TITLE is a variable (not a string
    /// literal) — must NOT be lifted (body-local reference). The leaf falls back to the
    /// plain baked slot (`stringArgs` empty). Demote-safe: no false OTA promise.
    func testLinkNonLiteralTitleIsNotLifted() throws {
        let source = """
        import SwiftUI
        struct Screen: View {
            var linkTitle: String
            var url: URL
            var body: some View {
                VStack {
                    Text("Header")
                    Link(linkTitle, destination: url)
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: source)
        let screen = lowered.first { $0.viewName == "Screen" }!
        // No parameterized leaf: the title is not a string literal.
        let paramLeaves = screen.opaqueLeaves.filter { !$0.stringArgs.isEmpty }
        XCTAssertTrue(paramLeaves.isEmpty,
            "a non-literal title (variable) must NOT be lifted — it stays baked: "
            + "\(paramLeaves.map { $0.stringArgs })")
    }

    /// WASM render-correctness gate: a `Link` with a non-literal destination falls back
    /// to an opaque slot that carries the TITLE in `slotArgs`. The compiled WASM module
    /// emits `slotArgs[id] = ["<title>"]`; editing the title changes the VALUE but keeps
    /// the id STABLE (no structural change → slot is still resolved on-device).
    func testLinkTitleLiftedSlotArgRidesWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__Screen", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping Link title-lift WASM run")

        func build(_ title: String) throws -> (slotArgs: [String: [String]], opaqueIDs: [String]) {
            let source = """
            import SwiftUI
            struct Screen: View {
                var url: URL
                var body: some View {
                    VStack {
                        Text("Header")
                        Link("\(title)", destination: url)
                    }
                }
            }
            """
            let module = try compileSlotModule(source: source, into: "linktitle-\(title)")
            let wasm = [UInt8](try Data(contentsOf: module))
            let runner = try Runner(wasm: wasm)
            let out = try runner.callPacked("view_body__Screen", [])
            let emission = try JSONDecoder().decode(BodyEmission.self, from: Data(out))
            let ids = collectOpaqueIDs(emission.root)
            return (emission.slotArgs ?? [:], ids)
        }

        let a = try build("Open Site")
        XCTAssertEqual(a.slotArgs.count, 1, "one parameterized Link slot: \(a.slotArgs)")
        let id = try XCTUnwrap(a.slotArgs.keys.first)
        XCTAssertEqual(a.slotArgs[id], ["Open Site"],
                       "slotArgs carries the title literal: \(a.slotArgs)")
        XCTAssertTrue(a.opaqueIDs.contains(id),
                      "tree's opaque id matches slotArgs key: tree=\(a.opaqueIDs) slotArgs=\(id)")

        // Edit the title → the id is UNCHANGED (structural stability); value updated.
        let b = try build("Visit Us")
        let idB = try XCTUnwrap(b.slotArgs.keys.first)
        XCTAssertEqual(id, idB,
            "EDITING the Link title keeps the slot id stable (OTA-patchable): \(id) vs \(idB)")
        XCTAssertEqual(b.slotArgs[idB], ["Visit Us"],
                       "edited title rides WASM in slotArgs: \(b.slotArgs)")
    }

    // MARK: - 5. NESTED opaqueCall lifting (cli 1.6.33)

    /// cli 1.6.33: `opaqueCall` now lifts plain-string args of NESTED custom-view calls
    /// (in trailing/@ViewBuilder closures), not just top-level args. This is the exact
    /// real-app SettingsScreen bug: a `SettingsSection(title: "T") { SettingsRow(label:
    /// "L", sub: "S") { … } }` previously lifted only the section title "T" and BAKED the
    /// nested row's "L"/"S" → editing them gave a FINGERPRINT MISMATCH. Now all three lift.
    func testNestedCustomViewStringArgsAreLifted() throws {
        let source = """
        import SwiftUI
        struct SettingsRow: View {
            let label: String
            var sub: String?
            var action: () -> Void
            var body: some View { Button(action: action) { Text(label) } }
        }
        struct SettingsSection<Content: View>: View {
            let title: String
            @ViewBuilder var content: () -> Content
            var body: some View { VStack { Text(title); content() } }
        }
        struct Screen: View {
            @State private var x = false
            var body: some View {
                SettingsSection(title: "Reminders") {
                    SettingsRow(label: "Notify before window", sub: "Off") { x.toggle() }
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: source, sameFileThunk: true)
        let screen = lowered.first { $0.viewName == "Screen" }!
        let allArgs = Set(screen.opaqueLeaves.flatMap { $0.stringArgs })
        XCTAssertTrue(allArgs.contains("Reminders"),
            "the top-level section title must lift (was already working): \(allArgs)")
        XCTAssertTrue(allArgs.contains("Notify before window"),
            "the NESTED row label must lift (the cli 1.6.33 fix): \(allArgs)")
        XCTAssertTrue(allArgs.contains("Off"),
            "the NESTED row sub must lift (the cli 1.6.33 fix): \(allArgs)")
        // None of the lifted literals appear verbatim in the shipped tree (they ride slotArgs).
        XCTAssertFalse(screen.guestBody.contains("Notify before window"),
            "a lifted nested literal must NOT bake into the tree: \(screen.guestBody.prefix(400))")
    }

    /// RANGE CORRECTNESS (the cli 1.6.28 silent-drop guard, extended to nested lifting):
    /// editing only the NESTED row label via a ProjectFingerprint round-trip must NOT churn
    /// the native-shell fingerprint (the nested literal's byte range is taken from the
    /// ORIGINAL source node, not the offset=0 rewritten tree); a STRUCTURAL edit (renaming
    /// the nested view `SettingsRow`→`SettingsRow2`, which changes the slot template) DOES
    /// churn — proving no silent-drop (a structural change can't ship with a stale fingerprint).
    func testNestedLiftedLabelIsFingerprintStableButStructuralEditChurns() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("patch-nested-opaquecall-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Screen.swift")

        func writeSource(rowName: String, rowLabel: String) throws {
            let src = """
            import SwiftUI
            struct \(rowName): View {
                let label: String
                var sub: String?
                var action: () -> Void
                var body: some View { Button(action: action) { Text(label) } }
            }
            struct SettingsSection<Content: View>: View {
                let title: String
                @ViewBuilder var content: () -> Content
                var body: some View { VStack { Text(title); content() } }
            }
            struct Screen: View {
                @State private var x = false
                var body: some View {
                    SettingsSection(title: "Reminders") {
                        \(rowName)(label: "\(rowLabel)", sub: "Off") { x.toggle() }
                    }
                }
            }
            """
            try src.write(to: file, atomically: true, encoding: .utf8)
        }

        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }

        // Sanity: confirm the nested label actually lifts (else the test is vacuous).
        try writeSource(rowName: "SettingsRow", rowLabel: "Notify before window")
        let preLower = BodyLowering().lowerAllViews(
            source: try String(contentsOf: file, encoding: .utf8), sameFileThunk: true)
        let screen0 = preLower.first { $0.viewName == "Screen" }
        try XCTSkipUnless(
            screen0?.opaqueLeaves.contains(where: { $0.stringArgs.contains("Notify before window") }) == true,
            "nested row label did not lift in this engine build — skip")

        let base = fp()

        // PART 1 — editing ONLY the nested lifted label must NOT churn (the OTA fix).
        try writeSource(rowName: "SettingsRow", rowLabel: "Notify before posting")
        XCTAssertEqual(fp(), base,
            "editing only the NESTED row label must NOT churn the native-shell fingerprint "
            + "(it rides WASM via slotArgs; range correctness from the original source node)")

        // Restore → fingerprint returns to base (deterministic).
        try writeSource(rowName: "SettingsRow", rowLabel: "Notify before window")
        XCTAssertEqual(fp(), base, "restoring the label must restore the fingerprint")

        // PART 2 — a STRUCTURAL edit (rename the nested custom view) MUST churn.
        // The slot template embeds `SettingsRow(...)`; renaming it to `SettingsRow2(...)`
        // changes the native reconstruction → the slot id + native surface must differ.
        try writeSource(rowName: "SettingsRow2", rowLabel: "Notify before window")
        XCTAssertNotEqual(fp(), base,
            "renaming the nested custom view (SettingsRow→SettingsRow2) is a STRUCTURAL change "
            + "and MUST churn the fingerprint — no silent-drop")
    }

    /// SAFETY: a NESTED interpolation whose dynamic part is a body-local stays FULLY BAKED
    /// (no lift) — the nested-lift extension must preserve the lifter's interpolation safety
    /// rule (a non-slotable `\(expr)` keeps the whole string native). The static segment of
    /// `"Hi \(n)"` (where `n` is a body-local `let`) must NOT ride WASM. A sibling PLAIN
    /// nested literal in the SAME slot ("Tap") still lifts — proving the safety rule is
    /// per-string, not all-or-nothing for the whole slot.
    func testNestedInterpolationWithBodyLocalDynamicStaysBaked() throws {
        let source = """
        import SwiftUI
        struct Row: View {
            let label: String
            var hint: String
            var body: some View { VStack { Text(label); Text(hint) } }
        }
        struct Section2<Content: View>: View {
            let title: String
            @ViewBuilder var content: () -> Content
            var body: some View { VStack { Text(title); content() } }
        }
        struct Screen: View {
            var n: String
            var body: some View {
                Section2(title: "Header") {
                    Row(label: "Hi \\(n)", hint: "Tap")
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: source, sameFileThunk: true)
        let screen = lowered.first { $0.viewName == "Screen" }!
        let allArgs = screen.opaqueLeaves.flatMap { $0.stringArgs }
        // P0-B: the interpolated `"Hi \(n)"` must NOT lift regardless of slotability — the
        // makeInterpolatedReplacement path would render "a[0]Alice" (literal) instead of "Hi Alice".
        // Only PLAIN (non-interpolated) args like "Tap" (hint) and "Header" (title) lift.
        XCTAssertTrue(allArgs.contains("Tap"),
            "a plain NESTED string arg ('Tap') must lift even alongside an interpolation: \(allArgs)")
        XCTAssertTrue(allArgs.contains("Header"),
            "the top-level title still lifts: \(allArgs)")
        XCTAssertFalse(allArgs.contains("Hi "),
            "P0-B: the interpolated static segment 'Hi ' must NOT lift — would render 'a[0]Alice': \(allArgs)")

        // Now the NON-slotable case: a nested interpolation referencing a BODY-LOCAL `let`.
        let source2 = """
        import SwiftUI
        struct Row: View { let label: String; var body: some View { Text(label) } }
        struct Section2<Content: View>: View {
            let title: String
            @ViewBuilder var content: () -> Content
            var body: some View { VStack { Text(title); content() } }
        }
        struct Screen: View {
            var body: some View {
                let secret = String(describing: 42)
                return Section2(title: "Header") {
                    Row(label: "Hi \\(secret)")
                }
            }
        }
        """
        let lowered2 = BodyLowering().lowerAllViews(source: source2, sameFileThunk: true)
        let screen2 = lowered2.first { $0.viewName == "Screen" }!
        let allArgs2 = screen2.opaqueLeaves.flatMap { $0.stringArgs }
        XCTAssertFalse(allArgs2.contains("Hi "),
            "a nested interpolation with a body-local dynamic must NOT lift its static segment: \(allArgs2)")
    }

    // MARK: - Helpers (mirror SwiftUIRichInputMarshalTests)

    private func collectOpaqueIDs(_ node: ViewNode) -> [String] {
        var out: [String] = []
        func walk(_ n: ViewNode) {
            if case .opaque(let id, _) = n.kind { out.append(id) }
            for c in n.childNodes { walk(c) }
        }
        walk(node)
        return out
    }

    private func compileSlotModule(source: String, into label: String) throws -> URL {
        let lowering = BodyLowering()
        let lowered = lowering.lowerAllViews(source: source)
        let guestViews = lowered
            .filter { !$0.referencesUnmarshalledInput }
            .map { lv -> SwiftUIGuestEmitter.GuestView in
                var slotArgs: [String: [String]] = [:]
                for leaf in lv.opaqueLeaves where !leaf.stringArgs.isEmpty {
                    slotArgs[leaf.id] = leaf.stringArgs
                }
                return SwiftUIGuestEmitter.GuestView(
                    viewName: lv.viewName, guestBody: lv.guestBody, inputs: lv.inputs,
                    stateModel: lv.stateModel, slotArgs: slotArgs)
            }
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
            let ptr: UInt32
            if input.isEmpty {
                ptr = try malloc([.i32(1)])[0].i32
            } else {
                ptr = try malloc([.i32(UInt32(input.count))])[0].i32
                let mem = try memory()
                mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: input.count) { raw in
                    raw.copyBytes(from: input)
                }
            }
            let packed = try fn([.i32(ptr), .i32(UInt32(input.count))])[0].i64
            let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
            let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
            let all = try memory().data
            return [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
        }
    }
}
