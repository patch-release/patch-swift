// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// Regression tests for the SwiftUI guest-module SCOPE GUARD — the #1 real-app fix.
///
/// The body lowering emits scalar/condition values VERBATIM from the developer's
/// source. That is correct only when every identifier the verbatim expression
/// references is in scope in the guest `_patchBuildTree__<View>` function. A
/// reference to a FREE identifier the guest can't resolve compiles to `cannot find
/// 'X' in scope`, and because every view export shares ONE `_PatchSwiftUI.swift`
/// wrapper, that single error demotes the WHOLE module and ships ZERO views.
///
/// Several constructs that ORIGINALLY demoted the AppA views now LOWER instead
/// (the coverage extensions): a design-system NUMERIC static (`Theme.Radius.lg`) and a
/// computed scalar property in a numeric position become NUMERIC HOST TOKENS (the
/// build-time thunk resolves them natively → a Double the guest reads from its input
/// JSON), and a non-guest-safe input DEFAULT (`Locale.current.…`) is SANITIZED to the
/// type-appropriate zero (the SDK marshals the live value in regardless). What still
/// demotes: a dropped body-local `let` whose RHS isn't guest-computable (`let owners =
/// schedule.…`) and a body reading a non-reconstructable enum/struct/Foundation value.
///
/// These tests assert (a) the constructs that now lower do NOT flag
/// `referencesUnresolvedSymbol` (and record the right token / sanitized default),
/// (b) the genuinely-unlowerable ones still ARE flagged so the BuildPipeline excludes
/// just them, (c) clean views are NOT flagged, and (d) end-to-end a MIXED set (clean +
/// offending) compiles and SHIPS the clean views' exports rather than declining.
final class SwiftUIGuestScopeCheckTests: XCTestCase {

    private func lower(_ source: String, view: String,
                       sameFileThunk: Bool = true) throws -> BodyLowering.LoweredView {
        let all = BodyLowering().lowerAllViews(source: source, sameFileThunk: sameFileThunk)
        return try XCTUnwrap(all.first { $0.viewName == view }, "view \(view) not lowered")
    }

    // MARK: - The four real-app demote causes (each must be flagged)

