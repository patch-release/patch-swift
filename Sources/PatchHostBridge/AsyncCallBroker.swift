// SPDX-License-Identifier: MIT

import Foundation

// ===========================================================================
// PatchAsyncCallBroker — the HOST-side capture + resolve for ASYNC routed calls
// (Lever #2 async half; the generic-bridge analogue of `PatchHTTPBroker`).
//
// When a guest's `async` body calls the SUSPEND import
// `patch_host.call_async(symbolId, argsPtr, argsLen, token)`, the WasmKit glue
// (`GenericHostBridge`) reads the arg blob and records the pending call HERE (the
// guest then returns → suspended on its continuation for `token`). When the async
// pump stalls (the guest has no pure jobs left to run because it is awaiting this
// host value), the SDK calls `resolvePending(...)`, which — for each pending call
// — runs the registered async thunk to completion on HOST concurrency (a `Task` +
// semaphore; the guest is suspended so blocking the caller thread is correct, just
// as the HTTP broker blocks on `URLSession`), encodes the TLV result blob, writes
// it into guest memory, and resumes the guest via `patch_resolve_hostcall`.
//
// Thread-confined to the runtime's serial call queue (the SDK drives the pump on
// that queue), so — like `PatchHTTPBroker` — no internal locking of `pending` is
// needed. It is `@unchecked Sendable` only so it can be captured by the WasmKit
// import closures.
// ===========================================================================

public final class PatchAsyncCallBroker: @unchecked Sendable {

    /// One owed async call captured while the guest was suspended.
    public struct Pending: Sendable {
        public let token: Int32
        public let symbolId: Int32
        public let argsBlob: [UInt8]
    }

    /// The import module + name the guest's generated shim declares for the
    /// async-suspend call (mirrors `patch_host.call`'s namespace).
    public static let importModule = "patch_host"
    public static let importName = "call_async"
    /// The guest export the host calls to resume a suspended async call. It takes
    /// `(token, resultPtr, resultLen)`: the guest reads the TLV result blob at
    /// `[resultPtr, resultPtr+resultLen)`, decodes it exactly as a synchronous
    /// `patch_host.call` result, and resumes its continuation. An EMPTY result
    /// (len 0) decodes as `.nilValue` (void) — the same convention as the packed-0
    /// synchronous result.
    public static let resolveExport = "patch_resolve_hostcall"

    /// The controller whose async registry this broker resolves against.
    public let bridge: PatchHostBridge

    private var pending: [Pending] = []

    public init(bridge: PatchHostBridge) {
        self.bridge = bridge
    }

    // MARK: Enqueue (called from the `call_async` import host function)

    /// `call_async(symbolId, args, token)` — the guest suspended awaiting an async
    /// call for `token`.
    public func enqueue(token: Int32, symbolId: Int32, argsBlob: [UInt8]) {
        pending.append(Pending(token: token, symbolId: symbolId, argsBlob: argsBlob))
    }

    /// Whether any async call is owed (the pump's stall handler checks this).
    public var hasPending: Bool { !pending.isEmpty }

    /// Drain the owed calls (FIFO).
    public func drain() -> [Pending] {
        defer { pending.removeAll() }
        return pending
    }

    // MARK: Resolve (the pump's stall handler)

    /// Resolve every owed async call. For each: run the registered async thunk to
    /// completion (on host concurrency), encode the TLV result blob, write it into
    /// guest memory via `writeBlob`, and resume the continuation via `invokeResolve`.
    /// Returns whether any progress was made (so the pump knows there is more to run).
    ///
    /// `writeBlob`   : write `[UInt8]` into guest linear memory, return `(ptr, len)`
    ///                 (an empty blob may map to `(0, 0)`). The SDK supplies
    ///                 `runtime.writeBuffer`.
    /// `invokeResolve`: invoke the guest's `patch_resolve_hostcall(token, ptr, len)`.
    ///
    /// Expressed against injected closures so this stays Foundation-only (no PatchSDK
    /// / WasmKit dependency — the same boundary the controller keeps). The SDK's
    /// `GenericHostBridge.asyncResolveCallback` adapts a `WASMRuntime` to these.
    ///
    /// A thunk that NEVER completes (a hung async symbol) is bounded by `timeout`:
    /// on timeout the call resolves to a tagged `.error` (→ guest demotes), so a
    /// stuck native symbol can never deadlock the pump.
    @discardableResult
    public func resolvePending(
        timeout: TimeInterval = 30,
        writeBlob: (_ bytes: [UInt8]) throws -> (ptr: UInt32, len: UInt32),
        invokeResolve: (_ token: Int32, _ ptr: UInt32, _ len: UInt32) throws -> Void
    ) throws -> Bool {
        let owed = drain()
        if owed.isEmpty { return false }
        for call in owed {
            let result = runAsyncToCompletion(symbolId: call.symbolId,
                                              argsBlob: call.argsBlob,
                                              timeout: timeout)
            // Encode the TLV result blob (a `.nilValue` → empty blob → (0,0) resume).
            let blob = TLVCodec.encodeValue(result)
            let (ptr, len) = blob.isEmpty ? (UInt32(0), UInt32(0)) : try writeBlob(blob)
            try invokeResolve(call.token, ptr, len)
        }
        return true
    }

    /// Run the registered async thunk for `symbolId` to completion synchronously
    /// (blocking the caller thread — correct here because the guest is suspended).
    /// A `Task` performs the `await`; a semaphore waits for it. Any failure or a
    /// timeout becomes a tagged `.error` result the guest demotes on.
    func runAsyncToCompletion(symbolId: Int32, argsBlob: [UInt8], timeout: TimeInterval) -> TLVValue {
        let box = _AsyncResultBox()
        let sem = DispatchSemaphore(value: 0)
        let bridge = self.bridge
        Task {
            let r = await bridge.callAsync(symbolId, argsBlob: argsBlob)
            box.set(r)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            return .error("async symbolId \(symbolId) timed out after \(timeout)s")
        }
        return box.get() ?? .error("async symbolId \(symbolId) produced no result")
    }
}

/// Thread-safe box so the detached `Task`'s async result can hand back to the
/// blocking caller (mirrors `_HTTPResultBox`).
private final class _AsyncResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TLVValue?
    func set(_ v: TLVValue) { lock.lock(); value = v; lock.unlock() }
    func get() -> TLVValue? { lock.lock(); defer { lock.unlock() }; return value }
}
