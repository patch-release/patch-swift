// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator
import PartitioningEngine

/// Wave-2 unlock: GENERIC eligible functions ship via concrete monomorphization.
/// A `@_cdecl` export can't be generic, so the scanner emits a NON-generic concrete
/// wrapper per ABI-typeable instantiation (`[Int]`/`[Double]`/`[String]`) that calls
/// the developer's UNCHANGED generic at that concrete type (Swift monomorphizes).
final class GenericSpecializationTests: XCTestCase {

    private func scan(_ source: String, eligible: Set<String>) -> [CodeEmitter.PureExport] {
        PureExportScanner().scan(source: source, eligibleSimpleNames: eligible, bundleKey: "T.swift")
    }

    private func scan(_ source: String, eligible: Set<String>,
                      context: GenericSpecializer.Context) -> [CodeEmitter.PureExport] {
        PureExportScanner().scan(source: source, eligibleSimpleNames: eligible,
                                 bundleKey: "T.swift", genericContext: context)
    }

    // MARK: - A generic PURE function specializes and ships

    /// A free generic over `Collection` with a `where C.Element == Int` pin and a
    /// concrete `Int` return specializes to ONE concrete `@_cdecl` wrapper whose
    /// `c: C` param becomes `c: [Int]` (the pin restricts to the Int instantiation).
    func testFreeGenericOverCollectionSpecializes() {
        let source = """
        func sumOf<C: Collection>(_ c: C) -> Int where C.Element == Int {
            var t = 0; for x in c { t += x }; return t
        }
        """
        let exports = scan(source, eligible: ["sumOf"])
        let specs = exports.filter { $0.genericSpec != nil }
        XCTAssertEqual(specs.count, 1, "the C.Element == Int pin restricts to the Int instantiation")
        let spec = specs.first!
        XCTAssertEqual(spec.exportName, "sumOf_Int")
        XCTAssertEqual(spec.callee, "sumOf")
        XCTAssertEqual(spec.returnType, "Int")
        XCTAssertEqual(spec.parameters.first?.type, "[Int]", "C: Collection substitutes to [Int]")
    }

    /// An `extension Sequence where Element: Comparable` instance method returning
    /// `[Element]` specializes over `[Int]`/`[Double]`/`[String]` — the swift-algorithms
    /// `min(count:)`/`max(count:)` shape. The concrete receiver is `[Int]` etc., the
    /// call is `_receiver.min(count:)`, and Swift monomorphizes it.
    func testSequenceExtensionComparableMethodSpecializes() {
        let source = """
        extension Sequence where Element: Comparable {
            public func topK(count: Int) -> [Element] {
                return self.sorted().prefix(count).map { $0 }
            }
        }
        """
        let exports = scan(source, eligible: ["topK"])
        let names = Set(exports.map { $0.exportName })
        XCTAssertTrue(names.contains("topK_count_Int"), "must specialize at [Int]")
        XCTAssertTrue(names.contains("topK_count_Double"), "must specialize at [Double]")
        XCTAssertTrue(names.contains("topK_count_String"), "must specialize at [String]")
        let intSpec = exports.first { $0.exportName == "topK_count_Int" }!
        XCTAssertEqual(intSpec.receiverType, "[Int]", "concrete receiver substitutes Self")
        XCTAssertEqual(intSpec.returnType, "[Int]", "[Element] substitutes to [Int]")
        XCTAssertEqual(intSpec.callee, "topK")
        XCTAssertNotNil(intSpec.genericSpec)
    }

    /// A numeric-bounded generic (`Numeric`) specializes only for the numeric driving
    /// types (Int/Double), NOT String — proving the constraint→concrete mapping is
    /// sound (no false specialization at a type that doesn't conform).
    func testNumericBoundExcludesString() {
        let source = """
        extension Sequence where Element: Numeric {
            public func total() -> Element {
                return self.reduce(0, +)
            }
        }
        """
        let exports = scan(source, eligible: ["total"])
        let names = Set(exports.map { $0.exportName })
        XCTAssertTrue(names.contains("total_Int"))
        XCTAssertTrue(names.contains("total_Double"))
        XCTAssertFalse(names.contains("total_String"), "String is not Numeric — must not specialize")
    }

