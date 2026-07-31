// SPDX-License-Identifier: Apache-2.0

import Foundation
import PartitioningEngine
import CodeGenerator

/// Interface for invoking the Swift→WASM toolchain.
public protocol WasmCompiling {
    /// Compile the given `_wasm.swift` sources into a `.wasm` module.
    func compile(sources: [URL], outputModule: URL) throws -> WasmCompileResult
}

public struct WasmCompileResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case success
        case failure(reason: String)
        /// The toolchain is not installed; engine should treat affected
        /// functions as native (auto-reclassify-on-failure pipeline).
        case toolchainUnavailable
    }

    public let status: Status
    public let moduleURL: URL?
    public let log: String

    public init(status: Status, moduleURL: URL?, log: String) {
        self.status = status
        self.moduleURL = moduleURL
        self.log = log
    }

    public var isSuccess: Bool { status == .success }
}

/// Day-1 stub. Reports the toolchain as unavailable rather than shelling out, so
/// the rest of the pipeline can be exercised deterministically in tests/CI with
/// no external dependency and no network access. The real compiler is
/// `SwiftWasmCompiler` (Day-2).
public struct StubWasmCompiler: WasmCompiling {
    public init() {}

    public func compile(sources: [URL], outputModule: URL) throws -> WasmCompileResult {
        WasmCompileResult(
            status: .toolchainUnavailable,
            moduleURL: nil,
            log: "StubWasmCompiler: Swift→WASM toolchain not invoked. "
                + "Would compile \(sources.count) source(s) to \(outputModule.lastPathComponent)."
        )
    }
}

// MARK: - Real Swift → WASM compiler (Day-2)

/// Compiles generated `_wasm.swift` sources into a real `.wasm` module using the
/// **swift.org** open-source toolchain (the Apple/Xcode toolchain CANNOT target
/// wasm — DECISIONS finding #1) and the official WebAssembly Swift SDK.
///
/// Exact invocation (proven end-to-end on `Examples/OrderApp`):
///
/// ```
/// . "$HOME/.swiftly/env.sh"
/// "$HOME/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin/swift" \
///     build --swift-sdk swift-6.3.2-RELEASE_wasm --jobs 4 -c release
/// ```
///
/// We drive it through a throwaway SwiftPM package with a single `executableTarget`
/// built in *reactor* mode (`-mexec-model=reactor` + `--export-if-defined`), which
/// is what makes SwiftPM emit a standalone, instantiable `<name>.wasm` (a library
/// target only produces a `.o`). SwiftPM is used rather than a raw `swiftc` line
/// because it assembles the full WASI sysroot / resource-dir / static-stdlib flag
/// set from the artifactbundle automatically; reproducing that by hand is brittle.
public struct SwiftWasmCompiler: WasmCompiling {
    /// Swift SDK identifier (as listed by `swift sdk list`).
    public let swiftSDK: String
    /// Path to the swift.org toolchain that owns a wasm-capable LLVM backend.
    public let toolchainSwift: URL
    /// `env.sh` to source so the swiftly clang/lld land on PATH for linking.
    public let swiftlyEnv: URL?
    /// Symbols to export from the module (the generated fragment entry points).
    public let exportedSymbols: [String]
    public let jobs: Int
    /// The packaging tier to compile at. **T0 Embedded is the default** (tiny,
    /// no Foundation/ICU; Foundation values come from host bridges via the
    /// C-header import ABI). T1/T2 use the full WASM SDK. When a `tier` is
    /// supplied the `swiftSDK` is derived from it (overriding the explicit
    /// `swiftSDK` argument), so the convergence loop can switch tiers cleanly.
    public let tier: PackagingTier

    public init(
        swiftSDK: String = "swift-6.3.2-RELEASE_wasm",
        toolchainSwift: URL = SwiftWasmCompiler.defaultToolchainSwift,
        swiftlyEnv: URL? = SwiftWasmCompiler.defaultSwiftlyEnv,
        exportedSymbols: [String] = [],
        jobs: Int = 4,
        tier: PackagingTier = .t2Foundation
    ) {
        self.toolchainSwift = toolchainSwift
        self.swiftlyEnv = swiftlyEnv
        self.exportedSymbols = exportedSymbols
        self.jobs = jobs
        self.tier = tier
        // Tier always drives the SDK so the manifest flags and SDK stay
        // consistent (the explicit `swiftSDK:` arg is retained for source compat
        // but the tier's SDK wins).
        _ = swiftSDK
        self.swiftSDK = tier.swiftSDK
    }

