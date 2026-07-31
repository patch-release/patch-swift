// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// NATIVE EFFECT-MODIFIER SLOTS (the #1 effect-coverage fix): a view with an undispatchable
/// EFFECT modifier (`.task { await load() }`/`.onAppear`/`.refreshable`/`.onSubmit`/gesture)
/// USED to demote the WHOLE view (`hasUndispatchableEffect`), so editing UNRELATED text inside
/// it couldn't ship OTA. Now the effect is kept NATIVE via a `nativeEffectSlot` modifier (the
/// build-time thunk re-applies the real modifier over `self`) while the REST of the view lowers —
/// so the view auto-routes. DEMOTE-SAFE: only a FIDELITY-SAFE + thunk-reachable effect is slotted;
/// an effect reading a body-local/`private` member or an animation-driving effect keeps the
/// `hasUndispatchableEffect` demote (the dev's native view renders, never a stripped body whose
/// effect can't be supplied).
///
/// onChange-coverage pass: `.onChange(of: X)` and `.onReceive(publisher)` now ALSO slot via the
/// effect mechanism, with a stricter gate — `.onChange` slots ONLY when the watched value `X` is
/// NATIVE SOURCE-OF-TRUTH (the guest body does NOT mutate it via dispatch). A GUEST-OWNED watched
/// value (a `@State` the body itself mutates) keeps the `hasUndispatchableEffect` demote (faithful
/// firing of a native `.onChange(of: self.X)` over the guest's own writeback round-trip is unproven —
/// conservative = correct). `.onReceive` slots like `.task` (a native publisher + native closure).
final class SwiftUIEffectSlotTests: XCTestCase {

    // MARK: - 1. The headline fix: `.task` no longer demotes — it slots + the view auto-routes.

