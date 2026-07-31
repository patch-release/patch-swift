// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// Regression tests for three CRITICAL guest-emission defects in SwiftUI→WASM
/// lowering — each one made the WHOLE guest module fail to compile (the SwiftUI
/// guest is ONE compile unit), so NO view shipped and NO OTA patch rendered:
///
///   DEFECT 2 — `ForEach` emitted an UNBOUND loop variable: the row template
///     referenced `x` with no `for x in …` → `cannot find 'x' in scope`. FIX: a
///     `ForEach` over a marshalled scalar-array input emits a real guest loop that
///     binds the loop var; over anything else it DEMOTES to `.opaque` (native slot).
///
///   DEFECT 3 — a view reading a non-reconstructable input (struct/enum/dictionary)
///     was correctly flagged `thunkSafe:false` but STILL emitted into the module,
///     where it bound a struct as an UNQUALIFIED nested-type default / accessed a
///     missing member → compile error. FIX: such a view is EXCLUDED from guest
///     emission entirely (no `view_body__X`); the rest of the module still ships.
///
/// The PRINCIPLE under test: the engine only emits guest code that COMPILES;
/// anything it can't faithfully lower DEMOTES (native slot) or is EXCLUDED — never
/// broken guest code that fails the module. Each test proves the emitted guest
/// SOURCE actually compiles (the belt-and-suspenders WASM compile) where the
/// toolchain is present, and the structural shape always.
final class SwiftUIForEachLoweringTests: XCTestCase {

    // MARK: - (a) ForEach over a marshalled scalar array → bound guest loop

