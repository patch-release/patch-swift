#include "cexec.h"

// Simple bounded FIFO ring of captured job pointers. Single-threaded WASI, so
// no locking needed.
#define PATCH_QUEUE_CAP 4096
static PatchJob *g_queue[PATCH_QUEUE_CAP];
static int g_head = 0; // pop index
static int g_tail = 0; // push index
static int g_count = 0;

void patch_exec_push(PatchJob *job) {
    if (g_count >= PATCH_QUEUE_CAP) {
        // Overflow: drop. (In practice the depth stays tiny for cooperative
        // chains; a real impl would grow.)
        return;
    }
    g_queue[g_tail] = job;
    g_tail = (g_tail + 1) % PATCH_QUEUE_CAP;
    g_count++;
}

PatchJob *patch_exec_pop(void) {
    if (g_count == 0) return 0;
    PatchJob *j = g_queue[g_head];
    g_head = (g_head + 1) % PATCH_QUEUE_CAP;
    g_count--;
    return j;
}

int patch_exec_pending(void) { return g_count; }

// The hook the runtime calls instead of its default global enqueue. We simply
// capture the job; the host pump runs it later. We deliberately ignore
// `original` (the single-threaded WASI default would do nothing useful here).
static SWIFTCC void patch_enqueue_hook(PatchJob *job, PatchEnqueueOriginal original) {
    (void)original;
    patch_exec_push(job);
}

void patch_exec_install(void) {
    swift_task_enqueueGlobal_hook = patch_enqueue_hook;
}

int patch_exec_run_one(void) {
    PatchJob *j = patch_exec_pop();
    if (!j) return 0;
    // Run on the generic executor: an all-zero SerialExecutorRef (4 words).
    swift_job_run(j, 0, 0, 0, 0);
    return 1;
}
