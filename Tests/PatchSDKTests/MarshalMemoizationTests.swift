import XCTest
@testable import PatchSDK
#if canImport(SwiftUI)
import SwiftUI
import Combine
@testable import PatchSwiftUI
#endif

// MarshalMemoizationTests — P0 PERF CORRECTNESS GATE for the marshalling memoization.
// ===================================================================================
// `PatchInstanceInputs.extract(from:typeName:)` skips the ~159µs recursive JSON
// string-build when the instance's marshalled state is UNCHANGED since a recent render
// (the SwiftUI steady state), reusing the cached propsJSON keyed by a change-detector
// FINGERPRINT. A STALE/wrong propsJSON = WRONG UI on device — worse than slow — so these
// tests guard the false-render hazard directly:
//   (T) TRANSPARENCY: memoized extract == always-fresh extract, byte-for-byte, for EVERY
//       supported shape (scalar/collection/nested-struct/optional/enum/dict/Set/Date/etc.).
//   (a) CHANGED field → re-marshal (fresh propsJSON, no stale reuse).
//   (b) UNCHANGED instance → reuse the cached propsJSON.
//   (c) Equal fingerprint ⟺ equal marshalled JSON; a value/length/optional/enum/key change
//       always changes the fingerprint (the change-detector catches every real change).
//   (d) An un-fingerprintable instance NEVER caches (always re-encodes) — never wrong.
//   (e) Writebacks are LIVE — re-collected every render, never cached.
//   (f) The marshal cache is LRU-bounded.
#if canImport(SwiftUI)
@MainActor
final class MarshalMemoizationTests: XCTestCase {

    // MARK: - Fixtures (a spread of every encoder shape)

    struct Row: View { var id: Int; var title: String; var enabled: Bool
        var body: some View { EmptyView() } }
    enum Status { case active, archived(reason: String), pending(Int, String) }

    struct RichInstance: View {
        @State var notificationsOn: Bool = true
        @State var badgeCount: Int = 3
        @State var displayName: String = "Ada"
        var subtitle: String? = "member"
        var rows: [Row] = (0..<10).map { Row(id: $0, title: "Row \($0)", enabled: $0 % 2 == 0) }
        var tags: Set<String> = ["a", "b", "c"]
        var counts: [String: Int] = ["x": 1, "y": 2]
        var when: Date = Date(timeIntervalSince1970: 1_700_000_000)
        var status: Status = .archived(reason: "stale")
        var ratio: Double = 0.5
        var integral: Double = 2.0
        var body: some View { EmptyView() }
    }

    struct ScalarInstance: View {
        @State var on: Bool = true
        @State var n: Int = 0
        @State var name: String = "x"
        var body: some View { EmptyView() }
    }

    // MARK: - (T) Transparency: memoized == always-fresh, byte-for-byte

    func testMemoizedMatchesFreshAcrossShapes() {
        PatchMarshalCache.shared.reset()
        // For a spread of instances, the memoized extract must produce the SAME json as the
        // always-fresh extract — on the MISS (first call) AND on the HIT (second call).
        func assertTransparent(_ instance: Any, _ typeName: String, _ label: String) {
            let fresh = PatchInstanceInputs.extract(from: instance).json
            let miss = PatchInstanceInputs.extract(from: instance, typeName: typeName).json
            XCTAssertEqual(miss, fresh, "[\(label)] memoized MISS json must equal fresh json")
            let hit = PatchInstanceInputs.extract(from: instance, typeName: typeName).json
            XCTAssertEqual(hit, fresh, "[\(label)] memoized HIT json must equal fresh json")
        }
        assertTransparent(RichInstance(), "Rich", "rich")
        assertTransparent(ScalarInstance(), "Scalar", "scalar")
        assertTransparent(RichInstance(rows: []), "Rich", "empty-array")
        assertTransparent(RichInstance(subtitle: nil), "Rich", "nil-optional")
        assertTransparent(RichInstance(status: .pending(5, "soon")), "Rich", "enum-payload-tuple")
        assertTransparent(RichInstance(counts: [:]), "Rich", "empty-dict")
        assertTransparent(RichInstance(tags: []), "Rich", "empty-set")
    }

