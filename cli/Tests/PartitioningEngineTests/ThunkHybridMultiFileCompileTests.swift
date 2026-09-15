// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator

/// MULTI-FILE HYBRID THUNK-COMPILE NET. `SwiftUIThunkCompileTests` type-checks the legacy
/// SAME-FILE output as ONE compile unit — which, by construction, can never catch an ACCESS-
/// CONTROL break (Swift's `private`/`fileprivate` is file-scoped: everything is visible inside a
/// single file). The DEFAULT `patchcli prepare` placement is HYBRID: most thunk code lands in a
/// SEPARATE `Patch/Generated/PatchThunks.generated.swift`, so a thunk closure that names a
/// FILE-PRIVATE symbol (a `private struct MixTrackRow: View` child, a `fileprivate enum Palette`
/// token, a file-scope `private let`) compiles in a single-file harness but fails the real app
/// build with `cannot find 'MixTrackRow' in scope`.
///
/// This harness reproduces the REAL on-disk layout: every developer file (with `dynamic`
/// inserted + any in-file PATCH-THUNKS block) is written as ITS OWN file, the generated thunk
/// file is written separately, and they are type-checked TOGETHER (one module, many files — the
/// exact access-control topology Xcode compiles) for the iOS simulator against the SDK host stub.
///
/// Skips (does NOT fail) when no iphonesimulator SDK is present.
final class ThunkHybridMultiFileCompileTests: XCTestCase {

    struct Outcome {
        var compiled: Bool
        var log: String
        var result: ThunkGenerator.Result
        /// Every file as written to disk (name → text), incl. `PatchThunks.generated.swift`.
        var files: [String: String]
        var dump: String {
            files.sorted { $0.key < $1.key }
                .map { "===== \($0.key) =====\n\($0.value)" }.joined(separator: "\n")
        }
    }

    /// Run the REAL hybrid `prepare` over `files`, lay the output out as separate files and
    /// type-check them together. nil → no iOS SDK (caller skips).
    static func prepareAndCompile(_ files: [(name: String, text: String)]) throws -> Outcome? {
        let sdkPath = SwiftUIThunkCompileTests.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sdkPath, !sdkPath.isEmpty else { return nil }

        let base = URL(fileURLWithPath: "/tmp/PatchHybridFixture")
        let sources = files.map {
            ThunkGenerator.SourceFile(url: base.appendingPathComponent($0.name), text: $0.text)
        }
        let result = ThunkGenerator().prepare(sources: sources, hybrid: true)

        func stripHostImports(_ s: String) -> String {
            s.replacingOccurrences(of: "import PatchSDK\n", with: "")
                .replacingOccurrences(of: "import PatchSwiftUI\n", with: "")
                .replacingOccurrences(of: "import PatchRender\n", with: "")
        }
        var written: [String: String] = [:]
        for f in files {
            let modified = result.modifiedFiles.first { $0.url.lastPathComponent == f.name }?.text
            written[f.name] = stripHostImports(modified ?? f.text)
        }
        if !result.generatedFileContents.isEmpty {
            written[ThunkGenerator.thunkFileName] = stripHostImports(result.generatedFileContents)
        }
        written["HostStub.swift"] = SwiftUIThunkCompileTests.hostStub

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hybrid-thunk-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var paths: [String] = []
        for (name, text) in written.sorted(by: { $0.key < $1.key }) {
            let url = tmp.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            paths.append(url.path)
        }
        let args = ["-typecheck", "-sdk", sdkPath, "-target", "arm64-apple-ios18.0-simulator"] + paths
        let log = SwiftUIThunkCompileTests.run("/usr/bin/swiftc", args, captureStderr: true) ?? ""
        return Outcome(compiled: !log.contains("error:"), log: log, result: result, files: written)
    }

