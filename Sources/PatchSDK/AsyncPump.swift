// AsyncPump.swift — the on-device async/await EXECUTOR PUMP for Patch modules.
// ============================================================================
// WasmKit is single-threaded and has no event loop, so a guest `Task {...}` body
// never runs on its own: the Swift concurrency runtime would enqueue the job on a
// global executor that doesn't exist in the WASI sandbox. The PROVEN mechanism
// (experiments/async-exec, ASYNC-BREAKTHROUGH.md) is a HOST-DRIVEN cooperative
// executor:
//
//   * GUEST side (the codegen contract in sdk/guest-contract/CPatchExec): a C
//     shim overrides `swift_task_enqueueGlobal_hook` to FIFO-capture every job
//     the runtime wants to run, and exports a `patch_pump(budget)` that runs up
//     to `budget` captured jobs via `swift_job_run`. The host pump IS the event
//     loop. A guest that awaits HOST async work calls a `patch_host.async_request
//     (token)` import and is later resumed by the host calling the guest's
//     `patch_resolve(token, value)` export.
//
//   * HOST side (this file): `pumpToCompletion(...)` repeatedly calls the guest's
//     `patch_pump` export until the top-level Task signals done (`patch_done`),
//     resolving any host-async continuations the guest is suspended on in between.
//
// This is the productized version of the proven `experiments/async-exec` host
// driver, moved into the SDK runtime and wired through the serial call queue so
// it is hot-swap-safe.

import WasmKit

/// The set of export/import names the async pump contract uses. These match the
/// `@_cdecl` exports the guest codegen emits (see sdk/guest-contract) and the
/// `experiments/async-exec` proof. Names are configurable so the engine can
/// evolve the contract without changing the host.
public struct AsyncPumpContract: Sendable {
    /// Export the guest installs the executor hook (call once before a Task).
    public var install: String
    /// Export that runs up to `budget` queued jobs; returns the number run.
    public var pump: String
    /// Export: number of jobs currently queued (for forward-progress checks).
    public var pending: String
    /// Export: 1 once the top-level Task completed, else 0.
    public var done: String
    /// Export the host calls to resolve a host-async continuation: `(token, value)`.
    public var resolve: String
    /// Number of jobs to run per `pump` call.
    public var budget: Int32

    public init(install: String = "patch_init",
                pump: String = "patch_pump",
                pending: String = "patch_pending",
                done: String = "patch_done",
                resolve: String = "patch_resolve",
                budget: Int32 = 256) {
        self.install = install
        self.pump = pump
        self.pending = pending
        self.done = done
        self.resolve = resolve
        self.budget = budget
    }

    public static let `default` = AsyncPumpContract()
}

/// Errors specific to driving the async pump.
public enum AsyncPumpError: Error, CustomStringConvertible, Equatable {
    /// The guest never signaled completion within the iteration cap (a likely
    /// deadlock: a Task awaiting host work the host never resolves, or a runaway).
    case neverCompleted(rounds: Int)
    /// The pump made no forward progress: no jobs ran AND the host resolver had
    /// nothing to resolve, yet the Task is not done (a stuck continuation).
    case stuck(pending: Int32)

    public var description: String {
        switch self {
        case .neverCompleted(let r): return "async Task never completed after \(r) pump rounds"
        case .stuck(let p): return "async pump stuck: no progress, \(p) jobs pending, not done"
        }
    }
}

extension WASMRuntime {
    /// Whether this module exposes the async pump contract (so callers can decide
    /// to drive the pump vs. a plain sync invoke).
    public func supportsAsyncPump(_ contract: AsyncPumpContract = .default) -> Bool {
        hasFunction(contract.pump) && hasFunction(contract.done)
    }

    /// Install the guest's cooperative-executor hook (idempotent). Safe to call
    /// once per kicked-off Task chain; a no-op if the module has no installer.
    public func installAsyncExecutor(_ contract: AsyncPumpContract = .default) throws {
        guard hasFunction(contract.install) else { return }
        _ = try invoke(contract.install)
    }

    /// Drive the guest's cooperative executor to completion.
    ///
    /// After the caller has KICKED OFF a top-level Task (by invoking some
    /// `patch_start_*`-style export which enqueues — but does not run — the Task),
    /// this loops `patch_pump` until `patch_done == 1`. When the pump makes no
    /// progress (the guest is suspended awaiting HOST async work), `hostResolve`
    /// is called; it should resolve any owed continuations by invoking the guest's
    /// `patch_resolve(token, value)` and return `true` if it resolved at least one
    /// (i.e. there is more work to pump). Returning `false` with the Task not done
    /// means a genuine deadlock and surfaces `AsyncPumpError.stuck`.
    ///
    /// - Parameters:
    ///   - contract: the export/import names + per-pump budget.
    ///   - maxRounds: safety cap on pump iterations (deadlock guard).
    ///   - hostResolve: invoked when the pump stalls; resolves host-async
    ///       continuations. Receives `self` so it can call `resolve(token:value:)`.
    ///       Returns whether it made progress.
    @discardableResult
    public func pumpToCompletion(
        contract: AsyncPumpContract = .default,
        maxRounds: Int = 1_000_000,
        hostResolve: ((WASMRuntime) throws -> Bool)? = nil
    ) throws -> Int {
        var rounds = 0
        while try isDone(contract) == false {
            let ran = try pumpOnce(contract)
            if ran == 0 {
                // The pure-continuation queue is empty. Either the guest is
                // suspended on host async work (resolve it) or it is truly stuck.
                let progressed = try hostResolve?(self) ?? false
                if !progressed {
                    throw AsyncPumpError.stuck(pending: try pendingCount(contract))
                }
            }
            rounds += 1
            if rounds >= maxRounds { throw AsyncPumpError.neverCompleted(rounds: rounds) }
        }
        return rounds
    }

    /// Run one `patch_pump(budget)` and return how many jobs ran.
    public func pumpOnce(_ contract: AsyncPumpContract = .default) throws -> Int32 {
        let r = try invoke(contract.pump, [.i32(UInt32(bitPattern: contract.budget))])
        guard let first = r.first else { return 0 }
        return Int32(bitPattern: first.i32)
    }

    /// Whether the top-level Task has completed.
    public func isDone(_ contract: AsyncPumpContract = .default) throws -> Bool {
        let r = try invoke(contract.done)
        return (r.first?.i32 ?? 0) != 0
    }

    /// Number of jobs currently queued in the guest's executor.
    public func pendingCount(_ contract: AsyncPumpContract = .default) throws -> Int32 {
        guard hasFunction(contract.pending) else { return 0 }
        let r = try invoke(contract.pending)
        return Int32(bitPattern: r.first?.i32 ?? 0)
    }

    /// Resolve a host-async continuation: hand the guest the value it was awaiting
    /// for `token`. After this the guest's resumed continuation is re-enqueued
    /// through the executor hook and the next `pump` runs it.
    public func resolve(token: Int32, value: Int32,
                        contract: AsyncPumpContract = .default) throws {
        _ = try invoke(contract.resolve,
                       [.i32(UInt32(bitPattern: token)), .i32(UInt32(bitPattern: value))])
    }
}
