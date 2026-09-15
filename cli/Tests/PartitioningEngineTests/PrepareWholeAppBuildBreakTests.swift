// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
@testable import Compiler
import SwiftParser

/// Regression nets for the build-breaking classes found by running the REAL `patchcli
/// prepare` over whole real apps and rebuilding them with xcodebuild
/// (`tools/prepare-build-sweep.sh`). Unlike `SwiftUIThunkCompileTests` (one same-file view at a
/// time) these run the default HYBRID placement over MULTI-FILE fixtures and type-check the
/// developer's modified files TOGETHER WITH the generated thunk file — the generated file listed
/// FIRST, the compile order that surfaced the associated-type-inference break — against the
/// iOS simulator SDK with the `SwiftUIThunkCompileTests.hostStub` Patch surface.
///
/// Classes covered (each was a real app that compiled before prepare and not after):
///   1. `@available(iOS 17, *) struct V: View` — generated extensions lacked the availability.
///   2. A custom view param typed `LocalizedStringKey` fed a lifted `a[k]` (`String`).
///   3. A `private` member declared inside `#if os(iOS)` read by a slot → wrongly separate-file.
///   4. The same-file block imported every module of the PROJECT into the developer's file.
///   5. `.background(.quaternary)` / `tint.gradient` / `Text(…).font(…)` as a color token
///      (`.color(…)`) or a view-child slot (`AnyView(.quaternary)`).
///   6. The Xcode widget template (`var entry: Provider.Entry`) — any cross-file extension of
///      the view trips `reference to invalid associated type 'Entry'` in the developer's file.
///   7. Views outside the build target (widget/macOS target, local package, file not in the
///      project) — thunked into a target that can't see them (`XcodeTargetSources`).
final class PrepareWholeAppBuildBreakTests: XCTestCase {

    private struct Outcome {
        var log: String
        var result: ThunkGenerator.Result
        var files: [String: String]      // file name → final text (modified or original)
        var generated: String
        var compiled: Bool { !log.contains("error:") }
    }

    /// Hybrid-prepare `sources` (name → text), then type-check every resulting file plus the
    /// generated thunk file (first) plus the host stub. nil when no iOS simulator SDK.
    private func prepareAndTypecheck(_ sources: [(String, String)],
                                     target: String = "arm64-apple-ios16.0-simulator",
                                     thunkable: Set<String>? = nil) throws -> Outcome? {
        let sdk = SwiftUIThunkCompileTests.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sdk, !sdk.isEmpty else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whole-app-break-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputs = sources.map { ThunkGenerator.SourceFile(url: dir.appendingPathComponent($0.0), text: $0.1) }
        let thunkablePaths = thunkable.map { Set($0.map { dir.appendingPathComponent($0).path }) }
        let result = ThunkGenerator().prepare(sources: inputs, hybrid: true, thunkableFiles: thunkablePaths)

        func strip(_ s: String) -> String {
            s.replacingOccurrences(of: "import PatchSDK\n", with: "")
                .replacingOccurrences(of: "import PatchSwiftUI\n", with: "")
                .replacingOccurrences(of: "import PatchRender\n", with: "")
        }
        var files: [String: String] = [:]
        var paths: [String] = []
        let genURL = dir.appendingPathComponent("AAA_PatchThunks.generated.swift")
        try strip(result.generatedFileContents).write(to: genURL, atomically: true, encoding: .utf8)
        paths.append(genURL.path)
        for src in inputs {
            let text = result.modifiedFiles.first { $0.url == src.url }?.text ?? src.text
            files[src.url.lastPathComponent] = text
            try strip(text).write(to: src.url, atomically: true, encoding: .utf8)
            paths.append(src.url.path)
        }
        let stub = dir.appendingPathComponent("ZZZ_HostStub.swift")
        try SwiftUIThunkCompileTests.hostStub.write(to: stub, atomically: true, encoding: .utf8)
        paths.append(stub.path)
        let log = SwiftUIThunkCompileTests.run("/usr/bin/swiftc",
                                               ["-typecheck", "-sdk", sdk, "-target", target] + paths,
                                               captureStderr: true) ?? ""
        return Outcome(log: log, result: result, files: files, generated: result.generatedFileContents)
    }

    // MARK: 1. @available views

