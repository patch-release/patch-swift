// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// The bar from the task: prove the engine's auto-generated `_wasm.swift`
/// is genuinely EXECUTABLE across the ABI. These tests:
///   1. emit `_wasm.swift` via `CodeEmitter` for representative functions,
///   2. compile them to a real `.wasm` with the swift.org toolchain
///      (skipped when the toolchain is absent so the suite stays green),
///   3. host-RUN the module via WasmKit using the EXACT (ptr,len)+packed-i64
///      JSON ABI the SDK's `Patch.callPacked`/`callJSON` use, and
///   4. decode the JSON result and assert the expected value.
///
/// This is the host counterpart to `SwiftWasmCompiler` proving the guest side:
/// together they show encode args → invoke export → decode result round-trips
/// end-to-end with no hand-written ABI code.
final class GeneratedABIExecutableTests: XCTestCase {

    // MARK: - Minimal host runner (mirrors PatchSDK's callPacked)

    /// Instantiate a wasm module (WASI satisfied + reactor `_initialize`).
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
            // Provide the FULL patch_host bridge (mirrors PatchSDK.FoundationBridge,
            // incl. the expanded formatter/regex/date/typed-JSON surface). The
            // generated C header declares ALL host imports, so a T0 module imports
            // the whole surface even when a fragment uses only one — every runner
            // must satisfy them all to instantiate.
            PatchHostTestImports.register(into: &imports, store: store)
            let module = try parseWasm(bytes: wasm)
            self.instance = try module.instantiate(store: store, imports: imports)
            try wasi.initialize(instance)
        }

        func memory() throws -> Memory {
            guard let m = instance.exports[memory: "memory"] else {
                throw NSError(domain: "abi", code: 1, userInfo: [NSLocalizedDescriptionKey: "no memory export"])
            }
            return m
        }

        /// Allocate guest memory, copy bytes in, return (ptr, len).
        func writeBuffer(_ bytes: [UInt8]) throws -> (UInt32, UInt32) {
            guard let malloc = instance.exports[function: "patch_malloc"] else {
                throw NSError(domain: "abi", code: 2, userInfo: [NSLocalizedDescriptionKey: "no patch_malloc"])
            }
            let ptr = try malloc([.i32(UInt32(bytes.count))])[0].i32
            let mem = try memory()
            mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: bytes.count) { raw in
                raw.copyBytes(from: bytes)
            }
            return (ptr, UInt32(bytes.count))
        }

        func read(ptr: UInt32, len: UInt32) throws -> [UInt8] {
            let mem = try memory()
            let all = mem.data
            return [UInt8](all[Int(ptr)..<Int(ptr) + Int(len)])
        }

        /// The canonical structured-blob call: write `input` → invoke export →
        /// unpack the i64 (ptr,len) result → read the output bytes. Exactly the
        /// shape `PatchSDK.Patch.callPacked` implements.
        func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
            guard let fn = instance.exports[function: name] else {
                throw NSError(domain: "abi", code: 3, userInfo: [NSLocalizedDescriptionKey: "no export \(name)"])
            }
            let (inPtr, inLen) = try writeBuffer(input)
            let packed = try fn([.i32(inPtr), .i32(inLen)])[0].i64
            let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
            let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
            return try read(ptr: outPtr, len: outLen)
        }
    }

    private func compileOrSkip(supportSource: String, generatedFiles: [(name: String, content: String)],
                               exports: [String]) throws -> [UInt8] {
        let compiler = SwiftWasmCompiler(exportedSymbols: exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping executable round-trip")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("abiexec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var sources: [URL] = []
        let support = tmp.appendingPathComponent("Logic.swift")
        try supportSource.write(to: support, atomically: true, encoding: .utf8)
        sources.append(support)
        for f in generatedFiles {
            let u = tmp.appendingPathComponent(f.name)
            try f.content.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "WASM compile failed:\n\(result.log)")
        return [UInt8](try Data(contentsOf: out))
    }

    // MARK: - 1. Pure Decimal calc, JSON (ptr,len) round-trip

    /// A pure `Decimal`-arithmetic function exported wholesale by the engine, then
    /// invoked through the generated JSON (ptr,len) ABI. Proves the headline pure
    /// path runs real Foundation math in WASM and returns the right number.
    func testPureDecimalCalcRoundTrip() throws {
        let logic = """
        import Foundation

        public enum Tax {
            // Decimal tax math (the wasm-safe Foundation surface the engine targets).
            public static func priceWithTaxCents(_ cents: Int, _ taxBasisPoints: Int) -> Int {
                let base = Decimal(cents)
                let tax = base * Decimal(taxBasisPoints) / Decimal(10_000)
                let total = base + tax
                var rounded = Decimal()
                var src = total
                NSDecimalRound(&rounded, &src, 0, .plain)
                return (rounded as NSDecimalNumber).intValue
            }
        }
        """
        // Emit the @_cdecl ABI wrapper via the REAL CodeEmitter.
        let export = CodeEmitter.PureExport(
            exportName: "priceWithTaxCents",
            callee: "Tax.priceWithTaxCents",
            parameters: [(label: "_", name: "cents", type: "Int"),
                         (label: "_", name: "taxBasisPoints", type: "Int")],
            returnType: "Int")
        let emitted = CodeEmitter().emitPureExportFile(export, includeAllocator: true)

        let wasm = try compileOrSkip(
            supportSource: logic,
            generatedFiles: [(name: emitted.fileName, content: emitted.source)],
            exports: emitted.exports)

        let runner = try Runner(wasm: wasm)

        // encode args → invoke export → decode result.
        struct Args: Encodable { let cents: Int; let taxBasisPoints: Int }
        struct Out: Decodable { let value: Int }
        let inBytes = [UInt8](try JSONEncoder().encode(Args(cents: 10_000, taxBasisPoints: 875)))
        let outBytes = try runner.callPacked("priceWithTaxCents", inBytes)
        let out = try JSONDecoder().decode(Out.self, from: Data(outBytes))
        // 10000 + 10000*875/10000 = 10000 + 875 = 10875.
        XCTAssertEqual(out.value, 10_875, "Decimal tax calc must run in WASM and return 10875")
    }

    // MARK: - 2. Codable struct in / struct out, JSON (ptr,len) round-trip

    /// A pure function taking a Codable struct and returning a Codable struct,
    /// exported by the engine and invoked through the generated ABI. Proves the
    /// Codable-in/Codable-out shape (the one the demo needs) auto-generates and
    /// executes.
    func testCodableInOutRoundTrip() throws {
        let logic = """
        import Foundation

        public struct CartLine: Codable {
            public let priceCents: Int
            public let qty: Int
        }
        public struct Summary: Codable, Equatable {
            public let subtotalCents: Int
            public let taxCents: Int
            public let totalCents: Int
        }
        public enum Pricing {
            public static func summarize(lines: [CartLine], taxBasisPoints: Int) -> Summary {
                let subtotal = lines.reduce(0) { $0 + $1.priceCents * $1.qty }
                let tax = subtotal * taxBasisPoints / 10_000
                return Summary(subtotalCents: subtotal, taxCents: tax, totalCents: subtotal + tax)
            }
        }
        """
        let export = CodeEmitter.PureExport(
            exportName: "summarize",
            callee: "Pricing.summarize",
            parameters: [(label: "lines", name: "lines", type: "[CartLine]"),
                         (label: "taxBasisPoints", name: "taxBasisPoints", type: "Int")],
            returnType: "Summary")
        let emitted = CodeEmitter().emitPureExportFile(export, includeAllocator: true)

        let wasm = try compileOrSkip(
            supportSource: logic,
            generatedFiles: [(name: emitted.fileName, content: emitted.source)],
            exports: emitted.exports)

        let runner = try Runner(wasm: wasm)

        struct Line: Codable { let priceCents: Int; let qty: Int }
        struct Args: Encodable { let lines: [Line]; let taxBasisPoints: Int }
        struct Summary: Decodable, Equatable { let subtotalCents: Int; let taxCents: Int; let totalCents: Int }
        struct Out: Decodable { let value: Summary }

        let args = Args(lines: [Line(priceCents: 3000, qty: 2), Line(priceCents: 1250, qty: 1)],
                        taxBasisPoints: 875)
        let inBytes = [UInt8](try JSONEncoder().encode(args))
        let outBytes = try runner.callPacked("summarize", inBytes)
        let out = try JSONDecoder().decode(Out.self, from: Data(outBytes))
        // subtotal = 2*3000 + 1250 = 7250; tax = 7250*875/10000 = 634; total = 7884.
        XCTAssertEqual(out.value, Summary(subtotalCents: 7250, taxCents: 634, totalCents: 7884))
    }

    // MARK: - 3. SwiftUI value-lift: font size 17→22 round-trip (CGFloat → Double)

    /// The headline OTA story: a `CGFloat` font-size design token lifted from a
    /// SwiftUI view compiles into the module as `_pv_ProfileCard_primaryFontSize`
    /// and is read by the native shim via `Patch.value`. The OTA edit (17 → 22)
    /// lives ONLY in the WASM `_pv_` function; the native shell is unchanged. Proves
    /// the value crosses the JSON ABI as a Double and round-trips to 22.
    func testValueLiftFontSizeRoundTrip() throws {
        // The WASM `_pv_` function body is the OTA-editable unit. The OTA edit is
        // here: was `17`, pushed as `22`.
        let export = CodeEmitter.ValueExport(
            typeName: "ProfileCard", memberName: "primaryFontSize", isMethod: false,
            parameters: [], returnType: "CGFloat", abiReturnType: "Double",
            bodyStatements: ["return 22  // OTA EDIT: was 17"])
        let emitted = CodeEmitter().emitValueExportFile(export, includeAllocator: true)
        XCTAssertEqual(export.exportName, "_pv_ProfileCard_primaryFontSize")

        let wasm = try compileOrSkip(
            supportSource: "// no developer support source needed for a pure scalar token\n",
            generatedFiles: [(name: emitted.fileName, content: emitted.source)],
            exports: emitted.exports)
        let runner = try Runner(wasm: wasm)

        struct Out: Decodable { let value: Double }
        // No-input value: the shim sends "{}" (matching PatchSDK.valueJSON).
        let outBytes = try runner.callPacked("_pv_ProfileCard_primaryFontSize", [UInt8]("{}".utf8))
        let out = try JSONDecoder().decode(Out.self, from: Data(outBytes))
        XCTAssertEqual(out.value, 22, "font size should ship OTA as 22 (was 17)")
        // The native shim wraps the Double back to CGFloat at the use site.
        XCTAssertEqual(CGFloat(out.value), CGFloat(22))
    }

    // MARK: - 4. SwiftUI value-lift: label string "Hi" → "Welcome back" round-trip

    func testValueLiftLabelStringRoundTrip() throws {
        let export = CodeEmitter.ValueExport(
            typeName: "ProfileCard", memberName: "greeting", isMethod: false,
            parameters: [], returnType: "String", abiReturnType: "String",
            bodyStatements: ["return \"Welcome back\"  // OTA EDIT: was \"Hi\""])
        let emitted = CodeEmitter().emitValueExportFile(export, includeAllocator: true)

        let wasm = try compileOrSkip(
            supportSource: "// pure string label, no support source\n",
            generatedFiles: [(name: emitted.fileName, content: emitted.source)],
            exports: emitted.exports)
        let runner = try Runner(wasm: wasm)

        struct Out: Decodable { let value: String }
        let outBytes = try runner.callPacked("_pv_ProfileCard_greeting", [UInt8]("{}".utf8))
        let out = try JSONDecoder().decode(Out.self, from: Data(outBytes))
        XCTAssertEqual(out.value, "Welcome back", "label should ship OTA as \"Welcome back\" (was \"Hi\")")
    }

    // MARK: - 5. SwiftUI value-lift: value helper WITH inputs (Patch.call)

    /// A pure value helper `rowHeight(for:) -> CGFloat` lifts with its `Int` input
    /// and round-trips through the args envelope (the `Patch.call` path).
    func testValueLiftHelperWithArgsRoundTrip() throws {
        let export = CodeEmitter.ValueExport(
            typeName: "ProfileCard", memberName: "rowHeight", isMethod: true,
            parameters: [(label: "for", name: "index", declType: "Int", abiType: "Int")],
            returnType: "CGFloat", abiReturnType: "Double",
            bodyStatements: ["return index == 0 ? 64 : 44"])
        let emitted = CodeEmitter().emitValueExportFile(export, includeAllocator: true)

        let wasm = try compileOrSkip(
            supportSource: "// pure layout-math helper\n",
            generatedFiles: [(name: emitted.fileName, content: emitted.source)],
            exports: emitted.exports)
        let runner = try Runner(wasm: wasm)

        struct Args: Encodable { let index: Int }
        struct Out: Decodable { let value: Double }
        let out0 = try JSONDecoder().decode(Out.self, from: Data(
            try runner.callPacked("_pv_ProfileCard_rowHeight",
                                  [UInt8](try JSONEncoder().encode(Args(index: 0))))))
        let out3 = try JSONDecoder().decode(Out.self, from: Data(
            try runner.callPacked("_pv_ProfileCard_rowHeight",
                                  [UInt8](try JSONEncoder().encode(Args(index: 3))))))
        XCTAssertEqual(out0.value, 64)
        XCTAssertEqual(out3.value, 44)
    }

    // MARK: - 6. SwiftUI value-lift: the generated native shim (frozen shell)

    /// The native shim is what stays in the App Store binary; its SIGNATURES are
    /// frozen (the fingerprint locks them) while the value rides OTA. Assert the
    /// emitter produces the expected frozen shapes: a CGFloat property wrapped from
    /// Double via Patch.value, a String property via Patch.value, and a CGFloat
    /// method via Patch.call with a Double-converted Int-free arg.
    func testValueLiftNativeShimShape() {
        let emitter = CodeEmitter()
        let fontSize = CodeEmitter.ValueExport(
            typeName: "ProfileCard", memberName: "primaryFontSize", isMethod: false,
            parameters: [], returnType: "CGFloat", abiReturnType: "Double",
            bodyStatements: ["return 17"])
        let greeting = CodeEmitter.ValueExport(
            typeName: "ProfileCard", memberName: "greeting", isMethod: false,
            parameters: [], returnType: "String", abiReturnType: "String",
            bodyStatements: ["return \"Hi\""])
        let rowHeight = CodeEmitter.ValueExport(
            typeName: "ProfileCard", memberName: "rowHeight", isMethod: true,
            parameters: [(label: "for", name: "index", declType: "Int", abiType: "Int")],
            returnType: "CGFloat", abiReturnType: "Double",
            bodyStatements: ["return index == 0 ? 64 : 44"])

        let (fileName, src) = emitter.emitValueBridgeFile(
            typeName: "ProfileCard", exports: [fontSize, greeting, rowHeight])
        XCTAssertEqual(fileName, "ProfileCard_values_bridge.swift")
        // CGFloat property: Double value wrapped back to CGFloat.
        XCTAssertTrue(src.contains(
            "var primaryFontSize: CGFloat { CGFloat(Patch.value(\"ProfileCard.primaryFontSize\""),
            "font-size shim should read Patch.value and wrap to CGFloat\n\(src)")
        // String property: no wrap.
        XCTAssertTrue(src.contains(
            "var greeting: String { Patch.value(\"ProfileCard.greeting\""),
            "greeting shim should read Patch.value as String\n\(src)")
        // Method with arg: Patch.call, CGFloat-wrapped result, labeled param.
        XCTAssertTrue(src.contains("func rowHeight(for index: Int) -> CGFloat"),
                      "rowHeight signature should be frozen with its label\n\(src)")
        XCTAssertTrue(src.contains("Patch.call(\"ProfileCard.rowHeight\""),
                      "rowHeight shim should dispatch via Patch.call\n\(src)")
        // The frozen shell extends the original type (body stays in original source).
        XCTAssertTrue(src.contains("extension ProfileCard {"))
    }
}
