// SPDX-License-Identifier: Apache-2.0

import Foundation

// =============================================================================
// GenericHostBridgeGuestEmitter — assembles the SHIPPABLE generic-host-bridge
// guest WASM module source (Lever #2, the BUILD-WIRING that closes the SHIP gap).
//
// `HostBridgeLowering` flips a forced-native function native→OTA and produces, per
// routed call site, the re-lowered guest body (`Routed.guestSequence`: the
// `have()`-guarded `patch_host.call` closure the rewriter emits). UNTIL NOW that
// sequence was only REPORTED — it was never compiled into the shipped module. This
// emitter takes the routed set + the engine-supplied per-function guest bodies and
// produces a self-contained guest module that:
//
//   1. Includes `HostBridgeABI.emitGuestPreamble()` ONCE (the generic-bridge
//      runtime: the `__PatchTLVWriter` + `__patchHostCall` dispatcher + result
//      decoder), so every spliced `patch_host.call` sequence has its codec in scope.
//   2. Emits one `@_cdecl` export PER FLIPPED FUNCTION whose body is the re-lowered
//      guest sequence (the routed `patch_host.call` is PRESENT + INSTANTIABLE in the
//      built `.wasm`).
//   3. Emits the `patch_host_symbols` manifest export (`HostBridgeABI.emitManifest-
//      GuestExport`) so the SDK reads the routed set on activation.
//   4. Declares the THREE generic CBridge imports (`patch_host.call/.release/.have`)
//      + `patch_malloc` via the proven C-header ABI (Clang import_module/import_name
//      — the flat ABI WasmKit accepts; `@_extern(wasm)` is rejected). The SDK's
//      `GenericHostBridge` supplies them at instantiation.
//
// This is the engine analogue of `SwiftUIGuestEmitter` / `UIKitGuestEmitter`: it
// emits the guest SOURCE; `BuildPipeline` compiles it to a `module.hostbridge.wasm`
// ADDITIVE PMOD sub-module (it never touches the default / SwiftUI / UIKit modules).
//
// DISCIPLINE: additive + demote-safe. Only a FLIPPED function contributes an export;
// a function that doesn't flip is untouched. With `PATCH_HOST_BRIDGE` OFF nothing
// here runs (the pipeline gate), so the build is byte-identical.
// =============================================================================

public struct GenericHostBridgeGuestEmitter {

    public init() {}

    /// One flipped function to ship: the export name + the re-lowered guest body
    /// (the `Routed.guestSequence` closure expression) + the function's Swift return
    /// type (so the `@_cdecl` probe returns a faithful scalar the test can assert).
    /// The body is a self-contained `{ () -> Ret in … }()` expression that references
    /// ONLY the arg expressions in `argBindings` (bound as locals in the wrapper).
    public struct FlippedFunction: Sendable, Equatable {
        /// The `@_cdecl` export name (sanitized, unique per flipped function).
        public let exportName: String
        /// The re-lowered guest sequence — the `have()`-guarded `patch_host.call`
        /// closure expression the rewriter emitted (`Routed.guestSequence`).
        public let guestSequence: String
        /// The Swift return type of the routed call (`"Double"`, `"Int"`, `"Bool"`,
        /// `"String"`, `"Void"`). Drives the probe's `@_cdecl` result type.
        public let returnType: String
        /// `let <name> = <literal>` bindings for every free identifier the
        /// `guestSequence` references (the routed call's arg exprs), so the wrapper
        /// compiles standalone and the routed `patch_host.call` is genuinely present.
        public let argBindings: [String]

        public init(exportName: String, guestSequence: String,
                    returnType: String, argBindings: [String]) {
            self.exportName = exportName
            self.guestSequence = guestSequence
            self.returnType = returnType
            self.argBindings = argBindings
        }
    }

    /// One generated source file (relative path inside the compile package + bytes).
    public struct File: Sendable, Equatable {
        public let relativePath: String
        public let contents: String
        public init(relativePath: String, contents: String) {
            self.relativePath = relativePath
            self.contents = contents
        }
    }