    func testAvailableViewExtensionsCarryAvailability() throws {
        guard let o = try prepareAndTypecheck([("Views.swift", """
        import SwiftUI
        import Observation

        @available(iOS 17.0, *)
        @Observable final class Model { var title = "hi" }

        @available(iOS 17.0, *)
        struct AvailView: View {
            var model: Model
            var body: some View { VStack { Text(model.title); Text("static") } }
        }
        """)]) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(o.result.viewNames.contains("AvailView"), "the view still gets a thunk")
        XCTAssertTrue(o.generated.contains("@available(iOS 17.0, *)\nextension AvailView {"), o.generated)
        XCTAssertTrue(o.compiled, "an @available view's generated thunk must compile below its availability:\n\(o.log)")
    }

    // MARK: 2. LocalizedStringKey custom params

    func testLiftedLiteralIntoLocalizedStringKeyParamCompiles() throws {
        guard let o = try prepareAndTypecheck([("Views.swift", """
        import SwiftUI

        struct SearchField: View {
            @Binding var searchText: String
            var placeholder: LocalizedStringKey = "Search..."
            var body: some View { TextField(placeholder, text: $searchText) }
        }
        struct SectionHeaderView: View {
            let text: LocalizedStringKey
            var body: some View { Text(text).font(.headline) }
        }
        struct TitleRow<S: StringProtocol>: View {
            let title: S
            var body: some View { Text(title) }
        }
        struct ListScreen: View {
            @State var searchText = ""
            var body: some View {
                List {
                    Section(header: SectionHeaderView(text: "Villagers")) {
                        SearchField(searchText: $searchText, placeholder: "Search villagers")
                        TitleRow(title: "Generic")
                        Image(systemName: "star")
                    }
                }
            }
        }
        """)]) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(o.generated.contains("placeholder: __patchLit(a[0])"),
                      "the custom-view literal is still lifted (OTA-editable):\n\(o.generated)")
        XCTAssertTrue(o.compiled, "a lifted literal into a LocalizedStringKey param must compile:\n\(o.log)")
    }

    func testRenderParameterizedTemplateOnlyWrapsBarePlaceholders() {
        let t = "Foo(a: \u{1}0\u{1}, b: LocalizedStringKey(\u{1}1\u{1}), c: \"x\\(\u{1}2\u{1})\")"
        let out = ThunkGenerator.renderParameterizedTemplate(t, argCount: 3)
        XCTAssertEqual(out, "Foo(a: __patchLit(a[0]), b: LocalizedStringKey(a[1]), c: \"x\\(__patchLit(a[2]))\")")
        // A placeholder INSIDE a string literal is left as the historical `a[k]`.
        XCTAssertEqual(ThunkGenerator.renderParameterizedTemplate("Foo(\"\u{1}0\u{1}\")", argCount: 1),
                       "Foo(\"a[0]\")")
    }

    // MARK: 3. #if-wrapped private members

    func testIfConfigPrivateMemberForcesSameFilePlacement() throws {
        guard let o = try prepareAndTypecheck([("StoreSupportView.swift", """
        import SwiftUI

        extension View {
            func mySheet(isPresented: Binding<Bool>) -> some View { sheet(isPresented: isPresented) { Text("s") } }
        }

        struct StoreSupportView: View {
            #if os(iOS)
            @State private var manageSheetPresented = false
            #endif
            var body: some View {
                List {
                    #if os(iOS)
                    Button("Manage subscription") { manageSheetPresented = true }
                        .mySheet(isPresented: $manageSheetPresented)
                    #endif
                    Button("Restore") { }
                }
            }
        }
        """)]) else { throw XCTSkip("no iphonesimulator SDK") }
        if case .separateFile? = o.result.placements["StoreSupportView"],
           o.generated.contains("manageSheetPresented") {
            XCTFail("a slot reading a #if-wrapped private member must not be placed separate-file:\n\(o.generated)")
        }
        XCTAssertTrue(o.compiled, "the thunk reading a #if-wrapped private member must compile:\n\(o.log)")
    }

    // MARK: 4. same-file block imports

