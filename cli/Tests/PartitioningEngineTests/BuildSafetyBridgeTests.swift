// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import SwiftParser
import SwiftSyntax
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler

/// Build-safety: the GENERAL-LOGIC / native-bridge codegen path must carry the
/// same PROVE-OR-DEMOTE invariant the SwiftUI thunk side has — if the engine can't
/// PROVE the generated Swift compiles against the dev's real types, that
/// function/bridge DEMOTES to native rather than emitting a guess.
///
/// Audit catalog (`findings/buildsafety-general-bridges.md`):
///   S3 — `_Args`/`_Out` struct FIELD names not keyword-escaped → a dev param/field
///        named after a Swift keyword (`default`/`where`/`repeat`/…) emits invalid
///        Swift on BOTH the guest wrapper AND the native-bridge mirror (the dev's
///        Xcode build). FIX: backtick-escape keyword field names.
///   S1 — the T2 ABI wrapper synthesizes `_Args: Decodable` / `_Out: Encodable` over
///        verbatim dev field types WITHOUT proving they are Codable. A non-Codable
///        boundary type → the synthesized conformance fails to compile. FIX: prove
///        every boundary type is Codable BEFORE emitting; else stay native.
///   S2 — the native-shell `*_bridge.swift` files are written but NEVER type-checked
///        by the engine, so a wrong hardcoded type/optionality ships as a successful
///        `patchcli build` and breaks the developer's Xcode build. FIX: host-
///        `swiftc -typecheck` the bridge against its deps and DEMOTE on failure.
final class BuildSafetyBridgeTests: XCTestCase {

    /// A generated Swift fragment is syntactically valid iff its parse tree has no
    /// error nodes. `let default: Int` (a bare keyword as an identifier) yields an
    /// error node; `` let `default`: Int `` does not. This is the toolchain-free
    /// build-safety gate the audit's S3 repro requires.
    private func parsesCleanly(_ source: String) -> Bool {
        !Parser.parse(source: source).hasError
    }

    // MARK: - S3: keyword-named field names are backtick-escaped ------------------

    /// The shared helper escapes a reserved keyword and leaves a normal name alone.
    func testKeywordSafeFieldNameEscapesReservedKeywordsOnly() {
        // Reserved keywords → backtick-escaped.
        for kw in ["default", "where", "repeat", "class", "in", "func", "case",
                   "guard", "switch", "return", "self", "Self", "throws", "is"] {
            XCTAssertEqual(CodeEmitter.keywordSafeFieldName(kw), "`\(kw)`",
                           "reserved keyword '\(kw)' must be backtick-escaped")
        }
        // Ordinary identifiers (including contextual words that ARE valid bare
        // identifiers) are returned unchanged — no churn.
        for ok in ["count", "promoCode", "value", "get", "set", "some", "any", "x0"] {
            XCTAssertEqual(CodeEmitter.keywordSafeFieldName(ok), ok,
                           "ordinary identifier '\(ok)' must be unchanged")
        }
    }

    /// A pure export with KEYWORD-named parameters emits a `_Args` envelope whose
    /// field names are backtick-escaped, and the WHOLE generated wrapper parses
    /// cleanly. Before the fix this emitted `let `default`` as a bare `let default:`
    /// → a parse error → broken guest WASM compile AND broken dev Xcode build.
    func testKeywordNamedParamsEmitValidWrapper() {
        let export = CodeEmitter.PureExport(
            exportName: "schedule",
            callee: "Scheduler.schedule",
            parameters: [(label: "_", name: "repeat", type: "Int"),
                         (label: "where", name: "where", type: "Bool"),
                         (label: "_", name: "default", type: "Int")],
            returnType: "Int")
        let (_, source, _) = CodeEmitter().emitFoundationPureExportFilePublic(
            export, includeAllocator: true)
        XCTAssertTrue(source.contains("let `repeat`: Int"),
                      "keyword param 'repeat' must be backtick-escaped; got:\n\(source)")
        XCTAssertTrue(source.contains("let `where`: Bool"),
                      "keyword param 'where' must be backtick-escaped")
        XCTAssertTrue(source.contains("let `default`: Int"),
                      "keyword param 'default' must be backtick-escaped")
        XCTAssertFalse(source.contains("let default:") || source.contains("let where:")
                       || source.contains("let repeat:"),
                       "no bare keyword field may be emitted")
        XCTAssertTrue(parsesCleanly(source),
                      "the full keyword-named wrapper must parse without errors:\n\(source)")
    }

    /// A keyword-named OUTPUT (the flattened result-envelope field) is escaped, and
    /// the `_out = _Out(<label>:)` initializer label + the `_result.<label>` read
    /// match — the source parses clean. (Tuple-component labels arrive from
    /// SwiftSyntax `.text`, backtick-stripped, so a `(default: Int, count: Int)`
    /// return surfaces a keyword `default` label that must be re-escaped.)
    func testKeywordNamedTupleOutputEmitsValidWrapper() {
        let export = CodeEmitter.PureExport(
            exportName: "parse", callee: "P.parse",
            parameters: [(label: "_", name: "s", type: "String")],
            returnType: "(default: Int, count: Int)")
        let (_, source, _) = CodeEmitter().emitFoundationPureExportFilePublic(
            export, includeAllocator: true)
        XCTAssertTrue(source.contains("let `default`: Int"),
                      "keyword tuple-component 'default' must be backtick-escaped; got:\n\(source)")
        XCTAssertTrue(source.contains("`default`: _result.`default`"),
                      "the flattened read of a keyword component must also be escaped")
        XCTAssertTrue(parsesCleanly(source),
                      "keyword-output wrapper must parse without errors:\n\(source)")
    }

