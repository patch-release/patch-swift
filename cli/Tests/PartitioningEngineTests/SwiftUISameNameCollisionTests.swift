// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator
@testable import Compiler
import ViewNodeIR

/// SAME-NAME VIEW COLLISION (soundness).
/// ====================================
/// Two SwiftUI views that sanitize to the SAME guest export base
/// (`view_body__<name>`) — e.g. two `CardView`s in different files/modules — can
/// NEITHER be auto-routed CORRECTLY. The SDK identifies a live view ONLY by the
/// unqualified type-name string baked statically into its generated thunk
/// (`Patch.shared.thunkBody(typeName: "CardView", …)`) and routes on
/// `entries[typeName]`. Two views named `CardView` produce thunks that BOTH bake
/// `"CardView"` and BOTH look up the SAME manifest slot, so shipping either body
/// would route the OTHER view's instance through it (render view A's body for
/// view B). There is no module qualifier at the SDK boundary to disambiguate.
///
/// The engine therefore EXCLUDES *every* claimant of a colliding name from guest
/// emission (not just the second): both render native via the thunk's fallback
/// `body`, so no mis-route is possible. A view with a UNIQUE name is unaffected
/// (byte-identical behavior — no churn). These tests pin that contract.
final class SwiftUISameNameCollisionTests: XCTestCase {

    // MARK: - 1. The emitter's export base derivation (the collision key)

    func testSameNameProducesSameExportBase() {
        // Two views named `CardView` derive the IDENTICAL guest export — that's the
        // collision the pipeline must guard. (And a UNIQUE name differs.)
        XCTAssertEqual(SwiftUIGuestEmitter.exportSymbol(forView: "CardView"),
                       SwiftUIGuestEmitter.exportSymbol(forView: "CardView"))
        XCTAssertNotEqual(SwiftUIGuestEmitter.exportSymbol(forView: "CardView"),
                          SwiftUIGuestEmitter.exportSymbol(forView: "Header"))
    }

    // MARK: - 2. No-toolchain: the emitted wrapper EXCLUDES both colliding views,
    //            KEEPS the uniquely-named one.

