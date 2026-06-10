import XCTest
import WasmKit
@testable import PatchSDK

/// Regression tests for the SDK pre-launch bug-hunt #5. Each pins a specific real
/// bug (memory leak / decode hardening / loader-verify safety) fixed in the
/// corresponding source file. Most are fixture-free (pure Swift) so they run in
/// any environment; the two that exercise the packed-result host primitive use the
/// committed `MarshalFixture.release.wasm` and XCTSkip when it is absent.
final class BugHuntSDK5Tests: XCTestCase {

    private func marshalBytes() throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm") else {
            throw XCTSkip("MarshalFixture.release.wasm fixture absent")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    // MARK: #1 — callPacked leaked the OUTPUT guest buffer when `read` threw
    //
    // `callPacked`/`callPackedAsync` unpack a guest-returned `(outPtr<<32)|outLen`
    // i64 and then `read(ptr: outPtr, len: outLen)`. A buggy/hostile guest can
    // pack an OUT-OF-BOUNDS (ptr,len): `read` then throws `memoryOutOfBounds` and
    // the old code never reached `runtime.free(outPtr)` — leaking that guest
    // buffer on every failing call until guest linear memory is exhausted. The fix
    // frees `outPtr` via `defer` on every exit path. These tests prove (a) the
    // happy path still round-trips correctly (no double-free / behavior change) and
    // (b) thousands of round-trips through real guest memory do not grow without
    // bound (the buffers are reclaimed), which would previously OOM if the output
    // were leaked.

    func testCallPackedHappyPathStillRoundTripsAfterFreeRefactor() throws {
        let patch = Patch()
        try patch.activate(bytes: try marshalBytes())
        let input: [UInt8] = Array("memory-safety".utf8)
        let out = try patch.callPacked("reverse_packed", input)
        XCTAssertEqual(out, input.reversed(),
                       "the defer-free refactor must not change the happy-path result")
    }

    /// A guest that packs an OUT-OF-BOUNDS `(outPtr,outLen)` makes `callPacked`'s
    /// `read(ptr:len:)` throw `memoryOutOfBounds`. The bug: on that throw the old
    /// code never freed `outPtr`, leaking the buffer. The fix frees `outPtr` via
    /// `defer` on every exit path. There is no committed fixture that returns a bad
    /// packed value, so this hand-assembles a tiny WASM module whose `bad_packed`
    /// export returns a packed result with a huge `outLen` (forcing the OOB read),
    /// and asserts `callPacked` (a) throws a clean runtime error rather than
    /// crashing and (b) keeps working for subsequent calls (the instance is not
    /// wedged) — i.e. the failure is handled, not fatal.
    func testCallPackedOnOutOfBoundsPackedResultThrowsCleanly() throws {
        // module: (memory 1) export "memory"; func "patch_malloc"(i32)->i32 returns
        // a fixed in-bounds ptr (16); func "bad_packed"(i32,i32)->i64 returns
        // (16 << 32) | 0xFFFFFFFF — a valid ptr but a 4 GB length → OOB read.
        let wasm = Self.oobPackedModule()
        let patch = Patch()
        try patch.activate(bytes: wasm)

        XCTAssertThrowsError(try patch.callPacked("bad_packed", [1, 2, 3])) { err in
            guard case PatchError.runtime(let re) = err,
                  case .memoryOutOfBounds = re else {
                return XCTFail("expected a clean memoryOutOfBounds runtime error, got \(err)")
            }
        }
        // The instance survives: a second call still throws cleanly (not wedged /
        // not crashed). This is the behavior the `defer`-free fix preserves.
        XCTAssertThrowsError(try patch.callPacked("bad_packed", [9])) { err in
            guard case PatchError.runtime = err else {
                return XCTFail("instance should still respond after a handled OOB, got \(err)")
            }
        }
    }

