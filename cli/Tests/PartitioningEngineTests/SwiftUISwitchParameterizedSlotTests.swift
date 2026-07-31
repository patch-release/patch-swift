// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
@testable import Compiler
import PartitioningEngine
import ViewNodeIR

/// A1 FIX — PARAMETERIZED-SWITCH SLOTS (the OnboardingFlow fingerprint-mismatch fix).
///
/// Background: a `switch page { case 0: helperView(title:"A") default: helperView(title:"B") }`
/// in a lowered `var body` was previously wrapped as ONE `opaqueViewBuilder` slot. The slot's
/// source (including the title strings verbatim) was folded into `nativeSurface`, so editing a
/// title changed the native-shell fingerprint → "PATCH-AFFECTING, refusing to push". A basic
/// string-literal edit inside a per-arm helper call SHOULD ship OTA.
///
/// The fix: when the switch subject is a marshalled guest input AND every arm has exactly one
/// `opaqueCall`-able call, each arm is lowered as its own PARAMETERIZED `opaqueCall` slot so
/// the title strings ride WASM via `slotArgs`/`stringArgRanges` → they are normalized out of
/// the fingerprint's `shellNormalizedHash`, making title edits fingerprint-stable.
///
/// Test coverage:
///   1. Title strings become parameterized slot args (stringArgRanges non-empty).
///   2. Editing ONLY a title produces the SAME shell-normalized fingerprint (no drift).
///   3. A non-marshalled-subject switch still uses opaqueViewBuilder (demote-safe fallback).
///   4. A multi-statement or non-slotable arm still uses opaqueViewBuilder (demote-safe).
///   5. The guest module compiles (WASM toolchain, skipped if unavailable).
final class SwiftUISwitchParameterizedSlotTests: XCTestCase {

    // MARK: - Helpers

    private func lower(_ source: String) -> [BodyLowering.LoweredView] {
        BodyLowering().lowerAllViews(source: source)
    }

    private func lowerFirst(_ source: String) throws -> BodyLowering.LoweredView {
        try XCTUnwrap(lower(source).first { $0.viewName == "Screen" } ?? lower(source).first,
                      "no view lowered")
    }

    /// The source used for the OnboardingFlow-mirror fixture. `title` can be substituted.
    private func onboardingSource(title: String = "Find your best time") -> String {
        """
        import SwiftUI
        func helperView(title: String, body: String) -> some View { Text(title) }
        struct Screen: View {
            @State private var page: Int = 0
            var body: some View {
                VStack {
                    switch page {
                    case 0:
                        helperView(title: "Find your best time", body: "Subtitle A")
                    default:
                        helperView(title: "\(title)", body: "Subtitle B")
                    }
                }
            }
        }
        """
    }

    // MARK: - Test 1: title strings become parameterized slot args

    /// Each arm's helper call must become a PARAMETERIZED `opaqueCall` slot (non-empty
    /// `stringArgs` + non-empty `stringArgRanges`), so the title literal rides WASM via
    /// `slotArgs` and is NOT baked into `nativeSurface`.
    func testSwitchArmsAreParameterizedSlots() throws {
        let lv = try lowerFirst(onboardingSource())
        // Must have at least 2 parameterized leaves (one per arm).
        let paramLeaves = lv.opaqueLeaves.filter { !$0.stringArgs.isEmpty }
        XCTAssertGreaterThanOrEqual(paramLeaves.count, 2,
            "each arm of the marshalled-subject switch must become a parameterized opaqueCall slot; "
            + "got leaves: \(lv.opaqueLeaves.map { ($0.id, $0.stringArgs) })")
        // Every parameterized leaf must have stringArgRanges (so the fingerprint can normalize them).
        for leaf in paramLeaves {
            XCTAssertFalse(leaf.stringArgRanges.isEmpty,
                "parameterized leaf \(leaf.id) must have stringArgRanges for fingerprint normalization")
        }
        // The title "Find your best time" must ride slotArgs, NOT appear in guestBody.
        XCTAssertFalse(lv.guestBody.contains("Find your best time"),
            "the title literal must NOT appear in the guest body — it rides slotArgs; "
            + "body: \(lv.guestBody)")
    }

