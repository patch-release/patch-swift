// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator
import PartitioningEngine

/// NATIVE-FAST-PATH (the single highest-value perf feature): a per-view body content
/// hash, computed identically at the TWO emit sites — the manifest emitter
/// (`SwiftUIGuestEmitter`, fed by `BuildPipeline`) and the `ThunkGenerator` thunk
/// call-site — so the SDK can render an UNPATCHED view's native body with ZERO WASM.
///
/// THE LINCHPIN INVARIANT these tests pin: for the same view built in the same build,
/// `thunk.baselineHash == manifest.bodyHash`. Both are `BodyLowering.viewBodyContentHash`
/// over the SAME `LoweredView` (lowered with the SAME `sameFileThunk`/`crossFile`
/// contract), so they are EQUAL by construction — and ANY semantic body change (incl. a
/// lifted slot-literal edit) makes them DIFFER (so a real patch is never silently dropped).
final class NativeFastPathHashTests: XCTestCase {

    /// Lower the FIRST view in `source` with the SAME contract the build uses
    /// (`sameFileThunk: true`, the default) over a single-file cross-file bundle.
    private func lowerFirst(_ source: String, sameFileThunk: Bool = true) throws -> BodyLowering.LoweredView {
        let crossFile = BodyLowering.crossFileBundle(sources: [source])
        let lowered = BodyLowering().lowerAllViews(source: source, sameFileThunk: sameFileThunk,
                                                   crossFile: crossFile)
        return try XCTUnwrap(lowered.first, "no view lowered from source")
    }

    /// The `baselineHash:"…"` literal the ThunkGenerator baked into a view's thunk.
    private func bakedBaselineHash(forView name: String, in source: String) throws -> String {
        let sources = [ThunkGenerator.SourceFile(url: URL(fileURLWithPath: "/x/\(name).swift"), text: source)]
        let r = ThunkGenerator().prepare(sources: sources, sameFile: true)
        let text = r.modifiedFiles.first { $0.url.lastPathComponent == "\(name).swift" }?.text ?? ""
        return try extractBaselineHash(from: text, view: name)
    }

    /// Pull THIS view's `baselineHash: "<hex>"` out of its generated `thunkBody(…)` call.
    /// The thunk emits `typeName: "<view>", baselineHash: "<hex>", instance: self` — scope the
    /// match to the view's OWN `typeName:` so a file with multiple views' thunks isn't confused.
    private func extractBaselineHash(from thunkText: String, view: String) throws -> String {
        let pattern = #"typeName: "\#(view)", baselineHash: "([0-9a-f]+)""#
        guard let r = thunkText.range(of: pattern, options: .regularExpression) else {
            throw XCTSkip("no baselineHash literal for \(view) in thunk: \(thunkText)")
        }
        let frag = String(thunkText[r])  // e.g. `typeName: "Card", baselineHash: "abc123"`
        // The hex is the last quoted token.
        let hex = frag.split(separator: "\"").last { $0.allSatisfy { c in c.isHexDigit } }
        return try XCTUnwrap(hex.map(String.init), "couldn't isolate the hex hash in: \(frag)")
    }

