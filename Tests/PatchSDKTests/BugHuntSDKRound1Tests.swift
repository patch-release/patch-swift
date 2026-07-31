// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import Combine
@testable import PatchSDK
import PatchViewIR
#if canImport(SwiftUI)
import SwiftUI
import PatchRender
@testable import PatchSwiftUI
#endif

/// Regression tests for the overnight-rigor SDK round-1 bug batch (E-sdk):
/// #3 (@Published .publisher collection), #23 (Date 1970/2001 write-back),
/// #46 (CustomStringConvertible enum case name), #47/#70 (leading-underscore field),
/// #49/#52 (dual-owned state masking), #51 (Int64/UInt write-back),
/// #73/#74 (large-Int precision). The render/lifecycle bugs (#22/#50/#71/#72/#44/#45)
/// are exercised through their pure helpers / public surfaces where unit-testable.
#if canImport(SwiftUI)

// MARK: - Fixtures

/// A flat-struct element a reactive collection holds (mirrors the existing suite).
private struct _R1Item { let id: Int; let title: String }

/// BUG #3: classic MVVM where the COLLECTION itself is `@Published` and a Combine
/// subscriber attached (`.assign(to:&$items)` / `.sink`), permanently moving the
/// storage to `.publisher`. The live rows must still marshal (not an empty list).
private final class _R1FeedVM: ObservableObject {
    @Published var items: [_R1Item] = []
    init(rows: [_R1Item]) {
        // `.assign(to: &$items)` permanently moves `_items` storage into `.publisher`
        // (no AnyCancellable needed) — the exact dominant MVVM shape bug #3 targets.
        Just(rows).assign(to: &$items)
    }
}
private struct _R1FeedView: View {
    @ObservedObject var vm: _R1FeedVM
    var body: some View { Text("x") }
}

/// BUG #46: a raw-value enum that ALSO conforms to `CustomStringConvertible` with a
/// custom description. `String(describing:)` returns the description, not the case
/// name — the guest compares the case LABEL, so it must marshal the true label.
private enum _R1Status: String, CustomStringConvertible {
    case active = "ACTIVE"
    case archived
    var description: String { "Status.\(rawValue)" }
}

/// BUG #47/#70: a struct with a source field literally named `_count`.
private struct _R1Underscored { var _count: Int; var title: String }

/// A persisting `_PatchScalarWrapper` test double (a real `@State` setter no-ops
/// outside a SwiftUI view, so it can't verify a write). It runs the SAME coercion
/// the built-in wrappers do, so it exercises `_patchCoerceScalar` end-to-end through
/// `applyWritebacks` (#51/#74).
@MainActor
private final class _R1IntBox<Value>: _PatchScalarWrapper {
    var stored: Value
    init(_ v: Value) { stored = v }
    func _patchRead() -> Any? { stored }
    func _patchWrite(_ newValue: Any) {
        if let v = _patchCoerceScalar(newValue, to: Value.self) { stored = v }
    }
}

final class BugHuntSDKRound1Tests: XCTestCase {

    // MARK: #3 — @Published collection in .publisher storage marshals its live rows

    @MainActor
    func testPublishedCollectionInPublisherStorageMarshalsRows() {
        let vm = _R1FeedVM(rows: [_R1Item(id: 1, title: "A"), _R1Item(id: 2, title: "B")])
        XCTAssertEqual(vm.items.count, 2, "precondition: the VM holds 2 rows")
        let e = PatchInstanceInputs.extract(from: _R1FeedView(vm: vm))
        // The populated `.publisher`-state collection must marshal as a real array —
        // NOT an empty list (the old skip-the-field bug rendered ZERO rows).
        XCTAssertEqual(e.json,
            #"{"vm":{"items":[{"id":1,"title":"A"},{"id":2,"title":"B"}]}}"#,
            "a @Published .publisher collection must marshal its live rows: \(e.json)")
    }

