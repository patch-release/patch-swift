// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import SwiftParser
@testable import CodeGenerator

/// Tests for the RESOLVER-THUNK GENERATOR — the App-Store-clean resolution mechanism for
/// the generalized "call what's already linked" host bridge (DESIGN §4.2). The generator
/// emits, INTO THE APP TARGET, a compiled-in dispatch table: for each routed native symbol,
/// a closure that decodes TLV args, calls the REAL native symbol, and encodes the TLV result.
///
/// The properties pinned here:
///   1. the generated thunk SOURCE is correct for a scalar free fn + a Foundation call;
///   2. the COMPILES-OR-DEMOTE net drops a symbol whose call expression won't compile;
///   3. (when an iOS/host SDK is present) the generated thunk for a good symbol actually
///      host-`swiftc -typecheck`s against a stub of the app types + the registry shim — the
///      production proof that "build-safe = demote-safe".
final class HostBridgeThunkGeneratorTests: XCTestCase {

    private func parses(_ s: String) -> Bool { !Parser.parse(source: s).hasError }

    // MARK: - Sample routed symbols

    /// (a) a SCALAR FREE FUNCTION — the prototype's `PricingEngine.discount(subtotal:tier:)`
    /// (DESIGN proof shape (a), symbolId 101): `(Double, Int) -> Double`.
    private func discountSymbol(id: Int32 = 101) -> RoutedSymbol {
        RoutedSymbol(
            id: id,
            canonicalSignature: "MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double",
            callTemplate: "PricingEngine.discount(subtotal: \u{1}0\u{1}, tier: \u{1}1\u{1})",
            argTypes: [.double, .int],
            returnType: .double,
            requiredImports: [])
    }

    /// (b) a FOUNDATION call — `String(format:_:)` over a string + an int, returning a String.
    /// Stands in for "an arbitrary Foundation API the curated bridges don't cover".
    private func foundationFormatSymbol(id: Int32 = 301) -> RoutedSymbol {
        RoutedSymbol(
            id: id,
            canonicalSignature: "Foundation.String.init(format:String,CVarArg)->String",
            callTemplate: "String(format: \u{1}0\u{1}, \u{1}1\u{1})",
            argTypes: [.string, .int],
            returnType: .string,
            requiredImports: ["Foundation"])
    }

    /// The app-type stub that makes the discount symbol resolvable in the type-check probe —
    /// the developer's REAL `PricingEngine` (or a stub of it). Used by the compiles-or-demote
    /// net's baseline + per-symbol probes.
    private let pricingStub = """
    enum PricingEngine {
        static func discount(subtotal: Double, tier: Int) -> Double {
            subtotal * (1.0 - (tier == 2 ? 0.12 : tier == 1 ? 0.05 : 0))
        }
    }
    """

    // MARK: - (1) Generated source correctness

    func testScalarFreeFunctionThunkSourceIsCorrect() {
        let r = HostBridgeThunkGenerator().generate(symbols: [discountSymbol()])
        let src = r.fileContents
        XCTAssertEqual(r.emittedSymbolIDs, [101])
        XCTAssertTrue(r.demoted.isEmpty, "no demote expected for a clean scalar fn")

        // The registration is keyed by id + carries the signature.
        XCTAssertTrue(src.contains("PatchHostBridge.register(id: 101, signature:"), src)
        XCTAssertTrue(src.contains("MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double"), src)
        // The args decode with the RIGHT TLV accessors for (Double, Int) and the call template
        // is substituted: `\u{1}0\u{1}` → `try __a.f64(0)`, `\u{1}1\u{1}` → `Int(try __a.i64(1))`.
        XCTAssertTrue(src.contains("PricingEngine.discount(subtotal: try __a.f64(0), tier: Int(try __a.i64(1)))"),
                      "args must substitute typed decodes; got:\n\(src)")
        // No raw sentinel placeholder survived.
        XCTAssertFalse(src.contains("\u{1}"), "no \\u{1} sentinel may survive into the source")
        // A Double return encodes as `.f64(...)`.
        XCTAssertTrue(src.contains("return .f64(Double(PricingEngine.discount("), src)
        // Per-symbol isolation region present.
        XCTAssertTrue(src.contains(HostBridgeThunkGenerator.beginRegion(101)), src)
        XCTAssertTrue(src.contains(HostBridgeThunkGenerator.endRegion(101)), src)
        // The whole generated file PARSES.
        XCTAssertTrue(parses(src), "the generated file must parse:\n\(src)")
        // The register entry-point is declared.
        XCTAssertTrue(src.contains("func \(HostBridgeThunkGenerator.registerFunctionName)()"), src)
    }

