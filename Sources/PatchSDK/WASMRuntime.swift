import Foundation
import WasmKit
import WasmKitWASI
import WASI

/// Errors thrown by the Patch WASM runtime layer.
public enum PatchRuntimeError: Error, CustomStringConvertible, Equatable {
    /// The named export (function or memory) was not found in the module.
    case exportNotFound(String)
    /// A guest memory read/write would fall outside linear memory.
    case memoryOutOfBounds(ptr: UInt32, len: UInt32)
    /// The module did not export the expected linear memory.
    case memoryMissing
    /// The module's guest allocator (`patch_malloc`) returned a null pointer.
    case allocationFailed(bytes: Int)
    /// An invoked export returned an unexpected number/shape of results.
    case unexpectedResults(function: String, got: Int, expected: String)
    /// A WASM trap (e.g. `proc_exit`, `fatalError`, OOB) tore down the call.
    /// A trap is NOT recoverable within the same instance — the instance must
    /// be re-loaded.
    case trap(String)
    /// The module bytes failed to parse / instantiate.
    case instantiationFailed(String)

    public var description: String {
        switch self {
        case .exportNotFound(let n): return "WASM export not found: \(n)"
        case .memoryOutOfBounds(let p, let l):
            return "WASM memory access out of bounds (ptr=\(p), len=\(l))"
        case .memoryMissing: return "WASM module does not export `memory`"
        case .allocationFailed(let b): return "guest allocator returned null for \(b) bytes"
        case .unexpectedResults(let f, let g, let e):
            return "export `\(f)` returned \(g) results, expected \(e)"
        case .trap(let m): return "WASM trap: \(m)"
        case .instantiationFailed(let m): return "WASM instantiation failed: \(m)"
        }
    }
}

/// Configuration for how the runtime satisfies WASI Preview 1 imports.
///
/// Real Swift-compiled modules import 14–34 `wasi_snapshot_preview1.*`
/// functions (clock/random/args/environ/fd_*/path_*). They will NOT instantiate
/// unless the host provides them. `WasmKitWASI`'s `WASIBridgeToHost` provides a
/// full Preview 1 implementation; this struct controls what capabilities it
/// grants (the safest patch surface grants no FS preopens).
public struct WASIConfig: Sendable {
    /// Command-line args exposed to the guest (`args_get`). Usually just a name.
    public var args: [String]
    /// Environment variables exposed to the guest (`environ_get`).
    public var environment: [String: String]
    /// Guest-path -> host-path directory preopens for the WASI filesystem.
    /// Default: none. Patch logic should be pure compute; grant nothing.
    public var preopens: [String: String]

    public init(
        args: [String] = ["patch"],
        environment: [String: String] = [:],
        preopens: [String: String] = [:]
    ) {
        self.args = args
        self.environment = environment
        self.preopens = preopens
    }

    /// The default: no FS access, no env, single arg. The deterministic surface.
    public static let `default` = WASIConfig()
}

/// A loaded, instantiated WebAssembly module with managed lifecycle, linear
/// memory access, and the Patch v0 marshalling ABI.
///
/// One `WASMRuntime` owns one active `Instance`. The runtime is created once per
/// loaded patch module; hot-swap replaces the whole runtime behind the
/// read/write lock in `Patch` rather than mutating an instance in place, which
/// keeps WasmKit's `Store`/`Instance` graph internally consistent.
///
/// ## Patch v0 marshalling ABI (host <-> guest)
/// Strings / `Data` / `Codable` payloads cross as a `(ptr: i32, len: i32)` pair
/// into the module's exported `memory`. No NUL terminator; length is explicit.
/// The host reserves guest memory through the module's exported allocator
/// (`patch_malloc(i32) -> i32`, optionally paired with `patch_free(i32)`),
/// writes the bytes, then calls the target export with `(ptr, len)`.
public final class WASMRuntime {
    /// One Engine per runtime; the Store/Instance are created from it.
    public let engine: Engine
    public let store: Store
    public let instance: Instance