    /// `var height: CGFloat { width * 0.66 }` — a COMPUTED scalar property in a
    /// numeric position (`.frame(height: …)`). It used to DEMOTE the view (free
    /// `height`); it now LOWERS as a NUMERIC HOST TOKEN — the build-time thunk
    /// evaluates `height` natively over `self` (it sees `self.width`), so no free
    /// `height` survives. `width` (a marshalled input) stays verbatim.
    func testComputedPropertyInScalarPositionLowersAsNumericToken() throws {
        let source = """
        import SwiftUI
        struct Onboard1Illustration: View {
            var width: CGFloat = 304
            var height: CGFloat { width * 0.66 }
            var body: some View {
                Rectangle().frame(width: width, height: height)
            }
        }
        """
        let lowered = try lower(source, view: "Onboard1Illustration")
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
                       "a computed scalar in a numeric position now lowers via a numeric token, "
                       + "unresolved: \(lowered.unresolvedSymbols)")
        let numTokens = lowered.hostTokens.filter { $0.kind == .number }
        XCTAssertEqual(numTokens.count, 1, "the computed `height` becomes one numeric token")
        XCTAssertEqual(numTokens.first?.source, "height")
        // `width` IS a marshalled input — it stays verbatim, not a token.
        XCTAssertTrue(lowered.guestBody.contains("width: Double(width)"),
                      "the `width` input stays verbatim: \(lowered.guestBody)")
    }

    /// A dropped body-local `let` referenced by a sibling node in a NON-projectable way
    /// (here a `.frame(width: owners.first?.width ?? 0)` numeric position that isn't a
    /// `.count`/`.isEmpty` collection guard) still leaks the free identifier `owners` →
    /// the view demotes. (The `owners.count > 1` GUARD case now host-projects — see
    /// `testDroppedBodyLocalCollectionGuardNowHostProjects` — but an arbitrary body-local
    /// value read is still the demote-safety guard.)
    func testDroppedBodyLocalLetIsFlagged() throws {
        let source = """
        import SwiftUI
        struct WidthReader: View {
            let schedule: Schedule
            var body: some View {
                let owners = schedule.availableOwners
                Text("hi").frame(width: owners.first.width)
            }
        }
        """
        let lowered = try lower(source, view: "WidthReader")
        XCTAssertTrue(lowered.referencesUnresolvedSymbol,
                      "a dropped body-local `let` read in a non-projectable position must demote")
        XCTAssertTrue(lowered.unresolvedSymbols.contains("owners"),
                      "the unresolved symbol is `owners`: \(lowered.unresolvedSymbols)")
        // `owners` is a body-LOCAL, not the view's own private member — so it is NOT
        // the inaccessible-member wall (a same-file thunk wouldn't unblock it). The
        // precise diagnostic must NOT misattribute it to a private read.
        XCTAssertTrue(lowered.inaccessibleReadNames.isEmpty,
                      "a dropped body-local `let` is not an inaccessible-member read: \(lowered.inaccessibleReadNames)")
    }

    /// COVERAGE (per-row indexed slot, IR v8): a body-local-collection COUNT GUARD
    /// (`let owners = schedule.availableOwners; if owners.count > 1 { … }`) now
    /// HOST-PROJECTS — `owners.count` resolves to a numeric token
    /// (`(schedule.availableOwners).count`), so `owners` no longer leaks and the view
    /// LOWERS instead of demoting. (Was the `AccountSwitcher` blocker.)
    func testDroppedBodyLocalCollectionGuardNowHostProjects() throws {
        let source = """
        import SwiftUI
        struct AccountSwitcher: View {
            let schedule: Schedule
            var body: some View {
                let owners = schedule.availableOwners
                if owners.count > 1 {
                    Text("multi")
                }
            }
        }
        """
        let lowered = try lower(source, view: "AccountSwitcher")
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
                       "the count guard host-projects, so `owners` no longer leaks: \(lowered.unresolvedSymbols)")
        XCTAssertFalse(lowered.unresolvedSymbols.contains("owners"))
        let numTokens = lowered.hostTokens.filter { $0.kind == .number }
        XCTAssertEqual(numTokens.first?.source, "(schedule.availableOwners).count",
                       "the `owners.count` guard becomes a numeric count token: \(numTokens.map(\.source))")
        XCTAssertTrue(lowered.guestBody.contains("__numtok_"),
                      "the guest body reads the count token: \(lowered.guestBody)")
    }

    // MARK: - The "inaccessible-member wall" (cross-file thunk × private member)

    /// A `private @Environment`/`@State` service read inside a host-resolvable
    /// position (here a `Text(…)` string interpolation in an alert message). With a
    /// SEPARATE-file thunk (`sameFileThunk: false`) this BLOCKS the view — not because
    /// the value can't be reconstructed, but because it would have to be host-resolved by
    /// the generated thunk, which lives in a SEPARATE file and (Swift file-scoped private)
    /// can't see the private member. This mirrors the real AppA `SettingsScreen`
    /// blocker: `private var schedule` read in the alert message's
    /// `\(max(1, schedule.connections.count * 20))` interpolation. The view stays native,
    /// and `inaccessibleReadNames` names the precise cause.
    func testPrivateMemberReadFlaggedAsInaccessibleWallSeparateFile() throws {
        let lowered = try lower(Self.settingsScreenSource, view: "SettingsScreen",
                                sameFileThunk: false)
        // The view is blocked (the alert message reads `schedule`, a non-reconstructable
        // private @Environment, in the lowered tree).
        XCTAssertTrue(lowered.referencesUnmarshalledInput || lowered.referencesUnresolvedSymbol,
                      "a private-member read in a lowered string must block a SEPARATE-file thunk view")
        // The precise cause: `schedule` is the view's OWN private member → the
        // inaccessible-member wall (a same-file thunk would unblock it; a cross-file one
        // can't). This is what makes the diagnostic accurate.
        XCTAssertEqual(lowered.inaccessibleReadNames, ["schedule"],
                       "the blocking read is the private `schedule`: \(lowered.inaccessibleReadNames)")
    }

    /// THE UNBLOCK. The SAME view, lowered for a SAME-FILE thunk (the default), LOWERS:
    /// the thunk now lives in the view's own file, so its `__patchTokens()` can read the
    /// `private schedule` natively → a host STRING token the SDK merges into the guest
    /// input JSON. No longer blocked, and no inaccessible-member wall remains. This is the
    /// unit-level proof of the same-file fix (the real-build proof is SettingsScreen
    /// lowering AppA 44→45).
    func testPrivateMemberReadLowersWithSameFileThunk() throws {
        let lowered = try lower(Self.settingsScreenSource, view: "SettingsScreen",
                                sameFileThunk: true)
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "same-file: the private read host-resolves, so no unmarshalled-input block")
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
                       "same-file: the private read host-resolves, so no out-of-scope symbol")
        XCTAssertTrue(lowered.inaccessibleReadNames.isEmpty,
                      "same-file: the inaccessible-member wall does not exist: \(lowered.inaccessibleReadNames)")
        // It recorded a host STRING token for the private interpolation — the thunk
        // resolves `schedule.connections.count` natively over `self`.
        XCTAssertTrue(lowered.guestBody.contains("__strtok_") || lowered.guestBody.contains("schedule"),
                      "same-file: the private interpolation host-resolves as a string token: \(lowered.guestBody)")
    }

    private static let settingsScreenSource = """
    import SwiftUI
    struct SettingsScreen: View {
        @Environment(ScheduleService.self) private var schedule
        @State private var showAlert = false
        var body: some View {
            VStack {
                Text("Settings")
            }
            .alert("Rebuild?", isPresented: $showAlert) {
                Button("OK") {}
            } message: {
                Text("Takes about \\(max(1, schedule.connections.count * 20)) seconds.")
            }
        }
    }
    """

    /// A PRIVATE non-reconstructable enum `@State` read. With a SEPARATE-file thunk it
    /// BLOCKS the view AND is the inaccessible-member wall (`status` is the view's own
    /// private member) — distinguishing it from a body-local block (empty wall, see
    /// `testDroppedBodyLocalLetIsFlagged`).
    func testPrivateEnumStateReadIsInaccessibleWallSeparateFile() throws {
        let source = """
        import SwiftUI
        struct StatusView: View {
            enum Status { case on, off }
            @State private var status: Status = .on
            var body: some View {
                Text(status == .on ? "On" : "Off")
            }
        }
        """
        let lowered = try lower(source, view: "StatusView", sameFileThunk: false)
        XCTAssertTrue(lowered.referencesUnmarshalledInput || lowered.referencesUnresolvedSymbol,
                      "a private enum @State read must block a SEPARATE-file thunk view")
        XCTAssertEqual(lowered.inaccessibleReadNames, ["status"],
                       "the blocking read is the private `status`: \(lowered.inaccessibleReadNames)")
    }

    /// A CLEAN view that reads only marshalled scalar inputs has NO inaccessible-member
    /// wall — no false positive. (The diagnostic field is empty for any view that ships.)
    func testCleanViewHasEmptyInaccessibleReads() throws {
        let source = """
        import SwiftUI
        struct Clean: View {
            let title: String = "Hi"
            @State private var count: Int = 0
            var body: some View {
                VStack {
                    Text(title)
                    Text("count=\\(count)")
                }
            }
        }
        """
        let lowered = try lower(source, view: "Clean")
        XCTAssertFalse(lowered.referencesUnmarshalledInput)
        XCTAssertFalse(lowered.referencesUnresolvedSymbol)
        XCTAssertTrue(lowered.inaccessibleReadNames.isEmpty,
                      "a clean view must have no inaccessible-member wall: \(lowered.inaccessibleReadNames)")
    }

    /// `cornerRadius: grid ? Theme.Radius.md : Theme.Radius.pill` — a design-system
    /// numeric static (CGFloat) in a NUMERIC position. It used to DEMOTE (free
    /// `Theme`); it now LOWERS as a NUMERIC HOST TOKEN (the thunk resolves the whole
    /// ternary natively → a Double the guest reads from its input JSON). `label`/`grid`
    /// (marshalled inputs) keep their roles — `grid` rides into the token's native eval.
    func testDesignSystemStaticInNumericPositionLowersAsNumericToken() throws {
        let source = """
        import SwiftUI
        struct SelectableChip: View {
            let label: String
            let grid: Bool
            var body: some View {
                Text(label)
                    .background(
                        RoundedRectangle(cornerRadius: grid ? Theme.Radius.md : Theme.Radius.pill)
                            .fill(.gray)
                    )
            }
        }
        """
        let lowered = try lower(source, view: "SelectableChip")
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
                       "a design-system numeric static now lowers via a numeric token, "
                       + "unresolved: \(lowered.unresolvedSymbols)")
        XCTAssertEqual(lowered.hostTokens.filter { $0.kind == .number }.count, 1,
                       "the ternary radius becomes one numeric token")
        XCTAssertTrue(lowered.guestBody.contains("roundedRectangle(cornerRadius: Double(__numtok_"),
                      "the shape's radius reads the numeric token: \(lowered.guestBody)")
    }

    /// `@State var code = Locale.current.region?.identifier ?? "US"` — a Foundation
    /// type in an UNANNOTATED `private` input's default. The default can't be inferred as
    /// a scalar, so the input is `.unsupported`. With a SEPARATE-file thunk, reading it
    /// in a `Text(...)` leaks a live reference to a non-reconstructable private member the
    /// cross-file thunk can't slot, so the view is excluded (`referencesUnmarshalledInput`).
    func testFoundationTypeInUntypedInputDefaultDemotesSeparateFile() throws {
        let source = """
        import SwiftUI
        struct SurveyFlow: View {
            @State private var specificCountryCode = Locale.current.region?.identifier ?? "US"
            var body: some View {
                Text(specificCountryCode)
            }
        }
        """
        let lowered = try lower(source, view: "SurveyFlow", sameFileThunk: false)
        XCTAssertTrue(lowered.referencesUnmarshalledInput || lowered.referencesUnresolvedSymbol,
                      "separate-file: a view reading an unsupported Foundation-defaulted private "
                      + "input must not ship")
    }

    /// THE SAME view, with a SAME-FILE thunk (the default), SHIPS — faithfully. The
    /// `Text(specificCountryCode)` over the non-reconstructable private member is SLOTTED
    /// (rendered natively by the thunk's `__patchSlots()` closure, which CAN read the
    /// private member because it's in the view's own file). The view is no longer blocked:
    /// its other elements ride WASM (patchable) while that one Text renders native — never
    /// a wrong value. This is the same-file unblock applied to a Foundation-bound read.
    func testFoundationTypeInUntypedInputDefaultSlotsAndShipsSameFile() throws {
        let source = """
        import SwiftUI
        struct SurveyFlow: View {
            @State private var specificCountryCode = Locale.current.region?.identifier ?? "US"
            var body: some View {
                VStack {
                    Text("Survey")
                    Text(specificCountryCode)
                }
            }
        }
        """
        let lowered = try lower(source, view: "SurveyFlow", sameFileThunk: true)
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "same-file: the private Foundation read slots, so no unmarshalled-input block")
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
                       "same-file: no out-of-scope symbol leaks (the read is slotted)")
        // The private Text is a native slot (an opaque leaf) — faithful, not a wrong value.
        XCTAssertTrue(lowered.guestBody.contains("N.opaque"),
                      "same-file: the private Foundation Text is slotted: \(lowered.guestBody)")
        XCTAssertTrue(lowered.opaqueLeaves.contains { $0.slotable },
                      "same-file: the slotted leaf is renderable by the thunk over self")
    }

    /// A TYPED input (`String`) whose default is a Foundation expression
    /// (`Locale.current.…`) IS bound (a known scalar kind). The default used to leak
    /// `Locale` into the guest binding and DEMOTE the view; now the engine SANITIZES a
    /// non-guest-safe default to the type-appropriate zero (`""`) — the SDK marshals the
    /// live value in at runtime regardless, so nothing is lost and the view SHIPS.
    func testFoundationTypeInTypedInputDefaultIsSanitizedAndLowers() throws {
        let source = """
        import SwiftUI
        struct RegionView: View {
            var code: String = Locale.current.identifier
            var body: some View {
                Text(code)
            }
        }
        """
        let lowered = try lower(source, view: "RegionView")
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
                       "a Foundation-typed input default is sanitized, not a demote cause, "
                       + "unresolved: \(lowered.unresolvedSymbols)")
        // The default was replaced with the zero string — no `Locale` survives.
        let codeInput = try XCTUnwrap(lowered.inputs.first { $0.name == "code" })
        XCTAssertEqual(codeInput.defaultLiteral, "\"\"",
                       "the non-guest-safe default is replaced by the zero string")
        XCTAssertEqual(lowered.hostTokens.count, 0, "no token needed — the body reads the input")
    }

    /// A guest-SAFE typed default (a plain literal) is preserved verbatim — sanitization
    /// only rewrites a default that references a free identifier, never a safe one.
    func testGuestSafeTypedInputDefaultIsPreserved() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var code: String = "US"
            var count: Int = 3
            var body: some View { Text(code) }
        }
        """
        let lowered = try lower(source, view: "V")
        XCTAssertFalse(lowered.referencesUnresolvedSymbol)
        XCTAssertEqual(lowered.inputs.first { $0.name == "code" }?.defaultLiteral, "\"US\"",
                       "a safe string default is preserved")
        XCTAssertEqual(lowered.inputs.first { $0.name == "count" }?.defaultLiteral, "3",
                       "a safe int default is preserved")
    }

    // MARK: - Clean views must NOT be flagged (no false positives)

    /// A simple, fully-marshalled view (the AppA `AccountChip`/`BodyText`
    /// shape) must NOT be flagged — its body references only inputs + IR + stdlib.
    func testCleanViewNotFlagged() throws {
        let source = """
        import SwiftUI
        struct AccountChip: View {
            let label: String
            let selected: Bool
            var body: some View {
                HStack(spacing: 8) {
                    Text(label).foregroundColor(selected ? .blue : .gray)
                }
                .padding(.horizontal, 14)
            }
        }
        """
        let lowered = try lower(source, view: "AccountChip")
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
                       "a fully-marshalled clean view must not be flagged: \(lowered.unresolvedSymbols)")
        XCTAssertTrue(lowered.unresolvedSymbols.isEmpty)
    }

    /// A view using stdlib free functions (`max`/`Double`) + IR types in scalar
    /// positions must NOT be flagged (those are safe globals).
    func testStdlibGlobalsNotFlagged() throws {
        let source = """
        import SwiftUI
        struct Bar: View {
            let pct: Int
            var body: some View {
                Rectangle().frame(width: Double(max(pct, 1)), height: 10)
            }
        }
        """
        let lowered = try lower(source, view: "Bar")
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
                       "stdlib globals (max/Double) must not be flagged: \(lowered.unresolvedSymbols)")
    }

    /// A `ForEach` over a marshalled array binds its loop var via a real `for x in`
    /// in the guest — a reference to that loop var must NOT be flagged.
    func testForEachLoopVarNotFlagged() throws {
        let source = """
        import SwiftUI
        struct ListView: View {
            let scores: [Int] = []
            var body: some View {
                VStack {
                    ForEach(scores, id: \\.self) { s in
                        Text("\\(s)")
                    }
                }
            }
        }
        """
        let lowered = try lower(source, view: "ListView")
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
                       "a ForEach loop var (bound by the emitted `for`) must not be flagged: \(lowered.unresolvedSymbols)")
    }

    // MARK: - The direct checker contract

    func testCheckerFlagsFreeMemberBaseNotMemberName() {
        // `Theme.Radius.md` must flag ONLY the base `Theme`, never `.Radius`/`.md`.
        let r = SwiftUIGuestScopeCheck.check(
            guestBody: "N.shape(.roundedRectangle(cornerRadius: Double(Theme.Radius.md)))",
            inputNames: [], usesGeometry: false)
        XCTAssertEqual(r.unresolved, ["Theme"])
    }

    func testCheckerHonorsInputAndGeoScope() {
        let body = "N.text(label).frame(width: Double(__geo_width))"
        // `label` in scope (input), `__geo_width` in scope (geo) → compilable.
        XCTAssertTrue(SwiftUIGuestScopeCheck.check(
            guestBody: body, inputNames: ["label"], usesGeometry: true).isCompilable)
        // `__geo_width` only in scope when usesGeometry — else flagged.
        XCTAssertEqual(SwiftUIGuestScopeCheck.check(
            guestBody: body, inputNames: ["label"], usesGeometry: false).unresolved,
            ["__geo_width"])
    }

    func testCheckerIgnoresOpaqueLabelStrings() {
        // An identifier appearing ONLY inside an `N.opaque(…, label: "…")` string is
        // a string literal, not a live reference — it must not be flagged.
        let body = #"N.opaque(id: "x", label: "if owners.count > 1 { Theme.Colors.ink }")"#
        XCTAssertTrue(SwiftUIGuestScopeCheck.check(
            guestBody: body, inputNames: [], usesGeometry: false).isCompilable,
            "names inside an opaque label string must not be flagged")
    }

    // MARK: - Layer 2: per-view isolation attribution (the robustness backstop)

    /// `viewsBlamedByCompileError` maps a compiler error's LINE NUMBER to the view
    /// whose emitted region contains it — so the bisecting isolation drops ONLY the
    /// offending view (re-emitting the wrapper without it) instead of demoting all
    /// exports. This is the backstop for a construct the static scope check misses.
    func testCompileErrorAttributedToOwningView() throws {
        // A miniature wrapper with two views' marker comments at known lines.
        let wrapper = """
        // header preamble line 1
        // header preamble line 2

        // Build the lowered `Alpha` tree from a flat state/inputs JSON blob.
        private func _patchBuildTree__Alpha(_ i: [UInt8]) -> ViewNode {
            return N.text("a")   // line 6
        }
        @_cdecl("view_body__Alpha")
        public func view_body__Alpha(_ p: Int32, _ l: Int32) -> Int64 { 0 }

        // Build the lowered `Beta` tree from a flat state/inputs JSON blob.
        private func _patchBuildTree__Beta(_ i: [UInt8]) -> ViewNode {
            return N.text(boom)   // line 14 — the offending reference
        }
        @_cdecl("view_body__Beta")
        public func view_body__Beta(_ p: Int32, _ l: Int32) -> Int64 { 0 }
        """
        // An error blaming line 14 (inside Beta's region) must attribute to Beta only.
        let log = """
        --- iteration 1 ---
        /tmp/x/_PatchSwiftUI.swift:14:19: error: cannot find 'boom' in scope
            return N.text(boom)
        """
        let blamed = BuildPipeline.viewsBlamedByCompileError(
            log: log, wrapperFileName: "_PatchSwiftUI.swift",
            wrapperText: wrapper, views: ["Alpha", "Beta"])
        XCTAssertEqual(blamed, ["Beta"], "the error on line 14 belongs to Beta, not Alpha")
    }

    func testCompileErrorInPreambleAttributesToNoView() throws {
        // An error BEFORE any view marker (a shared helper / preamble) attributes to no
        // view — bisection can't help, so the module declines (correct).
        let wrapper = """
        // preamble line 1
        private func _patchEmit(_ b: [UInt8]) -> Int64 { 0 }  // line 2

        // Build the lowered `Alpha` tree from a flat state/inputs JSON blob.
        private func _patchBuildTree__Alpha(_ i: [UInt8]) -> ViewNode { return N.text("a") }
        """
        let log = "/tmp/x/_PatchSwiftUI.swift:2:1: error: something broke in the preamble"
        let blamed = BuildPipeline.viewsBlamedByCompileError(
            log: log, wrapperFileName: "_PatchSwiftUI.swift",
            wrapperText: wrapper, views: ["Alpha"])
        XCTAssertEqual(blamed, [], "a preamble error is not attributable to any single view")
    }

    func testMultipleBlamedViewsAllAttributed() throws {
        let wrapper = """
        // Build the lowered `Alpha` tree from a flat state/inputs JSON blob.
        private func _patchBuildTree__Alpha(_ i: [UInt8]) -> ViewNode { return N.text(badA) }  // line 2

        // Build the lowered `Beta` tree from a flat state/inputs JSON blob.
        private func _patchBuildTree__Beta(_ i: [UInt8]) -> ViewNode { return N.text("b") }  // line 5

        // Build the lowered `Gamma` tree from a flat state/inputs JSON blob.
        private func _patchBuildTree__Gamma(_ i: [UInt8]) -> ViewNode { return N.text(badG) }  // line 8
        """
        let log = """
        /tmp/x/_PatchSwiftUI.swift:2:65: error: cannot find 'badA' in scope
        /tmp/x/_PatchSwiftUI.swift:8:65: error: cannot find 'badG' in scope
        """
        let blamed = BuildPipeline.viewsBlamedByCompileError(
            log: log, wrapperFileName: "_PatchSwiftUI.swift",
            wrapperText: wrapper, views: ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(blamed, ["Alpha", "Gamma"],
                       "both offending views attributed; the clean Beta is spared")
    }

    // MARK: - END-TO-END: a mixed set ships the clean views (the real-app proof)

    /// The crux: a file with a CLEAN view + an offending view (a `Theme.Radius` in a
    /// numeric position) must, through the real BuildPipeline, ship the CLEAN view's
    /// export — NOT decline the whole module. This is exactly the AppA failure
    /// in miniature ("46 views render natively" → at least the clean ones ship).
    func testMixedSetShipsCleanViewExportEndToEnd() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: [], tier: .t2Foundation)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping mixed-set E2E")

        // CLEAN view (must ship) + OFFENDING view (Theme.Radius in numeric position,
        // must be excluded). Both lower successfully; only the guest COMPILE differs.
        let cleanSource = """
        import SwiftUI
        struct CleanChip: View {
            let label: String
            var body: some View {
                Text(label).padding(.horizontal, 12)
            }
        }
        """
        // A still-unlowerable view: a dropped body-local `let` (`owners = …`) the emitter
        // can't bind, read by a sibling node in a NON-projectable position → free `owners`.
        // (Design-system numerics / computed scalars now LOWER via numeric tokens; the
        // `owners.count > 1` GUARD also host-projects now; so this uses an arbitrary
        // body-local VALUE read — `owners.first.width` in a `.frame(width:)` — which is
        // genuinely out of reach: it leaks `owners` as a free guest identifier.)
        let badSource = """
        import SwiftUI
        struct BadChip: View {
            let schedule: Schedule
            var body: some View {
                let owners = schedule.availableOwners
                Text("multi").frame(width: owners.first.width)
            }
        }
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-scope-e2e-\(UUID().uuidString)")
        let srcDir = tmp.appendingPathComponent("src")
        let buildDir = tmp.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try cleanSource.write(to: srcDir.appendingPathComponent("Clean.swift"),
                              atomically: true, encoding: .utf8)
        try badSource.write(to: srcDir.appendingPathComponent("Bad.swift"),
                            atomically: true, encoding: .utf8)

        let pipeline = BuildPipeline()
        let defaultModule = buildDir.appendingPathComponent("module.wasm")
        let result = try pipeline.runSwiftUILowering(
            sourceDir: srcDir, buildDir: buildDir,
            compiler: compiler, defaultModule: defaultModule)

        let lowered = try XCTUnwrap(result, "the mixed set must SHIP a module, not decline")
        XCTAssertNotNil(lowered.moduleURL)
        // The CLEAN view's export ships; the OFFENDING one does not.
        XCTAssertTrue(lowered.exports.contains("view_body__CleanChip"),
                      "the clean view must ship its export: \(lowered.exports)")
        XCTAssertFalse(lowered.exports.contains("view_body__BadChip"),
                       "the offending view must be excluded: \(lowered.exports)")

        // And the shipped module actually instantiates + renders the clean view.
        let wasm = [UInt8](try Data(contentsOf: try XCTUnwrap(lowered.moduleURL)))
        let runner = try Runner(wasm: wasm)
        let out = try runner.callPacked("view_body__CleanChip", [UInt8](Data(#"{"label":"Hi"}"#.utf8)))
        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(out))
        XCTAssertTrue(body.root.describe().contains("Hi"),
                      "the clean view renders its real label in WASM: \(body.root.describe())")
    }

    // MARK: - Demote diagnostic fix-hints

    /// A view blocked by a `private` member read that the cross-file thunk can't
    /// host-resolve: `inaccessibleReadNames` names it, confirming the data the
    /// BuildPipeline would use to emit the fix-hint ("make `<name>` internal") is correct.
    ///
    /// Pattern: a private non-reconstructable `@Environment` service used inside a
    /// string interpolation in an alert message — the emitter tries to make the
    /// interpolation a host-resolved string token, but the thunk (separate-file) can't
    /// call the private member. This is the exact same pattern as `SettingsScreen`
    /// (the real-app inaccessible-member wall), just a different service name.
    func testPrivateMemberDiagnosticPopulatesInaccessibleReadNames() throws {
        // Reuses the verified `settingsScreenSource` fixture from the existing tests.
        // We assert that `inaccessibleReadNames` is non-empty (the data the BuildPipeline
        // needs to emit the fix-hint), and confirm the same-file path leaves it empty.
        let lowered = try lower(Self.settingsScreenSource, view: "SettingsScreen",
                                sameFileThunk: false)
        // Pre-condition: the view is blocked (same as testPrivateMemberReadFlaggedAsInaccessibleWallSeparateFile).
        XCTAssertTrue(lowered.referencesUnmarshalledInput || lowered.referencesUnresolvedSymbol,
                      "separate-file: a private-member read in a lowered string must block")
        // Fix-hint data: `schedule` must appear in inaccessibleReadNames.
        XCTAssertTrue(lowered.inaccessibleReadNames.contains("schedule"),
                      "the private member `schedule` must be named as inaccessible: "
                      + "\(lowered.inaccessibleReadNames)")
        // BuildPipeline uses this to emit the hint. Non-empty = hint fires.
        XCTAssertFalse(lowered.inaccessibleReadNames.isEmpty,
                       "inaccessibleReadNames must be non-empty so the fix-hint fires")
        // Same-file thunk unblocks the view → inaccessibleReadNames is empty → no hint.
        let loweredSameFile = try lower(Self.settingsScreenSource, view: "SettingsScreen",
                                        sameFileThunk: true)
        XCTAssertTrue(loweredSameFile.inaccessibleReadNames.isEmpty,
                      "same-file: inaccessibleReadNames empty → no fix-hint emitted (correct)")
    }

    /// A view blocked by a TUPLE-typed stored property (`canAdvance: (Bool, String)`).
    /// Tuples aren't Codable so the engine can't marshal them. The fix-hint should
    /// suggest replacing the tuple with a named Codable struct.
    func testTupleTypedBlockingReadPopulatesTupleBlockingNames() throws {
        let source = """
        import SwiftUI
        struct StepView: View {
            var canAdvance: (ok: Bool, reason: String) = (false, "")
            var title: String = ""
            var body: some View {
                VStack {
                    Text(title)
                    if canAdvance.ok {
                        Text(canAdvance.reason)
                    }
                }
            }
        }
        """
        let lowered = try lower(source, view: "StepView")
        // The tuple-typed `canAdvance` is `.unsupported` (can't be marshalled).
        // The view should be blocked when the body actually reads it.
        XCTAssertTrue(lowered.referencesUnmarshalledInput,
                      "a view reading a tuple-typed property must be blocked (tuple not Codable): "
                      + "blocking reads = \(lowered.blockingReadNames)")
        // The tuple blocker must be named.
        XCTAssertTrue(lowered.tupleBlockingNames.contains("canAdvance"),
                      "the tuple-typed `canAdvance` must appear in tupleBlockingNames: "
                      + "\(lowered.tupleBlockingNames)")
        // Sanity: it must also appear in blockingReadNames.
        XCTAssertTrue(lowered.blockingReadNames.contains("canAdvance"),
                      "canAdvance must be in blockingReadNames: \(lowered.blockingReadNames)")
    }

    /// A view blocked by a non-reconstructable struct (NOT a tuple) must NOT populate
    /// `tupleBlockingNames` — no false hint for genuinely-native struct demotes.
    func testNonTupleStructBlockingReadDoesNotPopulateTupleBlockingNames() throws {
        let source = """
        import SwiftUI
        struct ProfileView: View {
            var profile: Profile = Profile()
            var body: some View {
                Text(profile.name)
            }
        }
        struct Profile { var name: String = "" }
        """
        let lowered = try lower(source, view: "ProfileView")
        // May or may not be blocked depending on catalog (Profile isn't in flat catalog).
        // What we assert is: even if it's blocked, tupleBlockingNames must be EMPTY.
        XCTAssertTrue(lowered.tupleBlockingNames.isEmpty,
                      "a non-tuple struct demote must NOT appear in tupleBlockingNames "
                      + "(no false tuple fix-hint): \(lowered.tupleBlockingNames)")
    }

    /// A clean view (only scalar inputs) has EMPTY `tupleBlockingNames` — no false hint.
    func testCleanViewHasEmptyTupleBlockingNames() throws {
        let source = """
        import SwiftUI
        struct SimpleView: View {
            var title: String = ""
            var count: Int = 0
            var body: some View {
                Text("\\(title) (\\(count))")
            }
        }
        """
        let lowered = try lower(source, view: "SimpleView")
        XCTAssertFalse(lowered.referencesUnmarshalledInput,
                       "a clean view has no blocking reads")
        XCTAssertTrue(lowered.tupleBlockingNames.isEmpty,
                      "a clean view must have empty tupleBlockingNames: \(lowered.tupleBlockingNames)")
    }

    /// A view with a SwiftData @Query property: tupleBlockingNames must be EMPTY
    /// (no false tuple fix-hint for genuinely-native SwiftData demotes).
    func testSwiftDataDemoteDoesNotPopulateTupleBlockingNames() throws {
        let source = """
        import SwiftUI
        import SwiftData
        struct ItemList: View {
            @Query var items: [Item]
            var body: some View {
                ForEach(items) { _ in Text("item") }
            }
        }
        """
        let lowered = try lower(source, view: "ItemList")
        // The SwiftData @Query property may block the view.
        // We assert: tupleBlockingNames is empty regardless.
        XCTAssertTrue(lowered.tupleBlockingNames.isEmpty,
                      "a SwiftData @Query demote must NOT appear in tupleBlockingNames: "
                      + "\(lowered.tupleBlockingNames)")
    }

    // Minimal WASM runner (mirrors SwiftUINonScalarInputTests.Runner).
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
