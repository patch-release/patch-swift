// SPDX-License-Identifier: MIT

import Foundation

// ===========================================================================
// PatchHostBridge — the SDK host runtime for the GENERALIZED "call what's
// already linked" bridge (Lever #2, part A).
//
// This is the production port of experiments/host-bridge-generalized/host. It
// owns the THREE pieces a generic host call needs:
//
//   1. the SYMBOL REGISTRY      — id -> a native thunk closure (the only thing
//                                  that grows per routed symbol; NO new WASM
//                                  import / C decl / Swift shim per leaf)
//   2. the HANDLE TABLE         — opaque Int32 -> live native reference objects
//   3. the SYMBOL MANIFEST      — the engine's `patch_host_symbols` side table,
//                                  validated against the registry
//
// The three generic WASM imports (`patch_host.call/.release/.have`) are wired
// into WasmKit by `GenericHostBridge` (Bridge.swift), which dispatches into THIS
// controller. Keeping the dispatch logic here (Foundation-only, no WasmKit) lets
// it be unit-tested directly and keeps the WasmKit-facing glue thin.
//
// PUBLIC REGISTRATION API (what the build-time resolver-thunk generator emits
// calls to): `register(id:signature:_:)`. The generated thunk file calls it once
// per routed symbol, supplying a typed closure that calls the REAL native symbol
// (e.g. `{ args in .f64(PricingEngine.discount(subtotal: try args.f64(0),
// tier: Int(try args.i64(1)))) }`). The closure compiles against the app's real
// types — this is a compiled-in, statically type-checked dispatch table keyed by
// the engine's symbol ids, NOT runtime symbol lookup (App-Store-clean; see
// DESIGN §4.2).
// ===========================================================================

/// A registered native thunk: takes the decoded args (via `ArgReader`) and the
/// shared handle table, returns one `TLVValue`. A thunk MAY throw — the
/// dispatcher converts any thrown error to a tagged `.error` result, which the
/// guest's emitted wrapper treats as "demote this call to native". So a thunk
/// can use `try args.f64(0)` / `guard … else { throw … }` freely; failure is
/// always the safe demote path.
public typealias HostThunk = @Sendable (_ args: ArgReader, _ handles: HandleTable) throws -> TLVValue

/// The generalized host-bridge controller. Thread-safe; one instance backs a
/// loaded module's generic-bridge sub-module. Drop (or `teardown()`) on module
/// teardown to release every handle.
public final class PatchHostBridge: @unchecked Sendable {

    /// The shared handle table for by-reference native objects.
    public let handles: HandleTable

    private let lock = NSLock()
    private var registry: [Int32: HostThunk] = [:]
    private var manifest: HostSymbolManifest = .empty

    public init(handles: HandleTable = HandleTable()) {
        self.handles = handles
    }

    // MARK: - Public registration API (the resolver-thunk's entry point)

    /// Register a native thunk for `id`. `signature` is the canonical signature
    /// the engine assigned the id to (carried for diagnostics / manifest
    /// cross-check; the resolution is the closure itself, not the string).
    ///
    /// Re-registering the same id REPLACES its thunk (a re-`prepare`d build /
    /// module epoch swap re-registers cleanly). Returns self for chaining.
    @discardableResult
    public func register(id: Int32, signature: String = "", _ thunk: @escaping HostThunk) -> PatchHostBridge {
        lock.lock(); defer { lock.unlock() }
        registry[id] = thunk
        return self
    }

    /// Bulk register. Convenience for a generated thunk file that builds its map
    /// up front.
    @discardableResult
    public func register(_ thunks: [Int32: HostThunk]) -> PatchHostBridge {
        lock.lock(); defer { lock.unlock() }
        for (id, t) in thunks { registry[id] = t }
        return self
    }

    /// Remove a registered thunk (rare; e.g. tearing down a single routed symbol).
    public func unregister(id: Int32) {
        lock.lock(); defer { lock.unlock() }
        registry[id] = nil
    }

    /// Load the engine's `patch_host_symbols` manifest (called once per module
    /// activation). PART A uses it only to validate ids; it does not by itself
    /// register thunks. Defensive parsing (a bad blob → `.empty`).
    public func loadManifest(_ bytes: [UInt8]) {
        let parsed = HostSymbolManifest.parse(bytes)
        lock.lock(); defer { lock.unlock() }
        manifest = parsed
    }

    /// Directly install a parsed manifest (test/engine convenience).
    public func setManifest(_ m: HostSymbolManifest) {
        lock.lock(); defer { lock.unlock() }
        manifest = m
    }

    public var currentManifest: HostSymbolManifest {
        lock.lock(); defer { lock.unlock() }
        return manifest
    }

    // MARK: - The three generic-import operations

    /// `patch_host.have(id)` — is `id` resolvable in THIS build? (1/0)
    ///
    /// "Resolvable" means a thunk is registered for it. (The manifest is the
    /// engine's *intent*; the registry is what the app actually compiled in. An
    /// id the patch routes but the current app build generated no thunk for →
    /// not in the registry → `have()==0` → that call demotes. See DESIGN §5.)
    public func have(_ id: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return registry[id] != nil
    }

    /// `patch_host.call(id, args)` — resolve `id`, dispatch the thunk, return one
    /// `TLVValue`. ANY failure (unknown id, decode error, type mismatch, a stale
    /// handle, a thunk throw) becomes a tagged `.error` — never a crash, never a
    /// misdispatch. This is the demote-safety guarantee.
    ///
    /// `argsBlob` is the raw TLV arg blob from guest memory; the result is the
    /// `TLVValue` the WasmKit glue then encodes back into guest memory.
    public func call(_ id: Int32, argsBlob: [UInt8]) -> TLVValue {
        let thunk: HostThunk?
        lock.lock()
        thunk = registry[id]
        lock.unlock()

        guard let thunk else {
            return .error("unknown symbolId \(id)")
        }
        do {
            let decoded = try TLVCodec.decodeArgs(argsBlob)
            return try thunk(ArgReader(decoded), handles)
        } catch let e as CustomStringConvertible {
            return .error(e.description)
        } catch {
            return .error("\(error)")
        }
    }

    /// `patch_host.release(handle)` — drop the host's strong ref. Idempotent.
    public func release(_ handle: Int32) {
        handles.release(handle)
    }

    // MARK: - Teardown

    /// Drop every registered thunk + every live handle. Called on module
    /// teardown so a module epoch can never leak its handles or thunks.
    public func teardown() {
        handles.removeAll()
        lock.lock(); defer { lock.unlock() }
        registry.removeAll()
        manifest = .empty
    }

    // MARK: - Introspection (diagnostics)

    /// Ids with a registered thunk.
    public var registeredIDs: Set<Int32> {
        lock.lock(); defer { lock.unlock() }
        return Set(registry.keys)
    }
}