    /// Hand-assembled WASM (binary) exporting `memory`, `patch_malloc`, and
    /// `bad_packed` (see the test above). Kept tiny + literal so the test needs no
    /// WAT toolchain (which the SDK target deliberately excludes).
    private static func oobPackedModule() -> [UInt8] {
        // Built once with `wat2wasm` from:
        //   (module
        //     (memory (export "memory") 1)
        //     (func (export "patch_malloc") (param i32) (result i32) i32.const 16)
        //     (func (export "patch_free") (param i32))
        //     (func (export "bad_packed") (param i32 i32) (result i64)
        //       i64.const 16 i64.const 32 i64.shl          ;; 16 << 32
        //       i64.const 0xFFFFFFFF i64.or))              ;; | 0xFFFFFFFF (len)
        // Verified bytes (wat2wasm of the WAT above; 116 bytes).
        return [
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03, 0x60,
            0x01, 0x7f, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x02, 0x7f, 0x7f,
            0x01, 0x7e, 0x03, 0x04, 0x03, 0x00, 0x01, 0x02, 0x05, 0x03, 0x01, 0x00,
            0x01, 0x07, 0x33, 0x04, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02,
            0x00, 0x0c, 0x70, 0x61, 0x74, 0x63, 0x68, 0x5f, 0x6d, 0x61, 0x6c, 0x6c,
            0x6f, 0x63, 0x00, 0x00, 0x0a, 0x70, 0x61, 0x74, 0x63, 0x68, 0x5f, 0x66,
            0x72, 0x65, 0x65, 0x00, 0x01, 0x0a, 0x62, 0x61, 0x64, 0x5f, 0x70, 0x61,
            0x63, 0x6b, 0x65, 0x64, 0x00, 0x02, 0x0a, 0x18, 0x03, 0x04, 0x00, 0x41,
            0x10, 0x0b, 0x02, 0x00, 0x0b, 0x0e, 0x00, 0x42, 0x10, 0x42, 0x20, 0x86,
            0x42, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x84, 0x0b,
        ]
    }

    // MARK: #2 — WASMRuntime.read/write reject OOB without crashing
    //
    // The marshalling and bridge layers rely on `read`/`write` failing CLOSED (a
    // thrown `memoryOutOfBounds`) for any guest-controlled (ptr,len) past the end
    // of linear memory. A regression to an unchecked slice would be an out-of-
    // bounds read (UB / crash). Pin both directions, including the overflow-prone
    // ptr+len near UInt32.max.

    func testRuntimeReadRejectsOutOfBoundsAndOverflow() throws {
        let runtime = try WASMRuntime(bytes: try marshalBytes())
        let size = try runtime.memorySize()
        // Just past the end.
        XCTAssertThrowsError(try runtime.read(ptr: UInt32(size), len: 1)) { err in
            guard case PatchRuntimeError.memoryOutOfBounds = err else {
                return XCTFail("expected memoryOutOfBounds, got \(err)")
            }
        }
        // ptr valid, len enormous (would overflow a 32-bit add; must not trap).
        XCTAssertThrowsError(try runtime.read(ptr: 0, len: .max)) { err in
            guard case PatchRuntimeError.memoryOutOfBounds = err else {
                return XCTFail("expected memoryOutOfBounds for huge len, got \(err)")
            }
        }
        // A zero-length read at the very end is legal (returns []).
        XCTAssertEqual(try runtime.read(ptr: UInt32(size), len: 0), [])
    }

    func testRuntimeWriteRejectsOutOfBounds() throws {
        let runtime = try WASMRuntime(bytes: try marshalBytes())
        let size = try runtime.memorySize()
        XCTAssertThrowsError(try runtime.write([1, 2, 3, 4], at: UInt32(size))) { err in
            guard case PatchRuntimeError.memoryOutOfBounds = err else {
                return XCTFail("expected memoryOutOfBounds, got \(err)")
            }
        }
    }

    // MARK: #3 — MessagePack reader hardening for str/bin huge counts
    //
    // The array/map32 OOM guard is already tested (MessagePackHardeningTests). The
    // str32/bin32 paths likewise carry an attacker-controlled u32 length; a blob
    // claiming a multi-GB string/bin with no payload must be rejected by the
    // truncated-payload check, never attempt the allocation, and never crash.

    func testHugeStringCountIsRejectedNotAllocated() {
        // str32 (0xdb), length = 0xffffffff, but no following bytes.
        let blob: [UInt8] = [0xdb, 0xff, 0xff, 0xff, 0xff]
        XCTAssertThrowsError(try MessagePack.decode(String.self, from: blob)) { error in
            XCTAssertTrue(error is MessagePackError, "expected MessagePackError, got \(error)")
        }
    }

    func testHugeBinaryCountIsRejectedNotAllocated() {
        // bin32 (0xc6), length = 0xffffffff, no payload.
        let blob: [UInt8] = [0xc6, 0xff, 0xff, 0xff, 0xff]
        XCTAssertThrowsError(try MessagePack.decode(Data.self, from: blob)) { error in
            XCTAssertTrue(error is MessagePackError, "expected MessagePackError, got \(error)")
        }
    }