    func testTaskEffectIsSlottedNotDemoted() throws {
        let source = """
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
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
            "a slottable .task must NOT demote the whole view")
        XCTAssertFalse(lowered.effectSlots.isEmpty, "the .task is recorded as a native effect slot")
        XCTAssertTrue(lowered.effectSlots.contains { $0.applySource.contains("content.task")
                        && $0.applySource.contains("load()") },
            "the effect slot re-applies the real .task over content/self: \(lowered.effectSlots)")
        // The emitted guest body keeps the effect as a nativeEffectSlot modifier.
        XCTAssertTrue(lowered.guestBody.contains("nativeEffectSlot(id:"),
            "the body lowers the .task to a nativeEffectSlot modifier: \(lowered.guestBody)")
        // And the view AUTO-ROUTES (it would not have before — hasUndispatchableEffect blocked it).
        XCTAssertTrue(ProjectFingerprinter.isAutoRouted(lowered, collidingBases: []),
            "the view auto-routes now that its only effect-block reason is a slotted effect")
    }

    // MARK: - 1b. `.highPriorityGesture` / `.onHover` (BUG FIXES) slot instead of demoting.

    /// BUG #5: `highPriorityGesture`/`simultaneousGesture` passed their literal name to GATE 1,
    /// which only allowlists "gesture" → GATE 1 always failed → demote, despite the slot path being
    /// written. Fix passes "gesture" for GATE 1; the slot's applySource is rebuilt from the REAL call.
    func testHighPriorityGestureSlottedNotDemoted() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var confirmed = false
            let label: String
            func confirm() { confirmed = true }
            var body: some View {
                Text(label).padding()
                    .highPriorityGesture(TapGesture().onEnded { confirm() })
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
            "a self-reachable highPriorityGesture must slot, not demote the whole view")
        XCTAssertTrue(lowered.effectSlots.contains { $0.applySource.contains("content.highPriorityGesture") },
            "the slot re-applies the REAL highPriorityGesture (the name arg only selects GATE 1): \(lowered.effectSlots)")
        XCTAssertTrue(ProjectFingerprinter.isAutoRouted(lowered, collidingBases: []))
    }

    /// DEMOTE-SAFETY: a gesture handler reading a BODY-LOCAL (not self-reachable in the
    /// cross-file thunk) is NOT slotable → must still demote (never an uncompilable slot).
    func testGestureReadingBodyLocalStillDemotes() throws {
        let source = """
        import SwiftUI
        struct V: View {
            let label: String
            var body: some View {
                let token = label.uppercased()
                return Text(label)
                    .highPriorityGesture(TapGesture().onEnded { _ = token })
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertTrue(lowered.hasUndispatchableEffect || lowered.effectSlots.isEmpty,
            "a gesture handler reading a body-local `token` is not slotable → demote-safe")
    }

    // MARK: - 2. `.onAppear` with a method call (the canonical demote) now slots + auto-routes.

    func testOnAppearEffectIsSlotted() throws {
        let source = """
        import SwiftUI
        struct V: View {
            let label: String
            func startAnimation() {}
            var body: some View {
                Text(label).padding().onAppear { startAnimation() }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertFalse(lowered.hasUndispatchableEffect)
        XCTAssertTrue(lowered.effectSlots.contains { $0.applySource.contains("content.onAppear") })
        XCTAssertTrue(ProjectFingerprinter.isAutoRouted(lowered, collidingBases: []))
    }

    // MARK: - 3. KEPT-DEMOTED: a GUEST-OWNED `.onChange(of:)` watched value stays demoted.

    /// A `.onChange(of: X)` whose watched value `X` the GUEST BODY mutates (a `@State` written by a
    /// Button dispatch) is GUEST-OWNED. Faithfully firing a native `.onChange(of: self.X)` over the
    /// guest's writeback round-trip is unproven (re-entrancy / ordering), so it must KEEP the
    /// `hasUndispatchableEffect` demote — NOT slot — so the dev's real native `.onChange` runs.
    func testGuestMutatedOnChangeStaysDemoted() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var count = 0
            let title: String
            func log() {}
            var body: some View {
                VStack {
                    Text(title)
                    Button("inc") { count += 1 }
                }
                .onChange(of: count) { _, _ in log() }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertTrue(lowered.hasUndispatchableEffect,
            "a GUEST-MUTATED .onChange watched value must keep the whole-view demote")
        XCTAssertTrue(lowered.effectSlots.isEmpty,
            "the guest-owned .onChange must NOT be a native effect slot: \(lowered.effectSlots)")
        XCTAssertFalse(ProjectFingerprinter.isAutoRouted(lowered, collidingBases: []))
    }

    // MARK: - 3b. SLOTS: a NATIVE-source-of-truth `.onChange(of:)` is faithful via the effect slot.

    /// A `.onChange(of: X)` whose watched value `X` is NATIVE SOURCE-OF-TRUTH — an `@Environment`
    /// service property (`auth.uid`) or an `@AppStorage` the body does NOT mutate — slots via the
    /// effect mechanism: the thunk applies the REAL `.onChange(of: self.X) { … }` over the rendered
    /// subtree, where SwiftUI's own machinery fires it on the real change of the live `self.X`,
    /// identical to native. The REST of the view then lowers (vs. the old whole-view demote).
    /// This is the AppA ContentView fix (`.onChange(of: auth.uid)` + `.onChange(of: hasOnboarded)`).
    func testNativeSourceOnChangeSlots() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @Environment(AuthService.self) private var auth
            @State private var schedule: ScheduleService?
            @State private var flow: Int = 0
            @AppStorage("k") private var hasOnboarded: Bool = false
            var body: some View {
                VStack {
                    Text("hi")
                }
                .onChange(of: auth.uid) { _, newUid in
                    if let newUid, let schedule { schedule.ensureProfile(for: newUid) }
                }
                .onChange(of: hasOnboarded) { _, done in
                    if !done { flow = 1 }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
            "a native-source-of-truth .onChange must NOT demote the whole view")
        XCTAssertEqual(lowered.effectSlots.count, 2,
            "both .onChange modifiers slot as native effect slots: \(lowered.effectSlots)")
        XCTAssertTrue(lowered.effectSlots.contains {
            $0.applySource.contains("content.onChange(of: auth.uid)") },
            "the auth.uid .onChange re-applies the real modifier over self: \(lowered.effectSlots)")
        XCTAssertTrue(lowered.effectSlots.contains {
            $0.applySource.contains("content.onChange(of: hasOnboarded)") },
            "the hasOnboarded .onChange re-applies the real modifier over self: \(lowered.effectSlots)")
        XCTAssertTrue(lowered.guestBody.contains("nativeEffectSlot(id:"),
            "the body lowers each .onChange to a nativeEffectSlot modifier")
        XCTAssertTrue(ProjectFingerprinter.isAutoRouted(lowered, collidingBases: []),
            "the view auto-routes now that its .onChange watchers slot natively")
    }

    // MARK: - 3c. SLOTS: `.onReceive(publisher)` keeps only the effect native (not the whole subtree).

    /// `.onReceive(timer) { _ in now = .now }` fires on a NATIVE publisher event and runs its closure
    /// natively over `self`, exactly like `.task`. It slots via the effect mechanism — so the INNER
    /// content lowers (vs. the old whole-subtree opaque native leaf). This is the AppA
    /// HomeScreen fix (its `.onReceive(timer)` used to slot the whole ScrollView as one native leaf).
    func testOnReceiveSlots() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var now: Date = .now
            private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            var body: some View {
                ScrollView {
                    VStack { Text("a"); Text("b") }
                }
                .onReceive(timer) { _ in now = .now }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertFalse(lowered.hasUndispatchableEffect)
        XCTAssertTrue(lowered.effectSlots.contains {
            $0.applySource.contains("content.onReceive(timer)") },
            "the .onReceive re-applies the real modifier over self: \(lowered.effectSlots)")
        // The inner content lowers — it is NOT swallowed into one big opaque native leaf.
        XCTAssertTrue(lowered.opaqueLeaves.isEmpty,
            "the ScrollView/VStack/Text content must lower, not slot as one opaque leaf: \(lowered.opaqueLeaves.map { $0.label })")
        XCTAssertTrue(ProjectFingerprinter.isAutoRouted(lowered, collidingBases: []))
    }

    // MARK: - 4. KEPT-DEMOTED: an effect driving `withAnimation` must stay demoted (fidelity).

    func testEffectWithAnimationStaysDemoted() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var shown = false
            let title: String
            var body: some View {
                Text(title).onAppear { withAnimation { shown = true } }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertTrue(lowered.effectSlots.isEmpty,
            "an effect closure driving withAnimation must NOT be slotted (unproven through the guest boundary)")
    }

    // MARK: - 5. KEPT-DEMOTED: an effect reading an INACCESSIBLE (`private`, separate-file) member.

    /// In SEPARATE-FILE thunk placement (`sameFileThunk: false`), a `private`/`fileprivate` member
    /// the cross-file thunk can't reach must BLOCK the effect slot — exactly like the opaque-leaf /
    /// action-slot slotability gate — so the view keeps the `hasUndispatchableEffect` demote rather
    /// than emit a thunk that won't compile. (Same-file placement reaches it; this asserts the
    /// cross-file gate.)
    func testEffectReadingInaccessibleMemberStaysDemoted() throws {
        let source = """
        import SwiftUI
        struct V: View {
            let label: String
            private func secretLoad() async {}
            var body: some View {
                Text(label).task { await secretLoad() }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source, sameFileThunk: false).first)
        XCTAssertTrue(lowered.effectSlots.isEmpty,
            "an effect reading a `private` member is out of a CROSS-FILE thunk's scope → must NOT be slotted: \(lowered.effectSlots)")
        XCTAssertTrue(lowered.hasUndispatchableEffect,
            "an un-slottable (cross-file-private) effect keeps the whole-view demote")
    }

    /// CONVERSELY: with SAME-FILE placement the thunk reaches the `private` member, so the SAME
    /// `.task { await secretLoad() }` DOES slot (the view auto-routes). This is the placement that
    /// `ThunkGenerator` uses for a private-member view (HYBRID same-file factoring).
    func testEffectReadingPrivateMemberSlotsSameFile() throws {
        let source = """
        import SwiftUI
        struct V: View {
            let label: String
            private func secretLoad() async {}
            var body: some View {
                Text(label).task { await secretLoad() }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source, sameFileThunk: true).first)
        XCTAssertFalse(lowered.effectSlots.isEmpty,
            "same-file placement reaches the private member, so the .task slots")
        XCTAssertFalse(lowered.hasUndispatchableEffect)
    }

    // MARK: - 6. FINGERPRINT: the effect source is folded into the native surface.

    /// Editing the native effect closure churns `nativeSurface` (a native-shell change → MISMATCH),
    /// while editing the lowered body text does NOT. Prove the effect source is in `nativeSurface`.
    func testEffectSourceFoldedIntoNativeSurface() throws {
        let source = """
        import SwiftUI
        struct V: View {
            let title: String
            func load() async {}
            var body: some View {
                Text(title).task { await load() }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let surface = ProjectFingerprinter.nativeSurface(of: lowered)
        XCTAssertTrue(surface.contains("E:"), "the effect slot is folded into the native surface")
        XCTAssertTrue(surface.contains("load()"),
            "the native effect source is in the surface (so editing it churns the hash): \(surface)")
    }

    // MARK: - 7. THE GUEST WASM-COMPILE NET (the gap that let a real bug ship).
    //
    // The `nativeEffectSlot(id:)` IR node is emitted as `<base>.nativeEffectSlot(id: "...")` —
    // a CHAINING method on `ViewNode`. A real production bug: that chaining method was MISSING
    // from the guest-emitted `Builder` (`CodeGenerator/GuestIR/Builder.swifttext`), so EVERY
    // view that kept an effect native FAILED the guest WASM compile (`value of type 'ViewNode'
    // has no member 'nativeEffectSlot'`) and silently demoted — 7 AppA views, 10 AppB
    // views. The string-only assertions above never caught it because they don't COMPILE the
    // emitted module. This test does: it lowers a `.task` effect-slot view, emits the real guest
    // module, and compiles it to WASM — the only true guarantee that the node is buildable.

    /// A view whose `.task` keeps the effect native (a `nativeEffectSlot`) must emit a guest module
    /// that COMPILES TO WASM. (Skips without the swift.org WASM toolchain.)
    func testNativeEffectSlotGuestModuleCompilesToWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__EffectView", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping nativeEffectSlot compile")
        let source = """
        import SwiftUI
        struct EffectView: View {
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
        // Sanity: the body really does carry a nativeEffectSlot (else this test proves nothing).
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertTrue(lowered.guestBody.contains("nativeEffectSlot(id:"),
                      "fixture must emit a nativeEffectSlot: \(lowered.guestBody)")
        let module = try compileNativeEffectSlotModule(source: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: module.path),
                      "the guest module with a nativeEffectSlot compiled to WASM")
    }

    /// Lower → emit the real guest module → compile it to WASM (mirrors the build's guest emit).
    private func compileNativeEffectSlotModule(source: String) throws -> URL {
        let lowered = BodyLowering().lowerAllViews(source: source)
        let guestViews = lowered
            .filter { !$0.referencesUnmarshalledInput }
            .map { SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody,
                                                 inputs: $0.inputs, stateModel: $0.stateModel) }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-effectslot-\(UUID().uuidString)")
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
}
