// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler
@testable import CodeGenerator
@testable import PatchCLI

/// A file the app target compiles that ANOTHER target compiles too (a widget / app extension /
/// framework sharing the file or an Xcode 16 synchronized folder). That target doesn't link PatchSDK,
/// so any Patch code importing it must stay out of the file — found with a fixture app whose
/// `Shared/` synchronized folder belongs to the app and a framework: `prepare` wrote a compact
/// PATCH-THUNKS block (`import PatchSDK`) into `Shared/SharedBadge.swift` and the framework target
/// failed with `no such module 'PatchSDK'`.
final class SharedTargetFileTests: XCTestCase {

    /// App target `App` (synchronized folders `App` + `Shared`) and framework `Kit` (`Shared` only).
    static let pbxproj = """
    // !$*UTF8*$!
    {
    \tarchiveVersion = 1;
    \tobjectVersion = 77;
    \tobjects = {
    \t\tG1 /* App */ = {isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>"; };
    \t\tG2 /* Shared */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Shared; sourceTree = "<group>"; };
    \t\tM1 = {isa = PBXGroup; children = (G1, G2, ); sourceTree = "<group>"; };
    \t\tT1 /* App */ = {isa = PBXNativeTarget; buildPhases = (); fileSystemSynchronizedGroups = (G1, G2, ); name = App; productType = "com.apple.product-type.application"; };
    \t\tT2 /* Kit */ = {isa = PBXNativeTarget; buildPhases = (); fileSystemSynchronizedGroups = (G2, ); name = Kit; productType = "com.apple.product-type.framework"; };
    \t\tP1 = {isa = PBXProject; mainGroup = M1; projectDirPath = ""; targets = (T1, T2, ); };
    \t};
    \trootObject = P1;
    }
    """

    static let sharedBadge = """
    import SwiftUI

    public struct SharedBadge: View {
        public let count: Int
        @State private var pulse = false
        public init(count: Int) { self.count = count }
        public var body: some View {
            HStack {
                Dot(active: pulse)
                Text("\\(count) new")
            }
            .onTapGesture { pulse.toggle() }
        }
    }

    private struct Dot: View {
        let active: Bool
        var body: some View {
            Circle().fill(active ? Color.orange : Color.gray).frame(width: 8, height: 8)
        }
    }
    """

    static let contentView = """
    import SwiftUI

    struct ContentView: View {
        @State private var count = 3
        var body: some View {
            VStack {
                Text("Hello")
                SharedBadge(count: count)
            }
        }
    }
    """