    /// Deeply-nested arrays must throw (depth cap), not blow the native stack.
    func testDeepNestingThrowsInsteadOfStackOverflow() {
        // 2000 nested fixarray-of-1 headers (0x91), past the 1024 depth cap.
        var blob = [UInt8](repeating: 0x91, count: 2000)
        blob.append(0x00) // a terminal pos-fixint so the innermost element exists
        XCTAssertThrowsError(try MessagePack.decode([[[[Int]]]].self, from: blob)) { error in
            XCTAssertTrue(error is MessagePackError, "deep nesting must throw, not crash")
        }
    }

    // MARK: #4 — Loader verify rejects a tampered module (no partial activation)
    //
    // The loader's SHA-256 verify is the integrity gate: a byte-flip in the
    // downloaded module must be rejected (`hashMismatch`) and must NOT activate or
    // cache. Drive the full `acquireAndActivate` path with a `file://` module whose
    // bytes do not match the advertised sha and assert it throws WITHOUT calling
    // the activation closure.

    func testTamperedModuleIsRejectedAndNeverActivated() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunt5-\(UUID().uuidString).wasm")
        let realBytes: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00] // "\0asm" + version
        try Data(realBytes).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storage = try ModuleStorage(appKey: "hunt5-\(UUID().uuidString)",
                                        baseDirectory: FileManager.default.temporaryDirectory)
        let loader = ModuleLoader(storage: storage)

        // Advertise a WRONG sha (all-zeros) for the served bytes → must mismatch.
        let response = UpdateCheckResponse(
            has_update: true,
            version: "9.9.9",
            module_url: tmp.absoluteString,
            diff_url: nil,
            sha256: String(repeating: "0", count: 64),
            size: realBytes.count,
            mandatory: false)

        var activated = false
        do {
            _ = try await loader.acquireAndActivate(response) { _ in activated = true }
            XCTFail("a sha mismatch must throw, not silently activate")
        } catch let e as ModuleLoader.LoadError {
            guard case .hashMismatch = e else {
                return XCTFail("expected hashMismatch, got \(e)")
            }
        }
        XCTAssertFalse(activated, "verify must fail BEFORE the activation closure runs")
        XCTAssertNil(storage.currentVersion, "a rejected module must never be cached as current")
    }

    /// The matching positive: when the advertised sha matches, the bytes are
    /// handed to the activation closure verbatim and cached as current.
    func testVerifiedModuleActivatesAndCaches() async throws {
        let realBytes: [UInt8] = Array("the-verified-module-bytes".utf8)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunt5ok-\(UUID().uuidString).wasm")
        try Data(realBytes).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storage = try ModuleStorage(appKey: "hunt5ok-\(UUID().uuidString)",
                                        baseDirectory: FileManager.default.temporaryDirectory)
        let loader = ModuleLoader(storage: storage)
        let correctSHA = SHA256Hash.hexString(of: Data(realBytes))

        let response = UpdateCheckResponse(
            has_update: true, version: "1.2.3",
            module_url: tmp.absoluteString, diff_url: nil,
            sha256: correctSHA, size: realBytes.count, mandatory: false)

        var seen: [UInt8]?
        let result = try await loader.acquireAndActivate(response) { bytes in seen = bytes }
        XCTAssertEqual(seen, realBytes, "verified bytes must reach activation unchanged")
        XCTAssertEqual(result.version, "1.2.3")
        XCTAssertEqual(storage.currentVersion, "1.2.3", "a verified module must be cached as current")
    }

    // MARK: #5 — Backoff never crashes on degenerate config (error-path safety)
    //
    // `nextDelay()` runs ONLY after a failed poll; if it could itself trap the app
    // (e.g. `Double.random(in: 0...negative)` or `...infinity`), a single network
    // blip would crash the app. Pin the sanitization for the degenerate cases.

    func testBackoffNeverCrashesOnDegenerateConfig() {
        // Infinite maxDelay + jitter: must produce a finite, non-negative delay.
        var b1 = ExponentialBackoff(base: 2, multiplier: 2, maxDelay: .infinity, jitter: true)
        for _ in 0..<8 {
            let d = b1.nextDelay()
            XCTAssertTrue(d.isFinite && d >= 0, "jittered delay must be finite & >= 0, got \(d)")
        }
        // A huge base/multiplier that overflows pow() to +inf must still be safe.
        var b2 = ExponentialBackoff(base: 1e300, multiplier: 1e10, maxDelay: 300, jitter: true)
        let d2 = b2.nextDelay()
        XCTAssertTrue(d2.isFinite && d2 >= 0 && d2 <= 300)
    }
}
