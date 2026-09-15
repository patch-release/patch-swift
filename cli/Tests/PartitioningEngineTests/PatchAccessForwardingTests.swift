// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import CodeGenerator

/// PRIVATE-ACCESS FORWARDING — the default `patchcli prepare` placement for a view whose thunk reads
/// `private` members. The view's file gets only `dynamic` + a compact, sorted PATCH-ACCESS forwarder
/// extension; the whole thunk lives in `Patch/Generated/`. These tests run the REAL hybrid prepare and
/// then swiftc TYPE-CHECK the resulting MULTI-FILE output (each prepared source file as its own file +
/// the generated file + the SDK host stub) against the iOS simulator SDK — separate files, so Swift's
/// file-scoped `private` genuinely bites: a forwarder that doesn't actually grant access fails here.
final class PatchAccessForwardingTests: XCTestCase {

    // MARK: - Harness

    private func prepare(_ files: [(String, String)], accessForwarding: Bool = true) -> ThunkGenerator.Result {
        ThunkGenerator().prepare(
            sources: files.map { .init(url: URL(fileURLWithPath: "/fixture/\($0.0)"), text: $0.1) },
            hybrid: true, accessForwarding: accessForwarding)
    }

    private func text(_ r: ThunkGenerator.Result, _ name: String, original: [(String, String)]) -> String {
        r.modifiedFiles.first { $0.url.lastPathComponent == name }?.text
            ?? original.first { $0.0 == name }!.1
    }

    /// Type-check the prepared multi-file project. nil = no iOS SDK (skip).
    private func typecheck(_ r: ThunkGenerator.Result, original: [(String, String)],
                           swiftVersion: String = "5") throws -> (ok: Bool, log: String)? {
        guard let sdk = SwiftUIThunkCompileTests.run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "iphonesimulator"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sdk.isEmpty else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("paf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var paths: [String] = []
        func strip(_ s: String) -> String {
            s.replacingOccurrences(of: "import PatchSDK\n", with: "")
                .replacingOccurrences(of: "import PatchSwiftUI\n", with: "")
                .replacingOccurrences(of: "import PatchRender\n", with: "")
        }
        for (name, _) in original {
            let u = tmp.appendingPathComponent(name)
            try strip(text(r, name, original: original)).write(to: u, atomically: true, encoding: .utf8)
            paths.append(u.path)
        }
        if !r.generatedFileContents.isEmpty {
            let u = tmp.appendingPathComponent("PatchThunks.generated.swift")
            try strip(r.generatedFileContents).write(to: u, atomically: true, encoding: .utf8)
            paths.append(u.path)
        }
        let stub = tmp.appendingPathComponent("HostStub.swift")
        try SwiftUIThunkCompileTests.hostStub.write(to: stub, atomically: true, encoding: .utf8)
        paths.append(stub.path)
        let log = SwiftUIThunkCompileTests.run("/usr/bin/swiftc",
            ["-typecheck", "-sdk", sdk, "-target", "arm64-apple-ios17.0-simulator",
             "-swift-version", swiftVersion, "-module-name", "FixtureApp"] + paths,
            captureStderr: true) ?? ""
        return (!log.contains("error:"), log)
    }

    private func dump(_ r: ThunkGenerator.Result, _ original: [(String, String)]) -> String {
        var s = ""
        for (n, _) in original { s += "===== \(n) =====\n\(text(r, n, original: original))\n" }
        return s + "===== generated =====\n\(r.generatedFileContents)"
    }

    /// Generated lines living in developer files (everything between any BEGIN/END markers).
    static func inFileGeneratedLines(_ text: String) -> Int {
        var n = 0, inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == ThunkGenerator.sameFileBeginMarker || t == PatchAccessForwarding.beginMarker { inside = true }
            if inside { n += 1 }
            if t == ThunkGenerator.sameFileEndMarker || t == PatchAccessForwarding.endMarker { inside = false }
        }
        return n
    }

    // MARK: - Fixtures

