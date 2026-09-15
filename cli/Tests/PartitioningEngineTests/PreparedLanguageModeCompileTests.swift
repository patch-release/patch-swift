// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
@testable import Compiler

/// LANGUAGE-MODE / DIAGNOSTIC-LEVEL MATRIX for everything `patchcli prepare` + `init` write into an
/// app. The other compile nets type-check generated code in Swift 5 mode with warnings ignored; a
/// real project may build in Swift 6 language mode, with `SWIFT_STRICT_CONCURRENCY=complete`, or
/// with warnings treated as errors — where code that is merely a WARNING in the default setting
/// breaks the build. Each test prepares a multi-file project (separate files, so file-scoped
/// `private` and per-file imports genuinely bite), type-checks the UNPREPARED project with the same
/// flags as a baseline, and requires the prepared project to add NO diagnostic (error or warning).
///
/// Covered: PATCH-ACCESS forwarders (struct- and extension-conformed views), slot / token / rowSlot /
/// action / effect / callback closures, `__patchLit` custom `LocalizedStringKey` params, a compact
/// in-file block (a `private` view type), `@preconcurrency` imports, the `Patch.configure` startup
/// code `init` injects (`AppEntryInjector`), and UIKit cell thunks.
final class PreparedLanguageModeCompileTests: XCTestCase {

    /// The flag sets a developer's project can build with.
    static let modes: [(name: String, flags: [String])] = [
        ("swift5-warnings-as-errors", ["-swift-version", "5", "-warnings-as-errors"]),
        ("swift5-strict-concurrency-complete", ["-swift-version", "5", "-strict-concurrency=complete", "-warnings-as-errors"]),
        ("swift6", ["-swift-version", "6", "-warnings-as-errors"]),
    ]

    /// `Patch.configure(…)` / `start()` as the real SDK declares them (non-isolated static configure,
    /// async start), for the injected startup code. Kept out of the shared host stub.
    static let configureStub = """
    public struct PatchConfiguration: Sendable {
        public var appKey: String
        public var appID: String?
        public var fingerprint: String?
        public init(appKey: String, appID: String? = nil, fingerprint: String? = nil) {
            self.appKey = appKey; self.appID = appID; self.fingerprint = fingerprint
        }
    }
    public enum StartOutcome: Sendable { case started }
    extension Patch {
        nonisolated public static func configure(_ configuration: PatchConfiguration) {}
        @discardableResult nonisolated public func start() async -> StartOutcome { .started }
    }
    """

    /// The UIKit host surface a cell thunk calls, mirroring `sdk/Sources/PatchUIKit` (a
    /// `@MainActor` `installPatchedCell`).
    static let uikitStub = """
    import UIKit
    public struct PatchCellWiring {
        public var slots: [String: () -> UIView]
        public var actions: [String: () -> Void]
        public var colorTokens: [String: () -> UIColor]
        public var numberTokens: [String: () -> Double]
        public init(slots: [String: () -> UIView] = [:], actions: [String: () -> Void] = [:],
                    colorTokens: [String: () -> UIColor] = [:], numberTokens: [String: () -> Double] = [:]) {
            self.slots = slots; self.actions = actions; self.colorTokens = colorTokens; self.numberTokens = numberTokens
        }
    }
    public final class Patch: @unchecked Sendable {
        public static let shared = Patch()
        @MainActor @discardableResult
        public func installPatchedCell(typeName: String, contentView: UIView, model: Any?,
                                       wiring: () -> PatchCellWiring = { PatchCellWiring() }) -> Bool { false }
    }
    """

    // MARK: - Harness

