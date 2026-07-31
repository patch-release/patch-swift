// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Fix S2 — the BUILD-SAFETY net for the native-shell `*_bridge.swift` files.
///
/// The engine writes `*_bridge.swift` files (the rewired native shell that calls a
/// WASM fragment via `Patch.call(...)`) but NEVER compiles them — the WASM
/// convergence loop only proves the *guest* half. A bridge whose hardcoded
/// type/optionality/Codable assumption is wrong therefore compiles never in
/// `patchcli build` and instead FAILS in the developer's Xcode build, *after*
/// `patchcli build` reported success — the worst DX failure mode (a "broken-success").
///
/// This driver closes that hole: it host-`swiftc -typecheck`s the generated bridge
/// files together with the developer's own source (the same files the dev's app
/// target compiles) + a synthesized `PatchSDK` shim, and reports which bridge files
/// fail to type-check. The caller DEMOTES a failing bridge's unit (drops the bridge
/// AND its paired WASM export, keeping that function native) so a non-compiling
/// bridge can NEVER reach the developer.
///
/// SAFETY VALVE (never spuriously demote): if the developer's source does not
/// type-check ON ITS OWN (a missing third-party import, a host-only dependency the
/// CLI can't resolve), the net is INCONCLUSIVE — we cannot attribute an error to the
/// bridge vs. the pre-existing project state — so it SKIPS (keeps every bridge,
/// the current behavior). The net only ever demotes when it can PROVE the bridge is
/// the thing that broke an otherwise-clean compile.
struct BridgeTypecheck {

    /// Outcome of the net for one build.
    struct Outcome {
        /// Bridge file URLs that FAILED to type-check against the dev source (demote).
        var failingBridges: Set<URL> = []
        /// Whether the net actually ran (false = host toolchain unavailable, or the
        /// dev-source baseline didn't type-check → inconclusive → skipped).
        var ran: Bool = false
        /// A human-readable note (for `--verbose` / diagnostics).
        var note: String = ""
    }

