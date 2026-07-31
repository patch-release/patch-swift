// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import CryptoKit
import SwiftParser
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler

// ===========================================================================
// LEVER #2 — INTEGRATION VERTICAL SLICE (the ENGINE half).
//
// Proves the engine side of one routed call end-to-end through the FOUR REAL
// reconciled components, for a real routable call
// `PricingEngine.discount(subtotal:Double,tier:Int)->Double`:
//
//   (a) CLASSIFY routable      — GeneralBridgeRewriter.classify (Agent 3)
//   (b) DERIVE id + signature + EMIT guest call — HostBridgeABI (Agent 2),
//       compiled to a real .wasm with the swift.org toolchain and RUN through
//       WasmKit (with a host dispatcher that executes the Agent-4 resolver
//       thunk's exact closure body), asserting the routed result value-exact.
//   (c) GENERATE the resolver thunk (real-SDK target) — HostBridgeThunkGenerator
//       (Agent 4 retargeted) — and CONFIRM it host-`swiftc -typecheck`s against a
//       PricingEngine stub + the real PatchHostBridge ABI shim (the
//       compiles-or-demote net).
//
// The on-device RUNTIME half (the SAME guest run through the REAL
// PatchHostBridge / GenericHostBridge) lives in the SDK target's
// HostBridgeVerticalSliceTests. The two halves agree on the CONTENT-ADDRESSED
// symbol id (this test derives it; the SDK test recomputes + asserts it).
// ===========================================================================
final class HostBridgeVerticalSliceTests: XCTestCase {

    // The routed call's resolved shape (what an engine call-site extractor would hand over).
    private static let receiverModuleType = "MyApp.PricingEngine"
    private static let methodName = "discount"
    private static let canonicalSignature =
        "MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double"

    private func parses(_ s: String) -> Bool { !Parser.parse(source: s).hasError }

    // =======================================================================
    // MARK: (a) Agent 3 — classify the call routable
    // =======================================================================

    func testClassifierRoutesTheCall() {
        let candidate = GeneralBridgeRewriter.Candidate(
            kind: .freeOrStatic,
            receiver: "PricingEngine",
            function: Self.methodName,
            nativeExpr: "PricingEngine.discount(subtotal: subtotal, tier: tier)",
            canonicalSignature: Self.canonicalSignature,
            args: [
                .init(expr: "subtotal", swiftType: "Double"),
                .init(expr: "tier", swiftType: "Int"),
            ],
            returnType: "Double",
            symbolResolvable: true)

        let verdict = GeneralBridgeRewriter().classify(candidate)
        guard case .route(let site) = verdict else {
            return XCTFail("the scalar discount call must classify ROUTABLE; got \(verdict)")
        }
        // The classified site carries the marshalling tags the ABI core will encode:
        // Double→f64, Int→i64, Double return→f64. These MUST be byte-identical to the
        // engine's canonical TLVTag (proven in testValueTagsAreByteIdenticalToTLVTag).
        XCTAssertEqual(site.args.map(\.tag), [.f64, .i64])
        XCTAssertEqual(site.returnTag, .f64)
        XCTAssertEqual(site.canonicalSignature, Self.canonicalSignature)
    }

    /// Demote-on-doubt is the classifier's value: an `inout` arg / a non-marshallable
    /// reference arg / an unresolvable symbol each DEMOTES (stays native).
    func testClassifierDemotesOnDoubt() {
        let base = GeneralBridgeRewriter.Candidate(
            kind: .freeOrStatic, receiver: "PricingEngine", function: "discount",
            nativeExpr: "PricingEngine.discount(subtotal: s, tier: t)",
            canonicalSignature: Self.canonicalSignature,
            args: [.init(expr: "s", swiftType: "Double"), .init(expr: "t", swiftType: "Int")],
            returnType: "Double", symbolResolvable: true)

        // Symbol not in the routed set → demote (DESIGN §4.1).
        var c = base; c = GeneralBridgeRewriter.Candidate(
            kind: c.kind, receiver: c.receiver, function: c.function, nativeExpr: c.nativeExpr,
            canonicalSignature: c.canonicalSignature, args: c.args, returnType: c.returnType,
            symbolResolvable: false)
        if case .demote(.unresolvableSymbol) = GeneralBridgeRewriter().classify(c) {} else {
            XCTFail("an unresolvable symbol must demote")
        }
        // A reference-type arg the guest can't marshal → demote.
        let refArg = GeneralBridgeRewriter.Candidate(
            kind: .freeOrStatic, receiver: "X", function: "f", nativeExpr: "X.f(obj)",
            canonicalSignature: "MyApp.X.f(SomeClass)->Void",
            args: [.init(expr: "obj", swiftType: "SomeClass")], returnType: "Void")
        if case .demote(.unmarshallableArgType) = GeneralBridgeRewriter().classify(refArg) {} else {
            XCTFail("a non-marshallable reference arg must demote")
        }
    }