    func testSameFileBlockCarriesOnlyItsOwnFilesImports() throws {
        guard let o = try prepareAndTypecheck([
            ("Other.swift", """
            import SwiftUI
            import Combine
            import MapKit
            struct Other: View { var body: some View { Text("o") } }
            """),
            ("Private.swift", """
            import SwiftUI
            extension View {
                func mySheet(isPresented: Binding<Bool>) -> some View { sheet(isPresented: isPresented) { Text("s") } }
            }
            struct PrivateReader: View {
                #if os(iOS)
                @State private var presented = false
                #endif
                var body: some View {
                    List {
                        #if os(iOS)
                        Button("Manage") { presented = true }
                            .mySheet(isPresented: $presented)
                        #endif
                    }
                }
            }
            """),
        ]) else { throw XCTSkip("no iphonesimulator SDK") }
        let text = o.files["Private.swift"] ?? ""
        guard text.contains(ThunkGenerator.sameFileBeginMarker) else {
            throw XCTSkip("fixture no longer needs a same-file block")
        }
        XCTAssertFalse(text.contains("import Combine"),
                       "a same-file block must not inject another file's imports into this file:\n\(text)")
        XCTAssertFalse(text.contains("import MapKit"), text)
        XCTAssertTrue(o.compiled, o.log)
    }

    // MARK: 5. non-Color ShapeStyles

    func testNonColorShapeStylesAreNeitherColorTokensNorViewSlots() throws {
        guard let o = try prepareAndTypecheck([("Tile.swift", """
        import SwiftUI
        struct Tile: View {
            var tint: Color
            var body: some View {
                VStack {
                    Text("A").padding().background(.quaternary)
                    Text("B").padding().background(.quaternary.opacity(0.5))
                    Text("C").padding().background(tint.gradient)
                    Text("D").padding().background(Text("Continue").font(.title2).foregroundColor(.white))
                    Text("E").padding().background(Color.gray.opacity(0.1))
                }
            }
        }
        """)], target: "arm64-apple-ios17.0-simulator") else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertFalse(o.generated.contains(".color(.quaternary"), o.generated)
        XCTAssertFalse(o.generated.contains(".color(tint.gradient"), o.generated)
        XCTAssertFalse(o.generated.contains(".color(Text("), o.generated)
        XCTAssertFalse(o.generated.contains("AnyView(.quaternary"), o.generated)
        XCTAssertTrue(o.generated.contains(".color(Color.gray.opacity(0.1))"),
                      "a real Color token still lowers:\n\(o.generated)")
        XCTAssertTrue(o.compiled, o.log)
    }

    func testProvablyNotColorPredicateKeepsDesignTokens() {
        func probe(_ src: String) -> Bool {
            let tree = Parser.parse(source: "let x = \(src)")
            let expr = Emitter.tokenProbeValueExpr(tree)!
            return Emitter.tokenExprIsProvablyNotColorOrFont(expr, kind: .color)
        }
        XCTAssertTrue(probe(".quaternary"))
        XCTAssertTrue(probe(".tertiary.opacity(0.5)"))
        XCTAssertTrue(probe("model.color.gradient"))
        XCTAssertTrue(probe("Text(\"x\").font(.title2)"))
        XCTAssertTrue(probe("WebImage(url: u).resizable()"))
        // Design-system tokens that merely share a modifier/style name keep lowering.
        XCTAssertFalse(probe("Theme.tint"))
        XCTAssertFalse(probe(".background"))
        XCTAssertFalse(probe("Theme.Colors.accent.opacity(0.4)"))
        XCTAssertFalse(probe("Color(.systemBackground)"))
        XCTAssertFalse(probe("palette.color(for: kind)"))
        // `Font` has `bold()`/`italic()`/`weight(_:)` — a font token chain keeps lowering.
        func fontProbe(_ src: String) -> Bool {
            let expr = Emitter.tokenProbeValueExpr(Parser.parse(source: "let x = \(src)"))!
            return Emitter.tokenExprIsProvablyNotColorOrFont(expr, kind: .font)
        }
        XCTAssertFalse(fontProbe(".subheadline.bold()"))
        XCTAssertFalse(fontProbe("Theme.Font.body(13).italic()"))
        XCTAssertTrue(fontProbe("Text(\"x\").font(.title)"))
    }

    // MARK: 5b. modifier through optional chaining

    func testModifierThroughOptionalChainingIsSlottedWhole() throws {
        guard let o = try prepareAndTypecheck([("RepositoryView.swift", """
        import SwiftUI
        struct Repository { let name: String; let description: String? }
        struct RepositoryView: View {
            let repository: Repository
            var body: some View {
                VStack(alignment: .leading) {
                    Text(repository.name)
                    repository.description
                        .map(Text.init)?
                        .lineLimit(nil)
                }
            }
        }
        """)]) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertFalse(o.generated.contains("Text.init)?)"), "a dangling `?` must never be slotted alone:\n\(o.generated)")
        XCTAssertTrue(o.compiled, o.log)
    }

