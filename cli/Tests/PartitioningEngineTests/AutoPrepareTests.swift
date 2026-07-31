// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CodeGenerator
@testable import Compiler
@testable import PatchCLI

/// Tests for AUTO-PREPARE — the DX fix that runs `patchcli prepare`'s logic
/// automatically (idempotently, quietly) before every `build`/`push`/`release`,
/// so a developer never has to remember to re-run `patchcli prepare` after adding
/// a new view. These exercise the shared `AutoPrepare` helper that all three
/// commands call (it invokes the very same `Prepare.execute` `patchcli init` uses).
final class AutoPrepareTests: XCTestCase {

    // MARK: - Scaffolding

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoprep-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// An un-prepared SwiftUI view (no `dynamic`, no thunk block).
    private let unpreparedView = """
    import SwiftUI
    struct MyView: View {
        var body: some View { Text("hi") }
    }
    """

    // MARK: - Core: a NEW un-prepared view gets dynamic + thunks

    func testAutoPrepAddsDynamicAndThunksToNewView() throws {
        let dir = try makeTempDir("adds")
        let viewURL = dir.appendingPathComponent("MyView.swift")
        try write(unpreparedView, to: viewURL)

        // Default config (auto-prepare ON), no --no-prepare flag.
        AutoPrepare.run(root: dir, excludes: [], target: nil,
                        noPrepareFlag: false, config: PatchConfig())

        let after = read(viewURL)
        XCTAssertTrue(after.contains("dynamic var body"),
                      "auto-prepare should insert `dynamic` on the view body. Got:\n\(after)")
        // HYBRID placement: a non-private view's thunk goes to the dedicated generated
        // folder, NOT into the developer's file — so NO same-file block here.
        XCTAssertFalse(after.contains(ThunkGenerator.sameFileBeginMarker),
                       "a non-private view's file must NOT get a same-file block (hybrid). Got:\n\(after)")
        // The body is still patchable after editing — it parses.
        XCTAssertTrue(ThunkGenerator.parses(after), "edited source must still parse")

        // The thunk landed in the dedicated, gitignored generated folder.
        let genURL = dir.appendingPathComponent("Patch/Generated/PatchThunks.generated.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: genURL.path),
                      "the generated-folder thunk file should exist")
        let gen = read(genURL)
        XCTAssertTrue(gen.contains("extension MyView {"), gen)
        XCTAssertTrue(gen.contains("@_dynamicReplacement(for: body)"), gen)
        XCTAssertTrue(ThunkGenerator.parses(gen), "the generated file must parse")
        // The generated folder is gitignored (root rule + in-folder .gitignore).
        XCTAssertTrue(read(dir.appendingPathComponent(".gitignore")).contains("Patch/Generated/"),
                      "the root .gitignore must ignore the generated folder")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Patch/Generated/.gitignore").path),
                      "an in-folder .gitignore should be written")
    }

    // MARK: - Opt-out: --no-prepare flag

    func testNoPrepareFlagSkips() throws {
        let dir = try makeTempDir("flag-skip")
        let viewURL = dir.appendingPathComponent("MyView.swift")
        try write(unpreparedView, to: viewURL)

        AutoPrepare.run(root: dir, excludes: [], target: nil,
                        noPrepareFlag: true, config: PatchConfig())  // --no-prepare

        let after = read(viewURL)
        XCTAssertEqual(after, unpreparedView, "--no-prepare must leave source untouched")
        XCTAssertFalse(after.contains("dynamic var body"))
        XCTAssertFalse(after.contains(ThunkGenerator.sameFileBeginMarker))
    }

    // MARK: - Opt-out: build.auto_prepare = false in config

    func testConfigAutoPrepareFalseSkips() throws {
        let dir = try makeTempDir("config-skip")
        let viewURL = dir.appendingPathComponent("MyView.swift")
        try write(unpreparedView, to: viewURL)

        var cfg = PatchConfig()
        cfg.buildAutoPrepare = false
        AutoPrepare.run(root: dir, excludes: [], target: nil, noPrepareFlag: false, config: cfg)

        XCTAssertEqual(read(viewURL), unpreparedView,
                       "auto_prepare: false must leave source untouched")
    }

    func testConfigAutoPrepareDefaultsOnWhenOmitted() throws {
        // An omitted `auto_prepare:` in .Patch.yml parses to the default (ON).
        let cfg = try PatchConfig.parse("""
        version: 1
        app_key: pak_x
        target: App
        build:
          optimization: size
        """)
        XCTAssertTrue(cfg.buildAutoPrepare, "auto_prepare must default ON when omitted")
        XCTAssertTrue(AutoPrepare.enabled(noPrepareFlag: false, config: cfg))
    }

    func testConfigAutoPrepareParsedFalse() throws {
        let cfg = try PatchConfig.parse("""
        version: 1
        app_key: pak_x
        target: App
        build:
          auto_prepare: false
        """)
        XCTAssertFalse(cfg.buildAutoPrepare)
        XCTAssertFalse(AutoPrepare.enabled(noPrepareFlag: false, config: cfg))
    }

    // MARK: - Precedence: --no-prepare flag overrides config ON

    func testFlagOverridesConfigOn() throws {
        var cfg = PatchConfig()
        cfg.buildAutoPrepare = true
        XCTAssertFalse(AutoPrepare.enabled(noPrepareFlag: true, config: cfg),
                       "--no-prepare must override config auto_prepare: true")
    }

    // MARK: - Idempotency: re-running auto-prep on a prepared project is a no-op

    func testIdempotentReRunNoOps() throws {
        let dir = try makeTempDir("idem")
        let viewURL = dir.appendingPathComponent("MyView.swift")
        try write(unpreparedView, to: viewURL)

        // First run prepares it.
        AutoPrepare.run(root: dir, excludes: [], target: nil, noPrepareFlag: false, config: PatchConfig())
        let firstPass = read(viewURL)
        XCTAssertTrue(firstPass.contains("dynamic var body"))
        // Hybrid: the (non-private) view's file gets only `dynamic`, no same-file block.
        XCTAssertFalse(firstPass.contains(ThunkGenerator.sameFileBeginMarker))
        let genURL = dir.appendingPathComponent("Patch/Generated/PatchThunks.generated.swift")
        let firstGen = read(genURL)
        XCTAssertTrue(firstGen.contains("extension MyView {"))

        // Second run must be a no-op: BOTH the source AND the generated file are
        // byte-identical (deterministic regeneration; `dynamic` is already there).
        AutoPrepare.run(root: dir, excludes: [], target: nil, noPrepareFlag: false, config: PatchConfig())
        let secondPass = read(viewURL)
        XCTAssertEqual(secondPass, firstPass, "re-running auto-prepare must be a no-op (source)")
        XCTAssertEqual(read(genURL), firstGen, "re-running auto-prepare must be a no-op (generated file)")

        // And `countUnpreparedViews` reports 0 once prepared (it's the "N new" signal).
        XCTAssertEqual(AutoPrepare.countUnpreparedViews(root: dir, excludes: []), 0)
    }

    // MARK: - The "N new view(s)" signal

    func testCountUnpreparedViewsCountsNewViewsOnly() throws {
        let dir = try makeTempDir("count")
        // One already-dynamic view + one brand-new un-prepared view → 1 "new".
        try write("""
        import SwiftUI
        struct OldView: View {
            dynamic var body: some View { Text("old") }
        }
        struct NewView: View {
            var body: some View { Text("new") }
        }
        """, to: dir.appendingPathComponent("Views.swift"))
        XCTAssertEqual(AutoPrepare.countUnpreparedViews(root: dir, excludes: []), 1,
                       "only the un-prepared (non-dynamic) view counts as new")
    }

    // MARK: - Graceful degradation: a failing prepare never crashes / corrupts

    func testFailureDegradesGracefullyNoSources() throws {
        // A directory with NO Swift sources makes `Prepare.execute` throw
        // (ValidationError "No Swift sources found"). Auto-prepare must NOT propagate
        // that — it warns + returns so the build can continue. Just calling it without
        // throwing/crashing is the assertion (the method is non-throwing by signature).
        let dir = try makeTempDir("fail-nosrc")
        try write("not swift", to: dir.appendingPathComponent("README.txt"))

        // Must not throw — non-throwing signature; this exercises the catch path.
        AutoPrepare.run(root: dir, excludes: [], target: nil, noPrepareFlag: false, config: PatchConfig())

        // The non-source file is untouched.
        XCTAssertEqual(read(dir.appendingPathComponent("README.txt")), "not swift")
    }

    func testFailureDoesNotCorruptSourceWhenViewExcluded() throws {
        // Auto-prepare must never leave a developer's source corrupted. Here the only
        // source's directory exists but the view stays byte-identical because the run
        // can't find anything to prepare under a nonexistent root — and even if it
        // could, the underlying writeSourcesWithBackupVerify restores on a parse break.
        // We assert the original view is unharmed when auto-prepare points at a missing
        // subdir (a degenerate input that yields no sources → graceful no-op).
        let dir = try makeTempDir("fail-missing")
        let viewURL = dir.appendingPathComponent("MyView.swift")
        try write(unpreparedView, to: viewURL)
        let missing = dir.appendingPathComponent("does-not-exist")

        AutoPrepare.run(root: missing, excludes: [], target: nil,
                        noPrepareFlag: false, config: PatchConfig())

        XCTAssertEqual(read(viewURL), unpreparedView,
                       "a view outside the (missing) prepare root must be untouched")
    }

    // MARK: - No SwiftUI views: silent no-op (not a failure)

    func testNoViewsIsQuietNoOp() throws {
        let dir = try makeTempDir("noviews")
        let helperURL = dir.appendingPathComponent("Helper.swift")
        try write("""
        import Foundation
        struct Helper { func go() {} }
        """, to: helperURL)

        AutoPrepare.run(root: dir, excludes: [], target: nil, noPrepareFlag: false, config: PatchConfig())

        // No views → nothing to prepare → source untouched, no crash.
        XCTAssertTrue(read(helperURL).contains("struct Helper"))
        XCTAssertFalse(read(helperURL).contains(ThunkGenerator.sameFileBeginMarker))
        XCTAssertEqual(AutoPrepare.countUnpreparedViews(root: dir, excludes: []), 0)
    }

    // MARK: - PATCH_AUTO_PREPARE env override

    func testEnvOverrideDisables() throws {
        setenv("PATCH_AUTO_PREPARE", "0", 1)
        defer { unsetenv("PATCH_AUTO_PREPARE") }
        // Config says ON, but env "0" disables.
        XCTAssertFalse(AutoPrepare.enabled(noPrepareFlag: false, config: PatchConfig()))
    }

    func testEnvOverrideEnablesOverConfigOff() throws {
        setenv("PATCH_AUTO_PREPARE", "1", 1)
        defer { unsetenv("PATCH_AUTO_PREPARE") }
        var cfg = PatchConfig()
        cfg.buildAutoPrepare = false  // config says OFF…
        XCTAssertTrue(AutoPrepare.enabled(noPrepareFlag: false, config: cfg),
                      "PATCH_AUTO_PREPARE=1 should re-enable over config off")
        // …but the --no-prepare flag still wins (highest precedence).
        XCTAssertFalse(AutoPrepare.enabled(noPrepareFlag: true, config: cfg))
    }
}
