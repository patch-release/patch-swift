// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator

/// RELEASE-BUILD NET for prepared SwiftUI views — compile, LINK and RUN.
///
/// Every other thunk harness only type-checks (`-typecheck`), which is exactly how a prepared app
/// that built fine in Debug could crash the compiler when ARCHIVED: the old prepare emitted an
/// opaque-result `@_dynamicReplacement(for: body)`, and on Swift 6.0 → 6.3 that form
///   * crashes IRGen at `-O` (`ElementLayout::project` while emitting `__patchedBody`),
///   * fails to LINK at `-O -wmo` (the replacement's opaque type descriptor is never emitted),
///   * and SEGFAULTS AT LAUNCH under parallel WMO (`-num-threads`, Xcode's Release default).
///
/// This test runs the REAL hybrid `prepare` over a multi-file fixture, lays the output out as the
/// separate files Xcode compiles (view files + `Patch/Generated/PatchThunks.generated.swift` + a
/// runnable PatchSDK stand-in), builds it as a macOS executable in the optimization modes a Release
/// archive uses and runs it, asserting at runtime that:
///   (i)   the generated route runs for a prepared view,
///   (ii)  with no active patch the ORIGINAL body runs, exactly once (no recursion),
///   (iii) with a patch the patched view is returned and the original body does not run,
///   (iv)  the body value is well-typed: the direct and the generic (`V.Body` metadata) paths agree
///         on the dynamic type and on the content (`dump` reads it through that metadata).
/// It also builds the prepared views WITHOUT the gitignored generated file (a fresh clone) and
/// asserts they render natively.
///
/// Skips when no macOS SDK / toolchain is available.
final class ReleaseRoutedBodyRunTests: XCTestCase {

    static let helloFile = """
    import SwiftUI

    struct Hello: View {
        @State private var taps = 0
        var title: String = "native-body"
        var body: some View {
            let _ = __testMark("ORIG:Hello")
            VStack(spacing: 4) {
                Text(title)
                Row(label: "row-\\(taps)")
            }
        }
    }

    /// A file-private child view: its whole thunk stays in THIS file (same-file placement).
    private struct Row: View {
        let label: String
        var body: some View { Text(label) }
    }
    """

    static let imperativeFile = """
    import SwiftUI

    /// A non-builder body with explicit returns.
    struct Imperative: View {
        var flag = true
        var body: some View {
            if flag { return AnyView(Text("imperative-a")) }
            return AnyView(Text("imperative-b"))
        }
    }
    """

    /// A runnable stand-in for the PatchSDK surface the generated code calls.
    static let hostStub = """
    import SwiftUI

    nonisolated(unsafe) var __testPatched: Set<String> = []
    nonisolated(unsafe) var __testEvents: [String] = []
    func __testMark(_ s: String) { __testEvents.append(s) }

    public enum PatchHostToken {
        case color(Color)
        case font(Font)
        case number(Double)
        case string(String)
    }

    public struct PatchRowSlot {
        public var count: Int
        public var factory: (Int) -> AnyView
        public init(count: Int, factory: @escaping (Int) -> AnyView) {
            self.count = count; self.factory = factory
        }
    }

    public struct PatchedBodyHost: View {
        let typeName: String
        public var body: some View { Text("patched-\\(typeName)") }
    }

    @MainActor
    public final class Patch {
        public static let shared = Patch()
        public func thunkBody(typeName: String, baselineHash: String? = nil, instance: Any,
                              slots: () -> [String: ([String]) -> AnyView] = { [:] },
                              tokens: () -> [String: PatchHostToken] = { [:] },
                              rowSlots: () -> [String: PatchRowSlot] = { [:] },
                              actionSlots: () -> [String: () -> Void] = { [:] },
                              effectSlots: () -> [String: (AnyView) -> AnyView] = { [:] },
                              callbackSlots: () -> [String: () -> AnyView] = { [:] }) -> PatchedBodyHost? {
            __testMark("ROUTE:\\(typeName)")
            // Exercise the helper closures the way the SDK does.
            _ = slots(); _ = tokens(); _ = rowSlots(); _ = actionSlots(); _ = effectSlots(); _ = callbackSlots()
            return __testPatched.contains(typeName) ? PatchedBodyHost(typeName: typeName) : nil
        }
        public func dispatchCallback(typeName: String, instance: Any, callbackId: String) {}
    }
    """