    // MARK: 6. widget template associated type

    func testWidgetTemplateEntryViewIsNotThunked() throws {
        guard let o = try prepareAndTypecheck([("NextWateringWidget.swift", """
        import WidgetKit
        import SwiftUI

        struct Provider: TimelineProvider {
            func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: Date(), title: "x") }
            func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
                completion(SimpleEntry(date: Date(), title: "x"))
            }
            func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
                completion(Timeline(entries: [SimpleEntry(date: Date(), title: "x")], policy: .atEnd))
            }
        }
        struct SimpleEntry: TimelineEntry {
            let date: Date
            let title: String
        }
        struct EntryView: View {
            var entry: Provider.Entry
            var body: some View { VStack { Text(entry.title); Text("Next watering") } }
        }
        struct PlainView: View {
            var entry: SimpleEntry
            var body: some View { Text(entry.title) }
        }
        """)], target: "arm64-apple-ios17.0-simulator") else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertFalse(o.result.viewNames.contains("EntryView"), "the Provider.Entry view renders native")
        XCTAssertTrue(o.result.viewNames.contains("PlainView"), "an ordinary view in the same file is still thunked")
        XCTAssertFalse((o.files["NextWateringWidget.swift"] ?? "").contains("dynamic var body: some View { VStack { Text(entry.title)"))
        XCTAssertTrue(o.compiled, o.log)
    }

    /// The build/fingerprint must agree with prepare: a view prepare won't thunk is never
    /// auto-routed (else an edit to it would release "compatible" and never render).
    func testBuildPipelineTreatsEntryViewAsThunkIneligible() {
        let src = """
        import WidgetKit
        import SwiftUI
        struct Provider: TimelineProvider {
            func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: Date()) }
            func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {}
            func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {}
        }
        struct SimpleEntry: TimelineEntry { let date: Date }
        struct EntryView: View { var entry: Provider.Entry; var body: some View { Text("x") } }
        struct Other: View { var body: some View { Text("y") } }
        """
        let ineligible = BuildPipeline.thunkIneligibleViewNames(sources: [src])
        XCTAssertTrue(ineligible.contains("EntryView"))
        XCTAssertFalse(ineligible.contains("Other"))
    }

    func testExplicitTypealiasEntryIsNotFlagged() {
        let tree = Parser.parse(source: """
        struct Provider { typealias Entry = Int; func f(_ e: Entry) {} }
        struct V: View { var entry: Provider.Entry; var body: some View { Text("") } }
        """)
        XCTAssertTrue(ThunkGenerator.inferredAssociatedTypeRiskViews([tree], viewNames: ["V"]).isEmpty)
    }

    // MARK: 7. build-target membership

    func testViewsOutsideTheTargetGetNoThunk() throws {
        guard let o = try prepareAndTypecheck([
            ("AppView.swift", """
            import SwiftUI
            struct AppView: View { var body: some View { Text("app") } }
            """),
            ("WidgetOnlyView.swift", """
            import SwiftUI
            struct WidgetOnlyView: View { var body: some View { Text("widget") } }
            """),
        ], thunkable: ["AppView.swift"]) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertEqual(o.result.viewNames, ["AppView"])
        XCTAssertFalse(o.generated.contains("WidgetOnlyView"), o.generated)
        XCTAssertFalse((o.files["WidgetOnlyView.swift"] ?? "").contains("dynamic"), "no source edit outside the target")
        XCTAssertTrue(o.compiled, o.log)
    }