    /// The NATIVE-BRIDGE mirror (the `*_bridge.swift` the engine writes into the dev's
    /// project) must ALSO keyword-escape field names — this is the half that breaks
    /// the developer's Xcode build (S2/S3). We drive it through the mixed-fragment
    /// bridge emit (`emit`) with a keyword-named input/output and assert the bridge
    /// parses cleanly.
    func testNativeBridgeMirrorEscapesKeywordFields() {
        let frag = SplitPlan.PureFragment(
            name: "_sp_bar_frag",
            inputs: [(name: "default", type: "Int")],
            outputs: [(name: "where", type: "Int")],
            bodyStatements: ["return `default`"])
        let plan = SplitPlan(
            originalID: "Foo.bar()", originalSimpleName: "bar",
            pureFragments: [frag],
            nativeSignature: "bar(_ default: Int) -> Int",
            originalParameters: [(name: "default", type: "Int")],
            returnType: "Int",
            shellSteps: [.fragmentCall(fragment: frag)])
        let files = CodeEmitter().emit(plan, includeAllocator: true)
        XCTAssertTrue(files.bridgeSource.contains("let `default`: Int"),
                      "native bridge `_Args` must escape keyword input; got:\n\(files.bridgeSource)")
        XCTAssertTrue(files.bridgeSource.contains("let `where`: Int"),
                      "native bridge `_Out` must escape keyword output")
        XCTAssertTrue(parsesCleanly(files.bridgeSource),
                      "native bridge must parse without errors:\n\(files.bridgeSource)")
        XCTAssertTrue(parsesCleanly(files.wasmSource),
                      "guest wasm wrapper must parse without errors:\n\(files.wasmSource)")
    }

    // MARK: - S1: prove every ABI boundary type is Codable, else demote ------------

    /// A no-op WASM compiler stub: the S1 gate runs at codegen time (a `dryRun`
    /// build never reaches it), so the stub just satisfies the signature.
    private final class NoopCompiler: WasmCompiling, @unchecked Sendable {
        func compile(sources: [URL], outputModule: URL) throws -> WasmCompileResult {
            try? Data([0x00, 0x61, 0x73, 0x6d]).write(to: outputModule)
            return WasmCompileResult(status: .success, moduleURL: outputModule, log: "ok")
        }
    }

