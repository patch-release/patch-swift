// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler
@testable import PatchCLI

/// `CLISupport.resolveAPIKey` — the client half of the app_key / publish-token split.
///
/// THE BUG THIS PINS: `resolveAPIKey` used to fall back to `config.appKey`. That
/// key is baked into the developer's app source by `patchcli init`, so it ships
/// inside every IPA and is recoverable with `strings` — and sending it as
/// `X-API-Key` made it a publish credential. Anyone who downloaded a published
/// app could extract it and push arbitrary WebAssembly to every user of that app.
///
/// `app_key` must now never be used as a publish credential, and a project with
/// no publish token must fail with an actionable message rather than an opaque 401.
final class PublishCredentialTests: XCTestCase {

    // MARK: - helpers

    /// A config with no ambient environment interference.
    private func makeConfig(
        appKey: String = "",
        apiKey: String? = nil,
        publishToken: String? = nil
    ) -> PatchConfig {
        PatchConfig(
            appKey: appKey,
            project: "MyApp.xcodeproj",
            target: "MyApp",
            apiKey: apiKey,
            publishToken: publishToken
        )
    }

    /// Run `body` with `PATCH_API_KEY` set to `value` (or unset when nil), then
    /// restore. `resolveAPIKey` reads the process environment, so a test that
    /// leaves it set would leak into every later test in the same process.
    private func withEnv(_ value: String?, _ body: () throws -> Void) rethrows {
        let name = "PATCH_API_KEY"
        let previous = ProcessInfo.processInfo.environment[name]
        if let value { setenv(name, value, 1) } else { unsetenv(name) }
        defer {
            if let previous { setenv(name, previous, 1) } else { unsetenv(name) }
        }
        try body()
    }

    // MARK: - the vulnerability: app_key is never a publish credential

    func testAppKeyIsNotUsedAsAPublishCredential() throws {
        // The exact shape `patchcli init` used to leave behind: a real app_key,
        // nothing else. This MUST NOT resolve.
        let cfg = makeConfig(appKey: "pak_\(String(repeating: "a", count: 64))")
        try withEnv(nil) {
            XCTAssertNil(
                CLISupport.resolveAPIKey(config: cfg),
                "app_key ships inside the app binary and must never authorize a push")
        }
    }

    func testAppKeyInTheApiKeySlotIsAlsoRejected() throws {
        // A developer who pasted their app_key into `api_key:` (an easy mistake
        // when the two were interchangeable) gets the actionable error, not a 401.
        let cfg = makeConfig(apiKey: "pak_\(String(repeating: "b", count: 64))")
        try withEnv(nil) {
            XCTAssertNil(CLISupport.resolveAPIKey(config: cfg))
        }
    }

    func testAppKeyInTheEnvVarIsAlsoRejected() throws {
        let cfg = makeConfig()
        try withEnv("pak_\(String(repeating: "c", count: 64))") {
            XCTAssertNil(CLISupport.resolveAPIKey(config: cfg))
        }
    }

    func testAppKeyIsIgnoredEvenWhenAPublishTokenIsAlsoPresent() throws {
        // Precedence sanity: the presence of an app_key must not shadow the real
        // credential either.
        let cfg = makeConfig(
            appKey: "pak_\(String(repeating: "d", count: 64))",
            publishToken: "ppt_token_value")
        try withEnv(nil) {
            XCTAssertEqual(CLISupport.resolveAPIKey(config: cfg), "ppt_token_value")
        }
    }

    // MARK: - the publish token resolves

    func testPublishTokenFromConfigResolves() throws {
        let cfg = makeConfig(publishToken: "ppt_abc123")
        try withEnv(nil) {
            XCTAssertEqual(CLISupport.resolveAPIKey(config: cfg), "ppt_abc123")
        }
    }

    func testEnvVarWinsOverConfig() throws {
        let cfg = makeConfig(publishToken: "ppt_from_config")
        try withEnv("ppt_from_env") {
            XCTAssertEqual(CLISupport.resolveAPIKey(config: cfg), "ppt_from_env")
        }
    }

    func testPublishTokenWinsOverApiKey() throws {
        let cfg = makeConfig(apiKey: "legacy_key", publishToken: "ppt_preferred")
        try withEnv(nil) {
            XCTAssertEqual(CLISupport.resolveAPIKey(config: cfg), "ppt_preferred")
        }
    }

    func testApiKeyStillResolvesForSelfHostedAndCI() throws {
        // The platform PATCH_API_KEY (admin / CI) is not a `ppt_` value, so the
        // resolver must not require that prefix.
        let cfg = makeConfig(apiKey: "platform-shared-secret")
        try withEnv(nil) {
            XCTAssertEqual(CLISupport.resolveAPIKey(config: cfg), "platform-shared-secret")
        }
    }

