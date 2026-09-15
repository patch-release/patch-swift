// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler
@testable import CodeGenerator
import PartitioningEngine

/// Body ROUTING (`var body: some View { __patchRoute { … } }`, the prepare edit that replaced
/// `dynamic var body` + `@_dynamicReplacement`) must be invisible to everything derived from the
/// developer's source: a project prepared by this CLI has the SAME native-shell fingerprint, the
/// same per-view `bodyHash` (native fast path) and the same slot ids as the same project prepared
/// by an older (`dynamic`) CLI — so existing registered fingerprints and shipped modules stay valid.
final class FingerprintRoutedBodyTests: XCTestCase {

    private func tmpRoot(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("patch-fp-route-\(tag)-\(UUID().uuidString)")
    }
    private func write(_ root: URL, _ rel: String, _ contents: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: u, atomically: true, encoding: .utf8)
    }
    private func fingerprint(_ root: URL) -> String {
        ProjectFingerprinter().snapshot(projectDir: root, bridges: [:]).fingerprint
    }

    static let displayText = """
    import SwiftUI
    struct DisplayText: View { let text: String; var body: some View { Text(text) } }
    """

    /// An auto-routed view whose body carries a LIFTED string literal (a byte-range the
    /// fingerprint normalizes — the case where offsets move under the routing edit).
    static let card = """
    import SwiftUI
    struct CardView: View {
        var title: String
        var body: some View {
            VStack {
                DisplayText(text: "Settings")
                Text(title)
            }
        }
    }

    struct Plain: View {
        var body: some View { Text("plain") }
    }
    """

    /// What the older CLI's prepare wrote into these files: `dynamic ` before each `var body`.
    static func legacyPrepared(_ s: String) -> String {
        s.replacingOccurrences(of: "    var body: some View", with: "    dynamic var body: some View")
            .replacingOccurrences(of: "; var body: some View", with: "; dynamic var body: some View")
    }

    private func routedPrepared(_ files: [String: String]) -> [String: String] {
        let base = URL(fileURLWithPath: "/tmp/fp-route")
        let r = ThunkGenerator().prepare(sources: files.map {
            .init(url: base.appendingPathComponent($0.key), text: $0.value)
        }, hybrid: true)
        var out = files
        for m in r.modifiedFiles { out[m.url.lastPathComponent] = m.text }
        return out
    }

    func testRoutedPrepareHashesLikeLegacyDynamicPrepare() throws {
        let files = ["DisplayText.swift": Self.displayText, "CardView.swift": Self.card]
        let routed = routedPrepared(files)
        XCTAssertTrue(routed["CardView.swift"]!.contains("var body: some View { __patchRoute {"), routed["CardView.swift"]!)
        XCTAssertTrue(routed["CardView.swift"]!.contains(ThunkGenerator.routeFallbackBeginMarker))

        for shipped in [nil, ["CardView", "Plain", "DisplayText"]] as [[String]?] {
            let legacyRoot = tmpRoot("legacy"), routedRoot = tmpRoot("routed")
            defer { try? FileManager.default.removeItem(at: legacyRoot); try? FileManager.default.removeItem(at: routedRoot) }
            for (name, text) in files { try write(legacyRoot, "App/\(name)", Self.legacyPrepared(text)) }
            for (name, text) in routed { try write(routedRoot, "App/\(name)", text) }
            if let shipped {
                for root in [legacyRoot, routedRoot] {
                    let m = ShippedOTAManifest(shippedSwiftUIViews: shipped, shippedUIKitCells: [], generalLogicTrusted: true)
                    try FileManager.default.createDirectory(at: root.appendingPathComponent(".Patch/build"), withIntermediateDirectories: true)
                    try JSONEncoder().encode(m).write(to: root.appendingPathComponent(".Patch/build/\(ShippedOTAManifest.fileName)"))
                }
            }
            XCTAssertEqual(fingerprint(routedRoot), fingerprint(legacyRoot),
                           "a routed project must hash exactly like the same project prepared with `dynamic` (manifest: \(String(describing: shipped)))")

            // The lifted literal still rides WASM: editing it keeps the routed fingerprint stable…
            let before = fingerprint(routedRoot)
            let cardURL = routedRoot.appendingPathComponent("App/CardView.swift")
            let edited = try String(contentsOf: cardURL, encoding: .utf8)
                .replacingOccurrences(of: #""Settings""#, with: #""Preferences and more""#)
            try edited.write(to: cardURL, atomically: true, encoding: .utf8)
            if shipped != nil { XCTAssertEqual(fingerprint(routedRoot), before, "a lifted-literal edit must stay stable") }
            // …and a native edit outside the lifted literal still churns.
            try edited.replacingOccurrences(of: "var title: String", with: "var title: String = \"t\"")
                .write(to: cardURL, atomically: true, encoding: .utf8)
            XCTAssertNotEqual(fingerprint(routedRoot), before, "a native-shell edit must still churn")
        }
    }

    /// Partitioning must classify a routed body exactly like the `dynamic` body it replaces
    /// (real app: CleanArchSwiftUI's private generic `QueryViewContainer`, whose body stayed native
    /// only because of `dynamic` — without the parity rule its routed body became wasmEligible and
    /// moved the fingerprint). The route closure adds no record; generated `__patchRoute`s are native.
    func testRoutedBodyPartitionsLikeDynamicBody() throws {
        let original = """
        import SwiftUI
        private struct Shield<T: Equatable>: View, Equatable {
            let value: T
            let make: (T) -> String
            var body: some View {
                Text(make(value)).onTapGesture { print(value) }
            }
            static func == (l: Shield<T>, r: Shield<T>) -> Bool { l.value == r.value }
        }
        """
        let routed = routedPrepared(["Shield.swift": original])["Shield.swift"]!
        XCTAssertTrue(routed.contains("var body: some View { __patchRoute {"), routed)
        func classify(_ text: String) throws -> [String: String] {
            let root = tmpRoot("partition")
            defer { try? FileManager.default.removeItem(at: root) }
            try write(root, "App/Shield.swift", text)
            let report = try PartitioningEngine(registry: .standard).analyze(directory: root)
            return Dictionary(report.results.map { ($0.functionID, String(describing: $0.classification)) },
                              uniquingKeysWith: { a, _ in a })
        }
        let legacy = try classify(Self.legacyPrepared(original))
        let prepared = try classify(routed)
        // The generated blocks' own members aren't developer code; compare the developer's.
        XCTAssertEqual(prepared.filter { !$0.key.contains("__patch") }, legacy.filter { !$0.key.contains("__patch") })
        XCTAssertFalse(prepared.keys.contains { $0.contains("closure@L") && !$0.contains("__patch") && !legacy.keys.contains($0) },
                       "the route wrapper closure must not add a record: \(prepared.keys.sorted())")
        for (id, c) in prepared where id.hasSuffix("__patchRoute(_:)") { XCTAssertNotEqual(c, "wasmEligible", id) }
    }

    func testRoutedBodyLowersIdenticallyToOriginal() throws {
        let routed = routedPrepared(["DisplayText.swift": Self.displayText, "CardView.swift": Self.card])["CardView.swift"]!
        let lb = BodyLowering()
        let original = lb.lowerAllViews(source: Self.card, sameFileThunk: true)
        let prepared = lb.lowerAllViews(source: routed, sameFileThunk: true)
        XCTAssertEqual(original.map(\.viewName), prepared.map(\.viewName))
        XCTAssertFalse(original.isEmpty)
        for (o, p) in zip(original, prepared) {
            XCTAssertEqual(BodyLowering.viewBodyContentHash(o), BodyLowering.viewBodyContentHash(p), o.viewName)
            XCTAssertEqual(o.guestBody, p.guestBody, o.viewName)
            XCTAssertEqual(o.opaqueLeaves.map(\.id), p.opaqueLeaves.map(\.id), o.viewName)
        }
    }

    /// Real-app check (env-gated): `PATCH_FP_PAIRS="legacyDir=routedDir;…"` — the same app prepared
    /// by an older (`dynamic`) CLI and by this one must have the same native-shell fingerprint.
    func testRealAppPairsHashIdentically() throws {
        guard let spec = ProcessInfo.processInfo.environment["PATCH_FP_PAIRS"], !spec.isEmpty else {
            throw XCTSkip("set PATCH_FP_PAIRS=legacyDir=routedDir;… to compare real prepared apps")
        }
        for pair in spec.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let ls = ProjectFingerprinter().snapshot(projectDir: URL(fileURLWithPath: parts[0]), bridges: [:])
            let rs = ProjectFingerprinter().snapshot(projectDir: URL(fileURLWithPath: parts[1]), bridges: [:])
            let legacy = ls.fingerprint, routed = rs.fingerprint
            print("FP-PAIR \(parts[1]) \(legacy == routed ? "EQUAL" : "DIFFERENT")")
            for (a, b) in zip(ls.componentHashes, rs.componentHashes) where a.1 != b.1 { print("FP-COMPONENT \(a.0)") }
            let lf = Set(ls.components.nativeSwiftFiles), rf = Set(rs.components.nativeSwiftFiles)
            for f in lf.symmetricDifference(rf).sorted() { print("FP-FILE \(lf.contains(f) ? "legacy" : "routed") \(f)") }
            XCTAssertEqual(legacy, routed, "\(parts[0]) vs \(parts[1])")
        }
    }

    func testLegacyCanonicalFormIsExactInverse() {
        let routed = routedPrepared(["DisplayText.swift": Self.displayText, "CardView.swift": Self.card])
        for (name, text) in routed {
            let canonical = ThunkGenerator.legacyCanonicalForm(text)?.text ?? text
            let original = name == "CardView.swift" ? Self.card : Self.displayText
            XCTAssertEqual(canonical, Self.legacyPrepared(original), name)
            // And unprepare's inverse restores the pristine source.
            let restored = ThunkGenerator.unrouteBodies(in: ThunkGenerator.stripRouteFallbackBlock(from: text), onlyTypes: nil).text
            XCTAssertEqual(restored, original, name)
        }
    }
}