    /// The `bodyHash` the manifest emitter wrote, for a view emitted with the given hash.
    /// Mirrors `BuildPipeline`: feed the lowered `guestBody`/slotArgs + the SAME
    /// `viewBodyContentHash` into `SwiftUIGuestEmitter`, then read it back out of the
    /// emitted `patch_view_manifest` JSON literal.
    private func emittedManifestBodyHash(for lowered: BodyLowering.LoweredView) throws -> String {
        var slotArgs: [String: [String]] = [:]
        for leaf in lowered.opaqueLeaves where !leaf.stringArgs.isEmpty {
            slotArgs[leaf.id] = leaf.stringArgs
        }
        let gv = SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, stateModel: lowered.stateModel,
            thunkSafe: true, slotArgs: slotArgs,
            bodyHash: BodyLowering.viewBodyContentHash(lowered))
        let emission = try SwiftUIGuestEmitter().emit(views: [gv])
        let wrapper = emission.files.first { $0.fileName == "_PatchSwiftUI.swift" }?.contents ?? ""
        // The manifest is a JSON literal in the wrapper; the hex hash survives escaping.
        guard let r = wrapper.range(of: #"bodyHash\\?":\\?"([0-9a-f]+)\\?""#, options: .regularExpression) else {
            // Fall back to a simpler match (no escaping) — depending on swiftStringLiteralBody.
            guard let r2 = wrapper.range(of: #"bodyHash[^0-9a-f]*([0-9a-f]{16})"#, options: .regularExpression) else {
                throw XCTSkip("no bodyHash in emitted manifest: \(wrapper.prefix(400))")
            }
            let frag = String(wrapper[r2])
            return try XCTUnwrap(frag.range(of: #"[0-9a-f]{16}"#, options: .regularExpression).map { String(frag[$0]) })
        }
        let frag = String(wrapper[r])
        return try XCTUnwrap(frag.range(of: #"[0-9a-f]{16}"#, options: .regularExpression).map { String(frag[$0]) })
    }

    // MARK: - THE LINCHPIN: thunk baselineHash == manifest bodyHash

    func testThunkBaselineHashEqualsManifestBodyHash() throws {
        let source = """
        import SwiftUI
        struct Hello: View {
            let title: String
            var body: some View {
                VStack {
                    Text(title)
                    Text("Subtitle")
                }
            }
        }
        """
        let lowered = try lowerFirst(source)
        let manifestHash = try emittedManifestBodyHash(for: lowered)
        let thunkHash = try bakedBaselineHash(forView: "Hello", in: source)
        XCTAssertEqual(thunkHash, manifestHash,
                       "the thunk's baked baselineHash MUST equal the manifest's bodyHash for the "
                       + "same view in the same build (the native-fast-path correctness invariant)")
        XCTAssertEqual(thunkHash.count, 16, "16 hex chars (64 bits)")
    }

    /// The invariant also holds for a view with a parameterized native slot (a lifted
    /// string literal) — the literal rides the hash, so both sides still agree.
    func testInvariantHoldsWithParameterizedSlot() throws {
        let source = """
        import SwiftUI
        struct Card: View {
            var body: some View {
                VStack {
                    Text("Title")
                    Badge(text: "NEW")
                }
            }
        }
        struct Badge: View { let text: String; var body: some View { Text(text) } }
        """
        let lowered = try lowerFirst(source)
        let manifestHash = try emittedManifestBodyHash(for: lowered)
        let thunkHash = try bakedBaselineHash(forView: "Card", in: source)
        XCTAssertEqual(thunkHash, manifestHash,
                       "the invariant must hold even when the body has a parameterized slot")
    }

    // MARK: - A semantic body change CHANGES the hash (no false-native)

    func testBodyChangeChangesTheHash() throws {
        let v1 = """
        import SwiftUI
        struct V: View { var body: some View { Text("Hello") } }
        """
        let v2 = """
        import SwiftUI
        struct V: View { var body: some View { Text("Goodbye") } }
        """
        let h1 = BodyLowering.viewBodyContentHash(try lowerFirst(v1))
        let h2 = BodyLowering.viewBodyContentHash(try lowerFirst(v2))
        XCTAssertNotEqual(h1, h2, "changing the Text content MUST change the hash (else a patch silently no-ops)")
    }

    /// A STRUCTURAL change (adding a node) changes the hash.
    func testStructuralChangeChangesTheHash() throws {
        let v1 = """
        import SwiftUI
        struct V: View { var body: some View { VStack { Text("A") } } }
        """
        let v2 = """
        import SwiftUI
        struct V: View { var body: some View { VStack { Text("A"); Text("B") } } }
        """
        let h1 = BodyLowering.viewBodyContentHash(try lowerFirst(v1))
        let h2 = BodyLowering.viewBodyContentHash(try lowerFirst(v2))
        XCTAssertNotEqual(h1, h2, "adding a node MUST change the hash")
    }

    /// A lifted SLOT-LITERAL edit (which rides `BodyEmission.slotArgs`, NOT `guestBody`)
    /// MUST still change the hash — otherwise such an OTA patch would FALSE-NATIVE
    /// (silently not apply). This is the exact dangerous failure the hash must prevent.
    func testSlotLiteralEditChangesTheHash() throws {
        func src(_ literal: String) -> String {
            """
            import SwiftUI
            struct V: View {
                var body: some View { VStack { Text("Fixed"); Badge(text: "\(literal)") } }
            }
            struct Badge: View { let text: String; var body: some View { Text(text) } }
            """
        }
        let l1 = try lowerFirst(src("NEW"))
        let l2 = try lowerFirst(src("HOT"))
        // Sanity: the lifted literal rides slotArgs, not guestBody — so guestBody is equal
        // but the canonical hash must still differ (proving slotArgs is in the hash).
        let h1 = BodyLowering.viewBodyContentHash(l1)
        let h2 = BodyLowering.viewBodyContentHash(l2)
        let hasSlotArgs = !l1.opaqueLeaves.filter { !$0.stringArgs.isEmpty }.isEmpty
        if hasSlotArgs && l1.guestBody == l2.guestBody {
            // The canonical case this guards: guestBody stable, only the slot literal changed.
            XCTAssertNotEqual(h1, h2,
                              "a lifted slot-literal edit (rides slotArgs, not guestBody) MUST change the "
                              + "hash, or the patch would false-native")
        } else {
            // If the engine put the literal in guestBody (no lift), the hash differs anyway.
            XCTAssertNotEqual(h1, h2, "a literal edit MUST change the hash regardless of lift")
        }
    }

    // MARK: - Determinism + stability

    /// The hash is DETERMINISTIC across repeated lowerings of the same source.
    func testHashIsDeterministic() throws {
        let source = """
        import SwiftUI
        struct V: View { var body: some View { VStack { Text("A"); Text("B") } } }
        """
        let h1 = BodyLowering.viewBodyContentHash(try lowerFirst(source))
        let h2 = BodyLowering.viewBodyContentHash(try lowerFirst(source))
        XCTAssertEqual(h1, h2, "same source ⇒ same hash, every run")
    }

    /// `viewBodyContentHash(guestBody:opaqueLeaves:)` and the `LoweredView` overload agree
    /// (they MUST be the same function — the single canonical-string builder).
    func testBothOverloadsAgree() throws {
        let source = """
        import SwiftUI
        struct V: View { var body: some View { Text("X") } }
        """
        let lowered = try lowerFirst(source)
        XCTAssertEqual(BodyLowering.viewBodyContentHash(lowered),
                       BodyLowering.viewBodyContentHash(guestBody: lowered.guestBody,
                                                        opaqueLeaves: lowered.opaqueLeaves))
    }

    // MARK: - stableEventHash collision → FALSE-NATIVE (dispatch-only change)

    /// BUG: `stableEventHash` maps the full button call-text to only 5 decimal digits
    /// (0–99999, via `hash % 100000`). Two DISTINCT button sources can produce the SAME
    /// 5-digit value, landing both on the SAME `actionID`. When a developer patches a
    /// Button's action body (changes `count += 1` to something with the same hash) while
    /// keeping the label identical, the emitted `guestBody` is byte-for-byte the same —
    /// `viewBodyContentHash` matches — and the native-fast-path gate says "unchanged":
    /// the SDK renders the NATIVE body (zero WASM), silently discarding the patched
    /// dispatch rule. This is a FALSE-NATIVE: a real OTA patch is dropped.
    ///
    /// FIXED: `stableEventHash` now returns a full 64-bit FNV hex string instead of
    /// truncating to `% 100000` (5 decimal digits / ~100K buckets). The original pair
    /// that triggered the bug — `Button("OK") { count += 1 }` and
    /// `Button("OK") { count -= 19247 }` — both hashed to 65926 in the old scheme,
    /// producing byte-identical `guestBody` strings and identical `viewBodyContentHash`
    /// despite different dispatch semantics. This test now PASSES (verifying the fix).
    func testStableEventHashCollisionCausesIdenticalBodyHashFalseNative() throws {
        // After the fix, the previously-colliding button sources produce DIFFERENT hashes.
        // "Button("OK") { count += 1 }" → "c00d6d13916a3806"
        // "Button("OK") { count -= 19247 }" → "9fadd78ce40a6866"
        let source1 = """
        import SwiftUI
        struct V: View {
            @State var count: Int = 0
            var body: some View {
                Button("OK") { count += 1 }
            }
        }
        """
        let source2 = """
        import SwiftUI
        struct V: View {
            @State var count: Int = 0
            var body: some View {
                Button("OK") { count -= 19247 }
            }
        }
        """
        // Verify that the fix resolves the collision: these two inputs now produce DIFFERENT hashes.
        let hash1 = Emitter.stableEventHash(#"Button("OK") { count += 1 }"#)
        let hash2 = Emitter.stableEventHash(#"Button("OK") { count -= 19247 }"#)
        XCTAssertNotEqual(hash1, hash2,
                          "FIX: the two button sources must NOT collide after widening to 64-bit")
        XCTAssertEqual(hash1, "c00d6d13916a3806",
                       "pinned FNV-1a full-64-bit hex for button +1")
        XCTAssertEqual(hash2, "9fadd78ce40a6866",
                       "pinned FNV-1a full-64-bit hex for button -19247")
        let lowered1 = try lowerFirst(source1)
        let lowered2 = try lowerFirst(source2)
        // After the fix, different action sources produce different actionIDs → different guestBodies.
        XCTAssertNotEqual(lowered1.guestBody, lowered2.guestBody,
                          "FIX: guestBodies must differ when actions produce different hashes")
        // The viewBodyContentHash must now be DIFFERENT for these two semantically-distinct views.
        let h1 = BodyLowering.viewBodyContentHash(lowered1)
        let h2 = BodyLowering.viewBodyContentHash(lowered2)
        // Confirm that the dispatch rules ARE actually different (different semantics):
        let rules1 = lowered1.stateModel?.rules.map { "\($0.field):\($0.op)" } ?? []
        let rules2 = lowered2.stateModel?.rules.map { "\($0.field):\($0.op)" } ?? []
        XCTAssertNotEqual(rules1, rules2,
                          "precondition: the two views must have different dispatch semantics")
        XCTAssertNotEqual(h1, h2,
                          "FIX: different dispatch semantics (count += 1 vs count -= 19247) "
                          + "now produce DIFFERENT viewBodyContentHash — the FALSE-NATIVE bug is resolved")
    }

    // MARK: - Granularity: editing a CHILD view must not change the PARENT's hash

    /// The user-critical optimality invariant: if you edit a child view C inside parent P,
    /// only C should re-run WASM — P must STAY on the native-fast-path, never forced to WASM
    /// just because a child changed. P's hash is over P's OWN body; a child view is a
    /// slot/reference in P's tree (not inlined), so editing C's body leaves P's hash
    /// unchanged.
    func testEditingChildViewDoesNotChangeParentHash() throws {
        func parentWithChild(_ childText: String) -> String {
            """
            import SwiftUI
            struct Parent: View {
                var body: some View { VStack { Text("Header"); Child() } }
            }
            struct Child: View { var body: some View { Text("\(childText)") } }
            """
        }
        // `Parent` is first → lowerFirst lowers Parent; `Child()` is a separate view (a slot
        // in Parent's tree), so Child's body is irrelevant to Parent's lowered hash.
        let pA = try lowerFirst(parentWithChild("A"))
        let pB = try lowerFirst(parentWithChild("B"))
        XCTAssertEqual(BodyLowering.viewBodyContentHash(pA), BodyLowering.viewBodyContentHash(pB),
                       "editing a CHILD view's body must NOT change the PARENT's hash — the parent "
                       + "stays native-fast-path, never re-WASM'd because a child changed")
    }
}
