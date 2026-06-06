# Guest-side async executor contract (CPatchExec)

This directory is the **guest-side contract** for the on-device async/await
executor. It is NOT compiled into the host SDK (these are `wasm32`-target sources
that override the Swift concurrency runtime's hooks — they only build under the
WASM SDK). `CPatchExec` is compiled into any Patch module that ships
`async`/`await` code, alongside the matching `@_cdecl` exports.

## What the guest must provide

`cexec.c` / `include/cexec.h` install a cooperative executor:

* `patch_exec_install()` overrides `swift_task_enqueueGlobal_hook` to FIFO-capture
  every job the Swift runtime wants to run on the (nonexistent) global executor.
* `patch_exec_run_one()` runs one captured job via `swift_job_run` on the generic
  (all-zero) executor.

The guest then exports the **pump contract** the host drives (emitted around the
patched async function):

| Export                          | Signature        | Meaning                                            |
|---------------------------------|------------------|----------------------------------------------------|
| `patch_init`                    | `() -> ()`       | install the executor hook (call once)              |
| `patch_start_<fn>(args…)`       | `(…) -> ()`      | kick off the top-level `Task {}` (enqueues only)   |
| `patch_pump(budget) -> i32`     | `(i32) -> i32`   | run up to `budget` queued jobs; returns # run      |
| `patch_pending() -> i32`        | `() -> i32`      | # jobs currently queued                            |
| `patch_done() -> i32`           | `() -> i32`      | 1 once the top-level Task completed                 |
| `patch_result() -> i32`         | `() -> i32`      | the Task's scalar result (or a packed-i64 blob)    |
| `patch_resolve(token, value)`   | `(i32,i32) -> ()`| resume a host-awaited continuation                 |

For a guest that awaits **host** async work, it imports
`patch_host.async_request(token)` (declared in `cexec.h` with the flat
`import_module`/`import_name` attributes WasmKit accepts) and is resumed by the
host calling `patch_resolve`.

## What the host (this SDK) provides

The host pump driver lives in `Sources/PatchSDK/AsyncPump.swift` +
`AsyncBroker.swift`, surfaced on the `Patch` facade as `runAsync` /
`callAsyncResult` / `callPackedAsync`. The host:

1. calls `patch_init`,
2. invokes the `patch_start_<fn>` kickoff export,
3. loops `patch_pump` until `patch_done == 1`, resolving host-awaited
   continuations via `PatchAsyncBroker` (`patch_host.async_request` → the broker;
   `patch_resolve` ← the pump's stall handler) in between.

The export/import names are configurable via `AsyncPumpContract` so the contract
can evolve without a host change.
