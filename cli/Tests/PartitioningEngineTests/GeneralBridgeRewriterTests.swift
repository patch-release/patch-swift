// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator

/// LEVER #2 (part B) — the GENERALIZED "call what's already linked" rewriter.
///
/// Covers the CLASSIFIER (routable-call gate, DESIGN §4.1/§6) + the guest-sequence
/// emission (the `have()`-preflight + `patch_host.call` + `.error`-demote fallback
/// shape). These are pure (no WASM toolchain): they assert the classifier routes
/// only PROVABLY-safe call sites, the emitted guest sequence has the demote-safe
/// shape, and the DEMOTE-SAFETY contract holds (inout / closure / generic / unsafe /
/// unknown-type calls are kept native).
final class GeneralBridgeRewriterTests: XCTestCase {

    // Convenience builder for the common scalar free-fn candidate.
    private func scalarFreeCall(
        receiver: String = "PricingEngine",
        function: String = "discount",
        nativeExpr: String,
        signature: String,
        args: [GeneralBridgeRewriter.Candidate.Arg],
        returnType: String,
        symbolResolvable: Bool = true,
        hasInoutArg: Bool = false,
        hasEscapingClosureArg: Bool = false,
        isUnspecializedGeneric: Bool = false,
        isVariadic: Bool = false,
        touchesCrossThreadObject: Bool = false
    ) -> GeneralBridgeRewriter.Candidate {
        GeneralBridgeRewriter.Candidate(
            kind: .freeOrStatic, receiver: receiver, function: function,
            nativeExpr: nativeExpr, canonicalSignature: signature,
            args: args, returnType: returnType, returnIsHandle: false,
            hasInoutArg: hasInoutArg, hasEscapingClosureArg: hasEscapingClosureArg,
            isUnspecializedGeneric: isUnspecializedGeneric, isVariadic: isVariadic,
            touchesCrossThreadObject: touchesCrossThreadObject,
            symbolResolvable: symbolResolvable)
    }

    // MARK: - (1) A routable SCALAR free-fn call routes + emits the guest sequence

    func testScalarFreeFunctionRoutes() {
        let cand = scalarFreeCall(
            nativeExpr: "PricingEngine.discount(subtotal: s, tier: t)",
            signature: "MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double",
            args: [
                .init(expr: "s", swiftType: "Double"),
                .init(expr: "t", swiftType: "Int"),
            ],
            returnType: "Double")

        let rw = GeneralBridgeRewriter()
        guard case .route(let site) = rw.classify(cand) else {
            return XCTFail("a scalar free-fn call must route")
        }
        XCTAssertEqual(site.args.map(\.tag), [.f64, .i64])
        XCTAssertEqual(site.returnTag, .f64)

        // The emitted guest sequence: have()-preflight + call + .error-demote fallback.
        let seq = rw.emitGuestSequence(site)
        XCTAssertTrue(seq.contains("_patchBridgeHave("), "must pre-flight the symbol via have(): \n\(seq)")
        XCTAssertTrue(seq.contains("== 0 { return PricingEngine.discount(subtotal: s, tier: t) }"),
                      "have()==0 must fall back to the VERBATIM native call:\n\(seq)")
        XCTAssertTrue(seq.contains("_patchBridgeCall("), "must call the generic dispatch import:\n\(seq)")
        XCTAssertTrue(seq.contains("__pb.f64(Double(s))"), "first arg encodes as f64:\n\(seq)")
        XCTAssertTrue(seq.contains("__pb.i64(Int64(t))"), "second arg encodes as i64:\n\(seq)")
        XCTAssertTrue(seq.contains("case .f64(let __v): return __v"), "decode the f64 result:\n\(seq)")
        XCTAssertTrue(seq.contains("default: return PricingEngine.discount(subtotal: s, tier: t)"),
                      "a tagged .error / unexpected result must demote to the native call:\n\(seq)")
        // The closure is typed to the return type so it slots into any expression.
        XCTAssertTrue(seq.contains("{ () -> Double in"), "the sequence is a return-typed closure:\n\(seq)")
    }

