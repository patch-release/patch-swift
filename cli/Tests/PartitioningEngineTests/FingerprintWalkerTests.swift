// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler
import PartitioningEngine

/// Locks the native-shell fingerprint against the [BUG-3] class: the fingerprint
/// walk (and its sub-walks for Info.plist/frameworks/deployment-target) MUST hash
/// ONLY the developer's own native sources — never in-tree dependency clones or
/// Xcode build output. This walker was historically missed when the other four
/// discovery walks were hardened, and on a real app (AppA) it hashed 1,888
/// files for a 34-file app, making the OTA-compatibility gate permanently mismatch.
final class FingerprintWalkerTests: XCTestCase {

    /// Build a realistic project tree: a handful of REAL app sources surrounded by
    /// every flavor of build-artifact / dependency clone the walk must ignore.
    private func makeProject() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("patch-fp-\(UUID().uuidString)")
        func write(_ rel: String, _ contents: String) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: u, atomically: true, encoding: .utf8)
        }
        // --- REAL app sources (these, and ONLY these, belong in the fingerprint) ---
        try write("App/Math.swift", """
        struct Math {
            func add(_ a: Int, _ b: Int) -> Int {
                let s = a + b
                return s
            }
        }
        """)
        try write("App/Model.swift", """
        import Combine
        final class Store: ObservableObject {
            // A NATIVE-typed reactive prop: reading it is genuinely native (it is not a
            // value-marshallable scalar/array, so the reactive read can't host-project).
            // This keeps the getter a true NATIVE shell function — what the fingerprint
            // EXPLAIN reports with an "observable/state" reason. (A getter over a
            // value-marshallable reactive scalar/array now host-projects to `mixed`.)
            @Published var session: URLSession = .shared
            var summary: String {
                return session.configuration.identifier ?? "none"
            }
        }
        """)
        try write("Info.plist", "<plist><dict><key>App</key><string>Real</string></dict></plist>")

        // --- Things the walk MUST exclude ---
        try write("build/SourcePackages/checkouts/SomeDep/Sources/Dep.swift", "public func depFn() {}")
        try write("build/Build/Intermediates.noindex/App.build/DerivedSources/GeneratedAssetSymbols.swift",
                  "enum Gen { static let x = 1 }")
        try write("build/Build/Products/Debug-iphonesimulator/include/ffi/cel.swift", "func ffi() {}")
        try write("DerivedData/App/Build/Foo.swift", "func dd() {}")
        try write("Pods/SomePod/P.swift", "func pod() {}")
        try write("Carthage/Checkouts/C/C.swift", "func cart() {}")
        try write("AppTests/MathTests.swift", "import XCTest\nfinal class T: XCTestCase {}")
        try write(".Patch/build/module_wasm.swift", "func stale() {}")
        // A dependency Info.plist + Package.swift that the sub-walks must NOT pick.
        try write("build/SourcePackages/checkouts/SomeDep/Info.plist", "<plist>DEP</plist>")
        try write("build/SourcePackages/checkouts/SomeDep/Package.swift",
                  "// swift-tools-version:5.9\nimport PackageDescription\nlet p = Package(name: \"D\", platforms: [.iOS(.v13)])")
        return root
    }

    private func nativeRels(_ snap: ProjectFingerprinter.Snapshot) -> Set<String> {
        Set(snap.components.nativeSwiftFiles.map { String($0.split(separator: "|").first ?? "") })
    }

    func testFingerprintExcludesDepsAndBuildOutput() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let snap = ProjectFingerprinter().snapshot(projectDir: root, bridges: [:])
        let rels = nativeRels(snap)
        // EXACTLY the two real app sources — nothing else.
        XCTAssertEqual(rels, ["App/Math.swift", "App/Model.swift"],
                       "fingerprint must hash only developer sources; got \(rels.sorted())")
        // None of the artifact/dependency/test/generated files leaked in.
        for bad in ["Dep.swift", "GeneratedAssetSymbols.swift", "cel.swift", "Foo.swift",
                    "P.swift", "C.swift", "MathTests.swift", "module_wasm.swift"] {
            XCTAssertFalse(rels.contains(where: { $0.hasSuffix(bad) }),
                           "\(bad) must NOT be in the fingerprint; got \(rels.sorted())")
        }
        // The app's REAL Info.plist must be picked (not the dependency's "DEP" one).
        XCTAssertEqual(snap.components.infoPlist, Fingerprinter.hashData(Data("<plist><dict><key>App</key><string>Real</string></dict></plist>".utf8)),
                       "must hash the app Info.plist, not a dependency's")
        // Deployment target must NOT come from the dependency's Package.swift (.v13).
        XCTAssertNotEqual(snap.components.deploymentTarget, "iOS 13.0",
                          "deployment target must not be inferred from a dependency's Package.swift")
    }

    func testIsBuildArtifactPathPatterns() {
        let yes = [
            "/x/deriveddata/y.swift", "/x/sourcepackages/checkouts/z.swift",
            "/x/checkouts/z.swift", "/x/carthage/checkouts/z.swift",
            "/x/pods/z.swift", "/x/node_modules/z.swift",
            "/app/build/build/intermediates.noindex/a.build/gen.swift",
            "/app/build/build/products/debug-iphonesimulator/include/ffi.swift",
        ]
        for p in yes { XCTAssertTrue(SwiftParserEngine.isBuildArtifactPath(p), "\(p) should be an artifact path") }
        let no = ["/app/sources/math.swift", "/app/views/home.swift", "/app/app/model.swift"]
        for p in no { XCTAssertFalse(SwiftParserEngine.isBuildArtifactPath(p), "\(p) should NOT be an artifact path") }
    }

    /// The core OTA promise: editing the BODY of an OTA-eligible (pure) function
    /// must NOT change the fingerprint; editing a native function MUST.
    func testBodyEditOfEligibleFnIsStableButNativeChanges() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()

        // (1) Edit the pure `Math.add` body (interior line) → fingerprint stable.
        let math = root.appendingPathComponent("App/Math.swift")
        var s = try String(contentsOf: math, encoding: .utf8)
        s = s.replacingOccurrences(of: "let s = a + b", with: "let s = a + b + 0  // tweaked")
        try s.write(to: math, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base, "editing a wasmEligible function body must NOT change the fingerprint")

        // (2) Edit a NATIVE function (the getter reads a native-typed reactive prop).
        let model = root.appendingPathComponent("App/Model.swift")
        var m = try String(contentsOf: model, encoding: .utf8)
        m = m.replacingOccurrences(of: #"return session.configuration.identifier ?? "none""#,
                                   with: #"return session.configuration.identifier ?? "n/a""#)
        try m.write(to: model, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base, "editing a native function body MUST change the fingerprint")
    }

    // MARK: - PARAMETERIZED NATIVE SLOTS: string-literal edit is fingerprint-stable

    /// Build a project with a SwiftUI view that slots a CUSTOM child view carrying a
    /// simple string literal (`DisplayText(text: "Hello", size: 28)`). DisplayText is
    /// a custom view → the call is a NATIVE slot. With parameterized slots the literal
    /// rides WASM (via `BodyEmission.slotArgs`) and the slot factory is literal-
    /// independent, so editing the STRING is OTA and must NOT move the fingerprint —
    /// while editing the NUMBER (baked into the factory) is a native change and MUST.
    private func makeSlotProject() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("patch-fp-slot-\(UUID().uuidString)")
        let viewURL = root.appendingPathComponent("App/Home.swift")
        try fm.createDirectory(at: viewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        import SwiftUI
        struct DisplayText: View {
            var text: String
            var size: Double
            var body: some View { Text(text).font(.system(size: size)) }
        }
        struct Home: View {
            var body: some View {
                VStack {
                    Text("Header")
                    DisplayText(text: "Hello", size: 28)
                }
            }
        }
        """.write(to: viewURL, atomically: true, encoding: .utf8)
        return root
    }

    func testSlottedCustomViewStringEditIsFingerprintStable() throws {
        let root = try makeSlotProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = root.appendingPathComponent("App/Home.swift")
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()

        // (1) Edit the slotted custom view's STRING literal → OTA → fingerprint STABLE.
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #"DisplayText(text: "Hello", size: 28)"#,
                                   with: #"DisplayText(text: "Settings", size: 28)"#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "editing a SLOTTED custom view's STRING literal must NOT move the fingerprint "
            + "(it rides WASM via slotArgs; the native slot factory is literal-independent)")

        // (2) Edit the slotted call's NUMBER (baked into the native factory) → native
        //     change → fingerprint MUST move.
        var s2 = try String(contentsOf: view, encoding: .utf8)
        s2 = s2.replacingOccurrences(of: #"DisplayText(text: "Settings", size: 28)"#,
                                     with: #"DisplayText(text: "Settings", size: 30)"#)
        try s2.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "editing the slotted call's NUMBER is a native-shell change and MUST move the fingerprint")
    }

    /// THE AppA P0 (requirement #2): editing a CONSTANT / lowered `Text` literal /
    /// `spacing:` in a MIXED but AUTO-ROUTED view must NOT churn the fingerprint — that
    /// content rides WASM (OTA-patchable), so the gate must accept the OTA push. A slot
    /// SOURCE edit (native code the thunk bakes in) MUST still churn. Before the fix the
    /// walker refused to strip ANY span of a mixed view, so a pure constant edit was
    /// wrongly refused.
    private func makeMixedAutoRoutedProject() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("patch-fp-mixed-\(UUID().uuidString)")
        let viewURL = root.appendingPathComponent("App/Screen.swift")
        try fm.createDirectory(at: viewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        import SwiftUI
        struct Badge: View {
            let n: Int
            var body: some View { Text("\\(n)") }
        }
        struct Screen: View {
            var body: some View {
                VStack(spacing: 12) {
                    Text("Title")
                    Badge(n: 5)
                }
            }
        }
        """.write(to: viewURL, atomically: true, encoding: .utf8)
        return root
    }

    func testAutoRoutedMixedViewConstantEditIsStableButSlotEditChurns() throws {
        let root = try makeMixedAutoRoutedProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = root.appendingPathComponent("App/Screen.swift")
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()

        // (1) Edit a LOWERED Text literal → rides WASM → fingerprint STABLE.
        var s = try String(contentsOf: view, encoding: .utf8)
        s = s.replacingOccurrences(of: #"Text("Title")"#, with: #"Text("Updated Title")"#)
        try s.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "editing a LOWERED Text literal in an auto-routed mixed view must NOT churn the fingerprint")

        // (2) Edit a LOWERED constant (VStack spacing) → rides WASM → STABLE.
        var s2 = try String(contentsOf: view, encoding: .utf8)
        s2 = s2.replacingOccurrences(of: "VStack(spacing: 12)", with: "VStack(spacing: 20)")
        try s2.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "editing a LOWERED layout constant (spacing) in an auto-routed mixed view must NOT churn")

        // (3) Edit the native SLOT source (the custom-view leaf) → native change → MUST churn.
        var s3 = try String(contentsOf: view, encoding: .utf8)
        s3 = s3.replacingOccurrences(of: "Badge(n: 5)", with: "Badge(n: 6)")
        try s3.write(to: view, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(fp(), base,
            "editing the native slot SOURCE (the custom view) is a native-shell change and MUST churn")
    }

    /// CROSS-FILE reactive-collection consistency: a `ForEach(database.sounds)` over an
    /// @Observable model defined in ANOTHER file lowers (cross-file marshalling), so editing a
    /// literal in its row rides WASM → the fingerprint is STABLE. This is the build↔fingerprint
    /// CONSISTENCY validator: if the fingerprint didn't apply the SAME cross-file resolution the
    /// build does, it wouldn't strip the lowered body and this edit would (wrongly) churn — the
    /// exact P0 failure mode. (Model file has NO `View` text, so it exercises the PASS-0 collect.)
    /// Uses `@StateObject` — a HELD wrapper that marshals safely; the `@Environment(T.self)`
    /// form intentionally DEMOTES (bug #8: its `wrappedValue` traps uncatchably when absent), so
    /// this test isolates the cross-file type-resolution unlock, not the unsafe env-injection path.
    func testCrossFileReactiveForEachLoweredRowEditIsStable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("patch-fp-xfile-\(UUID().uuidString)")
        let viewURL = root.appendingPathComponent("App/Views/SoundsScreen.swift")
        let modelURL = root.appendingPathComponent("App/Services/SoundDatabase.swift")
        try fm.createDirectory(at: viewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        import Observation
        struct Sound { var label: String; var ipa: String }
        @Observable final class SoundDatabase { var sounds: [Sound] = [] }
        """.write(to: modelURL, atomically: true, encoding: .utf8)
        try """
        import SwiftUI
        struct SoundsScreen: View {
            @StateObject private var database = SoundDatabase()
            var body: some View {
                List {
                    ForEach(database.sounds, id: \\.label) { sound in
                        Text("• \\(sound.label)")
                    }
                }
            }
        }
        """.write(to: viewURL, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }
        let base = fp()
        // Edit the LOWERED row literal — the cross-file reactive ForEach rides WASM → STABLE.
        var s = try String(contentsOf: viewURL, encoding: .utf8)
        s = s.replacingOccurrences(of: #"Text("• \(sound.label)")"#, with: #"Text("- \(sound.label)")"#)
        try s.write(to: viewURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(fp(), base,
            "editing a literal in a CROSS-FILE reactive ForEach row that lowers must NOT churn — "
            + "proves the fingerprint applies the SAME cross-file resolution as the build")
    }

    func testExplainReportsObservableReason() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let expl = FingerprintExplain.explain(projectDir: root)
        let model = expl.first { $0.relPath == "App/Model.swift" }
        XCTAssertNotNil(model, "the @Observable getter file should be reported native; got \(expl.map(\.relPath))")
        XCTAssertTrue(model?.dominantReason.localizedCaseInsensitiveContains("observable") == true
                      || model?.dominantReason.localizedCaseInsensitiveContains("state") == true,
                      "reason should mention observable/state; got \(model?.dominantReason ?? "nil")")
        // The pure Math.swift must NOT be flagged native.
        XCTAssertFalse(expl.contains { $0.relPath == "App/Math.swift" },
                       "a pure function file must not appear in the native shell explain")
    }

    // MARK: - P0: fingerprint MUST be invariant to `patchcli prepare`

    /// A real bug report (AppA): a developer registered the fingerprint, then
    /// changed ONE line of text in a SwiftUI view and ran `patchcli release`. Because
    /// `release` now AUTO-RUNS `prepare` (which inserts a `dynamic` modifier on every
    /// `var body` and appends a `// PATCH-THUNKS-BEGIN…END` block), the fingerprint
    /// computed at release time differed from the one registered before prepare ran —
    /// a guaranteed FINGERPRINT MISMATCH on a project whose native shell did not
    /// actually change. The fingerprint MUST be invariant to prepare's scaffolding.
    private func viewFile(prepared: Bool, bodyText: String) -> String {
        let dyn = prepared ? "dynamic " : ""
        var s = """
        import SwiftUI
        struct Greeting: View {
            \(dyn)var body: some View {
                VStack {
                    Text("\(bodyText)")
                    Text("subtitle")
                }
            }
        }
        """
        if prepared {
            s += """

            // PATCH-THUNKS-BEGIN (generated by `patchcli prepare` — DO NOT EDIT)
            // Regenerated wholesale on every `patchcli prepare`.
            #if canImport(SwiftUI)
            import SwiftUI
            import PatchSDK
            extension Greeting {
                @_dynamicReplacement(for: body)
                var __patch_body: some View { Patch.thunkBody(typeName: "Greeting", instance: self) }
            }
            #endif
            // PATCH-THUNKS-END
            """
        }
        return s
    }

    private func fpWithView(_ viewSource: String) throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("patch-fp-prep-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func write(_ rel: String, _ c: String) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try c.write(to: u, atomically: true, encoding: .utf8)
        }
        // A plain native file too, to prove the rest of the shell is untouched.
        try write("App/Service.swift", "final class Service { func go() -> Int { 1 + 1 } }")
        try write("Views/Greeting.swift", viewSource)
        return ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint
    }

    func testFingerprintIsInvariantToPrepareScaffolding() throws {
        // The SAME view, unprepared (register-time) vs prepared (auto-prepare at
        // build/release time), MUST produce the SAME native-shell fingerprint.
        let unprepared = try fpWithView(viewFile(prepared: false, bodyText: "Hello World"))
        let prepared   = try fpWithView(viewFile(prepared: true,  bodyText: "Hello World"))
        XCTAssertEqual(unprepared, prepared,
            "fingerprint must be INVARIANT to `prepare` (dynamic + PATCH-THUNKS block) — registering before prepare then auto-preparing on release must NOT trip the gate")
    }

    func testPatchableBodyEditDoesNotChurnFingerprintWhenPrepared() throws {
        // The core promise under auto-prepare: editing patchable view-body TEXT
        // ("Hello World" → "Settings") on an already-prepared project does not move
        // the native-shell fingerprint.
        let before = try fpWithView(viewFile(prepared: true, bodyText: "Hello World"))
        let after  = try fpWithView(viewFile(prepared: true, bodyText: "Settings"))
        XCTAssertEqual(before, after,
            "editing a patchable SwiftUI body's text must not change the native-shell fingerprint")
    }

    func testStripPatchScaffoldingLeavesDeveloperDynamicIntact() {
        // A developer's OWN `dynamic func` is native shell and must survive stripping;
        // only the prepare-inserted `dynamic var body` is removed.
        let src = """
        class PushService {
            dynamic func register() {}
            dynamic var body: some View { Text("x") }
        }
        """
        let stripped = ProjectFingerprinter.stripPatchScaffolding(src)
        XCTAssertTrue(stripped.contains("dynamic func register"),
                      "developer's own `dynamic func` must be preserved")
        XCTAssertTrue(stripped.contains("var body"), "the body decl stays")
        XCTAssertFalse(stripped.contains("dynamic var body"),
                       "prepare-inserted `dynamic` on `var body` must be stripped")
    }

    // MARK: - Baked configure-fingerprint invariance (the "fingerprint changed
    //         straight after init" P0)

    /// An `@main` App that bakes `fingerprint: "<fp>"` into its `Patch.configure(.init(…))`
    /// call (what `patchcli init` injects). `fingerprint` nil omits the literal entirely.
    private func appWithConfigure(fingerprint: String?, bodyText: String = "Hello World") -> String {
        let fpArg = fingerprint.map { ",\n            fingerprint: \"\($0)\"" } ?? ""
        return """
        import SwiftUI
        import PatchSDK

        @main
        struct DemoApp: App {
            init() {
                Patch.configure(.init(
                    appKey: "pak_demo",
                    appID: "00000000-0000-0000-0000-000000000000"\(fpArg)))
                Task { await Patch.shared.start() }
            }
            var body: some Scene {
                WindowGroup { Greeting() }
            }
        }
        struct Greeting: View {
            var body: some View { Text("\(bodyText)") }
        }
        """
    }

    private func fpWithApp(_ appSource: String) throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("patch-fp-cfg-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let u = root.appendingPathComponent("Sources/DemoApp.swift")
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try appSource.write(to: u, atomically: true, encoding: .utf8)
        return ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint
    }

    func testFingerprintInvariantToBakedConfigureFingerprint() throws {
        // The CORE init→release invariant: the baked `fingerprint:` literal is the hash's
        // OWN output. The SAME app with two DIFFERENT baked values (init bakes it; a later
        // re-register changes it) MUST hash identically — else `init`/`release` would
        // false-MISMATCH on a project the developer never changed.
        let a = try fpWithApp(appWithConfigure(fingerprint: String(repeating: "a", count: 64)))
        let b = try fpWithApp(appWithConfigure(fingerprint: String(repeating: "b", count: 64)))
        XCTAssertEqual(a, b, "the baked configure fingerprint VALUE must not affect the native-shell hash")
        // The PLACEHOLDER `init` injects (before it knows the real fingerprint) must hash the
        // same as a real value, so init can inject placeholder → snapshot → rebake with NO
        // hash movement.
        let placeholder = try fpWithApp(appWithConfigure(
            fingerprint: AppEntryInjector.pendingFingerprintPlaceholder))
        XCTAssertEqual(a, placeholder,
            "placeholder and real fingerprint must hash identically — the rebake is hash-inert")
    }

    func testConfigureCallStructureStillHashed() throws {
        // Only the fingerprint VALUE is excluded. The rest of the configure call (its
        // presence, appKey/appID, the Task line) is real native shell and MUST still affect
        // the hash — a genuine change there is never silently treated OTA-compatible.
        let withConfig = try fpWithApp(appWithConfigure(fingerprint: String(repeating: "a", count: 64)))
        let noConfig = try fpWithApp("""
        import SwiftUI
        @main
        struct DemoApp: App {
            var body: some Scene { WindowGroup { Greeting() } }
        }
        struct Greeting: View {
            var body: some View { Text("Hello World") }
        }
        """)
        XCTAssertNotEqual(withConfig, noConfig,
            "adding/removing the configure call MUST change the native-shell hash")
    }

    func testRebakeFingerprintIsHashInert() throws {
        // End-to-end of the init mechanism: inject configure with the PLACEHOLDER, snapshot,
        // then `rebakeFingerprint` to a real value — the snapshot must be unchanged by the
        // rebake (the value is excluded), so the registered fingerprint stays valid.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("patch-fp-rebake-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let u = root.appendingPathComponent("Sources/DemoApp.swift")
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try appWithConfigure(fingerprint: AppEntryInjector.pendingFingerprintPlaceholder)
            .write(to: u, atomically: true, encoding: .utf8)
        let before = ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint
        XCTAssertTrue(AppEntryInjector.rebakeFingerprint(in: root, to: before))
        let after = ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint
        XCTAssertEqual(before, after, "rebaking the real fingerprint must not move the native-shell hash")
        // And the literal on disk is now the real value (devices report the exact shell).
        let literal = AppEntryInjector.fingerprintLiteral(in: root)
        XCTAssertEqual(literal?.value, before, "rebake must write the real fingerprint to the source literal")
    }
}
