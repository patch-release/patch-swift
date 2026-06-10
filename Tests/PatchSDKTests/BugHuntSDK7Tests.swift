import XCTest
import Foundation
import PatchViewIR
@testable import PatchSDK

/// Regression tests for SDK bug-hunt #7.
///
/// #1 (P1) — The ViewNode JSON wire codecs could not carry a NON-FINITE Double.
/// `.frame(maxWidth: .infinity)` is one of the single most common SwiftUI layout
/// idioms, so its IR (`.frame(width: .infinity, …)`) flows through `EmbeddedJSON`
/// (T0 embedded guest) and `ViewNodeWire` (T2 Foundation guest). Before the fix:
///   * `EmbeddedJSON.number(.infinity)` emitted the BARE token `inf` — INVALID
///     JSON the host `JSONDecoder` rejects, collapsing the whole view to the
///     error stub.
///   * `ViewNodeWire.encode` (default `JSONEncoder`) THREW on a non-finite Double,
///     so the T2 body failed to emit at all.
/// The fix carries non-finite Doubles as agreed STRING tokens ("inf"/"-inf"/"nan")
/// on BOTH the embedded emitter and Foundation's non-conforming-float strategy, so
/// both guest tiers round-trip identically back to `.infinity` / NaN.
final class BugHuntSDK7Tests: XCTestCase {

    // MARK: #1 — non-finite Double survives the ViewNode wire boundary