    static let routedMain = """
    import SwiftUI
    import Foundation

    func viaGeneric<V: View>(_ v: V) -> Any { v.body }
    func fail(_ s: String) -> Never { print("FAIL: \\(s)"); exit(1) }
    func dumped(_ x: Any) -> String { var s = ""; dump(x, to: &s); return s }

    MainActor.assumeIsolated {
        for patched in [false, true, false] {
            __testPatched = patched ? ["Hello", "Imperative"] : []
            for (name, make, native, other) in [
                ("Hello", { () -> (Any, Any, String) in let v = Hello(); return (v.body, viaGeneric(v), String(describing: type(of: v.body))) }, "native-body", "trueContent: PreparedApp.PatchedBodyHost"),
                ("Imperative", { () -> (Any, Any, String) in let v = Imperative(); return (v.body, viaGeneric(v), String(describing: type(of: v.body))) }, "imperative-a", "trueContent: PreparedApp.PatchedBodyHost"),
            ] {
                __testEvents = []
                let (direct, generic, typeName) = make()
                let routes = __testEvents.filter { $0 == "ROUTE:\\(name)" }.count
                let originals = __testEvents.filter { $0 == "ORIG:\\(name)" }.count
                // (i) the route ran — once per body evaluation (direct + generic).
                if routes != 3 { fail("\\(name): route ran \\(routes)x, events \\(__testEvents)") }
                // (ii)/(iii) the right body ran.
                if name == "Hello" {
                    if patched && originals != 0 { fail("Hello: original body ran on the patched path \\(__testEvents)") }
                    if !patched && originals != 3 { fail("Hello: original body ran \\(originals)x (want 3) \\(__testEvents)") }
                }
                // (iv) content + type agree across the direct and generic paths.
                let want = patched ? other : native
                let dont = patched ? native : "trueContent:"
                let d = dumped(direct), g = dumped(generic)
                if !d.contains(want) || d.contains(dont) { fail("\\(name) direct body wrong:\\n\\(d)") }
                if !g.contains(want) || g.contains(dont) { fail("\\(name) generic body wrong:\\n\\(g)") }
                if String(describing: type(of: direct)) != String(describing: type(of: generic)) || typeName != String(describing: type(of: generic)) {
                    fail("\\(name) type mismatch \\(type(of: direct)) vs \\(type(of: generic)) vs \\(typeName)")
                }
                print("ok \\(name) patched=\\(patched) \\(typeName)")
            }
        }
        print("ROUTED-PASS")
    }
    """

    /// With no generated file (a fresh clone): bodies render natively, nothing routes.
    static let freshCloneMain = """
    import SwiftUI
    import Foundation

    func fail(_ s: String) -> Never { print("FAIL: \\(s)"); exit(1) }

    MainActor.assumeIsolated {
        __testEvents = []
        let h = Hello().body
        var d = ""; dump(h, to: &d)
        if !d.contains("native-body") || __testEvents != ["ORIG:Hello"] { fail("fresh clone Hello: \\(__testEvents)\\n\\(d)") }
        if String(describing: type(of: h)).contains("_ConditionalContent") { fail("fallback must be the bare native body: \\(type(of: h))") }
        var i = ""; dump(Imperative(flag: false).body, to: &i)
        if !i.contains("imperative-b") { fail("fresh clone Imperative:\\n\\(i)") }
        print("FRESH-PASS")
    }
    """

    struct Built {
        var dir: URL
        var result: ThunkGenerator.Result
    }