    func testFoundationStringReturningThunkSourceIsCorrect() {
        let r = HostBridgeThunkGenerator().generate(symbols: [foundationFormatSymbol()])
        let src = r.fileContents
        XCTAssertEqual(r.emittedSymbolIDs, [301])
        // String arg → `try __a.str(0)`; Int arg → `Int(try __a.i64(1))`.
        XCTAssertTrue(src.contains("String(format: try __a.str(0), Int(try __a.i64(1)))"),
                      "Foundation call args must substitute typed decodes; got:\n\(src)")
        // String return → `.string(...)`.
        XCTAssertTrue(src.contains("return .string(String(format:"), src)
        XCTAssertTrue(parses(src), "the generated file must parse:\n\(src)")
    }

    func testHandleReturnAndArgEncodeAndDecode() {
        // A CONSTRUCTOR returning a reference type (DESIGN proof shape (b)): the result is
        // retained in the host handle table; a later method takes that handle as arg 0.
        let make = RoutedSymbol(
            id: 201,
            canonicalSignature: "Foundation.makeCurrencyFormatter(String)->NumberFormatter",
            callTemplate: "makeCurrencyFormatter(\u{1}0\u{1})",
            argTypes: [.string],
            returnType: .handle("NumberFormatter"),
            requiredImports: ["Foundation"])
        let format = RoutedSymbol(
            id: 202,
            canonicalSignature: "Foundation.NumberFormatter.string(from:NSNumber)->String",
            callTemplate: "\u{1}0\u{1}.string(from: NSNumber(value: \u{1}1\u{1})) ?? \"\"",
            argTypes: [.handle("NumberFormatter"), .double],
            returnType: .string,
            requiredImports: ["Foundation"])
        let src = HostBridgeThunkGenerator().generate(symbols: [make, format]).fileContents
        // Constructor: returned ref type is retained → TLV handle out.
        XCTAssertTrue(src.contains("return .handle(__a.retain(makeCurrencyFormatter(try __a.str(0))))"), src)
        // Method: handle arg 0 is resolved + cast to the expected type; double arg 1 decodes.
        XCTAssertTrue(src.contains("(try __a.object(0, as: NumberFormatter.self)).string(from: NSNumber(value: try __a.f64(1)))"),
                      "handle arg must resolve + cast; got:\n\(src)")
        XCTAssertTrue(parses(src), "the generated file must parse:\n\(src)")
    }

    func testVoidReturnEmitsNilValue() {
        let logIt = RoutedSymbol(
            id: 401,
            canonicalSignature: "MyApp.Analytics.track(String)->Void",
            callTemplate: "Analytics.track(\u{1}0\u{1})",
            argTypes: [.string],
            returnType: .void)
        let src = HostBridgeThunkGenerator().generate(symbols: [logIt]).fileContents
        XCTAssertTrue(src.contains("Analytics.track(try __a.str(0))\n"), src)
        XCTAssertTrue(src.contains("return .nilValue"), src)
        XCTAssertTrue(parses(src), src)
    }

    func testEmptySymbolSetEmitsEmptyFile() {
        let r = HostBridgeThunkGenerator().generate(symbols: [])
        XCTAssertEqual(r.fileContents, "")
        XCTAssertTrue(r.emittedSymbolIDs.isEmpty)
        XCTAssertTrue(r.demoted.isEmpty)
    }

