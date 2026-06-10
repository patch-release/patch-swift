import XCTest
import WasmKit
@testable import PatchSDK

/// Wave-5 bridge: `AppReviewBridge` (in-app rating prompt). Fire-and-forget host
/// function `patch.request_review()` -> []. The native StoreKit call is injected
/// at `init`, so on macOS we inject a spy and assert the registered host function
/// invokes it exactly once per guest call.
///
/// Rather than depend on the prebuilt `BridgeFixture.wasm` (which does not export
/// a `request_review` caller), this drives the FULL guest -> host path through a
/// tiny self-contained wasm module assembled inline: it imports
/// `patch.request_review` and exports `call_request_review`, which simply calls
/// the import. This keeps the test hermetic (no fixture rebuild) while still
/// exercising the real `register(...)` dispatch.
final class AppReviewBridgeTests: XCTestCase {

    /// Minimal wasm module (wat2wasm output of:
    ///   (module
    ///     (import "patch" "request_review" (func $r))
    ///     (func (export "call_request_review") call $r))
    /// ). 77 bytes; imports only `patch.request_review`, exports one caller.
    private static let fixtureWasm: [UInt8] = [
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x02, 0x18,
        0x01, 0x05, 0x70, 0x61, 0x74, 0x63, 0x68, 0x0e, 0x72, 0x65, 0x71, 0x75, 0x65, 0x73, 0x74, 0x5f,
        0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x17, 0x01, 0x13,
        0x63, 0x61, 0x6c, 0x6c, 0x5f, 0x72, 0x65, 0x71, 0x75, 0x65, 0x73, 0x74, 0x5f, 0x72, 0x65, 0x76,
        0x69, 0x65, 0x77, 0x00, 0x01, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b,
    ]

    /// Thread-safe call counter for the injected native action.
    private final class CallSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func record() { lock.lock(); _count += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    }

    private func makeRuntime(_ bridge: AppReviewBridge) throws -> WASMRuntime {
        let registry = BridgeRegistry().register(bridge)
        return try WASMRuntime(bytes: Self.fixtureWasm, hostImports: registry.hostImports())
    }

    /// Each guest call to `request_review` invokes the injected action exactly once.
    func testRequestReviewInvokesInjectedActionOncePerCall() throws {
        let spy = CallSpy()
        let rt = try makeRuntime(AppReviewBridge(request: { spy.record() }))

        XCTAssertEqual(spy.count, 0, "no call before invocation")

        _ = try rt.invoke("call_request_review")
        XCTAssertEqual(spy.count, 1, "one guest call -> exactly one native request_review")

        _ = try rt.invoke("call_request_review")
        _ = try rt.invoke("call_request_review")
        XCTAssertEqual(spy.count, 3, "call count tracks guest invocations 1:1")
    }

    /// The bridge's module namespace + fire-and-forget shape (no args, no result).
    func testModuleNamespaceAndVoidResult() throws {
        let spy = CallSpy()
        let bridge = AppReviewBridge(request: { spy.record() })
        XCTAssertEqual(bridge.module, "patch")

        let rt = try makeRuntime(bridge)
        let results = try rt.invoke("call_request_review")
        XCTAssertTrue(results.isEmpty, "request_review returns no value")
        XCTAssertEqual(spy.count, 1)
    }

    /// Registering via the default registry must not double-define / throw, and
    /// the injected spy still fires through that path.
    func testRegistersWithoutConflict() throws {
        let spy = CallSpy()
        let registry = BridgeRegistry()
        registry.register(AppReviewBridge(request: { spy.record() }))
        let rt = try WASMRuntime(bytes: Self.fixtureWasm, hostImports: registry.hostImports())
        _ = try rt.invoke("call_request_review")
        XCTAssertEqual(spy.count, 1)
    }
}