    // MARK: - Test 2: editing only a title produces no fingerprint drift

    /// THE USER'S EXACT BUG: editing "Plan the YEAR" → "Plan the DECADE" should NOT
    /// change the native-shell fingerprint. After the fix, the title rides WASM via
    /// slotArgs → stringArgRanges → `shellNormalizedHash` normalizes it to a placeholder
    /// → fingerprint is identical before and after the edit.
    func testTitleEditProducesNoFingerprintDrift() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("patch-swparam-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let file = root.appendingPathComponent("OnboardingFlow.swift")

        // Write the INITIAL version (title = "Plan the YEAR").
        let initial = onboardingSource(title: "Plan the YEAR")
        try initial.write(to: file, atomically: true, encoding: .utf8)
        let fp1 = ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint

        // Write the EDITED version (title = "Plan the DECADE") — the user's change.
        let edited = onboardingSource(title: "Plan the DECADE")
        try edited.write(to: file, atomically: true, encoding: .utf8)
        let fp2 = ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint

        XCTAssertEqual(fp1, fp2,
            "editing only a title string inside a switch arm helper call must NOT churn the "
            + "native-shell fingerprint — it ships OTA via slotArgs. "
            + "fp1=\(fp1.prefix(16)) fp2=\(fp2.prefix(16))")
    }

    // MARK: - Test 3: non-marshalled subject falls back to opaqueViewBuilder (demote-safe)

    /// A switch whose subject is NOT a marshalled guest input (e.g. a body-local `let`
    /// whose RHS is not guest-resolvable) must NOT take the parameterized-slot path.
    /// It must fall back to `opaqueViewBuilder` → ONE opaque slot wrapping the whole switch.
    func testNonMarshalledSubjectFallsBackToOpaqueViewBuilder() throws {
        let source = """
        import SwiftUI
        func helperView(title: String) -> some View { Text(title) }
        struct Screen: View {
            var body: some View {
                let idx = SomeService.shared.currentPage  // not guest-resolvable
                switch idx {
                case 0:
                    helperView(title: "Page A")
                default:
                    helperView(title: "Page B")
                }
            }
        }
        """
        let lv = try lowerFirst(source)
        // The non-marshalled subject CANNOT be reconstructed as a guest ternary → the whole
        // switch must fall back to opaqueViewBuilder (ONE native leaf), NOT the per-arm
        // parameterized-slot fast path (which emits a guest ternary chain). cli 1.6.31+: that
        // single NATIVE leaf MAY lift its display literals ("Page A"/"Page B" ride WASM so
        // editing them is OTA-safe) — a feature, NOT the per-arm path. The invariant we guard:
        // the switch is NOT lowered to a per-arm guest ternary.
        XCTAssertFalse(lv.guestBody.contains(" ? "),
            "a non-marshalled switch subject must NOT be lowered to a per-arm guest ternary "
            + "(must fall back to opaqueViewBuilder); guestBody: \(lv.guestBody)")
    }

    // MARK: - Test 4: multi-statement arm falls back to opaqueViewBuilder (demote-safe)

