// SPDX-License-Identifier: MIT

import Foundation
import WasmKit
import PatchHostBridge

// ===========================================================================
// LEVER #2 — SDK ACTIVATION WIRING (the runtime hand-off).
//
// This is the facade-side half that makes a shipped module which routes native
// calls through the GENERALIZED host bridge automatically resolve them on-device.
// It owns:
//
//   1. a SHARED `PatchHostBridge` (`Patch.shared.hostBridge`) — the registry +
//      handle table + manifest for the active module set. Process-lifetime owned,
//      but its PER-EPOCH state (handles + manifest) is reset on every module-set
//      change (mirrors how `activate`/`hotSwap` already tear down the prior
//      runtimes + drop the value cache).
//
//   2. the IMPORT WIRING — `GenericHostBridge(bridge:).register(into:&imports,…)`
//      layered into every instantiated module's import set, alongside the curated
//      `patch_host.*` bridges. They coexist: the three generic names (call /
//      release / have) don't collide with any curated leaf. A module that doesn't
//      declare the generic imports just has them DEFINED-but-unused (exactly like
//      every curated bridge today), so it behaves identically to before — additive,
//      demote-safe.
//
//   3. the APP-FACING REGISTRATION HAND-OFF — `Patch.shared.onRegisterHostBridges`.
//      The engine's `prepare` step generates, INTO THE APP TARGET, a
//      `__patchRegisterHostBridges(_ bridge:)` that calls `bridge.register(id:…)`
//      for each routed symbol with a closure that calls the REAL native symbol
//      (App-Store-clean — a compiled-in, statically type-checked dispatch table,
//      NOT runtime symbol lookup; DESIGN §4.2). The app passes that function to
//      `Patch.shared.onRegisterHostBridges(__patchRegisterHostBridges)` once (at
//      `Patch.configure`); the SDK RE-RUNS it after every module-set change so the
//      registry is always consistent with the live app binary (re-registration is
//      idempotent, last-wins).
//
//   4. the MANIFEST LOAD — after activation, the SDK reads the new module's
//      `patch_host_symbols` export (a JSON side table the engine ships) via
//      `PatchHostBridge.loadManifest`, so `have()`/diagnostics see the declared
//      routed-symbol set. An id the app didn't register a thunk for → `have()==0`
//      → the guest's emitted fallback goes native (fail-closed; DESIGN §5).
//
// LIFETIME MAP (handles vs thunks vs manifest):
//   * THUNKS (the registry) are APP-BINARY-scoped (the compiled-in dispatch table)
//     — identical across patch epochs. They are re-derived per epoch by re-running
//     the registration hook (idempotent), so they survive a mid-session patch swap.
//   * HANDLES are PATCH/EPOCH-scoped (live native objects a routed call constructed)
//     — cleared on every module-set change so a stale handle from a previous epoch
//     can never resolve to a wrong object (HandleTable ids are monotonic anyway).
//   * the MANIFEST is PER-MODULE — reloaded from the freshly-activated module's
//     `patch_host_symbols` export on every change (empty when the module ships none).
// ===========================================================================

extension Patch {

    /// The engine ships the routed-symbol side table under this guest export name
    /// (packed `(ptr,len) -> i64` ABI; input ignored — same shape as
    /// `patch_view_manifest`). The SDK reads it once per module activation.
    public static let hostSymbolManifestExportName = "patch_host_symbols"

    // MARK: - Import composition

    /// Compose the generic-bridge imports onto a curated-bridge import closure, so
    /// every instantiated module gets the THREE `patch_host.*` generic imports
    /// (call/release/have) backed by the shared `hostBridge`, layered on top of the
    /// curated bridges. `instantiateModuleSet` calls this to build the per-module
    /// `hostImports`. Coexistence is safe: the generic names don't collide with any
    /// curated leaf, and defining unused imports never breaks instantiation.
    func composedHostImports() -> (inout Imports, Store) -> Void {
        let curated = bridges.hostImports()
        let generic = GenericHostBridge(bridge: hostBridge)
        return { imports, store in
            curated(&imports, store)
            generic.register(into: &imports, store: store)
        }
    }

    // MARK: - App-facing registration hand-off

    /// Install the app's generated host-bridge registration closure. The engine's
    /// `prepare` step emits a `__patchRegisterHostBridges(_ bridge: PatchHostBridge)`
    /// into the app target; pass it here ONCE (at `Patch.configure`):
    ///
    /// ```swift
    /// Patch.shared.onRegisterHostBridges(__patchRegisterHostBridges)
    /// ```
    ///
    /// The SDK invokes it immediately (so a module already active gets its thunks)
    /// and re-invokes it after every module-set change (so the registry tracks the
    /// live app binary across patch swaps). Re-registration is idempotent (last
    /// thunk wins per id), so calling this more than once is safe.
    @discardableResult
    public func onRegisterHostBridges(
        _ register: @escaping @Sendable (PatchHostBridge) -> Void
    ) -> Patch {
        setHostBridgeRegistrar(register)
        // Apply immediately against the shared bridge so a module activated BEFORE
        // the app installed its registrar (e.g. a synchronous first-frame activation)
        // still resolves its routed calls on the next dispatch.
        register(hostBridge)
        return self
    }

    // MARK: - Per-epoch lifecycle (called from activate / hotSwap / deactivate)

    /// Reset the shared bridge for a NEW module set and re-prime it: drop every live
    /// handle from the prior epoch, reload the new module's `patch_host_symbols`
    /// manifest, and re-run the app registrar so the registry matches the live
    /// binary. Keeps the registry's compiled-in thunks (app-binary-scoped) intact —
    /// they are simply refreshed, not wiped — so a mid-session patch swap never
    /// loses the app's resolvers. Best-effort + non-throwing: any failure degrades
    /// to "no validated ids" (the registry + tagged-error demote path still hold).
    ///
    /// Call AFTER the new module set is swapped in and `assertUsable`-probed, and
    /// AFTER releasing the write lock (it reads the live runtime via `callPacked`).
    func refreshHostBridgeForActiveModuleSet() {
        // (1) Per-epoch handle reset: a routed call in the prior epoch may have
        //     retained live native objects; drop them so this epoch starts clean and
        //     a stale handle can never resolve to a wrong object.
        hostBridge.handles.removeAll()

        // (2) Reload the routed-symbol manifest from the freshly-activated module.
        //     Absent/garbled → `.empty` (degraded-but-safe).
        if hasFunction(Self.hostSymbolManifestExportName),
           let bytes = try? callPacked(Self.hostSymbolManifestExportName, []) {
            hostBridge.loadManifest(bytes)
        } else {
            hostBridge.setManifest(.empty)
        }

        // (3) Re-run the app's registration hook so the registry tracks the live
        //     binary for THIS epoch (idempotent; last thunk wins per id).
        currentHostBridgeRegistrar()?(hostBridge)
    }

    /// Full teardown of the shared bridge (registry + handles + manifest). Called
    /// when the SDK drops its module set entirely (`deactivate`). The registrar is
    /// preserved so a subsequent activation re-primes from the same compiled-in
    /// thunks.
    func teardownHostBridge() {
        hostBridge.teardown()
    }
}
