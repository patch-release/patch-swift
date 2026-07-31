// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
import SwiftParser
import SwiftSyntax
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// THE regression that was failing in production: a WASM-eligible function that
/// references the app's OWN value type (`PhoneNumber.notPhoneNumber() ->
/// PhoneNumber`) used to be compiled standalone with only `import Foundation`, so
/// `swift build --swift-sdk` failed with "cannot find type 'PhoneNumber' in
/// scope" and the fragment demoted to native — no shippable module.
///
/// The fix is dependency-closure bundling: the `DependencyClosureBundler`
/// reconstructs the transitive closure of the export's value types as minimal
/// `Codable` structs/enums + emits the pure logic, so the compile unit is
/// self-contained. These tests prove:
///   1. (always) the bundler computes the right closure for the headline cases,
///      rejects unbundlable closures (class/native), and produces compilable text;
///   2. (when the toolchain is present) the bundled module COMPILES to a real
///      `.wasm` and HOST-RUNS, returning a correct app-value-typed result.
final class DependencyClosureBundlerTests: XCTestCase {

    // MARK: - Minimal host runner (mirrors PatchSDK.callPacked)

    /// Container-aware host runner (mirrors the SDK): one WasmKit instance per
    /// sub-module of a `PMOD` container (or one for a raw `.wasm`), routing each
    /// `callPacked` to whichever instance exports the symbol.
    private final class Runner {
        let store: Store
        let instances: [Instance]
        let wasi: WASIBridgeToHost
        init(wasm: [UInt8]) throws {
            let engine = Engine()
            self.store = Store(engine: engine)
            self.wasi = try WASIBridgeToHost()
            var imports = Imports()
            wasi.link(to: &imports, store: store)
            // Full patch_host bridge surface (harmless for modules that don't import
            // them; required because the generated C header declares all imports).
            PatchHostTestImports.register(into: &imports, store: store)
            let modules = PatchModuleContainer.decode(wasm) ?? [wasm]
            var built: [Instance] = []
            for m in modules {
                let parsed = try parseWasm(bytes: m)
                let inst = try parsed.instantiate(store: store, imports: imports)
                try wasi.initialize(inst)
                built.append(inst)
            }
            self.instances = built
        }
        func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
            guard let inst = instances.first(where: { $0.exports[function: name] != nil }),
                  let fn = inst.exports[function: name],
                  let malloc = inst.exports[function: "patch_malloc"],
                  let mem = inst.exports[memory: "memory"] else {
                throw NSError(domain: "abi", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "no instance exports \(name)"])
            }
            let inPtr = try malloc([.i32(UInt32(input.count))])[0].i32
            if !input.isEmpty {
                mem.withUnsafeMutableBufferPointer(offset: UInt(inPtr), count: input.count) { $0.copyBytes(from: input) }
            }
            let packed = try fn([.i32(inPtr), .i32(UInt32(input.count))])[0].i64
            let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
            let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
            let all = mem.data
            return [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
        }
    }

    /// The PhoneNumberKit-shaped fixture: a value type with an enum field, declared
    /// across multiple files/extensions exactly like the real corpus, plus the
    /// pure static factory the engine wants to export.
    private static let phoneNumberFixture: [(String, String)] = [
        ("PhoneNumber.swift", """
        import Foundation
        public struct PhoneNumber: Sendable {
            public let numberString: String
            public let countryCode: UInt64
            public let leadingZero: Bool
            public let nationalNumber: UInt64
            public let numberExtension: String?
            public let type: PhoneNumberType
            public let regionID: String?
        }
        extension PhoneNumber: Equatable {}
        public extension PhoneNumber {
            static func notPhoneNumber() -> PhoneNumber {
                return PhoneNumber(numberString: "", countryCode: 0, leadingZero: false,
                                   nationalNumber: 0, numberExtension: nil, type: .notParsed, regionID: nil)
            }
            // A pure computed property (URL is WASM-safe) — MAY be bundled.
            var url: URL? { URL(string: "tel://" + numberString) }
            // A computed property that touches UIKit — must be DROPPED from the
            // reconstruction (a whole-file bundle would drag UIKit in and fail).
            var color: UIColor { UIColor.systemBlue }
        }
        """),
        ("MetadataTypes.swift", """
        import Foundation
        public enum PhoneNumberType: String, Codable, Sendable {
            case fixedLine, mobile, fixedOrMobile, unknown, notParsed
        }
        """),
        // A UIKit file in the same project that must NOT pollute the closure.
        ("UI.swift", """
        #if canImport(UIKit)
        import UIKit
        final class PhoneNumberTextField: UITextField {}
        #endif
        """),
    ]

    private func writeFixture(_ files: [(String, String)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dcb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    // MARK: - 1. Closure correctness (always runs)

    func testClosureReconstructsValueTypeAndEnum() throws {
        let dir = try writeFixture(Self.phoneNumberFixture)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundler = DependencyClosureBundler()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let index = bundler.index(for: files)
        let clo = bundler.closure(exportName: "notPhoneNumber", callee: "PhoneNumber.notPhoneNumber",
                                  signatureTypes: ["PhoneNumber"], index: index)
        XCTAssertTrue(clo.shippable, "notPhoneNumber must be bundlable; reason: \(clo.rejectionReason ?? "")")
        XCTAssertTrue(clo.neededTypes.contains("PhoneNumber"))
        XCTAssertTrue(clo.neededTypes.contains("PhoneNumberType"),
                      "the enum field type must be pulled into the closure")
        let src = bundler.emitSupportSource(types: clo.neededTypes, fns: clo.neededFns, index: index)
        // Reconstructed as Codable; no duplicate PhoneNumber declaration; the URL
        // computed property (not in the closure) must be omitted.
        XCTAssertTrue(src.contains("struct PhoneNumber: Codable"))
        XCTAssertTrue(src.contains("enum PhoneNumberType: String, Codable"))
        XCTAssertTrue(src.contains("extension PhoneNumber {"), "static factory must extend the reconstructed type")
        XCTAssertFalse(src.contains("UIColor"), "UIKit-touching member must be DROPPED from the closure\n\(src)")
        XCTAssertEqual(src.components(separatedBy: "struct PhoneNumber").count - 1, 1,
                       "PhoneNumber must be declared exactly once (no enum/struct collision)")
    }

    /// COVERAGE (general-logic milk-more): a CASELESS namespace `enum` used as a
    /// config table (`enum Config { static let url = "https://…" }`) must
    /// reconstruct its SIMPLE-LITERAL static constants, so a pure body reading
    /// `Config.url` compiles instead of demoting. This is the real
    /// `AIService.hasCloudFunctions` fix (reads three `Config` string constants);
    /// before the fix `Config` reconstructed as an empty `enum Config {}` and the
    /// export failed the WASM compile.
    func testNamespaceEnumStaticLiteralConstantsAreReconstructed() throws {
        let dir = try writeFixture([("Config.swift", """
        import Foundation
        enum Config {
            static let url = "https://example.com/api"
            static let apiKey = "K1pH"
            static let retries = 3
            static let enabled = true
            // NON-literal static — must be DROPPED (references the enum's own init/state).
            static let derived = makeURL()
            static func makeURL() -> String { "x" }
        }
        """)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundler = DependencyClosureBundler()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let index = bundler.index(for: files)
        let src = bundler.emitSingleValueTypeSource(type: "Config", index: index,
                                                    header: "test namespace enum")
        let out = try XCTUnwrap(src)
        XCTAssertTrue(out.contains(#"static let url = "https://example.com/api""#),
                      "string literal static const must reconstruct\n\(out)")
        XCTAssertTrue(out.contains(#"static let apiKey = "K1pH""#))
        XCTAssertTrue(out.contains("static let retries = 3"))
        XCTAssertTrue(out.contains("static let enabled = true"))
        // SAFETY: a non-literal static (a fn call) must NOT be reconstructed — it may
        // reach the type's own init/unbundled state. Dropping it is demote-safe (the
        // export that reads it would then fail and demote ALONE).
        XCTAssertFalse(out.contains("static let derived ="),
                       "non-literal static must be dropped\n\(out)")
    }

    func testClosureRejectsReferenceTypeBoundary() throws {
        let dir = try writeFixture([("M.swift", """
        public final class Session { public var token = "" }
        public enum Api {
            public static func current() -> Session { Session() }
        }
        """)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundler = DependencyClosureBundler()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let clo = bundler.closure(exportName: "current", callee: "Api.current",
                                  signatureTypes: ["Session"], index: bundler.index(for: files))
        XCTAssertFalse(clo.shippable, "a class (reference type) boundary must be rejected")
        XCTAssertNotNil(clo.rejectionReason)
    }

    func testClosureRejectsNativeDependency() throws {
        let dir = try writeFixture([("M.swift", """
        import Foundation
        public struct Wrapper { public let re: NSRegularExpression }
        public enum Maker {
            public static func make() -> Wrapper { fatalError() }
        }
        """)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundler = DependencyClosureBundler()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let clo = bundler.closure(exportName: "make", callee: "Maker.make",
                                  signatureTypes: ["Wrapper"], index: bundler.index(for: files))
        XCTAssertFalse(clo.shippable, "a stored NSRegularExpression must reject the closure")
    }

    /// REGRESSION (engine SIGSEGV / stack overflow): two value types that store each
    /// other (`A.b: B`, `B.a: A`) form a reference cycle `A → B → A`. The operator
    /// reconstruction trio
    ///   reconstructedOperatorDecls(A)
    ///     → nonScalarStoredFieldNames(A)        [descends into field type B]
    ///       → fieldTypeIsComparable(B)
    ///         → reconstructedOperatorDecls(B)   [→ … → back to A]
    /// only had a 1-hop self-cycle guard (`fieldType != typeName`), so this 2-hop
    /// cycle recursed unboundedly and overflowed the stack (exit 139, zero output) —
    /// observed on checkout-sheet-kit-swift, SwiftHub, and Gifski. Threading a
    /// `visited` set through the trio cuts the recursion at an already-active type.
    /// This test reaches `emitSupportSource` (which walks every bundled value type via
    /// `reconstructedOperatorTokens`); BEFORE the fix it never returns / crashes the
    /// test process — simply REACHING the assertions proves the recursion terminates.
    func testValueTypeReferenceCycleDoesNotOverflowOperatorReconstruction() throws {
        let dir = try writeFixture([("Cycle.swift", """
        public struct A: Equatable {
            public var n: Int
            public var b: B
        }
        public struct B: Equatable {
            public var m: Int
            public var a: A
        }
        // Operators that READ the non-scalar field, so the reconstruction walk must
        // decide whether the field type is Comparable — exactly the recursive path.
        public extension A {
            static func < (l: A, r: A) -> Bool { l.b < r.b }
            static func + (l: A, r: A) -> A { A(n: l.n + r.n, b: l.b + r.b) }
        }
        public extension B {
            static func < (l: B, r: B) -> Bool { l.a < r.a }
            static func + (l: B, r: B) -> B { B(m: l.m + r.m, a: l.a + r.a) }
        }
        public enum Maker {
            public static func makeA(_ a: A) -> A { a }
        }
        """)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundler = DependencyClosureBundler()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let index = bundler.index(for: files)
        // Drives the per-type operator-reconstruction walk over the A↔B cycle.
        let clo = bundler.closure(exportName: "makeA", callee: "Maker.makeA",
                                  signatureTypes: ["A"], index: index)
        // emitSupportSource walks EVERY bundled value type through the recursive trio.
        let src = bundler.emitSupportSource(types: clo.neededTypes, fns: clo.neededFns, index: index)
        // Reaching here at all is the regression check (no stack overflow / hang).
        // The result must also be sane: both cycle members are present and each is
        // declared exactly once (no infinite re-emission).
        XCTAssertTrue(clo.neededTypes.contains("A"))
        XCTAssertTrue(clo.neededTypes.contains("B"))
        XCTAssertEqual(src.components(separatedBy: "struct A").count - 1, 1,
                       "A must be declared exactly once")
        XCTAssertEqual(src.components(separatedBy: "struct B").count - 1, 1,
                       "B must be declared exactly once")
    }

    // MARK: - 1b. Member-surface reconstruction + safety (always runs)

    /// Helper: the closure for an INSTANCE-method export on a value type.
    private func instanceClosure(_ files: [URL], type: String, method: String,
                                 sig: [String] = []) -> DependencyClosureBundler.ExportClosure {
        let bundler = DependencyClosureBundler()
        return bundler.closure(exportName: "\(type)_\(method)", callee: "\(type).\(method)",
                               signatureTypes: sig.isEmpty ? [type] : sig, index: bundler.index(for: files))
    }

    /// A pure instance method over stored fields + a sibling method it calls are
    /// BOTH reconstructed (the value-type method call graph is followed).
    func testReconstructsPureMethodAndItsSiblingCallGraph() throws {
        let dir = try writeFixture([("V.swift", """
        public struct V: Codable { public var x: Double; public var y: Double }
        public extension V {
            func dot(_ o: V) -> Double { x * o.x + y * o.y }
            var lengthSquared: Double { dot(self) }
            func scaledLen(_ k: Double) -> Double { lengthSquared * k }
        }
        """)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        // Export `scaledLen`, which calls `lengthSquared`, which calls `dot`.
        let clo = instanceClosure(files, type: "V", method: "scaledLen")
        XCTAssertTrue(clo.shippable, "pure method + its sibling call graph must reconstruct: \(clo.rejectionReason ?? "")")
        let m = clo.neededMembers["V"] ?? []
        XCTAssertTrue(m.contains("scaledLen") && m.contains("lengthSquared") && m.contains("dot"),
                      "the transitive member surface must include dot+lengthSquared+scaledLen, got \(m)")
        let bundler = DependencyClosureBundler()
        let src = bundler.emitSupportSource(types: clo.neededTypes, fns: clo.neededFns,
                                            index: bundler.index(for: files), surfaceMembers: clo.neededMembers)
        XCTAssertTrue(src.contains("func dot(") && src.contains("var lengthSquared"),
                      "reconstructed members must be emitted into the value type")
    }

    /// SAFETY: a method that transitively reaches a NATIVE symbol (UIKit) must NOT
    /// ship — neither the method nor an export needing it (zero false negatives).
    func testMethodReachingNativeNeverShips() throws {
        let dir = try writeFixture([("V.swift", """
        import Foundation
        public struct V: Codable { public var x: Double }
        public extension V {
            func pure() -> Double { x * 2 }
            // touches UIKit transitively (via a helper method).
            func tainted() -> Double { helper() }
            func helper() -> Double { UIColor.white.cgColor.alpha }
        }
        """)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        // The pure method ships.
        XCTAssertTrue(instanceClosure(files, type: "V", method: "pure").shippable)
        // The native-reaching method (via a helper) is REJECTED.
        let tainted = instanceClosure(files, type: "V", method: "tainted")
        XCTAssertFalse(tainted.shippable, "a method reaching native (UIColor) via a helper must be rejected")
        XCTAssertNotNil(tainted.rejectionReason)
    }

    /// SAFETY: a method using a DROPPED value-type operator (Euclid array-literal
    /// `+`) or an unreconstructed static (`.zero`) / custom init must be rejected, so
    /// the shared reconstruction always compiles.
    func testMethodUsingDroppedOperatorOrStaticNeverShips() throws {
        let dir = try writeFixture([("V.swift", """
        public struct V: Codable, ExpressibleByArrayLiteral {
            public var x: Double; public var y: Double
            public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
            public init(arrayLiteral e: Double...) { self.init(e[0], e[1]) }
            public static let zero = V(0, 0)
            // array-literal construction → the operator is DROPPED from reconstruction.
            public static func + (a: V, b: V) -> V { [a.x + b.x, a.y + b.y] }
        }
        public extension V {
            func dot(_ o: V) -> Double { x * o.x + y * o.y }            // pure → ships
            func added(_ o: V) -> V { self + o }                        // dropped `+` → reject
            func orZero(_ b: Bool) -> V { b ? .zero : self }            // static `.zero` → reject
            func remade() -> V { V(unchecked: x, y: y) }                // custom init → reject
        }
        public extension V { init(unchecked x: Double, y: Double) { self.init(x, y) } }
        """)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(instanceClosure(files, type: "V", method: "dot").shippable, "pure dot must ship")
        XCTAssertFalse(instanceClosure(files, type: "V", method: "added").shippable,
                       "a method using a DROPPED value-type operator must be rejected")
        XCTAssertFalse(instanceClosure(files, type: "V", method: "orZero").shippable,
                       "a method using an unreconstructed static `.zero` must be rejected")
        XCTAssertFalse(instanceClosure(files, type: "V", method: "remade").shippable,
                       "a method using a custom initializer must be rejected")
    }

    /// SAFETY: a `mutating` / `throws` / generic member must not be reconstructed.
    func testImpureMethodShapesNeverShip() throws {
        let dir = try writeFixture([("V.swift", """
        public struct V: Codable { public var x: Double }
        public extension V {
            mutating func bump() { x += 1 }
            func risky() throws -> Double { x }
            func gen<T>(_ t: T) -> Double { x }
        }
        """)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        // (mutating/throws/generic are also filtered by the scanner, but the bundler
        // gate must reject them too if reached transitively.)
        XCTAssertFalse(instanceClosure(files, type: "V", method: "risky").shippable,
                       "a throws method must be rejected")
        XCTAssertFalse(instanceClosure(files, type: "V", method: "gen").shippable,
                       "a generic method must be rejected")
    }

    // MARK: - 2. End-to-end: build a REAL module from the closure and HOST-RUN it

    /// The headline regression: the closure-bundled module COMPILES to wasm and
    /// runs, returning a correct app-value-typed result. Skipped (kept green) when
    /// the swift.org WASM toolchain is absent.
    func testBundledAppValueTypeBuildsAndRuns() throws {
        let compiler = SwiftWasmCompiler()
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping real compile/run")
        let dir = try writeFixture(Self.phoneNumberFixture)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Run the REAL pipeline (parse → classify → bundle closure → compile).
        let buildDir = FileManager.default.temporaryDirectory.appendingPathComponent("dcb-build-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: buildDir) }
        let result = try BuildPipeline().run(sourceDir: dir, buildDir: buildDir, compiler: compiler, dryRun: false)

        guard let module = result.moduleURL else {
            return XCTFail("no module emitted. rejected: \(result.rejectedExports). " +
                           "log:\n\(result.compileOutcome?.log.suffix(2000) ?? "")")
        }
        let wasm = [UInt8](try Data(contentsOf: module))
        XCTAssertEqual(Array(wasm.prefix(4)), [0x00, 0x61, 0x73, 0x6d], "not a WASM module")
        XCTAssertTrue(result.exportSymbols.contains("notPhoneNumber"),
                      "notPhoneNumber must ship as a real export, not be demoted")

        // HOST-RUN: invoke notPhoneNumber and decode the PhoneNumber it returns.
        let runner = try Runner(wasm: wasm)
        struct PhoneNumberOut: Decodable, Equatable {
            let numberString: String; let countryCode: UInt64; let leadingZero: Bool
            let nationalNumber: UInt64; let numberExtension: String?; let type: String; let regionID: String?
        }
        struct Out: Decodable { let value: PhoneNumberOut }
        let bytes = try runner.callPacked("notPhoneNumber", [UInt8]("{}".utf8))
        let out = try JSONDecoder().decode(Out.self, from: Data(bytes))
        XCTAssertEqual(out.value, PhoneNumberOut(
            numberString: "", countryCode: 0, leadingZero: false, nationalNumber: 0,
            numberExtension: nil, type: "notParsed", regionID: nil),
            "notPhoneNumber() must run in WASM and return the empty/.notParsed PhoneNumber")
    }

    // MARK: - S5. Reconstructed-type spelling (resolved/unqualified leaf) -----------

    private func reconstruct(_ files: [(String, String)], type: String) throws -> String {
        let dir = try writeFixture(files)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundler = DependencyClosureBundler()
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let index = bundler.index(for: urls)
        return try XCTUnwrap(bundler.emitSingleValueTypeSource(
            type: type, index: index, header: "S5 reconstruction"))
    }

    /// S5(a): an ENCLOSING-scope typealias used in a struct field type (`[NS.Word]`,
    /// `Word = UInt`) is re-emitted as a `typealias` on the reconstructed top-level
    /// type, so the severed reconstruction resolves the leaf (mirrors the enum path).
    func testReconstructedStructReEmitsEnclosingAliasForFieldType() throws {
        let out = try reconstruct([("Big.swift", """
        import Foundation
        enum NS { typealias Word = UInt }
        struct Big { let storage: [NS.Word]; let n: Int }
        """)], type: "Big")
        // The aliased leaf resolves: either a re-emitted `typealias Word = UInt` (so the
        // field keeps `[Word]`) or the field is rewritten to the resolved leaf — both
        // compile. The key invariant: NO unresolved `NS.Word` qualifier survives.
        XCTAssertFalse(out.contains("NS.Word"),
                       "module/parent-qualified alias `NS.Word` must NOT survive verbatim:\n\(out)")
        XCTAssertTrue(out.contains("typealias Word = UInt") || out.contains("storage: [UInt]"),
                      "the aliased leaf must resolve (typealias re-emitted or leaf rewritten):\n\(out)")
        XCTAssertFalse(Parser.parse(source: out).hasError,
                       "reconstructed struct must parse without errors:\n\(out)")
    }

    /// S5(b): a MODULE-qualified field type (`Euclid.Vector`) is emitted UNQUALIFIED
    /// (`Vector`) — the bundled top-level reconstruction has no `Euclid` module.
    func testReconstructedStructStripsModuleQualifierFromFieldType() throws {
        let out = try reconstruct([("Plane.swift", """
        import Foundation
        struct Vector: Codable { let x: Double; let y: Double }
        struct Plane: Codable { let normal: Euclid.Vector; let d: Double }
        """)], type: "Plane")
        XCTAssertTrue(out.contains("let normal: Vector"),
                      "module qualifier must be stripped to the unqualified leaf:\n\(out)")
        XCTAssertFalse(out.contains("Euclid.Vector"),
                       "no `Euclid.Vector` module-qualified spelling may survive:\n\(out)")
        XCTAssertFalse(Parser.parse(source: out).hasError,
                       "reconstructed struct must parse without errors:\n\(out)")
    }

    /// S5(c): a TYPE-LEVEL `indirect` on a recursive enum is preserved (the case-level
    /// `indirect` survives via the verbatim case text; without the type-level keyword a
    /// recursive enum fails "is not marked 'indirect'").
    func testReconstructedRecursiveEnumKeepsTypeLevelIndirect() throws {
        let out = try reconstruct([("Expr.swift", """
        import Foundation
        indirect enum Expr: Codable { case lit(Int); case add(Expr, Expr) }
        """)], type: "Expr")
        XCTAssertTrue(out.contains("indirect enum Expr"),
                      "type-level `indirect` must be preserved on a recursive enum:\n\(out)")
        XCTAssertFalse(Parser.parse(source: out).hasError,
                       "reconstructed recursive enum must parse without errors:\n\(out)")
    }
}