    /// The full emission: the files to compile + the `@_cdecl` export symbols to
    /// `--export-if-defined`.
    public struct Emission: Sendable, Equatable {
        public let files: [File]
        public let exports: [String]
        public init(files: [File], exports: [String]) {
            self.files = files
            self.exports = exports
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - Constants
    // -------------------------------------------------------------------------

    /// The C-bridge target name (carries the 3 generic flat imports + the arena).
    public static let cTargetName = "PatchHBBridge"
    /// The Swift guest target name.
    public static let swiftTargetName = "PatchHBGuest"
    /// The wrapper source file name (the one carrying the preamble + exports).
    public static let wrapperFileName = "_PatchHostBridge.swift"

    /// The always-present exports (the allocator) every consumer relies on.
    static let allocatorExports = ["patch_malloc", "patch_free"]

    // -------------------------------------------------------------------------
    // MARK: - Emission
    // -------------------------------------------------------------------------

    /// Emit the guest module source for the flipped functions + the routed-symbol
    /// manifest. Returns nil when there's nothing to ship (no flipped function).
    public func emit(flipped: [FlippedFunction],
                     symbols: [HostBridgeSymbol]) throws -> Emission? {
        guard !flipped.isEmpty else { return nil }

        var exports = Self.allocatorExports
        // includeAllocator:false — this guest already carries `patch_malloc` (C bridge)
        // and `_patchEmit`/`_patchHBEmit` below, so the integrated emitter must not also
        // emit a Swift `patch_malloc` (would collide with the C symbol).
        let manifestExport = try HostBridgeABI.emitManifestGuestExport(symbols, includeAllocator: false)

        // Per-flipped-function `@_cdecl` export. Each binds the routed call's arg
        // exprs as locals (so the lifted closure compiles standalone) then RETURNS the
        // re-lowered guest sequence — the routed `patch_host.call(id, …)` rides here.
        var fnExports: [String] = []
        for fn in flipped {
            exports.append(fn.exportName)
            fnExports.append(emitFunctionExport(fn))
        }

        let wrapper = """
        // Auto-generated by Patch — GENERIC host-bridge guest module (Lever #2).
        // The re-lowered bodies of FLIPPED forced-native functions run in WASM here:
        // each routed call dispatches through the SINGLE `patch_host.call` import,
        // falling back to the verbatim native call when the host can't resolve it
        // (`have()` pre-flight + `.error` decode). The SDK's GenericHostBridge serves
        // the import from the app's compiled-in dispatch table. DO NOT EDIT.

        import \(Self.cTargetName)

        // MARK: - Packed (ptr,len) emit (SDK malloc convention; over the C arena)

        @inline(__always)
        func _patchEmit(_ bytes: [UInt8]) -> Int64 {
            let n = Int32(bytes.count)
            guard n > 0, let out = patch_malloc(n) else { return 0 }
            let dst = out.assumingMemoryBound(to: UInt8.self)
            for i in 0..<bytes.count { dst[i] = bytes[i] }
            let outPtr = Int32(bitPattern: UInt32(UInt(bitPattern: out)))
            return (Int64(outPtr) << 32) | Int64(bytes.count)
        }

        // The integrated manifest export (includeAllocator:false) packs via `_patchHBEmit`.
        @inline(__always)
        func _patchHBEmit(_ bytes: [UInt8]) -> Int64 { _patchEmit(bytes) }

        \(HostBridgeABI.emitGuestPreamble())

        // MARK: - Flipped forced-native function exports (the re-lowered bodies)

        \(fnExports.joined(separator: "\n\n"))

        \(manifestExport)

        // Required reactor entry (never called; keeps the module valid).
        @_cdecl("patch_noop")
        public func patch_noop() {}
        """

        let files = [
            File(relativePath: "Sources/\(Self.cTargetName)/include/cbridge.h",
                 contents: Self.cbridgeHeader()),
            File(relativePath: "Sources/\(Self.cTargetName)/shim.c",
                 contents: Self.cbridgeShim()),
            File(relativePath: "Sources/\(Self.swiftTargetName)/\(Self.wrapperFileName)",
                 contents: wrapper),
        ]
        return Emission(files: files, exports: exports + ["patch_noop", HostBridgeABI.manifestGuestExport])
    }

    /// One flipped function's `@_cdecl` probe. Binds the routed call's arg exprs as
    /// locals (their values are placeholders — the routed `patch_host.call` for the
    /// content-addressed id is what must SHIP, not a particular input) then returns
    /// the re-lowered sequence. A non-scalar return is reduced to a stable scalar so
    /// the export has a clean flat ABI (the manifest carries the real signature).
    func emitFunctionExport(_ fn: FlippedFunction) -> String {
        let bindings = fn.argBindings.map { "    \($0)" }.joined(separator: "\n")
        let bindingsBlock = bindings.isEmpty ? "" : bindings + "\n"
        let seq = fn.guestSequence
            .split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: "\n    ")
        switch normalizedReturn(fn.returnType) {
        case .i64:
            return """
            @_cdecl("\(fn.exportName)")
            public func \(fn.exportName)() -> Int64 {
            \(bindingsBlock)    let __v = \(seq)
                return Int64(__v)
            }
            """
        case .f64:
            return """
            @_cdecl("\(fn.exportName)")
            public func \(fn.exportName)() -> Float64 {
            \(bindingsBlock)    let __v = \(seq)
                return Float64(__v)
            }
            """
        case .bool:
            return """
            @_cdecl("\(fn.exportName)")
            public func \(fn.exportName)() -> Int32 {
            \(bindingsBlock)    let __v = \(seq)
                return __v ? 1 : 0
            }
            """
        case .string:
            return """
            @_cdecl("\(fn.exportName)")
            public func \(fn.exportName)() -> Int64 {
            \(bindingsBlock)    let __v = \(seq)
                return _patchEmit(Array(__v.utf8))
            }
            """
        case .void:
            return """
            @_cdecl("\(fn.exportName)")
            public func \(fn.exportName)() {
            \(bindingsBlock)    \(seq)
            }
            """
        }
    }

    enum ScalarReturn { case i64, f64, bool, string, void }