    /// Drives `runSwiftUILowering` with the stub compiler (no WASM toolchain needed).
    /// The guest wrapper `_PatchSwiftUI.swift` is written to disk before compilation,
    /// so we can read it and assert exactly which view bodies were emitted — the
    /// colliding pair must be absent, the unique view present.
    func testCollidingViewsExcludedFromEmittedWrapper() throws {
        let dir = try makeSourceDir([
            // `CardView` declared in TWO separate files (the cross-module shape that
            // actually compiles — two top-level structs of one name can't coexist in
            // a single module). Each body is independently lowerable.
            "FeatureA.swift": """
            import SwiftUI
            struct CardView: View {
                let title: String = "A"
                var body: some View { VStack { Text(title); Text("from A") } }
            }
            """,
            "FeatureB.swift": """
            import SwiftUI
            struct CardView: View {
                let title: String = "B"
                var body: some View { VStack { Text(title); Text("from B") } }
            }
            """,
            // A uniquely-named view that MUST still ship.
            "Header.swift": """
            import SwiftUI
            struct Header: View {
                let caption: String = "Hi"
                var body: some View { VStack { Text(caption) } }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let buildDir = dir.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        // StubWasmCompiler reports the toolchain unavailable, so the pipeline emits
        // the wrapper (written to disk) then declines — exactly what we want to read.
        _ = try? BuildPipeline().runSwiftUILowering(
            sourceDir: dir, buildDir: buildDir, compiler: StubWasmCompiler(),
            defaultModule: buildDir.appendingPathComponent("module.wasm"))

        let wrapperURL = buildDir.appendingPathComponent("swiftui")
            .appendingPathComponent("_PatchSwiftUI.swift")
        let wrapper = try String(contentsOf: wrapperURL, encoding: .utf8)

        // The unique view ships.
        XCTAssertTrue(wrapper.contains("view_body__Header"),
                      "the uniquely-named Header view must still be emitted")
        // NEITHER colliding `CardView` ships — the export base appears nowhere as a
        // declared `@_cdecl` export (no body function for it).
        XCTAssertFalse(wrapper.contains("@_cdecl(\"view_body__CardView\")"),
                       "neither same-named CardView may be emitted (unroutable collision)")
        XCTAssertFalse(wrapper.contains("_patchBuildTree__CardView"),
                       "no build-tree function for the excluded colliding views")
        // The manifest must NOT carry a CardView entry (no routable type). The
        // manifest JSON is baked into the guest as an ESCAPED Swift string literal
        // (`\"type\":\"Header\"`), so match that shape.
        XCTAssertFalse(wrapper.contains(#"\"type\":\"CardView\""#),
                       "the manifest must not advertise a routable CardView")
        XCTAssertTrue(wrapper.contains(#"\"type\":\"Header\""#),
                      "the manifest must advertise the unique Header view")
    }

    /// The exclusion fires the concise non-verbose warning naming the dropped views.
    func testCollisionEmitsNonVerboseWarning() throws {
        XCTAssertNil(ProcessInfo.processInfo.environment["PATCH_SWIFTUI_VERBOSE"],
                     "this test asserts the NON-verbose warning path")
        let dir = try makeSourceDir([
            "A.swift": """
            import SwiftUI
            struct CardView: View { let t: String = "A"; var body: some View { VStack { Text(t) } } }
            """,
            "B.swift": """
            import SwiftUI
            struct CardView: View { let t: String = "B"; var body: some View { VStack { Text(t) } } }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let buildDir = dir.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let captured = try captureStderr {
            _ = try? BuildPipeline().runSwiftUILowering(
                sourceDir: dir, buildDir: buildDir, compiler: StubWasmCompiler(),
                defaultModule: buildDir.appendingPathComponent("module.wasm"))
        }
        XCTAssertTrue(captured.contains("CardView"),
                      "the warning names the excluded colliding view: \(captured)")
        XCTAssertTrue(captured.contains("render"),
                      "the warning explains it renders natively: \(captured)")
    }

    // MARK: - 3. End-to-end (toolchain): the unique view ships + runs in WASM while
    //            the colliding pair is excluded — the module still compiles cleanly.

    func testUniqueViewShipsWhenSiblingNameCollides() throws {
        // The unique `Header` export ships; the colliding `CardView`s do not.
        let compiler = SwiftWasmCompiler(
            exportedSymbols: ["view_body", "view_body__Header", "patch_view_manifest",
                              "patch_malloc", "patch_free"])
        try XCTSkipUnless(compiler.toolchainAvailable,
                          "swift.org WASM toolchain not installed — skipping WASM build")

        let dir = try makeSourceDir([
            "FeatureA.swift": """
            import SwiftUI
            struct CardView: View {
                let title: String = "A"
                var body: some View { VStack { Text(title); Text("from A") } }
            }
            """,
            "FeatureB.swift": """
            import SwiftUI
            struct CardView: View {
                let title: String = "B"
                var body: some View { VStack { Text(title); Text("from B") } }
            }
            """,
            "Header.swift": """
            import SwiftUI
            struct Header: View {
                let caption: String = "Hi"
                var body: some View { VStack { Text(caption) } }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let buildDir = dir.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let result = try BuildPipeline().runSwiftUILowering(
            sourceDir: dir, buildDir: buildDir, compiler: compiler,
            defaultModule: buildDir.appendingPathComponent("module.wasm"))
        let sw = try XCTUnwrap(result, "the unique Header view should still ship")
        XCTAssertEqual(sw.loweredViewBodies, 1, "only Header ships; both CardViews excluded")
        XCTAssertTrue(sw.exports.contains("view_body__Header"))
        XCTAssertFalse(sw.exports.contains("view_body__CardView"),
                       "neither same-named CardView ships (unroutable collision)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(sw.moduleURL).path))
    }

    // MARK: - helpers

    private func makeSourceDir(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func captureStderr(_ body: () throws -> Void) throws -> String {
        let pipe = Pipe()
        let original = dup(STDERR_FILENO)
        fflush(stderr)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        nonisolated(unsafe) let collected = NSMutableData()
        let lock = NSLock()
        let reader = Thread {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); collected.append(data); lock.unlock()
        }
        reader.start()
        func teardownAndRead() -> String {
            fflush(stderr)
            dup2(original, STDERR_FILENO)
            close(original)
            pipe.fileHandleForWriting.closeFile()
            while !reader.isFinished { usleep(1000) }
            lock.lock(); let data = collected as Data; lock.unlock()
            return String(decoding: data, as: UTF8.self)
        }
        do { try body() } catch {
            _ = teardownAndRead()
            throw error
        }
        return teardownAndRead()
    }
}
