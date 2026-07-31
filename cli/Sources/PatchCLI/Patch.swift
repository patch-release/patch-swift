// SPDX-License-Identifier: Apache-2.0

import ArgumentParser

/// Patch CLI entry point.
///
/// Full developer command set: init, build, push, release (build+push), status,
/// rollback, fingerprint, channels, whoami, analyze (+ the lower-level compile).
/// `build`/`release` drive the REAL engine and the REAL WASM toolchain;
/// push/release/status/rollback/fingerprint/channels talk to the REAL backend with
/// CLI-token auth. `ship` is a hidden, deprecated alias for `release`.
@main
struct Patch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patchcli",
        abstract: "OTA code updates for native Swift iOS apps — auto-partitioning engine.",
        version: "1.7.0",
        subcommands: [
            Setup.self, Init.self, Prepare.self, Doctor.self, Build.self, Push.self, Release.self, Status.self, Rollback.self,
            FingerprintCommand.self, Channels.self, Whoami.self, Analyze.self, Compile.self, Overlay.self,
            // Deprecated alias for `release`; hidden from --help, still functional.
            Ship.self,
        ]
        // NO `defaultSubcommand`: with one, ArgumentParser routes an UNKNOWN verb
        // (`patchcli deploy`) into the default command's positional argument, so
        // `analyze`'s `<path>` swallowed `deploy` and the user saw a misleading
        // "Path not found: deploy" instead of "unknown subcommand". Without it,
        // `patchcli deploy` errors with the correct "Unknown subcommand or argument
        // 'deploy'" + usage, and bare `patchcli` prints help/usage. `analyze` is still
        // run explicitly: `patchcli analyze <path>` (its CI use was always explicit).
    )
}