    func testBareFreeFunctionWithNoArgsRoutes() {
        let cand = GeneralBridgeRewriter.Candidate(
            kind: .freeOrStatic, receiver: "", function: "featureFlag",
            nativeExpr: "featureFlag()",
            canonicalSignature: "MyApp.featureFlag()->Bool",
            args: [], returnType: "Bool")
        let rw = GeneralBridgeRewriter()
        guard case .route(let site) = rw.classify(cand) else {
            return XCTFail("a no-arg scalar free fn must route")
        }
        XCTAssertEqual(site.returnTag, .bool)
        let seq = rw.emitGuestSequence(site)
        // No arg-encode statements, but still the full preflight/call/decode shape.
        XCTAssertFalse(seq.contains("__pb.i64"), "no args → no encodes")
        XCTAssertTrue(seq.contains("case .bool(let __v): return __v"))
    }

    // MARK: - (2) The Foundation stateless quartet routes

    func testFoundationOpenURLRoutes() {
        let cand = GeneralBridgeRewriter.Candidate(
            kind: .foundationStateless, receiver: "UIApplication.shared", function: "open",
            nativeExpr: "UIApplication.shared.open(url)",
            canonicalSignature: "UIKit.UIApplication.open(URL)->Bool",
            args: [.init(expr: "url.absoluteString", swiftType: "String")],
            returnType: "Bool")
        let rw = GeneralBridgeRewriter()
        guard case .route(let site) = rw.classify(cand) else {
            return XCTFail("openURL (string arg) must route")
        }
        XCTAssertEqual(site.args.map(\.tag), [.string])
        let seq = rw.emitGuestSequence(site)
        XCTAssertTrue(seq.contains("__pb.string(url.absoluteString)"))
        XCTAssertTrue(seq.contains("default: return UIApplication.shared.open(url)"))
    }

    func testFoundationNotificationPostRoutes() {
        let cand = GeneralBridgeRewriter.Candidate(
            kind: .foundationStateless, receiver: "NotificationCenter.default", function: "post",
            nativeExpr: "NotificationCenter.default.post(name: n.rawValue, object: nil)",
            canonicalSignature: "Foundation.NotificationCenter.post(name:String)->Void",
            args: [.init(expr: "n.rawValue", swiftType: "String")],
            returnType: "Void")
        let rw = GeneralBridgeRewriter()
        guard case .route(let site) = rw.classify(cand) else {
            return XCTFail("NotificationCenter.post (name only) must route")
        }
        XCTAssertEqual(site.returnTag, .nilValue)
        let seq = rw.emitGuestSequence(site)
        XCTAssertTrue(seq.contains("{ () -> Void in"), "a void return types the closure Void:\n\(seq)")
        XCTAssertTrue(seq.contains("case .nilValue: return ()"), "void decodes to nilValue:\n\(seq)")
    }

    func testFoundationFileExistsRoutes() {
        let cand = GeneralBridgeRewriter.Candidate(
            kind: .foundationStateless, receiver: "FileManager.default", function: "fileExists",
            nativeExpr: "FileManager.default.fileExists(atPath: p)",
            canonicalSignature: "Foundation.FileManager.fileExists(atPath:String)->Bool",
            args: [.init(expr: "p", swiftType: "String")],
            returnType: "Bool")
        let rw = GeneralBridgeRewriter()
        guard case .route = rw.classify(cand) else {
            return XCTFail("FileManager.fileExists must route")
        }
    }

    // MARK: - (3) DEMOTE-SAFETY — provably-unsafe call sites stay native

    func testInoutArgDemotes() {
        // Structural flag form.
        let cand = scalarFreeCall(
            nativeExpr: "mutate(&x)",
            signature: "MyApp.mutate(inout Int)->Void",
            args: [.init(expr: "&x", swiftType: "Int")],
            returnType: "Void", hasInoutArg: true)
        assertDemote(cand, .inoutArgument)
    }

    func testInoutTokenInExprDemotes() {
        // Even without the structural flag, the raw `inout ` token demotes.
        let cand = scalarFreeCall(
            nativeExpr: "apply(transform: inout state)",
            signature: "MyApp.apply(transform:Int)->Void",
            args: [.init(expr: "inout state", swiftType: "Int")],
            returnType: "Void")
        assertDemote(cand, .inoutArgument)
    }

