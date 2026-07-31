// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// R2 GUEST-EMITTER CORRECTNESS (overnight rigor round 2).
/// ======================================================
/// Each test pins a verified guest-emitter bug from the R2 partition report
/// (`P2-SwiftUIGuestEmitter.md`). Host-level tests assert the EMITTED guest source
/// (deterministic, always run); the `…ExecutesInWasm` tests compile + run the guest
/// through WasmKit (skipped when the swift.org WASM toolchain is absent) to prove the
/// runtime behavior end-to-end.
final class SwiftUIGuestEmitterR2Tests: XCTestCase {

    // MARK: - R2-#23 / #25: an enum FIELD inside a marshalled struct must emit the
    //          mirroring guest enum + scanner (else the whole guest module fails to
    //          compile and ALL views demote).

    func testEnumFieldInStructEmitsEnumTypeAndScanner() throws {
        // The body reads ONLY the scalar field — merely HAVING the enum field used to
        // emit an undefined `_PatchEnum_Status` reference (compile-fail).
        let source = """
        import SwiftUI
        enum Status: String { case active = "ACTIVE"; case done }
        struct Item { var name: String; var status: Status }
        struct RowView: View {
            let item: Item
            var body: some View { Text(item.name) }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let item = try XCTUnwrap(lowered.inputs.first { $0.name == "item" })
        XCTAssertEqual(item.kind, .flatStruct)
        // The enum field rode in the struct element.
        let statusField = try XCTUnwrap(item.structElement?.fields.first { $0.name == "status" })
        guard case .enumValue = statusField.shape else {
            return XCTFail("status field should be an enum shape, got \(statusField.shape)")
        }
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody, inputs: lowered.inputs)
        let wrapper = try XCTUnwrap(try SwiftUIGuestEmitter().emit(views: [view])
            .files.first { $0.fileName == "_PatchSwiftUI.swift" }).contents
        // The mirroring enum + its scanner MUST be emitted even though no top-level
        // input is an enum (the struct references `_PatchEnum_Status` + its scanner).
        XCTAssertTrue(wrapper.contains("enum _PatchEnum_Status: String {"),
                      "the struct's enum FIELD type must be emitted")
        XCTAssertTrue(wrapper.contains("_patchScanStatusEnum"),
                      "the enum-field scanner must be emitted")
        // The explicit raw value rides too.
        XCTAssertTrue(wrapper.contains("case active = \"ACTIVE\""),
                      "the explicit raw value is faithful")
    }

    func testEnumFieldNestedDeepInStructEmitsEnum() throws {
        // An enum field nested inside a nested struct (and a struct-array element) is
        // also reached by the recursive collection.
        let source = """
        import SwiftUI
        enum Priority: Int { case low, high }
        struct Meta { var flag: Bool; var priority: Priority }
        struct Task2 { var title: String; var meta: Meta }
        struct TaskView: View {
            let task: Task2
            var body: some View { Text(task.title) }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody, inputs: lowered.inputs)
        let wrapper = try XCTUnwrap(try SwiftUIGuestEmitter().emit(views: [view])
            .files.first { $0.fileName == "_PatchSwiftUI.swift" }).contents
        XCTAssertTrue(wrapper.contains("enum _PatchEnum_Priority: Int {"),
                      "an enum field nested inside a nested struct must still be emitted")
        XCTAssertTrue(wrapper.contains("_patchScanPriorityEnum"))
    }

    // MARK: - R2-#24 / #86: a reserved-word enum case name must be backtick-escaped.

