import XCTest
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI
#endif

/// Unit tests for the OUT-OF-THE-BOX view-patching runtime (PatchSwiftUI/
/// ViewPatching.swift): the instance→inputs marshalling, the props∪state merge,
/// scalar write-backs, manifest decode + schema gating, and button-action
/// collection. These lock the flat-JSON input format the ENGINE's lowered guest
/// body must scan — keep in sync with cli SwiftUIGuestEmitter `_patchScan*`.
#if canImport(SwiftUI)
@MainActor
final class PatchViewPatchingTests: XCTestCase {

    // MARK: - Sample views

    private struct Sample: View {
        let title: String
        var subtitle: String = "sub"
        @State var count: Int = 7
        @State var on: Bool = true
        var ratio: Double = 1.5
        var body: some View { Text(title) }
    }

    private struct NoState: View {
        let name: String
        var body: some View { Text(name) }
    }

    // MARK: - Instance marshalling

    func testExtractMarshalsScalarsAndSortsKeys() {
        let e = PatchInstanceInputs.extract(from: Sample(title: "Hi"))
        // Keys are sorted: count, on, ratio, subtitle, title.
        XCTAssertEqual(
            e.json,
            #"{"count":7,"on":true,"ratio":1.5,"subtitle":"sub","title":"Hi"}"#,
            "flat inputs JSON mismatch: \(e.json)")
    }

    func testExtractWriteBacksOnlyForWrappers() {
        let e = PatchInstanceInputs.extract(from: Sample(title: "Hi"))
        // @State count + @State on are write-back-able; plain props are not.
        XCTAssertEqual(Set(e.writebacks.map(\.key)), ["count", "on"])
    }

