// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator

/// LEVER #2 (part B) — the CALL-SITE EXTRACTOR (the rewriter's FRONT-END).
///
/// `HostBridgeCallExtractor` walks a forced-native / mixed function's body and
/// produces `GeneralBridgeRewriter.Candidate`s. These tests assert:
///   - the extracted candidates' arg tags / structural flags / handle markers
///     for each call shape (scalar free fn, Foundation stateless, instance method);
///   - the DEMOTE-ON-DOUBT discipline: an unknown-from-syntax arg type is marked
///     `unresolvedType` (never guessed), and an inout/closure/generic/unsafe/
///     metatype/selector call is flagged so the classifier demotes;
///   - the HANDLE chain: a value-producing call whose result feeds a later call →
///     the later call's arg is recognised as a handle;
///   - end-to-end: routing the extracted candidates THROUGH the real
///     `GeneralBridgeRewriter.classify` confirms the routable ones pass + the
///     unsafe ones demote (the fail-closed net is the same one production uses).
final class HostBridgeCallExtractorTests: XCTestCase {

    private let rw = GeneralBridgeRewriter()

    // Extract candidates from a whole-function source string (seeds param types from
    // the signature, layers engine return hints, walks the body in source order).
    private func extract(_ source: String,
                         hints: [String: String] = [:]) -> [GeneralBridgeRewriter.Candidate] {
        HostBridgeCallExtractor().extract(fromSource: source, returnTypeHints: hints)
    }

    // MARK: - (1) A scalar free-fn call → routable candidate with correct arg tags

