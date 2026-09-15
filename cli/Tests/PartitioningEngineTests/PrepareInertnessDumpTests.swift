// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import CryptoKit
@testable import CodeGenerator
@testable import Compiler
@testable import PatchCLI

/// INERTNESS VERIFIER for prepare-side changes (env-gated; local corpus only). For each corpus app
/// it runs the REAL `Prepare.execute` on an APFS clone and dumps, under `$PATCH_INERTNESS_OUT/<app>/`:
///   * `tree/…` — every `.swift` file prepare wrote (view files + `PatchThunks.generated.swift`),
///   * `views.txt` — per lowered view: auto-route verdict, body content hash, native-surface hash,
///   * `fingerprint.txt` — the native-shell component hashes BEFORE and AFTER prepare.
/// Run it on two builds (base vs branch) and `diff -r` the outputs: every difference must be a
/// view that uses the changed shape. Uses only APIs that exist on both sides of the change.
final class PrepareInertnessDumpTests: XCTestCase {
    func testDumpCorpusPrepareAndFingerprint() throws {
        let env = ProcessInfo.processInfo.environment
        guard let outRoot = env["PATCH_INERTNESS_OUT"], !outRoot.isEmpty else {
            throw XCTSkip("set PATCH_INERTNESS_OUT=<dir> to dump prepare/fingerprint inertness data")
        }
        guard let corpus = CorpusPaths.resolvedRoot() else { throw XCTSkip("no corpus") }
        let apps = (env["PATCH_INERTNESS_APPS"] ?? "").split(separator: ",").map(String.init)
        let fm = FileManager.default
        func sha(_ s: String) -> String {
            SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
        }
        func fingerprint(_ dir: URL) -> String {
            let snap = ProjectFingerprinter().snapshot(projectDir: dir, bridges: [:])
            return snap.componentHashes.map { "\($0.label)=\($0.hash)" }.sorted().joined(separator: "\n")
                + "\nnative=" + snap.components.nativeSwiftFiles.joined(separator: "\n")
        }
        for app in apps {
            let src = corpus.appendingPathComponent(app)
            guard fm.fileExists(atPath: src.path) else { continue }
            let work = fm.temporaryDirectory.appendingPathComponent("inert-\(app)-\(UUID().uuidString)")
            _ = SwiftUIThunkCompileTests.run("/bin/cp", ["-cR", src.path, work.path])
            defer { try? fm.removeItem(at: work) }
            let out = URL(fileURLWithPath: outRoot).appendingPathComponent(app)
            try? fm.removeItem(at: out)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)

            let before = fingerprint(work)
            let originals = Dictionary(uniqueKeysWithValues: Prepare.swiftSources(in: work, excludes: [])
                .map { ($0.url.standardizedFileURL.path, $0.text) })
            _ = try? Prepare.execute(root: work, excludes: [], target: nil, assumeYes: true,
                                     thunksOnly: false, check: false, quiet: true)
            // Every .swift file prepare created or changed.
            let workPath = work.standardizedFileURL.resolvingSymlinksInPath().path
            if let en = fm.enumerator(at: work, includingPropertiesForKeys: nil) {
                for case let url as URL in en where url.pathExtension == "swift" {
                    let p = url.standardizedFileURL.path
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    if originals[p] == text { continue }
                    let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
                    let rel = resolved.hasPrefix(workPath) ? String(resolved.dropFirst(workPath.count)) : url.lastPathComponent
                    let dest = out.appendingPathComponent("tree").appendingPathComponent(rel)
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: dest, atomically: true, encoding: .utf8)
                }
            }
            let after = fingerprint(work)
            try ("BEFORE\n" + before + "\n\nAFTER\n" + after + "\n")
                .write(to: out.appendingPathComponent("fingerprint.txt"), atomically: true, encoding: .utf8)

            let sources = ProjectFingerprinter.crossFileLoweringSources(projectDir: work)
            let bundle = BodyLowering.crossFileBundle(sources: sources.map(\.source))
            var lines: [String] = []
            for (_, text) in sources where text.contains("View") {
                for lv in BodyLowering().lowerAllViews(source: text, sameFileThunk: true, crossFile: bundle) {
                    let routed = ProjectFingerprinter.isAutoRouted(lv, collidingBases: [])
                    lines.append("\(lv.viewName) routed=\(routed) body=\(BodyLowering.viewBodyContentHash(lv).prefix(16)) "
                                 + "surface=\(sha(ProjectFingerprinter.nativeSurface(of: lv)))")
                }
            }
            try (lines.sorted().joined(separator: "\n") + "\n")
                .write(to: out.appendingPathComponent("views.txt"), atomically: true, encoding: .utf8)
        }
    }
}