    func testXcodeTargetSourcesClassicBuildPhase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xts-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("App"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let pbx = """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            objects = {
                B1 /* AppView.swift in Sources */ = {isa = PBXBuildFile; fileRef = F1 /* AppView.swift */; };
                B2 /* Widget.swift in Sources */ = {isa = PBXBuildFile; fileRef = F2 /* Widget.swift */; };
                F1 /* AppView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppView.swift; sourceTree = "<group>"; };
                F2 /* Widget.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Widget.swift; sourceTree = "<group>"; };
                F3 = {isa = PBXFileReference; path = "Shared/Util.swift"; sourceTree = SOURCE_ROOT; };
                B3 = {isa = PBXBuildFile; fileRef = F3; };
                G0 = {isa = PBXGroup; children = ( G1, G2, ); sourceTree = "<group>"; };
                G1 /* App */ = {isa = PBXGroup; children = ( F1, ); path = App; sourceTree = "<group>"; };
                G2 /* Widgets */ = {isa = PBXGroup; children = ( F2, ); name = Widgets; path = "My Widgets"; sourceTree = "<group>"; };
                S1 = {isa = PBXSourcesBuildPhase; files = ( B1 /* AppView.swift in Sources */, B3, ); };
                S2 = {isa = PBXSourcesBuildPhase; files = ( B2, ); };
                T1 /* App */ = {isa = PBXNativeTarget; buildPhases = ( S1, ); name = "My App"; };
                T2 = {isa = PBXNativeTarget; buildPhases = ( S2, ); name = Widgets; };
                P0 = {isa = PBXProject; mainGroup = G0; projectDirPath = ""; targets = ( T1, T2, ); };
            };
            rootObject = P0;
        }
        """
        let files = XcodeTargetSources.swiftFiles(pbxproj: pbx, projectDir: dir, target: "My App", fm: fm)
        XCTAssertEqual(files, [dir.appendingPathComponent("App/AppView.swift").standardizedFileURL.path,
                               dir.appendingPathComponent("Shared/Util.swift").standardizedFileURL.path])
        let widget = XcodeTargetSources.swiftFiles(pbxproj: pbx, projectDir: dir, target: "Widgets", fm: fm)
        XCTAssertEqual(widget, [dir.appendingPathComponent("My Widgets/Widget.swift").standardizedFileURL.path])
        XCTAssertNil(XcodeTargetSources.swiftFiles(pbxproj: pbx, projectDir: dir, target: "Nope", fm: fm))
    }

    func testXcodeTargetSourcesSynchronizedFolderWithExceptions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("xts-sync-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        for rel in ["MyApp/ContentView.swift", "MyApp/Sub/Row.swift", "MyApp/WidgetOnly.swift", "Widget/W.swift"] {
            let url = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "import SwiftUI\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let pbx = """
        {
            objects = {
                R1 /* MyApp */ = {isa = PBXFileSystemSynchronizedRootGroup; exceptions = ( E1 /* exceptions */, ); path = MyApp; sourceTree = "<group>"; };
                R2 /* Widget */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Widget; sourceTree = "<group>"; };
                E1 = {isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = ( WidgetOnly.swift, ); target = T1 /* MyApp */; };
                G0 = {isa = PBXGroup; children = ( R1, R2, ); sourceTree = "<group>"; };
                T1 /* MyApp */ = {isa = PBXNativeTarget; buildPhases = ( ); fileSystemSynchronizedGroups = ( R1 /* MyApp */, ); name = MyApp; };
                T2 = {isa = PBXNativeTarget; buildPhases = ( ); fileSystemSynchronizedGroups = ( R2, ); name = Widget; };
                P0 = {isa = PBXProject; mainGroup = G0; };
            };
            rootObject = P0;
        }
        """
        let files = XcodeTargetSources.swiftFiles(pbxproj: pbx, projectDir: dir, target: "MyApp", fm: fm)
        XCTAssertEqual(files.map { Set($0.map { URL(fileURLWithPath: $0).lastPathComponent }) }, ["ContentView.swift", "Row.swift"])
    }

    // MARK: 8. composition with PATCH-ACCESS forwarding (the default placement)

    /// A forwarded view must get every whole-app fix: `@available` on its forwarder extension AND
    /// its Generated/ thunks, `__patchLit` declared in the Generated file that now uses it, and a
    /// `#if`-wrapped private member still kept file-scoped (compact fallback block).
    func testForwardedViewComposesAvailabilityLiteralsAndIfConfigPrivates() throws {
        guard let o = try prepareAndTypecheck([("Views.swift", """
        import SwiftUI
        import Observation

        struct SearchField: View {
            @Binding var searchText: String
            var placeholder: LocalizedStringKey = "Search..."
            var body: some View { TextField(placeholder, text: $searchText) }
        }
        extension View {
            func mySheet(isPresented: Binding<Bool>) -> some View { sheet(isPresented: isPresented) { Text("s") } }
        }
        @available(iOS 17.0, *)
        @Observable final class Model { var title = "hi" }

