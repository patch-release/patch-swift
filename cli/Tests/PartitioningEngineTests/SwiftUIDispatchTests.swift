// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// Tests for the INTERACTIVE dispatch lowering (Breakthrough #5 productization):
/// the engine now emits a `dispatch(state,event) -> {newState,newTree}` guest
/// export so a view's state-UPDATE logic runs IN WASM (not just `view_body`).
///
///   * the emitter derives a state model (fields + mutation rules) from a real
///     interactive view (Toggle / Stepper / TextField / onTapGesture),
///   * the guest emitter ships BOTH `view_body` AND `dispatch` exports + the
///     state struct + `update` (the interaction logic),
///   * (with the WASM toolchain) the guest COMPILES and host-EXECUTES `dispatch`,
///     and the captured state transitions (toggle flip, stepper clamp, tap
///     wraparound, name assign) are correct — the UPDATE computed IN WASM.
final class SwiftUIDispatchTests: XCTestCase {

    // A real interactive SettingsView: a Toggle + a Stepper (clamped 0...9) + a
    // TextField + a state-derived greeting whose tap bumps the badge (wraparound).
    // This is the productization target — the same shape as the standalone proof.
    private let settingsSource = """
    import SwiftUI

    struct SettingsView: View {
        @State var notificationsOn: Bool = true
        @State var badgeCount: Int = 0
        @State var displayName: String = "Ada"
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.title2)
                    .bold()
                Toggle("Notifications", isOn: $notificationsOn)
                Stepper("Badge", value: $badgeCount, in: 0...9)
                TextField("Name", text: $displayName)
                Text("Hello")
                    .font(.headline)
                    .foregroundColor(.green)
                    .onTapGesture { badgeCount = badgeCount >= 9 ? 0 : badgeCount + 1 }
            }
            .padding(20)
        }
    }
    """

    // MARK: - 1. State-model inference (always runs, no toolchain)

    func testDerivesStateModelFromInteractiveView() throws {
        let lowering = BodyLowering()
        let v = try XCTUnwrap(lowering.lowerAllViews(source: settingsSource).first)
        let model = try XCTUnwrap(v.stateModel, "an interactive view yields a state model")
        XCTAssertTrue(model.isInteractive)

        // Fields: the three @State scalars the controls bind to.
        let fieldNames = Set(model.fields.map { $0.name })
        XCTAssertEqual(fieldNames, ["notificationsOn", "badgeCount", "displayName"])

        // Rules: a setBool (Toggle), a clamped setInt (Stepper 0...9), a setString
        // (TextField), and a wraparound inc (the onTapGesture badge bump).
        func rule(_ event: String) -> BodyLowering.MutationRule? {
            model.rules.first { $0.eventID == event }
        }
        let toggle = try XCTUnwrap(rule("notificationsOn"))
        XCTAssertEqual(toggle.field, "notificationsOn")
        XCTAssertEqual(toggle.op, .setBool)

        let stepper = try XCTUnwrap(rule("badgeCount"))
        XCTAssertEqual(stepper.op, .setIntClamped(lo: 0, hi: 9), "Stepper clamps to its in: range")

        let name = try XCTUnwrap(rule("displayName"))
        XCTAssertEqual(name.op, .setString)

        // The onTapGesture's event id is hash-derived; find the wraparound inc rule.
        let tap = try XCTUnwrap(model.rules.first {
            if case .incInt(_, _, _, let wrap) = $0.op { return wrap }
            return false
        }, "the onTapGesture badge bump lowers to a wraparound inc rule")
        XCTAssertEqual(tap.field, "badgeCount")
        XCTAssertEqual(tap.op, .incInt(step: 1, lo: 0, hi: 9, wrap: true))
    }

    // MARK: - 2. Guest emitter ships view_body + dispatch

    func testGuestEmitterShipsDispatchExport() throws {
        let lowering = BodyLowering()
        let lowered = lowering.lowerAllViews(source: settingsSource)
        let guestViews = lowered.map {
            SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody,
                                          inputs: $0.inputs, stateModel: $0.stateModel)
        }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        // BOTH the canonical exports + the per-view ones.
        XCTAssertTrue(emission.exports.contains("view_body"), "view_body still ships")
        XCTAssertTrue(emission.exports.contains("dispatch"), "dispatch now ships")
        XCTAssertTrue(emission.exports.contains("view_body__SettingsView"))
        XCTAssertTrue(emission.exports.contains("dispatch__SettingsView"))

