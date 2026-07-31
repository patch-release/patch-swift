// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
@testable import Compiler
@testable import PatchCLI

/// End-to-end `Prepare.execute` HYBRID placement: the generated thunks land in a
/// dedicated, gitignored `Patch/Generated/` folder that is wired into the build for BOTH
/// project shapes (SwiftPM + Xcode), while the developer's view files stay clean (only
/// the `dynamic` keyword) except for private-member views (factored helper block).
final class PrepareHybridPlacementTests: XCTestCase {

    private func tmp(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-hybrid-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private let helloView = """
    import SwiftUI
    struct Hello: View {
        var body: some View { Text("hi") }
    }
    """

    // MARK: - SwiftPM shape

    func testSwiftPMGeneratedFolderWiredAndGitignored() throws {
        let dir = try tmp("spm")
        // A realistic SPM layout: Package.swift + Sources/App/Hello.swift.
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            platforms: [.iOS(.v16)],
            targets: [ .target(name: "App") ]
        )
        """, to: dir.appendingPathComponent("Package.swift"))
        let viewURL = dir.appendingPathComponent("Sources/App/Hello.swift")
        try write(helloView, to: viewURL)

        _ = try Prepare.execute(root: dir, excludes: [], target: "App",
                                assumeYes: true, thunksOnly: false, check: false, quiet: true)

        // (1) The view file got ONLY `dynamic` — no same-file block.
        let view = read(viewURL)
        XCTAssertTrue(view.contains("dynamic var body"), view)
        XCTAssertFalse(view.contains(ThunkGenerator.sameFileBeginMarker), view)

        // (2) The generated file lives in Patch/Generated/ UNDER the view's source tree
        // (so SwiftPM globs it into the target by location), and it parses.
        let genURL = dir.appendingPathComponent("Sources/App/Patch/Generated/PatchThunks.generated.swift")
        XCTAssertTrue(exists(genURL), "generated thunk file should be under the target's source tree")
        let gen = read(genURL)
        XCTAssertTrue(gen.contains("@_dynamicReplacement(for: body)"), gen)
        XCTAssertTrue(ThunkGenerator.parses(gen), gen)

        // (3) The PatchSwiftUI product was wired into the SwiftPM target.
        let manifest = read(dir.appendingPathComponent("Package.swift"))
        XCTAssertTrue(manifest.contains(".product(name: \"PatchSwiftUI\", package: \"patch-swift\")"), manifest)

        // (4) The generated folder is gitignored (root rule + in-folder .gitignore).
        let rootIgnore = read(dir.appendingPathComponent(".gitignore"))
        XCTAssertTrue(rootIgnore.contains("Patch/Generated/"), "root .gitignore should ignore the folder:\n\(rootIgnore)")
        XCTAssertTrue(exists(genURL.deletingLastPathComponent().appendingPathComponent(".gitignore")),
                      "an in-folder .gitignore should exist")
    }

    // MARK: - Xcode (synchronized group) shape

    func testXcodeSynchronizedGeneratedFolderWiredAndGitignored() throws {
        let dir = try tmp("xc-sync")
        // An Xcode-16 synchronized-group project whose root folder is `Sync/`.
        try write(PBXThunkIntegrationTests.synchronized,
                  to: dir.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        let viewURL = dir.appendingPathComponent("Sync/Hello.swift")
        try write(helloView, to: viewURL)

        _ = try Prepare.execute(root: dir, excludes: [], target: "Demo",
                                assumeYes: true, thunksOnly: false, check: false, quiet: true)

        // The generated folder lands under Sync/ (the synchronized root) so Xcode auto-
        // includes it by location — verify it's there + the project still lints.
        let genURL = dir.appendingPathComponent("Sync/Patch/Generated/PatchThunks.generated.swift")
        XCTAssertTrue(exists(genURL), "generated thunk file should be under the synchronized root")
        XCTAssertTrue(ThunkGenerator.parses(read(genURL)))

        let pbx = read(dir.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        // Synchronized group: the file is auto-included — no explicit PBXFileReference for
        // it should be added (that would double-compile). Only the product link is wired.
        XCTAssertFalse(pbx.contains("PatchThunks.generated.swift"),
                       "synchronized group: must NOT add an explicit ref for the auto-included file")
        XCTAssertTrue(pbx.contains("PatchSwiftUI"), "the PatchSwiftUI product link must be wired")
        XCTAssertNil(XcodeProjectEditor.plutilLint(dir.appendingPathComponent("Demo.xcodeproj/project.pbxproj")),
                     "edited pbxproj must still lint")

        XCTAssertTrue(read(dir.appendingPathComponent(".gitignore")).contains("Patch/Generated/"))
    }

    // MARK: - Xcode (classic group) shape — explicit file membership

    func testXcodeClassicGeneratedFileGetsExplicitMembership() throws {
        let dir = try tmp("xc-classic")
        try write(OnboardingTests.pbxprojNoPackages,
                  to: dir.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        try write(helloView, to: dir.appendingPathComponent("Hello.swift"))

        _ = try Prepare.execute(root: dir, excludes: [], target: "Demo",
                                assumeYes: true, thunksOnly: false, check: false, quiet: true)

        let pbx = read(dir.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        // Classic group: the generated file needs an explicit ref + build file (it's NOT
        // auto-included by location).
        XCTAssertTrue(pbx.contains("PatchThunks.generated.swift"),
                      "classic group: the generated file must be added to the target explicitly")
        XCTAssertTrue(pbx.contains("PatchSwiftUI"))
        XCTAssertNil(XcodeProjectEditor.plutilLint(dir.appendingPathComponent("Demo.xcodeproj/project.pbxproj")),
                     "edited pbxproj must still lint")
        XCTAssertTrue(read(dir.appendingPathComponent(".gitignore")).contains("Patch/Generated/"))
    }

    // MARK: - Idempotency: a second run is a fixed point

    func testReRunIsAFixedPoint() throws {
        let dir = try tmp("idem")
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [ .target(name: "App") ])
        """, to: dir.appendingPathComponent("Package.swift"))
        let viewURL = dir.appendingPathComponent("Sources/App/Hello.swift")
        try write(helloView, to: viewURL)

