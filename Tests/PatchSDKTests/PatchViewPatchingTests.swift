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

    func testNonScalarTypesNowMarshal() {
        struct Holder: View {
            let arr: [Int] = [1, 2]
            let n: Int = 3
            var body: some View { EmptyView() }
        }
        let e = PatchInstanceInputs.extract(from: Holder())
        // Both marshal now: the scalar `n` AND the array `arr` (recursive encoder).
        XCTAssertEqual(e.json, #"{"arr":[1,2],"n":3}"#)
    }

    // MARK: - Recursive value encoder (struct / array / enum / Date / Optional)

    func testEncodeArrayOfScalars() {
        XCTAssertEqual(PatchValueEncoder.encode([1, 2, 3]), "[1,2,3]")
        XCTAssertEqual(PatchValueEncoder.encode(["a", "b"]), #"["a","b"]"#)
        XCTAssertEqual(PatchValueEncoder.encode([true, false]), "[true,false]")
        XCTAssertEqual(PatchValueEncoder.encode([1.5, 2.0]), "[1.5,2]")
        XCTAssertEqual(PatchValueEncoder.encode([Int]()), "[]")
    }

    func testEncodeStruct() {
        struct Point: Equatable, Codable { var x: Int; var y: Int }
        // Keys sorted for stability.
        XCTAssertEqual(PatchValueEncoder.encode(Point(x: 3, y: 4)), #"{"x":3,"y":4}"#)
    }

    func testEncodeNestedStructAndArray() {
        struct Item: Codable { var name: String; var qty: Int }
        struct Cart: Codable { var items: [Item]; var total: Double }
        let cart = Cart(items: [Item(name: "Pen", qty: 2)], total: 4.0)
        XCTAssertEqual(
            PatchValueEncoder.encode(cart),
            #"{"items":[{"name":"Pen","qty":2}],"total":4}"#)
    }

    func testEncodeOptional() {
        let some: Int? = 5
        let none: Int? = nil
        XCTAssertEqual(PatchValueEncoder.encode(some as Any), "5")
        XCTAssertEqual(PatchValueEncoder.encode(none as Any), "null")
        let someStr: String? = "hi"
        XCTAssertEqual(PatchValueEncoder.encode(someStr as Any), #""hi""#)
    }

    func testEncodeEnumNoPayload() {
        enum Status { case active, paused }
        // A no-payload case encodes as {"case":"active"}.
        XCTAssertEqual(PatchValueEncoder.encode(Status.active), #"{"case":"active"}"#)
        XCTAssertEqual(PatchValueEncoder.encode(Status.paused), #"{"case":"paused"}"#)
    }

    func testEncodeEnumWithPayload() {
        enum Shape { case circle(Double); case rect(w: Int, h: Int) }
        XCTAssertEqual(PatchValueEncoder.encode(Shape.circle(2.0)),
                       #"{"case":"circle","_0":2}"#)
        // Labelled associated values use their labels, in DECLARATION order
        // (positional — unlike struct fields, enum payloads aren't reordered).
        XCTAssertEqual(PatchValueEncoder.encode(Shape.rect(w: 3, h: 4)),
                       #"{"case":"rect","w":3,"h":4}"#)
    }

    func testEncodeDictionaryStringKeys() {
        let d = ["b": 2, "a": 1]
        // String-keyed dictionary → JSON object, keys sorted.
        XCTAssertEqual(PatchValueEncoder.encode(d), #"{"a":1,"b":2}"#)
    }

    func testEncodeDate() {
        let date = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(PatchValueEncoder.encode(date), "1000")
    }

    func testEncodeUUIDAndURL() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        XCTAssertEqual(PatchValueEncoder.encode(uuid),
                       #""00000000-0000-0000-0000-000000000001""#)
        let url = URL(string: "https://example.com/x")!
        XCTAssertEqual(PatchValueEncoder.encode(url), #""https://example.com/x""#)
    }

    func testEncodeStructWithEnumAndOptionalFields() {
        enum Role: String, Codable { case admin, user }
        struct Account: Codable { var name: String; var role: Role; var nickname: String? }
        // A `String`-RawRepresentable enum still mirrors as an enum (no payload) →
        // {"case":"admin"}; the optional nil → null.
        let acct = Account(name: "Ada", role: .admin, nickname: nil)
        XCTAssertEqual(
            PatchValueEncoder.encode(acct),
            #"{"name":"Ada","nickname":null,"role":{"case":"admin"}}"#)
    }

    func testEncodeMarshalsStateAndBindingValues() {
        struct M: View {
            @State var tags: [String] = ["x", "y"]
            var body: some View { EmptyView() }
        }
        let e = PatchInstanceInputs.extract(from: M())
        XCTAssertEqual(e.json, #"{"tags":["x","y"]}"#)
        // Wrapper-backed → still write-back-registered.
        XCTAssertEqual(Set(e.writebacks.map(\.key)), ["tags"])
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

    // MARK: - Non-scalar write-back round trip (JSON → concrete Decodable type)

    private struct Filters: Equatable, Codable { var tags: [String]; var max: Int }

    private struct StructBinding: View {
        @Binding var filters: Filters
        var body: some View { EmptyView() }
    }

    func testApplyWritebacksReconstructsCodableStruct() {
        let box = Box(Filters(tags: ["a"], max: 1))
        let sample = StructBinding(
            filters: Binding(get: { box.v }, set: { box.v = $0 }))
        let e = PatchInstanceInputs.extract(from: sample)
        // The struct marshalled IN as a nested object.
        XCTAssertEqual(e.json, #"{"filters":{"max":1,"tags":["a"]}}"#)
        // A new guest state changes the struct; it reconstructs the concrete type.
        PatchedBodyHost.applyWritebacks(
            e.writebacks, newStateJSON: #"{"filters":{"max":9,"tags":["a","b"]}}"#)
        XCTAssertEqual(box.v, Filters(tags: ["a", "b"], max: 9),
                       "Codable struct was not reconstructed on write-back")
    }

    func testApplyWritebacksReconstructsArray() {
        let box = Box([1, 2])
        struct ArrBinding: View {
            @Binding var nums: [Int]
            var body: some View { EmptyView() }
        }
        let sample = ArrBinding(nums: Binding(get: { box.v }, set: { box.v = $0 }))
        let e = PatchInstanceInputs.extract(from: sample)
        XCTAssertEqual(e.json, #"{"nums":[1,2]}"#)
        PatchedBodyHost.applyWritebacks(e.writebacks, newStateJSON: #"{"nums":[3,4,5]}"#)
        XCTAssertEqual(box.v, [3, 4, 5])
    }

    func testWriteJSONNoOpForNonDecodable() {
        // A non-Decodable Value can't be reconstructed — the write-back must be a
        // safe no-op (never a wrong/garbage write).
        struct NotCodable: Equatable { var x: Int }
        let box = Box(NotCodable(x: 1))
        struct B: View {
            @Binding var v: NotCodable
            var body: some View { EmptyView() }
        }
        let sample = B(v: Binding(get: { box.v }, set: { box.v = $0 }))
        let e = PatchInstanceInputs.extract(from: sample)
        // It still marshals OUT (Mirror), but can't come back.
        XCTAssertEqual(e.json, #"{"v":{"x":1}}"#)
        PatchedBodyHost.applyWritebacks(e.writebacks, newStateJSON: #"{"v":{"x":99}}"#)
        XCTAssertEqual(box.v, NotCodable(x: 1), "non-Decodable must not be overwritten")
    }

    // MARK: - Merge preserves nested (non-scalar) values

    func testMergePreservesNestedObjectsAndArrays() {
        // A non-scalar prop in the base must survive a merge that only overrides a
        // scalar — the old scalar-only serializer dropped it.
        let merged = PatchFlatJSON.merge(
            base: #"{"items":[{"q":2}],"name":"Ada","count":0}"#,
            override: #"{"count":5}"#)
        XCTAssertEqual(merged, #"{"count":5,"items":[{"q":2}],"name":"Ada"}"#)
    }

    func testMergeNestedOverrideWins() {
        let merged = PatchFlatJSON.merge(
            base: #"{"f":{"max":1,"tags":["a"]}}"#,
            override: #"{"f":{"max":9,"tags":["a","b"]}}"#)
        XCTAssertEqual(merged, #"{"f":{"max":9,"tags":["a","b"]}}"#)
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
            ViewNode(.button(actionID: "act1", role: nil, label: [ViewNode(.text("A"))])),
            ViewNode(.hstack(alignment: nil, spacing: nil, children: [
                ViewNode(.button(actionID: "act2", role: nil, label: [ViewNode(.text("B"))]))
            ]))
        ]))
        XCTAssertEqual(Set(PatchedBodyHost.collectButtonActionIDs(tree)), ["act1", "act2"])
    }
}
#endif
