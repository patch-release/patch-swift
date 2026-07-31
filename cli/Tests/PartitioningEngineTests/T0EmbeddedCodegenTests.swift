// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// Proves the **auto-T0 (Embedded + host-bridge) codegen path**: an ordinary
/// scalar/Bool function auto-emits an Embedded-compatible `_wasm.swift` (no
/// in-module Foundation/JSONEncoder/Codable), compiles with the EMBEDDED WASM SDK,
/// and host-runs through the EXACT (ptr,len)+packed-i64 ABI the SDK uses — args
/// read via the `patch_host.json_get_i64` bridge, result hand-encoded as
/// `{"value":N}` — returning the right value. This is the size win: tens of KB
/// (T0) instead of ~57 MB (T2, the old in-guest-JSONEncoder path).
final class T0EmbeddedCodegenTests: XCTestCase {

    // MARK: - Host runner providing the patch_host bridge (mirrors FoundationBridge)

    private final class T0Runner {
        let store: Store
        let instance: Instance
        let wasi: WASIBridgeToHost
        init(wasm: [UInt8]) throws {
            let engine = Engine()
            self.store = Store(engine: engine)
            self.wasi = try WASIBridgeToHost()
            var imports = Imports()
            wasi.link(to: &imports, store: store)
            // Full patch_host bridge surface (real JSONSerialization json_get_i64
            // + the expanded formatter/regex/date/typed-JSON bridges). The generated
            // C header declares ALL imports, so a T0 module imports the whole
            // surface even when a fragment uses only one — register them all.
            PatchHostTestImports.register(into: &imports, store: store)
            let module = try parseWasm(bytes: wasm)
            self.instance = try module.instantiate(store: store, imports: imports)
            try wasi.initialize(instance)
        }

        func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
            guard let mem = instance.exports[memory: "memory"],
                  let malloc = instance.exports[function: "patch_malloc"],
                  let fn = instance.exports[function: name] else {
                throw NSError(domain: "t0", code: 1)
            }
            let inPtr = try malloc([.i32(UInt32(input.count))])[0].i32
            mem.withUnsafeMutableBufferPointer(offset: UInt(inPtr), count: input.count) { $0.copyBytes(from: input) }
            let packed = try fn([.i32(inPtr), .i32(UInt32(input.count))])[0].i64
            let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
            let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
            let all = mem.data
            return [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
        }
    }

    /// Compile an emitted T0 package (support source + generated wrapper) with the
    /// EMBEDDED SDK via the real SwiftWasmCompiler. Skips when the toolchain absent.
    private func compileT0OrSkip(support: String, wrapperFile: (name: String, content: String),
                                 exports: [String]) throws -> [UInt8] {
        let compiler = SwiftWasmCompiler(exportedSymbols: exports, tier: .t0Embedded)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping T0 round-trip")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("t0exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let supportURL = tmp.appendingPathComponent("Logic.swift")
        try support.write(to: supportURL, atomically: true, encoding: .utf8)
        let wrapperURL = tmp.appendingPathComponent(wrapperFile.name)
        try wrapperFile.content.write(to: wrapperURL, atomically: true, encoding: .utf8)
        let out = tmp.appendingPathComponent("module.wasm")
        let result = try compiler.compile(sources: [supportURL, wrapperURL], outputModule: out)
        XCTAssertEqual(result.status, .success, "T0 embedded compile failed:\n\(result.log)")
        return [UInt8](try Data(contentsOf: out))
    }

    // MARK: - Tier-selection unit checks (no toolchain needed)