    /// Held so it lives as long as the instance (its host functions close over
    /// guest memory). `WASIBridgeToHost` is the Preview 1 implementation.
    private let wasi: WASIBridgeToHost

    /// Name of the exported guest allocator. Matches the standard fixtures.
    private let allocatorName: String
    /// Name of the exported linear memory. Standard for Swift reactor modules.
    private let memoryName: String

    // MARK: - Lifecycle

    /// Parse, instantiate, and WASI-initialize a module from raw bytes.
    ///
    /// - Parameters:
    ///   - bytes: the `.wasm` binary (a WASI reactor or command module).
    ///   - wasiConfig: WASI capabilities to grant.
    ///   - hostImports: extra host functions to expose to the guest (the
    ///       wasm->native bridge). Merged on top of the WASI imports.
    ///   - allocatorName: exported allocator (default `patch_malloc`).
    ///   - memoryName: exported memory (default `memory`).
    public init(
        bytes: [UInt8],
        wasiConfig: WASIConfig = .default,
        hostImports: ((inout Imports, Store) -> Void)? = nil,
        allocatorName: String = "patch_malloc",
        memoryName: String = "memory"
    ) throws {
        self.allocatorName = allocatorName
        self.memoryName = memoryName
        self.engine = Engine()
        self.store = Store(engine: engine)

        do {
            self.wasi = try WASIBridgeToHost(
                args: wasiConfig.args,
                environment: wasiConfig.environment,
                preopens: wasiConfig.preopens
            )
        } catch {
            throw PatchRuntimeError.instantiationFailed(
                "WASI bridge init failed: \(error)")
        }

        var imports = Imports()
        // 1. Satisfy all `wasi_snapshot_preview1.*` imports.
        wasi.link(to: &imports, store: store)
        // 2. Layer any extra host functions (the native bridge) on top.
        hostImports?(&imports, store)

        let module: Module
        do {
            module = try parseWasm(bytes: bytes)
        } catch {
            throw PatchRuntimeError.instantiationFailed("parse: \(error)")
        }
        do {
            self.instance = try module.instantiate(store: store, imports: imports)
        } catch {
            throw PatchRuntimeError.instantiationFailed("instantiate: \(error)")
        }

        // 3. Reactor init: call `_initialize` once before any other export.
        //    (`initialize` is a no-op if the module has no `_initialize`.)
        do {
            try wasi.initialize(instance)
        } catch let code as WASIExitCode {
            throw PatchRuntimeError.trap("_initialize exited with code \(code.code)")
        } catch {
            throw PatchRuntimeError.trap("_initialize failed: \(error)")
        }
    }

    /// Convenience: load from a file URL.
    public convenience init(
        contentsOf url: URL,
        wasiConfig: WASIConfig = .default,
        hostImports: ((inout Imports, Store) -> Void)? = nil
    ) throws {
        let data = try Data(contentsOf: url)
        try self.init(bytes: [UInt8](data), wasiConfig: wasiConfig, hostImports: hostImports)
    }

    /// Teardown is implicit: dropping the `WASMRuntime` releases the Store,
    /// Instance, memory, and the WASI bridge. WasmKit has no explicit
    /// destroy/close call; ARC reclaims the whole graph. This method exists so
    /// callers can express intent and so future versions can flush state.
    public func teardown() {
        // No-op today; the object graph is freed when the last reference drops.
        // A trap leaves the instance unusable — callers should drop the runtime.
    }

    /// Post-instantiation usability probe for the hot-swap path. Instantiation
    /// already validates parse/link/`_initialize`, but a module can instantiate
    /// and still be unable to participate in the Patch marshalling ABI if it does
    /// not export the linear `memory` every host<->guest payload crosses through.
    /// `hotSwap` calls this after swapping the runtime in and rolls back to the
    /// prior (known-good) module if it throws. Throws `memoryMissing` when the
    /// exported memory is absent.
    public func assertUsable() throws {
        _ = try memory()
    }

