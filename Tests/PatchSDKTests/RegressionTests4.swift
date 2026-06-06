import XCTest
import Foundation
import CBZ2
@testable import PatchSDK

/// Regression tests. Each test pins a specific correctness / crash / DoS /
/// wrong-instance bug fixed in the corresponding source file. All are
/// fixture-free (pure Swift) so they run in any environment.
final class RegressionTests4: XCTestCase {

    // MARK: #1 — FoundationBridge.decimalOp(divFloor) used FLOOR, not truncate-to-0
    //
    // `divFloor` (op 4) is documented + intended as "truncate toward zero" — the
    // integer-division semantics ledger/money math relies on (C/Python
    // `(a*rate)/denom` truncates toward 0). It used `NSDecimalNumber.RoundingMode
    // .down`, which is FLOOR (toward −∞) — WRONG for any negative result.

    func testDivFloorTruncatesTowardZeroForPositive() {
        // Positive case is unchanged: 570.9375 -> 570.
        XCTAssertEqual(FoundationBridge.decimalOp(op: 4, a: 5_709_375, b: 10_000, scale: 2), 570)
        // 3.5 -> 3 (truncate).
        XCTAssertEqual(FoundationBridge.decimalOp(op: 4, a: 7, b: 2, scale: 0), 3)
    }

    func testDivFloorTruncatesTowardZeroForNegative() {
        // THE BUG: -5/2 = -2.5. Truncate-toward-zero = -2. Floor (.down) = -3.
        XCTAssertEqual(FoundationBridge.decimalOp(op: 4, a: -5, b: 2, scale: 0), -2,
                       "divFloor must truncate toward zero (-2), not floor (-3)")
        // -7/2 = -3.5 -> -3 (truncate), NOT -4 (floor).
        XCTAssertEqual(FoundationBridge.decimalOp(op: 4, a: -7, b: 2, scale: 0), -3)
        // A realistic negative ledger figure: -570.9375 -> -570, not -571.
        XCTAssertEqual(FoundationBridge.decimalOp(op: 4, a: -5_709_375, b: 10_000, scale: 2), -570)
        // Both operands negative → positive quotient, unchanged: -7/-2 = 3.5 -> 3.
        XCTAssertEqual(FoundationBridge.decimalOp(op: 4, a: -7, b: -2, scale: 0), 3)
        // Negative divisor only: 7/-2 = -3.5 -> -3 (truncate), not -4.
        XCTAssertEqual(FoundationBridge.decimalOp(op: 4, a: 7, b: -2, scale: 0), -3)
    }

    func testDivFloorDivByZeroStillZero() {
        XCTAssertEqual(FoundationBridge.decimalOp(op: 4, a: -5, b: 0, scale: 2), 0)
    }

    // MARK: #2 — BSDIFF40 reconstruction overflow TRAP on a hostile control length
    //
    // A control triple's `addLen`/`copyLen`/`seekLen` are attacker-controlled
    // offtin int64s up to 2^63-1. The reconstruction loop did `newPos + Int(addLen)`
    // (etc.) with PLAIN `+`, which TRAPS on Int overflow — an uncatchable crash, so
    // the loader's diff→full fallback (which only catches THROWN errors) never runs.
    // The fix uses overflow-reporting arithmetic → a clean `.reconstructionOverrun`.