    /// A scalar/Bool function auto-emits a T0-compatible wrapper (the headline
    /// change); a struct-returning function falls back to the Foundation wrapper.
    func testScalarFunctionEmitsT0Wrapper() {
        let scalar = CodeEmitter.PureExport(
            exportName: "orderTotalCents", callee: "Pricing.orderTotalCents",
            parameters: [(label: "_", name: "subtotalCents", type: "Int"),
                         (label: "_", name: "taxBasisPoints", type: "Int")],
            returnType: "Int")
        let emitted = CodeEmitter().emitPureExportFile(scalar, includeAllocator: true)
        XCTAssertFalse(emitted.source.contains("import Foundation"),
                       "T0 wrapper must not import Foundation\n\(emitted.source)")
        XCTAssertFalse(emitted.source.contains("JSONEncoder"))
        XCTAssertFalse(emitted.source.contains("JSONDecoder"))
        XCTAssertTrue(emitted.source.contains("import CHost"))
        XCTAssertTrue(emitted.source.contains("patchJSONGetI64"))
        let verdict = EmbeddedCompatibility().analyzeSource(emitted.source)
        XCTAssertEqual(verdict.tier, .t0Embedded,
                       "scalar wrapper must select T0; blockers=\(verdict.blockers)")

        let structRet = CodeEmitter.PureExport(
            exportName: "summarize", callee: "Pricing.summarize",
            parameters: [(label: "lines", name: "lines", type: "[CartLine]")],
            returnType: "Summary")
        let fb = CodeEmitter().emitPureExportFile(structRet, includeAllocator: true)
        XCTAssertTrue(fb.source.contains("JSONDecoder"),
                      "struct-shaped function must fall back to the Foundation wrapper")
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(fb.source).tier, .t2Foundation)
    }

    // MARK: - End-to-end: emit -> embedded compile -> host-run -> right value

    /// The demo's pricing logic, auto-emitted at T0, must compute $70.95 (7095).
    func testT0PricingRoundTripIsCorrect() throws {
        let logic = """
        public enum Pricing {
            public static func orderTotalCents(_ subtotalCents: Int, _ promoBasisPoints: Int,
                                               _ taxBasisPoints: Int, _ freeShipThresholdCents: Int,
                                               _ flatShipCents: Int) -> Int {
                let discount = subtotalCents * promoBasisPoints / 10_000
                let taxable = subtotalCents - discount
                let tax = taxable * taxBasisPoints / 10_000
                let shipping = subtotalCents > freeShipThresholdCents ? 0 : flatShipCents
                return taxable + tax + shipping
            }
        }
        """
        let export = CodeEmitter.PureExport(
            exportName: "orderTotalCents", callee: "Pricing.orderTotalCents",
            parameters: [(label: "_", name: "subtotalCents", type: "Int"),
                         (label: "_", name: "promoBasisPoints", type: "Int"),
                         (label: "_", name: "taxBasisPoints", type: "Int"),
                         (label: "_", name: "freeShipThresholdCents", type: "Int"),
                         (label: "_", name: "flatShipCents", type: "Int")],
            returnType: "Int")
        let emitted = CodeEmitter().emitPureExportFile(export, includeAllocator: true)
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded)

        let wasm = try compileT0OrSkip(
            support: logic, wrapperFile: (emitted.fileName, emitted.source), exports: emitted.exports)
        // Size proof: T0 module is tens of KB, not the ~57 MB T2 floor.
        XCTAssertLessThan(wasm.count, 2_000_000, "T0 module should be well under 2 MB (got \(wasm.count))")

        let runner = try T0Runner(wasm: wasm)
        struct Args: Encodable {
            let subtotalCents: Int; let promoBasisPoints: Int; let taxBasisPoints: Int
            let freeShipThresholdCents: Int; let flatShipCents: Int
        }
        struct Out: Decodable { let value: Int }
        // subtotal $75.00, 10% promo, 8.75% tax, free ship over $50 → discount 750,
        // taxable 6750, tax 590, shipping 0 → total 7340.
        let args = Args(subtotalCents: 7500, promoBasisPoints: 1000, taxBasisPoints: 875,
                        freeShipThresholdCents: 5000, flatShipCents: 599)
        let inBytes = [UInt8](try JSONEncoder().encode(args))
        let out = try JSONDecoder().decode(Out.self, from: Data(try runner.callPacked("orderTotalCents", inBytes)))
        XCTAssertEqual(out.value, 7340, "T0 pricing must compute the right total")

        // Cross-check against the same pure Swift logic running natively.
        func native(_ s: Int, _ p: Int, _ t: Int, _ f: Int, _ sh: Int) -> Int {
            let discount = s * p / 10_000; let taxable = s - discount
            let tax = taxable * t / 10_000; let shipping = s > f ? 0 : sh
            return taxable + tax + shipping
        }
        XCTAssertEqual(out.value, native(7500, 1000, 875, 5000, 599))
    }

    /// The DEMO's canonical pricing case: the hand-built OTAModule-Embedded asserts
    /// `checkoutTotalCents(7250,1000,875,5000,599) = 7095` ($70.95). The auto-T0
    /// codegen must reproduce that exact total from the same integer-cents logic,
    /// proving the auto path matches the proven hand-built module's result.
    func testT0DemoCanonicalPricingIs7095() throws {
        let logic = """
        public enum Pricing {
            public static func orderTotalCents(_ subtotalCents: Int, _ promoBasisPoints: Int,
                                               _ taxBasisPoints: Int, _ freeShipThresholdCents: Int,
                                               _ flatShipCents: Int) -> Int {
                let discount = subtotalCents * promoBasisPoints / 10_000
                let taxable = subtotalCents - discount
                let tax = taxable * taxBasisPoints / 10_000
                let shipping = subtotalCents > freeShipThresholdCents ? 0 : flatShipCents
                return taxable + tax + shipping
            }
        }
        """
        let export = CodeEmitter.PureExport(
            exportName: "orderTotalCents", callee: "Pricing.orderTotalCents",
            parameters: [(label: "_", name: "subtotalCents", type: "Int"),
                         (label: "_", name: "promoBasisPoints", type: "Int"),
                         (label: "_", name: "taxBasisPoints", type: "Int"),
                         (label: "_", name: "freeShipThresholdCents", type: "Int"),
                         (label: "_", name: "flatShipCents", type: "Int")],
            returnType: "Int")
        let emitted = CodeEmitter().emitPureExportFile(export, includeAllocator: true)
        let wasm = try compileT0OrSkip(
            support: logic, wrapperFile: (emitted.fileName, emitted.source), exports: emitted.exports)
        let runner = try T0Runner(wasm: wasm)
        struct Args: Encodable {
            let subtotalCents: Int; let promoBasisPoints: Int; let taxBasisPoints: Int
            let freeShipThresholdCents: Int; let flatShipCents: Int
        }
        struct Out: Decodable { let value: Int }
        // Demo v1 inputs.
        let v1 = Args(subtotalCents: 7250, promoBasisPoints: 1000, taxBasisPoints: 875,
                      freeShipThresholdCents: 5000, flatShipCents: 599)
        let out1 = try JSONDecoder().decode(Out.self, from: Data(
            try runner.callPacked("orderTotalCents", [UInt8](try JSONEncoder().encode(v1)))))
        XCTAssertEqual(out1.value, 7095, "auto-T0 must reproduce the demo's $70.95 total")
        // Demo v2 hot-update inputs → 6148.
        let v2 = Args(subtotalCents: 7250, promoBasisPoints: 2000, taxBasisPoints: 600,
                      freeShipThresholdCents: 5000, flatShipCents: 599)
        let out2 = try JSONDecoder().decode(Out.self, from: Data(
            try runner.callPacked("orderTotalCents", [UInt8](try JSONEncoder().encode(v2)))))
        XCTAssertEqual(out2.value, 6148, "auto-T0 must reproduce the demo's v2 hot-update total")
    }

    /// A Bool business-logic check (phone-number-validity shape) auto-emits T0 and
    /// round-trips true/false through the `{"value":N}` (0/1) envelope.
    func testT0BoolRoundTrip() throws {
        let logic = """
        public enum PhoneRules {
            public static func isValidLength(_ digitCount: Int, _ countryCode: Int) -> Bool {
                switch countryCode {
                case 1: return digitCount == 10
                case 44: return digitCount == 10 || digitCount == 11
                default: return digitCount >= 4 && digitCount <= 15
                }
            }
        }
        """
        let export = CodeEmitter.PureExport(
            exportName: "isValidLength", callee: "PhoneRules.isValidLength",
            parameters: [(label: "_", name: "digitCount", type: "Int"),
                         (label: "_", name: "countryCode", type: "Int")],
            returnType: "Bool")
        let emitted = CodeEmitter().emitPureExportFile(export, includeAllocator: true)
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded)

        let wasm = try compileT0OrSkip(
            support: logic, wrapperFile: (emitted.fileName, emitted.source), exports: emitted.exports)
        let runner = try T0Runner(wasm: wasm)
        struct Args: Encodable { let digitCount: Int; let countryCode: Int }
        struct Out: Decodable { let value: Int }
        func call(_ d: Int, _ c: Int) throws -> Int {
            try JSONDecoder().decode(Out.self, from: Data(
                try runner.callPacked("isValidLength",
                    [UInt8](try JSONEncoder().encode(Args(digitCount: d, countryCode: c)))))).value
        }
        XCTAssertEqual(try call(10, 1), 1, "US 10-digit must be valid")
        XCTAssertEqual(try call(7, 1), 0, "US 7-digit must be invalid")
        XCTAssertEqual(try call(11, 44), 1, "UK 11-digit must be valid")
    }

    // MARK: - research/foundation-bridges: widened T0 marshalling (String + Double)

    /// A String-arg + String-return function is now T0-eligible (was T2): args read
    /// via patch_host.json_get_string, result hand-encoded `{"value":"..."}` via the
    /// embedded-safe escaper — no in-module Foundation/JSONEncoder.
    func testT0StringMarshallingSelectsT0() {
        let export = CodeEmitter.PureExport(
            exportName: "greet", callee: "Greeter.greet",
            parameters: [(label: "_", name: "name", type: "String")],
            returnType: "String")
        let emitted = CodeEmitter().emitPureExportFile(export, includeAllocator: true)
        XCTAssertFalse(emitted.source.contains("import Foundation"),
                       "String T0 wrapper must not import Foundation\n\(emitted.source)")
        XCTAssertFalse(emitted.source.contains("JSONEncoder"))
        XCTAssertTrue(emitted.source.contains("patchJSONGetString"),
                      "String arg must be read via the json_get_string bridge")
        XCTAssertTrue(emitted.source.contains("_patchJSONEscape"),
                      "String result must use the embedded-safe JSON escaper")
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded,
                       "String marshalling must select T0")
    }

    /// A Double-arg + Double-return function is now T0-eligible: args via
    /// json_get_f64 (the Double bit-pattern), result `{"value":<decimal>}`.
    func testT0DoubleMarshallingSelectsT0() {
        let export = CodeEmitter.PureExport(
            exportName: "scale", callee: "Math.scale",
            parameters: [(label: "_", name: "x", type: "Double"),
                         (label: "_", name: "factor", type: "Double")],
            returnType: "Double")
        let emitted = CodeEmitter().emitPureExportFile(export, includeAllocator: true)
        XCTAssertFalse(emitted.source.contains("import Foundation"))
        XCTAssertTrue(emitted.source.contains("patchJSONGetF64"),
                      "Double arg must be read via the json_get_f64 bridge")
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded)
    }

    /// END-TO-END: a String-returning T0 fragment compiles embedded and round-trips
    /// a correct (escaped) value through the json_get_string / packed-string ABI.
    func testT0StringRoundTripIsCorrect() throws {
        let logic = """
        public enum Greeter {
            public static func greet(_ name: String) -> String {
                return "Hello, " + name + "!"
            }
        }
        """
        let export = CodeEmitter.PureExport(
            exportName: "greet", callee: "Greeter.greet",
            parameters: [(label: "_", name: "name", type: "String")],
            returnType: "String")
        let emitted = CodeEmitter().emitPureExportFile(export, includeAllocator: true)
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded)

        let wasm = try compileT0OrSkip(
            support: logic, wrapperFile: (emitted.fileName, emitted.source), exports: emitted.exports)
        XCTAssertLessThan(wasm.count, 2_000_000, "String T0 module should be well under 2 MB (got \(wasm.count))")

        let runner = try T0Runner(wasm: wasm)
        struct Args: Encodable { let name: String }
        struct Out: Decodable { let value: String }
        func call(_ n: String) throws -> String {
            try JSONDecoder().decode(Out.self, from: Data(
                try runner.callPacked("greet", [UInt8](try JSONEncoder().encode(Args(name: n)))))).value
        }
        XCTAssertEqual(try call("Ada"), "Hello, Ada!")
        // The escaper must survive a quote/backslash in the value.
        XCTAssertEqual(try call("a\"b\\c"), "Hello, a\"b\\c!")
    }

    /// END-TO-END: a Double-arg/Double-return T0 fragment compiles embedded and
    /// round-trips through json_get_f64 + the `{"value":<decimal>}` encoder.
    func testT0DoubleRoundTripIsCorrect() throws {
        let logic = """
        public enum Math {
            public static func scale(_ x: Double, _ factor: Double) -> Double {
                return x * factor + 1.0
            }
        }
        """
        let export = CodeEmitter.PureExport(
            exportName: "scale", callee: "Math.scale",
            parameters: [(label: "_", name: "x", type: "Double"),
                         (label: "_", name: "factor", type: "Double")],
            returnType: "Double")
        let emitted = CodeEmitter().emitPureExportFile(export, includeAllocator: true)
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded)

        let wasm = try compileT0OrSkip(
            support: logic, wrapperFile: (emitted.fileName, emitted.source), exports: emitted.exports)
        let runner = try T0Runner(wasm: wasm)
        struct Args: Encodable { let x: Double; let factor: Double }
        struct Out: Decodable { let value: Double }
        let out = try JSONDecoder().decode(Out.self, from: Data(
            try runner.callPacked("scale", [UInt8](try JSONEncoder().encode(Args(x: 2.5, factor: 4.0))))))
        XCTAssertEqual(out.value, 11.0, accuracy: 1e-9, "2.5 * 4.0 + 1.0 = 11.0")
    }

    // MARK: - Value-type RECEIVER at T0 (the FINAL size lever)

    /// A Euclid-style `Vector` (flat scalar struct, positional init) whose stored
    /// fields are all Double — the reconstruction shape used by the receiver tests.
    private var vectorShape: CodeEmitter.PureExport.ValueTypeShape {
        .init(typeName: "Vector",
              fields: [.init(name: "x", type: "Double"),
                       .init(name: "y", type: "Double"),
                       .init(name: "z", type: "Double")],
              initLabels: ["_", "_", "_"])   // public init(_ x, _ y, _ z)
    }

    /// A value-type INSTANCE METHOD (`v.dot(u)`) — receiver Vector + ARG Vector —
    /// auto-emits a T0 wrapper (no Foundation/JSONDecoder); the receiver & arg are
    /// reconstructed via json_get_subobject + scalar readers.
    func testValueTypeReceiverEmitsT0Wrapper() {
        let dot = CodeEmitter.PureExport(
            exportName: "Vector_dot", callee: "dot",
            parameters: [(label: "_", name: "other", type: "Vector")],
            returnType: "Double",
            receiverType: "Vector",
            receiverShape: vectorShape,
            valueParamShapes: ["other": vectorShape])
        let emitted = CodeEmitter().emitPureExportFile(dot, includeAllocator: true)
        XCTAssertFalse(emitted.source.contains("import Foundation"),
                       "value-type receiver T0 wrapper must not import Foundation\n\(emitted.source)")
        XCTAssertFalse(emitted.source.contains("JSONDecoder"))
        XCTAssertTrue(emitted.source.contains("patchJSONGetSubobject(_argsBytes, \"_receiver\")"),
                      "receiver must be extracted via the subobject bridge\n\(emitted.source)")
        XCTAssertTrue(emitted.source.contains("patchJSONGetSubobject(_argsBytes, \"other\")"),
                      "value-type arg must be extracted via the subobject bridge\n\(emitted.source)")
        XCTAssertTrue(emitted.source.contains("_receiver.dot(other)"),
                      "the instance method must be called on the reconstructed receiver\n\(emitted.source)")
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded,
                       "value-type receiver wrapper must select T0")

        // A NON-reconstructable receiver (no shape) still falls back to Foundation/T2.
        let noShape = CodeEmitter.PureExport(
            exportName: "Vector_dot2", callee: "dot",
            parameters: [(label: "_", name: "other", type: "Vector")],
            returnType: "Double", receiverType: "Vector")
        let fb = CodeEmitter().emitPureExportFile(noShape, includeAllocator: true)
        XCTAssertTrue(fb.source.contains("JSONDecoder"),
                      "a receiver with no reconstruction shape must stay on the Foundation wrapper")
    }

    /// END-TO-END: `Vector.dot` rides T0, compiles embedded, and computes the correct
    /// dot product from a NESTED-receiver JSON envelope — vs a native cross-check.
    func testValueTypeReceiverDotRoundTripIsCorrect() throws {
        let logic = """
        public struct Vector {
            public var x: Double
            public var y: Double
            public var z: Double
            public init(_ x: Double, _ y: Double, _ z: Double = 0) {
                self.x = x; self.y = y; self.z = z
            }
            public func dot(_ other: Vector) -> Double {
                x * other.x + y * other.y + z * other.z
            }
        }
        """
        let dot = CodeEmitter.PureExport(
            exportName: "Vector_dot", callee: "dot",
            parameters: [(label: "_", name: "other", type: "Vector")],
            returnType: "Double",
            receiverType: "Vector",
            receiverShape: vectorShape,
            valueParamShapes: ["other": vectorShape])
        let emitted = CodeEmitter().emitPureExportFile(dot, includeAllocator: true)
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded)

        let wasm = try compileT0OrSkip(
            support: logic, wrapperFile: (emitted.fileName, emitted.source), exports: emitted.exports)
        XCTAssertLessThan(wasm.count, 2_000_000, "value-type T0 module should be well under 2 MB (got \(wasm.count))")

        let runner = try T0Runner(wasm: wasm)
        struct Vec: Encodable { let x: Double; let y: Double; let z: Double }
        struct Args: Encodable { let _receiver: Vec; let other: Vec }
        struct Out: Decodable { let value: Double }
        func dotCall(_ a: Vec, _ b: Vec) throws -> Double {
            try JSONDecoder().decode(Out.self, from: Data(
                try runner.callPacked("Vector_dot",
                    [UInt8](try JSONEncoder().encode(Args(_receiver: a, other: b)))))).value
        }
        func native(_ a: Vec, _ b: Vec) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
        let a = Vec(x: 1, y: 2, z: 3), b = Vec(x: 4, y: 5, z: 6)
        XCTAssertEqual(try dotCall(a, b), 32.0, accuracy: 1e-9, "1*4 + 2*5 + 3*6 = 32")
        XCTAssertEqual(try dotCall(a, b), native(a, b), accuracy: 1e-9)
        let c = Vec(x: -1.5, y: 0.25, z: 10), d = Vec(x: 2, y: -8, z: 0.5)
        XCTAssertEqual(try dotCall(c, d), native(c, d), accuracy: 1e-9)
    }

    /// END-TO-END: a value-type COMPUTED PROPERTY (`v.length`) rides T0 — receiver
    /// only, no args — and computes the Euclidean length via the stdlib `.squareRoot()`.
    func testValueTypeReceiverLengthRoundTripIsCorrect() throws {
        let logic = """
        public struct Vector {
            public var x: Double
            public var y: Double
            public var z: Double
            public init(_ x: Double, _ y: Double, _ z: Double = 0) {
                self.x = x; self.y = y; self.z = z
            }
            public var lengthSquared: Double { x * x + y * y + z * z }
            public var length: Double { lengthSquared.squareRoot() }
        }
        """
        let length = CodeEmitter.PureExport(
            exportName: "Vector_length", callee: "length",
            parameters: [], returnType: "Double",
            receiverType: "Vector", isProperty: true,
            receiverShape: vectorShape)
        let emitted = CodeEmitter().emitPureExportFile(length, includeAllocator: true)
        XCTAssertTrue(emitted.source.contains("_receiver.length"),
                      "a computed property is read with no call parens\n\(emitted.source)")
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded)

        let wasm = try compileT0OrSkip(
            support: logic, wrapperFile: (emitted.fileName, emitted.source), exports: emitted.exports)
        let runner = try T0Runner(wasm: wasm)
        struct Vec: Encodable { let x: Double; let y: Double; let z: Double }
        struct Args: Encodable { let _receiver: Vec }
        struct Out: Decodable { let value: Double }
        let out = try JSONDecoder().decode(Out.self, from: Data(
            try runner.callPacked("Vector_length",
                [UInt8](try JSONEncoder().encode(Args(_receiver: Vec(x: 3, y: 4, z: 12)))))))
        XCTAssertEqual(out.value, 13.0, accuracy: 1e-9, "|(3,4,12)| = sqrt(9+16+144) = 13")
    }

    // MARK: - Value-type RETURN (the Codable-return bridge)

    /// A flat-scalar `User` model with synthesized memberwise init + synthesized
    /// Codable — the canonical decode-shaped return type.
    private var userShape: CodeEmitter.PureExport.ValueTypeShape {
        .init(typeName: "User",
              fields: [.init(name: "id", type: "Int"),
                       .init(name: "name", type: "String"),
                       .init(name: "score", type: "Double"),
                       .init(name: "active", type: "Bool")],
              initLabels: nil)   // synthesized memberwise init (field-name labels)
    }

    /// A function RETURNING a flat-scalar value type auto-emits a T0 wrapper that
    /// hand-encodes the result field-by-field (no Foundation/JSONEncoder/Codable) —
    /// the encode-side of the value-type bridge.
    func testValueTypeReturnEmitsT0Wrapper() {
        let make = CodeEmitter.PureExport(
            exportName: "makeUser", callee: "makeUser",
            parameters: [(label: "_", name: "id", type: "Int")],
            returnType: "User",
            returnShape: userShape)
        let emitted = CodeEmitter().emitPureExportFile(make, includeAllocator: true)
        XCTAssertFalse(emitted.source.contains("import Foundation"),
                       "value-type RETURN T0 wrapper must not import Foundation\n\(emitted.source)")
        XCTAssertFalse(emitted.source.contains("JSONEncoder()"),
                       "value-type RETURN must hand-encode, not use JSONEncoder\n\(emitted.source)")
        XCTAssertFalse(emitted.source.contains("struct \(userShape.typeName)_Out"),
                       "no in-guest Encodable envelope struct is emitted for the return\n\(emitted.source)")
        XCTAssertTrue(emitted.source.contains("_patchEncodeObj_makeUser"),
                      "a per-export object encoder must be emitted\n\(emitted.source)")
        XCTAssertTrue(emitted.source.contains("_value.id") && emitted.source.contains("_value.name")
                      && emitted.source.contains("_value.score") && emitted.source.contains("_value.active"),
                      "every stored field must be read off the returned value\n\(emitted.source)")
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded,
                       "value-type RETURN wrapper must select T0")

        // DEMOTE-SAFETY: a return with NO reconstruction shape (e.g. a Foundation /
        // nested / non-Codable-in-guest type) stays on the Foundation (T2) wrapper.
        let noShape = CodeEmitter.PureExport(
            exportName: "makeUser2", callee: "makeUser",
            parameters: [(label: "_", name: "id", type: "Int")],
            returnType: "User")
        let fb = CodeEmitter().emitPureExportFile(noShape, includeAllocator: true)
        XCTAssertTrue(fb.source.contains("JSONEncoder"),
                      "a return with no reconstruction shape must stay on the Foundation wrapper")
    }

    /// END-TO-END: a function returning a value-type model `buildUser(...) -> User`
    /// that today would need `User: Encodable` in the guest (and demote when that
    /// conformance is `#if !$Embedded`-guarded) instead rides T0 — the guest
    /// HAND-ENCODES the returned `User` field-by-field and the test decodes the
    /// canonical envelope with the REAL `User` Codable (mirroring the native shell),
    /// proving an exact round-trip. The support `User` is DELIBERATELY non-Codable to
    /// prove the guest never needs the conformance. (Inputs are scalar args, not a
    /// String-parse, so the support body stays T0-embedded-clean — String-split /
    /// `Double(String)` would pull the embedded-absent Unicode/strtod tables; this
    /// test isolates the RETURN-ENCODE bridge, which is the change under test.)
    func testValueTypeReturnDecodeShapedRoundTrip() throws {
        let logic = """
        // `User` is intentionally NOT Codable — the T0 guest HAND-ENCODES it with no
        // Codable/Encodable conformance. The string field rides String construction
        // (`String(decoding:as:)`/`+`), which IS T0-embedded-safe (no Unicode tables).
        public struct User {
            public var id: Int
            public var name: String
            public var score: Double
            public var active: Bool
        }
        // A value-producing function: maps scalar inputs into the model, the common
        // shape of a `decode`/`map`/`make` business function whose RETURN is the model.
        public func buildUser(_ id: Int, _ nameCode: Int, _ score: Double, _ flag: Int) -> User {
            // Build the name from a code WITHOUT String interpolation/parse (T0-clean):
            // 0 -> "Ada", 1 -> "Bo\\\"b" (quote+backslash to test JSON escaping), else "".
            let name: String
            if nameCode == 0 { name = "Ada" }
            else if nameCode == 1 { name = "Bo\\\\\\"b" }
            else { name = "" }
            return User(id: id, name: name, score: score, active: flag != 0)
        }
        """
        let build = CodeEmitter.PureExport(
            exportName: "buildUser", callee: "buildUser",
            parameters: [(label: "_", name: "id", type: "Int"),
                         (label: "_", name: "nameCode", type: "Int"),
                         (label: "_", name: "score", type: "Double"),
                         (label: "_", name: "flag", type: "Int")],
            returnType: "User",
            returnShape: userShape)
        let emitted = CodeEmitter().emitPureExportFile(build, includeAllocator: true)
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded,
                       "value-type-return wrapper must select T0\n\(emitted.source)")
        XCTAssertTrue(emitted.source.contains("_patchEncodeObj_buildUser"),
                      "the return must be hand-encoded field-by-field\n\(emitted.source)")

        let wasm = try compileT0OrSkip(
            support: logic, wrapperFile: (emitted.fileName, emitted.source), exports: emitted.exports)
        XCTAssertLessThan(wasm.count, 2_000_000, "value-type-return T0 module should be well under 2 MB (got \(wasm.count))")

        let runner = try T0Runner(wasm: wasm)
        struct Args: Encodable { let id: Int; let nameCode: Int; let score: Double; let flag: Int }
        // The native shell decodes the envelope with the REAL User Codable.
        struct User: Codable, Equatable { let id: Int; let name: String; let score: Double; let active: Bool }
        struct Out: Decodable { let value: User }
        func buildCall(_ id: Int, _ nameCode: Int, _ score: Double, _ flag: Int) throws -> User {
            try JSONDecoder().decode(Out.self, from: Data(
                try runner.callPacked("buildUser",
                    [UInt8](try JSONEncoder().encode(Args(id: id, nameCode: nameCode, score: score, flag: flag)))))).value
        }
        XCTAssertEqual(try buildCall(42, 0, 9.5, 1),
                       User(id: 42, name: "Ada", score: 9.5, active: true),
                       "exact round-trip through the hand-encoded value-type envelope")
        // String-escape fidelity: a name containing a quote + backslash must survive.
        XCTAssertEqual(try buildCall(7, 1, 0.0, 0).name, "Bo\\\"b",
                       "JSON-escaped string field round-trips correctly")
        // Negative / zero / false edge values.
        XCTAssertEqual(try buildCall(-1, 2, -3.25, 0),
                       User(id: -1, name: "", score: -3.25, active: false))
        // The fields land in the right slots (no swap) — distinct values per field.
        let u = try buildCall(100, 0, 2.5, 1)
        XCTAssertEqual(u.id, 100); XCTAssertEqual(u.name, "Ada")
        XCTAssertEqual(u.score, 2.5, accuracy: 1e-9); XCTAssertTrue(u.active)
    }

    // MARK: - LEVER #1: NESTED value-type Codable (decode arg + encode return)

    /// A NESTED value type: `Profile` containing an `Address` (itself flat-scalar).
    /// The bundler builds a recursive shape (`Profile.address` carries `Address`'s
    /// shape via `nestedShape`).
    private var nestedProfileShape: CodeEmitter.PureExport.ValueTypeShape {
        let address = CodeEmitter.PureExport.ValueTypeShape(
            typeName: "Address",
            fields: [.init(name: "city", type: "String"), .init(name: "zip", type: "Int")],
            initLabels: nil)
        return .init(typeName: "Profile",
                     fields: [.init(name: "id", type: "Int"),
                              .init(name: "address", type: "Address", nestedShape: address)],
                     initLabels: nil)
    }

    /// END-TO-END nested Codable: `reslot(_ p: Profile) -> Profile` — a value-type ARG
    /// AND a value-type RETURN, each with a NESTED struct field. The guest reconstructs
    /// `Profile` (incl. the nested `Address`) from sub-blobs and hand-encodes the result
    /// (incl. the nested object), with NO in-guest Codable. Decodes the canonical
    /// envelope with the REAL nested Codable, proving an exact deep round-trip. This is
    /// the "decode JSON → transform → encode JSON" shape with NESTED models at T0.
    func testNestedValueTypeArgAndReturnRoundTrip() throws {
        let logic = """
        // Neither type is Codable — the T0 guest hand-encodes/decodes both levels.
        public struct Address { public var city: String; public var zip: Int }
        public struct Profile { public var id: Int; public var address: Address }
        // decode -> transform -> encode: bump the id, uppercase-tag the city's zip.
        public func reslot(_ p: Profile) -> Profile {
            Profile(id: p.id + 1, address: Address(city: p.address.city, zip: p.address.zip + 100))
        }
        """
        let reslot = CodeEmitter.PureExport(
            exportName: "reslot", callee: "reslot",
            parameters: [(label: "_", name: "p", type: "Profile")],
            returnType: "Profile",
            valueParamShapes: ["p": nestedProfileShape],
            returnShape: nestedProfileShape)
        let emitted = CodeEmitter().emitPureExportFile(reslot, includeAllocator: true)
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded,
                       "nested value-type wrapper must select T0 (no Codable/Foundation)\n\(emitted.source)")
        XCTAssertFalse(emitted.source.contains("JSONEncoder()") || emitted.source.contains("JSONDecoder()"),
                       "nested value types must hand-(de)code, not use JSON coders\n\(emitted.source)")
        // The nested sub-blob is extracted for the arg's `address` field AND the return
        // encoder opens a nested `{…}` for it.
        XCTAssertTrue(emitted.source.contains("patchJSONGetSubobject"),
                      "the nested field must be pulled as its own sub-blob\n\(emitted.source)")

        let wasm = try compileT0OrSkip(
            support: logic, wrapperFile: (emitted.fileName, emitted.source), exports: emitted.exports)
        let runner = try T0Runner(wasm: wasm)
        struct Address: Codable, Equatable { let city: String; let zip: Int }
        struct Profile: Codable, Equatable { let id: Int; let address: Address }
        struct Out: Decodable { let value: Profile }
        func reslotCall(_ p: Profile) throws -> Profile {
            try JSONDecoder().decode(Out.self, from: Data(
                try runner.callPacked("reslot",
                    [UInt8](try JSONEncoder().encode(["p": p]))))).value
        }
        XCTAssertEqual(try reslotCall(Profile(id: 1, address: Address(city: "Reykjavík", zip: 101))),
                       Profile(id: 2, address: Address(city: "Reykjavík", zip: 201)),
                       "exact DEEP round-trip: nested struct decoded, transformed, re-encoded at T0")
    }

    /// A value-type return that is NOT flat-scalar (has a nested-struct field) gets
    /// NO return shape from the bundler and must fall back to the Foundation (T2)
    /// wrapper — never silently ship a partial/wrong encode (zero-false-negative).
    func testNonFlatValueTypeReturnStaysFoundation() {
        // Simulate the enrichment outcome: no returnShape attached (the bundler
        // returns nil for a non-flat-scalar type). The emitter must NOT T0-encode it.
        let make = CodeEmitter.PureExport(
            exportName: "makeWrapped", callee: "makeWrapped",
            parameters: [(label: "_", name: "n", type: "Int")],
            returnType: "Wrapped")   // no returnShape → not reconstructable
        let emitted = CodeEmitter().emitPureExportFile(make, includeAllocator: true)
        XCTAssertTrue(emitted.source.contains("JSONEncoder"),
                      "a non-reconstructable value-type return must stay on the Foundation wrapper\n\(emitted.source)")
    }

    /// END-TO-END: a value-type RECEIVER + value-type RETURN in one export — an
    /// instance method `Vector.scaled(by:) -> Vector` — rides T0: the receiver is
    /// reconstructed from a nested sub-blob AND the result is hand-encoded
    /// field-by-field, both with no in-guest Codable. Proves the decode-side and
    /// encode-side value-type bridges compose in a single wrapper.
    func testValueTypeReceiverAndReturnComposeRoundTrip() throws {
        let logic = """
        public struct Vector {
            public var x: Double
            public var y: Double
            public var z: Double
            public init(_ x: Double, _ y: Double, _ z: Double = 0) {
                self.x = x; self.y = y; self.z = z
            }
            public func scaled(_ k: Double) -> Vector {
                Vector(x * k, y * k, z * k)
            }
        }
        """
        let scaled = CodeEmitter.PureExport(
            exportName: "Vector_scaled", callee: "scaled",
            parameters: [(label: "_", name: "k", type: "Double")],
            returnType: "Vector",
            receiverType: "Vector",
            receiverShape: vectorShape,
            returnShape: vectorShape)
        let emitted = CodeEmitter().emitPureExportFile(scaled, includeAllocator: true)
        XCTAssertEqual(EmbeddedCompatibility().analyzeSource(emitted.source).tier, .t0Embedded,
                       "receiver+return value-type wrapper must select T0\n\(emitted.source)")
        XCTAssertTrue(emitted.source.contains("patchJSONGetSubobject(_argsBytes, \"_receiver\")"),
                      "the receiver is reconstructed from a sub-blob")
        XCTAssertTrue(emitted.source.contains("_patchEncodeObj_Vector_scaled"),
                      "the returned Vector is hand-encoded field-by-field")

        let wasm = try compileT0OrSkip(
            support: logic, wrapperFile: (emitted.fileName, emitted.source), exports: emitted.exports)
        let runner = try T0Runner(wasm: wasm)
        struct Vec: Codable, Equatable { let x: Double; let y: Double; let z: Double }
        struct Args: Encodable { let _receiver: Vec; let k: Double }
        struct Out: Decodable { let value: Vec }
        let out = try JSONDecoder().decode(Out.self, from: Data(
            try runner.callPacked("Vector_scaled",
                [UInt8](try JSONEncoder().encode(Args(_receiver: Vec(x: 1, y: -2, z: 3), k: 2.5))))))
        XCTAssertEqual(out.value, Vec(x: 2.5, y: -5.0, z: 7.5),
                       "scaled vector round-trips exactly through both value-type bridges")
    }
}
