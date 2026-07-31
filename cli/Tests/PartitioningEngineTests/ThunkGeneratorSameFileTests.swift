// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator
import PartitioningEngine

/// Tests SAME-FILE thunk generation — the default `patchcli prepare` mode.
///
/// Instead of one separate `PatchThunks.generated.swift`, each view's
/// `@_dynamicReplacement(for: body)` extension (+ `__patchSlots()`/`__patchTokens()`)
/// is appended to the view's OWN source file inside an idempotent BEGIN/END-marker
/// block. Living in the view's file is what makes the view's `private`/`fileprivate`
/// members reachable from the thunk — the architectural unblock for a view whose body
/// host-resolves a private member (e.g. AppA's SettingsScreen).
final class ThunkGeneratorSameFileTests: XCTestCase {
    private func run(_ files: [(name: String, text: String)]) -> ThunkGenerator.Result {
        let sources = files.map {
            ThunkGenerator.SourceFile(url: URL(fileURLWithPath: "/x/\($0.name)"), text: $0.text)
        }
        return ThunkGenerator().prepare(sources: sources, sameFile: true)
    }
    private func text(_ r: ThunkGenerator.Result, named name: String) -> String {
        r.modifiedFiles.first { $0.url.lastPathComponent == name }?.text ?? ""
    }

    // MARK: - Block placement + structure

