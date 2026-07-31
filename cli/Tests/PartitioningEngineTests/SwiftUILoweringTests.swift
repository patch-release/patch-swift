// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import WasmKit
import WasmKitWASI
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// Tests for the productized SwiftUI→WASM lowering path (PATCH_SWIFTUI=1):
///   * the `FrontierLower` Classifier+Emitter lower a real SwiftUI body,
///   * the `SwiftUIGuestEmitter` produces a self-contained guest module with the
///     `view_body` export + the embeddable ViewNode IR,
///   * the embedded IR resources match the canonical `ViewNodeIR` target (drift guard),
///   * (when the WASM toolchain is present) the guest module COMPILES, host-RUNS
///     `view_body`, and returns a decodable `BodyEmission` whose tree matches the
///     original SwiftUI — the headline "View.body executes in WASM" claim.
final class SwiftUILoweringTests: XCTestCase {

    // MARK: - PER-ROW INDEXED NATIVE-ACTION SLOTS (the AppA AccountSwitcher fix)

    /// The exact real-app shape: a `ForEach` over a BODY-LOCAL collection (`owners`,
    /// aliasing an `@Environment` service collection the guest can't reconstruct) whose
    /// rows are a custom child view (`AccountChip`) carrying a PER-ROW native action
    /// closure. It LOWERS to an `indexedForEachSlot` node + a recorded `IndexedRowSlot`,
    /// the body-local count guard host-projects to a numeric token, and NO free guest
    /// identifier leaks — so the view becomes routable (was the only native view).
    func testAccountSwitcherIndexedForEachSlotLowers() throws {
        let src = """
        import SwiftUI

        struct AccountSwitcher: View {
            @Environment(ScheduleService.self) private var schedule
            var body: some View {
                let owners = schedule.availableOwners
                if owners.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(owners, id: \\.id) { owner in
                                AccountChip(id: owner.id, label: owner.label, subtitle: owner.subtitle,
                                            selected: schedule.selectedOwnerId == owner.id) {
                                    schedule.selectedOwnerId = owner.id
                                }
                            }
                        }.padding(.horizontal, 20)
                    }.scrollClipDisabled()
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "AccountSwitcher" })

        // (1) The ForEach lowered to an indexed-row slot (NOT a plain opaque slot).
        XCTAssertEqual(v.indexedRowSlots.count, 1, "the body-local-collection ForEach lowered to one indexed-row slot")
        let slot = try XCTUnwrap(v.indexedRowSlots.first)
        XCTAssertEqual(slot.collectionSource, "schedule.availableOwners",
            "the body-local `owners` alias resolved to its accessible initializer")
        XCTAssertEqual(slot.loopVar, "owner")
        XCTAssertTrue(slot.rowSource.contains("AccountChip"), "the row source is the custom child view: \(slot.rowSource)")
        XCTAssertTrue(slot.rowSource.contains("schedule.selectedOwnerId = owner.id"),
            "the per-row native action closure rides into the row source")

        // (2) The guest body carries the indexed-slot node (not a whole-ForEach opaque),
        //     and the body-local count guard host-projected to a numeric token.
        XCTAssertTrue(v.guestBody.contains("N.indexedForEachSlot(id: \"\(slot.id)\""),
            "guest tree carries the indexed-slot node: \(v.guestBody)")
        XCTAssertTrue(v.guestBody.contains("__numtok_"),
            "the `owners.count` guard host-projected to a numeric count token: \(v.guestBody)")

        // (3) No free guest identifier leaks → the view is routable (was native before).
        XCTAssertFalse(v.referencesUnresolvedSymbol,
            "no free guest identifier remains (unresolved: \(v.unresolvedSymbols))")
        XCTAssertFalse(v.referencesUnmarshalledInput)
        // The structure rides WASM; the rows are native — but the indexed slot IS content.
        XCTAssertFalse(v.guestBody.contains("\"owners\""))
        XCTAssertFalse(BodyLowering.guestBodyReferencesAny(v.guestBody, names: ["owners", "schedule"]),
            "neither the body-local alias nor the service leaks into the guest tree")
    }

    /// DEMOTE-SAFE: a `ForEach` over a body-local collection whose row reads an
    /// INACCESSIBLE (`private`) member that the cross-file thunk can't reach (here the
    /// SEPARATE-file thunk → `private` is inaccessible) does NOT get an indexed-row slot —
    /// it stays a native slot (faithful over a thunk-uncompilable factory).
    func testInaccessiblePerRowDoesNotIndexedSlot() throws {
        let src = """
        import SwiftUI

        struct RowList: View {
            @Environment(Svc.self) private var svc
            private func rowTitle(_ x: Item) -> String { x.secret }
            var body: some View {
                let items = svc.items
                if !items.isEmpty {
                    HStack {
                        ForEach(items, id: \\.id) { item in
                            Chip(label: rowTitle(item)) { svc.pick(item.id) }
                        }
                    }
                }
            }
        }
        """
        let lowering = BodyLowering()
        // SEPARATE-file thunk: `private rowTitle` is INACCESSIBLE → the row factory can't
        // compile → no indexed-row slot (it demotes to a plain native slot for the ForEach).
        let views = lowering.lowerAllViews(source: src, sameFileThunk: false)
        let v = try XCTUnwrap(views.first { $0.viewName == "RowList" })
        XCTAssertTrue(v.indexedRowSlots.isEmpty,
            "a row reading a private (cross-file-inaccessible) member does NOT get an indexed slot")
    }

    /// DEMOTE-SAFE: a `ForEach` whose ROWS are themselves lowerable (a plain `Text` over a
    /// marshalled scalar array) keeps lowering as a real guest loop (`N.forEach`), NOT an
    /// indexed-row slot — the indexed path is the fallback ONLY when the guest loop fails.
    func testLowerableRowsKeepGuestLoopNotIndexedSlot() throws {
        let src = """
        import SwiftUI

        struct TagRow: View {
            let tags: [String]
            var body: some View {
                HStack {
                    ForEach(tags, id: \\.self) { tag in
                        Text(tag)
                    }
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "TagRow" })
        XCTAssertTrue(v.indexedRowSlots.isEmpty, "lowerable rows over a marshalled array stay a guest loop")
        XCTAssertTrue(v.guestBody.contains("N.forEach"), "the real guest loop is emitted: \(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains("indexedForEachSlot"))
    }

    // MARK: - $0-SHORTHAND ForEach rows (the common idiom — closure-invocation factory)

    /// A `$0`-SHORTHAND row over a body-local collection lowers to an `indexedForEachSlot`
    /// (it no longer declines to a whole-ForEach slot). The recorded slot carries the FULL
    /// original closure text (the factory invokes it with the element) — proving `$0`
    /// support rides the closure-invocation path, NOT a `$0`-rewrite.
    func testDollarZeroShorthandRowLowersToIndexedSlot() throws {
        let src = """
        import SwiftUI

        struct AccountSwitcher: View {
            @Environment(ScheduleService.self) private var schedule
            var body: some View {
                let owners = schedule.availableOwners
                if owners.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(owners, id: \\.id) {
                                AccountChip(id: $0.id, label: $0.label, subtitle: $0.subtitle,
                                            selected: schedule.selectedOwnerId == $0.id) {
                                    schedule.selectedOwnerId = $0.id
                                }
                            }
                        }.padding(.horizontal, 20)
                    }.scrollClipDisabled()
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "AccountSwitcher" })

        XCTAssertEqual(v.indexedRowSlots.count, 1, "the $0 row lowered to one indexed-row slot")
        let slot = try XCTUnwrap(v.indexedRowSlots.first)
        XCTAssertEqual(slot.collectionSource, "schedule.availableOwners")
        XCTAssertEqual(slot.loopVar, "$0", "the synthetic seed loop var marks the shorthand form")
        // The closure-invocation factory carries the FULL original closure text (incl. `$0`).
        let closureText = try XCTUnwrap(slot.rowClosureText, "a $0 row stores its closure text")
        XCTAssertTrue(closureText.contains("AccountChip(id: $0.id"), "the closure text is the verbatim row: \(closureText)")
        XCTAssertTrue(closureText.contains("schedule.selectedOwnerId = $0.id"), "the per-row action rides the closure")

        XCTAssertTrue(v.guestBody.contains("N.indexedForEachSlot(id: \"\(slot.id)\""),
            "guest tree carries the indexed-slot node: \(v.guestBody)")
        XCTAssertTrue(v.guestBody.contains("__numtok_"), "the count guard host-projected: \(v.guestBody)")
        XCTAssertFalse(v.referencesUnresolvedSymbol, "no free guest identifier (unresolved: \(v.unresolvedSymbols))")
        XCTAssertFalse(BodyLowering.guestBodyReferencesAny(v.guestBody, names: ["owners", "schedule"]),
            "neither the alias nor the service leaks into the guest tree")
    }

    /// DEMOTE-SAFE: a `$1`/multi-element `$0`-shorthand row (NOT a single-element ForEach
    /// row binding) does NOT get an indexed slot — the single-element indexed slot can't
    /// express it. (Construct a row that references `$1` in its OWN body.)
    func testMultiElementShorthandRowDeclines() throws {
        let src = """
        import SwiftUI

        struct PairRow: View {
            @Environment(Svc.self) private var svc
            var body: some View {
                let pairs = svc.pairs
                HStack {
                    ForEach(pairs, id: \\.0) {
                        AccountChip(id: $0, label: $1) { svc.pick($0) }
                    }
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "PairRow" })
        XCTAssertTrue(v.indexedRowSlots.isEmpty,
            "a $1-using (multi-element) shorthand row declines the single-element indexed slot")
    }

    /// DEMOTE-SAFE: a `$0`-shorthand row that ALSO reads a body-local OTHER than the
    /// element (here `multiplier`, a `let` in the body) does NOT get an indexed slot — the
    /// thunk factory closes over `self` only, so a non-element body-local read can't compile.
    func testDollarZeroRowReadingBodyLocalDeclines() throws {
        let src = """
        import SwiftUI

        struct ScaledRow: View {
            @Environment(Svc.self) private var svc
            var body: some View {
                let owners = svc.owners
                let multiplier = 3
                HStack {
                    ForEach(owners, id: \\.id) {
                        AccountChip(id: $0.id, scale: multiplier) { svc.pick($0.id) }
                    }
                }
            }
        }
        """
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: src, sameFileThunk: true)
        let v = try XCTUnwrap(views.first { $0.viewName == "ScaledRow" })
        XCTAssertTrue(v.indexedRowSlots.isEmpty,
            "a $0 row reading a non-element body-local (`multiplier`) declines the indexed slot")
    }

    /// The thunk factory for a `$0` row INVOKES the original closure with the element
    /// (`(closure)(coll[i])`) — proving the closure-invocation form is emitted, NOT a
    /// `let $0 = …` bind (which is illegal Swift). Also proves a genuinely-nested closure
    /// that uses `$0` (the AccountChip action) rides VERBATIM (its `$0` is its own, never
    /// rewritten), and the whole edited file parses.
    func testDollarZeroRowThunkInvokesClosure() throws {
        let src = """
        import SwiftUI

        struct AccountSwitcher: View {
            @Environment(ScheduleService.self) private var schedule
            var body: some View {
                let owners = schedule.availableOwners
                if owners.count > 1 {
                    HStack {
                        ForEach(owners, id: \\.id) {
                            AccountChip(id: $0.id, label: $0.label) {
                                schedule.selectedOwnerId = $0.id
                            }
                        }
                    }
                }
            }
        }
        """
        let sources = [ThunkGenerator.SourceFile(url: URL(fileURLWithPath: "/x/AccountSwitcher.swift"), text: src)]
        let result = ThunkGenerator().prepare(sources: sources, sameFile: true)
        let t = try XCTUnwrap(result.modifiedFiles.first { $0.url.lastPathComponent == "AccountSwitcher.swift" }?.text)
        XCTAssertTrue(t.contains("func __patchRowSlots() -> [String: PatchRowSlot]"), t)
        XCTAssertTrue(t.contains("let __coll = schedule.availableOwners"), t)
        XCTAssertTrue(t.contains("PatchRowSlot(count: __coll.count)"), t)
        // The closure-invocation factory: `(closure)(coll[i])` — NOT a `let $0 = …` bind.
        XCTAssertTrue(t.contains("return AnyView(("), "the factory invokes the closure: \(t)")
        XCTAssertTrue(t.contains(")(__coll[__coll.index"), "the closure is applied to coll[i]: \(t)")
        XCTAssertFalse(t.contains("let $0 ="), "NEVER a `let $0 = …` bind (illegal Swift): \(t)")
        // The nested action closure's `$0` rides VERBATIM (untouched — its own param).
        XCTAssertTrue(t.contains("schedule.selectedOwnerId = $0.id"), "the nested closure's $0 is verbatim: \(t)")
        XCTAssertTrue(t.contains("AccountChip(id: $0.id, label: $0.label)"), "the outer row's $0 is verbatim: \(t)")
        XCTAssertTrue(ThunkGenerator.parses(t), "the edited file parses: \(t)")
    }

    // A representative real SwiftUI view: Text + stacks + modifiers + a Toggle (the
    // static + simple-interactive subset the proven package covers).
    private let profileSource = """
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
    """

    // MARK: - 1. Host-side lowering (always runs, no toolchain)

    func testLowersRealViewBody() throws {
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: profileSource)
        XCTAssertEqual(views.count, 1, "should find exactly one View struct")
        let v = try XCTUnwrap(views.first)
        XCTAssertEqual(v.viewName, "ProfileCard")

        // The body has Text/VStack/HStack/Image/Spacer/Toggle + font/bold/padding/etc.
        // — all in the lowerable surface, so coverage should be very high.
        let r = v.report
        XCTAssertGreaterThan(r.totalElements, 8, "a real body has many elements")
        XCTAssertGreaterThanOrEqual(r.coverage, 0.95,
            "static + simple-interactive body should lower ≥95%: \(r.summary())")
        XCTAssertTrue(r.isInteractive, "the Toggle makes this an interactive view")
        XCTAssertEqual(r.loweredInteractiveControls, 1, "the Toggle lowers as a state control")

        // The emitted guest body is the N.* builder expression that builds the tree.
        XCTAssertTrue(v.guestBody.contains("N.vstack"), "VStack lowers to N.vstack")
        XCTAssertTrue(v.guestBody.contains("N.toggle"), "Toggle lowers to N.toggle")
        XCTAssertTrue(v.guestBody.contains("N.text(name)"), "Text(name) marshals the input string")
    }

    // MARK: - 1b. IR v2 containers + navigation shell lowering (no toolchain)

    /// A settings-style screen exercising the IR v2 surface: NavigationStack +
    /// .navigationTitle, a Form with Sections (string-titled + header/footer),
    /// a List, a ScrollView, LazyVStack/LazyHStack, and Label(_:systemImage:).
    /// All of it is in the lowerable surface, so it lowers with ZERO opaque
    /// nodes — the whole screen rides WASM (granularly patchable).
    private let settingsSource = """
    import SwiftUI

    struct SettingsScreen: View {
        var body: some View {
            NavigationStack {
                Form {
                    Section("Account") {
                        Label("Profile", systemImage: "person.crop.circle")
                        Text("Signed in")
                    }
                    Section(header: Text("Display"), footer: Text("Affects all screens")) {
                        Text("Theme")
                    }
                }
                .navigationTitle("Settings")
            }
        }
    }
    """

    func testLowersIRv2Containers() throws {
        let lowering = BodyLowering()
        let views = lowering.lowerAllViews(source: settingsSource)
        let v = try XCTUnwrap(views.first)
        XCTAssertEqual(v.viewName, "SettingsScreen")

        let g = v.guestBody
        // Navigation shell + title modifier.
        XCTAssertTrue(g.contains("N.navigationStack("), "NavigationStack lowers: \(g)")
        XCTAssertTrue(g.contains(".navigationTitle(\"Settings\")"), "navigationTitle lowers: \(g)")
        // Form + Sections.
        XCTAssertTrue(g.contains("N.form("), "Form lowers: \(g)")
        XCTAssertTrue(g.contains("N.section("), "Section lowers: \(g)")
        // String-titled Section → a Text header.
        XCTAssertTrue(g.contains("header: [") && g.contains("N.text(\"Account\")"),
                      "Section(\"Account\") lowers the title to a Text header: \(g)")
        // header:/footer: Section → lowered header AND footer.
        XCTAssertTrue(g.contains("footer: ["), "Section(footer:) lowers a footer: \(g)")
        // Label(_:systemImage:).
        XCTAssertTrue(g.contains("N.label(title: \"Profile\", systemImage: \"person.crop.circle\")"),
                      "Label lowers to N.label: \(g)")

        // The whole screen is lowerable — zero opaque fallback (every node +
        // modifier lowered; the emitted guest body has no N.opaque slot).
        XCTAssertFalse(g.contains("N.opaque"),
                       "the IR v2 settings screen rides WASM with no native slot: \(g)")
        XCTAssertEqual(v.report.loweredNodes, v.report.totalNodes,
                       "every node lowered: \(v.report.summary())")
        XCTAssertEqual(v.report.loweredModifiers, v.report.totalModifiers,
                       "every modifier (incl. navigationTitle) lowered: \(v.report.summary())")
        XCTAssertEqual(v.report.coverage, 1.0, v.report.summary())
    }

    /// `List { Section("A"){ Text("x") } }` lowers to `N.list([ N.section(...) ])`
    /// with no opaque (the headline nested-container assertion from the task).
    func testListOfSectionLowersWithoutOpaque() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                List {
                    Section("A") {
                        Text("x")
                    }
                }
            }
        }
        """
        let v = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let g = v.guestBody
        XCTAssertTrue(g.contains("N.list("), "List lowers: \(g)")
        XCTAssertTrue(g.contains("N.section("), "Section lowers inside the List: \(g)")
        XCTAssertTrue(g.contains("N.text(\"x\")"), "the Section row lowers: \(g)")
        XCTAssertFalse(g.contains("N.opaque"), "nothing falls back to native: \(g)")
        XCTAssertEqual(v.report.loweredNodes, v.report.totalNodes, v.report.summary())
    }

    /// ScrollView axes + LazyVStack/LazyHStack now lower to DISTINCT lazy nodes
    /// (the IR models them; the renderer builds a real LazyVStack/LazyHStack).
    func testScrollViewAndLazyStacksLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                ScrollView(.horizontal) {
                    LazyHStack {
                        Text("a")
                        Text("b")
                    }
                }
            }
        }
        """
        let v = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let g = v.guestBody
        XCTAssertTrue(g.contains("N.scrollView(axis: .horizontal"), "horizontal ScrollView: \(g)")
        XCTAssertTrue(g.contains("N.lazyHStack("), "LazyHStack lowers to a distinct lazy node: \(g)")
        XCTAssertFalse(g.contains("N.opaque"), "no opaque: \(g)")

        // Default-axis ScrollView + LazyVStack → a distinct lazyVStack node.
        let vert = """
        import SwiftUI
        struct W: View {
            var body: some View {
                ScrollView {
                    LazyVStack { Text("a") }
                }
            }
        }
        """
        let w = try XCTUnwrap(BodyLowering().lowerAllViews(source: vert).first)
        XCTAssertTrue(w.guestBody.contains("N.scrollView(axis: .vertical"), "default vertical: \(w.guestBody)")
        XCTAssertTrue(w.guestBody.contains("N.lazyVStack("), "LazyVStack lowers to a distinct lazy node: \(w.guestBody)")
    }

    /// Legacy `NavigationView` maps to the same navigationStack shell.
    func testNavigationViewMapsToNavigationStack() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                NavigationView {
                    Text("home")
                }
            }
        }
        """
        let v = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        XCTAssertTrue(v.guestBody.contains("N.navigationStack("),
                      "NavigationView maps to navigationStack: \(v.guestBody)")
        XCTAssertFalse(v.guestBody.contains("N.opaque"))
    }

    // MARK: - 1d. NEW leaf views (styledText/symbolImage/bundleImage/asyncImage/
    //              determinate progress/gauge/link/shareLink/secureField/textEditor/
    //              labeledContent/menu, generalized Label, EmptyView/AnyView)

    /// A screen exercising the new LEAF views — each lowers to its dedicated node
    /// with NO spurious `N.opaque`.
    func testNewLeafViewsLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            let prog: Double
            let level: Double
            var draft: String = ""
            var secret: String = ""
            var body: some View {
                VStack {
                    Text(verbatim: "raw")
                    Image(systemName: "wifi", variableValue: 0.5)
                    Image("Logo")
                    AsyncImage(url: URL(string: "https://example.com/a.png"))
                    ProgressView(value: prog, total: 100)
                    Gauge(value: level, in: 0...10) { Text("L") }
                    Link("Home", destination: URL(string: "https://example.com"))
                    ShareLink(item: "share me")
                    SecureField("Password", text: $secret)
                    TextEditor(text: $draft)
                    LabeledContent("Name") { Text("Ada") }
                    Menu { Button("One", action: {}) } label: { Text("More") }
                    Label { Text("T") } icon: { Image(systemName: "star") }
                    EmptyView()
                    AnyView(Text("erased"))
                }
            }
        }
        """
        let v = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let g = v.guestBody
        XCTAssertTrue(g.contains("N.styledText(\"raw\", verbatim: true)"), "Text(verbatim:) lowers: \(g)")
        XCTAssertTrue(g.contains("N.symbolImage(systemName: \"wifi\""), "Image(systemName:variableValue:) lowers: \(g)")
        XCTAssertTrue(g.contains("N.bundleImage(name: \"Logo\")"), "Image(\"asset\") lowers: \(g)")
        XCTAssertTrue(g.contains("N.asyncImage(url: \"https://example.com/a.png\")"), "AsyncImage lowers: \(g)")
        XCTAssertTrue(g.contains("N.progressView(value: Double(prog), total: Double(100)"), "determinate ProgressView lowers: \(g)")
        XCTAssertTrue(g.contains("N.gauge(value: Double(level), min: 0.0, max: 10.0"), "Gauge lowers: \(g)")
        XCTAssertTrue(g.contains("N.link(destination: \"https://example.com\""), "Link lowers: \(g)")
        XCTAssertTrue(g.contains("N.shareLink(items: [\"share me\"]"), "ShareLink lowers: \(g)")
        XCTAssertTrue(g.contains("N.secureField(\"Password\", text: secret, event: \"secret\")"), "SecureField lowers: \(g)")
        XCTAssertTrue(g.contains("N.textEditor(text: draft, event: \"draft\")"), "TextEditor lowers: \(g)")
        XCTAssertTrue(g.contains("N.labeledContent(label:"), "LabeledContent lowers: \(g)")
        XCTAssertTrue(g.contains("N.menu(label:"), "Menu lowers: \(g)")
        XCTAssertTrue(g.contains("N.label(title:"), "generalized Label lowers: \(g)")
        XCTAssertTrue(g.contains("N.group([])"), "EmptyView lowers to an empty group: \(g)")
        XCTAssertTrue(g.contains("N.text(\"erased\")"), "AnyView unwraps to the inner node: \(g)")
        // None of these forms should slot.
        XCTAssertFalse(g.contains("N.opaque"), "every new leaf lowers, no native slot: \(g)")
    }

    /// The `.contextMenu { items }` MODIFIER form lowers — wrapping the lowered base
    /// content in a contextMenu node (the item Button auto-wires via the actionID
    /// path). A `.contextMenu(menuItems:preview:)` overload stays opaque.
    func testContextMenuModifierLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("Long-press me")
                    .contextMenu {
                        Button("Copy", action: {})
                        Button("Share", action: {})
                    }
            }
        }
        """
        let v = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let g = v.guestBody
        XCTAssertTrue(g.contains("N.contextMenu(content: [N.text(\"Long-press me\")]"),
                      ".contextMenu wraps the lowered base content: \(g)")
        // The button lowers via the label-node form (title routed through emitTitleTextLiteral
        // for markdown/LocalizedStringKey handling): N.button(actionID:, label: [N.text("Copy")]).
        XCTAssertTrue(g.contains("N.button(actionID:") && g.contains("N.text(\"Copy\")"),
                      "the menu items lower: \(g)")
        XCTAssertFalse(g.contains("N.opaque"), "the items-builder contextMenu lowers fully: \(g)")
    }

    // MARK: - 1e. NEW containers (lazy grids, grid/gridRow, groupBox,
    //              disclosureGroup, viewThatFits, controlGroup)

    /// A screen exercising the new CONTAINERS — each lowers with NO spurious opaque.
    func testNewContainersLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.fixed(80))], spacing: 12) {
                        Text("a")
                        Text("b")
                    }
                    LazyHGrid(rows: [GridItem(.adaptive(minimum: 40))]) {
                        Text("c")
                    }
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Text("r1c1")
                            Text("r1c2")
                        }
                    }
                    GroupBox("Box") {
                        Text("boxed")
                    }
                    DisclosureGroup("Section") {
                        Text("hidden")
                    }
                    ViewThatFits {
                        Text("wide")
                        Text("narrow")
                    }
                    ControlGroup {
                        Button("X", action: {})
                    }
                }
            }
        }
        """
        let v = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let g = v.guestBody
        XCTAssertTrue(g.contains("N.lazyVGrid(columns: ["), "LazyVGrid lowers: \(g)")
        XCTAssertTrue(g.contains("IRGridItem(size: .flexible("), "flexible GridItem lowers: \(g)")
        XCTAssertTrue(g.contains("IRGridItem(size: .fixed(Double(80)))"), "fixed GridItem lowers: \(g)")
        XCTAssertTrue(g.contains("N.lazyHGrid(rows: ["), "LazyHGrid lowers: \(g)")
        XCTAssertTrue(g.contains("IRGridItem(size: .adaptive("), "adaptive GridItem lowers: \(g)")
        XCTAssertTrue(g.contains("N.grid("), "Grid lowers: \(g)")
        XCTAssertTrue(g.contains("N.gridRow("), "GridRow lowers: \(g)")
        XCTAssertTrue(g.contains("N.groupBox("), "GroupBox lowers: \(g)")
        XCTAssertTrue(g.contains("N.disclosureGroup(label:"), "DisclosureGroup lowers: \(g)")
        XCTAssertTrue(g.contains("N.viewThatFits(axes: .both"), "ViewThatFits lowers: \(g)")
        XCTAssertTrue(g.contains("N.controlGroup("), "ControlGroup lowers: \(g)")
        XCTAssertFalse(g.contains("N.opaque"), "every new container lowers, no native slot: \(g)")
    }

    /// Honest limits: forms the EMITTER deliberately slots — a `Text(date, style:)`
    /// (no Foundation in the embedded guest), a bound `TabView(selection:)`, a
    /// `Path { }` of non-literal points, and an `AsyncImage` with a content closure.
    /// They become native slots (never dropped). (A BOUND `DisclosureGroup(isExpanded:)`
    /// now LOWERS via the Bool-binding bridge — see testBoundDisclosureGroupLowers.)
    func testNewConstructHonestLimitsSlot() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State var tab = 0
            var when: Date
            var body: some View {
                VStack {
                    Text(when, style: .relative)
                    TabView(selection: $tab) {
                        Text("one").tag(0)
                    }
                    Path { p in
                        p.move(to: .zero)
                    }
                    AsyncImage(url: URL(string: "https://e.com/a.png")) { img in
                        img.resizable()
                    } placeholder: {
                        ProgressView()
                    }
                }
            }
        }
        """
        let v = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let g = v.guestBody
        // The VStack shell lowers; the listed forms each become a native slot.
        XCTAssertTrue(g.contains("N.vstack("), "the shell lowers: \(g)")
        XCTAssertTrue(g.contains("N.opaque"), "the honest-limit forms slot: \(g)")
        // Specifically NOT lowered to their dedicated nodes:
        XCTAssertFalse(g.contains("N.dateText("), "Text(date,style:) stays opaque (no Foundation in guest): \(g)")
        XCTAssertFalse(g.contains("N.tabView("), "bound TabView stays opaque: \(g)")
        // `p.move(to: .zero)` uses `.zero` (not a literal `CGPoint(x:y:)`), so this
        // Path still slots. A literal-coordinate Path now LOWERS (see testPathLowers).
        XCTAssertFalse(g.contains("N.path("), "Path with .zero (non-literal point) stays opaque: \(g)")
        XCTAssertFalse(g.contains("N.asyncImage("), "AsyncImage w/ content closure stays opaque: \(g)")
    }

    /// A BOUND `DisclosureGroup(isExpanded: $flag) { content } label: { … }` lowers via
    /// the Bool-binding bridge: `N.disclosureGroup(label:isExpanded:_:event:)`. The SDK
    /// renders a real bound `DisclosureGroup`; on toggle it dispatches `setBool`.
    func testBoundDisclosureGroupLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var open = false
            var body: some View {
                DisclosureGroup("Advanced", isExpanded: $open) {
                    Text("hidden")
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "the bound DisclosureGroup lowers: \(body)")
        XCTAssertTrue(body.contains("N.disclosureGroup(label:") && body.contains("isExpanded: open")
                      && body.contains("event: \"open\""),
                      "bound DisclosureGroup uses the Bool-binding bridge: \(body)")
    }

    /// Demote-safe: a `Section` wrapping a custom child view degrades to a native
    /// slot WITHOUT crashing, while the surrounding lowerable structure (incl. the
    /// now-lowerable `Label { } icon: { }` builder form) still rides WASM.
    func testIRv2DemotesUnhandledFormsSafely() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                List {
                    Section("Rows") {
                        Label("ok", systemImage: "checkmark")
                        Label {
                            Text("custom")
                        } icon: {
                            Circle()
                        }
                        CustomRow()
                    }
                }
            }
        }
        """
        let v = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let g = v.guestBody
        // The list/section/known-label still lower.
        XCTAssertTrue(g.contains("N.list("))
        XCTAssertTrue(g.contains("N.section("))
        XCTAssertTrue(g.contains("N.label(title: \"ok\", systemImage: \"checkmark\")"))
        // The builder-form Label NOW lowers to the general title/icon node (Text + Circle).
        XCTAssertTrue(g.contains("N.label(title:"),
                      "the builder Label { } icon: { } lowers to the general node: \(g)")
        // The custom child slots to native (opaque), not dropped.
        XCTAssertTrue(g.contains("N.opaque"), "the custom child becomes a native slot: \(g)")
        XCTAssertLessThan(v.report.loweredNodes, v.report.totalNodes,
                          "the custom child fell back to native: \(v.report.summary())")
    }

    // MARK: - 1c. IR v2: flexible frames, common modifiers, RGBA colors lower

    /// `.frame(maxWidth: .infinity)` + `.tint(.blue)` lower with NO native fallback
    /// (the flexible frame rides WASM as `.flexFrame`, the tint as `.tint`).
    func testFlexibleFrameAndTintLowerWithNoOpaque() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("x")
                    .frame(maxWidth: .infinity)
                    .tint(.blue)
            }
        }
        """
        let lowering = BodyLowering()
        let report = try XCTUnwrap(lowering.analyze(source: source))
        XCTAssertEqual(report.loweredElements, report.totalElements,
            "every element lowers — no native fallback: \(report.summary())")
        XCTAssertTrue(report.fallbackReasons.isEmpty,
            "no fallbacks expected: \(report.fallbackReasons)")

        let body = try XCTUnwrap(lowering.emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "no opaque slot in the emitted body: \(body)")
        XCTAssertTrue(body.contains(".flexFrame(minWidth: nil, idealWidth: nil, maxWidth: .infinity,"),
            "maxWidth: .infinity lowers to .flexFrame with .infinity: \(body)")
        XCTAssertTrue(body.contains(".tint(.named(\"blue\"))"), "tint lowers: \(body)")
    }

    /// `Color(red:green:blue:)` lowers to `N.color(.rgba(...))` (the renderer already
    /// renders `.rgba`), with NO opaque fallback.
    func testRGBAColorLiteralLowersWithNoOpaque() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Color(red: 0.2, green: 0.4, blue: 0.9)
            }
        }
        """
        let lowering = BodyLowering()
        let report = try XCTUnwrap(lowering.analyze(source: source))
        XCTAssertEqual(report.loweredElements, report.totalElements,
            "the RGBA color lowers — no native fallback: \(report.summary())")
        XCTAssertTrue(report.fallbackReasons.isEmpty, "no fallbacks: \(report.fallbackReasons)")

        let body = try XCTUnwrap(lowering.emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "RGBA Color is no longer slotted: \(body)")
        XCTAssertTrue(body.contains("N.color(.rgba(IRColor(r: Double(0.2), g: Double(0.4), b: Double(0.9), a: Double(1))))"),
            "Color(red:green:blue:) lowers to .rgba with opacity defaulting to 1: \(body)")
    }

    /// The full IR-v2 modifier surface (clipShape/disabled/fixedSize, flexible frame
    /// with an explicit alignment, RGBA tint, ProgressView) all lower with no opaque.
    func testIRv2ModifierSurfaceLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                ProgressView()
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipShape(Capsule())
                    .tint(Color(red: 0.1, green: 0.2, blue: 0.3))
                    .disabled(true)
                    .fixedSize()
            }
        }
        """
        let lowering = BodyLowering()
        let report = try XCTUnwrap(lowering.analyze(source: source))
        XCTAssertTrue(report.fallbackReasons.isEmpty,
            "the whole IR-v2 surface lowers: \(report.summary())")

        let body = try XCTUnwrap(lowering.emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "no opaque slot: \(body)")
        XCTAssertTrue(body.contains("N.progressView"), "ProgressView() lowers: \(body)")
        XCTAssertTrue(body.contains(".clipShape(.capsule)"), "clipShape lowers: \(body)")
        XCTAssertTrue(body.contains(".disabled(true)"), "disabled(true) lowers: \(body)")
        XCTAssertTrue(body.contains(".fixedSize()"), "fixedSize lowers: \(body)")
        XCTAssertTrue(body.contains("maxWidth: .infinity"), "flex maxWidth lowers: \(body)")
        XCTAssertTrue(body.contains("alignment: .leading"), "flex alignment lowers: \(body)")
        XCTAssertTrue(body.contains(".tint(.rgba(IRColor(r: Double(0.1), g: Double(0.2), b: Double(0.3), a: Double(1))))"),
            "tint accepts an RGBA Color(red:…): \(body)")
    }

    // MARK: - The MODIFIER-surface + IRShapeStyle expansion lowering

    /// The styling modifiers (foregroundStyle layers, ShapeStyle background with a
    /// material `in:` shape, gradient fill, stroke, border, shadow, content overlay)
    /// lower to their builder calls with NO opaque fallback.
    func testStylingModifierSurfaceLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Rectangle()
                    .fill(LinearGradient(colors: [.red, .blue], startPoint: .top, endPoint: .bottom))
                    .foregroundStyle(.primary, .secondary)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .border(.blue, width: 2)
                    .shadow(color: .black, radius: 4, x: 0, y: 2)
                    .overlay(alignment: .bottomTrailing) { Text("badge") }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "styling surface lowers with no slot: \(body)")
        XCTAssertTrue(body.contains(".fill(.linearGradient(IRGradient(stops:"), "gradient fill lowers: \(body)")
        XCTAssertTrue(body.contains(".foregroundStyle([.color(.named(\"primary\")), .color(.named(\"secondary\"))])"),
                      "2-layer foregroundStyle lowers: \(body)")
        XCTAssertTrue(body.contains(".background(.material(.ultraThin), in: .roundedRectangle"),
                      "material background with in: shape lowers: \(body)")
        XCTAssertTrue(body.contains(".border(.color(.named(\"blue\")), width: Double(2))"), "border lowers: \(body)")
        XCTAssertTrue(body.contains(".shadow(color: .named(\"black\"), radius: Double(4)"), "shadow lowers: \(body)")
        XCTAssertTrue(body.contains(".overlay(alignment: .bottomTrailing, ["), "content overlay lowers: \(body)")
    }

    /// The layout modifiers (offset/position/aspectRatio/scaledToFit/clipped/
    /// fixedSize axis/layoutPriority/zIndex/ignoresSafeArea) all lower.
    func testLayoutModifierSurfaceLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("x")
                    .offset(x: 4, y: -8)
                    .position(x: 10, y: 20)
                    .aspectRatio(1.5, contentMode: .fit)
                    .clipped()
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                    .zIndex(3)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "layout surface lowers with no slot: \(body)")
        XCTAssertTrue(body.contains(".offset(x: Double(4), y: Double(-8))"), "offset lowers: \(body)")
        XCTAssertTrue(body.contains(".position(x: Double(10), y: Double(20))"), "position lowers: \(body)")
        XCTAssertTrue(body.contains(".aspectRatio(Double(1.5), contentMode: .fit)"), "aspectRatio lowers: \(body)")
        XCTAssertTrue(body.contains(".clipped(antialiased: false)"), "clipped lowers: \(body)")
        XCTAssertTrue(body.contains(".fixedSize(horizontal: true, vertical: false)"), "fixedSize axis lowers: \(body)")
        XCTAssertTrue(body.contains(".layoutPriority(Double(2))"), "layoutPriority lowers: \(body)")
        XCTAssertTrue(body.contains(".zIndex(Double(3))"), "zIndex lowers: \(body)")
        XCTAssertTrue(body.contains(".ignoresSafeArea(regions: \"container\", edges: \"top\")"),
                      "ignoresSafeArea lowers: \(body)")
    }

    // MARK: - Wave 1 — additive standard-library modifiers

    /// G15b: a NON-literal `Color(...)` (`Color(.systemBackground)`, `Color(uiColor:)`)
    /// routes through the host-token color path (a `.hostToken` ColorRef) in both a
    /// modifier value position AND as a standalone node — instead of slotting.
    func testWave1NonLiteralColorRoutesThroughToken() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                VStack {
                    Text("a").foregroundColor(Color(.systemBackground))
                    Text("b").background(Color(uiColor: .secondarySystemBackground))
                    Color(.systemGroupedBackground)
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "no slot — all colors tokenize: \(body)")
        // The foregroundColor + the standalone Color node both carry a hostToken.
        XCTAssertTrue(body.contains(".hostToken("), "non-literal Color rides as a host token: \(body)")
        XCTAssertTrue(body.contains("N.color(.hostToken("), "standalone Color node tokenizes: \(body)")
    }

    /// A literal `Color(red:green:blue:)` still lowers STATICALLY (not a token) — no
    /// regression from G15b.
    func testWave1LiteralColorStillStatic() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Color(red: 0.5, green: 0.2, blue: 0.1)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains("N.color(.rgba("), "literal Color stays static rgba: \(body)")
        XCTAssertFalse(body.contains("hostToken"), "literal Color is NOT a token: \(body)")
    }

    /// G8: accessibility modifiers lower (label/hint/value string-literal, hidden
    /// bool, addTraits/removeTraits single + array forms).
    func testWave1AccessibilityModifiersLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Image(systemName: "star")
                    .accessibilityLabel("Favorite")
                    .accessibilityHint("Tap")
                    .accessibilityValue("3")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits([.isHeader, .isSelected])
                    .accessibilityRemoveTraits(.isImage)
                    .accessibilityHidden(false)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "no slot: \(body)")
        XCTAssertTrue(body.contains(".accessibilityLabel(\"Favorite\")"), body)
        XCTAssertTrue(body.contains(".accessibilityHint(\"Tap\")"), body)
        XCTAssertTrue(body.contains(".accessibilityValue(\"3\")"), body)
        XCTAssertTrue(body.contains(".accessibilityAddTraits(\"isButton\")"), body)
        XCTAssertTrue(body.contains(".accessibilityAddTraits(\"isHeader+isSelected\")"), body)
        XCTAssertTrue(body.contains(".accessibilityRemoveTraits(\"isImage\")"), body)
        XCTAssertTrue(body.contains(".accessibilityHidden(false)"), body)
    }

    /// G7: per-key `.environment(\.key, value)` lowers (layoutDirection/colorScheme/
    /// locale); `.environmentObject(_)` still slots (demote-safe).
    func testWave1EnvironmentValueLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("x")
                    .environment(\\.layoutDirection, .rightToLeft)
                    .environment(\\.colorScheme, .dark)
                    .environment(\\.locale, Locale(identifier: "he"))
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "no slot: \(body)")
        XCTAssertTrue(body.contains(".environmentValue(key: \"layoutDirection\", value: \"rightToLeft\")"), body)
        XCTAssertTrue(body.contains(".environmentValue(key: \"colorScheme\", value: \"dark\")"), body)
        XCTAssertTrue(body.contains(".environmentValue(key: \"locale\", value: \"he\")"), body)
    }

    /// `.environmentObject(_)` / an unknown env key slot gracefully (view still ships).
    func testWave1EnvironmentObjectStillSlots() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("x").environment(\\.font, .body)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains("N.opaque"), "an unrecognized env key slots: \(body)")
    }

    /// G36 (REVERTED): `.presentationDetents`/`.presentationDragIndicator` are
    /// DELIBERATELY NOT lowered — they slot gracefully (demote-safe). Lowering them as IR
    /// modifiers regressed a real view (AppA RemindersQuickSheet 44→43): keeping the
    /// modified subtree's base content lowered re-exposed a non-reconstructable `@State`
    /// read the previous whole-expression slot subsumed. This test locks the demote-safe
    /// slot behavior (the modifier rides a native slot; the surrounding view still ships)
    /// and guards against re-introducing the lowering without a root-caused fix.
    func testWave1PresentationDetentsSlotsNotLowered() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var showing = false
            var body: some View {
                Text("main").sheet(isPresented: $showing) {
                    Text("body")
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        // The presentation modifiers are NOT lowered to IR — they slot. The lowering used
        // to emit QUOTED detent tokens (`"medium"`); the slot instead embeds the RAW source
        // (`.medium`), so a quoted token appears ONLY if the modifier was (re-)lowered.
        // (Checking for `.presentationDetents([` would false-match the slot's raw source.)
        XCTAssertFalse(body.contains("\"medium\""), "must NOT lower detents to IR tokens: \(body)")
        XCTAssertTrue(body.contains("N.opaque"), "the presentation-modified subtree slots: \(body)")
        XCTAssertTrue(body.contains("N.text(\"main\")") || body.contains("sheet"),
                      "the surrounding view still lowers around the slot: \(body)")
    }

    /// G9: legacy `.navigationBarTitle(_, displayMode:)` + `.navigationViewStyle(.stack)`.
    func testWave1LegacyNavigationAPILowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                NavigationView {
                    Text("content").navigationBarTitle("Home", displayMode: .inline)
                }
                .navigationViewStyle(.stack)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "no slot: \(body)")
        XCTAssertTrue(body.contains(".navigationBarTitle(\"Home\", displayMode: \"inline\")"), "navBarTitle: \(body)")
        XCTAssertTrue(body.contains(".navigationViewStyle(\"stack\")"), "navViewStyle: \(body)")
    }

    /// G4/G5: an unbound paged-carousel `TabView { ... }` lowers to a tabView node,
    /// and `.tabViewStyle(.page(...))` / `.indexViewStyle(.page(...))` ride WASM.
    func testWave1PagedTabViewAndStylesLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                TabView {
                    Text("Page 1")
                    Text("Page 2")
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "no slot: \(body)")
        XCTAssertTrue(body.contains("N.tabView(tabs:"), "paged TabView lowers to a node: \(body)")
        XCTAssertTrue(body.contains(".tabViewStyle(\"page.always\")"), "tabViewStyle: \(body)")
        XCTAssertTrue(body.contains(".indexViewStyle(\"page.never\")"), "indexViewStyle: \(body)")
    }

    /// A TabView with `.tabItem` (the tab-BAR form) still slots — demote-safe.
    func testWave1TabBarFormStillSlots() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                TabView {
                    Text("Home").tabItem { Label("Home", systemImage: "house") }
                    Text("Settings").tabItem { Label("Settings", systemImage: "gear") }
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains("N.opaque"), "tab-bar form slots gracefully: \(body)")
    }

    /// G3 `Shape.trim(from:to:)` lowers (the progress-ring idiom; `to:` is a
    /// marshalled scalar input that rides WASM).
    func testWave1ShapeTrimLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            let progress: Double
            var body: some View {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 8))
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "no slot: \(body)")
        XCTAssertTrue(body.contains(".trim(from: Double(0), to: Double(progress))"),
                      "trim rides a marshalled input: \(body)")
    }

    /// G6 `.allowsHitTesting(Bool)` + G10 `.scrollClipDisabled()` lower (bool form).
    func testWave1AllowsHitTestingAndScrollClipDisabledLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("x")
                    .allowsHitTesting(false)
                    .scrollClipDisabled()
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "no slot: \(body)")
        XCTAssertTrue(body.contains(".allowsHitTesting(false)"), "allowsHitTesting lowers: \(body)")
        XCTAssertTrue(body.contains(".scrollClipDisabled(true)"), "scrollClipDisabled lowers: \(body)")
    }

    /// G37 `.scrollContentBackground(.hidden)` + G38 `.listRowSeparator`/
    /// `.listRowBackground(view)`/`.listRowInsets(EdgeInsets)` lower.
    func testWave1ScrollContentBackgroundAndListRowModifiersLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            let items: [String]
            var body: some View {
                List {
                    ForEach(items, id: \\.self) { it in
                        Text(it)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.blue)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "no slot: \(body)")
        XCTAssertTrue(body.contains(".scrollContentBackground(\"hidden\")"), "scrollContentBackground: \(body)")
        XCTAssertTrue(body.contains(".listRowSeparator(\"hidden\", edges: \"all\")"), "listRowSeparator: \(body)")
        XCTAssertTrue(body.contains(".listRowBackground([N.color"), "listRowBackground rides a child: \(body)")
        XCTAssertTrue(body.contains(".listRowInsets(IREdgeInsets(top: Double(4), leading: Double(8), bottom: Double(4), trailing: Double(8)))"),
                      "listRowInsets: \(body)")
    }

    /// Sweep (scroll/layout): the high-value scroll/layout modifiers that previously
    /// slotted now LOWER — scrollDisabled/scrollIndicators/scrollTargetBehavior/
    /// scrollTargetLayout/scrollBounceBehavior/contentMargins/safeAreaPadding.
    func testSweepScrollAndLayoutModifiersLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                ScrollView {
                    LazyVStack {
                        Text("a")
                        Text("b")
                    }
                    .scrollTargetLayout()
                }
                .scrollDisabled(false)
                .scrollIndicators(.hidden, axes: .vertical)
                .scrollTargetBehavior(.paging)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .safeAreaPadding(.top, 12)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "scroll/layout surface lowers with no slot: \(body)")
        XCTAssertTrue(body.contains(".scrollDisabled(false)"), "scrollDisabled lowers: \(body)")
        XCTAssertTrue(body.contains(".scrollIndicators(\"hidden\", axes: \"vertical\")"),
                      "scrollIndicators lowers: \(body)")
        XCTAssertTrue(body.contains(".scrollTargetBehavior(\"paging\")"), "scrollTargetBehavior lowers: \(body)")
        XCTAssertTrue(body.contains(".scrollTargetLayout(isEnabled: true)"), "scrollTargetLayout lowers: \(body)")
        XCTAssertTrue(body.contains(".scrollBounceBehavior(\"basedOnSize\", axes: \"vertical\")"),
                      "scrollBounceBehavior lowers: \(body)")
        XCTAssertTrue(body.contains(".contentMargins(edges: \"horizontal\", Double(16), placement: \"scrollContent\")"),
                      "contentMargins lowers: \(body)")
        XCTAssertTrue(body.contains(".safeAreaPadding(edges: \"top\", Double(12), insets: nil)"),
                      "safeAreaPadding lowers: \(body)")
    }

    /// Sweep: additional faithful forms — `.scrollIndicators(.visible)` (no axes →
    /// default "all"), `.safeAreaPadding(16)` (all-edges length), `.safeAreaPadding(
    /// EdgeInsets(...))`, `.contentMargins(16)` (all edges), `.scrollTargetLayout(
    /// isEnabled: false)`.
    func testSweepScrollAndLayoutAlternateFormsLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                VStack {
                    ScrollView { Text("a") }
                        .scrollIndicators(.never)
                        .scrollTargetLayout(isEnabled: false)
                        .contentMargins(20)
                        .contentMargins(8, for: .scrollIndicators)
                        .scrollBounceBehavior(.always)
                    ScrollView { Text("b") }
                        .safeAreaPadding(16)
                    ScrollView { Text("c") }
                        .safeAreaPadding(EdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4))
                    ScrollView { Text("d") }
                        .safeAreaPadding(.horizontal)
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "alternate forms lower with no slot: \(body)")
        XCTAssertTrue(body.contains(".scrollIndicators(\"never\", axes: \"all\")"), "default axes + .never: \(body)")
        XCTAssertTrue(body.contains(".scrollTargetLayout(isEnabled: false)"), "explicit false: \(body)")
        XCTAssertTrue(body.contains(".contentMargins(edges: \"all\", Double(20), placement: \"automatic\")"),
                      "all-edges contentMargins: \(body)")
        XCTAssertTrue(body.contains(".contentMargins(edges: \"all\", Double(8), placement: \"scrollIndicators\")"),
                      "length-only contentMargins with placement: \(body)")
        XCTAssertTrue(body.contains(".scrollBounceBehavior(\"always\", axes: \"vertical\")"),
                      "scrollBounceBehavior .always default axes: \(body)")
        XCTAssertTrue(body.contains(".safeAreaPadding(edges: \"all\", Double(16), insets: nil)"),
                      "all-edges length safeAreaPadding: \(body)")
        XCTAssertTrue(body.contains(".safeAreaPadding(edges: \"all\", nil, insets: IREdgeInsets(top: Double(1)"),
                      "EdgeInsets safeAreaPadding: \(body)")
        XCTAssertTrue(body.contains(".safeAreaPadding(edges: \"horizontal\", nil, insets: nil)"),
                      "edges-only safeAreaPadding: \(body)")
    }

    /// Sweep DEMOTE-SAFE: a non-literal/unrecognized form of each scroll/layout
    /// modifier SLOTS (never forces the whole view native). `.scrollPosition` and
    /// `.matchedGeometryEffect` are deliberately left slotting too.
    func testSweepScrollAndLayoutUnsupportedFormsSlot() throws {
        let source = """
        import SwiftUI
        struct V: View {
            let flag: Bool
            @Namespace var ns
            @State var pos: Int?
            var body: some View {
                VStack {
                    ScrollView { Text("a") }
                        .scrollDisabled(flag)
                        .scrollPosition(id: $pos)
                    Text("b").matchedGeometryEffect(id: "x", in: ns)
                    ScrollView { Text("c") }
                        .scrollTargetBehavior(.viewAligned)
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        // The faithful `.scrollTargetBehavior(.viewAligned)` STILL lowers (rides WASM).
        XCTAssertTrue(body.contains(".scrollTargetBehavior(\"viewAligned\")"),
                      "viewAligned lowers: \(body)")
        // The non-literal `.scrollDisabled(flag)`, the binding `.scrollPosition`, and
        // `.matchedGeometryEffect` each SLOT — they appear ONLY inside an opaque slot
        // (the whole expression rendered natively), NEVER as a lowered IR builder call.
        XCTAssertTrue(body.contains("N.opaque"), "unsupported forms slot (not demote): \(body)")
        // A LOWERED scrollDisabled would emit `.scrollDisabled(false)`/`(true)` — the
        // non-literal `flag` form never produces a bool-literal builder call.
        XCTAssertFalse(body.contains(".scrollDisabled(true)") || body.contains(".scrollDisabled(false)"),
                       "non-literal scrollDisabled did not lower to a bool builder call: \(body)")
        // `.scrollPosition`/`.matchedGeometryEffect` have NO IR builder — if they
        // lowered, the body would carry an `N.…scrollPosition`/`…matchedGeometryEffect`
        // BUILDER chain (a `)` -closing call), not an opaque-slot source-label string.
        // They slot, so the only occurrence is inside `N.opaque(... label: "...")`.
        for line in body.split(separator: "\n") {
            if line.contains("scrollPosition") || line.contains("matchedGeometryEffect") {
                XCTAssertTrue(line.contains("N.opaque"),
                              "scrollPosition/matchedGeometryEffect only inside an opaque slot: \(line)")
            }
        }
    }

    /// Sweep v6 (visibility / chrome / declarative effects): a batch of declarative
    /// enum/bool/scalar/ColorRef/ShapeKind modifiers that previously slotted now LOWER.
    func testSweepVisibilityChromeModifiersLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                VStack {
                    Text("a")
                        .hidden()
                        .menuIndicator(.hidden)
                        .menuOrder(.fixed)
                        .headerProminence(.increased)
                        .contentTransition(.numericText)
                        .textSelection(.enabled)
                        .allowsTightening(true)
                        .flipsForRightToLeftLayoutDirection(false)
                        .lineLimit(2, reservesSpace: true)
                    Text("b")
                        .labelsHidden()
                        .compositingGroup()
                        .geometryGroup()
                        .drawingGroup()
                        .luminanceToAlpha()
                        .colorMultiply(.red)
                        .containerShape(.capsule)
                        .listItemTint(.blue)
                        .listRowSeparatorTint(.green, edges: .top)
                        .persistentSystemOverlays(.hidden)
                        .invalidatableContent(true)
                        .selectionDisabled(true)
                        .deleteDisabled(false)
                        .moveDisabled(true)
                }
                .background(Color.blue.opacity(0.2))
                .backgroundStyle(.regularMaterial)
                .defaultScrollAnchor(.bottom)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "v6 surface lowers with no slot: \(body)")
        XCTAssertTrue(body.contains(".hidden()"), "hidden lowers: \(body)")
        XCTAssertTrue(body.contains(".labelsHidden()"), "labelsHidden lowers: \(body)")
        XCTAssertTrue(body.contains(".menuIndicator(\"hidden\")"), "menuIndicator lowers: \(body)")
        XCTAssertTrue(body.contains(".menuOrder(\"fixed\")"), "menuOrder lowers: \(body)")
        XCTAssertTrue(body.contains(".headerProminence(\"increased\")"), "headerProminence lowers: \(body)")
        XCTAssertTrue(body.contains(".contentTransition(\"numericText\")"), "contentTransition lowers: \(body)")
        XCTAssertTrue(body.contains(".textSelection(true)"), "textSelection lowers: \(body)")
        XCTAssertTrue(body.contains(".allowsTightening(true)"), "allowsTightening lowers: \(body)")
        XCTAssertTrue(body.contains(".flipsForRightToLeftLayoutDirection(false)"),
                      "flipsForRightToLeftLayoutDirection lowers: \(body)")
        XCTAssertTrue(body.contains(".lineLimitReservesSpace(limit: 2, reservesSpace: true)"),
                      "lineLimit(reservesSpace:) lowers: \(body)")
        XCTAssertTrue(body.contains(".compositingGroup()"), "compositingGroup lowers: \(body)")
        XCTAssertTrue(body.contains(".geometryGroup()"), "geometryGroup lowers: \(body)")
        XCTAssertTrue(body.contains(".drawingGroup(opaque: false)"), "drawingGroup lowers: \(body)")
        XCTAssertTrue(body.contains(".luminanceToAlpha()"), "luminanceToAlpha lowers: \(body)")
        XCTAssertTrue(body.contains(".colorMultiply("), "colorMultiply lowers: \(body)")
        XCTAssertTrue(body.contains(".containerShape("), "containerShape lowers: \(body)")
        XCTAssertTrue(body.contains(".listItemTint("), "listItemTint lowers: \(body)")
        XCTAssertTrue(body.contains(".listRowSeparatorTint(") && body.contains("edges: \"top\""),
                      "listRowSeparatorTint lowers with edges: \(body)")
        XCTAssertTrue(body.contains(".persistentSystemOverlays(\"hidden\")"),
                      "persistentSystemOverlays lowers: \(body)")
        XCTAssertTrue(body.contains(".invalidatableContent(true)"), "invalidatableContent lowers: \(body)")
        XCTAssertTrue(body.contains(".selectionDisabled(true)"), "selectionDisabled lowers: \(body)")
        XCTAssertTrue(body.contains(".deleteDisabled(false)"), "deleteDisabled lowers: \(body)")
        XCTAssertTrue(body.contains(".moveDisabled(true)"), "moveDisabled lowers: \(body)")
        XCTAssertTrue(body.contains(".background(.material(.regular), in: nil)"),
                      "backgroundStyle lowers via background(_:in:): \(body)")
        XCTAssertTrue(body.contains(".defaultScrollAnchor(.bottom)"), "defaultScrollAnchor lowers: \(body)")
    }

    /// Sweep v6 DEMOTE-SAFE: an unrecognized form of each v6 modifier SLOTS (never
    /// forces the whole view native). A non-literal bool, an unknown enum case, a
    /// custom-shape containerShape, and a non-literal color each slot.
    func testSweepVisibilityChromeUnsupportedFormsSlot() throws {
        let source = """
        import SwiftUI
        struct V: View {
            let flag: Bool
            let tint: Color
            var body: some View {
                VStack {
                    Text("a").allowsTightening(flag)
                    Text("b").listItemTint(tint)
                    Text("c").menuOrder(.custom)
                    Text("d").contentTransition(.symbolEffect)
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains("N.opaque"), "unsupported v6 forms slot (not demote): \(body)")
        // A LOWERED allowsTightening would emit a bool-literal builder call; the
        // non-literal `flag` form must not.
        XCTAssertFalse(body.contains(".allowsTightening(true)") || body.contains(".allowsTightening(false)"),
                       "non-literal allowsTightening did not lower: \(body)")
        // Unknown enum cases never reach the lowered builder calls.
        XCTAssertFalse(body.contains(".menuOrder(\"custom\")"), "unknown menuOrder case slots: \(body)")
        XCTAssertFalse(body.contains(".contentTransition(\"symbolEffect\")"),
                       "unknown contentTransition case slots: \(body)")
    }

    /// The transform/effect modifiers lower (rotation/scale/blur/brightness/etc.).
    func testTransformEffectModifierSurfaceLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("x")
                    .rotationEffect(.degrees(45), anchor: .topLeading)
                    .scaleEffect(x: 1.2, y: 0.8)
                    .blur(radius: 2)
                    .brightness(0.1)
                    .saturation(0.5)
                    .hueRotation(.degrees(90))
                    .colorInvert()
                    .blendMode(.multiply)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "transform surface lowers with no slot: \(body)")
        XCTAssertTrue(body.contains(".rotationEffect(degrees: Double(45), anchor: .topLeading)"), body)
        XCTAssertTrue(body.contains(".scaleEffect(x: Double(1.2), y: Double(0.8), anchor: nil)"), body)
        XCTAssertTrue(body.contains(".blur(radius: Double(2), opaque: false)"), body)
        XCTAssertTrue(body.contains(".brightness(Double(0.1))"), body)
        XCTAssertTrue(body.contains(".hueRotation(degrees: Double(90))"), body)
        XCTAssertTrue(body.contains(".colorInvert()"), body)
        XCTAssertTrue(body.contains(".blendMode(.multiply)"), body)
    }

    /// The text-styling modifiers lower (fontWeight/underline/kerning/textCase/
    /// monospaced/redacted/symbolRenderingMode/imageScale).
    func testTextStylingModifierSurfaceLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("x")
                    .fontWeight(.bold)
                    .fontDesign(.rounded)
                    .underline(true, color: .red)
                    .kerning(1.5)
                    .tracking(2)
                    .lineSpacing(4)
                    .textCase(.uppercase)
                    .minimumScaleFactor(0.5)
                    .truncationMode(.middle)
                    .monospacedDigit()
                    .redacted(reason: .placeholder)
                    .symbolRenderingMode(.hierarchical)
                    .imageScale(.large)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "text-styling surface lowers with no slot: \(body)")
        XCTAssertTrue(body.contains(".fontWeight(.bold)"), body)
        XCTAssertTrue(body.contains(".fontDesign(.rounded)"), body)
        XCTAssertTrue(body.contains(".underline(true, color: .named(\"red\"))"), body)
        XCTAssertTrue(body.contains(".kerning(Double(1.5))"), body)
        XCTAssertTrue(body.contains(".textCase(\"uppercase\")"), body)
        XCTAssertTrue(body.contains(".truncationMode(\"middle\")"), body)
        XCTAssertTrue(body.contains(".monospacedDigit()"), body)
        XCTAssertTrue(body.contains(".redacted(reason: \"placeholder\")"), body)
        XCTAssertTrue(body.contains(".symbolRenderingMode(\"hierarchical\")"), body)
        XCTAssertTrue(body.contains(".imageScale(\"large\")"), body)
    }

    /// Built-in control-config styles lower to the carried case names; a custom
    /// style STRUCT slots (the honest boundary).
    func testControlConfigStylesLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Button("Go") { }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardType(.emailAddress)
                    .submitLabel(.go)
                    .preferredColorScheme(.dark)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "built-in control styles lower: \(body)")
        XCTAssertTrue(body.contains(".buttonStyle(.borderedProminent)"), body)
        XCTAssertTrue(body.contains(".controlSize(\"large\")"), body)
        XCTAssertTrue(body.contains(".keyboardType(\"emailAddress\")"), body)
        XCTAssertTrue(body.contains(".submitLabel(\"go\")"), body)
        XCTAssertTrue(body.contains(".preferredColorScheme(\"dark\")"), body)
    }

    /// Additional built-in control styles (styles-views wave) lower to their carried
    /// case names: textFieldStyle / datePickerStyle / controlGroupStyle /
    /// groupBoxStyle / disclosureGroupStyle / tableStyle.
    func testAdditionalControlStylesLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var q = ""
            var body: some View {
                VStack {
                    TextField("Search", text: $q)
                        .textFieldStyle(.roundedBorder)
                    GroupBox {
                        Text("a")
                    }
                    .groupBoxStyle(.automatic)
                    DisclosureGroup("More") {
                        Text("b")
                    }
                    .disclosureGroupStyle(.automatic)
                    ControlGroup {
                        Button("X") { }
                    }
                    .controlGroupStyle(.navigation)
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains(".textFieldStyle(\"roundedBorder\")"), body)
        XCTAssertTrue(body.contains(".groupBoxStyle(\"automatic\")"), body)
        XCTAssertTrue(body.contains(".disclosureGroupStyle(\"automatic\")"), body)
        XCTAssertTrue(body.contains(".controlGroupStyle(\"navigation\")"), body)
    }

    /// `.datePickerStyle(.compact)` rides as a String modifier (its base view may
    /// still slot — the modifier itself lowers).
    func testDatePickerStyleModifierLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Text("x").datePickerStyle(.graphical)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains(".datePickerStyle(\"graphical\")"), body)
    }

    /// A CUSTOM style STRUCT for a new style modifier (`.textFieldStyle(MyStyle())`)
    /// makes the whole expression slot (an unrecognized modifier returns nil → the
    /// node is emitted as a native `.opaque` slot — demote-safe, matching how a
    /// custom `.buttonStyle(MyStyle())` slots).
    func testCustomTextFieldStyleStaysSlotted() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var q = ""
            var body: some View {
                TextField("x", text: $q).textFieldStyle(MyCustomStyle())
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains("N.opaque"), "a custom textFieldStyle slots the expression: \(body)")
        XCTAssertFalse(body.contains(".textFieldStyle(\""),
                       "a custom textFieldStyle struct is not carried as a lowered String modifier: \(body)")
    }

    /// A DECLARATIVE `Path { p in … }` of LITERAL scalar commands lowers to
    /// `N.path([IRPathCommand…])` (the render side replays it into a real `Path`).
    func testPathLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: 100, y: 0))
                    p.addQuadCurve(to: CGPoint(x: 100, y: 100), control: CGPoint(x: 120, y: 50))
                    p.addLine(to: CGPoint(x: 0, y: 100))
                    p.closeSubpath()
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "a literal Path lowers, not slots: \(body)")
        XCTAssertTrue(body.contains("N.path("), "Path lowers to N.path: \(body)")
        XCTAssertTrue(body.contains("IRPathCommand.move(x: Double(0), y: Double(0))"), body)
        XCTAssertTrue(body.contains("IRPathCommand.line(x: Double(100), y: Double(0))"), body)
        XCTAssertTrue(body.contains("IRPathCommand.quad("), body)
        XCTAssertTrue(body.contains("IRPathCommand.closeSubpath"), body)
    }

    /// A `Path` with a NON-literal coordinate (`.zero`, a computed value, an unknown
    /// command like `addArc`) keeps SLOTTING — never a partial/wrong path.
    func testNonLiteralPathStaysSlotted() throws {
        let source = """
        import SwiftUI
        struct V: View {
            let w: CGFloat = 50
            var body: some View {
                VStack {
                    Path { p in
                        p.move(to: CGPoint(x: w, y: 0))
                        p.addLine(to: CGPoint(x: 100, y: 0))
                    }
                    Path { p in
                        p.addArc(center: CGPoint(x: 0, y: 0), radius: 10, startAngle: .zero, endAngle: .degrees(90), clockwise: true)
                    }
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.path("),
                       "a Path with a non-literal coord / unknown command slots: \(body)")
        XCTAssertTrue(body.contains("N.opaque"), "the non-literal Paths slot: \(body)")
        XCTAssertTrue(body.contains("N.vstack("), "the shell still lowers: \(body)")
    }

    /// `Path { p in p.addRect(CGRect(...)) }` and `addRoundedRect(in:cornerRadius:)`
    /// lower to their rect commands.
    func testPathRectCommandsLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Path { p in
                    p.addRect(CGRect(x: 0, y: 0, width: 10, height: 20))
                    p.addRoundedRect(in: CGRect(x: 1, y: 2, width: 30, height: 40), cornerRadius: 4)
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains("N.path("), body)
        XCTAssertTrue(body.contains("IRPathCommand.addRect(x: Double(0), y: Double(0), width: Double(10), height: Double(20))"), body)
        XCTAssertTrue(body.contains("IRPathCommand.addRoundedRect(x: Double(1), y: Double(2), width: Double(30), height: Double(40), cornerRadius: Double(4))"), body)
    }

    /// A CUSTOM ButtonStyle struct (`.buttonStyle(MyStyle())`) stays NATIVE — only
    /// built-in named cases lower (the documented honest limit).
    func testCustomButtonStyleStaysOpaque() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Button("Go") { }.buttonStyle(MyFancyStyle())
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains("N.opaque"), "a custom ButtonStyle slots: \(body)")
        // The whole `Button(...).buttonStyle(MyFancyStyle())` slotted: no lowered
        // `N.button(...)` builder node was emitted (the `.buttonStyle(` text only
        // survives inside the opaque leaf's descriptive label, not as a builder call).
        XCTAssertFalse(body.contains("N.button("),
                       "a custom ButtonStyle slots the whole expression, not a lowered node: \(body)")
    }

    /// Lifecycle + gesture modifiers lower (onAppear/onChange/task/drag/longPress).
    func testLifecycleAndGestureModifiersLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var count = 0
            var body: some View {
                Text("x")
                    .onAppear { count = 1 }
                    .onChange(of: count) { count += 1 }
                    .onLongPressGesture(minimumDuration: 0.4) { count = 0 }
                    .gesture(DragGesture().onChanged { _ in }.onEnded { _ in })
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains(".onAppear(event:"), "onAppear lowers: \(body)")
        XCTAssertTrue(body.contains(".onChange(valueKey: \"count\", event:"), "onChange lowers: \(body)")
        XCTAssertTrue(body.contains(".onLongPressGesture(minimumDuration: Double(0.4), event:"),
                      "onLongPressGesture lowers: \(body)")
    }

    /// `.animation(_:value:)` and `.transition(_:)` lower with literal params.
    func testAnimationAndTransitionLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var on = false
            var body: some View {
                Text("x")
                    .animation(.easeInOut(duration: 0.3), value: on)
                    .transition(.move(edge: .bottom))
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertFalse(body.contains("N.opaque"), "animation+transition lower: \(body)")
        XCTAssertTrue(body.contains(".animation(IRAnimation(curve: \"easeInOut\", duration: 0.3), valueKey: \"on\")"),
                      "animation lowers with the curve + duration: \(body)")
        XCTAssertTrue(body.contains(".transition(.move(edge: \"bottom\"))"), "transition lowers: \(body)")
    }

    /// A non-literal `.disabled(expr)` and a value-bearing `ProgressView(value:)`
    /// stay NATIVE (slotted) — the honest-limits boundary of IR v2.
    func testDynamicDisabledStaysOpaqueAndDeterminateProgressLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            let busy: Bool
            let frac: Double
            var body: some View {
                VStack {
                    ProgressView(value: frac)
                    Text("x").disabled(busy)
                }
            }
        }
        """
        let lowering = BodyLowering()
        let body = try XCTUnwrap(lowering.emitGuestBody(source: source))
        // The determinate `ProgressView(value: frac)` NOW lowers (a marshalled Double
        // input); the dynamic `.disabled(busy)` still slots the whole Text (the
        // modifier-chain fallback renders the expression natively).
        XCTAssertTrue(body.contains("N.opaque"), "the dynamic .disabled form slots: \(body)")
        XCTAssertTrue(body.contains("N.progressView(value: Double(frac)"),
            "ProgressView(value:) lowers to the determinate node: \(body)")
        // The Text+disabled slotted WHOLE: no lowered `N.text("x")...disabled(...)`
        // builder chain was emitted (the `.disabled(` text only survives inside the
        // opaque leaf's descriptive label, not as a builder call).
        XCTAssertFalse(body.contains("N.text(\"x\").disabled"),
            "a dynamic .disabled(expr) is not lowered as a builder chain: \(body)")
    }

    // MARK: - 1b. HOST-STATE tier (B — presentation / selection / navigation / focus)

    /// `.sheet(isPresented:)` lowers: the bound `$flag` becomes the presentation key
    /// + a `.setBool` dispatch rule (so a swipe-dismiss flips the guest flag), and the
    /// content recurses. No opaque fallback for this whole-body form.
    func testSheetIsPresentedLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var showing = false
            var body: some View {
                Button("Open") { showing = true }
                    .sheet(isPresented: $showing) {
                        Text("Sheet body")
                    }
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source).first)
        let body = lowered.guestBody
        XCTAssertTrue(body.contains("N.opaque") == false, "sheet(isPresented:) lowers fully: \(body)")
        XCTAssertTrue(body.contains(".sheet(presentedKey: \"showing\""), "carries the flag key: \(body)")
        XCTAssertTrue(body.contains("N.text(\"Sheet body\")"), "sheet content recurses: \(body)")
        // A `.setBool` rule on the `showing` field drives present/dismiss in WASM.
        let model = try XCTUnwrap(lowered.stateModel)
        XCTAssertTrue(model.fields.contains { $0.name == "showing" && $0.kind == .bool })
        XCTAssertTrue(model.rules.contains { $0.field == "showing" })
    }

    /// `.alert(_:isPresented:actions:message:)` lowers with the action Buttons (incl.
    /// `Button(role: .destructive)`) recursing — they auto-wire host-side via actionID.
    func testAlertLowersWithRoleButtons() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var confirming = false
            var body: some View {
                Text("Body")
                    .alert("Delete?", isPresented: $confirming) {
                        Button("Delete", role: .destructive) { }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This cannot be undone")
                    }
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source).first)
        let body = lowered.guestBody
        XCTAssertTrue(body.contains(".alert(\"Delete?\""), "alert lowers: \(body)")
        XCTAssertTrue(body.contains("role: .destructive"), "destructive role carried: \(body)")
        XCTAssertTrue(body.contains("role: .cancel"), "cancel role carried: \(body)")
        XCTAssertTrue(body.contains("N.text(\"This cannot be undone\")"), "message recurses: \(body)")
        XCTAssertFalse(body.contains("N.opaque"), "no fallback for this alert form: \(body)")
    }

    /// `.fullScreenCover`/`.popover`/`.confirmationDialog`/`.navigationDestination(isPresented:)`
    /// all lower via the same Bool bridge.
    func testOtherPresentationFormsLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var a = false
            @State private var b = false
            @State private var c = false
            @State private var d = false
            var body: some View {
                VStack {
                    Color.clear.fullScreenCover(isPresented: $a) { Text("cover") }
                    Color.clear.popover(isPresented: $b) { Text("pop") }
                    Color.clear.confirmationDialog("Pick", isPresented: $c) { Button("OK") { } }
                    Color.clear.navigationDestination(isPresented: $d) { Text("dest") }
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains(".fullScreenCover(presentedKey: \"a\""), body)
        XCTAssertTrue(body.contains(".popover(presentedKey: \"b\""), body)
        XCTAssertTrue(body.contains(".confirmationDialog(\"Pick\""), body)
        XCTAssertTrue(body.contains(".navigationDestination(presentedKey: \"d\""), body)
    }

    /// `Picker(selection:)` over `Text(...).tag(Int)` rows lowers to an Int-tagged
    /// picker node + a `.setIntClamped` rule (the guest assigns the picked tag).
    func testIntPickerLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var choice = 0
            var body: some View {
                Picker("Flavor", selection: $choice) {
                    Text("Vanilla").tag(0)
                    Text("Chocolate").tag(1)
                }
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source).first)
        let body = lowered.guestBody
        XCTAssertTrue(body.contains("N.picker("), "picker lowers: \(body)")
        XCTAssertTrue(body.contains("IRPickerOption(tag: .int(0)"), "tag 0 carried: \(body)")
        XCTAssertTrue(body.contains("IRPickerOption(tag: .int(1)"), "tag 1 carried: \(body)")
        XCTAssertTrue(body.contains("selection: choice, options:"), "selection field bound: \(body)")
        XCTAssertFalse(body.contains("N.opaque"), "no fallback: \(body)")
        let model = try XCTUnwrap(lowered.stateModel)
        XCTAssertTrue(model.rules.contains { $0.field == "choice" })
    }

    /// A String-tagged Picker lowers with `.string` tags + a `.setString` rule.
    func testStringPickerLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var sort = "name"
            var body: some View {
                Picker("Sort", selection: $sort) {
                    Text("Name").tag("name")
                    Text("Date").tag("date")
                }
                .pickerStyle(.segmented)
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains("IRPickerOption(tag: .string(\"name\")"), body)
        XCTAssertTrue(body.contains("IRPickerOption(tag: .string(\"date\")"), body)
        XCTAssertTrue(body.contains(".pickerStyle(\"segmented\")"), "pickerStyle still rides: \(body)")
    }

    /// The EAGER `NavigationLink(destination:) { label }` lowers (both subtrees recurse).
    func testNavigationLinkEagerLowers() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                NavigationLink {
                    Text("Detail")
                } label: {
                    Text("Go")
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains("N.navigationLink(destination:"), body)
        XCTAssertTrue(body.contains("N.text(\"Detail\")"), "destination recurses: \(body)")
        XCTAssertTrue(body.contains("N.text(\"Go\")"), "label recurses: \(body)")
        XCTAssertFalse(body.contains("N.opaque"), body)
    }

    /// `.searchable(text:)` lowers to a host search-bar bridge + a `.setString` rule;
    /// `.toolbar { ToolbarItem }`/`EditButton`/`Button(role:)` also lower.
    func testSearchableToolbarEditButtonLower() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var query = ""
            var body: some View {
                List {
                    EditButton()
                }
                .searchable(text: $query, prompt: "Search")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Add") { }
                    }
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains(".searchable(searchKey: \"query\""), body)
        XCTAssertTrue(body.contains("prompt: \"Search\""), body)
        XCTAssertTrue(body.contains("N.editButton"), "EditButton lowers: \(body)")
        XCTAssertTrue(body.contains(".toolbar(items:"), "toolbar lowers: \(body)")
        XCTAssertTrue(body.contains("IRToolbarItem(placement: \"navigationBarTrailing\""), body)
    }

    /// HONEST LIMITS: a value-based `NavigationLink(value:)`, a custom-Hashable Picker
    /// tag, an `item:`-presentation, and a `DatePicker` (no static lowering of its
    /// epoch mutation) all SLOT rather than lower wrongly.
    func testHostStateHonestLimitsSlot() throws {
        let source = """
        import SwiftUI
        struct V: View {
            @State private var sel: Item? = nil
            @State private var showItem = false
            var body: some View {
                VStack {
                    NavigationLink("Push", value: 42)
                    Color.clear.sheet(item: $sel) { it in Text(it.name) }
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        // The value-based link slots (no destination registry in static lowering).
        XCTAssertTrue(body.contains("N.opaque"), "value-link + item-sheet slot: \(body)")
        XCTAssertFalse(body.contains("N.navigationLink(destination:"),
            "a value-based NavigationLink does NOT lower to the eager node: \(body)")
        XCTAssertFalse(body.contains(".sheetItem"),
            "the item: sheet form is not statically lowered (would need item marshalling): \(body)")
    }

    // MARK: - 1c. GeometryReader (C — promoted to host-state) + Canvas boundary

    /// `GeometryReader { proxy in <body using proxy.size/.frame> }` lowers to a
    /// `N.geometryReader(id:, [<body>])` whose child reads the reserved `__geo_*`
    /// inputs (the engine rewrites `proxy.size.width`→`__geo_width`, etc.), and the
    /// guest emitter binds those reserved inputs from the input JSON. The reserved
    /// scalars flow through dynamic-accepting contexts (`.frame` width/height,
    /// `Text` interpolation, arithmetic) like any marshalled `@State` scalar.
    func testGeometryReaderLowersWithGeoInputs() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                GeometryReader { proxy in
                    VStack {
                        Text("\\(Int(proxy.frame(in: .local).minX)),\\(Int(proxy.frame(in: .local).minY))")
                            .frame(width: proxy.size.width, height: proxy.size.height / 2)
                    }
                }
            }
        }
        """
        let lowered = try XCTUnwrap(BodyLowering().lowerAllViews(source: source).first)
        let body = lowered.guestBody
        // Lowers to a real geometryReader node, NOT a slot.
        XCTAssertTrue(body.contains("N.geometryReader(id: \"geo_"), body)
        XCTAssertFalse(body.contains("N.opaque"), "a mappable proxy body must NOT slot: \(body)")
        // The proxy member accesses are rewritten to the reserved input identifiers.
        XCTAssertTrue(body.contains("__geo_width"), "proxy.size.width → __geo_width: \(body)")
        XCTAssertTrue(body.contains("__geo_height"), "proxy.size.height → __geo_height: \(body)")
        XCTAssertTrue(body.contains("__geo_minX"), "proxy.frame(in:).minX → __geo_minX: \(body)")
        XCTAssertTrue(body.contains("__geo_minY"), "proxy.frame(in:).minY → __geo_minY: \(body)")
        // No live `proxy` identifier survives in the lowered body.
        XCTAssertFalse(body.contains("proxy"), "the proxy param must be fully rewritten away: \(body)")
        // The lowering flags geometry use so the guest emitter binds the reserved inputs.
        XCTAssertTrue(lowered.usesGeometry, "the lowered view must flag geometry use")

        // The guest emitter binds the reserved __geo_* inputs from the JSON blob.
        let guestViews = [SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, usesGeometry: lowered.usesGeometry)]
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)
        let wrapper = try XCTUnwrap(emission.files.first { $0.fileName == "_PatchSwiftUI.swift" })
        XCTAssertTrue(wrapper.contents.contains("let __geo_width = _patchScanDouble(_patchInputs, \"__geo_width\")"),
                      "the guest binds __geo_width from the input JSON")
        XCTAssertTrue(wrapper.contents.contains("let __geo_minY = _patchScanDouble(_patchInputs, \"__geo_minY\")"),
                      "the guest binds __geo_minY from the input JSON")
    }

    /// HONEST LIMIT: a `GeometryReader` whose body uses the proxy in a form the engine
    /// can't map to a reserved scalar (`proxy.size` whole, `proxy.safeAreaInsets`,
    /// `proxy[anchor]`, `.maxX`) DEMOTES the whole reader to a native slot — never a
    /// guest that references the unbound `proxy`.
    func testGeometryReaderUnmappableProxyUseSlots() throws {
        func bodyFor(_ inner: String) throws -> String {
            let source = """
            import SwiftUI
            struct V: View {
                var body: some View {
                    GeometryReader { proxy in
                        \(inner)
                    }
                }
            }
            """
            return try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        }
        // `proxy.size` used WHOLE (passed to a frame `CGSize`-style use) → slot.
        let whole = try bodyFor("Color.clear.frame(width: proxy.size.width).onAppear { _ = proxy.size }")
        XCTAssertTrue(whole.contains("N.opaque"), "proxy.size whole → slot: \(whole)")
        // `proxy.safeAreaInsets` (unmodeled) → slot.
        let safe = try bodyFor("Text(\"x\").padding(proxy.safeAreaInsets.top)")
        XCTAssertTrue(safe.contains("N.opaque"), "proxy.safeAreaInsets → slot: \(safe)")
        // `.maxX` (needs arithmetic we don't synthesize) → slot.
        let maxx = try bodyFor("Text(\"x\").offset(x: proxy.frame(in: .local).maxX)")
        XCTAssertTrue(maxx.contains("N.opaque"), "proxy.frame(in:).maxX → slot: \(maxx)")
        XCTAssertFalse(maxx.contains("N.geometryReader"), "unmappable reader must not lower: \(maxx)")
    }

    /// `Canvas { ctx, size in … }` is a deliberate ENGINE boundary: faithfully parsing
    /// imperative `GraphicsContext` draw closures is out of the demote-safe budget, so
    /// the engine SLOTS Canvas (the `canvas(ops:)` IR node + SDK replay exist and
    /// round-trip for hand-written/future emission — see the SDK render tests).
    func testCanvasSlotsFromEngine() throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View {
                Canvas { ctx, size in
                    ctx.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(.blue))
                }
            }
        }
        """
        let body = try XCTUnwrap(BodyLowering().emitGuestBody(source: source))
        XCTAssertTrue(body.contains("N.opaque"), "Canvas slots from the engine (honest boundary): \(body)")
        XCTAssertFalse(body.contains("N.canvas"), "the engine does not emit canvas ops: \(body)")
    }

    // MARK: - 2. Guest module emission

    func testGuestEmitterProducesViewBodyExport() throws {
        let lowering = BodyLowering()
        let lowered = lowering.lowerAllViews(source: profileSource)
        let guestViews = lowered.map {
            SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody, inputs: $0.inputs)
        }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        // Exports: per-view `view_body__ProfileCard`, the canonical `view_body`, plus
        // the allocator.
        XCTAssertTrue(emission.exports.contains("patch_malloc"))
        XCTAssertTrue(emission.exports.contains("view_body"))
        XCTAssertTrue(emission.exports.contains("view_body__ProfileCard"))

        // Files: the embeddable IR sources + the wrapper.
        let names = Set(emission.files.map { $0.fileName })
        XCTAssertTrue(names.contains("_PatchSwiftUI.swift"))
        XCTAssertTrue(names.contains("_ViewNodeIR_ViewNode.swift"))
        XCTAssertTrue(names.contains("_ViewNodeIR_JSONEmit.swift"))

        // The wrapper carries the @_cdecl export and emits the tree.
        let wrapper = try XCTUnwrap(emission.files.first { $0.fileName == "_PatchSwiftUI.swift" })
        XCTAssertTrue(wrapper.contents.contains("@_cdecl(\"view_body__ProfileCard\")"))
        XCTAssertTrue(wrapper.contents.contains("EmbeddedJSON.encode(emission)"))
    }

    // MARK: - 3. IR drift guard — the shipped IR resources MUST match ViewNodeIR

    func testEmbeddedIRMatchesCanonicalViewNodeIR() throws {
        // The guest ships a COPY of the IR (CodeGenerator GuestIR resources). Assert
        // each copy is byte-identical to the canonical `ViewNodeIR` target source, so
        // the wire format the SDK renderer matches can never silently drift.
        let emitter = SwiftUIGuestEmitter()
        let shipped = try emitter.irSources()
        // Locate the canonical ViewNodeIR sources relative to this test file.
        let here = URL(fileURLWithPath: #filePath)
        let pkgRoot = here.deletingLastPathComponent()  // .../Tests/PartitioningEngineTests
            .deletingLastPathComponent().deletingLastPathComponent()  // cli/
        let irDir = pkgRoot.appendingPathComponent("Sources/ViewNodeIR")
        for f in shipped {
            // `_ViewNodeIR_ViewNode.swift` → `ViewNode.swift`
            let base = f.fileName.replacingOccurrences(of: "_ViewNodeIR_", with: "")
            let canonical = irDir.appendingPathComponent(base)
            let canonicalText = try String(contentsOf: canonical, encoding: .utf8)
            XCTAssertEqual(f.contents, canonicalText,
                "shipped guest IR `\(base)` drifted from the canonical ViewNodeIR — "
                + "regenerate cli/Sources/CodeGenerator/GuestIR/\(base.replacingOccurrences(of: ".swift", with: ".swifttext"))")
        }
    }

    // MARK: - 4. END-TO-END: lower → compile → host-run view_body in WASM

    func testViewBodyExecutesInWasm() throws {
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__ProfileCard", "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping view_body execution")

        // Lower + emit the guest module.
        let lowering = BodyLowering()
        let lowered = lowering.lowerAllViews(source: profileSource)
        let guestViews = lowered.map {
            SwiftUIGuestEmitter.GuestView(viewName: $0.viewName, guestBody: $0.guestBody, inputs: $0.inputs)
        }
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.swiftui.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "SwiftUI guest WASM compile failed:\n\(result.log)")

        // Host-run view_body with a marshalled input (name).
        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        let inputs = Data(#"{"name":"Ada Lovelace"}"#.utf8)
        let outBytes = try runner.callPacked("view_body", [UInt8](inputs))
        XCTAssertFalse(outBytes.isEmpty, "view_body returned no bytes")

        // Decode the BodyEmission and assert the tree is the lowered ProfileCard.
        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
        let desc = body.root.describe()
        XCTAssertTrue(desc.contains("VStack"), "root is a VStack: \(desc)")
        XCTAssertTrue(desc.contains("Toggle"), "the interactive Toggle is in the tree")
        XCTAssertTrue(desc.contains("Image(systemName:\"star.fill\")"))
        // The marshalled-in `name` is reflected in the WASM-built tree.
        XCTAssertTrue(desc.contains("Ada Lovelace"), "Text(name) carried the input: \(desc)")

        // Self-reported coverage: the tree is overwhelmingly non-opaque (rides WASM).
        let cov = try XCTUnwrap(body.coverage)
        XCTAssertEqual(cov.opaqueNodes, 0, "no node fell back to native for this body")
    }

    /// END-TO-END (host-state tier): a body with `.sheet(isPresented:)` + a `Picker`
    /// + a `Button(role:)` LOWERS → COMPILES to WASM → host-runs `view_body` (the new
    /// node kinds emit through the Foundation-free EmbeddedJSON path) AND `dispatch`
    /// (the presentation-flag `.setBool` rule flips the flag IN WASM). This proves the
    /// v3 guest IR copies compile under Embedded Swift and the JSON shapes round-trip.
    func testHostStateBodyExecutesInWasm() throws {
        let source = """
        import SwiftUI
        struct HostStateScreen: View {
            @State private var showing = false
            @State private var choice = 0
            var body: some View {
                VStack {
                    Picker("Flavor", selection: $choice) {
                        Text("Vanilla").tag(0)
                        Text("Chocolate").tag(1)
                    }
                    Button("Open") { showing = true }
                        .sheet(isPresented: $showing) {
                            VStack {
                                Text("Sheet body")
                                Button("Delete", role: .destructive) { }
                            }
                        }
                }
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source).first)
        // thunkSafe iff the body lowered with ZERO opaque leaves (mixed-view-free)
        // and reads no unmarshalled input — the same gate the BuildPipeline applies.
        let thunkSafe = lowered.opaqueLeaves.isEmpty && !lowered.referencesUnmarshalledInput
        let guestViews = [SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, stateModel: lowered.stateModel,
            thunkSafe: thunkSafe)]
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping host-state execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-hoststate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.hoststate.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "host-state guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)

        // 1) Initial render: the Picker + sheet(isPresented:) + role button emit.
        let initial = try runner.callPacked("view_body", [UInt8](Data("{}".utf8)))
        let body0 = try JSONDecoder().decode(BodyEmission.self, from: Data(initial))
        let d0 = body0.root.describe()
        XCTAssertTrue(d0.contains("Picker(selection:int(0)"), "Picker emits with the int selection: \(d0)")
        XCTAssertTrue(d0.contains(".sheet(key:showing,isPresented:false"), "sheet flag false initially: \(d0)")
        // The destructive Button lives inside the sheet's MODIFIER content (which
        // `describe()` doesn't recurse), so assert against the raw emitted JSON — it
        // carries `"role":"destructive"` for the lowered `Button(role:.destructive)`.
        let json0 = String(decoding: initial, as: UTF8.self)
        XCTAssertTrue(json0.contains("\"role\":\"destructive\""),
                      "the destructive role button emits inside the sheet: \(json0)")
        XCTAssertTrue(json0.contains("\"sheet\""), "the sheet content is in the emitted tree")
        XCTAssertEqual(body0.coverage?.opaqueNodes, 0, "host-state body lowers fully (no opaque): \(d0)")

        // 2) Dispatch the sheet's present event with `.bool(true)`: the `.setBool` rule
        //    must flip `showing` to true IN WASM and re-emit with the flag set.
        let presentEvent = try XCTUnwrap(
            lowered.stateModel?.rules.first { $0.field == "showing" }?.eventID,
            "a presentation rule for `showing` was recorded")
        let envelope = #"{"state":"{\"showing\":false,\"choice\":0}","event":{"event":{"id":"\#(presentEvent)"}},"value":{"bool":{"_0":true}}}"#
        let dispatched = try runner.callPacked("dispatch", [UInt8](Data(envelope.utf8)))
        let result1 = try JSONDecoder().decode(DispatchResult.self, from: Data(dispatched))
        XCTAssertTrue(result1.state.contains("\"showing\":true"),
                      "the .setBool rule flipped the presentation flag in WASM: \(result1.state)")
        XCTAssertTrue(result1.tree.describe().contains(".sheet(key:showing,isPresented:true"),
                      "the re-emitted tree shows the sheet presented: \(result1.tree.describe())")
    }

    /// END-TO-END (PER-ROW INDEXED SLOT): the AccountSwitcher shape — a `ForEach` over a
    /// body-local collection with a custom per-row view + per-row native action — LOWERS
    /// → COMPILES to WASM (proving the v8 `indexedForEachSlot` node + the host-projected
    /// count token are Embedded-Swift-clean) → host-runs `view_body`, and the WASM-built
    /// tree carries the indexed-slot node. The row COUNT rides as a `__numtok_*` input the
    /// host supplies (the guest reads it in the `owners.count > 1` guard); when we marshal
    /// a count > 1 the guard's THEN-branch (the ScrollView + indexed slot) emits.
    func testIndexedForEachSlotExecutesInWasm() throws {
        let source = """
        import SwiftUI
        struct AccountSwitcher: View {
            @Environment(ScheduleService.self) private var schedule
            var body: some View {
                let owners = schedule.availableOwners
                if owners.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(owners, id: \\.id) { owner in
                                AccountChip(id: owner.id, label: owner.label, subtitle: owner.subtitle,
                                            selected: schedule.selectedOwnerId == owner.id) {
                                    schedule.selectedOwnerId = owner.id
                                }
                            }
                        }.padding(.horizontal, 20)
                    }.scrollClipDisabled()
                }
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source, sameFileThunk: true).first)
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
            "no free guest identifier leaks (unresolved: \(lowered.unresolvedSymbols))")
        let slot = try XCTUnwrap(lowered.indexedRowSlots.first, "an indexed-row slot was recorded")

        let thunkSafe = lowered.opaqueLeaves.allSatisfy { $0.slotable }
            && !lowered.indexedRowSlots.isEmpty
        XCTAssertTrue(thunkSafe, "AccountSwitcher is routable via the indexed-row slot")

        let guestViews = [SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, stateModel: lowered.stateModel,
            thunkSafe: thunkSafe, usesGeometry: lowered.usesGeometry,
            inputTokens: lowered.hostTokens.filter { $0.ridesInputJSON })]
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping indexed-slot execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-rowslot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.rowslot.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "indexed-slot guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        // The host supplies the row count under the count token's reserved `__numtok_*`
        // key (the thunk evaluates `schedule.availableOwners.count` natively). Marshal a
        // count of 3 so the `owners.count > 1` guard's THEN-branch emits.
        let countToken = try XCTUnwrap(lowered.hostTokens.first { $0.kind == .number })
        let inputJSON = "{\"\(countToken.inputKey)\":3}"
        let outBytes = try runner.callPacked("view_body", [UInt8](Data(inputJSON.utf8)))
        XCTAssertFalse(outBytes.isEmpty, "view_body returned no bytes")

        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
        let desc = body.root.describe()
        // The guard's THEN-branch is present: ScrollView → HStack → the indexed-row slot.
        XCTAssertTrue(desc.contains("ScrollView(axis:horizontal)"), "the scroll view emits: \(desc)")
        XCTAssertTrue(desc.contains("IndexedForEachSlot(#\(slot.id)"),
            "the WASM-built tree carries the indexed-row slot node: \(desc)")
        // Raw JSON carries the indexed-slot node's countKey (host-read).
        let json = String(decoding: outBytes, as: UTF8.self)
        XCTAssertTrue(json.contains("indexedForEachSlot"), "the node serializes through the embedded JSON path")
        XCTAssertTrue(json.contains(slot.countKey), "the countKey rides the node: \(slot.countKey)")
        // No node fell back to a native OPAQUE slot (the rows are the indexed slot, not opaque).
        XCTAssertEqual(body.coverage?.opaqueNodes, 0, "no opaque node — the ForEach became an indexed-row slot: \(desc)")

        // With a count of 1 (≤ guard), the guard's else (empty group) emits — proving the
        // host-projected count token genuinely drives the guard IN WASM.
        let outBytes1 = try runner.callPacked("view_body", [UInt8](Data("{\"\(countToken.inputKey)\":1}".utf8)))
        let body1 = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes1))
        XCTAssertFalse(body1.root.describe().contains("IndexedForEachSlot"),
            "count ≤ 1 → the guard hides the row strip (the count token drives it in WASM)")
    }

    /// END-TO-END ($0-SHORTHAND): the SAME real-app AccountSwitcher shape but with a
    /// `$0`-shorthand row (the common idiom) LOWERS → its guest module COMPILES to WASM →
    /// host-runs `view_body`, and the WASM-built tree carries the indexed-row slot (no free
    /// `$0` leaks into the guest — `$0` is bound natively in the thunk factory). Proving the
    /// `$0` form ships the SAME guest tree as the named form (the closure-invocation lives
    /// entirely in the build-time thunk, never the guest).
    func testDollarZeroIndexedForEachSlotExecutesInWasm() throws {
        let source = """
        import SwiftUI
        struct AccountSwitcher: View {
            @Environment(ScheduleService.self) private var schedule
            var body: some View {
                let owners = schedule.availableOwners
                if owners.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(owners, id: \\.id) {
                                AccountChip(id: $0.id, label: $0.label, subtitle: $0.subtitle,
                                            selected: schedule.selectedOwnerId == $0.id) {
                                    schedule.selectedOwnerId = $0.id
                                }
                            }
                        }.padding(.horizontal, 20)
                    }.scrollClipDisabled()
                }
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source, sameFileThunk: true).first)
        XCTAssertFalse(lowered.referencesUnresolvedSymbol,
            "no free guest identifier leaks (unresolved: \(lowered.unresolvedSymbols))")
        let slot = try XCTUnwrap(lowered.indexedRowSlots.first, "a $0 indexed-row slot was recorded")
        XCTAssertNotNil(slot.rowClosureText, "the $0 row stored its closure text for the invocation factory")

        let thunkSafe = lowered.opaqueLeaves.allSatisfy { $0.slotable } && !lowered.indexedRowSlots.isEmpty
        XCTAssertTrue(thunkSafe, "the $0 AccountSwitcher is routable via the indexed-row slot")

        let guestViews = [SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, stateModel: lowered.stateModel,
            thunkSafe: thunkSafe, usesGeometry: lowered.usesGeometry,
            inputTokens: lowered.hostTokens.filter { $0.ridesInputJSON })]
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping $0 indexed-slot execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-rowslot-dollar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.rowslot-dollar.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "$0 indexed-slot guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        let countToken = try XCTUnwrap(lowered.hostTokens.first { $0.kind == .number })
        let outBytes = try runner.callPacked("view_body", [UInt8](Data("{\"\(countToken.inputKey)\":3}".utf8)))
        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
        let desc = body.root.describe()
        XCTAssertTrue(desc.contains("ScrollView(axis:horizontal)"), "the scroll view emits: \(desc)")
        XCTAssertTrue(desc.contains("IndexedForEachSlot(#\(slot.id)"),
            "the WASM-built tree carries the indexed-row slot node: \(desc)")
        XCTAssertEqual(body.coverage?.opaqueNodes, 0, "no opaque node — the $0 ForEach became an indexed-row slot: \(desc)")
        let json = String(decoding: outBytes, as: UTF8.self)
        XCTAssertFalse(json.contains("$0"), "no free `$0` leaks into the guest tree: \(json)")
        XCTAssertTrue(json.contains(slot.countKey), "the countKey rides the node: \(slot.countKey)")
    }

    /// END-TO-END (sweep — scroll/layout): a body using the new scroll/layout
    /// modifiers LOWERS → COMPILES to WASM (proving the v5 guest IR copies are
    /// Embedded-Swift-clean) → host-runs `view_body`, and the WASM-built tree carries
    /// each scroll/layout modifier (they RIDE WASM, not native slots).
    func testSweepScrollLayoutBodyExecutesInWasm() throws {
        let source = """
        import SwiftUI
        struct ScrollScreen: View {
            var body: some View {
                ScrollView {
                    LazyVStack {
                        Text("a")
                        Text("b")
                    }
                    .scrollTargetLayout()
                }
                .scrollDisabled(false)
                .scrollIndicators(.hidden, axes: .vertical)
                .scrollTargetBehavior(.viewAligned)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .safeAreaPadding(.top, 12)
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source).first)
        let thunkSafe = lowered.opaqueLeaves.isEmpty && !lowered.referencesUnmarshalledInput
        let guestViews = [SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, stateModel: lowered.stateModel, thunkSafe: thunkSafe)]
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping scroll/layout execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-scrolllayout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.scrolllayout.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "scroll/layout guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        let outBytes = try runner.callPacked("view_body", [UInt8](Data("{}".utf8)))
        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
        XCTAssertEqual(body.coverage?.opaqueNodes, 0, "scroll/layout body lowers fully (no opaque)")
        // The emitted JSON carries each scroll/layout modifier (it rode WASM).
        let json = String(decoding: outBytes, as: UTF8.self)
        for key in ["scrollDisabled", "scrollIndicators", "scrollTargetBehavior",
                    "scrollTargetLayout", "scrollBounceBehavior", "contentMargins",
                    "safeAreaPadding"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "\(key) rides the WASM-built tree: \(json)")
        }
    }

    /// END-TO-END (sweep v6 — visibility/chrome/effects): a body using the new v6
    /// modifiers LOWERS → COMPILES to WASM (proving the v6 guest IR copies are
    /// Embedded-Swift-clean — these add new `Modifier` cases the guest's `JSONEmit`
    /// must serialize) → host-runs `view_body`, and the WASM-built tree carries each
    /// modifier (they RIDE WASM, not native slots).
    func testSweepVisibilityChromeBodyExecutesInWasm() throws {
        let source = """
        import SwiftUI
        struct ChromeScreen: View {
            var body: some View {
                VStack {
                    Text("a")
                        .hidden()
                        .menuIndicator(.hidden)
                        .menuOrder(.fixed)
                        .contentTransition(.numericText)
                        .textSelection(.enabled)
                        .allowsTightening(true)
                        .lineLimit(2, reservesSpace: true)
                    Text("b")
                        .compositingGroup()
                        .geometryGroup()
                        .drawingGroup()
                        .luminanceToAlpha()
                        .colorMultiply(.red)
                        .containerShape(.capsule)
                        .listItemTint(.blue)
                        .invalidatableContent(true)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source).first)
        let thunkSafe = lowered.opaqueLeaves.isEmpty && !lowered.referencesUnmarshalledInput
        let guestViews = [SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, stateModel: lowered.stateModel, thunkSafe: thunkSafe)]
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping v6 chrome execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-v6chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.v6chrome.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "v6 chrome guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        let outBytes = try runner.callPacked("view_body", [UInt8](Data("{}".utf8)))
        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
        XCTAssertEqual(body.coverage?.opaqueNodes, 0, "v6 chrome body lowers fully (no opaque)")
        // The schema version stamped on the emission is the new v6 (matches the SDK's
        // `PatchViewIRSchema.version`, kept in sync by hand — see Schema.swift).
        XCTAssertGreaterThanOrEqual(SwiftUIGuestEmitter.manifestSchemaVersion, 6,
                                    "v6 modifier cases require schema >= 6")
        // The emitted JSON carries each v6 modifier (it rode WASM).
        let json = String(decoding: outBytes, as: UTF8.self)
        for key in ["hidden", "menuIndicator", "menuOrder", "contentTransition",
                    "textSelection", "allowsTightening", "lineLimitReservesSpace",
                    "compositingGroup", "geometryGroup", "drawingGroup", "luminanceToAlpha",
                    "colorMultiply", "containerShape", "listItemTint", "invalidatableContent",
                    "defaultScrollAnchor"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "\(key) rides the WASM-built tree: \(json)")
        }
    }

    /// END-TO-END (sweep v7): the accessibility / help / text-input / presentation-config
    /// modifier batch LOWERS → COMPILES to WASM (proving the guest IR copies carry the new
    /// `Modifier` cases Embedded-Swift-clean) → host-runs `view_body` with each v7 modifier
    /// riding the WASM-built tree (0 opaque). Mirrors `testSweepVisibilityChromeBodyExecutesInWasm`.
    func testSweepV7AccessibilityPresentationBodyExecutesInWasm() throws {
        let source = """
        import SwiftUI
        struct V7Screen: View {
            var body: some View {
                VStack {
                    Text("a")
                        .help("Tooltip")
                        .accessibilityIdentifier("row-1")
                        .accessibilitySortPriority(2)
                        .accessibilityRespondsToUserInteraction(true)
                        .privacySensitive(true)
                        .speechAlwaysIncludesPunctuation(true)
                        .fontWidth(.condensed)
                        .textScale(.secondary)
                    Text("b")
                        .findDisabled(true)
                        .statusBarHidden(true)
                        .contentShape(.capsule)
                        .coordinateSpace(.named("grid"))
                        .symbolEffectsRemoved(true)
                }
                .scrollDismissesKeyboard(.interactively)
                .interactiveDismissDisabled(true)
                .presentationCornerRadius(16)
                .presentationContentInteraction(.scrolls)
                .presentationCompactAdaptation(.popover)
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source).first)
        let thunkSafe = lowered.opaqueLeaves.isEmpty && !lowered.referencesUnmarshalledInput
        let guestViews = [SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, stateModel: lowered.stateModel, thunkSafe: thunkSafe)]
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping v7 execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-v7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.v7.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "v7 guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        let outBytes = try runner.callPacked("view_body", [UInt8](Data("{}".utf8)))
        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
        XCTAssertEqual(body.coverage?.opaqueNodes, 0, "v7 body lowers fully (no opaque)")
        XCTAssertGreaterThanOrEqual(SwiftUIGuestEmitter.manifestSchemaVersion, 7,
                                    "v7 modifier cases require schema >= 7")
        let json = String(decoding: outBytes, as: UTF8.self)
        for key in ["help", "accessibilityIdentifier", "accessibilitySortPriority",
                    "accessibilityRespondsToUserInteraction", "privacySensitive",
                    "speechAlwaysIncludesPunctuation", "fontWidth", "textScale",
                    "findDisabled", "statusBarHidden", "contentShape", "coordinateSpaceNamed",
                    "symbolEffectsRemoved", "scrollDismissesKeyboard", "interactiveDismissDisabled",
                    "presentationCornerRadius", "presentationContentInteraction",
                    "presentationCompactAdaptation"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "\(key) rides the WASM-built tree: \(json)")
        }
    }

    /// DEMOTE-SAFE (Lever 2): a `Text` with a SwiftUI-ONLY interpolation overload
    /// (`Text("\\(v, specifier:)")` / `format:` / `style:`) — which the plain-`String`
    /// guest interpolation can't express — does NOT emit a guest-uncompilable verbatim
    /// body; it SLOTS the whole Text (an opaque leaf) so the rest of the view ships and
    /// the native `Text` renders the formatted output faithfully. Previously this slipped
    /// the name-only static guard and failed the embedded WASM compile (the 22× class).
    func testSwiftUIInterpolationOverloadSlotsNotVerbatim() throws {
        let source = """
        import SwiftUI
        struct FmtRow: View {
            let value: Double
            var body: some View {
                VStack {
                    Text("\\(value, specifier: "%.1f")")
                    Text("plain \\(value)")
                }
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source).first)
        // The formatted Text slotted (an opaque leaf), the plain interpolation rode WASM.
        XCTAssertFalse(lowered.opaqueLeaves.isEmpty,
                       "a SwiftUI-only interpolation overload must SLOT, not emit verbatim")
        // The guest body must NOT carry the un-compilable `specifier:` interpolation verbatim.
        XCTAssertFalse(lowered.guestBody.contains("specifier:"),
                       "the specifier overload must not ride the guest body verbatim:\n\(lowered.guestBody)")
        // The plain interpolation still lowered as a real text node.
        XCTAssertTrue(lowered.guestBody.contains("N.text"),
                      "the plain interpolation still lowers as a text node")
    }

    /// END-TO-END (C — GeometryReader): a `GeometryReader { proxy in … }` body LOWERS
    /// → COMPILES to WASM (proving the guest IR copies + the reserved `__geo_*`
    /// bindings are Embedded-Swift-clean) → host-runs `view_body` with the proxy's
    /// size/frame injected as `__geo_*` inputs, and the WASM-built tree reflects those
    /// LIVE geometry values (the dominant `proxy.size.width`→`.frame` idiom + arithmetic
    /// + `Text` interpolation reading `minX`/`minY`).
    func testGeometryReaderBodyExecutesInWasm() throws {
        let source = """
        import SwiftUI
        struct GeoScreen: View {
            var body: some View {
                GeometryReader { proxy in
                    VStack {
                        Text("origin \\(Int(proxy.frame(in: .local).minX)),\\(Int(proxy.frame(in: .local).minY))")
                        Color.blue
                            .frame(width: proxy.size.width, height: proxy.size.height / 2)
                    }
                }
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source).first)
        XCTAssertTrue(lowered.usesGeometry, "the GeometryReader body must flag geometry use")
        let guestViews = [SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, usesGeometry: lowered.usesGeometry)]
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping GeometryReader execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-geo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.geo.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "GeometryReader guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)

        // Inject the live proxy size/frame the SDK host wrapper would supply.
        let geoInputs = Data(#"{"__geo_width":320,"__geo_height":200,"__geo_minX":10,"__geo_minY":20}"#.utf8)
        let outBytes = try runner.callPacked("view_body", [UInt8](geoInputs))
        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
        let desc = body.root.describe()
        // The tree is a real geometryReader wrapping the lowered child.
        XCTAssertTrue(desc.contains("GeometryReader("), "root is a GeometryReader: \(desc)")
        // The frame width reflects the injected __geo_width (320); height is __geo_height/2 (100).
        XCTAssertTrue(desc.contains("w:320"), "frame width = injected __geo_width: \(desc)")
        XCTAssertTrue(desc.contains("h:100"), "frame height = __geo_height/2 computed in WASM: \(desc)")
        // The Text interpolation reflects the injected minX/minY (10, 20).
        XCTAssertTrue(desc.contains("origin 10,20"), "Text reads __geo_minX/minY: \(desc)")
        // No node fell back to native (the whole reader rides WASM).
        XCTAssertEqual(body.coverage?.opaqueNodes, 0, "GeometryReader body lowers fully: \(desc)")
    }

    /// END-TO-END: a literal `Path { … }` lowers → compiles to WASM → `view_body`
    /// runs → the emitted tree is a real `path` node with the replayed commands, no
    /// native fallback (the whole shape rides WASM).
    func testPathBodyExecutesInWasm() throws {
        let source = """
        import SwiftUI
        struct Triangle: View {
            var body: some View {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: 100, y: 0))
                    p.addLine(to: CGPoint(x: 50, y: 80))
                    p.closeSubpath()
                }
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source).first)
        let guestViews = [SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, usesGeometry: lowered.usesGeometry)]
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping Path execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.path.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "Path guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        let outBytes = try runner.callPacked("view_body", [UInt8]("{}".utf8))
        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
        // The emitted node round-trips as a real path with the 3 line/move + close.
        if case .path(let cmds) = body.root.kind {
            XCTAssertEqual(cmds.count, 4, "move + 2 lines + close: \(cmds)")
            XCTAssertEqual(cmds.first, .move(x: 0, y: 0))
            XCTAssertEqual(cmds.last, .closeSubpath)
        } else {
            XCTFail("root is not a path node: \(body.root.describe())")
        }
        XCTAssertEqual(body.coverage?.opaqueNodes, 0, "the Path lowers fully (no native slot)")
    }

    /// END-TO-END: the new control-style modifiers compile to WASM + round-trip on
    /// the emitted tree (a TextField carrying `.textFieldStyle("roundedBorder")`).
    func testAdditionalStyleModifierExecutesInWasm() throws {
        let source = """
        import SwiftUI
        struct Form1: View {
            var q: String = ""
            var body: some View {
                TextField("Search", text: $q)
                    .textFieldStyle(.roundedBorder)
            }
        }
        """
        let lowering = BodyLowering()
        let lowered = try XCTUnwrap(lowering.lowerAllViews(source: source).first)
        let guestViews = [SwiftUIGuestEmitter.GuestView(
            viewName: lowered.viewName, guestBody: lowered.guestBody,
            inputs: lowered.inputs, usesGeometry: lowered.usesGeometry)]
        let emission = try SwiftUIGuestEmitter().emit(views: guestViews)

        let compiler = SwiftWasmCompiler(exportedSymbols: emission.exports)
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping style-modifier execution")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-style-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sources: [URL] = []
        for f in emission.files {
            let u = tmp.appendingPathComponent(f.fileName)
            try f.contents.write(to: u, atomically: true, encoding: .utf8)
            sources.append(u)
        }
        let out = tmp.appendingPathComponent("module.style.wasm")
        let result = try compiler.compile(sources: sources, outputModule: out)
        XCTAssertEqual(result.status, .success, "style-modifier guest WASM compile failed:\n\(result.log)")

        let wasm = [UInt8](try Data(contentsOf: out))
        let runner = try Runner(wasm: wasm)
        let outBytes = try runner.callPacked("view_body", [UInt8]("{}".utf8))
        let body = try JSONDecoder().decode(BodyEmission.self, from: Data(outBytes))
        // The textFieldStyle modifier rides as a String modifier on the TextField.
        let hasStyle = body.root.modifiers.contains {
            if case .textFieldStyle(let s) = $0 { return s == "roundedBorder" }; return false
        }
        XCTAssertTrue(hasStyle, "the textFieldStyle modifier round-trips: \(body.root.describe())")
    }

    // MARK: - Minimal WasmKit host runner (mirrors PatchSDK.callPacked)

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
            guard let m = instance.exports[memory: "memory"] else {
                throw NSError(domain: "abi", code: 1)
            }
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

    // MARK: - Non-ASCII text lowering (multi-byte UTF-8 robustness — Masahiro's report)

    /// A PLAIN non-ASCII `Text("録画品質")` must lower to the toolchain-robust byte form
    /// (`String(decoding:[..],as:UTF8.self)`), NOT a raw non-ASCII string literal that a
    /// guest toolchain could small-string-miscompile and silently drop to native.
    func testNonASCIITextLowersToByteDecodeForm() {
        let src = """
        import SwiftUI
        struct V: View {
            var body: some View {
                VStack {
                    Text("録画品質")
                    Text("Bitrate")
                }
            }
        }
        """
        let views = BodyLowering().lowerAllViews(source: src, sameFileThunk: true)
        let v = views.first { $0.viewName == "V" }
        XCTAssertNotNil(v, "V lowered")
        let body = v?.guestBody ?? ""
        // The Japanese literal rides WASM as UTF-8 bytes (233 = 0xE9, the first byte of 録)…
        XCTAssertTrue(body.contains("String(decoding: [233,"),
            "non-ASCII Text must lower to the byte-decode form; got:\n\(body)")
        // …and the raw multi-byte literal must NOT be baked as a guest string literal.
        XCTAssertFalse(body.contains("\"録画品質\""),
            "the raw non-ASCII literal must be replaced, not baked verbatim; got:\n\(body)")
        // The ASCII sibling stays a plain literal (byte-identical fast path).
        XCTAssertTrue(body.contains("\"Bitrate\""),
            "ASCII literals stay verbatim; got:\n\(body)")
    }

    /// An ASCII-only body must be BYTE-IDENTICAL with vs without the encoder — the fast
    /// path (no non-ASCII byte) returns the emitted body verbatim, so every existing app
    /// keeps its exact `guestBody` (and thus its content hash / native-shell fingerprint).
    func testASCIIBodyIsByteIdenticalUnderEncoder() {
        let ascii = "N.vstack(spacing: 8.0) { [ N.text(\"Hello\"), N.text(\"World\") ] }"
        XCTAssertEqual(GuestNonASCIIEncoder.encode(ascii), ascii,
            "an ASCII-only body must be returned verbatim (fast path)")
        XCTAssertFalse(GuestNonASCIIEncoder.containsNonASCII(ascii))
    }

    /// The encoder decodes ESCAPES + leaves an INTERPOLATION alone (its dynamic part already
    /// forces a non-small string; rewriting its static segments is out of scope).
    func testEncoderDecodesEscapesAndSkipsInterpolation() {
        // A plain literal with an escape + non-ASCII → byte form of the DECODED value (tab, not `\t`).
        let escaped = "N.text(\"A\\t録\")"
        let out = GuestNonASCIIEncoder.encode(escaped)
        XCTAssertTrue(out.contains("String(decoding: [65, 9,"),
            "escapes decode before byte-encoding (A=65, tab=9); got:\n\(out)")
        // An interpolation (`"…\(x)…"`) is NOT a plain literal → left verbatim.
        let interp = "N.text(\"録\\(x)\")"
        XCTAssertEqual(GuestNonASCIIEncoder.encode(interp), interp,
            "an interpolation is left as-is; got:\n\(GuestNonASCIIEncoder.encode(interp))")
    }
}