    func testReservedWordEnumCaseEscaped() throws {
        let source = """
        import SwiftUI
        enum Mode: String { case `default`; case `repeat`; case normal }
        struct V: View {
            let mode: Mode
            var body: some View { if mode == .normal { Text("n") } else { Text("o") } }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody, inputs: lowered.inputs)
        let wrapper = try XCTUnwrap(try SwiftUIGuestEmitter().emit(views: [view])
            .files.first { $0.fileName == "_PatchSwiftUI.swift" }).contents
        // The decl + the scanner's member access escape the reserved words…
        XCTAssertTrue(wrapper.contains("case `default`"), "reserved-word case decl escaped: \(wrapper)")
        XCTAssertTrue(wrapper.contains("case `repeat`"))
        XCTAssertTrue(wrapper.contains("return .`default`"), "scanner member access escaped")
        XCTAssertTrue(wrapper.contains("return .`repeat`"))
        // …but the JSON `"case"` key stays the BARE name (the wire form the SDK
        // marshals): the scanner line pairs a BARE `"default"` key with the escaped
        // member access. A double-backticked wire key (`"\`default\`"`) would never
        // match `{"case":"default"}` at runtime.
        XCTAssertTrue(wrapper.contains("case \"default\": return .`default`"),
                      "bare wire key + escaped return: \(wrapper)")
        XCTAssertTrue(wrapper.contains("case \"repeat\": return .`repeat`"))
        XCTAssertFalse(wrapper.contains("case \"`default`\""),
                       "the wire-form key must NOT be backtick-wrapped")
        // And no UNescaped `case default` / `.default` slipped through.
        XCTAssertFalse(wrapper.contains("case default ") || wrapper.contains("case default\n"),
                       "no bare reserved-word case decl")
    }

    func testEscapeIdentifierHelper() {
        XCTAssertEqual(SwiftUIGuestEmitter.escapeIdentifier("default"), "`default`")
        XCTAssertEqual(SwiftUIGuestEmitter.escapeIdentifier("repeat"), "`repeat`")
        XCTAssertEqual(SwiftUIGuestEmitter.escapeIdentifier("in"), "`in`")
        XCTAssertEqual(SwiftUIGuestEmitter.escapeIdentifier("active"), "active")
        XCTAssertEqual(SwiftUIGuestEmitter.escapeIdentifier("normalCase"), "normalCase")
    }

    // MARK: - R2-#83 / #102: the TextField write-back cap is no longer 1024 bytes.

    func testSetStringCapRaisedBeyond1024() throws {
        let source = """
        import SwiftUI
        struct NoteView: View {
            @State private var note = ""
            var body: some View { TextField("Note", text: $note) }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, stateModel: lowered.stateModel)
        let wrapper = try XCTUnwrap(try SwiftUIGuestEmitter().emit(views: [view])
            .files.first { $0.fileName == "_PatchSwiftUI.swift" }).contents
        // The 1024-byte clip is gone; the cap is now a large guardrail, not a limit.
        XCTAssertFalse(wrapper.contains("_patchTruncUTF8(str, 1024)"),
                       "the 1024-byte TextField clip must be raised")
        XCTAssertTrue(wrapper.contains("_patchTruncUTF8(str, 1_048_576)"),
                      "the write-back cap is a 1 MiB guardrail, not a product limit")
    }

    // MARK: - R2-#5 / #50 / #55 / #51 / #82 / #84 / #103: parsing helpers (host-level
    //          presence checks; the runtime behavior is exercised in WASM below).

    func testParsingHelpersHardened() throws {
        // Emit ANY interactive view so the dispatch/parse helpers are present.
        let source = """
        import SwiftUI
        struct CounterView: View {
            @State private var count = 0
            var body: some View {
                VStack { Text("\\(count)"); Button("inc") { count += 1 } }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, stateModel: lowered.stateModel)
        let wrapper = try XCTUnwrap(try SwiftUIGuestEmitter().emit(views: [view])
            .files.first { $0.fileName == "_PatchSwiftUI.swift" }).contents
        // R2-#50/#55: _patchReadInt uses overflow-checked accumulation, not `v * 10`.
        XCTAssertTrue(wrapper.contains("multipliedReportingOverflow"),
                      "_patchReadInt must use overflow-checked Int64 accumulation")
        XCTAssertFalse(wrapper.contains("v = v * 10 + Int(s[i] - 0x30)"),
                       "the trapping Int accumulation is gone")
        // R2-#51/#82: _patchReadDouble consumes an exponent.
        XCTAssertTrue(wrapper.contains("0x65 || s[i] == 0x45"),
                      "_patchReadDouble must consume e/E exponents")
        // R2-#5: _patchDoubleToString routes the whole-number fast path through Int64.
        XCTAssertTrue(wrapper.contains("_patchInt64ToString(Int64(d))"),
                      "_patchDoubleToString must not call Int(d) (wasm32 trap)")
        XCTAssertFalse(wrapper.contains("_patchIntToString(Int(d))"),
                       "the trapping Int(d) fast path is gone")
        // R2-#84/#103: a single shared escape decoder covers all string-body paths.
        XCTAssertTrue(wrapper.contains("_patchDecodeEscape"),
                      "a shared escape decoder must exist")
    }

    // MARK: - R2-#6 / #42 / #49 / #85 / #87: key scans are depth-0 + key-position
    //          anchored — a like-named NESTED key (or a value equal to a field name)
    //          no longer mis-resolves a top-level scalar.

    func testNestedSameNameKeyDoesNotCollideInWasm() throws {
        let compiler = SwiftWasmCompiler(exportedSymbols: ["view_body"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping collision WASM run")
        // `Card` has a scalar `body: String` AND a nested `attachment: Media` whose own
        // `body: String` sorts BEFORE the scalar. Reading card.body must NOT pick up the
        // nested attachment.body.
        let source = """
        import SwiftUI
        struct Media { var body: String }
        struct Card { var attachment: Media; var body: String }
        struct CardRow: View {
            let card: Card
            var body: some View { Text(card.body) }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "nested-collision-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        // Alphabetical key order: attachment < body.
        let inputs = Data(#"{"card":{"attachment":{"body":"NESTED"},"body":"OUTER"}}"#.utf8)
        let desc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked("view_body", [UInt8](inputs))))
            .root.describe()
        XCTAssertTrue(desc.contains("OUTER"), "card.body must read the TOP-LEVEL value: \(desc)")
        XCTAssertFalse(desc.contains("NESTED"), "must NOT read the nested attachment.body: \(desc)")
    }

