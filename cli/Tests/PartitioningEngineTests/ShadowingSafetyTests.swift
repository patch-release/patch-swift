// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PartitioningEngine

/// Safety + precision tests for Agent-B's optimization-sweep changes:
///   1. project-VALUE-type shadowing (suppress framework hit for a name the
///      project redeclares as a struct/enum),
///   2. zero-false-negative guards: typealias-to-native and extension-of-native
///      must NOT shadow, attribute (`@State`) detection survives a `struct State`,
///   3. registry hardening: lock / crypto / autoreleasepool call-name detection.
///
/// Each test runs the FULL pipeline (parser → resolver → call graph → classifier)
/// the way the engine does, since shadowing is fed from the resolved symbol table.
final class ShadowingSafetyTests: XCTestCase {

    /// Analyze a set of in-memory (source, file) tuples through the real pipeline.
    private func analyze(_ sources: [(String, String)]) -> CoverageReport {
        let dir = URL(fileURLWithPath: "/tmp/PatchShadowFixtures")
        let tuples = sources.map { (src, name) in (src, dir.appendingPathComponent(name)) }
        let resolved = ProjectResolver().resolve(sources: tuples)
        let parser = SwiftParserEngine()
        var records: [FunctionRecord] = []
        for (src, file) in tuples { records += parser.parse(source: src, file: file) }
        return PartitioningEngine().analyze(records: records, fileCount: tuples.count, resolved: resolved)
    }

    private func result(_ report: CoverageReport, containing fragment: String) -> ClassificationResult? {
        report.results.first { $0.functionID.contains(fragment) }
    }

    // MARK: - 1. Value-type shadowing (the precision win)

    func testProjectValueTypeShadowsFrameworkSymbol() {
        // A project struct named `Path` (collides with SwiftUI.Path / a registry
        // mustStayNative symbol). A pure function over it must be wasmEligible.
        let src = """
        struct Path { let segments: [Int]
            func length() -> Int { segments.reduce(0, +) }
        }
        struct Index { let value: Int
            func next() -> Index { Index(value: value + 1) }
        }
        """
        let r = analyze([(src, "Geometry.swift")])
        XCTAssertEqual(result(r, containing: "Path.length")?.classification, .wasmEligible,
                       "project `struct Path` collides with framework Path but is pure → wasmEligible")
        XCTAssertEqual(result(r, containing: "Index.next")?.classification, .wasmEligible,
                       "project `struct Index` is pure → wasmEligible")
    }

    func testProjectEnumShadowsRegistryStateType() {
        // RxSwift/Alamofire-style: a project type named `State` (collides with the
        // SwiftUI `State` registry entry). A pure transition fn must be eligible.
        let src = """
        enum State { case idle, running, done
            func canTransition(to other: State) -> Bool {
                switch (self, other) { case (.idle, .running): return true; default: return false }
            }
        }
        """
        let r = analyze([(src, "Machine.swift")])
        XCTAssertEqual(result(r, containing: "State.canTransition")?.classification, .wasmEligible,
                       "project `enum State` is pure → wasmEligible (framework `State` shadowed)")
    }

    // MARK: - 2. Zero-false-negative guards

    func testTypealiasToNativeTypeDoesNotShadow() {
        // RxExample-style `typealias Image = UIImage`: `Image` MUST NOT shadow,
        // because it IS the native UIImage. A function using it stays non-eligible.
        let src = """
        typealias Image = UIImage
        struct Decompressor {
            func go(_ image: Image) -> Image { return image }
        }
        """
        let r = analyze([(src, "Img.swift")])
        let go = result(r, containing: "Decompressor.go")
        XCTAssertNotNil(go)
        XCTAssertNotEqual(go?.classification, .wasmEligible,
            "ZERO-FALSE-NEGATIVE: `typealias Image = UIImage` aliases a native type and must not be shadowed")
    }

    func testExtensionOfNativeTypeDoesNotShadow() {
        // `extension UIView { … }` registers UIView in the symbol table but must
        // NOT add it to the shadow set — a function touching UIView stays native.
        let src = """
        extension UIView { func helper() -> Int { return 1 } }
        struct Renderer {
            func draw(_ v: UIView) -> Int { return v.helper() }
        }
        """
        let r = analyze([(src, "Ext.swift")])
        let draw = result(r, containing: "Renderer.draw")
        XCTAssertNotNil(draw)
        XCTAssertNotEqual(draw?.classification, .wasmEligible,
            "ZERO-FALSE-NEGATIVE: extending UIView must not shadow the real UIView")
    }

