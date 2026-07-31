// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// BEHAVIORAL-FIDELITY ORACLE — a reusable "war-chest" test harness (not always
/// run) that catches SILENT SEMANTIC DIVERGENCE between a SwiftUI view's NATIVE
/// body and its WASM-lowered body.
///
/// WHY THIS EXISTS
/// ----------------
/// The coverage suite measures "did this view LOWER" (no opaque leaves, guest
/// module compiles). It does NOT measure "does the lowered body RENDER the same
/// thing the native body would". A lowering can be perfectly "covered" yet
/// quietly wrong: an interpolation that drops a value, a host-token that resolves
/// to the wrong slot, a conditional that flips its branch, a ForEach that emits
/// the wrong number of rows. Those are SEMANTIC divergences — invisible to the
/// "lowered: yes" signal, fatal to the user.
///
/// THE ORACLE
/// ----------
/// `ViewNode.describe()` is a stable, total structural transcript of a rendered
/// tree (it recurses every child + every modifier — see `Describe.swift`). The
/// renderer is a pure function of the tree, so two trees that describe identically
/// render identically. The native body's rendered tree is the REFERENCE; the
/// WASM-built tree must MATCH it for every input. We encode the reference as an
/// EXPECTED SNAPSHOT (the structural transcript a correct lowering must produce)
/// and assert equality per input. A mismatch is a divergence = a hard failure
/// with a line-level diff.
///
/// HOW IT RUNS (mirrors `SwiftUILoweringTests.testViewBodyExecutesInWasm`)
/// ----------------------------------------------------------------------
///   1. lower the fixture's source via `BodyLowering`
///   2. emit + compile the guest module to WASM via `SwiftUIGuestEmitter` +
///      `SwiftWasmCompiler` (SKIPS cleanly when the swift.org WASM toolchain is
///      absent — exactly like the existing `*ExecutesInWasm` tests)
///   3. instantiate in WasmKit (`Runner`, the shared minimal host) and call the
///      `view_body` export over each input JSON
///   4. decode the `BodyEmission` and assert `root.describe()` == the snapshot,
///      and the self-reported opaque-node count matches the fixture's contract
///
/// The harness is DETERMINISTIC: `describe()` is order-stable, the host bridges
/// are pure, and each fixture pins its own inputs + snapshots — no clocks, no RNG,
/// no shared mutable state across cases.
final class SwiftUIFidelityOracleTests: XCTestCase {

    // MARK: - Fixture model

    /// A host-token value to inject. The build-time thunk's `__patchTokens()` would
    /// resolve the real native expression (`Theme.Radius.lg` → 16, `confidence.label`
    /// → "High"); the harness simulates that by merging the value into the guest
    /// input JSON under the token's REAL reserved key — which it resolves at runtime
    /// from `lowered.hostTokens` (the id is content-derived, never hard-coded). The
    /// `index` selects among multiple tokens of the same kind (source-order).
    struct TokenBinding {
        let kind: BodyLowering.HostToken.Kind
        let index: Int
        let value: String   // raw JSON value, e.g. "16" or "\"High\""
        init(_ kind: BodyLowering.HostToken.Kind, index: Int = 0, value: String) {
            self.kind = kind; self.index = index; self.value = value
        }
    }

    /// One input → its expected rendered-tree transcript.
    struct Case {
        let name: String
        /// The marshalled input JSON for the view's DECLARED inputs (`name`, `count`).
        /// Host-token reserved keys are NOT put here — they're supplied via
        /// `tokenBindings` and merged with their real (content-derived) keys.
        let inputJSON: String
        /// Host-token values to merge under their real reserved keys.
        let tokenBindings: [TokenBinding]
        /// The EXACT `root.describe()` a faithful lowering must produce. This is
        /// the "native reference" — what SwiftUI would render for this input.
        /// Opaque-slot ids (content hashes) are NORMALIZED to `#SLOT` before the
        /// comparison so the snapshot stays stable across content-id churn while
        /// still pinning the slot's POSITION + label.
        let expectedDescribe: String
        /// Substrings that MUST appear in the raw emission JSON (host-token /
        /// modifier-content payloads `describe()` doesn't recurse into). Empty by
        /// default.
        let mustContainInJSON: [String]
        init(_ name: String, inputJSON: String, tokenBindings: [TokenBinding] = [],
             expectedDescribe: String, mustContainInJSON: [String] = []) {
            self.name = name
            self.inputJSON = inputJSON
            self.tokenBindings = tokenBindings
            self.expectedDescribe = expectedDescribe
            self.mustContainInJSON = mustContainInJSON
        }
    }

