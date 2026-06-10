import Foundation
import WasmKit

// MARK: - Breakthrough #6 — NETWORKING (URLSession) async host bridge
//
// The async sibling of the #8 host-bridge family. The dominant real-app async
// shape — a function that is `async` ONLY because it `await`s `URLSession`, then
// decodes JSON + runs value-type logic — runs in WASM by rewriting the
// `URLSession.shared.data(from:)` / `.data(for:)` leaf (CLI FusionRewriter) onto
// the async imports this file serves. Proven end-to-end in executing WASM
// (docs/ENGINEERING.md §2 breakthrough #6, 6/6 incl a live HTTPS fetch).
//
// ## The async-suspend contract (matches the engine's emitted shims + the C ABI)
//   guest import  `patch_host.http_get(urlPtr,urlLen,token) -> ()`           [SUSPEND]
//   guest import  `patch_host.http_request(mPtr,mLen,uPtr,uLen,bPtr,bLen,token) -> ()`
//   guest export  `patch_resolve_http(token, dataPtr, dataLen, status) -> ()` [RESUME]
//
// The guest stashes a continuation under `token` and calls the import (returns
// void → the guest is SUSPENDED, the pump runs no more jobs for that chain). The
// host owns the real concurrency: it performs the real `URLSession` fetch on its
// own run loop, writes the response bytes into GUEST linear memory via the guest's
// exported `patch_malloc`, and resumes the continuation by invoking
// `patch_resolve_http(token, ptr, len, status)`. cookies/TLS/auth stay HOST-side
// (the security win — credentials never enter WASM).
//
// v1 scope (the prototype's honest limits): GET + simple one-buffer POST
// request/response + decode. Streaming / websockets / multipart-upload / download /
// `URLSessionDelegate` subclasses are OUT (kept native by the registry's
// mustStayNative split). Header dictionaries + response MIME are not yet marshalled
// (Data + statusCode only).

/// Records the host-async HTTP requests a guest made (token → owed request) and the
/// fetch results to resolve them with. Thread-confined to the runtime's serial call
/// queue (the SDK drives the pump on that queue), so no internal locking is needed.
///
/// The `fetch` closure is injectable: the default performs a REAL `URLSession`
/// request; tests inject a mock (a local server or an in-memory table) so CI does no
/// real outbound network. The host owns concurrency — `fetch` is invoked
/// synchronously from the pump's stall handler (the guest is suspended, so there is
/// nothing else to run), which is the correct v1 model: one suspended chain per
/// in-flight request, resolved before the next pump round.
public final class PatchHTTPBroker: @unchecked Sendable {
    /// A host fetch: (method, url, body) → (responseBytes, httpStatus). A status of
    /// 0 (or any non-2xx) is passed through to the guest, which decides the error
    /// path (the prototype's `404 -> badStatus(404)` shape). `nil` body on failure.
    public typealias Fetch = @Sendable (_ method: String, _ url: String, _ body: [UInt8])
        -> (body: [UInt8], status: Int32)

    /// One owed request captured while the guest was suspended.
    public struct Pending: Sendable {
        public let token: Int32
        public let method: String
        public let url: String
        public let body: [UInt8]
    }

    private var pending: [Pending] = []
    private let fetchFn: Fetch

    /// The guest export the host calls to resume a suspended fetch.
    public static let resolveExport = "patch_resolve_http"
    /// The import module + names the guest's generated C header declares.
    public static let importModule = "patch_host"
    public static let getImportName = "http_get"
    public static let requestImportName = "http_request"

    /// Designated init: inject the host fetch (testable / mockable).
    public init(fetch: @escaping Fetch) {
        self.fetchFn = fetch
    }

