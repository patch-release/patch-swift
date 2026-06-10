import XCTest
import WasmKit
@testable import PatchSDK

/// Regression tests for SDK bug-hunt #6. Each pins a specific real bug fixed in the
/// corresponding source file. All are fixture-free (hand-assembled tiny WASM modules
/// via `wat2wasm`), so they run in any environment with no committed `.wasm`.
final class BugHuntSDK6Tests: XCTestCase {

    // MARK: #1 — WASMRuntime.writeBuffer leaked the allocated ptr when write() failed
    //
    // `writeBuffer` does `allocate()` then `write()`. A guest-controlled
    // `patch_malloc` that returns a pointer near/past the end of linear memory makes
    // the bounds-checked `write` throw `memoryOutOfBounds` — and the OLD code never
    // freed the just-allocated guest buffer on that path. The leak compounded through
    // every caller (MarshalContext records the ptr only AFTER writeBuffer returns, so
    // a throw never recorded it; callPacked's input write; the HTTP resolve path) and
    // repeated failing calls could exhaust guest linear memory. The fix frees `ptr`
    // when the write throws.

    func testWriteBufferFreesAllocatedPtrWhenWriteFails() throws {
        let rt = try WASMRuntime(bytes: Self.trackingMallocModule())
        // patch_malloc returns 0xFFFC0000 (far past the 1-page / 65536-byte memory),
        // so writeBuffer's internal write() bounds-check throws.
        XCTAssertThrowsError(try rt.writeBuffer([1, 2, 3, 4, 5])) { err in
            guard case PatchRuntimeError.memoryOutOfBounds = err else {
                return XCTFail("expected memoryOutOfBounds, got \(err)")
            }
        }
        // The fix freed the leaked buffer: patch_free was invoked exactly once.
        XCTAssertEqual(try rt.invoke("free_count")[0].i32, 1,
                       "writeBuffer must free the allocated ptr when the write fails")

        // Many failing calls must NOT accumulate unfreed buffers (one free per call).
        for _ in 0..<50 { _ = try? rt.writeBuffer([9, 9, 9]) }
        XCTAssertEqual(try rt.invoke("free_count")[0].i32, 51,
                       "each failing writeBuffer frees its buffer (no leak accumulation)")
    }

    // MARK: #2 — BridgeContext.writeBytes leaked the allocated ptr on the OOB path
    //
    // A host bridge that returns bytes goes through `BridgeContext.writeBytes`, which
    // invokes the guest's `patch_malloc`, bounds-checks the returned ptr, then writes.
    // If the bounds-check fails (guest malloc returned an OOB ptr) the OLD code threw
    // `oob` WITHOUT freeing the just-allocated buffer — one leak per bridge call. The
    // fix frees the buffer (best-effort `patch_free`) before throwing. Here a custom
    // bridge's host fn calls `packedResult` (→ writeBytes) on a module whose
    // `patch_malloc` returns an OOB ptr; we drive it via the guest export `call_bridge`
    // and assert `patch_free` was invoked.

    func testBridgeWriteBytesFreesAllocatedPtrOnOOB() throws {
        let registry = BridgeRegistry()
        registry.registerFunction(module: "patch", name: "emit", parameters: [], results: [.i64]) { caller, _ in
            let ctx = BridgeContext(caller: caller)
            // Returning bytes routes through writeBytes; the guest's patch_malloc is
            // OOB so writeBytes throws `oob` (and, after the fix, frees the buffer).
            return [try ctx.packedResult([UInt8]("hello-from-host".utf8))]
        }
        let rt = try WASMRuntime(bytes: Self.bridgeLeakModule(),
                                 hostImports: registry.hostImports())
        // call_bridge invokes the host emit fn, which throws on the OOB write. The
        // trap surfaces as a runtime error; what matters is patch_free ran once.
        XCTAssertThrowsError(try rt.invoke("call_bridge"))
        XCTAssertEqual(try rt.invoke("free_count")[0].i32, 1,
                       "BridgeContext.writeBytes must free the allocated ptr on the OOB path")
    }

    // MARK: #3 — activate/hotSwap now probe EVERY module's usability, not just primary
    //
    // A PMOD container's additive sub-module that instantiates but exports no
    // `memory` cannot participate in the marshalling ABI. The OLD `hotSwap` probed
    // only `built.primary.assertUsable()`; `activate` probed nothing. Such a set
    // could swap in and only fail later at call time. The fix probes every module in
    // the set before committing (in `instantiateModuleSet`), so a bad set is rejected
    // at activation and the prior module is preserved.

    func testActivateRejectsModuleSetWithUnusableAdditionalSubmodule() throws {
        // A PMOD container: [valid module with memory, a module WITHOUT memory export].
        let container = PatchModuleContainer.encode([
            Self.trackingMallocModule(),   // primary: exports memory
            Self.noMemoryModule(),         // additive: NO memory export → unusable
        ])
        let patch = Patch()
        XCTAssertThrowsError(try patch.activate(bytes: container)) { err in
            guard case PatchError.runtime(let re) = err, case .memoryMissing = re else {
                return XCTFail("expected memoryMissing for the no-memory sub-module, got \(err)")
            }
        }
        XCTAssertFalse(patch.hasActiveModule, "a set with an unusable sub-module must not activate")
    }

