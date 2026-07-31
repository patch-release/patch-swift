// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import ViewNodeIR

/// Wire-encoding drift guard for non-finite Doubles.
///
/// Three encoders have to agree on how a non-finite Double reaches the renderer:
///
/// 1. the **T0 (embedded) guest** — `CodeGenerator/GuestIR/JSONEmit.swifttext`,
///    a hand-written emitter compiled into the WASM module;
/// 2. the **T2 (Foundation) guest** — Foundation's `JSONEncoder`, configured by
///    `ABI.makeEncoder()` with `nonConformingFloatEncodingStrategy`;
/// 3. the **host decoder** — `ABI.makeDecoder()`, with the matching
///    `.convertFromString` strategy.
///
/// They did not agree. (1) clamped non-finite values to
/// `±greatestFiniteMagnitude` (and `NaN` to `0`) while (2) and (3) used the
/// string sentinels `"inf"` / `"-inf"` / `"nan"` — even though `ABI.swift`
/// documents the encoder as carrying non-finite doubles "as the same string
/// tokens the embedded emitter uses". So the SAME view lowered through the two
/// guest tiers produced different trees for the same input.
///
/// Scope, stated precisely: this is NOT the `.frame(maxWidth: .infinity)` path.
/// That idiom lowers to `IRLength.infinity`, a structured enum case emitted as
/// `"infinity"` (see `emitLength`), and never touches `number(Double)`. The
/// affected path is any of the ~143 `number(_:)` call sites reached by a
/// COMPUTED Double that happens to be non-finite — a `cornerRadius` from a
/// division by zero, a host-resolved numeric token, an `opacity` from a NaN
/// ratio. Rarer than a frame modifier, but it is exactly the case where the two
/// guest tiers silently rendered differently.
///
/// These tests pin the sentinel encoding so the tiers can't silently diverge again.
final class NonFiniteWireEncodingTests: XCTestCase {

    private func emit(_ d: Double) -> String {
        var out = JSONOut()
        out.number(d)
        return String(decoding: out.bytes, as: UTF8.self)
    }

    // MARK: - The sentinel encoding

    func testPositiveInfinityEmitsSentinel() {
        XCTAssertEqual(emit(.infinity), "\"\(JSONNonFinite.positiveInfinity)\"")
    }

    func testNegativeInfinityEmitsSentinel() {
        XCTAssertEqual(emit(-.infinity), "\"\(JSONNonFinite.negativeInfinity)\"")
    }

    func testNaNEmitsSentinel() {
        XCTAssertEqual(emit(.nan), "\"\(JSONNonFinite.nan)\"")
    }

    func testNonFiniteIsNeverClampedToAFiniteNumber() {
        // The regression: `1.7976931348623157e+308` must never appear on the wire
        // as a stand-in for infinity, and NaN must never become 0.
        for d in [Double.infinity, -.infinity, .nan] {
            let out = emit(d)
            XCTAssertFalse(out.contains("1.797"), "non-finite \(d) was clamped: \(out)")
            XCTAssertTrue(out.hasPrefix("\""), "non-finite \(d) must be a string sentinel: \(out)")
        }
        XCTAssertNotEqual(emit(.nan), "0")
    }

    // MARK: - Sentinel values must match the SDK's `PatchViewIR.JSONNonFinite`

    /// The SDK vendors its own copy of these constants. They are the wire contract:
    /// if the two ever disagree the host decoder silently fails to convert and the
    /// whole view collapses to the error stub.
    func testSentinelValuesMatchTheSDKContract() {
        XCTAssertEqual(JSONNonFinite.positiveInfinity, "inf")
        XCTAssertEqual(JSONNonFinite.negativeInfinity, "-inf")
        XCTAssertEqual(JSONNonFinite.nan, "nan")
    }

    // MARK: - Finite values are untouched

    func testFiniteEncodingIsUnchanged() {
        XCTAssertEqual(emit(0), "0")
        XCTAssertEqual(emit(16), "16")
        XCTAssertEqual(emit(-8), "-8")
        XCTAssertEqual(emit(12.5), "12.5")
        XCTAssertEqual(emit(0.5), "0.5")
    }

    func testLargeFiniteValuesStillEmitAsNumbers() {
        // greatestFiniteMagnitude is a legitimate finite value — it must keep
        // emitting as a NUMBER, not get mistaken for the old infinity sentinel.
        let out = emit(.greatestFiniteMagnitude)
        XCTAssertFalse(out.hasPrefix("\""), "a finite value must not become a string: \(out)")
    }

    // MARK: - End-to-end through a real Double-valued modifier

    func testComputedNonFiniteModifierRidesTheWireAsASentinel() {
        // A computed radius that came out infinite — the real shape of this bug.
        let node = N.text("Hi").cornerRadius(.infinity)
        let json = String(decoding: EmbeddedJSON.encode(BodyEmission(root: node)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"\(JSONNonFinite.positiveInfinity)\""),
                      "a non-finite modifier value must ride the wire as a sentinel: \(json)")
        XCTAssertFalse(json.contains("1.797"),
                       "a non-finite modifier value must not be clamped: \(json)")
    }

    /// `.frame(maxWidth: .infinity)` takes the STRUCTURED path and must be
    /// unaffected by this change — pinned so the two paths don't get conflated.
    func testFlexFrameInfinityStillUsesTheStructuredCase() {
        let node = N.text("Hi").flexFrame(maxWidth: .infinity)
        let json = String(decoding: EmbeddedJSON.encode(BodyEmission(root: node)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"infinity\""), json)
    }
}
