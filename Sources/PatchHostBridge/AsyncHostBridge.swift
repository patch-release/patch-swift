// SPDX-License-Identifier: MIT

import Foundation

// ===========================================================================
// AsyncHostBridge — the ASYNC half of the generalized "call what's already
// linked" host bridge (Lever #2, DESIGN §8.7 — "async native symbols compose
// with the existing async pump + a continuation, as the networking bridge does").
//
// THE PROBLEM. A SYNCHRONOUS routed call (PatchHostBridge.call) runs the native
// thunk inline on the WasmKit caller thread and returns its TLV result blob in
// the SAME trap — correct because the guest is blocked anyway. An `async` native
// symbol (e.g. `await store.products(for:)`, `await loader.fetch()`) CANNOT be
// run that way: `await`ing it would block the single WasmKit thread (no event
// loop inside the sandbox), and Swift concurrency has no executor in WASI to make
// progress on. So we reuse the SAME continuation pattern the networking bridge
// (`PatchHTTPBroker`) already proved:
//
//   1. the guest, in an `async` body, calls a SUSPEND import
//      `patch_host.call_async(symbolId, argsPtr, argsLen, token) -> ()` and
//      returns (the guest is now suspended on its continuation for `token`);
//   2. the host CAPTURES that pending call (this file's `PatchAsyncCallBroker`);
//   3. when the pump stalls (no pure guest jobs left to run), the host RESOLVES
//      every pending call: it runs the registered ASYNC thunk to completion on
//      its OWN concurrency (a `Task` + semaphore, exactly as the HTTP broker's
//      `URLSession` fetch blocks the host — the guest has nothing else to run),
//      encodes the TLV result blob, writes it into GUEST memory, and resumes the
//      continuation by invoking the guest export
//      `patch_resolve_hostcall(token, resultPtr, resultLen) -> ()`;
//   4. the next pump round runs the resumed continuation with the real value.
//
// This file owns the host-side state (the async registry + the pending-call
// broker). The WasmKit glue (the `call_async` import + the result-write-back +
// the `patch_resolve_hostcall` invoke) lives in `GenericHostBridge` so this file
// stays Foundation-only + directly unit-testable; the broker's resolve step is
// expressed against two injected closures (write-to-guest-memory / invoke-the-
// resolve-export) so it never has to import PatchSDK or WasmKit (no dep cycle —
// the same boundary `PatchHostBridge` already keeps).
// ===========================================================================

/// A registered ASYNC native thunk: takes the decoded args + the shared handle
/// table, `await`s the real native `async` symbol, and returns one `TLVValue`.
/// MAY throw (a thrown error → a tagged `.error` result → the guest demotes), so
/// an `async throws` native symbol composes for free (the throwing half rides the
/// same `.error` channel as the synchronous throwing thunk).
public typealias AsyncHostThunk = @Sendable (_ args: ArgReader, _ handles: HandleTable) async throws -> TLVValue

extension PatchHostBridge {

    // MARK: - Async registration API (the async resolver-thunk's entry point)

    /// Register an ASYNC native thunk for `id`. Mirrors the synchronous
    /// `register(id:signature:_:)` but for an `async` (or `async throws`) native
    /// symbol. The generated thunk file calls this for each routed async symbol,
    /// supplying a closure that `await`s the real native symbol. Re-registering an
    /// id REPLACES its async thunk (a re-`prepare`d build / module epoch swap).
    @discardableResult
    public func registerAsync(id: Int32, signature: String = "", _ thunk: @escaping AsyncHostThunk) -> PatchHostBridge {
        asyncStore.set(id: id, thunk: thunk)
        return self
    }

    /// Is `id` resolvable as an ASYNC thunk in THIS build? (the async analogue of
    /// `have(_:)` — the `call_async` glue answers a suspend for an unknown async id
    /// with a tagged `.error` resume, so the guest demotes.)
    public func haveAsync(_ id: Int32) -> Bool {
        asyncStore.has(id)
    }

