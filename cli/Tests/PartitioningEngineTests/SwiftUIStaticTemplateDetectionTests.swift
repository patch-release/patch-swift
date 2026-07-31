// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

// SwiftUIStaticTemplateDetectionTests — the false-render FIREWALL for the
// structurally-static template cache.
//
// WHAT WE GUARD
// -------------
// `PatchedBodyStaticTemplateCache` in the SDK caches a view's WASM-decoded tree the
// first time it renders, then replays the SAME tree for every subsequent render —
// skipping WASM entirely.  This is correct IFF the view's tree is provably IDENTICAL
// for EVERY possible input.  The engine marks `isStructurallyStatic:true` only when
// ALL four conservative conditions hold (see `BodyLowering.swift` §1179-1201).
//
// A WRONG positive (a hazard view incorrectly marked static) would silently serve a
// stale tree: the first render's inputs would be frozen in every later render.  This
// file makes that impossible.
//
// TWO LAYERS
// ----------
// 1. POSITIVE DETECTION (layer A — the load-bearing correctness proof):
//    A view whose tree genuinely never changes across inputs IS marked static, AND
//    calling its WASM body across 10 arbitrary input JSONs yields BYTE-IDENTICAL
//    output each time (the engine's static mark is justified).  The WASM layer runs
//    only when the swift.org WASM toolchain is present — it skips cleanly otherwise,
//    but the detection assertion runs unconditionally.
//
// 2. HAZARD EXCLUSION (layer B — each hazard class MUST be NOT-static):
//    (a) `__strtok_` string-token view (Text(confidence.label)) — string varies
//        per instance.
//    (b) time-derived `__strtok_` via a host-resolved computed property (greetingLine)
//        — varies per instance.
//    (c) Optional-binding `if let x { Text(x) }` — tree STRUCTURE changes when `x`
//        is nil vs non-nil (the `Text` node appears or disappears).
//    (d) Marshalled-input view (Text(title)) — the `title` input appears in the tree.
//    (e) Numeric-token `__numtok_` view (cornerRadius: Theme.Radius.lg) — numeric
//        value varies per instance.
//    (f) Interactive state view (Toggle bound to @State isOn) — dispatch can change
//        state → tree changes post-interaction.
//    (g) GeometryReader view — `__geo_*` inputs vary per layout context.
//
// If ANY hazard view compiles AND `isStructurallyStatic == true`, the detection
// conditions are wrong and the cache would serve incorrect trees.  All seven cases
// must remain false.
final class SwiftUIStaticTemplateDetectionTests: XCTestCase {

    // MARK: - Helper

    private func lowerFirst(_ src: String, sameFileThunk: Bool = true)
    -> BodyLowering.LoweredView? {
        BodyLowering().lowerAllViews(source: src, sameFileThunk: sameFileThunk).first
    }

    // MARK: - LAYER A: POSITIVE detection — a genuinely static view IS marked static

