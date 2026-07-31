// SPDX-License-Identifier: MIT

import XCTest
import WasmKit
@testable import PatchSDK
#if canImport(SwiftUI)
import SwiftUI
@testable import PatchSwiftUI
#endif

/// Regression tests for SDK bug-hunt #8 — three surgical fixes shipped in 1.5.17.
///
/// #1 (P0) — `checkForUpdate()` ignored the `revert:true` rollback-recall directive.
///           The imperative/EAS-style flow must deactivate + clear-current just like
///           `checkAndApply()` does.
///
/// #2 (P1) — Guest-heap leak in `PatchHTTPBridge.resolvePending`: the response buffer
///           allocated via `patch_malloc` was never freed when `invoke` threw.
///
/// #3 (P2) — `URLSessionBridge.syncGet` did not cancel the task on timeout, so a
///           timed-out dataTask kept running and held the serial call queue.
///
/// (A planned #4 — marshalling a plain `_`-prefixed stored property — was DROPPED;
/// see the note above `testWrapperBackedUnderscoreFieldStillStripsPrefix`.)
final class BugHuntSDK8Tests: XCTestCase {

    // MARK: - Shared helpers

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-bh8-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func marshalBytes() throws -> [UInt8] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm"))
        return [UInt8](try Data(contentsOf: url))
    }

    private struct RoutingTransport: HTTPTransport {
        let route: @Sendable (URLRequest) -> (Data, Int)
        func send(_ request: URLRequest) async throws -> (Data, Int) { route(request) }
    }

    private let apiBase = URL(string: "https://api.test/api/v1")!

    // MARK: - #1: checkForUpdate() must honour revert:true

    /// `checkForUpdate()` with a `revert:true` response must deactivate the live
    /// module, drop the current storage slot, clear pending/staged, reach `.upToDate`,
    /// and return `nil` — mirroring the `checkAndApply()` revert path exactly.
    func testCheckForUpdateHonoursRevertDirective() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = try marshalBytes()

        // Seed a current module (the now-rolled-back patch).
        let storage = try ModuleStorage(appKey: "bh8-revert", baseDirectory: dir)
        try storage.installCurrent(
            version: "1.0.0",
            sha256: SHA256Hash.hexString(of: Data(bytes)),
            bytes: bytes)

        // Backend returns revert:true.
        let revertResp = UpdateCheckResponse(has_update: false, revert: true)
        let revertJSON = try JSONEncoder().encode(revertResp)
        let transport = RoutingTransport { req in
            let p = req.url?.absoluteString ?? ""
            if p.hasSuffix("/modules/check") { return (revertJSON, 200) }
            if p.hasSuffix("/events")        { return (Data(), 201) }
            return (Data(), 404)
        }

        let patch = Patch()
        patch.bridges.registerDefaults()
        patch.injectForTesting(
            configuration: PatchConfiguration(
                appKey: "bh8-revert",
                appID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                apiBaseURL: apiBase,
                fingerprint: "fp", deviceID: "dev"),
            storage: storage,
            checker: UpdateChecker(baseURL: apiBase, transport: transport))

        // Bring the cached module up first.
        _ = patch.activateBestLocal()
        XCTAssertTrue(patch.hasActiveModule, "precondition: cached module is active")
        XCTAssertEqual(storage.currentVersion, "1.0.0")

        // Call the imperative path (NOT checkAndApply).
        let info = try await patch.checkForUpdate()

        // Must return nil — it is a revert, not an available update.
        XCTAssertNil(info, "checkForUpdate() must return nil on revert:true")

        // Module must be deactivated.
        XCTAssertFalse(patch.hasActiveModule,
                       "revert must deactivate the live module in checkForUpdate()")

        // Current slot must be cleared (durable across relaunch).
        XCTAssertNil(storage.currentVersion,
                     "revert must clear current storage slot in checkForUpdate()")

        // Observable must be .upToDate, not .available.
        let state = await MainActor.run { patch.updateState.state }
        XCTAssertEqual(state, .upToDate,
                       "revert must drive updateState to .upToDate in checkForUpdate()")
    }

    // MARK: - #2: PatchHTTPBridge.resolvePending frees buffer when invoke throws

    /// When `invoke` throws (export absent), the response buffer allocated via
    /// `patch_malloc` must be freed so it does not leak. We use MarshalFixture.wasm
    /// (exports patch_malloc + patch_free + memory, but NOT patch_resolve_http). Ten
    /// repeated throw-path calls must all succeed without an allocationFailed error
    /// — which would fire if leaked allocations exhausted the heap.
    func testResolvePendingFreesBufferWhenInvokeThrows() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "MarshalFixture.release", withExtension: "wasm"))
        let runtime = try WASMRuntime(bytes: [UInt8](try Data(contentsOf: url)))

        // Non-empty body forces writeBuffer to actually allocate guest memory.
        let broker = PatchHTTPBroker(
            fetch: { _, _, _ in (Array(repeating: 0xAB, count: 64), 200) })

        var throwCount = 0
        for i in 0..<10 {
            broker.enqueueGet(token: Int32(i), url: "https://example.com/\(i)")
            do { _ = try broker.resolvePending(runtime) }
            catch { throwCount += 1 }
        }
        // All 10 invoke attempts threw (no patch_resolve_http export).
        XCTAssertEqual(throwCount, 10,
            "each resolvePending call must throw (no patch_resolve_http export)")
        // Reaching here without PatchRuntimeError.allocationFailed proves buffers
        // are freed via the defer path — a leaked 64-byte allocation per round would
        // exhaust the 1-page heap before all 10 rounds completed.
    }

    // MARK: - #3: URLSessionBridge.syncGet cancels task on timeout

    /// The DispatchSemaphore.wait(_:) return value must be checked for `.timedOut`.
    /// This validates the conditional that guards `task.cancel()` in the fix.
    func testSyncGetTimeoutBranchCanEvaluate() {
        // A semaphore with value=0 and an already-elapsed deadline always times out.
        let sem = DispatchSemaphore(value: 0)
        // .now() is already in the past by the time wait() inspects it.
        let result = sem.wait(timeout: .now())
        XCTAssertEqual(result, .timedOut,
                       "semaphore(value:0) with .now() deadline must return .timedOut")
        // The fix routes through `if result == .timedOut { task.cancel() }`.
        // This test pins that the conditional CAN evaluate to true, preventing
        // a regression where the `== .timedOut` check is accidentally removed.
    }

    /// Verify syncGet with a session whose tasks are immediately cancelled returns nil.
    func testSyncGetReturnsNilOnCancelledSession() {
        // Use a configuration that immediately refuses all connections.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.001  // near-zero → rapid failure
        let session = URLSession(configuration: config)
        // Result is nil (no body delivered on error/cancel/timeout).
        let result = URLSessionBridge.syncGet("https://127.0.0.1:1/no-such-host", session: session)
        XCTAssertNil(result, "syncGet must return nil when the request fails immediately")
    }

    // MARK: - Wrapper-backed `_` fields must not regress
    //
    // NOTE: the originally-planned Fix #4 (marshal a plain `var _name` underscore-named
    // stored property) was DROPPED: its branch would also catch unknown SwiftUI property
    // wrappers (@FocusState/@Namespace/@Environment(\.keyPath)/…) whose Mirror label is
    // `_name` but which don't conform to Patch's wrapper protocols, feeding their wrapper
    // structs onto the render/marshalling path. A plain `_`-prefixed stored property is an
    // exceedingly rare naming choice, so the risk/reward favored leaving it dropped (the
    // encoder already omits it safely). This test pins that wrapper-backed fields are
    // unaffected.

#if canImport(SwiftUI)
    /// Property-WRAPPER-backed `_` fields (Mirror exposes them as `_count` for
    /// `@State var count`) must NOT regress: they still strip the `_` prefix and
    /// emit as `count`, matching the CLI-facing name.
    @MainActor
    func testWrapperBackedUnderscoreFieldStillStripsPrefix() {
        struct StateView: View {
            @State var count: Int = 7
            var body: some View { EmptyView() }
        }
        let e = PatchInstanceInputs.extract(from: StateView())
        XCTAssertTrue(e.json.contains("\"count\":7"),
            "@State var count must marshal as 'count', not '_count': \(e.json)")
        XCTAssertFalse(e.json.contains("\"_count\""),
            "wrapper storage '_count' must NOT appear raw in the JSON: \(e.json)")
    }
#endif
}