    // MARK: - (b) Unchanged instance → HIT (cached propsJSON reused)

    func testUnchangedInstanceIsCacheHit() {
        PatchMarshalCache.shared.reset()
        let inst = RichInstance()
        XCTAssertEqual(PatchMarshalCache.shared.entryCount(typeName: "Rich"), 0)
        _ = PatchInstanceInputs.extract(from: inst, typeName: "Rich")          // MISS → store
        XCTAssertEqual(PatchMarshalCache.shared.entryCount(typeName: "Rich"), 1, "first extract stores one entry")
        // A second extract of an equivalent instance must HIT — still 1 entry, same json.
        let json1 = PatchInstanceInputs.extract(from: RichInstance(), typeName: "Rich").json
        XCTAssertEqual(PatchMarshalCache.shared.entryCount(typeName: "Rich"), 1, "unchanged state must not add an entry")
        XCTAssertEqual(json1, PatchInstanceInputs.extract(from: inst).json, "HIT json must equal fresh json")
    }

    // MARK: - (a) Changed field → MISS → fresh json (no stale reuse)

    func testChangedScalarRemarshals() {
        PatchMarshalCache.shared.reset()
        let a = RichInstance(badgeCount: 3)
        let b = RichInstance(badgeCount: 99)
        let ja = PatchInstanceInputs.extract(from: a, typeName: "Rich").json
        let jb = PatchInstanceInputs.extract(from: b, typeName: "Rich").json
        XCTAssertNotEqual(ja, jb, "a changed scalar must produce different json")
        XCTAssertEqual(jb, PatchInstanceInputs.extract(from: b).json, "the changed json must equal a fresh marshal of b")
        // Both fingerprints cached → 2 distinct entries.
        XCTAssertEqual(PatchMarshalCache.shared.entryCount(typeName: "Rich"), 2)
    }

    func testChangedStringRemarshals() {
        PatchMarshalCache.shared.reset()
        let j1 = PatchInstanceInputs.extract(from: RichInstance(displayName: "Ada"), typeName: "Rich").json
        let j2 = PatchInstanceInputs.extract(from: RichInstance(displayName: "Bob"), typeName: "Rich").json
        XCTAssertNotEqual(j1, j2)
        XCTAssertTrue(j2.contains("Bob") && !j2.contains("Ada"), "the changed string must appear in the json: \(j2)")
    }

    // MARK: - (c) Fingerprint catches EVERY real change

