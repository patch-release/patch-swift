// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator
@testable import Compiler

/// LEVER #2 (part B) — the CURATED KNOWN-SYMBOL TABLE (the breadth foundation).
///
/// `HostBridgeKnownSymbols` supplies CONFIDENT arg/return types for a small set of
/// high-frequency, KNOWN-bridgeable framework symbols so the extractor routes them
/// instead of demoting on imperfect syntactic type inference. These tests assert,
/// for every table entry:
///   - a sample call extracts to a routable `Candidate` that passes the REAL
///     `GeneralBridgeRewriter.classify` (no `<unresolved>` demote),
///   - the correct canonical signature + symbol-id (round-trips the ABI core),
///   - a resolver-thunk that host-`swiftc`-typechecks against a Foundation stub;
/// plus the NEGATIVE: a closure-bearing `DispatchQueue.async { … }` still demotes,
/// and the ADDITIVE-SAFETY contract (a conflicting concrete syntactic type is NOT
/// overridden — the call falls through to demote-on-doubt).
final class HostBridgeKnownSymbolsTests: XCTestCase {

    private let rw = GeneralBridgeRewriter()

    private func extract(_ source: String,
                         hints: [String: String] = [:]) -> [GeneralBridgeRewriter.Candidate] {
        HostBridgeCallExtractor().extract(fromSource: source, returnTypeHints: hints)
    }

    private func candidate(_ source: String, function: String,
                           hints: [String: String] = [:],
                           file: StaticString = #filePath, line: UInt = #line)
        -> GeneralBridgeRewriter.Candidate?
    {
        let cands = extract(source, hints: hints)
        guard let c = cands.first(where: { $0.function == function }) else {
            XCTFail("the \(function) call must be extracted; got \(cands.map(\.function))",
                    file: file, line: line)
            return nil
        }
        return c
    }

    // =======================================================================
    // MARK: - (1) Every table entry routes with the right tags + signature
    // =======================================================================
    //
    // Each of these would WITHOUT the table demote on an `<unresolved>` return
    // (a framework member's return is invisible to pure call syntax) — the table
    // is exactly what upgrades it to the confident type so it routes.

    func testNotificationCenterPostRoutesWithKnownVoidReturn() {
        // NO engine return hint — the table alone must supply post's Void return.
        let c = candidate("""
        func notify(n: String) {
            NotificationCenter.default.post(name: n)
        }
        """, function: "post")
        guard let c else { return }
        XCTAssertEqual(c.args.map(\.swiftType), ["String"])
        XCTAssertEqual(c.returnType, "Void", "the known-symbol table supplies post's Void return")
        XCTAssertEqual(c.canonicalSignature, "Foundation.NotificationCenter.post(name:String)")
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("NotificationCenter.post must route via the known-symbol table")
        }
        XCTAssertEqual(site.args.map(\.tag), [.string])
        XCTAssertEqual(site.returnTag, .nilValue)
    }