    func testFieldValueEqualToOtherFieldNameDoesNotMisresolveInWasm() throws {
        let compiler = SwiftWasmCompiler(exportedSymbols: ["view_body"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping value-name-collision WASM run")
        // A field VALUE literally equals another field's NAME ("status"); the scalar
        // scan for `status` must not match the bytes inside the `name` VALUE string.
        let source = """
        import SwiftUI
        struct Row { var name: String; var status: String }
        struct RowV: View {
            let row: Row
            var body: some View { VStack { Text(row.name); Text(row.status) } }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "value-name-collision-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        let inputs = Data(#"{"row":{"name":"status","status":"REAL"}}"#.utf8)
        let desc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked("view_body", [UInt8](inputs))))
            .root.describe()
        XCTAssertTrue(desc.contains("REAL"), "row.status must resolve to its real value: \(desc)")
    }

    // MARK: - R2-#56: a `[String:Int]` value above Int32.max is PRESERVED (clamped),
    //          not silently dropped, on the wasm32 guest.

    func testLargeDictIntPreservedInWasm() throws {
        let compiler = SwiftWasmCompiler(exportedSymbols: ["view_body"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping large-int-dict WASM run")
        let source = """
        import SwiftUI
        struct Holder { var label: String; var counts: [String: Int] }
        struct HolderView: View {
            let holder: Holder
            var body: some View { Text("n=\\(holder.counts.count)") }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "large-int-dict-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        // 1_700_000_000_000 > Int32.max; the entry must survive (count stays 2).
        let inputs = Data(#"{"holder":{"label":"x","counts":{"epoch":1700000000000,"small":5}}}"#.utf8)
        let desc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked("view_body", [UInt8](inputs))))
            .root.describe()
        XCTAssertTrue(desc.contains("n=2"),
                      "a 64-bit dict value must NOT drop the entry on wasm32: \(desc)")
    }

    // MARK: - R2-#52 / #53: a dictionary entry whose KEY needs JSON escaping is not
    //          silently dropped (decode-then-re-find used to miss the escaped key).

    func testEscapedDictKeyNotDroppedInWasm() throws {
        let compiler = SwiftWasmCompiler(exportedSymbols: ["view_body"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping escaped-key WASM run")
        let source = """
        import SwiftUI
        struct Holder { var label: String; var labels: [String: Int] }
        struct HolderView: View {
            let holder: Holder
            var body: some View { Text("n=\\(holder.labels.count)") }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "escaped-key-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        // Keys with escapes: a quote, a newline, a backslash. All 3 must survive.
        let inputs = Data(##"{"holder":{"label":"x","labels":{"a\"b":1,"line1\nline2":2,"C:\\x":3}}}"##.utf8)
        let desc = try JSONDecoder()
            .decode(BodyEmission.self, from: Data(try Runner(wasm: wasm).callPacked("view_body", [UInt8](inputs))))
            .root.describe()
        XCTAssertTrue(desc.contains("n=3"),
                      "escaped dict keys must NOT be dropped: \(desc)")
    }

    // MARK: - WASM helpers (shared with the rich-input suite's pattern).

    private func compileSwiftUIModule(source: String, into label: String) throws -> URL {
        let lowering = BodyLowering()
        let lowered = lowering.lowerAllViews(source: source)
        let guestViews = lowered
            .filter { !$0.referencesUnmarshalledInput }
            .map { SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody,
                                                 inputs: $0.inputs, stateModel: $0.stateModel) }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-r2-\(label)-\(UUID().uuidString)")
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
        func memory() throws -> Memory {
            guard let m = instance.exports[memory: "memory"] else { throw NSError(domain: "abi", code: 1) }
            return m
        }
        func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
            guard let fn = instance.exports[function: name],
                  let malloc = instance.exports[function: "patch_malloc"] else {
                throw NSError(domain: "abi", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing export \(name)"])
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