    @discardableResult
    func assertCompiles(_ files: [(name: String, text: String)], _ what: String,
                        file: StaticString = #filePath, line: UInt = #line) throws -> Outcome {
        guard let o = try Self.prepareAndCompile(files) else { throw XCTSkip("no iphonesimulator SDK") }
        if ProcessInfo.processInfo.environment["PATCH_DUMP_HYBRID"] == "1" { print(o.dump) }
        XCTAssertTrue(o.compiled,
                      "[\(what)] the hybrid-prepared project must type-check as SEPARATE files:\n"
                      + "----- log -----\n\(o.log)\n----- files -----\n\(o.dump)",
                      file: file, line: line)
        return o
    }

    // MARK: - BUG 1: file-private TYPES referenced from a separate-file thunk

    /// The customer's `MixToolPanel.swift`: a non-private panel whose body uses two FILE-PRIVATE
    /// child views (`private struct MixTrackRow`/`MixGainRow`). The thunk's native slot closures
    /// (`AnyView(MixGainRow(...))`, the ForEach row `MixTrackRow(track:)`) name those types, so the
    /// panel's helper methods MUST stay beside the source — a separate-file extension can't see a
    /// file-private type (`cannot find 'MixGainRow' in scope`).
    static let mixToolPanel = """
    import SwiftUI

    struct MixTrack: Identifiable {
        let id: Int
        var name: String
        var gain: Double
    }

    struct MixToolPanel: View {
        let tracks: [MixTrack]
        @State var masterGain: Double = 0.5
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mix")
                ForEach(tracks) { track in
                    MixTrackRow(track: track)
                }
                MixGainRow(title: "Master", gain: masterGain)
            }
        }
    }

    private struct MixTrackRow: View {
        let track: MixTrack
        var body: some View {
            HStack { Text(track.name); Spacer() }
        }
    }

    private struct MixGainRow: View {
        let title: String
        let gain: Double
        var body: some View { Text(title) }
    }
    """

    /// A plain view in ANOTHER file so the generated folder has separate-file content too.
    static let helloFile = """
    import SwiftUI
    struct HelloPanel: View {
        var body: some View { Text("hi").padding() }
    }
    """

    func testPrivateChildViewTypesCompileAcrossFiles() throws {
        let o = try assertCompiles([("MixToolPanel.swift", Self.mixToolPanel), ("HelloPanel.swift", Self.helloFile)],
                                   "private child view types")
        // Private-access forwarding (the default): the file-private child view types are reached via
        // PATCH-ACCESS factories (`__patchMake_MixGainRow(…)`) declared in MixToolPanel.swift.
        guard case .forwardedPrivateAccess(let members)? = o.result.placements["MixToolPanel"] else {
            return XCTFail("MixToolPanel references file-private types → forwarded; got "
                           + "\(String(describing: o.result.placements["MixToolPanel"]))\n\(o.dump)")
        }
        XCTAssertTrue(members.contains("MixGainRow"), "must name the private type: \(members)")
        let genWithoutFactories = o.result.generatedFileContents
            .replacingOccurrences(of: "__patchMake_MixGainRow(", with: "")
            .replacingOccurrences(of: "__patchMake_MixTrackRow(", with: "")
        XCTAssertFalse(genWithoutFactories.contains("MixGainRow("),
                       "a file-private type must never be named directly in the separate generated file:\n\(o.dump)")
        XCTAssertEqual(o.result.placements["HelloPanel"], .separateFile)

        // Legacy layout (forwarding off): the file-private types force same-file placement and are named.
        let legacy = ThunkGenerator().prepare(
            sources: [("MixToolPanel.swift", Self.mixToolPanel), ("HelloPanel.swift", Self.helloFile)]
                .map { .init(url: URL(fileURLWithPath: "/fixture/\($0.0)"), text: $0.1) },
            hybrid: true, accessForwarding: false)
        guard case .sameFileBecausePrivate(let legacyMembers)? = legacy.placements["MixToolPanel"] else {
            return XCTFail("legacy: MixToolPanel should be same-file; got \(String(describing: legacy.placements["MixToolPanel"]))")
        }
        XCTAssertTrue(legacyMembers.contains("MixGainRow"), "\(legacyMembers)")
        XCTAssertFalse(legacy.generatedFileContents.contains("MixGainRow("))
    }