    /// The canonical trigger: `.frame(maxWidth: .infinity)`. Both the embedded
    /// (Foundation-free) emitter AND the Foundation encoder must produce bytes the
    /// host decodes back to a tree EQUAL to the original (infinity preserved).
    func testFrameInfinityRoundTripsThroughBothWireCodecs() throws {
        let tree = ViewNode(
            .text("Fills width"),
            modifiers: [.frame(width: .infinity, height: nil, alignment: .center)])
        let emission = BodyEmission(root: tree, computeCoverage: false,
                                    schemaVersion: PatchViewIRSchema.version)

        // T2 (Foundation) path: must NOT throw, and must round-trip.
        let t2Bytes = try ViewNodeWire.encode(emission)
        let t2Back = try ViewNodeWire.decode(t2Bytes)
        XCTAssertEqual(t2Back.root, tree, "Foundation wire preserves .frame(.infinity)")

        // T0 (embedded) path: emits valid JSON the SAME host decoder reads.
        let t0Bytes = EmbeddedJSON.encode(emission)
        // The emitted bytes must be syntactically valid JSON (not the bare `inf`).
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: Data(t0Bytes)),
            "embedded emitter must produce VALID JSON for a non-finite Double")
        let t0Back = try ViewNodeWire.decode(t0Bytes)
        XCTAssertEqual(t0Back.root, tree, "embedded wire preserves .frame(.infinity)")

        // Both tiers decode to the SAME tree (the embedded emitter writes `null`
        // for absent Optionals while Foundation omits them — a pre-existing,
        // harmless divergence — but the decoded trees are equal, which is the
        // contract that matters).
        XCTAssertEqual(t0Back.root, t2Back.root,
                       "T0 and T2 decode to the same tree")
    }

    /// Negative infinity (e.g. a frame/offset value) also round-trips.
    func testNegativeInfinityRoundTrips() throws {
        let tree = ViewNode(.spacer(minLength: -.infinity))
        let emission = BodyEmission(root: tree, computeCoverage: false)
        let back = try ViewNodeWire.decode(EmbeddedJSON.encode(emission))
        guard case .spacer(let m) = back.root.kind else {
            return XCTFail("expected spacer, got \(back.root.kind)")
        }
        XCTAssertEqual(m, -.infinity)
    }

    /// NaN round-trips to NaN (NaN != NaN, so assert via `.isNaN`).
    func testNaNRoundTrips() throws {
        let tree = ViewNode(.slider(value: .nan, min: 0, max: 1, step: nil,
                                    event: EventID("x")))
        let emission = BodyEmission(root: tree, computeCoverage: false)
        // Both codecs produce valid JSON and decode back to a NaN slider value.
        for bytes in [EmbeddedJSON.encode(emission), try ViewNodeWire.encode(emission)] {
            let back = try ViewNodeWire.decode(bytes)
            guard case .slider(let v, _, _, _, _) = back.root.kind else {
                return XCTFail("expected slider")
            }
            XCTAssertTrue(v.isNaN, "NaN survives the wire as NaN")
        }
    }

    /// A non-finite value in a DISPATCH event payload (`IRValue.double`) — the
    /// other Double-carrying boundary — also survives encode/decode.
    func testDispatchEventInfinityPayloadRoundTrips() throws {
        let bytes = try ViewNodeWire.encodeDispatch(
            state: "{}",
            event: DispatchEvent(event: EventID("seek"), value: .double(.infinity)))
        // Re-decode the envelope (it is a plain {state,event} object).
        struct Env: Codable { var state: String; var event: DispatchEvent }
        let dec = JSONDecoder()
        dec.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let env = try dec.decode(Env.self, from: Data(bytes))
        guard case .double(let d) = env.event.value else {
            return XCTFail("expected .double payload, got \(env.event.value)")
        }
        XCTAssertEqual(d, .infinity)
    }

    /// Guard against regression of the FINITE fast-path: ordinary numbers still
    /// emit as bare JSON numbers (not quoted strings), so existing consumers and
    /// the integer/fractional formatting are unchanged.
    func testFiniteNumbersStillEmitAsBareJSONNumbers() throws {
        let tree = ViewNode(.text("x"),
                            modifiers: [.frame(width: 320, height: 12.5, alignment: nil)])
        let json = String(decoding: EmbeddedJSON.encode(
            BodyEmission(root: tree, computeCoverage: false)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"width\":320"), "integral width is a bare int: \(json)")
        XCTAssertTrue(json.contains("\"height\":12.5"), "fractional height is a bare number: \(json)")
        XCTAssertFalse(json.contains("\"inf\""), "no stray non-finite token for finite input")
    }

    // MARK: #2 (P2) — PatchView glue checked dispatch on the PRIMARY module only
    //
    // `patchView(...)` decided whether the view is interactive by checking whether
    // the `dispatch` export exists. The OLD check was `withRuntime { $0.hasFunction
    // (dispatchExport) }`, which inspects ONLY the primary module — but the actual
    // `dispatch` call routes via `callPacked` → `withRuntime(forFunction:)`, which
    // reaches an ADDITIVE PMOD sub-module too. So a real-source/SwiftUI PMOD whose
    // `dispatch` lives in a sub-module rendered READ-ONLY even though dispatching
    // would have worked. The fix uses the facade's `hasFunction`, which (as proven
    // here) sees an additive-only export.

    /// The facade's `hasFunction` (the path the glue now uses) sees an export that
    /// exists ONLY in an additive PMOD sub-module; a primary-only probe would miss
    /// it. This is the exact distinction the read-only/interactive decision turned on.
    func testFacadeHasFunctionSeesAdditiveOnlyExport() throws {
        let primary = Self.minimalMemoryModule(extraExport: false)   // no `extra_only`
        let additive = Self.minimalMemoryModule(extraExport: true)   // exports `extra_only`
        let container = PatchModuleContainer.encode([primary, additive])

        let patch = Patch()
        try patch.activate(bytes: container)

        // The facade routes across BOTH modules — the glue's new dispatch check.
        XCTAssertTrue(patch.hasFunction("extra_only"),
                      "facade.hasFunction must see an additive-only export (the fixed glue path)")

        // The OLD primary-only probe (`withRuntime { $0.hasFunction }`) would NOT
        // see it — assert that to pin exactly what the fix changed.
        let primaryOnly = (try? patch.withRuntime { $0.hasFunction("extra_only") }) ?? false
        XCTAssertFalse(primaryOnly,
                       "primary-only probe misses the additive export — the old read-only bug")
    }

    /// A minimal valid WASM module exporting `memory` + `patch_malloc`, optionally
    /// also `extra_only` (so the two roles differ by exactly one export). Hand-
    /// assembled via `wat2wasm` and kept literal so the test needs no toolchain.
    private static func minimalMemoryModule(extraExport: Bool) -> [UInt8] {
        if extraExport {
            // (module (memory (export "memory") 1)
            //   (func (export "patch_malloc") (param i32)(result i32) i32.const 0)
            //   (func (export "extra_only") (result i32) i32.const 7))
            return [
                0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0a, 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f,
                0x60, 0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x01, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x26,
                0x03, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x0c, 0x70, 0x61, 0x74, 0x63, 0x68,
                0x5f, 0x6d, 0x61, 0x6c, 0x6c, 0x6f, 0x63, 0x00, 0x00, 0x0a, 0x65, 0x78, 0x74, 0x72, 0x61, 0x5f,
                0x6f, 0x6e, 0x6c, 0x79, 0x00, 0x01, 0x0a, 0x0b, 0x02, 0x04, 0x00, 0x41, 0x00, 0x0b, 0x04, 0x00,
                0x41, 0x07, 0x0b,
            ]
        }
        // (module (memory (export "memory") 1)
        //   (func (export "patch_malloc") (param i32)(result i32) i32.const 0))
        return [
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
            0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x19, 0x02, 0x06, 0x6d, 0x65, 0x6d,
            0x6f, 0x72, 0x79, 0x02, 0x00, 0x0c, 0x70, 0x61, 0x74, 0x63, 0x68, 0x5f, 0x6d, 0x61, 0x6c, 0x6c,
            0x6f, 0x63, 0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x00, 0x0b,
        ]
    }
}