    func testMultipleSymbolsEachInOwnIsolatedRegion() {
        let r = HostBridgeThunkGenerator().generate(symbols: [discountSymbol(), foundationFormatSymbol()])
        let src = r.fileContents
        XCTAssertEqual(r.emittedSymbolIDs, [101, 301])
        // Each symbol has its own BEGIN/END region — the unit the net isolates.
        for id: Int32 in [101, 301] {
            XCTAssertTrue(src.contains(HostBridgeThunkGenerator.beginRegion(id)), "missing region \(id)")
            XCTAssertTrue(src.contains(HostBridgeThunkGenerator.endRegion(id)), "missing end region \(id)")
        }
        XCTAssertTrue(parses(src), src)
    }

    // MARK: - (2) Compiles-or-demote net: SYNTAX gate (toolchain-free)

    /// A malformed call template (a `\u{1}k\u{1}` placeholder with no matching `argTypes`
    /// entry) leaves a bare sentinel in the source → it does NOT parse → the symbol is
    /// DROPPED by the syntax gate (the toolchain-free floor of the compiles-or-demote net).
    func testMalformedTemplateDemotedBySyntaxGate() {
        // 2 placeholders but only 1 declared arg type → `\u{1}1\u{1}` survives unsubstituted.
        let bad = RoutedSymbol(
            id: 999,
            canonicalSignature: "MyApp.Bad.call(Int,Int)->Int",
            callTemplate: "Bad.call(\u{1}0\u{1}, \u{1}1\u{1})",
            argTypes: [.int],          // only arg 0 — arg 1 placeholder can't substitute
            returnType: .int)
        let r = HostBridgeThunkGenerator().generate(symbols: [bad])
        XCTAssertTrue(r.emittedSymbolIDs.isEmpty, "a malformed-template symbol must be demoted")
        XCTAssertEqual(r.demoted.count, 1)
        XCTAssertEqual(r.demoted.first?.id, 999)
        XCTAssertEqual(r.fileContents, "", "no file when every symbol demoted")
    }

    /// A good symbol survives the syntax gate even when a sibling demotes (per-symbol
    /// isolation — one bad symbol never disables the rest).
    func testGoodSymbolSurvivesWhenSiblingDemotes() {
        let bad = RoutedSymbol(
            id: 999, canonicalSignature: "Bad", callTemplate: "Bad(\u{1}0\u{1}, \u{1}1\u{1})",
            argTypes: [.int], returnType: .int)
        let r = HostBridgeThunkGenerator().generate(symbols: [discountSymbol(), bad])
        XCTAssertEqual(r.emittedSymbolIDs, [101], "the good symbol must still emit")
        XCTAssertEqual(r.demoted.map { $0.id }, [999])
        XCTAssertTrue(parses(r.fileContents), r.fileContents)
    }

    // MARK: - (3) Compiles-or-demote net: HOST swiftc type-check (the production proof)

    /// The good scalar-fn thunk MUST host-`swiftc -typecheck` against the app-type stub +
    /// the registry shim — the production proof that the generated native call is build-safe.
    /// Skips when the host toolchain is unavailable (e.g. a Linux CI box without swiftc).
    func testGoodThunkTypechecksAgainstAppStub() throws {
        guard BridgeThunkValidator.hostSwiftc() != nil else { throw XCTSkip("no host swiftc") }
        let r = HostBridgeThunkGenerator().generate(symbols: [discountSymbol()],
                                                    validate: BridgeThunkValidator(),
                                                    appTypeStub: pricingStub)
        // The net ran and KEPT the symbol — it type-checks against the real `PricingEngine`.
        XCTAssertEqual(r.emittedSymbolIDs, [101],
                       "a thunk that compiles against the app types must be kept; demoted=\(r.demoted)")
        XCTAssertTrue(r.demoted.isEmpty, "no demote for a type-correct thunk; got \(r.demoted)")
        XCTAssertTrue(parses(r.fileContents), r.fileContents)
    }

