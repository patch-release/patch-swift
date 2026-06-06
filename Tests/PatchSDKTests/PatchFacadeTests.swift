import XCTest
import WasmKit
@testable import PatchSDK

/// Tests the public `Patch` façade: configuration, activation, typed calls, and
/// the thread-safety foundation (serial queue + read/write lock).
final class PatchFacadeTests: XCTestCase {

    private func marshalBytes() throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm") else {
            throw PatchRuntimeError.memoryMissing
        }
        return [UInt8](try Data(contentsOf: url))
    }

    func testConfigureAndActivate() throws {
        // Use a fresh instance to avoid cross-test shared-state coupling.
        let patch = Patch()
        XCTAssertFalse(patch.hasActiveModule)
        XCTAssertThrowsError(try patch.call("add_i64")) { err in
            guard case PatchError.noActiveModule = err else {
                return XCTFail("expected noActiveModule, got \(err)")
            }
        }

        try patch.activate(bytes: try marshalBytes())
        XCTAssertTrue(patch.hasActiveModule)

        let r = try patch.call("add_i64", [.i64(5), .i64(6)])
        XCTAssertEqual(Int64(bitPattern: r[0].i64), 11)

        patch.deactivate()
        XCTAssertFalse(patch.hasActiveModule)
    }

    func testSharedConfigure() {
        Patch.configure(PatchConfiguration(appKey: "test-app", channel: .staging))
        let cfg = Patch.shared.currentConfiguration
        XCTAssertEqual(cfg?.appKey, "test-app")
        XCTAssertEqual(cfg?.channel, .staging)
    }

    func testTypedCallThroughFacade() throws {
        let patch = Patch()
        try patch.activate(bytes: try marshalBytes())

        // not_bool(Bool) -> Bool, via the typed call path (lower + raise).
        let flipped: Bool = try patch.call("not_bool", false, returning: Bool.self)
        XCTAssertTrue(flipped)
        let flipped2: Bool = try patch.call("not_bool", true, returning: Bool.self)
        XCTAssertFalse(flipped2)
    }

    // MARK: - Structured-blob (ptr,len)+packed-i64 ABI (the engine's generated exports)

    /// `callPacked` is the host primitive the engine's auto-generated `@_cdecl`
    /// exports talk to: write input bytes → invoke `(ptr,len)->i64` → unpack the
    /// packed (outPtr,outLen) → read the output bytes. Verified against a real
    /// guest (`reverse_packed`) using actual linear memory.
    func testCallPackedRoundTripsThroughGuestMemory() throws {
        let patch = Patch()
        try patch.activate(bytes: try marshalBytes())

        let input: [UInt8] = Array("PatchSDK".utf8)
        let out = try patch.callPacked("reverse_packed", input)
        XCTAssertEqual(out, input.reversed(), "guest must see and return the bytes via (ptr,len)")

        // Empty input is handled (guest mallocs 0 → returns (ptr, 0)).
        let empty = try patch.callPacked("reverse_packed", [])
        XCTAssertEqual(empty, [])
    }

    /// `callJSON` (encode → callPacked → decode) round-trips a Codable value
    /// through real guest memory — the exact path the generated `Patch.call`
    /// bridge shim uses. The `identity_packed` guest returns the JSON blob
    /// unchanged, so the decoded value must equal the input.
    func testCallJSONRoundTripsCodable() throws {
        struct Order: Codable, Equatable {
            let id: Int
            let sku: String
            let qty: Int
            let promo: String?
        }
        let patch = Patch()
        try patch.activate(bytes: try marshalBytes())

        let order = Order(id: 7, sku: "TSHIRT", qty: 3, promo: "SAVE10")
        let back: Order = try patch.callJSON("identity_packed", order, returning: Order.self)
        XCTAssertEqual(back, order, "callJSON must encode → invoke export → decode back the value")
    }

    /// `callPacked`/`callJSON` surface a clear error when no module is active.
    func testCallPackedRequiresActiveModule() {
        let patch = Patch()
        XCTAssertThrowsError(try patch.callPacked("reverse_packed", [1, 2, 3])) { err in
            guard case PatchError.noActiveModule = err else {
                return XCTFail("expected noActiveModule, got \(err)")
            }
        }
    }

    /// A failing `callPacked` (here: invoking `add_i64`, an (i64,i64)->i64
    /// export, via the packed (i32,i32)->i64 path — a signature mismatch that
    /// traps inside `invoke`) must surface a clean `PatchError`, free the input
    /// guest buffer it allocated (the fix moves that `free` into a `defer` so it
    /// runs on the error path, not only on success — otherwise every failing
    /// packed call leaks its input buffer), and leave the instance usable for a
    /// subsequent successful call.
    func testCallPackedFailurePathStaysSound() throws {
        let patch = Patch()
        try patch.activate(bytes: try marshalBytes())

        let payload = [UInt8](repeating: 0xAB, count: 4096)
        // Many failing packed calls in a row must not corrupt or wedge the
        // instance (each frees its input buffer in the `defer`).
        for _ in 0..<256 {
            XCTAssertThrowsError(try patch.callPacked("add_i64", payload)) { err in
                guard case PatchError.runtime = err else {
                    return XCTFail("expected PatchError.runtime, got \(err)")
                }
            }
        }

        // A real packed call still round-trips after all those failures.
        let reversed = try patch.callPacked("reverse_packed", [1, 2, 3, 4])
        XCTAssertEqual(reversed, [4, 3, 2, 1])
        // And a normal call still works.
        let r = try patch.call("add_i64", [.i64(20), .i64(22)])
        XCTAssertEqual(Int64(bitPattern: r[0].i64), 42)
    }

    func testHotSwapReplacesActiveModule() throws {
        let patch = Patch()
        try patch.activate(bytes: try marshalBytes())
        XCTAssertEqual(Int64(bitPattern: try patch.call("add_i64", [.i64(1), .i64(1)])[0].i64), 2)

        // Hot-swap to the same module bytes (proves the drain+swap path works and
        // calls keep succeeding afterward).
        try patch.hotSwap(bytes: try marshalBytes())
        XCTAssertTrue(patch.hasActiveModule)
        XCTAssertEqual(Int64(bitPattern: try patch.call("add_i64", [.i64(3), .i64(4)])[0].i64), 7)
    }

    /// A hot-swap whose new module fails to come up must roll back to the prior
    /// (known-good) module: the swap throws, but the old module stays active and
    /// keeps answering calls. Bytes are a valid wasm magic header followed by
    /// garbage — they pass the magic check but fail to instantiate, exercising
    /// the build-then-swap failure path (the new runtime is never installed).
    func testHotSwapRollsBackToPriorModuleOnFailure() throws {
        let patch = Patch()
        try patch.activate(bytes: try marshalBytes())
        XCTAssertEqual(Int64(bitPattern: try patch.call("add_i64", [.i64(2), .i64(3)])[0].i64), 5)

        let bad: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0xff, 0xff, 0xff, 0xff]
            + [UInt8](repeating: 0x00, count: 32)
        XCTAssertThrowsError(try patch.hotSwap(bytes: bad)) { err in
            guard case PatchError.runtime = err else {
                return XCTFail("expected PatchError.runtime, got \(err)")
            }
        }

        // Rollback proven: the prior good module is still active and callable, and
        // produces correct results (it was never torn down).
        XCTAssertTrue(patch.hasActiveModule, "prior module must stay active after a failed hot-swap")
        XCTAssertEqual(Int64(bitPattern: try patch.call("add_i64", [.i64(10), .i64(11)])[0].i64), 21)

        // A subsequent good hot-swap still succeeds after the failed one.
        try patch.hotSwap(bytes: try marshalBytes())
        XCTAssertEqual(Int64(bitPattern: try patch.call("add_i64", [.i64(4), .i64(5)])[0].i64), 9)
    }

    /// The `assertUsable()` probe (the rollback trigger for a module that
    /// instantiates but cannot marshal) returns cleanly for a real module that
    /// exports linear memory — so a good hot-swap is never spuriously rolled back.
    func testAssertUsablePassesForRealModule() throws {
        let runtime = try WASMRuntime(bytes: try marshalBytes())
        XCTAssertNoThrow(try runtime.assertUsable())
    }

    /// Concurrency smoke test: hammer the serial queue from many threads. The
    /// single WASM instance must never be re-entered concurrently; all results
    /// must be correct and no crashes/data races occur.
    func testConcurrentCallsSerializeCorrectly() throws {
        let patch = Patch()
        try patch.activate(bytes: try marshalBytes())

        let iterations = 500
        let results = ResultBox()
        let group = DispatchGroup()
        let pool = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        for n in 0..<iterations {
            group.enter()
            pool.async {
                defer { group.leave() }
                do {
                    let r = try patch.call("add_i64", [.i64(UInt64(n)), .i64(1)])
                    results.record(expected: Int64(n) + 1, got: Int64(bitPattern: r[0].i64))
                } catch {
                    results.recordError(error)
                }
            }
        }
        let timeout = group.wait(timeout: .now() + 30)
        XCTAssertEqual(timeout, .success, "concurrent calls did not finish in time")
        XCTAssertEqual(results.errorCount, 0, "calls errored: \(results.firstError as Any)")
        XCTAssertEqual(results.mismatchCount, 0, "got \(results.mismatchCount) wrong results")
        XCTAssertEqual(results.okCount, iterations)
    }

    /// Concurrency under hot-swap: keep calling while swapping the module. The
    /// read/write lock must prevent the active runtime from being freed mid-call.
    func testConcurrentCallsDuringHotSwap() throws {
        let patch = Patch()
        try patch.activate(bytes: try marshalBytes())

        let results = ResultBox()
        let group = DispatchGroup()
        let pool = DispatchQueue(label: "test.swap", attributes: .concurrent)
        let bytes = try marshalBytes()

        // Caller threads.
        for n in 0..<300 {
            group.enter()
            pool.async {
                defer { group.leave() }
                do {
                    let r = try patch.call("add_i64", [.i64(UInt64(n)), .i64(2)])
                    results.record(expected: Int64(n) + 2, got: Int64(bitPattern: r[0].i64))
                } catch {
                    results.recordError(error)
                }
            }
        }
        // Swapper thread, racing the callers.
        for _ in 0..<10 {
            group.enter()
            pool.async {
                defer { group.leave() }
                do { try patch.hotSwap(bytes: bytes) }
                catch { results.recordError(error) }
            }
        }
        let timeout = group.wait(timeout: .now() + 30)
        XCTAssertEqual(timeout, .success)
        XCTAssertEqual(results.errorCount, 0, "errors during hot-swap: \(results.firstError as Any)")
        XCTAssertEqual(results.mismatchCount, 0)
    }
}

/// Thread-safe tally for the concurrency tests.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var okCount = 0
    private(set) var mismatchCount = 0
    private(set) var errorCount = 0
    private(set) var firstError: Error?

    func record(expected: Int64, got: Int64) {
        lock.lock(); defer { lock.unlock() }
        if expected == got { okCount += 1 } else { mismatchCount += 1 }
    }
    func recordError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        errorCount += 1
        if firstError == nil { firstError = error }
    }
}
