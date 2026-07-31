// SPDX-License-Identifier: MIT

import Foundation

// ===========================================================================
// THE HANDLE TABLE (DESIGN §3.2 — the by-reference proxy).
//
// WASM linear memory can never hold a live native pointer, and the engine can
// never reconstruct a non-Codable reference type (a class instance, NSObject,
// a third-party SDK object, a Foundation reference like NumberFormatter). So a
// constructed native reference object lives HERE — the host holds the ONLY
// strong reference — keyed by an opaque, monotonically-increasing Int32 the
// guest carries.
//
//   * `retain(_:)`  — store an object, return its opaque handle.
//   * `resolve(_:)` — map a handle back to the live object (nil if stale/freed).
//   * `release(_:)` — drop the host's strong ref (the guest's deinit calls this).
//   * `removeAll()` — drop the WHOLE table on module teardown.
//
// Ids are MONOTONIC / GENERATIONAL: a freed or stale handle from a previous
// module epoch resolves to nil (a clean tagged error), NEVER to a wrong reused
// object — because `next` only ever increases (it never reuses a freed slot id)
// within a table's lifetime. On the rare 32-bit wraparound the counter skips 0
// (0 is reserved as "no handle").
//
// THREAD CONFINEMENT: the SDK drives the guest on a single caller thread (the
// serial `Patch.callQueue` + the async pump). The handle table and dispatch are
// confined to that thread, so a non-thread-safe native object held by handle is
// only ever touched on that one thread. A small NSLock is kept anyway so a test
// (or a future multi-thread driver) can't data-race the dictionary; it is
// uncontended on the hot path.
// ===========================================================================

/// A host-side table mapping opaque Int32 handles to live native objects. The
/// host holds the only strong reference to each retained object for as long as
/// its handle is live; the guest owns the handle's lifetime via `release`.
public final class HandleTable: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Int32: AnyObject] = [:]
    /// Monotonic id source. Starts at 1 (0 == "no handle" / nil result).
    private var next: Int32 = 1

    public init() {}

    /// Retain `obj` and return its opaque handle. The returned id is unique for
    /// the table's lifetime (monotonic; never reuses a freed slot).
    public func retain(_ obj: AnyObject) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        let id = next
        next &+= 1
        if next == 0 { next = 1 }   // wraparound: skip the reserved 0
        slots[id] = obj
        return id
    }

    /// Resolve a handle to its live object, or nil if the handle is stale /
    /// already released / never issued.
    public func resolve(_ id: Int32) -> AnyObject? {
        lock.lock(); defer { lock.unlock() }
        return slots[id]
    }

    /// Resolve and cast to an expected type. Returns nil if the handle is stale
    /// OR resolves to a different type (an ABI-stability mismatch → the caller
    /// returns a tagged `.error`). This is the cast a method/property thunk uses.
    public func resolve<T>(_ id: Int32, as type: T.Type) -> T? {
        resolve(id) as? T
    }

    /// Drop the host's strong reference to the object behind `id` (the guest's
    /// proxy `deinit` calls this). A no-op for an unknown/already-freed id.
    public func release(_ id: Int32) {
        lock.lock(); defer { lock.unlock() }
        slots[id] = nil
    }

    /// Drop the ENTIRE table — every retained native object is released. Called
    /// on module teardown so a module epoch can never leak its handles.
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        slots.removeAll()
    }

    /// Number of live handles. Used by the leak-free assertion in tests (after a
    /// balanced construct/release sequence this must be 0).
    public var liveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return slots.count
    }
}