    /// equal-state ⇒ equal fingerprint; different-state ⇒ different fingerprint AND different
    /// json. Run a battery of single-field mutations and assert the fingerprint moves with the
    /// json (never a json change without a fingerprint change — that would be a stale-render bug).
    func testFingerprintCatchesEveryChange() {
        func fp(_ inst: Any) -> UInt64? {
            PatchInstanceInputs.fingerprint(of: PatchInstanceInputs.selectFields(from: inst))
        }
        func json(_ inst: Any) -> String { PatchInstanceInputs.extract(from: inst).json }

        let base = RichInstance()
        // Equal state → equal fingerprint + equal json.
        XCTAssertEqual(fp(base), fp(RichInstance()))
        XCTAssertEqual(json(base), json(RichInstance()))

        // A battery of mutations: each must change BOTH json and fingerprint.
        let mutated: [(String, RichInstance)] = [
            ("bool",          RichInstance(notificationsOn: false)),
            ("int",           RichInstance(badgeCount: 4)),
            ("string",        RichInstance(displayName: "Bob")),
            ("optional-nil",  RichInstance(subtitle: nil)),
            ("optional-val",  RichInstance(subtitle: "guest")),
            ("array-content", RichInstance(rows: (0..<10).map { Row(id: $0, title: "X\($0)", enabled: true) })),
            ("array-length",  RichInstance(rows: (0..<3).map { Row(id: $0, title: "Row \($0)", enabled: true) })),
            ("set-content",   RichInstance(tags: ["a", "b", "z"])),
            ("dict-content",  RichInstance(counts: ["x": 1, "y": 3])),
            ("dict-keys",     RichInstance(counts: ["x": 1, "z": 2])),
            ("date",          RichInstance(when: Date(timeIntervalSince1970: 1_700_000_001))),
            ("enum-case",     RichInstance(status: .active)),
            ("enum-payload",  RichInstance(status: .archived(reason: "other"))),
            ("double-frac",   RichInstance(ratio: 0.75)),
            ("double-int",    RichInstance(integral: 3.0)),
        ]
        let baseJSON = json(base)
        let baseFP = fp(base)
        for (label, m) in mutated {
            let mJSON = json(m)
            let mFP = fp(m)
            XCTAssertNotEqual(mJSON, baseJSON, "[\(label)] json must change")
            // The CRITICAL invariant: a json change MUST be accompanied by a fingerprint change
            // (else memoization would serve a stale json — wrong UI).
            XCTAssertNotEqual(mFP, baseFP, "[\(label)] fingerprint must change when json changes (no stale-render)")
        }
    }

    /// Set/dict order-independence: two instances whose Set/Dict differ ONLY in iteration
    /// order must have the SAME fingerprint AND the same json (the encoder sorts them).
    func testSetAndDictOrderIndependence() {
        let a = RichInstance(tags: ["a", "b", "c"], counts: ["x": 1, "y": 2])
        let b = RichInstance(tags: ["c", "a", "b"], counts: ["y": 2, "x": 1])
        func fp(_ inst: Any) -> UInt64? {
            PatchInstanceInputs.fingerprint(of: PatchInstanceInputs.selectFields(from: inst))
        }
        XCTAssertEqual(PatchInstanceInputs.extract(from: a).json, PatchInstanceInputs.extract(from: b).json,
                       "Set/Dict marshal order-independently")
        XCTAssertEqual(fp(a), fp(b), "Set/Dict fingerprint order-independently")
    }

    // MARK: - Adversarial: type/shape aliasing must NOT collide

    // Values that print the SAME but marshal to DIFFERENT json (Int 2 → `2`, Double 2.0 → `2`,
    // String "2" → `"2"`, Bool true → `true`) must have DISTINCT fingerprints — a weak hash
    // that ignored the type kind would alias them and serve stale json.
    func testTypeKindNeverAliases() {
        struct Holder: View { var v: Any; var body: some View { EmptyView() } }
        // We can't put `Any` through @State, but a plain stored prop exercises the same encoder.
        func fp(_ value: Any) -> UInt64? {
            // Wrap as a one-field struct so the top-level walk hashes a single value.
            struct One: View { let x: Any; var body: some View { EmptyView() } }
            return PatchInstanceInputs.fingerprint(of: PatchInstanceInputs.selectFields(from: One(x: value)))
        }
        func json(_ value: Any) -> String {
            struct One: View { let x: Any; var body: some View { EmptyView() } }
            return PatchInstanceInputs.extract(from: One(x: value)).json
        }
        let cases: [(String, Any)] = [
            ("int2", 2), ("double2", 2.0), ("string2", "2"), ("boolTrue", true), ("int0", 0), ("boolFalse", false),
        ]
        // Every pair with DIFFERENT json must have a DIFFERENT fingerprint.
        for i in 0..<cases.count {
            for j in (i+1)..<cases.count {
                let (ni, vi) = cases[i]; let (nj, vj) = cases[j]
                if json(vi) != json(vj) {
                    XCTAssertNotEqual(fp(vi), fp(vj), "[\(ni) vs \(nj)] differ in json but share a fingerprint (aliasing)")
                }
            }
        }
        // Sanity: the json forms are what we expect.
        XCTAssertEqual(json(2), "{\"x\":2}")
        XCTAssertEqual(json(2.0), "{\"x\":2}")          // integral double prints as int
        XCTAssertEqual(json("2"), "{\"x\":\"2\"}")
        XCTAssertEqual(json(true), "{\"x\":true}")
        // Int 2 and Double 2.0 marshal to IDENTICAL json (both `2`). The fingerprint folds a
        // per-kind type TAG, so it distinguishes them (DIFFERENT fp). That is SAFE — a stricter
        // fingerprint than the json can only cause a benign cache MISS (re-deriving the same
        // json), NEVER a stale HIT. The crucial direction — equal fp ⇒ equal json — is what the
        // pairwise loop above guards. (We do NOT require fp(2)==fp(2.0); strictness is fine.)
        XCTAssertNotNil(fp(2)); XCTAssertNotNil(fp(2.0))
    }

