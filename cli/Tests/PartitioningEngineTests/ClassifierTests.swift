// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PartitioningEngine

final class ClassifierTests: XCTestCase {
    private func classify(_ source: String) -> [String: ClassificationResult] {
        let records = SwiftParserEngine().parse(source: source, file: Fixtures.fixtureURL)
        let g = CallGraphBuilder().build(from: records)
        return Classifier().classifyAll(g)
    }

    private func result(_ results: [String: ClassificationResult], containing fragment: String) -> ClassificationResult? {
        results.first { $0.key.contains(fragment) }?.value
    }

    func testPureMathIsWasmEligible() {
        let r = classify(Fixtures.sample)
        XCTAssertEqual(result(r, containing: "Calc.addNumbers")?.classification, .wasmEligible)
        XCTAssertEqual(result(r, containing: "Calc.multiply")?.classification, .wasmEligible)
        // square calls only multiply (pure) → still eligible (transitive purity)
        XCTAssertEqual(result(r, containing: "Calc.square")?.classification, .wasmEligible)
    }

    func testURLSessionIsBridged_zeroFalseNegative() {
        let r = classify(Fixtures.sample)
        let fetch = result(r, containing: "NetworkService.fetch")
        XCTAssertNotNil(fetch)
        // SAFETY: a URLSession-touching function must NEVER be wasmEligible.
        XCTAssertNotEqual(fetch?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE VIOLATION: URLSession function classified wasmEligible")
        // Day-2: URLSession is bridgeable (host bridge) → bridged, runs OTA.
        XCTAssertEqual(fetch?.classification, .bridged,
                       "URLSession-only function should be bridged (Day-2). Got: \(String(describing: fetch?.classification))")
    }

    func testUserDefaultsIsNotWasmEligible() {
        let r = classify(Fixtures.sample)
        let save = result(r, containing: "Prefs.saveCount")
        XCTAssertNotNil(save)
        XCTAssertNotEqual(save?.classification, .wasmEligible,
                          "UserDefaults function must not be wasmEligible")
    }

    func testBridgeableOnlyFunctionIsBridged() {
        let r = classify(Fixtures.sample)
        // Mixer.process: pure sum(...) + scaling logic + UserDefaults write.
        // Day-2: UserDefaults is bridgeable and there is no mustStayNative symbol,
        // so the whole function runs OTA via the host bridge → bridged.
        let process = result(r, containing: "Mixer.process")
        XCTAssertNotNil(process)
        XCTAssertNotEqual(process?.classification, .native,
                          "process should be OTA-updatable (bridged), not native")
        XCTAssertEqual(process?.classification, .bridged,
                       "process uses only bridgeable UserDefaults + pure logic → bridged. Got: \(String(describing: process?.classification)) reasons: \(process?.reasons ?? [])")
    }

    func testForcedNativeNeverWasmEligible() {
        let src = """
        import Foundation
        class T: NSObject {
            @objc func handler() { let x = compute(); print(x) }
            func compute() -> Int { return 1 + 1 }
        }
        """
        let r = classify(src)
        let handler = result(r, containing: "handler")
        XCTAssertEqual(handler?.classification, .native, "@objc must classify native")
    }

    // MARK: - OrderService plan fixture

    func testOrderServiceClassificationsMatchPlan() {
        let r = classify(Fixtures.orderService)

        // Pure functions → wasmEligible
        XCTAssertEqual(result(r, containing: "calculateOrderTotal")?.classification, .wasmEligible,
                       "calculateOrderTotal should be wasmEligible")
        XCTAssertEqual(result(r, containing: "applyPromoCode")?.classification, .wasmEligible)
        XCTAssertEqual(result(r, containing: "validateOrder")?.classification, .wasmEligible)
        XCTAssertEqual(result(r, containing: "loyaltyMultiplier")?.classification, .wasmEligible)
        XCTAssertEqual(result(r, containing: "determineTier")?.classification, .wasmEligible)
        XCTAssertEqual(result(r, containing: "calculateDeliveryDate")?.classification, .wasmEligible)

        // Day-2: submitOrder uses URLSession (bridgeable) + JSONDecoder (wasm-safe)
        // + pure helpers, with NO mustStayNative symbol → bridged (runs OTA).
        let submit = result(r, containing: "submitOrder")
        XCTAssertNotEqual(submit?.classification, .wasmEligible, "ZERO-FALSE-NEGATIVE: submitOrder")
        XCTAssertEqual(submit?.classification, .bridged,
                       "submitOrder should be bridged (URLSession+JSON bridgeable). Got \(String(describing: submit?.classification))")

        // Day-2: processLoyaltyPoints uses UserDefaults + NotificationCenter
        // (both bridgeable) + pure logic → bridged.
        let loyalty = result(r, containing: "processLoyaltyPoints")
        XCTAssertNotEqual(loyalty?.classification, .wasmEligible, "ZERO-FALSE-NEGATIVE: processLoyaltyPoints")
        XCTAssertEqual(loyalty?.classification, .bridged,
                       "processLoyaltyPoints should be bridged. Got \(String(describing: loyalty?.classification))")
    }

    // MARK: - Day-2 three-tier behaviour

    /// A function that mixes a genuine mustStayNative API (FileManager) with
    /// separable pure/wasm-safe logic must classify `mixed` (auto-split candidate).
    func testMustStayNativeMixedWithPureIsMixed() {
        let src = """
        import Foundation
        struct Exporter {
            func export(_ items: [Int], to path: String) -> Int {
                let total = items.reduce(0, +)
                let json = try! JSONEncoder().encode(items)
                FileManager.default.createFile(atPath: path, contents: json)
                return total
            }
            func describe(_ items: [Int]) -> String { return "\\(items.count)" }
        }
        """
        let r = classify(src)
        let export = result(r, containing: "Exporter.export")
        XCTAssertNotEqual(export?.classification, .wasmEligible, "ZERO-FALSE-NEGATIVE: FileManager")
        XCTAssertEqual(export?.classification, .mixed,
                       "FileManager + pure/JSON logic should be mixed. Got \(String(describing: export?.classification)) reasons: \(export?.reasons ?? [])")
    }

    /// WASM-safe Foundation value types (Decimal/Date/Codable/UUID) must NOT
    /// pull a function native — it stays wasmEligible (Day-2 COVERAGE>SIZE).
    func testWasmSafeFoundationStaysEligible() {
        let src = """
        import Foundation
        struct Money {
            func tax(_ cents: Int) -> Decimal {
                let amount = Decimal(cents) / Decimal(100)
                let when = Date(timeIntervalSince1970: 0)
                var cal = Calendar(identifier: .gregorian)
                let y = cal.component(.year, from: when)
                let id = UUID().uuidString
                return amount * Decimal(0.0875) + Decimal(y) + Decimal(id.count)
            }
        }
        """
        let r = classify(src)
        let tax = result(r, containing: "Money.tax")
        XCTAssertEqual(tax?.classification, .wasmEligible,
                       "Decimal/Date/Calendar/UUID are WASM-safe Foundation → wasmEligible. Got \(String(describing: tax?.classification)) reasons: \(tax?.reasons ?? [])")
    }

    /// A genuine mustStayNative symbol with no separable logic stays native.
    func testCoreDataOnlyIsNative() {
        let src = """
        import CoreData
        struct Store {
            func save(_ ctx: NSManagedObjectContext) {
                try? ctx.save()
            }
        }
        """
        let r = classify(src)
        let save = result(r, containing: "Store.save")
        XCTAssertEqual(save?.classification, .native,
                       "CoreData-only function should be native. Got \(String(describing: save?.classification))")
    }

    /// Pure helper on an ObservableObject class (not touching @Published) must be
    /// eligible (Day-2: ObservableObject no longer blanket-forces native).
    func testObservableObjectPureHelperIsEligible() {
        let src = """
        import Foundation
        import Combine
        class VM: ObservableObject {
            @Published var count: Int = 0
            func increment() { count += 1 }            // touches @Published → native
            func formatted(_ n: Int) -> String { return "\\(n * 2)" }  // pure → eligible
        }
        """
        let r = classify(src)
        let inc = result(r, containing: "VM.increment")
        let fmt = result(r, containing: "VM.formatted")
        XCTAssertEqual(inc?.classification, .native,
                       "increment touches @Published count → native. Got \(String(describing: inc?.classification))")
        XCTAssertEqual(fmt?.classification, .wasmEligible,
                       "pure helper on an ObservableObject should be wasmEligible. Got \(String(describing: fmt?.classification)) reasons: \(fmt?.reasons ?? [])")
    }

    func testSwiftUIViewIsNative_zeroFalseNegative() {
        let src = """
        import SwiftUI
        struct ProfileView: View {
            @State private var name: String = ""
            var body: some View {
                VStack { Button("Save") { editProfile() } }
            }
            func editProfile() { name = name.uppercased() }
        }
        """
        let r = classify(src)
        // Every member of a View-conforming type must be native — including the
        // otherwise-pure-looking editProfile() (it mutates @State via the type).
        XCTAssertEqual(result(r, containing: ".body")?.classification, .native)
        XCTAssertEqual(result(r, containing: "editProfile")?.classification, .native,
                       "ZERO-FALSE-NEGATIVE: a View method must never be wasmEligible")
    }

    func testRegistryHasSubstantialCoverage() {
        XCTAssertGreaterThanOrEqual(NativeRegistry.standard.count, 250,
                                    "Registry should have a few hundred entries")
    }

    // MARK: - Embedded-compatibility axis (T0 / T1 / T2 tier)

    /// Pure integer logic is embeddable → T0 (the default, smallest tier).
    func testPureMathIsEmbeddableT0() {
        let r = classify(Fixtures.sample)
        let add = result(r, containing: "Calc.addNumbers")
        XCTAssertEqual(add?.classification, .wasmEligible)
        XCTAssertEqual(add?.tier, .t0Embedded,
                       "pure math should be T0 Embedded. blockers: \(add?.tierBlockers ?? [])")
    }

    /// Foundation VALUE needs satisfied by host bridges (Decimal/Date/JSON) stay
    /// T0 — they are routed through `patch_host.*`, not `import Foundation`.
    func testDecimalViaBridgeIsEmbeddableT0() {
        let src = """
        struct Money {
            func total(_ cents: Int, _ taxBP: Int) -> Int {
                let d = Decimal(cents)
                let tax = d * Decimal(taxBP)
                return Int(truncating: tax as NSDecimalNumber)
            }
        }
        """
        let r = classify(src)
        let total = result(r, containing: "Money.total")
        XCTAssertEqual(total?.classification, .wasmEligible)
        XCTAssertEqual(total?.tier, .t0Embedded,
                       "Decimal is a bridged Foundation value → still T0. blockers: \(total?.tierBlockers ?? [])")
        XCTAssertTrue(total?.tierBlockers.isEmpty ?? false)
    }

    /// In-module Codable / JSONDecoder synthesis is embedded-incompatible AND
    /// needs Foundation → must fall back to T2 (not T0).
    func testCodableSynthesisFallsBackToT2() {
        let src = """
        struct Parser {
            func decode(_ data: [UInt8]) -> Int {
                let d = try! JSONDecoder().decode([Int].self, from: Data(data))
                return d.count
            }
        }
        """
        let r = classify(src)
        let dec = result(r, containing: "Parser.decode")
        // Still WASM-eligible (JSONDecoder is wasm-safe Foundation under full SDK),
        // but the embedded axis must demote it OUT of T0.
        XCTAssertNotEqual(dec?.tier, .t0Embedded,
                          "JSONDecoder synthesis must not be T0. tier: \(String(describing: dec?.tier))")
        XCTAssertEqual(dec?.tier, .t2Foundation,
                       "JSONDecoder needs in-module Foundation → T2. blockers: \(dec?.tierBlockers ?? [])")
    }

    /// `any Protocol` existentials are rejected by Embedded but compile under the
    /// stdlib runtime → T1 (no Foundation needed). The signature-only existential
    /// is caught by the source-text oracle the BuildPipeline uses
    /// (`selectStartTier`/`analyzeSource`) — the ground-truth grep — even though
    /// the per-function reference axis (best-effort) may not surface it from the
    /// signature alone. (Either way the compile-oracle escalation is the final net.)
    func testExistentialFallsBackToT1ViaSourceOracle() {
        let src = """
        protocol Shape { func area() -> Int }
        struct Geo {
            func describe(_ s: any Shape) -> Int { return s.area() }
        }
        """
        let verdict = EmbeddedCompatibility().analyzeSource(src)
        XCTAssertNotEqual(verdict.tier, .t0Embedded,
                          "`any Shape` must not be T0. tier: \(verdict.tier)")
        XCTAssertEqual(verdict.tier, .t1Stdlib,
                       "existential needs stdlib runtime, no Foundation → T1. blockers: \(verdict.blockers)")
    }

    /// `Mirror` reflection has no embedded support and needs Foundation/runtime
    /// metadata → T2.
    func testMirrorFallsBackToT2() {
        let src = """
        struct Inspector {
            func fields(_ x: Int) -> Int {
                let m = Mirror(reflecting: x)
                return m.children.count
            }
        }
        """
        let r = classify(src)
        let f = result(r, containing: "Inspector.fields")
        XCTAssertNotEqual(f?.tier, .t0Embedded, "Mirror must not be T0")
        XCTAssertEqual(f?.tier, .t2Foundation,
                       "Mirror → T2. blockers: \(f?.tierBlockers ?? [])")
    }

    /// The embedded tier aggregates over the CLOSURE: a pure caller of a
    /// JSON-decoding helper inherits the helper's T2 tier (one module = one tier).
    func testEmbeddedTierPropagatesOverClosure() {
        let src = """
        struct Pipeline {
            func parse(_ data: [UInt8]) -> Int {
                return try! JSONDecoder().decode([Int].self, from: Data(data)).count
            }
            func run(_ data: [UInt8]) -> Int {
                let n = parse(data)   // pure caller, but callee needs Foundation
                return n * 2
            }
        }
        """
        let r = classify(src)
        let run = result(r, containing: "Pipeline.run")
        XCTAssertEqual(run?.tier, .t2Foundation,
                       "tier must aggregate the callee's T2 over the closure. tier: \(String(describing: run?.tier)) blockers: \(run?.tierBlockers ?? [])")
    }

    /// PackagingTier ordering: T0 < T1 < T2 (so `max`/`<` pick the larger when
    /// aggregating, and `selectStartTier` picks the smallest viable start).
    func testPackagingTierOrdering() {
        XCTAssertLessThan(PackagingTier.t0Embedded, .t1Stdlib)
        XCTAssertLessThan(PackagingTier.t1Stdlib, .t2Foundation)
        XCTAssertEqual(max(PackagingTier.t0Embedded, .t2Foundation), .t2Foundation)
        XCTAssertEqual(PackagingTier.t0Embedded.swiftSDK, "swift-6.3.2-RELEASE_wasm-embedded")
        XCTAssertEqual(PackagingTier.t2Foundation.swiftSDK, "swift-6.3.2-RELEASE_wasm")
    }

    // MARK: - EmbeddedCompatibility source-text analyzer (the grep oracle)

    func testEmbeddedCompatSourceAnalyzer() {
        let compat = EmbeddedCompatibility()
        // Pure / Decimal-via-bridge → T0.
        XCTAssertEqual(compat.analyzeSource("func f(_ x: Int) -> Int { x * 2 }").tier, .t0Embedded)
        XCTAssertEqual(compat.analyzeSource("let d = Decimal(5) + Decimal(3)").tier, .t0Embedded)
        // Existential → T1.
        XCTAssertEqual(compat.analyzeSource("func g(_ s: any P) { }").tier, .t1Stdlib)
        // Codable / Mirror / NSRegularExpression → T2.
        XCTAssertEqual(compat.analyzeSource("let e = JSONEncoder()").tier, .t2Foundation)
        XCTAssertEqual(compat.analyzeSource("let m = Mirror(reflecting: 1)").tier, .t2Foundation)
        XCTAssertEqual(compat.analyzeSource("let r = NSRegularExpression()").tier, .t2Foundation)
    }

    /// Over-promotion regression: a blocker token that appears ONLY inside a comment
    /// or a string literal is NOT real code and must NOT promote the module's tier.
    /// Before the fix, a single such false hit ballooned a trivial pure module from
    /// T0 (~tens of KB) to T2 (~60 MB full Foundation).
    func testBlockerTokensInCommentsAndStringsDoNotPromoteTier() {
        let compat = EmbeddedCompatibility()
        // Block comment mentioning blocker tokens → still pure → T0.
        let blockComment = """
        /* This helper does NOT use Codable or Mirror — pure integer math. */
        func add(_ a: Int, _ b: Int) -> Int { a + b }
        """
        XCTAssertEqual(compat.analyzeSource(blockComment).tier, .t0Embedded,
                       "a blocker token inside a block comment must not force T2")
        // Line comment mentioning a blocker token → T0.
        let lineComment = "// configure Locale here later\nfunc f() -> Int { 1 }"
        XCTAssertEqual(compat.analyzeSource(lineComment).tier, .t0Embedded)
        // String literal containing a blocker token → T0 (it's a label, not a type).
        let strLit = "func label() -> String { \"choose a Locale\" }"
        XCTAssertEqual(compat.analyzeSource(strLit).tier, .t0Embedded,
                       "a blocker word inside a string literal must not force T2")
        // Multiline string literal with a blocker token → T0.
        let multiline = "func help() -> String { \"\"\"\nUses Codable internally? No.\n\"\"\" }"
        XCTAssertEqual(compat.analyzeSource(multiline).tier, .t0Embedded)
        // SANITY: a REAL blocker in actual code still promotes (no false negative).
        XCTAssertEqual(compat.analyzeSource("let m = Mirror(reflecting: 1)").tier, .t2Foundation)
        XCTAssertEqual(
            compat.analyzeSource("/* doc */ let e = JSONEncoder() // real").tier, .t2Foundation,
            "a real blocker outside comments/strings must still promote")
    }

    // MARK: - Day-3 safety: levers must never leak native / view-state

    /// Lever 2c: a pure helper inside a SwiftUI `View` must NOT escape to
    /// wasmEligible. Every member of a blanket-native type stays native, no
    /// matter how pure its body looks. (Zero-false-negative on the View lever.)
    /// P0 (per-member View forcing): a `View`-conforming type is NO LONGER
    /// blanket-forced native. Pure value members (design tokens, helpers) are freed
    /// to classify on their merits, while `body` and any member reading reactive
    /// state stay native. This is the SwiftUI value-lift coverage lever; safety is
    /// preserved by the unchanged downstream checks (see the safety tests below).
    func testViewTypePureValueMembersAreFreed() {
        let src = """
        import SwiftUI
        struct CardView: View {
            @State private var n = 0
            // body is the view DSL → native (also reads @State).
            var body: some View { Text("\\(n)") }
            // Pure value members in a View are now FREED → wasmEligible.
            func doubled(_ x: Int) -> Int { return x * 2 }
            static func tripled(_ x: Int) -> Int { return x * 3 }
            var computedPure: Int { return 42 }
        }
        """
        let r = classify(src)
        // body stays native (view DSL + reads @State).
        XCTAssertEqual(result(r, containing: ".body")?.classification, .native,
                       "body is view DSL and reads @State → must be native")
        // Pure value members are freed to wasmEligible.
        for frag in ["doubled", "tripled", "computedPure"] {
            XCTAssertEqual(result(r, containing: frag)?.classification, .wasmEligible,
                           "P0: pure value member \(frag) in a View should be freed to wasmEligible")
        }
    }

    /// Lever 2a + host-projection: a method that READS value-typed reactive state
    /// (`@State`/`@Binding`/`@Published`) is NEVER `wasmEligible`/`bridged`. A pure,
    /// read-only access of a VALUE-MARSHALLABLE reactive prop is host-projected →
    /// `mixed` (the native shell projects the value into the WASM fragment, which
    /// never touches reactive state). A MUTATION of reactive state stays native.
    func testReactiveStateAccessNeverEligibleNorBridged() {
        let src = """
        import SwiftUI
        import Combine
        final class Model: ObservableObject {
            @Published var items: [Int] = []
            @State var flag = false
            // READ-ONLY over a value-marshallable @Published prop ([Int]) → the
            // host-projection lift routes this to `mixed`. Still NOT wasmEligible/
            // bridged (a pure fragment never touches reactive state).
            func total() -> Int { return items.reduce(0, +) }
            // MUTATES @State storage (`flag.toggle()`) → must stay native (a write
            // can't be host-projected; also `flag` has no annotation, so it isn't a
            // projection candidate anyway).
            func toggle() -> Bool { flag.toggle(); return flag }
            // pure sibling → eligible
            func pureAdd(_ a: Int, _ b: Int) -> Int { return a + b }
        }
        """
        let r = classify(src)
        // ZERO-FALSE-NEGATIVE invariant (the point of this test): a reactive read
        // is NEVER wasmEligible nor bridged. Host-projection routes the pure
        // value-typed read to `mixed`, which still honours the invariant.
        let total = result(r, containing: "Model.total")?.classification
        XCTAssertNotEqual(total, .wasmEligible, "reading @Published storage must never be wasmEligible")
        XCTAssertNotEqual(total, .bridged, "reading @Published storage must never be bridged")
        XCTAssertEqual(total, .mixed,
                       "pure read of a value-marshallable @Published prop → host-projected (mixed)")
        XCTAssertEqual(result(r, containing: "Model.toggle")?.classification, .native,
                       "MUTATING @State storage must be native (a write can't be projected)")
        XCTAssertEqual(result(r, containing: "Model.pureAdd")?.classification, .wasmEligible,
                       "pure sibling should remain wasmEligible")
    }

    /// Lever 2b safety: a function whose closure touches a mustStayNative symbol
    /// must NEVER be classified `bridged` (bridged = ONLY bridgeable + pure).
    func testMustStayNativeNeverBridged() {
        let src = """
        import CoreData
        import Foundation
        struct Repo {
            // CoreData ctx.save (tier-1) + UserDefaults (bridgeable) → must NOT be bridged.
            func dump(_ ctx: NSManagedObjectContext) {
                UserDefaults.standard.set(1, forKey: "k")
                try? ctx.save()
            }
        }
        """
        let r = classify(src)
        let dump = result(r, containing: "Repo.dump")
        XCTAssertNotEqual(dump?.classification, .wasmEligible, "ZERO-FALSE-NEGATIVE")
        XCTAssertNotEqual(dump?.classification, .bridged,
                          "a CoreData (mustStayNative) touch must never be bridged. Got \(String(describing: dump?.classification))")
    }

    /// Lever 2a (native→mixed): a function that CALLS a forced-native helper but
    /// itself does only liftable work becomes a split candidate (mixed), and must
    /// never be wasmEligible. A forced-native callee must not poison the caller
    /// into the un-splittable `forced native` bucket.
    func testCallerOfForcedNativeIsMixedNotForcedNative() {
        let src = """
        import Foundation
        struct Worker {
            @objc func nativeBit() { }   // forced native (cannot lift)
            func run(_ items: [Int]) -> Int {
                let total = items.reduce(0, +)   // liftable
                let scaled = total * 2           // liftable
                nativeBit()                      // native call stays in shell
                return scaled
            }
        }
        """
        let r = classify(src)
        let run = result(r, containing: "Worker.run")
        XCTAssertNotEqual(run?.classification, .wasmEligible, "ZERO-FALSE-NEGATIVE: calls forced-native helper")
        XCTAssertEqual(run?.classification, .mixed,
                       "caller of a forced-native helper with separable pure work should be a split candidate. Got \(String(describing: run?.classification)) reasons \(run?.reasons ?? [])")
        // The @objc helper itself stays native.
        XCTAssertEqual(result(r, containing: "Worker.nativeBit")?.classification, .native)
    }

    /// Perf-cap safety: an over-ambiguous call (more than the fan-out cap)
    /// routes to the forced-native sink, so the caller is never wasmEligible.
    func testOverAmbiguousDispatchNeverEligible() {
        // Build many same-named methods (> cap) plus a caller of that name.
        var src = "struct Caller { func go() { ambiguous() } }\n"
        let cap = CallGraphBuilder.dynamicDispatchFanoutCap
        for i in 0...(cap + 5) {
            src += "struct T\(i) { func ambiguous() { } }\n"
        }
        let records = SwiftParserEngine().parse(source: src, file: Fixtures.fixtureURL)
        let g = CallGraphBuilder().build(from: records)
        let res = Classifier().classifyAll(g)
        let go = res.first { $0.key.contains("Caller.go") }?.value
        XCTAssertNotNil(go)
        XCTAssertNotEqual(go?.classification, .wasmEligible,
                          "ZERO-FALSE-NEGATIVE: over-ambiguous dispatch must not be wasmEligible")
        // The synthetic sink must never appear as a reported function.
        XCTAssertFalse(res.keys.contains(CallGraphBuilder.ambiguousSinkID) == false &&
                       g.nodes.contains(CallGraphBuilder.ambiguousSinkID) == false,
                       "sink should exist as a graph node")
    }

    /// The synthetic ambiguous-dispatch sink must be excluded from the coverage
    /// report (it is an analysis artifact, not a real corpus function).
    func testSyntheticSinkExcludedFromReport() {
        var src = "struct Caller { func go() { ambiguous() } }\n"
        let cap = CallGraphBuilder.dynamicDispatchFanoutCap
        for i in 0...(cap + 5) { src += "struct T\(i) { func ambiguous() { } }\n" }
        let records = SwiftParserEngine().parse(source: src, file: Fixtures.fixtureURL)
        let report = PartitioningEngine().analyze(records: records, fileCount: 1)
        XCTAssertFalse(report.results.contains { $0.functionID == CallGraphBuilder.ambiguousSinkID },
                       "synthetic sink must not appear in the coverage report")
    }

    /// `setValue(_:forHTTPHeaderField:)` on URLRequest must NOT force native
    /// (it is not KVC). With only bridgeable URLRequest touches the function is
    /// bridged — but KVC `setValue(_:forKey:)` must still force native.
    func testHTTPHeaderSetValueNotForcedNative() {
        let src = """
        import Foundation
        struct Req {
            func build(_ url: URL) -> URLRequest {
                var r = URLRequest(url: url)
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                return r
            }
        }
        struct KVC {
            func poke(_ o: NSObject) { o.setValue(1, forKey: "x") }
        }
        """
        let r = classify(src)
        let build = result(r, containing: "Req.build")
        XCTAssertNotEqual(build?.classification, .native,
                          "URLRequest.setValue(_:forHTTPHeaderField:) must not force native. Got \(String(describing: build?.classification))")
        // KVC setValue(_:forKey:) must still be native.
        XCTAssertEqual(result(r, containing: "KVC.poke")?.classification, .native,
                       "KVC setValue(_:forKey:) must stay native")
    }

    // MARK: - Robustness: ClosureFlagSolver index build must not TRAP

    /// `ClosureFlagSolver.solve` builds a node→index map via
    /// `Dictionary(uniquingKeysWith:)` over `Array(graph.nodes)`. `graph.nodes`
    /// is a `Set`, so the keys are unique by construction and the de-dup guard
    /// can never fire today — but the guard makes the line trap-proof against any
    /// future change to the node source. This drives the solver through that line
    /// directly and asserts correct flag propagation: a node that reaches a
    /// forced-native callee inherits `forcedNative`; an isolated pure node does not.
    func testClosureFlagSolverBuildsIndexAndPropagates() {
        // a -> b (forced-native), c isolated (pure).
        let nodes: Set<String> = ["a", "b", "c"]
        let url = URL(fileURLWithPath: "/tmp/PatchFixtures/Solver.swift")
        func rec(_ id: String, forcesNative: Bool) -> FunctionRecord {
            FunctionRecord(id: id, kind: .function, sourceFile: url,
                           startLine: 1, endLine: 1, bodyReferences: [],
                           forcesNative: forcesNative)
        }
        let graph = CallGraph(
            nodes: nodes,
            edges: ["a": ["b"]],
            reverseEdges: ["b": ["a"]],
            records: ["a": rec("a", forcesNative: false),
                      "b": rec("b", forcesNative: true),
                      "c": rec("c", forcesNative: false)],
            unresolvedReferences: [:]
        )
        var bLocal = Classifier.TierFlags()
        bLocal.localForcedNative = true
        bLocal.forcedNative = true
        let local: [String: Classifier.TierFlags] = ["b": bLocal]

        // Must not crash; must propagate b's forced-native up to a, but not to c.
        let solved = ClosureFlagSolver.solve(graph: graph, local: local)
        XCTAssertTrue(solved["b"]?.forcedNative == true, "b is locally forced-native")
        XCTAssertTrue(solved["a"]?.forcedNative == true, "a reaches b → inherits forced-native")
        XCTAssertFalse(solved["c"]?.forcedNative == true, "c is isolated/pure → not forced-native")
    }
}