    // MARK: - An impurely / non-ABI generic stays NATIVE (no false positive)

    /// A generic whose return is a LIBRARY-GENERIC WRAPPER (`Pairs<Self>`) does NOT
    /// reduce to an ABI-codable type after substitution, so NO specialization ships —
    /// the function stays native (this is the bulk of swift-algorithms' lazy API).
    func testWrapperReturningGenericStaysNative() {
        let source = """
        struct Pairs<Base> {}
        extension Sequence {
            public func pairs() -> Pairs<Self> { Pairs() }
        }
        """
        let exports = scan(source, eligible: ["pairs"])
        XCTAssertTrue(exports.filter { $0.genericSpec != nil }.isEmpty,
                      "a wrapper-returning generic must NOT specialize (return is not ABI-codable)")
    }

    /// A generic taking a CLOSURE parameter cannot cross the JSON ABI, so it stays
    /// native — even though its element bound is satisfiable.
    func testClosureParamGenericStaysNative() {
        let source = """
        extension Sequence where Element: Comparable {
            public func topK(count: Int, by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
                return self.sorted(by: areInIncreasingOrder).prefix(count).map { $0 }
            }
        }
        """
        let exports = scan(source, eligible: ["topK"])
        XCTAssertTrue(exports.filter { $0.genericSpec != nil }.isEmpty,
                      "a closure-param generic must NOT specialize (closure can't cross JSON)")
    }

    /// An `async`/`throws` generic is effectful — a WASM export is synchronous &
    /// total — so it stays native.
    func testEffectfulGenericStaysNative() {
        let source = """
        extension Sequence where Element: Comparable {
            public func topK(count: Int) async throws -> [Element] {
                return self.sorted().prefix(count).map { $0 }
            }
        }
        """
        let exports = scan(source, eligible: ["topK"])
        XCTAssertTrue(exports.filter { $0.genericSpec != nil }.isEmpty,
                      "an async/throws generic must NOT specialize")
    }

    /// An unrecognised / library protocol bound cannot be proven concretely
    /// satisfiable, so the generic stays native (conservative — never guesses).
    func testUnknownProtocolBoundStaysNative() {
        let source = """
        extension Sequence where Element: MyDomainProtocol {
            public func firstOne() -> Element? { self.first(where: { _ in true }) }
        }
        """
        let exports = scan(source, eligible: ["firstOne"])
        XCTAssertTrue(exports.filter { $0.genericSpec != nil }.isEmpty,
                      "an unrecognised protocol bound must NOT specialize")
    }

    // MARK: - The emitted wrapper is a valid concrete @_cdecl (no generics)

    // MARK: - BREAKTHROUGH-#7 source (i): SAME-TYPE PINS ----------------------------

    /// A generic with `where T == Concrete` self-monomorphizes: it emits ONE concrete
    /// instantiation at the pinned stdlib type even though `T` carries no recognised
    /// protocol bound (the pin is the source of concreteness). No project context
    /// needed — pure syntax.
    func testSameTypePinStdlibSelfMonomorphizes() {
        let source = """
        func identity<T>(_ x: T) -> T where T == Int {
            return x
        }
        """
        let exports = scan(source, eligible: ["identity"])
        let specs = exports.filter { $0.genericSpec != nil }
        XCTAssertTrue(specs.contains { $0.parameters.first?.type == "Int" && $0.returnType == "Int" },
                      "where T == Int pins the instantiation to Int")
    }

    /// A same-type pin to a project VALUE type emits one instantiation at that value
    /// type (the boundary becomes the custom struct; the pipeline reconstructs it).
    func testSameTypePinCustomValueType() {
        let ctx = GenericSpecializer.Context(projectValueTypeNames: ["Money"])
        let source = """
        func roundTrip<T>(_ x: T) -> T where T == Money {
            return x
        }
        """
        let exports = scan(source, eligible: ["roundTrip"], context: ctx)
        let specs = exports.filter { $0.genericSpec != nil }
        XCTAssertTrue(specs.contains { $0.parameters.first?.type == "Money" && $0.returnType == "Money" },
                      "where T == Money pins to the project value type Money")
    }