    func testAttributeStateStillDetectedWithProjectStructState() {
        // Even when the project declares `struct State`, a SwiftUI `@State` property
        // wrapper attribute must still force native (attributes are never shadowed).
        // `@State` is handled via the parser's forced-native path, so the function
        // touching the `@State` property must classify `native`, not eligible.
        let src = """
        struct State { let n: Int }
        struct MyView {
            @State private var count = 0
            func bump() { count += 1 }
        }
        """
        let r = analyze([(src, "V.swift")])
        let bump = result(r, containing: "MyView.bump")
        XCTAssertNotNil(bump)
        XCTAssertEqual(bump?.classification, .native,
            "ZERO-FALSE-NEGATIVE: a function over a `@State` property must stay native even with a project `struct State`")
    }

    // MARK: - 3. Registry hardening (close pre-existing false negatives)

    func testWithLockCallStaysNonEligible() {
        // `someLock.withLock { pure }` — the lock TYPE lives on a property, so the
        // body only shows `.withLock`. The call name must be recognised native.
        let src = """
        struct Cache {
            let lock = OSAllocatedUnfairLock(initialState: 0)
            func read() -> Int { lock.withLock { $0 } }
        }
        """
        let r = analyze([(src, "Cache.swift")])
        let read = result(r, containing: "Cache.read")
        XCTAssertNotNil(read)
        XCTAssertNotEqual(read?.classification, .wasmEligible,
            "ZERO-FALSE-NEGATIVE: `.withLock { }` is a lock primitive and must not be wasmEligible")
    }

    func testOSUnfairLockCFunctionStaysNonEligible() {
        let src = """
        struct L {
            func crit() { os_unfair_lock_lock(p); os_unfair_lock_unlock(p) }
        }
        """
        let r = analyze([(src, "L.swift")])
        let crit = result(r, containing: "L.crit")
        XCTAssertNotEqual(crit?.classification, .wasmEligible,
            "ZERO-FALSE-NEGATIVE: os_unfair_lock_lock C call must not be wasmEligible")
    }

    func testAutoreleasepoolStaysNonEligible() {
        let src = """
        struct Worker {
            func run() -> Int { var n = 0; autoreleasepool { n = 1 + 1 }; return n }
        }
        """
        let r = analyze([(src, "W.swift")])
        let run = result(r, containing: "Worker.run")
        XCTAssertNotEqual(run?.classification, .wasmEligible,
            "ZERO-FALSE-NEGATIVE: autoreleasepool is an ObjC-runtime construct and must not be wasmEligible")
    }

    func testSecurityCryptoCFunctionStaysNonEligible() {
        let src = """
        struct Trust {
            func make(_ data: Data) -> Bool {
                guard let c = SecCertificateCreateWithData(nil, data as CFData) else { return false }
                return SecCertificateCopyKey(c) != nil
            }
        }
        """
        let r = analyze([(src, "T.swift")])
        let make = result(r, containing: "Trust.make")
        XCTAssertNotEqual(make?.classification, .wasmEligible,
            "ZERO-FALSE-NEGATIVE: SecCertificate* crypto C calls must not be wasmEligible")
    }

    // MARK: - 4. Shadow set construction

    func testShadowSetExcludesExtensionsIncludesValueTypes() {
        let src = """
        struct Path { let n: Int }
        enum Color2 { case red }
        class Observable<T> { var value: T? }
        extension UIView { func x() {} }
        typealias Pure = Path
        typealias NativeImg = UIImage
        """
        let table = SymbolTableBuilder().build(
            sources: [(src, URL(fileURLWithPath: "/tmp/x/S.swift"))])
        let shadow = ResolvedProject.projectTypeNames(from: table)
        XCTAssertTrue(shadow.contains("Path"), "value struct Path should shadow")
        XCTAssertTrue(shadow.contains("Color2"), "value enum should shadow")
        XCTAssertTrue(shadow.contains("Pure"), "typealias to pure type should shadow")
        XCTAssertFalse(shadow.contains("Observable"), "reference type (class) excluded by value-type policy")
        XCTAssertFalse(shadow.contains("UIView"), "extension-only type must NOT shadow")
        XCTAssertFalse(shadow.contains("NativeImg"), "typealias to native UIImage must NOT shadow")
    }
}