    /// THE COMPILES-OR-DEMOTE NET — the load-bearing property. A symbol whose REAL native
    /// call expression does NOT compile against the app types (here: the app's `PricingEngine`
    /// has NO `discount` member — it was renamed/removed since the engine routed it) must be
    /// DROPPED by the net rather than break the developer's build. Skips without host swiftc.
    func testNonCompilingThunkIsDemotedByNet() throws {
        guard BridgeThunkValidator.hostSwiftc() != nil else { throw XCTSkip("no host swiftc") }
        // The stub's `PricingEngine` exists but has NO `discount(subtotal:tier:)` — the routed
        // call `PricingEngine.discount(subtotal:tier:)` therefore won't type-check.
        let renamedStub = """
        enum PricingEngine {
            static func computeDiscount(subtotal: Double, tier: Int) -> Double { 0 }
        }
        """
        let r = HostBridgeThunkGenerator().generate(symbols: [discountSymbol()],
                                                    validate: BridgeThunkValidator(),
                                                    appTypeStub: renamedStub)
        XCTAssertTrue(r.emittedSymbolIDs.isEmpty,
                      "a thunk that does NOT compile against the app types must be demoted, not emitted")
        XCTAssertEqual(r.demoted.count, 1)
        XCTAssertEqual(r.demoted.first?.id, 101)
        XCTAssertTrue(r.demoted.first?.reason.contains("type-check") ?? false, r.demoted.first?.reason ?? "")
    }

    /// Per-symbol isolation under the host net: a GOOD symbol + a NON-COMPILING symbol →
    /// the good one is kept, the bad one demoted (one bad symbol never condemns the good one).
    func testNetIsolatesGoodFromBadSymbol() throws {
        guard BridgeThunkValidator.hostSwiftc() != nil else { throw XCTSkip("no host swiftc") }
        // `discount` exists; `missing(...)` does not.
        let stub = """
        enum PricingEngine {
            static func discount(subtotal: Double, tier: Int) -> Double { 0 }
        }
        """
        let bad = RoutedSymbol(
            id: 888,
            canonicalSignature: "MyApp.PricingEngine.missing(Int)->Int",
            callTemplate: "PricingEngine.missing(\u{1}0\u{1})",
            argTypes: [.int],
            returnType: .int)
        let r = HostBridgeThunkGenerator().generate(symbols: [discountSymbol(), bad],
                                                    validate: BridgeThunkValidator(),
                                                    appTypeStub: stub)
        XCTAssertEqual(r.emittedSymbolIDs, [101], "the good symbol must survive; demoted=\(r.demoted)")
        XCTAssertEqual(r.demoted.map { $0.id }, [888], "only the non-compiling symbol demotes")
    }

    /// SAFETY VALVE (never spuriously demote): when the app-type baseline does NOT compile on
    /// its own (an unresolvable import in the stub), the net is INCONCLUSIVE → it skips
    /// (keeps every symbol) rather than blame the thunk. Mirrors `BridgeTypecheck`'s baseline
    /// guard. Skips without host swiftc.
    func testInconclusiveBaselineKeepsAllSymbols() throws {
        guard BridgeThunkValidator.hostSwiftc() != nil else { throw XCTSkip("no host swiftc") }
        // A stub that references an unresolvable third-party import → baseline won't compile.
        let brokenStub = """
        import ThisModuleDoesNotExist1234
        enum PricingEngine {
            static func discount(subtotal: Double, tier: Int) -> Double { 0 }
        }
        """
        let net = BridgeThunkValidator().run(symbols: [discountSymbol()], appTypeStub: brokenStub)
        XCTAssertFalse(net.ran, "an inconclusive baseline must skip the net (keep all): \(net.note)")
        XCTAssertTrue(net.failing.isEmpty, "no symbol may be demoted on an inconclusive baseline")
        // …and the generator therefore emits the symbol (kept).
        let r = HostBridgeThunkGenerator().generate(symbols: [discountSymbol()],
                                                    validate: BridgeThunkValidator(),
                                                    appTypeStub: brokenStub)
        XCTAssertEqual(r.emittedSymbolIDs, [101], "an inconclusive net must keep the symbol")
    }