    func testExtractNoStateView() {
        let e = PatchInstanceInputs.extract(from: NoState(name: "x"))
        XCTAssertEqual(e.json, #"{"name":"x"}"#)
        XCTAssertTrue(e.writebacks.isEmpty)
    }

    func testIntegralDoublePrintsAsInteger() {
        // The guest's Foundation-free Int scan rejects a trailing ".0"; an
        // integral Double must serialize as a bare integer.
        XCTAssertEqual(PatchInstanceInputs.scalarJSONFragment(2.0), "2")
        XCTAssertEqual(PatchInstanceInputs.scalarJSONFragment(2.5), "2.5")
        XCTAssertEqual(PatchInstanceInputs.scalarJSONFragment(true), "true")
        XCTAssertEqual(PatchInstanceInputs.scalarJSONFragment(false), "false")
        XCTAssertEqual(PatchInstanceInputs.scalarJSONFragment(42), "42")
    }

    func testStringEscaping() {
        let frag = PatchInstanceInputs.scalarJSONFragment("a\"b\\c\nd")
        XCTAssertEqual(frag, #""a\"b\\c\nd""#)
    }

    func testUnsupportedTypesAreSkipped() {
        struct Holder: View {
            let arr: [Int] = [1, 2]
            let n: Int = 3
            var body: some View { EmptyView() }
        }
        let e = PatchInstanceInputs.extract(from: Holder())
        // Only the scalar `n` marshals; the array is dropped (guest defaults it).
        XCTAssertEqual(e.json, #"{"n":3}"#)
    }

    // MARK: - Flat-JSON merge

    func testMergeOverrideWins() {
        let merged = PatchFlatJSON.merge(
            base: #"{"a":1,"b":"x"}"#, override: #"{"b":"y"}"#)
        XCTAssertEqual(merged, #"{"a":1,"b":"y"}"#)
    }

    func testMergeEmptyCases() {
        XCTAssertEqual(PatchFlatJSON.merge(base: "", override: ""), "{}")
        XCTAssertEqual(PatchFlatJSON.merge(base: #"{"a":1}"#, override: ""), #"{"a":1}"#)
        XCTAssertEqual(PatchFlatJSON.merge(base: "", override: #"{"a":1}"#), #"{"a":1}"#)
    }

    func testMergePreservesNativePropsWhenStateOverrides() {
        // Native props re-marshalled fresh; guest state overrides only its fields.
        let merged = PatchFlatJSON.merge(
            base: #"{"name":"Ada","count":0}"#, override: #"{"count":5}"#)
        XCTAssertEqual(merged, #"{"count":5,"name":"Ada"}"#)
    }

    // MARK: - scalarEqual

    func testScalarEqualCrossType() {
        XCTAssertTrue(PatchFlatJSON.scalarEqual(5, 5.0))
        XCTAssertTrue(PatchFlatJSON.scalarEqual(true, true))
        XCTAssertFalse(PatchFlatJSON.scalarEqual(true, 1.0))   // bool ≠ number
        XCTAssertTrue(PatchFlatJSON.scalarEqual("z", "z"))
        XCTAssertFalse(PatchFlatJSON.scalarEqual("z", "y"))
        XCTAssertFalse(PatchFlatJSON.scalarEqual(nil as Any?, 1))
    }

    // MARK: - Write-back round trip
    //
    // NOTE: `@State` write-back can only be exercised on an INSTALLED view (an
    // un-installed `State` is "a constant Binding of the initial value" per
    // Apple), so the State path is validated in the on-simulator E2E. Here we
    // use a closure-backed `@Binding` (reference-semantic, works standalone) to
    // prove the write-back PLUMBING — extraction, key match, no-op suppression,
    // and write-through — which is identical for State once installed.

    private final class Box<T> { var v: T; init(_ v: T) { self.v = v } }

    private struct BindingSample: View {
        @Binding var count: Int
        @Binding var on: Bool
        var body: some View { Text("\(count)") }
    }

    func testApplyWritebacksWritesThroughBinding() {
        let countBox = Box(7), onBox = Box(true)
        let sample = BindingSample(
            count: Binding(get: { countBox.v }, set: { countBox.v = $0 }),
            on: Binding(get: { onBox.v }, set: { onBox.v = $0 }))
        let e = PatchInstanceInputs.extract(from: sample)
        XCTAssertEqual(Set(e.writebacks.map(\.key)), ["count", "on"])
        XCTAssertEqual(e.json, #"{"count":7,"on":true}"#)

        // New guest state flips `on` false and bumps `count` to 9.
        PatchedBodyHost.applyWritebacks(e.writebacks,
                                        newStateJSON: #"{"count":9,"on":false}"#)
        XCTAssertEqual(countBox.v, 9, "count not written back")
        XCTAssertEqual(onBox.v, false, "on not written back")
    }

    func testApplyWritebacksSuppressesNoOp() {
        var setCount = 0
        let countBox = Box(5)
        let sample = OneBinding(count: Binding(
            get: { countBox.v }, set: { countBox.v = $0; setCount += 1 }))
        let e = PatchInstanceInputs.extract(from: sample)
        // Same value → no write should fire (suppressed by scalarEqual).
        PatchedBodyHost.applyWritebacks(e.writebacks, newStateJSON: #"{"count":5}"#)
        XCTAssertEqual(setCount, 0, "no-op write was not suppressed")
        // Changed value → exactly one write.
        PatchedBodyHost.applyWritebacks(e.writebacks, newStateJSON: #"{"count":6}"#)
        XCTAssertEqual(setCount, 1)
        XCTAssertEqual(countBox.v, 6)
    }

    private struct OneBinding: View {
        @Binding var count: Int
        var body: some View { Text("\(count)") }
    }

    // MARK: - Manifest decode + schema gating

    func testManifestDecode() throws {
        let json = """
        {"schemaVersion":1,"views":[
          {"type":"SettingsScreen","export":"view_body__SettingsScreen","dispatch":"dispatch__SettingsScreen","thunkSafe":true},
          {"type":"Banner","export":"view_body__Banner","dispatch":null,"thunkSafe":false}
        ]}
        """
        let m = try JSONDecoder().decode(PatchViewManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.views.count, 2)
        XCTAssertEqual(m.views[0].type, "SettingsScreen")
        XCTAssertTrue(m.views[0].thunkSafe)
        XCTAssertEqual(m.views[0].dispatch, "dispatch__SettingsScreen")
        XCTAssertNil(m.views[1].dispatch)
        XCTAssertFalse(m.views[1].thunkSafe)
    }

    // MARK: - Button action collection

    func testCollectButtonActionIDs() {
        let tree = ViewNode(.vstack(alignment: nil, spacing: nil, children: [
            ViewNode(.button(actionID: "act1", label: [ViewNode(.text("A"))])),
            ViewNode(.hstack(alignment: nil, spacing: nil, children: [
                ViewNode(.button(actionID: "act2", label: [ViewNode(.text("B"))]))
            ]))
        ]))
        XCTAssertEqual(Set(PatchedBodyHost.collectButtonActionIDs(tree)), ["act1", "act2"])
    }
}
#endif
