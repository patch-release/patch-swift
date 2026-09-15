// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler
@testable import CodeGenerator

/// FINGERPRINT INVARIANCE of the private-access-forwarding migration — the property that keeps every
/// already-shipped app working: re-preparing a project that an OLDER CLI prepared (in-file PATCH-THUNKS
/// blocks) into the forwarder layout (PATCH-ACCESS blocks + Generated/ thunks) must leave the registered
/// native-shell fingerprint byte-identical, so no app has to re-register or rebuild.
final class PatchAccessForwardingFingerprintTests: XCTestCase {

    private func write(_ files: [(String, String)], generated: String, to root: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let gen = root.appendingPathComponent("Patch/Generated")
        try fm.createDirectory(at: gen, withIntermediateDirectories: true)
        try generated.write(to: gen.appendingPathComponent(ThunkGenerator.thunkFileName), atomically: true, encoding: .utf8)
    }

    private func prepared(_ files: [(String, String)], forwarding: Bool) -> ([(String, String)], String) {
        let r = ThunkGenerator().prepare(
            sources: files.map { .init(url: URL(fileURLWithPath: "/p/\($0.0)"), text: $0.1) },
            hybrid: true, accessForwarding: forwarding)
        let out = files.map { f in (f.0, r.modifiedFiles.first { $0.url.lastPathComponent == f.0 }?.text ?? f.1) }
        return (out, r.generatedFileContents)
    }

    static let project: [(String, String)] = [
        ("MixView.swift", PatchAccessForwardingTests.mixView),
        ("Plain.swift", """
        import SwiftUI
        struct PlainView: View {
            let title: String
            var body: some View { Text(title).padding() }
        }
        """),
        ("Weird.swift", """
        import SwiftUI
        struct WeirdView: View {
            private var palette = [Color.red, Color.blue].shuffled()
            @State private var on = false
            private var header: some View { Text("Weird") }
            var body: some View {
                VStack { header; Circle().fill(palette[0]).frame(width: 20, height: 20); Toggle("x", isOn: $on) }
            }
        }
        """),
    ]

    func testMigratingALegacyPreparedProjectKeepsTheFingerprintIdentical() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paf-fp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fp = { ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint }

        // (1) The project as an OLDER CLI left it: legacy same-file blocks.
        let (legacyFiles, legacyGen) = prepared(Self.project, forwarding: false)
        XCTAssertTrue(legacyFiles.contains { $0.1.contains("// Patch kept the patch-thunk code") }, "fixture must exercise a legacy block")
        try write(legacyFiles, generated: legacyGen, to: root)
        let before = fp()

        // (2) The next `patchcli prepare` (new default) re-prepares that SAME on-disk tree.
        let (migratedFiles, migratedGen) = prepared(legacyFiles, forwarding: true)
        XCTAssertTrue(migratedFiles.contains { $0.1.contains(PatchAccessForwarding.beginMarker) }, "fixture must exercise forwarding")
        XCTAssertNotEqual(legacyFiles.map { $0.1 }, migratedFiles.map { $0.1 }, "the migration must actually change the files")
        try write(migratedFiles, generated: migratedGen, to: root)
        let after = fp()

        XCTAssertEqual(before, after, "migrating to private-access forwarding must not change the native-shell fingerprint")

        // (3) Stable across a further re-prepare, too.
        let (again, againGen) = prepared(migratedFiles, forwarding: true)
        try write(again, generated: againGen, to: root)
        XCTAssertEqual(fp(), after)
    }

    func testStrippedShellTextIsIdenticalPerFile() {
        let (legacy, _) = prepared(Self.project, forwarding: false)
        let (fwd, _) = prepared(Self.project, forwarding: true)
        for (l, f) in zip(legacy, fwd) {
            XCTAssertEqual(ProjectFingerprinter.stripPatchScaffolding(l.1), ProjectFingerprinter.stripPatchScaffolding(f.1),
                           "\(l.0): stripped shell differs\n--- legacy ---\n\(l.1)\n--- forwarded ---\n\(f.1)")
        }
    }

    /// Local E2E helper (env-gated): print the native-shell fingerprint of each directory in
    /// `PAF_FP_DIRS` (colon-separated) — used to compare a real app before/after migration.
    func testPrintFingerprintsOfDirs() throws {
        guard let dirs = ProcessInfo.processInfo.environment["PAF_FP_DIRS"] else { throw XCTSkip("set PAF_FP_DIRS") }
        for d in dirs.split(separator: ":") {
            let fp = ProjectFingerprinter().snapshot(projectDir: URL(fileURLWithPath: String(d)), bridges: [:]).fingerprint
            print("[PAF_FP] \(d) \(fp)")
        }
    }

    /// A developer comment that merely resembles the marker, or a BEGIN with no END, never strips code.
    func testUnterminatedAccessMarkerStripsNothing() {
        let src = """
        struct A {
            \(PatchAccessForwarding.beginMarker)
            var realNativeCode = 1
        }
        """
        XCTAssertEqual(ProjectFingerprinter.stripPatchScaffolding(src), src)
    }
}