    // MARK: - unset / placeholder / whitespace handling

    func testEmptyConfigResolvesToNil() throws {
        try withEnv(nil) {
            XCTAssertNil(CLISupport.resolveAPIKey(config: makeConfig()))
        }
    }

    func testPlaceholderIsTreatedAsUnset() throws {
        let cfg = makeConfig(appKey: CLISupport.placeholderAppKey)
        try withEnv(nil) {
            XCTAssertNil(CLISupport.resolveAPIKey(config: cfg))
        }
    }

    func testEmptyEnvVarFallsThroughToConfig() throws {
        let cfg = makeConfig(publishToken: "ppt_config_value")
        try withEnv("") {
            XCTAssertEqual(CLISupport.resolveAPIKey(config: cfg), "ppt_config_value")
        }
    }

    func testWhitespaceOnlyTokenIsTreatedAsUnset() throws {
        let cfg = makeConfig(publishToken: "   ")
        try withEnv(nil) {
            XCTAssertNil(CLISupport.resolveAPIKey(config: cfg))
        }
    }

    func testSurroundingWhitespaceIsTrimmed() throws {
        // A token pasted from a browser often carries a trailing newline; sending
        // it verbatim produced a mystifying 401.
        let cfg = makeConfig(publishToken: "  ppt_padded\n")
        try withEnv(nil) {
            XCTAssertEqual(CLISupport.resolveAPIKey(config: cfg), "ppt_padded")
        }
    }

    // MARK: - the error a credential-less project gets

    func testMissingCredentialMessageIsActionable() {
        let message = CLISupport.noPublishCredentialMessage
        XCTAssertTrue(message.contains("patchcli login"),
                      "must name the command that fixes it")
        XCTAssertTrue(message.contains("PATCH_API_KEY"),
                      "must mention the CI escape hatch")
        XCTAssertTrue(message.lowercased().contains("app_key"),
                      "must explain why the app_key they hold does not work")
    }

    func testMakeAPIThrowsTheActionableErrorWithNoCredential() throws {
        let cfg = makeConfig(appKey: "pak_\(String(repeating: "e", count: 64))")
        try withEnv(nil) {
            XCTAssertThrowsError(try CLISupport.makeAPI(config: cfg)) { error in
                let text = "\(error)"
                XCTAssertTrue(text.contains("patchcli login"), "got: \(text)")
            }
        }
    }

    func testMakeAPISucceedsWithAPublishToken() throws {
        let cfg = makeConfig(apiKey: nil, publishToken: "ppt_valid")
        try withEnv(nil) {
            let api = try CLISupport.makeAPI(config: cfg)
            XCTAssertEqual(api.apiKey, "ppt_valid")
        }
    }

    // MARK: - .Patch.yml round-trip

    func testPublishTokenRoundTripsThroughYAML() throws {
        var cfg = makeConfig(appKey: "pak_public", publishToken: "ppt_secret")
        cfg.appId = "11111111-1111-1111-1111-111111111111"
        let reparsed = try PatchConfig.parse(cfg.yamlString())
        XCTAssertEqual(reparsed.publishToken, "ppt_secret")
        XCTAssertEqual(reparsed.appKey, "pak_public")
        XCTAssertEqual(reparsed.appId, cfg.appId)
    }

    func testAbsentPublishTokenIsNotEmittedIntoYAML() throws {
        let cfg = makeConfig(appKey: "pak_public")
        XCTAssertFalse(cfg.yamlString().contains("publish_token:"),
                       "an absent token must not be written as an empty key")
        XCTAssertNil(try PatchConfig.parse(cfg.yamlString()).publishToken)
    }

    // MARK: - the link payload carries the token

    func testLinkedAppDecodesAPublishToken() {
        let app = CliLinkPollResult.LinkedApp(
            id: "app-id", workspaceId: "ws-id", name: "App",
            bundleId: "com.acme.app", appKey: "pak_public",
            publishToken: "ppt_secret")
        XCTAssertEqual(app.publishToken, "ppt_secret")
        XCTAssertNotEqual(app.publishToken, app.appKey)
    }

    func testLinkedAppToleratesAMissingPublishToken() {
        // A backend predating the split must not break decoding — the CLI reports
        // the gap instead (see Init/Login).
        let app = CliLinkPollResult.LinkedApp(
            id: "app-id", workspaceId: "ws-id", name: "App",
            bundleId: "com.acme.app", appKey: "pak_public")
        XCTAssertNil(app.publishToken)
    }
}
