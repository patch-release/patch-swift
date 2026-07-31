// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// THE DEAD-BUTTON CORRECTNESS FIX (confirmed on-device bug): an `N.button(actionID:)`
/// renders from WASM, but tapping dispatches only a RECORDED rule. A COMPLEX action
/// (`Task { await … }`, an `@Observable`/method call, a multi-statement body) recorded
/// NO rule, so the button rendered but did NOTHING on device — a dead control (there's no
/// native button left once the view auto-routes). The fix:
///   * In a plain BODY/container context an undispatchable Button is SLOTTED natively
///     (a real, working control via the thunk's `__patchSlots()` self-context).
///   * In a MODIFIER-ACTION LIST context (alert/confirmationDialog/toolbar/Menu/contextMenu)
///     the renderer can't attach a native slot to an actions-list entry, so the WHOLE view
///     DEMOTES to native (`hasUndispatchableAction` → not `thunkSafe`) — fully functional.
///   * A SIMPLE action (`flag.toggle()`, `showing = true`, `count += 1`) still records a
///     rule and dispatches in WASM (unchanged / extended for `= true`/`= false`).
final class SwiftUIButtonActionDispatchTests: XCTestCase {

    // MARK: - 1. Emitter-level: complex action in BODY context SLOTS (no dead bare button)