    /// The customer shape: a view whose native slots/actions/effects reach a private `@State` (value
    /// AND `$binding`), a private computed `some View` helper, a private method with labeled params, a
    /// private child View TYPE, a `fileprivate` computed property, a private `@Environment` action, a
    /// private static, and a private async method driving `.task`.
    static let mixView = """
    import SwiftUI

    struct Track: Identifiable { let id: Int; let name: String }

    private struct MixTrackRow: View {
        let track: Track
        var body: some View { HStack { Image(systemName: "music.note"); Text(track.name) } }
    }

    final class MixModel: ObservableObject { @Published var tracks: [Track] = [] }

    struct MixView: View {
        @State private var isOn = false
        @State private var volume: Double = 0.5
        @StateObject private var model = MixModel()
        @Environment(\\.dismiss) private var dismiss
        private static let maxRows = 5
        fileprivate var subtitle: String { "Tracks: \\(model.tracks.count)" }
        private var header: some View { Label("Mix", systemImage: "slider.horizontal.3").font(.headline) }
        @ViewBuilder private func row(_ t: Track, compact: Bool = false) -> some View {
            if compact { Text(t.name) } else { MixTrackRow(track: t) }
        }
        private func load() async {}
        private func bump(by n: Double) { volume += n }

        var body: some View {
            VStack {
                header
                Toggle("Enabled", isOn: $isOn)
                Slider(value: $volume, in: 0...1)
                MixTrackRow(track: Track(id: 0, name: "Intro"))
                row(Track(id: 1, name: "Verse"), compact: true)
                Text(subtitle)
                Button("Louder") { bump(by: 0.1) }
                Button("Done") { dismiss() }
                Text("max \\(Self.maxRows)")
            }
            .task { await load() }
        }
    }
    """

    // MARK: - Tests

