// SPDX-License-Identifier: MIT

import Foundation
import WasmKit

// ===========================================================================
// GenericHostBridge — the WasmKit glue that wires the THREE generic imports
// (`patch_host.call` / `.release` / `.have`) into a runtime's import set, backed
// by a `PatchHostBridge` controller.
//
// This is the ONLY file in the target that imports WasmKit. It mirrors the
// proven prototype host (experiments/host-bridge-generalized/host): read the arg
// blob from guest memory, dispatch through the controller, write the result blob
// back into guest memory via the exported `patch_malloc`, return the packed
// (ptr<<32)|len i64 (0 == void/nil).
//
// It deliberately does NOT depend on PatchSDK (so PatchSDK can depend on this
// target without a cycle). PatchSDK's `BridgeRegistry` adapts it via the
// `registerFunction` raw API or by calling `register(into:store:)` directly. The
// import-module namespace is "patch_host" — the SAME namespace the curated
// Foundation bridges use, but the three names (call/release/have) don't collide
// with any curated leaf.
// ===========================================================================

/// Registers the three generic `patch_host.*` imports into a WasmKit `Imports`,
/// dispatching into a `PatchHostBridge` controller. Construct one per module
/// runtime, pass its `register(into:store:)` as part of the runtime's
/// host-imports, and hold it (and the controller) for the runtime's lifetime.
public struct GenericHostBridge: Sendable {

    /// The import module namespace (matches the SDK's curated `patch_host`).
    public static let module = "patch_host"

    public let bridge: PatchHostBridge

    public init(bridge: PatchHostBridge) {
        self.bridge = bridge
    }

    // MARK: - Guest-memory marshalling (mirrors the SDK's BridgeContext / prototype Ctx)

    /// Read `len` bytes from the caller instance's exported linear memory.
    private static func readBytes(_ caller: Caller, _ ptr: UInt32, _ len: UInt32) throws -> [UInt8] {
        guard let mem = caller.instance?.exports[memory: "memory"] else { throw GlueError.noMemory }
        let all = mem.data
        let start = Int(ptr), end = Int(ptr) + Int(len)
        guard start >= 0, end <= all.count else { throw GlueError.oob(ptr: ptr, len: len) }
        if len == 0 { return [] }
        return [UInt8](all[start..<end])
    }