    func testEscapingClosureArgDemotes() {
        let cand = scalarFreeCall(
            nativeExpr: "schedule(after: 1.0, handler)",
            signature: "MyApp.schedule(after:Double,handler:()->Void)->Void",
            args: [.init(expr: "1.0", swiftType: "Double")],
            returnType: "Void", hasEscapingClosureArg: true)
        assertDemote(cand, .escapingClosureArg)
    }

    func testUnspecializedGenericDemotes() {
        // No `.self`/`#selector`/unsafe token in the exprs — this exercises the
        // structural `isUnspecializedGeneric` gate specifically (a `.self`
        // metatype token would otherwise be caught first by the raw pre-filter,
        // which is also a correct demote, just a different reason).
        let cand = scalarFreeCall(
            nativeExpr: "box(value)",
            signature: "MyApp.box<T>(T)->Box<T>",
            args: [.init(expr: "value", swiftType: "T")],
            returnType: "Box", isUnspecializedGeneric: true)
        assertDemote(cand, .unspecializedGeneric)
    }

    func testUnsafePointerArgDemotes() {
        let cand = scalarFreeCall(
            nativeExpr: "blit(UnsafePointer(buf), count: n)",
            signature: "MyApp.blit(UnsafePointer<UInt8>,count:Int)->Void",
            args: [
                .init(expr: "UnsafePointer(buf)", swiftType: "UnsafePointer<UInt8>"),
                .init(expr: "n", swiftType: "Int"),
            ],
            returnType: "Void")
        // The raw-token pre-filter catches `UnsafePointer` in the expr.
        assertDemote(cand, .unsafePointer)
    }

    func testWithUnsafeBytesDemotes() {
        let cand = scalarFreeCall(
            nativeExpr: "data.withUnsafeBytes { hash($0) }",
            signature: "MyApp.hash(UnsafeRawBufferPointer)->Int",
            args: [.init(expr: "data.withUnsafeBytes { $0 }", swiftType: "Int")],
            returnType: "Int")
        assertDemote(cand, .unsafePointer)
    }

    func testMetatypeArgDemotes() {
        let cand = scalarFreeCall(
            nativeExpr: "register(MyType.self)",
            signature: "MyApp.register(Any.Type)->Void",
            args: [.init(expr: "MyType.self", swiftType: "Any.Type")],
            returnType: "Void")
        assertDemote(cand, .metatypeArg)
    }

    func testUnknownReferenceArgTypeDemotes() {
        // A by-reference arg the guest would have to construct itself and that
        // is NOT a handle → unmarshallable.
        let cand = scalarFreeCall(
            nativeExpr: "render(in: context)",
            signature: "MyApp.render(in:CGContext)->Void",
            args: [.init(expr: "context", swiftType: "CGContext", isHandle: false)],
            returnType: "Void")
        assertDemote(cand, .unmarshallableArgType)
    }

    func testUnknownReturnTypeDemotes() {
        let cand = scalarFreeCall(
            nativeExpr: "makeView()",
            signature: "MyApp.makeView()->UIView",
            args: [],
            returnType: "UIView", symbolResolvable: true)
        assertDemote(cand, .unmarshallableReturn)
    }

    func testVariadicDemotes() {
        let cand = scalarFreeCall(
            nativeExpr: "sum(1, 2, 3)",
            signature: "MyApp.sum(Int...)->Int",
            args: [.init(expr: "1", swiftType: "Int")],
            returnType: "Int", isVariadic: true)
        assertDemote(cand, .variadic)
    }

    func testCrossThreadObjectDemotes() {
        let cand = scalarFreeCall(
            nativeExpr: "view.layoutIfNeeded()",
            signature: "UIKit.UIView.layoutIfNeeded()->Void",
            args: [],
            returnType: "Void", touchesCrossThreadObject: true)
        assertDemote(cand, .crossThreadOrActor)
    }