    /// A view fixture + its behavioral contract.
    struct Fixture {
        let name: String
        let source: String
        /// Expected number of OPAQUE (native-slot) nodes in the lowered tree. The
        /// oracle asserts the guest's self-reported `coverage.opaqueNodes` matches —
        /// a lowering that silently slots a leaf it should have lowered (or vice
        /// versa) is itself a divergence.
        let expectedOpaqueNodes: Int
        /// Expected count of host tokens, per kind, the engine must record for this
        /// view. Pins the host-projection decision itself — a shape that was meant to
        /// string-token but silently SLOTS (or vice versa) is caught here, BEFORE the
        /// WASM run. Empty kinds are not asserted.
        let expectedTokenCounts: [BodyLowering.HostToken.Kind: Int]
        let cases: [Case]
        init(name: String, source: String, expectedOpaqueNodes: Int,
             expectedTokenCounts: [BodyLowering.HostToken.Kind: Int] = [:],
             cases: [Case]) {
            self.name = name
            self.source = source
            self.expectedOpaqueNodes = expectedOpaqueNodes
            self.expectedTokenCounts = expectedTokenCounts
            self.cases = cases
        }
    }

    /// The lowered metadata the harness threads through (token keys, etc.).
    private struct Built {
        let runner: Runner
        let lowered: BodyLowering.LoweredView
    }

    // MARK: - The reusable harness

