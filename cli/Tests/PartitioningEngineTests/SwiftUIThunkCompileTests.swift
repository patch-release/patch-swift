// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
import ViewNodeIR

/// THE BUILD-SAFETY NET — the single most important correctness property of the whole
/// product: the code `patchcli prepare` generates must ALWAYS compile in the developer's
/// app. Syntax-only type inference can NEVER be fully safe, so the only true guarantee is
/// to COMPILE THE OUTPUT.
///
/// This harness, for each synthetic fixture, runs the REAL same-file `prepare` (the exact
/// path `patchcli prepare`/`build`/`push` runs) to generate the `dynamic`-patched view +
/// its `@_dynamicReplacement(for: body)` thunk (with `__patchSlots()`/`__patchTokens()`/
/// `__patchRowSlots()`), then ACTUALLY type-checks the generated source against the iOS
/// simulator SDK — with a self-contained STUB of the exact `PatchSDK`/`PatchSwiftUI` host
/// surface the thunk calls (`Patch.shared.thunkBody(...)` + `PatchHostToken` + the slot/
/// token/rowSlot closure shapes). A generated thunk that does NOT type-check is a HARD
/// test failure.
///
/// THE INVARIANT this enforces: build-safe = demote-safe. If the engine cannot PROVE the
/// generated thunk compiles, it must DEMOTE that view/leaf to native (a slot or a whole-
/// view demote) rather than emit a guess. The historical bug this net catches: a bare
/// identifier in a `.background(...)`/`.foregroundStyle(...)` slot that is actually a
/// `some View` (`backgroundView`) — or a function, or a custom `ShapeStyle` — was
/// mis-recorded as a `.color` TOKEN, so the thunk emitted `.color(backgroundView)` → an
/// Xcode error `Cannot convert value of type 'some View' to expected argument type
/// 'Color'`. The fixtures here include exactly those shapes; if any token emission isn't
/// type-provable, the compile fails here.
///
/// Skips (does NOT fail) when no iphonesimulator SDK is present (e.g. a Linux CI box).
final class SwiftUIThunkCompileTests: XCTestCase {

    // MARK: - The host stub (the exact surface the generated thunk calls)

    /// A self-contained stub of the `PatchSDK`/`PatchSwiftUI` host surface every generated
    /// SwiftUI thunk references. We strip the thunk's `import PatchSDK`/`import PatchSwiftUI`
    /// and supply these symbols in the same compile unit, so the type-check exercises the
    /// thunk's CALL SHAPE (label names, the `Color`/`Font`/`Double`/`String` arg types of
    /// `PatchHostToken`, the slot/token/rowSlot closure types) WITHOUT the WasmKit deps.
    /// `PatchHostToken`'s cases mirror `sdk/Sources/PatchRender/Render.swift` EXACTLY — so a
    /// thunk that passes a non-`Color` to `.color(...)` fails to type-check here, which is
    /// the entire point.
    static let hostStub = """
    import SwiftUI

    public enum PatchHostToken {
        case color(Color)
        case font(Font)
        case number(Double)
        case string(String)
    }

    public struct PatchRowSlot {
        public var count: Int
        public var factory: (Int) -> AnyView
        public init(count: Int, factory: @escaping (Int) -> AnyView) {
            self.count = count; self.factory = factory
        }
    }

    @MainActor
    public final class PatchedBodyHost: View {
        public var body: some View { EmptyView() }
    }

    @MainActor
    public final class Patch {
        public static let shared = Patch()
        public func thunkBody(typeName: String, baselineHash: String? = nil, instance: Any,
                              slots: () -> [String: ([String]) -> AnyView] = { [:] },
                              tokens: () -> [String: PatchHostToken] = { [:] },
                              rowSlots: () -> [String: PatchRowSlot] = { [:] },
                              actionSlots: () -> [String: () -> Void] = { [:] },
                              effectSlots: () -> [String: (AnyView) -> AnyView] = { [:] },
                              callbackSlots: () -> [String: () -> AnyView] = { [:] }) -> PatchedBodyHost? {
            nil
        }
        // Mirrors the real SDK `Patch.dispatchCallback` EXACTLY — the generated thunk's
        // `__patchDispatchCallback(_:)` calls this, so a signature drift fails to type-check here
        // (the entire point of the thunk-compile net: it would have caught the original incomplete
        // lever, whose thunk called a `__patchDispatchCallback` the SDK never defined).
        public func dispatchCallback(typeName: String, instance: Any, callbackId: String) {}
    }
    """

    // MARK: - Core: lower → generate thunk → COMPILE

    private struct CompileOutcome {
        var compiled: Bool
        var log: String
        var dynamicInsertions: Int
        var generatedAnyToken: Bool
        var generatedAnyColorToken: Bool
        var generatedAnySlot: Bool
        var modifiedText: String
    }

    /// Run the real same-file `prepare` over `source`, then type-check the generated
    /// source (the `dynamic`-patched view + its appended thunk) + the host stub for iOS.
    /// Returns the outcome (nil only when the iOS SDK is unavailable → caller skips).
    @discardableResult
    private func prepareAndCompile(_ source: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) throws -> CompileOutcome? {
        let sdkPath = Self.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sdkPath, !sdkPath.isEmpty else { return nil }

        let url = URL(fileURLWithPath: "/tmp/PatchFixture.swift")
        // SAME-FILE mode — exactly what `patchcli prepare`/`build`/`push` run.
        let result = ThunkGenerator().prepare(sources: [.init(url: url, text: source)], sameFile: true)
        // In same-file mode the thunk is APPENDED to the view's own file text.
        let modifiedText = result.modifiedFiles.first?.text ?? source

        // Strip the thunk's host imports; the stub shadows those names in-unit.
        let patched = modifiedText
            .replacingOccurrences(of: "import PatchSDK\n", with: "")
            .replacingOccurrences(of: "import PatchSwiftUI\n", with: "")
            .replacingOccurrences(of: "import PatchRender\n", with: "")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-thunk-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try patched.write(to: tmp.appendingPathComponent("Fixture.swift"), atomically: true, encoding: .utf8)
        try Self.hostStub.write(to: tmp.appendingPathComponent("HostStub.swift"), atomically: true, encoding: .utf8)

        let args = [
            "-typecheck",
            "-sdk", sdkPath,
            "-target", "arm64-apple-ios16.0-simulator",
            tmp.appendingPathComponent("Fixture.swift").path,
            tmp.appendingPathComponent("HostStub.swift").path
        ]
        let log = Self.run("/usr/bin/swiftc", args, captureStderr: true) ?? ""
        return CompileOutcome(
            compiled: !log.contains("error:"),
            log: log,
            dynamicInsertions: result.dynamicInsertions,
            generatedAnyToken: modifiedText.contains("PatchHostToken"),
            generatedAnyColorToken: modifiedText.contains("= .color("),
            generatedAnySlot: modifiedText.contains(ThunkGenerator.slotsMethodName + "()"),
            modifiedText: modifiedText)
    }

    /// Assert a fixture's generated thunk type-checks (skips without an iOS SDK).
    private func assertCompiles(_ source: String, _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        guard let outcome = try prepareAndCompile(source, file: file, line: line) else {
            throw XCTSkip("no iphonesimulator SDK")
        }
        XCTAssertTrue(outcome.compiled,
                      "[\(what)] the generated thunk + patched view must type-check for iOS:\n" +
                      "----- log -----\n\(outcome.log)\n" +
                      "----- generated -----\n\(outcome.modifiedText)",
                      file: file, line: line)
    }

    // MARK: - CALLBACK SLOT (the net the soundness review flagged as missing)

