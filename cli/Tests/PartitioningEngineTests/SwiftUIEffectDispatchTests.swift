// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// THE DEAD/DESTRUCTIVE-EFFECT CORRECTNESS FIX (confirmed on-device bug class, sibling of
/// the dead-button fix). A behavioral/lifecycle modifier (`.task`, `.onChange`, `.onAppear`,
/// `.onSubmit`, `.onTapGesture`, `.onLongPressGesture`, `.onDelete`, `.onMove`) can LOWER into
/// a thunkSafe AUTO-ROUTED view yet do NOTHING — or, worse, silently revert — on device.
///
/// HISTORY: the original fix flagged `hasUndispatchableEffect` and DEMOTED the whole view. The
/// NATIVE EFFECT-MODIFIER SLOT fix (`nativeEffectSlot`) supersedes that for the FIDELITY-SAFE
/// lifecycle/user-input effects: rather than demote the whole view (so an unrelated text edit
/// couldn't ship OTA), the effect is kept NATIVE (a `nativeEffectSlot` the thunk re-applies over
/// `self`) while the REST of the view lowers — so the view AUTO-ROUTES. The cases that STILL
/// demote (a wrong-rendering risk) are the state-watchers (`.onChange`/`.onReceive`) and the
/// list-edit array mutations (`.onDelete`/`.onMove`), plus any effect reading a body-local /
/// cross-file-private member or driving `withAnimation`. A SIMPLE recorded mutation on
/// `.onAppear`/`.onSubmit`/gestures STILL dispatches in WASM (kept routing — better than a slot);
/// an EMPTY closure is a harmless no-op (kept). See SwiftUIEffectSlotTests for the slot path.
final class SwiftUIEffectDispatchTests: XCTestCase {

    private func lower(_ source: String) throws -> BodyLowering.LoweredView {
        try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
    }

    // MARK: - 1. `.task` with a real closure SLOTS (the primary async-data-load fix)

    /// `.task { await vm.load() }` is the #1 async data-load hook. The guest can't re-run it in
    /// WASM, but the cross-file thunk CAN re-apply `content.task { await vm.load() }` over `self` —
    /// so the effect is kept NATIVE via a `nativeEffectSlot` and the REST of the view lowers
    /// (an unrelated text edit ships OTA). The view AUTO-ROUTES (it no longer demotes).
    func testTaskWithClosureSlots() throws {
        let lowered = try lower("""
        import SwiftUI
        @Observable final class VM { var items: [String] = []; func load() async {} }
        struct DataScreen: View {
            @State var vm = VM()
            var body: some View {
                VStack { Text("Header") }
                    .task { await vm.load() }
            }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
                       "a slottable .task is kept native via a nativeEffectSlot — the view does NOT demote")
        XCTAssertTrue(lowered.effectSlots.contains { $0.applySource.contains("content.task")
                        && $0.applySource.contains("vm.load()") },
                      "the .task is recorded as a native effect slot re-applied over self: \(lowered.effectSlots)")
    }

    /// An EMPTY `.task { }` (rare but valid) is a harmless no-op — the view stays routable.
    func testEmptyTaskDoesNotDemote() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            var body: some View { Text("Hi").task { } }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
                       "an empty .task is a no-op — the view stays routable")
    }

    // MARK: - 2. `.onChange` of a GUEST-OWNED (control-bound) value DEMOTES

    /// `.onChange(of: query)` where `query` is GUEST-OWNED — bound to a `TextField($query)` the
    /// guest renders+mutates — keeps the whole-view demote. The onChange-coverage pass slots an
    /// `.onChange` ONLY when its watched value is NATIVE source-of-truth (the guest body does not
    /// mutate it); a control-bound field records a guest mutation rule, so it stays demoted (the
    /// dev's native `.onChange` runs — faithfully firing a native watcher over the guest's own
    /// writeback round-trip while the user types is unproven).
    func testOnChangeWithClosureDemotes() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            @State var query = ""
            @State var count = 0
            var body: some View {
                TextField("q", text: $query)
                    .onChange(of: query) { count += 1 }
            }
        }
        """)
        XCTAssertTrue(lowered.hasUndispatchableEffect,
                      "a non-empty .onChange demotes (the renderer attaches no value-watcher)")
    }