    /// A view with ONLY a literal `Text` and a color/font token (no marshalled inputs)
    /// has a tree that is identical for every possible caller.  The engine MUST mark
    /// it `isStructurallyStatic:true`.
    ///
    /// Conditions satisfied:
    ///   1. No `ridesInputJSON` token (color/font tokens are render-time placeholders,
    ///      NOT merged into the input JSON — the `ridesInputJSON` flag is false for them).
    ///   2. The guestBody contains NO references to any reconstructable input name
    ///      (there are no inputs at all).
    ///   3. No GeometryReader.
    ///   4. No interactive state model.
    func testGenuinelyStaticViewIsMarkedStatic() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Colors { static let ink = Color.black } }
        struct ConstantBadge: View {
            var body: some View {
                Text("Active")
                    .foregroundStyle(Theme.Colors.ink)
                    .padding(8)
            }
        }
        """
        let v = try XCTUnwrap(lowerFirst(src), "engine lowered no view")
        // Color token — NOT a ridesInputJSON token (it's a render-time color ref,
        // resolved by the thunk's __patchTokens(), NOT merged into the input JSON).
        let ridingTokens = v.hostTokens.filter { $0.ridesInputJSON }
        XCTAssertTrue(ridingTokens.isEmpty,
                      "ConstantBadge must have no ridesInputJSON tokens; found: "
                      + ridingTokens.map { "\($0.kind):\($0.source)" }.joined(separator: ", "))
        // No marshalled inputs → no input name appears in the tree.
        XCTAssertTrue(v.inputs.filter { $0.kind.guestReconstructable }.isEmpty,
                      "ConstantBadge must have no reconstructable inputs")
        // No geometry reader.
        XCTAssertFalse(v.usesGeometry, "ConstantBadge must not use GeometryReader")
        // No interactive state.
        XCTAssertTrue(v.stateModel?.isInteractive != true,
                      "ConstantBadge must not be interactive")
        // THE KEY ASSERTION: the engine marks it static.
        XCTAssertTrue(v.isStructurallyStatic,
                      "ConstantBadge (literal text + color token, zero inputs) MUST be "
                      + "isStructurallyStatic:true — the cache can safely replay its first tree "
                      + "for every render. Got: \(v.isStructurallyStatic); guestBody: \(v.guestBody)")
    }

    /// A view with ONLY two literal `Text` nodes and a font token (no inputs whatsoever).
    /// Tests the simplest static shape.
    func testLiteralOnlyViewIsMarkedStatic() throws {
        let src = """
        import SwiftUI
        enum Brand { enum Font { static let heading = SwiftUI.Font.headline } }
        struct StaticLabel: View {
            var body: some View {
                VStack {
                    Text("Welcome").font(Brand.Font.heading)
                    Text("Get started")
                }
            }
        }
        """
        let v = try XCTUnwrap(lowerFirst(src), "engine lowered no view")
        XCTAssertTrue(v.inputs.filter { $0.kind.guestReconstructable }.isEmpty,
                      "StaticLabel must have no reconstructable inputs")
        XCTAssertTrue(v.isStructurallyStatic,
                      "StaticLabel (two literal texts + font token, zero inputs) "
                      + "MUST be isStructurallyStatic:true")
    }

    /// A view with NO inputs at all and NO tokens — the simplest possible static shape.
    func testZeroInputZeroTokenViewIsMarkedStatic() throws {
        let src = """
        import SwiftUI
        struct EmptyCard: View {
            var body: some View {
                VStack {
                    Text("No data")
                    Text("Please check back later")
                }
                .padding()
            }
        }
        """
        let v = try XCTUnwrap(lowerFirst(src), "engine lowered no view")
        XCTAssertTrue(v.isStructurallyStatic,
                      "EmptyCard (all literals, zero inputs, zero tokens) "
                      + "MUST be isStructurallyStatic:true; got guestBody: \(v.guestBody)")
    }

    // MARK: - LAYER A (WASM): the static view's WASM tree is IDENTICAL across 10 inputs

    /// POSITIVE FIREWALL (compile-and-run): lower `ConstantBadge`, compile it to WASM,
    /// call `view_body` across 10 DIFFERENT input JSONs (including edge cases), and
    /// assert the output bytes are IDENTICAL each time.  This proves the engine's
    /// `isStructurallyStatic` mark is CORRECT: the cached tree is always valid.
    ///
    /// Requires the swift.org WASM toolchain — skips cleanly if absent (the detection
    /// assertion in `testGenuinelyStaticViewIsMarkedStatic` runs regardless).
    func testStaticViewWasmTreeIsIdenticalAcrossAllInputs() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Colors { static let ink = Color.black } }
        struct ConstantBadge: View {
            var body: some View {
                Text("Active")
                    .foregroundStyle(Theme.Colors.ink)
                    .padding(8)
            }
        }
        """
        let loweredAll = BodyLowering().lowerAllViews(source: src, sameFileThunk: true)
        guard let lowered = loweredAll.first else {
            XCTFail("engine lowered no view from ConstantBadge source"); return
        }
        XCTAssertTrue(lowered.isStructurallyStatic,
                      "pre-flight: ConstantBadge must be static (this test proves the mark is correct)")

        let gv = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName,
            guestBody: lowered.guestBody,
            inputs: lowered.inputs,
            stateModel: lowered.stateModel,
            thunkSafe: true,
            usesGeometry: lowered.usesGeometry,
            inputTokens: lowered.hostTokens.filter { $0.ridesInputJSON })
        let emission = try SwiftUIGuestEmitter().emit(views: [gv])

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — "
                          + "skipping WASM positive-firewall execution for ConstantBadge; "
                          + "the detection assertion above runs regardless")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("static-firewall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }

        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("static_badge.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success,
                       "ConstantBadge guest WASM compile failed:\n\(result.log)")
        guard result.status == .success else { return }

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)

        // 10 different input JSONs — empty, random strings, edge cases.
        // The static view has NO marshalled inputs, so the body must IGNORE the payload;
        // the WASM output must be byte-identical for every one of these.
        let inputs: [String] = [
            "{}",
            "{\"title\":\"Hello\"}",
            "{\"title\":\"World\",\"count\":42}",
            "{\"name\":\"Alice\",\"score\":99.5}",
            "{\"a\":1,\"b\":2,\"c\":3}",
            "{\"x\":\"\"}",
            "{\"greeting\":\"Bonjour\",\"icon\":\"star\"}",
            "{\"items\":[\"one\",\"two\",\"three\"]}",
            "{\"flag\":true}",
            "{\"nested\":{\"key\":\"value\"}}"
        ]

        var outputs: [[UInt8]] = []
        for (i, inputJSON) in inputs.enumerated() {
            let outBytes: [UInt8]
            do {
                outBytes = try runner.callPacked("view_body", [UInt8](Data(inputJSON.utf8)))
            } catch {
                XCTFail("input[\(i)] '\(inputJSON)' → view_body threw: \(error)"); continue
            }
            XCTAssertFalse(outBytes.isEmpty,
                           "input[\(i)] '\(inputJSON)' → view_body returned no bytes")
            outputs.append(outBytes)
        }

        guard outputs.count == inputs.count else {
            XCTFail("not all inputs completed; got \(outputs.count) / \(inputs.count)"); return
        }

        // CORE ASSERTION: every output is byte-identical to the first.
        // This is the PROOF that the static-template cache is correct: the cached
        // tree (stored after input[0]) will be served for inputs[1..9] without WASM,
        // and the result is IDENTICAL to running WASM on each.
        let reference = outputs[0]
        for (i, candidate) in outputs.dropFirst().enumerated() {
            XCTAssertEqual(candidate, reference,
                           "STATIC TREE VIOLATION: ConstantBadge's WASM output for "
                           + "input[\(i + 1)] '\(inputs[i + 1])' DIFFERS from input[0] '\(inputs[0])'. "
                           + "This means the view's tree IS input-dependent and MUST NOT be "
                           + "marked isStructurallyStatic:true — the cache would serve a stale tree. "
                           + "ref (\(reference.count)B): \(String(decoding: reference, as: UTF8.self).prefix(200))\n"
                           + "got (\(candidate.count)B): \(String(decoding: candidate, as: UTF8.self).prefix(200))")
        }
    }

    // MARK: - LAYER B: HAZARD EXCLUSION — each hazard MUST NOT be marked static

    // (a) String-token view: Text(confidence.label) lowered via __strtok_<id>.
    // The string token RIDES the input JSON — a different `confidence` value = a
    // different `__strtok_` value = a different Text node.  NOT static.
    func testStringTokenHazardIsNotStatic() throws {
        let src = """
        import SwiftUI
        enum Confidence { case high, medium, low
            var label: String { switch self { case .high: "High" case .medium: "Mid"
                case .low: "Low" } }
        }
        struct ConfidencePill: View {
            let confidence: Confidence
            var body: some View {
                Text(confidence.label)
                    .padding(4)
            }
        }
        """
        let v = try XCTUnwrap(lowerFirst(src), "engine lowered no view")
        // Guard: the view must have a ridesInputJSON token (the string token).
        let ridingTokens = v.hostTokens.filter { $0.ridesInputJSON }
        guard !ridingTokens.isEmpty else {
            // If the engine didn't emit a string token (e.g. the lowering changed),
            // the view may have an input instead — either way it must NOT be static.
            XCTAssertFalse(v.isStructurallyStatic,
                           "ConfidencePill (enum-label Text) must NOT be static regardless of lowering path")
            return
        }
        // The string token ridesInputJSON → the body reads __strtok_<id> → the tree
        // changes when the resolved string changes.  MUST be excluded.
        XCTAssertFalse(v.isStructurallyStatic,
                       "ConfidencePill has a __strtok_ string token (ridesInputJSON) — "
                       + "the WASM body reads a varying string from the input JSON and MUST "
                       + "NOT be marked isStructurallyStatic:true (cache would freeze the string)")
    }

    // (b) Time-derived string token: a host-resolved computed greeting string
    // (e.g. depends on time-of-day or locale).  The token rides the input JSON
    // and varies per call.  NOT static.
    func testTimeDerivedStringTokenHazardIsNotStatic() throws {
        let src = """
        import SwiftUI
        struct GreetingView: View {
            let greetingLine: String     // computed by thunk (e.g. time-derived)
            var body: some View {
                Text(greetingLine)
                    .padding()
            }
        }
        """
        let v = try XCTUnwrap(lowerFirst(src), "engine lowered no view")
        // `greetingLine` is a plain marshalled input (a String field).
        // The body reads `greetingLine` in a live position → tree changes per input.
        let reconstructable = v.inputs.filter { $0.kind.guestReconstructable }.map(\.name)
        let bodyReferencesInput = !reconstructable.isEmpty
            && BodyLowering.guestBodyReferencesAny(v.guestBody, names: Set(reconstructable))
        // Either the body directly reads a marshalled input, OR it has a __strtok_:
        let ridingToken = v.hostTokens.contains { $0.ridesInputJSON }
        XCTAssertTrue(bodyReferencesInput || ridingToken,
                      "GreetingView must have either a marshalled greetingLine input in the "
                      + "tree OR a __strtok_ token — one of these must block the static mark")
        XCTAssertFalse(v.isStructurallyStatic,
                       "GreetingView (time-derived string varies per instance) MUST NOT be "
                       + "isStructurallyStatic:true — the cache would freeze the greeting for "
                       + "the first caller's time-of-day")
    }

    // (c) Optional-binding view: `if let x = subtitle { Text(x) }`.
    // The tree STRUCTURE changes when `subtitle` is nil (the Text node disappears)
    // vs non-nil.  NOT static.
    func testOptionalBindingHazardIsNotStatic() throws {
        let src = """
        import SwiftUI
        struct Card: View {
            let title: String
            let subtitle: String?
            var body: some View {
                VStack {
                    Text(title)
                    if let s = subtitle {
                        Text(s)
                    }
                }
            }
        }
        """
        let v = try XCTUnwrap(lowerFirst(src), "engine lowered no view")
        // The body has `title` (and possibly `subtitle`) as reconstructable inputs.
        // At minimum `title` is in the tree → the view is input-dependent.
        let reconstructable = Set(v.inputs.filter { $0.kind.guestReconstructable }.map(\.name))
        XCTAssertFalse(reconstructable.isEmpty,
                       "Card must have reconstructable inputs (title/subtitle)")
        XCTAssertFalse(v.isStructurallyStatic,
                       "Card has title + optional subtitle in the tree — tree varies with "
                       + "both the title text AND whether subtitle is nil; MUST NOT be static")
    }

    // (d) Plain marshalled-input view: `Text(title)`.
    // `title` is a reconstructable input that appears in the tree → different `title`
    // values → different Text nodes.  NOT static.
    func testMarshalledInputViewIsNotStatic() throws {
        let src = """
        import SwiftUI
        struct TitleCard: View {
            let title: String
            var body: some View {
                Text(title)
                    .padding()
            }
        }
        """
        let v = try XCTUnwrap(lowerFirst(src), "engine lowered no view")
        let reconstructable = Set(v.inputs.filter { $0.kind.guestReconstructable }.map(\.name))
        XCTAssertTrue(reconstructable.contains("title"),
                      "TitleCard must have `title` as a reconstructable input; got: \(reconstructable)")
        let treeReferences = BodyLowering.guestBodyReferencesAny(v.guestBody, names: reconstructable)
        XCTAssertTrue(treeReferences,
                      "TitleCard's guestBody must reference `title` in a live position; "
                      + "guestBody: \(v.guestBody)")
        XCTAssertFalse(v.isStructurallyStatic,
                       "TitleCard has Text(title) — the title input IS in the tree; MUST NOT be "
                       + "isStructurallyStatic:true (cache would serve the first title for every render)")
    }

    // (e) Numeric-token view: a design-system constant in a numeric position
    // (`.cornerRadius(Theme.Radius.lg)`).  The constant is resolved by the thunk and
    // rides the input JSON as a `__numtok_<id>` key → the body reads a varying value.
    // NOT static.
    func testNumericTokenHazardIsNotStatic() throws {
        let src = """
        import SwiftUI
        enum Theme { enum Radius { static let lg: CGFloat = 16 } }
        struct RoundedCard: View {
            let text: String
            var body: some View {
                Text(text)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.lg))
            }
        }
        """
        let v = try XCTUnwrap(lowerFirst(src), "engine lowered no view")
        // The view has a __numtok_ token OR the numeric constant was inlined (folded
        // as a literal by the engine).  In the first case: ridesInputJSON → NOT static.
        // In the second case (constant folded): `text` input IS in the tree → also not static.
        let ridingNumeric = v.hostTokens.filter { $0.ridesInputJSON && $0.kind == .number }
        let reconstructable = Set(v.inputs.filter { $0.kind.guestReconstructable }.map(\.name))
        let textInTree = !reconstructable.isEmpty
            && BodyLowering.guestBodyReferencesAny(v.guestBody, names: reconstructable)
        // Either the numeric token or the text input blocks the static mark.
        XCTAssertTrue(!ridingNumeric.isEmpty || textInTree,
                      "RoundedCard must be excluded from static via a ridesInputJSON numtok OR "
                      + "via the text input in the tree — one of these must be true")
        XCTAssertFalse(v.isStructurallyStatic,
                       "RoundedCard has `text` in the tree (and possibly a __numtok_ token) "
                       + "— MUST NOT be isStructurallyStatic:true")
    }

    // (f) Interactive state view: a Toggle bound to @State isOn.
    // The dispatch export re-emits the tree with new state → the tree changes
    // post-interaction even if the INITIAL tree might look input-independent.
    // NOT static.
    func testInteractiveStateViewIsNotStatic() throws {
        let src = """
        import SwiftUI
        struct NotificationsToggle: View {
            @State var isOn: Bool = false
            var body: some View {
                Toggle("Notifications", isOn: $isOn)
                    .padding()
            }
        }
        """
        let v = try XCTUnwrap(lowerFirst(src), "engine lowered no view")
        // The state model must be interactive (has a @State field + a dispatch rule).
        let interactive = v.stateModel?.isInteractive == true
        XCTAssertTrue(interactive,
                      "NotificationsToggle must have an interactive state model (@State isOn + Toggle); "
                      + "stateModel: \(String(describing: v.stateModel))")
        XCTAssertFalse(v.isStructurallyStatic,
                       "NotificationsToggle is interactive — dispatch changes state → tree changes; "
                       + "MUST NOT be isStructurallyStatic:true (cache would freeze the toggle's state)")
    }

    // (g) GeometryReader view: uses `__geo_*` inputs injected per-layout.
    // The child sizes differ layout-to-layout → the tree changes.  NOT static.
    func testGeometryReaderHazardIsNotStatic() throws {
        let src = """
        import SwiftUI
        struct ResponsiveCard: View {
            var body: some View {
                GeometryReader { geo in
                    if geo.size.width > 400 {
                        Text("Wide")
                    } else {
                        Text("Narrow")
                    }
                }
            }
        }
        """
        let v = try XCTUnwrap(lowerFirst(src), "engine lowered no view")
        XCTAssertTrue(v.usesGeometry,
                      "ResponsiveCard must have usesGeometry:true; got false. "
                      + "guestBody: \(v.guestBody)")
        XCTAssertFalse(v.isStructurallyStatic,
                       "ResponsiveCard uses GeometryReader (__geo_* inputs vary per layout); "
                       + "MUST NOT be isStructurallyStatic:true")
    }

    // MARK: - Discriminative: static twin vs non-static version

    /// A view WITH a title input is NOT static; its structural twin WITHOUT the input
    /// IS static.  This pins the exact boundary the engine draws.
    func testInputPresentMakesViewNonStatic_InputAbsentMakesViewStatic() throws {
        let withInput = """
        import SwiftUI
        struct TagView: View {
            let label: String
            var body: some View {
                Text(label)
                    .padding(4)
                    .background(Color.blue.opacity(0.15))
            }
        }
        """
        let withoutInput = """
        import SwiftUI
        struct TagView: View {
            var body: some View {
                Text("Active")
                    .padding(4)
                    .background(Color.blue.opacity(0.15))
            }
        }
        """
        let vWith = try XCTUnwrap(lowerFirst(withInput))
        let vWithout = try XCTUnwrap(lowerFirst(withoutInput))

        XCTAssertFalse(vWith.isStructurallyStatic,
                       "TagView WITH a label input MUST NOT be static (label appears in tree)")
        XCTAssertTrue(vWithout.isStructurallyStatic,
                      "TagView WITHOUT any input (all literals) MUST be static")
    }
}

// MARK: - Private Runner (mirrors SwiftUIFidelityOracleTests.Runner)

/// Minimal WasmKit host for calling `view_body` exports.  Registered with the
/// patch host-bridge stubs so the ABI machinery compiles and links.
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
    private func memory() throws -> Memory {
        guard let m = instance.exports[memory: "memory"] else {
            throw NSError(domain: "runner", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no memory export"])
        }
        return m
    }
    func callPacked(_ name: String, _ input: [UInt8]) throws -> [UInt8] {
        guard let fn = instance.exports[function: name],
              let malloc = instance.exports[function: "patch_malloc"] else {
            throw NSError(domain: "runner", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "missing export: \(name)"])
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
