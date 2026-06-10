import XCTest
import WasmKit
@testable import PatchSDK

/// Proves the PRODUCTIZED on-device async/await EXECUTOR: a real Swift-compiled
/// WASM module's `async`/`await` / `Task` / `async let` / `TaskGroup` / actor /
/// host-await bodies RUN TO COMPLETION when driven through the SDK's pump.
///
/// This mirrors the `experiments/async-exec` proof, but through the SDK API:
///   * the low-level `WASMRuntime.pumpToCompletion` (the executor pump in the run
///     path), and
///   * the high-level `Patch.runAsync` / `Patch.callAsyncResult` facade methods,
///     which install the executor hook, kick off the Task, and pump it — through
///     the serial call queue + read lock (hot-swap-safe).
final class AsyncPumpTests: XCTestCase {

    private func asyncGuestBytes() throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: "AsyncExecGuest", withExtension: "wasm") else {
            throw XCTSkip("AsyncExecGuest.wasm fixture missing")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    /// Build a standalone runtime with the broker's `patch_host.async_request`
    /// import satisfied (the async guest imports it, so a bare instantiation with
    /// no host imports would fail). Pure-async tests still work — they just never
    /// trigger the import.
    private func makeRuntime(broker: PatchAsyncBroker) throws -> WASMRuntime {
        try WASMRuntime(
            bytes: try asyncGuestBytes(),
            hostImports: { imports, store in broker.link(into: &imports, store: store) })
    }

    // MARK: - Low-level: WASMRuntime pump

    /// Control + negative control + the pump making a Task complete.
    func testSyncControlAndPumpedTaskCompletes() throws {
        let runtime = try makeRuntime(broker: PatchAsyncBroker())
        XCTAssertTrue(runtime.supportsAsyncPump(), "module exposes the patch_* pump contract")

        // Sync control: a plain export runs with no pump. sumSync(5)=2*(1+..+5)=30.
        XCTAssertEqual(try runtime.invoke("sumSync", [.i32(5)])[0].i32, 30)

        // Negative control: a Task kicked off but NOT pumped does not complete.
        try runtime.installAsyncExecutor()
        _ = try runtime.invoke("patch_start_sum", [.i32(7)])
        XCTAssertFalse(try runtime.isDone(), "Task is queued, not run, without the pump")
        XCTAssertGreaterThanOrEqual(try runtime.pendingCount(), 1, "a job is enqueued")

        // Now pump to completion — the pump is what makes it run. sumAsync(7)=2*28=56.
        let rounds = try runtime.pumpToCompletion()
        XCTAssertTrue(try runtime.isDone())
        XCTAssertGreaterThan(rounds, 0)
        XCTAssertEqual(try runtime.invoke("patch_result")[0].i32, 56)
    }

    /// Every structured-concurrency shape runs to completion via the pump.
    func testAllAsyncShapesRunToCompletion() throws {
        let runtime = try makeRuntime(broker: PatchAsyncBroker())

        func drive(_ start: String, _ n: Int32) throws -> Int32 {
            try runtime.installAsyncExecutor()
            _ = try runtime.invoke(start, [.i32(UInt32(bitPattern: n))])
            _ = try runtime.pumpToCompletion()
            XCTAssertTrue(try runtime.isDone(), "\(start) completed")
            return Int32(bitPattern: try runtime.invoke("patch_result")[0].i32)
        }

        XCTAssertEqual(try drive("patch_start_sum", 5), 30, "async await-chain")
        XCTAssertEqual(try drive("patch_start_sum", 10), 110, "async await-chain")
        XCTAssertEqual(try drive("patch_start_asynclet", 5), 40, "async let")
        XCTAssertEqual(try drive("patch_start_taskgroup", 5), 30, "TaskGroup")
        XCTAssertEqual(try drive("patch_start_actor", 5), 30, "actor isolation")
    }

    /// The async + HOST-ABI round-trip: the guest awaits a value the HOST resolves
    /// through the broker; the pump resolves it and resumes the continuation.
    /// processWithHost(base) = base + fetched*2, where `fetched` is whatever the
    /// HOST resolved (the host owns the value; we capture it and mirror the guest's
    /// pure transform — exactly as the experiments/async-exec proof does).
    func testHostAwaitRoundTripViaBroker() throws {
        // Capture each value the broker resolves, so we can mirror the guest's
        // transform without assuming the guest's internal token numbering.
        var fetched: [Int32] = []
        let broker = PatchAsyncBroker(valueProvider: { token in
            let v = token * 100 + 7
            fetched.append(v)
            return v
        })
        let runtime = try makeRuntime(broker: broker)

        try runtime.installAsyncExecutor()
        _ = try runtime.invoke("patch_start_hostawait", [.i32(1000)])
        _ = try runtime.pumpToCompletion(hostResolve: broker.resolveCallback())
        XCTAssertTrue(try runtime.isDone())
        XCTAssertEqual(fetched.count, 1, "guest awaited the host exactly once")
        // The guest transformed the HOST-resolved value: base + fetched*2.
        let want = 1000 + fetched[0] * 2
        XCTAssertEqual(Int32(bitPattern: try runtime.invoke("patch_result")[0].i32), want)
    }

    /// A deadlocked host-await (no resolver supplied) surfaces `.stuck` rather than
    /// spinning forever — the pump's forward-progress guard.
    func testHostAwaitWithoutResolverIsStuck() throws {
        let runtime = try WASMRuntime(
            bytes: try asyncGuestBytes(),
            hostImports: { imports, store in
                // async_request that records nothing (the guest suspends forever).
                imports.define(module: "patch_host", name: "async_request",
                               Function(store: store, parameters: [.i32], results: []) { _, _ in [] })
            })
        try runtime.installAsyncExecutor()
        _ = try runtime.invoke("patch_start_hostawait", [.i32(1000)])
        XCTAssertThrowsError(try runtime.pumpToCompletion()) { err in
            guard case AsyncPumpError.stuck = err else {
                return XCTFail("expected .stuck, got \(err)")
            }
        }
    }

    // MARK: - High-level: Patch facade async API

    /// Drive an async export to completion THROUGH the `Patch` facade
    /// (`callAsyncResult`) — install hook + kickoff + pump on the serial queue.
    func testPatchFacadeRunsAsyncToCompletion() throws {
        let patch = Patch()
        patch.bridges.registerFunction(
            module: PatchAsyncBroker.importModule, name: PatchAsyncBroker.importName,
            parameters: [.i32], results: []
        ) { [broker = patch.asyncBroker] _, args in
            broker.enqueue(token: Int32(bitPattern: args[0].i32)); return []
        }
        try patch.activate(bytes: try asyncGuestBytes())

        XCTAssertTrue(patch.activeModuleSupportsAsync())
        // sumAsync(5)=30 via the facade.
        XCTAssertEqual(try patch.callAsyncResult(start: "patch_start_sum", [.i32(5)]), 30)
        // taskGroupSum(5)=30.
        XCTAssertEqual(try patch.callAsyncResult(start: "patch_start_taskgroup", [.i32(5)]), 30)
    }

    /// The facade's `callAsyncResult` + the shared `asyncBroker` resolves a TWO-
    /// await host round-trip (`processTwoHostCalls(base) = base + a + b`). The host
    /// owns the resolved values; we capture them and mirror the guest's transform.
    func testPatchFacadeHostAwaitRoundTrip() throws {
        let patch = Patch()
        var fetched: [Int32] = []
        patch.asyncBroker.valueProvider = { token in
            let v = token * 100 + 7
            fetched.append(v)
            return v
        }
        patch.registerAsyncBrokerImport()   // wires patch_host.async_request → broker
        try patch.activate(bytes: try asyncGuestBytes())

        let result = try patch.callAsyncResult(start: "patch_start_hostawait2", [.i32(2000)])
        XCTAssertEqual(fetched.count, 2, "guest awaited the host twice (sequential awaits)")
        XCTAssertEqual(result, 2000 + fetched[0] + fetched[1])
    }

    /// `runAsync` reports the pump rounds and leaves the module reusable for the
    /// next async call (state is reset per kickoff).
    func testRunAsyncReusableAcrossCalls() throws {
        let patch = Patch()
        patch.registerAsyncBrokerImport()
        try patch.activate(bytes: try asyncGuestBytes())

        let rounds = try patch.runAsync(start: "patch_start_sum", [.i32(5)])
        XCTAssertGreaterThan(rounds, 0)
        XCTAssertEqual(try patch.call("patch_result")[0].i32, 30)

        // A second, different async call on the SAME module works.
        _ = try patch.runAsync(start: "patch_start_asynclet", [.i32(5)])
        XCTAssertEqual(try patch.call("patch_result")[0].i32, 40)
    }
}
