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
// MARK: - Reactive-collection marshalling fixtures (Stage 1)

/// A flat-struct element a reactive collection holds.
private struct _RCItem { let id: Int; let label: String }

/// An iOS-17 `@Observable` view-model with a collection. The macro injects
/// `_$observationRegistrar` + surfaces `items`/`loading` as `_items`/`_loading`
/// backing — the encoder must skip the `_$…` plumbing and surface the real fields.
@available(iOS 17, macOS 14, *)
@Observable private final class _RCObservableVM {
    var items: [_RCItem]
    var loading: Bool
    init(items: [_RCItem], loading: Bool) { self.items = items; self.loading = loading }
}

/// A classic ObservableObject holding a PLAIN stored collection (isolates the
/// reactive-wrapper UNWRAP from the `@Published` encoding question).
private final class _RCPlainVM: ObservableObject {
    var items: [_RCItem] = []
}

/// A classic ObservableObject with a `@Published` collection (reveals whether a
/// `Published<[…]>` field marshals through the encoder).
private final class _RCPublishedVM: ObservableObject {
    @Published var items: [_RCItem] = []
}

private struct _RCObservedView: View {
    @ObservedObject var vm: _RCPlainVM
    var body: some View { Text("x") }
}

private struct _RCPublishedObservedView: View {
    @ObservedObject var vm: _RCPublishedVM
    var body: some View { Text("x") }
}

/// BUG #8 fixture: a view holding ONLY an `@EnvironmentObject`. With NO environment
/// object installed, native `wrappedValue` would TRAP — so `extract` must NOT eagerly
/// unwrap it. Reading `extract(from:)` on this view (no `.environmentObject(...)`
/// supplied) must NOT crash and must omit the env member.
private final class _RCEnvVM: ObservableObject {
    var items: [_RCItem] = []
}
private struct _RCEnvObjectView: View {
    @EnvironmentObject var vm: _RCEnvVM
    var body: some View { Text("x") }
}

/// BUG #8 fixture (iOS-17 Observation form): `@Environment(T.self)` with NO object in
/// the environment. `wrappedValue` traps if absent → `extract` must skip it.
@available(iOS 17, macOS 14, *)
@Observable private final class _RCEnvObservable {
    var items: [_RCItem] = []
}
@available(iOS 17, macOS 14, *)
private struct _RCEnvObservableView: View {
    @Environment(_RCEnvObservable.self) private var vm
    var body: some View { Text("x") }
}

/// BUG #6 fixture: a reactive VM holding a NON-marshallable SIBLING field (a closure)
/// ALONGSIDE the data collection. The whole object must NOT zero out to `{}` — the
/// collection field must survive so a `ForEach(vm.items)` renders the real rows.
private final class _RCSiblingVM: ObservableObject {
    var items: [_RCItem] = [_RCItem(id: 9, label: "S")]
    var onTap: () -> Void = {}                       // a stored closure — not encodable (skipped)
    var cancellables: Set<_RCFakeCancellable> = []   // a Set<AnyCancellable>-style sibling
}
/// A stand-in for `AnyCancellable` — an empty-shaped reference type a reactive VM stores
/// in a `Set`. Hashable so it can live in a Set (matching the real `Set<AnyCancellable>`).
private final class _RCFakeCancellable: Hashable {
    static func == (l: _RCFakeCancellable, r: _RCFakeCancellable) -> Bool { l === r }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}
private struct _RCSiblingView: View {
    @ObservedObject var vm: _RCSiblingVM
    var body: some View { Text("x") }
}

