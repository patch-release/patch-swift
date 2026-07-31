// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// CALLBACK-SLOT END-TO-END DISPATCH (the runtime half of the callbackSlot lever).
///
/// A custom child-view call with a dispatchable labeled `() -> Void` callback
/// (`TeaserScreen(onContinue: { showPaywall = true })`) lowers to a `.callbackSlot` node
/// AND records a guest mutation rule keyed by the slot's position-stable id. On device the
/// native thunk renders the child view with a stable forwarder `{ self.__patchDispatchCallback(id) }`;
/// when the child fires the callback, the SDK runs the guest's `dispatch(event: id)` and writes the
/// new state back into the instance's @State. This test proves the WASM half: the recorded rule for
/// the callback id, executed in real WasmKit, flips the bound state — so the callback is NOT dead.
final class SwiftUICallbackSlotDispatchTests: XCTestCase {

    private let source = """
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

    /// EMITTER-LEVEL: the dispatchable callback records a slot AND a mutation rule keyed by the
    /// SAME id the `.callbackSlot` node carries — so `dispatch(event: node.id)` finds the rule.
    func testCallbackRecordsSlotAndMatchingDispatchRule() throws {
        let lowered = BodyLowering().lowerAllViews(source: source)
        let content = try XCTUnwrap(lowered.first { $0.viewName == "ContentView" })
        // Exactly one callback slot, on the child-view call.
        XCTAssertEqual(content.callbackSlots.count, 1,
                       "the dispatchable onContinue callback records one slot: \(content.callbackSlots)")
        let cb = try XCTUnwrap(content.callbackSlots.first)
        // The guest body carries the `.callbackSlot(id:)` node with that id.
        XCTAssertTrue(content.guestBody.contains("N.callbackSlot(id: \(cb.id.debugDescription)"),
                      "the guest body emits the callbackSlot node: \(content.guestBody)")
        // The forwarder in the slot source routes back through __patchDispatchCallback by that id.
        XCTAssertTrue(cb.slotSource.contains("__patchDispatchCallback(\"\(cb.id)\")"),
                      "the slot source uses the stable forwarder: \(cb.slotSource)")
        // A mutation rule was recorded keyed by the SAME id (so dispatch(event: id) applies it).
        let rule = try XCTUnwrap(content.stateModel?.rules.first { $0.eventID == cb.id },
                                 "a dispatch rule keyed by the callback id must exist (else a dead callback): \(String(describing: content.stateModel?.rules))")
        XCTAssertEqual(rule.field, "showPaywall",
                       "the rule mutates the bound state field: \(rule)")
    }

    /// COLLISION FIX (P1): the SAME child view + same callback LABEL at two positions (the if/else
    /// arms) must get DISTINCT, body-edit-stable ids AND both mutation rules — not collide on one
    /// id (which previously silently dropped the 2nd occurrence's rule and made BOTH render via the
    /// 1st's factory → tapping the 2nd dispatched the WRONG @State). The 1st keeps the bare baseId
    /// (inertness: a single-callback view is byte-identical to before the fix); the 2nd gets `#1`.
    func testTwoSameShapeCallbacksGetDistinctIdsAndRules() throws {
        let src = """
        import SwiftUI
        struct TeaserScreen: View {
            let onContinue: () -> Void
            var body: some View { Button("Go", action: onContinue) }
        }
        struct CollisionView: View {
            let flag: Bool
            @State private var showA = false
            @State private var showB = false
            var body: some View {
                if flag {
                    TeaserScreen(onContinue: { showA = true })
                } else {
                    TeaserScreen(onContinue: { showB = true })
                }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: src)
        let v = try XCTUnwrap(lowered.first { $0.viewName == "CollisionView" })
        // BOTH callbacks record a slot — the 2nd is NOT silently dropped.
        XCTAssertEqual(v.callbackSlots.count, 2,
                       "both if/else callbacks must record a slot: \(v.callbackSlots.map(\.id))")
        // The two same-shape callbacks get DISTINCT ids.
        XCTAssertEqual(Set(v.callbackSlots.map(\.id)).count, 2,
                       "the two same-shape callbacks must get DISTINCT ids: \(v.callbackSlots.map(\.id))")
        // INERTNESS: one keeps the bare baseId (no `#`); the colliding one gets a `#1` suffix.
        XCTAssertTrue(v.callbackSlots.contains { !$0.id.contains("#") }, "one occurrence keeps the bare baseId")
        XCTAssertTrue(v.callbackSlots.contains { $0.id.contains("#1") }, "the colliding occurrence gets a #1 suffix")
        // BOTH mutation rules exist, each flipping its OWN field — proving no dropped/colliding rule.
        let rules = v.stateModel?.rules ?? []
        let fields = Set(v.callbackSlots.compactMap { cb in rules.first { $0.eventID == cb.id }?.field })
        XCTAssertEqual(fields, ["showA", "showB"],
                       "each callback's rule must flip its OWN @State field, not collide: \(fields)")
    }

    /// END-TO-END: lower → compile guest to WASM → run `dispatch(event: callbackId)` → the bound
    /// state flips IN WASM. This is the proof the callback is live (not a dead control).
    func testCallbackDispatchFlipsStateInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__ContentView",
                              "dispatch", "dispatch__ContentView",
                              "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping callback dispatch execution")

        let lowered = BodyLowering().lowerAllViews(source: source)
        let content = try XCTUnwrap(lowered.first { $0.viewName == "ContentView" })
        let cb = try XCTUnwrap(content.callbackSlots.first)

        let guestViews = lowered.map {
            SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody,
                                          inputs: $0.inputs, stateModel: $0.stateModel)
        }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-cb-dispatch-\(UUID().uuidString)")
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
                       "callback-slot guest WASM compile failed:\n\(result.log)")

        let runner = try Runner(wasm: [UInt8](try Data(contentsOf: out)))
        XCTAssertTrue(runner.hasExport("dispatch"), "dispatch exported for the interactive callback view")

        // Drive the callback dispatch from the default (false) state.
        let env = try ViewNodeWire.encodeDispatch(
            state: #"{"showPaywall":false}"#,
            event: DispatchEvent(event: EventID(cb.id), value: .none))
        let outBytes = try runner.callPacked("dispatch", env)
        let dr = try ViewNodeWire.decodeDispatch(Data(outBytes).map { $0 })
        XCTAssertTrue(dr.state.contains("\"showPaywall\":true"),
                      "the callback dispatch flipped showPaywall→true IN WASM (live, not a dead callback): \(dr.state)")
    }

    /// Minimal WasmKit runner (mirrors the file-private one in SwiftUIDispatchTests).
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