    // MARK: - Probe / shim sanity

    /// The standalone probe (the per-symbol type-check unit) is itself well-formed Swift —
    /// the app stub + the registry shim + the one registration, parseable. Guards the probe
    /// construction (a malformed probe would make the net falsely demote everything).
    func testStandaloneProbeParses() {
        let sym = discountSymbol()
        let probe = HostBridgeThunkGenerator.standaloneProbe(
            region: HostBridgeThunkGenerator.renderRegistration(sym), sym: sym, appTypeStub: pricingStub)
        XCTAssertTrue(parses(probe), "the standalone probe must parse:\n\(probe)")
        // The registry shim it embeds is itself valid Swift.
        XCTAssertTrue(parses("import Foundation\n" + HostBridgeThunkGenerator.registrySDKShim),
                      "the registry SDK shim must parse")
    }

    // MARK: - (4) THROWING native symbols (DESIGN §8.7 — the .error demote channel)

    /// A `throws` free function: the routed call is `try …` and the whole encode is wrapped in
    /// `do { return … } catch { return .error("\(error)") }`. The `.error` tag is the demote
    /// channel — a thrown native error routes the guest to its native fallback, never a crash.
    func testThrowingSymbolWrapsInDoCatchError() {
        let parse = RoutedSymbol(
            id: 501,
            canonicalSignature: "MyApp.Parser.parse(String)->Int",
            callTemplate: "Parser.parse(\u{1}0\u{1})",
            argTypes: [.string],
            returnType: .int,
            requiredImports: [],
            isThrowing: true)
        let src = HostBridgeThunkGenerator().generate(symbols: [parse]).fileContents
        // The native call is `try …`.
        XCTAssertTrue(src.contains("Int64(try Parser.parse(try __a.str(0)))"),
                      "the throwing native call must be `try …`; got:\n\(src)")
        // Wrapped in do/catch → .error (the demote channel).
        XCTAssertTrue(src.contains("do {"), src)
        XCTAssertTrue(src.contains("} catch {"), src)
        XCTAssertTrue(src.contains("return .error(\"\\(error)\")"),
                      "a thrown error must map to a tagged .error; got:\n\(src)")
        XCTAssertTrue(parses(src), src)
    }

    /// A throwing VOID symbol: the call statement is `try …` inside the do-block, then
    /// `return .nilValue`; a throw still routes to `.error`.
    func testThrowingVoidSymbol() {
        let sym = RoutedSymbol(
            id: 502, canonicalSignature: "MyApp.Disk.write(String)->Void",
            callTemplate: "Disk.write(\u{1}0\u{1})", argTypes: [.string], returnType: .void,
            isThrowing: true)
        let src = HostBridgeThunkGenerator().generate(symbols: [sym]).fileContents
        XCTAssertTrue(src.contains("do {"), src)
        XCTAssertTrue(src.contains("try Disk.write(try __a.str(0))"), src)
        XCTAssertTrue(src.contains("return .nilValue"), src)
        XCTAssertTrue(src.contains("} catch {"), src)
        XCTAssertTrue(parses(src), src)
    }

    /// A throwing HANDLE-returning constructor: the `try` is INSIDE the retain, all inside the
    /// do/catch, so a failed construction demotes rather than retaining a bad object.
    func testThrowingHandleConstructor() {
        let sym = RoutedSymbol(
            id: 503, canonicalSignature: "MyApp.makeThing(String)->Thing",
            callTemplate: "makeThing(\u{1}0\u{1})", argTypes: [.string],
            returnType: .handle("Thing"), isThrowing: true)
        let src = HostBridgeThunkGenerator().generate(symbols: [sym]).fileContents
        XCTAssertTrue(src.contains("return .handle(__a.retain(try makeThing(try __a.str(0))))"), src)
        XCTAssertTrue(src.contains("do {") && src.contains("} catch {"), src)
        XCTAssertTrue(parses(src), src)
    }