    /// Write `bytes` into guest memory via the exported `patch_malloc`, returning
    /// the packed (ptr<<32)|len i64 result. Empty bytes → 0 (void/nil). Bounds-
    /// checks the allocator's returned pointer before writing (a buggy/hostile
    /// `patch_malloc` can't corrupt memory — fail closed with an error blob).
    private static func packed(_ caller: Caller, _ bytes: [UInt8]) throws -> Value {
        if bytes.isEmpty { return .i64(0) }
        guard let alloc = caller.instance?.exports[function: "patch_malloc"] else {
            throw GlueError.noAllocator
        }
        let res = try alloc.invoke([.i32(UInt32(bytes.count))])
        guard res.count == 1, case .i32(let ptr) = res[0], ptr != 0 else {
            throw GlueError.allocFailed(bytes.count)
        }
        guard let mem = caller.instance?.exports[memory: "memory"] else { throw GlueError.noMemory }
        guard Int(ptr) >= 0, Int(ptr) + bytes.count <= mem.data.count else {
            throw GlueError.oob(ptr: ptr, len: UInt32(bytes.count))
        }
        mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: bytes.count) { raw in
            raw.copyBytes(from: bytes)
        }
        return .i64((UInt64(ptr) << 32) | UInt64(bytes.count))
    }

    enum GlueError: Error, CustomStringConvertible {
        case noMemory, noAllocator
        case oob(ptr: UInt32, len: UInt32)
        case allocFailed(Int)
        var description: String {
            switch self {
            case .noMemory: return "generic-bridge: instance exports no `memory`"
            case .noAllocator: return "generic-bridge: instance exports no `patch_malloc`"
            case .oob(let p, let l): return "generic-bridge: guest memory OOB (ptr=\(p), len=\(l))"
            case .allocFailed(let n): return "generic-bridge: guest allocator returned null for \(n) bytes"
            }
        }
    }

    // MARK: - Import registration

    /// Define `patch_host.call`, `patch_host.release`, and `patch_host.have` into
    /// `imports`, dispatching into the controller. Layer this on top of the WASI
    /// imports (and any curated bridges) when building a runtime.
    public func register(into imports: inout Imports, store: Store) {
        let bridge = self.bridge

        // call(symbolId: i32, argsPtr: i32, argsLen: i32) -> i64 (packed result blob).
        imports.define(
            module: Self.module, name: "call",
            Function(store: store, parameters: [.i32, .i32, .i32], results: [.i64]) { caller, args in
                let symbolId = Int32(bitPattern: args[0].i32)
                // A failure to even READ the arg blob is itself a tagged error the
                // guest demotes on — resolve it to an `.error` result, never a trap.
                let result: TLVValue
                do {
                    let argBlob = try Self.readBytes(caller, args[1].i32, args[2].i32)
                    result = bridge.call(symbolId, argsBlob: argBlob)
                } catch let e as CustomStringConvertible {
                    result = .error(e.description)
                } catch {
                    result = .error("\(error)")
                }
                // Encode the result blob and write it into guest memory. If the
                // WRITE-BACK itself fails (no allocator / OOB), surface a tagged
                // `.error` blob instead — but if even that can't be written, the
                // only honest signal left is 0 (void/nil); the guest then can't
                // decode a result and its wrapper demotes.
                let blob = TLVCodec.encodeValue(result)
                do {
                    return [try Self.packed(caller, blob)]
                } catch {
                    let errBlob = TLVCodec.encodeValue(.error("\(error)"))
                    if let p = try? Self.packed(caller, errBlob) { return [p] }
                    return [.i64(0)]
                }
            })

        // release(handle: i32) -> void.
        imports.define(
            module: Self.module, name: "release",
            Function(store: store, parameters: [.i32], results: []) { _, args in
                bridge.release(Int32(bitPattern: args[0].i32))
                return []
            })

        // have(symbolId: i32) -> i32 (1/0).
        imports.define(
            module: Self.module, name: "have",
            Function(store: store, parameters: [.i32], results: [.i32]) { _, args in
                [.i32(bridge.have(Int32(bitPattern: args[0].i32)) ? 1 : 0)]
            })

        // If an async-call broker is wired in, ALSO define the async-suspend import.
        // (Defined here so a module that routes BOTH sync and async calls gets all the
        // `patch_host.*` generic imports from one `register`.)
        if let asyncBroker {
            // call_async(symbolId: i32, argsPtr: i32, argsLen: i32, token: i32) -> ()
            // The guest records the call + SUSPENDS (returns void). The host resolves it
            // from the pump stall (asyncResolve) and resumes via patch_resolve_hostcall.
            imports.define(
                module: Self.module, name: PatchAsyncCallBroker.importName,
                Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: []) { caller, args in
                    let symbolId = Int32(bitPattern: args[0].i32)
                    let token = Int32(bitPattern: args[3].i32)
                    // A failure to even READ the arg blob still records a pending call
                    // (with an empty blob) so the suspended guest is always resumed — the
                    // async thunk then sees a decode/arity error → tagged `.error` → demote.
                    let argBlob = (try? Self.readBytes(caller, args[1].i32, args[2].i32)) ?? []
                    asyncBroker.enqueue(token: token, symbolId: symbolId, argsBlob: argBlob)
                    return []
                })
        }
    }

    // MARK: - ASYNC routed calls (DESIGN §8.7)

    /// An optional async-call broker. When non-nil, `register(into:store:)` ALSO
    /// defines the `patch_host.call_async(symbolId, argsPtr, argsLen, token)` suspend
    /// import (the guest awaits the result; the host resumes it from the pump stall via
    /// `patch_resolve_hostcall`). Wire one with `withAsyncBroker(_:)` before registering.
    public var asyncBroker: PatchAsyncCallBroker? = nil

    /// Return a copy of this glue with `broker` attached for async routed calls. The
    /// broker's `bridge` SHOULD be the same controller this glue dispatches into.
    public func withAsyncBroker(_ broker: PatchAsyncCallBroker) -> GenericHostBridge {
        var g = self
        g.asyncBroker = broker
        return g
    }

    /// A `hostResolve` adapter for the SDK's async pump (`pumpToCompletion`'s
    /// `hostResolve`), expressed against the two guest-memory primitives the SDK's
    /// `WASMRuntime` provides. Pass `writeBlob = runtime.writeBuffer` and
    /// `invokeResolve = { token, ptr, len in try runtime.invoke(PatchAsyncCallBroker
    /// .resolveExport, [.i32(token), .i32(ptr), .i32(len)]) }`. Returns false (no
    /// progress) when no async broker is wired or nothing is owed — composes with the
    /// HTTP / bare-async resolvers in one stall round.
    public func asyncResolve(
        timeout: TimeInterval = 30,
        writeBlob: (_ bytes: [UInt8]) throws -> (ptr: UInt32, len: UInt32),
        invokeResolve: (_ token: Int32, _ ptr: UInt32, _ len: UInt32) throws -> Void
    ) throws -> Bool {
        guard let asyncBroker else { return false }
        return try asyncBroker.resolvePending(timeout: timeout,
                                              writeBlob: writeBlob,
                                              invokeResolve: invokeResolve)
    }

    /// The `(inout Imports, Store) -> Void` closure shape `WASMRuntime(hostImports:)`
    /// expects — capture this and pass it (or compose it with other bridges).
    public func hostImports() -> (inout Imports, Store) -> Void {
        let bridge = self.bridge
        return { imports, store in
            GenericHostBridge(bridge: bridge).register(into: &imports, store: store)
        }
    }
}
