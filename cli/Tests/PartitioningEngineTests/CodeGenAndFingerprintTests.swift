// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftParser
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler
@testable import PatchCLI

final class CodeGenTests: XCTestCase {
    private func exporterPlan() -> SplitPlan? {
        let records = SwiftParserEngine().parse(source: Fixtures.exporter, file: Fixtures.fixtureURL)
        guard let export = records.first(where: { $0.id.contains("Exporter.export") }) else { return nil }
        return FunctionSplitter().plan(for: export, source: Fixtures.exporter)
    }

    func testSplitterProducesFragmentsForMixedFunction() {
        guard let plan = exporterPlan() else {
            return XCTFail("Splitter returned no plan for an obviously-mixed function")
        }
        XCTAssertFalse(plan.pureFragments.isEmpty, "Expected at least one pure fragment")
        XCTAssertFalse(plan.nativeStatementsSummary.isEmpty, "Expected retained native statements (FileManager)")
        // The FileManager statement must remain in the shell, not be lifted.
        XCTAssertTrue(plan.nativeStatementsSummary.contains { $0.contains("FileManager") },
                      "FileManager statement must stay native. Steps: \(plan.nativeStatementsSummary)")
    }

    func testSplitterComputesDataFlow() {
        guard let plan = exporterPlan() else { return XCTFail("no plan") }
        // The leading pure run binds `total`, `scaled`, `json`. `json` is consumed
        // by the native FileManager step, so it must be a live-out of a fragment.
        // `scaled` is consumed by the trailing pure run.
        let allOutputs = Set(plan.pureFragments.flatMap { $0.outputs.map { $0.name } })
        XCTAssertTrue(allOutputs.contains("json") || allOutputs.contains("scaled"),
                      "Fragment outputs should capture downstream-consumed bindings. Got: \(allOutputs)")
    }

    func testEmitterRewiresBridgeBodyWithPatchCall() {
        guard let plan = exporterPlan() else { return XCTFail("no plan") }
        let files = CodeEmitter().emit(plan)

        XCTAssertTrue(files.wasmFileName.hasSuffix("_wasm.swift"))
        XCTAssertTrue(files.bridgeFileName.hasSuffix("_bridge.swift"))
        XCTAssertTrue(files.wasmSource.contains("_sp_export_"),
                      "WASM source should contain generated fragment names. Got:\n\(files.wasmSource)")
        // The bridge body must be GENUINELY REWIRED (not a documented stub): it
        // dispatches lifted runs through Patch.call and keeps FileManager native.
        XCTAssertTrue(files.bridgeSource.contains("Patch.call(\"_sp_export_"),
                      "Bridge body must thread values through Patch.call. Got:\n\(files.bridgeSource)")
        XCTAssertTrue(files.bridgeSource.contains("FileManager"),
                      "Bridge must retain the native FileManager statement. Got:\n\(files.bridgeSource)")
        // Both emitted files should parse cleanly.
        XCTAssertTrue(emittedSourceParsesWithoutErrors(files.wasmSource),
                      "Emitted WASM source must be syntactically valid:\n\(files.wasmSource)")
        XCTAssertTrue(emittedSourceParsesWithoutErrors(files.bridgeSource),
                      "Emitted bridge source must be syntactically valid:\n\(files.bridgeSource)")
    }

    private func emittedSourceParsesWithoutErrors(_ source: String) -> Bool {
        let recs = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        return recs.contains { $0.kind == .function || $0.kind == .method }
    }

    // MARK: - Day-7: emitted ABI is genuinely executable (codegen shape)