    @MainActor
    func testUnwrapPublishedReadsPublisherCurrentValue() {
        let vm = _R1FeedVM(rows: [_R1Item(id: 7, title: "Z")])
        let m = Mirror(reflecting: vm)
        guard let published = m.children.first(where: { $0.label == "_items" })?.value else {
            return XCTFail("no _items backing")
        }
        XCTAssertTrue(PatchValueEncoder.isPublished(published))
        let unwrapped = PatchValueEncoder.unwrapPublished(published)
        let arr = unwrapped as? [_R1Item]
        XCTAssertEqual(arr?.count, 1, "unwrapPublished reaches the .publisher subject's currentValue")
        XCTAssertEqual(arr?.first?.id, 7)
    }

    // MARK: #46 — CustomStringConvertible enum marshals the TRUE case name

    func testCustomStringConvertibleEnumMarshalsCaseName() {
        // .archived (custom description "Status.archived") must marshal as case "archived",
        // and .active (rawValue "ACTIVE", description "Status.ACTIVE") as case "active".
        XCTAssertEqual(PatchValueEncoder.enumCaseName(_R1Status.archived), "archived")
        XCTAssertEqual(PatchValueEncoder.enumCaseName(_R1Status.active), "active")
        XCTAssertEqual(PatchValueEncoder.encode(_R1Status.archived), #"{"case":"archived"}"#,
                       "must use the runtime case name, not the custom description")
        XCTAssertEqual(PatchValueEncoder.encode(_R1Status.active), #"{"case":"active"}"#)
        // A non-enum returns nil (safe fallback).
        XCTAssertNil(PatchValueEncoder.enumCaseName(42))
        XCTAssertNil(PatchValueEncoder.enumCaseName("hi"))
    }

    // MARK: #47/#70 — a source field literally named `_count` marshals under its raw name

    func testLeadingUnderscoreFieldMarshalsUnderRawName() {
        let frag = PatchValueEncoder.encode(_R1Underscored(_count: 5, title: "T"))
        XCTAssertNotNil(frag)
        // The guest scans the RAW name `_count`, so it MUST appear in the JSON.
        XCTAssertTrue(frag?.contains(#""_count":5"#) ?? false,
                      "the raw underscored name must be present for the guest scanner: \(frag ?? "nil")")
        XCTAssertTrue(frag?.contains(#""title":"T""#) ?? false)
    }

    // MARK: #51 — fixed-width integral @State write-back coerces (Int64/UInt/Int32)

    @MainActor
    func testCoerceScalarWidensToFixedWidthIntegers() {
        // The guest emits an integral number → `unbox` collapses to Int → the wrapper's
        // concrete Value may be any width. Coercion must land all of these (was nil → no write).
        XCTAssertEqual(_patchCoerceScalar(Int(5), to: Int64.self), Int64(5))
        XCTAssertEqual(_patchCoerceScalar(Int(5), to: Int32.self), Int32(5))
        XCTAssertEqual(_patchCoerceScalar(Int(5), to: Int16.self), Int16(5))
        XCTAssertEqual(_patchCoerceScalar(Int(5), to: UInt.self), UInt(5))
        XCTAssertEqual(_patchCoerceScalar(Int(5), to: UInt64.self), UInt64(5))
        XCTAssertEqual(_patchCoerceScalar(Int(5), to: UInt32.self), UInt32(5))
        // The previously-broken case: `Int as? Int64` was nil and the widening branch
        // only targeted Double/CGFloat/Float/Int, so Int64/UInt/Int32 returned nil (no write).
        XCTAssertNotNil(_patchCoerceScalar(Int(5), to: Int64.self),
                        "Int→Int64 coercion must not return nil (was the silent-drop bug)")
        // A through-the-wrapper round-trip writes the value (no silent drop).
        let box = _R1IntBox<Int64>(0)
        box._patchWrite(Int(42))
        XCTAssertEqual(box.stored, 42, "Int→Int64 write must land, not be dropped")
    }

    // MARK: #73/#74 — large Int (> 2^53) survives the write-back / merge

    @MainActor
    func testLargeIntWritebackPreservesPrecision() {
        // 2^53 + 1 — a snowflake id / epoch-ms. The Double round-trip would collapse it
        // to …992. The write-back path (unbox + coerce) must keep it exact.
        let big = 9_007_199_254_740_993
        let box = _R1IntBox<Int>(0)
        let wb = PatchScalarWriteback(key: "id", wrapper: box)
        PatchedBodyHost.applyWritebacks([wb], newStateJSON: "{\"id\":\(big)}")
        XCTAssertEqual(box.stored, big, "large Int write-back must not lose precision")
    }

    func testLargeIntSurvivesFlatJSONMerge() {
        let big = 9_007_199_254_740_993
        let merged = PatchFlatJSON.merge(base: "{\"id\":\(big)}", override: "{\"other\":1}")
        // The merge must NOT round the id to a Double (…992) nor emit a `.0` the guest rejects.
        XCTAssertTrue(merged.contains("\"id\":\(big)"),
                      "large Int must survive the merge exactly: \(merged)")
        XCTAssertFalse(merged.contains("\(big).0"), "must not emit a trailing .0")
    }

    // MARK: #23 — Date inside a Decodable @State struct round-trips (1970, not 2001)

    @MainActor
    func testDateInDecodableStructRoundTripsViaSecondsSince1970() {
        struct Filters: Codable, Equatable { var max: Int; var when: Date }
        let original = Filters(max: 1, when: Date(timeIntervalSince1970: 1000))
        // The encoder marshals `when` as epoch-1970 seconds (1000).
        let frag = PatchValueEncoder.encode(original)
        XCTAssertEqual(frag, #"{"max":1,"when":1000}"#, "encode side uses timeIntervalSince1970")
        // The decode side MUST interpret 1000 as seconds-since-1970, not since-2001.
        let decoded = _patchDecodeJSON(Filters.self, from: frag!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.when.timeIntervalSince1970 ?? -1, 1000, accuracy: 0.001,
                       "Date must NOT be corrupted by ~31 years (epoch-2001 reference)")
        XCTAssertEqual(decoded, original)
    }

    // MARK: #49/#52 — dual-owned state reconciliation (native change wins over stale guest)

    @MainActor
    func testReconcileDropsGuestOverrideWhenNativeChangedField() {
        // Guest last wrote {"soundOn":true} with baseline {"soundOn":true}. Native then set
        // soundOn=false (currentProps). Reconcile must DROP the stale guest override so the
        // live native value (false) wins, not the stale true.
        let effective = PatchedBodyHost.reconcileGuestOverride(
            guestState: #"{"soundOn":true}"#,
            baseline: #"{"soundOn":true}"#,
            currentProps: #"{"soundOn":false}"#)
        let merged = PatchFlatJSON.merge(base: #"{"soundOn":false}"#, override: effective)
        XCTAssertTrue(merged.contains(#""soundOn":false"#),
                      "native change must win over the stale guest value: \(merged) (effective: \(effective))")
    }

    @MainActor
    func testReconcileKeepsGuestOverrideWhenNativeUnchanged() {
        // Only the guest touched `step` (baseline == currentProps). The guest override stays.
        let effective = PatchedBodyHost.reconcileGuestOverride(
            guestState: #"{"step":3}"#,
            baseline: #"{"step":0}"#,
            currentProps: #"{"step":0}"#)
        XCTAssertTrue(effective.contains(#""step":3"#),
                      "a guest-only change must be preserved: \(effective)")
    }

    @MainActor
    func testReconcileWithNoBaselineKeepsOverride() {
        // No dispatch yet → no baseline. The override (whatever it is) is preserved verbatim.
        let effective = PatchedBodyHost.reconcileGuestOverride(
            guestState: #"{"x":1}"#, baseline: "", currentProps: #"{"x":9}"#)
        XCTAssertEqual(effective, #"{"x":1}"#)
    }
}

#endif