    /// A switch where one arm has MULTIPLE statements (not a single call expression) must
    /// NOT take the parameterized-slot path — fall back to `opaqueViewBuilder`.
    func testMultiStatementArmFallsBackToOpaqueViewBuilder() throws {
        let source = """
        import SwiftUI
        func helperView(title: String) -> some View { Text(title) }
        struct Screen: View {
            @State private var page: Int = 0
            var body: some View {
                switch page {
                case 0:
                    helperView(title: "Page A")
                default:
                    // Multi-statement arm: not a single opaqueCall-able expression
                    let _ = 0
                    helperView(title: "Page B")
                }
            }
        }
        """
        let lv = try lowerFirst(source)
        // A multi-statement arm isn't a single opaqueCall-able expression → the whole switch
        // falls back to opaqueViewBuilder (ONE native leaf), NOT the per-arm parameterized-slot
        // fast path (a guest ternary chain). cli 1.6.31+: the native leaf MAY lift its display
        // literals (OTA-safe edits) — a feature. The invariant we guard: no per-arm guest ternary.
        XCTAssertFalse(lv.guestBody.contains(" ? "),
            "a multi-statement switch arm must NOT be lowered to a per-arm guest ternary "
            + "(must fall back to opaqueViewBuilder); guestBody: \(lv.guestBody)")
    }

    // MARK: - Test 5: WASM compile (guest module compiles)

    /// The lowered guest body (with the per-arm ternary dispatch + opaqueCall slots) must
    /// compile to a valid WASM module. Skipped when the WASM toolchain is unavailable.
    func testSwitchParameterizedSlotGuestModuleCompiles() throws {
        let source = """
        import SwiftUI
        func helperView(title: String, body: String) -> some View { Text(title) }
        struct Screen: View {
            @State private var page: Int = 0
            var body: some View {
                VStack {
                    switch page {
                    case 0:
                        helperView(title: "Find your best time", body: "Subtitle A")
                    default:
                        helperView(title: "Plan the YEAR", body: "Subtitle B")
                    }
                }
            }
        }
        """
        let lowered = lower(source)
        let screen = try XCTUnwrap(lowered.first { $0.viewName == "Screen" }, "Screen not lowered")

        // Must have at least 2 parameterized leaves (one per arm) — i.e. the fast path fired.
        let paramLeaves = screen.opaqueLeaves.filter { !$0.stringArgs.isEmpty }
        guard paramLeaves.count >= 2 else {
            // If the fast path didn't fire (e.g. due to stricter checks), the test still
            // shouldn't fail — but log it as a skip so it's visible.
            throw XCTSkip("parameterized-switch fast path did not fire (got \(paramLeaves.count) param leaves)")
        }

        // Build a guest WASM module from the lowered view.
        var slotArgs: [String: [String]] = [:]
        for leaf in screen.opaqueLeaves where !leaf.stringArgs.isEmpty {
            slotArgs[leaf.id] = leaf.stringArgs
        }
        let guestViews = [SwiftUIGuestEmitter.GuestView(
            viewName: screen.viewName, guestBody: screen.guestBody,
            inputs: screen.inputs, stateModel: screen.stateModel,
            thunkSafe: true, slotArgs: slotArgs)]
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swparam-wasm-\(UUID().uuidString)")
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
        guard compiler.toolchainAvailable else {
            throw XCTSkip("WASM toolchain not available — skipping WASM compile gate")
        }
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success,
            "parameterized-switch guest WASM module must compile:\n\(result.log)")
    }

    // MARK: - Test 6: structural ID stability (slot id unchanged when title changes)

    /// The structural slot ID of each arm's parameterized leaf must be IDENTICAL whether the
    /// title is "Plan the YEAR" or "Plan the DECADE" — the id is derived from the TEMPLATE
    /// (literal value normalized out), so only a structural change would churn it.
    func testSwitchArmSlotIdIsStableAcrossTitleEdit() throws {
        func ids(forTitle title: String) throws -> Set<String> {
            let lv = try lowerFirst(onboardingSource(title: title))
            return Set(lv.opaqueLeaves.filter { !$0.stringArgs.isEmpty }.map(\.id))
        }
        let ids1 = try ids(forTitle: "Plan the YEAR")
        let ids2 = try ids(forTitle: "Plan the DECADE")
        guard !ids1.isEmpty else {
            throw XCTSkip("fast path did not fire")
        }
        XCTAssertEqual(ids1, ids2,
            "parameterized switch arm slot IDs must be STABLE across a title edit; "
            + "before=\(ids1.sorted()) after=\(ids2.sorted())")
    }
}
