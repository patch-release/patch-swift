// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PatchCLI

/// `.Patch.yml` gained a live secret (`publish_token`) when the credential split
/// landed. Before that it held only `app_key` — public, and baked into the app
/// binary anyway — so committing it was harmless, which is exactly why no
/// project ignores it today. These pin the guard that closes that gap.
///
/// The failure this prevents is quiet and expensive: `patchcli init` writes a
/// token, the developer runs `git add .`, and a credential that can ship code to
/// every user of the app is in the repo (and its history) forever.
final class GitIgnoreGuardTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitignore-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRepo() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    private func writeIgnore(_ s: String) throws {
        try s.write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    }

    private func readIgnore() -> String {
        (try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
    }

    // MARK: - Adding

    func testAddsEntryWhenGitignoreAbsent() throws {
        try makeRepo()
        guard case .added = GitIgnoreGuard.ensureIgnored(root: root) else {
            return XCTFail("expected .added")
        }
        XCTAssertTrue(readIgnore().contains(".Patch.yml"))
        XCTAssertEqual(GitIgnoreGuard.ignoreState(root: root).isIgnored, true)
    }

    func testAppendsWithoutDestroyingExistingRules() throws {
        try makeRepo()
        try writeIgnore("build/\n*.xcuserstate\n")
        guard case .added = GitIgnoreGuard.ensureIgnored(root: root) else {
            return XCTFail("expected .added")
        }
        let out = readIgnore()
        // A .gitignore is hand-curated; mangling it is worse than a missing entry.
        XCTAssertTrue(out.contains("build/"))
        XCTAssertTrue(out.contains("*.xcuserstate"))
        XCTAssertTrue(out.contains(".Patch.yml"))
    }

    /// A file with no trailing newline must not get its last rule glued to ours.
    func testDoesNotCorruptLastRuleWhenFileLacksTrailingNewline() throws {
        try makeRepo()
        try writeIgnore("build/\n*.xcuserstate")   // no trailing \n
        _ = GitIgnoreGuard.ensureIgnored(root: root)
        let lines = readIgnore().split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("*.xcuserstate"), "last pre-existing rule was corrupted: \(lines)")
        XCTAssertTrue(lines.contains(".Patch.yml"))
    }

    // MARK: - Idempotence

    func testSecondRunIsANoOp() throws {
        try makeRepo()
        _ = GitIgnoreGuard.ensureIgnored(root: root)
        let after1 = readIgnore()
        guard case .alreadyIgnored = GitIgnoreGuard.ensureIgnored(root: root) else {
            return XCTFail("expected .alreadyIgnored on the second run")
        }
        // `init` and `login` are both re-runnable; repeated runs must not stack
        // duplicate blocks into the file.
        XCTAssertEqual(readIgnore(), after1)
    }

    func testRecognizesExistingRuleVariants() throws {
        for rule in [".Patch.yml", "/.Patch.yml", ".Patch.yml/"] {
            try tearDownWithError(); try setUpWithError(); try makeRepo()
            try writeIgnore("\(rule)\n")
            guard case .alreadyIgnored = GitIgnoreGuard.ensureIgnored(root: root) else {
                return XCTFail("rule \(rule) should count as already ignored")
            }
        }
    }

    // MARK: - The two dangerous false-positives

    /// A COMMENT naming the file must not read as protection.
    func testCommentMentioningTheFileIsNotProtection() throws {
        try makeRepo()
        try writeIgnore("# remember to ignore .Patch.yml one day\n")
        guard case .added = GitIgnoreGuard.ensureIgnored(root: root) else {
            return XCTFail("a comment must not count as an ignore rule")
        }
    }

    /// `!.Patch.yml` explicitly UN-ignores the file. Treating it as ignored would
    /// report a secret as protected while git happily commits it.
    func testNegationIsNotProtection() throws {
        try makeRepo()
        try writeIgnore("*.yml\n!.Patch.yml\n")
        guard case .added = GitIgnoreGuard.ensureIgnored(root: root) else {
            return XCTFail("a `!` negation must not count as ignored")
        }
    }

    // MARK: - Non-repos

    /// Never litter a .gitignore into a directory that isn't a repo — and never
    /// write one into a subdirectory of somebody else's repo.
    func testDoesNotCreateGitignoreOutsideARepo() throws {
        guard case .notAGitRepo = GitIgnoreGuard.ensureIgnored(root: root) else {
            return XCTFail("expected .notAGitRepo")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitignore").path))
    }

    // MARK: - Read-only state (what `doctor` uses)

    func testIgnoreStateNeverWrites() throws {
        try makeRepo()
        let state = GitIgnoreGuard.ignoreState(root: root)
        XCTAssertEqual(state.isIgnored, false)
        // doctor is contractually read-only and CI-safe; a diagnostic that
        // mutates the checkout would break that.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitignore").path))
    }

    func testIgnoreStateAgreesWithEnsureIgnored() throws {
        try makeRepo()
        XCTAssertEqual(GitIgnoreGuard.ignoreState(root: root).isIgnored, false)
        _ = GitIgnoreGuard.ensureIgnored(root: root)
        XCTAssertEqual(GitIgnoreGuard.ignoreState(root: root).isIgnored, true)
    }
}

private extension GitIgnoreGuard.State {
    /// Test-only convenience; `.notAGitRepo`/`.unknown` are neither.
    var isIgnored: Bool? {
        switch self {
        case .ignored: return true
        case .notIgnored: return false
        case .notAGitRepo, .unknown: return nil
        }
    }
}