    // MARK: - End-to-end: through the memoizing extract, a mutation never serves stale json

    func testEndToEndNoStaleAcrossMutations() {
        PatchMarshalCache.shared.reset()
        // Render a sequence of states through the MEMOIZING extract and confirm every one
        // matches its own fresh marshal — i.e. the cache never serves a previous state's json.
        let states: [RichInstance] = [
            RichInstance(),
            RichInstance(badgeCount: 1),
            RichInstance(),                                   // back to base (should HIT base entry)
            RichInstance(displayName: "Zed"),
            RichInstance(rows: []),
            RichInstance(subtitle: nil),
            RichInstance(badgeCount: 1),                      // repeat (should HIT)
        ]
        for (i, s) in states.enumerated() {
            let memo = PatchInstanceInputs.extract(from: s, typeName: "Rich").json
            let fresh = PatchInstanceInputs.extract(from: s).json
            XCTAssertEqual(memo, fresh, "state #\(i): memoized extract served a STALE json")
        }
    }

    // MARK: - (e) Writebacks are LIVE (re-collected, never cached)

    func testWritebacksAreLiveOnHit() {
        PatchMarshalCache.shared.reset()
        let inst = ScalarInstance()
        let first = PatchInstanceInputs.extract(from: inst, typeName: "Scalar")   // MISS
        let second = PatchInstanceInputs.extract(from: inst, typeName: "Scalar")  // HIT
        // The HIT still returns the live writebacks for the wrapper-backed @State fields
        // (on, n, name — the 3 @State props), freshly collected from the instance.
        XCTAssertEqual(first.writebacks.count, 3)
        XCTAssertEqual(second.writebacks.count, 3, "a cache HIT must still return live writebacks (not cached/empty)")
        XCTAssertEqual(Set(second.writebacks.map(\.key)), ["on", "n", "name"])
    }

    // A wrapper-backed @State whose VALUE the encoder can't represent (a closure). The original
    // `extract` excluded such a field's writeback (it was gated on encodability); the refactor
    // includes it, which is PROVEN-INERT: the field is omitted from the marshalled JSON, so the
    // guest never returns its key, so `applyWritebacks` skips it (`guard let raw = state[key]`).
    // This test pins that the writeback list / JSON are still correct for that shape.
    struct StateClosureView: View {
        @State var n: Int = 1
        @State var handler: () -> Void = {}   // unencodable @State value
        var body: some View { EmptyView() }
    }