    /// A pure function is exported wholesale across the JSON (ptr,len) ABI: the
    /// emitted file carries a deterministic `@_cdecl("<name>")(ptr,len)->i64`
    /// wrapper, the allocator, and `Args`/`Out` JSON envelopes — the exact shape
    /// the SDK's `callJSON`/`callPacked` invoke.
    func testPureExportEmitsCdeclABIWrapper() {
        let export = CodeEmitter.PureExport(
            exportName: "checkout",
            callee: "PricingEngine.checkout",
            parameters: [(label: "lines", name: "lines", type: "[CartLine]"),
                         (label: "promoCode", name: "promoCode", type: "String?")],
            returnType: "OrderSummary")
        let (fileName, source, exports) = CodeEmitter().emitPureExportFile(export, includeAllocator: true)

        XCTAssertEqual(fileName, "checkout_wasm.swift")
        XCTAssertEqual(exports, ["checkout", "patch_malloc", "patch_free"],
                       "exports must be deterministic and include the allocator")
        XCTAssertTrue(source.contains(#"@_cdecl("checkout")"#),
                      "must export the deterministic name. Got:\n\(source)")
        XCTAssertTrue(source.contains(#"@_cdecl("patch_malloc")"#), "must emit the guest allocator")
        XCTAssertTrue(source.contains("-> Int64"), "ABI wrapper returns packed i64")
        XCTAssertTrue(source.contains("PricingEngine.checkout(lines: _args.lines, promoCode: _args.promoCode)"),
                      "must call the developer's function with decoded args. Got:\n\(source)")
        XCTAssertTrue(source.contains("JSONDecoder().decode(checkout_Args.self"))
        XCTAssertTrue(source.contains("JSONEncoder().encode(_out)"))
        XCTAssertTrue(source.contains("(Int64(_outPtr) << 32) | Int64(_outLen)"),
                      "must pack (ptr,len) into the i64 result")
        XCTAssertTrue(emittedSourceParsesWithoutErrors(source),
                      "emitted pure-export ABI must parse:\n\(source)")
    }

    /// `PureExportScanner` finds the instance-less pure functions and skips
    /// instance methods (which need a `self` that doesn't exist in WASM).
    func testPureExportScannerFindsStaticAndSkipsInstance() {
        let source = """
        import Foundation
        enum Calc {
            static func add(_ a: Int, _ b: Int) -> Int { a + b }
        }
        struct Box {
            let n: Int
            func doubled() -> Int { n * 2 }            // instance method → skip
            static func make(_ n: Int) -> Box { Box(n: n) }
        }
        func freeAdd(_ a: Int, _ b: Int) -> Int { a + b }
        """
        let exports = PureExportScanner().scan(
            source: source,
            eligibleSimpleNames: ["add", "doubled", "make", "freeAdd"])
        let names = exports.map { $0.exportName }
        XCTAssertTrue(names.contains("add"), "static enum method must export")
        XCTAssertTrue(names.contains("freeAdd"), "free function must export")
        XCTAssertTrue(names.contains("make"), "static struct method must export")
        XCTAssertFalse(names.contains("doubled"), "instance method must NOT export (needs self)")
        // Callee for the enum static is `Calc.add`.
        XCTAssertEqual(exports.first { $0.exportName == "add" }?.callee, "Calc.add")
        XCTAssertEqual(exports.first { $0.exportName == "freeAdd" }?.callee, "freeAdd")
    }

    /// `PureExportScanner` exports instance-less COMPUTED PROPERTIES returning a
    /// liftable scalar/string: a `static var` on any value type (`AED.code`) and a
    /// non-static `var` on an `enum` (a value type — decoded receiver). It skips
    /// stored properties, instance properties on a struct/class, and non-liftable
    /// (value-type) return types. These were previously never exported (the scanner
    /// only visited functions), the dominant realization gap on token-heavy apps
    /// (Money: 519 eligible → 1 compiled).
    func testPureExportScannerExportsInstanceLessComputedProperties() {
        let source = """
        import Foundation
        enum AED {
            static var code: String { return "AED" }   // static computed → Type.code
            static var minorUnit: Int { 2 }
            static let stored = "x"                     // stored → skip
        }
        enum Suit {
            case spade, heart
            var symbol: String { self == .spade ? "S" : "H" } // enum instance computed → receiver
        }
        struct Box {
            let n: Int
            var doubled: Int { n * 2 }                  // struct instance computed → skip (needs self)
            static var token: Double { 3.5 }            // static computed → Box.token
        }
        """
        let exports = PureExportScanner().scan(
            source: source,
            eligibleSimpleNames: ["code", "minorUnit", "stored", "symbol", "doubled", "token"])
        let byName = Dictionary(uniqueKeysWithValues: exports.map { ($0.exportName, $0) })

        // Static computed properties on value types export as `Type.prop` (no parens).
        XCTAssertNotNil(byName["AED_code"], "static computed property must export")
        XCTAssertEqual(byName["AED_code"]?.callee, "AED.code")
        XCTAssertEqual(byName["AED_code"]?.isProperty, true)
        XCTAssertTrue(byName["AED_code"]?.parameters.isEmpty ?? false, "a property has no parameters")
        XCTAssertNotNil(byName["AED_minorUnit"], "static Int computed property must export")
        XCTAssertNotNil(byName["Box_token"], "static Double computed property must export")

        // A non-static computed property on an ENUM (a value type) exports via the
        // decoded receiver path.
        XCTAssertNotNil(byName["Suit_symbol"], "enum instance computed property must export")
        XCTAssertEqual(byName["Suit_symbol"]?.receiverType, "Suit")
        XCTAssertEqual(byName["Suit_symbol"]?.isProperty, true)

        // Skips: a stored property, and an instance computed property on a struct.
        XCTAssertNil(byName["AED_stored"], "stored property must NOT export")
        XCTAssertNil(byName["Box_doubled"], "struct instance computed property must NOT export (needs self)")
    }

    /// SELF-FREE instance-method lowering: a method on a SwiftUI View struct (a
    /// non-reconstructable receiver) whose body references ONLY its params is lowered
    /// to a RECEIVER-LESS free function — no `_receiver` decode. This is the
    /// `SettingsScreen.relativeString(from:)` real-app fix.
    func testSelfFreeInstanceMethodLowersReceiverLess() {
        let source = """
        import SwiftUI
        import Foundation
        struct SettingsScreen: View {
            @State private var toast: String?
            var body: some View { Text("x") }
            private func relativeString(from date: Date) -> String {
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .abbreviated
                return f.localizedString(for: date, relativeTo: .now)
            }
        }
        """
        let exports = PureExportScanner().scan(
            source: source, eligibleSimpleNames: ["relativeString"])
        guard let e = exports.first(where: { $0.exportName == "SettingsScreen_relativeString" }) else {
            return XCTFail("self-free instance method must export; got: \(exports.map { $0.exportName })")
        }
        XCTAssertNil(e.receiverType, "a self-free method must NOT decode a `_receiver`")
        XCTAssertNotNil(e.selfFreeFreeFunction, "must carry a synthesized free-function definition")
        let def = e.selfFreeFreeFunction!.verbatimDefinition
        XCTAssertEqual(e.callee, e.selfFreeFreeFunction!.symbolName,
                       "the wrapper must call the synthetic free symbol")
        XCTAssertTrue(def.hasPrefix("func __patch_sf_SettingsScreen_relativeString"),
                      "free fn renamed to the synthetic symbol; got:\n\(def)")
        XCTAssertFalse(def.contains("self"), "synthesized free fn must reference no self")
        XCTAssertTrue(def.contains("RelativeDateTimeFormatter"), "body must be preserved verbatim")
        XCTAssertTrue(emittedSourceParsesWithoutErrors(def), "synthesized free fn must be valid Swift")
        // The Foundation wrapper must call the free symbol (no `_receiver.`).
        let (_, wrapper, _) = CodeEmitter().emitFoundationPureExportFilePublic(e, includeAllocator: true)
        XCTAssertTrue(wrapper.contains("__patch_sf_SettingsScreen_relativeString("),
                      "wrapper must invoke the free symbol; got:\n\(wrapper)")
        XCTAssertFalse(wrapper.contains("_receiver"), "wrapper must NOT decode a receiver")
    }

    /// COMPOSITION (the lead milk-more lever): the self-free verbatim body
    /// (`RelativeDateTimeFormatter` — ABSENT from WASM-corelib Foundation, so the
    /// verbatim body could NEVER compile at any tier) is run through the FusionRewriter
    /// exactly as the BuildPipeline does. The canonical builder collapses to the
    /// `patch_host.relative_date_format` host shim, so the body compiles and ships.
    /// This is what flips `SettingsScreen.relativeString` from demote → ship.
    func testSelfFreeRelativeStringComposesWithFusionBridge() {
        let source = """
        import SwiftUI
        import Foundation
        struct SettingsScreen: View {
            var body: some View { Text("x") }
            private func relativeString(from date: Date) -> String {
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .abbreviated
                return f.localizedString(for: date, relativeTo: .now)
            }
        }
        """
        let exports = PureExportScanner().scan(source: source, eligibleSimpleNames: ["relativeString"])
        let e = try! XCTUnwrap(exports.first { $0.exportName == "SettingsScreen_relativeString" })
        let def = try! XCTUnwrap(e.selfFreeFreeFunction).verbatimDefinition
        // The BuildPipeline rewrites the verbatim body (here we rewrite `def` directly).
        let r = FusionRewriter().rewrite(def)
        XCTAssertTrue(r.bridgedLeaves.contains("RelativeDateTimeFormatter.localizedString(for:relativeTo:)"),
                      "the self-free body's canonical RelativeDateTimeFormatter builder must fire the bridge")
        XCTAssertFalse(r.source.contains("RelativeDateTimeFormatter"),
                       "after composition the WASM-absent type must be gone:\n\(r.source)")
        XCTAssertTrue(r.source.contains("_patchFusionRelativeDateStringToNow(date, _patchFusionRelStyle_abbreviated)"),
                      "the body must call the host shim:\n\(r.source)")
        // The shim resolves against the CHost header: the fusion flat-import ABI is now
        // declared in the always-present CHost target (composition pre-req).
        let header = CHeaderBridge().headerSource()
        XCTAssertTrue(header.contains("patch_relative_date_format"),
                      "CHost header must declare the fusion relative-date import")
        XCTAssertTrue(header.contains("patch_now_unix_millis"),
                      "CHost header must declare the fusion now-millis import the `…ToNow` shim uses")
    }

    /// A bridge whose body fires NO canonical builder (an unusual/configured formatter)
    /// is left verbatim and stays native — demote-safe (no false rewrite).
    func testSelfFreeBodyWithUnusualFormatterStaysVerbatim() {
        // A reused/configured formatter (two calls on the same instance) is NOT the
        // canonical single-builder shape the rewriter matches.
        let body = """
        func __patch_sf_T_f(_ a: Date, _ b: Date) -> String {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            f.dateTimeStyle = .named
            return f.localizedString(for: a, relativeTo: b)
        }
        """
        let r = FusionRewriter().rewrite(body)
        XCTAssertFalse(r.bridgedLeaves.contains("RelativeDateTimeFormatter.localizedString(for:relativeTo:)"),
                       "a configured formatter (extra property set) must NOT match — stays native\n\(r.source)")
        XCTAssertTrue(r.source.contains("RelativeDateTimeFormatter"),
                      "the verbatim body is unchanged (it will fail the WASM compile and demote alone)")
    }

    /// A SELF-USING instance method (reads `self.x` / a bare instance member) must NOT
    /// be lowered receiver-less — it stays on the existing path (a value-type receiver
    /// for a struct, or skipped for a class). Zero false negatives: a method that
    /// touches instance state can never become a self-free free function.
    func testSelfUsingInstanceMethodNotLoweredReceiverLess() {
        let source = """
        import SwiftUI
        struct Card: View {
            let title: String
            @State private var n: Int = 0
            var body: some View { Text("x") }
            // reads `self.title` (explicit) — NOT self-free
            func tagged(_ suffix: String) -> String { self.title + suffix }
            // reads `n` (implicit self / instance prop) — NOT self-free
            func bumped(_ d: Int) -> Int { n + d }
        }
        """
        let exports = PureExportScanner().scan(
            source: source, eligibleSimpleNames: ["tagged", "bumped"])
        for ex in exports where ex.exportName.hasPrefix("Card_") {
            XCTAssertNil(ex.selfFreeFreeFunction,
                         "\(ex.exportName): a self-using method must NOT lower receiver-less")
        }
        // `tagged` reads `self.title`; `bumped` reads implicit-self `n`. Neither is
        // self-free, so neither carries a self-free lowering.
        XCTAssertNil(exports.first { $0.exportName == "Card_tagged" }?.selfFreeFreeFunction)
        XCTAssertNil(exports.first { $0.exportName == "Card_bumped" }?.selfFreeFreeFunction)
    }

    /// A self-free instance method that CALLS another instance method (implicit self)
    /// is NOT self-free — the call is an implicit-self member reference. (`connectionRow`
    /// calling `connectionSubtitle(connection)` would be caught here, but the leaf
    /// `connectionSubtitle` itself — reading only its param — IS self-free.)
    func testSelfFreeRejectsImplicitSelfMethodCall() {
        let source = """
        import Foundation
        struct V {
            // self-free leaf: reads only the param
            func sub(_ c: String) -> String { "@" + c }
            // calls `sub(...)` — an implicit-self method call → NOT self-free
            func row(_ c: String) -> String { sub(c) + "!" }
        }
        """
        let exports = PureExportScanner().scan(
            source: source, eligibleSimpleNames: ["sub", "row"])
        XCTAssertNotNil(exports.first { $0.exportName == "V_sub" }?.selfFreeFreeFunction,
                        "a leaf reading only its param IS self-free")
        XCTAssertNil(exports.first { $0.exportName == "V_row" }?.selfFreeFreeFunction,
                     "a method calling an implicit-self method is NOT self-free")
    }

    /// The emitter renders a computed-property export as a no-arg ABI wrapper whose
    /// call expression reads the property with NO parens (`AED.code`, not `AED.code()`).
    func testEmitterRendersComputedPropertyCallWithoutParens() {
        let export = CodeEmitter.PureExport(
            exportName: "AED_code", callee: "AED.code", parameters: [], returnType: "String",
            isProperty: true)
        let (_, source, _) = CodeEmitter().emitFoundationPureExportFilePublic(
            export, includeAllocator: true)
        XCTAssertTrue(source.contains("let _result = AED.code"),
                      "property must be read without call parens; got:\n\(source)")
        XCTAssertFalse(source.contains("AED.code("),
                       "must NOT emit a call form for a property")
        XCTAssertTrue(emittedSourceParsesWithoutErrors(source),
                      "emitted property wrapper must be valid Swift")
    }

    /// A FIXED TUPLE return `(A, B)` is not Codable as a single field, so the emitter
    /// FLATTENS it into one `_Out` field per component (unlabeled → `_<i>` read from
    /// `_result.<i>`; labeled → `<label>` read from `_result.<label>`). The wrapper
    /// must be valid Swift (so it actually compiles to WASM instead of demoting).
    func testEmitterFlattensUnlabeledTupleReturn() {
        let export = CodeEmitter.PureExport(
            exportName: "pair", callee: "More.pair",
            parameters: [(label: "_", name: "n", type: "Int")], returnType: "(Int, String)")
        let (_, source, _) = CodeEmitter().emitFoundationPureExportFilePublic(
            export, includeAllocator: true)
        XCTAssertTrue(source.contains("let _0: Int"), "first component flattened to _0; got:\n\(source)")
        XCTAssertTrue(source.contains("let _1: String"), "second component flattened to _1")
        XCTAssertTrue(source.contains("_0: _result.0"), "first read positionally from _result.0")
        XCTAssertTrue(source.contains("_1: _result.1"), "second read positionally from _result.1")
        XCTAssertFalse(source.contains("let value: (Int, String)"),
                       "must NOT wrap the whole tuple as one (non-Codable) field")
        XCTAssertTrue(emittedSourceParsesWithoutErrors(source),
                      "flattened tuple wrapper must be valid Swift")
    }

    /// A LABELED tuple return `(x: A, y: B)` flattens by label (`_result.x`), and a
    /// `[K: V]` component's colon must NOT be mistaken for a tuple label.
    func testEmitterFlattensLabeledTupleReturnAndSkipsDictColon() {
        let export = CodeEmitter.PureExport(
            exportName: "stats", callee: "Geo.stats", parameters: [],
            returnType: "(count: Int, weights: [String: Double])")
        let (_, source, _) = CodeEmitter().emitFoundationPureExportFilePublic(
            export, includeAllocator: true)
        XCTAssertTrue(source.contains("let count: Int"), "labeled component keeps its label; got:\n\(source)")
        XCTAssertTrue(source.contains("let weights: [String: Double]"),
                      "a `[String: Double]` component must stay one field (its colon is not a tuple label)")
        XCTAssertTrue(source.contains("count: _result.count"), "read by label")
        XCTAssertTrue(source.contains("weights: _result.weights"), "read by label")
        XCTAssertTrue(emittedSourceParsesWithoutErrors(source),
                      "flattened labeled-tuple wrapper must be valid Swift")
    }

    /// `tupleComponents` only fires for a TOP-LEVEL fixed tuple: a non-tuple, a
    /// parenthesized single type `(A)`, an optional tuple `(A, B)?`, and a function
    /// type all return nil (so they ride the normal single-`value` path).
    func testTupleComponentsRejectsNonTupleShapes() {
        XCTAssertNil(CodeEmitter.tupleComponents(of: "Int"))
        XCTAssertNil(CodeEmitter.tupleComponents(of: "[Int]"))
        XCTAssertNil(CodeEmitter.tupleComponents(of: "(Int)"))            // 1-tuple == Int
        XCTAssertNil(CodeEmitter.tupleComponents(of: "(Int, String)?"))  // optional tuple
        XCTAssertNil(CodeEmitter.tupleComponents(of: "(Int) -> Bool"))   // function type
        let two = CodeEmitter.tupleComponents(of: "(Int, String)")
        XCTAssertEqual(two?.count, 2)
        XCTAssertEqual(two?.map { $0.type }, ["Int", "String"])
    }

    /// `ValueExportScanner` lifts pure VALUE members (design tokens / labels /
    /// value helpers) of a view-DSL type — instance computed properties and
    /// instance methods (their bodies need no `self`). It skips view-returning,
    /// `@ViewBuilder`, and non-liftable-typed members, and members of non-view
    /// types.
    func testValueExportScannerLiftsViewValueMembers() {
        let source = """
        import SwiftUI
        struct ProfileCard: View {
            var primaryFontSize: CGFloat { 17 }
            var greeting: String { "Hi" }
            func rowHeight(for index: Int) -> CGFloat { index == 0 ? 64 : 44 }
            @ViewBuilder var headerView: some View { Text("h") }
            var body: some View { Text(greeting) }
            func avatar() -> some View { Circle() }
        }
        struct Tokens {  // not a View → not a value-lift candidate here
            var fontSize: Double { 12 }
        }
        """
        let groups = ValueExportScanner().scan(
            source: source,
            eligibleSimpleNames: ["primaryFontSize", "greeting", "rowHeight",
                                  "headerView", "body", "avatar", "fontSize"])
        // Only the ProfileCard view contributes value members.
        XCTAssertEqual(groups.map { $0.typeName }, ["ProfileCard"])
        let names = Set(groups.first?.exports.map { $0.memberName } ?? [])
        XCTAssertEqual(names, ["primaryFontSize", "greeting", "rowHeight"],
                       "should lift the 3 pure value members; skip body/headerView/avatar/non-View")
        // CGFloat crosses the ABI as Double.
        let fs = groups.first?.exports.first { $0.memberName == "primaryFontSize" }
        XCTAssertEqual(fs?.returnType, "CGFloat")
        XCTAssertEqual(fs?.abiReturnType, "Double")
        XCTAssertEqual(fs?.exportName, "_pv_ProfileCard_primaryFontSize")
        XCTAssertEqual(fs?.key, "ProfileCard.primaryFontSize")
        // The method carries its labeled Int input at its ABI type.
        let rh = groups.first?.exports.first { $0.memberName == "rowHeight" }
        XCTAssertEqual(rh?.isMethod, true)
        XCTAssertEqual(rh?.parameters.first?.label, "for")
        XCTAssertEqual(rh?.parameters.first?.abiType, "Int")
    }

    /// The rewired bridge is no longer a `fatalError` stub: `Patch.call`
    /// dispatches through the SDK (`PatchSDK.Patch.shared.callJSON`).
    func testBridgeDispatchesThroughSDK() {
        guard let plan = exporterPlan() else { return XCTFail("no plan") }
        let files = CodeEmitter().emit(plan)

        XCTAssertTrue(files.bridgeSource.contains("PatchSDK.Patch.shared.callJSON"),
                      "bridge Patch.call must dispatch through the SDK. Got:\n\(files.bridgeSource)")
        XCTAssertFalse(files.bridgeSource.contains("provided by the Patch runtime at link time"),
                       "the documented fatalError stub must be gone")
        XCTAssertTrue(files.bridgeSource.contains("import PatchSDK"),
                      "bridge must import the SDK")
        XCTAssertTrue(emittedSourceParsesWithoutErrors(files.bridgeSource), "bridge must parse")
    }

    /// A mixed function whose lifted run has CONCRETE-typed I/O produces a fragment
    /// that carries a real `@_cdecl` export + allocator, and the bridge calls it
    /// through the SDK with matching JSON `Args`/`Out` envelopes.
    func testConcreteFragmentExportsABIAndBridgeCallsIt() {
        // The pure run binds `name: String` (explicitly annotated so the splitter
        // gives the fragment a concrete, ABI-eligible signature), consumed by the
        // native FileManager statement (FileManager is mustStayNative → mixed).
        let source = """
        import Foundation
        struct Worker {
            func run(_ n: Int, _ dir: String) {
                let name: String = "report-\\(n * 2 + 1)"
                FileManager.default.createFile(atPath: dir + "/" + name, contents: nil)
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("Worker.run") }),
              let plan = FunctionSplitter().plan(for: record, source: source) else {
            return XCTFail("expected a split plan for a concrete-typed mixed function")
        }
        guard let frag = plan.pureFragments.first else { return XCTFail("no fragment") }
        XCTAssertTrue(frag.outputs.allSatisfy { $0.type != "_" },
                      "fragment outputs must be concretely typed to be ABI-eligible. Got: \(frag.outputs)")
        let files = CodeEmitter().emit(plan)

        // WASM file: the fragment is exported via @_cdecl + allocator.
        XCTAssertTrue(files.wasmSource.contains("@_cdecl(\"\(frag.name)\")"),
                      "ABI-eligible fragment must carry a real @_cdecl export. Got:\n\(files.wasmSource)")
        XCTAssertTrue(files.wasmSource.contains("@_cdecl(\"patch_malloc\")"),
                      "wasm file with exports must emit the allocator")
        XCTAssertTrue(files.exportSymbols.contains("patch_malloc"))
        XCTAssertTrue(files.exportSymbols.contains(frag.name))

        // Bridge: calls the fragment through the SDK with matching envelopes.
        XCTAssertTrue(files.bridgeSource.contains("Patch.call(\"\(frag.name)\""),
                      "bridge must call the exported fragment. Got:\n\(files.bridgeSource)")
        XCTAssertTrue(files.bridgeSource.contains("\(frag.name)_Args"),
                      "bridge must build the args envelope")
        XCTAssertTrue(files.bridgeSource.contains("\(frag.name)_Out"),
                      "bridge must decode the out envelope")
        XCTAssertTrue(emittedSourceParsesWithoutErrors(files.wasmSource), "wasm file must parse")
        XCTAssertTrue(emittedSourceParsesWithoutErrors(files.bridgeSource), "bridge must parse")
    }

    // MARK: - Day-3: a known mixed function splits into compilable fragments

    /// End-to-end: the classifier marks `export` mixed, the splitter produces a
    /// real plan, and the emitted `_wasm.swift` + `_bridge.swift` both PARSE
    /// (compilable shape) — the native FileManager statement is in the bridge,
    /// the lifted pure work is a fragment in the wasm file.
    func testKnownMixedFunctionSplitsIntoCompilableFragments() {
        let records = SwiftParserEngine().parse(source: Fixtures.exporter, file: Fixtures.fixtureURL)
        let g = CallGraphBuilder().build(from: records)
        let cls = Classifier().classifyAll(g)
        let export = cls.first { $0.key.contains("Exporter.export") }?.value
        XCTAssertEqual(export?.classification, .mixed, "export should classify mixed")

        guard let record = records.first(where: { $0.id.contains("Exporter.export") }),
              let plan = FunctionSplitter().plan(for: record, source: Fixtures.exporter) else {
            return XCTFail("splitter produced no plan for the mixed function")
        }
        let files = CodeEmitter().emit(plan)
        XCTAssertTrue(emittedSourceParsesWithoutErrors(files.wasmSource), "wasm fragment must parse")
        XCTAssertTrue(emittedSourceParsesWithoutErrors(files.bridgeSource), "bridge must parse")
        XCTAssertTrue(files.bridgeSource.contains("FileManager"), "FileManager must stay in the shell")
        XCTAssertFalse(files.wasmSource.contains("FileManager"),
                       "ZERO-FALSE-NEGATIVE: FileManager must never leak into the WASM fragment")
    }

    /// Soundness of the native→mixed lever: when the splitter is told which
    /// callees are native, a statement that CALLS a native helper must stay in
    /// the shell and must NOT be lifted into a WASM fragment.
    func testSplitterKeepsNativeCalleeCallsInShell() {
        let source = """
        import Foundation
        struct Worker {
            func run(_ items: [Int]) -> Int {
                let total = items.reduce(0, +)
                let scaled = total * 2
                nativeBit(scaled)
                let report = scaled + items.count
                return report
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("Worker.run") }) else {
            return XCTFail("no record")
        }
        // Tell the splitter `nativeBit` is a native callee.
        let splitter = FunctionSplitter(nativeCalleeNames: ["nativeBit"])
        guard let plan = splitter.plan(for: record, source: source) else {
            return XCTFail("expected a split plan when a native callee is present")
        }
        // The nativeBit(...) call must be retained as a native shell statement,
        // never inside a pure fragment body.
        XCTAssertTrue(plan.nativeStatementsSummary.contains { $0.contains("nativeBit") },
                      "native callee call must stay in the shell. Steps: \(plan.nativeStatementsSummary)")
        for frag in plan.pureFragments {
            XCTAssertFalse(frag.bodyStatements.contains { $0.contains("nativeBit") },
                           "ZERO-FALSE-NEGATIVE: native callee must not be lifted into a WASM fragment. Frag: \(frag.bodyStatements)")
        }
    }

    // MARK: - Day-5: Strategy B (guard / conditional split)

    /// A `guard <pure bool> else { <native throw> }` lifts the boolean condition
    /// into a Bool WASM fragment; the native else-branch stays in the shell.
    func testGuardConditionLiftsPureBoolIntoFragment() {
        let source = """
        import Foundation
        struct Validator {
            func check(_ count: Int, _ name: String, _ path: String) throws {
                guard count > 0 && !name.isEmpty else { throw VErr.bad }
                FileManager.default.createFile(atPath: path, contents: nil)
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("Validator.check") }) else {
            return XCTFail("no record")
        }
        let diag = FunctionSplitter().planDiagnostic(for: record, tree: SwiftParser.Parser.parse(source: source))
        guard let plan = diag.0 else {
            return XCTFail("expected a guard-split plan; outcome=\(diag.1)")
        }
        // A Bool fragment was lifted with `count`/`name` inputs.
        guard let frag = plan.pureFragments.first(where: { $0.name.contains("cond") }) else {
            return XCTFail("expected a guard-condition fragment. Frags: \(plan.pureFragments.map { $0.name })")
        }
        XCTAssertEqual(frag.outputs.first?.type, "Bool", "guard fragment must return Bool")
        XCTAssertTrue(frag.bodyStatements.joined().contains("count > 0"),
                      "fragment must carry the lifted condition. Got: \(frag.bodyStatements)")
        // The native FileManager statement and the throw stay in the shell.
        XCTAssertTrue(plan.nativeStatementsSummary.contains { $0.contains("FileManager") })
        XCTAssertTrue(plan.nativeStatementsSummary.contains { $0.contains("throw") })
        // Emitted fragment + bridge both parse, and the throw never leaks to WASM.
        let files = CodeEmitter().emit(plan)
        XCTAssertTrue(emittedSourceParsesWithoutErrors(files.wasmSource), "wasm must parse:\n\(files.wasmSource)")
        XCTAssertFalse(files.wasmSource.contains("FileManager"),
                       "ZERO-FALSE-NEGATIVE: FileManager must never enter WASM")
        XCTAssertFalse(files.wasmSource.contains("throw"),
                       "control-flow throw must never enter the WASM fragment")
    }

    /// Strategy B must NOT lift a guard whose condition reads a capture / instance
    /// member it can't thread (it would emit an uncompilable fragment).
    func testGuardWithCaptureIsNotLifted() {
        let source = """
        import Foundation
        struct Worker {
            var cancelled = false
            func run(_ n: Int) -> Int {
                guard !cancelled else { return 0 }
                UserDefaults.standard.set(n, forKey: "n")
                return n
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("Worker.run") }) else {
            return XCTFail("no record")
        }
        let plan = FunctionSplitter().plan(for: record, source: source)
        // `cancelled` is an instance member (not a param/local), so no cond
        // fragment may reference it.
        for frag in (plan?.pureFragments ?? []) {
            XCTAssertFalse(frag.bodyStatements.joined().contains("cancelled"),
                           "captured instance member must not be lifted. Frag: \(frag.bodyStatements)")
        }
    }

    // MARK: - Day-5: Strategy A2 (sub-expression lifting)

    /// A pure numeric sub-expression inside a native statement is lifted into a
    /// typed fragment; the native call is rewritten to use the bound temp.
    func testSubExpressionLiftInsideNativeStatement() {
        let source = """
        import Foundation
        struct S {
            func save(_ a: Int, _ b: Int, _ path: String) {
                FileManager.default.createFile(atPath: path, contents: Data(count: a * b + 1))
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("S.save") }),
              let plan = FunctionSplitter().plan(for: record, source: source) else {
            return XCTFail("expected a sub-expression split plan")
        }
        guard let frag = plan.pureFragments.first(where: { $0.name.contains("expr") }) else {
            return XCTFail("expected a sub-expr fragment. Frags: \(plan.pureFragments.map { $0.name })")
        }
        XCTAssertEqual(frag.outputs.first?.type, "Int", "numeric sub-expr fragment returns Int")
        XCTAssertTrue(frag.bodyStatements.joined().contains("a * b + 1"))
        // The rewritten native statement keeps FileManager and references the temp.
        let rewritten = plan.nativeStatementsSummary.joined()
        XCTAssertTrue(rewritten.contains("FileManager"), "FileManager stays native")
        XCTAssertTrue(rewritten.contains(frag.outputs.first!.name),
                      "native statement must use the bound temp. Got: \(rewritten)")
        let files = CodeEmitter().emit(plan)
        XCTAssertTrue(emittedSourceParsesWithoutErrors(files.wasmSource))
        XCTAssertFalse(files.wasmSource.contains("FileManager"),
                       "ZERO-FALSE-NEGATIVE: FileManager must never enter WASM")
    }

    // MARK: - Day-5: body-finder reaches inits / computed properties / closures

    /// A mixed `init` body now splits (the body-finder matches by start line, not
    /// only plain `func`s) — the pure run lifts, `self.x = …` stays native.
    func testInitializerBodySplits() {
        let source = """
        import Foundation
        struct Model {
            var total: Int
            init(_ items: [Int]) {
                let sum = items.reduce(0, +)
                UserDefaults.standard.set(sum, forKey: "s")
                self.total = sum
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("Model.init") }) else {
            return XCTFail("no init record")
        }
        guard let plan = FunctionSplitter().plan(for: record, source: source) else {
            return XCTFail("init body should now be reachable + splittable")
        }
        // The `self.total = sum` assignment must stay native (no `self` in WASM).
        for frag in plan.pureFragments {
            XCTAssertFalse(frag.bodyStatements.joined().contains("self."),
                           "ZERO-FALSE-NEGATIVE: self access must never enter WASM. Frag: \(frag.bodyStatements)")
        }
        XCTAssertTrue(plan.nativeStatementsSummary.contains { $0.contains("self.total") },
                      "self assignment stays in shell. Steps: \(plan.nativeStatementsSummary)")
    }

    // MARK: - Day-5: safety — captures, self, super, await/try never lifted

    /// A closure body's pure run that reads a CAPTURED outer local must not be
    /// lifted (the fragment would reference an undeclared value).
    func testClosureCaptureNeverLifted() {
        let source = """
        import Foundation
        func make(_ base: Int) -> () -> Void {
            let factor = base * 2
            return {
                let scaled = factor * 10
                UserDefaults.standard.set(scaled, forKey: "x")
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let closure = records.first(where: { $0.kind == .closure }) else {
            return XCTFail("no closure record")
        }
        let plan = FunctionSplitter().plan(for: closure, source: source)
        // `factor` is captured from the enclosing function — it must NOT appear in
        // a fragment body (it isn't a closure param / local def).
        for frag in (plan?.pureFragments ?? []) {
            XCTAssertFalse(frag.bodyStatements.joined().contains("factor"),
                           "captured local must not be lifted. Frag: \(frag.bodyStatements)")
        }
    }

    /// `super.foo()`, `await`, and `try` must never be lifted into a WASM fragment.
    func testEffectfulAndSuperNeverLifted() {
        let source = """
        import Foundation
        class C: NSObject {
            func run(_ n: Int) async throws -> Int {
                super.someHook()
                let local = try await fetch(n)
                UserDefaults.standard.set(local, forKey: "k")
                return local
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("C.run") }) else {
            return XCTFail("no record")
        }
        let plan = FunctionSplitter(nativeCalleeNames: ["fetch"]).plan(for: record, source: source)
        for frag in (plan?.pureFragments ?? []) {
            let body = frag.bodyStatements.joined()
            XCTAssertFalse(body.contains("super"), "super must never enter WASM. Frag: \(body)")
            XCTAssertFalse(body.contains("await"), "await must never enter WASM. Frag: \(body)")
            XCTAssertFalse(body.contains("try"), "try must never enter WASM. Frag: \(body)")
        }
    }

    // MARK: - optimization-sweep #3: cross-statement local-type threading

    /// A multi-statement pure region where a later local's type can only be known
    /// by threading an earlier local's inferred type now produces a CONCRETELY
    /// typed (ABI-eligible) fragment instead of an un-inferrable generic one.
    func testCrossStatementTypeThreadingMakesFragmentConcrete() {
        let source = """
        import Foundation
        struct S {
            func run(_ items: [Int], _ path: String) {
                let a = items.count          // a: Int (.count)
                let b = a + 1                // b: Int (threaded from a)
                let c = b * 2                // c: Int (threaded from b)
                FileManager.default.createFile(atPath: path, contents: Data(count: c))
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("S.run") }),
              let plan = FunctionSplitter().plan(for: record, source: source) else {
            return XCTFail("expected a split plan")
        }
        guard let frag = plan.pureFragments.first else { return XCTFail("no fragment") }
        // The live-out `c` (consumed by the FileManager statement) must be
        // concretely typed Int — proving the type was threaded across `a`→`b`→`c`.
        XCTAssertTrue(frag.outputs.contains { $0.name == "c" && $0.type == "Int" },
                      "live-out `c` must be concretely typed Int (threaded). Got: \(frag.outputs)")
        XCTAssertTrue(CodeEmitter().isABIEligible(frag),
                      "concretely-typed fragment must be ABI-eligible (executable). Frag: \(frag.outputs)")
        let files = CodeEmitter().emit(plan)
        XCTAssertTrue(files.wasmSource.contains("@_cdecl"),
                      "ABI-eligible fragment must carry a real export. Got:\n\(files.wasmSource)")
        XCTAssertFalse(files.wasmSource.contains("FileManager"),
                       "ZERO-FALSE-NEGATIVE: FileManager must never enter WASM")
    }

    // MARK: - optimization-sweep #1: switch / branch value lifting (Strategy C)

    /// A `let x = switch s { … }` value-switch whose arms are all pure, sitting
    /// among native statements, lifts into a CONCRETE-typed (ABI-EXECUTABLE) WASM
    /// value fragment. The arm-type inference is the optimization-sweep #1 lever:
    /// before it, the switch result typed to `_` (generic, NON-executable). The
    /// lift itself is performed by whichever strategy fires first (Strategy A
    /// treats the binding as a normal pure statement; Strategy C is the fallback
    /// when no other pure run exists) — what matters is the concrete Int result.
    func testSwitchValueBindingLiftsIntoConcreteFragment() {
        let source = """
        import Foundation
        struct S {
            func run(_ tier: Int, _ path: String) {
                UserDefaults.standard.set(tier, forKey: "t")
                let factor = switch tier {
                case 0: 1
                case 1: 2
                default: 3
                }
                FileManager.default.createFile(atPath: path, contents: Data(count: factor))
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("S.run") }),
              let plan = FunctionSplitter().plan(for: record, source: source) else {
            return XCTFail("expected a split plan for the switch-binding function")
        }
        // SOME fragment must carry the switch and bind `factor: Int` concretely.
        guard let frag = plan.pureFragments.first(where: {
            $0.outputs.contains { o in o.name == "factor" }
        }) else {
            return XCTFail("expected a fragment binding `factor`. Frags: \(plan.pureFragments.map { ($0.name, $0.outputs.map { $0.name }) })")
        }
        XCTAssertEqual(frag.outputs.first(where: { $0.name == "factor" })?.type, "Int",
                       "all-Int switch arms → Int result (arm-type inference). Got: \(frag.outputs)")
        XCTAssertTrue(frag.bodyStatements.joined().contains("switch tier"),
                      "fragment must carry the lifted switch. Got: \(frag.bodyStatements)")
        XCTAssertTrue(CodeEmitter().isABIEligible(frag),
                      "concretely-typed switch fragment must be ABI-EXECUTABLE (the win)")
        // The native FileManager + UserDefaults statements stay in the shell.
        XCTAssertTrue(plan.nativeStatementsSummary.contains { $0.contains("FileManager") })
        let files = CodeEmitter().emit(plan)
        XCTAssertTrue(emittedSourceParsesWithoutErrors(files.wasmSource), "wasm must parse:\n\(files.wasmSource)")
        XCTAssertTrue(files.wasmSource.contains("@_cdecl"), "must export a real ABI wrapper")
        XCTAssertFalse(files.wasmSource.contains("FileManager"),
                       "ZERO-FALSE-NEGATIVE: native I/O must never enter WASM")
    }

    /// Strategy C fires as the FALLBACK for a switch binding when Strategy A's
    /// statement-run partition is blocked: here the switch shares a pure run with
    /// a statement that calls a captured/native helper, so Strategy A pushes the
    /// whole run native and returns nil; Strategy C then lifts the switch ALONE.
    /// (This is the wire-ios trigger — 8 such functions realize only via C.)
    func testStrategyCSwitchLiftFiresAsFallback() {
        let source = """
        import Foundation
        struct S {
            func run(_ tier: Int, _ path: String) {
                let factor = switch tier {
                case 0: 10
                default: 20
                }
                let leaked = capturedHelper(factor)
                FileManager.default.createFile(atPath: path, contents: Data(count: factor + leaked))
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("S.run") }) else {
            return XCTFail("no record")
        }
        let diag = FunctionSplitter().planDiagnostic(
            for: record, tree: SwiftParser.Parser.parse(source: source))
        guard let plan = diag.0 else { return XCTFail("expected a plan; outcome=\(diag.1)") }
        XCTAssertEqual(diag.1, .splitSwitch, "should realize via the dedicated switch-lift strategy")
        guard let frag = plan.pureFragments.first(where: { $0.name.contains("branch") }) else {
            return XCTFail("expected a `branch` (Strategy C) fragment. Frags: \(plan.pureFragments.map { $0.name })")
        }
        XCTAssertEqual(frag.outputs.first?.name, "factor")
        XCTAssertEqual(frag.outputs.first?.type, "Int")
        XCTAssertTrue(CodeEmitter().isABIEligible(frag), "switch fragment must be ABI-executable")
        // The captured helper call + native I/O must stay in the shell, never lifted.
        XCTAssertTrue(plan.nativeStatementsSummary.contains { $0.contains("capturedHelper") })
        for f in plan.pureFragments {
            XCTAssertFalse(f.bodyStatements.joined().contains("capturedHelper"),
                           "ZERO-FALSE-NEGATIVE: captured/native callee must never enter WASM. Frag: \(f.bodyStatements)")
        }
    }

    /// An expression-`if` (`if c { a } else { b }`) value binding lifts to a
    /// concrete Int fragment via arm-type inference.
    func testExpressionIfBindingLiftsIntoFragment() {
        let source = """
        import Foundation
        struct S {
            func run(_ big: Bool, _ path: String) {
                UserDefaults.standard.set(big, forKey: "b")
                let size = if big { 1024 } else { 256 }
                FileManager.default.createFile(atPath: path, contents: Data(count: size))
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("S.run") }),
              let plan = FunctionSplitter().plan(for: record, source: source) else {
            return XCTFail("expected an expression-if lift plan")
        }
        guard let frag = plan.pureFragments.first(where: {
            $0.outputs.contains { o in o.name == "size" }
        }) else {
            return XCTFail("expected a fragment binding `size`. Frags: \(plan.pureFragments.map { $0.name })")
        }
        XCTAssertEqual(frag.outputs.first(where: { $0.name == "size" })?.type, "Int")
        XCTAssertTrue(frag.bodyStatements.joined().contains("if big"))
        XCTAssertTrue(CodeEmitter().isABIEligible(frag), "if-binding fragment must be ABI-executable")
    }

    /// SAFETY: a switch with a NATIVE arm (calls native I/O) must NOT lift — the
    /// whole branch stays native (zero false negatives). The native callee never
    /// enters a WASM fragment.
    func testSwitchWithNativeArmIsNotLifted() {
        let source = """
        import Foundation
        struct S {
            func run(_ tier: Int, _ path: String) -> Int {
                let factor = switch tier {
                case 0: 1
                case 1: nativeSize(path)
                default: 3
                }
                FileManager.default.createFile(atPath: path, contents: Data(count: factor))
                return factor
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("S.run") }) else {
            return XCTFail("no record")
        }
        let plan = FunctionSplitter(nativeCalleeNames: ["nativeSize"]).plan(for: record, source: source)
        for frag in (plan?.pureFragments ?? []) {
            XCTAssertFalse(frag.bodyStatements.joined().contains("nativeSize"),
                           "ZERO-FALSE-NEGATIVE: a switch with a native arm must not be lifted. Frag: \(frag.bodyStatements)")
        }
    }

    /// SAFETY: a switch whose arms have heterogeneous (or un-inferrable) types must
    /// NOT lift as a concrete value fragment (we can't soundly type the result).
    func testHeterogeneousSwitchNotLiftedAsConcrete() {
        let source = """
        import Foundation
        struct S {
            func run(_ tier: Int, _ path: String) {
                UserDefaults.standard.set(tier, forKey: "t")
                let v = switch tier {
                case 0: 1
                default: "two"
                }
                FileManager.default.createFile(atPath: path + "\\(v)", contents: nil)
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("S.run") }) else {
            return XCTFail("no record")
        }
        let plan = FunctionSplitter().plan(for: record, source: source)
        // If any fragment lifted the switch, its result must NOT be a wrong concrete
        // type. The safe outcome is that no `branch` fragment with a concrete type
        // claims to type the heterogeneous switch.
        for frag in (plan?.pureFragments ?? []) where frag.name.contains("branch") {
            XCTFail("heterogeneous switch must not be lifted as a concrete branch fragment: \(frag.outputs)")
        }
    }

    /// A homogeneous scalar array literal (`[0.25, 0.5, 0.75]`) now types as
    /// `[Double]` (Codable), so a fragment binding it is ABI-executable instead of
    /// abandoned as un-inferrable.
    func testHomogeneousArrayLiteralTypesAsCodableElement() {
        let source = """
        import Foundation
        struct S {
            func run(_ path: String) {
                let weights = [0.25, 0.5, 0.75, 1.0]
                let total = weights.count
                FileManager.default.createFile(atPath: path, contents: Data(count: total))
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("S.run") }),
              let plan = FunctionSplitter().plan(for: record, source: source),
              let frag = plan.pureFragments.first else {
            return XCTFail("expected a plan with a fragment")
        }
        // The fragment's live-out is `total: Int`, and `weights` (if a live-out)
        // would be `[Double]`. The fragment must be ABI-executable.
        XCTAssertTrue(CodeEmitter().isABIEligible(frag),
                      "array-literal-typed fragment must be ABI-executable. Outs: \(frag.outputs)")
    }

    // MARK: - optimization-sweep #2: async/throws pure-extraction split

    /// An `async throws` function with a pure computation between native `await`
    /// calls splits: the pure run lifts to WASM, the `await`/native parts stay in
    /// the (async throws) native shell. Mirrors the URLSession-style split.
    func testAsyncThrowsPureRunSplits() {
        let source = """
        import Foundation
        struct Service {
            func load(_ base: Int, _ url: URL) async throws -> Int {
                let scaled = base * 2 + 7
                let data = try await URLSession.shared.data(from: url).0
                UserDefaults.standard.set(data.count, forKey: "k")
                return scaled + data.count
            }
        }
        """
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        guard let record = records.first(where: { $0.id.contains("Service.load") }),
              let plan = FunctionSplitter().plan(for: record, source: source) else {
            return XCTFail("expected an async/throws split plan")
        }
        // The pure `scaled = base*2+7` run lifts to a concrete Int fragment.
        guard let frag = plan.pureFragments.first else { return XCTFail("no fragment") }
        XCTAssertTrue(frag.outputs.contains { $0.name == "scaled" && $0.type == "Int" },
                      "pure run must lift `scaled: Int`. Got: \(frag.outputs)")
        // The native shell must preserve async/throws effects and keep await native.
        XCTAssertTrue(plan.isAsync, "shell must remain async")
        XCTAssertTrue(plan.isThrows, "shell must remain throws")
        XCTAssertTrue(plan.nativeStatementsSummary.contains { $0.contains("await") },
                      "the await must stay in the native shell. Steps: \(plan.nativeStatementsSummary)")
        for f in plan.pureFragments {
            let body = f.bodyStatements.joined()
            XCTAssertFalse(body.contains("await"), "await must never enter WASM. Frag: \(body)")
            XCTAssertFalse(body.contains("URLSession"), "URLSession must never enter WASM. Frag: \(body)")
        }
        let files = CodeEmitter().emit(plan)
        // The emitted async-throws shell signature must carry the effects.
        XCTAssertTrue(files.bridgeSource.contains("async") && files.bridgeSource.contains("throws"),
                      "bridge shell must remain async throws. Got:\n\(files.bridgeSource)")
        XCTAssertTrue(emittedSourceParsesWithoutErrors(files.wasmSource), "wasm must parse")
    }
}

final class FingerprintTests: XCTestCase {
    private func sampleComponents() -> FingerprintComponents {
        FingerprintComponents(
            sdkVersion: "0.1.0",
            wasmKitVersion: "0.1.5",
            bridgeDefinitions: ["URLSession.bridge", "UserDefaults.bridge"],
            nativeSwiftFiles: ["ProfileView.swift", "OrderService_bridge.swift"],
            nativeGeneratedStubs: ["stub1.swift"],
            infoPlist: "<plist>...</plist>",
            entitlements: "<entitlements/>",
            linkedFrameworks: ["UIKit", "Foundation"],
            deploymentTarget: "iOS 17.0",
            swiftCompilerVersion: "6.3.2"
        )
    }

    func testFingerprintIsDeterministic() {
        let c = sampleComponents()
        let a = Fingerprinter.fingerprint(c)
        let b = Fingerprinter.fingerprint(c)
        XCTAssertEqual(a, b, "Fingerprint must be deterministic")
        XCTAssertEqual(a.count, 64, "SHA-256 hex should be 64 chars")
    }

    func testFingerprintChangesWhenComponentChanges() {
        var c = sampleComponents()
        let original = Fingerprinter.fingerprint(c)
        c.deploymentTarget = "iOS 18.0"
        let changed = Fingerprinter.fingerprint(c)
        XCTAssertNotEqual(original, changed, "Changing a native component must change the fingerprint")
    }

    /// SAFETY: swapping two components' VALUES must change the fingerprint. The old
    /// formula sorted the BARE component hashes, so a value swap produced an
    /// IDENTICAL fingerprint (the multiset of hashes was unchanged) — a real
    /// native-shell change that the OTA-compatibility gate would miss, letting an
    /// incompatible module push through. The label-bound formula prevents this.
    func testFingerprintDetectsValueSwapBetweenComponents() {
        var a = sampleComponents()
        a.infoPlist = "AAA"; a.entitlements = "BBB"
        var b = sampleComponents()
        b.infoPlist = "BBB"; b.entitlements = "AAA"   // same VALUES, swapped fields
        XCTAssertNotEqual(
            Fingerprinter.fingerprint(a), Fingerprinter.fingerprint(b),
            "swapping infoPlist/entitlements values must change the fingerprint")

        // Also for two array components.
        var x = sampleComponents()
        x.bridgeDefinitions = ["one"]; x.linkedFrameworks = ["two"]
        var y = sampleComponents()
        y.bridgeDefinitions = ["two"]; y.linkedFrameworks = ["one"]
        XCTAssertNotEqual(
            Fingerprinter.fingerprint(x), Fingerprinter.fingerprint(y),
            "swapping bridgeDefinitions/linkedFrameworks values must change the fingerprint")
    }

    func testHashIsStableForKnownInput() {
        // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        XCTAssertEqual(
            Fingerprinter.hash(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testStubCompilerReportsUnavailable() throws {
        let result = try StubWasmCompiler().compile(
            sources: [URL(fileURLWithPath: "/tmp/a_wasm.swift")],
            outputModule: URL(fileURLWithPath: "/tmp/module.wasm")
        )
        XCTAssertEqual(result.status, .toolchainUnavailable)
    }
}

// MARK: - Fingerprint mismatch explanation (changedComponents)

/// Covers `ProjectFingerprinter.changedComponents` — the diff that turns an opaque
/// "FINGERPRINT MISMATCH" into a list naming WHICH components/files changed.
final class FingerprintDiffTests: XCTestCase {
    /// A temp project dir with the given swift files (name → contents). Cleaned by
    /// the caller passing the URL into `addTeardownBlock`.
    private func makeProject(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fpdiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Build a backend-style `StoredFingerprintComponents` from a local snapshot —
    /// i.e. what the backend would have stored when this snapshot was registered.
    private func stored(from s: ProjectFingerprinter.Snapshot,
                        withPerFile: Bool = true) -> StoredFingerprintComponents {
        let c = s.components
        return StoredFingerprintComponents(
            sdkVersion: c.sdkVersion, wasmKitVersion: c.wasmKitVersion,
            bridgeDefinitions: c.bridgeDefinitions, linkedFrameworks: c.linkedFrameworks,
            deploymentTarget: c.deploymentTarget, swiftCompilerVersion: c.swiftCompilerVersion,
            nativeSwiftFileCount: c.nativeSwiftFiles.count,
            nativeGeneratedStubCount: c.nativeGeneratedStubs.count,
            componentHashes: Dictionary(uniqueKeysWithValues: s.componentHashes.map { ($0.label, $0.hash) }),
            nativeSwiftFiles: withPerFile ? c.nativeSwiftFiles : nil,
            nativeGeneratedStubs: withPerFile ? c.nativeGeneratedStubs : nil)
    }

    func testIdenticalSnapshotsProduceNoChanges() throws {
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let fp = ProjectFingerprinter()
        let snap = fp.snapshot(projectDir: dir, bridges: [:])
        let changed = ProjectFingerprinter.changedComponents(local: snap, backend: stored(from: snap))
        XCTAssertTrue(changed.isEmpty, "an unchanged shell must yield no changed-component lines")
    }

    func testDeploymentTargetChangeIsNamedWithOldAndNew() throws {
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let fp = ProjectFingerprinter()
        let before = fp.snapshot(projectDir: dir, bridges: [:], deploymentTarget: "iOS 17.0")
        let after = fp.snapshot(projectDir: dir, bridges: [:], deploymentTarget: "iOS 18.0")
        let changed = ProjectFingerprinter.changedComponents(local: after, backend: stored(from: before))
        let joined = changed.joined(separator: "\n")
        XCTAssertTrue(joined.contains("Deployment target"), "should name the deployment-target component: \(joined)")
        XCTAssertTrue(joined.contains("iOS 17.0") && joined.contains("iOS 18.0"),
                      "should show old → new: \(joined)")
    }

    func testAddedNativeFileIsNamedByPath() throws {
        let fp = ProjectFingerprinter()
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let before = fp.snapshot(projectDir: dir, bridges: [:])
        // Add a second native file → the "native swift files" component changes.
        try "class B { @objc func g() {} }".write(
            to: dir.appendingPathComponent("Brand.swift"), atomically: true, encoding: .utf8)
        let after = fp.snapshot(projectDir: dir, bridges: [:])
        let joined = ProjectFingerprinter.changedComponents(local: after, backend: stored(from: before))
            .joined(separator: "\n")
        XCTAssertTrue(joined.contains("Native source files"), "should flag native sources: \(joined)")
        XCTAssertTrue(joined.contains("Brand.swift"), "should NAME the added file: \(joined)")
        XCTAssertTrue(joined.contains("+"), "added file should be marked with '+': \(joined)")
    }

    func testOldRecordWithoutPerFileFallsBackToCountAndHint() throws {
        let fp = ProjectFingerprinter()
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let before = fp.snapshot(projectDir: dir, bridges: [:])
        try "class B { @objc func g() {} }".write(
            to: dir.appendingPathComponent("Brand.swift"), atomically: true, encoding: .utf8)
        let after = fp.snapshot(projectDir: dir, bridges: [:])
        // Simulate a record registered by an older CLI: no per-file lists stored.
        let joined = ProjectFingerprinter.changedComponents(
            local: after, backend: stored(from: before, withPerFile: false)).joined(separator: "\n")
        XCTAssertTrue(joined.contains("Native source files"), "should still flag native sources: \(joined)")
        XCTAssertTrue(joined.contains("fingerprint register"),
                      "old record should hint at re-registering for per-file detail: \(joined)")
    }

    func testNoBackendComponentsYieldsEmptyDiff() throws {
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let snap = ProjectFingerprinter().snapshot(projectDir: dir, bridges: [:])
        XCTAssertTrue(ProjectFingerprinter.changedComponents(local: snap, backend: nil).isEmpty,
                      "no backend components → fall back to generic guidance (empty list)")
    }

    // MARK: - Component-delta classification (partial-patch safety)

    /// The static label → kind classification: only Info.plist / entitlements /
    /// linked frameworks / deployment target are native-only; everything else is
    /// patch-affecting (conservative default for any future/unknown label).
    func testClassifyDeltaLabels() {
        let nativeOnly = ["Info.plist", "entitlements", "linked frameworks", "deployment target"]
        for l in nativeOnly {
            XCTAssertEqual(ProjectFingerprinter.classifyDelta(label: l), .nativeOnly,
                           "\(l) must be native-only")
        }
        let affecting = ["native swift files", "native generated stubs", "bridge definitions",
                         "SDK version", "WasmKit version", "swift compiler version",
                         "some-future-unknown-component"]
        for l in affecting {
            XCTAssertEqual(ProjectFingerprinter.classifyDelta(label: l), .patchAffecting,
                           "\(l) must be patch-affecting (conservative)")
        }
    }

    /// An unchanged shell yields no deltas → `changed`/`allNativeOnly` both false
    /// (so the skip is never offered when nothing changed).
    func testComponentDeltasNoChange() throws {
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let snap = ProjectFingerprinter().snapshot(projectDir: dir, bridges: [:])
        let report = ProjectFingerprinter.componentDeltas(local: snap, backend: stored(from: snap))
        XCTAssertFalse(report.changed)
        XCTAssertFalse(report.allNativeOnly, "no change → allNativeOnly must be false (no skip)")
        XCTAssertFalse(report.hasPatchAffecting)
    }

    /// A pure deployment-target bump (nothing else) is classified native-only, so
    /// `allNativeOnly` is true — the SOLE condition that permits skip-and-patch.
    func testComponentDeltasNativeOnlyWhenOnlyDeploymentTargetChanged() throws {
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let fp = ProjectFingerprinter()
        let before = fp.snapshot(projectDir: dir, bridges: [:], deploymentTarget: "iOS 17.0")
        let after = fp.snapshot(projectDir: dir, bridges: [:], deploymentTarget: "iOS 18.0")
        let report = ProjectFingerprinter.componentDeltas(local: after, backend: stored(from: before))
        XCTAssertTrue(report.changed)
        XCTAssertTrue(report.allNativeOnly,
                      "a deployment-target-only change is native-only → skip allowed")
        XCTAssertFalse(report.hasPatchAffecting)
        XCTAssertEqual(report.nativeOnly.map(\.label), ["deployment target"])
        // The detail lines are preserved (same wording as the flat diff).
        XCTAssertTrue(report.deltas.first?.detailLines.joined().contains("iOS 17.0") == true)
        XCTAssertTrue(report.deltas.first?.detailLines.joined().contains("iOS 18.0") == true)
    }

    /// Adding a linked framework (a new native package) with NO change to the native
    /// swift surface is native-only → skip allowed. This is the canonical
    /// "I added a package but my views are unaffected" case.
    func testComponentDeltasNativeOnlyWhenOnlyFrameworkAdded() throws {
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let fp = ProjectFingerprinter()
        let before = fp.snapshot(projectDir: dir, bridges: [:],
                                 linkedFrameworks: ["Foundation"])
        let after = fp.snapshot(projectDir: dir, bridges: [:],
                                linkedFrameworks: ["Foundation", "MapKit"])
        let report = ProjectFingerprinter.componentDeltas(local: after, backend: stored(from: before))
        XCTAssertTrue(report.allNativeOnly,
                      "a framework-add-only change is native-only → skip allowed")
        XCTAssertEqual(report.nativeOnly.map(\.label), ["linked frameworks"])
        XCTAssertTrue(report.deltas.first?.detailLines.joined().contains("MapKit") == true,
                      "the added framework must be named")
    }

    /// SAFETY: a change to the NATIVE swift surface is patch-affecting and must NOT
    /// permit the skip. Adding a NATIVE file (an @objc method — not OTA-eligible)
    /// trips "native swift files", which is patch-affecting.
    func testComponentDeltasPatchAffectingWhenNativeFileChanged() throws {
        let fp = ProjectFingerprinter()
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let before = fp.snapshot(projectDir: dir, bridges: [:])
        try "class B { @objc func g() {} }".write(
            to: dir.appendingPathComponent("Brand.swift"), atomically: true, encoding: .utf8)
        let after = fp.snapshot(projectDir: dir, bridges: [:])
        let report = ProjectFingerprinter.componentDeltas(local: after, backend: stored(from: before))
        XCTAssertTrue(report.changed)
        XCTAssertTrue(report.hasPatchAffecting, "a native-file change must be patch-affecting")
        XCTAssertFalse(report.allNativeOnly,
                       "ZERO-FALSE-NEGATIVE: a patch-affecting change must NOT permit skip-and-patch")
        XCTAssertEqual(report.patchAffecting.map(\.label), ["native swift files"])
    }

    /// SAFETY: a MIX of a native-only change AND a patch-affecting change must NOT
    /// permit the skip — a single patch-affecting component disqualifies the whole
    /// drift (the patch could still be incompatible).
    func testComponentDeltasMixedIsNotAllNativeOnly() throws {
        let fp = ProjectFingerprinter()
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let before = fp.snapshot(projectDir: dir, bridges: [:], deploymentTarget: "iOS 17.0")
        // Both: bump the deployment target (native-only) AND add a native file.
        try "class B { @objc func g() {} }".write(
            to: dir.appendingPathComponent("Brand.swift"), atomically: true, encoding: .utf8)
        let after = fp.snapshot(projectDir: dir, bridges: [:], deploymentTarget: "iOS 18.0")
        let report = ProjectFingerprinter.componentDeltas(local: after, backend: stored(from: before))
        XCTAssertTrue(report.hasPatchAffecting)
        XCTAssertFalse(report.allNativeOnly,
                       "ZERO-FALSE-NEGATIVE: any patch-affecting change disqualifies the skip")
        // Native-only sorts first; both are present.
        XCTAssertEqual(Set(report.deltas.map(\.label)), ["deployment target", "native swift files"])
        XCTAssertEqual(report.deltas.first?.kind, .nativeOnly, "native-only deltas sort first")
    }

    /// SAFETY: a bridge change is patch-affecting (the WASM module CALLS bridges), so
    /// it must NOT permit the skip even though it's a single non-source component.
    func testComponentDeltasBridgeChangeIsPatchAffecting() throws {
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let fp = ProjectFingerprinter()
        let before = fp.snapshot(projectDir: dir, bridges: [:])
        let after = fp.snapshot(projectDir: dir, bridges: ["URLSession": true])
        let report = ProjectFingerprinter.componentDeltas(local: after, backend: stored(from: before))
        XCTAssertTrue(report.hasPatchAffecting, "a bridge change must be patch-affecting")
        XCTAssertFalse(report.allNativeOnly,
                       "a bridge change must NOT permit skip-and-patch")
        XCTAssertEqual(report.patchAffecting.map(\.label), ["bridge definitions"])
    }

    /// An old backend record (no componentHashes) yields an empty report — treated
    /// as "no detail available", never as "safe to skip".
    func testComponentDeltasOldRecordYieldsEmptyReportNotSkip() throws {
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let snap = ProjectFingerprinter().snapshot(projectDir: dir, bridges: [:])
        // backend == nil
        let r1 = ProjectFingerprinter.componentDeltas(local: snap, backend: nil)
        XCTAssertFalse(r1.changed)
        XCTAssertFalse(r1.allNativeOnly, "no backend → must not permit skip")
        // backend with nil componentHashes
        let noHashes = StoredFingerprintComponents(
            sdkVersion: nil, wasmKitVersion: nil, bridgeDefinitions: nil, linkedFrameworks: nil,
            deploymentTarget: nil, swiftCompilerVersion: nil, nativeSwiftFileCount: nil,
            nativeGeneratedStubCount: nil, componentHashes: nil,
            nativeSwiftFiles: nil, nativeGeneratedStubs: nil)
        let r2 = ProjectFingerprinter.componentDeltas(local: snap, backend: noHashes)
        XCTAssertFalse(r2.changed)
        XCTAssertFalse(r2.allNativeOnly, "no componentHashes → must not permit skip")
    }
}

// MARK: - Push flow: native-only-drift gate (skip offered only when sound)

/// Exercises the push/release fingerprint gate's PURE decision function,
/// `PushFlow.evaluateFingerprintGate`, across every path:
///   • match → `.compatible`;
///   • `--force` on any mismatch → `.forced` (blanket override);
///   • native-only drift + `--allow-native-drift` → `.proceedNativeDrift`;
///   • native-only drift, no flag → `.promptNativeDrift` (TTY consent, else SAFE);
///   • a patch-affecting change → `.refuse` even WITH `--allow-native-drift` (the
///     flag does NOT bypass it; only `--force` does);
///   • no component detail (old backend record) → `.refuse` (never silently ship).
final class PushFlowNativeDriftTests: XCTestCase {
    private func makeProject(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fpgate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A `FingerprintRecord` carrying the stored components of a snapshot — i.e. what
    /// the backend would return as the active fingerprint when this snapshot was
    /// registered. `withComponents: false` simulates an OLD record (no breakdown).
    private func record(from s: ProjectFingerprinter.Snapshot,
                        withComponents: Bool = true) -> FingerprintRecord {
        let c = s.components
        let stored = withComponents ? StoredFingerprintComponents(
            sdkVersion: c.sdkVersion, wasmKitVersion: c.wasmKitVersion,
            bridgeDefinitions: c.bridgeDefinitions, linkedFrameworks: c.linkedFrameworks,
            deploymentTarget: c.deploymentTarget, swiftCompilerVersion: c.swiftCompilerVersion,
            nativeSwiftFileCount: c.nativeSwiftFiles.count,
            nativeGeneratedStubCount: c.nativeGeneratedStubs.count,
            componentHashes: Dictionary(uniqueKeysWithValues: s.componentHashes.map { ($0.label, $0.hash) }),
            nativeSwiftFiles: c.nativeSwiftFiles, nativeGeneratedStubs: c.nativeGeneratedStubs) : nil
        return FingerprintRecord(id: "fp-1", appId: "app-1", fingerprint: s.fingerprint,
                                 isActive: true, appVersion: "1.0.0", components: stored)
    }

    /// An identical shell → `.compatible` (nothing to override).
    func testGateCompatibleWhenUnchanged() throws {
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let snap = ProjectFingerprinter().snapshot(projectDir: dir, bridges: [:])
        let decision = PushFlow.evaluateFingerprintGate(
            snapshot: snap, active: record(from: snap), force: false, allowNativeDrift: false)
        XCTAssertEqual(decision, .compatible)
    }

    /// A NATIVE-ONLY drift + `--allow-native-drift` → proceed.
    func testGateProceedsOnNativeOnlyDriftWithFlag() throws {
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let fp = ProjectFingerprinter()
        let before = fp.snapshot(projectDir: dir, bridges: [:], deploymentTarget: "iOS 17.0")
        let after = fp.snapshot(projectDir: dir, bridges: [:], deploymentTarget: "iOS 18.0")
        let decision = PushFlow.evaluateFingerprintGate(
            snapshot: after, active: record(from: before), force: false, allowNativeDrift: true)
        guard case .proceedNativeDrift(let note) = decision else {
            return XCTFail("native-only drift + flag must proceed; got \(decision)")
        }
        XCTAssertTrue(note.contains("NATIVE-ONLY DRIFT"))
        XCTAssertTrue(note.contains("Deployment target"), "the native-only component should be named")
    }

    /// A NATIVE-ONLY drift WITHOUT the flag → prompt (interactive consent path).
    /// The decision carries the prompt + the SAFE declined message naming the flag.
    func testGatePromptsOnNativeOnlyDriftWithoutFlag() throws {
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let fp = ProjectFingerprinter()
        let before = fp.snapshot(projectDir: dir, bridges: [:], linkedFrameworks: ["Foundation"])
        let after = fp.snapshot(projectDir: dir, bridges: [:], linkedFrameworks: ["Foundation", "MapKit"])
        let decision = PushFlow.evaluateFingerprintGate(
            snapshot: after, active: record(from: before), force: false, allowNativeDrift: false)
        guard case .promptNativeDrift(let prompt, _, let declined) = decision else {
            return XCTFail("native-only drift without flag must prompt; got \(decision)")
        }
        XCTAssertTrue(prompt.contains("Ship the view patch anyway?"))
        XCTAssertTrue(declined.contains("--allow-native-drift"),
                      "the safe refusal must name the non-interactive flag")
    }

    /// SAFETY: a PATCH-AFFECTING change is REFUSED even WITH `--allow-native-drift`.
    /// The flag must never bypass a change that can reach the shipped patch.
    func testGateRefusesPatchAffectingEvenWithAllowDriftFlag() throws {
        let fp = ProjectFingerprinter()
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let before = fp.snapshot(projectDir: dir, bridges: [:])
        // Add a NATIVE file → "native swift files" (patch-affecting).
        try "class B { @objc func g() {} }".write(
            to: dir.appendingPathComponent("Brand.swift"), atomically: true, encoding: .utf8)
        let after = fp.snapshot(projectDir: dir, bridges: [:])
        let decision = PushFlow.evaluateFingerprintGate(
            snapshot: after, active: record(from: before), force: false, allowNativeDrift: true)
        guard case .refuse(let message) = decision else {
            return XCTFail("ZERO-FALSE-NEGATIVE: patch-affecting change must be refused; got \(decision)")
        }
        XCTAssertTrue(message.contains("PATCH-AFFECTING"),
                      "the refusal must explain why --allow-native-drift didn't help")
        XCTAssertTrue(message.contains("--force"), "only --force can override a patch-affecting change")
    }

    /// SAFETY: a MIX (native-only + patch-affecting) is refused with the flag.
    func testGateRefusesMixedDriftWithFlag() throws {
        let fp = ProjectFingerprinter()
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let before = fp.snapshot(projectDir: dir, bridges: [:], deploymentTarget: "iOS 17.0")
        try "class B { @objc func g() {} }".write(
            to: dir.appendingPathComponent("Brand.swift"), atomically: true, encoding: .utf8)
        let after = fp.snapshot(projectDir: dir, bridges: [:], deploymentTarget: "iOS 18.0")
        let decision = PushFlow.evaluateFingerprintGate(
            snapshot: after, active: record(from: before), force: false, allowNativeDrift: true)
        guard case .refuse = decision else {
            return XCTFail("a mix with a patch-affecting change must be refused; got \(decision)")
        }
    }

    /// `--force` overrides EVERYTHING — even a patch-affecting change.
    func testGateForcedOverridesPatchAffecting() throws {
        let fp = ProjectFingerprinter()
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let before = fp.snapshot(projectDir: dir, bridges: [:])
        try "class B { @objc func g() {} }".write(
            to: dir.appendingPathComponent("Brand.swift"), atomically: true, encoding: .utf8)
        let after = fp.snapshot(projectDir: dir, bridges: [:])
        let decision = PushFlow.evaluateFingerprintGate(
            snapshot: after, active: record(from: before), force: true, allowNativeDrift: false)
        guard case .forced(let warning) = decision else {
            return XCTFail("--force must override; got \(decision)")
        }
        XCTAssertTrue(warning.contains("--force overriding"))
    }

    /// SAFETY: an OLD backend record (no componentHashes) can't be classified, so a
    /// mismatch is REFUSED even with `--allow-native-drift` — never silently shipped.
    func testGateRefusesWhenNoComponentDetailEvenWithFlag() throws {
        let dir = try makeProject(["A.swift": "class A { @objc func f() {} }"])
        let fp = ProjectFingerprinter()
        let before = fp.snapshot(projectDir: dir, bridges: [:], deploymentTarget: "iOS 17.0")
        let after = fp.snapshot(projectDir: dir, bridges: [:], deploymentTarget: "iOS 18.0")
        // Old record: same fingerprint as `before` but NO component breakdown.
        let oldRecord = record(from: before, withComponents: false)
        let decision = PushFlow.evaluateFingerprintGate(
            snapshot: after, active: oldRecord, force: false, allowNativeDrift: true)
        guard case .refuse = decision else {
            return XCTFail("no component detail → must refuse (can't prove native-only); got \(decision)")
        }
    }

    /// The DeltaReport flags are the exact predicates the gate branches on.
    func testDeltaReportGatePredicates() {
        let nativeOnly = ProjectFingerprinter.ComponentDelta(
            label: "deployment target", kind: .nativeOnly, detailLines: ["x"])
        let affecting = ProjectFingerprinter.ComponentDelta(
            label: "native swift files", kind: .patchAffecting, detailLines: ["y"])
        XCTAssertFalse(ProjectFingerprinter.DeltaReport(deltas: []).allNativeOnly)
        let r1 = ProjectFingerprinter.DeltaReport(deltas: [nativeOnly])
        XCTAssertTrue(r1.allNativeOnly); XCTAssertFalse(r1.hasPatchAffecting)
        let r2 = ProjectFingerprinter.DeltaReport(deltas: [nativeOnly, affecting])
        XCTAssertFalse(r2.allNativeOnly); XCTAssertTrue(r2.hasPatchAffecting)
    }
}

// MARK: - WASM convergence loop (auto-reclassify-on-failure)

/// A scripted compiler that fails until a named "culprit" file is removed, used
/// to test the convergence loop without invoking the real (heavy) toolchain.
private struct ScriptedCompiler: WasmCompiling {
    let failingFileName: String
    func compile(sources: [URL], outputModule: URL) throws -> WasmCompileResult {
        if let bad = sources.first(where: { $0.lastPathComponent == failingFileName }) {
            return WasmCompileResult(
                status: .failure(reason: "scripted failure"),
                moduleURL: nil,
                log: "\(bad.path):1:1: error: scripted compile failure\n")
        }
        // Touch the output so callers can observe a "module".
        try? Data().write(to: outputModule)
        return WasmCompileResult(status: .success, moduleURL: outputModule, log: "ok")
    }
}

final class WasmConvergenceTests: XCTestCase {
    func testConvergenceDemotesFailingCandidate() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let good = tmp.appendingPathComponent("Good_wasm.swift")
        let bad = tmp.appendingPathComponent("Bad_wasm.swift")
        try "func a() {}".write(to: good, atomically: true, encoding: .utf8)
        try "func b() {}".write(to: bad, atomically: true, encoding: .utf8)

        let convergence = WasmConvergence(compiler: ScriptedCompiler(failingFileName: "Bad_wasm.swift"))
        let outcome = try convergence.converge(
            [
                .init(functionID: "Good", sourceFile: good, exports: ["a"]),
                .init(functionID: "Bad", sourceFile: bad, exports: ["b"]),
            ],
            outputModule: tmp.appendingPathComponent("out.wasm"))

        XCTAssertFalse(outcome.toolchainUnavailable)
        XCTAssertEqual(outcome.compiled.map { $0.functionID }, ["Good"])
        XCTAssertEqual(outcome.reclassifiedNative.map { $0.functionID }, ["Bad"],
                       "the non-compiling candidate must be demoted to native (safe)")
        XCTAssertNotNil(outcome.moduleURL)
    }

    /// When the iteration budget is exhausted WITHOUT a successful compile, the
    /// surviving candidates did NOT ship — they must be reported as DEMOTED, not
    /// `compiled`, and `compiled` must stay consistent with `moduleURL == nil`.
    /// (The old code returned `compiled: survivors` here, so callers misreported a
    /// non-zero "compiled" count with no module emitted.)
    func testConvergenceExhaustedBudgetReportsNoCompiledUnits() throws {
        // A compiler that always fails with an UNATTRIBUTABLE error (names no
        // candidate file), so the loop escalates tiers and never converges.
        struct AlwaysFailUnattributable: WasmCompiling {
            func compile(sources: [URL], outputModule: URL) throws -> WasmCompileResult {
                WasmCompileResult(status: .failure(reason: "unattributable"),
                                  moduleURL: nil,
                                  log: "error: a module-wide failure naming no candidate\n")
            }
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = tmp.appendingPathComponent("A_wasm.swift")
        try "func a() {}".write(to: a, atomically: true, encoding: .utf8)

        let convergence = WasmConvergence(compiler: AlwaysFailUnattributable())
        let outcome = try convergence.converge(
            [.init(functionID: "A", sourceFile: a, exports: ["a"])],
            outputModule: tmp.appendingPathComponent("out.wasm"),
            maxIterations: 2)
        XCTAssertNil(outcome.moduleURL, "no module should be emitted")
        XCTAssertTrue(outcome.compiled.isEmpty,
                      "compiled must be empty when no module shipped; got \(outcome.compiled.map { $0.functionID })")
        XCTAssertEqual(outcome.reclassifiedNative.map { $0.functionID }, ["A"],
                       "the un-shippable candidate must be reported as demoted, not compiled")
    }

    func testConvergenceAllCompileNoDemotions() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = tmp.appendingPathComponent("A_wasm.swift")
        try "func a() {}".write(to: a, atomically: true, encoding: .utf8)

        let convergence = WasmConvergence(compiler: ScriptedCompiler(failingFileName: "NONE"))
        let outcome = try convergence.converge(
            [.init(functionID: "A", sourceFile: a, exports: ["a"])],
            outputModule: tmp.appendingPathComponent("out.wasm"))
        XCTAssertEqual(outcome.compiled.count, 1)
        XCTAssertTrue(outcome.reclassifiedNative.isEmpty)
    }

    /// Real end-to-end compile — skipped when the swift.org WASM toolchain is not
    /// installed (e.g. generic CI), so the suite stays green everywhere.
    func testRealWasmCompileOfFoundationFragment() throws {
        let compiler = SwiftWasmCompiler()
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping real compile")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("realwasm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let src = tmp.appendingPathComponent("Frag_wasm.swift")
        try """
        import Foundation
        @_cdecl("frag_compute")
        public func frag_compute(_ cents: Int32) -> Int32 {
            let d = Decimal(Int(cents)) / Decimal(100) * Decimal(string: "0.0875")!
            return Int32(truncating: NSDecimalNumber(decimal: d * 100))
        }
        """.write(to: src, atomically: true, encoding: .utf8)

        let out = tmp.appendingPathComponent("frag.wasm")
        let c = SwiftWasmCompiler(exportedSymbols: ["frag_compute"])
        let result = try c.compile(sources: [src], outputModule: out)
        XCTAssertEqual(result.status, .success, "real WASM compile failed:\n\(result.log)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "no .wasm emitted")
        // WASM magic bytes: 0x00 'a' 's' 'm'
        let head = try FileHandle(forReadingFrom: out).readData(ofLength: 4)
        XCTAssertEqual([UInt8](head), [0x00, 0x61, 0x73, 0x6d], "output is not a WASM module")
    }
}

// MARK: - C-header import ABI (the Embedded Foundation bridge codegen)

final class CHeaderBridgeTests: XCTestCase {
    func testHeaderDeclaresCleanFlatImportABI() {
        let h = CHeaderBridge().headerSource()
        // The import_module/import_name attribute macro (NOT @_extern(wasm)).
        XCTAssertTrue(h.contains(#"__attribute__((import_module(mod), import_name(nm)))"#),
                      "header must use Clang's import_module/import_name attributes")
        // The proven module namespace + the three Foundation-value imports.
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","decimal_op")"#))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","json_get_i64")"#))
        XCTAssertTrue(h.contains(#"WASM_IMPORT("patch_host","now_unix_millis")"#))
        // Exact flat signature for decimal_op (matches PatchSDK.FoundationBridge).
        XCTAssertTrue(h.contains("int64_t host_decimal_op(int32_t op, int64_t a, int64_t b, int32_t scale);"))
        // The Swift wrapper must NOT declare the imports via @_extern(wasm) (the
        // mangled ABI WasmKit rejects); they are declared in C. (The header's
        // prose mentions @_extern only to document the contrast.)
        XCTAssertFalse(CHeaderBridge().swiftBridgeSource().contains("@_extern"),
                       "Swift bridge must call C imports, not declare @_extern(wasm)")
    }

    func testSwiftWrappersMatchOpCodes() {
        let s = CHeaderBridge().swiftBridgeSource()
        XCTAssertTrue(s.contains("import CHost"))
        XCTAssertTrue(s.contains("PATCH_DECIMAL_MUL: Int32 = 0"))
        XCTAssertTrue(s.contains("PATCH_DECIMAL_DIV: Int32 = 1"))
        XCTAssertTrue(s.contains("PATCH_DECIMAL_ADD: Int32 = 2"))
        XCTAssertTrue(s.contains("PATCH_DECIMAL_SUB: Int32 = 3"))
        XCTAssertTrue(s.contains("PATCH_DECIMAL_DIV_FLOOR: Int32 = 4"))
        XCTAssertTrue(s.contains("func patchDecimalMul"))
        XCTAssertTrue(s.contains("func patchJSONGetI64"))
        XCTAssertTrue(s.contains("func patchNowUnixMillis"))
    }

    func testFilesLayout() {
        let files = CHeaderBridge().files(swiftTargetName: "PatchWasm")
        let paths = Set(files.map(\.relativePath))
        XCTAssertTrue(paths.contains("Sources/CHost/include/chost.h"))
        XCTAssertTrue(paths.contains("Sources/CHost/shim.c"))
        XCTAssertTrue(paths.contains("Sources/PatchWasm/_patch_host_bridge.swift"))
        // The shim includes the header so the C target produces an object (and
        // thus emits the import declarations).
        let shim = files.first { $0.relativePath.hasSuffix("shim.c") }
        XCTAssertEqual(shim?.contents.contains(#"#include "include/chost.h""#), true)
    }

    /// Real embedded compile of a C-header-bridged fragment — skipped without the
    /// swift.org embedded WASM SDK. Proves the generated header + manifest produce
    /// a tiny module that imports patch_host.* via the clean flat ABI.
    func testRealEmbeddedCompileViaCHeaderBridge() throws {
        let compiler = SwiftWasmCompiler(tier: .t0Embedded)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping embedded compile")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("embedcompile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // An embedded fragment that uses Decimal-via-bridge (no `import Foundation`).
        let src = tmp.appendingPathComponent("Frag_wasm.swift")
        try """
        @_cdecl("taxCents")
        public func taxCents(_ taxable: Int32, _ taxBP: Int32) -> Int32 {
            let num = patchDecimalMul(Int64(taxable), Int64(taxBP))
            return Int32(truncatingIfNeeded: patchDecimalDivFloor(num, 10_000))
        }
        """.write(to: src, atomically: true, encoding: .utf8)

        let out = tmp.appendingPathComponent("frag.wasm")
        let c = SwiftWasmCompiler(exportedSymbols: ["taxCents", "patch_malloc", "patch_free"], tier: .t0Embedded)
        let result = try c.compile(sources: [src], outputModule: out)
        XCTAssertEqual(result.status, .success, "embedded compile via C-header bridge failed:\n\(result.log)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "no .wasm emitted")
        // Embedded module must be TINY (well under 1 MB; the full SDK floor is ~53 MB).
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        XCTAssertLessThan(size, 1_000_000, "embedded module should be tens of KB, got \(size) bytes")
        let head = try FileHandle(forReadingFrom: out).readData(ofLength: 4)
        XCTAssertEqual([UInt8](head), [0x00, 0x61, 0x73, 0x6d], "output is not a WASM module")
    }
}

// MARK: - BuildPipeline tier selection

final class BuildPipelineTierTests: XCTestCase {
    private func write(_ src: String, to dir: URL, name: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try src.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    /// A pure-logic app (no Foundation, no embedded blockers) selects T0 Embedded.
    func testPureLogicSelectsT0() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = try write("""
        enum Calc { static func dbl(_ x: Int) -> Int { x * 2 } }
        """, to: tmp, name: "Calc.swift")

        let engine = PartitioningEngine()
        let report = try engine.analyze(directory: tmp)
        let pipeline = BuildPipeline()
        let (tier, rationale) = pipeline.selectStartTier(report: report, wasmSources: [src], supportSources: [src])
        XCTAssertEqual(tier, .t0Embedded, "pure logic → T0. rationale: \(rationale)")
    }

    /// A generated JSON-ABI wrapper (uses in-module Codable/JSONEncoder) forces
    /// the module up to T2 — the realistic case for the current Codable codegen.
    func testCodableABIWrapperSelectsT2() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dev = try write("""
        enum Calc { static func dbl(_ x: Int) -> Int { x * 2 } }
        """, to: tmp, name: "Calc.swift")
        // A generated wrapper that looks like CodeEmitter output (import Foundation + JSON).
        let gen = try write("""
        import Foundation
        @_cdecl("dbl")
        public func dbl__abi(_ ptr: Int32, _ len: Int32) -> Int64 {
            let d = try! JSONDecoder().decode([Int].self, from: Data())
            _ = JSONEncoder()
            return Int64(d.count)
        }
        """, to: tmp, name: "dbl_wasm.swift")

        let engine = PartitioningEngine()
        let report = try engine.analyze(directory: tmp)
        let pipeline = BuildPipeline()
        let (tier, rationale) = pipeline.selectStartTier(report: report, wasmSources: [gen], supportSources: [dev])
        XCTAssertEqual(tier, .t2Foundation,
                       "JSON-Codable ABI wrapper forces T2. rationale: \(rationale)")
    }

    /// END-TO-END (dry run): the pipeline analyzes a SwiftUI view, frees its pure
    /// value members, and emits BOTH the OTA `_pv_<Type>_<member>_wasm.swift`
    /// modules and the frozen `<Type>_values_bridge.swift` native shim — proving
    /// the value-lift path is wired through `Patch build`. `body` and view-DSL
    /// members produce no codegen (they stay verbatim in the native source).
    func testValueLiftPipelineEmitsWasmAndBridge() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vlift-\(UUID().uuidString)")
        let build = tmp.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try write("""
        import SwiftUI
        struct ProfileCard: View {
            @State private var expanded = false
            let userName: String
            var primaryFontSize: CGFloat { 17 }
            var greeting: String { "Hi" }
            func rowHeight(for index: Int) -> CGFloat { index == 0 ? 64 : 44 }
            var body: some View { Text(greeting).font(.system(size: primaryFontSize)) }
        }
        """, to: tmp, name: "ProfileCard.swift")

        let pipeline = BuildPipeline()
        let result = try pipeline.run(
            sourceDir: tmp, buildDir: build, compiler: StubWasmCompiler(), dryRun: true)

        let wasmNames = Set(result.generatedWasmSources.map { $0.lastPathComponent })
        XCTAssertTrue(wasmNames.contains("_pv_ProfileCard_primaryFontSize_wasm.swift"),
                      "font-size token should emit a _pv_ WASM module. Got: \(wasmNames)")
        XCTAssertTrue(wasmNames.contains("_pv_ProfileCard_greeting_wasm.swift"),
                      "greeting label should emit a _pv_ WASM module. Got: \(wasmNames)")
        XCTAssertTrue(wasmNames.contains("_pv_ProfileCard_rowHeight_wasm.swift"),
                      "rowHeight helper should emit a _pv_ WASM module. Got: \(wasmNames)")

        let bridgeNames = Set(result.generatedBridgeSources.map { $0.lastPathComponent })
        XCTAssertTrue(bridgeNames.contains("ProfileCard_values_bridge.swift"),
                      "should emit one frozen native value-shim file per view. Got: \(bridgeNames)")
        // The exported symbols include the _pv_ functions + the shared allocator.
        XCTAssertTrue(result.exportSymbols.contains("_pv_ProfileCard_greeting"))
        XCTAssertTrue(result.exportSymbols.contains("patch_malloc"))

        // The frozen shim reads via Patch.value / Patch.call (no body rewrite).
        let bridge = try String(contentsOf: build.appendingPathComponent("ProfileCard_values_bridge.swift"), encoding: .utf8)
        XCTAssertTrue(bridge.contains("Patch.value(\"ProfileCard.greeting\""))
        XCTAssertTrue(bridge.contains("CGFloat(Patch.value(\"ProfileCard.primaryFontSize\""))
        XCTAssertTrue(bridge.contains("Patch.call(\"ProfileCard.rowHeight\""))
    }
}