    // MARK: - 3. `.onDelete` / `.onMove` DEMOTE (data-integrity — scalar-only guest)

    func testOnDeleteDemotes() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            @State var rows = ["a", "b", "c"]
            var body: some View {
                List {
                    ForEach(rows, id: \\.self) { Text($0) }
                        .onDelete { offsets in rows.remove(atOffsets: offsets) }
                }
            }
        }
        """)
        XCTAssertTrue(lowered.hasUndispatchableEffect,
                      ".onDelete demotes (the scalar-only guest can't apply the array delete → it reverts)")
    }

    func testOnMoveDemotes() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            @State var rows = ["a", "b", "c"]
            var body: some View {
                List {
                    ForEach(rows, id: \\.self) { Text($0) }
                        .onMove { from, to in rows.move(fromOffsets: from, toOffset: to) }
                }
            }
        }
        """)
        XCTAssertTrue(lowered.hasUndispatchableEffect,
                      ".onMove demotes (the reorder can't be applied to the guest collection)")
    }

    // MARK: - 4. `.onAppear`/`.onSubmit`/gestures: complex closure DEMOTES, simple KEEPS

    /// `.onAppear { vm.load() }` — a method call the guest can't record as a rule, but the
    /// thunk CAN re-apply `content.onAppear { vm.load() }` over `self`. Kept native via a
    /// `nativeEffectSlot`; the rest of the view lowers → the view AUTO-ROUTES (no longer demotes).
    func testOnAppearComplexClosureSlots() throws {
        let lowered = try lower("""
        import SwiftUI
        @Observable final class VM { func load() {} }
        struct V: View {
            @State var vm = VM()
            var body: some View {
                Text("Body").onAppear { vm.load() }
            }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
                       "a slottable complex .onAppear is kept native via a nativeEffectSlot")
        XCTAssertTrue(lowered.effectSlots.contains { $0.applySource.contains("content.onAppear") },
                      "the .onAppear is recorded as a native effect slot: \(lowered.effectSlots)")
    }

    /// `.onAppear { count += 1 }` — a SIMPLE recorded mutation. The renderer fires the event
    /// and the guest rule applies in WASM → faithful → the view KEEPS routing.
    func testOnAppearSimpleMutationKeepsRouting() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            @State var count = 0
            var body: some View {
                Text("Body").onAppear { count += 1 }
            }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
                       "a simple .onAppear mutation is faithfully dispatched → kept routing")
        let model = try XCTUnwrap(lowered.stateModel)
        XCTAssertTrue(model.rules.contains { $0.field == "count" },
                      "the .onAppear simple mutation recorded a rule: \(model.rules)")
    }

    /// An EMPTY `.onAppear { }` is a harmless no-op — kept routing.
    func testEmptyOnAppearKeepsRouting() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            var body: some View { Text("Body").onAppear { } }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect)
    }

    /// `.onTapGesture { vm.refresh() }` — a complex closure the guest can't dispatch, but the
    /// thunk re-applies `content.onTapGesture { vm.refresh() }` over `self` (the real tap runs).
    /// Kept native via a `nativeEffectSlot`; the view AUTO-ROUTES (no longer demotes).
    func testOnTapGestureComplexClosureSlots() throws {
        let lowered = try lower("""
        import SwiftUI
        @Observable final class VM { func refresh() {} }
        struct V: View {
            @State var vm = VM()
            var body: some View {
                Text("Tap me").onTapGesture { vm.refresh() }
            }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
                       "a slottable complex .onTapGesture is kept native via a nativeEffectSlot")
        XCTAssertTrue(lowered.effectSlots.contains { $0.applySource.contains("content.onTapGesture") },
                      "the .onTapGesture is recorded as a native effect slot: \(lowered.effectSlots)")
    }

    /// `.onTapGesture { flag.toggle() }` — a simple recorded mutation dispatches in WASM →
    /// kept routing.
    func testOnTapGestureSimpleMutationKeepsRouting() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            @State var flag = false
            var body: some View {
                Text("Tap me").onTapGesture { flag.toggle() }
            }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
                       "a simple .onTapGesture mutation is faithfully dispatched → kept routing")
        let model = try XCTUnwrap(lowered.stateModel)
        XCTAssertTrue(model.rules.contains { $0.field == "flag" && $0.op == .toggleBool })
    }

    /// `.onSubmit(connect)` — a FUNCTION-REFERENCE action. The guest can't dispatch it, but the
    /// thunk re-applies `content.onSubmit(connect)` over `self` — the real `connect` fires
    /// natively. Kept native via a `nativeEffectSlot`; the view AUTO-ROUTES (no longer demotes).
    /// This is the common real-app form (AppA's ConnectHandleScreen).
    func testOnSubmitFunctionRefSlots() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            @State var handle = ""
            func connect() {}
            var body: some View {
                TextField("handle", text: $handle).onSubmit(connect)
            }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
                       ".onSubmit(connect) is kept native via a nativeEffectSlot (the function ref re-applies over self)")
        XCTAssertTrue(lowered.effectSlots.contains { $0.applySource.contains("content.onSubmit(connect)") },
                      "the .onSubmit(connect) is recorded as a native effect slot: \(lowered.effectSlots)")
    }

    /// `.onAppear(perform: load)` — a function-ref via the `perform:` label; the thunk re-applies
    /// `content.onAppear(perform: load)` over `self`. Kept native via a `nativeEffectSlot`.
    func testOnAppearFunctionRefSlots() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            func load() {}
            var body: some View {
                Text("Body").onAppear(perform: load)
            }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
                       ".onAppear(perform: load) is kept native via a nativeEffectSlot")
        XCTAssertTrue(lowered.effectSlots.contains { $0.applySource.contains("content.onAppear(perform: load)") },
                      "the .onAppear(perform:) is recorded as a native effect slot: \(lowered.effectSlots)")
    }

    /// `.onSubmit { search() }` — a free-function call the guest can't record, kept native via a
    /// `nativeEffectSlot` (the thunk re-applies `content.onSubmit { search() }` over `self`).
    func testOnSubmitComplexClosureSlots() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            @State var q = ""
            func search() {}
            var body: some View {
                TextField("q", text: $q).onSubmit { search() }
            }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect, "a slottable complex .onSubmit is kept native via a nativeEffectSlot")
        XCTAssertTrue(lowered.effectSlots.contains { $0.applySource.contains("content.onSubmit") },
                      "the .onSubmit is recorded as a native effect slot: \(lowered.effectSlots)")
    }

    // MARK: - 4b. `.gesture(...)` continuous + tap forms (the sibling of onTapGesture)

    /// `.gesture(DragGesture().onChanged { … })` — the guest can't consume the `.point`
    /// translation, but the thunk re-applies the whole `content.gesture(DragGesture()…)` over
    /// `self` (the real drag runs). Kept native via a `nativeEffectSlot`; the view AUTO-ROUTES.
    func testDragGestureSlots() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            @State var offset = CGSize.zero
            var body: some View {
                Rectangle()
                    .gesture(DragGesture().onChanged { v in offset = v.translation })
            }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
                       ".gesture(DragGesture) is kept native via a nativeEffectSlot (the real drag re-applies over self)")
        XCTAssertTrue(lowered.effectSlots.contains { $0.applySource.contains("content.gesture") },
                      "the .gesture(DragGesture) is recorded as a native effect slot: \(lowered.effectSlots)")
    }

    /// `.gesture(MagnifyGesture()...)` — a `.double` the guest can't consume, kept native via a
    /// `nativeEffectSlot` (the thunk re-applies the real magnify gesture over `self`).
    func testMagnifyGestureSlots() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            @State var scale = 1.0
            var body: some View {
                Image(systemName: "photo")
                    .gesture(MagnifyGesture().onChanged { v in scale = v.magnification })
            }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect, ".gesture(MagnifyGesture) is kept native via a nativeEffectSlot")
        XCTAssertTrue(lowered.effectSlots.contains { $0.applySource.contains("content.gesture") },
                      "the .gesture(MagnifyGesture) is recorded as a native effect slot: \(lowered.effectSlots)")
    }

    /// `.gesture(TapGesture().onEnded { vm.refresh() })` — a complex tap action, kept native via a
    /// `nativeEffectSlot` (the thunk re-applies the real `.gesture(TapGesture()…)` over `self`).
    func testGestureTapComplexActionSlots() throws {
        let lowered = try lower("""
        import SwiftUI
        @Observable final class VM { func refresh() {} }
        struct V: View {
            @State var vm = VM()
            var body: some View {
                Text("Tap").gesture(TapGesture().onEnded { vm.refresh() })
            }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
                       ".gesture(TapGesture) with a complex action is kept native via a nativeEffectSlot")
        XCTAssertTrue(lowered.effectSlots.contains { $0.applySource.contains("content.gesture") },
                      "the .gesture(TapGesture) is recorded as a native effect slot: \(lowered.effectSlots)")
    }

    /// `.gesture(TapGesture().onEnded { count += 1 })` — a SIMPLE recorded mutation routes
    /// through the same rule-recording path as the dedicated .onTapGesture → kept routing.
    func testGestureTapSimpleMutationKeepsRouting() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            @State var count = 0
            var body: some View {
                Text("Tap").gesture(TapGesture().onEnded { count += 1 })
            }
        }
        """)
        XCTAssertFalse(lowered.hasUndispatchableEffect,
                       "a simple .gesture(TapGesture) mutation is recorded → kept routing")
        let model = try XCTUnwrap(lowered.stateModel)
        XCTAssertTrue(model.rules.contains { $0.field == "count" },
                      "the gesture tap simple mutation recorded a rule: \(model.rules)")
    }

    // MARK: - 4c. `.onHover` (the sibling of onChange)

    /// `.onHover { hovering in isHovered = hovering }` — the renderer dispatches `.bool` the
    /// guest can't consume → dead → demote.
    func testOnHoverDemotes() throws {
        let lowered = try lower("""
        import SwiftUI
        struct V: View {
            @State var isHovered = false
            var body: some View {
                Text("Hover").onHover { hovering in isHovered = hovering }
            }
        }
        """)
        XCTAssertTrue(lowered.hasUndispatchableEffect, "a non-empty .onHover demotes")
    }

    // MARK: - 5. END-TO-END in WASM

    /// PROOF (kept): a view with ONLY a SIMPLE `.onAppear { count += 1 }` is NOT flagged and,
    /// in WASM, dispatching the appear event id INCREMENTS the guest `count` — the effect is
    /// genuinely live on device.
    func testSimpleOnAppearDispatchesInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__Counter", "dispatch", "dispatch__Counter",
                              "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping effect-dispatch WASM run")

        let source = """
        import SwiftUI
        struct Counter: View {
            @State var count: Int = 0
            var body: some View {
                Text("Count").onAppear { count += 1 }
            }
        }
        """
        let lowered = BodyLowering().lowerAllViews(source: source)
        let lv = try XCTUnwrap(lowered.first)
        XCTAssertFalse(lv.hasUndispatchableEffect,
                       "a simple .onAppear mutation does NOT demote")
        let appearRule = try XCTUnwrap(lv.stateModel?.rules.first { $0.field == "count" },
                                       "the simple .onAppear recorded a dispatch rule")

        let guestViews = lowered.map {
            SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody,
                                          inputs: $0.inputs, stateModel: $0.stateModel)
        }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-effectdispatch-\(UUID().uuidString)")
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
        XCTAssertTrue(runner.hasExport("dispatch"), "dispatch is exported")

        func dispatch(state: String, event: String, value: IRValue) throws -> DispatchResult {
            let env = try ViewNodeWire.encodeDispatch(
                state: state, event: DispatchEvent(event: EventID(event), value: value))
            let outBytes = try runner.callPacked("dispatch", env)
            return try ViewNodeWire.decodeDispatch(Data(outBytes).map { $0 })
        }
        // Dispatch the .onAppear event id → guest `count` increments IN WASM (the effect is LIVE).
        let r1 = try dispatch(state: #"{"count":0}"#, event: appearRule.eventID, value: .none)
        XCTAssertTrue(r1.state.contains("\"count\":1"),
                      "dispatching the simple .onAppear event incremented count IN WASM — the effect is LIVE: \(r1.state)")
    }

    // MARK: - WasmKit host runner (mirrors SwiftUIButtonActionDispatchTests.Runner)

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