    // MARK: - Invocation

    /// Look up an exported function by name.
    public func function(_ name: String) throws -> Function {
        guard let fn = instance.exports[function: name] else {
            throw PatchRuntimeError.exportNotFound(name)
        }
        return fn
    }

    /// Whether an export with the given name exists as a function.
    public func hasFunction(_ name: String) -> Bool {
        instance.exports[function: name] != nil
    }

    /// Invoke an exported function with raw `Value`s, mapping traps to
    /// `PatchRuntimeError.trap`.
    @discardableResult
    public func invoke(_ name: String, _ args: [Value] = []) throws -> [Value] {
        let fn = try function(name)
        do {
            return try fn.invoke(args)
        } catch let e as PatchRuntimeError {
            throw e
        } catch {
            // WasmKit surfaces traps as thrown errors; normalize them.
            throw PatchRuntimeError.trap("\(name): \(error)")
        }
    }

    // MARK: - Linear memory

    /// The module's exported linear memory.
    public func memory() throws -> Memory {
        guard let mem = instance.exports[memory: memoryName] else {
            throw PatchRuntimeError.memoryMissing
        }
        return mem
    }

    /// Current size of linear memory in bytes.
    public func memorySize() throws -> Int {
        try memory().data.count
    }

    /// Reserve `byteCount` bytes of guest memory via the exported allocator.
    /// Returns the guest pointer (a linear-memory offset).
    public func allocate(_ byteCount: Int) throws -> UInt32 {
        guard byteCount >= 0 else {
            throw PatchRuntimeError.allocationFailed(bytes: byteCount)
        }
        if byteCount == 0 { return 0 }
        let results = try invoke(allocatorName, [.i32(UInt32(byteCount))])
        guard results.count == 1 else {
            throw PatchRuntimeError.unexpectedResults(
                function: allocatorName, got: results.count, expected: "1 i32 ptr")
        }
        let ptr = results[0].i32
        if ptr == 0 { throw PatchRuntimeError.allocationFailed(bytes: byteCount) }
        return ptr
    }

    /// Release a buffer previously returned by `allocate` (best-effort; a no-op
    /// if the module exports no `patch_free`).
    public func free(_ ptr: UInt32) {
        guard ptr != 0, hasFunction("patch_free") else { return }
        _ = try? invoke("patch_free", [.i32(ptr)])
    }

    /// Write raw bytes into guest memory at `ptr`. Bounds-checked.
    public func write(_ bytes: [UInt8], at ptr: UInt32) throws {
        let mem = try memory()
        let end = Int(ptr) + bytes.count
        guard Int(ptr) >= 0, end <= mem.data.count else {
            throw PatchRuntimeError.memoryOutOfBounds(ptr: ptr, len: UInt32(bytes.count))
        }
        if bytes.isEmpty { return }
        mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: bytes.count) { raw in
            raw.copyBytes(from: bytes)
        }
    }

    /// Read `len` bytes from guest memory at `ptr`. Bounds-checked.
    public func read(ptr: UInt32, len: UInt32) throws -> [UInt8] {
        let mem = try memory()
        let all = mem.data
        let start = Int(ptr)
        let end = start + Int(len)
        guard start >= 0, end <= all.count else {
            throw PatchRuntimeError.memoryOutOfBounds(ptr: ptr, len: len)
        }
        if len == 0 { return [] }
        return [UInt8](all[start..<end])
    }

    /// Allocate guest memory, copy `bytes` in, and return `(ptr, len)`. The
    /// caller owns the buffer (free it with `free(_:)` when the call returns,
    /// if the module supports freeing).
    @discardableResult
    public func writeBuffer(_ bytes: [UInt8]) throws -> (ptr: UInt32, len: UInt32) {
        let ptr = try allocate(bytes.count)
        try write(bytes, at: ptr)
        return (ptr, UInt32(bytes.count))
    }
}