    func testForEachOverScalarArrayLowersToBoundLoopNoOpaque() throws {
        let source = """
        import SwiftUI
        struct ScoreList: View {
            @State private var scores: [Int] = [10, 20, 30]
            var body: some View {
                VStack {
                    ForEach(scores, id: \\.self) { x in
                        Text("Score: \\(x)")
                    }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let g = lowered.guestBody

        // A real guest loop binds the loop variable over the collection — NOT an
        // unbound free identifier, and NOT a native `.opaque` slot.
        XCTAssertTrue(g.contains("for x in scores"),
                      "ForEach must bind the loop var over the marshalled array: \(g)")
        XCTAssertTrue(g.contains("N.forEach("), "still a forEach node: \(g)")
        XCTAssertFalse(g.contains("N.opaque"),
                       "a scalar-array ForEach must NOT demote to a native slot: \(g)")
        // The loop var reaches the row body.
        XCTAssertTrue(g.contains("Score: \\(x)"), "the row template uses the loop var: \(g)")
        // The array is a guest-reconstructable input → the view does not demote.
        XCTAssertFalse(lowered.referencesUnmarshalledInput)
        XCTAssertEqual(try XCTUnwrap(lowered.inputs.first { $0.name == "scores" }).kind, .intArray)
    }

    /// BELT-AND-SUSPENDERS: the emitted guest SOURCE for the scalar-array ForEach
    /// actually COMPILES to WASM (proving the loop binding is valid Swift, not just
    /// the right shape). The whole point of the fix is that the module compiles.
    func testForEachGuestSourceCompiles() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__ScoreList", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping ForEach compile")

        let source = """
        import SwiftUI
        struct ScoreList: View {
            let scores: [Int] = []
            var body: some View {
                VStack {
                    ForEach(scores, id: \\.self) { x in
                        Text("Score: \\(x)")
                    }
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "foreach-compile")
        XCTAssertTrue(FileManager.default.fileExists(atPath: module.path),
                      "the guest module with a ForEach loop compiled to WASM")
    }

    // MARK: - (b) ForEach over a NON-marshallable collection → demote to .opaque

    func testForEachOverNestedStructArrayLowersToBoundLoop() throws {
        // `items` is an array of a struct with a nested `Tag` field. Recursive
        // marshalling now reconstructs nested structs, so the ForEach lowers to a REAL
        // bound guest loop (render-correctness proven by
        // SwiftUIRichInputMarshalTests.testNestedStructArrayExecutesInWasm) — it is no
        // longer demoted. The loop var is properly BOUND (never an unbound leak that
        // would fail the module).
        let source = """
        import SwiftUI
        struct Tag { var label: String }
        struct Item { var name: String; var tag: Tag }
        struct ItemList: View {
            let items: [Item] = []
            var body: some View {
                VStack {
                    ForEach(items, id: \\.name) { it in
                        Text(it.name)
                    }
                }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("N.forEach("), "still a forEach node: \(g)")
        XCTAssertTrue(g.contains("for it in items"),
                      "lowers to a real BOUND guest loop over the reconstructed array: \(g)")
        // SAFETY: the loop var appears ONLY in its bound context, never as an unbound
        // leak — the established module-safety invariant still holds.
        XCTAssertFalse(g.contains("N.opaque"),
                       "the reconstructable struct-array ForEach no longer demotes: \(g)")
    }

    func testForEachOverComputedRangeDemotesToOpaque() throws {
        // `0..<5` is a computed expression, not a marshalled bound array. Demote.
        let source = """
        import SwiftUI
        struct RangeList: View {
            var body: some View {
                VStack {
                    ForEach(0..<5, id: \\.self) { i in
                        Text("Row \\(i)")
                    }
                }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("N.opaque"), "a range ForEach demotes (no bound array): \(g)")
        XCTAssertFalse(g.contains("for i in 0..<5"), "no guest loop over a range: \(g)")
    }

    func testForEachOverMemberAccessDemotesToOpaque() throws {
        // `model.rows` is a member access, not a bare marshalled-array identifier.
        let source = """
        import SwiftUI
        struct Model { var rows: [Int] = [] }
        struct MemberList: View {
            let model = Model()
            var body: some View {
                VStack {
                    ForEach(model.rows, id: \\.self) { r in
                        Text("\\(r)")
                    }
                }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("N.opaque"), "a member-access ForEach demotes: \(g)")
        XCTAssertFalse(g.contains("for r in model.rows"), "no guest loop over a member access: \(g)")
    }

    /// The implicit-`$0` ForEach row form can't bind a loop var with a `for` loop
    /// (`for $0 in …` is illegal), so it demotes rather than emit broken code.
    func testForEachImplicitDollarParamDemotes() throws {
        let source = """
        import SwiftUI
        struct DollarList: View {
            let scores: [Int] = []
            var body: some View {
                VStack { ForEach(scores, id: \\.self) { Text("\\($0)") } }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("N.opaque"),
                      "an implicit-$0 ForEach row demotes (can't bind $0 with a for loop): \(g)")
    }

    /// A scalar-array ForEach whose ROW BODY is wholly non-lowerable (here an HStack
    /// with an unsupported `.background(Color…opacity…)` modifier → the whole row
    /// lowers to ONE `.opaque` leaf that carries the loop var only in its label, never
    /// live). Looping that would bind `tag` but never use it (a guest-compile warning)
    /// and emit N identical opaque nodes, so the WHOLE ForEach demotes to one native
    /// slot instead. The loop var must NEVER be left bound-but-unused. (On-device this
    /// renders natively — faithful — which the E2E confirmed.)
    func testForEachScalarArrayWithFullyOpaqueRowDemotesWhole() throws {
        // The row is a single CUSTOM view (a non-lowerable leaf). Its `tag` use lives
        // only in the opaque slot's source/label — NOT as a live guest identifier — so
        // looping would bind `tag` but never use it (and emit N identical opaque nodes).
        // The whole ForEach must therefore demote to one native slot.
        let source = """
        import SwiftUI
        struct TagRows: View {
            @State private var tags: [String] = ["a", "b"]
            var body: some View {
                VStack {
                    ForEach(tags, id: \\.self) { tag in
                        CustomTagBadge(tag: tag)
                    }
                }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("N.opaque"), "the non-lowerable row demotes the whole ForEach: \(g)")
        XCTAssertFalse(g.contains("for tag in tags"),
                       "no loop is emitted when the row never reads the loop var live "
                       + "(avoids a bound-but-unused var + N identical opaque nodes): \(g)")
    }

    /// A scalar-array ForEach whose row is PARTLY lowerable — a lowered `Text(tag)`
    /// reads the element AND a sibling leaf is non-lowerable — KEEPS the loop (a
    /// lowered child reads `tag`, so the bind is used and the module compiles). The
    /// non-lowerable leaf just makes the view non-thunkSafe (renders native), but the
    /// guest module is never broken.
    func testForEachScalarArrayWithPartlyLowerableRowKeepsLoop() throws {
        let source = """
        import SwiftUI
        struct TagRows: View {
            @State private var tags: [String] = ["a", "b"]
            var body: some View {
                VStack {
                    ForEach(tags, id: \\.self) { tag in
                        HStack {
                            Text(tag)
                            Text(tag).background(Color.blue.opacity(0.2))
                        }
                    }
                }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("for tag in tags"),
                      "a lowered child reads the element → the loop is kept: \(g)")
    }

    // MARK: - (b') Dynamic `List(data) { … }` is the same hazard → loop or demote

    func testDynamicListOverScalarArrayLowersToBoundLoop() throws {
        let source = """
        import SwiftUI
        struct NameList: View {
            let names: [String] = []
            var body: some View {
                List(names, id: \\.self) { n in
                    Text(n)
                }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("N.list("), "still a List: \(g)")
        XCTAssertTrue(g.contains("for n in names"),
                      "dynamic List over a marshalled array binds the loop var: \(g)")
        XCTAssertFalse(g.contains("N.opaque"), "no native slot for a loopable dynamic List: \(g)")
    }

    func testDynamicListOverNestedStructArrayLowersToBoundLoop() throws {
        // A struct element with a nested `Meta` field. Recursive marshalling now
        // reconstructs nested structs, so the data-driven List lowers to a REAL bound
        // guest loop over the reconstructed `[Row]` (render-correctness proven by
        // SwiftUIRichInputMarshalTests.testNestedStructArrayExecutesInWasm) — no longer
        // a whole-List demote.
        let source = """
        import SwiftUI
        struct Meta { var k: String }
        struct Row { var t: String; var meta: Meta }
        struct RowList: View {
            let rows: [Row] = []
            var body: some View {
                List(rows, id: \\.t) { r in
                    Text(r.t)
                }
            }
        }
        """
        let g = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(g.contains("for r in rows"),
                      "lowers to a real BOUND guest loop over the reconstructed array: \(g)")
        XCTAssertFalse(g.contains("N.opaque"),
                       "the reconstructable struct-array List no longer demotes: \(g)")
    }

    // MARK: - (c) A struct-field-reading view is EXCLUDED from emission

    func testStructReadingViewExcludedFromEmissionRestStillEmits() throws {
        // IRShowcase reads a struct field in a CONTROL-FLOW CONDITION (`if profile.active`)
        // — a LIVE guest reference to a non-reconstructable input that can't host-resolve
        // (unlike a `Text(profile.name)` content, which now lowers via a STRING host token).
        // It must be EXCLUDED from guest emission entirely (no `view_body__IRShowcase`),
        // since emitting it would bind an unqualified nested type / access a missing member
        // and fail the WHOLE module. A second, clean view in the same source must still
        // emit + ship.
        let dir = try makeSourceDir([
            "Views.swift": """
            import SwiftUI
            struct IRShowcase: View {
                struct Profile { var name: String; var active: Bool }
                @State private var profile = Profile(name: "Ada", active: true)
                var body: some View {
                    VStack {
                        if profile.active { Text("on") } else { Text("off") }
                        Text("static label")
                    }
                }
            }
            struct CleanCard: View {
                let title: String = "Hello"
                var body: some View {
                    VStack { Text(title) }
                }
            }
            """
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        // Drive the emission selection exactly as BuildPipeline does: lower, then
        // build the guest views EXCLUDING any that read a non-reconstructable input.
        let lowering = BodyLowering()
        let source = try String(contentsOf: dir.appendingPathComponent("Views.swift"), encoding: .utf8)
        var guestViews: [SwiftUIGuestEmitter.GuestView] = []
        var excluded: [String] = []
        for lowered in lowering.lowerAllViews(source: source) {
            guard lowered.report.totalElements > 0 else { continue }
            if lowered.referencesUnmarshalledInput {
                excluded.append(lowered.viewName)
                continue   // EXCLUDE from emission (DEFECT 3 fix)
            }
            guestViews.append(.init(viewName: lowered.viewName, guestBody: lowered.guestBody,
                                    inputs: lowered.inputs, stateModel: lowered.stateModel,
                                    thunkSafe: true))
        }
        XCTAssertEqual(excluded, ["IRShowcase"], "the struct-reading view is excluded")
        XCTAssertEqual(guestViews.map { $0.viewName }, ["CleanCard"],
                       "only the clean view reaches the emitter")

        // The emitted module has NO `view_body__IRShowcase`, DOES have CleanCard, and
        // the manifest lists only the clean view.
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)
        let wrapper = try XCTUnwrap(emission.files.first { $0.fileName == "_PatchSwiftUI.swift" })
        XCTAssertFalse(wrapper.contents.contains("view_body__IRShowcase"),
                       "the excluded view must emit NO body export")
        XCTAssertFalse(wrapper.contents.contains("Profile("),
                       "no unqualified nested-type constructor is emitted")
        XCTAssertTrue(wrapper.contents.contains("@_cdecl(\"view_body__CleanCard\")"),
                      "the clean view still emits its body export")
        XCTAssertTrue(emission.exports.contains("view_body__CleanCard"))
        XCTAssertFalse(emission.exports.contains("view_body__IRShowcase"))
    }

    /// The full BuildPipeline path excludes the struct-reader and ships the clean
    /// view — and the emitted module COMPILES to WASM (proving the exclusion removed
    /// the whole-module failure). Toolchain-gated.
    func testBuildPipelineExcludesStructReaderAndModuleCompiles() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__CleanCard", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping pipeline compile")

        let dir = try makeSourceDir([
            "Views.swift": """
            import SwiftUI
            struct IRShowcase: View {
                struct Profile { var name: String; var active: Bool }
                @State private var profile = Profile(name: "Ada", active: true)
                var body: some View { VStack { if profile.active { Text("on") } else { Text("off") } } }
            }
            struct CleanCard: View {
                let title: String = "Hi"
                var body: some View { VStack { Text(title) } }
            }
            """
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let buildDir = dir.appendingPathComponent(".build")
        let defaultModule = buildDir.appendingPathComponent("module.wasm")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let pipeline = BuildPipeline()
        let result = try pipeline.runSwiftUILowering(
            sourceDir: dir, buildDir: buildDir, compiler: compiler, defaultModule: defaultModule)
        let sw = try XCTUnwrap(result, "the SwiftUI lowering should ship the clean view")
        XCTAssertEqual(sw.loweredViewBodies, 1, "only CleanCard ships")
        XCTAssertTrue(sw.exports.contains("view_body__CleanCard"))
        XCTAssertFalse(sw.exports.contains("view_body__IRShowcase"),
                       "the struct-reader is excluded — never breaks the module")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(sw.moduleURL).path))
    }

    // MARK: - DEFECT 5: a concise non-verbose WARNING when views are demoted/excluded

    func testDemotedViewsEmitNonVerboseWarning() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__CleanCard", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping warning capture")
        // Ensure the verbose flag is OFF (the warning must show WITHOUT it).
        XCTAssertNil(ProcessInfo.processInfo.environment["PATCH_SWIFTUI_VERBOSE"],
                     "this test asserts the NON-verbose warning path")

        let dir = try makeSourceDir([
            "Views.swift": """
            import SwiftUI
            struct IRShowcase: View {
                struct Profile { var name: String; var active: Bool }
                @State private var profile = Profile(name: "Ada", active: true)
                var body: some View { VStack { if profile.active { Text("on") } else { Text("off") } } }
            }
            struct CleanCard: View {
                let title: String = "Hi"
                var body: some View { VStack { Text(title) } }
            }
            """
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let buildDir = dir.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let captured = try captureStderr {
            _ = try BuildPipeline().runSwiftUILowering(
                sourceDir: dir, buildDir: buildDir, compiler: compiler,
                defaultModule: buildDir.appendingPathComponent("module.wasm"))
        }
        XCTAssertTrue(captured.contains("could not be lowered to WASM"),
                      "a concise non-verbose warning fires for the excluded view: \(captured)")
        XCTAssertTrue(captured.contains("IRShowcase"), "names the demoted view: \(captured)")
        XCTAssertTrue(captured.contains("render"), "explains it renders natively: \(captured)")
        XCTAssertTrue(captured.contains("PATCH_SWIFTUI_VERBOSE=1"),
                      "points at the verbose flag for details: \(captured)")
    }

    /// Run `body` with stderr (fd 2) redirected to a pipe; return everything written
    /// to it. A background thread drains the read end while `body` runs (so a large
    /// write can't fill the pipe buffer and block the writer). Teardown — restoring
    /// fd 2 and closing the duplicated write end so the pipe reaches EOF — runs
    /// EXPLICITLY before joining the reader and reading the bytes; without it fd 2
    /// (which `dup2` also points at the write end) keeps the pipe open and
    /// `readDataToEndOfFile` blocks forever (the original deadlock). On the error
    /// path it tears down (so fd 2 isn't leaked to later tests) before rethrowing.
    private func captureStderr(_ body: () throws -> Void) throws -> String {
        let pipe = Pipe()
        let original = dup(STDERR_FILENO)
        fflush(stderr)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        // `collected` is mutated only under `lock` (below), so the cross-thread capture
        // is manually synchronized — tell Swift 6 concurrency exactly that.
        nonisolated(unsafe) let collected = NSMutableData()
        let lock = NSLock()
        let reader = Thread {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); collected.append(data); lock.unlock()
        }
        reader.start()

        func teardownAndRead() -> String {
            fflush(stderr)
            dup2(original, STDERR_FILENO)            // fd 2 → real stderr again
            close(original)
            pipe.fileHandleForWriting.closeFile()    // close the last write-end fd → EOF
            while !reader.isFinished { usleep(1000) } // let the drain finish
            lock.lock(); let data = collected as Data; lock.unlock()
            return String(decoding: data, as: UTF8.self)
        }

        do {
            try body()
        } catch {
            _ = teardownAndRead()   // restore stderr before propagating (don't leak fd 2)
            throw error
        }
        return teardownAndRead()
    }

    // MARK: - (d) END-TO-END: ForEach-over-[Int] compiles + runs in WASM

    func testForEachLoopExecutesInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__ScoreList", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping ForEach WASM run")

        let source = """
        import SwiftUI
        struct ScoreList: View {
            let scores: [Int] = []
            var body: some View {
                VStack {
                    ForEach(scores, id: \\.self) { x in
                        Text("Score: \\(x)")
                    }
                }
            }
        }
        """
        let module = try compileSwiftUIModule(source: source, into: "foreach-exec")
        let wasm = [UInt8](try Data(contentsOf: module))
        let runner = try Runner(wasm: wasm)

        // Marshal a REAL array in — the WASM loop must unroll one row per element.
        let inputs = Data(#"{"scores":[7,8,9]}"#.utf8)
        let outBytes = try runner.callPacked("view_body", [UInt8](inputs))
        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
        let desc = body.root.describe()

        // The unrolled rows reflect the array — proving the loop binding compiled
        // AND ran in WASM (not the empty default, not a single template row).
        XCTAssertTrue(desc.contains("ForEach"), "the tree has a ForEach node: \(desc)")
        XCTAssertTrue(desc.contains("Text(\"Score: 7\")"), "row 0 from the array: \(desc)")
        XCTAssertTrue(desc.contains("Text(\"Score: 8\")"), "row 1 from the array: \(desc)")
        XCTAssertTrue(desc.contains("Text(\"Score: 9\")"), "row 2 from the array: \(desc)")
        // Exactly three rows (no extra, no template leftover).
        let rowCount = desc.components(separatedBy: "Text(\"Score: ").count - 1
        XCTAssertEqual(rowCount, 3, "exactly one row per array element: \(desc)")

        // An EMPTY array yields zero rows (the loop ran, appended nothing).
        let empty = try Runner(wasm: wasm).callPacked("view_body", [UInt8](Data(#"{"scores":[]}"#.utf8)))
        let emptyBody = try JSONDecoder().decode(BodyEmission.self, from: Data(empty))
        let emptyDesc = emptyBody.root.describe()
        XCTAssertFalse(emptyDesc.contains("Text(\"Score: "), "empty array → no rows: \(emptyDesc)")
    }

    // MARK: - Helpers

    /// Whether the emitted guest body references `name` as a LIVE identifier (a
    /// `DeclReferenceExpr` in the parsed builder expression) — names appearing only
    /// inside an `N.opaque(…, label: "…")` string literal don't count.
    private func emittedTreeReferences(_ guestBody: String, name: String) -> Bool {
        BodyLowering.guestBodyReferencesAny(guestBody, names: [name])
    }

    /// Lower `source`, emit the guest module, write the files, and compile to WASM.
    private func compileSwiftUIModule(source: String, into label: String) throws -> URL {
        let lowering = BodyLowering()
        let lowered = lowering.lowerAllViews(source: source)
        let guestViews = lowered
            .filter { !$0.referencesUnmarshalledInput }
            .map { SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody,
                                                 inputs: $0.inputs, stateModel: $0.stateModel) }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.swiftui.wasm")
        let compiler = SwiftWasmCompiler(
            exportedSymbols: emission.exports + ["patch_malloc", "patch_free"])
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "guest WASM compile failed:\n\(result.log)")
        return out
    }

    private func makeSourceDir(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    // Minimal WASM runner (mirrors SwiftUILoweringTests.Runner / PatchSDK.callPacked).
    private final class Runner {
        let store: Store
        let instance: Instance
        let wasi: WASIBridgeToHost
        init(wasm: [UInt8]) throws {
            let engine = Engine()
            self.store = Store(engine: engine)
            self.wasi = try WASIBridgeToHost()
            var imports = Imports()
            wasi.link(to: &imports, store: store)
            PatchHostTestImports.register(into: &imports, store: store)
            let module = try parseWasm(bytes: wasm)
            self.instance = try module.instantiate(store: store, imports: imports)
            try wasi.initialize(instance)
        }
        func memory() throws -> Memory {
            guard let m = instance.exports[memory: "memory"] else { throw NSError(domain: "abi", code: 1) }
            return m
        }
        func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
            guard let fn = instance.exports[function: name],
                  let malloc = instance.exports[function: "patch_malloc"] else {
                throw NSError(domain: "abi", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing export \(name)"])
            }
            let ptr = try malloc([.i32(UInt32(input.count))])[0].i32
            let mem = try memory()
            mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: input.count) { raw in
                raw.copyBytes(from: input)
            }
            let packed = try fn([.i32(ptr), .i32(UInt32(input.count))])[0].i64
            let outPtr = UInt32(truncatingIfNeeded: packed >> 32)
            let outLen = UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)
            let all = try memory().data
            return [UInt8](all[Int(outPtr)..<Int(outPtr) + Int(outLen)])
        }
    }
}