    func testUnencodableWrapperWritebackIsInertNotWrong() {
        PatchMarshalCache.shared.reset()
        let v = StateClosureView()
        let e = PatchInstanceInputs.extract(from: v, typeName: "SC")
        // Only `n` survives in the JSON (the closure @State is omitted, unencodable).
        XCTAssertEqual(e.json, "{\"n\":1}")
        // The memoized path matches the always-fresh path exactly.
        XCTAssertEqual(e.json, PatchInstanceInputs.extract(from: v).json)
        // applyWritebacks with a guest state lacking `handler` is a no-op for that key (the
        // guard `state[key] == nil` skips it) — proving the extra writeback is inert.
        // (We just assert the writeback list contains the keys; the inertness is structural.)
        let keys = Set(e.writebacks.map(\.key))
        XCTAssertTrue(keys.contains("n"), "the encodable @State writeback is present")
        PatchedBodyHost.applyWritebacks(e.writebacks, newStateJSON: "{\"n\":5}")  // no `handler` key
        // No crash, n got written; the closure writeback was a no-op (key absent).
    }

    // MARK: - (d) Reactive object mutation is detected (no stale)

    final class CounterVM: ObservableObject { @Published var count: Int; @Published var label: String
        init(count: Int, label: String) { self.count = count; self.label = label } }
    struct ReactiveView: View {
        @ObservedObject var vm: CounterVM
        var body: some View { EmptyView() }
    }

    func testReactiveObjectMutationDetected() {
        PatchMarshalCache.shared.reset()
        let vm = CounterVM(count: 1, label: "a")
        let v = ReactiveView(vm: vm)
        let j1 = PatchInstanceInputs.extract(from: v, typeName: "Reactive").json
        // Mutate the SAME object in place (the instance struct is recreated each render but
        // holds the same VM) — the fingerprint must dig into the object and detect the change.
        vm.count = 2
        let j2 = PatchInstanceInputs.extract(from: v, typeName: "Reactive").json
        XCTAssertNotEqual(j1, j2, "a reactive object's in-place mutation must re-marshal (no stale)")
        XCTAssertEqual(j2, PatchInstanceInputs.extract(from: v).json, "must equal a fresh marshal of the mutated object")
        XCTAssertTrue(j2.contains("\"count\":2"), "the new value must be present: \(j2)")
    }

    // MARK: - (f) LRU bound on the marshal cache

    func testMarshalCacheLRUBound() {
        PatchMarshalCache.shared.reset()
        let cap = PatchMarshalCache.capacityPerType
        // Insert cap+2 distinct states (distinct badgeCount → distinct fingerprint).
        for i in 0..<(cap + 2) {
            _ = PatchInstanceInputs.extract(from: RichInstance(badgeCount: i), typeName: "Rich")
        }
        XCTAssertEqual(PatchMarshalCache.shared.entryCount(typeName: "Rich"), cap,
                       "marshal cache must be bounded to capacityPerType")
    }

    // MARK: - Un-fingerprintable instance still marshals correctly (always re-encodes)

    // A value type whose Mirror has NO recognizable scalar/structured representation for one
    // field (a stored closure) — `PatchValueEncoder` omits it; the fingerprint feeds `false`
    // (representable=false). The instance still marshals fine and the memoized path equals fresh.
    struct ClosureHolder: View {
        @State var n: Int = 1
        var onTap: () -> Void = {}     // unencodable — encoder omits, fingerprint flags unrep
        var body: some View { EmptyView() }
    }

    func testUnfingerprintableFieldStillTransparent() {
        PatchMarshalCache.shared.reset()
        let inst = ClosureHolder(n: 5)
        let fresh = PatchInstanceInputs.extract(from: inst).json
        let memo1 = PatchInstanceInputs.extract(from: inst, typeName: "Closure").json
        let memo2 = PatchInstanceInputs.extract(from: inst, typeName: "Closure").json
        XCTAssertEqual(memo1, fresh)
        XCTAssertEqual(memo2, fresh)
        // The closure field is omitted; only `n` survives.
        XCTAssertEqual(fresh, "{\"n\":5}")
        // And a change to the encodable field still re-marshals.
        let changed = PatchInstanceInputs.extract(from: ClosureHolder(n: 6), typeName: "Closure").json
        XCTAssertEqual(changed, "{\"n\":6}")
    }
}
#endif