    func testHotSwapRollsBackWhenNewSetHasUnusableSubmodule() throws {
        let good = Self.trackingMallocModule()
        let patch = Patch()
        try patch.activate(bytes: good)   // a known-good single module is active
        XCTAssertTrue(patch.hasActiveModule)

        // Attempt to hot-swap to a set whose additive sub-module is unusable.
        let badSet = PatchModuleContainer.encode([good, Self.noMemoryModule()])
        XCTAssertThrowsError(try patch.hotSwap(bytes: badSet))
        // The prior good module is preserved (rollback) and still usable.
        XCTAssertTrue(patch.hasActiveModule, "hotSwap must keep the prior module on a bad new set")
        XCTAssertNoThrow(try patch.withRuntime { try $0.assertUsable() })
    }

    // MARK: - Hand-assembled WASM modules (wat2wasm; kept literal so no toolchain)

    /// (memory 1); patch_malloc -> 0xFFFC0000 (OOB); patch_free increments a counter;
    /// free_count returns it.
    private static func trackingMallocModule() -> [UInt8] {
        [
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0e, 0x03, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x04, 0x03, 0x00, 0x01, 0x02, 0x05, 0x03, 0x01, 0x00, 0x01, 0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x00, 0x0b, 0x07, 0x33, 0x04, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x0c, 0x70, 0x61, 0x74, 0x63, 0x68, 0x5f, 0x6d, 0x61, 0x6c, 0x6c, 0x6f, 0x63, 0x00, 0x00, 0x0a, 0x70, 0x61, 0x74, 0x63, 0x68, 0x5f, 0x66, 0x72, 0x65, 0x65, 0x00, 0x01, 0x0a, 0x66, 0x72, 0x65, 0x65, 0x5f, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x02, 0x0a, 0x17, 0x03, 0x06, 0x00, 0x41, 0x80, 0x80, 0x7c, 0x0b, 0x09, 0x00, 0x23, 0x00, 0x41, 0x01, 0x6a, 0x24, 0x00, 0x0b, 0x04, 0x00, 0x23, 0x00, 0x0b,
        ]
    }

    /// Imports `patch.emit` (-> i64); exports memory, an OOB patch_malloc, a counting
    /// patch_free, free_count, and `call_bridge` which invokes the imported emit.
    private static func bridgeLeakModule() -> [UInt8] {
        [
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x12, 0x04, 0x60, 0x00, 0x01, 0x7e, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x02, 0x0e, 0x01, 0x05, 0x70, 0x61, 0x74, 0x63, 0x68, 0x04, 0x65, 0x6d, 0x69, 0x74, 0x00, 0x00, 0x03, 0x05, 0x04, 0x01, 0x02, 0x03, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x00, 0x0b, 0x07, 0x41, 0x05, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x0c, 0x70, 0x61, 0x74, 0x63, 0x68, 0x5f, 0x6d, 0x61, 0x6c, 0x6c, 0x6f, 0x63, 0x00, 0x01, 0x0a, 0x70, 0x61, 0x74, 0x63, 0x68, 0x5f, 0x66, 0x72, 0x65, 0x65, 0x00, 0x02, 0x0a, 0x66, 0x72, 0x65, 0x65, 0x5f, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x03, 0x0b, 0x63, 0x61, 0x6c, 0x6c, 0x5f, 0x62, 0x72, 0x69, 0x64, 0x67, 0x65, 0x00, 0x04, 0x0a, 0x1c, 0x04, 0x06, 0x00, 0x41, 0x80, 0x80, 0x7c, 0x0b, 0x09, 0x00, 0x23, 0x00, 0x41, 0x01, 0x6a, 0x24, 0x00, 0x0b, 0x04, 0x00, 0x23, 0x00, 0x0b, 0x04, 0x00, 0x10, 0x00, 0x0b,
        ]
    }

    /// A module that instantiates but exports NO `memory` (only patch_malloc + noop).
    private static func noMemoryModule() -> [UInt8] {
        [
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x09, 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x00, 0x03, 0x03, 0x02, 0x00, 0x01, 0x07, 0x17, 0x02, 0x0c, 0x70, 0x61, 0x74, 0x63, 0x68, 0x5f, 0x6d, 0x61, 0x6c, 0x6c, 0x6f, 0x63, 0x00, 0x00, 0x04, 0x6e, 0x6f, 0x6f, 0x70, 0x00, 0x01, 0x0a, 0x09, 0x02, 0x04, 0x00, 0x41, 0x10, 0x0b, 0x02, 0x00, 0x0b,
        ]
    }
}