    /// Lower → emit → compile → instantiate, returning a runner + the lowered
    /// metadata. Returns nil after issuing `XCTSkip` when the toolchain is absent.
    /// `file`/`line` propagate the caller's location for clean failure attribution.
    private func buildRunner(for fixture: Fixture,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> Built? {
        let lowering = BodyLowering()
        let loweredAll = lowering.lowerAllViews(source: fixture.source, sameFileThunk: true)
        guard let lowered = loweredAll.first else {
            XCTFail("[\(fixture.name)] lowered NO view from the fixture source", file: file, line: line)
            return nil
        }

        // CONTRACT: the host-projection DECISION must match. A shape meant to
        // string-/numeric-token that silently slots (or vice versa) is a divergence
        // the oracle catches here — before the WASM run.
        for (kind, expected) in fixture.expectedTokenCounts {
            let actual = lowered.hostTokens.filter { $0.kind == kind }.count
            XCTAssertEqual(actual, expected,
                "[\(fixture.name)] host-token count for \(kind) drifted — host-projection decision changed. all tokens: \(lowered.hostTokens.map { "\($0.kind):\($0.source)" })",
                file: file, line: line)
        }
        // The same routing gate the BuildPipeline applies: a view is thunk-safe iff
        // every opaque leaf is slotable AND it reads no unmarshalled input (or it
        // routes via an indexed-row slot).
        let thunkSafe = (lowered.opaqueLeaves.allSatisfy { $0.slotable }
                         && !lowered.referencesUnmarshalledInput)
                        || !lowered.indexedRowSlots.isEmpty

        let guestView = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName,
            guestBody: lowered.guestBody,
            inputs: lowered.inputs,
            stateModel: lowered.stateModel,
            thunkSafe: thunkSafe,
            usesGeometry: lowered.usesGeometry,
            inputTokens: lowered.hostTokens.filter { $0.ridesInputJSON })
        let emission = try SwiftUIGuestEmitter().emit(views: [guestView])

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
            "swift.org WASM toolchain not installed — skipping fidelity-oracle execution for \(fixture.name)")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-fidelity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }

        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.swiftui.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success,
            "[\(fixture.name)] guest WASM compile failed:\n\(result.log)", file: file, line: line)
        guard result.status == .success else { return nil }

        let wasm = [UInt8](try Data(contentsOf: out))
        return Built(runner: try Runner(wasm: wasm), lowered: lowered)
    }

    /// Build the per-case input JSON: the declared-input JSON merged with each
    /// token binding under the token's REAL reserved key (resolved from the lowered
    /// metadata). Fails the case if a binding can't be matched to a recorded token.
    private func inputJSON(for c: Case, lowered: BodyLowering.LoweredView,
                           fixtureName: String,
                           file: StaticString, line: UInt) -> String {
        guard !c.tokenBindings.isEmpty else { return c.inputJSON }
        var pairs: [String] = []
        for b in c.tokenBindings {
            let matches = lowered.hostTokens.filter { $0.kind == b.kind }
            guard b.index < matches.count else {
                XCTFail("[\(fixtureName)/\(c.name)] no \(b.kind) token #\(b.index) recorded (have \(matches.count))",
                        file: file, line: line)
                continue
            }
            pairs.append("\"\(matches[b.index].inputKey)\":\(b.value)")
        }
        // Splice the token pairs into the declared-input object.
        let base = c.inputJSON.trimmingCharacters(in: .whitespaces)
        let inner = String(base.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        let body = inner.isEmpty ? pairs.joined(separator: ",")
                                 : ([inner] + pairs).joined(separator: ",")
        return "{\(body)}"
    }

    /// Normalize opaque-slot ids (content hashes like `#op_327b0a535a507f7e`) to a
    /// stable `#SLOT` token so the snapshot pins the slot's POSITION + label without
    /// pinning a churning content hash. Applies to both the `Opaque(#…)` node form
    /// and the `.opaque(#…)` modifier form.
    private func normalizeSlotIDs(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "#" {
                let after = s.index(after: i)
                // an opaque id starts with `op_`; replace the whole `#op_<hex>` run.
                if s[after...].hasPrefix("op_") {
                    out += "#SLOT"
                    var j = s.index(after, offsetBy: 3)
                    while j < s.endIndex, s[j].isHexDigit { j = s.index(after: j) }
                    i = j
                    continue
                }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }

    /// Run a whole fixture: for each input, execute `view_body` in WASM and assert
    /// the rendered-tree transcript EXACTLY matches the snapshot. Any drift fails
    /// with the side-by-side transcripts.
    private func runFidelity(_ fixture: Fixture,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        guard let built = try buildRunner(for: fixture, file: file, line: line) else { return }
        let runner = built.runner
        for c in fixture.cases {
            let json = inputJSON(for: c, lowered: built.lowered,
                                 fixtureName: fixture.name, file: file, line: line)
            let outBytes: [UInt8]
            do {
                outBytes = try runner.callPacked("view_body", [UInt8](Data(json.utf8)))
            } catch {
                XCTFail("[\(fixture.name)/\(c.name)] view_body threw: \(error)", file: file, line: line)
                continue
            }
            XCTAssertFalse(outBytes.isEmpty,
                "[\(fixture.name)/\(c.name)] view_body returned no bytes", file: file, line: line)
            guard !outBytes.isEmpty else { continue }

            let body: BodyEmission
            do {
                body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
            } catch {
                XCTFail("[\(fixture.name)/\(c.name)] BodyEmission decode failed: \(error)\nraw: \(String(decoding: outBytes, as: UTF8.self))",
                        file: file, line: line)
                continue
            }

            // (1) STRUCTURAL FIDELITY: the WASM-built tree must MATCH the native
            //     reference transcript for this input (slot ids normalized).
            let actual = normalizeSlotIDs(body.root.describe())
            if actual != c.expectedDescribe {
                XCTFail("""
                    DIVERGENCE — [\(fixture.name)/\(c.name)] WASM tree ≠ native reference.
                    input: \(json)
                    ---- EXPECTED (native reference) ----
                    \(c.expectedDescribe)
                    ---- ACTUAL (WASM-lowered) ----
                    \(actual)
                    \(firstDiffLine(expected: c.expectedDescribe, actual: actual))
                    """, file: file, line: line)
            }

            // (2) COVERAGE FIDELITY: the opaque-node count must match the contract —
            //     a silent slot (or un-slot) is a divergence too.
            if let cov = body.coverage {
                XCTAssertEqual(cov.opaqueNodes, fixture.expectedOpaqueNodes,
                    "[\(fixture.name)/\(c.name)] opaque-node count drifted (tree:\n\(actual))",
                    file: file, line: line)
            }

            // (3) PAYLOAD FIDELITY: host-token / modifier-content payloads that
            //     `describe()` doesn't recurse into.
            let emittedJSON = String(decoding: outBytes, as: UTF8.self)
            for needle in c.mustContainInJSON {
                XCTAssertTrue(emittedJSON.contains(needle),
                    "[\(fixture.name)/\(c.name)] expected emission JSON to contain `\(needle)`:\n\(emittedJSON)",
                    file: file, line: line)
            }
        }
    }

    /// Report the first transcript line that differs (line-level diff for the
    /// failure message — keeps the oracle's output actionable).
    private func firstDiffLine(expected: String, actual: String) -> String {
        let e = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let a = actual.split(separator: "\n", omittingEmptySubsequences: false)
        for i in 0..<max(e.count, a.count) {
            let el = i < e.count ? String(e[i]) : "<missing>"
            let al = i < a.count ? String(a[i]) : "<missing>"
            if el != al {
                return "first diff @ line \(i):\n  expected: \(el)\n  actual:   \(al)"
            }
        }
        return "(no line-level diff found — likely trailing whitespace)"
    }

    // MARK: - FIXTURES (host-projection / slot-risk shapes)

    /// 1) TEXT + INTERPOLATION — the canonical "did the marshalled value survive
    ///    the round-trip" case. A dropped/garbled interpolation is the most common
    ///    silent divergence.
    private static let textInterpolation = Fixture(
        name: "TextInterpolation",
        source: """
        import SwiftUI
        struct Greeting: View {
            let name: String
            let count: Int
            var body: some View {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hello, \\(name)!")
                        .font(.title)
                    Text("You have \\(count) items")
                        .foregroundColor(.secondary)
                }
            }
        }
        """,
        expectedOpaqueNodes: 0,
        cases: [
            Case("ada",
                inputJSON: #"{"name":"Ada","count":3}"#,
                expectedDescribe: """
                VStack(align:leading,spacing:4.0)
                  Text("Hello, Ada!") .font(title)
                  Text("You have 3 items") .fg(secondary)
                """),
            // A DIFFERENT input must produce a DIFFERENT, correct tree — proving the
            // values genuinely flow through WASM, not baked at lower-time.
            Case("grace",
                inputJSON: #"{"name":"Grace","count":42}"#,
                expectedDescribe: """
                VStack(align:leading,spacing:4.0)
                  Text("Hello, Grace!") .font(title)
                  Text("You have 42 items") .fg(secondary)
                """),
            // Empty string + zero — edge values must still round-trip exactly.
            Case("empty",
                inputJSON: #"{"name":"","count":0}"#,
                expectedDescribe: """
                VStack(align:leading,spacing:4.0)
                  Text("Hello, !") .font(title)
                  Text("You have 0 items") .fg(secondary)
                """),
        ])

    /// 1b) NON-ASCII (multi-byte UTF-8) TEXT — a Japanese-shipping app (Masahiro's
    ///     report). A static non-ASCII `Text("録画品質")` must round-trip through the
    ///     WASM guest → `EmbeddedJSON` wire → host decode BYTE-EXACT, exactly like an
    ///     ASCII literal. Covers short + long multi-byte literals, ASCII siblings, AND
    ///     an interpolation that MIXES non-ASCII static segments with a marshalled input.
    private static let nonASCIIText = Fixture(
        name: "NonASCIIText",
        source: """
        import SwiftUI
        struct RecordingSettings: View {
            let owner: String
            var body: some View {
                VStack(alignment: .leading, spacing: 12) {
                    Text("録画品質")
                    Text("解像度とビットレート")
                    Text("Bitrate")
                    Text("オーナー: \\(owner)")
                }
            }
        }
        """,
        expectedOpaqueNodes: 0,
        cases: [
            Case("taro",
                inputJSON: #"{"owner":"タロウ"}"#,
                expectedDescribe: """
                VStack(align:leading,spacing:12.0)
                  Text("録画品質")
                  Text("解像度とビットレート")
                  Text("Bitrate")
                  Text("オーナー: タロウ")
                """,
                mustContainInJSON: ["録画品質", "解像度とビットレート"]),
            // A DIFFERENT non-ASCII input must flow through WASM (not baked): proves the
            // marshalled value survives the UTF-8 round-trip, not just the static literal.
            Case("emoji",
                inputJSON: #"{"owner":"李明 🎬"}"#,
                expectedDescribe: """
                VStack(align:leading,spacing:12.0)
                  Text("録画品質")
                  Text("解像度とビットレート")
                  Text("Bitrate")
                  Text("オーナー: 李明 🎬")
                """,
                mustContainInJSON: ["李明 🎬"]),
        ])

    /// 2) CONDITIONAL (`if flag`) — branch selection driven by a marshalled Bool.
    ///    A flipped/stuck branch is a divergence the "lowered" signal misses.
    private static let conditional = Fixture(
        name: "ConditionalFlag",
        source: """
        import SwiftUI
        struct Banner: View {
            let isPremium: Bool
            let title: String
            var body: some View {
                VStack {
                    Text(title)
                    if isPremium {
                        Text("PRO")
                            .font(.caption)
                    } else {
                        Text("Free")
                    }
                }
            }
        }
        """,
        expectedOpaqueNodes: 0,
        cases: [
            Case("premium",
                inputJSON: #"{"isPremium":true,"title":"Plan"}"#,
                expectedDescribe: """
                VStack(align:center,spacing:nil)
                  Text("Plan")
                  Text("PRO") .font(caption)
                """),
            Case("free",
                inputJSON: #"{"isPremium":false,"title":"Plan"}"#,
                expectedDescribe: """
                VStack(align:center,spacing:nil)
                  Text("Plan")
                  Text("Free")
                """),
        ])

    /// 3) FOREACH over a scalar array input — the row COUNT and per-row content
    ///    must track the marshalled array exactly. An off-by-one / dropped row is
    ///    a divergence.
    private static let forEachScalar = Fixture(
        name: "ForEachScalarArray",
        source: """
        import SwiftUI
        struct TagList: View {
            let tags: [String]
            var body: some View {
                VStack {
                    ForEach(tags, id: \\.self) { tag in
                        Text(tag)
                    }
                }
            }
        }
        """,
        expectedOpaqueNodes: 0,
        cases: [
            Case("three",
                inputJSON: #"{"tags":["swift","wasm","ota"]}"#,
                expectedDescribe: """
                VStack(align:center,spacing:nil)
                  ForEach
                    Text("swift")
                    Text("wasm")
                    Text("ota")
                """),
            Case("one",
                inputJSON: #"{"tags":["solo"]}"#,
                expectedDescribe: """
                VStack(align:center,spacing:nil)
                  ForEach
                    Text("solo")
                """),
            Case("empty",
                inputJSON: #"{"tags":[]}"#,
                expectedDescribe: """
                VStack(align:center,spacing:nil)
                  ForEach
                """),
        ])

    /// 4) NUMERIC HOST-TOKEN — a design-system numeric constant in a `.padding`
    ///    position rides the input JSON as `__numtok_*`; the host resolves it. The
    ///    oracle marshals the resolved value and asserts it lands in the modifier.
    private static let numericToken = Fixture(
        name: "NumericHostToken",
        source: """
        import SwiftUI
        enum Theme { enum Radius { static let lg: CGFloat = 16 } }
        struct Card: View {
            let label: String
            var body: some View {
                Text(label)
                    .padding(Theme.Radius.lg)
            }
        }
        """,
        expectedOpaqueNodes: 0,
        expectedTokenCounts: [.number: 1],
        cases: [
            // The host (thunk's __patchTokens) would resolve Theme.Radius.lg → 16;
            // the harness marshals that resolved value under the token's REAL reserved
            // key (resolved at runtime from lowered.hostTokens — the id is a hash).
            Case("resolved16",
                inputJSON: #"{"label":"Hi"}"#,
                tokenBindings: [TokenBinding(.number, value: "16")],
                expectedDescribe: """
                Text("Hi") .padding(t:16.0,l:16.0,b:16.0,tr:16.0)
                """),
            // A DIFFERENT host-resolved value flows through — proving the token is
            // genuinely READ in WASM, not frozen at lower-time.
            Case("resolved8",
                inputJSON: #"{"label":"Hi"}"#,
                tokenBindings: [TokenBinding(.number, value: "8")],
                expectedDescribe: """
                Text("Hi") .padding(t:8.0,l:8.0,b:8.0,tr:8.0)
                """),
        ])

    /// 5) STRING HOST-TOKEN — an enum/host-derived `Text(...)` content the guest
    ///    can't reconstruct rides as `__strtok_*`; the host resolves the real String.
    ///    The oracle proves the resolved String lands in the Text node and the leaked
    ///    enum value does NOT appear. The `.uppercased()` tail makes the expression a
    ///    PROVABLE String (per the v1.6.3 type-provability allowlist), so the engine
    ///    string-tokens it instead of SLOTTING — which the `expectedTokenCounts`
    ///    contract pins. (A bare `confidence.label` with no type catalog stays a
    ///    native slot — the honest "demote over an unfillable slot" invariant.)
    private static let stringToken = Fixture(
        name: "StringHostToken",
        source: """
        import SwiftUI
        enum Confidence { case high, low
            var label: String { self == .high ? "High" : "Low" }
        }
        struct Pill: View {
            let confidence: Confidence
            var body: some View {
                Text(confidence.label.uppercased())
                    .font(.caption)
            }
        }
        """,
        expectedOpaqueNodes: 0,
        expectedTokenCounts: [.string: 1],
        cases: [
            // The host resolves `confidence.label.uppercased()` → the real String;
            // the harness marshals it under the token's REAL reserved key.
            Case("high",
                inputJSON: "{}",
                tokenBindings: [TokenBinding(.string, value: "\"HIGH\"")],
                expectedDescribe: """
                Text("HIGH") .font(caption)
                """,
                mustContainInJSON: ["HIGH"]),
            Case("low",
                inputJSON: "{}",
                tokenBindings: [TokenBinding(.string, value: "\"LOW\"")],
                expectedDescribe: """
                Text("LOW") .font(caption)
                """,
                mustContainInJSON: ["LOW"]),
        ])

    /// 6) MIXED VIEW WITH NATIVE SLOT — a body that lowers MOST of its tree but
    ///    contains a non-lowerable leaf (a custom child view). The lowerable
    ///    structure must ride WASM and the custom leaf must become exactly ONE
    ///    opaque slot — not silently dropped, not silently swallowing the whole
    ///    view. The oracle pins the slot's POSITION in the tree.
    private static let mixedWithSlot = Fixture(
        name: "MixedViewNativeSlot",
        source: """
        import SwiftUI
        struct Row: View {
            let title: String
            var body: some View {
                HStack {
                    Text(title)
                    Spacer()
                    CustomBadge(count: 5)
                }
            }
        }
        """,
        expectedOpaqueNodes: 1,
        cases: [
            Case("hello",
                inputJSON: #"{"title":"Inbox"}"#,
                expectedDescribe: """
                HStack(align:center,spacing:nil)
                  Text("Inbox")
                  Spacer
                  Opaque(#SLOT,CustomBadge)
                """),
        ])

    /// 7) NESTED CONTAINER + MODIFIER STACK — a deeper tree (the ProfileCard shape)
    ///    exercises modifier ORDER preservation and Toggle/Image leaf fidelity. A
    ///    reordered or dropped modifier is a divergence.
    private static let nestedModifierStack = Fixture(
        name: "NestedModifierStack",
        source: """
        import SwiftUI
        struct ProfileCard: View {
            let name: String
            var notificationsOn: Bool = true
            var body: some View {
                VStack(alignment: .leading, spacing: 12) {
                    Text(name)
                        .font(.title)
                        .bold()
                    Text("Engineer")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack {
                        Image(systemName: "star.fill")
                        Spacer()
                        Toggle("Notifications", isOn: $notificationsOn)
                    }
                    .padding(8)
                }
                .padding(16)
                .background(.gray)
                .cornerRadius(12)
            }
        }
        """,
        expectedOpaqueNodes: 0,
        cases: [
            Case("ada-on",
                inputJSON: #"{"name":"Ada Lovelace","notificationsOn":true}"#,
                expectedDescribe: """
                VStack(align:leading,spacing:12.0) .padding(t:16.0,l:16.0,b:16.0,tr:16.0) .bg(gray) .corner(12.0)
                  Text("Ada Lovelace") .font(title) .bold
                  Text("Engineer") .font(subheadline) .fg(secondary)
                  HStack(align:center,spacing:nil) .padding(t:8.0,l:8.0,b:8.0,tr:8.0)
                    Image(systemName:"star.fill")
                    Spacer
                    Toggle(isOn:true,event:#notificationsOn)
                      Text("Notifications")
                """),
            // Same shape, OFF — proves the marshalled `notificationsOn` genuinely
            // drives the Toggle's `isOn` in WASM (not the literal default).
            Case("grace-off",
                inputJSON: #"{"name":"Grace Hopper","notificationsOn":false}"#,
                expectedDescribe: """
                VStack(align:leading,spacing:12.0) .padding(t:16.0,l:16.0,b:16.0,tr:16.0) .bg(gray) .corner(12.0)
                  Text("Grace Hopper") .font(title) .bold
                  Text("Engineer") .font(subheadline) .fg(secondary)
                  HStack(align:center,spacing:nil) .padding(t:8.0,l:8.0,b:8.0,tr:8.0)
                    Image(systemName:"star.fill")
                    Spacer
                    Toggle(isOn:false,event:#notificationsOn)
                      Text("Notifications")
                """),
        ])

    // MARK: - All fixtures

    private static let allFixtures: [Fixture] = [
        textInterpolation, conditional, forEachScalar,
        numericToken, stringToken, mixedWithSlot, nestedModifierStack,
    ]

    // MARK: - Tests (one per fixture, so a divergence names the shape)
    //
    // Each runs lower → emit → compile-to-WASM → host-run → structural-compare.
    // They SKIP cleanly (XCTSkip) when the swift.org WASM toolchain is absent — so
    // this whole oracle is a no-op on a host-only machine / CI without the toolchain,
    // exactly like the existing `*ExecutesInWasm` tests.

    func testFidelity_TextInterpolation() throws { try runFidelity(Self.textInterpolation) }
    func testFidelity_NonASCIIText() throws { try runFidelity(Self.nonASCIIText) }

    /// DIAGNOSTIC (env-driven, opt-in): run `view_body` on an ARBITRARY module.wasm
    /// (e.g. one produced by the REAL `patchcli build` incl. `wasm-opt -Oz`) and assert
    /// its emitted JSON contains an expected needle. Set PATCH_WASM (path), PATCH_INPUT
    /// (input JSON, default `{}`), PATCH_NEEDLE (substring). No-ops when PATCH_WASM unset.
    func testDiag_RunArbitraryModule() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PATCH_WASM"] else { throw XCTSkip("PATCH_WASM unset") }
        let wasm = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let runner = try Runner(wasm: wasm)
        let input = env["PATCH_INPUT"] ?? "{}"
        let out = try runner.callPacked("view_body", [UInt8](Data(input.utf8)))
        let json = String(decoding: out, as: UTF8.self)
        FileHandle.standardError.write(Data("VIEW_BODY_JSON: \(json)\n".utf8))
        if let needle = env["PATCH_NEEDLE"] {
            XCTAssertTrue(json.contains(needle),
                "expected view_body JSON to contain \(needle):\n\(json)")
        }
    }
    func testFidelity_ConditionalFlag() throws { try runFidelity(Self.conditional) }
    func testFidelity_ForEachScalarArray() throws { try runFidelity(Self.forEachScalar) }
    func testFidelity_NumericHostToken() throws { try runFidelity(Self.numericToken) }
    func testFidelity_StringHostToken() throws { try runFidelity(Self.stringToken) }
    func testFidelity_MixedViewNativeSlot() throws { try runFidelity(Self.mixedWithSlot) }
    func testFidelity_NestedModifierStack() throws { try runFidelity(Self.nestedModifierStack) }

    /// META (toolchain-FREE, always runs): every fixture's source must parse + lower
    /// to exactly one view whose host-projection DECISION matches its declared
    /// `expectedTokenCounts` and `expectedOpaqueNodes`. This guards the fixtures
    /// themselves (a fixture that stops lowering — e.g. an engine change demotes its
    /// whole body — would otherwise silently SKIP its WASM run on a no-toolchain CI
    /// and look "green"); it runs the host-side lowering only, no WASM.
    func testFidelity_AllFixturesLowerWithExpectedProjection() throws {
        let lowering = BodyLowering()
        for fixture in Self.allFixtures {
            let lowered = lowering.lowerAllViews(source: fixture.source, sameFileThunk: true)
            guard let v = lowered.first else {
                XCTFail("[\(fixture.name)] lowered NO view — fixture no longer lowers")
                continue
            }
            for (kind, expected) in fixture.expectedTokenCounts {
                let actual = v.hostTokens.filter { $0.kind == kind }.count
                XCTAssertEqual(actual, expected,
                    "[\(fixture.name)] \(kind)-token count drifted (tokens: \(v.hostTokens.map { "\($0.kind):\($0.source)" }))")
            }
            // The opaque-leaf count (host-side) must match the WASM-reported contract.
            XCTAssertEqual(v.opaqueLeaves.count, fixture.expectedOpaqueNodes,
                "[\(fixture.name)] opaque-leaf count drifted (leaves: \(v.opaqueLeaves.map { $0.label }))")
        }
    }

    // MARK: - Shared minimal WASM runner (mirrors SwiftUILoweringTests.Runner)

    final class Runner {
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
                throw NSError(domain: "abi", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "missing export \(name)"])
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