    /// A `Button { Task { await schedule.updateProfile { … } } }` in a plain body — a
    /// COMPLEX action — must NOT lower to a bare `N.button` (which would dispatch nothing).
    /// It SLOTS the whole Button (`N.opaque`, slotable over `self`) so the real native button
    /// + real action render via the thunk, and the rest of the view still lowers.
    func testComplexActionButtonInBodySlotsNotDeadButton() throws {
        let source = """
        import SwiftUI
        @Observable final class Schedule {
            var profile: String = ""
            func updateProfile(_ f: () -> Void) {}
        }
        struct SettingsRow: View {
            @State var schedule = Schedule()
            var body: some View {
                VStack {
                    Text("Profile")
                    Button {
                        Task { await schedule.updateProfile { } }
                    } label: {
                        Text("Save")
                    }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let body = lowered.guestBody
        // The complex-action Button slotted to an opaque node — NOT a bare wired button.
        XCTAssertTrue(body.contains("N.opaque"),
                      "complex-action Button slots to an opaque node: \(body)")
        XCTAssertFalse(body.contains("N.button(actionID:"),
                       "no dead bare button emitted for the complex action: \(body)")
        // A slot was recorded for it (so the build-time thunk renders the real button).
        XCTAssertTrue(lowered.opaqueLeaves.contains { $0.label == "Button" },
                      "the Button was recorded as a slot: \(lowered.opaqueLeaves)")
        // It reads only `self`-accessible names (schedule), so the slot is slotable → the
        // view still auto-routes (the Text rides WASM, the Button renders natively).
        XCTAssertTrue(lowered.opaqueLeaves.allSatisfy { $0.slotable },
                      "the self-only Button slot is slotable: \(lowered.opaqueLeaves)")
        XCTAssertFalse(lowered.hasUndispatchableAction,
                       "a BODY-context slot does NOT force the view to demote")
    }

    /// A multi-statement action (not the single recognizable mutation) in body context
    /// also SLOTS (it's undispatchable as a rule), instead of shipping a dead button.
    func testMultiStatementActionButtonInBodySlots() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State var count = 0
            @State var open = false
            var body: some View {
                Button {
                    count += 1
                    open = true
                } label: { Text("Go") }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let body = lowered.guestBody
        XCTAssertTrue(body.contains("N.opaque"),
                      "multi-statement action slots: \(body)")
        XCTAssertFalse(body.contains("N.button(actionID:"),
                       "no dead bare button for the multi-statement action: \(body)")
    }

    // MARK: - 2. Emitter-level: complex action in an ACTIONS-LIST context → NATIVE-ACTION SLOT
    //
    // UPDATED (actionSlot mechanism): a complex actions-list Button action that references only
    // SELF-accessible members (a `@State` store, a self method) is no longer demoted — it lowers
    // its LABEL + role to an `actionSlotButton` node and supplies its ACTION as a native
    // `__patchActionSlots()` closure (over `self`), so the view AUTO-ROUTES and the real native
    // action runs faithfully. (`hasUndispatchableAction` is now reserved for an action the thunk
    // CAN'T reach — a body-local / cross-file-private read — see the demote tests below.)

    /// A complex-action Button inside an `.alert { … }` actions list whose action reads a
    /// SELF `@State` store (`Task { await store.purge() }`) now ACTION-SLOTS (not demotes): the
    /// Button label + role lower; the `Task { … }` rides a native `__patchActionSlots()` closure.
    func testComplexActionButtonInAlertActionSlots() throws {
        let source = """
        import SwiftUI
        @Observable final class Store { func purge() async {} }
        struct V: View {
            @State var confirming = false
            @State var store = Store()
            var body: some View {
                Text("Body")
                    .alert("Delete?", isPresented: $confirming) {
                        Button("Delete", role: .destructive) {
                            Task { await store.purge() }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This cannot be undone")
                    }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertFalse(lowered.hasUndispatchableAction,
                       "a self-accessible complex alert action now action-slots, not demotes")
        XCTAssertTrue(lowered.actionSlots.contains { $0.source.contains("store.purge()") },
                      "the Task { await store.purge() } action is recorded as a native action slot: \(lowered.actionSlots)")
        XCTAssertTrue(lowered.guestBody.contains("N.actionSlotButton("),
                      "the Delete button lowers to an actionSlotButton node: \(lowered.guestBody)")
    }

    /// The SAME self-accessible complex action in a `.toolbar { Button { Task … } }` action-slots.
    func testComplexActionButtonInToolbarActionSlots() throws {
        let source = """
        import SwiftUI
        @Observable final class Store { func sync() async {} }
        struct V: View {
            @State var store = Store()
            var body: some View {
                Text("Body")
                    .toolbar {
                        Button {
                            Task { await store.sync() }
                        } label: { Text("Sync") }
                    }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertFalse(lowered.hasUndispatchableAction,
                       "a self-accessible complex toolbar action now action-slots, not demotes")
        XCTAssertTrue(lowered.actionSlots.contains { $0.source.contains("store.sync()") },
                      "the toolbar action is recorded as a native action slot: \(lowered.actionSlots)")
    }

    /// A self-accessible complex action in a `Menu { Button { Task … } }` action-slots (the menu
    /// items are an actions list).
    func testComplexActionButtonInMenuActionSlots() throws {
        let source = """
        import SwiftUI
        @Observable final class Store { func archive() async {} }
        struct V: View {
            @State var store = Store()
            var body: some View {
                Menu {
                    Button {
                        Task { await store.archive() }
                    } label: { Text("Archive") }
                } label: { Text("More") }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertFalse(lowered.hasUndispatchableAction,
                       "a self-accessible complex Menu action now action-slots, not demotes")
        XCTAssertTrue(lowered.actionSlots.contains { $0.source.contains("store.archive()") },
                      "the Menu action is recorded as a native action slot: \(lowered.actionSlots)")
    }

    /// DEMOTE-SAFE (still): an actions-list Button whose action reads a BODY-LOCAL the `self`-only
    /// thunk can't reach must STILL demote (`hasUndispatchableAction`) — NOT strip the body and
    /// ship a broken action. (The mechanism only slots a provably-reachable action.)
    func testComplexActionButtonReadingBodyLocalStillDemotes() throws {
        let source = """
        import SwiftUI
        @Observable final class Store { func purge(_ id: Int) async {} }
        struct V: View {
            @State var confirming = false
            @State var store = Store()
            let ids: [Int]
            var body: some View {
                let pendingID = ids.first ?? 0
                Text("Body")
                    .alert("Delete?", isPresented: $confirming) {
                        Button("Delete", role: .destructive) {
                            Task { await store.purge(pendingID) }
                        }
                    } message: { Text("Undo not possible") }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertTrue(lowered.actionSlots.isEmpty,
                      "an action reading a body-local must NOT be action-slotted: \(lowered.actionSlots)")
        XCTAssertTrue(lowered.hasUndispatchableAction,
                      "a body-local action still demotes the view (never a stripped/broken body)")
    }

    // MARK: - 2b. BARE METHOD-REFERENCE actions (`Button("Connect", action: submit)`)
    //
    // The AppA `AddConnectionSheet` fix: a toolbar `confirmationAction`
    // `Button("Connect", action: submit)` — a bare METHOD-REFERENCE action, not a `{ … }` closure.
    // There's no closure body to record a dispatch rule from (undispatchable), but a bare 0-arg
    // method ref naming a thunk-REACHABLE view method CAN be slotted: the thunk supplies the native
    // closure `{ self.submit() }`, so the view auto-routes and the real native call runs on tap.
    // DEMOTE-SAFE: only a same-view, separate-file-reachable (or same-file private) method ref
    // slots; a cross-file-private (separate-file thunk) or non-resolvable ref stays demoted.

    /// A toolbar `Button("Connect", action: submit)` — bare method-ref over a PRIVATE self method,
    /// SAME-FILE thunk (the default). The action slots as `self.submit()`; the view auto-routes.
    func testBareMethodRefActionSlotsSameFile() throws {
        let source = """
        import SwiftUI
        struct AddSheet: View {
            @State private var handle = ""
            var body: some View {
                Text("x")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Connect", action: submit)
                        }
                    }
            }
            private func submit() { handle = "" }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertFalse(lowered.hasUndispatchableAction,
                       "a reachable bare method-ref toolbar action now action-slots, not demotes")
        XCTAssertTrue(lowered.actionSlots.contains { $0.source == "self.submit()" },
                      "the method-ref action is recorded as `self.submit()`: \(lowered.actionSlots)")
        XCTAssertTrue(lowered.guestBody.contains("N.actionSlotButton("),
                      "the Connect button lowers to an actionSlotButton node: \(lowered.guestBody)")
    }

    /// THE DEMOTE-SAFETY INVARIANT: the SAME `Button("Connect", action: submit)` over a PRIVATE
    /// method, but a SEPARATE-FILE thunk (`sameFileThunk: false`). Swift's file-scoped private hides
    /// `submit` from the separate-file thunk extension, so `{ self.submit() }` would NOT compile —
    /// the action must NOT slot; the whole view DEMOTES (the real native view renders the edit).
    func testBareMethodRefPrivateSeparateFileDemotes() throws {
        let source = """
        import SwiftUI
        struct AddSheet: View {
            @State private var handle = ""
            var body: some View {
                Text("x")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Connect", action: submit)
                        }
                    }
            }
            private func submit() { handle = "" }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering()
            .lowerAllViews(source: source, sameFileThunk: false).first)
        XCTAssertTrue(lowered.actionSlots.isEmpty,
                      "a cross-file-private method ref must NOT slot (the thunk can't reach it): \(lowered.actionSlots)")
        XCTAssertTrue(lowered.hasUndispatchableAction,
                      "a cross-file-private method ref demotes the view (never a broken slot)")
    }

    /// An INTERNAL (non-private) method ref slots even with a SEPARATE-FILE thunk — the
    /// extension CAN reach an internal method. Demote-safe coverage WIDENS for accessible methods.
    func testBareMethodRefInternalSeparateFileSlots() throws {
        let source = """
        import SwiftUI
        struct AddSheet: View {
            @State var handle = ""
            var body: some View {
                Text("x")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Connect", action: submit)
                        }
                    }
            }
            func submit() { handle = "" }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering()
            .lowerAllViews(source: source, sameFileThunk: false).first)
        XCTAssertFalse(lowered.hasUndispatchableAction,
                       "an internal method ref slots even cross-file (the extension reaches it)")
        XCTAssertTrue(lowered.actionSlots.contains { $0.source == "self.submit()" },
                      "the internal method-ref action slots as `self.submit()`: \(lowered.actionSlots)")
    }

    /// DEMOTE-SAFE: a method ref naming a NON-MEMBER (a free function / not one of the view's
    /// methods — `globalHelper`) is NOT resolvable as `self.globalHelper()` and must NOT slot; the
    /// view demotes. (We only slot a provable SELF method — never a guess that might not compile.)
    func testBareMethodRefNonMemberDemotes() throws {
        let source = """
        import SwiftUI
        func globalHelper() {}
        struct AddSheet: View {
            var body: some View {
                Text("x")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Connect", action: globalHelper)
                        }
                    }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertTrue(lowered.actionSlots.isEmpty,
                      "a non-member free-function ref must NOT slot: \(lowered.actionSlots)")
        XCTAssertTrue(lowered.hasUndispatchableAction,
                      "a non-member method ref demotes (no provable self.<name>())")
    }

    /// DEMOTE-SAFE: a MEMBER-CHAIN action ref (`Button("Save", action: vm.save)`) is NOT slotted —
    /// the receiver `vm` could be private/body-local, harder to prove reachable, so we stay
    /// conservative and demote rather than emit `self.vm.save()` blindly.
    func testBareMethodRefMemberChainDemotes() throws {
        let source = """
        import SwiftUI
        final class VM { func save() {} }
        struct V: View {
            @StateObject var vm = VM()
            var body: some View {
                Text("x")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save", action: vm.save)
                        }
                    }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertTrue(lowered.actionSlots.isEmpty,
                      "a member-chain action ref must NOT slot (conservative): \(lowered.actionSlots)")
        XCTAssertTrue(lowered.hasUndispatchableAction,
                      "a member-chain method ref demotes (receiver reachability unproven)")
    }

    // MARK: - 3. SIMPLE actions are UNCHANGED (still dispatch in WASM, view stays routed)

    /// A simple `flag.toggle()` button records a dispatch rule and lowers to a bare
    /// `N.button` (wired), NOT a slot — it works on device via dispatch.
    func testSimpleToggleButtonRecordsRuleAndWiresButton() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State var flag = false
            var body: some View {
                Button { flag.toggle() } label: { Text("Flip") }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let body = lowered.guestBody
        XCTAssertTrue(body.contains("N.button(actionID:"),
                      "simple toggle action stays a wired N.button: \(body)")
        XCTAssertFalse(body.contains("N.opaque"),
                       "simple toggle action does NOT slot: \(body)")
        let model = try XCTUnwrap(lowered.stateModel, "an interactive view yields a state model")
        XCTAssertTrue(model.rules.contains { $0.field == "flag" && $0.op == .toggleBool },
                      "a toggleBool rule was recorded: \(model.rules)")
        XCTAssertFalse(lowered.hasUndispatchableAction)
    }

    /// `showing = true` (the common sheet-open tap) NOW records a rule (`assignBoolLiteral`)
    /// and stays a wired button — previously it recorded NO rule (a latent dead button).
    func testBoolLiteralAssignButtonRecordsRule() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var showing = false
            var body: some View {
                Button("Open") { showing = true }
                    .sheet(isPresented: $showing) { Text("Sheet body") }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let body = lowered.guestBody
        XCTAssertFalse(body.contains("N.opaque"),
                       "the bool-literal-assign button does NOT slot (it dispatches): \(body)")
        let model = try XCTUnwrap(lowered.stateModel)
        XCTAssertTrue(model.rules.contains {
            $0.field == "showing" && $0.op == .assignBoolLiteral(true)
        }, "a `showing = true` assignBoolLiteral rule was recorded: \(model.rules)")
        XCTAssertFalse(lowered.hasUndispatchableAction)
    }

    /// An EMPTY action (`Button("Delete") { }`) is a valid no-op: it stays a wired button
    /// (no rule), is NEVER slotted/demoted — the existing alert-role-buttons case keeps working.
    func testEmptyActionAlertButtonsStayLowered() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var confirming = false
            var body: some View {
                Text("Body")
                    .alert("Delete?", isPresented: $confirming) {
                        Button("Delete", role: .destructive) { }
                        Button("Cancel", role: .cancel) { }
                    } message: { Text("Undo not possible") }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertFalse(lowered.hasUndispatchableAction,
                       "empty-action buttons are valid no-ops — the view stays routable")
        let body = lowered.guestBody
        XCTAssertTrue(body.contains(".alert("), "the alert still lowers: \(body)")
        XCTAssertFalse(body.contains("N.opaque"),
                       "empty-action alert buttons don't slot: \(body)")
    }

    // MARK: - 4. END-TO-END in WASM: simple button dispatches, complex button is a slot

    /// PROOF (a): a simple `Button { flag.toggle() }` view compiles, the tree carries a
    /// WIRED button node, and dispatching its action id flips the guest `@State` IN WASM —
    /// the button is genuinely live on device. PROOF (b): a complex-action button renders as
    /// a SLOT (opaque) node, not a dead bare button.
    func testSimpleButtonDispatchesAndComplexButtonSlotsInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__Panel", "dispatch", "dispatch__Panel",
                              "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping button-dispatch WASM run")

        // A view with BOTH a simple-action button (toggles a flag — dispatchable) AND a
        // complex-action button (a Task — must slot). The simple one must dispatch in WASM;
        // the complex one must be an opaque slot, never a dead wired button.
        let source = """
        import SwiftUI
        @Observable final class Svc { func refresh() async {} }
        struct Panel: View {
            @State var flag: Bool = false
            @State var svc = Svc()
            var body: some View {
                VStack {
                    Text("Panel")
                    Button { flag.toggle() } label: { Text("Flip") }
                    Button {
                        Task { await svc.refresh() }
                    } label: { Text("Refresh") }
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: source)
        let lv = try XCTUnwrap(lowered.first)

        // The complex-action button slotted; the simple one wired. (Static check first.)
        XCTAssertTrue(lv.guestBody.contains("N.button(actionID:"),
                      "the simple Flip button is wired: \(lv.guestBody)")
        XCTAssertTrue(lv.guestBody.contains("N.opaque"),
                      "the complex Refresh button slotted: \(lv.guestBody)")
        XCTAssertTrue(lv.opaqueLeaves.allSatisfy { $0.slotable },
                      "the self-only Refresh slot is slotable → the view auto-routes")
        XCTAssertFalse(lv.hasUndispatchableAction,
                       "a BODY-context slot does not demote the view")

        // Compile + run.
        let guestViews = lowered.map {
            SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody,
                                          inputs: $0.inputs, stateModel: $0.stateModel)
        }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-buttondispatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.swiftui.wasm")
        let realCompiler = SwiftWasmCompiler(
            exportedSymbols: emission.exports + ["patch_malloc", "patch_free"])
        let result = try realCompiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)

        // (b) The rendered tree carries a real Button node AND an Opaque (the slotted complex
        // button) — proving the complex button is a slot, not a dead/dropped node.
        let initial = try runner.callPacked("view_body", [UInt8]("{}".utf8))
        let desc = try JSONDecoder().decode(BodyEmission.self, from: Data(initial)).root.describe()
        XCTAssertTrue(desc.contains("Button(action:"),
                      "the simple Flip button is a wired Button node in the tree: \(desc)")
        XCTAssertTrue(desc.contains("Opaque("),
                      "the complex Refresh button is an opaque slot in the tree, not a dead node: \(desc)")

        // (a) ON-DEVICE INTERACTION SIMULATION: dispatch the Flip button's action id → the
        // guest `flag` flips IN WASM. This is the live proof the wired button is NOT dead.
        let model = try XCTUnwrap(lv.stateModel)
        let flipRule = try XCTUnwrap(model.rules.first { $0.field == "flag" },
                                     "the Flip button recorded a dispatch rule")
        XCTAssertTrue(runner.hasExport("dispatch"), "dispatch is exported")

        func dispatch(state: String, event: String, value: IRValue) throws -> DispatchResult {
            let env = try ViewNodeWire.encodeDispatch(
                state: state, event: DispatchEvent(event: EventID(event), value: value))
            let outBytes = try runner.callPacked("dispatch", env)
            return try ViewNodeWire.decodeDispatch(Data(outBytes).map { $0 })
        }
        var state = #"{"flag":false}"#
        let r1 = try dispatch(state: state, event: flipRule.eventID, value: .none)
        state = r1.state
        XCTAssertTrue(state.contains("\"flag\":true"),
                      "dispatching the Flip button flipped the guest flag IN WASM — the button is LIVE: \(state)")
        // Flip again → back to false (the rule is a real toggle, computed in WASM).
        let r2 = try dispatch(state: state, event: flipRule.eventID, value: .none)
        XCTAssertTrue(r2.state.contains("\"flag\":false"),
                      "second Flip tap toggled back in WASM: \(r2.state)")
    }

    // MARK: - WasmKit host runner (mirrors PatchSDK.callPacked / the dispatch tests)

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
        func hasExport(_ name: String) -> Bool { instance.exports[function: name] != nil }
        func memory() throws -> Memory {
            guard let m = instance.exports[memory: "memory"] else { throw NSError(domain: "abi", code: 1) }
            return m
        }
        func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
            guard let fn = instance.exports[function: name],
                  let malloc = instance.exports[function: "patch_malloc"] else {
                throw NSError(domain: "abi", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "missing export \(name)"])
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
}
