// AsyncBroker.swift — the HOST side of the guest↔host async round-trip.
// ======================================================================
// A guest async body that awaits real host I/O (network, disk, a bridge) calls
// the `patch_host.async_request(token)` import to say "I am suspended awaiting a
// value for this token". The host owns the real concurrency: it performs the work
// (on its own run loop / via a bridge) and later calls the guest's
// `patch_resolve(token, value)` export to resume the continuation. The guest's
// own executor only ever pumps pure continuations; the host owns the I/O.
//
// `PatchAsyncBroker` captures the tokens the guest requested during a pump round.
// The default `valueProvider` is deterministic (token·100+7), which lets the SDK
// test the round-trip with no real I/O; a
// real app supplies a provider that maps a token → an actual host result (e.g.
// the resolved value of a bridged async call).

import WasmKit

/// Records the host-async requests a guest made (token → owed value) so the pump
/// loop can resolve them. Thread-confined to the runtime's serial call queue.
public final class PatchAsyncBroker: @unchecked Sendable {
    /// token → the value the host will resolve it with (its "I/O result").
    private var owed: [(token: Int32, value: Int32)] = []
    /// Maps a request token to the value the host resolves it with. Override to
    /// plug in real host async results; the default mirrors the proof.
    public var valueProvider: (Int32) -> Int32

    public init(valueProvider: @escaping (Int32) -> Int32 = { $0 * 100 + 7 }) {
        self.valueProvider = valueProvider
    }

    /// Called from the `patch_host.async_request` host function when the guest
    /// suspends awaiting `token`.
    public func enqueue(token: Int32) {
        owed.append((token, valueProvider(token)))
    }

    /// Drain + return the currently owed (token, value) pairs.
    public func drain() -> [(token: Int32, value: Int32)] {
        defer { owed.removeAll() }
        return owed
    }

    /// Whether anything is owed (used by the pump's stall handler).
    public var hasPending: Bool { !owed.isEmpty }

    /// The host-import name the guest's CExec shim declares
    /// (`__attribute__((import_module("patch_host"), import_name("async_request")))`).
    public static let importModule = "patch_host"
    public static let importName = "async_request"

    /// Define the `patch_host.async_request(token)` host function into `imports`,
    /// recording each requested token into this broker.
    public func link(into imports: inout Imports, store: Store) {
        imports.define(
            module: PatchAsyncBroker.importModule,
            name: PatchAsyncBroker.importName,
            Function(store: store, parameters: [.i32], results: []) { [weak self] _, args in
                let token = Int32(bitPattern: args[0].i32)
                self?.enqueue(token: token)
                return []
            }
        )
    }

    /// A `hostResolve` callback for `WASMRuntime.pumpToCompletion`: resolves every
    /// owed continuation via the guest's `patch_resolve` and reports progress.
    public func resolveCallback(_ contract: AsyncPumpContract = .default)
        -> (WASMRuntime) throws -> Bool {
        { [weak self] runtime in
            guard let self else { return false }
            let owed = self.drain()
            if owed.isEmpty { return false }
            for r in owed {
                try runtime.resolve(token: r.token, value: r.value, contract: contract)
            }
            return true
        }
    }
}