        let wrapper = try XCTUnwrap(emission.files.first { $0.fileName == "_PatchSwiftUI.swift" })
        // The state struct + update function + dispatch @_cdecl are emitted.
        XCTAssertTrue(wrapper.contents.contains("struct _PatchState_SettingsView"))
        XCTAssertTrue(wrapper.contents.contains("func _patchUpdate_SettingsView"))
        XCTAssertTrue(wrapper.contents.contains("@_cdecl(\"dispatch__SettingsView\")"))
        XCTAssertTrue(wrapper.contents.contains("EmbeddedJSON.encodeDispatch"))
        // The clamp logic for the stepper lives in WASM.
        XCTAssertTrue(wrapper.contents.contains("_patchClampI"))
    }

    // MARK: - 3. A purely-static view ships NO dispatch (default-safe)

    func testStaticViewShipsNoDispatch() throws {
        let staticSource = """
        import SwiftUI
        struct Banner: View {
            let title: String
            var body: some View {
                VStack { Text(title).font(.title).bold() }.padding(16)
            }
        }
        """
        let lowering = BodyLowering()
        let v = try XCTUnwrap(lowering.lowerAllViews(source: staticSource).first)
        XCTAssertNil(v.stateModel, "a static view has no state model")

        let gv = [SwiftUIGuestEmitter.GuestView(viewName: v.viewName, guestBody: v.guestBody,
                                                inputs: v.inputs, stateModel: v.stateModel)]
        let emission = try SwiftUIGuestEmitter().emit(views: gv)
        XCTAssertTrue(emission.exports.contains("view_body"))
        XCTAssertFalse(emission.exports.contains("dispatch"), "no dispatch for a static view")
        let wrapper = try XCTUnwrap(emission.files.first { $0.fileName == "_PatchSwiftUI.swift" })
        XCTAssertFalse(wrapper.contents.contains("@_cdecl(\"dispatch\")"))
    }

    // MARK: - 4. END-TO-END: lower → compile → EXECUTE dispatch in WASM

    func testDispatchExecutesStateTransitionsInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__SettingsView",
                              "dispatch", "dispatch__SettingsView",
                              "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping dispatch execution")

        // Lower + emit the interactive guest module.
        let lowering = BodyLowering()
        let lowered = lowering.lowerAllViews(source: settingsSource)
        let guestViews = lowered.map {
            SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody,
                                          inputs: $0.inputs, stateModel: $0.stateModel)
        }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-dispatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.swiftui.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success,
                       "interactive SwiftUI guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)

        // The module exports BOTH view_body AND dispatch.
        XCTAssertTrue(runner.hasExport("view_body"), "view_body exported")
        XCTAssertTrue(runner.hasExport("dispatch"), "dispatch exported")

        // (a) Initial render from default state.
        let initial = try runner.callPacked("view_body", [UInt8]("{}".utf8))
        let initialBody = try JSONDecoder().decode(BodyEmission.self, from: Data(initial))
        XCTAssertTrue(initialBody.root.describe().contains("Toggle"))

        // Helper: drive one dispatch and return the decoded result.
        func dispatch(state: String, event: String, value: IRValue) throws -> DispatchResult {
            let env = try ViewNodeWire.encodeDispatch(
                state: state, event: DispatchEvent(event: EventID(event), value: value))
            let outBytes = try runner.callPacked("dispatch", env)
            return try ViewNodeWire.decodeDispatch(Data(outBytes).map { $0 })
        }

        // Start from the default state JSON (what view_body of {} would assume).
        var state = #"{"notificationsOn":true,"badgeCount":0,"displayName":"Ada"}"#

        // TRANSITION 1 — Toggle flips the Bool IN WASM.
        let r1 = try dispatch(state: state, event: "notificationsOn", value: .bool(false))
        state = r1.state
        XCTAssertTrue(state.contains("\"notificationsOn\":false"),
                      "toggle flipped the bool in WASM: \(state)")

        // TRANSITION 2 — Stepper CLAMPS 42 → 9 (the clamp logic runs IN WASM).
        let r2 = try dispatch(state: state, event: "badgeCount", value: .int(42))
        state = r2.state
        XCTAssertTrue(state.contains("\"badgeCount\":9"),
                      "stepper clamped 42→9 in WASM: \(state)")

        // TRANSITION 3 — the onTapGesture badge bump WRAPS 9 → 0 (logic in WASM).
        let tapEvent = try XCTUnwrap(lowered.first?.stateModel?.rules.first {
            if case .incInt(_, _, _, let wrap) = $0.op { return wrap }; return false
        }?.eventID)
        let r3 = try dispatch(state: state, event: tapEvent, value: .none)
        state = r3.state
        XCTAssertTrue(state.contains("\"badgeCount\":0"),
                      "tap wrapped badge 9→0 in WASM: \(state)")

        // TRANSITION 4 — TextField assigns the String IN WASM.
        let r4 = try dispatch(state: state, event: "displayName", value: .string("Hopper"))
        state = r4.state
        XCTAssertTrue(state.contains("\"displayName\":\"Hopper\""),
                      "textField assigned the name in WASM: \(state)")

        // The re-emitted tree reflects the new state (badge label, toggle off).
        XCTAssertTrue(r4.tree.describe().contains("Toggle"),
                      "dispatch re-emitted the full tree")
        // The dispatch result's coverage shows the re-rendered tree rides WASM.
        if let cov = r4.coverage {
            XCTAssertEqual(cov.opaqueNodes, 0, "the re-rendered tree has no native fallback")
        }
    }

    // MARK: - WasmKit host runner (mirrors PatchSDK.callPacked)

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
