// SPDX-License-Identifier: Apache-2.0

import Foundation
import ArgumentParser
import Compiler

/// `patchcli login` — obtain a PUBLISH TOKEN and store it in `.Patch.yml`.
///
/// This is the standalone half of what `patchcli init` step 1 does: it runs the
/// same device-code-style browser hand-off (`LinkAPI.swift`), and on confirm
/// writes the delivered `publish_token` (plus `app_id` / `workspace_id` /
/// `app_key` if they are not already pinned).
///
/// Why it exists as its own command:
///
///   * **Recovery for existing projects.** An app registered before the
///     credential split has an `app_key` in `.Patch.yml` and no publish token.
///     `app_key` is a PUBLIC device identifier — it is baked into
///     `Patch.configure(appKey:)`, so it ships inside the app binary and is
///     recoverable from any published IPA with `strings`. It therefore cannot
///     authorize a push, and the backend rejects it. One `patchcli login` mints
///     the real credential without re-running the whole `init` flow.
///   * **Rotation.** A leaked or retired token is replaced by running this again
///     (revoke the old one in the console).
///
/// The token is never printed — only written to `.Patch.yml`.
struct Login: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Get a publish token for this project (opens your browser) and save it to .Patch.yml."
    )

    @Option(name: .long, help: "Backend base URL override.")
    var baseURL: String?

    @Flag(name: .long, help: "Don't auto-open the browser (the URL is printed instead).")
    var noOpen: Bool = false

    func run() throws {
        var (config, configURL) = try CLISupport.loadConfig()

        // The link session is keyed by bundle id — the console matches it to an
        // existing app (re-auth) or offers to create one.
        guard let bundleId = config.bundleId, !bundleId.isEmpty else {
            throw ValidationError("""
                No `bundle_id:` in .Patch.yml, so there is nothing to log in for.

                Add `bundle_id: com.your.app` (the identifier your app ships \
                with), or run `patchcli init` to detect it automatically.
                """)
        }
        let appName = config.target.isEmpty ? bundleId : config.target

        let base = CLISupport.resolveBaseURL(baseURL, config: config)
        guard let baseURLParsed = URL(string: base) else {
            throw ValidationError("Invalid backend base URL: \(base)")
        }

        let api = HTTPCliLinkAPI(baseURL: baseURLParsed)
        print("Patch login")
        print("===========")
        print("  Contacting \(baseURLParsed.host ?? base)…")

        let session: CliLinkSession
        do {
            session = try api.createLink(bundleId: bundleId, name: appName, platform: "ios")
        } catch {
            throw ValidationError("Couldn't reach the Patch backend (\(error)).")
        }

        print("  Confirm in your browser:")
        print("")
        print("      \(session.connectURL)")
        print("")
        if !noOpen {
            Init.openInBrowser(session.connectURL)
            print("  (Opened in your default browser — if not, paste the URL above.)")
        }
        print("  Waiting for confirmation… (Ctrl-C to abort; expires in \(session.expiresInSeconds / 60) min)")

        let isTTY = isatty(1) == 1
        let outcome = CliLinkWait.wait(api: api, session: session, onPoll: { attempt in
            if isTTY && attempt % 5 == 0 {
                print("  … still waiting (\(attempt * session.pollIntervalSeconds)s)")
            }
        })

        switch outcome {
        case .linked(let app, _):
            guard let token = app.publishToken, !token.isEmpty else {
                throw ValidationError("""
                    The backend confirmed the app but returned no publish token.

                    It is probably running a version that predates publish tokens. \
                    Create one in the console under Settings → CLI tokens and set \
                    `publish_token:` in .Patch.yml (or the PATCH_API_KEY env var).
                    """)
            }
            config.publishToken = token
            // Fill in identity only where it is not already pinned, so `login`
            // never silently repoints an existing project at a different app.
            if (config.appId ?? "").isEmpty { config.appId = app.id }
            if (config.workspaceId ?? "").isEmpty { config.workspaceId = app.workspaceId }
            if !Init.isRealKey(config.appKey) { config.appKey = app.appKey }

            do {
                try config.yamlString().write(to: configURL, atomically: true, encoding: .utf8)
            } catch {
                // Deliberately does NOT echo the token — CLI output ends up in
                // scrollback, CI logs and pasted bug reports.
                throw ValidationError(
                    "Got a publish token but couldn't write \(configURL.path): \(error)\n"
                    + "Fix the file permissions and re-run `patchcli login`.")
            }
            print("")
            print("  ✓ Publish token saved to \(configURL.lastPathComponent) — you can push now.")
            print("  → Keep .Patch.yml out of version control; it holds a live credential.")
            print("  → For CI, set PATCH_API_KEY instead of committing the token.")
        case .expired, .timedOut:
            throw ValidationError("The browser confirmation wasn't completed in time. Re-run `patchcli login`.")
        case .consumed:
            throw ValidationError("This link was already used. Re-run `patchcli login` for a fresh one.")
        case .failed(let message):
            throw ValidationError("Gave up polling after repeated errors: \(message)")
        }
    }
}