    /// Locate the host `swiftc` (the Xcode/Apple toolchain — NOT the WASM toolchain).
    /// `xcrun -f swiftc` resolves the active developer dir; a bare `swiftc` on PATH is
    /// the fallback. nil when neither resolves (the net then skips).
    static func hostSwiftc() -> URL? {
        // `xcrun -f swiftc`
        let xcrun = Process()
        xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrun.arguments = ["-f", "swiftc"]
        let pipe = Pipe()
        xcrun.standardOutput = pipe
        xcrun.standardError = Pipe()
        if (try? xcrun.run()) != nil {
            xcrun.waitUntilExit()
            if xcrun.terminationStatus == 0,
               let data = try? pipe.fileHandleForReading.readToEnd(),
               let path = String(data: data ?? Data(), encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        for p in ["/usr/bin/swiftc", "/usr/local/bin/swiftc"] where FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    /// The synthesized `PatchSDK` module shim: the minimal `Patch` surface the
    /// generated bridges call via `PatchSDK.Patch.shared.callJSON/valueJSON/callValueJSON`
    /// (the bridges `import PatchSDK` and define their OWN file-local `enum Patch`
    /// wrapper around it). This is compiled as a SEPARATE module named `PatchSDK` (so
    /// `import PatchSDK` resolves and the bridge's local `enum Patch` never collides
    /// with this `PatchSDK.Patch`) — it lets the host type-check prove the bridge's
    /// TYPE soundness (its `_Args`/`_Out` envelopes, signature types, optionality)
    /// WITHOUT the real SDK package.
    static let patchSDKShim = """
    // Synthesized PatchSDK module shim — host type-check only, never shipped. DO NOT EDIT.
    import Foundation
    public enum Patch {
        public static let shared = Shared()
        public struct Shared {
            public init() {}
            public func callJSON<A: Encodable, R: Decodable>(_ name: String, _ args: A, returning: R.Type) throws -> R { fatalError() }
            public func valueJSON<R: Decodable>(_ key: String, returning: R.Type) throws -> R { fatalError() }
            public func callValueJSON<A: Encodable, R: Decodable>(_ key: String, _ args: A, returning: R.Type) throws -> R { fatalError() }
        }
    }
    """

    /// Run the net. `devSwiftFiles` are the developer's own (native-shell) source
    /// files; `bridges` the generated `*_bridge.swift` files; `enabled` gates it off
    /// (the env-var escape hatch). Returns which bridges to demote.
    static func run(devSwiftFiles: [URL], bridges: [URL], enabled: Bool) -> Outcome {
        var out = Outcome()
        guard enabled, !bridges.isEmpty else {
            out.note = bridges.isEmpty ? "no bridges" : "disabled"
            return out
        }
        guard let swiftc = hostSwiftc() else {
            out.note = "host swiftc unavailable — skipped"
            return out
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("patch-bridgecheck-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // Build the `PatchSDK` module shim into a `.swiftmodule` so the bridges'
        // `import PatchSDK` + `PatchSDK.Patch.shared.*` resolve during type-check.
        // If the shim build fails (an unexpected toolchain quirk), skip the net.
        let shimSrc = work.appendingPathComponent("PatchSDKShim.swift")
        try? patchSDKShim.write(to: shimSrc, atomically: true, encoding: .utf8)
        let modDir = work.appendingPathComponent("mod")
        try? fm.createDirectory(at: modDir, withIntermediateDirectories: true)
        guard buildShimModule(swiftc: swiftc, shimSrc: shimSrc, outDir: modDir) else {
            out.note = "PatchSDK shim module build failed — net skipped (no demote)"
            return out
        }

        // BASELINE: the dev source must type-check on its own (with the shim module on
        // the search path). If it does not (third-party imports the CLI can't resolve),
        // the net is inconclusive → skip (never spuriously demote).
        if typecheckFails(swiftc: swiftc, files: devSwiftFiles, moduleSearchDir: modDir, attributableTo: nil) {
            out.note = "dev-source baseline did not type-check — net inconclusive, skipped (no demote)"
            return out
        }
        out.ran = true

        // Type-check each bridge individually against the clean baseline so one bad
        // bridge never masks/condemns a good one. A bridge that introduces an error
        // attributed to its own file is demoted.
        for bridge in bridges {
            if typecheckFails(swiftc: swiftc, files: devSwiftFiles + [bridge],
                              moduleSearchDir: modDir, attributableTo: bridge) {
                out.failingBridges.insert(bridge)
            }
        }
        out.note = out.failingBridges.isEmpty
            ? "all \(bridges.count) bridge(s) type-checked"
            : "\(out.failingBridges.count)/\(bridges.count) bridge(s) failed host type-check — demoted"
        return out
    }

    /// Compile the shim into a `PatchSDK.swiftmodule` under `outDir`. Returns success.
    private static func buildShimModule(swiftc: URL, shimSrc: URL, outDir: URL) -> Bool {
        let p = Process()
        p.executableURL = swiftc
        p.arguments = ["-emit-module", "-module-name", "PatchSDK",
                       "-emit-module-path", outDir.appendingPathComponent("PatchSDK.swiftmodule").path,
                       "-parse-as-library", "-suppress-warnings", shimSrc.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// `swiftc -typecheck` the file set against the `PatchSDK` shim module. Returns
    /// true if it FAILS. When `attributableTo` is non-nil, a failure counts only if
    /// the compiler's error output mentions that file (so an error in an UNRELATED dev
    /// file — which the baseline already passed, so this shouldn't happen, but be
    /// defensive — never condemns the bridge).
    private static func typecheckFails(swiftc: URL, files: [URL], moduleSearchDir: URL,
                                       attributableTo: URL?) -> Bool {
        let p = Process()
        p.executableURL = swiftc
        // `-typecheck` (no codegen), parse-as-library (no top-level entry needed),
        // suppress warnings-as-noise, `-I` so `import PatchSDK` resolves. One module.
        p.arguments = ["-typecheck", "-parse-as-library", "-suppress-warnings",
                       "-I", moduleSearchDir.path]
            + files.map { $0.path }
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        guard (try? p.run()) != nil else { return false }  // can't run → don't demote
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return false }
        guard let bridge = attributableTo else { return true }
        let log = String(data: errData ?? Data(), encoding: .utf8) ?? ""
        // Attribute by file base name (the absolute path appears in `file:line:col:`).
        return log.contains(bridge.lastPathComponent)
    }
}
