// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator
import PartitioningEngine
import SwiftParser
import SwiftSyntax

/// Tests the build-time view-patching codegen: `dynamic` insertion + thunk
/// generation, including the real-app skip-list (Scene/Commands, `#if`, generic
/// `where`, duplicate names) and the lock-step rule (a thunk only for a body we
/// actually made `dynamic`).
final class ThunkGeneratorTests: XCTestCase {
    // These tests validate the LEGACY separate-file thunk rendering (one
    // `PatchThunks.generated.swift`, `r.thunkFileContents`), which is still a supported
    // mode (`PATCH_SAMEFILE_THUNK=0` / `prepare(sources:sameFile:false)`). The default
    // mode is now SAME-FILE (the thunks are appended to each view's own file); see
    // `ThunkGeneratorSameFileTests` for that path.
    private func run(_ files: [String: String]) -> ThunkGenerator.Result {
        let sources = files.map { ThunkGenerator.SourceFile(url: URL(fileURLWithPath: "/x/\($0.key)"), text: $0.value) }
        return ThunkGenerator().prepare(sources: sources, sameFile: false)
    }
    private func newText(_ r: ThunkGenerator.Result) -> String {
        r.modifiedFiles.first?.text ?? ""
    }

    func testSimpleViewGetsDynamicAndThunk() {
        let r = run(["A.swift": """
        import SwiftUI
        struct Hello: View {
            var body: some View { Text("hi") }
        }
        """])
        XCTAssertEqual(r.viewNames, ["Hello"])
        XCTAssertEqual(r.dynamicInsertions, 1)
        XCTAssertTrue(newText(r).contains("dynamic var body: some View"), newText(r))
        XCTAssertTrue(r.thunkFileContents.contains("@_dynamicReplacement(for: body)"))
        XCTAssertTrue(r.thunkFileContents.contains(#"typeName: "Hello""#))
        XCTAssertTrue(r.thunkFileContents.contains("Patch.shared.thunkBody("))
        XCTAssertTrue(r.thunkFileContents.contains("slots: { self.__patchSlots() }"))
        // A fully-lowered view has no leaves → empty slot map. The slot ABI is a
        // FACTORY (`([String]) -> AnyView`) so parameterized native slots can ride
        // the lifted string-literal values from the emission's `slotArgs`.
        XCTAssertTrue(r.thunkFileContents.contains("func __patchSlots() -> [String: ([String]) -> AnyView]"))
    }

    func testMixedViewEmitsNativeSlot() {
        // A body referencing a CUSTOM child view (a self-contained native leaf)
        // becomes a slotable opaque leaf → the thunk renders it via a slot closure.
        let r = run(["A.swift": """
        import SwiftUI
        struct Card: View { var body: some View { Text("card") } }
        struct Screen: View {
            var title: String = "Hi"
            var body: some View {
                VStack {
                    Text(title)
                    Card()
                }
            }
        }
        """])
        XCTAssertTrue(r.viewNames.contains("Screen"))
        // Screen's slot map renders Card() natively. Card() has no string-literal
        // args, so it's a PLAIN factory that ignores its args.
        XCTAssertTrue(r.thunkFileContents.contains("{ (_: [String]) in AnyView(Card()) }"),
                      "expected a native slot closure for Card(): \(r.thunkFileContents)")
    }

    func testNonSlotableLeafGetsNoSlotClosure() {
        // A leaf referencing a body-LOCAL (a ForEach element) can't be rendered from
        // a self-only slot closure → it is NOT slotted (the view falls back native).
        let r = run(["A.swift": """
        import SwiftUI
        struct Row: View { var label: String; var body: some View { Text(label) } }
        struct ListScreen: View {
            var items: [String] = []
            var body: some View {
                VStack {
                    ForEach(items, id: \\.self) { item in
                        Row(label: item)
                    }
                }
            }
        }
        """])
        // `Row(label: item)` references the ForEach local `item` → not slotable →
        // no `Row(label: item)` slot closure emitted.
        XCTAssertFalse(r.thunkFileContents.contains("AnyView(Row(label: item))"),
                       "a leaf referencing a body-local must not be slotted")
    }

    func testAccessModifierPreserved() {
        let r = run(["A.swift": """
        import SwiftUI
        struct V: View {
            public var body: some View { Text("x") }
        }
        """])
        XCTAssertTrue(newText(r).contains("public dynamic var body"), newText(r))
    }

    func testPriorLineAttributePreserved() {
        let r = run(["A.swift": """
        import SwiftUI
        struct V: View {
            @ViewBuilder
            var body: some View { Text("x") }
        }
        """])
        // `dynamic` is inserted before `var`, after the attribute line.
        XCTAssertTrue(newText(r).contains("@ViewBuilder\n    dynamic var body"), newText(r))
    }

    func testSkipsSceneAndCommands() {
        let r = run(["A.swift": """
        import SwiftUI
        @main struct App1: App {
            var body: some Scene { WindowGroup { Text("x") } }
        }
        struct Cmds: Commands {
            var body: some Commands { EmptyCommands() }
        }
        """])
        XCTAssertEqual(r.dynamicInsertions, 0)
        XCTAssertTrue(r.viewNames.isEmpty)
    }

    func testSkipsBodyInsideIfConfig() {
        let r = run(["A.swift": """
        import SwiftUI
        struct V: View {
            #if os(iOS)
            var body: some View { Text("ios") }
            #else
            var body: some View { Text("other") }
            #endif
        }
        """])
        // Bodies inside #if are config-dependent — never touched, no thunk.
        XCTAssertEqual(r.dynamicInsertions, 0)
        XCTAssertFalse(r.thunkFileContents.contains("extension V "))
    }

    func testSkipsDuplicateNames() {
        let r = run([
            "A.swift": "import SwiftUI\nstruct Dup: View { var body: some View { Text(\"a\") } }",
            "B.swift": "import SwiftUI\nstruct Dup: View { var body: some View { Text(\"b\") } }",
        ])
        // Two top-level `struct Dup` → ambiguous `extension Dup` → skip entirely.
        XCTAssertFalse(r.viewNames.contains("Dup"))
        XCTAssertEqual(r.dynamicInsertions, 0)
    }

    func testSkipsGenericWhereClause() {
        let r = run(["A.swift": """
        import SwiftUI
        struct G<T>: View where T: CustomStringConvertible {
            let v: T
            var body: some View { Text("x") }
        }
        """])
        XCTAssertFalse(r.viewNames.contains("G"))
        XCTAssertEqual(r.dynamicInsertions, 0)
    }

    func testGenericWithoutWhereIsThunked() {
        let r = run(["A.swift": """
        import SwiftUI
        struct Row<T: CustomStringConvertible>: View {
            let item: T
            var body: some View { Text("x") }
        }
        """])
        XCTAssertEqual(r.viewNames, ["Row"])
        XCTAssertTrue(newText(r).contains("dynamic var body"))
        XCTAssertTrue(r.thunkFileContents.contains("extension Row {"))
    }

    func testIdempotentOnAlreadyDynamic() {
        let r = run(["A.swift": """
        import SwiftUI
        struct V: View {
            dynamic var body: some View { Text("x") }
        }
        """])
        XCTAssertEqual(r.dynamicInsertions, 0, "should not re-insert dynamic")
        XCTAssertTrue(r.modifiedFiles.isEmpty)
        // But still gets a thunk (lock-step: body is dynamic).
        XCTAssertEqual(r.viewNames, ["V"])
        XCTAssertTrue(r.thunkFileContents.contains("extension V {"))
    }

    func testBodyInPlainExtension() {
        let r = run(["A.swift": """
        import SwiftUI
        struct Profile: View {
            let name: String
        }
        extension Profile {
            var body: some View { Text(name) }
        }
        """])
        XCTAssertEqual(r.viewNames, ["Profile"])
        XCTAssertEqual(r.dynamicInsertions, 1)
        XCTAssertTrue(newText(r).contains("dynamic var body"))
    }

    func testExtensionDeclaredConformance() {
        let r = run(["A.swift": """
        import SwiftUI
        struct Widget1 {
            let title: String
        }
        extension Widget1: View {
            var body: some View { Text(title) }
        }
        """])
        XCTAssertEqual(r.viewNames, ["Widget1"])
        XCTAssertEqual(r.dynamicInsertions, 1)
    }

    func testMultipleViewsAcrossFiles() {
        let r = run([
            "A.swift": "import SwiftUI\nstruct A: View { var body: some View { Text(\"a\") } }",
            "B.swift": "import SwiftUI\nstruct B: View { var body: some View { Text(\"b\") } }",
        ])
        XCTAssertEqual(r.viewNames, ["A", "B"])
        XCTAssertEqual(r.dynamicInsertions, 2)
        XCTAssertEqual(r.modifiedFiles.count, 2)
    }

    func testThunkFileStructure() {
        let r = run(["A.swift": "import SwiftUI\nstruct V: View { var body: some View { Text(\"x\") } }"])
        let t = r.thunkFileContents
        XCTAssertTrue(t.contains("#if canImport(SwiftUI)"))
        XCTAssertTrue(t.contains("import PatchSwiftUI"))
        XCTAssertTrue(t.contains("@MainActor @ViewBuilder"))
        XCTAssertTrue(t.contains("} else {"))
        XCTAssertTrue(t.contains("body"))
        XCTAssertTrue(t.hasSuffix("#endif\n"))
    }

    /// A view using a design-system NUMERIC token (`Theme.Radius.lg` in a
    /// `.cornerRadius(…)`) gets a `__patchTokens()` that resolves it as a
    /// `.number(Double(Theme.Radius.lg))` keyed by the SAME id the shipped tree carries
    /// — so the SDK injects the resolved Double into the guest's input JSON. The id must
    /// match between the engine (push) and the thunk (build).
    func testNumericTokenThunkEmitsNumberCaseWithMatchingID() {
        let src = """
        import SwiftUI
        enum Theme { enum Radius { static let lg: CGFloat = 20 } }
        struct Chip: View {
            let label: String
            var body: some View { Text(label).cornerRadius(Theme.Radius.lg) }
        }
        """
        // Engine side: the numeric token id the shipped tree carries.
        let lowered = BodyLowering().lowerAllViews(source: src).first { $0.viewName == "Chip" }
        let numToken = (lowered?.hostTokens ?? []).first { $0.kind == .number }
        let id = numToken?.id ?? ""
        XCTAssertFalse(id.isEmpty, "engine should record a numeric token")
        // Thunk side: the generated `__patchTokens()` resolves it as `.number(Double(…))`.
        let r = run(["A.swift": src])
        let t = r.thunkFileContents
        XCTAssertTrue(t.contains("func __patchTokens() -> [String: PatchHostToken]"),
                      "the thunk exposes __patchTokens(): \(t)")
        XCTAssertTrue(t.contains("__t[\"\(id)\"] = .number(Double(Theme.Radius.lg))"),
                      "the thunk resolves the numeric token by the engine's id: \(t)")
    }

    func testEngineAndThunkAgreeOnOpaqueLeafIDs() {
        // The linchpin of mixed views: the opaque-leaf ids the ENGINE bakes into the
        // shipped tree must equal the ids the THUNK generator keys its native slot
        // closures by — both derive from `BodyLowering` over the same source, so
        // they agree. (If they didn't, the SDK's coverage check would demote every
        // mixed view to native.)
        let src = """
        import SwiftUI
        struct Card: View { var body: some View { Text("c") } }
        struct Screen: View {
            var body: some View {
                VStack {
                    Text("t")
                    Card()
                    Color(red: 0.1, green: 0.2, blue: 0.3)
                }
            }
        }
        """
        // Engine side: the opaque leaves the shipped tree carries.
        let lowered = BodyLowering().lowerAllViews(source: src).first { $0.viewName == "Screen" }
        let engineLeafIDs = Set((lowered?.opaqueLeaves ?? []).filter { $0.slotable }.map(\.id))
        XCTAssertFalse(engineLeafIDs.isEmpty, "expected slotable opaque leaves (Card, Color)")

        // Thunk side: every engine leaf id appears as a slot key in the generated file.
        let r = run(["A.swift": src])
        for id in engineLeafIDs {
            XCTAssertTrue(r.thunkFileContents.contains("__s[\"\(id)\"]"),
                          "thunk file is missing a slot for engine leaf id \(id)")
        }
        // And Screen is thunk-eligible (all leaves slotable).
        XCTAssertTrue(r.viewNames.contains("Screen"))
    }

    func testContentlessContainerHasNoLoweredContentNode() {
        // The #1 fix: a pure routing/layout shell (Group/if-else over child views,
        // no Text/Image/control of its own) has NO lowered content node, so
        // BuildPipeline won't mark it thunkSafe → it stays native (not blanked).
        let routingShell = BodyLowering().analyze(source: """
        import SwiftUI
        struct ContentView: View {
            var body: some View { Group { if true { ChildA() } else { ChildB() } } }
        }
        """)
        XCTAssertNotNil(routingShell)
        XCTAssertFalse(routingShell!.hasLoweredContentNode,
                       "a container-only shell must have no lowered content node")

        // A view with real content (Text) does.
        let realView = BodyLowering().analyze(source: """
        import SwiftUI
        struct Banner: View { var body: some View { VStack { Text("hi") } } }
        """)
        XCTAssertTrue(realView!.hasLoweredContentNode)
    }

    func testPrivateStateLeafIsNotSlotted() {
        // An unsupported modifier (`.padding(.horizontal,16)`) slots the whole node,
        // but it wraps a Toggle bound to a PRIVATE @State (`$on`). The cross-file
        // thunk can't access `$on`, so this leaf must NOT be slotted — else
        // PatchThunks.generated.swift fails to compile ('$on' is inaccessible).
        let r = run(["A.swift": """
        import SwiftUI
        struct Screen: View {
            @State private var on = true
            var body: some View {
                VStack {
                    Text("hi")
                    HStack { Toggle(isOn: $on) { Text("") } }.padding(.horizontal, 16)
                }
            }
        }
        """])
        XCTAssertFalse(r.thunkFileContents.contains("$on"),
                       "must not emit a slot closure referencing the private $on:\n\(r.thunkFileContents)")
    }

    func testBuildArtifactPathsExcludedFromDiscovery() {
        // The fix for the hang: project-discovery walks skip build-tool output that
        // lives in the project tree (DerivedData / resolved SwiftPM deps / Pods).
        XCTAssertTrue(SwiftParserEngine.isBuildArtifactPath(
            "/proj/deriveddata/sourcepackages/checkouts/wasmkit/sources/foo.swift"))
        XCTAssertTrue(SwiftParserEngine.isBuildArtifactPath("/proj/pods/lib/a.swift"))
        XCTAssertTrue(SwiftParserEngine.isBuildArtifactPath("/x/carthage/build/y.swift"))
        XCTAssertFalse(SwiftParserEngine.isBuildArtifactPath("/proj/sources/myapp/contentview.swift"))
    }

    func testCollectsThirdPartyImports() {
        // A view file importing a third-party module → the thunk file carries that
        // import (guarded) so a slot closure referencing its types compiles.
        let r = run(["A.swift": """
        import SwiftUI
        import Charts
        struct V: View { var body: some View { Text("x") } }
        """])
        XCTAssertTrue(r.thunkFileContents.contains("#if canImport(Charts)"), r.thunkFileContents)
        XCTAssertTrue(r.thunkFileContents.contains("import Charts"))
    }

    // MARK: - Bug R2-#89: scoped + submodule imports must be carried

    /// `collectImports` must carry the MODULE of a SCOPED import (`import struct
    /// DesignKit.Brand`) and of a SUBMODULE import (`import os.log`). Before the fix it
    /// dropped both (skipping `importKindSpecifier != nil` and any `.`-containing path), so a
    /// slot/token source referencing `Brand`/`OSLog` failed to compile in the separate
    /// generated file (`cannot find 'Brand' in scope`).
    func testCollectImportsCarriesScopedAndSubmoduleModules() {
        let src = """
        import SwiftUI
        import struct DesignKit.Brand
        import os.log
        struct V: View { var body: some View { Text("x") } }
        """
        let tree = SwiftParser.Parser.parse(source: src)
        let imports = ThunkGenerator.collectImports([tree])
        XCTAssertTrue(imports.contains("DesignKit"),
                      "the scoped import's MODULE must be carried: \(imports)")
        XCTAssertTrue(imports.contains("os.log"),
                      "the submodule import must be carried verbatim: \(imports)")
        // The always-imported set is still excluded; an `@_exported`/`@testable` import is skipped.
        XCTAssertFalse(imports.contains("SwiftUI"), imports.description)
    }

    /// The carried scoped/submodule imports reach the generated thunk file (guarded).
    func testScopedAndSubmoduleImportsReachThunkFile() {
        let r = run(["A.swift": """
        import SwiftUI
        import struct DesignKit.Brand
        import os.log
        struct V: View { var body: some View { Text("x") } }
        """])
        XCTAssertTrue(r.thunkFileContents.contains("#if canImport(DesignKit)"), r.thunkFileContents)
        XCTAssertTrue(r.thunkFileContents.contains("import DesignKit"), r.thunkFileContents)
        XCTAssertTrue(r.thunkFileContents.contains("#if canImport(os.log)"), r.thunkFileContents)
        XCTAssertTrue(r.thunkFileContents.contains("import os.log"), r.thunkFileContents)
        XCTAssertTrue(ThunkGenerator.parses(r.thunkFileContents), r.thunkFileContents)
    }

    /// An `@_exported`/`@testable`-attributed import is still skipped (its semantics don't
    /// survive a re-emit and it isn't needed for type lookup).
    func testAttributedImportsStillSkipped() {
        let src = """
        @testable import MyLib
        @_exported import OtherLib
        import SwiftUI
        struct V: View { var body: some View { Text("x") } }
        """
        let tree = SwiftParser.Parser.parse(source: src)
        let imports = ThunkGenerator.collectImports([tree])
        XCTAssertFalse(imports.contains("MyLib"), imports.description)
        XCTAssertFalse(imports.contains("OtherLib"), imports.description)
    }
}