        @available(iOS 17.0, *)
        struct AvailPrivate: View {
            var model: Model
            @State private var query = ""
            @State private var presented = false
            var body: some View {
                List {
                    SearchField(searchText: $query, placeholder: "Search villagers")
                    Button("Manage") { presented = true }
                        .mySheet(isPresented: $presented)
                    Text(model.title)
                }
            }
        }
        struct IfConfigPrivate: View {
            #if os(iOS)
            @State private var shown = false
            #endif
            var body: some View {
                List {
                    #if os(iOS)
                    Button("Show") { shown = true }
                        .mySheet(isPresented: $shown)
                    #endif
                    Text("x")
                }
            }
        }
        """)]) else { throw XCTSkip("no iphonesimulator SDK") }
        let file = o.files["Views.swift"] ?? ""
        if case .forwardedPrivateAccess? = o.result.placements["AvailPrivate"] {
            XCTAssertTrue(file.contains("@available(iOS 17.0, *)\nextension AvailPrivate {"),
                          "the in-file forwarder extension carries the view's availability:\n\(file)")
        } else {
            XCTFail("AvailPrivate should be forwarded: \(String(describing: o.result.placements["AvailPrivate"]))")
        }
        XCTAssertTrue(o.generated.contains("fileprivate func __patchLit"), "Generated/ declares the helper it uses")
        XCTAssertTrue(o.generated.contains("__patchLit(a[0])"), o.generated)
        XCTAssertFalse(o.generated.contains("shown"), "a #if-wrapped private member never reaches Generated/:\n\(o.generated)")
        XCTAssertTrue(o.compiled, o.log)
    }

    // MARK: 9. `if #available` branches (proposal B)

    private static let availabilityBranchView = """
    import SwiftUI
    import Observation
    @available(iOS 17.0, *)
    @Observable final class Model { var title = "hi" }
    @available(iOS 17.0, *)
    struct NewCard: View {
        var model: Model
        var body: some View { Text(model.title) }
    }
    struct Home: View {
        var body: some View {
            VStack {
                Text("Home")
                if #available(iOS 17.0, *) {
                    NewCard(model: Model())
                } else {
                    Text("Update iOS")
                }
            }
        }
    }
    """

    /// Slots recorded inside the AVAILABLE branch of `if #available(iOS 17, *)` are wrapped in the
    /// same check in the thunk, so the app still compiles at an iOS 16 deployment target.
    func testAvailabilityBranchSlotsAreGuardedInTheThunk() throws {
        guard let o = try prepareAndTypecheck([("Home.swift", Self.availabilityBranchView)]) else {
            throw XCTSkip("no iphonesimulator SDK")
        }
        XCTAssertTrue(o.result.viewNames.contains("Home"))
        XCTAssertTrue(o.generated.contains("if #available(iOS 17.0, *) {\n        __s["),
                      "the NewCard slot entry is availability-guarded:\n\(o.generated)")
        XCTAssertTrue(o.compiled, "an #available-branch slot must compile below its availability:\n\(o.log)")
    }

    /// HASH-INERT: the guard is thunk text only — the guest body, slot ids and `bodyHash` are
    /// exactly what they'd be without the tag (so no fingerprint/bodyHash churn for existing apps).
    func testAvailabilityGuardIsHashInert() {
        let lv = BodyLowering().lowerAllViews(source: Self.availabilityBranchView).first { $0.viewName == "Home" }!
        XCTAssertTrue(lv.opaqueLeaves.contains { $0.availability == ["#available(iOS 17.0, *)"] })
        var stripped = lv.opaqueLeaves
        for i in stripped.indices { stripped[i].availability = [] }
        XCTAssertEqual(BodyLowering.viewBodyContentHash(guestBody: lv.guestBody, opaqueLeaves: stripped),
                       BodyLowering.viewBodyContentHash(lv))
        // The condition's version does not enter the guest body or the ids either.
        let other = BodyLowering().lowerAllViews(source: Self.availabilityBranchView
            .replacingOccurrences(of: "if #available(iOS 17.0, *)", with: "if #available(iOS 15.0, *)"))
            .first { $0.viewName == "Home" }!
        XCTAssertEqual(other.guestBody, lv.guestBody)
        XCTAssertEqual(other.opaqueLeaves.map(\.id), lv.opaqueLeaves.map(\.id))
        XCTAssertEqual(BodyLowering.viewBodyContentHash(other), BodyLowering.viewBodyContentHash(lv))
    }

    // MARK: 10. deployment target below PatchSDK's minimum (proposal A — warn only)

    func testDeploymentTargetReaderAndSDKFloor() {
        let pbx = """
        {
            objects = {
                C1 = {isa = XCBuildConfiguration; buildSettings = { IPHONEOS_DEPLOYMENT_TARGET = 14.0; }; name = Debug; };
                C2 = {isa = XCBuildConfiguration; buildSettings = { IPHONEOS_DEPLOYMENT_TARGET = 15.2; }; name = Release; };
                C3 = {isa = XCBuildConfiguration; buildSettings = { SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; }; name = Debug; };
                L1 = {isa = XCConfigurationList; buildConfigurations = ( C1, C2, ); };
                L2 = {isa = XCConfigurationList; buildConfigurations = ( C3, ); };
                L3 = {isa = XCConfigurationList; buildConfigurations = ( ); };
                T1 = {isa = PBXNativeTarget; buildConfigurationList = L1; name = Old; };
                T2 = {isa = PBXNativeTarget; buildConfigurationList = L3; name = Inherits; };
                P0 = {isa = PBXProject; buildConfigurationList = L2; };
            };
            rootObject = P0;
        }
        """
        XCTAssertEqual(XcodeTargetSources.iOSDeploymentTarget(pbxproj: pbx, target: "Old"), "14.0")
        XCTAssertEqual(XcodeTargetSources.iOSDeploymentTarget(pbxproj: pbx, target: "Inherits"), "17.0")
        XCTAssertTrue(XcodeTargetSources.versionPrecedes("9.3", "16.0"))
        XCTAssertTrue(XcodeTargetSources.versionPrecedes("15.6", XcodeTargetSources.sdkMinimumIOS))
        XCTAssertFalse(XcodeTargetSources.versionPrecedes("16.0", XcodeTargetSources.sdkMinimumIOS))
    }

    // MARK: 11. file-private reach: `private extension` nested types, wrapper backing storage

    /// A type nested in `private extension V { struct Constants }` is file-private (NewsApp), and a
    /// private property wrapper's `_name` backing storage is too (ACHNBrowserUI `_namespace`): a
    /// slot reading either must never move to Patch/Generated/ un-forwarded.
    func testPrivateExtensionNestedTypeAndWrapperBackingStorageStayFileScoped() throws {
        guard let o = try prepareAndTypecheck([
            ("FavoritesView.swift", """
            import SwiftUI
            extension String { func localized() -> String { self } }
            struct FavoritesView: View {
                @State private var shown = false
                var body: some View {
                    NavigationView {
                        List { Text("row").onTapGesture { shown.toggle() } }
                            .navigationBarTitle(Text(Constants.title), displayMode: .automatic)
                    }
                }
            }
            private extension FavoritesView {
                struct Constants {
                    static let title = "Favorites".localized()
                }
            }
            """),
            ("PlayerView.swift", """
            import SwiftUI
            enum PlayerMode { case small, expanded }
            struct PlayerSmall: View {
                @Binding var mode: PlayerMode
                var namespace: Namespace.ID
                var body: some View { Text("small").matchedGeometryEffect(id: "p", in: namespace) }
            }
            struct PlayerView: View {
                @State private var mode: PlayerMode = .small
                @Namespace private var namespace
                var body: some View {
                    VStack {
                        switch mode {
                        case .small:
                            PlayerSmall(mode: $mode, namespace: _namespace.wrappedValue)
                        case .expanded:
                            Text("expanded")
                        }
                    }
                }
            }
            """),
        ]) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertFalse(o.generated.contains("Constants.title"),
                       "a private-extension nested type never reaches Patch/Generated/:\n\(o.generated)")
        XCTAssertFalse(o.generated.contains("_namespace"),
                       "a private wrapper's backing storage never reaches Patch/Generated/:\n\(o.generated)")
        XCTAssertTrue(o.compiled, o.log)
    }

    func testFilePrivateSymbolsIncludePrivateExtensionNestedTypes() {
        let tree = Parser.parse(source: """
        struct V {}
        private extension V { struct Constants { static let a = 1 } }
        extension V { struct Public {} }
        """)
        let syms = ThunkGenerator.filePrivateSymbols(in: tree)
        XCTAssertTrue(syms.typeNames.contains("Constants"))
        XCTAssertFalse(syms.typeNames.contains("Public"))
    }
}