    /// Non-throwing symbols are UNCHANGED (no `do/catch`, no `try` on the native call) —
    /// the throwing support is purely additive.
    func testNonThrowingSymbolUnchanged() {
        let src = HostBridgeThunkGenerator().generate(symbols: [discountSymbol()]).fileContents
        XCTAssertFalse(src.contains("do {"), "a non-throwing symbol must NOT be wrapped in do/catch")
        XCTAssertTrue(src.contains("return .f64(Double(PricingEngine.discount("),
                      "the non-throwing encode is unchanged; got:\n\(src)")
    }

    /// REAL-SDK target: a throwing symbol wraps in do/catch and the native call is `try …`,
    /// against the `bridge.register(...)` ABI. (The realSDK shim's `register` closure is
    /// already `throws`, so the wrapper compiles.)
    func testThrowingSymbolRealSDKTarget() {
        let sym = RoutedSymbol(
            id: 504, canonicalSignature: "MyApp.Parser.parse(String)->Int",
            callTemplate: "Parser.parse(\u{1}0\u{1})", argTypes: [.string], returnType: .int,
            isThrowing: true)
        let gen = HostBridgeThunkGenerator(target: .realSDK)
        let r = gen.generate(symbols: [sym])
        let src = r.fileContents
        XCTAssertTrue(src.contains("bridge.register(id: 504"), src)
        XCTAssertTrue(src.contains("Int64(try Parser.parse(try args.string(0)))"), src)
        XCTAssertTrue(src.contains("} catch {") && src.contains("return .error(\"\\(error)\")"), src)
        XCTAssertTrue(parses(src), src)
    }

    /// The compiles-or-demote net proves a throwing thunk against the app's real `throws` type
    /// (host swiftc). The stub's `Parser.parse` is `throws`, so the generated `try …` thunk
    /// type-checks.
    func testThrowingThunkTypechecksAgainstAppStub() throws {
        guard BridgeThunkValidator.hostSwiftc() != nil else { throw XCTSkip("no host swiftc") }
        let throwingStub = """
        enum ParseError: Error { case bad }
        enum Parser {
            static func parse(_ s: String) throws -> Int {
                guard let v = Int(s) else { throw ParseError.bad }
                return v
            }
        }
        """
        let sym = RoutedSymbol(
            id: 505, canonicalSignature: "MyApp.Parser.parse(String)->Int",
            callTemplate: "Parser.parse(\u{1}0\u{1})", argTypes: [.string], returnType: .int,
            isThrowing: true)
        let r = HostBridgeThunkGenerator().generate(symbols: [sym],
                                                    validate: BridgeThunkValidator(),
                                                    appTypeStub: throwingStub)
        XCTAssertEqual(r.emittedSymbolIDs, [505],
                       "a throwing thunk that type-checks against the real throws fn must be kept; demoted=\(r.demoted)")
        XCTAssertTrue(r.demoted.isEmpty, "no demote for a correct throwing thunk; got \(r.demoted)")
    }

    // MARK: - (5) ASYNC native symbols (DESIGN §8.7 — registerAsync + the pump)

    /// An `async` symbol registers via `registerAsync` + an `async` closure; the native call is
    /// `await …`. (No `do/catch` unless ALSO throwing.)
    func testAsyncSymbolUsesRegisterAsyncAndAwait() {
        let sym = RoutedSymbol(
            id: 601,
            canonicalSignature: "MyApp.Store.products()->Int",
            callTemplate: "Store.products()",
            argTypes: [],
            returnType: .int,
            isAsync: true)
        let src = HostBridgeThunkGenerator().generate(symbols: [sym]).fileContents
        XCTAssertTrue(src.contains("PatchHostBridge.registerAsync(id: 601"),
                      "an async symbol must register via registerAsync; got:\n\(src)")
        // The closure is `async throws` and the native call is `await …`.
        XCTAssertTrue(src.contains("async throws -> PatchBridgeValue"), src)
        XCTAssertTrue(src.contains("return .i64(Int64(await Store.products()))"),
                      "the async native call must be `await …`; got:\n\(src)")
        XCTAssertFalse(src.contains("do {"), "a non-throwing async symbol is not wrapped in do/catch")
        XCTAssertTrue(parses(src), src)
    }