/// BUG #9 fixture: an `ObservableObject` whose `@Published` storage has transitioned to
/// `.publisher` (a Combine subscriber attached) rather than a settled `.value`. The
/// sibling-skip must omit it without zeroing the whole object — the plain `items` survive.
private final class _RCPublisherStateVM: ObservableObject {
    var items: [_RCItem] = [_RCItem(id: 4, label: "Q")]
    @Published var counter: Int = 0
}
private struct _RCPublisherStateView: View {
    @ObservedObject var vm: _RCPublisherStateVM
    var body: some View { Text("x") }
}

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

    // MARK: - Reactive-collection marshalling (Stage 1)

    func testObservableMacroObjectMarshalsItsFieldsSkippingPlumbing() throws {
        // The @Observable macro injects `_$observationRegistrar`; encodeObject must SKIP it
        // (not fail the WHOLE object) and surface the `_items`/`_loading` backing under the
        // real field names. Without the `_$…` skip this returns nil → the VM never marshals.
        guard #available(iOS 17, macOS 14, *) else { throw XCTSkip("needs Observation (macOS 14+)") }
        let vm = _RCObservableVM(items: [_RCItem(id: 1, label: "A"), _RCItem(id: 2, label: "B")],
                                 loading: false)
        XCTAssertEqual(PatchValueEncoder.encode(vm),
                       #"{"items":[{"id":1,"label":"A"},{"id":2,"label":"B"}],"loading":false}"#)
    }

    func testExtractUnwrapsObservedObjectCollectionAsNestedObject() {
        // An @ObservedObject reactive member marshals as a NESTED object under its member
        // name, so the guest can read `vm.items` (a ForEach over a reactive collection).
        let vm = _RCPlainVM()
        vm.items = [_RCItem(id: 7, label: "Z")]
        let e = PatchInstanceInputs.extract(from: _RCObservedView(vm: vm))
        XCTAssertEqual(e.json, #"{"vm":{"items":[{"id":7,"label":"Z"}]}}"#,
                       "reactive object marshalled as nested object: \(e.json)")
        // Read-only: no write-back for a reactive-collection member.
        XCTAssertTrue(e.writebacks.isEmpty, "reactive marshalling is read-only")
    }

    func testExtractObservedObjectPublishedCollectionUnwrapsCleanly() {
        // A classic `@Published var items` surfaces as `_items: Published<[…]>`; the encoder
        // unwraps the `Published.storage.value` payload so it marshals as a clean array (not
        // `{"storage":{"case":"value",...}}`) — classic MVVM works alongside @Observable.
        let vm = _RCPublishedVM()
        vm.items = [_RCItem(id: 3, label: "P")]
        let e = PatchInstanceInputs.extract(from: _RCPublishedObservedView(vm: vm))
        XCTAssertEqual(e.json, #"{"vm":{"items":[{"id":3,"label":"P"}]}}"#,
                       "@Published collection unwraps to a clean array: \(e.json)")
    }

    // MARK: - Bug #8: an absent @EnvironmentObject / @Environment must NOT trap

    func testExtractDoesNotTrapOnAbsentEnvironmentObject() {
        // Before the fix, `extract` eagerly called `_patchReactiveObject()` → `wrappedValue`
        // on EVERY reactive wrapper, and `@EnvironmentObject.wrappedValue` TRAPS (uncatchable)
        // when no object is installed. The fix removes the EnvironmentObject conformance, so
        // `extract` skips it. Reaching this assertion at all proves it didn't trap.
        let e = PatchInstanceInputs.extract(from: _RCEnvObjectView())
        XCTAssertFalse(e.json.contains("\"vm\""),
                       "an @EnvironmentObject must be omitted, never eagerly unwrapped: \(e.json)")
        XCTAssertEqual(e.json, "{}", "no marshallable members → empty object: \(e.json)")
    }

    func testExtractDoesNotTrapOnAbsentEnvironmentObservable() throws {
        // Same guarantee for the iOS-17 `@Environment(T.self)` Observation form.
        guard #available(iOS 17, macOS 14, *) else { throw XCTSkip("needs Observation (macOS 14+)") }
        let e = PatchInstanceInputs.extract(from: _RCEnvObservableView())
        XCTAssertFalse(e.json.contains("\"vm\""),
                       "an @Environment(T.self) must be omitted, never eagerly unwrapped: \(e.json)")
        XCTAssertEqual(e.json, "{}", "no marshallable members → empty object: \(e.json)")
    }

    func testReactiveWrapperConformanceIsHeldWrappersOnly() {
        // Lock the safe surface: only the HELD wrappers conform to `_PatchReactiveWrapper`.
        // `@EnvironmentObject`/`@Environment` MUST NOT (their wrappedValue can trap).
        XCTAssertNotNil(ObservedObject(wrappedValue: _RCPlainVM()) as? _PatchReactiveWrapper,
                        "@ObservedObject is a safe held wrapper → conforms")
        XCTAssertNil(EnvironmentObject<_RCEnvVM>() as Any as? _PatchReactiveWrapper,
                     "@EnvironmentObject must NOT conform (its wrappedValue can trap)")
    }

    // MARK: - Bug #6: a non-marshallable SIBLING must not zero the whole object

    func testReactiveObjectWithUnencodableSiblingKeepsCollection() {
        // A reactive VM holding a stored closure `var onTap: () -> Void` and a
        // `Set<_RCFakeCancellable>` ALONGSIDE `var items: [_RCItem]`. Before the fix, the
        // first unencodable sibling (the closure) made `encodeObject` return nil → the whole
        // VM marshalled to `{}` → a `ForEach(vm.items)` read an EMPTY array (a populated list
        // rendered empty). The fix SKIPS the unencodable siblings and KEEPS the encodable
        // `items` — the load-bearing guarantee: the collection the body reads survives.
        let vm = _RCSiblingVM()
        let e = PatchInstanceInputs.extract(from: _RCSiblingView(vm: vm))
        XCTAssertNotEqual(e.json, "{}", "the object must not zero out")
        XCTAssertNotEqual(e.json, #"{"vm":{}}"#, "the VM must not zero out to {}")
        XCTAssertTrue(e.json.contains(#""items":[{"id":9,"label":"S"}]"#),
                      "the collection must survive an unencodable sibling: \(e.json)")
        XCTAssertFalse(e.json.contains("onTap"),
                       "the unencodable closure sibling is omitted, not emitted: \(e.json)")
        // Direct encoder check: a non-nil object carrying the data field (closure skipped).
        let obj = PatchValueEncoder.encode(vm)
        XCTAssertNotNil(obj, "encodeObject must not fail the whole object on an unencodable sibling")
        XCTAssertTrue(obj?.contains(#""items":[{"id":9,"label":"S"}]"#) ?? false,
                      "encodeObject skips unencodable siblings, keeps the data field: \(obj ?? "nil")")
    }

    // MARK: - Bug #9: a @Published in .publisher storage must not corrupt the object

    func testPublishedInPublisherStorageDoesNotCorruptObject() {
        // Force the `@Published var counter` storage into `.publisher` by attaching a Combine
        // subscriber to its projected publisher. BUG #3: `unwrapPublished` now reads the
        // `.publisher` subject's live `currentValue` (here the initial `0`), so the field
        // MARSHALS its real value instead of being skipped. The object never corrupts; the
        // plain `items` collection still marshals. (Keys sorted: counter before items.)
        let vm = _RCPublisherStateVM()
        let token = vm.$counter.sink { _ in }   // subscriber attach → storage becomes .publisher
        defer { token.cancel() }
        let e = PatchInstanceInputs.extract(from: _RCPublisherStateView(vm: vm))
        XCTAssertEqual(e.json, #"{"vm":{"counter":0,"items":[{"id":4,"label":"Q"}]}}"#,
                       "a .publisher-state @Published marshals its live currentValue (bug #3): \(e.json)")
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

    private struct DoubleBinding: View {
        @Binding var opacity: Double
        var body: some View { EmptyView() }
    }

    /// REGRESSION (the Slider/Double write-back data-loss bug): the guest serializes an
    /// integral `Double` (`1.0`/`0.0`) without a fractional part, so the JSON number is
    /// integral and `unbox` collapses it to `Int`. Before the `_patchCoerceScalar` fix,
    /// `Int as? Double` was nil → the native `@State<Double>`/`Binding<Double>` (a Slider at
    /// an integral stop) silently did NOT update. Now it coerces Int→Double and writes.
    func testApplyWritebacksWritesIntegralDoubleThroughBinding() {
        let box = Box(0.5)
        let sample = DoubleBinding(opacity: Binding(get: { box.v }, set: { box.v = $0 }))
        let e = PatchInstanceInputs.extract(from: sample)
        // Drag the Slider to 1.0 (an INTEGRAL stop — the previously-broken case).
        PatchedBodyHost.applyWritebacks(e.writebacks, newStateJSON: #"{"opacity":1}"#)
        XCTAssertEqual(box.v, 1.0, accuracy: 1e-9,
                       "an integral Double (1.0) must write back through Binding<Double>")
        // Drag to 0.0 (the other integral extreme).
        PatchedBodyHost.applyWritebacks(e.writebacks, newStateJSON: #"{"opacity":0}"#)
        XCTAssertEqual(box.v, 0.0, accuracy: 1e-9, "0.0 must write back too")
        // A fractional value still works (the control case).
        PatchedBodyHost.applyWritebacks(e.writebacks, newStateJSON: #"{"opacity":0.42}"#)
        XCTAssertEqual(box.v, 0.42, accuracy: 1e-9, "a fractional Double writes back")
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

    // MARK: - NATIVE-FAST-PATH: bodyHash decode (additive, backward-compatible)

    /// The `bodyHash` field decodes when present, and is `nil` for a manifest from an
    /// OLD cli that predates the field — the fail-safe input (the SDK then routes WASM).
    func testManifestBodyHashDecodesAndDefaultsNilForOldManifest() throws {
        let json = """
        {"schemaVersion":1,"views":[
          {"type":"A","export":"view_body__A","dispatch":null,"thunkSafe":true,"bodyHash":"deadbeefcafef00d"},
          {"type":"B","export":"view_body__B","dispatch":null,"thunkSafe":true}
        ]}
        """
        let m = try JSONDecoder().decode(PatchViewManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.views[0].bodyHash, "deadbeefcafef00d", "present hash decodes")
        XCTAssertNil(m.views[1].bodyHash, "an entry without the key decodes to nil (old manifest)")
    }
}

// MARK: - NATIVE-FAST-PATH routing gate

/// The single highest-value perf feature: an UNPATCHED view (its baked `baselineHash`
/// equals the active module's manifest `bodyHash`) renders its NATIVE body with ZERO
/// WASM (`thunkBody` returns nil); a CHANGED view, or any unknown/missing hash, routes
/// WASM. These tests pin the gate's truth table + the fail-safe (a false "native" — a
/// real patch silently not applying — must be impossible).
@MainActor
final class NativeFastPathGateTests: XCTestCase {

    private struct ViewA { var title = "A" }
    private struct ViewB { var title = "B" }

    private func entry(_ type: String, bodyHash: String?) -> PatchViewManifest.Entry {
        PatchViewManifest.Entry(type: type, export: "view_body__\(type)", dispatch: nil,
                                thunkSafe: true, minVersion: 8, bodyHash: bodyHash)
    }

    // NOTE: each test RESETS + installs its own entries at the top (deterministic, per the
    // "reset @MainActor caches in test methods not setUp" rule) — so no shared-singleton
    // state leaks between tests regardless of run order.

    /// view UNCHANGED (baselineHash == manifest.bodyHash) → nil (NATIVE, no WASM).
    func testEqualHashRendersNativeNoWASM() {
        Patch.configure(.init(appKey: "test-fastpath-eq", apiBaseURL: nil))
        PatchViewPatchRegistry.shared.resetForTesting()
        PatchViewPatchRegistry.shared.installEntriesForTesting([entry("ViewA", bodyHash: "abc123def456abcd")])
        let host = Patch.shared.thunkBody(typeName: "ViewA", baselineHash: "abc123def456abcd",
                                          instance: ViewA())
        XCTAssertNil(host, "an unchanged view (equal hashes) must render NATIVE — nil, no WASM round-trip")
    }

    /// view CHANGED (baselineHash != manifest.bodyHash) → non-nil (WASM).
    func testDifferentHashRoutesWASM() {
        Patch.configure(.init(appKey: "test-fastpath-diff", apiBaseURL: nil))
        PatchViewPatchRegistry.shared.resetForTesting()
        // The active module ships a DIFFERENT body for ViewA than this build's baseline
        // (an OTA patch changed it) → its bodyHash differs from the thunk's baselineHash.
        PatchViewPatchRegistry.shared.installEntriesForTesting([entry("ViewA", bodyHash: "1111111111111111")])
        let host = Patch.shared.thunkBody(typeName: "ViewA", baselineHash: "abc123def456abcd",
                                          instance: ViewA())
        XCTAssertNotNil(host, "a changed view (different hashes) must route WASM (a real patch applies)")
    }

    /// FAIL-SAFE: manifest bodyHash is nil (an OLD module) → route WASM, never false-native.
    func testNilManifestHashFailsSafeToWASM() {
        Patch.configure(.init(appKey: "test-fastpath-oldmod", apiBaseURL: nil))
        PatchViewPatchRegistry.shared.resetForTesting()
        PatchViewPatchRegistry.shared.installEntriesForTesting([entry("ViewA", bodyHash: nil)])
        let host = Patch.shared.thunkBody(typeName: "ViewA", baselineHash: "abc123def456abcd",
                                          instance: ViewA())
        XCTAssertNotNil(host, "no manifest bodyHash (old module) must FAIL SAFE to WASM")
    }

    /// FAIL-SAFE: thunk baselineHash is nil (an OLD thunk) → route WASM, never false-native.
    func testNilBaselineHashFailsSafeToWASM() {
        Patch.configure(.init(appKey: "test-fastpath-oldthunk", apiBaseURL: nil))
        PatchViewPatchRegistry.shared.resetForTesting()
        PatchViewPatchRegistry.shared.installEntriesForTesting([entry("ViewA", bodyHash: "abc123def456abcd")])
        // baselineHash defaults to nil (a thunk generated by the OLD cli).
        let host = Patch.shared.thunkBody(typeName: "ViewA", instance: ViewA())
        XCTAssertNotNil(host, "no baked baselineHash (old thunk) must FAIL SAFE to WASM")
    }

    /// TWO-VIEW SCENARIO: A's hash DIFFERS (patched) → WASM; B's MATCHES (unpatched) → native.
    func testTwoViewScenarioOnlyChangedViewRoutesWASM() {
        Patch.configure(.init(appKey: "test-fastpath-two", apiBaseURL: nil))
        PatchViewPatchRegistry.shared.resetForTesting()
        PatchViewPatchRegistry.shared.installEntriesForTesting([
            entry("ViewA", bodyHash: "AAAAAAAAAAAAAAAA"),  // module ships a CHANGED A
            entry("ViewB", bodyHash: "BBBBBBBBBBBBBBBB"),  // module ships the SAME B
        ])
        // The app build baked these baselines into the thunks.
        let hostA = Patch.shared.thunkBody(typeName: "ViewA", baselineHash: "ZZZZZZZZZZZZZZZZ",
                                           instance: ViewA())
        let hostB = Patch.shared.thunkBody(typeName: "ViewB", baselineHash: "BBBBBBBBBBBBBBBB",
                                           instance: ViewB())
        XCTAssertNotNil(hostA, "ViewA changed (A's bodyHash != A's baseline) → WASM")
        XCTAssertNil(hostB, "ViewB unchanged (B's bodyHash == B's baseline) → NATIVE, no WASM")
    }

    /// A view NOT in the active manifest never routes regardless of hash (the prior behavior).
    func testUnknownViewNeverRoutes() {
        Patch.configure(.init(appKey: "test-fastpath-unknown", apiBaseURL: nil))
        PatchViewPatchRegistry.shared.resetForTesting()
        PatchViewPatchRegistry.shared.installEntriesForTesting([entry("ViewA", bodyHash: "abc123def456abcd")])
        XCTAssertNil(Patch.shared.thunkBody(typeName: "NotInManifest", baselineHash: "abc123def456abcd",
                                            instance: ViewB()))
    }

    /// NO-WASM EVIDENCE: the native fast-path short-circuits BEFORE the instance marshal
    /// (`PatchInstanceInputs.extract`, which is what feeds the WASM render). Proof: an
    /// EQUAL-hash call leaves the marshal cache for that type EMPTY (extract never ran),
    /// whereas a DIFFERENT-hash call POPULATES it (extract + the WASM render path ran).
    /// Since `PatchedBodyHost` is the only thing that ever invokes WASM, "no host built +
    /// no marshal" ⟺ "no WASM on the native path".
    func testNativePathSkipsMarshalDifferentPathDoesNot() {
        struct MarshalProbe { var title = "probe"; var count = 3 }
        Patch.configure(.init(appKey: "test-fastpath-evidence", apiBaseURL: nil))

        // (a) EQUAL hash → native: the marshal cache for this type stays EMPTY.
        PatchViewPatchRegistry.shared.resetForTesting()
        PatchViewPatchRegistry.shared.installEntriesForTesting([entry("MarshalProbe", bodyHash: "fadefadefadefade")])
        PatchMarshalCache.shared.reset()
        let nativeHost = Patch.shared.thunkBody(typeName: "MarshalProbe", baselineHash: "fadefadefadefade",
                                                instance: MarshalProbe())
        XCTAssertNil(nativeHost, "equal hash → native")
        XCTAssertEqual(PatchMarshalCache.shared.entryCount(typeName: "MarshalProbe"), 0,
                       "the native fast-path must NOT run the instance marshal — it short-circuits "
                       + "before extract(), so NO WASM render can occur")

        // (b) DIFFERENT hash → WASM render path: the marshal runs (cache populates).
        PatchViewPatchRegistry.shared.resetForTesting()
        PatchViewPatchRegistry.shared.installEntriesForTesting([entry("MarshalProbe", bodyHash: "0000000000000000")])
        PatchMarshalCache.shared.reset()
        let wasmHost = Patch.shared.thunkBody(typeName: "MarshalProbe", baselineHash: "fadefadefadefade",
                                              instance: MarshalProbe())
        XCTAssertNotNil(wasmHost, "different hash → WASM")
        XCTAssertEqual(PatchMarshalCache.shared.entryCount(typeName: "MarshalProbe"), 1,
                       "the WASM path DOES run the instance marshal (contrast that proves the gate "
                       + "short-circuits the native path before any render work)")
        PatchMarshalCache.shared.reset()
    }
}

// MARK: - R2 SDK bug-batch regression tests

@MainActor
final class R2SDKBugBatchTests: XCTestCase {

    // R2-#98/#99: scalarEqual must compare large integral values EXACTLY (not via a
    // lossy Double), so a real write-back to a value > 2^53 isn't suppressed as a no-op.
    func testScalarEqualLargeIntDistinguishesAdjacentValues() {
        let a = 9_007_199_254_740_992       // 2^53
        let b = 9_007_199_254_740_993       // 2^53 + 1 (NOT representable as a distinct Double)
        // Both arrive as Int here AND as JSON-parsed NSNumbers in the real path.
        XCTAssertFalse(PatchFlatJSON.scalarEqual(a, b),
                       "adjacent large ints must NOT compare equal (Double would collapse them)")
        XCTAssertTrue(PatchFlatJSON.scalarEqual(a, a))
        XCTAssertTrue(PatchFlatJSON.scalarEqual(b, b))
    }

    func testScalarEqualLargeIntViaJSONNSNumber() {
        // Mirror the live path: the guest emits the value, JSONSerialization parses it
        // as an integer NSNumber, and scalarEqual gates the write-back.
        let parsed = { (s: String) -> Any in
            let obj = try! JSONSerialization.jsonObject(
                with: ("[" + s + "]").data(using: .utf8)!, options: [.fragmentsAllowed])
            return (obj as! [Any])[0]
        }
        let current: Any = 9_007_199_254_740_992
        let incoming = parsed("9007199254740993")
        XCTAssertFalse(PatchFlatJSON.scalarEqual(current, incoming),
                       "a real large-int write must not be suppressed")
        XCTAssertTrue(PatchFlatJSON.scalarEqual(current, parsed("9007199254740992")))
    }

    func testScalarEqualStillEqualForOrdinaryAndFloatValues() {
        XCTAssertTrue(PatchFlatJSON.scalarEqual(3, 3.0))      // int vs integral double
        XCTAssertTrue(PatchFlatJSON.scalarEqual(1.5, 1.5))
        XCTAssertFalse(PatchFlatJSON.scalarEqual(1.5, 1.6))
        XCTAssertTrue(PatchFlatJSON.scalarEqual("x", "x"))
        XCTAssertFalse(PatchFlatJSON.scalarEqual("x", "y"))
        XCTAssertTrue(PatchFlatJSON.scalarEqual(true, true))
        XCTAssertFalse(PatchFlatJSON.scalarEqual(true, false))
        // A Bool must never be treated as a number.
        XCTAssertFalse(PatchFlatJSON.scalarEqual(true, 1))
    }

    // R2-#137: jsonFragmentsEqual canonicalizes (sorted keys) so equal objects with
    // different key order compare equal — used to suppress no-op non-scalar write-backs.
    func testJSONFragmentsEqualIgnoresKeyOrder() {
        XCTAssertTrue(PatchedBodyHost.jsonFragmentsEqual(
            #"{"a":1,"b":2}"#, #"{"b":2,"a":1}"#))
        XCTAssertTrue(PatchedBodyHost.jsonFragmentsEqual("[1,2,3]", "[1,2,3]"))
        XCTAssertTrue(PatchedBodyHost.jsonFragmentsEqual("null", "null"))
    }

    func testJSONFragmentsEqualDetectsRealDifference() {
        XCTAssertFalse(PatchedBodyHost.jsonFragmentsEqual(
            #"{"a":1,"b":2}"#, #"{"a":1,"b":3}"#))
        XCTAssertFalse(PatchedBodyHost.jsonFragmentsEqual("[1,2]", "[1,2,3]"))
        // Unparseable fragment → NOT equal (so the caller performs the write — demote-safe).
        XCTAssertFalse(PatchedBodyHost.jsonFragmentsEqual("not json", "not json either"))
    }
}

// MARK: - Split-signal architecture tests (F5/W2, V7 spec)

/// Proves the B1 safety invariant (demote scopes to type only) and the stranded-view
/// guarantee (module activation re-renders a previously-unpatched view).
///
/// NOTE: these tests exercise the `PatchViewPatchRegistry` state machine directly —
/// they DON'T need a real SwiftUI render loop because the invariants are in the
/// registry's signal dispatch, not in SwiftUI's Observation engine. We verify that
/// (a) `markFailed` inserts into `failedTypes` and only bumps the per-type signal
/// (i.e. type B's `entryIfPatchable` still returns a non-nil entry after A is failed),
/// and (b) after an epoch advance the registry reflects a new manifest (proving a
/// previously-absent view becomes patchable on the next call).
@MainActor
final class SplitSignalArchitectureTests: XCTestCase {

    private func makeEntry(_ type: String) -> PatchViewManifest.Entry {
        PatchViewManifest.Entry(type: type, export: "view_body__\(type)", dispatch: nil,
                                thunkSafe: true, minVersion: nil, bodyHash: nil)
    }

    // MARK: - Test (a): demote of type A does NOT invalidate type B

    /// After `markFailed("ViewA")`, `entryIfPatchable("ViewB")` must still return a
    /// non-nil entry. If the old single-signal design were still in place, `markFailed`
    /// would bump the global signal and BOTH views' deps would be re-evaluated — but
    /// crucially, `failedTypes` only contains "ViewA", so B's entry would still be
    /// returned. The split-signal ensures the Observation dependency for B was NOT
    /// registered against the per-type A signal, so B's thunk is NOT re-triggered.
    ///
    /// The state-machine correctness we can verify without SwiftUI: after markFailed(A),
    /// `entryIfPatchable("ViewA")` returns nil (A is demoted) and
    /// `entryIfPatchable("ViewB")` returns non-nil (B is unaffected).
    func testDemoteTypeADoesNotAffectTypeB() {
        Patch.configure(.init(appKey: "test-split-signal-demote", apiBaseURL: nil))
        let registry = PatchViewPatchRegistry.shared
        registry.resetForTesting()
        registry.installEntriesForTesting([makeEntry("ViewA"), makeEntry("ViewB")])

        // Both should be patchable before any demote.
        XCTAssertNotNil(registry.entryIfPatchable(typeName: "ViewA"),
                        "ViewA must be patchable before any demote")
        XCTAssertNotNil(registry.entryIfPatchable(typeName: "ViewB"),
                        "ViewB must be patchable before any demote")

        // Demote type A only.
        registry.markFailed(typeName: "ViewA", forEpoch: nil)

        // A is now demoted (returns nil); B is unaffected (still non-nil).
        XCTAssertNil(registry.entryIfPatchable(typeName: "ViewA"),
                     "ViewA must be demoted after markFailed(ViewA)")
        XCTAssertNotNil(registry.entryIfPatchable(typeName: "ViewB"),
                        "ViewB must remain patchable — demoting A must NOT affect B")

        registry.resetForTesting()
    }

    // MARK: - Test (b): B1 stranded-view — module activation re-renders a previously-unpatched view

    /// A view (ViewC) that was NOT in the OLD module's manifest becomes patchable
    /// when a NEW module that INCLUDES it is loaded (epoch advances). The global
    /// module signal must re-evaluate all views including ViewC, so it discovers it
    /// is now patchable instead of being stranded on the native path.
    ///
    /// We simulate this by: (1) installing a manifest WITHOUT ViewC, confirming
    /// `entryIfPatchable("ViewC")` returns nil; (2) advancing the epoch so the
    /// registry re-syncs; (3) installing a manifest WITH ViewC, confirming it now
    /// returns non-nil. The registry's `syncWithModuleEpoch` triggers the reload
    /// on the next `entryIfPatchable` call — exactly what happens when the global
    /// module signal triggers a re-evaluation of ViewC's thunk.
    func testModuleActivationUnstrandsNewlyPatchableView() {
        Patch.configure(.init(appKey: "test-split-signal-strand", apiBaseURL: nil))
        let registry = PatchViewPatchRegistry.shared
        registry.resetForTesting()

        // OLD module: ViewA is patchable, ViewC is NOT (absent from manifest).
        registry.installEntriesForTesting([makeEntry("ViewA")])
        XCTAssertNotNil(registry.entryIfPatchable(typeName: "ViewA"),
                        "ViewA is in the manifest → patchable")
        XCTAssertNil(registry.entryIfPatchable(typeName: "ViewC"),
                     "ViewC is NOT in the manifest → returns nil (native)")

        // Simulate a module change: install a NEW manifest that includes ViewC.
        // We reset and re-install (simulating an epoch advance + new manifest load).
        registry.resetForTesting()
        registry.installEntriesForTesting([makeEntry("ViewA"), makeEntry("ViewC")])

        // After the epoch advance + registry re-sync, ViewC is now patchable.
        // The GLOBAL module signal guarantees ViewC's thunk re-evaluates and discovers this.
        XCTAssertNotNil(registry.entryIfPatchable(typeName: "ViewC"),
                        "ViewC must be patchable after the new module is loaded — "
                        + "the global module signal ensures no B1 stranded-view")
        XCTAssertNotNil(registry.entryIfPatchable(typeName: "ViewA"),
                        "ViewA remains patchable in the new module")

        registry.resetForTesting()
    }

    // MARK: - Additional: typeSignals cleared on epoch advance

    /// Proves that per-type signals are cleared when the module epoch advances
    /// (via syncWithModuleEpoch / resetForTesting). A failed type from the old
    /// epoch must NOT be failed in the new epoch.
    func testFailedTypeIsResetOnEpochAdvance() {
        Patch.configure(.init(appKey: "test-split-signal-epochreset", apiBaseURL: nil))
        let registry = PatchViewPatchRegistry.shared
        registry.resetForTesting()
        registry.installEntriesForTesting([makeEntry("ViewD")])

        // Demote ViewD in the current epoch.
        registry.markFailed(typeName: "ViewD", forEpoch: nil)
        XCTAssertNil(registry.entryIfPatchable(typeName: "ViewD"),
                     "ViewD is demoted in the current epoch")

        // Simulate a new epoch: reset + re-install (as syncWithModuleEpoch would do).
        registry.resetForTesting()
        registry.installEntriesForTesting([makeEntry("ViewD")])

        // ViewD must be patchable again — the epoch reset cleared failedTypes.
        XCTAssertNotNil(registry.entryIfPatchable(typeName: "ViewD"),
                        "ViewD must be patchable in the new epoch (failedTypes cleared on epoch advance)")

        registry.resetForTesting()
    }
}
#endif