    /// Agent 3's `HostBridgeValueTag` and Agent 2's `TLVTag` MUST be the SAME wire
    /// bytes (DESIGN §2.2) — the reconciliation requires a 1:1 mapping. A drift here
    /// silently misdispatches every routed call.
    func testValueTagsAreByteIdenticalToTLVTag() {
        XCTAssertEqual(HostBridgeValueTag.nilValue.rawValue, TLVTag.nilValue.rawValue)
        XCTAssertEqual(HostBridgeValueTag.i64.rawValue,      TLVTag.i64.rawValue)
        XCTAssertEqual(HostBridgeValueTag.f64.rawValue,      TLVTag.f64.rawValue)
        XCTAssertEqual(HostBridgeValueTag.bool.rawValue,     TLVTag.bool.rawValue)
        XCTAssertEqual(HostBridgeValueTag.string.rawValue,   TLVTag.string.rawValue)
        XCTAssertEqual(HostBridgeValueTag.bytes.rawValue,    TLVTag.bytes.rawValue)
        XCTAssertEqual(HostBridgeValueTag.handle.rawValue,   TLVTag.handle.rawValue)
        XCTAssertEqual(HostBridgeValueTag.error.rawValue,    TLVTag.error.rawValue)
        // And every case maps 1:1 (no extra/missing tags).
        XCTAssertEqual(HostBridgeValueTag.allCases.map(\.rawValue).sorted(),
                       TLVTag.allCases.map(\.rawValue).sorted())
    }

    // =======================================================================
    // MARK: (b) Agent 2 — derive id, emit the guest, compile to WASM, RUN it
    // =======================================================================

    /// The content-addressed id is `truncate32(SHA256(canonicalSignature))`. Assert
    /// against an independent SHA256 + pin the golden value the SDK test mirrors.
    func testSymbolIdIsContentAddressed() {
        let id = HostBridgeABI.hostBridgeSymbolId(Self.canonicalSignature)
        let digest = SHA256.hash(data: Data(Self.canonicalSignature.utf8))
        let bytes = Array(digest.prefix(4))
        let u = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
              | (UInt32(bytes[2]) << 8)  | UInt32(bytes[3])
        XCTAssertEqual(id, Int32(bitPattern: u))
        // The golden value the engine-emitted guest + the SDK runtime test pin.
        XCTAssertEqual(id, -1509889347,
                       "the routed symbol id must equal the constant both halves agree on")
    }

    /// The canonical signature derivation (Agent 2) reproduces the exact key the
    /// resolver thunk matches (module-qualified, no whitespace, declaration order).
    func testCanonicalSignatureDerivation() {
        let call = HostBridgeABI.ResolvedCall(
            receiverType: Self.receiverModuleType,
            name: Self.methodName,
            params: [.init(label: "subtotal", type: "Double"), .init(label: "tier", type: "Int")],
            returnType: "Double")
        XCTAssertEqual(HostBridgeABI.canonicalSignature(call), Self.canonicalSignature)
    }