    /// Other file-private symbol shapes the separate generated file can't reach: a NESTED
    /// private child view, a `fileprivate enum` design token (a color token source), a file-scope
    /// `private let` numeric constant, a private type in a generic argument / `.sheet` content.
    static let privateSymbolShapes = """
    import SwiftUI

    fileprivate enum Palette {
        static let accent = Color.red
    }
    private let kRowSpacing: CGFloat = 6
    private func caption(_ i: Int) -> String { "#\\(i)" }
    extension Color {
        fileprivate static let brandInk = Color.blue
    }

    struct DeckPanel: View {
        @State var showSheet = false
        var body: some View {
            VStack(spacing: kRowSpacing) {
                Row(title: "A")
                Text("deck").foregroundStyle(Palette.accent)
                Text("ink").foregroundStyle(Color.brandInk)
                Text(caption(3)).padding(kRowSpacing)
                ForEach(0..<3, id: \\.self) { i in
                    Badge(index: i)
                }
            }
            .sheet(isPresented: $showSheet) { SheetBody() }
        }

        private struct Row: View {
            let title: String
            var body: some View { Text(title) }
        }
    }

    fileprivate struct Badge: View {
        let index: Int
        var body: some View { Text("\\(index)") }
    }

    private struct SheetBody: View {
        var body: some View { Text("sheet") }
    }
    """

    func testOtherFilePrivateSymbolShapesCompileAcrossFiles() throws {
        let o = try assertCompiles([("DeckPanel.swift", Self.privateSymbolShapes), ("HelloPanel.swift", Self.helloFile)],
                                   "nested private type / fileprivate enum token / private global")
        guard case .sameFileBecausePrivate(let members)? = o.result.placements["DeckPanel"] else {
            return XCTFail("DeckPanel references file-private symbols → same-file\n\(o.dump)")
        }
        for sym in ["Row", "Palette", "Badge", "SheetBody"] {
            XCTAssertTrue(members.contains(sym), "must name `\(sym)`: \(members)\n\(o.dump)")
        }
        XCTAssertEqual(o.result.privateSymbolReferences["DeckPanel"].map(Set.init)?.isSuperset(of: ["Row", "Palette", "Badge", "SheetBody"]), true)
    }

    /// A `private struct` that becomes a View RETROACTIVELY (`extension Tag: View`) can't be
    /// extended from the generated file either — its whole thunk must stay beside it.
    func testPrivateStructWithExtensionViewConformanceCompiles() throws {
        let src = """
        import SwiftUI
        struct TagList: View {
            var body: some View { VStack { Tag(name: "a") } }
        }
        private struct Tag { let name: String }
        extension Tag: View {
            var body: some View { Text(name) }
        }
        """
        let o = try assertCompiles([("TagList.swift", src), ("HelloPanel.swift", Self.helloFile)],
                                   "private struct + extension View conformance")
        XCTAssertFalse(o.result.generatedFileContents.contains("extension Tag {"), o.dump)
    }

    /// DEMOTE-SAFETY / NO OVER-REACH: an INTERNAL child view type (same name shape, not private)
    /// still routes SEPARATE — the private-type rule must only fire on genuinely file-private types.
    func testInternalChildViewTypeStaysSeparate() throws {
        let src = Self.mixToolPanel.replacingOccurrences(of: "private struct", with: "struct")
        let o = try assertCompiles([("MixToolPanel.swift", src)], "internal child types")
        XCTAssertEqual(o.result.placements["MixToolPanel"], .separateFile, o.dump)
    }

    // MARK: - BUG 2: non-View builder content wrapped in AnyView

