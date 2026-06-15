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

    func testEncodeRawValueEnumUsesCaseNameNotRawValue() {
        // A RAW-VALUE enum input (the engine's `.enumValue` reconstruction) must marshal
        // by CASE NAME — the guest's mirroring enum decodes the `{"case":"<name>"}` shape
        // by name, NOT by raw value. (`String(describing:)` of a bare case is the case
        // name even when the raw value differs, e.g. an explicit `= "ACTIVE"`.)
        enum StringStatus: String { case active = "ACTIVE", archived = "ARCHIVED" }
        XCTAssertEqual(PatchValueEncoder.encode(StringStatus.active), #"{"case":"active"}"#)
        XCTAssertEqual(PatchValueEncoder.encode(StringStatus.archived), #"{"case":"archived"}"#)
        enum IntMedal: Int { case gold = 1, silver = 2, bronze = 3 }
        XCTAssertEqual(PatchValueEncoder.encode(IntMedal.gold), #"{"case":"gold"}"#)
        XCTAssertEqual(PatchValueEncoder.encode(IntMedal.bronze), #"{"case":"bronze"}"#)
    }

    func testExtractMarshalsSingleStructInputAsNestedObject() {
        // A SINGLE flat-struct stored property (the engine's `.flatStruct` input) marshals
        // as a NESTED JSON OBJECT under its key — exactly what the guest's single-object
        // scanner (`_patchScan<Type>Row`) reads.
        struct Product { let name: String; let price: Double; let inStock: Bool }
        struct Row { let item: Product }
        let e = PatchInstanceInputs.extract(from: Row(item: Product(name: "Widget", price: 9, inStock: true)))
        XCTAssertEqual(e.json, #"{"item":{"inStock":true,"name":"Widget","price":9}}"#)
    }

    func testExtractMarshalsEnumInputAsCaseObject() {
        // A single raw-value enum stored property marshals as `{"key":{"case":"<name>"}}`
        // — what the guest's enum case scanner reads.
        enum Status: String { case active, archived }
        struct Badge { let status: Status }
        let e = PatchInstanceInputs.extract(from: Badge(status: .archived))
        XCTAssertEqual(e.json, #"{"status":{"case":"archived"}}"#)
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

    func testEncodeDeeplyNestedStructFieldsLockGuestContract() {
        // The exact wire shape the engine's RICH-INPUT guest scanners decode: a struct
        // with a nested struct, a scalar-array field, a `[String:Int]` dict field, and a
        // nested struct-array. Locks the byte contract so the CLI guest stays in sync.
        struct Address: Codable { var city: String; var zip: String }
        struct LineItem: Codable { var label: String; var qty: Int }
        struct Profile: Codable {
            var name: String
            var address: Address
            var tags: [String]
            var scores: [String: Int]
            var items: [LineItem]
        }
        let p = Profile(name: "Ada", address: Address(city: "London", zip: "NW1"),
                        tags: ["a", "b"], scores: ["x": 1], items: [LineItem(label: "Pen", qty: 2)])
        // Keys are emitted in sorted order; the guest scans by key NAME so order is
        // irrelevant to decoding, but locking it keeps the contract test deterministic.
        XCTAssertEqual(
            PatchValueEncoder.encode(p),
            #"{"address":{"city":"London","zip":"NW1"},"items":[{"label":"Pen","qty":2}],"name":"Ada","scores":{"x":1},"tags":["a","b"]}"#)
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

    /// SOUNDNESS ANCHOR for the same-name view collision. The SDK routes a live view
    /// to its lowered body SOLELY by the unqualified type-name string the manifest is
    /// keyed on (`entries[typeName]`) — there is no module qualifier at this boundary.
    /// So if a manifest ever carried TWO entries of the same `type` (two `CardView`s),
    /// the registry's `out[entry.type] = entry` reduction COLLAPSES them: only one
    /// survives, and BOTH live `CardView` thunks (which both bake `typeName:"CardView"`)
    /// would route through whichever won. That mis-route is exactly why the ENGINE must
    /// exclude every claimant of a colliding name from emission (so the manifest never
    /// advertises a `CardView` at all). This test pins the SDK side of that invariant:
    /// same-typed entries are NOT distinguishable here.
    func testSameTypeManifestEntriesCollapseToOne() throws {
        let json = """
        {"schemaVersion":1,"views":[
          {"type":"CardView","export":"view_body__CardView","dispatch":null,"thunkSafe":true},
          {"type":"CardView","export":"view_body__CardView__alt","dispatch":null,"thunkSafe":true}
        ]}
        """
        let m = try JSONDecoder().decode(PatchViewManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.views.count, 2, "the wire format can DECODE two same-typed entries…")
        // …but the registry keys its lookup by `type`, so two same-typed entries can
        // address only ONE slot — there is no way to route two same-named live views.
        var byType: [String: PatchViewManifest.Entry] = [:]
        for entry in m.views { byType[entry.type] = entry }
        XCTAssertEqual(byType.count, 1,
                       "same-typed entries COLLAPSE — the SDK can't disambiguate, so the "
                       + "engine must never emit a colliding name")
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

    // MARK: - Input-riding host tokens (number + string, merged into the guest input JSON)

    /// `.number` host tokens are emitted into the guest input blob keyed by their
    /// reserved `__numtok_<id>` key (the guest reads them in WASM); `.color`/`.font`
    /// tokens are NOT (they ride the rendered tree instead).
    func testInputTokenJSONEmitsOnlyNumberTokens() throws {
        let tokens: [String: PatchHostToken] = [
            "nt_abc": .number(20),
            "nt_def": .number(13.5),
            "ct_xyz": .color(.red),     // must be excluded
            "ft_uvw": .font(.body),     // must be excluded
        ]
        let json = try XCTUnwrap(PatchedBodyHost.inputTokenJSON(from: tokens))
        // Parse it back so order-independence is guaranteed.
        let parsed = try XCTUnwrap(PatchFlatJSON.parse(json))
        XCTAssertEqual((parsed["__numtok_nt_abc"] as? NSNumber)?.doubleValue, 20)
        XCTAssertEqual((parsed["__numtok_nt_def"] as? NSNumber)?.doubleValue, 13.5)
        // No color/font token leaked into the input JSON.
        XCTAssertNil(parsed["__numtok_ct_xyz"])
        XCTAssertNil(parsed["__numtok_ft_uvw"])
        XCTAssertEqual(parsed.keys.count, 2, "only the two numeric tokens are injected")
    }

    /// `.string` host tokens are emitted into the guest input blob keyed by their
    /// reserved `__strtok_<id>` key, JSON-escaped, so the guest reads the real String
    /// (the ConfidencePill `confidence.label` mechanism). `.color`/`.font` are excluded.
    func testInputTokenJSONEmitsStringTokensEscaped() throws {
        let tokens: [String: PatchHostToken] = [
            "st_abc": .string("HIGH"),
            "st_def": .string("AI \"powered\"\nnext"),  // needs escaping
            "nt_n": .number(5),
            "ct_c": .color(.red),       // excluded
        ]
        let json = try XCTUnwrap(PatchedBodyHost.inputTokenJSON(from: tokens))
        let parsed = try XCTUnwrap(PatchFlatJSON.parse(json))
        XCTAssertEqual(parsed["__strtok_st_abc"] as? String, "HIGH")
        XCTAssertEqual(parsed["__strtok_st_def"] as? String, "AI \"powered\"\nnext",
                       "the string token must round-trip with quotes/newline escaped")
        XCTAssertEqual((parsed["__numtok_nt_n"] as? NSNumber)?.doubleValue, 5)
        XCTAssertNil(parsed["__strtok_ct_c"])
        XCTAssertEqual(parsed.keys.count, 3, "two string + one number, no color")
    }

    /// No input-riding tokens → nil (so the host skips the extra merge entirely).
    func testInputTokenJSONNilWhenNoInputTokens() {
        XCTAssertNil(PatchedBodyHost.inputTokenJSON(from: [:]))
        XCTAssertNil(PatchedBodyHost.inputTokenJSON(from: ["ct_x": .color(.blue)]))
    }
}
#endif