    func testUserDefaultsBoolReaderRoutesWithKnownBoolReturn() {
        // `UserDefaults.standard` is NOT in the legacy foundationStateless table, so
        // WITHOUT the known-symbol table this demotes on an unresolved Bool return.
        let c = candidate("""
        func flag(k: String) -> Bool {
            return UserDefaults.standard.bool(forKey: k)
        }
        """, function: "bool")
        guard let c else { return }
        XCTAssertEqual(c.args.map(\.swiftType), ["String"])
        XCTAssertEqual(c.returnType, "Bool", "the table supplies bool(forKey:)'s Bool return")
        XCTAssertEqual(c.canonicalSignature, "Foundation.UserDefaults.bool(forKey:String)->Bool")
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("UserDefaults.bool(forKey:) must route")
        }
        XCTAssertEqual(site.args.map(\.tag), [.string])
        XCTAssertEqual(site.returnTag, .bool)
    }

    func testUserDefaultsIntegerReaderRoutes() {
        let c = candidate("""
        func count(k: String) -> Int {
            return UserDefaults.standard.integer(forKey: k)
        }
        """, function: "integer")
        guard let c else { return }
        XCTAssertEqual(c.returnType, "Int")
        XCTAssertEqual(c.canonicalSignature, "Foundation.UserDefaults.integer(forKey:String)->Int")
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("UserDefaults.integer(forKey:) must route")
        }
        XCTAssertEqual(site.returnTag, .i64)
    }

    func testUserDefaultsDoubleReaderRoutes() {
        let c = candidate("""
        func ratio(k: String) -> Double {
            return UserDefaults.standard.double(forKey: k)
        }
        """, function: "double")
        guard let c else { return }
        XCTAssertEqual(c.returnType, "Double")
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("UserDefaults.double(forKey:) must route")
        }
        XCTAssertEqual(site.returnTag, .f64)
    }

    func testUserDefaultsBoolSetterRoutesWithVoidReturn() {
        // `set(_:forKey:)` — the syntax types arg 0 (the Bool literal); the table
        // confirms the forKey:String + Void return + picks the Bool overload.
        let c = candidate("""
        func save(k: String) {
            UserDefaults.standard.set(true, forKey: k)
        }
        """, function: "set")
        guard let c else { return }
        XCTAssertEqual(c.args.map(\.swiftType), ["Bool", "String"])
        XCTAssertEqual(c.returnType, "Void")
        XCTAssertEqual(c.canonicalSignature, "Foundation.UserDefaults.set(Bool,forKey:String)")
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("UserDefaults.set(_:forKey:) (Bool) must route")
        }
        XCTAssertEqual(site.args.map(\.tag), [.bool, .string])
        XCTAssertEqual(site.returnTag, .nilValue)
    }

    func testUserDefaultsIntSetterPicksTheIntOverload() {
        let c = candidate("""
        func save(k: String, n: Int) {
            UserDefaults.standard.set(n, forKey: k)
        }
        """, function: "set")
        guard let c else { return }
        XCTAssertEqual(c.args.map(\.swiftType), ["Int", "String"])
        XCTAssertEqual(c.canonicalSignature, "Foundation.UserDefaults.set(Int,forKey:String)")
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("UserDefaults.set(_:forKey:) (Int) must route")
        }
        XCTAssertEqual(site.args.map(\.tag), [.i64, .string])
    }

    func testFileManagerFileExistsRoutesWithKnownBoolReturn() {
        let c = candidate("""
        func check(p: String) -> Bool {
            return FileManager.default.fileExists(atPath: p)
        }
        """, function: "fileExists")
        guard let c else { return }
        XCTAssertEqual(c.returnType, "Bool")
        XCTAssertEqual(c.canonicalSignature, "Foundation.FileManager.fileExists(atPath:String)->Bool")
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("FileManager.fileExists must route")
        }
        XCTAssertEqual(site.args.map(\.tag), [.string])
        XCTAssertEqual(site.returnTag, .bool)
    }

    func testUIApplicationOpenRoutesWithKnownBoolReturn() {
        // `open(_:)` (single-arg) → Bool. The URL arg marshals as the boundary String.
        let c = candidate("""
        func go(u: String) {
            _ = UIApplication.shared.open(u)
        }
        """, function: "open")
        guard let c else { return }
        XCTAssertEqual(c.args.map(\.swiftType), ["String"])
        XCTAssertEqual(c.returnType, "Bool")
        XCTAssertEqual(c.canonicalSignature, "UIKit.UIApplication.open(String)->Bool")
        guard case .route(let site) = rw.classify(c) else {
            return XCTFail("UIApplication.shared.open(_:) must route")
        }
        XCTAssertEqual(site.args.map(\.tag), [.string])
        XCTAssertEqual(site.returnTag, .bool)
    }

    // =======================================================================
    // MARK: - (2) Every routed entry → a stable id + a thunk that TYPECHECKS
    // =======================================================================

    /// For each table entry, build its canonical signature, confirm the ABI-core id
    /// round-trips, and prove the resolver-thunk type-checks against the REAL linked
    /// framework — the build-safety net. A UIKit-module entry can only be type-checked
    /// on a host where UIKit is available (an iOS build); on a pure-macOS host `UIKit`
    /// is absent so the production net would correctly demote it THERE while keeping it
    /// on iOS. So we require every FOUNDATION-module thunk to survive the host net, and
    /// assert the framework-module entries (UIKit) parse + are routable at the candidate
    /// level (proven separately); the production iOS build type-checks them for real.
    func testEveryEntryProducesATypecheckableResolverThunk() {
        // Build one RoutedSymbol per curated entry from its declared signature.
        var symbols: [RoutedSymbol] = []
        var foundationIDs = Set<Int32>()
        for entry in HostBridgeKnownSymbols.entries {
            let canonical = canonicalSignature(for: entry)
            let id = HostBridgeABI.hostBridgeSymbolId(canonical)
            // Stable, deterministic id (round-trips through the ABI core).
            XCTAssertEqual(id, HostBridgeABI.hostBridgeSymbolId(canonical),
                           "the symbol id must be deterministic for \(canonical)")
            let sym = routedSymbol(for: entry, canonical: canonical, id: id)
            symbols.append(sym)
            // A Foundation-only entry (no extra framework import) MUST type-check on
            // the macOS host. A UIKit entry can't be host-checked here (UIKit absent).
            if entry.requiredModule == nil { foundationIDs.insert(id) }
        }
        XCTAssertEqual(symbols.count, HostBridgeKnownSymbols.entries.count)

        // The compiles-or-demote net: type-check each generated thunk in isolation
        // against the REAL linked framework (empty app stub). The CI host has the Apple
        // toolchain, so this actually runs.
        let gen = HostBridgeThunkGenerator(target: .realSDK)
        let validator = BridgeThunkValidator()
        let result = gen.generate(symbols: symbols, validate: validator, appTypeStub: "")

        // The syntax floor must always keep every entry (every template parses).
        XCTAssertTrue(result.demoted.allSatisfy { !$0.reason.contains("does not parse") },
                      "no curated thunk should fail to PARSE: \(result.demoted)")

        // Every FOUNDATION resolver thunk must survive the net — type-checking against
        // the real linked Foundation (the genuine build-safety proof). When swiftc is
        // unavailable the net is inconclusive → all kept; still passes.
        let kept = Set(result.emittedSymbolIDs)
        XCTAssertTrue(foundationIDs.isSubset(of: kept),
                      "every Foundation resolver thunk must type-check against real Foundation; "
                      + "demoted=\(result.demoted.filter { foundationIDs.contains($0.id) })")

        // The only host-net casualties may be the framework-module (UIKit) entries —
        // expected on macOS (UIKit absent). Assert nothing ELSE was dropped.
        let droppedFoundation = result.demoted.filter { foundationIDs.contains($0.id) }
        XCTAssertTrue(droppedFoundation.isEmpty,
                      "a Foundation thunk was unexpectedly demoted: \(droppedFoundation)")
    }

    // =======================================================================
    // MARK: - (3) NEGATIVE — a closure-bearing DispatchQueue.async still demotes
    // =======================================================================

    func testClosureBearingDispatchAsyncStillDemotes() {
        // The survey is explicit: most Dispatch is closure-bearing → DEMOTE (§8). The
        // table never routes around the structural closure hazard.
        let c = candidate("""
        func go() {
            DispatchQueue.main.async { doThing() }
        }
        """, function: "async")
        guard let c else { return }
        XCTAssertTrue(c.hasEscapingClosureArg, "a trailing closure must set the closure hazard")
        switch rw.classify(c) {
        case .demote(let r):
            XCTAssertEqual(r, .escapingClosureArg, "closure-bearing async must demote on the closure hazard")
        case .route:
            XCTFail("a closure-bearing DispatchQueue.async must NEVER route")
        }
        // And there is intentionally NO curated entry for it.
        XCTAssertNil(HostBridgeKnownSymbols.lookup(receiver: "DispatchQueue.main", method: "async", arity: 1),
                     "DispatchQueue.main.async must NOT be in the curated table")
    }

    // =======================================================================
    // MARK: - (4) ADDITIVE-SAFETY — the table never overrides a conflict
    // =======================================================================

    func testConflictingConcreteArgTypeIsNotOverridden() {
        // `fileExists(atPath:)` expects String; if the call passed an `Int` (a typed
        // local), the table must NOT silently re-type it to String (mis-marshal) — the
        // call doesn't fit the curated overload → demote-on-doubt keeps it native-safe.
        let resolved = HostBridgeKnownSymbols.resolve(
            HostBridgeKnownSymbols.lookup(receiver: "FileManager.default",
                                          method: "fileExists", arity: 1)!,
            syntacticArgTypes: ["Int"])
        XCTAssertNil(resolved, "a conflicting concrete arg type must NOT be upgraded")
    }

    func testUnresolvedArgTypeIsUpgradedToTheCuratedFact() {
        let entry = HostBridgeKnownSymbols.lookup(receiver: "NotificationCenter.default",
                                                  method: "post", arity: 1)!
        let resolved = HostBridgeKnownSymbols.resolve(
            entry, syntacticArgTypes: [HostBridgeKnownSymbols.unresolvedMarker])
        XCTAssertEqual(resolved?.argTypes, ["String"], "an <unresolved> arg must adopt the curated type")
        XCTAssertEqual(resolved?.returnType, "Void")
    }

    func testAgreeingConcreteArgTypeIsKept() {
        let entry = HostBridgeKnownSymbols.lookup(receiver: "UserDefaults.standard",
                                                  method: "bool", arity: 1)!
        let resolved = HostBridgeKnownSymbols.resolve(entry, syntacticArgTypes: ["String"])
        XCTAssertEqual(resolved?.argTypes, ["String"])
    }

    func testNonCuratedSymbolReturnsNoEntry() {
        XCTAssertNil(HostBridgeKnownSymbols.lookup(receiver: "PricingEngine",
                                                   method: "discount", arity: 2),
                     "an app-local symbol must NOT be in the curated framework table")
    }

    // =======================================================================
    // MARK: - (5) RECONCILIATION — HostBridgeLowering uses the boundary template
    // =======================================================================
    //
    // The build-wiring pass (`HostBridgeLowering.callTemplate`) re-spells a routed
    // call into the resolver-thunk's native call expression. For a curated
    // boundary-reconstruction symbol it MUST prefer the table's `nativeCallTemplate`
    // (the wire String → native `Notification.Name`/`URL` rebuild) — the plain
    // re-spell `post(name: <String>)` would NOT type-check against real Foundation.

    func testLoweringUsesTheBoundaryReconstructionTemplate() {
        let candidate = GeneralBridgeRewriter.Candidate(
            kind: .foundationStateless, receiver: "NotificationCenter.default",
            function: "post",
            nativeExpr: "NotificationCenter.default.post(name: n)",
            canonicalSignature: "Foundation.NotificationCenter.post(name:String)",
            args: [.init(expr: "n", swiftType: "String")],
            returnType: "Void")
        let template = HostBridgeLowering(moduleName: "MyApp").callTemplate(candidate: candidate)
        XCTAssertEqual(
            template,
            "NotificationCenter.default.post(name: Notification.Name(\u{1}0\u{1}), object: nil)",
            "the lowering pass must prefer the curated boundary-reconstruction template")
    }

    func testLoweringFallsThroughForANonCuratedSymbol() {
        // An app-local symbol has no table entry → the default plain re-spell.
        let candidate = GeneralBridgeRewriter.Candidate(
            kind: .freeOrStatic, receiver: "PricingEngine", function: "discount",
            nativeExpr: "PricingEngine.discount(subtotal: s, tier: t)",
            canonicalSignature: "MyApp.PricingEngine.discount(subtotal:Double,tier:Int)->Double",
            args: [.init(expr: "s", swiftType: "Double"), .init(expr: "t", swiftType: "Int")],
            returnType: "Double")
        let template = HostBridgeLowering(moduleName: "MyApp").callTemplate(candidate: candidate)
        XCTAssertEqual(
            template,
            "PricingEngine.discount(subtotal: \u{1}0\u{1}, tier: \u{1}1\u{1})",
            "a non-curated symbol must use the default plain re-spell")
    }

    // =======================================================================
    // MARK: - helpers — build the canonical signature + RoutedSymbol per entry
    // =======================================================================

    /// The canonical signature for a curated entry, via the ABI core's rules.
    private func canonicalSignature(for entry: HostBridgeKnownSymbols.Entry) -> String {
        let params = zip(entry.argLabels, entry.argTypes).map {
            HostBridgeABI.ResolvedCall.Param(label: $0.0, type: $0.1)
        }
        let ret: String? = (entry.returnType == "Void" || entry.returnType == "()") ? nil : entry.returnType
        return HostBridgeABI.canonicalSignature(.init(
            receiverType: entry.canonicalReceiver, name: entry.method,
            params: params, returnType: ret))
    }

    /// A resolver-thunk input (`RoutedSymbol`) for a curated entry — its real native
    /// call template + arg/return decode types + the required import.
    private func routedSymbol(for entry: HostBridgeKnownSymbols.Entry,
                              canonical: String, id: Int32) -> RoutedSymbol {
        // Prefer the entry's BOUNDARY-RECONSTRUCTION template (the thunk rebuilds a
        // Notification.Name / URL natively); else the plain re-spell
        // `<receiver>.<method>(label: \u{1}k\u{1}, …)` — the same default
        // `HostBridgeLowering.callTemplate` produces.
        let template: String
        if let native = entry.nativeCallTemplate {
            template = native
        } else {
            var parts: [String] = []
            for (k, label) in entry.argLabels.enumerated() {
                let placeholder = "\u{1}\(k)\u{1}"
                if let label, !label.isEmpty { parts.append("\(label): \(placeholder)") }
                else { parts.append(placeholder) }
            }
            template = "\(entry.receiver).\(entry.method)(\(parts.joined(separator: ", ")))"
        }
        let argTypes: [ArgType] = entry.argTypes.map(Self.argType(for:))
        let retType: ReturnType = Self.returnType(for: entry.returnType)
        return RoutedSymbol(id: id, canonicalSignature: canonical, callTemplate: template,
                            argTypes: argTypes, returnType: retType,
                            requiredImports: entry.requiredModule.map { [$0] } ?? [])
    }

    private static func argType(for swiftType: String) -> ArgType {
        switch swiftType {
        case "Int", "Int64", "Int32": return .int
        case "Double", "Float", "CGFloat": return .double
        case "Bool": return .bool
        case "String": return .string
        case "Data", "[UInt8]": return .data
        default: return .string
        }
    }

    private static func returnType(for swiftType: String) -> ReturnType {
        switch swiftType {
        case "Void", "()": return .void
        case "Int", "Int64", "Int32": return .int
        case "Double", "Float", "CGFloat": return .double
        case "Bool": return .bool
        case "String": return .string
        case "Data", "[UInt8]": return .data
        default: return .string
        }
    }
}
