import XCTest
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
import PatchSwiftUI
#endif

/// THE end-to-end SwiftUI proof THROUGH THE SDK: a real, Swift-compiled WASM
/// module emits a `ViewNode` tree (`view_body`), the SDK decodes + schema-checks
/// it, the renderer turns it into REAL SwiftUI, and a dispatched event runs the
/// guest's UPDATE logic IN WASM (`dispatch`) which re-emits a new tree the host
/// re-renders. This drives the interactive guest fixture through the production
/// `Patch.viewBody` / `Patch.dispatch` / `Patch.patchView` API.
final class PatchViewModuleTests: XCTestCase {

    private func interactiveBytes() throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: "FrontierGuestInteractive", withExtension: "wasm") else {
            throw XCTSkip("FrontierGuestInteractive.wasm fixture missing")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    private func makePatch() throws -> Patch {
        let patch = Patch()
        try patch.activate(bytes: try interactiveBytes())
        return patch
    }

    // Tree introspection helpers (the values are DERIVED in WASM).
    private func findToggle(_ n: ViewNode) -> Bool? {
        if case .toggle(_, let v, _) = n.kind { return v }
        for c in n.childNodes { if let r = findToggle(c) { return r } }
        return nil
    }
    private func findStepper(_ n: ViewNode) -> Int? {
        if case .stepper(_, let v, _, _, _, _) = n.kind { return v }
        for c in n.childNodes { if let r = findStepper(c) { return r } }
        return nil
    }
    private func findTextField(_ n: ViewNode) -> String? {
        if case .textField(_, let v, _) = n.kind { return v }
        for c in n.childNodes { if let r = findTextField(c) { return r } }
        return nil
    }

    /// `Patch.viewBody` returns the guest-emitted tree with real interactive
    /// controls + their WASM-derived current values.
    func testViewBodyEmitsInteractiveTree() throws {
        let patch = try makePatch()
        let tree = try patch.viewBody()   // default state ⇒ guest defaults
        XCTAssertEqual(findToggle(tree), true, "default notificationsOn == true (WASM)")
        XCTAssertEqual(findStepper(tree), 0, "default badgeCount == 0 (WASM)")
        XCTAssertEqual(findTextField(tree), "Ada", "default displayName == Ada (WASM)")
    }

    /// A dispatched event runs the guest UPDATE in WASM and re-emits a NEW tree:
    /// the toggle flips, and the badge stepper's clamp logic runs in WASM.
    func testDispatchRunsUpdateInWasmAndReEmits() throws {
        let patch = try makePatch()

        // Seed the opaque state from a no-op dispatch (the guest returns its state).
        var state = try patch.dispatch(state: "", event: EventID("__noop__"), value: .none).state
        XCTAssertEqual(findToggle(try patch.viewBody(state: state)), true)

        // Flip the toggle OFF — UPDATE runs in WASM, new state + tree returned.
        var r = try patch.dispatch(state: state, event: EventID("toggleNotifications"), value: .bool(false))
        state = r.state
        XCTAssertEqual(findToggle(r.tree), false, "WASM mutated notificationsOn → false")

        // Badge clamp logic runs in WASM (range 0...9; 42 clamps to 9).
        r = try patch.dispatch(state: state, event: EventID("setBadge"), value: .int(42))
        state = r.state
        XCTAssertEqual(findStepper(r.tree), 9, "WASM clamped 42 → 9")

        // TextField edit + greeting recompute in WASM.
        r = try patch.dispatch(state: state, event: EventID("setName"), value: .string("Grace"))
        XCTAssertEqual(findTextField(r.tree), "Grace")
        XCTAssertTrue(r.tree.describe().contains("Hello, Grace!"),
                      "greeting recomputed in WASM from the new name")
    }

    #if canImport(SwiftUI)
    /// `Patch.patchView()` builds a real SwiftUI view backed by the live module,
    /// and a dispatched event forwards into the guest's `dispatch` (the new state
    /// the guest returns mutated as expected). This is the full on-device loop:
    /// real SwiftUI + WASM-run interaction logic.
    @MainActor
    func testPatchViewRendersLiveModuleAndDispatches() throws {
        let patch = try makePatch()
        // Seed the initial opaque state.
        let seed = try patch.dispatch(state: "", event: EventID("__noop__"), value: .none).state

        let view = patch.patchView(initialState: seed)
        // The SwiftUI body renders a real view from the WASM-emitted tree.
        XCTAssertNotNil(view.body)
        XCTAssertNotNil(view.reduce, "module has a dispatch export ⇒ interactive")

        // Drive the reduce (exactly what the control binding does on a change):
        // toggle off → the guest returns a new opaque state with the flip.
        let newState = view.reduce!(seed, EventID("toggleNotifications"), .bool(false))
        XCTAssertNotEqual(newState, seed, "WASM dispatch produced a new state")
        // Re-render from the new state: the toggle is now false (derived in WASM).
        XCTAssertEqual(findToggle(try patch.viewBody(state: newState)), false)
    }

    /// THE ENGINE-EMITTED proof THROUGH THE SDK: a SettingsView lowered by the
    /// PRODUCTION engine path (PATCH_SWIFTUI: BodyLowering + SwiftUIGuestEmitter →
    /// auto-generated `dispatch`) drives the SDK's `Patch.viewBody`/`Patch.dispatch`.
    /// The engine derived the state struct + UPDATE rules; the mutation logic
    /// (toggle flip, stepper CLAMP) runs IN WASM. The event ids are the bound
    /// `@State` field names the engine emitted (not hand-chosen).
    func testEngineEmittedDispatchRunsThroughSDK() throws {
        guard let url = Bundle.module.url(forResource: "EngineSettingsView", withExtension: "wasm") else {
            throw XCTSkip("EngineSettingsView.wasm fixture missing")
        }
        let patch = Patch()
        // The engine lowers at the Foundation (T2) tier, so the module imports the
        // host's `patch_host.*` Foundation bridges (decimal_op/json/now). Register
        // the standard bridge set exactly as a real app does (Patch.shared.start
        // calls this) so the module instantiates against the host surface.
        patch.bridges.registerDefaults()
        try patch.activate(bytes: [UInt8](try Data(contentsOf: url)))

        // view_body emits the interactive tree with WASM-derived defaults.
        let tree = try patch.viewBody()
        XCTAssertEqual(findToggle(tree), true, "engine default notificationsOn == true (WASM)")
        XCTAssertEqual(findStepper(tree), 0, "engine default badgeCount == 0 (WASM)")
        XCTAssertEqual(findTextField(tree), "Ada", "engine default displayName == Ada (WASM)")

        // Seed the opaque state, then dispatch through the SDK. The engine emits the
        // event id = the bound @State field name.
        var state = try patch.dispatch(state: "", event: EventID("__noop__"), value: .none).state

        // Toggle flip — engine-generated UPDATE runs in WASM.
        var r = try patch.dispatch(state: state, event: EventID("notificationsOn"), value: .bool(false))
        state = r.state
        XCTAssertEqual(findToggle(r.tree), false, "engine-emitted dispatch flipped notificationsOn in WASM")

        // Stepper CLAMP 42 → 9 — the engine derived the clamp from `in: 0...9`,
        // and it runs in WASM.
        r = try patch.dispatch(state: state, event: EventID("badgeCount"), value: .int(42))
        state = r.state
        XCTAssertEqual(findStepper(r.tree), 9, "engine-emitted clamp 42→9 ran in WASM")

        // TextField assign — runs in WASM.
        r = try patch.dispatch(state: state, event: EventID("displayName"), value: .string("Grace"))
        XCTAssertEqual(findTextField(r.tree), "Grace", "engine-emitted dispatch assigned the name in WASM")
    }

    /// A schema-version mismatch surfaces as a typed PatchViewError, not a crash.
    /// (We can't easily make the real guest emit a future version, so we assert the
    /// schema gate directly through the decode path used by `viewBody`.)
    func testSchemaGateIsWired() throws {
        // A tree stamped with a future version must be rejected by the host gate.
        let future = PatchViewIRSchema.version + 1
        let bytes = try ViewNodeWire.encode(
            BodyEmission(root: N.text("x"), computeCoverage: false, schemaVersion: future))
        // The same decode+check the SDK glue performs.
        let decoded = try ViewNodeWire.decode(bytes)
        XCTAssertThrowsError(try PatchViewIRSchema.check(decoded.schemaVersion))
    }
    #endif
}