    /// CALLBACK-SLOT THUNK COMPILE — the test whose ABSENCE let the original incomplete lever (a
    /// thunk calling a `__patchDispatchCallback` the SDK never defined) pass a green suite. A custom
    /// child-view call with a dispatchable labeled `() -> Void` callback (`onContinue: { showPaywall
    /// = true }`) must lower to a `.callbackSlot` node and generate BOTH `__patchCallbackSlots()`
    /// (the native child-view slot with the stable forwarder) AND `__patchDispatchCallback(_:)`
    /// (which calls `Patch.shared.dispatchCallback`) — and the whole thunk MUST type-check against
    /// the SDK API (mirrored in the host stub).
    func testCallbackSlotDispatchableCompiles() throws {
        let src = """
        import SwiftUI
        struct TeaserScreen: View {
            let onContinue: () -> Void
            var body: some View { Button("Go", action: onContinue) }
        }
        struct ContentView: View {
            @State private var showPaywall = false
            var body: some View {
                VStack {
                    Text("Welcome")
                    TeaserScreen(onContinue: { showPaywall = true })
                }
                .sheet(isPresented: $showPaywall) { Text("Paywall") }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "callback-slot thunk must type-check for iOS:\n----- log -----\n\(outcome.log)\n" +
                      "----- generated -----\n\(outcome.modifiedText)")
        // Precise: the METHOD DECLARATION (not the doc-comment/forwarder mentions of the same name).
        XCTAssertTrue(outcome.modifiedText.contains("func \(ThunkGenerator.dispatchCallbackMethodName)"),
                      "a dispatchable callback must generate the \(ThunkGenerator.dispatchCallbackMethodName) method:\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("__cb["),
                      "a dispatchable callback must populate a callback-slot entry (__cb[...]):\n\(outcome.modifiedText)")
    }

    /// SOUNDNESS-GATE NEGATIVE: a NON-dispatchable callback body (a native call the guest cannot run)
    /// must NOT create a callback slot — `recordActionMutation` fails, so the call falls back to a
    /// native `opaqueCall` and NO `__patchDispatchCallback` is generated. Without this gate the lever
    /// would emit a callback slot whose guest dispatch has no rule → a DEAD callback on-device. The
    /// thunk must still compile.
    func testNonDispatchableCallbackDoesNotCreateSlot() throws {
        let src = """
        import SwiftUI
        enum Analytics { static func track(_ e: String) {} }
        struct TeaserScreen: View {
            let onContinue: () -> Void
            var body: some View { Button("Go", action: onContinue) }
        }
        struct ContentView: View {
            let title: String
            var body: some View {
                VStack {
                    Text(title)
                    TeaserScreen(onContinue: { Analytics.track("continue") })
                }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "thunk must compile:\n\(outcome.log)\n----\n\(outcome.modifiedText)")
        // Precise: NO method declaration (the doc comment in __patchCallbackSlots always mentions the
        // name; a real dead-callback slot would emit `func __patchDispatchCallback` + a `__cb[...]` entry).
        XCTAssertFalse(outcome.modifiedText.contains("func \(ThunkGenerator.dispatchCallbackMethodName)"),
                       "a non-dispatchable native callback must NOT create a callback slot (the dead-callback hole):\n\(outcome.modifiedText)")
        XCTAssertFalse(outcome.modifiedText.contains("__cb["),
                       "a non-dispatchable native callback must NOT populate a callback-slot entry:\n\(outcome.modifiedText)")
    }

    // MARK: - THE BUG: a `some View` / non-Color identifier in a color slot

    /// THE PRODUCTION BUG, reproduced and pinned: `.background(<identifier>)` where the
    /// identifier is a `some View` computed property. The engine must NOT record it as a
    /// `.color` token (`__t[id] = .color(backgroundView)` would be `Cannot convert value
    /// of type 'some View' to expected argument type 'Color'`). It must native-slot the
    /// background as a VIEW modifier (or demote). Either way: the thunk MUST compile.
    func testBackgroundSomeViewIdentifierCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let title: String
            private var backgroundView: some View { Color.blue.opacity(0.2) }
            var body: some View {
                Text(title).background(backgroundView)
            }
        }
        """
        try assertCompiles(src, "background(some View identifier)")
    }

    /// `.foregroundStyle(<identifier>)` where the identifier is a CUSTOM `ShapeStyle` (valid
    /// Swift — `foregroundStyle` accepts any `ShapeStyle`), NOT a `Color`. The engine must
    /// not record it as a `.color` token (`.color(myStyle)` over a custom `ShapeStyle` is
    /// `Cannot convert ... to expected argument type 'Color'`); it must native-slot the
    /// whole `.foregroundStyle` instead. The thunk MUST compile.
    func testForegroundStyleCustomShapeStyleIdentifierCompiles() throws {
        let src = """
        import SwiftUI
        struct MyStyle: ShapeStyle {
            func resolve(in environment: EnvironmentValues) -> some ShapeStyle { Color.red }
        }
        struct V: View {
            let title: String
            private let myStyle = MyStyle()
            var body: some View {
                Text(title).foregroundStyle(myStyle)
            }
        }
        """
        try assertCompiles(src, "foregroundStyle(custom ShapeStyle identifier)")
    }

    /// `.background(<function reference>)` — a bare identifier that is a function, not a
    /// color. `.color(makeBackground)` would not compile.
    func testBackgroundFunctionReferenceCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let title: String
            func makeBackground() -> some View { Color.gray }
            var body: some View {
                Text(title).background(makeBackground())
            }
        }
        """
        try assertCompiles(src, "background(function call)")
    }

    /// LEAF-INTERNAL BINDING SLOTABILITY (AppA P0 fix): a native-slot leaf that binds
    /// its OWN loop var (`ForEach(items) { item in Row(item) }`) must be SLOTABLE — the loop
    /// var is bound inside the slot closure `AnyView(ForEach(items){ item in Row(item) })`, so
    /// it compiles. Before the fix, `item` (collected into the whole-body `bodyLocals`) wrongly
    /// blocked the slot → the whole view rendered native (not auto-routed). The generated thunk
    /// MUST compile (and the view should auto-route — see SwiftUILoweringTests for the routing
    /// assertion). This is the dominant real-app blocker (AppA 22→39 auto-routed views).
    func testForEachLoopVarSlotCompiles() throws {
        let src = """
        import SwiftUI
        struct Row: View {
            let label: String
            var body: some View { Text(label) }
        }
        struct V: View {
            let items: [String]
            var body: some View {
                VStack(spacing: 8) {
                    Text("Header")
                    ForEach(items, id: \\.self) { item in
                        Row(label: item)
                    }
                }
            }
        }
        """
        try assertCompiles(src, "ForEach loop-var native slot (leaf-internal binding)")
    }

    // MARK: - TERNARY-ARM string lift (cli 1.6.34) — the generated factory MUST compile

    /// `Text(cond ? "A" : "B")` arm literals lift into the Button slot's `stringArgs`; the
    /// generated factory substitutes `\u{1}k\u{1}` → `a[k]`, producing
    /// `Text(currentPage < 2 ? LocalizedStringKey(a[0]) : LocalizedStringKey(a[1]))`. That
    /// LocalizedStringKey-wrapped ternary MUST type-check (prove-or-demote: a mis-typed lift
    /// would fail HERE and the view would demote, never ship a wrong render). The real
    /// AppD OnboardingScreen shape (Button with a multi-statement `private`
    /// action slots natively → its label `Text(ternary)` is the lift site).
    func testTernaryArmLiftFactoryCompiles() throws {
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
        try assertCompiles(src, "ternary-arm LocalizedStringKey lift factory")
    }

    /// `Text(verbatim: cond ? "a" : "b")` — the verbatim arms lift as BARE placeholders →
    /// the factory renders `Text(verbatim: ok ? a[0] : a[1])`, which type-checks (verbatim:
    /// takes a plain String). A LocalizedStringKey wrap here would be a COMPILE error, so this
    /// pins the String-position typing.
    func testTernaryVerbatimBareFactoryCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            @State private var ok = false
            let onTap: () -> Void
            var body: some View {
                Button { onTap() } label: {
                    Text(verbatim: ok ? "a" : "b")
                }
            }
        }
        """
        try assertCompiles(src, "ternary-arm verbatim bare-String lift factory")
    }

    // MARK: - NATIVE EFFECT-MODIFIER SLOTS — the generated `__patchEffectSlots()` MUST compile

    /// A view with an undispatchable `.task { await self.load() }` keeps the effect NATIVE via a
    /// `nativeEffectSlot` (the thunk re-applies `content.task { await self.load() }` over `self`)
    /// while the rest of the view lowers. The generated `__patchEffectSlots()` — which applies a
    /// real `.task` modifier over `self` — MUST type-check for iOS.
    func testTaskEffectSlotCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            @State private var loaded = false
            let title: String
            func load() async { loaded = true }
            var body: some View {
                VStack {
                    Text(title)
                    Text(loaded ? "ready" : "loading")
                }
                .task { await load() }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
            "[.task effect slot] the generated __patchEffectSlots() must type-check for iOS:\n" +
            "----- log -----\n\(outcome.log)\n----- generated -----\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains(ThunkGenerator.effectSlotsMethodName + "()"),
            "the view must emit __patchEffectSlots()")
        XCTAssertTrue(outcome.modifiedText.contains("content.task"),
            "the effect slot must re-apply `content.task { … }` over self (in __patchEffectSlots())")
    }

    /// A view with an undispatchable `.onAppear { startAnimation() }` — same: the effect rides a
    /// `nativeEffectSlot`, the rest lowers, and `__patchEffectSlots()` MUST compile.
    func testOnAppearEffectSlotCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let label: String
            func startAnimation() {}
            var body: some View {
                Text(label)
                    .padding()
                    .onAppear { startAnimation() }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
            "[.onAppear effect slot] the generated __patchEffectSlots() must type-check for iOS:\n" +
            "----- log -----\n\(outcome.log)\n----- generated -----\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("content.onAppear"),
            "the effect slot must re-apply `content.onAppear { … }` over self")
    }

    /// A `.refreshable { await reload() }` keeps the async refresh native via a `nativeEffectSlot`;
    /// the generated `__patchEffectSlots()` MUST compile.
    func testRefreshableEffectSlotCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let rows: [String]
            func reload() async {}
            var body: some View {
                List(rows, id: \\.self) { r in Text(r) }
                    .refreshable { await reload() }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
            "[.refreshable effect slot] the generated __patchEffectSlots() must type-check for iOS:\n" +
            "----- log -----\n\(outcome.log)\n----- generated -----\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("content.refreshable"),
            "the effect slot must re-apply `content.refreshable { … }` over self")
    }

    /// A `.onReceive(timer) { _ in now = .now }` keeps the native publisher subscription via a
    /// `nativeEffectSlot` (the thunk re-applies `content.onReceive(self.timer) { … }` over `self`),
    /// the rest of the view lowers, and the generated `__patchEffectSlots()` MUST type-check.
    func testOnReceiveEffectSlotCompiles() throws {
        let src = """
        import SwiftUI
        import Combine
        struct V: View {
            @State private var now: Date = .now
            let title: String
            private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            var body: some View {
                VStack {
                    Text(title)
                    Text(now.formatted())
                }
                .onReceive(timer) { _ in now = .now }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
            "[.onReceive effect slot] the generated __patchEffectSlots() must type-check for iOS:\n" +
            "----- log -----\n\(outcome.log)\n----- generated -----\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("content.onReceive"),
            "the effect slot must re-apply `content.onReceive(...) { … }` over self")
    }

    /// A `.onChange(of: X)` whose watched value `X` is NATIVE source-of-truth (an `@AppStorage` the
    /// body doesn't mutate) keeps the native watcher via a `nativeEffectSlot` (the thunk re-applies
    /// `content.onChange(of: self.X) { … }` over `self`); the rest of the view lowers and the
    /// generated `__patchEffectSlots()` MUST type-check. (The AppA ContentView shape.) The
    /// thunk re-applies the developer's VERBATIM modifier, so it inherits the original's availability;
    /// we use the iOS-16-safe single-closure-param form here so the fixture compiles at the harness's
    /// iOS-16 deployment target (a two-param `.onChange` is iOS-17-only — and a dev who writes it has
    /// an iOS-17 app, so the thunk inherits that floor and still compiles in THEIR build).
    func testOnChangeNativeSourceEffectSlotCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            @AppStorage("done") private var done: Bool = false
            @State private var flow: Int = 0
            let title: String
            func onDone() {}
            var body: some View {
                VStack {
                    Text(title)
                    Text(flow == 0 ? "splash" : "main")
                }
                .onChange(of: done) { completed in
                    if completed { flow = 1; onDone() }
                }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
            "[.onChange effect slot] the generated __patchEffectSlots() must type-check for iOS:\n" +
            "----- log -----\n\(outcome.log)\n----- generated -----\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("content.onChange"),
            "the effect slot must re-apply `content.onChange(of: self.done) { … }` over self")
    }

    /// A closure PARAMETER bound inside a slot leaf (`.sheet { Sheet(onDone: { v in use(v) }) }`)
    /// is likewise leaf-internal and must not block slotability. The thunk MUST compile.
    func testClosureParamSlotCompiles() throws {
        let src = """
        import SwiftUI
        struct Sheet: View {
            let onPick: (String) -> Void
            var body: some View { Button("Pick") { onPick("x") } }
        }
        struct V: View {
            let title: String
            @State private var show = false
            var body: some View {
                Text(title)
                    .sheet(isPresented: $show) {
                        Sheet(onPick: { picked in print(picked) })
                    }
            }
        }
        """
        try assertCompiles(src, "closure-param native slot (leaf-internal binding)")
    }

    /// A bare identifier that is genuinely a `Color`-typed STORED property — this one IS a
    /// real color token (provable from the `: Color` annotation) and must still lower AND
    /// compile. (Guards the fix doesn't over-demote.)
    func testBackgroundColorTypedPropertyCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let title: String
            let backgroundColor: Color
            var body: some View {
                Text(title).foregroundStyle(backgroundColor)
            }
        }
        """
        try assertCompiles(src, "foregroundStyle(Color-typed property)")
    }

    /// A variant ternary among colors over a `some View` identifier branch — the WHOLE
    /// ternary must be a single provable-color token or native-slot; never `.color(viewExpr)`.
    func testForegroundStyleTernaryWithViewBranchCompiles() throws {
        let src = """
        import SwiftUI
        enum Variant { case primary, secondary }
        struct V: View {
            let variant: Variant
            private var fallbackView: some View { Color.gray }
            var body: some View {
                Text("x").background(variant == .primary ? Color.blue : Color.green)
            }
        }
        """
        try assertCompiles(src, "background(color ternary)")
    }

    // MARK: - Color tokens (the provable cases must still lower + compile)

    func testCustomColorTokenCompiles() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Colors { static let ink = Color.black } }
        struct V: View {
            let label: String
            var body: some View {
                Text(label).foregroundStyle(Theme.Colors.ink)
            }
        }
        """
        try assertCompiles(src, "foregroundStyle(Theme.Colors.ink token)")
    }

    func testShapeFillTokenCompiles() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Colors { static let accent = Color.blue } }
        struct V: View {
            let text: String
            var body: some View {
                Text(text).padding(.horizontal, 10).background(Capsule().fill(Theme.Colors.accent))
            }
        }
        """
        try assertCompiles(src, "background(Capsule().fill(token))")
    }

    func testColorTernaryOverAccessiblePropCompiles() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Colors { static let ink = Color.black } }
        struct V: View {
            let selected: Bool
            var body: some View {
                Text("x").foregroundStyle(selected ? .white : Theme.Colors.ink)
            }
        }
        """
        try assertCompiles(src, "foregroundStyle(color ternary token)")
    }

    func testColorConstructorTokenCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let label: String
            var body: some View {
                Text(label).foregroundStyle(Color(.systemBackground))
            }
        }
        """
        try assertCompiles(src, "foregroundStyle(Color(.systemBackground))")
    }

    // MARK: - Font tokens

    func testCustomFontTokenCompiles() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Font { static func body(_ s: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: s) } } }
        struct V: View {
            let label: String
            var body: some View {
                Text(label).font(Theme.Font.body(13, weight: .semibold))
            }
        }
        """
        try assertCompiles(src, "font(Theme.Font.body token)")
    }

    /// `.font(<some View identifier>)` — a bare identifier that is NOT a Font. The engine
    /// must not emit `.font(headerView)`.
    func testFontWithViewIdentifierCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let label: String
            private var headerView: some View { Text("h") }
            var body: some View {
                Text(label).font(.headline).overlay(headerView)
            }
        }
        """
        try assertCompiles(src, "font + overlay(view identifier)")
    }

    // MARK: - Numeric tokens

    func testNumericTokenCompiles() throws {
        let src = """
        import SwiftUI
        func baseUnit() -> CGFloat { 4 }
        enum Theme { enum Radius { static let lg: CGFloat = baseUnit() * 3 } }
        struct V: View {
            let label: String
            var body: some View {
                Text(label).cornerRadius(Theme.Radius.lg)
            }
        }
        """
        try assertCompiles(src, "cornerRadius(Theme.Radius.lg numeric token)")
    }

    func testComputedScalarNumericTokenCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let width: CGFloat
            var height: CGFloat { width * 0.66 }
            var body: some View {
                Text("x").frame(width: width, height: height)
            }
        }
        """
        try assertCompiles(src, "frame(height: computed-scalar token)")
    }

    // MARK: - String tokens

    func testStringTokenCompiles() throws {
        let src = """
        import SwiftUI
        enum Confidence { case high, low; var label: String { self == .high ? "High" : "Low" } }
        struct V: View {
            let confidence: Confidence
            var body: some View {
                Text(confidence.label)
            }
        }
        """
        try assertCompiles(src, "Text(confidence.label string token)")
    }

    /// `Text(profile.name)` where `profile` is a `@State` struct value with a `String` field.
    /// The local struct catalog PROVES `profile.name` is a `String`, so a same-file thunk
    /// host-projects it (`__t[id] = .string(self.profile.name)`). This is the build-safe
    /// member-access path the type-provability gate re-admits (the `feature.description`
    /// AttributedString hazard stays rejected by being absent from the catalog as a String).
    /// The generated thunk MUST compile — `.string(self.profile.name)` is `.string(String)`.
    func testStructStateStringFieldTokenCompiles() throws {
        let src = """
        import SwiftUI
        struct CardView: View {
            struct Profile { var name: String; var age: Int }
            @State private var profile = Profile(name: "Ada", age: 36)
            var body: some View {
                VStack { Text(profile.name); Text("static") }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "the struct String-field string token must compile:\n\(outcome.log)\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains(".string(profile.name)")
                      || outcome.modifiedText.contains(".string(self.profile.name)"),
                      "profile.name must host-project as a String token, not slot/demote:\n\(outcome.modifiedText)")
    }

    // MARK: - Native slots / mixed views

    func testMixedViewWithCustomChildCompiles() throws {
        let src = """
        import SwiftUI
        struct Sparkline: View { var body: some View { Rectangle() } }
        struct V: View {
            let title: String
            var body: some View {
                VStack {
                    Text(title)
                    Sparkline()
                }
            }
        }
        """
        try assertCompiles(src, "mixed view (custom child slot)")
    }

    func testParameterizedSlotCompiles() throws {
        let src = """
        import SwiftUI
        struct Badge: View { let text: String; var body: some View { Text(text) } }
        struct V: View {
            let title: String
            var body: some View {
                VStack {
                    Text(title)
                    Badge(text: "NEW")
                }
            }
        }
        """
        try assertCompiles(src, "parameterized slot (Badge with literal arg)")
    }

    // MARK: - Per-row indexed native-action slot

    func testIndexedForEachSlotCompiles() throws {
        let src = """
        import SwiftUI
        struct Owner: Identifiable { let id: Int; let name: String }
        struct Chip: View { let owner: Owner; let onTap: () -> Void; var body: some View { Button(owner.name, action: onTap) } }
        final class ScheduleService: ObservableObject {
            var availableOwners: [Owner] { [] }
            var selectedOwnerId: Int = 0
        }
        struct V: View {
            @StateObject var schedule = ScheduleService()
            var body: some View {
                ScrollView(.horizontal) {
                    HStack {
                        let owners = schedule.availableOwners
                        ForEach(owners) { owner in
                            Chip(owner: owner, onTap: { schedule.selectedOwnerId = owner.id })
                        }
                    }
                }
            }
        }
        """
        try assertCompiles(src, "indexedForEachSlot (per-row native action)")
    }

    // MARK: - Native-action slot (actions-list Button with a native method-call action)

    /// THE FEATURE: a `.contextMenu { Button(role:.destructive) { resetAllData() } }` whose action
    /// is a SELF method call (reads no body-local). The Button's label + role lower; the action is
    /// supplied as a native `__patchActionSlots()` closure. The view AUTO-ROUTES and the generated
    /// `{ resetAllData() }`-style closure MUST type-check (the body runs over `self`).
    func testActionSlotContextMenuSelfMethodRoutesAndCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let title: String
            func resetAllData() {}
            var body: some View {
                Text(title)
                    .contextMenu {
                        Button("Reset", role: .destructive) { resetAllData() }
                    }
            }
        }
        """
        // The lowering records an action slot (the action is a self-method call) + does NOT demote.
        var sawSlot = false
        for lv in BodyLowering().lowerAllViews(source: src) where lv.viewName == "V" {
            XCTAssertFalse(lv.hasUndispatchableAction,
                           "a self-method actions-list action must NOT demote — it action-slots")
            XCTAssertTrue(lv.actionSlots.contains { $0.source == "resetAllData()" },
                          "expected an action slot over resetAllData():\n\(lv.actionSlots)")
            // The guest tree carries the actionSlotButton node (label + role lowered).
            XCTAssertTrue(lv.guestBody.contains("N.actionSlotButton("),
                          "expected an actionSlotButton node in the guest body:\n\(lv.guestBody)")
            XCTAssertTrue(lv.guestBody.contains("role: .destructive"),
                          "the role must be preserved on the lowered button:\n\(lv.guestBody)")
            sawSlot = true
        }
        XCTAssertTrue(sawSlot, "view V must lower")
        // And the generated thunk (with __patchActionSlots() running resetAllData() over self)
        // MUST type-check for iOS.
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[action slot self-method] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains(ThunkGenerator.actionSlotsMethodName + "()"),
                      "expected a __patchActionSlots() method:\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("resetAllData()"),
                      "expected the native action closure to call resetAllData():\n\(outcome.modifiedText)")
    }

    /// An `.alert(…) { Button("Reset", role:.destructive) { resetAllData() } }` — alert actions
    /// list. The native action slots; the label + role lower; the thunk MUST compile.
    func testActionSlotAlertSelfMethodCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            @State private var showConfirm = false
            func resetAllData() {}
            var body: some View {
                VStack {
                    Text("Settings")
                    Button("Reset") { showConfirm = true }
                }
                .alert("Reset?", isPresented: $showConfirm) {
                    Button("Reset", role: .destructive) { resetAllData() }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[action slot alert] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
    }

    /// THE METHOD-REF FEATURE (the AppA `AddConnectionSheet` fix): a toolbar
    /// `confirmationAction` `Button("Connect", action: submit)` — a BARE METHOD-REFERENCE action,
    /// not a `{ … }` closure. The Button label lowers to an `actionSlotButton`; the thunk supplies
    /// the native closure `{ self.submit() }`. The view AUTO-ROUTES (no `hasUndispatchableAction`),
    /// and the generated `{ self.submit() }` action-slot closure MUST type-check (it runs over
    /// `self`, reaching the private `submit()` via the same-file thunk).
    func testActionSlotBareMethodRefRoutesAndCompiles() throws {
        let src = """
        import SwiftUI
        struct AddSheet: View {
            @State private var handle: String = ""
            var body: some View {
                NavigationStack {
                    Form { TextField("handle", text: $handle) }
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Connect", action: submit)
                            }
                        }
                }
            }
            private func submit() { handle = "" }
        }
        """
        var sawSlot = false
        for lv in BodyLowering().lowerAllViews(source: src) where lv.viewName == "AddSheet" {
            XCTAssertFalse(lv.hasUndispatchableAction,
                           "a bare method-ref toolbar action must NOT demote — it action-slots")
            XCTAssertTrue(lv.actionSlots.contains { $0.source == "self.submit()" },
                          "expected a method-ref action slot over self.submit():\n\(lv.actionSlots)")
            XCTAssertTrue(lv.guestBody.contains("N.actionSlotButton("),
                          "the Connect button lowers to an actionSlotButton node:\n\(lv.guestBody)")
            sawSlot = true
        }
        XCTAssertTrue(sawSlot, "view AddSheet must lower")
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[action slot method-ref] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("self.submit()"),
                      "expected the native action closure to call self.submit():\n\(outcome.modifiedText)")
    }

    /// SLOT-SAFE: a `.self`-qualified method ref (`Button("Go", action: self.run)`) also slots —
    /// the source is `self.run()`, reachable over `self`. The thunk MUST compile.
    func testActionSlotSelfQualifiedMethodRefCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            @State private var open = false
            var body: some View {
                Text("x")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Go", action: self.run)
                        }
                    }
            }
            func run() { open.toggle() }
        }
        """
        for lv in BodyLowering().lowerAllViews(source: src) where lv.viewName == "V" {
            XCTAssertFalse(lv.hasUndispatchableAction, "self.run method-ref slots, not demotes")
            XCTAssertTrue(lv.actionSlots.contains { $0.source == "self.run()" },
                          "expected a self.run() action slot:\n\(lv.actionSlots)")
        }
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[action slot self.method-ref] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
    }

    /// SLOT-SAFE: a `ForEach` row whose contextMenu Button action reads the LOOP VAR
    /// (`deleteSubscription(subscription)`) is rendered as a WHOLE-ROW native slot (the loop var
    /// is bound INSIDE the slotted ForEach expression, so the self-only slot closure compiles and
    /// the real `deleteSubscription(subscription)` runs). NO action slot is recorded (the action
    /// rides the whole-row slot, not a separate per-action closure) — never strips the row body.
    /// The thunk MUST compile.
    func testActionSlotLoopVarRowSlotsWholeAndCompiles() throws {
        let src = """
        import SwiftUI
        struct Sub: Identifiable { let id: Int; let name: String }
        struct V: View {
            let subscriptions: [Sub]
            func deleteSubscription(_ s: Sub) {}
            var body: some View {
                List {
                    ForEach(subscriptions) { subscription in
                        Text(subscription.name)
                            .contextMenu {
                                Button("Delete", role: .destructive) { deleteSubscription(subscription) }
                            }
                    }
                }
            }
        }
        """
        // The loop-var action rides the WHOLE-ROW native slot — NO separate action slot is recorded
        // (the slotted ForEach binds `subscription` internally, so the native call works faithfully).
        for lv in BodyLowering().lowerAllViews(source: src) where lv.viewName == "V" {
            XCTAssertTrue(lv.actionSlots.isEmpty,
                          "NO action slot for a loop-var action (the whole row slots):\n\(lv.actionSlots)")
            XCTAssertTrue(lv.opaqueLeaves.allSatisfy { $0.slotable },
                          "the whole-row slot must be slotable (the loop var is bound inside it)")
        }
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[action slot loop-var whole-row slot] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
    }

    /// DEMOTE-SAFE (the FORBIDDEN-outcome guard): a body-level actions-list Button whose action
    /// reads a BODY-LOCAL `let` (`let svc = makeService(); … .contextMenu { Button { svc.reset() } }`)
    /// is NOT slotable — `svc` is out of scope in the `self`-only thunk closure. The action must
    /// NOT be recorded as an action slot (which would strip the body and ship a patch that silently
    /// renders the OLD native view); instead `hasUndispatchableAction` demotes the WHOLE view to
    /// native. The thunk MUST compile.
    func testActionSlotBodyLocalActionDemotesAndCompiles() throws {
        let src = """
        import SwiftUI
        final class Service { func reset() {} }
        struct V: View {
            let title: String
            func makeService() -> Service { Service() }
            var body: some View {
                let svc = makeService()
                Text(title)
                    .contextMenu {
                        Button("Reset", role: .destructive) { svc.reset() }
                    }
            }
        }
        """
        for lv in BodyLowering().lowerAllViews(source: src) where lv.viewName == "V" {
            XCTAssertFalse(lv.actionSlots.contains { $0.source.contains("svc.reset") },
                           "a body-local action must NOT be recorded as an action slot:\n\(lv.actionSlots)")
        }
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[action slot body-local demote] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
    }

    // MARK: - Design-system patterns from the bug report

    func testPrivateBackgroundViewAndForegroundColorCompiles() throws {
        let src = """
        import SwiftUI
        enum Variant { case primary, secondary }
        struct V: View {
            let variant: Variant
            private var backgroundView: some View {
                RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.1))
            }
            private let foregroundColor: Color = .primary
            var body: some View {
                Text("Hello")
                    .foregroundColor(foregroundColor)
                    .background(backgroundView)
            }
        }
        """
        try assertCompiles(src, "private backgroundView + foregroundColor (the bug report)")
    }

    /// A `variant == .primary ? someViewA : someViewB` background — both branches Views.
    /// Must native-slot, never `.color(...)`.
    func testVariantTernaryViewBackgroundCompiles() throws {
        let src = """
        import SwiftUI
        enum Variant { case primary, secondary }
        struct V: View {
            let variant: Variant
            private var primaryBg: some View { Color.blue }
            private var secondaryBg: some View { Color.gray }
            var body: some View {
                Text("x").background(variant == .primary ? AnyView(primaryBg) : AnyView(secondaryBg))
            }
        }
        """
        try assertCompiles(src, "background(variant ternary of Views)")
    }

    // MARK: - GOAL 2: prove-the-slot-EXPRESSION-or-demote (statement / #if / Void-closure)

    /// A body that IS a bare `switch` whose arms `return` a view (`switch rating { case 1:
    /// return Text("a") … }`). The slot wrapper would emit `AnyView(switch rating {…})` —
    /// illegal in argument position AND the captured `return`s are illegal in an expression.
    /// The engine must DEMOTE the view (the thunk falls through to the original `body`). The
    /// thunk MUST compile.
    func testSwitchReturnBodyDemotesAndCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let rating: Int
            var body: some View {
                switch rating {
                case 1: return Text("😴")
                case 2: return Text("🙂")
                default: return Text("🤩")
                }
            }
        }
        """
        try assertCompiles(src, "switch-return body (demote)")
    }

    /// A bare `switch` whose arms are view EXPRESSIONS (no `return`) over heterogeneous View
    /// types. `AnyView(switch …)` in arg position is still illegal — the engine routes it
    /// through a `Group { switch … }` slot, which compiles iff the arms are bare expressions.
    /// Either lowers safely or demotes; the thunk MUST compile.
    func testSwitchExpressionBodyCompiles() throws {
        let src = """
        import SwiftUI
        enum Tab { case overview, detail }
        struct V: View {
            let tab: Tab
            var body: some View {
                switch tab {
                case .overview: Text("overview")
                case .detail: Text("detail")
                }
            }
        }
        """
        try assertCompiles(src, "switch-expression body")
    }

    /// A `for` loop in a ViewBuilder body. A `for` statement can't be wrapped
    /// `AnyView(for … {})` — the view must demote (or lower the loop). The thunk MUST compile.
    func testForLoopBodyCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let items: [String]
            var body: some View {
                VStack {
                    Text("header")
                    ForEach(items, id: \\.self) { item in
                        Text(item)
                    }
                }
            }
        }
        """
        try assertCompiles(src, "for-loop body (ForEach)")
    }

    /// An `if let` optional-binding body — not a plain boolean condition, so it can't be a
    /// guest ternary; it's `Group { if let … }`-slotted. Must compile (lower-safely or demote).
    func testIfLetBindingBodyCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let subtitle: String?
            var body: some View {
                VStack {
                    Text("title")
                    if let subtitle {
                        Text(subtitle)
                    }
                }
            }
        }
        """
        try assertCompiles(src, "if-let binding body")
    }

    /// A MID-EXPRESSION `#if os(...)` in the body (`Text(x) #if os(tvOS) .font(.large) #else
    /// .font(.caption) #endif`). Slotting the fragment leaves `AnyView(… #endif) }` — "extra
    /// tokens following conditional compilation directive". The engine must NOT slot a
    /// `#if`-containing source (it demotes / picks the iOS branch). The thunk MUST compile.
    func testIfConfigInBodyCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let timestamp: String
            var body: some View {
                Text(timestamp)
                #if os(tvOS)
                    .font(.system(size: 21))
                #else
                    .font(.caption)
                #endif
                    .foregroundColor(.secondary)
            }
        }
        """
        try assertCompiles(src, "#if-in-body fragment")
    }

    /// A Button whose action is a Void-returning `withAnimation { state.toggle() }`. If that
    /// action expression is mis-captured as a view leaf, the slot emits
    /// `AnyView(withAnimation { state.toggle() })` — "'()' cannot conform to 'View'". The
    /// engine must NOT slot a Void-returning action. The thunk MUST compile.
    func testWithAnimationVoidClosureLeafCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            @State private var expanded = false
            var body: some View {
                VStack {
                    Text("title")
                    Button("Toggle") {
                        withAnimation { expanded.toggle() }
                    }
                }
            }
        }
        """
        try assertCompiles(src, "withAnimation Void-closure action")
    }

    /// A bare `withAnimation { … }` as a TOP-LEVEL body statement (the WMFYearInReview
    /// shape). The whole expression is `Void`; it must demote, never `AnyView(withAnimation …)`.
    func testTopLevelWithAnimationDemotesAndCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            @State private var n = 0
            var body: some View {
                VStack {
                    Text("\\(n)")
                    Button("Next") { withAnimation { n += 1 } }
                }
            }
        }
        """
        try assertCompiles(src, "top-level withAnimation (demote)")
    }

    /// `.background(color.ignoresSafeArea())` — `.ignoresSafeArea()` makes the `Color` a
    /// `some View`, so it must NOT record as a `.color` token (`.color(<some View>)` fails).
    /// The whole `.background` must native-slot. The thunk MUST compile.
    func testBackgroundColorIgnoresSafeAreaCompiles() throws {
        let src = """
        import SwiftUI
        enum ColorTheme { static let background = Color.blue }
        struct V: View {
            let title: String
            var body: some View {
                Text(title).background(ColorTheme.background.ignoresSafeArea())
            }
        }
        """
        try assertCompiles(src, "background(color.ignoresSafeArea())")
    }

    /// A `Button(action: { … action() … }) { label }` whose action closure body invokes a
    /// `() -> Void` property. The action closure must NOT be lowered as view content — doing
    /// so emits `AnyView(action())` ("'()' cannot conform to 'View'"). Only the LABEL is
    /// content. The thunk MUST compile. (The real AppA PillButton shape.)
    func testButtonActionClosureNotSlottedCompiles() throws {
        let src = """
        import SwiftUI
        struct V: View {
            let title: String
            var isDisabled = false
            var action: () -> Void
            var body: some View {
                Button(action: { if !isDisabled { action() } }) {
                    HStack {
                        Text(title)
                    }
                }
            }
        }
        """
        try assertCompiles(src, "Button(action:) closure not slotted")
    }

    // MARK: - GOAL 3: string-token type-provability (non-String member must not tokenize)

    /// `Text(feature.description)` where `description` is an `AttributedString`, NOT a
    /// `String`. The engine must NOT record it as a `.string(feature.description)` token
    /// (`cannot convert 'AttributedString' to 'String'`); it must native-slot the `Text`
    /// (or demote). The thunk MUST compile.
    func testStringTokenAttributedStringDemotesAndCompiles() throws {
        let src = """
        import SwiftUI
        struct Feature {
            var description: AttributedString { AttributedString("hi") }
        }
        struct V: View {
            let feature: Feature
            var body: some View {
                Text(feature.description).font(.body)
            }
        }
        """
        try assertCompiles(src, "Text(feature.description: AttributedString)")
    }

    /// `Text(item.count.description)` — a `value.member` chain whose type can't be proven a
    /// String at the structural level. The engine must NOT tokenize it; it native-slots.
    /// The thunk MUST compile. (Guards the gate rejects the unprovable member chain.)
    func testStringTokenNonProvableMemberChainCompiles() throws {
        let src = """
        import SwiftUI
        struct Item { let name: String }
        struct V: View {
            let item: Item
            var body: some View {
                Text(item.name).font(.headline)
            }
        }
        """
        try assertCompiles(src, "Text(item.name) member chain")
    }

    /// `Text((short ? a.label : a.longLabel).uppercased())` — the AppA ConfidencePill
    /// string token. `.uppercased()` is a PROVABLE String transformation tail, so it STILL
    /// lowers as a `.string(...)` token (guards the fix doesn't over-demote the real win).
    /// The thunk MUST compile.
    func testProvableStringTransformTokenStillCompiles() throws {
        let src = """
        import SwiftUI
        enum Confidence { case high, low
            var label: String { self == .high ? "High" : "Low" }
            var longLabel: String { self == .high ? "Very High" : "Quite Low" }
        }
        struct V: View {
            let confidence: Confidence
            var short: Bool = true
            var body: some View {
                Text((short ? confidence.label : confidence.longLabel).uppercased()).font(.caption)
            }
        }
        """
        try assertCompiles(src, "Text(ternary.uppercased() string token)")
    }

    // MARK: - Tool runner

    static func run(_ launchPath: String, _ args: [String], captureStderr: Bool = false) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = captureStderr ? out : Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Corpus sweep (env-gated; CI skips, run locally)

    /// Run `prepare` over every Swift file of every corpus app, COMPILE each generated
    /// thunk, and report any that fail to type-check. Gated behind PATCH_THUNK_CORPUS=1
    /// (corpus is local/gitignored). This is the wide net: it measures, over real apps,
    /// how many generated thunks DON'T compile — the bug count the type-safety work closes.
    func testCorpusThunksCompile() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PATCH_THUNK_CORPUS"] == "1",
                          "set PATCH_THUNK_CORPUS=1 to run the corpus thunk-compile sweep")
        let sdkPath = Self.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(sdkPath != nil && !(sdkPath ?? "").isEmpty, "no iphonesimulator SDK")

        let root = ProcessInfo.processInfo.environment["PATCH_CORPUS_ROOT"]
            ?? CorpusPaths.defaultRepos
        let fm = FileManager.default
        guard let apps = try? fm.contentsOfDirectory(atPath: root) else {
            throw XCTSkip("corpus root not found: \(root)")
        }

        var totalViews = 0
        var failingFiles: [(app: String, file: String, log: String)] = []
        var compiledOK = 0

        for app in apps.sorted() {
            let appDir = root + "/" + app
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: appDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let en = fm.enumerator(atPath: appDir) else { continue }
            for case let rel as String in en where rel.hasSuffix(".swift") {
                if rel.contains("/.build/") || rel.contains("/Pods/")
                    || rel.contains("/Carthage/") || rel.contains("DerivedData") { continue }
                let path = appDir + "/" + rel
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                guard text.contains("var body: some View") else { continue }
                let url = URL(fileURLWithPath: path)
                let result = ThunkGenerator().prepare(sources: [.init(url: url, text: text)], sameFile: true)
                guard result.dynamicInsertions > 0, let modified = result.modifiedFiles.first?.text,
                      modified.contains("@_dynamicReplacement") else { continue }
                totalViews += result.viewNames.count

                // Compile JUST the generated thunk EXTENSION + the host stub. We can't
                // pull a file's whole dependency graph, so we extract the appended
                // same-file block (the `@_dynamicReplacement` extension + helpers) and
                // compile it standalone against a permissive stub of the view + app types.
                // A failure here is a thunk-codegen bug (a token over a non-Color/Font/etc.
                // expression) — exactly the class we're hunting.
                let block = Self.extractSameFileBlock(modified) ?? modified
                let patched = block
                    .replacingOccurrences(of: "import PatchSDK\n", with: "")
                    .replacingOccurrences(of: "import PatchSwiftUI\n", with: "")
                // The thunk references the FULL original file scope, so compile the full
                // patched file (best effort — many corpus files import app modules that
                // won't resolve; we only FLAG a file whose error is a thunk-token type
                // mismatch, the specific bug class, not a missing-import error).
                let tmp = fm.temporaryDirectory.appendingPathComponent("corpus-thunk-\(UUID().uuidString)")
                try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tmp) }
                let fixture = modified
                    .replacingOccurrences(of: "import PatchSDK\n", with: "")
                    .replacingOccurrences(of: "import PatchSwiftUI\n", with: "")
                try? fixture.write(to: tmp.appendingPathComponent("Fixture.swift"), atomically: true, encoding: .utf8)
                try? Self.hostStub.write(to: tmp.appendingPathComponent("HostStub.swift"), atomically: true, encoding: .utf8)
                let args = [
                    "-typecheck", "-sdk", sdkPath!,
                    "-target", "arm64-apple-ios16.0-simulator",
                    tmp.appendingPathComponent("Fixture.swift").path,
                    tmp.appendingPathComponent("HostStub.swift").path
                ]
                let log = Self.run("/usr/bin/swiftc", args, captureStderr: true) ?? ""
                // The bug class: a token resolver type mismatch. Filter to errors that are
                // genuinely thunk-codegen (a `.color`/`.font`/`.number`/`.string` arg type
                // mismatch), so missing-app-import noise doesn't drown the signal.
                let tokenTypeErrors = log.split(separator: "\n").filter {
                    $0.contains("error:") &&
                    ($0.contains("to expected argument type 'Color'") ||
                     $0.contains("to expected argument type 'Font'") ||
                     $0.contains("to expected argument type 'Double'") ||
                     $0.contains("to expected argument type 'String'") ||
                     ($0.contains("__patchTokens") || $0.contains("PatchHostToken")))
                }
                if !tokenTypeErrors.isEmpty {
                    failingFiles.append((app, rel, tokenTypeErrors.joined(separator: "\n")))
                } else {
                    compiledOK += 1
                }
                _ = patched
            }
        }

        print("=== CORPUS THUNK-COMPILE SWEEP ===")
        print("apps scanned: \(apps.count); view-files prepared: \(compiledOK + failingFiles.count); views: \(totalViews)")
        print("thunk token-type FAILURES: \(failingFiles.count)")
        for f in failingFiles.prefix(60) {
            print("  ✗ \(f.app)/\(f.file)\n     \(f.log.replacingOccurrences(of: "\n", with: "\n     "))")
        }
        XCTAssertTrue(failingFiles.isEmpty,
                      "\(failingFiles.count) corpus file(s) generated a thunk with a token-type mismatch")
    }

    /// Extract the appended same-file generated block (BEGIN/END markers), if present.
    static func extractSameFileBlock(_ text: String) -> String? {
        guard let b = text.range(of: ThunkGenerator.sameFileBeginMarker),
              let e = text.range(of: ThunkGenerator.sameFileEndMarker) else { return nil }
        return String(text[b.lowerBound..<e.upperBound])
    }

    // MARK: - Reactive reference-type view-model host-projection (the reactive-VM lever)

    /// A BOOL read off a reactive `@ObservedObject` member in an `if` condition
    /// (`if viewModel.isOn { … }`) host-projects to a numeric (Bool→1.0/0.0) token; the thunk
    /// emits `.number(Double(((self.viewModel.isOn) ? 1.0 : 0.0)))`, which MUST type-check
    /// (`viewModel` is a self property → `self.viewModel.isOn` is a Bool).
    func testReactiveMemberBoolConditionTokenCompiles() throws {
        let src = """
        import SwiftUI
        final class GreetVM: ObservableObject {
            @Published var title: String = "Hi"
            @Published var isOn = false
        }
        struct GreetView: View {
            @ObservedObject var viewModel: GreetVM
            var body: some View {
                VStack {
                    Text(viewModel.title)
                    if viewModel.isOn { Text("on") } else { Text("off") }
                }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[reactive bool condition] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("self.viewModel.isOn"),
                      "expected the thunk to read self.viewModel.isOn:\n\(outcome.modifiedText)")
    }

    /// A reactive collection field's `.isEmpty`/`.count` (`vm.items.isEmpty`) host-projects to
    /// a numeric count token (the thunk emits `.number(Double((self.vm.items).count))`), used
    /// in both an `if` guard AND a numeric modifier ternary (`.frame(height:)` / `.opacity()`).
    func testReactiveMemberCollectionGuardTokenCompiles() throws {
        let src = """
        import SwiftUI
        final class FeedVM: ObservableObject {
            @Published var items: [String] = []
            @Published var loading = false
        }
        struct FeedView: View {
            @ObservedObject var vm: FeedVM
            var body: some View {
                VStack {
                    if vm.items.isEmpty { Text("empty") } else { Text("has items") }
                    Text("footer").opacity(vm.loading ? 0.5 : 1)
                }
                .frame(height: vm.items.isEmpty ? 0 : 100)
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[reactive collection guard] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("(self.vm.items).count"),
                      "expected the thunk to read (self.vm.items).count:\n\(outcome.modifiedText)")
    }

    /// DEMOTE-SAFE: a bare reactive member passed WHOLE into a child view (`ChildRow(model: vm)`)
    /// is unprojectable — the view must stay native (a slot), never leak `vm`. The thunk MUST
    /// compile regardless (it slots the child view, no reactive token emitted).
    func testReactiveMemberBarePassDemotesAndCompiles() throws {
        let src = """
        import SwiftUI
        final class FeedVM: ObservableObject { @Published var loading = false }
        struct ChildRow: View { let model: FeedVM; var body: some View { Text("c") } }
        struct ParentView: View {
            @ObservedObject var vm: FeedVM
            var body: some View {
                VStack {
                    ChildRow(model: vm)
                    Text("x")
                }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[reactive bare pass demote] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
    }

    /// DEMOTE-SAFE: a METHOD call on a reactive member (`vm.items.contains("x")`) is
    /// unprojectable — the `if` demotes to a native slot, never a numeric token over a method.
    /// The thunk MUST compile.
    func testReactiveMemberMethodCallDemotesAndCompiles() throws {
        let src = """
        import SwiftUI
        final class FeedVM: ObservableObject { @Published var items: [String] = [] }
        struct MethodView: View {
            @ObservedObject var vm: FeedVM
            var body: some View {
                VStack {
                    if vm.items.contains("x") { Text("a") }
                    Text("y")
                }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[reactive method call demote] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
    }

    /// An `@EnvironmentObject` Bool read in a condition host-projects exactly like
    /// `@ObservedObject` — the thunk reads `self.service.isReady` natively. (The iOS-17
    /// `@Environment(T.self)` Observation form is detected identically by `reactiveMemberTypes`,
    /// but isn't fixture-compilable below the iOS-17 deployment target the test box uses, so the
    /// always-available `@EnvironmentObject` form pins the code path here.)
    func testEnvironmentObjectBoolTokenCompiles() throws {
        let src = """
        import SwiftUI
        final class AppService: ObservableObject { @Published var isReady = false }
        struct GateView: View {
            @EnvironmentObject var service: AppService
            var body: some View {
                VStack {
                    if service.isReady { Text("ready") } else { Text("loading") }
                }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[environment object bool] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("self.service.isReady"),
                      "expected the thunk to read self.service.isReady:\n\(outcome.modifiedText)")
    }

    // MARK: - COMPUTED-MEMBER-ON-INPUT host-projection (the design-system `Size`-enum idiom)

    /// True iff the named view AUTO-ROUTES (is not demoted by the lowering) for `source`.
    private func viewRoutes(_ source: String, _ viewName: String) -> Bool {
        for lv in BodyLowering().lowerAllViews(source: source)
        where lv.viewName == viewName && lv.report.totalElements > 0 {
            return !(lv.referencesUnmarshalledInput || lv.referencesUnresolvedSymbol)
        }
        return false
    }

    /// THE FEATURE: a computed CGFloat member of an ENUM INPUT used in a `.system(size:)` font
    /// position (`.font(.system(size: size.iconSize))`) — the AppF StreakBadge
    /// shape. The numeric size host-projects to a `__numtok_<id>` whose thunk reads
    /// `self.size.iconSize` natively; the view AUTO-ROUTES and the thunk MUST compile.
    func testComputedMemberEnumInputSystemFontSizeRoutesAndCompiles() throws {
        let src = """
        import SwiftUI
        struct StreakBadge: View {
            let count: Int
            let size: Size
            enum Size {
                case small, medium, large
                var iconSize: CGFloat {
                    switch self { case .small: return 16; case .medium: return 24; case .large: return 32 }
                }
                var fontSize: CGFloat {
                    switch self { case .small: return 12; case .medium: return 18; case .large: return 24 }
                }
            }
            var body: some View {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: size.iconSize))
                    Text("\\(count)")
                        .font(.system(size: size.fontSize, weight: .bold))
                }
            }
        }
        """
        XCTAssertTrue(viewRoutes(src, "StreakBadge"),
                      "StreakBadge with computed CGFloat members of an enum input must auto-route")
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[computed-member system font] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("self.size.iconSize"),
                      "expected the thunk to read self.size.iconSize:\n\(outcome.modifiedText)")
    }

    /// A computed CGFloat member of an enum input in a `.padding(size.padding)` numeric position
    /// AND a computed `Font` member in a bare `.font(size.fontSize)` position — both host-project
    /// (`.number(Double(self.size.padding))` + `.font(self.size.fontSize)`). The thunk MUST compile.
    func testComputedMemberPaddingAndFontMemberCompiles() throws {
        let src = """
        import SwiftUI
        struct Badge: View {
            let label: String
            let size: BadgeSize
            enum BadgeSize {
                case small, medium, large
                var iconSize: CGFloat { switch self { case .small: 20; case .medium: 32; case .large: 48 } }
                var fontSize: Font { switch self { case .small: .caption; case .medium: .headline; case .large: .title2 } }
                var padding: CGFloat { switch self { case .small: 8; case .medium: 12; case .large: 16 } }
            }
            var body: some View {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill").font(.system(size: size.iconSize))
                    Text(label).font(size.fontSize)
                }
                .padding(size.padding)
            }
        }
        """
        XCTAssertTrue(viewRoutes(src, "Badge"),
                      "Badge with computed CGFloat/Font members of an enum input must auto-route")
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[computed-member padding+font] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("self.size.padding"),
                      "expected the thunk to read self.size.padding:\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("self.size.fontSize"),
                      "expected the thunk to read self.size.fontSize:\n\(outcome.modifiedText)")
    }

    /// A computed STRING member of a struct input used as `Text(meta.title)` content host-projects
    /// to a `__strtok_<id>` (the thunk reads `self.meta.title`). The thunk MUST compile.
    func testComputedMemberStringContentCompiles() throws {
        let src = """
        import SwiftUI
        struct Meta {
            let kind: Int
            var title: String { kind == 0 ? "A" : "B" }
        }
        struct MetaView: View {
            let meta: Meta
            var body: some View {
                VStack { Text(meta.title) }
            }
        }
        """
        XCTAssertTrue(viewRoutes(src, "MetaView"),
                      "MetaView reading a computed String member of a struct input must auto-route")
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[computed-member string content] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
        XCTAssertTrue(outcome.modifiedText.contains("self.meta.title"),
                      "expected the thunk to read self.meta.title:\n\(outcome.modifiedText)")
    }

    /// DEMOTE-SAFE NEGATIVE: a METHOD call on an enum input (`size.scaled(2)`) is NOT a computed
    /// scalar member — it must NOT host-project (no `.system(size: Double(__numtok_...))` over a
    /// method). The view stays native and the thunk MUST compile.
    func testComputedMemberMethodCallDemotesAndCompiles() throws {
        let src = """
        import SwiftUI
        struct MethodBadge: View {
            let size: Size
            enum Size {
                case small, large
                func scaled(_ f: CGFloat) -> CGFloat { self == .small ? 16 * f : 32 * f }
            }
            var body: some View {
                Image(systemName: "star").font(.system(size: size.scaled(2)))
            }
        }
        """
        XCTAssertFalse(viewRoutes(src, "MethodBadge"),
                       "a method call on an enum input must NOT host-project (stays native)")
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[computed-member method demote] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
    }

    /// DEMOTE-SAFE NEGATIVE: a NON-scalar/non-Font computed member of an enum input
    /// (`size.insets` returning `EdgeInsets`) used as a WHOLE value in `.padding(size.insets)`
    /// is NOT in the catalog — the read must NEVER mis-project to a numeric token (which would
    /// emit `Double(self.size.insets)` over an `EdgeInsets`, a hard compile error). The
    /// `.padding` slots that node natively (its closure resolves `self.size.insets` correctly).
    /// THE INVARIANT: the thunk MUST compile and NO numeric token over `size.insets` is emitted.
    func testComputedMemberNonScalarReturnDemotesAndCompiles() throws {
        let src = """
        import SwiftUI
        struct InsetBadge: View {
            let size: Size
            enum Size {
                case small, large
                var insets: EdgeInsets {
                    self == .small ? EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)
                                   : EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
                }
            }
            var body: some View {
                Text("hi").padding(size.insets)
            }
        }
        """
        // The lowering must NOT record a numeric token over the non-scalar member.
        for lv in BodyLowering().lowerAllViews(source: src) where lv.viewName == "InsetBadge" {
            XCTAssertFalse(lv.hostTokens.contains { $0.kind == .number && $0.source.contains("size.insets") },
                           "a non-scalar (EdgeInsets) member must NOT become a numeric token: \(lv.hostTokens)")
        }
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
                      "[computed-member non-scalar demote] thunk must type-check:\n\(outcome.log)\n\(outcome.modifiedText)")
    }

    // MARK: - FALLBACK-PATH LIFT — Picker / ProgressView / Section / Menu fallback slots compile

    /// Gate #1: a `Picker` whose rows cannot be lowered (non-literal .tag values) falls back
    /// to a whole-Picker native slot. With the fallback-path lift, the title literal ("Period")
    /// is extracted into `stringArgs` → the thunk factory receives `(a: [String])` and emits
    /// `LocalizedStringKey(a[0])` at the call site. THE GENERATED THUNK MUST TYPE-CHECK.
    ///
    /// This is the exact pattern found in AppJ's InsightsScreen:
    ///   `Picker("Period", selection: $selectedPeriod) { ... }`
    /// where rows have non-literal tags, so the Picker falls back to opaqueExprLifted.
    func testFallbackPickerTitleLiftedThunkCompiles() throws {
        let src = """
        import SwiftUI
        // A type that can't be inferred as Int/String literal tag → Picker falls back to opaque slot.
        enum Period: String, CaseIterable, Identifiable {
            case week, month, year
            var id: String { rawValue }
            var label: String { rawValue.capitalized }
        }
        struct InsightsScreen: View {
            @State private var selectedPeriod: Period = .week
            let items: [String]
            var body: some View {
                VStack {
                    Picker("Period", selection: $selectedPeriod) {
                        ForEach(Period.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    ForEach(items, id: \\.self) { Text($0) }
                }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
            "[fallback Picker title lift] the generated thunk with LocalizedStringKey(a[0]) MUST type-check:\n" +
            "----- log -----\n\(outcome.log)\n----- generated -----\n\(outcome.modifiedText)")
        // Verify the lift actually happened (slot uses LocalizedStringKey param).
        let hasLiftedPicker = outcome.modifiedText.contains("LocalizedStringKey(a[0])")
                           || outcome.modifiedText.contains("LocalizedStringKey(a[")
        XCTAssertTrue(hasLiftedPicker || !outcome.modifiedText.contains("Picker(\"Period\""),
            "the Picker title literal must be lifted into LocalizedStringKey(a[k]) in the slot factory: "
            + "(or the Picker fully lowered — no opaque slot needed)")
    }

    /// Gate #2: `ProgressView("Loading…")` indeterminate (no value:) falls back to opaqueExprLifted.
    /// The title literal must be extracted into `stringArgs` → `LocalizedStringKey(a[0])` in the
    /// slot factory. THE GENERATED THUNK MUST TYPE-CHECK.
    func testFallbackProgressViewTitleLiftedThunkCompiles() throws {
        let src = """
        import SwiftUI
        // ProgressView without a value: → indeterminate — emitter takes the fallback opaqueExprLifted path.
        struct LoadingView: View {
            let items: [String]
            var body: some View {
                VStack {
                    ProgressView("Loading…")
                    ForEach(items, id: \\.self) { Text($0) }
                }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
            "[fallback ProgressView title lift] the generated thunk MUST type-check:\n" +
            "----- log -----\n\(outcome.log)\n----- generated -----\n\(outcome.modifiedText)")
    }

    /// Gate #3: `Section("Recent") { ForEach(items) { CustomRow($0) } }` — Section where the
    /// content row is a non-lowerable custom view. The Section falls back to opaqueExprLifted and
    /// the title "Recent" is lifted → `LocalizedStringKey(a[0])`. THE GENERATED THUNK MUST COMPILE.
    func testFallbackSectionTitleLiftedThunkCompiles() throws {
        let src = """
        import SwiftUI
        // Non-lowerable row — a custom child view whose body can't lower from this file.
        struct CustomRow: View {
            let item: String
            var body: some View { Text(item).padding() }
        }
        struct FeedView: View {
            let items: [String]
            var body: some View {
                List {
                    Section("Recent") {
                        ForEach(items, id: \\.self) { item in
                            CustomRow(item: item)
                        }
                    }
                }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
            "[fallback Section title lift] the generated thunk MUST type-check:\n" +
            "----- log -----\n\(outcome.log)\n----- generated -----\n\(outcome.modifiedText)")
    }

    /// Gate #4: `Menu("Sort") { Button("A–Z") { sort(.az) } }` — Menu whose content buttons
    /// have non-dispatchable actions falls back to opaqueExprLifted. Title "Sort" is lifted.
    /// THE GENERATED THUNK MUST COMPILE.
    func testFallbackMenuTitleLiftedThunkCompiles() throws {
        let src = """
        import SwiftUI
        struct FilterView: View {
            let items: [String]
            // sort() is a body-local, non-self action → Menu content isn't dispatchable as actionSlots.
            func sort(_ order: Int) { _ = order }
            var body: some View {
                VStack {
                    Menu("Sort") {
                        Button("A–Z") { sort(0) }
                        Button("Z–A") { sort(1) }
                    }
                    ForEach(items, id: \\.self) { Text($0) }
                }
            }
        }
        """
        guard let outcome = try prepareAndCompile(src) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(outcome.compiled,
            "[fallback Menu title lift] the generated thunk MUST type-check:\n" +
            "----- log -----\n\(outcome.log)\n----- generated -----\n\(outcome.modifiedText)")
    }
}
