// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import Compiler

/// Tests for the `PMOD` multi-module container — the sound (Option B) way to ship a
/// default module + an additive real-source/SwiftUI module as ONE artifact. These are
/// pure value-type tests; no toolchain needed.
final class PatchModuleContainerTests: XCTestCase {

    /// Encode then decode round-trips the exact module bytes, in order.
    func testRoundTrip() throws {
        let a: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 1, 2, 3]
        let b: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 9, 8, 7, 6, 5]
        let c: [UInt8] = [0x00, 0x61, 0x73, 0x6d]
        let blob = PatchModuleContainer.encode([a, b, c])
        XCTAssertTrue(PatchModuleContainer.isContainer(blob), "encoded blob must carry the PMOD magic")
        let parts = try XCTUnwrap(PatchModuleContainer.decode(blob))
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], a)
        XCTAssertEqual(parts[1], b)
        XCTAssertEqual(parts[2], c)
    }

    /// A single module still round-trips (the degenerate 1-module container).
    func testSingleModuleRoundTrip() throws {
        let only: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 42]
        let blob = PatchModuleContainer.encode([only])
        let parts = try XCTUnwrap(PatchModuleContainer.decode(blob))
        XCTAssertEqual(parts, [only])
    }

    /// Back-compat: a RAW wasm module (`\0asm`) is NOT a container and decode returns
    /// nil — the SDK then treats it as a single module (the unchanged legacy path).
    func testRawWasmIsNotContainer() {
        let rawWasm: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
        XCTAssertFalse(PatchModuleContainer.isContainer(rawWasm))
        XCTAssertNil(PatchModuleContainer.decode(rawWasm))
    }

    /// A truncated/corrupt container (declared length runs past the end) decodes to nil
    /// rather than crashing — callers fall back to treating it as a raw module.
    func testTruncatedContainerIsRejected() {
        // magic + version + count=2 + reserved, then a length that exceeds the buffer.
        var blob = PatchModuleContainer.magic + [PatchModuleContainer.version, 2, 0, 0]
        blob += [0xFF, 0xFF, 0xFF, 0x7F]   // declares ~2GB module — past the end
        XCTAssertTrue(PatchModuleContainer.isContainer(blob))
        XCTAssertNil(PatchModuleContainer.decode(blob), "a truncated container must decode to nil")
    }

    /// The container magic can never collide with the wasm magic (first byte differs).
    func testMagicDistinctFromWasm() {
        XCTAssertNotEqual(PatchModuleContainer.magic, WasmModuleMerger.wasmMagic)
        XCTAssertNotEqual(PatchModuleContainer.magic.first, WasmModuleMerger.wasmMagic.first)
    }
}