    /// Resolve `id` to a result, AWAITING the registered async thunk. ANY failure
    /// (unknown id, decode error, type mismatch, a stale handle, a thunk throw)
    /// becomes a tagged `.error` — never a crash, never a misdispatch. This is the
    /// async analogue of `call(_:argsBlob:)`; the broker calls it from its resolve
    /// step (on host concurrency, while the guest is suspended).
    public func callAsync(_ id: Int32, argsBlob: [UInt8]) async -> TLVValue {
        guard let thunk = asyncStore.get(id) else {
            return .error("unknown async symbolId \(id)")
        }
        do {
            let decoded = try TLVCodec.decodeArgs(argsBlob)
            return try await thunk(ArgReader(decoded), handles)
        } catch let e as CustomStringConvertible {
            return .error(e.description)
        } catch {
            return .error("\(error)")
        }
    }

    /// Drop every registered async thunk (folded into `teardown()` via this hook —
    /// the controller's `teardown()` clears the sync registry + handles; this
    /// clears the async registry so a module epoch can never leak its async thunks).
    public func teardownAsync() {
        dropAsyncStore()
    }
}

// MARK: - The async-thunk store (a small thread-safe side table on the controller)

/// A process-global, thread-safe side table from symbol id → async thunk, keyed
/// by the controller instance (so multiple loaded modules' controllers don't share
/// async registries). Kept OUT of the `PatchHostBridge` stored properties so this
/// async support is purely additive to the existing controller (no change to its
/// declaration). The table is tiny (one entry per routed async symbol) and is torn
/// down with its controller.
///
/// (An `extension` cannot add a stored property; this object IS that storage,
/// associated 1:1 with a controller. We avoid the ObjC associated-object machinery
/// — which needs `@objc`/NSObject — by keying a global registry on the controller's
/// `ObjectIdentifier`, cleaned up by `teardownAsync()`.)
final class AsyncThunkStore: @unchecked Sendable {
    private let lock = NSLock()
    private var thunks: [Int32: AsyncHostThunk] = [:]

    func set(id: Int32, thunk: @escaping AsyncHostThunk) {
        lock.lock(); defer { lock.unlock() }
        thunks[id] = thunk
    }
    func get(_ id: Int32) -> AsyncHostThunk? {
        lock.lock(); defer { lock.unlock() }
        return thunks[id]
    }
    func has(_ id: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return thunks[id] != nil
    }
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        thunks.removeAll()
    }
}

/// Global controller → async-store map. Each controller lazily gets its own store.
/// Entries are removed by `teardownAsync()`; an un-torn-down controller's entry is
/// released when nothing references the store any longer (we hold it weakly so a
/// dropped controller doesn't leak its store).
private final class _AsyncStoreRegistry: @unchecked Sendable {
    static let shared = _AsyncStoreRegistry()
    private let lock = NSLock()
    private var byController: [ObjectIdentifier: AsyncThunkStore] = [:]

    func store(for c: PatchHostBridge) -> AsyncThunkStore {
        let key = ObjectIdentifier(c)
        lock.lock(); defer { lock.unlock() }
        if let s = byController[key] { return s }
        let s = AsyncThunkStore()
        byController[key] = s
        return s
    }
    func drop(_ c: PatchHostBridge) {
        let key = ObjectIdentifier(c)
        lock.lock(); defer { lock.unlock() }
        byController[key]?.removeAll()
        byController[key] = nil
    }
}

extension PatchHostBridge {
    /// This controller's async-thunk store (lazily created, 1:1 with the controller).
    var asyncStore: AsyncThunkStore { _AsyncStoreRegistry.shared.store(for: self) }
    /// Drop this controller's async store (called by `teardownAsync()`).
    func dropAsyncStore() { _AsyncStoreRegistry.shared.drop(self) }
}