    private func makeApp(_ logic: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bs1-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("Sources/Geo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try logic.write(to: src.appendingPathComponent("Logic.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Geo", targets: [.target(name: "Geo")])
        """.write(to: tmp.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        return tmp
    }

    private func runDry(_ app: URL) throws -> BuildPipeline.Result {
        try BuildPipeline().run(
            sourceDir: app.appendingPathComponent("Sources/Geo"),
            buildDir: app.appendingPathComponent("build"),
            compiler: NoopCompiler(), dryRun: true)
    }

    /// A pure function whose ABI boundary is a NON-Codable type the bundler does NOT
    /// reconstruct (Foundation's `NSAttributedString` — a reference type, not in the
    /// known-Codable-leaf set, not bundled) PASSES the closure-shippable gate but
    /// would synthesize `_Args: Decodable { let s: NSAttributedString }` — which fails
    /// to compile (no synthesized conformance), LOUD on the guest but RED in the dev's
    /// Xcode build via the native-bridge mirror. The S1 gate DEMOTES it to native with
    /// a clear reason, so a non-Codable boundary never reaches the dev's build.
    func testNonCodableBoundaryDemotesToNative() throws {
        let app = try makeApp("""
        import Foundation
        public func styledLength(_ s: NSAttributedString) -> Int { s.length }
        """)
        defer { try? FileManager.default.removeItem(at: app) }
        let result = try runDry(app)
        XCTAssertFalse(result.exportSymbols.contains("styledLength"),
                       "a non-Codable boundary export must NOT ship; exports=\(result.exportSymbols)")
        XCTAssertTrue(result.rejectedExports.contains {
            $0.name == "styledLength" && $0.reason.contains("not provably Codable")
        }, "the demote must cite the S1 Codable proof; rejected=\(result.rejectedExports)")
    }

    /// The fix is DEMOTE-SAFE: an all-Codable boundary (scalars + String) still ships
    /// — the S1 gate is a one-directional filter, never a coverage regression.
    func testCodableBoundaryStillShips() throws {
        let app = try makeApp("""
        import Foundation
        public func score(_ n: Int, _ label: String) -> Int { n + label.count }
        """)
        defer { try? FileManager.default.removeItem(at: app) }
        let result = try runDry(app)
        XCTAssertTrue(result.exportSymbols.contains("score"),
                      "an all-Codable boundary must still ship; exports=\(result.exportSymbols)")
        XCTAssertFalse(result.rejectedExports.contains { $0.name == "score" },
                       "a provably-Codable export must not be demoted; rejected=\(result.rejectedExports)")
    }

    // MARK: - S2: host-typecheck the native bridges, demote a non-compiling one -----

    private func writeFile(_ dir: URL, _ name: String, _ body: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try body.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    /// A bridge whose hardcoded type DRIFTS from the dev's real symbol (it passes an
    /// `Int` where the dev helper returns a `String`) fails the host type-check and is
    /// reported as a failing bridge to DEMOTE — so the broken bridge never reaches the
    /// dev's Xcode build. The SOUND bridge in the same run type-checks and ships.
    func testTypecheckDemotesADriftedBridgeButKeepsTheSoundOne() throws {
        try XCTSkipUnless(BridgeTypecheck.hostSwiftc() != nil,
                          "host swiftc unavailable — skipping bridge type-check net")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bs2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // The developer's own source: a helper returning a String.
        let dev = try writeFile(tmp, "Logic.swift", """
        import Foundation
        public enum Helper { public static func label() -> String { "hi" } }
        """)
        // A SOUND bridge in the REAL bridge shape (import PatchSDK + a file-local
        // `enum Patch` shim + a `*Bridge` enum) — proves the synthesized PatchSDK
        // module shim resolves and the bridge's own `enum Patch` does NOT collide.
        let sound = try writeFile(tmp, "good_bridge.swift", """
        import Foundation
        import PatchSDK
        private struct G_Args: Encodable { let s: String }
        private struct G_Out: Decodable { let value: Int }
        enum GoodBridge { static func run() -> Int { Helper.label().count } }
        enum Patch {
            static func call<A: Encodable, R: Decodable>(_ name: String, _ args: A, returning: R.Type) -> R {
                return try! PatchSDK.Patch.shared.callJSON(name, args, returning: R.self)
            }
        }
        """)
        // A DRIFTED bridge: assigns the real String return to an Int — a type error the
        // engine never caught (it shipped as a successful build) and breaks the dev's
        // Xcode build.
        let drifted = try writeFile(tmp, "bad_bridge.swift", """
        import Foundation
        import PatchSDK
        enum BadBridge { static func run() -> Int { let n: Int = Helper.label(); return n } }
        """)
        let outcome = BridgeTypecheck.run(
            devSwiftFiles: [dev], bridges: [sound, drifted], enabled: true)
        XCTAssertTrue(outcome.ran, "the net should run (dev baseline type-checks): \(outcome.note)")
        XCTAssertTrue(outcome.failingBridges.contains(drifted),
                      "the drifted bridge must be flagged for demote: \(outcome.note)")
        XCTAssertFalse(outcome.failingBridges.contains(sound),
                       "the sound bridge must NOT be demoted: \(outcome.note)")
    }

    /// SAFETY VALVE: when the dev source doesn't type-check ON ITS OWN (an unresolvable
    /// third-party import), the net is INCONCLUSIVE — it must SKIP (demote nothing),
    /// never spuriously demote a bridge for a pre-existing project error.
    func testTypecheckSkipsWhenDevBaselineDoesNotCompile() throws {
        try XCTSkipUnless(BridgeTypecheck.hostSwiftc() != nil,
                          "host swiftc unavailable — skipping bridge type-check net")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bs2v-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Dev source imports a module the CLI can't resolve → baseline fails.
        let dev = try writeFile(tmp, "Logic.swift", """
        import Foundation
        import SomeThirdPartyModuleThatDoesNotExist
        public func f() -> Int { 1 }
        """)
        let bridge = try writeFile(tmp, "x_bridge.swift", """
        import Foundation
        enum XBridge { static func run() -> Int { 1 } }
        """)
        let outcome = BridgeTypecheck.run(
            devSwiftFiles: [dev], bridges: [bridge], enabled: true)
        XCTAssertFalse(outcome.ran, "the net must skip when the dev baseline can't compile")
        XCTAssertTrue(outcome.failingBridges.isEmpty,
                      "no bridge may be demoted on an inconclusive baseline: \(outcome.note)")
    }

    /// `isKnownCodableLeaf` is the authoritative gate the prove-Codable check uses:
    /// stdlib/Foundation Codable leaves + containers conform; a custom/reference type
    /// does not (it must be reconstructed-and-bundled to be Codable).
    func testKnownCodableLeafClassification() {
        for ok in ["Int", "String", "Double", "Bool", "Date", "URL", "UUID", "Data",
                   "Array", "Dictionary", "Set", "Optional"] {
            XCTAssertTrue(DependencyClosureBundler.isKnownCodableLeaf(ok),
                          "'\(ok)' is a known-Codable leaf/container")
        }
        for notLeaf in ["NSAttributedString", "Session", "MyView", "AnyObject"] {
            XCTAssertFalse(DependencyClosureBundler.isKnownCodableLeaf(notLeaf),
                           "'\(notLeaf)' is NOT a known-Codable leaf — must be bundled to ship")
        }
    }
}