    func testSameFileBlockIsAppendedToTheViewsOwnFile() {
        let r = run([("Hello.swift", """
        import SwiftUI
        struct Hello: View {
            var body: some View { Text("hi") }
        }
        """)])
        XCTAssertTrue(r.sameFile)
        XCTAssertEqual(r.viewNames, ["Hello"])
        XCTAssertTrue(r.thunkFileContents.isEmpty, "no separate thunk file in same-file mode")
        let t = text(r, named: "Hello.swift")
        // The original view + `dynamic` + the appended marked block, all in one file.
        XCTAssertTrue(t.contains("dynamic var body: some View"), t)
        XCTAssertTrue(t.contains(ThunkGenerator.sameFileBeginMarker), t)
        XCTAssertTrue(t.contains(ThunkGenerator.sameFileEndMarker), t)
        XCTAssertTrue(t.contains("extension Hello {"), t)
        XCTAssertTrue(t.contains("@_dynamicReplacement(for: body)"), t)
        XCTAssertTrue(t.contains(#"typeName: "Hello""#), t)
        // The struct decl must come BEFORE the generated block (we append, never prepend).
        XCTAssertLessThan(t.range(of: "struct Hello")!.lowerBound,
                          t.range(of: ThunkGenerator.sameFileBeginMarker)!.lowerBound)
        // The whole edited file still parses.
        XCTAssertTrue(ThunkGenerator.parses(t), t)
    }

    func testEachViewsThunkGoesInItsDeclaringFile() {
        let r = run([
            ("A.swift", "import SwiftUI\nstruct A: View { var body: some View { Text(\"a\") } }"),
            ("B.swift", "import SwiftUI\nstruct B: View { var body: some View { Text(\"b\") } }"),
        ])
        XCTAssertEqual(r.viewNames, ["A", "B"])
        let a = text(r, named: "A.swift"), b = text(r, named: "B.swift")
        XCTAssertTrue(a.contains("extension A {"), a)
        XCTAssertFalse(a.contains("extension B {"), "A's file must not carry B's thunk: \(a)")
        XCTAssertTrue(b.contains("extension B {"), b)
        XCTAssertFalse(b.contains("extension A {"), "B's file must not carry A's thunk: \(b)")
    }

    // MARK: - Idempotency (strip + re-append, never duplicate)

    func testRerunIsIdempotentAndDoesNotDuplicate() {
        let original = """
        import SwiftUI
        struct Hello: View {
            var body: some View { Text("hi") }
        }
        """
        let r1 = run([("Hello.swift", original)])
        let once = text(r1, named: "Hello.swift")
        // Feed the GENERATED output (dynamic + block) back through prepare.
        let r2 = run([("Hello.swift", once)])
        let twice = text(r2, named: "Hello.swift")
        // No `dynamic` to add the second time (it's already there); the block is regenerated.
        XCTAssertEqual(r2.dynamicInsertions, 0, "dynamic must not be inserted twice")
        // Exactly ONE begin + ONE end marker (no duplication).
        XCTAssertEqual(twice.components(separatedBy: ThunkGenerator.sameFileBeginMarker).count - 1, 1,
                       "exactly one generated block after re-run:\n\(twice)")
        XCTAssertEqual(twice.components(separatedBy: ThunkGenerator.sameFileEndMarker).count - 1, 1)
        // The thunk is now two extensions per view (body-replacement + helper methods),
        // so exactly TWO `extension Hello {` after a re-run (no duplication).
        XCTAssertEqual(twice.components(separatedBy: "extension Hello {").count - 1, 2,
                       "exactly two extensions (replacement + methods) after re-run:\n\(twice)")
        // Stable output: the second run reproduces the first byte-for-byte.
        XCTAssertEqual(once, twice, "same-file generation must be a fixed point")
        XCTAssertTrue(ThunkGenerator.parses(twice))
    }

    func testStripSameFileBlockRemovesBlockButKeepsDeveloperContent() {
        let original = """
        import SwiftUI
        struct Hello: View {
            var body: some View { Text("hi") }
        }
        """
        let r1 = run([("Hello.swift", original)])
        let withBlock = text(r1, named: "Hello.swift")
        let stripped = ThunkGenerator.stripSameFileBlock(from: withBlock)
        XCTAssertFalse(stripped.contains(ThunkGenerator.sameFileBeginMarker), stripped)
        XCTAssertFalse(stripped.contains("extension Hello {"), stripped)
        // The developer's struct + the inserted `dynamic` survive the strip.
        XCTAssertTrue(stripped.contains("struct Hello: View"), stripped)
        XCTAssertTrue(stripped.contains("dynamic var body"), stripped)
        XCTAssertTrue(ThunkGenerator.parses(stripped), stripped)
    }

    // MARK: - Private members ARE reachable in same-file mode

    /// The crux at the codegen level: a view whose mixed-view leaf reads a PRIVATE
    /// `@State` produces a slot closure referencing that private member — which is fine
    /// SAME-FILE (the extension shares the file). (In the separate-file path that very
    /// leaf is NOT slotted; see `ThunkGeneratorTests.testPrivateStateLeafIsNotSlotted`.)
    func testPrivateStateLeafIsSlottedInSameFileMode() {
        let r = run([("Screen.swift", """
        import SwiftUI
        struct Screen: View {
            @State private var on = true
            var body: some View {
                VStack {
                    Text("hi")
                    HStack { Toggle(isOn: $on) { Text("") } }.padding(.horizontal, 16)
                }
            }
        }
        """)])
        let t = text(r, named: "Screen.swift")
        // The slot closure for the Toggle node references `$on` — legal SAME-FILE.
        XCTAssertTrue(t.contains("$on"),
                      "same-file: a private-binding leaf IS slotted (the thunk sees $on):\n\(t)")
        XCTAssertTrue(t.contains("extension Screen {"), t)
        XCTAssertTrue(ThunkGenerator.parses(t), t)
    }

    func testThirdPartyImportCarriedIntoSameFileBlock() {
        let r = run([("A.swift", """
        import SwiftUI
        import Charts
        struct V: View { var body: some View { Text("x") } }
        """)])
        let t = text(r, named: "A.swift")
        XCTAssertTrue(t.contains("#if canImport(Charts)"), t)
    }

    // MARK: - PER-ROW INDEXED NATIVE-ACTION SLOTS (__patchRowSlots)

    /// The AccountSwitcher shape generates a `__patchRowSlots()` that natively evaluates
    /// the body-local collection (over `self`) and builds a per-row factory binding the
    /// loop var to `collection[i]` + carrying the per-row native action — and the whole
    /// edited file still parses.
    func testRowSlotsMethodGeneratedForBodyLocalForEach() {
        let r = run([("AccountSwitcher.swift", """
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
        """)])
        let t = text(r, named: "AccountSwitcher.swift")
        XCTAssertTrue(t.contains("func __patchRowSlots() -> [String: PatchRowSlot]"),
                      "the row-slots method is generated:\n\(t)")
        XCTAssertTrue(t.contains("let __coll = schedule.availableOwners"),
                      "the body-local alias resolved to its accessible collection source:\n\(t)")
        XCTAssertTrue(t.contains("PatchRowSlot(count: __coll.count)"), t)
        XCTAssertTrue(t.contains("let owner = __coll[__coll.index"), "the loop var binds to collection[i]:\n\(t)")
        XCTAssertTrue(t.contains("AccountChip(id: owner.id"), "the row's custom view + per-row action ride the factory:\n\(t)")
        XCTAssertTrue(t.contains("schedule.selectedOwnerId = owner.id"), "the per-row native action is in the factory:\n\(t)")
        // The thunk wires the rowSlots provider into thunkBody.
        XCTAssertTrue(t.contains("rowSlots: { self.__patchRowSlots() }"), t)
        // The whole edited file parses.
        XCTAssertTrue(ThunkGenerator.parses(t), t)
    }

    /// A view with NO indexed-row slot still gets a `__patchRowSlots()` returning `[:]`
    /// (uniform shape), and it parses.
    func testRowSlotsMethodEmptyForOrdinaryView() {
        let r = run([("Hello.swift", """
        import SwiftUI
        struct Hello: View { var body: some View { Text("hi") } }
        """)])
        let t = text(r, named: "Hello.swift")
        XCTAssertTrue(t.contains("func __patchRowSlots() -> [String: PatchRowSlot] {"), t)
        XCTAssertTrue(ThunkGenerator.parses(t), t)
    }
}