    private func makeProject() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("shared-target-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Shared"), withIntermediateDirectories: true)
        try Self.pbxproj.write(to: root.appendingPathComponent("App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        try Self.contentView.write(to: root.appendingPathComponent("App/ContentView.swift"), atomically: true, encoding: .utf8)
        // Sorts BEFORE `App/` would, if it were named so — the generated folder must still avoid it.
        try Self.sharedBadge.write(to: root.appendingPathComponent("Shared/SharedBadge.swift"), atomically: true, encoding: .utf8)
        try PatchConfig(appKey: "pak_x", project: "App.xcodeproj", target: "App").yamlString()
            .write(to: root.appendingPathComponent(".Patch.yml"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? fm.removeItem(at: root) }
        return root
    }

    func testSharedSwiftFilesAreTheIntersectionWithOtherTargets() throws {
        let root = try makeProject()
        let shared = try XCTUnwrap(XcodeTargetSources.sharedSwiftFiles(projectURL: root.appendingPathComponent("App.xcodeproj"), target: "App"))
        XCTAssertEqual(shared.map { ($0 as NSString).lastPathComponent }, ["SharedBadge.swift"])
        XCTAssertEqual(XcodeTargetSources.nativeTargetNames(pbxproj: Self.pbxproj), ["App", "Kit"])
        XCTAssertEqual(XcodeTargetSources.sharedSwiftFiles(projectURL: root.appendingPathComponent("App.xcodeproj"), target: "Kit")?
                        .map { ($0 as NSString).lastPathComponent }, ["SharedBadge.swift"])

        // A second target that ALREADY links PatchSwiftUI (e.g. an "App All" variant prepared too) can
        // compile Patch's in-file code — sharing with it is not a hazard.
        let linkedKit = Self.pbxproj
            .replacingOccurrences(of: "fileSystemSynchronizedGroups = (G2, ); name = Kit;",
                                  with: "fileSystemSynchronizedGroups = (G2, ); name = Kit; packageProductDependencies = (D1, );")
            .replacingOccurrences(of: "\t\tP1 = {", with: "\t\tD1 = {isa = XCSwiftPackageProductDependency; productName = PatchSwiftUI; };\n\t\tP1 = {")
        XCTAssertEqual(XcodeTargetSources.targetsLinking(product: "PatchSwiftUI", pbxproj: linkedKit), ["Kit"])
        XCTAssertEqual(XcodeTargetSources.sharedSwiftFiles(pbxproj: linkedKit, projectDir: root, target: "App"), [])
    }

    func testPrepareKeepsInFileThunkViewsOfSharedFilesNativeAndRecordsThem() throws {
        let root = try makeProject()
        _ = try Prepare.execute(root: root, excludes: [], target: "App", assumeYes: true,
                                thunksOnly: false, check: false, quiet: true)
        let badge = try String(contentsOf: root.appendingPathComponent("Shared/SharedBadge.swift"), encoding: .utf8)
        XCTAssertFalse(badge.contains("import PatchSDK"), "no PatchSDK import may land in a file another target compiles:\n\(badge)")
        XCTAssertFalse(badge.contains(ThunkGenerator.sameFileBeginMarker), badge)
        let native = PatchConfig.nativeViewNames(near: root)
        XCTAssertTrue(native.contains("Dot"), "the private view type is kept native and recorded: \(native)")
        // The app-only view is still prepared, and the generated folder is not in the shared folder.
        let content = try String(contentsOf: root.appendingPathComponent("App/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains("var body: some View { __patchRoute {"), content)
        // A routed body in the shared file carries only the SwiftUI-only fallback (no PatchSDK), so the
        // other target still builds it natively.
        if badge.contains(ThunkGenerator.routeMethodName) {
            XCTAssertTrue(badge.contains(ThunkGenerator.routeFallbackBeginMarker), badge)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("App/Patch/Generated").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Shared/Patch").path))

        // Idempotent: a second prepare changes nothing further.
        _ = try Prepare.execute(root: root, excludes: [], target: "App", assumeYes: true,
                                thunksOnly: false, check: false, quiet: true)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Shared/SharedBadge.swift"), encoding: .utf8), badge)
        XCTAssertEqual(PatchConfig.nativeViewNames(near: root), native)
    }

    func testGeneratedFolderNeverAnchorsInASharedFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("anchor-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let a = Prepare.Src(url: root.appendingPathComponent("AAShared/Card.swift"), text: "struct Card: View {}")
        let b = Prepare.Src(url: root.appendingPathComponent("App/Home.swift"), text: "struct Home: View {}")
        var result = ThunkGenerator.Result(modifiedFiles: [], thunkFileContents: "", viewNames: ["Card", "Home"],
                                           dynamicInsertions: 0, sameFile: false)
        result.viewDeclaringFile = [:]
        let plain = Prepare.generatedDirectory(for: result, sources: [a, b], root: root)
        XCTAssertTrue(plain.path.contains("/AAShared/"), plain.path)
        let avoided = Prepare.generatedDirectory(for: result, sources: [a, b], root: root,
                                                 avoiding: [ThunkGenerator.normalizedPath(a.url.path)])
        XCTAssertTrue(avoided.path.contains("/App/"), avoided.path)
    }
}
