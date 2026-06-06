#ifndef PATCH_CEXEC_H
#define PATCH_CEXEC_H

#include <stdint.h>
#include <stddef.h>

// Opaque Swift runtime Job pointer. The Swift concurrency runtime represents a
// schedulable unit of work as `swift::Job*`. We never dereference it from C; we
// only stash the pointer and hand it back to `swift_job_run`.
typedef void PatchJob;

// ---------------------------------------------------------------------------
// Swift concurrency runtime hooks (declared by the runtime, defined in
// libswift_Concurrency.a). `swift_task_enqueueGlobal_hook` is a writable global
// function pointer: if non-null, the runtime calls it INSTEAD of its default
// global-executor enqueue. The single-threaded WASI build has no real global
// executor thread, so overriding this hook is the supported way to capture jobs
// and drive them from a host-controlled pump.
//
//   void hook(Job *job, swift_task_enqueueGlobalOriginalFunction original)
//
// Both the hook and the "original" are declared SWIFT_CC(swift): the Swift
// calling convention threads an implicit `self` + `error` context pair, so at
// the wasm ABI each of these appears as 2 extra i32 params (the runtime's
// indirect call expects (i32 job, i32 original, i32 self, i32 error) -> ()).
// We mark them __attribute__((swiftcall)) so clang emits the matching ABI.
// ---------------------------------------------------------------------------
#define SWIFTCC __attribute__((swiftcall))

typedef SWIFTCC void (*PatchEnqueueOriginal)(PatchJob *job);
typedef SWIFTCC void (*PatchEnqueueHook)(PatchJob *job, PatchEnqueueOriginal original);

extern PatchEnqueueHook swift_task_enqueueGlobal_hook;

// Runs one job to its next suspension point (or completion). Provided by the
// concurrency runtime. On wasm32 the verified ABI is:
//   swift_job_run : (i32 job, i32, i32, i32, i32) -> void
// i.e. Job* + a 4-word SerialExecutorRef passed by value. The "generic"
// executor is all-zero, which is what the global pool uses for unbound jobs.
extern void swift_job_run(PatchJob *job, uintptr_t e0, uintptr_t e1,
                          uintptr_t e2, uintptr_t e3);

// Install our enqueue hook. Idempotent.
void patch_exec_install(void);

// FIFO of captured jobs (kept in C to avoid Swift/C reentrancy during enqueue).
void patch_exec_push(PatchJob *job);
PatchJob *patch_exec_pop(void);
int patch_exec_pending(void);

// Run a single queued job on the generic executor. Returns 1 if a job ran,
// 0 if the queue was empty.
int patch_exec_run_one(void);

// ---------------------------------------------------------------------------
// Host import for the async + host-ABI fusion. The guest calls this to tell the
// host "I am awaiting a value for `token`"; the host does the real async work on
// its own run loop and later calls the guest export `patch_resolve(token,val)`.
// Declared with import_module/import_name -> a flat WASM import WasmKit accepts.
// ---------------------------------------------------------------------------
__attribute__((import_module("patch_host"), import_name("async_request")))
void host_async_request(int32_t token);

#endif
