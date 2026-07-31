// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler

/// `PackageManifestEditor` — the Package.swift half of the `patchcli init`
/// SPM auto-add (the pbxproj half is covered in OnboardingTests).
final class PackageManifestEditorTests: XCTestCase {

    private func assertWired(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            text.contains(".package(url: \"https://github.com/patch-release/patch-swift\", from: \"1.0.0\")"),
            "package dependency missing:\n\(text)", file: file, line: line)
        XCTAssertTrue(
            text.contains(".product(name: \"PatchSDK\", package: \"patch-swift\")"),
            "product dependency missing:\n\(text)", file: file, line: line)
    }

    /// Compile-check an edited manifest with `swift package dump-package` so
    /// these tests prove the output is genuinely valid SwiftPM, not just
    /// plausible text. (PatchSDK is added as a product of an as-yet-unfetched
    /// package; dump-package evaluates the manifest without resolving, so it
    /// validates syntax/structure exactly as init's verify step does.)
    private func assertManifestEvaluates(_ manifest: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)
        if let failure = PackageManifestEditor.dumpPackageFailure(packageDir: dir) {
            XCTFail("edited manifest does not evaluate: \(failure)\n\(manifest)",
                    file: file, line: line)
        }
    }

    static let standard = """
    // swift-tools-version: 5.9
    import PackageDescription

    let package = Package(
        name: "Demo",
        platforms: [.iOS(.v16)],
        products: [
            .library(name: "Demo", targets: ["Demo"]),
        ],
        dependencies: [
            .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
        ],
        targets: [
            .target(
                name: "Demo",
                dependencies: [
                    .product(name: "Collections", package: "swift-collections"),
                ]
            ),
            .testTarget(name: "DemoTests", dependencies: ["Demo"]),
        ]
    )
    """

    func testAddsToExistingDependencyArrays() throws {
        let (result, text) = try PackageManifestEditor.addPackage(
            to: Self.standard, targetName: "Demo")
        XCTAssertEqual(result, .added)
        assertWired(text)
        // Existing dependencies survive.
        XCTAssertTrue(text.contains("swift-collections"))
        // The product landed in the Demo target, not the test target.
        let testTargetPart = text.components(separatedBy: ".testTarget").last!
        XCTAssertFalse(testTargetPart.contains("PatchSDK"))
        try assertManifestEvaluates(text)
    }

    static let bare = """
    // swift-tools-version: 5.9
    import PackageDescription

    let package = Package(
        name: "Solo",
        targets: [
            .target(name: "Solo"),
        ]
    )
    """

    func testCreatesBothDependencyArraysWhenAbsent() throws {
        let (result, text) = try PackageManifestEditor.addPackage(
            to: Self.bare, targetName: "Solo")
        XCTAssertEqual(result, .added)
        assertWired(text)
        try assertManifestEvaluates(text)
    }

    func testExecutableTargetWithTrailingArgs() throws {
        let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Tool",
            targets: [
                .executableTarget(name: "Tool", path: "Sources/Tool"),
            ]
        )
        """
        let (result, text) = try PackageManifestEditor.addPackage(to: manifest, targetName: "Tool")
        XCTAssertEqual(result, .added)
        assertWired(text)
        // The created dependencies array must not swallow the path: argument.
        XCTAssertTrue(text.contains("path: \"Sources/Tool\""))
        try assertManifestEvaluates(text)
    }

    func testIdempotent() throws {
        let (_, once) = try PackageManifestEditor.addPackage(to: Self.standard, targetName: "Demo")
        let (again, twice) = try PackageManifestEditor.addPackage(to: once, targetName: "Demo")
        XCTAssertEqual(again, .alreadyPresent)
        XCTAssertEqual(once, twice)
    }

    func testUnknownTargetThrows() {
        XCTAssertThrowsError(
            try PackageManifestEditor.addPackage(to: Self.standard, targetName: "Nope"))
    }

    func testBracketsInsideStringsAndCommentsDoNotConfuseTheScanner() throws {
        let tricky = """
        // swift-tools-version: 5.9
        // A comment with brackets [ ( and a fake targets: label
        import PackageDescription

        let package = Package(
            name: "Weird[Name", /* block ] comment ) */
            dependencies: [
                .package(url: "https://example.com/a[b", from: "1.0.0"), // ]
            ],
            targets: [
                .target(name: "Weird", dependencies: []),
            ]
        )
        """
        let (result, text) = try PackageManifestEditor.addPackage(to: tricky, targetName: "Weird")
        XCTAssertEqual(result, .added)
        assertWired(text)
    }

    func testEmptyInlineDependencyArrays() throws {
        let inline = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Inline",
            dependencies: [],
            targets: [
                .target(name: "Inline", dependencies: []),
            ]
        )
        """
        let (result, text) = try PackageManifestEditor.addPackage(to: inline, targetName: "Inline")
        XCTAssertEqual(result, .added)
        assertWired(text)
        try assertManifestEvaluates(text)
    }

    func testApplyWritesBackupAndVerifies() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-apply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = dir.appendingPathComponent("Package.swift")
        try Self.standard.write(to: manifest, atomically: true, encoding: .utf8)

        let result = try PackageManifestEditor.apply(packageDir: dir, targetName: "Demo")
        XCTAssertEqual(result, .added)
        assertWired(try String(contentsOf: manifest, encoding: .utf8))
        let backup = try String(
            contentsOf: dir.appendingPathComponent("Package.swift.patch-backup"),
            encoding: .utf8)
        XCTAssertEqual(backup, Self.standard)
    }
}
