import XCTest
import WasmKit
@testable import PatchSDK

/// Networking round-trip through the SDK.
///
/// A real Swift-compiled WASM guest (built under the full
/// WASM SDK) is `async` only because it `await`s a fetch; it then decodes JSON with
/// `JSONDecoder` in WASM and returns a derived value. The host serves the fetch via
/// `PatchHTTPBroker` (a mock fetch — no real outbound network in CI), writes the
/// response bytes into guest linear memory, and resumes the guest's continuation via
/// `patch_resolve_http`. The pump drives it to completion.
///
/// The round-trip under test:
///   guest await URLSession-shaped fetch  ->  SDK host serves bytes+status
///   ->  JSONDecoder in WASM  ->  correct decoded/derived value.
final class PatchHTTPBridgeTests: XCTestCase {

    private func guestBytes() throws -> [UInt8] {
        // Loaded by source-relative path (not Bundle.module) so the large networking
        // fixture can stay OUT of git + the Package resource list. The test
        // XCTSkips when it's absent (e.g. a fresh checkout / CI); it runs locally where
        // the fixture is present.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NetworkingGuest.wasm")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("NetworkingGuest.wasm fixture missing (kept local; not committed)")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    /// Build a runtime whose only host import is the networking broker (the guest's
    /// sole non-WASI import is patch_host.http_get).
    private func makeRuntime(broker: PatchHTTPBroker) throws -> WASMRuntime {
        try WASMRuntime(
            bytes: try guestBytes(),
            hostImports: { imports, store in broker.register(into: &imports, store: store) })
    }

    /// Write a URL into guest memory and set it as the fetch target.
    private func setURL(_ url: String, on rt: WASMRuntime) throws {
        let (ptr, len) = try rt.writeBuffer([UInt8](url.utf8))
        _ = try rt.invoke("patch_set_url", [.i32(ptr), .i32(len)])
    }

    private func drive(_ start: String, broker: PatchHTTPBroker, on rt: WASMRuntime) throws {
        try rt.installAsyncExecutor()
        _ = try rt.invoke(start)
        _ = try rt.pumpToCompletion(hostResolve: broker.resolveCallback())
        XCTAssertTrue(try rt.isDone(), "\(start) must run to completion")
    }

    // MARK: - The round-trip proof

    /// loadUser: await GET -> decode `User` -> derived value. The host serves the
    /// JSON; the decode + transform run in WASM. Derived value (guest):
    ///   ratio(=followers*100/following) + id + displayName.count.
    func testLoadUserDecodesInWasmFromMockHostFetch() throws {
        let json = #"{"id":7,"followers":3500,"following":100,"displayName":"Ada"}"#
        let sawURL = _Captured()
        let broker = PatchHTTPBroker(fetch: { method, url, _ in
            sawURL.set(url)
            XCTAssertEqual(method, "GET")
            return ([UInt8](json.utf8), 200)
        })
        let rt = try makeRuntime(broker: broker)

        // Sync control: the module instantiated + runs plain code.
        XCTAssertEqual(try rt.invoke("sumSync", [.i32(5)])[0].i32, 30)

        try setURL("https://api.example.com/user", on: rt)
        try drive("patch_start_loaduser", broker: broker, on: rt)

        XCTAssertEqual(sawURL.get(), "https://api.example.com/user", "the guest's URL crossed the ABI to the host")
        XCTAssertEqual(try rt.invoke("patch_errored")[0].i32, 0, "200 path: no error")
        // ratio = 3500*100/100 = 3500; + id(7) + "Ada".count(3) = 3510.
        XCTAssertEqual(Int32(bitPattern: try rt.invoke("patch_result")[0].i32), 3510)
    }

    /// loadFeedStats: a JSON ARRAY decoded to `[Repo]`, then reduce/aggregate in WASM.
    func testLoadFeedStatsDecodesArrayInWasm() throws {
        let json = #"[{"name":"a","stars":1000},{"name":"b","stars":2500},{"name":"c","stars":150}]"#
        let broker = PatchHTTPBroker(fetch: { _, _, _ in ([UInt8](json.utf8), 200) })
        let rt = try makeRuntime(broker: broker)
        try setURL("https://api.example.com/repos", on: rt)
        try drive("patch_start_loadfeedstats", broker: broker, on: rt)
        // totalStars(3650) + count(3) = 3653.
        XCTAssertEqual(Int32(bitPattern: try rt.invoke("patch_result")[0].i32), 3653)
    }

    /// The error path: a real non-200 status marshals back as the guest's thrown
    /// `LoadError.badStatus(status)` — status crosses the ABI.
    func testNon200StatusSurfacesGuestErrorPath() throws {
        let broker = PatchHTTPBroker(fetch: { _, _, _ in ([], 404) })
        let rt = try makeRuntime(broker: broker)
        try setURL("https://api.example.com/missing", on: rt)
        try drive("patch_start_loaduser", broker: broker, on: rt)
        XCTAssertEqual(try rt.invoke("patch_errored")[0].i32, 1, "non-200 must take the error path")
        XCTAssertEqual(Int32(bitPattern: try rt.invoke("patch_result")[0].i32), 404, "status crosses the ABI")
    }

    // MARK: - Broker unit behaviour (no guest)

    func testBrokerRecordsGetRequest() {
        let broker = PatchHTTPBroker(fetch: { _, _, _ in ([], 0) })
        broker.enqueueGet(token: 5, url: "https://x.test/a")
        XCTAssertTrue(broker.hasPending)
        let owed = broker.drain()
        XCTAssertEqual(owed.count, 1)
        XCTAssertEqual(owed[0].token, 5)
        XCTAssertEqual(owed[0].method, "GET")
        XCTAssertEqual(owed[0].url, "https://x.test/a")
        XCTAssertFalse(broker.hasPending, "drain clears pending")
    }

    func testBrokerRequestDefaultsEmptyMethodToGet() {
        let broker = PatchHTTPBroker(fetch: { _, _, _ in ([], 0) })
        broker.enqueueRequest(token: 1, method: "", url: "u", body: [])
        XCTAssertEqual(broker.drain()[0].method, "GET")
    }

    // MARK: - Import parity (#6 half: SDK serves the engine-emitted http imports)

    /// `registerDefaults()` serves the async networking imports the engine emits.
    /// A guest importing patch_host.http_get instantiates cleanly against defaults —
    /// WasmKit rejects any unsatisfied import, so a clean instantiate proves the
    /// http_get import is served (emitted ⊆ served for the networking half).
    func testRegisterDefaultsServesHTTPGetImport() throws {
        // Resolve the (optional, local-only) fixture FIRST so a missing fixture
        // surfaces as an XCTSkip from `guestBytes()` — NOT as a spurious failure.
        // (Previously the `try guestBytes()` lived INSIDE `XCTAssertNoThrow`, which
        // catches the thrown `XCTSkip` and reports it as a test FAILURE.)
        let bytes = try guestBytes()
        let registry = BridgeRegistry().registerDefaults()
        XCTAssertNoThrow(
            try WASMRuntime(bytes: bytes, hostImports: registry.hostImports()),
            "registerDefaults() must serve patch_host.http_get (the engine-emitted import)")
    }

    // MARK: - High-level facade path (Patch.httpBroker + callAsyncResult)

    /// Drive the networking round-trip THROUGH the `Patch` facade: a mock
    /// `httpBroker`, the http imports wired to it, and `callAsyncResult` which
    /// installs the hook + kicks off + pumps (resolving the fetch via the shared
    /// broker through `combinedResolve`).
    func testPatchFacadeDrivesNetworkingRoundTrip() throws {
        let patch = Patch()
        let json = #"{"id":7,"followers":3500,"following":100,"displayName":"Ada"}"#
        patch.httpBroker = PatchHTTPBroker(fetch: { _, _, _ in ([UInt8](json.utf8), 200) })
        patch.registerHTTPBrokerImport()        // wire patch_host.http_get → facade broker
        try patch.activate(bytes: try guestBytes())

        // Set the URL (write into guest memory + invoke patch_set_url), then drive
        // loadUser to completion + read the derived result.
        try patch.withRuntime { rt in
            let (ptr, len) = try rt.writeBuffer([UInt8]("https://api.example.com/user".utf8))
            _ = try rt.invoke("patch_set_url", [.i32(ptr), .i32(len)])
        }
        let result = try patch.callAsyncResult(start: "patch_start_loaduser")
        XCTAssertEqual(result, 3510, "decode+transform in WASM, fetch served by the facade broker")
    }
}

/// Thread-safe capture box (the broker's fetch closure is @Sendable).
private final class _Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