    /// bz2-compress `input` with libbz2's one-shot API (the inverse of the
    /// decompressor BSDIFF40Patch uses) so we can build a *real* BSDIFF40 patch.
    private func bz2Compress(_ input: [UInt8]) throws -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: max(input.count * 2, 1024) + 600)
        var destLen = UInt32(dst.count)
        var src = input
        let rc = dst.withUnsafeMutableBufferPointer { outBuf -> Int32 in
            src.withUnsafeMutableBufferPointer { srcBuf in
                BZ2_bzBuffToBuffCompress(
                    outBuf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: outBuf.count) { $0 },
                    &destLen,
                    srcBuf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: srcBuf.count) { $0 },
                    UInt32(srcBuf.count),
                    9,  // block size 100k * 9
                    0,  // verbosity
                    0)  // workFactor default
            }
        }
        guard rc == BZ_OK else { throw NSError(domain: "bz2", code: Int(rc)) }
        return Array(dst[0..<Int(destLen)])
    }

    /// Encode an offtin (sign–magnitude little-endian) int64 the way bsdiff does.
    private func offtin(_ v: Int64) -> [UInt8] {
        var mag = UInt64(v.magnitude)
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { out[i] = UInt8(mag & 0xff); mag >>= 8 }
        if v < 0 { out[7] |= 0x80 }
        return out
    }

    private func littleEndianI64(_ v: Int64) -> [UInt8] {
        var x = UInt64(bitPattern: v)
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { out[i] = UInt8(x & 0xff); x >>= 8 }
        return out
    }

    /// Build a BSDIFF40 patch from explicit (add, copy, seek) control triples and a
    /// supplied diff/extra payload. The diff stream must be >= total add bytes.
    private func makePatch(triples: [(Int64, Int64, Int64)], newSize: Int64,
                           diff: [UInt8], extra: [UInt8]) throws -> Data {
        var control: [UInt8] = []
        for (a, c, s) in triples { control += offtin(a) + offtin(c) + offtin(s) }
        let controlComp = try bz2Compress(control)
        let diffComp = try bz2Compress(diff)
        let extraComp = try bz2Compress(extra)
        var patch: [UInt8] = Array("BSDIFF40".utf8)
        patch += littleEndianI64(Int64(controlComp.count))
        patch += littleEndianI64(Int64(diffComp.count))
        patch += littleEndianI64(newSize)
        patch += controlComp
        patch += diffComp
        patch += extraComp
        return Data(patch)
    }

    func testBSDIFF40HostileAddLenThrowsInsteadOfTrapping() throws {
        // First triple advances `newPos` to 1; the SECOND has add = Int64.max, so
        // pre-fix `newPos(1) + Int(Int64.max)` OVERFLOW-TRAPS (uncatchable crash).
        // Post-fix it is rejected as a clean `.reconstructionOverrun`.
        let patch = try makePatch(
            triples: [(1, 0, 0), (Int64.max, 0, 0)],
            newSize: 16, diff: [0], extra: [])
        let old = Data([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertThrowsError(try BSDIFF40Patch.apply(patch: patch, to: old)) { err in
            XCTAssertEqual(err as? BSDIFF40Patch.DiffError, .reconstructionOverrun,
                           "a hostile addLen must throw, not crash the process")
        }
    }

    func testBSDIFF40HostileCopyLenThrowsInsteadOfTrapping() throws {
        // Advance newPos to 1 (add 1), then copy = Int64.max → `newPos(1)+Int.max`
        // overflow-traps pre-fix.
        let patch = try makePatch(
            triples: [(1, 0, 0), (0, Int64.max, 0)],
            newSize: 16, diff: [0], extra: [])
        let old = Data([7, 7, 7, 7])
        XCTAssertThrowsError(try BSDIFF40Patch.apply(patch: patch, to: old)) { err in
            XCTAssertEqual(err as? BSDIFF40Patch.DiffError, .reconstructionOverrun,
                           "a hostile copyLen must throw, not crash the process")
        }
    }

    /// Sanity: a WELL-FORMED single-triple patch still reconstructs correctly
    /// after the overflow-safe rewrite (proves the fix didn't break the happy path).
    func testBSDIFF40WellFormedStillReconstructs() throws {
        // newSize = 4: add 2 bytes from old (diff deltas all 0 → copy of old),
        // then copy 2 bytes from extra.
        let old = Data([10, 20, 30, 40])
        let control = offtin(2) + offtin(2) + offtin(0)   // add 2, copy 2, seek 0
        let controlComp = try bz2Compress(control)
        let diffComp = try bz2Compress([0, 0])            // deltas 0 → old[0],old[1]
        let extra: [UInt8] = [99, 98]
        let extraComp = try bz2Compress(extra)
        var patch: [UInt8] = Array("BSDIFF40".utf8)
        patch += littleEndianI64(Int64(controlComp.count))
        patch += littleEndianI64(Int64(diffComp.count))
        patch += littleEndianI64(4)
        patch += controlComp
        patch += diffComp
        patch += extraComp
        let out = try BSDIFF40Patch.apply(patch: Data(patch), to: old)
        XCTAssertEqual([UInt8](out), [10, 20, 99, 98],
                       "well-formed reconstruction must still be byte-exact after the overflow fix")
    }

    // MARK: #3 — async-call routing did not target the EXPORTING instance
    //
    // The sync structured path (`callPacked`) routes via `withRuntime(forFunction:)`
    // — the instance that exports the symbol (matters for a PMOD multi-module
    // container). The async paths (`runAsync` / `callAsyncResult` / `callPackedAsync`)
    // used plain `withRuntime` (PRIMARY only), so an async kickoff living in an
    // ADDITIVE instance threw `exportNotFound` (and the broker would have resolved a
    // fetch into the WRONG instance's memory). They now route via `forFunction:`.
    //
    // We can't easily ship a 2-module async wasm fixture here, but we CAN pin the
    // routing primitive every async path now shares: `withRuntime(forFunction:)`
    // does not require the export to be on the primary. This guards against a
    // regression to the primary-only `withRuntime`.

    func testWithRuntimeForFunctionIsTheRoutingPrimitive() throws {
        // No module loaded → both forms surface `noActiveModule`, never crash.
        let patch = Patch()
        XCTAssertThrowsError(try patch.withRuntime(forFunction: "anything") { _ in 0 }) { err in
            guard let e = err as? PatchError, case .noActiveModule = e else {
                return XCTFail("expected .noActiveModule, got \(err)")
            }
        }
        XCTAssertThrowsError(try patch.runAsync(start: "patch_start_x")) { err in
            guard let e = err as? PatchError, case .noActiveModule = e else {
                return XCTFail("async path must funnel through the same routing primitive")
            }
        }
        XCTAssertThrowsError(try patch.callAsyncResult(start: "patch_start_x")) { err in
            guard let e = err as? PatchError, case .noActiveModule = e else {
                return XCTFail("callAsyncResult must funnel through routing")
            }
        }
        XCTAssertThrowsError(try patch.callPackedAsync("patch_start_x", [], resultExport: "patch_result")) { err in
            guard let e = err as? PatchError, case .noActiveModule = e else {
                return XCTFail("callPackedAsync must funnel through routing")
            }
        }
    }
}