    func normalizedReturn(_ raw: String) -> ScalarReturn {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "Int", "Int64", "Int32", "Int16", "Int8",
             "UInt", "UInt64", "UInt32", "UInt16", "UInt8":
            return .i64
        case "Double", "Float", "CGFloat":
            return .f64
        case "Bool":
            return .bool
        case "String":
            return .string
        case "", "Void", "()":
            return .void
        default:
            // The classifier only routes a marshallable return; an unrecognized
            // spelling defaults to the i64 probe (the manifest still carries truth).
            return .i64
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - The CBridge generic-import C target (DESIGN part A)
    // -------------------------------------------------------------------------

    /// The C header declaring the THREE generic dispatch imports + the result arena.
    /// Verbatim the proven prototype (`experiments/host-bridge-generalized/guest/`):
    /// Clang import_module/import_name attributes → the clean flat ABI WasmKit accepts
    /// (NOT `@_extern(wasm)`). The SDK's GenericHostBridge satisfies the imports.
    public static func cbridgeHeader() -> String {
        """
        // Auto-generated by Patch — generic host-bridge import ABI (Lever #2).
        // DO NOT EDIT. The THREE generic dispatch imports (`patch_host.call/.release/
        // .have`) + the guest result allocator. Flat ABI via Clang import_module/
        // import_name (the form WasmKit accepts). The SDK's GenericHostBridge serves
        // the imports at instantiation; `--allow-undefined` lets them link unsatisfied.
        #ifndef PATCH_GENERIC_HB_BRIDGE_H
        #define PATCH_GENERIC_HB_BRIDGE_H

        #include <stdint.h>
        #include <stddef.h>

        #define WASM_IMPORT(mod, nm) __attribute__((import_module(mod), import_name(nm)))

        // Guest-side result allocator (a static data-segment bump arena, robust under
        // the reactor model). The host writes packed (ptr,len) results into OUR linear
        // memory via this; the guest's `_patchEmit` also uses it for the manifest.
        void *patch_malloc(int32_t n);
        void patch_free(void *p);
        void patch_reset_arena(void);

        // The SINGLE generic dispatch import: invoke ANY already-linked native symbol
        // by its content-addressed integer id, args/result via the TLV blob.
        WASM_IMPORT("patch_host", "call")
        int64_t patch_host_call(int32_t symbolId, const uint8_t *argsPtr, int32_t argsLen);

        // Drop the host's strong reference to an opaque native-object handle.
        WASM_IMPORT("patch_host", "release")
        void patch_host_release(int32_t handle);

        // ABI-stability pre-flight: is `symbolId` resolvable in THIS app build?
        WASM_IMPORT("patch_host", "have")
        int32_t patch_host_have(int32_t symbolId);

        #endif
        """
    }

    /// The C shim TU — forces SwiftPM to emit the C object (so the import declarations
    /// land in the linked module) + carries the result arena. Verbatim the prototype.
    public static func cbridgeShim() -> String {
        """
        // Auto-generated by Patch — C shim for the generic host-bridge header.
        // Forces the C object so the flat import declarations land in the module, and
        // carries the guest-side result allocator (static arena; reactor-safe).
        #include "include/cbridge.h"

        #define PATCH_HB_ARENA_SIZE (1 << 18) // 256 KiB
        static unsigned char patch_hb_arena[PATCH_HB_ARENA_SIZE];
        static int patch_hb_arena_top = 0;

        void *patch_malloc(int32_t n) {
            if (n <= 0) return 0;
            if (patch_hb_arena_top + (int)n > PATCH_HB_ARENA_SIZE) return 0;
            void *p = &patch_hb_arena[patch_hb_arena_top];
            patch_hb_arena_top += (int)n;
            return p;
        }

        void patch_free(void *p) { (void)p; }

        void patch_reset_arena(void) { patch_hb_arena_top = 0; }
        """
    }

    // -------------------------------------------------------------------------
    // MARK: - Package manifest (reactor model + the C target dependency)
    // -------------------------------------------------------------------------

    /// The `Package.swift` for the standalone guest compile: the C-bridge target + the
    /// Swift guest target depending on it, in reactor mode with `--allow-undefined`
    /// (the 3 imports link unsatisfied) + per-export `--export-if-defined`. Mirrors the
    /// proven prototype `run.sh` / vertical-slice manifest.
    public static func packageManifest(exports: [String]) -> String {
        var flags = [
            "\"-Xclang-linker\", \"-mexec-model=reactor\"",
            "\"-Xlinker\", \"--allow-undefined\"",
        ]
        // De-dupe + sort the export flags for deterministic output.
        for sym in Array(Set(exports + ["patch_reset_arena"])).sorted() {
            flags.append("\"-Xlinker\", \"--export-if-defined=\(sym)\"")
        }
        return """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "\(swiftTargetName)", targets: [
            .target(name: "\(cTargetName)"),
            .executableTarget(name: "\(swiftTargetName)", dependencies: ["\(cTargetName)"],
                swiftSettings: [ .swiftLanguageMode(.v5) ],
                linkerSettings: [ .unsafeFlags([
                    \(flags.joined(separator: ",\n                    "))
                ]) ])
        ])
        """
    }
}