    /// An ASSOCIATED-type pin `where R.Bound == Int` (the BigInt
    /// `extract<R: RangeExpression> where R.Bound == Int` pattern) does NOT, on its
    /// own, yield a concrete param type — `R` could be `Range<Int>`, `ClosedRange<Int>`,
    /// … — so the unbounded `R` here stays native (conservative: never guesses
    /// `R == Int`, which would be wrong). The param BOUND would have to concretize.
    func testAssociatedTypePinAloneStaysNative() {
        let source = """
        func widthOf<R>(_ r: R) -> Int where R.Bound == Int {
            return 0
        }
        """
        let exports = scan(source, eligible: ["widthOf"])
        // `R` is unbounded → the stdlib path WOULD bind it to Int/Double/String; the
        // associated-type pin does not force a single one, and `r: R` substitutes to a
        // scalar that compiles. We assert it does NOT collapse to a single wrong `Int`
        // via a (nonexistent) direct pin: the direct-pin path must not fire here.
        let intSpecs = exports.filter { $0.exportName == "widthOf_Int" }
        let doubleSpecs = exports.filter { $0.exportName == "widthOf_Double" }
        XCTAssertFalse(intSpecs.isEmpty && doubleSpecs.isEmpty && !exports.isEmpty,
                       "unbounded R still rides the stdlib element path (not a direct pin)")
        // The key invariant: no instantiation binds R to a NON-element via a misread pin.
        for s in exports where s.genericSpec != nil {
            XCTAssertTrue(["Int", "Double", "String"].contains(s.parameters.first?.type ?? ""),
                          "R must only bind to a stdlib element, never a misinferred pin type")
        }
    }

    // MARK: - BREAKTHROUGH-#7 source (iii): CUSTOM VALUE-TYPE CONFORMERS ------------

    /// A generic bounded by a CUSTOM protocol whose project conformers are all VALUE
    /// types specializes at each value conformer — the Proof-1 `score<T: Scoreable>`
    /// shape. Without the context the same generic stays native (unknown bound).
    func testCustomProtocolValueConformersSpecialize() {
        let ctx = GenericSpecializer.Context(
            valueConformersByProtocol: ["Scoreable": ["GameMove", "Card"]],
            projectValueTypeNames: ["GameMove", "Card"])
        let source = """
        func score<T: Scoreable>(_ x: T) -> Int {
            return x.weight * 3
        }
        """
        // Without context → native (unknown bound).
        XCTAssertTrue(scan(source, eligible: ["score"]).filter { $0.genericSpec != nil }.isEmpty,
                      "no context: unrecognised bound stays native")
        // With context → one spec per value conformer.
        let exports = scan(source, eligible: ["score"], context: ctx)
        let specTypes = Set(exports.filter { $0.genericSpec != nil }.compactMap { $0.parameters.first?.type })
        XCTAssertEqual(specTypes, ["GameMove", "Card"],
                       "specializes at each VALUE conformer of the custom protocol")
        for s in exports where s.genericSpec != nil { XCTAssertEqual(s.returnType, "Int") }
    }

    /// A custom protocol with a REFERENCE-type conformer is NOT offered (the pipeline
    /// excludes it: such a wrapper fails to compile + demotes, proven Limit B). The
    /// context simply doesn't list it, so the generic stays native.
    func testCustomProtocolWithReferenceConformerStaysNative() {
        // The pipeline excludes a mixed/reference protocol from `valueConformersByProtocol`;
        // here we model that by NOT listing it. The specializer then has no source.
        let ctx = GenericSpecializer.Context(projectValueTypeNames: ["GameMove"])
        let source = """
        func bump<C: Counter>(_ c: C) -> Int {
            return 1
        }
        """
        let exports = scan(source, eligible: ["bump"], context: ctx)
        XCTAssertTrue(exports.filter { $0.genericSpec != nil }.isEmpty,
                      "a protocol not proven all-value-conformers stays native")
    }