    /// An `async throws` symbol: `registerAsync` + an `async throws` closure + `await try …`
    /// wrapped in do/catch → .error. Both halves compose.
    func testAsyncThrowingSymbol() {
        let sym = RoutedSymbol(
            id: 602,
            canonicalSignature: "MyApp.Loader.load(String)->Int",
            callTemplate: "Loader.load(\u{1}0\u{1})",
            argTypes: [.string],
            returnType: .int,
            isThrowing: true,
            isAsync: true)
        let src = HostBridgeThunkGenerator().generate(symbols: [sym]).fileContents
        XCTAssertTrue(src.contains("registerAsync(id: 602"), src)
        // `try await …` (canonical Swift order) inside do/catch.
        XCTAssertTrue(src.contains("Int64(try await Loader.load(try __a.str(0)))"),
                      "async throws must be `try await …`; got:\n\(src)")
        XCTAssertTrue(src.contains("do {") && src.contains("} catch {"), src)
        XCTAssertTrue(src.contains("return .error(\"\\(error)\")"), src)
        XCTAssertTrue(parses(src), src)
    }

    /// REAL-SDK async target: `bridge.registerAsync(...)` + `(args, handles) async throws`.
    func testAsyncSymbolRealSDKTarget() {
        let sym = RoutedSymbol(
            id: 603, canonicalSignature: "MyApp.Store.products()->Int",
            callTemplate: "Store.products()", argTypes: [], returnType: .int, isAsync: true)
        let src = HostBridgeThunkGenerator(target: .realSDK).generate(symbols: [sym]).fileContents
        XCTAssertTrue(src.contains("bridge.registerAsync(id: 603"), src)
        XCTAssertTrue(src.contains("(args: ArgReader, handles: HandleTable) async throws -> TLVValue"), src)
        XCTAssertTrue(src.contains("await Store.products()"), src)
        XCTAssertTrue(parses(src), src)
    }

    /// The compiles-or-demote net proves an async thunk against the app's real `async` symbol.
    func testAsyncThunkTypechecksAgainstAppStub() throws {
        guard BridgeThunkValidator.hostSwiftc() != nil else { throw XCTSkip("no host swiftc") }
        let asyncStub = """
        enum Store {
            static func products() async -> Int { 42 }
        }
        """
        let sym = RoutedSymbol(
            id: 604, canonicalSignature: "MyApp.Store.products()->Int",
            callTemplate: "Store.products()", argTypes: [], returnType: .int, isAsync: true)
        let r = HostBridgeThunkGenerator().generate(symbols: [sym],
                                                    validate: BridgeThunkValidator(),
                                                    appTypeStub: asyncStub)
        XCTAssertEqual(r.emittedSymbolIDs, [604],
                       "an async thunk that type-checks against the real async fn must be kept; demoted=\(r.demoted)")
        XCTAssertTrue(r.demoted.isEmpty, "no demote for a correct async thunk; got \(r.demoted)")
    }

    /// A negative-id symbol (the production ids are `truncate32(SHA256(...))`, often negative)
    /// produces a valid probe + region — the file-name/probe-fn munging handles the sign.
    func testNegativeSymbolIdHandled() {
        let sym = RoutedSymbol(
            id: -123456,
            canonicalSignature: "MyApp.f(Int)->Int",
            callTemplate: "f(\u{1}0\u{1})", argTypes: [.int], returnType: .int)
        let r = HostBridgeThunkGenerator().generate(symbols: [sym])
        XCTAssertEqual(r.emittedSymbolIDs, [-123456])
        XCTAssertTrue(parses(r.fileContents), r.fileContents)
        let probe = HostBridgeThunkGenerator.standaloneProbe(
            region: HostBridgeThunkGenerator.renderRegistration(sym), sym: sym, appTypeStub: "")
        XCTAssertTrue(parses(probe), probe)
    }
}