    func testCustomerShapeForwardsAndCompilesMultiFile() throws {
        let files = [("MixView.swift", Self.mixView)]
        let r = prepare(files)
        let view = text(r, "MixView.swift", original: files)
        guard case .forwardedPrivateAccess(let members)? = r.placements["MixView"] else {
            return XCTFail("MixView should be forwarded; placement=\(String(describing: r.placements["MixView"])) blockers=\(r.forwardingBlockers)\n\(dump(r, files))")
        }
        XCTAssertFalse(members.isEmpty, "\(dump(r, files))")
        // In-file footprint: dynamic + the forwarder block only — no thunk block, no replacement.
        XCTAssertTrue(view.contains("dynamic var body"), view)
        XCTAssertTrue(view.contains(PatchAccessForwarding.beginMarker), view)
        // MixView's thunk (replacement + helpers) is NOT in the file. (The only in-file thunk is the
        // compact one for `MixTrackRow`, a `private struct … : View` — no other file can extend it.)
        XCTAssertFalse(view.contains(#"typeName: "MixView""#), "MixView's thunk must live in Generated/:\n\(view)")
        XCTAssertTrue(r.generatedFileContents.contains(#"typeName: "MixView""#), r.generatedFileContents)
        XCTAssertFalse(view.contains("///"), "in-file generated code carries no doc-comment bulk:\n\(view)")
        XCTAssertEqual(r.placements["MixTrackRow"], .sameFileBecausePrivate(members: ["<private view type>"]))
        // The generated file carries the helpers, retargeted to forwarders.
        XCTAssertTrue(r.generatedFileContents.contains("func __patchSlots"), r.generatedFileContents)
        if ProcessInfo.processInfo.environment["PAF_DUMP"] == "1" { print(dump(r, files)) }
        guard let tc = try typecheck(r, original: files) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(tc.ok, "multi-file prepared output must type-check:\n\(tc.log)\n\(dump(r, files))")
    }

    func testCustomerShapeCompilesInSwift6LanguageMode() throws {
        let files = [("MixView.swift", Self.mixView)]
        let r = prepare(files)
        guard let tc = try typecheck(r, original: files, swiftVersion: "6") else { throw XCTSkip("no iphonesimulator SDK") }
        // Only OUR code matters: a pre-existing Swift-6 concurrency diagnostic in the fixture itself
        // would show up identically without Patch; require no error mentioning a forwarder.
        let ours = tc.log.split(separator: "\n").filter { $0.contains("error:") && $0.contains("__patch") }
        XCTAssertTrue(ours.isEmpty, "forwarders must type-check in Swift 6 mode:\n\(tc.log)\n\(dump(r, files))")
    }

    func testForwarderBlockIsSmallSortedAndStableAcrossBodyEdits() throws {
        let files = [("MixView.swift", Self.mixView)]
        let r1 = prepare(files)
        // A body edit that uses the SAME private members (a literal + reorder) must not change the block.
        let edited = Self.mixView
            .replacingOccurrences(of: "Button(\"Louder\")", with: "Button(\"Turn it up\")")
            .replacingOccurrences(of: "Text(subtitle)\n", with: "Text(subtitle)\n            Divider()\n")
        let files2 = [("MixView.swift", edited)]
        let r2 = prepare(files2)
        func block(_ t: String) -> String {
            guard let b = t.range(of: PatchAccessForwarding.beginMarker),
                  let e = t.range(of: PatchAccessForwarding.endMarker) else { return "" }
            return String(t[b.lowerBound..<e.upperBound])
        }
        let b1 = block(text(r1, "MixView.swift", original: files))
        let b2 = block(text(r2, "MixView.swift", original: files2))
        XCTAssertFalse(b1.isEmpty)
        XCTAssertEqual(b1, b2, "a body edit that keeps the same private-member set must not change the forwarder block")
        // Sorted forwarders.
        let decls = b1.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("var ") || $0.hasPrefix("func ") || $0.hasPrefix("static ") || $0.hasPrefix("@") || $0.hasPrefix("nonisolated") }
        XCTAssertEqual(decls, decls.sorted(), b1)
        // Footprint: the forwarder block is far smaller than the legacy same-file block.
        let legacy = prepare(files, accessForwarding: false)
        let before = Self.inFileGeneratedLines(text(legacy, "MixView.swift", original: files))
        let after = Self.inFileGeneratedLines(text(r1, "MixView.swift", original: files))
        XCTAssertLessThan(after, before, "forwarders (\(after) lines) must be smaller than the legacy block (\(before) lines)")
        print("[PatchAccessForwarding] MixView in-file generated lines: legacy=\(before) forwarders=\(after)")
    }

    func testPrivateStateBindingAndMethodWithParams() throws {
        let files = [("Settings.swift", """
        import SwiftUI
        struct SettingsScreen: View {
            @State private var notifications: Bool = true
            @State private var name = "Ada"
            @FocusState private var focused: Bool
            private func label(for key: String, uppercased: Bool) -> String { uppercased ? key.uppercased() : key }
            var body: some View {
                Form {
                    Toggle(label(for: "notify", uppercased: true), isOn: $notifications)
                    TextField("Name", text: $name).focused($focused)
                    Button("Reset") { notifications = false; name = "" }
                }
            }
        }
        """)]
        let r = prepare(files)
        guard let tc = try typecheck(r, original: files) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(tc.ok, "\(tc.log)\n\(dump(r, files))")
    }

    func testFileprivateAndPrivateExtensionMembers() throws {
        let files = [("Card.swift", """
        import SwiftUI
        struct CardView: View {
            let title: String
            var body: some View {
                VStack { Text(title); badge; Text(caption) }
            }
        }
        private extension CardView {
            var badge: some View { Image(systemName: "star.fill").foregroundStyle(.yellow) }
        }
        extension CardView {
            fileprivate var caption: String { title.uppercased() }
        }
        """)]
        let r = prepare(files)
        guard let tc = try typecheck(r, original: files) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(tc.ok, "\(tc.log)\n\(dump(r, files))")
    }

    /// The ThunkGeneratorHybridTests private-member fixtures (struct-private @State of a nested type,
    /// `private extension`, `fileprivate extension`, per-member `private` in a plain extension), now
    /// FORWARDED by default: no helper block in the file, and the multi-file output type-checks.
    func testHybridPrivateMemberFixturesForwardAndCompile() throws {
        let fixtures: [(String, String)] = [
            ("CardView", """
            import SwiftUI
            struct CardView: View {
                struct Profile { var name: String; var age: Int }
                @State private var profile = Profile(name: "Ada", age: 36)
                var body: some View { VStack { Text(profile.name); Text("static") } }
            }
            """),
            ("PrivExt", """
            import SwiftUI
            struct PrivExt: View {
                var body: some View { Text(label).foregroundStyle(accentColor) }
            }
            private extension PrivExt {
                var label: String { "x" }
                var accentColor: Color { .red }
            }
            """),
            ("FilePrivExt", """
            import SwiftUI
            struct FilePrivExt: View {
                var body: some View { Text(label) }
            }
            fileprivate extension FilePrivExt {
                var label: String { "x" }
            }
            """),
            ("MemberPriv", """
            import SwiftUI
            struct MemberPriv: View {
                var body: some View { Text(label) }
            }
            extension MemberPriv {
                private var label: String { "x" }
            }
            """),
        ]
        for (name, src) in fixtures {
            let files = [("\(name).swift", src)]
            let r = prepare(files)
            let view = text(r, "\(name).swift", original: files)
            XCTAssertFalse(view.contains("__patchSlots") || view.contains("__patchTokens"),
                           "\(name): no helper methods in the developer file:\n\(dump(r, files)) blockers=\(r.forwardingBlockers)")
            guard let tc = try typecheck(r, original: files) else { throw XCTSkip("no iphonesimulator SDK") }
            XCTAssertTrue(tc.ok, "\(name):\n\(tc.log)\n\(dump(r, files))")
        }
    }

    /// FALLBACK: a private member with an unspellable (inferred, non-literal) type can't be forwarded —
    /// the view keeps the legacy same-file block, the blocker is reported by name, and it still compiles.
    func testUnforwardableMemberFallsBackToSameFileAndReports() throws {
        let files = [("Weird.swift", """
        import SwiftUI
        struct WeirdView: View {
            private var palette = [Color.red, Color.blue].shuffled()
            var body: some View {
                VStack { Circle().fill(palette[0]).frame(width: 20, height: 20) }
            }
        }
        """)]
        let r = prepare(files)
        let view = text(r, "Weird.swift", original: files)
        if ProcessInfo.processInfo.environment["PAF_DUMP"] == "1" { print(r.placements, r.forwardingBlockers, dump(r, files)) }
        if case .forwardedPrivateAccess? = r.placements["WeirdView"] {
            // Only acceptable if the thunk never needed `palette` (lowering may host it differently).
            XCTAssertFalse(r.generatedFileContents.contains("palette"), dump(r, files))
        } else if case .sameFileBecausePrivate? = r.placements["WeirdView"] {
            XCTAssertNotNil(r.forwardingBlockers["WeirdView"]?["palette"], "blocker must be named: \(r.forwardingBlockers)")
            XCTAssertTrue(view.contains(ThunkGenerator.sameFileBeginMarker), view)
        }
        guard let tc = try typecheck(r, original: files) else { throw XCTSkip("no iphonesimulator SDK") }
        XCTAssertTrue(tc.ok, "\(tc.log)\n\(dump(r, files))")
    }

    /// MIGRATION: a file carrying an old CLI's PATCH-THUNKS block is re-prepared into the forwarder
    /// layout (old block stripped, forwarders written, helpers moved), and re-running is a fixed point.
    func testMigratesLegacyInFileBlockAndIsIdempotent() throws {
        let files = [("MixView.swift", Self.mixView)]
        let legacy = prepare(files, accessForwarding: false)
        let legacyText = text(legacy, "MixView.swift", original: files)
        XCTAssertTrue(legacyText.contains(ThunkGenerator.sameFileBeginMarker), legacyText)
        // Re-prepare the legacy-prepared tree with the new default.
        let migratedFiles = [("MixView.swift", legacyText)]
        let migrated = prepare(migratedFiles)
        let m = text(migrated, "MixView.swift", original: migratedFiles)
        XCTAssertFalse(m.contains("// Patch kept the patch-thunk code"), "legacy block must be replaced:\n\(m)")
        XCTAssertTrue(m.contains(PatchAccessForwarding.beginMarker), m)
        XCTAssertEqual(m.components(separatedBy: ThunkGenerator.sameFileBeginMarker).count - 1, 1, m)
        XCTAssertEqual(m.components(separatedBy: PatchAccessForwarding.beginMarker).count - 1, 1, m)
        XCTAssertEqual(m.components(separatedBy: "dynamic var body").count - 1, 2, m)
        // Same as preparing the pristine source.
        let fresh = prepare(files)
        XCTAssertEqual(m, text(fresh, "MixView.swift", original: files))
        XCTAssertEqual(migrated.generatedFileContents, fresh.generatedFileContents)
        // Fixed point.
        let again = prepare([("MixView.swift", m)])
        XCTAssertEqual(text(again, "MixView.swift", original: [("MixView.swift", m)]), m)
        // And stripping every Patch block + dynamic restores the pristine source byte-for-byte.
        let stripped = PatchAccessForwarding.removeDynamic(
            from: PatchAccessForwarding.stripAllGeneratedBlocks(from: m), onlyTypes: nil).text
        XCTAssertEqual(stripped, Self.mixView.hasSuffix("\n") ? Self.mixView : Self.mixView + "\n")
    }

    /// Slot ids + baseline body hashes (native fast path) are untouched by forwarding — only the
    /// helper TEXT is retargeted.
    func testSlotIdsAndBaselineHashesUnchanged() {
        let files = [("MixView.swift", Self.mixView)]
        let legacy = prepare(files, accessForwarding: false)
        let fwd = prepare(files)
        func ids(_ s: String) -> [String] {
            let re = try! NSRegularExpression(pattern: #"(__[srtaecb]+)\["([^"]+)"\]"#)
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
        }
        func hashes(_ s: String) -> [String] {
            let re = try! NSRegularExpression(pattern: #"baselineHash: "[0-9a-f]+""#)
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
        }
        let legacyAll = legacy.generatedFileContents + text(legacy, "MixView.swift", original: files)
        let fwdAll = fwd.generatedFileContents + text(fwd, "MixView.swift", original: files)
        XCTAssertFalse(ids(legacyAll).isEmpty)
        XCTAssertEqual(ids(legacyAll), ids(fwdAll))
        XCTAssertEqual(hashes(legacyAll), hashes(fwdAll))
    }
}