    /// The customer's toolbar shape: `@ToolbarContentBuilder private var nativeToolbar: some
    /// ToolbarContent` used as `.toolbar { nativeToolbar }`. It must never be emitted as
    /// `AnyView(nativeToolbar)` (ToolbarContent is not a View).
    static let keyframeToolPanel = """
    import SwiftUI

    struct KeyframeToolPanel: View {
        @State private var isOn = false
        var body: some View {
            NavigationStack {
                VStack { Text("Keyframes") }
                    .toolbar { nativeToolbar }
            }
        }

        @ToolbarContentBuilder
        private var nativeToolbar: some ToolbarContent {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { isOn.toggle() }
            }
        }
    }

    struct ClipToolPanel: View {
        var body: some View {
            NavigationStack {
                Text("Clips")
                    .toolbar(content: { clipToolbar() })
            }
        }

        @ToolbarContentBuilder
        func clipToolbar() -> some ToolbarContent {
            ToolbarItemGroup(placement: .bottomBar) { Button("Split") {} }
        }
    }

    struct TrimToolPanel: View {
        var body: some View {
            NavigationStack {
                Text("Trim")
                    .toolbar { trimToolbar }
            }
        }

        var trimToolbar: some CustomizableToolbarContent {
            ToolbarItem(id: "trim", placement: .primaryAction) { Button("Trim") {} }
        }
    }

    struct EditorToolbar: ToolbarContent {
        var body: some ToolbarContent {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
        }
    }

    struct EditorPanel: View {
        var body: some View {
            NavigationStack {
                Text("Editor")
                    .toolbar { EditorToolbar() }
            }
        }
    }
    """

    func testToolbarContentIsNeverWrappedInAnyView() throws {
        let o = try assertCompiles([("KeyframeToolPanel.swift", Self.keyframeToolPanel)], "ToolbarContent")
        let all = o.files.values.joined(separator: "\n")
        for bad in ["AnyView(nativeToolbar)", "AnyView(clipToolbar())", "AnyView(trimToolbar)", "AnyView(EditorToolbar())"] {
            XCTAssertFalse(all.contains(bad), "ToolbarContent wrapped in AnyView (`\(bad)`):\n\(o.dump)")
        }
    }

    /// A cross-FILE `ToolbarContent` type (declared in another file) used as `.toolbar { X() }`.
    func testCrossFileToolbarContentTypeCompiles() throws {
        let toolbarFile = """
        import SwiftUI
        struct SharedToolbar: ToolbarContent {
            var body: some ToolbarContent {
                ToolbarItem(placement: .primaryAction) { Button("Go") {} }
            }
        }
        """
        let viewFile = """
        import SwiftUI
        struct SharedPanel: View {
            var body: some View {
                NavigationStack { Text("Shared").toolbar { SharedToolbar() } }
            }
        }
        """
        let o = try assertCompiles([("SharedToolbar.swift", toolbarFile), ("SharedPanel.swift", viewFile)],
                                   "cross-file ToolbarContent type")
        XCTAssertFalse(o.files.values.joined().contains("AnyView(SharedToolbar())"), o.dump)
    }

    /// NO OVER-DEMOTE: plain View content in `.toolbar { … }` (SwiftUI wraps it) still lowers
    /// exactly as before, and a custom VIEW child in the toolbar still compiles.
    func testPlainViewToolbarContentStillLowers() throws {
        let src = """
        import SwiftUI
        struct ShareButton: View { var body: some View { Image(systemName: "square.and.arrow.up") } }
        struct PlainToolbarPanel: View {
            var body: some View {
                NavigationStack {
                    Text("Plain")
                        .toolbar { ShareButton() }
                }
            }
        }
        struct ItemToolbarPanel: View {
            var body: some View {
                NavigationStack {
                    Text("Items")
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) { Text("Edit") }
                        }
                }
            }
        }
        """
        let o = try assertCompiles([("PlainToolbarPanel.swift", src)], "plain view toolbar")
        XCTAssertTrue(o.result.viewNames.contains("PlainToolbarPanel"), o.dump)
        // Neither toolbar needed the native-toolbar effect slot: a top-level ToolbarItem and a
        // custom View child keep lowering to IR toolbar items (byte-identical to before).
        XCTAssertFalse(o.files.values.joined().contains("content.toolbar"),
                       "plain toolbars must not be forced native:\n\(o.dump)")
        for lv in o.result.loweredViews where ["PlainToolbarPanel", "ItemToolbarPanel"].contains(lv.viewName) {
            XCTAssertTrue(lv.guestBody.contains(".toolbar(items:"), "\(lv.viewName): \(lv.guestBody)")
        }

        // A CONDITIONAL ToolbarItem (`if … { ToolbarItem }`) — non-View content in a bare
        // statement — must NOT become `AnyView(ToolbarItem…)`.
        let conditional = """
        import SwiftUI
        struct ConditionalToolbarPanel: View {
            @State var editing = false
            var body: some View {
                NavigationStack {
                    Text("Cond")
                        .toolbar {
                            if editing {
                                ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = false } }
                            }
                        }
                }
            }
        }
        """
        try assertCompiles([("ConditionalToolbarPanel.swift", conditional)], "conditional ToolbarItem")
    }