    public static var defaultToolchainSwift: URL {
        let fm = FileManager.default
        let rel = "Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin/swift"
        // swiftly and `installer -target CurrentUserHomeDirectory` land the
        // toolchain in ~/Library; a SYSTEM install (the pkg's default double-click,
        // or `installer -target /`) lands in /Library. Prefer whichever exists so
        // the WASM toolchain is found regardless of HOW it was installed — a system
        // install used to falsely report "WASM toolchain: NOT FOUND". Fall back to
        // the ~/Library path (the swiftly default) for a clear not-found message.
        let candidates = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/\(rel)"),
            URL(fileURLWithPath: "/Library/\(rel)"),
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    public static var defaultSwiftlyEnv: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = home.appendingPathComponent(".swiftly/env.sh")
        return FileManager.default.fileExists(atPath: env.path) ? env : nil
    }

    /// Is the wasm toolchain available on this machine?
    public var toolchainAvailable: Bool {
        FileManager.default.fileExists(atPath: toolchainSwift.path)
    }

    public func compile(sources: [URL], outputModule: URL) throws -> WasmCompileResult {
        guard toolchainAvailable else {
            return WasmCompileResult(
                status: .toolchainUnavailable, moduleURL: nil,
                log: "swift.org toolchain not found at \(toolchainSwift.path)")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("PatchWasm-\(UUID().uuidString)")
        let srcDir = work.appendingPathComponent("Sources/PatchWasm")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        // Debug escape hatch: PATCH_KEEP_WORK preserves the temp SwiftPM package and
        // prints its path, so a failed convergence can be reproduced by hand.
        let keepWork = ProcessInfo.processInfo.environment["PATCH_KEEP_WORK"] != nil
        if keepWork { FileHandle.standardError.write(Data("[keep-work] \(work.path)\n".utf8)) }
        defer { if !keepWork { try? fm.removeItem(at: work) } }

        // Copy the generated sources into the package's single target.
        for src in sources {
            let dst = srcDir.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
        // Reactor model needs a (possibly empty) compilation entry; ensure one
        // .swift exists even if the caller passed an oddly-named single file.
        let marker = srcDir.appendingPathComponent("__patch_reactor.swift")
        try "// Patch reactor module: exports only; no top-level entry executed.\n"
            .write(to: marker, atomically: true, encoding: .utf8)

        // Write the C-header Foundation-bridge target (CHost) at EVERY tier so the
        // module can call host Decimal/JSON/Date via the clean flat ABI (the
        // research finding: a C header, NOT @_extern(wasm)). The Swift target
        // depends on it and `import CHost`. Writing it at all tiers keeps the
        // generated wrappers tier-agnostic: an auto-emitted T0 host-bridge wrapper
        // (`import CHost`) still links if the module ends up compiled at T1/T2
        // (e.g. because another function in the same compile unit forced a higher
        // tier, or the convergence loop escalated). The `patch_host.*` imports are
        // satisfied by the native shell at instantiation; the linker allows them
        // undefined at every tier.
        for file in CHeaderBridge().files(swiftTargetName: "PatchWasm") {
            let dst = work.appendingPathComponent(file.relativePath)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: dst, atomically: true, encoding: .utf8)
        }

        try packageManifest(exports: exportedSymbols).write(
            to: work.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        // Run: swift build --swift-sdk <sdk> -c release --jobs N
        let result = try runSwiftBuild(in: work)
        if result.exitCode != 0 {
            return WasmCompileResult(
                status: .failure(reason: firstError(in: result.output)),
                moduleURL: nil, log: result.output)
        }

        // Locate the emitted .wasm and move it to the requested output path.
        let built = work.appendingPathComponent(
            ".build/wasm32-unknown-wasip1/release/PatchWasm.wasm")
        guard fm.fileExists(atPath: built.path) else {
            return WasmCompileResult(
                status: .failure(reason: "build reported success but no .wasm was emitted"),
                moduleURL: nil, log: result.output)
        }
        try? fm.createDirectory(at: outputModule.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputModule.path) { try? fm.removeItem(at: outputModule) }
        try fm.copyItem(at: built, to: outputModule)

        return WasmCompileResult(status: .success, moduleURL: outputModule, log: result.output)
    }

    // MARK: - Generic host-bridge guest compilation (Lever #2, PATCH_HOST_BRIDGE)

    /// Compile the GENERIC host-bridge guest module — the re-lowered bodies of the
    /// flipped forced-native functions + the routed-symbol manifest — to a real
    /// `.wasm`. This is the SHIP step Lever #2 was missing: the routed
    /// `patch_host.call` sequences become PRESENT + INSTANTIABLE in a built module
    /// (the SDK's GenericHostBridge serves the 3 generic imports at runtime).
    ///
    /// Uses the emitter's OWN package layout (the `PatchHBBridge` C target carrying
    /// `patch_host.call/.release/.have` + `patch_malloc`, the `PatchHBGuest` Swift
    /// target depending on it) — NOT the default `CHost` Foundation-bridge package, so
    /// it composes cleanly as a SEPARATE additive sub-module. Built with the full WASM
    /// SDK in reactor mode (`--allow-undefined` lets the 3 imports link unsatisfied).
    ///
    /// Returns the same `WasmCompileResult` contract as `compile`; a compile failure
    /// is demote-safe (the pipeline declines the sub-module and the rest of the patch
    /// still ships).
    public func compileGenericHostBridgeGuest(
        emission: GenericHostBridgeGuestEmitter.Emission,
        outputModule: URL
    ) throws -> WasmCompileResult {
        guard toolchainAvailable else {
            return WasmCompileResult(
                status: .toolchainUnavailable, moduleURL: nil,
                log: "swift.org toolchain not found at \(toolchainSwift.path)")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("PatchHB-\(UUID().uuidString)")
        let keepWork = ProcessInfo.processInfo.environment["PATCH_KEEP_WORK"] != nil
        if keepWork { FileHandle.standardError.write(Data("[keep-work hostbridge] \(work.path)\n".utf8)) }
        defer { if !keepWork { try? fm.removeItem(at: work) } }

        // Write the emitter's files (C bridge header/shim + the Swift wrapper).
        for file in emission.files {
            let dst = work.appendingPathComponent(file.relativePath)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: dst, atomically: true, encoding: .utf8)
        }
        try GenericHostBridgeGuestEmitter.packageManifest(exports: emission.exports).write(
            to: work.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let result = try runSwiftBuild(in: work)
        if result.exitCode != 0 {
            return WasmCompileResult(
                status: .failure(reason: firstError(in: result.output)),
                moduleURL: nil, log: result.output)
        }
        let built = work.appendingPathComponent(
            ".build/wasm32-unknown-wasip1/release/\(GenericHostBridgeGuestEmitter.swiftTargetName).wasm")
        guard fm.fileExists(atPath: built.path) else {
            return WasmCompileResult(
                status: .failure(reason: "build reported success but no .wasm was emitted"),
                moduleURL: nil, log: result.output)
        }
        try? fm.createDirectory(at: outputModule.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputModule.path) { try? fm.removeItem(at: outputModule) }
        try fm.copyItem(at: built, to: outputModule)
        return WasmCompileResult(status: .success, moduleURL: outputModule, log: result.output)
    }

    // MARK: - Real-source closure compilation (PATCH_REAL_SOURCE)

    /// Compile a set of `@_cdecl` export WRAPPERS against the developer's **real,
    /// verbatim** module source — the research breakthrough
    /// (`research/wave3/BREAKTHROUGH-real-source-compilation.md`). Instead of the
    /// engine RECONSTRUCTING the value types / abstracting un-inferrable locals (the
    /// default path, which demotes classes/protocols/generics outright), this lets
    /// the actual Swift compiler resolve types/generics/protocols against the real
    /// source. An export demotes ONLY when the real compile fails (a genuine
    /// WASM-unavailable reference — UIKit/SceneKit/threading — `#if canImport` leaves
    /// inert; everything else compiles).
    ///
    /// The package is named after the **real module** (`moduleName`) so self-
    /// qualified references (`Euclid.max`) resolve, built in **Swift-5 language mode**
    /// (relaxing Swift-6 strict-concurrency on a pre-existing library) — the only two
    /// accommodations the prototype needed. The real source files are filtered by the
    /// caller (`realSources`) to those whose imports are WASM-safe; genuinely-native
    /// bits behind `#if canImport(UIKit/AppKit/SceneKit/RealityKit)` are inert on WASM.
    ///
    /// Returns the same `WasmCompileResult` contract as `compile`, so the convergence
    /// loop's demote-on-real-failure machinery drives it unchanged.
    public func compileRealSource(
        moduleName: String,
        realSources: [URL],
        wrapperSources: [URL],
        exports: [String],
        outputModule: URL,
        fusionBridgeFiles: [RealSourceWasmCompiler.FusionPackageFile] = []
    ) throws -> WasmCompileResult {
        guard toolchainAvailable else {
            return WasmCompileResult(
                status: .toolchainUnavailable, moduleURL: nil,
                log: "swift.org toolchain not found at \(toolchainSwift.path)")
        }
        // The package/module is named after the REAL module so self-qualified refs
        // resolve. Sanitize to a valid Swift identifier (the prototype used `Euclid`).
        let safeModule = Self.sanitizedModuleName(moduleName)

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("PatchReal-\(UUID().uuidString)")
        let srcDir = work.appendingPathComponent("Sources/\(safeModule)")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let keepWork = ProcessInfo.processInfo.environment["PATCH_KEEP_WORK"] != nil
        if keepWork { FileHandle.standardError.write(Data("[keep-work real-source] \(work.path)\n".utf8)) }
        defer { if !keepWork { try? fm.removeItem(at: work) } }

        // Copy the REAL module source verbatim, then the generated wrapper(s).
        // De-dup by file name (a wrapper named like a real file would clobber it).
        var used = Set<String>()
        func copyIn(_ srcs: [URL], renamePrefix: String?) throws {
            for src in srcs {
                var base = src.lastPathComponent
                if used.contains(base), let p = renamePrefix { base = "\(p)\(base)" }
                var name = base
                var i = 1
                while used.contains(name) { name = "\(i)_\(base)"; i += 1 }
                used.insert(name)
                let dst = srcDir.appendingPathComponent(name)
                if let text = try? String(contentsOf: src, encoding: .utf8) {
                    try text.write(to: dst, atomically: true, encoding: .utf8)
                } else {
                    try fm.copyItem(at: src, to: dst)
                }
            }
        }
        try copyIn(realSources, renamePrefix: nil)
        try copyIn(wrapperSources, renamePrefix: "_patchwrap_")
        // Reactor model needs a compilation entry even if no top-level code runs.
        let marker = srcDir.appendingPathComponent("__patch_real_reactor.swift")
        try "// Patch real-source reactor module: exports only; no top-level entry.\n"
            .write(to: marker, atomically: true, encoding: .utf8)

        // FUSION: drop the bridge files (FusionCHost C target header/shim + the Swift
        // bridge shim) into the package. Their relative paths use the literal token
        // `__MODULE__` for the Swift target dir so the package can be named after the
        // real module. The manifest below declares the FusionCHost target + dependency
        // only when these files are present (otherwise it stays single-target).
        let fusionEnabled = !fusionBridgeFiles.isEmpty
        for f in fusionBridgeFiles {
            let rel = f.relativePath.replacingOccurrences(of: "__MODULE__", with: safeModule)
            let dst = work.appendingPathComponent(rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.contents.write(to: dst, atomically: true, encoding: .utf8)
        }

        // BREAKTHROUGH #9 — the auto-emitted real-source T0 wrappers `import CHost`
        // (scalars cross via `patch_host.json_get_i64`, no in-module Foundation).
        // Drop the CHeaderBridge C-target files (chost.h / shim.c / the Swift bridge
        // shim) into the package so that import resolves — at EVERY tier, exactly as
        // the non-real `compile` path does (its comment: keeps T0 host-bridge
        // wrappers linking even when the module ends up escalated to T1/T2). This is
        // what lets the convergence loop escalate a T0-shaped wrapper set from T0 up
        // to T2 on an embedded-link failure without the `import CHost` becoming a
        // `no such module`. The `patch_host.*` imports stay undefined at every tier
        // (`--allow-undefined`); the native shell satisfies them at instantiation.
        // Skipped only when fusion supplies its own FusionCHost target (avoids a
        // duplicate C target — the embedded T0 routing and fusion are disjoint paths).
        if !fusionEnabled {
            for file in CHeaderBridge().files(swiftTargetName: safeModule) {
                let dst = work.appendingPathComponent(file.relativePath)
                if fm.fileExists(atPath: dst.path) { continue }
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.contents.write(to: dst, atomically: true, encoding: .utf8)
            }
        }

        try realSourceManifest(moduleName: safeModule, exports: exports, fusion: fusionEnabled).write(
            to: work.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let result = try runSwiftBuild(in: work)
        if result.exitCode != 0 {
            return WasmCompileResult(
                status: .failure(reason: firstError(in: result.output)),
                moduleURL: nil, log: result.output)
        }
        let built = work.appendingPathComponent(
            ".build/wasm32-unknown-wasip1/release/\(safeModule).wasm")
        guard fm.fileExists(atPath: built.path) else {
            return WasmCompileResult(
                status: .failure(reason: "build reported success but no .wasm was emitted"),
                moduleURL: nil, log: result.output)
        }
        // BREAKTHROUGH #9 — T0 unsatisfiable-import guard. `--allow-undefined` lets a
        // T0 (embedded) module LINK even when a closure uses an embedded-blocked
        // stdlib path (e.g. `Double(String)` → `env._swift_stdlib_strtod_clocale`,
        // String-interpolation Unicode tables): the symbol is left as an `env.*`
        // import that NOTHING satisfies on-device, so the small module would fail to
        // INSTANTIATE in the SDK's WasmKit (`unknown import env.…`). The link success
        // alone therefore can't be trusted at T0. We validate the import section: a
        // clean embedded module imports ONLY `patch_host.*` (the host bridge) and
        // `wasi_snapshot_preview1.*` (WASI). ANY `env.*` import means an embedded
        // blocker leaked through — convert the "success" into a FAILURE so the
        // convergence loop escalates this whole module to T1/T2 (where the full SDK
        // provides the stdlib symbol). T1/T2 modules legitimately import many stdlib
        // symbols and have their own runtime, so this guard applies to T0 ONLY.
        if tier == .t0Embedded,
           let wasm = try? Data(contentsOf: built),
           let bad = Self.unsatisfiableEnvImports([UInt8](wasm)), !bad.isEmpty {
            return WasmCompileResult(
                status: .failure(reason: "T0 embedded module imports unsatisfiable stdlib symbol(s) \(bad.prefix(3).joined(separator: ", ")) — escalating tier"),
                moduleURL: nil,
                log: result.output + "\n[T0-guard] module-wide: embedded link left undefined env import(s): \(bad.joined(separator: ", ")) — not instantiable; escalate to T1/T2.\n")
        }
        try? fm.createDirectory(at: outputModule.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputModule.path) { try? fm.removeItem(at: outputModule) }
        try fm.copyItem(at: built, to: outputModule)
        return WasmCompileResult(status: .success, moduleURL: outputModule, log: result.output)
    }

    /// Parse a WASM module's import section and return any imports whose module
    /// namespace is `env` — the C/Swift stdlib namespace a CLEAN embedded (T0)
    /// module never needs (the host bridge lives under `patch_host`, WASI under
    /// `wasi_snapshot_preview1`). An `env.*` import in a T0 module means an
    /// embedded-blocked stdlib path (`Double(String)` → `_swift_stdlib_strtod_clocale`,
    /// Unicode tables from String interpolation/`==`, …) was left undefined by
    /// `--allow-undefined`; nothing satisfies it on-device, so the module can't
    /// instantiate. Returns nil when the bytes aren't a parseable WASM module (caller
    /// treats nil as "no guard verdict" — the existing toolchain error handling wins).
    /// Minimal hand-rolled parser: WASM is `\0asm` + version, then sections; the
    /// import section (id 2) is a vec of (module: name, field: name, desc).
    static func unsatisfiableEnvImports(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 8,
              bytes[0] == 0x00, bytes[1] == 0x61, bytes[2] == 0x73, bytes[3] == 0x6d else { return nil }
        var i = 8  // past magic (4) + version (4)
        func leb() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                result |= Int(b & 0x7f) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 35 { return nil }
            }
            return nil
        }
        func name() -> String? {
            guard let len = leb(), i + len <= bytes.count else { return nil }
            let s = String(decoding: bytes[i..<i+len], as: UTF8.self)
            i += len
            return s
        }
        // A `limits` is a flags byte then min, plus max iff the low bit of flags is
        // set (0x01 = has-max, 0x03 = shared+has-max). Used by table/mem imports.
        func limits() {
            guard i < bytes.count else { return }
            let flags = bytes[i]; i += 1
            _ = leb()                       // min
            if flags & 0x01 != 0 { _ = leb() }  // max (present for 0x01 and 0x03)
        }
        var envImports: [String] = []
        while i < bytes.count {
            let sectionID = bytes[i]; i += 1
            guard let size = leb() else { return nil }
            let sectionEnd = i + size
            guard sectionEnd <= bytes.count else { return nil }
            if sectionID == 2 {  // import section
                guard let count = leb() else { return nil }
                for _ in 0..<count {
                    guard let mod = name(), let field = name() else { return nil }
                    guard i < bytes.count else { return nil }
                    let kind = bytes[i]; i += 1   // import desc kind (0 func,1 table,2 mem,3 global)
                    switch kind {
                    case 0x00: _ = leb()      // func: typeidx
                    case 0x01: i += 1; limits()  // table: reftype byte + limits
                    case 0x02: limits()       // mem: limits
                    case 0x03: i += 2         // global: valtype + mut
                    default: return nil
                    }
                    if mod == "env" { envImports.append(field) }
                }
                return envImports  // import section found + parsed; done
            }
            i = sectionEnd  // skip non-import section
        }
        return envImports  // no import section → no env imports
    }

    /// Make a real module name a valid Swift package/target identifier (the package
    /// name doubles as the module name, so `Euclid.max` self-refs resolve). Strips
    /// non-identifier characters; a leading digit gets a `_` prefix.
    public static func sanitizedModuleName(_ raw: String) -> String {
        var s = String(raw.map { ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
        if let f = s.first, f.isNumber { s = "_" + s }
        return s.isEmpty ? "PatchReal" : s
    }

    /// The SwiftPM manifest for a real-source compile: an `executableTarget` named
    /// after the real module, in **Swift-5 language mode** with the reactor linker
    /// flags + per-export `--export-if-defined`.
    ///
    /// FUSION (breakthrough #2): when `fusion` is true the manifest ALSO declares a
    /// `FusionCHost` C target (carrying the bridgeable-leaf host imports as a clean
    /// flat WASM ABI via Clang `import_module`/`import_name`) and the module target
    /// depends on it. `--allow-undefined` (already present) lets the `patch`/
    /// `patch_host` imports link unresolved; the native shell satisfies them at
    /// instantiation. This is the one-target-addition the prior research found was the
    /// whole build-layer unlock (the prototype proved it compiles + runs under the
    /// full SDK). When `fusion` is false the manifest is byte-identical to the
    /// pre-fusion path (single target, no CHost) — so the non-fusion real-source path
    /// is unchanged.
    private func realSourceManifest(moduleName: String, exports: [String], fusion: Bool = false) -> String {
        var flags = ["-Xclang-linker", "-mexec-model=reactor", "-Xlinker", "--allow-undefined"]
        for symbol in exports { flags += ["-Xlinker", "--export-if-defined=\(symbol)"] }
        let flagList = flags.map { "\"\($0)\"" }.joined(separator: ", ")
        // BREAKTHROUGH #9 — T0 EMBEDDED real-source compile. When the tier is
        // `.t0Embedded`, build the real-module target with the Embedded feature +
        // `-wmo` against the EMBEDDED SDK (no Foundation/ICU in the module), and
        // declare the `CHost` C target the auto-emitted T0 host-bridge wrapper
        // `import CHost`s (scalars cross via `patch_host.json_get_i64`). This is the
        // order-of-magnitude size win: the same real closure that is ~60 MB at T2
        // (Foundation+ICU) is ~110 KB at T0. Swift-5 mode is retained (relaxes
        // strict-concurrency on a pre-existing library). The convergence loop
        // ESCALATES to T1/T2 on an embedded-link failure (a closure that genuinely
        // needs in-module Foundation/`any`/Mirror), so this is demote-safe: a tiny
        // module ships whenever the closure is embeddable, the full module otherwise.
        // (Fusion is a separate, T2-oriented path; T0 uses the plain CHost bridge.)
        if tier == .t0Embedded && !fusion {
            return """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
              name: "\(moduleName)",
              targets: [
                .target(name: "\(CHeaderBridge.cTargetName)"),
                .executableTarget(
                  name: "\(moduleName)",
                  dependencies: ["\(CHeaderBridge.cTargetName)"],
                  swiftSettings: [
                    .swiftLanguageMode(.v5),
                    .enableExperimentalFeature("Embedded"),
                    .unsafeFlags(["-wmo"])
                  ],
                  linkerSettings: [ .unsafeFlags([\(flagList)]) ]
                )
              ]
            )
            """
        }
        if fusion {
            return """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
              name: "\(moduleName)",
              targets: [
                .target(name: "FusionCHost"),
                .executableTarget(
                  name: "\(moduleName)",
                  dependencies: ["FusionCHost"],
                  swiftSettings: [ .swiftLanguageMode(.v5) ],
                  linkerSettings: [ .unsafeFlags([\(flagList)]) ]
                )
              ]
            )
            """
        }
        // Non-fusion T1/T2: declare + depend on the `CHost` C target too. The
        // real-source compile now always writes the CHeaderBridge files (so a
        // T0-shaped host-bridge wrapper that ESCALATED to T1/T2 still resolves
        // `import CHost`). The dependency is harmless when no wrapper imports CHost
        // (the C target compiles to a tiny, unused object), exactly as the non-real
        // `packageManifest` T1/T2 branch already does.
        return """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
          name: "\(moduleName)",
          targets: [
            .target(name: "\(CHeaderBridge.cTargetName)"),
            .executableTarget(
              name: "\(moduleName)",
              dependencies: ["\(CHeaderBridge.cTargetName)"],
              swiftSettings: [ .swiftLanguageMode(.v5) ],
              linkerSettings: [ .unsafeFlags([\(flagList)]) ]
            )
          ]
        )
        """
    }

    /// Test-only access to the tier-routed real-source `Package.swift` so the
    /// tier-routing wiring (BREAKTHROUGH #9: the Embedded T0 branch vs the T1/T2
    /// branch, and the always-present `CHost` C target) can be asserted without a
    /// WASM toolchain. Returns the manifest `realSourceManifest` would write for
    /// this compiler's `tier`.
    func realSourceManifestForTesting(moduleName: String, exports: [String], fusion: Bool = false) -> String {
        realSourceManifest(moduleName: moduleName, exports: exports, fusion: fusion)
    }

    // MARK: - Helpers

    private func packageManifest(exports: [String]) -> String {
        var flags = ["-Xclang-linker", "-mexec-model=reactor"]
        // The module imports host functions (patch_host.*) it does not define — the
        // native shell satisfies them at instantiation. Allow undefined symbols at
        // every tier so the auto-emitted host-bridge wrappers link regardless of
        // the final compile tier.
        flags += ["-Xlinker", "--allow-undefined"]
        for symbol in exports {
            flags += ["-Xlinker", "--export-if-defined=\(symbol)"]
        }
        let flagList = flags.map { "\"\($0)\"" }.joined(separator: ", ")

        if tier == .t0Embedded {
            // Embedded Swift: no Foundation/ICU. A tiny C target (CHost) carries
            // the flat host-import declarations (chost.h); the Swift target
            // depends on it. `-enable-experimental-feature Embedded -wmo` is the
            // embedded mode (the embedded SDK adds `-static-stdlib`).
            return """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
              name: "PatchWasm",
              targets: [
                .target(name: "\(CHeaderBridge.cTargetName)"),
                .executableTarget(
                  name: "PatchWasm",
                  dependencies: ["\(CHeaderBridge.cTargetName)"],
                  swiftSettings: [
                    .enableExperimentalFeature("Embedded"),
                    .unsafeFlags(["-wmo"])
                  ],
                  linkerSettings: [ .unsafeFlags([\(flagList)]) ]
                )
              ]
            )
            """
        }

        // T1 / T2: full WASM SDK. The Swift target depends on the CHost bridge
        // target too (it is harmless when unused, and required when a function in
        // this compile unit was auto-emitted as a T0 host-bridge wrapper that
        // `import CHost` but the module ended up at T1/T2). (T2 modules `import
        // Foundation`; T1 modules do not — that difference is in the source.)
        return """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
          name: "PatchWasm",
          targets: [
            .target(name: "\(CHeaderBridge.cTargetName)"),
            .executableTarget(
              name: "PatchWasm",
              dependencies: ["\(CHeaderBridge.cTargetName)"],
              linkerSettings: [ .unsafeFlags([\(flagList)]) ]
            )
          ]
        )
        """
    }

    private struct RunResult { let exitCode: Int32; let output: String }

    private func runSwiftBuild(in dir: URL) throws -> RunResult {
        // Source swiftly env (puts the swift.org clang/lld on PATH) then build.
        let envLine = swiftlyEnv.map { ". \"\($0.path)\" && " } ?? ""
        let cmd = envLine
            + "\"\(toolchainSwift.path)\" build "
            + "--swift-sdk \(swiftSDK) -c release --jobs \(jobs)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", cmd]
        process.currentDirectoryURL = dir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(exitCode: process.terminationStatus,
                         output: String(data: data, encoding: .utf8) ?? "")
    }

    private func firstError(in log: String) -> String {
        for line in log.split(separator: "\n") where line.contains("error:") {
            return String(line)
        }
        return "swift build failed (see log)"
    }
}

// MARK: - Real-source convergence adapter

/// A `WasmCompiling` adapter that compiles the passed candidate sources (the
/// generated `@_cdecl` wrappers + the shared allocator runtime) **against a fixed
/// set of the developer's REAL module source files**, in a package named after the
/// real module (Swift-5 mode, reactor). This lets the existing `WasmConvergence`
/// loop drive real-source closure compilation unchanged: when a wrapper fails to
/// compile against real source, convergence attributes + demotes it exactly as it
/// does a generated candidate, so genuinely-native references still fall back
/// correctly. The `tier`/SDK come from the wrapped `SwiftWasmCompiler` (the
/// real-source path is a T2-Foundation compile — the wrappers use the in-module
/// JSON coder).
public struct RealSourceWasmCompiler: WasmCompiling {
    public let base: SwiftWasmCompiler
    public let moduleName: String
    /// The developer's real, import-safe module source files (always compiled in,
    /// never demoted — a real source failure that names one of these is a true
    /// module-wide poison and fails the whole compile, which convergence handles).
    public let realSources: [URL]
    /// FUSION (breakthrough #2): extra package files contributing a `FusionCHost` C
    /// target carrying the bridgeable-leaf host imports (`patch`/`patch_host` flat
    /// ABI) plus the Swift bridge shims, so a real-source function whose ONE native
    /// leaf was rewritten to a host bridge (by `CodeGenerator.FusionRewriter`) links
    /// instead of demoting. Empty = no fusion (the manifest stays single-target,
    /// identical to the pre-fusion path). Each tuple is (relativePathInPackage,
    /// contents). Carried as data so the convergence loop's re-instantiation can
    /// forward it unchanged.
    public let fusionBridgeFiles: [FusionPackageFile]

    /// A single extra file to drop into the real-source compile package (the fusion
    /// CHost target + Swift bridge). Kept as a plain value type so it survives the
    /// convergence loop re-instantiating the compiler each iteration.
    public struct FusionPackageFile: Sendable, Equatable {
        public let relativePath: String
        public let contents: String
        public init(relativePath: String, contents: String) {
            self.relativePath = relativePath
            self.contents = contents
        }
    }

    public init(base: SwiftWasmCompiler, moduleName: String, realSources: [URL],
                fusionBridgeFiles: [FusionPackageFile] = []) {
        self.base = base
        self.moduleName = moduleName
        self.realSources = realSources
        self.fusionBridgeFiles = fusionBridgeFiles
    }

    public var toolchainAvailable: Bool { base.toolchainAvailable }

    public func compile(sources: [URL], outputModule: URL) throws -> WasmCompileResult {
        // `sources` here are the wrapper candidates + the shared runtime/support; the
        // real module source is the fixed closure. The convergence loop already adds
        // patch_malloc/patch_free to the export list it passes via the wrapped
        // compiler's `exportedSymbols`.
        try base.compileRealSource(
            moduleName: moduleName,
            realSources: realSources,
            wrapperSources: sources,
            exports: base.exportedSymbols,
            outputModule: outputModule,
            fusionBridgeFiles: fusionBridgeFiles)
    }
}