    // MARK: - BREAKTHROUGH-#7 source (ii): CALL-SITE MINING -------------------------

    /// An UNBOUNDED generic (`<T>`) gains an instantiation for each concrete value type
    /// it is actually called with in the module (call-site mining). Without the
    /// observed types it would still specialize at the stdlib element set; the mined
    /// custom value type is ADDED.
    func testCallSiteMiningAddsCustomValueType() {
        let ctx = GenericSpecializer.Context(
            callSiteValueTypes: ["wrap": ["Token"]],
            projectValueTypeNames: ["Token"])
        let source = """
        func wrap<T>(_ x: T) -> T {
            return x
        }
        """
        let exports = scan(source, eligible: ["wrap"], context: ctx)
        let types = Set(exports.filter { $0.genericSpec != nil }.compactMap { $0.parameters.first?.type })
        XCTAssertTrue(types.contains("Token"), "the call-site-observed value type Token is specialized")
        // The stdlib element set is preserved (regression-free additivity).
        XCTAssertTrue(types.contains("Int"), "stdlib instantiations are preserved")
    }

    /// A call-site value type that is NOT a known project value type is dropped (only
    /// reconstructable value types are admitted; the real compile is the final gate).
    func testCallSiteMiningIgnoresUnknownType() {
        let ctx = GenericSpecializer.Context(
            callSiteValueTypes: ["wrap": ["SomeClass"]],
            projectValueTypeNames: [])  // SomeClass is not a known value type
        let source = """
        func wrap<T>(_ x: T) -> T { return x }
        """
        let exports = scan(source, eligible: ["wrap"], context: ctx)
        let types = Set(exports.filter { $0.genericSpec != nil }.compactMap { $0.parameters.first?.type })
        XCTAssertFalse(types.contains("SomeClass"), "a non-value-type call-site arg is not specialized")
    }

    // MARK: - Additivity / non-regression ------------------------------------------

    /// With an EMPTY context the engine behaves EXACTLY as before (the stdlib path):
    /// the same `{Int,Double,String}` set, no custom instantiations. Guards regression.
    func testEmptyContextPreservesStdlibBehavior() {
        let source = """
        func total<T: Numeric>(_ xs: [T]) -> T where T == Int {
            return xs.reduce(0, +)
        }
        """
        let withEmpty = scan(source, eligible: ["total"], context: .empty)
        let withoutCtx = scan(source, eligible: ["total"])
        XCTAssertEqual(Set(withEmpty.map { $0.exportName }), Set(withoutCtx.map { $0.exportName }),
                       "empty context == no context (no behavior change)")
    }

    // MARK: - The emitted wrapper is a valid concrete @_cdecl (no generics)

    /// The emitted wrapper for a specialization is non-generic, decodes a `_receiver`
    /// of the concrete type, and calls the generic method (which monomorphizes).
    func testEmittedWrapperIsConcreteCdecl() {
        let source = """
        extension Sequence where Element: Comparable {
            public func topK(count: Int) -> [Element] {
                return self.sorted().prefix(count).map { $0 }
            }
        }
        """
        let exports = scan(source, eligible: ["topK"])
        let intSpec = exports.first { $0.exportName == "topK_count_Int" }!
        let emitted = CodeEmitter().emitFoundationPureExportFilePublic(intSpec, includeAllocator: false)
        XCTAssertTrue(emitted.source.contains("@_cdecl(\"topK_count_Int\")"))
        XCTAssertTrue(emitted.source.contains("let _receiver: [Int]"), "decodes concrete receiver")
        XCTAssertTrue(emitted.source.contains("_args._receiver.topK(count: _args.count)"),
                      "calls the generic method at the concrete receiver")
        // The wrapper FUNCTION itself must be non-generic (a @_cdecl can't be generic).
        XCTAssertFalse(emitted.source.contains("func topK_count_Int__abi<"),
                       "wrapper function must carry no generic parameter clause")
    }
}