    /// NAME PRECISION: another type's `var actions: some ToolbarContent` must NOT make THIS
    /// view's own `var actions: some View` look like ToolbarContent — its toolbar keeps lowering
    /// to IR items exactly as before (no forced-native toolbar, no fingerprint churn).
    func testSameNamedViewMemberIsNotMistakenForToolbarContent() throws {
        let other = """
        import SwiftUI
        struct OtherPanel: View {
            var body: some View { NavigationStack { Text("Other").toolbar { actions } } }
            @ToolbarContentBuilder
            var actions: some ToolbarContent { ToolbarItem { Button("X") {} } }
        }
        """
        let mine = """
        import SwiftUI
        struct MinePanel: View {
            var body: some View { NavigationStack { Text("Mine").toolbar { actions } } }
            var actions: some View { Text("Edit") }
        }
        """
        let o = try assertCompiles([("OtherPanel.swift", other), ("MinePanel.swift", mine)], "same-named members")
        let mineLowered = try XCTUnwrap(o.result.loweredViews.first { $0.viewName == "MinePanel" })
        XCTAssertTrue(mineLowered.effectSlots.isEmpty, "MinePanel's View toolbar must not go native: \(mineLowered.guestBody)")
        let otherLowered = try XCTUnwrap(o.result.loweredViews.first { $0.viewName == "OtherPanel" })
        XCTAssertEqual(otherLowered.effectSlots.map(\.label), ["toolbar"], otherLowered.guestBody)
    }

    /// The rest of the non-View builder family: `ChartContent`, `TableColumnContent`,
    /// `AccessibilityRotorContent` (the Scene/Commands family never appears in a View body).
    static let otherBuilders = """
    import SwiftUI
    import Charts

    struct Sample: Identifiable { let id: Int; let name: String; let value: Double }

    struct ChartPanel: View {
        let samples: [Sample]
        var body: some View {
            VStack {
                Text("Chart")
                Chart { marks }
                Chart(samples) { s in BarMark(x: .value("n", s.name), y: .value("v", s.value)) }
            }
        }

        @ChartContentBuilder
        var marks: some ChartContent {
            BarMark(x: .value("a", "x"), y: .value("b", 1))
        }
    }

    struct TablePanel: View {
        let samples: [Sample]
        var body: some View {
            VStack {
                Text("Table")
                Table(samples) { columns }
            }
        }

        @TableColumnBuilder<Sample, Never>
        var columns: some TableColumnContent<Sample, Never> {
            TableColumn("Name", value: \\.name)
        }
    }

    struct RotorPanel: View {
        let samples: [Sample]
        var body: some View {
            VStack { Text("Rotor") }
                .accessibilityRotor("Samples") { rotorEntries }
        }

        @AccessibilityRotorContentBuilder
        var rotorEntries: some AccessibilityRotorContent {
            ForEach(samples) { s in AccessibilityRotorEntry(s.name, id: s.id) }
        }
    }
    """

    func testOtherNonViewBuilderContentCompiles() throws {
        try assertCompiles([("BuilderPanels.swift", Self.otherBuilders)], "chart/table/rotor builders")
    }
}