    func testScalarFreeFunctionExtractsCorrectArgTags() {
        let src = """
        func compute(s: Double, t: Int) -> Double {
            let result = PricingEngine.discount(subtotal: s, tier: t)
            return result
        }
        """
        // The engine knows discount returns Double; supply that hint.
        let cands = extract(src, hints: ["PricingEngine.discount": "Double"])
        // The interesting candidate is the discount call.
        guard let c = cands.first(where: { $0.function == "discount" }) else {
            return XCTFail("the discount call must be extracted; got \(cands.map(\.function))")
        }
        XCTAssertEqual(c.kind, .freeOrStatic)
        XCTAssertEqual(c.receiver, "PricingEngine")
        XCTAssertEqual(c.args.map(\.swiftType), ["Double", "Int"], "arg types inferred from the typed params")
        XCTAssertEqual(c.returnType, "Double")
        // Routes through the REAL classifier with the right wire tags.
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("a scalar free-fn call must route")
        }
        XCTAssertEqual(site.args.map(\.tag), [.f64, .i64])
        XCTAssertEqual(site.returnTag, .f64)
    }

    func testLiteralArgsInferScalarTypes() {
        let src = """
        func f() {
            _ = Calc.add(1, 2.5, true, "x")
        }
        """
        let cands = extract(src, hints: ["Calc.add": "Int"])
        guard let c = cands.first(where: { $0.function == "add" }) else {
            return XCTFail("expected the add call")
        }
        XCTAssertEqual(c.args.map(\.swiftType), ["Int", "Double", "Bool", "String"])
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("all-literal scalar args must route")
        }
        XCTAssertEqual(site.args.map(\.tag), [.i64, .f64, .bool, .string])
    }

    func testScalarConversionArgInfersResultType() {
        // `Double(x)` infers Double regardless of x's type.
        let src = """
        func f(n: Int) {
            _ = Calc.scale(Double(n))
        }
        """
        let cands = extract(src, hints: ["Calc.scale": "Double"])
        guard let c = cands.first(where: { $0.function == "scale" }) else {
            return XCTFail("expected the scale call")
        }
        XCTAssertEqual(c.args.map(\.swiftType), ["Double"])
        guard case .route = rw.classify(c) else {
            return XCTFail("a scalar-conversion arg must route")
        }
    }

    // MARK: - (2) Foundation stateless calls → candidates that route

    func testNotificationCenterPostExtractsAndRoutes() {
        // The single-named-arg form (the survey's routable shape).
        let src = """
        func notify(n: String) {
            NotificationCenter.default.post(name: n)
        }
        """
        let cands = extract(src)
        guard let c = cands.first(where: { $0.function == "post" }) else {
            return XCTFail("the post call must be extracted")
        }
        XCTAssertEqual(c.kind, .foundationStateless)
        XCTAssertEqual(c.args.map(\.swiftType), ["String"])
        XCTAssertEqual(c.returnType, "Void", "post's Void return comes from the framework table")
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("NotificationCenter.post (string name) must route")
        }
        XCTAssertEqual(site.returnTag, .nilValue)
    }

    func testNilLiteralArgIsUnresolvedAndDemotes() {
        // `object: nil` — a bare `nil` literal is `nil` of an UNKNOWN type; we cannot
        // type it from syntax (nil of what?), so it is marked unresolved → demote.
        // This is the honest demote-on-doubt behaviour: the real `post(name:object:)`
        // routes ONLY once the engine supplies the param types (a wrong nil-type would
        // mis-marshal).
        let src = """
        func notify(n: String) {
            NotificationCenter.default.post(name: n, object: nil)
        }
        """
        let cands = extract(src)
        guard let c = cands.first(where: { $0.function == "post" }) else {
            return XCTFail("the post call must be extracted")
        }
        XCTAssertEqual(c.args.last?.swiftType, HostBridgeCallExtractor.unresolvedType,
                       "a bare nil literal must be marked unresolved, not guessed")
        assertDemotes(c, .unmarshallableArgType)
    }

    func testFileManagerFileExistsExtractsAndRoutes() {
        let src = """
        func check(p: String) -> Bool {
            return FileManager.default.fileExists(atPath: p)
        }
        """
        let cands = extract(src)
        guard let c = cands.first(where: { $0.function == "fileExists" }) else {
            return XCTFail("the fileExists call must be extracted")
        }
        XCTAssertEqual(c.kind, .foundationStateless)
        XCTAssertEqual(c.args.map(\.swiftType), ["String"])
        XCTAssertEqual(c.returnType, "Bool", "fileExists Bool return from the framework table")
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("FileManager.fileExists must route")
        }
        XCTAssertEqual(site.args.map(\.tag), [.string])
        XCTAssertEqual(site.returnTag, .bool)
    }

    // MARK: - (3) DEMOTE-SAFETY — provably-unsafe call sites are flagged → demote

    func testInoutArgIsFlaggedAndDemotes() {
        let src = """
        func f(x: Int) {
            mutate(&x)
        }
        """
        let cands = extract(src, hints: ["mutate": "Void"])
        guard let c = cands.first(where: { $0.function == "mutate" }) else {
            return XCTFail("expected the mutate call")
        }
        XCTAssertTrue(c.hasInoutArg, "the `&x` inout sigil must set hasInoutArg")
        assertDemotes(c, .inoutArgument)
    }

    func testClosureArgIsFlaggedAndDemotes() {
        // A trailing closure arg → escaping-closure hazard.
        let src = """
        func f() {
            schedule(after: 1.0) { doThing() }
        }
        """
        let cands = extract(src, hints: ["schedule": "Void"])
        guard let c = cands.first(where: { $0.function == "schedule" }) else {
            return XCTFail("expected the schedule call")
        }
        XCTAssertTrue(c.hasEscapingClosureArg, "a trailing closure must set hasEscapingClosureArg")
        assertDemotes(c, .escapingClosureArg)
    }

    func testInParenClosureArgIsFlaggedAndDemotes() {
        let src = """
        func f() {
            run(handler: { doThing() })
        }
        """
        let cands = extract(src, hints: ["run": "Void"])
        guard let c = cands.first(where: { $0.function == "run" }) else {
            return XCTFail("expected the run call")
        }
        XCTAssertTrue(c.hasEscapingClosureArg)
        assertDemotes(c, .escapingClosureArg)
    }

    func testUnsafePointerArgDemotesViaRawTokenGate() {
        let src = """
        func f(buf: UnsafePointer<UInt8>, n: Int) {
            blit(UnsafePointer(buf), count: n)
        }
        """
        let cands = extract(src, hints: ["blit": "Void"])
        guard let c = cands.first(where: { $0.function == "blit" }) else {
            return XCTFail("expected the blit call")
        }
        // The raw-token pre-filter in the classifier catches `UnsafePointer` in the expr.
        assertDemotes(c, .unsafePointer)
    }

    func testMetatypeArgDemotesViaRawTokenGate() {
        let src = """
        func f() {
            register(MyType.self)
        }
        """
        let cands = extract(src, hints: ["register": "Void"])
        guard let c = cands.first(where: { $0.function == "register" }) else {
            return XCTFail("expected the register call")
        }
        assertDemotes(c, .metatypeArg)
    }

    func testSelectorArgDemotesViaRawTokenGate() {
        let src = """
        func f() {
            wire(#selector(tap))
        }
        """
        let cands = extract(src, hints: ["wire": "Void"])
        guard let c = cands.first(where: { $0.function == "wire" }) else {
            return XCTFail("expected the wire call")
        }
        assertDemotes(c, .unresolvableSymbol)
    }

    // MARK: - (4) Unknown-from-syntax arg type → marked unresolved (NOT guessed)

    func testUnknownArgTypeIsMarkedUnresolvedAndDemotes() {
        // `context` has no resolvable type from syntax (not a param, not a literal).
        let src = """
        func f() {
            render(in: context)
        }
        """
        let cands = extract(src, hints: ["render": "Void"])
        guard let c = cands.first(where: { $0.function == "render" }) else {
            return XCTFail("expected the render call")
        }
        XCTAssertEqual(c.args.map(\.swiftType), [HostBridgeCallExtractor.unresolvedType],
                       "an unresolvable arg type must be marked unresolved, not guessed")
        // The classifier demotes an unresolved arg type.
        assertDemotes(c, .unmarshallableArgType)
    }

    func testMemberAccessArgIsUnresolvedNotGuessed() {
        // `x.rawValue` is *commonly* String/Int but we cannot PROVE which → unresolved.
        let src = """
        func f(e: Foo) {
            log(value: e.rawValue)
        }
        """
        let cands = extract(src, hints: ["log": "Void"])
        guard let c = cands.first(where: { $0.function == "log" }) else {
            return XCTFail("expected the log call")
        }
        XCTAssertEqual(c.args.map(\.swiftType), [HostBridgeCallExtractor.unresolvedType],
                       ".rawValue must NOT be guessed as String/Int")
        assertDemotes(c, .unmarshallableArgType)
    }

    func testUnknownReturnTypeDemotes() {
        // No hint, not a framework member → the return is unresolved → demote.
        let src = """
        func f(s: Double) {
            _ = AppMath.transform(s)
        }
        """
        let cands = extract(src)   // NO hint supplied
        guard let c = cands.first(where: { $0.function == "transform" }) else {
            return XCTFail("expected the transform call")
        }
        XCTAssertEqual(c.returnType, HostBridgeCallExtractor.unresolvedType,
                       "no hint + non-framework member → return unresolved")
        assertDemotes(c, .unmarshallableReturn)
    }

    // MARK: - (5) HANDLE chain — a value-producing call's result feeds a later call

    func testHandleProducingChainIsDetected() {
        // `formatter` is bound to a constructor of a non-by-value reference type →
        // it becomes a handle name; the later `formatter.string(from:)` arg-0 receiver
        // use is the handle. We pass the handle EXPLICITLY as an arg here to exercise
        // the §3.2 consumer recognition (the receiver-as-arg modelling).
        let src = """
        func money(amount: Double) -> String {
            let formatter = NumberFormatter()
            return convert(formatter, amount)
        }
        """
        // convert returns String (engine hint).
        let cands = extract(src, hints: ["convert": "String"])
        guard let c = cands.first(where: { $0.function == "convert" }) else {
            return XCTFail("expected the convert call; got \(cands.map(\.function))")
        }
        // The FIRST arg (`formatter`) must be recognised as a handle (bound to a
        // prior reference-producing call); the second (`amount`) is a by-value Double.
        XCTAssertEqual(c.args.count, 2)
        XCTAssertTrue(c.args[0].isHandle, "the formatter arg must be a handle (NumberFormatter ref)")
        XCTAssertFalse(c.args[1].isHandle, "the amount arg is a by-value Double")
        XCTAssertEqual(c.args[1].swiftType, "Double")
        // Routes: a handle arg + a scalar is the proven §3.2 shape.
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("a handle arg + scalar must route")
        }
        XCTAssertEqual(site.args.map(\.tag), [.handle, .f64])
    }

    func testScalarBindingIsNotAHandle() {
        // A local bound to a LITERAL is a by-value scalar, never a handle.
        let src = """
        func f() {
            let n = 42
            _ = Calc.use(n)
        }
        """
        let cands = extract(src, hints: ["Calc.use": "Int"])
        guard let c = cands.first(where: { $0.function == "use" }) else {
            return XCTFail("expected the use call")
        }
        XCTAssertEqual(c.args.count, 1)
        XCTAssertFalse(c.args[0].isHandle, "a literal-bound local is by-value, not a handle")
        XCTAssertEqual(c.args[0].swiftType, "Int")
        guard case .route = rw.classify(c) else {
            return XCTFail("a scalar-bound local arg must route")
        }
    }

    // MARK: - (6) End-to-end: a whole body's mixed call set classifies correctly

    func testMixedBodyRoutesSafeOnesAndDemotesUnsafeOnes() {
        let src = """
        func process(p: String, x: Int) -> Bool {
            let exists = FileManager.default.fileExists(atPath: p)
            mutate(&x)
            render(in: ctx)
            return exists
        }
        """
        let cands = extract(src, hints: ["mutate": "Void", "render": "Void"])
        var routed = 0, demoted = 0
        for c in cands {
            switch rw.classify(c) {
            case .route: routed += 1
            case .demote: demoted += 1
            }
        }
        // fileExists routes; mutate (inout) + render (unresolved arg) demote.
        XCTAssertGreaterThanOrEqual(routed, 1, "fileExists must route")
        XCTAssertGreaterThanOrEqual(demoted, 2, "the inout + unresolved-arg calls must demote")
    }

    // MARK: - (6b) Canonical signature flows through the ABI core's rules

    func testCanonicalSignatureIsModuleQualifiedAndLabelled() {
        let src = """
        func compute(s: Double, t: Int) -> Double {
            return PricingEngine.discount(subtotal: s, tier: t)
        }
        """
        let cands = HostBridgeCallExtractor(moduleName: "MyApp")
            .extract(fromSource: src, returnTypeHints: ["PricingEngine.discount": "Double"])
        guard let c = cands.first(where: { $0.function == "discount" }) else {
            return XCTFail("expected the discount call")
        }
        // The canonical signature follows the ABI core's rules: module-qualified
        // receiver, label:type params (no spaces), `->Ret`.
        XCTAssertEqual(c.canonicalSignature,
                       "MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double")
        // The same signature hashes to a stable id (round-trips through the ABI core).
        XCTAssertEqual(HostBridgeABI.hostBridgeSymbolId(c.canonicalSignature),
                       HostBridgeABI.hostBridgeSymbolId("MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double"))
    }

    func testVoidReturnOmitsTheArrowClause() {
        let src = """
        func f(p: String) {
            FileManager.default.removeItem(atPath: p)
        }
        """
        let cands = extract(src)
        guard let c = cands.first(where: { $0.function == "removeItem" }) else {
            return XCTFail("expected the removeItem call")
        }
        // removeItem → Void (framework table) → no `->` clause in the canonical sig.
        XCTAssertEqual(c.canonicalSignature,
                       "Foundation.FileManager.removeItem(atPath:String)")
    }

    func testUnspecializedGenericTypeParamArgDemotes() {
        // An arg whose only resolvable type is a bare type-parameter spelling `T`
        // (the function is generic, the call doesn't concretize it) → flagged.
        let src = """
        func box<T>(_ value: T) {
            store(value)
        }
        """
        let cands = extract(src, hints: ["store": "Void"])
        guard let c = cands.first(where: { $0.function == "store" }) else {
            return XCTFail("expected the store call")
        }
        XCTAssertTrue(c.isUnspecializedGeneric, "a bare type-param arg must flag unspecialised generic")
        assertDemotes(c, .unspecializedGeneric)
    }

    // MARK: - (7) Shapes the extractor does NOT describe (returns no candidate)

    func testImplicitBaseMemberCallProducesNoCandidate() {
        // `.success(x)` — a leading-dot enum case ctor has no receiver to qualify.
        let src = """
        func f(x: Int) {
            _ = result(.success(x))
        }
        """
        let cands = extract(src, hints: ["result": "Void"])
        // The outer `result(...)` is describable; the inner `.success(x)` is not.
        XCTAssertFalse(cands.contains(where: { $0.function == "success" }),
                       "a leading-dot member call must not produce a candidate")
    }

    // MARK: - helpers

    private func assertDemotes(_ cand: GeneralBridgeRewriter.Candidate,
                               _ expected: GeneralBridgeRewriter.DemoteReason,
                               file: StaticString = #filePath, line: UInt = #line) {
        switch rw.classify(cand) {
        case .demote(let r):
            XCTAssertEqual(r, expected, "wrong demote reason", file: file, line: line)
        case .route:
            XCTFail("expected demote (\(expected)) but the call ROUTED — demote-safety violated",
                    file: file, line: line)
        }
    }
}