    /// Convenience default init: a REAL `URLSession` fetch. Blocking is fine here —
    /// the guest is suspended awaiting exactly this value, so there is no other guest
    /// work to interleave; the host owns concurrency on its own session/run loop.
    /// NOTE: not used in CI (tests inject a mock); on device this is the real path.
    public convenience init(session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.init(fetch: { method, urlString, body in
            guard let url = URL(string: urlString) else { return ([], 0) }
            var req = URLRequest(url: url)
            req.httpMethod = method
            if !body.isEmpty { req.httpBody = Data(body) }
            let sem = DispatchSemaphore(value: 0)
            let box = _HTTPResultBox()
            let task = session.dataTask(with: req) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                box.set(body: data.map { [UInt8]($0) } ?? [], status: Int32(status))
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + timeout)
            return box.get()
        })
    }

    // MARK: Enqueue (called from the import host functions)

    /// `http_get(token, url)` — the guest suspended awaiting a GET for `token`.
    public func enqueueGet(token: Int32, url: String) {
        pending.append(Pending(token: token, method: "GET", url: url, body: []))
    }

    /// `http_request(token, method, url, body)` — the guest suspended awaiting a
    /// method/url/body request for `token`.
    public func enqueueRequest(token: Int32, method: String, url: String, body: [UInt8]) {
        let m = method.isEmpty ? "GET" : method
        pending.append(Pending(token: token, method: m, url: url, body: body))
    }

    /// Whether any request is owed (the pump's stall handler checks this).
    public var hasPending: Bool { !pending.isEmpty }

    /// Drain the owed requests (FIFO).
    public func drain() -> [Pending] {
        defer { pending.removeAll() }
        return pending
    }

    // MARK: Host bridge registration

    /// Register `patch_host.http_get` + `patch_host.http_request` into `imports`,
    /// recording each suspended request into this broker (the host returns nothing —
    /// the guest is now suspended on its continuation).
    public func register(into imports: inout Imports, store: Store) {
        imports.host(Self.importModule, Self.getImportName, [.i32, .i32, .i32], [], store: store) { [weak self] caller, args in
            let ctx = BridgeContext(caller: caller)
            let url = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let token = Int32(bitPattern: args[2].i32)
            self?.enqueueGet(token: token, url: url)
            return []
        }
        imports.host(Self.importModule, Self.requestImportName,
                     [.i32, .i32, .i32, .i32, .i32, .i32, .i32], [], store: store) { [weak self] caller, args in
            let ctx = BridgeContext(caller: caller)
            let method = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            let url = try ctx.readString(ptr: args[2].i32, len: args[3].i32)
            let body = try ctx.readBytes(ptr: args[4].i32, len: args[5].i32)
            let token = Int32(bitPattern: args[6].i32)
            self?.enqueueRequest(token: token, method: method, url: url, body: body)
            return []
        }
    }

    // MARK: Resolve (the pump's stall handler)

    /// Resolve every owed request: perform the host fetch, write the response bytes
    /// into GUEST linear memory (via the guest's `patch_malloc`, surfaced as
    /// `runtime.writeBuffer`), and resume the continuation by invoking the guest's
    /// `patch_resolve_http(token, ptr, len, status)`. Returns whether any progress
    /// was made (so the pump knows there is more to run).
    @discardableResult
    public func resolvePending(_ runtime: WASMRuntime) throws -> Bool {
        let owed = drain()
        if owed.isEmpty { return false }
        for req in owed {
            let result = fetchFn(req.method, req.url, req.body)
            // Write the body into GUEST memory (empty body → (0,0), a valid resume).
            let (ptr, len) = result.body.isEmpty ? (UInt32(0), UInt32(0))
                                                 : try runtime.writeBuffer(result.body)
            _ = try runtime.invoke(Self.resolveExport, [
                .i32(UInt32(bitPattern: req.token)),
                .i32(ptr), .i32(len),
                .i32(UInt32(bitPattern: result.status)),
            ])
        }
        return true
    }

    /// A `hostResolve` callback for `WASMRuntime.pumpToCompletion`: resolves every
    /// owed HTTP request. Compose with the plain `PatchAsyncBroker` resolver when a
    /// guest awaits BOTH host values and fetches (see `combinedResolve`).
    public func resolveCallback() -> (WASMRuntime) throws -> Bool {
        { [weak self] runtime in try self?.resolvePending(runtime) ?? false }
    }
}

/// A `hostResolve` that drains BOTH a `PatchAsyncBroker` (bare-i32 host awaits) and a
/// `PatchHTTPBroker` (fetches) in one stall round — for a guest that mixes the two.
/// Reports progress if EITHER resolved something.
public func combinedResolve(async asyncBroker: PatchAsyncBroker?,
                            http httpBroker: PatchHTTPBroker?,
                            contract: AsyncPumpContract = .default) -> (WASMRuntime) throws -> Bool {
    { runtime in
        var progressed = false
        if let httpBroker { progressed = try httpBroker.resolvePending(runtime) || progressed }
        if let asyncBroker {
            let owed = asyncBroker.drain()
            if !owed.isEmpty {
                for r in owed { try runtime.resolve(token: r.token, value: r.value, contract: contract) }
                progressed = true
            }
        }
        return progressed
    }
}

/// Thread-safe box so the blocking URLSession completion can hand its result back.
private final class _HTTPResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bodyValue: [UInt8] = []
    private var statusValue: Int32 = 0
    func set(body: [UInt8], status: Int32) {
        lock.lock(); bodyValue = body; statusValue = status; lock.unlock()
    }
    func get() -> (body: [UInt8], status: Int32) {
        lock.lock(); defer { lock.unlock() }; return (bodyValue, statusValue)
    }
}

// MARK: - Bridge wrapper (for `BridgeRegistry.register(_:)` / registerDefaults)

/// A `Bridge` that serves the networking imports backed by a `PatchHTTPBroker`.
/// Registered into `registerDefaults()` with a real-`URLSession` broker (device
/// path); tests register their own broker explicitly with a mock fetch.
///
/// IMPORTANT: this is distinct from the existing synchronous `URLSessionBridge`
/// (module `patch`, name `http_get`, blocking, body-only). This bridge is under the
/// flat `patch_host` namespace with the async-suspend `(…,token)->()` shape — no
/// collision (different module).
public struct PatchHTTPBridge: Bridge {
    public let module = PatchHTTPBroker.importModule
    public let broker: PatchHTTPBroker

    /// Use a real-`URLSession` broker by default.
    public init(broker: PatchHTTPBroker = PatchHTTPBroker()) {
        self.broker = broker
    }

    public func register(into imports: inout Imports, store: Store) {
        broker.register(into: &imports, store: store)
    }
}