    static func sdkPath() -> String? {
        SwiftUIThunkCompileTests.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "import PatchSDK\n", with: "")
            .replacingOccurrences(of: "import PatchSwiftUI\n", with: "")
            .replacingOccurrences(of: "import PatchRender\n", with: "")
            .replacingOccurrences(of: "import PatchUIKit\n", with: "")
    }

    /// Type-check `files` (name → text) for the iOS simulator; returns the diagnostics log.
    static func typecheck(_ files: [String: String], flags: [String], sdk: String,
                          envFlags: [String] = SwiftUIThunkCompileTests.envTypecheckFlags) throws -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("plm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var paths: [String] = []
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            let url = tmp.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            paths.append(url.path)
        }
        let args = ["-typecheck", "-sdk", sdk, "-target", "arm64-apple-ios17.0-simulator", "-module-name", "FixtureApp"]
            + flags + paths + envFlags
        return (SwiftUIThunkCompileTests.run("/usr/bin/swiftc", args, captureStderr: true) ?? "")
            .replacingOccurrences(of: tmp.path + "/", with: "")
    }

    /// `file:line:col: error|warning: message` lines, without the location (so a diagnostic that
    /// moved lines still matches).
    static func diagnostics(_ log: String) -> [String] {
        log.split(separator: "\n").compactMap { line -> String? in
            guard let r = line.range(of: ": error: ") ?? line.range(of: ": warning: ") else { return nil }
            let file = line[..<r.lowerBound].split(separator: ":").first.map(String.init) ?? ""
            return file + ": " + line[r.lowerBound...].dropFirst(2)
        }
    }

    /// Prepare → type-check baseline and prepared under every mode → no new diagnostics.
    func assertNoNewDiagnostics(sources: [String: String], prepared: [String: String], extraStubs: [String: String],
                                what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let sdk = Self.sdkPath(), !sdk.isEmpty else { throw XCTSkip("no iphonesimulator SDK") }
        let stubs = ["ZZ_HostStub.swift": SwiftUIThunkCompileTests.hostStub].merging(extraStubs) { $1 }
        for mode in Self.modes {
            let baseLog = try Self.typecheck(sources.merging(stubs) { $1 }, flags: mode.flags, sdk: sdk)
            let prepLog = try Self.typecheck(prepared.mapValues(Self.strip).merging(stubs) { $1 }, flags: mode.flags, sdk: sdk)
            let base = Set(Self.diagnostics(baseLog))
            let added = Self.diagnostics(prepLog).filter { !base.contains($0) }
            XCTAssertTrue(added.isEmpty,
                          "[\(what) / \(mode.name)] prepare added diagnostics:\n\(added.joined(separator: "\n"))\n"
                          + "--- prepared log ---\n\(prepLog)\n--- baseline log ---\n\(baseLog)\n"
                          + prepared.sorted { $0.key < $1.key }.map { "===== \($0.key) =====\n\($0.value)" }.joined(separator: "\n"),
                          file: file, line: line)
        }
    }

    func prepareSwiftUI(_ sources: [String: String]) -> (ThunkGenerator.Result, [String: String]) {
        let r = ThunkGenerator().prepare(
            sources: sources.sorted { $0.key < $1.key }.map { .init(url: URL(fileURLWithPath: "/fixture/\($0.key)"), text: $0.value) },
            hybrid: true, accessForwarding: true)
        var out = sources
        for m in r.modifiedFiles { out[m.url.lastPathComponent] = m.text }
        if !r.generatedFileContents.isEmpty { out[ThunkGenerator.thunkFileName] = r.generatedFileContents }
        return (r, out)
    }

    // MARK: - Fixtures (each warning-free in every mode on its own)

    static let profile = """
    import SwiftUI
    import Observation

    @Observable final class ProfileStore {
        var name = "Ada"
        var items: [Item] = [Item(title: "a"), Item(title: "b")]
        var isEmpty: Bool { items.isEmpty }
        func refresh() async {}
        func delete(_ item: Item) { items.removeAll { $0.id == item.id } }
    }

    struct Item: Identifiable, Hashable {
        let id = UUID()
        var title: String
    }

    enum Theme {
        static let accent = Color.orange
        static let radius: CGFloat = 12
        static let title = Font.system(size: 17, weight: .semibold)
    }

    struct ProfileScreen: View {
        @Environment(ProfileStore.self) private var store
        @State private var showSheet = false
        @State private var query = ""
        private var greeting: String { "Hello, " + store.name }

        var body: some View {
            NavigationStack {
                List {
                    Section {
                        ForEach(store.items) { item in
                            Row(item: item, onDelete: { store.delete(item) })
                        }
                    } header: {
                        SectionHeader(title: "People")
                    }
                    Text(greeting)
                        .font(Theme.title)
                        .foregroundStyle(Theme.accent)
                    Button("Show") { showSheet = true }
                        .cornerRadius(Theme.radius)
                        .contextMenu { Button("Refresh") { reload() } }
                }
                .searchable(text: $query)
                .refreshable { await store.refresh() }
                .task { await store.refresh() }
                .onChange(of: query) { _, newValue in
                    if newValue.isEmpty { reload() }
                }
                .sheet(isPresented: $showSheet) { Text("Sheet") }
            }
        }

        private func reload() {
            Task { await store.refresh() }
        }
    }

    struct SectionHeader: View {
        let title: LocalizedStringKey
        var body: some View { Text(title).font(.headline) }
    }

    struct Row: View {
        let item: Item
        let onDelete: () -> Void
        var body: some View {
            HStack {
                Text(item.title)
                Spacer()
                Button("Delete", action: onDelete)
            }
        }
    }
    """

    static let split = """
    import SwiftUI

    struct Counter {
        @State private var count = 0
        private let step = 2
    }

    extension Counter: View {
        var body: some View {
            VStack {
                Text("Count \\(count)")
                Button("Add") { count += step }
                Badge()
            }
        }
    }

    private struct Badge: View {
        @State private var on = false
        var body: some View {
            Text(on ? "on" : "off")
                .padding()
                .onTapGesture { on.toggle() }
        }
    }
    """

    /// A view whose `.task` passes a non-Sendable value out of a `@preconcurrency`-imported module
    /// across an actor boundary — legal ONLY because the file imports it `@preconcurrency`.
    static let weather = """
    import SwiftUI
    @preconcurrency import WeatherKit
    @preconcurrency import CoreLocation

    struct WeatherCard: View {
        var location: CLLocation
        @State private var hours: [Date] = []

        var body: some View {
            VStack {
                Text("Forecast")
                Text("\\(hours.count) hours")
            }
            .task {
                do {
                    let forecast = try await WeatherService.shared.weather(for: location, including: .hourly).forecast
                    hours = forecast.map { $0.date }
                } catch {
                    hours = []
                }
            }
        }
    }
    """

    static let app = """
    import SwiftUI

    @main
    struct DemoApp: App {
        @State private var store = ProfileStore()

        var body: some Scene {
            WindowGroup {
                ProfileScreen()
                    .environment(store)
            }
        }
    }
    """

    // MARK: - Tests

    func testPreparedSwiftUIProjectAddsNoDiagnosticsInAnyLanguageMode() throws {
        let sources = ["Profile.swift": Self.profile, "Split.swift": Self.split]
        let (r, prepared) = prepareSwiftUI(sources)
        XCTAssertTrue(r.viewNames.contains("ProfileScreen") && r.viewNames.contains("Counter"), "\(r.viewNames)")
        XCTAssertTrue(prepared["Split.swift"]?.contains(PatchAccessForwarding.beginMarker) == true
                      || prepared["Split.swift"]?.contains(ThunkGenerator.sameFileBeginMarker) == true,
                      "the fixture exercises in-file generated code:\n\(prepared["Split.swift"] ?? "")")
        try assertNoNewDiagnostics(sources: sources, prepared: prepared, extraStubs: [:], what: "swiftui project")
    }

    /// Bug: `@preconcurrency import WeatherKit` in the view's file was dropped from the generated
    /// file's imports (attributed imports were skipped), so the SAME `.task` code copied into the
    /// generated effect slot failed Swift 6 with "non-sendable type 'Forecast<HourWeather>' returned
    /// by implicitly asynchronous call to nonisolated function cannot cross actor boundary"
    /// (real app: Apple's Food Truck sample, `TruckWeatherCard`).
    func testPreconcurrencyImportsAreCarriedIntoGeneratedCode() throws {
        let sources = ["WeatherCard.swift": Self.weather, "Other.swift": "import SwiftUI\nimport WeatherKit\nimport CoreLocation\n"]
        let (_, prepared) = prepareSwiftUI(sources)
        let generated = prepared[ThunkGenerator.thunkFileName] ?? ""
        XCTAssertTrue(generated.contains("#if canImport(WeatherKit)\n@preconcurrency import WeatherKit\n#endif"),
                      "a module any view file imports @preconcurrency is imported that way:\n\(generated)")
        XCTAssertEqual(ThunkGenerator.guardedImport("Charts"), "#if canImport(Charts)\nimport Charts\n#endif\n")
        try assertNoNewDiagnostics(sources: sources, prepared: prepared, extraStubs: [:], what: "preconcurrency import")
    }

    /// Bug: every generated helper method carried an explicit `@MainActor`. For a view declared
    /// `struct X: View` that isolation is already inferred, but the explicit attribute makes Swift 5
    /// (minimal checking) diagnose the developer's copied closure code — `main actor-isolated
    /// property 'chat' can not be referenced from a Sendable closure` — in the generated copy only,
    /// which breaks a warnings-as-errors build (real apps: OpenAIWrapper, PlantWatering).
    func testCopiedClosureCodeGetsNoNewConcurrencyWarningInSwift5() throws {
        let chat = """
        import SwiftUI

        final class Chat: ObservableObject {
            @Published var title = "New Chat"
        }
        final class History {
            func append(_ title: String) {}
        }

        struct ChatView: View {
            @ObservedObject var chat: Chat
            @State private var saved = false

            var body: some View {
                VStack {
                    Text(chat.title)
                    Text(saved ? "saved" : "")
                }
                .onAppear {
                    DispatchQueue.global().async {
                        History().append(chat.title)
                    }
                }
            }
        }
        """
        let sources = ["ChatView.swift": "import Combine\n" + chat]
        let (_, prepared) = prepareSwiftUI(sources)
        let all = prepared.values.joined()
        XCTAssertTrue(all.contains("func __patchEffectSlots"), "the fixture exercises an effect slot:\n\(all)")
        XCTAssertFalse(all.contains("@MainActor func __patchEffectSlots"),
                       "inferred-@MainActor views get no explicit attribute on helpers:\n\(all)")
        guard let sdk = Self.sdkPath(), !sdk.isEmpty else { throw XCTSkip("no iphonesimulator SDK") }
        let flags = ["-swift-version", "5", "-warnings-as-errors"]
        let stubs = ["ZZ_HostStub.swift": SwiftUIThunkCompileTests.hostStub]
        // Swift-5-specific by construction: CI's PATCH_TYPECHECK_EXTRA_FLAGS (e.g. `-swift-version 6`) don't apply.
        let base = try Self.typecheck(sources.merging(stubs) { $1 }, flags: flags, sdk: sdk, envFlags: [])
        let prep = try Self.typecheck(prepared.mapValues(Self.strip).merging(stubs) { $1 }, flags: flags, sdk: sdk, envFlags: [])
        XCTAssertTrue(Self.diagnostics(base).isEmpty, "baseline is warning-free:\n\(base)")
        XCTAssertTrue(Self.diagnostics(prep).isEmpty, "prepared is warning-free:\n\(prep)\n\(all)")
    }

    func testExtensionConformedViewKeepsExplicitMainActorOnHelpers() {
        let (_, prepared) = prepareSwiftUI(["Split.swift": Self.split])
        let all = prepared.values.joined()
        // `Counter` conforms in an extension (nothing inferred) — its helpers must stay explicitly isolated.
        let counterBlocks = all.components(separatedBy: "extension Counter {").dropFirst()
        XCTAssertFalse(counterBlocks.isEmpty, all)
        XCTAssertTrue(counterBlocks.contains { $0.contains("@MainActor func __patch") }, all)
    }

    func testInjectedStartupCodeAddsNoDiagnosticsInAnyLanguageMode() throws {
        let injected = try XCTUnwrap(AppEntryInjector.inject(
            into: Self.app, appKey: "pak_test", appID: "app_1", fingerprint: AppEntryInjector.pendingFingerprintPlaceholder))
        XCTAssertTrue(injected.contains("Patch.configure("), injected)
        let sources = ["App.swift": Self.app, "Profile.swift": Self.profile]
        var prepared = prepareSwiftUI(sources).1
        prepared["App.swift"] = injected
        try assertNoNewDiagnostics(sources: sources, prepared: prepared,
                                   extraStubs: ["ZZ_ConfigureStub.swift": Self.configureStub],
                                   what: "Patch.configure injection")
    }

    func testUIKitCellThunkAddsNoDiagnosticsInAnyLanguageMode() throws {
        let cell = """
        import UIKit

        struct CellModel {
            let title: String
            let subtitle: String
        }

        final class LegacyCell: UITableViewCell {
            private let titleLabel = UILabel()
            private let subtitleLabel = UILabel()

            func configure(with model: CellModel) {
                titleLabel.text = model.title
                subtitleLabel.text = model.subtitle
                subtitleLabel.textColor = .secondaryLabel
                contentView.addSubview(titleLabel)
                contentView.addSubview(subtitleLabel)
                NSLayoutConstraint.activate([
                    titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
                    subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
                ])
            }
        }
        """
        let r = UIKitThunkGenerator().prepare(sources: [.init(url: URL(fileURLWithPath: "/fixture/LegacyCell.swift"), text: cell)])
        XCTAssertEqual(r.dynamicInsertions, 1, r.thunkFileContents)
        let prepared = ["LegacyCell.swift": r.modifiedFiles.first?.text ?? cell,
                        UIKitThunkGenerator.thunkFileName: r.thunkFileContents]
        guard let sdk = Self.sdkPath(), !sdk.isEmpty else { throw XCTSkip("no iphonesimulator SDK") }
        for mode in Self.modes {
            let stub = ["ZZ_UIKitStub.swift": Self.uikitStub]
            let base = try Self.typecheck(["LegacyCell.swift": cell].merging(stub) { $1 }, flags: mode.flags, sdk: sdk)
            let prep = try Self.typecheck(prepared.mapValues(Self.strip).merging(stub) { $1 }, flags: mode.flags, sdk: sdk)
            let baseSet = Set(Self.diagnostics(base))
            let added = Self.diagnostics(prep).filter { !baseSet.contains($0) }
            XCTAssertTrue(added.isEmpty, "[uikit cell / \(mode.name)]\n\(added.joined(separator: "\n"))\n\(prep)\n\(r.thunkFileContents)")
        }
    }
}