    func testUnresolvableSymbolDemotes() {
        // A symbol the target build did NOT generate a thunk for (not in the
        // routed set) — `have()` would return 0; the classifier refuses up front.
        let cand = scalarFreeCall(
            nativeExpr: "PricingEngine.discount(s, t)",
            signature: "MyApp.PricingEngine.discount(Double,Int)->Double",
            args: [
                .init(expr: "s", swiftType: "Double"),
                .init(expr: "t", swiftType: "Int"),
            ],
            returnType: "Double", symbolResolvable: false)
        assertDemote(cand, .unresolvableSymbol)
    }

    func testSelectorTokenDemotes() {
        let cand = scalarFreeCall(
            nativeExpr: "perform(#selector(foo))",
            signature: "MyApp.perform(Selector)->Void",
            args: [.init(expr: "#selector(foo)", swiftType: "Selector")],
            returnType: "Void")
        assertDemote(cand, .unresolvableSymbol)
    }

    // A HANDLE arg from a prior routed call IS marshallable (the proven §3.2 path).
    func testHandleArgRoutes() {
        let cand = GeneralBridgeRewriter.Candidate(
            kind: .freeOrStatic, receiver: "formatter", function: "string",
            nativeExpr: "formatter.string(from: amount)",
            canonicalSignature: "Foundation.NumberFormatter.string(from:Double)->String",
            args: [
                .init(expr: "__h0", swiftType: "NumberFormatter", isHandle: true),
                .init(expr: "amount", swiftType: "Double"),
            ],
            returnType: "String")
        let rw = GeneralBridgeRewriter()
        guard case .route(let site) = rw.classify(cand) else {
            return XCTFail("a handle arg + scalar must route (§3.2)")
        }
        XCTAssertEqual(site.args.map(\.tag), [.handle, .f64])
        let seq = rw.emitGuestSequence(site)
        XCTAssertTrue(seq.contains("__pb.handle(__h0)"), "the handle marshals as a handle TLV:\n\(seq)")
    }

    // MARK: - The codeMask-aware token guard does NOT fire inside a string literal

    func testStringLiteralInArgDoesNotFalseDemote() {
        // An arg whose VALUE is the literal "inout please" must not trip the
        // inout demote — the token is inside a string, not code.
        let cand = scalarFreeCall(
            nativeExpr: #"log(prefix: "inout please")"#,
            signature: "MyApp.log(prefix:String)->Void",
            args: [.init(expr: #""inout please""#, swiftType: "String")],
            returnType: "Void")
        let rw = GeneralBridgeRewriter()
        guard case .route = rw.classify(cand) else {
            return XCTFail("an `inout` substring inside a STRING LITERAL must not demote")
        }
    }

    // MARK: - The FusionRewriter hook (the integration seam)

    func testFusionRewriterHookRoutesAndDemotes() {
        let route = scalarFreeCall(
            nativeExpr: "PricingEngine.discount(s, t)",
            signature: "MyApp.PricingEngine.discount(Double,Int)->Double",
            args: [
                .init(expr: "s", swiftType: "Double"),
                .init(expr: "t", swiftType: "Int"),
            ],
            returnType: "Double")
        let seq = FusionRewriter().generalBridgeSequence(for: route)
        XCTAssertNotNil(seq, "the hook must emit a sequence for a routable site")
        XCTAssertTrue(seq?.contains("_patchBridgeCall(") ?? false)

        let demote = scalarFreeCall(
            nativeExpr: "mutate(&x)",
            signature: "MyApp.mutate(inout Int)->Void",
            args: [.init(expr: "&x", swiftType: "Int")],
            returnType: "Void", hasInoutArg: true)
        XCTAssertNil(FusionRewriter().generalBridgeSequence(for: demote),
                     "the hook must return nil (keep native) on a demote verdict")
    }

    // MARK: - helpers

    private func assertDemote(_ cand: GeneralBridgeRewriter.Candidate,
                              _ expected: GeneralBridgeRewriter.DemoteReason,
                              file: StaticString = #filePath, line: UInt = #line) {
        let rw = GeneralBridgeRewriter()
        switch rw.classify(cand) {
        case .demote(let r):
            XCTAssertEqual(r, expected, "wrong demote reason", file: file, line: line)
        case .route:
            XCTFail("expected demote (\(expected)) but the call ROUTED — demote-safety violated",
                    file: file, line: line)
        }
    }
}