    /// Run the real hybrid prepare and write the files. `includeGenerated == false` omits
    /// `PatchThunks.generated.swift` (and the stub, which only the generated code needs).
    static func layOut(includeGenerated: Bool) throws -> Built {
        let base = URL(fileURLWithPath: "/tmp/PatchReleaseFixture")
        let sources = [("Hello.swift", helloFile), ("Imperative.swift", imperativeFile)]
        let result = ThunkGenerator().prepare(
            sources: sources.map { ThunkGenerator.SourceFile(url: base.appendingPathComponent($0.0), text: $0.1) },
            hybrid: true)
        func stripHostImports(_ s: String) -> String {
            s.replacingOccurrences(of: "import PatchSDK\n", with: "")
                .replacingOccurrences(of: "import PatchSwiftUI\n", with: "")
                .replacingOccurrences(of: "import PatchRender\n", with: "")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("release-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in sources {
            let modified = result.modifiedFiles.first { $0.url.lastPathComponent == name }?.text ?? text
            try stripHostImports(modified).write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // The PatchSDK package is a committed dependency, so it is present in both layouts (the
        // in-file block of the private `Row` view needs it); only the gitignored generated file
        // is missing on a fresh clone.
        try hostStub.write(to: dir.appendingPathComponent("HostStub.swift"), atomically: true, encoding: .utf8)
        if includeGenerated {
            try stripHostImports(result.generatedFileContents)
                .write(to: dir.appendingPathComponent(ThunkGenerator.thunkFileName), atomically: true, encoding: .utf8)
            try routedMain.write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        } else {
            try freshCloneMain.write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        }
        return Built(dir: dir, result: result)
    }

    /// Build `dir/*.swift` into an executable with `flags`, run it, return (build log, run output).
    static func buildAndRun(_ dir: URL, flags: [String]) -> (log: String, output: String?) {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".swift") }.sorted().map { dir.appendingPathComponent($0).path }
        let exe = dir.appendingPathComponent("app-\(flags.joined().filter { $0.isLetter || $0.isNumber })").path
        let args = ["--sdk", "macosx", "swiftc"] + flags
            + ["-module-name", "PreparedApp", "-target", "arm64-apple-macos14", "-o", exe] + files
        let log = SwiftUIThunkCompileTests.run("/usr/bin/xcrun", args, captureStderr: true) ?? ""
        guard FileManager.default.isExecutableFile(atPath: exe) else { return (log, nil) }
        return (log, SwiftUIThunkCompileTests.run(exe, [], captureStderr: true))
    }

    static let releaseModes: [[String]] = [
        ["-O", "-wmo", "-num-threads", "4"],   // Xcode Release: whole-module + parallel IRGen
        ["-O", "-wmo"],
        ["-Osize", "-wmo", "-num-threads", "4"],
        ["-O"],                                 // batch/per-file optimized
        ["-Onone"],                             // Debug
    ]

    private func requireToolchain() throws {
        let sdk = SwiftUIThunkCompileTests.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "macosx"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(sdk.map { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) } ?? false,
                          "no macOS SDK")
        #if !arch(arm64)
        throw XCTSkip("the runnable fixture targets arm64 macOS")
        #endif
    }

    func testPreparedViewsBuildLinkAndRunInReleaseModes() throws {
        try requireToolchain()
        let built = try Self.layOut(includeGenerated: true)
        defer { try? FileManager.default.removeItem(at: built.dir) }
        // CI hook: keep the prepared layout so a real `xcodebuild -configuration Release` app build
        // can consume it (see the release-thunk probe).
        if let keep = ProcessInfo.processInfo.environment["PATCH_RELEASE_FIXTURE_OUT"] {
            try? FileManager.default.removeItem(atPath: keep)
            try FileManager.default.copyItem(at: built.dir, to: URL(fileURLWithPath: keep))
        }
        // The fixture really exercises the route: both views thunked, the private child same-file,
        // and nothing uses a dynamic replacement.
        XCTAssertEqual(Set(built.result.viewNames), ["Hello", "Imperative", "Row"])
        let all = built.result.generatedFileContents + built.result.modifiedFiles.map(\.text).joined()
        XCTAssertFalse(all.contains("_dynamicReplacement"), all)
        XCTAssertFalse(all.contains("dynamic var body"), all)
        for flags in Self.releaseModes {
            let (log, output) = Self.buildAndRun(built.dir, flags: flags)
            XCTAssertNotNil(output, "[\(flags.joined(separator: " "))] must compile + link:\n\(log)")
            XCTAssertTrue(output?.contains("ROUTED-PASS") ?? false,
                          "[\(flags.joined(separator: " "))] runtime checks failed:\n\(output ?? "")\n\(log)")
        }
    }

    func testPreparedViewsBuildAndRenderNativelyWithoutGeneratedFile() throws {
        try requireToolchain()
        let built = try Self.layOut(includeGenerated: false)
        defer { try? FileManager.default.removeItem(at: built.dir) }
        for flags in [["-O", "-wmo", "-num-threads", "4"], ["-Onone"]] {
            let (log, output) = Self.buildAndRun(built.dir, flags: flags)
            XCTAssertNotNil(output, "[\(flags.joined(separator: " "))] a fresh clone must build:\n\(log)")
            XCTAssertTrue(output?.contains("FRESH-PASS") ?? false,
                          "[\(flags.joined(separator: " "))]:\n\(output ?? "")\n\(log)")
        }
    }
}