    /// THE END-TO-END ENGINE PROOF: emit the guest (Agent 2 preamble + call site),
    /// compile it to a REAL .wasm with the swift.org toolchain, and RUN it through
    /// WasmKit with a host dispatcher that executes the Agent-4 resolver thunk's
    /// exact closure. The guest's routed PricingEngine.discount(129.99, tier 1) result
    /// must equal the host's own native computation — value-exact.
    ///
    /// Skips (stays green) when the WASM toolchain is absent.
    func testEmittedGuestCompilesAndRoutesThroughWasmKit() throws {
        try XCTSkipUnless(SwiftWasmCompiler().toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping guest compile/run")

        // --- emit the guest body with the REAL Agent-2 codegen ---
        let symbol = HostBridgeSymbol(canonicalSignature: Self.canonicalSignature,
                                      argTags: [.f64, .i64], retTag: .f64)
        let guestSource = Self.renderGuestSource(symbol: symbol)
        // It parses (the toolchain-free floor) before we pay for a WASM compile.
        XCTAssertTrue(parses(guestSource), "the emitted guest source must parse:\n\(guestSource)")

        // --- compile it to a real .wasm (full WASM SDK, reactor model) ---
        let wasm = try Self.compileGuestWasm(guestBody: guestSource)

        // --- run it through WasmKit; dispatch the one routed symbol via the
        //     Agent-4 resolver-thunk's EXACT closure body. ---
        let id = symbol.id
        let runner = try GenericGuestRunner(wasm: wasm) { symbolId, argsBlob in
            guard symbolId == id else { return .error("unknown symbolId \(symbolId)") }
            // Agent-4 real-SDK thunk body, executed verbatim:
            //   .f64(Double(PricingEngine.discount(subtotal: args.f64(0), tier: Int(args.i64(1)))))
            let decoded = try TLVMini.decodeArgs(argsBlob)
            guard case .f64(let subtotal) = decoded[0], case .i64(let tier) = decoded[1] else {
                return .error("arg type mismatch")
            }
            return .f64(VSlicePricingEngine.discount(subtotal: subtotal, tier: Int(tier)))
        }

        let cents = try runner.callI64("test_routed_discount_cents")
        let expected = Int64((VSlicePricingEngine.discount(subtotal: 129.99, tier: 1) * 100).rounded())
        XCTAssertEqual(expected, 12349, "documented exact silver-tier result")
        XCTAssertEqual(cents, expected,
                       "the engine-emitted guest must route PricingEngine.discount through the generic bridge value-exact")
    }

    // =======================================================================
    // MARK: (c) Agent 4 — generate the real-SDK resolver thunk + prove it compiles
    // =======================================================================

    /// The retargeted generator emits the EXACT real-SDK registration shape (the
    /// integration contract): `bridge.register(id:signature:) { (args: ArgReader,
    /// handles: HandleTable) throws -> TLVValue in return .f64(Double(...)) }`.
    func testResolverThunkSourceTargetsRealSDKAPI() {
        let sym = Self.discountRoutedSymbol()
        let r = HostBridgeThunkGenerator(target: .realSDK).generate(symbols: [sym])
        let src = r.fileContents
        XCTAssertEqual(r.emittedSymbolIDs, [sym.id])
        XCTAssertTrue(r.demoted.isEmpty, "no demote for a clean scalar fn; got \(r.demoted)")

        // The REAL SDK module is imported (not the stub `PatchSDK` enum).
        XCTAssertTrue(src.contains("import PatchHostBridge"), src)
        // The instance register with the TWO-param closure + TLVValue return.
        XCTAssertTrue(src.contains("bridge.register(id: \(sym.id), signature:"), src)
        XCTAssertTrue(src.contains("{ (args: ArgReader, handles: HandleTable) throws -> TLVValue in"), src)
        // The real accessors (string NOT str; Int(try args.i64(...))); .f64 result.
        XCTAssertTrue(src.contains("return .f64(Double(PricingEngine.discount(subtotal: try args.f64(0), tier: Int(try args.i64(1)))))"),
                      "the real-SDK thunk must call the native symbol via ArgReader; got:\n\(src)")
        XCTAssertFalse(src.contains("\u{1}"), "no sentinel may survive")
        XCTAssertTrue(parses(src), src)
    }

    /// THE COMPILES-OR-DEMOTE NET on the real-SDK ABI: the generated thunk must host-
    /// `swiftc -typecheck` against the developer's real `PricingEngine` + the real
    /// PatchHostBridge ABI shim — the proof that the emitted registration is build-safe.
    /// Skips without a host swiftc.
    func testResolverThunkTypechecksAgainstRealSDKShim() throws {
        guard BridgeThunkValidator.hostSwiftc() != nil else { throw XCTSkip("no host swiftc") }
        let r = HostBridgeThunkGenerator(target: .realSDK).generate(
            symbols: [Self.discountRoutedSymbol()],
            validate: BridgeThunkValidator(),
            appTypeStub: Self.pricingStub)
        XCTAssertEqual(r.emittedSymbolIDs, [Self.discountRoutedSymbol().id],
                       "a real-SDK thunk that type-checks against the app types must be kept; demoted=\(r.demoted)")
        XCTAssertTrue(r.demoted.isEmpty, "no demote for a type-correct real-SDK thunk; got \(r.demoted)")
    }

    /// And the net DROPS a real-SDK thunk whose native call no longer compiles
    /// (renamed/removed) — build-safe = demote-safe, on the real ABI.
    func testRealSDKThunkDemotedWhenSymbolRenamed() throws {
        guard BridgeThunkValidator.hostSwiftc() != nil else { throw XCTSkip("no host swiftc") }
        let renamedStub = """
        enum PricingEngine {
            static func computeDiscount(subtotal: Double, tier: Int) -> Double { 0 }
        }
        """
        let r = HostBridgeThunkGenerator(target: .realSDK).generate(
            symbols: [Self.discountRoutedSymbol()],
            validate: BridgeThunkValidator(),
            appTypeStub: renamedStub)
        XCTAssertTrue(r.emittedSymbolIDs.isEmpty,
                      "a real-SDK thunk that does not compile against the app types must demote")
        XCTAssertEqual(r.demoted.first?.id, Self.discountRoutedSymbol().id)
    }

    // =======================================================================
    // MARK: Helpers
    // =======================================================================

    private static func discountRoutedSymbol() -> RoutedSymbol {
        RoutedSymbol(
            id: HostBridgeABI.hostBridgeSymbolId(canonicalSignature),
            canonicalSignature: canonicalSignature,
            callTemplate: "PricingEngine.discount(subtotal: \u{1}0\u{1}, tier: \u{1}1\u{1})",
            argTypes: [.double, .int],
            returnType: .double,
            requiredImports: [])
    }

    private static let pricingStub = """
    enum PricingEngine {
        static func discount(subtotal: Double, tier: Int) -> Double {
            (subtotal * (1.0 - (tier == 2 ? 0.12 : tier == 1 ? 0.05 : 0)) * 100).rounded() / 100
        }
    }
    """

    /// Assemble the full guest `main.swift`: `import CBridge` + Agent-2 preamble +
    /// a `@_cdecl` export whose body is Agent-2's `emitCallSite(...)` (returning the
    /// discounted total in cents), + the reactor noop.
    private static func renderGuestSource(symbol: HostBridgeSymbol) -> String {
        let preamble = HostBridgeABI.emitGuestPreamble()
        let callSite = HostBridgeABI.emitCallSite(
            symbol: symbol,
            args: [.init(expr: "129.99", tag: .f64), .init(expr: "1", tag: .i64)],
            resultName: "discounted",
            demoteBody: "return -1")
        return """
        import CBridge

        \(preamble)

        @_cdecl("test_routed_discount_cents")
        public func test_routed_discount_cents() -> Int64 {
            \(callSite.split(separator: "\n").joined(separator: "\n    "))
            return Int64((discounted * 100).rounded())
        }

        @_cdecl("patch_noop")
        public func patch_noop() {}
        """
    }

    /// Compile the guest body to a real .wasm via a standalone SwiftPM package
    /// (full WASM SDK, reactor model), reusing the prototype's CBridge (the three
    /// generic flat imports + the result allocator). Mirrors the prototype run.sh.
    private static func compileGuestWasm(guestBody: String) throws -> [UInt8] {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("l2-vslice-\(UUID().uuidString)")
        let cbInc = work.appendingPathComponent("Sources/CBridge/include")
        let guestDir = work.appendingPathComponent("Sources/Guest")
        try fm.createDirectory(at: cbInc, withIntermediateDirectories: true)
        try fm.createDirectory(at: guestDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // The prototype CBridge declares patch_host.call/.release/.have + patch_malloc.
        // #filePath = <repo>/cli/Tests/PartitioningEngineTests/HostBridgeVerticalSliceTests.swift
        // → 4 deletions reach <repo>; experiments/ lives at the repo root (not under cli/).
        let proto = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PartitioningEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // cli
            .deletingLastPathComponent()   // <repo>
            .appendingPathComponent("experiments/host-bridge-generalized/guest/Sources/CBridge")
        // The CBridge fixture lives in the monorepo's local `experiments/` scratch dir, which
        // is absent from a standalone checkout (the split-cli clone, a fresh CI clone). Skip
        // the guest-compile+WasmKit slice rather than failing when the fixture isn't present.
        guard fm.fileExists(atPath: proto.appendingPathComponent("include/cbridge.h").path) else {
            throw XCTSkip("Lever-#2 vertical-slice CBridge fixture (experiments/host-bridge-generalized/) "
                + "not present in this checkout — skipping the guest-compile+WasmKit slice.")
        }
        try String(contentsOf: proto.appendingPathComponent("include/cbridge.h"), encoding: .utf8)
            .write(to: cbInc.appendingPathComponent("cbridge.h"), atomically: true, encoding: .utf8)
        try String(contentsOf: proto.appendingPathComponent("shim.c"), encoding: .utf8)
            .write(to: work.appendingPathComponent("Sources/CBridge/shim.c"), atomically: true, encoding: .utf8)
        try guestBody.write(to: guestDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Guest", targets: [
            .target(name: "CBridge"),
            .executableTarget(name: "Guest", dependencies: ["CBridge"],
                swiftSettings: [ .swiftLanguageMode(.v5) ],
                linkerSettings: [ .unsafeFlags([
                    "-Xclang-linker", "-mexec-model=reactor",
                    "-Xlinker", "--allow-undefined",
                    "-Xlinker", "--export-if-defined=patch_malloc",
                    "-Xlinker", "--export-if-defined=patch_reset_arena",
                    "-Xlinker", "--export-if-defined=patch_noop",
                    "-Xlinker", "--export-if-defined=test_routed_discount_cents",
                ]) ])
        ])
        """
        try manifest.write(to: work.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        // Build with the swiftly WASM toolchain (NOT the host swiftc).
        let swiftBin = SwiftWasmCompiler.defaultToolchainSwift
        let p = Process()
        p.executableURL = swiftBin
        p.arguments = ["build", "--swift-sdk", "swift-6.3.2-RELEASE_wasm", "-c", "release"]
        p.currentDirectoryURL = work
        var env = ProcessInfo.processInfo.environment
        // Put the swiftly bin first (the WASM SDK lives there); mirror the memory note.
        let swiftlyBin = fm.homeDirectoryForCurrentUser.appendingPathComponent(".swiftly/bin").path
        env["PATH"] = "\(swiftlyBin):/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        p.environment = env
        let errPipe = Pipe(); p.standardError = errPipe; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        let log = String(data: (try? errPipe.fileHandleForReading.readToEnd()) ?? Data() ?? Data(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "vslice", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "guest WASM compile failed:\n\(log)"])
        }
        let out = work.appendingPathComponent(".build/wasm32-unknown-wasip1/release/Guest.wasm")
        return [UInt8](try Data(contentsOf: out))
    }
}

// MARK: - The native symbol the routed call resolves to (engine-side test mirror).

private enum VSlicePricingEngine {
    static func discount(subtotal: Double, tier: Int) -> Double {
        let pct: Double = (tier == 2) ? 0.12 : (tier == 1) ? 0.05 : 0.0
        return (subtotal * (1.0 - pct) * 100).rounded() / 100
    }
}

// MARK: - A minimal TLV decode (mirrors DESIGN §2.2) for the host dispatcher.
// Only what the dispatcher needs (decode the arg blob). Byte-identical to the SDK
// codec + Agent-2's writer; the SDK test asserts the full byte layout separately.

private enum TLVMini {
    enum Value: Equatable { case i64(Int64); case f64(Double); case other }
    static func decodeArgs(_ b: [UInt8]) throws -> [Value] {
        guard !b.isEmpty else { return [] }
        var i = 0
        let argc = Int(b[i]); i += 1
        var out: [Value] = []
        for _ in 0..<argc {
            guard i < b.count else { throw err("truncated") }
            let tag = b[i]; i += 1
            switch tag {
            case 1:  // i64
                guard i + 8 <= b.count else { throw err("i64") }
                var v: UInt64 = 0; for k in 0..<8 { v |= UInt64(b[i+k]) << (UInt64(k)*8) }; i += 8
                out.append(.i64(Int64(bitPattern: v)))
            case 2:  // f64
                guard i + 8 <= b.count else { throw err("f64") }
                var v: UInt64 = 0; for k in 0..<8 { v |= UInt64(b[i+k]) << (UInt64(k)*8) }; i += 8
                out.append(.f64(Double(bitPattern: v)))
            default: throw err("unsupported tag \(tag)")
            }
        }
        return out
    }
    static func encodeF64(_ v: Double) -> [UInt8] {
        var out: [UInt8] = [2]
        let bits = (v.isFinite ? v : 0).bitPattern
        for k in 0..<8 { out.append(UInt8((bits >> (UInt64(k)*8)) & 0xff)) }
        return out
    }
    static func encodeError(_ s: String) -> [UInt8] {
        let u = Array(s.utf8)
        var out: [UInt8] = [7]
        let n = UInt32(u.count)
        out.append(UInt8(n & 0xff)); out.append(UInt8((n>>8)&0xff)); out.append(UInt8((n>>16)&0xff)); out.append(UInt8((n>>24)&0xff))
        out.append(contentsOf: u)
        return out
    }
    static func err(_ w: String) -> NSError { NSError(domain: "tlv", code: 1, userInfo: [NSLocalizedDescriptionKey: w]) }
}

private enum DispatchResult { case f64(Double); case error(String) }

// MARK: - A WasmKit runner wiring the THREE generic imports to a dispatcher.
// This mirrors the SDK's GenericHostBridge glue (the SDK test drives the SAME
// guest through the REAL GenericHostBridge); here, in the engine package, we use
// a faithful local glue so the engine half is self-contained.

private final class GenericGuestRunner {
    let store: Store
    let instance: Instance
    let wasi: WASIBridgeToHost
    let dispatch: (Int32, [UInt8]) throws -> DispatchResult

    init(wasm: [UInt8], dispatch: @escaping (Int32, [UInt8]) throws -> DispatchResult) throws {
        self.dispatch = dispatch
        let engine = Engine()
        self.store = Store(engine: engine)
        self.wasi = try WASIBridgeToHost()
        var imports = Imports()
        wasi.link(to: &imports, store: store)
        let disp = dispatch

        func readBytes(_ caller: Caller, _ p: UInt32, _ l: UInt32) -> [UInt8] {
            guard let mem = caller.instance?.exports[memory: "memory"] else { return [] }
            let all = mem.data
            let s = Int(p), e = Int(p) + Int(l)
            guard s >= 0, e <= all.count, l > 0 else { return [] }
            return [UInt8](all[s..<e])
        }
        func packed(_ caller: Caller, _ bytes: [UInt8]) -> Value {
            if bytes.isEmpty { return .i64(0) }
            guard let alloc = caller.instance?.exports[function: "patch_malloc"],
                  let res = try? alloc.invoke([.i32(UInt32(bytes.count))]),
                  case .i32(let ptr) = res[0], ptr != 0,
                  let mem = caller.instance?.exports[memory: "memory"] else { return .i64(0) }
            mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: bytes.count) { raw in
                raw.copyBytes(from: bytes)
            }
            return .i64((UInt64(ptr) << 32) | UInt64(bytes.count))
        }

        imports.define(module: "patch_host", name: "call",
            Function(store: store, parameters: [.i32, .i32, .i32], results: [.i64]) { caller, args in
                let symbolId = Int32(bitPattern: args[0].i32)
                let blob = readBytes(caller, args[1].i32, args[2].i32)
                let resultBytes: [UInt8]
                do {
                    switch try disp(symbolId, blob) {
                    case .f64(let v):   resultBytes = TLVMini.encodeF64(v)
                    case .error(let m): resultBytes = TLVMini.encodeError(m)
                    }
                } catch {
                    resultBytes = TLVMini.encodeError("\(error)")
                }
                return [packed(caller, resultBytes)]
            })
        imports.define(module: "patch_host", name: "release",
            Function(store: store, parameters: [.i32], results: []) { _, _ in [] })
        imports.define(module: "patch_host", name: "have",
            Function(store: store, parameters: [.i32], results: [.i32]) { _, _ in [.i32(1)] })

        let module = try parseWasm(bytes: wasm)
        self.instance = try module.instantiate(store: store, imports: imports)
        try wasi.initialize(instance)
    }

    func callI64(_ name: String) throws -> Int64 {
        guard let fn = instance.exports[function: name] else {
            throw NSError(domain: "vslice", code: 2, userInfo: [NSLocalizedDescriptionKey: "no export \(name)"])
        }
        let r = try fn.invoke([])
        return r.isEmpty ? 0 : Int64(bitPattern: r[0].i64)
    }
}
