// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation

/// Subprocess tests for the `ship` → `release` rename on the real CLI binary.
///
/// The command structs live in the non-importable `PatchCLI` executable, so we
/// exercise them the only honest way: run the built `patchcli` binary and inspect
/// its `--help` / stderr. Proves three contracts the rename promises:
///   1. `patchcli release --help` works and is the renamed command.
///   2. `patchcli ship --help` STILL works (the deprecated back-compat alias).
///   3. Running `patchcli ship` prints the one-line deprecation notice to **stderr**
///      (so scripts parsing stdout are unaffected) before doing the release flow.
final class ShipAliasTests: XCTestCase {

    /// Locate the built `patchcli` executable next to the test bundle. `swift test`
    /// builds it into the same products dir as the test bundle.
    private func patchBinary() throws -> URL {
        #if os(macOS)
        let bundle = Bundle(for: type(of: self))
        let productsDir = bundle.bundleURL.deletingLastPathComponent()
        let url = productsDir.appendingPathComponent("patchcli")
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        #endif
        // Fallback: the conventional debug build location relative to the package.
        // (#file is …/cli/Tests/PartitioningEngineTests/ShipAliasTests.swift)
        let pkgRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()   // PartitioningEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // cli (package root)
        let debug = pkgRoot.appendingPathComponent(".build/debug/patchcli")
        if FileManager.default.isExecutableFile(atPath: debug.path) { return debug }
        throw XCTSkip("patchcli binary not found (looked next to the test bundle and in .build/debug). " +
                      "Run `swift build` first.")
    }

    /// Run the binary, returning (stdout, stderr, exitCode). Uses a throwaway CWD
    /// with no `.Patch.yml` so commands that need config fail fast — we only care
    /// about help text / the deprecation banner, both emitted before any I/O.
    private func run(_ args: [String]) throws -> (out: String, err: String, code: Int32) {
        let binary = try patchBinary()
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = args
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-ship-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        proc.currentDirectoryURL = tmp

        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        // Read BEFORE wait to avoid deadlock on large output (help is small, but safe).
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self),
                proc.terminationStatus)
    }

    func testReleaseHelpShowsRenamedCommand() throws {
        let r = try run(["release", "--help"])
        XCTAssertEqual(r.code, 0, "`release --help` should exit 0; stderr: \(r.err)")
        // ArgumentParser prints the usage line with the command name.
        XCTAssertTrue(r.out.contains("patchcli release"),
                      "help should reference the `patchcli release` command name; got:\n\(r.out)")
        XCTAssertFalse(r.out.contains("Patch release"),
                       "the command was renamed to `patchcli`; got:\n\(r.out)")
        XCTAssertTrue(r.out.lowercased().contains("release a patch") ||
                      r.out.contains("--rollout"),
                      "help should describe the release command; got:\n\(r.out)")
    }

    func testShipAliasHelpStillWorks() throws {
        let r = try run(["ship", "--help"])
        XCTAssertEqual(r.code, 0, "the deprecated `ship --help` must still work; stderr: \(r.err)")
        XCTAssertTrue(r.out.contains("patchcli ship"),
                      "ship alias help should still render with the command name; got:\n\(r.out)")
        // It carries the same push flags it forwards to `release`.
        XCTAssertTrue(r.out.contains("--rollout"),
                      "ship alias should accept the same flags as release; got:\n\(r.out)")
    }

    func testShipAliasPrintsDeprecationNoticeToStderr() throws {
        // No `.Patch.yml` in the temp CWD → the release flow errors out, but the
        // deprecation banner is written to stderr FIRST, before any config load.
        let r = try run(["ship", "--dry-run"])
        XCTAssertTrue(r.err.contains("`patchcli ship` is now `patchcli release`"),
                      "the deprecated alias must warn on stderr; stderr was:\n\(r.err)")
        // The banner must NOT leak onto stdout (scripts parse stdout).
        XCTAssertFalse(r.out.contains("`patchcli ship` is now `patchcli release`"),
                       "deprecation banner must go to stderr, not stdout; stdout was:\n\(r.out)")
    }

    // MARK: - Launch rename + version contract

    /// `patchcli --version` prints the current version (the invoked command was
    /// renamed from `patch` to `patchcli` to avoid colliding with `/usr/bin/patch`).
    func testVersionFlagPrintsCurrentVersion() throws {
        let r = try run(["--version"])
        XCTAssertEqual(r.code, 0, "`--version` should exit 0; stderr: \(r.err)")
        // Assert a valid MAJOR.MINOR.PATCH semver rather than a hardcoded literal —
        // a pinned version string silently rots on every release bump (it did: it
        // was stuck at an old value while the binary moved on). This proves the
        // contract — `--version` prints a real version — without going stale.
        let version = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression),
                        "patchcli --version must print a MAJOR.MINOR.PATCH version; got:\n\(r.out)")
        XCTAssertNotEqual(version, "0.2.0", "the old 0.2.0 version must be gone; got:\n\(r.out)")
    }

    /// The root `--help` usage line is the `patchcli` command (the rename: the old
    /// `patch` executable collided with `/usr/bin/patch`, the GNU diff/patch tool,
    /// so it is now `patchcli`).
    func testRootUsageLineIsPatchcli() throws {
        let r = try run(["--help"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("USAGE: patchcli <subcommand>"),
                      "root usage line should be `patchcli`; got:\n\(r.out)")
        XCTAssertFalse(r.out.contains("USAGE: Patch"),
                       "the capital-`Patch` command name must be gone from usage; got:\n\(r.out)")
    }

    func testShipIsHiddenFromTopLevelHelp() throws {
        // `ship` is registered as a hidden alias: it works, but is not advertised
        // in the root command's subcommand listing (so docs point at `release`).
        let r = try run(["--help"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("release"),
                      "root help should list the `release` subcommand; got:\n\(r.out)")
        // Hidden subcommands are omitted from the SUBCOMMANDS section.
        XCTAssertFalse(r.out.contains("\n  ship "),
                       "the deprecated `ship` alias should be hidden from --help; got:\n\(r.out)")
    }
}
