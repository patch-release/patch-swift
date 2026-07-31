// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler

/// `patchcli overlay` — author + package the **resource overlay** (Phase 1b):
/// OTA overrides for named **colors** and localized **strings** (and the hook for
/// bundle **images**) shipped alongside the WASM module, with no view-IR. See
/// `docs/UIKIT-COVERAGE.md` §B.2 and the spec shape in `OverlaySpecReader`.
///
/// The overlay rides the SAME single-artifact upload/download/SHA path as the WASM
/// module: `overlay package` wraps the built `module.wasm` (or `PMOD` container) in
/// a thin `POVR` envelope carrying the serialized overlay table. The on-device SDK
/// strips it and installs a name-lookup redirection (consult overlay first, else the
/// bundle). An overlay-free build is never wrapped (byte-identical to today).
struct Overlay: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "overlay",
        abstract: "Author + package an OTA resource overlay (colors / strings / images).",
        subcommands: [Package.self, Inspect.self]
    )

    // MARK: - overlay package

    /// Wrap a built module with the overlay authored in a JSON spec file.
    struct Package: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "package",
            abstract: "Bundle an overlay spec (JSON) into the built module artifact."
        )

        @Argument(help: "Path to the overlay spec JSON (colors / strings / images).")
        var spec: String

        @Option(name: .long, help: "Module to wrap (default: .Patch/build/module.wasm).")
        var module: String?

        @Option(name: .long, help: "Where to write the wrapped artifact (default: overwrite the module in place).")
        var output: String?

        func run() throws {
            let specURL = URL(fileURLWithPath: spec)
            guard FileManager.default.fileExists(atPath: specURL.path) else {
                throw ValidationError("Overlay spec not found at \(specURL.path).")
            }

            // Resolve the module path (explicit > project default).
            let moduleURL = try resolveModuleURL(module)
            guard FileManager.default.fileExists(atPath: moduleURL.path) else {
                throw ValidationError(
                    "No module at \(moduleURL.path). Run `patchcli build` first (or pass --module).")
            }

            let table: PatchResourceOverlay.Table
            do { table = try OverlaySpecReader.load(from: specURL) }
            catch { throw ValidationError("Could not read overlay spec: \(error)") }

            if table.isEmpty {
                throw ValidationError(
                    "Overlay spec is empty (no colors/strings/images). Nothing to package.")
            }

            let inner = [UInt8](try Data(contentsOf: moduleURL))
            // If the module is ALREADY a POVR artifact (re-package), unwrap to the
            // inner WASM first so we never nest wrappers.
            let innerWasm = PatchOverlayArtifact.decode(inner)?.inner ?? inner
            let wrapped = PatchOverlayArtifact.package(inner: innerWasm, table: table)

            let outURL = output.map { URL(fileURLWithPath: $0) } ?? moduleURL
            // Atomic write.
            let tmp = outURL.deletingLastPathComponent()
                .appendingPathComponent(".patch-overlay-\(UUID().uuidString).bin")
            try Data(wrapped).write(to: tmp)
            if FileManager.default.fileExists(atPath: outURL.path) {
                _ = try? FileManager.default.removeItem(at: outURL)
            }
            try FileManager.default.moveItem(at: tmp, to: outURL)

            print("Patch overlay")
            print("=============")
            print("Spec:    \(specURL.path)")
            print("Module:  \(moduleURL.path)")
            print("Output:  \(outURL.path) (\(wrapped.count) bytes)")
            print("")
            print("Overlay contents:")
            print("  Colors:  \(table.colors.count)  \(table.colors.keys.sorted().joined(separator: ", "))")
            print("  Strings: \(table.stringCount) across \(table.strings.count) locale(s)")
            for locale in table.strings.keys.sorted() {
                let label = locale.isEmpty ? "(base)" : locale
                print("    \(label): \(table.strings[locale]!.count)")
            }
            if !table.images.isEmpty {
                let inlineBytes = table.images.values
                    .filter { $0.kind == .inline }
                    .reduce(0) { $0 + $1.payload.count }
                print("  Images:  \(table.images.count)  (\(inlineBytes) inline bytes)")
                if inlineBytes > 256 * 1024 {
                    print("    NOTE: inline image bytes are large (\(inlineBytes) B). Large images bloat")
                    print("          the artifact; prefer the external-ref form for big assets.")
                }
            }
            print("")
            print("  Wrapped — ship with `patchcli push` (the overlay rides the module upload).")
        }
    }

    // MARK: - overlay inspect

    /// Dump the overlay carried by an artifact (for verifying a packaged module).
    struct Inspect: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Print the resource overlay carried by a packaged module artifact."
        )

        @Argument(help: "Path to the artifact (a POVR-wrapped module, or any module).")
        var artifact: String

        func run() throws {
            let url = URL(fileURLWithPath: artifact)
            guard let data = try? Data(contentsOf: url) else {
                throw ValidationError("Artifact not found at \(url.path).")
            }
            let bytes = [UInt8](data)
            guard let decoded = PatchOverlayArtifact.decode(bytes) else {
                print("No resource overlay: this artifact is a plain module (no POVR wrapper).")
                return
            }
            guard let table = PatchResourceOverlay.decode(decoded.overlay) else {
                throw ValidationError("Artifact carries a POVR wrapper but the overlay chunk is corrupt.")
            }
            print("Resource overlay (\(decoded.overlay.count) chunk bytes, \(decoded.inner.count) inner module bytes):")
            print("  Colors (\(table.colors.count)):")
            for name in table.colors.keys.sorted() {
                let c = table.colors[name]!
                let dark = c.dark.map { String(format: " dark=(%.3f,%.3f,%.3f,%.3f)", $0.r, $0.g, $0.b, $0.a) } ?? ""
                print(String(format: "    %@ = (%.3f,%.3f,%.3f,%.3f)%@", name, c.r, c.g, c.b, c.a, dark))
            }
            print("  Strings (\(table.stringCount)):")
            for locale in table.strings.keys.sorted() {
                let label = locale.isEmpty ? "(base)" : locale
                for key in table.strings[locale]!.keys.sorted() {
                    let o = table.strings[locale]![key]!
                    let tbl = o.table.isEmpty ? "" : " [table=\(o.table)]"
                    print("    [\(label)] \(key) = \"\(o.value)\"\(tbl)")
                }
            }
            print("  Images (\(table.images.count)):")
            for name in table.images.keys.sorted() {
                let img = table.images[name]!
                print("    \(name) = \(img.kind == .inline ? "\(img.payload.count) bytes" : "ref") "
                      + "(@\(img.scale)x, \(img.mime.isEmpty ? "?" : img.mime))")
            }
        }
    }

    // MARK: - shared

    /// Resolve the module path: explicit `--module`, else the project's
    /// `.Patch/build/module.wasm` (found via `.Patch.yml`), else CWD's.
    static func resolveModuleURL(_ explicit: String?) throws -> URL {
        if let explicit { return URL(fileURLWithPath: explicit) }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let configURL = PatchConfig.find(startingAt: cwd) {
            return CLISupport.projectRoot(for: configURL)
                .appendingPathComponent(".Patch/build/module.wasm")
        }
        return cwd.appendingPathComponent(".Patch/build/module.wasm")
    }
}