        _ = try Prepare.execute(root: dir, excludes: [], target: "App",
                                assumeYes: true, thunksOnly: false, check: false, quiet: true)
        let genURL = dir.appendingPathComponent("Sources/App/Patch/Generated/PatchThunks.generated.swift")
        let view1 = read(viewURL), gen1 = read(genURL), ignore1 = read(dir.appendingPathComponent(".gitignore"))

        _ = try Prepare.execute(root: dir, excludes: [], target: "App",
                                assumeYes: true, thunksOnly: false, check: false, quiet: true)
        XCTAssertEqual(read(viewURL), view1, "view file must be a fixed point")
        XCTAssertEqual(read(genURL), gen1, "generated file must be a fixed point")
        XCTAssertEqual(read(dir.appendingPathComponent(".gitignore")), ignore1,
                       ".gitignore must not accumulate duplicate rules on re-run")
    }

    // MARK: - Bug R2-#105: prepare's test-exclusion must match the build's

    /// A view declared in a file the BUILD/fingerprint classify as a test (a `/UITests/`
    /// directory, or a non-`Tests`-suffixed file that `import XCTest`) must NOT be prepared.
    /// Before the fix, prepare's weaker local `isTestPath` (filename suffixes + `/Tests/`
    /// only) thunked such a view — but the build emits no guest body for it, so the thunk
    /// routed to a non-existent WASM body (a silent on-device demote / wasted dynamic+thunk).
    func testViewsInTestFilesAreNotPrepared() throws {
        let dir = try tmp("testexcl")
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [ .target(name: "App") ])
        """, to: dir.appendingPathComponent("Package.swift"))

        // A real app view (should be prepared).
        let appView = dir.appendingPathComponent("Sources/App/Hello.swift")
        try write(helloView, to: appView)

        // (a) A view in a `/UITests/` directory — the build excludes it by dir name.
        let uiTestsView = dir.appendingPathComponent("UITests/Probe.swift")
        try write("""
        import SwiftUI
        struct ProbeView: View { var body: some View { Text("probe") } }
        """, to: uiTestsView)

        // (b) A view in a NON-`Tests`-suffixed file that `import XCTest` — the build excludes
        // it by content sniff.
        let xctestView = dir.appendingPathComponent("Sources/App/Helpers.swift")
        try write("""
        import SwiftUI
        import XCTest
        struct HelperView: View { var body: some View { Text("helper") } }
        """, to: xctestView)

        let prepared = try Prepare.execute(root: dir, excludes: [], target: "App",
                                           assumeYes: true, thunksOnly: false, check: false, quiet: true)

        // Only the real app view is prepared.
        XCTAssertEqual(prepared, 1, "only Hello should be prepared (test-file views excluded)")
        XCTAssertTrue(read(appView).contains("dynamic var body"), read(appView))
        // The test-file views were NOT touched (no `dynamic` inserted).
        XCTAssertFalse(read(uiTestsView).contains("dynamic"),
                       "a /UITests/ view must not be prepared:\n\(read(uiTestsView))")
        XCTAssertFalse(read(xctestView).contains("dynamic var body"),
                       "an XCTest-importing view must not be prepared:\n\(read(xctestView))")
        // The generated file routes ONLY the real view.
        let gen = read(dir.appendingPathComponent("Sources/App/Patch/Generated/PatchThunks.generated.swift"))
        XCTAssertTrue(gen.contains(#"typeName: "Hello""#), gen)
        XCTAssertFalse(gen.contains("ProbeView"), gen)
        XCTAssertFalse(gen.contains("HelperView"), gen)
    }

    // MARK: - Bug R2-#96: UIKit cell prepare safety

    private let lowerableCell = """
    import UIKit
    struct CellModel { let title: String; let subtitle: String }
    final class ProfileCell: UITableViewCell {
        let titleLabel = UILabel()
        let subtitleLabel = UILabel()
        let stack = UIStackView()
        func configure(with model: CellModel) {
            titleLabel.text = model.title
            subtitleLabel.text = model.subtitle
            stack.axis = .vertical
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(subtitleLabel)
            contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
            ])
        }
    }
    """

    /// A lowerable UIKit cell still prepares correctly through the hardened path: the cell
    /// file's `dynamic` edit goes through the backup→verify discipline (a `.patch-backup` is
    /// left, like the SwiftUI path) and the written UIKit thunk file PARSES (bug R2-#96 — the
    /// dynamic edits used a bare `try?` and there was no thunk parse gate).
    func testUIKitCellPreparesThroughHardenedPath() throws {
        let dir = try tmp("uikit-cell")
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [ .target(name: "App") ])
        """, to: dir.appendingPathComponent("Package.swift"))
        let cellURL = dir.appendingPathComponent("Sources/App/ProfileCell.swift")
        try write(lowerableCell, to: cellURL)
        // The UIKit cell pass only runs when the SwiftUI prepare finds ≥1 view (prepare
        // returns early otherwise) — include a real SwiftUI view so the cell path executes.
        try write(helloView, to: dir.appendingPathComponent("Sources/App/Hello.swift"))

        _ = try Prepare.execute(root: dir, excludes: [], target: "App",
                                assumeYes: true, thunksOnly: false, check: false, quiet: true)

        // The cell's construction method got `dynamic`.
        XCTAssertTrue(read(cellURL).contains("dynamic func configure"), read(cellURL))
        // The backup→verify discipline left a `.patch-backup` (proves it went through
        // writeSourcesWithBackupVerify, not the old bare `try?`).
        XCTAssertTrue(exists(cellURL.appendingPathExtension("patch-backup")),
                      "the cell file's dynamic edit must go through the backup-verify path")
        // The generated UIKit thunk file exists next to the cell AND parses.
        let thunkURL = cellURL.deletingLastPathComponent()
            .appendingPathComponent(UIKitThunkGenerator.thunkFileName)
        XCTAssertTrue(exists(thunkURL), "the UIKit thunk file should be written")
        XCTAssertTrue(ThunkGenerator.parses(read(thunkURL)),
                      "the written UIKit thunk file must parse:\n\(read(thunkURL))")
    }

    /// The parse gate is fail-safe: if the generated UIKit thunk file does not parse, prepare
    /// must NOT write it and must NOT insert `dynamic` (a broken file would abort the whole
    /// app build). We can't force the engine to emit a malformed thunk through the public API,
    /// so this asserts the GATE's invariant directly: a non-parsing thunk string is rejected
    /// by the same `ThunkGenerator.parses` predicate the gate uses.
    func testMalformedUIKitThunkWouldBeRejectedByGate() {
        let broken = """
        #if canImport(UIKit)
        import UIKit
        extension ProfileCell {
            @_dynamicReplacement(for: configure(with:))
            func __patch_configure(with model: CellModel) {
                let x = (   // unbalanced — must not parse
            }
        }
        #endif
        """
        XCTAssertFalse(ThunkGenerator.parses(broken),
                       "a malformed cell thunk must fail the parse gate (so prepare skips writing it)")
        // A well-formed cell thunk passes (the gate doesn't over-reject).
        let ok = """
        #if canImport(UIKit)
        import UIKit
        extension ProfileCell {
            @_dynamicReplacement(for: configure(with:))
            func __patch_configure(with model: CellModel) { configure(with: model) }
        }
        #endif
        """
        XCTAssertTrue(ThunkGenerator.parses(ok))
    }
}
